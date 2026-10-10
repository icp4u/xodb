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
fn order(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "capture_memory", "read_memory_snapshot", "search_memory", "get_memory_search", "cancel_memory_search" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
/// One range, or up to max_ranges ranges captured during the same stop.
pub const max_ranges = 16;
/// Half the retained budget, so one call never has to evict its own ranges
/// while a pinned observation (at most max_snapshot) is retained.
pub const max_ranges_bytes = 32 * 1024 * 1024;
fn capture(a: std.mem.Allocator, session: *Session, args: V) !V {
    const Range = struct { address: u64, length: usize };
    var ranges: [max_ranges]Range = undefined;
    var count: usize = 0;
    const list = args.object.get("ranges");
    if (list) |v| {
        if (args.object.get("address") != null or args.object.get("length") != null) return error.InvalidArguments;
        if (v != .array or v.array.items.len == 0 or v.array.items.len > max_ranges) return error.InvalidArguments;
        var total: u64 = 0;
        for (v.array.items) |item| {
            try wire.fields(item, &.{ "address", "length" });
            const length = try wire.number(item, "length", null);
            if (length == 0 or length > memory.max_snapshot) return error.InvalidArguments;
            total += length;
            ranges[count] = .{ .address = try address(item), .length = @intCast(length) };
            count += 1;
        }
        if (total > max_ranges_bytes) return error.InvalidArguments;
    } else {
        const length = try wire.number(args, "length", null);
        if (length > memory.max_snapshot) return error.InvalidArguments;
        ranges[0] = .{ .address = try address(args), .length = @intCast(length) };
        count = 1;
    }
    const Captured = struct { id: u64, generation: u64, image_epoch: u64, address: []const u8, length: usize, readable: usize };
    var out: [max_ranges]Captured = undefined;
    for (ranges[0..count], out[0..count]) |range, *result| {
        const id = try session.memory.captureOwned(session, range.address, range.length, session.jobRequester());
        const snapshot = try session.memory.find(id);
        result.* = .{ .id = id, .generation = snapshot.generation, .image_epoch = snapshot.image_epoch, .address = try std.fmt.allocPrint(a, "0x{x}", .{snapshot.address}), .length = snapshot.bytes.len, .readable = snapshot.readable };
    }
    // Other clients' retained captures can leave only this call's own ranges
    // to evict; report that rather than returning an expired ID.
    for (out[0..count]) |result| _ = session.memory.find(result.id) catch return error.MemoryBudgetExceeded;
    return if (list == null) wire.value(a, out[0]) else wire.value(a, .{ .snapshots = out[0..count] });
}
/// Explicit search ranges; a request line is at most 64 KiB, which holds
/// about 1,300 ranges, so 1,024 leaves room. Region selectors go to 4,096.
pub const max_search_ranges = 1024;
pub const range_keys = [_][]const u8{ "address", "length", "ranges", "regions", "include_shared" };
/// The ranges one search covers: address/length, explicit `ranges`, or a
/// `regions` selector built from this stop's map (optionally clipped to an
/// address/length window). Shared by search_memory and runtime-instance search.
pub fn searchRanges(a: std.mem.Allocator, session: *Session, args: V) ![]const memory.Range {
    const has_window = args.object.get("address") != null or args.object.get("length") != null;
    if (args.object.get("ranges")) |v| {
        if (has_window or args.object.get("regions") != null or args.object.get("include_shared") != null) return error.InvalidArguments;
        if (v != .array or v.array.items.len == 0 or v.array.items.len > max_search_ranges) return error.InvalidArguments;
        const out = try a.alloc(memory.Range, v.array.items.len);
        for (v.array.items, out) |item, *r| {
            try wire.fields(item, &.{ "address", "length" });
            const length = try wire.number(item, "length", null);
            if (length == 0 or length > memory.max_search_total) return error.InvalidArguments;
            r.* = .{ .address = try address(item), .length = length };
        }
        return out;
    }
    if (args.object.get("regions")) |v| {
        if (v != .string) return error.InvalidArguments;
        const selector = std.meta.stringToEnum(memory.Selector, v.string) orelse return error.InvalidArguments;
        const shared = if (args.object.get("include_shared")) |b| (if (b == .bool) b.bool else return error.InvalidArguments) else false;
        var start: u64 = 0;
        var end: u64 = std.math.maxInt(u64);
        if (has_window) {
            start = try address(args);
            const length = try wire.number(args, "length", null);
            if (length == 0 or start > std.math.maxInt(u64) - length) return error.InvalidArguments;
            end = start + length;
        }
        try session.refreshMaps();
        return memory.regionRanges(a, session.modules.regions.items, selector, shared, start, end);
    }
    if (args.object.get("include_shared") != null) return error.InvalidArguments;
    const length = try wire.number(args, "length", null);
    if (length == 0 or length > memory.max_search) return error.InvalidArguments;
    const out = try a.alloc(memory.Range, 1);
    out[0] = .{ .address = try address(args), .length = length };
    return out;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "capture_memory") or std.mem.eql(u8, name, "search_memory")) {
        if (session.offline) return error.OfflineSession;
        const search = std.mem.eql(u8, name, "search_memory");
        try wire.fields(args, if (search) &(range_keys ++ .{ "pattern", "encoding", "generation" }) else &.{ "address", "length", "ranges", "generation" });
        const generation = try wire.number(args, "generation", null);
        try session.target.expectGeneration(generation);
        if (!search) return capture(a, session, args);
        const ranges = try searchRanges(a, session, args);
        const pattern = try text(args, "pattern");
        const encoding = if (args.object.get("encoding") != null) try text(args, "encoding") else "hex";
        var bytes: [256]u8 = undefined;
        const data = if (std.mem.eql(u8, encoding, "hex")) blk: {
            if (pattern.len == 0 or pattern.len > 512 or pattern.len % 2 != 0) return error.InvalidArguments;
            for (0..pattern.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, pattern[2 * i ..][0..2], 16) catch return error.InvalidArguments;
            break :blk bytes[0 .. pattern.len / 2];
        } else if (std.mem.eql(u8, encoding, "utf8")) pattern else return error.InvalidArguments;
        const id = try session.memory.startSearchRanges(session, ranges, data, session.jobRequester());
        return wire.value(a, .{ .id = id, .state = "running", .range_count = ranges.len, .length = session.memory.search.?.length });
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
    try wire.fields(args, if (cancel) &.{"id"} else &.{ "id", "start", "limit", "range_start", "range_limit" });
    const id = try wire.number(args, "id", null);
    const search = if (session.memory.search) |*v| v else return error.NoMemorySearch;
    if (search.id != id) return error.StaleMemorySearch;
    if (cancel) try session.memory.cancelSearch(id, session.jobRequester());
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    if (start > search.count or limit == 0 or limit > 128) return error.InvalidArguments;
    const end = @min(search.count, start + limit);
    const hits = try a.alloc([]const u8, end - start);
    for (search.hits[start..end], hits) |hit, *result| result.* = try std.fmt.allocPrint(a, "0x{x}", .{hit});
    const range_start = try wire.number(args, "range_start", 0);
    const range_limit = try wire.number(args, "range_limit", 16);
    if (range_start > search.ranges.len or range_limit > 256) return error.InvalidArguments;
    const range_end = @min(search.ranges.len, range_start + range_limit);
    // Per-range coverage; hits are ascending, so each range's hit count is
    // the hits between its bounds.
    const Row = struct { address: []const u8, length: u64, scanned: u64, unreadable: u64, hits: usize };
    const rows = try a.alloc(Row, range_end - range_start);
    var partial: usize = 0;
    var unreadable_only: usize = 0;
    for (search.ranges, 0..) |r, i| {
        if (r.unreadable > 0) partial += 1;
        if (r.unreadable == r.length) unreadable_only += 1;
        if (i < range_start or i >= range_end) continue;
        const below = std.sort.lowerBound(u64, search.hits[0..search.count], r.address, order);
        const above = std.sort.lowerBound(u64, search.hits[0..search.count], r.address + r.length, order);
        rows[i - range_start] = .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{r.address}), .length = r.length, .scanned = if (i < search.range) r.length else if (i == search.range) search.offset else 0, .unreadable = r.unreadable, .hits = above - below };
    }
    return wire.value(a, .{ .id = search.id, .state = search.state, .generation = search.generation, .image_epoch = search.image_epoch, .scanned = search.scanned, .length = search.length, .unreadable = search.unreadable, .total_hits = search.count, .start = start, .next = if (end < search.count) @as(?usize, end) else null, .hits = hits, .range_count = search.ranges.len, .ranges_done = search.range, .ranges_with_unreadable = partial, .ranges_unreadable = unreadable_only, .range_start = range_start, .range_next = if (range_end < search.ranges.len) @as(?usize, range_end) else null, .ranges = rows });
}
