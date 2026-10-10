#define _GNU_SOURCE 1
/* Accelerated churn through the flow counter at the owner's real limits.
 * Pure: synthetic records and polls, no perf handle or procfs. Gates the
 * structure (tables track the live set, rows track live descriptors, no cap,
 * no withdrawn joins); per-record and per-publication costs are printed as
 * evidence only. */
#include "check.h"
#include "xrt_fdflow_count.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { SERVER = 500, PARENT = 1000, ROWS = 262144, THREADS = 65536, PROCESSES = 16384 };
static uint64_t now_ns = 1000, sequence;
static struct xrt_fdflow_record records[1u << 16];
static uint32_t used, peak_processes, peak_threads;
static uint64_t feed_cpu, feed_records;
static int wrong_oracle;

static uint64_t cpu_ns(void) {
    struct timespec t;
    CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t));
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void flush(struct xrt_fdflow_counter *c) {
    struct xrt_fdflow_snapshot s = {.records = records, .record_count = used, .taken_ns = ++now_ns};
    uint64_t started = cpu_ns();
    CHECK(xrt_fdflow_counter_feed(c, &s) == XRT_OK);
    feed_cpu += cpu_ns() - started;
    feed_records += used;
    used = 0;
}
static void push(struct xrt_fdflow_counter *c, int32_t pid, int32_t tid, uint32_t kind,
                 uint32_t op, int64_t number, int64_t arg, int64_t result) {
    if (used == sizeof records / sizeof *records)
        flush(c);
    records[used++] = (struct xrt_fdflow_record){.pid = pid,
                                                 .tid = tid,
                                                 .kind = kind,
                                                 .operation = op,
                                                 .time_ns = ++now_ns,
                                                 .number = number,
                                                 .args = {(uint64_t)arg},
                                                 .result = result};
}
static void raw(struct xrt_fdflow_counter *c, int32_t pid, int32_t tid, int64_t number, int64_t arg) {
    push(c, pid, tid, XRT_FDFLOW_ENTER, XRT_FDFLOW_RAW, number, arg, 0);
    push(c, pid, tid, XRT_FDFLOW_EXIT, XRT_FDFLOW_RAW, number, 0, 0);
}
static void io(struct xrt_fdflow_counter *c, int32_t pid, int32_t tid, int write, int fd, int64_t n) {
    int64_t number = write ? 1 : 0;
    push(c, pid, tid, XRT_FDFLOW_ENTER, XRT_FDFLOW_RAW, number, fd, 0);
    push(c, pid, tid, XRT_FDFLOW_EXIT, XRT_FDFLOW_RAW, number, 0, n);
    push(c, pid, tid, XRT_FDFLOW_EXIT, write ? XRT_FDFLOW_WRITE : XRT_FDFLOW_READ, number, 0, n);
}
/* One poll: the server's fds [first, first+count) at inode base+fd, and each
 * listed child pid with one regular fd 3. The poll starts before pending
 * records are fed, then completes, as on the owner. */
