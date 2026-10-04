//! Bounded allocator entry/return evidence, independent of the transport.
//! A collector must provide a verified hook identity and normalized call-stack
//! key. No kernel register convention is assumed here. Loss or uncertain
//! pairing blocks lifetime derivation; raw records remain available for review.
const std = @import("std");
const lifetime = @import("allocation_lifetimes.zig");
const Allocator = std.mem.Allocator;
pub const max_threads = 32;
pub const max_depth = 32;
pub const max_records = lifetime.max_calls * 2;
pub const default_records = 32768;
pub const Phase = enum { enter, leave };
pub const Sample = struct {
    phase: Phase,
    hook: u16,
    kind: lifetime.Kind,
    /// Same nonzero key at entry/return. Nested ordinary downward-growing
    /// stacks have smaller keys. Equal/upward entries are ambiguous, including
    /// tail-call aliases and abandoned frames: do not silently infer nesting.
    stack_key: u64,
    ip: u64 = 0,
    arg0: u64 = 0,
    arg1: u64 = 0,
    result: u64 = 0,
    /// Allocation-entry stack citation, independent of the pairing stack key.
    stack: ?u32 = null,
};
pub const Event = struct {
    time_ns: u64,
    data: union(enum) { sample: Sample, lost: u64, throttle, unthrottle, thread_exit, exec, decode_error },
};
pub const Record = struct { lane: u16, event: Event };
pub const Reason = enum {
    pending,
    complete,
    missing_entry,
    capture_end,
    thread_exit,
    exec,
    loss,
    throttle,
    decode_error,
    hook_mismatch,
    stack_mismatch,
    stack_changed,
    time_reversed,
    nesting_limit,
    record_limit,
    memory_limit,
    identity,
    unread,
};
pub const Span = struct {
    lane: u16,
    entry_record: ?u32 = null,
    return_record: ?u32 = null,
    parent_span: ?u32 = null,
    reason: Reason = .pending,
};
pub const Gap = struct { reason: Reason, record: ?u32 };
const Lane = struct {
    stack: [max_depth]u32 = undefined,
    depth: usize = 0,
    last_ns: u64 = 0,
    closed: bool = false,
};
pub const Projection = struct {
    calls: []lifetime.Call,
    /// Map the analysis call index back to an immutable span citation.
    span_ids: []u32,
    pub fn deinit(self: Projection, a: Allocator) void {
        a.free(self.calls);
        a.free(self.span_ids);
    }
};
pub const Store = struct {
    records: std.ArrayList(Record) = .empty,
    spans: std.ArrayList(Span) = .empty,
    lanes: [max_threads]Lane = @splat(.{}),
    lane_count: usize,
    limit: usize,
    finished: bool = false,
    unread_possible: bool = false,
    first_gap: ?Gap = null,
    lost: u64 = 0,
    throttles: u64 = 0,
    rejected: u64 = 0,
    nested: u64 = 0,
    pub fn init(lane_count: usize, limit: usize) !Store {
        if (lane_count == 0 or lane_count > max_threads or limit == 0 or limit > max_records) return error.InvalidAllocationConfig;
        return .{ .lane_count = lane_count, .limit = limit };
    }
    pub fn deinit(self: *Store, a: Allocator) void {
        self.records.deinit(a);
        self.spans.deinit(a);
    }
    fn gap(self: *Store, reason: Reason, record: ?u32) void {
        if (self.first_gap == null) self.first_gap = .{ .reason = reason, .record = record };
    }
    fn boundary(self: *Store, index: usize, reason: Reason) void {
        const lane = &self.lanes[index];
        for (lane.stack[0..lane.depth]) |id| self.spans.items[id].reason = reason;
        lane.depth = 0;
    }
    fn stop(self: *Store, reason: Reason) void {
        if (reason == .record_limit or reason == .memory_limit or reason == .exec) self.unread_possible = true;
        for (0..self.lane_count) |i| self.boundary(i, reason);
        self.finished = true;
    }
    fn capacity(self: *Store, a: Allocator) !void {
        // Reserve both before accepting a record; allocation failure cannot
        // leave a partially appended event that looks complete.
        if (self.records.items.len == self.records.capacity)
            try self.records.ensureTotalCapacityPrecise(a, @min(self.limit, @max(64, self.records.capacity * 2)));
        if (self.spans.items.len == self.spans.capacity)
            try self.spans.ensureTotalCapacityPrecise(a, @min(self.limit, @max(64, self.spans.capacity * 2)));
    }
    pub fn feed(self: *Store, a: Allocator, index: usize, event: Event) !void {
        if (self.finished) return error.AllocationFinished;
        if (index >= self.lane_count or self.lanes[index].closed) {
            self.rejected +|= 1;
            self.gap(.identity, null);
            return error.InvalidAllocationIdentity;
        }
        if (self.records.items.len == self.limit) {
            self.rejected +|= 1;
            self.gap(.record_limit, null);
            self.stop(.record_limit);
            return error.AllocationRecordLimit;
        }
        self.capacity(a) catch |err| {
            self.rejected +|= 1;
            self.gap(.memory_limit, null);
            self.stop(.memory_limit);
            return err;
        };
        const ordinal: u32 = @intCast(self.records.items.len);
        self.records.appendAssumeCapacity(.{ .lane = @intCast(index), .event = event });
        const lane = &self.lanes[index];
        if (event.time_ns < lane.last_ns) {
            self.gap(.time_reversed, ordinal);
            self.boundary(index, .time_reversed);
            return error.AllocationTimeReversed;
        }
        lane.last_ns = event.time_ns;
        switch (event.data) {
            .lost => |n| {
                self.lost +|= n;
                self.gap(.loss, ordinal);
                self.boundary(index, .loss);
            },
            .throttle, .unthrottle => {
                if (event.data == .throttle) self.throttles +|= 1;
                self.gap(.throttle, ordinal);
                self.boundary(index, .throttle);
            },
            .decode_error => {
                self.gap(.decode_error, ordinal);
                self.boundary(index, .decode_error);
            },
            .thread_exit => {
                if (lane.depth > 0) self.gap(.thread_exit, ordinal);
                self.boundary(index, .thread_exit);
                lane.closed = true;
            },
            .exec => {
                // The heap/address identity was replaced; the owner closes all
                // collectors. No allocation history crosses that boundary.
                self.gap(.exec, ordinal);
                self.stop(.exec);
            },
            .sample => |sample| {
                if (sample.stack_key == 0) {
                    self.gap(.stack_mismatch, ordinal);
                    self.boundary(index, .stack_mismatch);
                    return error.AllocationStackKeyUnavailable;
                }
                if (sample.phase == .enter) {
                    if (lane.depth > 0) {
                        const previous = self.records.items[self.spans.items[lane.stack[lane.depth - 1]].entry_record.?].event.data.sample;
                        // glibc free can tail-reenter its own entry after lazy
                        // tcache initialization. Uretprobes report one return
                        // per entry at the shared SP. Keep both spans, derive
                        // the outer operation once, and require all returns.
                        const same_arguments = sample.arg0 == previous.arg0 and
                            (switch (sample.kind) {
                                .calloc, .realloc => sample.arg1 == previous.arg1,
                                else => true,
                            });
                        const tail_reentry = sample.stack_key == previous.stack_key and sample.hook == previous.hook and
                            sample.kind == previous.kind and sample.ip == previous.ip and same_arguments;
                        if (sample.stack_key > previous.stack_key or (sample.stack_key == previous.stack_key and !tail_reentry)) {
                            self.gap(.stack_changed, ordinal);
                            self.boundary(index, .stack_changed);
                        }
                    }
                    if (lane.depth == max_depth) {
                        self.gap(.nesting_limit, ordinal);
                        self.boundary(index, .nesting_limit);
                        // Preserve the entry as unpaired evidence. It cannot
                        // become a valid new top-level call after overflow.
                        self.spans.appendAssumeCapacity(.{ .lane = @intCast(index), .entry_record = ordinal, .reason = .nesting_limit });
                        return error.AllocationNestingLimit;
                    }
                    const span: u32 = @intCast(self.spans.items.len);
                    self.spans.appendAssumeCapacity(.{ .lane = @intCast(index), .entry_record = ordinal, .parent_span = if (lane.depth > 0) lane.stack[lane.depth - 1] else null });
                    if (lane.depth > 0) self.nested +|= 1;
                    lane.stack[lane.depth] = span;
                    lane.depth += 1;
                } else {
                    if (lane.depth > 0) {
                        const span = &self.spans.items[lane.stack[lane.depth - 1]];
                        const entry = self.records.items[span.entry_record.?].event.data.sample;
                        const mismatch: ?Reason = if (entry.hook != sample.hook or entry.kind != sample.kind) .hook_mismatch else if (entry.stack_key != sample.stack_key) .stack_mismatch else null;
                        if (mismatch) |reason| {
                            self.gap(reason, ordinal);
                            self.boundary(index, reason);
                        } else {
                            span.return_record = ordinal;
                            span.reason = .complete;
                            lane.depth -= 1;
                            return;
                        }
                    }
                    self.gap(.missing_entry, ordinal);
                    self.spans.appendAssumeCapacity(.{ .lane = @intCast(index), .return_record = ordinal, .reason = .missing_entry });
                }
            },
        }
    }
    /// The collector must disable every source and drain every lane before
    /// claiming a complete end. A bounded/failed drain leaves an unknown suffix.
    pub fn finish(self: *Store, unread_possible: bool) void {
        if (self.finished) return;
        self.unread_possible = unread_possible;
        if (unread_possible) self.gap(.unread, null);
        for (self.lanes[0..self.lane_count]) |lane| if (lane.depth > 0) {
            self.gap(.capture_end, null);
            break;
        };
        self.stop(if (unread_possible) .unread else .capture_end);
    }
    /// A complete, finalized trace of observed public top-level calls. This
    /// does not imply coverage of all allocators or threads, or prove a leak.
    pub fn project(self: *const Store, a: Allocator) !Projection {
        return self.projectWithCancel(a, null);
    }
    /// External source/identity failures have no safe complete suffix.
    pub fn abort(self: *Store, reason: Reason) void {
        std.debug.assert(reason != .complete and reason != .pending);
        if (self.finished) return;
        self.unread_possible = true;
        self.gap(reason, null);
        self.stop(reason);
    }
    pub fn projectWithCancel(self: *const Store, a: Allocator, cancel: ?*const std.atomic.Value(bool)) !Projection {
        if (cancel) |flag| if (flag.load(.acquire)) return error.AllocationAnalysisCancelled;
        if (!self.finished) return error.AllocationStillCollecting;
        if (self.first_gap != null) return error.AllocationEvidenceGap;
        var count: usize = 0;
        for (self.spans.items, 0..) |span, index| {
            if (index % 1024 == 0) if (cancel) |flag| if (flag.load(.acquire)) return error.AllocationAnalysisCancelled;
            if (span.reason != .complete) return error.AllocationEvidenceGap;
            if (span.parent_span == null) count += 1;
        }
        if (count > lifetime.max_calls) return error.AllocationCallLimit;
        const calls = try a.alloc(lifetime.Call, count);
        errdefer a.free(calls);
        const ids = try a.alloc(u32, count);
        errdefer a.free(ids);
        var at: usize = 0;
        for (self.spans.items, 0..) |span, id| {
            if (id % 1024 == 0) if (cancel) |flag| if (flag.load(.acquire)) return error.AllocationAnalysisCancelled;
            if (span.parent_span != null) continue;
            const entry = self.records.items[span.entry_record.?].event;
            const ret = self.records.items[span.return_record.?].event;
            calls[at] = .{ .kind = entry.data.sample.kind, .thread = @as(u64, span.lane) + 1, .entry_ns = entry.time_ns, .return_ns = ret.time_ns, .arg0 = entry.data.sample.arg0, .arg1 = entry.data.sample.arg1, .result = ret.data.sample.result };
            ids[at] = @intCast(id);
            at += 1;
        }
        return .{ .calls = calls, .span_ids = ids };
    }
};

