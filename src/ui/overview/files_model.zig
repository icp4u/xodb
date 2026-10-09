//! Owned presentation snapshot of the shared background descriptor collector.
//! Rendering never holds the collector's publication lock or scans procfs.
const std = @import("std");
const c = @import("../../c.zig").api;
const system = @import("../../model/system.zig");
const Collector = system.Collector;
pub const Mode = enum { files, processes, leaks, deleted, events };
pub const Identity = struct { pid: i32, start: u64 };
pub const Selection = struct { owner: Identity, fd: i32 = -1 };
pub const Row = union(enum) { process: u32, descriptor: struct { process: u32, fd: u32 }, event: u32 };
pub const Sort = enum { activity, count, pid };
pub const State = struct {
    snapshot: ?*c.struct_xrt_fd_snapshot = null,
    event: c.struct_xrt_fdevent_snapshot = std.mem.zeroes(c.struct_xrt_fdevent_snapshot),
    event_rows: std.ArrayList(c.struct_xrt_fdevent_row) = .empty,
    rows: std.ArrayList(Row) = .empty,
    mode: Mode = .files,
    sort: Sort = .activity,
    reverse: bool = false,
    filter: ?Identity = null,
    file_filter: ?struct { device: u64, inode: u64 } = null,
    event_target: ?Identity = null,
    event_generation: u64 = 0,
    event_sequence: u64 = 0,
    event_authorized: bool = false,
    stop_requested: bool = false,
    exact_active: bool = false,
    exact_requested: bool = false,
    event_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    poll_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    failure: [320]u8 = @splat(0),
    failure_len: usize = 0,
    remedy: ?[]const u8 = null,
    requested_at: u64 = 0,
    owner_cpu_ns: u64 = 0,
    owner_instances: u64 = 0,
    interval_ms: u32 = 1000,
    active_interval_ms: u32 = 1000,
    selected: ?Selection = null,
    selected_row: usize = 0,
    top: usize = 0,
    visible: usize = 12,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    searching: bool = false,
    dirty: bool = true,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        if (self.snapshot) |s| c.xrt_fd_snapshot_free(s);
        self.event_rows.deinit(a);
        self.rows.deinit(a);
        self.* = .{};
    }
    pub fn stopCapture(self: *State) void {
        self.event_authorized = false;
        self.stop_requested = true;
        self.requested_at = 0;
    }
    /// Live capture status remains visible even while the presentation is frozen.
    /// This never opens an owner or requests capture, and can run on every panel.
    pub fn refreshStatus(self: *State, owner: *Collector) bool {
        const ctx = owner.fd_collector orelse return false;
        if (self.stop_requested) {
            const request = c.struct_xrt_fdactivity_request{ .interval_ms = self.interval_ms, .stop_events = 1 };
            if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) self.stop_requested = false;
        }
        var view: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(ctx, &view) == 0) return false;
        defer c.xrt_fdactivity_release(ctx);
        const changed = self.exact_active != (view.event.running != 0) or self.exact_requested != (view.event_requested != 0);
        self.exact_active = view.event.running != 0;
        self.exact_requested = view.event_requested != 0;
        return changed;
    }
    pub fn refresh(self: *State, a: std.mem.Allocator, owner: *Collector, now: u64, paused: bool) !bool {
        if (paused) return false;
        const ctx = try owner.descriptors();
        if (self.requested_at == 0 or now -| self.requested_at >= 500_000_000) {
            const target = if (self.mode == .events and self.event_authorized) self.event_target else null;
            var foreground: [c.XRT_FD_INTEREST_MAX]i32 = undefined;
            var count: usize = 0;
            if (self.filter) |id| { foreground[0] = id.pid; count = 1; }
            for (self.rows.items[@min(self.top, self.rows.items.len)..@min(self.rows.items.len, self.top + self.visible)]) |row| {
                if (row == .event) continue;
                const pid = self.identity(row).owner.pid;
                if (std.mem.indexOfScalar(i32, foreground[0..count], pid) == null and count < foreground.len) {
                    foreground[count] = pid;
                    count += 1;
                }
            }
            const request = c.struct_xrt_fdactivity_request{
                .poll_pids = &foreground, .poll_pid_count = @intCast(count),
                .interval_ms = self.interval_ms,
                .event_pid = if (target) |id| id.pid else 0,
                .event_start = if (target) |id| id.start else 0,
            };
            const status = c.xrt_fdactivity_request(ctx, &request);
            if (status == c.XRT_OK) self.requested_at = now;
            if (status == c.XRT_INVALID_STATE) self.setFailure("Another process already owns the active event capture");
        }
        var view: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(ctx, &view) == 0) return false;
        // Copy only a newly published snapshot; never render while borrowed.
        var fresh: ?*c.struct_xrt_fd_snapshot = null;
        var event_changed = false;
        {
            defer c.xrt_fdactivity_release(ctx);
            self.owner_cpu_ns = view.owner_cpu_ns;
            self.owner_instances = owner.fd_opens;
            if (view.interval_ms != 0) self.active_interval_ms = view.interval_ms;
            self.poll_status = view.poll_status;
            if (view.poll != null and (self.snapshot == null or self.snapshot.?.sequence != view.poll.*.sequence))
                fresh = c.xrt_fd_snapshot_copy(view.poll) orelse return error.OutOfMemory;
            errdefer if (fresh) |s| c.xrt_fd_snapshot_free(s);
            if (self.event_target) |id| {
                const ready = view.event_generation != 0 and view.event_generation == view.requested_event_generation and
                    view.event.pid == id.pid and view.event.start_ticks == id.start;
                self.event_status = if (ready) view.event_status else c.XRT_STALE_SNAPSHOT;
                if (ready and (self.event_generation != view.event_generation or self.event_sequence != view.event_sequence)) {
                    if (view.event.row_count > 4096) return error.FdEventLimit;
                    try self.event_rows.ensureTotalCapacity(a, view.event.row_count);
                    self.event_rows.clearRetainingCapacity();
                    self.event_rows.appendSliceAssumeCapacity(view.event.rows[0..view.event.row_count]);
                    self.event = view.event;
                    self.event.rows = self.event_rows.items.ptr;
                    self.event_generation = view.event_generation;
                    self.event_sequence = view.event_sequence;
                    self.noteEvent(view.event_failure, view.event.reason);
                    event_changed = true;
                }
            }
        }
        if (fresh) |s| {
            if (self.snapshot) |old| c.xrt_fd_snapshot_free(old);
            self.snapshot = s;
        }
        self.dirty = self.dirty or fresh != null or event_changed;
        return fresh != null or event_changed;
    }
    /// A failed capture shows its operation, errno text, detail and remedy;
    /// otherwise the published coverage reason.
    pub fn noteEvent(self: *State, failure: c.struct_xrt_perf_failure, reason: [*c]const u8) void {
        self.remedy = null;
        if (failed(self.event_status) and failure.syscall != null) {
            var line: [320]u8 = undefined;
            self.setFailure(system.failureText(&line, failure));
            self.remedy = system.failureRemedy(failure);
        } else if (reason != null) self.setFailure(std.mem.span(reason));
    }
    fn failed(status: c.enum_xrt_status) bool {
        return status != c.XRT_OK and status != c.XRT_STALE_SNAPSHOT;
    }
    /// Footer state of the exact capture; a failed open is never "pending".
    pub fn captureState(self: *const State) []const u8 {
        if (failed(self.event_status)) return "failed";
        if (self.event.flags & c.XRT_FDEVENT_LOSS != 0) return "incomplete: event loss";
        if (self.event.flags & c.XRT_FDEVENT_POSSIBLE_LOSS != 0) return "incomplete: possible loss";
        if (self.event.flags & c.XRT_FDEVENT_LOSS_UNAVAILABLE != 0) return "loss accounting unavailable";
        if (self.exact_active) return "running";
        return if (self.exact_requested) "pending" else "stopped; retained counts";
    }
    /// A churn tile label, name[pid], with the name shortened to `keep` bytes
    /// (ending on a UTF-8 boundary) so equal names stay distinguishable.
    pub fn churnLabel(buf: []u8, process_name: []const u8, pid: i32, keep: usize) []const u8 {
        var n = @min(keep, process_name.len);
        while (n > 0 and n < process_name.len and process_name[n] & 0xc0 == 0x80) n -= 1;
        const more: []const u8 = if (n < process_name.len) "…" else "";
        return std.fmt.bufPrint(buf, "{s}{s}[{d}]", .{ process_name[0..n], more, pid }) catch "";
    }
    pub fn setFailure(self: *State, value: []const u8) void {
        self.failure_len = @min(value.len, self.failure.len);
        @memcpy(self.failure[0..self.failure_len], value[0..self.failure_len]);
    }
    pub fn show(self: *State, mode: Mode) void {
        if (mode != .events and self.event_authorized) self.stopCapture();
        self.mode = mode;
        self.top = 0;
        self.dirty = true;
        self.requested_at = 0;
    }
    pub fn scope(self: *State, id: Identity) void {
        self.filter = id;
        self.file_filter = null;
        self.selected = null;
        self.show(.files);
    }
    pub fn all(self: *State) void {
        self.filter = null;
        self.file_filter = null;
        self.selected = null;
        self.query_len = 0;
        self.show(.files);
    }
    pub fn text(self: *const State) []const u8 {
        return self.query[0..self.query_len];
    }
    fn includes(self: *const State, value: []const u8) bool {
        return self.query_len == 0 or std.ascii.indexOfIgnoreCase(value, self.text()) != null;
    }
    pub fn path(s: *const c.struct_xrt_fd_snapshot, fd: c.struct_xrt_fd) []const u8 {
        if (fd.flags & c.XRT_FD_LINK_CUT != 0) return "path truncated";
        if (fd.link >= s.strings_length or fd.link_length > s.strings_length - fd.link) return "path unavailable";
        const raw = s.strings[fd.link..][0..fd.link_length];
        for (raw) |byte| if (byte < 0x20 or byte == 0x7f) return "path contains control bytes; use inode";
        return if (std.unicode.utf8ValidateSlice(raw)) raw else "non-UTF-8 path; use inode";
    }
    pub fn name(p: *const c.struct_xrt_fd_process) []const u8 {
        const raw = p.comm[0 .. std.mem.indexOfScalar(u8, &p.comm, 0) orelse p.comm.len];
        for (raw) |byte| if (byte < 0x20 or byte == 0x7f) return "name contains control bytes";
        return if (std.unicode.utf8ValidateSlice(raw)) raw else "non-UTF-8 name";
    }
    pub fn identity(self: *const State, row: Row) Selection {
        if (row == .event) return .{ .owner = .{ .pid = self.event.pid, .start = self.event.start_ticks }, .fd = self.event_rows.items[row.event].fd };
        const s = self.snapshot.?;
        const index = if (row == .process) row.process else row.descriptor.process;
        const p = s.processes[index];
        return .{ .owner = .{ .pid = p.pid, .start = p.start }, .fd = if (row == .descriptor) s.fds[row.descriptor.fd].fd else -1 };
    }
    fn key(self: *const State, row: Row) f64 {
        if (self.sort == .pid) return @floatFromInt(self.identity(row).owner.pid);
        if (row == .event) {
            const e = self.event_rows.items[row.event];
            return if (self.sort == .count) @floatFromInt(e.read_calls +| e.write_calls) else @floatFromInt(e.read_bytes +| e.write_bytes);
        }
        const s = self.snapshot.?;
        if (row == .descriptor) {
            const f = s.fds[row.descriptor.fd];
            if (self.mode == .deleted or self.sort == .count) return if (f.flags & c.XRT_FD_STAT != 0) @floatFromInt(f.size) else -1;
            return if (progress(s.processes[row.descriptor.process], f)) |rate| rate else -1;
        }
        const p = s.processes[row.process];
        if (self.sort == .count) return @floatFromInt(p.count);
        if (self.mode == .leaks) return @floatFromInt(p.growth);
        return if (p.interval_ns == 0) -1 else p.churn_rate;
    }
    pub fn scopeReason(self: *const State) ?[]const u8 {
        const id = self.filter orelse return null;
        const s = self.snapshot orelse return "Waiting for the shared descriptor collector";
        for (s.processes[0..s.process_count]) |p| if (p.pid == id.pid) {
            if (id.start != 0 and p.start != id.start) return "Selected process identity changed; no replacement is selected";
            return null;
        };
        for (s.unseen[0..s.unseen_count]) |p| if (p.pid == id.pid) {
            return if (p.kernel != 0) "Kernel task has no user descriptor table" else "Descriptor table unavailable for this process through /proc";
        };
        return "Selected process has not been sampled; scan coverage is partial";
    }
    pub fn flowing(self: *const State, now: u64) bool {
        if (self.mode != .files) return false;
        const s = self.snapshot orelse return false;
        if (now -| s.taken_ns > 2_000_000_000) return false;
        for (self.rows.items[self.top..@min(self.rows.items.len, self.top + self.visible)]) |row| {
            if (row != .descriptor) continue;
            const p = s.processes[row.descriptor.process];
            if (p.flags & c.XRT_FDP_STALE != 0) continue;
            if (progress(p, s.fds[row.descriptor.fd])) |rate| if (rate > 0 and !offsetStale(p, s.fds[row.descriptor.fd])) return true;
        }
        return false;
    }
    pub fn offsetStale(p: c.struct_xrt_fd_process, fd: c.struct_xrt_fd) bool {
        return p.flags & c.XRT_FDP_STALE != 0 or fd.flags & c.XRT_FD_INFO_STALE != 0;
    }
    pub fn stale(p: c.struct_xrt_fd_process, fd: c.struct_xrt_fd) bool {
        const mask: u32 = c.XRT_FD_LINK_STALE | c.XRT_FD_STAT_STALE |
            @as(u8, if (fd.kind == c.XRT_FD_REGULAR or fd.kind == c.XRT_FD_MEMFD) c.XRT_FD_INFO_STALE else 0);
        return p.flags & c.XRT_FDP_STALE != 0 or fd.flags & mask != 0;
    }
    pub fn progress(_: c.struct_xrt_fd_process, fd: c.struct_xrt_fd) ?f32 {
        return if (fd.flags & c.XRT_FD_INFO == 0 or fd.flags & c.XRT_FD_OPENED != 0 or fd.info_interval_ns == 0 or
            (fd.kind != c.XRT_FD_REGULAR and fd.kind != c.XRT_FD_MEMFD)) null else fd.rate;
    }
    pub fn progressReason(p: c.struct_xrt_fd_process, fd: c.struct_xrt_fd) []const u8 {
        if (fd.kind != c.XRT_FD_REGULAR and fd.kind != c.XRT_FD_MEMFD) return "no seekable-file offset progress";
        if (fd.flags & c.XRT_FD_INFO == 0) return "fdinfo unavailable";
        if (offsetStale(p, fd)) return "cached offset progress; stale";
        if (fd.info_interval_ns == 0) return "first offset sample";
        if (fd.flags & c.XRT_FD_OPENED != 0) return "new descriptor; no prior identity";
        return "seekable offset progress; not exact IO";
    }
    fn less(self: *const State, a: Row, b: Row) bool {
        const ak = self.key(a);
        const bk = self.key(b);
        if (ak != bk) return if ((self.sort == .pid) != self.reverse) ak < bk else ak > bk;
        const ai = self.identity(a);
        const bi = self.identity(b);
        return if (ai.owner.pid != bi.owner.pid) ai.owner.pid < bi.owner.pid else ai.fd < bi.fd;
    }
    pub fn rebuild(self: *State, a: std.mem.Allocator, redact: bool) !void {
        if (!self.dirty) return;
        self.rows.clearRetainingCapacity();
        if (self.mode == .events) {
            if (self.event_status == c.XRT_OK)
                for (self.event_rows.items, 0..) |_, i| try self.rows.append(a, .{ .event = @intCast(i) });
        } else if (self.snapshot) |s| {
            for (s.processes[0..s.process_count], 0..) |p, pi| {
                if (self.filter) |id| {
                    if (p.pid != id.pid or (id.start != 0 and p.start != id.start)) continue;
                    if (id.start == 0) self.filter = .{ .pid = p.pid, .start = p.start };
                }
                if (self.mode == .processes or self.mode == .leaks) {
                    if (self.mode == .leaks and p.flags & c.XRT_FDP_LEAKING == 0) continue;
                    if (!self.includes(if (redact) "process" else name(&p))) continue;
                    try self.rows.append(a, .{ .process = @intCast(pi) });
                    continue;
                }
                for (s.fds[p.first..][0..p.count], 0..) |fd, i| {
                    if (self.mode == .deleted and fd.flags & c.XRT_FD_DELETED == 0) continue;
                    if (self.file_filter) |f| if (fd.flags & c.XRT_FD_STAT == 0 or fd.device != f.device or fd.inode != f.inode) continue;
                    if (!self.includes(if (redact) "redacted" else path(s, fd))) continue;
                    try self.rows.append(a, .{ .descriptor = .{ .process = @intCast(pi), .fd = p.first + @as(u32, @intCast(i)) } });
                }
            }
        }
        std.mem.sortUnstable(Row, self.rows.items, self, less);
        self.selected_row = @min(self.selected_row, self.rows.items.len -| 1);
        if (self.selected) |wanted| for (self.rows.items, 0..) |row, i| {
            if (std.meta.eql(wanted, self.identity(row))) {
                self.selected_row = i;
                break;
            }
        };
        self.select(self.selected_row);
        self.dirty = false;
    }
    pub fn select(self: *State, index: usize) void {
        if (index >= self.rows.items.len) {
            self.selected = null;
            self.top = 0;
            return;
        }
        self.selected_row = index;
        self.selected = self.identity(self.rows.items[index]);
        if (index < self.top) self.top = index;
        if (index >= self.top + self.visible) self.top = index + 1 - self.visible;
    }
    pub fn move(self: *State, by: i32) void {
        if (self.rows.items.len == 0) return;
        self.select(@intCast(std.math.clamp(@as(i64, @intCast(self.selected_row)) + by, 0, @as(i64, @intCast(self.rows.items.len - 1)))));
    }
};