static void poll(struct xrt_fdflow_counter *c, int first, int count, uint64_t base,
                 const int32_t *children, uint32_t nchildren) {
    flush(c);
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v); /* tables just before a bind are at their largest */
    if (v.process_count > peak_processes)
        peak_processes = v.process_count;
    if (v.thread_count > peak_threads)
        peak_threads = v.thread_count;
    static struct xrt_fd fds[1024 + 4096];
    static struct xrt_fd_process processes[1 + 4096];
    uint32_t nf = 0, np = 0;
    processes[np++] = (struct xrt_fd_process){.pid = SERVER, .start = 1, .first = 0, .count = (uint32_t)count};
    for (int i = 0; i < count; ++i)
        fds[nf++] = (struct xrt_fd){.fd = first + i, .kind = XRT_FD_SOCKET, .flags = XRT_FD_STAT,
                                    .device = 9, .inode = base + (uint64_t)(first + i)};
    for (uint32_t i = 0; i < nchildren; ++i) {
        processes[np++] = (struct xrt_fd_process){.pid = children[i], .start = 2 + (uint64_t)children[i],
                                                  .first = nf, .count = 1};
        fds[nf++] = (struct xrt_fd){.fd = 3, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 2,
                                    .inode = 7};
    }
    struct xrt_fd_snapshot s = {.sequence = ++sequence, .taken_ns = now_ns, .scan_ns = 1,
                                .processes = processes, .process_count = np, .fds = fds, .fd_count = nf};
    now_ns += 2;
    struct xrt_fdflow_bindings *b = NULL;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK);
    CHECK(xrt_fdflow_counter_bind(c, b) == XRT_OK);
}
/* What the owner copies each publication. */
static uint64_t publish_bytes(struct xrt_fdflow_counter *c) {
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v);
    return (uint64_t)v.row_count * sizeof *v.rows;
}
static void process_churn(void) {
    struct xrt_fdflow_counter *c = NULL;
    CHECK(xrt_fdflow_counter_create(ROWS, THREADS, PROCESSES, &c) == XRT_OK);
    const uint32_t total = 40000, per_poll = 2000, phases = 8;
    uint64_t server_bytes = 0, phase_cpu[8] = {0}, phase_records[8] = {0};
    poll(c, 7, 1, 100, NULL, 0);
    for (uint32_t k = 0; k < total; ++k) {
        int32_t child = 2000 + (int32_t)k;
        uint32_t phase = k * phases / total;
        uint64_t cpu0 = feed_cpu, records0 = feed_records;
        raw(c, PARENT, PARENT, 56, 0);           /* clone in the parent */
        raw(c, child, child, 59, 0);             /* execve */
        raw(c, child, child, 257, 0);            /* openat -> fd 3 */
        io(c, child, child, 0, 3, 64);           /* read: fd 3 not in any poll */
        raw(c, child, child, 3, 3);              /* close */
        push(c, child, child, XRT_FDFLOW_ENTER, XRT_FDFLOW_RAW, 231, 0, 0); /* exit_group */
        io(c, SERVER, SERVER, 1, 7, 10);         /* a steady server write */
        server_bytes += 10;
        if (used > 60000)
            flush(c);
        phase_cpu[phase] += feed_cpu - cpu0;
        phase_records[phase] += feed_records - records0;
        if (k % per_poll == per_poll - 1) {
            int32_t alive = child;
            cpu0 = feed_cpu, records0 = feed_records;
            poll(c, 7, 1, 100, &alive, 1);
            phase_cpu[phase] += feed_cpu - cpu0;
            phase_records[phase] += feed_records - records0;
        }
    }
    flush(c);
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v);
    printf("{\"case\":\"process_churn\",\"processes\":%u,\"peak_tracked_processes\":%u,\"peak_tracked_threads\":%u,"
           "\"flags\":%u,\"server_unknown\":%llu,\"ns_per_record_by_phase\":[",
           total, peak_processes, peak_threads, v.flags,
           (unsigned long long)(v.unknown_write));
    for (uint32_t i = 0; i < phases; ++i)
        printf("%s%.1f", i ? "," : "", (double)phase_cpu[i] / (double)(phase_records[i] ? phase_records[i] : 1));
    puts("]}");
    /* 2000 pids per poll: tables hold about one poll's worth, never the cap. */
    CHECK(!(v.flags & (XRT_FDFLOW_COUNT_CAP | XRT_FDFLOW_COUNT_INCOMPLETE | XRT_FDFLOW_COUNT_OOM)));
    CHECK(peak_processes > per_poll && peak_processes <= per_poll + 8 && peak_threads <= per_poll + 8);
    /* Churn never withdraws the steady server's joins. */
    CHECK(v.row_count >= 1 && v.rows[0].pid == SERVER);
    CHECK(v.rows[0].write_bytes == server_bytes + (wrong_oracle ? 1u : 0u) && !v.unknown_write);
    xrt_fdflow_counter_free(c);
}
/* More pids than the process table between two polls: pressure eviction keeps
 * feeding O(1) amortised (the review measured 0.35-1.6 s per batch before). */
