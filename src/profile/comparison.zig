//! Compare recorded CPU sample shares. Addresses and TIDs are local to a run.
const std = @import("std");
const flame = @import("flame.zig");
const a = std.heap.page_allocator;
pub const scale: u64 = 1_000_000_000;
pub const max_nodes = 2 * flame.max_nodes;
pub const unresolved_ancestry: u64 = 1 << 32;
pub const Counts = struct {
    inclusive: [2]u64 = .{ 0, 0 },
    self: [2]u64 = .{ 0, 0 },
};
pub const Row = struct {
    name: []const u8,
    module: []const u8,
    kind: flame.Kind,
    match: enum { symbol, category, recorded_identity, unmatched, ambiguous },
    counts: Counts = .{},
};
pub const Coverage = struct {
    samples: u64 = 0,
    retained: usize = 0,
    lost: u64 = 0,
    discarded: u64 = 0,
    partial: u64 = 0,
    unverified: u64 = 0,
    frequency_hz: u32 = 0,
    event: []const u8 = "",
    lost_records: u64 = 0,
    sha256: [64]u8 = @splat(0),
};
pub fn share(count: u64, total: u64) f64 {
    return 100 * @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(total));
}
pub fn delta(count: [2]u64, total: [2]u64) f64 {
    return share(count[1], total[1]) - share(count[0], total[0]);
}
pub const View = struct {
    arena: *std.heap.ArenaAllocator,
    graph: flame.Graph,
    rows: []Row,
    counts: []Counts,
    ranking: []u32,
    totals: [2]u64,
    pub fn deinit(self: *View) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};
