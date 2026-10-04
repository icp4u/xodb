//! Next-capture setup and capture outcome descriptions (T14 prototype;
//! proposed home `src/ui/capture_setup.zig`). Pure model, no rendering.
//!
//! - `Snapshot` is an immutable, caller-owned view of the target for one
//!   frame. Nothing here retains pointers into it or into target/capture
//!   storage; selections keep (debugger thread ID, TID) pairs by value.
//! - Next settings are the session's `profile.Config` defaults (savable
//!   choices). The thread selection is separate session state, never saved.
//! - `prepareStart` revalidates the selection against the current snapshot and
//!   builds the request; `Session.startProfile` still performs its own checks.
//! - `describe*` turn recorded capture evidence into readable outcomes with a
//!   next step that today's behavior supports. They never estimate runtime
//!   from the sample rate or infer waiting from missing samples.
const std = @import("std");
const profile = @import("../profile/capture.zig");
const perf = @import("../profile/linux_perf.zig");

/// Display limits, parameterized so storage work (T15) can change them.
pub const Limits = struct {
    max_threads: usize = perf.max_threads,

    min_frequency_hz: u32 = 1,
    max_frequency_hz: u32 = 1000,
};
pub const duration_presets = [_]u32{ 10000, 30000, 60000, 300000, 0 };
pub const frequency_presets = [_]u32{ 49, 99, 199, 499, 997 };

/// A thread as the debugger identifies it: the session-unique debugger ID
/// plus the kernel TID. A reused TID has a new debugger ID.
pub const ThreadRef = struct { id: u64, tid: i32 };
pub const ThreadState = enum { stopped, running, exited };
pub const ThreadRow = struct {
    ref: ThreadRef,
    state: ThreadState,
    /// Kernel thread name (comm), up to 15 bytes; empty when unavailable.
    name: []const u8 = "",
};
/// Identity of the traced program image. A different PID or image epoch
/// (exec, relaunch, attach elsewhere) invalidates any explicit selection.
pub const TargetKey = struct { pid: i32, image_epoch: u64 };
pub const Snapshot = struct {
    target: ?TargetKey,
    stopped: bool,
    offline: bool,
    collecting: bool,
    /// In target order; exited threads may be included and are never selectable.
    threads: []const ThreadRow,
};

pub const Mode = enum { all, subset };
pub const Notice = enum { none, cleared_replaced };

