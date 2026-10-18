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
static int heartbeat_stalled(int fd)
{
    uint64_t value = 0, last = 0, unchanged_at = now_ms(), deadline = now_ms() + 5000;
    if (pread(fd, &last, sizeof(last), 0) != sizeof(last)) return 0;
    while (now_ms() < deadline) {
        struct timespec pause = {0, 1000000};
        nanosleep(&pause, NULL);
        if (pread(fd, &value, sizeof(value), 0) != sizeof(value)) return 0;
        if (value != last) { last = value; unchanged_at = now_ms(); }
        else if (now_ms() - unchanged_at >= 25) return 1;
    }
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
static int no_tcp_listener(const struct xrt_debugserver *child)
{
    char command[128], line[256];
    if (child->pid <= 0 || access("/usr/sbin/lsof", X_OK) || kill(child->pid, 0)) return 0;
    // Only a numeric pid returned by our own spawn, never a target-supplied command.
    // Listing all files makes exit 0 prove lsof observed the helper; a filtered
    // empty selection exits 1 on macOS and cannot make that distinction.
    snprintf(command, sizeof(command), "/usr/sbin/lsof -nP -p %d -FnT 2>/dev/null", child->pid);
    FILE *stream = popen(command, "r");
    if (!stream) return 0;
    unsigned listeners = 0;
    while (fgets(line, sizeof(line), stream)) if (!strcmp(line, "TST=LISTEN\n")) ++listeners;
    int status = pclose(stream);
    return listeners == 0 && status >= 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
static int discovery_with_closed_stdio(const char *expected)
{
    int saved_in = dup(STDIN_FILENO), saved_out = dup(STDOUT_FILENO);
    if (saved_in <= STDERR_FILENO || saved_out <= STDERR_FILENO) {
        if (saved_in >= 0) close(saved_in);
        if (saved_out >= 0) close(saved_out);
        return 0;
    }
    int closed = !close(STDIN_FILENO) && !close(STDOUT_FILENO);
    char found[4096];
    enum xrt_status status = closed ? xrt_debugserver_find(found, sizeof(found), NULL) : XRT_TRANSPORT_FAILED;
    int restored_in = dup2(saved_in, STDIN_FILENO) == STDIN_FILENO;
    int restored_out = dup2(saved_out, STDOUT_FILENO) == STDOUT_FILENO;
    close(saved_in); close(saved_out);
    return restored_in && restored_out && status == XRT_OK && !strcmp(found, expected);
}
static int exercise(const char *self, int attach)
{
    struct xrt_debugserver child = {0};
    struct xrt_gdb_link *link = calloc(1, sizeof(*link));
    if (!link) return 0;
    link->fd = -1;
    pid_t target = 0;
    int passed = 0, detached = 0;
    const char *awaited = "owned fixture startup";
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
    struct xrt_debugserver_options options = {.attach_pid = target,
        .argv = attach ? NULL : (const char *const *)args};
    enum xrt_status started = xrt_debugserver_start(&options, &child);
    xrt_log(XRT_LOG_DEBUG, XRT_LOG_RUNTIME, "bootstrap started attach=%d status=%d\n", attach, started);
    awaited = "private debugserver startup";
    if (started != XRT_OK) { xrt_log(XRT_LOG_ERROR, XRT_LOG_RUNTIME, "bootstrap start status=%d\n", started); goto done; }
    awaited = "inherited Unix transport and helper process";
    if (child.transport <= 0 || !child.pid) goto done;
    if (getpgid(child.pid) != child.pid || getpgid(child.pid) == getpgrp()) goto done;
    awaited = "no debugserver TCP listener";
    if (!no_tcp_listener(&child)) goto done;
    if (attach == 3) {
        (void)pread(heartbeat_fd, &before, sizeof(before), 0);
        passed = 1;
        goto done; // Cancel after bootstrap, before the GDB client connects.
    }
    awaited = "GDB adoption of the private descriptor";
    if (xrt_gdb_adopt(link, xrt_debugserver_take_transport(&child), NULL) != XRT_OK) goto done;
    char reply[8192];
    awaited = "detach-on-error confirmation before attach";
    if (!query(link, "QSetDetachOnError:1", reply, sizeof(reply)) || strcmp(reply, "OK")) goto done;
    if (attach) {
        char command[32];
        snprintf(command, sizeof(command), "vAttach;%x", target);
        awaited = "vAttach stop reply on an already-watched private stream";
        if (!query(link, command, reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S')) goto done;
    }
    awaited = "qSupported reply";
    if (!query(link, "qSupported", reply, sizeof(reply))) goto done;
    awaited = "qProcessInfo reply";
    if (!query(link, "qProcessInfo", reply, sizeof(reply))) goto done;
    char *pid_text = strstr(reply, "pid:");
    if (!pid_text) goto done;
    char *end;
    unsigned long pid = strtoul(pid_text + 4, &end, 16);
    if (*end != ';' || !pid || pid > INT_MAX || (target && target != (pid_t)pid)) goto done;
    target = (pid_t)pid;
    awaited = "initial stop reply";
    if (!query(link, "?", reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S')) goto done;
    if (!query(link, "qAttached", reply, sizeof(reply))) goto done;
    xrt_log(XRT_LOG_DEBUG, XRT_LOG_RUNTIME, "bootstrap qAttached=%s\n", reply);
    // This debugserver may not implement qAttached (empty reply). The spawned
    // child's pid match above, not this optional packet, proves the attach.
    if (*reply && strcmp(reply, "0") && strcmp(reply, "1")) goto done;
    if (attach && *reply && strcmp(reply, "1")) goto done;
    // A real instruction step through the existing packet/link implementation.
    awaited = "instruction-step stop reply";
    if (!query(link, "s", reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S')) goto done;
    (void)pread(heartbeat_fd, &before, sizeof(before), 0);
    if (attach != 2) {
        awaited = "detach OK before transport close";
        if (!query(link, "D", reply, sizeof(reply)) || strcmp(reply, "OK")) goto done;
        detached = 1;
        awaited = "debugserver exit after detach OK, before transport close";
        if (xrt_debugserver_wait(&child, 2000) != XRT_OK) goto done;
    }
    passed = kill(target, 0) == 0; // Detach must preserve both launched and attached targets.
done:
    if (link->fd >= 0 && !detached && attach != 2) {
        char reply[8192];
        if (query(link, "D", reply, sizeof(reply)) && !strcmp(reply, "OK")) {
            detached = 1;
            (void)xrt_debugserver_wait(&child, 2000);
        }
    }
    xrt_gdb_disconnect(link); free(link); link = NULL;
    if (passed) awaited = "normal debugserver exit after detach/EOF";
    enum xrt_status cleanup = detached ? xrt_debugserver_close_detached(&child) :
        xrt_debugserver_close(&child);
    if (cleanup != XRT_OK || child.pid != 0) passed = 0;
    if (target > 0 && kill(target, 0)) passed = 0;
    // kill(pid, 0) also succeeds for a zombie. Prove the detached target runs.
    if (passed) awaited = "detached target heartbeat to advance";
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
    if (!passed)
        fprintf(stderr, "bootstrap failure case=%d awaited=%s seen=helper_pid=%d target_pid=%d link_fd=%d detached=%d\n",
                attach, awaited, child.pid, target, link ? link->fd : -1, detached);
    close(heartbeat_fd); unlink(heartbeat);
    return passed;
}
static unsigned attach_runs(void)
{
    const char *text = getenv("XODB_BOOTSTRAP_ATTACH_RUNS");
    if (!text || !*text) return 1;
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 10);
    return end && !*end && value > 0 && value <= 100 ? (unsigned)value : 0;
}
static int owner_probe(pid_t target, int report_fd)
{
    char executable[4096];
    if (xrt_debugserver_find(executable, sizeof(executable), NULL) != XRT_OK) return 20;
    struct xrt_debugserver child = {0};
    struct xrt_debugserver_options options = {.executable = executable, .attach_pid = target};
    if (xrt_debugserver_start(&options, &child) != XRT_OK) return 21;
    struct xrt_gdb_link link = {.fd = -1};
    if (xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) != XRT_OK) return 22;
    char reply[8192];
    if (!query(&link, "QSetDetachOnError:1", reply, sizeof(reply)) || strcmp(reply, "OK")) return 23;
    char command[32];
    snprintf(command, sizeof(command), "vAttach;%x", target);
    if (!query(&link, command, reply, sizeof(reply)) || (reply[0] != 'T' && reply[0] != 'S') ||
        !query(&link, "qSupported", reply, sizeof(reply)) ||
        !query(&link, "qProcessInfo", reply, sizeof(reply))) return 23;
    if (write(report_fd, &child.pid, sizeof(child.pid)) != sizeof(child.pid)) return 24;
    for (;;) pause(); // The parent deliberately SIGKILLs this owner.
}
static int attach_owner_probe(pid_t target, int report_fd)
{
    char executable[4096];
    if (xrt_debugserver_find(executable, sizeof(executable), NULL) != XRT_OK) return 40;
    struct xrt_debugserver child = {0};
    struct xrt_debugserver_options options = {.executable = executable, .attach_pid = target};
    if (xrt_debugserver_start(&options, &child) != XRT_OK) return 41;
    struct xrt_gdb_link link = {.fd = -1};
    if (xrt_gdb_adopt(&link, xrt_debugserver_take_transport(&child), NULL) != XRT_OK) return 42;
    char reply[32];
    if (!query(&link, "QSetDetachOnError:1", reply, sizeof(reply)) || strcmp(reply, "OK")) return 43;
    char command[32];
    int length = snprintf(command, sizeof(command), "vAttach;%x", target);
    if (length <= 0 || (size_t)length >= sizeof(command) ||
        xrt_gdb_send(&link, command, (size_t)length) != XRT_OK) return 44;
    if (write(report_fd, &child.pid, sizeof(child.pid)) != sizeof(child.pid)) return 45;
    for (;;) pause(); // The parent kills this owner with the attach request in flight.
}
static int place_report(posix_spawn_file_actions_t *actions, int fd)
{
    // A dup2 onto itself keeps FD_CLOEXEC when stdin/stdout were closed.
    return fd == 3 ? posix_spawn_file_actions_addinherit_np(actions, 3) :
        posix_spawn_file_actions_adddup2(actions, fd, 3);
}
static int parent_death(const char *self)
{
    char heartbeat[] = ".work/bootstrap-parent-death.XXXXXX";
    int heartbeat_fd = mkstemp(heartbeat), report[2] = {-1, -1};
    pid_t target = 0, owner = 0, helper = 0;
    int passed = 0;
    const char *awaited = "owned target startup";
    if (heartbeat_fd < 0 || pipe(report)) goto done;
    (void)fcntl(heartbeat_fd, F_SETFD, FD_CLOEXEC);
    (void)fcntl(report[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(report[1], F_SETFD, FD_CLOEXEC);
    char *target_args[] = {(char *)self, "--fixture", heartbeat, NULL};
    if (posix_spawn(&target, self, NULL, NULL, target_args, *_NSGetEnviron())) goto done;
    char target_text[32], report_text[32];
    snprintf(target_text, sizeof(target_text), "%d", target);
    snprintf(report_text, sizeof(report_text), "%d", 3);
    char *owner_args[] = {(char *)self, "--owner-probe", target_text, report_text, NULL};
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) goto done;
    int status = place_report(&actions, report[1]);
    if (!status) status = posix_spawn(&owner, self, &actions, NULL, owner_args, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    close(report[1]); report[1] = -1;
    if (status) goto done;
    awaited = "owner report after active private GDB exchange";
    if (read(report[0], &helper, sizeof(helper)) != sizeof(helper) || helper <= 0) goto done;
    if (kill(owner, SIGKILL) && errno != ESRCH) goto done;
    int owner_status;
    while (waitpid(owner, &owner_status, 0) < 0 && errno == EINTR) {}
    owner = 0;
    awaited = "debugserver exit after owner SIGKILL closed the socketpair";
    uint64_t deadline = now_ms() + 10000;
    while (!kill(helper, 0) && now_ms() < deadline) {
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    if (!kill(helper, 0) || errno != ESRCH) goto done;
    awaited = "attached target heartbeat after owner SIGKILL";
    uint64_t before = 0;
    if (pread(heartbeat_fd, &before, sizeof(before), 0) != sizeof(before) ||
        !heartbeat_advanced(heartbeat_fd, before)) goto done;
    passed = 1;
done:
    if (!passed)
        fprintf(stderr, "bootstrap failure case=owner-SIGKILL awaited=%s seen=owner_pid=%d helper_pid=%d target_pid=%d\n",
                awaited, owner, helper, target);
    if (owner > 0) { (void)kill(owner, SIGKILL); while (waitpid(owner, NULL, 0) < 0 && errno == EINTR) {} }
    if (target > 0) { (void)kill(target, SIGTERM); (void)kill(target, SIGCONT); while (waitpid(target, NULL, 0) < 0 && errno == EINTR) {} }
    if (report[0] >= 0) close(report[0]);
    if (report[1] >= 0) close(report[1]);
    if (heartbeat_fd >= 0) close(heartbeat_fd);
    unlink(heartbeat);
    return passed;
}
static int parent_death_during_attach(const char *self)
{
    char heartbeat[] = ".work/bootstrap-attach-death.XXXXXX";
    int heartbeat_fd = mkstemp(heartbeat), report[2] = {-1, -1};
    pid_t target = 0, owner = 0, helper = 0;
    int passed = 0;
    const char *awaited = "owned fast-heartbeat target startup";
    if (heartbeat_fd < 0 || pipe(report)) goto done;
    (void)fcntl(heartbeat_fd, F_SETFD, FD_CLOEXEC);
    (void)fcntl(report[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(report[1], F_SETFD, FD_CLOEXEC);
    char *target_args[] = {(char *)self, "--fixture-fast", heartbeat, NULL};
    if (posix_spawn(&target, self, NULL, NULL, target_args, *_NSGetEnviron())) goto done;
    char target_text[32], report_text[32];
    snprintf(target_text, sizeof(target_text), "%d", target);
    snprintf(report_text, sizeof(report_text), "%d", 3);
    char *owner_args[] = {(char *)self, "--attach-owner-probe", target_text, report_text, NULL};
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) goto done;
    int status = place_report(&actions, report[1]);
    if (!status) status = posix_spawn(&owner, self, &actions, NULL, owner_args, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    close(report[1]); report[1] = -1;
    if (status) goto done;
    awaited = "owner report after detach-on-error and vAttach send";
    if (read(report[0], &helper, sizeof(helper)) != sizeof(helper) || helper <= 0) goto done;
    awaited = "target stop from the in-flight attach request";
    if (!heartbeat_stalled(heartbeat_fd)) goto done;
    if (kill(owner, SIGKILL) && errno != ESRCH) goto done;
    int owner_status;
    while (waitpid(owner, &owner_status, 0) < 0 && errno == EINTR) {}
    owner = 0;
    awaited = "debugserver exit after owner SIGKILL during attach";
    uint64_t deadline = now_ms() + 10000;
    while (!kill(helper, 0) && now_ms() < deadline) {
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    if (!kill(helper, 0) || errno != ESRCH) goto done;
    awaited = "attached target heartbeat after attach-window owner SIGKILL";
    uint64_t before = 0;
    if (pread(heartbeat_fd, &before, sizeof(before), 0) != sizeof(before) ||
        !heartbeat_advanced(heartbeat_fd, before)) goto done;
    passed = 1;
done:
    if (!passed)
        fprintf(stderr, "bootstrap failure case=attach-owner-SIGKILL awaited=%s seen=owner_pid=%d helper_pid=%d target_pid=%d\n",
                awaited, owner, helper, target);
    if (owner > 0) { (void)kill(owner, SIGKILL); while (waitpid(owner, NULL, 0) < 0 && errno == EINTR) {} }
    if (target > 0) { (void)kill(target, SIGTERM); (void)kill(target, SIGCONT); while (waitpid(target, NULL, 0) < 0 && errno == EINTR) {} }
    if (report[0] >= 0) close(report[0]);
    if (report[1] >= 0) close(report[1]);
    if (heartbeat_fd >= 0) close(heartbeat_fd);
    unlink(heartbeat);
    return passed;
}
int main(int argc, char **argv)
{
    if (argc == 3 && (!strcmp(argv[1], "--fixture") || !strcmp(argv[1], "--fixture-fast"))) {
        int fd = open(argv[2], O_WRONLY);
        if (fd < 0) return 1;
        int fast = !strcmp(argv[1], "--fixture-fast");
        long interval = fast ? 1000000 : 100000000;
        uint64_t limit = fast ? 60000 : 600;
        for (uint64_t i = 1; i <= limit; ++i) {
            if (pwrite(fd, &i, sizeof(i), 0) != sizeof(i)) break;
            struct timespec pause = {0, interval};
            nanosleep(&pause, NULL);
        }
        close(fd);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "--owner-probe")) {
        char *end_target = NULL, *end_fd = NULL;
        long target = strtol(argv[2], &end_target, 10), report_fd = strtol(argv[3], &end_fd, 10);
        if (!end_target || *end_target || target <= 0 || target > INT_MAX ||
            !end_fd || *end_fd || report_fd < 0 || report_fd > INT_MAX) return 19;
        return owner_probe((pid_t)target, (int)report_fd);
    }
    if (argc == 4 && !strcmp(argv[1], "--attach-owner-probe")) {
        char *end_target = NULL, *end_fd = NULL;
        long target = strtol(argv[2], &end_target, 10), report_fd = strtol(argv[3], &end_fd, 10);
        if (!end_target || *end_target || target <= 0 || target > INT_MAX ||
            !end_fd || *end_fd || report_fd < 0 || report_fd > INT_MAX) return 39;
        return attach_owner_probe((pid_t)target, (int)report_fd);
    }
    CHECK(argc == 1); // Planted negative runs before creating any child.
    signal(SIGPIPE, SIG_IGN);
    CHECK(!mkdir(".work", 0755) || errno == EEXIST);
    char executable[4096];
    CHECK(xrt_debugserver_find(executable, sizeof(executable), NULL) == XRT_OK);
    CHECK(discovery_with_closed_stdio(executable));
    struct xrt_debugserver child = {0};
    const char *args[] = {argv[0], "--fixture", NULL};
    struct xrt_debugserver_options options = {.executable = "/no/such/debugserver", .argv = args};
    CHECK(xrt_debugserver_start(&options, &child) == XRT_EXEC_FAILED && !child.pid);
    options.executable = "/usr/bin/false";
    uint64_t failed_at = now_ms();
    CHECK(xrt_debugserver_start(&options, &child) == XRT_EXEC_FAILED && !child.pid && !child.transport);
    CHECK(now_ms() - failed_at < 1000); // Early helper death is not a handshake timeout.
    options.executable = executable;
    options.attach_pid = 1;
    CHECK(xrt_debugserver_start(&options, &child) == XRT_INVALID_ARGUMENT && !child.pid);
    options.attach_pid = 0;
    options.cancel = xrt_cancel_create();
    CHECK(options.cancel);
    xrt_cancel_request(options.cancel);
    CHECK(xrt_debugserver_start(&options, &child) == XRT_REMOTE_CANCELLED && !child.pid);
    xrt_cancel_release(options.cancel);
    unsigned runs = attach_runs();
    CHECK(runs > 0);
    CHECK(exercise(argv[0], 0));
    for (unsigned i = 0; i < runs; ++i) CHECK(exercise(argv[0], 1));
    CHECK(exercise(argv[0], 2)); // Lost transport must not kill an attached target.
    CHECK(exercise(argv[0], 3)); // Neither may a pre-connect startup cancellation.
    CHECK(parent_death(argv[0])); // SIGKILL closes the private channel and releases the target.
    for (unsigned i = 0; i < runs; ++i) CHECK(parent_death_during_attach(argv[0]));
    printf("{\"native_debugserver_bootstrap\":\"pass\",\"private_transport\":\"pass\","
           "\"detach_before_close\":\"pass\",\"closed_stdio\":\"pass\","
           "\"attach_owner_loss\":\"pass\",\"attach_cycles\":%u,"
           "\"attach_owner_loss_cycles\":%u}\n", runs, runs);
    return 0;
}
