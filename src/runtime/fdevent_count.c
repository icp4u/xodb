#include "fdevent_internal.h"
#include "fdevent_syscalls.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void add(struct fd_event_counter *c, uint64_t *to, uint64_t n)
{
    if (UINT64_MAX - *to < n) {
        *to = UINT64_MAX;
        c->snapshot.flags |= XRT_FDEVENT_SATURATED;
    } else
        *to += n;
}
int fd_event_counter_init(struct fd_event_counter *c, uint32_t limit)
{
    if (!c || !limit || limit > 65536)
        return 0;
    memset(c, 0, sizeof(*c));
    c->limit = limit;
    c->table_size = 2;
    while (c->table_size < limit * 2)
        c->table_size *= 2;
    c->rows = calloc(limit, sizeof(*c->rows));
    c->table = calloc(c->table_size, sizeof(*c->table));
    if (!c->rows || !c->table) {
        fd_event_counter_destroy(c);
        return 0;
    }
    c->snapshot.rows = c->rows;
    c->snapshot.reason = "successful covered syscalls in selected threads; fd numbers span "
                         "reopenings; current paths are not attribution";
    return 1;
}
void fd_event_counter_destroy(struct fd_event_counter *c)
{
    if (c) {
        free(c->rows);
        free(c->table);
        memset(c, 0, sizeof(*c));
    }
}
static struct xrt_fdevent_row *row(struct fd_event_counter *c, uint64_t argument)
{
    /* Linux fd arguments use the low signed 32 bits. */
    int32_t fd = (int32_t)(uint32_t)argument;
    if (fd < 0) {
        c->snapshot.flags |= XRT_FDEVENT_BAD_RECORD;
        add(c, &c->snapshot.invalid, 1);
        return NULL;
    }
    uint32_t slot = ((uint32_t)fd * 2654435761u) & (c->table_size - 1);
    while (c->table[slot]) {
        struct xrt_fdevent_row *r = &c->rows[c->table[slot] - 1];
        if (r->fd == fd)
            return r;
        slot = (slot + 1) & (c->table_size - 1);
    }
    if (c->snapshot.row_count == c->limit) {
        c->snapshot.flags |= XRT_FDEVENT_ROW_LIMIT;
        add(c, &c->snapshot.dropped_rows, 1);
        return NULL;
    }
    uint32_t i = c->snapshot.row_count++;
    c->table[slot] = i + 1;
    c->rows[i].fd = fd;
    return &c->rows[i];
}
static int relevant(int64_t nr)
{
    switch (nr) {
    case XRT_FDEVENT_NR_read:
    case XRT_FDEVENT_NR_write:
    case XRT_FDEVENT_NR_open:
    case XRT_FDEVENT_NR_close:
    case XRT_FDEVENT_NR_pread64:
    case XRT_FDEVENT_NR_pwrite64:
    case XRT_FDEVENT_NR_readv:
    case XRT_FDEVENT_NR_writev:
    case XRT_FDEVENT_NR_pipe:
    case XRT_FDEVENT_NR_dup:
    case XRT_FDEVENT_NR_dup2:
    case XRT_FDEVENT_NR_sendfile:
    case XRT_FDEVENT_NR_socket:
    case XRT_FDEVENT_NR_accept:
    case XRT_FDEVENT_NR_sendto:
    case XRT_FDEVENT_NR_recvfrom:
    case XRT_FDEVENT_NR_sendmsg:
    case XRT_FDEVENT_NR_recvmsg:
    case XRT_FDEVENT_NR_socketpair:
    case XRT_FDEVENT_NR_fcntl:
    case XRT_FDEVENT_NR_creat:
    case XRT_FDEVENT_NR_epoll_create:
    case XRT_FDEVENT_NR_inotify_init:
    case XRT_FDEVENT_NR_openat:
    case XRT_FDEVENT_NR_splice:
    case XRT_FDEVENT_NR_tee:
    case XRT_FDEVENT_NR_vmsplice:
    case XRT_FDEVENT_NR_signalfd:
    case XRT_FDEVENT_NR_timerfd_create:
    case XRT_FDEVENT_NR_eventfd:
    case XRT_FDEVENT_NR_accept4:
    case XRT_FDEVENT_NR_signalfd4:
    case XRT_FDEVENT_NR_eventfd2:
    case XRT_FDEVENT_NR_epoll_create1:
    case XRT_FDEVENT_NR_dup3:
    case XRT_FDEVENT_NR_pipe2:
    case XRT_FDEVENT_NR_inotify_init1:
    case XRT_FDEVENT_NR_preadv:
    case XRT_FDEVENT_NR_pwritev:
    case XRT_FDEVENT_NR_recvmmsg:
    case XRT_FDEVENT_NR_sendmmsg:
    case XRT_FDEVENT_NR_memfd_create:
    case XRT_FDEVENT_NR_userfaultfd:
    case XRT_FDEVENT_NR_copy_file_range:
    case XRT_FDEVENT_NR_preadv2:
    case XRT_FDEVENT_NR_pwritev2:
    case XRT_FDEVENT_NR_io_uring_setup:
    case XRT_FDEVENT_NR_io_uring_enter:
    case XRT_FDEVENT_NR_pidfd_open:
    case XRT_FDEVENT_NR_close_range:
    case XRT_FDEVENT_NR_openat2:
        return 1;
    default:
        return 0;
    }
}
static void bytes(struct fd_event_counter *c, uint64_t fd, uint64_t amount, int write)
{
    struct xrt_fdevent_row *r = row(c, fd);
    add(c, write ? &c->snapshot.write_bytes : &c->snapshot.read_bytes, amount);
    if (r) {
        add(c, write ? &r->write_bytes : &r->read_bytes, amount);
        add(c, write ? &r->write_calls : &r->read_calls, 1);
    }
}
static void opened(struct fd_event_counter *c, int64_t fd, int dup)
{
    if (fd < 0 || fd > INT_MAX) {
        c->snapshot.flags |= XRT_FDEVENT_BAD_RECORD;
        add(c, &c->snapshot.invalid, 1);
        return;
    }
    struct xrt_fdevent_row *r = row(c, (uint64_t)fd);
    add(c, dup ? &c->snapshot.dup_returns : &c->snapshot.open_returns, 1);
    if (r)
        add(c, dup ? &r->dup_returns : &r->open_returns, 1);
}
static void complete(struct fd_event_counter *c, const struct xrt_fdevent_record *entry,
                     int64_t result)
{
    if (result < 0)
        return; /* errno and internal restart returns transfer no bytes */
    const uint64_t *a = entry->args;
    const uint64_t n = (uint64_t)result;
    switch (entry->number) {
    case XRT_FDEVENT_NR_read:
    case XRT_FDEVENT_NR_pread64:
    case XRT_FDEVENT_NR_readv:
    case XRT_FDEVENT_NR_recvfrom:
    case XRT_FDEVENT_NR_recvmsg:
    case XRT_FDEVENT_NR_preadv:
    case XRT_FDEVENT_NR_preadv2:
        bytes(c, a[0], n, 0);
        break;
    case XRT_FDEVENT_NR_write:
    case XRT_FDEVENT_NR_pwrite64:
    case XRT_FDEVENT_NR_writev:
    case XRT_FDEVENT_NR_sendto:
    case XRT_FDEVENT_NR_sendmsg:
    case XRT_FDEVENT_NR_vmsplice:
    case XRT_FDEVENT_NR_pwritev:
    case XRT_FDEVENT_NR_pwritev2:
        bytes(c, a[0], n, 1);
        break;
    case XRT_FDEVENT_NR_sendfile:
        bytes(c, a[1], n, 0);
        bytes(c, a[0], n, 1);
        break; /* sendfile */
    case XRT_FDEVENT_NR_splice:
    case XRT_FDEVENT_NR_copy_file_range:
        bytes(c, a[0], n, 0);
        bytes(c, a[2], n, 1);
        break; /* splice/copy_file_range */
    case XRT_FDEVENT_NR_tee:
        bytes(c, a[0], n, 0);
        bytes(c, a[1], n, 1);
        break; /* tee: successful transferred bytes */
    case XRT_FDEVENT_NR_open:
    case XRT_FDEVENT_NR_socket:
    case XRT_FDEVENT_NR_accept:
    case XRT_FDEVENT_NR_creat:
    case XRT_FDEVENT_NR_epoll_create:
    case XRT_FDEVENT_NR_inotify_init:
    case XRT_FDEVENT_NR_openat:
    case XRT_FDEVENT_NR_timerfd_create:
    case XRT_FDEVENT_NR_eventfd:
    case XRT_FDEVENT_NR_accept4:
    case XRT_FDEVENT_NR_eventfd2:
    case XRT_FDEVENT_NR_epoll_create1:
    case XRT_FDEVENT_NR_inotify_init1:
    case XRT_FDEVENT_NR_memfd_create:
    case XRT_FDEVENT_NR_userfaultfd:
    case XRT_FDEVENT_NR_io_uring_setup:
    case XRT_FDEVENT_NR_pidfd_open:
    case XRT_FDEVENT_NR_openat2:
        opened(c, result, 0);
        break;
    case XRT_FDEVENT_NR_signalfd:
    case XRT_FDEVENT_NR_signalfd4:
        if ((int32_t)(uint32_t)a[0] == -1)
            opened(c, result, 0);
        break;
    case XRT_FDEVENT_NR_dup:
        opened(c, result, 1);
        break;
    case XRT_FDEVENT_NR_dup2:
    case XRT_FDEVENT_NR_dup3:
        if ((int32_t)(uint32_t)a[0] != (int32_t)(uint32_t)a[1])
            opened(c, result, 1);
        break; /* A successful replacement's implicit close is not inferred. */
    case XRT_FDEVENT_NR_fcntl:
        if (a[1] == 0 || a[1] == 1030)
            opened(c, result, 1);
        break; /* F_DUPFD/_CLOEXEC */
    case XRT_FDEVENT_NR_close: {
        struct xrt_fdevent_row *r = row(c, a[0]);
        add(c, &c->snapshot.close_successes, 1);
        if (r)
            add(c, &r->close_successes, 1);
        break;
    }
    case XRT_FDEVENT_NR_pipe:
    case XRT_FDEVENT_NR_socketpair:
    case XRT_FDEVENT_NR_pipe2:
        /* Two descriptors were created; their numbers live in user memory.
         * Keep the global count and flag incomplete per-fd attribution. */
        add(c, &c->snapshot.open_returns, 2);
        c->snapshot.flags |= XRT_FDEVENT_UNSUPPORTED;
        break;
    case XRT_FDEVENT_NR_recvmmsg:
    case XRT_FDEVENT_NR_sendmmsg:
    case XRT_FDEVENT_NR_io_uring_enter:
    case XRT_FDEVENT_NR_close_range:
        c->snapshot.flags |= XRT_FDEVENT_UNSUPPORTED;
        break;
    default:
        break;
    }
}
static void unpaired(struct fd_event_counter *c, struct fd_event_lane *lane)
{
    if (lane->has_pending && relevant(lane->pending.number)) {
        c->snapshot.flags |= XRT_FDEVENT_UNPAIRED;
        add(c, &c->snapshot.unpaired, 1);
    }
    lane->has_pending = 0;
}
static void loss_total(struct fd_event_counter *c)
{
    c->snapshot.lost = 0;
    for (size_t i = 0; i < XRT_FDEVENT_MAX_THREADS; ++i) {
        uint64_t count = c->record_lost[i] > c->kernel_lost[i] ? c->record_lost[i] : c->kernel_lost[i];
        add(c, &c->snapshot.lost, count);
    }
}
void fd_event_counter_loss(struct fd_event_counter *c, size_t index, uint64_t count, int known, int possible)
{
    if (!c || index >= XRT_FDEVENT_MAX_THREADS) return;
    if (!known || count < c->kernel_lost[index]) c->snapshot.flags |= XRT_FDEVENT_LOSS_UNAVAILABLE;
    if (possible) c->snapshot.flags |= XRT_FDEVENT_POSSIBLE_LOSS;
    if (known && count > c->kernel_lost[index]) {
        c->kernel_lost[index] = count;
        c->snapshot.flags |= XRT_FDEVENT_LOSS;
        unpaired(c, &c->lane[index]);
    } else if (possible) unpaired(c, &c->lane[index]);
    loss_total(c);
}

