//! Ended-store latency cohorts. Counts are raw denominators, durations are
//! measured wall intervals, and captured words retain their exact unsigned bits.
//! These summaries imply neither CPU time nor causal allocation/syscall links.
const std = @import("std");
const calls = @import("calls.zig");
const types = @import("types.zig");
const Allocator = std.mem.Allocator;
pub const max_top_n = 32;
pub const ArgumentFilter = struct { index: u8, value: u64 };
pub const Selection = struct {
    /// Fast is strictly below this duration; slow is greater than or equal.
    threshold_ns: u64,
    thread_id: ?u64 = null,
    function_id: ?u32 = null,
    /// Half-open entry-time window. Unpaired returns use their own timestamp;
    /// the time anchor is raw evidence, never a guessed missing entry time.
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,
    argument: ?ArgumentFilter = null,
    return_value: ?u64 = null,
    top_n: usize = 8,
    memory_limit: usize = 64 * 1024 * 1024,
    pub fn validate(self: Selection) !void {
        if (self.top_n == 0 or self.top_n > max_top_n or self.memory_limit == 0 or self.memory_limit > 512 * 1024 * 1024 or
            (self.start_ns != null and self.end_ns != null and self.start_ns.? > self.end_ns.?) or
            (self.argument != null and self.argument.?.index >= types.max_arguments)) return error.InvalidObservationSelection;
    }
};
pub const ValueCount = struct {
    value: u64,
    count: u64,
    representative_call: u32,
    entry_record: u32,
    return_record: u32,
};
pub const Distribution = struct {
    /// Both known and unavailable use the cohort call count as denominator.
    known: u64 = 0,
    unavailable: u64 = 0,
    distinct: u64 = 0,
    values: []ValueCount = &.{},
    omitted_values: u64 = 0,
    omitted_count: u64 = 0,
    fn deinit(self: *Distribution, a: Allocator) void {
        a.free(self.values);
    }
};
pub const Duration = struct {
    count: u64 = 0,
    /// Sum of inclusive call durations; nested/parallel intervals may overlap.
    /// Exact numerator; consumers must not round this through a JSON float.
    total_ns: u128 = 0,
    min_ns: ?u64 = null,
    max_ns: ?u64 = null,
    p50_ns: ?u64 = null,
    p90_ns: ?u64 = null,
    p99_ns: ?u64 = null,
    /// Convenience display value; total_ns/count retains exact evidence.
    mean_ns: ?f64 = null,
};
pub const Cohort = struct {
    count: u64 = 0,
    duration: Duration = .{},
    arguments: [types.max_arguments]Distribution = @splat(.{}),
    returns: Distribution = .{},
    /// Up to three distinct calls in duration order (low, middle, high).
    representative_calls: [3]?u32 = @splat(null),
    fn deinit(self: *Cohort, a: Allocator) void {
        for (&self.arguments) |*distribution| distribution.deinit(a);
        self.returns.deinit(a);
    }
};
pub const reason_count = @typeInfo(types.Reason).@"enum".fields.len;
pub const Summary = struct {
    total_calls: u64 = 0,
    matched_calls: u64 = 0,
    filtered_calls: u64 = 0,
    unavailable_filter_calls: u64 = 0,
    complete_calls: u64 = 0,
    incomplete_calls: u64 = 0,
    incomplete_by_reason: [reason_count]u64 = @splat(0),
};
pub const Comparison = struct {
    selection: Selection,
    summary: Summary = .{},
    fast: Cohort = .{},
    slow: Cohort = .{},
    pub fn deinit(self: *Comparison, a: Allocator) void {
        self.fast.deinit(a);
        self.slow.deinit(a);
    }
};
pub const Match = enum { yes, no, unavailable };
const DurationItem = struct { call_id: u32, ns: u64 };
const ValueItem = struct { value: u64, call_id: u32 };
fn checkpoint(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
}
pub fn matches(store: *const calls.Store, call: types.Call, selection: Selection) Match {
    if (selection.thread_id) |id| if (call.thread_id != id) return .no;
    if (selection.function_id) |id| if (call.function_id != id) return .no;
    const anchor = call.entry_record orelse call.return_record orelse return .unavailable;
    const time = store.records.items[anchor].event.time_ns;
    if (selection.start_ns) |start| if (time < start) return .no;
    if (selection.end_ns) |end| if (time >= end) return .no;
    var unavailable = false;
    if (selection.argument) |filter| {
        if (call.entry_record) |ordinal| {
            const entry = store.records.items[ordinal].event.data.sample;
            if (filter.index >= entry.arg_count) unavailable = true else if (entry.args[filter.index] != filter.value) return .no;
        } else unavailable = true;
    }
    if (selection.return_value) |value| {
        if (call.return_record) |ordinal| {
            if (store.records.items[ordinal].event.data.sample.result) |actual| {
                if (actual != value) return .no;
            } else unavailable = true;
        } else unavailable = true;
    }
    return if (unavailable) .unavailable else .yes;
}
fn durationLess(_: void, a: DurationItem, b: DurationItem) bool {
    return a.ns < b.ns or (a.ns == b.ns and a.call_id < b.call_id);
}
fn valueLess(_: void, a: ValueItem, b: ValueItem) bool {
    return a.value < b.value or (a.value == b.value and a.call_id < b.call_id);
}
fn rankBetter(a: ValueCount, b: ValueCount) bool {
    return a.count > b.count or (a.count == b.count and a.value < b.value);
}
fn percentile(items: []const DurationItem, percent: usize) u64 {
    // Nearest rank, including the single-value case, with no interpolation.
    return items[(items.len * percent + 99) / 100 - 1].ns;
}
fn summarizeDuration(items: []DurationItem) Duration {
    var result: Duration = .{ .count = items.len };
    if (items.len == 0) return result;
    std.mem.sort(DurationItem, items, {}, durationLess);
    for (items) |item| result.total_ns += item.ns;
    result.min_ns = items[0].ns;
    result.max_ns = items[items.len - 1].ns;
    result.p50_ns = percentile(items, 50);
    result.p90_ns = percentile(items, 90);
    result.p99_ns = percentile(items, 99);
    result.mean_ns = @as(f64, @floatFromInt(result.total_ns)) / @as(f64, @floatFromInt(items.len));
    return result;
}
fn summarizeValues(a: Allocator, store: *const calls.Store, items: []const DurationItem, scratch: []ValueItem, argument: ?usize, top_n: usize, cancel: ?*const std.atomic.Value(bool)) !Distribution {
    var result: Distribution = .{};
    var count: usize = 0;
    for (items, 0..) |item, i| {
        if (i % 1024 == 0) try checkpoint(cancel);
        const call = store.calls.items[item.call_id];
        const entry = store.records.items[call.entry_record.?].event.data.sample;
        const ret = store.records.items[call.return_record.?].event.data.sample;
        const value: ?u64 = if (argument) |index| (if (index < entry.arg_count) entry.args[index] else null) else ret.result;
        if (value) |bits| {
            scratch[count] = .{ .value = bits, .call_id = item.call_id };
            count += 1;
        } else result.unavailable += 1;
    }
    result.known = count;
    std.mem.sort(ValueItem, scratch[0..count], {}, valueLess);
    try checkpoint(cancel);
    var top: [max_top_n]ValueCount = undefined;
    var top_len: usize = 0;
    var cursor: usize = 0;
    while (cursor < count) {
        if (cursor % 1024 == 0) try checkpoint(cancel);
        const first = scratch[cursor];
        var end = cursor + 1;
        while (end < count and scratch[end].value == first.value) : (end += 1) {}
        const call = store.calls.items[first.call_id];
        const item: ValueCount = .{
            .value = first.value,
            .count = end - cursor,
            .representative_call = first.call_id,
            .entry_record = call.entry_record.?,
            .return_record = call.return_record.?,
        };
        result.distinct += 1;
        var position: usize = 0;
        while (position < top_len and !rankBetter(item, top[position])) : (position += 1) {}
        if (position < top_n) {
            const next_len = @min(top_len + 1, top_n);
            var shift = next_len;
            while (shift > position + 1) {
                shift -= 1;
                top[shift] = top[shift - 1];
            }
            top[position] = item;
            top_len = next_len;
        }
        cursor = end;
    }
    result.values = try a.dupe(ValueCount, top[0..top_len]);
    result.omitted_values = result.distinct - top_len;
    result.omitted_count = result.known;
    for (result.values) |item| result.omitted_count -= item.count;
    return result;
}
fn summarizeCohort(a: Allocator, store: *const calls.Store, cohort: *Cohort, items: []DurationItem, scratch: []ValueItem, top_n: usize, cancel: ?*const std.atomic.Value(bool)) !void {
    cohort.count = items.len;
    cohort.duration = summarizeDuration(items);
    try checkpoint(cancel);
    if (items.len != 0) cohort.representative_calls[0] = items[0].call_id;
    if (items.len > 1) cohort.representative_calls[1] = items[items.len / 2].call_id;
    if (items.len > 2) cohort.representative_calls[2] = items[items.len - 1].call_id;
    for (0..types.max_arguments) |index|
        cohort.arguments[index] = try summarizeValues(a, store, items, scratch, index, top_n, cancel);
    cohort.returns = try summarizeValues(a, store, items, scratch, null, top_n, cancel);
}
pub fn build(a: Allocator, store: *const calls.Store, selection: Selection) !Comparison {
    return buildWithCancel(a, store, selection, null);
}
pub fn buildWithCancel(a: Allocator, store: *const calls.Store, selection: Selection, cancel: ?*const std.atomic.Value(bool)) !Comparison {
    if (!store.finished) return error.ObservationStillCollecting;
    try selection.validate();
    try checkpoint(cancel);
    var result: Comparison = .{ .selection = selection };
    errdefer result.deinit(a);
    var counts: [2]usize = @splat(0);
    for (store.calls.items, 0..) |call, i| {
        if (i % 1024 == 0) try checkpoint(cancel);
        result.summary.total_calls += 1;
        switch (matches(store, call, selection)) {
            .no => result.summary.filtered_calls += 1,
            .unavailable => result.summary.unavailable_filter_calls += 1,
            .yes => {
                result.summary.matched_calls += 1;
                if (store.duration(call)) |ns| {
                    result.summary.complete_calls += 1;
                    counts[@intFromBool(ns >= selection.threshold_ns)] += 1;
                } else {
                    result.summary.incomplete_calls += 1;
                    result.summary.incomplete_by_reason[@intFromEnum(call.reason)] += 1;
                }
            },
        }
    }
    const scratch_count = @max(counts[0], counts[1]);
    const bytes = (counts[0] + counts[1]) * @sizeOf(DurationItem) + scratch_count * @sizeOf(ValueItem) +
        (types.max_arguments + 1) * (@min(selection.top_n, counts[0]) + @min(selection.top_n, counts[1])) * @sizeOf(ValueCount);
    if (bytes > selection.memory_limit) return error.ObservationComparisonMemoryLimit;
    const fast = try a.alloc(DurationItem, counts[0]);
    defer a.free(fast);
    const slow = try a.alloc(DurationItem, counts[1]);
    defer a.free(slow);
    const scratch = try a.alloc(ValueItem, scratch_count);
    defer a.free(scratch);
    var at: [2]usize = @splat(0);
    const buckets = [2][]DurationItem{ fast, slow };
    for (store.calls.items, 0..) |call, i| {
        if (i % 1024 == 0) try checkpoint(cancel);
        if (matches(store, call, selection) != .yes) continue;
        const ns = store.duration(call) orelse continue;
        const bucket: usize = @intFromBool(ns >= selection.threshold_ns);
        buckets[bucket][at[bucket]] = .{ .call_id = call.id, .ns = ns };
        at[bucket] += 1;
    }
    try summarizeCohort(a, store, &result.fast, fast, scratch, selection.top_n, cancel);
    try summarizeCohort(a, store, &result.slow, slow, scratch, selection.top_n, cancel);
    return result;
}

