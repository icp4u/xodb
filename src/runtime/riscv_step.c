#include "riscv_step.h"

/* RV64 with the C extension. Length is in the low bits: not 11 is 16-bit,
 * 11 but not 111xx is 32-bit, and anything longer is refused. Branch and
 * jump immediates are byte offsets. lr/sc of one width are one step. */

enum rk {
    RK_ORD,
    RK_COND,
    RK_JUMP,
    RK_CALL,
    RK_INDIRECT,
    RK_ECALL,
    RK_REFUSE
};

struct dec {
    uint8_t len;
    enum rk kind;
    uint8_t rs1;
    uint8_t lr;
    uint8_t sc;
    int64_t disp;
};

/* The instruction at pc plus at most 16 more. */
enum { RISCV_STEP_INSNS = 17 };

static int64_t sext(uint32_t value, unsigned bits)
{
    const uint32_t field = value & ((1u << bits) - 1u);
    if (field & (1u << (bits - 1)))
        return (int64_t)field - (int64_t)(1u << bits);
    return (int64_t)field;
}
static uint16_t load16(const uint8_t *b)
{
    return (uint16_t)b[0] | (uint16_t)((uint16_t)b[1] << 8);
}
static uint32_t load32(const uint8_t *b)
{
    return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24);
}
static int64_t b_imm(uint32_t insn)
{
    const uint32_t imm = ((insn >> 31) & 1u) << 12 | ((insn >> 7) & 1u) << 11 |
                         ((insn >> 25) & 0x3fu) << 5 | ((insn >> 8) & 0xfu) << 1;
    return sext(imm, 13);
}
static int64_t j_imm(uint32_t insn)
{
    const uint32_t imm = ((insn >> 31) & 1u) << 20 | ((insn >> 12) & 0xffu) << 12 |
                         ((insn >> 20) & 1u) << 11 | ((insn >> 21) & 0x3ffu) << 1;
    return sext(imm, 21);
}
static int64_t cj_imm(uint16_t insn)
{
    const uint32_t u = insn;
    const uint32_t imm = ((u >> 12) & 1u) << 11 | ((u >> 8) & 1u) << 10 | ((u >> 9) & 3u) << 8 |
                         ((u >> 6) & 1u) << 7 | ((u >> 7) & 1u) << 6 | ((u >> 2) & 1u) << 5 |
                         ((u >> 11) & 1u) << 4 | ((u >> 3) & 7u) << 1;
    return sext(imm, 12);
}
static int64_t cb_imm(uint16_t insn)
{
    const uint32_t u = insn;
    const uint32_t imm = ((u >> 12) & 1u) << 8 | ((u >> 5) & 3u) << 6 | ((u >> 2) & 1u) << 5 |
                         ((u >> 10) & 3u) << 3 | ((u >> 3) & 3u) << 1;
    return sext(imm, 9);
}

