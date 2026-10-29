#define _GNU_SOURCE 1
#include "xrt_arch.h"

#include <errno.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#if defined(__x86_64__) && !defined(__ILP32__)
#include <asm/ldt.h>
#include <sys/user.h>
#endif

static enum xrt_status ptrace_failure(void)
{
    if (errno == EPERM || errno == EACCES)
        return XRT_PERMISSION_DENIED;
    if (errno == ESRCH)
        return XRT_PROCESS_GONE;
    return XRT_PTRACE_FAILED;
}

static enum xrt_status ptrace_read(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                   unsigned char *raw, size_t size)
{
    (void)ctx;
    if (!arch || !raw || size != arch->kernel_gpr_bytes)
        return XRT_INVALID_ARGUMENT;
#if defined(__m68k__)
    if (arch->machine == XRT_M68K)
        return ptrace(PTRACE_GETREGS, tid, (void *)0, raw) == -1 ? ptrace_failure() : XRT_OK;
#endif
#if defined(__x86_64__) && !defined(__ILP32__)
    /* Compat tasks answer NT_PRSTATUS with a 68-byte i386 regset. The 64-bit
     * tracer's GETREGS image is the 216-byte user_regs_struct this row maps. */
    if (arch->machine == XRT_I386) {
        struct user_regs_struct regs;
        if (size != sizeof(regs))
            return XRT_UNEXPECTED_REGISTER_SIZE;
        memset(&regs, 0, sizeof(regs));
        if (ptrace(PTRACE_GETREGS, tid, (void *)0, &regs) == -1)
            return ptrace_failure();
        memcpy(raw, &regs, size);
        return XRT_OK;
    }
#endif
    /* LoongArch fills 280 of its 360 NT_PRSTATUS bytes and still reports
       360; the reserved tail is whatever the buffer held. */
    memset(raw, 0, size);
    struct iovec io = {.iov_base = raw, .iov_len = size};
    if (ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)1, &io) == -1)
        return ptrace_failure();
    return io.iov_len == size ? XRT_OK : XRT_UNEXPECTED_REGISTER_SIZE;
}

static enum xrt_status ptrace_write(void *ctx, int32_t tid, const struct xrt_arch *arch,
                                    const unsigned char *raw, size_t size)
{
    (void)ctx;
    if (!arch || !raw || size != arch->kernel_gpr_bytes)
        return XRT_INVALID_ARGUMENT;
#if defined(__m68k__)
    if (arch->machine == XRT_M68K)
        return ptrace(PTRACE_SETREGS, tid, (void *)0, (void *)raw) == -1 ? ptrace_failure()
                                                                         : XRT_OK;
#endif
#if defined(__x86_64__) && !defined(__ILP32__)
    if (arch->machine == XRT_I386) {
        struct user_regs_struct regs;
        if (size != sizeof(regs))
            return XRT_UNEXPECTED_REGISTER_SIZE;
        memcpy(&regs, raw, size);
        if (ptrace(PTRACE_SETREGS, tid, (void *)0, &regs) == -1)
            return ptrace_failure();
        return XRT_OK;
    }
#endif
    struct iovec io = {.iov_base = (void *)raw, .iov_len = size};
    if (ptrace(PTRACE_SETREGSET, tid, (void *)(uintptr_t)1, &io) == -1)
        return ptrace_failure();
    return io.iov_len == size ? XRT_OK : XRT_UNEXPECTED_REGISTER_SIZE;
}

static void store_field(const struct xrt_arch *arch, unsigned char *raw,
                        const struct xrt_register_desc *reg, uint64_t value)
{
    for (uint8_t b = 0; b < reg->width; ++b)
        raw[reg->kernel_offset + b] =
            (unsigned char)(value >> (8 * (arch->little_endian ? b : reg->width - 1 - b)));
    /* SETREGS keeps a dirty high half. A 32-bit write must clear it. */
    if (arch->machine == XRT_I386 && reg->width < 8 &&
        (size_t)reg->kernel_offset + 8 <= arch->kernel_gpr_bytes)
        memset(raw + reg->kernel_offset + reg->width, 0, (size_t)(8 - reg->width));
}

enum xrt_status xrt_registers_poke(const struct xrt_arch *arch, void *raw, size_t size,
                                   const char *name, size_t length, uint64_t value)
{
    if (!arch || !raw || !name)
        return XRT_INVALID_ARGUMENT;
    if (size != arch->kernel_gpr_bytes)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    const struct xrt_register_desc *reg = NULL;
    for (uint8_t i = 0; i < arch->register_count; ++i) {
        const struct xrt_register_desc *item = &arch->registers[i];
        if (strlen(item->name) == length && memcmp(item->name, name, length) == 0) {
            reg = item;
            break;
        }
    }
    if (!reg)
        return XRT_UNKNOWN_REGISTER;
    const enum xrt_status admitted = xrt_register_admit(reg, value);
    if (admitted != XRT_OK)
        return admitted;
    store_field(arch, raw, reg, value);
    return XRT_OK;
}

