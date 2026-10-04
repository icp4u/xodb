//! Deterministic DWARF expression evaluation against explicit target state.
//! Decoding belongs to the debug-info adapter; no operation reads host addresses.
const std = @import("std");
const OP = std.dwarf.OP;
const Registers = @import("../target/linux.zig").Registers;
pub const Op = struct { atom: u8, number: u64 = 0, number2: u64 = 0, offset: u64 = 0, data: ?[]const u8 = null };
pub const RegisterSet = [33]?u64;
pub const Place = struct { kind: enum { address, register, value }, bits: u64, register: ?u16 = null, data: ?[]const u8 = null, valid: ?[]const u8 = null };
pub const Context = struct {
    registers: RegisterSet,
    register_data: ?*const fn (*anyopaque, u64) ?[]const u8 = null,
    cfa: ?u64 = null,
    frame_base: ?u64 = null,
    load_bias: u64 = 0,
    user: *anyopaque,
    read: *const fn (*anyopaque, u64, []u8) anyerror!usize,
};
pub fn registers(regs: Registers) RegisterSet {
    var out: RegisterSet = @splat(null);
    if (@import("../target/linux.zig").architecture == .aarch64) {
        inline for (std.meta.fields(Registers)[0..31], 0..) |field, i| out[i] = @field(regs, field.name);
        out[31] = regs.sp;
        out[32] = regs.pc;
    } else {
        const x86 = [_]?u64{ regs.rax, regs.rdx, regs.rcx, regs.rbx, regs.rsi, regs.rdi, regs.rbp, regs.rsp, regs.r8, regs.r9, regs.r10, regs.r11, regs.r12, regs.r13, regs.r14, regs.r15, regs.rip };
        @memcpy(out[0..x86.len], &x86);
    }
    return out;
}
fn reg(ctx: Context, number: u64) !u64 {
    if (number >= ctx.registers.len) return error.UnsupportedRegister;
    return ctx.registers[@intCast(number)] orelse error.RegisterUnavailable;
}
pub fn evaluate(ctx: Context, ops: []const Op) !Place {
    if (ops.len == 0) return error.LocationUnavailable;
    if (ops.len > 4096) return error.ExpressionTooLarge;
    if (ops.len == 1) {
        const op = ops[0];
        if (op.atom == OP.implicit_value) {
            const data = op.data orelse return error.MalformedExpression;
            if (data.len > 4096) return error.CompositeTooLarge;
            return .{ .kind = .value, .bits = lowBits(data), .data = data };
        }
        const number: ?u64 = if (op.atom >= OP.reg0 and op.atom <= OP.reg31) op.atom - OP.reg0 else if (op.atom == OP.regx) op.number else null;
        if (number) |n| if (ctx.register_data) |read| if (read(ctx.user, n)) |data| {
            if (n > std.math.maxInt(u16)) return error.UnsupportedRegister;
            return .{ .kind = .register, .bits = lowBits(data), .data = data, .register = @intCast(n) };
        };
    }
    var stack: [128]u64 = undefined;
    var count: usize = 0;
    var kind: @FieldType(Place, "kind") = .address;
    var register: ?u16 = null;
    for (ops) |op| {
        if (count == stack.len) return error.ExpressionTooDeep;
        switch (op.atom) {
            OP.addr => {
                stack[count] = std.math.add(u64, op.number, ctx.load_bias) catch return error.InvalidAddress;
                count += 1;
            },
            OP.lit0...OP.lit31 => {
                stack[count] = op.atom - OP.lit0;
                count += 1;
            },
            OP.reg0...OP.reg31 => {
                if (ops.len != 1) return error.UnsupportedLocation;
                register = op.atom - OP.reg0;
                stack[count] = try reg(ctx, register.?);
                count += 1;
                kind = .register;
            },
            OP.regx => {
                if (ops.len != 1 or op.number > std.math.maxInt(u16)) return error.UnsupportedLocation;
                register = @intCast(op.number);
                stack[count] = try reg(ctx, op.number);
                count += 1;
                kind = .register;
            },
            OP.breg0...OP.breg31 => {
                stack[count] = (try reg(ctx, op.atom - OP.breg0)) +% op.number;
                count += 1;
            },
            OP.bregx => {
                stack[count] = (try reg(ctx, op.number)) +% op.number2;
                count += 1;
            },
            OP.fbreg => {
                stack[count] = (ctx.frame_base orelse return error.FrameBaseUnavailable) +% op.number;
                count += 1;
            },
            OP.call_frame_cfa => {
                stack[count] = ctx.cfa orelse return error.CfaUnavailable;
                count += 1;
            },
            OP.const1u, OP.const2u, OP.const4u, OP.const8u, OP.constu, OP.const1s, OP.const2s, OP.const4s, OP.const8s, OP.consts => {
                stack[count] = op.number;
                count += 1;
            },
            OP.dup => {
                if (count < 1) return error.MalformedExpression;
                stack[count] = stack[count - 1];
                count += 1;
            },
            OP.drop => {
                if (count < 1) return error.MalformedExpression;
                count -= 1;
            },
            OP.over => {
                if (count < 2) return error.MalformedExpression;
                stack[count] = stack[count - 2];
                count += 1;
            },
            OP.pick => {
                if (op.number >= count) return error.MalformedExpression;
                stack[count] = stack[count - @as(usize, @intCast(op.number)) - 1];
                count += 1;
            },
            OP.swap => {
                if (count < 2) return error.MalformedExpression;
                std.mem.swap(u64, &stack[count - 1], &stack[count - 2]);
            },
            OP.rot => {
                if (count < 3) return error.MalformedExpression;
                const top = stack[count - 1];
                stack[count - 1] = stack[count - 2];
                stack[count - 2] = stack[count - 3];
                stack[count - 3] = top;
            },
            OP.plus_uconst => {
                if (count < 1) return error.MalformedExpression;
                stack[count - 1] +%= op.number;
            },
            OP.deref, OP.deref_size => {
                if (count < 1) return error.MalformedExpression;
                const size: usize = if (op.atom == OP.deref) 8 else std.math.cast(usize, op.number) orelse return error.UnsupportedLocation;
                if (size == 0 or size > 8) return error.UnsupportedLocation;
                var bytes: [8]u8 = @splat(0);
                if (try ctx.read(ctx.user, stack[count - 1], bytes[0..size]) != size) return error.MemoryUnreadable;
                stack[count - 1] = std.mem.readInt(u64, &bytes, .little);
            },
            OP.stack_value => {
                if (count < 1) return error.MalformedExpression;
                kind = .value;
            },
            OP.neg, OP.not, OP.abs => {
                if (count < 1) return error.MalformedExpression;
                const value = stack[count - 1];
                stack[count - 1] = switch (op.atom) {
                    OP.neg => @as(u64, 0) -% value,
                    OP.not => ~value,
                    OP.abs => if (@as(i64, @bitCast(value)) < 0) @as(u64, 0) -% value else value,
                    else => unreachable,
                };
            },
            OP.plus, OP.minus, OP.mul, OP.div, OP.mod, OP.@"and", OP.@"or", OP.xor, OP.shl, OP.shr, OP.shra, OP.eq, OP.ne, OP.lt, OP.le, OP.gt, OP.ge => {
                if (count < 2) return error.MalformedExpression;
                const rhs = stack[count - 1];
                const lhs = stack[count - 2];
                count -= 1;
                const l: i64 = @bitCast(lhs);
                const r: i64 = @bitCast(rhs);
                stack[count - 1] = switch (op.atom) {
                    OP.plus => lhs +% rhs,
                    OP.minus => lhs -% rhs,
                    OP.mul => lhs *% rhs,
                    OP.div => if (r == 0 or (l == std.math.minInt(i64) and r == -1)) return error.InvalidArithmetic else @bitCast(@divTrunc(l, r)),
                    OP.mod => if (rhs == 0) return error.InvalidArithmetic else lhs % rhs,
                    OP.@"and" => lhs & rhs,
                    OP.@"or" => lhs | rhs,
                    OP.xor => lhs ^ rhs,
                    OP.shl => if (rhs >= 64) return error.InvalidArithmetic else lhs << @as(u6, @intCast(rhs)),
                    OP.shr => if (rhs >= 64) return error.InvalidArithmetic else lhs >> @as(u6, @intCast(rhs)),
                    OP.shra => if (rhs >= 64) return error.InvalidArithmetic else @bitCast(l >> @as(u6, @intCast(rhs))),
                    OP.eq => @intFromBool(lhs == rhs),
                    OP.ne => @intFromBool(lhs != rhs),
                    OP.lt => @intFromBool(l < r),
                    OP.le => @intFromBool(l <= r),
                    OP.gt => @intFromBool(l > r),
                    OP.ge => @intFromBool(l >= r),
                    else => unreachable,
                };
            },
            OP.nop => {},
            OP.entry_value, OP.GNU_entry_value => return error.EntryValueUnavailable,
            else => return error.UnsupportedLocation,
        }
    }
    if (count != 1) return error.MalformedExpression;
    return .{ .kind = kind, .bits = stack[0], .register = register };
}
test "frame-relative locations and stack values keep runtime addresses distinct" {
    const Mock = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) !usize {
            return error.MemoryUnreadable;
        }
    };
    var token: u8 = 0;
    var regs: RegisterSet = @splat(null);
    regs[0] = 5;
    regs[6] = 0x2000;
    const ctx = Context{ .registers = regs, .cfa = 0x2020, .frame_base = 0x2020, .load_bias = 0x100000, .user = &token, .read = Mock.read };
    const frame = try evaluate(ctx, &.{.{ .atom = OP.fbreg, .number = @bitCast(@as(i64, -16)) }});
    try std.testing.expectEqual(@as(u64, 0x2010), frame.bits);
    const absolute = try evaluate(ctx, &.{.{ .atom = OP.addr, .number = 0x4000 }});
    try std.testing.expectEqual(@as(u64, 0x104000), absolute.bits);
    const value = try evaluate(ctx, &.{ .{ .atom = OP.breg0, .number = 1 }, .{ .atom = OP.lit1 }, .{ .atom = OP.shl }, .{ .atom = OP.stack_value } });
    try std.testing.expectEqual(@as(u64, 12), value.bits);
    try std.testing.expectEqual(@FieldType(Place, "kind").value, value.kind);
    try std.testing.expectError(error.RegisterUnavailable, evaluate(ctx, &.{.{ .atom = OP.reg1 }}));
    try std.testing.expectError(error.MalformedExpression, evaluate(ctx, &.{.{ .atom = OP.plus }}));
}

