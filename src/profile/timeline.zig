//! Shared relative-time filtering, CPU density, and conservative scheduling spans.
//! This module does not open events or infer why a thread went off CPU.
const std = @import("std");
pub const max_bins = 512;
pub const max_transitions = 65536; // offline reconstruction bound; collection budget awaits T08
pub const max_markers = 1024;
pub const Range = struct {
    from_ns: u64,
    to_ns: u64,
    pub fn duration(self: Range) u64 {
        return self.to_ns -| self.from_ns;
    }
};
/// Sorted, owned TIDs. Copies held by workers never borrow GUI selection memory.
pub const ThreadSet = struct {
    pub const capacity = 1024;
    values: [capacity]u32 = @splat(0),
    len: u16 = 0,
    pub fn slice(self: *const ThreadSet) []const u32 {
        return self.values[0..self.len];
    }
    pub fn optional(self: *const ThreadSet) ?[]const u32 {
        return if (self.len == 0) null else self.slice();
    }
    pub fn has(self: *const ThreadSet, tid: u32) bool {
        var lo: usize = 0;
        var hi: usize = self.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.values[mid] < tid) lo = mid + 1 else hi = mid;
        }
        return lo < self.len and self.values[lo] == tid;
    }
    pub fn jsonStringify(self: ThreadSet, writer: *std.json.Stringify) !void {
        try writer.write(self.optional());
    }
    /// Preserve existing single/all-thread identities; append only multi-selection.
    pub fn hashInto(self: *const ThreadSet, hash: *std.crypto.hash.sha2.Sha256) void {
        if (self.len == 0) return;
        hash.update("multi-threads-v1");
        for (self.slice()) |tid| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, tid, .little);
            hash.update(&bytes);
        }
    }
};
pub const Filter = struct {
    tid: ?u32 = null,
    tids: ThreadSet = .{},
    from_ns: u64 = 0,
    to_ns: u64 = std.math.maxInt(u64),
    pub fn validate(self: *const Filter) !void {
        if (self.tids.len > ThreadSet.capacity or self.tids.len == 1 or (self.tid != null and self.tids.len != 0)) return error.InvalidProfileFilter;
        var previous: u32 = 0;
        for (self.tids.slice()) |tid| {
            if (tid <= previous or tid > std.math.maxInt(i32)) return error.InvalidProfileFilter;
            previous = tid;
        }
        for (self.tids.values[self.tids.len..]) |tid| if (tid != 0) return error.InvalidProfileFilter;
        if (self.from_ns >= self.to_ns or (self.tid != null and (self.tid.? == 0 or self.tid.? > std.math.maxInt(i32)))) return error.InvalidProfileFilter;
    }
    pub fn contains(self: *const Filter, tid: u32, offset_ns: u64) bool {
        return self.matchesThread(tid) and offset_ns >= self.from_ns and offset_ns < self.to_ns;
    }
    pub fn matchesThread(self: *const Filter, tid: u32) bool {
        if (self.tid) |single| return single == tid;
        return self.tids.len == 0 or self.tids.has(tid);
    }
    pub fn threadCount(self: *const Filter) usize {
        return if (self.tid != null) 1 else self.tids.len;
    }
    /// Normalize empty/single/multiple selections; order never changes identity.
    pub fn setThreads(self: *Filter, input: []const u32) !void {
        if (input.len > ThreadSet.capacity) return error.InvalidProfileFilter;
        var set = ThreadSet{};
        @memcpy(set.values[0..input.len], input);
        set.len = @intCast(input.len);
        std.mem.sort(u32, set.values[0..set.len], {}, std.sort.asc(u32));
        var previous: u32 = 0;
        for (set.slice()) |tid| {
            if (tid == 0 or tid > std.math.maxInt(i32) or tid == previous) return error.InvalidProfileFilter;
            previous = tid;
        }
        self.tid = if (input.len == 1) set.values[0] else null;
        self.tids = if (input.len == 1) .{} else set;
    }
    pub fn toggleThread(self: *Filter, tid: u32) !void {
        var next: [ThreadSet.capacity]u32 = undefined;
        var count: usize = 0;
        if (self.tid) |single| {
            if (single != tid) {
                next[0] = single;
                count = 1;
            }
        } else for (self.tids.slice()) |selected| {
            if (selected != tid) {
                next[count] = selected;
                count += 1;
            }
        }
        const selected = self.tid == tid or self.tids.has(tid);
        if (!selected) {
            if (count == next.len) return error.InvalidProfileFilter;
            next[count] = tid;
            count += 1;
        }
        try self.setThreads(next[0..count]);
    }
    pub fn clipped(self: *const Filter, extent_ns: u64) Range {
        return .{ .from_ns = @min(self.from_ns, extent_ns), .to_ns = @min(self.to_ns, extent_ns) };
    }
};
/// Owned selection state with no pointers into a capture arena. Full-range
/// selection follows live growth; an explicit end remains fixed until reset.
pub const Selection = struct {
    capture_id: u64 = 0,
    filter: Filter = .{},
    pub fn bind(self: *Selection, capture_id: u64, extent_ns: u64) void {
        if (self.capture_id != capture_id) {
            self.* = .{ .capture_id = capture_id };
        } else if (self.filter.to_ns != std.math.maxInt(u64)) {
            const clipped = self.filter.clipped(extent_ns);
            if (clipped.duration() == 0) {
                self.filter.from_ns = 0;
                self.filter.to_ns = std.math.maxInt(u64);
            } else {
                self.filter.from_ns = clipped.from_ns;
                self.filter.to_ns = clipped.to_ns;
            }
        }
    }
    pub fn set(self: *Selection, filter: Filter) !void {
        try filter.validate();
        self.filter = filter;
    }
    pub fn reset(self: *Selection) void {
        self.filter = .{};
    }
};
pub const Bin = struct { from_ns: u64, to_ns: u64, samples: u64 = 0 };
pub const Histogram = struct {
    allocator: std.mem.Allocator,
    range: Range,
    bins: []Bin,
    samples: u64 = 0,
    pub fn init(a: std.mem.Allocator, range: Range, requested_bins: usize) !Histogram {
        if (requested_bins == 0 or requested_bins > max_bins or range.from_ns > range.to_ns) return error.InvalidTimelineBins;
        const width = range.duration();
        const count = @min(requested_bins, width);
        const bins = try a.alloc(Bin, count);
        for (bins, 0..) |*bin, i| {
            bin.* = .{ .from_ns = range.from_ns + @as(u64, @intCast(@as(u128, width) * i / count)), .to_ns = range.from_ns + @as(u64, @intCast(@as(u128, width) * (i + 1) / count)) };
        }
        return .{ .allocator = a, .range = range, .bins = bins };
    }
    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.bins);
    }
    pub fn add(self: *Histogram, offset_ns: u64) void {
        if (offset_ns < self.range.from_ns or offset_ns >= self.range.to_ns) return;
        // Inverse of floor(i * width / count); u128 avoids overflow for long
        // captures and preserves the exact half-open boundary at every bin.
        const index: usize = @intCast(((@as(u128, offset_ns - self.range.from_ns) + 1) * self.bins.len - 1) / self.range.duration());
        self.bins[index].samples += 1;
        self.samples += 1;
    }
};
pub const Lane = struct { tid: u32, debugger_id: u64, enrolled_ns: ?u64 = null, samples: u64 = 0 };
pub const CpuTimeline = struct {
    histogram: Histogram,
    lanes: []Lane,
    invalid_samples: u64 = 0,
    pub fn deinit(self: *CpuTimeline) void {
        self.histogram.allocator.free(self.lanes);
        self.histogram.deinit();
    }
};
pub const Direction = enum { switch_in, switch_out };
/// A single lane, in original delivery order, already validated against the
/// opening perf task identity. T08's adapter will own identity validation.
pub const Transition = struct { offset_ns: u64, direction: Direction, preempted: bool = false };
pub const State = enum { running, off_cpu, unknown };
pub const Coverage = enum { available, disabled, lost, invalid_identity, incomplete, contradictory };
pub const Unknown = enum { unmatched_boundary, disabled, lost, invalid_identity, incomplete, contradictory, capacity };
pub const Span = struct {
    from_ns: u64,
    to_ns: u64,
    state: State,
    unknown_reason: ?Unknown = null,
    switch_out_preempted: ?bool = null,
    clipped_start: bool = false,
    clipped_end: bool = false,
};
fn appendSpan(a: std.mem.Allocator, spans: *std.ArrayList(Span), range: Range, original: Span) !void {
    var span = original;
    span.from_ns = @max(span.from_ns, range.from_ns);
    span.to_ns = @min(span.to_ns, range.to_ns);
    if (span.from_ns >= span.to_ns) return;
    span.clipped_start = span.from_ns != original.from_ns;
    span.clipped_end = span.to_ns != original.to_ns;
    try spans.append(a, span);
}
/// Returns a partition of the requested range clipped to [0, extent_ns).
/// An unlocalized loss invalidates the lane. Contradictory ordering also makes
/// the whole lane unknown: sorting must not conceal an evidence defect.
pub fn reconstruct(a: std.mem.Allocator, transitions: []const Transition, extent_ns: u64, range: Range, coverage: Coverage) ![]Span {
    if (range.from_ns > range.to_ns) return error.InvalidProfileFilter;
    if (transitions.len > max_transitions) return error.TimelineTransitionLimit;
    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(a);
    const clipped = Range{ .from_ns = @min(range.from_ns, extent_ns), .to_ns = @min(range.to_ns, extent_ns) };
    var reason: ?Unknown = switch (coverage) {
        .available => null,
        .disabled => .disabled,
        .lost => .lost,
        .invalid_identity => .invalid_identity,
        .incomplete => .incomplete,
        .contradictory => .contradictory,
    };
    if (reason == null) for (transitions, 0..) |event, i| {
        if (event.offset_ns > extent_ns or (event.preempted and event.direction != .switch_out) or
            (i > 0 and (event.offset_ns <= transitions[i - 1].offset_ns or event.direction == transitions[i - 1].direction)))
        {
            reason = .contradictory;
            break;
        }
    };
    if (reason != null or transitions.len == 0) {
        try appendSpan(a, &spans, clipped, .{ .from_ns = 0, .to_ns = extent_ns, .state = .unknown, .unknown_reason = reason orelse .unmatched_boundary });
    } else {
        try appendSpan(a, &spans, clipped, .{ .from_ns = 0, .to_ns = transitions[0].offset_ns, .state = .unknown, .unknown_reason = .unmatched_boundary });
        for (transitions[0 .. transitions.len - 1], transitions[1..]) |first, last| {
            const off = first.direction == .switch_out;
            try appendSpan(a, &spans, clipped, .{ .from_ns = first.offset_ns, .to_ns = last.offset_ns, .state = if (off) .off_cpu else .running, .switch_out_preempted = if (off) first.preempted else null });
        }
        try appendSpan(a, &spans, clipped, .{ .from_ns = transitions[transitions.len - 1].offset_ns, .to_ns = extent_ns, .state = .unknown, .unknown_reason = .unmatched_boundary });
    }
    return spans.toOwnedSlice(a);
}
pub const MarkerKind = enum { capture_open_stopped, continued, stop, step_started, step_complete, breakpoint_hit, watchpoint_hit, exit, detach };
pub const Marker = struct { offset_ns: u64, sequence: u64, tid: i32, kind: MarkerKind };
pub const marker_basis = "debugger event observation/control timestamps, not exact kernel scheduler boundaries; capture_open_stopped applies to all selected threads";

