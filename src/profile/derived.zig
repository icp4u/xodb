//! Reconstructed-stack flame aggregate for a completed capture (T16; proposed
//! `src/profile/derived.zig`). Streams time-ordered filtered samples through
//! one `unwind.Batch`, adds each derived stack to a bounded flame graph and
//! keeps only counts, per-node sample references and the graph, never every
//! expanded frame array.
//!
//! Every filtered sample lands in exactly one bucket, and the buckets sum to
//! the denominator:
//!   complete     CFI reached a terminal return-address rule (zero or undefined)
//!   partial      at least one caller recovered, then a terminal reason
//!   leaf_only    only the sampled PC (no usable stack, budget gap, ...)
//!   unavailable  no usable registers or sample state
//!   excluded     dropped whole at the flame node limit
//! Partial and leaf-only stacks hang under an explicit "[callers unknown:
//! reason]" node, so a fragment is never joined to complete call paths through
//! an unknown gap. The sampled PC is the leaf exactly once.
const std = @import("std");
const capture_model = @import("capture.zig");
const flame = @import("flame.zig");
const unwind = @import("unwind.zig");
const sample_store = @import("sample_store.zig");
const Capture = capture_model.Capture;

pub const version = "xodb-derived-flame-v1";
pub const reason_count = @typeInfo(unwind.Reason).@"enum".fields.len;
pub const max_reason_examples = 4;
pub const Bucket = enum { complete, partial, leaf_only, unavailable, excluded };
pub const bucket_meaning = .{
    .complete = "CFI reached a terminal return-address rule; inline and optimized-away calls are not reconstructed",
    .partial = "the leaf and some callers are recovered; callers above the terminal reason are unknown, not absent",
    .leaf_only = "only the sampled PC is known (no stack bytes, budget gap, missing asset or CFI at the leaf)",
    .unavailable = "no usable registers or sampled state; nothing beyond the recorded callchain",
    .excluded = "dropped whole because the flame graph reached its node limit",
};

/// Zig allocations of one derived build (graph, names, order, unwinder
/// state). libdw's own allocations are outside this budget.
pub const memory_limit: usize = 64 * 1024 * 1024;
/// Cache identity of a derived view: the immutable capture evidence (ID and
/// revision), the exact filter, the loaded asset set and the algorithm.
pub const Key = struct {
    capture_id: u64 = 0,
    revision: u64 = 0,
    filter: capture_model.Filter = .{},
    assets: u64 = 0,
    pub fn of(capture: *const Capture, filter: capture_model.Filter) Key {
        return .{ .capture_id = capture.id, .revision = capture.revision, .filter = filter, .assets = assetSet(capture) };
    }
};
/// Identity of the loaded ELF assets without hashing their bytes: module IDs,
/// placement and the identity of the held mapping. Content fingerprints are
/// computed once per build, in `unwind.Batch`.
pub fn assetSet(capture: *const Capture) u64 {
    var h = std.hash.Wyhash.init(0x16);
    h.update(version);
    h.update(unwind.algorithm);
    for (capture.images.loaded.items) |image| {
        h.update(std.mem.asBytes(&image.id));
        h.update(std.mem.asBytes(&image.bias));
        h.update(std.mem.asBytes(&image.mapping.len));
        h.update(std.mem.asBytes(&@intFromPtr(image.mapping.ptr)));
    }
    for (capture.pe_assets.entries.items) |image| {
        h.update("PE");
        h.update(std.mem.asBytes(&image.id));
        h.update(std.mem.asBytes(&image.bias));
        h.update(std.mem.asBytes(&image.mapping.len));
        h.update(std.mem.asBytes(&@intFromPtr(image.mapping.ptr)));
    }
    return h.final();
}
pub const Counts = struct {
    /// Samples matching the filter: the denominator.
    filtered: u64 = 0,
    complete: u64 = 0,
    partial: u64 = 0,
    leaf_only: u64 = 0,
    unavailable: u64 = 0,
    excluded: u64 = 0,
    /// Terminal reason of every filtered sample, by `unwind.Reason`.
    by_reason: [reason_count]u64 = @splat(0),
    /// Samples outside the filter, and samples no filter can place (no time/TID, before start, unknown thread).
    outside_filter: u64 = 0,
    unfilterable: u64 = 0,
    pub fn bucketTotal(self: Counts) u64 {
        return self.complete + self.partial + self.leaf_only + self.unavailable + self.excluded;
    }
};
pub const View = struct {
    arena: std.heap.ArenaAllocator,
    graph: flame.Graph,
    /// First sample ordinal that reached each node (parallel to graph nodes).
    examples: []u32,
    reason_examples: [reason_count][max_reason_examples]u32 = undefined,
    reason_example_count: [reason_count]u8 = @splat(0),
    counts: Counts = .{},
    filter: capture_model.Filter,
    /// Hex SHA-256 over version, filter, and every included sample's analysis ID in order.
    identity: [64]u8 = undefined,
    elf_bytes_hashed: u64 = 0,
    /// Worker wall time and peak budgeted bytes, set by the job.
    build_ns: u64 = 0,
    peak_bytes: usize = 0,
    pub fn deinit(self: *View) void {
        self.graph.deinit();
        self.arena.deinit();
    }
};

