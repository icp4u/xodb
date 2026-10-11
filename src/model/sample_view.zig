//! Sample evidence and worker results are formatted by the session owner.
//! Only bounded display lines and matching ordinal identities are published.
const std = @import("std");
const profile = @import("../profile/capture.zig");
const records = @import("../profile/records.zig");
const unwind = @import("../profile/unwind.zig");
const Session = @import("session.zig").Session;
const now = @import("../target/linux.zig").now;
pub const Request = struct {
    session: u64 = 0,
    capture: u64 = 0,
    ordinal: usize = std.math.maxInt(usize),
    filter: profile.Filter = .{},
};
pub const Tone = enum { text, weak, warm, good };
pub const Line = struct { text: []const u8 = "", tone: Tone = .weak };
pub const View = struct {
    request: Request,
    normalized: Request,
    revision: u64 = 0,
    count: usize = 0,
    matching: []const u32 = &.{},
    heading: []const u8 = "",
    identity: []const u8 = "",
    state: []const u8 = "",
    pc: []const u8 = "",
    jit: ?Line = null,
    diagnostic: ?Line = null,
    recorded: []const Line = &.{},
    derived: []const Line = &.{},
    result: Line = .{},
    terminal: Line = .{},
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Stack = union(enum) {
    not_available: []const u8,
    pending,
    waiting: []const u8,
    failed: []const u8,
    ready: *const unwind.Result,
};
const Matcher = struct {
    tids: [@import("../profile/linux_perf.zig").max_threads]u32 = undefined,
    count: usize,
    started_ns: u64,
    filter: profile.Filter,
    fn init(capture: *const profile.Capture, filter: profile.Filter) Matcher {
        var self = Matcher{ .count = capture.thread_count, .started_ns = capture.started_ns, .filter = filter };
        for (capture.threads[0..capture.thread_count], self.tids[0..capture.thread_count]) |thread, *tid| tid.* = @bitCast(thread.perf.tid);
        std.mem.sort(u32, self.tids[0..self.count], {}, std.sort.asc(u32));
        return self;
    }
    fn contains(self: *const Matcher, sample: anytype) bool {
        if (!sample.timePresent() or !sample.tidPresent() or sample.time_ns < self.started_ns or sample.tid > std.math.maxInt(i32)) return false;
        var lo: usize = 0;
        var hi = self.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.tids[mid] < sample.tid) lo = mid + 1 else hi = mid;
        }
        return lo < self.count and self.tids[lo] == sample.tid and self.filter.contains(sample.tid, sample.time_ns - self.started_ns);
    }
};
pub fn matches(capture: *const profile.Capture, filter: profile.Filter, ordinal: usize) bool {
    const matcher = Matcher.init(capture, filter);
    return matcher.contains(capture.samples.core(ordinal));
}
pub fn choose(capture: *const profile.Capture, filter: profile.Filter, ordinal: usize) usize {
    const matcher = Matcher.init(capture, filter);
    if (ordinal < capture.samples.len() and matcher.contains(capture.samples.core(ordinal))) return ordinal;
    for (0..capture.samples.len()) |i| if (matcher.contains(capture.samples.core(i))) return i;
    return capture.samples.len();
}
fn format(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var buffer: [512]u8 = undefined;
    // Keep the inspector's existing display-line bound. Raw evidence remains
    // available in the capture and its protocol endpoints.
    return a.dupe(u8, std.fmt.bufPrint(&buffer, fmt, args) catch "");
}
fn sampledState(a: std.mem.Allocator, capture: *const profile.Capture, sample: records.Sample) ![]const u8 {
    if (capture.config.user_stack_bytes == 0) return "Sampled state: stack capture was off for this capture";
    if (sample.user_state == 0 or sample.user_state > capture.user_state.count) return "Sampled state: missing (no registers or stack recorded for this sample)";
    const entry = capture.user_state.entries[sample.user_state - 1];
    const state = entry.state;
    return format(a, "Registers {s} / stack {s}: {d} of {d} bytes retained (kernel valid {d}){s}", .{ if (state.regs_present) "present" else "absent", if (entry.status == .budget) "budget gap" else if (state.stack_len == 0) "absent" else "captured", state.stack_len, state.stack_size, state.stack_dyn, if (state.stack_short) ", short" else "" });
}
/// Formats a single sample; no worker result or capture borrow survives in
/// the returned strings/arrays. Navigation includes actual matching ordinals.
pub fn project(a: std.mem.Allocator, session: u64, capture: *const profile.Capture, wanted: Request, stack: Stack, jit: ?*const @import("../frames/jit.zig").Sample) !View {
    var normalized = wanted;
    normalized.session = session;
    normalized.capture = capture.id;
    normalized.ordinal = choose(capture, wanted.filter, wanted.ordinal);
    var out = View{ .request = wanted, .normalized = normalized, .revision = capture.revision, .count = capture.samples.len() };
    var ordinals: std.ArrayList(u32) = .empty;
    const matcher = Matcher.init(capture, wanted.filter);
    for (0..capture.samples.len()) |i| if (matcher.contains(capture.samples.core(i))) try ordinals.append(a, @intCast(i));
    out.matching = ordinals.items;
    if (normalized.ordinal >= out.count) return out;
    const sample = capture.samples.get(normalized.ordinal);
    const offset = sample.time_ns -| capture.started_ns;
    out.heading = try format(a, "SAMPLE {d}/{d}   capture #{d} rev {d}   [ ] samples; I closes", .{ normalized.ordinal, out.count, capture.id, capture.revision });
    out.identity = try format(a, "TID {d}   +{d}.{d:0>6} ms   {s}   recorded callchain: {s}", .{ sample.tid, offset / 1_000_000, offset % 1_000_000, @tagName(sample.cpu_mode), @tagName(sample.callchain) });
    out.state = try sampledState(a, capture, sample);
    out.pc = try format(a, "Sampled PC 0x{x}{s} (leaf lookup uses this exact PC; callers use return PC - 1)", .{ sample.ip, if (sample.ip_present) "" else " (absent)" });
    if (jit) |labels| if (labels.leaf) |leaf| {
        out.jit = .{ .text = try format(a, "JIT {s} ({d} candidates): {s}", .{ leaf.outcome, leaf.total_candidates, if (leaf.candidates.len > 0) leaf.candidates[0].name else "no matching code" }), .tone = if (std.mem.eql(u8, leaf.outcome, "resolved")) .good else .warm };
    };
    const recorded = try a.alloc(Line, sample.frame_count);
    for (sample.frames[0..sample.frame_count], recorded, 0..) |item, *line, i| {
        const text = if (item.marker) try format(a, "{d: >2} [context {s}]", .{ i, @tagName(item.context) }) else blk: {
            if (jit) |labels| if (i < labels.frames.len) if (labels.frames[i]) |jit_label| {
                if (jit_label.candidates.len > 0) break :blk try format(a, "{d: >2} 0x{x} [{s}: {d}] {s}", .{ i, item.address, jit_label.outcome, jit_label.total_candidates, jit_label.candidates[0].name });
            };
            break :blk try format(a, "{d: >2} 0x{x} {s}", .{ i, item.address, @tagName(item.context) });
        };
        line.* = .{ .text = text, .tone = if (item.marker) .weak else .text };
    }
    out.recorded = recorded;
    switch (stack) {
        .ready => |result| {
            const derived = try a.alloc(Line, result.count);
            for (result.frames[0..result.count], derived, 0..) |frame, *line, i| line.* = .{
                .text = try format(a, "{d: >2} {s}  pc 0x{x}{s} {s}", .{ i, if (frame.name_len > 0) frame.name[0..frame.name_len] else "(no symbol)", frame.pc, if (i == 0) " leaf" else " lookup -1", frame.method orelse "" }),
                .tone = if (frame.name_len > 0) .text else .weak,
            };
            out.derived = derived;
            const complete = result.reason == .complete;
            out.terminal = .{ .text = try format(a, "{s}{s}{s}{s}", .{ if (complete) "CFI reached outermost frame" else "Unknown callers: ", if (complete) "" else @tagName(result.reason), if (result.detail != null) " / " else "", result.detail orelse "" }), .tone = if (complete) .good else .warm };
        },
        .pending => out.result = .{ .text = "Reconstructing on the worker...", .tone = .good },
        .waiting => |why| out.result.text = try format(a, "Queued: {s}", .{why}),
        .failed => |why| out.result = .{ .text = try format(a, "Failed: {s} (not retried)", .{why}), .tone = .warm },
        .not_available => |why| out.result.text = try a.dupe(u8, why),
    }
    return out;
}
fn stackFor(session: *Session, ordinal: usize) Stack {
    const capture = session.profile.?;
    if (capture.collector != null) return .{ .not_available = "Stop collection to reconstruct" };
    if (capture.config.user_stack_bytes == 0) return .{ .not_available = "Stack capture was off (S, Stacks)" };
    if (session.archive_job) |job| {
        if (job.kind == .stack and job.capture_id == capture.id and job.capture_revision == capture.revision and job.sample_ordinal == ordinal) {
            if (!job.done.load(.acquire)) return .pending;
            if (job.stack_result) |*result| return .{ .ready = result };
            return .{ .failed = if (job.failure) |err| @errorName(err) else "no result" };
        }
        if (!job.done.load(.acquire)) return .{ .waiting = if (job.kind == .derived) "reconstructed flame view" else "archive job" };
    }
    _ = session.requestProfileStackOwned(ordinal, .{}) catch |err| return .{ .failed = @errorName(err) };
    return .pending;
}
const Signature = struct {
    session: u64,
    capture: u64,
    revision: u64,
    active: bool,
    samples: usize,
    archive_job: u64,
    archive_done: bool,
    frames_serial: u64,
    frames_job: bool,
    frames_done: bool,
    evidence: u64,
    fn read(session: *const Session) Signature {
        return .{
            .session = session.id,
            .capture = if (session.profile) |c| c.id else 0,
            .revision = if (session.profile) |c| c.revision else 0,
            .active = if (session.profile) |c| c.collector != null else false,
            .samples = if (session.profile) |c| c.samples.len() else 0,
            .archive_job = if (session.archive_job) |job| job.id else 0,
            .archive_done = if (session.archive_job) |job| job.done.load(.acquire) else false,
            .frames_serial = session.frames.serial,
            .frames_job = session.frames.job != null,
            .frames_done = if (session.frames.job) |job| job.done.load(.acquire) else false,
            .evidence = session.frames.evidence_revision,
        };
    }
};
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    signature: ?Signature = null,
    built_ns: u64 = 0,
    pending: bool = false,
    jit_failure: ?anyerror = null,
    jit_requested: ?struct { session: u64, capture: u64, revision: u64, evidence: u64, ordinal: usize } = null,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = null;
        self.signature = null;
        // Retain the value-only JIT request identity across hide/show, as
        // the frontend did. Reopening alone must not restart that job.
        self.jit_failure = null;
        self.pending = false;
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        const previous = self.signature orelse return true;
        const current = Signature.read(session);
        if (std.meta.eql(previous, current)) return self.pending and now() -| self.built_ns >= 250 * std.time.ns_per_ms;
        if (current.session != previous.session or current.capture != previous.capture or !current.active) return true;
        return now() -| self.built_ns >= 250 * std.time.ns_per_ms;
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const requested = wanted orelse {
            self.clear();
            return;
        };
        if (self.value) |v| if (!self.changed(session) and (std.meta.eql(requested, v.request) or std.meta.eql(requested, v.normalized))) return;
        if (self.signature) |seen| if (seen.session != session.id or seen.capture != (if (session.profile) |c| c.id else @as(u64, 0))) self.clear();
        var effective = requested;
        if (requested.capture != 0 and (requested.session != session.id or requested.capture != (if (session.profile) |c| c.id else @as(u64, 0)))) effective.ordinal = std.math.maxInt(usize);
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .request = requested, .normalized = .{ .session = session.id, .capture = if (session.profile) |c| c.id else 0, .filter = requested.filter } };
        defer {
            self.signature = Signature.read(session);
            self.built_ns = now();
        }
        const capture = session.profile orelse return;
        const ordinal = choose(capture, effective.filter, effective.ordinal);
        self.pending = false;
        if (ordinal < capture.samples.len() and session.frames.hasJit()) {
            const jit_key: @typeInfo(@FieldType(Capture, "jit_requested")).optional.child = .{ .session = session.id, .capture = capture.id, .revision = capture.revision, .evidence = session.frames.evidence_revision, .ordinal = ordinal };
            if (capture.collector == null and !capture.archive_busy and !session.frames.busy() and (self.jit_requested == null or !std.meta.eql(self.jit_requested.?, jit_key))) {
                self.jit_failure = null;
                session.frames.prepareJit(capture, if (session.artifact) |artifact| artifact.source else null, ordinal, 1) catch |err| {
                    self.jit_failure = err;
                };
                self.jit_requested = jit_key;
            }
        }
        const stack: Stack = if (ordinal < capture.samples.len()) stackFor(session, ordinal) else .{ .not_available = "No sample in the current selection" };
        const jit = if (session.frames.jit_view) |view| view.sample(capture, ordinal, session.frames.evidence_revision) else null;
        self.pending = stack == .pending or stack == .waiting or session.frames.busy();
        self.value = project(self.arena.allocator(), session.id, capture, effective, stack, jit) catch |err| {
            self.value.?.diagnostic = .{ .text = @errorName(err), .tone = .warm };
            return;
        };
        self.value.?.request = requested;
        self.value.?.diagnostic = if (self.jit_failure) |err| .{ .text = @errorName(err), .tone = .warm } else null;
    }
};

