//! Bounded decoder for one Linux perf data ring.
//! Layout follows the userspace ABI in include/uapi/linux/perf_event.h
//! (GPL-2.0 WITH Linux-syscall-note). Multi-byte fields are host endian,
//! which is how a local kernel writes the ring. This file does not open
//! events or consult DWARF.

const std = @import("std");

pub const max_frames: u16 = 64;
pub const max_record_bytes: usize = 8192;
/// Ceiling used when a sample carries a user stack. The default record limit
/// stays `max_record_bytes`.
pub const max_record_span: usize = 16384;
/// PERF_REG_X86_64_MAX. XMM registers are not captured.
pub const max_user_regs: usize = 24;
pub const max_user_stack: u32 = 8192;
/// Total user-stack bytes one drain may retain, independent of the sample cap.
pub const max_retained_user_stack: usize = 256 * 1024;
/// AX, BX, CX, DX, SI, DI, BP, SP, IP, and R8–R15. Skips flags and segment regs.
pub const user_regs_gpr_mask: u64 = 0x1ff | (0xff << 16);
pub const regs_abi_none: u64 = 0;
pub const regs_abi_32: u64 = 1;
pub const regs_abi_64: u64 = 2;
pub const name_cap: usize = 64;
pub const path_cap: usize = 128;

pub const Type = struct {
    pub const mmap: u32 = 1;
    pub const lost: u32 = 2;
    pub const comm: u32 = 3;
    pub const exit: u32 = 4;
    pub const throttle: u32 = 5;
    pub const unthrottle: u32 = 6;
    pub const fork: u32 = 7;
    pub const sample: u32 = 9;
    pub const mmap2: u32 = 10;
    pub const lost_samples: u32 = 13;
    /// Per-task context switch. Body is only the header plus sample_id.
    pub const context_switch: u32 = 14;
    /// CPU-wide switch. Decoded, never requested: the collector does not open cpu-wide events.
    pub const context_switch_cpu_wide: u32 = 15;
};

pub const Bits = struct {
    pub const ip: u64 = 1 << 0;
    pub const tid: u64 = 1 << 1;
    pub const time: u64 = 1 << 2;
    pub const addr: u64 = 1 << 3;
    pub const read: u64 = 1 << 4;
    pub const callchain: u64 = 1 << 5;
    pub const id: u64 = 1 << 6;
    pub const cpu: u64 = 1 << 7;
    pub const period: u64 = 1 << 8;
    pub const stream_id: u64 = 1 << 9;
    pub const raw: u64 = 1 << 10;
    pub const branch_stack: u64 = 1 << 11;
    pub const regs_user: u64 = 1 << 12;
    pub const stack_user: u64 = 1 << 13;
    pub const weight: u64 = 1 << 14;
    pub const data_src: u64 = 1 << 15;
    pub const identifier: u64 = 1 << 16;
    pub const transaction: u64 = 1 << 17;
    pub const regs_intr: u64 = 1 << 18;
    pub const phys_addr: u64 = 1 << 19;
    pub const aux: u64 = 1 << 20;
    pub const cgroup: u64 = 1 << 21;
    pub const data_page_size: u64 = 1 << 22;
    pub const code_page_size: u64 = 1 << 23;
    pub const weight_struct: u64 = 1 << 24;
};

pub const Misc = struct {
    pub const cpumode_mask: u16 = 7;
    pub const kernel: u16 = 1;
    pub const user: u16 = 2;
    pub const hypervisor: u16 = 3;
    pub const guest_kernel: u16 = 4;
    pub const guest_user: u16 = 5;
    pub const proc_map_parse_timeout: u16 = 1 << 12;
    pub const comm_exec: u16 = 1 << 13;
    pub const mmap_build_id: u16 = 1 << 14;
    pub const exact_ip: u16 = 1 << 14;
    /// Same bit as COMM_EXEC. On PERF_RECORD_SWITCH* it means switch-out.
    pub const switch_out: u16 = 1 << 13;
    /// Same bit as MMAP_BUILD_ID. On a switch-out it means the task was preempted.
    pub const switch_out_preempt: u16 = 1 << 14;
};

