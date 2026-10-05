//! Bounded temporal associations to selected complete invocation intervals.
//! Uniqueness is within that explicit universe: incomplete calls are excluded.
//! Counts represent records, never inferred CPU cost, allocation bytes or cause.
const std = @import("std");
const calls = @import("calls.zig");
const comparison = @import("comparison.zig");
const Allocator = std.mem.Allocator;
pub const basis = "temporal association to selected complete invocation intervals; incomplete calls excluded; no causal attribution";
pub const max_streams = 16;
pub const max_citations = 4;
pub const Origin = struct {
    origin_id: u64,
    session_id: u64,
    process_id: u64,
    image_epoch: u64,
    producer_id: u64,
    clock_id: u64,
};
pub const Point = struct { ordinal: u64, time_ns: ?u64, tid: u32, thread_id: ?u64 = null };
pub const Interval = struct { ordinal: u64, start_ns: ?u64, end_ns: ?u64, tid: u32, thread_id: ?u64 = null };
pub const Kind = enum { cpu, syscall, allocation };
pub const RecordKind = enum { point, interval };
pub const Correlation = struct {
    proof_id: u64,
    source_producer_id: u64,
    target_producer_id: u64,
    source_clock_id: u64,
    target_clock_id: u64,
    /// Add to source times to reach the calls' clock domain.
    offset_ns: i64,
    uncertainty_ns: u64,
    /// Inclusive source-domain validity window of the supplied proof.
    valid_start_ns: u64,
    valid_end_ns: u64,
};
pub const ClockProof = union(enum) { unverified, same_domain, correlated: Correlation };
pub const Stream = struct {
    id: u64,
    origin: Origin,
    kind: Kind,
    clock: ClockProof = .unverified,
    /// At most one list is nonempty. Ordinals must be strictly increasing;
    /// timestamps may arrive in arbitrary cross-thread order.
    points: []const Point = &.{},
    intervals: []const Interval = &.{},
};
pub const Class = enum { exactly_one_call, overlap_multiple, outside_calls, unusable_time_or_identity, crosses_boundary };
pub const Reason = enum { origin_unknown, process_identity, image_identity, clock_unproved, clock_proof_mismatch, clock_window, clock_overflow, missing_time, time_reversed, thread_identity, thread_ambiguous, boundary };
pub const Cohort = enum { fast, slow };
pub const Counts = struct {
    records: u64 = 0,
    exactly_one_call: u64 = 0,
    overlap_multiple: u64 = 0,
    outside_calls: u64 = 0,
    unusable_time_or_identity: u64 = 0,
    crosses_boundary: u64 = 0,
    tid_only_records: u64 = 0,
    fast: u64 = 0,
    slow: u64 = 0,
    fn add(self: *Counts, row: RecordRow) void {
        self.records += 1;
        switch (row.classification) {
            inline else => |class| @field(self, @tagName(class)) += 1,
        }
        if (row.tid_only) self.tid_only_records += 1;
        if (row.cohort) |cohort| switch (cohort) {
            .fast => self.fast += 1,
            .slow => self.slow += 1,
        };
    }
};
pub const Citation = struct {
    stream_id: u64 = 0,
    origin_id: u64 = 0,
    ordinal: u64 = 0,
    kind: Kind = .cpu,
    record_kind: RecordKind = .point,
};
pub const RecordRow = struct {
    citation: Citation,
    classification: Class = .unusable_time_or_identity,
    reason: ?Reason = null,
    candidate_calls: u64 = 0,
    candidate_ids: [4]?u32 = @splat(null),
    call_id: ?u32 = null,
    cohort: ?Cohort = null,
    tid_only: bool = false,
    clock_uncertainty_ns: u64 = 0,
};
pub const StreamSummary = struct { id: u64, origin: Origin, kind: Kind, clock: ClockProof, counts: Counts = .{} };
pub const CallRow = struct {
    call_id: u32,
    cohort: Cohort,
    count: u64,
    points: u64,
    intervals: u64,
    citations: []Citation,
    omitted_citations: u64,
};
pub const Config = struct {
    selection: comparison.Selection,
    call_limit: usize = 131072,
    record_limit: usize = 1048576,
    row_limit: usize = 128,
    top_calls: usize = 16,
    citations_per_call: usize = 4,
    memory_limit: usize = 64 * 1024 * 1024,
    work_limit: u64 = 8 * 1024 * 1024,
};
pub const Result = struct {
    origin: Origin,
    selection: comparison.Selection,
    counts: Counts = .{},
    streams: []StreamSummary = &.{},
    rows: []RecordRow = &.{},
    omitted_rows: u64 = 0,
    calls: []CallRow = &.{},
    omitted_calls: u64 = 0,
    selected_complete_calls: u64 = 0,
    excluded_incomplete_calls: u64 = 0,
    coverage_incomplete: bool = false,
    work_steps: u64 = 0,
    pub fn deinit(self: *Result, a: Allocator) void {
        for (self.calls) |call| a.free(call.citations);
        a.free(self.calls);
        a.free(self.rows);
        a.free(self.streams);
    }
};
const Range = struct {
    call_id: u32,
    thread_id: u64,
    tid: u32,
    start: u64,
    end: u64,
    /// Maximum end in the implicit balanced tree rooted at this sorted index.
    subtree_end: u64 = 0,
    cohort: Cohort,
};
const Thread = struct { id: u64, tid: u32, lo: usize = 0, hi: usize = 0 };
const Tally = struct {
    count: u64 = 0,
    points: u64 = 0,
    intervals: u64 = 0,
    citations: [max_citations]Citation = @splat(.{}),
    citation_count: usize = 0,
};
const Work = struct {
    steps: u64 = 0,
    limit: u64,
    cancel: ?*const std.atomic.Value(bool),
    fn step(self: *Work) !void {
        if (self.cancel) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
        if (self.steps == self.limit) return error.ObservationAssociationWorkLimit;
        self.steps += 1;
    }
};
fn less(_: void, a: Range, b: Range) bool {
    if (a.thread_id != b.thread_id) return a.thread_id < b.thread_id;
    if (a.start != b.start) return a.start < b.start;
    return a.call_id < b.call_id;
}
fn indexTree(ranges: []Range, lo: usize, hi: usize) u64 {
    if (lo == hi) return 0;
    const mid = lo + (hi - lo) / 2;
    ranges[mid].subtree_end = @max(ranges[mid].end, @max(indexTree(ranges, lo, mid), indexTree(ranges, mid + 1, hi)));
    return ranges[mid].subtree_end;
}
fn originReason(target: Origin, stream: Stream) ?Reason {
    const source = stream.origin;
    if (target.origin_id == 0 or source.origin_id == 0 or target.session_id == 0 or source.session_id == 0 or target.process_id == 0 or source.process_id == 0 or target.image_epoch == 0 or source.image_epoch == 0 or target.producer_id == 0 or source.producer_id == 0 or target.clock_id == 0 or source.clock_id == 0) return .origin_unknown;
    if (target.session_id != source.session_id or target.process_id != source.process_id) return .process_identity;
    if (target.image_epoch != source.image_epoch) return .image_identity;
    switch (stream.clock) {
        .unverified => return .clock_unproved,
        .same_domain => if (target.producer_id != source.producer_id or target.clock_id != source.clock_id) {
            return .clock_proof_mismatch;
        },
        .correlated => |proof| {
            if (proof.proof_id == 0 or proof.source_producer_id != source.producer_id or proof.target_producer_id != target.producer_id or proof.source_clock_id != source.clock_id or proof.target_clock_id != target.clock_id or proof.valid_start_ns > proof.valid_end_ns) return .clock_proof_mismatch;
        },
    }
    return null;
}
const Window = struct { low: u64, high: u64, point: bool, uncertainty: u64 };
const WindowResult = union(enum) { window: Window, reason: Reason };
fn window(stream: Stream, start: ?u64, end: ?u64, point: bool) WindowResult {
    const first = start orelse return .{ .reason = .missing_time };
    const last = end orelse return .{ .reason = .missing_time };
    if (last < first) return .{ .reason = .time_reversed };
    var low: i128 = first;
    var high: i128 = last;
    var uncertainty: u64 = 0;
    if (stream.clock == .correlated) {
        const proof = stream.clock.correlated;
        if (first < proof.valid_start_ns or last > proof.valid_end_ns) return .{ .reason = .clock_window };
        low += proof.offset_ns;
        high += proof.offset_ns;
        uncertainty = proof.uncertainty_ns;
        low -= uncertainty;
        high += uncertainty;
    }
    if (low < 0 or high > std.math.maxInt(u64)) return .{ .reason = .clock_overflow };
    // A zero-duration interval is an instant, not a measured positive span.
    return .{ .window = .{ .low = @intCast(low), .high = @intCast(high), .point = point or first == last, .uncertainty = uncertainty } };
}
const Hits = struct { count: u64 = 0, first: ?usize = null, ids: [4]?u32 = @splat(null) };
fn visit(ranges: []const Range, lo: usize, hi: usize, query: Window, hits: *Hits, work: *Work) !void {
    if (lo == hi) return;
    try work.step();
    const mid = lo + (hi - lo) / 2;
    const node = ranges[mid];
    if (node.subtree_end <= query.low or (if (query.point) ranges[lo].start > query.high else ranges[lo].start >= query.high)) return;
    try visit(ranges, lo, mid, query, hits, work);
    if (node.end > query.low and (if (query.point) node.start <= query.high else node.start < query.high)) {
        if (hits.count < hits.ids.len) hits.ids[@intCast(hits.count)] = node.call_id;
        hits.count += 1;
        if (hits.first == null) hits.first = mid;
    }
    try visit(ranges, mid + 1, hi, query, hits, work);
}
const ThreadResult = union(enum) { thread: ?Thread, reason: Reason };
fn threadFor(threads: []const Thread, tid: u32, id: ?u64) ThreadResult {
    if (tid == 0 or (id != null and id.? == 0)) return .{ .reason = .thread_identity };
    if (id) |stable| {
        for (threads) |thread| if (thread.id == stable) return if (thread.tid == tid) .{ .thread = thread } else .{ .reason = .thread_identity };
        // A claimed identity must never fall back to an unrelated reused TID.
        for (threads) |thread| if (thread.tid == tid) return .{ .reason = .thread_identity };
        return .{ .thread = null };
    }
    var found: ?Thread = null;
    for (threads) |thread| if (thread.tid == tid) {
        if (found != null) return .{ .reason = .thread_ambiguous };
        found = thread;
    };
    return .{ .thread = found };
}
fn associate(target: Origin, stream: Stream, ordinal: u64, start: ?u64, end: ?u64, record_kind: RecordKind, tid: u32, thread_id: ?u64, ranges: []const Range, threads: []const Thread, tallies: []Tally, config: Config, work: *Work) !RecordRow {
    try work.step();
    var row: RecordRow = .{ .citation = .{ .stream_id = stream.id, .origin_id = stream.origin.origin_id, .ordinal = ordinal, .kind = stream.kind, .record_kind = record_kind } };
    if (originReason(target, stream)) |reason| {
        row.reason = reason;
        return row;
    }
    const query = switch (window(stream, start, end, record_kind == .point)) {
        .reason => |reason| {
            row.reason = reason;
            return row;
        },
        .window => |value| value,
    };
    row.clock_uncertainty_ns = query.uncertainty;
    const thread = switch (threadFor(threads, tid, thread_id)) {
        .reason => |reason| {
            row.reason = reason;
            return row;
        },
        .thread => |value| value,
    };
    row.tid_only = thread_id == null;
    var hits: Hits = .{};
    if (thread) |lane| try visit(ranges, lane.lo, lane.hi, query, &hits, work);
    row.candidate_calls = hits.count;
    row.candidate_ids = hits.ids;
    if (hits.count == 0) {
        row.classification = .outside_calls;
        return row;
    }
    if (hits.count > 1) {
        row.classification = .overlap_multiple;
        return row;
    }
    const index = hits.first.?;
    const range = ranges[index];
    row.call_id = range.call_id;
    if (query.low < range.start or (if (query.point) query.high >= range.end else query.high > range.end)) {
        row.classification = .crosses_boundary;
        row.reason = .boundary;
        return row;
    }
    row.classification = .exactly_one_call;
    row.cohort = range.cohort;
    const tally = &tallies[index];
    tally.count += 1;
    if (record_kind == .point) tally.points += 1 else tally.intervals += 1;
    if (tally.citation_count < config.citations_per_call) {
        tally.citations[tally.citation_count] = row.citation;
        tally.citation_count += 1;
    }
    return row;
}
pub fn build(a: Allocator, store: *const calls.Store, origin: Origin, streams: []const Stream, config: Config, cancel: ?*const std.atomic.Value(bool)) !Result {
    if (!store.finished) return error.ObservationStillCollecting;
    if (streams.len > max_streams or config.call_limit > calls.max_records or config.record_limit > 4 * 1024 * 1024 or config.row_limit > 4096 or config.top_calls > 64 or config.citations_per_call > max_citations or config.memory_limit == 0 or config.memory_limit > 512 * 1024 * 1024 or config.work_limit == 0) return error.InvalidObservationAssociationConfig;
    config.selection.validate() catch return error.InvalidObservationAssociationConfig;
    var work: Work = .{ .limit = config.work_limit, .cancel = cancel };
    var records: usize = 0;
    for (streams, 0..) |stream, si| {
        try work.step();
        if (stream.id == 0 or (stream.points.len != 0 and stream.intervals.len != 0)) return error.InvalidObservationAssociationStream;
        // Repeating a source under another stream ID would double-count its
        // record ordinals. CPU and syscall namespaces in one capture differ.
        for (streams[0..si]) |old| if (old.id == stream.id or (old.origin.origin_id == stream.origin.origin_id and old.kind == stream.kind)) return error.InvalidObservationAssociationStream;
        if (stream.points.len > config.record_limit - records) return error.ObservationAssociationRecordLimit;
        records += stream.points.len;
        if (stream.intervals.len > config.record_limit - records) return error.ObservationAssociationRecordLimit;
        records += stream.intervals.len;
        var previous: ?u64 = null;
        for (stream.points) |point| {
            try work.step();
            if (previous != null and previous.? >= point.ordinal) return error.InvalidObservationAssociationStream;
            previous = point.ordinal;
        }
        previous = null;
        for (stream.intervals) |interval| {
            try work.step();
            if (previous != null and previous.? >= interval.ordinal) return error.InvalidObservationAssociationStream;
            previous = interval.ordinal;
        }
    }
    var result: Result = .{ .origin = origin, .selection = config.selection, .coverage_incomplete = store.first_gap != null or store.unread_possible };
    errdefer result.deinit(a);
    var count: usize = 0;
    for (store.calls.items) |call| {
        try work.step();
        if (store.duration(call) == null) {
            result.excluded_incomplete_calls += 1;
            continue;
        }
        if (comparison.matches(store, call, config.selection) == .yes) count += 1;
    }
    if (count > config.call_limit) return error.ObservationAssociationCallLimit;
    result.selected_complete_calls = count;
    const row_count = @min(config.row_limit, records);
    const top_count = @min(config.top_calls, count);
    const bytes = count * (@sizeOf(Range) + @sizeOf(Tally)) + row_count * @sizeOf(RecordRow) + streams.len * @sizeOf(StreamSummary) + top_count * (@sizeOf(CallRow) + config.citations_per_call * @sizeOf(Citation));
    if (bytes > config.memory_limit) return error.ObservationAssociationMemoryLimit;
    const ranges = try a.alloc(Range, count);
    defer a.free(ranges);
    const tallies = try a.alloc(Tally, count);
    defer a.free(tallies);
    @memset(tallies, .{});
    var at: usize = 0;
    for (store.calls.items) |call| {
        try work.step();
        const ns = store.duration(call) orelse continue;
        if (comparison.matches(store, call, config.selection) != .yes) continue;
        ranges[at] = .{ .call_id = call.id, .thread_id = call.thread_id, .tid = call.tid, .start = store.records.items[call.entry_record.?].event.time_ns, .end = store.records.items[call.return_record.?].event.time_ns, .cohort = if (ns < config.selection.threshold_ns) .fast else .slow };
        at += 1;
    }
    std.mem.sort(Range, ranges, {}, less);
    var thread_buffer: [calls.max_threads]Thread = undefined;
    // Store lanes preserve exited/reused identities, including incomplete calls.
    const thread_count = store.lanes.items.len;
    for (store.lanes.items, 0..) |lane, i| thread_buffer[i] = .{ .id = lane.thread_id, .tid = lane.tid };
    var begin: usize = 0;
    while (begin < ranges.len) {
        var end = begin + 1;
        while (end < ranges.len and ranges[end].thread_id == ranges[begin].thread_id) : (end += 1) {}
        _ = indexTree(ranges, begin, end);
        for (thread_buffer[0..thread_count]) |*thread| if (thread.id == ranges[begin].thread_id) {
            thread.lo = begin;
            thread.hi = end;
            break;
        };
        begin = end;
    }
    result.streams = try a.alloc(StreamSummary, streams.len);
    result.rows = try a.alloc(RecordRow, row_count);
    var saved: usize = 0;
    for (streams, result.streams) |stream, *summary| {
        summary.* = .{ .id = stream.id, .origin = stream.origin, .kind = stream.kind, .clock = stream.clock };
        for (stream.points) |point| {
            const row = try associate(origin, stream, point.ordinal, point.time_ns, point.time_ns, .point, point.tid, point.thread_id, ranges, thread_buffer[0..thread_count], tallies, config, &work);
            summary.counts.add(row);
            result.counts.add(row);
            if (saved < row_count) {
                result.rows[saved] = row;
                saved += 1;
            } else result.omitted_rows += 1;
        }
        for (stream.intervals) |interval| {
            const row = try associate(origin, stream, interval.ordinal, interval.start_ns, interval.end_ns, .interval, interval.tid, interval.thread_id, ranges, thread_buffer[0..thread_count], tallies, config, &work);
            summary.counts.add(row);
            result.counts.add(row);
            if (saved < row_count) {
                result.rows[saved] = row;
                saved += 1;
            } else result.omitted_rows += 1;
        }
    }
    var top: [64]usize = undefined;
    var ntop: usize = 0;
    var attributed: usize = 0;
    for (tallies, 0..) |tally, i| {
        try work.step();
        if (tally.count == 0) continue;
        attributed += 1;
        var place: usize = 0;
        while (place < ntop and (tallies[top[place]].count > tally.count or (tallies[top[place]].count == tally.count and ranges[top[place]].call_id < ranges[i].call_id))) : (place += 1) {}
        if (place < top_count) {
            const next = @min(ntop + 1, top_count);
            var shift = next;
            while (shift > place + 1) {
                shift -= 1;
                top[shift] = top[shift - 1];
            }
            top[place] = i;
            ntop = next;
        }
    }
    result.calls = try a.alloc(CallRow, ntop);
    for (result.calls) |*row| row.* = .{ .call_id = 0, .cohort = .fast, .count = 0, .points = 0, .intervals = 0, .citations = &.{}, .omitted_citations = 0 };
    for (result.calls, top[0..ntop]) |*row, i| {
        const tally = tallies[i];
        row.* = .{ .call_id = ranges[i].call_id, .cohort = ranges[i].cohort, .count = tally.count, .points = tally.points, .intervals = tally.intervals, .citations = try a.dupe(Citation, tally.citations[0..tally.citation_count]), .omitted_citations = tally.count - tally.citation_count };
    }
    result.omitted_calls = attributed - ntop;
    result.work_steps = work.steps;
    return result;
}

