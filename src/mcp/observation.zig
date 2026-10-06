//! Generic function observations. Raw register words have an explicit SysV ABI;
//! no prototype, pointee contents, CPU cost or causality is inferred.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const model = @import("../observe/capture.zig");
const types = @import("../observe/types.zig");
const comparison = @import("../observe/comparison.zig");
const wire = @import("profile.zig");
const V = std.json.Value;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "start_observation", "stop_observation", "get_observation", "get_observation_calls", "get_observation_records", "compare_observation", "get_observation_comparison", "cancel_observation_comparison", "save_observation", "get_observation_archive", "cancel_observation_archive" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn exact(a: std.mem.Allocator, object: anytype) !V {
    var value = try wire.value(a, object);
    try @import("exact.zig").observation(a, &value);
    return value;
}
fn number32(args: V, key: []const u8, default: ?u32) !u32 {
    return std.math.cast(u32, try wire.number(args, key, if (default) |n| @as(?u64, n) else null)) orelse error.InvalidArguments;
}
fn word(args: V, key: []const u8) !u64 {
    const value = args.object.get(key) orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    return std.fmt.parseInt(u64, value.string, 0) catch error.InvalidArguments;
}
pub fn status(a: std.mem.Allocator, session: *Session) !V {
    const live = &session.observations;
    const capture = live.capture;
    const pending = live.pendingContext();
    return exact(a, .{
        .state = if (pending != null) "preparing" else if (capture) |v| (if (v.store.finished) "completed" else "collecting") else "empty",
        .identity = if (capture) |v| @as(?model.Identity, v.identity) else null,
        .preparation = if (pending) |p| @as(?model.Identity, p.identity) else null,
        .functions = if (capture) |v| v.functions else &.{},
        .threads = if (capture) |v| v.threads else &.{},
        .started_ns = if (capture) |v| @as(?u64, v.started_ns) else null,
        .ended_ns = if (capture) |v| v.ended_ns else null,
        .stop_reason = if (capture) |v| v.stop_reason else null,
        .finish_reason = if (capture) |v| v.store.finish_reason else null,
        .records = if (capture) |v| v.store.records.items.len else 0,
        .calls = if (capture) |v| v.store.calls.items.len else 0,
        .first_gap = if (capture) |v| v.store.first_gap else null,
        .lost = if (capture) |v| v.store.lost else 0,
        .rejected = if (capture) |v| v.store.rejected else 0,
        .unread_possible = if (capture) |v| v.store.unread_possible else false,
        .producer = if (capture) |v| v.producer else null,
        .peak_bytes = if (capture) |v| v.budget.peak else 0,
        .config = if (capture) |v| @as(?model.Config, v.config) else null,
        .offline = if (capture) |v| v.offline else false,
        .recipe_json = if (capture) |v| v.recipe_json else null,
        .comparison_selection = if (capture) |v| v.comparison_selection else null,
        .error_name = if (live.err) |err| @errorName(err) else @as(?[]const u8, null),
        .failure = live.failure,
        .cleanup_pending = live.cleanup != null,
        .abi = "sysv_x86_64: six integer argument registers and AX return word; types, floating-point and stack arguments unknown",
        .clock = "host CLOCK_MONOTONIC; remote fixed-offset conversion carries producer uncertainty",
        .scope = "only the selected stable threads and exact ELF functions; no automatic thread enrollment",
        .stack_basis = "raw kernel callchain and optional entry stack word; PCs are not validated symbolic frames and truncated only reports the capture limit",
    });
}
fn selected(session: *Session, args: V) !*model.Capture {
    const capture = session.observations.capture orelse return error.NoObservation;
    if (try wire.number(args, "session_id", null) != capture.identity.session_id or try wire.number(args, "capture_id", null) != capture.identity.capture_id) return error.StaleObservation;
    return capture;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "save_observation")) {
        try wire.fields(args, &.{ "generation", "session_id", "capture_id", "path" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        _ = try selected(session, args);
        const path = args.object.get("path") orelse return error.InvalidArguments;
        if (path != .string) return error.InvalidArguments;
        const id = try session.saveObservation(path.string);
        session.record(.agent, "save_observation");
        return wire.value(a, .{ .id = id, .completion = "poll get_observation_archive; acceptance does not mean publication" });
    }
    if (std.mem.eql(u8, name, "get_observation_archive") or std.mem.eql(u8, name, "cancel_observation_archive")) {
        const cancel = std.mem.eql(u8, name, "cancel_observation_archive");
        try wire.fields(args, if (cancel) &.{ "id", "generation" } else &.{"id"});
        const job = session.observation_archive orelse return error.NoObservationArchive;
        if (job.id != try wire.number(args, "id", null)) return error.StaleObservationArchive;
        if (cancel) {
            try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
            if (!job.done.load(.acquire)) job.progress.cancel.store(true, .release);
            session.record(.agent, "cancel_observation_archive");
        }
        return wire.value(a, job.status());
    }
    if (std.mem.eql(u8, name, "get_observation")) {
        try wire.fields(args, &.{});
        return status(a, session);
    }
    if (std.mem.eql(u8, name, "start_observation")) {
        try wire.fields(args, &.{ "generation", "tids", "mapping_address", "functions", "duration_ms", "record_limit", "memory_limit", "callstacks" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        const list = args.object.get("tids") orelse return error.InvalidArguments;
        if (list != .array or list.array.items.len == 0 or list.array.items.len > 32) return error.InvalidArguments;
        var tids: [32]i32 = undefined;
        for (list.array.items, 0..) |value, i| {
            if (value != .integer or value.integer <= 0 or value.integer > std.math.maxInt(i32)) return error.InvalidArguments;
            tids[i] = @intCast(value.integer);
        }
        const functions = args.object.get("functions") orelse return error.InvalidArguments;
        if (functions != .array or functions.array.items.len == 0 or functions.array.items.len > 16) return error.InvalidArguments;
        var requests: [16]@import("../profile/uprobe_hooks.zig").Request = undefined;
        for (functions.array.items, 0..) |value, i| {
            if (value != .string or value.string.len == 0 or value.string.len > 256) return error.InvalidArguments;
            requests[i] = .{ .id = @intCast(i + 1), .name = value.string };
        }
        var config = model.Config{ .duration_ms = try number32(args, "duration_ms", 60000), .record_limit = try number32(args, "record_limit", 32768), .memory_limit = try number32(args, "memory_limit", 64 * 1024 * 1024) };
        if (args.object.get("callstacks")) |value| {
            if (value != .bool) return error.InvalidArguments;
            config.callstacks = value.bool;
        }
        try session.startObservation(.agent, tids[0..list.array.items.len], config, try word(args, "mapping_address"), requests[0..functions.array.items.len]);
        return status(a, session);
    }
    if (std.mem.eql(u8, name, "stop_observation")) {
        try wire.fields(args, &.{ "generation", "session_id", "capture_id" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        const identity = if (session.observations.pendingContext()) |pending| pending.identity else (try selected(session, args)).identity;
        if (try wire.number(args, "session_id", null) != identity.session_id or try wire.number(args, "capture_id", null) != identity.capture_id) return error.StaleObservation;
        session.observations.stop(.manual);
        session.record(.agent, "stop_observation");
        return status(a, session);
    }
    if (std.mem.eql(u8, name, "get_observation_calls") or std.mem.eql(u8, name, "get_observation_records")) {
        try wire.fields(args, &.{ "session_id", "capture_id", "start", "limit" });
        const capture = try selected(session, args);
        if (!capture.store.finished) return error.ObservationStillCollecting;
        const start = try wire.number(args, "start", 0);
        const limit = try wire.number(args, "limit", 32);
        const records = std.mem.eql(u8, name, "get_observation_records");
        const total = if (records) capture.store.records.items.len else capture.store.calls.items.len;
        if (start > total or limit == 0 or limit > 64) return error.InvalidArguments;
        const end = @min(total, start + limit);
        if (records) return exact(a, .{ .identity = capture.identity, .start = start, .total = total, .next = if (end < total) @as(?usize, end) else null, .records = capture.store.records.items[start..end] });
        const Row = struct { call: types.Call, start_ns: ?u64, end_ns: ?u64, duration_ns: ?u64, args: ?[]const u64, result: ?u64, stack: ?types.Stack };
        const rows = try a.alloc(Row, end - start);
        for (capture.store.calls.items[start..end], rows) |invocation, *row| {
            const entry = if (invocation.entry_record) |id| capture.store.records.items[id].event else null;
            const ret = if (invocation.return_record) |id| capture.store.records.items[id].event else null;
            row.* = .{ .call = invocation, .start_ns = if (entry) |e| e.time_ns else null, .end_ns = if (ret) |e| e.time_ns else null, .duration_ns = capture.store.duration(invocation), .args = if (entry) |e| try a.dupe(u64, e.data.sample.args[0..e.data.sample.arg_count]) else null, .result = if (ret) |e| e.data.sample.result else null, .stack = if (entry) |e| e.data.sample.stack else null };
        }
        return exact(a, .{ .identity = capture.identity, .start = start, .total = total, .next = if (end < total) @as(?usize, end) else null, .calls = rows });
    }
    if (std.mem.eql(u8, name, "compare_observation")) {
        try wire.fields(args, &.{ "session_id", "capture_id", "threshold_ns", "thread_id", "function_id", "start_ns", "end_ns", "argument_index", "argument_value", "return_value", "top_n" });
        const capture = try selected(session, args);
        if (!capture.store.finished or session.observations.busy()) return error.ObservationStillCollecting;
        if (session.observation_archive) |job| if (!job.done.load(.acquire)) return error.ObservationArchiveBusy;
        var selection = comparison.Selection{ .threshold_ns = try wire.number(args, "threshold_ns", null), .top_n = @intCast(try wire.number(args, "top_n", 8)) };
        if (selection.top_n == 0 or selection.top_n > comparison.max_top_n) return error.InvalidArguments;
        inline for (.{ "thread_id", "start_ns", "end_ns" }) |key| if (args.object.get(key) != null) {
            @field(selection, key) = try wire.number(args, key, null);
        };
        if (args.object.get("function_id") != null) selection.function_id = try number32(args, "function_id", null);
        if (args.object.get("return_value") != null) selection.return_value = try word(args, "return_value");
        if (args.object.get("argument_index") != null or args.object.get("argument_value") != null) {
            const index = try wire.number(args, "argument_index", null);
            if (index >= 6) return error.InvalidArguments;
            selection.argument = .{ .index = @intCast(index), .value = try word(args, "argument_value") };
        }
        selection.validate() catch return error.InvalidArguments;
        const id = try session.compareObservation(selection);
        return wire.value(a, .{ .id = id, .state = "running", .identity = capture.identity });
    }
    try wire.fields(args, &.{"id"});
    const job = session.observation_analysis orelse return error.NoObservationComparison;
    if (job.id != try wire.number(args, "id", null)) return error.StaleObservationComparison;
    if (std.mem.eql(u8, name, "cancel_observation_comparison")) job.cancel.store(true, .release);
    const done = job.done.load(.acquire);
    return exact(a, .{ .id = job.id, .identity = job.capture.identity, .state = if (!done) "running" else if (job.err != null) "failed" else "completed", .error_name = if (done) (if (job.err) |err| @errorName(err) else @as(?[]const u8, null)) else null, .result = if (done) job.result else null, .peak_bytes = if (done) @as(?usize, job.budget.peak) else null, .basis = "measured entry-to-return wall duration, not CPU cost; incomplete calls excluded; raw words are untyped" });
}
