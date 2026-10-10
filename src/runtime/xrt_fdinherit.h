#ifndef XODB_RUNTIME_FDINHERIT_H
#define XODB_RUNTIME_FDINHERIT_H
#include "xrt_fdscan.h"
/* Polling evidence only: matching fd number, kind and device/inode in a sampled
 * parent/child pair. Reopening the same file can produce the same match. This
 * does not establish a shared open file description, who opened it, inheritance
 * at fork, or survival across exec. Those require separate history evidence. */
#define XRT_FDINH_PARENT_STALE 1u
#define XRT_FDINH_CHILD_STALE 2u
#define XRT_FDINH_IDENTITY_STALE 4u
#define XRT_FDINH_PARENT_FLAGS_KNOWN 8u
#define XRT_FDINH_CHILD_FLAGS_KNOWN 16u
#define XRT_FDINH_PARENT_CLOEXEC 32u
#define XRT_FDINH_CHILD_CLOEXEC 64u
struct xrt_fdinherit_row {
    uint32_t parent, child, parent_fd, child_fd, flags; /* exact source indices */
};
struct xrt_fdinherit {
    uint64_t sequence, taken_ns;
    struct xrt_fdinherit_row *rows;
    uint32_t count, capacity, matched, dropped, stale;
    uint32_t cloexec, no_cloexec, flags_unknown; /* child flag, fresh samples only */
    uint32_t parent_pairs, parent_unavailable, parent_unavailable_fds;
    /* Reasons within parent_unavailable: fd table denied (needs privilege),
     * not listed (exited, or hidden by hidepid), pid reused after the child. */
    uint32_t parent_denied, parent_absent, parent_reused;
    uint32_t no_parent_fd, different_object, identity_unknown;
    size_t allocated_bytes;
};
/* Source rows must be sorted by pid, then fd. Limits: 16384 processes, 262144
 * descriptors; max_rows is 1..262144. Storage grows with observed matches.
 * Counts cover all matching rows, including those omitted by max_rows. Rows
 * for fds 0-2 come after all others, so shared std fds fill max_rows last.
 * Every source fd is accounted for by matched, parent_unavailable_fds,
 * no_parent_fd, different_object or identity_unknown. No IO or target calls. */
enum xrt_status xrt_fdinherit_build(const struct xrt_fd_snapshot *, uint32_t max_rows, struct xrt_fdinherit **);
void xrt_fdinherit_free(struct xrt_fdinherit *);
#endif
