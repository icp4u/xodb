//! Task-scoped syscall entry/exit pairing.
//!
//! The kernel sources for the record shape are Linux v7.2
//! `include/trace/events/syscalls.h` (raw_syscalls sys_enter id + args[6],
//! sys_exit id + ret) and `include/linux/trace_events.h` (`struct trace_entry`,
//! 8 bytes). Perf delivers that blob as PERF_SAMPLE_RAW, which the installed
//! UAPI (`/usr/include/linux/perf_event.h`, PERF_RECORD_SAMPLE) explicitly says
//! is not a stable ABI. `Layout` is an argument so a host collector can refuse
//! a format file that disagrees. This module never stores the argument words.
//!
//! Elapsed time is CLOCK_MONOTONIC nanoseconds between the two trace hits.
//! The thread may have been off CPU for the whole interval. The value is not
//! CPU time, not device service time, and not a reason for waiting.
//!
//! Pairing keeps an unknown interval unknown: a capture that starts mid-call,
//! a lost or reordered record, a second entry, a number mismatch, exec, thread
//! death, tid reuse, cancellation, or a full detail buffer does not invent a
//! duration. Storage is a caller-provided span array, independent of any CPU
//! sample cap. Nothing here opens a perf fd or reads process memory.

const std = @import("std");

pub const clock_monotonic: i32 = 1;
pub const type_tracepoint: u32 = 2;
pub const attr_size_through_clockid: u32 = 96;
pub const inherit_bit: u64 = 1 << 1;
pub const sample_tid: u64 = 1 << 1;
pub const sample_time: u64 = 1 << 2;
pub const sample_id: u64 = 1 << 6;
pub const sample_raw: u64 = 1 << 10;
pub const sample_type: u64 = sample_tid | sample_time | sample_id | sample_raw;
pub const record_sample: u32 = 9;
pub const record_lost: u32 = 2;
pub const record_exit: u32 = 4;
pub const record_fork: u32 = 7;

pub const elapsed_note = "CLOCK_MONOTONIC nanoseconds between the entry and exit tracepoints, including time the thread was not running. Not CPU time, not device service time, and not a wait cause.";
pub const provenance = "kernel raw_syscalls entry/exit for an explicitly selected tid. Argument words, paths, and buffer contents are not stored. Children are not enrolled.";

/// Kernel-internal restart codes from Linux v7.2 `include/linux/errno.h`.
/// They are not userspace errno values. A paired interval keeps the raw return
/// and does not treat the code as the value the program observed.
pub const restart_sys: i64 = -512;
pub const restart_nointr: i64 = -513;
pub const restart_nohand: i64 = -514;
pub const restart_block: i64 = -516;

pub const Layout = struct {
    id_off: u16 = 8,
    enter_min: u16 = 64,
    args_off: u16 = 16,
    args_len: u16 = 48,
    exit_min: u16 = 24,
    ret_off: u16 = 16,
};

pub const documented_layout = Layout{};

pub const Kind = enum { enter, exit };

pub const RetClass = enum { value, errno, restart_internal };

pub fn classifyRet(ret: i64) RetClass {
    if (ret == restart_sys or ret == restart_nointr or ret == restart_nohand or ret == restart_block) return .restart_internal;
    if (ret <= -1 and ret >= -4095) return .errno;
    return .value;
}

pub const RawSyscall = struct {
    nr: i64,
    ret: ?i64,
    args_skipped: u16,
    extra_ignored: u16,
};

pub const PayloadError = error{ ShortPayload, NegativeNumber };

/// Copies the syscall number and, for an exit, the return word. The argument
/// region is counted and skipped. `extra_ignored` is bytes past the documented
/// minimum; those bytes are not interpreted.
pub fn decodePayload(kind: Kind, data: []const u8, layout: Layout) PayloadError!RawSyscall {
    const need: u16 = if (kind == .enter) layout.enter_min else layout.exit_min;
    if (data.len < need) return error.ShortPayload;
    if (@as(usize, layout.id_off) + 8 > data.len) return error.ShortPayload;
    const nr = readI64(data, layout.id_off) orelse return error.ShortPayload;
    if (nr < 0) return error.NegativeNumber;
    if (kind == .enter) {
        const args_end = @as(usize, layout.args_off) + @as(usize, layout.args_len);
        if (args_end > data.len) return error.ShortPayload;
        return .{
            .nr = nr,
            .ret = null,
            .args_skipped = layout.args_len,
            .extra_ignored = @intCast(data.len - need),
        };
    }
    if (@as(usize, layout.ret_off) + 8 > data.len) return error.ShortPayload;
    const ret = readI64(data, layout.ret_off) orelse return error.ShortPayload;
    return .{
        .nr = nr,
        .ret = ret,
        .args_skipped = 0,
        .extra_ignored = @intCast(data.len - need),
    };
}

pub const Decoded = union(enum) {
    syscall: struct { kind: Kind, tid: i32, time_ns: u64, event_id: u64, raw: RawSyscall },
    lost: struct { tid: ?i32, lost: u64, event_id: u64, time_ns: ?u64 },
    fork: struct { parent_tid: i32, child_tid: i32, time_ns: u64 },
    thread_exit: struct { tid: i32, time_ns: u64 },
    skipped: struct { typ: u32 },
};

pub const RecordError = error{ Truncated, BadId, ShortPayload, NegativeNumber };

