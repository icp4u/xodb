//! Portable aggregate CPU profile plus xodb evidence metadata. The ordering of
//! weighted stacks is synthetic; units are sample counts, never elapsed time.
const std = @import("std");
const c = @import("../c.zig").api;
const capture_model = @import("capture.zig");
const flame = @import("flame.zig");
const scheduling = @import("scheduling.zig");
const intervals = @import("intervals.zig");
const now = @import("../target/linux.zig").now;
pub const max_file_bytes = 64 * 1024 * 1024;
pub const ordering = "aggregated CPU sample counts; stack order is synthetic, not a timeline; use xodb CPU bins and scheduling totals for time evidence";
const Frame = struct { name: []const u8 };
const Key = struct { kind: flame.Kind, module_id: u64, mapping_id: u32, address: u64 };
pub const Aggregate = struct {
    frames: []Frame,
    identities: []flame.Frame,
    samples: [][]u32,
    weights: []u64,
    count: u64,
};
/// Allocate with a temporary arena. Identity strings borrow the graph/capture;
/// display names and stack arrays live in the arena.
pub fn aggregate(a: std.mem.Allocator, graph: *const flame.Graph) !Aggregate {
    var map: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    var frames: std.ArrayList(Frame) = .empty;
    var identities: std.ArrayList(flame.Frame) = .empty;
    const ids = try a.alloc(u32, graph.nodes.items.len);
    for (graph.nodes.items[1..], 1..) |node, i| {
        const f = node.frame;
        const entry = try map.getOrPut(a, .{ .kind = f.kind, .module_id = f.module_id, .mapping_id = f.mapping_id, .address = f.address });
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(frames.items.len);
            const name = if (f.module.len > 0) try std.fmt.allocPrint(a, "{s} [{s} @ 0x{x}, map {d}]", .{ f.name, std.fs.path.basename(f.module), f.address, f.mapping_id }) else try a.dupe(u8, f.name);
            try frames.append(a, .{ .name = name });
            try identities.append(a, f);
        }
        ids[i] = entry.value_ptr.*;
    }
    var samples: std.ArrayList([]u32) = .empty;
    var weights: std.ArrayList(u64) = .empty;
    var count: u64 = 0;
    for (graph.nodes.items) |node| {
        if (node.self == 0) continue;
        const path = try a.alloc(u32, node.depth);
        var cursor = node.id;
        var index = path.len;
        while (cursor != 0) {
            if (index == 0) return error.InvalidExportGraph;
            index -= 1;
            path[index] = ids[cursor];
            cursor = graph.nodes.items[cursor].parent orelse return error.InvalidExportGraph;
        }
        if (index != 0) return error.InvalidExportGraph;
        try samples.append(a, path);
        try weights.append(a, node.self);
        count += node.self;
    }
    if (count != graph.nodes.items[0].inclusive) return error.InvalidExportGraph;
    return .{ .frames = frames.items, .identities = identities.items, .samples = samples.items, .weights = weights.items, .count = count };
}
pub const Result = struct { bytes: usize, samples: u64, excluded_by_node_limit: u64 };
pub fn save(capture: *capture_model.Capture, path: [:0]const u8, filter: capture_model.Filter) !Result {
    return savePrepared(capture, path, filter, null);
}
pub fn savePrepared(capture: *capture_model.Capture, path: [:0]const u8, filter: capture_model.Filter, prepared: ?*const flame.Graph) !Result {
    if (capture.collector != null) return error.ProfileStillCollecting;
    try capture.validateFilter(filter);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var built: flame.Graph = undefined;
    const graph = prepared orelse blk: {
        built = try capture.graph(a, filter);
        break :blk &built;
    };
    const data = try aggregate(a, graph);
    const extent = capture.extentNs();
    const range = filter.clipped(extent);
    const density = try capture.cpuTimeline(a, filter, 128);
    const Schedule = struct { tid: i32, totals: scheduling.Totals };
    var schedules: std.ArrayList(Schedule) = .empty;
    for (capture.threads[0..capture.thread_count], 0..) |thread, i| {
        if (!filter.matchesThread(@intCast(thread.perf.tid))) continue;
        const spans = try capture.schedulingSpans(a, i, range);
        try schedules.append(a, .{ .tid = thread.perf.tid, .totals = scheduling.Totals.from(spans) });
    }
    var app: std.ArrayList(intervals.Interval) = .empty;
    for (capture.application_intervals.items.items) |item| if (item.matches(filter, extent)) try app.append(a, item);
    const profile = .{ .type = "sampled", .name = try std.fmt.allocPrint(a, "xodb #{d}: aggregate CPU sample counts (synthetic order)", .{capture.id}), .unit = "none", .startValue = @as(u64, 0), .endValue = data.count, .samples = data.samples, .weights = data.weights };
    const bytes = try std.json.Stringify.valueAlloc(a, .{
        .@"$schema" = "https://www.speedscope.app/file-format-schema.json",
        .name = profile.name,
        .exporter = "xodb",
        .activeProfileIndex = @as(u32, 0),
        .shared = .{ .frames = data.frames },
        .profiles = .{profile},
        .xodb = .{
            .schema_version = @as(u32, 1),
            .capture = capture.summary(),
            .filter = .{ .tid = filter.tid, .tids = filter.tids.optional(), .from_ns = filter.from_ns, .to_ns = if (filter.to_ns == std.math.maxInt(u64)) null else @as(?u64, filter.to_ns) },
            .range = range,
            .ordering = ordering,
            .samples = data.count,
            .excluded_by_node_limit = graph.rejected,
            .partial_samples = graph.partial_samples,
            .unverified_samples = graph.unverified_samples,
            .invalid_samples = density.invalid_samples,
            .frame_identities = data.identities,
            .mapping_coverage = @import("mappings.zig").coverage,
            .cpu_bins = density.histogram.bins,
            .cpu_threads = density.lanes,
            .scheduling_totals = schedules.items,
            .application_intervals = app.items,
            .application_provenance = intervals.provenance,
            .debugger_markers = capture.debugger_markers.items,
            .debugger_marker_basis = @import("timeline.zig").marker_basis,
            .debugger_marker_scope = "whole capture; retain earlier stop/resume evidence for a filtered range",
            .debugger_markers_dropped = capture.debugger_marker_dropped,
            .debugger_events_lost = capture.debugger_events_lost,
            .limitations = "portable selected aggregate, not a reopenable native capture; raw samples, per-switch history, ELF/source files and target state are not included; recorded mapping limitations still apply",
        },
    }, .{});
    try writeNew(a, path, bytes);
    return .{ .bytes = bytes.len, .samples = data.count, .excluded_by_node_limit = graph.rejected };
}
/// Publish complete bytes without replacing an existing file. The temporary
/// lives beside the destination so hard-link publication stays on one filesystem.
/// Writes use normal kernel buffering; no file or directory durability sync.
pub fn writeNew(a: std.mem.Allocator, path: [:0]const u8, bytes: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidExportPath;
    if (bytes.len > max_file_bytes) return error.ProfileExportLimit;
    const temporary = try std.fmt.allocPrintSentinel(a, "{s}.xodb-{d}-{d}.tmp", .{ path, c.getpid(), now() }, 0);
    defer a.free(temporary);
    const fd = c.open(temporary, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.ProfileExportOpenFailed;
    defer _ = c.close(fd);
    defer _ = c.unlink(temporary);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ProfileExportWriteFailed;
        offset += @intCast(n);
    }
    if (c.link(temporary, path) != 0) return if (std.c._errno().* == c.EEXIST) error.ProfileExportExists else error.ProfileExportPublishFailed;
}
test "portable weighted stacks conserve recursion, ancestry, self counts and identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = try flame.Graph.init(a);
    const main = flame.Frame{ .kind = .code, .address = 1, .mapping_id = 1, .name = "quote\"\\name" };
    const leaf = flame.Frame{ .kind = .code, .address = 2, .mapping_id = 1, .name = "leaf" };
    try graph.add(&.{ main, main, leaf });
    try graph.add(&.{ main, main, leaf });
    try graph.add(&.{main});
    var replaced = main;
    replaced.mapping_id = 2;
    try graph.add(&.{replaced});
    const data = try aggregate(a, &graph);
    try std.testing.expectEqual(4, data.count);
    try std.testing.expectEqual(3, data.frames.len);
    try std.testing.expectEqual(3, data.samples.len);
    try std.testing.expectEqual(1, data.samples[0].len);
    try std.testing.expectEqual(3, data.samples[1].len);
    try std.testing.expectEqual(data.samples[1][0], data.samples[1][1]);
    try std.testing.expect(data.samples[0][0] != data.samples[2][0]);
    try std.testing.expectEqual(2, data.weights[1]);
    const serialized = try std.json.Stringify.valueAlloc(a, data.frames, .{});
    _ = try std.json.parseFromSlice(std.json.Value, a, serialized, .{});
}
