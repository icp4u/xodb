//! Cancellable save/open work. The session pins save sources and publishes an
//! opened capture only after the worker's release/acquire handoff.
const std = @import("std");
const archive = @import("archive.zig");
const model = @import("capture.zig");
const a = std.heap.page_allocator;
const associations = @import("association_job.zig");
pub const Job = struct {
    id: u64,
    kind: enum { save, open },
    path: [:0]u8,
    source: ?*const model.Capture = null,
    capture: ?*model.Capture = null,
    association_source: ?*const associations.Job = null,
    associations_omitted_reason: ?[]const u8 = null,
    associations_saved: bool = false,
    associations_fallback_reason: ?[]const u8 = null,
    restored_associations: ?*associations.Job = null,
    worker: ?std.Thread = null,
    progress: archive.Progress = .{},
    done: std.atomic.Value(bool) = .init(false),
    reaped: bool = false,
    publication: ?archive.Publication = null,
    digest: ?[64]u8 = null,
    err: ?anyerror = null,
    pub fn start(id: u64, kind: @FieldType(Job, "kind"), path: []const u8, source: ?*const model.Capture, associated: ?*const associations.Job) !*Job {
        if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.ArchivePathInvalid;
        if (kind == .save and (source == null or !source.?.store.finished or source.?.ended_ns == null)) return error.ObservationStillCollecting;
        var omitted: ?[]const u8 = null;
        var fallback: ?[]const u8 = null;
        if (associated) |job| {
            if (kind != .save or source != job.capture) return error.InvalidSavedAssociations;
            if (!job.done.load(.acquire)) return error.ObservationAssociationsBusy;
            if (job.err) |err| {
                if (source.?.saved_associations != null) fallback = @errorName(err) else omitted = @errorName(err);
            } else try associations.saved_evidence.limits(try job.view());
        }
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .id = id, .kind = kind, .path = try a.dupeZ(u8, path), .source = source, .association_source = if (omitted == null and fallback == null) associated else null, .associations_omitted_reason = omitted, .associations_fallback_reason = fallback };
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
            self.err = if (err == error.ObservationAnalysisCancelled) error.ArchiveCancelled else err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        if (self.kind == .save) {
            var saved = evidence(self.source.?);
            if (self.associations_omitted_reason == null) {
                if (self.association_source) |job| saved.associations = try job.view() else if (self.source.?.saved_associations) |owned| saved.associations = owned.snapshot;
            }
            self.publication = try archive.save(a, self.path, saved, &self.progress);
            if (self.publication.?.state == .published) {
                self.digest = self.publication.?.sha256;
                self.associations_saved = saved.associations != null;
            }
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
        var restored: ?*associations.Job = null;
        errdefer if (restored) |job| job.deinit();
        if (saved.associations) |view| {
            capture.saved_associations = try associations.saved_evidence.Owned.create(a, view);
            // Replay in this worker; only completed, validated jobs reach owner.
            restored = try associations.Job.fromSaved(0, capture, view.selection, true, &self.progress.cancel);
        }
        try self.progress.step(.complete, saved.records.len);
        self.restored_associations = restored;
        self.capture = capture;
    }
    pub fn status(self: *const Job) struct { id: u64, kind: @FieldType(Job, "kind"), path: []const u8, state: enum { running, completed, cancelled, failed }, phase: @import("../profile/archive_progress.zig").Phase, units: usize, error_name: ?[]const u8, publication: ?archive.Publication, sha256: ?[]const u8, associations_saved: ?bool, associations_omitted_reason: ?[]const u8, associations_fallback_reason: ?[]const u8 } {
        const done = self.done.load(.acquire);
        const failed = done and (self.err != null or (self.publication != null and self.publication.?.state != .published));
        const cancelled = done and ((if (self.err) |err| err == error.ArchiveCancelled else false) or (if (self.publication) |p| p.state != .published and p.error_name != null and std.mem.eql(u8, p.error_name.?, "ArchiveCancelled") else false));
        return .{ .associations_saved = if (done and self.kind == .save) self.associations_saved else null, .associations_omitted_reason = self.associations_omitted_reason, .associations_fallback_reason = self.associations_fallback_reason, .id = self.id, .kind = self.kind, .path = self.path, .state = if (!done) .running else if (cancelled) .cancelled else if (failed) .failed else .completed, .phase = self.progress.phase.load(.acquire), .units = self.progress.units.load(.acquire), .error_name = if (done) (if (self.err) |err| @errorName(err) else if (self.publication) |p| p.error_name else null) else null, .publication = if (done) self.publication else null, .sha256 = if (done and self.digest != null) &self.digest.? else null };
    }
    pub fn deinit(self: *Job) void {
        self.progress.cancel.store(true, .release);
        if (self.worker) |worker| worker.join();
        if (self.restored_associations) |job| job.deinit();
        if (self.capture) |capture| capture.deinit();
        a.free(self.path);
        a.destroy(self);
    }
};
