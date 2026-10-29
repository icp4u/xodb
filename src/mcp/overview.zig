//! Observer-only whole-system tools backed by the C sysstat collector. They
//! need no debug target; rates come from the previous observation.
const std = @import("std");
const c = @import("../c_ui.zig").api;
const wire = @import("profile.zig");
const Value = std.json.Value;

const fd = @import("fd.zig");
const memstat = @import("memstat.zig");
pub const definitions = @import("tool_catalog.zig").overview_definitions;

pub fn handles(name: []const u8) bool {
    if (std.mem.eql(u8, name, "get_kernel_stacks")) return true;
    if (@import("system_capture.zig").handles(name)) return true;
    if (std.mem.eql(u8, name, "get_layout")) return true;
    if (std.mem.eql(u8, name, "get_graph")) return true;
    if (fd.handles(name)) return true;
    if (@import("radio.zig").handles(name)) return true;
    for ([_][]const u8{ "get_overview", "list_processes", "get_process", "get_connections", "get_sensors", "get_history", "get_process_groups" }) |candidate|
        if (std.mem.eql(u8, name, candidate)) return true;
    return memstat.handles(name);
}

pub const State = @import("../model/system.zig").Collector;
const history = @import("../model/system_history.zig");

fn boolean(args: Value, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    if (v != .bool) return error.InvalidArguments;
    return v.bool;
}

fn group(id: c_uint) u32 {
    return @as(u32, 1) << @intCast(id);
}

pub fn call(a: std.mem.Allocator, state: *State, name: []const u8, args: Value) !Value {
    if (std.mem.eql(u8, name, "get_kernel_stacks")) return @import("kernel_census.zig").call(a, &state.kernel_census, args, state.redact);
    if (std.mem.eql(u8, name, "get_graph")) return @import("graph.zig").descriptors(a, state, args);
    if (@import("radio.zig").handles(name)) return @import("radio.zig").call(a, name, args, state.redact);
    if (fd.handles(name)) return fd.call(a, state, name, args);
    if (memstat.handles(name)) return memstat.call(a, state, name, args);
    if (std.mem.eql(u8, name, "get_history")) return historyCall(a, state, args);
    if (std.mem.eql(u8, name, "get_process_groups")) return groupsCall(a, state, args);
    var opts = std.mem.zeroes(c.struct_xrt_sys_json_opts);
    if (std.mem.eql(u8, name, "get_overview")) {
        try wire.fields(args, &.{ "limit", "redact", "sort", "filter", "offset" });
        opts.groups = c.XRT_SYS_ALL_GROUPS & ~group(c.XRT_SYS_G_CONNECTIONS);
        try processArgs(a, args, &opts);
        const limit = try wire.number(args, "limit", 10);
        if (limit == 0 or limit > 100) return error.InvalidArguments;
        opts.limit = @intCast(limit);
    } else if (std.mem.eql(u8, name, "list_processes")) {
        try wire.fields(args, &.{ "sort", "filter", "limit", "offset", "redact" });
        opts.groups = group(c.XRT_SYS_G_PROCESSES) | group(c.XRT_SYS_G_SUMMARY);
        try processArgs(a, args, &opts);
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
        try wire.fields(args, &.{ "limit", "offset", "pid", "filter", "redact" });
        opts.groups = group(c.XRT_SYS_G_CONNECTIONS);
        // Rows with owner hints run to ~2 KiB on the wire: 400 stay under the 1 MiB reply.
        const limit = try wire.number(args, "limit", 100);
        if (limit == 0 or limit > 400) return error.InvalidArguments;
        opts.limit = @intCast(limit);
        const offset = try wire.number(args, "offset", 0);
        if (offset > 1_000_000) return error.InvalidArguments;
        opts.offset = @intCast(offset);
        if (args.object.get("pid") != null) {
            const pid = try wire.number(args, "pid", null);
            if (pid == 0 or pid > std.math.maxInt(i32)) return error.InvalidArguments;
            opts.pid = @intCast(pid);
        }
        if (args.object.get("filter")) |filter| {
            try wire.fields(filter, &.{ "proto", "state", "uid", "external", "queued" });
            if (try string(filter, "proto")) |proto| opts.conn_proto = for ([_][]const u8{ "tcp", "udp", "unix" }, [_]u8{ c.XRT_SYS_TCP, c.XRT_SYS_UDP, c.XRT_SYS_UNIX }) |key, id| {
                if (std.mem.eql(u8, key, proto)) break id;
            } else return error.InvalidArguments;
            if (try string(filter, "state")) |text| {
                if (text.len == 0 or text.len > 15) return error.InvalidArguments;
                opts.conn_state = (try a.dupeZ(u8, text)).ptr;
            }
            if (filter.object.get("uid") != null) {
                const uid = try wire.number(filter, "uid", null);
                if (uid > std.math.maxInt(u32)) return error.InvalidArguments;
                opts.user = (try std.fmt.allocPrintSentinel(a, "{d}", .{uid}, 0)).ptr;
            }
            opts.conn_external = @intFromBool(try boolean(filter, "external"));
            opts.conn_queued = @intFromBool(try boolean(filter, "queued"));
        }
    } else if (std.mem.eql(u8, name, "get_sensors")) {
        try wire.fields(args, &.{});
        opts.groups = group(c.XRT_SYS_G_POWER) | group(c.XRT_SYS_G_CPU) | group(c.XRT_SYS_G_DISKS);
    } else return error.UnknownTool;
    const now = @import("../target/linux.zig").now();
    state.request(opts.groups, now);
    var view = try View.open(state, try boolean(args, "redact"));
    defer view.close();
    const snap = view.snap;
    const text = c.xrt_sys_json(snap, &opts) orelse return error.OutOfMemory;
    defer c.free(text);
    var result = try std.json.parseFromSliceLeaky(Value, a, std.mem.span(text), .{ .allocate = .alloc_always });
    try result.object.put(a, "cache", try freshness(a, state, opts.groups, now));
    try result.object.put(a, "process_detail_pending", .{ .bool = state.light and opts.groups & group(c.XRT_SYS_G_PROCESSES) != 0 });
    if (std.mem.eql(u8, name, "get_connections")) try ownerHints(a, &result, snap, state);
    if (opts.pid > 0 and std.mem.eql(u8, name, "get_process")) {
        const rows = result.object.get("processes").?.object.get("rows").?.array.items;
        if (rows.len == 0 and snap.group[c.XRT_SYS_G_PROCESSES].st == c.XRT_SYS_OK) return error.UnknownProcess;
    }
    return result;
}

