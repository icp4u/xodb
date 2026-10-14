//! Keep an initialized GUI session alive through renderer loss and retries.
const std = @import("std");
const log = @import("../log.zig");
pub const Recovery = struct {
    ready: bool = false,
    initialized: bool = false,
    retry_at: u64 = 0,
    last_error: ?anyerror = null,

    pub fn init(self: *Recovery, renderer: anytype, window: anytype, now: u64) !bool {
        if (self.ready) return true;
        if (now < self.retry_at) return false;
        renderer.init(window) catch |err| {
            self.last_error = err;
            // A bad startup request needs correction; after a successful init,
            // a missing device may be temporary (reset or driver reload).
            if (!self.initialized and (err == error.VulkanDeviceNotFound or err == error.VulkanDeviceCannotPresent)) return err;
            self.retry_at = now +| 1_000_000_000;
            log.err(.render, "Renderer initialization failed: {s}; retrying, session retained\n", .{@errorName(err)});
            return false;
        };
        self.ready = true;
        self.initialized = true;
        self.last_error = null;
        return true;
    }
    pub fn lost(self: *Recovery, renderer: anytype, now: u64) void {
        renderer.deinit();
        self.ready = false;
        self.retry_at = now +| 1_000_000_000;
    }
};

// Fast component lane: scripted failures exercise the exact helper all GUI
// loops call, without requiring a physical device reset.
test "renderer loss retains the session and retries pinned devices" {
    const Fake = struct {
        calls: usize = 0,
        destroyed: usize = 0,
        failure: ?anyerror = null,
        fn init(self: *@This(), _: ?*anyopaque) !void {
            self.calls += 1;
            if (self.failure) |err| return err;
        }
        fn deinit(self: *@This()) void {
            self.destroyed += 1;
        }
    };
    for ([_]anyerror{ error.VulkanDeviceNotFound, error.VulkanDeviceCannotPresent }) |err| {
        var renderer = Fake{ .failure = err };
        var state = Recovery{};
        try std.testing.expectError(err, state.init(&renderer, null, 0));
        renderer.failure = error.VulkanFailed;
        try std.testing.expect(!try state.init(&renderer, null, 0));
        renderer.failure = null;
        try std.testing.expect(!try state.init(&renderer, null, state.retry_at - 1));
        try std.testing.expectEqual(@as(usize, 2), renderer.calls);
        try std.testing.expect(try state.init(&renderer, null, state.retry_at));
        state.lost(&renderer, state.retry_at);
        try std.testing.expectEqual(@as(usize, 1), renderer.destroyed);
        renderer.failure = err;
        try std.testing.expect(!try state.init(&renderer, null, state.retry_at));
        try std.testing.expect(state.initialized and !state.ready);
        renderer.failure = null;
        try std.testing.expect(try state.init(&renderer, null, state.retry_at));
        try std.testing.expect(state.ready and state.last_error == null);
    }
}