fn lowBits(data: []const u8) u64 {
    var bytes: [8]u8 = @splat(0);
    @memcpy(bytes[0..@min(8, data.len)], data[0..@min(8, data.len)]);
    return std.mem.readInt(u64, &bytes, .little);
}
/// Materialize piece descriptions in target little-endian bit order. A validity
/// mask preserves missing bits; absent pieces never become plausible zeroes.
pub fn composite(a: std.mem.Allocator, ctx: Context, ops: []const Op) !Place {
    var bits: usize = 0;
    var pieces: usize = 0;
    for (ops) |op| if (op.atom == OP.piece or op.atom == OP.bit_piece) {
        const n = if (op.atom == OP.piece) std.math.mul(u64, op.number, 8) catch return error.CompositeTooLarge else op.number;
        if (n > 4096 * 8 or n > 4096 * 8 - bits) return error.CompositeTooLarge;
        bits += @intCast(n);
        pieces += 1;
    };
    if (pieces == 0) return evaluate(ctx, ops);
    if (ops.len > 4096 or (ops[ops.len - 1].atom != OP.piece and ops[ops.len - 1].atom != OP.bit_piece)) return error.MalformedExpression;
    const data = try a.alloc(u8, (bits + 7) / 8);
    const valid = try a.alloc(u8, data.len);
    @memset(data, 0);
    @memset(valid, 0);
    var first: usize = 0;
    var dest: usize = 0;
    for (ops, 0..) |op, i| {
        if (op.atom != OP.piece and op.atom != OP.bit_piece) continue;
        const count: usize = @intCast(if (op.atom == OP.piece) op.number * 8 else op.number);
        const offset: u64 = if (op.atom == OP.bit_piece) op.number2 else 0;
        const part = if (i == first) null else evaluate(ctx, ops[first..i]) catch |err| switch (err) {
            error.RegisterUnavailable, error.UnsupportedRegister, error.LocationUnavailable, error.EntryValueUnavailable, error.FrameBaseUnavailable, error.CfaUnavailable, error.MemoryUnreadable, error.UnsupportedLocation => null,
            else => return err,
        };
        first = i + 1;
        if (part) |place| {
            var bytes: [4097]u8 = undefined;
            var available: []const u8 = &.{};
            var source_bit: u64 = offset;
            if (place.kind == .address) {
                const address = std.math.add(u64, place.bits, offset / 8) catch return error.InvalidAddress;
                source_bit = offset % 8;
                const wanted = (count + @as(usize, @intCast(source_bit)) + 7) / 8;
                const n = ctx.read(ctx.user, address, bytes[0..wanted]) catch 0;
                if (n > wanted) return error.InvalidMemoryRead;
                available = bytes[0..n];
            } else if (place.data) |raw| {
                available = raw;
            } else {
                std.mem.writeInt(u64, bytes[0..8], place.bits, .little);
                available = bytes[0..8];
            }
            for (0..count) |j| {
                const src = std.math.add(u64, source_bit, j) catch continue;
                if (src / 8 >= available.len) continue;
                const dst = dest + j;
                const mask = @as(u8, 1) << @as(u3, @intCast(dst % 8));
                if (available[@intCast(src / 8)] & (@as(u8, 1) << @as(u3, @intCast(src % 8))) != 0) data[dst / 8] |= mask;
                valid[dst / 8] |= mask;
            }
        }
        dest += count;
    }
    return .{ .kind = .value, .bits = lowBits(data), .data = data, .valid = valid };
}

