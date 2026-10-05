//! Task-local perf uprobes over pinned runtime ELF files. No policy changes,
//! process discovery, privilege escalation, GUI access or automatic fallback.
//! Caller holds the selected threads stopped until start returns. Raw registers
//! are normalized by the allocation session owner using the verified adapter.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("allocation_perf.zig");
const perf = @import("linux_perf.zig");
const hooks = @import("allocation_hooks.zig");
const kernel = @import("runtime.zig");
const rt = kernel.c;
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/syscall.h");
    @cInclude("linux/perf_event.h");
    @cInclude("time.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("dirent.h");
    @cInclude("dlfcn.h");
});
pub const max_threads = 32;
pub const data_pages = 16;
pub const Source = hooks.Source;
pub const Opener = struct {
    user: *anyopaque,
    call: *const fn (*anyopaque, i32, c_int, c_int, u64, bool, bool, bool) c_int,
};
pub const Config = struct { target: ?*const rt.struct_xrt_target = null, mapping: ?@import("../model/modules.zig").Region = null, remote_helper: ?[:0]const u8 = null, pid: i32, tids: []const i32, sources: []const Source, opener: ?Opener = null, enable: bool = true, callstacks: bool = true, cancel: ?*const std.atomic.Value(bool) = null };
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
pub const Item = struct { lane: u16, record: wire.Record };
pub const Drain = struct { count: usize = 0, more: bool = false, failure: ?perf.Failure = null };

