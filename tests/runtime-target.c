/* The debugger control loop, linked with an ordinary C compiler and no Zig,
 * ELF/DWARF, GUI or analysis libraries. All inferiors belong to this test. */
#define _GNU_SOURCE 1
#include "xrt_target.h"
#include "mapped_file.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

static struct xrt_target *target;
static pid_t child;
static volatile uint64_t watched;
static uint8_t data[8] = {1, 2, 3, 4, 5, 6, 7, 8};
#if defined(__x86_64__)
/* Exactly one write at the breakpoint address: step and hardware-watch bits
 * must coexist, regardless of compiler optimization or prologue choices. */
__attribute__((naked, noinline)) static void marker(void)
{
    __asm__ volatile("addq $1, watched(%rip)\nret");
}
#else
__attribute__((noinline)) static void marker(void)
{
    ++watched;
    __asm__ volatile("" ::: "memory");
}
#endif
static void cleanup(void)
{
    if (target) {
        xrt_target_destroy(target);
        target = NULL;
    }
    if (child > 0) {
        kill(child, SIGKILL);
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {
        }
        child = 0;
    }
}
#define CHECK(expr)                                                                                \
    do {                                                                                           \
        if (!(expr)) {                                                                             \
            fprintf(stderr, "%s:%d: %s (errno %d)\n", __FILE__, __LINE__, #expr, errno);           \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)
#define OK(expr)                                                                                   \
    do {                                                                                           \
        enum xrt_status status_ = (expr);                                                          \
        if (status_ != XRT_OK) {                                                                   \
            fprintf(stderr, "%s:%d: %s: runtime status %d\n", __FILE__, __LINE__, #expr, status_); \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)
static struct xrt_target_view view(void)
{
    struct xrt_target_view out;
    xrt_target_view(target, &out);
    return out;
}
static void wait_exit(void)
{
    const uint64_t deadline = xrt_now() + UINT64_C(3000000000);
    while (view().state != XRT_EXITED) {
        CHECK(xrt_now() < deadline);
        OK(xrt_target_poll(target));
        usleep(1000);
    }
}
static void launch_restart(void)
{
    target = xrt_target_create();
    CHECK(target);
    const char *missing[] = {"/xodb-test-no-executable", NULL};
    CHECK(xrt_target_launch(target, missing) == XRT_EXEC_FAILED);
    CHECK(view().pid == 0 && view().state == XRT_IDLE);
    const char *argv[] = {"/proc/self/exe", "--fixture", NULL};
    OK(xrt_target_launch(target, argv));
    struct xrt_target_view before = view();
    CHECK(before.state == XRT_STOPPED && before.owned && before.thread_count == 1 &&
          before.image_epoch == 1);
    const uint64_t old_id = before.threads[0].id, old_generation = before.generation;
    struct xrt_registers regs;
    OK(xrt_target_registers(target, before.pid, &regs));
    if (regs.machine == XRT_X86_64) {
        struct xrt_xstate extended;
        OK(xrt_target_extended(target, before.pid, &extended));
        CHECK(extended.vector_count >= 16 && extended.vector_bytes >= 16);
    }
    const uint64_t pc = regs.machine == XRT_X86_64 ? regs.values.x86.rip : regs.values.arm.pc;
    OK(xrt_target_step(target, before.pid));
    OK(xrt_target_wait_stopped(target));
    CHECK(view().threads[0].reason == XRT_STOP_SINGLE_STEP);
    OK(xrt_target_registers(target, before.pid, &regs));
    CHECK((regs.machine == XRT_X86_64 ? regs.values.x86.rip : regs.values.arm.pc) != pc);
    uint64_t pending;
    OK(xrt_target_breakpoint_reserve(target, &pending));
    OK(xrt_target_expect(target, view().generation));
    CHECK(xrt_target_expect(target, old_generation) == XRT_STALE_SNAPSHOT);
    OK(xrt_target_reset(target));
    CHECK(view().pid == 0 && view().breakpoint_count == 0);
    OK(xrt_target_launch(target, argv));
    CHECK(view().threads[0].id > old_id && view().image_epoch > before.image_epoch &&
          view().generation > old_generation);
    OK(xrt_target_breakpoint_restore(target, pending, false));
    CHECK(view().breakpoints[0].id == pending && !view().breakpoints[0].enabled &&
          view().breakpoints[0].pending);
    OK(xrt_target_continue(target));
    wait_exit();
    const struct xrt_target_view end = view();
    CHECK(end.events[end.event_count - 1].kind == XRT_EVENT_EXIT &&
          end.events[end.event_count - 1].detail == 17);
    xrt_target_destroy(target);
    target = NULL;
}
static void attach_probes(bool automatic_step)
{
    int gate[2];
    CHECK(pipe(gate) == 0);
    const pid_t parent = getpid();
    child = fork();
    CHECK(child >= 0);
    if (!child) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent)
            _exit(1);
        close(gate[1]);
        char byte;
        if (read(gate[0], &byte, 1) != 1)
            _exit(2);
        close(gate[0]);
        marker();
        marker();
        _exit(23);
    }
    close(gate[0]);
    target = xrt_target_create();
    CHECK(target);
    OK(xrt_target_attach(target, child));
    CHECK(view().state == XRT_STOPPED && !view().owned);
    uint8_t original[4], overlaid[4];
    size_t count;
    const uint64_t address = (uintptr_t)marker;
    const size_t trap_size = xrt_arch_native()->trap_size;
    OK(xrt_target_read(target, address, original, trap_size, &count));
    CHECK(count == trap_size);
    uint64_t bp, watch;
    OK(xrt_target_breakpoint_set(target, address, false, &bp));
    OK(xrt_target_read(target, address, overlaid, trap_size, &count));
    CHECK(memcmp(original, overlaid, trap_size) == 0 && view().breakpoints[0].patched);
    const uint64_t generation = view().generation;
    const uint8_t change[] = {7, 8, 9};
    OK(xrt_target_write(target, (uintptr_t)data + 2, change, sizeof(change)));
    CHECK(view().generation > generation);
    uint8_t memory[8];
    OK(xrt_target_read(target, (uintptr_t)data, memory, sizeof(memory), &count));
    CHECK(memcmp(memory, (uint8_t[]){1, 2, 7, 8, 9, 6, 7, 8}, 8) == 0);
    OK(xrt_target_watchpoint_set(target, (uintptr_t)&watched, 8, XRT_WATCH_WRITE, &watch));
    CHECK(write(gate[1], "x", 1) == 1);
    close(gate[1]);
    OK(xrt_target_continue(target));
    OK(xrt_target_wait_stopped(target));
    CHECK(view().threads[0].reason == XRT_STOP_BREAKPOINT && view().breakpoints[0].hit_count == 1);
    if (automatic_step) {
        OK(xrt_target_continue(target));
    } else {
        OK(xrt_target_step(target, child));
    }
    OK(xrt_target_wait_stopped(target));
    CHECK(view().breakpoints[0].patched);
    if (xrt_arch_native()->machine == XRT_X86_64) {
        CHECK(view().threads[0].reason == XRT_STOP_WATCHPOINT);
        bool completed = false;
        for (size_t i = 0; i < view().event_count; ++i)
            completed |= view().events[i].kind == XRT_EVENT_STEP_COMPLETE;
        CHECK(completed);
    } else {
        if (!automatic_step) {
            CHECK(view().threads[0].reason == XRT_STOP_SINGLE_STEP);
            OK(xrt_target_continue(target));
            OK(xrt_target_wait_stopped(target));
        }
        CHECK(view().threads[0].reason == XRT_STOP_WATCHPOINT);
    }
    bool hit = false;
    struct xrt_target_view current = view();
    for (size_t i = 0; i < current.event_count; ++i)
        if (current.events[i].kind == XRT_EVENT_WATCHPOINT_HIT) {
            CHECK(current.events[i].before == 0 && current.events[i].after == 1);
            hit = true;
        }
    CHECK(hit);
    OK(xrt_target_watchpoint_remove(target, watch));
    OK(xrt_target_breakpoint_remove(target, bp));
    OK(xrt_target_continue(target));
    wait_exit();
    CHECK(view().events[view().event_count - 1].detail == 23);
    CHECK(waitpid(child, NULL, WNOHANG) == -1 && errno == ECHILD);
    child = 0;
    xrt_target_destroy(target);
    target = NULL;
}
static void core_snapshot(void)
{
    target = xrt_target_create();
    CHECK(target);
    const struct xrt_thread thread = {
        .tid = getpid(), .state = XRT_STOPPED, .reason = XRT_STOP_SIGNAL, .signal = SIGSEGV};
    OK(xrt_target_core(target, getpid(), &thread, 1));
    CHECK(view().pid == getpid() && view().thread_count == 1);
    CHECK(xrt_target_continue(target) == XRT_READ_ONLY_CORE);
    CHECK(xrt_target_detach(target) == XRT_READ_ONLY_CORE);
    CHECK(xrt_target_step(target, getpid()) == XRT_READ_ONLY_CORE);
    xrt_target_destroy(target);
    target = NULL;
}
static void legacy_vectors(void)
{
    uint8_t raw[512] = {0};
    raw[0] = 0x7f;
    raw[1] = 3;
    raw[3] = 0x18;
    raw[4] = 8; /* TOP=3, physical ST3 valid. */
    raw[24] = 0x80;
    raw[25] = 0x1f;
    for (unsigned i = 0; i < 10; ++i)
        raw[32 + i] = (uint8_t)(i + 1);
    for (unsigned i = 0; i < 16; ++i)
        raw[160 + i] = (uint8_t)(i + 20);
    struct xrt_xstate decoded;
    OK(xrt_xstate_decode_legacy(raw, sizeof(raw), &decoded));
    CHECK(decoded.source == XRT_FPREGS && decoded.control == 0x37f && decoded.status == 0x1800 &&
          decoded.mxcsr == 0x1f80);
    CHECK(decoded.st_valid[0] && !decoded.st_valid[1] && memcmp(decoded.st[0], raw + 32, 10) == 0);
    CHECK(memcmp(decoded.vectors[0], raw + 160, 16) == 0 && decoded.vectors[0][16] == 0);
    struct xrt_xstate saved;
    memcpy(&saved, &decoded, sizeof(saved));
    for (size_t n = 0; n < 512; ++n) {
        CHECK(xrt_xstate_decode_legacy(raw, n, &decoded) == XRT_INVALID_XSTATE_SIZE);
        CHECK(memcmp(&decoded, &saved, sizeof(saved)) == 0);
    }
    CHECK(xrt_xstate_decode_legacy(NULL, 512, &decoded) == XRT_INVALID_ARGUMENT);
}
/* No inode-reuse timing is needed for the permanent regression: once its
 * VMA is gone, even a still-open descriptor is not a live backing mapping. */
static void mapping_identity(void)
{
    const long page = sysconf(_SC_PAGESIZE);
    CHECK(page > 0);
    const int fd = memfd_create("mapping-identity-fixture", MFD_CLOEXEC);
    CHECK(fd >= 0 && ftruncate(fd, page) == 0);
    void *address = mmap(NULL, (size_t)page, PROT_NONE, MAP_PRIVATE, fd, 0);
    CHECK(address != MAP_FAILED);
    struct stat st;
    CHECK(fstat(fd, &st) == 0);
    const uint64_t start = (uintptr_t)address, end = start + (uint64_t)page;
    const uint64_t ma = major(st.st_dev), mi = minor(st.st_dev), ino = st.st_ino;
    CHECK(xodb_mapped_file_matches(fd, getpid(), start, end, ma, mi, ino, 0) == 1);
    CHECK(xodb_mapped_file_matches(fd, getpid(), end, start, ma, mi, ino, 0) == 0);
    child = fork();
    CHECK(child >= 0);
    if (!child)
        _exit(0);
    siginfo_t info;
    CHECK(waitid(P_PID, (id_t)child, &info, WEXITED | WNOWAIT) == 0);
    CHECK(xodb_mapped_file_matches(fd, child, start, end, ma, mi, ino, 0) == 0);
    CHECK(waitpid(child, NULL, 0) == child);
    child = 0;
    CHECK(munmap(address, (size_t)page) == 0);
    CHECK(xodb_mapped_file_matches(fd, getpid(), start, end, ma, mi, ino, 0) == 0);
    /* Explicit path-only callers keep the weaker device/inode comparison. */
    CHECK(xodb_mapped_file_matches(fd, 0, start, end, ma, mi, ino, 0) == 1);
    CHECK(close(fd) == 0);
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--fixture") == 0)
        return 17;
    CHECK(atexit(cleanup) == 0);
    alarm(30);
    mapping_identity();
    core_snapshot();
    legacy_vectors();
    if (getenv("XODB_TEST_NO_LIVE") || !xrt_arch_native()) {
        puts("C target: immutable snapshot passed; live checks skipped");
        return 0;
    }
    launch_restart();
    attach_probes(false);
    attach_probes(true);
    puts("C target: launch, restart, attach, stepping, breakpoint overlays/rearm, watches, "
         "generations, cleanup passed");
    return 0;
}
