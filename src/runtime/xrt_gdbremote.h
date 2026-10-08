#ifndef XODB_RUNTIME_GDBREMOTE_H
#define XODB_RUNTIME_GDBREMOTE_H
#include "xrt_target.h"
#define XRT_GDB_CAP_THREADS (UINT64_C(1) << 0)
#define XRT_GDB_CAP_STEP (UINT64_C(1) << 1)
#define XRT_GDB_CAP_SOFTWARE_BREAK (UINT64_C(1) << 2)
#define XRT_GDB_CAP_WATCH (UINT64_C(1) << 3)
#define XRT_GDB_CAP_LIBRARIES (UINT64_C(1) << 4)
#define XRT_GDB_CAP_BINARY_WRITE (UINT64_C(1) << 5)
#define XRT_GDB_CAP_REGISTER_WRITE (UINT64_C(1) << 6)
#define XRT_GDB_CAP_INTERRUPT (UINT64_C(1) << 7)
struct xrt_gdb_info {
    uint64_t supported, unsupported, failed;
    uint32_t packet_size, register_count;
    int attached; /* -1 means qAttached unavailable; zero means stub launched. */
    char architecture[64], reason[128];
};
enum xrt_status xrt_target_gdb_remote(const char *endpoint, struct xrt_target **out);
bool xrt_target_gdb_info(const struct xrt_target *, struct xrt_gdb_info *);
#endif