/* 0 decoded, 1 truncated, -1 not a 16- or 32-bit instruction. */
static int decode16(uint16_t insn, struct dec *d)
{
    const unsigned op = insn & 3u;
    const unsigned f3 = (insn >> 13) & 7u;
    d->len = 2;
    d->kind = RK_ORD;
    d->rs1 = 0;
    d->lr = 0;
    d->sc = 0;
    d->disp = 0;
    if (op == 1 && f3 == 5) {
        /* c.j. On RV64 the funct3=001 encoding is c.addiw, not c.jal. */
        d->kind = RK_JUMP;
        d->disp = cj_imm(insn);
        return 0;
    }
    if (op == 1 && (f3 == 6 || f3 == 7)) {
        d->kind = RK_COND;
        d->disp = cb_imm(insn);
        return 0;
    }
    if (op == 2 && f3 == 4) {
        const unsigned rs1 = (insn >> 7) & 31u;
        const unsigned rs2 = (insn >> 2) & 31u;
        if (rs2 == 0) {
            /* c.ebreak is funct4=1001, rs1=0. c.jr x0 is reserved. */
            if (rs1 == 0) {
                d->kind = RK_REFUSE;
                return 0;
            }
            d->kind = RK_INDIRECT;
            d->rs1 = (uint8_t)rs1;
            return 0;
        }
    }
    return 0;
}
static int decode32(uint32_t insn, struct dec *d)
{
    const unsigned opcode = insn & 0x7fu;
    const unsigned funct3 = (insn >> 12) & 7u;
    const unsigned rd = (insn >> 7) & 31u;
    const unsigned rs1 = (insn >> 15) & 31u;
    const unsigned rs2 = (insn >> 20) & 31u;
    d->len = 4;
    d->kind = RK_ORD;
    d->rs1 = 0;
    d->lr = 0;
    d->sc = 0;
    d->disp = 0;
    if (opcode == 0x63u) {
        if (funct3 == 2 || funct3 == 3) {
            d->kind = RK_REFUSE;
            return 0;
        }
        d->kind = RK_COND;
        d->disp = b_imm(insn);
        return 0;
    }
    if (opcode == 0x6fu) {
        d->kind = rd == 0 ? RK_JUMP : RK_CALL;
        d->disp = j_imm(insn);
        return 0;
    }
    if (opcode == 0x67u) {
        if (funct3 != 0) {
            d->kind = RK_REFUSE;
            return 0;
        }
        d->kind = RK_INDIRECT;
        d->rs1 = (uint8_t)rs1;
        d->disp = sext((insn >> 20) & 0xfffu, 12);
        return 0;
    }
    if (opcode == 0x73u && funct3 == 0) {
        const unsigned imm12 = (insn >> 20) & 0xfffu;
        if (imm12 == 0 && rd == 0 && rs1 == 0) {
            d->kind = RK_ECALL;
            return 0;
        }
        /* ebreak, uret, sret, mret do not resume at pc+4. */
        if (imm12 == 1 || imm12 == 0x002u || imm12 == 0x102u || imm12 == 0x302u) {
            d->kind = RK_REFUSE;
            return 0;
        }
    }
    if (opcode == 0x2fu) {
        const unsigned funct5 = (insn >> 27) & 31u;
        const unsigned width = funct3 == 2 ? 4u : funct3 == 3 ? 8u : 0u;
        if (funct5 == 0x02u) {
            if (!width || rs2 != 0) {
                d->kind = RK_REFUSE;
                return 0;
            }
            d->lr = (uint8_t)width;
            return 0;
        }
        if (funct5 == 0x03u) {
            if (!width) {
                d->kind = RK_REFUSE;
                return 0;
            }
            d->sc = (uint8_t)width;
            return 0;
        }
    }
    return 0;
}
static int decode_insn(const uint8_t *b, size_t avail, struct dec *d)
{
    if (avail < 2)
        return 1;
    if ((b[0] & 0x3u) != 0x3u)
        return decode16(load16(b), d);
    /* inst[4:2] == 111 is 48-bit or longer. The length is not guessed. */
    if ((b[0] & 0x1cu) == 0x1cu)
        return -1;
    if (avail < 4)
        return 1;
    return decode32(load32(b), d);
}

