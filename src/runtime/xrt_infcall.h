#ifndef XODB_RUNTIME_INFCALL_H
#define XODB_RUNTIME_INFCALL_H
#include "xrt.h"
#include "xrt_wire.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* An inferior function call on one stopped x86-64 SysV Linux thread.
 *
 * The host classifies the prototype and arguments; this layer only places
 * already-classified words. It runs the selected thread alone on a checked,
 * bounded range of that thread's own stack below the red zone, with a return
 * address at the process entry point (AT_ENTRY) carrying a temporary internal
 * software breakpoint, so a return never runs target code by accident.
 * Before any write it saves the whole general register image, the whole
 * NT_X86_XSTATE image and every borrowed stack byte. A completed call restores
 * them, reads them back and compares them byte for byte. Callee effects
 * outside the borrowed range (memory, files, locks, allocations) are not
 * rolled back.
 *
 * Anything other than a return through the trap (a signal, a breakpoint, a
 * timeout, an exit, a ptrace event) leaves the thread stopped inside the
 * call with the call frame active. While it is active the target refuses
 * continue, step and detach with XRT_CALL_FRAME_ACTIVE until
 * xrt_target_infcall_resolve restores the saved context or abandons it.
 * Other threads are never resumed. Native structs are not the wire format:
 * xrt_infcall_wire_* encode the fields explicitly. */

#define XRT_INFCALL_INT_REGS 6
#define XRT_INFCALL_SSE_REGS 8
#define XRT_INFCALL_STACK_MAX 512
#define XRT_INFCALL_SRET_MAX 256
#define XRT_INFCALL_SENTINELS 4
#define XRT_INFCALL_TIMEOUT_MAX_MS 30000
#define XRT_INFCALL_RED_ZONE 128
/* Minimum mapped stack below the call frame for the callee's own frames,
 * unless the mapping is the main thread's growable [stack]. */
#define XRT_INFCALL_HEADROOM (32 * 1024)

enum xrt_infcall_outcome {
    XRT_INFCALL_NONE = 0,
    /* Nothing was written; refusal says why. */
    XRT_INFCALL_REFUSED,
    /* Returned through the trap; saved context restored and verified. */
    XRT_INFCALL_RETURNED,
    /* The rest leave the call frame active (thread stopped inside the call),
     * except EXITED and STOP_UNCONFIRMED, which cannot be restored. */
    XRT_INFCALL_TIMEOUT,
    XRT_INFCALL_SIGNAL,
    XRT_INFCALL_BREAKPOINT,
    XRT_INFCALL_EXCEPTION,
    XRT_INFCALL_TRAP,
    XRT_INFCALL_EVENT,
    XRT_INFCALL_EXITED,
    XRT_INFCALL_STOP_UNCONFIRMED,
    /* Returned, but writing the saved context back failed or read back
     * different bytes. The thread stays stopped; restore may be retried. */
    XRT_INFCALL_RESTORE_FAILED,
    /* Resolve outcomes. */
    XRT_INFCALL_RESTORED,
    XRT_INFCALL_ABANDONED
};
enum xrt_infcall_refusal {
    XRT_INFCALL_OK = 0,
    XRT_INFCALL_ACTIVE,          /* another call frame is active */
    XRT_INFCALL_STOP_STATE,      /* stepping, newborn, pending interrupt, event stop */
    XRT_INFCALL_SHADOW_STACK,    /* CET user shadow stack enabled */
    XRT_INFCALL_SCRATCH,         /* stack range unmapped, too small or not private rw */
    XRT_INFCALL_TRAP_SITE,       /* no AT_ENTRY or it is not plantable */
    XRT_INFCALL_REQUEST,         /* malformed classified request */
    XRT_INFCALL_XSTATE,          /* no lossless vector state image */
    XRT_INFCALL_NOT_ACTIVE       /* resolve without an active call */
};
enum xrt_infcall_mismatch {
    XRT_INFCALL_MATCH = 0,
    XRT_INFCALL_MISMATCH_GPR,
    XRT_INFCALL_MISMATCH_XSTATE,
    XRT_INFCALL_MISMATCH_STACK,
    XRT_INFCALL_MISMATCH_WRITE
};

struct xrt_infcall_request {
    uint64_t function;
    uint64_t timeout_ms;
    int32_t tid;
    uint32_t int_count, sse_count, stack_size, sret_size, sentinel_count;
    /* Set %al to sse_count (varargs). Otherwise rax is zero at entry. */
    bool variadic;
    uint64_t int_args[XRT_INFCALL_INT_REGS];
    uint8_t sse_args[XRT_INFCALL_SSE_REGS][16];
    /* Memory-class arguments, eightbyte aligned, lowest address first. */
    uint8_t stack[XRT_INFCALL_STACK_MAX];
    /* Exception trap sites (e.g. std::terminate); hitting one is EXCEPTION. */
    uint64_t sentinels[XRT_INFCALL_SENTINELS];
};
struct xrt_infcall_result {
    uint32_t outcome, refusal, mismatch, event;
    bool active, restored, verified, stack_balanced;
    int32_t tid, signal, si_code;
    uint64_t rax, rdx;
    uint8_t xmm0[16], xmm1[16];
    uint32_t sret_size;
    uint8_t sret[XRT_INFCALL_SRET_MAX];
    uint64_t fault_address, pc, sp, syscall, duration_ns;
    uint64_t function, trap, call_sp, borrowed_low, borrowed_high;
    uint64_t gpr_bytes, xstate_bytes, stack_bytes;
};

/* Runs the call. A refusal returns XRT_OK with outcome REFUSED and writes
 * nothing. Other statuses report a precondition (not stopped, unknown thread,
 * unsupported architecture or backend, stale generation). */
enum xrt_status xrt_target_infcall(struct xrt_target *target, const struct xrt_infcall_request *request,
                                   struct xrt_infcall_result *out);
/* restore=true writes the saved context back (RESTORED, or RESTORE_FAILED);
 * restore=false abandons it (ABANDONED): the thread stays where it stopped,
 * the return trap becomes an ordinary visible breakpoint, and continue works
 * again from inside the callee. */
enum xrt_status xrt_target_infcall_resolve(struct xrt_target *target, bool restore,
                                           struct xrt_infcall_result *out);
/* The thread with an active call frame, or zero. Local targets only; a remote
 * host learns it from call results. */
int32_t xrt_target_infcall_active(const struct xrt_target *target);
void xrt_infcall_release(struct xrt_target *target);

void xrt_infcall_wire_request(struct xrt_codec *codec, struct xrt_infcall_request *request);
void xrt_infcall_wire_result(struct xrt_codec *codec, struct xrt_infcall_result *result);
#endif
