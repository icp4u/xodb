#define _GNU_SOURCE 1
#include "target_internal.h"
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/uio.h>
#include "wire_target.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

enum xrt_status xrt_trace(unsigned request, int32_t tid, uintptr_t address, uintptr_t data)
{
    if (ptrace(request, tid, (void *)address, (void *)data) != -1)
        return XRT_OK;
    if (errno == EPERM || errno == EACCES)
        return XRT_PERMISSION_DENIED;
    if (errno == ESRCH)
        return XRT_PROCESS_GONE;
    return XRT_PTRACE_FAILED;
}

/* NT_ARM_PAC_MASK. The kernel writes user_pac_mask: data mask, then insn mask.
 * EINVAL means this kernel has no note. ESRCH and EIO stay distinguishable
 * from that, so a caller can retry those and cache only a permanent answer. */
enum xrt_status xrt_pac_masks_of_tid(int32_t tid, uint64_t *data_mask, uint64_t *insn_mask)
{
    if (!data_mask || !insn_mask)
        return XRT_INVALID_ARGUMENT;
    *data_mask = 0;
    *insn_mask = 0;
    if (tid <= 0)
        return XRT_INVALID_ARGUMENT;
    struct {
        uint64_t data_mask;
        uint64_t insn_mask;
    } masks;
    struct iovec io = {.iov_base = &masks, .iov_len = sizeof masks};
    if (ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)0x406, &io) == -1) {
        if (errno == EINVAL)
            return XRT_UNSUPPORTED_ARCHITECTURE;
        if (errno == EPERM || errno == EACCES)
            return XRT_PERMISSION_DENIED;
        if (errno == ESRCH)
            return XRT_PROCESS_GONE;
        return XRT_PTRACE_FAILED;
    }
    if (io.iov_len != sizeof masks)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    *data_mask = masks.data_mask;
    *insn_mask = masks.insn_mask;
    return XRT_OK;
}

/* One stopped thread is enough; the caller caches the pair for the target. */
enum xrt_status xrt_target_pac_mask(const struct xrt_target *t, int32_t tid,
                                    uint64_t *data_mask, uint64_t *insn_mask)
{
    if (!data_mask || !insn_mask)
        return XRT_INVALID_ARGUMENT;
    *data_mask = 0;
    *insn_mask = 0;
    if (!t || !t->arch || t->connection || t->arch->machine != XRT_AARCH64)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return xrt_pac_masks_of_tid(tid, data_mask, insn_mask);
}

