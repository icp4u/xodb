//! One owner-thread collector and cache, borrowed by the view and every MCP peer.
const std = @import("std");
pub const c = @import("../c.zig").api;
const a = std.heap.c_allocator;
const Snapshot = c.struct_xrt_sys_snapshot;
const count = c.XRT_SYS_G_COUNT;
pub fn bit(id: c_uint) u32 {
    return @as(u32, 1) << @intCast(id);
}

pub const FdEventState = enum { inactive, requested, active };

pub const Collector = struct {
    ctx: ?*c.struct_xrt_sys = null,
    cache: ?*Snapshot = null,
    scratch: ?*Snapshot = null,
    sampled: [count]u64 = @splat(0),
    due: [count]u64 = @splat(0),
    requested_until: [count]u64 = @splat(0),
    full_until: u64 = 0,
    fast_ns: u64 = 500_000_000,
    last_mask: u32 = 0,
    light: bool = false,
    opens: u64 = 0,
    redact: bool = false,
    fd_collector: ?*c.struct_xrt_fdactivity = null,
    fd_opens: u64 = 0,
    fd_event_state: FdEventState = .inactive,
    fd_lease: ?@import("../service/lease.zig").Lease = null,

    /// Cached publication only: displaying status never creates or renews capture.
    pub fn fdEventState(self: *Collector) FdEventState {
        const owner = self.fd_collector orelse return .inactive;
        var view: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(owner, &view) == 0) return self.fd_event_state;
        self.fd_event_state = if (view.event.running != 0) .active else if (view.event_requested != 0) .requested else .inactive;
        c.xrt_fdactivity_release(owner);
        return self.fd_event_state;
    }

    pub fn descriptors(self: *Collector) !*c.struct_xrt_fdactivity {
        if (self.fd_collector == null) {
            if (c.xrt_fdactivity_create(&self.fd_collector) != c.XRT_OK) return error.OutOfMemory;
            self.fd_opens += 1;
        }
        return self.fd_collector.?;
    }
    pub fn revokeFdEvents(self: *Collector) bool {
        if (self.fd_collector) |ctx| {
            const stop_request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .stop_events = 1 };
            if (c.xrt_fdactivity_request(ctx, &stop_request) != c.XRT_OK) return false;
        }
        self.fd_lease = null;
        return true;
    }
    pub fn checkFdLease(self: *Collector, now: u64, scope: u32) void {
        if (self.fd_lease) |lease| if (!lease.valid(now, scope)) {
            _ = self.revokeFdEvents(); // retry next tick if publication was busy
        };
    }

    pub fn deinit(self: *Collector) void {
        if (self.fd_collector) |owner| c.xrt_fdactivity_destroy(owner);
        if (self.cache) |p| {
            c.xrt_sys_snapshot_free(p);
            a.destroy(p);
        }
        if (self.scratch) |p| {
            c.xrt_sys_snapshot_free(p);
            a.destroy(p);
        }
        if (self.ctx) |p| c.xrt_sys_close(p);
        self.* = .{};
    }
    pub fn snapshot(self: *Collector) !*const Snapshot {
        if (self.cache == null) {
            const p = try a.create(Snapshot);
            p.* = std.mem.zeroes(Snapshot);
            p.abi = c.XRT_SYS_ABI;
            p.groups = c.XRT_SYS_ALL_GROUPS;
            for (&p.group) |*g| {
                g.st = c.XRT_SYS_UNAVAILABLE;
                g.why = c.XRT_SYS_WHY_NOT_COLLECTED;
            }
            self.cache = p;
        }
        return self.cache.?;
    }
    /// Requests affect the next owner tick, never sample inside an MCP call.
    /// Demand expires when clients stop asking; no peer owns the cache lifetime.
    pub fn request(self: *Collector, groups: u32, now: u64) void {
        for (&self.requested_until, 0..) |*until, i| if (groups & bit(@intCast(i)) != 0) {
            until.* = now + 3_000_000_000;
        };
        if (groups & bit(c.XRT_SYS_G_PROCESSES) != 0) self.full_until = now + 3_000_000_000;
    }
    fn period(self: *const Collector, id: usize) u64 {
        return switch (id) {
            c.XRT_SYS_G_PROCESSES, c.XRT_SYS_G_CONNECTIONS => @max(self.fast_ns, 1_000_000_000),
            c.XRT_SYS_G_FILESYSTEMS, c.XRT_SYS_G_USERS, c.XRT_SYS_G_SERVICES => @max(self.fast_ns, 2_000_000_000),
            c.XRT_SYS_G_POWER, c.XRT_SYS_G_DISKS, c.XRT_SYS_G_NETWORK => @max(self.fast_ns, 500_000_000),
            c.XRT_SYS_G_APPS => 60_000_000_000,
            c.XRT_SYS_G_SYSINFO => 10_000_000_000,
            else => self.fast_ns,
        };
    }
    pub fn tick(self: *Collector, now: u64, gui: u32, full_gui: bool) !bool {
        var mask: u32 = 0;
        for (self.due, 0..) |deadline, i| {
            const wanted = gui & bit(@intCast(i)) != 0 or now < self.requested_until[i];
            if (wanted and now >= deadline) mask |= bit(@intCast(i));
        }
        if (mask == 0) return false;
        _ = try self.snapshot();
        if (self.scratch == null) {
            const p = try a.create(Snapshot);
            p.* = std.mem.zeroes(Snapshot);
            self.scratch = p;
        }
        if (self.ctx == null) {
            var limits: c.struct_xrt_sys_limits = undefined;
            c.xrt_sys_limits_default(&limits);
            self.ctx = c.xrt_sys_open(&limits) orelse return error.OutOfMemory;
            self.opens += 1;
        }
        const light = !full_gui and now >= self.full_until;
        c.xrt_sys_configure(self.ctx.?, mask, @as(u32, c.XRT_SYS_SHOW_HOSTNAME) | @as(u32, if (light) c.XRT_SYS_LIGHT_PROCESSES else 0));
        if (c.xrt_sys_sample(self.ctx.?, self.scratch.?) != c.XRT_OK) return error.OutOfMemory;
        self.merge(mask);
        for (&self.due, &self.sampled, 0..) |*deadline, *sampled, i| if (mask & bit(@intCast(i)) != 0) {
            deadline.* = now + self.period(i);
            sampled.* = now;
        };
        if (mask & bit(c.XRT_SYS_G_PROCESSES) != 0) self.light = light;
        self.last_mask = mask;
        if (c.getenv("XODB_OVERVIEW_AUDIT") != null) std.debug.print("xodb: overview collector opens={d} sequence={d} groups={x} light={} processes_sample_ns={d}\n", .{ self.opens, self.cache.?.sequence, mask, self.light, self.sampled[c.XRT_SYS_G_PROCESSES] });
        return true;
    }
    fn merge(self: *Collector, mask: u32) void {
        const dst = self.cache.?;
        const src = self.scratch.?;
        dst.sequence = src.sequence;
        dst.monotonic_ns = src.monotonic_ns;
        dst.realtime_ns = src.realtime_ns;
        dst.interval_s = src.interval_s;
        dst.self = src.self;
        inline for (.{ "summary", "cpu", "memory", "disks", "filesystems", "network", "connections", "power", "users", "services", "apps", "processes", "info" }, 0..) |field, i| {
            if (mask & bit(i) != 0) {
                if (comptime i == c.XRT_SYS_G_PROCESSES) c.free(dst.processes.proc);
                if (comptime i == c.XRT_SYS_G_CONNECTIONS) c.free(dst.connections.conn);
                if (comptime i == c.XRT_SYS_G_APPS) c.free(dst.apps.list);
                @field(dst, field) = @field(src, field);
                dst.group[i] = src.group[i];
                if (comptime i == c.XRT_SYS_G_PROCESSES) src.processes.proc = null;
                if (comptime i == c.XRT_SYS_G_CONNECTIONS) src.connections.conn = null;
                if (comptime i == c.XRT_SYS_G_APPS) src.apps.list = null;
            }
        }
    }
};