pub fn decodeRecord(rec: []const u8, kind: Kind, expect_id: ?u64, layout: Layout) RecordError!Decoded {
    if (rec.len < 8) return error.Truncated;
    const typ = readU32(rec, 0) orelse return error.Truncated;
    const size = readU16(rec, 6) orelse return error.Truncated;
    if (size < 8 or size > rec.len) return error.Truncated;
    const body = rec[0..size];
    switch (typ) {
        record_sample => {
            if (body.len < 8 + 4 + 4 + 8 + 8 + 4) return error.Truncated;
            var p: usize = 8;
            const tid_u = readU32(body, p + 4) orelse return error.Truncated;
            if (tid_u > std.math.maxInt(i32)) return error.Truncated;
            p += 8;
            const time_ns = readU64(body, p) orelse return error.Truncated;
            p += 8;
            const event_id = readU64(body, p) orelse return error.Truncated;
            p += 8;
            if (expect_id) |want| if (event_id != want) return error.BadId;
            const raw_size64 = readU32(body, p) orelse return error.Truncated;
            p += 4;
            if (p + raw_size64 > body.len) return error.Truncated;
            const raw_bytes = body[p .. p + raw_size64];
            p += raw_size64;
            if (body.len - p >= 8) return error.Truncated;
            const raw = decodePayload(kind, raw_bytes, layout) catch |err| return err;
            return .{ .syscall = .{ .kind = kind, .tid = @intCast(tid_u), .time_ns = time_ns, .event_id = event_id, .raw = raw } };
        },
        record_lost => {
            if (body.len < 8 + 16) return error.Truncated;
            const event_id = readU64(body, 8) orelse return error.Truncated;
            const lost = readU64(body, 16) orelse return error.Truncated;
            var tid: ?i32 = null;
            var time_ns: ?u64 = null;
            if (body.len >= 8 + 16 + 8) {
                const tid_u = readU32(body, 8 + 16 + 4) orelse return error.Truncated;
                if (tid_u > std.math.maxInt(i32)) return error.Truncated;
                tid = @intCast(tid_u);
            }
            if (body.len >= 8 + 16 + 8 + 8) time_ns = readU64(body, 8 + 16 + 8);
            return .{ .lost = .{ .tid = tid, .lost = lost, .event_id = event_id, .time_ns = time_ns } };
        },
        record_fork, record_exit => {
            if (body.len < 8 + 24) return error.Truncated;
            const pid = readU32(body, 8) orelse return error.Truncated;
            const ppid = readU32(body, 12) orelse return error.Truncated;
            const tid = readU32(body, 16) orelse return error.Truncated;
            const ptid = readU32(body, 20) orelse return error.Truncated;
            const time_ns = readU64(body, 24) orelse return error.Truncated;
            if (pid > std.math.maxInt(i32) or ppid > std.math.maxInt(i32) or tid > std.math.maxInt(i32) or ptid > std.math.maxInt(i32)) return error.Truncated;
            if (typ == record_fork) {
                return .{ .fork = .{ .parent_tid = @intCast(ptid), .child_tid = @intCast(tid), .time_ns = time_ns } };
            }
            return .{ .thread_exit = .{ .tid = @intCast(tid), .time_ns = time_ns } };
        },
        else => return .{ .skipped = .{ .typ = typ } },
    }
}

pub const Validity = enum { elapsed, unknown };

pub const Reason = enum {
    complete,
    exit_without_entry,
    missing_exit,
    nested_entry,
    number_mismatch,
    time_reversed,
    loss,
    thread_exit,
    exec,
    tid_reused,
    cancelled,
    truncated,
};

pub const Span = struct {
    tid: i32,
    generation: u32,
    nr: i64,
    exit_nr: ?i64,
    entry_ns: ?u64,
    exit_ns: ?u64,
    ret: ?i64,
    ret_class: ?RetClass,
    validity: Validity,
    reason: Reason,
    elapsed_ns: ?u64,
};

pub const Event = union(enum) {
    enter: struct { tid: i32, nr: i64, time_ns: u64 },
    exit: struct { tid: i32, nr: i64, ret: i64, time_ns: u64 },
    loss: struct { tid: ?i32, lost: u64 },
    thread_exit: struct { tid: i32, time_ns: u64 },
    exec: struct { tid: i32, time_ns: u64 },
    reused: struct { tid: i32, generation: u32, start_ticks: u64 },
    fork: struct { parent_tid: i32, child_tid: i32 },
    truncated: struct { tid: i32 },
    cancel,
};

pub const Side = struct {
    time_ns: u64,
    rank: u8,
    event: Event,
};

pub const Filter = struct {
    tid: ?i32 = null,
    from_ns: u64 = 0,
    to_ns: u64 = std.math.maxInt(u64),
    pub fn validate(self: Filter) error{BadFilter}!void {
        if (self.from_ns >= self.to_ns) return error.BadFilter;
        if (self.tid) |tid| if (tid <= 0) return error.BadFilter;
    }
};

pub const Summary = struct {
    stored_matched: u32,
    dropped: u32,
    lost_records: u64,
    out_of_scope: u32,
    forks_not_followed: u32,
    ignored: u32,
    complete: u32,
    unknown: u32,
    elapsed_ns: u64,
    incomplete: bool,
};

pub const NrSummary = struct {
    nr: i64,
    complete: u32 = 0,
    unknown: u32 = 0,
    elapsed_ns: u64 = 0,
    max_elapsed_ns: u64 = 0,
};

const Slot = struct {
    used: bool = false,
    tid: i32 = 0,
    generation: u32 = 0,
    start_ticks: u64 = 0,
    live: bool = false,
    dead: bool = false,
    poisoned: bool = false,
    nr: i64 = 0,
    entry_ns: u64 = 0,
};

