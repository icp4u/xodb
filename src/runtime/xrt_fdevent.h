#ifndef XODB_RUNTIME_FDEVENT_H
#define XODB_RUNTIME_FDEVENT_H
/* Bounded native Linux x86-64 syscall evidence for one explicit process.
 * One owner drains. Returned rows are borrowed until the next drain/close.
 *
 * Bytes are successful syscall return values, not storage traffic. Rows name
 * fd numbers over the capture window: closing/reopening a number does not
 * turn its accumulated bytes into IO attributable to its current path.
 * Polling metadata must remain separately identified. No path is inferred.
 */
#include "xrt.h"
#include "xrt_perf.h"
#include <stddef.h>
#include <stdint.h>

#define XRT_FDEVENT_MAX_THREADS 32
#define XRT_FDEVENT_LOSS 1u
#define XRT_FDEVENT_BAD_RECORD 2u
#define XRT_FDEVENT_UNPAIRED 4u
#define XRT_FDEVENT_ROW_LIMIT 8u
#define XRT_FDEVENT_SCOPE_CHANGED 16u
#define XRT_FDEVENT_UNSUPPORTED 32u
#define XRT_FDEVENT_THROTTLED 64u
#define XRT_FDEVENT_SATURATED 128u
#define XRT_FDEVENT_POSSIBLE_LOSS 256u /* ring approached record capacity */
#define XRT_FDEVENT_LOSS_UNAVAILABLE 512u /* no readable per-FD lost counter */

struct xrt_fdevent_row {
    int32_t fd;
    uint32_t reserved;
    uint64_t read_bytes, write_bytes, read_calls, write_calls;
    uint64_t open_returns, close_successes, dup_returns;
};

struct xrt_fdevent_snapshot {
    int32_t pid;
    uint32_t flags;
    uint64_t start_ticks, started_ns, taken_ns;
    uint64_t records, lost, unpaired, invalid, dropped_rows;
    uint64_t read_bytes, write_bytes, open_returns, close_successes, dup_returns;
    uint64_t drain_cpu_ns, drain_wall_ns, ring_bytes;
    uint32_t threads, row_count;
    int running, pending; /* pending: bounded drain left unread records */
    /* Exact only for complete pairs of documented supported syscalls in the
     * selected threads. mmap/io_uring, pointer-returned fd arrays and implicit
     * dup2 replacement closes are not inferred from polling. */
    const struct xrt_fdevent_row *rows;
    const char *reason; /* static string; non-NULL also for successful scope */
};

struct xrt_fdevent_options {
    int32_t pid;
    uint64_t expected_start; /* required; pinned proc identity */
    uint32_t max_rows;       /* 0:4096; maximum 65536 distinct fd numbers */
    uint32_t drain_records;  /* 0:65536; maximum records decoded in one drain */
};
struct xrt_fdevent;
enum xrt_status xrt_fdevent_open(const struct xrt_fdevent_options *, struct xrt_fdevent **,
                                 struct xrt_perf_failure *);
/* Close kernel capture resources while retaining borrowed counter rows. */
void xrt_fdevent_stop(struct xrt_fdevent *);
void xrt_fdevent_close(struct xrt_fdevent *);
enum xrt_status xrt_fdevent_drain(struct xrt_fdevent *, struct xrt_fdevent_snapshot *);

/* Pure decoder shared by the collector and synthetic record tests. Args are
 * retained only for entry/exit pairing; no pointed-to user memory is read. */
enum xrt_fdevent_kind {
    XRT_FDEVENT_ENTER,
    XRT_FDEVENT_EXIT,
    XRT_FDEVENT_LOST,
    XRT_FDEVENT_THROTTLE,
    XRT_FDEVENT_EXEC,
    XRT_FDEVENT_TASK_EXIT,
    XRT_FDEVENT_FORK,
    XRT_FDEVENT_IGNORE
};
struct xrt_fdevent_identity {
    int32_t pid, tid;
    uint64_t enter_id, exit_id;
    uint16_t enter_type, exit_type;
};
struct xrt_fdevent_record {
    enum xrt_fdevent_kind kind;
    uint64_t time_ns, args[6], lost;
    int64_t number, result;
};
int xrt_fdevent_decode(const void *, size_t, const struct xrt_fdevent_identity *,
                       struct xrt_fdevent_record *);
#endif
