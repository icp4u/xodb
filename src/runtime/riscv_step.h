#ifndef XODB_RUNTIME_RISCV_STEP_H
#define XODB_RUNTIME_RISCV_STEP_H
#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

/* Successors to plant for one RISC-V software step. emulate means the
 * instruction is an unconditional direct jump to itself: the step is complete
 * and the PC stays put, so no probe is planted. */
struct xrt_riscv_plan {
    uint8_t count;
    uint8_t emulate;
    uint64_t pc[2];
};

/* bytes are the little-endian instruction stream at pc. gpr[0] is ignored:
 * x0 is architectural zero and is not in the kernel register image. known
 * bit i (1..31) means gpr[i] is valid. At most 17 instructions are examined;
 * a longer lr/sc window is refused. */
enum xrt_status xrt_riscv_plan(uint64_t pc, const uint8_t *bytes, size_t size,
                               const uint64_t gpr[32], uint32_t known, struct xrt_riscv_plan *out);
#endif
