//! Proven live values for variables exported with pseudo-C.
const std = @import("std");
const host = @import("../semq/host.zig");
const Arch = @import("../target/arch.zig").Arch;
const location = @import("../debug/location.zig");

pub const PseudoValue = struct { name: []const u8, display: []const u8, parameter: bool };

pub const LiveMemory = struct {
    user: *anyopaque,
    read: *const fn (*anyopaque, u64, []u8) anyerror!usize,
};

fn widthMask(width: u8) u64 {
    return if (width == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

pub fn value(a: std.mem.Allocator, architecture: Arch, registers: location.RegisterSet, cfa: ?u64, memory: ?LiveMemory, link_pc: u64, variable: host.PseudoVariable) !?PseudoValue {
    if (variable.size == 0 or variable.size > 32) return null;
    const value_size: usize = @intCast(variable.size);
    const start = variable.valid_start orelse return null;
    const end = variable.valid_end orelse return null;
    if (link_pc < start or link_pc >= end or start >= end) return null;
    var legacy: [1]host.PseudoPiece = undefined;
    const pieces = if (variable.pieces.len != 0) variable.pieces else blk: {
        if (!std.mem.eql(u8, variable.storage, "register") or variable.register == null or variable.size > 8) return null;
        legacy[0] = .{ .storage = "register", .size = @intCast(variable.size), .value_bit_offset = 0, .register = variable.register, .register_bit_offset = variable.register_bit_offset };
        break :blk &legacy;
    };
    if (variable.parameter and !variable.stack_parameter_verified) for (pieces) |piece| {
        if (std.mem.eql(u8, piece.storage, "stack")) return null;
    };
    var bytes: [32]u8 = @splat(0);
    var covered: [32]bool = @splat(false);
    for (pieces) |piece| {
        const width: u8 = piece.size * 8;
        if (piece.size == 0 or piece.value_bit_offset % 8 != 0) return null;
        const value_byte_offset: usize = piece.value_bit_offset / 8;
        if (value_byte_offset + piece.size > value_size) return null;
        var raw_value: u64 = undefined;
        if (std.mem.eql(u8, piece.storage, "register")) {
            const name = piece.register orelse return null;
            const lower = try a.dupe(u8, name);
            defer a.free(lower);
            _ = std.ascii.lowerString(lower, name);
            const register = architecture.registerNumber(lower) orelse return null;
            const raw = registers[register] orelse return null;
            if (@as(u16, piece.register_bit_offset) + width > 64) return null;
            raw_value = (raw >> @intCast(piece.register_bit_offset)) & widthMask(width);
        } else if (std.mem.eql(u8, piece.storage, "stack")) {
            const base = cfa orelse return null;
            const offset = piece.cfa_offset orelse return null;
            const address = if (offset >= 0)
                std.math.add(u64, base, @intCast(offset)) catch return null
            else if (offset == std.math.minInt(i64))
                return null
            else
                std.math.sub(u64, base, @intCast(-offset)) catch return null;
            var memory_bytes: [8]u8 = undefined;
            const reader = memory orelse return null;
            const got = (reader.read)(reader.user, address, memory_bytes[0..piece.size]) catch return null;
            if (got != piece.size) return null;
            raw_value = location.lowBits(memory_bytes[0..piece.size], architecture.endian());
        } else return null;
        for (0..piece.size) |index| {
            const at = value_byte_offset + index;
            if (covered[at]) return null;
            covered[at] = true;
            bytes[at] = @truncate(raw_value >> @intCast(index * 8));
        }
    }
    for (covered[0..value_size]) |present| if (!present) return null;
    const nonzero = for (bytes[0..value_size], 0..) |byte, index| {
        if (byte != 0) break index;
    } else 0;
    var padding: [32]bool = @splat(false);
    for (variable.padding) |range| {
        const offset: usize = range.offset;
        const range_size: usize = range.size;
        if (offset >= value_size or range_size > value_size - offset) return null;
        for (padding[offset .. offset + range_size]) |*byte| {
            if (byte.*) return null;
            byte.* = true;
        }
    }
    const has_padding = std.mem.indexOfScalar(bool, padding[0..value_size], true) != null;
    const display = if (!has_padding and std.mem.indexOf(u8, variable.type_name, "bool") != null)
        (if (nonzero == 0 and bytes[0] == 0) "false" else "true")
    else blk: {
        var highest: usize = value_size - 1;
        if (!has_padding) {
            while (highest > 0 and bytes[highest] == 0) highest -= 1;
        }
        var text: [66]u8 = undefined;
        var written: usize = 2;
        @memcpy(text[0..2], "0x");
        if (padding[highest]) {
            @memcpy(text[written .. written + 2], "??");
            written += 2;
        } else if (has_padding) {
            written += (try std.fmt.bufPrint(text[written..], "{x:0>2}", .{bytes[highest]})).len;
        } else {
            written += (try std.fmt.bufPrint(text[written..], "{x}", .{bytes[highest]})).len;
        }
        while (highest > 0) {
            highest -= 1;
            if (padding[highest]) {
                @memcpy(text[written .. written + 2], "??");
                written += 2;
            } else written += (try std.fmt.bufPrint(text[written..], "{x:0>2}", .{bytes[highest]})).len;
        }
        break :blk try a.dupe(u8, text[0..written]);
    };
    return .{ .name = variable.name, .display = display, .parameter = variable.parameter };
}

/// Apply the same storage proof for every pseudo-C variable. GUI and MCP
/// provide their stopped frame through this small model boundary.
pub fn collect(a: std.mem.Allocator, analysis: *host.Analysis, architecture: Arch, registers: location.RegisterSet, cfa: ?u64, memory: ?LiveMemory, link_pc: u64) ![]const PseudoValue {
    if (link_pc -% analysis.function.key.entry >= analysis.function.key.size) return &.{};
    var values: std.ArrayList(PseudoValue) = .empty;
    for (analysis.pseudocode.variables) |variable| {
        const found = (try value(a, architecture, registers, cfa, memory, link_pc, variable)) orelse continue;
        var duplicate = false;
        for (values.items) |old| if (std.mem.eql(u8, old.name, found.name)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try values.append(a, found);
    }
    return values.items;
}

test "aarch64 split pieces assemble most-significant first and vector pieces are refused" {
    // Piece rows as the 0.1.8 producer exports them for an AAPCS64 16-byte
    // aggregate (x1 high, x0 low) and for an HFA float pair (z1/z0).
    const a = std.testing.allocator;
    var registers: location.RegisterSet = @splat(null);
    registers[Arch.aarch64.registerNumber("x0").?] = 0x1111222233331e1e;
    registers[Arch.aarch64.registerNumber("x1").?] = 0x555566667777e2e2;
    registers[Arch.aarch64.registerNumber("x6").?] = 0xfedcba987654684a;
    registers[Arch.aarch64.registerNumber("x7").?] = 0x0123456789ac2849;
    const pair = [_]host.PseudoPiece{
        .{ .storage = "register", .size = 8, .value_bit_offset = 64, .register = "x1" },
        .{ .storage = "register", .size = 8, .value_bit_offset = 0, .register = "x0" },
    };
    const late = [_]host.PseudoPiece{
        .{ .storage = "register", .size = 8, .value_bit_offset = 64, .register = "x7" },
        .{ .storage = "register", .size = 8, .value_bit_offset = 0, .register = "x6" },
    };
    const floats = [_]host.PseudoPiece{
        .{ .storage = "register", .size = 4, .value_bit_offset = 32, .register = "z1" },
        .{ .storage = "register", .size = 4, .value_bit_offset = 0, .register = "z0" },
    };
    const base: host.PseudoVariable = .{ .name = "v", .type_name = "r6_two", .size = 16, .parameter = true, .storage = "split", .register = null, .register_bit_offset = 0, .storage_offset = null, .valid_start = 0x1000, .valid_end = 0x1010 };
    var variable = base;
    variable.pieces = &pair;
    const two = (try value(a, .aarch64, registers, null, null, 0x1004, variable)).?;
    defer a.free(two.display);
    try std.testing.expectEqualStrings("0x555566667777e2e21111222233331e1e", two.display);
    try std.testing.expect((try value(a, .aarch64, registers, null, null, 0x1010, variable)) == null);
    variable.pieces = &late;
    const wide = (try value(a, .aarch64, registers, null, null, 0x1000, variable)).?;
    defer a.free(wide.display);
    try std.testing.expectEqualStrings("0x123456789ac2849fedcba987654684a", wide.display);
    variable.size = 8;
    variable.pieces = &floats;
    try std.testing.expect((try value(a, .aarch64, registers, null, null, 0x1000, variable)) == null);
    // x86-64 vector pieces (ZMM0/ZMM1 for a double pair) are not GPRs either.
    const doubles = [_]host.PseudoPiece{
        .{ .storage = "register", .size = 8, .value_bit_offset = 64, .register = "ZMM1" },
        .{ .storage = "register", .size = 8, .value_bit_offset = 0, .register = "ZMM0" },
    };
    variable.size = 16;
    variable.pieces = &doubles;
    try std.testing.expect((try value(a, .x86_64, registers, null, null, 0x1000, variable)) == null);
}

test "stack parameters require ABI verification and aggregate padding is hidden" {
    const a = std.testing.allocator;
    const Memory = struct {
        fn read(_: *anyopaque, address: u64, bytes: []u8) !usize {
            if (address != 0x8000 or bytes.len != 8) return error.UnexpectedRead;
            @memcpy(bytes, &[_]u8{ 7, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0xdd });
            return bytes.len;
        }
    };
    var context: u8 = 0;
    const registers: location.RegisterSet = @splat(null);
    const stack = [_]host.PseudoPiece{.{ .storage = "stack", .size = 8, .value_bit_offset = 0, .cfa_offset = 0 }};
    const hidden = [_]host.PseudoPadding{.{ .offset = 4, .size = 4 }};
    var variable: host.PseudoVariable = .{
        .name = "seventh",
        .type_name = "owned_pad",
        .size = 8,
        .parameter = true,
        .storage = "stack",
        .register = null,
        .register_bit_offset = 0,
        .storage_offset = null,
        .valid_start = 0x1000,
        .valid_end = 0x1010,
        .pieces = &stack,
        .padding = &hidden,
    };
    try std.testing.expect((try value(a, .x86_64, registers, 0x8000, .{ .user = &context, .read = Memory.read }, 0x1000, variable)) == null);
    variable.stack_parameter_verified = true;
    const found = (try value(a, .x86_64, registers, 0x8000, .{ .user = &context, .read = Memory.read }, 0x1000, variable)).?;
    defer a.free(found.display);
    try std.testing.expectEqualStrings("0x????????00000007", found.display);
}
