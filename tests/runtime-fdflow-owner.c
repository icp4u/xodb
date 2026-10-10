#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdactivity.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Pure stream source; no perf handle or target trace is opened by this test. */
static atomic_int opens, closes, live_handles, deny, idle, read_mode, poll_block, poll_entered, activity_freed;
static void *activity_pointer;
static uint64_t ticks(void) {
    struct timespec t;
    CHECK(!clock_gettime(CLOCK_MONOTONIC, &t));
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void yield(void) {
    struct timespec t = {0, 1000000};
    nanosleep(&t, NULL);
}
struct xrt_fdflow {
    struct xrt_fdflow_snapshot view;
    struct xrt_fdflow_record records[3];
    struct xrt_fdflow_cpu cpu;
};
enum xrt_status xrt_fdflow_open(const struct xrt_fdflow_options *o, struct xrt_fdflow **out,
                                struct xrt_perf_failure *why) {
    CHECK(o && o->scoped && o->tid_count && o->tids);
    *out = NULL;
    atomic_fetch_add(&opens, 1);
    if (atomic_load(&deny)) {
        *why = (struct xrt_perf_failure){.kind = XRT_PERF_PERMISSION,
                                         .error = EACCES,
                                         .syscall = "fixture",
                                         .detail = "synthetic permission denial"};
        return XRT_PERMISSION_DENIED;
    }
    struct xrt_fdflow *f = calloc(1, sizeof *f);
    CHECK(f);
    f->cpu = (struct xrt_fdflow_cpu){.cpu = 0, .active = 1};
    f->view = (struct xrt_fdflow_snapshot){.cpus = &f->cpu,
                                           .records = f->records,
                                           .cpu_count = 1,
                                           .online_cpus = 1,
                                           .active_cpus = 1,
                                           .started_ns = ticks(),
                                           .running = 1,
                                           .scoped = 1,
                                           .reason = "synthetic owned stream"};
    atomic_fetch_add(&live_handles, 1);
    *out = f;
    return XRT_OK;
}
enum xrt_status xrt_fdflow_drain(struct xrt_fdflow *f, struct xrt_fdflow_snapshot *out) {
    CHECK(f);
    uint64_t n = ticks();
    f->view.taken_ns = n;
    f->view.record_count = 0;
    if (f->view.running && !atomic_load(&idle)) {
        f->records[0] = (struct xrt_fdflow_record){.time_ns = n - 2,
                                                   .pid = 100,
                                                   .tid = 100,
                                                   .kind = XRT_FDFLOW_ENTER,
                                                   .operation = XRT_FDFLOW_RAW,
                                                   .number = 1,
                                                   .args = {7}};
        f->records[1] = (struct xrt_fdflow_record){.time_ns = n - 1,
                                                   .pid = 100,
                                                   .tid = 100,
                                                   .kind = XRT_FDFLOW_EXIT,
                                                   .operation = XRT_FDFLOW_RAW,
                                                   .number = 1,
                                                   .result = 17};
        f->records[2] = (struct xrt_fdflow_record){.time_ns = n,
                                                   .pid = 100,
                                                   .tid = 100,
                                                   .kind = XRT_FDFLOW_EXIT,
                                                   .operation = XRT_FDFLOW_WRITE,
                                                   .number = 1,
                                                   .result = 17};
        if (atomic_load(&read_mode)) {
            for (unsigned i = 0; i < 3; ++i)
                f->records[i].number = 0;
            f->records[2].operation = XRT_FDFLOW_READ;
        }
        f->view.record_count = 3;
        f->view.records_seen += 3;
    }
    *out = f->view;
    return XRT_OK;
}
void xrt_fdflow_stop(struct xrt_fdflow *f) {
    CHECK(f);
    if (f->view.running)
        atomic_fetch_sub(&live_handles, 1);
    f->view.running = 0;
}
void xrt_fdflow_close(struct xrt_fdflow *f) {
    if (f) {
        if (f->view.running)
            atomic_fetch_sub(&live_handles, 1);
        atomic_fetch_add(&closes, 1);
        free(f);
    }
}
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *o, struct xrt_fdevent **p,
                                 struct xrt_perf_failure *f) {
    (void)o;
    (void)p;
    (void)f;
    CHECK(0);
    return XRT_INVALID_STATE;
}
void xrt_fdevent_stop(struct xrt_fdevent *p) {
    (void)p;
    CHECK(0);
}
void xrt_fdevent_close(struct xrt_fdevent *p) { CHECK(!p); }
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *p, struct xrt_fdevent_snapshot *s) {
    (void)p;
    (void)s;
    CHECK(0);
    return XRT_INVALID_STATE;
}
static enum xrt_status blocked_poll(struct xrt_fdscan *s, struct xrt_fd_snapshot *out) {
    if (atomic_load(&poll_block)) {
        atomic_store(&poll_entered, 1);
        while (atomic_load(&poll_block))
            yield();
    }
    return xrt_fdscan_poll(s, out);
}
static void watched_free(void *p) {
    int done = p == activity_pointer;
    free(p);
    if (done)
        atomic_store(&activity_freed, 1);
}
#define xrt_fdscan_poll blocked_poll
#define free watched_free
#include "../src/runtime/fdactivity.c"
#undef free
#undef xrt_fdscan_poll
static void request(struct xrt_fdflow_owner *o, int enable) {
    uint64_t end = ticks() + UINT64_C(10000000000);
    for (;;) {
        enum xrt_status s = xrt_fdflow_owner_request(o, enable);
        if (s == XRT_OK)
            return;
        CHECK(s == XRT_STALE_SNAPSHOT && ticks() < end);
        yield();
    }
}
static struct xrt_fdflow_live view(struct xrt_fdflow_owner *o) {
    struct xrt_fdflow_live v;
    uint64_t end = ticks() + UINT64_C(10000000000);
    while (!xrt_fdflow_owner_acquire(o, &v)) {
        CHECK(ticks() < end);
        yield();
    }
    /* Returned pointers are intentionally unusable after releasing. */
    v.counts.rows = NULL;
    v.rates = NULL;
    v.stream.cpus = NULL;
    xrt_fdflow_owner_release(o);
    return v;
}
static void wait_running(struct xrt_fdflow_owner *o, int running, int renew) {
    uint64_t end = ticks() + UINT64_C(10000000000);
    while (view(o).stream.running != running) {
        CHECK(ticks() < end);
        if (renew)
            request(o, 1);
        yield();
    }
}
static void bind_owned(struct xrt_fdflow_owner *o) {
    struct xrt_fd f = {
        .fd = 7, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 1, .inode = 2};
    struct xrt_fd_process p = {.pid = 100, .start = 1, .count = 1};
    struct xrt_fd_snapshot s = {.sequence = 1,
                                .taken_ns = ticks(),
                                .processes = &p,
                                .process_count = 1,
                                .fds = &f,
                                .fd_count = 1};
    struct xrt_fdflow_bindings *b = NULL;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK);
    uint64_t end = ticks() + UINT64_C(10000000000);
    for (;;) {
        enum xrt_status status = xrt_fdflow_owner_bind(o, b);
        if (status == XRT_OK)
            break;
        CHECK(status == XRT_STALE_SNAPSHOT && ticks() < end);
        yield();
    }
}
static void slow_poll(void) {
    int before = atomic_load(&opens);
    int32_t pid = getpid();
    struct xrt_fdactivity *a = NULL;
    struct xrt_fdactivity_options options = {.pids = &pid, .pid_count = 1};
    atomic_store(&poll_block, 1);
    CHECK(xrt_fdactivity_create_scoped(&options, &a) == XRT_OK);
    activity_pointer = a;
    struct xrt_fdactivity_request r = {.interval_ms = 1000, .poll_all = 1};
    uint64_t end = ticks() + UINT64_C(10000000000);
    while (xrt_fdactivity_request(a, &r) != XRT_OK) {
        CHECK(ticks() < end);
        yield();
    }
    while (!atomic_load(&poll_entered)) {
        CHECK(ticks() < end);
        yield();
    }
    CHECK(atomic_load(&opens) == before); /* A real blocked poll did not start tracing. */
    r.flow = 1;
    for (;;) {
        CHECK(ticks() < end);
        enum xrt_status status = xrt_fdactivity_request(a, &r);
        CHECK(status == XRT_OK || status == XRT_STALE_SNAPSHOT);
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(a, &v)) {
            int observed = v.flow.stream.running && v.flow.counts.write_bytes > 17;
            CHECK(!v.poll && atomic_load(&poll_block));
            xrt_fdactivity_release(a);
            if (observed)
                break;
        }
        yield();
    }
    /* Stop also completes while the polling worker remains blocked. */
    r.flow = 0;
    r.stop_flow = 1;
    for (;;) {
        CHECK(ticks() < end);
        enum xrt_status status = xrt_fdactivity_request(a, &r);
        CHECK(status == XRT_OK || status == XRT_STALE_SNAPSHOT);
        struct xrt_fdactivity_view v;
        if (xrt_fdactivity_acquire(a, &v)) {
            int stopped = !v.flow.stream.running && !v.flow.requested;
            CHECK(!v.poll);
            xrt_fdactivity_release(a);
            if (stopped)
                break;
        }
        yield();
    }
    CHECK(atomic_load(&live_handles) == 0);
    atomic_store(&poll_block, 0);
    xrt_fdactivity_destroy(a);
    while (!atomic_load(&activity_freed)) {
        CHECK(ticks() < end);
        yield();
    }
    activity_pointer = NULL;
}
int main(int argc, char **argv) {
    int wrong = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    int expiry = argc == 2 && !strcmp(argv[1], "--expiry");
    slow_poll();
    int32_t pid = getpid();
    struct xrt_fdflow_owner *o = NULL;
    CHECK(xrt_fdflow_owner_create(&pid, 1, &o) == XRT_OK);
    request(o, 1);
    wait_running(o, 1, 1);
    bind_owned(o);
    uint64_t end = ticks() + UINT64_C(10000000000), known = 0;
    int positive_rate = 0;
    while (!known || !positive_rate) {
        CHECK(ticks() < end);
        request(o, 1);
        struct xrt_fdflow_live v;
        if (xrt_fdflow_owner_acquire(o, &v)) {
            if (v.counts.row_count) {
                known = v.counts.rows[0].write_bytes;
                positive_rate = v.rates[0].write > 0;
            }
            xrt_fdflow_owner_release(o);
        }
        yield();
    }
    atomic_store(&idle, 1);
    uint64_t seq = view(o).sequence;
    while (view(o).sequence < seq + 2) {
        CHECK(ticks() < end);
        request(o, 1);
        yield();
    }
    struct xrt_fdflow_live v;
    CHECK(xrt_fdflow_owner_acquire(o, &v));
    CHECK(v.rates[0].write == 0);
    xrt_fdflow_owner_release(o);
    /* Stop while read events still arrive: neither rate may survive stop. */
    atomic_store(&read_mode, 1);
    atomic_store(&idle, 0);
    for (;;) {
        CHECK(ticks() < end);
        request(o, 1);
        int read_active = 0;
        if (xrt_fdflow_owner_acquire(o, &v)) {
            read_active = v.counts.row_count && v.rates[0].read > 0;
            xrt_fdflow_owner_release(o);
        }
        if (read_active)
            break;
        yield();
    }
    if (expiry)
        wait_running(o, 0, 0);
    else {
        request(o, 0);
        wait_running(o, 0, 0);
    }
    CHECK(!view(o).requested);
    while (!xrt_fdflow_owner_acquire(o, &v)) {
        CHECK(ticks() < end);
        yield();
    }
    CHECK(v.counts.row_count && v.rates[0].read == 0 && v.rates[0].write == 0);
    xrt_fdflow_owner_release(o);
    xrt_fdflow_owner_destroy(o);
    atomic_store(&deny, 1);
    CHECK(xrt_fdflow_owner_create(&pid, 1, &o) == XRT_OK);
    int before = atomic_load(&opens);
    request(o, 1);
    end = ticks() + UINT64_C(10000000000);
    while (view(o).status != XRT_PERMISSION_DENIED) {
        CHECK(ticks() < end);
        request(o, 1);
        yield();
    }
    seq = view(o).sequence;
    while (view(o).sequence < seq + 2) {
        CHECK(ticks() < end);
        request(o, 1);
        yield();
    }
    CHECK(view(o).stream.scoped && view(o).requested);
    CHECK(atomic_load(&opens) == before + 1); /* renew does not retry a failed open */
    request(o, 0);
    request(o, 1);
    while (atomic_load(&opens) != before + 2) {
        CHECK(ticks() < end);
        yield();
    }
    xrt_fdflow_owner_destroy(o);
    CHECK(atomic_load(&opens) == atomic_load(&closes) + 2);
    CHECK(known > 0 && known % 17 == (wrong ? 1u : 0u));
    puts("flow owner: independent blocked-poll drain/stop, passive readers, rates, expiry/retry "
         "and cleanup PASS");
    return 0;
}