/// The thread choice for the next capture. Kept sorted by debugger ID.
pub const Selection = struct {
    mode: Mode = .all,
    target: ?TargetKey = null,
    refs: [perf.max_threads]ThreadRef = undefined,
    count: usize = 0,

    /// Call once per frame with the current snapshot. A replaced target
    /// clears an explicit subset (and reports it) rather than letting it
    /// match whatever now uses the same TIDs.
    pub fn sync(self: *Selection, snapshot: *const Snapshot) Notice {
        const key = snapshot.target orelse return .none;
        if (self.target) |old| if (std.meta.eql(old, key)) return .none;
        const had = self.mode == .subset;
        self.* = .{ .target = key };
        return if (had) .cleared_replaced else .none;
    }
    fn find(self: *const Selection, id: u64) ?usize {
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.refs[mid].id < id) lo = mid + 1 else hi = mid;
        }
        return if (lo < self.count and self.refs[lo].id == id) lo else null;
    }
    /// True when this exact thread (ID and TID) is in an explicit subset.
    pub fn contains(self: *const Selection, ref: ThreadRef) bool {
        const i = self.find(ref.id) orelse return false;
        return self.refs[i].tid == ref.tid;
    }
    /// Shows whether a row counts toward the next capture.
    pub fn included(self: *const Selection, row: ThreadRow) bool {
        if (row.state == .exited) return false;
        return self.mode == .all or self.contains(row.ref);
    }
    pub fn selectAll(self: *Selection) void {
        self.mode = .all;
        self.count = 0;
    }
    /// An explicit subset, starting empty. Empty stays invalid for starting;
    /// it never means all threads.
    pub fn startSubset(self: *Selection) void {
        self.mode = .subset;
        self.count = 0;
    }
    pub fn add(self: *Selection, ref: ThreadRef) !void {
        self.mode = .subset;
        if (self.find(ref.id)) |i| {
            self.refs[i] = ref;
            return;
        }
        if (self.count == self.refs.len) return error.ProfileThreadLimit;
        var at = self.count;
        while (at > 0 and self.refs[at - 1].id > ref.id) : (at -= 1) self.refs[at] = self.refs[at - 1];
        self.refs[at] = ref;
        self.count += 1;
    }
    pub fn remove(self: *Selection, ref: ThreadRef) void {
        const i = self.find(ref.id) orelse return;
        std.mem.copyForwards(ThreadRef, self.refs[i .. self.count - 1], self.refs[i + 1 .. self.count]);
        self.count -= 1;
    }
    /// Clicking a row. In all-threads mode this starts a subset holding every
    /// current thread except the clicked one, so one click never collapses the
    /// choice to a single thread by surprise.
    pub fn toggle(self: *Selection, snapshot: *const Snapshot, row: ThreadRow) !void {
        if (row.state == .exited) return;
        if (self.mode == .all) {
            self.startSubset();
            for (snapshot.threads) |other| if (other.state != .exited and other.ref.id != row.ref.id) try self.add(other.ref);
            return;
        }
        if (self.contains(row.ref)) self.remove(row.ref) else try self.add(row.ref);
    }
    /// Adds each listed live thread (e.g. the rows matching a name filter).
    pub fn addRows(self: *Selection, rows: []const ThreadRow) !void {
        for (rows) |row| if (row.state != .exited) try self.add(row.ref);
    }
    /// Removes selected threads that no longer exist with the same identity.
    pub fn dropMissing(self: *Selection, snapshot: *const Snapshot) usize {
        var present: [perf.max_threads]bool = @splat(false);
        self.markPresent(snapshot, &present);
        var kept: usize = 0;
        for (self.refs[0..self.count], present[0..self.count]) |ref, here| {
            if (here) {
                self.refs[kept] = ref;
                kept += 1;
            }
        }
        const dropped = self.count - kept;
        self.count = kept;
        return dropped;
    }
    /// One pass over the snapshot: marks each selected ref whose exact thread
    /// is present and not exited. O(rows log selected).
    fn markPresent(self: *const Selection, snapshot: *const Snapshot, present: []bool) void {
        for (snapshot.threads) |row| {
            if (row.state == .exited) continue;
            const i = self.find(row.ref.id) orelse continue;
            if (self.refs[i].tid == row.ref.tid) present[i] = true;
        }
    }
    /// Selected threads that no longer exist with the same identity.
    pub fn missingCount(self: *const Selection, snapshot: *const Snapshot) usize {
        var present: [perf.max_threads]bool = @splat(false);
        self.markPresent(snapshot, &present);
        var n: usize = 0;
        for (present[0..self.count]) |here| n += @intFromBool(!here);
        return n;
    }
    /// Number of selected threads that still exist (for "N selected").
    pub fn liveCount(self: *const Selection, snapshot: *const Snapshot) usize {
        if (self.mode == .all) {
            var n: usize = 0;
            for (snapshot.threads) |row| n += @intFromBool(row.state != .exited);
            return n;
        }
        return self.count - self.missingCount(snapshot);
    }
};

pub const StartProblem = enum {
    offline,
    collecting,
    no_target,
    not_stopped,
    empty_subset,
    syscall_subset,
    missing_threads,
    too_many_threads,
    replaced_target,
};
pub const Prepared = union(enum) {
    ready: profile.Config,
    rejected: struct { problem: StartProblem, count: usize = 0 },
};
/// Builds the request for the next capture from the session defaults and the
/// selection, revalidated against the current snapshot. `tids` receives the
/// subset and must outlive the returned config. Session.startProfile still
/// validates the request (stopped threads, limits, scope).
pub fn prepareStart(snapshot: *const Snapshot, defaults: profile.Config, selection: *const Selection, limits: Limits, tids: []i32) Prepared {
    if (snapshot.offline) return .{ .rejected = .{ .problem = .offline } };
    if (snapshot.collecting) return .{ .rejected = .{ .problem = .collecting } };
    const key = snapshot.target orelse return .{ .rejected = .{ .problem = .no_target } };
    if (!snapshot.stopped) return .{ .rejected = .{ .problem = .not_stopped } };
    if (defaults.syscall_timing and (selection.mode == .all or selection.count > 32)) return .{ .rejected = .{ .problem = .syscall_subset } };
    var config = defaults;
    config.tids = &.{};
    if (selection.mode == .all) {
        const n = selection.liveCount(snapshot);
        if (n > limits.max_threads) return .{ .rejected = .{ .problem = .too_many_threads, .count = n } };
        return .{ .ready = config };
    }
    // A selection made for another image never applies here (sync clears it;
    // this also rejects a start queued before sync observed the change).
    if (selection.target == null or !std.meta.eql(selection.target.?, key)) return .{ .rejected = .{ .problem = .replaced_target } };
    if (selection.count == 0) return .{ .rejected = .{ .problem = .empty_subset } };
    const missing = selection.missingCount(snapshot);
    if (missing > 0) return .{ .rejected = .{ .problem = .missing_threads, .count = missing } };
    if (selection.count > @min(limits.max_threads, tids.len)) return .{ .rejected = .{ .problem = .too_many_threads, .count = selection.count } };
    for (selection.refs[0..selection.count], 0..) |ref, i| tids[i] = ref.tid;
    config.tids = tids[0..selection.count];
    return .{ .ready = config };
}
pub fn problemText(problem: StartProblem) []const u8 {
    return switch (problem) {
        .offline => "Offline archive: recorded evidence only; live capture is unavailable",
        .collecting => "A capture is running; changes apply to the next capture",
        .no_target => "No target. Launch or attach first",
        .not_stopped => "Pause the target (Space) before starting a capture",
        .syscall_subset => "Syscalls require 1 to 32 explicitly chosen threads (Threads tab)",
        .empty_subset => "No threads selected. Select threads or choose All threads",
        .missing_threads => "Some selected threads have exited. Drop them or choose again",
        .too_many_threads => "Too many threads for one capture. Select a subset",
        .replaced_target => "The target changed; the earlier thread choice was cleared",
    };
}

