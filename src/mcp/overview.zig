//! Observer-only whole-system tools backed by the C sysstat collector. They
//! need no debug target; rates come from the previous observation.
const std = @import("std");
const c = @import("../c.zig").api;
const wire = @import("profile.zig");
const Value = std.json.Value;

const fd = @import("fd.zig");
const memstat = @import("memstat.zig");
const base_definitions = std.mem.trim(u8, @embedFile("overview_tools.json"), " \n\r\t");
const fd_definitions = std.mem.trim(u8, fd.definitions, " \n\r\t");
pub const definitions = base_definitions[0 .. base_definitions.len - 1] ++ "," ++ fd_definitions[1 .. fd_definitions.len - 1] ++ "," ++ memstat.definitions[1..];

pub fn handles(name: []const u8) bool {
    if (fd.handles(name)) return true;
    for ([_][]const u8{ "get_overview", "list_processes", "get_process", "get_connections", "get_sensors" }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return memstat.handles(name);
}

pub const State = @import("../model/system.zig").Collector;

fn boolean(args: Value, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    if (v != .bool) return error.InvalidArguments;
    return v.bool;
}

fn group(id: c_uint) u32 {
    return @as(u32, 1) << @intCast(id);
}

pub fn call(a: std.mem.Allocator, state: *State, name: []const u8, args: Value) !Value {
    if (fd.handles(name)) return fd.call(a, state, name, args);
    if (memstat.handles(name)) return memstat.call(a, state, name, args);
    var opts = std.mem.zeroes(c.struct_xrt_sys_json_opts);
    if (std.mem.eql(u8, name, "get_overview")) {
        try wire.fields(args, &.{ "limit", "redact" });
        opts.groups = c.XRT_SYS_ALL_GROUPS & ~group(c.XRT_SYS_G_CONNECTIONS);
        opts.sort = c.XRT_SYS_SORT_CPU;
        const limit = try wire.number(args, "limit", 10);
        if (limit == 0 or limit > 100) return error.InvalidArguments;
        opts.limit = @intCast(limit);
    } else if (std.mem.eql(u8, name, "list_processes")) {
        try wire.fields(args, &.{ "sort", "limit", "redact" });
        opts.groups = group(c.XRT_SYS_G_PROCESSES) | group(c.XRT_SYS_G_SUMMARY);
        opts.sort = c.XRT_SYS_SORT_CPU;
        if (args.object.get("sort")) |sort| {
            if (sort != .string) return error.InvalidArguments;
            const keys = [_]struct { []const u8, c_uint }{
                .{ "cpu", c.XRT_SYS_SORT_CPU }, .{ "memory", c.XRT_SYS_SORT_MEMORY },   .{ "io", c.XRT_SYS_SORT_IO },
                .{ "fds", c.XRT_SYS_SORT_FDS }, .{ "threads", c.XRT_SYS_SORT_THREADS }, .{ "start", c.XRT_SYS_SORT_START },
                .{ "pid", c.XRT_SYS_SORT_PID },
            };
            var found = false;
            for (keys) |key| if (std.mem.eql(u8, key[0], sort.string)) {
                opts.sort = key[1];
                found = true;
            };
            if (!found) return error.InvalidArguments;
        }
        const limit = try wire.number(args, "limit", 25);
        if (limit == 0 or limit > 500) return error.InvalidArguments;
        opts.limit = @intCast(limit);
    } else if (std.mem.eql(u8, name, "get_process")) {
        try wire.fields(args, &.{ "pid", "redact" });
        const pid = try wire.number(args, "pid", null);
        if (pid == 0 or pid > std.math.maxInt(i32)) return error.InvalidArguments;
        opts.groups = group(c.XRT_SYS_G_PROCESSES) | group(c.XRT_SYS_G_CONNECTIONS);
        opts.pid = @intCast(pid);
        opts.limit = 200;
    } else if (std.mem.eql(u8, name, "get_connections")) {
        try wire.fields(args, &.{ "limit", "pid", "redact" });
        opts.groups = group(c.XRT_SYS_G_CONNECTIONS);
        const limit = try wire.number(args, "limit", 100);
        if (limit == 0 or limit > 2000) return error.InvalidArguments;
        opts.limit = @intCast(limit);
        if (args.object.get("pid") != null) {
            const pid = try wire.number(args, "pid", null);
            if (pid == 0 or pid > std.math.maxInt(i32)) return error.InvalidArguments;
            opts.pid = @intCast(pid);
        }
    } else if (std.mem.eql(u8, name, "get_sensors")) {
        try wire.fields(args, &.{});
        opts.groups = group(c.XRT_SYS_G_POWER) | group(c.XRT_SYS_G_CPU) | group(c.XRT_SYS_G_DISKS);
    } else return error.UnknownTool;
    const redact = try boolean(args, "redact") or state.redact;
    const now = @import("../target/linux.zig").now();
    state.request(opts.groups, now);
    var snap = try state.snapshot();
    var redacted: ?*c.struct_xrt_sys_snapshot = null;
    defer if (redacted) |copy| {
        c.xrt_sys_snapshot_free(copy);
        std.heap.c_allocator.destroy(copy);
    };
    if (redact) {
        const copy = try std.heap.c_allocator.create(c.struct_xrt_sys_snapshot);
        copy.* = std.mem.zeroes(c.struct_xrt_sys_snapshot);
        redacted = copy;
        if (c.xrt_sys_snapshot_copy(copy, snap) != c.XRT_OK) return error.OutOfMemory;
        c.xrt_sys_snapshot_redact(copy);
        snap = copy;
    }
    const text = c.xrt_sys_json(snap, &opts) orelse return error.OutOfMemory;
    defer c.free(text);
    var result = try std.json.parseFromSliceLeaky(Value, a, std.mem.span(text), .{ .allocate = .alloc_always });
    var freshness = Value{ .object = .empty };
    for (state.sampled, 0..) |time, i| if (opts.groups & group(@intCast(i)) != 0) {
        var entry = Value{ .object = .empty };
        try entry.object.put(a, "sampled_monotonic_ns", if (time == 0) .null else .{ .integer = @intCast(time) });
        try entry.object.put(a, "age_ms", if (time == 0) .null else .{ .integer = @intCast((now -| time) / 1_000_000) });
        try entry.object.put(a, "pending", .{ .bool = time == 0 });
        try freshness.object.put(a, std.mem.span(c.xrt_sys_group_name(@intCast(i))), entry);
    };
    try result.object.put(a, "cache", freshness);
    try result.object.put(a, "process_detail_pending", .{ .bool = state.light and opts.groups & group(c.XRT_SYS_G_PROCESSES) != 0 });
    if (opts.pid > 0 and std.mem.eql(u8, name, "get_process")) {
        const rows = result.object.get("processes").?.object.get("rows").?.array.items;
        if (rows.len == 0 and snap.group[c.XRT_SYS_G_PROCESSES].st == c.XRT_SYS_OK) return error.UnknownProcess;
    }
    return result;
}

test "overview reads and explicit fd capture controls are advertised" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, definitions, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(16, parsed.value.array.items.len);
    for (parsed.value.array.items) |definition| {
        try std.testing.expect(handles(definition.object.get("name").?.string));
        try std.testing.expectEqual(!fd.isControl(definition.object.get("name").?.string), definition.object.get("annotations").?.object.get("readOnlyHint").?.bool);
    }
}