/// The cache, or a redacted copy of it for this reply.
const View = struct {
    snap: *const c.struct_xrt_sys_snapshot,
    copy: ?*c.struct_xrt_sys_snapshot = null,
    fn open(state: *State, redact_arg: bool) !View {
        const snap = try state.snapshot();
        if (!(redact_arg or state.redact)) return .{ .snap = snap };
        const copy = try std.heap.c_allocator.create(c.struct_xrt_sys_snapshot);
        copy.* = std.mem.zeroes(c.struct_xrt_sys_snapshot);
        errdefer {
            c.xrt_sys_snapshot_free(copy);
            std.heap.c_allocator.destroy(copy);
        }
        if (c.xrt_sys_snapshot_copy(copy, snap) != c.XRT_OK) return error.OutOfMemory;
        c.xrt_sys_snapshot_redact(copy);
        return .{ .snap = copy, .copy = copy };
    }
    fn close(self: *View) void {
        if (self.copy) |copy| {
            c.xrt_sys_snapshot_free(copy);
            std.heap.c_allocator.destroy(copy);
        }
    }
};

fn freshness(a: std.mem.Allocator, state: *const State, groups: u32, now: u64) !Value {
    var result = Value{ .object = .empty };
    for (state.sampled, 0..) |time, i| if (groups & group(@intCast(i)) != 0) {
        var entry = Value{ .object = .empty };
        try entry.object.put(a, "sampled_monotonic_ns", if (time == 0) .null else .{ .integer = @intCast(time) });
        try entry.object.put(a, "age_ms", if (time == 0) .null else .{ .integer = @intCast((now -| time) / 1_000_000) });
        try entry.object.put(a, "pending", .{ .bool = time == 0 });
        try result.object.put(a, std.mem.span(c.xrt_sys_group_name(@intCast(i))), entry);
    };
    return result;
}