fn fixtureCall(store: *calls.Store, a: Allocator, thread: u64, time: u64, duration: u64, arg: ?u64, result: ?u64) !void {
    var entry = calls.fixtureEvent(time, thread, .enter, 1, 100);
    if (arg) |bits| {
        entry.data.sample.arg_count = 1;
        entry.data.sample.args[0] = bits;
    }
    try store.feed(a, entry);
    var ret = calls.fixtureEvent(time + duration, thread, .leave, 1, 100);
    ret.data.sample.result = result;
    try store.feed(a, ret);
}
test "empty and one-call cohorts retain exact denominators and unavailable fields" {
    const a = std.testing.allocator;
    var empty = try calls.Store.init(.{});
    defer empty.deinit(a);
    empty.finish(.capture_end);
    var zero = try build(a, &empty, .{ .threshold_ns = 1 });
    defer zero.deinit(a);
    try std.testing.expectEqual(@as(u64, 0), zero.summary.total_calls);
    try std.testing.expectEqual(@as(?u64, null), zero.fast.duration.p50_ns);
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixtureCall(&store, a, 1, 5, 0, null, null);
    store.finish(.capture_end);
    var one = try build(a, &store, .{ .threshold_ns = 0 });
    defer one.deinit(a);
    try std.testing.expectEqual(@as(u64, 0), one.fast.count);
    try std.testing.expectEqual(@as(u64, 1), one.slow.count);
    try std.testing.expectEqual(@as(?u64, 0), one.slow.duration.p99_ns);
    try std.testing.expectEqual(@as(u64, 1), one.slow.arguments[0].unavailable);
    try std.testing.expectEqual(@as(u64, 1), one.slow.returns.unavailable);
    try std.testing.expectEqual(@as(?u32, 0), one.slow.representative_calls[0]);
}
test "unequal cohorts top-N counts and incomplete exclusions are conserved" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixtureCall(&store, a, 1, 0, 1, 0xffffffffffffffff, 9);
    try fixtureCall(&store, a, 1, 10, 2, 0xffffffffffffffff, 9);
    try fixtureCall(&store, a, 1, 20, 3, 7, 10);
    try fixtureCall(&store, a, 1, 30, 4, 8, null);
    try fixtureCall(&store, a, 2, 0, 20, 42, 9);
    try store.feed(a, calls.fixtureEvent(100, 1, .enter, 1, 100));
    store.finish(.cancelled);
    var view = try build(a, &store, .{ .threshold_ns = 10, .top_n = 1 });
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 6), view.summary.total_calls);
    try std.testing.expectEqual(@as(u64, 5), view.summary.complete_calls);
    try std.testing.expectEqual(@as(u64, 1), view.summary.incomplete_calls);
    try std.testing.expectEqual(@as(u64, 4), view.fast.count);
    try std.testing.expectEqual(@as(u64, 1), view.slow.count);
    try std.testing.expectEqual(@as(u128, 10), view.fast.duration.total_ns);
    try std.testing.expectEqual(@as(?u64, 2), view.fast.duration.p50_ns);
    try std.testing.expectEqual(@as(?u64, 4), view.fast.duration.p99_ns);
    const args = view.fast.arguments[0];
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), args.values[0].value);
    try std.testing.expectEqual(@as(u64, 2), args.values[0].count);
    try std.testing.expectEqual(@as(u64, 2), args.omitted_count);
    try std.testing.expectEqual(@as(u64, 2), args.omitted_values);
    try std.testing.expectEqual(@as(u64, 1), view.fast.returns.unavailable);
    try std.testing.expectEqual(@as(u32, 0), args.values[0].entry_record);
    try std.testing.expectEqual(@as(u32, 1), args.values[0].return_record);
    try std.testing.expectEqual(@as(u64, 1), view.summary.incomplete_by_reason[@intFromEnum(types.Reason.cancelled)]);
}
test "entry-time thread and exact-value selection never substitutes missing values" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixtureCall(&store, a, 1, 0, 10, 5, 10);
    try fixtureCall(&store, a, 1, 20, 10, null, 10);
    try fixtureCall(&store, a, 1, 40, 10, 5, null);
    try fixtureCall(&store, a, 2, 0, 10, 5, 10);
    store.finish(.capture_end);
    var view = try build(a, &store, .{ .threshold_ns = 10, .thread_id = 1, .start_ns = 0, .end_ns = 40, .argument = .{ .index = 0, .value = 5 }, .return_value = 10 });
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), view.summary.matched_calls);
    try std.testing.expectEqual(@as(u64, 2), view.summary.filtered_calls);
    try std.testing.expectEqual(@as(u64, 1), view.summary.unavailable_filter_calls);
    try std.testing.expectEqual(@as(u64, 1), view.slow.count);
}
test "large duration sums are exact beyond u64 and analysis is bounded" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixtureCall(&store, a, 1, 0, std.math.maxInt(u64), 1, 2);
    try fixtureCall(&store, a, 2, 0, std.math.maxInt(u64), 1, 2);
    store.finish(.capture_end);
    var view = try build(a, &store, .{ .threshold_ns = 0 });
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u128, std.math.maxInt(u64)) * 2, view.slow.duration.total_ns);
    try std.testing.expectError(error.ObservationComparisonMemoryLimit, build(a, &store, .{ .threshold_ns = 0, .memory_limit = 1 }));
    try std.testing.expectError(error.InvalidObservationSelection, build(a, &store, .{ .threshold_ns = 0, .start_ns = 10, .end_ns = 1 }));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ObservationAnalysisCancelled, buildWithCancel(a, &store, .{ .threshold_ns = 0 }, &cancel));
}
fn allocationFailure(a: Allocator, store: *const calls.Store) !void {
    var view = try build(a, store, .{ .threshold_ns = 5 });
    defer view.deinit(a);
}
test "cohort allocations roll back at every failure" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    for (0..12) |i| try fixtureCall(&store, a, 1, i * 20, i, i, i + 1);
    store.finish(.capture_end);
    try std.testing.checkAllAllocationFailures(a, allocationFailure, .{&store});
}

test "unmatched return window and unknown filters retain explicit counts" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    var ret = calls.fixtureEvent(15, 1, .leave, 1, 100);
    ret.data.sample.result = 7;
    try store.feed(a, ret);
    store.finish(.capture_end);
    var view = try build(a, &store, .{ .threshold_ns = 0, .start_ns = 10, .end_ns = 20, .return_value = 7 });
    defer view.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), view.summary.matched_calls);
    try std.testing.expectEqual(@as(u64, 1), view.summary.incomplete_calls);
    try std.testing.expectEqual(@as(u64, 0), view.fast.count + view.slow.count);
    var unknown = try build(a, &store, .{ .threshold_ns = 0, .argument = .{ .index = 0, .value = 0 } });
    defer unknown.deinit(a);
    try std.testing.expectEqual(@as(u64, 1), unknown.summary.unavailable_filter_calls);
    try std.testing.expectEqual(@as(u64, 0), unknown.summary.matched_calls);
}
