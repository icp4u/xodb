//! A bounded, session-owned perf capture with observed mapping history.
//! Enrollment is explicit at a held newborn stop under the selected scope policy.
const std = @import("std");
const perf = @import("linux_perf.zig");
const records = @import("records.zig");
const modules = @import("../model/modules.zig");
const info = @import("../debug/info.zig");
const activity = @import("activity.zig");
const flame = @import("flame.zig");
const mappings = @import("mappings.zig");
const timeline = @import("timeline.zig");
const scheduling = @import("scheduling.zig");
const syscall_model = @import("syscalls.zig");
const syscall_perf = @import("linux_syscalls.zig");
const intervals = @import("intervals.zig");
pub const sample_state = @import("sample_state.zig");
pub const sample_store = @import("sample_store.zig");
/// Default and legacy archive sample ceiling.
pub const max_samples = 16384;
pub const max_sample_limit = 65536;
pub const sample_budget_bytes = sample_store.default_budget_bytes;
pub const max_frames_cached = 8192;
// Keep the previous maximum total data-page budget, but give smaller thread
// sets more room for bursts of mapping metadata. Metadata adds one page/tid.
fn ringPages(thread_count: usize) u8 {
    var pages: u8 = perf.max_data_pages;
    while (@as(usize, pages) * thread_count > @as(usize, perf.max_threads) * 4) pages /= 2;
    return pages;
}
pub const Config = struct {
    sample_limit: u32 = max_samples,
    frequency_hz: u32 = 99,
    /// Zero disables the wall-clock deadline; evidence/resource limits still apply.
    duration_ms: u32 = 60000,
    context_switch: bool = false,
    syscall_timing: bool = false,
    syscall_limit: u32 = syscall_model.default_limit,
    /// Effective only for an all-thread selection. Explicit TID lists stay fixed.
    follow_threads: bool = true,
    ring_budget_bytes: u32 = 64 * 1024 * 1024,
    user_stack_bytes: u32 = 0,
    user_stack_budget_bytes: u32 = sample_state.default_budget_bytes,
    tids: []const i32 = &.{},
    pub fn validate(self: Config) !void {
        if (self.syscall_limit == 0 or self.syscall_limit > syscall_model.max_limit) return error.InvalidProfileConfig;
        if (self.syscall_timing and self.tids.len > syscall_model.max_threads) return error.SyscallThreadLimit;
        if (self.sample_limit == 0 or self.sample_limit > max_sample_limit) return error.InvalidProfileConfig;
        if (self.ring_budget_bytes < 4096 or self.ring_budget_bytes > 256 * 1024 * 1024) return error.InvalidProfileConfig;
        if (self.user_stack_budget_bytes > sample_state.max_budget_bytes) return error.InvalidProfileConfig;
        if (self.user_stack_bytes != 0 and (self.user_stack_bytes < 64 or self.user_stack_bytes > records.max_user_stack or self.user_stack_bytes % 8 != 0)) return error.InvalidProfileConfig;
        if (self.frequency_hz == 0 or self.frequency_hz > 1000 or self.tids.len > perf.max_threads) return error.InvalidProfileConfig;
    }
};
pub const ScopeChange = struct { pid: u32, tid: u32, parent_pid: u32, parent_tid: u32, time_ns: ?u64 };
pub const Thread = struct {
    debugger_id: u64,
    perf: perf.ThreadInfo,
    /// Null denotes an opening thread; otherwise enrollment began at this
    /// monotonic time while ptrace still held the newborn before user code.
    enrolled_ns: ?u64 = null,
};
pub const Filter = timeline.Filter;
pub const annotations = @import("annotations.zig");
pub const CacheKey = annotations.Key;
pub const Stop = enum { collecting, manual, duration, capacity, mapping_limit, mappings_changed, metadata_lost, thread_scope_changed, decode_error, target_ended, image_changed, drain_limit, collector_error, scheduling_limit, scheduling_error, syscall_limit, syscall_error };
pub const Opened = union(enum) { capture: *Capture, failed: perf.Failure };
pub const Capture = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    offline: bool = false,
    reanalyzed: bool = false,
    offline_graph: ?flame.Graph = null,
    offline_graph_filter: Filter = .{},
    offline_graph_budget: ?*@import("archive_budget.zig").Budget = null,
    archive_busy: bool = false,
    boot_id: ?[36]u8 = null,
    recorded: std.AutoHashMapUnmanaged(CacheKey, annotations.Record) = .empty,
    work_cancel: ?*const std.atomic.Value(bool) = null,
    id: u64,
    session_id: u64,
    generation: u64,
    image_epoch: u64,
    pid: i32,
    started_ns: u64,
    ended_ns: ?u64 = null,
    observed_until_ns: u64 = 0,
    debugger_markers: std.ArrayList(timeline.Marker) = .empty,
    debugger_marker_dropped: u64 = 0,
    debugger_events_lost: u64 = 0,
    debugger_sequence: u64 = 0,
    config: Config,
    accepted: perf.Acceptance,
    threads: [perf.max_threads]Thread = undefined,
    thread_count: usize,
    collector: ?*perf.Collector,
    syscall_collector: ?*syscall_perf.Collector = null,
    syscalls: syscall_model.Store = .{},
    thread_names: [perf.max_threads][32]u8 = undefined,
    cpu_before: [perf.max_threads]?activity.Ticks = @splat(null),
    cpu_activity: ?activity.Summary = null,
    images: modules.Modules,
    history: mappings.History = .{},
    mapping_revision: u64 = 0,
    samples: sample_store.Store = .{ .max_samples = max_samples },
    sample_storage_full: bool = false,
    user_state: sample_state.Store = .{},
    switches: scheduling.Store = .{},
    application_intervals: intervals.Store = .{},
    cache: std.AutoHashMapUnmanaged(CacheKey, flame.Frame) = .empty,
    revision: u64 = 1,
    status: Stop = .collecting,
    // Unique exceptional conditions, in observation order (rings are not
    // globally time ordered). The first remains the primary stop reason.
    stop_reasons: [@typeInfo(Stop).@"enum".field_names.len]Stop = undefined,
    stop_reason_count: usize = 0,
    failure: ?perf.Failure = null,
    diagnostic: []const u8 = "",
    lost_records: u64 = 0,
    lost_samples: u64 = 0,
    throttles: u64 = 0,
    unthrottles: u64 = 0,
    mapping_events: u64 = 0,
    exec_events: u64 = 0,
    exit_events: u64 = 0,
    fork_events: u64 = 0,
    scope_change: ?ScopeChange = null,
    unknown_records: u64 = 0,
    discarded_samples: u64 = 0,
    missing_images: u64 = 0,
    unselected_threads: usize = 0,
    // Samples after this time retain raw addresses only. Loss can hide an
    // earlier mapping event, so loss conservatively invalidates all symbols.
    trusted_before_ns: u64 = std.math.maxInt(u64),

    pub fn open(a: std.mem.Allocator, id: u64, session_id: u64, generation: u64, image_epoch: u64, pid: i32, map_tid: i32, config: Config, debugger_ids: []const u64, started_ns: u64) !Opened {
        try config.validate();
        if (config.tids.len == 0 or config.tids.len != debugger_ids.len) return error.InvalidProfileConfig;
        var images = modules.Modules.init(a);
        images.immutable = true;
        errdefer images.deinit();
        try images.refresh(map_tid);
        if (images.regions.items.len > 16384) return error.ProfileMapLimit;
        images.pid = pid;
        var history = mappings.History{};
        errdefer history.deinit(a);
        var missing: u64 = 0;
        for (images.regions.items) |region| {
            const entry = prepareMapping(&images, region);
            if (entry.reason == .image_unavailable or entry.reason == .image_limit) missing += 1;
            try history.opening(a, entry);
        }
        const self = try a.create(Capture);
        errdefer a.destroy(self);
        var user_state = if (config.user_stack_bytes != 0) try sample_state.Store.init(a, config.sample_limit, config.user_stack_budget_bytes) else sample_state.Store{};
        errdefer user_state.deinit(a);
        const syscall_ring_bytes = if (config.syscall_timing) syscall_perf.ringBytes(config.tids.len) else 0;
        if (syscall_ring_bytes >= config.ring_budget_bytes) return error.SyscallRingBudget;
        const opened = try perf.start(a, .{ .tids = config.tids, .frequency_hz = config.frequency_hz, .max_frames = 64, .mmap_data = true, .data_pages = ringPages(config.tids.len), .ring_budget_bytes = config.ring_budget_bytes - syscall_ring_bytes, .max_sides = perf.max_sides_cap, .context_switch = config.context_switch, .user_regs_mask = if (config.user_stack_bytes != 0) records.user_regs_gpr_mask else 0, .user_stack_bytes = config.user_stack_bytes });
        switch (opened) {
            .failed => |failure| {
                user_state.deinit(a);
                images.deinit();
                history.deinit(a);
                a.destroy(self);
                return .{ .failed = failure };
            },
            .collector => |collector| {
                errdefer collector.close();
                var syscall_collector: ?*syscall_perf.Collector = null;
                if (config.syscall_timing) switch (try syscall_perf.start(a, pid, config.tids)) {
                    .collector => |opened_syscalls| syscall_collector = opened_syscalls,
                    .failed => |failure| {
                        var full = failure;
                        full.opened_then_closed += @intCast(config.tids.len);
                        collector.close();
                        user_state.deinit(a);
                        images.deinit();
                        history.deinit(a);
                        a.destroy(self);
                        return .{ .failed = full };
                    },
                };
                self.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = id, .session_id = session_id, .generation = generation, .image_epoch = image_epoch, .pid = pid, .boot_id = @import("../binary/snapshot.zig").bootId(), .started_ns = started_ns, .config = .{ .sample_limit = config.sample_limit, .follow_threads = config.follow_threads, .ring_budget_bytes = config.ring_budget_bytes, .frequency_hz = config.frequency_hz, .duration_ms = config.duration_ms, .context_switch = config.context_switch, .syscall_timing = config.syscall_timing, .syscall_limit = config.syscall_limit, .user_stack_bytes = config.user_stack_bytes, .user_stack_budget_bytes = if (config.user_stack_bytes == 0) 0 else config.user_stack_budget_bytes }, .samples = .{ .max_samples = config.sample_limit }, .user_state = user_state, .accepted = collector.acceptance(), .thread_count = config.tids.len, .collector = collector, .syscall_collector = syscall_collector, .syscalls = .{ .enabled = config.syscall_timing, .limit = config.syscall_limit }, .images = images, .history = history, .missing_images = missing };
                for (debugger_ids, 0..) |debugger_id, i| {
                    self.threads[i] = .{ .debugger_id = debugger_id, .perf = collector.thread(i).? };
                    self.cpu_before[i] = activity.read(pid, config.tids[i]);
                    _ = std.fmt.bufPrintSentinel(&self.thread_names[i], "Thread {d}", .{config.tids[i]}, 0) catch unreachable;
                }
                return .{ .capture = self };
            },
        }
    }
    /// Called only for a verified same-process newborn held by ptrace.
    pub fn enroll(self: *Capture, tid: i32, debugger_id: u64, now: u64) void {
        const collector = self.collector orelse return;
        if (!self.config.follow_threads or self.status != .collecting) return;
        // Release drained retired rings before applying the admission budget.
        self.drainSyscalls(4);
        self.drain(4);
        if (self.status != .collecting) {
            self.stop(self.status, now);
            return;
        }
        if (collector.addThread(tid)) |failure| {
            self.enrollmentFailed(failure, now);
            return;
        }
        const i = self.thread_count;
        self.threads[i] = .{ .debugger_id = debugger_id, .perf = collector.thread(i).?, .enrolled_ns = now };
        self.cpu_before[i] = activity.read(self.pid, tid);
        _ = std.fmt.bufPrintSentinel(&self.thread_names[i], "Thread {d}", .{tid}, 0) catch unreachable;
        self.thread_count += 1;
        self.accepted.threads = @intCast(self.thread_count);
        self.revision += 1;
    }
    pub fn enrollmentFailed(self: *Capture, failure: perf.Failure, now: u64) void {
        if (self.collector == null) return;
        self.failure = failure;
        self.trusted_before_ns = @min(self.trusted_before_ns, now);
        self.noteStop(.collector_error, failure.detail);
        self.stop(.collector_error, now);
    }
    pub fn retireThread(self: *Capture, index: usize, now: u64) void {
        const collector = self.collector orelse return;
        if (collector.retireThread(index)) |failure| self.enrollmentFailed(failure, now);
    }
    pub fn openingThreads(self: *const Capture) usize {
        var count: usize = 0;
        for (self.threads[0..self.thread_count]) |thread| if (thread.enrolled_ns == null) {
            count += 1;
        };
        return count;
    }
    pub fn clearOfflineGraph(self: *Capture) void {
        if (self.offline_graph) |*graph_| graph_.deinit();
        self.offline_graph = null;
        if (self.offline_graph_budget) |budget| budget.backing.destroy(budget);
        self.offline_graph_budget = null;
    }
    pub fn deinit(self: *Capture) void {
        self.clearOfflineGraph();
        if (self.collector) |collector| collector.close();
        if (self.syscall_collector) |collector| collector.close();
        self.syscalls.deinit(self.allocator);
        self.samples.deinit(self.allocator);
        self.user_state.deinit(self.allocator);
        self.switches.deinit(self.allocator);
        self.application_intervals.deinit(self.allocator);
        self.debugger_markers.deinit(self.allocator);
        self.recorded.deinit(self.allocator);
        self.cache.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.images.deinit();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn drainSyscalls(self: *Capture, passes: usize) void {
        const collector = self.syscall_collector orelse return;
        if (self.hasStop(.syscall_error) or self.hasStop(.syscall_limit)) return;
        const before = self.syscalls.items.items.len;
        defer {
            if (self.syscalls.items.items.len != before) self.revision += 1;
        }
        for (0..passes) |_| {
            const more = collector.drain(&self.syscalls) catch |err| {
                self.syscalls.unread_possible = true;
                self.noteStop(if (err == error.SyscallLimit) .syscall_limit else .syscall_error, @errorName(err));
                self.revision += 1;
                return;
            };
            if (collector.image_changed) self.noteStop(.image_changed, "syscall trace observed exec; later image records excluded");
            if (!more) return;
        }
        if (passes == 128) {
            self.syscalls.unread_possible = true;
            self.noteStop(.syscall_error, "syscall final drain limit reached");
        }
    }
    pub const SyscallSummary = struct {
        enabled: bool,
        retained: usize,
        limit: u32,
        lost: u64,
        throttles: u64,
        discarded: u64,
        invalid: u64,
        finished: bool,
        unread_possible: bool,
        discarded_basis: []const u8 = "decoded spans rejected by storage; unread ring records are not counted",
        number_abi: []const u8 = "x86-64 assumed from the supported target; raw tracepoints do not distinguish int 0x80 compatibility calls; such names require separate ABI confirmation",
        scope: []const u8 = "fixed explicitly selected x86-64 threads; no inherited children; syscall arguments are discarded",
        basis: []const u8 = "entry/exit CLOCK_MONOTONIC elapsed time, including off-CPU and debugger stops; scheduling overlap is observed context, not a wait cause",
    };
    pub fn syscallSummary(self: *const Capture) SyscallSummary {
        const calls = &self.syscalls;
        return .{ .enabled = calls.enabled, .retained = calls.items.items.len, .limit = calls.limit, .lost = calls.lost, .throttles = calls.throttles, .discarded = calls.discarded, .invalid = calls.invalid, .finished = calls.finished, .unread_possible = calls.unread_possible };
    }
    fn firstSkippedSample(self: *const Capture) ?usize {
        const entry = self.user_state.first_skipped orelse return null;
        for (0..self.samples.len()) |ordinal| if (self.samples.core(ordinal).user_state == entry + 1) return ordinal;
        return null;
    }
    pub fn summary(self: *const Capture) Summary {
        return .{ .follow_threads = self.config.follow_threads, .ring_budget_bytes = if (self.config.ring_budget_bytes == 0) null else self.config.ring_budget_bytes, .ring_allocated_bytes = (if (self.collector) |collector| collector.allocated_ring_bytes else 0) + (if (self.syscall_collector != null) syscall_perf.ringBytes(self.thread_count) else 0), .opening_threads = self.openingThreads(), .scope = if (self.config.follow_threads) "all threads in this process, including held newborns; user CPU only; child processes remain outside scope" else "fixed selected threads, user CPU only; new tasks stop collection; a subset leaves mappings unverified", .id = self.id, .session_id = self.session_id, .opening_generation = self.generation, .image_epoch = self.image_epoch, .pid = self.pid, .revision = self.revision, .status = self.status, .stop_reasons = self.stop_reasons[0..self.stop_reason_count], .started_ns = self.started_ns, .ended_ns = self.ended_ns, .duration_ms = self.config.duration_ms, .accepted = self.accepted, .threads = self.threads[0..self.thread_count], .sampled_state = .{ .requested_bytes = self.config.user_stack_bytes, .budget_bytes = self.config.user_stack_budget_bytes, .retained_bytes = self.user_state.used, .records = self.user_state.count, .skipped_stacks = self.user_state.skipped, .first_skipped_sample = self.firstSkippedSample(), .allocated_bytes = self.user_state.allocationBytes() }, .stored_samples = self.samples.len(), .sample_limit = self.config.sample_limit, .discarded_samples = self.discarded_samples, .lost_records = self.lost_records, .lost_samples = self.lost_samples, .throttles = self.throttles, .unthrottles = self.unthrottles, .mapping_events = self.mapping_events, .exec_events = self.exec_events, .exit_events = self.exit_events, .fork_events = self.fork_events, .scope_change = self.scope_change, .unknown_records = self.unknown_records, .unselected_threads = self.unselected_threads, .missing_images = self.missing_images, .trusted_before_ns = if (self.trusted_before_ns == std.math.maxInt(u64)) null else self.trusted_before_ns, .failure = self.failure, .diagnostic = self.diagnostic, .cpu_activity = self.cpu_activity, .scheduling = self.schedulingSummary(), .syscalls = self.syscallSummary(), .application_intervals = self.application_intervals.items.items.len, .mapping_revision = self.mapping_revision, .mapping_history = .{ .opening_regions = self.history.opening_count, .recorded_changes = self.history.changes.items.len, .unresolved_executable_mappings = self.unresolvedMappings(), .opened_images = self.images.loaded.items.len, .snapshot_bytes = self.images.snapshot_bytes } };
    }
    pub fn poll(self: *Capture, now: u64) void {
        if (self.collector == null) return;
        if (now -| @max(self.started_ns, self.observed_until_ns) >= 250_000_000) {
            self.observed_until_ns = now;
            self.revision += 1;
        }
        self.drainSyscalls(4);
        self.drain(4);
        if (self.status != .collecting) {
            self.stop(self.status, now);
        } else if (self.config.duration_ms != 0 and now -| self.started_ns >= @as(u64, self.config.duration_ms) * 1_000_000) self.stop(.duration, now);
    }
    pub fn stop(self: *Capture, reason: Stop, now: u64) void {
        const collector = self.collector orelse return;
        self.noteStop(reason, "");
        self.ended_ns = now;
        self.revision += 1;
        if (self.syscall_collector) |trace| {
            if (trace.stop()) |failure| {
                self.failure = failure;
                self.noteStop(.syscall_error, failure.detail);
            }
            self.drainSyscalls(128);
            self.syscalls.finish(self.allocator, if (trace.image_changed) .exec else if (self.hasStop(.syscall_error)) .decode_error else if (self.hasStop(.syscall_limit)) .truncated else .missing_exit) catch |err| self.noteStop(.syscall_limit, @errorName(err));
            trace.close();
            self.syscall_collector = null;
        }
        if (collector.stop()) |failure| {
            self.failure = failure;
            self.noteStop(.collector_error, failure.detail);
            self.trusted_before_ns = 0;
        } else self.drain(128);
        collector.close();
        self.collector = null;
        if (self.diagnostic.len == 0) self.diagnostic = switch (self.status) {
            .duration => "configured capture duration reached (wall clock, including time stopped)",
            .target_ended => "target exited or detached",
            .thread_scope_changed => "new task outside the capture scope; pause and start a new capture to include current threads",
            .mappings_changed, .image_changed => "target executed a different image; start a new capture for that image",
            .mapping_limit => "mapping history reached its record limit",
            .metadata_lost => "mapping metadata incomplete; stored samples retained as raw addresses",
            .capacity => "sample storage limit reached",
            .scheduling_limit => "scheduling history limit reached; retained prefix kept, discarded suffix is unknown",
            .syscall_limit => "syscall detail limit reached; retained prefix kept, unfinished durations are unknown",
            else => "",
        };
        var totals = activity.Totals{};
        for (self.threads[0..self.thread_count], 0..) |thread, i| totals.add(self.cpu_before[i], activity.read(self.pid, thread.perf.tid));
        self.cpu_activity = totals.summary(activity.ticksPerSecond());
        self.reportStop();
    }
    fn reportStop(self: *const Capture) void {
        switch (self.status) {
            .collecting, .manual => return,
            else => {},
        }
        @import("../m68k_log.zig").print("xodb: profile #{d} stopped: {s}; pid={d} elapsed_ms={d} duration_limit_ms={d} samples={d} sample_limit={d} threads={d} mappings={d} lost={d} unknown={d} ring_bytes={d}; {s}\n", .{ self.id, @tagName(self.status), self.pid, (self.ended_ns.? -| self.started_ns) / 1_000_000, self.config.duration_ms, self.samples.len(), self.config.sample_limit, self.thread_count, self.mapping_events, self.lost_samples, self.unknown_records, self.accepted.ring_data_bytes, self.diagnostic });
        if (self.stop_reason_count > 1) {
            @import("../m68k_log.zig").print("xodb: profile #{d} additional stop conditions:", .{self.id});
            for (self.stop_reasons[1..self.stop_reason_count]) |reason| @import("../m68k_log.zig").print(" {s}", .{@tagName(reason)});
            @import("../m68k_log.zig").print("\n", .{});
        }
        if (self.syscalls.enabled) @import("../m68k_log.zig").print("xodb: profile #{d} syscalls: retained={d} lost={d} throttles={d} discarded={d} invalid={d}\n", .{ self.id, self.syscalls.items.items.len, self.syscalls.lost, self.syscalls.throttles, self.syscalls.discarded, self.syscalls.invalid });
        if (self.config.context_switch) @import("../m68k_log.zig").print("xodb: profile #{d} scheduling: retained={d} discarded={d} invalid={d} storage_bytes={d}\n", .{ self.id, self.switches.retained, self.switches.discarded, self.switches.invalid, self.switches.storageBytes() });
        if (self.scope_change) |change| @import("../m68k_log.zig").print("xodb: profile #{d} task creation: pid={d} tid={d} parent_pid={d} parent_tid={d} same_process={}\n", .{ self.id, change.pid, change.tid, change.parent_pid, change.parent_tid, change.pid == self.pid });
        if (self.failure) |failure| @import("../m68k_log.zig").print("xodb: profile #{d} collector failure: {s} syscall={s} errno={d} tid={d}; {s}\n", .{ self.id, @tagName(failure.kind), failure.syscall, failure.errno, failure.tid, failure.detail });
    }
    /// Publish the compact sample first, then attach its owned raw state. A
    /// refused sample must not leave an orphan in the separately bounded store.
    fn retainSamples(self: *Capture, samples: []const records.Sample, states: []const records.UserState, stack: []const u8) void {
        if (self.sample_storage_full) {
            self.discarded_samples += samples.len;
            return;
        }
        for (samples, 0..) |incoming, i| {
            const ordinal = self.samples.len();
            var sample = incoming;
            sample.user_state = 0;
            self.samples.append(self.allocator, sample) catch |err| {
                self.sample_storage_full = true;
                self.discarded_samples += samples.len - i;
                self.noteStop(.capacity, switch (err) {
                    error.SampleLimit => "sample storage limit reached",
                    error.SampleBudget => "sample memory budget reached",
                    else => "sample storage allocation failed",
                });
                break;
            };
            if (self.config.user_stack_bytes == 0) continue;
            if (incoming.user_state == 0 or incoming.user_state > states.len) {
                self.noteStop(.decode_error, "sample user-state index is invalid");
                continue;
            }
            const was_exhausted = self.user_state.exhausted;
            self.samples.coreMut(ordinal).user_state = self.user_state.append(states[incoming.user_state - 1], stack) catch {
                self.noteStop(.decode_error, "sample user-state bounds are invalid");
                continue;
            };
            if (!was_exhausted and self.user_state.exhausted) @import("../m68k_log.zig").print("xodb: profile #{d} stack retention budget reached: used={d} budget={d} first_missing_sample={d}; CPU sampling continues, later stack dumps are not retained; collection overhead continues\n", .{ self.id, self.user_state.used, self.config.user_stack_budget_bytes, self.firstSkippedSample().? });
        }
        if (self.samples.len() == self.samples.max_samples) self.noteStop(.capacity, "sample storage limit reached");
    }
    fn drain(self: *Capture, passes: usize) void {
        const collector = self.collector orelse return;
        for (0..passes) |_| {
            const data = collector.drain();
            if (data.samples.len > 0 or data.sides.len > 0 or data.skipped_unknown > 0) self.revision += 1;
            for (data.sides) |event| self.side(event);
            self.unknown_records += data.skipped_unknown;
            if (data.skipped_unknown > 0) {
                self.trusted_before_ns = 0;
                self.noteStop(.metadata_lost, "unknown perf record; mapping history may be incomplete");
            }
            self.retainSamples(data.samples, data.user_states, data.user_stack);
            switch (data.status) {
                .ok => return,
                .capacity => {}, // drain again, including later thread rings
                else => {
                    self.noteStop(.decode_error, data.reason);
                    self.trusted_before_ns = 0;
                    self.revision += 1;
                    return;
                },
            }
        }
        if (passes == 128) {
            self.noteStop(.drain_limit, "final drain limit reached; unread records remain");
            self.trusted_before_ns = 0;
        }
    }
    fn side(self: *Capture, event: records.Side) void {
        switch (event.kind) {
            .lost, .lost_samples => {
                self.lost_records += 1;
                self.lost_samples +|= event.lost_count;
                self.noteStop(.metadata_lost, if (event.kind == .lost) "perf ring overflow; lost records may include mapping changes" else "perf reported lost samples; mapping history may be incomplete");
                self.trusted_before_ns = 0;
            },
            .mmap => {
                self.mapping_events += 1;
                self.recordMapping(event) catch |err| {
                    self.trusted_before_ns = 0;
                    self.noteStop(if (err == error.MappingHistoryLimit) .mapping_limit else .metadata_lost, @errorName(err));
                };
            },
            .comm => if (event.exec) {
                self.exec_events += 1;
                self.trusted_before_ns = @min(self.trusted_before_ns, if (event.time_present) event.time_ns else 0);
                self.noteStop(.mappings_changed, "target executed a different image; start a new capture for that image");
            },
            .throttle => self.throttles += 1,
            .unthrottle => self.unthrottles += 1,
            .exit => self.exit_events += 1,
            .fork => {
                self.fork_events += 1;
                // A parent's ring may report this before the child stop is
                // observed. TRACECLONE holds the newborn until our enrollment
                // callback; the live fallback excludes only pending newborns.
                if (self.config.follow_threads and event.pid == self.pid and event.ppid == self.pid and event.tid > 0 and event.time_present) return;
                if (self.scope_change == null) self.scope_change = .{ .pid = event.pid, .tid = event.tid, .parent_pid = event.ppid, .parent_tid = event.ptid, .time_ns = if (event.time_present) event.time_ns else null };
                self.trusted_before_ns = @min(self.trusted_before_ns, if (event.time_present) event.time_ns else 0);
                self.noteStop(.thread_scope_changed, if (event.pid == self.pid)
                    "new thread outside the opening set; pause and start a new capture to include current threads"
                else
                    "child process created outside the opening set; capture stopped at the scope boundary");
            },
            .context_switch => self.recordSwitch(event),
            .unknown => {},
        }
    }
    fn recordSwitch(self: *Capture, event: records.Side) void {
        const index = if (event.tid <= std.math.maxInt(i32)) self.threadIndex(@intCast(event.tid)) else null;
        if (!self.config.context_switch or event.raw_type != records.Type.context_switch or !event.task_present or !event.time_present or event.time_ns < self.started_ns or event.pid != self.pid or index == null) {
            self.switches.invalid +|= 1;
            self.noteStop(.scheduling_error, "scheduling record has invalid time, task identity or event kind");
            return;
        }
        self.switches.add(self.allocator, index.?, .{ .offset_ns = event.time_ns - self.started_ns, .direction = if (event.switch_out) .switch_out else .switch_in, .preempted = event.preempt_present and event.preempted }) catch |err| {
            self.noteStop(if (err == error.ContradictoryScheduling) .scheduling_error else .scheduling_limit, @errorName(err));
        };
    }
    fn exceptional(reason: Stop) bool {
        return switch (reason) {
            .collecting, .manual, .duration, .target_ended => false,
            else => true,
        };
    }
    pub fn hasStop(self: *const Capture, reason: Stop) bool {
        return self.status == reason or std.mem.indexOfScalar(Stop, self.stop_reasons[0..self.stop_reason_count], reason) != null;
    }
    fn noteStop(self: *Capture, reason: Stop, diagnostic: []const u8) void {
        if (exceptional(reason) and std.mem.indexOfScalar(Stop, self.stop_reasons[0..self.stop_reason_count], reason) == null) {
            self.stop_reasons[self.stop_reason_count] = reason;
            self.stop_reason_count += 1;
        }
        if (!exceptional(self.status)) {
            self.status = reason;
            if (exceptional(reason) or diagnostic.len > 0) self.diagnostic = diagnostic;
        }
    }
    pub fn threadIndex(self: *const Capture, tid: i32) ?usize {
        for (self.threads[0..self.thread_count], 0..) |thread, i| if (thread.perf.tid == tid) return i;
        return null;
    }
    pub fn schedulingCoverage(self: *const Capture) timeline.Coverage {
        if (!self.config.context_switch) return .disabled;
        if (self.switches.invalid > 0) return .invalid_identity;
        if (self.lost_records > 0 or self.lost_samples > 0) return .lost;
        if (self.unknown_records > 0 or self.throttles > 0 or self.hasStop(.decode_error) or self.hasStop(.drain_limit) or self.hasStop(.collector_error) or self.hasStop(.metadata_lost)) return .incomplete;
        return .available;
    }
    pub const SchedulingSummary = struct {
        status: enum { disabled, available, partial },
        coverage: timeline.Coverage,
        recorded_events: usize,
        discarded_events: u64,
        invalid_events: u64,
        contradictory_lanes: usize,
        storage_bytes: usize,
        event_limit: usize = scheduling.max_events,
        per_thread_limit: usize = scheduling.max_lane_events,
        basis: []const u8 = "paired per-task switch records; unmatched endpoints and missing evidence stay unknown; preemption is a transition, not a wait cause",
    };
    pub fn schedulingSummary(self: *const Capture) SchedulingSummary {
        const coverage = self.schedulingCoverage();
        var contradictory: usize = 0;
        for (self.switches.lanes[0..self.thread_count]) |lane| if (lane.contradictory) {
            contradictory += 1;
        };
        return .{ .status = if (coverage == .disabled) .disabled else if (coverage != .available or self.switches.discarded > 0 or contradictory > 0) .partial else .available, .coverage = coverage, .recorded_events = self.switches.retained, .discarded_events = self.switches.discarded, .invalid_events = self.switches.invalid, .contradictory_lanes = contradictory, .storage_bytes = self.switches.storageBytes() };
    }
    pub const SyscallRow = struct {
        ordinal: usize,
        thread: Thread,
        nr: i64,
        name: ?[]const u8,
        exit_nr: ?i64,
        entry_ns: ?u64,
        exit_ns: ?u64,
        elapsed_ns: ?u64,
        result: ?i64,
        return_class: ?syscall_model.ReturnClass,
        reason: syscall_model.Reason,
        scheduling_overlap: ?scheduling.Totals,
    };
    pub const SyscallPage = struct { rows: []SyscallRow, total: usize, next: ?usize };
    pub fn syscallPage(self: *const Capture, a: std.mem.Allocator, filter: Filter, start: usize, limit: usize) !SyscallPage {
        try self.validateFilter(filter);
        if (limit == 0 or limit > 128) return error.InvalidArguments;
        var rows: std.ArrayList(SyscallRow) = .empty;
        errdefer rows.deinit(a);
        var schedules: [syscall_model.max_threads]?[]timeline.Span = @splat(null);
        defer for (schedules) |spans| if (spans) |v| a.free(v);
        var total: usize = 0;
        for (self.syscalls.items.items, 0..) |span, ordinal| {
            if (span.thread_index >= self.thread_count) return error.InvalidSyscallIdentity;
            const thread = self.threads[span.thread_index];
            if (!filter.matchesThread(@intCast(thread.perf.tid)) or !span.overlaps(self.started_ns +| filter.from_ns, self.started_ns +| filter.to_ns)) continue;
            total += 1;
            if (total <= start or rows.items.len >= limit) continue;
            var overlap: ?scheduling.Totals = null;
            if (span.elapsed()) |elapsed| {
                overlap = .{ .unknown_ns = elapsed };
                if (schedules[span.thread_index] == null) schedules[span.thread_index] = try self.schedulingSpans(a, span.thread_index, .{ .from_ns = 0, .to_ns = self.extentNs() });
                const spans = schedules[span.thread_index].?;
                const from = span.entry_ns.? -| self.started_ns;
                const to = span.exit_ns.? -| self.started_ns;
                var lo: usize = 0;
                var hi = spans.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (spans[mid].to_ns <= from) lo = mid + 1 else hi = mid;
                }
                for (spans[lo..]) |schedule| {
                    if (schedule.from_ns >= to) break;
                    const duration = @min(to, schedule.to_ns) -| @max(from, schedule.from_ns);
                    switch (schedule.state) {
                        .running => {
                            overlap.?.running_ns += duration;
                            overlap.?.unknown_ns -|= duration;
                        },
                        .off_cpu => {
                            overlap.?.off_cpu_ns += duration;
                            overlap.?.unknown_ns -|= duration;
                        },
                        .unknown => {},
                    }
                }
            }
            try rows.append(a, .{ .ordinal = ordinal, .thread = thread, .nr = span.nr, .name = syscall_model.name(span.nr), .exit_nr = span.exit_nr, .entry_ns = span.entry_ns, .exit_ns = span.exit_ns, .elapsed_ns = span.elapsed(), .result = span.result, .return_class = if (span.result) |v| syscall_model.returnClass(v) else null, .reason = span.reason, .scheduling_overlap = overlap });
        }
        if (start > total) return error.InvalidArguments;
        const end = start + rows.items.len;
        return .{ .rows = try rows.toOwnedSlice(a), .total = total, .next = if (end < total) end else null };
    }
    pub fn schedulingSpans(self: *const Capture, a: std.mem.Allocator, index: usize, range: timeline.Range) ![]timeline.Span {
        if (index >= self.thread_count) return error.UnknownProfileThread;
        return self.switches.spans(a, index, self.extentNs(), range, self.schedulingCoverage());
    }
    pub fn addIntervals(self: *Capture, origin: []const u8, batch: []const intervals.Input) !void {
        if (self.offline) return error.ArchiveImmutable;
        if (self.archive_busy) return error.ArchiveBusy;
        if (self.collector != null) return error.ProfileStillCollecting;
        for (batch) |input| if (input.tid) |tid| {
            if (tid > std.math.maxInt(i32) or self.threadIndex(@intCast(tid)) == null) return error.UnknownProfileThread;
        };
        try self.application_intervals.add(self.allocator, origin, batch, self.extentNs());
        self.revision += 1;
    }
    pub fn includesThread(self: *const Capture, tid: i32) bool {
        for (self.threads[0..self.thread_count]) |thread| if (thread.perf.tid == tid) return true;
        return false;
    }
    fn prepareMapping(images: *modules.Modules, region: modules.Region) mappings.Mapping {
        var entry = mappings.Mapping{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = region.path, .executable = region.permissions[2] == 'x' };
        if (!entry.executable) {
            entry.reason = .non_executable;
        } else if (region.inode == 0 or region.path.len == 0 or region.path[0] != '/') {
            entry.reason = .anonymous;
        } else if (images.loaded.items.len == 256) {
            entry.reason = .image_limit;
        } else if (images.loadObserved(region)) |image| {
            entry.image_id = image.id;
            entry.reason = .elf;
        } else |err| entry.reason = if (err == error.BinarySnapshotLimit) .image_limit else .image_unavailable;
        return entry;
    }
    fn recordMapping(self: *Capture, event: records.Side) !void {
        if (!event.time_present or event.time_ns == 0 or event.maps_parse_timeout or event.pid != self.pid or event.length == 0) return error.InvalidMappingRecord;
        const end = std.math.add(u64, event.address, event.length) catch return error.InvalidMappingRecord;
        if (self.history.changes.items.len == mappings.max_changes) return error.MappingHistoryLimit;
        // Even an unusable image replaces the previous ownership of this range.
        // Record its identity before assigning any symbol to later samples.
        const path = try self.arena.allocator().dupe(u8, event.path[0..event.path_len]);
        var region = modules.Region{ .start = event.address, .end = end, .offset = event.page_offset, .inode = event.inode, .device_major = event.major, .device_minor = event.minor, .permissions = "---p".*, .path = path };
        if (event.prot & 1 != 0) region.permissions[0] = 'r';
        if (event.prot & 2 != 0) region.permissions[1] = 'w';
        if (event.prot & 4 != 0) region.permissions[2] = 'x';
        var entry: mappings.Mapping = undefined;
        if (event.raw_type != records.Type.mmap2 or event.build_id or event.path_truncated) {
            entry = .{ .start = region.start, .end = region.end, .offset = region.offset, .path = path, .executable = event.prot & 4 != 0 or event.raw_type == records.Type.mmap, .reason = if (event.path_truncated) .truncated_path else .unsupported_record };
        } else entry = prepareMapping(&self.images, region);
        const before = self.history.changes.items.len;
        _ = try self.history.add(self.allocator, event.time_ns, entry);
        if (self.history.changes.items.len != before) {
            self.mapping_revision += 1;
            if (entry.reason == .image_unavailable or entry.reason == .image_limit) self.missing_images += 1;
        }
    }
    fn unresolvedMappings(self: *const Capture) usize {
        var count: usize = 0;
        for (self.history.entries.items) |entry| if (entry.executable and entry.image_id == 0) {
            count += 1;
        };
        return count;
    }
    fn imageById(self: *Capture, id: u64) ?*modules.Module {
        for (self.images.loaded.items) |image| if (image.id == id) return image;
        return null;
    }
    fn frame(self: *Capture, address: u64, trusted: bool, found: ?mappings.Found) !flame.Frame {
        const mapping_id: u32 = if (trusted and found != null) found.?.mapping.id else 0;
        const ambiguous = trusted and found != null and found.?.ambiguous;
        const key = CacheKey{ .address = address, .mapping_id = mapping_id, .trusted = trusted, .ambiguous = ambiguous };
        if (self.offline) {
            if (self.recorded.get(key)) |record| return record.frame;
            return .{ .kind = .unknown, .mapping_id = mapping_id, .address = address, .lookup_address = address, .name = "[annotation limit / unavailable]", .mapping_note = "no recorded annotation" };
        }
        if (self.cache.get(key)) |cached| return cached;
        if (self.cache.count() == max_frames_cached) return .{ .kind = .unknown, .mapping_id = mapping_id, .address = address, .lookup_address = address, .name = "[symbol cache limit]" };
        const a = self.arena.allocator();
        const note = if (!trusted) "mapping metadata incomplete" else if (ambiguous) "ambiguous mapping timestamp" else if (found) |match| @tagName(match.mapping.reason) else "no observed mapping";
        var result = flame.Frame{ .kind = if (trusted and !ambiguous) .unknown else .unverified, .mapping_id = mapping_id, .mapping_note = note, .address = address, .lookup_address = address, .name = try std.fmt.allocPrint(a, "{s}0x{x}", .{ if (trusted and !ambiguous) "" else "[unverified] ", address }) };
        if (trusted and !ambiguous) if (found) |match| {
            result.module = match.mapping.path;
            if (match.mapping.executable) if (self.imageById(match.mapping.image_id)) |image| {
                result.module_id = image.id;
                if (image.image.symbolAt(try image.linkAddress(address))) |symbol| {
                    result.kind = .code;
                    result.address = try image.runtimeAddress(symbol.symbol.value);
                    result.name = symbol.symbol.name[0..@min(256, symbol.symbol.name.len)];
                }
            };
        };
        try self.cache.put(self.allocator, key, result);
        return result;
    }
    pub fn matchesLive(self: *Capture, live: *modules.Modules, frame_: flame.Frame) bool {
        if (self.offline or frame_.kind != .code) return false;
        const captured = self.imageById(frame_.module_id) orelse return false;
        for (live.regions.items) |region| {
            if (frame_.lookup_address < region.start or frame_.lookup_address >= region.end) continue;
            if (region.permissions[2] != 'x' or region.inode != captured.inode or region.device_major != captured.device_major or region.device_minor != captured.device_minor) return false;
            if (region.offset < captured.file_offset) return false;
            var relative = region;
            relative.offset -= captured.file_offset;
            const bias = modules.Modules.observedBias(&captured.image, relative) catch return false;
            return bias == captured.bias;
        }
        return false;
    }
    pub fn source(self: *Capture, a: std.mem.Allocator, frame_: flame.Frame) !info.Site {
        if (self.offline) {
            var it = self.recorded.iterator();
            while (it.next()) |entry| if (entry.key_ptr.address == frame_.lookup_address and entry.key_ptr.mapping_id == frame_.mapping_id) {
                return entry.value_ptr.site orelse error.ProfileSourceNotRecorded;
            };
            return error.ProfileSourceNotRecorded;
        }
        if (frame_.kind != .code) return error.ProfileFrameUnavailable;
        const image = self.imageById(frame_.module_id) orelse return error.ProfileFrameUnavailable;
        return (try image.debugInfo()).siteAt(a, try image.linkAddress(frame_.lookup_address));
    }
    pub fn instructions(self: *Capture, a: std.mem.Allocator, frame_: flame.Frame) ![]@import("../model/disassembly.zig").Instruction {
        if (frame_.kind != .code) return error.ProfileFrameUnavailable;
        const image = self.imageById(frame_.module_id) orelse return error.ProfileFrameUnavailable;
        const link = try image.linkAddress(frame_.address);
        const offset = image.image.fileOffset(link) orelse return error.ProfileFrameUnavailable;
        if (frame_.lookup_address < frame_.address or frame_.lookup_address - frame_.address > 65536) return error.ProfileAssemblyLimit;
        const bytes = @min(image.mapping.len - offset, frame_.lookup_address - frame_.address + 128);
        const disasm = @import("../model/disassembly.zig");
        const decoded = try a.alloc(disasm.Instruction, 4096);
        const count = try disasm.decode(image.mapping[@intCast(offset)..][0..@intCast(bytes)], frame_.address, decoded);
        var first: usize = 0;
        for (decoded[0..count], 0..) |instruction, i| {
            if (instruction.address <= frame_.lookup_address) first = i;
        }
        if (count == 0 or decoded[first].address + decoded[first].size <= frame_.lookup_address) return error.ProfileAssemblyLimit;
        first -|= 2;
        return decoded[first..@min(count, first + 16)];
    }
    /// Extent is part of the capture revision, never recomputed from the clock
    /// during a query. A final drain can include a sample beyond stop-request time.
    pub fn extentNs(self: *const Capture) u64 {
        var extent = @max(@max(self.ended_ns orelse 0, self.observed_until_ns) -| self.started_ns, self.switches.extent_ns);
        extent = @max(extent, (self.syscalls.extent_ns -| self.started_ns) +| @intFromBool(self.syscalls.enabled));
        for (0..self.samples.len()) |i| {
            const sample = self.samples.core(i);
            if (sample.timePresent() and sample.time_ns >= self.started_ns) extent = @max(extent, (sample.time_ns - self.started_ns) +| 1);
        }
        for (self.debugger_markers.items) |marker| extent = @max(extent, marker.offset_ns +| 1);
        return extent;
    }
    pub fn addMarker(self: *Capture, marker: timeline.Marker) void {
        self.revision += 1;
        if (self.debugger_markers.items.len == timeline.max_markers) {
            self.debugger_marker_dropped +|= 1;
            return;
        }
        self.debugger_markers.append(self.allocator, marker) catch {
            self.debugger_marker_dropped +|= 1;
        };
    }
    pub fn validateFilter(self: *const Capture, filter: Filter) !void {
        try filter.validate();
        if (filter.tid) |tid| if (!self.includesThread(@intCast(tid))) return error.UnknownProfileThread;
        for (filter.tids.slice()) |tid| if (!self.includesThread(@intCast(tid))) return error.UnknownProfileThread;
    }
    fn sampleThread(self: *const Capture, sample: *const sample_store.Core) ?usize {
        if (!sample.timePresent() or sample.time_ns < self.started_ns or !sample.tidPresent()) return null;
        for (self.threads[0..self.thread_count], 0..) |thread, i| if (thread.perf.tid == sample.tid) return i;
        return null;
    }
    pub fn cpuTimeline(self: *const Capture, a: std.mem.Allocator, filter: Filter, bins: usize) !timeline.CpuTimeline {
        try self.validateFilter(filter);
        var histogram = try timeline.Histogram.init(a, filter.clipped(self.extentNs()), bins);
        errdefer histogram.deinit();
        var counts: [perf.max_threads]u64 = @splat(0);
        var invalid: u64 = 0;
        for (0..self.samples.len()) |ordinal| {
            const sample = self.samples.core(ordinal);
            const index = self.sampleThread(sample) orelse {
                invalid += 1;
                continue;
            };
            const offset = sample.time_ns - self.started_ns;
            if (!filter.contains(sample.tid, offset)) continue;
            histogram.add(offset);
            counts[index] += 1;
        }
        const lanes = try a.alloc(timeline.Lane, if (filter.threadCount() > 0) filter.threadCount() else self.thread_count);
        var next: usize = 0;
        for (self.threads[0..self.thread_count], 0..) |thread, i| {
            if (!filter.matchesThread(@intCast(thread.perf.tid))) continue;
            lanes[next] = .{ .tid = @intCast(thread.perf.tid), .debugger_id = thread.debugger_id, .enrolled_ns = thread.enrolled_ns, .samples = counts[i] };
            next += 1;
        }
        return .{ .histogram = histogram, .lanes = lanes, .invalid_samples = invalid };
    }
    pub fn graph(self: *Capture, a: std.mem.Allocator, filter: Filter) !flame.Graph {
        if (self.offline) {
            if (self.offline_graph) |*cached| if (std.meta.eql(filter, self.offline_graph_filter)) return cached.clone(a);
            return error.ArchiveViewPending;
        }
        return self.graphDirect(a, filter);
    }
    pub fn graphDirect(self: *Capture, a: std.mem.Allocator, filter: Filter) !flame.Graph {
        return self.graphWithCancel(a, filter, self.work_cancel);
    }
    pub fn graphWithCancel(self: *Capture, a: std.mem.Allocator, filter: Filter, cancellation: ?*const std.atomic.Value(bool)) !flame.Graph {
        try self.validateFilter(filter);
        var result = try flame.Graph.init(a);
        errdefer result.deinit();
        var cursor = try mappings.Cursor.init(a, &self.history);
        defer cursor.deinit();
        const order = try a.alloc(u32, self.samples.len());
        defer a.free(order);
        for (order, 0..) |*index, i| index.* = @intCast(i);
        std.mem.sort(u32, order, &self.samples, struct {
            fn less(samples: *const sample_store.Store, l: u32, r: u32) bool {
                const x = samples.core(l).time_ns;
                const y = samples.core(r).time_ns;
                return if (x == y) l < r else x < y;
            }
        }.less);
        for (order) |sample_index| {
            if (cancellation) |cancel| if (cancel.load(.acquire)) return error.ArchiveCancelled;
            const thread_index = self.sampleThread(self.samples.core(sample_index)) orelse continue;
            const core = self.samples.core(sample_index);
            const offset = core.time_ns - self.started_ns;
            if (!filter.contains(core.tid, offset)) continue;
            const sample = self.samples.get(sample_index);
            try cursor.advance(sample.time_ns);
            var path: [records.max_frames + 4]flame.Frame = undefined;
            var count: usize = 0;
            // Labels are interned with the capture, not allocated per sample.
            const thread = self.threads[thread_index];
            path[count] = .{ .kind = .thread, .address = sample.tid, .module_id = thread.debugger_id, .name = std.mem.sliceTo(&self.thread_names[thread_index], 0) };
            count += 1;
            var chain = userChain(sample);
            const trusted = sample.time_ns < self.trusted_before_ns;
            var unverified = !trusted;
            // Kernel frame-pointer walking can run into libc/entry code that
            // uses RBP as data. Keep the raw record, but cut derived ancestry at
            // the first caller outside the observed executable mappings at sample time.
            var unmapped_caller = false;
            if (trusted and chain.count > 1) for (chain.addresses[1..chain.count], 1..) |address, i| {
                const executable = if (cursor.at(address)) |match| match.ambiguous or match.mapping.executable else false;
                if (!executable) {
                    chain.count = i;
                    unmapped_caller = true;
                    break;
                }
            };
            if (sample.callchain != .complete or chain.count <= 1 or chain.omitted_context or unmapped_caller) {
                result.partial_samples += 1;
                path[count] = .{ .kind = .incomplete, .address = if (unmapped_caller) 4 else @as(u64, @intFromEnum(sample.callchain)) + 1, .name = if (unmapped_caller) "[unmapped caller / partial]" else if (sample.callchain == .truncated) "[truncated callers]" else "[callers unavailable / partial]" };
                count += 1;
            }
            var index = chain.count;
            while (index > 0) {
                index -= 1;
                path[count] = try self.frame(chain.addresses[index], trusted, cursor.at(chain.addresses[index]));
                if (path[count].kind == .unverified) unverified = true;
                count += 1;
            }
            if (chain.count == 0) {
                path[count] = .{ .kind = .unknown, .name = "[user IP unavailable]" };
                count += 1;
            }
            if (unverified) result.unverified_samples += 1;
            try result.add(path[0..count]);
        }
        try result.layout();
        return result;
    }
};
pub const Summary = struct {
    id: u64,
    session_id: u64,
    opening_generation: u64,
    image_epoch: u64,
    pid: i32,
    revision: u64,
    status: Stop,
    stop_reasons: []const Stop,
    started_ns: u64,
    ended_ns: ?u64,
    duration_ms: u32,
    accepted: perf.Acceptance,
    threads: []const Thread,
    stored_samples: usize,
    discarded_samples: u64,
    lost_records: u64,
    lost_samples: u64,
    throttles: u64,
    unthrottles: u64,
    mapping_events: u64,
    exec_events: u64,
    exit_events: u64,
    fork_events: u64,
    scope_change: ?ScopeChange,
    unknown_records: u64,
    unselected_threads: usize,
    missing_images: u64,
    trusted_before_ns: ?u64,
    failure: ?perf.Failure,
    diagnostic: []const u8,
    cpu_activity: ?activity.Summary,
    scheduling: Capture.SchedulingSummary,
    syscalls: Capture.SyscallSummary,
    application_intervals: usize,
    mapping_revision: u64,
    mapping_history: struct { opening_regions: usize, recorded_changes: usize, unresolved_executable_mappings: usize, opened_images: usize, snapshot_bytes: usize, per_image_bytes_limit: usize = @import("../binary/snapshot.zig").per_image_limit, total_image_bytes_limit: usize = @import("../binary/snapshot.zig").total_limit, change_limit: usize = mappings.max_changes, coverage: []const u8 = mappings.coverage },
    units: []const u8 = "samples (not elapsed time)",
    clock: []const u8 = "CLOCK_MONOTONIC",
    callchain: []const u8 = "kernel user callchain, frame-pointer dependent; missing callers and sample skid possible; recorded ancestry stops at an unmapped caller; sampled DWARF inspection is a separate derived result",
    follow_threads: bool,
    opening_threads: usize,
    ring_budget_bytes: ?u32,
    ring_allocated_bytes: u64,
    scope: []const u8,
    mapping_policy: []const u8 = "continue across observed mapping changes using timestamped range identities; stop on exec/loss/scope change; uncertain mappings retain raw addresses; unreported moves can invalidate attribution",
    sampled_state: struct { requested_bytes: u32, budget_bytes: u32, retained_bytes: usize, records: usize, skipped_stacks: usize, first_skipped_sample: ?usize, allocated_bytes: usize },
    sample_limit: usize = max_samples,
};
pub const Chain = struct { addresses: [records.max_frames + 1]u64 = undefined, count: usize = 0, omitted_context: bool = false };
pub fn userChain(sample: records.Sample) Chain {
    var chain = Chain{};
    if (sample.ip_present and sample.ip != 0 and sample.cpu_mode == .user and !records.isContextMarker(sample.ip)) {
        chain.addresses[0] = sample.ip;
        chain.count = 1;
    }
    var first_user = true;
    for (sample.frames[0..sample.frame_count]) |item| {
        if (item.marker) continue;
        if (item.context != .user) {
            chain.omitted_context = true;
            continue;
        }
        if (item.address == 0 or records.isContextMarker(item.address)) continue;
        // Linux x86 emits the sampled IP first, then return addresses. Remove
        // only that first duplicate; recursive callers at the same PC survive.
        if (first_user and sample.ip_present and item.address == sample.ip) {
            first_user = false;
            continue;
        }
        first_user = false;
        chain.addresses[chain.count] = item.address - 1;
        chain.count += 1;
    }
    return chain;
}

