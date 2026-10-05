#define _GNU_SOURCE 1
#include "target_internal.h"

/* Wait only on TIDs learned through launch, attach or kernel birth events.
 * Other subsystems may own traced children of this same debugger process. */
static enum xrt_status wait_known(struct xrt_target *t, int32_t *tid, int *status)
{
    *tid = 0;
    for (size_t i = 0; i < t->thread_count; ++i) {
        const pid_t got = waitpid(t->threads[i].tid, status, __WALL | WNOHANG);
        if (got > 0) {
            *tid = got;
            return XRT_OK;
        }
        if (got < 0 && errno != ECHILD && errno != EINTR)
            return XRT_WAIT_FAILED;
    }
    return XRT_OK;
}
static enum xrt_status poll(struct xrt_target *t)
{
    for (;;) {
        int32_t tid;
        int status = 0;
        TRY(wait_known(t, &tid, &status));
        if (!tid)
            break;
        int i = xrt_thread_index(t, tid);
        assert(i >= 0);
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            xrt_target_event(t, XRT_EVENT_EXIT, tid,
                             WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status));
            t->threads[i] = t->threads[--t->thread_count];
            if (!t->thread_count) {
                t->state = XRT_EXITED;
                TRY(xrt_separate_vfork(t));
                t->stepping = false;
            } else if (t->stepping && t->step.tid == tid)
                TRY(xrt_stop_peers(t));
            continue;
        }
        if (!WIFSTOPPED(status))
            continue;
        const int sig = WSTOPSIG(status);
        const unsigned kind = (unsigned)status >> 16;
        t->threads[i].state = XRT_STOPPED;
        t->threads[i].interrupt_pending = false;
        if (kind == PTRACE_EVENT_EXIT) {
            if (t->thread_count == 1)
                TRY(xrt_separate_vfork(t));
            unsigned long exit_status = 0;
            TRY(xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&exit_status));
            t->threads[i].state = XRT_EXITED;
            if (t->stepping && t->step.tid == tid && t->step.has_watch)
                TRY(xrt_finish_step(t, false));
            t->threads[i].signal = 0;
            xrt_target_event(t, XRT_EVENT_THREAD_EXITING, tid, (int64_t)exit_status);
            TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
            if (t->stepping && t->step.tid == tid)
                TRY(xrt_stop_peers(t));
            continue;
        }
        if (kind == PTRACE_EVENT_EXEC) {
            TRY(xrt_separate_vfork(t));
            unsigned long former_tid = 0;
            TRY(xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&former_tid));
            const int prior = xrt_thread_index(t, (int32_t)former_tid);
            const uint64_t id = t->threads[prior >= 0 ? prior : i].id;
            t->threads[0] = (struct xrt_thread){.id = id, .tid = tid, .state = XRT_STOPPED};
            t->thread_count = 1;
            i = 0;
            /* exec invalidates the entire old image; never restore its bytes. */
            t->breakpoint_count = 0;
            memset(t->watchpoints, 0, sizeof(t->watchpoints));
            t->stepping = false;
            t->inherited_rearm = false;
            t->watchpoints_dirty = false;
            t->watch_cancelled = false;
            ++t->image_epoch;
            xrt_target_event(t, XRT_EVENT_IMAGE_REPLACED, tid, (int64_t)t->image_epoch);
            TRY(xrt_process_validate_native(tid));
        }
        unsigned long child = 0;
        if (kind == PTRACE_EVENT_FORK || kind == PTRACE_EVENT_VFORK || kind == PTRACE_EVENT_CLONE)
            TRY(xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&child));
        if (kind == PTRACE_EVENT_FORK || kind == PTRACE_EVENT_VFORK ||
            (kind == PTRACE_EVENT_CLONE && !xrt_traced_member((int32_t)child, t->pid))) {
            assert(t->birth_count < XRT_MAX_THREADS);
            if (!t->birth_count) {
                t->birth_image_epoch = t->image_epoch;
                t->birth_breakpoint_count = t->breakpoint_count;
                memcpy(t->birth_breakpoints, t->breakpoints,
                       t->breakpoint_count * sizeof(t->breakpoints[0]));
                memcpy(t->birth_watchpoints, t->watchpoints, sizeof(t->watchpoints));
                t->birth_next_probe_id = t->next_probe_id;
            }
            t->births[t->birth_count++] =
                (struct xrt_birth){.pid = (int32_t)child,
                                   .parent_tid = tid,
                                   .kind = kind == PTRACE_EVENT_FORK    ? XRT_BIRTH_FORK
                                           : kind == PTRACE_EVENT_VFORK ? XRT_BIRTH_VFORK
                                                                        : XRT_BIRTH_CLONE_UNKNOWN,
                                   .unpatched_probe = t->stepping ? t->step.rearm : 0,
                                   .has_saved_debug = t->threads[i].has_saved_debug,
                                   .saved_debug = t->threads[i].saved_debug};
            t->threads[i].signal = 0;
            t->threads[i].reason = kind == PTRACE_EVENT_FORK    ? XRT_STOP_FORK
                                   : kind == PTRACE_EVENT_VFORK ? XRT_STOP_VFORK
                                                                : XRT_STOP_CLONE;
            xrt_target_event(t, XRT_EVENT_PROCESS_BIRTH, (int32_t)child, tid);
            if (t->stepping && t->step.tid == tid)
                TRY(xrt_finish_step(t, false));
            TRY(xrt_stop_peers(t));
            continue;
        }
        if (kind == PTRACE_EVENT_VFORK_DONE) {
            t->threads[i].signal = 0;
            t->threads[i].reason = XRT_STOP_VFORK_DONE;
            if (t->want_run) {
                TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
                t->threads[i].state = XRT_RUNNING;
            } else
                TRY(xrt_stop_peers(t));
            continue;
        }
        if (kind == PTRACE_EVENT_CLONE) {
            TRY(xrt_add_thread(t, (int32_t)child, true));
            xrt_target_event(t, XRT_EVENT_THREAD_START, (int32_t)child, 0);
            if (t->stepping && t->step.tid == tid)
                TRY(xrt_finish_step(t, false));
            t->threads[i].reason = XRT_STOP_CLONE;
            if (t->want_run) {
                TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
                t->threads[i].state = XRT_RUNNING;
            } else
                TRY(xrt_stop_peers(t));
            continue;
        }
        if (t->threads[i].newborn && kind == PTRACE_EVENT_STOP) {
            t->threads[i].newborn = false;
            if (t->observer)
                t->observer(t->observer_context, &t->threads[i], xrt_traced_member(tid, t->pid));
            for (size_t b = 0; b < 4; ++b)
                if (t->watchpoints[b].present) {
                    const enum xrt_status result = xrt_configure_watches(t, tid);
                    if (result != XRT_OK) {
                        t->watchpoints_dirty = true;
                        TRY(xrt_stop_peers(t));
                        return result;
                    }
                    break;
                }
            if (t->want_run) {
                TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
                t->threads[i].state = XRT_RUNNING;
                continue;
            }
        }
        /* Consume only queued debugger interrupts. A genuine group stop or
         * explicit Pause must interrupt a previous run/step request. */
        if (kind == PTRACE_EVENT_STOP && sig == SIGTRAP && t->stepping && t->step.tid == tid &&
            !t->step.interrupted) {
            TRY(xrt_trace(PTRACE_SINGLESTEP, tid, 0, 0));
            t->threads[i].signal = 0;
            t->threads[i].reason = XRT_STOP_NONE;
            t->threads[i].state = XRT_RUNNING;
            continue;
        }
        if (kind == PTRACE_EVENT_STOP && sig == SIGTRAP && t->want_run) {
            TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
            t->threads[i].signal = 0;
            t->threads[i].reason = XRT_STOP_NONE;
            t->threads[i].state = XRT_RUNNING;
            continue;
        }
        t->threads[i].signal = kind == 0 ? sig : 0;
        t->threads[i].reason = kind == PTRACE_EVENT_EXEC   ? XRT_STOP_EXEC
                               : kind == PTRACE_EVENT_STOP ? XRT_STOP_INTERRUPT
                                                           : XRT_STOP_SIGNAL;
        if (kind == 0 && sig == SIGTRAP) {
            struct xrt_registers regs;
            TRY(xrt_target_registers(t, tid, &regs));
            struct xrt_signal_info info;
            TRY(xrt_signal_read(tid, &info));
            const uint64_t pc = xrt_pc(&regs);
            if (t->stepping && t->step.tid == tid) {
                const bool entry = t->step.has_exec_entry;
                t->step.has_exec_entry = false;
                const bool exec_trap =
                    t->arch->machine == XRT_X86_64
                        ? info.code == TRAP_BRKPT
                        : info.code == SI_USER && info.has_sender && !info.sender;
                if (entry && pc == t->step.exec_entry_pc && exec_trap) {
                    TRY(xrt_trace(PTRACE_SINGLESTEP, tid, 0, 0));
                    t->threads[i].signal = 0;
                    t->threads[i].reason = XRT_STOP_NONE;
                    t->threads[i].state = XRT_RUNNING;
                    continue;
                }
            }
            bool watch_hit = false;
            /* x86 #DB can carry both BS (single-step) and B0..B3 (watch).
             * Linux reports TRAP_TRACE in that case: si_code alone must not
             * discard the watch evidence or resume past a user watchpoint. */
            const bool stepped = t->stepping && t->step.tid == tid && info.code == TRAP_TRACE;
            bool armed = false;
            for (size_t b = 0; b < 4; ++b)
                armed |= t->watchpoints[b].present;
            if (info.code == 4 || (t->arch->machine == XRT_X86_64 && stepped && armed))
                TRY(xrt_watch_trap(t, tid, pc, &info, &watch_hit));
            if (watch_hit) {
                t->threads[i].signal = 0;
                t->threads[i].reason = XRT_STOP_WATCHPOINT;
                if (t->stepping)
                    TRY(xrt_finish_step(t, stepped));
                if (stepped) {
                    t->threads[i].breakpoint_address = 0;
                    xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, tid, 0);
                    t->events[t->event_count - 1].pc = pc;
                }
            } else if (t->stepping && t->step.tid == tid && info.code == TRAP_TRACE) {
                const bool stop_after = t->step.stop_after, watch = t->step.has_watch;
                t->threads[i].signal = 0;
                TRY(xrt_finish_step(t, true));
                t->threads[i].reason = watch ? XRT_STOP_WATCHPOINT : XRT_STOP_SINGLE_STEP;
                t->threads[i].breakpoint_address = 0;
                xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, tid, 0);
                t->events[t->event_count - 1].pc = pc;
                if (!stop_after) {
                    t->threads[i].reason = XRT_STOP_NONE;
                    t->state = XRT_STOPPED;
                    TRY(xrt_target_continue(t));
                    continue;
                }
            } else if (info.code == TRAP_BRKPT || info.code == SI_KERNEL) {
                uint64_t trap_pc;
                const int b = xrt_arch_breakpoint_pc(t->arch->machine, pc, &trap_pc)
                                  ? xrt_breakpoint_at(t, trap_pc)
                                  : -1;
                if (b >= 0 && t->breakpoints[b].patched) {
                    struct xrt_breakpoint *probe = &t->breakpoints[b];
                    TRY(xrt_register_write_pc(tid, probe->address));
                    t->threads[i].signal = 0;
                    t->threads[i].reason = XRT_STOP_BREAKPOINT;
                    t->threads[i].breakpoint_address = probe->address;
                    if (probe->hit_count != UINT64_MAX)
                        ++probe->hit_count;
                    xrt_target_event(t, XRT_EVENT_BREAKPOINT_HIT, tid, (int64_t)probe->id);
                    t->events[t->event_count - 1].pc = probe->address;
                }
            }
        }
        if (t->stepping && t->step.tid == tid)
            TRY(xrt_finish_step(t, false));
        xrt_target_event(t, XRT_EVENT_STOP, tid, sig);
        TRY(xrt_stop_peers(t));
    }
    TRY(xrt_poll_births(t));
    xrt_recompute_state(t);
    if (t->thread_count && t->state == XRT_STOPPED) {
        if (t->stepping) {
            const int i = xrt_thread_index(t, t->step.tid);
            if (i < 0 || t->threads[i].state == XRT_EXITED || t->step.has_watch)
                TRY(xrt_finish_step(t, false));
        }
        if (t->arch->machine == XRT_AARCH64 && !t->stepping) {
            bool started;
            TRY(xrt_start_arm_watch_completion(t, &started));
            if (started)
                return XRT_OK;
        }
        size_t b = 0;
        while (b < t->breakpoint_count) {
            const struct xrt_breakpoint probe = t->breakpoints[b];
            if (probe.temporary && !t->birth_count && !xrt_target_shared_vm(t) &&
                !xrt_target_only_internal_stops(t))
                TRY(xrt_target_breakpoint_remove(t, probe.id));
            else
                ++b;
        }
    }
    return XRT_OK;
}
enum xrt_status xrt_target_poll(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_SYNC});
    if (t->core)
        return XRT_OK;
    xrt_reap_detached(t);
    TRY(xrt_poll_births(t));
    if (!t->pid || !t->thread_count)
        return XRT_OK;
    const enum xrt_status result = poll(t);
    xrt_recompute_state(t);
    return result;
}
