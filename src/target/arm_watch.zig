//! Linux ARM64 hardware data-watch regset. Keep requested controls: kernel
//! readback can normalize addresses/BAS and need not round-trip enable bits.
const std = @import("std");
const bp = @import("breakpoints.zig");
pub const note = 0x403; // NT_ARM_HW_WATCH, Linux UAPI
pub const Register = extern struct { address: u64 = 0, control: u32 = 0, pad: u32 = 0 };
pub const State = extern struct { info: u32 = 0, pad: u32 = 0, registers: [16]Register = @splat(.{}) };
pub fn count(state: State, size: usize) !u8 {
    const n: u8 = @truncate(state.info);
    if (n > 16 or size < 8 + @as(usize, n) * 16) return error.UnexpectedWatchRegisterSize;
    return n;
}
pub fn request(slots: u8, watches: [4]?bp.Watchpoint, enabled: bool) State {
    var out = State{ .info = slots };
    if (enabled) for (watches, 0..) |maybe, index| {
        if (maybe) |watch| {
            std.debug.assert(index < slots and watch.kind != .execute);
            const bas = (@as(u32, 1) << @intCast(watch.length)) - 1;
            const access: u32 = if (watch.kind == .write) 2 else 3;
            out.registers[index] = .{ .address = watch.address, .control = 1 | (access << 3) | (bas << 5) };
        }
    };
    return out;
}
test "ARM watch requests retain logical offsets, kinds and lengths" {
    for ([_]u8{ 1, 2, 4, 8 }) |length| {
        var offset: u64 = 0;
        while (offset < 8) : (offset += length) {
            const watch = bp.Watchpoint{ .id = 1, .address = 0x1000 + offset, .length = length, .kind = .write };
            const out = request(4, .{ watch, null, null, null }, true);
            try std.testing.expectEqual(watch.address, out.registers[0].address);
            try std.testing.expectEqual(@as(u32, 0x11) | (((@as(u32, 1) << @intCast(length)) - 1) << 5), out.registers[0].control);
            try std.testing.expectEqual(@as(u32, 0), request(4, .{ watch, null, null, null }, false).registers[0].control);
        }
    }
    try std.testing.expectError(error.UnexpectedWatchRegisterSize, count(.{ .info = 17 }, 264));
    try std.testing.expectError(error.UnexpectedWatchRegisterSize, count(.{ .info = 4 }, 24));
}