pub const Machine = struct {
    spans: []Span,
    span_count: u32 = 0,
    dropped: u32 = 0,
    lost_records: u64 = 0,
    out_of_scope: u32 = 0,
    forks_not_followed: u32 = 0,
    ignored: u32 = 0,
    exec_seen: u32 = 0,
    truncated: bool = false,
    cancelled: bool = false,
    slots: [32]Slot = .{Slot{}} ** 32,
    nselected: u16 = 0,

    pub fn init(storage: []Span) Machine {
        return .{ .spans = storage };
    }

    pub fn select(self: *Machine, tid: i32, generation: u32, start_ticks: u64) error{ BadTid, ScopeFull, AlreadySelected }!void {
        if (tid <= 0 or generation == 0) return error.BadTid;
        if (self.find(tid) != null) return error.AlreadySelected;
        if (self.nselected == self.slots.len) return error.ScopeFull;
        self.slots[self.nselected] = .{ .used = true, .tid = tid, .generation = generation, .start_ticks = start_ticks };
        self.nselected += 1;
    }

    pub fn feed(self: *Machine, ev: Event) void {
        if (self.cancelled and ev != .cancel) {
            self.ignored += 1;
            return;
        }
        switch (ev) {
            .cancel => {
                self.cancelled = true;
                for (self.slots[0..self.nselected]) |*slot| {
                    if (slot.live) self.emitOpen(slot, .cancelled, null, null, null);
                    slot.live = false;
                    slot.poisoned = true;
                }
            },
            .fork => |fork| {
                if (self.find(fork.parent_tid) == null) {
                    self.out_of_scope += 1;
                    return;
                }
                self.forks_not_followed += 1;
            },
            .loss => |loss| {
                self.lost_records +|= loss.lost;
                if (loss.tid) |tid| {
                    const slot = self.find(tid) orelse {
                        self.out_of_scope += 1;
                        return;
                    };
                    if (slot.live) self.emitOpen(slot, .loss, null, null, null);
                    slot.live = false;
                } else {
                    for (self.slots[0..self.nselected]) |*slot| {
                        if (slot.live) self.emitOpen(slot, .loss, null, null, null);
                        slot.live = false;
                    }
                }
            },
            .reused => |again| {
                const slot = self.find(again.tid) orelse {
                    self.out_of_scope += 1;
                    return;
                };
                if (slot.live) self.emitOpen(slot, .tid_reused, null, null, null);
                slot.live = false;
                slot.dead = false;
                slot.poisoned = false;
                slot.generation = again.generation;
                slot.start_ticks = again.start_ticks;
            },
            .truncated => |mark| {
                self.truncated = true;
                const slot = self.find(mark.tid) orelse {
                    self.out_of_scope += 1;
                    return;
                };
                if (slot.live) self.emitOpen(slot, .truncated, null, null, null);
                slot.live = false;
                slot.poisoned = true;
            },
            .thread_exit => |exit| self.endTask(exit.tid, .thread_exit),
            .exec => |exec| {
                const slot = self.find(exec.tid) orelse {
                    self.out_of_scope += 1;
                    return;
                };
                if (slot.dead or slot.poisoned) {
                    self.ignored += 1;
                    return;
                }
                self.exec_seen += 1;
                if (slot.live) self.emitOpen(slot, .exec, null, null, null);
                slot.live = false;
            },
            .enter => |enter| {
                const slot = self.find(enter.tid) orelse {
                    self.out_of_scope += 1;
                    return;
                };
                if (slot.dead or slot.poisoned) {
                    self.ignored += 1;
                    return;
                }
                if (slot.live) self.emitOpen(slot, .nested_entry, null, null, null);
                slot.live = true;
                slot.nr = enter.nr;
                slot.entry_ns = enter.time_ns;
            },
            .exit => |exit| {
                const slot = self.find(exit.tid) orelse {
                    self.out_of_scope += 1;
                    return;
                };
                if (slot.dead or slot.poisoned) {
                    self.ignored += 1;
                    return;
                }
                if (!slot.live) {
                    self.emit(.{
                        .tid = exit.tid,
                        .generation = slot.generation,
                        .nr = exit.nr,
                        .exit_nr = exit.nr,
                        .entry_ns = null,
                        .exit_ns = exit.time_ns,
                        .ret = exit.ret,
                        .ret_class = classifyRet(exit.ret),
                        .validity = .unknown,
                        .reason = .exit_without_entry,
                        .elapsed_ns = null,
                    });
                    return;
                }
                const entry_ns = slot.entry_ns;
                const entry_nr = slot.nr;
                slot.live = false;
                if (exit.nr != entry_nr) {
                    self.emit(.{
                        .tid = exit.tid,
                        .generation = slot.generation,
                        .nr = entry_nr,
                        .exit_nr = exit.nr,
                        .entry_ns = entry_ns,
                        .exit_ns = exit.time_ns,
                        .ret = exit.ret,
                        .ret_class = classifyRet(exit.ret),
                        .validity = .unknown,
                        .reason = .number_mismatch,
                        .elapsed_ns = null,
                    });
                    return;
                }
                if (exit.time_ns < entry_ns) {
                    self.emit(.{
                        .tid = exit.tid,
                        .generation = slot.generation,
                        .nr = entry_nr,
                        .exit_nr = exit.nr,
                        .entry_ns = entry_ns,
                        .exit_ns = exit.time_ns,
                        .ret = exit.ret,
                        .ret_class = classifyRet(exit.ret),
                        .validity = .unknown,
                        .reason = .time_reversed,
                        .elapsed_ns = null,
                    });
                    return;
                }
                self.emit(.{
                    .tid = exit.tid,
                    .generation = slot.generation,
                    .nr = entry_nr,
                    .exit_nr = exit.nr,
                    .entry_ns = entry_ns,
                    .exit_ns = exit.time_ns,
                    .ret = exit.ret,
                    .ret_class = classifyRet(exit.ret),
                    .validity = .elapsed,
                    .reason = .complete,
                    .elapsed_ns = exit.time_ns - entry_ns,
                });
            },
        }
    }

    pub fn finish(self: *Machine) void {
        for (self.slots[0..self.nselected]) |*slot| {
            if (slot.live) self.emitOpen(slot, .missing_exit, null, null, null);
            slot.live = false;
        }
    }

    pub fn storedBytes(self: *const Machine) usize {
        return @as(usize, self.span_count) * @sizeOf(Span);
    }

    pub fn budgetBytes(self: *const Machine) usize {
        return self.spans.len * @sizeOf(Span);
    }

    pub fn summary(self: *const Machine, filter: Filter) error{BadFilter}!Summary {
        try filter.validate();
        var out = Summary{
            .stored_matched = 0,
            .dropped = self.dropped,
            .lost_records = self.lost_records,
            .out_of_scope = self.out_of_scope,
            .forks_not_followed = self.forks_not_followed,
            .ignored = self.ignored,
            .complete = 0,
            .unknown = 0,
            .elapsed_ns = 0,
            .incomplete = false,
        };
        for (self.spans[0..self.span_count]) |span| {
            if (!overlaps(span, filter)) continue;
            out.stored_matched += 1;
            if (span.validity == .elapsed) {
                out.complete += 1;
                out.elapsed_ns +|= span.elapsed_ns orelse 0;
            } else out.unknown += 1;
        }
        out.incomplete = self.dropped > 0 or self.lost_records > 0 or self.truncated or self.cancelled or out.unknown > 0;
        return out;
    }

    pub fn page(self: *const Machine, filter: Filter, out: []Span) error{BadFilter}!struct { copied: u32, omitted: u32 } {
        try filter.validate();
        var copied: u32 = 0;
        var omitted: u32 = 0;
        for (self.spans[0..self.span_count]) |span| {
            if (!overlaps(span, filter)) continue;
            if (copied < out.len) {
                out[copied] = span;
                copied += 1;
            } else omitted += 1;
        }
        return .{ .copied = copied, .omitted = omitted };
    }

    pub fn byNumber(self: *const Machine, filter: Filter, out: []NrSummary) error{BadFilter}!struct { used: u32, omitted_numbers: u32 } {
        try filter.validate();
        var used: u32 = 0;
        var omitted_numbers: u32 = 0;
        for (self.spans[0..self.span_count]) |span| {
            if (!overlaps(span, filter)) continue;
            const row = findNr(out[0..used], span.nr);
            if (row == null and used == out.len) {
                omitted_numbers += 1;
                continue;
            }
            const dest = row orelse blk: {
                out[used] = .{ .nr = span.nr };
                used += 1;
                break :blk &out[used - 1];
            };
            if (span.validity == .elapsed) {
                dest.complete += 1;
                const elapsed = span.elapsed_ns orelse 0;
                dest.elapsed_ns +|= elapsed;
                if (elapsed > dest.max_elapsed_ns) dest.max_elapsed_ns = elapsed;
            } else dest.unknown += 1;
        }
        return .{ .used = used, .omitted_numbers = omitted_numbers };
    }

    fn endTask(self: *Machine, tid: i32, reason: Reason) void {
        const slot = self.find(tid) orelse {
            self.out_of_scope += 1;
            return;
        };
        if (slot.dead) {
            self.ignored += 1;
            return;
        }
        if (slot.live) self.emitOpen(slot, reason, null, null, null);
        slot.live = false;
        slot.dead = true;
    }

    fn emitOpen(self: *Machine, slot: *Slot, reason: Reason, exit_nr: ?i64, exit_ns: ?u64, ret: ?i64) void {
        self.emit(.{
            .tid = slot.tid,
            .generation = slot.generation,
            .nr = slot.nr,
            .exit_nr = exit_nr,
            .entry_ns = slot.entry_ns,
            .exit_ns = exit_ns,
            .ret = ret,
            .ret_class = if (ret) |value| classifyRet(value) else null,
            .validity = .unknown,
            .reason = reason,
            .elapsed_ns = null,
        });
    }

    fn emit(self: *Machine, span: Span) void {
        if (self.span_count >= self.spans.len) {
            self.dropped += 1;
            return;
        }
        self.spans[self.span_count] = span;
        self.span_count += 1;
    }

    fn find(self: *Machine, tid: i32) ?*Slot {
        for (self.slots[0..self.nselected]) |*slot| if (slot.tid == tid) return slot;
        return null;
    }
};