/// Values at or above this are context markers, not instruction addresses.
/// PERF_CONTEXT_MAX in the UAPI.
pub const context_max: u64 = @as(u64, @bitCast(@as(i64, -4095)));
pub const context_hv: u64 = @as(u64, @bitCast(@as(i64, -32)));
pub const context_kernel: u64 = @as(u64, @bitCast(@as(i64, -128)));
pub const context_user: u64 = @as(u64, @bitCast(@as(i64, -512)));
pub const context_user_deferred: u64 = @as(u64, @bitCast(@as(i64, -640)));
pub const context_guest: u64 = @as(u64, @bitCast(@as(i64, -2048)));
pub const context_guest_kernel: u64 = @as(u64, @bitCast(@as(i64, -2176)));
pub const context_guest_user: u64 = @as(u64, @bitCast(@as(i64, -2560)));

pub fn isContextMarker(ip: u64) bool {
    return ip >= context_max;
}

pub const CpuMode = enum(u8) { unknown, kernel, user, hypervisor, guest_kernel, guest_user, other };

pub const Context = enum(u8) {
    unknown,
    kernel,
    user,
    hypervisor,
    guest,
    guest_kernel,
    guest_user,
    user_deferred,
    other,
};

pub const ChainItem = struct {
    /// True when this entry is a PERF_CONTEXT_* marker. `address` is then 0
    /// and must not be symbolized; `raw_marker` holds the ABI value.
    marker: bool = false,
    context: Context = .unknown,
    address: u64 = 0,
    raw_marker: u64 = 0,
};

pub const Callchain = enum(u8) { absent, complete, truncated };

pub const Sample = struct {
    ip: u64 = 0,
    ip_present: bool = false,
    ip_exact: bool = false,
    pid: u32 = 0,
    tid: u32 = 0,
    tid_present: bool = false,
    time_ns: u64 = 0,
    time_present: bool = false,
    /// Event counts this sample represents (PERF_SAMPLE_PERIOD). For a
    /// frequency-mode clock this is the sample's weight in event units.
    period: u64 = 0,
    period_present: bool = false,
    /// PERF_SAMPLE_WEIGHT when that bit was set. Absent is not a zero weight.
    weight: u64 = 0,
    weight_present: bool = false,
    cpu_mode: CpuMode = .unknown,
    callchain: Callchain = .absent,
    frame_count: u16 = 0,
    frames: [max_frames]ChainItem = @as([max_frames]ChainItem, @splat(.{})),
    /// Index into the drain's user-state table, plus one. Zero means this
    /// sample has no user registers or stack. The kernel callchain above is
    /// a separate record and is never filled from the user stack.
    user_state: u32 = 0,
};

/// Registers and stack bytes from one sample. Zero in `regs` is a captured
/// value only where `regs_mask` has that bit and `regs_present` is true.
/// `stack_len` bytes at `stack_off` are the trusted dump; they start at the
/// sampled user stack pointer. Bytes past `stack_dyn` in the record are not
/// copied.
pub const UserState = struct {
    abi: u64 = 0,
    regs_mask: u64 = 0,
    regs: [max_user_regs]u64 = @as([max_user_regs]u64, @splat(0)),
    regs_present: bool = false,
    stack_size: u64 = 0,
    stack_dyn: u64 = 0,
    stack_off: u32 = 0,
    stack_len: u32 = 0,
    stack_present: bool = false,
    /// The kernel dumped fewer trusted bytes than it reserved in `stack_size`,
    /// or fewer than the requested `sample_stack_user`.
    stack_short: bool = false,
};

pub const SideKind = enum(u8) {
    lost,
    lost_samples,
    throttle,
    unthrottle,
    comm,
    mmap,
    exit,
    fork,
    /// PERF_RECORD_SWITCH or PERF_RECORD_SWITCH_CPU_WIDE.
    context_switch,
    unknown,
};