test "sample IP is exact lookup, callers use return minus one, markers and recursion survive" {
    var sample = records.Sample{ .ip = 100, .ip_present = true, .cpu_mode = .user, .frame_count = 6 };
    sample.frames[0] = .{ .marker = true, .context = .user, .raw_marker = records.context_user };
    sample.frames[1] = .{ .context = .user, .address = 100 };
    sample.frames[2] = .{ .context = .user, .address = 100 };
    sample.frames[3] = .{ .context = .user, .address = 200 };
    sample.frames[4] = .{ .context = .kernel, .address = 500 };
    sample.frames[5] = .{ .context = .user, .address = 0 };
    const chain = userChain(sample);
    try std.testing.expectEqualSlices(u64, &.{ 100, 99, 199 }, chain.addresses[0..chain.count]);
    try std.testing.expect(chain.omitted_context);
}

test "metadata loss invalidates all mapping attribution" {
    var capture: Capture = undefined;
    capture.trusted_before_ns = std.math.maxInt(u64);
    capture.lost_records = 0;
    capture.lost_samples = 0;
    capture.status = .collecting;
    capture.stop_reason_count = 0;
    capture.side(.{ .kind = .lost, .lost_count = 3 });
    try std.testing.expectEqual(@as(u64, 0), capture.trusted_before_ns);
    try std.testing.expectEqual(@as(u64, 3), capture.lost_samples);
    try std.testing.expectEqual(Stop.metadata_lost, capture.status);
}

