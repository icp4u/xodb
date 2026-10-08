#include "../src/runtime/fdevent_internal.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint64_t now = 1;
static void pair(struct fd_event_counter *c, size_t lane, int64_t nr, uint64_t fd, int64_t result)
{
    struct xrt_fdevent_record e = {
        .kind = XRT_FDEVENT_ENTER, .number = nr, .time_ns = now++, .args = {fd, 0, 0, 0, 0, 0}};
    fd_event_counter_feed(c, lane, &e);
    e.kind = XRT_FDEVENT_EXIT;
    e.result = result;
    e.time_ns = now++;
    fd_event_counter_feed(c, lane, &e);
}
static struct xrt_fdevent_row *find(struct fd_event_counter *c, int fd)
{
    for (uint32_t i = 0; i < c->snapshot.row_count; ++i)
        if (c->rows[i].fd == fd)
            return &c->rows[i];
    return NULL;
}
static void transfer(struct fd_event_counter *c, int64_t nr, uint64_t first, uint64_t second,
                     uint64_t third, int64_t amount)
{
    struct xrt_fdevent_record e = {
        .kind = XRT_FDEVENT_ENTER, .number = nr, .time_ns = now++, .args = {first, second, third}};
    fd_event_counter_feed(c, 0, &e);
    e.kind = XRT_FDEVENT_EXIT;
    e.time_ns = now++;
    e.result = amount;
    fd_event_counter_feed(c, 0, &e);
}
static void transfer_families(void)
{
    struct fd_event_counter c;
    assert(fd_event_counter_init(&c, 16));
    /* sendfile(out,in,...), splice/copy_file_range(in,offset,out,...),
     * tee(in,out,...): each return accounts once on each endpoint. */
    transfer(&c, 40, 4, 3, 0, 5);
    transfer(&c, 275, 3, 0, 4, 7);
    transfer(&c, 326, 3, 0, 4, 11);
    transfer(&c, 276, 3, 4, 0, 13);
    assert(find(&c, 3)->read_bytes == 36 && find(&c, 3)->write_bytes == 0);
    assert(find(&c, 4)->write_bytes == 36 && find(&c, 4)->read_bytes == 0);
    assert(c.snapshot.read_bytes == 36 && c.snapshot.write_bytes == 36);
    /* fd arguments use signed low 32 bits, as the native kernel ABI does. */
    pair(&c, 1, 327, UINT64_C(0x123400000003), 17);
    pair(&c, 1, 328, 4, 19);
    assert(find(&c, 3)->read_bytes == 53 && find(&c, 4)->write_bytes == 55);
    transfer(&c, 33, 3, 3, 0, 3); /* dup2(fd,fd) creates no descriptor. */
    assert(c.snapshot.dup_returns == 0);
    transfer(&c, 33, 3, 4, 0, 4);
    transfer(&c, 72, 3, 1030, 0, 5); /* F_DUPFD_CLOEXEC */
    assert(c.snapshot.dup_returns == 2 && c.snapshot.close_successes == 0);
    assert(find(&c, 4)->dup_returns == 1 && find(&c, 5)->dup_returns == 1);
    pair(&c, 1, 22, 0, 0); /* pipe result is an array pointer, not an fd. */
    assert(c.snapshot.open_returns == 2 && find(&c, 0) == NULL);
    assert(c.snapshot.flags == XRT_FDEVENT_UNSUPPORTED);
    transfer(&c, 299, 3, 0, 0, 8); /* message count must not become bytes. */
    transfer(&c, 307, 4, 0, 0, 8);
    transfer(&c, 436, 3, 100, 0, 0); /* range closes are not fabricated. */
    assert(c.snapshot.read_bytes == 53 && c.snapshot.write_bytes == 55 &&
           c.snapshot.close_successes == 0);
    fd_event_counter_destroy(&c);
}
static void loss_reads(void)
{
    struct fd_event_counter c;
    assert(fd_event_counter_init(&c, 4));
    struct xrt_fdevent_record event = {.kind = XRT_FDEVENT_ENTER, .number = 1, .time_ns = now++, .args = {3}};
    fd_event_counter_feed(&c, 0, &event);
    assert(c.lane[0].has_pending);
    fd_event_counter_loss(&c, 0, 5, 1, 0);
    assert(!c.lane[0].has_pending && c.snapshot.lost == 5 && (c.snapshot.flags & XRT_FDEVENT_LOSS));
    event = (struct xrt_fdevent_record){.kind = XRT_FDEVENT_LOST, .lost = 3};
    fd_event_counter_feed(&c, 0, &event);
    assert(c.snapshot.lost == 5); /* delayed record must not double-count */
    event.lost = 2; fd_event_counter_feed(&c, 0, &event);
    assert(c.snapshot.lost == 5);
    fd_event_counter_loss(&c, 1, 7, 1, 0);
    assert(c.snapshot.lost == 12); /* independent rings add */
    event.lost = 4; fd_event_counter_feed(&c, 0, &event);
    assert(c.snapshot.lost == 16); /* record can precede the next read */
    fd_event_counter_loss(&c, 0, 9, 1, 0);
    assert(c.snapshot.lost == 16);
    fd_event_counter_loss(&c, 0, 8, 1, 0);
    assert(c.snapshot.lost == 16 && (c.snapshot.flags & XRT_FDEVENT_LOSS_UNAVAILABLE));
    fd_event_counter_loss(&c, 1, 0, 0, 1);
    assert(c.snapshot.lost == 16 && (c.snapshot.flags & XRT_FDEVENT_POSSIBLE_LOSS));
    fd_event_counter_loss(&c, 2, UINT64_MAX, 1, 0);
    assert(c.snapshot.lost == UINT64_MAX && (c.snapshot.flags & XRT_FDEVENT_SATURATED));
    fd_event_counter_destroy(&c);
}

