#ifndef XODB_PE_UNWIND_H
#define XODB_PE_UNWIND_H
#include <stddef.h>
#include <stdint.h>

/* Windows x64 register numbers, independent of the host and DWARF ABI.
 * Only known nonvolatile registers, RSP and RIP survive a successful step. */
struct xpu_context {
    uint64_t gpr[16], rip;
    unsigned char xmm[16][16];
    uint16_t gpr_known, xmm_known;
};
enum xpu_status {
    XPU_OK, XPU_MALFORMED, XPU_UNSUPPORTED_VERSION, XPU_UNSUPPORTED_OPCODE,
    XPU_UNSUPPORTED_CHAIN, XPU_UNSUPPORTED_EPILOG, XPU_MACHINE_FRAME,
    XPU_METADATA_MISSING, XPU_CODE_MISSING, XPU_STACK_MISSING,
    XPU_REGISTER_MISSING, XPU_LIMIT, XPU_NO_PROGRESS
};
enum xpu_method { XPU_UNWIND, XPU_LEAF, XPU_EPILOG };
struct xpu_function { uint32_t begin, end, unwind; };
struct xpu_source {
    void *context;
    uint32_t image_size;
    /* Exact, immutable/coherent reads: nonzero means success. The owner
     * retains richer transport/source-change errors. No host-pointer reads. */
    int (*metadata)(void *, uint32_t rva, void *, size_t);
    int (*code)(void *, uint32_t rva, void *, size_t);
    int (*stack)(void *, uint64_t address, void *, size_t);
    /* Optional table lookup: 1 and *out for the RUNTIME_FUNCTION covering
     * rva, 0 for none, -1 when the table cannot be consulted. It decides
     * whether a bare jmp out of a function is a tail call; without it that
     * one form is refused. */
    int (*function)(void *, uint32_t rva, struct xpu_function *out);
};
struct xpu_result {
    struct xpu_context caller;
    uint64_t cfa;
    enum xpu_method method;
};
/* The owner must prove control_rva belongs to executable PE code, and look
 * up the RUNTIME_FUNCTION at that exact PC (never PC-1). A null function
 * means a verified leaf. Dynamic function tables and unverified Wine/host
 * transitions must be refused by the owner. Output is zero on failure.
 * Version 1 only; at most 32 chained records, 64 epilog bytes, 16 KiB stack.
 * Exception handlers are validated as references but are never invoked. */
enum xpu_status xpu_step(const struct xpu_source *, const struct xpu_function *,
                         uint32_t control_rva, const struct xpu_context *,
                         struct xpu_result *);
/* Bounded metadata-only traversal of exactly the records a step can consult
 * for this function. (A bare tail jmp also reads the record header of the row
 * it lands on, which that row's own validation covers.) No code or stack
 * reads; useful when sealing a captured source. */
enum xpu_status xpu_validate(const struct xpu_source *, const struct xpu_function *);
#endif
