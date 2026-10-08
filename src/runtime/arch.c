#include "xrt_arch.h"
#include <string.h>

#define X86_DESC(name, dwarf, word, id, role)                                                      \
    {#name, id, dwarf, offsetof(struct xrt_x86_registers, name), (word) * 8, 8, role,             \
     XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
static const struct xrt_register_desc x86_registers[] = {XRT_X86_REGISTERS(X86_DESC)};
#undef X86_DESC
#define ARM_DESC(name, dwarf, word, id, role)                                                      \
    {#name, id, dwarf, offsetof(struct xrt_arm_registers, name), (word) * 8, 8, role,             \
     XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
static const struct xrt_register_desc arm_registers[] = {XRT_ARM_REGISTERS(ARM_DESC)};
#undef ARM_DESC
/* r0 is the kernel's saved slot. The ISA hard-wires $r0 to zero, and Linux
 * keeps the syscall-restart flag here. A write would not show up in the
 * program and would change restart. */
#define LOONGARCH_DESC(name, dwarf, word, id, role)                                                \
    {#name, id, dwarf, offsetof(struct xrt_loongarch_registers, name), (word) * 8, 8, role,       \
     (id) == 0 ? XRT_REG_READ_ONLY : XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
static const struct xrt_register_desc loongarch_registers[] = {XRT_LOONGARCH_REGISTERS(LOONGARCH_DESC)};
#undef LOONGARCH_DESC
/* msr, softe, dar, dsisr and result are published by the kernel and ignored
 * on write. orig_gpr3 (34) and trap (40) stay writable: they steer restart. */
#define PPC_DESC(name, dwarf, word, id, role)                                                      \
    {#name, id, dwarf, offsetof(struct xrt_ppc64_registers, name), (word) * 8, 8, role,          \
     ((id) == 33 || (id) == 39 || (id) == 41 || (id) == 42 || (id) == 43) ? XRT_REG_READ_ONLY      \
                                                                          : XRT_REG_READ_WRITE,   \
     XRT_REG_ALWAYS},
static const struct xrt_register_desc ppc64_registers[] = {XRT_PPC64_REGISTERS(PPC_DESC)};
#undef PPC_DESC
#define M68K_DESC(name, dwarf, offset, width, id, role)                                            \
    {#name, id, dwarf, offsetof(struct xrt_m68k_registers, name), offset, width, role,            \
     XRT_REG_READ_WRITE, XRT_REG_ALWAYS},
static const struct xrt_register_desc m68k_registers[] = {XRT_M68K_REGISTERS(M68K_DESC)};
#undef M68K_DESC

static const struct xrt_probe_choice x86_probes[] = {
    {XRT_ISA_MODE_ORDINARY, 1, 1, 0, {0xcc, 0, 0, 0}, {0, 0, 0, 0}}};
static const struct xrt_probe_choice m68k_probes[] = {
    {XRT_ISA_MODE_ORDINARY, 2, 2, 0, {0x4e, 0x4f, 0, 0}, {0, 0, 0, 0}}};
static const struct xrt_probe_choice arm_probes[] = {
    {XRT_ISA_MODE_ORDINARY, 4, 4, 0, {0x00, 0x00, 0x20, 0xd4}, {0, 0, 0, 0}}};
static const struct xrt_probe_choice loongarch_probes[] = {
    {XRT_ISA_MODE_ORDINARY, 4, 4, 0, {0x00, 0x00, 0x2a, 0x00}, {0, 0, 0, 0}}};
static const struct xrt_probe_choice ppc64_probes[] = {
    {XRT_ISA_MODE_ORDINARY, 4, 4, 0, {0x08, 0x00, 0xe0, 0x7f}, {0, 0, 0, 0}}};

static const struct xrt_arch architectures[] = {
    {.machine = XRT_M68K,
     .kernel_gpr_bytes = 80,
     .address_bits = 32,
     .little_endian = 0,
     .register_count = 18,
     .dwarf_count = 25,
     .trap_size = 2,
     .trap_alignment = 2,
     .breakpoint_adjust = 2,
     .caller_adjust = 2,
     .trap = {0x4e, 0x4f},
     .registers = m68k_registers,
     .elf_class = XRT_ELF_CLASS_32,
     .linux_abi = XRT_LINUX_ABI_NATIVE,
     .isa_mode = XRT_ISA_MODE_ORDINARY,
     .control_kind = XRT_CONTROL_SINGLE_PC,
     .tracer_bits = 32,
     .hardware_step = 1,
     .probes = m68k_probes,
     .probe_count = 1},
    {.machine = XRT_X86_64,
     .kernel_gpr_bytes = 216,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 18,
     .dwarf_count = 17,
     .trap_size = 1,
     .trap_alignment = 1,
     .breakpoint_adjust = 1,
     .caller_adjust = 1,
     .trap = {0xcc},
     .registers = x86_registers,
     .elf_class = XRT_ELF_CLASS_64,
     .linux_abi = XRT_LINUX_ABI_NATIVE,
     .isa_mode = XRT_ISA_MODE_ORDINARY,
     .control_kind = XRT_CONTROL_SINGLE_PC,
     .tracer_bits = 64,
     .hardware_step = 1,
     .probes = x86_probes,
     .probe_count = 1},
    {.machine = XRT_AARCH64,
     .kernel_gpr_bytes = 272,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 34,
     .dwarf_count = 33,
     .trap_size = 4,
     .trap_alignment = 4,
     .breakpoint_adjust = 0,
     .caller_adjust = 4,
     .trap = {0, 0, 0x20, 0xd4},
     .registers = arm_registers,
     .elf_class = XRT_ELF_CLASS_64,
     .linux_abi = XRT_LINUX_ABI_NATIVE,
     .isa_mode = XRT_ISA_MODE_ORDINARY,
     .control_kind = XRT_CONTROL_SINGLE_PC,
     .tracer_bits = 64,
     .hardware_step = 1,
     .probes = arm_probes,
     .probe_count = 1},
    {.machine = XRT_LOONGARCH,
     .kernel_gpr_bytes = 360,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 35,
     .dwarf_count = 32,
     .trap_size = 4,
     .trap_alignment = 4,
     .breakpoint_adjust = 0,
     .caller_adjust = 4,
     .trap = {0x00, 0x00, 0x2a, 0x00},
     .registers = loongarch_registers,
     .elf_class = XRT_ELF_CLASS_64,
     .linux_abi = XRT_LINUX_ABI_NATIVE,
     .isa_mode = XRT_ISA_MODE_ORDINARY,
     .control_kind = XRT_CONTROL_SINGLE_PC,
     .tracer_bits = 64,
     .hardware_step = 0,
     .probes = loongarch_probes,
     .probe_count = 1},
    {.machine = XRT_PPC64,
     .kernel_gpr_bytes = 384,
     .address_bits = 64,
     .little_endian = 1,
     .register_count = 44,
     .dwarf_count = 66,
     .trap_size = 4,
     .trap_alignment = 4,
     .breakpoint_adjust = 0,
     .caller_adjust = 4,
     .trap = {0x08, 0x00, 0xe0, 0x7f},
     .registers = ppc64_registers,
     .elf_class = XRT_ELF_CLASS_64,
     .linux_abi = XRT_LINUX_ABI_NATIVE,
     .isa_mode = XRT_ISA_MODE_ORDINARY,
     .control_kind = XRT_CONTROL_SINGLE_PC,
     .tracer_bits = 64,
     .hardware_step = 1,
     .probes = ppc64_probes,
     .probe_count = 1},
};

static int product_machine(uint16_t machine)
{
    return machine == XRT_M68K || machine == XRT_X86_64 || machine == XRT_AARCH64 ||
           machine == XRT_LOONGARCH || machine == XRT_PPC64;
}

static int choice_bounds(const struct xrt_probe_choice *choice)
{
    if (!choice)
        return 0;
    if (choice->isa_mode != XRT_ISA_MODE_ORDINARY && choice->isa_mode != XRT_ISA_MODE_ARM &&
        choice->isa_mode != XRT_ISA_MODE_THUMB)
        return 0;
    if (choice->width < 1 || choice->width > 4)
        return 0;
    if (choice->alignment != 1 && choice->alignment != 2 && choice->alignment != 4)
        return 0;
    if (choice->width % choice->alignment != 0)
        return 0;
    if (choice->match_len > choice->width)
        return 0;
    for (uint8_t i = choice->width; i < 4; ++i)
        if (choice->bytes[i])
            return 0;
    for (uint8_t i = choice->match_len; i < 4; ++i)
        if (choice->prefix[i])
            return 0;
    return 1;
}

enum xrt_status xrt_arch_validate(const struct xrt_arch *arch)
{
    if (!arch || !arch->registers)
        return XRT_INVALID_ARGUMENT;
    if (arch->elf_class != XRT_ELF_CLASS_32 && arch->elf_class != XRT_ELF_CLASS_64)
        return XRT_INVALID_ARGUMENT;
    if (arch->little_endian > 1)
        return XRT_INVALID_ARGUMENT;
    const uint8_t bits = arch->elf_class == XRT_ELF_CLASS_32 ? 32 : 64;
    if (arch->address_bits != bits)
        return XRT_INVALID_ARGUMENT;
    if (arch->linux_abi != XRT_LINUX_ABI_NATIVE && arch->linux_abi != XRT_LINUX_ABI_COMPAT32)
        return XRT_INVALID_ARGUMENT;
    if (arch->linux_abi == XRT_LINUX_ABI_COMPAT32 && arch->elf_class != XRT_ELF_CLASS_32)
        return XRT_INVALID_ARGUMENT;
    if (arch->isa_mode != XRT_ISA_MODE_ORDINARY && arch->isa_mode != XRT_ISA_MODE_ARM &&
        arch->isa_mode != XRT_ISA_MODE_THUMB)
        return XRT_INVALID_ARGUMENT;
    if (arch->control_kind > XRT_CONTROL_QUEUE)
        return XRT_INVALID_ARGUMENT;
    if (arch->tracer_bits != 32 && arch->tracer_bits != 64)
        return XRT_INVALID_ARGUMENT;
    if (arch->hardware_step > 1)
        return XRT_INVALID_ARGUMENT;
    if (!arch->register_count)
        return XRT_INVALID_ARGUMENT;
    if (!arch->dwarf_count || arch->dwarf_count > XRT_DWARF_REGISTER_COUNT)
        return XRT_INVALID_ARGUMENT;
    if (!arch->kernel_gpr_bytes || arch->kernel_gpr_bytes > XRT_GPR_BYTES_MAX)
        return XRT_INVALID_ARGUMENT;
    if (arch->trap_size < 1 || arch->trap_size > 4)
        return XRT_INVALID_ARGUMENT;
    if (arch->trap_alignment != 1 && arch->trap_alignment != 2 && arch->trap_alignment != 4)
        return XRT_INVALID_ARGUMENT;
    unsigned pcs = 0, sps = 0, nexts = 0;
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        if (reg->id != i || !reg->name || !reg->name[0])
            return XRT_INVALID_ARGUMENT;
        if (reg->width != 1 && reg->width != 2 && reg->width != 4 && reg->width != 8)
            return XRT_INVALID_ARGUMENT;
        if (reg->access > XRT_REG_READ_ONLY || reg->presence > XRT_REG_OPTIONAL)
            return XRT_INVALID_ARGUMENT;
        if (reg->role > XRT_ROLE_RA)
            return XRT_INVALID_ARGUMENT;
        if ((uint32_t)reg->kernel_offset + reg->width > arch->kernel_gpr_bytes)
            return XRT_INVALID_ARGUMENT;
        if (reg->snapshot_offset % 8 != 0 ||
            (size_t)reg->snapshot_offset + 8 > (size_t)arch->register_count * 8)
            return XRT_INVALID_ARGUMENT;
        for (uint8_t j = 0; j < i; ++j) {
            const struct xrt_register_desc *earlier = &arch->registers[j];
            if (strcmp(earlier->name, reg->name) == 0)
                return XRT_INVALID_ARGUMENT;
            if (reg->dwarf != XRT_DWARF_NONE && earlier->dwarf == reg->dwarf)
                return XRT_INVALID_ARGUMENT;
            if (reg->role != XRT_ROLE_NONE && earlier->role == reg->role)
                return XRT_INVALID_ARGUMENT;
            if (earlier->snapshot_offset == reg->snapshot_offset)
                return XRT_INVALID_ARGUMENT;
        }
        if (reg->role == XRT_ROLE_PC)
            ++pcs;
        else if (reg->role == XRT_ROLE_SP)
            ++sps;
        else if (reg->role == XRT_ROLE_NEXT_PC)
            ++nexts;
    }
    if (pcs != 1 || sps != 1)
        return XRT_INVALID_ARGUMENT;
    if (nexts != (arch->control_kind == XRT_CONTROL_PC_NEXT))
        return XRT_INVALID_ARGUMENT;
    if (arch->probe_count < 1 || arch->probe_count > XRT_PROBE_CHOICE_MAX || !arch->probes)
        return XRT_INVALID_ARGUMENT;
    unsigned ordinary = 0;
    for (uint8_t i = 0; i < arch->probe_count; ++i) {
        if (!choice_bounds(&arch->probes[i]))
            return XRT_INVALID_ARGUMENT;
        if (arch->probes[i].isa_mode == XRT_ISA_MODE_ORDINARY &&
            arch->probes[i].width == arch->trap_size &&
            arch->probes[i].alignment == arch->trap_alignment)
            ++ordinary;
    }
    if (product_machine(arch->machine) && ordinary != 1)
        return XRT_INVALID_ARGUMENT;
    return XRT_OK;
}

struct xrt_abi_id xrt_arch_abi(const struct xrt_arch *arch)
{
    struct xrt_abi_id id = {0};
    if (!arch)
        return id;
    id.machine = arch->machine;
    id.elf_class = arch->elf_class;
    id.little_endian = arch->little_endian;
    id.address_bits = arch->address_bits;
    id.linux_abi = arch->linux_abi;
    id.isa_mode = arch->isa_mode;
    return id;
}

static int abi_equal(const struct xrt_arch *arch, struct xrt_abi_id id)
{
    return arch && arch->machine == id.machine && arch->elf_class == id.elf_class &&
           arch->little_endian == id.little_endian && arch->address_bits == id.address_bits &&
           arch->linux_abi == id.linux_abi && arch->isa_mode == id.isa_mode;
}

const struct xrt_arch *xrt_arch_get(uint16_t machine)
{
    const struct xrt_arch *found = NULL;
    for (size_t i = 0; i < sizeof(architectures) / sizeof(architectures[0]); ++i) {
        if (architectures[i].machine != machine)
            continue;
        if (xrt_arch_validate(&architectures[i]) != XRT_OK)
            continue;
        if (found)
            return NULL;
        found = &architectures[i];
    }
    return found;
}

const struct xrt_arch *xrt_arch_resolve_in(struct xrt_abi_id id,
                                           const struct xrt_arch *const *rows, size_t count)
{
    const struct xrt_arch *found = NULL;
    if (!rows && count)
        return NULL;
    for (size_t i = 0; i < count; ++i) {
        if (!rows[i] || xrt_arch_validate(rows[i]) != XRT_OK || !abi_equal(rows[i], id))
            continue;
        if (found)
            return NULL;
        found = rows[i];
    }
    return found;
}

const struct xrt_arch *xrt_arch_resolve(struct xrt_abi_id id)
{
    const struct xrt_arch *rows[sizeof(architectures) / sizeof(architectures[0])];
    const size_t count = sizeof(architectures) / sizeof(architectures[0]);
    for (size_t i = 0; i < count; ++i)
        rows[i] = &architectures[i];
    return xrt_arch_resolve_in(id, rows, count);
}

const struct xrt_arch *xrt_arch_native(void)
{
    const struct xrt_arch *arch = NULL;
#if defined(__x86_64__) && !defined(__ILP32__)
    arch = xrt_arch_get(XRT_X86_64);
#elif defined(__aarch64__) && !defined(__AARCH64EB__) && !defined(__ILP32__)
    arch = xrt_arch_get(XRT_AARCH64);
#elif defined(__m68k__)
    arch = xrt_arch_get(XRT_M68K);
#elif defined(__loongarch_lp64) && defined(__loongarch_double_float)
    arch = xrt_arch_get(XRT_LOONGARCH);
#elif defined(__powerpc64__) && defined(_CALL_ELF) && _CALL_ELF == 2 &&                            \
    __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    arch = xrt_arch_get(XRT_PPC64);
#endif
    if (!arch || arch->tracer_bits != sizeof(long) * 8)
        return NULL;
    return arch;
}

const struct xrt_register_desc *xrt_arch_register_id(const struct xrt_arch *arch, uint16_t id)
{
    if (!arch || id >= arch->register_count || arch->registers[id].id != id)
        return NULL;
    return &arch->registers[id];
}

const struct xrt_register_desc *xrt_arch_role(const struct xrt_arch *arch, uint8_t role)
{
    const struct xrt_register_desc *found = NULL;
    if (!arch || role == XRT_ROLE_NONE)
        return NULL;
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        if (arch->registers[i].role != role)
            continue;
        if (found)
            return NULL;
        found = &arch->registers[i];
    }
    return found;
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
    if (!arch || number == XRT_DWARF_NONE || number >= arch->dwarf_count)
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

enum xrt_status xrt_arch_probe_prepare(const struct xrt_arch *arch,
                                       const struct xrt_probe_request *request,
                                       struct xrt_probe_encoding *out)
{
    if (!arch || !request || !out)
        return XRT_INVALID_ARGUMENT;
    if (request->isa_mode == XRT_ISA_MODE_NONE || request->isa_mode > XRT_ISA_MODE_THUMB)
        return XRT_INVALID_ARGUMENT;
    if (request->size && !request->bytes)
        return XRT_INVALID_ARGUMENT;
    if (arch->probe_count < 1 || arch->probe_count > XRT_PROBE_CHOICE_MAX || !arch->probes)
        return XRT_INVALID_ARGUMENT;
    int complete = 0, short_found = 0;
    const struct xrt_probe_choice *chosen = NULL;
    for (uint8_t i = 0; i < arch->probe_count; ++i) {
        const struct xrt_probe_choice *choice = &arch->probes[i];
        if (choice->isa_mode != request->isa_mode)
            continue;
        if (!choice_bounds(choice))
            return XRT_INVALID_ARGUMENT;
        const int miss = choice->match_len > 0 && request->size >= choice->match_len &&
                         memcmp(request->bytes, choice->prefix, choice->match_len) != 0;
        const int is_short =
            !miss && (request->size < choice->width || request->size < choice->match_len);
        if (is_short)
            short_found = 1;
        if (!miss && !is_short) {
            ++complete;
            chosen = choice;
        }
    }
    if (short_found)
        return XRT_BUFFER_TOO_SMALL;
    if (complete > 1)
        return XRT_AMBIGUOUS_MATCH;
    if (!complete)
        return XRT_UNSUPPORTED_MODE;
    if (!request->address || request->address % chosen->alignment)
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    if (request->address > UINT64_MAX - chosen->width)
        return XRT_INVALID_ARGUMENT;
    if (arch->address_bits < 64 && request->address >> arch->address_bits)
        return XRT_INVALID_BREAKPOINT_ADDRESS;
    struct xrt_probe_encoding encoding = {.isa_mode = chosen->isa_mode,
                                          .width = chosen->width,
                                          .alignment = chosen->alignment};
    memcpy(encoding.bytes, chosen->bytes, chosen->width);
    *out = encoding;
    return XRT_OK;
}

enum xrt_status xrt_arch_step_resources(const struct xrt_arch *arch, uint8_t isa_mode,
                                        struct xrt_step_resources *out)
{
    if (!arch || !out)
        return XRT_INVALID_ARGUMENT;
    if (isa_mode == XRT_ISA_MODE_NONE || isa_mode > XRT_ISA_MODE_THUMB)
        return XRT_INVALID_ARGUMENT;
    int found = 0;
    for (uint8_t i = 0; i < arch->probe_count; ++i)
        found |= arch->probes && arch->probes[i].isa_mode == isa_mode;
    if (!found)
        return XRT_UNSUPPORTED_MODE;
    *out = (struct xrt_step_resources){
        .max_probes = XRT_STEP_PROBE_MAX,
        .hardware_step = arch->hardware_step,
        .software_probes = arch->machine == XRT_LOONGARCH && !arch->hardware_step ? 2 : 0};
    return XRT_OK;
}

static const struct xrt_register_desc *match_copy(const struct xrt_arch *arch,
                                                  const struct xrt_register_desc *desc)
{
    if (!arch || !desc || !desc->name || desc->id >= arch->register_count)
        return NULL;
    const struct xrt_register_desc *row = &arch->registers[desc->id];
    if (!row->name || strcmp(row->name, desc->name) != 0 || row->dwarf != desc->dwarf ||
        row->role != desc->role)
        return NULL;
    return row;
}

static int listed(const uint16_t *ids, uint8_t count, uint16_t id)
{
    for (uint8_t i = 0; i < count; ++i)
        if (ids[i] == id)
            return 1;
    return 0;
}

enum xrt_status xrt_registers_validate(const struct xrt_arch *arch, const struct xrt_registers *regs)
{
    if (!arch || !arch->registers || !regs)
        return XRT_INVALID_ARGUMENT;
    if (regs->absent_count > XRT_ABSENT_MAX || regs->unknown_count > XRT_ABSENT_MAX ||
        regs->absent_count > arch->register_count || regs->unknown_count > arch->register_count)
        return XRT_INVALID_ARGUMENT;
    /* Descriptor ids are below register_count (a uint8_t), so one bit per id
     * keeps duplicate and overlap checks linear. */
    uint8_t listed_ids[32] = {0};
    for (unsigned list = 0; list < 2; ++list) {
        const uint16_t *ids = list ? regs->unknown_id : regs->absent_id;
        const uint8_t count = list ? regs->unknown_count : regs->absent_count;
        for (uint8_t i = 0; i < count; ++i) {
            const uint16_t id = ids[i];
            if (id >= arch->register_count || listed_ids[id / 8] & (1u << (id % 8)))
                return XRT_INVALID_ARGUMENT;
            listed_ids[id / 8] |= (uint8_t)(1u << (id % 8));
        }
    }
    /* A present value never exceeds its descriptor width. Storage under an
     * absent or unknown id may hold a sentinel and is never read. */
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        if ((size_t)reg->snapshot_offset + sizeof(uint64_t) > sizeof(regs->values))
            return XRT_INVALID_ARGUMENT;
        if (reg->width >= 8 || listed_ids[i / 8] & (1u << (i % 8)))
            continue;
        uint64_t value;
        memcpy(&value, (const unsigned char *)&regs->values + reg->snapshot_offset, sizeof(value));
        if (value >> (8 * reg->width))
            return XRT_INVALID_ARGUMENT;
    }
    return XRT_OK;
}

static uint64_t load_field(const struct xrt_arch *arch, const unsigned char *raw,
                           const struct xrt_register_desc *reg)
{
    uint64_t value = 0;
    for (uint8_t b = 0; b < reg->width; ++b)
        value |= (uint64_t)raw[reg->kernel_offset + b]
                 << (8 * (arch->little_endian ? b : reg->width - 1 - b));
    return value;
}

enum xrt_status xrt_registers_decode_row(const struct xrt_arch *arch, const void *bytes,
                                         size_t size, struct xrt_registers *out)
{
    if (!arch || !out)
        return XRT_INVALID_ARGUMENT;
    if (xrt_arch_validate(arch) != XRT_OK)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!bytes)
        return XRT_INVALID_ARGUMENT;
    if (size != arch->kernel_gpr_bytes)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    struct xrt_registers decoded = {.abi = xrt_arch_abi(arch)};
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        const uint64_t value = load_field(arch, bytes, reg);
        memcpy((unsigned char *)&decoded.values + reg->snapshot_offset, &value, sizeof(value));
    }
    if (xrt_registers_validate(arch, &decoded) != XRT_OK)
        return XRT_INVALID_ARGUMENT;
    *out = decoded;
    return XRT_OK;
}

