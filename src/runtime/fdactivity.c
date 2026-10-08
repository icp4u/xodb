#define _GNU_SOURCE 1
#include "xrt_fdactivity.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define EVENT_ROWS 4096u
#define DEMAND_NS UINT64_C(3000000000)
struct xrt_fdactivity {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t wake;
    atomic_bool stop;
    uint64_t wanted_until, fast_until, event_until, poll_all_until;
    struct { int32_t pid; uint64_t until; } poll_interest[XRT_FD_INTEREST_MAX];
    int32_t requested_pid;
    uint64_t requested_start, requested_generation;
    struct xrt_fdactivity_view view;
    struct xrt_fdevent_row rows[EVENT_ROWS];
};
static uint64_t now_ns(clockid_t id)
{
    struct timespec t;
    return clock_gettime(id, &t) ? 0 : (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
/* Compare evidence, not sampling clocks. Idle drains must not invalidate pages. */
static void publish_event(struct xrt_fdactivity *a, const struct xrt_fdevent_snapshot *e,
                          uint64_t generation, enum xrt_status status,
                          const struct xrt_perf_failure *failure)
{
    const struct xrt_fdevent_snapshot *old = &a->view.event;
    int changed = generation != a->view.event_generation || status != a->view.event_status;
#define DIFFERENT(field) changed |= old->field != e->field
    DIFFERENT(pid); DIFFERENT(start_ticks); DIFFERENT(started_ns);
    DIFFERENT(flags); DIFFERENT(records); DIFFERENT(lost); DIFFERENT(unpaired);
    DIFFERENT(invalid); DIFFERENT(dropped_rows); DIFFERENT(read_bytes);
    DIFFERENT(write_bytes); DIFFERENT(open_returns); DIFFERENT(close_successes);
    DIFFERENT(dup_returns); DIFFERENT(threads); DIFFERENT(row_count);
    DIFFERENT(running); DIFFERENT(pending); DIFFERENT(ring_bytes);
#undef DIFFERENT
    if (!changed && e->row_count)
        changed = memcmp(a->rows, e->rows, e->row_count * sizeof(*a->rows)) != 0;
    if (changed)
        ++a->view.event_sequence;
    if (e->row_count)
        memcpy(a->rows, e->rows, e->row_count * sizeof(*a->rows));
    a->view.event = *e;
    a->view.event.rows = a->rows;
    a->view.event_generation = generation;
    a->view.event_status = status;
    a->view.event_failure = *failure;
}
static void *owner(void *opaque)
{
    struct xrt_fdactivity *a = opaque;
    struct xrt_fdscan *poller = NULL;
    struct xrt_fdevent *events = NULL;
    uint64_t next_poll = 0, event_generation = 0;
    struct xrt_fdevent_snapshot event = {0};
    struct xrt_perf_failure failure = {0};
    enum xrt_status event_status = XRT_OK;
    const uint64_t cpu_started = now_ns(CLOCK_THREAD_CPUTIME_ID);
    while (!atomic_load(&a->stop)) {
        const uint64_t now = now_ns(CLOCK_MONOTONIC);
        pthread_mutex_lock(&a->lock);
        const int wanted = now < a->wanted_until, event_wanted = now < a->event_until;
        const uint32_t interval = now < a->fast_until ? 250 : 1000;
        const uint64_t generation = a->requested_generation, start = a->requested_start;
        const int32_t pid = a->requested_pid;
        int32_t foreground[XRT_FD_INTEREST_MAX];
        uint32_t nforeground = 0;
        const int all_foreground = now < a->poll_all_until;
        for (uint32_t i = 0; i < XRT_FD_INTEREST_MAX; ++i)
            if (now < a->poll_interest[i].until)
                foreground[nforeground++] = a->poll_interest[i].pid;
        pthread_mutex_unlock(&a->lock);
        if (event_generation != generation || !event_wanted) {
            if (events) {
                (void)xrt_fdevent_drain(events, &event);
                /* Close kernel handles before publishing inactive. Counter
                 * rows remain owned by the handle until close below. */
                xrt_fdevent_stop(events);
                pthread_mutex_lock(&a->lock);
                if (event.row_count <= EVENT_ROWS) {
                    event.running = 0;
                    event.reason = "event demand ended; retained counts cover its last capture";
                    publish_event(a, &event, event_generation, event_status, &failure);
                }
                pthread_mutex_unlock(&a->lock);
                xrt_fdevent_close(events);
                events = NULL;
            }
            if (event_generation != generation) {
                event_generation = generation;
                memset(&event, 0, sizeof(event));
                memset(&failure, 0, sizeof(failure));
                event.pid = pid;
                event.start_ticks = start;
                event_status = XRT_STALE_SNAPSHOT;
                if (event_wanted) {
                    const struct xrt_fdevent_options opts = {.pid = pid,
                                                             .expected_start = start,
                                                             .max_rows = EVENT_ROWS,
                                                             .drain_records = 8192};
                    event_status = xrt_fdevent_open(&opts, &events, &failure);
                    if (event_status != XRT_OK)
                        event.reason = failure.detail;
                }
            }
        }
        if (events)
            event_status = xrt_fdevent_drain(events, &event);
        struct xrt_fd_snapshot *copy = NULL;
        enum xrt_status poll_status = XRT_OK;
        int polled = 0;
        if (wanted && now >= next_poll) {
            polled = 1;
            if (!poller) {
                const struct xrt_fdscan_options opts = {.max_processes = 16384,
                                                        .max_fds = 65536,
                                                        .adaptive = 1,
                                                        .max_strings = 4u << 20,
                                                        .budget_ms = interval == 250 ? 5 : 10};
                poll_status = xrt_fdscan_create(&opts, &poller);
            }
            if (poller) {
                xrt_fdscan_budget(poller, interval == 250 ? 5 : 10);
                (void)xrt_fdscan_interest(poller, foreground, nforeground, all_foreground);
                struct xrt_fd_snapshot snapshot;
                poll_status = xrt_fdscan_poll(poller, &snapshot);
                if (poll_status == XRT_OK) {
                    copy = xrt_fd_snapshot_copy(&snapshot);
                    if (!copy)
                        poll_status = XRT_OUT_OF_MEMORY;
                }
            }
            next_poll = now + (uint64_t)interval * 1000000u;
        }
        pthread_mutex_lock(&a->lock);
        const struct xrt_fd_snapshot *old = NULL;
        if (copy) {
            old = a->view.poll;
            a->view.poll = copy;
        }
        if (polled)
            a->view.poll_status = poll_status;
        if (event_wanted) {
            if (event.row_count <= EVENT_ROWS)
                publish_event(a, &event, event_generation, event_status, &failure);
        }
        a->view.event_requested = event_wanted;
        a->view.poll_active = wanted;
        a->view.interval_ms = interval;
        a->view.updated_ns = now_ns(CLOCK_MONOTONIC);
        if (polled || events)
            ++a->view.generation;
        a->view.owner_cpu_ns = now_ns(CLOCK_THREAD_CPUTIME_ID) - cpu_started;
        pthread_mutex_unlock(&a->lock);
        xrt_fd_snapshot_free((struct xrt_fd_snapshot *)old);
        pthread_mutex_lock(&a->lock);
        if (!atomic_load(&a->stop)) {
            /* Monotonic condition clock; request wakes an idle owner early. */
            const uint64_t deadline = now_ns(CLOCK_MONOTONIC) + (events ? 10000000u : 50000000u);
            const struct timespec until = {(time_t)(deadline / 1000000000u),
                                           (long)(deadline % 1000000000u)};
            (void)pthread_cond_timedwait(&a->wake, &a->lock, &until);
        }
        pthread_mutex_unlock(&a->lock);
    }
    /* Synchronize with destroy's signal/unlock before freeing its mutex. */
    pthread_mutex_lock(&a->lock);
    pthread_mutex_unlock(&a->lock);
    xrt_fdevent_close(events);
    xrt_fdscan_destroy(poller);
    xrt_fd_snapshot_free((struct xrt_fd_snapshot *)a->view.poll);
    pthread_cond_destroy(&a->wake);
    pthread_mutex_destroy(&a->lock);
    free(a);
    return NULL;
}
enum xrt_status xrt_fdactivity_create(struct xrt_fdactivity **out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    *out = NULL;
    struct xrt_fdactivity *a = calloc(1, sizeof(*a));
    if (!a)
        return XRT_OUT_OF_MEMORY;
    atomic_init(&a->stop, 0);
    a->view.poll_status = XRT_STALE_SNAPSHOT;
    a->view.event_status = XRT_STALE_SNAPSHOT;
    a->view.event.rows = a->rows;
    if (pthread_mutex_init(&a->lock, NULL)) {
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    pthread_condattr_t attr;
    int error = pthread_condattr_init(&attr);
    if (!error) {
        error = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
        if (!error)
            error = pthread_cond_init(&a->wake, &attr);
        pthread_condattr_destroy(&attr);
    }
    if (error) {
        pthread_mutex_destroy(&a->lock);
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    pthread_attr_t thread_attr;
    error = pthread_attr_init(&thread_attr);
    if (!error) {
        error = pthread_attr_setdetachstate(&thread_attr, PTHREAD_CREATE_DETACHED);
        if (!error)
            error = pthread_create(&a->thread, &thread_attr, owner, a);
        pthread_attr_destroy(&thread_attr);
    }
    if (error) {
        pthread_cond_destroy(&a->wake);
        pthread_mutex_destroy(&a->lock);
        free(a);
        return XRT_OUT_OF_MEMORY;
    }
    *out = a;
    return XRT_OK;
}
void xrt_fdactivity_destroy(struct xrt_fdactivity *a)
{
    if (!a)
        return;
    /* The worker owns final cleanup. A slow procfs backing-file query cannot
     * stall GUI/server shutdown. Never access a after releasing this lock. */
    pthread_mutex_lock(&a->lock);
    atomic_store(&a->stop, 1);
    pthread_cond_signal(&a->wake);
    pthread_mutex_unlock(&a->lock);
}
enum xrt_status xrt_fdactivity_request(struct xrt_fdactivity *a,
                                       const struct xrt_fdactivity_request *r)
{
    if (!a || !r || (r->interval_ms != 250 && r->interval_ms != 1000) || r->event_pid < 0 ||
        r->poll_pid_count > XRT_FD_INTEREST_MAX || (r->poll_pid_count && !r->poll_pids) ||
        ((r->event_pid == 0) != (r->event_start == 0)) || (r->stop_events && r->event_pid))
        return XRT_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < r->poll_pid_count; ++i)
        if (r->poll_pids[i] <= 0) return XRT_INVALID_ARGUMENT;
    if (pthread_mutex_trylock(&a->lock))
        return XRT_STALE_SNAPSHOT;
    const uint64_t now = now_ns(CLOCK_MONOTONIC);
    if (r->event_pid && now < a->event_until &&
        (a->requested_pid != r->event_pid || a->requested_start != r->event_start)) {
        pthread_mutex_unlock(&a->lock);
        return XRT_INVALID_STATE;
    }
    if (r->stop_events)
        a->event_until = 0;
    a->wanted_until = now + DEMAND_NS;
    if (r->poll_all) a->poll_all_until = now + DEMAND_NS;
    for (uint32_t i = 0; i < r->poll_pid_count; ++i) {
        uint32_t slot = 0;
        for (uint32_t j = 0; j < XRT_FD_INTEREST_MAX; ++j) {
            if (a->poll_interest[j].pid == r->poll_pids[i]) { slot = j; break; }
            if (a->poll_interest[j].until < a->poll_interest[slot].until) slot = j;
        }
        a->poll_interest[slot].pid = r->poll_pids[i];
        a->poll_interest[slot].until = now + DEMAND_NS;
    }
    if (r->interval_ms == 250)
        a->fast_until = now + DEMAND_NS;
    if (r->event_pid) {
        if (now >= a->event_until || a->requested_pid != r->event_pid ||
            a->requested_start != r->event_start) {
            a->requested_pid = r->event_pid;
            a->requested_start = r->event_start;
            ++a->requested_generation;
        }
        a->event_until = now + DEMAND_NS;
    }
    pthread_cond_signal(&a->wake);
    pthread_mutex_unlock(&a->lock);
    return XRT_OK;
}
int xrt_fdactivity_acquire(struct xrt_fdactivity *a, struct xrt_fdactivity_view *view)
{
    if (!a || !view || pthread_mutex_trylock(&a->lock))
        return 0;
    *view = a->view;
    view->requested_event_generation = a->requested_generation;
    view->event_requested = now_ns(CLOCK_MONOTONIC) < a->event_until;
    return 1;
}
void xrt_fdactivity_release(struct xrt_fdactivity *a)
{
    if (a)
        pthread_mutex_unlock(&a->lock);
}
