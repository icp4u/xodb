#ifndef XODB_RUNTIME_ARCH_H
#define XODB_RUNTIME_ARCH_H

#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

#define XRT_M68K 4
#define XRT_X86_64 62
#define XRT_AARCH64 183
#define XRT_LOONGARCH 258
#define XRT_DWARF_NONE UINT16_MAX
#define XRT_DWARF_REGISTER_COUNT 33
#define XRT_GPR_BYTES_MAX 384
#define XRT_ABSENT_MAX 48
#define XRT_PROBE_CHOICE_MAX 2
#define XRT_STEP_PROBE_MAX 2
#define XRT_ROW_LAYOUT 1

#define XRT_ELF_CLASS_32 1
#define XRT_ELF_CLASS_64 2
#define XRT_LINUX_ABI_NATIVE 1
#define XRT_LINUX_ABI_COMPAT32 2
#define XRT_ISA_MODE_NONE 0
#define XRT_ISA_MODE_ORDINARY 1
#define XRT_ISA_MODE_ARM 2
#define XRT_ISA_MODE_THUMB 3

#define XRT_CONTROL_SINGLE_PC 0
#define XRT_CONTROL_PC_NEXT 1
#define XRT_CONTROL_QUEUE 2

#define XRT_REG_READ_WRITE 0
#define XRT_REG_READ_ONLY 1
#define XRT_REG_ALWAYS 0
#define XRT_REG_OPTIONAL 1

#define XRT_ROLE_NONE 0
#define XRT_ROLE_PC 1
#define XRT_ROLE_NEXT_PC 2
#define XRT_ROLE_SP 3
#define XRT_ROLE_RA 4

/* name, DWARF number, kernel word or byte offset, descriptor id, role.
 * Descriptor ids are the current macro order. XRT_ROW_LAYOUT 1 freezes it. */
#define XRT_X86_REGISTERS(X)                                                                       \
    X(rip, 16, 16, 0, XRT_ROLE_PC)                                                                 \
    X(rsp, 7, 19, 1, XRT_ROLE_SP)                                                                  \
    X(rbp, 6, 4, 2, XRT_ROLE_NONE)                                                                 \
    X(rax, 0, 10, 3, XRT_ROLE_NONE)                                                                \
    X(rbx, 3, 5, 4, XRT_ROLE_NONE)                                                                 \
    X(rcx, 2, 11, 5, XRT_ROLE_NONE)                                                                \
    X(rdx, 1, 12, 6, XRT_ROLE_NONE)                                                                \
    X(rsi, 4, 13, 7, XRT_ROLE_NONE)                                                                \
    X(rdi, 5, 14, 8, XRT_ROLE_NONE)                                                                \
    X(r8, 8, 9, 9, XRT_ROLE_NONE)                                                                  \
    X(r9, 9, 8, 10, XRT_ROLE_NONE)                                                                 \
    X(r10, 10, 7, 11, XRT_ROLE_NONE)                                                               \
    X(r11, 11, 6, 12, XRT_ROLE_NONE)                                                               \
    X(r12, 12, 3, 13, XRT_ROLE_NONE)                                                               \
    X(r13, 13, 2, 14, XRT_ROLE_NONE)                                                               \
    X(r14, 14, 1, 15, XRT_ROLE_NONE)                                                               \
    X(r15, 15, 0, 16, XRT_ROLE_NONE)                                                               \
    X(eflags, XRT_DWARF_NONE, 18, 17, XRT_ROLE_NONE)

