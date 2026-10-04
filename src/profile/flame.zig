//! Sample-count call tree. Input paths run from oldest caller to sampled leaf.
//! A node's identity includes its parent, so recursion and different callers
//! never collapse into a flat function histogram.
const std = @import("std");
pub const max_nodes = 8192;
pub const Kind = enum { root, thread, code, unknown, unverified, incomplete };
pub const Frame = struct {
    kind: Kind,
    module_id: u64 = 0,
    mapping_id: u32 = 0,
    mapping_note: []const u8 = "",
    address: u64 = 0,
    lookup_address: u64 = 0,
    name: []const u8,
    module: []const u8 = "",
};
pub const Node = struct {
    id: u32,
    parent: ?u32,
    frame: Frame,
    inclusive: u64 = 0,
    self: u64 = 0,
    depth: u16 = 0,
    x: u64 = 0,
    first_child: ?u32 = null,
    next_sibling: ?u32 = null,
};
const Key = struct { parent: u32, kind: Kind, module_id: u64, mapping_id: u32, address: u64 };
pub const Graph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    index: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    rejected: u64 = 0,
    partial_samples: u64 = 0,
    unverified_samples: u64 = 0,
    limit: usize = max_nodes,
    owned_labels: []u8 = &.{},

    pub fn init(a: std.mem.Allocator) !Graph {
        var graph = Graph{ .allocator = a };
        try graph.nodes.append(a, .{ .id = 0, .parent = null, .frame = .{ .kind = .root, .name = "All samples" } });
        return graph;
    }
    pub fn clone(self: *const Graph, a: std.mem.Allocator) !Graph {
        var out = Graph{ .allocator = a, .rejected = self.rejected, .partial_samples = self.partial_samples, .unverified_samples = self.unverified_samples, .limit = self.limit };
        errdefer out.deinit();
        try out.nodes.appendSlice(a, self.nodes.items);
        out.index = try self.index.clone(a);
        try out.ownLabels();
        return out;
    }
    /// Detach labels from capture/worker arenas before publishing a graph.
    pub fn ownLabels(self: *Graph) !void {
        var size: usize = 0;
        for (self.nodes.items) |node| {
            for ([_][]const u8{ node.frame.name, node.frame.module, node.frame.mapping_note }) |label| size = std.math.add(usize, size, label.len) catch return error.OutOfMemory;
        }
        const labels = try self.allocator.alloc(u8, size);
        var at: usize = 0;
        for (self.nodes.items) |*node| {
            inline for (.{ "name", "module", "mapping_note" }) |field| {
                const old = @field(node.frame, field);
                @memcpy(labels[at..][0..old.len], old);
                @field(node.frame, field) = labels[at..][0..old.len];
                at += old.len;
            }
        }
        self.allocator.free(self.owned_labels);
        self.owned_labels = labels;
    }
    pub fn deinit(self: *Graph) void {
        self.nodes.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.allocator.free(self.owned_labels);
    }
    pub fn add(self: *Graph, path: []const Frame) !void {
        return self.addWeighted(path, 1);
    }
    /// Period-weighted imported views use the same tree with explicit units.
    pub fn addWeighted(self: *Graph, path: []const Frame, weight: u64) !void {
        if (weight == 0) return error.InvalidFlameWeight;
        _ = std.math.add(u64, self.nodes.items[0].inclusive, weight) catch return error.FlameWeightOverflow;
        // Preflight the missing suffix. Reject a whole sample on capacity;
        // partial paths would violate inclusive = self + sum(children).
        var parent: u32 = 0;
        var missing: usize = 0;
        for (path, 0..) |frame, i| {
            const key = Key{ .parent = parent, .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .address = frame.address };
            parent = self.index.get(key) orelse {
                missing = path.len - i;
                break;
            };
        }
        if (self.nodes.items.len + missing > self.limit) {
            self.rejected += 1;
            return;
        }
        try self.nodes.ensureUnusedCapacity(self.allocator, missing);
        try self.index.ensureUnusedCapacity(self.allocator, @intCast(missing));
        parent = 0;
        self.nodes.items[0].inclusive += weight;
        for (path) |frame| {
            const key = Key{ .parent = parent, .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .address = frame.address };
            const entry = self.index.getOrPutAssumeCapacity(key);
            if (!entry.found_existing) {
                const id: u32 = @intCast(self.nodes.items.len);
                entry.value_ptr.* = id;
                self.nodes.appendAssumeCapacity(.{ .id = id, .parent = parent, .frame = frame, .depth = self.nodes.items[parent].depth + 1 });
            }
            parent = entry.value_ptr.*;
            self.nodes.items[parent].inclusive += weight;
        }
        self.nodes.items[parent].self += weight;
    }
    pub fn findChild(self: *const Graph, parent: u32, frame: Frame) ?u32 {
        return self.index.get(.{ .parent = parent, .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .address = frame.address });
    }
    pub fn layout(self: *Graph) !void {
        const order = try self.allocator.alloc(u32, self.nodes.items.len - 1);
        defer self.allocator.free(order);
        for (order, 1..) |*id, i| id.* = @intCast(i);
        std.mem.sort(u32, order, self.nodes.items, less);
        for (self.nodes.items) |*node| {
            node.first_child = null;
            node.next_sibling = null;
        }
        var previous: ?u32 = null;
        for (order) |id| {
            const parent = self.nodes.items[id].parent.?;
            if (previous != null and self.nodes.items[previous.?].parent.? == parent) {
                self.nodes.items[previous.?].next_sibling = id;
            } else self.nodes.items[parent].first_child = id;
            previous = id;
        }
        self.place(0, 0);
    }
    fn less(nodes: []Node, left: u32, right: u32) bool {
        const l = nodes[left];
        const r = nodes[right];
        if (l.parent.? != r.parent.?) return l.parent.? < r.parent.?;
        const names = std.mem.order(u8, l.frame.name, r.frame.name);
        if (names != .eq) return names == .lt;
        if (l.frame.kind != r.frame.kind) return @intFromEnum(l.frame.kind) < @intFromEnum(r.frame.kind);
        if (l.frame.module_id != r.frame.module_id) return l.frame.module_id < r.frame.module_id;
        if (l.frame.mapping_id != r.frame.mapping_id) return l.frame.mapping_id < r.frame.mapping_id;
        return l.frame.address < r.frame.address;
    }
    fn place(self: *Graph, id: u32, x: u64) void {
        self.nodes.items[id].x = x;
        var cursor = x;
        var child = self.nodes.items[id].first_child;
        while (child) |c| {
            self.place(c, cursor);
            cursor += self.nodes.items[c].inclusive;
            child = self.nodes.items[c].next_sibling;
        }
    }
};

