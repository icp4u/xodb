//! Test fixture layout for inspecting/injecting kernel ARM64 debug registers.
//! Production control encoding and regset validation live in runtime/watchpoints.c.
const std = @import("std");
pub const note = 0x403; // NT_ARM_HW_WATCH, Linux UAPI
pub const Register = extern struct { address: u64 = 0, control: u32 = 0, pad: u32 = 0 };
pub const State = extern struct { info: u32 = 0, pad: u32 = 0, registers: [16]Register = @splat(.{}) };
pub fn count(state: State, size: usize) !u8 {
    const n: u8 = @truncate(state.info);
    if (n > 16 or size < 8 + @as(usize, n) * 16) return error.UnexpectedWatchRegisterSize;
    return n;
}
test "ARM watch test regset validates kernel lengths" {
    try std.testing.expectError(error.UnexpectedWatchRegisterSize, count(.{ .info = 17 }, 264));
    try std.testing.expectError(error.UnexpectedWatchRegisterSize, count(.{ .info = 4 }, 24));
    try std.testing.expectEqual(@as(u8, 4), try count(.{ .info = 4 }, 72));
}
