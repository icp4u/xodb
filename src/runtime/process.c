#define _GNU_SOURCE 1
#include "xrt_process.h"
#include "xrt_arch.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static const int launch_signal_numbers[] = {SIGINT, SIGTERM, SIGHUP, SIGPIPE};
static struct sigaction launch_signals[4];
static bool have_launch_signals;

enum xrt_status xrt_process_save_launch_signals(void)
{
    struct sigaction actions[4];
    for (size_t i = 0; i < 4; ++i)
        if (sigaction(launch_signal_numbers[i], NULL, &actions[i]) < 0)
            return XRT_SIGNAL_FAILED;
    memcpy(launch_signals, actions, sizeof(actions));
    have_launch_signals = true;
    return XRT_OK;
}

enum xrt_status xrt_process_restore_launch_signals(void)
{
    if (!have_launch_signals)
        return XRT_OK;
    for (size_t i = 0; i < 4; ++i)
        if (sigaction(launch_signal_numbers[i], &launch_signals[i], NULL) < 0)
            return XRT_SIGNAL_FAILED;
    return XRT_OK;
}

uintptr_t xrt_process_options(bool owned, bool follow)
{
    /* Even with following disabled, hold children before they execute
     * inherited software traps. The coordinator decides adoption/release.
     * Every architecture is included so a software step on a non-x86 row
     * cannot leave a fork child with a planted successor. */
    const bool births = true;
    (void)follow;
    return PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT |
           (births ? PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACEVFORKDONE : 0) |
           (owned ? PTRACE_O_EXITKILL : 0);
}

/* Only used before releasing the launch gate: the child cannot have created
 * threads or descendants. Never consume another target's wait status. */
static void abort_launch(pid_t pid)
{
    kill(pid, SIGKILL);
    for (;;) {
        int status;
        const pid_t waited = waitpid(pid, &status, __WALL);
        if (waited < 0 && errno == EINTR)
            continue;
        if (waited < 0 || WIFEXITED(status) || WIFSIGNALED(status))
            return;
        if (WIFSTOPPED(status))
            ptrace(PTRACE_CONT, pid, (void *)0, (void *)(uintptr_t)SIGKILL);
    }
}

enum xrt_status xrt_process_launch(const char *const argv[], bool follow, int32_t *pid)
{
    if (!pid)
        return XRT_INVALID_ARGUMENT;
    *pid = 0;
    if (!argv || !argv[0])
        return XRT_INVALID_ARGUMENT;
    /* MSG_NOSIGNAL makes a dead gate reader an ordinary launch failure, even
     * when a plain C caller has not installed the debugger's SIGPIPE policy. */
    int gate[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, gate) < 0)
        return XRT_PIPE_FAILED;
    const pid_t child = fork();
    if (child < 0) {
        close(gate[0]);
        close(gate[1]);
        return XRT_FORK_FAILED;
    }
    if (child == 0) {
        close(gate[1]);
        unsigned char token = 0;
        ssize_t count;
        do {
            count = read(gate[0], &token, 1);
        } while (count < 0 && errno == EINTR);
        if (count != 1 || token != 1)
            _exit(126);
        close(gate[0]);
        if (xrt_process_restore_launch_signals() != XRT_OK)
            _exit(126);
        if (dup2(STDERR_FILENO, STDOUT_FILENO) < 0)
            _exit(126);
        const int input = open("/dev/null", O_RDONLY);
        if (input < 0 || dup2(input, STDIN_FILENO) < 0)
            _exit(126);
        if (input != STDIN_FILENO)
            close(input);
        execvp(argv[0], (char *const *)argv);
        _exit(127);
    }
    close(gate[0]);
    enum xrt_status result = XRT_OK;
    if (ptrace(PTRACE_SEIZE, child, (void *)0, (void *)xrt_process_options(true, follow)) < 0) {
        result = (errno == EPERM || errno == EACCES) ? XRT_PERMISSION_DENIED
                 : errno == ESRCH                    ? XRT_PROCESS_GONE
                                                     : XRT_PTRACE_FAILED;
    } else {
        const unsigned char token = 1;
        ssize_t count;
        do {
            count = send(gate[1], &token, 1, MSG_NOSIGNAL);
        } while (count < 0 && errno == EINTR);
        if (count != 1)
            result = XRT_PIPE_FAILED;
    }
    if (result != XRT_OK)
        abort_launch(child);
    close(gate[1]);
    if (result == XRT_OK)
        *pid = child;
    return result;
}

