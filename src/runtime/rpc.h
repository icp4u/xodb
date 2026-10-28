#ifndef XODB_RUNTIME_RPC_H
#define XODB_RUNTIME_RPC_H
#include "xrt.h"
#include "xrt_wire.h"
/* Requests carry generation:u64, arg[3]:u64, then an operation-specific byte
 * string (at most 64 KiB). Replies carry value:u64, extra_size:u32, extra bytes,
 * snapshot:bool; a snapshot is preceded by shared_vm:bool and family_root:u32.
 * All mutations check the authoritative expected generation before executing.
 * A snapshot is complete: its bounded event suffix must be contiguous. */
#define XRT_RPC_DATA_MAX 65536
#define XRT_RPC_TARGETS 128
#define XRT_RPC_REQUEST_PREFIX 32
/* FILE_OPEN arg[0]: allow a verified large mapped file for bounded symbol
 * ranges. Zero uses XRT_REMOTE_IMAGE_LIMIT for ordinary snapshots, including
 * requests from older hosts. Older agents may still refuse large images. */
#define XRT_RPC_FILE_SYMBOLS UINT64_C(1)
/* HELLO arg[0] requests an optional u64 capability suffix. Old hosts keep the
 * original 16-byte response; old agents ignore the request and return 16. */
#define XRT_RPC_HELLO_CAPABILITIES UINT64_C(1)
#define XRT_RPC_CAP_SOURCE UINT64_C(1)
#define XRT_RPC_CAP_LARGE_IMAGES UINT64_C(4)
/* HELLO arg[1] opts into this capability. When negotiated, each present
 * snapshot is followed by an address_space_unstable bool. Old hosts keep
 * their original reply shape; hosts without this evidence bypass read caches. */
#define XRT_RPC_CAP_ADDRESS_SPACE UINT64_C(2)
/* HELLO arg[1] asks for one more u64: the agent's open-file slot count.
 * Old hosts omit the bit and keep the 24-byte reply. Old agents ignore the
 * bit and omit the count; the host then keeps today's per-feature caps. */
#define XRT_RPC_CAP_FILE_SLOTS UINT64_C(8)
/* HELLO arg[1] asks for three more u64s after the slot count: insn mask,
 * data mask, then virtual-address width. Width is zero when the insn mask
 * is zero. Old hosts omit the bit. Old agents ignore it and keep a 16, 24,
 * or 32 byte reply. A new agent appends the triple whenever the bit is asked,
 * including zeros off aarch64, so the size does not depend on the machine. */
#define XRT_RPC_CAP_PAC_MASK UINT64_C(16)
/* HELLO arg[1] asks the agent to read kallsyms for the host. The bit is
 * returned only when the host asked. It does not change the reply size.
 * Old agents drop the bit. A host that does not see it still captures and
 * leaves kernel frames unnamed. */
#define XRT_RPC_CAP_KALLSYMS UINT64_C(32)
/* One registry of the HELLO capability word. A new bit is added to one row
 * list below, not as a second mask at a call site. Always-on bits are
 * advertised on every capable HELLO. Negotiated bits are asked and returned
 * only when the host sets them. */
#define XRT_RPC_CAP_ALWAYS_ROWS(X) \
    X(XRT_RPC_CAP_SOURCE) \
    X(XRT_RPC_CAP_LARGE_IMAGES)
#define XRT_RPC_CAP_NEGOTIATED_ROWS(X) \
    X(XRT_RPC_CAP_ADDRESS_SPACE) \
    X(XRT_RPC_CAP_FILE_SLOTS) \
    X(XRT_RPC_CAP_PAC_MASK) \
    X(XRT_RPC_CAP_KALLSYMS)
#define XRT_RPC_CAP_ALL_ROWS(X) \
    XRT_RPC_CAP_ALWAYS_ROWS(X) \
    XRT_RPC_CAP_NEGOTIATED_ROWS(X)
