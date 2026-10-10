//! Page the retained module-map snapshot without constructing an unbounded reply.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const model = @import("../model/modules.zig");
const wire = @import("profile.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Hash = std.crypto.hash.sha2.Sha256;
const default_limit = 128;
const maximum_limit = 512;
// Includes conservative escaping/hex expansion and both MCP reply forms.
// Leave ample room within the server's 1 MiB envelope, even for long paths.
const page_bytes = 192 * 1024;
const Snapshot = struct {
    session_id: u64,
    generation: u64,
    epoch: u64,
    regions: []const model.Region,
    failures: []const model.Modules.LoadFailure,
    pe_pending: bool = false,
};
fn hashNumber(hash: *Hash, n: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, n, .little);
    hash.update(&bytes);
}
fn hashText(hash: *Hash, text: []const u8) void {
    hashNumber(hash, text.len);
    hash.update(text);
}
fn identity(snapshot: Snapshot) [64]u8 {
    var hash = Hash.init(.{});
    hash.update("xodb-module-page-v1");
    hashNumber(&hash, snapshot.session_id);
    hashNumber(&hash, snapshot.generation);
    hashNumber(&hash, snapshot.epoch);
    hashNumber(&hash, snapshot.regions.len);
    for (snapshot.regions) |r| {
        hashNumber(&hash, r.start);
        hashNumber(&hash, r.end);
        hashNumber(&hash, r.offset);
        hashNumber(&hash, r.inode);
        hashNumber(&hash, r.device_major);
        hashNumber(&hash, r.device_minor);
        hash.update(&r.permissions);
        hashText(&hash, r.path);
        hashText(&hash, @tagName(r.file_source));
        hashNumber(&hash, @intFromBool(r.full_image_deferred));
        hashNumber(&hash, @intFromBool(r.pe_image != null));
        if (r.pe_image) |pe_image| {
            hashNumber(&hash, pe_image.id);
            hashNumber(&hash, pe_image.base);
            hashText(&hash, pe_image.path);
        }
    }
    hashNumber(&hash, snapshot.failures.len);
    for (snapshot.failures) |f| {
        hashNumber(&hash, f.start);
        hashNumber(&hash, f.end);
        hashText(&hash, f.path);
        hashText(&hash, f.diagnostic);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}
fn decimal(text: []const u8) !usize {
    if (text.len == 0 or text.len > 20) return error.InvalidModuleCursor;
    for (text) |b| if (b < '0' or b > '9') return error.InvalidModuleCursor;
    return std.fmt.parseInt(usize, text, 10) catch error.InvalidModuleCursor;
}
fn rowBytes(path: []const u8, diagnostic: []const u8) usize {
    return 1024 +| (path.len +| diagnostic.len) *| 16;
}
fn page(a: Allocator, snapshot: Snapshot, args: Value) !Value {
    try wire.fields(args, &.{ "cursor", "limit" });
    const limit = try wire.number(args, "limit", default_limit);
    if (limit == 0 or limit > maximum_limit) return error.InvalidArguments;
    const digest = identity(snapshot);
    var start: usize = 0;
    var failure_start: usize = 0;
    if (args.object.get("cursor")) |given| {
        if (given != .string or given.string.len > 128) return error.InvalidModuleCursor;
        var parts = std.mem.splitScalar(u8, given.string, ':');
        if (!std.mem.eql(u8, parts.next() orelse return error.InvalidModuleCursor, "1")) return error.InvalidModuleCursor;
        const key = parts.next() orelse return error.InvalidModuleCursor;
        if (key.len != digest.len) return error.InvalidModuleCursor;
        var decoded: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&decoded, key) catch return error.InvalidModuleCursor;
        start = try decimal(parts.next() orelse return error.InvalidModuleCursor);
        failure_start = try decimal(parts.next() orelse return error.InvalidModuleCursor);
        if (parts.next() != null) return error.InvalidModuleCursor;
        if (!std.mem.eql(u8, key, &digest)) return error.StaleModuleCursor;
        if (start > snapshot.regions.len or failure_start > snapshot.failures.len or
            (start < snapshot.regions.len and failure_start != 0)) return error.InvalidModuleCursor;
    }
    var end = start;
    var failure_end = failure_start;
    var used: usize = 0;
    var rows: usize = 0;
    while (end < snapshot.regions.len and rows < limit) {
        const bytes = rowBytes(snapshot.regions[end].path, if (snapshot.regions[end].pe_image) |pe_image| pe_image.path else "");
        if (bytes > page_bytes - used) break;
        used += bytes;
        rows += 1;
        end += 1;
    }
    while (end == snapshot.regions.len and failure_end < snapshot.failures.len and rows < limit) {
        const failure = snapshot.failures[failure_end];
        const bytes = rowBytes(failure.path, failure.diagnostic);
        if (bytes > page_bytes - used) break;
        used += bytes;
        rows += 1;
        failure_end += 1;
    }
    const more = end < snapshot.regions.len or failure_end < snapshot.failures.len;
    if (rows == 0 and more) return error.ModuleRowTooLarge;
    const next = if (more) try std.fmt.allocPrint(a, "1:{s}:{d}:{d}", .{ digest, end, failure_end }) else null;
    return wire.value(a, .{
        .regions = snapshot.regions[start..end],
        .load_failures = snapshot.failures[failure_start..failure_end],
        .total_regions = snapshot.regions.len,
        .total_load_failures = snapshot.failures.len,
        .map_generation = snapshot.generation,
        .image_epoch = snapshot.epoch,
        .pe_metadata_pending = snapshot.pe_pending,
        .next = next,
    });
}
pub fn call(a: Allocator, session: *Session, args: Value) !Value {
    try session.refreshMaps();
    return page(a, .{
        .session_id = session.id,
        .generation = session.maps_generation,
        .epoch = session.maps_epoch,
        .regions = session.modules.regions.items,
        .failures = session.modules.load_failures.items,
        .pe_pending = session.modules.peDiscoveryPending(),
    }, args);
}