pub fn overlaps(span: Span, filter: Filter) bool {
    if (filter.tid) |tid| if (span.tid != tid) return false;
    if (span.entry_ns) |entry| {
        if (span.exit_ns) |exit| {
            if (exit < entry) return inRange(entry, filter) or inRange(exit, filter);
            if (exit == entry) return inRange(entry, filter);
            return entry < filter.to_ns and exit > filter.from_ns;
        }
        return inRange(entry, filter);
    }
    if (span.exit_ns) |exit| return inRange(exit, filter);
    return false;
}

fn inRange(time_ns: u64, filter: Filter) bool {
    return time_ns >= filter.from_ns and time_ns < filter.to_ns;
}

fn findNr(rows: []NrSummary, nr: i64) ?*NrSummary {
    for (rows) |*row| if (row.nr == nr) return row;
    return null;
}

pub fn merge(left: []const Side, right: []const Side, out: []Event) error{ Contradictory, Capacity }!usize {
    if (!nondecreasing(left) or !nondecreasing(right)) return error.Contradictory;
    const total = left.len + right.len;
    if (total > out.len) return error.Capacity;
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < left.len or j < right.len) {
        const take_left = if (i >= left.len) false else if (j >= right.len) true else before(left[i], right[j]);
        const side = if (take_left) left[i] else right[j];
        if (take_left) i += 1 else j += 1;
        out[n] = side.event;
        n += 1;
    }
    return n;
}

