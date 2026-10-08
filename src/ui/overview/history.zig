//! View-side history: fixed ring buffers of samples (null = not measured)
//! and an adaptive graph scale whose peak decays instead of snapping down.
const std = @import("std");

pub const capacity = 180;

pub const Ring = struct {
    values: [capacity]?f32 = @splat(null),
    head: usize = 0,
    len: usize = 0,

    pub fn push(self: *Ring, value: ?f64) void {
        self.values[self.head] = if (value) |v| @floatCast(v) else null;
        self.head = (self.head + 1) % capacity;
        self.len = @min(self.len + 1, capacity);
    }
    /// The i-th most recent sample, 0 = newest.
    pub fn back(self: *const Ring, i: usize) ?f32 {
        if (i >= self.len) return null;
        return self.values[(self.head + capacity - 1 - i) % capacity];
    }
    pub fn last(self: *const Ring) ?f32 {
        return self.back(0);
    }
    pub fn max(self: *const Ring, count: usize) f32 {
        var m: f32 = 0;
        for (0..@min(count, self.len)) |i| if (self.back(i)) |v| {
            m = @max(m, v);
        };
        return m;
    }
};

/// A ceiling that rises at once to a "nice" value above the visible maximum
/// and decays by `decay` per sample toward it, so a burst stays readable.
pub const Scale = struct {
    peak: f32 = 0,
    floor: f32 = 1,
    /// Sample count at the last update: decay is per sample, not per frame.
    seen: u64 = 0,
    pub fn observe(self: *Scale, sample: u64, visible_max: f32) void {
        if (self.seen == sample) return;
        self.seen = sample;
        self.update(visible_max);
    }
    pub fn update(self: *Scale, visible_max: f32) void {
        const target = nice(@max(visible_max, self.floor));
        if (target >= self.peak) self.peak = target else self.peak = @max(target, self.peak * 0.97);
    }
    pub fn ceiling(self: *const Scale) f32 {
        return if (self.peak > 0) self.peak else nice(self.floor);
    }
};

/// 1, 2 or 5 times a power of ten, at or above `v`.
pub fn nice(v: f32) f32 {
    if (v <= 0) return 1;
    const exponent = @floor(std.math.log10(v));
    const base = std.math.pow(f32, 10, exponent);
    for ([_]f32{ 1, 2, 5, 10 }) |m| if (base * m >= v * 0.9999) return base * m;
    return base * 10;
}

/// Name-keyed rings for devices that may appear and disappear (disks, NICs,
/// sensors). Unseen names get a slot; slots are never reused within a run.
pub fn Keyed(comptime slots: usize, comptime series: usize) type {
    return struct {
        names: [slots][48]u8 = undefined,
        name_len: [slots]u8 = @splat(0),
        rings: [slots][series]Ring = undefined,
        scales: [slots]Scale = @splat(.{}),
        count: usize = 0,
        const Self = @This();
        pub fn get(self: *Self, name: []const u8) ?*[series]Ring {
            const index = self.find(name) orelse return null;
            return &self.rings[index];
        }
        pub fn find(self: *const Self, name: []const u8) ?usize {
            const key = name[0..@min(name.len, 48)];
            for (0..self.count) |i| if (std.mem.eql(u8, self.names[i][0..self.name_len[i]], key)) return i;
            return null;
        }
        pub fn slot(self: *Self, name: []const u8) ?usize {
            if (self.find(name)) |i| return i;
            if (self.count == slots) return null;
            const key = name[0..@min(name.len, 48)];
            @memcpy(self.names[self.count][0..key.len], key);
            self.name_len[self.count] = @intCast(key.len);
            self.rings[self.count] = @splat(.{});
            self.count += 1;
            return self.count - 1;
        }
    };
}

test "ring keeps order and gaps; scale decays toward a nice ceiling" {
    var ring = Ring{};
    ring.push(1);
    ring.push(null);
    ring.push(3);
    try std.testing.expectEqual(@as(?f32, 3), ring.back(0));
    try std.testing.expectEqual(@as(?f32, null), ring.back(1));
    try std.testing.expectEqual(@as(?f32, 1), ring.back(2));
    try std.testing.expectEqual(@as(?f32, null), ring.back(3));
    for (0..capacity + 5) |i| ring.push(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, capacity), ring.len);
    try std.testing.expectEqual(@as(?f32, capacity + 4), ring.back(0));
    var scale = Scale{};
    scale.update(730);
    try std.testing.expectEqual(@as(f32, 1000), scale.ceiling());
    scale.update(30);
    try std.testing.expect(scale.ceiling() < 1000 and scale.ceiling() > 900);
    for (0..400) |_| scale.update(30);
    try std.testing.expectEqual(@as(f32, 50), scale.ceiling());
    try std.testing.expectEqual(@as(f32, 2), nice(1.5));
    try std.testing.expectEqual(@as(f32, 100), nice(100));
    var keyed = Keyed(2, 2){};
    try std.testing.expectEqual(@as(?usize, 0), keyed.slot("nvme0n1"));
    try std.testing.expectEqual(@as(?usize, 1), keyed.slot("sda"));
    try std.testing.expectEqual(@as(?usize, null), keyed.slot("sdb"));
    try std.testing.expectEqual(@as(?usize, 0), keyed.slot("nvme0n1"));
}
