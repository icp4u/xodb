#define _GNU_SOURCE 1
#include "target_internal.h"

/* Wait only on TIDs learned through launch, attach or kernel birth events.
 * Other subsystems may own traced children of this same debugger process. */
static enum xrt_status wait_known(struct xrt_target *t, int32_t *tid, int *status)
{
    *tid = 0;
    /* The held vfork child is not a thread of this target. Drain it first so
     * an exit stop cannot sit uncollected while the parent waits in vfork. */
    if (t->vfork_hold) {
        const pid_t got = waitpid(t->vfork_hold, status, __WALL | WNOHANG);
        if (got > 0) {
            *tid = got;
            return XRT_OK;
        }
        if (got < 0 && errno == ECHILD) {
            t->vfork_hold = 0;
            t->vfork_hold_detach = 0;
        } else if (got < 0 && errno != EINTR)
            return XRT_WAIT_FAILED;
    }
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
/* Fork inherits patched bytes in its own address space. Put the original
 * instruction back in that child before it can execute the word. user_probes
 * restores breakpoints as well as temporary step traps. Never call this for a
 * vfork: the child shares the parent's pages, so the write would clear the
 * parent's traps while the record stayed patched. */
static enum xrt_status restore_child_probes(struct xrt_target *t, int32_t child, int user_probes)
{
    for (size_t p = 0; p < t->breakpoint_count; ++p) {
        const struct xrt_breakpoint *probe = &t->breakpoints[p];
        if (!probe->patched || !probe->width)
            continue;
        if (!user_probes && !probe->temporary)
            continue;
        const enum xrt_status status =
            xrt_patch_instruction_tid(t, child, probe->address, probe->original, probe->width);
        if (status != XRT_OK)
            return status;
    }
    return XRT_OK;
}
/* x86 can adopt a birth. Every other row refuses process following, so a held
 * child would leave continue and step stuck on PROCESS_BIRTH_PENDING. */
static int row_cannot_follow(const struct xrt_target *t)
{
    return t->arch && t->arch->machine != XRT_X86_64;
}
/* Move every probe the record still calls patched. The flag is the list of
 * traps to put back; only the shared bytes change. */
static enum xrt_status rewrite_patched(struct xrt_target *t, int plant)
{
    for (size_t p = 0; p < t->breakpoint_count; ++p) {
        const struct xrt_breakpoint *probe = &t->breakpoints[p];
        if (!probe->patched || !probe->width)
            continue;
        TRY(xrt_patch_instruction(t, probe->address, plant ? probe->planted : probe->original,
                                  probe->width));
    }
    return XRT_OK;
}
static enum xrt_status on_held_vfork_child(struct xrt_target *t, int status)
{
    const int32_t child = t->vfork_hold;
    if (!child)
        return XRT_OK;
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
        t->vfork_hold = 0;
        t->vfork_hold_detach = 0;
        return XRT_OK;
    }
    if (!WIFSTOPPED(status))
        return XRT_OK;
    if (t->vfork_hold_detach) {
        const enum xrt_status detached = xrt_trace(PTRACE_DETACH, child, 0, 0);
        t->vfork_hold = 0;
        t->vfork_hold_detach = 0;
        return detached == XRT_PROCESS_GONE ? XRT_OK : detached;
    }
    const unsigned kind = (unsigned)status >> 16;
    const int sig = WSTOPSIG(status);
    /* A trap left in the shared image must not be delivered. Other signals pass. */
    const int pass = kind == 0 && sig != SIGTRAP && sig != SIGSTOP ? sig : 0;
    return xrt_trace(PTRACE_CONT, child, 0, (uintptr_t)pass);
}
enum xrt_status xrt_detach_held_vfork(struct xrt_target *t)
{
    if (!t->vfork_hold)
        return XRT_OK;
    t->vfork_hold_detach = 1;
    int status = 0;
    const pid_t got = waitpid(t->vfork_hold, &status, __WALL | WNOHANG);
    if (got == t->vfork_hold)
        return on_held_vfork_child(t, status);
    if (got < 0 && errno == ECHILD) {
        t->vfork_hold = 0;
        t->vfork_hold_detach = 0;
        return XRT_OK;
    }
    if (got < 0 && errno != EINTR)
        return XRT_WAIT_FAILED;
    const enum xrt_status detached = xrt_trace(PTRACE_DETACH, t->vfork_hold, 0, 0);
    if (detached == XRT_OK) {
        t->vfork_hold = 0;
        t->vfork_hold_detach = 0;
        return XRT_OK;
    }
    if (detached != XRT_PROCESS_GONE)
        return detached;
    /* Still running. The next stop, including the interrupt, detaches it. */
    const enum xrt_status interrupted = xrt_trace(PTRACE_INTERRUPT, t->vfork_hold, 0, 0);
    if (interrupted == XRT_PROCESS_GONE) {
        t->vfork_hold = 0;
        t->vfork_hold_detach = 0;
        return XRT_OK;
    }
    return interrupted;
}
void xrt_drop_vfork_hold(struct xrt_target *t)
{
    if (!t)
        return;
    const int32_t child = t->vfork_hold;
    t->vfork_hold = 0;
    t->vfork_release = 0;
    t->vfork_hold_detach = 0;
    if (child <= 0)
        return;
    kill(child, SIGKILL);
    for (;;) {
        int status = 0;
        const pid_t got = waitpid(child, &status, __WALL);
        if (got < 0 && errno == EINTR)
            continue;
        if (got < 0 || WIFEXITED(status) || WIFSIGNALED(status))
            return;
        if (WIFSTOPPED(status))
            xrt_trace(PTRACE_CONT, child, 0, (uintptr_t)SIGKILL);
    }
}
static enum xrt_status poll(struct xrt_target *t)
{
    int held_spins = 0;
    for (;;) {
        int32_t tid;
        int status = 0;
        TRY(wait_known(t, &tid, &status));
        if (!tid)
            break;
        if (t->vfork_hold && tid == t->vfork_hold) {
            /* A trap we failed to lift would stop the child forever. Detach
             * rather than spin; VFORK_DONE still replants the parent. */
            if (++held_spins > 32) {
                TRY(xrt_detach_held_vfork(t));
                continue;
            }
            TRY(on_held_vfork_child(t, status));
            continue;
        }
        held_spins = 0;
        int i = xrt_thread_index(t, tid);
        assert(i >= 0);
        if (WIFEXITED(status) || WIFSIGNALED(status)) {
            xrt_target_event(t, XRT_EVENT_EXIT, tid,
                             WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status));
            t->threads[i] = t->threads[--t->thread_count];
            if (!t->thread_count) {
                t->state = XRT_EXITED;
                xrt_drop_vfork_hold(t);
                TRY(xrt_separate_vfork(t));
                t->stepping = false;
                /* The process is gone, so the successor trap cannot be
                 * unpatched. Drop it from the view; restart does not reinstall
                 * a temporary probe. */
                size_t kept = 0;
                for (size_t p = 0; p < t->breakpoint_count; ++p) {
                    if (t->breakpoints[p].temporary)
                        continue;
                    if (kept != p)
                        t->breakpoints[kept] = t->breakpoints[p];
                    ++kept;
                }
                t->breakpoint_count = kept;
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
            const enum xrt_status ident = xrt_process_validate_native(tid);
            xrt_target_apply_exec_identity(t, ident);
            if (ident != XRT_OK)
                return ident;
        }
        unsigned long child = 0;
        if (kind == PTRACE_EVENT_FORK || kind == PTRACE_EVENT_VFORK || kind == PTRACE_EVENT_CLONE)
            TRY(xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&child));
        if (kind == PTRACE_EVENT_FORK || kind == PTRACE_EVENT_VFORK ||
            (kind == PTRACE_EVENT_CLONE && !xrt_traced_member((int32_t)child, t->pid))) {
            if (row_cannot_follow(t)) {
                const int stepping_here = t->stepping && t->step.tid == tid;
                const int shared = kind == PTRACE_EVENT_VFORK;
                if (shared) {
                    /* The child shares this image and starts stopped. Lift every
                     * trap so a user breakpoint or a successor plant cannot kill
                     * it, keep it traced, and let it run. The records stay
                     * patched. Userspace on the parent waits until VFORK_DONE
                     * puts the traps back. A software step then hits its
                     * successor with the real child pid. */
                    TRY(rewrite_patched(t, 0));
                    t->vfork_hold = (int32_t)child;
                    t->vfork_release = 1;
                    t->vfork_hold_detach = 0;
                    const enum xrt_status ran = xrt_trace(PTRACE_CONT, (int32_t)child, 0, 0);
                    if (ran != XRT_OK && ran != XRT_PROCESS_GONE)
                        return ran;
                    t->threads[i].signal = 0;
                    if (stepping_here || t->want_run) {
                        TRY(xrt_trace(PTRACE_CONT, tid, 0, 0));
                        t->threads[i].state = XRT_RUNNING;
                        t->threads[i].reason = XRT_STOP_NONE;
                        continue;
                    }
                    TRY(xrt_stop_peers(t));
                    continue;
                }
                /* Separate address space. The parent's traps stay where they are. */
                TRY(restore_child_probes(t, (int32_t)child, 1));
                TRY(xrt_trace(PTRACE_DETACH, (int32_t)child, 0, 0));
                t->threads[i].signal = 0;
                if (stepping_here || t->want_run) {
                    /* A hardware step is still one instruction. CONT would run
                     * past it. A software step is resumed with CONT because its
                     * successor trap is already planted in this address space. */
                    const int hardware_step = stepping_here && !t->step.software;
                    TRY(xrt_trace(hardware_step ? PTRACE_SINGLESTEP : PTRACE_CONT, tid, 0, 0));
                    t->threads[i].state = XRT_RUNNING;
                    t->threads[i].reason = XRT_STOP_NONE;
                    continue;
                }
                TRY(xrt_stop_peers(t));
                continue;
            }
            TRY(restore_child_probes(t, (int32_t)child, 0));
            /* x86, following off: a software step must not leave the child
             * stopped or holding the successor trap. */
            if (t->stepping && t->step.software && t->step.tid == tid && !t->follow_processes) {
                TRY(xrt_trace(PTRACE_DETACH, (int32_t)child, 0, 0));
                TRY(xrt_finish_step(t, true));
                t->threads[i].signal = 0;
                t->threads[i].reason = XRT_STOP_SINGLE_STEP;
                t->threads[i].breakpoint_address = 0;
                TRY(xrt_stop_peers(t));
                continue;
            }
            assert(t->birth_count < XRT_MAX_THREADS);
            if (!t->birth_count) {
                t->birth_image_epoch = t->image_epoch;
                t->birth_breakpoint_count = 0;
                for (size_t p = 0; p < t->breakpoint_count; ++p) {
                    if (t->breakpoints[p].temporary)
                        continue;
                    t->birth_breakpoints[t->birth_breakpoint_count++] = t->breakpoints[p];
                }
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
            if (t->vfork_release) {
                /* The child has exec'd or exited, so this image is the parent's
                 * alone. Put back every probe the record still calls patched,
                 * then detach the child before userspace runs. */
                TRY(rewrite_patched(t, 1));
                t->vfork_release = 0;
                TRY(xrt_detach_held_vfork(t));
                const int stepping_here = t->stepping && t->step.tid == tid;
                if (stepping_here || t->want_run) {
                    const int hardware_step = stepping_here && !t->step.software;
                    TRY(xrt_trace(hardware_step ? PTRACE_SINGLESTEP : PTRACE_CONT, tid, 0, 0));
                    t->threads[i].state = XRT_RUNNING;
                    t->threads[i].reason = XRT_STOP_NONE;
                } else
                    TRY(xrt_stop_peers(t));
                continue;
            }
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
            !t->step.interrupted && !t->step.software) {
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
        /* Go preempts goroutines with SIGURG many times a second. Like gdb's
         * default (nostop, noprint, pass), deliver it without a user stop. A
         * hardware-stepped thread drops it: delivery would step into the
         * handler, and the Go runtime simply retries the preemption. */
        const bool step_here = t->stepping && t->step.tid == tid;
        if (kind == 0 && sig == SIGURG && (step_here ? !t->step.software : t->want_run)) {
            TRY(xrt_trace(step_here ? PTRACE_SINGLESTEP : PTRACE_CONT, tid, 0, step_here ? 0 : SIGURG));
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
            uint64_t pc = 0;
            const enum xrt_status pc_status = xrt_registers_pc(&regs, &pc);
            if (pc_status != XRT_OK)
                return pc_status;
            if (t->stepping && t->step.software && t->step.tid == tid) {
                int handled = 0;
                TRY(xrt_software_step_hit(t, i, pc, &handled));
                if (handled == 2)
                    continue;
                if (handled == 1)
                    goto software_stopped;
            }
            if (t->stepping && t->step.tid == tid) {
                const bool entry = t->step.has_exec_entry;
                t->step.has_exec_entry = false;
                const bool exec_trap =
                    t->arch->machine == XRT_X86_64
                        ? info.code == TRAP_BRKPT
                        : info.code == SI_USER && info.has_sender && !info.sender;
                /* m68k syscall return clears the trace bit and posts SIGTRAP
                 * with SI_KERNEL before the stepped instruction runs. One more
                 * single-step leaves that signal stop with the trace bit set.
                 * exec_entry_pc is the pc at PTRACE_SINGLESTEP, then cleared
                 * so a second kernel trap is reported. */
                const bool m68k_delayed = t->arch->machine == XRT_M68K && !t->step.software &&
                                          info.code == SI_KERNEL && t->step.exec_entry_pc != 0 &&
                                          pc == t->step.exec_entry_pc;
                if ((entry && pc == t->step.exec_entry_pc && exec_trap && !t->step.software) ||
                    m68k_delayed) {
                    if (m68k_delayed)
                        t->step.exec_entry_pc = 0;
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
                    t->events[t->event_count - 1].pc_known = 1;
                }
            } else if (t->stepping && t->step.tid == tid && info.code == TRAP_TRACE) {
                const bool stop_after = t->step.stop_after, watch = t->step.has_watch;
                t->threads[i].signal = 0;
                TRY(xrt_finish_step(t, true));
                t->threads[i].reason = watch ? XRT_STOP_WATCHPOINT : XRT_STOP_SINGLE_STEP;
                t->threads[i].breakpoint_address = 0;
                xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, tid, 0);
                t->events[t->event_count - 1].pc = pc;
                t->events[t->event_count - 1].pc_known = 1;
                if (!stop_after) {
                    t->threads[i].reason = XRT_STOP_NONE;
                    t->state = XRT_STOPPED;
                    TRY(xrt_target_continue(t));
                    continue;
                }
            } else if (info.code == TRAP_BRKPT || info.code == SI_KERNEL) {
                uint64_t trap_pc;
                if (t->stepping && t->step.tid == tid && xrt_atomic_step_exit(t, pc)) {
                    const bool stop_after = t->step.stop_after;
                    t->threads[i].signal = 0;
                    TRY(xrt_finish_step(t, true));
                    t->threads[i].reason = XRT_STOP_SINGLE_STEP;
                    t->threads[i].breakpoint_address = 0;
                    xrt_target_event(t, XRT_EVENT_STEP_COMPLETE, tid, 0);
                    t->events[t->event_count - 1].pc = pc;
                    t->events[t->event_count - 1].pc_known = 1;
                    if (!stop_after) {
                        t->threads[i].reason = XRT_STOP_NONE;
                        t->state = XRT_STOPPED;
                        TRY(xrt_target_continue(t));
                        continue;
                    }
                } else {
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
                    t->events[t->event_count - 1].pc_known = 1;
                }
                }
            }
        }
    software_stopped:
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
