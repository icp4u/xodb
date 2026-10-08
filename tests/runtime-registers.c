/* Build with arch.c/registers.c and an ordinary C compiler. An optional argv[1]
 * names an i386 executable for the x86-64 live ABI-mismatch regression. */
#define _GNU_SOURCE 1
#include "loongarch_step.h"
#include "rpc.h"
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
        const struct xrt_abi_id abi = xrt_arch_abi(arch);
        struct xrt_registers regs;
        CHECK(xrt_registers_decode(&abi, bytes + 1, arch->kernel_gpr_bytes, &regs) == XRT_OK);
        CHECK(regs.abi.machine == arch->machine);
        if (regs.abi.machine == XRT_X86_64) {
            CHECK(regs.values.x86.rip == word(16) && regs.values.x86.rsp == word(19));
            CHECK(regs.values.x86.rax == word(10) && regs.values.x86.eflags == word(18));
            CHECK(regs.values.x86.r15 == word(0) && regs.values.x86.r8 == word(9));
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
    struct xrt_register_desc high[18];
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
    const char *scratch = arch->machine == XRT_X86_64     ? "r10"
                          : arch->machine == XRT_LOONGARCH ? "r12"
                                                           : "x9";
    CHECK(xrt_register_write(child, scratch, strlen(scratch), UINT64_C(0xabcdef1234567890)) ==
          XRT_OK);
    CHECK(xrt_registers_read(child, &after) == XRT_OK);
    if (arch->machine == XRT_X86_64)
        CHECK(after.values.x86.r10 == UINT64_C(0xabcdef1234567890));
    else if (arch->machine == XRT_LOONGARCH)
        CHECK(after.values.loongarch.r12 == UINT64_C(0xabcdef1234567890));
    else
        CHECK(after.values.arm.x9 == UINT64_C(0xabcdef1234567890));
    CHECK(xrt_register_write(child, "fs_base", 7, 0) == XRT_UNKNOWN_REGISTER);
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