pub const Side = struct {
    kind: SideKind = .unknown,
    time_ns: u64 = 0,
    time_present: bool = false,
    pid: u32 = 0,
    tid: u32 = 0,
    ppid: u32 = 0,
    ptid: u32 = 0,
    lost_id: u64 = 0,
    lost_count: u64 = 0,
    event_id: u64 = 0,
    stream_id: u64 = 0,
    exec: bool = false,
    name: [name_cap]u8 = @as([name_cap]u8, @splat(0)),
    name_len: u8 = 0,
    name_truncated: bool = false,
    address: u64 = 0,
    length: u64 = 0,
    page_offset: u64 = 0,
    inode: u64 = 0,
    inode_generation: u64 = 0,
    major: u32 = 0,
    minor: u32 = 0,
    prot: u32 = 0,
    flags: u32 = 0,
    build_id: bool = false,
    maps_parse_timeout: bool = false,
    path: [path_cap]u8 = @as([path_cap]u8, @splat(0)),
    path_len: u8 = 0,
    path_truncated: bool = false,
    raw_type: u32 = 0,
    raw_size: u16 = 0,
    /// Switch-out when true, switch-in when false. Meaningful for `context_switch`.
    switch_out: bool = false,
    /// Set on switch-out. A switch-in leaves this false: the preempt bit is not defined then.
    preempt_present: bool = false,
    preempted: bool = false,
    /// Sample_id carried a TID. Zero pid/tid with this false means the identity was absent.
    task_present: bool = false,
    /// PERF_RECORD_SWITCH_CPU_WIDE carried next/prev pid and tid.
    /// Zero with this set is a real task (idle/swapper), not an absent field.
    other_task_present: bool = false,
    other_pid: u32 = 0,
    other_tid: u32 = 0,
    /// PERF_SAMPLE_CPU was in the sample_id. This collector does not request that bit.
    cpu_present: bool = false,
    cpu: u32 = 0,
};

pub const DecodeInput = struct {
    sample_type: u64,
    sample_id_all: bool = false,
    /// When non-zero, a callchain with this many entries is `truncated`:
    /// the kernel stopped at sample_max_stack and the rest is unknown.
    stack_cap: u16 = 0,
    max_frames: u16 = max_frames,
    /// Largest record this decode will copy. Defaults to 8192. Stack capture
    /// raises it, and it cannot exceed `max_record_span`.
    record_limit: u16 = 8192,
    /// `attr.sample_regs_user`. The REGS_USER bit without a mask is malformed.
    user_regs_mask: u64 = 0,
    /// `attr.sample_stack_user`. Zero leaves shortness to the record itself.
    user_stack_request: u32 = 0,
    /// Retention table for samples that carry user regs or a user stack.
    /// Empty when those bits are not expected.
    user_states: []UserState = &.{},
    /// Index of `user_states[0]` in the drain's full table.
    user_state_base: u32 = 0,
    /// Retention bytes for trusted stack dumps.
    user_stack: []u8 = &.{},
    /// Index of `user_stack[0]` in the drain's full byte buffer.
    user_stack_base: u32 = 0,
};

pub const Status = enum { ok, capacity, malformed, incomplete };

pub const Report = struct {
    status: Status = .ok,
    /// Bytes to add to the caller's tail. Records that did not fit, or that
    /// failed validation, are not included: the next decode sees them again.
    consumed: u64 = 0,
    samples: usize = 0,
    sides: usize = 0,
    skipped_unknown: u32 = 0,
    /// User-state slots committed by this decode.
    user_states: u32 = 0,
    /// Trusted stack bytes copied by this decode.
    user_stack_bytes: u32 = 0,
    reason: []const u8 = "",
};

const unsupported_body: u64 = Bits.read | Bits.raw | Bits.branch_stack | Bits.data_src | Bits.transaction | Bits.regs_intr | Bits.phys_addr | Bits.aux | Bits.cgroup | Bits.data_page_size | Bits.code_page_size | Bits.weight_struct;