const sort_keys = [_]struct { []const u8, c_uint }{
    .{ "cpu", c.XRT_SYS_SORT_CPU }, .{ "rss", c.XRT_SYS_SORT_MEMORY },  .{ "memory", c.XRT_SYS_SORT_MEMORY },
    .{ "io", c.XRT_SYS_SORT_IO },   .{ "fds", c.XRT_SYS_SORT_FDS },     .{ "threads", c.XRT_SYS_SORT_THREADS },
    .{ "age", c.XRT_SYS_SORT_AGE }, .{ "start", c.XRT_SYS_SORT_START }, .{ "pid", c.XRT_SYS_SORT_PID },
};

fn string(args: Value, key: []const u8) !?[]const u8 {
    const v = args.object.get(key) orelse return null;
    if (v != .string) return error.InvalidArguments;
    return v.string;
}

/// sort, offset and filter {user, match, state} for process rows.
fn processArgs(a: std.mem.Allocator, args: Value, opts: *c.struct_xrt_sys_json_opts) !void {
    opts.sort = c.XRT_SYS_SORT_CPU;
    if (try string(args, "sort")) |sort| opts.sort = for (sort_keys) |key| {
        if (std.mem.eql(u8, key[0], sort)) break key[1];
    } else return error.InvalidArguments;
    const offset = try wire.number(args, "offset", 0);
    if (offset > 1_000_000) return error.InvalidArguments;
    opts.offset = @intCast(offset);
    const filter = args.object.get("filter") orelse return;
    try wire.fields(filter, &.{ "user", "match", "state" });
    if (try string(filter, "match")) |text| {
        if (text.len == 0 or text.len > 255) return error.InvalidArguments;
        opts.match = (try a.dupeZ(u8, text)).ptr;
    }
    if (try string(filter, "user")) |text| {
        if (text.len == 0 or text.len > 63) return error.InvalidArguments;
        opts.user = (try a.dupeZ(u8, text)).ptr;
    }
    if (try string(filter, "state")) |text| {
        if (text.len != 1 or std.mem.indexOfScalar(u8, "RSDZTtIXWPKx", text[0]) == null) return error.InvalidArguments;
        opts.state = @intCast(text[0]);
    }
}

fn float(args: Value, key: []const u8, default: f64) !f64 {
    const v = args.object.get(key) orelse return default;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| if (std.math.isFinite(x)) x else error.InvalidArguments,
        else => error.InvalidArguments,
    };
}

fn series(a: std.mem.Allocator, h: *history.History, column: usize, end: u64, step: u64, n: usize) !Value {
    const out = try a.alloc(?f64, n);
    h.buckets(column, end, step, out);
    var list = try std.json.Array.initCapacity(a, n);
    for (out) |v| list.appendAssumeCapacity(if (v) |x| .{ .float = @round(x * 1000) / 1000 } else .null);
    return .{ .array = list };
}

/// The collector groups that feed one history group.
fn historyGroups(g: history.Group) u32 {
    return switch (g) {
        .cpu => group(c.XRT_SYS_G_SUMMARY) | group(c.XRT_SYS_G_CPU),
        .per_cpu => group(c.XRT_SYS_G_CPU),
        .memory => group(c.XRT_SYS_G_MEMORY),
        .psi => group(c.XRT_SYS_G_CPU) | group(c.XRT_SYS_G_MEMORY) | group(c.XRT_SYS_G_DISKS),
        .disks => group(c.XRT_SYS_G_DISKS),
        .network => group(c.XRT_SYS_G_NETWORK),
        .processes => group(c.XRT_SYS_G_PROCESSES),
    };
}