// ------------------------------------------------------------ settings

/// Next preset after `ms`; a custom value advances to the next larger preset.
/// Same order as the existing T shortcut.
pub fn nextDuration(ms: u32) u32 {
    for (duration_presets) |preset| if (preset > ms and ms != 0) return preset;
    return if (ms == 0) duration_presets[0] else 0;
}
pub fn durationText(buffer: []u8, ms: u32) []const u8 {
    if (ms == 0) return "until stopped";
    if (ms >= 120000 and ms % 60000 == 0) return std.fmt.bufPrint(buffer, "{d} min", .{ms / 60000}) catch "";
    if (ms % 1000 == 0) return std.fmt.bufPrint(buffer, "{d} s", .{ms / 1000}) catch "";
    return std.fmt.bufPrint(buffer, "{d} ms", .{ms}) catch "";
}
pub fn isPresetDuration(ms: u32) bool {
    return std.mem.indexOfScalar(u32, &duration_presets, ms) != null;
}
pub const FieldKind = enum { duration_s, frequency_hz };
/// A small numeric editor driven by committed text input. It edits a copy;
/// `commit` validates and returns the value for the caller to apply.
pub const NumberField = struct {
    kind: FieldKind,
    digits: [10]u8 = undefined,
    len: usize = 0,
    pub fn begin(kind: FieldKind) NumberField {
        return .{ .kind = kind };
    }
    /// Accepts committed text; ignores anything but ASCII digits.
    pub fn type_(self: *NumberField, typed: []const u8) void {
        for (typed) |ch| if (ch >= '0' and ch <= '9' and self.len < self.digits.len) {
            if (self.len == 1 and self.digits[0] == '0') self.len = 0;
            self.digits[self.len] = ch;
            self.len += 1;
        };
    }
    pub fn backspace(self: *NumberField) void {
        self.len -|= 1;
    }
    pub fn text(self: *const NumberField) []const u8 {
        return self.digits[0..self.len];
    }
    /// Seconds for duration (0 = until stopped), hertz for rate.
    pub fn commit(self: *const NumberField, limits: Limits) !u32 {
        if (self.len == 0) return error.EmptyNumber;
        const value = std.fmt.parseInt(u64, self.text(), 10) catch return error.NumberTooLarge;
        return switch (self.kind) {
            .duration_s => if (value * 1000 > std.math.maxInt(u32)) error.NumberTooLarge else @intCast(value * 1000),
            .frequency_hz => if (value < limits.min_frequency_hz or value > limits.max_frequency_hz) error.NumberOutOfRange else @intCast(value),
        };
    }
};

// ------------------------------------------------------------ outcomes