void fd_event_counter_feed(struct fd_event_counter *c, size_t index,
                           const struct xrt_fdevent_record *r)
{
    if (!c || !r)
        return;
    add(c, &c->snapshot.records, 1);
    if (index >= XRT_FDEVENT_MAX_THREADS) {
        c->snapshot.flags |= XRT_FDEVENT_BAD_RECORD;
        add(c, &c->snapshot.invalid, 1);
        return;
    }
    struct fd_event_lane *lane = &c->lane[index];
    if (lane->closed)
        return;
    /* A loss report is evidence even if its timestamp precedes the last
     * decoded sample. Never replace a known lost count with a generic error. */
    if (r->kind == XRT_FDEVENT_LOST) {
        c->snapshot.flags |= XRT_FDEVENT_LOSS;
        add(c, &c->record_lost[index], r->lost);
        loss_total(c);
        unpaired(c, lane);
        if (r->time_ns > lane->last_ns)
            lane->last_ns = r->time_ns;
        return;
    }
    if (r->time_ns < lane->last_ns) {
        c->snapshot.flags |= XRT_FDEVENT_BAD_RECORD;
        add(c, &c->snapshot.invalid, 1);
        unpaired(c, lane);
        return;
    }
    lane->last_ns = r->time_ns;
    switch (r->kind) {
    case XRT_FDEVENT_ENTER:
        unpaired(c, lane);
        lane->pending = *r;
        lane->has_pending = 1;
        break;
    case XRT_FDEVENT_EXIT:
        if (!lane->has_pending) {
            if (relevant(r->number)) {
                c->snapshot.flags |= XRT_FDEVENT_UNPAIRED;
                add(c, &c->snapshot.unpaired, 1);
            }
        } else if (lane->pending.number != r->number) {
            c->snapshot.flags |= XRT_FDEVENT_BAD_RECORD;
            add(c, &c->snapshot.invalid, 1);
            unpaired(c, lane);
        } else {
            complete(c, &lane->pending, r->result);
            lane->has_pending = 0;
        }
        break;
    case XRT_FDEVENT_LOST:
        c->snapshot.flags |= XRT_FDEVENT_LOSS;
        add(c, &c->record_lost[index], r->lost);
        loss_total(c);
        unpaired(c, lane);
        break;
    case XRT_FDEVENT_THROTTLE:
        c->snapshot.flags |= XRT_FDEVENT_THROTTLED;
        unpaired(c, lane);
        break;
    case XRT_FDEVENT_EXEC:
    case XRT_FDEVENT_TASK_EXIT:
        c->snapshot.flags |= XRT_FDEVENT_SCOPE_CHANGED;
        unpaired(c, lane);
        lane->closed = 1;
        break;
    case XRT_FDEVENT_FORK:
        c->snapshot.flags |= XRT_FDEVENT_SCOPE_CHANGED;
        break;
    case XRT_FDEVENT_IGNORE:
        break;
    }
}
