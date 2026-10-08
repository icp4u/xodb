#define _GNU_SOURCE 1
#include "target_internal.h"
#include "xrt_remote.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include "xrt_files.h"
#include "xrt_perf.h"
#include "perf_internal.h"
#include "remote_internal.h"
#include "wire_target.h"
#include "perf_wire.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
static volatile uint64_t watched;
#if defined(__x86_64__)
__attribute__((naked, noinline)) static void marker(void)
{
    __asm__ volatile("addq $1, watched(%rip)\nret");
}
#else
__attribute__((noinline)) static void marker(void)
{
    ++watched;
}
#endif
#define OK(expr)                                                                                   \
    do {                                                                                           \
        enum xrt_status s_ = (expr);                                                               \
        if (s_ != XRT_OK) {                                                                        \
            fprintf(stderr, "%s:%d: %s -> %d\n", __FILE__, __LINE__, #expr, s_);                   \
            abort();                                                                               \
        }                                                                                          \
    } while (0)
static struct xrt_target_view view(struct xrt_target *t)
{
    struct xrt_target_view v;
    xrt_target_view(t, &v);
    return v;
}
static void wait_exit(struct xrt_target *t)
{
    uint64_t deadline = xrt_now() + UINT64_C(5000000000);
    while (view(t).state != XRT_EXITED) {
        assert(xrt_now() < deadline);
        OK(xrt_target_poll(t));
        usleep(1000);
    }
}
static void files(struct xrt_target *t, const char *self, bool latency)
{
    struct xrt_file_request request = {.kind = XRT_FILE_MAPS};
    int fd = -1;
    OK(xrt_target_file(t, &request, &fd));
    assert((fcntl(fd, F_GET_SEALS) & F_SEAL_WRITE) != 0);
    FILE *maps = fdopen(fd, "r");
    assert(maps);
    char *line = NULL;
    size_t cap = 0;
    bool found = false;
    while (getline(&line, &cap, maps) > 0) {
        unsigned long long start, end, offset, major, minor, inode;
        char perm[5];
        int at = 0;
        if (sscanf(line, "%llx-%llx %4s %llx %llx:%llx %llu %n", &start, &end, perm, &offset,
                   &major, &minor, &inode, &at) != 7)
            continue;
        char *path = line + at;
        path[strcspn(path, "\n")] = 0;
        if (strcmp(path, self))
            continue;
        request = (struct xrt_file_request){
            .kind = XRT_FILE_MAPPED, .mapping = {start, end, offset, major, minor, inode, path}};
        int binary = -1;
        OK(xrt_target_file(t, &request, &binary));
        char elf[4];
        assert(read(binary, elf, 4) == 4 && !memcmp(elf, "\177ELF", 4));
        assert(write(binary, "x", 1) == -1 && errno == EPERM);
        close(binary);
        /* A policy refusal leaves this transport usable and retains partial
         * symbol data. A later pass resumes without downloading debug/code. */
        struct xrt_file_budget budget = {.limit_bytes = 64,
                                         .deadline_ns = xrt_now() + UINT64_C(2000000000)};
        xrt_target_file_budget(t, &budget);
        uint64_t resident = 0;
        binary = -1;
        if (latency) budget.deadline_ns = xrt_now() + UINT64_C(25000000);
        assert(xrt_remote_symbol_file(t, &request, &binary, &resident) ==
               (latency ? XRT_DISCOVERY_PENDING : XRT_DISCOVERY_BUDGET));
        assert(binary == -1 && budget.bytes == 16 && budget.files == 1 && budget.reads == 1);
        budget = (struct xrt_file_budget){.limit_bytes = 1024 * 1024,
                                         .deadline_ns = xrt_now() + UINT64_C(2000000000)};
        if (latency) {
            unsigned slices = 0;
            enum xrt_status status;
            do {
                budget = (struct xrt_file_budget){.limit_bytes = 1024 * 1024,
                    .deadline_ns = xrt_now() + UINT64_C(25000000)};
                status = xrt_remote_symbol_file(t, &request, &binary, &resident);
                assert(status == XRT_OK || status == XRT_DISCOVERY_PENDING);
                assert(budget.reads == 1 && budget.files == 0);
                assert(++slices < 128);
            } while (status != XRT_OK);
        } else {
            OK(xrt_remote_symbol_file(t, &request, &binary, &resident));
            assert(budget.files == 0); // Retained handle, not just retained bytes.
        }
        assert((latency || budget.resumed_bytes == 16) && resident > 16 && resident < 1024 * 1024);
        assert((fcntl(binary, F_GET_SEALS) & F_SEAL_WRITE) != 0);
        assert(pread(binary, elf, sizeof(elf), 0) == 4 && !memcmp(elf, "\177ELF", 4));
        close(binary);
        volatile sig_atomic_t cancel = 1;
        budget.cancel = &cancel;
        binary = -1;
        assert(xrt_remote_symbol_file(t, &request, &binary, &resident) == XRT_DISCOVERY_CANCELLED);
        assert(binary == -1);
        xrt_target_file_budget(t, NULL);
        /* Exhausting current-agent slots is a resource refusal, never an
         * instruction to update an already current agent. */
        unsigned char encoded[8192], meta[128];
        struct xrt_codec wire = xrt_codec(encoded, sizeof(encoded), false);
        xrt_wire_file_request(&wire, &request, NULL, 0);
        assert(wire.ok);
        uint64_t handles[32], unused = 0;
        struct xrt_call open = {.op = XRT_RPC_FILE_OPEN, .args = {XRT_RPC_FILE_SYMBOLS},
            .data = encoded, .size = wire.at, .out = meta, .capacity = sizeof(meta)};
        for (unsigned i = 0; i < 32; ++i) {
            open.value = &handles[i];
            OK(xrt_remote_call(t, &open));
        }
        open.value = &unused;
        assert(xrt_remote_call(t, &open) == XRT_FILE_UNAVAILABLE);
        assert(xrt_remote_symbol_file(t, &request, &binary, &resident) == XRT_FILE_UNAVAILABLE);
        for (unsigned i = 0; i < 32; ++i)
            OK(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FILE_CLOSE, .args = {handles[i]}}));
        ++request.mapping.inode;
        assert(xrt_target_file(t, &request, &binary) == XRT_FILE_UNAVAILABLE);
        found = true;
        break;
    }
    free(line);
    fclose(maps);
    assert(found);
    request = (struct xrt_file_request){.kind = XRT_FILE_THREAD_STAT, .tid = view(t).pid};
    OK(xrt_target_file(t, &request, &fd));
    char stat[256];
    assert(read(fd, stat, sizeof(stat)) > 0);
    close(fd);
    request = (struct xrt_file_request){.kind = XRT_FILE_THREAD_COMM, .tid = view(t).pid};
    OK(xrt_target_file(t, &request, &fd));
    char name[32];
    ssize_t named = read(fd, name, sizeof(name));
    assert(named > 1 && name[named - 1] == '\n');
    close(fd);
    request = (struct xrt_file_request){.kind = XRT_FILE_BOOT_ID};
    OK(xrt_target_file(t, &request, &fd));
    char boot[64];
    assert(read(fd, boot, sizeof(boot)) == 37);
    close(fd);
}
static int pending_clear(const struct xrt_breakpoint *probe)
{
    const uint8_t zero[4] = {0};
    return probe->pending && !probe->address && !probe->width && !probe->isa_mode &&
           !probe->alignment && !probe->patched && !memcmp(probe->planted, zero, 4) &&
           !memcmp(probe->original, zero, 4);
}
static struct xrt_breakpoint breakpoint_of(struct xrt_target *t, uint64_t id)
{
    struct xrt_target_view current = view(t);
    for (size_t i = 0; i < current.breakpoint_count; ++i)
        if (current.breakpoints[i].id == id)
            return current.breakpoints[i];
    assert(0);
    return (struct xrt_breakpoint){0};
}
static void architecture_agent(struct xrt_target *t, int32_t pid)
{
    assert(xrt_rpc_classify(XRT_RPC_ALLOCATIONS_START) == XRT_RPC_CLASS_PERF);
    assert(xrt_rpc_classify(XRT_RPC_FUNCTION_START) == XRT_RPC_CLASS_PERF);
    assert(xrt_rpc_classify(XRT_RPC_CONTROL_WRITE) == XRT_RPC_CLASS_MUTATION);
    assert(xrt_rpc_classify(XRT_RPC_SOURCE_OPEN) == XRT_RPC_CLASS_FILE);
    assert(xrt_rpc_classify(56) == XRT_RPC_CLASS_PROTOCOL);
    uint64_t packed = 1;
    assert(xrt_remote_call(t, &(struct xrt_call){.op = 56, .value = &packed}) == XRT_PROTOCOL_ERROR);
    struct xrt_registers regs;
    OK(xrt_target_registers(t, pid, &regs));
    uint64_t pc = 0;
    OK(xrt_registers_pc(&regs, &pc));
    uint64_t id = 0;
    OK(xrt_target_breakpoint_reserve(t, &id));
    struct xrt_breakpoint pending = breakpoint_of(t, id);
    assert(pending.enabled && pending_clear(&pending));
    OK(xrt_target_breakpoint_resolve(t, id, (uintptr_t)marker));
    struct xrt_breakpoint planted = breakpoint_of(t, id);
    assert(!planted.pending && planted.patched && planted.width == xrt_arch_native()->trap_size);
    OK(xrt_target_breakpoint_enable(t, id, false));
    planted = breakpoint_of(t, id);
    assert(!planted.pending && !planted.patched && !planted.enabled && planted.width &&
           planted.planted[0] == xrt_arch_native()->trap[0]);
    OK(xrt_target_breakpoint_withdraw(t, id));
    pending = breakpoint_of(t, id);
    assert(!pending.enabled && pending_clear(&pending));
    OK(xrt_target_breakpoint_resolve(t, id, (uintptr_t)marker));
    planted = breakpoint_of(t, id);
    assert(!planted.pending && !planted.patched && planted.width);
    OK(xrt_target_breakpoint_remove(t, id));
    OK(xrt_target_breakpoint_restore(t, id, false));
    pending = breakpoint_of(t, id);
    assert(pending.id == id && !pending.enabled && pending_clear(&pending));
    OK(xrt_target_breakpoint_remove(t, id));
    struct xrt_control_request one = {.count = 1, .value = {pc}};
    OK(xrt_target_control_write(t, pid, &one));
    assert(t->last_mutation.issued == 1 && t->last_mutation.confirmed == 1);
    struct xrt_control_request two = {.count = 2, .value = {pc, pc}};
    assert(xrt_target_control_write(t, pid, &two) == XRT_UNSUPPORTED_CONTROL);
    assert(!t->last_mutation.issued && !t->last_mutation.confirmed);
    uint8_t body[8];
    uint64_t word = pc;
    struct xrt_codec encoded = xrt_codec(body, sizeof(body), false);
    xrt_codec_u64(&encoded, &word);
    assert(encoded.ok);
    const uint64_t generation = t->generation;
    t->generation = generation - 1;
    packed = 99;
    assert(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CONTROL_WRITE,
                                                  .args = {(uint64_t)pid, 1, 0},
                                                  .data = body,
                                                  .size = 8,
                                                  .value = &packed}) == XRT_STALE_SNAPSHOT);
    assert(packed == 0 && t->generation == generation);
    packed = 99;
    assert(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CONTROL_WRITE,
                                                  .args = {(uint64_t)pid, 0, 0},
                                                  .value = &packed}) == XRT_INVALID_ARGUMENT);
    assert(packed == 0);
    packed = 99;
    assert(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CONTROL_WRITE,
                                                  .args = {(uint64_t)pid, 1, 1},
                                                  .data = body,
                                                  .size = 8,
                                                  .value = &packed}) == XRT_INVALID_ARGUMENT);
    assert(packed == 0);
    packed = 99;
    assert(xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_CONTROL_WRITE,
                                                  .args = {(uint64_t)pid, 1, 0},
                                                  .data = body,
                                                  .size = 3,
                                                  .value = &packed}) == XRT_INVALID_ARGUMENT);
    assert(packed == 0);
}
static void probes(const char *agent, const char *self)
{
    const char *transport[] = {agent, "--stdio", NULL};
    struct xrt_target *t = NULL;
    OK(xrt_target_remote(transport, &t));
    assert(xrt_target_is_remote(t));
    struct xrt_clock clock;
    assert(xrt_target_clock(t, &clock));
    assert(xrt_target_timestamp(t, clock.producer_ns) == clock.host_ns);
    assert(xrt_target_tick_hz(t) == (uint64_t)sysconf(_SC_CLK_TCK));
    assert(xrt_target_page_size(t) == (uint64_t)sysconf(_SC_PAGESIZE));
    const char *argv[] = {self, "--fixture", NULL};
    OK(xrt_target_launch(t, argv));
    struct xrt_target_view v = view(t);
    assert(v.state == XRT_STOPPED && v.owned && v.thread_count == 1);
    files(t, self, false);
    const int32_t pid = v.pid;
    const uint64_t address = (uintptr_t)marker;
    struct xrt_registers regs;
    OK(xrt_target_registers(t, pid, &regs));
    assert(regs.abi.machine == xrt_arch_native()->machine);
    if (regs.abi.machine == XRT_X86_64) {
        struct xrt_xstate x;
        OK(xrt_target_extended(t, pid, &x));
        assert(x.vector_count >= 16);
    }
    architecture_agent(t, pid);
    uint64_t bp, watch;
    OK(xrt_target_breakpoint_set(t, address, false, &bp));
    uint8_t overlaid[4], original[4];
    size_t count = 0;
    size_t trap = xrt_arch_native()->trap_size;
    memcpy(original, (const void *)(uintptr_t)address, trap);
    assert(xrt_target_read(t, address, NULL, trap, &count) == XRT_INVALID_ARGUMENT);
    assert(xrt_target_read(t, address, overlaid, trap, NULL) == XRT_INVALID_ARGUMENT);
    assert(xrt_target_breakpoint_set(t, address, false, NULL) == XRT_INVALID_ARGUMENT);
    OK(xrt_target_read(t, address, overlaid, trap, &count));
    assert(count == trap && !memcmp(original, overlaid, trap));
    uint8_t watch_slots = 0;
    const enum xrt_status watch_cap = xrt_target_watchpoint_capacity(t, &watch_slots);
    if (watch_cap != XRT_OK) {
        assert(watch_cap == XRT_UNSUPPORTED_ARCHITECTURE);
        --t->generation;
        assert(xrt_target_continue(t) == XRT_STALE_SNAPSHOT);
        assert(view(t).state == XRT_STOPPED);
        OK(xrt_target_continue(t));
        OK(xrt_target_wait_stopped(t));
        assert(view(t).threads[0].reason == XRT_STOP_BREAKPOINT);
        struct xrt_signal_info sig;
        OK(xrt_target_signal_info(t, pid, &sig));
        assert(sig.number == SIGTRAP);
        struct xrt_step_resources step_resources;
        OK(xrt_arch_step_resources(xrt_arch_native(), XRT_ISA_MODE_ORDINARY, &step_resources));
        if (step_resources.hardware_step || step_resources.software_probes) {
            OK(xrt_target_step(t, pid));
            OK(xrt_target_wait_stopped(t));
            assert(view(t).threads[0].reason == XRT_STOP_SINGLE_STEP && view(t).breakpoints[0].patched);
        } else {
            assert(xrt_target_continue(t) == XRT_UNSUPPORTED_CONTROL);
            assert(xrt_target_step(t, pid) == XRT_UNSUPPORTED_CONTROL);
            assert(view(t).state == XRT_STOPPED && view(t).breakpoints[0].patched);
        }
        OK(xrt_target_breakpoint_remove(t, bp));
        OK(xrt_target_continue(t));
        wait_exit(t);
        uint64_t epoch = view(t).image_epoch;
        OK(xrt_target_reset(t));
        OK(xrt_target_launch(t, argv));
        assert(view(t).image_epoch > epoch);
        int32_t restarted = view(t).pid;
        OK(xrt_target_destroy(t));
        assert(kill(restarted, 0) == -1 && errno == ESRCH);
        return;
    }
    OK(xrt_target_watchpoint_set(t, (uintptr_t)&watched, 8, XRT_WATCH_WRITE, &watch));
    /* A stale client cannot resume the authoritative agent target. */
    --t->generation;
    assert(xrt_target_continue(t) == XRT_STALE_SNAPSHOT);
    assert(view(t).state == XRT_STOPPED);
    OK(xrt_target_continue(t));
    OK(xrt_target_wait_stopped(t));
    assert(view(t).threads[0].reason == XRT_STOP_BREAKPOINT);
    struct xrt_signal_info sig;
    OK(xrt_target_signal_info(t, pid, &sig));
    assert(sig.number == SIGTRAP);
    OK(xrt_target_continue(t));
    OK(xrt_target_wait_stopped(t));
    assert(view(t).threads[0].reason == XRT_STOP_WATCHPOINT && view(t).breakpoints[0].patched);
    bool hit = false;
    v = view(t);
    for (size_t i = 0; i < v.event_count; ++i)
        if (v.events[i].kind == XRT_EVENT_WATCHPOINT_HIT) {
            assert(v.events[i].before == 0 && v.events[i].after == 1);
            hit = true;
        }
    assert(hit);
    OK(xrt_target_watchpoint_remove(t, watch));
    OK(xrt_target_breakpoint_remove(t, bp));
    OK(xrt_target_continue(t));
    wait_exit(t);
    uint64_t epoch = view(t).image_epoch;
    OK(xrt_target_reset(t));
    OK(xrt_target_launch(t, argv));
    assert(view(t).image_epoch > epoch);
    int32_t restarted = view(t).pid;
    OK(xrt_target_destroy(t));
    assert(kill(restarted, 0) == -1 && errno == ESRCH);
}
static void reap_family_child(pid_t pid)
{
    const uint64_t deadline = xrt_now() + UINT64_C(5000000000);
    for (;;) {
        int status = 0;
        const pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) {
            assert(WIFEXITED(status) || WIFSIGNALED(status));
            return;
        }
        if (got < 0) {
            if (errno == EINTR)
                continue;
            /* The fixture parent may have reaped it before being destroyed. */
            assert(errno == ECHILD);
            assert(kill(pid, 0) == -1 && errno == ESRCH);
            return;
        }
        assert(xrt_now() < deadline);
        usleep(1000);
    }
}
static void family(const char *agent, const char *self)
{
    const char *transport[] = {agent, "--stdio", NULL};
    struct xrt_target *parent = NULL;
    OK(xrt_target_remote(transport, &parent));
    const char *argv[] = {self, "--fork-fixture", NULL};
    OK(xrt_target_launch(parent, argv));
    OK(xrt_target_set_following(parent, true));
    OK(xrt_target_continue(parent));
    uint64_t deadline = xrt_now() + UINT64_C(5000000000);
    for (;;) {
        const struct xrt_target_view current = view(parent);
        if (current.birth_count) {
            assert(current.birth_count == 1 && !current.births[0].exited);
            /* The parent's fork event can precede the child's initial stop. */
            if (current.state == XRT_STOPPED && current.births[0].stopped)
                break;
        }
        assert(xrt_now() < deadline);
        OK(xrt_target_poll(parent));
        usleep(1000);
    }
    const int32_t child_pid = view(parent).births[0].pid, parent_pid = view(parent).pid;
    struct xrt_target *child = xrt_target_create();
    assert(child);
    struct xrt_birth birth;
    OK(xrt_target_adopt(parent, child_pid, child, &birth));
    assert(xrt_target_is_remote(child));
    assert(view(child).pid == child_pid && view(child).state == XRT_STOPPED &&
           view(parent).birth_count == 0);
    OK(xrt_target_destroy(child));
    OK(xrt_target_destroy(parent));
    /* ptrace can reap its stop while the real parent's zombie remains. Own
     * that orphan here rather than depending on PID 1 or an outer runner. */
    reap_family_child(child_pid);
    assert(kill(child_pid, 0) == -1 && errno == ESRCH);
    assert(kill(parent_pid, 0) == -1 && errno == ESRCH);
}
struct sampled {
    unsigned count;
    bool retry, retried;
    uint64_t tail;
    struct xrt_perf *perf;
};
static struct xrt_perf_consumed samples(void *raw, const struct xrt_perf_ring *ring)
{
    struct sampled *state = raw;
    unsigned *count = &state->count;
    if (ring->head > ring->tail && !state->retried) {
        if (!state->retry) {
            uint8_t header[8];
            assert(xrt_perf_copy(ring->data, ring->size, ring->tail, header, 8));
            uint16_t record;
            memcpy(&record, header + 6, 2);
            if (record > 8) {
                uint8_t bytes[256];
                size_t size = 0;
                OK(xrt_remote_call(
                    state->perf->remote_target,
                    &(struct xrt_call){.op = XRT_RPC_PERF_ACK,
                                       .args = {state->perf->remote_id, ring->tail, 8},
                                       .out = bytes,
                                       .capacity = sizeof(bytes),
                                       .length = &size}));
                struct xrt_codec in = xrt_codec(bytes, size, true);
                bool ok = true;
                xrt_codec_bool(&in, &ok);
                assert(in.ok && !ok);
            }
            state->retry = true;
            state->tail = ring->tail;
            return (struct xrt_perf_consumed){0, XRT_PERF_DRAIN_CAPACITY};
        }
        assert(ring->tail == state->tail);
        state->retried = true;
    }
    uint64_t tail = ring->tail;
    while (tail < ring->head) {
        uint8_t header[8];
        assert(xrt_perf_copy(ring->data, ring->size, tail, header, 8));
        uint16_t size;
        uint32_t type;
        memcpy(&size, header + 6, 2);
        memcpy(&type, header, 4);
        assert(size >= 8 && !(size & 7) && size <= ring->head - tail);
        if (type == 9)
            ++*count;
        tail += size;
    }
    return (struct xrt_perf_consumed){tail - ring->tail, XRT_PERF_DRAIN_OK};
}
static void collectors(const char *agent, const char *self)
{
    const char *transport[] = {agent, "--stdio", NULL};
    struct xrt_target *t = NULL;
    OK(xrt_target_remote(transport, &t));
    const char *argv[] = {self, "--cpu-fixture", NULL};
    OK(xrt_target_launch(t, argv));
    int32_t tid = view(t).pid;
    struct xrt_perf_failure failure = {0};
    struct xrt_cpu_acceptance acceptance;
    struct xrt_cpu_config config = {.tids = &tid,
                                    .thread_count = 1,
                                    .frequency_hz = 499,
                                    .max_frames = 16,
                                    .data_pages = 4,
                                    .ring_budget_bytes = 4 * 1024 * 1024,
                                    .exclude_kernel = true,
                                    .callchain = true};
    struct xrt_perf *p = xrt_cpu_start_target(t, &config, &acceptance, &failure);
    if (!p) {
        assert(failure.error == EACCES || failure.error == EPERM || failure.error == ENOSYS);
        OK(xrt_target_destroy(t));
        puts("remote perf denied by kernel policy");
        return;
    }
    assert(xrt_target_destroy(t) == XRT_INVALID_STATE);
    struct xrt_perf_info info;
    xrt_perf_info(p, &info);
    assert(info.threads == 1 && info.running);
    struct xrt_perf_thread thread;
    assert(xrt_perf_thread(p, 0, &thread) && thread.tid == tid && thread.event_count == 1);
    struct sampled samples_state = {.perf = p};
    OK(xrt_target_continue(t));
    uint64_t deadline = xrt_now() + UINT64_C(5000000000);
    while (view(t).state != XRT_EXITED) {
        assert(xrt_now() < deadline);
        OK(xrt_target_poll(t));
        enum xrt_perf_drain_status drained = xrt_perf_drain(p, samples, &samples_state);
        assert(drained == XRT_PERF_DRAIN_OK || drained == XRT_PERF_DRAIN_CAPACITY);
        usleep(2000);
    }
    assert(xrt_perf_stop(p, &failure));
    while (xrt_perf_drain(p, samples, &samples_state) == XRT_PERF_DRAIN_CAPACITY) {
    }
    assert(samples_state.count > 0 && samples_state.retried);
    xrt_perf_destroy(p);
    OK(xrt_target_destroy(t));
}
static int delayed_proxy(const char *agent, bool symbols)
{
    int pair[2];
    assert(!socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair));
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(dup2(pair[1], STDIN_FILENO) >= 0 && dup2(pair[1], STDOUT_FILENO) >= 0);
        close(pair[0]); close(pair[1]);
        execl(agent, agent, "--stdio", (char *)NULL);
        _exit(127);
    }
    close(pair[1]);
    int streams[] = {STDIN_FILENO, STDOUT_FILENO, pair[0]};
    for (unsigned i = 0; i < 3; ++i) {
        int flags = fcntl(streams[i], F_GETFL);
        assert(flags >= 0 && !fcntl(streams[i], F_SETFL, flags | O_NONBLOCK));
    }
    unsigned char *body = malloc(XRT_WIRE_MAX_BODY);
    assert(body);
    bool delayed = false;
    for (;;) {
        struct xrt_wire_frame frame;
        enum xrt_wire_result got = xrt_wire_read(STDIN_FILENO, &frame, body, XRT_WIRE_MAX_BODY, 10000);
        if (got == XRT_WIRE_EOF) break;
        assert(got == XRT_WIRE_OK);
        bool delay = symbols ? (frame.op == XRT_RPC_FILE_OPEN || frame.op == XRT_RPC_FILE_READ) :
            frame.op == XRT_RPC_READ && !delayed;
        assert(xrt_wire_write(pair[0], &frame, body, 10000) == XRT_WIRE_OK);
        assert(xrt_wire_read(pair[0], &frame, body, XRT_WIRE_MAX_BODY, 10000) == XRT_WIRE_OK);
        if (delay) { usleep(symbols ? 35000 : 350000); delayed = true; }
        assert(xrt_wire_write(STDOUT_FILENO, &frame, body, 10000) == XRT_WIRE_OK);
    }
    free(body); close(pair[0]);
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    return 0;
}
static void late_reply(const char *agent, const char *self)
{
    struct xrt_target *target = NULL;
    const char *transport[] = {self, "--delay-proxy", agent, NULL};
    OK(xrt_target_remote(transport, &target));
    const char *fixture[] = {self, "--fixture", NULL};
    OK(xrt_target_launch(target, fixture));
    struct xrt_file_budget budget = {.limit_bytes = 4096,
                                     .deadline_ns = xrt_now() + UINT64_C(200000000)};
    xrt_target_file_budget(target, &budget);
    unsigned char bytes[8];
    size_t got = 0;
    OK(xrt_target_read(target, (uint64_t)(uintptr_t)marker, bytes, sizeof(bytes), &got));
    assert(got == sizeof(bytes) && xrt_now() > budget.deadline_ns);
    /* Only file requests yield. Registers, memory and breakpoint control must
     * still work under the exhausted budget that completed discovery. */
    struct xrt_file_request file = {.kind = XRT_FILE_MAPS};
    int fd = -1;
    assert(xrt_target_file(target, &file, &fd) == XRT_DISCOVERY_PENDING);
    OK(xrt_target_read(target, (uint64_t)(uintptr_t)marker, bytes, sizeof(bytes), &got));
    struct xrt_registers regs;
    OK(xrt_target_registers(target, view(target).pid, &regs));
    uint64_t id;
    OK(xrt_target_breakpoint_reserve(target, &id));
    OK(xrt_target_breakpoint_resolve(target, id, (uintptr_t)marker));
    assert(!breakpoint_of(target, id).pending);
    OK(xrt_target_breakpoint_remove(target, id));
    budget.deadline_ns = xrt_now() + UINT64_C(2000000000);
    budget.bytes = budget.limit_bytes;
    assert(xrt_target_file(target, &file, &fd) == XRT_DISCOVERY_BUDGET);
    OK(xrt_target_breakpoint_reserve(target, &id));
    OK(xrt_target_breakpoint_resolve(target, id, (uintptr_t)marker));
    OK(xrt_target_breakpoint_remove(target, id));
    xrt_target_file_budget(target, NULL);
    OK(xrt_target_read(target, (uint64_t)(uintptr_t)marker, bytes, sizeof(bytes), &got));
    OK(xrt_target_destroy(target));
    puts("C discovery deadline: file requests defer; breakpoint installation and reads remain usable");
}
int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--delay-proxy")) return delayed_proxy(argv[2], false);
    if (argc == 3 && !strcmp(argv[1], "--symbol-delay-proxy")) return delayed_proxy(argv[2], true);
    /* These synthetic tracees skip exit-time LeakSanitizer, whose helper
     * cannot ptrace an already-traced process. Memory accesses are still
     * instrumented; the controller, proxy and agent retain leak checks. */
    if (argc == 2 && !strcmp(argv[1], "--cpu-fixture")) {
        volatile unsigned long value = 7;
        for (unsigned i = 0; i < 80000000; ++i)
            value = value * 1664525 + 1013904223;
        _exit(value == 0);
    }
    if (argc == 2 && !strcmp(argv[1], "--fixture")) {
        marker();
        marker();
        _exit(23);
    }
    if (argc == 2 && !strcmp(argv[1], "--fork-fixture")) {
        pid_t child = fork();
        if (child < 0)
            _exit(2);
        if (!child) {
            marker();
            _exit(0);
        }
        waitpid(child, NULL, 0);
        _exit(0);
    }
    assert(argc == 2);
    alarm(30);
    char self[4096];
    ssize_t size = readlink("/proc/self/exe", self, sizeof(self) - 1);
    assert(size > 0);
    self[size] = 0;
    if (getenv("XODB_TEST_NO_LIVE") || !xrt_arch_native()) {
        puts("C remote live checks explicitly skipped");
        return 0;
    }
    assert(prctl(PR_SET_CHILD_SUBREAPER, 1) == 0);
    late_reply(argv[1], self);
    struct xrt_target *slow = NULL;
    const char *transport[] = {self, "--symbol-delay-proxy", argv[1], NULL};
    const char *fixture[] = {self, "--fixture", NULL};
    OK(xrt_target_remote(transport, &slow));
    OK(xrt_target_launch(slow, fixture));
    files(slow, self, true);
    OK(xrt_target_destroy(slow));
    puts("C symbol discovery: delayed opens permit a read; later slices retain the agent file");
    probes(argv[1], self);
    if (xrt_arch_native()->machine == XRT_X86_64)
        collectors(argv[1], self);
    if (xrt_arch_native()->machine == XRT_X86_64)
        family(argv[1], self);
    struct xrt_target *bad = NULL;
    const char *missing[] = {"/xodb-no-agent", NULL};
    assert(xrt_target_remote(missing, &bad) == XRT_TRANSPORT_FAILED && !bad);
    puts("C proxy/agent: launch, stale generations, registers, overlays, combined watch/step, "
         "restart, fork adoption and cleanup passed");
    return 0;
}
