//! One archive operation owns its worker, progress and unpublished result.
const std = @import("std");
const archive = @import("archive.zig");
const Capture = @import("capture.zig").Capture;
const Progress = @import("archive_progress.zig").Progress;
const a = std.heap.page_allocator;
pub const Job = struct {
    pub const DerivedOwner = enum { gui, mcp };
    owner: @import("../service/job_owner.zig").Owner = .{},
    derived_owner: DerivedOwner = .mcp,
    id: u64,
    kind: enum { open, save, view, stack, derived, allocation_save },
    path: [:0]u8,
    symbols: ?[:0]u8 = null,
    local_id: u64 = 0,
    reanalyze: bool = false,
    capture: ?*Capture = null,
    allocation: ?*@import("allocation_capture.zig").Capture = null,
    allocation_opened: ?*@import("allocation_capture.zig").Capture = null,
    original_bytes: ?[]const u8 = null,
    frames: ?*@import("../frames/state.zig").State = null,
    attachment_save: ?@import("../frames/state.zig").AttachmentSave = null,
    sample_ordinal: usize = 0,
    capture_id: u64 = 0,
    capture_revision: u64 = 0,
    stack_result: ?@import("unwind.zig").Result = null,
    filter: @import("capture.zig").Filter = .{},
    view: ?@import("flame.zig").Graph = null,
    view_budget: ?*@import("archive_budget.zig").Budget = null,
    /// Reconstructed-stack flame view, with the cache key it was built for.
    derived_view: ?@import("derived.zig").View = null,
    derived_key: @import("derived.zig").Key = .{},
    superseded: bool = false,
    derived_budget: ?*@import("archive_budget.zig").Budget = null,
    progress: Progress = .{},
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    reaped: bool = false,
    opened: ?archive.Opened = null,
    publication: ?archive.Publication = null,
    failure: ?anyerror = null,
    pub fn create(id: u64, kind: @FieldType(Job, "kind"), path: []const u8) !*Job {
        if (path.len == 0 or path.len > archive.max_path or std.mem.indexOfScalar(u8, path, 0) != null) return error.ArchivePathInvalid;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .id = id, .kind = kind, .path = try a.dupeZ(u8, path) };
        return self;
    }
    pub fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.progress.phase.store(.complete, .release);
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        switch (self.kind) {
            .stack => {
                var budget = @import("archive_budget.zig").Budget{ .backing = a, .limit = 64 * 1024 * 1024 };
                try self.progress.step(.annotations, 0);
                self.stack_result = @import("unwind.zig").walk(budget.allocator(), self.capture.?, self.sample_ordinal, &self.progress.cancel) catch |err| return if (budget.denied) error.ArchiveMemoryLimit else err;
            },
            .derived => {
                const budget = try a.create(@import("archive_budget.zig").Budget);
                budget.* = .{ .backing = a, .limit = @import("derived.zig").memory_limit };
                self.derived_budget = budget;
                try self.progress.step(.annotations, 0);
                const begin = @import("../target/linux.zig").now();
                self.derived_view = @import("derived.zig").build(budget.allocator(), self.capture.?, self.filter, &self.progress.cancel, &self.progress.units) catch |err| return if (budget.denied) error.ArchiveMemoryLimit else err;
                self.derived_view.?.build_ns = @import("../target/linux.zig").now() - begin;
                self.derived_view.?.peak_bytes = budget.peak;
            },
            .view => {
                const budget = try a.create(@import("archive_budget.zig").Budget);
                budget.* = .{ .backing = a, .limit = 64 * 1024 * 1024 };
                self.view_budget = budget;
                try self.progress.step(.annotations, 0);
                self.view = self.capture.?.graphWithCancel(budget.allocator(), self.filter, &self.progress.cancel) catch |err| return if (budget.denied) error.ArchiveMemoryLimit else err;
            },
            .open => {
                const bytes = try archive.readFile(a, self.path, archive.max_file_bytes, &self.progress);
                defer a.free(bytes);
                if (std.mem.startsWith(u8, bytes, @import("allocation_archive.zig").magic)) {
                    if (self.symbols != null or self.reanalyze) return error.AllocationArchiveUsesRecordedLabels;
                    self.allocation_opened = try @import("allocation_archive.zig").decode(a, bytes, &self.progress);
                    return;
                }
                self.opened = try archive.decode(a, bytes, .{ .local_id = self.local_id, .resolver = .{ .enabled = self.symbols != null or self.reanalyze, .root = self.symbols }, .reanalyze = self.reanalyze, .progress = &self.progress });
            },
            .allocation_save => {
                const bytes = try @import("allocation_archive.zig").encode(a, self.allocation.?, &self.progress);
                defer a.free(bytes);
                self.publication = archive.publish(self.path, bytes, &self.progress);
            },
            .save => {
                var encoded: ?[]u8 = null;
                defer if (encoded) |bytes| a.free(bytes);
                const native_bytes = self.original_bytes orelse blk: {
                    encoded = try archive.encode(a, self.capture.?, .{ .writer_boot_id = @import("../binary/snapshot.zig").bootId(), .progress = &self.progress });
                    break :blk encoded.?;
                };
                if (self.progress.cancel.load(.acquire)) {
                    self.publication = archive.publish(self.path, native_bytes, &self.progress);
                    return;
                }
                const attached = if (self.frames) |frames| try frames.encode(null) else null;
                defer if (attached) |data| data.deinit();
                const with_frames = if (attached) |data| try archive.attachFrames(a, native_bytes, data.bytes()) else null;
                defer if (with_frames) |data| a.free(data);
                self.publication = archive.publish(self.path, with_frames orelse native_bytes, &self.progress);
            },
        }
    }
    pub fn join(self: *Job) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    pub fn deinit(self: *Job) void {
        self.progress.cancel.store(true, .release);
        self.join();
        if (self.frames) |frames| frames.pinned = false;
        if (self.capture) |capture| capture.archive_busy = false;
        if (self.allocation) |capture| capture.archive_busy = false;
        if (self.allocation_opened) |capture| capture.deinit();
        if (self.opened) |*opened| opened.deinit();
        if (self.view) |*view| view.deinit();
        if (self.view_budget) |budget| a.destroy(budget);
        if (self.derived_view) |*view| view.deinit();
        if (self.derived_budget) |budget| a.destroy(budget);
        if (self.symbols) |symbols| a.free(symbols);
        a.free(self.path);
        a.destroy(self);
    }
    pub fn status(self: *const Job) Status {
        const done = self.done.load(.acquire);
        return .{ .id = self.id, .kind = @tagName(self.kind), .path = self.path, .done = done, .cancel_requested = self.progress.cancel.load(.acquire), .phase = @tagName(self.progress.phase.load(.acquire)), .completed_units = self.progress.units.load(.acquire), .error_name = if (done and self.failure != null) @errorName(self.failure.?) else null, .publication = if (done) self.publication else null, .frame_attachments = if (done and self.publication != null and self.publication.?.state == .published) self.attachment_save else null };
    }
};
pub const Status = struct { id: u64, kind: []const u8, path: []const u8, done: bool, cancel_requested: bool, phase: []const u8, completed_units: usize, error_name: ?[]const u8, publication: ?archive.Publication, frame_attachments: ?@import("../frames/state.zig").AttachmentSave };
