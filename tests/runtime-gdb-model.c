#define _GNU_SOURCE 1
#include "xrt_gdbremote.h"
#include "gdb_packet.h"
#include "gdb_link.h"
#include "gdbremote.h"
#include "check.h"
#include "remote_internal.h"
#include <pthread.h>
#include <stdatomic.h>
#include <sys/syscall.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <sys/un.h>
#include <sys/resource.h>
#include <arpa/inet.h>
#include <assert.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

/* Synthetic stub: confirmations are deliberately unreliable. None of its
 * addresses refer to this process, so a native fallback cannot make it pass. */
static int digit(unsigned c)
{
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    assert(0); return 0;
}
static void encode(uint64_t value, char *out)
{
    static const char hex[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i) {
        unsigned byte = (unsigned)(value >> (8 * i)) & 255;
        out[2 * i] = hex[byte >> 4]; out[2 * i + 1] = hex[byte & 15];
    }
}
static uint64_t decode(const char *text)
{
    uint64_t value = 0;
    for (unsigned i = 0; i < 8; ++i)
        value |= (uint64_t)(digit(text[2 * i]) * 16 + digit(text[2 * i + 1])) << (8 * i);
    return value;
}
static void send_all(int fd, const void *data, size_t size)
{
    size_t at = 0;
    while (at < size) {
        ssize_t n = send(fd, (const char *)data + at, size - at, MSG_NOSIGNAL);
        assert(n > 0); at += (size_t)n;
    }
}
static int command(int fd, char *out, size_t cap)
{
    uint8_t wire[4096]; size_t used = 0;
    for (;;) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        assert(poll(&p, 1, 10000) > 0);
        ssize_t n = recv(fd, wire + used, 1, 0);
        if (n == 0) return 0;
        assert(n == 1 && used + 1 < sizeof(wire)); ++used;
        struct xrt_gdb_view view;
        enum xrt_gdb_decode_status status = xrt_gdb_decode(wire, used, (uint8_t *)out, cap - 1, &view);
        if (status == XRT_GDB_NEED_MORE) continue;
        assert(status == XRT_GDB_OK && view.consumed == used);
        used = 0;
        if (view.kind == XRT_GDB_ACK) continue;
        assert(view.kind == XRT_GDB_PACKET);
        send_all(fd, "+", 1); out[view.length] = 0; return 1;
    }
}
static void reply(int fd, const char *text)
{
    uint8_t wire[8192]; size_t size;
    assert(xrt_gdb_encode((const uint8_t *)text, strlen(text), wire, sizeof(wire), &size) == XRT_GDB_OK);
    send_all(fd, wire, size);
}
enum { SLOW_THREADS = 3, CHURN_THREADS = 4, CLOSED_LINK = 5, HOLD_READ = 6, HOLD_WRITE = 7 };
static int held_notify = -1;
static void hold_reply(int fd, uint64_t value)
{
    assert(held_notify >= 0 && write(held_notify, &value, sizeof(value)) == sizeof(value));
    close(held_notify);
    char byte;
    // Peer closes without our reply/release; with our ack still unread that is a reset.
    assert(recv(fd, &byte, 1, 0) <= 0);
    close(fd); _exit(0);
}
static void serve_connection(int fd, int mode, bool adopted, int attach_pid)
{
    if (adopted) {
        char first[128];
        CHECK(command(fd, first, sizeof first));
        CHECK(!strcmp(first, "QSetDetachOnError:1"));
        reply(fd, "OK");
    }
    uint64_t reg = 7, memory = 17, selected = 1; unsigned detach_count = 0;
    char request[4096], response[4096];
    unsigned commands = 0, round = 0, listed = 0, delayed = 0;
    while (command(fd, request, sizeof(request))) {
        assert(++commands <= 4096); strcpy(response, "");
        if (!strncmp(request, "qSupported:", 11))
            strcpy(response, "PacketSize=1000;qXfer:features:read+");
        else if (!strncmp(request, "vAttach;", 8)) {
            char expected[32];
            snprintf(expected, sizeof(expected), "vAttach;%x", attach_pid);
            CHECK(attach_pid > 0 && !strcmp(request, expected));
            strcpy(response, "T05thread:1;");
        }
        else if (!strcmp(request, "vCont?")) strcpy(response, mode >= SLOW_THREADS ? "vCont;c;s" : "vCont;c");
        else if (!strcmp(request, "?")) {
            CHECK(!attach_pid); // vAttach's stop reply is the initial stop.
            strcpy(response, mode == CHURN_THREADS ? "T05thread:10000;" : "T05thread:1;");
        }
        else if (!strncmp(request, "qXfer:features:read:target.xml:", 30)) {
            snprintf(response, sizeof(response), "l<target><architecture>%s</architecture><feature>"
                "<reg name='rip' bitsize='64'/><reg name='rsp' bitsize='64'/>"
                "<reg name='rax' bitsize='64'/></feature></target>", mode == 2 ? "unsupported" : "i386:x86-64");
        } else if (!strcmp(request, "qfThreadInfo") || !strcmp(request, "qsThreadInfo")) {
            bool first = request[1] == 'f';
            if (first) listed = 0;
            if (mode == SLOW_THREADS && round && !first) {
                /* Each page is inside the read deadline. The entire inventory
                 * exceeds the operation budget. EOF proves the client stops it. */
                struct pollfd p = {.fd = fd, .events = POLLIN};
                if (poll(&p, 1, (int)(XRT_GDB_OPERATION_NS / UINT64_C(10000000))) > 0) {
                    char c;
                    assert(recv(fd, &c, 1, 0) == 0);
                    assert(delayed > 0 && delayed < 32);
                    close(fd); _exit(0);
                }
                assert(++delayed <= 32);
                snprintf(response, sizeof(response), "m%x", delayed + 2);
            } else if (mode == CHURN_THREADS && listed < 1024) {
                size_t at = 0;
                for (unsigned i = 0; i < 64 && listed < 1024; ++i, ++listed) {
                    unsigned tid = listed == 0 ? 1 : listed == 1 ? 0x80000001u :
                        0x10000u + round * 1024 + listed - 2;
                    int n = snprintf(response + at, sizeof(response) - at, "%c%x", i ? ',' : 'm', tid);
                    assert(n > 0 && (size_t)n < sizeof(response) - at); at += (size_t)n;
                }
            } else if (first) {
                if (mode < SLOW_THREADS) reply(fd, "T05thread:1;"); /* Duplicate initial stop. */
                strcpy(response, mode == 1 || attach_pid ? "" : "m1,2");
            } else strcpy(response, "l");
        } else if (!strncmp(request, "vCont;s:", 8)) {
            ++round;
            snprintf(response, sizeof(response), "T05thread:%x;", mode == CHURN_THREADS ? 0x10000 + round * 1024 : 1);
        }
        else if (!strcmp(request, "qAttached")) strcpy(response, "1");
        else if (!strncmp(request, "Hg", 2)) {
            char *end; selected = strtoull(request + 2, &end, 16); assert(!*end);
            strcpy(response, "OK");
        }
        else if (!strcmp(request, "g")) {
            if (mode == CLOSED_LINK && ++listed > 1) { close(fd); _exit(0); }
            encode(0x1000, response); encode(0x8000, response + 16); encode(mode == CHURN_THREADS ? selected : reg, response + 32); response[48] = 0;
        } else if (!strncmp(request, "P2=", 3)) {
            uint64_t wanted = decode(request + 3);
            reg = wanted == 10 ? 9 : wanted;
            strcpy(response, wanted == 11 ? "E01" : "OK");
        } else if (request[0] == 'm') {
            unsigned long long address; unsigned size;
            assert(sscanf(request + 1, "%llx,%x", &address, &size) == 2 && (size == 8 || size == 1));
            if (size == 1) { reply(fd, "90"); continue; }
            if (mode == HOLD_READ && address == 0x2000) hold_reply(fd, memory);
            encode(address == 0x2000 ? memory : 17, response); response[16] = 0;
        } else if (request[0] == 'M') {
            unsigned long long address; unsigned size; int at = 0;
            assert(sscanf(request + 1, "%llx,%x:%n", &address, &size, &at) == 2 && size == 8);
            if (address == 0x2000) memory = decode(request + 1 + at);
            if (mode == HOLD_WRITE && address == 0x2000) hold_reply(fd, memory);
            strcpy(response, address == 0x2010 ? "E01" : "OK");
        } else if (!strncmp(request, "Z0,", 3)) strcpy(response, "E01");
        else if (!strncmp(request, "z0,", 3)) strcpy(response, "OK");
        else if (!strcmp(request, "D")) {
            strcpy(response, attach_pid || mode >= SLOW_THREADS || detach_count++ != 0 ? "OK" : "E01");
        }
        reply(fd, response);
    }
    close(fd); _exit(0);
}
static void serve(int listener, int mode)
{
    int fd = accept(listener, NULL, NULL); assert(fd >= 0); close(listener);
    serve_connection(fd, mode, false, 0);
}
struct fixture { pid_t child; char endpoint[64]; };
static struct fixture start(int mode)
{
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); assert(listener >= 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    assert(!bind(listener, (struct sockaddr *)&address, sizeof(address)) && !listen(listener, 1));
    socklen_t size = sizeof(address); assert(!getsockname(listener, (struct sockaddr *)&address, &size));
    struct fixture f = {.child = fork()}; assert(f.child >= 0);
    if (!f.child) serve(listener, mode);
    close(listener);
    snprintf(f.endpoint, sizeof(f.endpoint), "127.0.0.1:%u", ntohs(address.sin_port)); return f;
}
static void finish(struct fixture f)
{
    int status; assert(waitpid(f.child, &status, 0) == f.child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static uint64_t generation(struct xrt_target *target)
{
    struct xrt_target_view view; xrt_target_view(target, &view); return view.generation;
}
struct cancelled_call {
    struct xrt_target *target;
    bool mutation, health;
    atomic_int tid;
    enum xrt_status status;
};
static void *cancelled_call(void *opaque)
{
    struct cancelled_call *call = opaque;
    atomic_store(&call->tid, (int)syscall(SYS_gettid));
    uint64_t value = 99;
    size_t length = 0;
    call->status = call->health ? xrt_remote_health(call->target) :
        xrt_remote_call(call->target, &(struct xrt_call){
            .op = call->mutation ? XRT_RPC_WRITE : XRT_RPC_READ, .args = {0x2000, 8},
            .data = call->mutation ? &value : NULL, .size = call->mutation ? 8 : 0,
            .out = call->mutation ? NULL : &value, .capacity = call->mutation ? 0 : 8,
            .length = &length});
    return NULL;
}
static void mutex_waiter(struct cancelled_call *call)
{
    for (;;) {
        int tid = atomic_load(&call->tid);
        if (tid) {
            char path[96], line[256];
            snprintf(path, sizeof(path), "/proc/self/task/%d/syscall", tid);
            int fd = open(path, O_RDONLY | O_CLOEXEC); assert(fd >= 0);
            ssize_t n = read(fd, line, sizeof(line)-1); close(fd); assert(n > 0); line[n] = 0;
            char *end; long number = strtol(line, &end, 10);
            if (end != line && number == SYS_futex) return;
        }
        sched_yield();
    }
}
static void cancellation_checks(void)
{
    for (int mode = HOLD_READ; mode <= HOLD_WRITE; ++mode) {
        int event[2]; assert(!pipe(event)); held_notify = event[1];
        struct fixture f = start(mode); close(event[1]); held_notify = -1;
        struct xrt_target *target = NULL;
        assert(xrt_target_gdb_remote(f.endpoint, &target) == XRT_OK);
        struct xrt_cancel *cancel = xrt_target_cancel(target); assert(cancel);
        struct cancelled_call call = {.target = target, .mutation = mode == HOLD_WRITE};
        struct cancelled_call health = {.target = target, .health = true};
        atomic_init(&call.tid, 0); atomic_init(&health.tid, 0);
        pthread_t reader, waiter;
        assert(!pthread_create(&reader, NULL, cancelled_call, &call));
        uint64_t applied;
        assert(read(event[0], &applied, sizeof(applied)) == sizeof(applied)); close(event[0]);
        assert(applied == (mode == HOLD_WRITE ? 99u : 17u));
        assert(!pthread_create(&waiter, NULL, cancelled_call, &health));
        mutex_waiter(&health); // A second reader really is behind the transport mutex.
        xrt_remote_io_guard(true);
        assert(xrt_remote_health(target) == XRT_REMOTE_IO_FORBIDDEN);
        xrt_remote_io_guard(false);
        xrt_cancel_request(cancel); xrt_cancel_request(cancel);
        assert(!pthread_join(reader, NULL) && !pthread_join(waiter, NULL));
        assert(call.status == (mode == HOLD_WRITE ? XRT_REMOTE_OUTCOME_UNKNOWN : XRT_REMOTE_CANCELLED));
        assert(health.status == XRT_REMOTE_CANCELLED);
        assert(xrt_target_continue(target) == XRT_REMOTE_CANCELLED);
        assert(xrt_target_destroy(target) == XRT_OK);
        finish(f);
        assert(xrt_cancel_requested(cancel)); // Capability outlives target/connection.
        struct fixture fresh = start(HOLD_READ);
        target = NULL; assert(xrt_target_gdb_remote(fresh.endpoint, &target) == XRT_OK);
        struct xrt_cancel *new_cancel = xrt_target_cancel(target);
        assert(new_cancel && new_cancel != cancel && !xrt_cancel_requested(new_cancel));
        xrt_cancel_request(cancel);
        assert(xrt_target_expect(target, generation(target)) == XRT_OK);
        assert(xrt_target_destroy(target) == XRT_OK);
        finish(fresh);
        xrt_cancel_release(new_cancel); xrt_cancel_release(cancel);
    }
    puts("remote cancellation: held GDB read/write, mutex waiter, guarded lock refusal, sent mutation outcome unknown and fresh capability pass");
}
static void lifecycle_checks(void)
{
    for (int mode = SLOW_THREADS; mode <= CLOSED_LINK; ++mode) {
        struct fixture f = start(mode); struct xrt_target *target = NULL;
        assert(xrt_target_gdb_remote(f.endpoint, &target) == XRT_OK);
        if (mode == SLOW_THREADS) {
            struct timespec begin, end;
            assert(!clock_gettime(CLOCK_MONOTONIC, &begin));
            assert(xrt_target_step(target, 1) == XRT_OK);
            assert(xrt_target_wait_stopped(target) == XRT_TRANSPORT_FAILED);
            assert(!clock_gettime(CLOCK_MONOTONIC, &end));
            struct xrt_gdb_info info; assert(xrt_target_gdb_info(target, &info) == XRT_OK);
            assert(strstr(info.reason, "operation deadline exceeded"));
            assert(xrt_target_poll(target) == XRT_TRANSPORT_FAILED);
            printf("GDB slow inventory: operation deadline failed the link after %.3f s\n",
                (double)(end.tv_sec - begin.tv_sec) + (double)(end.tv_nsec - begin.tv_nsec) / 1e9);
        } else if (mode == CHURN_THREADS) {
            for (unsigned round = 0; round < 4; ++round) {
                struct xrt_target_view view; xrt_target_view(target, &view);
                assert(view.thread_count == 1024);
                /* A high remote TID keeps its local alias across refreshes. */
                struct xrt_registers regs;
                assert(xrt_target_registers(target, 2, &regs) == XRT_OK);
                uint64_t actual;
                assert(xrt_registers_value(&regs, "rax", 3, &actual) == XRT_OK && actual == 0x80000001u);
                assert(xrt_target_step(target, (int32_t)(0x10000 + round * 1024)) == XRT_OK);
                assert(xrt_target_wait_stopped(target) == XRT_OK);
                assert(xrt_target_registers(target, (int32_t)(0x10000 + round * 1024), &regs) == XRT_UNKNOWN_THREAD);
            }
            assert(xrt_target_detach(target) == XRT_OK);
        } else {
            struct xrt_registers regs;
            assert(xrt_target_registers(target, 1, &regs) == XRT_TRANSPORT_FAILED);
            assert(xrt_target_detach(target) == XRT_TRANSPORT_FAILED);
        }
        /* ASan/LSan also verify that a failed transport frees the target. */
        assert(xrt_target_destroy(target) == XRT_OK);
        finish(f);
    }
    puts("GDB lifecycle: bounded slow inventory, full-table turnover with stable aliases, failed-link destruction pass");
}
/* The opt-in guard is dormant in current event loops. A future remote owner
 * marks only the presentation thread; sibling workers may still use I/O. */
static void *guard_worker(void *unused)
{
    (void)unused;
    assert(xrt_target_remote(NULL, NULL) == XRT_INVALID_ARGUMENT);
    assert(xrt_target_gdb_remote(NULL, NULL) == XRT_INVALID_ARGUMENT);
    return NULL;
}
static void release_guard(void)
{
    int log[2]; assert(!pipe(log));
    int saved = dup(STDERR_FILENO); assert(saved >= 0);
    assert(dup2(log[1], STDERR_FILENO) >= 0); close(log[1]);
    xrt_remote_io_guard_strict(false);
    xrt_remote_io_guard(true);
    const uint32_t before = xrt_remote_io_violation_count();
    for (unsigned i = 0; i < 128; ++i) {
        assert(xrt_target_remote(NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_target_gdb_remote(NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_call(NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_background_file(NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_health(NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_fail(NULL, XRT_OK) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_file(NULL, NULL, NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
        assert(xrt_remote_symbol_file(NULL, NULL, NULL, NULL, NULL) == XRT_REMOTE_IO_FORBIDDEN);
    }
    assert(xrt_remote_io_violation_count() == before + 1024);
    xrt_remote_io_guard(false);
    fflush(stderr);
    assert(dup2(saved, STDERR_FILENO) >= 0); close(saved);
    char bytes[256]; ssize_t n = read(log[0], bytes, sizeof(bytes));
    assert(n > 0 && n < (ssize_t)sizeof(bytes));
    unsigned lines = 0;
    for (ssize_t i = 0; i < n; ++i) lines += bytes[i] == '\n';
    assert(lines == 1 && read(log[0], bytes, sizeof(bytes)) == 0); close(log[0]);
    puts("remote release guard: 1024 typed refusals before dereference/lock/I/O, one diagnostic line pass");
}
static void owner_guard(void)
{
    xrt_remote_io_guard_strict(true);
    xrt_remote_io_guard(true);
    pthread_t worker;
    assert(!pthread_create(&worker, NULL, guard_worker, NULL));
    assert(!pthread_join(worker, NULL));
    /* Native/empty target ownership is not moved by the remote guard. */
    struct xrt_target *native = xrt_target_create(); assert(native);
    struct xrt_target_view view; xrt_target_view(native, &view);
    xrt_target_file_budget(native, NULL);
    assert(view.state == XRT_IDLE && xrt_target_destroy(native) == XRT_OK);
    for (unsigned which = 0; which < 8; ++which) {
        pid_t child = fork(); assert(child >= 0);
        if (!child) {
            struct rlimit core = {0, 0}; assert(!setrlimit(RLIMIT_CORE, &core));
            assert(freopen("/dev/null", "w", stderr));
            /* Null arguments prove assertion happens before dereferencing a
             * handle, taking a connection lock, allocating or opening I/O. */
            if (which == 0) (void)xrt_target_remote(NULL, NULL);
            if (which == 1) (void)xrt_target_gdb_remote(NULL, NULL);
            if (which == 2) (void)xrt_remote_call(NULL, NULL);
            if (which == 3) (void)xrt_remote_background_file(NULL, NULL);
            if (which == 4) (void)xrt_remote_health(NULL);
            if (which == 5) (void)xrt_remote_fail(NULL, XRT_OK);
            if (which == 6) (void)xrt_remote_file(NULL, NULL, NULL, NULL);
            if (which == 7) (void)xrt_remote_symbol_file(NULL, NULL, NULL, NULL, NULL);
            _exit(1);
        }
        int status; assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
    xrt_remote_io_guard(false);
    xrt_remote_io_guard_strict(false);
    assert(xrt_target_remote(NULL, NULL) == XRT_INVALID_ARGUMENT);
    assert(xrt_target_gdb_remote(NULL, NULL) == XRT_INVALID_ARGUMENT);
    puts("remote owner guard: GDB, agent, dispatch and lock entrypoints assert before I/O; worker-local state and native path preserved");
}
static void private_open(void)
{
    int pair[2]; CHECK(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair));
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) { close(pair[0]); serve_connection(pair[1], 1, true, 0); }
    close(pair[1]);
    struct xrt_target *target = xrt_target_create(); CHECK(target);
    struct xrt_gdb *gdb = NULL;
    CHECK(xrt_gdb_open_fd(pair[0], 0, target, &gdb, NULL) == XRT_OK);
    CHECK(!xrt_gdb_detach_confirmed(gdb));
    struct xrt_target *idle = xrt_target_create(); CHECK(idle);
    CHECK(xrt_gdb_call(gdb, idle, &(struct xrt_call){.op=XRT_RPC_DETACH}) == XRT_OK);
    CHECK(!xrt_gdb_detach_confirmed(gdb)); // No packet was sent for an idle target.
    free(idle);
    struct xrt_target_view view; xrt_target_view(target, &view);
    CHECK(view.state == XRT_STOPPED && view.thread_count == 1);
    CHECK(xrt_gdb_call(gdb, target, &(struct xrt_call){.op=XRT_RPC_DETACH}) == XRT_DETACH_INCOMPLETE);
    CHECK(!xrt_gdb_detach_confirmed(gdb));
    CHECK(xrt_gdb_call(gdb, target, &(struct xrt_call){.op=XRT_RPC_DETACH}) == XRT_OK);
    CHECK(xrt_gdb_detach_confirmed(gdb));
    xrt_gdb_free(gdb); free(target); // Internal owner, no native pid relationship.
    CHECK(fcntl(pair[0], F_GETFD) == -1);
    finish((struct fixture){.child=child});

    CHECK(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair));
    child = fork(); CHECK(child >= 0);
    if (!child) { close(pair[0]); serve_connection(pair[1], 0, true, 42); }
    close(pair[1]);
    target = xrt_target_create(); CHECK(target);
    gdb = NULL;
    CHECK(xrt_gdb_open_fd(pair[0], 42, target, &gdb, NULL) == XRT_OK);
    CHECK(xrt_gdb_mutation_bytes(gdb) > 0);
    xrt_target_view(target, &view);
    CHECK(view.state == XRT_STOPPED && view.thread_count == 1);
    CHECK(xrt_gdb_call(gdb, target, &(struct xrt_call){.op=XRT_RPC_DETACH}) == XRT_OK);
    CHECK(xrt_gdb_detach_confirmed(gdb));
    xrt_gdb_free(gdb); free(target);
    finish((struct fixture){.child=child});
}
struct kgdb_io { int fd, saw_g, saw_dollar; };
static int kgdb_byte(int fd, unsigned char *b)
{
    for (;;) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int result = poll(&p, 1, 10000);
        if (result == 0) return -1;
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) return -1;
        ssize_t n = read(fd, b, 1);
        if (n == 0 || (n < 0 && errno == ECONNRESET)) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n != 1) return -1;
        return 1;
    }
}
static int kgdb_command(struct kgdb_io *io, char *out, size_t cap)
{
    uint8_t wire[2048];
    size_t used = 0;
    for (;;) {
        unsigned char b;
        int n = kgdb_byte(io->fd, &b);
        if (n <= 0) return n;
        if (!io->saw_dollar) {
            if (b == 'g') { io->saw_g = 1; continue; }
            if (b != '$' && b != '+' && b != '-') continue;
        }
        if (b == '$') io->saw_dollar = 1;
        if (used >= sizeof wire) return -1;
        wire[used++] = b;
        struct xrt_gdb_view view;
        enum xrt_gdb_decode_status status = xrt_gdb_decode(wire, used, (uint8_t *)out, cap - 1, &view);
        if (status == XRT_GDB_NEED_MORE) continue;
        if (status != XRT_GDB_OK || !view.consumed || view.consumed > used) return -1;
        memmove(wire, wire + view.consumed, used - view.consumed);
        used -= view.consumed;
        if (view.kind == XRT_GDB_ACK || view.kind == XRT_GDB_NAK) continue;
        if (view.kind != XRT_GDB_PACKET) continue;
        unsigned char ack = '+';
        ssize_t wrote;
        do wrote = write(io->fd, &ack, 1); while (wrote < 0 && errno == EINTR);
        if (wrote != 1) return -1;
        out[view.length] = 0;
        return 1;
    }
}
static void kgdb_reply(int fd, const char *text)
{
    uint8_t wire[4096];
    size_t size = 0, at = 0;
    CHECK(xrt_gdb_encode((const uint8_t *)text, strlen(text), wire, sizeof wire, &size) == XRT_GDB_OK);
    while (at < size) {
        ssize_t n = write(fd, wire + at, size - at);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0);
        at += (size_t)n;
    }
}
static void kgdb_put(char *bank, unsigned offset, uint64_t value)
{
    static const char digits[] = "0123456789abcdef";
    for (unsigned i = 0; i < 8; ++i) {
        unsigned byte = (unsigned)(value >> (8 * i)) & 255u;
        bank[2 * (offset + i)] = digits[byte >> 4];
        bank[2 * (offset + i) + 1] = digits[byte & 15];
    }
}
enum { KGDB_LIVE = 0, KGDB_SHORT = 1, KGDB_BADHEX = 2, KGDB_SERIAL = 3, KGDB_RUNNING = 4 };
/* Mirrors Linux kgdb on the wire: ids without leading zero bytes, an empty
 * reply ending the thread list, NUL-padded comm names, no reply to 0x03 while
 * running, and on x86 the address after int3 as the stopped pc. */
static void kgdb_serve(int fd, int mode)
{
    struct kgdb_io io = {.fd = fd};
    char request[1280], response[1280], last_hc[64], shadow_bank[313], task_bank[313];
    char *selected = shadow_bank;
    int stopped_task = 0;
    unsigned long long breakpoint = 0;
    last_hc[0] = 0;
    memset(shadow_bank, '0', 312); shadow_bank[312] = 0;
    memset(task_bank, '0', 312); task_bank[312] = 0;
    kgdb_put(shadow_bank, 56, 0x7ffe0000); kgdb_put(shadow_bank, 128, 0x401000);
    kgdb_put(task_bank, 56, 0x7ffe1000); kgdb_put(task_bank, 128, 0x402000);
    for (;;) {
        int got = kgdb_command(&io, request, sizeof request);
        if (got <= 0) _exit(got < 0 ? 7 : 0);
        if (mode == KGDB_SERIAL && !io.saw_g) _exit(3);
        if (!strcmp(request, "k") || !strncmp(request, "vKill", 5) || !strncmp(request, "vRun", 4) ||
            request[0] == 'R')
            _exit(2);
        response[0] = 0;
        if (!strcmp(request, "?")) strcpy(response, "S05");
        else if (!strcmp(request, "qC")) strcpy(response, stopped_task ? "QC01" : "QCfffffffe");
        else if (!strcmp(request, "qfThreadInfo")) strcpy(response, "mfffffffe,fffffffd,01");
        else if (!strcmp(request, "qsThreadInfo")) response[0] = 0;
        else if (!strcmp(request, "qThreadExtraInfo,fffffffe")) strcpy(response, "736861646f7743505530");
        else if (!strcmp(request, "qThreadExtraInfo,fffffffd")) strcpy(response, "736861646f7743505531");
        else if (!strcmp(request, "qThreadExtraInfo,1"))
            strcpy(response, "696e6974000000000000000000000000");
        else if (!strncmp(request, "Hg", 2)) {
            selected = !strcmp(request + 2, "1") ? task_bank : shadow_bank;
            strcpy(response, "OK");
        } else if (!strncmp(request, "Hc", 2)) {
            snprintf(last_hc, sizeof last_hc, "%s", request + 2);
            strcpy(response, "OK");
        } else if (!strcmp(request, "g")) {
            if (mode == KGDB_SHORT) strcpy(response, "00");
            else if (mode == KGDB_BADHEX) memset(response, 'z', 312), response[312] = 0;
            else strcpy(response, selected);
        } else if (!strncmp(request, "P10=", 4) && strlen(request) == 20) {
            memcpy(selected + 2 * 128, request + 4, 16);
            strcpy(response, "OK");
        } else if (request[0] == 'm') {
            unsigned long long address; unsigned size;
            /* x86 kgdb has no bound; more than 511 bytes overruns BUFMAX. */
            if (sscanf(request + 1, "%llx,%x", &address, &size) != 2 || !size || size > 511) _exit(6);
            (void)address;
            memset(response, '0', size * 2u);
            response[size * 2u] = 0;
        } else if (!strncmp(request, "Z0,", 3)) {
            if (sscanf(request + 3, "%llx", &breakpoint) != 1) _exit(7);
            strcpy(response, "OK");
        } else if (!strncmp(request, "z0,", 3)) {
            breakpoint = 0;
            strcpy(response, "OK");
        } else if (!strcmp(request, "c")) {
            if (strcmp(last_hc, "0")) _exit(5);
            if (mode == KGDB_RUNNING) {
                /* Nothing may follow on a running kernel: no 0x03, k or D. */
                struct pollfd p = {.fd = fd, .events = POLLIN};
                unsigned char b;
                if (poll(&p, 1, 2000) > 0 && read(fd, &b, 1) == 1) _exit(9);
                _exit(0);
            }
            if (breakpoint) {
                kgdb_put(task_bank, 128, breakpoint + 1);
                stopped_task = 1;
                strcpy(response, "T05thread:01;");
            } else strcpy(response, "T05thread:fffffffe;");
        } else if (!strcmp(request, "s")) {
            if (strcmp(last_hc, stopped_task ? "1" : "fffffffe")) _exit(4);
            if (breakpoint) _exit(8); /* Stepping onto its own int3. */
            kgdb_put(stopped_task ? task_bank : shadow_bank, 128, stopped_task ? 0x402004 : 0x401004);
            strcpy(response, stopped_task ? "T05thread:01;" : "T05thread:fffffffe;");
        } else if (!strcmp(request, "D")) {
            kgdb_reply(fd, "OK");
            _exit(0);
        }
        kgdb_reply(fd, response);
    }
}
static pid_t kgdb_unix(int mode, char *endpoint, size_t cap)
{
    char cwd[80], path[96];
    CHECK(getcwd(cwd, sizeof cwd));
    int n = snprintf(path, sizeof path, "%s/kgdb.sock", cwd);
    CHECK(n > 0 && n < (int)sizeof path);
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    CHECK(listener >= 0);
    unlink(path);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    CHECK(strlen(path) < sizeof addr.sun_path);
    memcpy(addr.sun_path, path, strlen(path));
    CHECK(!bind(listener, (struct sockaddr *)&addr, sizeof addr) && !listen(listener, 1));
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0) _exit(7);
        close(listener);
        kgdb_serve(fd, mode);
    }
    close(listener);
    CHECK(snprintf(endpoint, cap, "unix:%s", path) < (int)cap);
    return child;
}
static void kgdb_join(pid_t child, const char *endpoint)
{
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    if (endpoint && !strncmp(endpoint, "unix:", 5)) unlink(endpoint + 5);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static void kgdb_expect(const char *endpoint, enum xrt_status want)
{
    struct xrt_target *target = NULL;
    CHECK(xrt_target_gdb_remote(endpoint, &target) == want && !target);
}
static void kgdb_session(const char *endpoint, int exercise)
{
    struct xrt_target *target = NULL;
    CHECK(xrt_target_gdb_remote(endpoint, &target) == XRT_OK && target);
    struct xrt_gdb_info gdb;
    CHECK(xrt_target_gdb_info(target, &gdb) == XRT_OK);
    CHECK((gdb.supported & XRT_GDB_CAP_STEP) && !(gdb.unsupported & XRT_GDB_CAP_STEP));
    CHECK(!strcmp(gdb.architecture, "i386:x86-64"));
    struct xrt_target_view view;
    xrt_target_view(target, &view);
    CHECK(view.state == XRT_STOPPED && view.thread_count == 3);
    int32_t shadow = 0, shadow1 = 0, task = 0;
    for (size_t i = 0; i < view.thread_count; ++i) {
        if (view.threads[i].tid == 1) task = 1;
        if (view.threads[i].tid == 0x60000002) shadow = 0x60000002;
        if (view.threads[i].tid == 0x60000003) shadow1 = 0x60000003;
    }
    CHECK(task == 1 && shadow == 0x60000002 && shadow1 == 0x60000003);
    struct xrt_gdb_thread_info names;
    CHECK(xrt_target_gdb_thread_info(target, shadow, &names) == XRT_OK);
    CHECK(names.has_name && !strcmp(names.name, "shadowCPU0"));
    CHECK(xrt_target_gdb_thread_info(target, task, &names) == XRT_OK);
    CHECK(names.has_name && !strcmp(names.name, "init"));
    struct xrt_registers regs;
    uint64_t pc = 0, sp = 0;
    CHECK(xrt_target_registers(target, shadow, &regs) == XRT_OK);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == 0x401000);
    CHECK(xrt_registers_value(&regs, "rsp", 3, &sp) == XRT_OK && sp == 0x7ffe0000);
    CHECK(xrt_target_registers(target, task, &regs) == XRT_OK);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == 0x402000);
    CHECK(xrt_registers_value(&regs, "rsp", 3, &sp) == XRT_OK && sp == 0x7ffe1000);
    if (exercise) {
        uint64_t id = 0;
        CHECK(xrt_target_breakpoint_set(target, 0x402000, false, &id) == XRT_OK);
        CHECK(xrt_target_continue(target) == XRT_OK);
        CHECK(xrt_target_wait_stopped(target) == XRT_OK);
        /* The stub said 0x402001; the client rewound onto its breakpoint. */
        CHECK(xrt_target_registers(target, task, &regs) == XRT_OK);
        CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == 0x402000);
        xrt_target_view(target, &view);
        int hit = 0;
        for (size_t i = 0; i < view.thread_count; ++i)
            if (view.threads[i].tid == task) hit = view.threads[i].reason == XRT_STOP_BREAKPOINT;
        CHECK(hit);
        CHECK(xrt_target_step(target, shadow) == XRT_UNSUPPORTED_CONTROL);
        CHECK(xrt_target_step(target, task) == XRT_OK);
        CHECK(xrt_target_wait_stopped(target) == XRT_OK);
        CHECK(xrt_target_registers(target, task, &regs) == XRT_OK);
        CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == 0x402004);
        uint8_t big[1024];
        size_t count = 0;
        CHECK(xrt_target_read(target, 0x403000, big, sizeof big, &count) == XRT_OK && count == sizeof big);
    }
    CHECK(xrt_target_detach(target) == XRT_OK);
    CHECK(xrt_target_destroy(target) == XRT_OK);
}
static void kgdb_serial(void)
{
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    CHECK(master >= 0 && !grantpt(master) && !unlockpt(master));
    char *name = ptsname(master);
    char slave[64], endpoint[80];
    CHECK(name && strlen(name) < sizeof slave);
    memcpy(slave, name, strlen(name) + 1);
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) kgdb_serve(master, KGDB_SERIAL);
    close(master);
    CHECK(snprintf(endpoint, sizeof endpoint, "serial:%s,115200,break", slave) < (int)sizeof endpoint);
    kgdb_session(endpoint, 0);
    kgdb_join(child, NULL);
}
static void kgdb_lab(void)
{
    const char *endpoint = getenv("XODB_KGDB_ENDPOINT");
    if (!endpoint || !endpoint[0]) {
        puts("skip: KGDB lab endpoint not set");
        return;
    }
    struct xrt_target *target = NULL;
    CHECK(xrt_target_gdb_remote(endpoint, &target) == XRT_OK && target);
    struct xrt_target_view view;
    xrt_target_view(target, &view);
    CHECK(view.state == XRT_STOPPED && view.thread_count >= 1);
    struct xrt_registers regs;
    uint64_t pc = 0;
    CHECK(xrt_target_registers(target, view.threads[0].tid, &regs) == XRT_OK);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK);
    CHECK(xrt_target_detach(target) == XRT_OK);
    CHECK(xrt_target_destroy(target) == XRT_OK);
}
static void kgdb_checks(void)
{
    char endpoint[128];
    pid_t child = kgdb_unix(KGDB_LIVE, endpoint, sizeof endpoint);
    kgdb_session(endpoint, 1);
    kgdb_join(child, endpoint);
    child = kgdb_unix(KGDB_SHORT, endpoint, sizeof endpoint);
    struct xrt_target *target = NULL;
    enum xrt_status status = xrt_target_gdb_remote(endpoint, &target);
    CHECK(status == XRT_REGISTER_UNAVAILABLE && !target);
    kgdb_join(child, endpoint);
    child = kgdb_unix(KGDB_BADHEX, endpoint, sizeof endpoint);
    status = xrt_target_gdb_remote(endpoint, &target);
    CHECK(status == XRT_PROTOCOL_ERROR && !target);
    kgdb_join(child, endpoint);
    kgdb_serial();
    /* kgdboc ignores 0x03: a running kernel on a socket is refused, not waited for. */
    child = kgdb_unix(KGDB_RUNNING, endpoint, sizeof endpoint);
    CHECK(xrt_target_gdb_remote(endpoint, &target) == XRT_OK && target);
    uint64_t id = 0;
    CHECK(xrt_target_breakpoint_set(target, 0x402000, false, &id) == XRT_OK);
    CHECK(xrt_target_continue(target) == XRT_OK);
    CHECK(xrt_target_interrupt(target) == XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_target_detach(target) == XRT_UNSUPPORTED_CONTROL);
    (void)xrt_target_destroy(target);
    kgdb_join(child, endpoint);
    char abs_path[96];
    CHECK(getcwd(abs_path, 64));
    size_t prefix = strlen(abs_path);
    CHECK(prefix + 16 < sizeof abs_path);
    memcpy(abs_path + prefix, "/kgdb-absent", 13);
    char bad[128];
    CHECK(snprintf(bad, sizeof bad, "serial:%s,12", abs_path) < (int)sizeof bad);
    kgdb_expect("unix:relative", XRT_INVALID_ARGUMENT);
    kgdb_expect("serial:relative", XRT_INVALID_ARGUMENT);
    kgdb_expect(bad, XRT_INVALID_ARGUMENT);
    CHECK(snprintf(bad, sizeof bad, "serial:%s,115200,nope", abs_path) < (int)sizeof bad);
    kgdb_expect(bad, XRT_INVALID_ARGUMENT);
    kgdb_expect("tcp:host:99999", XRT_INVALID_ARGUMENT);
    kgdb_expect("serial:/dev/kgdb-missing-port", XRT_TRANSPORT_FAILED);
    kgdb_expect("unix:/dev/kgdb-missing-sock", XRT_TRANSPORT_FAILED);
    kgdb_expect("tcp:127.0.0.1:1", XRT_TRANSPORT_FAILED);
    kgdb_lab();
    puts("KGDB model: unix stub, built-in registers, classic step, serial break and typed refusals pass");
}
int main(int argc, char **argv)
{
    alarm(90);
    if (argc == 2 && !strcmp(argv[1], "--kgdb")) {
        kgdb_checks();
        return 0;
    }
    private_open();
    release_guard();
    owner_guard();
    cancellation_checks();
    if (argc == 2 && !strcmp(argv[1], "--cancellation")) return 0;
    lifecycle_checks();
    for (int mode = 0; mode <= 2; ++mode) {
        struct fixture f = start(mode); struct xrt_target *target = NULL;
        enum xrt_status status = xrt_target_gdb_remote(f.endpoint, &target);
        if (mode == 2) {
            assert(status == XRT_UNSUPPORTED_ARCHITECTURE && !target); finish(f); continue;
        }
        assert(status == XRT_OK && target);
        if (mode == 0) {
            uint64_t before = generation(target);
            struct xrt_gdb_info info, untouched;
            memset(&info, 0xa5, sizeof(info)); untouched = info;
            xrt_remote_io_guard(true);
            assert(xrt_target_gdb_info(target, &info) == XRT_REMOTE_IO_FORBIDDEN);
            assert(!memcmp(&info, &untouched, sizeof(info)));
            assert(xrt_target_file_budget(target, NULL) == XRT_REMOTE_IO_FORBIDDEN);
            assert(xrt_target_continue(target) == XRT_REMOTE_IO_FORBIDDEN);
            assert(xrt_target_invalidate(target) == XRT_REMOTE_IO_FORBIDDEN);
            assert(xrt_target_event(target, XRT_EVENT_AGENT_ACTION, 1, 0) == XRT_REMOTE_IO_FORBIDDEN);
            xrt_remote_io_guard(false);
            assert(generation(target) == before);
            pid_t child = fork(); assert(child >= 0);
            if (!child) {
                struct rlimit core = {0, 0}; assert(!setrlimit(RLIMIT_CORE, &core));
                assert(freopen("/dev/null", "w", stderr));
                xrt_remote_io_guard_strict(true);
    xrt_remote_io_guard(true);
                struct xrt_gdb_info guarded;
                (void)xrt_target_gdb_info(target, &guarded);
                _exit(1);
            }
            int child_status; assert(waitpid(child, &child_status, 0) == child);
            assert(WIFSIGNALED(child_status) && WTERMSIG(child_status) == SIGABRT);
        }
        struct xrt_gdb_info info; assert(xrt_target_gdb_info(target, &info) == XRT_OK);
        assert(info.unsupported & XRT_GDB_CAP_STEP);
        assert(mode == 1 ? (info.unsupported & XRT_GDB_CAP_THREADS) : (info.supported & XRT_GDB_CAP_THREADS));
        struct xrt_target_view view; xrt_target_view(target, &view);
        assert(view.thread_count == (mode == 1 ? 1u : 2u));
        assert(view.threads[0].reason == XRT_STOP_INTERRUPT); /* qAttached=1 is not an exec stop. */
        uint64_t before = generation(target);
        assert(xrt_target_step(target, 1) == XRT_UNSUPPORTED_CONTROL);
        assert(generation(target) == before);
        for (uint64_t address = 0x2000; address <= 0x2010; address += 8) {
            uint64_t value = 29; before = generation(target);
            status = xrt_target_write(target, address, &value, sizeof(value));
            assert(status == (address == 0x2000 ? XRT_OK : XRT_PARTIAL_MEMORY_WRITE));
            assert(generation(target) > before);
        }
        for (uint64_t value = 10; value <= 12; ++value) {
            before = generation(target);
            status = xrt_target_register_write(target, 1, "rax", 3, value);
            assert(status == (value == 12 ? XRT_OK : XRT_PARTIAL_REGISTER_WRITE));
            assert(generation(target) > before);
            struct xrt_registers regs; uint64_t actual;
            assert(xrt_target_registers(target, 1, &regs) == XRT_OK);
            assert(xrt_registers_value(&regs, "rax", 3, &actual) == XRT_OK && actual == (value == 10 ? 9 : value));
        }
        uint64_t bp_id = 0; before = generation(target);
        assert(xrt_target_breakpoint_set(target, 0x1000, false, &bp_id) == XRT_PERMISSION_DENIED);
        assert(generation(target) > before);
        assert(xrt_target_continue(target) == XRT_INVALID_STATE);
        assert(xrt_target_detach(target) == XRT_DETACH_INCOMPLETE);
        xrt_target_view(target, &view); assert(view.detach_pending && view.state == XRT_STOPPED);
        assert(xrt_target_detach(target) == XRT_OK);
        assert(xrt_target_destroy(target) == XRT_OK); finish(f);
    }
    puts("GDB model: unreliable write confirmations invalidate; missing step/thread capabilities, unsupported XML architecture, duplicate stops, uncertain breakpoint guard, retryable detach pass");
}
