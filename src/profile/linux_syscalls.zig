//! Opt-in raw_syscalls collection for explicit x86-64 task selections.
//! Entry/exit share one per-task ring through PERF_EVENT_IOC_SET_OUTPUT.
//! Group enable/disable bounds the pair. No system policy or tracing files change.
const std = @import("std");
const builtin = @import("builtin");
const perf = @import("linux_perf.zig");
const model = @import("syscalls.zig");
const c = perf.c;
pub const data_pages = 16;
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
const Slot = struct { tid: i32 = 0, enter: c_int = -1, exit: c_int = -1, enter_id: u64 = 0, exit_id: u64 = 0, map: []u8 = &.{}, tail: u64 = 0 };
pub fn ringBytes(threads: usize) u64 {
    return threads * data_pages * pageSize();
}
pub const Collector = struct {
    allocator: std.mem.Allocator,
    pid: i32,
    slots: [model.max_threads]Slot = @splat(.{}),
    count: usize = 0,
    enter_type: u16,
    exit_type: u16,
    running: bool = false,
    image_changed: bool = false,
    pub fn close(self: *Collector) void {
        _ = self.stop();
        for (self.slots[0..self.count]) |slot| {
            if (slot.exit >= 0) _ = c.close(slot.exit);
            if (slot.map.len > 0) _ = c.munmap(slot.map.ptr, slot.map.len);
            if (slot.enter >= 0) _ = c.close(slot.enter);
        }
        self.allocator.destroy(self);
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var failure: ?perf.Failure = null;
        for (self.slots[0..self.count]) |slot| if (slot.enter >= 0) {
            if (c.ioctl(slot.enter, @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, c.PERF_IOC_FLAG_GROUP)) != 0 and errno() != c.ESRCH)
                failure = failed("syscalls.disable", errno(), slot.tid, "disable syscall event group");
        };
        self.running = false;
        return failure;
    }
    fn fail(self: *Collector, failure: perf.Failure) Opened {
        var result = failure;
        for (self.slots[0..self.count]) |slot| result.opened_then_closed += @as(u16, @intFromBool(slot.enter >= 0)) + @as(u16, @intFromBool(slot.exit >= 0));
        self.close();
        return .{ .failed = result };
    }
    /// At most 128 records from every ring per pass; busy tasks cannot starve others.
    pub fn drain(self: *Collector, store: *model.Store) !bool {
        if (@import("builtin").cpu.arch == .m68k) return error.SyscallsUnsupportedArchitecture;
        if (self.image_changed) return false;
        var more = false;
        for (self.slots[0..self.count], 0..) |*slot, index| {
            const offset = std.mem.readInt(u64, slot.map[1040..1048], .little);
            const size = std.mem.readInt(u64, slot.map[1048..1056], .little);
            if (offset != pageSize() or size != data_pages * pageSize() or size > slot.map.len - offset) return error.SyscallRingLayout;
            const head = @atomicLoad(u64, field(slot.map, 1024), .acquire);
            if (head < slot.tail or head - slot.tail > size) return error.SyscallRingOverrun;
            const ring = slot.map[@intCast(offset)..][0..@intCast(size)];
            defer @atomicStore(u64, field(slot.map, 1032), slot.tail, .seq_cst);
            var count: usize = 0;
            while (slot.tail < head and count < 128) : (count += 1) {
                if (head - slot.tail < 8) return error.SyscallRingIncomplete;
                var bytes: [256]u8 = undefined;
                copy(ring, slot.tail, bytes[0..8]);
                const length = std.mem.readInt(u16, bytes[6..8], .little);
                if (length < 8 or length > bytes.len or length > head - slot.tail or length % 8 != 0) return error.SyscallRecordSize;
                copy(ring, slot.tail, bytes[0..length]);
                const event = try model.decode(bytes[0..length], .{ .pid = self.pid, .tid = slot.tid, .enter_id = slot.enter_id, .exit_id = slot.exit_id, .enter_type = self.enter_type, .exit_type = self.exit_type });
                slot.tail += length;
                if (event) |ev| {
                    try store.feed(self.allocator, index, ev);
                    if (ev == .exec) {
                        self.image_changed = true;
                        return false;
                    }
                }
            }
            more = more or slot.tail < head;
        }
        return more;
    }
};
fn copy(ring: []const u8, tail: u64, out: []u8) void {
    const at: usize = @intCast(tail & (ring.len - 1));
    const first = @min(out.len, ring.len - at);
    @memcpy(out[0..first], ring[at..][0..first]);
    @memcpy(out[first..], ring[0 .. out.len - first]);
}
fn field(map: []u8, offset: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + offset));
}
fn pageSize() usize {
    const n = c.sysconf(c._SC_PAGESIZE);
    return if (n > 0) @intCast(n) else 4096;
}
fn errno() c_int {
    return std.c._errno().*;
}
fn failed(stage: []const u8, err: c_int, tid: i32, detail: []const u8) perf.Failure {
    return .{ .kind = if (err == c.EPERM or err == c.EACCES) .permission else if (err == c.ESRCH) .thread_gone else if (err == c.EINVAL or err == c.E2BIG) .configuration else if (err == c.ENOENT or err == c.ENOSYS or err == c.ENODEV or err == c.EOPNOTSUPP) .unavailable else if (err == c.EMFILE or err == c.ENFILE or err == c.ENOMEM or err == c.EAGAIN) .resource else .other, .syscall = stage, .errno = err, .tid = tid, .detail = detail };
}
const Metadata = union(enum) { value: u16, failed: perf.Failure };
fn metadata(comptime enter: bool) Metadata {
    const base = "/sys/kernel/tracing/events/raw_syscalls/sys_" ++ (if (enter) "enter" else "exit");
    var id_buf: [64]u8 = undefined;
    const id_text = read(base ++ "/id", &id_buf) catch return .{ .failed = failed("syscalls.metadata.read", errno(), -1, base ++ "/id") };
    const id = std.fmt.parseInt(u32, std.mem.trim(u8, id_text, " \t\r\n"), 10) catch return .{ .failed = failed("syscalls.metadata.id", 0, -1, base ++ "/id") };
    var fmt_buf: [16384]u8 = undefined;
    const fmt = read(base ++ "/format", &fmt_buf) catch return .{ .failed = failed("syscalls.metadata.read", errno(), -1, base ++ "/format") };
    model.validateFormat(fmt, id, enter) catch return .{ .failed = .{ .kind = .configuration, .syscall = "syscalls.metadata.format", .detail = base ++ "/format: unsupported fields, widths, signedness or ID" } };
    return .{ .value = @intCast(id) };
}
fn read(path: [:0]const u8, buf: []u8) ![]const u8 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.MetadataRead;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf.ptr + used, buf.len - used);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.MetadataRead;
        }
        if (n == 0) return buf[0..used];
        used += @intCast(n);
    }
    std.c._errno().* = c.E2BIG;
    return error.MetadataRead;
}
fn openEvent(tid: i32, group: c_int, event: u16, leader: bool) c_int {
    var attr = std.mem.zeroes(perf.Attr);
    attr.size = 96;
    attr.typ = c.PERF_TYPE_TRACEPOINT;
    attr.config = event;
    attr.sample_period = 1;
    attr.sample_type = model.sample_type;
    attr.flags = 1 | (1 << 18) | (1 << 25); // disabled, sample_id_all, use_clockid
    if (leader) attr.flags |= (1 << 9) | (1 << 13) | (1 << 24); // comm, task, comm_exec
    attr.clockid = c.CLOCK_MONOTONIC;
    return @intCast(c.syscall(@as(c_long, c.SYS_perf_event_open), &attr, @as(c.pid_t, tid), @as(c_int, -1), group, @as(c_ulong, c.PERF_FLAG_FD_CLOEXEC)));
}
pub fn start(a: std.mem.Allocator, pid: i32, tids: []const i32) !Opened {
    if (@import("builtin").cpu.arch == .m68k) return error.SyscallsUnsupportedArchitecture;
    if (builtin.cpu.arch != .x86_64 or builtin.cpu.arch.endian() != .little) return .{ .failed = .{ .kind = .configuration, .syscall = "syscalls.architecture", .detail = "raw syscall decoding currently supports native Linux x86-64" } };
    if (pid <= 0 or tids.len == 0 or tids.len > model.max_threads) return .{ .failed = .{ .kind = .configuration, .syscall = "syscalls.scope", .detail = "select 1..32 explicit threads" } };
    for (tids, 0..) |tid, i| if (tid <= 0 or std.mem.indexOfScalar(i32, tids[0..i], tid) != null) return .{ .failed = .{ .kind = .configuration, .syscall = "syscalls.scope", .tid = tid, .detail = "invalid or duplicate selected TID" } };
    const entry = switch (metadata(true)) {
        .value => |v| v,
        .failed => |v| return .{ .failed = v },
    };
    const exit = switch (metadata(false)) {
        .value => |v| v,
        .failed => |v| return .{ .failed = v },
    };
    if (entry == exit) return .{ .failed = .{ .kind = .configuration, .syscall = "syscalls.metadata.id", .detail = "entry and exit tracepoint IDs are identical" } };
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .pid = pid, .enter_type = entry, .exit_type = exit };
    for (tids) |tid| {
        const slot = &self.slots[self.count];
        self.count += 1;
        slot.tid = tid;
        slot.enter = openEvent(tid, -1, entry, true);
        if (slot.enter < 0) return self.fail(failed("syscalls.perf_event_open.enter", errno(), tid, "raw_syscalls enter; check target access and tracing policy (SETUP.md)"));
        const bytes = (1 + data_pages) * pageSize();
        const ptr = c.mmap(null, bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, slot.enter, @as(c.off_t, 0));
        if (@intFromPtr(ptr) == std.math.maxInt(usize)) return self.fail(failed("syscalls.mmap", errno(), tid, "syscall ring"));
        slot.map = @as([*]u8, @ptrCast(ptr))[0..bytes];
        if (c.ioctl(slot.enter, @as(c_ulong, c.PERF_EVENT_IOC_ID), &slot.enter_id) != 0) return self.fail(failed("syscalls.id.enter", errno(), tid, "PERF_EVENT_IOC_ID"));
        slot.exit = openEvent(tid, slot.enter, exit, false);
        if (slot.exit < 0) return self.fail(failed("syscalls.perf_event_open.exit", errno(), tid, "raw_syscalls exit"));
        if (c.ioctl(slot.exit, @as(c_ulong, c.PERF_EVENT_IOC_ID), &slot.exit_id) != 0) return self.fail(failed("syscalls.id.exit", errno(), tid, "PERF_EVENT_IOC_ID"));
        if (c.ioctl(slot.exit, @as(c_ulong, c.PERF_EVENT_IOC_SET_OUTPUT), @as(c_ulong, @intCast(slot.enter))) != 0) return self.fail(failed("syscalls.set_output", errno(), tid, "share entry/exit ring"));
    }
    for (self.slots[0..self.count]) |slot|
        if (c.ioctl(slot.enter, @as(c_ulong, c.PERF_EVENT_IOC_ENABLE), @as(c_ulong, c.PERF_IOC_FLAG_GROUP)) != 0) return self.fail(failed("syscalls.enable", errno(), slot.tid, "enable syscall event group"));
    self.running = true;
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
    const self = std.testing.allocator.create(Collector) catch |err| {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
        return err;
    };
    self.* = .{ .allocator = std.testing.allocator, .pid = 1, .enter_type = 1, .exit_type = 2, .count = 2 };
    self.slots[0] = .{ .tid = 1, .enter = fds[0], .exit = fds[1] };
    self.slots[1] = .{ .tid = 2 }; // failed before the second pair opened
    const result = self.fail(failed("injected.open", c.EMFILE, 2, "descriptor exhaustion"));
    try std.testing.expectEqual(c.EMFILE, result.failed.errno);
    try std.testing.expectEqual(2, result.failed.opened_then_closed);
    for (fds) |fd| {
        try std.testing.expectEqual(-1, c.fcntl(fd, c.F_GETFD));
        try std.testing.expectEqual(c.EBADF, errno());
    }
}
