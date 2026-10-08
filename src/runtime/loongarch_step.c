#include "loongarch_step.h"

/* Integer control transfers use primary opcode bits [31:26]. ll/sc use the
 * full 8-bit opcode in bits [31:24]: 0x20 ll.w, 0x21 sc.w, 0x22 ll.d, 0x23 sc.d.
 * I26 immediates are split: si26 = (bits[9:0] << 16) | bits[25:10]. */

enum xrt_step_kind {
    STEP_ORD,
    STEP_COND21,
    STEP_COND16,
    STEP_JIRL,
    STEP_B,
    STEP_BL,
    STEP_REFUSE
};

/* Byte displacement. A signed left shift of a negative field is undefined. */
static int64_t disp_bytes(uint32_t value, unsigned bits)
{
    const uint32_t mask = (1u << bits) - 1u;
    const uint32_t field = value & mask;
    const int64_t wide = (int64_t)field;
    if (field & (1u << (bits - 1)))
        return (wide - (int64_t)((uint64_t)1 << bits)) * 4;
    return wide * 4;
}
static int opcode8(uint32_t insn)
{
    return (int)((insn >> 24) & 0xffu);
}
static enum xrt_step_kind kind_of(uint32_t insn)
{
    if (insn == 0x002a0000u)
        return STEP_REFUSE;
    switch ((insn >> 26) & 0x3fu) {
    case 0x10:
    case 0x11:
        return STEP_COND21;
    case 0x12:
        /* bceqz (bits 9:8 = 00) and bcnez (01) use the beqz offs21 layout.
         * Both successors are planted, so FCC is not read. Other values are
         * LBT jumps and stay refused. */
        return ((insn >> 8) & 3u) <= 1 ? STEP_COND21 : STEP_REFUSE;
    case 0x13:
        return STEP_JIRL;
    case 0x14:
        return STEP_B;
    case 0x15:
        return STEP_BL;
    case 0x16:
    case 0x17:
    case 0x18:
    case 0x19:
    case 0x1a:
    case 0x1b:
        return STEP_COND16;
    default:
        return STEP_ORD;
    }
}
static enum xrt_status add_pc(struct xrt_loongarch_plan *out, uint64_t step_pc, uint64_t dest)
{
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
static enum xrt_status taken_of(uint32_t insn, uint64_t here, enum xrt_step_kind kind,
                                const uint64_t gpr[32], uint32_t known, uint64_t *out)
{
    if (kind == STEP_COND21) {
        const uint32_t si21 = ((insn & 31u) << 16) | ((insn >> 10) & 0xffffu);
        *out = here + (uint64_t)disp_bytes(si21, 21);
        return XRT_OK;
    }
    if (kind == STEP_COND16) {
        *out = here + (uint64_t)disp_bytes((insn >> 10) & 0xffffu, 16);
        return XRT_OK;
    }
    if (kind == STEP_JIRL) {
        const uint32_t rj = (insn >> 5) & 31u;
        const int64_t disp = disp_bytes((insn >> 10) & 0xffffu, 16);
        uint64_t base = 0;
        if (rj != 0) {
            if ((known & (1u << rj)) == 0)
                return XRT_REGISTER_UNAVAILABLE;
            base = gpr[rj];
        }
        *out = base + (uint64_t)disp;
        return XRT_OK;
    }
    if (kind == STEP_B || kind == STEP_BL) {
        const uint32_t si26 = ((insn & 0x3ffu) << 16) | ((insn >> 10) & 0xffffu);
        *out = here + (uint64_t)disp_bytes(si26, 26);
        return XRT_OK;
    }
    return XRT_UNSUPPORTED_CONTROL;
}
static int outside(uint64_t dest, uint64_t window, uint64_t window_end)
{
    return dest < window || dest >= window_end;
}
static enum xrt_status plan_atomic(uint64_t pc, uint32_t insn, const uint64_t gpr[32],
                                   uint32_t known, const uint32_t *forward, uint8_t forward_count,
                                   struct xrt_loongarch_plan *out)
{
    const int ll = opcode8(insn);
    const int sc = ll == 0x20 ? 0x21 : 0x23;
    int sc_index = -1;
    for (uint8_t i = 0; i < forward_count; ++i) {
        const int op = opcode8(forward[i]);
        if (op == 0x20 || op == 0x22)
            return XRT_UNSUPPORTED_CONTROL;
        if (op == sc) {
            sc_index = (int)i;
            break;
        }
    }
    if (sc_index < 0)
        return XRT_UNSUPPORTED_CONTROL;
    /* Include the branch that follows sc so a retry back to ll is not a stop.
     * Exits are successors outside [pc, end). Both edges of that branch staying
     * inside the window is a typed refusal. */
    int last = sc_index + 1;
    if (sc_index + 1 < (int)forward_count) {
        const enum xrt_step_kind follow = kind_of(forward[sc_index + 1]);
        if (follow == STEP_REFUSE)
            return XRT_UNSUPPORTED_CONTROL;
        if (follow != STEP_ORD)
            last = sc_index + 2;
    }
    if ((uint64_t)(last + 1) > (UINT64_MAX - pc) / 4)
        return XRT_INVALID_ADDRESS;
    const uint64_t window_end = pc + 4ull * (uint64_t)(last + 1);
    const int sc_seq = sc_index + 1;
    for (int s = 0; s <= last; ++s) {
        const uint32_t word = s == 0 ? insn : forward[s - 1];
        const uint64_t here = pc + 4ull * (uint64_t)s;
        const enum xrt_step_kind kind = kind_of(word);
        if (kind == STEP_REFUSE)
            return XRT_UNSUPPORTED_CONTROL;
        /* A jirl or bl after ll uses registers that the window may change.
         * Only the ll itself may be an indirect branch, and it is not one. */
        if (s != 0 && (kind == STEP_JIRL || kind == STEP_BL))
            return XRT_UNSUPPORTED_CONTROL;
        if (kind == STEP_ORD) {
            if (s == last) {
                const enum xrt_status status = add_pc(out, pc, window_end);
                if (status != XRT_OK)
                    return status;
            }
            continue;
        }
        uint64_t taken = 0;
        const enum xrt_status decoded = taken_of(word, here, kind, gpr, known, &taken);
        if (decoded != XRT_OK)
            return decoded;
        const int has_fall = kind == STEP_COND21 || kind == STEP_COND16;
        const uint64_t fall = here + 4;
        const int taken_out = outside(taken, pc, window_end);
        const int fall_out = has_fall && outside(fall, pc, window_end);
        if (has_fall && !taken_out && !fall_out) {
            if (s == last && last != sc_seq)
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
enum xrt_status xrt_loongarch_plan(uint64_t pc, uint32_t insn, const uint64_t gpr[32],
                                   uint32_t known, const uint32_t *forward, uint8_t forward_count,
                                   struct xrt_loongarch_plan *out)
{
    if (!out || !gpr || forward_count > 16 || (forward_count && !forward))
        return XRT_INVALID_ARGUMENT;
    *out = (struct xrt_loongarch_plan){0};
    if (pc & 3u)
        return XRT_UNSUPPORTED_CONTROL;
    const int op = opcode8(insn);
    if (op == 0x20 || op == 0x22)
        return plan_atomic(pc, insn, gpr, known, forward, forward_count, out);
    const enum xrt_step_kind kind = kind_of(insn);
    if (kind == STEP_REFUSE)
        return XRT_UNSUPPORTED_CONTROL;
    if (kind == STEP_ORD) {
        if (pc > UINT64_MAX - 4)
            return XRT_INVALID_ADDRESS;
        out->count = 1;
        out->pc[0] = pc + 4;
        return XRT_OK;
    }
    uint64_t taken = 0;
    const enum xrt_status decoded = taken_of(insn, pc, kind, gpr, known, &taken);
    if (decoded != XRT_OK)
        return decoded;
    if (kind == STEP_B) {
        if (taken == pc) {
            out->emulate = 1;
            return XRT_OK;
        }
        out->count = 1;
        out->pc[0] = taken;
        return XRT_OK;
    }
    if (kind == STEP_BL || kind == STEP_JIRL) {
        if (taken == pc)
            return XRT_UNSUPPORTED_CONTROL;
        out->count = 1;
        out->pc[0] = taken;
        return XRT_OK;
    }
    if (pc > UINT64_MAX - 4)
        return XRT_INVALID_ADDRESS;
    const enum xrt_status taken_status = add_pc(out, pc, taken);
    if (taken_status != XRT_OK)
        return taken_status;
    const enum xrt_status fall_status = add_pc(out, pc, pc + 4);
    if (fall_status != XRT_OK)
        return fall_status;
    return out->count == 0 ? XRT_UNSUPPORTED_CONTROL : XRT_OK;
}
