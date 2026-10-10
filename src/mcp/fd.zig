//! Cached fd observers. No filesystem access, perf calls, sleeps or target control
//! occur in a tool call; the bounded C owner does sampling asynchronously.
const std = @import("std");
const c = @import("../c.zig").api;
const system = @import("../model/system.zig");
const wire = @import("profile.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub const definitions = @embedFile("fd_tools.json");
pub const event_cost = "exact mode slows all syscalls on this machine by roughly 10 % while active";
pub fn isControl(name: []const u8) bool {
    return std.mem.eql(u8, name, "start_fd_events") or std.mem.eql(u8, name, "stop_fd_events");
}
pub fn handles(name: []const u8) bool {
    if (isControl(name)) return true;
    inline for (.{ "get_fd_activity", "who_has_open", "get_fd_leaks", "get_deleted_open", "get_fd_inheritance", "get_fd_treemap" }) |known|
        if (std.mem.eql(u8, name, known)) return true;
    return false;
}
fn object() Value {
    return .{ .object = .empty };
}
fn string(a: Allocator, value: []const u8) !Value {
    return .{ .string = try a.dupe(u8, if (std.unicode.utf8ValidateSlice(value)) value else "unavailable: non-UTF-8 bytes") };
}
fn integer(a: Allocator, n: u64) !Value {
    return if (n <= std.math.maxInt(i64)) .{ .integer = @intCast(n) } else .{ .string = try std.fmt.allocPrint(a, "{d}", .{n}) };
}
fn real(n: f64) Value {
    return if (std.math.isFinite(n)) .{ .float = n } else .null;
}
fn set(a: Allocator, v: *Value, key: []const u8, n: u64) !void {
    try v.object.put(a, key, try integer(a, n));
}
fn text(a: Allocator, v: *Value, key: []const u8, s: []const u8) !void {
    try v.object.put(a, key, try string(a, s));
}
fn flag(a: Allocator, v: *Value, key: []const u8, yes: bool) !void {
    try v.object.put(a, key, .{ .bool = yes });
}
fn boolean(args: Value, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    if (v != .bool) return error.InvalidArguments;
    return v.bool;
}
fn decimal(args: Value, key: []const u8) !?u64 {
    const v = args.object.get(key) orelse return null;
    if (v != .string or v.string.len == 0 or v.string.len > 20) return error.InvalidArguments;
    for (v.string) |ch| if (ch < '0' or ch > '9') return error.InvalidArguments;
    return std.fmt.parseInt(u64, v.string, 10) catch error.InvalidArguments;
}
fn status(code: c.enum_xrt_status) []const u8 {
    return switch (code) {
        c.XRT_OK => "ok",
        c.XRT_STALE_SNAPSHOT => "pending",
        c.XRT_PERMISSION_DENIED => "needs privilege",
        c.XRT_PROCESS_GONE => "process identity unavailable or changed",
        c.XRT_OUT_OF_MEMORY => "out of memory",
        c.XRT_TOO_MANY_THREADS => "more than 32 threads",
        c.XRT_UNSUPPORTED_ARCHITECTURE => "native x86-64 required",
        else => "unavailable",
    };
}
fn path(s: *const c.struct_xrt_fd_snapshot, fd: c.struct_xrt_fd) []const u8 {
    if (fd.link >= s.strings_length or fd.link_length > s.strings_length - fd.link) return "";
    return s.strings[fd.link..][0..fd.link_length];
}
fn process(a: Allocator, p: c.struct_xrt_fd_process, redact: bool, now: u64) !Value {
    var out = object();
    try set(a, &out, "pid", @intCast(p.pid));
    try set(a, &out, "start_ticks", p.start);
    try text(a, &out, "name", if (redact) "redacted" else p.comm[0 .. std.mem.indexOfScalar(u8, &p.comm, 0) orelse p.comm.len]);
    try set(a, &out, "fds", p.count);
    try set(a, &out, "flags", p.flags);
    try flag(a, &out, "stale", p.flags & c.XRT_FDP_STALE != 0);
    try flag(a, &out, "quiet_hint", p.flags & c.XRT_FDP_QUIET != 0);
    try text(a, &out, "offset_progress_state", if (p.flags & c.XRT_FDP_OFFSETS_STALE != 0) "partial; cached offsets excluded" else if (p.interval_ns == 0) "first sample" else "measured");
    try set(a, &out, "age_ms", (now -| p.sampled_ns) / 1_000_000);
    try set(a, &out, "interval_ns", p.interval_ns);
    try set(a, &out, "opened_since_scan", p.opened);
    try set(a, &out, "closed_since_scan", p.closed);
    try out.object.put(a, "fd_delta", .{ .integer = p.d_count });
    const measured = p.interval_ns > 0 and p.flags & c.XRT_FDP_NO_IO == 0;
    try out.object.put(a, "logical_read_bytes_per_second", if (measured) real(p.read_rate) else .null);
    try out.object.put(a, "logical_write_bytes_per_second", if (measured) real(p.write_rate) else .null);
    try out.object.put(a, "offset_progress_per_second", if (p.interval_ns > 0 and p.flags & (c.XRT_FDP_STALE | c.XRT_FDP_OFFSETS_STALE) == 0) real(p.advance_rate) else .null);
    try out.object.put(a, "sampled_fd_changes_per_second", if (p.interval_ns > 0) real(p.churn_rate) else .null);
    try text(a, &out, "io_state", if (p.flags & c.XRT_FDP_NO_IO != 0) "unavailable" else if (p.interval_ns == 0) "first sample" else if (p.flags & c.XRT_FDP_STALE != 0) "stale" else "ok");
    try set(a, &out, "growth_above_window_low", p.growth);
    try flag(a, &out, "growth_candidate", p.flags & c.XRT_FDP_LEAKING != 0);
    var history = Value{ .array = std.json.Array.init(a) };
    for (0..@min(p.history.samples, c.XRT_FD_HISTORY)) |i| {
        var row = object();
        try set(a, &row, "elapsed_ms", p.history.ms[i]);
        try set(a, &row, "fds", p.history.fds[i]);
        try set(a, &row, "changes", p.history.churn[i]);
        try row.object.put(a, "logical_bytes_per_second", real(p.history.io[i]));
        try history.array.append(row);
    }
    try out.object.put(a, "history", history);
    return out;
}
fn descriptor(a: Allocator, s: *const c.struct_xrt_fd_snapshot, p: c.struct_xrt_fd_process, fd: c.struct_xrt_fd, redact: bool, now: u64) !Value {
    var out = object();
    const retained = p.flags & c.XRT_FDP_STALE != 0;
    const info_stale = retained or fd.flags & c.XRT_FD_INFO_STALE != 0;
    const path_stale = retained or fd.flags & c.XRT_FD_LINK_STALE != 0;
    const stat_stale = retained or fd.flags & c.XRT_FD_STAT_STALE != 0;
    try set(a, &out, "pid", @intCast(p.pid));
    try set(a, &out, "start_ticks", p.start);
    try set(a, &out, "fd", @intCast(fd.fd));
    try text(a, &out, "kind", std.mem.span(c.xrt_fd_kind_name(fd.kind)));
    const raw_path = path(s, fd);
    const path_ok = fd.flags & c.XRT_FD_LINK_CUT == 0 and std.unicode.utf8ValidateSlice(raw_path);
    try out.object.put(a, "path", if (redact) try string(a, "redacted") else if (path_ok) try string(a, raw_path) else .null);
    try text(a, &out, "path_state", if (redact) "redacted" else if (fd.flags & c.XRT_FD_LINK_CUT != 0) "truncated" else if (!path_ok) "non-UTF-8; query by device and inode" else if (path_stale) "stale" else "ok");
    try flag(a, &out, "path_truncated", fd.flags & c.XRT_FD_LINK_CUT != 0);
    try flag(a, &out, "deleted", fd.flags & c.XRT_FD_DELETED != 0);
    try flag(a, &out, "stale", retained or info_stale or path_stale or stat_stale);
    try set(a, &out, "age_ms", (now -| p.sampled_ns) / 1_000_000);
    const stat = fd.flags & c.XRT_FD_STAT != 0;
    try out.object.put(a, "device", if (stat) .{ .string = try std.fmt.allocPrint(a, "{d}", .{fd.device}) } else .null);
    try out.object.put(a, "inode", if (stat) .{ .string = try std.fmt.allocPrint(a, "{d}", .{fd.inode}) } else .null);
    try out.object.put(a, "size_bytes", if (stat) .{ .integer = fd.size } else .null);
    try out.object.put(a, "allocated_disk_bytes", if (stat) .{ .integer = fd.disk } else .null);
    try text(a, &out, "stat_state", if (!stat) "unavailable" else if (stat_stale) "stale" else "ok");
    const info = fd.flags & c.XRT_FD_INFO != 0;
    try out.object.put(a, "offset", if (info) try integer(a, fd.pos) else .null);
    try out.object.put(a, "open_flags", if (info) try integer(a, fd.open_flags) else .null);
    try text(a, &out, "fdinfo_state", if (!info) "unavailable" else if (info_stale) "stale" else "ok");
    try out.object.put(a, "offset_age_ms", if (info) try integer(a, (now -| fd.info_sampled_ns) / 1_000_000) else .null);
    try set(a, &out, "offset_interval_ns", fd.info_interval_ns);
    const progress = info and fd.info_interval_ns > 0 and fd.flags & c.XRT_FD_OPENED == 0;
    try out.object.put(a, "offset_advance", if (progress and !info_stale) try integer(a, fd.advance) else .null);
    try out.object.put(a, "offset_progress_per_second", if (progress and !info_stale) real(fd.rate) else .null);
    try text(a, &out, "source", "poll; offset progress is not exact file IO");
    return out;
}
const Sort = enum { pid, io, churn, fds };
const Order = struct {
    snapshot: *const c.struct_xrt_fd_snapshot,
    sort: Sort,
    fn less(ctx: Order, lhs: u32, rhs: u32) bool {
        const p = ctx.snapshot.processes[lhs];
        const q = ctx.snapshot.processes[rhs];
        const l: f64 = switch (ctx.sort) {
            .pid => 0,
            .io => p.read_rate + p.write_rate,
            .churn => p.churn_rate,
            .fds => @floatFromInt(p.count),
        };
        const r: f64 = switch (ctx.sort) {
            .pid => 0,
            .io => q.read_rate + q.write_rate,
            .churn => q.churn_rate,
            .fds => @floatFromInt(q.count),
        };
        return if (l != r) l > r else p.pid < q.pid;
    }
};
/// Server must authorize current control scope/lease before entering here.
pub fn control(a: Allocator, owner: *system.Collector, name: []const u8, args: Value) !Value {
    const start = std.mem.eql(u8, name, "start_fd_events");
    if (!start and !std.mem.eql(u8, name, "stop_fd_events")) return error.UnknownTool;
    try wire.fields(args, if (start) &.{ "pid", "start_ticks", "acknowledge_host_cost" } else &.{});
    const pid = if (start) try wire.number(args, "pid", null) else 0;
    const birth = if (start) try wire.number(args, "start_ticks", null) else 0;
    if (start and (pid == 0 or pid > std.math.maxInt(i32) or birth == 0)) return error.InvalidArguments;
    if (start and !try boolean(args, "acknowledge_host_cost")) return error.FdHostCostAcknowledgementRequired;
    const ctx = try owner.descriptors();
    const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .event_pid = @intCast(pid), .event_start = birth, .stop_events = if (start) 0 else 1 };
    const requested = c.xrt_fdactivity_request(ctx, &request);
    if (requested == c.XRT_INVALID_STATE) return error.FdEventScopeBusy;
    if (requested == c.XRT_STALE_SNAPSHOT) return error.FdCacheBusy;
    if (requested != c.XRT_OK) return error.FdCollectorUnavailable;
    var out = object();
    try text(a, &out, "state", if (start) "start or renewal requested" else "stop requested");
    try text(a, &out, "host_cost", event_cost);
    try set(a, &out, "demand_ms", if (start) 3000 else 0);
    return out;
}
fn appendInheritance(a: Allocator, s: *const c.struct_xrt_fd_snapshot, pid: u64, offset: u64, limit: u64, rows: *Value, out: *Value) !u64 {
    var comparisons: ?*c.struct_xrt_fdinherit = null;
    if (c.xrt_fdinherit_build(s, 262144, &comparisons) != c.XRT_OK) return error.FdComparisonUnavailable;
    defer c.xrt_fdinherit_free(comparisons);
    const view = comparisons.?;
    try text(a, out, "evidence", "sampled same-number, kind, device/inode match; inheritance and exec history unproved");
    try text(a, out, "fdinfo_demand", "fresh flags for reached rows; existing scan budget, no tracing");
    var counts = object();
    inline for (.{ "matched", "dropped", "stale", "cloexec", "no_cloexec", "flags_unknown", "parent_pairs", "parent_unavailable", "parent_unavailable_fds", "parent_denied", "parent_absent", "parent_reused", "no_parent_fd", "different_object", "identity_unknown" }) |field| try set(a, &counts, field, @field(view.*, field));
    try text(a, &counts, "parent_reasons", "parent_denied: fd table needs privilege; parent_absent: exited or hidden by hidepid; parent_reused: pid reused after the child");
    try out.object.put(a, "comparison_coverage", counts);
    var matches: u64 = 0;
    for (view.rows[0..view.count]) |r| {
        const child = s.processes[r.child];
        const parent = s.processes[r.parent];
        const fd = s.fds[r.child_fd];
        if (pid != 0 and child.pid != @as(i32, @intCast(pid))) continue;
        defer matches += 1;
        if (matches < offset or rows.array.items.len >= limit) continue;
        var row = object();
        var parent_id = object();
        var child_id = object();
        try set(a, &parent_id, "pid", @intCast(parent.pid));
        try set(a, &parent_id, "start_ticks", parent.start);
        try set(a, &child_id, "pid", @intCast(child.pid));
        try set(a, &child_id, "start_ticks", child.start);
        try row.object.put(a, "parent", parent_id);
        try row.object.put(a, "child", child_id);
        try set(a, &row, "fd", @intCast(fd.fd));
        try text(a, &row, "kind", std.mem.span(c.xrt_fd_kind_name(fd.kind)));
        try row.object.put(a, "device", .{ .string = try std.fmt.allocPrint(a, "{d}", .{fd.device}) });
        try row.object.put(a, "inode", .{ .string = try std.fmt.allocPrint(a, "{d}", .{fd.inode}) });
        try set(a, &row, "flags", r.flags);
        try row.object.put(a, "child_cloexec", if (r.flags & c.XRT_FDINH_CHILD_FLAGS_KNOWN != 0) .{ .bool = r.flags & c.XRT_FDINH_CHILD_CLOEXEC != 0 } else .null);
        try row.object.put(a, "parent_cloexec", if (r.flags & c.XRT_FDINH_PARENT_FLAGS_KNOWN != 0) .{ .bool = r.flags & c.XRT_FDINH_PARENT_CLOEXEC != 0 } else .null);
        try flag(a, &row, "stale", r.flags & (c.XRT_FDINH_PARENT_STALE | c.XRT_FDINH_CHILD_STALE | c.XRT_FDINH_IDENTITY_STALE) != 0);
        try rows.array.append(row);
    }
    return matches;
}
pub fn call(a: Allocator, owner: *system.Collector, name: []const u8, args: Value) !Value {
    if (std.mem.eql(u8, name, "get_fd_treemap")) return treemap(a, owner, args);
    const activity = std.mem.eql(u8, name, "get_fd_activity");
    const lookup = std.mem.eql(u8, name, "who_has_open");
    const leaks = std.mem.eql(u8, name, "get_fd_leaks");
    const inheritance = std.mem.eql(u8, name, "get_fd_inheritance");
    if (!activity and !lookup and !leaks and !inheritance and !std.mem.eql(u8, name, "get_deleted_open")) return error.UnknownTool;
    try wire.fields(args, if (activity) &.{ "limit", "offset", "sequence", "redact", "interval_ms", "pid", "mode", "start_ticks", "sort" } else if (lookup) &.{ "limit", "offset", "sequence", "redact", "interval_ms", "pid", "path", "device", "inode" } else &.{ "limit", "offset", "sequence", "redact", "interval_ms", "pid" });
    const limit = try wire.number(args, "limit", 50);
    const offset = try wire.number(args, "offset", 0);
    const sequence = try wire.number(args, "sequence", 0);
    const pid = try wire.number(args, "pid", 0);
    const interval = try wire.number(args, "interval_ms", 1000);
    if (limit == 0 or limit > 500 or offset > (if (inheritance) @as(u64, 262144) else 65536) or (offset != 0 and sequence == 0) or (args.object.contains("sequence") and sequence == 0) or (args.object.contains("pid") and pid == 0) or pid > std.math.maxInt(i32) or (interval != 250 and interval != 1000)) return error.InvalidArguments;
    const redact = try boolean(args, "redact") or owner.redact;
    var events = false;
    var sort: Sort = .io;
    if (args.object.get("mode")) |v| {
        if (v != .string) return error.InvalidArguments;
        if (std.mem.eql(u8, v.string, "events")) events = true else if (!std.mem.eql(u8, v.string, "poll")) return error.InvalidArguments;
    }
    if (args.object.get("sort")) |v| {
        if (v != .string) return error.InvalidArguments;
        sort = std.meta.stringToEnum(Sort, v.string) orelse return error.InvalidArguments;
    }
    const start = try wire.number(args, "start_ticks", 0);
    if ((events and (pid == 0 or start == 0)) or (!events and args.object.contains("start_ticks"))) return error.InvalidArguments;
    var wanted_path: ?[]const u8 = null;
    if (args.object.get("path")) |v| {
        if (v != .string or v.string.len == 0 or v.string.len > 4096 or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidArguments;
        if (redact) return error.FdPathLookupRedacted;
        wanted_path = v.string;
    }
    const device = try decimal(args, "device");
    const inode = try decimal(args, "inode");
    if (lookup and ((device == null) != (inode == null) or (wanted_path == null) == (device == null))) return error.InvalidArguments;
    const ctx = try owner.descriptors();
    const poll_pid: i32 = @intCast(pid);
    const request = c.struct_xrt_fdactivity_request{
        .interval_ms = @intCast(interval),
        .poll_pids = if (pid != 0) &poll_pid else null,
        .poll_pid_count = if (pid != 0) 1 else 0,
        .poll_all = if (pid == 0) 1 else 0,
        .fdinfo_all = @intFromBool(inheritance),
    };
    // Observer event reads neither start capture nor extend its lifetime.
    const requested: c.enum_xrt_status = if (events) c.XRT_OK else c.xrt_fdactivity_request(ctx, &request);
    if (requested == c.XRT_INVALID_STATE) return error.FdEventScopeBusy;
    if (requested != c.XRT_OK and requested != c.XRT_STALE_SNAPSHOT) return error.FdCollectorUnavailable;
    var view: c.struct_xrt_fdactivity_view = undefined;
    if (c.xrt_fdactivity_acquire(ctx, &view) == 0) return error.FdCacheBusy;
    defer c.xrt_fdactivity_release(ctx);
    var out = object();
    try text(a, &out, "mode", if (events) "events" else "poll");
    try flag(a, &out, "redacted", redact);
    try flag(a, &out, "exact_mode_active", view.event.running != 0);
    try flag(a, &out, "exact_mode_requested", view.event_requested != 0);
    try text(a, &out, "host_cost", event_cost);
    try flag(a, &out, "request_pending", requested != c.XRT_OK);
    try set(a, &out, "owner_cpu_ns", view.owner_cpu_ns);
    try set(a, &out, "interval_ms", view.interval_ms);
    try set(a, &out, "collector_instances", owner.fd_opens);
    // Status only: observer polling never requests or renews graph tracing.
    const flow = try flowStatus(a, view.flow);
    try out.object.put(a, "system_flow", flow);
    var rows = Value{ .array = std.json.Array.init(a) };
    var matches: u64 = 0;
    const now = @import("../target/linux.zig").now();
    if (events) {
        const e = view.event;
        const pending = view.event_generation == 0 or view.event_generation != view.requested_event_generation or e.pid != @as(i32, @intCast(pid)) or e.start_ticks != start or view.event_status == c.XRT_STALE_SNAPSHOT;
        try text(a, &out, "state", if (pending) (if (view.event_requested != 0) "pending" else "inactive; requires start_fd_events with control and host-cost acknowledgement") else status(view.event_status));
        try set(a, &out, "sequence", view.event_sequence);
        try set(a, &out, "capture_generation", view.event_generation);
        try flag(a, &out, "running", !pending and e.running != 0);
        try flag(a, &out, "drain_pending", !pending and e.pending != 0);
        try set(a, &out, "pid", pid);
        try set(a, &out, "start_ticks", start);
        if (!pending) {
            if (sequence != 0 and sequence != view.event_sequence) return error.FdSnapshotChanged;
            try text(a, &out, "coverage", if (e.reason != null) std.mem.span(e.reason) else "not available");
            try text(a, &out, "limit", "Native x86-64 syscall pairs in the original selected threads only; ABI-switching assembly, mmap and io_uring transfers are not covered. Rows span fd reuse; there is no current-path attribution.");
            try set(a, &out, "flags", e.flags);
            try set(a, &out, "lost", e.lost);
            try flag(a, &out, "possible_loss", e.flags & c.XRT_FDEVENT_POSSIBLE_LOSS != 0);
            try flag(a, &out, "loss_accounting_available", e.flags & c.XRT_FDEVENT_LOSS_UNAVAILABLE == 0);
            try text(a, &out, "loss_state", if (e.flags & c.XRT_FDEVENT_LOSS != 0) "known loss; counters are incomplete" else if (e.flags & c.XRT_FDEVENT_POSSIBLE_LOSS != 0) "possible loss; ring approached capacity" else if (e.flags & c.XRT_FDEVENT_LOSS_UNAVAILABLE != 0) "loss accounting unavailable; completeness is unproved" else "no loss observed");
            try set(a, &out, "unpaired", e.unpaired);
            try set(a, &out, "invalid", e.invalid);
            try set(a, &out, "dropped_rows", e.dropped_rows);
            try set(a, &out, "threads", e.threads);
            try set(a, &out, "ring_bytes", e.ring_bytes);
            try set(a, &out, "started_ns", e.started_ns);
            try set(a, &out, "taken_ns", e.taken_ns);
            try out.object.put(a, "errno", .{ .integer = view.event_failure.@"error" });
            if (view.event_status != c.XRT_OK and view.event_failure.syscall != null) {
                var line: [320]u8 = undefined;
                try text(a, &out, "failure", system.failureText(&line, view.event_failure));
                if (system.failureRemedy(view.event_failure)) |remedy| try text(a, &out, "remedy", remedy);
            }
            for (e.rows[0..e.row_count]) |r| {
                if (matches >= offset and rows.array.items.len < limit) {
                    var row = object();
                    try set(a, &row, "fd", @intCast(r.fd));
                    inline for (.{ "read_bytes", "write_bytes", "read_calls", "write_calls", "open_returns", "close_successes", "dup_returns" }) |field|
                        try set(a, &row, field, @field(r, field));
                    try rows.array.append(row);
                }
                matches += 1;
            }
        }
    } else if (view.poll) |ptr| {
        const s: *const c.struct_xrt_fd_snapshot = @ptrCast(ptr);
        if (sequence != 0 and sequence != s.sequence) return error.FdSnapshotChanged;
        try text(a, &out, "state", status(view.poll_status));
        try set(a, &out, "sequence", s.sequence);
        try set(a, &out, "age_ms", (now -| s.taken_ns) / 1_000_000);
        try flag(a, &out, "active", view.poll_active != 0);
        var coverage = object();
        inline for (.{ "process_count", "fd_count", "hidden", "kernel_threads", "unscanned", "gone", "stale", "dropped_processes", "dropped_fds", "cut_strings", "scan_ns", "scan_cpu_ns" }) |field| try set(a, &coverage, field, @field(s.*, field));
        try out.object.put(a, "coverage", coverage);
        if (pid != 0) {
            var scope = object();
            try text(a, &scope, "state", "not in cache; inspect partial coverage");
            for (s.processes[0..s.process_count]) |p| if (p.pid == @as(i32, @intCast(pid))) {
                try text(a, &scope, "state", if (p.flags & c.XRT_FDP_STALE != 0) "stale" else "sampled");
                try set(a, &scope, "start_ticks", p.start);
                try set(a, &scope, "fds", p.count);
                try flag(a, &scope, "truncated", p.flags & c.XRT_FDP_TRUNCATED != 0);
                break;
            };
            for (s.unseen[0..s.unseen_count]) |p| if (p.pid == @as(i32, @intCast(pid))) {
                try text(a, &scope, "state", if (p.kernel != 0) "kernel task has no user fd table" else "fd table unavailable");
                try set(a, &scope, "start_ticks", p.start);
                try flag(a, &scope, "stale", p.stale != 0);
                break;
            };
            try out.object.put(a, "scope", scope);
        }
        if (inheritance) {
            matches = try appendInheritance(a, s, pid, offset, limit, &rows, &out);
        } else {
            const indices = try a.alloc(u32, s.process_count);
            for (indices, 0..) |*index, i| index.* = @intCast(i);
            std.mem.sortUnstable(u32, indices, Order{ .snapshot = s, .sort = sort }, Order.less);
            for (indices) |index| {
                const p = s.processes[index];
                if (pid != 0 and p.pid != @as(i32, @intCast(pid))) continue;
                if (leaks or (activity and pid == 0)) {
                    if (leaks and p.flags & c.XRT_FDP_LEAKING == 0) continue;
                    if (matches >= offset and rows.array.items.len < limit) try rows.array.append(try process(a, p, redact, now));
                    matches += 1;
                    continue;
                }
                for (s.fds[p.first..][0..p.count]) |fd| {
                    if (!activity and !lookup and fd.flags & c.XRT_FD_DELETED == 0) continue;
                    if (lookup) {
                        if (wanted_path) |wanted| {
                            if (fd.flags & c.XRT_FD_LINK_CUT != 0 or !std.mem.eql(u8, path(s, fd), wanted)) continue;
                        } else if (fd.flags & c.XRT_FD_STAT == 0 or fd.device != device.? or fd.inode != inode.?) continue;
                    }
                    if (matches >= offset and rows.array.items.len < limit) try rows.array.append(try descriptor(a, s, p, fd, redact, now));
                    matches += 1;
                }
            }
        }
    } else {
        try text(a, &out, "state", status(view.poll_status));
        try set(a, &out, "sequence", 0);
    }
    try set(a, &out, "matches_in_cache", matches);
    try set(a, &out, "offset", offset);
    const next = offset + rows.array.items.len;
    try out.object.put(a, "next_offset", if (next < matches) try integer(a, next) else .null);
    try out.object.put(a, "rows", rows);
    return out;
}

test "fd reads are observer tools and capture controls require a lease" {
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, definitions, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(8, parsed.value.array.items.len);
    for (parsed.value.array.items) |tool| {
        try std.testing.expect(handles(tool.object.get("name").?.string));
        const annotations = tool.object.get("annotations").?.object;
        const controlled = isControl(tool.object.get("name").?.string);
        try std.testing.expectEqual(!controlled, annotations.get("readOnlyHint").?.bool);
        try std.testing.expectEqualStrings(if (controlled) "controller" else "observer", annotations.get("xodbSessionAccess").?.string);
    }
}

test "fd observers validate scope before starting an owner" {
    var owner: system.Collector = .{};
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "get_fd_activity", .args = "{\"mode\":\"events\",\"pid\":12}" },
        .{ .name = "get_fd_activity", .args = "{\"pid\":0}" },
        .{ .name = "get_fd_activity", .args = "{\"start_ticks\":2}" },
        .{ .name = "get_fd_activity", .args = "{\"offset\":1}" },
        .{ .name = "get_fd_activity", .args = "{\"limit\":501}" },
        .{ .name = "get_fd_activity", .args = "{\"interval_ms\":1}" },
        .{ .name = "who_has_open", .args = "{}" },
        .{ .name = "who_has_open", .args = "{\"path\":\"fixture\",\"device\":\"1\",\"inode\":\"2\"}" },
        .{ .name = "who_has_open", .args = "{\"device\":\"1\"}" },
        .{ .name = "who_has_open", .args = "{\"device\":\"-1\",\"inode\":\"2\"}" },
        .{ .name = "get_deleted_open", .args = "{\"mode\":\"events\"}" },
    };
    for (cases) |case| {
        const args = try std.json.parseFromSliceLeaky(Value, a, case.args, .{});
        try std.testing.expectError(error.InvalidArguments, call(a, &owner, case.name, args));
        try std.testing.expect(owner.fd_collector == null and owner.fd_opens == 0);
    }
}

