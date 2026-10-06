/* Bounded host-side driver for one supervised ghx decompile (see ghx_host.h). */
#define _GNU_SOURCE
#include "ghx_host.h"
#include "xsq.h"

#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <poll.h>
#include <signal.h>
#include <sys/prctl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static double now_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void sleep_ms(long ms)
{
    struct timespec t = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&t, &t) != 0 && errno == EINTR) {
    }
}

static void copy_field(char *out, size_t size, const char *value, size_t length)
{
    if (length >= size) length = size - 1;
    memcpy(out, value, length);
    out[length] = 0;
}

/* Fields are TAB separated key=value; values never contain TAB or newline. */
static void parse_line(char *line, struct xghx_outcome *o, int *have_result)
{
    int result = strncmp(line, "RESULT\t", 7) == 0;
    int worker = strncmp(line, "WORKER\t", 7) == 0;
    if (!result && !worker) return;
    if (result) *have_result = 1;
    for (char *field = strtok(line + 7, "\t"); field; field = strtok(NULL, "\t")) {
        char *eq = strchr(field, '=');
        if (!eq) continue;
        size_t key = (size_t)(eq - field);
        const char *value = eq + 1;
        if (worker && key == 3 && !strncmp(field, "pid", 3)) o->worker_pid = strtol(value, NULL, 10);
        if (!result) continue;
        if (key == 6 && !strncmp(field, "status", 6)) copy_field(o->status, sizeof o->status, value, strlen(value));
        if (key == 4 && !strncmp(field, "file", 4)) copy_field(o->file, sizeof o->file, value, strlen(value));
        if ((key == 6 && !strncmp(field, "detail", 6)) || (key == 13 && !strncmp(field, "worker_status", 13)))
            if (!o->detail[0]) copy_field(o->detail, sizeof o->detail, value, strlen(value));
    }
}

/* SIGTERM lets the supervisor kill its worker group and publish; SIGKILL is
 * the bounded fallback (its worker then dies by PR_SET_PDEATHSIG). */
static int stop(pid_t pid, long grace_ms)
{
    int status = 0;
    kill(pid, SIGTERM);
    for (double until = now_ms() + grace_ms + 1000; now_ms() < until; sleep_ms(10)) {
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) return status;
        if (got < 0 && errno != EINTR) return -1; /* not ours to signal any more */
    }
    kill(pid, SIGKILL);
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    return status;
}

static char **child_environment(const char *tmpdir)
{
    size_t n = 0;
    while (environ && environ[n]) n++;
    char **env = calloc(n + 2, sizeof *env);
    if (!env) return NULL;
    size_t k = 0;
    for (size_t i = 0; i < n; i++)
        if (strncmp(environ[i], "TMPDIR=", 7)) env[k++] = environ[i];
    size_t size = strlen(tmpdir) + 8;
    env[k] = malloc(size);
    if (!env[k]) {
        free(env);
        return NULL;
    }
    snprintf(env[k], size, "TMPDIR=%s", tmpdir);
    return env;
}

/* Only the last entry (TMPDIR) is owned; the others point into environ. */
static void free_environment(char **env)
{
    if (!env) return;
    size_t k = 0;
    while (env[k]) k++;
    if (k) free(env[k - 1]);
    free(env);
}

