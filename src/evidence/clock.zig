//! Clock domains and the mapping between them, with stated uncertainty.
//!
//! A stream declares the clock its times are in. Capture archives keep
//! CLOCK_MONOTONIC; pcap and pcapng files keep CLOCK_REALTIME. A `Mapping`
//! carries realtime into the capture's monotonic clock from paired samples
//! (monotonic read, realtime read, monotonic read) taken by the collector.
//! Without such pairs the mapping is `unaligned`: times stay in their own
//! domain and are never shown on the capture's axis.
const std = @import("std");

pub const Domain = enum(u8) {
    realtime,
    monotonic,
    /// A device or hardware clock, comparable only within one stream.
    device,
    unknown,
};

/// One bracketed sample: `realtime_ns` was read between the two monotonic reads.
pub const Pair = struct { monotonic_before_ns: u64, realtime_ns: u64, monotonic_after_ns: u64 };

pub const State = enum(u8) { aligned, unaligned };
pub const Mapping = struct {
    state: State = .unaligned,
    from: Domain = .realtime,
    to: Domain = .monotonic,
    /// to = from + offset_ns.
    offset_ns: i128 = 0,
    /// Half the narrowest bracket, plus any disagreement between pairs.
    uncertainty_ns: u64 = 0,
    pairs: u32 = 0,
    /// Largest difference between the offsets the pairs give (realtime steps
    /// or slew during the capture). Zero with one pair: drift is not measured.
    spread_ns: u64 = 0,
    reason: []const u8 = "no paired realtime/monotonic samples",

    pub const Mapped = struct { ns: u64, uncertainty_ns: u64 };
    pub fn map(self: Mapping, t: u64) ?Mapped {
        if (self.state != .aligned) return null;
        const v = @as(i128, t) + self.offset_ns;
        if (v < 0 or v > std.math.maxInt(u64)) return null;
        return .{ .ns = @intCast(v), .uncertainty_ns = self.uncertainty_ns };
    }
};

/// Realtime-to-monotonic from bracketed pairs. The narrowest bracket sets the
/// offset; every pair's disagreement with it is added to the uncertainty, so a
/// realtime step during the capture widens the result instead of hiding.
pub fn fromPairs(pairs: []const Pair) Mapping {
    var best: ?Pair = null;
    var valid: u32 = 0;
    for (pairs) |p| {
        if (p.monotonic_after_ns < p.monotonic_before_ns) continue;
        valid += 1;
        if (best == null or width(p) < width(best.?)) best = p;
    }
    const b = best orelse return .{};
    const offset = offsetOf(b);
    var spread: u64 = 0;
    for (pairs) |p| {
        if (p.monotonic_after_ns < p.monotonic_before_ns) continue;
        const d = offsetOf(p) - offset;
        spread = @max(spread, @as(u64, @intCast(@min(@abs(d), std.math.maxInt(u64)))));
    }
    return .{ .state = .aligned, .offset_ns = offset, .uncertainty_ns = (width(b) / 2 + width(b) % 2) +| spread, .pairs = valid, .spread_ns = spread, .reason = if (valid == 1) "one paired sample; drift not measured" else "paired samples" };
}
fn width(p: Pair) u64 {
    return p.monotonic_after_ns - p.monotonic_before_ns;
}
fn offsetOf(p: Pair) i128 {
    const mid = @as(i128, p.monotonic_before_ns) + @divFloor(@as(i128, width(p)), 2);
    return mid - @as(i128, p.realtime_ns);
}

test "unaligned without pairs" {
    const m = fromPairs(&.{});
    try std.testing.expectEqual(State.unaligned, m.state);
    try std.testing.expectEqual(@as(?Mapping.Mapped, null), m.map(5));
}

test "narrowest bracket wins and disagreement widens" {
    const one = fromPairs(&.{.{ .monotonic_before_ns = 1000, .realtime_ns = 1_000_000, .monotonic_after_ns = 1010 }});
    try std.testing.expectEqual(State.aligned, one.state);
    try std.testing.expectEqual(@as(u64, 1005 + 500), one.map(1_000_500).?.ns);
    try std.testing.expectEqual(@as(u64, 5), one.uncertainty_ns);
    const two = fromPairs(&.{
        .{ .monotonic_before_ns = 1000, .realtime_ns = 1_000_000, .monotonic_after_ns = 1100 },
        .{ .monotonic_before_ns = 5000, .realtime_ns = 1_004_020, .monotonic_after_ns = 5002 },
    });
    // Second pair (width 2) sets offset 5001 - 1004020; first disagrees by 69.
    try std.testing.expectEqual(@as(i128, 5001 - 1_004_020), two.offset_ns);
    try std.testing.expectEqual(@as(u64, 69), two.spread_ns);
    try std.testing.expectEqual(@as(u64, 1 + 69), two.uncertainty_ns);
    // Archive pairs are untrusted: extreme brackets saturate, never overflow.
    const max = std.math.maxInt(u64);
    try std.testing.expectEqual(max / 2 + 1, fromPairs(&.{.{ .monotonic_before_ns = 0, .realtime_ns = 0, .monotonic_after_ns = max }}).uncertainty_ns);
    try std.testing.expectEqual(@as(u64, max), fromPairs(&.{ .{ .monotonic_before_ns = 0, .realtime_ns = max, .monotonic_after_ns = 0 }, .{ .monotonic_before_ns = max, .realtime_ns = 0, .monotonic_after_ns = max } }).uncertainty_ns);
    // Bad pairs are ignored.
    try std.testing.expectEqual(State.unaligned, fromPairs(&.{.{ .monotonic_before_ns = 9, .realtime_ns = 1, .monotonic_after_ns = 3 }}).state);
}
