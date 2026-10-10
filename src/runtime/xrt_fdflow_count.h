#ifndef XODB_RUNTIME_FDFLOW_COUNT_H
#define XODB_RUNTIME_FDFLOW_COUNT_H
#include "xrt_fdflow.h"
#include "xrt_fdgraph.h"
/* A completed polling sample can correlate an event fd with an inode; it does
 * not prove which kernel file a concurrent fdget used. Counter rows retain the
 * identity that was sampled at entry and never inherit a reused fd's totals. */
#define XRT_FDFLOW_COUNT_CAP 1u
#define XRT_FDFLOW_COUNT_OOM 2u
#define XRT_FDFLOW_COUNT_INCOMPLETE 4u
struct xrt_fdflow_binding {
    int32_t pid, fd;
    uint64_t start, device, inode;
    uint32_t kind, row;
};
struct xrt_fdflow_bindings {
    struct xrt_fdflow_binding *rows; /* sorted by pid, fd; owned after replace */
    uint32_t count;
    uint64_t sequence, started_ns, ready_ns;
};
enum xrt_status xrt_fdflow_bindings_create(const struct xrt_fd_snapshot *,
                                           struct xrt_fdflow_bindings **);
void xrt_fdflow_bindings_free(struct xrt_fdflow_bindings *);
/* Rows exist only for descriptors of the current bound table that saw IO in
 * this capture: a bind drops the others. serial is unique and ascends with row
 * order within a capture, so consumers can match rows across publications. */
struct xrt_fdflow_count_row {
    uint64_t serial;
    int32_t pid, fd;
    uint64_t start, device, inode;
    uint32_t kind;
    int active; /* belongs to the current sampled table; set on every published row */
    uint64_t read_bytes, write_bytes, calls, last_ns;
};
struct xrt_fdflow_counts {
    const struct xrt_fdflow_count_row *rows;
    uint32_t row_count, thread_count, process_count, flags;
    uint64_t read_bytes, write_bytes, unknown_read, unknown_write;
    uint64_t unpaired, invalidated, dropped, duplicates, failed_calls;
    uint64_t sequence, taken_ns;
};
struct xrt_fdflow_counter;
enum xrt_status xrt_fdflow_counter_create(uint32_t max_rows, uint32_t max_threads,
                                          uint32_t max_processes, struct xrt_fdflow_counter **);
void xrt_fdflow_counter_free(struct xrt_fdflow_counter *);
/* Takes ownership on success. No procfs or target IO. Prepared on the polling
 * worker; merging, row compaction and eviction of idle pids/threads are linear
 * in observed descriptors and tracked identities, not configured limits. Feeding
 * is O(1) amortised per record. */
enum xrt_status xrt_fdflow_counter_bind(struct xrt_fdflow_counter *, struct xrt_fdflow_bindings *);
/* Consume each snapshot once, in drain order. Arrays from view are borrowed
 * until the next counter operation. An incomplete stream retains byte totals
 * but withdraws sampled joins; unknown bytes remain explicit. */
enum xrt_status xrt_fdflow_counter_feed(struct xrt_fdflow_counter *,
                                        const struct xrt_fdflow_snapshot *);
void xrt_fdflow_counter_view(const struct xrt_fdflow_counter *, struct xrt_fdflow_counts *);
#endif
