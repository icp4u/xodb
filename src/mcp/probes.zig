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
    return std.mem.eql(u8, name, "get_breakpoint_logs");
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value) !Value {
    if (args != .object or !handles(name)) return error.InvalidArguments;
    try @import("profile.zig").fields(args, &.{ "after", "limit" });
    const after = if (member(args, "after")) |v| try number(v) else 0;
    const limit = if (member(args, "limit")) |v| try number(v) else 32;
    if (limit == 0 or limit > 64) return error.InvalidArguments;
    const logs = session.probes.logs[0..session.probes.log_count];
    var start: usize = 0;
    while (start < logs.len and logs[start].sequence <= after) : (start += 1) {}
    const end = @min(logs.len, start + @as(usize, @intCast(limit)));
    return asValue(a, .{ .records = logs[start..end], .has_more = end < logs.len, .oldest_available = if (logs.len > 0) logs[0].sequence else 0, .dropped = session.probes.dropped_logs, .last_sequence = session.probes.log_sequence });
}
