#define _GNU_SOURCE 1
#include "target_internal.h"
#include <sched.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/user.h>

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
/* Wait for a traced child to stop. 1: stopped. 0: it died and was collected,
 * or is not ours to wait for. -1: no stop within two seconds. A new child
 * cannot run userspace before its first stop, so this normally takes
 * microseconds; the bound keeps a starved or frozen child from hanging the
 * debugger. Never waits on pid 0: that would take any child's status. */
static int settle_child(int32_t child)
{
    if (child <= 0)
        return 0;
    const uint64_t deadline = xrt_now() + UINT64_C(2000000000);
    for (unsigned spin = 0;; ++spin) {
        int status = 0;
        const pid_t got = waitpid(child, &status, __WALL | WNOHANG);
        if (got == child)
            return WIFSTOPPED(status) ? 1 : 0;
        if (got < 0 && errno != EINTR)
            return 0;
        if (xrt_now() >= deadline)
            return -1;
        if (spin < 64)
            sched_yield();
        else
            usleep(200);
    }
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
    const int released = t->vfork_release;
    t->vfork_hold = 0;
    t->vfork_release = 0;
    memset(t->vfork_waiting, 0, sizeof(t->vfork_waiting));
    t->vfork_hold_detach = 0;
    if (child <= 0)
        return;
    /* A released child only borrowed the image, whose traps are lifted. It
     * is not ours to kill: let it go, in a stop now or at the interrupt. */
    if (released) {
        if (xrt_trace(PTRACE_DETACH, child, 0, 0) == XRT_OK)
            return;
        xrt_trace(PTRACE_INTERRUPT, child, 0, 0);
        const int stopped = settle_child(child);
        if (!stopped || (stopped > 0 && xrt_trace(PTRACE_DETACH, child, 0, 0) == XRT_OK))
            return;
    }
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
/* Default action is ignore. No per-signal stop request exists; this predicate
 * is where one would go. */
static const int ignored_signals[] = {SIGCHLD, SIGWINCH, SIGURG};
static int default_ignored(int sig)
{
    return sig == SIGCHLD || sig == SIGWINCH || sig == SIGURG;
}
/* x86 reports PTRACE_SINGLESTEP of `syscall` as TRAP_BRKPT at syscall exit,
 * with the PC already on the next instruction. For a call a signal
 * interrupted that is before the restart rewinds the PC.
 * The two bytes at `entry` are the opcode. */
static int x86_open_syscall(struct xrt_target *t, uint64_t entry, uint64_t pc)
{
    if (!t->arch || t->arch->machine != XRT_X86_64 || !entry || pc != entry + 2)
        return 0;
    uint8_t op[2];
    size_t count = 0;
    /* The target is not marked stopped yet, so the overlay read would refuse. */
    if (xrt_memory_read(t->step.tid, entry, op, 2, &count) != XRT_OK || count != 2)
        return 0;
    return op[0] == 0x0f && op[1] == 0x05;
}
/* x86-64 syscall numbers and errnos, as the stopped registers show them. */
enum { X86_RT_SIGRETURN = 15, X86_RESTART_SYSCALL = 219, X86_ENOSYS = 38 };
/* The call was interrupted and the kernel has not yet chosen between restart
 * and EINTR. Any other rax at the step trap is a finished call, -ENOSYS
 * included: a single-step reports at syscall exit, never at entry. */
static int syscall_restarting(uint64_t rax)
{
    const int64_t value = (int64_t)rax;
    return value == -512 || value == -513 || value == -514 || value == -516;
}
static enum xrt_status syscall_regs(int32_t tid, uint64_t *rax, uint64_t *orig)
{
#if defined(__x86_64__)
    struct user_regs_struct regs;
    const enum xrt_status status = xrt_trace(PTRACE_GETREGS, tid, 0, (uintptr_t)&regs);
    if (status != XRT_OK)
        return status;
    *rax = (uint64_t)regs.rax;
    *orig = (uint64_t)regs.orig_rax;
    return XRT_OK;
#else
    (void)tid;
    (void)rax;
    (void)orig;
    return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
}
static enum xrt_status resume_open_syscall(struct xrt_target *t, int i, int32_t tid, int sig)
{
    TRY(xrt_trace(PTRACE_SYSCALL, tid, 0, (uintptr_t)sig));
    if (sig || !default_ignored(t->threads[i].signal))
        t->threads[i].signal = 0;
    t->threads[i].reason = XRT_STOP_NONE;
    t->threads[i].state = XRT_RUNNING;
    return XRT_OK;
}
/* The thread record carries one signal for the resume. When the stepped
 * thread reports another before its instruction retires, the earlier one
 * would be overwritten and never delivered. Park it for the end of the step. */
static void park_signal(struct xrt_target *t, int32_t tid, int held, int incoming)
{
    if (!t->stepping || t->step.tid != tid || held == incoming)
        return;
    for (size_t k = 0; k < sizeof ignored_signals / sizeof ignored_signals[0]; ++k)
        if (ignored_signals[k] == held)
            t->step.parked |= (uint8_t)(1u << k);
}
void xrt_requeue_parked(struct xrt_target *t)
{
    const uint8_t parked = t->step.parked;
    t->step.parked = 0;
    /* The thread is in a ptrace stop, so these stay pending until it is
     * resumed and are then reported like any other arrival. A thread that
     * has exited takes nothing. */
    for (size_t k = 0; k < sizeof ignored_signals / sizeof ignored_signals[0]; ++k)
        if (parked & (1u << k))
            (void)syscall(SYS_tgkill, (pid_t)t->pid, (pid_t)t->step.tid, ignored_signals[k]);
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
            /* A thread that was waiting in vfork is gone with the old image,
             * and so is its VFORK_DONE. Let any borrowing child go. */
            if (t->vfork_release)
                xrt_drop_vfork_hold(t);
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
            /* Not following: make the child safe and let it go, so a program
             * that spawns a helper runs without anyone resolving the birth. */
            int release = row_cannot_follow(t);
            int shared = kind == PTRACE_EVENT_VFORK;
            if (!release && !t->follow_processes) {
                /* The event kind does not say whether memory is shared. A
                 * shared clone that is not a vfork, or a failed comparison,
                 * stays held as before. */
                const long same = syscall(SYS_kcmp, tid, (int32_t)child, 1, 0UL, 0UL);
                release = same > 0 || (same == 0 && shared);
                shared = same == 0;
            }
            /* A bounded number of children may borrow the image at once. */
            if (release && shared &&
                t->vfork_release == sizeof(t->vfork_waiting) / sizeof(t->vfork_waiting[0]))
                release = 0;
            /* The child is ptrace-stopped before its first instruction but
             * may not have reached that stop yet. Collect it before touching
             * it. If it was killed first there is nothing to do. With no stop
             * in time it is held like any unfollowed birth used to be. */
            const int settled = release ? settle_child((int32_t)child) : 0;
            if (settled < 0)
                release = 0;
            if (release) {
                const int stepping_here = t->stepping && t->step.tid == tid;
                const int alive = settled > 0;
                if (alive)
                    xrt_target_event(t, XRT_EVENT_PROCESS_RELEASED, (int32_t)child, tid);
                shared = shared && alive;
                if (shared) {
                    /* The child shares this image and starts stopped. Lift every
                     * trap so a user breakpoint or a successor plant cannot kill
                     * it, keep it traced, and let it run. The records stay
                     * patched. Userspace on the parent waits until VFORK_DONE
                     * puts the traps back. A software step then hits its
                     * successor with the real child pid. */
                    TRY(rewrite_patched(t, 0));
                    /* The borrower's own children and its exec are not ours:
                     * without options nothing it starts is attached to us. */
                    xrt_trace(PTRACE_SETOPTIONS, (int32_t)child, 0, 0);
                    for (size_t w = 0; w < sizeof(t->vfork_waiting) / sizeof(t->vfork_waiting[0]); ++w)
                        if (!t->vfork_waiting[w]) {
                            t->vfork_waiting[w] = tid;
                            break;
                        }
                    ++t->vfork_release;
                    enum xrt_status ran;
                    if (t->vfork_hold) {
                        /* Threads may spawn at the same time. One borrower is
                         * kept traced to absorb a stray trap; the image is
                         * already clean, so a later one is let go at once. */
                        ran = xrt_trace(PTRACE_DETACH, (int32_t)child, 0, 0);
                        if (ran == XRT_PROCESS_GONE && t->reap_count < 2048)
                            xrt_remember_reap(t, (int32_t)child);
                    } else {
                        t->vfork_hold = (int32_t)child;
                        t->vfork_hold_detach = 0;
                        ran = xrt_trace(PTRACE_CONT, (int32_t)child, 0, 0);
                    }
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
                if (alive) {
                    enum xrt_status gone = restore_child_probes(t, (int32_t)child, 1);
                    if (gone == XRT_OK)
                        gone = xrt_trace(PTRACE_DETACH, (int32_t)child, 0, 0);
                    /* Killed while stopped: only its tracer can collect it, and
                     * until then its parent's wait would not see it. */
                    if (gone == XRT_PROCESS_GONE && t->reap_count < 2048)
                        xrt_remember_reap(t, (int32_t)child);
                    else if (gone != XRT_OK && gone != XRT_PROCESS_GONE)
                        return gone;
                }
                t->threads[i].signal = 0;
                if (stepping_here || t->want_run) {
                    /* A hardware step is still one instruction. CONT would run
                     * past it. A software step is resumed with CONT because its
                     * successor trap is already planted in this address space.
                     * A larx/stcx. step is resumed with CONT; single-step would
                     * clear the reservation. */
                    const int hardware_step =
                        stepping_here && !t->step.software && !t->step.atomic_run;
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
            size_t owed = 0;
            while (owed < sizeof(t->vfork_waiting) / sizeof(t->vfork_waiting[0]) &&
                   t->vfork_waiting[owed] != tid)
                ++owed;
            if (owed < sizeof(t->vfork_waiting) / sizeof(t->vfork_waiting[0])) {
                /* This thread's child has exec'd or exited. Once no child
                 * borrows the image it is the parent's alone: put back every
                 * probe the record still calls patched. The traced child is
                 * detached before userspace runs; if it is another thread's it
                 * keeps the clean image until that thread's own VFORK_DONE. */
                t->vfork_waiting[owed] = 0;
                if (t->vfork_release)
                    --t->vfork_release;
                if (!t->vfork_release)
                    TRY(rewrite_patched(t, 1));
                TRY(xrt_detach_held_vfork(t));
                const int stepping_here = t->stepping && t->step.tid == tid;
                if (stepping_here || t->want_run) {
                    /* A signal handler that runs inside a larx/stcx. step may
                     * vfork. That step stays on CONT like the fork resume. */
                    const int hardware_step =
                        stepping_here && !t->step.software && !t->step.atomic_run;
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
            /* An open syscall must keep stopping at its exit. Single-step would
             * clear a larx reservation, so that step is continued. */
            TRY(xrt_trace(t->step.syscall_open  ? PTRACE_SYSCALL
                          : t->step.atomic_run ? PTRACE_CONT
                                               : PTRACE_SINGLESTEP,
                          tid, 0, 0));
            if (!default_ignored(t->threads[i].signal))
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
        /* SIGCHLD, SIGWINCH and SIGURG are ignored by default. Deliver them
         * and keep running, including a step and the hidden step a Continue
         * takes off a breakpoint. A peer of the stepped thread is resumed the
         * same way, so its signal does not cancel the step. No per-signal
         * stop request exists; this guard is where one would go. An idle stop
         * that is not a step still reports the signal. */
        const bool step_here = t->stepping && t->step.tid == tid;
        if (kind == 0 && default_ignored(sig) && step_here && t->step.syscall_open) {
            /* The call is still in the kernel. CONT would let the restart
             * execute the replanted breakpoint. */
            park_signal(t, tid, t->threads[i].signal, sig);
            TRY(resume_open_syscall(t, i, tid, sig));
            continue;
        }
        if (kind == 0 && default_ignored(sig) && (step_here || t->want_run || t->stepping)) {
            int advanced = 0;
            uint64_t pc = 0;
            /* A hardware step that already retired its instruction reports
             * the pending signal with the PC moved. Finishing another
             * single-step would skip one more instruction. A stop still at
             * the stepped PC has not retired it. */
            /* atomic_run is a larx/stcx. sequence on PTRACE_CONT. The PC moves
             * through the sequence before the exit trap. That is not the step
             * ending, and single-step would clear the reservation. */
            if (step_here && !t->step.software && !t->step.atomic_run && t->step.exec_entry_pc) {
                struct xrt_registers regs;
                if (xrt_target_registers(t, tid, &regs) == XRT_OK &&
                    xrt_registers_pc(&regs, &pc) == XRT_OK && pc != t->step.exec_entry_pc)
                    advanced = 1;
            }
            if (advanced) {
                const bool stop_after = t->step.stop_after;
                park_signal(t, tid, t->threads[i].signal, sig);
                t->threads[i].signal = sig;
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
                TRY(xrt_stop_peers(t));
                continue;
            }
            if (step_here && !t->step.software && !t->step.atomic_run) {
                /* The instruction has not retired, and the signal is already
                 * dequeued. Single-step with zero so delivery does not enter
                 * the handler. The step trap keeps this signal and injects it
                 * on the resume; injecting it here would single-step into the
                 * handler and then hit the same breakpoint again. A signal
                 * already held from an earlier report of this step is parked. */
                park_signal(t, tid, t->threads[i].signal, sig);
                t->threads[i].signal = sig;
                TRY(xrt_trace(PTRACE_SINGLESTEP, tid, 0, 0));
                t->threads[i].reason = XRT_STOP_NONE;
                t->threads[i].state = XRT_RUNNING;
                continue;
            }
            TRY(xrt_trace(PTRACE_CONT, tid, 0, (uintptr_t)sig));
            t->threads[i].signal = 0;
            t->threads[i].reason = XRT_STOP_NONE;
            t->threads[i].state = XRT_RUNNING;
            continue;
        }
        /* A hardware step may already be holding an ignore-default signal
         * while this SIGTRAP retires the instruction. Keep it. */
        if (!(kind == 0 && sig == SIGTRAP && t->stepping && t->step.tid == tid &&
              default_ignored(t->threads[i].signal))) {
            park_signal(t, tid, t->threads[i].signal, kind == 0 ? sig : 0);
            t->threads[i].signal = kind == 0 ? sig : 0;
        }
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
            /* PTRACE_O_TRACESYSGOOD is not set, so a syscall stop is SIGTRAP
             * with si_code SIGTRAP. Any other trap while the call is open,
             * such as a breakpoint inside the signal handler, is an ordinary
             * stop and ends the step below. */
            if (t->step.syscall_open && t->stepping && t->step.tid == tid && info.code == SIGTRAP) {
                uint64_t rax = 0, orig = 0;
                TRY(syscall_regs(tid, &rax, &orig));
                bool over = false;
                if ((int64_t)rax == -X86_ENOSYS)
                    /* Entry stop. Remember a signal return for its exit. */
                    t->step.syscall_sigreturn = orig == X86_RT_SIGRETURN;
                else if (t->step.syscall_sigreturn) {
                    /* rt_sigreturn has put the interrupted registers back. A
                     * PC on the syscall is the kernel's restart. Anywhere else
                     * the call is over (EINTR) and the program runs on, so the
                     * breakpoint must be back before it can arrive again. */
                    t->step.syscall_sigreturn = 0;
                    over = pc != t->step.exec_entry_pc;
                } else
                    /* The exit of the call itself, or of the restart_syscall
                     * the kernel substituted, back at the stepped site. */
                    over = pc == t->step.exec_entry_pc + 2 && !syscall_restarting(rax) &&
                           (orig == t->step.syscall_nr || orig == X86_RESTART_SYSCALL);
                if (!over) {
                    TRY(resume_open_syscall(t, i, tid, 0));
                    continue;
                }
                const bool stop_after = t->step.stop_after;
                t->step.syscall_open = 0;
                if (!default_ignored(t->threads[i].signal))
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
                TRY(xrt_stop_peers(t));
                continue;
            }
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
                    if (!default_ignored(t->threads[i].signal))
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
            /* x86 reports a hardware step that ends in the kernel (the
             * instruction was a syscall, or the step resumed a fork event
             * stop) as TRAP_BRKPT at syscall exit. A real int3 arrives as
             * SI_KERNEL, and the exec entry case was taken above, so here the
             * code means the stepped instruction has completed. */
            const bool step_trap =
                info.code == TRAP_TRACE || (t->arch->machine == XRT_X86_64 && !t->step.software &&
                                            info.code == TRAP_BRKPT);
            const bool stepped = t->stepping && t->step.tid == tid && step_trap;
            bool armed = false;
            for (size_t b = 0; b < 4; ++b)
                armed |= t->watchpoints[b].present;
            if (info.code == 4 || (t->arch->machine == XRT_X86_64 && stepped && armed))
                TRY(xrt_watch_trap(t, tid, pc, &info, &watch_hit));
            if (watch_hit) {
                if (!default_ignored(t->threads[i].signal))
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
            } else if (stepped) {
                /* A syscall a signal interrupted reports this trap with a
                 * restart errno, before the kernel restarts it or returns
                 * EINTR. Leave its breakpoint lifted and stop at the real exit.
                 * A syscall that already returned has an ordinary rax and
                 * finishes like any other instruction. */
                if (!t->step.stop_after && !t->step.has_watch &&
                    x86_open_syscall(t, t->step.exec_entry_pc, pc)) {
                    uint64_t rax = 0, orig = 0;
                    TRY(syscall_regs(tid, &rax, &orig));
                    if (syscall_restarting(rax)) {
                        t->step.syscall_nr = orig;
                        t->step.syscall_open = 1;
                        t->step.syscall_sigreturn = 0;
                        t->threads[i].breakpoint_address = 0;
                        if (!default_ignored(t->threads[i].signal))
                            t->threads[i].signal = 0;
                        TRY(resume_open_syscall(t, i, tid, 0));
                        continue;
                    }
                }
                const bool stop_after = t->step.stop_after, watch = t->step.has_watch;
                /* A hardware step holds an ignore-default signal here until
                 * this trap. Clearing it would drop the handler. */
                if (!default_ignored(t->threads[i].signal))
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
                    if (!default_ignored(t->threads[i].signal))
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