pub fn decode(ring: []const u8, head: u64, tail: u64, in: DecodeInput, samples: []Sample, sides: []Side) Report {
    if (ring.len == 0 or (ring.len & (ring.len - 1)) != 0) {
        return .{ .status = .malformed, .reason = "ring length is not a power of two" };
    }
    if (head < tail) return .{ .status = .malformed, .reason = "tail passed head" };
    if (in.max_frames == 0 or in.max_frames > max_frames) {
        return .{ .status = .malformed, .reason = "max_frames out of range" };
    }
    if (in.record_limit == 0 or in.record_limit > max_record_span) {
        return .{ .status = .malformed, .reason = "record limit is out of range" };
    }

    var report = Report{};
    var cursor = tail;
    var guard: u32 = 0;
    var sink = UserSink{
        .states = in.user_states,
        .state_base = in.user_state_base,
        .stack = in.user_stack,
        .stack_base = in.user_stack_base,
    };
    while (cursor < head) {
        guard += 1;
        if (guard > 100000) return halt(report, sink, .malformed, cursor - tail, "record loop guard");
        const available = head - cursor;
        if (available < 8) return halt(report, sink, .incomplete, cursor - tail, "partial header");

        var hdr: [8]u8 = undefined;
        copyRing(ring, cursor, &hdr);
        const rec_type = readNum(u32, hdr[0..4]);
        const misc = readNum(u16, hdr[4..6]);
        const size = readNum(u16, hdr[6..8]);
        if (size == 0) return halt(report, sink, .malformed, cursor - tail, "record size is zero");
        if (size < 8) return halt(report, sink, .malformed, cursor - tail, "record size is below the header");
        if (size % 8 != 0) return halt(report, sink, .malformed, cursor - tail, "record size is not 8-byte aligned");
        if (size > ring.len) return halt(report, sink, .malformed, cursor - tail, "record size exceeds the ring");
        if (size > in.record_limit) {
            const why: []const u8 = if (in.record_limit == 8192) "record exceeds 8192-byte bound" else "record exceeds the configured byte bound";
            return halt(report, sink, .malformed, cursor - tail, why);
        }
        if (available < size) return halt(report, sink, .incomplete, cursor - tail, "record exceeds published bytes");

        var raw: [max_record_span]u8 = undefined;
        const rec = raw[0..size];
        copyRing(ring, cursor, rec);

        if (rec_type == Type.sample) {
            if (report.samples == samples.len) return halt(report, sink, .capacity, cursor - tail, "sample capacity");
            switch (parseSample(rec, misc, in, &samples[report.samples], &sink)) {
                .ok => {},
                .bad => |why| return halt(report, sink, .malformed, cursor - tail, why),
                .capacity => return halt(report, sink, .capacity, cursor - tail, "user stack capacity"),
            }
            report.samples += 1;
        } else if (knownSide(rec_type)) {
            if (report.sides == sides.len) return halt(report, sink, .capacity, cursor - tail, "side capacity");
            switch (parseSide(rec, misc, in, &sides[report.sides])) {
                .ok => {},
                .bad => |why| return halt(report, sink, .malformed, cursor - tail, why),
                .capacity => return halt(report, sink, .capacity, cursor - tail, "side capacity"),
            }
            report.sides += 1;
        } else {
            // Unknown types are skipped by their declared size. They do not
            // consume side capacity, so a burst of them cannot hide samples.
            report.skipped_unknown += 1;
        }
        cursor += size;
    }
    report.consumed = cursor - tail;
    report.user_states = sink.states_used;
    report.user_stack_bytes = sink.stack_used;
    return report;
}

const Parse = union(enum) { ok, bad: []const u8, capacity };

const UserSink = struct {
    states: []UserState,
    state_base: u32,
    stack: []u8,
    stack_base: u32,
    states_used: u32 = 0,
    stack_used: u32 = 0,
};

fn knownSide(rec_type: u32) bool {
    return rec_type == Type.mmap or rec_type == Type.lost or rec_type == Type.comm or rec_type == Type.exit or rec_type == Type.throttle or rec_type == Type.unthrottle or rec_type == Type.fork or rec_type == Type.mmap2 or rec_type == Type.lost_samples or rec_type == Type.context_switch or rec_type == Type.context_switch_cpu_wide;
}