test {
    std.testing.refAllDecls(activity);
    std.testing.refAllDecls(mappings);
    std.testing.refAllDecls(timeline);
    std.testing.refAllDecls(scheduling);
    std.testing.refAllDecls(intervals);
    std.testing.refAllDecls(sample_store);
}

test "maximum capture and mapping budgets preserve counts and bound identity storage" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 1, .config = .{}, .accepted = undefined, .thread_count = 1, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = 1, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    _ = try std.fmt.bufPrintSentinel(&capture.thread_names[0], "Thread 1", .{}, 0);
    for (0..mappings.max_opening) |i| {
        const start = 4096 + i * 64;
        try capture.history.opening(a, .{ .start = start, .end = start + 48 });
    }
    for (0..mappings.max_changes) |i| {
        const start = 4096 + i * 64 + 16;
        _ = try capture.history.add(a, i + 2, .{ .start = start, .end = start + 16 });
    }
    try std.testing.expectError(error.MappingHistoryLimit, capture.history.add(a, 9999, .{ .start = 2, .end = 3 }));
    for (0..max_samples) |i| {
        var sample = records.Sample{ .ip = 4096 + (i % mappings.max_opening) * 64 + 20, .ip_present = true, .pid = 1, .tid = 1, .tid_present = true, .time_ns = 10000 + i, .time_present = true, .cpu_mode = .user, .callchain = .complete, .frame_count = records.max_frames };
        for (&sample.frames, 0..) |*frame_, depth| frame_.* = .{ .context = .user, .address = 4096 + ((i + depth) % mappings.max_opening) * 64 + 21 };
        try capture.samples.append(a, sample);
    }
    const begin = @import("../target/linux.zig").now();
    var graph_ = try capture.graph(a, .{});
    defer graph_.deinit();
    const elapsed = @import("../target/linux.zig").now() - begin;
    try std.testing.expectEqual(@as(u64, max_samples), graph_.nodes.items[0].inclusive + graph_.rejected);
    try std.testing.expect(graph_.nodes.items.len <= flame.max_nodes and graph_.rejected > 0);
    try std.testing.expect(capture.cache.count() <= max_frames_cached);
    @import("../m68k_log.zig").print("mapping graph bound ({s}): {d} ms / {d} nodes / {d} accepted / {d} excluded\n", .{ @tagName(@import("builtin").mode), elapsed / 1_000_000, graph_.nodes.items.len, graph_.nodes.items[0].inclusive, graph_.rejected });
}

