//! Import ownership: immutable evidence, a default view, independent GUI/MCP slots.
const std = @import("std");
const model = @import("imported.zig");
const Progress = @import("archive_progress.zig").Progress;
const a = std.heap.page_allocator;
pub const Job = struct {
    path: ?[:0]u8 = null,
    input: ?*const model.Profile = null,
    filter: model.Filter = .{},
    profile: ?*model.Profile = null,
    view: ?*model.View = null,
    progress: Progress = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?anyerror = null,
    fn start(self: *Job) !void {
        self.thread = try unsupportedThread(.{}, run, .{self});
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        if (self.path) |path| self.profile = try model.Profile.open(path, &self.progress);
        self.view = try model.View.build(self.input orelse self.profile.?, self.filter, &self.progress);
    }
    fn join(self: *Job) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn deinit(self: *Job) void {
        self.progress.cancel.store(true, .release);
        self.join();
        if (self.view) |view| view.deinit();
        if (self.profile) |profile| profile.deinit();
        if (self.path) |path| a.free(path);
        a.destroy(self);
    }
};
pub const Result = union(enum) {
    pending,
    failed: anyerror,
    ready: *const model.View,
};
pub const Owner = enum { gui, mcp };
pub const Slot = struct {
    job: ?*Job = null,
    view: ?*model.View = null,
    failure: ?struct { filter: model.Filter, err: anyerror } = null,
    fn deinit(self: *Slot) void {
        if (self.job) |job| job.deinit();
        if (self.view) |view| view.deinit();
        self.* = .{};
    }
    fn poll(self: *Slot) bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        job.join();
        // Cancellation wins even when the worker completed just before it.
        if (job.progress.cancel.load(.acquire)) job.failure = error.ImportCancelled;
        if (job.failure) |err| {
            self.failure = .{ .filter = job.filter, .err = err };
        } else {
            if (self.view) |old| old.deinit();
            self.view = job.view;
            job.view = null;
            self.failure = null;
        }
        job.deinit();
        self.job = null;
        return true;
    }
    fn request(self: *Slot, profile: *const model.Profile, filter: model.Filter) Result {
        if (self.view) |view| if (std.meta.eql(view.filter, filter)) return .{ .ready = view };
        if (self.job != null) return .pending;
        if (self.failure) |failure| if (std.meta.eql(failure.filter, filter)) return .{ .failed = failure.err };
        const job = a.create(Job) catch |err| return self.fail(filter, err);
        job.* = .{ .input = profile, .filter = filter };
        job.start() catch |err| {
            job.deinit();
            return self.fail(filter, err);
        };
        self.job = job;
        return .pending;
    }
    fn fail(self: *Slot, filter: model.Filter, err: anyerror) Result {
        self.failure = .{ .filter = filter, .err = err };
        return .{ .failed = err };
    }
};
pub const State = struct {
    load_job: ?*Job = null,
    profile: ?*model.Profile = null,
    full: ?*model.View = null,
    failure: ?anyerror = null,
    gui: Slot = .{},
    mcp: Slot = .{},
    serial: u64 = 0,
    gui_filter: ?model.Filter = null,
    gui_sample: ?usize = null,
    gui_selected: u32 = 0,
    gui_zoom: u32 = 0,
    gui_stack_start: usize = 0,
    gui_view_id: ?[64]u8 = null,
    pub fn open(path: []const u8) !State {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.ImportPathInvalid;
        const job = try a.create(Job);
        job.* = .{};
        errdefer job.deinit();
        job.path = try a.dupeSentinel(u8, path, 0);
        try job.start();
        return .{ .load_job = job };
    }
    pub fn poll(self: *State) void {
        if (self.load_job) |job| if (job.done.load(.acquire)) {
            job.join();
            if (job.progress.cancel.load(.acquire)) job.failure = error.ImportCancelled;
            self.failure = job.failure;
            if (job.failure == null) {
                self.profile = job.profile;
                self.full = job.view;
                job.profile = null;
                job.view = null;
            }
            if (self.failure) |err| @import("../m68k_log.zig").print("xodb: profile import failed: {s}\n", .{@errorName(err)}) else @import("../m68k_log.zig").print("xodb: imported {s}: {d} samples, {d} {s}, labels=simpleperf\n", .{ self.profile.?.wire.architecture, self.full.?.samples, self.full.?.total_period, self.profile.?.wire.unit });
            job.deinit();
            self.load_job = null;
            self.serial += 1;
        };
        if (self.gui.poll()) self.serial += 1;
        if (self.mcp.poll()) self.serial += 1;
    }
    pub fn request(self: *State, filter: model.Filter, owner: Owner) Result {
        if (self.failure) |err| return .{ .failed = err };
        const profile = self.profile orelse return .pending;
        profile.validateFilter(filter) catch |err| return .{ .failed = err };
        if (std.meta.eql(filter, model.Filter{})) return .{ .ready = self.full.? };
        return switch (owner) {
            .gui => self.gui.request(profile, filter),
            .mcp => self.mcp.request(profile, filter),
        };
    }
    pub fn cancel(self: *State, owner: Owner) void {
        if (self.load_job) |job| job.progress.cancel.store(true, .release);
        const slot = if (owner == .gui) &self.gui else &self.mcp;
        if (slot.job) |job| job.progress.cancel.store(true, .release);
    }
    pub fn retry(self: *State, owner: Owner) void {
        const slot = if (owner == .gui) &self.gui else &self.mcp;
        slot.failure = null;
    }
    pub fn deinit(self: *State) void {
        if (self.load_job) |job| job.deinit();
        self.gui.deinit();
        self.mcp.deinit();
        if (self.full) |view| view.deinit();
        if (self.profile) |profile| profile.deinit();
        self.* = .{};
    }
};

fn unsupportedThread(_: anytype, _: anytype, _: anytype) error{ThreadsUnavailable}!std.Thread { return error.ThreadsUnavailable; }