#define XRT_ARM_REGISTERS(X)                                                                       \
    X(x0, 0, 0, 0, XRT_ROLE_NONE)                                                                  \
    X(x1, 1, 1, 1, XRT_ROLE_NONE)                                                                  \
    X(x2, 2, 2, 2, XRT_ROLE_NONE)                                                                  \
    X(x3, 3, 3, 3, XRT_ROLE_NONE)                                                                  \
    X(x4, 4, 4, 4, XRT_ROLE_NONE)                                                                  \
    X(x5, 5, 5, 5, XRT_ROLE_NONE)                                                                  \
    X(x6, 6, 6, 6, XRT_ROLE_NONE)                                                                  \
    X(x7, 7, 7, 7, XRT_ROLE_NONE)                                                                  \
    X(x8, 8, 8, 8, XRT_ROLE_NONE)                                                                  \
    X(x9, 9, 9, 9, XRT_ROLE_NONE)                                                                  \
    X(x10, 10, 10, 10, XRT_ROLE_NONE)                                                              \
    X(x11, 11, 11, 11, XRT_ROLE_NONE)                                                              \
    X(x12, 12, 12, 12, XRT_ROLE_NONE)                                                              \
    X(x13, 13, 13, 13, XRT_ROLE_NONE)                                                              \
    X(x14, 14, 14, 14, XRT_ROLE_NONE)                                                              \
    X(x15, 15, 15, 15, XRT_ROLE_NONE)                                                              \
    X(x16, 16, 16, 16, XRT_ROLE_NONE)                                                              \
    X(x17, 17, 17, 17, XRT_ROLE_NONE)                                                              \
    X(x18, 18, 18, 18, XRT_ROLE_NONE)                                                              \
    X(x19, 19, 19, 19, XRT_ROLE_NONE)                                                              \
    X(x20, 20, 20, 20, XRT_ROLE_NONE)                                                              \
    X(x21, 21, 21, 21, XRT_ROLE_NONE)                                                              \
    X(x22, 22, 22, 22, XRT_ROLE_NONE)                                                              \
    X(x23, 23, 23, 23, XRT_ROLE_NONE)                                                              \
    X(x24, 24, 24, 24, XRT_ROLE_NONE)                                                              \
    X(x25, 25, 25, 25, XRT_ROLE_NONE)                                                              \
    X(x26, 26, 26, 26, XRT_ROLE_NONE)                                                              \
    X(x27, 27, 27, 27, XRT_ROLE_NONE)                                                              \
    X(x28, 28, 28, 28, XRT_ROLE_NONE)                                                              \
    X(x29, 29, 29, 29, XRT_ROLE_NONE)                                                              \
    X(x30, 30, 30, 30, XRT_ROLE_RA)                                                                \
    X(sp, 31, 31, 31, XRT_ROLE_SP)                                                                 \
    X(pc, 32, 32, 32, XRT_ROLE_PC)                                                                 \
    X(pstate, XRT_DWARF_NONE, 33, 33, XRT_ROLE_NONE)

/* LoongArch64 LP64 NT_PRSTATUS is user_pt_regs: 45 little-endian words.
 * csr_era is the PC at word 33. DWARF 0-31 are r0-r31; the PC has no
 * DWARF number. r1 is the return-address column and r3 is the stack pointer. */
