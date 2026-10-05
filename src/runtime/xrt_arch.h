#ifndef XODB_RUNTIME_ARCH_H
#define XODB_RUNTIME_ARCH_H

#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

#define XRT_M68K 4
#define XRT_X86_64 62
#define XRT_AARCH64 183
#define XRT_DWARF_NONE UINT16_MAX
#define XRT_DWARF_REGISTER_COUNT 33
#define XRT_GPR_BYTES_MAX 272

/* name, supported DWARF number, Linux NT_PRSTATUS word index. These lists
 * define the public snapshots and all mapping tables, in existing GUI order.
 * Flags are visible/writable but are outside the current unwind register set. */
#define XRT_X86_REGISTERS(X)                                                                       \
    X(rip, 16, 16)                                                                                 \
    X(rsp, 7, 19)                                                                                  \
    X(rbp, 6, 4) X(rax, 0, 10) X(rbx, 3, 5) X(rcx, 2, 11) X(rdx, 1, 12) X(rsi, 4, 13)              \
        X(rdi, 5, 14) X(r8, 8, 9) X(r9, 9, 8) X(r10, 10, 7) X(r11, 11, 6) X(r12, 12, 3)            \
            X(r13, 13, 2) X(r14, 14, 1) X(r15, 15, 0) X(eflags, XRT_DWARF_NONE, 18)

#define XRT_ARM_REGISTERS(X)                                                                       \
    X(x0, 0, 0)                                                                                    \
    X(x1, 1, 1)                                                                                    \
    X(x2, 2, 2) X(x3, 3, 3) X(x4, 4, 4) X(x5, 5, 5) X(x6, 6, 6) X(x7, 7, 7) X(x8, 8, 8)            \
        X(x9, 9, 9) X(x10, 10, 10) X(x11, 11, 11) X(x12, 12, 12) X(x13, 13, 13) X(x14, 14, 14)     \
            X(x15, 15, 15) X(x16, 16, 16) X(x17, 17, 17) X(x18, 18, 18) X(x19, 19, 19)             \
                X(x20, 20, 20) X(x21, 21, 21) X(x22, 22, 22) X(x23, 23, 23) X(x24, 24, 24)         \
                    X(x25, 25, 25) X(x26, 26, 26) X(x27, 27, 27) X(x28, 28, 28) X(x29, 29, 29)     \
                        X(x30, 30, 30) X(sp, 31, 31) X(pc, 32, 32) X(pstate, XRT_DWARF_NONE, 33)

/* Linux m68k GETREGS uses 32-bit words, with SR at byte 70. */
#define XRT_M68K_REGISTERS(X)                                                                      \
    X(d0, 0, 56, 4)                                                                                \
    X(d1, 1, 0, 4)                                                                                 \
    X(d2, 2, 4, 4) X(d3, 3, 8, 4) X(d4, 4, 12, 4) X(d5, 5, 16, 4) X(d6, 6, 20, 4) X(d7, 7, 24, 4)  \
        X(a0, 8, 28, 4) X(a1, 9, 32, 4) X(a2, 10, 36, 4) X(a3, 11, 40, 4) X(a4, 12, 44, 4)         \
            X(a5, 13, 48, 4) X(a6, 14, 52, 4) X(usp, 15, 60, 4) X(pc, 24, 72, 4)                   \
                X(sr, XRT_DWARF_NONE, 70, 2)
#define XRT_M68K_FIELD(name, dwarf, offset, width) uint64_t name;
struct xrt_m68k_registers {
    XRT_M68K_REGISTERS(XRT_M68K_FIELD)
};
#undef XRT_M68K_FIELD

#define XRT_REGISTER_FIELD(name, dwarf, word) uint64_t name;
struct xrt_x86_registers {
    XRT_X86_REGISTERS(XRT_REGISTER_FIELD)
};
struct xrt_arm_registers {
    XRT_ARM_REGISTERS(XRT_REGISTER_FIELD)
};
#undef XRT_REGISTER_FIELD

/* Host-value snapshots, not kernel layouts or wire encodings. */
struct xrt_registers {
    uint16_t machine;
    union {
        struct xrt_x86_registers x86;
        struct xrt_arm_registers arm;
        struct xrt_m68k_registers m68k;
    } values;
};

struct xrt_register_desc {
    const char *name;
    uint16_t dwarf, snapshot_offset, kernel_offset;
    uint8_t width;
};

struct xrt_arch {
    uint16_t machine, kernel_gpr_bytes;
    uint8_t address_bits, little_endian;
    uint8_t register_count, dwarf_count, pc, sp, ra;
    uint8_t trap_size, trap_alignment, breakpoint_adjust, caller_adjust;
    uint8_t trap[4];
    const struct xrt_register_desc *registers;
};

/* Immutable descriptors work for either ISA on every host. Unknown machines
 * return NULL. The native backend is explicit about unsupported host ABIs. */
const struct xrt_arch *xrt_arch_get(uint16_t machine);
const struct xrt_arch *xrt_arch_native(void);
const struct xrt_register_desc *xrt_arch_register(uint16_t machine, const char *name,
                                                  size_t length);
const char *xrt_arch_dwarf_name(uint16_t machine, uint16_t number);
int xrt_arch_breakpoint_pc(uint16_t machine, uint64_t raw, uint64_t *pc);
int xrt_arch_caller_pc(uint16_t machine, uint64_t raw, uint64_t *pc);
int xrt_arch_breakpoint_valid(uint16_t machine, uint64_t address, size_t size);

/* Decode explicit target bytes, independent of host byte order. Exact kernel
 * regset size is required; output is unchanged on failure. */
enum xrt_status xrt_registers_decode(uint16_t machine, const void *bytes, size_t size,
                                     struct xrt_registers *out);
enum xrt_status xrt_registers_dwarf(const struct xrt_registers *regs, uint64_t *out, size_t count);

/* Linux ptrace-owner operations on a stopped native TID. A one-register write
 * rereads and preserves the entire kernel regset, including unexposed fields. */
enum xrt_status xrt_registers_read(int32_t tid, struct xrt_registers *out);
enum xrt_status xrt_register_write(int32_t tid, const char *name, size_t length, uint64_t value);
enum xrt_status xrt_register_write_pc(int32_t tid, uint64_t pc);

#endif