/// Recorded facts about one capture, copied by value from the model (see
/// `factsFrom`). Times are CLOCK_MONOTONIC nanoseconds.
pub const Facts = struct {
    id: u64,
    offline: bool,
    collecting: bool,
    status: profile.Stop,
    stop_reasons: []const profile.Stop,
    started_ns: u64,
    ended_ns: ?u64,
    duration_ms: u32,
    frequency_hz: u32,
    context_switch: bool,
    samples: usize,
    sample_limit: usize = profile.max_samples,
    discarded_samples: u64,
    lost_samples: u64,
    lost_records: u64,
    follow_threads: bool = false,
    selected_threads: usize,
    unselected_threads: usize,
    scope_change: ?profile.ScopeChange,
    failure: ?perf.Failure,
    pid: i32,
    /// Sampled user stacks (T10): request, total budget and recorded coverage.
    stack_bytes: u32 = 0,
    stack_budget: u32 = 0,
    stacks: StackCounts = .{},
};
pub const StackCounts = struct { samples: usize = 0, registers: usize = 0, retained: usize = 0, budget_gaps: usize = 0, kernel_absent: usize = 0, missing: usize = 0, first_gap: ?usize = null };
/// Proposed presets; any validated value from preferences or MCP still shows.
pub const stack_presets = [_]u32{ 0, 1024, 4096, 8192 };
pub const stack_budget_presets = [_]u32{ 8 * 1024 * 1024, 32 * 1024 * 1024, 64 * 1024 * 1024 };
fn stackCounts(capture: *const profile.Capture) StackCounts {
    var counts = StackCounts{};
    if (capture.config.user_stack_bytes == 0) return counts;
    for (0..capture.samples.len()) |ordinal| {
        const sample = capture.samples.core(ordinal);
        counts.samples += 1;
        if (sample.user_state == 0 or sample.user_state > capture.user_state.count) {
            counts.missing += 1;
            continue;
        }
        const entry = capture.user_state.entries[sample.user_state - 1];
        counts.registers += @intFromBool(entry.state.regs_present);
        if (entry.status == .budget) {
            counts.budget_gaps += 1;
        } else if (entry.state.stack_len == 0) {
            counts.kernel_absent += 1;
        } else counts.retained += 1;
    }
    counts.first_gap = capture.user_state.first_skipped;
    return counts;
}
pub fn sizeText(buffer: []u8, bytes: u64) []const u8 {
    if (bytes == 0) return "off";
    if (bytes >= 1024 * 1024 and bytes % (1024 * 1024) == 0) return std.fmt.bufPrint(buffer, "{d} MiB", .{bytes / (1024 * 1024)}) catch "";
    if (bytes >= 1024 and bytes % 1024 == 0) return std.fmt.bufPrint(buffer, "{d} KiB", .{bytes / 1024}) catch "";
    return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
}
/// Recorded stack coverage, or "" when stacks were off.
pub fn stackLine(buffer: []u8, facts: Facts) []const u8 {
    if (facts.stack_bytes == 0) return "";
    const s = facts.stacks;
    var a: [24]u8 = undefined;
    var b: [24]u8 = undefined;
    var gap: [48]u8 = undefined;
    const first = if (s.first_gap) |at| std.fmt.bufPrint(&gap, " (first ordinal #{d})", .{at}) catch "" else "";
    return std.fmt.bufPrint(buffer, "Stacks {s}/{s}: {d}/{d} kept, {d} over budget{s}, {d} no stack, {d} no regs", .{ sizeText(&a, facts.stack_bytes), sizeText(&b, facts.stack_budget), s.retained, s.samples, s.budget_gaps, first, s.kernel_absent, (s.samples - s.registers) }) catch "";
}
pub fn factsFrom(capture: *const profile.Capture) Facts {
    return .{ .follow_threads = capture.config.follow_threads, .stack_bytes = capture.config.user_stack_bytes, .stack_budget = capture.config.user_stack_budget_bytes, .stacks = stackCounts(capture), .id = capture.id, .offline = capture.offline, .collecting = capture.collector != null, .status = capture.status, .stop_reasons = capture.stop_reasons[0..capture.stop_reason_count], .started_ns = capture.started_ns, .ended_ns = capture.ended_ns, .duration_ms = capture.config.duration_ms, .frequency_hz = capture.config.frequency_hz, .context_switch = capture.config.context_switch, .samples = capture.samples.len(), .sample_limit = capture.config.sample_limit, .discarded_samples = capture.discarded_samples, .lost_samples = capture.lost_samples, .lost_records = capture.lost_records, .selected_threads = capture.thread_count, .unselected_threads = capture.unselected_threads, .scope_change = capture.scope_change, .failure = capture.failure, .pid = capture.pid };
}
pub const Severity = enum { normal, warning, failure };
/// A readable stop reason: what happened, and a next step today's behavior supports.
pub const Reason = struct { title: []const u8, next: []const u8, severity: Severity };
pub fn reason(stop: profile.Stop) Reason {
    return switch (stop) {
        .collecting => .{ .title = "Capturing", .next = "P stops collection; the target keeps its current run state", .severity = .normal },
        .manual => .{ .title = "Stopped by you", .next = "", .severity = .normal },
        .duration => .{ .title = "Reached its time limit", .next = "For longer runs choose a longer duration or until stopped (T)", .severity = .normal },
        .target_ended => .{ .title = "The target exited", .next = "", .severity = .normal },
        .capacity => .{ .title = "Sample storage filled", .next = "Use a shorter capture, a lower rate or fewer threads", .severity = .warning },
        .mapping_limit => .{ .title = "Mapping history filled", .next = "Use a shorter capture; later samples keep raw addresses", .severity = .warning },
        .mappings_changed, .image_changed => .{ .title = "The target started a different program", .next = "Start a new capture for the new program", .severity = .warning },
        .metadata_lost => .{ .title = "The kernel dropped profiling records", .next = "Try a lower rate or fewer threads; affected samples keep raw addresses", .severity = .warning },
        .thread_scope_changed => .{ .title = "A new thread or process appeared", .next = "Pause and start a new capture to include the current threads", .severity = .warning },
        .syscall_limit => .{ .title = "Syscall detail filled", .next = "Use a shorter capture, fewer threads or a larger syscall limit", .severity = .warning },
        .syscall_error => .{ .title = "Syscall collection failed", .next = "Retained evidence is kept; check the diagnostic before retrying", .severity = .failure },
        .scheduling_limit => .{ .title = "Scheduling history filled", .next = "Use a shorter capture or turn scheduling off", .severity = .warning },
        .scheduling_error => .{ .title = "Scheduling records were inconsistent", .next = "Scheduling for this capture is shown as unknown; CPU samples remain", .severity = .warning },
        .decode_error, .drain_limit, .collector_error => .{ .title = "Collection failed", .next = "Samples gathered so far are kept; start a new capture", .severity = .failure },
    };
}
pub const Clock = struct { now_ns: u64 };
/// The one-line summary, written into `buffer`.
pub fn summaryLine(buffer: []u8, facts: Facts, _: Limits, clock: Clock) []const u8 {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    const end = if (facts.collecting) clock.now_ns else facts.ended_ns orelse facts.started_ns;
    const elapsed = elapsedText(&a, end -| facts.started_ns);
    var c: [48]u8 = undefined;
    const limit = if (facts.duration_ms == 0) ", no time limit" else std.fmt.bufPrint(&c, " of {s}", .{durationText(&b, facts.duration_ms)}) catch "";
    const state = if (facts.offline) "recorded" else if (facts.collecting) "capturing" else "done";
    return std.fmt.bufPrint(buffer, "#{d} {s}  {s}{s}  /  {d} of {d} samples  /  {d} thread{s}{s}", .{ facts.id, state, elapsed, limit, facts.samples, facts.sample_limit, facts.selected_threads, if (facts.selected_threads == 1) "" else "s", unselectedText(facts) }) catch buffer[0..0];
}
fn unselectedText(facts: Facts) []const u8 {
    return if (facts.unselected_threads > 0) " (others not sampled)" else if (facts.follow_threads) " (following new threads)" else "";
}
pub fn elapsedText(buffer: []u8, ns: u64) []const u8 {
    const s = ns / 1_000_000_000;
    if (s >= 3600) return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    if (s >= 60) return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buffer, "{d}.{d} s", .{ s, ns / 100_000_000 % 10 }) catch "";
}
/// Time left before the recorded deadline, from the clock, not the sample rate.
pub fn remainingNs(facts: Facts, clock: Clock) ?u64 {
    if (!facts.collecting or facts.duration_ms == 0) return null;
    return (facts.started_ns + @as(u64, facts.duration_ms) * 1_000_000) -| clock.now_ns;
}
/// Loss and discards in words, or "" when there were none.
pub fn lossLine(buffer: []u8, facts: Facts) []const u8 {
    var n: usize = 0;
    if (facts.lost_samples > 0 or facts.lost_records > 0) {
        const piece = std.fmt.bufPrint(buffer, "Lost: the kernel reported {d} lost sample{s} in {d} loss record{s}", .{ facts.lost_samples, if (facts.lost_samples == 1) "" else "s", facts.lost_records, if (facts.lost_records == 1) "" else "s" }) catch return "";
        n = piece.len;
    }
    if (facts.discarded_samples > 0) {
        const piece = std.fmt.bufPrint(buffer[n..], "{s}{d} sample{s} not kept after storage filled", .{ if (n == 0) "Lost: " else "; ", facts.discarded_samples, if (facts.discarded_samples == 1) "" else "s" }) catch return buffer[0..n];
        n += piece.len;
    }
    return buffer[0..n];
}
/// Specific detail for the primary reason, using recorded evidence.
pub fn detailLine(buffer: []u8, facts: Facts, _: Limits) []const u8 {
    var a: [32]u8 = undefined;
    return switch (facts.status) {
        .duration => std.fmt.bufPrint(buffer, "The limit was {s}, measured on the wall clock including time paused in the debugger", .{durationText(&a, facts.duration_ms)}) catch "",
        .capacity => std.fmt.bufPrint(buffer, "{d} of {d} samples stored; {d} further samples were not kept", .{ facts.samples, facts.sample_limit, facts.discarded_samples }) catch "",
        .thread_scope_changed => if (facts.scope_change) |change| std.fmt.bufPrint(buffer, "New {s}: PID {d} / TID {d}, created by TID {d}. Task outside capture scope", .{ if (change.pid == @as(u32, @bitCast(facts.pid))) "thread" else "child process", change.pid, change.tid, change.parent_tid }) catch "" else "New task outside capture scope",
        .collector_error, .decode_error, .drain_limit => if (facts.failure) |f| failureLine(buffer, f) else "",
        else => "",
    };
}
pub fn failureLine(buffer: []u8, failure: perf.Failure) []const u8 {
    const what = switch (failure.kind) {
        .permission => "The system refused permission to profile",
        .resource => "The system ran out of a profiling resource",
        .thread_gone => "A selected thread exited while opening",
        .configuration => "The kernel rejected the profiling settings",
        .unavailable => "Profiling is unavailable on this system",
        .other => "Profiling could not be opened",
    };
    return std.fmt.bufPrint(buffer, "{s} ({s}, errno {d}{s}{s})", .{ what, failure.syscall, failure.errno, if (failure.detail.len > 0) ": " else "", failure.detail }) catch "";
}
/// Readable text for a failed start. These are not capture-stop diagnostics.
pub fn startFailure(buffer: []u8, start_error: []const u8, failure: ?perf.Failure, requested_threads: usize, limits: Limits) Reason {
    if (failure) |f| {
        const next = switch (f.kind) {
            .permission => "xodb does not change system settings. Grant perf_event_open access for this process (see PROFILING.md)",
            .resource => "Select fewer threads; each one needs a file descriptor and a ring buffer",
            .thread_gone => "Pause and try again; the thread list changed",
            .configuration => "Try a lower sample rate or scheduling off",
            else => "The target is unchanged and remains attached",
        };
        return .{ .title = failureLine(buffer, f), .next = next, .severity = .failure };
    }
    const title, const next = if (std.mem.eql(u8, start_error, "ProfileThreadLimit"))
        .{ std.fmt.bufPrint(buffer, "Capture needs {d} threads; the limit is {d}", .{ requested_threads, limits.max_threads }) catch "", "Select a subset of threads" }
    else if (std.mem.eql(u8, start_error, "NotStopped"))
        .{ "The target is running", "Pause it (Space), then start" }
    else if (std.mem.eql(u8, start_error, "InvalidProfileThreads"))
        .{ "The selected threads no longer match the target", "Review the thread selection" }
    else if (std.mem.eql(u8, start_error, "StepInProgress"))
        .{ "A source step is in progress", "Wait for the step to finish" }
    else if (std.mem.eql(u8, start_error, "OfflineSession"))
        .{ "Offline archive", "Live capture is unavailable; recorded evidence only" }
    else
        .{ std.fmt.bufPrint(buffer, "Capture did not start ({s})", .{start_error}) catch "", "The target is unchanged" };
    return .{ .title = title, .next = next, .severity = .failure };
}

