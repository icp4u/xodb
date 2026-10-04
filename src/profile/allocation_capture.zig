//! Shared allocation evidence owner and bounded inspection pages. Transport
//! supplies normalized events only after validating its register convention.
//! No probe creation, process control, privilege changes or implicit retries.
const std = @import("std");
const events = @import("allocation_events.zig");
const lifetime = @import("allocation_lifetimes.zig");
const Budget = @import("archive_budget.zig").Budget;
const Allocator = std.mem.Allocator;
pub const default_memory_limit = 32 * 1024 * 1024;
pub const maximum_memory_limit = 128 * 1024 * 1024;
pub const page_limit = 256;
pub const scan_limit = 4096;
pub const algorithm = "xodb-allocation-lifetimes-v1";
pub const Identity = struct { session_id: u64, capture_id: u64, process_id: u64, pid: i32, image_epoch: u64 };
pub const Key = struct { identity: Identity, revision: u64 };
pub const Thread = struct { id: u64, tid: i32 };
pub const Hook = struct {
    id: u16,
    kind: lifetime.Kind,
    name: []const u8,
    path: []const u8,
    device: u64,
    inode: u64,
    file_offset: u64,
    link_address: u64,
    runtime_address: u64,
};
pub const Config = struct { record_limit: usize = events.default_records, memory_limit: usize = default_memory_limit };
pub const State = enum { collecting, stopping, finalized, analyzing, ready, unavailable };
pub const Filter = struct { thread_id: ?u64 = null, from_ns: u64 = 0, to_ns: u64 = std.math.maxInt(u64), outstanding_only: bool = false };
pub const RecordRow = struct { ordinal: u32, thread: Thread, event: events.Event };
pub const SpanRow = struct {
    ordinal: u32,
    thread: Thread,
    parent: ?u32,
    reason: events.Reason,
    entry: ?RecordRow,
    returned: ?RecordRow,
};
pub const LifetimeRow = struct {
    ordinal: u32,
    pointer: u64,
    requested_bytes: u64,
    state: lifetime.State,
    allocation_span: u32,
    release_span: ?u32,
    allocation_thread: Thread,
    min_ns: ?u64,
    max_ns: ?u64,
};
pub fn Page(comptime Row: type) type {
    return struct { key: Key, rows: []Row, next: ?usize, scanned: usize, total_unfiltered: usize };
}
const Analysis = struct {
    projection: events.Projection,
    view: lifetime.View,
    fn deinit(self: *Analysis, a: Allocator) void {
        self.view.deinit(a);
        self.projection.deinit(a);
    }
};
pub const Capture = struct {
    backing: Allocator,
    budget: Budget,
    identity: Identity,
    revision: u64 = 1,
    started_ns: u64,
    ended_ns: ?u64 = null,
    observed_until_ns: u64,
    config: Config,
    threads: [events.max_threads]Thread = undefined,
    thread_count: usize,
    hooks: [16]Hook = undefined,
    hook_count: usize = 0,
    store: events.Store,
    state: State = .collecting,
    failure: ?anyerror = null,
    analysis: ?Analysis = null,
    worker_result: ?Analysis = null,
    worker_failure: ?anyerror = null,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),

    pub fn create(a: Allocator, id: Identity, config: Config, threads: []const Thread, hooks: []const Hook, started_ns: u64) !*Capture {
        if (id.session_id == 0 or id.capture_id == 0 or id.process_id == 0 or id.pid <= 0 or config.memory_limit < @sizeOf(Capture) or config.memory_limit > maximum_memory_limit or hooks.len == 0 or hooks.len > 16) return error.InvalidAllocationCapture;
        const store = try events.Store.init(threads.len, config.record_limit);
        for (threads, 0..) |thread, i| {
            if (thread.id == 0 or thread.tid <= 0) return error.InvalidAllocationThread;
            for (threads[0..i]) |old| if (old.id == thread.id or old.tid == thread.tid) return error.InvalidAllocationThread;
        }
        for (hooks, 0..) |hook, i| {
            if (hook.name.len == 0 or hook.name.len > 256 or hook.path.len == 0 or hook.path.len > 4096 or hook.inode == 0 or hook.runtime_address == 0 or std.mem.indexOfScalar(u8, hook.name, 0) != null or std.mem.indexOfScalar(u8, hook.path, 0) != null) return error.InvalidAllocationHook;
            for (hooks[0..i]) |old| if (old.id == hook.id or (old.device == hook.device and old.inode == hook.inode and old.file_offset == hook.file_offset)) return error.InvalidAllocationHook;
        }
        const self = try a.create(Capture);
        self.* = .{ .backing = a, .budget = .{ .backing = a, .limit = config.memory_limit - @sizeOf(Capture) }, .identity = id, .started_ns = started_ns, .observed_until_ns = started_ns, .config = config, .thread_count = threads.len, .store = store };
        errdefer self.deinit();
        @memcpy(self.threads[0..threads.len], threads);
        for (hooks) |hook| {
            const name = try self.budget.allocator().dupe(u8, hook.name);
            const path = self.budget.allocator().dupe(u8, hook.path) catch |err| {
                self.budget.allocator().free(name);
                return err;
            };
            self.hooks[self.hook_count] = hook;
            self.hooks[self.hook_count].name = name;
            self.hooks[self.hook_count].path = path;
            self.hook_count += 1;
        }
        return self;
    }
    /// Shutdown may join; normal event-loop replacement must cancel, poll and
    /// wait for worker==null before destroying the old capture.
    pub fn deinit(self: *Capture) void {
        self.cancel.store(true, .release);
        if (self.worker) |thread| thread.join();
        const a = self.budget.allocator();
        if (self.worker_result) |*result| result.deinit(a);
        if (self.analysis) |*result| result.deinit(a);
        self.store.deinit(a);
        for (self.hooks[0..self.hook_count]) |hook| {
            a.free(hook.name);
            a.free(hook.path);
        }
        std.debug.assert(self.budget.used == 0);
        self.backing.destroy(self);
    }
    pub fn key(self: *const Capture) Key {
        return .{ .identity = self.identity, .revision = self.revision };
    }
    pub fn validate(self: *const Capture, expected: Key) !void {
        if (!std.meta.eql(self.key(), expected)) return error.StaleAllocationCapture;
    }
    fn badSource(self: *Capture, reason: events.Reason) void {
        self.store.rejected +|= 1;
        self.store.abort(reason);
        self.state = .stopping;
        self.revision += 1;
    }
    pub fn feed(self: *Capture, lane: usize, event: events.Event) !void {
        if (self.store.finished) return error.AllocationFinished;
        if (lane >= self.thread_count) {
            self.badSource(.identity);
            return error.InvalidAllocationThread;
        }
        if (event.time_ns < self.started_ns) {
            self.badSource(.time_reversed);
            return error.InvalidAllocationTimestamp;
        }
        if (event.data == .sample) {
            const sample = event.data.sample;
            const known = for (self.hooks[0..self.hook_count]) |hook| {
                if (hook.id == sample.hook and hook.kind == sample.kind) break true;
            } else false;
            if (!known) {
                self.badSource(.identity);
                return error.InvalidAllocationHook;
            }
        }
        self.observed_until_ns = @max(self.observed_until_ns, event.time_ns);
        defer {
            self.revision += 1;
            if (self.store.finished) {
                self.state = .stopping;
            }
        }
        try self.store.feed(self.budget.allocator(), lane, event);
    }
    /// Owner calls after disabling sources and draining (or declaring an
    /// unknown suffix). A full/aborted store alone is not a capture end time.
    pub fn finish(self: *Capture, ended_ns: u64, unread_possible: bool) !void {
        if (self.ended_ns != null) return;
        if (ended_ns < self.observed_until_ns) return error.InvalidAllocationTimestamp;
        self.store.finish(unread_possible);
        self.ended_ns = ended_ns;
        self.state = .finalized;
        self.revision += 1;
    }
    pub fn abort(self: *Capture, reason: events.Reason) void {
        if (self.store.finished) return;
        self.store.abort(reason);
        self.state = .stopping;
        self.revision += 1;
    }
    pub fn requestAnalysis(self: *Capture, retry: bool) !void {
        self.poll();
        if (!self.store.finished) return error.AllocationStillCollecting;
        if (self.ended_ns == null) return error.AllocationCaptureNotFinalized;
        if (self.state == .analyzing or self.state == .ready) return;
        if (self.store.first_gap != null) {
            self.state = .unavailable;
            self.failure = error.AllocationEvidenceGap;
            return error.AllocationEvidenceGap;
        }
        if (self.failure != null and !retry) return self.failure.?;
        self.cancel.store(false, .release);
        self.done.store(false, .release);
        self.worker_failure = null;
        self.failure = null;
        self.budget.denied = false;
        self.worker = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.state = .unavailable;
            self.failure = err;
            return err;
        };
        self.state = .analyzing;
    }
    fn execute(self: *Capture) !Analysis {
        const a = self.budget.allocator();
        const projection = try self.store.projectWithCancel(a, &self.cancel);
        errdefer projection.deinit(a);
        var view = try lifetime.buildWithCancel(a, projection.calls, true, &self.cancel);
        errdefer view.deinit(a);
        if (self.cancel.load(.acquire)) return error.AllocationAnalysisCancelled;
        return .{ .projection = projection, .view = view };
    }
    fn run(self: *Capture) void {
        self.worker_result = self.execute() catch |err| blk: {
            self.worker_failure = if (self.budget.denied) error.AllocationMemoryLimit else err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
    pub fn cancelAnalysis(self: *Capture) void {
        self.cancel.store(true, .release);
    }
    pub fn poll(self: *Capture) void {
        const thread = self.worker orelse return;
        if (!self.done.load(.acquire)) return;
        thread.join();
        self.worker = null;
        if (self.cancel.load(.acquire)) {
            if (self.worker_result) |*result| result.deinit(self.budget.allocator());
            self.worker_result = null;
            self.failure = error.AllocationAnalysisCancelled;
        } else {
            self.analysis = self.worker_result;
            self.worker_result = null;
            self.failure = self.worker_failure;
        }
        self.state = if (self.analysis != null) .ready else .unavailable;
    }
    /// Never read mutable allocator accounting while a worker is using it.
    pub fn memory(self: *const Capture) ?struct { used: usize, peak: usize, limit: usize } {
        if (self.worker != null) return null;
        return .{ .used = self.budget.used + @sizeOf(Capture), .peak = self.budget.peak + @sizeOf(Capture), .limit = self.config.memory_limit };
    }
    pub fn summary(self: *const Capture) ?lifetime.Summary {
        return if (self.analysis) |result| result.view.summary else null;
    }
    fn filterValid(self: *const Capture, filter: Filter, start: usize, count: usize, total: usize) !void {
        if (filter.from_ns > filter.to_ns or start > total or count == 0 or count > page_limit) return error.InvalidAllocationPage;
        if (filter.thread_id) |id| {
            for (self.threads[0..self.thread_count]) |thread| if (thread.id == id) return;
            return error.InvalidAllocationThread;
        }
    }
    fn matches(self: *const Capture, filter: Filter, lane: usize, begin: u64, end: u64) bool {
        return (filter.thread_id == null or filter.thread_id.? == self.threads[lane].id) and end >= filter.from_ns and begin <= filter.to_ns;
    }
    fn record(self: *const Capture, id: u32) RecordRow {
        const row = self.store.records.items[id];
        return .{ .ordinal = id, .thread = self.threads[row.lane], .event = row.event };
    }
    fn span(self: *const Capture, id: u32) SpanRow {
        const row = self.store.spans.items[id];
        return .{ .ordinal = id, .thread = self.threads[row.lane], .parent = row.parent_span, .reason = row.reason, .entry = if (row.entry_record) |n| self.record(n) else null, .returned = if (row.return_record) |n| self.record(n) else null };
    }
    pub fn recordPage(self: *const Capture, a: Allocator, expected: Key, filter: Filter, start: usize, count: usize) !Page(RecordRow) {
        try self.validate(expected);
        try self.filterValid(filter, start, count, self.store.records.items.len);
        if (filter.outstanding_only) return error.InvalidAllocationPage;
        var rows: std.ArrayList(RecordRow) = .empty;
        errdefer rows.deinit(a);
        var at = start;
        while (at < self.store.records.items.len and at - start < scan_limit and rows.items.len < count) : (at += 1) {
            const row = self.store.records.items[at];
            if (self.matches(filter, row.lane, row.event.time_ns, row.event.time_ns)) try rows.append(a, self.record(@intCast(at)));
        }
        return .{ .key = self.key(), .rows = try rows.toOwnedSlice(a), .next = if (at < self.store.records.items.len) at else null, .scanned = at - start, .total_unfiltered = self.store.records.items.len };
    }
    pub fn spanPage(self: *const Capture, a: Allocator, expected: Key, filter: Filter, start: usize, count: usize) !Page(SpanRow) {
        try self.validate(expected);
        try self.filterValid(filter, start, count, self.store.spans.items.len);
        if (filter.outstanding_only) return error.InvalidAllocationPage;
        var rows: std.ArrayList(SpanRow) = .empty;
        errdefer rows.deinit(a);
        var at = start;
        while (at < self.store.spans.items.len and at - start < scan_limit and rows.items.len < count) : (at += 1) {
            const row = self.span(@intCast(at));
            const begin = if (row.entry) |r| r.event.time_ns else row.returned.?.event.time_ns;
            const end = if (row.returned) |r| r.event.time_ns else begin;
            if (self.matches(filter, self.store.spans.items[at].lane, begin, end)) try rows.append(a, row);
        }
        return .{ .key = self.key(), .rows = try rows.toOwnedSlice(a), .next = if (at < self.store.spans.items.len) at else null, .scanned = at - start, .total_unfiltered = self.store.spans.items.len };
    }
    /// Thread/time filters select the allocation's originating entry. They do
    /// not recalculate outstanding-at-time totals; summary is whole-capture.
    pub fn lifetimePage(self: *const Capture, a: Allocator, expected: Key, filter: Filter, start: usize, count: usize) !Page(LifetimeRow) {
        try self.validate(expected);
        const result = self.analysis orelse return if (self.failure) |err| err else error.AllocationAnalysisPending;
        try self.filterValid(filter, start, count, result.view.lifetimes.items.len);
        var rows: std.ArrayList(LifetimeRow) = .empty;
        errdefer rows.deinit(a);
        var at = start;
        while (at < result.view.lifetimes.items.len and at - start < scan_limit and rows.items.len < count) : (at += 1) {
            const row = result.view.lifetimes.items[at];
            const allocation_span = result.projection.span_ids[row.allocation_call];
            const birth = self.store.spans.items[allocation_span];
            const entry = self.record(birth.entry_record.?);
            if ((filter.outstanding_only and row.state != .outstanding) or !self.matches(filter, birth.lane, entry.event.time_ns, entry.event.time_ns)) continue;
            try rows.append(a, .{ .ordinal = @intCast(at), .pointer = row.pointer, .requested_bytes = row.size, .state = row.state, .allocation_span = allocation_span, .release_span = if (row.release_call) |i| result.projection.span_ids[i] else null, .allocation_thread = self.threads[birth.lane], .min_ns = row.min_ns, .max_ns = row.max_ns });
        }
        return .{ .key = self.key(), .rows = try rows.toOwnedSlice(a), .next = if (at < result.view.lifetimes.items.len) at else null, .scanned = at - start, .total_unfiltered = result.view.lifetimes.items.len };
    }
};

const test_id = Identity{ .session_id = 10, .capture_id = 3, .process_id = 2, .pid = 42, .image_epoch = 7 };
const test_threads = [_]Thread{ .{ .id = 17, .tid = 42 }, .{ .id = 23, .tid = 43 } };
const test_hooks = [_]Hook{
    .{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture.so", .device = 1, .inode = 9, .file_offset = 0x1000, .link_address = 0x1000, .runtime_address = 0x401000 },
    .{ .id = 2, .kind = .free, .name = "free", .path = "/fixture.so", .device = 1, .inode = 9, .file_offset = 0x1100, .link_address = 0x1100, .runtime_address = 0x401100 },
};
fn testSample(time: u64, phase: events.Phase, kind: lifetime.Kind, sp: u64, arg: u64, result: u64) events.Event {
    return .{ .time_ns = time, .data = .{ .sample = .{ .phase = phase, .hook = if (kind == .malloc) 1 else 2, .kind = kind, .stack_key = sp, .arg0 = arg, .result = result } } };
}
fn waitAnalysis(capture: *Capture) !void {
    var i: usize = 0;
    while (capture.worker != null and i < 5000) : (i += 1) {
        capture.poll();
        if (capture.worker != null) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    if (capture.worker != null) return error.TestAnalysisDeadline;
}
test "allocation capture worker preserves thread scope, nested evidence and lifetime citations" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    // Cross-thread drain order is deliberately reversed. Free takes place later.
    try capture.feed(1, testSample(140, .enter, .free, 200, 99, 0));
    try capture.feed(1, testSample(150, .leave, .free, 200, 0, 0));
    try capture.feed(0, testSample(110, .enter, .malloc, 100, 24, 0));
    try capture.feed(0, testSample(112, .enter, .malloc, 80, 24, 0));
    try capture.feed(0, testSample(116, .leave, .malloc, 80, 0, 99));
    try capture.feed(0, testSample(120, .leave, .malloc, 100, 0, 99));
    try capture.feed(0, testSample(125, .enter, .malloc, 100, 8, 0));
    try capture.feed(0, testSample(130, .leave, .malloc, 100, 0, 1000));
    try capture.finish(160, false);
    const key = capture.key();
    try capture.requestAnalysis(false);
    try std.testing.expectEqual(State.analyzing, capture.state);
    try std.testing.expect(capture.memory() == null);
    // Evidence pages read the finalized store even while analysis owns its budget.
    const evidence = try capture.spanPage(a, key, .{}, 0, 10);
    defer a.free(evidence.rows);
    try std.testing.expectEqual(@as(usize, 4), evidence.rows.len);
    try std.testing.expectEqual(@as(?u32, 1), evidence.rows[2].parent);
    try std.testing.expectEqual(@as(u64, 23), evidence.rows[0].thread.id);
    try waitAnalysis(capture);
    try std.testing.expectEqual(State.ready, capture.state);
    try std.testing.expectEqual(key, capture.key());
    try std.testing.expectEqual(@as(u64, 8), capture.summary().?.outstanding_bytes);
    const page = try capture.lifetimePage(a, key, .{}, 0, 10);
    defer a.free(page.rows);
    try std.testing.expectEqual(@as(usize, 2), page.rows.len);
    try std.testing.expectEqual(@as(u32, 1), page.rows[0].allocation_span);
    try std.testing.expectEqual(@as(?u32, 0), page.rows[0].release_span);
    try std.testing.expectEqual(@as(?u64, 20), page.rows[0].min_ns);
    try std.testing.expectEqual(@as(?u64, 40), page.rows[0].max_ns);
    const outstanding = try capture.lifetimePage(a, key, .{ .outstanding_only = true, .thread_id = 17 }, 0, 10);
    defer a.free(outstanding.rows);
    try std.testing.expectEqual(@as(usize, 1), outstanding.rows.len);
    try std.testing.expectEqual(@as(u64, 1000), outstanding.rows[0].pointer);
    const outside = try capture.lifetimePage(a, key, .{ .from_ns = 140 }, 0, 10);
    defer a.free(outside.rows);
    try std.testing.expectEqual(@as(usize, 0), outside.rows.len);
    // The summary never pretends that this page filter recomputed heap totals.
    try std.testing.expectEqual(@as(u64, 8), capture.summary().?.outstanding_bytes);
}
test "allocation pages reject stale revisions and identities across process sessions" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    const old = capture.key();
    try capture.feed(0, testSample(110, .enter, .malloc, 100, 16, 0));
    try std.testing.expectError(error.StaleAllocationCapture, capture.recordPage(a, old, .{}, 0, 10));
    var foreign = capture.key();
    foreign.identity.process_id += 1;
    try std.testing.expectError(error.StaleAllocationCapture, capture.recordPage(a, foreign, .{}, 0, 10));
    foreign = capture.key();
    foreign.identity.session_id += 1;
    try std.testing.expectError(error.StaleAllocationCapture, capture.spanPage(a, foreign, .{}, 0, 10));
    try std.testing.expectError(error.InvalidAllocationThread, capture.recordPage(a, capture.key(), .{ .thread_id = 999 }, 0, 10));
    try std.testing.expectError(error.InvalidAllocationPage, capture.recordPage(a, capture.key(), .{}, 0, page_limit + 1));
    try std.testing.expectError(error.InvalidAllocationPage, capture.recordPage(a, capture.key(), .{}, 2, 1));
    try std.testing.expectError(error.AllocationStillCollecting, capture.requestAnalysis(false));
}
test "allocation loss preserves call evidence but cannot publish outstanding totals" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    try capture.feed(0, testSample(110, .enter, .malloc, 100, 16, 0));
    try capture.feed(0, .{ .time_ns = 111, .data = .{ .lost = 1 } });
    try capture.feed(0, testSample(112, .leave, .malloc, 100, 0, 99));
    try capture.finish(120, false);
    try std.testing.expectError(error.AllocationEvidenceGap, capture.requestAnalysis(false));
    try std.testing.expect(capture.summary() == null);
    const page = try capture.spanPage(a, capture.key(), .{}, 0, 10);
    defer a.free(page.rows);
    try std.testing.expectEqual(events.Reason.loss, page.rows[0].reason);
    try std.testing.expectEqual(events.Reason.missing_entry, page.rows[1].reason);
    try std.testing.expectError(error.AllocationEvidenceGap, capture.lifetimePage(a, capture.key(), .{}, 0, 10));
}
test "invalid source hooks and unknown suffixes finalize immutable uncertain evidence" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    var unknown = testSample(110, .enter, .malloc, 100, 16, 0);
    unknown.data.sample.hook = 99;
    try std.testing.expectError(error.InvalidAllocationHook, capture.feed(0, unknown));
    try std.testing.expectEqual(State.stopping, capture.state);
    try std.testing.expect(capture.ended_ns == null);
    try std.testing.expect(capture.store.unread_possible);
    try std.testing.expectEqual(events.Reason.identity, capture.store.first_gap.?.reason);
    const frozen = capture.key();
    try std.testing.expectError(error.AllocationFinished, capture.feed(0, unknown));
    capture.abort(.exec);
    try std.testing.expectEqual(frozen, capture.key());
    try std.testing.expectError(error.AllocationCaptureNotFinalized, capture.requestAnalysis(false));
    try capture.finish(200, true);
    const final_key = capture.key();
    try std.testing.expectEqual(frozen.revision + 1, final_key.revision);
    try std.testing.expectEqual(@as(?u64, 200), capture.ended_ns);
    try capture.finish(300, false);
    try std.testing.expectEqual(final_key, capture.key());
    try std.testing.expectEqual(@as(?u64, 200), capture.ended_ns);
    try std.testing.expectError(error.AllocationEvidenceGap, capture.requestAnalysis(false));
}
test "sparse allocation pages bound scanning and advance even without matched rows" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    for (0..2500) |i| {
        try capture.feed(0, testSample(100 + i * 2, .enter, .malloc, 100, 16, 0));
        try capture.feed(0, testSample(101 + i * 2, .leave, .malloc, 100, 0, i + 1));
    }
    const page = try capture.recordPage(a, capture.key(), .{ .thread_id = 23 }, 0, 1);
    defer a.free(page.rows);
    try std.testing.expectEqual(@as(usize, scan_limit), page.scanned);
    try std.testing.expectEqual(@as(?usize, scan_limit), page.next);
    try std.testing.expectEqual(@as(usize, 0), page.rows.len);
    const last = try capture.recordPage(a, page.key, .{ .thread_id = 23 }, page.next.?, 1);
    defer a.free(last.rows);
    try std.testing.expectEqual(@as(?usize, null), last.next);
    try std.testing.expectEqual(@as(usize, 5000 - scan_limit), last.scanned);
}
test "allocation worker failures latch and preserve evidence within one budget" {
    const a = std.testing.allocator;
    var metadata: usize = 0;
    for (test_hooks) |hook| metadata += hook.name.len + hook.path.len;
    const limit = @sizeOf(Capture) + 64 * @sizeOf(events.Record) + 64 * @sizeOf(events.Span) + metadata + 128;
    const capture = try Capture.create(a, test_id, .{ .memory_limit = limit }, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    for (0..16) |i| {
        try capture.feed(0, testSample(100 + i * 2, .enter, .malloc, 100, 16, 0));
        try capture.feed(0, testSample(101 + i * 2, .leave, .malloc, 100, 0, i + 1));
    }
    try capture.finish(140, false);
    try capture.requestAnalysis(false);
    try waitAnalysis(capture);
    try std.testing.expectEqual(error.AllocationMemoryLimit, capture.failure.?);
    try std.testing.expectError(error.AllocationMemoryLimit, capture.requestAnalysis(false));
    try std.testing.expect(capture.worker == null and capture.summary() == null);
    try std.testing.expect(capture.memory().?.peak <= limit);
    const page = try capture.recordPage(a, capture.key(), .{}, 0, 1);
    defer a.free(page.rows);
    try std.testing.expectEqual(@as(usize, 1), page.rows.len);
}
test "maximum allocation capture worker stays inside the configured total budget and cancels" {
    const a = std.testing.allocator;
    const capture = try Capture.create(a, test_id, .{ .record_limit = events.max_records }, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    for (0..lifetime.max_calls) |i| {
        try capture.feed(0, testSample(100 + i * 2, .enter, .malloc, 100, 16, 0));
        try capture.feed(0, testSample(101 + i * 2, .leave, .malloc, 100, 0, i + 1));
    }
    try capture.finish(100 + 2 * lifetime.max_calls, false);
    const key = capture.key();
    try capture.requestAnalysis(false);
    capture.cancelAnalysis();
    try waitAnalysis(capture);
    try std.testing.expectEqual(error.AllocationAnalysisCancelled, capture.failure.?);
    try std.testing.expect(capture.analysis == null);
    try std.testing.expectError(error.AllocationAnalysisCancelled, capture.requestAnalysis(false));
    try capture.requestAnalysis(true);
    try waitAnalysis(capture);
    try std.testing.expectEqual(State.ready, capture.state);
    try std.testing.expectEqual(key, capture.key());
    try std.testing.expectEqual(@as(u64, lifetime.max_calls), capture.summary().?.outstanding_count);
    const memory = capture.memory().?;
    try std.testing.expect(memory.peak <= default_memory_limit);
    std.debug.print("allocation capture worker peak: {d} bytes / {d} records; evidence, metadata and analysis included\n", .{ memory.peak, events.max_records });
}
fn createFailureCase(a: Allocator) !void {
    const capture = try Capture.create(a, test_id, .{}, &test_threads, &test_hooks, 100);
    defer capture.deinit();
    try capture.feed(0, testSample(110, .enter, .malloc, 100, 16, 0));
    try capture.feed(0, testSample(111, .leave, .malloc, 100, 0, 99));
}
test "allocation capture creation and evidence failure release every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createFailureCase, .{});
}
