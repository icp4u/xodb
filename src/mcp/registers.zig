const std = @import("std");
const xstate = @import("../target/xstate.zig");
const wire = @import("profile.zig");
const Session = @import("../model/session.zig").Session;
pub fn call(a: std.mem.Allocator, session: *Session, args: std.json.Value) !std.json.Value {
    try wire.fields(args, &.{ "tid", "generation", "format", "width" });
    if (session.offline) return error.OfflineSession;
    const generation = try wire.number(args, "generation", session.target.generation);
    if (generation != session.target.generation) return error.StaleSnapshot;
    const tid = try wire.number(args, "tid", null);
    if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
    const state = try session.target.extendedRegisters(@intCast(tid));
    var format: xstate.Format = .hex;
    if (args.object.get("format")) |value| {
        if (value != .string) return error.InvalidArguments;
        format = std.meta.stringToEnum(xstate.Format, value.string) orelse return error.InvalidArguments;
    }
    const width = std.math.cast(usize, try wire.number(args, "width", state.vector_bytes * 8)) orelse return error.InvalidArguments;
    if (width != 128 and width != 256 and width != 512) return error.InvalidArguments;
    if (width > state.vector_bytes * 8) return error.VectorWidthUnavailable;
    const Row = struct { name: []const u8, hex: []const u8, lanes: [][]const u8 };
    const rows = try a.alloc(Row, state.vector_count);
    for (rows, 0..) |*row, i| {
        const bytes = state.vectors[i][0 .. width / 8];
        const hex = try a.alloc(u8, bytes.len * 2);
        const digits = "0123456789abcdef";
        for (bytes, 0..) |byte, j| {
            hex[j * 2] = digits[byte >> 4];
            hex[j * 2 + 1] = digits[byte & 15];
        }
        row.* = .{ .name = try std.fmt.allocPrint(a, "{s}{d}", .{ if (width == 128) "xmm" else if (width == 256) "ymm" else "zmm", i }), .hex = hex, .lanes = try xstate.lanes(a, bytes, format) };
    }
    const FP = struct { name: []const u8, valid: bool, hex: []const u8, value: ?[]const u8 };
    const fp = try a.alloc(FP, 8);
    for (fp, 0..) |*row, i| {
        const bits = std.mem.readInt(u80, &state.st[i], .little);
        row.* = .{ .name = try std.fmt.allocPrint(a, "st{d}", .{i}), .valid = state.st_valid[i], .hex = try std.fmt.allocPrint(a, "0x{x:0>20}", .{bits}), .value = if (state.st_valid[i]) try std.fmt.allocPrint(a, "{d}", .{@as(f80, @bitCast(bits))}) else null };
    }
    var masks: [8][]const u8 = undefined;
    for (&masks, state.masks) |*value, bits| value.* = try std.fmt.allocPrint(a, "0x{x:0>16}", .{bits});
    return wire.value(a, .{ .generation = generation, .tid = tid, .source = state.source, .features = try std.fmt.allocPrint(a, "0x{x}", .{state.features}), .in_use = try std.fmt.allocPrint(a, "0x{x}", .{state.in_use}), .width = width, .format = format, .lane_order = "least significant first", .hex_order = "memory byte order", .vectors = rows, .x87 = fp, .mxcsr = state.mxcsr, .x87_control = state.control, .x87_status = state.status, .opmask = if (state.vector_bytes == 64) @as(?[]const []const u8, &masks) else null });
}
