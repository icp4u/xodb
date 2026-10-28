//! Off-CPU blocked intervals. Weights are nanoseconds, never sample counts.
//! An interval that is still open at the end of the capture is truncated.
const std = @import("std");
const records = @import("records.zig");
pub const max_frames: usize = 64;
pub const Layout = struct {
    prev_pid_off: u16,
    next_pid_off: u16,
    prev_state_off: u16,
    prev_state_size: u8,
};
pub const Switch = struct {
    prev_pid: i32,
    next_pid: i32,
    time_ns: u64,
    /// Null when the tracepoint layout has no readable prev_state.
    prev_state: ?i64 = null,
    frames: []const u64,
};
/// sched_switch prev_state. A clear low byte is still runnable: 0 is
/// TASK_RUNNING, and current kernels add bit 0x100 when the switch was a
/// preemption (printed R+). Sleep, disk, stop, zombie, parked and idle bits
/// in that byte are real blocking, not a run-queue wait.
pub fn isRunQueueWait(state: i64) bool {
    return (state & 0xff) == 0;
}
pub const Wait = enum(u8) { blocking, runqueue };
pub const run_queue_name = "[run queue]";
/// Body of a PERF_RECORD_SAMPLE whose sample_type is TID, TIME, CALLCHAIN, RAW,
/// in that order. `frames_buf` receives the callchain, capped at max_frames.
pub fn parseSample(body: []const u8, layout: Layout, frames_buf: []u64) ?Switch {
    if (body.len < 24) return null;
    const time_ns = std.mem.readInt(u64, body[8..16], .little);
    const nr = std.mem.readInt(u64, body[16..24], .little);
    if (nr > 1024) return null;
    const chain_end = 24 + nr * 8;
    if (chain_end + 4 > body.len) return null;
    const raw_size = std.mem.readInt(u32, body[chain_end..][0..4], .little);
    const raw_at = chain_end + 4;
    if (raw_at + raw_size > body.len) return null;
    const raw = body[raw_at..][0..raw_size];
    const prev = readPid(raw, layout.prev_pid_off) orelse return null;
    const next = readPid(raw, layout.next_pid_off) orelse return null;
    const n = @min(@as(usize, @intCast(nr)), frames_buf.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        frames_buf[i] = std.mem.readInt(u64, body[24 + i * 8 ..][0..8], .little);
    }
    return .{ .prev_pid = prev, .next_pid = next, .time_ns = time_ns, .prev_state = readState(raw, layout), .frames = frames_buf[0..n] };
}
fn readState(raw: []const u8, layout: Layout) ?i64 {
    const at: usize = layout.prev_state_off;
    if (layout.prev_state_size == 8) {
        if (at + 8 > raw.len) return null;
        return std.mem.readInt(i64, raw[at..][0..8], .little);
    }
    if (layout.prev_state_size == 4) {
        if (at + 4 > raw.len) return null;
        return std.mem.readInt(i32, raw[at..][0..4], .little);
    }
    return null;
}
fn readPid(raw: []const u8, offset: u16) ?i32 {
    const at = @as(usize, offset);
    if (at + 4 > raw.len) return null;
    return std.mem.readInt(i32, raw[at..][0..4], .little);
}
pub const Split = struct { user: usize, kernel: usize };
/// Leaf-first ips, split by PERF_CONTEXT markers. Other contexts are omitted
/// from both sides so a guest or hypervisor marker cannot land in the user tree.
pub fn splitChain(frames: []const u64, user_buf: []u64, kernel_buf: []u64) Split {
    var mode: enum { unknown, user, kernel, other } = .unknown;
    var user_n: usize = 0;
    var kernel_n: usize = 0;
    for (frames) |ip| {
        if (records.isContextMarker(ip)) {
            mode = switch (ip) {
                records.context_user, records.context_user_deferred => .user,
                records.context_kernel => .kernel,
                else => .other,
            };
            continue;
        }
        if (ip == 0) continue;
        switch (mode) {
            .user => if (user_n < user_buf.len) {
                user_buf[user_n] = ip;
                user_n += 1;
            },
            .kernel => if (kernel_n < kernel_buf.len) {
                kernel_buf[kernel_n] = ip;
                kernel_n += 1;
            },
            else => {},
        }
    }
    return .{ .user = user_n, .kernel = kernel_n };
}
/// One stack's summed waits. Repeated closes of the same tid, wait kind and
/// frames add their nanoseconds here instead of storing another copy.
pub const Interval = struct {
    tid: i32,
    /// Earliest open, so a mapping cursor can still visit stacks in order.
    start_ns: u64,
    end_ns: u64,
    blocked_ns: u64,
    /// True when any folded close was truncated.
    truncated: bool,
    frames: []u64,
    wait: Wait = .blocking,
    closes: u32 = 1,
};
const Open = struct {
    start_ns: u64,
    frames: []u64,
    wait: Wait,
};
/// Distinct stacks kept per tracker. Further new stacks increment `dropped`.
pub const max_stacks: usize = 4096;
const StackKey = struct { tid: i32, wait: Wait, frames: []const u64 };
const StackContext = struct {
    pub fn hash(_: StackContext, key: StackKey) u64 {
        var h = std.hash.Wyhash.init(@as(u64, @bitCast(@as(i64, key.tid))) ^ (@as(u64, @intFromEnum(key.wait)) << 40));
        h.update(std.mem.sliceAsBytes(key.frames));
        return h.final();
    }
    pub fn eql(_: StackContext, a: StackKey, b: StackKey) bool {
        return a.tid == b.tid and a.wait == b.wait and std.mem.eql(u64, a.frames, b.frames);
    }
};
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    tids: []i32,
    open: []?Open,
    intervals: std.ArrayList(Interval) = .empty,
    /// Stack key to its row in `intervals`. Keys borrow the row's frames.
    stacks: std.HashMapUnmanaged(StackKey, u32, StackContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Ring losses plus stacks that did not fit in `limit`.
    dropped: u64 = 0,
    /// Every close, including ones whose stack was dropped.
    closed: u64 = 0,
    truncated_closes: u64 = 0,
    /// Nanoseconds kept in `intervals`. Dropped stacks are not included.
    blocked_total: u64 = 0,
    runqueue_ns: u64 = 0,
    limit: usize = max_stacks,
    pub fn init(a: std.mem.Allocator, tids: []const i32) !Tracker {
        const owned = try a.dupe(i32, tids);
        errdefer a.free(owned);
        const open = try a.alloc(?Open, owned.len);
        @memset(open, null);
        return .{ .allocator = a, .tids = owned, .open = open };
    }
    pub fn deinit(self: *Tracker) void {
        for (self.open) |slot| if (slot) |opened| self.allocator.free(opened.frames);
        for (self.intervals.items) |interval| self.allocator.free(interval.frames);
        self.intervals.deinit(self.allocator);
        self.stacks.deinit(self.allocator);
        self.allocator.free(self.open);
        self.allocator.free(self.tids);
    }
    fn index(self: *const Tracker, tid: i32) ?usize {
        for (self.tids, 0..) |known, i| if (known == tid) return i;
        return null;
    }
    fn find(self: *const Tracker, tid: i32, wait: Wait, frames: []const u64) ?usize {
        if (self.stacks.get(.{ .tid = tid, .wait = wait, .frames = frames })) |row| return row;
        return null;
    }
    fn close(self: *Tracker, slot: usize, end_ns: u64, truncated: bool) !void {
        const opened = self.open[slot] orelse return;
        self.open[slot] = null;
        const blocked = if (end_ns > opened.start_ns) end_ns - opened.start_ns else 0;
        self.closed += 1;
        if (truncated) self.truncated_closes += 1;
        if (self.find(self.tids[slot], opened.wait, opened.frames)) |found| {
            const item = &self.intervals.items[found];
            item.blocked_ns +|= blocked;
            item.closes +|= 1;
            if (truncated) item.truncated = true;
            if (opened.start_ns < item.start_ns) item.start_ns = opened.start_ns;
            if (end_ns > item.end_ns) item.end_ns = end_ns;
            self.blocked_total +|= blocked;
            if (opened.wait == .runqueue) self.runqueue_ns +|= blocked;
            self.allocator.free(opened.frames);
            return;
        }
        if (self.intervals.items.len >= self.limit) {
            self.dropped += 1;
            self.allocator.free(opened.frames);
            return;
        }
        self.stacks.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.allocator.free(opened.frames);
            return err;
        };
        self.intervals.append(self.allocator, .{
            .tid = self.tids[slot],
            .start_ns = opened.start_ns,
            .end_ns = end_ns,
            .blocked_ns = blocked,
            .truncated = truncated,
            .frames = opened.frames,
            .wait = opened.wait,
        }) catch |err| {
            self.allocator.free(opened.frames);
            return err;
        };
        self.stacks.putAssumeCapacity(.{ .tid = self.tids[slot], .wait = opened.wait, .frames = opened.frames }, @intCast(self.intervals.items.len - 1));
        self.blocked_total +|= blocked;
        if (opened.wait == .runqueue) self.runqueue_ns +|= blocked;
    }
    /// `outgoing` is the stack of the task that left the CPU. A switch-in
    /// closes that task's open interval. A second switch-out with no switch-in
    /// closes the previous interval as truncated. The wait kind defaults to
    /// real blocking; `switchedWait` records a run-queue wait after preemption.
    pub fn switched(self: *Tracker, prev_tid: i32, next_tid: i32, time_ns: u64, outgoing: []const u64) !void {
        return self.switchedWait(prev_tid, next_tid, time_ns, outgoing, .blocking);
    }
    pub fn switchedWait(self: *Tracker, prev_tid: i32, next_tid: i32, time_ns: u64, outgoing: []const u64, wait: Wait) !void {
        if (self.index(prev_tid)) |slot| {
            if (self.open[slot] != null) try self.close(slot, time_ns, true);
            const copy = try self.allocator.alloc(u64, @min(outgoing.len, max_frames));
            errdefer self.allocator.free(copy);
            @memcpy(copy, outgoing[0..copy.len]);
            self.open[slot] = .{ .start_ns = time_ns, .frames = copy, .wait = wait };
        }
        if (self.index(next_tid)) |slot| {
            if (prev_tid != next_tid) try self.close(slot, time_ns, false);
        }
    }
    /// The thread is back on a CPU (PERF_RECORD_SWITCH switch-in). Closes its
    /// open interval; nothing happens when none is open.
    pub fn resumed(self: *Tracker, tid: i32, time_ns: u64) !void {
        const slot = self.index(tid) orelse return;
        if (self.open[slot] != null) try self.close(slot, time_ns, false);
    }
    /// A thread that exits while blocked. The open interval stays, marked truncated.
    pub fn truncateTid(self: *Tracker, tid: i32, time_ns: u64) !void {
        const slot = self.index(tid) orelse return;
        if (self.open[slot] != null) try self.close(slot, time_ns, true);
    }
    /// Capture end. Open intervals stay in the result.
    pub fn finish(self: *Tracker, until_ns: u64) !void {
        for (self.open, 0..) |slot, i| if (slot != null) try self.close(i, until_ns, true);
    }
};
test "blocked intervals close on switch-in and stay truncated when the capture ends" {
    const a = std.testing.allocator;
    var tracker = try Tracker.init(a, &.{ 7, 8 });
    defer tracker.deinit();
    try tracker.switched(7, 9, 100, &.{ 10, 11 });
    try tracker.switched(3, 7, 250, &.{});
    try tracker.switched(8, 1, 300, &.{ 20 });
    try tracker.finish(400);
    try std.testing.expectEqual(@as(usize, 2), tracker.intervals.items.len);
    const first = tracker.intervals.items[0];
    try std.testing.expectEqual(@as(i32, 7), first.tid);
    try std.testing.expectEqual(@as(u64, 150), first.blocked_ns);
    try std.testing.expect(!first.truncated);
    try std.testing.expectEqualSlices(u64, &.{ 10, 11 }, first.frames);
    const second = tracker.intervals.items[1];
    try std.testing.expectEqual(@as(i32, 8), second.tid);
    try std.testing.expect(second.truncated);
    try std.testing.expectEqual(@as(u64, 100), second.blocked_ns);
}
test "a sched_switch sample yields the outgoing callchain and both pids" {
    var raw: [64]u8 = @splat(0);
    std.mem.writeInt(i32, raw[24..28], 7, .little);
    std.mem.writeInt(i32, raw[56..60], 9, .little);
    var body: [24 + 16 + 4 + 64]u8 = @splat(0);
    std.mem.writeInt(u64, body[8..16], 1000, .little);
    std.mem.writeInt(u64, body[16..24], 2, .little);
    std.mem.writeInt(u64, body[24..32], 0x10, .little);
    std.mem.writeInt(u64, body[32..40], 0x20, .little);
    std.mem.writeInt(u32, body[40..44], raw.len, .little);
    @memcpy(body[44..][0..raw.len], &raw);
    var frames: [max_frames]u64 = undefined;
    const parsed = parseSample(body[0 .. 44 + raw.len], .{ .prev_pid_off = 24, .next_pid_off = 56, .prev_state_off = 32, .prev_state_size = 8 }, &frames).?;
    try std.testing.expectEqual(@as(i32, 7), parsed.prev_pid);
    try std.testing.expectEqual(@as(i32, 9), parsed.next_pid);
    try std.testing.expectEqual(@as(u64, 1000), parsed.time_ns);
    try std.testing.expectEqualSlices(u64, &.{ 0x10, 0x20 }, parsed.frames);
    // The fixture's prev_state bytes are zero: still runnable, including R+.
    try std.testing.expectEqual(@as(i64, 0), parsed.prev_state.?);
    try std.testing.expect(isRunQueueWait(parsed.prev_state.?));
    std.mem.writeInt(i64, raw[32..40], 0x100, .little);
    @memcpy(body[44..][0..raw.len], &raw);
    const preempted = parseSample(body[0 .. 44 + raw.len], .{ .prev_pid_off = 24, .next_pid_off = 56, .prev_state_off = 32, .prev_state_size = 8 }, &frames).?;
    try std.testing.expectEqual(@as(i64, 0x100), preempted.prev_state.?);
    try std.testing.expect(isRunQueueWait(0x100));
    std.mem.writeInt(i64, raw[32..40], 1, .little);
    @memcpy(body[44..][0..raw.len], &raw);
    const sleeping = parseSample(body[0 .. 44 + raw.len], .{ .prev_pid_off = 24, .next_pid_off = 56, .prev_state_off = 32, .prev_state_size = 8 }, &frames).?;
    try std.testing.expectEqual(@as(i64, 1), sleeping.prev_state.?);
    try std.testing.expect(!isRunQueueWait(1));
    try std.testing.expect(!isRunQueueWait(0x101));
}
test "context markers split the outgoing stack and a thread exit keeps the open interval" {
    var user: [max_frames]u64 = undefined;
    var kernel: [max_frames]u64 = undefined;
    const frames = [_]u64{ records.context_kernel, 0x100, 0x200, records.context_user, 0x300, 0x400, records.context_hv, 0x500 };
    const split = splitChain(&frames, &user, &kernel);
    try std.testing.expectEqualSlices(u64, &.{ 0x100, 0x200 }, kernel[0..split.kernel]);
    try std.testing.expectEqualSlices(u64, &.{ 0x300, 0x400 }, user[0..split.user]);
    const a = std.testing.allocator;
    var tracker = try Tracker.init(a, &.{ 4 });
    defer tracker.deinit();
    try tracker.switched(4, 1, 10, &.{ 1 });
    try tracker.truncateTid(4, 50);
    try tracker.finish(90);
    try std.testing.expectEqual(@as(usize, 1), tracker.intervals.items.len);
    try std.testing.expect(tracker.intervals.items[0].truncated);
    try std.testing.expectEqual(@as(u64, 40), tracker.intervals.items[0].blocked_ns);
}
test "a second switch-out without a switch-in does not drop the open interval" {
    const a = std.testing.allocator;
    var tracker = try Tracker.init(a, &.{ 4 });
    defer tracker.deinit();
    try tracker.switched(4, 1, 10, &.{ 1 });
    try tracker.switched(4, 1, 40, &.{ 2 });
    try tracker.finish(40);
    try std.testing.expectEqual(@as(usize, 2), tracker.intervals.items.len);
    try std.testing.expect(tracker.intervals.items[0].truncated);
    try std.testing.expectEqual(@as(u64, 30), tracker.intervals.items[0].blocked_ns);
    try std.testing.expect(tracker.intervals.items[1].truncated);
    try std.testing.expectEqual(@as(u64, 0), tracker.intervals.items[1].blocked_ns);
}

