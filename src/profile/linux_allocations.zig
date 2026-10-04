//! Task-local perf uprobes over pinned runtime ELF files. No policy changes,
//! process discovery, privilege escalation, GUI access or automatic fallback.
//! Caller holds the selected threads stopped until start returns. Raw registers
//! are normalized by the allocation session owner using the verified adapter.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("allocation_perf.zig");
const perf = @import("linux_perf.zig");
const hooks = @import("allocation_hooks.zig");
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
    call: *const fn (*anyopaque, i32, c_int, c_int, u64, bool, bool) c_int,
};
pub const Config = struct { pid: i32, tids: []const i32, sources: []const Source, opener: ?Opener = null, enable: bool = true, cancel: ?*const std.atomic.Value(bool) = null };
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
pub const Item = struct { lane: u16, record: wire.Record };
pub const Drain = struct { count: usize = 0, more: bool = false, failure: ?perf.Failure = null };
const File = struct { fd: c_int = -1, source: Source = undefined, identity: c.struct_stat = undefined };
const Slot = struct {
    tid: i32 = 0,
    fds: [wire.max_hooks * 2]c_int = @splat(-1),
    ids: [wire.max_hooks]wire.Hook = undefined,
    opened: usize = 0,
    map: []u8 = &.{},
    tail: u64 = 0,
};
pub const Collector = struct {
    allocator: std.mem.Allocator,
    pid: i32,
    slots: [max_threads]Slot = @splat(.{}),
    files: [wire.max_hooks]File = @splat(.{}),
    count: usize = 0,
    source_count: usize = 0,
    cursor: usize = 0,
    running: bool = false,
    failed: bool = false,
    /// Retain one bounded malformed record for diagnostics.
    fault_bytes: [256]u8 = @splat(0),
    fault_len: usize = 0,
    pub fn enable(self: *Collector) ?perf.Failure {
        for (self.slots[0..self.count]) |slot| heldThread(self.pid, slot.tid) catch |err| return fail("allocations.scope", errno(), slot.tid, @errorName(err));
        for (self.files[0..self.source_count]) |file| {
            var current: c.struct_stat = undefined;
            if (c.fstat(file.fd, &current) != 0 or !sameFile(file.identity, current)) return fail("allocations.file", 0, -1, "runtime ELF changed during preparation");
        }
        for (self.slots[0..self.count]) |slot| {
            if (c.ioctl(slot.fds[0], @as(c_ulong, c.PERF_EVENT_IOC_ENABLE), @as(c_ulong, c.PERF_IOC_FLAG_GROUP)) != 0) {
                const failure = fail("allocations.enable", errno(), slot.tid, "enable allocation event group");
                _ = self.stop();
                return failure;
            }
        }
        self.running = true;
        return null;
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var failure: ?perf.Failure = null;
        for (self.slots[0..self.count]) |slot| if (slot.fds[0] >= 0) {
            if (c.ioctl(slot.fds[0], @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, c.PERF_IOC_FLAG_GROUP)) != 0 and errno() != c.ESRCH)
                failure = fail("allocations.disable", errno(), slot.tid, "disable allocation event group; an unread suffix may remain");
        };
        self.running = false;
        return failure;
    }
    pub fn close(self: *Collector) void {
        _ = self.stop();
        for (self.slots[0..self.count]) |slot| {
            for (slot.fds[0..slot.opened]) |fd| _ = c.close(fd);
            if (slot.map.len > 0) _ = c.munmap(slot.map.ptr, slot.map.len);
        }
        for (self.files[0..self.source_count]) |file| if (file.fd >= 0) {
            _ = c.close(file.fd);
        };
        self.allocator.destroy(self);
    }
    fn rollback(self: *Collector, reason: perf.Failure) Opened {
        var result = reason;
        for (self.slots[0..self.count]) |slot| result.opened_then_closed +|= @intCast(slot.opened);
        self.close();
        return .{ .failed = result };
    }
    fn fault(self: *Collector, count: usize, tid: i32, detail: []const u8) Drain {
        self.failed = true;
        _ = self.stop();
        return .{ .count = count, .failure = fail("allocations.drain", 0, tid, detail) };
    }
    /// Bounded and fair even with a small output slice. On failure, preceding
    /// output items are still returned: publish them before marking the gap.
    /// Disable all groups, then drain to more=false before claiming complete.
    pub fn drain(self: *Collector, out: []Item) Drain {
        if (self.failed) return .{ .failure = fail("allocations.drain", 0, -1, "collector has a latched decode/ring failure") };
        if (out.len == 0) return .{ .failure = fail("allocations.drain", 0, -1, "empty output buffer") };
        var result = Drain{};
        var scanned: usize = 0;
        while (scanned < self.count) : (scanned += 1) {
            const index = self.cursor;
            self.cursor = (self.cursor + 1) % self.count;
            const slot = &self.slots[index];
            const offset = std.mem.readInt(u64, slot.map[1040..1048], .little);
            const size = std.mem.readInt(u64, slot.map[1048..1056], .little);
            if (offset != pageSize() or size != data_pages * pageSize() or offset > slot.map.len or size > slot.map.len - offset)
                return self.fault(result.count, slot.tid, "unexpected perf ring layout");
            const head = @atomicLoad(u64, field(slot.map, 1024), .acquire);
            if (head < slot.tail or head - slot.tail > size) return self.fault(result.count, slot.tid, "perf ring overrun or reversed cursor");
            const ring = slot.map[@intCast(offset)..][0..@intCast(size)];
            var records_read: usize = 0;
            while (slot.tail < head and records_read < 128 and result.count < out.len) : (records_read += 1) {
                if (head - slot.tail < 8) return self.fault(result.count, slot.tid, "incomplete perf header");
                var bytes: [256]u8 = undefined;
                copy(ring, slot.tail, bytes[0..8]);
                const size_ = std.mem.readInt(u16, bytes[6..8], .little);
                if (size_ < 8 or size_ > bytes.len or size_ > head - slot.tail or size_ % 8 != 0)
                    return self.fault(result.count, slot.tid, "invalid perf record size");
                copy(ring, slot.tail, bytes[0..size_]);
                const record = wire.decode(bytes[0..size_], .{ .pid = @intCast(self.pid), .tid = @intCast(slot.tid), .hooks = slot.ids[0..self.source_count] }) catch |err| {
                    @memcpy(self.fault_bytes[0..size_], bytes[0..size_]);
                    self.fault_len = size_;
                    return self.fault(result.count, slot.tid, @errorName(err));
                };
                slot.tail += size_;
                // Publish consumed bytes even if a subsequent record is bad.
                @atomicStore(u64, field(slot.map, 1032), slot.tail, .seq_cst);
                out[result.count] = .{ .lane = @intCast(index), .record = record };
                result.count += 1;
                if (record.data == .exec or record.data == .fork) {
                    // Existing heap scope/identity has ended. The owner must
                    // retain this record and mark an incomplete ending.
                    _ = self.stop();
                    result.more = true;
                    return result;
                }
            }
            result.more = result.more or slot.tail < head;
            if (result.count == out.len) {
                // Some rings may not have been visited. A subsequent empty
                // drain is required before claiming a complete suffix.
                result.more = true;
                return result;
            }
        }
        return result;
    }
};
fn errno() c_int {
    return std.c._errno().*;
}
fn fail(stage: []const u8, n: c_int, tid: i32, detail: []const u8) perf.Failure {
    return .{ .kind = if (n == c.EACCES or n == c.EPERM) .permission else if (n == c.ESRCH) .thread_gone else if (n == c.ENOMEM or n == c.EMFILE or n == c.ENFILE) .resource else if (n == c.ENOENT or n == c.ENODEV or n == c.ENOSYS or n == c.EOPNOTSUPP) .unavailable else .configuration, .syscall = stage, .errno = n, .tid = tid, .detail = detail };
}
fn pageSize() usize {
    const n = c.sysconf(c._SC_PAGESIZE);
    return if (n > 0) @intCast(n) else 4096;
}
fn field(map: []u8, at: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + at));
}
fn copy(ring: []const u8, tail: u64, out: []u8) void {
    const at: usize = @intCast(tail & (ring.len - 1));
    const first = @min(out.len, ring.len - at);
    @memcpy(out[0..first], ring[at..][0..first]);
    @memcpy(out[first..], ring[0 .. out.len - first]);
}
fn read(path: [:0]const u8, bytes: []u8) ![]const u8 {
    std.c._errno().* = 0;
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.AllocationMetadataRead;
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < bytes.len) {
        const n = c.read(fd, bytes.ptr + used, bytes.len - used);
        if (n < 0) {
            if (errno() == c.EINTR) continue;
            return error.AllocationMetadataRead;
        }
        if (n == 0) return bytes[0..used];
        used += @intCast(n);
    }
    std.c._errno().* = c.E2BIG;
    return error.AllocationMetadataSize;
}
fn heldThread(pid: i32, tid: i32) !void {
    var path: [80]u8 = undefined;
    var bytes: [8192]u8 = undefined;
    const data = try read(try std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}/status", .{ pid, tid }), &bytes);
    var tgid = false;
    var stopped = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Tgid:")) tgid = (std.fmt.parseInt(i32, std.mem.trim(u8, line[5..], " \t"), 10) catch return error.AllocationTaskIdentity) == pid;
        if (std.mem.startsWith(u8, line, "State:")) {
            const value = std.mem.trim(u8, line[6..], " \t");
            stopped = value.len > 0 and (value[0] == 't' or value[0] == 'T');
        }
    }
    if (!tgid or !stopped) return error.AllocationRequiresHeldThread;
}
fn sameFile(a: c.struct_stat, b: c.struct_stat) bool {
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino and a.st_size == b.st_size and std.meta.eql(a.st_mtim, b.st_mtim) and std.meta.eql(a.st_ctim, b.st_ctim);
}
fn executableOffset(fd: c_int, offset: u64, stat: c.struct_stat) !void {
    if (stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 64 or offset >= @as(u64, @intCast(stat.st_size))) return error.InvalidAllocationElf;
    var header: [64]u8 = undefined;
    if (c.pread(fd, &header, header.len, 0) != header.len or !std.mem.eql(u8, header[0..6], "\x7fELF\x02\x01") or std.mem.readInt(u16, header[18..20], .little) != 62) return error.InvalidAllocationElf;
    const elf_type = std.mem.readInt(u16, header[16..18], .little);
    if (elf_type != 2 and elf_type != 3) return error.InvalidAllocationElf;
    const ph_start = std.mem.readInt(u64, header[32..40], .little);
    const stride = std.mem.readInt(u16, header[54..56], .little);
    const count = std.mem.readInt(u16, header[56..58], .little);
    if (stride != 56 or count == 0 or count > 4096 or ph_start > @as(u64, @intCast(stat.st_size)) or @as(u64, stride) * count > @as(u64, @intCast(stat.st_size)) - ph_start) return error.InvalidAllocationElf;
    for (0..count) |i| {
        var ph: [56]u8 = undefined;
        if (c.pread(fd, &ph, ph.len, @intCast(ph_start + i * stride)) != ph.len) return error.InvalidAllocationElf;
        if (std.mem.readInt(u32, ph[0..4], .little) != 1 or std.mem.readInt(u32, ph[4..8], .little) & 1 == 0) continue;
        const from = std.mem.readInt(u64, ph[8..16], .little);
        const size = std.mem.readInt(u64, ph[32..40], .little);
        if (from <= offset and offset - from < size and from <= @as(u64, @intCast(stat.st_size)) and size <= @as(u64, @intCast(stat.st_size)) - from) return;
    }
    return error.AllocationOffsetNotExecutable;
}
fn openEvent(tid: i32, group: c_int, pmu: u32, ret: u64, file: File, leader: bool) c_int {
    var path: [64]u8 = undefined;
    const pinned = std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{file.fd}) catch unreachable;
    var attr = std.mem.zeroes(perf.Attr);
    attr.size = 96;
    attr.typ = pmu;
    attr.config = ret;
    attr.config1 = @intFromPtr(pinned.ptr);
    attr.config2 = file.source.offset;
    attr.sample_period = 1;
    attr.sample_type = wire.sample_type;
    attr.sample_regs_user = wire.register_mask;
    attr.flags = 1 | (1 << 5) | (1 << 6) | (1 << 18) | (1 << 25);
    if (leader) attr.flags |= (1 << 9) | (1 << 13) | (1 << 24);
    attr.clockid = c.CLOCK_MONOTONIC;
    return @intCast(c.syscall(@as(c_long, c.SYS_perf_event_open), &attr, @as(c.pid_t, tid), @as(c_int, -1), group, @as(c_ulong, c.PERF_FLAG_FD_CLOEXEC)));
}
pub fn start(a: std.mem.Allocator, config: Config) !Opened {
    if (builtin.cpu.arch != .x86_64) return .{ .failed = fail("allocations.architecture", 0, -1, "uprobe register decoding currently supports Linux x86-64") };
    if (config.pid <= 0 or config.tids.len == 0 or config.tids.len > max_threads or config.sources.len == 0 or config.sources.len > wire.max_hooks) return .{ .failed = fail("allocations.scope", 0, -1, "select 1..32 held threads and 1..16 explicit runtime ELF hooks") };
    for (config.tids, 0..) |tid, i| {
        if (tid <= 0 or std.mem.indexOfScalar(i32, config.tids[0..i], tid) != null) return .{ .failed = fail("allocations.scope", 0, tid, "invalid or duplicate selected thread") };
        heldThread(config.pid, tid) catch |err| return .{ .failed = fail("allocations.scope", errno(), tid, @errorName(err)) };
    }
    var text: [128]u8 = undefined;
    const type_text = read("/sys/bus/event_source/devices/uprobe/type", &text) catch |err| return .{ .failed = fail("allocations.pmu", errno(), -1, @errorName(err)) };
    const pmu = std.fmt.parseInt(u32, std.mem.trim(u8, type_text, " \t\r\n"), 10) catch return .{ .failed = fail("allocations.pmu", 0, -1, "invalid uprobe PMU type") };
    const format = read("/sys/bus/event_source/devices/uprobe/format/retprobe", &text) catch |err| return .{ .failed = fail("allocations.pmu", errno(), -1, @errorName(err)) };
    const mask = wire.retprobeMask(format) catch |err| return .{ .failed = fail("allocations.pmu", 0, -1, @errorName(err)) };
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .pid = config.pid };
    for (config.sources) |source| {
        const file = &self.files[self.source_count];
        self.source_count += 1;
        file.source = source;
        file.fd = c.fcntl(source.fd, c.F_DUPFD_CLOEXEC, @as(c_int, 0));
        if (file.fd < 0 or c.fstat(file.fd, &file.identity) != 0) return self.rollback(fail("allocations.file", errno(), -1, "cannot pin runtime ELF descriptor"));
        if (!std.meta.eql(source.identity, hooks.Identity.fromStat(file.identity))) return self.rollback(fail("allocations.file", 0, -1, "runtime ELF changed after hook resolution"));
        executableOffset(file.fd, source.offset, file.identity) catch |err| return self.rollback(fail("allocations.file", 0, -1, @errorName(err)));
        for (self.files[0 .. self.source_count - 1]) |old| {
            if (old.source.id == source.id or (old.identity.st_dev == file.identity.st_dev and old.identity.st_ino == file.identity.st_ino and old.source.offset == source.offset))
                return self.rollback(fail("allocations.file", 0, -1, "duplicate hook ID or aliased file offset would double-count calls"));
        }
    }
    for (config.tids) |tid| {
        const slot = &self.slots[self.count];
        self.count += 1;
        slot.tid = tid;
        for (self.files[0..self.source_count], 0..) |file, hook_index| {
            var ids: [2]u64 = undefined;
            for (0..2) |phase| {
                const leader = slot.opened == 0;
                if (config.cancel) |cancel| if (cancel.load(.acquire)) return self.rollback(fail("allocations.cancel", c.ECANCELED, tid, "allocation preparation cancelled"));
                const fd = if (config.opener) |opener| opener.call(opener.user, tid, slot.fds[0], file.fd, file.source.offset, phase == 1, leader) else openEvent(tid, slot.fds[0], pmu, if (phase == 1) mask else 0, file, leader);
                if (fd < 0) return self.rollback(fail("allocations.perf_event_open", errno(), tid, "task-local uprobe open failed; current kernels require CAP_SYS_ADMIN for creation"));
                slot.fds[slot.opened] = fd;
                slot.opened += 1;
                if (c.ioctl(fd, @as(c_ulong, c.PERF_EVENT_IOC_ID), &ids[phase]) != 0) return self.rollback(fail("allocations.id", errno(), tid, "PERF_EVENT_IOC_ID"));
                if (leader) {
                    const bytes = (1 + data_pages) * pageSize();
                    const ptr = c.mmap(null, bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, @as(c.off_t, 0));
                    if (@intFromPtr(ptr) == std.math.maxInt(usize)) return self.rollback(fail("allocations.mmap", errno(), tid, "uprobe ring mmap failed"));
                    slot.map = @as([*]u8, @ptrCast(ptr))[0..bytes];
                } else if (c.ioctl(fd, @as(c_ulong, c.PERF_EVENT_IOC_SET_OUTPUT), slot.fds[0]) != 0) return self.rollback(fail("allocations.output", errno(), tid, "shared per-task ring"));
            }
            slot.ids[hook_index] = .{ .id = file.source.id, .kind = file.source.kind, .entry_id = ids[0], .return_id = ids[1] };
        }
        wire.validateIdentity(.{ .pid = @intCast(config.pid), .tid = @intCast(tid), .hooks = slot.ids[0..self.source_count] }) catch |err| return self.rollback(fail("allocations.identity", 0, tid, @errorName(err)));
    }
    for (self.files[0..self.source_count]) |file| {
        var current: c.struct_stat = undefined;
        if (c.fstat(file.fd, &current) != 0 or !sameFile(file.identity, current)) return self.rollback(fail("allocations.file", 0, -1, "runtime ELF changed while opening probes"));
    }
    if (config.enable) if (self.enable()) |failure| return self.rollback(failure);
    return .{ .collector = self };
}

