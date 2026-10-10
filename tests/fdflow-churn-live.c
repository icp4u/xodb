#define _GNU_SOURCE 1
/* Manual/periodic: needs root or CAP_PERFMON (exits 77 when denied). Captures
 * all CPUs like the default graph view while this process forks more than 20k
 * short-lived owned children, draining every 10 ms and binding a 1 s poll of
 * itself, as the owner does. Prints per-phase drain cost per record and ring
 * loss as aggregates only; no other process's identity is printed. */
#include "check.h"
#include "xrt_fdflow_count.h"
#include "xrt_fdscan.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now(clockid_t id) {
    struct timespec t;
    CHECK(!clock_gettime(id, &t));
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
int main(int argc, char **argv) {
    const uint32_t children = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 10) : 25000, phases = 5;
    CHECK(children >= phases);
    struct xrt_fdflow *flow = NULL;
    struct xrt_perf_failure why = {0};
    struct xrt_fdflow_options o = {0};
    enum xrt_status opened = xrt_fdflow_open(&o, &flow, &why);
    if (opened != XRT_OK) {
        fprintf(stderr, "flow open status=%u syscall=%s errno=%d detail=%s\n", opened,
                why.syscall ? why.syscall : "none", why.error, why.detail ? why.detail : "none");
        if (opened == XRT_PERMISSION_DENIED) {
            puts("BLOCKED: needs root or CAP_PERFMON; run with sudo -n -- (does not change the system)");
            return 77;
        }
        return 1;
    }
    struct xrt_fdflow_counter *counter = NULL;
    CHECK(xrt_fdflow_counter_create(262144, 65536, 16384, &counter) == XRT_OK);
    int32_t self = getpid();
    struct xrt_fdscan_options so = {.max_processes = 16384, .max_fds = 262144, .pids = &self, .pid_count = 1};
    struct xrt_fdscan *scan = NULL;
    CHECK(xrt_fdscan_create(&so, &scan) == XRT_OK);
    struct xrt_fdflow_snapshot stream = {0};
    uint64_t feed_ns[5] = {0}, records[5] = {0}, lost[5] = {0}, wall_ns[5] = {0};
    uint64_t next_drain = 0, next_poll = 0, phase_start = now(CLOCK_MONOTONIC), max_feed_ns = 0;
    uint32_t forked = 0, reaped = 0, peak_processes = 0, peak_threads = 0;
    while (reaped < children) {
        uint32_t phase = reaped * phases / children;
        uint64_t t = now(CLOCK_MONOTONIC);
        if (forked < children && forked - reaped < 64) {
            pid_t pid = fork();
            CHECK(pid >= 0);
            if (!pid) {
                char byte;
                ssize_t n = read(0, &byte, 0); /* one owned syscall, then exit */
                _exit(n < 0);
            }
            ++forked;
        }
        int status;
        while (reaped < forked && waitpid(-1, &status, forked < children ? WNOHANG : 0) > 0)
            ++reaped;
        if (t >= next_drain) {
            CHECK(xrt_fdflow_drain(flow, &stream) == XRT_OK);
            uint64_t started = now(CLOCK_THREAD_CPUTIME_ID);
            CHECK(xrt_fdflow_counter_feed(counter, &stream) == XRT_OK);
            uint64_t spent = now(CLOCK_THREAD_CPUTIME_ID) - started;
            feed_ns[phase] += spent;
            if (spent > max_feed_ns)
                max_feed_ns = spent;
            records[phase] += stream.record_count;
            lost[phase] = stream.lost;
            next_drain = t + 10000000u;
            struct xrt_fdflow_counts v;
            xrt_fdflow_counter_view(counter, &v);
            if (v.process_count > peak_processes)
                peak_processes = v.process_count;
            if (v.thread_count > peak_threads)
                peak_threads = v.thread_count;
        }
        if (t >= next_poll) {
            struct xrt_fd_snapshot s;
            if (xrt_fdscan_poll(scan, &s) == XRT_OK) {
                struct xrt_fdflow_bindings *b = NULL;
                if (xrt_fdflow_bindings_create(&s, &b) == XRT_OK &&
                    xrt_fdflow_counter_bind(counter, b) != XRT_OK)
                    xrt_fdflow_bindings_free(b);
            }
            next_poll = t + 1000000000u;
        }
        if (reaped * phases / children != phase) {
            wall_ns[phase] = now(CLOCK_MONOTONIC) - phase_start;
            phase_start = now(CLOCK_MONOTONIC);
        }
    }
    CHECK(xrt_fdflow_drain(flow, &stream) == XRT_OK && xrt_fdflow_counter_feed(counter, &stream) == XRT_OK);
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(counter, &v);
    double load[3] = {0};
    CHECK(getloadavg(load, 3) == 3);
    printf("{\"children\":%u,\"peak_tracked_processes\":%u,\"peak_tracked_threads\":%u,\"counter_flags\":%u,"
           "\"stream_flags\":%u,\"lost\":%llu,\"max_feed_ms\":%.3f,\"phases\":[",
           children, peak_processes, peak_threads, v.flags, stream.flags, (unsigned long long)stream.lost,
           (double)max_feed_ns / 1e6);
    for (uint32_t i = 0; i < phases; ++i)
        printf("%s{\"records\":%llu,\"feed_ns_per_record\":%.1f,\"lost_total\":%llu,\"wall_ms\":%.0f}", i ? "," : "",
               (unsigned long long)records[i], records[i] ? (double)feed_ns[i] / (double)records[i] : 0,
               (unsigned long long)lost[i], (double)wall_ns[i] / 1e6);
    printf("],\"load\":[%.2f,%.2f,%.2f]}\n", load[0], load[1], load[2]);
    xrt_fdflow_close(flow);
    xrt_fdscan_destroy(scan);
    xrt_fdflow_counter_free(counter);
    /* Tables never fill, so churn never withdraws joins. Loss is reported, and
     * judged against host load by the reader (performance is evidence). */
    CHECK(!(v.flags & (XRT_FDFLOW_COUNT_CAP | XRT_FDFLOW_COUNT_OOM)));
    CHECK(peak_processes < 16384);
    puts(stream.lost ? "churn: tables bounded; ring loss reported above"
                     : "churn: tables bounded, no ring loss PASS");
    return 0;
}
