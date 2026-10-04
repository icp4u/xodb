const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Value = std.json.Value;
fn member(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn number(v: ?Value) !u64 {
    const n = v orelse return error.InvalidArguments;
    return if (n == .integer and n.integer >= 0) @intCast(n.integer) else error.InvalidArguments;
}
fn text(v: ?Value) ![]const u8 {
    const s = v orelse return "";
    return if (s == .string) s.string else error.InvalidArguments;
}
fn asValue(a: std.mem.Allocator, v: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{ .allocate = .alloc_always })).value;
}
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "restart") or std.mem.eql(u8, name, "configure_breakpoint") or std.mem.eql(u8, name, "get_breakpoint_logs") or std.mem.eql(u8, name, "finish") or std.mem.eql(u8, name, "run_to");
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value) !Value {
    if (args != .object) return error.InvalidArguments;
    if (std.mem.eql(u8, name, "restart")) {
        try @import("profile.zig").fields(args, &.{"generation"});
        try session.authorize(.agent, .execution, try number(member(args, "generation")));
        try session.restart();
        session.record(.agent, "restart");
        return asValue(a, session.snapshot());
    }
    if (std.mem.eql(u8, name, "finish") or std.mem.eql(u8, name, "run_to")) {
        if (session.offline) return error.OfflineSession;
        const finish = std.mem.eql(u8, name, "finish");
        var iter = args.object.iterator();
        const keys: []const []const u8 = if (finish) &.{ "tid", "frame", "generation" } else &.{ "tid", "address", "file", "line", "generation" };
        while (iter.next()) |f| {
            for (keys) |key| {
                if (std.mem.eql(u8, key, f.key_ptr.*)) break;
            } else return error.InvalidArguments;
        }
        try session.authorize(.agent, .execution, try number(member(args, "generation")));
        const tid = try number(member(args, "tid"));
        if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
        if (finish) {
            const frame = if (member(args, "frame")) |v| try number(v) else 0;
            if (frame >= 63) return error.InvalidArguments;
            try session.finishFrame(@intCast(tid), @intCast(frame), .agent);
        } else {
            var address: u64 = undefined;
            if (member(args, "file")) |file| {
                if (member(args, "address") != null) return error.InvalidArguments;
                const line = try number(member(args, "line"));
                if (line == 0 or line > std.math.maxInt(u32)) return error.InvalidArguments;
                const addresses = try session.sourceAddresses(a, try text(file), @intCast(line));
                if (addresses.len == 0) return error.NoSourceAddress;
                address = addresses[0];
            } else {
                if (member(args, "line") != null) return error.InvalidArguments;
                address = std.fmt.parseInt(u64, try text(member(args, "address")), 0) catch return error.InvalidArguments;
            }
            try session.runTo(@intCast(tid), address, null, .agent);
        }
        session.record(.agent, if (finish) "finish" else "run_to");
        return asValue(a, session.snapshot());
    }
    const configure = std.mem.eql(u8, name, "configure_breakpoint");
    var fields = args.object.iterator();
    const allowed: []const []const u8 = if (configure) &.{ "generation", "id", "enabled", "condition", "log_expression", "tid", "ignore_count", "mode" } else &.{ "after", "limit" };
    while (fields.next()) |f| {
        for (allowed) |key| {
            if (std.mem.eql(u8, key, f.key_ptr.*)) break;
        } else return error.InvalidArguments;
    }
    if (!configure) {
        const after = if (member(args, "after")) |v| try number(v) else 0;
        const limit = if (member(args, "limit")) |v| try number(v) else 32;
        if (limit == 0 or limit > 64) return error.InvalidArguments;
        const logs = session.probes.logs[0..session.probes.log_count];
        var start: usize = 0;
        while (start < logs.len and logs[start].sequence <= after) : (start += 1) {}
        const end = @min(logs.len, start + @as(usize, @intCast(limit)));
        return asValue(a, .{ .records = logs[start..end], .has_more = end < logs.len, .oldest_available = if (logs.len > 0) logs[0].sequence else 0, .dropped = session.probes.dropped_logs, .last_sequence = session.probes.log_sequence });
    }
    if (session.offline) return error.OfflineSession;
    try session.authorize(.agent, .execution, try number(member(args, "generation")));
    const id = try number(member(args, "id"));
    if (@import("../model/persistent.zig").Manager.probe(session, id)) |probe| if (probe.internal) return error.InternalBreakpoint;
    var options: @import("../model/probes.zig").Options = .{ .condition = try text(member(args, "condition")), .log_expression = try text(member(args, "log_expression")), .ignore_count = if (member(args, "ignore_count")) |v| try number(v) else 0 };
    if (member(args, "mode")) |v| options.mode = std.meta.stringToEnum(@FieldType(@TypeOf(options), "mode"), try text(v)) orelse return error.InvalidArguments;
    if (member(args, "tid")) |v| {
        const tid = try number(v);
        for (session.target.threadSlice()) |thread| {
            if (thread.tid == tid and thread.state != .exited) {
                options.thread_id = thread.id;
                break;
            }
        } else return error.UnknownThread;
    }
    const enabled = if (member(args, "enabled")) |v| if (v == .bool) v.bool else return error.InvalidArguments else true;
    try session.probes.configure(&session.target, id, options, enabled);
    session.record(.agent, "configure_breakpoint");
    return asValue(a, .{ .id = id, .policy = session.probes.rule(id).?.*, .session = session.snapshot() });
}
