/* Build with arch.c/registers.c and an ordinary C compiler. An optional argv[1]
 * names an i386 executable for the x86-64 live ABI-mismatch regression. */
#define _GNU_SOURCE 1
#include "xrt_arch.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>
#if defined(__x86_64__) && !defined(__ILP32__)
#include <sys/user.h>
#endif

static pid_t child;
static void cleanup(void)
{
    if (child <= 0)
        return;
    kill(child, SIGKILL);
    int status;
    for (;;) {
        const pid_t result = waitpid(child, &status, 0);
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0 || WIFEXITED(status) || WIFSIGNALED(status))
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

static uint64_t word(size_t i)
{
    return UINT64_C(0x1020304050607080) + i;
}

static void descriptors(void)
{
    const uint16_t machines[] = {XRT_X86_64, XRT_AARCH64};
    unsigned char bytes[XRT_GPR_BYTES_MAX + 1];
    for (size_t i = 0; i < XRT_GPR_BYTES_MAX / 8; ++i)
        for (size_t b = 0; b < 8; ++b)
            bytes[1 + i * 8 + b] = (unsigned char)(word(i) >> (b * 8));
    for (size_t m = 0; m < 2; ++m) {
        const struct xrt_arch *arch = xrt_arch_get(machines[m]);
        CHECK(arch && arch->address_bits == 64 && arch->little_endian);
        struct xrt_registers regs;
        CHECK(xrt_registers_decode(arch->machine, bytes + 1, arch->kernel_gpr_bytes, &regs) ==
              XRT_OK);
        CHECK(regs.machine == arch->machine);
        if (regs.machine == XRT_X86_64) {
            CHECK(regs.values.x86.rip == word(16) && regs.values.x86.rsp == word(19));
            CHECK(regs.values.x86.rax == word(10) && regs.values.x86.eflags == word(18));
            CHECK(regs.values.x86.r15 == word(0) && regs.values.x86.r8 == word(9));
        } else {
            CHECK(regs.values.arm.x0 == word(0) && regs.values.arm.x30 == word(30));
            CHECK(regs.values.arm.sp == word(31) && regs.values.arm.pc == word(32));
            CHECK(regs.values.arm.pstate == word(33));
        }
        uint64_t values[XRT_DWARF_REGISTER_COUNT];
        memset(values, 0xa5, sizeof(values));
        CHECK(xrt_registers_dwarf(&regs, values, arch->dwarf_count - 1) == XRT_BUFFER_TOO_SMALL);
        for (size_t i = 0; i < XRT_DWARF_REGISTER_COUNT; ++i)
            CHECK(values[i] == UINT64_C(0xa5a5a5a5a5a5a5a5));
        CHECK(xrt_registers_dwarf(&regs, values, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
        if (regs.machine == XRT_X86_64) {
            const unsigned indices[] = {10, 12, 11, 5, 13, 14, 4, 19, 9, 8, 7, 6, 3, 2, 1, 0, 16};
            for (size_t i = 0; i < 17; ++i)
                CHECK(values[i] == word(indices[i]));
            for (size_t i = 17; i < XRT_DWARF_REGISTER_COUNT; ++i)
                CHECK(values[i] == UINT64_C(0xa5a5a5a5a5a5a5a5));
        } else {
            for (size_t i = 0; i < 33; ++i)
                CHECK(values[i] == word(i));
        }
        for (size_t i = 0; i < arch->register_count; ++i) {
            const struct xrt_register_desc *reg = &arch->registers[i];
            CHECK(reg->width == 8 && reg->kernel_offset + 8 <= arch->kernel_gpr_bytes);
            CHECK((size_t)reg->snapshot_offset + 8 <= sizeof(regs.values));
            CHECK(xrt_arch_register(arch->machine, reg->name, strlen(reg->name)) == reg);
            if (reg->dwarf != XRT_DWARF_NONE)
                CHECK(strcmp(xrt_arch_dwarf_name(arch->machine, reg->dwarf), reg->name) == 0);
        }
        CHECK(xrt_arch_register(arch->machine, "pc\0hidden", 9) == NULL);
        CHECK(xrt_arch_dwarf_name(arch->machine, XRT_DWARF_NONE) == NULL);
        CHECK(xrt_arch_dwarf_name(arch->machine, arch->dwarf_count) == NULL);
        struct xrt_registers saved;
        memset(&saved, 0xa5, sizeof(saved));
        for (size_t size = 0; size <= XRT_GPR_BYTES_MAX + 1; ++size) {
            if (size == arch->kernel_gpr_bytes)
                continue;
            memcpy(&regs, &saved, sizeof(regs));
            CHECK(xrt_registers_decode(arch->machine, bytes + 1, size, &regs) ==
                  XRT_UNEXPECTED_REGISTER_SIZE);
            CHECK(memcmp(&regs, &saved, sizeof(regs)) == 0);
        }
    }
    struct xrt_registers regs;
    CHECK(xrt_arch_get(0) == NULL);
    CHECK(xrt_registers_decode(0, bytes, 0, &regs) == XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(xrt_registers_decode(XRT_X86_64, NULL, 216, &regs) == XRT_INVALID_ARGUMENT);
    uint64_t pc = 99;
    CHECK(!xrt_arch_breakpoint_pc(XRT_X86_64, 0, &pc) && pc == 99);
    CHECK(xrt_arch_breakpoint_pc(XRT_X86_64, 0x1001, &pc) && pc == 0x1000);
    CHECK(xrt_arch_breakpoint_pc(XRT_AARCH64, 0x1000, &pc) && pc == 0x1000);
    CHECK(xrt_arch_caller_pc(XRT_AARCH64, 0x1000, &pc) && pc == 0xffc);
    CHECK(!xrt_arch_caller_pc(XRT_AARCH64, 3, &pc) && pc == 0xffc);
    CHECK(xrt_arch_breakpoint_valid(XRT_X86_64, 0x1001, 1));
    CHECK(!xrt_arch_breakpoint_valid(XRT_X86_64, 0x1001, 4));
    CHECK(xrt_arch_breakpoint_valid(XRT_AARCH64, 0x1000, 4));
    CHECK(!xrt_arch_breakpoint_valid(XRT_AARCH64, 0x1001, 4));
    /* Unaligned input and big-endian Linux m68k layout on any build host. */
    unsigned char m68k[81] = {0};
    for (unsigned i = 0; i < 20; ++i) {
        uint32_t value = UINT32_C(0x10203040) + i;
        for (unsigned b = 0; b < 4; ++b)
            m68k[1 + 4 * i + b] = (unsigned char)(value >> (24 - 8 * b));
    }
    CHECK(xrt_registers_decode(XRT_M68K, m68k + 1, 80, &regs) == XRT_OK);
    CHECK(regs.values.m68k.d0 == UINT32_C(0x1020304e));
    CHECK(regs.values.m68k.d1 == UINT32_C(0x10203040));
    CHECK(regs.values.m68k.usp == UINT32_C(0x1020304f));
    CHECK(regs.values.m68k.pc == UINT32_C(0x10203052));
    CHECK(regs.values.m68k.sr == UINT32_C(0x3051));
    uint64_t dwarf[XRT_DWARF_REGISTER_COUNT];
    memset(dwarf, 0xa5, sizeof(dwarf));
    CHECK(xrt_registers_dwarf(&regs, dwarf, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    CHECK(dwarf[0] == regs.values.m68k.d0 && dwarf[15] == regs.values.m68k.usp &&
          dwarf[24] == regs.values.m68k.pc);
    CHECK(dwarf[16] == 0 && xrt_arch_dwarf_name(XRT_M68K, 16) == NULL);
    CHECK(xrt_arch_breakpoint_pc(XRT_M68K, 0x1002, &pc) && pc == 0x1000);
    CHECK(xrt_arch_breakpoint_valid(XRT_M68K, 0x1000, 2));
    CHECK(!xrt_arch_breakpoint_valid(XRT_M68K, 0x1001, 2));
}

static void stopped_child(const char *executable)
{
    const pid_t parent = getpid();
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent)
            _exit(2);
        if (ptrace(PTRACE_TRACEME, 0, (void *)0, (void *)0) < 0)
            _exit(3);
        if (executable) {
            execl(executable, executable, (char *)NULL);
            _exit(4);
        }
        raise(SIGSTOP);
        _exit(0);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child && WIFSTOPPED(status));
    CHECK(ptrace(PTRACE_SETOPTIONS, child, (void *)0, (void *)(uintptr_t)PTRACE_O_EXITKILL) == 0);
}

int main(int argc, char **argv)
{
    descriptors();
    const struct xrt_arch *arch = xrt_arch_native();
    const char *no_live = getenv("XODB_TEST_NO_LIVE");
    if (!arch || (no_live && strcmp(no_live, "1") == 0)) {
        if (!arch) {
            struct xrt_registers regs;
            CHECK(xrt_registers_read(0, &regs) == XRT_UNSUPPORTED_ARCHITECTURE);
        }
        puts("C register descriptors/decoders passed; native ptrace disabled or unsupported");
        return 0;
    }
    CHECK(atexit(cleanup) == 0);
    alarm(20);
    stopped_child(NULL);
    struct xrt_registers before, after;
    CHECK(xrt_registers_read(child, &before) == XRT_OK);
#if defined(__x86_64__) && !defined(__ILP32__)
    struct user_regs_struct kernel_before, kernel_after;
    CHECK(ptrace(PTRACE_GETREGS, child, (void *)0, &kernel_before) == 0);
#define COMPARE_KERNEL(name, dwarf, word_index) CHECK(before.values.x86.name == kernel_before.name);
    XRT_X86_REGISTERS(COMPARE_KERNEL)
#undef COMPARE_KERNEL
#endif
    uint64_t values[XRT_DWARF_REGISTER_COUNT];
    CHECK(xrt_registers_dwarf(&before, values, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    CHECK(values[arch->pc] != 0 && values[arch->sp] != 0);
    const char *scratch = arch->machine == XRT_X86_64 ? "r10" : "x9";
    CHECK(xrt_register_write(child, scratch, strlen(scratch), UINT64_C(0xabcdef1234567890)) ==
          XRT_OK);
    CHECK(xrt_registers_read(child, &after) == XRT_OK);
    if (arch->machine == XRT_X86_64)
        CHECK(after.values.x86.r10 == UINT64_C(0xabcdef1234567890));
    else
        CHECK(after.values.arm.x9 == UINT64_C(0xabcdef1234567890));
    CHECK(xrt_register_write(child, "fs_base", 7, 0) == XRT_UNKNOWN_REGISTER);
    CHECK(xrt_register_write(child, "rax\0", 4, 0) == XRT_UNKNOWN_REGISTER);
    CHECK(xrt_register_write_pc(child, values[arch->pc]) == XRT_OK);
#if defined(__x86_64__) && !defined(__ILP32__)
    CHECK(ptrace(PTRACE_GETREGS, child, (void *)0, &kernel_after) == 0);
    kernel_before.r10 = UINT64_C(0xabcdef1234567890);
    CHECK(memcmp(&kernel_before, &kernel_after, sizeof(kernel_before)) == 0);
#endif
    cleanup();
    if (argc > 1 && arch->machine == XRT_X86_64) {
        stopped_child(argv[1]);
        memset(&before, 0xa5, sizeof(before));
        memcpy(&after, &before, sizeof(after));
        CHECK(xrt_registers_read(child, &after) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(memcmp(&before, &after, sizeof(before)) == 0);
        CHECK(xrt_register_write(child, "rax", 3, 0) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(xrt_register_write_pc(child, 0) == XRT_UNEXPECTED_REGISTER_SIZE);
        cleanup();
    }
    alarm(0);
    puts("C registers passed: descriptors, decoding, DWARF maps, live reads/writes, preserved "
         "kernel state");
    return 0;
}