fn testRegion(n: usize, path: []const u8) model.Region {
    const start = 0x20000000000001 + @as(u64, @intCast(n)) * 4096;
    return .{ .start = start, .end = start + 4096, .offset = 0, .inode = 7, .device_major = 1, .device_minor = 2, .permissions = .{ 'r', '-', '-', 'p' }, .path = path };
}
test "module pages cover every region and failure exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const regions = try a.alloc(model.Region, 5001);
    for (regions, 0..) |*region, i| region.* = testRegion(i, "owned-module");
    const failures = [_]model.Modules.LoadFailure{
        .{ .start = 1, .end = 2, .path = "first", .diagnostic = "OwnedFailure" },
        .{ .start = 3, .end = 4, .path = "second", .diagnostic = "OwnedFailure" },
    };
    const snapshot = Snapshot{ .session_id = 1, .generation = 2, .epoch = 3, .regions = regions, .failures = &failures };
    var args = try wire.value(a, .{ .limit = 97 });
    var seen: usize = 0;
    var failures_seen: usize = 0;
    var pages: usize = 0;
    while (true) {
        const result = try page(a, snapshot, args);
        try std.testing.expectEqual(@as(i64, 5001), result.object.get("total_regions").?.integer);
        try std.testing.expectEqual(@as(i64, 2), result.object.get("total_load_failures").?.integer);
        const rows = result.object.get("regions").?.array.items;
        const bad = result.object.get("load_failures").?.array.items;
        try std.testing.expect(rows.len + bad.len <= 97);
        for (rows) |row| {
            try std.testing.expectEqual(regions[seen].start, @as(u64, @intCast(row.object.get("start").?.integer)));
            seen += 1;
        }
        for (bad) |row| {
            try std.testing.expectEqualStrings(failures[failures_seen].path, row.object.get("path").?.string);
            failures_seen += 1;
        }
        pages += 1;
        const next = result.object.get("next").?;
        if (next == .null) break;
        try std.testing.expect(pages < 100);
        try args.object.put(a, "cursor", next);
    }
    try std.testing.expectEqual(@as(usize, 5001), seen);
    try std.testing.expectEqual(@as(usize, 2), failures_seen);
    const empty = try page(a, .{ .session_id = 1, .generation = 2, .epoch = 3, .regions = &.{}, .failures = &.{} }, .{ .object = .empty });
    try std.testing.expect(empty.object.get("next").? == .null);
}

