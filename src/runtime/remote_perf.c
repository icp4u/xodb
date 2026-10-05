#define _GNU_SOURCE 1
#include "perf_remote.h"
#include "perf_internal.h"
#include "perf_wire.h"
#include "wire_target.h"
#include "remote_internal.h"
#include "target_internal.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
static bool request(struct xrt_perf *p, uint16_t op, uint64_t a, uint64_t b, const void *data,
                    size_t size, void *out, size_t capacity, struct xrt_codec *extra,
                    uint64_t *value, struct xrt_perf_failure *f)
{
    size_t count = 0;
    enum xrt_status status =
        xrt_remote_call(p->remote_target, &(struct xrt_call){.op = op,
                                                             .args = {p->remote_id, a, b},
                                                             .data = data,
                                                             .size = size,
                                                             .out = out,
                                                             .capacity = capacity,
                                                             .length = &count,
                                                             .value = value});
    if (status != XRT_OK) {
        xrt_perf_fail(&p->remote_info.failure, "runtime transport",
                      status == XRT_UNSUPPORTED_ARCHITECTURE ? ENOTSUP : EIO, -1,
                      "remote collector request failed");
        p->remote_info.failed = true;
        if (f)
            *f = p->remote_info.failure;
        return false;
    }
    *extra = xrt_codec(out, count, true);
    bool ok = false;
    xrt_codec_bool(extra, &ok);
    if (!ok) {
        struct xrt_perf_failure failure = {0};
        xrt_wire_perf_failure(extra, &failure);
        if (extra->ok && extra->at == extra->size) {
            if (f)
                *f = failure;
            return false;
        }
    } else {
        struct xrt_perf_info info = {0};
        xrt_wire_perf_info(extra, &info);
        if (extra->ok) {
            p->remote_info = info;
            p->count = info.threads;
            p->running = info.running;
            return true;
        }
    }
    xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
    xrt_perf_fail(f, "runtime protocol", EPROTO, -1, "invalid collector response");
    return false;
}
static struct xrt_perf *start(const struct xrt_target *t, uint16_t op, const void *data,
                              size_t size, struct xrt_cpu_acceptance *cpu, uint16_t *enter,
                              uint16_t *exit, struct xrt_perf_failure *f)
{
    struct xrt_perf *p = calloc(1, sizeof(*p));
    if (!p) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "remote collector allocation");
        return NULL;
    }
    p->remote_target = t;
    uint8_t bytes[1024];
    struct xrt_codec extra;
    uint64_t value = 0;
    if (!request(p, op, 0, 0, data, size, bytes, sizeof(bytes), &extra, &value, f)) {
        free(p);
        return NULL;
    }
    xrt_codec_u64(&extra, &p->remote_id);
    if (cpu)
        xrt_wire_cpu_acceptance(&extra, cpu);
    if (!extra.ok || extra.at != extra.size || !p->remote_id) {
        xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
        xrt_perf_fail(f, "runtime protocol", EPROTO, -1, "invalid collector acceptance");
        free(p);
        return NULL;
    }
    if (enter)
        *enter = (uint16_t)(value >> 16);
    if (exit)
        *exit = (uint16_t)value;
    __atomic_add_fetch(&((struct xrt_target *)t)->remote_collectors, 1, __ATOMIC_SEQ_CST);
    return p;
}
struct xrt_perf *xrt_remote_cpu_start(const struct xrt_target *t,
                                      const struct xrt_cpu_config *config,
                                      struct xrt_cpu_acceptance *a, struct xrt_perf_failure *f)
{
    if (!config || !a || !config->tids || config->thread_count > XRT_PERF_MAX_THREADS) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid collector configuration");
        return NULL;
    }
    uint8_t bytes[8192];
    struct xrt_codec out = xrt_codec(bytes, sizeof(bytes), false);
    struct xrt_cpu_config copy = *config;
    xrt_wire_cpu_config(&out, &copy, NULL);
    if (!out.ok) {
        xrt_perf_fail(f, "config", EINVAL, -1, "collector configuration too large");
        return NULL;
    }
    return start(t, XRT_RPC_CPU_START, bytes, out.at, a, NULL, NULL, f);
}
struct xrt_perf *xrt_remote_syscalls_start(const struct xrt_target *t, int32_t pid,
                                           const int32_t *tids, size_t count, uint16_t *enter,
                                           uint16_t *exit, struct xrt_perf_failure *f)
{
    if (pid != t->pid || !tids || count > XRT_PERF_MAX_THREADS || !enter || !exit) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid syscall configuration");
        return NULL;
    }
    uint8_t bytes[8192];
    struct xrt_codec out = xrt_codec(bytes, sizeof(bytes), false);
    uint32_t n = (uint32_t)count;
    xrt_codec_u32(&out, &n);
    for (size_t i = 0; i < count; ++i) {
        uint32_t tid = (uint32_t)tids[i];
        xrt_codec_u32(&out, &tid);
    }
    return start(t, XRT_RPC_SYSCALLS_START, bytes, out.at, NULL, enter, exit, f);
}
bool xrt_remote_perf_op(struct xrt_perf *p, uint16_t op, uint64_t arg, struct xrt_perf_failure *f)
{
    /* Slot identities never recycle within a capture. Retirement is permanent;
     * do not send another request for every exited thread on every host poll. */
    if (op == XRT_RPC_PERF_RETIRE && arg < XRT_PERF_MAX_THREADS && p->remote_retired[arg])
        return true;
    uint8_t bytes[256];
    struct xrt_codec extra;
    if (!request(p, op, arg, 0, NULL, 0, bytes, sizeof(bytes), &extra, NULL, f))
        return false;
    if (extra.at == extra.size) {
        if (op == XRT_RPC_PERF_RETIRE && arg < XRT_PERF_MAX_THREADS)
            p->remote_retired[arg] = true;
        return true;
    }
    xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
    xrt_perf_fail(f, "runtime protocol", EPROTO, -1, "unexpected collector response bytes");
    return false;
}
void xrt_remote_perf_destroy(struct xrt_perf *p)
{
    if (!xrt_remote_perf_op(p, XRT_RPC_PERF_DESTROY, 0, NULL))
        xrt_remote_fail(p->remote_target, XRT_TRANSPORT_FAILED);
    __atomic_sub_fetch(&((struct xrt_target *)p->remote_target)->remote_collectors, 1,
                       __ATOMIC_SEQ_CST);
    free(p);
}
bool xrt_remote_perf_thread(const struct xrt_perf *p, size_t index, struct xrt_perf_thread *out)
{
    if (!out)
        return false;
    uint8_t bytes[512];
    struct xrt_codec extra;
    if (!request((struct xrt_perf *)p, XRT_RPC_PERF_THREAD, index, 0, NULL, 0, bytes, sizeof(bytes),
                 &extra, NULL, NULL))
        return false;
    struct xrt_perf_thread thread = {0};
    xrt_wire_perf_thread(&extra, &thread);
    if (!extra.ok || extra.at != extra.size) {
        xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
        return false;
    }
    *out = thread;
    return true;
}
enum xrt_perf_drain_status xrt_remote_perf_drain(struct xrt_perf *p, xrt_perf_decoder decode,
                                                 void *context)
{
    uint8_t *bytes = malloc(XRT_RPC_DATA_MAX), *ring = malloc(65536);
    if (!bytes || !ring) {
        free(bytes);
        free(ring);
        return XRT_PERF_DRAIN_MALFORMED;
    }
    enum xrt_perf_drain_status status = XRT_PERF_DRAIN_OK;
    const size_t first = p->cursor, count = p->count;
    bool pending = false;
    for (size_t i = 0; i < count; ++i) {
        const size_t index = (first + i) % count;
        if (p->remote_drained[index])
            continue;
        struct xrt_codec extra;
        if (!request(p, XRT_RPC_PERF_RING, index, 0, NULL, 0, bytes, XRT_RPC_DATA_MAX, &extra, NULL,
                     NULL)) {
            status = XRT_PERF_DRAIN_MALFORMED;
            break;
        }
        bool present = false;
        xrt_codec_bool(&extra, &present);
        if (!present) {
            if (!extra.ok || extra.at != extra.size) {
                xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
                status = XRT_PERF_DRAIN_MALFORMED;
                break;
            }
            if (p->remote_retired[index])
                p->remote_drained[index] = true;
            continue;
        }
        struct xrt_perf_thread thread = {0};
        uint64_t tail = 0;
        uint32_t length = 0;
        xrt_wire_perf_thread(&extra, &thread);
        xrt_codec_u64(&extra, &tail);
        bool more = false;
        xrt_codec_bool(&extra, &more);
        pending |= more;
        xrt_codec_u32(&extra, &length);
        if (!extra.ok || length > 65536 || length != extra.size - extra.at ||
            length > UINT64_MAX - tail) {
            xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
            status = XRT_PERF_DRAIN_MALFORMED;
            break;
        }
        const size_t at = (size_t)(tail & 65535), left = length < 65536 - at ? length : 65536 - at;
        memcpy(ring + at, bytes + extra.at, left);
        memcpy(ring, bytes + extra.at + left, length - left);
        const struct xrt_perf_ring view = {.data = ring,
                                           .size = 65536,
                                           .index = index,
                                           .head = tail + length,
                                           .tail = tail,
                                           .thread = &thread};
        struct xrt_perf_consumed consumed = decode(context, &view);
        if (consumed.bytes > length || (consumed.bytes & 7)) {
            status = XRT_PERF_DRAIN_MALFORMED;
            break;
        }
        if (!request(p, XRT_RPC_PERF_ACK, tail, consumed.bytes, NULL, 0, bytes, XRT_RPC_DATA_MAX,
                     &extra, NULL, NULL)) {
            status = XRT_PERF_DRAIN_MALFORMED;
            break;
        }
        if (extra.at != extra.size) {
            xrt_remote_fail(p->remote_target, XRT_PROTOCOL_ERROR);
            status = XRT_PERF_DRAIN_MALFORMED;
            break;
        }
        status = consumed.status;
        if (status == XRT_PERF_DRAIN_CAPACITY)
            p->cursor = (index + (consumed.bytes != 0)) % count;
        else if (status == XRT_PERF_DRAIN_STOP)
            p->cursor = (index + 1) % count;
        if (status != XRT_PERF_DRAIN_OK)
            break;
    }
    if (status == XRT_PERF_DRAIN_OK && count)
        p->cursor = (first + 1) % count;
    free(bytes);
    free(ring);
    return status == XRT_PERF_DRAIN_OK && pending ? XRT_PERF_DRAIN_CAPACITY : status;
}

