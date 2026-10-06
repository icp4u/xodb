#define _GNU_SOURCE 1
#include "target_internal.h"
#include <sys/uio.h>
#if defined(__x86_64__) && !defined(__ILP32__)
#include <sys/user.h>
#endif

static enum xrt_status debug_get(int32_t tid, unsigned slot, uint64_t *out)
{
#if defined(__x86_64__) && !defined(__ILP32__)
    errno = 0;
    const long value = ptrace(PTRACE_PEEKUSER, tid,
                              (void *)(offsetof(struct user, u_debugreg) +
                                       slot * sizeof(((struct user *)0)->u_debugreg[0])),
                              (void *)0);
    if (value == -1 && errno)
        return XRT_MEMORY_UNREADABLE;
    *out = (uint64_t)value;
    return XRT_OK;
#else
    (void)tid;
    (void)slot;
    (void)out;
    return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
}
static enum xrt_status debug_set(int32_t tid, unsigned slot, uint64_t value)
{
#if defined(__x86_64__) && !defined(__ILP32__)
    return xrt_trace(PTRACE_POKEUSER, tid,
                     offsetof(struct user, u_debugreg) +
                         slot * sizeof(((struct user *)0)->u_debugreg[0]),
                     (uintptr_t)value);
#else
    (void)tid;
    (void)slot;
    (void)value;
    return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
}
enum xrt_status xrt_restore_debug(int32_t tid, const struct xrt_debug_registers *saved)
{
    TRY(debug_set(tid, 7, 0));
    for (unsigned i = 0; i < 4; ++i)
        TRY(debug_set(tid, i, saved->address[i]));
    TRY(debug_set(tid, 6, saved->status));
    return debug_set(tid, 7, saved->control);
}
struct arm_watch_reg {
    uint64_t address;
    uint32_t control, pad;
};
struct arm_watch_bank {
    uint32_t info, pad;
    struct arm_watch_reg registers[16];
};
static enum xrt_status arm_bank(int32_t tid, uintptr_t note, struct arm_watch_bank *bank)
{
    memset(bank, 0, sizeof(*bank));
    struct iovec io = {.iov_base = bank, .iov_len = sizeof(*bank)};
    TRY(xrt_trace(PTRACE_GETREGSET, tid, note, (uintptr_t)&io));
    const unsigned n = bank->info & 255;
    return n > 16 || io.iov_len < 8 + n * 16 ? XRT_UNEXPECTED_WATCH_REGISTER_SIZE : XRT_OK;
}
enum xrt_status xrt_target_watchpoint_capacity(const struct xrt_target *t, uint8_t *capacity)
{
    if (t && t->connection)
        return xrt_remote_capacity(t, capacity);
    if (!capacity)
        return XRT_INVALID_ARGUMENT;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (t->arch->machine != XRT_X86_64 && t->arch->machine != XRT_AARCH64)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    *capacity = 4;
    if (t->arch->machine == XRT_X86_64)
        return XRT_OK;
    for (size_t i = 0; i < t->thread_count; ++i) {
        const struct xrt_thread *thread = &t->threads[i];
        if (thread->state != XRT_STOPPED)
            continue;
        uint8_t n = thread->arm_watch_slots;
        if (!thread->has_arm_watch_slots) {
            struct arm_watch_bank bank;
            TRY(arm_bank(thread->tid, 0x403, &bank));
            n = (uint8_t)bank.info;
        }
        if (n < *capacity)
            *capacity = n;
    }
    return XRT_OK;
}
enum xrt_status xrt_configure_arm_watches(struct xrt_target *t, int32_t tid, bool enabled)
{
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_thread *thread = &t->threads[i];
    if (thread->state == XRT_EXITED)
        return XRT_OK;
    if (!thread->has_arm_watch_slots) {
        bool armed = false;
        for (size_t b = 0; b < 4; ++b)
            armed |= t->watchpoints[b].present;
        if (!armed)
            return XRT_OK;
        struct arm_watch_bank saved, execution;
        TRY(arm_bank(tid, 0x403, &saved));
        TRY(arm_bank(tid, 0x402, &execution));
        for (size_t b = 0; b < 16; ++b)
            if (execution.registers[b].address || (execution.registers[b].control & 1))
                return XRT_EXISTING_HARDWARE_BREAKPOINTS;
        for (size_t b = 0; b < 16; ++b)
            if (saved.registers[b].address || (saved.registers[b].control & 1))
                return XRT_EXISTING_HARDWARE_WATCHPOINTS;
        thread->arm_watch_slots = (uint8_t)saved.info;
        thread->has_arm_watch_slots = true;
    }
    const uint8_t slots = thread->arm_watch_slots;
    struct arm_watch_bank bank = {.info = slots};
    if (enabled)
        for (size_t b = 0; b < 4; ++b) {
            const struct xrt_watchpoint *watch = &t->watchpoints[b];
            if (!watch->present)
                continue;
            if (b >= slots)
                return XRT_WATCHPOINT_LIMIT;
            const uint32_t bas = (UINT32_C(1) << watch->length) - 1;
            const uint32_t access = watch->kind == XRT_WATCH_WRITE ? 2 : 3;
            bank.registers[b] = (struct arm_watch_reg){.address = watch->address,
                                                       .control = 1 | (access << 3) | (bas << 5)};
        }
    struct iovec io = {.iov_base = &bank, .iov_len = 8 + (size_t)slots * 16};
    return xrt_trace(PTRACE_SETREGSET, tid, 0x403, (uintptr_t)&io);
}
enum xrt_status xrt_configure_watches(struct xrt_target *t, int32_t tid)
{
    if (t->arch->machine == XRT_AARCH64)
        return xrt_configure_arm_watches(t, tid, true);
    if (t->arch->machine != XRT_X86_64)
        return XRT_OK;
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_thread *thread = &t->threads[i];
    if (thread->state == XRT_EXITED)
        return XRT_OK;
    if (!thread->has_saved_debug) {
        struct xrt_debug_registers saved;
        for (unsigned b = 0; b < 4; ++b)
            TRY(debug_get(tid, b, &saved.address[b]));
        TRY(debug_get(tid, 6, &saved.status));
        TRY(debug_get(tid, 7, &saved.control));
        thread->saved_debug = saved;
        thread->has_saved_debug = true;
    }
    TRY(debug_set(tid, 7, 0));
    uint64_t control = 0x400;
    for (unsigned b = 0; b < 4; ++b) {
        const struct xrt_watchpoint *watch = &t->watchpoints[b];
        TRY(debug_set(tid, b, watch->present ? watch->address : 0));
        if (!watch->present)
            continue;
        const unsigned length = watch->length == 1   ? 0
                                : watch->length == 2 ? 1
                                : watch->length == 4 ? 3
                                                     : 2;
        const unsigned rw = watch->kind == XRT_WATCH_WRITE        ? 1
                            : watch->kind == XRT_WATCH_READ_WRITE ? 3
                                                                  : 0;
        control |= UINT64_C(1) << (2 * b);
        control |= (uint64_t)(rw | (length << 2)) << (16 + 4 * b);
    }
    TRY(debug_set(tid, 6, 0));
    return debug_set(tid, 7, control);
}
static enum xrt_status apply_watches(struct xrt_target *t)
{
    for (size_t i = 0; i < t->thread_count; ++i)
        TRY(xrt_configure_watches(t, t->threads[i].tid));
    t->watchpoints_dirty = false;
    return XRT_OK;
}
enum xrt_status xrt_ensure_watches(struct xrt_target *t)
{
    return t->watchpoints_dirty ? apply_watches(t) : XRT_OK;
}
static uint64_t little_word(const uint8_t bytes[8])
{
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i)
        value |= (uint64_t)bytes[i] << (i * 8);
    return value;
}
static bool watch_value(int32_t tid, const struct xrt_watchpoint *watch, uint64_t *value)
{
    uint8_t bytes[8] = {0};
    size_t count;
    if (xrt_memory_read(tid, watch->address, bytes, watch->length, &count) != XRT_OK ||
        count != watch->length)
        return false;
    *value = little_word(bytes);
    return true;
}
enum xrt_status xrt_target_watchpoint_set(struct xrt_target *t, uint64_t address, uint8_t length,
                                          enum xrt_watch_kind kind, uint64_t *id)
{
    if (!id || kind > XRT_WATCH_EXECUTE)
        return XRT_INVALID_ARGUMENT;
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_WATCH_SET,
                                                     .args = {address, length, kind},
                                                     .value = id});
    if (t->birth_count)
        return XRT_PROCESS_BIRTH_PENDING;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    if (!id || kind > XRT_WATCH_EXECUTE)
        return XRT_INVALID_ARGUMENT;
    if (t->arch->machine == XRT_AARCH64 && kind == XRT_WATCH_EXECUTE)
        return XRT_EXECUTION_WATCHPOINTS_UNSUPPORTED;
    TRY(xrt_ensure_watches(t));
    uint8_t capacity;
    TRY(xrt_target_watchpoint_capacity(t, &capacity));
    if ((length != 1 && length != 2 && length != 4 && length != 8) || address % length ||
        (kind == XRT_WATCH_EXECUTE && length != 1))
        return XRT_INVALID_WATCH_RANGE;
    unsigned slot = 0;
    while (slot < capacity && t->watchpoints[slot].present)
        ++slot;
    if (slot == capacity || t->next_probe_id == UINT64_MAX)
        return XRT_WATCHPOINT_LIMIT;
    uint8_t bytes[8] = {0};
    size_t count;
    TRY(xrt_target_read(t, address, bytes, length, &count));
    if (count != length)
        return XRT_MEMORY_UNREADABLE;
    const uint64_t probe = t->next_probe_id++;
    t->watchpoints[slot] = (struct xrt_watchpoint){.id = probe,
                                                   .address = address,
                                                   .length = length,
                                                   .kind = kind,
                                                   .previous = little_word(bytes),
                                                   .present = true};
    const enum xrt_status status = apply_watches(t);
    if (status != XRT_OK) {
        t->watchpoints[slot].present = false;
        if (apply_watches(t) != XRT_OK)
            t->watchpoints_dirty = true;
        return status;
    }
    xrt_target_event(t, XRT_EVENT_WATCHPOINT_SET, t->pid, (int64_t)probe);
    t->events[t->event_count - 1].address = address;
    *id = probe;
    return XRT_OK;
}
enum xrt_status xrt_target_watchpoint_remove(struct xrt_target *t, uint64_t id)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_WATCH_REMOVE, .args = {id}});
    if (t->birth_count)
        return XRT_PROCESS_BIRTH_PENDING;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(xrt_ensure_watches(t));
    for (size_t i = 0; i < 4; ++i) {
        struct xrt_watchpoint *watch = &t->watchpoints[i];
        if (!watch->present || watch->id != id)
            continue;
        const struct xrt_watchpoint saved = *watch;
        watch->present = false;
        const enum xrt_status status = apply_watches(t);
        if (status != XRT_OK) {
            *watch = saved;
            if (apply_watches(t) != XRT_OK)
                t->watchpoints_dirty = true;
            return status;
        }
        xrt_target_event(t, XRT_EVENT_WATCHPOINT_REMOVED, t->pid, (int64_t)id);
        return XRT_OK;
    }
    return XRT_UNKNOWN_WATCHPOINT;
}
enum xrt_status xrt_watch_trap(struct xrt_target *t, int32_t tid, uint64_t pc,
                               const struct xrt_signal_info *info, bool *hit)
{
    *hit = false;
    if (t->arch->machine == XRT_AARCH64) {
        struct xrt_arm_watch_hit evidence = {
            .pc = pc, .address = info->address, .code = info->code};
        for (size_t i = 0; i < 4; ++i)
            if (t->watchpoints[i].present) {
                *hit = true;
                evidence.before_valid[i] =
                    watch_value(tid, &t->watchpoints[i], &evidence.before[i]);
            }
        if (!*hit)
            return XRT_OK;
        for (size_t i = 0; i < t->thread_count; ++i)
            if (t->threads[i].tid != tid && t->threads[i].state == XRT_RUNNING)
                evidence.other_threads_running = true;
        struct xrt_thread *thread = &t->threads[xrt_thread_index(t, tid)];
        thread->arm_watch_hit = evidence;
        thread->has_arm_watch_hit = true;
        return XRT_OK;
    }
    uint64_t status;
    TRY(debug_get(tid, 6, &status));
    if (!(status & 15))
        return XRT_OK;
    for (unsigned i = 0; i < 4; ++i) {
        struct xrt_watchpoint *watch = &t->watchpoints[i];
        if (!watch->present || !(status & (UINT64_C(1) << i)))
            continue;
        uint64_t after;
        if (!watch_value(tid, watch, &after))
            return XRT_MEMORY_UNREADABLE;
        xrt_target_event(t, XRT_EVENT_WATCHPOINT_HIT, tid, (int64_t)watch->id);
        struct xrt_event *event = &t->events[t->event_count - 1];
        event->pc = pc;
        event->pc_known = 1;
        event->address = watch->address;
        event->before = watch->previous;
        event->after = after;
        event->size = watch->length;
        for (size_t j = 0; j < t->thread_count; ++j)
            if (t->threads[j].tid != tid && t->threads[j].state == XRT_RUNNING)
                event->other_threads_running = true;
        watch->previous = after;
        *hit = true;
    }
    return debug_set(tid, 6, 0);
}
void xrt_publish_arm_watch(struct xrt_target *t, int32_t tid, const struct xrt_arm_watch_hit *hit,
                           bool completed)
{
    unsigned count = 0;
    for (size_t i = 0; i < 4; ++i)
        count += t->watchpoints[i].present;
    struct xrt_registers regs;
    const bool have_regs = xrt_target_registers(t, tid, &regs) == XRT_OK;
    for (size_t i = 0; i < 4; ++i) {
        struct xrt_watchpoint *watch = &t->watchpoints[i];
        if (!watch->present)
            continue;
        uint64_t after = 0;
        const bool valid = completed && watch_value(tid, watch, &after);
        xrt_target_event(t, XRT_EVENT_WATCHPOINT_HIT, tid, (int64_t)watch->id);
        struct xrt_event *event = &t->events[t->event_count - 1];
        event->pc = hit->pc;
        event->pc_known = 1;
        if (have_regs) {
            uint64_t decoded = 0;
            if (xrt_registers_pc(&regs, &decoded) == XRT_OK)
                event->pc = decoded;
            else {
                event->pc = 0;
                event->pc_known = 0;
            }
        }
        event->has_trap = true;
        event->trap_pc = hit->pc;
        event->trap_address = hit->address;
        event->trap_code = hit->code;
        event->watch_phase = completed ? 1 : 2;
        event->watch_attribution = count == 1 ? 1 : 2;
        event->address = watch->address;
        event->size = watch->length;
        event->before = hit->before[i];
        event->before_valid = hit->before_valid[i];
        event->after = after;
        event->after_valid = valid;
        event->other_threads_running = hit->other_threads_running;
        if (valid)
            watch->previous = after;
    }
}
enum xrt_status xrt_start_arm_watch_completion(struct xrt_target *t, bool *started)
{
    *started = false;
    for (size_t i = 0; i < t->thread_count; ++i) {
        struct xrt_thread *thread = &t->threads[i];
        if (!thread->has_arm_watch_hit)
            continue;
        if (t->watch_cancelled || thread->state != XRT_STOPPED) {
            xrt_publish_arm_watch(t, thread->tid, &thread->arm_watch_hit, false);
            thread->has_arm_watch_hit = false;
            continue;
        }
        TRY(xrt_ensure_watches(t));
        enum xrt_status status = xrt_configure_arm_watches(t, thread->tid, false);
        if (status != XRT_OK) {
            t->watchpoints_dirty = true;
            return status;
        }
        status = xrt_begin_step(t, thread->tid, true);
        if (status != XRT_OK) {
            if (xrt_configure_watches(t, thread->tid) != XRT_OK)
                t->watchpoints_dirty = true;
            return status;
        }
        t->step.has_watch = true;
        t->step.watch = thread->arm_watch_hit;
        thread->has_arm_watch_hit = false;
        *started = true;
        return XRT_OK;
    }
    t->watch_cancelled = false;
    return XRT_OK;
}