test "list_processes answers from the live system with explicit states" {
    var state: State = .{};
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args = Value{ .object = .empty };
    try args.object.put(a, "sort", .{ .string = "pid" });
    try args.object.put(a, "limit", .{ .integer = 3 });
    try args.object.put(a, "redact", .{ .bool = true });
    const pending = try call(a, &state, "list_processes", args);
    try std.testing.expectEqual(0, pending.object.get("sequence").?.integer);
    try std.testing.expect(try state.tick(@import("../target/linux.zig").now(), 0, false));
    const result = try call(a, &state, "list_processes", args);
    const processes = result.object.get("processes").?.object;
    try std.testing.expect(processes.get("count").?.integer > 0);
    try std.testing.expectEqual(3, processes.get("shown").?.integer);
    const row = processes.get("rows").?.array.items[0].object;
    try std.testing.expectEqualStrings("redacted", row.get("cmdline").?.object.get("why").?.string);
    try std.testing.expect(row.get("start_ticks").? == .integer);
    // cpu_pct is a measured number or an explicit state ("first sample"), never absent
    try std.testing.expect(row.get("cpu_pct") != null);
    var bad = Value{ .object = .empty };
    try bad.object.put(a, "sort", .{ .string = "bogus" });
    try std.testing.expectError(error.InvalidArguments, call(a, &state, "list_processes", bad));
    var missing = Value{ .object = .empty };
    try missing.object.put(a, "pid", .{ .integer = std.math.maxInt(i32) });
    try std.testing.expectError(error.UnknownProcess, call(a, &state, "get_process", missing));
}