pub const Collector = struct {
    allocator: std.mem.Allocator,
    owner: ?*rt.struct_xrt_allocations,
    handle: *rt.struct_xrt_perf,
    pid: i32,
    hooks: [wire.max_hooks]struct { id: u16, kind: @import("allocation_lifetimes.zig").Kind } = undefined,
    source_count: usize = 0,
    callstacks: bool = false,
    failed: bool = false,
    fault_bytes: [256]u8 = @splat(0),
    fault_len: usize = 0,
    pub fn enable(self: *Collector) ?perf.Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_allocations_enable(self.owner.?, &f)) null else kernel.failure(f);
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_stop(self.handle, &f)) null else kernel.failure(f);
    }
    pub fn close(self: *Collector) void {
        if (self.owner) |owner| rt.xrt_allocations_destroy(owner) else rt.xrt_perf_destroy(self.handle);
        self.allocator.destroy(self);
    }
    const Decoding = struct {
        self: *Collector,
        out: []Item,
        result: Drain = .{},
        stop: bool = false,
        fn decode(raw: ?*anyopaque, view: [*c]const rt.struct_xrt_perf_ring) callconv(.c) rt.struct_xrt_perf_consumed {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            const ring = view[0];
            var tail = ring.tail;
            const status = ctx.consume(ring, &tail) catch |err| blk: {
                ctx.result.failure = fail("allocations.drain", 0, ring.thread[0].tid, @errorName(err));
                break :blk rt.XRT_PERF_DRAIN_MALFORMED;
            };
            return .{ .bytes = tail - ring.tail, .status = status };
        }
        fn consume(ctx: *@This(), ring: rt.struct_xrt_perf_ring, tail: *u64) !c_uint {
            const self = ctx.self;
            var ids: [wire.max_hooks]wire.Hook = undefined;
            for (self.hooks[0..self.source_count], 0..) |hook, i| ids[i] = .{ .id = hook.id, .kind = hook.kind, .entry_id = ring.thread[0].event_ids[2 * i], .return_id = ring.thread[0].event_ids[2 * i + 1] };
            var count: usize = 0;
            while (tail.* < ring.head and count < 128 and ctx.result.count < ctx.out.len) : (count += 1) {
                if (ring.head - tail.* < 8) return error.AllocationRingIncomplete;
                var bytes: [wire.max_record_size]u8 = undefined;
                copy(ring.data[0..ring.size], tail.*, bytes[0..8]);
                const size = std.mem.readInt(u16, bytes[6..8], .little);
                if (size < 8 or size > bytes.len or size > ring.head - tail.* or size % 8 != 0) return error.AllocationRecordSize;
                copy(ring.data[0..ring.size], tail.*, bytes[0..size]);
                var record = wire.decode(bytes[0..size], .{ .pid = @intCast(self.pid), .tid = @intCast(ring.thread[0].tid), .hooks = ids[0..self.source_count], .callstacks = self.callstacks }) catch |err| {
                    self.fault_len = @min(size, self.fault_bytes.len);
                    @memcpy(self.fault_bytes[0..self.fault_len], bytes[0..self.fault_len]);
                    return err;
                };
                record.time_ns = rt.xrt_perf_timestamp(self.handle, record.time_ns);
                tail.* += size;
                ctx.out[ctx.result.count] = .{ .lane = @intCast(ring.index), .record = record };
                ctx.result.count += 1;
                if (record.data == .exec or record.data == .fork or record.data == .mapping_change) {
                    ctx.stop = true;
                    ctx.result.more = true;
                    return rt.XRT_PERF_DRAIN_STOP;
                }
            }
            ctx.result.more = ctx.result.more or tail.* < ring.head;
            if (ctx.result.count == ctx.out.len) {
                ctx.result.more = true;
                return rt.XRT_PERF_DRAIN_CAPACITY;
            }
            return rt.XRT_PERF_DRAIN_OK;
        }
    };
    pub fn drain(self: *Collector, out: []Item) Drain {
        if (self.failed) return .{ .failure = fail("allocations.drain", 0, -1, "collector has a latched decode/ring failure") };
        if (out.len == 0) return .{ .failure = fail("allocations.drain", 0, -1, "empty output buffer") };
        var ctx = Decoding{ .self = self, .out = out };
        const status = rt.xrt_perf_drain(self.handle, Decoding.decode, &ctx);
        ctx.result.more = ctx.result.more or status == rt.XRT_PERF_DRAIN_CAPACITY;
        if (status == rt.XRT_PERF_DRAIN_MALFORMED) {
            self.failed = true;
            if (ctx.result.failure == null) ctx.result.failure = fail("allocations.drain", 0, -1, "invalid perf ring layout or overrun");
        }
        if (self.failed or ctx.stop) _ = self.stop();
        return ctx.result;
    }
};
const copy = kernel.copy;
const pageSize = rt.xrt_perf_page_size;
fn errno() c_int {
    return std.c._errno().*;
}
fn fail(stage: []const u8, n: c_int, tid: i32, detail: []const u8) perf.Failure {
    return .{ .kind = if (n == c.EACCES or n == c.EPERM) .permission else if (n == c.ESRCH) .thread_gone else if (n == c.ENOMEM or n == c.EMFILE or n == c.ENFILE) .resource else if (n == c.ENOENT or n == c.ENODEV or n == c.ENOSYS or n == c.EOPNOTSUPP) .unavailable else .configuration, .syscall = stage, .errno = n, .tid = tid, .detail = detail };
}
pub fn start(a: std.mem.Allocator, config: Config) !Opened {
    if (config.sources.len > wire.max_hooks) return .{ .failed = fail("allocations.scope", 0, -1, "too many allocation hooks") };
    var sources: [wire.max_hooks]rt.struct_xrt_allocation_source = undefined;
    for (config.sources, 0..) |source, i| {
        sources[i] = .{ .id = source.id, .kind = @intFromEnum(source.kind), .fd = source.fd, .offset = source.offset, .identity = .{ .device = source.identity.device, .inode = source.identity.inode, .size = source.identity.size, .mtime_sec = source.identity.mtime_sec, .mtime_ns = source.identity.mtime_ns, .ctime_sec = source.identity.ctime_sec, .ctime_ns = source.identity.ctime_ns } };
    }
    const Bridge = struct {
        fn open(raw: ?*anyopaque, tid: i32, group: c_int, file: c_int, offset: u64, returning: bool, leader: bool, stacks: bool) callconv(.c) c_int {
            const cfg: *const Config = @ptrCast(@alignCast(raw.?));
            const opener = cfg.opener.?;
            return opener.call(opener.user, tid, group, file, offset, returning, leader, stacks);
        }
        fn cancelled(raw: ?*anyopaque) callconv(.c) bool {
            const cfg: *const Config = @ptrCast(@alignCast(raw.?));
            return if (cfg.cancel) |cancel| cancel.load(.acquire) else false;
        }
    };
    const cfg = rt.struct_xrt_allocation_config{
        .pid = config.pid,
        .tids = config.tids.ptr,
        .thread_count = config.tids.len,
        .sources = &sources,
        .source_count = config.sources.len,
        .enable = config.enable,
        .callstacks = config.callstacks,
        .opener = if (config.opener != null) Bridge.open else null,
        .cancelled = Bridge.cancelled,
        .context = @constCast(&config),
    };
    var f: rt.struct_xrt_perf_failure = undefined;
    var mapping: rt.struct_xrt_mapping = undefined;
    var path: [8192]u8 = undefined;
    if (config.mapping) |region| {
        if (region.path.len >= path.len or std.mem.indexOfScalar(u8, region.path, 0) != null) return error.AllocationMappingIdentity;
        @memcpy(path[0..region.path.len], region.path);
        path[region.path.len] = 0;
        mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = @ptrCast(&path) };
    }
    const owner = rt.xrt_allocations_start_target(config.target, &cfg, if (config.mapping != null) &mapping else null, if (config.remote_helper) |helper| helper.ptr else null, &f) orelse return .{ .failed = kernel.failure(f) };
    errdefer rt.xrt_allocations_destroy(owner);
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .owner = owner, .handle = rt.xrt_allocations_perf(owner).?, .pid = config.pid, .source_count = config.sources.len, .callstacks = config.callstacks };
    for (config.sources, 0..) |source, i| self.hooks[i] = .{ .id = source.id, .kind = source.kind };
    return .{ .collector = self };
}
fn executableOffset(fd: c_int, offset: u64, _: c.struct_stat) !void {
    if (rt.xrt_allocation_offset(fd, offset)) |why| {
        if (std.mem.eql(u8, std.mem.span(why), "InvalidAllocationElf")) return error.InvalidAllocationElf;
        return error.AllocationOffsetNotExecutable;
    }
}
fn field(map: []u8, at: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + at));
}
const Slot = if (builtin.is_test) kernel.internal.struct_xrt_perf_slot else void;
test {
    std.testing.refAllDecls(Collector);
    std.testing.refAllDecls(@This());
}
fn mock(a: std.mem.Allocator, lanes: usize) !*Collector {
    const handle = rt.xrt_perf_create(data_pages, max_threads, std.math.maxInt(u64)) orelse return error.OutOfMemory;
    errdefer rt.xrt_perf_destroy(handle);
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .owner = null, .handle = handle, .pid = 12, .source_count = 1 };
    errdefer a.destroy(self);
    self.hooks[0] = .{ .id = 1, .kind = .malloc };
    const state = kernel.state(handle);
    for (0..lanes) |i| {
        const slot = &state.slots[i];
        state.count += 1;
        slot.thread.tid = @intCast(13 + i);
        slot.thread.event_count = 2;
        slot.fds = @splat(-1);
        slot.thread.event_ids[0] = 100;
        slot.thread.event_ids[1] = 101;
        const bytes = (1 + data_pages) * pageSize();
        const ptr = c.mmap(null, bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, @as(c.off_t, 0));
        if (@intFromPtr(ptr) == std.math.maxInt(usize)) return error.TestMmapFailed;
        slot.map = @ptrCast(ptr);
        slot.map_size = bytes;
        slot.owns_map = true;
        state.allocated += data_pages * pageSize();
        std.mem.writeInt(u64, slot.map[1040..1048], pageSize(), .little);
        std.mem.writeInt(u64, slot.map[1048..1056], data_pages * pageSize(), .little);
    }
    return self;
}
fn mockSample(slot: *Slot, at: u64, event_id: u64) void {
    var bytes: [80]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 9, .little);
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], bytes.len, .little);
    std.mem.writeInt(u32, bytes[8..12], 12, .little);
    std.mem.writeInt(i32, bytes[12..16], slot.thread.tid, .little);
    std.mem.writeInt(u64, bytes[16..24], at, .little);
    std.mem.writeInt(u64, bytes[24..32], event_id, .little);
    std.mem.writeInt(u64, bytes[32..40], 2, .little);
    std.mem.writeInt(u64, bytes[56..64], 37, .little);
    const ring = slot.map[pageSize()..slot.map_size];
    for (bytes, 0..) |byte, i| ring[@intCast((at + i) % ring.len)] = byte;
    @atomicStore(u64, field(slot.map[0..slot.map_size], 1024), at + bytes.len, .release);
}
test "allocation rings wrap records and fairly drain small output pages" {
    const collector = try mock(std.testing.allocator, 2);
    defer collector.close();
    var out: [1]Item = undefined;
    for (kernel.state(collector.handle).slots[0..2]) |*slot| {
        slot.tail = data_pages * pageSize() - 16;
        mockSample(slot, slot.tail, 100);
        mockSample(slot, slot.tail + 80, 101);
    }
    for (0..4) |i| {
        const result = collector.drain(&out);
        try std.testing.expectEqual(@as(?perf.Failure, null), result.failure);
        try std.testing.expectEqual(@as(usize, 1), result.count);
        try std.testing.expectEqual(@as(u16, @intCast(i % 2)), out[0].lane);
        try std.testing.expectEqual(@as(u64, 37), out[0].record.data.sample.registers.di);
    }
    const end = collector.drain(&out);
    try std.testing.expectEqual(@as(usize, 0), end.count);
    try std.testing.expect(!end.more);
}
test "malformed records preserve preceding output and latch a bounded diagnostic" {
    const collector = try mock(std.testing.allocator, 1);
    defer collector.close();
    mockSample(&kernel.state(collector.handle).slots[0], 0, 100);
    mockSample(&kernel.state(collector.handle).slots[0], 80, 999);
    var out: [8]Item = undefined;
    const result = collector.drain(&out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(result.failure != null);
    try std.testing.expectEqual(@as(usize, 80), collector.fault_len);
    try std.testing.expectEqual(@as(u64, 80), kernel.state(collector.handle).slots[0].tail);
    try std.testing.expectEqual(@as(usize, 0), collector.drain(&out).count);
}
test "invalid ring extent and overrun cannot produce decoded allocation evidence" {
    const collector = try mock(std.testing.allocator, 1);
    defer collector.close();
    @atomicStore(u64, field(kernel.state(collector.handle).slots[0].map[0..kernel.state(collector.handle).slots[0].map_size], 1024), data_pages * pageSize() + 1, .release);
    var out: [8]Item = undefined;
    const result = collector.drain(&out);
    try std.testing.expect(result.failure != null);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(u64, 0), kernel.state(collector.handle).slots[0].tail);
}
test "hook offsets must lie inside file-backed executable runtime ELF segments" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const fd = c.open("/proc/self/exe", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.TestElfUnavailable;
    defer _ = c.close(fd);
    var info: c.struct_stat = undefined;
    if (c.fstat(fd, &info) != 0) return error.TestStatFailed;
    var eh: [64]u8 = undefined;
    if (c.pread(fd, &eh, eh.len, 0) != eh.len) return error.TestElfUnavailable;
    const ph_offset = std.mem.readInt(u64, eh[32..40], .little);
    const n = std.mem.readInt(u16, eh[56..58], .little);
    var found = false;
    for (0..n) |i| {
        var ph: [56]u8 = undefined;
        if (c.pread(fd, &ph, ph.len, @intCast(ph_offset + i * ph.len)) != ph.len) return error.TestElfUnavailable;
        if (std.mem.readInt(u32, ph[0..4], .little) == 1 and std.mem.readInt(u32, ph[4..8], .little) & 1 != 0) {
            try executableOffset(fd, std.mem.readInt(u64, ph[8..16], .little), info);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try std.testing.expectError(error.InvalidAllocationElf, executableOffset(fd, @intCast(info.st_size), info));
}

noinline fn testMarker(value: u64) callconv(.c) u64 {
    return value +% 1;
}
fn testMarkerOffset(fd: c_int) !u64 {
    var info: c.Dl_info = undefined;
    const runtime = @intFromPtr(&testMarker);
    if (c.dladdr(@ptrFromInt(runtime), &info) == 0) return error.TestLoadBias;
    var eh: [64]u8 = undefined;
    if (c.pread(fd, &eh, eh.len, 0) != eh.len) return error.TestElfUnavailable;
    const kind = std.mem.readInt(u16, eh[16..18], .little);
    const link = if (kind == 2) runtime else runtime - @intFromPtr(info.dli_fbase);
    const offset = std.mem.readInt(u64, eh[32..40], .little);
    for (0..std.mem.readInt(u16, eh[56..58], .little)) |i| {
        var ph: [56]u8 = undefined;
        if (c.pread(fd, &ph, ph.len, @intCast(offset + i * ph.len)) != ph.len) return error.TestElfUnavailable;
        if (std.mem.readInt(u32, ph[0..4], .little) != 1) continue;
        const va = std.mem.readInt(u64, ph[16..24], .little);
        const size = std.mem.readInt(u64, ph[32..40], .little);
        if (link >= va and link - va < size) return std.mem.readInt(u64, ph[8..16], .little) + link - va;
    }
    return error.TestMarkerUnmapped;
}
fn fdCount() !usize {
    const dir = c.opendir("/proc/self/fd") orelse return error.TestFdDirectory;
    defer _ = c.closedir(dir);
    var count: usize = 0;
    while (c.readdir(dir)) |entry| {
        const name = entry.*.d_name;
        if (name[0] != '.') count += 1;
    }
    return count;
}
test "ordinary-user owned setup leaves descriptor counts unchanged on the observed outcome" {
    try @import("../test_support.zig").requireLive();
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const fd = c.open("/proc/self/exe", c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.TestElfUnavailable;
    defer _ = c.close(fd);
    const offset = try testMarkerOffset(fd);
    const child = c.fork();
    if (child < 0) return error.TestForkFailed;
    if (child == 0) {
        _ = c.raise(c.SIGSTOP);
        c._exit(0);
    }
    defer {
        _ = c.kill(child, c.SIGKILL);
        var status: c_int = 0;
        while (c.waitpid(child, &status, 0) < 0 and errno() == c.EINTR) {}
    }
    var status: c_int = 0;
    if (c.waitpid(child, &status, c.WUNTRACED) != child or !c.WIFSTOPPED(status)) return error.TestChildNotStopped;
    const before = try fdCount();
    var stale = try hooks.identity(fd);
    stale.mtime_ns +%= 1;
    const rejected = try start(std.testing.allocator, .{ .pid = child, .tids = &.{child}, .sources = &.{.{ .id = 1, .kind = .malloc, .fd = fd, .offset = offset, .identity = stale }} });
    switch (rejected) {
        .failed => |failure| {
            try std.testing.expectEqualStrings("allocations.file", failure.syscall);
            try std.testing.expectEqualStrings("runtime ELF changed after hook resolution", failure.detail);
            try std.testing.expectEqual(@as(usize, 0), failure.opened_then_closed);
        },
        .collector => |collector| {
            collector.close();
            return error.StaleAllocationSourceAccepted;
        },
    }
    try std.testing.expectEqual(before, try fdCount());
    const opened = try start(std.testing.allocator, .{ .pid = child, .tids = &.{child}, .sources = &.{.{ .id = 1, .kind = .malloc, .fd = fd, .offset = offset, .identity = try hooks.identity(fd) }} });
    switch (opened) {
        .failed => |failure| {
            try std.testing.expectEqual(.permission, failure.kind);
            try std.testing.expectEqualStrings("allocations.perf_event_open", failure.syscall);
            try std.testing.expect(failure.errno == c.EACCES or failure.errno == c.EPERM);
            std.debug.print("allocation setup: permission denied (errno={d}); live register semantics NOT tested\n", .{failure.errno});
        },
        .collector => |collector| {
            const stopped = collector.stop();
            collector.close();
            try std.testing.expect(stopped == null);
            std.debug.print("allocation setup: ordinary-user open/close succeeded; child remained stopped, register semantics NOT tested\n", .{});
        },
    }
    try std.testing.expectEqual(before, try fdCount());
}
