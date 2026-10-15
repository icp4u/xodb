//! Capture requests use trusted transport identity and a separate consent state.
const std = @import("std");
const model = @import("../model/system_capture_state.zig");
const Collector = @import("../model/system.zig").Collector;
const wire = @import("profile.zig");
const Value = std.json.Value;
pub fn handles(name: []const u8) bool {
    inline for (.{ "request_system_capture", "cancel_system_capture", "get_system_capture", "get_system_capture_result" }) |tool| if (std.mem.eql(u8, name, tool)) return true;
    return false;
}
fn status(a: std.mem.Allocator, collector: *const Collector) !Value {
    const state = &collector.capture;
    return wire.value(a, .{ .mode = state.mode, .request = state.current, .cleanup_pending = state.backend_busy and state.current != null and !state.current.?.active(), .result_id = state.result_id, .result_kind = state.result_kind, .audit = state.audit[0..state.audit_count], .limits = .{ .duration_ms = 10_000, .cpu_frequency_hz = 99, .cpu_samples = 16384, .perf_ring_bytes = 64 * 1024 * 1024, .request_interval_ms = 1000, .approval_timeout_ms = 30_000, .retained_results = 1 }, .cost = "CPU: brief attach stop, user CPU sampling; symbols/images cost additional memory. FD flow: exact native syscall tracing, about 11% host syscall overhead; bounded drain/rings may lose events, not an event-rate cap. Ctrl+Esc in the overview revokes capture.", .fd_scope = if (collector.fd_scope.len == 0) "system-wide, enrolled CPUs" else "explicit process scope", .shutdown = "owner stops on deadline, cancellation, disconnect or shutdown; background fd stop completes after its current bounded drain" });
}
pub fn call(a: std.mem.Allocator, collector: *Collector, cpu_slot: anytype, scope: @import("../model/command.zig").AgentScope, caller: model.Caller, name: []const u8, args: Value, now: u64) !Value {
    const result = try dispatch(a, collector, cpu_slot, scope, caller, name, args, now);
    const redact = @import("../redact.zig");
    // CLI redaction is initialized before workers start and handled by Server.
    // A later GUI X toggle uses an owner-local policy, not a racy global write.
    if (collector.redact and redact.active() == null) {
        if (collector.capture_redaction == null) collector.capture_redaction = redact.Policy.fromMachine(redact.randomKey());
        const bytes = try std.json.Stringify.valueAlloc(a, result, .{});
        const scrubbed = try collector.capture_redaction.?.scrubJson(a, bytes, "id");
        return (try std.json.parseFromSlice(Value, a, scrubbed, .{})).value;
    }
    return result;
}
fn dispatch(a: std.mem.Allocator, collector: *Collector, cpu_slot: anytype, scope: @import("../model/command.zig").AgentScope, caller: model.Caller, name: []const u8, args: Value, now: u64) !Value {
    if (std.mem.eql(u8, name, "request_system_capture")) {
        try wire.fields(args, &.{ "kind", "pid", "start_ticks", "duration_ms", "frequency_hz", "interval_ms" });
        const kind = args.object.get("kind") orelse return error.InvalidArguments;
        if (kind != .string) return error.InvalidArguments;
        const parsed = std.meta.stringToEnum(model.Kind, kind.string) orelse return error.InvalidArguments;
        const pid = try wire.number(args, "pid", 0);
        const duration = try wire.number(args, "duration_ms", 1000);
        const hz = try wire.number(args, "frequency_hz", 99);
        const interval = try wire.number(args, "interval_ms", 1000);
        if (pid > std.math.maxInt(i32) or duration > 10_000 or hz > 99 or interval > 1000) return error.InvalidArguments;
        if (parsed == .cpu and args.object.get("interval_ms") != null) return error.InvalidArguments;
        if (parsed == .fd_flow and args.object.get("frequency_hz") != null) return error.InvalidArguments;
        _ = try collector.capture.submit(caller, scope, .{ .kind = parsed, .pid = @intCast(pid), .start_ticks = try wire.number(args, "start_ticks", 0), .duration_ms = @intCast(duration), .frequency_hz = @intCast(hz), .interval_ms = @intCast(interval) }, now);
    } else if (std.mem.eql(u8, name, "cancel_system_capture")) {
        try wire.fields(args, &.{"request_id"});
        try collector.capture.cancel(caller, try wire.number(args, "request_id", null), now);
    } else if (std.mem.eql(u8, name, "get_system_capture_result")) {
        try wire.fields(args, &.{ "request_id", "view", "start", "limit", "capture_id", "revision", "sample" });
        const id = try wire.number(args, "request_id", null);
        try collector.capture.readable(caller, id);
        var local: Value = .{ .object = .empty };
        var fields = args.object.iterator();
        while (fields.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "request_id") and !std.mem.eql(u8, field.key_ptr.*, "view")) try local.object.put(a, field.key_ptr.*, field.value_ptr.*);
        if (collector.capture.result_kind == .cpu) {
            const session = (cpu_slot orelse return error.CaptureResultUnavailable).* orelse return error.CaptureResultUnavailable;
            const view = args.object.get("view") orelse Value{ .string = "summary" };
            if (view != .string) return error.InvalidArguments;
            const tool: []const u8 = if (std.mem.eql(u8, view.string, "summary")) "get_profile" else if (std.mem.eql(u8, view.string, "samples")) "get_profile_samples" else if (std.mem.eql(u8, view.string, "stack")) "get_profile_stack" else return error.InvalidArguments;
            if (std.mem.eql(u8, view.string, "stack")) try local.object.put(a, "reconstruct", .{ .bool = false });
            return wire.call(a, session, tool, local);
        }
        try wire.fields(args, &.{ "request_id", "start", "limit" });
        const flow = collector.capture_flow orelse return error.CaptureResultPending;
        const start = try wire.number(args, "start", 0);
        const limit = try wire.number(args, "limit", 64);
        if (limit == 0 or limit > 128 or start > flow.counts.row_count) return error.InvalidArguments;
        const end = @min(flow.counts.row_count, start + limit);
        var failure_line: [320]u8 = undefined;
        return wire.value(a, .{ .request_id = id, .kind = "fd_flow", .rows = flow.counts.rows[start..end], .total = flow.counts.row_count, .next = if (end < flow.counts.row_count) @as(?u64, end) else null, .read_bytes = flow.counts.read_bytes, .write_bytes = flow.counts.write_bytes, .unknown_read = flow.counts.unknown_read, .unknown_write = flow.counts.unknown_write, .failed_calls = flow.counts.failed_calls, .lost = flow.stream.lost, .flags = flow.stream.flags, .counter_flags = flow.counts.flags, .enrolled_cpus = flow.stream.active_cpus, .online_cpus = flow.stream.online_cpus, .status = flow.status, .failure = @import("../model/system.zig").failureText(&failure_line, flow.failure), .identity = "sampled inode joins, not proof of the kernel file used by a racing syscall; rows are bounded and may be incomplete" });
    } else if (std.mem.eql(u8, name, "get_system_capture")) {
        try wire.fields(args, &.{});
    } else return error.UnknownTool;
    return status(a, collector);
}
