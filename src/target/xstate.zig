//! Linux x86-64 floating point and vector state. Read-only, native-host layout.
const std = @import("std");
const c = @import("../c.zig").api;
extern fn xodb_xstate_features() u64;
extern fn xodb_xstate_component(component: c_uint, offset: *c_uint, size: *c_uint) c_int;
pub const State = struct {
    source: enum { xstate, fpregs } = .xstate,
    features: u64 = 3,
    in_use: u64 = 3,
    vector_bytes: usize = 16,
    vector_count: usize = 16,
    vectors: [32][64]u8 = @splat(@splat(0)),
    st: [8][10]u8 = @splat(@splat(0)),
    st_valid: [8]bool = @splat(false),
    masks: [8]u64 = @splat(0),
    mxcsr: u32 = 0,
    control: u16 = 0,
    status: u16 = 0,
};
fn component(bytes: []const u8, number: u32, needed: usize) ![]const u8 {
    var offset: c_uint = 0;
    var size: c_uint = 0;
    if (xodb_xstate_component(number, &offset, &size) == 0 or size < needed or offset < 576 or offset > bytes.len or needed > bytes.len - offset) return error.XstateComponentUnavailable;
    return bytes[offset..][0..needed];
}
pub fn read(tid: i32) !State {
    if (@import("arch.zig").native != .x86_64) return error.ExtendedRegistersUnsupportedArchitecture;
    var bytes: [65536]u8 align(64) = undefined;
    var io = c.iovec{ .iov_base = &bytes, .iov_len = bytes.len };
    var result: State = .{};
    if (c.ptrace(c.PTRACE_GETREGSET, tid, @as(usize, 0x202), @intFromPtr(&io)) < 0) {
        const err = std.c._errno().*;
        if (err != c.EINVAL and err != c.EIO and err != c.ENODEV) return error.ExtendedRegistersUnavailable;
        io.iov_len = 512;
        if (c.ptrace(c.PTRACE_GETREGSET, tid, @as(usize, 2), @intFromPtr(&io)) < 0) return error.ExtendedRegistersUnavailable;
        result.source = .fpregs;
    }
    if (io.iov_len < 512 or io.iov_len > bytes.len) return error.InvalidXstateSize;
    const raw = bytes[0..io.iov_len];
    const source = result.source;
    result = try decodeLegacy(raw);
    result.source = source;
    if (result.source == .fpregs) return result;
    if (raw.len < 576 or std.mem.readInt(u64, raw[520..528], .little) != 0) return error.InvalidXstateHeader;
    result.features = xodb_xstate_features();
    result.in_use = std.mem.readInt(u64, raw[512..520], .little);
    if (result.features & 4 != 0) {
        const upper = try component(raw, 2, 256);
        for (0..16) |i| @memcpy(result.vectors[i][16..32], upper[i * 16 ..][0..16]);
        result.vector_bytes = 32;
    }
    if (result.features & 0xe0 == 0xe0) {
        const masks = try component(raw, 5, 64);
        const upper = try component(raw, 6, 512);
        const high = try component(raw, 7, 1024);
        for (0..8) |i| result.masks[i] = std.mem.readInt(u64, masks[i * 8 ..][0..8], .little);
        for (0..16) |i| {
            @memcpy(result.vectors[i][32..64], upper[i * 32 ..][0..32]);
            @memcpy(&result.vectors[i + 16], high[i * 64 ..][0..64]);
        }
        result.vector_bytes = 64;
        result.vector_count = 32;
    }
    return result;
}
/// Only the architectural FXSAVE area is portable between core producer CPUs.
pub fn decodeLegacy(raw: []const u8) !State {
    if (raw.len < 512) return error.InvalidXstateSize;
    var result = State{ .source = .fpregs };
    result.control = std.mem.readInt(u16, raw[0..2], .little);
    result.status = std.mem.readInt(u16, raw[2..4], .little);
    result.mxcsr = std.mem.readInt(u32, raw[24..28], .little);
    const top = (result.status >> 11) & 7;
    for (&result.st, &result.st_valid, 0..) |*value, *valid, i| {
        @memcpy(value, raw[32 + i * 16 ..][0..10]);
        valid.* = (raw[4] & (@as(u8, 1) << @as(u3, @intCast((top + i) % 8)))) != 0;
    }
    for (0..16) |i| @memcpy(result.vectors[i][0..16], raw[160 + i * 16 ..][0..16]);
    return result;
}
pub const Format = enum { hex, f32, f64, i32, u32, u64 };
pub fn lanes(a: std.mem.Allocator, bytes: []const u8, format: Format) ![][]const u8 {
    const width: usize = if (format == .f64 or format == .u64 or format == .hex) 8 else 4;
    const out = try a.alloc([]const u8, bytes.len / width);
    for (out, 0..) |*item, i| {
        const lane = bytes[i * width ..][0..width];
        item.* = switch (format) {
            .f32 => try std.fmt.allocPrint(a, "{e}", .{@as(f32, @bitCast(std.mem.readInt(u32, lane[0..4], .little)))}),
            .f64 => try std.fmt.allocPrint(a, "{e}", .{@as(f64, @bitCast(std.mem.readInt(u64, lane[0..8], .little)))}),
            .i32 => try std.fmt.allocPrint(a, "{d}", .{std.mem.readInt(i32, lane[0..4], .little)}),
            .u32 => try std.fmt.allocPrint(a, "{d}", .{std.mem.readInt(u32, lane[0..4], .little)}),
            .u64 => try std.fmt.allocPrint(a, "{d}", .{std.mem.readInt(u64, lane[0..8], .little)}),
            .hex => try std.fmt.allocPrint(a, "0x{x:0>16}", .{std.mem.readInt(u64, lane[0..8], .little)}),
        };
    }
    return out;
}
