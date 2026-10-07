//! One bounded worker per session. Completed sources are immutable; replacement,
//! aggregate selection and saves cannot race one another or archive attachment.
const std = @import("std");
pub const model = @import("model.zig");
const c = model.c;
const archive = @import("../profile/archive.zig");
const a = std.heap.page_allocator;
pub const Encoded = struct {
    ptr: [*c]u8,
    len: usize,
    pub fn bytes(self: Encoded) []const u8 {
        return self.ptr[0..self.len];
    }
    pub fn deinit(self: Encoded) void {
        c.free(self.ptr);
    }
};
pub const AttachmentSave = struct {
    retained: ?usize = 0,
    added: usize = 0,
    removed: usize = 0,
    opaque_preserved: bool = false,
};
pub const Attachment = struct {
    pub const SourceReport = struct { source_id: []const u8, sha256: []const u8, kind: model.Kind, input_bytes: usize };
    state: enum { none, pending, restored, not_loaded, unavailable, unsupported_version } = .none,
    failure: ?anyerror = null,
    source_count: ?usize = null,
    ids: [model.max_sources][64]u8 = undefined,
    digests: [model.max_sources][64]u8 = undefined,
    reports: [model.max_sources]SourceReport = undefined,
    input_bytes: ?usize = null,
    pub fn status(self: *const Attachment) struct { state: @FieldType(Attachment, "state"), error_name: ?[]const u8, source_count: ?usize, input_bytes: ?usize, sources: []const SourceReport } {
        return .{ .state = self.state, .error_name = if (self.failure) |err| @errorName(err) else null, .source_count = self.source_count, .input_bytes = self.input_bytes, .sources = self.reports[0..(self.source_count orelse 0)] };
    }
    fn fail(self: *Attachment, err: anyerror) void {
        self.failure = err;
        self.state = if (err == error.FrameVersionUnsupported) .unsupported_version else .unavailable;
    }
};
pub const Job = struct {
    kind: enum { import, restore, aggregate, save, jit },
    cancel: *c.struct_xlf_cancel,
    jit_cancel: c.struct_xodb_jit_cancel = .{ .requested = 0 },
    declaration: ?[]u8 = null,
    capture: ?*@import("../profile/capture.zig").Capture = null,
    context: @import("jit.zig").Context = undefined,
    sample_start: usize = 0,
    sample_count: usize = 1,
    jit_result: ?*@import("jit.zig").View = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    diagnostic: c.struct_xlf_error = std.mem.zeroes(c.struct_xlf_error),
    owner: *State,
    path: ?[:0]u8 = null,
    source_kind: model.Kind = .logical,
    jvm_kind: ?u32 = null,
    selected_thread: ?u32 = null,
    index: usize = 0,
    replace: bool = false,
    archive_restore: bool = false,
    input: ?[]u8 = null,
    created: [model.max_sources]?*model.Source = @splat(null),
    count: usize = 0,
    result: ?model.Aggregate = null,
    publication: ?archive.Publication = null,
    fn execute(self: *Job) !void {
        try model.poll(self.cancel);
        const owner = self.owner;
        switch (self.kind) {
            .import => {
                const source = try model.Source.create(self.source_kind, model.memory_limit - owner.retained());
                self.created[0] = source;
                self.count = 1;
                source.metadata.jvm_kind = self.jvm_kind;
                if (self.declaration) |bytes| {
                    const parsed = try std.json.parseFromSlice(@import("jit.zig").Declaration, source.arena.allocator(), bytes, .{ .allocate = .alloc_always });
                    source.metadata.jit = parsed.value;
                    source.metadata.algorithm = "xodb-jit-code-lifetime/3";
                }
                const replaced = if (self.replace) owner.sources[self.index].?.input.size else 0;
                try source.read(self.path.?, model.max_input - (owner.inputBytes() - replaced), self.cancel);
                try source.decode(self.cancel, &self.jit_cancel);
            },
            .restore => {
                var input: c.struct_xfb_input = std.mem.zeroes(c.struct_xfb_input);
                defer c.xfb_input_free(&input);
                const bytes = if (self.input) |bytes| bytes else blk: {
                    try model.bundleCheck(c.xfb_read(self.path.?, c.XFB_MAX_BYTES, self.cancel, &input));
                    break :blk input.bytes[0..input.size];
                };
                var view: c.struct_xfb_view = undefined;
                try model.bundleCheck(c.xfb_decode(bytes.ptr, bytes.len, self.cancel, &view));
                var retained = owner.retained() + bytes.len;
                for (view.sources[0..view.count]) |record| {
                    const kind = std.enums.fromInt(model.Kind, record.kind) orelse return error.FrameBundleInvalid;
                    if (retained >= model.memory_limit) return error.FrameMemoryLimit;
                    const source = try model.Source.create(kind, model.memory_limit - retained);
                    self.created[self.count] = source;
                    self.count += 1;
                    try source.restore(record, self.cancel);
                    try source.decode(self.cancel, &self.jit_cancel);
                    retained += source.retained();
                }
            },
            .aggregate => {
                const source = owner.sources[self.index].?;
                const limit = source.budget.limit;
                source.budget.limit = model.memory_limit - (owner.retained() - source.budget.used);
                defer source.budget.limit = limit;
                self.result = try source.query(self.selected_thread, self.cancel);
            },
            .jit => {
                self.jit_result = try @import("jit.zig").build(owner.sources[0..owner.count], self.capture.?, self.context, owner.evidence_revision, self.sample_start, self.sample_count, model.memory_limit - owner.retained(), &self.jit_cancel);
            },
            .save => {
                const encoded = try owner.encode(self.cancel);
                defer encoded.deinit();
                try model.poll(self.cancel);
                self.publication = archive.publish(self.path.?, encoded.bytes(), null);
                if (self.publication.?.state != .published) return error.FramePublicationFailed;
            },
        }
        if (self.publication == null) try model.poll(self.cancel);
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = if (err == error.OutOfMemory) error.FrameMemoryLimit else err;
            if (self.kind == .aggregate) self.diagnostic = self.owner.sources[self.index].?.diagnostic;
            for (self.created[0..self.count]) |source| if (source.?.diagnostic.status != c.XLF_OK) {
                self.diagnostic = source.?.diagnostic;
            };
        };
        self.done.store(true, .release);
    }
    fn deinit(self: *Job) void {
        c.xlf_cancel_request(self.cancel);
        c.xodb_jit_cancel_request(&self.jit_cancel);
        if (self.thread) |thread| thread.join();
        for (self.created) |source| if (source) |s| s.deinit();
        if (self.result) |*result| result.deinit();
        if (self.jit_result) |result| result.deinit();
        if (self.declaration) |bytes| a.free(bytes);
        if (self.capture) |capture| capture.archive_busy = false;
        if (self.input) |bytes| a.free(bytes);
        if (self.path) |path| a.free(path);
        c.xlf_cancel_destroy(self.cancel);
        a.destroy(self);
    }
};
pub const State = struct {
    sources: [model.max_sources]?*model.Source = @splat(null),
    count: usize = 0,
    job: ?*Job = null,
    pinned: bool = false,
    failure: ?anyerror = null,
    /// Archive restoration failures survive unrelated frame jobs. Original
    /// source identities guard archive saves even after a workspace replacement.
    attachment: Attachment = .{},
    diagnostic: c.struct_xlf_error = std.mem.zeroes(c.struct_xlf_error),
    publication: ?archive.Publication = null,
    serial: u64 = 0,
    evidence_revision: u64 = 0,
    jit_view: ?*@import("jit.zig").View = null,
    pub fn retained(self: *const State) usize {
        // Fixed allowance covers the active job's bounded path/declaration and
        // the opaque cancellation token. C decoder and arena allocations are
        // charged separately below, including temporary aggregate copies.
        var bytes: usize = @sizeOf(State) + @sizeOf(Job) + 4096 + 1 + c.XFB_MAX_METADATA + 4096;
        for (self.sources[0..self.count]) |source| bytes += source.?.retained();
        if (self.jit_view) |view| bytes += @sizeOf(@import("jit.zig").View) + view.budget.used;
        return bytes;
    }
    pub fn inputBytes(self: *const State) usize {
        var bytes: usize = 0;
        for (self.sources[0..self.count]) |source| bytes += source.?.input.size;
        return bytes;
    }
    pub fn busy(self: *const State) bool {
        return self.job != null or self.pinned;
    }
    fn prepare(self: *State, kind: @FieldType(Job, "kind"), path: ?[]const u8) !*Job {
        self.poll();
        if (self.busy()) return error.FrameBusy;
        if (path) |p| if (p.len == 0 or p.len > 4096 or std.mem.indexOfScalar(u8, p, 0) != null) return error.FramePathInvalid;
        const job = a.create(Job) catch return error.FrameMemoryLimit;
        job.* = .{ .owner = self, .kind = kind, .cancel = c.xlf_cancel_create() orelse {
            a.destroy(job);
            return error.FrameMemoryLimit;
        } };
        errdefer job.deinit();
        if (path) |p| job.path = a.dupeZ(u8, p) catch return error.FrameMemoryLimit;
        return job;
    }
    fn start(self: *State, job: *Job) !void {
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return error.FrameWorkerUnavailable;
        self.job = job;
        self.failure = null;
        self.diagnostic = std.mem.zeroes(c.struct_xlf_error);
        self.publication = null;
        self.serial += 1;
    }
    pub fn importFile(self: *State, path: []const u8, kind: model.Kind, jvm_kind: ?u32, replace: ?usize) !void {
        if (replace) |index| {
            if (index >= self.count) return error.FrameSourceInvalid;
        } else if (self.count >= model.max_sources) return error.FrameSourceLimit;
        const job = try self.prepare(.import, path);
        errdefer job.deinit();
        job.source_kind = kind;
        job.jvm_kind = jvm_kind;
        job.index = replace orelse self.count;
        job.replace = replace != null;
        try self.start(job);
    }
    pub fn importJit(self: *State, path: []const u8, kind: model.Kind, declaration: []const u8) !void {
        if (kind != .jitdump and kind != .perfmap) return error.JitSourceInvalid;
        if (declaration.len > c.XFB_MAX_METADATA) return error.JitMetadataInvalid;
        if (self.count >= model.max_sources) return error.FrameSourceLimit;
        const job = try self.prepare(.import, path);
        errdefer job.deinit();
        job.source_kind = kind;
        job.index = self.count;
        job.declaration = a.dupe(u8, declaration) catch return error.FrameMemoryLimit;
        try self.start(job);
    }
    pub fn prepareJit(self: *State, capture: *@import("../profile/capture.zig").Capture, source: ?@import("../profile/archive.zig").Source, start_index: usize, count: usize) !void {
        if (capture.collector != null) return error.ArchiveStillCollecting;
        if (capture.archive_busy) return error.ArchiveBusy;
        const job = try self.prepare(.jit, null);
        errdefer job.deinit();
        job.capture = capture;
        capture.archive_busy = true;
        job.context = @import("jit.zig").context(capture, source);
        job.sample_start = start_index;
        job.sample_count = count;
        try self.start(job);
    }
    pub fn hasJit(self: *const State) bool {
        for (self.sources[0..self.count]) |source| if (source.?.jit_owner != null) return true;
        return false;
    }
    pub fn open(self: *State, path: []const u8) !void {
        // Extension is a declared format; JSONL is never guessed from contents.
        if (!std.mem.endsWith(u8, path, ".xof")) return self.importFile(path, .logical, null, null);
        const job = try self.prepare(.restore, path);
        errdefer job.deinit();
        try self.start(job);
    }
    pub fn restore(self: *State, bytes: []const u8) !void {
        if (bytes.len > c.XFB_MAX_BYTES) return error.FrameInputLimit;
        const job = try self.prepare(.restore, null);
        errdefer job.deinit();
        job.input = a.dupe(u8, bytes) catch return error.FrameMemoryLimit;
        try self.start(job);
    }
    pub fn restoreArchive(self: *State, bytes: []const u8) void {
        self.poll();
        self.attachment = .{ .state = .pending };
        // Do not let archive-open timing replace an explicitly imported source.
        if (self.busy() or self.count != 0) {
            self.attachment.state = .not_loaded;
            self.attachment.failure = error.ArchiveFramesNotLoaded;
            return;
        }
        self.restore(bytes) catch |err| {
            self.attachment.fail(err);
            return;
        };
        self.job.?.archive_restore = true;
    }
    pub fn archiveSave(self: *const State) !AttachmentSave {
        if (self.busy()) return error.FrameBusy;
        const original = &self.attachment;
        if (original.state == .none) return .{ .added = self.count };
        if (original.state != .restored) {
            if (self.count != 0) return error.ArchiveFrameAttachmentConflict;
            // An unavailable/unsupported attachment can still be copied intact.
            return .{ .retained = original.source_count, .opaque_preserved = true };
        }
        var matched: [model.max_sources]bool = @splat(false);
        for (original.ids[0..original.source_count.?]) |id| {
            for (self.sources[0..self.count], 0..) |source, index| {
                if (!matched[index] and std.mem.eql(u8, &source.?.id, &id)) {
                    matched[index] = true;
                    break;
                }
            } else return error.ArchiveFrameAttachmentConflict;
        }
        return .{ .retained = original.source_count, .added = self.count - original.source_count.? };
    }
    pub fn select(self: *State, index: usize, thread: ?u32) !void {
        if (index >= self.count) return error.FrameSourceInvalid;
        if (self.sources[index].?.jit_owner != null) return error.FrameSourceNotLogical;
        const job = try self.prepare(.aggregate, null);
        errdefer job.deinit();
        job.index = index;
        job.selected_thread = thread;
        try self.start(job);
    }
    pub fn save(self: *State, path: []const u8) !void {
        if (!std.mem.endsWith(u8, path, ".xof")) return error.FrameBundleExtension;
        if (self.count == 0) return error.FrameEmpty;
        const job = try self.prepare(.save, path);
        errdefer job.deinit();
        try self.start(job);
    }
    pub fn cancel(self: *State) void {
        if (self.job) |job| {
            c.xlf_cancel_request(job.cancel);
            c.xodb_jit_cancel_request(&job.jit_cancel);
        }
    }
    pub fn poll(self: *State) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.thread) |thread| thread.join();
        job.thread = null;
        if (c.xlf_cancel_requested(job.cancel) and job.publication == null) job.failure = error.FrameCancelled;
        self.failure = job.failure;
        self.diagnostic = job.diagnostic;
        if (job.archive_restore) {
            if (job.failure) |err| {
                self.attachment.fail(err);
            } else {
                self.attachment.state = .restored;
                self.attachment.source_count = job.count;
                self.attachment.input_bytes = 0;
                for (job.created[0..job.count], 0..) |source_, i| {
                    const source = source_.?;
                    self.attachment.ids[i] = source.id;
                    @memcpy(&self.attachment.digests[i], source.input.sha256[0..64]);
                    self.attachment.reports[i] = .{ .source_id = &self.attachment.ids[i], .sha256 = &self.attachment.digests[i], .kind = source.kind, .input_bytes = source.input.size };
                    self.attachment.input_bytes.? += source.input.size;
                }
            }
        }
        if (job.failure == null) switch (job.kind) {
            .import => {
                self.evidence_revision += 1;
                if (job.replace) self.sources[job.index].?.deinit() else self.count += 1;
                self.sources[job.index] = job.created[0];
                job.created[0] = null;
            },
            .restore => {
                self.evidence_revision += 1;
                for (self.sources) |source| if (source) |s| s.deinit();
                self.sources = job.created;
                self.count = job.count;
                job.created = @splat(null);
            },
            .aggregate => {
                const source = self.sources[job.index].?;
                if (source.aggregate) |*agg| agg.deinit();
                source.aggregate = job.result;
                job.result = null;
                source.metadata.selected_thread = job.selected_thread;
                source.metadata.algorithm = model.algorithm;
                source.aggregate_stale = false;
                source.selection_stale = false;
                source.metadata_changed = true;
            },
            .jit => {
                if (self.jit_view) |view| view.deinit();
                self.jit_view = job.jit_result;
                for (self.sources[0..self.count]) |source| if (source.?.jit_owner != null) {
                    source.?.metadata.algorithm = "xodb-jit-code-lifetime/3";
                    source.?.aggregate_stale = false;
                    source.?.metadata_changed = true;
                };
                job.jit_result = null;
            },
            .save => self.publication = job.publication,
        };
        job.deinit();
        self.job = null;
        self.serial += 1;
    }
    /// Caller pins State before handing it to an archive worker. Only immutable
    /// original bytes and completed selection metadata are read here.
    pub fn encode(self: *const State, cancellation: ?*c.struct_xlf_cancel) !Encoded {
        var budget = @import("../profile/archive_budget.zig").Budget{ .backing = a, .limit = model.memory_limit - self.retained() };
        var arena = std.heap.ArenaAllocator.init(budget.allocator());
        defer arena.deinit();
        var view: c.struct_xfb_view = std.mem.zeroes(c.struct_xfb_view);
        view.count = self.count;
        var encoded_bytes: usize = c.XFB_HEADER_BYTES;
        for (self.sources[0..self.count], 0..) |source, i| {
            try model.poll(cancellation);
            const s = source.?;
            const metadata = s.encodeMetadata(arena.allocator()) catch |err| return if (err == error.OutOfMemory) error.FrameMemoryLimit else err;
            if (metadata.len > c.XFB_MAX_METADATA) return error.FrameInputLimit;
            view.sources[i] = .{ .kind = @intFromEnum(s.kind), .stability = s.input.stability, .metadata = metadata.ptr, .metadata_size = metadata.len, .bytes = s.input.bytes, .size = s.input.size, .sha256 = s.input.sha256 };
            encoded_bytes += c.XFB_HEADER_BYTES + metadata.len + s.input.size;
        }
        if (encoded_bytes > budget.limit - budget.used) return error.FrameMemoryLimit;
        var encoded: Encoded = .{ .ptr = null, .len = 0 };
        try model.bundleCheck(c.xfb_encode(&view, cancellation, &encoded.ptr, &encoded.len));
        return encoded;
    }
    pub fn deinit(self: *State) void {
        if (self.job) |job| job.deinit();
        if (self.jit_view) |view| view.deinit();
        for (self.sources) |source| if (source) |s| s.deinit();
        self.* = .{};
    }
};
