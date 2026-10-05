//! One-caller-thread CPU sampling collector over perf_event_open(2).
//!
//! The caller passes an explicit tid list. Nothing here scans /proc for
//! tasks or turns a hardware counter failure into a software clock.
//! `inherit` stays off. The owner may explicitly enroll held newborn threads.
//! `context_switch` defaults off. When set, the kernel adds per-task
//! PERF_RECORD_SWITCH records. CPU-wide switch records are not requested.
//! `user_regs_mask` and `user_stack_bytes` default to zero. When either is
//! set, samples can carry user registers and a bounded user-stack dump.
//! That does not change the kernel callchain or the default capture.
//!
//! Timestamps are CLOCK_MONOTONIC nanoseconds (attr.use_clockid). That is
//! the same clock as clock_gettime(CLOCK_MONOTONIC), not wall time.
//!
//! Ring protocol, from the mmap page comment in include/uapi/linux/perf_event.h:
//! load data_head with an acquire barrier, read bytes, then store data_tail
//! with a full barrier so the kernel does not overwrite records still queued.

const std = @import("std");
const records = @import("records.zig");
const runtime = @import("runtime.zig");
const rt = runtime.c;

pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // glibc fortified fcntl wrappers cannot be translated in ReleaseSafe
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1"); // translate-c needs one ioctl declaration
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/syscall.h");
    @cInclude("linux/perf_event.h");
    @cInclude("time.h");
});

pub const max_threads: u16 = 1024;
pub const max_data_pages: u8 = 64;
pub const max_samples_cap: u16 = 4096;
pub const max_sides_cap: u16 = 2048;

const off_data_head: usize = 1024;
const off_data_tail: usize = 1032;
pub const Clock = enum { task, cpu };
pub const Hardware = enum { none, cpu_cycles };
pub const EventKind = enum { task_clock, cpu_clock, cpu_cycles };

pub const Config = struct {
    target: ?*const rt.struct_xrt_target = null,
    follow_threads: bool = false,
    tids: []const i32,
    clock: Clock = .task,
    /// When this is not `.none`, the open uses that hardware event. A failure
    /// is returned as-is; the collector does not substitute a software clock.
    hardware: Hardware = .none,
    frequency_hz: u32 = 99,
    max_frames: u16 = 32,
    /// Power of two. Total mapping is `(1 + data_pages)` pages per thread.
    data_pages: u8 = 4,
    /// Data-ring ceiling, excluding one metadata page per live event.
    ring_budget_bytes: u64 = 64 * 1024 * 1024,
    max_samples: u16 = 1024,
    max_sides: u16 = 512,
    exclude_kernel: bool = true,
    mmap_data: bool = false,
    callchain: bool = true,
    include_weight: bool = false,
    /// Per-task PERF_RECORD_SWITCH records. Off unless the caller asks.
    /// Does not change sample_type, exclude_kernel, or the thread list.
    context_switch: bool = false,
    /// `attr.sample_regs_user`. Zero leaves PERF_SAMPLE_REGS_USER off.
    /// Bits above the x86 GPR file are rejected.
    user_regs_mask: u64 = 0,
    /// `attr.sample_stack_user`. Zero leaves PERF_SAMPLE_STACK_USER off.
    /// A non-zero value must be a multiple of 8, from 64 through 8192,
    /// and the mask must include the stack pointer and instruction pointer.
    user_stack_bytes: u32 = 0,
};

pub const FailureKind = enum { unavailable, permission, configuration, thread_gone, resource, other };

pub const Failure = struct {
    kind: FailureKind,
    syscall: []const u8,
    errno: i32 = 0,
    /// Thread the failing call was about, or -1 when the request was rejected
    /// before any thread was opened.
    tid: i32 = -1,
    /// File descriptors successfully opened, then closed, before returning.
    opened_then_closed: u16 = 0,
    detail: []const u8 = "",
};

pub const ThreadInfo = struct {
    tid: i32,
    event_id: u64,
    /// `starttime` from `/proc/<tid>/stat`, in clock ticks since boot.
    /// This is not a debugger thread id. A recycled tid has a new value.
    start_time_ticks: u64,
    start_time_known: bool,
};