test "ring sizing preserves the total budget for every supported thread count" {
    for (1..perf.max_threads + 1) |threads| {
        const pages = ringPages(threads);
        try std.testing.expect(pages >= 4 and pages <= perf.max_data_pages);
        try std.testing.expect(std.math.isPowerOfTwo(pages));
        try std.testing.expect(threads * pages <= @as(usize, perf.max_threads) * 4);
    }
    try std.testing.expectEqual(@as(u8, 32), ringPages(100));
    try std.testing.expectEqual(@as(u8, 4), ringPages(640));
}

test "CPU timeline and flames share filters, invalid sample handling, and final-drain extent" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 100, .ended_ns = 200, .config = .{}, .accepted = undefined, .thread_count = 2, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    for (0..2) |i| {
        capture.threads[i] = .{ .debugger_id = i + 10, .perf = .{ .tid = @intCast(i + 1), .event_id = i + 1, .start_time_ticks = 1, .start_time_known = true } };
        _ = try std.fmt.bufPrintSentinel(&capture.thread_names[i], "Thread {d}", .{i + 1}, 0);
    }
    for ([_]u64{ 100, 109, 110, 150, 199, 200 }, 0..) |time, i| {
        try capture.samples.append(a, .{ .ip = 4096, .ip_present = true, .tid = @intCast(1 + i % 2), .tid_present = true, .time_ns = time, .time_present = true, .cpu_mode = .user });
    }
    try capture.samples.append(a, .{ .tid = 1, .tid_present = true, .time_ns = 99, .time_present = true });
    try capture.samples.append(a, .{ .tid = 77, .tid_present = true, .time_ns = 125, .time_present = true });
    try capture.samples.append(a, .{ .tid = 1, .tid_present = true, .time_ns = 125, .time_present = false });
    try std.testing.expectEqual(101, capture.extentNs());
    const filters = [_]Filter{ .{}, .{ .to_ns = 10 }, .{ .from_ns = 10, .to_ns = 100 }, .{ .from_ns = 100, .to_ns = 101 }, .{ .tid = 1 }, .{ .tid = 2 }, .{ .from_ns = 1000 } };
    const expected = [_]u64{ 6, 2, 3, 1, 3, 3, 0 };
    for (filters, expected) |filter, count| {
        var density = try capture.cpuTimeline(a, filter, 7);
        defer density.deinit();
        var graph_ = try capture.graph(a, filter);
        defer graph_.deinit();
        try std.testing.expectEqual(count, density.histogram.samples);
        try std.testing.expectEqual(graph_.nodes.items[0].inclusive + graph_.rejected, density.histogram.samples);
        try std.testing.expectEqual(3, density.invalid_samples);
        var sum: u64 = 0;
        for (density.lanes) |lane| sum += lane.samples;
        try std.testing.expectEqual(count, sum);
    }
    try std.testing.expectError(error.UnknownProfileThread, capture.cpuTimeline(a, .{ .tid = 77 }, 7));
    try std.testing.expectError(error.InvalidProfileFilter, capture.cpuTimeline(a, .{ .from_ns = 5, .to_ns = 5 }, 7));
}