fn historyCall(a: std.mem.Allocator, state: *State, args: Value) !Value {
    try wire.fields(args, &.{ "group", "seconds", "step", "pid", "redact" });
    const which = std.meta.stringToEnum(history.Group, (try string(args, "group")) orelse return error.InvalidArguments) orelse return error.InvalidArguments;
    const seconds = try float(args, "seconds", 60);
    if (seconds < 1 or seconds > 3600) return error.InvalidArguments;
    var step_s = try float(args, "step", @max(seconds / 120, @as(f64, @floatFromInt(state.fast_ns)) / 1e9));
    if (step_s < 0.1 or step_s > seconds) return error.InvalidArguments;
    // Bounded reply: widen the step rather than return more points.
    step_s = @max(step_s, seconds / history.max_points);
    const step: u64 = @intFromFloat(step_s * 1e9);
    const n: usize = @intFromFloat(@ceil(seconds / step_s - 1e-9));
    const now = @import("../target/linux.zig").now();
    state.request(historyGroups(which), now);
    const h = &state.history;
    var result = Value{ .object = .empty };
    try result.object.put(a, "group", .{ .string = @tagName(which) });
    try result.object.put(a, "seconds", .{ .float = seconds });
    try result.object.put(a, "step_s", .{ .float = step_s });
    try result.object.put(a, "capacity_rows", .{ .integer = history.rows });
    try result.object.put(a, "rows", .{ .integer = @intCast(h.len) });
    try result.object.put(a, "cache", try freshness(a, state, historyGroups(which), now));
    const end = h.newest() orelse {
        try result.object.put(a, "pending", .{ .bool = true });
        return result;
    };
    try result.object.put(a, "pending", .{ .bool = false });
    try result.object.put(a, "points", .{ .integer = @intCast(n) });
    try result.object.put(a, "newest_monotonic_ns", .{ .integer = @intCast(end) });
    try result.object.put(a, "newest_age_ms", .{ .integer = @intCast((now -| end) / 1_000_000) });
    try result.object.put(a, "retained_s", .{ .float = @as(f64, @floatFromInt(end - h.oldest().?)) / 1e9 });
    var times = try std.json.Array.initCapacity(a, n);
    for (0..n) |i| times.appendAssumeCapacity(.{ .float = -@as(f64, @floatFromInt(n - 1 - i)) * step_s });
    try result.object.put(a, "times_s", .{ .array = times });
    try result.object.put(a, "times_note", .{ .string = "bucket ends in seconds relative to the newest sample; each value is the mean of the samples in its bucket, null when none was measured" });
    var out = Value{ .object = .empty };
    switch (which) {
        .cpu, .memory, .psi => for (std.enums.values(history.Scalar)) |scalar| if (scalar.group() == which or (which == .cpu and scalar == .load1)) {
            try out.object.put(a, @tagName(scalar), try series(a, h, h.scalarColumn(scalar), end, step, n));
        },
        .per_cpu => for (0..h.cpus) |i| {
            try out.object.put(a, try std.fmt.allocPrint(a, "cpu{d}", .{i}), try series(a, h, h.cpuColumn(i), end, step, n));
        },
        .disks, .network => {
            const total = if (which == .disks) [_]history.Scalar{ .disk_read_bps, .disk_write_bps } else [_]history.Scalar{ .net_rx_bps, .net_tx_bps };
            for (total) |scalar| try out.object.put(a, @tagName(scalar), try series(a, h, h.scalarColumn(scalar), end, step, n));
            var devices = std.json.Array.init(a);
            const list = if (which == .disks) h.disks[0..h.disk_count] else h.nets[0..h.net_count];
            for (list, 0..) |device, slot| {
                var entry = Value{ .object = .empty };
                try entry.object.put(a, "name", .{ .string = try a.dupe(u8, device.name[0..device.len]) });
                var values = Value{ .object = .empty };
                const names: []const []const u8 = if (which == .disks) &history.disk_series else &history.net_series;
                for (names, 0..) |key, k| try values.object.put(a, key, try series(a, h, if (which == .disks) h.diskColumn(slot, k) else h.netColumn(slot, k), end, step, n));
                try entry.object.put(a, "series", values);
                try devices.append(entry);
            }
            try result.object.put(a, "devices", .{ .array = devices });
        },
        .processes => {
            const redact = try boolean(args, "redact") or state.redact;
            if (args.object.get("pid") != null) {
                const pid = try wire.number(args, "pid", null);
                if (pid == 0 or pid > std.math.maxInt(i32)) return error.InvalidArguments;
                const snap = try state.snapshot();
                const procs = if (snap.processes.proc == null) &[_]c.struct_xrt_sys_proc{} else snap.processes.proc[0..snap.processes.count];
                const p = history.find(procs, @intCast(pid), 0) orelse return error.UnknownProcess;
                try result.object.put(a, "tracked", .{ .bool = h.track(p, now, now + history.track_ns, true) != null });
            }
            var list = std.json.Array.init(a);
            for (h.tracked, 0..) |t, slot| {
                if (t.pid == 0) continue;
                if (args.object.get("pid")) |pid| if (pid.integer != t.pid) continue;
                var entry = Value{ .object = .empty };
                try entry.object.put(a, "pid", .{ .integer = t.pid });
                try entry.object.put(a, "start_ticks", .{ .integer = @intCast(t.start) });
                try entry.object.put(a, "comm", .{ .string = if (redact) "process" else try a.dupe(u8, std.mem.sliceTo(&t.comm, 0)) });
                try entry.object.put(a, "explicit", .{ .bool = t.explicit });
                var values = Value{ .object = .empty };
                for (history.process_series, 0..) |key, k| try values.object.put(a, key, try series(a, h, h.processColumn(slot, k), end, step, n));
                try entry.object.put(a, "series", values);
                try list.append(entry);
            }
            try result.object.put(a, "processes", .{ .array = list });
            try result.object.put(a, "tracking", .{ .string = "the top 8 by CPU and by RSS on each processes sample, plus pids requested here for 10 minutes; at most 64" });
        },
    }
    try result.object.put(a, "series", out);
    return result;
}