test "fd replies redact names and paths and preserve unavailable values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = std.mem.zeroes(c.struct_xrt_fd_process);
    p.pid = 123;
    p.start = 456;
    p.sampled_ns = 1000;
    @memcpy(p.comm[0..12], "private-demo");
    const proc = try process(a, p, true, 2000);
    try std.testing.expectEqualStrings("redacted", proc.object.get("name").?.string);
    try std.testing.expect(proc.object.get("logical_read_bytes_per_second").? == .null);
    var s = std.mem.zeroes(c.struct_xrt_fd_snapshot);
    const link = "/fixture/confidential-path";
    s.strings = link.ptr;
    s.strings_length = link.len;
    var fd = std.mem.zeroes(c.struct_xrt_fd);
    fd.fd = 3;
    fd.link_length = link.len;
    const row = try descriptor(a, &s, p, fd, true, 2000);
    try std.testing.expectEqualStrings("redacted", row.object.get("path").?.string);
    for ([_][]const u8{ "device", "inode", "size_bytes", "allocated_disk_bytes", "offset", "offset_advance", "offset_progress_per_second" }) |field|
        try std.testing.expect(row.object.get(field).? == .null);
    fd.flags = c.XRT_FD_STAT | c.XRT_FD_INFO;
    fd.inode = std.math.maxInt(u64);
    const measured = try descriptor(a, &s, p, fd, false, 2000);
    try std.testing.expectEqualStrings("18446744073709551615", measured.object.get("inode").?.string);
    try std.testing.expectEqualStrings(link, measured.object.get("path").?.string);
    try std.testing.expect(measured.object.get("offset_progress_per_second").? == .null);
    fd.info_interval_ns = 1_000_000_000;
    fd.info_sampled_ns = 1000;
    fd.rate = 10;
    fd.flags |= c.XRT_FD_INFO_STALE | c.XRT_FD_LINK_STALE | c.XRT_FD_STAT_STALE;
    const cached = try descriptor(a, &s, p, fd, false, 2_000_001_000);
    try std.testing.expect(cached.object.get("stale").?.bool);
    for ([_][]const u8{ "path_state", "fdinfo_state", "stat_state" }) |field|
        try std.testing.expectEqualStrings("stale", cached.object.get(field).?.string);
    try std.testing.expect(cached.object.get("offset_advance").? == .null);
    try std.testing.expect(cached.object.get("offset_progress_per_second").? == .null);
    try std.testing.expectEqual(@as(i64, 2000), cached.object.get("offset_age_ms").?.integer);
    const invalid_path = [_]u8{0xff};
    s.strings = &invalid_path;
    s.strings_length = 1;
    fd.link_length = 1;
    const invalid = try descriptor(a, &s, p, fd, false, 2000);
    try std.testing.expect(invalid.object.get("path").? == .null);
    try std.testing.expectEqualStrings("non-UTF-8; query by device and inode", invalid.object.get("path_state").?.string);
    const safe_json = try std.json.Stringify.valueAlloc(a, invalid, .{});
    try std.testing.expect(std.unicode.utf8ValidateSlice(safe_json));
}