test "debugger timeline markers stay bounded with explicit dropped counts" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 1, .started_ns = 1, .config = .{}, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    for (0..timeline.max_markers + 2) |i| capture.addMarker(.{ .offset_ns = i, .sequence = i, .tid = 1, .kind = .stop });
    try std.testing.expectEqual(timeline.max_markers, capture.debugger_markers.items.len);
    try std.testing.expectEqual(2, capture.debugger_marker_dropped);
}

test "scheduling records require opening identity and preserve earlier capture failures" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 41, .started_ns = 100, .ended_ns = 200, .config = .{ .context_switch = true }, .accepted = undefined, .thread_count = 1, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = 42, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    var event = records.Side{ .kind = .context_switch, .raw_type = records.Type.context_switch, .time_present = true, .task_present = true, .pid = 41, .tid = 42, .time_ns = 110 };
    capture.recordSwitch(event);
    event.time_ns = 150;
    event.switch_out = true;
    event.preempt_present = true;
    event.preempted = true;
    capture.recordSwitch(event);
    const spans = try capture.schedulingSpans(a, 0, .{ .from_ns = 0, .to_ns = 100 });
    defer a.free(spans);
    try std.testing.expectEqual(40, scheduling.Totals.from(spans).running_ns);
    try std.testing.expectEqual(60, scheduling.Totals.from(spans).unknown_ns);
    try std.testing.expectEqual(Stop.collecting, capture.status);
    try std.testing.expectError(error.UnknownProfileThread, capture.schedulingSpans(a, 1, .{ .from_ns = 0, .to_ns = 100 }));
    capture.status = .metadata_lost;
    capture.diagnostic = "prior loss";
    event.tid = 77;
    capture.recordSwitch(event);
    try std.testing.expectEqual(Stop.metadata_lost, capture.status);
    try std.testing.expectEqualStrings("prior loss", capture.diagnostic);
    try std.testing.expectEqual(timeline.Coverage.invalid_identity, capture.schedulingCoverage());
    try std.testing.expectEqual(1, capture.switches.invalid);
    capture.status = .collecting;
    event.tid = 42;
    event.time_ns = 99;
    capture.recordSwitch(event);
    try std.testing.expectEqual(Stop.scheduling_error, capture.status);
    capture.config.context_switch = false;
    try std.testing.expectEqual(timeline.Coverage.disabled, capture.schedulingCoverage());
}

