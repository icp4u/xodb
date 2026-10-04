// Standalone Android ARM64 capability probe. Traces only its own forked child.
// No files, sockets, app access, system settings or command-line PID argument.
#define _GNU_SOURCE
#include <asm/ptrace.h>
#include <errno.h>
#include <linux/elf.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile uint64_t watched __attribute__((aligned(8))) = 7;
static volatile sig_atomic_t child_pid;
static void interrupted(int signal_number) {
    // Child sets PDEATHSIG and checks parent identity before stopping.
    _exit(128 + signal_number);
}
static int stopped(pid_t child, int signal_number) {
    int status;
    if (waitpid(child, &status, 0) != child) return -1;
    if (WIFEXITED(status) || WIFSIGNALED(status)) child_pid = 0;
    if (!WIFSTOPPED(status) || WSTOPSIG(status) != signal_number) {
        fprintf(stderr, "unexpected child wait status=0x%x\n", status);
        errno = EPROTO;
        return -1;
    }
    return 0;
}
#define REQUIRE(expr) do { if (!(expr)) { perror(#expr); goto fail; } } while (0)
int main(void) {
    setbuf(stdout, NULL);
    signal(SIGALRM, interrupted);
    signal(SIGINT, interrupted);
    signal(SIGTERM, interrupted);
    pid_t parent = getpid();
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent) _exit(2);
        if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0) { perror("TRACEME"); _exit(3); }
        raise(SIGSTOP);
        watched = 42;
        _exit(watched == 42 ? 0 : 4);
    }
    child_pid = child;
    alarm(10);
    REQUIRE(stopped(child, SIGSTOP) == 0);
    REQUIRE(ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)(uintptr_t)PTRACE_O_EXITKILL) == 0);
    struct user_pt_regs regs = {0};
    struct iovec io = { &regs, sizeof(regs) };
    REQUIRE(ptrace(PTRACE_GETREGSET, child, (void *)(uintptr_t)NT_PRSTATUS, &io) == 0);
    REQUIRE(io.iov_len == sizeof(regs));
    printf("GETREGSET ok: bytes=%zu pc=0x%llx\n", io.iov_len, (unsigned long long)regs.pc);
    errno = 0;
    long word = ptrace(PTRACE_PEEKDATA, child, (void *)&watched, NULL);
    REQUIRE(errno == 0 && word == 7);
    puts("PEEKDATA ok: owned child value=7");
    REQUIRE(ptrace(PTRACE_SINGLESTEP, child, NULL, NULL) == 0);
    REQUIRE(stopped(child, SIGTRAP) == 0);
    siginfo_t info = {0};
    REQUIRE(ptrace(PTRACE_GETSIGINFO, child, NULL, &info) == 0);
    REQUIRE(info.si_code == TRAP_TRACE);
    puts("SINGLESTEP ok: TRAP_TRACE");
    struct user_hwdebug_state watch = {0};
    io = (struct iovec){ &watch, sizeof(watch) };
    REQUIRE(ptrace(PTRACE_GETREGSET, child, (void *)(uintptr_t)NT_ARM_HW_WATCH, &io) == 0);
    unsigned slots = watch.dbg_info & 255;
    printf("HW_WATCH slots=%u bytes=%zu\n", slots, io.iov_len);
    REQUIRE(slots > 0 && slots <= 16 && io.iov_len >= 8 + slots * 16);
    memset(watch.dbg_regs, 0, sizeof(watch.dbg_regs));
    watch.dbg_regs[0].addr = (uintptr_t)&watched;
    watch.dbg_regs[0].ctrl = 1 | (2 << 3) | (255 << 5); // enabled, write, eight bytes
    io.iov_len = 8 + slots * 16;
    REQUIRE(ptrace(PTRACE_SETREGSET, child, (void *)(uintptr_t)NT_ARM_HW_WATCH, &io) == 0);
    REQUIRE(ptrace(PTRACE_CONT, child, NULL, NULL) == 0);
    REQUIRE(stopped(child, SIGTRAP) == 0);
    REQUIRE(ptrace(PTRACE_GETSIGINFO, child, NULL, &info) == 0);
    REQUIRE(info.si_code == TRAP_HWBKPT);
    REQUIRE((uintptr_t)info.si_addr >= (uintptr_t)&watched && (uintptr_t)info.si_addr < (uintptr_t)&watched + sizeof(watched));
    puts("HW_WATCH ok: owned child write trapped");
    watch.dbg_regs[0].ctrl = 0;
    REQUIRE(ptrace(PTRACE_SETREGSET, child, (void *)(uintptr_t)NT_ARM_HW_WATCH, &io) == 0);
    REQUIRE(ptrace(PTRACE_CONT, child, NULL, NULL) == 0);
    int status;
    REQUIRE(waitpid(child, &status, 0) == child);
    child_pid = 0;
    REQUIRE(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    alarm(0);
    puts("PASS: child exited and reaped");
    return 0;
fail:
    if (child_pid > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    child_pid = 0;
    alarm(0);
    return 1;
}
