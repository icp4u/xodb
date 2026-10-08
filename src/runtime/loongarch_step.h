#ifndef XODB_RUNTIME_LOONGARCH_STEP_H
#define XODB_RUNTIME_LOONGARCH_STEP_H
#include "xrt.h"
#include <stdint.h>

/* Successors to plant for one LoongArch software step. emulate means the
 * instruction is an unconditional branch to itself: the step is complete and
 * the PC stays put, so no probe is planted. */
struct xrt_loongarch_plan {
    uint8_t count;
    uint8_t emulate;
    uint64_t pc[2];
};

/* gpr[0] is ignored. A jirl base of r0 is architectural zero, never the
 * kernel restart word. known bit i (1..31) means gpr[i] is valid.
 * forward holds the little-endian instruction words at pc+4, pc+8, ...
 * and may be NULL when forward_count is 0. forward_count is at most 16. */
enum xrt_status xrt_loongarch_plan(uint64_t pc, uint32_t insn, const uint64_t gpr[32],
                                   uint32_t known, const uint32_t *forward, uint8_t forward_count,
                                   struct xrt_loongarch_plan *out);
#endif