fn nondecreasing(sides: []const Side) bool {
    if (sides.len < 2) return true;
    var i: usize = 1;
    while (i < sides.len) : (i += 1) if (sides[i].time_ns < sides[i - 1].time_ns) return false;
    return true;
}

fn before(a: Side, b: Side) bool {
    if (a.time_ns < b.time_ns) return true;
    if (a.time_ns > b.time_ns) return false;
    return a.rank < b.rank;
}

pub const ScopeError = error{ NotTaskScoped, CpuWide, InheritsChildren, NotTracepoint, MissingId, SampleType, Clock, AttrSize };

pub const OpenRequest = struct {
    tid: i32,
    cpu: i32,
    flags: u64,
    typ: u32,
    config: u64,
    sample_type: u64,
    clockid: i32,
    size: u32,
};

pub fn validateScope(req: OpenRequest) ScopeError!void {
    if (req.tid <= 0) return error.NotTaskScoped;
    if (req.cpu != -1) return error.CpuWide;
    if (req.flags & inherit_bit != 0) return error.InheritsChildren;
    if (req.typ != type_tracepoint) return error.NotTracepoint;
    if (req.config == 0) return error.MissingId;
    if (req.sample_type != sample_type) return error.SampleType;
    if (req.clockid != clock_monotonic) return error.Clock;
    if (req.size < attr_size_through_clockid) return error.AttrSize;
}

pub fn taskRequest(tid: i32, config: u64) OpenRequest {
    return .{
        .tid = tid,
        .cpu = -1,
        .flags = 0,
        .typ = type_tracepoint,
        .config = config,
        .sample_type = sample_type,
        .clockid = clock_monotonic,
        .size = attr_size_through_clockid,
    };
}

fn readU16(bytes: []const u8, off: usize) ?u16 {
    if (off + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) ?u32 {
    if (off + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) ?u64 {
    if (off + 8 > bytes.len) return null;
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

fn readI64(bytes: []const u8, off: usize) ?i64 {
    const v = readU64(bytes, off) orelse return null;
    return @bitCast(v);
}

fn noPointers(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.fields) |field| if (!noPointers(field.type)) return false;
            return true;
        },
        .@"union" => |info| {
            inline for (info.fields) |field| if (!noPointers(field.type)) return false;
            return true;
        },
        .optional => |info| return noPointers(info.child),
        .pointer => return false,
        else => return true,
    }
}

fn putU16(buf: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, buf[off..][0..2], v, .little);
}
fn putU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn putU64(buf: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, buf[off..][0..8], v, .little);
}
fn putI64(buf: []u8, off: usize, v: i64) void {
    putU64(buf, off, @bitCast(v));
}

fn sample(buf: []u8, kind_pad: u16, tid: u32, time_ns: u64, event_id: u64, raw: []const u8) void {
    const size: u16 = @intCast(8 + 8 + 8 + 8 + 4 + raw.len);
    @memset(buf[0..size], 0);
    putU32(buf, 0, record_sample);
    putU16(buf, 4, kind_pad);
    putU16(buf, 6, size);
    putU32(buf, 8, 1);
    putU32(buf, 12, tid);
    putU64(buf, 16, time_ns);
    putU64(buf, 24, event_id);
    putU32(buf, 32, @intCast(raw.len));
    @memcpy(buf[36 .. 36 + raw.len], raw);
}

fn enterRaw(buf: []u8, nr: i64, fill: u8) void {
    @memset(buf[0..64], fill);
    putI64(buf, 8, nr);
}

fn exitRaw(buf: []u8, nr: i64, ret: i64) void {
    @memset(buf[0..24], 0);
    putI64(buf, 8, nr);
    putI64(buf, 16, ret);
}

fn machine(storage: []Span) Machine {
    return Machine.init(storage);
}

test "payload skips argument bytes and keeps only the number and return" {
    try std.testing.expect(noPointers(Span));
    try std.testing.expect(noPointers(RawSyscall));
    var raw: [80]u8 = undefined;
    enterRaw(&raw, 257, 'A');
    const text = "/etc/passwd";
    @memcpy(raw[16 .. 16 + text.len], text);
    const got = try decodePayload(.enter, raw[0..64], documented_layout);
    try std.testing.expectEqual(@as(i64, 257), got.nr);
    try std.testing.expectEqual(@as(u16, 48), got.args_skipped);
    try std.testing.expect(got.ret == null);
    const extra = try decodePayload(.enter, &raw, documented_layout);
    try std.testing.expectEqual(@as(u16, 16), extra.extra_ignored);
    try std.testing.expectEqual(error.ShortPayload, decodePayload(.enter, raw[0..63], documented_layout));
    var exit_buf: [24]u8 = undefined;
    exitRaw(&exit_buf, 0, -4);
    const left = try decodePayload(.exit, &exit_buf, documented_layout);
    try std.testing.expectEqual(@as(i64, 0), left.nr);
    try std.testing.expectEqual(@as(i64, -4), left.ret.?);
    try std.testing.expectEqual(RetClass.errno, classifyRet(-4));
    try std.testing.expectEqual(RetClass.restart_internal, classifyRet(restart_sys));
    try std.testing.expectEqual(RetClass.value, classifyRet(8));
}

