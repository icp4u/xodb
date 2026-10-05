#define _GNU_SOURCE 1
#include "xrt_xstate.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/uio.h>
#if defined(__x86_64__) && !defined(__ILP32__)
#include <cpuid.h>
#endif

static uint64_t little(const uint8_t *bytes, unsigned n)
{
    uint64_t out = 0;
    for (unsigned i = 0; i < n; ++i)
        out |= (uint64_t)bytes[i] << (i * 8);
    return out;
}
enum xrt_status xrt_xstate_decode_legacy(const void *bytes, size_t size, struct xrt_xstate *out)
{
    if (!bytes || !out)
        return XRT_INVALID_ARGUMENT;
    if (size < 512)
        return XRT_INVALID_XSTATE_SIZE;
    const uint8_t *raw = bytes;
    struct xrt_xstate result = {.source = XRT_FPREGS,
                                .features = 3,
                                .in_use = 3,
                                .vector_bytes = 16,
                                .vector_count = 16,
                                .control = (uint16_t)little(raw, 2),
                                .status = (uint16_t)little(raw + 2, 2),
                                .mxcsr = (uint32_t)little(raw + 24, 4)};
    const unsigned top = (result.status >> 11) & 7;
    for (unsigned i = 0; i < 8; ++i) {
        memcpy(result.st[i], raw + 32 + i * 16, 10);
        result.st_valid[i] = (raw[4] & (1U << ((top + i) % 8))) != 0;
    }
    for (unsigned i = 0; i < 16; ++i)
        memcpy(result.vectors[i], raw + 160 + i * 16, 16);
    *out = result;
    return XRT_OK;
}
#if defined(__x86_64__) && !defined(__ILP32__)
static uint64_t features(void)
{
    unsigned a, b, c, d;
    if (!__get_cpuid(1, &a, &b, &c, &d) || !(c & bit_OSXSAVE))
        return 3;
    unsigned lo, hi;
    __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
    return ((uint64_t)hi << 32) | lo;
}
static const uint8_t *component(const uint8_t *raw, size_t length, unsigned number, size_t needed)
{
    unsigned size, offset, c, d;
    if (!__get_cpuid_count(0x0d, number, &size, &offset, &c, &d) || size < needed || offset < 576 ||
        offset > length || needed > length - offset)
        return NULL;
    return raw + offset;
}
static enum xrt_status decode(const uint8_t *raw, size_t length, struct xrt_xstate *out)
{
    if (length < 576 || little(raw + 520, 8))
        return XRT_INVALID_XSTATE_HEADER;
    struct xrt_xstate state;
    const enum xrt_status status = xrt_xstate_decode_legacy(raw, length, &state);
    if (status != XRT_OK)
        return status;
    state.source = XRT_XSTATE;
    state.features = features();
    state.in_use = little(raw + 512, 8);
    if (state.features & 4) {
        const uint8_t *upper = component(raw, length, 2, 256);
        if (!upper)
            return XRT_XSTATE_COMPONENT_UNAVAILABLE;
        for (size_t i = 0; i < 16; ++i)
            memcpy(state.vectors[i] + 16, upper + i * 16, 16);
        state.vector_bytes = 32;
    }
    if ((state.features & 0xe0) == 0xe0) {
        const uint8_t *masks = component(raw, length, 5, 64),
                      *upper = component(raw, length, 6, 512),
                      *high = component(raw, length, 7, 1024);
        if (!masks || !upper || !high)
            return XRT_XSTATE_COMPONENT_UNAVAILABLE;
        for (size_t i = 0; i < 8; ++i)
            state.masks[i] = little(masks + i * 8, 8);
        for (size_t i = 0; i < 16; ++i) {
            memcpy(state.vectors[i] + 32, upper + i * 32, 32);
            memcpy(state.vectors[i + 16], high + i * 64, 64);
        }
        state.vector_bytes = 64;
        state.vector_count = 32;
    }
    *out = state;
    return XRT_OK;
}
#endif
enum xrt_status xrt_xstate_read(int32_t tid, struct xrt_xstate *out)
{
    if (!out || tid <= 0)
        return XRT_INVALID_ARGUMENT;
#if defined(__x86_64__) && !defined(__ILP32__)
    uint8_t *raw = malloc(65536);
    if (!raw)
        return XRT_OUT_OF_MEMORY;
    struct iovec io = {.iov_base = raw, .iov_len = 65536};
    bool legacy = false;
    enum xrt_status result = XRT_OK;
    if (ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)0x202, &io) < 0) {
        if (errno != EINVAL && errno != EIO && errno != ENODEV)
            result = XRT_EXTENDED_REGISTERS_UNAVAILABLE;
        else {
            io.iov_len = 512;
            legacy = true;
            if (ptrace(PTRACE_GETREGSET, tid, (void *)(uintptr_t)2, &io) < 0)
                result = XRT_EXTENDED_REGISTERS_UNAVAILABLE;
        }
    }
    if (result == XRT_OK) {
        if (io.iov_len < 512 || io.iov_len > 65536)
            result = XRT_INVALID_XSTATE_SIZE;
        else
            result = legacy ? xrt_xstate_decode_legacy(raw, io.iov_len, out)
                            : decode(raw, io.iov_len, out);
    }
    free(raw);
    return result;
#else
    return XRT_EXTENDED_REGISTERS_UNSUPPORTED_ARCHITECTURE;
#endif
}
