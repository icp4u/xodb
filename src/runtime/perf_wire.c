#include "perf_wire.h"
#include <limits.h>
#include <string.h>
#define U64(v) xrt_codec_u64(c, &(v))
#define U32(v) xrt_codec_u32(c, &(v))
#define U16(v) xrt_codec_u16(c, &(v))
#define U8(v) xrt_codec_u8(c, &(v))
#define BOOL(v) xrt_codec_bool(c, &(v))
static void signed32(struct xrt_codec *c, int32_t *v)
{
    uint32_t n = 0;
    if (!c->read)
        memcpy(&n, v, 4);
    U32(n);
    if (c->ok && c->read)
        memcpy(v, &n, 4);
}
static void count(struct xrt_codec *c, size_t *v, uint32_t max)
{
    if (!c->read && *v > max) {
        c->ok = false;
        return;
    }
    uint32_t n = c->read ? 0 : (uint32_t)*v;
    U32(n);
    if (n > max)
        c->ok = false;
    if (c->read && c->ok)
        *v = n;
}
void xrt_wire_perf_attr(struct xrt_codec *c, struct xrt_perf_attr *a)
{
    U32(a->type);
    U32(a->size);
    U64(a->config);
    U64(a->sample_period);
    U64(a->sample_type);
    U64(a->read_format);
    U64(a->flags);
    U32(a->wakeup_events);
    U32(a->bp_type);
    U64(a->config1);
    U64(a->config2);
    U64(a->branch_sample_type);
    U64(a->sample_regs_user);
    U32(a->sample_stack_user);
    signed32(c, &a->clockid);
    U64(a->sample_regs_intr);
    U32(a->aux_watermark);
    U16(a->sample_max_stack);
    U16(a->reserved_2);
    U32(a->aux_sample_size);
    U32(a->aux_action);
    U64(a->sig_data);
    U64(a->config3);
    U64(a->config4);
}
void xrt_wire_perf_info(struct xrt_codec *c, struct xrt_perf_info *v)
{
    count(c, &v->threads, XRT_PERF_MAX_THREADS);
    count(c, &v->page_size, 1024 * 1024);
    U64(v->allocated_ring_bytes);
    U64(v->ring_data_bytes);
    U64(v->data_offset);
    U32(v->mmap_version);
    BOOL(v->running);
    BOOL(v->failed);
    if (v->failed)
        xrt_wire_perf_failure(c, &v->failure);
}
void xrt_wire_perf_thread(struct xrt_codec *c, struct xrt_perf_thread *t)
{
    signed32(c, &t->tid);
    count(c, &t->event_count, XRT_PERF_MAX_EVENTS);
    for (size_t i = 0; i < t->event_count; ++i)
        U64(t->event_ids[i]);
    U64(t->start_time_ticks);
    U64(t->debugger_id);
    U64(t->enrolled_ns);
    BOOL(t->start_time_known);
    BOOL(t->retiring);
}
void xrt_wire_cpu_config(struct xrt_codec *c, struct xrt_cpu_config *v, int32_t *tids)
{
    count(c, &v->thread_count, XRT_PERF_MAX_THREADS);
    for (size_t i = 0; i < v->thread_count; ++i) {
        int32_t tid = c->read ? 0 : v->tids[i];
        signed32(c, &tid);
        if (c->read)
            tids[i] = tid;
    }
    if (c->read)
        v->tids = tids;
    U32(v->event);
    U32(v->frequency_hz);
    U32(v->user_stack_bytes);
    U16(v->max_frames);
    U8(v->data_pages);
    U64(v->ring_budget_bytes);
    U64(v->user_regs_mask);
    BOOL(v->exclude_kernel);
    BOOL(v->mmap_data);
    BOOL(v->callchain);
    BOOL(v->include_weight);
    BOOL(v->context_switch);
    BOOL(v->follow_threads);
}
void xrt_wire_cpu_acceptance(struct xrt_codec *c, struct xrt_cpu_acceptance *v)
{
    xrt_wire_perf_attr(c, &v->attr);
    U32(v->kernel_max_sample_rate);
    U32(v->kernel_max_stack);
}
void xrt_wire_perf_failure(struct xrt_codec *c, struct xrt_perf_failure *v)
{
    /* Stable diagnostic codes keep decoded strings valid after a collector is
     * destroyed. Unlisted errors still retain kind, errno, TID and rollback. */
    static const char *const details[] = {
        "target collector operation failed",
        "capture ring-data budget exhausted",
        "capture reached 1024 distinct thread identities",
        "capture reached distinct thread identity limit",
        "thread id already recorded; reuse requires a new capture",
        "new task is outside captured process",
        "collector is not running"};
    uint8_t detail = 0;
    if (!c->read && v->detail)
        for (size_t i = 1; i < sizeof(details) / sizeof(details[0]); ++i)
            if (!strcmp(v->detail, details[i]))
                detail = (uint8_t)i;
    uint32_t kind = c->read ? 0 : (uint32_t)v->kind;
    U32(kind);
    if (kind > XRT_PERF_OTHER)
        c->ok = false;
    if (c->read) {
        v->kind = kind;
        v->syscall = "remote perf";
        v->detail = "target collector operation failed";
    }
    signed32(c, &v->error);
    signed32(c, &v->tid);
    U16(v->opened_then_closed);
    U8(detail);
    if (detail >= sizeof(details) / sizeof(details[0]))
        c->ok = false;
    else if (c->read) {
        v->detail = details[detail];
        if (detail)
            v->syscall = "enroll";
    }
}