const Sum = struct {
    value: f64 = 0,
    unknown: u32 = 0,
    fn add(self: *Sum, v: anytype) void {
        if (v.st == c.XRT_SYS_OK or (@TypeOf(v) == c.struct_xrt_sys_u64 and v.st == c.XRT_SYS_STALE)) {
            self.value += if (@TypeOf(v) == c.struct_xrt_sys_f64) v.v else @floatFromInt(v.v);
        } else self.unknown += 1;
    }
};
const Rollup = struct {
    key: []const u8,
    root: ?*const c.struct_xrt_sys_proc = null,
    members: u32 = 0,
    cpu: Sum = .{},
    rss: Sum = .{},
    threads: Sum = .{},
    fds: Sum = .{},
    io: Sum = .{},
    top: ?*const c.struct_xrt_sys_proc = null,
};

/// The application a process belongs to: the topmost ancestor of the same
/// owner in the same process group (a shell job, a launched app with its
/// helpers). Kernel threads share kthreadd.
fn treeRoot(procs: []const c.struct_xrt_sys_proc, p: *const c.struct_xrt_sys_proc) *const c.struct_xrt_sys_proc {
    if (p.kernel_thread.st == c.XRT_SYS_OK and p.kernel_thread.v != 0) return history.find(procs, 2, 0) orelse p;
    var at = p;
    for (0..128) |_| {
        if (at.ppid.st != c.XRT_SYS_OK or at.ppid.v <= 1) break;
        const parent = history.find(procs, @intCast(at.ppid.v), 0) orelse break;
        if (parent.pgid == 0 or parent.pgid != at.pgid) break;
        if (parent.uid.st != at.uid.st or parent.uid.v != at.uid.v) break;
        at = parent;
    }
    return at;
}