static enum xrt_status add_pc(struct xrt_riscv_plan *out, uint64_t step_pc, uint64_t dest)
{
    if (dest & 1u)
        return XRT_UNSUPPORTED_CONTROL;
    if (dest == step_pc)
        return XRT_OK;
    for (uint8_t i = 0; i < out->count; ++i)
        if (out->pc[i] == dest)
            return XRT_OK;
    if (out->count >= 2)
        return XRT_UNSUPPORTED_CONTROL;
    out->pc[out->count++] = dest;
    return XRT_OK;
}
static enum xrt_status pc_add(uint64_t here, int64_t disp, uint64_t *dest)
{
    if (disp >= 0) {
        if ((uint64_t)disp > UINT64_MAX - here)
            return XRT_INVALID_ADDRESS;
        *dest = here + (uint64_t)disp;
        return XRT_OK;
    }
    const uint64_t mag = (uint64_t)(-disp);
    if (mag > here)
        return XRT_INVALID_ADDRESS;
    *dest = here - mag;
    return XRT_OK;
}
static enum xrt_status indirect(const struct dec *d, const uint64_t gpr[32], uint32_t known,
                                uint64_t *dest)
{
    uint64_t base = 0;
    if (d->rs1 != 0) {
        if ((known & (1u << d->rs1)) == 0)
            return XRT_REGISTER_UNAVAILABLE;
        base = gpr[d->rs1];
    }
    uint64_t sum = 0;
    const enum xrt_status status = pc_add(base, d->disp, &sum);
    if (status != XRT_OK)
        return status;
    *dest = sum & ~UINT64_C(1);
    return XRT_OK;
}
static int outside(uint64_t dest, uint64_t window, uint64_t window_end)
{
    return dest < window || dest >= window_end;
}

static enum xrt_status plan_one(uint64_t pc, const struct dec *d, const uint64_t gpr[32],
                                uint32_t known, struct xrt_riscv_plan *out)
{
    if (d->kind == RK_REFUSE)
        return XRT_UNSUPPORTED_CONTROL;
    if (d->kind == RK_ORD || d->kind == RK_ECALL) {
        /* a7 is x17. Refuse only when that register is known. */
        if (d->kind == RK_ECALL && (known & (1u << 17)) && gpr[17] == 139)
            return XRT_UNSUPPORTED_CONTROL;
        if (pc > UINT64_MAX - d->len)
            return XRT_INVALID_ADDRESS;
        out->count = 1;
        out->pc[0] = pc + d->len;
        return XRT_OK;
    }
    if (d->kind == RK_COND) {
        uint64_t taken = 0;
        const enum xrt_status decoded = pc_add(pc, d->disp, &taken);
        if (decoded != XRT_OK)
            return decoded;
        if (pc > UINT64_MAX - d->len)
            return XRT_INVALID_ADDRESS;
        const enum xrt_status taken_status = add_pc(out, pc, taken);
        if (taken_status != XRT_OK)
            return taken_status;
        const enum xrt_status fall_status = add_pc(out, pc, pc + d->len);
        if (fall_status != XRT_OK)
            return fall_status;
        return out->count == 0 ? XRT_UNSUPPORTED_CONTROL : XRT_OK;
    }
    uint64_t dest = 0;
    if (d->kind == RK_INDIRECT) {
        const enum xrt_status status = indirect(d, gpr, known, &dest);
        if (status != XRT_OK)
            return status;
    } else {
        const enum xrt_status status = pc_add(pc, d->disp, &dest);
        if (status != XRT_OK)
            return status;
    }
    if (dest & 1u)
        return XRT_UNSUPPORTED_CONTROL;
    if (dest == pc) {
        if (d->kind == RK_JUMP) {
            out->emulate = 1;
            return XRT_OK;
        }
        return XRT_UNSUPPORTED_CONTROL;
    }
    out->count = 1;
    out->pc[0] = dest;
    return XRT_OK;
}