fn parseSample(rec: []const u8, misc: u16, in: DecodeInput, sample: *Sample, sink: *UserSink) Parse {
    if (in.sample_type & unsupported_body != 0) return .{ .bad = "unsupported sample field" };
    sample.* = .{};
    sample.cpu_mode = cpuMode(misc);
    sample.ip_exact = misc & Misc.exact_ip != 0;
    var cur = Cursor{ .b = rec, .i = 8 };
    const st = in.sample_type;

    if (st & Bits.identifier != 0) _ = cur.takeU64() orelse return .{ .bad = "sample truncated" };
    if (st & Bits.ip != 0) {
        sample.ip = cur.takeU64() orelse return .{ .bad = "sample truncated" };
        sample.ip_present = true;
    }
    if (st & Bits.tid != 0) {
        sample.pid = cur.takeU32() orelse return .{ .bad = "sample truncated" };
        sample.tid = cur.takeU32() orelse return .{ .bad = "sample truncated" };
        sample.tid_present = true;
    }
    if (st & Bits.time != 0) {
        sample.time_ns = cur.takeU64() orelse return .{ .bad = "sample truncated" };
        sample.time_present = true;
    }
    if (st & Bits.addr != 0) _ = cur.takeU64() orelse return .{ .bad = "sample truncated" };
    if (st & Bits.id != 0) _ = cur.takeU64() orelse return .{ .bad = "sample truncated" };
    if (st & Bits.stream_id != 0) _ = cur.takeU64() orelse return .{ .bad = "sample truncated" };
    if (st & Bits.cpu != 0) {
        _ = cur.takeU32() orelse return .{ .bad = "sample truncated" };
        _ = cur.takeU32() orelse return .{ .bad = "sample truncated" };
    }
    if (st & Bits.period != 0) {
        sample.period = cur.takeU64() orelse return .{ .bad = "sample truncated" };
        sample.period_present = true;
    }
    if (st & Bits.callchain != 0) {
        const chain = parseCallchain(&cur, sample, in, cpuMode(misc)) orelse return .{ .bad = "sample truncated" };
        sample.callchain = chain;
    }
    // Side-data indices and counts are committed only after the entire record
    // validates, including fields following the stack bytes.
    var pending = sink.*;
    if (st & (Bits.regs_user | Bits.stack_user) != 0) {
        if (parseUser(&cur, st, in, sample, &pending)) |stop| return stop;
    }
    if (st & Bits.weight != 0) {
        // A callchain the record cannot hold leaves the weight unaligned.
        if (sample.callchain != .truncated or st & (Bits.regs_user | Bits.stack_user) != 0 or cur.i + 8 <= rec.len) {
            sample.weight = cur.takeU64() orelse return .{ .bad = "sample truncated" };
            sample.weight_present = true;
        }
    }
    if (rec.len - cur.i >= 8) return .{ .bad = "sample has trailing bytes" };
    sink.* = pending;
    return .ok;
}

fn parseUser(cur: *Cursor, st: u64, in: DecodeInput, sample: *Sample, sink: *UserSink) ?Parse {
    if (st & Bits.regs_user != 0 and (in.user_regs_mask == 0 or in.user_regs_mask >> max_user_regs != 0)) return .{ .bad = "user register mask is invalid" };
    if (sink.states_used >= sink.states.len) return .capacity;
    const index = std.math.add(u32, sink.state_base, sink.states_used) catch return .{ .bad = "user state index overflow" };
    const stored_index = std.math.add(u32, index, 1) catch return .{ .bad = "user state index overflow" };
    var state = UserState{};
    if (st & Bits.regs_user != 0) {
        if (in.user_regs_mask >> max_user_regs != 0) return .{ .bad = "user register mask includes an unsupported bit" };
        const abi = cur.takeU64() orelse return .{ .bad = "sample truncated" };
        if (abi != regs_abi_none and abi != regs_abi_32 and abi != regs_abi_64) return .{ .bad = "unsupported user register ABI" };
        state.abi = abi;
        state.regs_mask = in.user_regs_mask;
        if (abi != regs_abi_none) {
            if (in.user_regs_mask == 0) return .{ .bad = "user register mask is empty" };
            var bit: usize = 0;
            while (bit < max_user_regs) : (bit += 1) {
                if (in.user_regs_mask & (@as(u64, 1) << @intCast(bit)) == 0) continue;
                state.regs[bit] = cur.takeU64() orelse return .{ .bad = "sample truncated" };
            }
            state.regs_present = true;
        }
    }
    if (st & Bits.stack_user != 0) {
        const size = cur.takeU64() orelse return .{ .bad = "sample truncated" };
        if (in.user_stack_request != 0 and size > in.user_stack_request) return .{ .bad = "user stack exceeds requested size" };
        if (size > max_user_stack) return .{ .bad = "user stack exceeds 8192-byte bound" };
        if (size % 8 != 0) return .{ .bad = "user stack size is not 8-byte aligned" };
        const data = cur.need(@intCast(size)) orelse return .{ .bad = "sample truncated" };
        const dyn: u64 = if (size == 0) 0 else (cur.takeU64() orelse return .{ .bad = "sample truncated" });
        if (dyn > size) return .{ .bad = "dyn_size exceeds the stack field" };
        state.stack_size = size;
        state.stack_dyn = dyn;
        state.stack_present = size != 0;
        const requested: u64 = in.user_stack_request;
        state.stack_short = size != 0 and (dyn < size or (requested != 0 and dyn < requested));
        const keep: u32 = @intCast(dyn);
        const keep_len: usize = keep;
        const used: usize = sink.stack_used;
        if (used > sink.stack.len or sink.stack.len - used < keep_len) return .capacity;
        if (keep != 0) {
            state.stack_off = std.math.add(u32, sink.stack_base, sink.stack_used) catch return .{ .bad = "user stack offset overflow" };
            _ = std.math.add(u32, state.stack_off, keep) catch return .{ .bad = "user stack offset overflow" };
            @memcpy(sink.stack[sink.stack_used..][0..keep], data[0..keep]);
            state.stack_len = keep;
            sink.stack_used += keep;
        }
    }
    sink.states[sink.states_used] = state;
    sample.user_state = stored_index;
    sink.states_used += 1;
    return null;
}