#define XRT_RPC_CAP_OR_BIT(bit) |(bit)
#define XRT_RPC_CAP_ADD_BIT(bit) +(bit)
#define XRT_RPC_CAP_ONE_BIT(bit) && ((bit) > 0) && (((bit) & ((bit) - 1)) == 0)
#define XRT_RPC_CAP_ALWAYS (0 XRT_RPC_CAP_ALWAYS_ROWS(XRT_RPC_CAP_OR_BIT))
#define XRT_RPC_CAP_NEGOTIATED (0 XRT_RPC_CAP_NEGOTIATED_ROWS(XRT_RPC_CAP_OR_BIT))
_Static_assert((0 XRT_RPC_CAP_ALL_ROWS(XRT_RPC_CAP_ADD_BIT)) == (0 XRT_RPC_CAP_ALL_ROWS(XRT_RPC_CAP_OR_BIT)), "HELLO capability bits overlap");
_Static_assert((1 XRT_RPC_CAP_ALL_ROWS(XRT_RPC_CAP_ONE_BIT)), "HELLO capability is not one bit");
_Static_assert(XRT_RPC_CAP_PAC_MASK == UINT64_C(16), "PAC mask bit stays 16");
_Static_assert(XRT_RPC_CAP_KALLSYMS == UINT64_C(32), "kallsyms bit stays 32");
_Static_assert((XRT_RPC_CAP_PAC_MASK & XRT_RPC_CAP_KALLSYMS) == 0, "PAC mask and kallsyms share a bit");
enum xrt_rpc_op {
    XRT_RPC_HELLO = 1,
    XRT_RPC_CREATE,
    XRT_RPC_DESTROY,
    XRT_RPC_SYNC,
    XRT_RPC_LAUNCH,
    XRT_RPC_ATTACH,
    XRT_RPC_INTERRUPT,
    XRT_RPC_CONTINUE,
    XRT_RPC_STEP,
    XRT_RPC_WAIT_STOPPED,
    XRT_RPC_DETACH,
    XRT_RPC_DETACH_FAMILY,
    XRT_RPC_CLOSE,
    XRT_RPC_RESET,
    XRT_RPC_FOLLOW,
    XRT_RPC_ADOPT,
    XRT_RPC_BP_SET,
    XRT_RPC_BP_RESERVE,
    XRT_RPC_BP_RESTORE,
    XRT_RPC_BP_RESOLVE,
    XRT_RPC_BP_WITHDRAW,
    XRT_RPC_BP_ENABLE,
    XRT_RPC_BP_INTERNAL,
    XRT_RPC_BP_REMOVE,
    XRT_RPC_WATCH_SET,
    XRT_RPC_WATCH_REMOVE,
    XRT_RPC_WATCH_CAPACITY,
    XRT_RPC_READ,
    XRT_RPC_WRITE,
    XRT_RPC_REGISTERS,
    XRT_RPC_REGISTER_WRITE,
    XRT_RPC_EXTENDED,
    XRT_RPC_SIGNAL_SUPPRESS,
    XRT_RPC_INVALIDATE,
    XRT_RPC_EVENT,
    XRT_RPC_SIGNAL_INFO,
    XRT_RPC_VIEW,
    XRT_RPC_FILE_OPEN,
    XRT_RPC_FILE_READ,
    XRT_RPC_FILE_CLOSE,
    XRT_RPC_CPU_START,
    XRT_RPC_SYSCALLS_START,
    XRT_RPC_PERF_DESTROY,
    XRT_RPC_PERF_ENABLE,
    XRT_RPC_PERF_STOP,
    XRT_RPC_PERF_RETIRE,
    XRT_RPC_PERF_ENROLL,
    XRT_RPC_PERF_THREAD,
    XRT_RPC_PERF_RING,
    XRT_RPC_PERF_ACK,
    XRT_RPC_PERF_INFO,
    XRT_RPC_ALLOCATIONS_START,
    XRT_RPC_FUNCTION_START,
    XRT_RPC_CONTROL_WRITE,
    XRT_RPC_SOURCE_OPEN,
    XRT_RPC_CLEAR_STOP
};

enum xrt_rpc_class {
    XRT_RPC_CLASS_PROTOCOL = 0,
    XRT_RPC_CLASS_PERF,
    XRT_RPC_CLASS_FILE,
    XRT_RPC_CLASS_READ,
    XRT_RPC_CLASS_MUTATION
};