const fixtureOrigin: Origin = .{ .origin_id = 1, .session_id = 1, .process_id = 1, .image_epoch = 1, .producer_id = 1, .clock_id = 1 };
fn fixturePair(store: *calls.Store, a: Allocator, thread: u64, tid: u32, start: u64, end: u64, key: u64) !void {
    var entry = calls.fixtureEvent(start, thread, .enter, 1, key);
    entry.tid = tid;
    try store.feed(a, entry);
    var ret = calls.fixtureEvent(end, thread, .leave, 1, key);
    ret.tid = tid;
    try store.feed(a, ret);
}
fn expectConserved(counts: Counts) !void {
    try std.testing.expectEqual(counts.records, counts.exactly_one_call + counts.overlap_multiple + counts.outside_calls + counts.unusable_time_or_identity + counts.crosses_boundary);
    try std.testing.expectEqual(counts.exactly_one_call, counts.fast + counts.slow);
}
test "half-open points and crossing intervals have exact disjoint denominators" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, calls.fixtureEvent(10, 1, .enter, 1, 100));
    try store.feed(a, calls.fixtureEvent(20, 1, .enter, 1, 80));
    try store.feed(a, calls.fixtureEvent(30, 1, .leave, 1, 80));
    try store.feed(a, calls.fixtureEvent(40, 1, .leave, 1, 100));
    try fixturePair(&store, a, 2, 102, 10, 50, 100);
    store.finish(.capture_end);
    const points = [_]Point{
        .{ .ordinal = 0, .time_ns = 5, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 1, .time_ns = 10, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 2, .time_ns = 20, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 3, .time_ns = 30, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 4, .time_ns = 40, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 5, .time_ns = 20, .tid = 102, .thread_id = 2 },
    };
    const intervals = [_]Interval{
        .{ .ordinal = 0, .start_ns = 11, .end_ns = 19, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 1, .start_ns = 19, .end_ns = 21, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 2, .start_ns = 5, .end_ns = 15, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 3, .start_ns = 40, .end_ns = 41, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 4, .start_ns = 30, .end_ns = 40, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 5, .start_ns = 40, .end_ns = 40, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 6, .start_ns = null, .end_ns = 40, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 7, .start_ns = 40, .end_ns = 39, .tid = 101, .thread_id = 1 },
    };
    const streams = [_]Stream{
        .{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .same_domain, .points = &points },
        .{ .id = 2, .origin = fixtureOrigin, .kind = .syscall, .clock = .same_domain, .intervals = &intervals },
    };
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 35 }, .citations_per_call = 2 }, null);
    defer result.deinit(a);
    try expectConserved(result.counts);
    try std.testing.expectEqual(@as(u64, 14), result.counts.records);
    try std.testing.expectEqual(@as(u64, 5), result.counts.exactly_one_call);
    try std.testing.expectEqual(@as(u64, 2), result.counts.overlap_multiple);
    try std.testing.expectEqual(@as(u64, 4), result.counts.outside_calls);
    try std.testing.expectEqual(@as(u64, 1), result.counts.crosses_boundary);
    try std.testing.expectEqual(@as(u64, 2), result.counts.unusable_time_or_identity);
    try std.testing.expectEqual(@as(u64, 4), result.counts.fast);
    try std.testing.expectEqual(@as(u64, 1), result.counts.slow);
    try std.testing.expectEqual(@as(u32, 0), result.calls[0].call_id);
    try std.testing.expectEqual(@as(u64, 4), result.calls[0].count);
    try std.testing.expectEqual(@as(u64, 2), result.calls[0].omitted_citations);
    try std.testing.expectEqual(@as(usize, 2), result.calls[0].citations.len);
    try std.testing.expectEqual(@as(u64, 2), result.rows[2].candidate_calls);
    try std.testing.expectEqual(@as(?Cohort, null), result.rows[2].cohort);
    for (result.streams) |stream| try expectConserved(stream.counts);
}
test "clock proofs retain uncertainty at boundaries and reject unknown domains" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixturePair(&store, a, 1, 101, 100, 200, 100);
    store.finish(.capture_end);
    var source = fixtureOrigin;
    source.origin_id = 2;
    source.producer_id = 2;
    source.clock_id = 2;
    const points = [_]Point{
        .{ .ordinal = 0, .time_ns = 50, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 1, .time_ns = 0, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 2, .time_ns = 90, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 3, .time_ns = 101, .tid = 101, .thread_id = 1 },
    };
    const proof: ClockProof = .{ .correlated = .{ .proof_id = 9, .source_producer_id = 2, .target_producer_id = 1, .source_clock_id = 2, .target_clock_id = 1, .offset_ns = 100, .uncertainty_ns = 10, .valid_start_ns = 0, .valid_end_ns = 100 } };
    var second_source = source;
    second_source.origin_id = 3;
    var third_source = source;
    third_source.origin_id = 4;
    const streams = [_]Stream{
        .{ .id = 1, .origin = source, .kind = .cpu, .clock = proof, .points = &points },
        .{ .id = 2, .origin = second_source, .kind = .cpu, .points = points[0..1] },
        .{ .id = 3, .origin = third_source, .kind = .cpu, .clock = .same_domain, .points = points[0..1] },
    };
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 100 } }, null);
    defer result.deinit(a);
    try expectConserved(result.counts);
    try std.testing.expectEqual(@as(u64, 1), result.counts.exactly_one_call);
    try std.testing.expectEqual(@as(u64, 2), result.counts.crosses_boundary);
    try std.testing.expectEqual(@as(u64, 3), result.counts.unusable_time_or_identity);
    try std.testing.expectEqual(@as(u64, 10), result.rows[0].clock_uncertainty_ns);
    try std.testing.expectEqual(@as(?Reason, .clock_window), result.rows[3].reason);
    try std.testing.expectEqual(@as(?Reason, .clock_unproved), result.rows[4].reason);
    try std.testing.expectEqual(@as(?Reason, .clock_proof_mismatch), result.rows[5].reason);
    try std.testing.expectEqual(@as(u64, 9), result.streams[0].clock.correlated.proof_id);
}
test "stable thread identity prevents attribution across TID reuse and processes" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixturePair(&store, a, 1, 101, 10, 20, 100);
    try store.feed(a, .{ .thread_id = 1, .tid = 101, .time_ns = 21, .data = .thread_exit });
    try fixturePair(&store, a, 2, 101, 30, 40, 100);
    store.finish(.capture_end);
    const points = [_]Point{
        .{ .ordinal = 0, .time_ns = 15, .tid = 101 },
        .{ .ordinal = 1, .time_ns = 15, .tid = 101, .thread_id = 1 },
        .{ .ordinal = 2, .time_ns = 15, .tid = 101, .thread_id = 2 },
        .{ .ordinal = 3, .time_ns = 15, .tid = 101, .thread_id = 3 },
    };
    var different = fixtureOrigin;
    different.process_id = 99;
    different.origin_id = 99;
    const streams = [_]Stream{
        .{ .id = 1, .origin = fixtureOrigin, .kind = .allocation, .clock = .same_domain, .points = &points },
        .{ .id = 2, .origin = different, .kind = .allocation, .clock = .same_domain, .points = points[1..2] },
    };
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 } }, null);
    defer result.deinit(a);
    try expectConserved(result.counts);
    try std.testing.expectEqual(@as(u64, 1), result.counts.exactly_one_call);
    try std.testing.expectEqual(@as(u64, 1), result.counts.outside_calls);
    try std.testing.expectEqual(@as(u64, 3), result.counts.unusable_time_or_identity);
    try std.testing.expectEqual(@as(?Reason, .thread_ambiguous), result.rows[0].reason);
    try std.testing.expectEqual(@as(?Reason, .thread_identity), result.rows[3].reason);
    try std.testing.expectEqual(@as(?Reason, .process_identity), result.rows[4].reason);
}
test "empty incomplete and truncated result selections conserve all input records" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, calls.fixtureEvent(1, 1, .enter, 1, 100));
    store.finish(.cancelled);
    const points = [_]Point{ .{ .ordinal = 0, .time_ns = 2, .tid = 101 }, .{ .ordinal = 1, .time_ns = null, .tid = 101 } };
    const streams = [_]Stream{.{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .same_domain, .points = &points }};
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 }, .row_limit = 0, .top_calls = 0 }, null);
    defer result.deinit(a);
    try expectConserved(result.counts);
    try std.testing.expectEqual(@as(u64, 1), result.excluded_incomplete_calls);
    try std.testing.expect(result.coverage_incomplete);
    try std.testing.expectEqual(@as(u64, 2), result.omitted_rows);
    try std.testing.expectEqual(@as(u64, 1), result.counts.outside_calls);
    try std.testing.expectEqual(@as(u64, 1), result.counts.unusable_time_or_identity);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    var empty = try build(a, &store, fixtureOrigin, &.{}, .{ .selection = .{ .threshold_ns = 1 } }, null);
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(u64, 0), empty.counts.records);
}
fn failingBuild(a: Allocator, store: *const calls.Store, streams: []const Stream) !void {
    var result = try build(a, store, fixtureOrigin, streams, .{ .selection = .{ .threshold_ns = 2 } }, null);
    defer result.deinit(a);
}
test "association failures release all storage and limits never silently truncate totals" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try fixturePair(&store, a, 1, 101, 1, 10, 100);
    store.finish(.capture_end);
    const points = [_]Point{.{ .ordinal = 0, .time_ns = 2, .tid = 101 }};
    const streams = [_]Stream{.{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .same_domain, .points = &points }};
    try std.testing.checkAllAllocationFailures(a, failingBuild, .{ &store, &streams });
    try std.testing.expectError(error.ObservationAssociationRecordLimit, build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 }, .record_limit = 0 }, null));
    try std.testing.expectError(error.ObservationAssociationCallLimit, build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 }, .call_limit = 0 }, null));
    try std.testing.expectError(error.ObservationAssociationMemoryLimit, build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 }, .memory_limit = 1 }, null));
    try std.testing.expectError(error.ObservationAssociationWorkLimit, build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 }, .work_limit = 1 }, null));
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ObservationAnalysisCancelled, build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 1 } }, &cancel));
}