// ------------------------------------------------------------ tests

const testing = std.testing;
fn testRows(comptime n: usize) [n]ThreadRow {
    var out: [n]ThreadRow = undefined;
    for (&out, 0..) |*row, i| row.* = .{ .ref = .{ .id = i + 1, .tid = @intCast(1000 + i) }, .state = .stopped, .name = "worker" };
    return out;
}
fn snap(threads: []const ThreadRow) Snapshot {
    return .{ .target = .{ .pid = 1000, .image_epoch = 1 }, .stopped = true, .offline = false, .collecting = false, .threads = threads };
}

test "all, subset and empty selections; empty never means all" {
    var list = testRows(4);
    const s = snap(&list);
    var sel = Selection{};
    _ = sel.sync(&s);
    var tids: [8]i32 = undefined;
    const defaults = profile.Config{ .frequency_hz = 199, .duration_ms = 0, .context_switch = true };
    const all = prepareStart(&s, defaults, &sel, .{}, &tids).ready;
    try testing.expectEqual(@as(usize, 0), all.tids.len);
    try testing.expectEqual(@as(u32, 199), all.frequency_hz);
    try testing.expectEqual(@as(u32, 0), all.duration_ms);
    try testing.expect(all.context_switch);
    sel.startSubset();
    try testing.expectEqual(StartProblem.empty_subset, prepareStart(&s, defaults, &sel, .{}, &tids).rejected.problem);
    try sel.add(list[2].ref);
    try sel.add(list[0].ref);
    const subset = prepareStart(&s, defaults, &sel, .{}, &tids).ready;
    try testing.expectEqualSlices(i32, &.{ 1000, 1002 }, subset.tids);
    // Toggling from all-threads mode deselects one thread, not all others.
    sel.selectAll();
    try sel.toggle(&s, list[1]);
    try testing.expectEqual(Mode.subset, sel.mode);
    try testing.expectEqual(@as(usize, 3), sel.liveCount(&s));
    try testing.expect(!sel.included(list[1]) and sel.included(list[0]));
    // Removing the last selected thread leaves an invalid empty subset.
    for (list) |row| sel.remove(row.ref);
    try testing.expectEqual(Mode.subset, sel.mode);
    try testing.expectEqual(StartProblem.empty_subset, prepareStart(&s, defaults, &sel, .{}, &tids).rejected.problem);
}

