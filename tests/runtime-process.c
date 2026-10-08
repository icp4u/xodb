/* Plain C coverage of launch ownership, protocol-safe stdio, signal restoration
 * and /proc inspection. Seccomp injects real kernel failures before/after SEIZE. */
#define _GNU_SOURCE 1
#include "xrt_process.h"
#include "xrt_arch.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static int32_t child;
static void cleanup(void)
{
    if (child <= 0)
        return;
    kill(child, SIGKILL);
    for (;;) {
        int status;
        const pid_t waited = waitpid(child, &status, __WALL);
        if (waited < 0 && errno == EINTR)
            continue;
        if (waited < 0 || WIFEXITED(status) || WIFSIGNALED(status))
            break;
        ptrace(PTRACE_CONT, child, (void *)0, (void *)(uintptr_t)SIGKILL);
    }
    child = 0;
}
#define CHECK(expr)                                                                                \
    do {                                                                                           \
        if (!(expr)) {                                                                             \
            fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, errno);           \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

static int fd_count(void)
{
    DIR *dir = opendir("/proc/self/fd");
    CHECK(dir != NULL);
    int count = 0;
    while (readdir(dir))
        ++count;
    closedir(dir);
    return count;
}

static void disposition(int number, void (*handler)(int))
{
    struct sigaction action = {.sa_handler = handler};
    sigemptyset(&action.sa_mask);
    CHECK(sigaction(number, &action, NULL) == 0);
}

static int child_main(bool ignored_pipe)
{
    struct sigaction pipe_action, term_action;
    struct stat input, output, error;
    unsigned char byte;
    if (sigaction(SIGPIPE, NULL, &pipe_action) || sigaction(SIGTERM, NULL, &term_action))
        return 1;
    if (pipe_action.sa_handler != (ignored_pipe ? SIG_IGN : SIG_DFL))
        return 2;
    if (term_action.sa_handler != (ignored_pipe ? SIG_DFL : SIG_IGN))
        return 3;
    if (fstat(0, &input) || !S_ISCHR(input.st_mode) || read(0, &byte, 1) != 0)
        return 4;
    if (fstat(1, &output) || fstat(2, &error) || output.st_dev != error.st_dev ||
        output.st_ino != error.st_ino)
        return 5;
    if (write(1, "inferior\n", 9) != 9)
        return 6;
    return 73;
}

static void wait_exit(int expected, bool expect_exec)
{
    bool saw_exec = false, saw_exit = false;
    for (;;) {
        int status;
        pid_t waited;
        do {
            waited = waitpid(child, &status, __WALL);
        } while (waited < 0 && errno == EINTR);
        CHECK(waited == child);
        if (WIFEXITED(status)) {
            CHECK(WEXITSTATUS(status) == expected && saw_exec == expect_exec && saw_exit);
            break;
        }
        CHECK(WIFSTOPPED(status) && WSTOPSIG(status) == SIGTRAP);
        const unsigned event = (unsigned)status >> 16;
        if (event == PTRACE_EVENT_EXEC) {
            saw_exec = true;
            struct xrt_task_info info;
            CHECK(xrt_task_inspect(child, &info) == XRT_OK);
            CHECK(info.group == child && info.tracer == getpid() && info.state == 't');
            CHECK(xrt_process_validate_native(child) ==
                  (xrt_arch_native() ? XRT_OK : XRT_UNSUPPORTED_ARCHITECTURE));
        } else {
            CHECK(event == PTRACE_EVENT_EXIT);
            saw_exit = true;
        }
        CHECK(ptrace(PTRACE_CONT, child, (void *)0, (void *)0) == 0);
    }
    struct xrt_task_info info;
    CHECK(xrt_task_inspect(child, &info) == XRT_PROCESS_GONE);
    child = 0;
}

static void launch_stdio(bool ignored_pipe, bool close_input)
{
    int output[2], error[2], saved[3];
    CHECK(pipe2(output, O_CLOEXEC) == 0 && pipe2(error, O_CLOEXEC) == 0);
    for (int i = 0; i < 3; ++i) {
        saved[i] = fcntl(i, F_DUPFD_CLOEXEC, 3);
        CHECK(saved[i] >= 0);
    }
    CHECK(dup2(output[1], 1) == 1 && dup2(error[1], 2) == 2);
    close(output[1]);
    close(error[1]);
    if (close_input)
        close(0);
    const char *argv[] = {"/proc/self/exe", "--child", ignored_pipe ? "ignored" : "default", NULL};
    const enum xrt_status result = xrt_process_launch(argv, false, &child);
    for (int i = 0; i < 3; ++i) {
        CHECK(dup2(saved[i], i) == i);
        close(saved[i]);
    }
    CHECK(result == XRT_OK && child > 1);
    wait_exit(73, true);
    char bytes[32];
    CHECK(read(output[0], bytes, sizeof(bytes)) == 0);
    CHECK(read(error[0], bytes, sizeof(bytes)) == 9 && memcmp(bytes, "inferior\n", 9) == 0);
    close(output[0]);
    close(error[0]);
}

static void inspect_tasks(void)
{
    struct xrt_task_info info;
    CHECK(xrt_task_inspect(getpid(), &info) == XRT_OK);
    CHECK(info.group == getpid() && info.tracer == 0);
    struct xrt_task_info saved;
    memset(&saved, 0xa5, sizeof(saved));
    memcpy(&info, &saved, sizeof(info));
    CHECK(xrt_task_inspect(-1, &info) == XRT_INVALID_ARGUMENT);
    CHECK(memcmp(&info, &saved, sizeof(info)) == 0);
    CHECK(xrt_task_inspect(INT32_MAX, &info) == XRT_PROCESS_GONE);
    CHECK(memcmp(&info, &saved, sizeof(info)) == 0);
    CHECK(xrt_task_inspect(getpid(), NULL) == XRT_INVALID_ARGUMENT);
    child = fork();
    CHECK(child >= 0);
    if (child == 0)
        _exit(42);
    siginfo_t status;
    CHECK(waitid(P_PID, (id_t)child, &status, WEXITED | WNOWAIT) == 0);
    CHECK(xrt_task_inspect(child, &info) == XRT_OK && info.state == 'Z' && info.group == child &&
          info.tracer == 0);
    CHECK(waitpid(child, NULL, 0) == child);
    child = 0;
}

static void deny_syscall(unsigned number, unsigned error)
{
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, number, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | error),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {.len = sizeof(filter) / sizeof(filter[0]), .filter = filter};
    CHECK(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0);
    CHECK(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) == 0);
}

