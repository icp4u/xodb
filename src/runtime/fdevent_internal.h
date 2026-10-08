#ifndef XODB_FDEVENT_INTERNAL_H
#define XODB_FDEVENT_INTERNAL_H
#include "xrt_fdevent.h"
struct fd_event_lane {
    struct xrt_fdevent_record pending;
    uint64_t last_ns;
    int has_pending, closed;
};
struct fd_event_counter {
    struct xrt_fdevent_snapshot snapshot;
    struct xrt_fdevent_row *rows;
    uint32_t *table, table_size, limit;
    struct fd_event_lane lane[XRT_FDEVENT_MAX_THREADS];
    uint64_t record_lost[XRT_FDEVENT_MAX_THREADS], kernel_lost[XRT_FDEVENT_MAX_THREADS];
};
int fd_event_counter_init(struct fd_event_counter *, uint32_t);
void fd_event_counter_destroy(struct fd_event_counter *);
void fd_event_counter_loss(struct fd_event_counter *, size_t, uint64_t cumulative, int known, int possible);
void fd_event_counter_feed(struct fd_event_counter *, size_t, const struct xrt_fdevent_record *);
#endif
