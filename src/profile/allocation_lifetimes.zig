//! Analysis foundation for paired, top-level allocator calls. No live collector.
//! Entry/return bound allocator effects; the view never calls outstanding bytes leaks.
const std = @import("std");
pub const max_calls = 65536;
pub const Kind = enum { malloc, calloc, realloc, free };
pub const Call = struct {
    kind: Kind,
    thread: u64,
    entry_ns: u64,
    return_ns: u64,
    arg0: u64,
    arg1: u64 = 0,
    result: u64 = 0,
};
pub const State = enum { outstanding, released, reallocated, reuse_without_free, zero_size_unknown, ambiguous };
pub const Lifetime = struct {
    allocation_call: usize,
    release_call: ?usize = null,
    pointer: u64,
    size: u64,
    state: State = .outstanding,
    /// Bounds on lifetime within the allocator. Free entry is not the instant
    /// its internal implementation relinquished the object.
    min_ns: ?u64 = null,
    max_ns: ?u64 = null,
};
pub const Summary = struct {
    successful_allocations: u64 = 0,
    failed_allocations: u64 = 0,
    zero_size_null: u64 = 0,
    unmatched_releases: u64 = 0,
    null_frees: u64 = 0,
    reused_without_free: u64 = 0,
    zero_size_unknown: u64 = 0,
    ambiguous_effects: u64 = 0,
    outstanding_count: u64 = 0,
    outstanding_bytes: u64 = 0,
    bytes_overflow: bool = false,
};
pub const View = struct {
    lifetimes: std.ArrayList(Lifetime) = .empty,
    summary: Summary = .{},
    pub fn deinit(self: *View, a: std.mem.Allocator) void {
        self.lifetimes.deinit(a);
    }
};
const Effect = struct { time: u64, call: usize, pointer: u64, size: u64 = 0, kind: enum { allocate, release, resize_release, unknown_release } };
fn less(calls: []const Call, left: Effect, right: Effect) bool {
    if (left.time != right.time) return left.time < right.time;
    if (calls[left.call].thread != calls[right.call].thread) return calls[left.call].thread < calls[right.call].thread;
    if (left.call != right.call) return left.call < right.call;
    // A zero-duration realloc must retire the old generation before publishing
    // the new one. Cross-thread ties are detected separately and not ordered.
    return left.kind != .allocate and right.kind == .allocate;
}
fn append(a: std.mem.Allocator, effects: *std.ArrayList(Effect), effect: Effect) !void {
    try effects.append(a, effect);
}
/// Calls must be complete, paired and top-level, retaining order within each
/// thread. Unpaired/lost evidence remains queryable elsewhere; do not derive
/// associations across it. `evidence_complete` is a collector/parser gate,
/// not a claim that every allocator or thread in the process was observed.
pub fn build(a: std.mem.Allocator, calls: []const Call, evidence_complete: bool) !View {
    return buildWithCancel(a, calls, evidence_complete, null);
}
fn checkCancel(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.AllocationAnalysisCancelled;
}
pub fn buildWithCancel(a: std.mem.Allocator, calls: []const Call, evidence_complete: bool, cancel: ?*const std.atomic.Value(bool)) !View {
    try checkCancel(cancel);
    if (!evidence_complete) return error.AllocationEvidenceGap;
    if (calls.len > max_calls) return error.AllocationCallLimit;
    var out = View{};
    errdefer out.deinit(a);
    var effects: std.ArrayList(Effect) = .empty;
    defer effects.deinit(a);
    try effects.ensureTotalCapacityPrecise(a, calls.len * 2);
    var last_return: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer last_return.deinit(a);
    for (calls, 0..) |call, index| {
        if (index % 1024 == 0) try checkCancel(cancel);
        if (call.thread == 0 or call.return_ns < call.entry_ns) return error.InvalidAllocationCall;
        const last = try last_return.getOrPut(a, call.thread);
        if (last.found_existing and call.entry_ns < last.value_ptr.*) return error.OverlappingAllocatorCalls;
        last.value_ptr.* = call.return_ns;
        const bytes = switch (call.kind) {
            .malloc => call.arg0,
            .calloc => std.math.mul(u64, call.arg0, call.arg1) catch {
                if (call.result != 0) return error.InvalidAllocationResult;
                out.summary.failed_allocations += 1;
                continue;
            },
            .realloc => call.arg1,
            .free => 0,
        };
        if (call.kind == .free) {
            if (call.arg0 == 0) out.summary.null_frees += 1 else try append(a, &effects, .{ .time = call.entry_ns, .call = index, .pointer = call.arg0, .kind = .release });
            continue;
        }
        if (call.kind == .realloc and call.arg0 != 0) {
            if (call.result != 0) {
                try append(a, &effects, .{ .time = call.entry_ns, .call = index, .pointer = call.arg0, .kind = .resize_release });
            } else if (bytes == 0) {
                // Allocator-specific realloc(p, 0) semantics are deliberately
                // unresolved. Exclude the old row from outstanding totals.
                try append(a, &effects, .{ .time = call.entry_ns, .call = index, .pointer = call.arg0, .kind = .unknown_release });
                out.summary.zero_size_unknown += 1;
                continue;
            }
        }
        if (call.result == 0) {
            if (bytes == 0) out.summary.zero_size_null += 1 else out.summary.failed_allocations += 1;
            continue;
        }
        out.summary.successful_allocations += 1;
        try append(a, &effects, .{ .time = call.return_ns, .call = index, .pointer = call.result, .size = bytes, .kind = .allocate });
    }
    try checkCancel(cancel);
    std.mem.sort(Effect, effects.items, calls, less);
    try checkCancel(cancel);
    var active: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    defer active.deinit(a);
    const Tie = struct { thread: u64, ambiguous: bool = false };
    var ties: std.AutoHashMapUnmanaged(u64, Tie) = .empty;
    defer ties.deinit(a);
    var begin: usize = 0;
    while (begin < effects.items.len) {
        try checkCancel(cancel);
        var end = begin + 1;
        while (end < effects.items.len and effects.items[end].time == effects.items[begin].time) : (end += 1) {}
        ties.clearRetainingCapacity();
        for (effects.items[begin..end]) |effect| {
            const tied = try ties.getOrPut(a, effect.pointer);
            const thread = calls[effect.call].thread;
            if (!tied.found_existing) tied.value_ptr.* = .{ .thread = thread } else if (tied.value_ptr.thread != thread) tied.value_ptr.ambiguous = true;
        }
        for (effects.items[begin..end]) |effect| {
            if (ties.get(effect.pointer).?.ambiguous) {
                out.summary.ambiguous_effects += 1;
                if (active.fetchRemove(effect.pointer)) |old| out.lifetimes.items[old.value].state = .ambiguous;
                if (effect.kind == .allocate) try out.lifetimes.append(a, .{ .allocation_call = effect.call, .pointer = effect.pointer, .size = effect.size, .state = .ambiguous });
                continue;
            }
            if (effect.kind == .allocate) {
                if (active.fetchRemove(effect.pointer)) |old| {
                    out.lifetimes.items[old.value].state = .reuse_without_free;
                    out.summary.reused_without_free += 1;
                }
                const index = out.lifetimes.items.len;
                try out.lifetimes.append(a, .{ .allocation_call = effect.call, .pointer = effect.pointer, .size = effect.size });
                try active.put(a, effect.pointer, index);
            } else if (active.fetchRemove(effect.pointer)) |old| {
                const row = &out.lifetimes.items[old.value];
                row.release_call = effect.call;
                row.state = switch (effect.kind) {
                    .release => .released,
                    .resize_release => .reallocated,
                    .unknown_release => .zero_size_unknown,
                    .allocate => unreachable,
                };
                if (effect.kind != .unknown_release) {
                    const birth = calls[row.allocation_call];
                    const release = calls[effect.call];
                    row.min_ns = release.entry_ns -| birth.return_ns;
                    row.max_ns = release.return_ns - birth.entry_ns;
                }
            } else out.summary.unmatched_releases += 1;
        }
        begin = end;
    }
    for (out.lifetimes.items, 0..) |row, index| {
        if (index % 1024 == 0) try checkCancel(cancel);
        if (row.state != .outstanding) continue;
        out.summary.outstanding_count += 1;
        const sum = @addWithOverflow(out.summary.outstanding_bytes, row.size);
        if (sum[1] != 0) {
            out.summary.bytes_overflow = true;
            out.summary.outstanding_bytes = std.math.maxInt(u64);
        } else out.summary.outstanding_bytes = sum[0];
    }
    return out;
}

