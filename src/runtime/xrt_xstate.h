#ifndef XODB_RUNTIME_XSTATE_H
#define XODB_RUNTIME_XSTATE_H
#include "xrt.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
enum xrt_xstate_source { XRT_XSTATE, XRT_FPREGS };
struct xrt_xstate {
    enum xrt_xstate_source source;
    uint64_t features, in_use;
    uint32_t vector_bytes, vector_count;
    uint8_t vectors[32][64], st[8][10];
    bool st_valid[8];
    uint64_t masks[8];
    uint32_t mxcsr;
    uint16_t control, status;
};
enum xrt_status xrt_xstate_read(int32_t tid, struct xrt_xstate *out);
/* FXSAVE's architectural 512-byte prefix is portable across core producers;
 * XSAVE component offsets require the producer's CPU layout, never the host's. */
enum xrt_status xrt_xstate_decode_legacy(const void *bytes, size_t size, struct xrt_xstate *out);
#endif
