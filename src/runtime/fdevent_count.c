#include "fdevent_internal.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* Native x86-64 syscall ABI, independent of the build host. */
enum {
    X64_read = 0,
    X64_write = 1,
    X64_open = 2,
    X64_close = 3,
    X64_pread64 = 17,
    X64_pwrite64 = 18,
    X64_readv = 19,
    X64_writev = 20,
    X64_pipe = 22,
    X64_dup = 32,
    X64_dup2 = 33,
    X64_sendfile = 40,
    X64_socket = 41,
    X64_accept = 43,
    X64_sendto = 44,
    X64_recvfrom = 45,
    X64_sendmsg = 46,
    X64_recvmsg = 47,
    X64_socketpair = 53,
    X64_fcntl = 72,
    X64_creat = 85,
    X64_epoll_create = 213,
    X64_inotify_init = 253,
    X64_openat = 257,
    X64_splice = 275,
    X64_tee = 276,
    X64_vmsplice = 278,
    X64_signalfd = 282,
    X64_timerfd_create = 283,
    X64_eventfd = 284,
    X64_accept4 = 288,
    X64_signalfd4 = 289,
    X64_eventfd2 = 290,
    X64_epoll_create1 = 291,
    X64_dup3 = 292,
    X64_pipe2 = 293,
    X64_inotify_init1 = 294,
    X64_preadv = 295,
    X64_pwritev = 296,
    X64_recvmmsg = 299,
    X64_sendmmsg = 307,
    X64_memfd_create = 319,
    X64_userfaultfd = 323,
    X64_copy_file_range = 326,
    X64_preadv2 = 327,
    X64_pwritev2 = 328,
    X64_io_uring_setup = 425,
    X64_io_uring_enter = 426,
    X64_pidfd_open = 434,
    X64_close_range = 436,
    X64_openat2 = 437,
};

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
    case X64_read:
    case X64_write:
    case X64_open:
    case X64_close:
    case X64_pread64:
    case X64_pwrite64:
    case X64_readv:
    case X64_writev:
    case X64_pipe:
    case X64_dup:
    case X64_dup2:
    case X64_sendfile:
    case X64_socket:
    case X64_accept:
    case X64_sendto:
    case X64_recvfrom:
    case X64_sendmsg:
    case X64_recvmsg:
    case X64_socketpair:
    case X64_fcntl:
    case X64_creat:
    case X64_epoll_create:
    case X64_inotify_init:
    case X64_openat:
    case X64_splice:
    case X64_tee:
    case X64_vmsplice:
    case X64_signalfd:
    case X64_timerfd_create:
    case X64_eventfd:
    case X64_accept4:
    case X64_signalfd4:
    case X64_eventfd2:
    case X64_epoll_create1:
    case X64_dup3:
    case X64_pipe2:
    case X64_inotify_init1:
    case X64_preadv:
    case X64_pwritev:
    case X64_recvmmsg:
    case X64_sendmmsg:
    case X64_memfd_create:
    case X64_userfaultfd:
    case X64_copy_file_range:
    case X64_preadv2:
    case X64_pwritev2:
    case X64_io_uring_setup:
    case X64_io_uring_enter:
    case X64_pidfd_open:
    case X64_close_range:
    case X64_openat2:
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
    case X64_read:
    case X64_pread64:
    case X64_readv:
    case X64_recvfrom:
    case X64_recvmsg:
    case X64_preadv:
    case X64_preadv2:
        bytes(c, a[0], n, 0);
        break;
    case X64_write:
    case X64_pwrite64:
    case X64_writev:
    case X64_sendto:
    case X64_sendmsg:
    case X64_vmsplice:
    case X64_pwritev:
    case X64_pwritev2:
        bytes(c, a[0], n, 1);
        break;
    case X64_sendfile:
        bytes(c, a[1], n, 0);
        bytes(c, a[0], n, 1);
        break; /* sendfile */
    case X64_splice:
    case X64_copy_file_range:
        bytes(c, a[0], n, 0);
        bytes(c, a[2], n, 1);
        break; /* splice/copy_file_range */
    case X64_tee:
        bytes(c, a[0], n, 0);
        bytes(c, a[1], n, 1);
        break; /* tee: successful transferred bytes */
    case X64_open:
    case X64_socket:
    case X64_accept:
    case X64_creat:
    case X64_epoll_create:
    case X64_inotify_init:
    case X64_openat:
    case X64_timerfd_create:
    case X64_eventfd:
    case X64_accept4:
    case X64_eventfd2:
    case X64_epoll_create1:
    case X64_inotify_init1:
    case X64_memfd_create:
    case X64_userfaultfd:
    case X64_io_uring_setup:
    case X64_pidfd_open:
    case X64_openat2:
        opened(c, result, 0);
        break;
    case X64_signalfd:
    case X64_signalfd4:
        if ((int32_t)(uint32_t)a[0] == -1)
            opened(c, result, 0);
        break;
    case X64_dup:
        opened(c, result, 1);
        break;
    case X64_dup2:
    case X64_dup3:
        if ((int32_t)(uint32_t)a[0] != (int32_t)(uint32_t)a[1])
            opened(c, result, 1);
        break; /* A successful replacement's implicit close is not inferred. */
    case X64_fcntl:
        if (a[1] == 0 || a[1] == 1030)
            opened(c, result, 1);
        break; /* F_DUPFD/_CLOEXEC */
    case X64_close: {
        struct xrt_fdevent_row *r = row(c, a[0]);
        add(c, &c->snapshot.close_successes, 1);
        if (r)
            add(c, &r->close_successes, 1);
        break;
    }
    case X64_pipe:
    case X64_socketpair:
    case X64_pipe2:
        /* Two descriptors were created; their numbers live in user memory.
         * Keep the global count and flag incomplete per-fd attribution. */
        add(c, &c->snapshot.open_returns, 2);
        c->snapshot.flags |= XRT_FDEVENT_UNSUPPORTED;
        break;
    case X64_recvmmsg:
    case X64_sendmmsg:
    case X64_io_uring_enter:
    case X64_close_range:
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
