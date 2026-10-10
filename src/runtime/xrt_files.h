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
/* How a successful mapped-file open was resolved. REMOTE means the local
 * snapshot came from the agent; its namespace path is not in the wire ABI. */
enum xrt_file_source {
    XRT_FILE_SOURCE_UNKNOWN,
    XRT_FILE_SOURCE_MAP_FILES,
    XRT_FILE_SOURCE_EXE,
    XRT_FILE_SOURCE_ROOT,
    XRT_FILE_SOURCE_HOST,
    XRT_FILE_SOURCE_REMOTE
};
/* Returned descriptors belong to the caller. Remote results are immutable
 * local snapshots of target files, so analysis never opens host /proc/PID. */
enum xrt_status xrt_target_file_open(const struct xrt_target *, const struct xrt_file_request *,
                                     int *, struct xrt_file_identity *);
enum xrt_status xrt_target_file(const struct xrt_target *, const struct xrt_file_request *,
                                int *fd);
enum xrt_status xrt_process_file(int32_t pid, const struct xrt_file_request *, int *fd);
/* Optional source output is set only on success. Identity checks and lookup
 * order are identical to the ordinary open calls. */
enum xrt_status xrt_target_file_resolved(const struct xrt_target *, const struct xrt_file_request *,
        int *, struct xrt_file_identity *, enum xrt_file_source *);
enum xrt_status xrt_process_file_resolved(int32_t, const struct xrt_file_request *,
        int *, enum xrt_file_source *);
enum xrt_status xrt_file_identity(int fd, struct xrt_file_identity *);
enum xrt_status xrt_file_unchanged(int fd, const struct xrt_file_identity *);
/* Pinned regular file, without a whole-image snapshot. Open on the target's
 * owner thread; one worker may then use the view. Join it before close. A
 * remote view prevents destruction of its borrowed target until closed.
 * Reads are exact and bounded; failure publishes no bytes. Identity changes
 * poison the view permanently. No local pathname is reopened after open. */
#define XRT_FILE_VIEW_MAX_READ 65536
struct xrt_file_view;
enum xrt_status xrt_target_file_view_open(const struct xrt_target *,
        const struct xrt_file_request *, struct xrt_file_view **);
const struct xrt_file_identity *xrt_file_view_identity(const struct xrt_file_view *);
/* One-worker mode: a remote read yields with DISCOVERY_PENDING while a
 * foreground RPC owns or awaits the transport. No wire request was sent. */
void xrt_file_view_background(struct xrt_file_view *);
int xrt_file_view_remote(const struct xrt_file_view *);
enum xrt_file_source xrt_file_view_source(const struct xrt_file_view *);
enum xrt_status xrt_file_view_validate(struct xrt_file_view *);
enum xrt_status xrt_file_view_read(struct xrt_file_view *, uint64_t, void *, size_t);
enum xrt_status xrt_file_view_close(struct xrt_file_view *);
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
/* Worker-owned symbol projection: at most 64 MiB of selected sections, each
 * read at most 64 KiB. Successful start owns the view; failed start does not.
 * The local application uses this when a full-image snapshot is too large.
 * Cancel is asynchronous; destroy joins before releasing the borrowed view.
 * Poll is owner-thread only, returning PENDING or a sealed fd exactly once.
 * A completed poll revalidates the original file before transferring the fd. */
struct xrt_symbol_job;
/* Synchronous projection for ordinary local files up to 256 MiB. Borrows the
 * view; copies at most 64 MiB of symbol metadata, never whole code or DWARF.
 * Larger/remote inputs return UNSUPPORTED_MODE and use the worker instead. */
enum xrt_status xrt_local_symbol_file(struct xrt_file_view *, int *, uint64_t *resident);
enum xrt_status xrt_symbol_job_start(struct xrt_file_view *, struct xrt_symbol_job **);
enum xrt_status xrt_symbol_job_poll(struct xrt_symbol_job *, int *, uint64_t *resident);
void xrt_symbol_job_cancel(struct xrt_symbol_job *);
void xrt_symbol_job_destroy(struct xrt_symbol_job *);
#endif
