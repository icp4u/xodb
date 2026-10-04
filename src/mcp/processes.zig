//! Explicit process routing; GUI selection never changes the default MCP target.
const std = @import("std");
const model = @import("../model/session.zig");
const wire = @import("profile.zig");
const Value = std.json.Value;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "get_processes", "set_process_following", "retry_process_admission", "detach_process_family" }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
pub fn call(a: std.mem.Allocator, session: *model.Session, name: []const u8, args: Value) !Value {
    const tree = session.process_tree orelse return error.NoProcessTree;
    if (std.mem.eql(u8, name, "get_processes")) {
        try wire.fields(args, &.{ "start", "limit" });
        const start = std.math.cast(usize, try wire.number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try wire.number(args, "limit", 32)) orelse return error.InvalidArguments;
        if (start > tree.count or limit == 0 or limit > 128) return error.InvalidArguments;
        const end = start + @min(limit, tree.count - start);
        var rows: std.ArrayList(Value) = .empty;
        for (tree.entries[start..end]) |entry| {
            const target = &entry.session.target;
            const Pending = struct { pid: i32, parent_tid: i32, kind: []const u8, stopped: bool, exited: bool, vm_errno: i32 };
            var pending: std.ArrayList(Pending) = .empty;
            // A response is bounded even when all processes have pending births.
            for (target.births[0..@min(target.birth_count, 8)]) |birth|
                try pending.append(a, .{ .pid = birth.pid, .parent_tid = birth.parent_tid, .kind = @tagName(birth.kind), .stopped = birth.stopped, .exited = birth.exited, .vm_errno = birth.vm_errno });
            try rows.append(a, try wire.value(a, .{
                .process_id = entry.id,
                .parent_process_id = entry.parent,
                .session_id = entry.session.id,
                .pid = target.pid,
                .state = @tagName(target.state),
                .generation = target.generation,
                .image_epoch = target.image_epoch,
                .kind = if (entry.kind) |kind| @tagName(kind) else "root",
                .following = target.follow_processes,
                .shared_vm = target.sharedVm(),
                .detach_pending = target.detach_pending,
                .pending_count = target.birth_count,
                .pending = pending.items,
                .pending_truncated = target.birth_count > pending.items.len,
                .admission_error = entry.admission_error,
                .diagnostic = entry.session.step_diagnostic,
            }));
        }
        return wire.value(a, .{ .revision = tree.revision, .default_process_id = 1, .gui_process_id = tree.active().process_id, .process_limit = tree.limit, .total = tree.count, .processes = rows.items, .next = if (end < tree.count) @as(?usize, end) else null });
    }
    if (session.offline or session.imported != null) return error.OfflineSession;
    const following = std.mem.eql(u8, name, "set_process_following");
    try wire.fields(args, if (following) &.{ "generation", "enabled", "process_limit" } else &.{"generation"});
    try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
    if (following) {
        const enabled = args.object.get("enabled") orelse return error.InvalidArguments;
        if (enabled != .bool) return error.InvalidArguments;
        const limit = if (args.object.contains("process_limit")) try wire.number(args, "process_limit", null) else null;
        if (limit) |n| if (n > @import("../model/process_tree.zig").maximum) return error.InvalidProcessLimit;
        try tree.setFollowing(session, enabled.bool, if (limit) |n| @as(usize, @intCast(n)) else null, .agent);
    } else if (std.mem.eql(u8, name, "detach_process_family")) {
        try tree.detachFamily(session, .agent);
    } else {
        tree.retryAdmissions();
        session.target.generation += 1;
        session.record(.agent, "retry_process_admission");
    }
    return wire.value(a, session.snapshot());
}
