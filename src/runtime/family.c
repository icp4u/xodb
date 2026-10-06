#define _GNU_SOURCE 1
#include "target_internal.h"
#include <stdio.h>
#include <sys/syscall.h>

bool xrt_target_shared_vm(const struct xrt_target *t)
{
    if (t && t->connection)
        return t->remote_shared;
    if (!t)
        return false;
    if (t->vfork_parent)
        return true;
    for (size_t i = 0; i < XRT_MAX_THREADS; ++i)
        if (t->vfork_children[i])
            return true;
    return false;
}
const struct xrt_target *xrt_target_family_root(const struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_root(t);
    if (t)
        while (t->vfork_parent)
            t = t->vfork_parent;
    return t;
}
size_t xrt_shared_family(struct xrt_target *t, struct xrt_target *out[32])
{
    while (t->vfork_parent)
        t = t->vfork_parent;
    out[0] = t;
    size_t count = 1;
    for (size_t at = 0; at < count; ++at)
        for (size_t i = 0; i < XRT_MAX_THREADS; ++i) {
            if (!out[at]->vfork_children[i])
                continue;
            assert(count < 32);
            out[count++] = out[at]->vfork_children[i];
        }
    return count;
}
enum xrt_status xrt_memory_mutation_allowed(const struct xrt_target *t)
{
    if (t->detach_pending)
        return XRT_DETACH_INCOMPLETE;
    if (t->birth_count)
        return XRT_PROCESS_BIRTH_PENDING;
    if (xrt_target_shared_vm(t))
        return XRT_SHARED_ADDRESS_SPACE;
    return XRT_OK;
}
enum xrt_status xrt_execution_allowed(const struct xrt_target *t)
{
    if (t->detach_pending)
        return XRT_DETACH_INCOMPLETE;
    if (t->birth_count)
        return XRT_PROCESS_BIRTH_PENDING;
    if (!t->identity_admitted || !t->arch || t->arch != xrt_arch_native())
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->plant_cleanup.active)
        return XRT_INVALID_STATE;
    for (size_t i = 0; i < XRT_MAX_THREADS; ++i)
        if (t->vfork_children[i])
            return XRT_VFORK_PARENT_BLOCKED;
    if (t->vfork_parent) {
        struct xrt_target *family[32];
        const size_t count = xrt_shared_family((struct xrt_target *)t, family);
        for (size_t i = 0; i < count; ++i)
            if (family[i] != t && (family[i]->state == XRT_RUNNING || family[i]->birth_count))
                return XRT_SHARED_ADDRESS_SPACE_PEER_RUNNING;
    }
    return XRT_OK;
}
enum xrt_status xrt_target_set_following(struct xrt_target *t, bool enabled)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FOLLOW, .args = {enabled}});
    if (!t->arch || t->arch->machine != XRT_X86_64)
        return XRT_UNSUPPORTED_PROCESS_FOLLOWING;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (t->state != XRT_STOPPED || t->stepping)
        return XRT_NOT_STOPPED;
    if (xrt_target_shared_vm(t))
        return XRT_SHARED_ADDRESS_SPACE;
    for (size_t i = 0; i < t->thread_count; ++i)
        if (t->threads[i].state == XRT_STOPPED) {
            const enum xrt_status status = xrt_trace(PTRACE_SETOPTIONS, t->threads[i].tid, 0,
                                                     xrt_process_options(t->owned, enabled));
            if (status != XRT_OK) {
                for (size_t j = 0; j < t->thread_count; ++j)
                    if (t->threads[j].state == XRT_STOPPED)
                        xrt_trace(PTRACE_SETOPTIONS, t->threads[j].tid, 0,
                                  xrt_process_options(t->owned, t->follow_processes));
                return status;
            }
        }
    t->follow_processes = enabled;
    ++t->generation;
    return XRT_OK;
}
enum xrt_status xrt_poll_births(struct xrt_target *t)
{
    for (size_t i = 0; i < t->birth_count; ++i) {
        struct xrt_birth *birth = &t->births[i];
        if (birth->stopped || birth->exited)
            continue;
        int status = 0;
        const pid_t got = waitpid(birth->pid, &status, __WALL | WNOHANG);
        if (!got || (got < 0 && errno == EINTR))
            continue;
        if (got < 0)
            return XRT_CHILD_WAIT_FAILED;
        birth->status = status;
        if (WIFEXITED(status) || WIFSIGNALED(status))
            birth->exited = true;
        else if (WIFSTOPPED(status)) {
            birth->stopped = true;
            if ((unsigned)status >> 16 != PTRACE_EVENT_STOP)
                return XRT_UNEXPECTED_CHILD_INITIAL_STOP;
        } else
            return XRT_UNEXPECTED_CHILD_INITIAL_STOP;
        ++t->generation;
    }
    return XRT_OK;
}
/* The child image is its own identity. Re-read it; do not copy the parent's flag. */
static void admit_adopted(const struct xrt_target *parent, struct xrt_target *out, int32_t pid,
                          bool exited)
{
    out->arch = parent->arch;
    out->identity_admitted = 0;
    if (exited || !out->arch || xrt_process_validate_native(pid) != XRT_OK)
        return;
    const struct xrt_arch *native = xrt_arch_native();
    if (out->arch == native && native && xrt_arch_validate(native) == XRT_OK)
        out->identity_admitted = 1;
}
enum xrt_status xrt_target_adopt(struct xrt_target *t, int32_t pid, struct xrt_target *out,
                                 struct xrt_birth *result)
{
    if (t && t->connection)
        return xrt_remote_adopt(t, pid, out, result);
    if (!out || !result || out == t)
        return XRT_INVALID_ARGUMENT;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (out->pid || out->thread_count || out->core)
        return XRT_INVALID_STATE;
    size_t i = 0;
    while (i < t->birth_count && t->births[i].pid != pid)
        ++i;
    if (i == t->birth_count)
        return XRT_UNKNOWN_CHILD;
    const struct xrt_birth birth = t->births[i];
    if (!birth.stopped && !birth.exited)
        return XRT_CHILD_INITIAL_STOP_PENDING;
    if (t->birth_image_epoch != t->image_epoch)
        return XRT_PARENT_IMAGE_CHANGED_DURING_BIRTH;
    bool shared = false;
    if (!birth.exited) {
        const long compared = syscall(SYS_kcmp, birth.parent_tid, birth.pid, 1, 0UL, 0UL);
        if (compared < 0) {
            t->births[i].vm_errno = errno;
            return errno == EACCES || errno == EPERM ? XRT_CHILD_VM_COMPARISON_DENIED
                                                     : XRT_CHILD_VM_COMPARISON_FAILED;
        }
        shared = compared == 0;
        if (shared && birth.kind != XRT_BIRTH_VFORK)
            return XRT_SHARED_CLONE_REQUIRES_COORDINATION;
    }
    size_t slot = 0;
    if (shared) {
        struct xrt_target *family[32];
        if (xrt_shared_family(t, family) == 32)
            return XRT_PROCESS_LIMIT;
        while (slot < XRT_MAX_THREADS && t->vfork_children[slot])
            ++slot;
        if (slot == XRT_MAX_THREADS)
            return XRT_PROCESS_LIMIT;
    }
    /* A reused handle keeps counting: contexts taken before the reuse stay stale. */
    const uint64_t generation = out->generation;
    memset(out, 0, sizeof(*out));
    out->generation = generation;
    out->remote_collectors = 0; /* Adopted handle is not published yet. */
    admit_adopted(t, out, pid, birth.exited);
    out->pid = pid;
    out->owned = t->owned;
    out->follow_processes = t->follow_processes;
    out->state = birth.exited ? XRT_EXITED : XRT_STOPPED;
    out->image_epoch = t->birth_image_epoch;
    out->next_probe_id = t->birth_next_probe_id;
    /* Keep inherited host thread filters from binding to a reused small ID. */
    out->next_thread_id = t->next_thread_id;
    if (!birth.exited) {
        out->threads[0] = (struct xrt_thread){.id = out->next_thread_id++,
                                              .tid = pid,
                                              .state = XRT_STOPPED,
                                              .reason = XRT_STOP_INTERRUPT,
                                              .has_saved_debug = birth.has_saved_debug,
                                              .saved_debug = birth.saved_debug};
        out->thread_count = 1;
        out->breakpoint_count = shared ? t->breakpoint_count : t->birth_breakpoint_count;
        memcpy(out->breakpoints, shared ? t->breakpoints : t->birth_breakpoints,
               out->breakpoint_count * sizeof(out->breakpoints[0]));
        for (size_t b = 0; b < out->breakpoint_count; ++b)
            out->breakpoints[b].hit_count = 0;
        if (!shared && birth.unpatched_probe) {
            const int b = xrt_breakpoint_index(out, birth.unpatched_probe);
            if (b >= 0)
                out->breakpoints[b].patched = false;
        }
        out->inherited_rearm = !shared;
        memcpy(out->watchpoints, t->birth_watchpoints, sizeof(out->watchpoints));
        out->watchpoints_dirty = true;
        if (shared) {
            t->vfork_children[slot] = out;
            out->vfork_parent = t;
        }
    }
    t->births[i] = t->births[--t->birth_count];
    xrt_target_event(out, XRT_EVENT_PROCESS_BIRTH, pid, birth.parent_tid);
    ++t->generation;
    *result = birth;
    return XRT_OK;
}
enum xrt_status xrt_rearm_inherited(struct xrt_target *t)
{
    if (!t->inherited_rearm)
        return XRT_OK;
    for (size_t i = 0; i < t->breakpoint_count; ++i) {
        struct xrt_breakpoint *probe = &t->breakpoints[i];
        if (!probe->enabled || probe->pending || probe->patched || !probe->width)
            continue;
        TRY(xrt_patch_instruction(t, probe->address, probe->planted, probe->width));
        probe->patched = true;
    }
    t->inherited_rearm = false;
    return XRT_OK;
}
void xrt_sync_shared_patch(struct xrt_target *t, uint64_t id, bool patched)
{
    if (!t->vfork_parent)
        return;
    struct xrt_target *family[32];
    const size_t count = xrt_shared_family(t, family);
    for (size_t i = 0; i < count; ++i) {
        const int b = xrt_breakpoint_index(family[i], id);
        if (b >= 0)
            family[i]->breakpoints[b].patched = patched;
    }
}
enum xrt_status xrt_separate_vfork(struct xrt_target *t)
{
    struct xrt_target *parent = t->vfork_parent;
    if (!parent)
        return XRT_OK;
    for (size_t i = 0; i < parent->breakpoint_count; ++i) {
        struct xrt_breakpoint *probe = &parent->breakpoints[i];
        if (!probe->enabled || probe->pending || probe->patched || !probe->width ||
            parent->state != XRT_STOPPED)
            continue;
        TRY(xrt_patch_instruction(parent, probe->address, probe->planted, probe->width));
        probe->patched = true;
        xrt_sync_shared_patch(t, probe->id, true);
    }
    for (size_t i = 0; i < XRT_MAX_THREADS; ++i)
        if (parent->vfork_children[i] == t)
            parent->vfork_children[i] = NULL;
    t->vfork_parent = NULL;
    xrt_target_event(parent, XRT_EVENT_PROCESS_SEPARATED, t->pid, 0);
    return XRT_OK;
}
void xrt_remember_reap(struct xrt_target *t, int32_t tid)
{
    for (size_t i = 0; i < t->reap_count; ++i)
        if (t->reap_tids[i] == tid)
            return;
    assert(t->reap_count < 2048);
    t->reap_tids[t->reap_count++] = tid;
}
void xrt_reap_detached(struct xrt_target *t)
{
    size_t i = 0;
    while (i < t->reap_count) {
        int status = 0;
        const pid_t got = waitpid(t->reap_tids[i], &status, __WALL | WNOHANG);
        if ((got > 0 && (WIFEXITED(status) || WIFSIGNALED(status))) || (got < 0 && errno == ECHILD))
            t->reap_tids[i] = t->reap_tids[--t->reap_count];
        else
            ++i;
    }
}
enum xrt_status xrt_target_detach(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_DETACH});
    TRY(xrt_memory_mutation_allowed(t));
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (!t->pid || t->state == XRT_IDLE)
        return XRT_INVALID_STATE;
    xrt_reap_detached(t);
    if (t->reap_count + t->thread_count + 1 > 2048)
        return XRT_TOO_MANY_PENDING_CHILDREN;
    if (t->state == XRT_RUNNING) {
        TRY(xrt_target_interrupt(t));
        TRY(xrt_target_wait_stopped(t));
    }
    /* Restore a half-planted trap before this process is released. */
    if (t->plant_cleanup.active &&
        (t->state != XRT_STOPPED || xrt_target_retry_plant_cleanup(t) != XRT_OK))
        return XRT_INVALID_STATE;
    if (t->state == XRT_STOPPED) {
        while (t->breakpoint_count)
            TRY(xrt_target_breakpoint_remove(t, t->breakpoints[t->breakpoint_count - 1].id));
        for (size_t i = 0; i < t->thread_count; ++i) {
            const struct xrt_thread *thread = &t->threads[i];
            if (thread->state != XRT_EXITED && thread->has_saved_debug &&
                t->arch->machine == XRT_X86_64)
                TRY(xrt_restore_debug(thread->tid, &thread->saved_debug));
        }
    }
    if (t->arch->machine == XRT_AARCH64)
        for (size_t i = 0; i < t->thread_count; ++i) {
            const struct xrt_thread *thread = &t->threads[i];
            if (thread->state == XRT_STOPPED && thread->has_arm_watch_slots)
                TRY(xrt_configure_arm_watches(t, thread->tid, false));
        }
    while (t->thread_count) {
        const struct xrt_thread thread = t->threads[t->thread_count - 1];
        const enum xrt_status result =
            xrt_trace(PTRACE_DETACH, thread.tid, 0, (uintptr_t)thread.signal);
        if (result != XRT_OK && result != XRT_PROCESS_GONE)
            return result;
        if (thread.state == XRT_EXITED)
            xrt_remember_reap(t, thread.tid);
        --t->thread_count;
    }
    if (t->owned && t->state != XRT_EXITED)
        xrt_remember_reap(t, t->pid);
    xrt_target_event(t, XRT_EVENT_DETACH, t->pid, 0);
    t->pid = 0;
    t->state = XRT_IDLE;
    t->owned = false;
    return XRT_OK;
}
enum xrt_status xrt_target_detach_family(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_DETACH_FAMILY});
    if (t->core)
        return XRT_READ_ONLY_CORE;
    struct xrt_target *family[32];
    const size_t count = xrt_shared_family(t, family);
    for (size_t i = 0; i < count; ++i)
        if (family[i]->state == XRT_RUNNING) {
            TRY(xrt_target_interrupt(family[i]));
            TRY(xrt_target_wait_stopped(family[i]));
        }
    const uint64_t deadline = xrt_now() + UINT64_C(3000000000);
    for (;;) {
        bool pending = false;
        for (size_t i = 0; i < count; ++i) {
            TRY(xrt_poll_births(family[i]));
            for (size_t b = 0; b < family[i]->birth_count; ++b)
                pending |= !family[i]->births[b].stopped && !family[i]->births[b].exited;
        }
        if (!pending)
            break;
        if (xrt_now() >= deadline)
            return XRT_CHILD_INITIAL_STOP_TIMEOUT;
        usleep(1000);
    }
    for (size_t i = 0; i < count; ++i)
        if (family[i]->plant_cleanup.active &&
            (family[i]->state != XRT_STOPPED || xrt_target_retry_plant_cleanup(family[i]) != XRT_OK))
            return XRT_INVALID_STATE;
    for (size_t i = 0; i < count; ++i)
        family[i]->detach_pending = true;
    for (size_t i = 0; i < count; ++i) {
        struct xrt_target *member = family[i];
        for (size_t p = 0; p < member->birth_breakpoint_count; ++p) {
            const struct xrt_breakpoint *probe = &member->birth_breakpoints[p];
            if (probe->pending || !probe->width)
                continue;
            for (size_t b = 0; b < member->birth_count; ++b)
                if (!member->births[b].exited)
                    TRY(xrt_patch_instruction_tid(member, member->births[b].pid, probe->address,
                                                  probe->original, probe->width));
        }
        for (size_t p = 0; p < member->breakpoint_count; ++p) {
            struct xrt_breakpoint *probe = &member->breakpoints[p];
            if (!probe->pending && probe->patched && probe->width && member->state == XRT_STOPPED)
                TRY(xrt_patch_instruction(member, probe->address, probe->original, probe->width));
            probe->patched = false;
            probe->enabled = false;
        }
        member->inherited_rearm = false;
        for (size_t b = 0; b < member->birth_count; ++b) {
            const struct xrt_birth *birth = &member->births[b];
            if (!birth->exited && birth->has_saved_debug && member->arch->machine == XRT_X86_64)
                TRY(xrt_restore_debug(birth->pid, &birth->saved_debug));
        }
    }
    for (size_t i = 0; i < count; ++i)
        while (family[i]->birth_count) {
            const struct xrt_birth *birth = &family[i]->births[family[i]->birth_count - 1];
            if (!birth->exited)
                TRY(xrt_trace(PTRACE_DETACH, birth->pid, 0, 0));
            --family[i]->birth_count;
        }
    for (size_t i = 0; i < count; ++i) {
        family[i]->vfork_parent = NULL;
        memset(family[i]->vfork_children, 0, sizeof(family[i]->vfork_children));
    }
    for (size_t i = count; i > 0; --i) {
        struct xrt_target *member = family[i - 1];
        member->detach_pending = false;
        if (member->pid) {
            const enum xrt_status result = xrt_target_detach(member);
            if (result != XRT_OK) {
                member->detach_pending = true;
                return result;
            }
        }
    }
    return XRT_OK;
}
enum xrt_status xrt_target_close(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CLOSE});
    if (!t)
        return XRT_OK;
    if (t->core) {
        t->core = false;
        t->pid = 0;
        t->thread_count = 0;
        t->state = XRT_IDLE;
        return XRT_OK;
    }
    xrt_reap_detached(t);
    if (!t->pid)
        return XRT_OK;
    if (t->owned)
        for (size_t i = 0; i < XRT_MAX_THREADS; ++i)
            if (t->vfork_children[i])
                TRY(xrt_target_close(t->vfork_children[i]));
    if (!t->birth_count && (t->state == XRT_EXITED || (!t->owned && !t->thread_count))) {
        TRY(xrt_separate_vfork(t));
        t->pid = 0;
        t->state = XRT_IDLE;
        return XRT_OK;
    }
    if (!t->owned) {
        return t->birth_count || xrt_target_shared_vm(t) ? xrt_target_detach_family(t)
                                                         : xrt_target_detach(t);
    }
    for (size_t i = 0; i < t->birth_count; ++i)
        if (!t->births[i].exited)
            kill(t->births[i].pid, SIGKILL);
    if (t->state != XRT_EXITED)
        kill(t->pid, SIGKILL);
    if (!t->thread_count && t->state != XRT_EXITED) {
        int status;
        while (waitpid(t->pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
    /* Reap any known worker that is ready; waiting on the leader first can
     * deadlock until the kernel has released every traced worker. */
    while (t->thread_count) {
        bool progressed = false;
        size_t i = 0;
        while (i < t->thread_count) {
            int status = 0;
            const int32_t tid = t->threads[i].tid;
            const pid_t got = waitpid(tid, &status, __WALL | WNOHANG);
            if (got > 0 && WIFSTOPPED(status)) {
                const unsigned kind = (unsigned)status >> 16;
                if (kind == PTRACE_EVENT_CLONE || kind == PTRACE_EVENT_FORK ||
                    kind == PTRACE_EVENT_VFORK) {
                    unsigned long child = 0;
                    if (xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&child) == XRT_OK) {
                        if (kind == PTRACE_EVENT_CLONE && xrt_traced_member((int32_t)child, t->pid))
                            xrt_add_thread(t, (int32_t)child, true);
                        else {
                            assert(t->birth_count < XRT_MAX_THREADS);
                            t->births[t->birth_count++] = (struct xrt_birth){
                                .pid = (int32_t)child,
                                .parent_tid = tid,
                                .kind = kind == PTRACE_EVENT_VFORK  ? XRT_BIRTH_VFORK
                                        : kind == PTRACE_EVENT_FORK ? XRT_BIRTH_FORK
                                                                    : XRT_BIRTH_CLONE_UNKNOWN};
                            kill((pid_t)child, SIGKILL);
                        }
                    }
                }
                xrt_trace(PTRACE_CONT, tid, 0, SIGKILL);
                progressed = true;
            } else if (got > 0 || (got < 0 && errno == ECHILD)) {
                t->threads[i] = t->threads[--t->thread_count];
                progressed = true;
                continue;
            }
            ++i;
        }
        if (!progressed)
            usleep(1000);
    }
    for (size_t i = 0; i < t->birth_count; ++i)
        if (!t->births[i].exited) {
            int status;
            for (;;) {
                const pid_t got = waitpid(t->births[i].pid, &status, __WALL);
                if (got < 0 && errno == EINTR)
                    continue;
                if (got <= 0 || WIFEXITED(status) || WIFSIGNALED(status))
                    break;
                xrt_trace(PTRACE_CONT, t->births[i].pid, 0, SIGKILL);
            }
        }
    t->birth_count = 0;
    TRY(xrt_separate_vfork(t));
    t->pid = 0;
    t->thread_count = 0;
    t->state = XRT_IDLE;
    return XRT_OK;
}
enum xrt_status xrt_target_reset(struct xrt_target *t)
{
    if (t && t->connection)
        return xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_RESET});
    TRY(xrt_target_close(t));
    t->breakpoint_count = 0;
    t->plant_cleanup.active = 0;
    memset(t->watchpoints, 0, sizeof(t->watchpoints));
    t->thread_count = 0;
    t->stepping = false;
    t->want_run = false;
    t->watchpoints_dirty = false;
    t->watch_cancelled = false;
    t->detach_pending = false;
    t->inherited_rearm = false;
    return XRT_OK;
}