test "later task records cannot disguise metadata loss or change its diagnostic" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 41, .started_ns = 100, .config = .{ .follow_threads = false }, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    capture.side(.{ .kind = .lost, .lost_count = 3 });
    const diagnostic = capture.diagnostic;
    capture.side(.{ .kind = .fork, .pid = 41, .tid = 42, .ppid = 41, .ptid = 41, .time_present = true, .time_ns = 150 });
    try std.testing.expectEqual(Stop.metadata_lost, capture.status);
    try std.testing.expectEqualStrings(diagnostic, capture.diagnostic);
    try std.testing.expectEqual(0, capture.trusted_before_ns);
    try std.testing.expectEqual(3, capture.lost_samples);
    try std.testing.expectEqual(1, capture.fork_events);
    try std.testing.expectEqual(42, capture.scope_change.?.tid);
}

test "scope stop retains primary reason while later loss invalidates symbols and scheduling" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 0, .image_epoch = 0, .pid = 41, .started_ns = 100, .config = .{ .context_switch = true, .follow_threads = false }, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    capture.side(.{ .kind = .fork, .pid = 43, .tid = 43, .ppid = 41, .ptid = 42, .time_present = true, .time_ns = 150 });
    const diagnostic = capture.diagnostic;
    try std.testing.expectEqual(150, capture.trusted_before_ns);
    capture.side(.{ .kind = .lost, .lost_count = 3 });
    capture.side(.{ .kind = .lost, .lost_count = 4 });
    try std.testing.expectEqual(Stop.thread_scope_changed, capture.status);
    try std.testing.expectEqualStrings(diagnostic, capture.diagnostic);
    try std.testing.expectEqual(0, capture.trusted_before_ns);
    try std.testing.expectEqual(7, capture.lost_samples);
    try std.testing.expectEqualSlices(Stop, &.{ .thread_scope_changed, .metadata_lost }, capture.stop_reasons[0..capture.stop_reason_count]);
    try std.testing.expectEqual(timeline.Coverage.lost, capture.schedulingCoverage());
    capture.lost_samples = 0;
    capture.lost_records = 0;
    try std.testing.expectEqual(timeline.Coverage.incomplete, capture.schedulingCoverage());
    capture.noteStop(.manual, "");
    try std.testing.expectEqual(Stop.thread_scope_changed, capture.status);
}

