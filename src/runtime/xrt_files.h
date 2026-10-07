#ifndef XODB_RUNTIME_FILES_H
#define XODB_RUNTIME_FILES_H
#include "xrt.h"
#include <stdint.h>
#include <stddef.h>
#include <signal.h>
struct xrt_target;
struct xrt_file_identity {
    uint64_t device, inode;
    int64_t size, mtime_sec, mtime_ns, ctime_sec, ctime_ns;
};
struct xrt_mapping {
    uint64_t start, end, offset, device_major, device_minor, inode;
    const char *path;
};
enum xrt_file_kind {
    XRT_FILE_MAPPED,
    XRT_FILE_MAPS,
    XRT_FILE_THREAD_STAT,
    XRT_FILE_BOOT_ID,
    XRT_FILE_THREAD_COMM,
    XRT_FILE_AUXV
};
struct xrt_file_request {
    enum xrt_file_kind kind;
    int32_t tid;
    struct xrt_mapping mapping; /* used only for MAPPED */
};
/* Returned descriptors belong to the caller. Remote results are immutable
 * local snapshots of target files, so analysis never opens host /proc/PID. */
enum xrt_status xrt_target_file_open(const struct xrt_target *, const struct xrt_file_request *,
                                     int *, struct xrt_file_identity *);
enum xrt_status xrt_target_file(const struct xrt_target *, const struct xrt_file_request *,
                                int *fd);
enum xrt_status xrt_process_file(int32_t pid, const struct xrt_file_request *, int *fd);
enum xrt_status xrt_file_identity(int fd, struct xrt_file_identity *);
enum xrt_status xrt_file_unchanged(int fd, const struct xrt_file_identity *);
/* Owner-thread scope for automatic remote symbol discovery. Explicit user
 * file requests keep their normal limits. The borrowed budget must outlive
 * the scope; clear it before returning to the event loop. */
struct xrt_file_budget {
    uint64_t limit_bytes, deadline_ns, bytes, files, negative_hits, skipped;
    uint64_t resumed_bytes, reads;
    const volatile sig_atomic_t *cancel;
};
void xrt_target_file_budget(const struct xrt_target *, struct xrt_file_budget *);
/* Owner thread only. Remote ELF symbol-only sparse projection; do not use for
 * debug information or code bytes. Partial transfers resume on the next pass.
 * The output fd is sealed; resident counts retained source bytes, not holes. */
enum xrt_status xrt_remote_symbol_file(const struct xrt_target *, const struct xrt_file_request *,
                                      int *fd, uint64_t *resident);
#endif
