//! Owner-side capture setup, progress and typed controls.
const std = @import("std");
const model = @import("session.zig");
const Session = model.Session;
const c = @import("../c.zig").api;
const setup = @import("../ui/capture_setup.zig");
const profile = @import("../profile/capture.zig");
const perf = @import("../profile/linux_perf.zig");
const linux = @import("../target/linux.zig");
const archive = @import("../profile/archive_job.zig");

pub const View = struct {
    snapshot: setup.Snapshot = .{ .target = null, .stopped = false, .offline = false, .collecting = false, .threads = &.{} },
    defaults: profile.Config = .{},
    capture_id: ?u64 = null,
    facts: ?setup.Facts = null,
    start_error: ?[]const u8 = null,
    start_failure: ?perf.Failure = null,
    requested_threads: usize = 0,
    archive_job: ?archive.Status = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    rows: ThreadRows = .{},
    value: View = .{},
    refreshed_ns: u64 = 0,
    revision: u64 = 0,
    show_setup: bool = false,
    pub fn refresh(self: *Capture, session: *Session, show_setup: bool) void {
        self.show_setup = show_setup;
        self.value = .{
            .snapshot = self.rows.observe(session, show_setup),
            .defaults = session.profile_defaults,
            .capture_id = if (session.profile) |v| v.id else null,
            .facts = if (show_setup) if (session.profile) |v| setup.factsFrom(v) else null else null,
            .start_error = session.profile_error,
            .start_failure = session.profile_failure,
            .requested_threads = session.profile_requested_threads,
            .archive_job = if (session.archive_job) |job| job.status() else null,
        };
        self.revision = if (session.profile) |v| v.revision else 0;
        self.refreshed_ns = linux.now();
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        if (!std.meta.eql(self.value.defaults, session.profile_defaults) or
            self.value.capture_id != (if (session.profile) |v| @as(?u64, v.id) else null) or
            !std.meta.eql(self.value.start_error, session.profile_error) or !std.meta.eql(self.value.start_failure, session.profile_failure)) return true;
        const status = if (session.archive_job) |job| job.status() else null;
        if ((status == null) != (self.value.archive_job == null)) return true;
        if (status) |v| {
            const old = self.value.archive_job.?;
            if (v.id != old.id or v.done != old.done or v.cancel_requested != old.cancel_requested) return true;
        }
        if (linux.now() -| self.refreshed_ns < 250 * std.time.ns_per_ms) return false;
        if (status) |v| if (v.completed_units != self.value.archive_job.?.completed_units or !std.mem.eql(u8, v.phase, self.value.archive_job.?.phase)) return true;
        return self.show_setup and self.revision != (if (session.profile) |v| v.revision else 0);
    }
};
pub const Start = struct {
    target: ?setup.TargetKey,
    mode: setup.Mode,
    threads: []const setup.ThreadRef,
    pub fn from(selection: *const setup.Selection) Start {
        return .{ .target = selection.target, .mode = selection.mode, .threads = selection.refs[0..selection.count] };
    }
};
pub const Action = union(enum) {
    defaults: profile.Config,
    start: Start,
    stop: u64,
    retry_derived,
    cancel_archive: u64,
    browse: struct { key: @import("profile_view.zig").Key, frame: @import("../profile/flame.zig").Frame },
};
pub const Outcome = union(enum) {
    configured,
    started: u64,
    stopped,
    rejected: setup.StartProblem,
    retrying,
    cancelled,
    browse: struct { source: u64, assembly: u64 },
};
/// Validate debugger IDs as well as TIDs at execution, before the perf call.
/// The request contains only the selected rows, never a borrowed Selection.
pub fn prepare(snapshot: *const setup.Snapshot, defaults: profile.Config, request: Start, tids: []i32) !setup.Prepared {
    if (request.threads.len > perf.max_threads or (request.mode == .all and request.threads.len != 0)) return error.InvalidProfileThreads;
    var selection: setup.Selection = .{ .target = request.target, .mode = request.mode };
    for (request.threads) |ref| {
        if (ref.id == 0 or ref.tid <= 0) return error.InvalidProfileThreads;
        const before = selection.count;
        try selection.add(ref);
        if (selection.count == before) return error.InvalidProfileThreads;
    }
    // Even All refers to the displayed image; never retarget a queued start.
    if (!std.meta.eql(snapshot.target, request.target)) return .{ .rejected = .{ .problem = .replaced_target } };
    return setup.prepareStart(snapshot, defaults, &selection, .{}, tids);
}
pub fn apply(rows: *ThreadRows, session: *Session, actor: model.Actor, action: Action) !Outcome {
    switch (action) {
        .defaults => |config| {
            if (session.offline) return error.OfflineSession;
            if (config.tids.len != 0) return error.InvalidProfileThreads;
            try config.validate();
            session.profile_defaults = config;
            session.record(actor, "configure_profile");
            return .configured;
        },
        .start => |request| {
            const snapshot = rows.observe(session, false);
            var tids: [perf.max_threads]i32 = undefined;
            switch (try prepare(&snapshot, session.profile_defaults, request, &tids)) {
                .rejected => |reason| return .{ .rejected = reason.problem },
                .ready => |config| {
                    const id = try session.startProfile(config);
                    session.record(actor, "start_profile");
                    return .{ .started = id };
                },
            }
        },
        .stop => |id| {
            const capture = session.profile orelse return error.NoProfileCapture;
            if (capture.id != id) return error.StaleProfileCapture;
            try session.stopProfile();
            session.record(actor, "stop_profile");
            return .stopped;
        },
        .retry_derived => {
            session.retryDerived();
            return .retrying;
        },
        .cancel_archive => |id| {
            const job = session.archive_job orelse return error.NoArchiveJob;
            if (job.id != id) return error.StaleArchiveJob;
            try job.owner.require(if (actor == .human) .{} else session.jobRequester());
            if (job.done.load(.acquire)) return error.ArchiveAlreadyFinished;
            job.progress.cancel.store(true, .release);
            session.record(actor, "cancel_archive");
            return .cancelled;
        },
        .browse => |request| {
            const capture = session.profile orelse return error.NoProfileCapture;
            const key = request.key;
            if (key.session != session.id or key.capture != capture.id or key.mapping_revision != capture.mapping_revision or
                (capture.trusted_before_ns != std.math.maxInt(u64) and key.revision != capture.revision)) return error.StaleProfileCapture;
            if (capture.offline) return error.ProfileSourceNotRecorded;
            const state = session.target.snapshot();
            if (state.state != .stopped or state.image_epoch != capture.image_epoch or state.pid != capture.pid) return error.ProfileImageNotStopped;
            try session.refreshMaps();
            if (!capture.matchesLive(&session.modules, request.frame)) return error.ProfileImageMismatch;
            return .{ .browse = .{ .source = request.frame.lookup_address, .assembly = request.frame.address } };
        },
    }
}

