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

static enum xrt_status read_raw(int32_t tid, const struct xrt_arch *arch, unsigned char *raw)
{
#if defined(__m68k__)
    (void)arch;
    return ptrace(PTRACE_GETREGS, tid, (void *)0, raw) == -1 ? ptrace_failure() : XRT_OK;
#else
    struct iovec io = {.iov_base = raw, .iov_len = arch->kernel_gpr_bytes};
    if (ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)1, &io) == -1)
        return ptrace_failure();
    if (io.iov_len != arch->kernel_gpr_bytes)
        return XRT_UNEXPECTED_REGISTER_SIZE;
    return XRT_OK;
#endif
}

enum xrt_status xrt_registers_read(int32_t tid, struct xrt_registers *out)
{
    const struct xrt_arch *arch = xrt_arch_native();
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    if (!out)
        return XRT_INVALID_ARGUMENT;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    const enum xrt_status status = read_raw(tid, arch, raw);
    if (status != XRT_OK)
        return status;
    return xrt_registers_decode(arch->machine, raw, arch->kernel_gpr_bytes, out);
}

enum xrt_status xrt_register_write(int32_t tid, const char *name, size_t length, uint64_t value)
{
    const struct xrt_arch *arch = xrt_arch_native();
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    const struct xrt_register_desc *reg = xrt_arch_register(arch->machine, name, length);
    if (!reg)
        return XRT_UNKNOWN_REGISTER;
    if (reg->width < 8 && value >> (reg->width * 8))
        return XRT_INVALID_ARGUMENT;
    unsigned char raw[XRT_GPR_BYTES_MAX];
    const enum xrt_status status = read_raw(tid, arch, raw);
    if (status != XRT_OK)
        return status;
    for (size_t b = 0; b < reg->width; ++b)
        raw[reg->kernel_offset + b] =
            (unsigned char)(value >> (8 * (arch->little_endian ? b : reg->width - 1 - b)));
#if defined(__m68k__)
    return ptrace(PTRACE_SETREGS, tid, (void *)0, raw) == -1 ? ptrace_failure() : XRT_OK;
#else
    struct iovec io = {.iov_base = raw, .iov_len = arch->kernel_gpr_bytes};
    if (ptrace(PTRACE_SETREGSET, tid, (void *)(uintptr_t)1, &io) == -1)
        return ptrace_failure();
    return io.iov_len == arch->kernel_gpr_bytes ? XRT_OK : XRT_UNEXPECTED_REGISTER_SIZE;
#endif
}

enum xrt_status xrt_register_write_pc(int32_t tid, uint64_t pc)
{
    const struct xrt_arch *arch = xrt_arch_native();
    if (!arch)
        return XRT_UNSUPPORTED_ARCHITECTURE;
    const char *name = xrt_arch_dwarf_name(arch->machine, arch->pc);
    return xrt_register_write(tid, name, strlen(name), pc);
}
