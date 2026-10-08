#include "xrt_gdbremote.h"
#include "xrt_remote.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); failed=1; goto done; } } while (0)
int main(int argc, char **argv)
{
    if (argc < 4 || argc > 6) return 2;
    struct xrt_target *t = NULL; int failed = 0;
    uint64_t marker = strtoull(argv[2], NULL, 16), tick = strtoull(argv[3], NULL, 16);
    bool native = !strcmp(argv[1], "native");
    enum xrt_status status;
    if (native) {
        CHECK(argc == 5);
        t = xrt_target_create(); CHECK(t);
        const char *launch[] = { argv[4], NULL };
        status = xrt_target_launch(t, launch);
    } else status = xrt_target_gdb_remote(argv[1], &t);
    CHECK(status == XRT_OK && t);
    struct xrt_target_view view; xrt_target_view(t, &view);
    CHECK(view.state == XRT_STOPPED && view.thread_count > 0);
    int32_t tid = view.threads[0].tid;
    if (!native) {
        struct xrt_gdb_info info; CHECK(xrt_target_gdb_info(t, &info));
        CHECK(info.supported & XRT_GDB_CAP_THREADS);
    }
    struct xrt_registers regs; CHECK(xrt_target_registers(t, tid, &regs) == XRT_OK);
    const char *name = regs.abi.machine == XRT_AARCH64 ? "x0" : "rax";
    size_t name_size = strlen(name);
    uint64_t old_rax; CHECK(xrt_registers_value(&regs, name, name_size, &old_rax) == XRT_OK);
    uint64_t value = 0; size_t count;
    CHECK(xrt_target_read(t, marker, &value, sizeof(value), &count) == XRT_OK);
    CHECK(count == sizeof(value) && value == UINT64_C(0x1122334455667788));
    value = UINT64_C(0x8877665544332211);
    CHECK(xrt_target_write(t, marker, &value, sizeof(value)) == XRT_OK);
    uint64_t actual;
    CHECK(xrt_target_read(t, marker, &actual, sizeof(actual), &count) == XRT_OK && count == 8 && actual == value);
    xrt_target_view(t, &view); uint64_t before = view.generation;
    status = xrt_target_write(t, 1, &value, sizeof(value));
    CHECK(native ? status != XRT_OK : status == XRT_PARTIAL_MEMORY_WRITE);
    xrt_target_view(t, &view); CHECK(native || view.generation > before);
    status = xrt_target_register_write(t, tid, name, name_size, old_rax ^ 0x1234);
    if (status != XRT_OK) fprintf(stderr,"register write status=%d\n",status);
    CHECK(status == XRT_OK);
    CHECK(xrt_target_registers(t, tid, &regs) == XRT_OK);
    CHECK(xrt_registers_value(&regs, name, name_size, &actual) == XRT_OK && actual == (old_rax ^ 0x1234));
    CHECK(xrt_target_register_write(t, tid, name, name_size, old_rax) == XRT_OK);
    if (argc == 6) {
        uint64_t old_pc; CHECK(xrt_registers_pc(&regs, &old_pc) == XRT_OK);
        uint64_t exclusive = strtoull(argv[5], NULL, 16);
        CHECK(xrt_target_register_write(t, tid, "pc", 2, exclusive) == XRT_OK);
        xrt_target_view(t, &view); before = view.generation;
        CHECK(xrt_target_step(t, tid) == XRT_UNSUPPORTED_CONTROL);
        xrt_target_view(t, &view); CHECK(view.generation == before);
        uint64_t atomic_bp; CHECK(xrt_target_breakpoint_set(t, exclusive, false, &atomic_bp) == XRT_OK);
        CHECK(xrt_target_continue(t) == XRT_UNSUPPORTED_CONTROL);
        CHECK(xrt_target_breakpoint_remove(t, atomic_bp) == XRT_OK);
        CHECK(xrt_target_register_write(t, tid, "pc", 2, old_pc) == XRT_OK);
        puts("PASS AArch64 exclusive-load step and breakpoint step-over refuse before execution");
    }
    uint64_t bp; CHECK(xrt_target_breakpoint_set(t, tick, false, &bp) == XRT_OK);
    CHECK(xrt_target_continue(t) == XRT_OK);
    CHECK(xrt_target_wait_stopped(t) == XRT_OK);
    xrt_target_view(t, &view);
    CHECK(view.state == XRT_STOPPED && view.threads[0].reason == XRT_STOP_BREAKPOINT);
    CHECK(view.breakpoints[0].hit_count == 1);
    CHECK(xrt_target_registers(t, tid, &regs) == XRT_OK && xrt_registers_pc(&regs, &actual) == XRT_OK && actual == tick);
    CHECK(xrt_target_continue(t) == XRT_OK);
    CHECK(xrt_target_wait_stopped(t) == XRT_OK);
    xrt_target_view(t, &view);
    CHECK(view.state == XRT_STOPPED && view.threads[0].reason == XRT_STOP_BREAKPOINT && view.breakpoints[0].hit_count == 2);
    CHECK(xrt_target_step(t, tid) == XRT_OK);
    CHECK(xrt_target_wait_stopped(t) == XRT_OK);
    xrt_target_view(t, &view);
    CHECK(view.state == XRT_STOPPED && view.threads[0].reason == XRT_STOP_SINGLE_STEP);
    CHECK(xrt_target_breakpoint_remove(t, bp) == XRT_OK);
    if (native || argc < 5 || strcmp(argv[4], "no-interrupt")) {
        CHECK(xrt_target_continue(t) == XRT_OK);
        CHECK(xrt_target_interrupt(t) == XRT_OK);
        CHECK(xrt_target_wait_stopped(t) == XRT_OK);
        xrt_target_view(t, &view);
        CHECK(view.state == XRT_STOPPED && view.threads[0].reason == XRT_STOP_INTERRUPT);
    } else puts("NOT TESTED in this flow: asynchronous interrupt (separate QEMU failure evidence)");
    if (!native) CHECK(xrt_target_detach(t) == XRT_OK);
    puts("PASS target: registers, verified memory/register writes, failed-write generation, repeated Z0 hit/step-over, step, cleanup");
done:
    if (t) {
        enum xrt_status closed = xrt_target_destroy(t);
        if (closed != XRT_OK) { fprintf(stderr,"cleanup status=%d\n",closed); failed = 1; }
    }
    return failed;
}
