#define _GNU_SOURCE 1
#include "target_internal.h"
#include "wire_target.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

uint64_t xrt_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}
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
struct xrt_target *xrt_target_create(void)
{
    struct xrt_target *t = calloc(1, sizeof(*t));
    if (t) {
        t->remote_collectors = 0; /* Not shared until create returns. */
        t->arch = xrt_arch_native();
        t->next_thread_id = t->next_probe_id = 1;
    }
    return t;
}
enum xrt_status xrt_target_destroy(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_destroy(t);
    if (!t)
        return XRT_OK;
    TRY(xrt_target_close(t));
    free(t);
    return XRT_OK;
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
void xrt_target_invalidate(struct xrt_target *t)
{
    if (t && t->connection) {
        (void)xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_INVALIDATE});
        return;
    }
    ++t->generation;
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
void xrt_target_event(struct xrt_target *t, enum xrt_event_kind kind, int32_t tid, int64_t detail)
{
    if (t && t->connection) {
        (void)xrt_remote_call(t,
                              &(struct xrt_call){.op = XRT_RPC_EVENT,
                                                 .args = {kind, (uint32_t)tid, (uint64_t)detail}});
        return;
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
bool xrt_traced_member(int32_t tid, int32_t group)
{
    struct xrt_task_info info;
    return xrt_task_inspect(tid, &info) == XRT_OK && info.group == group && info.tracer == getpid();
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
    if (status == XRT_OK)
        status = xrt_process_validate_native(pid);
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
            return xrt_process_validate_native(tid);
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
    const enum xrt_status result = attach(t, pid);
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
        const uint64_t pc = xrt_pc(&regs);
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
    return xrt_registers_read(tid, out);
}
enum xrt_status xrt_target_register_write(struct xrt_target *t, int32_t tid, const char *name,
                                          size_t length, uint64_t value)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_REGISTER_WRITE,
                                                     .args = {(uint32_t)tid, value},
                                                     .data = name,
                                                     .size = length});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (xrt_thread_index(t, tid) < 0)
        return XRT_UNKNOWN_THREAD;
    TRY(xrt_register_write(tid, name, length, value));
    xrt_target_event(t, XRT_EVENT_REGISTER_WRITTEN, tid, 0);
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
    return xrt_xstate_read(tid, out);
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
