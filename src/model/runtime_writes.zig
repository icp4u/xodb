//! Session IO/authority adapter. C owns encoding, destination rules and recovery.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("session.zig");
const linux = @import("../target/linux.zig");
const cache = @import("runtime_types.zig");
pub fn reason(p: [*c]const u8) ?[]const u8 {
    return if (p == null) null else std.mem.span(p);
}
pub fn hexBytes(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |v, i| {
        out[2 * i] = digits[v >> 4];
        out[2 * i + 1] = digits[v & 15];
    }
    return out[0 .. bytes.len * 2];
}
pub const Change = struct {
    value: c.struct_xjai_write_change = std.mem.zeroes(c.struct_xjai_write_change),
    pub fn jsonStringify(self: Change, writer: anytype) !void {
        const v = self.value;
        var address: [32]u8 = undefined;
        var old: [128]u8 = undefined;
        var wanted: [128]u8 = undefined;
        var observed: [128]u8 = undefined;
        try writer.write(.{ .id = v.id, .address_hex = (std.fmt.bufPrint(&address, "0x{x}", .{v.address}) catch unreachable), .size = v.size, .generation_before = v.before_generation, .generation_after = v.after_generation, .raw = v.raw != 0, .undo = v.undo != 0, .write_attempted = v.write_attempted != 0, .verified = v.verified != 0, .before_hex = if (v.before_valid != 0) hexBytes(&old, v.before[0..v.size]) else null, .requested_hex = hexBytes(&wanted, v.requested[0..v.size]), .observed_hex = if (v.observed_valid != 0) hexBytes(&observed, v.observed[0..v.size]) else null, .reason = reason(v.reason), .backend_reason = reason(v.backend_reason), .state = if (v.reason == null) "verified" else if (v.id == 0) "refused" else "failed" });
    }
};
pub const State = struct {
    target_id: u64 = 1,
    journal: ?*c.struct_xjai_write_journal = null,
    pub fn deinit(self: *State) void {
        c.xjai_write_journal_free(self.journal);
        self.journal = null;
    }
    pub fn stamp(self: *const State, session: *model.Session, actor: model.Actor) c.struct_xjai_write_stamp {
        const snap = session.target.snapshot();
        return .{ .session_id = session.id, .target_id = self.target_id, .image_epoch = snap.image_epoch, .generation = snap.generation, .client_id = if (actor == .agent) session.agent_client_id orelse 0 else 0, .actor = @intFromEnum(actor) };
    }
    fn finish(_: *State, session: *model.Session, actor: model.Actor, change: Change) void {
        if (change.value.id == 0) return;
        session.record(actor, if (change.value.undo != 0) "undo_runtime_write" else "write_runtime_field");
        session.audit[session.audit_count - 1].runtime_write = change;
        if (change.value.verified != 0) session.runtime_types.advance(session, change.value.before_generation);
    }
    pub fn apply(self: *State, session: *model.Session, actor: model.Actor, expected: u64, entry: cache.Entry, index: u32, address: u64, path: []const u8, value: []const u8, raw: bool) !Change {
        try authority(session, actor, expected);
        try entry.requireStop(session);
        const g = try entry.graph();
        try session.refreshMaps();
        var ctx = Context{ .session = session, .live = .{ .session = session }, .actor = actor, .stamp = self.stamp(session, actor), .expected = expected };
        var reader = c.struct_xjai_live_reader{ .context = &ctx, .read = Context.read, .reads = 0, .bytes = 0 };
        var plan: c.struct_xjai_write_plan = undefined;
        var change = Change{};
        if (c.xjai_write_plan(g, index, address, path.ptr, path.len, value.ptr, value.len, @intFromBool(raw), &reader, &plan)) |why| {
            change.value.reason = why;
            return change;
        }
        if (self.journal == null) self.journal = c.xjai_write_journal_create() orelse return error.OutOfMemory;
        const io = ctx.io();
        _ = c.xjai_write_apply(self.journal, &plan, path.ptr, path.len, @intFromBool(raw), &ctx.stamp, &io, &change.value);
        self.finish(session, actor, change);
        return change;
    }
    pub fn undo(self: *State, session: *model.Session, actor: model.Actor, expected: u64, id: u64, raw: bool) !Change {
        try authority(session, actor, expected);
        try session.refreshMaps();
        var ctx = Context{ .session = session, .live = .{ .session = session }, .actor = actor, .stamp = self.stamp(session, actor), .expected = expected };
        const io = ctx.io();
        var change = Change{};
        _ = c.xjai_write_undo(self.journal, id, @intFromBool(raw), &ctx.stamp, &io, &change.value);
        self.finish(session, actor, change);
        return change;
    }
    pub fn last(self: *const State, session: *model.Session) u64 {
        const s = self.stamp(session, .human);
        return c.xjai_write_journal_last(self.journal, &s);
    }
};
fn authority(session: *model.Session, actor: model.Actor, expected: u64) !void {
    if (session.offline) return error.OfflineSession;
    try session.authorize(actor, .mutation, expected);
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (actor == .agent and session.agent_client_id != null) {
        const lease = session.agent_lease orelse return error.ControlLeaseRequired;
        if (!session.agent_controller or !lease.valid(linux.now(), @intFromEnum(session.agent_scope))) return error.ControlLeaseRequired;
    }
}
const Context = struct {
    session: *model.Session,
    live: cache.LiveReader,
    actor: model.Actor,
    stamp: c.struct_xjai_write_stamp,
    expected: u64,
    fn from(p: ?*anyopaque) *Context {
        return @ptrCast(@alignCast(p.?));
    }
    fn current(self: *Context) !void {
        const s = self.session.target.snapshot();
        if (self.session.id != self.stamp.session_id or self.session.runtime_writes.target_id != self.stamp.target_id or s.image_epoch != self.stamp.image_epoch) return error.RuntimeWriteTargetChanged;
        if (s.state != .stopped) return error.NotStopped;
        try self.session.target.expectGeneration(self.expected);
    }
    fn io(self: *Context) c.struct_xjai_write_io {
        return .{ .context = self, .read = read, .write = write, .guard = guard, .generation = generation };
    }
    fn read(p: ?*anyopaque, address: u64, output: ?*anyopaque, size: usize) callconv(.c) c_int {
        const self = from(p);
        self.current() catch return 0;
        const got = self.live.readInto(address, output, size);
        self.current() catch return 0;
        return got;
    }
    fn write(p: ?*anyopaque, address: u64, input: ?*const anyopaque, size: usize) callconv(.c) [*c]const u8 {
        const self = from(p);
        self.current() catch |err| return @errorName(err).ptr;
        authority(self.session, self.actor, self.expected) catch |err| return @errorName(err).ptr;
        const bytes: [*]const u8 = @ptrCast(input.?);
        self.session.target.writeMemory(address, bytes[0..size]) catch |err| {
            self.expected = self.session.target.snapshot().generation;
            return @errorName(err).ptr;
        };
        self.expected = self.session.target.snapshot().generation;
        return null;
    }
    fn generation(p: ?*anyopaque) callconv(.c) u64 {
        return from(p).session.target.snapshot().generation;
    }
    fn mapping(p: ?*anyopaque, address: u64, output: [*c]c.struct_xjai_write_mapping) callconv(.c) c_int {
        const self = from(p);
        for (self.session.modules.regions.items) |r| if (address >= r.start and address < r.end) {
            output.* = .{ .start = r.start, .end = r.end, .permissions = (if (r.permissions[0] == 'r') @as(u32, c.XJAI_WRITE_MAP_READ) else 0) | (if (r.permissions[1] == 'w') @as(u32, c.XJAI_WRITE_MAP_WRITE) else 0) | (if (r.permissions[2] == 'x') @as(u32, c.XJAI_WRITE_MAP_EXEC) else 0) | (if (r.permissions[3] == 's') @as(u32, c.XJAI_WRITE_MAP_SHARED) else 0) };
            return 1;
        };
        return 0;
    }
    fn guard(p: ?*anyopaque, address: u64, size: usize) callconv(.c) [*c]const u8 {
        const self = from(p);
        self.current() catch |err| return @errorName(err).ptr;
        authority(self.session, self.actor, self.expected) catch |err| return @errorName(err).ptr;
        var ranges: [cache.max_contexts * 16]c.struct_xjai_write_range = undefined;
        var count: usize = 0;
        for (self.session.runtime_types.entries) |slot| if (slot) |e| {
            @memcpy(ranges[count..][0..e.range_count], e.ranges[0..e.range_count]);
            count += e.range_count;
        };
        return c.xjai_write_destination(mapping, self, &ranges, count, address, size);
    }
};