test "histogram uneven boundaries conserve every nanosecond and exclude the end" {
    const a = std.testing.allocator;
    for (1..40) |width| for (1..20) |bins| {
        var h = try Histogram.init(a, .{ .from_ns = 100, .to_ns = 100 + width }, bins);
        defer h.deinit();
        for (99..102 + width) |offset| h.add(offset);
        try std.testing.expectEqual(width, h.samples);
        var next: u64 = 100;
        for (h.bins) |bin| {
            try std.testing.expectEqual(next, bin.from_ns);
            try std.testing.expectEqual(bin.to_ns - bin.from_ns, bin.samples);
            next = bin.to_ns;
        }
        try std.testing.expectEqual(100 + width, next);
    };
    var empty = try Histogram.init(a, .{ .from_ns = 7, .to_ns = 7 }, 32);
    defer empty.deinit();
    empty.add(7);
    try std.testing.expectEqual(0, empty.bins.len);
    var huge = try Histogram.init(a, .{ .from_ns = 0, .to_ns = std.math.maxInt(u64) }, max_bins);
    defer huge.deinit();
    for (huge.bins) |bin| {
        huge.add(bin.from_ns);
        huge.add(bin.to_ns - 1);
    }
    for (huge.bins) |bin| try std.testing.expectEqual(2, bin.samples);
    try std.testing.expectError(error.InvalidTimelineBins, Histogram.init(a, .{ .from_ns = 0, .to_ns = 1 }, max_bins + 1));
}

