/* The debugger control loop, linked with an ordinary C compiler and no Zig,
 * ELF/DWARF, GUI or analysis libraries. All inferiors belong to this test. */
#define _GNU_SOURCE 1
#include "target_internal.h"
#include "wire_target.h"
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
    if (regs.abi.machine == XRT_X86_64) {
        struct xrt_xstate extended;
        OK(xrt_target_extended(target, before.pid, &extended));
        CHECK(extended.vector_count >= 16 && extended.vector_bytes >= 16);
    }
    uint64_t pc = 0;
    OK(xrt_registers_pc(&regs, &pc));
    OK(xrt_target_step(target, before.pid));
    OK(xrt_target_wait_stopped(target));
    CHECK(view().threads[0].reason == XRT_STOP_SINGLE_STEP);
    OK(xrt_target_registers(target, before.pid, &regs));
    uint64_t stepped = 0;
    OK(xrt_registers_pc(&regs, &stepped));
    CHECK(stepped != pc);
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
          view().breakpoints[0].pending && !view().breakpoints[0].width &&
          !view().breakpoints[0].address && !view().breakpoints[0].patched);
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
struct patch_script {
    int calls;
    size_t accept[4];
    enum xrt_status status[4];
    size_t widths[4];
    uint8_t bytes[4][4];
};
static enum xrt_status scripted_patch(void *ctx, int32_t tid, uint64_t address, const void *bytes,
                                      size_t size, size_t *accepted)
{
    struct patch_script *script = ctx;
    (void)tid;
    (void)address;
    CHECK(script->calls < 4 && size <= 4);
    memcpy(script->bytes[script->calls], bytes, size);
    script->widths[script->calls] = size;
    *accepted = script->accept[script->calls];
    return script->status[script->calls++];
}
static enum xrt_status delegate_patch(void *ctx, int32_t tid, uint64_t address, const void *bytes,
                                      size_t size, size_t *accepted)
{
    (void)ctx;
    return xrt_memory_patch(tid, address, bytes, size, accepted);
}
struct reg_bank {
    unsigned char image[XRT_GPR_BYTES_MAX];
    int reads, writes, mode;
};
static enum xrt_status bank_read(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                 unsigned char *raw, size_t size)
{
    struct reg_bank *bank = ctx;
    (void)tid;
    if (!arch || !raw || size != arch->kernel_gpr_bytes)
        return XRT_INVALID_ARGUMENT;
    ++bank->reads;
    if (bank->mode == 2 && bank->writes)
        return XRT_PTRACE_FAILED;
    memcpy(raw, bank->image, size);
    if (bank->mode == 1 && bank->writes)
        raw[size - 1] ^= 1;
    return XRT_OK;
}
static enum xrt_status bank_write(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                  const unsigned char *raw, size_t size)
{
    struct reg_bank *bank = ctx;
    (void)tid;
    if (!arch || !raw || size != arch->kernel_gpr_bytes)
        return XRT_INVALID_ARGUMENT;
    ++bank->writes;
    memcpy(bank->image, raw, size);
    return XRT_OK;
}
static int pending_clear(const struct xrt_breakpoint *probe)
{
    const uint8_t zero[4] = {0};
    return probe->pending && !probe->address && !probe->width && !probe->isa_mode &&
           !probe->alignment && !probe->patched && !memcmp(probe->planted, zero, 4) &&
           !memcmp(probe->original, zero, 4);
}
static struct xrt_breakpoint breakpoint(uint64_t id)
{
    struct xrt_target_view current = view();
    for (size_t i = 0; i < current.breakpoint_count; ++i)
        if (current.breakpoints[i].id == id)
            return current.breakpoints[i];
    CHECK(0);
    return (struct xrt_breakpoint){0};
}
static size_t written_events(void)
{
    size_t count = 0;
    struct xrt_target_view current = view();
    for (size_t i = 0; i < current.event_count; ++i)
        if (current.events[i].kind == XRT_EVENT_REGISTER_WRITTEN)
            ++count;
    return count;
}
static void round_trip(void)
{
    uint8_t *bytes = malloc(XRT_WIRE_MAX_BODY);
    CHECK(bytes);
    struct xrt_codec out = xrt_codec(bytes, XRT_WIRE_MAX_BODY, false);
    xrt_wire_target(&out, target);
    CHECK(out.ok);
    struct xrt_target *decoded = xrt_target_create();
    CHECK(decoded);
    struct xrt_codec in = xrt_codec(bytes, out.at, true);
    xrt_wire_target(&in, decoded);
    CHECK(in.ok && decoded->breakpoint_count == target->breakpoint_count);
    for (size_t i = 0; i < target->breakpoint_count; ++i) {
        const struct xrt_breakpoint *left = &target->breakpoints[i];
        const struct xrt_breakpoint *right = &decoded->breakpoints[i];
        CHECK(right->id == left->id && right->pending == left->pending &&
              right->patched == left->patched && right->enabled == left->enabled &&
              right->width == left->width && right->address == left->address &&
              right->isa_mode == left->isa_mode && right->alignment == left->alignment);
        CHECK(!memcmp(right->planted, left->planted, 4) && !memcmp(right->original, left->original, 4));
    }
    free(decoded);
    free(bytes);
}
static void foundation(void)
{
    target = xrt_target_create();
    CHECK(target);
    const char *argv[] = {"/proc/self/exe", "--fixture", NULL};
    OK(xrt_target_launch(target, argv));
    CHECK(view().state == XRT_STOPPED && target->identity_admitted);
    const int32_t tid = view().pid;
    struct xrt_registers regs;
    OK(xrt_target_registers(target, tid, &regs));
    uint64_t pc = 0;
    OK(xrt_registers_pc(&regs, &pc));
    const uint64_t next_before = target->next_probe_id;
    struct patch_script script = {.accept = {2, 1}, .status = {XRT_OK, XRT_OK}};
    target->patch = scripted_patch;
    target->patch_ctx = &script;
    const uint8_t original[4] = {1, 2, 3, 4};
    const struct xrt_probe_encoding encoding = {.isa_mode = XRT_ISA_MODE_ORDINARY,
                                                .width = 4,
                                                .alignment = 1,
                                                .bytes = {9, 8, 7, 6}};
    CHECK(xrt_target_commit_plant(target, 0x1000, &encoding, original) == XRT_PARTIAL_MEMORY_WRITE);
    CHECK(script.calls == 2 && script.widths[0] == 4 && script.widths[1] == 2);
    CHECK(!memcmp(script.bytes[1], original, 2));
    CHECK(target->plant_cleanup.active && target->plant_cleanup.width == 4 &&
          target->plant_cleanup.address == 0x1000);
    CHECK(!memcmp(target->plant_cleanup.original, original, 4));
    CHECK(!view().breakpoint_count && target->next_probe_id == next_before);
    CHECK(xrt_execution_allowed(target) == XRT_INVALID_STATE);
    CHECK(xrt_target_continue(target) == XRT_INVALID_STATE);
    CHECK(view().state == XRT_STOPPED);
    script.accept[2] = 1;
    script.status[2] = XRT_OK;
    CHECK(xrt_target_retry_plant_cleanup(target) == XRT_PARTIAL_MEMORY_WRITE);
    CHECK(target->plant_cleanup.active && script.calls == 3 && script.widths[2] == 4);
    CHECK(!memcmp(script.bytes[2], original, 4));
    script.accept[3] = 4;
    script.status[3] = XRT_OK;
    OK(xrt_target_retry_plant_cleanup(target));
    CHECK(!target->plant_cleanup.active);
    memset(&script, 0, sizeof(script));
    script.accept[0] = 2;
    script.status[0] = XRT_PTRACE_FAILED;
    script.accept[1] = 2;
    script.status[1] = XRT_OK;
    CHECK(xrt_target_commit_plant(target, 0x1000, &encoding, original) == XRT_PTRACE_FAILED);
    CHECK(!target->plant_cleanup.active && script.calls == 2);
    memset(&script, 0, sizeof(script));
    script.status[0] = XRT_PTRACE_FAILED;
    CHECK(xrt_target_commit_plant(target, 0x1000, &encoding, original) == XRT_PTRACE_FAILED);
    CHECK(script.calls == 1 && !target->plant_cleanup.active);
    memset(&script, 0, sizeof(script));
    script.status[0] = XRT_PTRACE_FAILED;
    uint64_t id = 99;
    const uint64_t next_probe = target->next_probe_id;
    const size_t breakpoints = target->breakpoint_count;
    CHECK(xrt_target_breakpoint_set(target, pc, false, &id) == XRT_PTRACE_FAILED);
    CHECK(id == 99 && target->next_probe_id == next_probe && target->breakpoint_count == breakpoints);
    CHECK(!target->plant_cleanup.active);
    target->patch = delegate_patch;
    OK(xrt_target_breakpoint_set(target, pc, false, &id));
    struct xrt_breakpoint planted = breakpoint(id);
    CHECK(planted.patched && planted.width == xrt_arch_native()->trap_size &&
          planted.planted[0] == xrt_arch_native()->trap[0]);
    OK(xrt_target_breakpoint_remove(target, id));
    target->patch = NULL;
    target->patch_ctx = NULL;

    OK(xrt_target_breakpoint_reserve(target, &id));
    struct xrt_breakpoint pending = breakpoint(id);
    CHECK(pending.enabled && pending_clear(&pending));
    round_trip();
    OK(xrt_target_breakpoint_resolve(target, id, pc));
    planted = breakpoint(id);
    CHECK(!planted.pending && planted.patched && planted.enabled &&
          planted.width == xrt_arch_native()->trap_size && planted.address == pc);
    OK(xrt_target_breakpoint_enable(target, id, false));
    planted = breakpoint(id);
    CHECK(!planted.pending && !planted.patched && !planted.enabled && planted.width &&
          planted.planted[0] == xrt_arch_native()->trap[0]);
    round_trip();
    OK(xrt_target_breakpoint_withdraw(target, id));
    pending = breakpoint(id);
    CHECK(!pending.enabled && pending_clear(&pending));
    OK(xrt_target_breakpoint_resolve(target, id, pc));
    planted = breakpoint(id);
    CHECK(!planted.pending && !planted.patched && !planted.enabled && planted.width);
    OK(xrt_target_breakpoint_remove(target, id));
    OK(xrt_target_breakpoint_restore(target, id, false));
    pending = breakpoint(id);
    CHECK(pending.id == id && !pending.enabled && pending_clear(&pending));
    round_trip();
    OK(xrt_target_breakpoint_remove(target, id));

    const struct xrt_arch *native = xrt_arch_native();
    const char *scratch = native->machine == XRT_X86_64 ? "r10" : "x9";
    struct reg_bank bank = {0};
    struct xrt_reg_io io = {.read = bank_read, .write = bank_write, .ctx = &bank};
    target->reg_io = &io;
    const uint64_t generation = view().generation;
    const size_t written = written_events();
    CHECK(xrt_target_register_write(target, tid, "no_such", 7, 1) == XRT_UNKNOWN_REGISTER);
    CHECK(!target->last_mutation.issued && !target->last_mutation.confirmed);
    CHECK(view().generation == generation && written_events() == written && !bank.writes);
    OK(xrt_target_register_write(target, tid, scratch, strlen(scratch), UINT64_C(0xabcdef)));
    CHECK(target->last_mutation.issued && target->last_mutation.confirmed && bank.writes == 1);
    CHECK(view().generation == generation + 1 && written_events() == written + 1);
    bank.mode = 1;
    bank.reads = bank.writes = 0;
    const uint64_t after_ok = view().generation;
    CHECK(xrt_target_register_write(target, tid, scratch, strlen(scratch), UINT64_C(0xabcdee)) ==
          XRT_PARTIAL_REGISTER_WRITE);
    CHECK(target->last_mutation.issued && !target->last_mutation.confirmed && bank.writes == 1);
    CHECK(view().generation == after_ok + 1 && written_events() == written + 1);
    bank.mode = 2;
    bank.reads = bank.writes = 0;
    const uint64_t after_partial = view().generation;
    CHECK(xrt_target_register_write(target, tid, scratch, strlen(scratch), 1) == XRT_PTRACE_FAILED);
    CHECK(target->last_mutation.issued && !target->last_mutation.confirmed && bank.writes == 1);
    CHECK(view().generation == after_partial + 1 && written_events() == written + 1);
    bank.mode = 0;
    bank.reads = bank.writes = 0;
    const uint64_t before_control = view().generation;
    struct xrt_control_request refused = {.count = 2, .value = {1, 2}};
    CHECK(xrt_target_control_write(target, tid, &refused) == XRT_UNSUPPORTED_CONTROL);
    CHECK(!target->last_mutation.issued && !target->last_mutation.confirmed && !bank.writes);
    CHECK(view().generation == before_control);
    bank.mode = 1;
    struct xrt_control_request one = {.count = 1, .value = {0x1000}};
    CHECK(xrt_target_control_write(target, tid, &one) == XRT_PARTIAL_REGISTER_WRITE);
    CHECK(target->last_mutation.issued && !target->last_mutation.confirmed && bank.writes == 1);
    CHECK(view().generation == before_control + 1 && written_events() == written + 1);
    target->reg_io = NULL;

    target->plant_cleanup.active = 1;
    xrt_target_apply_exec_identity(target, XRT_EXEC_FAILED);
    CHECK(!target->identity_admitted && target->arch && !target->plant_cleanup.active);
    CHECK(xrt_target_register_write(target, tid, scratch, strlen(scratch), 1) ==
          XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(xrt_target_breakpoint_set(target, pc, false, &id) == XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(xrt_target_step(target, tid) == XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(view().state == XRT_STOPPED);
    xrt_target_apply_exec_identity(target, XRT_OK);
    CHECK(target->identity_admitted && target->arch == native);
    OK(xrt_target_breakpoint_reserve(target, &id));
    struct xrt_breakpoint restored = breakpoint(id);
    CHECK(pending_clear(&restored));
    OK(xrt_target_breakpoint_remove(target, id));
    xrt_target_destroy(target);
    target = NULL;
}
static void adopted_child(void)
{
    if (!xrt_arch_native() || xrt_arch_native()->machine != XRT_X86_64)
        return;
    target = xrt_target_create();
    CHECK(target);
    const char *argv[] = {"/proc/self/exe", "--adopt", NULL};
    OK(xrt_target_launch(target, argv));
    OK(xrt_target_set_following(target, true));
    OK(xrt_target_continue(target));
    const uint64_t deadline = xrt_now() + UINT64_C(3000000000);
    int32_t born_pid = 0;
    while (!born_pid) {
        CHECK(xrt_now() < deadline);
        OK(xrt_target_poll(target));
        struct xrt_target_view parent = view();
        if (parent.birth_count && parent.births[0].stopped)
            born_pid = parent.births[0].pid;
        else
            usleep(1000);
    }
    /* Parent admission is cleared so the child must be re-validated, not copied. */
    target->identity_admitted = 0;
    struct xrt_target *born = xrt_target_create();
    CHECK(born);
    /* A reused handle's generation keeps increasing across adoption. */
    born->generation = 41;
    struct xrt_birth birth;
    OK(xrt_target_adopt(target, born_pid, born, &birth));
    CHECK(born->generation > 41);
    CHECK(born->identity_admitted && born->arch == xrt_arch_native());
    CHECK(!target->identity_admitted);
    struct xrt_target_view child_view;
    xrt_target_view(born, &child_view);
    CHECK(child_view.state == XRT_STOPPED && child_view.thread_count == 1);
    const int32_t tid = child_view.threads[0].tid;
    OK(xrt_target_register_write(born, tid, "r10", 3, UINT64_C(0x51a)));
    CHECK(born->last_mutation.issued && born->last_mutation.confirmed);
    struct xrt_registers regs;
    OK(xrt_target_registers(born, tid, &regs));
    uint64_t got = 0;
    OK(xrt_registers_value(&regs, "r10", 3, &got));
    CHECK(got == UINT64_C(0x51a));
    uint64_t pc = 0;
    OK(xrt_registers_pc(&regs, &pc));
    uint64_t id = 0;
    /* The launched image is a separate mapping from this test process. */
    OK(xrt_target_breakpoint_set(born, pc, false, &id));
    CHECK(born->breakpoint_count == 1 && born->breakpoints[0].patched);
    OK(xrt_target_breakpoint_remove(born, id));
    OK(xrt_target_step(born, tid));
    OK(xrt_target_wait_stopped(born));
    xrt_target_view(born, &child_view);
    CHECK(child_view.threads[0].reason == XRT_STOP_SINGLE_STEP);
    /* The adopted task is this test's grandchild and is still ptrace-stopped.
     * close() treats ECHILD as already gone and never continues it, so a
     * queued SIGKILL would not land. Continue the signal, collect the traced
     * death, then let the inferior parent reap the zombie. A SIGCHLD stop is
     * discarded so waitpid is not interrupted before that reap. */
    CHECK(kill(born_pid, SIGKILL) == 0);
    /* SIGKILL can take the tracee out of its stop before this continue. */
    const enum xrt_status resumed = xrt_trace(PTRACE_CONT, born_pid, 0, 0);
    CHECK(resumed == XRT_OK || resumed == XRT_PROCESS_GONE);
    const uint64_t reap_deadline = xrt_now() + UINT64_C(3000000000);
    int status = 0;
    for (;;) {
        CHECK(xrt_now() < reap_deadline);
        const pid_t reaped = waitpid(born_pid, &status, __WALL | WNOHANG);
        if (reaped < 0 && errno == EINTR)
            continue;
        CHECK(reaped >= 0);
        if (!reaped) {
            usleep(1000);
            continue;
        }
        if (WIFSTOPPED(status)) {
            const enum xrt_status again = xrt_trace(PTRACE_CONT, born_pid, 0, 0);
            CHECK(again == XRT_OK || again == XRT_PROCESS_GONE);
            continue;
        }
        CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL);
        break;
    }
    target->identity_admitted = 1;
    while (view().state != XRT_EXITED) {
        CHECK(xrt_now() < reap_deadline);
        OK(xrt_target_poll(target));
        if (view().state == XRT_STOPPED) {
            for (size_t i = 0; i < target->thread_count; ++i)
                target->threads[i].signal = 0;
            OK(xrt_target_continue(target));
        }
        usleep(1000);
    }
    xrt_target_destroy(born);
    xrt_target_destroy(target);
    target = NULL;
}
static void detach_owed_cleanup(void)
{
    target = xrt_target_create();
    CHECK(target);
    const char *argv[] = {"/proc/self/exe", "--fixture", NULL};
    OK(xrt_target_launch(target, argv));
    const int32_t pid = view().pid;
    struct xrt_registers regs;
    OK(xrt_target_registers(target, pid, &regs));
    uint64_t pc = 0;
    OK(xrt_registers_pc(&regs, &pc));
    const uint64_t at = pc + 32;
    uint8_t orig = 0, trap = 0xcc, now = 0;
    size_t count = 0;
    OK(xrt_memory_read(pid, at, &orig, 1, &count));
    OK(xrt_memory_patch(pid, at, &trap, 1, &count));
    target->plant_cleanup.active = 1;
    target->plant_cleanup.address = at;
    target->plant_cleanup.width = 1;
    memset(target->plant_cleanup.original, 0, 4);
    target->plant_cleanup.original[0] = orig;
    OK(xrt_target_detach(target));
    CHECK(!target->plant_cleanup.active && !target->pid);
    count = 0;
    OK(xrt_memory_read(pid, at, &now, 1, &count));
    CHECK(now == orig);
    xrt_target_destroy(target);
    target = NULL;
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {
    }
}

int main(int argc, char **argv)
{
    if (argc == 2 && strcmp(argv[1], "--fixture") == 0)
        return 17;
    if (argc == 2 && strcmp(argv[1], "--adopt") == 0) {
        const pid_t kid = fork();
        if (kid < 0)
            _exit(1);
        if (!kid) {
            for (;;)
                pause();
        }
        int status = 0;
        while (waitpid(kid, &status, 0) < 0) {
            if (errno != EINTR)
                _exit(2);
        }
        _exit(0);
    }
    CHECK(atexit(cleanup) == 0);
    alarm(30);
    mapping_identity();
    core_snapshot();
    legacy_vectors();
    if (getenv("XODB_TEST_NO_LIVE") || !xrt_arch_native()) {
        puts("C target: immutable snapshot passed; live checks skipped");
        return 0;
    }
    foundation();
    launch_restart();
    attach_probes(false);
    attach_probes(true);
    adopted_child();
    detach_owed_cleanup();
    puts("C target: launch, restart, attach, stepping, breakpoint overlays/rearm, watches, "
         "generations, cleanup passed");
    return 0;
}
