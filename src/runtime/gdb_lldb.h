#ifndef XODB_GDB_LLDB_H
#define XODB_GDB_LLDB_H
/* Parsers for the LLDB extension replies of Apple's debugserver: qHostInfo,
 * qProcessInfo, qMemoryRegionInfo and jGetLoadedDynamicLibrariesInfos.
 * Every input is untrusted. Nothing here allocates, recurses past
 * XRT_GDB_JSON_DEPTH, or reads beyond the given length. */
#include "xrt_gdbremote.h"

#define XRT_GDB_JSON_DEPTH 16
struct xrt_gdb_host {
    enum xrt_gdb_os os;
    uint32_t cputype, address_bits, pointer_size;
    bool has_endian, little_endian;
    uint64_t pid;
};
struct xrt_gdb_stop {
    bool exec, has_exception;
    uint64_t exception, codes[4];
    unsigned code_count;
};
/* Mach exception and exec fields from a T stop. Duplicate or incomplete
 * exception tuples are refused. Unknown types retain their numeric codes. */
enum xrt_status xrt_gdb_stop_parse(const char *, size_t, struct xrt_gdb_stop *);
/* key:value; lists. Unknown keys are ignored; a repeated known key, a pair
 * without ':' or a number out of range is a protocol error. */
enum xrt_status xrt_gdb_host_parse(const char *, size_t, struct xrt_gdb_host *);
enum xrt_status xrt_gdb_process_parse(const char *, size_t, struct xrt_gdb_host *);
/* One qMemoryRegionInfo reply for the address asked. A reply without a size
 * ends the address space: OK with size zero. cut marks a raw prefix of an
 * oversized reply: its last, incomplete pair is ignored and no escape or
 * repeat marker may precede it. */
enum xrt_status xrt_gdb_region_parse(const char *, size_t, bool cut, uint64_t asked,
                                     struct xrt_gdb_region *);
/* {"images":[{"load_address":N,"pathname":"..."}]}. Stores at most capacity
 * rows; *total counts every image, up to XRT_GDB_IMAGES_MAX. */
enum xrt_status xrt_gdb_images_parse(const char *, size_t, struct xrt_gdb_image *,
                                     size_t capacity, size_t *total);
/* jThreadsInfo array. Names are bounded printable text; registers/memory are
 * ignored. Missing/duplicate IDs and repeated known fields are refused. */
enum xrt_status xrt_gdb_threads_parse(const char *, size_t, struct xrt_gdb_thread_info *,
                                      size_t capacity, size_t *total);
#endif
