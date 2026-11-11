//! Chronological projection: timestamps never borrow merged-flame coordinates.
const std = @import("std");
const V = std.json.Value;
fn field(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn text(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
fn number(v: V) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => 0,
    };
}
fn array(v: V) []const V {
    return if (v == .array) v.array.items else &.{};
}
pub const Span = struct { start: f64, end: f64, depth: u32, label: []const u8, weight: u64 = 0, cache_read: f64 = 0, cache_input: f64 = 0 };
pub const Chart = struct {
    wall: std.ArrayList(Span) = .empty,
    tokens: std.ArrayList(Span) = .empty,
    start: f64 = 0,
    end: f64 = 0,
    omitted: usize = 0,
    pub fn build(a: std.mem.Allocator, doc: V) !Chart {
        var out = Chart{ .start = number(field(doc, "start")), .end = number(field(doc, "end")) };
        _ = try out.session(a, doc, 0, 0);
        std.mem.sort(Span, out.wall.items, {}, less);
        std.mem.sort(Span, out.tokens.items, {}, less);
        return out;
    }
    fn less(_: void, l: Span, r: Span) bool {
        return l.start < r.start or (l.start == r.start and l.depth < r.depth);
    }
    fn add(self: *Chart, a: std.mem.Allocator, list: *std.ArrayList(Span), span: Span) !void {
        if (!std.math.isFinite(span.start) or !std.math.isFinite(span.end) or span.end < span.start) {
            self.omitted += 1;
            return;
        }
        if (list.items.len >= 300000) {
            self.omitted += 1;
            return;
        }
        try list.append(a, span);
        self.start = @min(self.start, span.start);
        self.end = @max(self.end, span.end);
    }
    fn session(self: *Chart, a: std.mem.Allocator, doc: V, base: u32, nesting: usize) !u32 {
        if (nesting > 8) {
            self.omitted += 1;
            return base;
        }
        if (std.mem.eql(u8, text(field(doc, "agent")), "fleet")) {
            var next = base;
            for (array(field(doc, "children"))) |child| next = try self.session(a, child, next, nesting);
            return next;
        }
        const start = number(field(doc, "start"));
        const end = number(field(doc, "end"));
        try self.add(a, &self.wall, .{ .start = start, .end = end, .depth = base, .label = text(field(doc, "agent")) });
        try self.add(a, &self.wall, .{ .start = start, .end = end, .depth = base + 1, .label = text(field(doc, "title")) });
        for (array(field(doc, "turns"))) |turn| try self.add(a, &self.wall, .{ .start = number(field(turn, "start")), .end = number(field(turn, "end")), .depth = base + 2, .label = text(field(turn, "title")) });
        var ordered: std.ArrayList(Span) = .empty;
        for (array(field(doc, "spans"))) |s| {
            const detail = text(field(s, "detail"));
            const label = if (detail.len > 0) try std.fmt.allocPrint(a, "{s} / {s}", .{ text(field(s, "activity")), detail }) else text(field(s, "activity"));
            try ordered.append(a, .{ .start = number(field(s, "start")), .end = number(field(s, "end")), .depth = 0, .label = label });
        }
        std.mem.sort(Span, ordered.items, {}, less);
        var ends: [64]f64 = @splat(-std.math.inf(f64));
        var lanes: u16 = 0;
        for (ordered.items) |s| {
            var lane: usize = 0;
            while (lane < ends.len and ends[lane] > s.start) : (lane += 1) {}
            if (lane == ends.len) {
                self.omitted += 1;
                continue;
            }
            ends[lane] = s.end;
            lanes = @max(lanes, @as(u16, @intCast(lane + 1)));
            var span = s;
            span.depth = base + 3 + @as(u16, @intCast(lane));
            try self.add(a, &self.wall, span);
        }
        const categories = [_][]const u8{ "fresh input", "cached input", "cache write", "output", "reasoning" };
        for (array(field(doc, "tokens"))) |call| {
            const time = number(field(call, "time"));
            const weights = field(call, "weights");
            const cache_read = number(field(weights, "cached input"));
            const cache_input = cache_read + number(field(weights, "fresh input")) + number(field(weights, "cache write"));
            for (categories, 0..) |category, index| {
                const count = number(field(field(call, "weights"), category));
                if (!std.math.isFinite(count) or count <= 0 or count > 1e15) continue;
                try self.add(a, &self.tokens, .{ .start = time, .end = time, .depth = base + 3 + @as(u16, @intCast(index)), .weight = @intFromFloat(count), .cache_read = cache_read, .cache_input = cache_input, .label = try std.fmt.allocPrint(a, "{s} / {s}: {d:.0}", .{ text(field(call, "detail")), category, count }) });
            }
        }
        var next = base + 4 + @max(lanes, 5);
        for (array(field(doc, "children"))) |child| {
            const id = text(field(child, "parent_call_id"));
            var parent: []const u8 = if (field(child, "spawn_time") != .null and id.len > 0) "recorded spawn (not in view)" else "unlinked subagent";
            for (array(field(doc, "spans"))) |s| if (id.len > 0 and std.mem.eql(u8, id, text(field(s, "call_id")))) {
                parent = text(field(s, "activity"));
                break;
            };
            const label = try std.fmt.allocPrint(a, "{s} > subagent:{s}", .{ parent, text(field(child, "subagent_name")) });
            try self.add(a, &self.wall, .{ .start = number(field(child, "start")), .end = number(field(child, "end")), .depth = next, .label = label });
            next = try self.session(a, child, next + 1, nesting + 1);
        }
        return next;
    }
};

test "chronology preserves parallel intervals and separates overlap lanes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(V, a,
        \\{"start":1,"end":9,"agent":"synthetic","title":"test","turns":[],"spans":[{"start":2,"end":6,"activity":"tool:a"},{"start":3,"end":5,"activity":"tool:b"},{"start":6,"end":8,"activity":"model"}],"tokens":[{"time":7,"weights":{"cached input":40,"output":3},"detail":"call"}]}
    , .{});
    const chart = try Chart.build(a, doc);
    try std.testing.expectEqual(@as(f64, 1), chart.start);
    try std.testing.expectEqual(@as(f64, 9), chart.end);
    const left = chart.wall.items[2];
    const right = chart.wall.items[3];
    try std.testing.expectEqual(@as(f64, 2), left.start);
    try std.testing.expectEqual(@as(f64, 6), left.end);
    try std.testing.expect(left.depth != right.depth);
    try std.testing.expectEqual(left.depth, chart.wall.items[4].depth);
    try std.testing.expectEqual(@as(usize, 2), chart.tokens.items.len);
    try std.testing.expectEqual(@as(f64, 7), chart.tokens.items[0].start);
    try std.testing.expectEqual(chart.tokens.items[0].start, chart.tokens.items[0].end);
    try std.testing.expectEqual(@as(u64, 40), chart.tokens.items[0].weight);
}