test "descriptor presentation preserves scope, unknown progress and redaction" {
    const a = std.testing.allocator;
    var state: State = .{};
    defer state.deinit(a);
    var owner: Collector = .{};
    try std.testing.expect(!try state.refresh(a, &owner, 1, true));
    try std.testing.expect(owner.fd_collector == null);
    var processes = [_]c.struct_xrt_fd_process{std.mem.zeroes(c.struct_xrt_fd_process)} ** 2;
    processes[0].pid = 123;
    processes[0].start = 10;
    processes[0].count = 2;
    processes[0].interval_ns = 1_000_000_000;
    @memcpy(processes[0].comm[0..6], "writer");
    processes[1].pid = 456;
    processes[1].start = 20;
    processes[1].first = 2;
    processes[1].count = 1;
    processes[1].interval_ns = 1_000_000_000;
    var fds = [_]c.struct_xrt_fd{std.mem.zeroes(c.struct_xrt_fd)} ** 3;
    for (&fds, 0..) |*fd, i| {
        fd.fd = @intCast(i + 3);
        fd.kind = c.XRT_FD_REGULAR;
        fd.flags = c.XRT_FD_INFO | c.XRT_FD_STAT;
        fd.info_interval_ns = 1_000_000_000;
        fd.rate = if (i == 0) 50 else 20;
        fd.link_length = 15;
    }
    fds[1].kind = c.XRT_FD_PIPE;
    fds[1].rate = 999;
    var snapshot = std.mem.zeroes(c.struct_xrt_fd_snapshot);
    snapshot.processes = &processes;
    snapshot.process_count = processes.len;
    snapshot.fds = &fds;
    snapshot.fd_count = fds.len;
    snapshot.strings = "/fixture/secret";
    snapshot.strings_length = 16;
    state.snapshot = c.xrt_fd_snapshot_copy(&snapshot) orelse return error.OutOfMemory;
    try state.rebuild(a, false);
    try std.testing.expectEqual(3, state.rows.items.len);
    try std.testing.expectEqual(@as(i32, 123), state.identity(state.rows.items[0]).owner.pid);
    try std.testing.expectEqual(@as(i32, 3), state.identity(state.rows.items[0]).fd);
    try std.testing.expect(State.progress(processes[0], fds[1]) == null);
    var cached = fds[0];
    cached.flags |= c.XRT_FD_LINK_STALE;
    try std.testing.expect(State.stale(processes[0], cached));
    try std.testing.expect(!State.offsetStale(processes[0], cached));
    cached.flags |= c.XRT_FD_INFO_STALE;
    try std.testing.expect(State.offsetStale(processes[0], cached));
    try std.testing.expectEqualStrings("cached offset progress; stale", State.progressReason(processes[0], cached));
    try std.testing.expectEqual(@as(?f32, 50), State.progress(processes[0], cached));
    var pipe = fds[1];
    pipe.flags |= c.XRT_FD_INFO_STALE;
    try std.testing.expect(!State.stale(processes[0], pipe));
    pipe.flags |= c.XRT_FD_LINK_STALE;
    try std.testing.expect(State.stale(processes[0], pipe));
    state.scope(.{ .pid = 123, .start = 11 });
    try state.rebuild(a, false);
    try std.testing.expectEqual(0, state.rows.items.len);
    state.scope(.{ .pid = 123, .start = 10 });
    try state.rebuild(a, false);
    try std.testing.expectEqual(2, state.rows.items.len);
    state.all();
    @memcpy(state.query[0..6], "secret");
    state.query_len = 6;
    try state.rebuild(a, false);
    try std.testing.expectEqual(3, state.rows.items.len);
    state.dirty = true;
    try state.rebuild(a, true);
    try std.testing.expectEqual(0, state.rows.items.len);
    try std.testing.expectEqualStrings("writer", State.name(&processes[0]));
}