test "selection survives growth, clamps shrinkage, and resets across capture identities" {
    var selected = Selection{};
    selected.bind(3, 100);
    try selected.set(.{ .tid = 12, .from_ns = 10, .to_ns = 50 });
    selected.bind(3, 200);
    try std.testing.expectEqual(50, selected.filter.to_ns);
    selected.bind(3, 30);
    try std.testing.expectEqual(30, selected.filter.to_ns);
    selected.bind(3, 5);
    try std.testing.expectEqual(std.math.maxInt(u64), selected.filter.to_ns);
    try std.testing.expectEqual(12, selected.filter.tid.?);
    selected.bind(4, 0);
    try std.testing.expectEqual(null, selected.filter.tid);
    try std.testing.expectError(error.InvalidProfileFilter, selected.set(.{ .from_ns = 5, .to_ns = 5 }));
    try std.testing.expectError(error.InvalidProfileFilter, selected.set(.{ .tid = 0 }));
}

test "scheduling pairs preserve unknown endpoints and clip without losing transition evidence" {
    const a = std.testing.allocator;
    const events = [_]Transition{
        .{ .offset_ns = 10, .direction = .switch_in },
        .{ .offset_ns = 30, .direction = .switch_out, .preempted = true },
        .{ .offset_ns = 70, .direction = .switch_in },
        .{ .offset_ns = 90, .direction = .switch_out },
    };
    const spans = try reconstruct(a, &events, 100, .{ .from_ns = 0, .to_ns = 100 }, .available);
    defer a.free(spans);
    try std.testing.expectEqual(5, spans.len);
    try std.testing.expectEqual(State.unknown, spans[0].state);
    try std.testing.expectEqual(State.running, spans[1].state);
    try std.testing.expectEqual(State.off_cpu, spans[2].state);
    try std.testing.expectEqual(true, spans[2].switch_out_preempted.?);
    try std.testing.expectEqual(State.unknown, spans[4].state);
    var cursor: u64 = 0;
    for (spans) |span| {
        try std.testing.expectEqual(cursor, span.from_ns);
        cursor = span.to_ns;
    }
    try std.testing.expectEqual(100, cursor);
    const clipped = try reconstruct(a, &events, 100, .{ .from_ns = 35, .to_ns = 60 }, .available);
    defer a.free(clipped);
    try std.testing.expectEqual(1, clipped.len);
    try std.testing.expect(clipped[0].clipped_start and clipped[0].clipped_end);
    try std.testing.expectEqual(true, clipped[0].switch_out_preempted.?);
}

