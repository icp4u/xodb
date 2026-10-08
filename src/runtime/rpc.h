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
 * ranges. Zero preserves the ordinary 256 MiB snapshot policy, including
 * requests from older hosts. Older agents may still refuse large images. */
#define XRT_RPC_FILE_SYMBOLS UINT64_C(1)
/* HELLO arg[0] requests an optional u64 capability suffix. Old hosts keep the
 * original 16-byte response; old agents ignore the request and return 16. */
#define XRT_RPC_HELLO_CAPABILITIES UINT64_C(1)
#define XRT_RPC_CAP_SOURCE UINT64_C(1)
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
    XRT_RPC_SOURCE_OPEN
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
        return XRT_RPC_CLASS_MUTATION;
    default:
        return XRT_RPC_CLASS_PROTOCOL;
    }
}

_Static_assert(XRT_FILE_LIMIT == 70, "status 70 is the file limit");
_Static_assert(XRT_AMBIGUOUS_MATCH == 76, "status 76 is ambiguous probe match");
_Static_assert(XRT_RPC_ALLOCATIONS_START == 52, "allocation start stays 52");
_Static_assert(XRT_RPC_FUNCTION_START == 53, "function start stays 53");
_Static_assert(XRT_RPC_CONTROL_WRITE == 54, "control write is opcode 54");
_Static_assert(XRT_RPC_SOURCE_OPEN == 55, "source open is opcode 55");
#endif
