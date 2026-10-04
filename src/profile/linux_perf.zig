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

pub const c = @import("../generated/linux_perf.zig");

pub const max_threads: u16 = 1024;
pub const max_data_pages: u8 = 64;
pub const max_samples_cap: u16 = 4096;
pub const max_sides_cap: u16 = 2048;

const off_data_head: usize = 1024;
const off_data_tail: usize = 1032;
const off_data_offset: usize = 1040;
const off_data_size: usize = 1048;

const flag_disabled: u64 = 1 << 0;
const flag_exclude_kernel: u64 = 1 << 5;
const flag_exclude_hv: u64 = 1 << 6;
const flag_exclude_idle: u64 = 1 << 7;
const flag_mmap: u64 = 1 << 8;
const flag_comm: u64 = 1 << 9;
const flag_freq: u64 = 1 << 10;
const flag_task: u64 = 1 << 13;
const flag_mmap_data: u64 = 1 << 17;
const flag_sample_id_all: u64 = 1 << 18;
const flag_exclude_callchain_kernel: u64 = 1 << 21;
const flag_mmap2: u64 = 1 << 23;
const flag_comm_exec: u64 = 1 << 24;
const flag_use_clockid: u64 = 1 << 25;
/// perf_event_attr.context_switch. Bit 26 of the flags word in the installed UAPI.
pub const context_switch_flag: u64 = 1 << 26;
const flag_context_switch: u64 = context_switch_flag;

/// Byte layout of struct perf_event_attr up through PERF_ATTR_SIZE_VER9.
/// Flags are a raw word so the kernel bit positions do not depend on how
/// @cImport lowers the C bitfield.
pub const Attr = extern struct {
    typ: u32,
    size: u32,
    config: u64,
    sample_period: u64,
    sample_type: u64,
    read_format: u64,
    flags: u64,
    wakeup_events: u32,
    bp_type: u32,
    config1: u64,
    config2: u64,
    branch_sample_type: u64,
    sample_regs_user: u64,
    sample_stack_user: u32,
    clockid: i32,
    sample_regs_intr: u64,
    aux_watermark: u32,
    sample_max_stack: u16,
    reserved_2: u16,
    aux_sample_size: u32,
    aux_action: u32,
    sig_data: u64,
    config3: u64,
    config4: u64,
};

comptime {
    if (@sizeOf(Attr) != 144) @compileError("perf_event_attr size drifted from PERF_ATTR_SIZE_VER9");
    if (@offsetOf(Attr, "flags") != 40) @compileError("perf flags word moved");
    if (@offsetOf(Attr, "clockid") != 92) @compileError("perf clockid moved");
    if (@offsetOf(Attr, "sample_max_stack") != 108) @compileError("sample_max_stack moved");
}

pub const Clock = enum { task, cpu };
pub const Hardware = enum { none, cpu_cycles };
pub const EventKind = enum { task_clock, cpu_clock, cpu_cycles };

