#ifndef XODB_RUNTIME_GDBREMOTE_H
#define XODB_RUNTIME_GDBREMOTE_H
#include "xrt_target.h"
#include "xrt_cancel.h"
#define XRT_GDB_CAP_THREADS (UINT64_C(1) << 0)
#define XRT_GDB_CAP_STEP (UINT64_C(1) << 1)
#define XRT_GDB_CAP_SOFTWARE_BREAK (UINT64_C(1) << 2)
#define XRT_GDB_CAP_WATCH (UINT64_C(1) << 3)
#define XRT_GDB_CAP_LIBRARIES (UINT64_C(1) << 4)
#define XRT_GDB_CAP_BINARY_WRITE (UINT64_C(1) << 5)
#define XRT_GDB_CAP_REGISTER_WRITE (UINT64_C(1) << 6)
#define XRT_GDB_CAP_INTERRUPT (UINT64_C(1) << 7)
#define XRT_GDB_CAP_REGIONS (UINT64_C(1) << 8)
#define XRT_GDB_CAP_IMAGES (UINT64_C(1) << 9)
#define XRT_GDB_CAP_THREAD_INFO (UINT64_C(1) << 10)
#define XRT_GDB_REGIONS_MAX 4096
#define XRT_GDB_IMAGES_MAX 4096
#define XRT_GDB_IMAGE_SEGMENTS_MAX 64
/* The target's operating system selects its signal numbering. Unknown keeps
 * the GDB protocol numbers and their Linux display mapping. */
enum xrt_gdb_os { XRT_GDB_OS_UNKNOWN, XRT_GDB_OS_LINUX, XRT_GDB_OS_DARWIN };
struct xrt_gdb_info {
    uint64_t supported, unsupported, failed;
    uint32_t packet_size, register_count;
    int attached; /* -1 means qAttached unavailable; zero means stub launched. */
    char architecture[64], reason[128];
    enum xrt_gdb_os os;
    uint32_t address_bits; /* zero means unknown; pointers above it carry tags. */
    /* Last causal stop, cached without IO. Signal delivery differs from Mach
     * exception reporting, even when debugserver also supplies a signal byte. */
    int32_t stop_tid;
    bool has_exception, has_fault, pending_delivery;
    uint32_t exception_count;
    uint64_t exception_type, exception_codes[4], fault_address;
};
/* Remote text is untrusted: names are printable ASCII, bounded and cut. */
struct xrt_gdb_region {
    uint64_t start, size;
    bool mapped, read, write, execute;
    char type[32], name[128];
};
/* Optional stopped-thread metadata. The thread inventory remains authoritative;
 * a JSON row cannot create a thread. Queue addresses are opaque, not names. */
struct xrt_gdb_thread_info {
    uint64_t remote_tid, queue_address;
    bool has_name, name_truncated, has_queue;
    char name[128];
};
struct xrt_gdb_image_segment {
    uint64_t vmaddr, vmsize;
    uint32_t maxprot;
    char name[17];
};
struct xrt_gdb_image {
    uint64_t load_address;
    bool path_truncated;
    char path[256];
    bool has_uuid, has_header;
    unsigned char uuid[16];
    uint32_t cputype, cpusubtype, filetype, segment_count;
    struct xrt_gdb_image_segment segments[XRT_GDB_IMAGE_SEGMENTS_MAX];
};
enum xrt_status xrt_target_gdb_remote(const char *endpoint, struct xrt_target **out);
enum xrt_status xrt_target_gdb_remote_cancel(const char *endpoint, struct xrt_target **out, struct xrt_cancel *);
enum xrt_status xrt_target_gdb_info(const struct xrt_target *, struct xrt_gdb_info *);
enum xrt_status xrt_target_gdb_thread_info(const struct xrt_target *, int32_t tid,
                                          struct xrt_gdb_thread_info *);
/* Stopped targets of a stub with the LLDB extensions only. At most capacity
 * rows are stored; *total above capacity means the list was cut. A stub
 * without the packet, or a reply above the packet limit, is the typed
 * XRT_FILE_UNAVAILABLE or XRT_BUFFER_TOO_SMALL with the connection kept. */
enum xrt_status xrt_target_gdb_regions(struct xrt_target *, struct xrt_gdb_region *,
                                       size_t capacity, size_t *total);
enum xrt_status xrt_target_gdb_images(struct xrt_target *, struct xrt_gdb_image *,
                                      size_t capacity, size_t *total);
#endif