#define XRT_LOONGARCH_REGISTERS(X)                                                                 \
    X(r0, 0, 0, 0, XRT_ROLE_NONE)                                                                  \
    X(r1, 1, 1, 1, XRT_ROLE_RA)                                                                    \
    X(r2, 2, 2, 2, XRT_ROLE_NONE)                                                                  \
    X(r3, 3, 3, 3, XRT_ROLE_SP)                                                                    \
    X(r4, 4, 4, 4, XRT_ROLE_NONE)                                                                  \
    X(r5, 5, 5, 5, XRT_ROLE_NONE)                                                                  \
    X(r6, 6, 6, 6, XRT_ROLE_NONE)                                                                  \
    X(r7, 7, 7, 7, XRT_ROLE_NONE)                                                                  \
    X(r8, 8, 8, 8, XRT_ROLE_NONE)                                                                  \
    X(r9, 9, 9, 9, XRT_ROLE_NONE)                                                                  \
    X(r10, 10, 10, 10, XRT_ROLE_NONE)                                                              \
    X(r11, 11, 11, 11, XRT_ROLE_NONE)                                                              \
    X(r12, 12, 12, 12, XRT_ROLE_NONE)                                                              \
    X(r13, 13, 13, 13, XRT_ROLE_NONE)                                                              \
    X(r14, 14, 14, 14, XRT_ROLE_NONE)                                                              \
    X(r15, 15, 15, 15, XRT_ROLE_NONE)                                                              \
    X(r16, 16, 16, 16, XRT_ROLE_NONE)                                                              \
    X(r17, 17, 17, 17, XRT_ROLE_NONE)                                                              \
    X(r18, 18, 18, 18, XRT_ROLE_NONE)                                                              \
    X(r19, 19, 19, 19, XRT_ROLE_NONE)                                                              \
    X(r20, 20, 20, 20, XRT_ROLE_NONE)                                                              \
    X(r21, 21, 21, 21, XRT_ROLE_NONE)                                                              \
    X(r22, 22, 22, 22, XRT_ROLE_NONE)                                                              \
    X(r23, 23, 23, 23, XRT_ROLE_NONE)                                                              \
    X(r24, 24, 24, 24, XRT_ROLE_NONE)                                                              \
    X(r25, 25, 25, 25, XRT_ROLE_NONE)                                                              \
    X(r26, 26, 26, 26, XRT_ROLE_NONE)                                                              \
    X(r27, 27, 27, 27, XRT_ROLE_NONE)                                                              \
    X(r28, 28, 28, 28, XRT_ROLE_NONE)                                                              \
    X(r29, 29, 29, 29, XRT_ROLE_NONE)                                                              \
    X(r30, 30, 30, 30, XRT_ROLE_NONE)                                                              \
    X(r31, 31, 31, 31, XRT_ROLE_NONE)                                                              \
    X(orig_a0, XRT_DWARF_NONE, 32, 32, XRT_ROLE_NONE)                                               \
    X(pc, XRT_DWARF_NONE, 33, 33, XRT_ROLE_PC)                                                     \
    X(badv, XRT_DWARF_NONE, 34, 34, XRT_ROLE_NONE)

/* Linux m68k GETREGS uses 32-bit words, with SR at byte 70. The historical
 * dense return-address number is 24, which is the PC, not a link-register role. */
#define XRT_M68K_REGISTERS(X)                                                                      \
    X(d0, 0, 56, 4, 0, XRT_ROLE_NONE)                                                              \
    X(d1, 1, 0, 4, 1, XRT_ROLE_NONE)                                                               \
    X(d2, 2, 4, 4, 2, XRT_ROLE_NONE)                                                               \
    X(d3, 3, 8, 4, 3, XRT_ROLE_NONE)                                                               \
    X(d4, 4, 12, 4, 4, XRT_ROLE_NONE)                                                              \
    X(d5, 5, 16, 4, 5, XRT_ROLE_NONE)                                                              \
    X(d6, 6, 20, 4, 6, XRT_ROLE_NONE)                                                              \
    X(d7, 7, 24, 4, 7, XRT_ROLE_NONE)                                                              \
    X(a0, 8, 28, 4, 8, XRT_ROLE_NONE)                                                              \
    X(a1, 9, 32, 4, 9, XRT_ROLE_NONE)                                                              \
    X(a2, 10, 36, 4, 10, XRT_ROLE_NONE)                                                            \
    X(a3, 11, 40, 4, 11, XRT_ROLE_NONE)                                                            \
    X(a4, 12, 44, 4, 12, XRT_ROLE_NONE)                                                            \
    X(a5, 13, 48, 4, 13, XRT_ROLE_NONE)                                                            \
    X(a6, 14, 52, 4, 14, XRT_ROLE_NONE)                                                            \
    X(usp, 15, 60, 4, 15, XRT_ROLE_SP)                                                             \
    X(pc, 24, 72, 4, 16, XRT_ROLE_PC)                                                              \
    X(sr, XRT_DWARF_NONE, 70, 2, 17, XRT_ROLE_NONE)
#define XRT_M68K_FIELD(name, dwarf, offset, width, id, role) uint64_t name;
struct xrt_m68k_registers {
    XRT_M68K_REGISTERS(XRT_M68K_FIELD)
};
#undef XRT_M68K_FIELD

#define XRT_REGISTER_FIELD(name, dwarf, word, id, role) uint64_t name;
struct xrt_x86_registers {
    XRT_X86_REGISTERS(XRT_REGISTER_FIELD)
};
struct xrt_arm_registers {
    XRT_ARM_REGISTERS(XRT_REGISTER_FIELD)
};
struct xrt_loongarch_registers {
    XRT_LOONGARCH_REGISTERS(XRT_REGISTER_FIELD)
};
#undef XRT_REGISTER_FIELD

