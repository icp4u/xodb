//! The owner copies ended native source records before starting the worker.
//! Only the invocation capture remains borrowed, pinned by its Session owner.
const std = @import("std");
pub const associations = @import("associations.zig");
const model = @import("capture.zig");
const comparison = @import("comparison.zig");
const Profile = @import("../profile/capture.zig").Capture;
const Allocation = @import("../profile/allocation_capture.zig").Capture;
const Producer = @import("../profile/producer.zig").Producer;
const Budget = @import("../profile/archive_budget.zig").Budget;
const a = std.heap.page_allocator;
pub const ProfileSource = struct { capture: *const Profile, id: u64, revision: u64, cpu: bool = true, syscalls: bool = false };
pub const AllocationSource = struct { capture: *const Allocation, id: u64, revision: u64 };
pub const max_live_records = 1024 * 1024;
pub const saved_evidence = @import("association_evidence.zig");
pub const Source = saved_evidence.Source;
pub const clock_basis = "recorded acquisition contract: native sources used host CLOCK_MONOTONIC in the same live Session; remote timestamps were already normalized with a fixed offset, summed conversion uncertainty is retained and drift is unmeasured";
pub const allocation_basis = "allocator entry/return sample records only; metadata records excluded explicitly; event counts are not allocations, lifetimes or requested bytes";
const Thread = struct { tid: i32, id: u64 };
fn threadLess(_: void, lhs: Thread, rhs: Thread) bool {
    return lhs.tid < rhs.tid;
}
fn stableThread(threads: []const Thread, tid: u32) ?u64 {
    if (tid > std.math.maxInt(i32)) return null;
    var low: usize = 0;
    var high = threads.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (threads[mid].tid < tid) low = mid + 1 else high = mid;
    }
    if (low == threads.len or threads[low].tid != tid or (low + 1 < threads.len and threads[low + 1].tid == tid)) return null;
    return if (threads[low].id != 0) threads[low].id else null;
}
fn trustedTime(start: ?u64, end: ?u64, before: u64) bool {
    const lo = start orelse return false;
    const hi = end orelse return false;
    return hi >= lo and lo < before and hi <= before;
}
fn compatible(capture: *const model.Capture, owner_session: u64, owner_process: u64, session_id: u64, process_id: u64, pid: i32, image_epoch: u64) !void {
    const id = capture.identity;
    if (capture.offline or owner_session != id.session_id or owner_process != id.process_id or session_id != id.session_id or process_id != id.process_id or pid != id.pid or image_epoch != id.image_epoch) return error.ObservationAssociationIdentity;
}
const uncertainty = saved_evidence.uncertainty;
pub const Job = struct {
    owner: @import("../service/job_owner.zig").Owner = .{},
    id: u64,
    capture: *const model.Capture,
    selection: comparison.Selection,
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    origin: associations.Origin,
    streams: [3]associations.Stream = undefined,
    sources: [3]Source = undefined,
    source_count: usize = 0,
    copied_records: usize = 0,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    result: ?associations.Result = null,
    err: ?anyerror = null,
    association_algorithm: []const u8 = saved_evidence.algorithm,
    analysis_origin: @FieldType(saved_evidence.Snapshot, "analysis_origin") = .live,
    algorithm_supported: bool = true,
    pub fn create(id: u64, capture: *const model.Capture, owner_session: u64, owner_process: u64, profile: ?ProfileSource, allocation: ?AllocationSource, selection: comparison.Selection) !*Job {
        try selection.validate();
        if (!capture.store.finished) return error.ObservationStillCollecting;
        if (capture.offline) return error.NativeObservationAssociationRequired;
        if (profile == null and allocation == null) return error.NoObservationAssociationSources;
        try compatible(capture, owner_session, owner_process, owner_session, owner_process, capture.identity.pid, capture.identity.image_epoch);
        const self = try a.create(Job);
        self.* = .{
            .id = id,
            .capture = capture,
            .selection = selection,
            .budget = .{ .backing = a, .limit = saved_evidence.memory_limit },
            .arena = undefined,
            // Domain tokens are namespaced by the verified live Session. They
            // do not pretend to be boot IDs or source capture equality proofs.
            .origin = .{ .origin_id = capture.identity.capture_id, .session_id = owner_session, .process_id = owner_process, .image_epoch = capture.identity.image_epoch, .producer_id = owner_session, .clock_id = 1 },
        };
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        if (profile) |source| self.copyProfile(source, owner_session, owner_process) catch |err| return saved_evidence.budgetError(&self.budget, err);
        if (allocation) |source| self.copyAllocation(source, owner_session, owner_process) catch |err| return saved_evidence.budgetError(&self.budget, err);
        if (self.source_count == 0) return error.NoObservationAssociationSources;
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    /// Borrowed slices are valid only while this completed job is pinned.
    /// Consumers retain IDs, then re-look up on the Session owner thread for
    /// each use; never retain slices across job/capture replacement. An old ID
    /// returns StaleObservationAssociations, not a view of its successor.
    pub fn view(self: *const Job) !saved_evidence.Snapshot {
        if (!self.done.load(.acquire)) return error.ObservationAssociationsBusy;
        if (self.err) |err| return err;
        if (!self.algorithm_supported) {
            var snapshot = self.capture.saved_associations.?.snapshot;
            snapshot.analysis_origin = .restored;
            return snapshot;
        }
        return .{ .association_algorithm = self.association_algorithm, .analysis_origin = self.analysis_origin, .origin = self.origin, .selection = self.selection, .sources = self.sources[0..self.source_count], .streams = self.streams[0..self.source_count], .derived = self.result orelse return error.NoObservationAssociations };
    }
    pub fn fromSaved(id: u64, capture: *const model.Capture, selection: comparison.Selection, synchronous: bool, cancel_flag: ?*const std.atomic.Value(bool)) !*Job {
        try selection.validate();
        const saved = (capture.saved_associations orelse return error.NoSavedObservationAssociations).snapshot;
        const self = try a.create(Job);
        self.* = .{ .id = id, .capture = capture, .selection = selection, .budget = .{ .backing = a, .limit = saved_evidence.memory_limit }, .arena = undefined, .origin = saved.origin };
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        self.analysis_origin = if (synchronous) .restored else .reanalysed;
        if (synchronous) {
            self.association_algorithm = self.arena.allocator().dupe(u8, saved.association_algorithm) catch |err| return saved_evidence.budgetError(&self.budget, err);
            self.algorithm_supported = std.mem.eql(u8, saved.association_algorithm, saved_evidence.algorithm);
        }
        const owned = self.arena.allocator();
        for (saved.sources, saved.streams) |source, stream| {
            try self.reserveRecords(stream.points.len + stream.intervals.len);
            self.sources[self.source_count] = saved_evidence.clone(Source, owned, source) catch |err| return saved_evidence.budgetError(&self.budget, err);
            self.streams[self.source_count] = saved_evidence.clone(associations.Stream, owned, stream) catch |err| return saved_evidence.budgetError(&self.budget, err);
            self.source_count += 1;
        }
        if (cancel_flag) |flag| if (flag.load(.acquire)) return error.ObservationAnalysisCancelled;
        if (synchronous) {
            if (self.algorithm_supported) self.result = associations.build(self.budget.allocator(), &capture.store, self.origin, self.streams[0..self.source_count], .{ .selection = selection }, cancel_flag) catch |err| return saved_evidence.budgetError(&self.budget, err);
            self.done.store(true, .release);
        } else self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn reserveRecords(self: *Job, count: usize) !void {
        const limit = max_live_records;
        if (count > limit - self.copied_records) return error.ObservationAssociationRecordLimit;
        self.copied_records += count;
    }
    fn add(self: *Job, source: Source, points: []const associations.Point, intervals: []const associations.Interval) !void {
        if (source.ended_ns < source.started_ns) return error.ObservationAssociationClock;
        const delta = try uncertainty(self.capture.producer, source.producer);
        var origin = self.origin;
        origin.origin_id = source.capture_id;
        const proof: associations.ClockProof = if (source.producer == null) .same_domain else .{ .correlated = .{
            .proof_id = source.stream_id,
            .source_producer_id = origin.producer_id,
            .target_producer_id = self.origin.producer_id,
            .source_clock_id = origin.clock_id,
            .target_clock_id = self.origin.clock_id,
            .offset_ns = 0,
            .uncertainty_ns = delta,
            .valid_start_ns = source.started_ns,
            .valid_end_ns = source.ended_ns,
        } };
        self.sources[self.source_count] = source;
        self.streams[self.source_count] = .{ .id = source.stream_id, .origin = origin, .kind = source.kind, .clock = proof, .points = points, .intervals = intervals };
        self.source_count += 1;
    }
    fn copyProfile(self: *Job, selected: ProfileSource, owner_session: u64, owner_process: u64) !void {
        const source = selected.capture;
        if (source.id != selected.id or source.revision != selected.revision) return error.StaleProfileView;
        if (source.offline) return error.NativeObservationAssociationRequired;
        if (source.collector != null or source.syscall_collector != null or source.status == .collecting or source.ended_ns == null) return error.ProfileStillCollecting;
        if (source.accepted.clockid != 1) return error.ObservationAssociationClock;
        if (!selected.cpu and !selected.syscalls) return error.NoObservationAssociationSources;
        try compatible(self.capture, owner_session, owner_process, source.session_id, owner_process, source.pid, source.image_epoch);
        _ = try uncertainty(self.capture.producer, source.producer);
        const owned = self.arena.allocator();
        if (source.thread_count > source.threads.len) return error.InvalidObservationAssociationSource;
        const threads = try owned.alloc(Thread, source.thread_count);
        for (source.threads[0..source.thread_count], threads) |thread, *out| out.* = .{ .tid = thread.perf.tid, .id = thread.debugger_id };
        std.mem.sort(Thread, threads, {}, threadLess);
        if (selected.cpu) {
            try self.reserveRecords(source.samples.len());
            const points = try owned.alloc(associations.Point, source.samples.len());
            var scope_untrusted: usize = 0;
            for (points, 0..) |*point, ordinal| {
                const record = source.samples.core(ordinal).*;
                const trusted = !record.timePresent() or trustedTime(record.time_ns, record.time_ns, source.trusted_before_ns);
                if (!trusted) scope_untrusted += 1;
                const identity = if (trusted and record.tidPresent() and record.pid == source.pid) stableThread(threads, record.tid) else null;
                point.* = .{ .ordinal = ordinal, .time_ns = if (record.timePresent()) record.time_ns else null, .tid = if (identity != null) record.tid else 0, .thread_id = identity };
            }
            try self.add(.{ .stream_id = 1, .kind = .cpu, .capture_id = source.id, .revision = source.revision, .started_ns = source.started_ns, .ended_ns = source.ended_ns.?, .stored_records = points.len, .included_records = points.len, .scope_untrusted_records = scope_untrusted, .identity_trusted_before_ns = if (source.trusted_before_ns == std.math.maxInt(u64)) null else source.trusted_before_ns, .lost_records = source.lost_records, .lost_samples = source.lost_samples, .throttles = source.throttles, .loss_basis = "lost_records counts PERF_RECORD_LOST notifications; lost_samples is their reported missing samples", .discarded_records = source.discarded_samples, .unread_possible = source.hasStop(.drain_limit) or source.hasStop(.collector_error) or source.hasStop(.decode_error), .producer = source.producer }, points, &.{});
        }
        if (selected.syscalls) {
            if (!source.syscalls.enabled) return error.SyscallTimingNotEnabled;
            if (!source.syscalls.finished) return error.ProfileStillCollecting;
            try self.reserveRecords(source.syscalls.items.items.len);
            const intervals = try owned.alloc(associations.Interval, source.syscalls.items.items.len);
            var incomplete: usize = 0;
            var scope_untrusted: usize = 0;
            for (source.syscalls.items.items, intervals, 0..) |record, *interval, ordinal| {
                const trusted = record.reason != .complete or trustedTime(record.entry_ns, record.exit_ns, source.trusted_before_ns);
                if (!trusted) scope_untrusted += 1;
                const thread = if (trusted and record.thread_index < source.thread_count) source.threads[record.thread_index] else null;
                const valid = record.reason == .complete;
                if (!valid) incomplete += 1;
                interval.* = .{ .ordinal = ordinal, .start_ns = if (valid) record.entry_ns else null, .end_ns = if (valid) record.exit_ns else null, .tid = if (thread) |t| (if (t.perf.tid > 0) @intCast(t.perf.tid) else 0) else 0, .thread_id = if (thread) |t| (if (t.debugger_id > 0) t.debugger_id else null) else null };
            }
            try self.add(.{ .stream_id = 2, .kind = .syscall, .capture_id = source.id, .revision = source.revision, .started_ns = source.started_ns, .ended_ns = source.ended_ns.?, .stored_records = intervals.len, .included_records = intervals.len, .incomplete_records = incomplete, .scope_untrusted_records = scope_untrusted, .identity_trusted_before_ns = if (source.trusted_before_ns == std.math.maxInt(u64)) null else source.trusted_before_ns, .lost_samples = source.syscalls.lost, .throttles = source.syscalls.throttles, .loss_basis = "lost_samples counts missing raw syscall enter/exit events reported by the collector", .discarded_records = source.syscalls.discarded, .unread_possible = source.syscalls.unread_possible, .producer = source.producer }, &.{}, intervals);
        }
    }
    fn copyAllocation(self: *Job, selected: AllocationSource, owner_session: u64, owner_process: u64) !void {
        const source = selected.capture;
        if (source.identity.capture_id != selected.id or source.revision != selected.revision) return error.StaleAllocationCapture;
        if (source.archived or source.origin != null) return error.NativeObservationAssociationRequired;
        if (!source.store.finished or source.ended_ns == null) return error.AllocationCaptureNotFinalized;
        try compatible(self.capture, owner_session, owner_process, source.identity.session_id, source.identity.process_id, source.identity.pid, source.identity.image_epoch);
        _ = try uncertainty(self.capture.producer, source.producer);
        var count: usize = 0;
        for (source.store.records.items) |record| if (record.event.data == .sample) {
            count += 1;
        };
        try self.reserveRecords(count);
        const points = try self.arena.allocator().alloc(associations.Point, count);
        var at: usize = 0;
        for (source.store.records.items, 0..) |record, ordinal| {
            if (record.event.data != .sample) continue;
            const thread = if (record.lane < source.thread_count) source.threads[record.lane] else null;
            points[at] = .{ .ordinal = ordinal, .time_ns = record.event.time_ns, .tid = if (thread) |t| (if (t.tid > 0) @intCast(t.tid) else 0) else 0, .thread_id = if (thread) |t| (if (t.id > 0) t.id else null) else null };
            at += 1;
        }
        try self.add(.{ .stream_id = 3, .kind = .allocation, .capture_id = source.identity.capture_id, .revision = source.revision, .started_ns = source.started_ns, .ended_ns = source.ended_ns.?, .stored_records = source.store.records.items.len, .included_records = count, .excluded_metadata_records = source.store.records.items.len - count, .lost_samples = source.store.lost, .throttles = source.store.throttles, .loss_basis = "lost_samples counts missing allocator probe events reported by the collector", .discarded_records = source.store.rejected, .unread_possible = source.store.unread_possible, .producer = source.producer }, points, &.{});
    }
    fn run(self: *Job) void {
        self.result = associations.build(self.budget.allocator(), &self.capture.store, self.origin, self.streams[0..self.source_count], .{ .selection = self.selection }, &self.cancel) catch |err| blk: {
            self.err = saved_evidence.budgetError(&self.budget, err);
            break :blk null;
        };
        self.done.store(true, .release);
    }
    pub fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        if (self.worker) |worker| worker.join();
        if (self.result) |*result| result.deinit(self.budget.allocator());
        self.arena.deinit();
        a.destroy(self);
    }
};
test "producer proof requires consistent acquisition and checked uncertainty" {
    const p: Producer = .{ .machine = 62, .address_bits = 64, .little_endian = true, .boot_id = null, .monotonic_ns = 10, .host_monotonic_ns = 20, .uncertainty_ns = 7 };
    try std.testing.expectEqual(@as(u64, 0), try uncertainty(null, null));
    try std.testing.expectEqual(@as(u64, 14), try uncertainty(p, p));
    try std.testing.expectError(error.ObservationAssociationProducer, uncertainty(p, null));
    var different = p;
    different.machine = 4;
    try std.testing.expectError(error.ObservationAssociationProducer, uncertainty(p, different));
    different = p;
    different.uncertainty_ns = std.math.maxInt(u64);
    try std.testing.expectError(error.ObservationAssociationClockOverflow, uncertainty(p, different));
}
test "source thread lookup rejects reused TIDs instead of choosing the first" {
    const threads = [_]Thread{ .{ .tid = 100, .id = 1 }, .{ .tid = 101, .id = 2 }, .{ .tid = 101, .id = 3 }, .{ .tid = 102, .id = 4 } };
    try std.testing.expectEqual(@as(?u64, 1), stableThread(&threads, 100));
    try std.testing.expectEqual(@as(?u64, null), stableThread(&threads, 101));
    try std.testing.expectEqual(@as(?u64, 4), stableThread(&threads, 102));
}

test "profile identity trust excludes boundary points and crossing intervals" {
    try std.testing.expect(trustedTime(9, 9, 10));
    try std.testing.expect(!trustedTime(10, 10, 10));
    try std.testing.expect(trustedTime(8, 10, 10));
    try std.testing.expect(!trustedTime(8, 11, 10));
    try std.testing.expect(!trustedTime(0, 0, 0));
    try std.testing.expect(!trustedTime(10, 9, 20));
    try std.testing.expect(!trustedTime(null, 10, 20));
}
