//! Cached, observer-only page metadata. No target bytes or physical addresses.
const std = @import("std");
const c = @import("../c.zig").api;
const wire = @import("profile.zig");
const State = @import("../model/system.zig").Collector;
const V = std.json.Value;
const A = std.mem.Allocator;
pub const definitions = std.mem.trim(u8, @embedFile("memstat_tools.json"), " \n\r\t");
pub fn handles(name: []const u8) bool {
    return eq(name, "get_memory_map") or eq(name, "get_thp_state") or eq(name, "get_fragmentation");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn obj() V {
    return .{ .object = .empty };
}
fn arr(a: A) V {
    return .{ .array = std.array_list.Managed(V).init(a) };
}
fn put(a: A, o: *V, key: []const u8, v: V) !void {
    try o.object.put(a, key, v);
}
fn add(a: A, o: *V, v: V) !void {
    _ = a;
    try o.array.append(v);
}
fn text(a: A, bytes: []const u8) !V {
    return .{ .string = try a.dupe(u8, bytes) };
}
fn safe(a: A, bytes: []const u8) !V {
    if (bytes.len > 4096 or !std.unicode.utf8ValidateSlice(bytes)) return .null;
    for (bytes) |ch| if (ch < 32 or ch == 127) return .null;
    return text(a, bytes);
}
fn n(a: A, value: u64) !V {
    return if (value <= std.math.maxInt(i64)) .{ .integer = @intCast(value) } else .{ .string = try std.fmt.allocPrint(a, "{d}", .{value}) };
}
fn hex(a: A, value: u64) !V {
    return .{ .string = try std.fmt.allocPrint(a, "0x{x}", .{value}) };
}
fn known(a: A, value: u64, ok: bool) !V {
    return if (ok) n(a, value) else .null;
}
fn flag(value: bool) V {
    return .{ .bool = value };
}
fn boolean(args: V, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    if (v != .bool) return error.InvalidArguments;
    return v.bool;
}
fn unsigned(args: V, key: []const u8, default: ?u64) !u64 {
    const v = args.object.get(key) orelse return default orelse error.InvalidArguments;
    if (v == .integer and v.integer >= 0) return @intCast(v.integer);
    if (v == .string and v.string.len > 0 and v.string.len <= 20) {
        for (v.string) |ch| if (ch < '0' or ch > '9') return error.InvalidArguments;
        return std.fmt.parseInt(u64, v.string, 10) catch return error.InvalidArguments;
    }
    return error.InvalidArguments;
}
fn address(args: V, key: []const u8) !u64 {
    const v = args.object.get(key) orelse return 0;
    if (v != .string or v.string.len < 3 or v.string.len > 18 or !std.mem.startsWith(u8, v.string, "0x")) return error.InvalidArguments;
    for (v.string[2..]) |ch| if (!std.ascii.isHex(ch)) return error.InvalidArguments;
    return std.fmt.parseInt(u64, v.string[2..], 16) catch return error.InvalidArguments;
}
fn status(a: A, s: c.struct_xrt_mem_status) !V {
    var result = obj();
    const label: []const u8 = switch (s.state) {
        c.XRT_MEM_OK => "ok",
        c.XRT_MEM_UNAVAILABLE => "unavailable",
        c.XRT_MEM_DENIED => "denied",
        c.XRT_MEM_EXITED => "exited",
        c.XRT_MEM_IDENTITY_CHANGED => "identity_changed",
        c.XRT_MEM_PARTIAL => "partial",
        else => "invalid",
    };
    try put(a, &result, "state", try text(a, label));
    try put(a, &result, "reason", try safe(a, std.mem.sliceTo(&s.reason, 0)));
    try put(a, &result, "errno", .{ .integer = s.@"error" });
    return result;
}
fn cache(a: A, sequence: u64, sampled: u64, now: u64) !V {
    var result = obj();
    try put(a, &result, "sequence", try n(a, sequence));
    try put(a, &result, "sampled_monotonic_ns", try known(a, sampled, sampled != 0));
    try put(a, &result, "age_ms", try known(a, (now -| sampled) / 1_000_000, sampled != 0));
    try put(a, &result, "pending", flag(sampled == 0));
    return result;
}
fn processSummary(a: A, p: *const c.struct_xrt_mem_process, redact: bool) !V {
    var result = obj();
    try put(a, &result, "pid", .{ .integer = p.pid });
    try put(a, &result, "start_ticks", try n(a, p.start_ticks));
    try put(a, &result, "name", if (redact or p.maps_status.state == c.XRT_MEM_DENIED or p.name[0] == 0) .null else try safe(a, std.mem.sliceTo(&p.name, 0)));
    inline for (.{ "started_ns", "finished_ns", "cpu_ns", "page_size", "mapped_bytes", "scanned_bytes", "vma_count", "range_count" }) |field|
        try put(a, &result, field, try n(a, @field(p, field)));
    inline for (.{ "maps_status", "pages_status", "numa_status", "rollup_status" }) |field|
        try put(a, &result, field, try status(a, @field(p, field)));
    try put(a, &result, "scan_resume", try hex(a, p.scan_resume));
    inline for (.{ .{ "rss", c.XRT_MEM_RSS }, .{ "anonymous", c.XRT_MEM_ANONYMOUS }, .{ "anon_huge", c.XRT_MEM_ANON_HUGE }, .{ "swap", c.XRT_MEM_SWAP } }) |field| {
        try put(a, &result, field[0], try known(a, @field(p, field[0]), p.totals_known & field[1] != 0));
        try put(a, &result, "rollup_" ++ field[0], try known(a, @field(p, "rollup_" ++ field[0]), p.rollup_known & field[1] != 0));
    }
    var coverage = obj();
    try put(a, &coverage, "numerator_bytes", try known(a, p.coverage_numerator, p.coverage_numerator_known != 0));
    try put(a, &coverage, "denominator_bytes", try known(a, p.coverage_denominator, p.coverage_denominator_known != 0));
    try put(a, &coverage, "numerator_known", flag(p.coverage_numerator_known != 0));
    try put(a, &coverage, "denominator_known", flag(p.coverage_denominator_known != 0));
    try put(a, &coverage, "pmd_size", try known(a, p.pmd_size, p.pmd_size_known != 0));
    try put(a, &coverage, "basis", try text(a, "AnonHugePages in THPeligible private anonymous VMAs / PMD-aligned span inside those VMAs"));
    try put(a, &result, "coverage", coverage);
    return result;
}
fn vma(a: A, p: *const c.struct_xrt_mem_process, index: u32, redact: bool) !V {
    const row = p.vmas[index];
    var result = obj();
    try put(a, &result, "index", try n(a, index));
    try put(a, &result, "start", try hex(a, row.start));
    try put(a, &result, "end", try hex(a, row.end));
    try put(a, &result, "offset", try hex(a, row.offset));
    try put(a, &result, "inode", if (redact) .null else try n(a, row.inode));
    try put(a, &result, "permissions", try text(a, row.permissions[0..4]));
    try put(a, &result, "known_mask", try n(a, row.known));
    try put(a, &result, "flags", try n(a, row.flags));
    const path_ok = row.flags & c.XRT_MEM_PATH_CUT == 0 and @as(u64, row.path) + row.path_length <= p.path_length;
    try put(a, &result, "path", if (redact or !path_ok) .null else try safe(a, p.paths[row.path..][0..row.path_length]));
    try put(a, &result, "thp_eligible", if (row.known & c.XRT_MEM_ELIGIBLE != 0) flag(row.thp_eligible != 0) else .null);
    inline for (.{ .{ "rss", c.XRT_MEM_RSS }, .{ "pss", c.XRT_MEM_PSS }, .{ "anonymous", c.XRT_MEM_ANONYMOUS }, .{ "anon_huge", c.XRT_MEM_ANON_HUGE }, .{ "file_pmd", c.XRT_MEM_FILE_PMD }, .{ "shmem_pmd", c.XRT_MEM_SHMEM_PMD }, .{ "swap", c.XRT_MEM_SWAP }, .{ "locked", c.XRT_MEM_LOCKED }, .{ "kernel_page", c.XRT_MEM_KERNEL_PAGE }, .{ "mmu_page", c.XRT_MEM_MMU_PAGE }, .{ "private_hugetlb", c.XRT_MEM_PRIVATE_HUGETLB }, .{ "shared_hugetlb", c.XRT_MEM_SHARED_HUGETLB } }) |field|
        try put(a, &result, field[0], try known(a, @field(row, field[0]), row.known & field[1] != 0));
    var nodes = arr(a);
    for (row.numa[0..row.numa_count]) |node| {
        var item = obj();
        try put(a, &item, "node", try n(a, node.node));
        try put(a, &item, "pages", try n(a, node.pages));
        try add(a, &nodes, item);
    }
    try put(a, &result, "numa_page_size", try known(a, row.numa_page_size, row.numa_page_size != 0));
    try put(a, &result, "numa_vma_totals", if (row.numa_available != 0) nodes else .null);
    return result;
}
fn pageRange(a: A, row: c.struct_xrt_mem_range) !V {
    var result = obj();
    try put(a, &result, "start", try hex(a, row.start));
    try put(a, &result, "end", try hex(a, row.end));
    try put(a, &result, "categories", try n(a, row.categories));
    try put(a, &result, "known_mask", try n(a, row.known));
    try put(a, &result, "vma", try n(a, row.vma));
    try put(a, &result, "backend", try text(a, switch (row.backend) {
        c.XRT_MEM_BACKEND_SCAN => "pagemap_scan",
        c.XRT_MEM_BACKEND_PAGEMAP => "pagemap_flags",
        else => "unavailable",
    }));
    return result;
}
fn cell(a: A, scope: *const c.struct_xrt_mem_scope, start: u64, end: u64) !V {
    var row: c.struct_xrt_mem_cell = undefined;
    if (c.xrt_mem_cell_read(scope.snapshot, scope.previous, start, end, &row) == 0) return error.InvalidArguments;
    var result = obj();
    try put(a, &result, "start", try hex(a, start));
    try put(a, &result, "end", try hex(a, end));
    inline for (.{ "mapped_bytes", "observed_bytes", "categories", "categories_all", "known", "mixed", "changed_categories", "change_known" }) |field|
        try put(a, &result, field, try n(a, @field(row, field)));
    try put(a, &result, "mapping_known", flag(row.mapping_known != 0));
    try put(a, &result, "pmd_change_known", flag(row.pmd_change_known != 0));
    try put(a, &result, "collapsed_bytes", try known(a, row.collapsed_bytes, row.pmd_change_known != 0));
    try put(a, &result, "split_bytes", try known(a, row.split_bytes, row.pmd_change_known != 0));
    try put(a, &result, "physical_change_known", flag(false));
    return result;
}
fn system(a: A, s: *const c.struct_xrt_mem_system, fragmentation: bool, order: ?u32) !V {
    var result = obj();
    inline for (.{ "buddy_status", "vmstat_status", "thp_status", "zswap_status" }) |field|
        try put(a, &result, field, try status(a, @field(s, field)));
    inline for (.{ "started_ns", "finished_ns", "cpu_ns", "page_size", "delta_interval_ns" }) |field|
        try put(a, &result, field, try n(a, @field(s, field)));
    try put(a, &result, "activity_scope", try text(a, "system-wide; never attributed to the selected process"));
    var counters = arr(a);
    for (s.counters[0..s.counter_count]) |counter| {
        var item = obj();
        try put(a, &item, "name", try text(a, std.mem.sliceTo(&counter.name, 0)));
        try put(a, &item, "value", try n(a, counter.value));
        try put(a, &item, "cumulative", flag(counter.cumulative != 0));
        try put(a, &item, "delta", try known(a, counter.delta, counter.delta_known != 0));
        try put(a, &item, "reset", flag(counter.reset != 0));
        try add(a, &counters, item);
    }
    try put(a, &result, "counters", counters);
    if (!fragmentation) {
        var settings = arr(a);
        for (s.settings[0..s.setting_count]) |setting| {
            var item = obj();
            try put(a, &item, "name", try text(a, std.mem.sliceTo(&setting.name, 0)));
            try put(a, &item, "value", if (setting.status.state == c.XRT_MEM_OK) try safe(a, std.mem.sliceTo(&setting.value, 0)) else .null);
            try put(a, &item, "status", try status(a, setting.status));
            try add(a, &settings, item);
        }
        try put(a, &result, "settings", settings);
    } else {
        var zones = arr(a);
        for (s.zones[0..s.zone_count]) |*zone| {
            var item = obj();
            try put(a, &item, "node", try n(a, zone.node));
            try put(a, &item, "name", try text(a, std.mem.sliceTo(&zone.name, 0)));
            try put(a, &item, "free_pages", try n(a, zone.free_pages));
            try put(a, &item, "free_blocks", try n(a, zone.free_blocks));
            var blocks = arr(a);
            for (zone.blocks[0..zone.orders]) |blocks_at_order| try add(a, &blocks, try n(a, blocks_at_order));
            try put(a, &item, "blocks_by_order", blocks);
            var f: c.struct_xrt_mem_fragmentation = undefined;
            const ok = if (order) |o| c.xrt_mem_fragmentation(zone, o, &f) != 0 else false;
            try put(a, &item, "order", if (order) |o| try n(a, o) else .null);
            try put(a, &item, "index_permille", if (ok) .{ .integer = f.index_permille } else .null);
            try put(a, &item, "unusable_permille", if (ok) try n(a, f.unusable_permille) else .null);
            try put(a, &item, "suitable_blocks", if (ok) try n(a, f.suitable_blocks) else .null);
            try add(a, &zones, item);
        }
        try put(a, &result, "zones", zones);
        try put(a, &result, "index_note", try text(a, "kernel extfrag formula; -1000 means an allocation is possible; other negative values are valid; not a completion percentage"));
    }
    return result;
}

pub fn call(a: A, state: *State, name: []const u8, args: V) !V {
    const map = eq(name, "get_memory_map");
    const frag = eq(name, "get_fragmentation");
    if (map) try wire.fields(args, &.{ "pid", "start_ticks", "range_start", "range_end", "view", "cell_bytes", "limit", "offset", "sequence", "redact", "numa" }) else if (frag) try wire.fields(args, &.{ "order", "redact" }) else if (eq(name, "get_thp_state")) try wire.fields(args, &.{ "pid", "start_ticks", "redact" }) else return error.UnknownTool;
    const redact = try boolean(args, "redact") or state.redact;
    var request = std.mem.zeroes(c.struct_xrt_mem_request);
    request.flags = c.XRT_MEM_SKIP_PAGES;
    var mode: []const u8 = "vmas";
    if (args.object.get("view")) |v| {
        if (v != .string or !(eq(v.string, "vmas") or eq(v.string, "ranges") or eq(v.string, "cells"))) return error.InvalidArguments;
        mode = v.string;
    }
    if (map and !eq(mode, "vmas")) request.flags = 0;
    if (map and try boolean(args, "numa")) request.flags |= c.XRT_MEM_NUMA;
    const pid = try wire.number(args, "pid", if (map) null else 0);
    if (pid > std.math.maxInt(i32) or ((map or args.object.get("pid") != null) and pid == 0)) return error.InvalidArguments;
    if (pid > 0) {
        request.pid = @intCast(pid);
        request.start_ticks = try unsigned(args, "start_ticks", null);
        if (request.start_ticks == 0) return error.InvalidArguments;
    } else if (args.object.get("start_ticks") != null) return error.InvalidArguments;
    request.range_start = try address(args, "range_start");
    request.range_end = try address(args, "range_end");
    const has_range = args.object.get("range_start") != null;
    if (has_range != (args.object.get("range_end") != null)) return error.InvalidArguments;
    const page_long = c.sysconf(c._SC_PAGESIZE);
    if (page_long <= 0) return error.MemoryUnavailable;
    const page: u64 = @intCast(page_long);
    if (has_range and (request.range_end <= request.range_start or request.range_start % page != 0 or request.range_end % page != 0)) return error.InvalidArguments;
    if (eq(mode, "vmas") and has_range) return error.InvalidArguments;
    const cell_bytes = try wire.number(args, "cell_bytes", 2 * 1024 * 1024);
    if (args.object.get("cell_bytes") != null and !eq(mode, "cells")) return error.InvalidArguments;
    if (eq(mode, "cells") and (!has_range or (cell_bytes != 2 * 1024 * 1024 and cell_bytes != page) or
        request.range_start % cell_bytes != 0 or request.range_end % cell_bytes != 0)) return error.InvalidArguments;
    const limit = try wire.number(args, "limit", 128);
    const offset = try unsigned(args, "offset", 0);
    const sequence = try unsigned(args, "sequence", 0);
    if (limit == 0 or limit > 256 or (offset != 0 and sequence == 0)) return error.InvalidArguments;
    var order: ?u32 = null;
    if (args.object.get("order") != null) {
        const given = try wire.number(args, "order", null);
        if (given >= c.XRT_MEM_MAX_ORDERS) return error.InvalidArguments;
        order = @intCast(given);
    } else if (page <= 2 * 1024 * 1024) {
        var bytes = page;
        var o: u32 = 0;
        while (bytes < 2 * 1024 * 1024) : (o += 1) bytes *= 2;
        if (bytes == 2 * 1024 * 1024) order = o;
    }
    const observer = try state.memoryObserver();
    const ticket = if (pid > 0) c.xrt_memobserver_process(observer, &request) else 0;
    if (pid > 0 and ticket == 0) return error.MemoryCacheBusy;
    if (pid == 0 and c.xrt_memobserver_system(observer) == 0) return error.MemoryCacheBusy;
    var view: c.struct_xrt_mem_view = undefined;
    if (c.xrt_memobserver_acquire(observer, &view) == 0) return error.MemoryCacheBusy;
    defer c.xrt_memobserver_release(observer);
    const now = @import("../target/linux.zig").now();
    var result = obj();
    try put(a, &result, "schema", .{ .integer = 1 });
    try put(a, &result, "redacted", flag(redact));
    try put(a, &result, "cadence_ms", .{ .integer = 1000 });
    try put(a, &result, "demand_ms", .{ .integer = 3000 });
    try put(a, &result, "owner_cpu_ns", try n(a, view.owner_cpu_ns));
    try put(a, &result, "owner_instances", try n(a, state.memory_opens));
    try put(a, &result, "system_cache", try cache(a, view.system_sequence, view.system_sampled_ns, now));
    try put(a, &result, "system_refresh_ms", try n(a, @max(1_000_000_000, view.system_refresh_ns) / 1_000_000));
    try put(a, &result, "system_error", .{ .integer = view.system_error });
    if (!map) try put(a, &result, "system", if (view.system != null) try system(a, view.system, frag, order) else .null);
    if (pid == 0) return result;
    const scope = for (&view.scopes) |*candidate| {
        if (candidate.ticket == ticket) break candidate;
    } else return error.MemoryCacheBusy;
    if (sequence != 0 and scope.sequence != sequence) return error.StaleMemorySnapshot;
    try put(a, &result, "ticket", try n(a, ticket));
    try put(a, &result, "cache", try cache(a, scope.sequence, scope.sampled_ns, now));
    try put(a, &result, "refresh_ms", try n(a, @max(1_000_000_000, scope.refresh_ns) / 1_000_000));
    try put(a, &result, "cost_limited", flag(scope.cost_limited != 0));
    try put(a, &result, "sampling", flag(scope.sampling != 0));
    try put(a, &result, "delta_interval_ns", try n(a, scope.delta_interval_ns));
    try put(a, &result, "process_error", .{ .integer = scope.@"error" });
    if (scope.snapshot == null) {
        try put(a, &result, "process", .null);
        return result;
    }
    const p: *const c.struct_xrt_mem_process = scope.snapshot;
    try put(a, &result, "process", try processSummary(a, p, redact));
    if (!map) return result;
    const count: u64 = if (eq(mode, "vmas")) p.vma_count else if (eq(mode, "ranges")) p.range_count else (request.range_end - request.range_start) / cell_bytes;
    if (offset > count) return error.InvalidArguments;
    const end = offset + @min(limit, count - offset);
    var rows = arr(a);
    var i = offset;
    while (i < end) : (i += 1) {
        const row = if (eq(mode, "vmas")) try vma(a, p, @intCast(i), redact) else if (eq(mode, "ranges")) try pageRange(a, p.ranges[@intCast(i)]) else try cell(a, scope, request.range_start + i * cell_bytes, request.range_start + (i + 1) * cell_bytes);
        try add(a, &rows, row);
    }
    try put(a, &result, "view", try text(a, mode));
    try put(a, &result, "count", try n(a, count));
    try put(a, &result, "offset", try n(a, offset));
    try put(a, &result, "next_offset", if (end < count) try n(a, end) else .null);
    try put(a, &result, "rows", rows);
    return result;
}

test "memory arguments are strict before any worker opens" {
    var state: State = .{};
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "{\"pid\":42}",                                        "{\"pid\":42,\"start_ticks\":0}",
        "{\"pid\":42,\"start_ticks\":1,\"root\":\"fixture\"}", "{\"pid\":42,\"start_ticks\":1,\"range_start\":\"0x1000\"}",
        "{\"pid\":42,\"start_ticks\":1,\"view\":\"cells\"}",   "{\"pid\":42,\"start_ticks\":1,\"offset\":1}",
        "{\"pid\":42,\"start_ticks\":1,\"limit\":257}",        "{\"pid\":42,\"start_ticks\":1,\"cell_bytes\":4096}",
    }) |bytes| {
        const args = try std.json.parseFromSliceLeaky(V, a, bytes, .{});
        try std.testing.expectError(error.InvalidArguments, call(a, &state, "get_memory_map", args));
    }
    const zero_pid = try std.json.parseFromSliceLeaky(V, a, "{\"pid\":0}", .{});
    try std.testing.expectError(error.InvalidArguments, call(a, &state, "get_thp_state", zero_pid));
    try std.testing.expectEqual(0, state.memory_opens);
}