pub const Acceptance = struct {
    event: EventKind,
    requested_frequency_hz: u32,
    kernel_max_sample_rate: u32,
    kernel_max_stack: u32,
    exclude_kernel: bool,
    mmap_data: bool,
    callchain: bool,
    include_weight: bool,
    sample_type: u64,
    sample_max_stack: u16,
    /// clock_gettime clock id used for sample timestamps.
    clockid: i32,
    ring_data_bytes: u64,
    /// Byte offset of the data ring within the mapping, as published by the kernel.
    data_offset: u64,
    mmap_version: u32,
    threads: u16,
    /// Echo of Config.context_switch after a successful open. The kernel
    /// accepted the attr that carried this bit; a rejection is a Failure.
    context_switch: bool,
    /// Echo of the user-register mask and stack dump size actually opened.
    /// Both stay zero on the default capture.
    user_regs_mask: u64 = 0,
    user_stack_bytes: u32 = 0,
};

pub const DrainStatus = enum { ok, capacity, malformed, incomplete, closed };

pub const Drain = struct {
    /// Valid until the next `drain` or `close` on this collector.
    samples: []const records.Sample,
    sides: []const records.Side,
    status: DrainStatus,
    skipped_unknown: u32,
    reason: []const u8,
    /// Valid until the next `drain` or `close`, like `samples`. Empty when
    /// user register and stack capture were left off.
    user_states: []const records.UserState = &.{},
    user_stack: []const u8 = &.{},
};

