#define _GNU_SOURCE 1
#include "perf_internal.h"
#include "perf_remote.h"
#include "xrt_remote.h"
#include <errno.h>
#include <linux/perf_event.h>
#include <string.h>
#include <time.h>
static uint32_t sysctl(const char *path)
{
    char bytes[32];
    size_t size;
    uint64_t n;
    return xrt_perf_read_file(path, bytes, sizeof(bytes), &size) &&
                   xrt_perf_unsigned(bytes, size, &n) && n <= UINT32_MAX
               ? (uint32_t)n
               : 0;
}
struct xrt_perf *xrt_cpu_start(const struct xrt_cpu_config *c, struct xrt_cpu_acceptance *a,
                               struct xrt_perf_failure *f)
{
    const char *detail = NULL;
    if (!c || !c->tids || !c->thread_count || c->thread_count > XRT_PERF_MAX_THREADS)
        detail = "select 1..1024 explicit threads";
    else if (!c->frequency_hz)
        detail = "frequency is zero";
    else if (c->event > 2)
        detail = "unsupported event kind";
    else if (!c->data_pages || c->data_pages > 64 || (c->data_pages & (c->data_pages - 1)))
        detail = "data_pages must be a power of two up to 64";
    else if (c->callchain && (!c->max_frames || c->max_frames > 64))
        detail = "max_frames out of range";
    else if (c->user_regs_mask >> 24)
        detail = "user register mask includes an unsupported bit";
    else if (c->user_stack_bytes &&
             (c->user_stack_bytes < 64 || c->user_stack_bytes > 8192 || c->user_stack_bytes % 8))
        detail = "user_stack_bytes must be a multiple of 8 from 64 to 8192";
    else if (c->user_stack_bytes && (c->user_regs_mask & 384) != 384)
        detail = "user stack capture requires the stack pointer and instruction pointer";
    if (detail) {
        xrt_perf_fail(f, "config", 0, -1, detail);
        return NULL;
    }
    for (size_t i = 0; i < c->thread_count; ++i) {
        if (c->tids[i] <= 0) {
            xrt_perf_fail(f, "config", 0, c->tids[i], "tid must be positive");
            return NULL;
        }
        for (size_t j = 0; j < i; ++j)
            if (c->tids[i] == c->tids[j]) {
                xrt_perf_fail(f, "config", 0, c->tids[i], "duplicate tid");
                return NULL;
            }
    }
    memset(a, 0, sizeof(*a));
    a->kernel_max_sample_rate = sysctl("/proc/sys/kernel/perf_event_max_sample_rate");
    a->kernel_max_stack = sysctl("/proc/sys/kernel/perf_event_max_stack");
    if (a->kernel_max_sample_rate && c->frequency_hz > a->kernel_max_sample_rate)
        detail = "frequency exceeds perf_event_max_sample_rate";
    if (c->callchain && a->kernel_max_stack && c->max_frames > a->kernel_max_stack)
        detail = "max_frames exceeds perf_event_max_stack";
    if (detail) {
        xrt_perf_fail(f, "config", 0, -1, detail);
        return NULL;
    }
    struct xrt_perf_attr *attr = &a->attr;
    attr->size = sizeof(*attr);
    attr->sample_period = c->frequency_hz;
    attr->sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_PERIOD;
    if (c->callchain)
        attr->sample_type |= PERF_SAMPLE_CALLCHAIN;
    if (c->include_weight)
        attr->sample_type |= PERF_SAMPLE_WEIGHT;
    if (c->user_regs_mask)
        attr->sample_type |= PERF_SAMPLE_REGS_USER;
    if (c->user_stack_bytes)
        attr->sample_type |= PERF_SAMPLE_STACK_USER;
    attr->flags = UINT64_C(1) | (UINT64_C(1) << 6) | (UINT64_C(1) << 7) | (UINT64_C(1) << 8) |
                  (UINT64_C(1) << 9) | (UINT64_C(1) << 10) | (UINT64_C(1) << 13) |
                  (UINT64_C(1) << 18) | (UINT64_C(1) << 23) | (UINT64_C(1) << 24) |
                  (UINT64_C(1) << 25);
    if (c->mmap_data)
        attr->flags |= UINT64_C(1) << 17;
    if (c->exclude_kernel)
        attr->flags |= (UINT64_C(1) << 5) | (UINT64_C(1) << 21);
    if (c->context_switch)
        attr->flags |= UINT64_C(1) << 26;
    attr->clockid = CLOCK_MONOTONIC;
    attr->sample_max_stack = c->callchain ? c->max_frames : 0;
    attr->sample_regs_user = c->user_regs_mask;
    attr->sample_stack_user = c->user_stack_bytes;
    attr->type = c->event == 2 ? PERF_TYPE_HARDWARE : PERF_TYPE_SOFTWARE;
    attr->config = c->event == 2   ? PERF_COUNT_HW_CPU_CYCLES
                   : c->event == 1 ? PERF_COUNT_SW_CPU_CLOCK
                                   : PERF_COUNT_SW_TASK_CLOCK;
    struct xrt_perf *p = xrt_perf_create(c->data_pages, XRT_PERF_MAX_THREADS, c->ring_budget_bytes);
    if (!p) {
        xrt_perf_fail(f, "alloc", errno, -1, "collector allocation");
        return NULL;
    }
    for (size_t i = 0; i < c->thread_count; ++i)
        if (!xrt_perf_add(p, c->tids[i], attr, 1, NULL, NULL, f))
            goto fail;
    if (!xrt_perf_enable(p, f))
        goto fail;
    return p;
fail:
    if (f)
        f->opened_then_closed += (uint16_t)xrt_perf_fd_count(p);
    xrt_perf_destroy(p);
    return NULL;
}
bool xrt_cpu_enroll(struct xrt_perf *p, int32_t tid, const struct xrt_cpu_acceptance *a,
                    struct xrt_perf_failure *f)
{
    if (p->remote_target)
        return xrt_remote_perf_op(p, XRT_RPC_PERF_ENROLL, (uint32_t)tid, f);
    if (!p->running) {
        xrt_perf_fail(f, "enroll", 0, tid, "collector is not running");
        return false;
    }
    return xrt_perf_add(p, tid, &a->attr, 1, NULL, NULL, f);
}

struct xrt_perf *xrt_cpu_start_target(const struct xrt_target *t, const struct xrt_cpu_config *c,
                                      struct xrt_cpu_acceptance *a, struct xrt_perf_failure *f)
{
    return xrt_target_is_remote(t) ? xrt_remote_cpu_start(t, c, a, f) : xrt_cpu_start(c, a, f);
}
struct xrt_perf *xrt_syscalls_start_target(const struct xrt_target *t, int32_t pid,
                                           const int32_t *tids, size_t count, uint16_t *enter,
                                           uint16_t *exit, struct xrt_perf_failure *f)
{
    return xrt_target_is_remote(t) ? xrt_remote_syscalls_start(t, pid, tids, count, enter, exit, f)
                                   : xrt_syscalls_start(pid, tids, count, enter, exit, f);
}