pub const Config = struct {
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

const Slot = struct {
    tid: i32 = 0,
    fd: c_int = -1,
    map: []u8 = &.{},
    mapped: bool = false,
    retiring: bool = false,
    tail: u64 = 0,
    event_id: u64 = 0,
    start_time_ticks: u64 = 0,
    start_time_known: bool = false,
};

pub const Collector = struct {
    allocator: std.mem.Allocator,
    slots: [max_threads]Slot = @as([max_threads]Slot, @splat(.{})),
    slot_count: u16 = 0,
    next_slot: usize = 0,
    samples: []records.Sample,
    sides: []records.Side,
    running: bool = false,
    closed: bool = false,
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
    page_size: usize,
    attr: Attr = std.mem.zeroes(Attr),
    data_pages: u8 = 4,
    ring_budget_bytes: u64 = 64 * 1024 * 1024,
    allocated_ring_bytes: u64 = 0,

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
            .threads = self.slot_count,
        };
    }

    pub fn thread(self: *const Collector, index: usize) ?ThreadInfo {
        if (index >= self.slot_count) return null;
        const slot = self.slots[index];
        return .{
            .tid = slot.tid,
            .event_id = slot.event_id,
            .start_time_ticks = slot.start_time_ticks,
            .start_time_known = slot.start_time_known,
        };
    }

    /// Transactional enrollment: failure leaves existing events and slot identities intact.
    /// The owner must hold this thread before its first user instruction.
    pub fn addThread(self: *Collector, tid: i32) ?Failure {
        if (self.closed or !self.running) return .{ .kind = .configuration, .syscall = "enroll", .tid = tid, .detail = "collector is not running" };
        return self.openThread(tid, true);
    }

    fn openThread(self: *Collector, tid: i32, enable: bool) ?Failure {
        if (tid <= 0) return .{ .kind = .configuration, .syscall = "enroll", .tid = tid, .detail = "invalid thread id" };
        for (self.slots[0..self.slot_count]) |slot| if (slot.tid == tid) return .{ .kind = .configuration, .syscall = "enroll", .tid = tid, .detail = "thread id already recorded; reuse requires a new capture" };
        if (self.slot_count == max_threads) return .{ .kind = .resource, .syscall = "enroll", .tid = tid, .detail = "capture reached 1024 distinct thread identities" };
        const bytes = @as(u64, self.data_pages) * self.page_size;
        if (bytes > self.ring_budget_bytes -| self.allocated_ring_bytes) return .{ .kind = .resource, .syscall = "enroll", .tid = tid, .detail = "capture ring-data budget exhausted" };
        var attr = self.attr;
        const fd = perfOpen(&attr, tid);
        if (fd < 0) {
            const err = errno();
            return .{ .kind = classify(err), .syscall = "perf_event_open", .errno = err, .tid = tid, .detail = "thread open failed" };
        }
        const mapped = mapRing(fd, self.data_pages, self.page_size) orelse {
            const err = errno();
            _ = c.close(fd);
            return .{ .kind = classify(err), .syscall = "mmap", .errno = err, .tid = tid, .opened_then_closed = 1, .detail = "ring mmap failed" };
        };
        var slot = Slot{ .tid = tid, .fd = fd, .map = mapped, .mapped = true };
        if (c.ioctl(fd, ioctlCommand(c.PERF_EVENT_IOC_ID), &slot.event_id) != 0) {
            const err = errno();
            _ = c.munmap(mapped.ptr, mapped.len);
            _ = c.close(fd);
            return .{ .kind = classify(err), .syscall = "ioctl", .errno = err, .tid = tid, .opened_then_closed = 1, .detail = "PERF_EVENT_IOC_ID" };
        }
        const started = procStartTime(tid);
        slot.start_time_ticks = started.ticks;
        slot.start_time_known = started.known;
        if (enable and c.ioctl(fd, @as(c_ulong, c.PERF_EVENT_IOC_ENABLE), @as(c_ulong, 0)) != 0) {
            const err = errno();
            _ = c.munmap(mapped.ptr, mapped.len);
            _ = c.close(fd);
            return .{ .kind = classify(err), .syscall = "ioctl", .errno = err, .tid = tid, .opened_then_closed = 1, .detail = "PERF_EVENT_IOC_ENABLE" };
        }
        if (self.slot_count == 0) {
            self.mmap_version = readNum(u32, slot.map[0..4]);
            self.data_offset = readNum(u64, slot.map[off_data_offset..][0..8]);
            self.ring_data_bytes = publishedDataBytes(slot.map, self.page_size);
        }
        self.slots[self.slot_count] = slot;
        self.slot_count += 1;
        self.allocated_ring_bytes += bytes;
        return null;
    }

    /// Call only after the owner has reaped this thread. Preserve its queued
    /// samples/metadata, then release its ring on the first complete drain.
    pub fn retireThread(self: *Collector, index: usize) ?Failure {
        if (index >= self.slot_count) return .{ .kind = .configuration, .syscall = "retire", .detail = "unknown collector slot" };
        const slot = &self.slots[index];
        if (slot.fd < 0 or slot.retiring) return null;
        if (c.ioctl(slot.fd, @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, 0)) != 0) {
            const err = errno();
            if (err != c.ESRCH) return .{ .kind = classify(err), .syscall = "ioctl", .errno = err, .tid = slot.tid, .detail = "disable exited thread" };
        }
        slot.retiring = true;
        return null;
    }

    fn releaseSlot(self: *Collector, slot: *Slot) void {
        if (slot.fd < 0) return;
        _ = c.ioctl(slot.fd, @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, 0));
        if (slot.mapped) {
            _ = c.munmap(slot.map.ptr, slot.map.len);
            self.allocated_ring_bytes -= @as(u64, self.data_pages) * self.page_size;
            slot.mapped = false;
            slot.map = &.{};
        }
        _ = c.close(slot.fd);
        slot.fd = -1;
    }

    /// Disable every event. Queued ring bytes stay until `drain` or `close`.
    /// ESRCH (thread already gone) is not a failure.
    pub fn stop(self: *Collector) ?Failure {
        if (self.closed) return .{ .kind = .configuration, .syscall = "stop", .detail = "collector is closed" };
        if (!self.running) return null;
        for (self.slots[0..self.slot_count]) |slot| {
            if (slot.fd < 0) continue;
            if (c.ioctl(slot.fd, @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, 0)) != 0) {
                const err = errno();
                if (err == c.ESRCH) continue;
                return .{ .kind = classify(err), .syscall = "ioctl", .errno = err, .tid = slot.tid, .detail = "PERF_EVENT_IOC_DISABLE" };
            }
        }
        self.running = false;
        return null;
    }

    /// Enable events again after `stop`. Does not open new threads.
    pub fn restart(self: *Collector) ?Failure {
        if (self.closed) return .{ .kind = .configuration, .syscall = "restart", .detail = "collector is closed" };
        if (self.running) return .{ .kind = .configuration, .syscall = "restart", .detail = "collector is already running" };
        return self.enableAll();
    }

    pub fn drain(self: *Collector) Drain {
        if (@import("builtin").cpu.arch == .m68k) return .{ .samples = &.{}, .sides = &.{}, .user_states = &.{}, .user_stack = &.{}, .status = .closed, .skipped_unknown = 0, .reason = "m68k perf unsupported" };
        if (self.closed) return .{ .samples = &.{}, .sides = &.{}, .user_states = &.{}, .user_stack = &.{}, .status = .closed, .skipped_unknown = 0, .reason = "collector is closed" };
        var used_samples: usize = 0;
        var used_sides: usize = 0;
        var used_states: usize = 0;
        var used_stack: usize = 0;
        var skipped: u32 = 0;
        var status: DrainStatus = .ok;
        var reason: []const u8 = "";
        const first = self.next_slot;
        for (0..self.slot_count) |offset| {
            const index = (first + offset) % self.slot_count;
            const slot = &self.slots[index];
            if (slot.fd < 0 and !slot.mapped) continue;
            const view = slotView(slot, self.page_size) orelse {
                status = .malformed;
                reason = "ring header is unusable";
                break;
            };
            const input = records.DecodeInput{
                .sample_type = self.sample_type,
                .sample_id_all = true,
                .stack_cap = if (self.callchain) self.sample_max_stack else 0,
                .max_frames = if (self.callchain) self.sample_max_stack else 1,
                .record_limit = @intCast(if (self.user_stack_bytes != 0) records.max_record_span else records.max_record_bytes),
                .user_regs_mask = self.user_regs_mask,
                .user_stack_request = self.user_stack_bytes,
                .user_states = self.user_states[used_states..],
                .user_state_base = @intCast(used_states),
                .user_stack = self.user_stack[used_stack..],
                .user_stack_base = @intCast(used_stack),
            };
            const report = records.decode(view.data, view.head, slot.tail, input, self.samples[used_samples..], self.sides[used_sides..]);
            used_samples += report.samples;
            used_sides += report.sides;
            used_states += report.user_states;
            used_stack += report.user_stack_bytes;
            skipped += report.skipped_unknown;
            if (report.consumed != 0) {
                slot.tail += report.consumed;
                // Full barrier before data_tail, as the mmap page comment requires
                // (smp_mb, then the store the kernel's consumer side observes).
                @atomicStore(u64, field(slot.map, off_data_tail), slot.tail, .seq_cst);
            }
            if (slot.retiring and report.status == .ok and slot.tail == view.head) self.releaseSlot(slot);
            if (report.status == .capacity) {
                // A busy ring must not monopolize every bounded drain. If this
                // ring got no space at all, give it the first turn next time.
                self.next_slot = (index + @intFromBool(report.consumed != 0)) % self.slot_count;
            }
            if (report.status != .ok) {
                status = switch (report.status) {
                    .ok => .ok,
                    .capacity => .capacity,
                    .malformed => .malformed,
                    .incomplete => .incomplete,
                };
                reason = report.reason;
                break;
            }
        }
        if (status == .ok and self.slot_count > 0) self.next_slot = (first + 1) % self.slot_count;
        return .{
            .samples = self.samples[0..used_samples],
            .sides = self.sides[0..used_sides],
            .user_states = self.user_states[0..used_states],
            .user_stack = self.user_stack[0..used_stack],
            .status = status,
            .skipped_unknown = skipped,
            .reason = reason,
        };
    }

    /// Disable, unmap, close, and free. Safe on a collector that already
    /// stopped. The pointer must not be used again.
    pub fn close(self: *Collector) void {
        if (self.closed) return;
        self.closed = true;
        self.running = false;
        self.releaseAll();
        const allocator = self.allocator;
        allocator.free(self.samples);
        allocator.free(self.sides);
        if (self.user_states.len != 0) allocator.free(self.user_states);
        if (self.user_stack.len != 0) allocator.free(self.user_stack);
        allocator.destroy(self);
    }

    fn enableAll(self: *Collector) ?Failure {
        var enabled: usize = 0;
        while (enabled < self.slot_count) : (enabled += 1) {
            const slot = &self.slots[enabled];
            if (slot.fd < 0 or slot.retiring) continue;
            if (c.ioctl(slot.fd, @as(c_ulong, c.PERF_EVENT_IOC_ENABLE), @as(c_ulong, 0)) != 0) {
                const err = errno();
                var undo: usize = 0;
                while (undo < enabled) : (undo += 1) {
                    _ = c.ioctl(self.slots[undo].fd, @as(c_ulong, c.PERF_EVENT_IOC_DISABLE), @as(c_ulong, 0));
                }
                self.running = false;
                return .{ .kind = classify(err), .syscall = "ioctl", .errno = err, .tid = slot.tid, .detail = "PERF_EVENT_IOC_ENABLE" };
            }
        }
        self.running = true;
        return null;
    }

    fn releaseAll(self: *Collector) void {
        for (self.slots[0..self.slot_count]) |*slot| self.releaseSlot(slot);
        self.slot_count = 0;
        self.running = false;
    }
};

