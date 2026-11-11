#define _GNU_SOURCE 1
#include "perf_internal.h"
#include "perf_regs.h"
#include "perf_remote.h"
#include "xrt_remote.h"
#include <errno.h>
#include <linux/perf_event.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
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
static const char ring_pinned_detail[] =
    "ring mmap failed; pinned pages exceeded perf_event_mlock_kb times online CPUs plus RLIMIT_MEMLOCK";
static const char shrunk_notice[] =
    "per-thread rings were shrunk after mmap returned EPERM; the limit is perf_event_mlock_kb times online CPUs plus RLIMIT_MEMLOCK";
static const char capped_notice[] =
    "opened a prefix of threads after per-thread mmap returned EPERM; the limit is perf_event_mlock_kb times online CPUs plus RLIMIT_MEMLOCK";
static const char byte_shrunk_notice[] =
    "per-thread rings were sized in bytes against perf_event_mlock_kb times online CPUs plus RLIMIT_MEMLOCK";
static const char byte_capped_notice[] =
    "opened a prefix of threads after rings were sized in bytes against perf_event_mlock_kb times online CPUs plus RLIMIT_MEMLOCK";
static bool ring_pinned(const struct xrt_perf_failure *f)
{
    return f && f->error == EPERM && f->syscall && !strcmp(f->syscall, "mmap");
}
static void close_failed(struct xrt_perf *p, struct xrt_perf_failure *f)
{
    if (f)
        f->opened_then_closed = (uint16_t)(f->opened_then_closed + xrt_perf_fd_count(p));
    xrt_perf_destroy(p);
}
static bool add_n(struct xrt_perf *p, const struct xrt_cpu_config *c, size_t count,
                  const struct xrt_perf_attr *attr, struct xrt_perf_failure *f)
{
    for (size_t i = 0; i < count; ++i)
        if (!xrt_perf_add(p, c->tids[i], attr, 1, NULL, NULL, f)) {
            if (!c->exclude_kernel && f && (f->error == EPERM || f->error == EACCES) && f->syscall &&
                !strcmp(f->syscall, "perf_event_open"))
                f->detail =
                    "kernel stacks need perf_event_paranoid at most 1, or root; this program does not change that setting";
            return false;
        }
    return xrt_perf_enable(p, f);
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
    else if (c->user_regs_mask >> XODB_PERF_USER_REGS_LIMIT)
        detail = "user register mask includes an unsupported bit";
    else if (c->user_stack_bytes &&
             (c->user_stack_bytes < 64 || c->user_stack_bytes > 8192 || c->user_stack_bytes % 8))
        detail = "user_stack_bytes must be a multiple of 8 from 64 to 8192";
    else if (c->user_stack_bytes &&
             (c->user_regs_mask & XODB_PERF_USER_REGS_REQUIRED) != XODB_PERF_USER_REGS_REQUIRED)
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
    /* Bit 5 drops kernel instruction pointers. Bit 21 drops the kernel part
     * of PERF_SAMPLE_CALLCHAIN. A kernel-stack capture leaves both clear.
     * There is no second open that turns them back on. */
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
    if (!c->exclude_kernel) {
        const char *hook = getenv("XODB_TEST_KERNEL_STACKS");
        if (hook && !strcmp(hook, "deny")) {
            xrt_perf_fail(f, "perf_event_open", EPERM, -1,
                          "kernel stacks need perf_event_paranoid at most 1, or root; this program does not change that setting");
            return NULL;
        }
    }
    unsigned pages = c->data_pages;
    size_t plan = c->thread_count;
    bool planned = false;
    /* The mmap hook must see the requested page count. A real open sizes
     * each ring in bytes against the pinned allowance before the first mmap,
     * so a larger page does not pin four times the bytes of a smaller one. */
    if (!getenv("XODB_TEST_RING_MMAP")) {
        unsigned long remaining = 0;
        if (xrt_perf_pinned_remaining(&remaining)) {
            unsigned fitted = xrt_perf_fit_pages(pages, plan);
            if ((uint64_t)plan * (1u + fitted) > remaining) {
                size_t fit = (size_t)(remaining / (1u + fitted));
                if (fit > 0 && fit < plan) {
                    plan = fit;
                    planned = true;
                }
            }
            if (fitted != pages)
                planned = true;
            pages = fitted;
        }
    }
    bool report_plan = planned;
    for (;;) {
        struct xrt_perf *p = xrt_perf_create(pages, XRT_PERF_MAX_THREADS, c->ring_budget_bytes);
        if (!p) {
            xrt_perf_fail(f, "alloc", errno, -1, "collector allocation");
            return NULL;
        }
        if (add_n(p, c, plan, attr, f)) {
            if (plan < c->thread_count) {
                p->ring_limit = XRT_RING_LIMIT_CAPPED;
                p->ring_planned = report_plan;
                if (f)
                    memset(f, 0, sizeof(*f));
            } else if (pages != c->data_pages) {
                p->ring_limit = XRT_RING_LIMIT_SHRUNK;
                p->ring_planned = report_plan;
                if (f)
                    memset(f, 0, sizeof(*f));
            }
            return p;
        }
        report_plan = false;
        const bool pinned = ring_pinned(f);
        /* One data page still does not fit every thread. Keep the prefix
         * whose rings mapped. A later enroll that hits the same ceiling
         * fails; the capture stops and does not keep running. */
        if (pinned && pages == 1 && p->count > 0) {
            struct xrt_perf_failure enable_failure = {0};
            if (xrt_perf_enable(p, &enable_failure)) {
                p->ring_limit = XRT_RING_LIMIT_CAPPED;
                if (f)
                    memset(f, 0, sizeof(*f));
                return p;
            }
            if (f)
                *f = enable_failure;
            close_failed(p, f);
            return NULL;
        }
        if (pinned && f)
            f->detail = ring_pinned_detail;
        close_failed(p, f);
        if (!(pinned && pages > 1))
            return NULL;
        pages /= 2;
    }
}
enum xrt_ring_limit xrt_cpu_ring_limit(const struct xrt_perf *p)
{
    if (!p)
        return XRT_RING_LIMIT_NONE;
    if (p->remote_target)
        return p->limit_known ? p->ring_limit : XRT_RING_LIMIT_NONE;
    return p->ring_limit;
}
const char *xrt_cpu_ring_notice(const struct xrt_perf *p)
{
    if (!p || (p->remote_target && !p->limit_known))
        return NULL;
    if (p->ring_limit == XRT_RING_LIMIT_SHRUNK)
        return p->ring_planned ? byte_shrunk_notice : shrunk_notice;
    if (p->ring_limit == XRT_RING_LIMIT_CAPPED)
        return p->ring_planned ? byte_capped_notice : capped_notice;
    return NULL;
}
bool xrt_cpu_limit_carried(const struct xrt_perf *p)
{
    return p && p->remote_target && p->limit_known;
}
size_t xrt_cpu_unsampled(const struct xrt_perf *p, int32_t *out, size_t cap)
{
    if (!p || !p->limit_known)
        return 0;
    size_t n = p->unsampled_count;
    size_t copy = n < cap ? n : cap;
    if (out && copy)
        memcpy(out, p->unsampled, copy * sizeof(int32_t));
    return n;
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
    if (xrt_perf_add(p, tid, &a->attr, 1, NULL, NULL, f))
        return true;
    if (ring_pinned(f))
        f->detail = ring_pinned_detail;
    return false;
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
