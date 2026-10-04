const std = @import("std");
const Mode = enum(i16) { idle = -2, busy = 7 };
const Big = enum(u64) { high = 0x8000000000000001 };
const Pair = struct { left: i32, right: u64 };
export fn value_checkpoint() void {
    asm volatile ("" ::: .{ .memory = true });
}
pub fn main() void {
    var numbers = [_]i32{ 11, -22, 33, 44 };
    const slice: []const i32 = numbers[1..];
    const text: []const u8 = "hello λ\nworld";
    const empty: []const i32 = &.{};
    const mode: Mode = .idle;
    const high: Big = .high;
    var pair: Pair = .{ .left = -17, .right = 9001 };
    const bytes: []const u8 = &.{ 0, 255, 65 };
    std.mem.doNotOptimizeAway(&numbers);
    std.mem.doNotOptimizeAway(&slice);
    std.mem.doNotOptimizeAway(&text);
    std.mem.doNotOptimizeAway(&empty);
    std.mem.doNotOptimizeAway(&mode);
    std.mem.doNotOptimizeAway(&high);
    std.mem.doNotOptimizeAway(&pair);
    std.mem.doNotOptimizeAway(&bytes);
    value_checkpoint();
    std.mem.doNotOptimizeAway(&numbers);
}