fn testSample(time: u64, phase: Phase, kind: lifetime.Kind, stack_key: u64, arg0: u64, result: u64) Event {
    return .{ .time_ns = time, .data = .{ .sample = .{ .phase = phase, .hook = @intFromEnum(kind), .kind = kind, .stack_key = stack_key, .arg0 = arg0, .result = result } } };
}
test "nested allocator calls retain citations and collapse to the outer call" {
    const a = std.testing.allocator;
    var store = try Store.init(1, 64);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 40, 0));
    try store.feed(a, 0, testSample(2, .enter, .calloc, 80, 5, 0));
    try store.feed(a, 0, testSample(3, .leave, .calloc, 80, 0, 99));
    try store.feed(a, 0, testSample(4, .leave, .malloc, 100, 0, 99));
    try std.testing.expectError(error.AllocationStillCollecting, store.project(a));
    store.finish(false);
    const calls = try store.project(a);
    defer calls.deinit(a);
    try std.testing.expectEqual(@as(usize, 4), store.records.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.spans.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.nested);
    try std.testing.expectEqual(@as(?u32, 0), store.spans.items[1].parent_span);
    try std.testing.expectEqual(@as(usize, 1), calls.calls.len);
    try std.testing.expectEqual(@as(u64, 40), calls.calls[0].arg0);
    try std.testing.expectEqual(@as(u32, 0), calls.span_ids[0]);
    var view = try lifetime.build(a, calls.calls, true);
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 40), view.summary.outstanding_bytes);
}
test "cross-thread drain order preserves per-thread evidence and lifetime order" {
    const a = std.testing.allocator;
    var store = try Store.init(2, 16);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(10, .enter, .free, 100, 99, 0));
    try store.feed(a, 0, testSample(12, .leave, .free, 100, 0, 0));
    try store.feed(a, 1, testSample(1, .enter, .malloc, 200, 40, 0));
    try store.feed(a, 1, testSample(3, .leave, .malloc, 200, 0, 99));
    store.finish(false);
    const calls = try store.project(a);
    defer calls.deinit(a);
    var view = try lifetime.build(a, calls.calls, true);
    defer view.deinit(a);
    try std.testing.expectEqual(lifetime.State.released, view.lifetimes.items[0].state);
    try std.testing.expectEqual(@as(?u64, 7), view.lifetimes.items[0].min_ns);
}
test "lost return cannot pair through a gap; later complete evidence stays inspectable" {
    const a = std.testing.allocator;
    var store = try Store.init(1, 16);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 40, 0));
    try store.feed(a, 0, .{ .time_ns = 2, .data = .{ .lost = 5 } });
    try store.feed(a, 0, testSample(3, .leave, .malloc, 100, 0, 99));
    try store.feed(a, 0, testSample(4, .enter, .malloc, 100, 16, 0));
    try store.feed(a, 0, testSample(5, .leave, .malloc, 100, 0, 123));
    store.finish(false);
    try std.testing.expectEqual(Reason.loss, store.spans.items[0].reason);
    try std.testing.expectEqual(Reason.missing_entry, store.spans.items[1].reason);
    try std.testing.expectEqual(Reason.complete, store.spans.items[2].reason);
    try std.testing.expectEqual(@as(u64, 5), store.lost);
    try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
}
test "mismatched hook or stack and a missing entry block derivation" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |bad_stack| {
        var store = try Store.init(1, 16);
        defer store.deinit(a);
        try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 40, 0));
        try store.feed(a, 0, testSample(2, .leave, if (bad_stack) .malloc else .calloc, if (bad_stack) 88 else 100, 0, 99));
        store.finish(false);
        try std.testing.expectEqual(if (bad_stack) Reason.stack_mismatch else Reason.hook_mismatch, store.first_gap.?.reason);
        try std.testing.expectEqual(@as(usize, 2), store.spans.items.len);
        try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
    }
}
test "upward and equal stack entries never silently become nested calls" {
    const a = std.testing.allocator;
    for ([_]u64{ 100, 120 }) |key| {
        var store = try Store.init(1, 16);
        defer store.deinit(a);
        try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 40, 0));
        try store.feed(a, 0, testSample(2, .enter, .free, key, 99, 0));
        try store.feed(a, 0, testSample(3, .leave, .free, key, 0, 0));
        store.finish(false);
        try std.testing.expectEqual(Reason.stack_changed, store.first_gap.?.reason);
        try std.testing.expectEqual(@as(?u32, null), store.spans.items[1].parent_span);
        try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
    }
}
test "capture stop, task exit and exec expose unfinished calls" {
    const a = std.testing.allocator;
    for ([_]Reason{ .capture_end, .thread_exit, .exec }) |reason| {
        var store = try Store.init(2, 16);
        defer store.deinit(a);
        try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 40, 0));
        if (reason == .capture_end) store.finish(false) else try store.feed(a, 0, .{ .time_ns = 2, .data = if (reason == .exec) .exec else .thread_exit });
        store.finish(false);
        try std.testing.expectEqual(reason, store.spans.items[0].reason);
        try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
    }
    var store = try Store.init(1, 4);
    defer store.deinit(a);
    try store.feed(a, 0, .{ .time_ns = 1, .data = .thread_exit });
    try std.testing.expectError(error.InvalidAllocationIdentity, store.feed(a, 0, testSample(2, .enter, .malloc, 100, 4, 0)));
}
test "nesting and record limits preserve raw evidence and flag rejected suffix" {
    const a = std.testing.allocator;
    var deep = try Store.init(1, 64);
    defer deep.deinit(a);
    for (0..max_depth) |i| try deep.feed(a, 0, testSample(i, .enter, .malloc, 1000 - i, 4, 0));
    try std.testing.expectError(error.AllocationNestingLimit, deep.feed(a, 0, testSample(max_depth, .enter, .malloc, 1000 - max_depth, 4, 0)));
    try std.testing.expectEqual(@as(usize, max_depth + 1), deep.records.items.len);
    try std.testing.expectEqual(Reason.nesting_limit, deep.first_gap.?.reason);
    var short = try Store.init(1, 1);
    defer short.deinit(a);
    try short.feed(a, 0, testSample(1, .enter, .malloc, 100, 4, 0));
    try std.testing.expectError(error.AllocationRecordLimit, short.feed(a, 0, testSample(2, .leave, .malloc, 100, 0, 99)));
    try std.testing.expectEqual(Reason.record_limit, short.spans.items[0].reason);
    try std.testing.expectEqual(@as(u64, 1), short.rejected);
    try std.testing.expect(short.finished);
    try std.testing.expect(short.unread_possible);
}
test "clock reversal retains the bad record and prevents plausible false durations" {
    const a = std.testing.allocator;
    var store = try Store.init(1, 16);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(5, .enter, .malloc, 100, 4, 0));
    try std.testing.expectError(error.AllocationTimeReversed, store.feed(a, 0, testSample(4, .leave, .malloc, 100, 0, 99)));
    store.finish(false);
    try std.testing.expectEqual(@as(usize, 2), store.records.items.len);
    try std.testing.expectEqual(Reason.time_reversed, store.first_gap.?.reason);
    try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
}
fn failingCase(a: Allocator) !void {
    var store = try Store.init(2, 256);
    defer store.deinit(a);
    for (0..96) |i| {
        try store.feed(a, i % 2, testSample(i * 2, .enter, .malloc, 100, 4, 0));
        try store.feed(a, i % 2, testSample(i * 2 + 1, .leave, .malloc, 100, 0, i + 1));
    }
    store.finish(false);
    const calls = try store.project(a);
    defer calls.deinit(a);
}
test "all partial record/span/projection allocations are released on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failingCase, .{});
}
test "maximum record store and projection have a measured memory bound" {
    var budget = @import("archive_budget.zig").Budget{ .backing = std.testing.allocator, .limit = 32 * 1024 * 1024 };
    const a = budget.allocator();
    var store = try Store.init(1, max_records);
    for (0..lifetime.max_calls) |i| {
        try store.feed(a, 0, testSample(i * 2, .enter, .malloc, 100, 4, 0));
        try store.feed(a, 0, testSample(i * 2 + 1, .leave, .malloc, 100, 0, i + 1));
    }
    store.finish(false);
    const calls = try store.project(a);
    try std.testing.expectEqual(@as(usize, lifetime.max_calls), calls.calls.len);
    var view = try lifetime.build(a, calls.calls, true);
    try std.testing.expectEqual(@as(u64, lifetime.max_calls), view.summary.outstanding_count);
    view.deinit(a);
    calls.deinit(a);
    store.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    @import("../m68k_log.zig").print("allocation events/projection/analysis peak: {d} bytes / {d} records\n", .{ budget.peak, max_records });
}