int main(void)
{
    loss_reads();
    transfer_families();
    struct fd_event_counter c;
    assert(fd_event_counter_init(&c, 4));
    pair(&c, 0, 257, 99, 3);
    pair(&c, 0, 1, 3, 13);
    pair(&c, 0, 1, 3, -9);
    pair(&c, 0, 0, 3, 7);
    pair(&c, 0, 3, 3, 0);
    pair(&c, 0, 257, 99, 3);
    pair(&c, 1, 18, 3, 19);
    pair(&c, 1, 17, 3, 0);
    const struct xrt_fdevent_row *r = find(&c, 3);
    assert(r);
    assert(r->open_returns == 2 && r->close_successes == 1 && r->write_bytes == 32 &&
           r->read_bytes == 7);
    assert(r->write_calls == 2 && r->read_calls == 2 && c.snapshot.flags == 0);
    pair(&c, 0, 32, 3, 4);
    assert(find(&c, 4)->dup_returns == 1);
    assert(c.snapshot.open_returns == 2 && c.snapshot.dup_returns == 1);
    /* A syscall lost between entry/exit must never yield invented bytes. */
    struct xrt_fdevent_record e = {
        .kind = XRT_FDEVENT_ENTER, .number = 1, .time_ns = now++, .args = {3}};
    fd_event_counter_feed(&c, 0, &e);
    e.kind = XRT_FDEVENT_LOST;
    e.lost = 9;
    e.time_ns = now++;
    fd_event_counter_feed(&c, 0, &e);
    e.kind = XRT_FDEVENT_EXIT;
    e.result = 100;
    e.time_ns = now++;
    fd_event_counter_feed(&c, 0, &e);
    assert(c.snapshot.write_bytes == 32 && c.snapshot.lost == 9 && c.snapshot.unpaired == 2);
    assert((c.snapshot.flags & (XRT_FDEVENT_LOSS | XRT_FDEVENT_UNPAIRED)) ==
           (XRT_FDEVENT_LOSS | XRT_FDEVENT_UNPAIRED));
    /* Exact global bytes remain available when the bounded per-fd table fills. */
    pair(&c, 1, 1, 5, 10);
    pair(&c, 1, 1, 6, 20);
    pair(&c, 1, 1, 7, 30);
    assert(c.snapshot.row_count == 4 && c.snapshot.dropped_rows == 1);
    assert(c.snapshot.write_bytes == 92 && (c.snapshot.flags & XRT_FDEVENT_ROW_LIMIT));
    /* Unrelated syscalls and errors do not become byte traffic. */
    pair(&c, 2, 39, 0, 999);
    pair(&c, 2, 1, 3, -512);
    assert(c.snapshot.write_bytes == 92);
    /* A different syscall number cannot complete a pending IO operation. */
    e = (struct xrt_fdevent_record){
        .kind = XRT_FDEVENT_ENTER, .number = 0, .time_ns = now++, .args = {3}};
    fd_event_counter_feed(&c, 2, &e);
    e.kind = XRT_FDEVENT_EXIT;
    e.number = 1;
    e.result = 300;
    e.time_ns = now++;
    fd_event_counter_feed(&c, 2, &e);
    assert(c.snapshot.invalid == 1 && c.snapshot.write_bytes == 92);
    /* No counters from a lane after exec are associated with the old capture. */
    e = (struct xrt_fdevent_record){.kind = XRT_FDEVENT_EXEC, .time_ns = now++};
    fd_event_counter_feed(&c, 2, &e);
    pair(&c, 2, 1, 3, 1000);
    assert(c.snapshot.write_bytes == 92);
    /* Loss remains counted when its trailer timestamp is older. */
    e = (struct xrt_fdevent_record){.kind = XRT_FDEVENT_LOST, .time_ns = 1, .lost = 4};
    fd_event_counter_feed(&c, 1, &e);
    assert(c.snapshot.lost == 13);
    /* Saturation is explicit, never wraparound. */
    c.snapshot.write_bytes = UINT64_MAX - 2;
    pair(&c, 1, 1, 3, 3);
    assert(c.snapshot.write_bytes == UINT64_MAX && (c.snapshot.flags & XRT_FDEVENT_SATURATED));
    fd_event_counter_destroy(&c);
    assert(!c.rows && !c.table);
    assert(!fd_event_counter_init(&c, 0));
    assert(!fd_event_counter_init(&c, 65537));
    puts("fd event counters: successful short IO/errors, reopen, multiple lanes, loss, pairing, "
         "exec, limits and saturation pass");
    return 0;
}
