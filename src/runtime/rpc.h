#ifndef XODB_RUNTIME_RPC_H
#define XODB_RUNTIME_RPC_H
#include "xrt_wire.h"
/* Requests carry generation:u64, arg[3]:u64, then an operation-specific byte
 * string (at most 64 KiB). Replies carry value:u64, extra_size:u32, extra bytes,
 * snapshot:bool; a snapshot is preceded by shared_vm:bool and family_root:u32.
 * All mutations check the authoritative expected generation before executing.
 * A snapshot is complete: its bounded event suffix must be contiguous. */
#define XRT_RPC_DATA_MAX 65536
#define XRT_RPC_TARGETS 128
#define XRT_RPC_REQUEST_PREFIX 32
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
    XRT_RPC_FUNCTION_START
};
#endif