test "memory formatting preserves unknown and redacts process names and paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = std.mem.zeroes(c.struct_xrt_mem_process);
    @memcpy(p.name[0..5], "owned");
    var row = std.mem.zeroes(c.struct_xrt_mem_vma);
    row.path_length = 15;
    row.permissions = .{ 'r', 'w', '-', 'p', 0 };
    var path = "/fixture/secret".*;
    p.paths = &path;
    p.path_length = path.len;
    p.vmas = @ptrCast(&row);
    p.vma_count = 1;
    const summary = try processSummary(a, &p, true);
    try std.testing.expect(summary.object.get("name").? == .null);
    try std.testing.expect(summary.object.get("coverage").?.object.get("denominator_bytes").? == .null);
    p.maps_status.state = c.XRT_MEM_DENIED;
    try std.testing.expect((try processSummary(a, &p, false)).object.get("name").? == .null);
    const redacted = try vma(a, &p, 0, true);
    try std.testing.expect(redacted.object.get("path").? == .null);
    const plain = try vma(a, &p, 0, false);
    try std.testing.expectEqualStrings("/fixture/secret", plain.object.get("path").?.string);
    try std.testing.expect(plain.object.get("rss").? == .null);
    try std.testing.expect((try safe(a, "unsafe\nname")) == .null);
    try std.testing.expect((try safe(a, "\xff")) == .null);
    try std.testing.expectEqualStrings("18446744073709551615", (try n(a, std.math.maxInt(u64))).string);
}