pub const Opened = union(enum) {
    collector: *Collector,
    failed: Failure,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    handle: *rt.struct_xrt_perf,
    accepted: rt.struct_xrt_cpu_acceptance = std.mem.zeroes(rt.struct_xrt_cpu_acceptance),
    samples: []records.Sample,
    sides: []records.Side,
    event: EventKind,
    requested_frequency_hz: u32,
    kernel_max_sample_rate: u32,
    kernel_max_stack: u32,
    exclude_kernel: bool,
    mmap_data: bool,
    callchain: bool,
    include_weight: bool,
    context_switch: bool,
    user_regs_mask: u64 = 0,
    user_stack_bytes: u32 = 0,
    user_states: []records.UserState = &.{},
    user_stack: []u8 = &.{},
    sample_type: u64,
    sample_max_stack: u16,
    clockid: i32,
    ring_data_bytes: u64,
    data_offset: u64 = 0,
    mmap_version: u32,

    pub fn acceptance(self: *const Collector) Acceptance {
        return .{
            .event = self.event,
            .requested_frequency_hz = self.requested_frequency_hz,
            .kernel_max_sample_rate = self.kernel_max_sample_rate,
            .kernel_max_stack = self.kernel_max_stack,
            .exclude_kernel = self.exclude_kernel,
            .mmap_data = self.mmap_data,
            .callchain = self.callchain,
            .include_weight = self.include_weight,
            .context_switch = self.context_switch,
            .user_regs_mask = self.user_regs_mask,
            .user_stack_bytes = self.user_stack_bytes,
            .sample_type = self.sample_type,
            .sample_max_stack = self.sample_max_stack,
            .clockid = self.clockid,
            .ring_data_bytes = self.ring_data_bytes,
            .data_offset = self.data_offset,
            .mmap_version = self.mmap_version,
            .threads = @intCast(runtime.info(self.handle).threads),
        };
    }

    pub fn allocatedRingBytes(self: *const Collector) u64 {
        return runtime.info(self.handle).allocated_ring_bytes;
    }
    pub fn thread(self: *const Collector, index: usize) ?ThreadInfo {
        var value: rt.struct_xrt_perf_thread = undefined;
        if (!rt.xrt_perf_thread(self.handle, index, &value)) return null;
        return .{ .tid = value.tid, .event_id = value.event_ids[0], .start_time_ticks = value.start_time_ticks, .start_time_known = value.start_time_known };
    }
    pub fn debuggerId(self: *const Collector, index: usize) u64 {
        var value: rt.struct_xrt_perf_thread = undefined;
        return if (rt.xrt_perf_thread(self.handle, index, &value)) value.debugger_id else 0;
    }
    pub fn enrolledAt(self: *const Collector, index: usize) ?u64 {
        var value: rt.struct_xrt_perf_thread = undefined;
        if (!rt.xrt_perf_thread(self.handle, index, &value) or value.enrolled_ns == 0) return null;
        return rt.xrt_perf_timestamp(self.handle, value.enrolled_ns);
    }
    pub fn pendingFailure(self: *const Collector) ?Failure {
        const value = runtime.info(self.handle);
        return if (value.failed) runtime.failure(value.failure) else null;
    }
    pub fn addThread(self: *Collector, tid: i32) ?Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_cpu_enroll(self.handle, tid, &self.accepted, &f)) null else runtime.failure(f);
    }
    pub fn retireThread(self: *Collector, index: usize) ?Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_retire(self.handle, index, &f)) null else runtime.failure(f);
    }
    pub fn stop(self: *Collector) ?Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_stop(self.handle, &f)) null else runtime.failure(f);
    }
    pub fn restart(self: *Collector) ?Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_enable(self.handle, &f)) null else runtime.failure(f);
    }
    const Decoding = struct {
        self: *Collector,
        used_samples: usize = 0,
        used_sides: usize = 0,
        used_states: usize = 0,
        used_stack: usize = 0,
        skipped: u32 = 0,
        reason: []const u8 = "",
        fn decode(raw: ?*anyopaque, ring_: [*c]const rt.struct_xrt_perf_ring) callconv(.c) rt.struct_xrt_perf_consumed {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            const self = ctx.self;
            const ring = ring_[0];
            const input = records.DecodeInput{
                .sample_type = self.sample_type,
                .sample_id_all = true,
                .stack_cap = if (self.callchain) self.sample_max_stack else 0,
                .max_frames = if (self.callchain) self.sample_max_stack else 1,
                .record_limit = @intCast(if (self.user_stack_bytes != 0) records.max_record_span else records.max_record_bytes),
                .user_regs_mask = self.user_regs_mask,
                .user_stack_request = self.user_stack_bytes,
                .user_states = self.user_states[ctx.used_states..],
                .user_state_base = @intCast(ctx.used_states),
                .user_stack = self.user_stack[ctx.used_stack..],
                .user_stack_base = @intCast(ctx.used_stack),
            };
            const report = records.decode(ring.data[0..ring.size], ring.head, ring.tail, input, self.samples[ctx.used_samples..], self.sides[ctx.used_sides..]);
            for (self.samples[ctx.used_samples..][0..report.samples]) |*sample| if (sample.time_present) {
                sample.time_ns = rt.xrt_perf_timestamp(self.handle, sample.time_ns);
            };
            for (self.sides[ctx.used_sides..][0..report.sides]) |*side| if (side.time_present) {
                side.time_ns = rt.xrt_perf_timestamp(self.handle, side.time_ns);
            };
            ctx.used_samples += report.samples;
            ctx.used_sides += report.sides;
            ctx.used_states += report.user_states;
            ctx.used_stack += report.user_stack_bytes;
            ctx.skipped += report.skipped_unknown;
            ctx.reason = report.reason;
            return .{ .bytes = report.consumed, .status = @intFromEnum(report.status) };
        }
    };
    pub fn drain(self: *Collector) Drain {
        var ctx = Decoding{ .self = self };
        const status = rt.xrt_perf_drain(self.handle, Decoding.decode, &ctx);
        return .{
            .samples = self.samples[0..ctx.used_samples],
            .sides = self.sides[0..ctx.used_sides],
            .user_states = self.user_states[0..ctx.used_states],
            .user_stack = self.user_stack[0..ctx.used_stack],
            .status = @enumFromInt(status),
            .skipped_unknown = ctx.skipped,
            .reason = if (status == rt.XRT_PERF_DRAIN_MALFORMED and ctx.reason.len == 0) "ring header is unusable" else ctx.reason,
        };
    }
    pub fn close(self: *Collector) void {
        rt.xrt_perf_destroy(self.handle);
        const allocator = self.allocator;
        allocator.free(self.samples);
        allocator.free(self.sides);
        allocator.free(self.user_states);
        allocator.free(self.user_stack);
        allocator.destroy(self);
    }
};