test "short, swapped, and foreign sample records do not become syscalls" {
    var buf: [128]u8 = undefined;
    var raw: [64]u8 = undefined;
    enterRaw(&raw, 0, 0x11);
    sample(&buf, 0, 42, 100, 7, &raw);
    const ok = try decodeRecord(buf[0..108], .enter, 7, documented_layout);
    try std.testing.expectEqual(@as(i32, 42), ok.syscall.tid);
    try std.testing.expectEqual(@as(u16, 48), ok.syscall.raw.args_skipped);
    try std.testing.expectEqual(error.BadId, decodeRecord(buf[0..108], .enter, 8, documented_layout));
    try std.testing.expectEqual(error.Truncated, decodeRecord(buf[0..20], .enter, null, documented_layout));
    putU32(raw[0..8], 0, 0x01000000);
    var bad: [64]u8 = undefined;
    enterRaw(&bad, -1, 0);
    sample(&buf, 0, 42, 100, 7, &bad);
    try std.testing.expectEqual(error.NegativeNumber, decodeRecord(buf[0..108], .enter, null, documented_layout));
    var unknown = [_]u8{0} ** 16;
    putU32(&unknown, 0, 99);
    putU16(&unknown, 6, 16);
    const skipped = try decodeRecord(&unknown, .enter, null, documented_layout);
    try std.testing.expectEqual(@as(u32, 99), skipped.skipped.typ);
}

test "pairing keeps mid-call, loss, reorder, nesting, mismatch, and restart unknown or separate" {
    var storage: [16]Span = undefined;
    var m = machine(&storage);
    try m.select(7, 1, 50);
    m.feed(.{ .exit = .{ .tid = 7, .nr = 0, .ret = 1, .time_ns = 10 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 0, .time_ns = 20 } });
    m.feed(.{ .loss = .{ .tid = 7, .lost = 2 } });
    m.feed(.{ .exit = .{ .tid = 7, .nr = 0, .ret = 0, .time_ns = 30 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 1, .time_ns = 40 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 1, .time_ns = 50 } });
    m.feed(.{ .exit = .{ .tid = 7, .nr = 2, .ret = -1, .time_ns = 60 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 0, .time_ns = 80 } });
    m.feed(.{ .exit = .{ .tid = 7, .nr = 0, .ret = 3, .time_ns = 70 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 0, .time_ns = 90 } });
    m.feed(.{ .exit = .{ .tid = 7, .nr = 0, .ret = restart_sys, .time_ns = 120 } });
    m.feed(.{ .enter = .{ .tid = 7, .nr = 0, .time_ns = 130 } });
    m.feed(.{ .exit = .{ .tid = 7, .nr = 0, .ret = 4, .time_ns = 130 } });
    m.finish();
    try std.testing.expectEqual(@as(u32, 8), m.span_count);
    try std.testing.expectEqual(Reason.exit_without_entry, m.spans[0].reason);
    try std.testing.expect(m.spans[0].elapsed_ns == null);
    try std.testing.expectEqual(Reason.loss, m.spans[1].reason);
    try std.testing.expectEqual(Reason.exit_without_entry, m.spans[2].reason);
    try std.testing.expectEqual(Reason.nested_entry, m.spans[3].reason);
    try std.testing.expectEqual(Reason.number_mismatch, m.spans[4].reason);
    try std.testing.expectEqual(@as(i64, 1), m.spans[4].nr);
    try std.testing.expectEqual(@as(i64, 2), m.spans[4].exit_nr.?);
    try std.testing.expectEqual(Reason.time_reversed, m.spans[5].reason);
    try std.testing.expectEqual(Reason.complete, m.spans[6].reason);
    try std.testing.expectEqual(RetClass.restart_internal, m.spans[6].ret_class.?);
    try std.testing.expectEqual(@as(u64, 30), m.spans[6].elapsed_ns.?);
    try std.testing.expectEqual(@as(u64, 0), m.spans[7].elapsed_ns.?);
    const sum = try m.summary(.{});
    try std.testing.expect(sum.incomplete);
    try std.testing.expectEqual(@as(u32, 2), sum.complete);
    try std.testing.expectEqual(@as(u64, 30), sum.elapsed_ns);
    try std.testing.expectEqual(@as(u64, 2), m.lost_records);
}