enum xrt_status xrt_control_accept(const struct xrt_arch *arch, uint8_t count)
{
    if (!arch || !count || count > 2)
        return XRT_INVALID_ARGUMENT;
    if (arch->control_kind == XRT_CONTROL_QUEUE)
        return XRT_UNSUPPORTED_CONTROL;
    if (arch->control_kind == XRT_CONTROL_SINGLE_PC && count != 1)
        return XRT_UNSUPPORTED_CONTROL;
    if (arch->control_kind != XRT_CONTROL_SINGLE_PC && arch->control_kind != XRT_CONTROL_PC_NEXT)
        return XRT_UNSUPPORTED_CONTROL;
    return XRT_OK;
}

enum xrt_status xrt_control_poke(const struct xrt_arch *arch, void *raw, size_t size,
                                 const struct xrt_control_request *request)
{
    if (!request)
        return XRT_INVALID_ARGUMENT;
    const enum xrt_status accepted = xrt_control_accept(arch, request->count);
    if (accepted != XRT_OK)
        return accepted;
    const struct xrt_register_desc *pc = xrt_arch_role(arch, XRT_ROLE_PC);
    if (!pc)
        return XRT_UNSUPPORTED_CONTROL;
    const enum xrt_status pc_status = xrt_register_admit(pc, request->value[0]);
    if (pc_status != XRT_OK)
        return pc_status;
    if (size != arch->kernel_gpr_bytes || !raw)
        return size != arch->kernel_gpr_bytes ? XRT_UNEXPECTED_REGISTER_SIZE : XRT_INVALID_ARGUMENT;
    store_field(arch, raw, pc, request->value[0]);
    if (request->count == 2) {
        const struct xrt_register_desc *next = xrt_arch_role(arch, XRT_ROLE_NEXT_PC);
        if (!next)
            return XRT_UNSUPPORTED_CONTROL;
        const enum xrt_status next_status = xrt_register_admit(next, request->value[1]);
        if (next_status != XRT_OK)
            return next_status;
        store_field(arch, raw, next, request->value[1]);
    }
    return XRT_OK;
}

enum xrt_status xrt_mutation_confirm_image(const unsigned char *expected,
                                           const unsigned char *actual, size_t size,
                                           const unsigned char *mutable_mask)
{
    if (!expected || !actual || !size || size > XRT_GPR_BYTES_MAX)
        return XRT_INVALID_ARGUMENT;
    for (size_t i = 0; i < size; ++i) {
        if (mutable_mask && mutable_mask[i])
            continue;
        if (expected[i] != actual[i])
            return XRT_PARTIAL_REGISTER_WRITE;
    }
    return XRT_OK;
}

enum xrt_status xrt_registers_mutate(const struct xrt_arch *arch, struct xrt_reg_io *io,
                                     int32_t tid, const unsigned char *image,
                                     struct xrt_mutation_result *out)
{
    if (out) {
        out->issued = 0;
        out->confirmed = 0;
    }
    if (!arch || !io || !io->read || !io->write || !image || !out)
        return XRT_INVALID_ARGUMENT;
    if (!arch->kernel_gpr_bytes || arch->kernel_gpr_bytes > XRT_GPR_BYTES_MAX)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    const enum xrt_status written =
        io->write(io->ctx, tid, arch, image, arch->kernel_gpr_bytes);
    out->issued = 1;
    if (written != XRT_OK)
        return written;
    unsigned char got[XRT_GPR_BYTES_MAX];
    memset(got, 0, sizeof(got));
    const enum xrt_status read = io->read(io->ctx, tid, arch, got, arch->kernel_gpr_bytes);
    if (read != XRT_OK)
        return read;
    const enum xrt_status confirmed =
        xrt_mutation_confirm_image(image, got, arch->kernel_gpr_bytes, NULL);
    if (confirmed != XRT_OK)
        return confirmed;
    out->confirmed = 1;
    return XRT_OK;
}

#if defined(__x86_64__) && !defined(__ILP32__)
/* 32-bit TLS lives in the GDT thread area selected by gs. fs_base is not it.
 * A failed lookup stays absent so the kernel's gs_base word is not shown. */
static void i386_gs_base(int32_t tid, struct xrt_registers *regs)
{
    const struct xrt_arch *arch = xrt_arch_get(XRT_I386);
    const struct xrt_register_desc *gs = xrt_arch_register(XRT_I386, "gs", 2);
    const struct xrt_register_desc *base = xrt_arch_register(XRT_I386, "gs_base", 7);
    uint64_t selector = 0;
    if (!arch || !gs || !base || xrt_registers_value_desc_row(arch, regs, gs, &selector) != XRT_OK) {
        if (base)
            xrt_registers_mark_absent(regs, base->id);
        return;
    }
    struct user_desc desc;
    memset(&desc, 0, sizeof(desc));
    const unsigned idx = (unsigned)((selector & 0xffffu) >> 3);
    if (ptrace(PTRACE_GET_THREAD_AREA, tid, (void *)(uintptr_t)idx, &desc) != 0) {
        xrt_registers_mark_absent(regs, base->id);
        return;
    }
    const uint64_t value = desc.base_addr;
    memcpy((unsigned char *)&regs->values + base->snapshot_offset, &value, sizeof(value));
}
#endif

