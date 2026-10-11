#define _GNU_SOURCE 1
#include "xrt_wire.h"
#include "gdb_link.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

/* The test build redirects only wire.c's read and gdb_link.c's recv here.
 * Stop after the final bytes were received but before the decoder can accept
 * them, so cancellation wins deterministically instead of relying on timing. */
static int held_fd = -1, held_notice[2], held_release[2];
static void after_read(int fd, ssize_t n, bool final)
{
    if (fd != held_fd || n <= 0 || !final) return;
    assert(write(held_notice[1], "!", 1) == 1);
    char byte; assert(read(held_release[0], &byte, 1) == 1);
}
ssize_t xrt_test_read(int fd, void *bytes, size_t size)
{
    ssize_t n = read(fd, bytes, size);
    after_read(fd, n, size == 4);
    return n;
}
ssize_t xrt_test_recv(int fd, void *bytes, size_t size, int flags)
{
    ssize_t n = recv(fd, bytes, size, flags);
    after_read(fd, n, true);
    return n;
}

/* Fast component lane. The peer never releases its held bytes: the test first
 * observes the reader inside poll, then cancels, then requires its completion.
 * Looking at our own thread's syscall makes disabling the wake a reliable
 * negative control, rather than racing cancellation against entry to poll. */
struct task {
    struct xrt_cancel *cancel;
    int fd, done[2], mode;
    atomic_int tid;
    int result;
    size_t written;
};
static void *operation(void *opaque)
{
    struct task *t = opaque;
    atomic_store(&t->tid, (int)syscall(SYS_gettid));
    struct xrt_wire_frame f = {.request = 1, .op = 1, .size = 4};
    uint8_t body[16];
    if (t->mode < 3)
        t->result = xrt_wire_read_cancel(t->fd, &f, body, sizeof(body), 30000, t->cancel);
    else if (t->mode == 3)
        t->result = xrt_wire_write_cancel(t->fd, &f, "body", 30000, t->cancel, &t->written);
    else if (t->mode == 6) {
        f.size = XRT_WIRE_MAX_BODY;
        char *large = calloc(1, f.size); assert(large);
        t->result = xrt_wire_write_cancel(t->fd, &f, large, 30000, t->cancel, &t->written);
        free(large);
    } else {
        struct xrt_gdb_link *l = calloc(1, sizeof(*l)); assert(l);
        *l = (struct xrt_gdb_link){.fd = t->fd, .cancel = t->cancel, .packet_size = 1024, .noack = true};
        size_t size;
        t->result = t->mode == 4 ? xrt_gdb_receive(l, body, sizeof(body), &size, true) :
            xrt_gdb_send(l, "qC", 2);
        assert(l->fd == -1 && l->failed);
        free(l);
        t->fd = -1;
    }
    assert(write(t->done[1], "!", 1) == 1);
    return NULL;
}
static void in_poll(struct task *t)
{
    for (;;) {
        int tid = atomic_load(&t->tid);
        if (tid) {
            char path[96], line[256];
            snprintf(path, sizeof(path), "/proc/self/task/%d/syscall", tid);
            int fd = open(path, O_RDONLY | O_CLOEXEC); assert(fd >= 0);
            ssize_t n = read(fd, line, sizeof(line) - 1); close(fd);
            assert(n > 0); line[n] = 0;
            char *end;
            long number = strtol(line, &end, 10);
            if (end != line && number == SYS_poll) return;
        }
        struct pollfd done = {.fd = t->done[0], .events = POLLIN};
        assert(poll(&done, 1, 0) == 0);
        sched_yield();
    }
}
static void fill(int fd)
{
    char bytes[4096] = {0};
    for (;;) {
        ssize_t n = send(fd, bytes, sizeof(bytes), MSG_NOSIGNAL);
        if (n > 0) continue;
        assert(n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
        return;
    }
}
static void waits(void)
{
    struct xrt_cancel *cancel = xrt_cancel_create(); assert(cancel);
    enum { count = 7 };
    struct task task[count] = {0};
    pthread_t threads[count];
    int peer[count];
    for (int mode = 0; mode < count; ++mode) {
        struct task *t = &task[mode];
        int pair[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, pair));
        t->fd = pair[0]; peer[mode] = pair[1]; t->mode = mode;
        atomic_init(&t->tid, 0);
        t->cancel = xrt_cancel_retain(cancel);
        assert(!pipe2(t->done, O_CLOEXEC));
        uint8_t bytes[36] = {0};
        struct xrt_wire_frame f = {.request = 1, .op = 1, .size = 4};
        assert(xrt_wire_header_encode(&f, bytes));
        if (mode == 1) assert(write(peer[mode], bytes, 7) == 7);
        if (mode == 2) assert(write(peer[mode], bytes, 34) == 34);
        if (mode == 3 || mode == 5) fill(t->fd);
        if (mode == 4) assert(write(peer[mode], "$OK#", 4) == 4);
        if (mode == 6) {
            int size = 4096;
            assert(!setsockopt(t->fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)));
        }
        assert(!pthread_create(&threads[mode], NULL, operation, t));
        if (mode == 6) {
            char observed[64];
            while (recv(peer[mode], observed, sizeof(observed), MSG_PEEK) <= 32) sched_yield();
        }
        in_poll(t);
    }
    xrt_cancel_request(cancel);
    xrt_cancel_request(cancel);
    xrt_cancel_release(cancel); /* Every reader owns its own lifetime. */
    for (int mode = 0; mode < count; ++mode) {
        struct task *t = &task[mode];
        struct pollfd done = {.fd = t->done[0], .events = POLLIN};
        assert(poll(&done, 1, 10000) == 1); /* Safety bound, no peer release. */
        assert(!pthread_join(threads[mode], NULL));
        assert(t->result == (mode < 4 || mode == 6 ? (int)XRT_WIRE_CANCELLED : (int)XRT_REMOTE_CANCELLED));
        if (mode == 3) assert(t->written == 0);
        if (mode == 6) assert(t->written > 32 && t->written < XRT_WIRE_MAX_BODY + 32);
        if (t->fd >= 0) close(t->fd);
        close(peer[mode]); close(t->done[0]); close(t->done[1]);
        xrt_cancel_release(t->cancel);
    }
}
static void final_bytes(void)
{
    for (unsigned gdb = 0; gdb < 2; ++gdb) {
        struct task task = {.mode = gdb ? 4 : 0, .cancel = xrt_cancel_create()};
        assert(task.cancel);
        int pair[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, pair));
        task.fd = pair[0]; held_fd = pair[0]; atomic_init(&task.tid, 0);
        assert(!pipe2(task.done, O_CLOEXEC) && !pipe2(held_notice, O_CLOEXEC) && !pipe2(held_release, O_CLOEXEC));
        if (gdb) assert(write(pair[1], "$OK#9a", 6) == 6);
        else {
            struct xrt_wire_frame frame = {.request = 1, .op = 1, .size = 4};
            assert(xrt_wire_write(pair[1], &frame, "body", 1000) == XRT_WIRE_OK);
        }
        pthread_t thread; assert(!pthread_create(&thread, NULL, operation, &task));
        struct pollfd notice = {.fd = held_notice[0], .events = POLLIN};
        assert(poll(&notice, 1, 10000) == 1);
        xrt_cancel_request(task.cancel);
        assert(write(held_release[1], "!", 1) == 1);
        assert(!pthread_join(thread, NULL));
        assert(task.result == (gdb ? (int)XRT_REMOTE_CANCELLED : (int)XRT_WIRE_CANCELLED));
        held_fd = -1;
        if (task.fd >= 0) close(task.fd);
        close(pair[1]); close(task.done[0]); close(task.done[1]);
        close(held_notice[0]); close(held_notice[1]); close(held_release[0]); close(held_release[1]);
        xrt_cancel_release(task.cancel);
    }
}
static void before_poll(void)
{
    int pair[2]; assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, pair));
    struct xrt_cancel *c = xrt_cancel_create(); assert(c);
    struct xrt_wire_frame empty = {.request = 1, .op = 1}, out = {.request = 77};
    assert(xrt_wire_write(pair[1], &empty, NULL, 1000) == XRT_WIRE_OK);
    xrt_cancel_request(c);
    assert(xrt_wire_read_cancel(pair[0], &out, NULL, 0, 1000, c) == XRT_WIRE_CANCELLED);
    assert(out.request == 77);
    size_t written = 99;
    assert(xrt_wire_write_cancel(pair[0], &empty, NULL, 1000, c, &written) == XRT_WIRE_CANCELLED);
    assert(!written);
    char b;
    assert(read(pair[1], &b, 1) == -1 && errno == EAGAIN);
    /* The guard did not consume a complete, empty-body final reply. */
    assert(xrt_wire_read(pair[0], &out, NULL, 0, 1000) == XRT_WIRE_OK);
    assert(out.request == 1);
    struct xrt_gdb_link *l = calloc(1, sizeof(*l)); assert(l);
    l->fd = pair[0]; l->cancel = c; l->packet_size = 1024; l->noack = true;
    assert(xrt_gdb_encode((const uint8_t *)"OK", 2, l->rx, sizeof(l->rx), &l->received) == XRT_GDB_OK);
    char reply[16]; size_t length = 99;
    assert(xrt_gdb_receive(l, reply, sizeof(reply), &length, false) == XRT_REMOTE_CANCELLED);
    assert(length == 0 && l->fd == -1);
    assert(xrt_gdb_send(l, "c", 1) == XRT_REMOTE_CANCELLED && l->written == 0);
    assert(xrt_gdb_connect(l, "127.0.0.1:1", c) == XRT_REMOTE_CANCELLED);
    free(l); close(pair[1]);
    int wake = xrt_cancel_fd(c);
    struct xrt_cancel *held = xrt_cancel_retain(c);
    xrt_cancel_release(c);
    assert(xrt_cancel_requested(held) && fcntl(wake, F_GETFD) >= 0);
    xrt_cancel_release(held);
    assert(fcntl(wake, F_GETFD) == -1 && errno == EBADF);
    c = xrt_cancel_create(); assert(c && !xrt_cancel_requested(c));
    xrt_cancel_release(c);
}
int main(void)
{
    alarm(30);
    before_poll();
    waits();
    final_bytes();
    puts("remote cancellation: pending/partial writes, header/body/packet reads, seven waiters, final-byte race, sticky/duplicate/pre-poll cancellation and retained lifetime pass");
}
