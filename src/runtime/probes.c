#define _GNU_SOURCE 1
#include "target_internal.h"

int xrt_breakpoint_at(const struct xrt_target *t, uint64_t address)
{
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (!t->breakpoints[i].pending && t->breakpoints[i].address == address)
            return (int)i;
    return -1;
}
int xrt_breakpoint_index(const struct xrt_target *t, uint64_t id)
{
    for (size_t i = 0; i < t->breakpoint_count; ++i)
        if (t->breakpoints[i].id == id)
            return (int)i;
    return -1;
}
enum xrt_status xrt_target_patch_span(struct xrt_target *t, int32_t tid, uint64_t address,
                                      const uint8_t *bytes, size_t width, size_t *accepted)
{
    if (!accepted)
        return XRT_INVALID_ARGUMENT;
    *accepted = 0;
    if (!t || !bytes || width < 1 || width > 4 || address > UINT64_MAX - width)
        return XRT_INVALID_ARGUMENT;
    if (t->patch)
        return t->patch(t->patch_ctx, tid, address, bytes, width, accepted);
    return xrt_memory_patch(tid, address, bytes, width, accepted);
}
enum xrt_status xrt_patch_instruction_tid(struct xrt_target *t, int32_t tid, uint64_t address,
                                          const uint8_t *bytes, size_t width)
{
    if (!t->arch || !xrt_arch_breakpoint_valid(t->arch->machine, address, width))
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    size_t count = 0;
    const enum xrt_status result = xrt_target_patch_span(t, tid, address, bytes, width, &count);
    if (result == XRT_OK && count == width)
        return XRT_OK;
    return count ? XRT_PARTIAL_MEMORY_WRITE : result;
}
enum xrt_status xrt_patch_instruction(struct xrt_target *t, uint64_t address, const uint8_t *bytes,
                                      size_t width)
{
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    return xrt_patch_instruction_tid(t, tid, address, bytes, width);
}
enum xrt_status xrt_target_commit_plant(struct xrt_target *t, uint64_t address,
                                        const struct xrt_probe_encoding *encoding,
                                        const uint8_t original[4])
{
    if (!t || !encoding || !original)
        return XRT_INVALID_ARGUMENT;
    if (!t->identity_admitted)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    if (encoding->width < 1 || encoding->width > 4)
        return XRT_INVALID_ARGUMENT;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    size_t accepted = 0;
    const enum xrt_status status =
        xrt_target_patch_span(t, tid, address, encoding->bytes, encoding->width, &accepted);
    if (status == XRT_OK && accepted == encoding->width)
        return XRT_OK;
    if (!accepted)
        return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
    size_t restored = 0;
    const enum xrt_status back =
        xrt_target_patch_span(t, tid, address, original, accepted, &restored);
    if (back == XRT_OK && restored == accepted)
        return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
    t->plant_cleanup.active = 1;
    t->plant_cleanup.address = address;
    t->plant_cleanup.width = encoding->width;
    memcpy(t->plant_cleanup.original, original, 4);
    return XRT_PARTIAL_MEMORY_WRITE;
}
enum xrt_status xrt_target_retry_plant_cleanup(struct xrt_target *t)
{
    if (!t || !t->plant_cleanup.active)
        return XRT_OK;
    if (!t->identity_admitted)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    size_t accepted = 0;
    const enum xrt_status status = xrt_target_patch_span(
        t, tid, t->plant_cleanup.address, t->plant_cleanup.original, t->plant_cleanup.width,
        &accepted);
    if (status == XRT_OK && accepted == t->plant_cleanup.width) {
        t->plant_cleanup.active = 0;
        return XRT_OK;
    }
    return status != XRT_OK ? status : XRT_PARTIAL_MEMORY_WRITE;
}
enum xrt_status xrt_target_read(const struct xrt_target *t, uint64_t address, void *out,
                                size_t size, size_t *count)
{
    if (!count || (!out && size))
        return XRT_INVALID_ARGUMENT;
    *count = 0;
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_READ,
                                                     .args = {address, size},
                                                     .out = out,
                                                     .capacity = size,
                                                     .length = count});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (!size)
        return XRT_OK;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    const enum xrt_status result = xrt_memory_read(tid, address, out, size, count);
    if (result != XRT_OK)
        return result == XRT_INVALID_ADDRESS ? result : XRT_MEMORY_UNREADABLE;
    uint8_t *bytes = out;
    for (size_t b = 0; b < t->breakpoint_count; ++b) {
        const struct xrt_breakpoint *p = &t->breakpoints[b];
        if (!p->patched || !p->width)
            continue;
        for (size_t i = 0; i < p->width; ++i) {
            const uint64_t at = p->address + i;
            if (at >= address && at - address < *count)
                bytes[at - address] = p->original[i];
        }
    }
    return XRT_OK;
}
enum xrt_status xrt_target_write(struct xrt_target *t, uint64_t address, const void *data,
                                 size_t size)
{
    if (t && t->connection)
        return xrt_remote_call(
            t,
            &(struct xrt_call){.op = XRT_RPC_WRITE, .args = {address}, .data = data, .size = size});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (size > 4096 || address > UINT64_MAX - size)
        return XRT_INVALID_ADDRESS;
    if (!data && size)
        return XRT_INVALID_ARGUMENT;
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    const uint8_t *bytes = data;
    size_t written = 0;
    enum xrt_status result = XRT_OK;
    for (; written < size; ++written) {
        const uint64_t at = address + written;
        struct xrt_breakpoint *overlay = NULL;
        for (size_t i = 0; i < t->breakpoint_count; ++i) {
            struct xrt_breakpoint *p = &t->breakpoints[i];
            if (p->patched && p->width && at >= p->address && at - p->address < p->width) {
                overlay = p;
                break;
            }
        }
        if (!overlay) {
            size_t count;
            result = xrt_memory_patch(tid, at, &bytes[written], 1, &count);
            if (result != XRT_OK) {
                if (written)
                    result = XRT_PARTIAL_MEMORY_WRITE;
                break;
            }
        }
        if (overlay)
            overlay->original[at - overlay->address] = bytes[written];
    }
    if (written) {
        xrt_target_event(t, XRT_EVENT_MEMORY_WRITTEN, t->pid, (int64_t)written);
        t->events[t->event_count - 1].address = address;
    }
    return result;
}
static enum xrt_status admitted_native(const struct xrt_target *t)
{
    if (!t || !t->identity_admitted || !t->arch || t->arch != xrt_arch_native())
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return XRT_OK;
}
static enum xrt_status prepare_probe(struct xrt_target *t, uint64_t address, uint8_t original[4],
                                     struct xrt_probe_encoding *encoding)
{
    uint8_t raw[4] = {0};
    size_t count = 0;
    const enum xrt_status read = xrt_target_read(t, address, raw, sizeof(raw), &count);
    if (read != XRT_OK)
        return read;
    const struct xrt_probe_request request = {.address = address,
                                              .isa_mode = t->arch->isa_mode,
                                              .bytes = raw,
                                              .size = count};
    const enum xrt_status prepared = xrt_arch_probe_prepare(t->arch, &request, encoding);
    if (prepared != XRT_OK)
        return prepared;
    if (count >= encoding->width && memcmp(raw, encoding->bytes, encoding->width) == 0)
        return XRT_EXISTING_TRAP_INSTRUCTION;
    memset(original, 0, 4);
    memcpy(original, raw, encoding->width);
    return XRT_OK;
}
static void store_encoding(struct xrt_breakpoint *p, uint64_t address, const uint8_t original[4],
                           const struct xrt_probe_encoding *encoding, bool patched)
{
    p->address = address;
    p->width = encoding->width;
    p->isa_mode = encoding->isa_mode;
    p->alignment = encoding->alignment;
    memset(p->original, 0, sizeof(p->original));
    memset(p->planted, 0, sizeof(p->planted));
    memcpy(p->original, original, encoding->width);
    memcpy(p->planted, encoding->bytes, encoding->width);
    p->pending = false;
    p->patched = patched;
}
static void clear_pending(struct xrt_breakpoint *p)
{
    p->address = 0;
    p->width = 0;
    p->isa_mode = 0;
    p->alignment = 0;
    memset(p->planted, 0, sizeof(p->planted));
    memset(p->original, 0, sizeof(p->original));
    p->patched = false;
    p->pending = true;
}
enum xrt_status xrt_target_breakpoint_set(struct xrt_target *t, uint64_t address, bool temporary,
                                          uint64_t *id)
{
    if (!id)
        return XRT_INVALID_ARGUMENT;
    if (t && t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_BP_SET, .args = {address, temporary}, .value = id});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    const int existing = xrt_breakpoint_at(t, address);
    if (existing >= 0) {
        *id = t->breakpoints[existing].id;
        return XRT_OK;
    }
    /* UINT64_MAX is never allocated: the counter would wrap to the absent ID. */
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS || t->next_probe_id == UINT64_MAX)
        return XRT_BREAKPOINT_LIMIT;
    uint8_t original[4];
    struct xrt_probe_encoding encoding;
    TRY(prepare_probe(t, address, original, &encoding));
    TRY(xrt_target_commit_plant(t, address, &encoding, original));
    struct xrt_breakpoint p = {.id = t->next_probe_id, .enabled = true, .temporary = temporary};
    store_encoding(&p, address, original, &encoding, true);
    ++t->next_probe_id;
    t->breakpoints[t->breakpoint_count++] = p;
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_SET, t->pid, (int64_t)p.id);
    t->events[t->event_count - 1].address = address;
    *id = p.id;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_reserve(struct xrt_target *t, uint64_t *id)
{
    if (!id)
        return XRT_INVALID_ARGUMENT;
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_RESERVE, .value = id});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS || t->next_probe_id == UINT64_MAX)
        return XRT_BREAKPOINT_LIMIT;
    *id = t->next_probe_id++;
    t->breakpoints[t->breakpoint_count++] = (struct xrt_breakpoint){0};
    clear_pending(&t->breakpoints[t->breakpoint_count - 1]);
    t->breakpoints[t->breakpoint_count - 1].id = *id;
    t->breakpoints[t->breakpoint_count - 1].enabled = true;
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_SET, t->pid, (int64_t)*id);
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_restore(struct xrt_target *t, uint64_t id, bool enabled)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_RESTORE, .args = {id, enabled}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (!id || id == UINT64_MAX || xrt_breakpoint_index(t, id) >= 0)
        return XRT_INVALID_ARGUMENT;
    /* Breakpoints and watchpoints share one probe-ID namespace. */
    for (unsigned i = 0; i < XRT_MAX_WATCHPOINTS; ++i)
        if (t->watchpoints[i].present && t->watchpoints[i].id == id)
            return XRT_INVALID_ARGUMENT;
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS)
        return XRT_BREAKPOINT_LIMIT;
    t->breakpoints[t->breakpoint_count] = (struct xrt_breakpoint){0};
    clear_pending(&t->breakpoints[t->breakpoint_count]);
    t->breakpoints[t->breakpoint_count].id = id;
    t->breakpoints[t->breakpoint_count].enabled = enabled;
    ++t->breakpoint_count;
    if (t->next_probe_id <= id)
        t->next_probe_id = id + 1;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_resolve(struct xrt_target *t, uint64_t id, uint64_t address)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_RESOLVE, .args = {id, address}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (!p->pending)
        return XRT_BREAKPOINT_ALREADY_RESOLVED;
    if (xrt_breakpoint_at(t, address) >= 0)
        return XRT_BREAKPOINT_LOCATION_ALREADY_USED;
    uint8_t original[4];
    struct xrt_probe_encoding encoding;
    TRY(prepare_probe(t, address, original, &encoding));
    if (p->enabled)
        TRY(xrt_target_commit_plant(t, address, &encoding, original));
    store_encoding(p, address, original, &encoding, p->enabled);
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_withdraw(struct xrt_target *t, uint64_t id)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_WITHDRAW, .args = {id}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->patched)
        TRY(xrt_patch_instruction(t, p->address, p->original, p->width));
    const bool enabled = p->enabled;
    const uint64_t kept = p->id;
    const bool internal = p->internal;
    clear_pending(p);
    p->id = kept;
    p->enabled = enabled;
    p->internal = internal;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_enable(struct xrt_target *t, uint64_t id, bool enabled)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_BP_ENABLE, .args = {id, enabled}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->enabled == enabled)
        return XRT_OK;
    if (!p->pending)
        TRY(xrt_patch_instruction(t, p->address, enabled ? p->planted : p->original, p->width));
    p->enabled = enabled;
    p->patched = enabled && !p->pending;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_internal(struct xrt_target *t, uint64_t id, bool internal)
{
    if (t && t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_BP_INTERNAL, .args = {id, internal}});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    t->breakpoints[i].internal = internal;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_breakpoint_remove(struct xrt_target *t, uint64_t id)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_BP_REMOVE, .args = {id}});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    TRY(admitted_native(t));
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    const struct xrt_breakpoint p = t->breakpoints[i];
    if (p.patched)
        TRY(xrt_patch_instruction(t, p.address, p.original, p.width));
    t->breakpoints[i] = t->breakpoints[--t->breakpoint_count];
    xrt_target_event(t, XRT_EVENT_BREAKPOINT_REMOVED, t->pid, (int64_t)id);
    return XRT_OK;
}
enum xrt_status xrt_begin_step(struct xrt_target *t, int32_t tid, bool stop_after)
{
    TRY(xrt_execution_allowed(t));
    TRY(xrt_rearm_inherited(t));
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(xrt_ensure_watches(t));
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_registers regs;
    TRY(xrt_target_registers(t, tid, &regs));
    uint64_t pc = 0;
    const enum xrt_status pc_status = xrt_registers_pc(&regs, &pc);
    if (pc_status != XRT_OK)
        return pc_status;
    uint64_t rearm = 0;
    const int b = xrt_breakpoint_at(t, pc);
    if (b >= 0 && t->breakpoints[b].enabled) {
        struct xrt_breakpoint *p = &t->breakpoints[b];
        TRY(xrt_patch_instruction(t, p->address, p->original, p->width));
        p->patched = false;
        xrt_sync_shared_patch(t, p->id, false);
        rearm = p->id;
    }
    const enum xrt_status status =
        xrt_trace(PTRACE_SINGLESTEP, tid, 0, (uintptr_t)t->threads[i].signal);
    if (status != XRT_OK) {
        if (rearm && xrt_patch_instruction(t, t->breakpoints[b].address, t->breakpoints[b].planted,
                                           t->breakpoints[b].width) == XRT_OK) {
            t->breakpoints[b].patched = true;
            xrt_sync_shared_patch(t, rearm, true);
        }
        /* A failed repair must remain visible and must be retried before run. */
        else if (rearm) {
            t->inherited_rearm = true;
            ++t->generation;
        }
        return status;
    }
    t->step = (struct xrt_step){.tid = tid,
                                .rearm = rearm,
                                .stop_after = stop_after,
                                .has_exec_entry = t->threads[i].reason == XRT_STOP_EXEC,
                                .exec_entry_pc = pc};
    t->threads[i].signal = 0;
    t->threads[i].reason = XRT_STOP_NONE;
    t->threads[i].state = XRT_RUNNING;
    t->stepping = true;
    t->want_run = false;
    t->state = XRT_RUNNING;
    xrt_target_event(t, XRT_EVENT_STEP_STARTED, tid, 0);
    return XRT_OK;
}
enum xrt_status xrt_target_step(struct xrt_target *t, int32_t tid)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_STEP, .args = {(uint32_t)tid}});
    return t->core ? XRT_READ_ONLY_CORE : xrt_begin_step(t, tid, true);
}
enum xrt_status xrt_finish_step(struct xrt_target *t, bool completed)
{
    if (!t->stepping)
        return XRT_OK;
    const struct xrt_step step = t->step;
    const int b = step.rearm ? xrt_breakpoint_index(t, step.rearm) : -1;
    if (b >= 0) {
        bool live = false;
        for (size_t i = 0; i < t->thread_count; ++i)
            live |= t->threads[i].state != XRT_EXITED;
        if (live) {
            TRY(xrt_patch_instruction(t, t->breakpoints[b].address, t->breakpoints[b].planted,
                                      t->breakpoints[b].width));
            t->breakpoints[b].patched = true;
            xrt_sync_shared_patch(t, step.rearm, true);
        }
    }
    if (step.has_watch) {
        const int i = xrt_thread_index(t, step.tid);
        if (i >= 0 && t->threads[i].state == XRT_STOPPED) {
            const enum xrt_status status = xrt_configure_watches(t, step.tid);
            if (status != XRT_OK) {
                t->watchpoints_dirty = true;
                return status;
            }
        }
        xrt_publish_arm_watch(t, step.tid, &step.watch, completed);
    }
    t->stepping = false;
    return XRT_OK;
}
bool xrt_target_only_internal_stops(const struct xrt_target *t)
{
    if (!t)
        return false;
    bool hit = false;
    for (size_t i = 0; i < t->thread_count; ++i) {
        const struct xrt_thread *thread = &t->threads[i];
        if (thread->reason == XRT_STOP_NONE || thread->reason == XRT_STOP_INTERRUPT)
            continue;
        if (thread->reason != XRT_STOP_BREAKPOINT)
            return false;
        const int b = xrt_breakpoint_at(t, thread->breakpoint_address);
        if (b < 0 || !t->breakpoints[b].internal)
            return false;
        hit = true;
    }
    return hit;
}