test "sample publication owns its evidence and permits navigation while details lag" {
    const a = std.testing.allocator;
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = .init(a), .id = 4, .session_id = 1, .generation = 1, .image_epoch = 1, .pid = 7, .started_ns = 100, .ended_ns = 100000, .config = .{}, .accepted = std.mem.zeroes(@import("../profile/linux_perf.zig").Acceptance), .thread_count = 1024, .collector = null, .images = @import("modules.zig").Modules.init(a), .samples = .{ .max_samples = profile.max_sample_limit } };
    var capture_alive = true;
    defer if (capture_alive) capture.deinit();
    for (0..capture.thread_count) |i| capture.threads[i] = .{ .debugger_id = i + 1, .perf = .{ .tid = @intCast(7 + 1023 - i), .event_id = i + 1, .start_time_ticks = 1, .start_time_known = true } };
    for (0..profile.max_sample_limit) |i| {
        var sample = records.Sample{ .tid = @intCast(7 + i % 1024), .tid_present = true, .time_present = true, .time_ns = 100 + i, .ip = 0x1234, .ip_present = true, .frame_count = if (i == 0) records.max_frames else 1 };
        for (sample.frames[0..sample.frame_count], 0..) |*frame, j| frame.* = .{ .address = 0x1234 + j, .context = .user };
        try capture.samples.append(a, sample);
    }
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var stack = unwind.Result{ .count = unwind.max_frames, .reason = .complete };
    for (stack.frames[0..stack.count], 0..) |*frame, i| {
        frame.* = .{ .pc = 0x2345 + i, .sp = 0, .lookup_pc = 0x2345 + i, .method = try arena.allocator().dupe(u8, "owned CFI method") };
        @memset(&frame.name, 'n');
        frame.name_len = frame.name.len;
    }
    const jit_model = @import("../frames/jit.zig");
    var candidates = [_]jit_model.Candidate{std.mem.zeroes(jit_model.Candidate)};
    candidates[0].name = try arena.allocator().dupe(u8, "owned JIT symbol");
    var jit_label = std.mem.zeroes(jit_model.Label);
    jit_label.outcome = "resolved";
    jit_label.total_candidates = 1;
    jit_label.candidates = &candidates;
    var labels: [records.max_frames]?jit_model.Label = @splat(jit_label);
    const jit = jit_model.Sample{ .ordinal = 0, .leaf = jit_label, .frames = &labels, .frames_omitted = 0 };
    var frontend = @import("../ui/sample_inspector.zig").Inspector{ .open = true };
    const prepared = try project(arena.allocator(), 1, capture, frontend.request(.{}).?, .{ .ready = &stack }, &jit);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 }, .revision = 1, .taken_ns = 1, .status = .ready, .sample = prepared });
    defer publication.destroy();
    try std.testing.expect(publication.bytes < 384 * 1024);
    capture.deinit();
    capture_alive = false;
    _ = arena.reset(.free_all);
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    frontend.present(publication.value.sample, .{});
    try std.testing.expectEqual(@as(usize, profile.max_sample_limit), frontend.view.?.matching.len);
    try std.testing.expect(std.mem.indexOf(u8, frontend.view.?.derived[0].text, "owned CFI method") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontend.view.?.jit.?.text, "owned JIT symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, frontend.view.?.recorded[63].text, "owned JIT symbol") != null);
    try std.testing.expectEqual(@as(usize, unwind.max_frames), frontend.view.?.derived.len);
    frontend.step(.{}, 1);
    frontend.step(.{}, 1);
    frontend.present(publication.value.sample, .{});
    try std.testing.expectEqual(@as(usize, 2), frontend.ordinal);
    frontend.step(.{}, 1);
    try std.testing.expectEqual(@as(usize, 3), frontend.ordinal);
    frontend.present(publication.value.sample, .{ .tid = 8 });
    try std.testing.expect(frontend.view == null);
}

