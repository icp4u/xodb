//! The sweep planner: which 20 MHz spectral window each sensor listens to,
//! and for how long. Pure.
//!
//! One HT20 spectral window sees 20 MHz around the channel it is tuned to;
//! the 2.4 GHz band is 2400-2500 MHz. By default the windows step across
//! the band (a sweep) and the views stitch the dwells together. A focus
//! narrows the windows to a span; a span that fits one window (or a fixed
//! focus) parks the sensor there for the highest sample rate. With several
//! sensors the windows are shared out: enough sensors see the whole band at
//! once, and with a park hint one sensor stays on the blast region while the
//! others sweep. Retuning is a receive-only monitor channel change.
const std = @import("std");

pub const band_lo: u16 = 2400;
pub const band_hi: u16 = 2500;
/// Half the width of an HT20 spectral window, MHz.
pub const half: u16 = 10;
/// Edge bins of an FFT window are attenuated: interior windows overlap by twice this.
pub const edge: u16 = 2;
/// The shortest dwell that still resolves 50/60 Hz in one visit: the
/// detector wants 20 mains periods (400 ms at 50 Hz) and half a second of
/// samples, plus the settling after a retune.
pub const resolve_dwell_ms: u32 = 600;
pub const max_sensors = 4;
pub const max_windows = 14;
/// Every 2.4 GHz channel (bit c for channel c).
pub const all_channels: u16 = 0x7ffe;

pub fn channelMhz(c: u8) u16 {
    return if (c == 14) 2484 else 2407 + 5 * @as(u16, c);
}
pub fn channelOf(mhz: u16) ?u8 {
    if (mhz == 2484) return 14;
    if (mhz < 2412 or mhz > 2472 or (mhz - 2407) % 5 != 0) return null;
    return @intCast((mhz - 2407) / 5);
}

pub const Mode = enum {
    /// Step across the whole band.
    sweep,
    /// Cover a span: one window if it fits, else the span's windows in turn.
    focus,
    /// One window at the span's centre, never retuned: the highest sample rate.
    fixed,
};

pub const Request = struct {
    mode: Mode = .sweep,
    lo_mhz: u16 = band_lo,
    hi_mhz: u16 = band_hi,
    dwell_ms: u32 = resolve_dwell_ms,
    /// A window to keep one sensor on while others sweep (the blast region).
    park_mhz: ?u16 = null,
    /// Channels the sensors can be tuned to (bit c); a failed tune clears one.
    allowed: u16 = all_channels,
};

pub const Assignment = struct {
    centres: [max_windows]u16 = @splat(0),
    n: u8 = 0,
    pub fn list(self: *const Assignment) []const u16 {
        return self.centres[0..self.n];
    }
};

pub const Plan = struct {
    mode: Mode = .sweep,
    /// The span the windows cover, MHz.
    lo_mhz: u16 = 0,
    hi_mhz: u16 = 0,
    dwell_ms: u32 = resolve_dwell_ms,
    sensors: u8 = 0,
    per: [max_sensors]Assignment = @splat(.{}),
    /// The union of windows, ascending.
    windows: Assignment = .{},

    /// Longest time before a sweeping sensor comes back to a window, ms (0: all parked).
    pub fn revisitMs(self: *const Plan) u32 {
        var r: u32 = 0;
        for (self.per[0..self.sensors]) |*a| if (a.n > 1) {
            r = @max(r, @as(u32, a.n) * self.dwell_ms);
        };
        return r;
    }
    /// Share of the time each window is watched, worst case (1: continuous).
    pub fn watchShare(self: *const Plan) f32 {
        var worst: f32 = 1;
        for (self.windows.list()) |w| {
            var part: f32 = 0;
            for (self.per[0..self.sensors]) |*a| for (a.list()) |c| {
                if (c == w) part += 1 / @as(f32, @floatFromInt(a.n));
            };
            worst = @min(worst, part);
        }
        return worst;
    }
    pub fn describe(self: *const Plan, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        self.write(&w) catch {};
        return w.buffered();
    }
    fn write(self: *const Plan, w: *std.Io.Writer) !void {
        if (self.sensors == 0 or self.windows.n == 0) return w.print("no spectral sensor", .{});
        const lo = self.windows.centres[0] - half;
        const hi = self.windows.centres[self.windows.n - 1] + half;
        switch (self.mode) {
            .sweep => try w.print("sweep {d}-{d} MHz", .{ lo, hi }),
            .focus => try w.print("focus {d}-{d} MHz", .{ self.lo_mhz, self.hi_mhz }),
            .fixed => try w.print("fixed window {d}-{d} MHz", .{ lo, hi }),
        }
        try w.print(": {d} window{s} (ch ", .{ self.windows.n, if (self.windows.n == 1) "" else "s" });
        for (self.windows.list(), 0..) |c, i| try w.print("{s}{d}", .{ if (i > 0) "/" else "", channelOf(c) orelse 0 });
        try w.print(")", .{});
        if (self.sensors > 1) try w.print(" on {d} sensors", .{self.sensors});
        const r = self.revisitMs();
        if (r == 0) try w.print(", watched continuously", .{}) else try w.print(", {d} ms dwell, each revisited within {d:.1} s ({d:.0}% of the time)", .{ self.dwell_ms, @as(f32, @floatFromInt(r)) / 1000, self.watchShare() * 100 });
    }
};

