#ifndef XODB_RUNTIME_FILES_H
#define XODB_RUNTIME_FILES_H
#include "xrt.h"
#include <stdint.h>
#include <stddef.h>
#include <signal.h>
struct xrt_target;
/* Whole-image extent, not an up-front allocation. Older agents advertised no
 * large-image capability and enforced the legacy limit independently. */
#define XRT_REMOTE_IMAGE_LIMIT (UINT64_C(2) * 1024 * 1024 * 1024)
#define XRT_LEGACY_REMOTE_IMAGE_LIMIT (UINT64_C(256) * 1024 * 1024)
/* Synchronous whole-file transfers run on the target owner thread, uncached and
 * uncancellable. Larger main images use the background ranged image job. */
#define XRT_REMOTE_SYNC_IMAGE_LIMIT XRT_LEGACY_REMOTE_IMAGE_LIMIT
/* Shared agent file table. HELLO reports this count only when the host asks. */
#define XRT_AGENT_FILE_SLOTS 32u
uint64_t xrt_target_remote_image_limit(const struct xrt_target *);
/* Slots the connected agent advertised. Zero means an older agent that did
 * not report a count; callers keep today's caps. Local targets return zero. */
uint32_t xrt_target_file_slots(const struct xrt_target *);
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
 * order are identical to the ordinary open calls. On a remote target the
 * identity is the agent's stat of the target file, not the stat of the
 * sealed host copy. */
enum xrt_status xrt_target_file_resolved(const struct xrt_target *, const struct xrt_file_request *,
        int *, struct xrt_file_identity *, enum xrt_file_source *);
/* This thread only. While set, a regular file whose whole image is already
 * held skips the body read. The callback returns non-zero only after it has
 * retained that image for the thread. The descriptor is then a sealed file of
 * the opened size and must not be read. NULL keeps the ordinary copy. */
void xrt_remote_set_held_image(int (*fn)(const struct xrt_file_identity *));
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
/* Mutable owner-thread variant may reuse the stopped maps cache. */
enum xrt_status xrt_target_file_view_open_owner(struct xrt_target *,
        const struct xrt_file_request *, struct xrt_file_view **);
const struct xrt_file_identity *xrt_file_view_identity(const struct xrt_file_view *);
/* One-worker mode: a remote read yields with DISCOVERY_PENDING while a
 * foreground RPC owns or awaits the transport. No wire request was sent. */
void xrt_file_view_background(struct xrt_file_view *);
int xrt_file_view_remote(const struct xrt_file_view *);
enum xrt_file_source xrt_file_view_source(const struct xrt_file_view *);
enum xrt_status xrt_file_view_validate(struct xrt_file_view *);
/* Owner only after joining the file worker: identity validation participates
 * in foreground ordering instead of reporting transport contention as pending. */
enum xrt_status xrt_file_view_validate_foreground(struct xrt_file_view *);
/* Once all reads finish, release the remote slot but keep the identity and
 * target lifetime guard. Local views stay pinned. A released remote view
 * can only be validated (by an open/check/close), not read again. Call from
 * the worker at completion or from its owner after joining, never concurrently. */
enum xrt_status xrt_file_view_release(struct xrt_file_view *);
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
enum xrt_status xrt_target_file_budget(const struct xrt_target *, struct xrt_file_budget *);
/* Owner thread only. Remote ELF symbol-only sparse projection; do not use for
 * debug information or code bytes. Partial transfers resume on the next pass.
 * The output fd is sealed; resident counts retained source bytes, not holes.
 * identity, when not NULL, receives the agent's stat of the projected file. */
enum xrt_status xrt_remote_symbol_file(const struct xrt_target *, const struct xrt_file_request *,
                                      int *fd, uint64_t *resident, struct xrt_file_identity *identity);
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
