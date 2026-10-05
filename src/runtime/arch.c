#include "xrt_arch.h"
#include <string.h>

#define X86_DESC(name, dwarf, word)                                                                \
    {#name, dwarf, offsetof(struct xrt_x86_registers, name), (word) * 8, 8},
static const struct xrt_register_desc x86_registers[] = {XRT_X86_REGISTERS(X86_DESC)};
#undef X86_DESC
#define ARM_DESC(name, dwarf, word)                                                                \
    {#name, dwarf, offsetof(struct xrt_arm_registers, name), (word) * 8, 8},
static const struct xrt_register_desc arm_registers[] = {XRT_ARM_REGISTERS(ARM_DESC)};
#undef ARM_DESC

#define M68K_DESC(name, dwarf, offset, width)                                                      \
    {#name, dwarf, offsetof(struct xrt_m68k_registers, name), offset, width},
static const struct xrt_register_desc m68k_registers[] = {XRT_M68K_REGISTERS(M68K_DESC)};
#undef M68K_DESC
static const struct xrt_arch architectures[] = {
    {.machine = XRT_M68K,
     .kernel_gpr_bytes = 80,
     .address_bits = 32,
     .little_endian = 0,
     .register_count = 18,
     .dwarf_count = 25,
     .pc = 24,
     .sp = 15,
     .ra = 24,
     .trap_size = 2,
     .trap_alignment = 2,
     .breakpoint_adjust = 2,
     .caller_adjust = 2,
     .trap = {0x4e, 0x4f},
     .registers = m68k_registers},
    {.machine = XRT_X86_64,
     .kernel_gpr_bytes = 216,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 18,
     .dwarf_count = 17,
     .pc = 16,
     .sp = 7,
     .ra = 16,
     .trap_size = 1,
     .trap_alignment = 1,
     .breakpoint_adjust = 1,
     .caller_adjust = 1,
     .trap = {0xcc},
     .registers = x86_registers},
    {.machine = XRT_AARCH64,
     .kernel_gpr_bytes = 272,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 34,
     .dwarf_count = 33,
     .pc = 32,
     .sp = 31,
     .ra = 30,
     .trap_size = 4,
     .trap_alignment = 4,
     .breakpoint_adjust = 0,
     .caller_adjust = 4,
     .trap = {0, 0, 0x20, 0xd4},
     .registers = arm_registers},
};

const struct xrt_arch *xrt_arch_get(uint16_t machine)
{
    for (size_t i = 0; i < sizeof(architectures) / sizeof(architectures[0]); ++i)
        if (architectures[i].machine == machine)
            return &architectures[i];
    return NULL;
}

const struct xrt_arch *xrt_arch_native(void)
{
#if defined(__x86_64__) && !defined(__ILP32__)
    return xrt_arch_get(XRT_X86_64);
#elif defined(__aarch64__) && !defined(__AARCH64EB__) && !defined(__ILP32__)
    return xrt_arch_get(XRT_AARCH64);
#elif defined(__m68k__)
    return xrt_arch_get(XRT_M68K);
#else
    return NULL;
#endif
}

const struct xrt_register_desc *xrt_arch_register(uint16_t machine, const char *name, size_t length)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    if (!arch || !name)
        return NULL;
    for (size_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        if (strlen(reg->name) == length && memcmp(reg->name, name, length) == 0)
            return reg;
    }
    return NULL;
}

const char *xrt_arch_dwarf_name(uint16_t machine, uint16_t number)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    if (!arch || number >= arch->dwarf_count)
        return NULL;
    for (size_t i = 0; i < arch->register_count; ++i)
        if (arch->registers[i].dwarf == number)
            return arch->registers[i].name;
    return NULL;
}

static int adjust_pc(const struct xrt_arch *arch, uint64_t raw, uint8_t adjust, uint64_t *pc)
{
    if (!arch || !pc || raw < adjust)
        return 0;
    if (arch->address_bits < 64 && raw >> arch->address_bits)
        return 0;
    *pc = raw - adjust;
    return 1;
}

int xrt_arch_breakpoint_pc(uint16_t machine, uint64_t raw, uint64_t *pc)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    return adjust_pc(arch, raw, arch ? arch->breakpoint_adjust : 0, pc);
}

int xrt_arch_caller_pc(uint16_t machine, uint64_t raw, uint64_t *pc)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    return adjust_pc(arch, raw, arch ? arch->caller_adjust : 0, pc);
}

int xrt_arch_breakpoint_valid(uint16_t machine, uint64_t address, size_t size)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    if (!arch || size != arch->trap_size || address % arch->trap_alignment != 0)
        return 0;
    return arch->address_bits == 64 || address >> arch->address_bits == 0;
}

enum xrt_status xrt_registers_decode(uint16_t machine, const void *bytes, size_t size,
                                     struct xrt_registers *out)
{
    const struct xrt_arch *arch = xrt_arch_get(machine);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!bytes || !out)
        return XRT_INVALID_ARGUMENT;
    if (size != arch->kernel_gpr_bytes)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    struct xrt_registers decoded = {.machine = machine};
    for (size_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        const unsigned char *raw = (const unsigned char *)bytes + reg->kernel_offset;
        uint64_t value = 0;
        for (size_t b = 0; b < reg->width; ++b)
            value |= (uint64_t)raw[b] << (8 * (arch->little_endian ? b : reg->width - 1 - b));
        memcpy((unsigned char *)&decoded.values + reg->snapshot_offset, &value, sizeof(value));
    }
    *out = decoded;
    return XRT_OK;
}

enum xrt_status xrt_registers_dwarf(const struct xrt_registers *regs, uint64_t *out, size_t count)
{
    if (!regs || !out)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_get(regs->machine);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (count < arch->dwarf_count)
        return XRT_BUFFER_TOO_SMALL;
    memset(out, 0, arch->dwarf_count * sizeof(*out));
    for (size_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        if (reg->dwarf < arch->dwarf_count)
            memcpy(&out[reg->dwarf], (const unsigned char *)&regs->values + reg->snapshot_offset,
                   sizeof(uint64_t));
    }
    return XRT_OK;
}
