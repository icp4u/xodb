//! Byte/count-weighted allocation call trees from finalized lifetime evidence.
const std = @import("std");
const model = @import("allocation_capture.zig");
const flame = @import("flame.zig");
const stacks = @import("allocation_stacks.zig");
const Budget = @import("archive_budget.zig").Budget;
pub const Owner = enum { gui, mcp };
pub const Metric = enum { allocated_bytes, outstanding_bytes, allocations };
pub const Key = struct { capture: model.Key, filter: model.Filter, metric: Metric };
pub const View = struct {
    graph: flame.Graph,
    allocations: u64 = 0,
    caller_stacks: u64 = 0,
    missing_stacks: u64 = 0,
    excluded_weight: u64 = 0,
    zero_weight: u64 = 0,
    pub fn deinit(self: *View) void {
        self.graph.deinit();
    }
};
pub fn build(a: std.mem.Allocator, capture: *const model.Capture, filter: model.Filter, metric: Metric, cancel: *const std.atomic.Value(bool)) !View {
    if (capture.worker != null or capture.state != .ready) return error.AllocationAnalysisPending;
    if (filter.from_ns > filter.to_ns) return error.InvalidAllocationPage;
    if (filter.thread_id) |id| {
        const found = for (capture.threads[0..capture.thread_count]) |thread| {
            if (thread.id == id) break true;
        } else false;
        if (!found) return error.InvalidAllocationThread;
    }
    const analysis = capture.analysis orelse return error.AllocationAnalysisPending;
    var view = View{ .graph = try flame.Graph.init(a) };
    errdefer view.deinit();
    view.graph.nodes.items[0].frame.name = if (metric == .allocations) "Successful allocations" else if (metric == .outstanding_bytes) "Outstanding requested bytes" else "Allocated requested bytes";
    for (analysis.view.lifetimes.items) |row| {
        if (cancel.load(.acquire)) return error.AllocationAnalysisCancelled;
        const span = capture.store.spans.items[analysis.projection.span_ids[row.allocation_call]];
        const entry = capture.store.records.items[span.entry_record.?];
        const thread = capture.threads[span.lane];
        if (filter.thread_id != null and filter.thread_id.? != thread.id) continue;
        if (entry.event.time_ns < filter.from_ns or entry.event.time_ns > filter.to_ns) continue;
        if ((filter.outstanding_only or metric == .outstanding_bytes) and row.state != .outstanding) continue;
        const weight = if (metric == .allocations) 1 else row.size;
        view.allocations += 1;
        if (weight == 0) {
            view.zero_weight += 1;
            continue;
        }
        var path: [stacks.max_frames + 2]flame.Frame = undefined;
        path[0] = .{ .kind = .thread, .address = thread.id, .name = "allocation thread" };
        var count: usize = 1;
        const stack = if (entry.event.data.sample.stack) |id| &capture.stacks.entries.items[id] else null;
        if (stack != null and stack.?.count > 0) {
            if (stack.?.count > 1 and stack.?.status != .caller_missing) view.caller_stacks += 1 else view.missing_stacks += 1;
            path[count] = .{ .kind = .incomplete, .address = @intFromEnum(stack.?.status), .name = switch (stack.?.status) {
                .depth_limit => "stack depth limit",
                .caller_missing => "entry caller unavailable; frame-pointer prefix",
                else => "older callers not established; frame-pointer prefix",
            } };
            count += 1;
            var depth: usize = stack.?.count;
            while (depth > 0) {
                depth -= 1;
                path[count] = capture.stackFrame(stack.?.pcs[depth], depth);
                count += 1;
            }
        } else {
            view.missing_stacks += 1;
            path[count] = .{ .kind = .incomplete, .name = "allocation stack unavailable" };
            count += 1;
        }
        const rejected = view.graph.rejected;
        try view.graph.addWeighted(path[0..count], weight);
        if (view.graph.rejected != rejected) view.excluded_weight = try std.math.add(u64, view.excluded_weight, weight);
    }
    try view.graph.ownLabels();
    try view.graph.layout();
    return view;
}

pub const Job = struct {
    request_owner: @import("../service/job_owner.zig").Owner = .{},
    key: Key,
    capture: *const model.Capture,
    budget: Budget,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    result: ?View = null,
    failure: ?anyerror = null,
    const allocator = std.heap.page_allocator;
    pub fn create(capture: *const model.Capture, filter: model.Filter, metric: Metric) !*Job {
        const self = try allocator.create(Job);
        errdefer allocator.destroy(self);
        self.* = .{ .key = .{ .capture = capture.key(), .filter = filter, .metric = metric }, .capture = capture, .budget = .{ .backing = allocator, .limit = 64 * 1024 * 1024 } };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        self.result = build(self.budget.allocator(), self.capture, self.key.filter, self.key.metric, &self.cancel) catch |err| blk: {
            self.failure = if (self.budget.denied) error.AllocationHeapMemoryLimit else err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    pub fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit();
        std.debug.assert(self.budget.used == 0);
        allocator.destroy(self);
    }
};
