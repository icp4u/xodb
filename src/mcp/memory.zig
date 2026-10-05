const std = @import("std");
const Session = @import("../model/session.zig").Session;
const memory = @import("../model/memory.zig");
const wire = @import("profile.zig");
const V = std.json.Value;
fn text(args: V, key: []const u8) ![]const u8 {
    const v = args.object.get(key) orelse return error.InvalidArguments;
    return if (v == .string) v.string else error.InvalidArguments;
}
fn address(args: V) !u64 {
    return std.fmt.parseInt(u64, try text(args, "address"), 0) catch error.InvalidArguments;
}
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "capture_memory", "read_memory_snapshot", "search_memory", "get_memory_search", "cancel_memory_search" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "capture_memory") or std.mem.eql(u8, name, "search_memory")) {
        if (session.offline) return error.OfflineSession;
        const search = std.mem.eql(u8, name, "search_memory");
        try wire.fields(args, if (search) &.{ "address", "length", "pattern", "encoding", "generation" } else &.{ "address", "length", "generation" });
        const generation = try wire.number(args, "generation", null);
        try session.target.expectGeneration(generation);
        const length = try wire.number(args, "length", null);
        if (length > memory.max_search) return error.InvalidArguments;
        if (!search) {
            const id = try session.memory.capture(session, try address(args), @intCast(length));
            const snapshot = try session.memory.find(id);
            return wire.value(a, .{ .id = id, .generation = snapshot.generation, .image_epoch = snapshot.image_epoch, .address = try std.fmt.allocPrint(a, "0x{x}", .{snapshot.address}), .length = snapshot.bytes.len, .readable = snapshot.readable });
        }
        const pattern = try text(args, "pattern");
        const encoding = if (args.object.get("encoding") != null) try text(args, "encoding") else "hex";
        var bytes: [256]u8 = undefined;
        const data = if (std.mem.eql(u8, encoding, "hex")) blk: {
            if (pattern.len == 0 or pattern.len > 512 or pattern.len % 2 != 0) return error.InvalidArguments;
            for (0..pattern.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, pattern[2 * i ..][0..2], 16) catch return error.InvalidArguments;
            break :blk bytes[0 .. pattern.len / 2];
        } else if (std.mem.eql(u8, encoding, "utf8")) pattern else return error.InvalidArguments;
        const id = try session.memory.startSearch(session, try address(args), @intCast(length), data);
        return wire.value(a, .{ .id = id, .state = "running" });
    }
    if (std.mem.eql(u8, name, "read_memory_snapshot")) {
        try wire.fields(args, &.{ "id", "baseline", "start", "limit" });
        const snapshot = try session.memory.find(try wire.number(args, "id", null));
        const baseline = if (args.object.get("baseline") != null) try session.memory.find(try wire.number(args, "baseline", null)) else null;
        const start = try wire.number(args, "start", 0);
        const limit = try wire.number(args, "limit", 256);
        if (limit == 0 or limit > 4096 or start > snapshot.bytes.len) return error.InvalidArguments;
        const end = @min(snapshot.bytes.len, start + limit);
        const hex = try a.alloc(u8, (end - start) * 2);
        const changes = try a.alloc(memory.Memory.Comparison, end - start);
        const digits = "0123456789abcdef";
        for (start..end, 0..) |offset, i| {
            hex[2 * i] = if (snapshot.valid[offset]) digits[snapshot.bytes[offset] >> 4] else '?';
            hex[2 * i + 1] = if (snapshot.valid[offset]) digits[snapshot.bytes[offset] & 15] else '?';
            changes[i] = if (baseline) |old| memory.Memory.compare(snapshot, old, offset) else .outside_baseline;
        }
        return wire.value(a, .{ .id = snapshot.id, .generation = snapshot.generation, .image_epoch = snapshot.image_epoch, .address = try std.fmt.allocPrint(a, "0x{x}", .{snapshot.address + start}), .length = snapshot.bytes.len, .start = start, .next = if (end < snapshot.bytes.len) @as(?usize, end) else null, .hex = hex, .valid = snapshot.valid[start..end], .comparison = changes });
    }
    const cancel = std.mem.eql(u8, name, "cancel_memory_search");
    try wire.fields(args, if (cancel) &.{"id"} else &.{ "id", "start", "limit" });
    const id = try wire.number(args, "id", null);
    const search = if (session.memory.search) |*v| v else return error.NoMemorySearch;
    if (search.id != id) return error.StaleMemorySearch;
    if (cancel and search.state == .running) search.state = .cancelled;
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    if (start > search.count or limit == 0 or limit > 128) return error.InvalidArguments;
    const end = @min(search.count, start + limit);
    const hits = try a.alloc([]const u8, end - start);
    for (search.hits[start..end], hits) |hit, *result| result.* = try std.fmt.allocPrint(a, "0x{x}", .{hit});
    return wire.value(a, .{ .id = search.id, .state = search.state, .generation = search.generation, .image_epoch = search.image_epoch, .scanned = search.scanned, .length = search.length, .unreadable = search.unreadable, .total_hits = search.count, .start = start, .next = if (end < search.count) @as(?usize, end) else null, .hits = hits });
}