enum xrt_availability {
    XRT_AVAIL_PRESENT = 1,
    XRT_AVAIL_ABSENT = 2,
    XRT_AVAIL_UNKNOWN = 3,
    XRT_AVAIL_UNSUPPORTED = 4
};

struct xrt_abi_id {
    uint16_t machine;
    uint8_t elf_class;
    uint8_t little_endian;
    uint8_t address_bits;
    uint8_t linux_abi;
    uint8_t isa_mode;
};

struct xrt_register_desc {
    const char *name;
    uint16_t id;
    uint16_t dwarf;
    uint16_t snapshot_offset, kernel_offset;
    uint8_t width, role, access, presence;
};

struct xrt_probe_choice {
    uint8_t isa_mode, width, alignment, match_len;
    uint8_t bytes[4];
    uint8_t prefix[4];
};

struct xrt_arch {
    uint16_t machine, kernel_gpr_bytes;
    uint8_t address_bits, little_endian;
    uint8_t register_count, dwarf_count;
    uint8_t trap_size, trap_alignment, breakpoint_adjust, caller_adjust;
    uint8_t trap[4];
    const struct xrt_register_desc *registers;
    uint8_t elf_class, linux_abi, isa_mode, control_kind, tracer_bits;
    uint8_t hardware_step;
    const struct xrt_probe_choice *probes;
    uint8_t probe_count;
};

/* Host-value snapshots, not kernel layouts or wire encodings. */
struct xrt_registers {
    struct xrt_abi_id abi;
    uint8_t absent_count, unknown_count;
    uint16_t absent_id[XRT_ABSENT_MAX];
    uint16_t unknown_id[XRT_ABSENT_MAX];
    union {
        struct xrt_x86_registers x86;
        struct xrt_arm_registers arm;
        struct xrt_m68k_registers m68k;
        struct xrt_loongarch_registers loongarch;
    } values;
};

struct xrt_probe_request {
    uint64_t address;
    uint8_t isa_mode;
    const uint8_t *bytes;
    size_t size;
};

struct xrt_probe_encoding {
    uint8_t isa_mode, width, alignment;
    uint8_t bytes[4];
};

struct xrt_control_request {
    uint8_t count;
    uint64_t value[2];
};

struct xrt_mutation_result {
    uint8_t issued;
    uint8_t confirmed;
};

struct xrt_reg_io {
    enum xrt_status (*read)(void *ctx, int32_t tid, const struct xrt_arch *arch,
                            unsigned char *raw, size_t size);
    enum xrt_status (*write)(void *ctx, int32_t tid, const struct xrt_arch *arch,
                             const unsigned char *raw, size_t size);
    void *ctx;
};

struct xrt_step_resources {
    uint8_t max_probes, hardware_step, software_probes;
};

const struct xrt_arch *xrt_arch_get(uint16_t machine);
const struct xrt_arch *xrt_arch_resolve(struct xrt_abi_id id);
const struct xrt_arch *xrt_arch_resolve_in(struct xrt_abi_id id,
                                           const struct xrt_arch *const *rows, size_t count);
const struct xrt_arch *xrt_arch_native(void);
struct xrt_abi_id xrt_arch_abi(const struct xrt_arch *arch);
enum xrt_status xrt_arch_validate(const struct xrt_arch *arch);
const struct xrt_register_desc *xrt_arch_register(uint16_t machine, const char *name,
                                                  size_t length);
const struct xrt_register_desc *xrt_arch_register_id(const struct xrt_arch *arch, uint16_t id);
const struct xrt_register_desc *xrt_arch_role(const struct xrt_arch *arch, uint8_t role);
const char *xrt_arch_dwarf_name(uint16_t machine, uint16_t number);
int xrt_arch_breakpoint_pc(uint16_t machine, uint64_t raw, uint64_t *pc);
int xrt_arch_caller_pc(uint16_t machine, uint64_t raw, uint64_t *pc);
int xrt_arch_breakpoint_valid(uint16_t machine, uint64_t address, size_t size);
enum xrt_status xrt_arch_probe_prepare(const struct xrt_arch *arch,
                                       const struct xrt_probe_request *request,
                                       struct xrt_probe_encoding *out);
