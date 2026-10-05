//! C-owned raw_syscalls event groups, with host-side record analysis.
const std = @import("std");
const builtin = @import("builtin");
const perf = @import("linux_perf.zig");
const model = @import("syscalls.zig");
const runtime = @import("runtime.zig");
const rt = runtime.c;
const c = perf.c;
const copy = runtime.copy;
pub const data_pages = 16;
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
pub fn ringBytes(threads: usize) u64 {
    return threads * data_pages * rt.xrt_perf_page_size();
}
pub const Collector = struct {
    allocator: std.mem.Allocator,
    handle: *rt.struct_xrt_perf,
    pid: i32,
    enter_type: u16,
    exit_type: u16,
    image_changed: bool = false,
    pub fn close(self: *Collector) void {
        rt.xrt_perf_destroy(self.handle);
        self.allocator.destroy(self);
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_stop(self.handle, &f)) null else runtime.failure(f);
    }
    const Decoding = struct {
        self: *Collector,
        store: *model.Store,
        more: bool = false,
        failure: ?anyerror = null,
        fn decode(raw: ?*anyopaque, view: [*c]const rt.struct_xrt_perf_ring) callconv(.c) rt.struct_xrt_perf_consumed {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            const ring = view[0];
            var tail = ring.tail;
            const status = ctx.consume(ring, &tail) catch |err| blk: {
                ctx.failure = err;
                break :blk rt.XRT_PERF_DRAIN_MALFORMED;
            };
            return .{ .bytes = tail - ring.tail, .status = status };
        }
        fn consume(ctx: *@This(), ring: rt.struct_xrt_perf_ring, tail: *u64) !c_uint {
            var count: usize = 0;
            while (tail.* < ring.head and count < 128) : (count += 1) {
                if (ring.head - tail.* < 8) return error.SyscallRingIncomplete;
                var bytes: [256]u8 = undefined;
                copy(ring.data[0..ring.size], tail.*, bytes[0..8]);
                const length = std.mem.readInt(u16, bytes[6..8], .little);
                if (length < 8 or length > bytes.len or length > ring.head - tail.* or length % 8 != 0) return error.SyscallRecordSize;
                copy(ring.data[0..ring.size], tail.*, bytes[0..length]);
                const event = try model.decode(bytes[0..length], .{ .pid = ctx.self.pid, .tid = ring.thread[0].tid, .enter_id = ring.thread[0].event_ids[0], .exit_id = ring.thread[0].event_ids[1], .enter_type = ctx.self.enter_type, .exit_type = ctx.self.exit_type });
                tail.* += length;
                if (event) |ev| {
                    var event_ = ev;
                    if (event_ == .call) event_.call.time = rt.xrt_perf_timestamp(ctx.self.handle, event_.call.time);
                    try ctx.store.feed(ctx.self.allocator, ring.index, event_);
                    if (ev == .exec) {
                        ctx.self.image_changed = true;
                        return rt.XRT_PERF_DRAIN_STOP;
                    }
                }
            }
            ctx.more = ctx.more or tail.* < ring.head;
            return rt.XRT_PERF_DRAIN_OK;
        }
    };
    pub fn drain(self: *Collector, store: *model.Store) !bool {
        if (self.image_changed) return false;
        var ctx = Decoding{ .self = self, .store = store };
        const status = rt.xrt_perf_drain(self.handle, Decoding.decode, &ctx);
        if (ctx.failure) |err| return err;
        if (status == rt.XRT_PERF_DRAIN_MALFORMED) return error.SyscallRingLayout;
        return !self.image_changed and (ctx.more or status == rt.XRT_PERF_DRAIN_CAPACITY);
    }
};
pub fn start(a: std.mem.Allocator, pid: i32, tids: []const i32) !Opened {
    return startTarget(a, null, pid, tids);
}
pub fn startTarget(a: std.mem.Allocator, target: ?*const rt.struct_xrt_target, pid: i32, tids: []const i32) !Opened {
    var entry: u16 = undefined;
    var exit: u16 = undefined;
    var f: rt.struct_xrt_perf_failure = undefined;
    const handle = rt.xrt_syscalls_start_target(target, pid, tids.ptr, tids.len, &entry, &exit, &f) orelse return .{ .failed = runtime.failure(f) };
    errdefer rt.xrt_perf_destroy(handle);
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .handle = handle, .pid = pid, .enter_type = entry, .exit_type = exit };
    return .{ .collector = self };
}

test "shared syscall ring wrap copies exactly" {
    const ring = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var result: [6]u8 = undefined;
    copy(&ring, 6, &result);
    try std.testing.expectEqualSlices(u8, &.{ 6, 7, 0, 1, 2, 3 }, &result);
}

test "syscall partial-open failure closes all prepared descriptors" {
    try @import("../test_support.zig").requireLive();
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const result = try start(std.testing.allocator, c.getpid(), &.{ c.getpid(), std.math.maxInt(i32) });
    switch (result) {
        .collector => |collector| {
            collector.close();
            return error.ExpectedOpenFailure;
        },
        .failed => |failure| {
            try std.testing.expectEqual(c.ESRCH, failure.errno);
            try std.testing.expectEqual(@as(u16, 2), failure.opened_then_closed);
        },
    }
}

test "syscall failure cleanup closes prepared descriptors without perf permissions" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(0, c.pipe2(&fds, c.O_CLOEXEC));
    const handle = rt.xrt_perf_create(16, 32, std.math.maxInt(u64)) orelse return error.OutOfMemory;
    const state = runtime.state(handle);
    state.count = 1;
    state.slots[0].thread.event_count = 2;
    state.slots[0].fds[0] = fds[0];
    state.slots[0].fds[1] = fds[1];
    try std.testing.expectEqual(2, rt.xrt_perf_fd_count(handle));
    rt.xrt_perf_destroy(handle);
    for (fds) |fd| {
        try std.testing.expectEqual(-1, c.fcntl(fd, c.F_GETFD));
        try std.testing.expectEqual(c.EBADF, std.c._errno().*);
    }
}