pub fn start(allocator: std.mem.Allocator, config: Config) error{OutOfMemory}!Opened {
    if (reject(config)) |failure| return .{ .failed = failure };
    const rate = readSysctl("/proc/sys/kernel/perf_event_max_sample_rate") orelse 0;
    const stack_cap = readSysctl("/proc/sys/kernel/perf_event_max_stack") orelse 0;
    if (rate != 0 and config.frequency_hz > rate) {
        return .{ .failed = .{ .kind = .configuration, .syscall = "config", .detail = "frequency exceeds perf_event_max_sample_rate" } };
    }
    if (config.callchain and stack_cap != 0 and config.max_frames > stack_cap) {
        return .{ .failed = .{ .kind = .configuration, .syscall = "config", .detail = "max_frames exceeds perf_event_max_stack" } };
    }

    const event: EventKind = switch (config.hardware) {
        .cpu_cycles => .cpu_cycles,
        .none => switch (config.clock) {
            .task => .task_clock,
            .cpu => .cpu_clock,
        },
    };
    var sample_type: u64 = records.Bits.ip | records.Bits.tid | records.Bits.time | records.Bits.period;
    if (config.callchain) sample_type |= records.Bits.callchain;
    if (config.include_weight) sample_type |= records.Bits.weight;
    if (config.user_regs_mask != 0) sample_type |= records.Bits.regs_user;
    if (config.user_stack_bytes != 0) sample_type |= records.Bits.stack_user;

    var flags: u64 = flag_disabled | flag_exclude_hv | flag_exclude_idle | flag_mmap | flag_comm | flag_freq | flag_task | flag_sample_id_all | flag_mmap2 | flag_comm_exec | flag_use_clockid;
    if (config.mmap_data) flags |= flag_mmap_data;
    if (config.exclude_kernel) flags |= flag_exclude_kernel | flag_exclude_callchain_kernel;
    if (config.context_switch) flags |= flag_context_switch;

    var attr = std.mem.zeroes(Attr);
    attr.size = @sizeOf(Attr);
    attr.sample_period = config.frequency_hz;
    attr.sample_type = sample_type;
    attr.flags = flags;
    attr.clockid = c.CLOCK_MONOTONIC;
    attr.sample_max_stack = if (config.callchain) config.max_frames else 0;
    attr.sample_regs_user = config.user_regs_mask;
    attr.sample_stack_user = config.user_stack_bytes;
    switch (event) {
        .cpu_cycles => {
            attr.typ = c.PERF_TYPE_HARDWARE;
            attr.config = c.PERF_COUNT_HW_CPU_CYCLES;
        },
        .task_clock => {
            attr.typ = c.PERF_TYPE_SOFTWARE;
            attr.config = c.PERF_COUNT_SW_TASK_CLOCK;
        },
        .cpu_clock => {
            attr.typ = c.PERF_TYPE_SOFTWARE;
            attr.config = c.PERF_COUNT_SW_CPU_CLOCK;
        },
    }

    const page = pageSize();
    const samples = allocator.alloc(records.Sample, config.max_samples) catch return error.OutOfMemory;
    const sides = allocator.alloc(records.Side, config.max_sides) catch {
        allocator.free(samples);
        return error.OutOfMemory;
    };
    const self = allocator.create(Collector) catch {
        allocator.free(samples);
        allocator.free(sides);
        return error.OutOfMemory;
    };
    self.* = .{
        .allocator = allocator,
        .samples = samples,
        .sides = sides,
        .event = event,
        .requested_frequency_hz = config.frequency_hz,
        .kernel_max_sample_rate = rate,
        .kernel_max_stack = stack_cap,
        .exclude_kernel = config.exclude_kernel,
        .mmap_data = config.mmap_data,
        .callchain = config.callchain,
        .include_weight = config.include_weight,
        .context_switch = config.context_switch,
        .user_regs_mask = config.user_regs_mask,
        .user_stack_bytes = config.user_stack_bytes,
        .user_states = &.{},
        .user_stack = &.{},
        .sample_type = sample_type,
        .sample_max_stack = if (config.callchain) config.max_frames else 0,
        .clockid = c.CLOCK_MONOTONIC,
        .ring_data_bytes = 0,
        .data_offset = 0,
        .mmap_version = 0,
        .page_size = page,
        .attr = attr,
        .data_pages = config.data_pages,
        .ring_budget_bytes = config.ring_budget_bytes,
    };

    if (config.user_regs_mask != 0 or config.user_stack_bytes != 0) {
        self.user_states = allocator.alloc(records.UserState, config.max_samples) catch return failOwned(self, .{ .kind = .resource, .syscall = "alloc", .detail = "user state table" });
        if (config.user_stack_bytes != 0) {
            self.user_stack = allocator.alloc(u8, records.max_retained_user_stack) catch return failOwned(self, .{ .kind = .resource, .syscall = "alloc", .detail = "user stack buffer" });
        }
    }

    for (config.tids) |tid| {
        if (self.openThread(tid, false)) |failure| {
            var full = failure;
            full.opened_then_closed += self.slot_count;
            return failOwned(self, full);
        }
    }

    if (self.enableAll()) |failure| {
        var full = failure;
        full.opened_then_closed = self.slot_count;
        return failOwned(self, full);
    }
    return .{ .collector = self };
}