test "path guesses refused under request or owner redaction before collection" {
    var owner: system.Collector = .{};
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"path\":\"/fixture/secret\",\"redact\":true}", "{\"path\":\"/fixture/secret\",\"redact\":false}" }, 0..) |input, i| {
        owner.redact = i == 1;
        const args = try std.json.parseFromSlice(Value, a, input, .{});
        try std.testing.expectError(error.FdPathLookupRedacted, call(a, &owner, "who_has_open", args.value));
        try std.testing.expectEqual(0, owner.fd_opens);
    }
}

fn flowStatus(a: Allocator, sample: c.struct_xrt_fdflow_live) !Value {
    var flow = object();
    try flag(a, &flow, "running", sample.stream.running != 0);
    try flag(a, &flow, "requested", sample.requested != 0);
    try text(a, &flow, "state", status(sample.status));
    try text(a, &flow, "host_cost", system.graph_cost);
    try text(a, &flow, "identity", "sampled inode correlation; uncertain bytes remain unattributed");
    try text(a, &flow, "scope", if (sample.stream.scoped != 0) "explicit process thread scope at capture start" else "all processes on enrolled CPUs");
    try set(a, &flow, "active_cpus", if (sample.stream.running != 0) sample.stream.active_cpus else 0);
    try set(a, &flow, "enrolled_cpus", sample.stream.active_cpus);
    try set(a, &flow, "online_cpus", sample.stream.online_cpus);
    try set(a, &flow, "generation", sample.generation);
    try set(a, &flow, "sequence", sample.sequence);
    try set(a, &flow, "flags", sample.stream.flags);
    try set(a, &flow, "counter_flags", sample.counts.flags);
    try set(a, &flow, "lost", sample.stream.lost);
    try set(a, &flow, "read_bytes", sample.counts.read_bytes);
    try set(a, &flow, "write_bytes", sample.counts.write_bytes);
    try set(a, &flow, "unknown_read", sample.counts.unknown_read);
    try set(a, &flow, "unknown_write", sample.counts.unknown_write);
    if (sample.failure.detail != null) {
        var failure_line: [320]u8 = undefined;
        try text(a, &flow, "failure", system.failureText(&failure_line, sample.failure));
    }
    return flow;
}
fn treeMetric(a: Allocator, m: c.struct_xrt_fdtreemap_metric) !Value {
    var out = object();
    inline for (.{ "descriptors", "stale", "deleted", "unknown_paths", "stale_paths", "offset_measured", "flow_measured", "unexpanded", "flags", "read_bytes", "write_bytes", "last_ns" }) |field| try set(a, &out, field, @field(m, field));
    try out.object.put(a, "read_bytes_per_second", if (m.flow_measured > 0) real(m.read_rate) else .null);
    try out.object.put(a, "write_bytes_per_second", if (m.flow_measured > 0) real(m.write_rate) else .null);
    try out.object.put(a, "offset_progress_per_second", if (m.offset_measured > 0) real(m.offset_rate) else .null);
    return out;
}
fn treePath(a: Allocator, out: *Value, t: *const c.struct_xrt_fdtreemap, node: u32, redact: bool) !void {
    if (node >= t.count) {
        try out.object.put(a, "namespace_kind", .null);
        try out.object.put(a, "path", .null);
        try out.object.put(a, "path_hex", .null);
        try text(a, out, "path_state", "combined omitted entries; no single path");
        return;
    }
    try set(a, out, "namespace_kind", t.nodes[node].kind);
    var buffer: [4098]u8 = undefined;
    var needed: usize = 0;
    const valid = !redact and c.xrt_fdtreemap_path(t, node, &buffer, buffer.len, &needed) == c.XRT_OK;
    const bytes = if (valid) buffer[0 .. needed - 1] else "";
    try out.object.put(a, "path", if (valid and bytes.len <= 512 and std.unicode.utf8ValidateSlice(bytes)) try string(a, bytes) else .null);
    if (valid) {
        const hex = try a.alloc(u8, bytes.len * 2);
        const digits = "0123456789abcdef";
        for (bytes, 0..) |byte, i| {
            hex[i * 2] = digits[byte >> 4];
            hex[i * 2 + 1] = digits[byte & 15];
        }
        try out.object.put(a, "path_hex", .{ .string = hex });
    } else try out.object.put(a, "path_hex", .null);
    try text(a, out, "path_state", if (redact) "redacted" else if (!valid) "unavailable" else if (bytes.len > 512) "long path; exact bytes in path_hex" else if (!std.unicode.utf8ValidateSlice(bytes)) "non-UTF-8; exact bytes in path_hex" else if (t.nodes[node].kind != 0) "synthetic kind bucket; not a filesystem path" else "literal sampled spelling");
}
fn treemap(a: Allocator, owner: *system.Collector, args: Value) !Value {
    try wire.fields(args, &.{ "node", "sequence", "limit", "redact" });
    const node = try wire.number(args, "node", 0);
    const sequence = try wire.number(args, "sequence", 0);
    const limit = try wire.number(args, "limit", 16);
    if (node >= 4096 or limit == 0 or limit > 32 or (node != 0 and sequence == 0) or (args.object.contains("sequence") and sequence == 0)) return error.InvalidArguments;
    const redact = try boolean(args, "redact") or owner.redact;
    const ctx = try owner.descriptors();
    // Poll demand only: observing live metrics must not renew capture.
    // poll_all already refreshes seekable offsets each scan; no fdinfo_all.
    const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .poll_all = 1 };
    const requested = c.xrt_fdactivity_request(ctx, &request);
    if (requested != c.XRT_OK and requested != c.XRT_STALE_SNAPSHOT) return error.FdCollectorUnavailable;
    var view: c.struct_xrt_fdactivity_view = undefined;
    if (c.xrt_fdactivity_acquire(ctx, &view) == 0) return error.FdCacheBusy;
    var tree: ?*c.struct_xrt_fdtreemap = null;
    defer c.xrt_fdtreemap_free(tree);
    var holder: c.struct_xrt_fdtreemap_holder = std.mem.zeroes(c.struct_xrt_fdtreemap_holder);
    var snapshot: ?*c.struct_xrt_fd_snapshot = null;
    var flow: ?*c.struct_xrt_fdflow_live = null;
    {
        // Copy under the lock, build after release: the flow drain waits on it.
        defer c.xrt_fdactivity_release(ctx);
        const poll: *const c.struct_xrt_fd_snapshot = if (view.poll != null) @ptrCast(view.poll) else return error.FdSnapshotPending;
        if (sequence != 0 and sequence != poll.sequence) return error.FdSnapshotChanged;
        snapshot = c.xrt_fd_snapshot_copy(poll) orelse return error.OutOfMemory;
        flow = c.xrt_fdflow_live_copy(&view.flow) orelse {
            c.xrt_fd_snapshot_free(snapshot);
            return error.OutOfMemory;
        };
    }
    {
        defer c.xrt_fd_snapshot_free(snapshot);
        defer c.xrt_fdflow_live_free(flow);
        const options = c.struct_xrt_fdtreemap_options{ .max_nodes = 4096, .max_text = 1024 * 1024, .max_depth = 32 };
        if (c.xrt_fdtreemap_build(snapshot, flow, &options, &tree) != c.XRT_OK) return error.FdTreemapUnavailable;
        if (node >= tree.?.count) return error.InvalidArguments;
        _ = c.xrt_fdtreemap_holder(tree, @intCast(node), &holder);
    }
    // Only owned tree data and by-value publication status are used below.
    const t = tree.?;
    var layout: ?*c.struct_xrt_fdtreemap_layout = null;
    if (c.xrt_fdtreemap_layout(t, @intCast(node), @intCast(limit), 1.6, &layout) != c.XRT_OK) return error.FdTreemapUnavailable;
    defer c.xrt_fdtreemap_layout_free(layout);
    var out = object();
    try text(a, &out, "state", status(view.poll_status));
    try text(a, &out, "evidence", "area is descriptor count; literal path aggregation can combine different inodes/namespaces; sampled syscall identity, not exact file IO");
    try text(a, &out, "limits", "4096 nodes, 1 MiB names, 32 components; capped descriptors remain unexpanded at the nearest represented ancestor");
    try flag(a, &out, "redacted", redact);
    try set(a, &out, "sequence", t.sequence);
    try set(a, &out, "taken_ns", t.taken_ns);
    try set(a, &out, "node", node);
    try out.object.put(a, "parent", if (node != 0) try integer(a, t.nodes[node].parent) else .null);
    try treePath(a, &out, t, @intCast(node), redact);
    try out.object.put(a, "metric", try treeMetric(a, t.nodes[node].total));
    try out.object.put(a, "system_flow", try flowStatus(a, view.flow));
    var counts = object();
    inline for (.{ "fd_count", "count", "text_length", "matched_rows", "unmatched_rows", "dropped_processes", "dropped_fds", "unscanned", "gone", "denied", "flow_flags", "count_flags", "allocated_bytes" }) |field| try set(a, &counts, field, @field(t.*, field));
    try out.object.put(a, "coverage", counts);
    var sample = object();
    if (holder.pid > 0) {
        try set(a, &sample, "pid", @intCast(holder.pid));
        try set(a, &sample, "start_ticks", holder.start);
        try set(a, &sample, "fd", @intCast(holder.fd));
        try text(a, &sample, "evidence", "one sampled holder of this subtree; use its process Files table");
    }
    try out.object.put(a, "sample_holder", if (holder.pid > 0) sample else .null);
    var tiles = Value{ .array = std.json.Array.init(a) };
    for (layout.?.tiles[0..layout.?.count]) |tile| {
        var row = object();
        try row.object.put(a, "node", if (tile.node < t.count) try integer(a, tile.node) else .null);
        try text(a, &row, "kind", switch (tile.kind) {
            c.XRT_FDT_CHILD => "child",
            c.XRT_FDT_DIRECT => "direct",
            c.XRT_FDT_OVERFLOW => "unexpanded",
            else => "other",
        });
        try set(a, &row, "hidden_items", tile.hidden_items);
        try treePath(a, &row, t, tile.node, redact);
        try row.object.put(a, "metric", try treeMetric(a, tile.metric));
        inline for (.{ "x", "y", "w", "h" }) |field| try row.object.put(a, field, real(@field(tile, field)));
        try tiles.array.append(row);
    }
    try out.object.put(a, "tiles", tiles);
    return out;
}
