#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdflow_count.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int wrong_oracle;

static uint64_t clock_ns = 1000, sequence = 0;
static struct xrt_fdflow_counts counts(struct xrt_fdflow_counter *c) {
    struct xrt_fdflow_counts v = {0};
    xrt_fdflow_counter_view(c, &v);
    return v;
}
static struct xrt_fdflow_counter *create(unsigned rows, unsigned threads, unsigned processes) {
    struct xrt_fdflow_counter *c = NULL;
    CHECK(xrt_fdflow_counter_create(rows, threads, processes, &c) == XRT_OK);
    return c;
}
static void bind(struct xrt_fdflow_counter *c, uint64_t inode, uint64_t start, uint32_t flags) {
    struct xrt_fd f = {
        .fd = 7, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 2, .inode = inode};
    struct xrt_fd_process p = {.pid = 100, .start = start, .first = 0, .count = 1, .flags = flags};
    struct xrt_fd_snapshot s = {.sequence = ++sequence,
                                .taken_ns = clock_ns,
                                .scan_ns = 10,
                                .processes = &p,
                                .process_count = 1,
                                .fds = &f,
                                .fd_count = 1};
    struct xrt_fdflow_bindings *b = NULL;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK);
    CHECK(xrt_fdflow_counter_bind(c, b) == XRT_OK);
    clock_ns += 20;
}
static void feed(struct xrt_fdflow_counter *c, struct xrt_fdflow_record *r, uint32_t n,
                 uint64_t lost, uint32_t flags) {
    struct xrt_fdflow_snapshot s = {
        .records = r, .record_count = n, .taken_ns = clock_ns + 1, .lost = lost, .flags = flags};
    CHECK(xrt_fdflow_counter_feed(c, &s) == XRT_OK);
    clock_ns += 2;
}
static struct xrt_fdflow_record enter(int32_t tid, int64_t number, int fd) {
    return (struct xrt_fdflow_record){.pid = 100,
                                      .tid = tid,
                                      .kind = XRT_FDFLOW_ENTER,
                                      .operation = XRT_FDFLOW_RAW,
                                      .time_ns = ++clock_ns,
                                      .number = number,
                                      .args = {(uint64_t)fd}};
}
static struct xrt_fdflow_record finish(int32_t tid, int64_t number, uint32_t op, int64_t n) {
    return (struct xrt_fdflow_record){.pid = 100,
                                      .tid = tid,
                                      .kind = XRT_FDFLOW_EXIT,
                                      .operation = op,
                                      .time_ns = ++clock_ns,
                                      .number = number,
                                      .result = n};
}
static void call(struct xrt_fdflow_counter *c, int32_t tid, int64_t number, uint32_t op,
                 int64_t n) {
    struct xrt_fdflow_record r[3];
    r[0] = enter(tid, number, 7);
    r[0].cpu = 1;
    r[1] = finish(tid, number, XRT_FDFLOW_RAW, n);
    r[1].cpu = 9;
    r[2] = finish(tid, number, op, n);
    r[2].cpu = 9;
    feed(c, r, 3, 0, 0);
}
static void basic(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 17);
    call(c, 100, 0, XRT_FDFLOW_READ, 11);
    call(c, 100, 1, XRT_FDFLOW_WRITE, -9);
    struct xrt_fdflow_counts v = counts(c);
    CHECK(v.row_count == 1 && v.rows[0].inode == 101 && v.write_bytes == 17 && v.read_bytes == 11);
    CHECK(v.rows[0].write_bytes == 17 && v.rows[0].read_bytes == 11 && v.rows[0].calls == 2);
    CHECK(!v.unknown_read && !v.unknown_write && v.failed_calls == 1);
    uint64_t actual_written = v.rows[0].write_bytes;
    /* Raw number20 may be compat getpid: raw returns are never byte evidence. */
    struct xrt_fdflow_record r[2] = {enter(100, 20, 7), finish(100, 20, XRT_FDFLOW_RAW, 100)};
    feed(c, r, 2, 0, 0);
    CHECK(counts(c).write_bytes == 17);
    /* A named return without an entry still has known bytes, unknown fd. */
    r[0] = finish(200, 1, XRT_FDFLOW_WRITE, 9);
    feed(c, r, 1, 0, 0);
    CHECK(counts(c).write_bytes == 26 && counts(c).unknown_write == 9 && counts(c).unpaired == 1);
    feed(c, r, 1, 0, 0);
    CHECK(counts(c).write_bytes == 26 && counts(c).duplicates == 1);
    xrt_fdflow_counter_free(c);
    CHECK(actual_written == (wrong_oracle ? 18u : 17u));
}
static void reuse(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 17);
    struct xrt_fdflow_record r[2] = {enter(101, 3, 7), finish(101, 3, XRT_FDFLOW_RAW, 0)};
    feed(c, r, 2, 0, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 3);
    CHECK(counts(c).unknown_write == 3);
    bind(c, 202, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 5);
    /* The replaced descriptor's row is dropped at bind; totals keep its bytes. */
    struct xrt_fdflow_counts v = counts(c);
    CHECK(v.row_count == 1 && v.write_bytes == 25);
    CHECK(v.rows[0].inode == 202 && v.rows[0].write_bytes == 5 && v.rows[0].active);
    uint64_t serial = v.rows[0].serial;
    bind(c, 202, 2, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 7);
    v = counts(c);
    CHECK(v.row_count == 1 && v.rows[0].start == 2 && v.rows[0].write_bytes == 7 &&
          v.rows[0].serial > serial);
    xrt_fdflow_counter_free(c);
}
static void concurrent_mutation(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    struct xrt_fdflow_record r = enter(100, 1, 7);
    feed(c, &r, 1, 0, 0);
    r = enter(101, 3, 7);
    feed(c, &r, 1, 0, 0);
    r = finish(100, 1, XRT_FDFLOW_WRITE, 17);
    feed(c, &r, 1, 0, 0);
    CHECK(counts(c).unknown_write == 17);
    /* A poll while close is in flight cannot restore an association. */
    bind(c, 101, 1, 0);
    call(c, 102, 1, XRT_FDFLOW_WRITE, 7);
    CHECK(counts(c).unknown_write == 24);
    r = finish(101, 3, XRT_FDFLOW_RAW, 0);
    feed(c, &r, 1, 0, 0);
    call(c, 102, 1, XRT_FDFLOW_WRITE, 3);
    CHECK(counts(c).unknown_write == 27);
    bind(c, 202, 1, 0);
    call(c, 102, 1, XRT_FDFLOW_WRITE, 5);
    CHECK(counts(c).unknown_write == 27 && counts(c).write_bytes == 32);
    /* Poll changes identity while a write is in flight: keep its bytes unknown.
     */
    r = enter(102, 1, 7);
    feed(c, &r, 1, 0, 0);
    bind(c, 303, 1, 0);
    r = finish(102, 1, XRT_FDFLOW_WRITE, 11);
    feed(c, &r, 1, 0, 0);
    CHECK(counts(c).unknown_write == 38);
    xrt_fdflow_counter_free(c);
}
static void clocks_and_loss(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    struct xrt_fdflow_record r[2] = {enter(100, 1, 7), finish(100, 1, XRT_FDFLOW_WRITE, 17)};
    r[0].time_ns = 1;
    feed(c, r, 2, 0, 0);
    CHECK(counts(c).unknown_write == 17);
    bind(c, 101, 1, XRT_FDP_STALE);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 3);
    CHECK(counts(c).unknown_write == 20);
    bind(c, 101, 1, 0);
    r[0] = enter(100, 1, 7);
    feed(c, r, 1, 0, 0);
    feed(c, NULL, 0, 9, XRT_FDFLOW_LOSS);
    r[0] = finish(100, 1, XRT_FDFLOW_WRITE, 5);
    feed(c, r, 1, 9, XRT_FDFLOW_LOSS);
    CHECK(counts(c).unknown_write == 25 && (counts(c).flags & XRT_FDFLOW_COUNT_INCOMPLETE));
    bind(c, 101, 1, 0);
    r[0] = enter(100, 1, 7);
    r[1] = finish(100, 1, XRT_FDFLOW_WRITE, 7);
    feed(c, r, 2, 9, XRT_FDFLOW_LOSS);
    CHECK(counts(c).unknown_write == 25 && counts(c).write_bytes == 32);
    r[0] = enter(100, 1, 7);
    r[1] = finish(100, 1, XRT_FDFLOW_WRITE, 11);
    feed(c, r, 2, 9, XRT_FDFLOW_CPU_PARTIAL);
    CHECK(counts(c).unknown_write == 36);
    xrt_fdflow_counter_free(c);
}
static void mutation_windows(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 1);
    uint64_t began = clock_ns;
    struct xrt_fdflow_record r[2] = {enter(101, 3, 7), finish(101, 3, XRT_FDFLOW_RAW, 0)};
    feed(c, r, 2, 0, 0);
    struct xrt_fd f = {
        .fd = 7, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 2, .inode = 101};
    struct xrt_fd_process p = {.pid = 100, .start = 1, .count = 1};
    struct xrt_fd_snapshot s = {.sequence = ++sequence,
                                .taken_ns = began,
                                .scan_ns = clock_ns - began,
                                .processes = &p,
                                .process_count = 1,
                                .fds = &f,
                                .fd_count = 1};
    struct xrt_fdflow_bindings *b = NULL;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK);
    CHECK(xrt_fdflow_counter_bind(c, b) == XRT_OK);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 3);
    CHECK(counts(c).unknown_write == 3); /* poll crossed a close window */
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 5);
    CHECK(counts(c).unknown_write == 3);
    r[0] = enter(101, 426, 7);
    r[1] = finish(101, 426, XRT_FDFLOW_RAW, 0);
    feed(c, r, 2, 0, 0);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 7);
    CHECK(counts(c).unknown_write == 10); /* async close may finish after return */
    bind(c, 202, 2, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 11);
    CHECK(counts(c).unknown_write == 10); /* new PID start is a new process */
    r[0] = enter(100, 1, 7);
    r[1] = finish(100, 1, XRT_FDFLOW_WRITE, 13);
    feed(c, r, 2, 0, XRT_FDFLOW_THROTTLE);
    CHECK(counts(c).unknown_write == 23);
    xrt_fdflow_counter_free(c);
}
static void bounds(void) {
    struct xrt_fdflow_counter *c = create(1, 1, 1);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 17);
    /* A replaced descriptor frees its row: one row serves any number of binds. */
    bind(c, 202, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 3);
    CHECK(counts(c).row_count == 1 && !counts(c).unknown_write && !counts(c).flags);
    /* A finished call frees its thread under pressure. */
    call(c, 101, 1, XRT_FDFLOW_WRITE, 5);
    CHECK(!counts(c).unknown_write && counts(c).thread_count == 1 && !counts(c).flags);
    /* A thread inside close pins its slot: the next thread is capped, and its
     * untracked call withdraws every join instead of guessing. */
    struct xrt_fdflow_record r = enter(101, 3, 7);
    feed(c, &r, 1, 0, 0);
    call(c, 102, 1, XRT_FDFLOW_WRITE, 7);
    CHECK(counts(c).unknown_write == 7 && counts(c).thread_count == 1 &&
          (counts(c).flags & XRT_FDFLOW_COUNT_CAP) && (counts(c).flags & XRT_FDFLOW_COUNT_INCOMPLETE));
    xrt_fdflow_counter_free(c);
    c = create(128, 128, 128);
    bind(c, 101, 1, 0);
    for (int i = 1; i <= 100; ++i)
        call(c, 100 + i, 1, XRT_FDFLOW_WRITE, 1);
    CHECK(counts(c).thread_count == 100 && counts(c).write_bytes == 100 &&
          !counts(c).unknown_write);
    xrt_fdflow_counter_free(c);
}
/* Native numbers that compat tables use for open/close/creat/execve/dup2/
 * socketcall must not withdraw joins; preadv/pwritev are IO, not mutations. */