/* Replaces every opcode >= CPU_START inference. An unassigned opcode is not
 * a perf operation. */
static inline enum xrt_rpc_class xrt_rpc_classify(uint16_t op)
{
    switch ((enum xrt_rpc_op)op) {
    case XRT_RPC_CPU_START:
    case XRT_RPC_SYSCALLS_START:
    case XRT_RPC_PERF_DESTROY:
    case XRT_RPC_PERF_ENABLE:
    case XRT_RPC_PERF_STOP:
    case XRT_RPC_PERF_RETIRE:
    case XRT_RPC_PERF_ENROLL:
    case XRT_RPC_PERF_THREAD:
    case XRT_RPC_PERF_RING:
    case XRT_RPC_PERF_ACK:
    case XRT_RPC_PERF_INFO:
    case XRT_RPC_ALLOCATIONS_START:
    case XRT_RPC_FUNCTION_START:
        return XRT_RPC_CLASS_PERF;
    case XRT_RPC_FILE_OPEN:
    case XRT_RPC_FILE_READ:
    case XRT_RPC_FILE_CLOSE:
    case XRT_RPC_SOURCE_OPEN:
        return XRT_RPC_CLASS_FILE;
    case XRT_RPC_HELLO:
    case XRT_RPC_CREATE:
    case XRT_RPC_SYNC:
    case XRT_RPC_READ:
    case XRT_RPC_REGISTERS:
    case XRT_RPC_EXTENDED:
    case XRT_RPC_WATCH_CAPACITY:
    case XRT_RPC_SIGNAL_INFO:
    case XRT_RPC_VIEW:
        return XRT_RPC_CLASS_READ;
    case XRT_RPC_DESTROY:
    case XRT_RPC_LAUNCH:
    case XRT_RPC_ATTACH:
    case XRT_RPC_INTERRUPT:
    case XRT_RPC_CONTINUE:
    case XRT_RPC_STEP:
    case XRT_RPC_WAIT_STOPPED:
    case XRT_RPC_DETACH:
    case XRT_RPC_DETACH_FAMILY:
    case XRT_RPC_CLOSE:
    case XRT_RPC_RESET:
    case XRT_RPC_FOLLOW:
    case XRT_RPC_ADOPT:
    case XRT_RPC_BP_SET:
    case XRT_RPC_BP_RESERVE:
    case XRT_RPC_BP_RESTORE:
    case XRT_RPC_BP_RESOLVE:
    case XRT_RPC_BP_WITHDRAW:
    case XRT_RPC_BP_ENABLE:
    case XRT_RPC_BP_INTERNAL:
    case XRT_RPC_BP_REMOVE:
    case XRT_RPC_WATCH_SET:
    case XRT_RPC_WATCH_REMOVE:
    case XRT_RPC_WRITE:
    case XRT_RPC_REGISTER_WRITE:
    case XRT_RPC_SIGNAL_SUPPRESS:
    case XRT_RPC_INVALIDATE:
    case XRT_RPC_EVENT:
    case XRT_RPC_CONTROL_WRITE:
    case XRT_RPC_CLEAR_STOP:
        return XRT_RPC_CLASS_MUTATION;
    default:
        return XRT_RPC_CLASS_PROTOCOL;
    }
}

_Static_assert(XRT_FILE_LIMIT == 70, "status 70 is the file limit");
_Static_assert(XRT_AMBIGUOUS_MATCH == 76, "status 76 is ambiguous probe match");
_Static_assert(XRT_FILE_SLOT_LIMIT == 84, "file-slot exhaustion stays appended");
_Static_assert(XRT_RPC_ALLOCATIONS_START == 52, "allocation start stays 52");
_Static_assert(XRT_RPC_FUNCTION_START == 53, "function start stays 53");
_Static_assert(XRT_RPC_CONTROL_WRITE == 54, "control write is opcode 54");
_Static_assert(XRT_RPC_SOURCE_OPEN == 55, "source open is opcode 55");
_Static_assert(XRT_RPC_CLEAR_STOP == 56, "clear stop is opcode 56");
#endif