const Group = struct {
    address: [2]?u64 = .{ null, null },
    module: [2]u64 = .{ 0, 0 },
    ambiguous: bool = false,
};
fn symbolKey(allocator: std.mem.Allocator, frame: flame.Frame) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}:{s}{s}", .{ frame.module.len, frame.module, frame.name });
}
fn check(cancel: *const std.atomic.Value(bool)) !void {
    if (cancel.load(.acquire)) return error.ComparisonCancelled;
}
/// Thread roots are aggregated; recursion remains in the tree. Flat inclusive
/// counts include a function at most once along each ancestry path.
pub fn build(allocator: std.mem.Allocator, graphs: [2]*const flame.Graph, cancel: *const std.atomic.Value(bool)) !View {
    return buildMatching(allocator, graphs, cancel, graphs[0] == graphs[1]);
}
fn buildMatching(allocator: std.mem.Allocator, graphs: [2]*const flame.Graph, cancel: *const std.atomic.Value(bool), same_evidence: bool) !View {
    // The graph retains this allocator interface, so its arena address must
    // remain stable when the finished View moves from the worker stack.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const mem = arena.allocator();
    const totals = [2]u64{ graphs[0].nodes.items[0].inclusive, graphs[1].nodes.items[0].inclusive };
    if (totals[0] == 0 or totals[1] == 0) return error.ComparisonEmptyCapture;
    for (graphs) |graph| if (graph.rejected != 0) return error.ComparisonGraphLimit;
    var groups = std.StringHashMap(Group).init(mem);
    for (graphs, 0..) |graph, side| for (graph.nodes.items) |node| {
        try check(cancel);
        const f = node.frame;
        if (f.kind != .code or f.module.len == 0 or f.name.len == 0 or f.name.len >= 256) continue;
        const key = try symbolKey(mem, f);
        const found = try groups.getOrPut(key);
        if (!found.found_existing) found.value_ptr.* = .{};
        const group = found.value_ptr;
        if (group.address[side]) |address| {
            if (address != f.address or group.module[side] != f.module_id) group.ambiguous = true;
        } else {
            group.address[side] = f.address;
            group.module[side] = f.module_id;
        }
    };
    var rows: std.ArrayList(Row) = .empty;
    var index = std.StringHashMap(u32).init(mem);
    var mapping: [2][]u32 = undefined;
    for (graphs, 0..) |graph, side| {
        mapping[side] = try mem.alloc(u32, graph.nodes.items.len);
        @memset(mapping[side], std.math.maxInt(u32));
        for (graph.nodes.items, 0..) |node, n| {
            try check(cancel);
            const f = node.frame;
            if (f.kind == .root or f.kind == .thread) continue;
            const group = groups.get(try symbolKey(mem, f));
            const category = f.kind == .incomplete;
            const symbol = f.kind == .code and group != null and !group.?.ambiguous;
            const key = if (symbol) try std.fmt.allocPrint(mem, "symbol:{s}", .{try symbolKey(mem, f)}) else if (category) try std.fmt.allocPrint(mem, "category:{s}", .{f.name}) else try std.fmt.allocPrint(mem, "unmatched:{d}:{d}:{d}:{d}:{d}", .{ if (same_evidence) @as(usize, 0) else side, @intFromEnum(f.kind), f.module_id, f.mapping_id, f.address });
            const found = try index.getOrPut(key);
            if (!found.found_existing) {
                found.value_ptr.* = @intCast(rows.items.len);
                try rows.append(mem, .{ .name = try mem.dupe(u8, f.name), .module = try mem.dupe(u8, f.module), .kind = f.kind, .match = if (symbol) .symbol else if (category) .category else if (same_evidence) .recorded_identity else if (group != null and group.?.ambiguous) .ambiguous else .unmatched });
            }
            const id = found.value_ptr.*;
            mapping[side][n] = id;
            rows.items[id].counts.self[side] += node.self;
        }
        for (graph.nodes.items, 0..) |node, n| {
            const id = mapping[side][n];
            if (id == std.math.maxInt(u32)) continue;
            var parent = node.parent;
            const recursive = while (parent) |p| {
                if (mapping[side][p] == id) break true;
                parent = graph.nodes.items[p].parent;
            } else false;
            if (!recursive) rows.items[id].counts.inclusive[side] += node.inclusive;
        }
    }
    var out = try flame.Graph.init(mem);
    out.limit = max_nodes;
    out.nodes.items[0].frame.name = "CPU sample share comparison";
    // Store the union of paths, then replace raw mixed weights with normalized
    // display widths. A separate counter array retains both runs exactly.
    for (graphs, 0..) |graph, side| for (graph.nodes.items, 0..) |node, n| {
        try check(cancel);
        if (node.self == 0) continue;
        var buffer: [128]flame.Frame = undefined;
        const path = try ancestry(&buffer, graph, mapping[side], rows.items, @intCast(n));
        try out.addWeighted(path, node.self);
        if (out.rejected != 0) return error.ComparisonGraphLimit;
    };
    const counts = try mem.alloc(Counts, out.nodes.items.len);
    @memset(counts, .{});
    for (graphs, 0..) |graph, side| for (graph.nodes.items, 0..) |node, n| {
        try check(cancel);
        if (node.self == 0) continue;
        var buffer: [128]flame.Frame = undefined;
        const path = try ancestry(&buffer, graph, mapping[side], rows.items, @intCast(n));
        var id: u32 = 0;
        for (path) |f| id = out.findChild(id, f).?;
        counts[id].self[side] += node.self;
    };
    for (out.nodes.items, counts) |*node, *count| {
        count.inclusive = count.self;
        // Ceil keeps every observed path visible. Resolution is one part in 1e9.
        node.self = @max(normalize(count.self[0], totals[0]), normalize(count.self[1], totals[1]));
        node.inclusive = node.self;
    }
    var n = out.nodes.items.len;
    while (n > 1) {
        n -= 1;
        const parent = out.nodes.items[n].parent.?;
        for (0..2) |side| counts[parent].inclusive[side] += counts[n].inclusive[side];
        out.nodes.items[parent].inclusive += out.nodes.items[n].inclusive;
    }
    try out.layout();
    const ranking = try mem.alloc(u32, rows.items.len);
    for (ranking, 0..) |*id, row| id.* = @intCast(row);
    const Sort = struct { rows: []const Row, totals: [2]u64 };
    std.mem.sort(u32, ranking, Sort{ .rows = rows.items, .totals = totals }, struct {
        fn less(ctx: Sort, left: u32, right: u32) bool {
            const l = delta(ctx.rows[left].counts.self, ctx.totals);
            const r = delta(ctx.rows[right].counts.self, ctx.totals);
            if (@abs(l) != @abs(r)) return @abs(l) > @abs(r);
            return std.mem.order(u8, ctx.rows[left].name, ctx.rows[right].name) == .lt;
        }
    }.less);
    return .{ .arena = arena, .graph = out, .rows = rows.items, .counts = counts, .ranking = ranking, .totals = totals };
}
fn normalize(count: u64, total: u64) u64 {
    return @intCast((@as(u128, count) * scale + total - 1) / total);
}
fn ancestry(buffer: []flame.Frame, graph: *const flame.Graph, mapping: []const u32, rows: []const Row, leaf: u32) ![]flame.Frame {
    var count: usize = 0;
    var next: ?u32 = leaf;
    while (next) |id| {
        const row = mapping[id];
        if (row != std.math.maxInt(u32)) {
            if (count == buffer.len) return error.ComparisonDepthLimit;
            if (id != leaf and (rows[row].kind == .unknown or rows[row].kind == .unverified)) {
                // Unknown ancestors must not partition every known descendant
                // by ASLR. This is an evidence-gap category, not a matched PC.
                if (count == 0 or buffer[count - 1].address != unresolved_ancestry) {
                    buffer[count] = .{ .kind = .incomplete, .address = unresolved_ancestry, .name = "[unresolved callers grouped]" };
                    count += 1;
                }
            } else {
                buffer[count] = .{ .kind = rows[row].kind, .address = @as(u64, row) + 1, .name = rows[row].name, .module = rows[row].module };
                count += 1;
            }
        }
        next = graph.nodes.items[id].parent;
    }
    std.mem.reverse(flame.Frame, buffer[0..count]);
    return buffer[0..count];
}
pub const Job = struct {
    paths: [2][:0]u8,
    progress: @import("archive_progress.zig").Progress = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    budget: @import("archive_budget.zig").Budget = .{ .backing = a, .limit = 128 * 1024 * 1024 },
    result: ?View = null,
    coverage: [2]Coverage = .{ .{}, .{} },
    failure: ?anyerror = null,
    pub fn start(before: []const u8, after: []const u8) !*Job {
        for ([_][]const u8{ before, after }) |path| if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.ArchivePathInvalid;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const first = try a.dupeZ(u8, before);
        errdefer a.free(first);
        const second = try a.dupeZ(u8, after);
        errdefer a.free(second);
        self.* = .{ .paths = .{ first, second } };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn read(self: *Job, side: usize) !flame.Graph {
        const archive = @import("archive.zig");
        const bytes = try archive.readFile(a, self.paths[side], archive.max_file_bytes, &self.progress);
        defer a.free(bytes);
        var opened = try archive.decode(a, bytes, .{ .local_id = side + 1, .progress = &self.progress });
        defer opened.deinit();
        var graph = try opened.capture.graphWithCancel(self.budget.allocator(), .{}, &self.progress.cancel);
        errdefer graph.deinit();
        try graph.ownLabels();
        self.coverage[side] = .{ .samples = graph.nodes.items[0].inclusive, .retained = opened.capture.samples.len(), .event = @tagName(opened.capture.accepted.event), .lost_records = opened.capture.lost_records, .lost = opened.capture.lost_samples, .discarded = opened.capture.discarded_samples, .partial = graph.partial_samples, .unverified = graph.unverified_samples, .frequency_hz = opened.capture.config.frequency_hz, .sha256 = std.fmt.bytesToHex(opened.source.archive_sha256, .lower) };
        return graph;
    }
    fn execute(self: *Job) !void {
        var before = try self.read(0);
        defer before.deinit();
        var after = try self.read(1);
        defer after.deinit();
        if (!std.mem.eql(u8, self.coverage[0].event, self.coverage[1].event)) return error.ComparisonEventMismatch;
        try self.progress.step(.annotations, 0);
        self.result = try buildMatching(self.budget.allocator(), .{ &before, &after }, &self.progress.cancel, std.mem.eql(u8, &self.coverage[0].sha256, &self.coverage[1].sha256));
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = if (self.budget.denied) error.ComparisonMemoryLimit else err;
        };
        self.done.store(true, .release);
    }
    pub fn deinit(self: *Job) void {
        self.progress.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.result) |*view| view.deinit();
        for (self.paths) |path| a.free(path);
        std.debug.assert(self.budget.used == 0);
        a.destroy(self);
    }
};