pub fn start(allocator: std.mem.Allocator, config: Config) error{OutOfMemory}!Opened {
    if (config.max_samples == 0 or config.max_samples > max_samples_cap) return .{ .failed = .{ .kind = .configuration, .syscall = "config", .detail = "max_samples out of range" } };
    if (config.max_sides == 0 or config.max_sides > max_sides_cap) return .{ .failed = .{ .kind = .configuration, .syscall = "config", .detail = "max_sides out of range" } };
    const event: EventKind = if (config.hardware == .cpu_cycles) .cpu_cycles else if (config.clock == .task) .task_clock else .cpu_clock;
    const cfg = rt.struct_xrt_cpu_config{
        .tids = config.tids.ptr,
        .thread_count = config.tids.len,
        .event = @intFromEnum(event),
        .frequency_hz = config.frequency_hz,
        .user_stack_bytes = config.user_stack_bytes,
        .max_frames = config.max_frames,
        .data_pages = config.data_pages,
        .ring_budget_bytes = config.ring_budget_bytes,
        .user_regs_mask = config.user_regs_mask,
        .exclude_kernel = config.exclude_kernel,
        .mmap_data = config.mmap_data,
        .callchain = config.callchain,
        .include_weight = config.include_weight,
        .context_switch = config.context_switch,
        .follow_threads = config.follow_threads,
    };
    var accepted: rt.struct_xrt_cpu_acceptance = undefined;
    var f: rt.struct_xrt_perf_failure = undefined;
    const handle = rt.xrt_cpu_start_target(config.target, &cfg, &accepted, &f) orelse return .{ .failed = runtime.failure(f) };
    errdefer rt.xrt_perf_destroy(handle);
    const samples = try allocator.alloc(records.Sample, config.max_samples);
    errdefer allocator.free(samples);
    const sides = try allocator.alloc(records.Side, config.max_sides);
    errdefer allocator.free(sides);
    const states: []records.UserState = if (config.user_regs_mask != 0 or config.user_stack_bytes != 0) try allocator.alloc(records.UserState, config.max_samples) else &.{};
    errdefer allocator.free(states);
    const stack: []u8 = if (config.user_stack_bytes != 0) try allocator.alloc(u8, records.max_retained_user_stack) else &.{};
    errdefer allocator.free(stack);
    const self = try allocator.create(Collector);
    const info = runtime.info(handle);
    self.* = .{
        .allocator = allocator,
        .handle = handle,
        .accepted = accepted,
        .samples = samples,
        .sides = sides,
        .user_states = states,
        .user_stack = stack,
        .event = event,
        .requested_frequency_hz = config.frequency_hz,
        .kernel_max_sample_rate = accepted.kernel_max_sample_rate,
        .kernel_max_stack = accepted.kernel_max_stack,
        .exclude_kernel = config.exclude_kernel,
        .mmap_data = config.mmap_data,
        .callchain = config.callchain,
        .include_weight = config.include_weight,
        .context_switch = config.context_switch,
        .user_regs_mask = config.user_regs_mask,
        .user_stack_bytes = config.user_stack_bytes,
        .sample_type = accepted.attr.sample_type,
        .sample_max_stack = accepted.attr.sample_max_stack,
        .clockid = accepted.attr.clockid,
        .ring_data_bytes = info.ring_data_bytes,
        .data_offset = info.data_offset,
        .mmap_version = info.mmap_version,
    };
    return .{ .collector = self };
}
fn field(map: []u8, offset: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + offset));
}
test "bounded draining rotates past a continuously busy ring without dropping queued data" {
    const a = std.testing.allocator;
    const collector = try a.create(Collector);
    defer a.destroy(collector);
    const handle = rt.xrt_perf_create(1, 3, 12288) orelse return error.OutOfMemory;
    defer rt.xrt_perf_destroy(handle);
    runtime.state(handle).count = 3;
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    collector.* = .{ .allocator = a, .handle = handle, .samples = &samples, .sides = &sides, .event = .task_clock, .requested_frequency_hz = 99, .kernel_max_sample_rate = 0, .kernel_max_stack = 0, .exclude_kernel = true, .mmap_data = false, .callchain = false, .include_weight = false, .context_switch = false, .sample_type = records.Bits.ip, .sample_max_stack = 0, .clockid = c.CLOCK_MONOTONIC, .ring_data_bytes = 4096, .mmap_version = 0 };
    var rings: [3][8192]u8 align(8) = @splat(@splat(0));
    for (&rings, 0..) |*ring, i| {
        runtime.state(handle).slots[i].map = ring;
        runtime.state(handle).slots[i].map_size = ring.len;
        for (0..3) |record| {
            const pos = 4096 + record * 16;
            std.mem.writeInt(u32, ring[pos..][0..4], records.Type.sample, .little);
            std.mem.writeInt(u16, ring[pos + 6 ..][0..2], 16, .little);
            std.mem.writeInt(u64, ring[pos + 8 ..][0..8], 100 + i, .little);
        }
        field(ring, off_data_head).* = 48;
    }
    // The first ring has more records than the entire output buffer. Every
    // other ring must nevertheless get a turn before its backlog is exhausted.
    var counts: [3]usize = @splat(0);
    for (0..9) |i| {
        const batch = collector.drain();
        try std.testing.expectEqual(1, batch.samples.len);
        const index = batch.samples[0].ip - 100;
        counts[index] += 1;
        if (i < 3) try std.testing.expectEqual(i, index);
    }
    try std.testing.expectEqualSlices(usize, &.{ 3, 3, 3 }, &counts);
    const empty = collector.drain();
    try std.testing.expectEqual(DrainStatus.ok, empty.status);
    try std.testing.expectEqual(0, empty.samples.len);
    for (runtime.state(collector.handle).slots[0..3]) |slot| {
        try std.testing.expectEqual(48, slot.tail);
        try std.testing.expectEqual(48, field(slot.map[0..slot.map_size], off_data_tail).*);
    }
}