/// Channel centres (ascending) whose windows cover [lo, hi], each window's
/// usable interior overlapping the next.
pub fn windows(lo: u16, hi: u16, allowed: u16, out: *[max_windows]u16) usize {
    var centres: [max_windows]u16 = undefined;
    var n_allowed: usize = 0;
    for (1..15) |c| if (allowed & (@as(u16, 1) << @intCast(c)) != 0) {
        centres[n_allowed] = channelMhz(@intCast(c));
        n_allowed += 1;
    };
    if (n_allowed == 0) return 0;
    var n: usize = 0;
    var pos = lo;
    while (n < out.len) {
        // The furthest window whose usable interior still starts at or before pos.
        var pick: ?u16 = null;
        for (centres[0..n_allowed]) |c| if (c - half + edge <= pos) {
            pick = c;
        };
        if (pick == null) {
            for (centres[0..n_allowed]) |c| if (c > pos) {
                pick = c;
                break;
            };
        }
        const c = pick orelse centres[n_allowed - 1];
        if (n > 0 and c <= out[n - 1]) break;
        out[n] = c;
        n += 1;
        pos = c + half - edge;
        if (pos >= hi) break;
    }
    return n;
}

/// The allowed channel centre nearest `mhz`.
pub fn nearest(mhz: u16, allowed: u16) ?u16 {
    var best: ?u16 = null;
    for (1..15) |c| if (allowed & (@as(u16, 1) << @intCast(c)) != 0) {
        const f = channelMhz(@intCast(c));
        if (best == null or @abs(@as(i32, f) - mhz) < @abs(@as(i32, best.?) - mhz)) best = f;
    };
    return best;
}

pub fn plan(req: Request, sensors: u8) Plan {
    var p = Plan{ .mode = req.mode, .dwell_ms = @max(100, req.dwell_ms), .sensors = @min(sensors, max_sensors) };
    var lo = std.math.clamp(@min(req.lo_mhz, req.hi_mhz), band_lo, band_hi);
    var hi = std.math.clamp(@max(req.lo_mhz, req.hi_mhz), band_lo, band_hi);
    if (req.mode == .sweep) {
        lo = band_lo;
        hi = band_hi;
    }
    p.lo_mhz = lo;
    p.hi_mhz = hi;
    // A span that one window holds is a fixed window.
    if (req.mode == .focus and hi - lo <= 2 * half + 2) p.mode = .fixed;
    if (p.mode == .fixed) {
        p.windows.centres[0] = nearest((lo + hi) / 2, req.allowed) orelse return p;
        p.windows.n = 1;
    } else p.windows.n = @intCast(windows(if (p.mode == .sweep) band_lo + 2 else lo, if (p.mode == .sweep) band_hi - 6 else hi, req.allowed, &p.windows.centres));
    const k: usize = p.windows.n;
    const s: usize = p.sensors;
    if (k == 0 or s == 0) return p;
    const park = if (req.park_mhz) |m| nearest(m, req.allowed) else null;
    if (s >= k) {
        // Every window watched at once; spare sensors double up on the park window (or spread).
        for (0..s) |i| {
            p.per[i].centres[0] = if (i < k) p.windows.centres[i] else park orelse p.windows.centres[i % k];
            p.per[i].n = 1;
        }
    } else if (park != null and s >= 2) {
        // One parked on the blast region for clean 50/60 Hz; the others sweep the rest.
        p.per[0].centres[0] = park.?;
        p.per[0].n = 1;
        var rest: [max_windows]u16 = undefined;
        var m: usize = 0;
        for (p.windows.list()) |c| if (c != park.?) {
            rest[m] = c;
            m += 1;
        };
        if (m == 0) {
            rest[0] = park.?;
            m = 1;
        }
        share(&p, 1, rest[0..m]);
    } else share(&p, 0, p.windows.list());
    return p;
}

