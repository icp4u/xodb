/* Probe only this process and an owned child; never change host policy. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/perf_event.h>
#include <signal.h>
#include <stdio.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    alarm(5);
    int pipefd[2];
    if (pipe(pipefd)) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (!child) {
        close(pipefd[0]);
        int err = ptrace(PTRACE_TRACEME, 0, 0, 0) < 0 ? errno : 0;
        if (write(pipefd[1], &err, sizeof(err)) != sizeof(err)) _exit(1);
        if (!err) raise(SIGSTOP);
        _exit(0);
    }
    close(pipefd[1]);
    int trace_error = 0, status = 0;
    if (read(pipefd[0], &trace_error, sizeof(trace_error)) != sizeof(trace_error)) return 1;
    close(pipefd[0]);
    if (waitpid(child, &status, 0) != child) return 1;
    if (WIFSTOPPED(status)) {
        if (ptrace(PTRACE_CONT, child, 0, 0) < 0) return 1;
        if (waitpid(child, &status, 0) != child) return 1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status)) return 1;
    struct perf_event_attr attr = {
        .type = PERF_TYPE_SOFTWARE, .size = sizeof(attr),
        .config = PERF_COUNT_SW_TASK_CLOCK, .disabled = 1,
        .exclude_kernel = 1, .exclude_hv = 1,
    };
    int fd = syscall(SYS_perf_event_open, &attr, 0, -1, -1, PERF_FLAG_FD_CLOEXEC);
    int perf_error = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    printf("{\"ptrace_errno\":%d,\"perf_errno\":%d}\n", trace_error, perf_error);
    return trace_error || perf_error ? 2 : 0;
}
