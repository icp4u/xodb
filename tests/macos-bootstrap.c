/* Opt-in native lifecycle test. Only this fixture and its own helper/children. */
#include "check.h"
#include "xrt_debugserver.h"
#include "gdb_link.h"
#include "xrt_log.h"
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

static uint64_t now_ms(void)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}
static int heartbeat_advanced(int fd, uint64_t before)
{
    uint64_t deadline = now_ms() + 5000;
    do {
        uint64_t value = 0;
        if (pread(fd, &value, sizeof(value), 0) == sizeof(value) && value > before) return 1;
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    } while (now_ms() < deadline);
    return 0;
}

static int query(struct xrt_gdb_link *link, const char *request, char *reply, size_t capacity)
{
    size_t length = 0;
    enum xrt_status status = xrt_gdb_exchange(link, request, strlen(request), reply, capacity - 1, &length);
    xrt_log(XRT_LOG_DEBUG, XRT_LOG_RUNTIME, "bootstrap query %s status=%d\n", request, status);
    if (status != XRT_OK) return 0;
    reply[length] = 0;
    return 1;
}
static int loopback_listener(const struct xrt_debugserver *child)
{
    char command[128], expected[64], line[256];
    // Only a numeric pid returned by our own spawn, never a target-supplied command.
    snprintf(command, sizeof(command), "/usr/sbin/lsof -nP -a -p %d -iTCP -sTCP:LISTEN -Fn", child->pid);
    snprintf(expected, sizeof(expected), "n%s\n", child->endpoint);
    FILE *stream = popen(command, "r");
    if (!stream) return 0;
    unsigned matching = 0, other = 0;
    while (fgets(line, sizeof(line), stream)) if (line[0] == 'n') {
        if (!strcmp(line, expected)) ++matching; else ++other;
    }
    int status = pclose(stream);
    return status == 0 && matching == 1 && other == 0;
}
static int exercise(const char *self, int attach)
{
    struct xrt_debugserver child = {0};
    struct xrt_gdb_link *link = calloc(1, sizeof(*link));
    if (!link) return 0;
    link->fd = -1;
    pid_t target = 0;
    int passed = 0, detached = 0;
    char heartbeat[] = ".work/bootstrap-heartbeat.XXXXXX";
    int heartbeat_fd = mkstemp(heartbeat);
    if (heartbeat_fd < 0) { free(link); return 0; }
    (void)fcntl(heartbeat_fd, F_SETFD, FD_CLOEXEC);
    uint64_t before = 0;
    char *args[] = {(char *)self, "--fixture", heartbeat, NULL};
    if (attach) {
        posix_spawnattr_t attr;
        if (posix_spawnattr_init(&attr)) goto done;
        int status = posix_spawnattr_setpgroup(&attr, 0);
        if (!status) status = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
        if (!status) status = posix_spawn(&target, self, NULL, &attr, args, *_NSGetEnviron());
        posix_spawnattr_destroy(&attr);
        if (status) goto done;
    }
    struct xrt_debugserver_options options = {.directory = ".work", .attach_pid = target,
        .argv = attach ? NULL : (const char *const *)args};
    enum xrt_status started = xrt_debugserver_start(&options, &child);
    xrt_log(XRT_LOG_DEBUG, XRT_LOG_RUNTIME, "bootstrap started attach=%d status=%d\n", attach, started);
    if (started != XRT_OK) { xrt_log(XRT_LOG_ERROR, XRT_LOG_RUNTIME, "bootstrap start status=%d\n", started); goto done; }
    if (strncmp(child.endpoint, "127.0.0.1:", 10) || !child.pid) goto done;
    if (getpgid(child.pid) != child.pid || getpgid(child.pid) == getpgrp()) goto done;
    if (!loopback_listener(&child)) goto done;
    if (attach == 3) {
        (void)pread(heartbeat_fd, &before, sizeof(before), 0);
        passed = 1;
        goto done; // Cancel after bootstrap, before the GDB client connects.
    }
    if (xrt_gdb_connect(link, child.endpoint, NULL) != XRT_OK) goto done;
    char reply[8192];
    if (!query(link, "qSupported", reply, sizeof(reply))) goto done;
    if (!query(link, "qProcessInfo", reply, sizeof(reply))) goto done;
    char *pid_text = strstr(reply, "pid:");
    if (!pid_text) goto done;
    char *end;
    unsigned long pid = strtoul(pid_text + 4, &end, 16);
    if (*end != ';' || !pid || pid > INT_MAX || (target && target != (pid_t)pid)) goto done;
    target = (pid_t)pid;
    if (!query(link, "?", reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S')) goto done;
    if (!query(link, "qAttached", reply, sizeof(reply))) goto done;
    xrt_log(XRT_LOG_DEBUG, XRT_LOG_RUNTIME, "bootstrap qAttached=%s\n", reply);
    // This debugserver may not implement qAttached (empty reply). The spawned
    // child's pid match above, not this optional packet, proves the attach.
    if (*reply && strcmp(reply, "0") && strcmp(reply, "1")) goto done;
    if (attach && *reply && strcmp(reply, "1")) goto done;
    // A real instruction step through the existing packet/link implementation.
    if (!query(link, "s", reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S')) goto done;
    (void)pread(heartbeat_fd, &before, sizeof(before), 0);
    if (attach != 2) {
        if (!query(link, "D", reply, sizeof(reply)) || strcmp(reply, "OK")) goto done;
        detached = 1;
    }
    passed = kill(target, 0) == 0; // Detach must preserve both launched and attached targets.
done:
    if (link->fd >= 0 && !detached && attach != 2) {
        char reply[8192];
        (void)query(link, "D", reply, sizeof(reply));
    }
    xrt_gdb_disconnect(link); free(link);
    if (xrt_debugserver_close(&child) != XRT_OK || child.pid != 0) passed = 0;
    if (target > 0 && kill(target, 0)) passed = 0;
    // kill(pid, 0) also succeeds for a zombie. Prove the detached target runs.
    if (passed && !heartbeat_advanced(heartbeat_fd, before)) passed = 0;
    if (target > 0) {
        if (kill(target, SIGTERM) && errno != ESRCH) passed = 0;
        (void)kill(target, SIGCONT); // An owned test fixture may be job-control stopped.
        if (attach) {
            int status;
            while (waitpid(target, &status, 0) < 0 && errno == EINTR) {}
        } else {
            uint64_t deadline = now_ms() + 5000;
            while (!kill(target, 0) && now_ms() < deadline) {
                struct timespec pause = {0, 10000000};
                nanosleep(&pause, NULL);
            }
            if (!kill(target, 0) || errno != ESRCH) passed = 0;
        }
    }
    close(heartbeat_fd); unlink(heartbeat);
    return passed;
}
int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--fixture")) {
        int fd = open(argv[2], O_WRONLY);
        if (fd < 0) return 1;
        for (uint64_t i = 1; i <= 600; ++i) {
            if (pwrite(fd, &i, sizeof(i), 0) != sizeof(i)) break;
            struct timespec pause = {0, 100000000};
            nanosleep(&pause, NULL);
        }
        close(fd);
        return 0;
    }
    CHECK(argc == 1); // Planted negative runs before creating any child.
    signal(SIGPIPE, SIG_IGN);
    CHECK(!mkdir(".work", 0755) || errno == EEXIST);
    char executable[4096];
    CHECK(xrt_debugserver_find(executable, sizeof(executable), NULL) == XRT_OK);
    struct xrt_debugserver child = {0};
    const char *args[] = {argv[0], "--fixture", NULL};
    struct xrt_debugserver_options options = {.executable = "/no/such/debugserver", .directory = ".work", .argv = args};
    CHECK(xrt_debugserver_start(&options, &child) == XRT_EXEC_FAILED && !child.pid);
    options.executable = executable;
    options.attach_pid = 1;
    CHECK(xrt_debugserver_start(&options, &child) == XRT_INVALID_ARGUMENT && !child.pid);
    options.attach_pid = 0;
    options.cancel = xrt_cancel_create();
    CHECK(options.cancel);
    xrt_cancel_request(options.cancel);
    CHECK(xrt_debugserver_start(&options, &child) == XRT_REMOTE_CANCELLED && !child.pid);
    xrt_cancel_release(options.cancel);
    CHECK(exercise(argv[0], 0));
    CHECK(exercise(argv[0], 1));
    CHECK(exercise(argv[0], 2)); // Lost transport must not kill an attached target.
    CHECK(exercise(argv[0], 3)); // Neither may a pre-connect startup cancellation.
    puts("native debugserver bootstrap: discovery, launch, attach, loopback endpoint, instruction step, detach, helper reap and startup refusal passed");
    return 0;
}