test "loss, disabled collection, invalid identity and contradictory transitions stay unknown" {
    const a = std.testing.allocator;
    const cases = [_][2]Transition{
        .{ .{ .offset_ns = 40, .direction = .switch_in }, .{ .offset_ns = 20, .direction = .switch_out } },
        .{ .{ .offset_ns = 20, .direction = .switch_in }, .{ .offset_ns = 20, .direction = .switch_out } },
        .{ .{ .offset_ns = 20, .direction = .switch_in }, .{ .offset_ns = 40, .direction = .switch_in } },
        .{ .{ .offset_ns = 20, .direction = .switch_in, .preempted = true }, .{ .offset_ns = 40, .direction = .switch_out } },
    };
    for (cases) |events| {
        const spans = try reconstruct(a, &events, 100, .{ .from_ns = 0, .to_ns = 100 }, .available);
        defer a.free(spans);
        try std.testing.expectEqual(1, spans.len);
        try std.testing.expectEqual(Unknown.contradictory, spans[0].unknown_reason.?);
    }
    for ([_]Coverage{ .disabled, .lost, .invalid_identity, .available }) |coverage| {
        const spans = try reconstruct(a, &.{}, 100, .{ .from_ns = 0, .to_ns = 100 }, coverage);
        defer a.free(spans);
        try std.testing.expectEqual(1, spans.len);
        try std.testing.expectEqual(State.unknown, spans[0].state);
    }
    const empty = try reconstruct(a, &.{}, 100, .{ .from_ns = 120, .to_ns = 130 }, .available);
    defer a.free(empty);
    try std.testing.expectEqual(0, empty.len);
}

