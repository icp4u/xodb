//! Exclusive startup phases shared by the window backends and Vulkan.
//! Only the first sample of each phase is kept. A phase that never ends
//! contributes 0. Durations are microseconds.
const std = @import("std");

pub const Phase = enum { connect, window, instance, device, swapchain, draw };
const count = @typeInfo(Phase).@"enum".fields.len;

var began: [count]u64 = @splat(0);
var open: [count]bool = @splat(false);
var done: [count]bool = @splat(false);
var micros: [count]u64 = @splat(0);

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn begin(phase: Phase) void {
    const i = @intFromEnum(phase);
    if (done[i] or open[i]) return;
    began[i] = now();
    open[i] = true;
}

pub fn end(phase: Phase) void {
    const i = @intFromEnum(phase);
    if (done[i] or !open[i]) return;
    micros[i] = (now() -| began[i]) / std.time.ns_per_us;
    open[i] = false;
    done[i] = true;
}

pub fn finished(phase: Phase) bool {
    return done[@intFromEnum(phase)];
}

pub fn microseconds(phase: Phase) u64 {
    return micros[@intFromEnum(phase)];
}

test "the first sample of a startup phase is the one that sticks" {
    begin(.connect);
    end(.connect);
    const first = microseconds(.connect);
    begin(.connect);
    end(.connect);
    try std.testing.expectEqual(first, microseconds(.connect));
    try std.testing.expect(finished(.connect));
    try std.testing.expect(!finished(.draw));
    try std.testing.expectEqual(@as(u64, 0), microseconds(.draw));
}
