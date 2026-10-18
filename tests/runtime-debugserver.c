/* Portable contract for the macOS bootstrap's inherited private transport. */
#define _GNU_SOURCE 1
#include "xrt_debugserver.h"
#include "gdb_link.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

static uint64_t now_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static void send_all(int fd, const void *data, size_t size)
{
    size_t at = 0;
    while (at < size) {
        ssize_t n = send(fd, (const char *)data + at, size - at, MSG_NOSIGNAL);
        assert(n > 0);
        at += (size_t)n;
    }
}
static int request(int fd, char *out, size_t capacity)
{
    uint8_t wire[256]; size_t used = 0;
    for (;;) {
        ssize_t n = read(fd, wire + used, 1);
        if (n < 0 && errno == EINTR) continue;
        if (!n) return 0;
        assert(n == 1 && used + 1 < sizeof(wire));
        ++used;
        struct xrt_gdb_view view;
        enum xrt_gdb_decode_status decoded = xrt_gdb_decode(wire, used, (uint8_t *)out,
                                                            capacity - 1, &view);
        if (decoded == XRT_GDB_NEED_MORE) continue;
        assert(decoded == XRT_GDB_OK && view.consumed == used);
        used = 0;
        if (view.kind == XRT_GDB_ACK) continue;
        assert(view.kind == XRT_GDB_PACKET);
        send_all(fd, "+", 1);
        out[view.length] = 0;
        return 1;
    }
}
static void response(int fd, const char *text)
{
    uint8_t wire[256]; size_t size = 0;
    assert(xrt_gdb_encode((const uint8_t *)text, strlen(text), wire, sizeof(wire), &size) == XRT_GDB_OK);
    send_all(fd, wire, size);
}
static int acknowledged(int fd)
{
    char byte;
    ssize_t used;
    do used = read(fd, &byte, 1); while (used < 0 && errno == EINTR);
    return used == 1 && byte == '+';
}
static int fake_debugserver(int argc, char **argv)
{
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask)) return 10;
    if (sigismember(&mask, SIGTERM) || sigismember(&mask, SIGINT) || sigismember(&mask, SIGPIPE)) return 11;
    const int reset[] = {SIGTERM, SIGINT, SIGPIPE};
    for (size_t index = 0; index < sizeof(reset) / sizeof(reset[0]); ++index) {
        int signal_number = reset[index];
        struct sigaction action;
        if (sigaction(signal_number, NULL, &action) || action.sa_handler != SIG_DFL) return 12;
    }
    struct stat descriptor;
    if (fstat(3, &descriptor) || !S_ISSOCK(descriptor.st_mode)) return 13;
    for (int index = 1; index < argc; ++index)
        if (!strncmp(argv[index], "--attach", 8)) return 14;
    char packet[128];
    const int deferred_attach = argc == 3;
    if (deferred_attach) {
        if (!request(3, packet, sizeof(packet)) || strcmp(packet, "QSetDetachOnError:1")) return 15;
        response(3, "OK");
        if (!request(3, packet, sizeof(packet)) || strncmp(packet, "vAttach;", 8)) return 16;
        char *end = NULL;
        long target = strtol(packet + 8, &end, 16);
        if (!end || *end || target <= 0 || target > INT32_MAX) return 17;
        if (getenv("XODB_FAKE_ATTACH_HOLD")) {
            if (kill((pid_t)target, SIGSTOP)) return 18;
            char byte;
            ssize_t used;
            do used = read(3, &byte, 1); while (used < 0 && errno == EINTR);
            /* The owner can die with our packet ACK still unread. Linux then
             * reports ECONNRESET; Darwin commonly reports EOF. Both prove the
             * private owner transport is gone. */
            if (used > 0 || (used < 0 && errno != ECONNRESET) || kill((pid_t)target, SIGCONT)) return 19;
            return 0;
        }
        response(3, "T05thread:1;");
    }
    if (!request(3, packet, sizeof(packet)) || strcmp(packet, "D")) return 20;
    response(3, "OK");
    /* Do not let the helper exit between the final reply and its protocol ACK;
     * that would turn a valid D/OK exchange into a transport race. */
    if (!acknowledged(3)) return 21;
    for (int index = 1; index < argc; ++index)
        if (!strcmp(argv[index], "stubborn")) for (;;) pause();
    if (deferred_attach) return 0;
    ssize_t used;
    do used = read(3, packet, sizeof(packet)); while (used < 0 && errno == EINTR);
    return used == 0 ? 0 : 22;
}
static void exchange(struct xrt_gdb_link *link, const char *command, const char *expected)
{
    char reply[64]; size_t length = 0;
    enum xrt_status status = xrt_gdb_exchange(link, command, strlen(command), reply, sizeof(reply), &length);
    if (status != XRT_OK)
        fprintf(stderr, "debugserver exchange failed command=%s status=%d reason=%s\n", command, status, link->reason);
    assert(status == XRT_OK);
    assert(length == strlen(expected) && !memcmp(reply, expected, length));
}
static void deferred_attach(const char *self)
{
    struct xrt_debugserver child = {0};
    struct xrt_debugserver_options options = {.executable = self, .attach_pid = 42};
    assert(xrt_debugserver_start(&options, &child) == XRT_OK);
    struct xrt_gdb_link link = {.fd = -1};
    assert(xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) == XRT_OK);
    exchange(&link, "QSetDetachOnError:1", "OK");
    exchange(&link, "vAttach;2a", "T05thread:1;");
    exchange(&link, "D", "OK");
    assert(xrt_debugserver_wait(&child, 2000) == XRT_OK && child.pid == 0);
    xrt_gdb_disconnect(&link);
    assert(xrt_debugserver_close_detached(&child) == XRT_OK);
}
static int attach_owner(const char *self, pid_t target, int report_fd)
{
    if (setenv("XODB_FAKE_ATTACH_HOLD", "1", 1)) return 30;
    struct xrt_debugserver child = {0};
    struct xrt_debugserver_options options = {.executable = self, .attach_pid = target};
    if (xrt_debugserver_start(&options, &child) != XRT_OK) return 31;
    struct xrt_gdb_link link = {.fd = -1};
    if (xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) != XRT_OK) return 32;
    char reply[16]; size_t length = 0;
    if (xrt_gdb_exchange(&link, "QSetDetachOnError:1", 19, reply, sizeof(reply), &length) != XRT_OK ||
        length != 2 || memcmp(reply, "OK", 2)) return 33;
    char command[32];
    int size = snprintf(command, sizeof(command), "vAttach;%x", target);
    if (size <= 0 || (size_t)size >= sizeof(command) ||
        xrt_gdb_send(&link, command, (size_t)size) != XRT_OK) return 34;
    if (write(report_fd, &child.pid, sizeof(child.pid)) != sizeof(child.pid)) return 35;
    for (;;) pause();
}
static void owner_loss_during_attach(const char *self)
{
#ifdef __linux__
    assert(!prctl(PR_SET_CHILD_SUBREAPER, 1));
#endif
    atomic_uint_fast64_t *heartbeat = mmap(NULL, sizeof(*heartbeat), PROT_READ | PROT_WRITE,
                                           MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert(heartbeat != MAP_FAILED);
    atomic_init(heartbeat, 0);
    pid_t target = fork(); assert(target >= 0);
    if (!target) {
        for (;;) {
            atomic_fetch_add_explicit(heartbeat, 1, memory_order_relaxed);
            struct timespec pause = {0, 1000000};
            nanosleep(&pause, NULL);
        }
    }
    int report[2]; assert(!pipe(report));
    assert(fcntl(report[0], F_SETFD, FD_CLOEXEC) == 0);
    assert(fcntl(report[1], F_SETFD, FD_CLOEXEC) == 0);
    pid_t owner = fork(); assert(owner >= 0);
    if (!owner) {
        close(report[0]);
        _exit(attach_owner(self, target, report[1]));
    }
    close(report[1]);
    pid_t helper = 0;
    assert(read(report[0], &helper, sizeof(helper)) == sizeof(helper) && helper > 0);
    close(report[0]);
    int target_status = 0;
    uint64_t deadline = now_ms() + 5000;
    do {
        pid_t waited = waitpid(target, &target_status, WUNTRACED | WNOHANG);
        assert(waited == 0 || waited == target);
        if (waited == target && WIFSTOPPED(target_status)) break;
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    } while (now_ms() < deadline);
    assert(WIFSTOPPED(target_status));
    assert(!kill(owner, SIGKILL));
    int owner_status = 0;
    assert(waitpid(owner, &owner_status, 0) == owner && WIFSIGNALED(owner_status) && WTERMSIG(owner_status) == SIGKILL);
#ifdef __linux__
    int helper_status = 0;
    assert(waitpid(helper, &helper_status, 0) == helper && WIFEXITED(helper_status) && WEXITSTATUS(helper_status) == 0);
    assert(!prctl(PR_SET_CHILD_SUBREAPER, 0));
#else
    deadline = now_ms() + 5000;
    while (!kill(helper, 0) && now_ms() < deadline) {
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    assert(kill(helper, 0) && errno == ESRCH);
#endif
    uint64_t before = atomic_load_explicit(heartbeat, memory_order_relaxed);
    deadline = now_ms() + 5000;
    while (atomic_load_explicit(heartbeat, memory_order_relaxed) == before && now_ms() < deadline) {
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
    }
    assert(atomic_load_explicit(heartbeat, memory_order_relaxed) > before);
    assert(!kill(target, SIGTERM));
    (void)kill(target, SIGCONT);
    assert(waitpid(target, &target_status, 0) == target);
    assert(!munmap(heartbeat, sizeof(*heartbeat)));
}
int main(int argc, char **argv)
{
    if (argc > 1 && !strncmp(argv[1], "--fd=", 5)) return fake_debugserver(argc, argv);

    struct sigaction ignored = {.sa_handler = SIG_IGN}, old_term;
    sigemptyset(&ignored.sa_mask);
    assert(!sigaction(SIGTERM, &ignored, &old_term));
    sigset_t blocked, old_mask;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGINT);
    sigaddset(&blocked, SIGPIPE);
    assert(!sigprocmask(SIG_BLOCK, &blocked, &old_mask));

    const char *fixture[] = {"fixture", NULL};
    struct xrt_debugserver child = {0};
    struct xrt_debugserver_options options = {.executable = argv[0], .argv = fixture};
    assert(xrt_debugserver_start(&options, &child) == XRT_OK);
    assert(child.pid > 0 && child.transport > 0);
    struct xrt_gdb_link link = {.fd = -1};
    assert(xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) == XRT_OK);
    char reply[16]; size_t length = 0;
    enum xrt_status detached = xrt_gdb_exchange(&link, "D", 1, reply, sizeof(reply), &length);
    if (detached != XRT_OK) {
        int child_status = 0;
        pid_t waited = waitpid(child.pid, &child_status, WNOHANG);
        fprintf(stderr, "detach status=%d reason=%s waited=%d child_status=%d\n",
                detached, link.reason, (int)waited, child_status);
    }
    assert(detached == XRT_OK);
    assert(length == 2 && !memcmp(reply, "OK", 2));
    xrt_gdb_disconnect(&link);
    assert(xrt_debugserver_close_detached(&child) == XRT_OK && child.pid == 0 && child.transport == 0);

    // With the owner's stdin/stdout closed, socketpair returns 0 and 1: our end
    // must not be 0 ("no transport") and the child's must survive stdio setup.
    int saved_in = dup(0), saved_out = dup(1);
    assert(saved_in > 2 && saved_out > 2 && !close(0) && !close(1));
    enum xrt_status low = xrt_debugserver_start(&options, &child);
    int low_fd = child.transport;
    link = (struct xrt_gdb_link){.fd = -1};
    enum xrt_status low_adopt = low == XRT_OK ? xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) : low;
    enum xrt_status low_detach = low_adopt == XRT_OK ? xrt_gdb_exchange(&link, "D", 1, reply, sizeof(reply), &length) : low_adopt;
    xrt_gdb_disconnect(&link);
    enum xrt_status low_close = xrt_debugserver_close_detached(&child);
    assert(dup2(saved_in, 0) == 0 && dup2(saved_out, 1) == 1 && !close(saved_in) && !close(saved_out));
    assert(low == XRT_OK && low_fd > 2 && low_detach == XRT_OK && length == 2 && !memcmp(reply, "OK", 2));
    assert(low_close == XRT_OK && child.pid == 0);

    // With only stdin closed, the child's socket is already descriptor 3.
    // The spawn action must preserve it without clearing CLOEXEC in the owner.
    errno = 0;
    assert(fcntl(3, F_GETFD) == -1 && errno == EBADF);
    saved_in = fcntl(0, F_DUPFD_CLOEXEC, 4);
    assert(saved_in >= 4 && !close(0));
    low = xrt_debugserver_start(&options, &child);
    low_fd = child.transport;
    link = (struct xrt_gdb_link){.fd = -1};
    low_adopt = low == XRT_OK ? xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) : low;
    low_detach = low_adopt == XRT_OK ? xrt_gdb_exchange(&link, "D", 1, reply, sizeof(reply), &length) : low_adopt;
    xrt_gdb_disconnect(&link);
    low_close = xrt_debugserver_close_detached(&child);
    assert(dup2(saved_in, 0) == 0 && !close(saved_in));
    assert(low == XRT_OK && low_fd > 2 && low_detach == XRT_OK && length == 2 && !memcmp(reply, "OK", 2));
    assert(low_close == XRT_OK && child.pid == 0);

    /* D/OK makes it safe to terminate a targetless helper that does not exit
     * on its own. The unconfirmed close API deliberately has no such signal. */
    const char *stubborn[] = {"stubborn", NULL};
    options.argv = stubborn;
    assert(xrt_debugserver_start(&options, &child) == XRT_OK);
    link = (struct xrt_gdb_link){.fd = -1};
    assert(xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) == XRT_OK);
    assert(xrt_gdb_exchange(&link, "D", 1, reply, sizeof(reply), &length) == XRT_OK);
    assert(length == 2 && !memcmp(reply, "OK", 2));
    assert(xrt_debugserver_wait(&child, 50) == XRT_STOP_TIMEOUT && child.pid > 0);
    xrt_gdb_disconnect(&link);
    uint64_t cleanup_at = now_ms();
    assert(xrt_debugserver_close_detached(&child) == XRT_OK && child.pid == 0);
    assert(now_ms() - cleanup_at < 3000);

    assert(!sigaction(SIGTERM, &old_term, NULL));
    assert(!sigprocmask(SIG_SETMASK, &old_mask, NULL));
    options.argv = fixture;
    options.executable = "/bin/false";
    uint64_t before = now_ms();
    assert(xrt_debugserver_start(&options, &child) == XRT_EXEC_FAILED);
    assert(now_ms() - before < 1000 && child.pid == 0 && child.transport == 0);

    options.executable = argv[0];
    options.cancel = xrt_cancel_create();
    assert(options.cancel);
    xrt_cancel_request(options.cancel);
    assert(xrt_debugserver_start(&options, &child) == XRT_REMOTE_CANCELLED);
    xrt_cancel_release(options.cancel);
    deferred_attach(argv[0]);
    owner_loss_during_attach(argv[0]);
    puts("debugserver bootstrap: inherited AF_UNIX transport, closed-stdio descriptor placement, deferred attach after detach-on-error, detach ordering, attach-window owner loss and prompt child exit passed");
    return 0;
}
