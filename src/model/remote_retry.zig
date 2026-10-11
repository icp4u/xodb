//! Retry policy for one immutable inspection/preparation key. Unknown errors
//! are refusals until the selection or source state changes; they are never
//! guessed retryable from a diagnostic string.
const std = @import("std");

pub const Retry = struct {
    key: ?u64 = null,
    failure: ?anyerror = null,
    attempts: u8 = 0,
    after_ns: u64 = 0,

    pub fn ready(self: *Retry, key: u64, now: u64) bool {
        if (self.key != key) self.* = .{ .key = key };
        const err = self.failure orelse return true;
        return retryable(err) and now >= self.after_ns;
    }
    pub fn failed(self: *Retry, key: u64, err: anyerror, now: u64) void {
        if (self.key != key or self.failure == null or self.failure.? != err) self.* = .{ .key = key };
        self.failure = err;
        self.attempts +|= 1;
        const shift: u6 = @intCast(@min(self.attempts - 1, 4));
        self.after_ns = now +| (@as(u64, 250 * std.time.ns_per_ms) << shift);
    }
    pub fn clear(self: *Retry) void {
        self.* = .{};
    }
};
fn retryable(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.Busy,
        error.QueueFull,
        error.StaleSnapshot,
        error.DiscoveryPending,
        error.DebugMetadataPending,
        error.PeMetadataPending,
        error.SourceFetchPending,
        error.SymbolDiscoveryPending,
        => true,
        else => false,
    };
}

test "persistent preparation failures are paced, bounded and reset by a new key" {
    var retry: Retry = .{};
    var requests: usize = 0;
    var time: u64 = 0;
    while (time < 60 * std.time.ns_per_s) : (time += 2 * std.time.ns_per_ms) {
        if (!retry.ready(1, time)) continue;
        requests += 1;
        retry.failed(1, error.OutOfMemory, time);
    }
    // Thirty thousand owner ticks produce only the exponential ramp followed
    // by one retry per maximum interval. This uses a logical clock, not load.
    try std.testing.expectEqual(@as(usize, 19), requests);
    try std.testing.expect(retry.ready(2, time));
    try std.testing.expect(retry.failure == null);
}
test "permanent refusal persists across frames and resets on selection or explicit retry" {
    var retry: Retry = .{};
    retry.failed(1, error.TooLarge, 0);
    try std.testing.expect(!retry.ready(1, std.math.maxInt(u64)));
    try std.testing.expectEqual(error.TooLarge, retry.failure.?);
    try std.testing.expect(retry.ready(2, 0));
    retry.failed(2, error.RemoteOutcomeUnknown, 0);
    try std.testing.expect(!retry.ready(2, std.math.maxInt(u64)));
    retry.clear();
    try std.testing.expect(retry.ready(2, 0));
}
test "retry delay survives repeated frames and has a saturating deadline" {
    var retry: Retry = .{};
    retry.failed(1, error.DebugMetadataPending, 1);
    for (0..500) |_| try std.testing.expect(!retry.ready(1, 2));
    try std.testing.expectEqual(@as(u8, 1), retry.attempts);
    const deadline = retry.after_ns;
    try std.testing.expect(!retry.ready(1, deadline - 1));
    try std.testing.expect(retry.ready(1, deadline));
    retry.failed(1, error.DebugMetadataPending, std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64), retry.after_ns);
}

// Requests include viewport coordinates. Hash floats by representation and
// slices by content; addresses and padding must not turn an unchanged viewport
// into another remote inspection on every frame.
pub fn hashValue(hash: *std.hash.Wyhash, value: anytype) void {
    switch (@typeInfo(@TypeOf(value))) {
        .float => std.hash.autoHash(hash, @as(std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(value))), @bitCast(value))),
        .pointer => {
            std.hash.autoHash(hash, value.len);
            for (value) |item| hashValue(hash, item);
        },
        .optional => {
            std.hash.autoHash(hash, value != null);
            if (value) |item| hashValue(hash, item);
        },
        .@"struct" => |structure| inline for (structure.fields) |field| hashValue(hash, @field(value, field.name)),
        .@"union" => {
            std.hash.autoHash(hash, std.meta.activeTag(value));
            switch (value) {
                inline else => |item| hashValue(hash, item),
            }
        },
        .array => for (value) |item| hashValue(hash, item),
        else => std.hash.autoHash(hash, value),
    }
}