test "throttle and decode boundaries mark open calls; finished evidence is immutable" {
    const a = std.testing.allocator;
    for ([_]Event{
        .{ .time_ns = 2, .data = .throttle },
        .{ .time_ns = 2, .data = .unthrottle },
        .{ .time_ns = 2, .data = .decode_error },
    }) |event| {
        var store = try Store.init(1, 16);
        defer store.deinit(a);
        try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 8, 0));
        try store.feed(a, 0, event);
        store.finish(false);
        try std.testing.expectEqual(if (event.data == .decode_error) Reason.decode_error else Reason.throttle, store.spans.items[0].reason);
        try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
    }
    var store = try Store.init(1, 16);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 8, 0));
    try store.feed(a, 0, testSample(2, .leave, .malloc, 100, 0, 99));
    try store.feed(a, 0, .{ .time_ns = 3, .data = .thread_exit });
    store.finish(false);
    try std.testing.expectError(error.AllocationFinished, store.feed(a, 0, testSample(4, .enter, .malloc, 100, 8, 0)));
    try std.testing.expectEqual(@as(?Gap, null), store.first_gap);
    const projection = try store.project(a);
    defer projection.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), projection.calls.len);
}

test "a stopped collector with an unread suffix cannot publish lifetime totals" {
    const a = std.testing.allocator;
    var store = try Store.init(1, 16);
    defer store.deinit(a);
    try store.feed(a, 0, testSample(1, .enter, .malloc, 100, 8, 0));
    try store.feed(a, 0, testSample(2, .leave, .malloc, 100, 0, 99));
    store.finish(true);
    try std.testing.expectEqual(Reason.complete, store.spans.items[0].reason);
    try std.testing.expectEqual(Reason.unread, store.first_gap.?.reason);
    try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
}

