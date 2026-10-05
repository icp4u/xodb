#ifndef XODB_RUNTIME_MEMORY_H
#define XODB_RUNTIME_MEMORY_H

#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

/* Internal Linux primitives, called by the ptrace owner with a stopped TID.
 * These read/write physical bytes; the target layer owns breakpoint overlays.
 * Addresses belong to the native target, never to the caller's buffers. */

/* count must be non-null and is set on every return. Empty operations succeed
 * without accessing the target. A short read is successful. A failed patch
 * may have changed a prefix; count reports exactly how many bytes changed.
 * Nonempty buffers must hold size bytes. No allocation crosses this API. */
enum xrt_status xrt_memory_read(int32_t tid, uint64_t address, void *dest, size_t size,
                                size_t *count);
enum xrt_status xrt_memory_patch(int32_t tid, uint64_t address, const void *bytes, size_t size,
                                 size_t *count);

#endif