test "list churn, exited threads and a reused TID never enroll or substitute" {
    var list = testRows(3);
    var s = snap(&list);
    var sel = Selection{};
    _ = sel.sync(&s);
    try sel.add(list[1].ref);
    var tids: [8]i32 = undefined;
    // A new thread appears: an explicit subset does not grow.
    var grown = testRows(4);
    s.threads = &grown;
    try testing.expectEqual(@as(usize, 1), prepareStart(&s, .{}, &sel, .{}, &tids).ready.tids.len);
    // The selected thread exits and its TID is reused by a new thread.
    var reused = grown;
    reused[1] = .{ .ref = .{ .id = 99, .tid = list[1].ref.tid }, .state = .stopped, .name = "imposter" };
    s.threads = &reused;
    try testing.expect(!sel.included(reused[1]));
    const rejected = prepareStart(&s, .{}, &sel, .{}, &tids).rejected;
    try testing.expectEqual(StartProblem.missing_threads, rejected.problem);
    try testing.expectEqual(@as(usize, 1), rejected.count);
    try testing.expectEqual(@as(usize, 1), sel.dropMissing(&s));
    try testing.expectEqual(StartProblem.empty_subset, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    // An exited row is shown but never selectable.
    var exited = grown;
    exited[0].state = .exited;
    s.threads = &exited;
    try sel.toggle(&s, exited[0]);
    try testing.expectEqual(@as(usize, 0), sel.count);
}

test "target replacement clears a subset; a start queued before sync is rejected" {
    var list = testRows(3);
    var s = snap(&list);
    var sel = Selection{};
    _ = sel.sync(&s);
    try sel.add(list[0].ref);
    var tids: [8]i32 = undefined;
    // exec: same PID, new image epoch. Same TIDs and IDs must not carry over.
    s.target = .{ .pid = 1000, .image_epoch = 2 };
    try testing.expectEqual(StartProblem.replaced_target, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    try testing.expectEqual(Notice.cleared_replaced, sel.sync(&s));
    try testing.expectEqual(Mode.all, sel.mode);
    try testing.expectEqual(Notice.none, sel.sync(&s));
    // All-threads mode survives replacement silently: it means "all current".
    s.target = .{ .pid = 2000, .image_epoch = 1 };
    try testing.expectEqual(Notice.none, sel.sync(&s));
}

test "gating: offline, collecting, running and thread limits" {
    var list = testRows(3);
    var s = snap(&list);
    var sel = Selection{};
    _ = sel.sync(&s);
    var tids: [2]i32 = undefined;
    s.offline = true;
    try testing.expectEqual(StartProblem.offline, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    s.offline = false;
    s.collecting = true;
    try testing.expectEqual(StartProblem.collecting, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    s.collecting = false;
    s.stopped = false;
    try testing.expectEqual(StartProblem.not_stopped, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    s.stopped = true;
    try testing.expectEqual(StartProblem.too_many_threads, prepareStart(&s, .{}, &sel, .{ .max_threads = 2 }, &tids).rejected.problem);
    for (list) |row| try sel.add(row.ref);
    try testing.expectEqual(StartProblem.too_many_threads, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
    s.target = null;
    try testing.expectEqual(StartProblem.no_target, prepareStart(&s, .{}, &sel, .{}, &tids).rejected.problem);
}

test "durations, presets, custom values and numeric fields" {
    var ms: u32 = 60000;
    for ([_]u32{ 300000, 0, 10000, 30000, 60000 }) |expected| {
        ms = nextDuration(ms);
        try testing.expectEqual(expected, ms);
    }
    try testing.expectEqual(@as(u32, 300000), nextDuration(90000));
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("90 s", durationText(&buffer, 90000));
    try testing.expectEqualStrings("5 min", durationText(&buffer, 300000));
    try testing.expectEqualStrings("1500 ms", durationText(&buffer, 1500));
    try testing.expectEqualStrings("until stopped", durationText(&buffer, 0));
    var field = NumberField.begin(.frequency_hz);
    field.type_("0x2a5");
    try testing.expectEqualStrings("25", field.text());
    try testing.expectEqual(@as(u32, 25), try field.commit(.{}));
    field.type_("00");
    try testing.expectError(error.NumberOutOfRange, field.commit(.{}));
    field.backspace();
    field.backspace();
    field.backspace();
    field.backspace();
    try testing.expectError(error.EmptyNumber, field.commit(.{}));
    var seconds = NumberField.begin(.duration_s);
    seconds.type_("0");
    try testing.expectEqual(@as(u32, 0), try seconds.commit(.{}));
    seconds.type_("4294968");
    try testing.expectError(error.NumberTooLarge, seconds.commit(.{}));
}

test "outcomes use recorded evidence and keep the primary reason" {
    const reasons = [_]profile.Stop{ .thread_scope_changed, .metadata_lost };
    var facts = Facts{ .id = 3, .offline = false, .collecting = false, .status = .thread_scope_changed, .stop_reasons = &reasons, .started_ns = 1_000_000_000, .ended_ns = 3_500_000_000, .duration_ms = 60000, .frequency_hz = 99, .context_switch = false, .samples = 412, .discarded_samples = 0, .lost_samples = 3, .lost_records = 1, .selected_threads = 2, .unselected_threads = 5, .scope_change = .{ .pid = 1000, .tid = 1077, .parent_pid = 1000, .parent_tid = 1001, .time_ns = null }, .failure = null, .pid = 1000 };
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings("#3 done  2.5 s of 60 s  /  412 of 16384 samples  /  2 threads (others not sampled)", summaryLine(&buffer, facts, .{}, .{ .now_ns = 99_000_000_000 }));
    try testing.expectEqualStrings("A new thread or process appeared", reason(facts.status).title);
    try testing.expectEqualStrings("New thread: PID 1000 / TID 1077, created by TID 1001. Task outside capture scope", detailLine(&buffer, facts, .{}));
    try testing.expect(lossLine(&buffer, facts).len > 0);
    facts.collecting = true;
    facts.ended_ns = null;
    try testing.expectEqual(@as(?u64, 57_500_000_000), remainingNs(facts, .{ .now_ns = 3_500_000_000 }));
    facts.duration_ms = 0;
    try testing.expectEqual(@as(?u64, null), remainingNs(facts, .{ .now_ns = 3_500_000_000 }));
    try testing.expectEqualStrings("#3 capturing  2.5 s, no time limit  /  412 of 16384 samples  /  2 threads (others not sampled)", summaryLine(&buffer, facts, .{}, .{ .now_ns = 3_500_000_000 }));
    // Every stop enum value has readable text.
    inline for (@typeInfo(profile.Stop).@"enum".fields) |field| try testing.expect(reason(@enumFromInt(field.value)).title.len > 0);
    const denied = startFailure(&buffer, "PerfOpenFailed", .{ .kind = .permission, .syscall = "perf_event_open", .errno = 13 }, 4, .{});
    try testing.expect(std.mem.indexOf(u8, denied.title, "permission") != null);
    try testing.expect(std.mem.indexOf(u8, denied.next, "does not change system settings") != null);
    const limit = startFailure(&buffer, "ProfileThreadLimit", null, 2000, .{});
    try testing.expectEqualStrings("Capture needs 2000 threads; the limit is 1024", limit.title);
}

test "capture summary uses the recorded sample ceiling" {
    const capture = try @import("../profile/archive_fixture.zig").build(std.testing.allocator, .empty, null);
    defer capture.deinit();
    capture.config.sample_limit = 65536;
    capture.status = .capacity;
    const facts = factsFrom(capture);
    var buffer: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, summaryLine(&buffer, facts, .{}, .{ .now_ns = 0 }), "0 of 65536 samples") != null);
    try std.testing.expect(std.mem.indexOf(u8, detailLine(&buffer, facts, .{}), "0 of 65536 samples") != null);
}