fn failOwned(self: *Collector, failure: Failure) Opened {
    const allocator = self.allocator;
    self.releaseAll();
    allocator.free(self.samples);
    allocator.free(self.sides);
    if (self.user_states.len != 0) allocator.free(self.user_states);
    if (self.user_stack.len != 0) allocator.free(self.user_stack);
    allocator.destroy(self);
    return .{ .failed = failure };
}

fn reject(config: Config) ?Failure {
    if (config.tids.len == 0) return .{ .kind = .configuration, .syscall = "config", .detail = "tid list is empty" };
    if (config.tids.len > max_threads) return .{ .kind = .configuration, .syscall = "config", .detail = "tid list exceeds 1024" };
    if (config.frequency_hz == 0) return .{ .kind = .configuration, .syscall = "config", .detail = "frequency is zero" };
    if (config.data_pages == 0 or config.data_pages > max_data_pages or config.data_pages & (config.data_pages - 1) != 0) {
        return .{ .kind = .configuration, .syscall = "config", .detail = "data_pages must be a power of two up to 64" };
    }
    if (config.max_samples == 0 or config.max_samples > max_samples_cap) return .{ .kind = .configuration, .syscall = "config", .detail = "max_samples out of range" };
    if (config.max_sides == 0 or config.max_sides > max_sides_cap) return .{ .kind = .configuration, .syscall = "config", .detail = "max_sides out of range" };
    if (config.callchain and (config.max_frames == 0 or config.max_frames > records.max_frames)) {
        return .{ .kind = .configuration, .syscall = "config", .detail = "max_frames out of range" };
    }
    if (config.user_regs_mask >> records.max_user_regs != 0) {
        return .{ .kind = .configuration, .syscall = "config", .detail = "user register mask includes an unsupported bit" };
    }
    if (config.user_stack_bytes != 0) {
        if (config.user_stack_bytes < 64 or config.user_stack_bytes > records.max_user_stack or config.user_stack_bytes % 8 != 0) {
            return .{ .kind = .configuration, .syscall = "config", .detail = "user_stack_bytes must be a multiple of 8 from 64 to 8192" };
        }
        if (config.user_regs_mask & (1 << 7) == 0 or config.user_regs_mask & (1 << 8) == 0) {
            return .{ .kind = .configuration, .syscall = "config", .detail = "user stack capture requires the stack pointer and instruction pointer" };
        }
    }
    var i: usize = 0;
    while (i < config.tids.len) : (i += 1) {
        if (config.tids[i] <= 0) return .{ .kind = .configuration, .syscall = "config", .tid = config.tids[i], .detail = "tid must be positive; 0 would sample the caller and a negative pid would attach more widely" };
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (config.tids[j] == config.tids[i]) return .{ .kind = .configuration, .syscall = "config", .tid = config.tids[i], .detail = "duplicate tid" };
        }
    }
    return null;
}