fn groupsCall(a: std.mem.Allocator, state: *State, args: Value) !Value {
    try wire.fields(args, &.{ "by", "sort", "limit", "offset", "redact" });
    const by = (try string(args, "by")) orelse "tree";
    const tree = std.mem.eql(u8, by, "tree");
    if (!tree and !std.mem.eql(u8, by, "cgroup")) return error.InvalidArguments;
    const sort = (try string(args, "sort")) orelse "cpu";
    const sorts = [_][]const u8{ "cpu", "rss", "threads", "fds", "io", "members" };
    const sort_index = for (sorts, 0..) |key, i| {
        if (std.mem.eql(u8, key, sort)) break i;
    } else return error.InvalidArguments;
    const limit = try wire.number(args, "limit", 20);
    if (limit == 0 or limit > 200) return error.InvalidArguments;
    const offset = try wire.number(args, "offset", 0);
    const now = @import("../target/linux.zig").now();
    state.request(group(c.XRT_SYS_G_PROCESSES), now);
    var view = try View.open(state, try boolean(args, "redact"));
    defer view.close();
    const snap = view.snap;
    const procs = if (snap.processes.proc == null) &[_]c.struct_xrt_sys_proc{} else snap.processes.proc[0..snap.processes.count];
    var index: std.StringArrayHashMapUnmanaged(Rollup) = .empty;
    for (procs) |*p| {
        var key_buf: [32]u8 = undefined;
        const root = if (tree) treeRoot(procs, p) else null;
        const key = if (root) |r|
            try std.fmt.bufPrint(&key_buf, "{d}:{d}", .{ r.pid, r.start_ticks })
        else if (p.cgroup.st == c.XRT_SYS_OK) std.mem.sliceTo(&p.cgroup.s, 0) else "unavailable";
        const entry = try index.getOrPut(a, key);
        if (!entry.found_existing) {
            // The snapshot may be a redacted copy freed before the reply is written.
            entry.key_ptr.* = try a.dupe(u8, key);
            entry.value_ptr.* = .{ .key = entry.key_ptr.*, .root = root };
        }
        const r = entry.value_ptr;
        r.members += 1;
        r.cpu.add(p.cpu_pct);
        r.rss.add(p.rss);
        r.threads.add(p.threads);
        r.fds.add(p.fds);
        if (p.io_read_bps.st == c.XRT_SYS_OK and p.io_write_bps.st == c.XRT_SYS_OK) r.io.value += p.io_read_bps.v + p.io_write_bps.v else r.io.unknown += 1;
        if (r.top == null or (p.cpu_pct.st == c.XRT_SYS_OK and (r.top.?.cpu_pct.st != c.XRT_SYS_OK or p.cpu_pct.v > r.top.?.cpu_pct.v))) r.top = p;
    }
    const rollups = index.values();
    const Order = struct {
        k: usize,
        fn key(self: @This(), r: Rollup) f64 {
            return switch (self.k) {
                0 => r.cpu.value,
                1 => r.rss.value,
                2 => r.threads.value,
                3 => r.fds.value,
                4 => r.io.value,
                else => @floatFromInt(r.members),
            };
        }
        fn less(self: @This(), x: Rollup, y: Rollup) bool {
            return self.key(x) > self.key(y);
        }
    };
    std.mem.sort(Rollup, rollups, Order{ .k = sort_index }, Order.less);
    var rows = std.json.Array.init(a);
    const first = @min(offset, rollups.len);
    const last = @min(first + limit, rollups.len);
    for (rollups[first..last]) |r| {
        var row = Value{ .object = .empty };
        if (r.root) |root| {
            try row.object.put(a, "root", try wire.value(a, .{ .pid = root.pid, .start_ticks = root.start_ticks, .comm = std.mem.sliceTo(&root.comm, 0), .pgid = root.pgid }));
        } else try row.object.put(a, "cgroup", .{ .string = r.key });
        try row.object.put(a, "members", .{ .integer = r.members });
        inline for (.{ "cpu_pct", "rss", "threads", "fds", "io_bps" }, .{ "cpu", "rss", "threads", "fds", "io" }) |out_name, field| {
            const sum = @field(r, field);
            try row.object.put(a, out_name, if (sum.unknown == r.members) try wire.value(a, .{ .state = "unavailable", .why = "no member measured" }) else .{ .float = @round(sum.value * 100) / 100 });
            if (sum.unknown > 0 and sum.unknown < r.members) try row.object.put(a, out_name ++ "_unmeasured_members", .{ .integer = sum.unknown });
        }
        if (r.top) |top| try row.object.put(a, "busiest", try wire.value(a, .{ .pid = top.pid, .comm = std.mem.sliceTo(&top.comm, 0) }));
        try rows.append(row);
    }
    var result = Value{ .object = .empty };
    try result.object.put(a, "by", .{ .string = if (tree) "tree" else "cgroup" });
    try result.object.put(a, "sort", .{ .string = sort });
    try result.object.put(a, "rule", .{ .string = if (tree) "root = topmost ancestor with the same uid and process group; kernel threads group under kthreadd" else "processes with the same cgroup path" });
    try result.object.put(a, "processes", .{ .integer = @intCast(procs.len) });
    try result.object.put(a, "total", .{ .integer = @intCast(rollups.len) });
    try result.object.put(a, "offset", .{ .integer = @intCast(first) });
    try result.object.put(a, "shown", .{ .integer = @intCast(last - first) });
    try result.object.put(a, "next_offset", if (last < rollups.len) .{ .integer = @intCast(last) } else .null);
    try result.object.put(a, "rss_note", .{ .string = "sum of member RSS; shared pages count once per member" });
    try result.object.put(a, "groups", .{ .array = rows });
    try result.object.put(a, "cache", try freshness(a, state, group(c.XRT_SYS_G_PROCESSES), now));
    try result.object.put(a, "process_detail_pending", .{ .bool = state.light });
    return result;
}