test "cross-thread release sorted by timestamps, requested bytes and lifetime bounds" {
    const a = std.testing.allocator;
    // Drain order differs from time order across threads.
    var view = try build(a, &.{
        .{ .kind = .free, .thread = 2, .entry_ns = 40, .return_ns = 60, .arg0 = 0x1000 },
        .{ .kind = .malloc, .thread = 1, .entry_ns = 10, .return_ns = 20, .arg0 = 64, .result = 0x1000 },
        .{ .kind = .calloc, .thread = 1, .entry_ns = 21, .return_ns = 30, .arg0 = 3, .arg1 = 7, .result = 0x2000 },
    }, true);
    defer view.deinit(a);
    try std.testing.expectEqual(State.released, view.lifetimes.items[0].state);
    try std.testing.expectEqual(@as(?u64, 20), view.lifetimes.items[0].min_ns);
    try std.testing.expectEqual(@as(?u64, 50), view.lifetimes.items[0].max_ns);
    try std.testing.expectEqual(@as(u64, 21), view.summary.outstanding_bytes);
}

test "realloc failure preserves old object; same-pointer success makes a new generation" {
    const a = std.testing.allocator;
    var view = try build(a, &.{
        .{ .kind = .malloc, .thread = 1, .entry_ns = 1, .return_ns = 2, .arg0 = 16, .result = 99 },
        .{ .kind = .realloc, .thread = 1, .entry_ns = 3, .return_ns = 4, .arg0 = 99, .arg1 = 1024, .result = 0 },
        .{ .kind = .realloc, .thread = 1, .entry_ns = 5, .return_ns = 6, .arg0 = 99, .arg1 = 24, .result = 99 },
    }, true);
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), view.summary.failed_allocations);
    try std.testing.expectEqual(State.reallocated, view.lifetimes.items[0].state);
    try std.testing.expectEqual(@as(?usize, 2), view.lifetimes.items[0].release_call);
    try std.testing.expectEqual(@as(u64, 24), view.summary.outstanding_bytes);
}