static void native_numbers(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    static const int64_t harmless[] = {5 /* fstat */, 8 /* lseek */, 11 /* munmap */,
                                       63 /* uname */, 102 /* getuid */};
    for (unsigned i = 0; i < sizeof harmless / sizeof *harmless; ++i) {
        struct xrt_fdflow_record r[2] = {enter(101, harmless[i], 7),
                                         finish(101, harmless[i], XRT_FDFLOW_RAW, 0)};
        feed(c, r, 2, 0, 0);
        call(c, 100, 1, XRT_FDFLOW_WRITE, 1);
    }
    call(c, 100, 295, XRT_FDFLOW_READ, 9);  /* preadv */
    call(c, 100, 296, XRT_FDFLOW_WRITE, 4); /* pwritev */
    struct xrt_fdflow_counts v = counts(c);
    CHECK(!v.unknown_read && !v.unknown_write && !v.invalidated && v.row_count == 1);
    CHECK(v.rows[0].write_bytes == 9 && v.rows[0].read_bytes == 9 && v.rows[0].calls == 7);
    struct xrt_fdflow_record r[2] = {enter(101, 3, 7), finish(101, 3, XRT_FDFLOW_RAW, 0)};
    feed(c, r, 2, 0, 0); /* native close still withdraws them */
    call(c, 100, 1, XRT_FDFLOW_WRITE, 2);
    CHECK(counts(c).unknown_write == 2);
    xrt_fdflow_counter_free(c);
}
/* Forgetting a process mid-window must keep its later IO unknown, not known. */
static void eviction(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 1);
    bind(c, 101, 1, 0);
    struct xrt_fdflow_record r[2] = {enter(101, 3, 7), finish(101, 3, XRT_FDFLOW_RAW, 0)};
    feed(c, r, 2, 0, 0); /* close after the poll began */
    r[0] = enter(300, 39, 0);
    r[0].pid = 300; /* another pid evicts 100 from the one-entry table */
    feed(c, r, 1, 0, 0);
    CHECK(counts(c).process_count == 1 && !(counts(c).flags & XRT_FDFLOW_COUNT_CAP));
    call(c, 100, 1, XRT_FDFLOW_WRITE, 5);
    CHECK(counts(c).unknown_write == 5 && counts(c).write_bytes == 5);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 6);
    CHECK(counts(c).unknown_write == 5 && counts(c).rows[0].write_bytes == 6);
    /* A bind keeps the live set and drops the rest. */
    r[0] = enter(301, 39, 0);
    r[0].pid = 301;
    feed(c, r, 1, 0, 0);
    bind(c, 101, 1, 0);
    CHECK(counts(c).process_count <= 1 && counts(c).thread_count <= 1);
    xrt_fdflow_counter_free(c);
}
/* A reused pid whose new process used io_uring before the poll that revealed
 * it stays unproved: async descriptor changes may land after the scan. */