enum xrt_status xrt_registers_read_for(const struct xrt_arch *arch, int32_t tid,
                                       struct xrt_registers *out)
{
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!out)
        return XRT_INVALID_ARGUMENT;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    memset(raw, 0, sizeof(raw));
    const enum xrt_status status = ptrace_read(NULL, tid, arch, raw, arch->kernel_gpr_bytes);
    if (status != XRT_OK)
        return status;
    const struct xrt_abi_id abi = xrt_arch_abi(arch);
    const enum xrt_status decoded = xrt_registers_decode(&abi, raw, arch->kernel_gpr_bytes, out);
    if (decoded != XRT_OK)
        return decoded;
#if defined(__x86_64__) && !defined(__ILP32__)
    if (arch->machine == XRT_I386)
        i386_gs_base(tid, out);
#endif
    return XRT_OK;
}

enum xrt_status xrt_registers_read(int32_t tid, struct xrt_registers *out)
{
    return xrt_registers_read_for(xrt_arch_native(), tid, out);
}

enum xrt_status xrt_register_write_result_for(const struct xrt_arch *arch, int32_t tid,
                                              const char *name, size_t length, uint64_t value,
                                              struct xrt_reg_io *io,
                                              struct xrt_mutation_result *out)
{
    if (out) {
        out->issued = 0;
        out->confirmed = 0;
    }
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!name || !out)
        return XRT_INVALID_ARGUMENT;
    const struct xrt_register_desc *reg = xrt_arch_register(arch->machine, name, length);
    if (!reg)
        return XRT_UNKNOWN_REGISTER;
    const enum xrt_status admitted = xrt_register_admit(reg, value);
    if (admitted != XRT_OK)
        return admitted;
    struct xrt_reg_io local = {.read = ptrace_read, .write = ptrace_write, .ctx = NULL};
    if (!io)
        io = &local;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    memset(raw, 0, sizeof(raw));
    const enum xrt_status read = io->read(io->ctx, tid, arch, raw, arch->kernel_gpr_bytes);
    if (read != XRT_OK)
        return read;
    const enum xrt_status poked =
        xrt_registers_poke(arch, raw, arch->kernel_gpr_bytes, name, length, value);
    if (poked != XRT_OK)
        return poked;
    return xrt_registers_mutate(arch, io, tid, raw, out);
}

enum xrt_status xrt_register_write_result(int32_t tid, const char *name, size_t length,
                                          uint64_t value, struct xrt_reg_io *io,
                                          struct xrt_mutation_result *out)
{
    return xrt_register_write_result_for(xrt_arch_native(), tid, name, length, value, io, out);
}

enum xrt_status xrt_register_write(int32_t tid, const char *name, size_t length, uint64_t value)
{
    struct xrt_mutation_result result = {0};
    return xrt_register_write_result(tid, name, length, value, NULL, &result);
}

enum xrt_status xrt_register_write_pc_for(const struct xrt_arch *arch, int32_t tid, uint64_t pc)
{
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (arch->control_kind != XRT_CONTROL_SINGLE_PC)
        return XRT_UNSUPPORTED_CONTROL;
    const struct xrt_register_desc *reg = xrt_arch_role(arch, XRT_ROLE_PC);
    if (!reg || !reg->name)
        return XRT_UNSUPPORTED_CONTROL;
    return xrt_register_write_result_for(arch, tid, reg->name, strlen(reg->name), pc, NULL,
                                         &(struct xrt_mutation_result){0});
}

enum xrt_status xrt_register_write_pc(int32_t tid, uint64_t pc)
{
    return xrt_register_write_pc_for(xrt_arch_native(), tid, pc);
}

enum xrt_status xrt_control_write_for(const struct xrt_arch *arch, int32_t tid,
                                      const struct xrt_control_request *request,
                                      struct xrt_reg_io *io, struct xrt_mutation_result *out)
{
    if (out) {
        out->issued = 0;
        out->confirmed = 0;
    }
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!request || !out)
        return XRT_INVALID_ARGUMENT;
    const enum xrt_status accepted = xrt_control_accept(arch, request->count);
    if (accepted != XRT_OK)
        return accepted;
    struct xrt_reg_io local = {.read = ptrace_read, .write = ptrace_write, .ctx = NULL};
    if (!io)
        io = &local;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    memset(raw, 0, sizeof(raw));
    const enum xrt_status read = io->read(io->ctx, tid, arch, raw, arch->kernel_gpr_bytes);
    if (read != XRT_OK)
        return read;
    const enum xrt_status poked = xrt_control_poke(arch, raw, arch->kernel_gpr_bytes, request);
    if (poked != XRT_OK)
        return poked;
    return xrt_registers_mutate(arch, io, tid, raw, out);
}

enum xrt_status xrt_control_write(int32_t tid, const struct xrt_control_request *request,
                                  struct xrt_reg_io *io, struct xrt_mutation_result *out)
{
    return xrt_control_write_for(xrt_arch_native(), tid, request, io, out);
}