test "exec, thread exit, tid reuse, cancel, truncation, and foreign tids stay unenrolled" {
    var storage: [12]Span = undefined;
    var m = machine(&storage);
    try m.select(3, 1, 9);
    m.feed(.{ .enter = .{ .tid = 3, .nr = 59, .time_ns = 10 } });
    m.feed(.{ .exec = .{ .tid = 3, .time_ns = 15 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 59, .ret = 0, .time_ns = 20 } });
    try std.testing.expectEqual(Reason.exec, m.spans[0].reason);
    try std.testing.expect(m.spans[0].elapsed_ns == null);
    try std.testing.expectEqual(Reason.exit_without_entry, m.spans[1].reason);
    m.feed(.{ .enter = .{ .tid = 3, .nr = 0, .time_ns = 30 } });
    m.feed(.{ .thread_exit = .{ .tid = 3, .time_ns = 40 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 0, .ret = 0, .time_ns = 45 } });
    try std.testing.expectEqual(Reason.thread_exit, m.spans[2].reason);
    try std.testing.expectEqual(@as(u32, 1), m.ignored);
    m.feed(.{ .reused = .{ .tid = 3, .generation = 2, .start_ticks = 99 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 0, .ret = 0, .time_ns = 46 } });
    m.feed(.{ .enter = .{ .tid = 3, .nr = 1, .time_ns = 50 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 1, .ret = 8, .time_ns = 60 } });
    try std.testing.expectEqual(@as(u32, 2), m.spans[m.span_count - 1].generation);
    try std.testing.expectEqual(@as(u64, 10), m.spans[m.span_count - 1].elapsed_ns.?);
    m.feed(.{ .fork = .{ .parent_tid = 3, .child_tid = 8 } });
    m.feed(.{ .enter = .{ .tid = 8, .nr = 39, .time_ns = 70 } });
    try std.testing.expectEqual(@as(u32, 1), m.forks_not_followed);
    try std.testing.expectEqual(@as(u32, 1), m.out_of_scope);
    m.feed(.{ .enter = .{ .tid = 3, .nr = 0, .time_ns = 80 } });
    m.feed(.{ .truncated = .{ .tid = 3 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 0, .ret = 1, .time_ns = 90 } });
    try std.testing.expectEqual(Reason.truncated, m.spans[m.span_count - 1].reason);
    try std.testing.expect(m.truncated);
    var other: [4]Span = undefined;
    var n = machine(&other);
    try n.select(4, 1, 1);
    try n.select(5, 1, 1);
    n.feed(.{ .enter = .{ .tid = 4, .nr = 0, .time_ns = 1 } });
    n.feed(.{ .enter = .{ .tid = 5, .nr = 0, .time_ns = 1 } });
    n.feed(.{ .loss = .{ .tid = null, .lost = 3 } });
    try std.testing.expectEqual(Reason.loss, n.spans[0].reason);
    try std.testing.expectEqual(Reason.loss, n.spans[1].reason);
    n.feed(.cancel);
    n.feed(.{ .enter = .{ .tid = 4, .nr = 1, .time_ns = 9 } });
    try std.testing.expect(n.cancelled);
    try std.testing.expectEqual(@as(u32, 1), n.ignored);
}

test "detail capacity drops spans without evicting and without inventing elapsed time" {
    var storage: [1]Span = undefined;
    var m = machine(&storage);
    try m.select(1, 1, 1);
    m.feed(.{ .enter = .{ .tid = 1, .nr = 0, .time_ns = 10 } });
    m.feed(.{ .exit = .{ .tid = 1, .nr = 0, .ret = 1, .time_ns = 40 } });
    m.feed(.{ .enter = .{ .tid = 1, .nr = 1, .time_ns = 50 } });
    m.feed(.{ .exit = .{ .tid = 1, .nr = 1, .ret = 1, .time_ns = 90 } });
    try std.testing.expectEqual(@as(u32, 1), m.span_count);
    try std.testing.expectEqual(@as(u32, 1), m.dropped);
    try std.testing.expectEqual(@as(u64, 30), m.spans[0].elapsed_ns.?);
    try std.testing.expectEqual(@as(usize, @sizeOf(Span)), m.storedBytes());
    const sum = try m.summary(.{});
    try std.testing.expect(sum.incomplete);
    try std.testing.expectEqual(@as(u64, 30), sum.elapsed_ns);
    var page_buf: [1]Span = undefined;
    const listed = try m.page(.{ .from_ns = 0, .to_ns = 100 }, &page_buf);
    try std.testing.expectEqual(@as(u32, 1), listed.copied);
    var rows: [1]NrSummary = undefined;
    const folded = try m.byNumber(.{}, &rows);
    try std.testing.expectEqual(@as(u32, 1), folded.used);
    try std.testing.expectEqual(@as(i64, 0), rows[0].nr);
    try std.testing.expectEqual(error.BadFilter, m.summary(.{ .tid = 0 }));
    try std.testing.expectEqual(error.ScopeFull, blk: {
        var wide: [1]Span = undefined;
        var full = machine(&wide);
        var tid: i32 = 1;
        while (tid <= 32) : (tid += 1) try full.select(tid, 1, 1);
        break :blk full.select(33, 1, 1);
    });
}

test "time and tid filters use half-open overlap and per-number pages" {
    var storage: [6]Span = undefined;
    var m = machine(&storage);
    try m.select(2, 1, 1);
    try m.select(3, 1, 1);
    m.feed(.{ .enter = .{ .tid = 2, .nr = 0, .time_ns = 100 } });
    m.feed(.{ .exit = .{ .tid = 2, .nr = 0, .ret = 1, .time_ns = 180 } });
    m.feed(.{ .enter = .{ .tid = 2, .nr = 1, .time_ns = 180 } });
    m.feed(.{ .exit = .{ .tid = 2, .nr = 1, .ret = 1, .time_ns = 190 } });
    m.feed(.{ .enter = .{ .tid = 3, .nr = 0, .time_ns = 100 } });
    m.feed(.{ .exit = .{ .tid = 3, .nr = 0, .ret = 1, .time_ns = 110 } });
    m.finish();
    const window = Filter{ .tid = 2, .from_ns = 180, .to_ns = 200 };
    const sum = try m.summary(window);
    try std.testing.expectEqual(@as(u32, 1), sum.complete);
    try std.testing.expectEqual(@as(u64, 10), sum.elapsed_ns);
    try std.testing.expect(!sum.incomplete);
    var rows: [1]NrSummary = undefined;
    const folded = try m.byNumber(.{ .from_ns = 0, .to_ns = 1000 }, &rows);
    try std.testing.expectEqual(@as(u32, 1), folded.omitted_numbers);
}