static void pid_flood(void) {
    struct xrt_fdflow_counter *c = NULL;
    CHECK(xrt_fdflow_counter_create(ROWS, THREADS, PROCESSES, &c) == XRT_OK);
    int32_t pid = 1;
    printf("{\"case\":\"pid_flood\",\"records_per_batch\":32768,\"cpu_ms_by_batch\":[");
    for (int round = 0; round < 4; ++round) {
        for (int i = 0; i < 32768; ++i) {
            records[i] = (struct xrt_fdflow_record){.time_ns = ++now_ns, .pid = pid, .tid = pid,
                                                    .kind = XRT_FDFLOW_ENTER, .number = 39};
            ++pid;
        }
        struct xrt_fdflow_snapshot s = {.records = records, .record_count = 32768, .taken_ns = ++now_ns};
        uint64_t started = cpu_ns();
        CHECK(xrt_fdflow_counter_feed(c, &s) == XRT_OK);
        printf("%s%.2f", round ? "," : "", (double)(cpu_ns() - started) / 1e6);
    }
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v);
    printf("],\"tracked_processes\":%u,\"flags\":%u}\n", v.process_count, v.flags);
    CHECK(v.process_count <= PROCESSES && !(v.flags & (XRT_FDFLOW_COUNT_CAP | XRT_FDFLOW_COUNT_INCOMPLETE)));
    xrt_fdflow_counter_free(c);
}
/* A server with 256 open connections, all replaced every poll: 1M connections,
 * about 2.7 hours at 100/s, in a few seconds. Rows stay at the live set. */
static void connection_churn(void) {
    struct xrt_fdflow_counter *c = NULL;
    CHECK(xrt_fdflow_counter_create(ROWS, THREADS, PROCESSES, &c) == XRT_OK);
    const int live = 256;
    const uint32_t polls = 4096;
    uint32_t peak_rows = 0;
    uint64_t copy_cpu[4] = {0}, copies[4] = {0}, peak_bytes = 0, known = 0;
    struct xrt_fdflow_count_row *spare = malloc(ROWS * sizeof *spare);
    CHECK(spare);
    for (uint32_t k = 0; k < polls; ++k) {
        poll(c, 10, live, 1000000 + (uint64_t)k * 1024, NULL, 0);
        for (int fd = 10; fd < 10 + live; ++fd) {
            io(c, SERVER, SERVER + 1 + fd % 4, 0, fd, 100);
            io(c, SERVER, SERVER + 1 + fd % 4, 1, fd, 50);
        }
        flush(c);
        struct xrt_fdflow_counts v;
        xrt_fdflow_counter_view(c, &v);
        if (v.row_count > peak_rows)
            peak_rows = v.row_count;
        uint64_t bytes = publish_bytes(c);
        if (bytes > peak_bytes)
            peak_bytes = bytes;
        uint64_t started = cpu_ns();
        memcpy(spare, v.rows, v.row_count * sizeof *v.rows);
        copy_cpu[k * 4 / polls] += cpu_ns() - started;
        ++copies[k * 4 / polls];
        CHECK(!(v.flags & (XRT_FDFLOW_COUNT_CAP | XRT_FDFLOW_COUNT_INCOMPLETE)));
        known = v.read_bytes + v.write_bytes - v.unknown_read - v.unknown_write;
    }
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v);
    printf("{\"case\":\"connection_churn\",\"connections\":%u,\"peak_rows\":%u,\"peak_publish_bytes\":%llu,"
           "\"flags\":%u,\"publish_copy_ns_by_quarter\":[",
           polls * (uint32_t)live, peak_rows, (unsigned long long)peak_bytes, v.flags);
    for (int i = 0; i < 4; ++i)
        printf("%s%.0f", i ? "," : "", (double)copy_cpu[i] / (double)(copies[i] ? copies[i] : 1));
    puts("]}");
    free(spare);
    CHECK(peak_rows == (uint32_t)live + (wrong_oracle ? 1u : 0u));
    CHECK(known == (uint64_t)polls * live * 150 && !v.unknown_read && !v.unknown_write);
    xrt_fdflow_counter_free(c);
}
int main(int argc, char **argv) {
    /* A case name runs only that case, e.g. to measure an older counter. */
    setvbuf(stdout, NULL, _IOLBF, 0);
    wrong_oracle = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    const char *only = argc == 2 && !wrong_oracle ? argv[1] : NULL;
    if (!only || !strcmp(only, "processes"))
        process_churn();
    if (!only || !strcmp(only, "flood"))
        pid_flood();
    if (!only || !strcmp(only, "connections"))
        connection_churn();
    puts("flow counter churn: tables track live pids, rows track live descriptors PASS");
    return 0;
}
