#define _GNU_SOURCE 1
#include "xrt_arch.h"

#include <errno.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>

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
}

enum xrt_status xrt_register_admit(const struct xrt_register_desc *reg, uint64_t value)
{
    if (!reg)
        return XRT_INVALID_ARGUMENT;
    if (reg->access == XRT_REG_READ_ONLY)
        return XRT_REGISTER_NOT_WRITABLE;
    if (reg->width < 8 && value >> (reg->width * 8))
        return XRT_INVALID_ARGUMENT;
    return XRT_OK;
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

enum xrt_status xrt_registers_read(int32_t tid, struct xrt_registers *out)
{
    const struct xrt_arch *arch = xrt_arch_native();
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!out)
        return XRT_INVALID_ARGUMENT;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    const enum xrt_status status = ptrace_read(NULL, tid, arch, raw, arch->kernel_gpr_bytes);
    if (status != XRT_OK)
        return status;
    const struct xrt_abi_id abi = xrt_arch_abi(arch);
    return xrt_registers_decode(&abi, raw, arch->kernel_gpr_bytes, out);
}

enum xrt_status xrt_register_write_result(int32_t tid, const char *name, size_t length,
                                          uint64_t value, struct xrt_reg_io *io,
                                          struct xrt_mutation_result *out)
{
    if (out) {
        out->issued = 0;
        out->confirmed = 0;
    }
    const struct xrt_arch *arch = xrt_arch_native();
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
    const enum xrt_status read = io->read(io->ctx, tid, arch, raw, arch->kernel_gpr_bytes);
    if (read != XRT_OK)
        return read;
    const enum xrt_status poked =
        xrt_registers_poke(arch, raw, arch->kernel_gpr_bytes, name, length, value);
    if (poked != XRT_OK)
        return poked;
    return xrt_registers_mutate(arch, io, tid, raw, out);
}

enum xrt_status xrt_register_write(int32_t tid, const char *name, size_t length, uint64_t value)
{
    struct xrt_mutation_result result = {0};
    return xrt_register_write_result(tid, name, length, value, NULL, &result);
}

enum xrt_status xrt_register_write_pc(int32_t tid, uint64_t pc)
{
    const struct xrt_arch *arch = xrt_arch_native();
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (arch->control_kind != XRT_CONTROL_SINGLE_PC)
        return XRT_UNSUPPORTED_CONTROL;
    const struct xrt_register_desc *reg = xrt_arch_role(arch, XRT_ROLE_PC);
    if (!reg || !reg->name)
        return XRT_UNSUPPORTED_CONTROL;
    return xrt_register_write(tid, reg->name, strlen(reg->name), pc);
}

enum xrt_status xrt_control_write(int32_t tid, const struct xrt_control_request *request,
                                  struct xrt_reg_io *io, struct xrt_mutation_result *out)
{
    if (out) {
        out->issued = 0;
        out->confirmed = 0;
    }
    const struct xrt_arch *arch = xrt_arch_native();
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
    const enum xrt_status read = io->read(io->ctx, tid, arch, raw, arch->kernel_gpr_bytes);
    if (read != XRT_OK)
        return read;
    const enum xrt_status poked = xrt_control_poke(arch, raw, arch->kernel_gpr_bytes, request);
    if (poked != XRT_OK)
        return poked;
    return xrt_registers_mutate(arch, io, tid, raw, out);
}
