#define _GNU_SOURCE 1
#include "target_internal.h"
#include "xrt_infcall.h"
#include "rpc.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#if defined(__linux__) && defined(__x86_64__) && !defined(__ILP32__)
#include <elf.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/user.h>
#define INFCALL_HOST 1
#endif

/* Borrowed range bound: red zone, aligned return slot, stack arguments and
 * the aligned hidden return area. See the layout in prepare(). */
#define BORROW_MAX 1024
#define XSTATE_MAX 65536
#define XSTATE_LEGACY_XMM 160
#define XSTATE_HEADER 512
#define INTERRUPT_GRACE_NS UINT64_C(2000000000)

#if INFCALL_HOST
struct xrt_infcall {
    bool active;
    int32_t tid;
    struct user_regs_struct gpr;
    size_t xstate_size;
    uint8_t xstate[XSTATE_MAX];
    /* Per-target scratch: the call image and read-back copies. */
    uint8_t scratch[XSTATE_MAX];
    uint64_t low, high, entry_sp, sret, function, trap, started;
    uint8_t stack[BORROW_MAX];
    int32_t signal;
    enum xrt_stop_reason reason;
    uint64_t breakpoint_address;
    bool has_siginfo;
    siginfo_t siginfo;
    uint64_t trap_id;
    bool trap_owned;
    uint32_t sentinel_count;
    uint64_t sentinels[XRT_INFCALL_SENTINELS], sentinel_id[XRT_INFCALL_SENTINELS];
    bool sentinel_owned[XRT_INFCALL_SENTINELS];
};
#endif

int32_t xrt_target_infcall_active(const struct xrt_target *t)
{
#if INFCALL_HOST
    if (t && t->infcall && t->infcall->active)
        return t->infcall->tid;
#else
    (void)t;
#endif
    return 0;
}

void xrt_infcall_wire_request(struct xrt_codec *c, struct xrt_infcall_request *r)
{
    uint32_t tid = (uint32_t)r->tid;
    xrt_codec_u64(c, &r->function);
    xrt_codec_u64(c, &r->timeout_ms);
    xrt_codec_u32(c, &tid);
    r->tid = (int32_t)tid;
    xrt_codec_u32(c, &r->int_count);
    xrt_codec_u32(c, &r->sse_count);
    xrt_codec_u32(c, &r->stack_size);
    xrt_codec_u32(c, &r->sret_size);
    xrt_codec_u32(c, &r->sentinel_count);
    xrt_codec_bool(c, &r->variadic);
    for (unsigned i = 0; i < XRT_INFCALL_INT_REGS; ++i)
        xrt_codec_u64(c, &r->int_args[i]);
    xrt_codec_bytes(c, r->sse_args, sizeof(r->sse_args));
    xrt_codec_bytes(c, r->stack, sizeof(r->stack));
    for (unsigned i = 0; i < XRT_INFCALL_SENTINELS; ++i)
        xrt_codec_u64(c, &r->sentinels[i]);
}
void xrt_infcall_wire_result(struct xrt_codec *c, struct xrt_infcall_result *r)
{
    uint32_t tid = (uint32_t)r->tid, signal = (uint32_t)r->signal, code = (uint32_t)r->si_code;
    xrt_codec_u32(c, &r->outcome);
    xrt_codec_u32(c, &r->refusal);
    xrt_codec_u32(c, &r->mismatch);
    xrt_codec_u32(c, &r->event);
    xrt_codec_bool(c, &r->active);
    xrt_codec_bool(c, &r->restored);
    xrt_codec_bool(c, &r->verified);
    xrt_codec_bool(c, &r->stack_balanced);
    xrt_codec_u32(c, &tid);
    xrt_codec_u32(c, &signal);
    xrt_codec_u32(c, &code);
    r->tid = (int32_t)tid;
    r->signal = (int32_t)signal;
    r->si_code = (int32_t)code;
    xrt_codec_u64(c, &r->rax);
    xrt_codec_u64(c, &r->rdx);
    xrt_codec_bytes(c, r->xmm0, sizeof(r->xmm0));
    xrt_codec_bytes(c, r->xmm1, sizeof(r->xmm1));
    xrt_codec_u32(c, &r->sret_size);
    xrt_codec_bytes(c, r->sret, sizeof(r->sret));
    uint64_t *words[] = {&r->fault_address, &r->pc, &r->sp, &r->syscall, &r->duration_ns,
                         &r->function, &r->trap, &r->call_sp, &r->borrowed_low,
                         &r->borrowed_high, &r->gpr_bytes, &r->xstate_bytes, &r->stack_bytes};
    for (size_t i = 0; i < sizeof(words) / sizeof(words[0]); ++i)
        xrt_codec_u64(c, words[i]);
    if (c->read && (r->sret_size > XRT_INFCALL_SRET_MAX || r->outcome > XRT_INFCALL_ABANDONED ||
                    r->refusal > XRT_INFCALL_NOT_ACTIVE || r->mismatch > XRT_INFCALL_MISMATCH_WRITE))
        c->ok = false;
}