test "compact admission retains raw state by ordinal and latches refusal across drains" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |byte_refusal| {
        const capture = try a.create(Capture);
        capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 1, .image_epoch = 1, .pid = 1, .started_ns = 100, .config = .{ .user_stack_bytes = 64, .user_stack_budget_bytes = 8 }, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
        defer capture.deinit();
        capture.user_state = try sample_state.Store.init(a, 4, 8);
        capture.samples.max_samples = if (byte_refusal) max_samples else 2;
        // The first sample has no chain. Appending its first chain then needs
        // a new allocation; force a byte refusal after exactly one sample.
        const raw = [_]records.UserState{.{ .abi = 2, .regs_present = true, .stack_size = 8, .stack_dyn = 8, .stack_len = 8, .stack_present = true }};
        var bytes: [8]u8 = @splat(7);
        const first = records.Sample{ .ip = 1, .user_state = 1 };
        capture.retainSamples(&.{first}, &raw, &bytes);
        const held = capture.samples.used_bytes;
        if (byte_refusal) capture.samples.budget_bytes = held;
        var next = records.Sample{ .ip = 2, .user_state = 1, .frame_count = 1 };
        next.frames[0] = .{ .address = 2, .context = .user };
        capture.retainSamples(&.{ next, next }, &raw, &bytes);
        // A later cheap sample must not be retained beyond the refused suffix.
        @memset(&bytes, 9);
        capture.retainSamples(&.{first}, &raw, &bytes);
        const retained: usize = if (byte_refusal) 1 else 2;
        try std.testing.expectEqual(retained, capture.samples.len());
        try std.testing.expectEqual(retained, capture.user_state.count);
        try std.testing.expectEqual(@as(u64, 4 - retained), capture.discarded_samples);
        try std.testing.expectEqual(Stop.capacity, capture.status);
        try std.testing.expect(capture.sample_storage_full);
        try std.testing.expectEqual(@as(u32, 1), capture.samples.get(0).user_state);
        try std.testing.expectEqual(@as(u8, 7), capture.user_state.stack(capture.user_state.entries[0])[0]);
        if (!byte_refusal) {
            try std.testing.expectEqual(@as(u32, 2), capture.samples.get(1).user_state);
            try std.testing.expectEqual(sample_state.Status.budget, capture.user_state.entries[1].status);
            try std.testing.expectEqual(@as(?usize, 1), capture.firstSkippedSample());
        }
    }
}

