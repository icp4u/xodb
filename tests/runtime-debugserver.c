/* Portable contract for the macOS bootstrap's inherited private transport. */
#define _GNU_SOURCE 1
#include "xrt_debugserver.h"
#include "gdb_link.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
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
    char request[64];
    size_t total = 0;
    while (total < sizeof(request) && !memmem(request, total, "$D#44", 5)) {
        ssize_t got = read(3, request + total, sizeof(request) - total);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return 14;
        total += (size_t)got;
    }
    if (!memmem(request, total, "$D#44", 5)) return 14;
    static const char reply[] = "+$OK#9a";
    if (write(3, reply, sizeof(reply) - 1) != sizeof(reply) - 1) return 15;
    for (int index = 1; index < argc; ++index)
        if (!strcmp(argv[index], "stubborn")) for (;;) pause();
    ssize_t used;
    do used = read(3, request, sizeof(request)); while (used < 0 && errno == EINTR);
    return used == 0 ? 0 : 16;
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

    /* D/OK makes it safe to terminate a targetless helper that does not exit
     * on its own. The unconfirmed close API deliberately has no such signal. */
    const char *stubborn[] = {"stubborn", NULL};
    options.argv = stubborn;
    assert(xrt_debugserver_start(&options, &child) == XRT_OK);
    link = (struct xrt_gdb_link){.fd = -1};
    assert(xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) == XRT_OK);
    assert(xrt_gdb_exchange(&link, "D", 1, reply, sizeof(reply), &length) == XRT_OK);
    assert(length == 2 && !memcmp(reply, "OK", 2));
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
    puts("debugserver bootstrap: inherited AF_UNIX transport, signal reset, detach ordering and prompt child exit passed");
    return 0;
}