fn perfOpen(attr: *Attr, tid: i32) c_int {
    const rc = c.syscall(
        @as(c_long, c.SYS_perf_event_open),
        attr,
        @as(c.pid_t, tid),
        @as(c_int, -1),
        @as(c_int, -1),
        @as(c_ulong, c.PERF_FLAG_FD_CLOEXEC),
    );
    return @intCast(rc);
}

fn mapRing(fd: c_int, data_pages: u8, page: usize) ?[]u8 {
    const len = (1 + @as(usize, data_pages)) * page;
    const ptr = c.mmap(null, len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, @as(c.off_t, 0));
    if (@intFromPtr(ptr) == std.math.maxInt(usize)) return null;
    return @as([*]u8, @ptrCast(ptr))[0..len];
}

const View = struct { data: []u8, head: u64 };

fn slotView(slot: *Slot, page: usize) ?View {
    if (@import("builtin").cpu.arch == .m68k) return null;
    if (!slot.mapped or slot.map.len < off_data_size + 8) return null;
    const head = @atomicLoad(u64, field(slot.map, off_data_head), .acquire);
    var data_off = readNum(u64, slot.map[off_data_offset..][0..8]);
    var data_sz = readNum(u64, slot.map[off_data_size..][0..8]);
    if (data_sz == 0) {
        if (slot.map.len <= page) return null;
        data_off = page;
        data_sz = slot.map.len - page;
    }
    if (data_off > slot.map.len or data_sz > slot.map.len - data_off) return null;
    if (data_sz == 0 or (data_sz & (data_sz - 1)) != 0) return null;
    const data_from: usize = @intCast(data_off);
    const size: usize = @intCast(data_sz);
    return .{ .data = slot.map[data_from..][0..size], .head = head };
}