enum xrt_status xrt_target_destroy(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_destroy(t);
    if (!t)
        return XRT_OK;
    TRY(xrt_target_close(t));
    xrt_follow_subreaper_release(t);
    xodb_maps_free(&t->maps);
    free(t);
    return XRT_OK;
}
enum xrt_status xrt_target_invalidate(struct xrt_target *t)
{
    if (!t) return XRT_INVALID_ARGUMENT;
    if (t && t->connection) {
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_INVALIDATE});
    }
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_expect(const struct xrt_target *t, uint64_t generation)
{
    if (t && t->connection) {
        enum xrt_status status = xrt_remote_health(t);
        if (status != XRT_OK)
            return status;
    }
    return (t ? t->generation : 0) == generation ? XRT_OK : XRT_STALE_SNAPSHOT;
}
enum xrt_status xrt_target_event(struct xrt_target *t, enum xrt_event_kind kind, int32_t tid, int64_t detail)
{
    if (!t) return XRT_INVALID_ARGUMENT;
    if (t && t->connection) {
        return xrt_remote_call(t,
                              &(struct xrt_call){.op = XRT_RPC_EVENT,
                                                 .args = {kind, (uint32_t)tid, (uint64_t)detail}});
    }
    ++t->sequence;
    if (t->event_count == XRT_MAX_EVENTS) {
        memmove(t->events, t->events + 1, (XRT_MAX_EVENTS - 1) * sizeof(t->events[0]));
        --t->event_count;
    }
    t->events[t->event_count++] = (struct xrt_event){.sequence = t->sequence,
                                                     .time_ns = xrt_now(),
                                                     .tid = tid,
                                                     .kind = kind,
                                                     .detail = detail,
                                                     .before_valid = true,
                                                     .after_valid = true};
    ++t->generation;
    return XRT_OK;
}
bool xrt_traced_member(int32_t tid, int32_t group)
{
    struct xrt_task_info info;
    /* Linux records the tracing task, not its process leader. A native owner
     * may be a worker thread; another thread in our process is not its owner. */
    return xrt_task_inspect(tid, &info) == XRT_OK && info.group == group && info.tracer == syscall(SYS_gettid);
}
bool xrt_task_zombie(int32_t tid)
{
    struct xrt_task_info info;
    return xrt_task_inspect(tid, &info) == XRT_OK && info.state == 'Z';
}
static bool task_gone(int32_t tid)
{
    struct xrt_task_info info;
    const enum xrt_status status = xrt_task_inspect(tid, &info);
    return status == XRT_PROCESS_GONE ||
           (status == XRT_OK && (info.state == 'Z' || info.state == 'X'));
}
enum xrt_status xrt_target_launch(struct xrt_target *t, const char *const argv[])
{
    if (t && t->connection)
        return xrt_remote_launch(t, argv);
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->pid || !argv || !argv[0])
        return XRT_INVALID_STATE;
    if (!t->arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    int32_t pid;
    TRY(xrt_process_launch(argv, t->follow_processes, &pid));
    t->pid = pid;
    t->owned = true;
    t->state = XRT_RUNNING;
    enum xrt_status status = xrt_add_thread(t, pid, false);
    if (status == XRT_OK) {
        xrt_target_event(t, XRT_EVENT_LAUNCH, pid, 0);
        status = xrt_target_wait_stopped(t);
    }
    if (status == XRT_OK && t->state == XRT_EXITED)
        status = XRT_EXEC_FAILED;
    const struct xrt_arch *identified = NULL;
    if (status == XRT_OK)
        status = xrt_process_identify(pid, &identified);
    if (status == XRT_OK && xrt_arch_host_traceable(identified)) {
        t->arch = identified;
        t->identity_admitted = 1;
    } else if (status == XRT_OK) {
        status = XRT_UNSUPPORTED_ARCHITECTURE;
    }
    if (status != XRT_OK)
        xrt_target_close(t);
    return status;
}
static enum xrt_status interrupt_thread(struct xrt_thread *thread)
{
    if (thread->state != XRT_RUNNING || thread->interrupt_pending || thread->newborn)
        return XRT_OK;
    const enum xrt_status status = xrt_trace(PTRACE_INTERRUPT, thread->tid, 0, 0);
    if (status != XRT_OK) {
        if (status != XRT_PROCESS_GONE)
            return status;
        if (xrt_task_zombie(thread->tid))
            thread->state = XRT_EXITED;
        return XRT_OK;
    }
    thread->interrupt_pending = true;
    return XRT_OK;
}
enum xrt_status xrt_stop_peers(struct xrt_target *t)
{
    if (t->stepping)
        t->step.interrupted = true;
    t->want_run = false;
    for (size_t i = 0; i < t->thread_count; ++i)
        TRY(interrupt_thread(&t->threads[i]));
    return XRT_OK;
}
enum xrt_status xrt_target_interrupt(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_INTERRUPT});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state == XRT_IDLE || t->state == XRT_EXITED)
        return XRT_INVALID_STATE;
    t->watch_cancelled = true;
    return xrt_stop_peers(t);
}
static enum xrt_status attach(struct xrt_target *t, int32_t pid)
{
    const uint64_t deadline = xrt_now() + UINT64_C(3000000000);
    bool announced = false;
    while (xrt_now() < deadline) {
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/task", (int)pid);
        DIR *dir = opendir(path);
        if (!dir)
            return XRT_PROCESS_GONE;
        bool added = false;
        enum xrt_status status = XRT_OK;
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            char *end;
            const long number = strtol(entry->d_name, &end, 10);
            if (*end || number <= 0 || number > INT32_MAX)
                continue;
            const int32_t tid = (int32_t)number;
            if (xrt_thread_index(t, tid) >= 0)
                continue;
            status =
                xrt_trace(PTRACE_SEIZE, tid, 0, xrt_process_options(false, t->follow_processes));
            if (status != XRT_OK) {
                if ((status == XRT_PROCESS_GONE || status == XRT_PERMISSION_DENIED) &&
                    xrt_task_zombie(tid)) {
                    status = XRT_OK;
                    if (tid == pid) {
                        status = xrt_add_thread(t, tid, false);
                        if (status != XRT_OK)
                            break;
                        t->threads[xrt_thread_index(t, tid)].state = XRT_EXITED;
                    }
                    continue;
                }
                if (status == XRT_PROCESS_GONE) {
                    status = XRT_OK;
                    continue;
                }
                if (status == XRT_PERMISSION_DENIED && t->thread_count &&
                    xrt_traced_member(tid, pid)) {
                    status = xrt_add_thread(t, tid, true);
                    if (status != XRT_OK)
                        break;
                    added = true;
                    continue;
                }
                if (status == XRT_PERMISSION_DENIED && task_gone(tid)) {
                    status = XRT_OK;
                    continue;
                }
                break;
            }
            status = xrt_add_thread(t, tid, false);
            if (status != XRT_OK) {
                /* This successfully seized task is not in the bounded table.
                 * Interrupt/detach it before reporting capacity exhaustion. */
                xrt_trace(PTRACE_INTERRUPT, tid, 0, 0);
                int wait_status;
                while (waitpid(tid, &wait_status, __WALL) < 0 && errno == EINTR) {
                }
                xrt_trace(PTRACE_DETACH, tid, 0, 0);
                break;
            }
            added = true;
            status = interrupt_thread(&t->threads[xrt_thread_index(t, tid)]);
            if (status != XRT_OK)
                break;
        }
        closedir(dir);
        TRY(status);
        if (!t->thread_count)
            return XRT_PROCESS_GONE;
        if (!announced) {
            xrt_target_event(t, XRT_EVENT_ATTACH, pid, 0);
            announced = true;
        }
        TRY(xrt_target_interrupt(t));
        TRY(xrt_target_wait_stopped(t));
        if (t->state == XRT_EXITED)
            return XRT_OK;
        if (!added) {
            int32_t tid;
            TRY(xrt_target_stopped_tid(t, &tid));
            const struct xrt_arch *identified = NULL;
            const enum xrt_status ident = xrt_process_identify(tid, &identified);
            if (ident != XRT_OK)
                return ident;
            return xrt_arch_host_traceable(identified) ? XRT_OK : XRT_UNSUPPORTED_ARCHITECTURE;
        }
    }
    return XRT_STOP_TIMEOUT;
}
enum xrt_status xrt_target_attach(struct xrt_target *t, int32_t pid)
{
    if (t && t->connection)
        return xrt_remote_call(t,
                               &(struct xrt_call){.op = XRT_RPC_ATTACH, .args = {(uint32_t)pid}});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (pid <= 1 || pid == getpid() || t->pid)
        return XRT_INVALID_PID;
    if (!t->arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    t->pid = pid;
    t->owned = false;
    t->state = XRT_RUNNING;
    enum xrt_status result = attach(t, pid);
    /* A zombie group leader has no /proc/pid/exe. The stopped worker still
     * names the image, and an already-exited target has nothing to identify. */
    if (result == XRT_OK && t->state != XRT_EXITED) {
        int32_t tid = 0;
        const struct xrt_arch *identified = NULL;
        result = xrt_target_stopped_tid(t, &tid);
        if (result == XRT_OK)
            result = xrt_process_identify(tid, &identified);
        if (result == XRT_OK && xrt_arch_host_traceable(identified)) {
            t->arch = identified;
            t->identity_admitted = 1;
        } else {
            if (result == XRT_OK)
                result = XRT_UNSUPPORTED_ARCHITECTURE;
            xrt_target_close(t);
            return result;
        }
    }
    if (result != XRT_OK)
        xrt_target_close(t);
    return result;
}
void xrt_recompute_state(struct xrt_target *t)
{
    if (!t->pid)
        return;
    if (!t->thread_count) {
        t->state = XRT_EXITED;
        return;
    }
    bool stopped = false;
    for (size_t i = 0; i < t->thread_count; ++i) {
        if (t->threads[i].state == XRT_RUNNING) {
            t->state = XRT_RUNNING;
            return;
        }
        stopped |= t->threads[i].state == XRT_STOPPED;
    }
    t->state = stopped ? XRT_STOPPED : XRT_RUNNING;
}
enum xrt_status xrt_target_continue(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CONTINUE});
    TRY(xrt_execution_allowed(t));
    TRY(xrt_rearm_inherited(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    TRY(xrt_ensure_watches(t));
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].has_arm_watch_hit)
            return XRT_WATCHPOINT_COMPLETION_PENDING;
    for (size_t i = 0; i < t->thread_count; ++i) {
        const struct xrt_thread *thread = &t->threads[i];
        if (thread->state != XRT_STOPPED)
            continue;
        struct xrt_registers regs;
        TRY(xrt_target_registers(t, thread->tid, &regs));
        uint64_t pc = 0;
        const enum xrt_status pc_status = xrt_registers_pc(&regs, &pc);
        if (pc_status != XRT_OK)
            return pc_status;
        if (thread->breakpoint_address && thread->breakpoint_address == pc &&
            xrt_breakpoint_at(t, pc) >= 0)
            return xrt_begin_step(t, thread->tid, false);
    }
    t->want_run = true;
    for (size_t i = 0; i < t->thread_count; ++i) {
        struct xrt_thread *thread = &t->threads[i];
        if (thread->state != XRT_STOPPED)
            continue;
        const enum xrt_status status =
            xrt_trace(PTRACE_CONT, thread->tid, 0, (uintptr_t)thread->signal);
        if (status != XRT_OK) {
            xrt_recompute_state(t);
            return status;
        }
        thread->signal = 0;
        thread->reason = XRT_STOP_NONE;
        thread->state = XRT_RUNNING;
    }
    t->state = XRT_RUNNING;
    xrt_target_event(t, XRT_EVENT_CONTINUED, t->pid, 0);
    xrt_recompute_state(t);
    return XRT_OK;
}
enum xrt_status xrt_target_wait_stopped(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_WAIT_STOPPED});
    const uint64_t deadline = xrt_now() + UINT64_C(3000000000);
    while (xrt_now() < deadline) {
        TRY(xrt_target_poll(t));
        if (t->state == XRT_STOPPED || t->state == XRT_EXITED)
            return XRT_OK;
        usleep(1000);
    }
    return XRT_STOP_TIMEOUT;
}
enum xrt_status xrt_target_registers(const struct xrt_target *t, int32_t tid,
                                     struct xrt_registers *out)
{
    if (t && t->connection)
        return xrt_remote_registers(t, tid, out);
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (!t->arch || !xrt_arch_host_traceable(t->arch))
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return xrt_registers_read_for(t->arch, tid, out);
}
static void unpack_mutation(struct xrt_target *t, uint64_t packed)
{
    t->last_mutation.issued = (uint8_t)(packed & 0xff);
    t->last_mutation.confirmed = (uint8_t)((packed >> 8) & 0xff);
}
static void finish_mutation(struct xrt_target *t, int32_t tid, enum xrt_status status,
                            struct xrt_mutation_result result)
{
    t->last_mutation = result;
    if (!result.issued)
        return;
    if (status == XRT_OK && result.confirmed)
        xrt_target_event(t, XRT_EVENT_REGISTER_WRITTEN, tid, 0);
    else
        ++t->generation;
}
void xrt_target_apply_exec_identity(struct xrt_target *t, enum xrt_status validate_status)
{
    if (!t)
        return;
    t->plant_cleanup.active = 0;
    if (validate_status != XRT_OK) {
        t->identity_admitted = 0;
        return;
    }
    t->arch = xrt_arch_native();
    t->identity_admitted = t->arch && xrt_arch_validate(t->arch) == XRT_OK;
}
enum xrt_status xrt_target_register_write(struct xrt_target *t, int32_t tid, const char *name,
                                          size_t length, uint64_t value)
{
    if (!t)
        return XRT_INVALID_ARGUMENT;
    t->last_mutation = (struct xrt_mutation_result){0};
    if (t->connection) {
        uint64_t packed = 0;
        const enum xrt_status status =
            xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_REGISTER_WRITE,
                                                  .args = {(uint32_t)tid, value},
                                                  .data = name,
                                                  .size = length,
                                                  .value = &packed});
        unpack_mutation(t, packed);
        return status;
    }
    if (!t->identity_admitted || !xrt_arch_host_traceable(t->arch))
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (xrt_thread_index(t, tid) < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_mutation_result result = {0};
    const enum xrt_status status =
        xrt_register_write_result_for(t->arch, tid, name, length, value, t->reg_io, &result);
    finish_mutation(t, tid, status, result);
    return status;
}
enum xrt_status xrt_target_control_write(struct xrt_target *t, int32_t tid,
                                         const struct xrt_control_request *request)
{
    if (!t || !request)
        return XRT_INVALID_ARGUMENT;
    t->last_mutation = (struct xrt_mutation_result){0};
    if (t->connection) {
        uint8_t body[16];
        struct xrt_codec encoded = xrt_codec(body, sizeof(body), false);
        for (uint8_t i = 0; i < request->count && i < 2; ++i) {
            uint64_t word = request->value[i];
            xrt_codec_u64(&encoded, &word);
        }
        if (!encoded.ok || request->count < 1 || request->count > 2)
            return XRT_INVALID_ARGUMENT;
        uint64_t packed = 0;
        const enum xrt_status status = xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_CONTROL_WRITE,
                                  .args = {(uint32_t)tid, request->count, 0},
                                  .data = body,
                                  .size = (size_t)request->count * 8,
                                  .value = &packed});
        unpack_mutation(t, packed);
        return status;
    }
    if (!t->identity_admitted || !xrt_arch_host_traceable(t->arch))
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (xrt_thread_index(t, tid) < 0)
        return XRT_UNKNOWN_THREAD;
    struct xrt_mutation_result result = {0};
    const enum xrt_status status = xrt_control_write_for(t->arch, tid, request, t->reg_io, &result);
    finish_mutation(t, tid, status, result);
    return status;
}
enum xrt_status xrt_target_clear_stop(struct xrt_target *t, int32_t tid, uint64_t address)
{
    if (!t)
        return XRT_INVALID_ARGUMENT;
    if (t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_CLEAR_STOP, .args = {(uint32_t)tid, address}});
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (t->threads[i].reason == XRT_STOP_BREAKPOINT && t->threads[i].breakpoint_address == address) {
        t->threads[i].reason = XRT_STOP_INTERRUPT;
        ++t->generation;
    }
    return XRT_OK;
}
enum xrt_status xrt_target_signal_suppress(struct xrt_target *t, int32_t tid)
{
    if (t && t->connection)
        return xrt_remote_call(
            t, &(struct xrt_call){.op = XRT_RPC_SIGNAL_SUPPRESS, .args = {(uint32_t)tid}});
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    t->threads[i].signal = 0;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_target_extended(const struct xrt_target *t, int32_t tid, struct xrt_xstate *out)
{
    if (t && t->connection)
        return xrt_remote_extended(t, tid, out);
    if (t->core)
        return XRT_READ_ONLY_CORE;
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    const enum xrt_status status = xrt_xstate_read(tid, out);
    /* A 32-bit task has xmm0-7 only; the 64-bit xstate's upper rows are not its state. */
    if (status == XRT_OK && t->arch && t->arch->machine == XRT_I386 && out->vector_count > 8) {
        memset(out->vectors[8], 0, sizeof(out->vectors) - sizeof(out->vectors[0]) * 8);
        out->vector_count = 8;
    }
    return status;
}
void xrt_target_observer(struct xrt_target *t, xrt_new_thread_observer observer, void *context)
{
    t->observer = observer;
    t->observer_context = context;
}
enum xrt_status xrt_target_core(struct xrt_target *t, int32_t pid, const struct xrt_thread *threads,
                                size_t count)
{
    if (t && t->connection)
        return XRT_INVALID_STATE;
    if (t->pid || t->core || t->thread_count)
        return XRT_INVALID_STATE;
    if (count > XRT_MAX_THREADS || (!threads && count))
        return XRT_INVALID_ARGUMENT;
    for (size_t i = 0; i < count; ++i) {
        t->threads[i] = threads[i];
        t->threads[i].id = t->next_thread_id++;
    }
    t->thread_count = count;
    t->pid = pid;
    t->state = XRT_STOPPED;
    t->owned = false;
    t->want_run = false;
    ++t->generation;
    ++t->image_epoch;
    t->core = true;
    return XRT_OK;
}

enum xrt_status xrt_target_core_extend(struct xrt_target *t, const struct xrt_thread *threads, size_t count)
{
    if (!t || !t->core)
        return XRT_INVALID_STATE;
    if (!count)
        return XRT_OK;
    if (!threads || t->thread_count + count > XRT_MAX_THREADS)
        return XRT_TOO_MANY_THREADS;
    for (size_t i = 0; i < count; ++i) {
        struct xrt_thread *slot = &t->threads[t->thread_count];
        *slot = threads[i];
        slot->id = t->next_thread_id++;
        t->thread_count++;
    }
    ++t->generation;
    return XRT_OK;
}

enum xrt_status xrt_target_signal_info(const struct xrt_target *t, int32_t tid,
                                       struct xrt_signal_info *out)
{
    if (!t || !out)
        return XRT_INVALID_ARGUMENT;
    if (t->connection) {
        uint8_t bytes[64];
        size_t size = 0;
        struct xrt_signal_info info = {0};
        enum xrt_status status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_SIGNAL_INFO,
                                                                       .args = {(uint32_t)tid},
                                                                       .out = bytes,
                                                                       .capacity = sizeof(bytes),
                                                                       .length = &size});
        if (status != XRT_OK)
            return status;
        struct xrt_codec in = xrt_codec(bytes, size, true);
        xrt_wire_signal(&in, &info);
        if (!in.ok || in.at != in.size)
            return xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
        *out = info;
        return XRT_OK;
    }
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    return xrt_signal_read(tid, out);
}
