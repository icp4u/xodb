//! Huge coverage of sampled VMA ranges. Points keep their real sample times;
//! missing measurements are gaps, never zero. No source strings are retained.
const std = @import("std");
const md = @import("../../memdefrag/model.zig");
pub const capacity = 32;
pub const max_ranges = 4096;
pub const Point = struct { sampled_ns: u64, fraction: ?f32 };
pub const Series = struct {
    points: [capacity]Point = undefined,
    head: usize = 0,
    len: usize = 0,
    seen: u64 = 0,
    fn push(self: *Series, point: Point) void {
        self.points[self.head] = point;
        self.head = (self.head + 1) % capacity;
        self.len = @min(capacity, self.len + 1);
    }
    pub fn back(self: *const Series, i: usize) ?Point {
        if (i >= self.len) return null;
        return self.points[(self.head + capacity - 1 - i) % capacity];
    }
};
const Key = struct {
    start: u64,
    end: u64,
    kind: md.VmaKind,
    perms: [4]u8,
    fn of(v: md.Vma) Key {
        var perms: [4]u8 = @splat('-');
        @memcpy(perms[0..@min(4, v.perms.len)], v.perms[0..@min(4, v.perms.len)]);
        return .{ .start = v.start, .end = v.end, .kind = v.kind, .perms = perms };
    }
};
pub const History = struct {
    allocator: ?std.mem.Allocator = null,
    ranges: std.AutoArrayHashMapUnmanaged(Key, Series) = .empty,
    target: ?md.Identity = null,
    sampled_ns: ?u64 = null,
    epoch: u64 = 0,
    omitted: usize = 0,
    audited_ns: ?u64 = null,

    pub fn deinit(self: *History) void {
        if (self.allocator) |a| self.ranges.deinit(a);
        self.* = .{};
    }
    pub fn get(self: *const History, vma: md.Vma) ?*const Series {
        return self.ranges.getPtr(Key.of(vma));
    }
    /// Called while the modern view is visible. System-only publications and
    /// pending viewports do not invent another process sample.
    pub fn observe(self: *History, a: std.mem.Allocator, map: *const md.Map) !void {
        const p = map.process orelse return;
        const id = md.Identity{ .pid = p.pid, .start = p.start_ticks };
        if (!std.meta.eql(self.target, @as(?md.Identity, id))) {
            self.deinit();
            self.target = id;
        }
        if (map.pending or self.sampled_ns == map.sampled_ns) return;
        // A looping or backwards-seeked replay starts a new timeline.
        if (self.sampled_ns) |last| if (map.sampled_ns < last) {
            self.deinit();
            self.target = id;
        };
        self.allocator = a;
        // Reserve before appending any point: an allocation failure cannot leave
        // half a sample that a later frame would append twice.
        try self.ranges.ensureTotalCapacity(a, @min(max_ranges, self.ranges.count() +| map.vmas.len));
        self.epoch +%= 1;
        self.omitted = 0;
        // Disappeared ranges are discarded after this sample. A replacement at
        // the same address between samples is not an observable allocation lifetime.
        for (map.vmas) |vma| {
            const key = Key.of(vma);
            if (!self.ranges.contains(key) and self.ranges.count() >= max_ranges) {
                self.omitted += 1;
                continue;
            }
            const entry = try self.ranges.getOrPut(a, key);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            if (entry.found_existing and entry.value_ptr.seen == self.epoch) continue;
            entry.value_ptr.push(.{ .sampled_ns = map.sampled_ns, .fraction = coverage(vma) });
            entry.value_ptr.seen = self.epoch;
        }
        var i = self.ranges.count();
        while (i > 0) {
            i -= 1;
            if (self.ranges.values()[i].seen != self.epoch) self.ranges.swapRemoveAt(i);
        }
        self.sampled_ns = map.sampled_ns;
    }
};
/// AnonHugePages divided by the whole VMA span, not the THP-eligible span.
pub fn coverage(vma: md.Vma) ?f32 {
    const huge = vma.anon_huge orelse return null;
    if (vma.end <= vma.start or huge > vma.end - vma.start) return null;
    return @as(f32, @floatFromInt(huge)) / @as(f32, @floatFromInt(vma.end - vma.start));
}

test "VMA history keeps real timestamps, gaps and target/range lifetimes" {
    var h = History{};
    defer h.deinit();
    var vmas = [_]md.Vma{.{ .start = 0x1000, .end = 0x5000, .anon_huge = 0x2000 }};
    var map = md.Map{ .sampled_ns = 10, .process = .{ .pid = 7, .start_ticks = 9 }, .vmas = &vmas };
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(?f32, 0.5), h.get(vmas[0]).?.back(0).?.fraction);
    // A repaint or a system-counter publication does not add a point.
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 1), h.get(vmas[0]).?.len);
    map.sampled_ns = 50;
    vmas[0].anon_huge = null;
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(?f32, null), h.get(vmas[0]).?.back(0).?.fraction);
    try std.testing.expectEqual(@as(u64, 10), h.get(vmas[0]).?.back(1).?.sampled_ns);
    map.pending = true;
    map.sampled_ns = 60;
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 2), h.get(vmas[0]).?.len);
    map.pending = false;
    map.process.?.start_ticks += 1;
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 1), h.get(vmas[0]).?.len);
    map.sampled_ns = 5;
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 1), h.get(vmas[0]).?.len);
    try std.testing.expectEqual(@as(u64, 5), h.get(vmas[0]).?.back(0).?.sampled_ns);
    map.sampled_ns = 70;
    map.vmas = &.{};
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, 0), h.ranges.count());
    try std.testing.expectEqual(@as(?f32, null), coverage(.{ .start = 4, .end = 4, .anon_huge = 0 }));
    try std.testing.expectEqual(@as(?f32, null), coverage(.{ .start = 4, .end = 8, .anon_huge = 5 }));
}

// Fast component lane: capacity and allocation refusal are observable properties.
test "VMA history bounds points and refuses allocation without a partial sample" {
    var h = History{};
    defer h.deinit();
    var vmas = [_]md.Vma{.{ .start = 0x1000, .end = 0x5000, .anon_huge = 0 }};
    var map = md.Map{ .sampled_ns = 1, .process = .{ .pid = 7, .start_ticks = 9 }, .vmas = &vmas };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, h.observe(failing.allocator(), &map));
    try std.testing.expect(h.sampled_ns == null and h.ranges.count() == 0);
    h.deinit();
    for (1..capacity + 9) |i| {
        map.sampled_ns = @intCast(i * i);
        try h.observe(std.testing.allocator, &map);
    }
    const series = h.get(vmas[0]).?;
    try std.testing.expectEqual(@as(usize, capacity), series.len);
    try std.testing.expectEqual(@as(u64, 1600), series.back(0).?.sampled_ns);
    try std.testing.expectEqual(@as(u64, 81), series.back(capacity - 1).?.sampled_ns);
    try std.testing.expectEqual(@as(?f32, 0), series.back(0).?.fraction);
    const rows = try std.testing.allocator.alloc(md.Vma, max_ranges + 7);
    defer std.testing.allocator.free(rows);
    for (rows, 0..) |*row, i| row.* = .{ .start = i * 4096, .end = (i + 1) * 4096 };
    h.deinit();
    map.sampled_ns += 1;
    map.vmas = rows;
    try h.observe(std.testing.allocator, &map);
    try std.testing.expectEqual(@as(usize, max_ranges), h.ranges.count());
    try std.testing.expectEqual(@as(usize, 7), h.omitted);
}