/// For sockets whose owner is not visible: the owning uid and the visible
/// processes of that uid whose descriptor tables this account cannot read
/// (the only possible holders it knows of).
fn ownerHints(a: std.mem.Allocator, result: *Value, snap: *const c.struct_xrt_sys_snapshot, state: *const State) !void {
    const conns = result.object.getPtr("connections") orelse return;
    const rows = conns.object.getPtr("rows") orelse return;
    const procs = if (snap.processes.proc == null) &[_]c.struct_xrt_sys_proc{} else snap.processes.proc[0..snap.processes.count];
    const own = std.c.geteuid();
    for (rows.array.items) |*row| {
        const pid = row.object.get("pid") orelse continue;
        if (pid != .object) continue;
        const why = pid.object.get("why") orelse continue;
        if (why != .string or !std.mem.eql(u8, why.string, std.mem.span(c.xrt_sys_reason_text(c.XRT_SYS_WHY_NEEDS_PRIVILEGE)))) continue;
        const uid_value = row.object.get("uid") orelse continue;
        if (uid_value != .integer) continue;
        const uid = uid_value.integer;
        var hint = Value{ .object = .empty };
        try hint.object.put(a, "uid", .{ .integer = uid });
        try hint.object.put(a, "own_uid", .{ .bool = uid == own });
        var candidates = std.json.Array.init(a);
        var visible: u32 = 0;
        var unreadable: u32 = 0;
        for (procs) |*p| {
            if (p.uid.st != c.XRT_SYS_OK or p.uid.v != uid) continue;
            if (p.kernel_thread.st == c.XRT_SYS_OK and p.kernel_thread.v != 0) continue;
            visible += 1;
            if (p.fds.st == c.XRT_SYS_OK) continue; // read, and it did not hold the inode
            unreadable += 1;
            if (candidates.items.len < 8) try candidates.append(try wire.value(a, .{ .pid = p.pid, .comm = std.mem.sliceTo(&p.comm, 0), .fds = std.mem.span(c.xrt_sys_reason_text(p.fds.why)) }));
        }
        if (procs.len == 0) {
            try hint.object.put(a, "pending", .{ .string = "process table not sampled yet; poll get_connections again" });
        } else {
            try hint.object.put(a, "visible_processes_of_uid", .{ .integer = visible });
            try hint.object.put(a, "unreadable_fd_tables", .{ .integer = unreadable });
            try hint.object.put(a, "candidates", .{ .array = candidates });
        }
        try hint.object.put(a, "explain", .{ .string = if (uid == own)
            "your uid, but no readable descriptor table holds this socket; the candidates are your processes whose fd tables could not be read (non-dumpable or exited)"
        else
            "another uid: its descriptor tables need privilege, so the holder cannot be named; candidates are that uid's visible processes" });
        try row.object.put(a, "owner_hint", hint);
    }
    _ = state;
}

test "overview reads and explicit fd capture controls are advertised" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, definitions, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(28, parsed.value.array.items.len);
    for (parsed.value.array.items) |definition| {
        try std.testing.expect(handles(definition.object.get("name").?.string));
        const name = definition.object.get("name").?.string;
        const request = std.mem.eql(u8, name, "request_system_capture") or std.mem.eql(u8, name, "cancel_system_capture");
        try std.testing.expectEqual(!fd.isControl(name) and !request, definition.object.get("annotations").?.object.get("readOnlyHint").?.bool);
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
