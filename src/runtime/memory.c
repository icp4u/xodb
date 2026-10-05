#define _GNU_SOURCE 1
#include "xrt_memory.h"

#include <errno.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>

static enum xrt_status failure(enum xrt_status fallback)
{
    if (errno == EPERM || errno == EACCES)
        return XRT_PERMISSION_DENIED;
    if (errno == ESRCH)
        return XRT_PROCESS_GONE;
    return fallback;
}

static int valid_range(uint64_t address, size_t size)
{
    return address != 0 && address <= UINTPTR_MAX && size <= UINTPTR_MAX - address;
}

enum xrt_status xrt_memory_read(int32_t tid, uint64_t address, void *dest, size_t size,
                                size_t *count)
{
    *count = 0;
    if (size == 0)
        return XRT_OK;
    if (!dest)
        return XRT_INVALID_ARGUMENT;
    if (!valid_range(address, size))
        return XRT_INVALID_ADDRESS;
    struct iovec local = {.iov_base = dest, .iov_len = size};
    struct iovec remote = {.iov_base = (void *)(uintptr_t)address, .iov_len = size};
    ssize_t result;
    do {
        result = process_vm_readv(tid, &local, 1, &remote, 1, 0);
    } while (result < 0 && errno == EINTR);
    if (result < 0)
        return failure(XRT_MEMORY_UNREADABLE);
    *count = (size_t)result;
    return XRT_OK;
}

enum xrt_status xrt_memory_patch(int32_t tid, uint64_t address, const void *bytes, size_t size,
                                 size_t *count)
{
    *count = 0;
    if (size == 0)
        return XRT_OK;
    if (!bytes)
        return XRT_INVALID_ARGUMENT;
    if (!valid_range(address, size))
        return XRT_INVALID_ADDRESS;
    while (*count < size) {
        const uintptr_t current = (uintptr_t)address + *count;
        const size_t offset = current % sizeof(long);
        const uintptr_t aligned = current - offset;
        size_t chunk = sizeof(long) - offset;
        if (chunk > size - *count)
            chunk = size - *count;
        /* -1 is valid target data. PEEK reports failure through errno. */
        errno = 0;
        long word = ptrace(PTRACE_PEEKTEXT, tid, (void *)aligned, (void *)0);
        if (word == -1 && errno != 0)
            return failure(XRT_MEMORY_UNREADABLE);
        /* The ptrace word has native byte order and native long width.
         * Editing its object bytes works on both 32/64-bit and either endian. */
        memcpy((unsigned char *)&word + offset, (const unsigned char *)bytes + *count, chunk);
        if (ptrace(PTRACE_POKETEXT, tid, (void *)aligned, (void *)(uintptr_t)(unsigned long)word) ==
            -1)
            return failure(XRT_PTRACE_FAILED);
        *count += chunk;
    }
    return XRT_OK;
}