static enum xrt_status plan_atomic(uint64_t pc, const uint8_t *bytes, size_t size,
                                   const struct dec *first, const uint64_t gpr[32], uint32_t known,
                                   struct xrt_riscv_plan *out)
{
    struct slot {
        struct dec d;
        uint64_t here;
    } slots[RISCV_STEP_INSNS];
    (void)gpr;
    (void)known;
    slots[0].d = *first;
    slots[0].here = pc;
    int n = 1;
    size_t off = first->len;
    /* Decode no further than the instruction after sc: bytes past the
     * window are not part of the step and may not be code. */
    while (n < RISCV_STEP_INSNS && off < size) {
        if (pc > UINT64_MAX - off)
            return XRT_INVALID_ADDRESS;
        struct dec d;
        const int got = decode_insn(bytes + off, size - off, &d);
        if (got == 1)
            break;
        if (got != 0)
            return XRT_UNSUPPORTED_CONTROL;
        slots[n].d = d;
        slots[n].here = pc + off;
        off += d.len;
        ++n;
        if (slots[n - 2].d.sc)
            break;
    }
    int sc_at = -1;
    for (int i = 1; i < n; ++i) {
        if (slots[i].d.lr)
            return XRT_UNSUPPORTED_CONTROL;
        if (slots[i].d.sc) {
            if (slots[i].d.sc != first->lr)
                return XRT_UNSUPPORTED_CONTROL;
            sc_at = i;
            break;
        }
    }
    if (sc_at < 0)
        return XRT_UNSUPPORTED_CONTROL;
    /* Include the direct branch after sc so a retry back to lr is not a stop.
     * A call or an indirect branch uses state the window may change. */
    int last = sc_at;
    if (sc_at + 1 < n) {
        const enum rk follow = slots[sc_at + 1].d.kind;
        if (follow == RK_COND || follow == RK_JUMP)
            last = sc_at + 1;
        else if (follow != RK_ORD)
            return XRT_UNSUPPORTED_CONTROL;
    }
    if (slots[last].here > UINT64_MAX - slots[last].d.len)
        return XRT_INVALID_ADDRESS;
    const uint64_t window_end = slots[last].here + slots[last].d.len;
    for (int s = 0; s <= last; ++s) {
        const struct dec *d = &slots[s].d;
        const uint64_t here = slots[s].here;
        if (d->kind == RK_REFUSE || d->kind == RK_INDIRECT || d->kind == RK_CALL ||
            d->kind == RK_ECALL)
            return XRT_UNSUPPORTED_CONTROL;
        if (d->kind == RK_ORD) {
            if (s == last) {
                const enum xrt_status status = add_pc(out, pc, window_end);
                if (status != XRT_OK)
                    return status;
            }
            continue;
        }
        uint64_t taken = 0;
        const enum xrt_status decoded = pc_add(here, d->disp, &taken);
        if (decoded != XRT_OK)
            return decoded;
        const int has_fall = d->kind == RK_COND;
        uint64_t fall = 0;
        if (has_fall) {
            if (here > UINT64_MAX - d->len)
                return XRT_INVALID_ADDRESS;
            fall = here + d->len;
        }
        const int taken_out = outside(taken, pc, window_end);
        const int fall_out = has_fall && outside(fall, pc, window_end);
        if (has_fall && !taken_out && !fall_out) {
            if (s == last && last != sc_at)
                return XRT_UNSUPPORTED_CONTROL;
            continue;
        }
        if (taken_out) {
            const enum xrt_status status = add_pc(out, pc, taken);
            if (status != XRT_OK)
                return status;
        }
        if (fall_out) {
            const enum xrt_status status = add_pc(out, pc, fall);
            if (status != XRT_OK)
                return status;
        }
    }
    return out->count == 0 ? XRT_UNSUPPORTED_CONTROL : XRT_OK;
}

enum xrt_status xrt_riscv_plan(uint64_t pc, const uint8_t *bytes, size_t size,
                               const uint64_t gpr[32], uint32_t known, struct xrt_riscv_plan *out)
{
    if (!out || !gpr || !bytes)
        return XRT_INVALID_ARGUMENT;
    *out = (struct xrt_riscv_plan){0};
    if (pc & 1u)
        return XRT_UNSUPPORTED_CONTROL;
    struct dec first;
    const int got = decode_insn(bytes, size, &first);
    if (got != 0)
        return XRT_UNSUPPORTED_CONTROL;
    if (first.lr)
        return plan_atomic(pc, bytes, size, &first, gpr, known, out);
    return plan_one(pc, &first, gpr, known, out);
}
