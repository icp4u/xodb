//! Value-only bookmarks; never retain a replaced profile's arena or node IDs.
const std = @import("std");
const tree = @import("flame.zig");
const chart = @import("agent_time_chart.zig");

pub const Mark = struct {
    len: u8 = 0,
    kinds: [32]tree.Kind = undefined,
    addresses: [32]u64 = undefined,

    pub fn of(g: *const tree.Graph, id: u32) Mark {
        var m = Mark{};
        if (id >= g.nodes.items.len) return m;
        var depth: usize = 0;
        var cur = id;
        while (cur != 0) : (cur = g.nodes.items[cur].parent orelse 0) depth += 1;
        m.len = @intCast(@min(depth, m.kinds.len));
        cur = id;
        while (cur != 0) : (cur = g.nodes.items[cur].parent orelse 0) {
            // The root-most prefix resolves from root; a leaf-most suffix does not.
            if (depth <= m.kinds.len) {
                m.kinds[depth - 1] = g.nodes.items[cur].frame.kind;
                m.addresses[depth - 1] = g.nodes.items[cur].frame.address;
            }
            depth -= 1;
        }
        return m;
    }

    /// Same node, or deepest surviving ancestor within the saved prefix.
    pub fn resolve(m: Mark, g: *const tree.Graph) u32 {
        var cur: u32 = 0;
        for (m.kinds[0..m.len], m.addresses[0..m.len]) |kind, address| {
            cur = g.findChild(cur, .{ .kind = kind, .address = address, .name = "" }) orelse return cur;
        }
        return cur;
    }
};

/// Start and label survive sorting, lane reassignment and a growing end time.
/// An occurrence disambiguates identical marks without borrowing label memory.
pub const ChartMark = struct {
    start: f64,
    label_hash: u64,
    occurrence: usize = 0,

    fn matches(self: ChartMark, span: chart.Span) bool {
        return self.start == span.start and self.label_hash == std.hash.Wyhash.hash(0, span.label);
    }
    pub fn of(spans: []const chart.Span, selected: usize) ?ChartMark {
        if (selected >= spans.len) return null;
        var mark = ChartMark{ .start = spans[selected].start, .label_hash = std.hash.Wyhash.hash(0, spans[selected].label) };
        for (spans[0..selected]) |span| if (mark.matches(span)) {
            mark.occurrence += 1;
        };
        return mark;
    }
    pub fn resolve(self: ChartMark, spans: []const chart.Span) usize {
        var occurrence: usize = 0;
        for (spans, 0..) |span, i| if (self.matches(span)) {
            if (occurrence == self.occurrence) return i;
            occurrence += 1;
        };
        return 0;
    }
};

test "bounded flame mark keeps root prefix across renumbering and missing ancestors" {
    var old = try tree.Graph.init(std.testing.allocator);
    defer old.deinit();
    var next = try tree.Graph.init(std.testing.allocator);
    defer next.deinit();
    var path: [80]tree.Frame = undefined;
    for (&path, 0..) |*frame, i| frame.* = .{ .kind = .code, .address = i + 1, .name = "frame" };
    try old.add(&path);
    // A separate root branch deliberately renumbers every retained node.
    try next.add(&.{.{ .kind = .code, .address = 999, .name = "inserted" }});
    try next.add(&path);
    for ([_]u32{ 0, 1, 31, 32, 33, 80, 999 }) |id| {
        const mark = Mark.of(&old, id);
        const depth = if (id == 999) 0 else @min(id, 32);
        try std.testing.expectEqual(depth, mark.len);
        const resolved = mark.resolve(&next);
        try std.testing.expectEqual(depth, next.nodes.items[resolved].depth);
        try std.testing.expectEqual(@as(u64, depth), next.nodes.items[resolved].frame.address);
        if (depth > 0) try std.testing.expect(resolved != depth);
    }
    var partial = try tree.Graph.init(std.testing.allocator);
    defer partial.deinit();
    try partial.add(path[0..9]);
    const mark = Mark.of(&old, 80);
    try std.testing.expectEqual(@as(u32, 9), mark.resolve(&partial));
}

test "chart marks survive index changes, growing ends and duplicate labels" {
    const Span = chart.Span;
    const old = [_]Span{
        .{ .start = 1, .end = 2, .depth = 0, .label = "same" },
        .{ .start = 1, .end = 3, .depth = 1, .label = "same" },
        .{ .start = 2, .end = 3, .depth = 0, .label = "other" },
    };
    const next = [_]Span{
        .{ .start = 0, .end = 1, .depth = 0, .label = "inserted" },
        .{ .start = 1, .end = 9, .depth = 4, .label = "same" },
        .{ .start = 1, .end = 9, .depth = 5, .label = "same" },
        old[2],
    };
    try std.testing.expectEqual(@as(usize, 2), ChartMark.of(&old, 1).?.resolve(&next));
    try std.testing.expectEqual(@as(usize, 3), ChartMark.of(&old, 2).?.resolve(&next));
    try std.testing.expectEqual(@as(usize, 0), ChartMark.of(&old, 2).?.resolve(next[0..2]));
    try std.testing.expect(ChartMark.of(&old, 3) == null);
}
