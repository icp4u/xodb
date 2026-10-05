//! Fixed-scope function observation over the authoritative C uprobe engine.
//! The caller holds target threads during preparation and validates the opening
//! generation/image again before publishing this collector to a live job.
const std = @import("std");
const wire = @import("perf.zig");
const types = @import("types.zig");
const kernel = @import("../profile/runtime.zig");
const rt = kernel.c;
const perf = @import("../profile/linux_perf.zig");
const hooks = @import("../profile/uprobe_hooks.zig");
const modules = @import("../model/modules.zig");
pub const max_threads = 32;
pub const Thread = struct { id: u64, tid: i32 };
pub const Config = struct {
    target: ?*const rt.struct_xrt_target,
    scope: rt.struct_xrt_function_scope,
    mapping: modules.Region,
    pid: i32,
    threads: []const Thread,
    sources: []const hooks.Source,
    helper: ?[:0]const u8 = null,
    enable: bool = false,
    callstacks: bool = true,
    cancel: ?*const std.atomic.Value(bool) = null,
};
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
pub const Drain = struct {
    count: usize = 0,
    more: bool = false,
    failure: ?perf.Failure = null,
    scope_changed: ?types.Reason = null,
};
fn failure(tid: i32, detail: []const u8) perf.Failure {
    return .{ .kind = .configuration, .syscall = "functions.drain", .errno = 0, .tid = tid, .detail = detail };
}
pub const Collector = struct {
    allocator: std.mem.Allocator,
    owner: *rt.struct_xrt_functions,
    handle: *rt.struct_xrt_perf,
    pid: i32,
    threads: [max_threads]Thread = undefined,
    thread_count: usize,
    ids: [wire.max_sources]u16 = undefined,
    source_count: usize,
    callstacks: bool,
    mapping_start: u64,
    mapping_end: u64,
    failed: bool = false,
    boundary: ?types.Reason = null,
    fault_bytes: [256]u8 = @splat(0),
    fault_len: usize = 0,
    pub fn enable(self: *Collector) ?perf.Failure {
        if (self.failed or self.boundary != null) return failure(-1, "collector has a terminal evidence boundary");
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_functions_enable(self.owner, &f)) null else kernel.failure(f);
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_stop(self.handle, &f)) null else kernel.failure(f);
    }
    pub fn close(self: *Collector) void {
        rt.xrt_functions_destroy(self.owner);
        self.allocator.destroy(self);
    }
    fn thread(self: *const Collector, tid: i32) !Thread {
        for (self.threads[0..self.thread_count]) |t| if (t.tid == tid) return t;
        return error.FunctionThreadIdentity;
    }
    const Decoding = struct {
        self: *Collector,
        out: []types.Event,
        result: Drain = .{},
        fn decode(raw: ?*anyopaque, view: [*c]const rt.struct_xrt_perf_ring) callconv(.c) rt.struct_xrt_perf_consumed {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            const ring = view[0];
            var tail = ring.tail;
            const status = ctx.consume(ring, &tail) catch |err| blk: {
                ctx.result.failure = failure(ring.thread[0].tid, @errorName(err));
                break :blk rt.XRT_PERF_DRAIN_MALFORMED;
            };
            return .{ .bytes = tail - ring.tail, .status = status };
        }
        fn consume(ctx: *@This(), ring: rt.struct_xrt_perf_ring, tail: *u64) !c_uint {
            const self = ctx.self;
            const t = try self.thread(ring.thread[0].tid);
            if (ring.thread[0].event_count != self.source_count * 2) return error.FunctionEventCount;
            var ids: [wire.max_sources]wire.Hook = undefined;
            for (self.ids[0..self.source_count], 0..) |id, i| ids[i] = .{ .id = id, .entry_id = ring.thread[0].event_ids[2 * i], .return_id = ring.thread[0].event_ids[2 * i + 1] };
            const identity = wire.Identity{ .pid = @intCast(self.pid), .tid = @intCast(t.tid), .hooks = ids[0..self.source_count], .callstacks = self.callstacks };
            var count: usize = 0;
            while (tail.* < ring.head and count < 128 and ctx.result.count < ctx.out.len) : (count += 1) {
                if (ring.head - tail.* < 8) return error.FunctionRingIncomplete;
                var bytes: [wire.max_record_size]u8 = undefined;
                kernel.copy(ring.data[0..ring.size], tail.*, bytes[0..8]);
                const size = std.mem.readInt(u16, bytes[6..8], .little);
                if (size < 8 or size > bytes.len or size > ring.head - tail.* or size % 8 != 0) return error.FunctionRecordSize;
                kernel.copy(ring.data[0..ring.size], tail.*, bytes[0..size]);
                var record = wire.decode(bytes[0..size], identity) catch |err| {
                    self.fault_len = @min(size, self.fault_bytes.len);
                    @memcpy(self.fault_bytes[0..self.fault_len], bytes[0..self.fault_len]);
                    return err;
                };
                record.time_ns = rt.xrt_perf_timestamp(self.handle, record.time_ns);
                tail.* += size;
                if (record.data == .probe_mapping) {
                    const m = record.data.probe_mapping;
                    if (m.start < self.mapping_end and self.mapping_start < m.end) record.data = .mapping_change;
                }
                if (record.event(t.id, @intCast(t.tid))) |event| {
                    ctx.out[ctx.result.count] = event;
                    ctx.result.count += 1;
                    const reason: ?types.Reason = switch (event.data) {
                        .exec => .exec,
                        .fork, .mapping_change => .scope_changed,
                        else => null,
                    };
                    if (reason) |why| {
                        self.boundary = why;
                        ctx.result.scope_changed = why;
                        return rt.XRT_PERF_DRAIN_STOP;
                    }
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
    /// Prefix only: after exec/fork/mapping change, future drains never expose
    /// uncertain suffix records, even if the caller retries this method.
    pub fn drain(self: *Collector, out: []types.Event) Drain {
        if (self.boundary) |why| return .{ .scope_changed = why };
        if (self.failed) return .{ .failure = failure(-1, "collector has a latched decoding/ring failure") };
        if (out.len == 0) return .{ .failure = failure(-1, "empty output buffer") };
        var ctx = Decoding{ .self = self, .out = out };
        const status = rt.xrt_perf_drain(self.handle, Decoding.decode, &ctx);
        ctx.result.more = ctx.result.more or status == rt.XRT_PERF_DRAIN_CAPACITY;
        if (status == rt.XRT_PERF_DRAIN_MALFORMED or status == rt.XRT_PERF_DRAIN_INCOMPLETE) {
            self.failed = true;
            if (ctx.result.failure == null) ctx.result.failure = failure(-1, "invalid or incomplete perf ring evidence");
        }
        if (self.failed or self.boundary != null) {
            if (self.stop()) |f| if (ctx.result.failure == null) {
                ctx.result.failure = f;
            };
            ctx.result.more = false;
        }
        return ctx.result;
    }
};
pub fn start(a: std.mem.Allocator, config: Config) !Opened {
    if (config.pid <= 0 or config.threads.len == 0 or config.threads.len > max_threads or config.sources.len == 0 or config.sources.len > wire.max_sources) return .{ .failed = failure(-1, "select 1..32 held threads and 1..16 function sources") };
    var tids: [max_threads]i32 = undefined;
    for (config.threads, 0..) |thread, i| {
        if (thread.id == 0 or thread.tid <= 0) return .{ .failed = failure(thread.tid, "invalid stable thread identity") };
        for (config.threads[0..i]) |old| if (old.id == thread.id or old.tid == thread.tid) return .{ .failed = failure(thread.tid, "duplicate stable thread identity") };
        tids[i] = thread.tid;
    }
    var sources: [wire.max_sources]rt.struct_xrt_function_source = undefined;
    for (config.sources, 0..) |source, i| sources[i] = .{ .id = source.id, .fd = source.fd, .offset = source.offset, .identity = .{ .device = source.identity.device, .inode = source.identity.inode, .size = source.identity.size, .mtime_sec = source.identity.mtime_sec, .mtime_ns = source.identity.mtime_ns, .ctime_sec = source.identity.ctime_sec, .ctime_ns = source.identity.ctime_ns } };
    const Bridge = struct {
        fn cancelled(raw: ?*anyopaque) callconv(.c) bool {
            const cfg: *const Config = @ptrCast(@alignCast(raw.?));
            return if (cfg.cancel) |cancel| cancel.load(.acquire) else false;
        }
    };
    const cfg = rt.struct_xrt_function_config{ .pid = config.pid, .tids = &tids, .thread_count = config.threads.len, .sources = &sources, .source_count = config.sources.len, .enable = config.enable, .callstacks = config.callstacks, .cancelled = Bridge.cancelled, .context = @constCast(&config) };
    var path: [8192]u8 = undefined;
    const region = config.mapping;
    if (region.path.len >= path.len or std.mem.indexOfScalar(u8, region.path, 0) != null) return error.FunctionMappingIdentity;
    @memcpy(path[0..region.path.len], region.path);
    path[region.path.len] = 0;
    const mapping = rt.struct_xrt_mapping{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = @ptrCast(&path) };
    var f: rt.struct_xrt_perf_failure = undefined;
    const owner = rt.xrt_functions_start_scoped(config.target, &config.scope, &cfg, &mapping, if (config.helper) |helper| helper.ptr else null, &f) orelse return .{ .failed = kernel.failure(f) };
    errdefer rt.xrt_functions_destroy(owner);
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .owner = owner, .handle = rt.xrt_functions_perf(owner).?, .pid = config.pid, .thread_count = config.threads.len, .source_count = config.sources.len, .callstacks = config.callstacks, .mapping_start = region.start, .mapping_end = region.end };
    @memcpy(self.threads[0..config.threads.len], config.threads);
    for (config.sources, 0..) |source, i| self.ids[i] = source.id;
    return .{ .collector = self };
}

const builtin = @import("builtin");
const test_c = if (builtin.is_test) @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
}) else struct {};
const Slot = if (builtin.is_test) kernel.internal.struct_xrt_perf_slot else void;
fn field(map: []u8, at: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + at));
}
fn mock(a: std.mem.Allocator, lanes: usize) !*Collector {
    const handle = rt.xrt_perf_create(1, max_threads, std.math.maxInt(u64)) orelse return error.OutOfMemory;
    errdefer rt.xrt_perf_destroy(handle);
    const self = try a.create(Collector);
    errdefer a.destroy(self);
    self.* = .{ .allocator = a, .owner = undefined, .handle = handle, .pid = 12, .thread_count = lanes, .source_count = 1, .callstacks = false, .mapping_start = 0x4000, .mapping_end = 0x5000 };
    self.ids[0] = 1;
    const state = kernel.state(handle);
    const page = rt.xrt_perf_page_size();
    for (0..lanes) |i| {
        self.threads[i] = .{ .id = 501 + i, .tid = @intCast(13 + i) };
        const slot = &state.slots[i];
        state.count += 1;
        slot.thread.tid = self.threads[i].tid;
        slot.thread.event_count = 2;
        slot.fds = @splat(-1);
        slot.thread.event_ids[0] = 100;
        slot.thread.event_ids[1] = 101;
        const ptr = test_c.mmap(null, 2 * page, test_c.PROT_READ | test_c.PROT_WRITE, test_c.MAP_PRIVATE | test_c.MAP_ANONYMOUS, -1, @as(test_c.off_t, 0));
        if (@intFromPtr(ptr) == std.math.maxInt(usize)) return error.TestMmapFailed;
        slot.map = @ptrCast(ptr);
        slot.map_size = 2 * page;
        slot.owns_map = true;
        state.allocated += page;
        std.mem.writeInt(u64, slot.map[1040..1048], page, .little);
        std.mem.writeInt(u64, slot.map[1048..1056], page, .little);
    }
    return self;
}
fn destroyMock(self: *Collector) void {
    rt.xrt_perf_destroy(self.handle);
    self.allocator.destroy(self);
}
fn write(slot: *Slot, at: u64, bytes: []const u8) void {
    const ring = slot.map[rt.xrt_perf_page_size()..slot.map_size];
    for (bytes, 0..) |byte, i| ring[@intCast((at + i) % ring.len)] = byte;
    @atomicStore(u64, field(slot.map[0..slot.map_size], 1024), at + bytes.len, .release);
}
fn sample(slot: *Slot, at: u64, id: u64) void {
    var bytes: [112]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 9, .little);
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], bytes.len, .little);
    std.mem.writeInt(u32, bytes[8..12], 12, .little);
    std.mem.writeInt(i32, bytes[12..16], slot.thread.tid, .little);
    std.mem.writeInt(u64, bytes[16..24], at, .little);
    std.mem.writeInt(u64, bytes[24..32], id, .little);
    std.mem.writeInt(u64, bytes[32..40], 2, .little);
    std.mem.writeInt(u64, bytes[72..80], 37, .little);
    std.mem.writeInt(u64, bytes[80..88], if (id == 100) 0x1000 else 0x1008, .little);
    write(slot, at, &bytes);
}
test {
    std.testing.refAllDecls(Collector);
    std.testing.refAllDecls(@This());
}
test "function rings wrap and retain configured stable identity across fair drain pages" {
    const collector = try mock(std.testing.allocator, 2);
    defer destroyMock(collector);
    for (kernel.state(collector.handle).slots[0..2]) |*slot| {
        slot.tail = rt.xrt_perf_page_size() - 16;
        sample(slot, slot.tail, 100);
        sample(slot, slot.tail + 112, 101);
    }
    var out: [1]types.Event = undefined;
    for (0..4) |i| {
        const result = collector.drain(&out);
        try std.testing.expect(result.failure == null and result.count == 1);
        try std.testing.expectEqual(@as(u64, 501 + i % 2), out[0].thread_id);
        try std.testing.expectEqual(@as(u64, 0x1000), out[0].data.sample.stack_key);
    }
    const end = collector.drain(&out);
    try std.testing.expect(end.count == 0 and !end.more);
}
test "function malformed suffix preserves prefix and latches failure without consuming uncertain bytes" {
    const collector = try mock(std.testing.allocator, 1);
    defer destroyMock(collector);
    const slot = &kernel.state(collector.handle).slots[0];
    sample(slot, 0, 100);
    sample(slot, 112, 999);
    var out: [8]types.Event = undefined;
    const result = collector.drain(&out);
    try std.testing.expect(result.count == 1 and result.failure != null);
    try std.testing.expectEqual(@as(u64, 112), slot.tail);
    try std.testing.expectEqual(@as(usize, 112), collector.fault_len);
    try std.testing.expectEqual(@as(usize, 0), collector.drain(&out).count);
}
test "function scope boundary stops current and subsequent drains before another sample or lane" {
    const collector = try mock(std.testing.allocator, 2);
    defer destroyMock(collector);
    const state = kernel.state(collector.handle);
    const slot = &state.slots[0];
    sample(slot, 0, 100);
    var exec: [48]u8 = @splat(0);
    std.mem.writeInt(u32, exec[0..4], 3, .little);
    std.mem.writeInt(u16, exec[4..6], 1 << 13, .little);
    std.mem.writeInt(u16, exec[6..8], exec.len, .little);
    std.mem.writeInt(u32, exec[8..12], 12, .little);
    std.mem.writeInt(i32, exec[12..16], slot.thread.tid, .little);
    std.mem.writeInt(u32, exec[24..28], 12, .little);
    std.mem.writeInt(i32, exec[28..32], slot.thread.tid, .little);
    std.mem.writeInt(u64, exec[32..40], 112, .little);
    std.mem.writeInt(u64, exec[40..48], 100, .little);
    write(slot, 112, &exec);
    sample(slot, 160, 101);
    sample(&state.slots[1], 0, 100);
    var out: [8]types.Event = undefined;
    const result = collector.drain(&out);
    try std.testing.expect(result.count == 2 and result.scope_changed == .exec and result.failure == null and !result.more);
    try std.testing.expect(out[1].data == .exec);
    try std.testing.expectEqual(@as(u64, 160), slot.tail);
    try std.testing.expectEqual(@as(u64, 0), state.slots[1].tail);
    const again = collector.drain(&out);
    try std.testing.expect(again.count == 0 and again.scope_changed == .exec and !again.more);
}
test "function invalid ring extent cannot produce evidence" {
    const collector = try mock(std.testing.allocator, 1);
    defer destroyMock(collector);
    const slot = &kernel.state(collector.handle).slots[0];
    @atomicStore(u64, field(slot.map[0..slot.map_size], 1024), rt.xrt_perf_page_size() + 1, .release);
    var out: [8]types.Event = undefined;
    const result = collector.drain(&out);
    try std.testing.expect(result.failure != null and result.count == 0 and slot.tail == 0);
}
