//! Bounded asynchronous temporal evidence joins for ended native captures.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const jobs = @import("../observe/association_job.zig");
const comparison = @import("../observe/comparison.zig");
const wire = @import("profile.zig");
const V = std.json.Value;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "associate_observation", "get_observation_associations", "cancel_observation_associations" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn boolean(args: V, key: []const u8, default: bool) !bool {
    const value = args.object.get(key) orelse return default;
    return if (value == .bool) value.bool else error.InvalidArguments;
}
fn word(args: V, key: []const u8) !u64 {
    const value = args.object.get(key) orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    return std.fmt.parseInt(u64, value.string, 0) catch error.InvalidArguments;
}
fn exact(a: std.mem.Allocator, object: anytype) !V {
    var value = try wire.value(a, object);
    try @import("exact.zig").observation(a, &value);
    return value;
}
pub fn status(a: std.mem.Allocator, job: *const jobs.Job) !V {
    const done = job.done.load(.acquire);
    const source_incomplete = for (job.sources[0..job.source_count]) |source| {
        if (source.coverageIncomplete()) break true;
    } else false;
    return exact(a, .{
        .id = job.id,
        .identity = job.capture.identity,
        .offline = job.capture.offline,
        .association_algorithm = job.association_algorithm,
        .algorithm_supported = job.algorithm_supported,
        .payload_version = @as(u32, 2),
        .analysis_origin = job.analysis_origin,
        .rows_truncated = if (done and job.result != null) @as(?bool, job.result.?.omitted_rows != 0) else null,
        .calls_truncated = if (done and job.result != null) @as(?bool, job.result.?.omitted_calls != 0) else null,
        .omitted_rows = if (done and job.result != null) @as(?u64, job.result.?.omitted_rows) else null,
        .omitted_calls = if (done and job.result != null) @as(?u64, job.result.?.omitted_calls) else null,
        .citation_basis = "retained normalized source points/intervals and original ordinals; full sample stacks and allocation payloads are not included",
        .state = if (!done) "running" else if (if (job.err) |err| err == error.ObservationAnalysisCancelled else false) "cancelled" else if (job.err != null) "failed" else if (!job.algorithm_supported) "unsupported_algorithm" else "completed",
        .cancel_requested = job.cancel.load(.acquire),
        .error_name = if (done) (if (job.err) |err| @errorName(err) else @as(?[]const u8, null)) else null,
        .sources = job.sources[0..job.source_count],
        .selection = job.selection,
        .invocation_producer = job.capture.producer,
        .counts = if (done and job.result != null) @as(?jobs.associations.Counts, job.result.?.counts) else null,
        .selected_complete_calls = if (done and job.result != null) @as(?u64, job.result.?.selected_complete_calls) else null,
        .excluded_incomplete_calls = if (done and job.result != null) @as(?u64, job.result.?.excluded_incomplete_calls) else null,
        .coverage_incomplete = if (done and job.result != null) @as(?bool, source_incomplete or job.result.?.coverage_incomplete or job.result.?.excluded_incomplete_calls != 0) else null,
        .source_coverage_incomplete = source_incomplete,
        .invocation_coverage_incomplete = if (done and job.result != null) @as(?bool, job.result.?.coverage_incomplete or job.result.?.excluded_incomplete_calls != 0) else null,
        .peak_bytes = if (done) @as(?usize, job.budget.peak) else null,
        .basis = jobs.associations.basis,
        .clock_basis = jobs.clock_basis,
        .thread_basis = "stable debugger IDs retained from acquisition; missing or reused source TIDs are unusable, never silently inferred",
        .allocation_basis = jobs.allocation_basis,
    });
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "associate_observation")) {
        try wire.fields(args, &.{ "session_id", "capture_id", "threshold_ns", "thread_id", "function_id", "start_ns", "end_ns", "argument_index", "argument_value", "return_value", "profile_id", "profile_revision", "include_cpu", "include_syscalls", "allocation_id", "allocation_revision" });
        if (session.observation_archive) |job| if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
        const capture = session.observations.capture orelse return error.NoObservation;
        if (capture.offline) {
            inline for (.{ "profile_id", "profile_revision", "include_cpu", "include_syscalls", "allocation_id", "allocation_revision" }) |key| if (args.object.get(key) != null) return error.InvalidArguments;
        }
        if (capture.identity.session_id != try wire.number(args, "session_id", null) or capture.identity.capture_id != try wire.number(args, "capture_id", null)) return error.StaleObservation;
        if (!capture.store.finished or session.observations.busy()) return error.ObservationStillCollecting;
        var selection = comparison.Selection{ .threshold_ns = try wire.number(args, "threshold_ns", null) };
        inline for (.{ "thread_id", "start_ns", "end_ns" }) |key| if (args.object.get(key) != null) {
            @field(selection, key) = try wire.number(args, key, null);
        };
        if (args.object.get("function_id") != null) selection.function_id = std.math.cast(u32, try wire.number(args, "function_id", null)) orelse return error.InvalidArguments;
        if (args.object.get("return_value") != null) selection.return_value = try word(args, "return_value");
        if (args.object.get("argument_index") != null or args.object.get("argument_value") != null) {
            const index = try wire.number(args, "argument_index", null);
            if (index >= 6) return error.InvalidArguments;
            selection.argument = .{ .index = @intCast(index), .value = try word(args, "argument_value") };
        }
        selection.validate() catch return error.InvalidArguments;
        var profile: ?jobs.ProfileSource = null;
        if (args.object.get("profile_id") != null or args.object.get("profile_revision") != null) {
            profile = .{ .capture = session.profile orelse return error.NoProfile, .id = try wire.number(args, "profile_id", null), .revision = try wire.number(args, "profile_revision", null), .cpu = try boolean(args, "include_cpu", true), .syscalls = try boolean(args, "include_syscalls", false) };
        } else if (args.object.get("include_cpu") != null or args.object.get("include_syscalls") != null) return error.InvalidArguments;
        var allocation: ?jobs.AllocationSource = null;
        if (args.object.get("allocation_id") != null or args.object.get("allocation_revision") != null) allocation = .{ .capture = session.allocations.capture orelse return error.NoAllocationCapture, .id = try wire.number(args, "allocation_id", null), .revision = try wire.number(args, "allocation_revision", null) };
        if (session.observation_associations) |old| if (!old.done.load(.acquire)) return error.ObservationAssociationsBusy;
        if (session.next_observation_association == std.math.maxInt(u64)) return error.ObservationAssociationLimit;
        // Failed creation preserves the previous completed result.
        const candidate = if (capture.offline) try jobs.Job.fromSaved(session.next_observation_association, capture, selection, false, null) else try jobs.Job.create(session.next_observation_association, capture, session.id, session.process_id, profile, allocation, selection);
        if (session.observation_associations) |old| old.deinit();
        session.observation_associations = candidate;
        session.next_observation_association += 1;
        return status(a, candidate);
    }
    const get = std.mem.eql(u8, name, "get_observation_associations");
    try wire.fields(args, if (get) &.{ "id", "start", "limit", "stream_id" } else &.{"id"});
    const job = session.observation_associations orelse return error.NoObservationAssociations;
    if (job.id != try wire.number(args, "id", null)) return error.StaleObservationAssociations;
    if (!get) {
        if (!job.done.load(.acquire)) job.cancel.store(true, .release);
        return status(a, job);
    }
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 16);
    if (limit == 0 or limit > 64) return error.InvalidArguments;
    var value = try status(a, job);
    // Source snapshots remain available even after source captures are replaced.
    if (args.object.get("stream_id") != null) {
        const stream_id = try wire.number(args, "stream_id", null);
        const stream = for (job.streams[0..job.source_count]) |stream| {
            if (stream.id == stream_id) break stream;
        } else return error.UnknownObservationAssociationSource;
        const point = stream.intervals.len == 0;
        const total = if (point) stream.points.len else stream.intervals.len;
        if (start > total) return error.InvalidArguments;
        const end = @min(total, start + limit);
        const data = if (point) try exact(a, .{ .stream_id = stream_id, .kind = stream.kind, .origin = stream.origin, .clock = stream.clock, .start = start, .total = total, .next = if (end < total) @as(?usize, end) else null, .points = stream.points[start..end] }) else try exact(a, .{ .stream_id = stream_id, .kind = stream.kind, .origin = stream.origin, .clock = stream.clock, .start = start, .total = total, .next = if (end < total) @as(?usize, end) else null, .intervals = stream.intervals[start..end] });
        try value.object.put(a, "source_records", data);
        return value;
    }
    if (job.done.load(.acquire)) if (job.result) |result| {
        if (start > result.rows.len) return error.InvalidArguments;
        const end = @min(result.rows.len, start + limit);
        try value.object.put(a, "result", try exact(a, .{ .origin = result.origin, .streams = result.streams, .counts = result.counts, .calls = result.calls, .rows = result.rows[start..end], .start = start, .total_rows = result.rows.len, .next = if (end < result.rows.len) @as(?usize, end) else null, .omitted_rows = result.omitted_rows, .omitted_calls = result.omitted_calls, .work_steps = result.work_steps }));
    };
    return value;
}