test "a denied exact capture is shown as failed with its operation, errno text and remedy" {
    var state: State = .{ .exact_requested = true, .event_authorized = true, .event_status = c.XRT_PERMISSION_DENIED };
    var f = std.mem.zeroes(c.struct_xrt_perf_failure);
    f.kind = c.XRT_PERF_PERMISSION;
    f.syscall = "syscalls.metadata.read";
    f.detail = "/sys/kernel/tracing/events/raw_syscalls/sys_enter/id";
    f.@"error" = c.EACCES;
    f.tid = -1;
    state.noteEvent(f, f.detail);
    const shown = state.failure[0..state.failure_len];
    try std.testing.expect(std.mem.indexOf(u8, shown, "syscalls.metadata.read") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, std.mem.span(c.strerror(c.EACCES))) != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "/sys/kernel/tracing/events/raw_syscalls/sys_enter/id") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.remedy.?, "tracefs") != null);
    try std.testing.expectEqualStrings("failed", state.captureState());
    // Still waiting for enrollment is pending, and a running capture is not failed.
    state.event_status = c.XRT_STALE_SNAPSHOT;
    try std.testing.expectEqualStrings("pending", state.captureState());
    state.event_status = c.XRT_OK;
    state.noteEvent(std.mem.zeroes(c.struct_xrt_perf_failure), "covered syscalls");
    try std.testing.expect(state.remedy == null);
    try std.testing.expectEqualStrings("covered syscalls", state.failure[0..state.failure_len]);
}

test "churn tiles keep equal command names distinguishable by pid" {
    var first: [64]u8 = undefined;
    var second: [64]u8 = undefined;
    try std.testing.expectEqualStrings("pw-play[12]", State.churnLabel(&first, "pw-play", 12, 64));
    for ([_]usize{ 64, 3, 0 }) |keep| {
        const a = State.churnLabel(&first, "pw-play", 1201, keep);
        const b = State.churnLabel(&second, "pw-play", 1202, keep);
        try std.testing.expect(!std.mem.eql(u8, a, b));
        try std.testing.expect(std.mem.endsWith(u8, a, "[1201]") and std.mem.endsWith(u8, b, "[1202]"));
    }
    try std.testing.expectEqualStrings("pw-…[7]", State.churnLabel(&first, "pw-play", 7, 3));
    // A shortened name never splits a UTF-8 sequence.
    try std.testing.expectEqualStrings("a…[7]", State.churnLabel(&first, "aé", 7, 2));
}