test "balanced index agrees with exhaustive interval matching across threads" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, calls.fixtureEvent(0, 1, .enter, 1, 1000));
    for (0..100) |i| try fixturePair(&store, a, 1, 101, 10 + i * 20, 20 + i * 20, 900);
    try store.feed(a, calls.fixtureEvent(2200, 1, .leave, 1, 1000));
    for (0..100) |i| try fixturePair(&store, a, 2, 102, i * 22, i * 22 + 7, 1000);
    store.finish(.capture_end);
    var intervals: [400]Interval = undefined;
    for (&intervals, 0..) |*interval, i| interval.* = .{ .ordinal = i, .start_ns = (i * 47) % 2400, .end_ns = (i * 47) % 2400 + (i * 13) % 41, .tid = @intCast(101 + i % 2), .thread_id = 1 + i % 2 };
    const streams = [_]Stream{.{ .id = 1, .origin = fixtureOrigin, .kind = .syscall, .clock = .same_domain, .intervals = &intervals }};
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 20 }, .row_limit = intervals.len }, null);
    defer result.deinit(a);
    try expectConserved(result.counts);
    for (intervals, result.rows) |interval, row| {
        var hits: u64 = 0;
        var contained = false;
        const point = interval.start_ns.? == interval.end_ns.?;
        for (store.calls.items) |call| {
            if (call.thread_id != interval.thread_id.?) continue;
            const start = store.records.items[call.entry_record.?].event.time_ns;
            const end = store.records.items[call.return_record.?].event.time_ns;
            if (end > interval.start_ns.? and (if (point) start <= interval.end_ns.? else start < interval.end_ns.?)) {
                hits += 1;
                contained = start <= interval.start_ns.? and (if (point) end > interval.end_ns.? else end >= interval.end_ns.?);
            }
        }
        const class: Class = if (hits == 0) .outside_calls else if (hits > 1) .overlap_multiple else if (contained) .exactly_one_call else .crosses_boundary;
        try std.testing.expectEqual(class, row.classification);
        try std.testing.expectEqual(hits, row.candidate_calls);
    }
}
test "a long parent does not force quadratic scans through retired child intervals" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, calls.fixtureEvent(0, 1, .enter, 1, 1000));
    for (0..1000) |i| try fixturePair(&store, a, 1, 101, 1 + i * 3, 2 + i * 3, 900);
    try store.feed(a, calls.fixtureEvent(10000, 1, .leave, 1, 1000));
    store.finish(.capture_end);
    var points: [1000]Point = undefined;
    for (&points, 0..) |*point, i| point.* = .{ .ordinal = i, .time_ns = 2 + i * 3, .tid = 101, .thread_id = 1 };
    const streams = [_]Stream{.{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .same_domain, .points = &points }};
    var result = try build(a, &store, fixtureOrigin, &streams, .{ .selection = .{ .threshold_ns = 10 }, .work_limit = 100000 }, null);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u64, 1000), result.counts.exactly_one_call);
    try std.testing.expect(result.work_steps < 100000);
    try std.testing.expectEqual(@as(u64, 1000), result.calls[0].count);
}
test "duplicate source citations and ordinals are rejected rather than double-counted" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    store.finish(.capture_end);
    const points = [_]Point{ .{ .ordinal = 0, .time_ns = 1, .tid = 101 }, .{ .ordinal = 0, .time_ns = 2, .tid = 101 } };
    var stream: Stream = .{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .same_domain, .points = &points };
    try std.testing.expectError(error.InvalidObservationAssociationStream, build(a, &store, fixtureOrigin, &.{stream}, .{ .selection = .{ .threshold_ns = 1 } }, null));
    stream.points = points[0..1];
    var other = stream;
    other.id = 2;
    try std.testing.expectError(error.InvalidObservationAssociationStream, build(a, &store, fixtureOrigin, &.{ stream, other }, .{ .selection = .{ .threshold_ns = 1 } }, null));
}
test "clock translation underflow and overflow retain unusable records" {
    const a = std.testing.allocator;
    var store = try calls.Store.init(.{});
    defer store.deinit(a);
    store.finish(.capture_end);
    const points = [_]Point{ .{ .ordinal = 0, .time_ns = 0, .tid = 101 }, .{ .ordinal = 1, .time_ns = std.math.maxInt(u64), .tid = 101 } };
    const stream: Stream = .{ .id = 1, .origin = fixtureOrigin, .kind = .cpu, .clock = .{ .correlated = .{ .proof_id = 1, .source_producer_id = 1, .target_producer_id = 1, .source_clock_id = 1, .target_clock_id = 1, .offset_ns = 0, .uncertainty_ns = 1, .valid_start_ns = 0, .valid_end_ns = std.math.maxInt(u64) } }, .points = &points };
    var result = try build(a, &store, fixtureOrigin, &.{stream}, .{ .selection = .{ .threshold_ns = 1 } }, null);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u64, 2), result.counts.unusable_time_or_identity);
    for (result.rows) |row| try std.testing.expectEqual(@as(?Reason, .clock_overflow), row.reason);
}
