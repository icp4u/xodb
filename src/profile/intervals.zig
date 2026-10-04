//! Application-supplied timing annotations. These are imported claims, not
//! kernel observations. Relative times are bound to one completed capture.
const std = @import("std");
const timeline = @import("timeline.zig");
pub const limit = 4096;
pub const batch_limit = 128;
pub const text_limit = 96;
pub const provenance = "imported application timing; source, clock alignment and meaning are supplied by the caller, not verified kernel events";
pub const Kind = enum { frame, request, custom };
pub const Input = struct { from_ns: u64, to_ns: u64, tid: ?u32 = null, label: []const u8, kind: Kind = .custom, correlation_id: ?u64 = null };
pub const Interval = struct {
    id: u32,
    from_ns: u64,
    to_ns: u64,
    tid: ?u32,
    kind: Kind,
    correlation_id: ?u64,
    label_bytes: [text_limit]u8 = @splat(0),
    label_len: u8,
    source_bytes: [text_limit]u8 = @splat(0),
    source_len: u8,
    pub fn label(self: *const Interval) []const u8 {
        return self.label_bytes[0..self.label_len];
    }
    pub fn source(self: *const Interval) []const u8 {
        return self.source_bytes[0..self.source_len];
    }
    pub fn matches(self: *const Interval, filter: timeline.Filter, extent: u64) bool {
        if (self.tid) |tid| if (!filter.matchesThread(tid)) return false;
        const range = filter.clipped(extent);
        if (range.from_ns == range.to_ns) return false;
        return if (self.from_ns == self.to_ns) self.from_ns >= range.from_ns and self.from_ns < range.to_ns else self.from_ns < range.to_ns and self.to_ns > range.from_ns;
    }
    pub fn jsonStringify(self: Interval, writer: *std.json.Stringify) !void {
        try writer.write(.{ .id = self.id, .from_ns = self.from_ns, .to_ns = self.to_ns, .tid = self.tid, .kind = self.kind, .correlation_id = self.correlation_id, .label = self.label(), .source = self.source() });
    }
};
fn validText(text: []const u8) bool {
    if (text.len == 0 or text.len > text_limit or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}
pub const Store = struct {
    items: std.ArrayList(Interval) = .empty,
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        self.items.deinit(a);
    }
    /// All validation precedes mutation; a rejected batch preserves old evidence.
    pub fn add(self: *Store, a: std.mem.Allocator, source_: []const u8, batch: []const Input, extent: u64) !void {
        if (batch.len == 0 or batch.len > batch_limit or !validText(source_)) return error.InvalidApplicationIntervals;
        if (self.items.items.len + batch.len > limit) return error.ApplicationIntervalLimit;
        for (batch) |input| {
            if (!validText(input.label) or input.to_ns < input.from_ns or input.from_ns >= extent or input.to_ns > extent or input.tid == 0) return error.InvalidApplicationIntervals;
        }
        const needed = self.items.items.len + batch.len;
        if (needed > self.items.capacity) try self.items.ensureTotalCapacityPrecise(a, @min(limit, @max(needed, @max(64, self.items.capacity * 2))));
        for (batch) |input| {
            var interval = Interval{ .id = @intCast(self.items.items.len + 1), .from_ns = input.from_ns, .to_ns = input.to_ns, .tid = input.tid, .kind = input.kind, .correlation_id = input.correlation_id, .label_len = @intCast(input.label.len), .source_len = @intCast(source_.len) };
            @memcpy(interval.label_bytes[0..input.label.len], input.label);
            @memcpy(interval.source_bytes[0..source_.len], source_);
            self.items.appendAssumeCapacity(interval);
        }
    }
};
test "application timing batches are atomic, bounded, and half-open with explicit global events" {
    const a = std.testing.allocator;
    var store = Store{};
    defer store.deinit(a);
    try store.add(a, "frame CSV", &.{ .{ .from_ns = 10, .to_ns = 30, .tid = 7, .label = "frame 1", .kind = .frame }, .{ .from_ns = 30, .to_ns = 30, .label = "instant" } }, 100);
    try std.testing.expect(!store.items.items[0].matches(.{ .from_ns = 30 }, 100));
    try std.testing.expect(store.items.items[1].matches(.{ .tid = 8, .from_ns = 30 }, 100));
    try std.testing.expect(!store.items.items[1].matches(.{ .to_ns = 30 }, 100));
    try std.testing.expect(!store.items.items[0].matches(.{ .tid = 8 }, 100));
    try std.testing.expectError(error.InvalidApplicationIntervals, store.add(a, "source", &.{ .{ .from_ns = 1, .to_ns = 2, .label = "valid" }, .{ .from_ns = 50, .to_ns = 101, .label = "invalid" } }, 100));
    try std.testing.expectEqual(2, store.items.items.len);
    try std.testing.expectError(error.InvalidApplicationIntervals, store.add(a, "source", &.{.{ .from_ns = 1, .to_ns = 2, .label = "bad\ntext" }}, 100));
    try std.testing.expectError(error.InvalidApplicationIntervals, store.add(a, "source", &.{.{ .from_ns = 1, .to_ns = 2, .label = "\xff" }}, 100));
    const text = try std.json.Stringify.valueAlloc(a, store.items.items[0], .{});
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "frame CSV") != null);
    while (store.items.items.len < limit) try store.add(a, "source", &.{.{ .from_ns = 1, .to_ns = 2, .label = "bounded" }}, 100);
    try std.testing.expect(store.items.capacity <= limit);
    try std.testing.expectError(error.ApplicationIntervalLimit, store.add(a, "source", &.{.{ .from_ns = 1, .to_ns = 2, .label = "overflow" }}, 100));
}