test "a switch-in record closes the interval so later on-CPU time is not blocked time" {
    const a = std.testing.allocator;
    var tracker = try Tracker.init(a, &.{4});
    defer tracker.deinit();
    try tracker.switched(4, 1, 100, &.{1});
    try tracker.resumed(4, 400);
    try tracker.resumed(4, 450);
    try tracker.switched(4, 1, 900, &.{2});
    try tracker.finish(1000);
    try std.testing.expectEqual(@as(usize, 2), tracker.intervals.items.len);
    try std.testing.expect(!tracker.intervals.items[0].truncated);
    try std.testing.expectEqual(@as(u64, 300), tracker.intervals.items[0].blocked_ns);
    try std.testing.expect(tracker.intervals.items[1].truncated);
    try std.testing.expectEqual(@as(u64, 100), tracker.intervals.items[1].blocked_ns);
}

test "repeated stacks sum, a run-queue wait stays separate, and a new stack past the cap is dropped" {
    const a = std.testing.allocator;
    var tracker = try Tracker.init(a, &.{4});
    defer tracker.deinit();
    tracker.limit = 2;
    try tracker.switchedWait(4, 1, 10, &.{ 1, 2 }, .blocking);
    try tracker.resumed(4, 30);
    try tracker.switchedWait(4, 1, 40, &.{ 1, 2 }, .blocking);
    try tracker.resumed(4, 50);
    try tracker.switchedWait(4, 1, 60, &.{ 1, 2 }, .runqueue);
    try tracker.resumed(4, 70);
    try tracker.switchedWait(4, 1, 80, &.{9}, .blocking);
    try tracker.resumed(4, 90);
    try std.testing.expectEqual(@as(usize, 2), tracker.intervals.items.len);
    try std.testing.expectEqual(@as(u64, 4), tracker.closed);
    try std.testing.expectEqual(@as(u64, 1), tracker.dropped);
    try std.testing.expectEqual(Wait.blocking, tracker.intervals.items[0].wait);
    try std.testing.expectEqual(@as(u64, 30), tracker.intervals.items[0].blocked_ns);
    try std.testing.expectEqual(@as(u32, 2), tracker.intervals.items[0].closes);
    try std.testing.expectEqual(@as(u64, 10), tracker.intervals.items[0].start_ns);
    try std.testing.expectEqual(Wait.runqueue, tracker.intervals.items[1].wait);
    try std.testing.expectEqual(@as(u64, 10), tracker.intervals.items[1].blocked_ns);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, tracker.intervals.items[1].frames);
    try std.testing.expectEqual(@as(u64, 40), tracker.blocked_total);
    try std.testing.expectEqual(@as(u64, 10), tracker.runqueue_ns);
}
