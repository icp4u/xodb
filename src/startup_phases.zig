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
var ended: [count]u64 = @splat(0);

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
    ended[i] = now();
    micros[i] = (ended[i] -| began[i]) / std.time.ns_per_us;
    open[i] = false;
    done[i] = true;
}

pub fn finished(phase: Phase) bool {
    return done[@intFromEnum(phase)];
}

pub fn microseconds(phase: Phase) u64 {
    return micros[@intFromEnum(phase)];
}

/// XODB_STARTUP_TRACE=FILE appends absolute CLOCK_MONOTONIC nanoseconds for
/// an external benchmark (scripts/startup-bench): one `present` line at the
/// first accepted present, and one `onscreen` line when the compositor's
/// presentation feedback for that frame arrives. Unset, nothing is recorded.
pub fn tracing() bool {
    return std.c.getenv("XODB_STARTUP_TRACE") != null;
}
fn traceAppend(line: []const u8) void {
    const path = std.c.getenv("XODB_STARTUP_TRACE") orelse return;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    _ = std.c.write(fd, line.ptr, line.len);
    _ = std.c.close(fd);
}
pub fn tracePresent(main_ns: u64) void {
    if (!tracing()) return;
    const w = @intFromEnum(Phase.window);
    const d = @intFromEnum(Phase.draw);
    var buffer: [768]u8 = undefined;
    var used = (std.fmt.bufPrint(&buffer, "present main={d} configured={d} present={d} connect={d} window={d} instance={d} device={d} swapchain={d} draw={d}", .{
        main_ns, ended[w], ended[d], micros[0], micros[1], micros[2], micros[3], micros[4], micros[5],
    }) catch return).len;
    // Absolute phase starts: the gaps between phases are the unnamed work.
    inline for (@typeInfo(Phase).@"enum".fields, 0..) |field, i| {
        used += (std.fmt.bufPrint(buffer[used..], " {s}_at={d}", .{ field.name, began[i] }) catch return).len;
    }
    buffer[used] = '\n';
    traceAppend(buffer[0 .. used + 1]);
}
/// `shown` is the compositor's presentation time in `clock` (sway: MONOTONIC);
/// `received` is when the feedback event was read; `frame` counts from 1.
pub fn traceOnscreen(shown: u64, clock: u32, refresh: u32, received: u64, frame: u32) void {
    var buffer: [192]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "onscreen shown={d} clock={d} refresh={d} received={d} frame={d}\n", .{ shown, clock, refresh, received, frame }) catch return;
    traceAppend(line);
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
