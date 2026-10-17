#define _GNU_SOURCE 1
/* Shared target state, independent of the host tracing API. */
#include "target_internal.h"
#include <stdlib.h>
#include <time.h>

uint64_t xrt_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}

struct xrt_target *xrt_target_create(void)
{
    struct xrt_target *t = calloc(1, sizeof(*t));
    if (t) {
        t->remote_collectors = 0; /* Not shared until create returns. */
        t->arch = xrt_arch_native();
        t->identity_admitted = t->arch && xrt_arch_validate(t->arch) == XRT_OK;
        t->next_thread_id = t->next_probe_id = 1;
    }
    return t;
}

void xrt_target_view(const struct xrt_target *t, struct xrt_target_view *out)
{
    if (!t) {
        *out = (struct xrt_target_view){.next_thread_id = 1, .next_probe_id = 1};
        return;
    }
    *out = (struct xrt_target_view){.pid = t->pid,
                                    .state = t->state,
                                    .owned = t->owned,
                                    .follow_processes = t->follow_processes,
                                    .stepping = t->stepping,
                                    .detach_pending = t->detach_pending,
                                    .want_run = t->want_run,
                                    .generation = t->generation,
                                    .image_epoch = t->image_epoch,
                                    .sequence = t->sequence,
                                    .next_thread_id = t->next_thread_id,
                                    .next_probe_id = t->next_probe_id,
                                    .thread_count = t->thread_count,
                                    .event_count = t->event_count,
                                    .breakpoint_count = t->breakpoint_count,
                                    .birth_count = t->birth_count,
                                    .threads = t->threads,
                                    .events = t->events,
                                    .breakpoints = t->breakpoints,
                                    .watchpoints = t->watchpoints,
                                    .births = t->births};
}

int xrt_thread_index(const struct xrt_target *t, int32_t tid)
{
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].tid == tid)
            return (int)i;
    return -1;
}

enum xrt_status xrt_add_thread(struct xrt_target *t, int32_t tid, bool newborn)
{
    if (xrt_thread_index(t, tid) >= 0)
        return XRT_OK;
    if (t->thread_count == XRT_MAX_THREADS)
        return XRT_TOO_MANY_THREADS;
    t->threads[t->thread_count++] = (struct xrt_thread){
        .id = t->next_thread_id++, .tid = tid, .state = XRT_RUNNING, .newborn = newborn};
    return XRT_OK;
}

enum xrt_status xrt_target_stopped_tid(const struct xrt_target *t, int32_t *tid)
{
    if (!t || !tid)
        return XRT_INVALID_ARGUMENT;
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].state == XRT_STOPPED) {
            *tid = t->threads[i].tid;
            return XRT_OK;
        }
    return XRT_NOT_STOPPED;
}

int xrt_breakpoint_index(const struct xrt_target *t, uint64_t id)
{
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (t->breakpoints[i].id == id)
            return (int)i;
    return -1;
}
