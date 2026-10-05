//! Host presentation of the C runtime's normalized floating-point/vector state.
const std = @import("std");
const runtime = @import("runtime.zig");
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
pub fn fromRuntime(raw: runtime.c.struct_xrt_xstate) State {
    return .{ .source = @enumFromInt(raw.source), .features = raw.features, .in_use = raw.in_use, .vector_bytes = raw.vector_bytes, .vector_count = raw.vector_count, .vectors = raw.vectors, .st = raw.st, .st_valid = raw.st_valid, .masks = raw.masks, .mxcsr = raw.mxcsr, .control = raw.control, .status = raw.status };
}
pub fn decodeLegacy(bytes: []const u8) !State {
    var out: runtime.c.struct_xrt_xstate = undefined;
    try runtime.check(runtime.c.xrt_xstate_decode_legacy(bytes.ptr, bytes.len, &out));
    return fromRuntime(out);
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