fn publishedDataBytes(map: []u8, page: usize) u64 {
    if (map.len < off_data_size + 8) return 0;
    const data_sz = readNum(u64, map[off_data_size..][0..8]);
    if (data_sz != 0) return data_sz;
    if (map.len <= page) return 0;
    return map.len - page;
}

fn field(map: []u8, offset: usize) *u64 {
    return @ptrCast(@alignCast(map.ptr + offset));
}

fn pageSize() usize {
    const n = c.sysconf(c._SC_PAGESIZE);
    if (n <= 0) return 4096;
    return @intCast(n);
}

fn classify(err: c_int) FailureKind {
    if (err == c.ESRCH) return .thread_gone;
    if (err == c.EPERM or err == c.EACCES) return .permission;
    if (err == c.EINVAL or err == c.E2BIG) return .configuration;
    if (err == c.ENOSYS or err == c.ENODEV or err == c.ENOENT or err == c.EOPNOTSUPP) return .unavailable;
    if (err == c.EMFILE or err == c.ENFILE or err == c.ENOMEM or err == c.EAGAIN or err == c.EBUSY) return .resource;
    return .other;
}

fn errno() c_int {
    return std.c._errno().*;
}

fn readSysctl(path: [*:0]const u8) ?u32 {
    const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [32]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    return parseU32(buf[0..@intCast(n)]);
}