test "maximum scheduling reconstruction is bounded and partitions the extent" {
    const a = std.testing.allocator;
    const events = try a.alloc(Transition, max_transitions + 1);
    defer a.free(events);
    for (events, 0..) |*event, i| event.* = .{ .offset_ns = i + 1, .direction = if (i % 2 == 0) .switch_in else .switch_out };
    const spans = try reconstruct(a, events[0..max_transitions], max_transitions + 1, .{ .from_ns = 0, .to_ns = max_transitions + 1 }, .available);
    defer a.free(spans);
    try std.testing.expectEqual(max_transitions + 1, spans.len);
    var next: u64 = 0;
    for (spans) |span| {
        try std.testing.expectEqual(next, span.from_ns);
        next = span.to_ns;
    }
    try std.testing.expectEqual(max_transitions + 1, next);
    try std.testing.expectError(error.TimelineTransitionLimit, reconstruct(a, events, max_transitions + 2, .{ .from_ns = 0, .to_ns = 1 }, .available));
    const lost = try reconstruct(a, events[0..3], 5, .{ .from_ns = 0, .to_ns = 5 }, .lost);
    defer a.free(lost);
    try std.testing.expectEqual(1, lost.len);
    try std.testing.expectEqual(Unknown.lost, lost[0].unknown_reason.?);
}

test "thread filters own canonical sets and toggle back to all" {
    var filter = Filter{ .from_ns = 10, .to_ns = 30 };
    var ids = [_]u32{ 9, 3 };
    try filter.setThreads(&ids);
    ids[0] = 77;
    try filter.validate();
    try std.testing.expectEqualSlices(u32, &.{ 3, 9 }, filter.tids.slice());
    try std.testing.expect(filter.contains(3, 10) and filter.contains(9, 29));
    try std.testing.expect(!filter.contains(77, 15) and !filter.contains(3, 30));
    const before = filter;
    try std.testing.expectError(error.InvalidProfileFilter, filter.setThreads(&.{ 3, 3 }));
    try std.testing.expectEqualDeep(before, filter);
    try std.testing.expectError(error.InvalidProfileFilter, filter.setThreads(&.{0}));
    try filter.toggleThread(3);
    try std.testing.expectEqual(@as(?u32, 9), filter.tid);
    try std.testing.expectEqual(@as(u16, 0), filter.tids.len);
    try filter.toggleThread(9);
    try std.testing.expect(filter.matchesThread(77));
    try std.testing.expectEqual(@as(u64, 10), filter.from_ns);
    try filter.toggleThread(7);
    try std.testing.expectEqual(@as(?u32, 7), filter.tid);
    var many: [ThreadSet.capacity]u32 = undefined;
    for (&many, 0..) |*tid, i| tid.* = @intCast(i + 1);
    try filter.setThreads(&many);
    try std.testing.expectError(error.InvalidProfileFilter, filter.toggleThread(5000));
    try std.testing.expectEqual(@as(usize, ThreadSet.capacity), filter.threadCount());
}