enum xrt_status xrt_arch_step_resources(const struct xrt_arch *arch, uint8_t isa_mode,
                                        struct xrt_step_resources *out);

/* A NULL abi or out is XRT_INVALID_ARGUMENT. A pointer that does not resolve
 * is XRT_UNSUPPORTED_ARCHITECTURE. Failure leaves *out unchanged. */
enum xrt_status xrt_registers_decode(const struct xrt_abi_id *abi, const void *bytes, size_t size,
                                     struct xrt_registers *out);
enum xrt_status xrt_registers_decode_row(const struct xrt_arch *arch, const void *bytes,
                                         size_t size, struct xrt_registers *out);
enum xrt_status xrt_registers_validate(const struct xrt_arch *arch,
                                       const struct xrt_registers *regs);
enum xrt_status xrt_registers_dwarf(const struct xrt_registers *regs, uint64_t *out,
                                    uint8_t *present, size_t count);
enum xrt_availability xrt_registers_availability(const struct xrt_registers *regs,
                                                 const struct xrt_register_desc *desc);
enum xrt_availability xrt_registers_availability_row(const struct xrt_arch *arch,
                                                     const struct xrt_registers *regs,
                                                     const struct xrt_register_desc *desc);
enum xrt_status xrt_registers_mark_absent(struct xrt_registers *regs, uint16_t id);
enum xrt_status xrt_registers_mark_unknown(struct xrt_registers *regs, uint16_t id);
enum xrt_status xrt_registers_value(const struct xrt_registers *regs, const char *name,
                                    size_t length, uint64_t *out);
enum xrt_status xrt_registers_value_desc(const struct xrt_registers *regs,
                                         const struct xrt_register_desc *desc, uint64_t *out);
enum xrt_status xrt_registers_value_desc_row(const struct xrt_arch *arch,
                                             const struct xrt_registers *regs,
                                             const struct xrt_register_desc *desc, uint64_t *out);
enum xrt_status xrt_registers_value_dwarf(const struct xrt_registers *regs, uint16_t dwarf,
                                          uint64_t *out);
enum xrt_status xrt_registers_pc(const struct xrt_registers *regs, uint64_t *out);
enum xrt_status xrt_registers_role(const struct xrt_registers *regs, uint8_t role, uint64_t *out);

enum xrt_status xrt_register_admit(const struct xrt_register_desc *reg, uint64_t value);
enum xrt_status xrt_registers_poke(const struct xrt_arch *arch, void *raw, size_t size,
                                   const char *name, size_t length, uint64_t value);
enum xrt_status xrt_control_accept(const struct xrt_arch *arch, uint8_t count);
enum xrt_status xrt_control_poke(const struct xrt_arch *arch, void *raw, size_t size,
                                 const struct xrt_control_request *request);
enum xrt_status xrt_mutation_confirm_image(const unsigned char *expected,
                                           const unsigned char *actual, size_t size,
                                           const unsigned char *mutable_mask);
enum xrt_status xrt_registers_mutate(const struct xrt_arch *arch, struct xrt_reg_io *io,
                                     int32_t tid, const unsigned char *image,
                                     struct xrt_mutation_result *out);

enum xrt_status xrt_registers_read(int32_t tid, struct xrt_registers *out);
enum xrt_status xrt_register_write(int32_t tid, const char *name, size_t length, uint64_t value);
enum xrt_status xrt_register_write_result(int32_t tid, const char *name, size_t length,
                                          uint64_t value, struct xrt_reg_io *io,
                                          struct xrt_mutation_result *out);
enum xrt_status xrt_register_write_pc(int32_t tid, uint64_t pc);
enum xrt_status xrt_control_write(int32_t tid, const struct xrt_control_request *request,
                                  struct xrt_reg_io *io, struct xrt_mutation_result *out);

#endif