test "zero-size realloc and unobserved frees do not masquerade as known lifetimes" {
    const a = std.testing.allocator;
    var view = try build(a, &.{
        .{ .kind = .malloc, .thread = 1, .entry_ns = 1, .return_ns = 2, .arg0 = 16, .result = 99 },
        .{ .kind = .realloc, .thread = 1, .entry_ns = 3, .return_ns = 4, .arg0 = 99, .arg1 = 0 },
        .{ .kind = .free, .thread = 1, .entry_ns = 5, .return_ns = 6, .arg0 = 0 },
        .{ .kind = .free, .thread = 1, .entry_ns = 7, .return_ns = 8, .arg0 = 77 },
        .{ .kind = .malloc, .thread = 1, .entry_ns = 9, .return_ns = 10, .arg0 = 4, .result = 55 },
        .{ .kind = .malloc, .thread = 1, .entry_ns = 11, .return_ns = 12, .arg0 = 8, .result = 55 },
    }, true);
    defer view.deinit(a);
    try std.testing.expectEqual(State.zero_size_unknown, view.lifetimes.items[0].state);
    try std.testing.expectEqual(@as(?u64, null), view.lifetimes.items[0].max_ns);
    try std.testing.expectEqual(@as(u64, 1), view.summary.null_frees);
    try std.testing.expectEqual(@as(u64, 1), view.summary.unmatched_releases);
    try std.testing.expectEqual(State.reuse_without_free, view.lifetimes.items[1].state);
    try std.testing.expectEqual(@as(u64, 8), view.summary.outstanding_bytes);
}