fn parseCallchain(cur: *Cursor, sample: *Sample, in: DecodeInput, initial: CpuMode) ?Callchain {
    const nr = cur.takeU64() orelse return null;
    if (nr > 4096) return null;
    var context = contextFromMode(initial);
    var truncated = in.stack_cap != 0 and nr == in.stack_cap;
    var last_was_marker = false;
    var n: u64 = 0;
    while (n < nr) : (n += 1) {
        const ip = cur.takeU64() orelse {
            // header.size ended before nr entries. Keep the frames already
            // stored and report the chain as truncated.
            sample.callchain = .truncated;
            return .truncated;
        };
        last_was_marker = isContextMarker(ip);
        if (last_was_marker) {
            context = contextFromMarker(ip);
            if (sample.frame_count < in.max_frames) {
                sample.frames[sample.frame_count] = .{
                    .marker = true,
                    .context = context,
                    .raw_marker = ip,
                };
                sample.frame_count += 1;
            } else truncated = true;
        } else if (sample.frame_count < in.max_frames) {
            sample.frames[sample.frame_count] = .{
                .marker = false,
                .context = context,
                .address = ip,
            };
            sample.frame_count += 1;
        } else truncated = true;
    }
    if (last_was_marker) truncated = true;
    return if (truncated) .truncated else .complete;
}