/* Remote: the agent owns the transaction. A host never programs agent
 * registers itself; it sends the classified request and decodes the result. */
static enum xrt_status remote_infcall(struct xrt_target *t, uint16_t op, uint64_t arg,
                                      struct xrt_infcall_request *request,
                                      struct xrt_infcall_result *out)
{
    if (!xrt_remote_supports(t, XRT_RPC_CAP_INFCALL))
        return XRT_UNSUPPORTED_CONTROL;
    uint8_t body[sizeof(struct xrt_infcall_request) + 64];
    uint8_t reply[sizeof(struct xrt_infcall_result) + 64];
    size_t size = 0;
    if (request) {
        struct xrt_codec encoded = xrt_codec(body, sizeof(body), false);
        xrt_infcall_wire_request(&encoded, request);
        if (!encoded.ok)
            return XRT_INVALID_ARGUMENT;
        size = encoded.at;
    }
    size_t length = 0;
    const enum xrt_status status = xrt_remote_call(
        t, &(struct xrt_call){.op = op, .args = {arg}, .data = request ? body : NULL,
                              .size = size, .out = reply, .capacity = sizeof(reply),
                              .length = &length});
    if (status != XRT_OK)
        return status;
    struct xrt_codec decoded = xrt_codec(reply, length, true);
    xrt_infcall_wire_result(&decoded, out);
    if (!decoded.ok || decoded.at != length)
        return XRT_PROTOCOL_ERROR;
    return XRT_OK;
}

#if INFCALL_HOST
static uint64_t auxv_entry(int32_t pid)
{
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/auxv", (int)pid);
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    uint64_t pair[2], entry = 0;
    while (fread(pair, sizeof(pair), 1, f) == 1 && pair[0] != AT_NULL)
        if (pair[0] == AT_ENTRY)
            entry = pair[1];
    fclose(f);
    return entry;
}
/* CET user shadow stacks make a debugger-supplied return address fault. */
static bool shadow_stack(int32_t pid, int32_t tid)
{
    char path[96], line[256];
    snprintf(path, sizeof(path), "/proc/%d/task/%d/status", (int)pid, (int)tid);
    FILE *f = fopen(path, "r");
    if (!f)
        return false;
    bool enabled = false;
    while (fgets(line, sizeof(line), f))
        if (!strncmp(line, "x86_Thread_features:", 20) && strstr(line + 20, "shstk"))
            enabled = true;
    fclose(f);
    return enabled;
}
/* The borrowed range [low, high) and callee headroom must lie in one private
 * read-write anonymous mapping (a thread stack). The main thread's [stack]
 * may grow on demand. The heap and file-backed data are refused: a thread
 * stopped on a sigaltstack carved from them would have the callee's frames
 * overwrite live objects below it. */