static void signal_evidence(void)
{
    struct xrt_signal_info info, saved;
    memset(&saved, 0xa5, sizeof(saved));
    memcpy(&info, &saved, sizeof(info));
    CHECK(xrt_signal_read(-1, &info) == XRT_INVALID_ARGUMENT);
    CHECK(memcmp(&info, &saved, sizeof(info)) == 0);
    CHECK(xrt_signal_read(getpid(), &info) == XRT_PROCESS_GONE);
    CHECK(memcmp(&info, &saved, sizeof(info)) == 0);
    CHECK(xrt_signal_read(getpid(), NULL) == XRT_INVALID_ARGUMENT);
    const long page_size = sysconf(_SC_PAGESIZE);
    CHECK(page_size > 0);
    void *page = mmap(NULL, (size_t)page_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(page != MAP_FAILED);
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        if (ptrace(PTRACE_TRACEME, 0, (void *)0, (void *)0) < 0)
            _exit(1);
        raise(SIGSTOP);
        kill(getpid(), SIGUSR1);
        (void)*(volatile unsigned char *)page;
        _exit(2);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGSTOP);
    CHECK(ptrace(PTRACE_SETOPTIONS, child, (void *)0, (void *)(uintptr_t)PTRACE_O_EXITKILL) == 0);
    CHECK(ptrace(PTRACE_CONT, child, (void *)0, (void *)0) == 0);
    CHECK(waitpid(child, &status, 0) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGUSR1);
    CHECK(xrt_signal_read(child, &info) == XRT_OK);
    CHECK(info.number == SIGUSR1 && info.code == SI_USER && info.error_number == 0);
    CHECK(info.has_sender && info.sender == child && !info.has_address);
    CHECK(ptrace(PTRACE_CONT, child, (void *)0, (void *)0) == 0);
    CHECK(waitpid(child, &status, 0) == child && WIFSTOPPED(status) && WSTOPSIG(status) == SIGSEGV);
    CHECK(xrt_signal_read(child, &info) == XRT_OK);
    CHECK(info.number == SIGSEGV && info.code == SEGV_ACCERR && info.error_number == 0);
    CHECK(info.has_address && info.address == (uintptr_t)page && !info.has_sender);
    cleanup();
    CHECK(munmap(page, (size_t)page_size) == 0);
}