/// CFI and frame-base consumers need complete scalar state, never missing bits.
pub fn scalar(place: Place, size: usize) !u64 {
    if (size == 0 or size > 8) return error.UnsupportedLocation;
    if (place.data) |data| if (data.len < size) return error.LocationUnavailable;
    if (place.valid) |valid| {
        if (valid.len < size) return error.LocationUnavailable;
        for (valid[0..size]) |mask| if (mask != 255) return error.LocationUnavailable;
    }
    return place.bits;
}
test "composite pieces preserve partial register, memory and bit availability" {
    const Mock = struct {
        fn read(_: *anyopaque, address: u64, out: []u8) !usize {
            const data = [_]u8{ 0x9a, 0xbc, 0xde };
            if (address < 0x1000 or address >= 0x1003) return error.MemoryUnreadable;
            const n = @min(out.len, 0x1003 - address);
            @memcpy(out[0..n], data[@intCast(address - 0x1000)..][0..n]);
            return n;
        }
    };
    var token: u8 = 0;
    var regs: RegisterSet = @splat(null);
    regs[0] = 0x12345678;
    const ctx = Context{ .registers = regs, .user = &token, .read = Mock.read };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed = try composite(a, ctx, &.{ .{ .atom = OP.reg0 }, .{ .atom = OP.piece, .number = 2 }, .{ .atom = OP.addr, .number = 0x1000 }, .{ .atom = OP.piece, .number = 4 }, .{ .atom = OP.piece, .number = 2 } });
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x9a, 0xbc, 0xde, 0, 0, 0 }, mixed.data.?);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 255, 0, 0, 0 }, mixed.valid.?);
    try std.testing.expectError(error.LocationUnavailable, scalar(mixed, 8));
    const bits = try composite(a, ctx, &.{ .{ .atom = OP.reg0 }, .{ .atom = OP.bit_piece, .number = 4, .number2 = 4 }, .{ .atom = OP.bit_piece, .number = 4 }, .{ .atom = OP.addr, .number = 0x1000 }, .{ .atom = OP.bit_piece, .number = 8, .number2 = 4 } });
    try std.testing.expectEqualSlices(u8, &.{ 7, 0xc9 }, bits.data.?);
    try std.testing.expectEqualSlices(u8, &.{ 15, 255 }, bits.valid.?);
    const implicit = try composite(a, ctx, &.{ .{ .atom = OP.implicit_value, .data = &.{ 0x11, 0x22 } }, .{ .atom = OP.piece, .number = 2 }, .{ .atom = OP.reg1 }, .{ .atom = OP.piece, .number = 1 } });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0 }, implicit.data.?);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 0 }, implicit.valid.?);
    try std.testing.expectError(error.CompositeTooLarge, composite(a, ctx, &.{.{ .atom = OP.piece, .number = 4097 }}));
    try std.testing.expectError(error.MalformedExpression, composite(a, ctx, &.{ .{ .atom = OP.piece, .number = 1 }, .{ .atom = OP.reg0 } }));
}