test "cross-thread equal-time address reuse is ambiguous, not arbitrarily ordered" {
    const a = std.testing.allocator;
    var view = try build(a, &.{
        .{ .kind = .malloc, .thread = 1, .entry_ns = 1, .return_ns = 2, .arg0 = 8, .result = 55 },
        .{ .kind = .free, .thread = 1, .entry_ns = 4, .return_ns = 8, .arg0 = 55 },
        .{ .kind = .malloc, .thread = 2, .entry_ns = 3, .return_ns = 4, .arg0 = 16, .result = 55 },
    }, true);
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 2), view.summary.ambiguous_effects);
    try std.testing.expectEqual(State.ambiguous, view.lifetimes.items[0].state);
    try std.testing.expectEqual(State.ambiguous, view.lifetimes.items[1].state);
    try std.testing.expectEqual(@as(u64, 0), view.summary.outstanding_bytes);
}

test "reject gaps, impossible calloc success, overlap and excessive input" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.AllocationEvidenceGap, build(a, &.{}, false));
    const huge = Call{ .kind = .calloc, .thread = 1, .entry_ns = 1, .return_ns = 2, .arg0 = std.math.maxInt(u64), .arg1 = 2, .result = 1 };
    try std.testing.expectError(error.InvalidAllocationResult, build(a, &.{huge}, true));
    var failed = huge;
    failed.result = 0;
    var view = try build(a, &.{failed}, true);
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), view.summary.failed_allocations);
    try std.testing.expectError(error.OverlappingAllocatorCalls, build(a, &.{
        .{ .kind = .malloc, .thread = 1, .entry_ns = 1, .return_ns = 20, .arg0 = 8, .result = 55 },
        .{ .kind = .free, .thread = 1, .entry_ns = 2, .return_ns = 3, .arg0 = 55 },
    }, true));
    const too_many = try a.alloc(Call, max_calls + 1);
    defer a.free(too_many);
    try std.testing.expectError(error.AllocationCallLimit, build(a, too_many, true));
}

fn allocationFailureCase(a: std.mem.Allocator) !void {
    var view = try build(a, &.{
        .{ .kind = .malloc, .thread = 1, .entry_ns = 1, .return_ns = 2, .arg0 = 12, .result = 55 },
        .{ .kind = .free, .thread = 2, .entry_ns = 4, .return_ns = 8, .arg0 = 55 },
        .{ .kind = .realloc, .thread = 3, .entry_ns = 3, .return_ns = 4, .arg0 = 0, .arg1 = 16, .result = 55 },
    }, true);
    defer view.deinit(a);
}
test "allocation failure releases every partial analysis allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "maximum distinct-address history has bounded analysis memory" {
    const a = std.testing.allocator;
    const calls = try a.alloc(Call, max_calls);
    defer a.free(calls);
    for (calls, 0..) |*call, i| call.* = .{ .kind = .malloc, .thread = 1, .entry_ns = i * 2, .return_ns = i * 2 + 1, .arg0 = 16, .result = (i + 1) * 16 };
    var budget = @import("archive_budget.zig").Budget{ .backing = a, .limit = 32 * 1024 * 1024 };
    var view = try build(budget.allocator(), calls, true);
    try std.testing.expectEqual(@as(u64, max_calls), view.summary.outstanding_count);
    try std.testing.expectEqual(@as(u64, max_calls * 16), view.summary.outstanding_bytes);
    view.deinit(budget.allocator());
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    std.debug.print("allocation analysis peak: {d} bytes / {d} calls\n", .{ budget.peak, max_calls });
}