test "module cursors refuse other sessions generations mappings and malformed indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var regions = [_]model.Region{ testRegion(0, "owned"), testRegion(1, "owned") };
    var failures = [_]model.Modules.LoadFailure{.{ .start = 1, .end = 2, .path = "owned", .diagnostic = "First" }};
    const snapshot = Snapshot{ .session_id = 1, .generation = 2, .epoch = 3, .regions = &regions, .failures = &failures };
    const first = try page(a, snapshot, try wire.value(a, .{ .limit = 1 }));
    const cursor = first.object.get("next").?;
    const args = try wire.value(a, .{ .cursor = cursor.string, .limit = 2 });
    _ = try page(a, snapshot, args); // Page size may change without losing place.
    var changed = snapshot;
    changed.session_id += 1;
    try std.testing.expectError(error.StaleModuleCursor, page(a, changed, args));
    changed = snapshot;
    changed.generation += 1;
    try std.testing.expectError(error.StaleModuleCursor, page(a, changed, args));
    changed = snapshot;
    changed.epoch += 1;
    try std.testing.expectError(error.StaleModuleCursor, page(a, changed, args));
    regions[0].offset = 4096;
    try std.testing.expectError(error.StaleModuleCursor, page(a, snapshot, args));
    regions[0].offset = 0;
    regions[0].file_source = .target_root;
    try std.testing.expectError(error.StaleModuleCursor, page(a, snapshot, args));
    const resolved = try page(a, snapshot, try wire.value(a, .{ .limit = 1 }));
    try std.testing.expectEqualStrings("target_root", resolved.object.get("regions").?.array.items[0].object.get("file_source").?.string);
    regions[0].file_source = .unopened;
    regions[0].full_image_deferred = true;
    try std.testing.expectError(error.StaleModuleCursor, page(a, snapshot, args));
    regions[0].full_image_deferred = false;
    failures[0].diagnostic = "Second";
    try std.testing.expectError(error.StaleModuleCursor, page(a, snapshot, args));
    failures[0].diagnostic = "First";
    for ([_][]const u8{ "", "1:x:0:0", "2:x:0:0", "1:x:-1:0" }) |text|
        try std.testing.expectError(error.InvalidModuleCursor, page(a, snapshot, try wire.value(a, .{ .cursor = text })));
    const digest = identity(snapshot);
    const outside = try std.fmt.allocPrint(a, "1:{s}:3:0", .{digest});
    try std.testing.expectError(error.InvalidModuleCursor, page(a, snapshot, try wire.value(a, .{ .cursor = outside })));
    for ([_]u64{ 0, 513, std.math.maxInt(u64) }) |limit|
        try std.testing.expectError(error.InvalidArguments, page(a, snapshot, try wire.value(a, .{ .limit = limit })));
}

test "module byte budget includes long escaped paths hex fields and both reply forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try a.alloc(u8, 4096);
    @memset(path, 1); // Worst JSON control-byte expansion, then escape the text copy.
    var regions: [512]model.Region = undefined;
    for (&regions, 0..) |*region, i| region.* = testRegion(i, path);
    const snapshot = Snapshot{ .session_id = 1, .generation = 2, .epoch = 3, .regions = &regions, .failures = &.{} };
    var result = try page(a, snapshot, try wire.value(a, .{ .limit = 512 }));
    try std.testing.expect(result.object.get("regions").?.array.items.len > 0);
    try std.testing.expect(result.object.get("regions").?.array.items.len < 512);
    try std.testing.expect(result.object.get("next").? != .null);
    try @import("exact.zig").addresses(a, &result);
    const text = try std.json.Stringify.valueAlloc(a, result, .{});
    const reply = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = 1, .result = .{ .structuredContent = result, .isError = false, .content = .{.{ .type = "text", .text = text }} } }, .{});
    try std.testing.expect(reply.len < 1024 * 1024);
    const enormous = try a.alloc(u8, page_bytes);
    @memset(enormous, 'x');
    regions[0].path = enormous;
    try std.testing.expectError(error.ModuleRowTooLarge, page(a, snapshot, .{ .object = .empty }));
}