void xrt_remote_perf_refresh(struct xrt_perf *p)
{
    xrt_remote_perf_op(p, XRT_RPC_PERF_INFO, 0, NULL);
}
static struct xrt_perf *remote_uprobes_start(const struct xrt_target *t,
                                              const struct xrt_allocation_config *config,
                                              const struct xrt_mapping *mapping, const char *helper,
                                              bool functions, struct xrt_perf_failure *f)
{
    if (!config || !mapping || !config->tids || !config->sources || !config->thread_count ||
        config->thread_count > 32 || !config->source_count ||
        config->source_count > XRT_ALLOCATION_MAX_HOOKS || config->opener) {
        xrt_perf_fail(f, "config", EINVAL, -1, "invalid remote allocation configuration");
        return NULL;
    }
    if (config->cancelled && config->cancelled(config->context)) {
        xrt_perf_fail(f, "allocations.cancel", ECANCELED, -1, "allocation preparation cancelled");
        return NULL;
    }
    uint8_t *bytes = malloc(XRT_RPC_DATA_MAX);
    if (!bytes) {
        xrt_perf_fail(f, "alloc", ENOMEM, -1, "allocation request buffer");
        return NULL;
    }
    struct xrt_codec out = xrt_codec(bytes, XRT_RPC_DATA_MAX, false);
    uint32_t count = (uint32_t)config->thread_count;
    xrt_codec_u32(&out, &count);
    for (size_t i = 0; i < count; ++i) {
        uint32_t tid = (uint32_t)config->tids[i];
        xrt_codec_u32(&out, &tid);
    }
    bool enable = config->enable, stacks = config->callstacks;
    xrt_codec_bool(&out, &enable);
    xrt_codec_bool(&out, &stacks);
    struct xrt_file_request file = {.kind = XRT_FILE_MAPPED, .mapping = *mapping};
    xrt_wire_file_request(&out, &file, NULL, 0);
    count = (uint32_t)config->source_count;
    xrt_codec_u32(&out, &count);
    for (size_t i = 0; i < count; ++i) {
        struct xrt_allocation_source source = config->sources[i];
        if (source.fd != config->sources[0].fd)
            out.ok = false;
        xrt_codec_u16(&out, &source.id);
        if (!functions)
            xrt_codec_u16(&out, &source.kind);
        xrt_codec_u64(&out, &source.offset);
        xrt_wire_file_identity(&out, &source.identity);
    }
    size_t length = helper ? strnlen(helper, 8192) : 0;
    uint32_t n = (uint32_t)length;
    xrt_codec_u32(&out, &n);
    xrt_codec_bytes(&out, (void *)helper, length);
    if (length >= 8192 || !out.ok) {
        free(bytes);
        xrt_perf_fail(f, "config", EINVAL, -1, "allocation request too large");
        return NULL;
    }
    struct xrt_perf *p = start(t, functions ? XRT_RPC_FUNCTION_START : XRT_RPC_ALLOCATIONS_START,
                              bytes, out.at, NULL, NULL, NULL, f);
    free(bytes);
    if (p && config->cancelled && config->cancelled(config->context)) {
        xrt_perf_destroy(p);
        p = NULL;
        xrt_perf_fail(f, "allocations.cancel", ECANCELED, -1, "allocation preparation cancelled");
    }
    return p;
}

struct xrt_perf *xrt_remote_allocations_start(const struct xrt_target *t,
                                              const struct xrt_allocation_config *config,
                                              const struct xrt_mapping *mapping, const char *helper,
                                              struct xrt_perf_failure *f)
{
    return remote_uprobes_start(t, config, mapping, helper, false, f);
}
struct xrt_perf *xrt_remote_functions_start(const struct xrt_target *t,
                                            const struct xrt_allocation_config *config,
                                            const struct xrt_mapping *mapping, const char *helper,
                                            struct xrt_perf_failure *f)
{
    return remote_uprobes_start(t, config, mapping, helper, true, f);
}
