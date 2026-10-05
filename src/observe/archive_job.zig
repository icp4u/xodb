//! Cancellable save/open work. The session pins save sources and publishes an
//! opened capture only after the worker's release/acquire handoff.
const std = @import("std");
const archive = @import("archive.zig");
const model = @import("capture.zig");
const a = std.heap.page_allocator;
pub const Job = struct {
    id: u64,
    kind: enum { save, open },
    path: [:0]u8,
    source: ?*const model.Capture = null,
    capture: ?*model.Capture = null,
    worker: ?std.Thread = null,
    progress: archive.Progress = .{},
    done: std.atomic.Value(bool) = .init(false),
    reaped: bool = false,
    publication: ?archive.Publication = null,
    digest: ?[64]u8 = null,
    err: ?anyerror = null,
    pub fn start(id: u64, kind: @FieldType(Job, "kind"), path: []const u8, source: ?*const model.Capture) !*Job {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.ArchivePathInvalid;
        if (kind == .save and (source == null or !source.?.store.finished or source.?.ended_ns == null)) return error.ObservationStillCollecting;
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .id = id, .kind = kind, .path = try a.dupeZ(u8, path), .source = source };
        errdefer a.free(self.path);
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    pub fn evidence(capture: *const model.Capture) archive.Evidence {
        return .{
            .metadata = .{ .identity = capture.identity, .config = capture.config, .producer = capture.producer, .threads = capture.threads, .functions = capture.functions, .started_ns = capture.started_ns, .ended_ns = capture.ended_ns.?, .stop_reason = capture.stop_reason, .finish_reason = capture.store.finish_reason.?, .recipe_json = capture.recipe_json, .comparison_selection = capture.comparison_selection },
            .records = capture.store.records.items,
            .calls = capture.store.calls.items,
            .first_gap = capture.store.first_gap,
            .unread_possible = capture.store.unread_possible,
            .rejected = capture.store.rejected,
        };
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        if (self.kind == .save) {
            self.publication = try archive.save(a, self.path, evidence(self.source.?), &self.progress);
            if (self.publication.?.state == .published) self.digest = self.publication.?.sha256;
            return;
        }
        const opened = try archive.open(a, self.path, &self.progress);
        defer opened.deinit();
        const saved = opened.evidence();
        const m = saved.metadata;
        const capture = try model.Capture.create(a, m.identity, m.config, m.threads, m.functions);
        errdefer capture.deinit();
        capture.producer = m.producer;
        capture.started_ns = m.started_ns;
        capture.ended_ns = m.ended_ns;
        capture.stop_reason = m.stop_reason;
        capture.offline = true;
        if (m.recipe_json) |json| capture.recipe_json = try capture.arena.allocator().dupe(u8, json);
        capture.comparison_selection = m.comparison_selection;
        for (saved.records, 0..) |record, i| {
            if (i % 256 == 0) try self.progress.step(.decoding, i);
            try capture.feed(record.event);
        }
        capture.store.finish(m.finish_reason);
        capture.store.rejected = saved.rejected;
        capture.store.unread_possible = saved.unread_possible;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(opened.bytes, &digest, .{});
        self.digest = std.fmt.bytesToHex(digest, .lower);
        try self.progress.step(.complete, saved.records.len);
        self.capture = capture;
    }
    pub fn status(self: *const Job) struct { id: u64, kind: @FieldType(Job, "kind"), path: []const u8, state: enum { running, completed, cancelled, failed }, phase: @import("../profile/archive_progress.zig").Phase, units: usize, error_name: ?[]const u8, publication: ?archive.Publication, sha256: ?[]const u8 } {
        const done = self.done.load(.acquire);
        const failed = done and (self.err != null or (self.publication != null and self.publication.?.state != .published));
        const cancelled = done and ((if (self.err) |err| err == error.ArchiveCancelled else false) or (if (self.publication) |p| p.state != .published and p.error_name != null and std.mem.eql(u8, p.error_name.?, "ArchiveCancelled") else false));
        return .{ .id = self.id, .kind = self.kind, .path = self.path, .state = if (!done) .running else if (cancelled) .cancelled else if (failed) .failed else .completed, .phase = self.progress.phase.load(.acquire), .units = self.progress.units.load(.acquire), .error_name = if (done) (if (self.err) |err| @errorName(err) else if (self.publication) |p| p.error_name else null) else null, .publication = if (done) self.publication else null, .sha256 = if (done and self.digest != null) &self.digest.? else null };
    }
    pub fn deinit(self: *Job) void {
        self.progress.cancel.store(true, .release);
        if (self.worker) |worker| worker.join();
        if (self.capture) |capture| capture.deinit();
        a.free(self.path);
        a.destroy(self);
    }
};