fn parseU32(text: []const u8) ?u32 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\n' or text[i] == '\t')) i += 1;
    if (i >= text.len or text[i] < '0' or text[i] > '9') return null;
    var v: u32 = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        v = v * 10 + (text[i] - '0');
    }
    return v;
}

fn procStartTime(tid: i32) struct { known: bool, ticks: u64 } {
    var path: [64]u8 = undefined;
    const n = c.snprintf(&path, path.len, "/proc/%d/stat", tid);
    if (n <= 0 or n >= path.len) return .{ .known = false, .ticks = 0 };
    const fd = c.open(&path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return .{ .known = false, .ticks = 0 };
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const got = c.read(fd, &buf, buf.len);
    if (got <= 0) return .{ .known = false, .ticks = 0 };
    const text = buf[0..@intCast(got)];
    var close_paren: ?usize = null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) if (text[i] == ')') {
        close_paren = i;
    };
    const paren = close_paren orelse return .{ .known = false, .ticks = 0 };
    if (paren + 1 >= text.len) return .{ .known = false, .ticks = 0 };
    const token = tokenAt(text[paren + 1 ..], 19) orelse return .{ .known = false, .ticks = 0 };
    return .{ .known = true, .ticks = parseU64(token) orelse 0 };
}

fn tokenAt(text: []const u8, index: usize) ?[]const u8 {
    var i: usize = 0;
    var seen: usize = 0;
    while (i < text.len) {
        while (i < text.len and text[i] == ' ') i += 1;
        if (i >= text.len) return null;
        const from = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n') i += 1;
        if (seen == index) return text[from..i];
        seen += 1;
    }
    return null;
}

fn parseU64(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var v: u64 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    return v;
}

fn readNum(comptime T: type, bytes: []const u8) T {
    var v: T = 0;
    @memcpy(@as(*[@sizeOf(T)]u8, @ptrCast(&v)), bytes[0..@sizeOf(T)]);
    return v;
}

