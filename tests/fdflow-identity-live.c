#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdflow_count.h"
#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now(clockid_t id) {
    struct timespec t;
    CHECK(!clock_gettime(id, &t));
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static uint64_t rss(void) {
    FILE *f = fopen("/proc/self/statm", "r");
    CHECK(f);
    unsigned long total, resident;
    CHECK(fscanf(f, "%lu %lu", &total, &resident) == 2);
    CHECK(!fclose(f));
    return resident * (uint64_t)sysconf(_SC_PAGESIZE);
}
static void child_main(int command, int ack, int old, int replacement, int cpu, pid_t parent) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent ||
        sched_setaffinity(0, sizeof set, &set) || dup2(old, 70) != 70 || raise(SIGSTOP))
        _exit(10);
    char byte;
    while (read(command, &byte, 1) == 1) {
        if (byte == 'Q')
            _exit(0);
        if (byte == 'B' && dup2(replacement, 70) != 70)
            _exit(11);
        size_t size = byte == 'A' ? 17 : byte == 'B' ? 5 : byte == 'C' ? 7 : 0;
        if (!size || write(70, "owned-identity-io", size) != (ssize_t)size ||
            write(ack, &byte, 1) != 1)
            _exit(12);
    }
    _exit(13);
}
static int drain_to_read(struct xrt_fdflow *flow, struct xrt_fdflow_counter *counter, pid_t child,
                         int fd) {
    uint64_t deadline = now(CLOCK_MONOTONIC) + UINT64_C(10000000000);
    while (now(CLOCK_MONOTONIC) < deadline) {
        struct xrt_fdflow_snapshot s;
        enum xrt_status status = xrt_fdflow_drain(flow, &s);
        if (status != XRT_OK ||
            s.flags & (XRT_FDFLOW_LOSS | XRT_FDFLOW_LOSS_UNKNOWN | XRT_FDFLOW_LATE |
                       XRT_FDFLOW_CPU_PARTIAL | XRT_FDFLOW_THROTTLE))
            return 0;
        int ready = 0;
        for (uint32_t i = 0; i < s.record_count; ++i) {
            const struct xrt_fdflow_record *r = &s.records[i];
            if (r->kind == XRT_FDFLOW_ENTER || r->kind == XRT_FDFLOW_EXIT) {
                if (r->pid != child || r->tid != child)
                    return 0;
                if (r->kind == XRT_FDFLOW_ENTER && r->number == 0 && r->args[0] == (uint64_t)fd)
                    ready = 1;
            }
        }
        if (xrt_fdflow_counter_feed(counter, &s) != XRT_OK)
            return 0;
        if (ready)
            return 1;
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
    return 0;
}
static int poll_bind(struct xrt_fdscan *poller, struct xrt_fdflow_counter *counter, pid_t child) {
    struct xrt_fd_snapshot s;
    if (xrt_fdscan_poll(poller, &s) != XRT_OK || s.process_count != 1 ||
        s.processes[0].pid != child)
        return 0;
    struct xrt_fdflow_bindings *b = NULL;
    if (xrt_fdflow_bindings_create(&s, &b) != XRT_OK)
        return 0;
    if (xrt_fdflow_counter_bind(counter, b) != XRT_OK) {
        xrt_fdflow_bindings_free(b);
        return 0;
    }
    return 1;
}
static int row_bytes(struct xrt_fdflow_counter *c, uint64_t inode, uint64_t bytes, int active) {
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(c, &v);
    for (uint32_t i = 0; i < v.row_count; ++i)
        if (v.rows[i].fd == 70 && v.rows[i].inode == inode && v.rows[i].write_bytes == bytes &&
            v.rows[i].active == active)
            return 1;
    fprintf(stderr,
            "no fd70 row inode=%llu bytes=%llu active=%d; rows=%u total=%llu unknown=%llu\n",
            (unsigned long long)inode, (unsigned long long)bytes, active, v.row_count,
            (unsigned long long)v.write_bytes, (unsigned long long)v.unknown_write);
    return 0;
}
int main(void) {
    uint64_t began = now(CLOCK_MONOTONIC), cpu = now(CLOCK_PROCESS_CPUTIME_ID), before = rss();
    cpu_set_t allowed;
    CHECK(!sched_getaffinity(0, sizeof allowed, &allowed));
    int first = -1;
    for (int i = 0; i < CPU_SETSIZE; ++i)
        if (CPU_ISSET(i, &allowed)) {
            first = i;
            break;
        }
    CHECK(first >= 0);
    int command[2], ack[2];
    CHECK(!pipe(command) && !pipe(ack));
    int old = memfd_create("owned-old", MFD_CLOEXEC),
        replacement = memfd_create("owned-new", MFD_CLOEXEC);
    CHECK(old >= 0 && replacement >= 0 && old != 70 && replacement != 70 && command[0] != 70 &&
          ack[1] != 70);
    struct stat old_stat, new_stat;
    CHECK(!fstat(old, &old_stat) && !fstat(replacement, &new_stat));
    CHECK(old_stat.st_ino != new_stat.st_ino);
    pid_t parent = getpid(), child = fork();
    CHECK(child >= 0);
    if (!child) {
        close(command[1]);
        close(ack[0]);
        child_main(command[0], ack[1], old, replacement, first, parent);
    }
    close(command[0]);
    close(ack[1]);
    int status;
    CHECK(waitpid(child, &status, WUNTRACED) == child && WIFSTOPPED(status));
    struct xrt_fdflow *flow = NULL;
    struct xrt_fdflow_counter *counter = NULL;
    struct xrt_fdscan *poller = NULL;
    struct xrt_fdflow_options opts = {.scoped = 1, .tids = &child, .tid_count = 1};
    struct xrt_perf_failure failure = {0};
    enum xrt_status opened = xrt_fdflow_open(&opts, &flow, &failure);
    int rc = 1;
    if (opened != XRT_OK) {
        fprintf(stderr, "flow open status=%u errno=%d detail=%s\n", opened, failure.error,
                failure.detail ? failure.detail : "none");
        if (opened == XRT_PERMISSION_DENIED)
            rc = 77;
        goto cleanup;
    }
    struct xrt_fdscan_options scan = {
        .max_processes = 1, .max_fds = 256, .max_strings = 32768, .pids = &child, .pid_count = 1};
    if (xrt_fdscan_create(&scan, &poller) != XRT_OK ||
        xrt_fdflow_counter_create(128, 4, 2, &counter) != XRT_OK)
        goto cleanup;
    if (kill(child, SIGCONT) || !drain_to_read(flow, counter, child, command[0]) ||
        !poll_bind(poller, counter, child))
        goto cleanup;
    for (unsigned i = 0; i < 3; ++i) {
        char expected = "ABC"[i], actual;
        if (write(command[1], &expected, 1) != 1 || read(ack[0], &actual, 1) != 1 ||
            actual != expected || !drain_to_read(flow, counter, child, command[0]))
            goto cleanup;
        if (i == 0 && !row_bytes(counter, old_stat.st_ino, 17, 1))
            goto cleanup;
        if (i == 1) {
            struct xrt_fdflow_counts v;
            xrt_fdflow_counter_view(counter, &v);
            if (v.unknown_write < 5 || !row_bytes(counter, old_stat.st_ino, 17, 1) ||
                !poll_bind(poller, counter, child))
                goto cleanup;
        }
        if (i == 2 && (!row_bytes(counter, old_stat.st_ino, 17, 0) ||
                       !row_bytes(counter, new_stat.st_ino, 7, 1)))
            goto cleanup;
    }
    CHECK(!fstat(old, &old_stat) && !fstat(replacement, &new_stat));
    if (old_stat.st_size != 17 || new_stat.st_size != 12)
        goto cleanup;
    struct xrt_fdflow_counts v;
    xrt_fdflow_counter_view(counter, &v);
    if (v.write_bytes != 32 || v.flags)
        goto cleanup;
    printf("{\"old_bytes\":17,\"new_bytes\":7,\"unattributed_after_dup2\":5,\"all_write_bytes\":32,"
           "\"rss_before\":%llu,\"rss_after\":%llu,\"cpu_ns\":%llu,\"wall_ns\":%llu}\n",
           (unsigned long long)before, (unsigned long long)rss(),
           (unsigned long long)(now(CLOCK_PROCESS_CPUTIME_ID) - cpu),
           (unsigned long long)(now(CLOCK_MONOTONIC) - began));
    rc = 0;
cleanup:
    xrt_fdflow_close(flow);
    xrt_fdflow_counter_free(counter);
    xrt_fdscan_destroy(poller);
    if (rc == 0) {
        CHECK(write(command[1], "Q", 1) == 1);
    } else
        CHECK(!kill(child, SIGKILL));
    CHECK(waitpid(child, &status, 0) == child);
    if (rc == 0)
        CHECK(WIFEXITED(status) && !WEXITSTATUS(status));
    close(command[1]);
    close(ack[0]);
    close(old);
    close(replacement);
    if (rc == 77) {
        puts("BLOCKED: owned identity fixture needs existing perf/tracefs access");
        return 77;
    }
    CHECK(!rc);
    puts("owned live fd reuse: old inode history retained, uncertain gap unknown, new inode starts "
         "fresh PASS");
    return 0;
}
