//! Live controls and preparation status; read pages share the evidence adapter.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const wire = @import("profile.zig");
const evidence = @import("allocations.zig");
const hooks = @import("../profile/allocation_hooks.zig");
const V = std.json.Value;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "start_allocations", "stop_allocations", "get_allocation_capture", "get_allocation_events", "get_allocation_calls", "get_allocation_lifetimes", "get_allocation_stack", "get_allocation_flamegraph" }) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}
fn number32(args: V, key: []const u8, default: u32) !u32 {
    const n = try wire.number(args, key, default);
    return std.math.cast(u32, n) orelse error.InvalidArguments;
}
pub fn status(a: std.mem.Allocator, session: *Session) !V {
    const live = &session.allocations;
    var result = if (live.capture) |capture| try evidence.status(a, capture) else try wire.value(a, .{ .key = @as(?u8, null), .state = "empty" });
    const pending = live.pendingContext();
    try result.object.put(a, "preparing", .{ .bool = live.preparing() });
    try result.object.put(a, "collecting", .{ .bool = live.collecting() });
    try result.object.put(a, "preparation_id", try wire.value(a, if (pending) |p| p.identity.capture_id else @as(?u64, null)));
    try result.object.put(a, "session_id", try wire.value(a, session.id));
    try result.object.put(a, "error", try wire.value(a, if (live.err) |err| @errorName(err) else @as(?[]const u8, null)));
    try result.object.put(a, "failure", try wire.value(a, live.failure));
    try result.object.put(a, "stop_reason", try wire.value(a, live.reason));
    try result.object.put(a, "defaults", try wire.value(a, session.allocation_defaults));
    try result.object.put(a, "helper_enabled", .{ .bool = session.allocation_helper != null });
    return result;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "get_allocation_capture")) {
        try wire.fields(args, &.{});
        return status(a, session);
    }
    if (std.mem.eql(u8, name, "start_allocations")) {
        try wire.fields(args, &.{ "generation", "tids", "mapping_address", "hooks", "duration_ms", "record_limit", "memory_limit", "callstacks" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        const list = args.object.get("tids") orelse return error.InvalidArguments;
        if (list != .array or list.array.items.len == 0 or list.array.items.len > 32) return error.InvalidAllocationThreads;
        var tids: [32]i32 = undefined;
        for (list.array.items, 0..) |item, i| {
            if (item != .integer or item.integer <= 0 or item.integer > std.math.maxInt(i32)) return error.InvalidAllocationThreads;
            tids[i] = @intCast(item.integer);
        }
        var mapping: ?u64 = null;
        if (args.object.get("mapping_address")) |address| {
            if (address != .string) return error.InvalidArguments;
            mapping = std.fmt.parseInt(u64, address.string, 0) catch return error.InvalidArguments;
        }
        var custom: [hooks.max_hooks]hooks.Request = undefined;
        var requests: []const hooks.Request = &Session.allocation_hooks;
        if (args.object.get("hooks")) |items| {
            if (items != .array or items.array.items.len == 0 or items.array.items.len > custom.len) return error.InvalidAllocationHooks;
            for (items.array.items, 0..) |item, i| {
                try wire.fields(item, &.{ "name", "kind" });
                const symbol = item.object.get("name") orelse return error.InvalidArguments;
                const kind = item.object.get("kind") orelse return error.InvalidArguments;
                if (symbol != .string or kind != .string or symbol.string.len == 0 or symbol.string.len > 256) return error.InvalidArguments;
                custom[i] = .{ .id = @intCast(i + 1), .kind = std.meta.stringToEnum(@import("../profile/allocation_lifetimes.zig").Kind, kind.string) orelse return error.InvalidArguments, .name = symbol.string };
            }
            requests = custom[0..items.array.items.len];
        }
        var callstacks = session.allocation_defaults.callstacks;
        if (args.object.get("callstacks")) |value| {
            if (value != .bool) return error.InvalidArguments;
            callstacks = value.bool;
        }
        try session.startAllocations(.agent, tids[0..list.array.items.len], .{
            .callstacks = callstacks,
            .duration_ms = try number32(args, "duration_ms", session.allocation_defaults.duration_ms),
            .record_limit = try number32(args, "record_limit", session.allocation_defaults.record_limit),
            .memory_limit = try number32(args, "memory_limit", session.allocation_defaults.memory_limit),
        }, mapping, requests);
        return status(a, session);
    }
    if (std.mem.eql(u8, name, "stop_allocations")) {
        try wire.fields(args, &.{ "generation", "session_id", "capture_id" });
        try session.authorize(.agent, .execution, try wire.number(args, "generation", null));
        if (try wire.number(args, "session_id", null) != session.id) return error.StaleAllocationCapture;
        const current = if (session.allocations.pendingContext()) |pending| pending.identity.capture_id else if (session.allocations.capture) |capture| capture.identity.capture_id else return error.NoAllocationCapture;
        if (try wire.number(args, "capture_id", null) != current) return error.StaleAllocationCapture;
        session.allocations.stop(.manual);
        session.record(.agent, "stop_allocations");
        return status(a, session);
    }
    return evidence.call(a, session.allocations.capture, name, args);
}
test "allocation control preserves observation scope and rejects malformed starts" {
    var session = Session.init();
    defer session.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = (try std.json.parseFromSlice(V, a, "{\"generation\":0,\"tids\":[1]}", .{})).value;
    try std.testing.expectError(error.AgentScopeDenied, call(a, &session, "start_allocations", args));
    const snapshot = try status(a, &session);
    try std.testing.expectEqual(V.null, snapshot.object.get("key").?);
    try std.testing.expect(!snapshot.object.get("preparing").?.bool);
}
