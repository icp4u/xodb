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
enum xrt_status xrt_patch_instruction_tid(const struct xrt_target *t, int32_t tid, uint64_t address,
                                          const uint8_t *bytes)
{
    if (!t->arch || !xrt_arch_breakpoint_valid(t->arch->machine, address, t->arch->trap_size))
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    size_t count = 0;
    const enum xrt_status result =
        xrt_memory_patch(tid, address, bytes, t->arch->trap_size, &count);
    return result != XRT_OK && count ? XRT_PARTIAL_MEMORY_WRITE : result;
}
enum xrt_status xrt_patch_instruction(const struct xrt_target *t, uint64_t address,
                                      const uint8_t *bytes)
{
    int32_t tid;
    TRY(xrt_target_stopped_tid(t, &tid));
    return xrt_patch_instruction_tid(t, tid, address, bytes);
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
        if (!p->patched)
            continue;
        for (size_t i = 0; i < t->arch->trap_size; ++i) {
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
            if (at >= p->address && at - p->address < t->arch->trap_size) {
                overlay = p;
                break;
            }
        }
        if (!overlay || !overlay->patched) {
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
static enum xrt_status original_instruction(struct xrt_target *t, uint64_t address,
                                            uint8_t bytes[4])
{
    if (!address || !xrt_arch_breakpoint_valid(t->arch->machine, address, t->arch->trap_size))
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    size_t count;
    TRY(xrt_target_read(t, address, bytes, t->arch->trap_size, &count));
    if (count != t->arch->trap_size)
        return XRT_MEMORY_UNREADABLE;
    return memcmp(bytes, t->arch->trap, count) == 0 ? XRT_EXISTING_TRAP_INSTRUCTION : XRT_OK;
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
    if (!id)
        return XRT_INVALID_ARGUMENT;
    const int existing = xrt_breakpoint_at(t, address);
    if (existing >= 0) {
        *id = t->breakpoints[existing].id;
        return XRT_OK;
    }
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS)
        return XRT_BREAKPOINT_LIMIT;
    struct xrt_breakpoint p = {.id = t->next_probe_id,
                               .address = address,
                               .patched = true,
                               .enabled = true,
                               .temporary = temporary};
    TRY(original_instruction(t, address, p.original));
    TRY(xrt_patch_instruction(t, address, t->arch->trap));
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
    if (!id)
        return XRT_INVALID_ARGUMENT;
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS)
        return XRT_BREAKPOINT_LIMIT;
    *id = t->next_probe_id++;
    t->breakpoints[t->breakpoint_count++] =
        (struct xrt_breakpoint){.id = *id, .pending = true, .enabled = true};
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
    if (!id || id == UINT64_MAX || xrt_breakpoint_index(t, id) >= 0)
        return XRT_INVALID_ARGUMENT;
    if (t->breakpoint_count == XRT_MAX_BREAKPOINTS)
        return XRT_BREAKPOINT_LIMIT;
    t->breakpoints[t->breakpoint_count++] =
        (struct xrt_breakpoint){.id = id, .pending = true, .enabled = enabled};
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
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (!p->pending)
        return XRT_BREAKPOINT_ALREADY_RESOLVED;
    if (xrt_breakpoint_at(t, address) >= 0)
        return XRT_BREAKPOINT_LOCATION_ALREADY_USED;
    uint8_t original[4] = {0};
    TRY(original_instruction(t, address, original));
    if (p->enabled)
        TRY(xrt_patch_instruction(t, address, t->arch->trap));
    p->address = address;
    memcpy(p->original, original, sizeof(original));
    p->pending = false;
    p->patched = p->enabled;
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
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->patched)
        TRY(xrt_patch_instruction(t, p->address, p->original));
    p->address = 0;
    p->patched = false;
    p->pending = true;
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
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    struct xrt_breakpoint *p = &t->breakpoints[i];
    if (p->enabled == enabled)
        return XRT_OK;
    if (!p->pending)
        TRY(xrt_patch_instruction(t, p->address, enabled ? t->arch->trap : p->original));
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
    const int i = xrt_breakpoint_index(t, id);
    if (i < 0)
        return XRT_UNKNOWN_BREAKPOINT;
    const struct xrt_breakpoint p = t->breakpoints[i];
    if (p.patched)
        TRY(xrt_patch_instruction(t, p.address, p.original));
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
    const uint64_t pc = xrt_pc(&regs);
    uint64_t rearm = 0;
    const int b = xrt_breakpoint_at(t, pc);
    if (b >= 0 && t->breakpoints[b].enabled) {
        struct xrt_breakpoint *p = &t->breakpoints[b];
        TRY(xrt_patch_instruction(t, p->address, p->original));
        p->patched = false;
        xrt_sync_shared_patch(t, p->id, false);
        rearm = p->id;
    }
    const enum xrt_status status =
        xrt_trace(PTRACE_SINGLESTEP, tid, 0, (uintptr_t)t->threads[i].signal);
    if (status != XRT_OK) {
        if (rearm && xrt_patch_instruction(t, t->breakpoints[b].address, t->arch->trap) == XRT_OK) {
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
            TRY(xrt_patch_instruction(t, t->breakpoints[b].address, t->arch->trap));
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