static void failed_launch(unsigned failure)
{
    /* The controller isolates the fault-injection settings. */
    const pid_t controller = fork();
    CHECK(controller >= 0);
    if (controller == 0) {
        const int descriptors = fd_count();
        const pid_t unrelated = fork();
        CHECK(unrelated >= 0);
        if (unrelated == 0)
            _exit(42);
        const char *argv[] = {"/proc/self/exe", "--must-not-exec", NULL};
        enum xrt_status expected;
        struct rlimit saved_limit = {0};
        if (failure == 0) {
            deny_syscall(SYS_ptrace, EACCES);
            expected = XRT_PERMISSION_DENIED;
        } else if (failure == 1) {
            /* On x86-64/AArch64 libc send() uses the sendto syscall. */
            deny_syscall(SYS_sendto, EPIPE);
            expected = XRT_PIPE_FAILED;
        } else {
            CHECK(getrlimit(RLIMIT_NOFILE, &saved_limit) == 0);
            struct rlimit limit = saved_limit;
            limit.rlim_cur = 0;
            CHECK(setrlimit(RLIMIT_NOFILE, &limit) == 0);
            expected = XRT_PIPE_FAILED;
        }
        disposition(SIGPIPE, SIG_DFL);
        CHECK(xrt_process_launch(argv, false, &child) == expected && child == 0);
        int status;
        CHECK(waitpid(unrelated, &status, 0) == unrelated && WIFEXITED(status) &&
              WEXITSTATUS(status) == 42);
        CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
        if (failure == 2)
            CHECK(setrlimit(RLIMIT_NOFILE, &saved_limit) == 0);
        CHECK(fd_count() == descriptors);
        /* Only the denied-ptrace filter prevents LSan's exit helper. The
         * sendto failure and restored fd limit permit normal leak checks. */
        if (failure == 0)
            _exit(0);
        exit(0);
    }
    int status;
    CHECK(waitpid(controller, &status, 0) == controller);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}

int main(int argc, char **argv)
{
    /* Synthetic tracees bypass exit-time LeakSanitizer: its helper cannot
     * ptrace a process already owned by this test. The controller still gets
     * normal leak checks, and tracee memory accesses remain instrumented. */
    if (argc == 3 && strcmp(argv[1], "--child") == 0)
        _exit(child_main(strcmp(argv[2], "ignored") == 0));
    CHECK(argc == 1);
    CHECK(atexit(cleanup) == 0);
    alarm(30);
    const int descriptors = fd_count();
    const uintptr_t base = PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC | PTRACE_O_TRACEEXIT;
    CHECK((xrt_process_options(false, false) & base) == base);
    CHECK(!(xrt_process_options(false, false) & PTRACE_O_EXITKILL));
    CHECK(xrt_process_options(true, true) & PTRACE_O_EXITKILL);
    const uintptr_t births = PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK | PTRACE_O_TRACEVFORKDONE;
    CHECK((xrt_process_options(false, true) & births) == births);
    CHECK((xrt_process_options(false, false) & births) == births);
    CHECK(xrt_process_launch(NULL, false, &child) == XRT_INVALID_ARGUMENT && child == 0);
    const char *empty[] = {NULL};
    CHECK(xrt_process_launch(empty, false, &child) == XRT_INVALID_ARGUMENT && child == 0);
    CHECK(xrt_process_launch(empty, false, NULL) == XRT_INVALID_ARGUMENT);
    inspect_tasks();
    if (getenv("XODB_TEST_NO_LIVE")) {
        puts("runtime process: metadata passed; live ptrace checks skipped");
        return 0;
    }
    struct sigaction original_pipe, original_term;
    CHECK(sigaction(SIGPIPE, NULL, &original_pipe) == 0 &&
          sigaction(SIGTERM, NULL, &original_term) == 0);
    disposition(SIGPIPE, SIG_IGN);
    disposition(SIGTERM, SIG_DFL);
    CHECK(xrt_process_save_launch_signals() == XRT_OK);
    disposition(SIGPIPE, SIG_DFL);
    disposition(SIGTERM, SIG_IGN);
    launch_stdio(true, false);
    launch_stdio(true, true); /* Restart, including a caller with closed stdin. */
    CHECK(xrt_process_save_launch_signals() == XRT_OK);
    disposition(SIGPIPE, SIG_IGN);
    disposition(SIGTERM, SIG_DFL);
    launch_stdio(false, false);
    const char *missing[] = {"/xodb-fixture-does-not-exist", NULL};
    CHECK(xrt_process_launch(missing, false, &child) == XRT_OK);
    wait_exit(127, false);
    failed_launch(0);
#if defined(__x86_64__) || defined(__aarch64__)
    failed_launch(1);
#endif
    failed_launch(2);
    signal_evidence();
    CHECK(sigaction(SIGPIPE, &original_pipe, NULL) == 0 &&
          sigaction(SIGTERM, &original_term, NULL) == 0);
    CHECK(fd_count() == descriptors);
    puts("runtime process: launch/restart, stdio, signals, task identity, failure cleanup passed");
    return 0;
}