/// Contiguous groups of `list` for sensors `first..`.
fn share(p: *Plan, first: usize, list: []const u16) void {
    const s = p.sensors - first;
    const k = list.len;
    for (0..s) |i| {
        const a = &p.per[first + i];
        const from = if (s >= k) i % k else i * k / s;
        const to = if (s >= k) from + 1 else (i + 1) * k / s;
        for (list[from..to], 0..) |c, j| a.centres[j] = c;
        a.n = @intCast(to - from);
    }
}

test "one sensor sweeps the band in six overlapping windows" {
    const p = plan(.{}, 1);
    try std.testing.expectEqual(Mode.sweep, p.mode);
    try std.testing.expectEqualSlices(u16, &.{ 2412, 2427, 2442, 2457, 2472, 2484 }, p.windows.list());
    try std.testing.expectEqualSlices(u16, p.windows.list(), p.per[0].list());
    try std.testing.expectEqual(@as(u32, 6 * resolve_dwell_ms), p.revisitMs());
    var b: [200]u8 = undefined;
    try std.testing.expectEqualStrings("sweep 2402-2494 MHz: 6 windows (ch 1/4/7/10/13/14), 600 ms dwell, each revisited within 3.6 s (17% of the time)", p.describe(&b));
    // Channel 14 not tunable here: five windows to 2482.
    const q = plan(.{ .allowed = all_channels & ~@as(u16, 1 << 14) }, 1);
    try std.testing.expectEqualSlices(u16, &.{ 2412, 2427, 2442, 2457, 2472 }, q.windows.list());
}

test "focus: a wide span in turn, a narrow span or a fixed focus in one window" {
    const wide = plan(.{ .mode = .focus, .lo_mhz = 2440, .hi_mhz = 2470 }, 1);
    try std.testing.expectEqual(Mode.focus, wide.mode);
    try std.testing.expectEqualSlices(u16, &.{ 2447, 2462 }, wide.windows.list());
    try std.testing.expect(wide.windows.centres[0] - half <= 2440 and wide.windows.centres[1] + half >= 2470);
    const narrow = plan(.{ .mode = .focus, .lo_mhz = 2449, .hi_mhz = 2466 }, 1);
    try std.testing.expectEqual(Mode.fixed, narrow.mode);
    try std.testing.expectEqualSlices(u16, &.{2457}, narrow.windows.list());
    try std.testing.expectEqual(@as(u32, 0), narrow.revisitMs());
    const fixed = plan(.{ .mode = .fixed, .lo_mhz = 2400, .hi_mhz = 2440 }, 1);
    try std.testing.expectEqualSlices(u16, &.{2422}, fixed.windows.list());
    var b: [200]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, narrow.describe(&b), "watched continuously"));
}

test "N sensors share the windows; enough see the whole band at once; one can park" {
    const two = plan(.{}, 2);
    try std.testing.expectEqualSlices(u16, &.{ 2412, 2427, 2442 }, two.per[0].list());
    try std.testing.expectEqualSlices(u16, &.{ 2457, 2472, 2484 }, two.per[1].list());
    try std.testing.expectEqual(@as(u32, 3 * resolve_dwell_ms), two.revisitMs());
    const six = plan(.{}, 4);
    try std.testing.expect(six.revisitMs() <= 2 * resolve_dwell_ms);
    var all: u32 = 0;
    for (six.per[0..4]) |*a| all += a.n;
    try std.testing.expectEqual(@as(u32, 6), all);
    const parked = plan(.{ .park_mhz = 2455 }, 2);
    try std.testing.expectEqualSlices(u16, &.{2457}, parked.per[0].list());
    try std.testing.expectEqualSlices(u16, &.{ 2412, 2427, 2442, 2472, 2484 }, parked.per[1].list());
    try std.testing.expectEqual(@as(f32, 1.0 / 5.0), parked.watchShare());
    const focus2 = plan(.{ .mode = .focus, .lo_mhz = 2440, .hi_mhz = 2470 }, 2);
    try std.testing.expectEqual(@as(u32, 0), focus2.revisitMs());
}