static bool scratch_mapped(int32_t pid, uint64_t low, uint64_t high)
{
    char path[64], line[512];
    snprintf(path, sizeof(path), "/proc/%d/maps", (int)pid);
    FILE *f = fopen(path, "r");
    if (!f)
        return false;
    bool ok = false;
    while (fgets(line, sizeof(line), f)) {
        unsigned long long start = 0, end = 0, inode = 0;
        char perms[5] = {0};
        int name = 0;
        if (sscanf(line, "%llx-%llx %4s %*s %*s %llu %n", &start, &end, perms, &inode, &name) < 4)
            continue;
        if (low < start || low >= end)
            continue;
        const char *label = name > 0 ? line + name : "";
        const bool grows = !strncmp(label, "[stack]", 7);
        const bool anonymous = inode == 0 && (label[0] == '\0' || label[0] == '\n' ||
                                              !strncmp(label, "[anon:", 6));
        ok = high <= end && perms[0] == 'r' && perms[1] == 'w' && perms[3] == 'p' &&
             (grows || (anonymous && low - start >= XRT_INFCALL_HEADROOM));
        break;
    }
    fclose(f);
    return ok;
}
static enum xrt_status read_xstate(int32_t tid, uint8_t *buffer, size_t *size)
{
    struct iovec io = {.iov_base = buffer, .iov_len = XSTATE_MAX};
    TRY(xrt_trace(PTRACE_GETREGSET, tid, NT_X86_XSTATE, (uintptr_t)&io));
    if (io.iov_len < XSTATE_HEADER + 64 || io.iov_len > XSTATE_MAX)
        return XRT_INVALID_XSTATE_SIZE;
    *size = io.iov_len;
    return XRT_OK;
}
static enum xrt_status write_xstate(int32_t tid, const uint8_t *buffer, size_t size)
{
    struct iovec io = {.iov_base = (void *)buffer, .iov_len = size};
    return xrt_trace(PTRACE_SETREGSET, tid, NT_X86_XSTATE, (uintptr_t)&io);
}
static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}
static void pause_briefly(unsigned *spins)
{
    struct timespec ts = {0, *spins < 20 ? 50000 : 1000000};
    ++*spins;
    nanosleep(&ts, NULL);
}
static void remove_owned(struct xrt_target *t, struct xrt_infcall *ic, bool keep_trap)
{
    for (uint32_t i = 0; i < ic->sentinel_count; ++i)
        if (ic->sentinel_owned[i] && xrt_target_breakpoint_remove(t, ic->sentinel_id[i]) == XRT_OK)
            ic->sentinel_owned[i] = false;
    if (ic->trap_owned) {
        if (keep_trap) {
            /* An abandoned frame may still return here. Stop there visibly
             * rather than run the entry point. */
            if (xrt_target_breakpoint_internal(t, ic->trap_id, false) == XRT_OK)
                ic->trap_owned = false;
        } else if (xrt_target_breakpoint_remove(t, ic->trap_id) == XRT_OK)
            ic->trap_owned = false;
    }
}
/* Reuses a breakpoint already at the site, so a disabled one would leave the
 * original instruction there. The site counts only once int3 is really in
 * memory (a raw read, not the overlay). */
static enum xrt_status plant(struct xrt_target *t, int32_t tid, uint64_t address, uint64_t *id,
                             bool *owned)
{
    *owned = xrt_breakpoint_at(t, address) < 0;
    TRY(xrt_target_breakpoint_set(t, address, false, id));
    if (*owned)
        TRY(xrt_target_breakpoint_internal(t, *id, true));
    uint8_t byte = 0;
    size_t got = 0;
    if (xrt_memory_read(tid, address, &byte, 1, &got) != XRT_OK || got != 1 || byte != 0xcc)
        return XRT_INVALID_STATE;
    return XRT_OK;
}
/* Write the saved machine context and borrowed bytes back, then read all of
 * it again and compare byte for byte. */
static void restore(struct xrt_target *t, struct xrt_infcall *ic, struct xrt_infcall_result *out)
{
    const int32_t tid = ic->tid;
    out->gpr_bytes = sizeof(ic->gpr);
    out->xstate_bytes = ic->xstate_size;
    out->stack_bytes = ic->high - ic->low;
    out->mismatch = XRT_INFCALL_MATCH;
    size_t count = 0;
    struct user_regs_struct gpr = ic->gpr;
    if (write_xstate(tid, ic->xstate, ic->xstate_size) != XRT_OK ||
        xrt_trace(PTRACE_SETREGS, tid, 0, (uintptr_t)&gpr) != XRT_OK ||
        xrt_memory_patch(tid, ic->low, ic->stack, ic->high - ic->low, &count) != XRT_OK ||
        count != ic->high - ic->low) {
        out->mismatch = XRT_INFCALL_MISMATCH_WRITE;
        return;
    }
    out->restored = true;
    uint8_t *xstate = ic->scratch;
    uint8_t stack[BORROW_MAX];
    size_t xstate_size = 0;
    memset(&gpr, 0, sizeof(gpr));
    if (xrt_trace(PTRACE_GETREGS, tid, 0, (uintptr_t)&gpr) != XRT_OK ||
        memcmp(&gpr, &ic->gpr, sizeof(gpr)))
        out->mismatch = XRT_INFCALL_MISMATCH_GPR;
    else if (read_xstate(tid, xstate, &xstate_size) != XRT_OK || xstate_size != ic->xstate_size ||
             memcmp(xstate, ic->xstate, xstate_size))
        out->mismatch = XRT_INFCALL_MISMATCH_XSTATE;
    else if (xrt_memory_read(tid, ic->low, stack, ic->high - ic->low, &count) != XRT_OK ||
             count != ic->high - ic->low || memcmp(stack, ic->stack, count))
        out->mismatch = XRT_INFCALL_MISMATCH_STACK;
    out->verified = out->mismatch == XRT_INFCALL_MATCH;
    if (!out->verified)
        return;
    const int i = xrt_thread_index(t, tid);
    if (i >= 0) {
        t->threads[i].signal = ic->signal;
        t->threads[i].reason = ic->reason;
        t->threads[i].breakpoint_address = ic->breakpoint_address;
    }
    if (ic->has_siginfo)
        (void)xrt_trace(PTRACE_SETSIGINFO, tid, 0, (uintptr_t)&ic->siginfo);
    remove_owned(t, ic, false);
    ic->active = false;
}
static void finish_active(struct xrt_target *t, struct xrt_infcall *ic, int i,
                          struct xrt_infcall_result *out)
{
    t->threads[i].state = XRT_STOPPED;
    t->threads[i].interrupt_pending = false;
    ic->active = true;
    out->active = true;
    xrt_recompute_state(t);
}
/* Classify one wait status of the calling thread. Returns true when the
 * transaction has an outcome. */
