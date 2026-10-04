//! An immutable input and a cancellable worker for recorded callchain views.
//! The source capture pins immutable ELF bytes until this job is joined. Mutable
//! arrays, labels and caches belong to the input; published labels are detached.
const std = @import("std");
const model = @import("capture.zig");
const flame = @import("flame.zig");
const modules = @import("../model/modules.zig");
const Budget = @import("archive_budget.zig").Budget;
const Capture = model.Capture;
const a = std.heap.page_allocator;
pub const memory_limit = 96 * 1024 * 1024;
pub const algorithm = "xodb-recorded-view-v1";
pub const Key = struct {
    session_id: u64,
    capture_id: u64,
    revision: u64,
    filter: model.Filter,
    pub fn of(capture: *const Capture, filter: model.Filter) Key {
        return .{ .session_id = capture.session_id, .capture_id = capture.id, .revision = capture.revision, .filter = filter };
    }
    pub fn viewId(self: Key) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(algorithm);
        for ([_]u64{ self.session_id, self.capture_id, self.revision, self.filter.tid orelse 0, self.filter.from_ns, self.filter.to_ns }) |n| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, n, .little);
            hash.update(&bytes);
        }
        self.filter.tids.hashInto(&hash);
        return std.fmt.bytesToHex(hash.finalResult(), .lower);
    }
    pub fn eql(self: Key, other: Key) bool {
        return std.meta.eql(self, other);
    }
};
pub const Result = struct {
    key: Key,
    sample_count: usize,
    mapping_revision: u64,
    trusted_before_ns: u64,
    snapshot_ns: u64,
    build_ns: u64,
    peak_bytes: usize,
    graph: flame.Graph,
    budget: *Budget,
    pub fn deinit(self: *Result) void {
        self.graph.deinit();
        a.destroy(self.budget);
    }
};
pub const Job = struct {
    id: u64,
    owner: enum { gui, mcp } = .mcp,
    key: Key,
    source: *Capture,
    /// Set by the session when a new capture replaces source. Release after join.
    owns_source: bool = false,
    input: ?*Capture,
    budget: ?*Budget,
    sample_count: usize,
    mapping_revision: u64,
    trusted_before_ns: u64,
    snapshot_ns: u64,
    build_ns: u64 = 0,
    graph: ?flame.Graph = null,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    failure: ?anyerror = null,
    pub fn create(id: u64, capture: *Capture, filter: model.Filter) !*Job {
        try capture.validateFilter(filter);
        const started = now();
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const budget = try a.create(Budget);
        errdefer a.destroy(budget);
        budget.* = .{ .backing = a, .limit = memory_limit };
        const input = snapshot(budget.allocator(), capture) catch |err| return if (budget.denied) error.ProfileViewMemoryLimit else err;
        self.* = .{ .id = id, .key = Key.of(capture, filter), .source = capture, .input = input, .budget = budget, .sample_count = capture.samples.len(), .mapping_revision = capture.mapping_revision, .trusted_before_ns = capture.trusted_before_ns, .snapshot_ns = now() - started };
        return self;
    }
    pub fn start(self: *Job) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    fn run(self: *Job) void {
        const started = now();
        self.execute() catch |err| {
            self.failure = err;
        };
        self.build_ns = now() - started;
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        const input = self.input.?;
        defer {
            input.deinit();
            self.input = null;
        }
        const budget = self.budget.?;
        var graph = input.graphWithCancel(budget.allocator(), self.key.filter, &self.cancel) catch |err| return if (budget.denied) error.ProfileViewMemoryLimit else err;
        errdefer graph.deinit();
        if (self.cancel.load(.acquire)) return error.ArchiveCancelled;
        graph.ownLabels() catch |err| return if (budget.denied) error.ProfileViewMemoryLimit else err;
        if (self.cancel.load(.acquire)) return error.ArchiveCancelled;
        self.graph = graph;
    }
    pub fn join(self: *Job) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    /// Only consume after acquire(done); joining an already finished thread is cheap.
    pub fn take(self: *Job) ?Result {
        std.debug.assert(self.done.load(.acquire));
        self.join();
        const graph = self.graph orelse return null;
        const budget = self.budget.?;
        self.graph = null;
        self.budget = null;
        return .{ .key = self.key, .sample_count = self.sample_count, .mapping_revision = self.mapping_revision, .trusted_before_ns = self.trusted_before_ns, .snapshot_ns = self.snapshot_ns, .build_ns = self.build_ns, .peak_bytes = budget.peak, .graph = graph, .budget = budget };
    }
    /// A running join is reserved for shutdown. Event-loop replacement cancels
    /// and polls done before destruction; owns_source pins the old capture.
    pub fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        self.join();
        if (self.input) |input| input.deinit();
        if (self.graph) |*graph| graph.deinit();
        if (self.budget) |budget| a.destroy(budget);
        if (self.owns_source) self.source.deinit();
        a.destroy(self);
    }
};
fn now() u64 {
    return @import("../target/linux.zig").now();
}
fn frameCopy(allocator: std.mem.Allocator, frame: flame.Frame) !flame.Frame {
    var out = frame;
    out.name = try allocator.dupe(u8, frame.name);
    out.module = try allocator.dupe(u8, frame.module);
    out.mapping_note = try allocator.dupe(u8, frame.mapping_note);
    return out;
}
/// Read only on the event loop. ELF bytes remain borrowed, never lazy debug
/// handles. The caller must pin source until snapshot destruction.
pub fn snapshot(allocator: std.mem.Allocator, source: *const Capture) !*Capture {
    const copy = try allocator.create(Capture);
    copy.* = .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator), .id = source.id, .session_id = source.session_id, .generation = source.generation, .image_epoch = source.image_epoch, .pid = source.pid, .started_ns = source.started_ns, .ended_ns = source.ended_ns, .observed_until_ns = source.observed_until_ns, .config = source.config, .accepted = source.accepted, .thread_count = source.thread_count, .collector = null, .images = modules.Modules.init(allocator), .offline = source.offline, .revision = source.revision, .mapping_revision = source.mapping_revision, .trusted_before_ns = source.trusted_before_ns };
    errdefer copy.deinit();
    copy.config.tids = &.{};
    @memcpy(copy.threads[0..source.thread_count], source.threads[0..source.thread_count]);
    @memcpy(copy.thread_names[0..source.thread_count], source.thread_names[0..source.thread_count]);
    copy.samples = try source.samples.clone(allocator);
    try copy.history.entries.appendSlice(allocator, source.history.entries.items);
    copy.history.opening_count = source.history.opening_count;
    try copy.history.changes.appendSlice(allocator, source.history.changes.items);
    const strings = copy.arena.allocator();
    for (copy.history.entries.items) |*entry| entry.path = try strings.dupe(u8, entry.path);
    try copy.images.loaded.ensureTotalCapacity(allocator, source.images.loaded.items.len);
    for (source.images.loaded.items) |image| {
        if (!image.immutable) return error.ProfileViewMutableImage;
        const path = try allocator.dupeZ(u8, image.path);
        errdefer allocator.free(path);
        const private = try allocator.create(modules.Module);
        // Deliberately read only immutable fields; archive/source workers may
        // have initialized image.debug concurrently.
        private.* = .{ .id = image.id, .inode = image.inode, .device_major = image.device_major, .device_minor = image.device_minor, .path = path, .image = image.image, .bias = image.bias, .start = image.start, .end = image.end, .mapping = image.mapping, .file_offset = image.file_offset, .owns_mapping = false, .immutable = true, .debug_allocator = allocator };
        copy.images.loaded.appendAssumeCapacity(private);
    }
    var records = source.recorded.iterator();
    while (records.next()) |entry| try copy.recorded.put(allocator, entry.key_ptr.*, .{ .frame = try frameCopy(strings, entry.value_ptr.frame) });
    return copy;
}