test "same-hook same-argument tail reentry retains both returns and derives one operation" {
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |complete| {
        var store = try Store.init(1, 16);
        defer store.deinit(a);
        try store.feed(a, 0, testSample(1, .enter, .free, 100, 0x1234, 0));
        try store.feed(a, 0, testSample(2, .enter, .free, 100, 0x1234, 0));
        try store.feed(a, 0, testSample(3, .leave, .free, 100, 0, 0));
        if (complete) try store.feed(a, 0, testSample(4, .leave, .free, 100, 0, 0));
        store.finish(false);
        try std.testing.expectEqual(@as(?u32, 0), store.spans.items[1].parent_span);
        if (complete) {
            const projection = try store.project(a);
            defer projection.deinit(a);
            try std.testing.expectEqual(@as(usize, 1), projection.calls.len);
            try std.testing.expectEqual(@as(u64, 0x1234), projection.calls[0].arg0);
            try std.testing.expectEqual(@as(u64, 4), projection.calls[0].return_ns);
        } else try std.testing.expectError(error.AllocationEvidenceGap, store.project(a));
    }
    var changed = try Store.init(1, 16);
    defer changed.deinit(a);
    try changed.feed(a, 0, testSample(1, .enter, .free, 100, 1, 0));
    try changed.feed(a, 0, testSample(2, .enter, .free, 100, 2, 0));
    changed.finish(false);
    try std.testing.expectEqual(Reason.stack_changed, changed.first_gap.?.reason);
}