/// Per-frame thread snapshot for the setup panel: rows by value with names
/// read once per debugger thread ID from the live target's comm files.
/// Nothing here points into target storage; names live in this cache.
pub const ThreadRows = struct {
    rows: [@import("../profile/linux_perf.zig").max_threads]setup.ThreadRow = undefined,
    names: [@import("../profile/linux_perf.zig").max_threads]Name = undefined,
    name_count: usize = 0,
    key: ?setup.TargetKey = null,
    const Name = struct { id: u64, len: u8, bytes: [16]u8 };

    pub fn snapshot(self: *ThreadRows, session: *Session) setup.Snapshot {
        return self.observe(session, true);
    }
    pub fn observe(self: *ThreadRows, session: *Session, names: bool) setup.Snapshot {
        const target = &session.target;
        const live = target.core == null and target.snapshot().pid != 0 and target.snapshot().state != .idle and target.snapshot().state != .exited;
        const key: ?setup.TargetKey = if (live) .{ .pid = target.snapshot().pid, .image_epoch = target.snapshot().image_epoch } else null;
        if (!std.meta.eql(key, self.key)) {
            self.key = key;
            self.name_count = 0;
        }
        var n: usize = 0;
        if (live) for (target.threadSlice()) |thread| {
            if (n == self.rows.len) break;
            self.rows[n] = .{ .ref = .{ .id = thread.id, .tid = thread.tid }, .state = switch (thread.state) {
                .stopped => .stopped,
                .running => .running,
                else => .exited,
            }, .name = if (names) self.name(target, thread.id, thread.tid) else "" };
            n += 1;
        };
        const collecting = if (session.profile) |capture| capture.collector != null else false;
        return .{ .target = key, .stopped = target.snapshot().state == .stopped, .offline = session.offline, .collecting = collecting, .threads = self.rows[0..n] };
    }
    fn name(self: *ThreadRows, target: *const @import("../target/linux.zig").Target, id: u64, tid: i32) []const u8 {
        for (self.names[0..self.name_count]) |*entry| if (entry.id == id) return entry.bytes[0..entry.len];
        if (self.name_count == self.names.len) return "";
        const rt = @import("../target/runtime.zig").c;
        const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_THREAD_COMM, .tid = tid });
        const entry = &self.names[self.name_count];
        entry.* = .{ .id = id, .len = 0, .bytes = undefined };
        var fd: c_int = -1;
        if (rt.xrt_target_file(target.handle, &request, &fd) == rt.XRT_OK) {
            defer _ = c.close(fd);
            const got = c.read(fd, &entry.bytes, entry.bytes.len);
            if (got > 0) entry.len = @intCast(std.mem.trimEnd(u8, entry.bytes[0..@intCast(got)], "\n").len);
        }
        self.name_count += 1;
        return entry.bytes[0..entry.len];
    }
};

