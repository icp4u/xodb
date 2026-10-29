//! Bounded observer view of the shared, demand-driven task census.
const std = @import("std");
const census = @import("../model/kernel_census.zig");
const wire = @import("profile.zig");
const redact = @import("../redact.zig");
const Value = std.json.Value;

pub fn call(a: std.mem.Allocator, cache: *census.Cache, args: Value, hidden: bool) !Value {
    try wire.fields(args, &.{ "start", "limit", "group", "member_start", "member_limit", "refresh", "sequence", "user_tid" });
    if (args.object.contains("user_tid")) {
        const tid = try wire.number(args, "user_tid", null);
        if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
    }
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 16);
    const member_start = try wire.number(args, "member_start", 0);
    const member_limit = try wire.number(args, "member_limit", 64);
    if (limit == 0 or limit > 32 or member_limit == 0 or member_limit > 128) return error.InvalidArguments;
    const refresh = args.object.get("refresh") orelse Value{ .bool = true };
    if (refresh != .bool) return error.InvalidArguments;
    _ = cache.poll();
    if (refresh.bool) try cache.request();
    if (args.object.contains("sequence") and try wire.number(args, "sequence", null) != cache.sequence) return error.StaleCensus;
    const snapshot = if (cache.current) |*s| s else return wire.value(a, .{
        .status = if (cache.failure != null) "unavailable" else "pending",
        .failure = cache.failure,
        .sequence = cache.sequence,
        .pending = cache.job != null,
        .scope_pid = cache.pid,
    });
    if (start > snapshot.groups.items.len) return error.InvalidArguments;
    var groups: std.ArrayList(Value) = .empty;
    const end = start + @min(limit, snapshot.groups.items.len - start);
    for (snapshot.groups.items[start..end]) |g| try groups.append(a, try wire.value(a, .{
        .id = g.id,
        .status = @tagName(g.status),
        .count = g.count,
        .d_count = g.d_count,
        .stack = try clean(a, g.stack, false),
    }));
    var members: std.ArrayList(Value) = .empty;
    var matched: usize = 0;
    if (args.object.contains("group")) {
        const group = try wire.number(args, "group", null);
        if (group >= snapshot.groups.items.len) return error.InvalidArguments;
        for (snapshot.tasks.items) |task| {
            if (task.group != group) continue;
            defer matched += 1;
            if (matched < member_start or members.items.len == member_limit) continue;
            try members.append(a, try wire.value(a, .{
                .pid = task.pid,
                .tid = task.tid,
                .start_ticks = task.start_ticks,
                .state = @as([]const u8, &.{task.state}),
                .comm = try clean(a, task.comm, hidden),
                .wchan = try clean(a, task.wchan, false),
            }));
        }
        if (member_start > matched) return error.InvalidArguments;
    }
    return wire.value(a, .{
        .status = if (snapshot.failure != null) "partial" else "ready",
        .sequence = cache.sequence,
        .pending = cache.job != null,
        .scope_pid = cache.pid,
        .started_monotonic_ns = snapshot.started_ns,
        .finished_monotonic_ns = snapshot.finished_ns,
        .age_ms = (census.now() -| snapshot.finished_ns) / std.time.ns_per_ms,
        .atomic_snapshot = false,
        .truncated = snapshot.truncated,
        .failure = snapshot.failure,
        .task_count = snapshot.tasks.items.len,
        .group_count = snapshot.groups.items.len,
        .denied = snapshot.denied,
        .vanished = snapshot.vanished,
        .unreadable = snapshot.unreadable,
        .groups = groups.items,
        .next = if (end < snapshot.groups.items.len) @as(?usize, end) else null,
        .members = members.items,
        .member_count = matched,
        .member_next = if (member_start + members.items.len < matched) @as(?usize, member_start + members.items.len) else null,
        .user_stack = "Use get_stack for an already stopped debugger thread; census never attaches or stops tasks",
        .limits = .{ .tasks = census.max_tasks, .text_bytes = census.max_text, .stack_bytes = 8192, .scan_ms = 5000 },
    });
}

/// Kernel symbols and wait channels are not private; they still pass through
/// the session policy. Task names follow the overview's comm redaction.
fn clean(a: std.mem.Allocator, text: []const u8, hidden: bool) ![]const u8 {
    if (hidden) return "<redacted>";
    if (redact.active()) |policy| return policy.scrubAlloc(a, text);
    return text;
}

/// A local debugger can add an already stopped thread's user frames alongside
/// the census. Never attach or confuse a remote/core PID with a host task.
pub fn withUserStack(a: std.mem.Allocator, result: *Value, cache: *census.Cache, session: anytype, args: Value) !void {
    if (!args.object.contains("user_tid")) return;
    const tid: i32 = @intCast(try wire.number(args, "user_tid", null));
    var reason: []const u8 = "ThreadNotInLocalDebugger";
    var frames: Value = .null;
    if (!session.offline and session.imported == null and session.target.core == null and !session.target.isRemote()) {
        if (cache.current) |*s| for (s.tasks.items) |task| {
            if (task.tid != tid or task.pid != session.target.snapshot().pid) continue;
            if (!census.identityMatches(task)) {
                reason = "TaskIdentityChanged";
                break;
            }
            for (session.target.threadSlice()) |thread| {
                if (thread.tid != tid) continue;
                if (thread.state != .stopped) {
                    reason = "ThreadNotStopped";
                    break;
                }
                const stack = session.stack(a, tid, 64) catch |err| {
                    reason = @errorName(err);
                    break;
                };
                frames = try wire.value(a, stack);
                reason = "ready";
                break;
            }
            break;
        };
    }
    try result.object.put(a, "user_stack", try wire.value(a, .{
        .tid = tid,
        .status = reason,
        .frames = frames,
        .generation = session.target.snapshot().generation,
        .simultaneous_with_census = false,
    }));
}
