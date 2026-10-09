//! Byte-bounded pages over immutable companions and source-prefix rules.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Rule = @import("../model/source_maps.zig").Rule;
const wire = @import("profile.zig");
const paging = @import("list_page.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const Row = struct { path: []const u8, bytes: usize, verification: []const u8 };
const Snapshot = struct {
    session_id: u64,
    files: []const Row,
    rules: []const Rule,
    retained: usize = 0,
    automatic: bool = true,
    automatic_bytes: usize = 0,
};
fn identity(s: Snapshot) [64]u8 {
    var h = paging.Identity.init("xodb-debug-files-v1");
    h.number(s.session_id);
    h.number(s.retained);
    h.number(@intFromBool(s.automatic));
    h.number(s.automatic_bytes);
    h.number(s.files.len);
    for (s.files) |row| {
        h.text(row.path);
        h.number(row.bytes);
        h.text(row.verification);
    }
    h.number(s.rules.len);
    for (s.rules) |row| {
        h.text(row.from);
        h.text(row.to);
    }
    return h.finish();
}
fn page(a: A, s: Snapshot, args: V) !V {
    try wire.fields(args, &.{ "start", "limit", "view_id" });
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    const total = s.files.len + s.rules.len;
    if (start > total or limit == 0 or limit > 128) return error.InvalidArguments;
    const view = identity(s);
    if (args.object.get("view_id")) |given| {
        if (given != .string or given.string.len != view.len) return error.InvalidArguments;
        if (!std.mem.eql(u8, given.string, &view)) return error.StaleDebugFilesView;
    } else if (start != 0) return error.DebugFilesViewRequired;
    var files = V{ .array = std.array_list.Managed(V).init(a) };
    var rules = V{ .array = std.array_list.Managed(V).init(a) };
    var budget: paging.Budget = .{};
    var end: usize = @intCast(start);
    while (end < total and end - start < limit) : (end += 1) {
        const file = end < s.files.len;
        var row = if (file) try wire.value(a, s.files[end]) else try wire.value(a, s.rules[end - s.files.len]);
        if (!try budget.include(a, &row)) {
            if (end == start) return error.McpRowTooLarge;
            break;
        }
        if (file) try files.array.append(row) else try rules.array.append(row);
    }
    return wire.value(a, .{
        .files = files,
        .source_maps = rules,
        .retained = s.retained,
        .automatic = s.automatic,
        .automatic_bytes = s.automatic_bytes,
        .total_files = s.files.len,
        .total_source_maps = s.rules.len,
        .start = start,
        .next = if (end < total) @as(?usize, end) else null,
        .view_id = view[0..],
    });
}
pub fn call(a: A, session: *Session, args: V) !V {
    const source = session.symbolFiles();
    const rows = try a.alloc(Row, source.items.items.len);
    for (source.items.items, rows) |file, *row| row.* = .{ .path = file.path, .bytes = file.bytes.len, .verification = @tagName(file.verification) };
    return page(a, .{ .session_id = session.id, .files = rows, .rules = session.sourceMaps().rules.items, .retained = source.retained, .automatic = source.automatic, .automatic_bytes = source.auto_retained }, args);
}

test "debug file pages cover both arrays and refuse stale selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: [64]Row = undefined;
    for (&files, 0..) |*row, i| row.* = .{ .path = try std.fmt.allocPrint(a, "owned-{d}", .{i}), .bytes = i, .verification = "build_id" };
    var rules: [32]Rule = undefined;
    for (&rules, 0..) |*row, i| row.* = .{ .from = try std.fmt.allocPrint(a, "/old/{d}", .{i}), .to = "/new" };
    const s = Snapshot{ .session_id = 1, .files = &files, .rules = &rules };
    var args = try wire.value(a, .{ .limit = 7 });
    var seen: usize = 0;
    while (true) {
        const result = try page(a, s, args);
        const f = result.object.get("files").?.array.items;
        const r = result.object.get("source_maps").?.array.items;
        try std.testing.expect(f.len + r.len <= 7);
        for (f) |row| {
            try std.testing.expectEqualStrings(files[seen].path, row.object.get("path").?.string);
            seen += 1;
        }
        for (r) |row| {
            try std.testing.expectEqualStrings(rules[seen - files.len].from, row.object.get("from").?.string);
            seen += 1;
        }
        if (result.object.get("next").? == .null) break;
        try args.object.put(a, "start", result.object.get("next").?);
        try args.object.put(a, "view_id", result.object.get("view_id").?);
    }
    try std.testing.expectEqual(@as(usize, 96), seen);
    var changed = s;
    changed.session_id += 1;
    try std.testing.expectError(error.StaleDebugFilesView, page(a, changed, args));
    rules[0].to = "/different";
    try std.testing.expectError(error.StaleDebugFilesView, page(a, s, args));
    try std.testing.expectError(error.DebugFilesViewRequired, page(a, s, try wire.value(a, .{ .start = 1 })));
    for ([_]u64{ 0, 129 }) |limit| try std.testing.expectError(error.InvalidArguments, page(a, s, try wire.value(a, .{ .limit = limit })));
    const empty = try page(a, .{ .session_id = 2, .files = &.{}, .rules = &.{} }, .{ .object = .empty });
    try std.testing.expect(empty.object.get("next").? == .null);
}
