//! Bounded retained switch history. Each lane preserves kernel delivery order.
const std = @import("std");
const timeline = @import("timeline.zig");
pub const max_threads = 1024;
pub const max_events = 262144;
pub const max_lane_events = timeline.max_transitions;
const Lane = struct {
    events: std.ArrayList(timeline.Transition) = .empty,
    cutoff_ns: ?u64 = null,
    contradictory: bool = false,
};
pub const Store = struct {
    lanes: [max_threads]Lane = @splat(.{}),
    retained: usize = 0,
    discarded: u64 = 0,
    invalid: u64 = 0,
    extent_ns: u64 = 0,
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        for (&self.lanes) |*lane| lane.events.deinit(a);
    }
    fn drop(self: *Store, lane: *Lane, offset: u64) void {
        self.discarded +|= 1;
        lane.cutoff_ns = @min(lane.cutoff_ns orelse offset, offset);
    }
    pub fn add(self: *Store, a: std.mem.Allocator, index: usize, event: timeline.Transition) !void {
        const lane = &self.lanes[index];
        self.extent_ns = @max(self.extent_ns, event.offset_ns +| 1);
        if (self.retained == max_events or lane.events.items.len == max_lane_events or lane.cutoff_ns != null) {
            self.drop(lane, event.offset_ns);
            return error.SchedulingLimit;
        }
        if (lane.events.items.len == lane.events.capacity) {
            lane.events.ensureTotalCapacityPrecise(a, @min(max_lane_events, @max(64, lane.events.capacity * 2))) catch |err| {
                self.drop(lane, event.offset_ns);
                return err;
            };
        }
        if (lane.events.items.len > 0) {
            const last = lane.events.items[lane.events.items.len - 1];
            if (event.offset_ns <= last.offset_ns or event.direction == last.direction) lane.contradictory = true;
        }
        lane.events.appendAssumeCapacity(event);
        self.retained += 1;
        if (lane.contradictory) return error.ContradictoryScheduling;
    }
    pub fn storageBytes(self: *const Store) usize {
        var bytes: usize = 0;
        for (&self.lanes) |*lane| bytes += lane.events.capacity * @sizeOf(timeline.Transition);
        return bytes;
    }
    pub fn spans(self: *const Store, a: std.mem.Allocator, index: usize, extent: u64, range: timeline.Range, coverage: timeline.Coverage) ![]timeline.Span {
        const lane = &self.lanes[index];
        if (coverage != .available or lane.contradictory) return timeline.reconstruct(a, &.{}, extent, range, if (coverage != .available) coverage else .contradictory);
        const end = @min(extent, lane.cutoff_ns orelse extent);
        // The retained prefix is trustworthy only if discarded timestamps do
        // not precede it. A clock/order defect must not be hidden by clipping.
        if (lane.events.items.len > 0 and lane.events.items[lane.events.items.len - 1].offset_ns > end) return timeline.reconstruct(a, &.{}, extent, range, .contradictory);
        const prefix = try timeline.reconstruct(a, lane.events.items, end, range, .available);
        errdefer a.free(prefix);
        const tail_start = @max(end, @min(range.from_ns, extent));
        const tail_end = @min(extent, range.to_ns);
        if (tail_start >= tail_end) return prefix;
        const result = try a.alloc(timeline.Span, prefix.len + 1);
        @memcpy(result[0..prefix.len], prefix);
        a.free(prefix);
        result[prefix.len] = .{ .from_ns = tail_start, .to_ns = tail_end, .state = .unknown, .unknown_reason = .capacity, .clipped_start = tail_start != end, .clipped_end = tail_end != extent };
        return result;
    }
};
pub const Totals = struct {
    running_ns: u64 = 0,
    off_cpu_ns: u64 = 0,
    unknown_ns: u64 = 0,
    pub fn from(spans: []const timeline.Span) Totals {
        var self = Totals{};
        for (spans) |span| switch (span.state) {
            .running => self.running_ns += span.to_ns - span.from_ns,
            .off_cpu => self.off_cpu_ns += span.to_ns - span.from_ns,
            .unknown => self.unknown_ns += span.to_ns - span.from_ns,
        };
        return self;
    }
};

test "schedule budgets keep a valid prefix, explicit unknown suffix, and bounded memory" {
    const a = std.testing.allocator;
    const store = try a.create(Store);
    store.* = .{};
    defer a.destroy(store);
    defer store.deinit(a);
    for (0..4) |lane| for (0..max_lane_events) |i| try store.add(a, lane, .{ .offset_ns = i + 1, .direction = if (i % 2 == 0) .switch_in else .switch_out });
    try std.testing.expectEqual(max_events, store.retained);
    try std.testing.expect(store.storageBytes() <= (2 * max_events + 64 * max_threads) * @sizeOf(timeline.Transition));
    try std.testing.expectError(error.SchedulingLimit, store.add(a, 0, .{ .offset_ns = max_lane_events + 1, .direction = .switch_in }));
    try std.testing.expectError(error.SchedulingLimit, store.add(a, 4, .{ .offset_ns = 8, .direction = .switch_in }));
    const spans = try store.spans(a, 0, max_lane_events + 20, .{ .from_ns = 0, .to_ns = max_lane_events + 20 }, .available);
    defer a.free(spans);
    const totals = Totals.from(spans);
    try std.testing.expect(totals.running_ns > 0 and totals.off_cpu_ns > 0);
    try std.testing.expectEqual(max_lane_events + 20, totals.running_ns + totals.off_cpu_ns + totals.unknown_ns);
    try std.testing.expectEqual(timeline.Unknown.capacity, spans[spans.len - 1].unknown_reason.?);
    const lost = try store.spans(a, 0, 100, .{ .from_ns = 0, .to_ns = 100 }, .lost);
    defer a.free(lost);
    try std.testing.expectEqual(100, Totals.from(lost).unknown_ns);
}

test "out of order or duplicate directions invalidate a lane, never another lane" {
    const a = std.testing.allocator;
    const store = try a.create(Store);
    store.* = .{};
    defer a.destroy(store);
    defer store.deinit(a);
    try store.add(a, 0, .{ .offset_ns = 10, .direction = .switch_in });
    try std.testing.expectError(error.ContradictoryScheduling, store.add(a, 0, .{ .offset_ns = 20, .direction = .switch_in }));
    try store.add(a, 1, .{ .offset_ns = 10, .direction = .switch_in });
    try store.add(a, 1, .{ .offset_ns = 20, .direction = .switch_out });
    const bad = try store.spans(a, 0, 30, .{ .from_ns = 0, .to_ns = 30 }, .available);
    defer a.free(bad);
    const good = try store.spans(a, 1, 30, .{ .from_ns = 0, .to_ns = 30 }, .available);
    defer a.free(good);
    try std.testing.expectEqual(30, Totals.from(bad).unknown_ns);
    try std.testing.expectEqual(10, Totals.from(good).running_ns);
}
