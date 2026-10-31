/* Apple's debugserver remains the debugger. This component owns only its
 * process and private inherited transport, not a second run-control path. */
#define _GNU_SOURCE 1
#include "xrt_debugserver.h"
#include "host_compat.h"
#ifdef __APPLE__
#include <crt_externs.h>
#endif
#include <poll.h>
#include <stdint.h>
#include <spawn.h>

int xrt_spawn_owned_helper(int32_t *pid, int (*create)(int32_t *pid, void *context), void *context);
void xrt_drop_owned_helper(int32_t pid);
static char **environment(void);

struct debugserver_spawn {
    const char *path;
    char *const *argv;
    posix_spawn_file_actions_t *actions;
    posix_spawnattr_t *attr;
};

static int debugserver_create(int32_t *out, void *context)
{
    struct debugserver_spawn *spawn = context;
    pid_t child = 0;
    /* spawn-allow: create callback of xrt_spawn_owned_helper */
    int status = posix_spawn(&child, spawn->path, spawn->actions, spawn->attr, spawn->argv, environment());
    if (status)
        return status;
    *out = (int32_t)child;
    return 0;
}
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <signal.h>

#define DEBUGSERVER_FD 3

#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0
#endif

static char **environment(void)
{
#ifdef __APPLE__
    return *_NSGetEnviron();
#else
    extern char **environ;
    return environ;
#endif
}
static uint64_t milliseconds(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static enum xrt_status wait_read(int fd, uint64_t until, struct xrt_cancel *cancel)
{
    for (;;) {
        if (xrt_cancel_requested(cancel)) return XRT_REMOTE_CANCELLED;
        uint64_t now = milliseconds();
        if (now >= until) return XRT_STOP_TIMEOUT;
        struct pollfd fds[2] = {{fd, POLLIN, 0}, {xrt_cancel_fd(cancel), POLLIN, 0}};
        int result = poll(fds, cancel ? 2 : 1, (int)(until - now));
        if (result < 0 && errno == EINTR) continue;
        if (xrt_cancel_requested(cancel)) return XRT_REMOTE_CANCELLED;
        if (result < 0) return XRT_TRANSPORT_FAILED;
        if (!result) return XRT_STOP_TIMEOUT;
        if (fds[0].revents & (POLLIN | POLLHUP)) return XRT_OK;
        return XRT_TRANSPORT_FAILED;
    }
}
/* A spawn dup2 onto the same number leaves close-on-exec set, and
 * POSIX_SPAWN_CLOEXEC_DEFAULT then closes it in the child. Darwin can mark the
 * descriptor inherited directly. The portable component test instead gives
 * dup2 a private source number, without clearing CLOEXEC in the parent. */
static int place(posix_spawn_file_actions_t *actions, int fd, int target, int *temporary)
{
    *temporary = -1;
    if (fd == target) {
#ifdef __APPLE__
        return posix_spawn_file_actions_addinherit_np(actions, fd);
#else
        int moved = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        if (moved < 0) return errno ? errno : EBADF;
        *temporary = moved;
        fd = moved;
#endif
    }
    return posix_spawn_file_actions_adddup2(actions, fd, target);
}
static int spawn_child(const char *path, char *const *argv, int output, int inherited, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return status;
    int output_copy = -1, inherited_copy = -1;
    /* Duplicate first: with the owner's stdio closed, output or inherited may
     * be 0..2, and the /dev/null opens below would replace them. */
    if (!status && inherited >= 0)
        status = place(&actions, inherited, DEBUGSERVER_FD, &inherited_copy);
    if (!status && output >= 0)
        status = place(&actions, output, STDOUT_FILENO, &output_copy);
    if (!status) status = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!status && output < 0)
        status = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    if (!status) status = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    posix_spawnattr_t attr;
    int attr_status = posix_spawnattr_init(&attr);
    if (!status) status = attr_status;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGPIPE);
    if (!status) status = posix_spawnattr_setpgroup(&attr, 0);
    if (!status) status = posix_spawnattr_setsigmask(&attr, &empty);
    if (!status) status = posix_spawnattr_setsigdefault(&attr, &defaults);
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
        POSIX_SPAWN_CLOEXEC_DEFAULT;
    if (!status) status = posix_spawnattr_setflags(&attr, flags);
    if (!status) {
        int32_t spawned = 0;
        struct debugserver_spawn spawn = { path, argv, &actions, &attr };
        status = xrt_spawn_owned_helper(&spawned, debugserver_create, &spawn);
        if (!status)
            *pid = (pid_t)spawned;
    }
    if (!attr_status) posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    if (output_copy >= 0) close(output_copy);
    if (inherited_copy >= 0) close(inherited_copy);
    return status;
}
static enum xrt_status reap(struct xrt_debugserver *child, uint64_t until)
{
    while (child->pid > 0) {
        int status;
        pid_t result = waitpid(child->pid, &status, WNOHANG);
        if (result == child->pid || (result < 0 && errno == ECHILD)) {
            if (child->pid > 1)
                xrt_drop_owned_helper((int32_t)child->pid);
            child->pid = 0;
            return XRT_OK;
        }
        if (result < 0 && errno != EINTR) return XRT_WAIT_FAILED;
        if (milliseconds() >= until) return XRT_STOP_TIMEOUT;
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    return XRT_OK;
}
/* Catch exec and argument failures promptly without inventing a readiness byte
 * that Apple's --fd protocol does not provide. A live launch may still be
 * loading when this short observation ends; the first GDB request then reports
 * any later failure directly through the private stream. */
static enum xrt_status early_exit(struct xrt_debugserver *child, struct xrt_cancel *cancel)
{
    uint64_t until = milliseconds() + 100;
    while (milliseconds() < until) {
        if (xrt_cancel_requested(cancel)) return XRT_REMOTE_CANCELLED;
        int status;
        pid_t result = waitpid(child->pid, &status, WNOHANG);
        if (result == child->pid || (result < 0 && errno == ECHILD)) {
            if (child->pid > 1)
                xrt_drop_owned_helper((int32_t)child->pid);
            child->pid = 0;
            return XRT_EXEC_FAILED;
        }
        if (result < 0 && errno != EINTR) return XRT_WAIT_FAILED;
        struct pollfd fds[2] = {{child->transport, POLLIN, 0}, {xrt_cancel_fd(cancel), POLLIN, 0}};
        int polled = poll(fds, cancel ? 2 : 1, 10);
        if (polled < 0 && errno == EINTR) continue;
        if (polled < 0) return XRT_TRANSPORT_FAILED;
        if (xrt_cancel_requested(cancel)) return XRT_REMOTE_CANCELLED;
        if (fds[0].revents & (POLLHUP | POLLERR | POLLNVAL)) {
            (void)reap(child, milliseconds() + 100);
            return XRT_EXEC_FAILED;
        }
        if (fds[0].revents & POLLIN) return XRT_OK;
    }
    return XRT_OK;
}
int xrt_debugserver_take_transport(struct xrt_debugserver *child)
{
    if (!child || child->transport <= 0) return -1;
    int fd = child->transport;
    child->transport = 0;
    return fd;
}
static enum xrt_status close_child(struct xrt_debugserver *child, int detach_confirmed)
{
    if (!child) return XRT_INVALID_ARGUMENT;
    if (child->transport > 0) {
        close(child->transport);
        child->transport = 0;
    }
    if (child->pid <= 0) return XRT_OK;
    /* Without D/OK, EOF is the only safe release: killing debugserver while
     * it still owns an attached process can kill that process on Darwin. */
    enum xrt_status status = reap(child, milliseconds() + (detach_confirmed ? 100 : 10000));
    if (status != XRT_STOP_TIMEOUT || !detach_confirmed) return status;
    /* D/OK is the protocol proof that the target is no longer owned. Some
     * Apple debugserver builds remain alive after it; terminate only that
     * exact, now targetless helper and retain its pid if reaping still fails. */
    if (kill(child->pid, SIGTERM) && errno != ESRCH) return XRT_SIGNAL_FAILED;
    return reap(child, milliseconds() + 2000);
}
enum xrt_status xrt_debugserver_wait(struct xrt_debugserver *child, uint32_t timeout_ms)
{
    if (!child) return XRT_INVALID_ARGUMENT;
    return reap(child, milliseconds() + timeout_ms);
}
enum xrt_status xrt_debugserver_close(struct xrt_debugserver *child)
{
    return close_child(child, 0);
}
enum xrt_status xrt_debugserver_close_detached(struct xrt_debugserver *child)
{
    return close_child(child, 1);
}
enum xrt_status xrt_debugserver_find(char *out, size_t capacity, struct xrt_cancel *cancel)
{
    if (!out || !capacity) return XRT_INVALID_ARGUMENT;
    out[0] = 0;
    if (xrt_cancel_requested(cancel)) return XRT_REMOTE_CANCELLED;
    int pipefd[2];
    if (xrt_host_pipe(pipefd)) return XRT_PIPE_FAILED;
    char *args[] = {"/usr/bin/xcode-select", "-p", NULL};
    struct xrt_debugserver child = {0};
    int status = spawn_child(args[0], args, pipefd[1], -1, &child.pid);
    close(pipefd[1]);
    if (status) { close(pipefd[0]); return XRT_EXEC_FAILED; }
    char selected[4096]; size_t used = 0;
    uint64_t deadline = milliseconds() + 5000;
    enum xrt_status result = XRT_OK;
    for (;;) {
        result = wait_read(pipefd[0], deadline, cancel);
        if (result != XRT_OK) break;
        ssize_t n = read(pipefd[0], selected + used, sizeof(selected) - 1 - used);
        if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (n < 0) { result = XRT_TRANSPORT_FAILED; break; }
        if (!n) break;
        used += (size_t)n;
        if (used == sizeof(selected) - 1) { result = XRT_BUFFER_TOO_SMALL; break; }
    }
    close(pipefd[0]);
    enum xrt_status cleanup = xrt_debugserver_close(&child);
    if (cleanup != XRT_OK) return cleanup;
    if (result != XRT_OK) return result;
    while (used && (selected[used - 1] == '\n' || selected[used - 1] == '\r')) --used;
    selected[used] = 0;
    if (!used || selected[0] != '/') return XRT_FILE_UNAVAILABLE;
    int length = snprintf(out, capacity, "%s/../SharedFrameworks/LLDB.framework/Resources/debugserver", selected);
    if (length < 0 || (size_t)length >= capacity) { out[0] = 0; return XRT_BUFFER_TOO_SMALL; }
    if (access(out, X_OK)) { out[0] = 0; return XRT_FILE_UNAVAILABLE; }
    return XRT_OK;
}
enum xrt_status xrt_debugserver_start(const struct xrt_debugserver_options *options, struct xrt_debugserver *out)
{
    if (!options || !out || out->pid || out->transport ||
        options->attach_pid < 0 || ((options->attach_pid > 0) == (options->argv != NULL))) return XRT_INVALID_ARGUMENT;
    if (xrt_cancel_requested(options->cancel)) return XRT_REMOTE_CANCELLED;
    size_t argc = 0;
    if (options->argv) {
        while (argc < 256 && options->argv[argc]) ++argc;
        if (!argc || !*options->argv[0]) return XRT_INVALID_ARGUMENT;
        if (argc == 256) return XRT_TOO_MANY_ARGUMENTS;
    }
    char discovered[4096];
    const char *executable = options->executable;
    if (!executable) {
        enum xrt_status found = xrt_debugserver_find(discovered, sizeof(discovered), options->cancel);
        if (found != XRT_OK) return found;
        executable = discovered;
    }
    int transport[2];
    if (xrt_host_socketpair(AF_UNIX, SOCK_STREAM, 0, transport)) return XRT_TRANSPORT_FAILED;
    /* 0 means "no transport" in struct xrt_debugserver; keep our end off stdio. */
    if (transport[0] <= STDERR_FILENO) {
        int moved = fcntl(transport[0], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        close(transport[0]);
        if (moved < 0) { close(transport[1]); return XRT_TRANSPORT_FAILED; }
        transport[0] = moved;
    }
    char fd_option[32];
    snprintf(fd_option, sizeof(fd_option), "--fd=%d", DEBUGSERVER_FD);
    char *args[264]; size_t n = 0;
    args[n++] = (char *)executable;
    args[n++] = fd_option;
    args[n++] = "--no-stdio";
    /* Attach is deliberately not a command-line action. The GDB owner first
     * enables detach-on-error, then sends vAttach while debugserver's packet
     * read thread is already watching this private stream. */
    if (options->argv) {
        args[n++] = "--";
        for (size_t i = 0; i < argc; ++i) args[n++] = (char *)options->argv[i];
    }
    args[n] = NULL;
    int spawned = spawn_child(executable, args, -1, transport[1], &out->pid);
    close(transport[1]);
    if (spawned) { close(transport[0]); return XRT_EXEC_FAILED; }
    out->transport = transport[0];
    enum xrt_status result = early_exit(out, options->cancel);
    if (result != XRT_OK) {
        enum xrt_status cleanup = xrt_debugserver_close(out);
        if (cleanup != XRT_OK) return cleanup;
    }
    return result;
}
