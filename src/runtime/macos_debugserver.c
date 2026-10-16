/* Apple's debugserver remains the debugger. This component owns only its
 * process and initial endpoint discovery, not a second run-control path. */
#include "xrt_debugserver.h"
#include "host_compat.h"
#include <crt_externs.h>
#include <poll.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <signal.h>

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
static int spawn(const char *path, char *const *argv, int output, pid_t *pid)
{
    posix_spawn_file_actions_t actions;
    int status = posix_spawn_file_actions_init(&actions);
    if (status) return status;
    status = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!status) status = output >= 0 ? posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) :
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    if (!status) status = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    // Helpers must not inherit the session's IPC sockets or other open files.
    posix_spawnattr_t attr;
    int attr_status = posix_spawnattr_init(&attr);
    if (!status) status = attr_status;
    if (!status) status = posix_spawnattr_setpgroup(&attr, 0);
    if (!status) status = posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP);
    if (!status) status = posix_spawn(pid, path, &actions, &attr, argv, *_NSGetEnviron());
    if (!attr_status) posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    return status;
}
static enum xrt_status reap(struct xrt_debugserver *child, uint64_t until)
{
    while (child->pid > 0) {
        int status;
        pid_t result = waitpid(child->pid, &status, WNOHANG);
        if (result == child->pid || (result < 0 && errno == ECHILD)) {
            child->pid = 0; child->endpoint[0] = 0; return XRT_OK;
        }
        if (result < 0 && errno != EINTR) return XRT_WAIT_FAILED;
        if (milliseconds() >= until) return XRT_STOP_TIMEOUT;
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    return XRT_OK;
}
enum xrt_status xrt_debugserver_close(struct xrt_debugserver *child)
{
    if (!child) return XRT_INVALID_ARGUMENT;
    if (child->pid <= 0) return XRT_OK;
    enum xrt_status status = reap(child, milliseconds() + 100);
    if (status != XRT_STOP_TIMEOUT) return status;
    // The owner closes/detaches through GDB first. Signal only our helper,
    // never a target pid or a process group.
    if (kill(child->pid, SIGTERM) && errno != ESRCH) return XRT_SIGNAL_FAILED;
    // Do not force-kill a debugger that may still own an attached process.
    // Preserve the pid if cleanup cannot be confirmed by the deadline.
    return reap(child, milliseconds() + 2000);
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
    int status = spawn(args[0], args, pipefd[1], &child.pid);
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
    if (!options || !out || out->pid || !options->directory || !*options->directory ||
        options->attach_pid < 0 || ((options->attach_pid > 0) == (options->argv != NULL))) return XRT_INVALID_ARGUMENT;
    out->endpoint[0] = 0;
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
    // The caller supplies its private work root. A fresh mode-0700 child owns
    // the Unix handshake; there is no shared fixed filename or port reservation.
    char directory[sizeof(((struct sockaddr_un *)0)->sun_path)];
    int length = snprintf(directory, sizeof(directory), "%s/xodb-ds.XXXXXX", options->directory);
    if (length < 0 || (size_t)length + sizeof("/port") > sizeof(directory)) return XRT_BUFFER_TOO_SMALL;
    if (!mkdtemp(directory)) return XRT_FILE_UNAVAILABLE;
    char path[sizeof(directory)];
    snprintf(path, sizeof(path), "%s/port", directory);
    int listener = xrt_host_socket(AF_UNIX, SOCK_STREAM, 0, 1), peer = -1;
    enum xrt_status result = XRT_TRANSPORT_FAILED;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    memcpy(address.sun_path, path, strlen(path) + 1);
    address.sun_len = (uint8_t)SUN_LEN(&address);
    if (listener < 0 || bind(listener, (struct sockaddr *)&address, address.sun_len) || listen(listener, 1)) goto done;
    char attach[32];
    snprintf(attach, sizeof(attach), "--attach=%d", options->attach_pid);
    char *args[264]; size_t n = 0;
    args[n++] = (char *)executable;
    args[n++] = "--unix-socket"; args[n++] = path;
    args[n++] = "--no-stdio";
    if (options->attach_pid) args[n++] = attach;
    args[n++] = "--";
    args[n++] = "127.0.0.1:0";
    for (size_t i = 0; i < argc; ++i) args[n++] = (char *)options->argv[i];
    args[n] = NULL;
    if (spawn(executable, args, -1, &out->pid)) { result = XRT_EXEC_FAILED; goto done; }
    uint64_t deadline = milliseconds() + 10000;
    result = wait_read(listener, deadline, options->cancel);
    if (result != XRT_OK) goto done;
    peer = xrt_host_flags(accept(listener, NULL, NULL), 1);
    if (peer < 0) { result = XRT_TRANSPORT_FAILED; goto done; }
    char port[6]; size_t used = 0;
    for (;;) {
        result = wait_read(peer, deadline, options->cancel);
        if (result != XRT_OK) goto done;
        ssize_t got = read(peer, port + used, sizeof(port) - used);
        if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (got < 0) { result = XRT_TRANSPORT_FAILED; goto done; }
        if (!got) break;
        used += (size_t)got;
        if (used == sizeof(port)) { result = XRT_PROTOCOL_ERROR; goto done; }
    }
    unsigned number = 0;
    for (size_t i = 0; i < used; ++i) {
        if (port[i] < '0' || port[i] > '9') { result = XRT_PROTOCOL_ERROR; goto done; }
        number = number * 10 + (unsigned)(port[i] - '0');
    }
    if (!number || number > 65535) { result = XRT_PROTOCOL_ERROR; goto done; }
    snprintf(out->endpoint, sizeof(out->endpoint), "127.0.0.1:%u", number);
    result = XRT_OK;
done:
    if (peer >= 0) close(peer);
    if (listener >= 0) close(listener);
    unlink(path); rmdir(directory); // Only this call's fresh handshake files.
    if (result != XRT_OK) {
        enum xrt_status cleanup = xrt_debugserver_close(out);
        if (cleanup != XRT_OK) return cleanup;
    }
    return result;
}
