//! Owner-prepared syscall pages. The frontend never traverses capture history.
const std = @import("std");
const profile = @import("../profile/capture.zig");
const Session = @import("session.zig").Session;
const now = @import("../target/linux.zig").now;
pub const Request = struct {
    session: u64 = 0,
    capture: u64 = 0,
    filter: profile.Filter = .{},
    first: usize = 0,
    count: usize = 1,
};

test "syscall publication bounds full history and rejects an obsolete page" {
    const a = std.testing.allocator;
    var session = Session{ .id = 1 };
    defer session.deinit();
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = .init(a), .id = 2, .session_id = 1, .generation = 1, .image_epoch = 1, .pid = 7, .started_ns = 100, .ended_ns = 1000000, .config = .{}, .accepted = std.mem.zeroes(@import("../profile/linux_perf.zig").Acceptance), .thread_count = 1, .collector = null, .images = @import("modules.zig").Modules.init(a) };
    session.profile = capture;
    capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = 7, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    capture.syscalls.enabled = true;
    capture.syscalls.limit = 65536;
    for (0..65536) |i| try capture.syscalls.items.append(a, .{ .thread_index = 0, .nr = 0, .exit_nr = 0, .entry_ns = 100 + i * 10, .exit_ns = 105 + i * 10, .result = 1, .reason = .complete });
    var owner = Capture{};
    defer owner.deinit();
    owner.refresh(&session, .{ .session = 1, .capture = 2, .count = 64, .first = 10 });
    try std.testing.expectEqual(@as(usize, 65536), owner.value.?.total);
    try std.testing.expectEqual(@as(usize, 64), owner.value.?.rows.len);
    try std.testing.expectEqual(@as(usize, 10), owner.value.?.rows[0].ordinal);
    try std.testing.expectEqual(@as(?u64, 5), owner.value.?.rows[0].elapsed_ns);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 }, .revision = 1, .taken_ns = 1, .status = .ready, .syscalls = owner.value });
    defer publication.destroy();
    // Other optional panes enlarge the fixed publication header. Bound this
    // page's retained payload independently of those unrelated fixed fields.
    try std.testing.expect(publication.bytes - @sizeOf(boundary.Publication) < 64 * 1024);
    capture.deinit();
    session.profile = null;
    owner.clear();
    try std.testing.expectEqual(@as(usize, 0), owner.arena.queryCapacity());
    var frontend = @import("../ui/syscalls.zig").Panel{ .open = true, .first = 10 };
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    frontend.present(publication.value.syscalls, 1866, .{});
    try std.testing.expectEqual(@as(usize, 65536), frontend.total);
    try std.testing.expectEqualStrings("read", frontend.view.?.rows[0].name.?);
    frontend.wheel(1);
    frontend.present(publication.value.syscalls, 1866, .{});
    try std.testing.expectEqual(@as(usize, 11), frontend.first);
    try std.testing.expect(frontend.view == null);
}
pub const View = struct {
    request: Request,
    normalized: Request,
    revision: u64 = 0,
    total: usize = 0,
    rows: []const profile.Capture.SyscallRow = &.{},
    recorded: bool = false,
    collecting: bool = false,
    lost: u64 = 0,
    throttles: u64 = 0,
    discarded: u64 = 0,
    unread_possible: bool = false,
    message: []const u8 = "",
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    built_ns: u64 = 0,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = null;
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        const value = self.value orelse return true;
        const current = session.profile;
        if (value.normalized.session != session.id or value.normalized.capture != (if (current) |c| c.id else @as(u64, 0))) return true;
        if (current) |c| return value.collecting != (c.collector != null) or (value.revision != c.revision and (c.collector == null or now() -| self.built_ns >= 250 * std.time.ns_per_ms));
        return false;
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const requested = wanted orelse {
            self.clear();
            return;
        };
        if (self.value) |v| if (!self.changed(session) and (std.meta.eql(requested, v.request) or std.meta.eql(requested, v.normalized))) return;
        _ = self.arena.reset(.retain_capacity);
        var normalized = requested;
        normalized.session = session.id;
        normalized.capture = if (session.profile) |c| c.id else 0;
        normalized.count = std.math.clamp(requested.count, 1, 64);
        if (requested.session != normalized.session or requested.capture != normalized.capture) normalized.first = 0;
        if (self.value) |old| {
            if (!std.meta.eql(old.normalized.filter, requested.filter)) normalized.first = 0;
        }
        self.value = .{ .request = requested, .normalized = normalized };
        self.built_ns = now();
        const current = session.profile orelse return;
        const value = &self.value.?;
        value.revision = current.revision;
        value.recorded = current.syscalls.enabled;
        value.collecting = current.collector != null;
        value.lost = current.syscalls.lost;
        value.throttles = current.syscalls.throttles;
        value.discarded = current.syscalls.discarded;
        value.unread_possible = current.syscalls.unread_possible;
        const page = current.syscallPage(self.arena.allocator(), normalized.filter, normalized.first, normalized.count) catch |err| {
            value.message = @errorName(err);
            return;
        };
        value.total = page.total;
        value.rows = page.rows;
    }
};