test "flames preserve callers, recursion, self samples, and capacity conservation" {
    var graph = try Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = Frame{ .kind = .code, .address = 1, .name = "a" };
    const b = Frame{ .kind = .code, .address = 2, .name = "b" };
    try graph.add(&.{ a, a, b });
    try graph.add(&.{ a, b });
    try graph.add(&.{a});
    try graph.add(&.{ b, a });
    graph.limit = graph.nodes.items.len;
    try graph.add(&.{ b, b }); // rejected atomically
    try graph.add(&.{ a, b }); // an existing path still fits
    try graph.layout();
    try std.testing.expectEqual(@as(u64, 5), graph.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 1), graph.rejected);
    var total_self: u64 = 0;
    for (graph.nodes.items) |node| {
        var children: u64 = 0;
        var child = node.first_child;
        while (child) |id| {
            const n = graph.nodes.items[id];
            try std.testing.expectEqual(node.x + children, n.x);
            children += n.inclusive;
            child = n.next_sibling;
        }
        try std.testing.expectEqual(node.inclusive, node.self + children);
        total_self += node.self;
    }
    try std.testing.expectEqual(@as(u64, 5), total_self);
    try std.testing.expectEqual(@as(u64, 4), graph.nodes.items[1].inclusive);
    try std.testing.expectEqual(@as(u16, 2), graph.nodes.items[2].depth);
}

fn cloneFailure(a: std.mem.Allocator, source: *const Graph) !void {
    var copy = try source.clone(a);
    defer copy.deinit();
    try std.testing.expectEqualDeep(source.nodes.items, copy.nodes.items);
}

test "owned graph labels survive cloning and all clone allocation failures" {
    var graph = try Graph.init(std.testing.allocator);
    defer graph.deinit();
    var name = "mutable name".*;
    var module = "/mutable/module".*;
    var note = "mutable note".*;
    try graph.add(&.{.{ .kind = .code, .address = 1, .name = &name, .module = &module, .mapping_note = &note }});
    try graph.ownLabels();
    @memset(&name, 'x');
    @memset(&module, 'x');
    @memset(&note, 'x');
    try graph.ownLabels(); // Re-owning labels must keep their content valid.
    try std.testing.expectEqualStrings("mutable name", graph.nodes.items[1].frame.name);
    try std.testing.expectEqualStrings("/mutable/module", graph.nodes.items[1].frame.module);
    try std.testing.expectEqualStrings("mutable note", graph.nodes.items[1].frame.mapping_note);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cloneFailure, .{&graph});
}

test "weighted flames preserve periods and reject overflow atomically" {
    var graph = try Graph.init(std.testing.allocator);
    defer graph.deinit();
    const frame = Frame{ .kind = .code, .address = 1, .name = "one" };
    try graph.addWeighted(&.{frame}, 7);
    try graph.addWeighted(&.{frame}, 11);
    try std.testing.expectEqual(@as(u64, 18), graph.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 18), graph.nodes.items[1].self);
    try std.testing.expectError(error.InvalidFlameWeight, graph.addWeighted(&.{frame}, 0));
    try std.testing.expectError(error.FlameWeightOverflow, graph.addWeighted(&.{frame}, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(u64, 18), graph.nodes.items[0].inclusive);
}