enum xrt_status xrt_registers_decode(const struct xrt_abi_id *abi, const void *bytes, size_t size,
                                     struct xrt_registers *out)
{
    if (!abi || !out)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(*abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    return xrt_registers_decode_row(arch, bytes, size, out);
}

enum xrt_availability xrt_registers_availability_row(const struct xrt_arch *arch,
                                                     const struct xrt_registers *regs,
                                                     const struct xrt_register_desc *desc)
{
    const struct xrt_register_desc *row = match_copy(arch, desc);
    if (!arch || !regs || !row || xrt_registers_validate(arch, regs) != XRT_OK)
        return XRT_AVAIL_UNSUPPORTED;
    if (listed(regs->absent_id, regs->absent_count, row->id))
        return XRT_AVAIL_ABSENT;
    if (listed(regs->unknown_id, regs->unknown_count, row->id))
        return XRT_AVAIL_UNKNOWN;
    return XRT_AVAIL_PRESENT;
}

enum xrt_availability xrt_registers_availability(const struct xrt_registers *regs,
                                                 const struct xrt_register_desc *desc)
{
    if (!regs)
        return XRT_AVAIL_UNSUPPORTED;
    return xrt_registers_availability_row(xrt_arch_resolve(regs->abi), regs, desc);
}

static enum xrt_status mark_id(struct xrt_registers *regs, uint16_t id, int unknown)
{
    if (!regs)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(regs->abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (xrt_registers_validate(arch, regs) != XRT_OK || id >= arch->register_count)
        return XRT_INVALID_ARGUMENT;
    if (listed(regs->absent_id, regs->absent_count, id) ||
        listed(regs->unknown_id, regs->unknown_count, id))
        return XRT_INVALID_ARGUMENT;
    if (unknown) {
        if (regs->unknown_count == XRT_ABSENT_MAX)
            return XRT_INVALID_ARGUMENT;
        regs->unknown_id[regs->unknown_count++] = id;
    } else {
        if (regs->absent_count == XRT_ABSENT_MAX)
            return XRT_INVALID_ARGUMENT;
        regs->absent_id[regs->absent_count++] = id;
    }
    return XRT_OK;
}

enum xrt_status xrt_registers_mark_absent(struct xrt_registers *regs, uint16_t id)
{
    return mark_id(regs, id, 0);
}

enum xrt_status xrt_registers_mark_unknown(struct xrt_registers *regs, uint16_t id)
{
    return mark_id(regs, id, 1);
}

enum xrt_status xrt_registers_value_desc_row(const struct xrt_arch *arch,
                                             const struct xrt_registers *regs,
                                             const struct xrt_register_desc *desc, uint64_t *out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    const enum xrt_availability availability = xrt_registers_availability_row(arch, regs, desc);
    if (availability != XRT_AVAIL_PRESENT)
        return availability == XRT_AVAIL_UNSUPPORTED ? XRT_UNSUPPORTED_ARCHITECTURE
                                                     : XRT_REGISTER_UNAVAILABLE;
    memcpy(out, (const unsigned char *)&regs->values + arch->registers[desc->id].snapshot_offset,
           sizeof(*out));
    return XRT_OK;
}

enum xrt_status xrt_registers_value_desc(const struct xrt_registers *regs,
                                         const struct xrt_register_desc *desc, uint64_t *out)
{
    if (!regs || !out)
        return XRT_INVALID_ARGUMENT;
    return xrt_registers_value_desc_row(xrt_arch_resolve(regs->abi), regs, desc, out);
}

enum xrt_status xrt_registers_value(const struct xrt_registers *regs, const char *name,
                                    size_t length, uint64_t *out)
{
    if (!regs || !out)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(regs->abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    const struct xrt_register_desc *reg = xrt_arch_register(arch->machine, name, length);
    if (!reg)
        return XRT_UNKNOWN_REGISTER;
    return xrt_registers_value_desc_row(arch, regs, reg, out);
}

enum xrt_status xrt_registers_value_dwarf(const struct xrt_registers *regs, uint16_t dwarf,
                                          uint64_t *out)
{
    if (!regs || !out)
        return XRT_INVALID_ARGUMENT;
    if (dwarf == XRT_DWARF_NONE)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(regs->abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    for (uint8_t i = 0; i < arch->register_count; ++i)
        if (arch->registers[i].dwarf == dwarf)
            return xrt_registers_value_desc_row(arch, regs, &arch->registers[i], out);
    return XRT_UNKNOWN_REGISTER;
}

enum xrt_status xrt_registers_role(const struct xrt_registers *regs, uint8_t role, uint64_t *out)
{
    if (!regs || !out)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(regs->abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    const struct xrt_register_desc *reg = xrt_arch_role(arch, role);
    if (!reg)
        return XRT_UNKNOWN_REGISTER;
    return xrt_registers_value_desc_row(arch, regs, reg, out);
}

enum xrt_status xrt_registers_pc(const struct xrt_registers *regs, uint64_t *out)
{
    return xrt_registers_role(regs, XRT_ROLE_PC, out);
}

enum xrt_status xrt_registers_dwarf(const struct xrt_registers *regs, uint64_t *out,
                                    uint8_t *present, size_t count)
{
    if (!regs || !out || !present)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_arch *arch = xrt_arch_resolve(regs->abi);
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (count < arch->dwarf_count)
        return XRT_BUFFER_TOO_SMALL;
    /* Callers may pass a count above dwarf_count. Numbers at or above
     * dwarf_count are not dense slots, so every supplied present[] entry
     * starts absent and only an admitted number is set. out[] is untouched
     * except for those admitted numbers. */
    for (size_t i = 0; i < count; ++i)
        present[i] = 0;
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *reg = &arch->registers[i];
        if (reg->dwarf == XRT_DWARF_NONE || reg->dwarf >= arch->dwarf_count)
            continue;
        if (xrt_registers_availability_row(arch, regs, reg) != XRT_AVAIL_PRESENT)
            continue;
        memcpy(&out[reg->dwarf], (const unsigned char *)&regs->values + reg->snapshot_offset,
               sizeof(uint64_t));
        present[reg->dwarf] = 1;
    }
    return XRT_OK;
}
