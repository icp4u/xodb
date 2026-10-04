//! Bounded normalized operands/effects. This is an inspection IR, not an
//! executable semantic lift: aliases, flags, faults and implicit memory effects
//! still require architecture-specific reasoning. Unsupported operations stay opaque.
const std = @import("std");
const c = @import("../c.zig").api;
pub const max_instructions = 64;
pub const max_bytes = 1024;
pub const Operation = enum { @"opaque", copy, load_address, add, subtract, multiply, bit_and, bit_or, bit_xor, bit_not, negate, shift_left, shift_right, arithmetic_shift_right, compare, test_bits, conditional_branch, jump, call, return_, trap, system, push, pop, nop };
pub const Access = enum { read, write, read_write };
pub const Memory = struct {
    segment: ?[]const u8,
    base: ?[]const u8,
    index: ?[]const u8,
    scale: i32,
    displacement: i64,
    pc_relative: bool,
    static_address: ?u64,
    address_only: bool,
};
pub const Operand = struct {
    kind: enum { register, immediate, memory, @"opaque" },
    width_bits: u16,
    access: ?Access,
    register: ?[]const u8 = null,
    immediate: ?i64 = null,
    memory: ?Memory = null,
};
pub const Instruction = struct {
    address: u64,
    size: u16,
    mnemonic: []const u8,
    text: []const u8,
    operation: Operation,
    operands: []Operand,
    registers_read: []const []const u8,
    registers_written: []const []const u8,
    register_access_available: bool,
    // Raw prefixes retain REP/LOCK/segment/address-size information. No claim
    // that classifying an instruction models their full semantics.
    prefixes: [4]u8,
    semantics_complete: bool = false,
    memory_effects_complete: bool = false,
    pub fn deinit(self: Instruction, a: std.mem.Allocator) void {
        a.free(self.mnemonic);
        a.free(self.text);
        for (self.operands) |operand| {
            if (operand.register) |r| a.free(r);
            if (operand.memory) |m| {
                if (m.segment) |r| a.free(r);
                if (m.base) |r| a.free(r);
                if (m.index) |r| a.free(r);
            }
        }
        a.free(self.operands);
        for (self.registers_read) |r| a.free(r);
        for (self.registers_written) |r| a.free(r);
        a.free(self.registers_read);
        a.free(self.registers_written);
    }
};
fn reg(a: std.mem.Allocator, handle: c.csh, id: c_uint) !?[]const u8 {
    if (id == c.X86_REG_INVALID) return null;
    const text = c.cs_reg_name(handle, id);
    return try a.dupe(u8, if (text != null) std.mem.span(text) else "[unknown register]");
}
fn operation(raw: *const c.cs_insn) Operation {
    return switch (raw.id) {
        c.X86_INS_MOV, c.X86_INS_MOVABS => .copy,
        c.X86_INS_LEA => .load_address,
        c.X86_INS_ADD => .add,
        c.X86_INS_SUB => .subtract,
        c.X86_INS_IMUL, c.X86_INS_MUL => .multiply,
        c.X86_INS_AND => .bit_and,
        c.X86_INS_OR => .bit_or,
        c.X86_INS_XOR => .bit_xor,
        c.X86_INS_NOT => .bit_not,
        c.X86_INS_NEG => .negate,
        c.X86_INS_SHL, c.X86_INS_SAL => .shift_left,
        c.X86_INS_SHR => .shift_right,
        c.X86_INS_SAR => .arithmetic_shift_right,
        c.X86_INS_CMP => .compare,
        c.X86_INS_TEST => .test_bits,
        c.X86_INS_JMP, c.X86_INS_LJMP => .jump,
        c.X86_INS_CALL, c.X86_INS_LCALL => .call,
        c.X86_INS_RET, c.X86_INS_RETF, c.X86_INS_RETFQ => .return_,
        c.X86_INS_UD0, c.X86_INS_UD1, c.X86_INS_UD2, c.X86_INS_HLT, c.X86_INS_INT3 => .trap,
        c.X86_INS_SYSCALL, c.X86_INS_SYSENTER, c.X86_INS_INT => .system,
        c.X86_INS_PUSH => .push,
        c.X86_INS_POP => .pop,
        c.X86_INS_NOP => .nop,
        else => blk: {
            const groups = raw.detail.*.groups[0..raw.detail.*.groups_count];
            if (std.mem.indexOfScalar(u8, groups, c.CS_GRP_JUMP) != null or raw.id == c.X86_INS_LOOP or raw.id == c.X86_INS_LOOPE or raw.id == c.X86_INS_LOOPNE) break :blk .conditional_branch;
            break :blk .@"opaque";
        },
    };
}
fn registers(a: std.mem.Allocator, handle: c.csh, ids: []const u16) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |r| a.free(r);
        list.deinit(a);
    }
    for (ids) |id| {
        const value = (try reg(a, handle, id)) orelse continue;
        errdefer a.free(value);
        try list.append(a, value);
    }
    return list.toOwnedSlice(a);
}
fn lift(a: std.mem.Allocator, handle: c.csh, raw: *const c.cs_insn) !Instruction {
    if (raw.detail == null) return error.DisassemblerDetailUnavailable;
    var result = Instruction{ .address = raw.address, .size = raw.size, .mnemonic = &.{}, .text = &.{}, .operation = operation(raw), .operands = &.{}, .registers_read = &.{}, .registers_written = &.{}, .register_access_available = false, .prefixes = raw.detail.*.unnamed_0.x86.prefix };
    errdefer result.deinit(a);
    result.mnemonic = try a.dupe(u8, std.mem.sliceTo(&raw.mnemonic, 0));
    result.text = try a.dupe(u8, std.mem.sliceTo(&raw.op_str, 0));
    const x86 = raw.detail.*.unnamed_0.x86;
    result.operands = try a.alloc(Operand, x86.op_count);
    for (result.operands) |*out| out.* = .{ .kind = .@"opaque", .width_bits = 0, .access = null };
    for (x86.operands[0..x86.op_count], result.operands) |operand, *out| {
        out.width_bits = @as(u16, operand.size) * 8;
        out.access = switch (operand.access) {
            c.CS_AC_READ => .read,
            c.CS_AC_WRITE => .write,
            c.CS_AC_READ | c.CS_AC_WRITE => .read_write,
            else => null,
        };
        switch (operand.type) {
            c.X86_OP_REG => {
                out.kind = .register;
                out.register = try reg(a, handle, operand.unnamed_0.reg);
            },
            c.X86_OP_IMM => {
                out.kind = .immediate;
                out.immediate = operand.unnamed_0.imm;
            },
            c.X86_OP_MEM => {
                const mem = operand.unnamed_0.mem;
                out.kind = .memory;
                out.memory = .{ .segment = null, .base = null, .index = null, .scale = mem.scale, .displacement = mem.disp, .pc_relative = mem.base == c.X86_REG_RIP or mem.base == c.X86_REG_EIP, .static_address = null, .address_only = raw.id == c.X86_INS_LEA };
                out.memory.?.segment = try reg(a, handle, mem.segment);
                out.memory.?.base = try reg(a, handle, mem.base);
                out.memory.?.index = try reg(a, handle, mem.index);
                if (mem.base == c.X86_REG_RIP and mem.index == c.X86_REG_INVALID and mem.segment == c.X86_REG_INVALID) out.memory.?.static_address = std.math.cast(u64, @as(i128, raw.address) + raw.size + mem.disp);
                // LEA describes an address expression, never a memory access.
                if (raw.id == c.X86_INS_LEA) out.access = null;
            },
            else => {},
        }
    }
    var reads: c.cs_regs = undefined;
    var writes: c.cs_regs = undefined;
    var nr: u8 = 0;
    var nw: u8 = 0;
    if (c.cs_regs_access(handle, raw, &reads, &nr, &writes, &nw) == c.CS_ERR_OK) {
        result.registers_read = try registers(a, handle, reads[0..nr]);
        result.registers_written = try registers(a, handle, writes[0..nw]);
        result.register_access_available = true;
    }
    return result;
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8, address: u64, limit: usize) ![]Instruction {
    if (@import("../target/arch.zig").native != .x86_64) return error.InstructionAnalysisUnsupportedArchitecture;
    if (bytes.len == 0 or bytes.len > max_bytes or limit == 0 or limit > max_instructions) return error.InvalidAnalysisLimit;
    if (address > @as(u64, std.math.maxInt(u64)) - bytes.len) return error.InvalidAddress;
    var handle: c.csh = 0;
    if (c.cs_open(c.CS_ARCH_X86, c.CS_MODE_64, &handle) != c.CS_ERR_OK) return error.DisassemblerUnavailable;
    defer _ = c.cs_close(&handle);
    if (c.cs_option(handle, c.CS_OPT_DETAIL, c.CS_OPT_ON) != c.CS_ERR_OK) return error.DisassemblerDetailUnavailable;
    var raw: [*c]c.cs_insn = null;
    const n = c.cs_disasm(handle, bytes.ptr, bytes.len, address, limit, &raw);
    defer c.cs_free(raw, n);
    var out: std.ArrayList(Instruction) = .empty;
    errdefer {
        for (out.items) |inst| inst.deinit(a);
        out.deinit(a);
    }
    for (raw[0..n]) |*inst| {
        const item = try lift(a, handle, inst);
        errdefer item.deinit(a);
        try out.append(a, item);
    }
    return out.toOwnedSlice(a);
}
fn free(a: std.mem.Allocator, list: []Instruction) void {
    for (list) |inst| inst.deinit(a);
    a.free(list);
}
test "inspection IR preserves memory width/addressing, LEA, implicit registers and opaque effects" {
    const a = std.testing.allocator;
    const items = try decode(a, &.{ 0x48, 0x8b, 0x44, 0xcb, 0xf0, 0x48, 0x8d, 0x05, 0x10, 0, 0, 0, 0x50, 0x0f, 0x0b, 0xf3, 0xa4 }, 0x1000, 64);
    defer free(a, items);
    try std.testing.expectEqual(5, items.len);
    try std.testing.expectEqual(Operation.copy, items[0].operation);
    const memory = items[0].operands[1].memory.?;
    try std.testing.expectEqualStrings("rbx", memory.base.?);
    try std.testing.expectEqualStrings("rcx", memory.index.?);
    try std.testing.expectEqual(8, memory.scale);
    try std.testing.expectEqual(-16, memory.displacement);
    try std.testing.expectEqual(64, items[0].operands[1].width_bits);
    try std.testing.expectEqual(Access.read, items[0].operands[1].access.?);
    try std.testing.expectEqual(Operation.load_address, items[1].operation);
    try std.testing.expectEqual(0x101c, items[1].operands[1].memory.?.static_address.?);
    try std.testing.expect(items[1].operands[1].memory.?.address_only);
    try std.testing.expectEqual(null, items[1].operands[1].access);
    var stack_written = false;
    for (items[2].registers_written) |r| if (std.mem.eql(u8, r, "rsp")) {
        stack_written = true;
    };
    try std.testing.expect(stack_written);
    try std.testing.expectEqual(Operation.trap, items[3].operation);
    try std.testing.expectEqual(Operation.@"opaque", items[4].operation);
    try std.testing.expectEqual(0xf3, items[4].prefixes[0]);
    for (items) |item| try std.testing.expect(!item.semantics_complete and !item.memory_effects_complete);
}
test "inspection IR rejects oversized requests and leaves truncated instructions undecoded" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidAnalysisLimit, decode(a, &.{0x90}, 0, 65));
    try std.testing.expectError(error.InvalidAddress, decode(a, &.{0x90}, std.math.maxInt(u64), 1));
    const items = try decode(a, &.{ 0x90, 0x48, 0x8b }, 0x1000, 64);
    defer free(a, items);
    try std.testing.expectEqual(1, items.len);
}