/// Event-loop owned coordinator: only finished jobs may be joined during poll.
/// One published view and one job; MCP reads never rebuild or clone the graph.
pub const State = struct {
    job: ?*Job = null,
    result: ?Result = null,
    failure: ?struct { key: Key, err: anyerror } = null,
    next_job: u64 = 1,
    serial: u64 = 0,

    pub fn deinit(self: *State) void {
        if (self.job) |job| job.deinit();
        if (self.result) |*result| result.deinit();
        self.* = .{};
    }
    pub fn poll(self: *State, current: ?*Capture) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.join();
        defer {
            job.deinit();
            self.job = null;
            self.serial += 1;
        }
        if (job.cancel.load(.acquire) or job.owns_source or current != job.source) return;
        if (job.take()) |result| {
            if (self.result) |*old| old.deinit();
            self.result = result;
            self.failure = null;
        } else if (job.failure) |err| self.failed(job.key, err);
    }
    fn failed(self: *State, key: Key, err: anyerror) void {
        self.failure = .{ .key = key, .err = err };
        self.serial += 1;
        std.debug.print("xodb: recorded flame view failed: {s}; capture={d} revision={d}; change filter or explicitly retry\n", .{ @errorName(err), key.capture_id, key.revision });
    }
    pub fn retained(self: *const State, key: Key) bool {
        if (self.failure) |failure| if (failure.key.eql(key)) return true;
        if (self.result) |result| if (result.key.eql(key)) return true;
        if (self.job) |job| if (job.key.eql(key) and !job.cancel.load(.acquire)) return true;
        return false;
    }
    pub fn request(self: *State, capture: *Capture, revision: u64, filter: model.Filter, retry: bool) !*const Result {
        self.poll(capture);
        try capture.validateFilter(filter);
        var key = Key.of(capture, filter);
        key.revision = revision;
        if (self.result) |*result| if (result.key.eql(key)) return result;
        if (self.job) |job| if (job.key.eql(key) and !job.cancel.load(.acquire)) return error.ProfileViewPending;
        if (self.failure) |failure| if (failure.key.eql(key) and !retry) return failure.err;
        if (revision != capture.revision) return error.StaleProfile;
        if (self.failure) |failure| if (failure.key.capture_id == capture.id and std.meta.eql(failure.key.filter, filter)) {
            if (!retry) return failure.err;
            self.failure = null;
        };
        if (self.job) |job| {
            // An explicit filter change supersedes pending work; retry with the
            // then-current revision once cancellation completes. No snapshot
            // has been accepted for this key yet.
            if (!std.meta.eql(job.key.filter, filter) or job.key.capture_id != capture.id) job.cancel.store(true, .release);
            return error.ProfileViewBusy;
        }
        const job = Job.create(self.next_job, capture, filter) catch |err| {
            self.failed(key, err);
            return err;
        };
        job.start() catch |err| {
            job.deinit();
            self.failed(key, err);
            return err;
        };
        self.job = job;
        self.failure = null;
        self.next_job += 1;
        self.serial += 1;
        return error.ProfileViewPending;
    }
    /// Transfer the old source to its worker, or free it immediately. Safe even
    /// when a previous retired source is still pinned by the sole job.
    pub fn retire(self: *State, capture: *Capture) void {
        if (self.result) |*result| result.deinit();
        self.result = null;
        self.failure = null;
        self.serial += 1;
        if (self.job) |job| if (job.source == capture) {
            job.cancel.store(true, .release);
            job.owns_source = true;
            return;
        };
        capture.deinit();
    }
};