static enum xrt_status read_elf_ident(int32_t tid, unsigned char header[20])
{
    if (tid <= 0)
        return XRT_INVALID_ARGUMENT;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/exe", (int)tid);
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return XRT_TARGET_IMAGE_UNAVAILABLE;
    ssize_t count;
    do {
        count = pread(fd, header, 20, 0);
    } while (count < 0 && errno == EINTR);
    close(fd);
    if (count != 20)
        return XRT_TARGET_IMAGE_UNAVAILABLE;
    return XRT_OK;
}

static enum xrt_status classify_elf_header(const unsigned char header[20], const struct xrt_arch **out)
{
    if (memcmp(header, "\177ELF", 4) != 0)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    const struct xrt_arch *native = xrt_arch_native();
    const int class = header[4];
    const int data = header[5];
    const uint16_t machine =
        native && !native->little_endian
            ? (uint16_t)((uint16_t)header[19] | (uint16_t)header[18] << 8)
            : (uint16_t)((uint16_t)header[18] | (uint16_t)header[19] << 8);
    if (native && class == (native->address_bits == 32 ? 1 : 2) &&
        data == (native->little_endian ? 1 : 2) && machine == native->machine) {
        *out = native;
        return XRT_OK;
    }
#if defined(__x86_64__) && !defined(__ILP32__)
    const struct xrt_arch *compat = xrt_arch_get(XRT_I386);
    if (compat && class == 1 && data == 1 && machine == XRT_I386) {
        *out = compat;
        return XRT_OK;
    }
#endif
    return XRT_UNSUPPORTED_ARCHITECTURE;
}

enum xrt_status xrt_process_identify(int32_t tid, const struct xrt_arch **out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    unsigned char header[20];
    const enum xrt_status read = read_elf_ident(tid, header);
    if (read != XRT_OK)
        return read;
    return classify_elf_header(header, out);
}

static enum xrt_status identify_fd(int fd, const struct xrt_arch **out)
{
    unsigned char header[20];
    ssize_t count;
    do {
        count = pread(fd, header, 20, 0);
    } while (count < 0 && errno == EINTR);
    if (count != 20)
        return XRT_TARGET_IMAGE_UNAVAILABLE;
    return classify_elf_header(header, out);
}