test "same-process FORK before newborn enrollment preserves coverage; child processes stop" {
    const a = std.testing.allocator;
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 1, .session_id = 1, .generation = 1, .image_epoch = 1, .pid = 41, .started_ns = 100, .config = .{}, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
    defer capture.deinit();
    capture.side(.{ .kind = .fork, .pid = 41, .tid = 42, .ppid = 41, .ptid = 41, .time_present = true, .time_ns = 150 });
    try std.testing.expectEqual(Stop.collecting, capture.status);
    try std.testing.expectEqual(std.math.maxInt(u64), capture.trusted_before_ns);
    try std.testing.expectEqual(@as(?ScopeChange, null), capture.scope_change);
    capture.side(.{ .kind = .fork, .pid = 43, .tid = 43, .ppid = 41, .ptid = 42, .time_present = true, .time_ns = 160 });
    try std.testing.expectEqual(Stop.thread_scope_changed, capture.status);
    try std.testing.expectEqual(@as(u64, 160), capture.trusted_before_ns);
    try std.testing.expectEqual(@as(u32, 43), capture.scope_change.?.pid);
}

test "configured admission crosses the legacy ceiling and stops exactly at its limit" {
    const a = std.testing.allocator;
    const capture = try @import("archive_fixture.zig").build(a, .empty, null);
    defer capture.deinit();
    capture.status = .collecting;
    capture.config.sample_limit = max_samples + 7;
    capture.samples.max_samples = capture.config.sample_limit;
    const batch: [128]records.Sample = @splat(.{ .ip = 0x1000, .ip_present = true });
    while (capture.samples.len() < max_samples) capture.retainSamples(&batch, &.{}, &.{});
    try std.testing.expectEqual(Stop.collecting, capture.status);
    capture.retainSamples(batch[0..7], &.{}, &.{});
    try std.testing.expectEqual(Stop.capacity, capture.status);
    try std.testing.expectEqual(capture.config.sample_limit, capture.summary().sample_limit);
    capture.retainSamples(&batch, &.{}, &.{});
    try std.testing.expectEqual(capture.config.sample_limit, capture.samples.len());
    try std.testing.expectEqual(@as(u64, 128), capture.discarded_samples);
}