test "sample completion invalidates pending display even after signature observes done" {
    const a = std.testing.allocator;
    var session = Session{ .id = 1 };
    defer session.deinit();
    const capture = try a.create(profile.Capture);
    capture.* = .{ .allocator = a, .arena = .init(a), .id = 1, .session_id = 1, .generation = 1, .image_epoch = 1, .pid = 7, .started_ns = 100, .ended_ns = 200, .config = .{ .user_stack_bytes = 4096 }, .accepted = std.mem.zeroes(@import("../profile/linux_perf.zig").Acceptance), .thread_count = 1, .collector = null, .images = @import("modules.zig").Modules.init(a) };
    session.profile = capture;
    capture.threads[0] = .{ .debugger_id = 1, .perf = .{ .tid = 7, .event_id = 1, .start_time_ticks = 1, .start_time_known = true } };
    try capture.samples.append(a, .{ .tid = 7, .tid_present = true, .time_ns = 110, .time_present = true });
    const job = try @import("../profile/archive_job.zig").Job.create(1, .stack, "owned held stack result");
    job.capture = capture;
    job.capture_id = capture.id;
    job.capture_revision = capture.revision;
    job.sample_ordinal = 0;
    session.archive_job = job;
    var owner = Capture{};
    defer owner.deinit();
    owner.refresh(&session, .{});
    try std.testing.expect(owner.pending);
    try std.testing.expectEqualStrings("Reconstructing on the worker...", owner.value.?.result.text);
    job.stack_result = .{ .count = 0, .reason = .complete };
    job.done.store(true, .release);
    // Model completion between preparing the pending text and recording the
    // signature: the pending bit must still schedule another preparation.
    owner.signature = Signature.read(&session);
    owner.built_ns = 0;
    try std.testing.expect(owner.changed(&session));
    owner.refresh(&session, owner.value.?.normalized);
    try std.testing.expect(!owner.pending);
    try std.testing.expectEqualStrings("CFI reached outermost frame", owner.value.?.terminal.text);
    owner.refresh(&session, null);
    try std.testing.expectEqual(@as(usize, 0), owner.arena.queryCapacity());
}