fn parseSide(rec: []const u8, misc: u16, in: DecodeInput, side: *Side) Parse {
    side.* = .{};
    const id_size = sampleIdSize(in);
    const rec_type = readNum(u32, rec[0..4]);
    side.raw_type = rec_type;
    side.raw_size = @intCast(rec.len);
    if (rec.len < id_size + 8) return .{ .bad = "record shorter than sample_id" };
    const body_end = rec.len - id_size;
    var cur = Cursor{ .b = rec[0..body_end], .i = 8 };

    switch (rec_type) {
        Type.lost => {
            if (body_end < 24) return .{ .bad = "lost record is short" };
            side.kind = .lost;
            side.lost_id = cur.takeU64() orelse return .{ .bad = "lost record is short" };
            side.lost_count = cur.takeU64() orelse return .{ .bad = "lost record is short" };
        },
        Type.lost_samples => {
            if (body_end < 16) return .{ .bad = "lost_samples record is short" };
            side.kind = .lost_samples;
            side.lost_count = cur.takeU64() orelse return .{ .bad = "lost_samples record is short" };
        },
        Type.throttle, Type.unthrottle => {
            if (body_end < 32) return .{ .bad = "throttle record is short" };
            side.kind = if (rec_type == Type.throttle) .throttle else .unthrottle;
            side.time_ns = cur.takeU64() orelse return .{ .bad = "throttle record is short" };
            side.time_present = true;
            side.event_id = cur.takeU64() orelse return .{ .bad = "throttle record is short" };
            side.stream_id = cur.takeU64() orelse return .{ .bad = "throttle record is short" };
        },
        Type.exit, Type.fork => {
            if (body_end < 32) return .{ .bad = "task record is short" };
            side.kind = if (rec_type == Type.exit) .exit else .fork;
            side.pid = cur.takeU32() orelse return .{ .bad = "task record is short" };
            side.ppid = cur.takeU32() orelse return .{ .bad = "task record is short" };
            side.tid = cur.takeU32() orelse return .{ .bad = "task record is short" };
            side.ptid = cur.takeU32() orelse return .{ .bad = "task record is short" };
            side.time_ns = cur.takeU64() orelse return .{ .bad = "task record is short" };
            side.time_present = true;
            side.exec = misc & Misc.comm_exec != 0;
        },
        Type.comm => {
            if (body_end < 16) return .{ .bad = "comm record is short" };
            side.kind = .comm;
            side.pid = cur.takeU32() orelse return .{ .bad = "comm record is short" };
            side.tid = cur.takeU32() orelse return .{ .bad = "comm record is short" };
            side.exec = misc & Misc.comm_exec != 0;
            const named = takeName(rec[16..body_end], &side.name);
            side.name_len = named.len;
            side.name_truncated = named.truncated;
        },
        Type.mmap, Type.mmap2 => {
            side.kind = .mmap;
            side.maps_parse_timeout = misc & Misc.proc_map_parse_timeout != 0;
            const fixed: usize = if (rec_type == Type.mmap2) 72 else 40;
            if (body_end < fixed) return .{ .bad = "mmap record is short" };
            side.pid = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
            side.tid = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
            side.address = cur.takeU64() orelse return .{ .bad = "mmap record is short" };
            side.length = cur.takeU64() orelse return .{ .bad = "mmap record is short" };
            side.page_offset = cur.takeU64() orelse return .{ .bad = "mmap record is short" };
            if (rec_type == Type.mmap2) {
                side.build_id = misc & Misc.mmap_build_id != 0;
                side.major = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
                side.minor = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
                side.inode = cur.takeU64() orelse return .{ .bad = "mmap record is short" };
                side.inode_generation = cur.takeU64() orelse return .{ .bad = "mmap record is short" };
                side.prot = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
                side.flags = cur.takeU32() orelse return .{ .bad = "mmap record is short" };
            }
            const named = takeName(rec[fixed..body_end], &side.path);
            side.path_len = named.len;
            side.path_truncated = named.truncated;
        },
        Type.context_switch, Type.context_switch_cpu_wide => {
            const wide = rec_type == Type.context_switch_cpu_wide;
            const expect: usize = if (wide) 16 else 8;
            if (body_end != expect) return .{ .bad = "switch record body has an unexpected length" };
            side.kind = .context_switch;
            side.switch_out = misc & Misc.switch_out != 0;
            if (side.switch_out) {
                side.preempt_present = true;
                side.preempted = misc & Misc.switch_out_preempt != 0;
            }
            side.task_present = in.sample_id_all and in.sample_type & Bits.tid != 0;
            if (wide) {
                side.other_pid = cur.takeU32() orelse return .{ .bad = "switch record is short" };
                side.other_tid = cur.takeU32() orelse return .{ .bad = "switch record is short" };
                side.other_task_present = true;
            }
        },
        else => unreachable,
    }
    applySampleId(rec, in, side);
    return .ok;
}

fn applySampleId(rec: []const u8, in: DecodeInput, side: *Side) void {
    if (!in.sample_id_all) return;
    var i = rec.len - sampleIdSize(in);
    const st = in.sample_type;
    if (st & Bits.tid != 0 and i + 8 <= rec.len) {
        if (side.pid == 0 and side.tid == 0) {
            side.pid = readNum(u32, rec[i..][0..4]);
            side.tid = readNum(u32, rec[i + 4 ..][0..4]);
        }
        i += 8;
    }
    if (st & Bits.time != 0 and i + 8 <= rec.len) {
        if (!side.time_present) {
            side.time_ns = readNum(u64, rec[i..][0..8]);
            side.time_present = true;
        }
        i += 8;
    }
    if (st & Bits.id != 0 and i + 8 <= rec.len) i += 8;
    if (st & Bits.stream_id != 0 and i + 8 <= rec.len) i += 8;
    if (st & Bits.cpu != 0 and i + 8 <= rec.len) {
        side.cpu = readNum(u32, rec[i..][0..4]);
        side.cpu_present = true;
        i += 8;
    }
}

