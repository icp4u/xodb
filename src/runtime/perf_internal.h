#ifndef XODB_RUNTIME_PERF_INTERNAL_H
#define XODB_RUNTIME_PERF_INTERNAL_H
#include "xrt_perf.h"
struct xrt_perf_slot {
    struct xrt_perf_thread thread;
    int fds[XRT_PERF_MAX_EVENTS];
    uint8_t *map;
    size_t map_size;
    uint64_t tail;
    uint32_t lost_read_mask; /* event read format is exactly PERF_FORMAT_LOST */
    bool owns_map;
};
struct xrt_perf {
    const struct xrt_target *remote_target;
    uint64_t remote_id;
    struct xrt_perf_info remote_info;
    bool remote_retired[XRT_PERF_MAX_THREADS], remote_drained[XRT_PERF_MAX_THREADS];
    struct xrt_perf_slot slots[XRT_PERF_MAX_THREADS];
    size_t count, cursor, max_threads, page_size;
    unsigned data_pages;
    uint64_t budget, allocated;
    bool running;
    bool failed;
    struct xrt_perf_failure failure;
};
/* Shared by native drain and the agent: acquire a validated ring view, then
 * commit only a prefix of that view. A zero-size view denotes a closed slot. */
enum xrt_perf_drain_status xrt_perf_peek(struct xrt_perf *, size_t, struct xrt_perf_ring *);
enum xrt_perf_drain_status xrt_perf_commit(struct xrt_perf *, const struct xrt_perf_ring *,
                                           struct xrt_perf_consumed);
#endif