test {
    std.testing.refAllDecls(Collector);
    std.testing.refAllDecls(@This());
}
fn mock(a: std.mem.Allocator, lanes: usize) !*Collector {
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .pid = 12, .source_count = 1 };
    errdefer self.close();
    for (0..lanes) |i| {
        const slot = &self.slots[i];
        self.count += 1;
        slot.tid = @intCast(13 + i);
        slot.ids[0] = .{ .id = 1, .kind = .malloc, .entry_id = 100, .return_id = 101 };
        const bytes = (1 + data_pages) * pageSize();
        const ptr = c.mmap(null, bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, @as(c.off_t, 0));
        if (@intFromPtr(ptr) == std.math.maxInt(usize)) return error.TestMmapFailed;
        slot.map = @as([*]u8, @ptrCast(ptr))[0..bytes];
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
    std.mem.writeInt(i32, bytes[12..16], slot.tid, .little);
    std.mem.writeInt(u64, bytes[16..24], at, .little);
    std.mem.writeInt(u64, bytes[24..32], event_id, .little);
    std.mem.writeInt(u64, bytes[32..40], 2, .little);
    std.mem.writeInt(u64, bytes[56..64], 37, .little);
    const ring = slot.map[pageSize()..];
    for (bytes, 0..) |byte, i| ring[@intCast((at + i) % ring.len)] = byte;
    @atomicStore(u64, field(slot.map, 1024), at + bytes.len, .release);
}
test "allocation rings wrap records and fairly drain small output pages" {
    const collector = try mock(std.testing.allocator, 2);
    defer collector.close();
    var out: [1]Item = undefined;
    for (collector.slots[0..2]) |*slot| {
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
    mockSample(&collector.slots[0], 0, 100);
    mockSample(&collector.slots[0], 80, 999);
    var out: [8]Item = undefined;
    const result = collector.drain(&out);
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(result.failure != null);
    try std.testing.expectEqual(@as(usize, 80), collector.fault_len);
    try std.testing.expectEqual(@as(u64, 80), collector.slots[0].tail);
    try std.testing.expectEqual(@as(usize, 0), collector.drain(&out).count);
}
test "invalid ring extent and overrun cannot produce decoded allocation evidence" {
    const collector = try mock(std.testing.allocator, 1);
    defer collector.close();
    @atomicStore(u64, field(collector.slots[0].map, 1024), data_pages * pageSize() + 1, .release);
    var out: [8]Item = undefined;
    const result = collector.drain(&out);
    try std.testing.expect(result.failure != null);
    try std.testing.expectEqual(@as(usize, 0), result.count);
    try std.testing.expectEqual(@as(u64, 0), collector.slots[0].tail);
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