enum xrt_status xrt_launch_image(const char *file, const struct xrt_arch **out)
{
    if (!file || !*file || !out)
        return XRT_INVALID_ARGUMENT;
    if (strchr(file, '/')) {
        const int fd = open(file, O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            return XRT_TARGET_IMAGE_UNAVAILABLE;
        const enum xrt_status status = identify_fd(fd, out);
        close(fd);
        return status;
    }
    const char *path = getenv("PATH");
    if (!path || !*path)
        path = "/usr/bin:/bin";
    enum xrt_status missing = XRT_TARGET_IMAGE_UNAVAILABLE;
    const char *at = path;
    while (*at) {
        const char *colon = strchr(at, ':');
        const size_t len = colon ? (size_t)(colon - at) : strlen(at);
        char full[4096];
        int wrote;
        if (len == 0)
            wrote = snprintf(full, sizeof(full), "%s", file);
        else
            wrote = snprintf(full, sizeof(full), "%.*s/%s", (int)len, at, file);
        if (wrote > 0 && (size_t)wrote < sizeof(full)) {
            const int fd = open(full, O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                const enum xrt_status status = identify_fd(fd, out);
                close(fd);
                return status;
            }
            if (errno != ENOENT)
                missing = XRT_TARGET_IMAGE_UNAVAILABLE;
        }
        if (!colon)
            break;
        at = colon + 1;
    }
    return missing;
}

enum xrt_status xrt_process_validate_native(int32_t tid)
{
    const struct xrt_arch *found = NULL;
    const enum xrt_status status = xrt_process_identify(tid, &found);
    if (status != XRT_OK)
        return status;
    if (!found || found != xrt_arch_native())
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return XRT_OK;
}

static bool parse_pid(const char *text, int32_t *out)
{
    char *end;
    errno = 0;
    const long value = strtol(text, &end, 10);
    if (errno || end == text || value < 0 || value > INT32_MAX)
        return false;
    while (*end == ' ' || *end == '\t')
        ++end;
    if (*end)
        return false;
    *out = (int32_t)value;
    return true;
}

enum xrt_status xrt_task_inspect(int32_t tid, struct xrt_task_info *out)
{
    if (tid <= 0 || !out)
        return XRT_INVALID_ARGUMENT;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/status", (int)tid);
    const int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT || errno == ESRCH)
            return XRT_PROCESS_GONE;
        if (errno == EACCES || errno == EPERM)
            return XRT_PERMISSION_DENIED;
        return XRT_TASK_INFO_UNAVAILABLE;
    }
    char bytes[4097];
    ssize_t count;
    do {
        count = read(fd, bytes, sizeof(bytes) - 1);
    } while (count < 0 && errno == EINTR);
    const int saved_errno = errno;
    close(fd);
    if (count <= 0)
        return count < 0 && saved_errno == ESRCH ? XRT_PROCESS_GONE : XRT_TASK_INFO_UNAVAILABLE;
    bytes[count] = 0;
    struct xrt_task_info info = {0};
    bool state = false, group = false, tracer = false;
    for (char *line = bytes, *end; (end = strchr(line, '\n')) != NULL; line = end + 1) {
        *end = 0;
        if (strncmp(line, "State:", 6) == 0) {
            const char *value = line + 6;
            while (*value == ' ' || *value == '\t')
                ++value;
            info.state = *value;
            state = *value != 0;
        } else if (strncmp(line, "Tgid:", 5) == 0) {
            group = parse_pid(line + 5, &info.group);
        } else if (strncmp(line, "TracerPid:", 10) == 0) {
            tracer = parse_pid(line + 10, &info.tracer);
        }
    }
    if (!state || !group || !tracer)
        return XRT_TASK_INFO_UNAVAILABLE;
    *out = info;
    return XRT_OK;
}

enum xrt_status xrt_signal_read(int32_t tid, struct xrt_signal_info *out)
{
    if (tid <= 0 || !out)
        return XRT_INVALID_ARGUMENT;
    siginfo_t raw;
    if (ptrace(PTRACE_GETSIGINFO, tid, (void *)0, &raw) < 0) {
        if (errno == EPERM || errno == EACCES)
            return XRT_PERMISSION_DENIED;
        if (errno == ESRCH)
            return XRT_PROCESS_GONE;
        return XRT_PTRACE_FAILED;
    }
    struct xrt_signal_info info = {
        .number = raw.si_signo, .code = raw.si_code, .error_number = raw.si_errno};
    if (raw.si_code == SI_USER || raw.si_code == SI_QUEUE || raw.si_code == SI_TKILL) {
        info.sender = raw.si_pid;
        info.has_sender = true;
    }
    if (raw.si_code > 0 &&
        (raw.si_signo == SIGILL || raw.si_signo == SIGFPE || raw.si_signo == SIGSEGV ||
         raw.si_signo == SIGBUS || raw.si_signo == SIGTRAP)) {
        info.address = (uintptr_t)raw.si_addr;
        info.has_address = true;
    }
    *out = info;
    return XRT_OK;
}