static void reuse_async(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    bind(c, 101, 1, 0);
    call(c, 100, 1, XRT_FDFLOW_WRITE, 3); /* old process joins: start 1 */
    struct xrt_fdflow_record r[2] = {enter(100, 425, 0), finish(100, 425, XRT_FDFLOW_RAW, 0)};
    feed(c, r, 2, 0, 0);                  /* the new process: io_uring_setup */
    bind(c, 202, 2, 0);                   /* the poll sees start 2 */
    call(c, 100, 1, XRT_FDFLOW_WRITE, 5);
    CHECK(counts(c).unknown_write == 5 + (wrong_oracle ? 1u : 0u));
    xrt_fdflow_counter_free(c);
}
/* A call pending across a bind that compacts rows keeps its own row. */
static void compaction_pending(void) {
    struct xrt_fdflow_counter *c = create(16, 16, 16);
    struct xrt_fd f[2] = {
        {.fd = 7, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 2, .inode = 101},
        {.fd = 6, .kind = XRT_FD_REGULAR, .flags = XRT_FD_STAT, .device = 2, .inode = 50}};
    struct xrt_fd_process p[2] = {{.pid = 100, .start = 1, .first = 0, .count = 1},
                                  {.pid = 200, .start = 2, .first = 1, .count = 1}};
    struct xrt_fd_snapshot s = {.sequence = ++sequence, .taken_ns = clock_ns, .scan_ns = 10,
                                .processes = p, .process_count = 2, .fds = f, .fd_count = 2};
    struct xrt_fdflow_bindings *b = NULL;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK && xrt_fdflow_counter_bind(c, b) == XRT_OK);
    clock_ns += 20;
    struct xrt_fdflow_record r[3] = {enter(200, 1, 6), finish(200, 1, XRT_FDFLOW_RAW, 3),
                                     finish(200, 1, XRT_FDFLOW_WRITE, 3)};
    for (int i = 0; i < 3; ++i)
        r[i].pid = 200;
    feed(c, r, 3, 0, 0);                    /* row 0: pid 200 fd 6 */
    r[0] = enter(100, 1, 7);
    feed(c, r, 1, 0, 0);                    /* pid 100 enters write(7): row 1 */
    CHECK(counts(c).row_count == 2 && counts(c).rows[1].pid == 100);
    s.sequence = ++sequence, s.taken_ns = clock_ns, s.process_count = 1, s.fd_count = 1;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_OK && xrt_fdflow_counter_bind(c, b) == XRT_OK);
    clock_ns += 20;                         /* pid 200 gone: its row is dropped */
    r[0] = finish(100, 1, XRT_FDFLOW_RAW, 5);
    r[1] = finish(100, 1, XRT_FDFLOW_WRITE, 5);
    feed(c, r, 2, 0, 0);
    struct xrt_fdflow_counts v = counts(c);
    CHECK(v.row_count == 1 && v.rows[0].pid == 100 && v.rows[0].fd == 7);
    CHECK(v.rows[0].write_bytes == 5 + (wrong_oracle ? 1u : 0u) && !v.unknown_write);
    xrt_fdflow_counter_free(c);
}
static void hostile_bindings(void) {
    struct xrt_fdflow_bindings *b = NULL;
    struct xrt_fd_snapshot s = {.taken_ns = 1, .scan_ns = UINT64_MAX};
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_INVALID_ARGUMENT && !b);
    s.scan_ns = 0;
    s.process_count = 1;
    CHECK(xrt_fdflow_bindings_create(&s, &b) == XRT_INVALID_ARGUMENT);
    struct xrt_fdflow_counter *c = NULL;
    CHECK(xrt_fdflow_counter_create(0, 1, 1, &c) == XRT_INVALID_ARGUMENT && !c);
}
int main(int argc, char **argv) {
    wrong_oracle = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    basic();
    reuse();
    concurrent_mutation();
    clocks_and_loss();
    mutation_windows();
    bounds();
    native_numbers();
    eviction();
    reuse_async();
    compaction_pending();
    hostile_bindings();

    puts("sampled IO identity: native returns, reuse, clocks, mutation, loss and "
         "limits PASS");
    return 0;
}
