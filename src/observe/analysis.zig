//! A comparison never borrows a live collector; its ended capture is pinned by
//! the session until this worker has been joined.
const std = @import("std");
const comparison = @import("comparison.zig");
const model = @import("capture.zig");
const Budget = @import("../profile/archive_budget.zig").Budget;
pub const Job = struct {
    id: u64,
    capture: *const model.Capture,
    selection: comparison.Selection,
    budget: Budget,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    result: ?comparison.Comparison = null,
    err: ?anyerror = null,
    pub fn create(id: u64, capture: *const model.Capture, selection: comparison.Selection) !*Job {
        if (!capture.store.finished) return error.ObservationStillCollecting;
        const a = std.heap.page_allocator;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .id = id, .capture = capture, .selection = selection, .budget = .{ .backing = a, .limit = 64 * 1024 * 1024 } };
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        self.result = comparison.buildWithCancel(self.budget.allocator(), &self.capture.store, self.selection, &self.cancel) catch |err| blk: {
            self.err = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    pub fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        if (self.worker) |worker| worker.join();
        if (self.result) |*result| result.deinit(self.budget.allocator());
        std.heap.page_allocator.destroy(self);
    }
};