enum xghx_status xghx_run(const struct xghx_request *r, const struct xsq_cancel *cancel, struct xghx_outcome *o)
{
    memset(o, 0, sizeof *o);
    o->supervisor_status = -1;
    double start = now_ms();
    int in[2] = {-1, -1}, out[2] = {-1, -1}, log = -1;
    char path[4200], deadline[32], grace[32], memory[32];
    snprintf(path, sizeof path, "%s/supervisor-stderr.log", r->outdir);
    snprintf(deadline, sizeof deadline, "%ld", r->deadline_ms);
    snprintf(grace, sizeof grace, "%ld", r->grace_ms);
    snprintf(memory, sizeof memory, "%ld", r->memory_mb);
    char *argv[] = {(char *)r->supervisor, "-w", (char *)r->worker, "-s", (char *)r->sleighhome, "-o",
                    (char *)r->outdir, "-t", deadline, "-g", grace, "-M", memory, NULL};
    char **env = NULL;
    int status_pipe[2] = {-1, -1}, error = 0;
    pid_t pid = -1;
    if (pipe2(in, O_CLOEXEC) || pipe2(out, O_CLOEXEC) || pipe2(status_pipe, O_CLOEXEC)) goto failed;
    log = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (log < 0 || !(env = child_environment(r->outdir))) goto failed;
    /* fork, not posix_spawn: the supervisor must die with the debugger
     * (PR_SET_PDEATHSIG), so a SIGKILLed xodb cannot leave it and its worker
     * running until their deadline. The calling thread waits for the child,
     * so the death signal tracks the debugger, not an exiting thread. The
     * child runs only async-signal-safe calls before execve. */
    pid_t parent = getpid();
    sigset_t none;
    sigemptyset(&none);
    pid = fork();
    if (pid < 0) goto failed;
    if (pid == 0) {
        struct sigaction dfl;
        memset(&dfl, 0, sizeof dfl);
        dfl.sa_handler = SIG_DFL;
        int code = 0;
        setpgid(0, 0); /* own group: no terminal signals */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) code = errno ? errno : ESRCH;
        for (int sig = 1; sig < 65 && !code; sig++)
            if (sig != SIGKILL && sig != SIGSTOP) sigaction(sig, &dfl, NULL);
        if (!code && (sigprocmask(SIG_SETMASK, &none, NULL) || dup2(in[0], STDIN_FILENO) < 0 ||
                      dup2(out[1], STDOUT_FILENO) < 0 || dup2(log, STDERR_FILENO) < 0))
            code = errno;
        if (!code) execve(r->supervisor, argv, env);
        if (!code) code = errno;
        ssize_t ignored = write(status_pipe[1], &code, sizeof code);
        (void)ignored;
        _exit(127);
    }
    setpgid(pid, pid);
    close(status_pipe[1]);
    status_pipe[1] = -1;
    {
        int code = 0;
        ssize_t n;
        while ((n = read(status_pipe[0], &code, sizeof code)) < 0 && errno == EINTR) {
        }
        close(status_pipe[0]);
        status_pipe[0] = -1;
        if (n == (ssize_t)sizeof code) { /* exec failed: reap the child and report */
            while (waitpid(pid, &o->supervisor_status, 0) < 0 && errno == EINTR) {
            }
            error = code;
            goto spawn_error;
        }
    }
    close(in[0]);
    close(out[1]);
    close(log);
    in[0] = out[1] = log = -1;
    /* The request is far below PIPE_BUF; a failed write shows up as no RESULT. */
    {
        size_t length = strlen(r->line);
        char *line = malloc(length + 2);
        if (line) {
            memcpy(line, r->line, length);
            line[length] = '\n';
            ssize_t ignored = write(in[1], line, length + 1);
            (void)ignored;
            free(line);
        }
        close(in[1]);
        in[1] = -1;
    }
    char buffer[16384];
    size_t used = 0;
    int have_result = 0, eof = 0;
    enum xghx_status status = XGHX_RESULT;
    double host_deadline = start + r->deadline_ms + r->grace_ms + 3000;
    while (!eof) {
        if (xsq_cancel_requested(cancel)) {
            status = XGHX_CANCELLED;
            break;
        }
        if (now_ms() > host_deadline) {
            status = XGHX_HOST_DEADLINE;
            break;
        }
        struct pollfd p = {out[0], POLLIN, 0};
        int n = poll(&p, 1, 50);
        if (n < 0 && errno != EINTR) break;
        if (n <= 0) continue;
        ssize_t got = read(out[0], buffer + used, sizeof buffer - 1 - used);
        if (got < 0 && (errno == EINTR || errno == EAGAIN)) continue;
        if (got <= 0) {
            eof = 1;
            break;
        }
        used += (size_t)got;
        buffer[used] = 0;
        char *line = buffer, *end;
        while ((end = strchr(line, '\n'))) {
            *end = 0;
            parse_line(line, o, &have_result);
            line = end + 1;
        }
        used -= (size_t)(line - buffer);
        memmove(buffer, line, used);
        if (used == sizeof buffer - 1) used = 0; /* an overlong line is dropped */
    }
    if (eof) {
        /* stdout EOF: the supervisor is exiting; its own reaping is bounded by -g. */
        int reaped = 0;
        for (double until = now_ms() + r->grace_ms + 2000; now_ms() < until; sleep_ms(5)) {
            pid_t got = waitpid(pid, &o->supervisor_status, WNOHANG);
            if (got == pid || (got < 0 && errno != EINTR)) {
                reaped = 1;
                break;
            }
        }
        if (!reaped) o->supervisor_status = stop(pid, r->grace_ms);
        if (!have_result) status = XGHX_PROTOCOL;
    } else {
        o->supervisor_status = stop(pid, r->grace_ms);
        if (status == XGHX_RESULT) status = have_result ? XGHX_RESULT : XGHX_PROTOCOL;
    }
    close(out[0]);
    free_environment(env);
    o->ms = now_ms() - start;
    return status;
spawn_error:
    errno = error;
failed:
    o->error = errno;
    for (int i = 0; i < 2; i++) {
        if (in[i] >= 0) close(in[i]);
        if (out[i] >= 0) close(out[i]);
    }
    if (log >= 0) close(log);
    for (int i = 0; i < 2; i++)
        if (status_pipe[i] >= 0) close(status_pipe[i]);
    free_environment(env);
    o->ms = now_ms() - start;
    return XGHX_SPAWN_FAILED;
}

static int remove_entry(const char *path, const struct stat *st, int flag, struct FTW *ftw)
{
    (void)st;
    (void)ftw;
    return flag == FTW_DP ? rmdir(path) : unlink(path);
}

int xghx_remove_tree(const char *path)
{
    return nftw(path, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

struct xsq_cancel *xghx_cancel_new(void)
{
    struct xsq_cancel *cancel = malloc(sizeof *cancel);
    if (cancel) xsq_cancel_init(cancel);
    return cancel;
}

void xghx_cancel_free(struct xsq_cancel *cancel)
{
    free(cancel);
}

const char *xghx_status_name(enum xghx_status status)
{
    switch (status) {
    case XGHX_RESULT: return "result";
    case XGHX_CANCELLED: return "cancelled";
    case XGHX_HOST_DEADLINE: return "host_deadline";
    case XGHX_SPAWN_FAILED: return "spawn_failed";
    case XGHX_PROTOCOL: return "protocol";
    }
    return "unknown";
}
