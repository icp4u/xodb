#define _GNU_SOURCE 1
#include "perf_remote.h"
#include "perf_internal.h"
#include "perf_wire.h"
#include "target_internal.h"
#include "wire_target.h"
#include "../profile/allocation_broker.h"
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
struct collector {
    uint64_t id;
    struct xrt_target *target;
    struct xrt_perf *perf;
    struct xrt_allocations *allocations;
    struct xrt_cpu_acceptance cpu;
    bool is_cpu, pending, follow;
    struct xrt_perf_ring offered;
    uint64_t offered_bytes;
};
struct xrt_agent_perf {
    struct collector slots[32];
    uint64_t next_id;
    int32_t tids[XRT_PERF_MAX_THREADS];
    char path[8192], helper[8192];
    struct xrt_allocation_source sources[XRT_ALLOCATION_MAX_HOOKS];
};
struct xrt_agent_perf *xrt_agent_perf_create(void)
{
    return calloc(1, sizeof(struct xrt_agent_perf));
}
void xrt_agent_perf_destroy(struct xrt_agent_perf *a)
{
    if (!a)
        return;
    for (unsigned i = 0; i < 32; ++i) {
        if (a->slots[i].allocations)
            xrt_allocations_destroy(a->slots[i].allocations);
        else
            xrt_perf_destroy(a->slots[i].perf);
    }
    free(a);
}
bool xrt_agent_perf_uses(struct xrt_agent_perf *a, const struct xrt_target *t)
{
    for (unsigned i = 0; i < 32; ++i)
        if (a->slots[i].perf && a->slots[i].target == t)
            return true;
    return false;
}
static bool held(struct xrt_target *t, const int32_t *tids, size_t count)
{
    if (!count || count > XRT_PERF_MAX_THREADS || t->core || t->state != XRT_STOPPED)
        return false;
    for (size_t i = 0; i < count; ++i) {
        const int at = xrt_thread_index(t, tids[i]);
        if (at < 0 || t->threads[at].state != XRT_STOPPED)
            return false;
    }
    return true;
}
static void result(struct xrt_codec *out, bool ok, struct xrt_perf *p,
                   struct xrt_perf_failure *failure)
{
    xrt_codec_bool(out, &ok);
    if (!ok) {
        xrt_wire_perf_failure(out, failure);
        return;
    }
    struct xrt_perf_info info = {0};
    if (p)
        xrt_perf_info(p, &info);
    xrt_wire_perf_info(out, &info);
}
struct broker {
    int fd, pid, target;
};
static int broker_open(void *raw, int32_t tid, int group, int file, uint64_t offset, bool returning,
                       bool leader, bool stacks)
{
    struct broker *b = raw;
    return xodb_allocation_broker_open(b->fd, b->target, tid, file, group, offset, returning,
                                       leader, stacks, NULL, NULL);
}
static struct xrt_allocations *allocations_open(struct xrt_agent_perf *a, struct xrt_target *t,
                                                struct xrt_codec *in, struct xrt_perf_failure *f)
{
    uint32_t count = 0;
    xrt_codec_u32(in, &count);
    if (count > 32 || !count)
        return NULL;
    for (uint32_t i = 0; i < count; ++i) {
        uint32_t tid = 0;
        xrt_codec_u32(in, &tid);
        if (tid > INT32_MAX)
            in->ok = false;
        a->tids[i] = (int32_t)tid;
    }
    struct xrt_allocation_config config = {
        .pid = t->pid, .tids = a->tids, .thread_count = count, .sources = a->sources};
    xrt_codec_bool(in, &config.enable);
    xrt_codec_bool(in, &config.callstacks);
    struct xrt_file_request file = {0};
    xrt_wire_file_request(in, &file, a->path, sizeof(a->path));
    xrt_codec_u32(in, &count);
    if (count > XRT_ALLOCATION_MAX_HOOKS || !count)
        return NULL;
    config.source_count = count;
    for (uint32_t i = 0; i < count; ++i) {
        struct xrt_allocation_source *source = &a->sources[i];
        xrt_codec_u16(in, &source->id);
        xrt_codec_u16(in, &source->kind);
        xrt_codec_u64(in, &source->offset);
        xrt_wire_file_identity(in, &source->identity);
    }
    uint32_t length = 0;
    xrt_codec_u32(in, &length);
    if (!in->ok || length >= sizeof(a->helper))
        return NULL;
    xrt_codec_bytes(in, a->helper, length);
    a->helper[length] = 0;
    if (!in->ok || in->at != in->size || memchr(a->helper, 0, length) ||
        file.kind != XRT_FILE_MAPPED || !held(t, config.tids, config.thread_count))
        return NULL;
    int fd = -1;
    enum xrt_status status = xrt_target_file(t, &file, &fd);
    if (status != XRT_OK) {
        xrt_perf_fail(f, "allocations.file", ENOENT, -1, "target mapped file unavailable");
        return NULL;
    }
    for (uint32_t i = 0; i < count; ++i)
        a->sources[i].fd = fd;
    struct broker broker = {.fd = -1, .pid = -1, .target = t->pid};
    if (length) {
        if (xodb_allocation_broker_start(a->helper, &broker.fd, &broker.pid)) {
            close(fd);
            xrt_perf_fail(f, "allocations.helper", errno, -1, "target helper start failed");
            return NULL;
        }
        config.opener = broker_open;
        config.context = &broker;
    }
    struct xrt_allocations *result = xrt_allocations_start(&config, f);
    xodb_allocation_broker_close(broker.fd, broker.pid);
    close(fd);
    return result;
}
enum xrt_status xrt_agent_perf_dispatch(struct xrt_agent_perf *a, struct xrt_target *t, uint16_t op,
                                        const uint64_t *args, void *bytes, size_t size,
                                        uint64_t *value, void *extra, size_t *extra_size)
{
    struct xrt_codec in = xrt_codec(bytes, size, true),
                     out = xrt_codec(extra, XRT_RPC_DATA_MAX, false);
    struct xrt_perf_failure failure = {.kind = XRT_PERF_CONFIGURATION,
                                       .syscall = "remote perf",
                                       .detail = "invalid collector operation",
                                       .error = EINVAL,
                                       .tid = -1};
    struct collector *slot = NULL;
    bool ok = false;
    const bool opening =
        op == XRT_RPC_CPU_START || op == XRT_RPC_SYSCALLS_START || op == XRT_RPC_ALLOCATIONS_START;
    if (!a || !t)
        return XRT_INVALID_ARGUMENT;
    if (opening) {
        /* Current host decoders support x86-64 Linux perf record layouts. */
        if (t->arch->machine != XRT_X86_64)
            return XRT_UNSUPPORTED_ARCHITECTURE;
        for (unsigned i = 0; i < 32; ++i)
            if (!a->slots[i].perf) {
                slot = &a->slots[i];
                break;
            }
        if (!slot || a->next_id == UINT64_MAX)
            return XRT_PROCESS_LIMIT;
        memset(slot, 0, sizeof(*slot));
        if (op == XRT_RPC_ALLOCATIONS_START) {
            slot->allocations = allocations_open(a, t, &in, &failure);
            if (slot->allocations)
                slot->perf = xrt_allocations_perf(slot->allocations);
        } else if (op == XRT_RPC_CPU_START) {
            struct xrt_cpu_config config = {0};
            xrt_wire_cpu_config(&in, &config, a->tids);
            if (!in.ok || in.at != in.size || !held(t, config.tids, config.thread_count))
                goto reply;
            slot->perf = xrt_cpu_start(&config, &slot->cpu, &failure);
            slot->is_cpu = true;
            slot->follow = config.follow_threads;
        } else {
            uint32_t count = 0;
            xrt_codec_u32(&in, &count);
            if (count > XRT_PERF_MAX_THREADS)
                return XRT_INVALID_ARGUMENT;
            for (uint32_t i = 0; i < count; ++i) {
                uint32_t tid = 0;
                xrt_codec_u32(&in, &tid);
                if (tid > INT32_MAX)
                    in.ok = false;
                a->tids[i] = (int32_t)tid;
            }
            if (!in.ok || in.at != in.size || !held(t, a->tids, count))
                goto reply;
            uint16_t enter = 0, exit = 0;
            slot->perf = xrt_syscalls_start(t->pid, a->tids, count, &enter, &exit, &failure);
            *value = ((uint64_t)enter << 16) | exit;
        }
        ok = slot->perf != NULL;
        if (ok) {
            slot->id = ++a->next_id;
            slot->target = t;
            for (size_t i = 0; i < slot->perf->count; ++i) {
                int at = xrt_thread_index(t, slot->perf->slots[i].thread.tid);
                if (at >= 0)
                    slot->perf->slots[i].thread.debugger_id = t->threads[at].id;
            }
        }
    } else {
        if (size)
            return XRT_INVALID_ARGUMENT;
        for (unsigned i = 0; i < 32; ++i)
            if (a->slots[i].perf && a->slots[i].id == args[0] && a->slots[i].target == t) {
                slot = &a->slots[i];
                break;
            }
        if (!slot)
            return XRT_INVALID_ARGUMENT;
        switch (op) {
        case XRT_RPC_PERF_INFO:
            ok = true;
            break;
        case XRT_RPC_PERF_DESTROY:
            if (slot->allocations)
                xrt_allocations_destroy(slot->allocations);
            else
                xrt_perf_destroy(slot->perf);
            slot->allocations = NULL;
            slot->perf = NULL;
            ok = true;
            break;
        case XRT_RPC_PERF_ENABLE:
            ok = slot->allocations ? xrt_allocations_enable(slot->allocations, &failure)
                                   : xrt_perf_enable(slot->perf, &failure);
            break;
        case XRT_RPC_PERF_STOP:
            ok = xrt_perf_stop(slot->perf, &failure);
            break;
        case XRT_RPC_PERF_RETIRE:
            ok = args[1] <= SIZE_MAX && xrt_perf_retire(slot->perf, (size_t)args[1], &failure);
            break;
        case XRT_RPC_PERF_ENROLL: {
            if (!slot->is_cpu || args[1] > INT32_MAX)
                break;
            int tid = (int)args[1], index = xrt_thread_index(t, tid);
            if (index < 0 || t->threads[index].state != XRT_STOPPED)
                break;
            ok = xrt_cpu_enroll(slot->perf, tid, &slot->cpu, &failure);
            break;
        }
        case XRT_RPC_PERF_THREAD: {
            struct xrt_perf_thread thread = {0};
            ok = args[1] <= SIZE_MAX && xrt_perf_thread(slot->perf, (size_t)args[1], &thread);
            result(&out, ok, slot->perf, &failure);
            if (ok)
                xrt_wire_perf_thread(&out, &thread);
            goto done;
        }
        case XRT_RPC_PERF_RING: {
            struct xrt_perf_ring ring = {0};
            slot->pending = false;
            enum xrt_perf_drain_status status =
                args[1] > SIZE_MAX ? XRT_PERF_DRAIN_MALFORMED
                                   : xrt_perf_peek(slot->perf, (size_t)args[1], &ring);
            if (status != XRT_PERF_DRAIN_OK) {
                failure.error = EPROTO;
                break;
            }
            result(&out, true, slot->perf, &failure);
            bool present = ring.size != 0;
            xrt_codec_bool(&out, &present);
            if (present) {
                xrt_wire_perf_thread(&out, (struct xrt_perf_thread *)ring.thread);
                uint64_t tail = ring.tail;
                xrt_codec_u64(&out, &tail);
                const size_t limit = out.size - out.at - 5;
                uint64_t available = ring.head - ring.tail;
                size_t count = 0;
                while (count < available && available - count >= 8) {
                    uint8_t header[8];
                    xrt_perf_copy(ring.data, ring.size, ring.tail + count, header, 8);
                    uint16_t length;
                    memcpy(&length, header + 6, 2);
                    if (length < 8 || (length & 7) || length > available - count) {
                        failure.error = EPROTO;
                        out.at = 0;
                        goto reply;
                    }
                    if (length > limit - count)
                        break;
                    count += length;
                }
                if (!count && available) {
                    failure.error = EPROTO;
                    out.at = 0;
                    goto reply;
                }
                bool more = available > count;
                xrt_codec_bool(&out, &more);
                uint32_t n = (uint32_t)count;
                xrt_codec_u32(&out, &n);
                if (count) {
                    xrt_perf_copy(ring.data, ring.size, ring.tail, (uint8_t *)extra + out.at,
                                  count);
                    out.at += count;
                }
                slot->offered = ring;
                slot->offered_bytes = count;
                slot->pending = true;
            }
            goto done;
        }
        case XRT_RPC_PERF_ACK:
            if (!slot->pending || args[1] != slot->offered.tail || args[2] > slot->offered_bytes ||
                (args[2] & 7))
                break;
            /* A byte count must end on a complete record, not merely on an
             * eight-byte boundary inside a record. Failed ACKs retain data. */
            for (uint64_t at = 0; at < args[2];) {
                uint8_t header[8];
                if (!xrt_perf_copy(slot->offered.data, slot->offered.size, slot->offered.tail + at,
                                   header, 8))
                    goto reply;
                uint16_t length;
                memcpy(&length, header + 6, 2);
                if (length < 8 || (length & 7) || length > args[2] - at)
                    goto reply;
                at += length;
            }
            ok = xrt_perf_commit(
                     slot->perf, &slot->offered,
                     (struct xrt_perf_consumed){.bytes = args[2], .status = XRT_PERF_DRAIN_OK}) ==
                 XRT_PERF_DRAIN_OK;
            slot->pending = false;
            break;
        default:
            return XRT_INVALID_ARGUMENT;
        }
    }
reply:
    result(&out, ok, slot ? slot->perf : NULL, &failure);
    if (ok && opening) {
        uint64_t id = slot->id;
        xrt_codec_u64(&out, &id);
        if (slot->is_cpu)
            xrt_wire_cpu_acceptance(&out, &slot->cpu);
    }
done:
    if (!out.ok)
        return XRT_BUFFER_TOO_SMALL;
    *extra_size = out.at;
    return XRT_OK;
}

void xrt_agent_perf_observe(struct xrt_agent_perf *a, struct xrt_target *t,
                            const struct xrt_thread *thread, bool same_group)
{
    for (unsigned i = 0; i < 32; ++i) {
        struct collector *c = &a->slots[i];
        if (!c->perf || c->target != t || !c->is_cpu || !c->follow || !c->perf->running ||
            c->perf->failed)
            continue;
        if (!same_group) {
            /* The fork record/target snapshot carries the scope boundary.
             * Retain queued evidence for the host to classify and drain. */
            xrt_perf_stop(c->perf, NULL);
            continue;
        }
        if (!xrt_cpu_enroll(c->perf, thread->tid, &c->cpu, &c->perf->failure)) {
            c->perf->failed = true;
            xrt_perf_stop(c->perf, NULL);
            continue;
        }
        c->perf->slots[c->perf->count - 1].thread.debugger_id = thread->id;
        c->perf->slots[c->perf->count - 1].thread.enrolled_ns = xrt_now();
    }
}