test "cache requests do not sample, one owner merges groups and expires demand" {
    var collector: Collector = .{};
    defer collector.deinit();
    const now: u64 = 10_000_000_000;
    for (0..10) |_| collector.request(bit(c.XRT_SYS_G_PROCESSES), now);
    try std.testing.expectEqual(0, collector.opens);
    try std.testing.expectEqual(0, (try collector.snapshot()).sequence);
    try std.testing.expect(try collector.tick(now, 0, false));
    try std.testing.expectEqual(1, collector.opens);
    const sequence = (try collector.snapshot()).sequence;
    const rows = collector.cache.?.processes.count;
    try std.testing.expect(rows > 0 and !collector.light);
    try std.testing.expect(!try collector.tick(now + 1, 0, false));
    try std.testing.expect(try collector.tick(now + 2, bit(c.XRT_SYS_G_MEMORY), false));
    try std.testing.expectEqual(rows, collector.cache.?.processes.count);
    try std.testing.expectEqual(sequence + 1, collector.cache.?.sequence);
    try std.testing.expect(!try collector.tick(now + 4_000_000_000, 0, false));
    try std.testing.expect(try collector.tick(now + 4_000_000_000, bit(c.XRT_SYS_G_PROCESSES), false));
    try std.testing.expect(collector.light);
    const row = collector.cache.?.processes.proc[0];
    try std.testing.expectEqual(c.XRT_SYS_WHY_NOT_COLLECTED, row.fds.why);
    try std.testing.expectEqual(c.XRT_SYS_WHY_NOT_COLLECTED, row.io_read_bytes.why);
}

test "GUI event status does not create a descriptor collector" {
    var owner: Collector = .{};
    defer owner.deinit();
    try std.testing.expectEqual(FdEventState.inactive, owner.fdEventState());
    try std.testing.expectEqual(@as(u64, 0), owner.fd_opens);
    try std.testing.expect(owner.fd_collector == null);
}