static bool classify(struct xrt_target *t, struct xrt_infcall *ic, int i, int status,
                     bool interrupted, struct xrt_infcall_result *out)
{
    const int32_t tid = ic->tid;
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
        out->outcome = XRT_INFCALL_EXITED;
        out->signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
        t->threads[i].state = XRT_EXITED;
        ic->active = false;
        xrt_recompute_state(t);
        return true;
    }
    if (!WIFSTOPPED(status))
        return false;
    const int sig = WSTOPSIG(status);
    const unsigned event = (unsigned)status >> 16;
    struct user_regs_struct regs;
    memset(&regs, 0, sizeof(regs));
    (void)xrt_trace(PTRACE_GETREGS, tid, 0, (uintptr_t)&regs);
    out->pc = regs.rip;
    out->sp = regs.rsp;
    out->signal = sig;
    if (event == PTRACE_EVENT_STOP) {
        out->outcome = interrupted ? XRT_INFCALL_TIMEOUT : XRT_INFCALL_EVENT;
        out->event = event;
        out->syscall = (int64_t)regs.orig_rax >= 0 ? regs.orig_rax : UINT64_MAX;
        out->signal = 0;
        t->threads[i].signal = 0;
        t->threads[i].reason = XRT_STOP_INTERRUPT;
        finish_active(t, ic, i, out);
        return true;
    }
    if (event) {
        /* Exit and exec end the frame; clone/fork/vfork leave it active. */
        out->outcome = event == PTRACE_EVENT_EXIT || event == PTRACE_EVENT_EXEC
                           ? XRT_INFCALL_EXITED
                           : XRT_INFCALL_EVENT;
        out->event = event;
        out->signal = 0;
        t->threads[i].signal = 0;
        t->threads[i].reason = XRT_STOP_INTERRUPT;
        if (out->outcome == XRT_INFCALL_EXITED) {
            t->threads[i].state = XRT_STOPPED;
            ic->active = false;
            xrt_recompute_state(t);
            remove_owned(t, ic, false);
            if (event == PTRACE_EVENT_EXIT) {
                /* This wait consumed the exit stop the event loop would
                 * have continued; nothing reports it again, and a close
                 * would wait for it forever. Let the thread exit, as the
                 * event loop does. */
                unsigned long code = 0;
                (void)xrt_trace(PTRACE_GETEVENTMSG, tid, 0, (uintptr_t)&code);
                xrt_target_event(t, XRT_EVENT_THREAD_EXITING, tid, (int64_t)code);
                t->threads[i].state = XRT_EXITED;
                (void)xrt_trace(PTRACE_CONT, tid, 0, 0);
                xrt_recompute_state(t);
            }
        } else
            finish_active(t, ic, i, out);
        return true;
    }
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (xrt_trace(PTRACE_GETSIGINFO, tid, 0, (uintptr_t)&info) == XRT_OK) {
        out->si_code = info.si_code;
        if (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGFPE)
            out->fault_address = (uint64_t)(uintptr_t)info.si_addr;
    }
    if (sig == SIGTRAP) {
        const uint64_t at = regs.rip - 1;
        if (at == ic->trap) {
            out->outcome = XRT_INFCALL_RETURNED;
            out->stack_balanced = regs.rsp == ic->entry_sp + 8;
            out->rax = regs.rax;
            out->rdx = regs.rdx;
            out->signal = 0;
            return true;
        }
        for (uint32_t s = 0; s < ic->sentinel_count; ++s)
            if (at == ic->sentinels[s]) {
                (void)xrt_register_write_pc_for(t->arch, tid, at);
                out->outcome = XRT_INFCALL_EXCEPTION;
                out->pc = at;
                out->signal = 0;
                t->threads[i].signal = 0;
                t->threads[i].reason = XRT_STOP_INTERRUPT;
                finish_active(t, ic, i, out);
                return true;
            }
        const int b = xrt_breakpoint_at(t, at);
        if (b >= 0 && t->breakpoints[b].patched && info.si_code == SI_KERNEL) {
            struct xrt_breakpoint *probe = &t->breakpoints[b];
            (void)xrt_register_write_pc_for(t->arch, tid, probe->address);
            if (probe->hit_count != UINT64_MAX)
                ++probe->hit_count;
            out->outcome = XRT_INFCALL_BREAKPOINT;
            out->pc = probe->address;
            out->signal = 0;
            t->threads[i].signal = 0;
            t->threads[i].reason = XRT_STOP_BREAKPOINT;
            t->threads[i].breakpoint_address = probe->address;
            xrt_target_event(t, XRT_EVENT_BREAKPOINT_HIT, tid, (int64_t)probe->id);
            t->events[t->event_count - 1].pc = probe->address;
            t->events[t->event_count - 1].pc_known = 1;
            finish_active(t, ic, i, out);
            return true;
        }
        /* An unknown trap (compiled-in int3, hardware watch). Continuing
         * after an abandon must not deliver SIGTRAP and kill the target. */
        out->outcome = XRT_INFCALL_TRAP;
        t->threads[i].signal = 0;
        t->threads[i].reason = XRT_STOP_INTERRUPT;
        finish_active(t, ic, i, out);
        return true;
    }
    out->outcome = XRT_INFCALL_SIGNAL;
    t->threads[i].signal = sig;
    t->threads[i].reason = XRT_STOP_SIGNAL;
    finish_active(t, ic, i, out);
    return true;
}
static void refuse(struct xrt_infcall_result *out, enum xrt_infcall_refusal why)
{
    out->outcome = XRT_INFCALL_REFUSED;
    out->refusal = why;
}
static enum xrt_status local_infcall(struct xrt_target *t, const struct xrt_infcall_request *rq,
                                     struct xrt_infcall_result *out)
{
    const int32_t tid = rq->tid;
    const int i = xrt_thread_index(t, tid);
    if (i < 0)
        return XRT_UNKNOWN_THREAD;
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (t->infcall && t->infcall->active) {
        refuse(out, XRT_INFCALL_ACTIVE);
        return XRT_OK;
    }
    const enum xrt_status allowed = xrt_execution_allowed(t);
    if (allowed != XRT_OK)
        return allowed;
    const struct xrt_thread *thread = &t->threads[i];
    switch (thread->reason) {
    case XRT_STOP_NONE:
    case XRT_STOP_INTERRUPT:
    case XRT_STOP_SIGNAL:
    case XRT_STOP_BREAKPOINT:
    case XRT_STOP_SINGLE_STEP:
    case XRT_STOP_WATCHPOINT:
        break;
    case XRT_STOP_EXEC:
    case XRT_STOP_CLONE:
    case XRT_STOP_FORK:
    case XRT_STOP_VFORK:
    case XRT_STOP_VFORK_DONE:
    case XRT_STOP_EXCEPTION:
        refuse(out, XRT_INFCALL_STOP_STATE);
        return XRT_OK;
    }
    if (t->stepping || thread->newborn || thread->interrupt_pending || thread->has_arm_watch_hit) {
        refuse(out, XRT_INFCALL_STOP_STATE);
        return XRT_OK;
    }
    if (!rq->function || rq->int_count > XRT_INFCALL_INT_REGS - (rq->sret_size ? 1u : 0u) ||
        rq->sse_count > XRT_INFCALL_SSE_REGS || rq->stack_size > XRT_INFCALL_STACK_MAX ||
        rq->stack_size % 8 || rq->sret_size > XRT_INFCALL_SRET_MAX ||
        rq->sentinel_count > XRT_INFCALL_SENTINELS || !rq->timeout_ms ||
        rq->timeout_ms > XRT_INFCALL_TIMEOUT_MAX_MS) {
        refuse(out, XRT_INFCALL_REQUEST);
        return XRT_OK;
    }
    if (shadow_stack(t->pid, tid)) {
        refuse(out, XRT_INFCALL_SHADOW_STACK);
        return XRT_OK;
    }
    const uint64_t trap = auxv_entry(t->pid);
    if (!trap) {
        refuse(out, XRT_INFCALL_TRAP_SITE);
        return XRT_OK;
    }
    if (!t->infcall) {
        t->infcall = calloc(1, sizeof(*t->infcall));
        if (!t->infcall)
            return XRT_OUT_OF_MEMORY;
    }
    struct xrt_infcall *ic = t->infcall;
    memset(ic, 0, sizeof(*ic));
    ic->tid = tid;
    ic->trap = trap;
    ic->function = rq->function;
    TRY(xrt_trace(PTRACE_GETREGS, tid, 0, (uintptr_t)&ic->gpr));
    if (read_xstate(tid, ic->xstate, &ic->xstate_size) != XRT_OK) {
        refuse(out, XRT_INFCALL_XSTATE);
        return XRT_OK;
    }
    /* Layout, highest address first: the caller's red zone is never touched;
     * then the hidden return area and the stack arguments, each 16-byte
     * aligned; then the return slot. At entry (rsp + 8) % 16 == 0. */
    const uint64_t sp = ic->gpr.rsp;
    if (sp < BORROW_MAX + XRT_INFCALL_HEADROOM) {
        refuse(out, XRT_INFCALL_SCRATCH);
        return XRT_OK;
    }
    const uint64_t top = sp - XRT_INFCALL_RED_ZONE;
    const uint64_t sret = rq->sret_size ? (top - rq->sret_size) & ~UINT64_C(15) : 0;
    const uint64_t args = ((sret ? sret : top) - rq->stack_size) & ~UINT64_C(15);
    const uint64_t entry_sp = args - 8;
    ic->low = entry_sp;
    ic->high = sp;
    ic->entry_sp = entry_sp;
    ic->sret = sret;
    out->function = rq->function;
    out->trap = trap;
    out->call_sp = entry_sp;
    out->borrowed_low = ic->low;
    out->borrowed_high = ic->high;
    size_t count = 0;
    if (ic->high - ic->low > BORROW_MAX || !scratch_mapped(t->pid, ic->low, ic->high) ||
        xrt_memory_read(tid, ic->low, ic->stack, ic->high - ic->low, &count) != XRT_OK ||
        count != ic->high - ic->low) {
        refuse(out, XRT_INFCALL_SCRATCH);
        return XRT_OK;
    }
    ic->signal = thread->signal;
    ic->reason = thread->reason;
    ic->breakpoint_address = thread->breakpoint_address;
    if (thread->signal &&
        xrt_trace(PTRACE_GETSIGINFO, tid, 0, (uintptr_t)&ic->siginfo) == XRT_OK)
        ic->has_siginfo = true;
    /* First target write. From here every exit either restores or leaves
     * an explicit active frame. */
    enum xrt_status status = plant(t, tid, trap, &ic->trap_id, &ic->trap_owned);
    for (uint32_t s = 0; status == XRT_OK && s < rq->sentinel_count; ++s) {
        ic->sentinels[s] = rq->sentinels[s];
        ic->sentinel_count = s + 1;
        status = plant(t, tid, rq->sentinels[s], &ic->sentinel_id[s], &ic->sentinel_owned[s]);
    }
    if (status != XRT_OK) {
        remove_owned(t, ic, false);
        xrt_target_event(t, XRT_EVENT_EXECUTION, tid, XRT_INFCALL_REFUSED);
        refuse(out, XRT_INFCALL_TRAP_SITE);
        return XRT_OK;
    }
    uint8_t frame[8 + XRT_INFCALL_STACK_MAX];
    memcpy(frame, &trap, 8);
    memcpy(frame + 8, rq->stack, rq->stack_size);
    struct user_regs_struct call = ic->gpr;
    uint8_t *xstate = ic->scratch;
    memcpy(xstate, ic->xstate, ic->xstate_size);
    for (uint32_t k = 0; k < rq->sse_count; ++k)
        memcpy(xstate + XSTATE_LEGACY_XMM + 16 * k, rq->sse_args[k], 16);
    if (rq->sse_count) {
        uint64_t features;
        memcpy(&features, xstate + XSTATE_HEADER, 8);
        features |= 2; /* XSTATE_BV.SSE: take the XMM values from this image. */
        memcpy(xstate + XSTATE_HEADER, &features, 8);
    }
    unsigned long long *slots[] = {&call.rdi, &call.rsi, &call.rdx, &call.rcx, &call.r8, &call.r9};
    unsigned slot = 0;
    if (sret)
        *slots[slot++] = sret;
    for (uint32_t k = 0; k < rq->int_count; ++k)
        *slots[slot++] = rq->int_args[k];
    call.rip = rq->function;
    call.rsp = entry_sp;
    call.rax = rq->variadic ? rq->sse_count : 0;
    call.orig_rax = (unsigned long long)-1; /* no syscall restart on resume */
    call.eflags &= ~(unsigned long long)(0x100 | 0x400); /* TF, DF */
    count = 0;
    status = xrt_memory_patch(tid, entry_sp, frame, 8 + rq->stack_size, &count);
    if (status == XRT_OK)
        status = write_xstate(tid, xstate, ic->xstate_size);
    if (status == XRT_OK)
        status = xrt_trace(PTRACE_SETREGS, tid, 0, (uintptr_t)&call);
    if (status != XRT_OK) {
        restore(t, ic, out);
        xrt_target_event(t, XRT_EVENT_EXECUTION, tid, XRT_INFCALL_REFUSED);
        if (out->verified) {
            refuse(out, XRT_INFCALL_SCRATCH);
        } else {
            out->outcome = XRT_INFCALL_RESTORE_FAILED;
            finish_active(t, ic, i, out);
        }
        return XRT_OK;
    }
    /* Resume only this thread. Others stay in their ptrace stops. */
    ic->started = now_ns();
    status = xrt_trace(PTRACE_CONT, tid, 0, 0);
    if (status != XRT_OK) {
        restore(t, ic, out);
        xrt_target_event(t, XRT_EVENT_EXECUTION, tid, XRT_INFCALL_REFUSED);
        if (!out->verified) {
            out->outcome = XRT_INFCALL_RESTORE_FAILED;
            finish_active(t, ic, i, out);
            return XRT_OK;
        }
        return status;
    }
    t->threads[i].state = XRT_RUNNING;
    t->threads[i].signal = 0;
    t->threads[i].reason = XRT_STOP_NONE;
    const uint64_t deadline = ic->started + rq->timeout_ms * UINT64_C(1000000);
    uint64_t grace = 0;
    bool interrupted = false;
    unsigned spins = 0;
    for (;;) {
        int wait_status = 0;
        const pid_t got = waitpid(tid, &wait_status, __WALL | WNOHANG);
        if (got == tid) {
            if (classify(t, ic, i, wait_status, interrupted, out))
                break;
            continue;
        }
        if (got < 0 && errno != EINTR) {
            out->outcome = XRT_INFCALL_EXITED;
            t->threads[i].state = XRT_EXITED;
            ic->active = false;
            xrt_recompute_state(t);
            break;
        }
        const uint64_t now = now_ns();
        if (!interrupted && now >= deadline) {
            interrupted = true;
            grace = now + INTERRUPT_GRACE_NS;
            if (xrt_trace(PTRACE_INTERRUPT, tid, 0, 0) != XRT_OK)
                grace = now;
        } else if (interrupted && now >= grace) {
            /* The stop request is not proof of a stop. The ordinary poll
             * reaps it later; the frame stays active until resolved. */
            out->outcome = XRT_INFCALL_STOP_UNCONFIRMED;
            t->threads[i].interrupt_pending = true;
            ic->active = true;
            out->active = true;
            xrt_recompute_state(t);
            break;
        }
        pause_briefly(&spins);
    }
    out->duration_ns = now_ns() - ic->started;
    if (out->outcome == XRT_INFCALL_RETURNED) {
        uint8_t *after = ic->scratch;
        size_t after_size = 0;
        if (read_xstate(tid, after, &after_size) == XRT_OK) {
            memcpy(out->xmm0, after + XSTATE_LEGACY_XMM, 16);
            memcpy(out->xmm1, after + XSTATE_LEGACY_XMM + 16, 16);
        }
        if (sret) {
            size_t got = 0;
            if (xrt_memory_read(tid, sret, out->sret, rq->sret_size, &got) == XRT_OK &&
                got == rq->sret_size)
                out->sret_size = rq->sret_size;
        }
        t->threads[i].state = XRT_STOPPED;
        xrt_recompute_state(t);
        restore(t, ic, out);
        if (!out->verified) {
            out->outcome = XRT_INFCALL_RESTORE_FAILED;
            finish_active(t, ic, i, out);
        }
    } else if (out->outcome == XRT_INFCALL_EXITED && t->state == XRT_STOPPED) {
        /* A thread that exited inside the call leaves its peers stopped. */
        remove_owned(t, ic, false);
    }
    xrt_target_event(t, XRT_EVENT_EXECUTION, tid, (int64_t)out->outcome);
    return XRT_OK;
}
static enum xrt_status local_resolve(struct xrt_target *t, bool keep_saved,
                                     struct xrt_infcall_result *out)
{
    struct xrt_infcall *ic = t->infcall;
    if (!ic || !ic->active) {
        refuse(out, XRT_INFCALL_NOT_ACTIVE);
        return XRT_OK;
    }
    out->tid = ic->tid;
    out->function = ic->function;
    out->trap = ic->trap;
    out->borrowed_low = ic->low;
    out->borrowed_high = ic->high;
    const int i = xrt_thread_index(t, ic->tid);
    if (i < 0 || t->threads[i].state == XRT_EXITED) {
        ic->active = false;
        out->outcome = XRT_INFCALL_EXITED;
        xrt_target_event(t, XRT_EVENT_EXECUTION, ic->tid, (int64_t)out->outcome);
        return XRT_OK;
    }
    if (t->threads[i].state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    if (keep_saved) {
        restore(t, ic, out);
        out->outcome = out->verified ? XRT_INFCALL_RESTORED : XRT_INFCALL_RESTORE_FAILED;
        out->active = ic->active;
    } else {
        remove_owned(t, ic, true);
        ic->active = false;
        out->outcome = XRT_INFCALL_ABANDONED;
    }
    xrt_recompute_state(t);
    xrt_target_event(t, XRT_EVENT_EXECUTION, ic->tid, (int64_t)out->outcome);
    return XRT_OK;
}
#endif

/* Closing releases the target. An attached process that keeps running must
 * not keep a borrowed context, so a stopped active frame is restored first
 * (best effort; a failure is not retried). An owned process is killed. */
void xrt_infcall_release(struct xrt_target *t)
{
    if (!t || !t->infcall)
        return;
#if INFCALL_HOST
    struct xrt_infcall *ic = t->infcall;
    const int i = xrt_thread_index(t, ic->tid);
    if (ic->active && !t->owned && i >= 0 && t->threads[i].state == XRT_STOPPED &&
        t->state == XRT_STOPPED) {
        struct xrt_infcall_result ignored;
        memset(&ignored, 0, sizeof(ignored));
        restore(t, ic, &ignored);
    }
#endif
    free(t->infcall);
    t->infcall = NULL;
}
static enum xrt_status precondition(const struct xrt_target *t)
{
    if (!t)
        return XRT_INVALID_ARGUMENT;
    if (t->core)
        return XRT_READ_ONLY_CORE;
    if (!t->identity_admitted || !t->arch || t->arch->machine != XRT_X86_64 ||
        !xrt_arch_host_traceable(t->arch))
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (t->state != XRT_STOPPED)
        return XRT_NOT_STOPPED;
    return XRT_OK;
}
enum xrt_status xrt_target_infcall(struct xrt_target *t, const struct xrt_infcall_request *request,
                                   struct xrt_infcall_result *out)
{
    if (!t || !request || !out)
        return XRT_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    out->tid = request->tid;
    out->syscall = UINT64_MAX;
    if (t->connection) {
        struct xrt_infcall_request copy = *request;
        return remote_infcall(t, XRT_RPC_INFCALL, request->timeout_ms, &copy, out);
    }
    TRY(precondition(t));
#if INFCALL_HOST
    return local_infcall(t, request, out);
#else
    return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
}
enum xrt_status xrt_target_infcall_resolve(struct xrt_target *t, bool restore_saved,
                                           struct xrt_infcall_result *out)
{
    if (!t || !out)
        return XRT_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    out->syscall = UINT64_MAX;
    if (t->connection)
        return remote_infcall(t, XRT_RPC_INFCALL_RESOLVE, restore_saved, NULL, out);
    TRY(precondition(t));
#if INFCALL_HOST
    return local_resolve(t, restore_saved, out);
#else
    (void)restore_saved;
    return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
}