fn sampleThread(capture: *const Capture, sample: *const sample_store.Core) ?usize {
    if (!sample.timePresent() or sample.time_ns < capture.started_ns or !sample.tidPresent()) return null;
    for (capture.threads[0..capture.thread_count], 0..) |thread, i| if (thread.perf.tid == sample.tid) return i;
    return null;
}
fn bucketOf(result: *const unwind.Result) Bucket {
    if (result.reason == .complete and result.count > 0) return .complete;
    if (result.count >= 2) return .partial;
    if (result.count == 1) return .leaf_only;
    return .unavailable;
}

/// Builds the view; `a` should be a counting budget. Cancellation is checked
/// per sample and inside the unwinder.
pub fn build(a: std.mem.Allocator, capture: *const Capture, filter: capture_model.Filter, cancel: ?*const std.atomic.Value(bool), progress: ?*std.atomic.Value(usize)) !View {
    return buildWithLimit(a, capture, filter, cancel, progress, flame.max_nodes);
}
pub fn buildWithLimit(a: std.mem.Allocator, capture: *const Capture, filter: capture_model.Filter, cancel: ?*const std.atomic.Value(bool), progress: ?*std.atomic.Value(usize), node_limit: usize) !View {
    if (capture.collector != null) return error.ArchiveStillCollecting;
    try capture.validateFilter(filter);
    var view = View{ .arena = std.heap.ArenaAllocator.init(a), .graph = try flame.Graph.init(a), .examples = &.{}, .filter = filter };
    errdefer view.deinit();
    view.graph.limit = @min(node_limit, flame.max_nodes);
    const arena = view.arena.allocator();
    var batch = unwind.Batch.init(a, capture, cancel);
    defer batch.deinit();
    var identity = std.crypto.hash.sha2.Sha256.init(.{});
    identity.update(version);
    identity.update(unwind.algorithm);
    var filter_bytes: [20]u8 = undefined;
    std.mem.writeInt(u64, filter_bytes[0..8], filter.from_ns, .little);
    std.mem.writeInt(u64, filter_bytes[8..16], filter.to_ns, .little);
    std.mem.writeInt(u32, filter_bytes[16..20], filter.tid orelse 0, .little);
    identity.update(&filter_bytes);
    filter.tids.hashInto(&identity);
    // The same time order (ties by ordinal) the recorded graph uses.
    const order = try a.alloc(u32, capture.samples.len());
    defer a.free(order);
    for (order, 0..) |*index, i| index.* = @intCast(i);
    std.mem.sort(u32, order, &capture.samples, struct {
        fn less(samples: *const sample_store.Store, l: u32, r: u32) bool {
            const x = samples.core(l).time_ns;
            const y = samples.core(r).time_ns;
            return if (x == y) l < r else x < y;
        }
    }.less);
    var examples = try a.alloc(u32, flame.max_nodes);
    defer a.free(examples);
    @memset(examples, std.math.maxInt(u32));
    examples[0] = std.math.maxInt(u32);
    for (order, 0..) |ordinal, done| {
        if (cancel) |flag| if (flag.load(.acquire)) return error.ArchiveCancelled;
        if (progress) |p| p.store(done, .release);
        const sample = capture.samples.core(ordinal);
        const thread_index = sampleThread(capture, sample) orelse {
            view.counts.unfilterable += 1;
            continue;
        };
        if (!filter.contains(sample.tid, sample.time_ns - capture.started_ns)) {
            view.counts.outside_filter += 1;
            continue;
        }
        view.counts.filtered += 1;
        const result = try batch.walk(ordinal);
        identity.update(&result.analysis_id);
        view.counts.by_reason[@intFromEnum(result.reason)] += 1;
        const slot = @intFromEnum(result.reason);
        if (view.reason_example_count[slot] < max_reason_examples) {
            view.reason_examples[slot][view.reason_example_count[slot]] = ordinal;
            view.reason_example_count[slot] += 1;
        }
        var path: [unwind.max_frames + 2]flame.Frame = undefined;
        var marker_label: [160]u8 = undefined;
        var address_labels: [unwind.max_frames][32]u8 = undefined;
        var count: usize = 0;
        const thread = capture.threads[thread_index];
        path[count] = .{ .kind = .thread, .address = sample.tid, .module_id = thread.debugger_id, .name = std.mem.sliceTo(&capture.thread_names[thread_index], 0) };
        count += 1;
        const bucket = bucketOf(&result);
        if (bucket != .complete) {
            const prefix = switch (bucket) {
                .partial => "callers unknown",
                .leaf_only => "leaf only",
                else => "no stack",
            };
            path[count] = .{ .kind = if (bucket == .unavailable) .unknown else .incomplete, .address = 0x100 + @as(u64, @intFromEnum(bucket)) * 0x100 + @intFromEnum(result.reason), .name = try std.fmt.bufPrint(&marker_label, "[{s}: {s}]", .{ prefix, @tagName(result.reason) }) };
            count += 1;
        }
        // Outermost caller first, the sampled leaf last and only once.
        var index = result.count;
        while (index > 0) {
            index -= 1;
            const frame = result.frames[index];
            const named = frame.name_len > 0 and frame.module_id != 0;
            path[count] = .{
                .kind = if (named) .code else .unknown,
                .module_id = frame.module_id,
                .mapping_id = frame.mapping_id,
                .address = if (named) frame.symbol_address orelse frame.lookup_pc else frame.lookup_pc,
                .lookup_address = frame.lookup_pc,
                .name = if (named) result.frames[index].name[0..frame.name_len] else try std.fmt.bufPrint(&address_labels[index], "0x{x}", .{frame.lookup_pc}),
            };
            count += 1;
        }
        const before = view.graph.rejected;
        const old_nodes = view.graph.nodes.items.len;
        try view.graph.add(path[0..count]);
        // Names scale with distinct nodes, not samples. Temporary path labels
        // are valid until the next sample; detach only newly inserted nodes.
        for (view.graph.nodes.items[old_nodes..]) |*node| node.frame.name = try arena.dupe(u8, node.frame.name);
        if (view.graph.rejected != before) {
            view.counts.excluded += 1;
            continue;
        }
        switch (bucket) {
            .complete => view.counts.complete += 1,
            .partial => view.counts.partial += 1,
            .leaf_only => view.counts.leaf_only += 1,
            .unavailable => view.counts.unavailable += 1,
            .excluded => unreachable,
        }
        // First sample reaching each node, for stable citations.
        var node: u32 = 0;
        for (path[0..count]) |step| {
            node = view.graph.findChild(node, step) orelse break;
            if (examples[node] == std.math.maxInt(u32)) examples[node] = ordinal;
        }
    }
    try view.graph.layout();
    view.examples = try arena.dupe(u32, examples[0..view.graph.nodes.items.len]);
    view.elf_bytes_hashed = batch.hashed_bytes;
    view.identity = std.fmt.bytesToHex(identity.finalResult(), .lower);
    std.debug.assert(view.counts.bucketTotal() == view.counts.filtered);
    return view;
}
