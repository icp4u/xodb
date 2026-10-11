//! Keep a failed optional scene from rebuilding its GPU resources every frame.
const std = @import("std");
pub const Retry = struct {
    next: u64 = 0,
    delay: u64 = 250 * std.time.ns_per_ms,
    reason: ?anyerror = null,
    pub fn waiting(self: *const Retry, now: u64) ?anyerror {
        return if (now < self.next) self.reason else null;
    }
    pub fn failed(self: *Retry, now: u64, reason: anyerror) void {
        self.reason = reason;
        self.next = now +| self.delay;
        self.delay = @min(self.delay * 2, 4 * std.time.ns_per_s);
    }
};

test "scene retries back off, remain typed, and reset after recovery" {
    var retry = Retry{};
    var now: u64 = 1;
    for (0..10) |_| {
        try std.testing.expect(retry.waiting(now) == null);
        const delay = retry.delay;
        retry.failed(now, error.OutOfMemory);
        try std.testing.expectEqual(error.OutOfMemory, retry.waiting(now).?);
        try std.testing.expectEqual(error.OutOfMemory, retry.waiting(now + delay - 1).?);
        now += delay;
        try std.testing.expect(retry.waiting(now) == null);
        try std.testing.expect(retry.delay <= 4 * std.time.ns_per_s);
    }
    retry = .{};
    try std.testing.expect(retry.waiting(now) == null);
    try std.testing.expectEqual(@as(u64, 250 * std.time.ns_per_ms), retry.delay);
}