test "capture starts refuse reused thread IDs and replaced images" {
    const key: setup.TargetKey = .{ .pid = 42, .image_epoch = 3 };
    const thread: setup.ThreadRef = .{ .id = 9, .tid = 43 };
    var rows = [_]setup.ThreadRow{.{ .ref = thread, .state = .stopped, .name = "worker" }};
    var snapshot: setup.Snapshot = .{ .target = key, .stopped = true, .offline = false, .collecting = false, .threads = &rows };
    var tids: [2]i32 = undefined;
    const request: Start = .{ .target = key, .mode = .subset, .threads = &.{thread} };
    try std.testing.expectEqual(@as(i32, 43), (try prepare(&snapshot, .{}, request, &tids)).ready.tids[0]);
    rows[0].ref.id = 10;
    try std.testing.expectEqual(.missing_threads, (try prepare(&snapshot, .{}, request, &tids)).rejected.problem);
    rows[0].ref = thread;
    rows[0].state = .exited;
    try std.testing.expectEqual(.missing_threads, (try prepare(&snapshot, .{}, request, &tids)).rejected.problem);
    snapshot.target.?.image_epoch += 1;
    try std.testing.expectEqual(.replaced_target, (try prepare(&snapshot, .{}, .{ .target = key, .mode = .all, .threads = &.{} }, &tids)).rejected.problem);
    try std.testing.expectError(error.InvalidProfileThreads, prepare(&snapshot, .{}, .{ .target = key, .mode = .subset, .threads = &.{ thread, thread } }, &tids));
}

test "capture publication owns thread names and failure progress after retirement" {
    const boundary = @import("remote_owner.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = arena.allocator();
    const rows = try a.alloc(setup.ThreadRow, 1);
    rows[0] = .{ .ref = .{ .id = 9, .tid = 43 }, .state = .stopped, .name = try a.dupe(u8, "worker") };
    const reason = try a.dupe(u8, "PerfUnavailable");
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 42, .start_ticks = 1, .image_epoch = 0, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .capture_control = .{ .snapshot = .{ .target = .{ .pid = 42, .image_epoch = 0 }, .stopped = true, .offline = false, .collecting = false, .threads = rows }, .start_error = reason },
    });
    defer publication.destroy();
    @memset(reason, 'x');
    rows[0].ref.id = 100;
    arena.deinit();
    const view = publication.value.capture_control.?;
    try std.testing.expectEqualStrings("worker", view.snapshot.threads[0].name);
    try std.testing.expectEqual(@as(u64, 9), view.snapshot.threads[0].ref.id);
    try std.testing.expectEqualStrings("PerfUnavailable", view.start_error.?);
}

test "capture controls refuse foreign jobs and invalid defaults without side effects" {
    const a = std.testing.allocator;
    const session = try a.create(Session);
    defer a.destroy(session);
    session.* = Session.init();
    defer session.deinit();
    const rows = try a.create(ThreadRows);
    defer a.destroy(rows);
    rows.* = .{};
    const job = try archive.Job.create(7, .view, "capture");
    session.archive_job = job;
    session.agent_client_id = 8;
    try std.testing.expectError(error.JobNotOwned, apply(rows, session, .agent, .{ .cancel_archive = 7 }));
    try std.testing.expect(!job.progress.cancel.load(.acquire));
    try std.testing.expectError(error.StaleArchiveJob, apply(rows, session, .human, .{ .cancel_archive = 6 }));
    try std.testing.expectError(error.InvalidProfileThreads, apply(rows, session, .human, .{ .defaults = .{ .tids = &.{42} } }));
    try std.testing.expectError(error.InvalidProfileConfig, apply(rows, session, .human, .{ .defaults = .{ .frequency_hz = 0 } }));
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
    _ = try apply(rows, session, .human, .{ .cancel_archive = 7 });
    try std.testing.expect(job.progress.cancel.load(.acquire));
}