test "two rings merge by timestamp and a backwards ring is not repaired" {
    const enter = [_]Side{
        .{ .time_ns = 10, .rank = 0, .event = .{ .enter = .{ .tid = 1, .nr = 0, .time_ns = 10 } } },
        .{ .time_ns = 30, .rank = 0, .event = .{ .enter = .{ .tid = 1, .nr = 1, .time_ns = 30 } } },
    };
    const exit = [_]Side{
        .{ .time_ns = 25, .rank = 3, .event = .{ .exit = .{ .tid = 1, .nr = 0, .ret = 4, .time_ns = 25 } } },
        .{ .time_ns = 30, .rank = 3, .event = .{ .exit = .{ .tid = 1, .nr = 1, .ret = 5, .time_ns = 30 } } },
    };
    var out: [4]Event = undefined;
    const n = try merge(&enter, &exit, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(out[0] == .enter);
    try std.testing.expect(out[1] == .exit);
    try std.testing.expect(out[2] == .enter);
    var storage: [4]Span = undefined;
    var m = machine(&storage);
    try m.select(1, 1, 1);
    for (out[0..n]) |ev| m.feed(ev);
    m.finish();
    try std.testing.expectEqual(@as(u64, 15), m.spans[0].elapsed_ns.?);
    try std.testing.expectEqual(@as(u64, 0), m.spans[1].elapsed_ns.?);
    const backwards = [_]Side{
        .{ .time_ns = 20, .rank = 0, .event = .{ .enter = .{ .tid = 1, .nr = 0, .time_ns = 20 } } },
        .{ .time_ns = 10, .rank = 0, .event = .{ .enter = .{ .tid = 1, .nr = 0, .time_ns = 10 } } },
    };
    try std.testing.expectEqual(error.Contradictory, merge(&backwards, &exit, &out));
    try std.testing.expectEqual(error.Capacity, merge(&enter, &exit, out[0..3]));
}

test "scope rejects cpu-wide, inherit, missing id, and a foreign clock" {
    try validateScope(taskRequest(4, 120));
    try std.testing.expectEqual(error.NotTaskScoped, validateScope(taskRequest(0, 120)));
    try std.testing.expectEqual(error.NotTaskScoped, validateScope(taskRequest(-1, 120)));
    var wide = taskRequest(4, 120);
    wide.cpu = 0;
    try std.testing.expectEqual(error.CpuWide, validateScope(wide));
    var child = taskRequest(4, 120);
    child.flags |= inherit_bit;
    try std.testing.expectEqual(error.InheritsChildren, validateScope(child));
    try std.testing.expectEqual(error.MissingId, validateScope(taskRequest(4, 0)));
    var clock = taskRequest(4, 120);
    clock.clockid = 0;
    try std.testing.expectEqual(error.Clock, validateScope(clock));
    try std.testing.expect((taskRequest(4, 120).flags & inherit_bit) == 0);
}

test "fork and exit records expose task identity and do not carry a buffer" {
    var buf: [64]u8 = undefined;
    @memset(&buf, 0);
    putU32(&buf, 0, record_fork);
    putU16(&buf, 6, 32);
    putU32(&buf, 8, 20);
    putU32(&buf, 12, 10);
    putU32(&buf, 16, 21);
    putU32(&buf, 20, 11);
    putU64(&buf, 24, 500);
    const fork = try decodeRecord(buf[0..32], .enter, null, documented_layout);
    try std.testing.expectEqual(@as(i32, 11), fork.fork.parent_tid);
    try std.testing.expectEqual(@as(i32, 21), fork.fork.child_tid);
    putU32(&buf, 0, record_exit);
    const exit = try decodeRecord(buf[0..32], .exit, null, documented_layout);
    try std.testing.expectEqual(@as(i32, 21), exit.thread_exit.tid);
    putU32(&buf, 0, record_lost);
    putU16(&buf, 6, 48);
    putU64(&buf, 8, 7);
    putU64(&buf, 16, 4);
    putU32(&buf, 24, 20);
    putU32(&buf, 28, 21);
    const lost = try decodeRecord(buf[0..48], .enter, null, documented_layout);
    try std.testing.expectEqual(@as(u64, 4), lost.lost.lost);
    try std.testing.expectEqual(@as(i32, 21), lost.lost.tid.?);
}

test "a shifted layout is explicit and a pointer-sized number is not dereferenced" {
    const shifted = Layout{ .id_off = 0, .enter_min = 56, .args_off = 8, .args_len = 48, .exit_min = 16, .ret_off = 8 };
    var raw: [56]u8 = undefined;
    @memset(&raw, 0x5a);
    putI64(&raw, 0, 0x7fff00000000);
    const got = try decodePayload(.enter, &raw, shifted);
    try std.testing.expectEqual(@as(i64, 0x7fff00000000), got.nr);
    try std.testing.expectEqual(@as(u16, 48), got.args_skipped);
    try std.testing.expectEqual(error.ShortPayload, decodePayload(.enter, &raw, documented_layout));
}
