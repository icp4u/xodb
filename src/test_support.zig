//! Explicit CI exclusion, never a fallback after a failed capability probe.
const std = @import("std");
const c = @import("c.zig").api;

pub fn requireLive() !void {
    const value = c.getenv("XODB_TEST_NO_LIVE") orelse return;
    if (std.mem.eql(u8, std.mem.span(value), "1")) return error.SkipZigTest;
}