fn sampleIdSize(in: DecodeInput) usize {
    if (!in.sample_id_all) return 0;
    var n: usize = 0;
    const st = in.sample_type;
    if (st & Bits.tid != 0) n += 8;
    if (st & Bits.time != 0) n += 8;
    if (st & Bits.id != 0) n += 8;
    if (st & Bits.stream_id != 0) n += 8;
    if (st & Bits.cpu != 0) n += 8;
    if (st & Bits.identifier != 0) n += 8;
    return n;
}

fn takeName(region: []const u8, dst: []u8) struct { len: u8, truncated: bool } {
    var n: usize = 0;
    while (n < region.len and region[n] != 0) n += 1;
    const copy_n = @min(n, dst.len);
    if (copy_n != 0) @memcpy(dst[0..copy_n], region[0..copy_n]);
    return .{ .len = @intCast(copy_n), .truncated = n > dst.len or n == region.len };
}

fn cpuMode(misc: u16) CpuMode {
    return switch (misc & Misc.cpumode_mask) {
        Misc.kernel => .kernel,
        Misc.user => .user,
        Misc.hypervisor => .hypervisor,
        Misc.guest_kernel => .guest_kernel,
        Misc.guest_user => .guest_user,
        0 => .unknown,
        else => .other,
    };
}

fn contextFromMode(mode: CpuMode) Context {
    return switch (mode) {
        .unknown => .unknown,
        .kernel => .kernel,
        .user => .user,
        .hypervisor => .hypervisor,
        .guest_kernel => .guest_kernel,
        .guest_user => .guest_user,
        .other => .other,
    };
}

fn contextFromMarker(raw: u64) Context {
    if (raw == context_hv) return .hypervisor;
    if (raw == context_kernel) return .kernel;
    if (raw == context_user) return .user;
    if (raw == context_user_deferred) return .user_deferred;
    if (raw == context_guest) return .guest;
    if (raw == context_guest_kernel) return .guest_kernel;
    if (raw == context_guest_user) return .guest_user;
    return .other;
}

fn halt(report: Report, sink: UserSink, status: Status, consumed: u64, reason: []const u8) Report {
    var counted = report;
    counted.user_states = sink.states_used;
    counted.user_stack_bytes = sink.stack_used;
    return finish(counted, status, consumed, reason);
}

fn finish(report: Report, status: Status, consumed: u64, reason: []const u8) Report {
    var out = report;
    out.status = status;
    out.consumed = consumed;
    out.reason = reason;
    return out;
}

const Cursor = struct {
    b: []const u8,
    i: usize,

    fn need(self: *Cursor, n: usize) ?[]const u8 {
        if (self.i + n > self.b.len) return null;
        const s = self.b[self.i .. self.i + n];
        self.i += n;
        return s;
    }
    fn takeU32(self: *Cursor) ?u32 {
        const s = self.need(4) orelse return null;
        return readNum(u32, s);
    }
    fn takeU64(self: *Cursor) ?u64 {
        const s = self.need(8) orelse return null;
        return readNum(u64, s);
    }
};

fn readNum(comptime T: type, bytes: []const u8) T {
    var v: T = 0;
    @memcpy(@as(*[@sizeOf(T)]u8, @ptrCast(&v)), bytes[0..@sizeOf(T)]);
    return v;
}

pub fn copyRing(ring: []const u8, offset: u64, dest: []u8) void {
    if (dest.len == 0) return;
    var at: usize = @intCast(offset % ring.len);
    var i: usize = 0;
    while (i < dest.len) {
        const chunk = @min(dest.len - i, ring.len - at);
        @memcpy(dest[i..][0..chunk], ring[at..][0..chunk]);
        i += chunk;
        at = 0;
    }
}
