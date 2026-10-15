/* Build with arch.c/registers.c and an ordinary C compiler. An optional argv[1]
 * names an i386 executable for the x86-64 live ABI-mismatch regression. */
#define _GNU_SOURCE 1
#include "loongarch_step.h"
#include "riscv_step.h"
#include "rpc.h"
#include "xrt_arch.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
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
        const struct xrt_abi_id abi = xrt_arch_abi(arch);
        struct xrt_registers regs;
        CHECK(xrt_registers_decode(&abi, bytes + 1, arch->kernel_gpr_bytes, &regs) == XRT_OK);
        CHECK(regs.abi.machine == arch->machine);
        if (regs.abi.machine == XRT_X86_64) {
            CHECK(regs.values.x86.rip == word(16) && regs.values.x86.rsp == word(19));
            CHECK(regs.values.x86.rax == word(10) && regs.values.x86.eflags == word(18));
            CHECK(regs.values.x86.r15 == word(0) && regs.values.x86.r8 == word(9));
            /* The thread pointers are user_regs_struct words 21 and 22: shown, never written. */
            CHECK(arch->register_count == 20 && regs.values.x86.fs_base == word(21) && regs.values.x86.gs_base == word(22));
            uint64_t base = 0;
            CHECK(xrt_registers_value(&regs, "fs_base", 7, &base) == XRT_OK && base == word(21));
            CHECK(xrt_registers_value(&regs, "gs_base", 7, &base) == XRT_OK && base == word(22));
            for (uint16_t id = 0; id < arch->register_count; ++id)
                CHECK(xrt_register_admit(xrt_arch_register_id(arch, id), 1) == (id >= 18 ? XRT_REGISTER_NOT_WRITABLE : XRT_OK));
            unsigned char raw[216] = {0};
            CHECK(xrt_registers_poke(arch, raw, sizeof raw, "fs_base", 7, 0x1000) == XRT_REGISTER_NOT_WRITABLE);
            CHECK(xrt_registers_poke(arch, raw, sizeof raw, "gs_base", 7, 0x1000) == XRT_REGISTER_NOT_WRITABLE);
        } else {
            CHECK(regs.values.arm.x0 == word(0) && regs.values.arm.x30 == word(30));
            CHECK(regs.values.arm.sp == word(31) && regs.values.arm.pc == word(32));
            CHECK(regs.values.arm.pstate == word(33));
        }
        uint64_t values[XRT_DWARF_REGISTER_COUNT];
        uint8_t present[XRT_DWARF_REGISTER_COUNT];
        memset(values, 0xa5, sizeof(values));
        memset(present, 0xa5, sizeof(present));
        CHECK(xrt_registers_dwarf(&regs, values, present, arch->dwarf_count - 1) ==
              XRT_BUFFER_TOO_SMALL);
        for (size_t i = 0; i < XRT_DWARF_REGISTER_COUNT; ++i) {
            CHECK(values[i] == UINT64_C(0xa5a5a5a5a5a5a5a5));
            CHECK(present[i] == 0xa5);
        }
        CHECK(xrt_registers_dwarf(&regs, values, present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
        if (regs.abi.machine == XRT_X86_64) {
            const unsigned indices[] = {10, 12, 11, 5, 13, 14, 4, 19, 9, 8, 7, 6, 3, 2, 1, 0, 16};
            for (size_t i = 0; i < 17; ++i) {
                CHECK(values[i] == word(indices[i]));
                CHECK(present[i] == 1);
            }
            for (size_t i = 17; i < XRT_DWARF_REGISTER_COUNT; ++i) {
                CHECK(values[i] == UINT64_C(0xa5a5a5a5a5a5a5a5));
                CHECK(present[i] == 0);
            }
            uint64_t scanned = 0;
            CHECK(xrt_registers_value_dwarf(&regs, 16, &scanned) == XRT_OK);
            CHECK(scanned == regs.values.x86.rip);
            scanned = 7;
            CHECK(xrt_registers_value_dwarf(&regs, 300, &scanned) == XRT_UNKNOWN_REGISTER);
            CHECK(scanned == 7);
        } else {
            for (size_t i = 0; i < 33; ++i) {
                CHECK(values[i] == word(i));
                CHECK(present[i] == 1);
            }
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
            CHECK(xrt_registers_decode(&abi, bytes + 1, size, &regs) ==
                  XRT_UNEXPECTED_REGISTER_SIZE);
            CHECK(memcmp(&regs, &saved, sizeof(regs)) == 0);
        }
    }
    struct xrt_registers regs;
    CHECK(xrt_arch_get(0) == NULL);
    CHECK(xrt_registers_decode(NULL, bytes, 0, &regs) == XRT_INVALID_ARGUMENT);
    const struct xrt_abi_id missing = {.machine = 0,
                                       .elf_class = XRT_ELF_CLASS_64,
                                       .little_endian = 1,
                                       .address_bits = 64,
                                       .linux_abi = XRT_LINUX_ABI_NATIVE,
                                       .isa_mode = XRT_ISA_MODE_ORDINARY};
    CHECK(xrt_registers_decode(&missing, bytes, 0, &regs) == XRT_UNSUPPORTED_ARCHITECTURE);
    const struct xrt_abi_id x86_abi = xrt_arch_abi(xrt_arch_get(XRT_X86_64));
    CHECK(xrt_registers_decode(&x86_abi, NULL, 216, &regs) == XRT_INVALID_ARGUMENT);
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
    const struct xrt_abi_id m68k_abi = xrt_arch_abi(xrt_arch_get(XRT_M68K));
    CHECK(xrt_registers_decode(&m68k_abi, m68k + 1, 80, &regs) == XRT_OK);
    CHECK(regs.values.m68k.d0 == UINT32_C(0x1020304e));
    CHECK(regs.values.m68k.d1 == UINT32_C(0x10203040));
    CHECK(regs.values.m68k.usp == UINT32_C(0x1020304f));
    CHECK(regs.values.m68k.pc == UINT32_C(0x10203052));
    CHECK(regs.values.m68k.sr == UINT32_C(0x3051));
    uint64_t dwarf[XRT_DWARF_REGISTER_COUNT];
    uint8_t dwarf_present[XRT_DWARF_REGISTER_COUNT];
    memset(dwarf, 0xa5, sizeof(dwarf));
    memset(dwarf_present, 0xa5, sizeof(dwarf_present));
    CHECK(xrt_registers_dwarf(&regs, dwarf, dwarf_present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    CHECK(dwarf[0] == regs.values.m68k.d0 && dwarf_present[0] == 1);
    CHECK(dwarf[15] == regs.values.m68k.usp && dwarf_present[15] == 1);
    CHECK(dwarf[24] == regs.values.m68k.pc && dwarf_present[24] == 1);
    CHECK(dwarf[16] == UINT64_C(0xa5a5a5a5a5a5a5a5) && dwarf_present[16] == 0);
    CHECK(xrt_arch_dwarf_name(XRT_M68K, 16) == NULL);
    CHECK(xrt_arch_breakpoint_pc(XRT_M68K, 0x1002, &pc) && pc == 0x1000);
    CHECK(xrt_arch_breakpoint_valid(XRT_M68K, 0x1000, 2));
    CHECK(!xrt_arch_breakpoint_valid(XRT_M68K, 0x1001, 2));
}

struct fake_bank {
    unsigned char image[XRT_GPR_BYTES_MAX];
    int reads, writes, mode;
};

static enum xrt_status fake_read(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                 unsigned char *raw, size_t size)
{
    struct fake_bank *bank = ctx;
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

static enum xrt_status fake_write(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                  const unsigned char *raw, size_t size)
{
    struct fake_bank *bank = ctx;
    (void)tid;
    if (!arch || !raw || size != arch->kernel_gpr_bytes)
        return XRT_INVALID_ARGUMENT;
    ++bank->writes;
    memcpy(bank->image, raw, size);
    return XRT_OK;
}

static int encoding_same(const struct xrt_probe_encoding *a, const struct xrt_probe_encoding *b)
{
    return a->isa_mode == b->isa_mode && a->width == b->width && a->alignment == b->alignment &&
           memcmp(a->bytes, b->bytes, 4) == 0;
}

static struct xrt_arch copy_row(const struct xrt_arch *arch, uint16_t machine,
                                const struct xrt_register_desc *registers, uint8_t register_count,
                                const struct xrt_probe_choice *probes, uint8_t probe_count,
                                uint8_t control_kind, uint16_t kernel_bytes, uint8_t dwarf_count)
{
    struct xrt_arch row = *arch;
    row.machine = machine;
    row.registers = registers;
    row.register_count = register_count;
    row.probes = probes;
    row.probe_count = probe_count;
    row.control_kind = control_kind;
    row.kernel_gpr_bytes = kernel_bytes;
    row.dwarf_count = dwarf_count;
    return row;
}

static void contract(void)
{
    CHECK(xrt_rpc_classify(XRT_RPC_ALLOCATIONS_START) == XRT_RPC_CLASS_PERF);
    CHECK(xrt_rpc_classify(XRT_RPC_FUNCTION_START) == XRT_RPC_CLASS_PERF);
    CHECK(xrt_rpc_classify(XRT_RPC_CPU_START) == XRT_RPC_CLASS_PERF);
    CHECK(xrt_rpc_classify(XRT_RPC_CONTROL_WRITE) == XRT_RPC_CLASS_MUTATION);
    CHECK(xrt_rpc_classify(XRT_RPC_REGISTER_WRITE) == XRT_RPC_CLASS_MUTATION);
    CHECK(xrt_rpc_classify(XRT_RPC_DESTROY) == XRT_RPC_CLASS_MUTATION);
    CHECK(xrt_rpc_classify(XRT_RPC_HELLO) == XRT_RPC_CLASS_READ);
    CHECK(xrt_rpc_classify(XRT_RPC_CREATE) == XRT_RPC_CLASS_READ);
    CHECK(xrt_rpc_classify(XRT_RPC_FILE_OPEN) == XRT_RPC_CLASS_FILE);
    CHECK(xrt_rpc_classify(0) == XRT_RPC_CLASS_PROTOCOL);
    CHECK(xrt_rpc_classify(XRT_RPC_SOURCE_OPEN) == XRT_RPC_CLASS_FILE);
    CHECK(xrt_rpc_classify(56) == XRT_RPC_CLASS_PROTOCOL);
    CHECK(XRT_PARTIAL_REGISTER_WRITE == 71 && XRT_AMBIGUOUS_MATCH == 76);

    const struct xrt_arch *x86 = xrt_arch_get(XRT_X86_64);
    CHECK(x86 && xrt_arch_validate(x86) == XRT_OK);
    struct xrt_register_desc high[20];
    CHECK(x86->register_count == sizeof(high) / sizeof(high[0]));
    memcpy(high, x86->registers, sizeof(high));
    high[3].dwarf = 300;
    struct xrt_arch high_row = copy_row(x86, 0xfffe, high, x86->register_count, x86->probes,
                                        x86->probe_count, XRT_CONTROL_SINGLE_PC,
                                        x86->kernel_gpr_bytes, x86->dwarf_count);
    CHECK(xrt_arch_validate(&high_row) == XRT_OK);
    unsigned char image[XRT_GPR_BYTES_MAX];
    memset(image, 0, sizeof(image));
    for (size_t i = 0; i < x86->kernel_gpr_bytes / 8; ++i)
        for (size_t b = 0; b < 8; ++b)
            image[i * 8 + b] = (unsigned char)(word(i) >> (b * 8));
    struct xrt_registers decoded, saved;
    memset(&saved, 0xa5, sizeof(saved));
    memcpy(&decoded, &saved, sizeof(decoded));
    CHECK(xrt_registers_decode_row(&high_row, image, x86->kernel_gpr_bytes, &decoded) == XRT_OK);
    CHECK(decoded.values.x86.rax == word(10));
    struct xrt_register_desc rax = high[3];
    uint64_t out = 7;
    CHECK(xrt_registers_value_desc_row(&high_row, &decoded, &rax, &out) == XRT_OK);
    CHECK(out == word(10));
    CHECK(xrt_registers_availability_row(&high_row, &decoded, &rax) == XRT_AVAIL_PRESENT);
    rax.dwarf = 0;
    out = 7;
    CHECK(xrt_registers_value_desc_row(&high_row, &decoded, &rax, &out) ==
          XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(out == 7);
    memcpy(&decoded, &saved, sizeof(decoded));
    CHECK(xrt_registers_decode_row(&high_row, NULL, x86->kernel_gpr_bytes, &decoded) ==
          XRT_INVALID_ARGUMENT);
    CHECK(memcmp(&decoded, &saved, sizeof(decoded)) == 0);

    const struct xrt_register_desc none_regs[] = {
        {"pc", 0, XRT_DWARF_NONE, 0, 0, 8, XRT_ROLE_PC, XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
        {"sp", 1, XRT_DWARF_NONE, 8, 8, 8, XRT_ROLE_SP, XRT_REG_READ_WRITE, XRT_REG_ALWAYS}};
    const struct xrt_probe_choice none_probe[] = {
        {XRT_ISA_MODE_ORDINARY, 1, 1, 0, {0xcc, 0, 0, 0}, {0, 0, 0, 0}}};
    struct xrt_arch none = copy_row(x86, 0xffff, none_regs, 2, none_probe, 1,
                                    XRT_CONTROL_SINGLE_PC, 16, 1);
    none.trap_size = 1;
    none.trap_alignment = 1;
    CHECK(xrt_arch_validate(&none) == XRT_OK);
    unsigned char pair[16];
    memset(pair, 0, sizeof(pair));
    pair[0] = 0x42;
    CHECK(xrt_registers_decode_row(&none, pair, sizeof(pair), &decoded) == XRT_OK);
    struct xrt_register_desc pc_copy = none_regs[0];
    out = 0;
    CHECK(xrt_registers_value_desc_row(&none, &decoded, &pc_copy, &out) == XRT_OK);
    CHECK(out == 0x42);
    uint64_t pc_out = 9;
    CHECK(xrt_registers_pc(&decoded, &pc_out) == XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(pc_out == 9);

    const struct xrt_register_desc next_regs[] = {
        {"pc", 0, XRT_DWARF_NONE, 0, 0, 8, XRT_ROLE_PC, XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
        {"npc", 1, XRT_DWARF_NONE, 8, 8, 8, XRT_ROLE_NEXT_PC, XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
        {"sp", 2, XRT_DWARF_NONE, 16, 16, 8, XRT_ROLE_SP, XRT_REG_READ_WRITE, XRT_REG_ALWAYS}};
    struct xrt_arch next = copy_row(x86, 0xfffd, next_regs, 3, none_probe, 1, XRT_CONTROL_PC_NEXT,
                                    24, 1);
    next.trap_size = 1;
    next.trap_alignment = 1;
    CHECK(xrt_arch_validate(&next) == XRT_OK);
    CHECK(xrt_control_accept(&next, 0) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_control_accept(&next, 3) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_control_accept(&next, 1) == XRT_OK);
    CHECK(xrt_control_accept(&next, 2) == XRT_OK);
    CHECK(xrt_control_accept(x86, 2) == XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_control_accept(x86, 1) == XRT_OK);
    unsigned char raw[24];
    memset(raw, 0x11, sizeof(raw));
    struct xrt_control_request both = {.count = 2, .value = {0x111, 0x222}};
    CHECK(xrt_control_poke(&next, raw, sizeof(raw), &both) == XRT_OK);
    CHECK(raw[0] == 0x11 && raw[1] == 0x01 && raw[8] == 0x22 && raw[9] == 0x02);
    unsigned char actual[24];
    memcpy(actual, raw, sizeof(actual));
    CHECK(xrt_mutation_confirm_image(raw, actual, sizeof(raw), NULL) == XRT_OK);
    actual[23] ^= 1;
    CHECK(xrt_mutation_confirm_image(raw, actual, sizeof(raw), NULL) == XRT_PARTIAL_REGISTER_WRITE);
    struct xrt_arch queue = next;
    queue.machine = 0xfffc;
    queue.control_kind = XRT_CONTROL_QUEUE;
    queue.register_count = 2;
    queue.registers = none_regs;
    queue.kernel_gpr_bytes = 16;
    CHECK(xrt_arch_validate(&queue) == XRT_OK);
    CHECK(xrt_control_accept(&queue, 1) == XRT_UNSUPPORTED_CONTROL);

    const struct xrt_probe_choice ambiguous_choices[2] = {
        {XRT_ISA_MODE_ORDINARY, 1, 1, 0, {0xcc, 0, 0, 0}, {0, 0, 0, 0}},
        {XRT_ISA_MODE_ORDINARY, 1, 1, 0, {0x90, 0, 0, 0}, {0, 0, 0, 0}}};
    struct xrt_arch ambiguous =
        copy_row(&none, 0xfffb, none_regs, 2, ambiguous_choices, 2, XRT_CONTROL_SINGLE_PC, 16, 1);
    CHECK(xrt_arch_validate(&ambiguous) == XRT_OK);
    const uint8_t sample[4] = {1, 2, 3, 4};
    struct xrt_probe_request request = {.address = 0x1000,
                                        .isa_mode = XRT_ISA_MODE_ORDINARY,
                                        .bytes = sample,
                                        .size = sizeof(sample)};
    struct xrt_probe_encoding encoding, keep;
    memset(&encoding, 0x5a, sizeof(encoding));
    keep = encoding;
    CHECK(xrt_arch_probe_prepare(&ambiguous, &request, &encoding) == XRT_AMBIGUOUS_MATCH);
    CHECK(encoding_same(&encoding, &keep));
    const struct xrt_probe_choice swapped[2] = {ambiguous_choices[1], ambiguous_choices[0]};
    ambiguous.probes = swapped;
    CHECK(xrt_arch_probe_prepare(&ambiguous, &request, &encoding) == XRT_AMBIGUOUS_MATCH);
    CHECK(encoding_same(&encoding, &keep));
    const struct xrt_probe_choice short_choices[2] = {
        {XRT_ISA_MODE_ORDINARY, 4, 4, 2, {0x11, 0x22, 0x33, 0x44}, {0xaa, 0xbb, 0, 0}},
        {XRT_ISA_MODE_ORDINARY, 1, 1, 0, {0xcc, 0, 0, 0}, {0, 0, 0, 0}}};
    struct xrt_arch shorts =
        copy_row(&none, 0xfffa, none_regs, 2, short_choices, 2, XRT_CONTROL_SINGLE_PC, 16, 1);
    CHECK(xrt_arch_validate(&shorts) == XRT_OK);
    const uint8_t prefix[1] = {0xaa};
    request.bytes = prefix;
    request.size = 1;
    CHECK(xrt_arch_probe_prepare(&shorts, &request, &encoding) == XRT_BUFFER_TOO_SMALL);
    CHECK(encoding_same(&encoding, &keep));
    const uint8_t missed[4] = {0, 0, 0, 0};
    request.bytes = missed;
    request.size = 4;
    CHECK(xrt_arch_probe_prepare(&shorts, &request, &encoding) == XRT_OK);
    CHECK(encoding.width == 1 && encoding.bytes[0] == 0xcc);
    request.isa_mode = XRT_ISA_MODE_NONE;
    memset(&encoding, 0x5a, sizeof(encoding));
    CHECK(xrt_arch_probe_prepare(&shorts, &request, &encoding) == XRT_INVALID_ARGUMENT);
    CHECK(encoding.bytes[0] == 0x5a);

    const struct xrt_abi_id abi = xrt_arch_abi(x86);
    CHECK(xrt_registers_decode(&abi, image, x86->kernel_gpr_bytes, &decoded) == XRT_OK);
    decoded.values.x86.rax = UINT64_C(0x1111111111111111);
    CHECK(xrt_registers_mark_absent(&decoded, 3) == XRT_OK);
    CHECK(xrt_registers_mark_absent(&decoded, 3) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_registers_mark_unknown(&decoded, 3) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_registers_mark_absent(&decoded, 100) == XRT_INVALID_ARGUMENT);
    struct xrt_register_desc product_rax = x86->registers[3];
    out = 7;
    CHECK(xrt_registers_value_desc(&decoded, &product_rax, &out) == XRT_REGISTER_UNAVAILABLE);
    CHECK(out == 7);
    CHECK(xrt_registers_availability(&decoded, &product_rax) == XRT_AVAIL_ABSENT);
    CHECK(xrt_registers_mark_unknown(&decoded, 4) == XRT_OK);
    decoded.absent_id[decoded.absent_count++] = 4;
    CHECK(xrt_registers_validate(x86, &decoded) == XRT_INVALID_ARGUMENT);
    decoded.absent_count--;
    decoded.unknown_count = 2;
    decoded.unknown_id[1] = 4;
    CHECK(xrt_registers_validate(x86, &decoded) == XRT_INVALID_ARGUMENT);

    const struct xrt_arch *native = xrt_arch_native();
    CHECK(native);
    const char *scratch = native->machine == XRT_X86_64      ? "r10"
                          : native->machine == XRT_AARCH64    ? "x9"
                          : native->machine == XRT_LOONGARCH  ? "r12"
                          : native->machine == XRT_PPC64      ? "r12"
                          : native->machine == XRT_RISCV      ? "a2"
                                                              : "d2";
    const struct xrt_register_desc *field =
        xrt_arch_register(native->machine, scratch, strlen(scratch));
    CHECK(field && field->kernel_offset + field->width < native->kernel_gpr_bytes);
    struct fake_bank bank = {0};
    struct xrt_reg_io io = {.read = fake_read, .write = fake_write, .ctx = &bank};
    struct xrt_mutation_result result = {.issued = 9, .confirmed = 9};
    CHECK(xrt_register_write_result(1, "no_such", 7, 1, &io, &result) == XRT_UNKNOWN_REGISTER);
    CHECK(!result.issued && !result.confirmed && !bank.reads && !bank.writes);
    CHECK(xrt_register_write_result(1, scratch, strlen(scratch), UINT64_C(0xabcdef), &io,
                                    &result) == XRT_OK);
    CHECK(result.issued && result.confirmed && bank.writes == 1 && bank.reads == 2);
    bank.mode = 1;
    bank.reads = bank.writes = 0;
    CHECK(xrt_register_write_result(1, scratch, strlen(scratch), UINT64_C(0xabcdee), &io,
                                    &result) == XRT_PARTIAL_REGISTER_WRITE);
    CHECK(result.issued && !result.confirmed && bank.writes == 1);
    bank.mode = 2;
    bank.reads = bank.writes = 0;
    CHECK(xrt_register_write_result(1, scratch, strlen(scratch), 1, &io, &result) ==
          XRT_PTRACE_FAILED);
    CHECK(result.issued && !result.confirmed && bank.writes == 1);
    bank.mode = 0;
    bank.reads = bank.writes = 0;
    struct xrt_control_request refused = {.count = 2, .value = {1, 2}};
    CHECK(xrt_control_write(1, &refused, &io, &result) == XRT_UNSUPPORTED_CONTROL);
    CHECK(!result.issued && !result.confirmed && !bank.writes && !bank.reads);
    bank.mode = 1;
    struct xrt_control_request one = {.count = 1, .value = {0x1000}};
    CHECK(xrt_control_write(1, &one, &io, &result) == XRT_PARTIAL_REGISTER_WRITE);
    CHECK(result.issued && !result.confirmed && bank.writes == 1 && bank.reads == 2);
}

static void riscv_expect(uint64_t pc, const uint8_t *bytes, size_t size, const uint64_t gpr[32],
                         uint32_t known, enum xrt_status status, uint8_t emulate, uint8_t count,
                         uint64_t first, uint64_t second)
{
    struct xrt_riscv_plan plan;
    CHECK(xrt_riscv_plan(pc, bytes, size, gpr, known, &plan) == status);
    if (status != XRT_OK)
        return;
    CHECK(plan.emulate == emulate && plan.count == count);
    if (count > 0)
        CHECK(plan.pc[0] == first);
    if (count > 1)
        CHECK(plan.pc[1] == second);
}
static void put32(uint8_t *out, uint32_t word)
{
    out[0] = (uint8_t)word;
    out[1] = (uint8_t)(word >> 8);
    out[2] = (uint8_t)(word >> 16);
    out[3] = (uint8_t)(word >> 24);
}
/* Encodings are the bytes llvm-mc emitted for RV64. Offsets are byte displacements. */
static void riscv_plan_tests(void)
{
    uint64_t gpr[32];
    memset(gpr, 0, sizeof(gpr));
    const uint8_t nop[] = {0x13, 0x00, 0x00, 0x00};
    const uint8_t cnop[] = {0x01, 0x00};
    CHECK(xrt_riscv_plan(0x1000, nop, 4, gpr, 0, NULL) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_riscv_plan(0x1000, NULL, 4, gpr, 0, &(struct xrt_riscv_plan){0}) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_riscv_plan(0x1000, nop, 4, NULL, 0, &(struct xrt_riscv_plan){0}) == XRT_INVALID_ARGUMENT);
    riscv_expect(0x1001, nop, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, nop, 0, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, nop, 2, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, nop, 3, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, nop, 4, gpr, 0, XRT_OK, 0, 1, 0x1004, 0);
    riscv_expect(0x1000, cnop, 2, gpr, 0, XRT_OK, 0, 1, 0x1002, 0);
    riscv_expect(UINT64_MAX - 1, nop, 4, gpr, 0, XRT_INVALID_ADDRESS, 0, 0, 0, 0);
    riscv_expect(UINT64_MAX - 1, cnop, 2, gpr, 0, XRT_INVALID_ADDRESS, 0, 0, 0, 0);
    /* c.addiw, the RV32 c.jal encoding, is not a jump on RV64. */
    const uint8_t addiw[] = {0x01, 0x25};
    riscv_expect(0x1000, addiw, 2, gpr, 0, XRT_OK, 0, 1, 0x1002, 0);
    const uint8_t overlong[] = {0x3f, 0x00, 0x00, 0x00};
    riscv_expect(0x1000, overlong, 2, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, overlong, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t reserved[] = {0x63, 0x20, 0x00, 0x00};
    riscv_expect(0x1000, reserved, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t ebreak[] = {0x73, 0x00, 0x10, 0x00};
    const uint8_t cebreak[] = {0x02, 0x90};
    const uint8_t cjr0[] = {0x02, 0x80};
    const uint8_t mret[] = {0x73, 0x00, 0x20, 0x30};
    const uint8_t sret[] = {0x73, 0x00, 0x20, 0x10};
    const uint8_t uret[] = {0x73, 0x00, 0x20, 0x00};
    riscv_expect(0x1000, ebreak, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, cebreak, 2, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, cjr0, 2, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, mret, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, sret, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, uret, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t wfi[] = {0x73, 0x00, 0x50, 0x10};
    riscv_expect(0x1000, wfi, 4, gpr, 0, XRT_OK, 0, 1, 0x1004, 0);
    const uint8_t ecall[] = {0x73, 0x00, 0x00, 0x00};
    riscv_expect(0x1000, ecall, 4, gpr, 0, XRT_OK, 0, 1, 0x1004, 0);
    gpr[17] = 63;
    riscv_expect(0x1000, ecall, 4, gpr, 1u << 17, XRT_OK, 0, 1, 0x1004, 0);
    gpr[17] = 139;
    riscv_expect(0x1000, ecall, 4, gpr, 1u << 17, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    gpr[17] = 139;
    riscv_expect(0x1000, ecall, 4, gpr, 0, XRT_OK, 0, 1, 0x1004, 0);
    const uint8_t jself[] = {0x6f, 0x00, 0x00, 0x00};
    const uint8_t cjself[] = {0x01, 0xa0};
    const uint8_t callself[] = {0xef, 0x00, 0x00, 0x00};
    riscv_expect(0x1000, jself, 4, gpr, 0, XRT_OK, 1, 0, 0, 0);
    riscv_expect(0x1000, cjself, 2, gpr, 0, XRT_OK, 1, 0, 0, 0);
    riscv_expect(0x1000, callself, 4, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t jal8[] = {0x6f, 0x00, 0x80, 0x00};
    const uint8_t jalra8[] = {0xef, 0x00, 0x80, 0x00};
    const uint8_t cj8[] = {0x21, 0xa0};
    riscv_expect(0x1000, jal8, 4, gpr, 0, XRT_OK, 0, 1, 0x1008, 0);
    riscv_expect(0x1000, jalra8, 4, gpr, 0, XRT_OK, 0, 1, 0x1008, 0);
    riscv_expect(0x1000, cj8, 2, gpr, 0, XRT_OK, 0, 1, 0x1008, 0);
    const uint8_t jalback[] = {0x6f, 0xf0, 0x9f, 0xff};
    const uint8_t cjback[] = {0xf5, 0xbf};
    riscv_expect(0x1000, jalback, 4, gpr, 0, XRT_OK, 0, 1, 0xff8, 0);
    riscv_expect(0x1000, cjback, 2, gpr, 0, XRT_OK, 0, 1, 0xffc, 0);
    const uint8_t beq8[] = {0x63, 0x04, 0x00, 0x00};
    const uint8_t beq0[] = {0x63, 0x00, 0x00, 0x00};
    const uint8_t beqback[] = {0xe3, 0x0c, 0x00, 0xfe};
    const uint8_t blt256[] = {0x63, 0xc0, 0x62, 0x10};
    const uint8_t bgeuback[] = {0x63, 0x70, 0xb5, 0x80};
    const uint8_t cbeq[] = {0x01, 0xc5};
    const uint8_t cbnez[] = {0x6d, 0xfd};
    const uint8_t cbeq32[] = {0x05, 0xc0};
    const uint8_t cbnez256[] = {0x81, 0xf0};
    riscv_expect(0x1000, beq8, 4, gpr, 0, XRT_OK, 0, 2, 0x1008, 0x1004);
    riscv_expect(0x1000, beq0, 4, gpr, 0, XRT_OK, 0, 1, 0x1004, 0);
    riscv_expect(0x1000, beqback, 4, gpr, 0, XRT_OK, 0, 2, 0xff8, 0x1004);
    riscv_expect(0x1000, blt256, 4, gpr, 0, XRT_OK, 0, 2, 0x1100, 0x1004);
    riscv_expect(0x2000, bgeuback, 4, gpr, 0, XRT_OK, 0, 2, 0x1000, 0x2004);
    riscv_expect(0x1000, cbeq, 2, gpr, 0, XRT_OK, 0, 2, 0x1008, 0x1002);
    riscv_expect(0x1000, cbnez, 2, gpr, 0, XRT_OK, 0, 2, 0xffa, 0x1002);
    riscv_expect(0x1000, cbeq32, 2, gpr, 0, XRT_OK, 0, 2, 0x1020, 0x1002);
    riscv_expect(0x1100, cbnez256, 2, gpr, 0, XRT_OK, 0, 2, 0x1000, 0x1102);
    const uint8_t jalr_ra[] = {0x67, 0x80, 0x00, 0x00};
    const uint8_t jalr_x0[] = {0x67, 0x00, 0x00, 0x00};
    const uint8_t jalr_imm[] = {0x67, 0x00, 0x00, 0x01};
    const uint8_t jalr_a5[] = {0xe7, 0x80, 0x07, 0x01};
    const uint8_t cjr[] = {0x82, 0x80};
    const uint8_t cjalr[] = {0x82, 0x90};
    riscv_expect(0x1000, jalr_ra, 4, gpr, 0, XRT_REGISTER_UNAVAILABLE, 0, 0, 0, 0);
    gpr[0] = 0x9999;
    riscv_expect(0x1000, jalr_x0, 4, gpr, 1u, XRT_OK, 0, 1, 0, 0);
    riscv_expect(0x1000, jalr_imm, 4, gpr, 1u, XRT_OK, 0, 1, 16, 0);
    gpr[1] = 0x4321;
    riscv_expect(0x1000, jalr_ra, 4, gpr, 1u << 1, XRT_OK, 0, 1, 0x4320, 0);
    riscv_expect(0x1000, cjr, 2, gpr, 1u << 1, XRT_OK, 0, 1, 0x4320, 0);
    riscv_expect(0x1000, cjalr, 2, gpr, 1u << 1, XRT_OK, 0, 1, 0x4320, 0);
    gpr[1] = 0x1000;
    riscv_expect(0x1000, jalr_ra, 4, gpr, 1u << 1, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    riscv_expect(0x1000, cjalr, 2, gpr, 1u << 1, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    gpr[15] = 0x2001;
    riscv_expect(0x1000, jalr_a5, 4, gpr, 1u << 15, XRT_OK, 0, 1, 0x2010, 0);
    riscv_expect(0x1000, jalr_a5, 4, gpr, 0, XRT_REGISTER_UNAVAILABLE, 0, 0, 0, 0);
    /* lr.w, sc.w, no branch: stop on the instruction after sc. */
    const uint8_t pair[] = {0xaf, 0x22, 0x05, 0x10, 0x2f, 0x23, 0x55, 0x18};
    riscv_expect(0x2000, pair, sizeof pair, gpr, 0, XRT_OK, 0, 1, 0x2008, 0);
    /* lr.w, addi, sc.w, bne -12 back to lr. The exit is the fall-through. */
    const uint8_t retry[] = {0xaf, 0x22, 0x05, 0x10, 0x13, 0x00, 0x00, 0x00,
                             0x2f, 0x23, 0x55, 0x18, 0xe3, 0x1a, 0x03, 0xfe};
    riscv_expect(0x2000, retry, sizeof retry, gpr, 0, XRT_OK, 0, 1, 0x2010, 0);
    const uint8_t retry_d[] = {0xaf, 0x32, 0x05, 0x10, 0x13, 0x00, 0x00, 0x00,
                               0x2f, 0x33, 0x55, 0x18, 0xe3, 0x1a, 0x03, 0xfe};
    riscv_expect(0x3000, retry_d, sizeof retry_d, gpr, 0, XRT_OK, 0, 1, 0x3010, 0);
    /* lr.w, c.nop, c.nop, sc.w, c.bnez back to lr. */
    const uint8_t mixed[] = {0xaf, 0x22, 0x05, 0x10, 0x01, 0x00, 0x01, 0x00,
                             0x2f, 0x23, 0x55, 0x18, 0x75, 0xf9};
    riscv_expect(0x2000, mixed, sizeof mixed, gpr, 0, XRT_OK, 0, 1, 0x200e, 0);
    /* lr.w, sc.w, c.bnez back to lr, then a 48-bit parcel: bytes past the
     * instruction after sc are not decoded. */
    const uint8_t tail[] = {0xaf, 0x22, 0x05, 0x10, 0x2f, 0x23, 0x55, 0x18, 0x65, 0xfc, 0x1f, 0x00};
    riscv_expect(0x2000, tail, sizeof tail, gpr, 0, XRT_OK, 0, 1, 0x200a, 0);
    const uint8_t spin[] = {0xaf, 0x22, 0x05, 0x10, 0xaf, 0x22, 0x55, 0x18, 0xe5, 0xbf};
    riscv_expect(0x2000, spin, sizeof spin, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t lone[] = {0xaf, 0x22, 0x05, 0x10, 0x13, 0x00, 0x00, 0x00};
    riscv_expect(0x2000, lone, sizeof lone, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t nested[] = {0xaf, 0x22, 0x05, 0x10, 0xaf, 0x22, 0x05, 0x10, 0x2f, 0x23, 0x55, 0x18};
    riscv_expect(0x2000, nested, sizeof nested, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t mismatch[] = {0xaf, 0x22, 0x05, 0x10, 0x2f, 0x33, 0x55, 0x18};
    riscv_expect(0x2000, mismatch, sizeof mismatch, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t indirect[] = {0xaf, 0x22, 0x05, 0x10, 0x67, 0x80, 0x00, 0x00, 0x2f, 0x23, 0x55, 0x18};
    gpr[1] = 0x8000;
    riscv_expect(0x2000, indirect, sizeof indirect, gpr, 1u << 1, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t cjr_in[] = {0xaf, 0x22, 0x05, 0x10, 0x82, 0x80, 0x2f, 0x23, 0x55, 0x18};
    riscv_expect(0x2000, cjr_in, sizeof cjr_in, gpr, 1u << 1, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t call_in[] = {0xaf, 0x22, 0x05, 0x10, 0xef, 0x00, 0x80, 0x00, 0x2f, 0x23, 0x55, 0x18};
    riscv_expect(0x2000, call_in, sizeof call_in, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    const uint8_t three[] = {0xaf, 0x22, 0x05, 0x10, 0x63, 0x00, 0x00, 0x02,
                             0x2f, 0x23, 0x55, 0x18, 0x63, 0x10, 0x00, 0x02};
    riscv_expect(0x2000, three, sizeof three, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    uint8_t long_window[4 + 16 * 4];
    put32(long_window, 0x100522afu);
    for (int i = 0; i < 16; ++i)
        put32(long_window + 4 + i * 4, 0x00000013u);
    riscv_expect(0x2000, long_window, sizeof long_window, gpr, 0, XRT_UNSUPPORTED_CONTROL, 0, 0, 0, 0);
    uint8_t fitted[4 + 15 * 4 + 4];
    put32(fitted, 0x100522afu);
    for (int i = 0; i < 15; ++i)
        put32(fitted + 4 + i * 4, 0x00000013u);
    put32(fitted + 4 + 15 * 4, 0x1855232fu);
    riscv_expect(0x2000, fitted, sizeof fitted, gpr, 0, XRT_OK, 0, 1, 0x2044, 0);
}

static void riscv_replay(void)
{
    const struct xrt_arch *arch = xrt_arch_get(XRT_RISCV);
    struct xrt_registers regs;
    struct xrt_step_resources step;
    struct xrt_probe_request request;
    struct xrt_probe_encoding encoding;
    unsigned char image[257];
    unsigned char saved_bytes[sizeof(regs)];
    uint64_t values[XRT_DWARF_REGISTER_COUNT];
    uint8_t present[XRT_DWARF_REGISTER_COUNT];
    uint64_t pc = 99;
    uint64_t scanned = 7;
    CHECK(arch && xrt_arch_validate(arch) == XRT_OK);
    CHECK(arch->kernel_gpr_bytes == 256 && arch->register_count == 32 && arch->dwarf_count == 32);
    CHECK(arch->hardware_step == 0 && arch->breakpoint_adjust == 0 && arch->caller_adjust == 2);
    CHECK(arch->trap_size == 2 && arch->trap[0] == 0x02 && arch->trap[1] == 0x90);
    CHECK(xrt_arch_resolve(xrt_arch_abi(arch)) == arch);
    {
        struct xrt_abi_id foreign = xrt_arch_abi(arch);
        foreign.little_endian = 0;
        CHECK(xrt_arch_resolve(foreign) == NULL);
    }
    CHECK(xrt_arch_step_resources(arch, XRT_ISA_MODE_ORDINARY, &step) == XRT_OK);
    CHECK(step.hardware_step == 0 && step.software_probes == 2);
    memset(&encoding, 0x5a, sizeof(encoding));
    request = (struct xrt_probe_request){.address = 0x1000,
                                         .isa_mode = XRT_ISA_MODE_ORDINARY,
                                         .bytes = arch->trap,
                                         .size = 2};
    CHECK(xrt_arch_probe_prepare(arch, &request, &encoding) == XRT_OK);
    CHECK(encoding.width == 2 && encoding.bytes[0] == 0x02 && encoding.bytes[1] == 0x90);
    CHECK(xrt_arch_breakpoint_pc(XRT_RISCV, 0x1000, &pc) && pc == 0x1000);
    CHECK(xrt_arch_caller_pc(XRT_RISCV, 0x1000, &pc) && pc == 0xffe);
    CHECK(!xrt_arch_caller_pc(XRT_RISCV, 1, &pc) && pc == 0xffe);
    CHECK(xrt_arch_breakpoint_valid(XRT_RISCV, 0x1000, 2));
    CHECK(!xrt_arch_breakpoint_valid(XRT_RISCV, 0x1001, 2));
    CHECK(!xrt_arch_breakpoint_valid(XRT_RISCV, 0x1000, 4));
    memset(image, 0, sizeof(image));
    for (size_t i = 0; i < 32; ++i)
        for (size_t b = 0; b < 8; ++b)
            image[1 + i * 8 + b] = (unsigned char)(word(i) >> (b * 8));
    memset(&regs, 0xa5, sizeof(regs));
    {
        const struct xrt_abi_id abi = xrt_arch_abi(arch);
        memcpy(saved_bytes, &regs, sizeof(regs));
        CHECK(xrt_registers_decode(&abi, image + 1, 255, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(memcmp(&regs, saved_bytes, sizeof(regs)) == 0);
        CHECK(xrt_registers_decode(&abi, image + 1, 257, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(xrt_registers_decode(&abi, NULL, 256, &regs) == XRT_INVALID_ARGUMENT);
        CHECK(xrt_registers_decode(&abi, image + 1, 256, &regs) == XRT_OK);
    }
    CHECK(regs.values.riscv.pc == word(0) && regs.values.riscv.ra == word(1));
    CHECK(regs.values.riscv.sp == word(2) && regs.values.riscv.a0 == word(10));
    CHECK(regs.values.riscv.a2 == word(12) && regs.values.riscv.t6 == word(31));
    memset(values, 0xa5, sizeof(values));
    memset(present, 0xa5, sizeof(present));
    CHECK(xrt_registers_dwarf(&regs, values, present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    CHECK(present[0] == 0 && values[0] == UINT64_C(0xa5a5a5a5a5a5a5a5));
    for (size_t i = 1; i < 32; ++i)
        CHECK(values[i] == word(i) && present[i] == 1);
    CHECK(present[32] == 0 && values[32] == UINT64_C(0xa5a5a5a5a5a5a5a5));
    CHECK(xrt_registers_value_dwarf(&regs, 0, &scanned) == XRT_UNKNOWN_REGISTER && scanned == 7);
    CHECK(xrt_arch_dwarf_name(XRT_RISCV, 0) == NULL);
    CHECK(strcmp(xrt_arch_dwarf_name(XRT_RISCV, 1), "ra") == 0);
    CHECK(strcmp(xrt_arch_dwarf_name(XRT_RISCV, 2), "sp") == 0);
    CHECK(strcmp(xrt_arch_dwarf_name(XRT_RISCV, 31), "t6") == 0);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == word(0));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_SP, &pc) == XRT_OK && pc == word(2));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_RA, &pc) == XRT_OK && pc == word(1));
    CHECK(xrt_arch_register(XRT_RISCV, "x0", 2) == NULL);
    CHECK(arch->registers[0].access == XRT_REG_READ_WRITE && strcmp(arch->registers[0].name, "pc") == 0);
    {
        unsigned char raw[256];
        memset(raw, 0, sizeof(raw));
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "x0", 2, 1) == XRT_UNKNOWN_REGISTER);
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "a2", 2, 1) == XRT_OK);
    }
    riscv_plan_tests();
}

static void loongarch_replay(void)
{
    const struct xrt_arch *arch = xrt_arch_get(XRT_LOONGARCH);
    struct xrt_registers regs;
    struct xrt_step_resources step;
    struct xrt_probe_request request;
    struct xrt_probe_encoding encoding;
    unsigned char image[361];
    unsigned char saved_bytes[sizeof(regs)];
    uint64_t values[XRT_DWARF_REGISTER_COUNT];
    uint8_t present[XRT_DWARF_REGISTER_COUNT];
    uint64_t pc = 99;
    uint64_t scanned = 7;
    CHECK(arch && xrt_arch_validate(arch) == XRT_OK);
    CHECK(arch->kernel_gpr_bytes == 360 && arch->register_count == 35 && arch->dwarf_count == 32);
    CHECK(arch->hardware_step == 0 && arch->breakpoint_adjust == 0 && arch->caller_adjust == 4);
    CHECK(arch->trap_size == 4 && arch->trap[0] == 0x00 && arch->trap[1] == 0x00 &&
          arch->trap[2] == 0x2a && arch->trap[3] == 0x00);
    CHECK(xrt_arch_resolve(xrt_arch_abi(arch)) == arch);
    {
        struct xrt_abi_id foreign = xrt_arch_abi(arch);
        foreign.little_endian = 0;
        CHECK(xrt_arch_resolve(foreign) == NULL);
    }
    CHECK(xrt_arch_step_resources(arch, XRT_ISA_MODE_ORDINARY, &step) == XRT_OK);
    CHECK(step.hardware_step == 0 && step.software_probes == 2);
    memset(&encoding, 0x5a, sizeof(encoding));
    request = (struct xrt_probe_request){.address = 0x1000,
                                         .isa_mode = XRT_ISA_MODE_ORDINARY,
                                         .bytes = arch->trap,
                                         .size = 4};
    CHECK(xrt_arch_probe_prepare(arch, &request, &encoding) == XRT_OK);
    CHECK(encoding.width == 4 && encoding.bytes[2] == 0x2a);
    CHECK(xrt_arch_breakpoint_pc(XRT_LOONGARCH, 0x1000, &pc) && pc == 0x1000);
    CHECK(xrt_arch_caller_pc(XRT_LOONGARCH, 0x1000, &pc) && pc == 0xffc);
    CHECK(!xrt_arch_caller_pc(XRT_LOONGARCH, 3, &pc) && pc == 0xffc);
    CHECK(xrt_arch_breakpoint_valid(XRT_LOONGARCH, 0x1000, 4));
    CHECK(!xrt_arch_breakpoint_valid(XRT_LOONGARCH, 0x1002, 4));
    memset(image, 0, sizeof(image));
    for (size_t i = 0; i < 45; ++i)
        for (size_t b = 0; b < 8; ++b)
            image[1 + i * 8 + b] = (unsigned char)(word(i) >> (b * 8));
    memset(&regs, 0xa5, sizeof(regs));
    CHECK(xrt_registers_decode(&((struct xrt_abi_id){0}), image + 1, 320, &regs) ==
          XRT_UNSUPPORTED_ARCHITECTURE);
    CHECK(xrt_registers_decode(NULL, image + 1, 360, &regs) == XRT_INVALID_ARGUMENT);
    {
        const struct xrt_abi_id abi = xrt_arch_abi(arch);
        memcpy(saved_bytes, &regs, sizeof(regs));
        CHECK(xrt_registers_decode(&abi, image + 1, 320, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(memcmp(&regs, saved_bytes, sizeof(regs)) == 0);
        CHECK(xrt_registers_decode(&abi, image + 1, 359, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(xrt_registers_decode(&abi, image + 1, 361, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(xrt_registers_decode(&abi, NULL, 360, &regs) == XRT_INVALID_ARGUMENT);
        CHECK(xrt_registers_decode(&abi, image + 1, 360, &regs) == XRT_OK);
    }
    CHECK(regs.values.loongarch.r0 == word(0) && regs.values.loongarch.r1 == word(1));
    CHECK(regs.values.loongarch.r3 == word(3) && regs.values.loongarch.r12 == word(12));
    CHECK(regs.values.loongarch.r31 == word(31) && regs.values.loongarch.orig_a0 == word(32));
    CHECK(regs.values.loongarch.pc == word(33) && regs.values.loongarch.badv == word(34));
    CHECK(image[1 + 12 * 8] == (unsigned char)(word(12) & 0xff));
    memset(values, 0xa5, sizeof(values));
    memset(present, 0xa5, sizeof(present));
    CHECK(xrt_registers_dwarf(&regs, values, present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    for (size_t i = 0; i < 32; ++i) {
        CHECK(values[i] == word(i) && present[i] == 1);
        CHECK(strcmp(xrt_arch_dwarf_name(XRT_LOONGARCH, (uint16_t)i), arch->registers[i].name) == 0);
    }
    CHECK(present[32] == 0 && values[32] == UINT64_C(0xa5a5a5a5a5a5a5a5));
    CHECK(xrt_registers_value_dwarf(&regs, 32, &scanned) == XRT_UNKNOWN_REGISTER && scanned == 7);
    CHECK(xrt_arch_dwarf_name(XRT_LOONGARCH, 32) == NULL);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == word(33));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_SP, &pc) == XRT_OK && pc == word(3));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_RA, &pc) == XRT_OK && pc == word(1));
    CHECK(arch->registers[0].access == XRT_REG_READ_ONLY && strcmp(arch->registers[0].name, "r0") == 0);
    CHECK(arch->registers[12].access == XRT_REG_READ_WRITE);
    {
        unsigned char raw[360];
        memset(raw, 0, sizeof(raw));
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "r0", 2, 1) == XRT_REGISTER_NOT_WRITABLE);
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "r12", 3, 1) == XRT_OK);
    }
    uint64_t gpr[32];
    struct xrt_loongarch_plan plan;
    memset(gpr, 0, sizeof(gpr));
    gpr[0] = 0x84;
    gpr[1] = 0x4321;
    gpr[4] = 0x1000;
    CHECK(xrt_loongarch_plan(0x1000, 0x00100000u, gpr, 0, NULL, 0, NULL) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_loongarch_plan(0x1000, 0x00100000u, gpr, 0, NULL, 1, &plan) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_loongarch_plan(0x1000, 0x00100000u, gpr, 0, NULL, 17, &plan) == XRT_INVALID_ARGUMENT);
    CHECK(xrt_loongarch_plan(0x1001, 0x00100000u, gpr, 0, NULL, 0, &plan) == XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_loongarch_plan(0x1000, 0x00100000u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.emulate == 0 && plan.count == 1 && plan.pc[0] == 0x1004);
    CHECK(xrt_loongarch_plan(0x1000, 0x002b0064u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x1004);
    CHECK(xrt_loongarch_plan(0x1000, 0x40000481u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.emulate == 0 && plan.count == 2 && plan.pc[0] == 0x41004 && plan.pc[1] == 0x1004);
    CHECK(xrt_loongarch_plan(0x1000, 0x50000400u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.emulate == 0 && plan.count == 1 && plan.pc[0] == 0x1004);
    CHECK(xrt_loongarch_plan(0x1000, 0x50000200u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == UINT64_C(0xfffffffff8001000));
    CHECK(xrt_loongarch_plan(0x1000, 0x5000f800u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x10f8);
    CHECK(xrt_loongarch_plan(0x1000, 0x50000000u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.emulate == 1 && plan.count == 0);
    CHECK(xrt_loongarch_plan(0x1000, 0x54000000u, gpr, 0, NULL, 0, &plan) == XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_loongarch_plan(0x1000, 0x4c000020u, gpr, 1u << 1, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == gpr[1]);
    CHECK(xrt_loongarch_plan(0x1000, 0x4c000000u, gpr, 1u, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0);
    CHECK(xrt_loongarch_plan(0x1000, 0x4c001000u, gpr, 1u, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 16);
    CHECK(xrt_loongarch_plan(0x1000, 0x4c000080u, gpr, 1u << 4, NULL, 0, &plan) ==
          XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_loongarch_plan(0x1000, 0x4c000080u, gpr, 0, NULL, 0, &plan) == XRT_REGISTER_UNAVAILABLE);
    CHECK(xrt_loongarch_plan(0x1000, 0x58000000u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x1004);
    CHECK(xrt_loongarch_plan(0x1000, 0x58000400u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x1004);
    /* Reviewer encodings: bceqz/bcnez are two-successor branches. +0 collapses
     * onto the step PC, so only the fall-through is planted. jiscr stays refused. */
    CHECK(xrt_loongarch_plan(0x1000, 0x48000000u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x1004); /* bceqz $fcc0, +0 */
    CHECK(xrt_loongarch_plan(0x1000, 0x48000800u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 2 && plan.pc[0] == 0x1008 && plan.pc[1] == 0x1004); /* bceqz $fcc0, +8 */
    CHECK(xrt_loongarch_plan(0x1000, 0x48000100u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 1 && plan.pc[0] == 0x1004); /* bcnez $fcc0, +0 */
    CHECK(xrt_loongarch_plan(0x1000, 0x48000900u, gpr, 0, NULL, 0, &plan) == XRT_OK);
    CHECK(plan.count == 2 && plan.pc[0] == 0x1008 && plan.pc[1] == 0x1004); /* bcnez $fcc0, +8 */
    CHECK(xrt_loongarch_plan(0x1000, 0x48000200u, gpr, 0, NULL, 0, &plan) == XRT_UNSUPPORTED_CONTROL);
    CHECK(xrt_loongarch_plan(0x1000, 0x002a0000u, gpr, 0, NULL, 0, &plan) == XRT_UNSUPPORTED_CONTROL);
    {
        const uint32_t forward[] = {0x00100000u, 0x21000000u, 0x43fff59fu};
        CHECK(xrt_loongarch_plan(0x2000, 0x20000000u, gpr, 0, forward, 3, &plan) == XRT_OK);
        CHECK(plan.emulate == 0 && plan.count == 1 && plan.pc[0] == 0x2010);
    }
    {
        uint32_t forward[16];
        for (int i = 0; i < 16; ++i)
            forward[i] = 0x00100000u;
        CHECK(xrt_loongarch_plan(0x2000, 0x20000000u, gpr, 0, forward, 16, &plan) ==
              XRT_UNSUPPORTED_CONTROL);
    }
    {
        const uint32_t forward[] = {0x20000000u, 0x21000000u};
        CHECK(xrt_loongarch_plan(0x2000, 0x20000000u, gpr, 0, forward, 2, &plan) ==
              XRT_UNSUPPORTED_CONTROL);
    }
    {
        const uint32_t forward[] = {0x23000000u};
        CHECK(xrt_loongarch_plan(0x2000, 0x20000000u, gpr, 0, forward, 1, &plan) ==
              XRT_UNSUPPORTED_CONTROL);
    }
    {
        /* addi.w then jirl then sc.w. The jirl would use GPRs from ll time. */
        const uint32_t forward[] = {0x0280058cu, 0x4c000180u, 0x2100008cu};
        gpr[12] = 0x9000;
        CHECK(xrt_loongarch_plan(0x2000, 0x2000008cu, gpr, ~1u, forward, 3, &plan) ==
              XRT_UNSUPPORTED_CONTROL);
    }
    {
        const uint32_t forward[] = {0x54000400u, 0x21000000u};
        CHECK(xrt_loongarch_plan(0x2000, 0x20000000u, gpr, 0, forward, 2, &plan) ==
              XRT_UNSUPPORTED_CONTROL);
    }
}

static void ppc64_replay(void)
{
    const struct xrt_arch *arch = xrt_arch_get(XRT_PPC64);
    struct xrt_registers regs;
    struct xrt_step_resources step;
    struct xrt_probe_request request;
    struct xrt_probe_encoding encoding;
    unsigned char image[385];
    unsigned char saved_bytes[sizeof(regs)];
    uint64_t values[XRT_DWARF_REGISTER_COUNT];
    uint8_t present[XRT_DWARF_REGISTER_COUNT];
    uint64_t pc = 99;
    CHECK(arch && xrt_arch_validate(arch) == XRT_OK);
    CHECK(arch->kernel_gpr_bytes == 384 && arch->register_count == 44 && arch->dwarf_count == 66);
    CHECK(arch->hardware_step == 1 && arch->breakpoint_adjust == 0 && arch->caller_adjust == 4);
    CHECK(arch->trap_size == 4 && arch->trap[0] == 0x08 && arch->trap[1] == 0x00 &&
          arch->trap[2] == 0xe0 && arch->trap[3] == 0x7f);
    CHECK(xrt_arch_resolve(xrt_arch_abi(arch)) == arch);
    {
        struct xrt_abi_id foreign = xrt_arch_abi(arch);
        foreign.little_endian = 0;
        CHECK(xrt_arch_resolve(foreign) == NULL);
    }
    CHECK(xrt_arch_step_resources(arch, XRT_ISA_MODE_ORDINARY, &step) == XRT_OK);
    CHECK(step.hardware_step == 1 && step.software_probes == 0);
    memset(&encoding, 0x5a, sizeof(encoding));
    request = (struct xrt_probe_request){.address = 0x1000,
                                         .isa_mode = XRT_ISA_MODE_ORDINARY,
                                         .bytes = arch->trap,
                                         .size = 4};
    CHECK(xrt_arch_probe_prepare(arch, &request, &encoding) == XRT_OK);
    CHECK(encoding.width == 4 && encoding.bytes[0] == 0x08 && encoding.bytes[3] == 0x7f);
    CHECK(xrt_arch_breakpoint_pc(XRT_PPC64, 0x1000, &pc) && pc == 0x1000);
    CHECK(xrt_arch_caller_pc(XRT_PPC64, 0x1000, &pc) && pc == 0xffc);
    CHECK(!xrt_arch_caller_pc(XRT_PPC64, 3, &pc) && pc == 0xffc);
    CHECK(xrt_arch_breakpoint_valid(XRT_PPC64, 0x1000, 4));
    CHECK(!xrt_arch_breakpoint_valid(XRT_PPC64, 0x1002, 4));
    memset(image, 0, sizeof(image));
    for (size_t i = 0; i < 48; ++i)
        for (size_t b = 0; b < 8; ++b)
            image[1 + i * 8 + b] = (unsigned char)(word(i) >> (b * 8));
    memset(&regs, 0xa5, sizeof(regs));
    {
        const struct xrt_abi_id abi = xrt_arch_abi(arch);
        memcpy(saved_bytes, &regs, sizeof(regs));
        CHECK(xrt_registers_decode(&abi, image + 1, 383, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(memcmp(&regs, saved_bytes, sizeof(regs)) == 0);
        CHECK(xrt_registers_decode(&abi, image + 1, 385, &regs) == XRT_UNEXPECTED_REGISTER_SIZE);
        CHECK(xrt_registers_decode(&abi, NULL, 384, &regs) == XRT_INVALID_ARGUMENT);
        CHECK(xrt_registers_decode(&abi, image + 1, 384, &regs) == XRT_OK);
    }
    CHECK(regs.values.ppc.r0 == word(0) && regs.values.ppc.r1 == word(1));
    CHECK(regs.values.ppc.r2 == word(2) && regs.values.ppc.r12 == word(12));
    CHECK(regs.values.ppc.r31 == word(31) && regs.values.ppc.pc == word(32));
    CHECK(regs.values.ppc.msr == word(33) && regs.values.ppc.orig_gpr3 == word(34));
    CHECK(regs.values.ppc.ctr == word(35) && regs.values.ppc.lr == word(36));
    CHECK(regs.values.ppc.xer == word(37) && regs.values.ppc.ccr == word(38));
    CHECK(regs.values.ppc.softe == word(39) && regs.values.ppc.trap == word(40));
    CHECK(regs.values.ppc.dar == word(41) && regs.values.ppc.dsisr == word(42));
    CHECK(regs.values.ppc.result == word(43));
    memset(values, 0xa5, sizeof(values));
    memset(present, 0xa5, sizeof(present));
    CHECK(xrt_registers_dwarf(&regs, values, present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    for (size_t i = 0; i < 32; ++i) {
        CHECK(values[i] == word(i) && present[i] == 1);
        CHECK(strcmp(xrt_arch_dwarf_name(XRT_PPC64, (uint16_t)i), arch->registers[i].name) == 0);
    }
    CHECK(values[65] == word(36) && present[65] == 1);
    CHECK(strcmp(xrt_arch_dwarf_name(XRT_PPC64, 65), "lr") == 0);
    CHECK(present[32] == 0 && present[64] == 0);
    CHECK(values[32] == UINT64_C(0xa5a5a5a5a5a5a5a5));
    CHECK(xrt_arch_dwarf_name(XRT_PPC64, 32) == NULL);
    CHECK(xrt_arch_dwarf_name(XRT_PPC64, 64) == NULL);
    CHECK(xrt_arch_dwarf_name(XRT_PPC64, 66) == NULL);
    CHECK(xrt_registers_pc(&regs, &pc) == XRT_OK && pc == word(32));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_SP, &pc) == XRT_OK && pc == word(1));
    CHECK(xrt_registers_role(&regs, XRT_ROLE_RA, &pc) == XRT_OK && pc == word(36));
    CHECK(arch->registers[0].access == XRT_REG_READ_WRITE && strcmp(arch->registers[0].name, "r0") == 0);
    CHECK(arch->registers[2].access == XRT_REG_READ_WRITE && strcmp(arch->registers[2].name, "r2") == 0);
    CHECK(arch->registers[33].access == XRT_REG_READ_ONLY && strcmp(arch->registers[33].name, "msr") == 0);
    CHECK(arch->registers[39].access == XRT_REG_READ_ONLY && strcmp(arch->registers[39].name, "softe") == 0);
    CHECK(arch->registers[41].access == XRT_REG_READ_ONLY && strcmp(arch->registers[41].name, "dar") == 0);
    CHECK(arch->registers[42].access == XRT_REG_READ_ONLY && strcmp(arch->registers[42].name, "dsisr") == 0);
    CHECK(arch->registers[43].access == XRT_REG_READ_ONLY && strcmp(arch->registers[43].name, "result") == 0);
    CHECK(arch->registers[34].access == XRT_REG_READ_WRITE &&
          strcmp(arch->registers[34].name, "orig_gpr3") == 0);
    CHECK(arch->registers[40].access == XRT_REG_READ_WRITE && strcmp(arch->registers[40].name, "trap") == 0);
    {
        unsigned char raw[384];
        memset(raw, 0x5a, sizeof(raw));
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "r0", 2, word(0)) == XRT_OK);
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "r12", 3, word(12)) == XRT_OK);
        CHECK(raw[0] == (unsigned char)(word(0) & 0xff));
        CHECK(raw[383] == 0x5a);
        CHECK(xrt_registers_poke(arch, raw, sizeof(raw), "msr", 3, 1) == XRT_REGISTER_NOT_WRITABLE);
        CHECK(raw[33 * 8] == 0x5a && raw[33 * 8 + 7] == 0x5a);
    }
}

/* A LoongArch NT_PRSTATUS get fills 280 bytes and leaves the reserved tail.
 * Writes and confirmation must not depend on that tail; an unnamed byte that
 * does change after a write (x86 orig_rax) still unconfirms it. */
struct partial_bank {
    unsigned char image[XRT_GPR_BYTES_MAX];
    size_t fill;
    int writes, flip;
};
static enum xrt_status partial_read(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                    unsigned char *raw, size_t size)
{
    struct partial_bank *bank = ctx;
    (void)tid;
    (void)arch;
    memcpy(raw, bank->image, bank->fill < size ? bank->fill : size);
    if (bank->writes && bank->flip >= 0)
        raw[bank->flip] ^= 1;
    return XRT_OK;
}
static enum xrt_status partial_write(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                     const unsigned char *raw, size_t size)
{
    struct partial_bank *bank = ctx;
    (void)tid;
    (void)arch;
    memcpy(bank->image, raw, bank->fill < size ? bank->fill : size);
    ++bank->writes;
    return XRT_OK;
}
static void scribble(void)
{
    volatile unsigned char junk[4096];
    for (size_t i = 0; i < sizeof(junk); ++i)
        junk[i] = 0xee;
}
static void partial_regsets(void)
{
    struct partial_bank bank = {.fill = 280, .flip = -1};
    struct xrt_reg_io io = {.read = partial_read, .write = partial_write, .ctx = &bank};
    struct xrt_mutation_result result = {0};
    unsigned char image[XRT_GPR_BYTES_MAX];
    memset(bank.image, 0x11, sizeof(bank.image));
    memset(image, 0, sizeof(image));
    memcpy(image, bank.image, 280);
    scribble();
    CHECK(xrt_registers_mutate(xrt_arch_get(XRT_LOONGARCH), &io, 1, image, &result) == XRT_OK &&
          result.confirmed);
    const struct xrt_arch *x86 = xrt_arch_get(XRT_X86_64);
    bank = (struct partial_bank){.fill = x86->kernel_gpr_bytes, .flip = 15 * 8};
    memset(bank.image, 0x22, sizeof(bank.image));
    memcpy(image, bank.image, sizeof(image));
    CHECK(xrt_registers_mutate(x86, &io, 1, image, &result) == XRT_PARTIAL_REGISTER_WRITE &&
          result.issued && !result.confirmed);
    const struct xrt_arch *ppc = xrt_arch_get(XRT_PPC64);
    bank = (struct partial_bank){.fill = ppc->kernel_gpr_bytes, .flip = -1};
    memset(bank.image, 0x33, sizeof(bank.image));
    memcpy(image, bank.image, ppc->kernel_gpr_bytes);
    CHECK(xrt_registers_mutate(ppc, &io, 1, image, &result) == XRT_OK && result.confirmed);
    bank.flip = (int)ppc->kernel_gpr_bytes - 1;
    bank.writes = 0;
    CHECK(xrt_registers_mutate(ppc, &io, 1, image, &result) == XRT_PARTIAL_REGISTER_WRITE &&
          result.issued && !result.confirmed);
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
    contract();
    loongarch_replay();
    riscv_replay();
    ppc64_replay();
    partial_regsets();
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
#define COMPARE_KERNEL(name, dwarf, word, id, role)                                                \
    CHECK(before.values.x86.name == kernel_before.name);
    XRT_X86_REGISTERS(COMPARE_KERNEL)
#undef COMPARE_KERNEL
#endif
#if defined(__riscv) && __riscv_xlen == 64
    /* The kernel rewrote every NT_PRSTATUS byte on the measured guest.
     * A hole would disagree between a poisoned buffer and a zeroed one. */
    unsigned char poisoned[256], zeroed[256];
    memset(poisoned, 0xa5, sizeof(poisoned));
    struct iovec poisoned_io = {.iov_base = poisoned, .iov_len = sizeof(poisoned)};
    CHECK(ptrace(PTRACE_GETREGSET, child, (void *)(uintptr_t)1, &poisoned_io) == 0);
    CHECK(poisoned_io.iov_len == 256);
    memset(zeroed, 0, sizeof(zeroed));
    struct iovec zeroed_io = {.iov_base = zeroed, .iov_len = sizeof(zeroed)};
    CHECK(ptrace(PTRACE_GETREGSET, child, (void *)(uintptr_t)1, &zeroed_io) == 0);
    CHECK(zeroed_io.iov_len == 256);
    CHECK(memcmp(poisoned, zeroed, sizeof(zeroed)) == 0);
#define COMPARE_RISCV(name, dwarf, word, id, role)                                                 \
    do {                                                                                           \
        uint64_t kernel_word = 0;                                                                  \
        memcpy(&kernel_word, zeroed + (word) * 8, 8);                                              \
        CHECK(before.values.riscv.name == kernel_word);                                           \
    } while (0);
    XRT_RISCV_REGISTERS(COMPARE_RISCV)
#undef COMPARE_RISCV
#endif
    uint64_t values[XRT_DWARF_REGISTER_COUNT];
    uint8_t present[XRT_DWARF_REGISTER_COUNT];
    CHECK(xrt_registers_dwarf(&before, values, present, XRT_DWARF_REGISTER_COUNT) == XRT_OK);
    const struct xrt_register_desc *pc_reg = xrt_arch_role(arch, XRT_ROLE_PC);
    const struct xrt_register_desc *sp_reg = xrt_arch_role(arch, XRT_ROLE_SP);
    CHECK(pc_reg && sp_reg && present[sp_reg->dwarf] && values[sp_reg->dwarf] != 0);
    uint64_t pc_value = 0;
    if (pc_reg->dwarf == XRT_DWARF_NONE)
        CHECK(xrt_registers_pc(&before, &pc_value) == XRT_OK && pc_value != 0);
    else {
        CHECK(present[pc_reg->dwarf] && values[pc_reg->dwarf] != 0);
        pc_value = values[pc_reg->dwarf];
    }
    const char *scratch = arch->machine == XRT_X86_64      ? "r10"
                          : arch->machine == XRT_LOONGARCH ? "r12"
                          : arch->machine == XRT_PPC64     ? "r12"
                          : arch->machine == XRT_RISCV     ? "a2"
                                                           : "x9";
    CHECK(xrt_register_write(child, scratch, strlen(scratch), UINT64_C(0xabcdef1234567890)) ==
          XRT_OK);
    CHECK(xrt_registers_read(child, &after) == XRT_OK);
    if (arch->machine == XRT_X86_64)
        CHECK(after.values.x86.r10 == UINT64_C(0xabcdef1234567890));
    else if (arch->machine == XRT_LOONGARCH)
        CHECK(after.values.loongarch.r12 == UINT64_C(0xabcdef1234567890));
    else if (arch->machine == XRT_PPC64)
        CHECK(after.values.ppc.r12 == UINT64_C(0xabcdef1234567890));
    else if (arch->machine == XRT_RISCV)
        CHECK(after.values.riscv.a2 == UINT64_C(0xabcdef1234567890));
    else
        CHECK(after.values.arm.x9 == UINT64_C(0xabcdef1234567890));
    /* A thread pointer is listed on x86-64 and is never writable (the kernel
       image compared below proves it stayed); elsewhere it is not a register. */
    CHECK(xrt_register_write(child, "fs_base", 7, 0) ==
          (arch->machine == XRT_X86_64 ? XRT_REGISTER_NOT_WRITABLE : XRT_UNKNOWN_REGISTER));
    CHECK(xrt_register_write(child, "gs_base", 7, 0) ==
          (arch->machine == XRT_X86_64 ? XRT_REGISTER_NOT_WRITABLE : XRT_UNKNOWN_REGISTER));
    CHECK(xrt_register_write(child, "fs", 2, 0) == XRT_UNKNOWN_REGISTER);
    CHECK(xrt_register_write(child, "rax\0", 4, 0) == XRT_UNKNOWN_REGISTER);
    CHECK(xrt_register_write_pc(child, pc_value) == XRT_OK);
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
