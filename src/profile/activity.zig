//! Independent CPU accounting for explaining a sparse user-space sample set.
//! These are start/stop procfs snapshots, not weighted samples or wait traces.
const std = @import("std");
const rt = @import("runtime.zig").c;
const c = @import("linux_perf.zig").c;
pub const Ticks = struct { start_time: u64, user: u64, kernel: u64 };
pub const Totals = struct {
    user_ticks: u64 = 0,
    kernel_ticks: u64 = 0,
    available_threads: u16 = 0,
    unavailable_threads: u16 = 0,

    pub fn add(self: *Totals, before: ?Ticks, after: ?Ticks) void {
        if (before == null or after == null or before.?.start_time != after.?.start_time or after.?.user < before.?.user or after.?.kernel < before.?.kernel) {
            self.unavailable_threads += 1;
            return;
        }
        self.user_ticks +|= after.?.user - before.?.user;
        self.kernel_ticks +|= after.?.kernel - before.?.kernel;
        self.available_threads += 1;
    }
    pub fn summary(self: Totals, tick_hz: u64) Summary {
        return .{
            .user_ms = if (self.available_threads > 0 and tick_hz > 0) milliseconds(self.user_ticks, tick_hz) else null,
            .kernel_ms = if (self.available_threads > 0 and tick_hz > 0) milliseconds(self.kernel_ticks, tick_hz) else null,
            .available_threads = self.available_threads,
            .unavailable_threads = self.unavailable_threads,
            .ticks_per_second = tick_hz,
            .complete = self.available_threads > 0 and self.unavailable_threads == 0 and tick_hz > 0,
        };
    }
};
pub const Summary = struct {
    user_ms: ?u64,
    kernel_ms: ?u64,
    available_threads: u16,
    unavailable_threads: u16,
    ticks_per_second: u64,
    complete: bool,
    basis: []const u8 = "selected-thread procfs snapshots at capture start/stop; approximate interval and tick granularity; user includes guest CPU; no off-CPU attribution",
};
fn milliseconds(ticks: u64, hz: u64) u64 {
    return @intCast(@min(std.math.maxInt(u64), @as(u128, ticks) * 1000 / hz));
}
pub fn ticksPerSecond() u64 {
    const hz = c.sysconf(c._SC_CLK_TCK);
    return if (hz > 0) @intCast(hz) else 0;
}
pub fn read(pid: i32, tid: i32) ?Ticks {
    return readTarget(null, pid, tid);
}
pub fn readTarget(target: ?*const rt.struct_xrt_target, pid: i32, tid: i32) ?Ticks {
    // /proc/PID/stat aggregates a thread group. This path gives only the selected
    // task, including when TID == PID, avoiding double-counting the leader.
    const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_THREAD_STAT, .tid = tid });
    var fd: c_int = -1;
    const status = if (target) |t| rt.xrt_target_file(t, &request, &fd) else rt.xrt_process_file(pid, &request, &fd);
    if (status != rt.XRT_OK) return null;
    defer _ = c.close(fd);
    var bytes: [2048]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0 or n == bytes.len) return null;
    return parse(bytes[0..@intCast(n)]);
}
pub fn parse(bytes: []const u8) ?Ticks {
    const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return null;
    var fields = std.mem.tokenizeAny(u8, bytes[end + 1 ..], " \n\t");
    var result: Ticks = undefined;
    for (0..20) |i| {
        const field = fields.next() orelse return null;
        switch (i) {
            11 => result.user = std.fmt.parseInt(u64, field, 10) catch return null,
            12 => result.kernel = std.fmt.parseInt(u64, field, 10) catch return null,
            19 => result.start_time = std.fmt.parseInt(u64, field, 10) catch return null,
            else => {},
        }
    }
    return result;
}

test "CPU counters handle task names and reject reuse, missing tasks, or regressions" {
    const tick = parse("123 (a name ) with spaces) S 0 0 0 0 0 0 0 0 0 0 14 15 0 0 0 0 1 0 22 0").?;
    try std.testing.expectEqual(Ticks{ .user = 14, .kernel = 15, .start_time = 22 }, tick);
    try std.testing.expect(parse("123 (truncated) S 0") == null);
    var totals = Totals{};
    totals.add(tick, .{ .user = 24, .kernel = 45, .start_time = 22 });
    totals.add(tick, .{ .user = 24, .kernel = 45, .start_time = 23 });
    totals.add(tick, null);
    totals.add(tick, .{ .user = 2, .kernel = 45, .start_time = 22 });
    const result = totals.summary(100);
    try std.testing.expectEqual(@as(?u64, 100), result.user_ms);
    try std.testing.expectEqual(@as(?u64, 300), result.kernel_ms);
    try std.testing.expectEqual(@as(u16, 3), result.unavailable_threads);
    try std.testing.expect(!result.complete);
    try std.testing.expect((Totals{}).summary(100).user_ms == null);
}
