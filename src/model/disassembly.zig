const std = @import("std");
const c = @import("../c.zig").api;
const Arch = @import("../target/arch.zig").Arch;
pub const Flow = enum { ordinary, conditional, jump, call, ret, trap, system };
pub const Instruction = struct { address: u64, size: u16, mnemonic: [32]u8, operands: [160]u8, flow: Flow = .ordinary, target: ?u64 = null };
pub fn decode(bytes: []const u8, address: u64, out: []Instruction) !usize {
    return decodeFor(@import("../target/arch.zig").native, bytes, address, out);
}
pub fn decodeFlow(bytes: []const u8, address: u64, out: []Instruction) !usize {
    return decodeFlowFor(@import("../target/arch.zig").native, bytes, address, out);
}
pub fn decodeFor(architecture: Arch, bytes: []const u8, address: u64, out: []Instruction) !usize {
    return decodeImpl(architecture, bytes, address, out, false);
}
pub fn decodeFlowFor(architecture: Arch, bytes: []const u8, address: u64, out: []Instruction) !usize {
    return decodeImpl(architecture, bytes, address, out, true);
}
fn decodeImpl(architecture: Arch, bytes: []const u8, address: u64, out: []Instruction, detail: bool) !usize {
    if (out.len == 0 or bytes.len == 0) return 0;
    if (address > std.math.maxInt(u64) - bytes.len) return error.InvalidAddress;
    if (architecture == .loongarch64) return error.DisassemblerUnavailable;
    var handle: c.csh = 0;
    if (c.cs_open(switch (architecture) {
        .x86_64 => c.CS_ARCH_X86,
        .aarch64 => c.CS_ARCH_ARM64,
        .m68k => c.CS_ARCH_M68K,
        .loongarch64 => unreachable,
    }, switch (architecture) {
        .x86_64 => c.CS_MODE_64,
        .aarch64 => c.CS_MODE_ARM,
        .m68k => c.CS_MODE_BIG_ENDIAN | c.CS_MODE_M68K_040,
        .loongarch64 => unreachable,
    }, &handle) != c.CS_ERR_OK) return error.DisassemblerUnavailable;
    defer _ = c.cs_close(&handle);
    if (detail and c.cs_option(handle, c.CS_OPT_DETAIL, c.CS_OPT_ON) != c.CS_ERR_OK) return error.DisassemblerDetailUnavailable;
    var instructions: [*c]c.cs_insn = null;
    const count = c.cs_disasm(handle, bytes.ptr, bytes.len, address, out.len, &instructions);
    defer c.cs_free(instructions, count);
    for (0..count) |i| {
        const raw = &instructions[i];
        out[i] = .{ .address = raw.address, .size = raw.size, .mnemonic = raw.mnemonic, .operands = raw.op_str };
        if (!detail) continue;
        if (raw.detail == null) return error.DisassemblerDetailUnavailable;
        const groups = raw.detail.*.groups[0..raw.detail.*.groups_count];
        if (architecture == .aarch64) {
            const arm = raw.detail.*.unnamed_0.arm64;
            out[i].flow = if (raw.id == c.ARM64_INS_BRK or raw.id == c.ARM64_INS_HLT)
                .trap
            else if (raw.id == c.ARM64_INS_RET)
                .ret
            else if (raw.id == c.ARM64_INS_BL or raw.id == c.ARM64_INS_BLR)
                .call
            else if (raw.id == c.ARM64_INS_BR)
                .jump
            else if (raw.id == c.ARM64_INS_B)
                (if (arm.cc == c.ARM64_CC_INVALID or arm.cc == c.ARM64_CC_AL or arm.cc == c.ARM64_CC_NV) .jump else .conditional)
            else if (raw.id == c.ARM64_INS_CBZ or raw.id == c.ARM64_INS_CBNZ or raw.id == c.ARM64_INS_TBZ or raw.id == c.ARM64_INS_TBNZ)
                .conditional
            else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_INT) != null)
                .system
            else
                .ordinary;
            if (out[i].flow == .call or out[i].flow == .jump or out[i].flow == .conditional) {
                for (arm.operands[0..arm.op_count]) |operand| if (operand.type == c.ARM64_OP_IMM) {
                    out[i].target = @bitCast(operand.unnamed_0.imm);
                };
            }
        } else if (architecture == .m68k) {
            // Capstone group classifications apply independently of host ISA.
            out[i].flow = if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_RET) != null or std.mem.indexOfScalar(u8, groups, c.CS_GRP_IRET) != null) .ret else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_CALL) != null) .call else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_JUMP) != null) (if (raw.id == c.M68K_INS_BRA or raw.id == c.M68K_INS_JMP) .jump else .conditional) else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_INT) != null) .trap else .ordinary;
        } else {
            out[i].flow = if (raw.id == c.X86_INS_HLT or raw.id == c.X86_INS_UD0 or raw.id == c.X86_INS_UD1 or raw.id == c.X86_INS_UD2)
                .trap
            else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_RET) != null or std.mem.indexOfScalar(u8, groups, c.CS_GRP_IRET) != null or raw.id == c.X86_INS_SYSRET or raw.id == c.X86_INS_SYSEXIT)
                .ret
            else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_CALL) != null)
                .call
            else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_JUMP) != null or raw.id == c.X86_INS_XBEGIN or raw.id == c.X86_INS_LOOP or raw.id == c.X86_INS_LOOPE or raw.id == c.X86_INS_LOOPNE)
                (if (raw.id == c.X86_INS_JMP or raw.id == c.X86_INS_LJMP) .jump else .conditional)
            else if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_INT) != null)
                .system
            else
                .ordinary;
            if (out[i].flow == .call or out[i].flow == .jump or out[i].flow == .conditional) {
                const x86 = raw.detail.*.unnamed_0.x86;
                // Far segment:offset transfers are deliberately unresolved.
                if (x86.op_count == 1 and x86.operands[0].type == c.X86_OP_IMM) out[i].target = @bitCast(x86.operands[0].unnamed_0.imm);
            }
        }
    }
    return count;
}
test "decoder preserves instruction boundaries and addresses" {
    var instructions: [4]Instruction = undefined;
    const n = try decode(&.{ 0x55, 0x48, 0x89, 0xe5, 0xc3 }, 0x1000, &instructions);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u64, 0x1001), instructions[1].address);
    try std.testing.expectEqualStrings("ret", std.mem.sliceTo(@as([]const u8, &instructions[2].mnemonic), 0));
}

test "loongarch disassembly is explicitly unavailable" {
    var instructions: [1]Instruction = undefined;
    try std.testing.expectError(error.DisassemblerUnavailable, decodeFor(.loongarch64, &.{ 0x00, 0x00, 0x2a, 0x00 }, 0x1000, &instructions));
}

test "m68k disassembly uses target byte order on a non-m68k host" {
    var instructions: [4]Instruction = undefined;
    const n = try decodeFlowFor(.m68k, &.{ 0x4e, 0x71, 0x4e, 0x75 }, 0x1000, &instructions);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u64, 0x1002), instructions[1].address);
    try std.testing.expectEqualStrings("nop", std.mem.sliceTo(&instructions[0].mnemonic, 0));
    try std.testing.expectEqual(Flow.ret, instructions[1].flow);
}