test "user stack backpressure across rings remains fair and retryable" {
    const a = std.testing.allocator;
    const collector = try a.create(Collector);
    defer a.destroy(collector);
    const handle = rt.xrt_perf_create(1, 3, 12288) orelse return error.OutOfMemory;
    defer rt.xrt_perf_destroy(handle);
    runtime.state(handle).count = 3;
    var samples: [8]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [8]records.UserState = undefined;
    var stack: [24]u8 = undefined;
    collector.* = .{ .allocator = a, .handle = handle, .samples = &samples, .sides = &sides, .event = .task_clock, .requested_frequency_hz = 99, .kernel_max_sample_rate = 0, .kernel_max_stack = 0, .exclude_kernel = true, .mmap_data = false, .callchain = false, .include_weight = false, .context_switch = false, .user_regs_mask = (1 << 7) | (1 << 8), .user_stack_bytes = 64, .user_states = &states, .user_stack = &stack, .sample_type = records.Bits.ip | records.Bits.regs_user | records.Bits.stack_user, .sample_max_stack = 0, .clockid = c.CLOCK_MONOTONIC, .ring_data_bytes = 4096, .mmap_version = 0 };
    var rings: [3][8192]u8 align(8) = @splat(@splat(0));
    for (&rings, 0..) |*ring, i| {
        runtime.state(handle).slots[i].map = ring;
        runtime.state(handle).slots[i].map_size = ring.len;
        const bytes = ring[4096..];
        std.mem.writeInt(u32, bytes[0..4], records.Type.sample, .little);
        std.mem.writeInt(u16, bytes[6..8], 72, .little);
        std.mem.writeInt(u64, bytes[8..16], 100 + i, .little);
        std.mem.writeInt(u64, bytes[16..24], records.regs_abi_64, .little);
        std.mem.writeInt(u64, bytes[24..32], 0x7000, .little);
        std.mem.writeInt(u64, bytes[32..40], 100 + i, .little);
        std.mem.writeInt(u64, bytes[40..48], 16, .little);
        @memset(bytes[48..64], @intCast(i));
        std.mem.writeInt(u64, bytes[64..72], 16, .little);
        field(ring, off_data_head).* = 72;
    }
    // Ring 0 leaves eight output bytes. Ring 1 needs sixteen and must remain
    // queued with capacity, then get first turn in the next drain.
    for (0..3) |i| {
        const batch = collector.drain();
        try std.testing.expectEqual(if (i == 2) DrainStatus.ok else DrainStatus.capacity, batch.status);
        try std.testing.expectEqual(@as(usize, 1), batch.samples.len);
        try std.testing.expectEqual(@as(u64, 100) + i, batch.samples[0].ip);
        try std.testing.expectEqual(@as(u32, 1), batch.samples[0].user_state);
        try std.testing.expectEqual(@as(usize, 1), batch.user_states.len);
        try std.testing.expectEqual(@as(usize, 16), batch.user_stack.len);
        try std.testing.expectEqual(@as(u8, @intCast(i)), batch.user_stack[0]);
    }
    for (runtime.state(collector.handle).slots[0..3]) |slot| try std.testing.expectEqual(@as(u64, 72), slot.tail);
}