test "bounded draining rotates past a continuously busy ring without dropping queued data" {
    const a = std.testing.allocator;
    const collector = try a.create(Collector);
    defer a.destroy(collector);
    var samples: [1]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    collector.* = .{ .allocator = a, .slot_count = 3, .samples = &samples, .sides = &sides, .event = .task_clock, .requested_frequency_hz = 99, .kernel_max_sample_rate = 0, .kernel_max_stack = 0, .exclude_kernel = true, .mmap_data = false, .callchain = false, .include_weight = false, .context_switch = false, .sample_type = records.Bits.ip, .sample_max_stack = 0, .clockid = c.CLOCK_MONOTONIC, .ring_data_bytes = 4096, .mmap_version = 0, .page_size = 4096 };
    var rings: [3][8192]u8 align(8) = @splat(@splat(0));
    for (&rings, 0..) |*ring, i| {
        collector.slots[i] = .{ .map = ring, .mapped = true };
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
    for (collector.slots[0..3]) |slot| {
        try std.testing.expectEqual(48, slot.tail);
        try std.testing.expectEqual(48, field(slot.map, off_data_tail).*);
    }
}

test "user stack backpressure across rings remains fair and retryable" {
    const a = std.testing.allocator;
    const collector = try a.create(Collector);
    defer a.destroy(collector);
    var samples: [8]records.Sample = undefined;
    var sides: [1]records.Side = undefined;
    var states: [8]records.UserState = undefined;
    var stack: [24]u8 = undefined;
    collector.* = .{ .allocator = a, .slot_count = 3, .samples = &samples, .sides = &sides, .event = .task_clock, .requested_frequency_hz = 99, .kernel_max_sample_rate = 0, .kernel_max_stack = 0, .exclude_kernel = true, .mmap_data = false, .callchain = false, .include_weight = false, .context_switch = false, .user_regs_mask = (1 << 7) | (1 << 8), .user_stack_bytes = 64, .user_states = &states, .user_stack = &stack, .sample_type = records.Bits.ip | records.Bits.regs_user | records.Bits.stack_user, .sample_max_stack = 0, .clockid = c.CLOCK_MONOTONIC, .ring_data_bytes = 4096, .mmap_version = 0, .page_size = 4096 };
    var rings: [3][8192]u8 align(8) = @splat(@splat(0));
    for (&rings, 0..) |*ring, i| {
        collector.slots[i] = .{ .map = ring, .mapped = true };
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
    for (collector.slots[0..3]) |slot| try std.testing.expectEqual(@as(u64, 72), slot.tail);
}

test "enroll held newborn transactionally, reject budget and reuse, retire drained rings" {
    try @import("../test_support.zig").requireLive();
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
    const linux = @import("../target/linux.zig");
    var target = linux.Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/xodb-fixture", "profile-birth" });
    const opened = try start(std.testing.allocator, .{ .tids = &.{target.pid}, .data_pages = 64 });
    const collector = switch (opened) {
        .collector => |value| value,
        .failed => |failure| {
            @import("../m68k_log.zig").print("perf enrollment test: {s} errno={d} {s}\n", .{ failure.syscall, failure.errno, failure.detail });
            return error.TestUnexpectedResult;
        },
    };
    defer collector.close();
    const Probe = struct {
        collector: *Collector,
        failure: ?Failure = null,
        calls: usize = 0,
        held_member: bool = false,
        fn born(raw: *anyopaque, thread: linux.Thread, member: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.held_member = member and thread.state == .stopped;
            self.failure = self.collector.addThread(thread.tid);
        }
    };
    var probe = Probe{ .collector = collector };
    target.new_thread_observer = .{ .context = &probe, .before_resume = Probe.born };
    defer target.new_thread_observer = null;
    try target.continueExecution();
    const deadline = linux.now() + 2_000_000_000;
    while (probe.calls == 0 and linux.now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.held_member);
    try std.testing.expect(probe.failure == null);
    try std.testing.expectEqual(@as(u16, 2), collector.slot_count);
    try std.testing.expect(collector.thread(1).?.event_id != collector.thread(0).?.event_id);
    try std.testing.expect(collector.addThread(target.pid) != null);
    const enrolled_tid = collector.thread(1).?.tid;
    var new_samples: usize = 0;
    var new_mappings: usize = 0;
    while (target.state != .exited and linux.now() < deadline) {
        try target.poll();
        const batch = collector.drain();
        try std.testing.expect(batch.status == .ok or batch.status == .capacity);
        for (batch.samples) |sample| if (sample.tid == enrolled_tid) {
            new_samples += 1;
        };
        for (batch.sides) |side| if (side.kind == .mmap and side.tid == enrolled_tid) {
            new_mappings += 1;
        };
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(linux.State.exited, target.state);
    try std.testing.expect(new_samples > 0);
    try std.testing.expect(new_mappings > 0);
    const bytes = collector.allocated_ring_bytes;
    collector.ring_budget_bytes = bytes;
    const rejected = collector.addThread(std.math.maxInt(i32)).?;
    try std.testing.expectEqual(FailureKind.resource, rejected.kind);
    collector.ring_budget_bytes += collector.ring_data_bytes;
    try std.testing.expectEqualStrings("perf_event_open", collector.addThread(std.math.maxInt(i32)).?.syscall);
    try std.testing.expectEqual(@as(u16, 2), collector.slot_count);
    try std.testing.expectEqual(bytes, collector.allocated_ring_bytes);
    // Deinit reaps only this fixture. Retired rings must retain queued data and
    // stable identities until drain, then return their memory/fd budget.
    const recorded_pid = target.pid;
    target.deinit();
    for (0..collector.slot_count) |i| try std.testing.expect(collector.retireThread(i) == null);
    for (0..32) |_| {
        const batch = collector.drain();
        if (batch.status == .ok) break;
        try std.testing.expectEqual(DrainStatus.capacity, batch.status);
    }
    try std.testing.expectEqual(@as(u64, 0), collector.allocated_ring_bytes);
    for (collector.slots[0..collector.slot_count]) |slot| {
        try std.testing.expectEqual(@as(c_int, -1), slot.fd);
        try std.testing.expect(!slot.mapped);
    }
    try std.testing.expectEqual(@as(u16, 2), collector.acceptance().threads);
    try std.testing.expect(collector.addThread(recorded_pid) != null);
}

// Linux ioctl command bits are unchanged; Bionic declares the argument signed.
fn ioctlCommand(command: u32) if (@import("builtin").abi.isAndroid()) c_int else c_ulong {
    return if (@import("builtin").abi.isAndroid()) @bitCast(command) else command;
}