test "comparison normalizes unequal counts, ignores ASLR and TIDs, and counts recursion once" {
    const mem = std.testing.allocator;
    var before = try flame.Graph.init(mem);
    defer before.deinit();
    var after = try flame.Graph.init(mem);
    defer after.deinit();
    const t = flame.Frame{ .kind = .thread, .address = 11, .name = "Thread 11" };
    const f = flame.Frame{ .kind = .code, .address = 100, .module_id = 1, .module = "/fixture", .name = "hot" };
    const g = flame.Frame{ .kind = .code, .address = 200, .module_id = 1, .module = "/fixture", .name = "cool" };
    var shifted = f;
    shifted.address += 0x1000;
    shifted.module_id = 9;
    var shifted_g = g;
    shifted_g.address += 0x1000;
    shifted_g.module_id = 9;
    try before.addWeighted(&.{ t, f, f }, 75);
    try before.addWeighted(&.{ t, g }, 25);
    try after.addWeighted(&.{ shifted, shifted }, 50);
    try after.addWeighted(&.{shifted_g}, 150);
    const cancel = std.atomic.Value(bool).init(false);
    var view = try build(mem, .{ &before, &after }, &cancel);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 2), view.rows.len);
    try std.testing.expectEqual([2]u64{ 100, 200 }, view.counts[0].inclusive);
    for (view.rows) |row| {
        try std.testing.expectEqual(row.counts.self, row.counts.inclusive);
        try std.testing.expectEqual(@as(f64, if (std.mem.eql(u8, row.name, "hot")) -50 else 50), delta(row.counts.self, view.totals));
    }
    // No apparent regression merely because one run collected more samples.
    var same = try build(mem, .{ &before, &before }, &cancel);
    defer same.deinit();
    for (same.rows) |row| try std.testing.expectEqual(@as(f64, 0), delta(row.counts.self, same.totals));
    const cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ComparisonCancelled, build(mem, .{ &before, &after }, &cancelled));
    // Two homonymous symbols in one module must not silently match a rebuild.
    var duplicate = f;
    duplicate.address += 10;
    try before.add(&.{duplicate});
    var ambiguous = try build(mem, .{ &before, &after }, &cancel);
    defer ambiguous.deinit();
    var count: usize = 0;
    for (ambiguous.rows) |row| if (row.match == .ambiguous) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "comparison groups unresolved ancestry without claiming matching unknown PCs" {
    var before = try flame.Graph.init(std.testing.allocator);
    defer before.deinit();
    var after = try flame.Graph.init(std.testing.allocator);
    defer after.deinit();
    const f = flame.Frame{ .kind = .code, .address = 10, .module = "/fixture", .name = "known" };
    try before.addWeighted(&.{ .{ .kind = .unknown, .address = 100, .name = "0x64" }, f }, 10);
    try after.addWeighted(&.{ .{ .kind = .unknown, .address = 200, .name = "0xc8" }, f }, 20);
    const cancel = std.atomic.Value(bool).init(false);
    var view = try build(std.testing.allocator, .{ &before, &after }, &cancel);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 3), view.graph.nodes.items.len);
    try std.testing.expectEqual(unresolved_ancestry, view.graph.nodes.items[1].frame.address);
    try std.testing.expectEqual([2]u64{ 10, 20 }, view.counts[2].self);
    try std.testing.expectEqual(@as(usize, 3), view.rows.len);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, comparisonAllocationFailure, .{[2]*const flame.Graph{ &before, &after }});
}
fn comparisonAllocationFailure(allocator: std.mem.Allocator, graphs: [2]*const flame.Graph) !void {
    const cancel = std.atomic.Value(bool).init(false);
    var view = try build(allocator, graphs, &cancel);
    defer view.deinit();
}

test "identical evidence matches unresolved leaf PCs without invented share changes" {
    var graph = try flame.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addWeighted(&.{.{ .kind = .unknown, .address = 0x1234, .name = "unresolved leaf" }}, 7);
    var copy = try graph.clone(std.testing.allocator);
    defer copy.deinit();
    const cancel = std.atomic.Value(bool).init(false);
    var view = try buildMatching(std.testing.allocator, .{ &graph, &copy }, &cancel, true);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 1), view.rows.len);
    try std.testing.expectEqual(.recorded_identity, view.rows[0].match);
    try std.testing.expectEqual([2]u64{ 7, 7 }, view.rows[0].counts.self);
    try std.testing.expectEqual(@as(f64, 0), delta(view.rows[0].counts.self, view.totals));
    var different = try buildMatching(std.testing.allocator, .{ &graph, &copy }, &cancel, false);
    defer different.deinit();
    try std.testing.expectEqual(@as(usize, 2), different.rows.len);
}
