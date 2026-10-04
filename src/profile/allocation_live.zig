//! One process's allocation preparation, collection and finalized evidence.
//! The session owner publishes workers only against an unchanged stopped target.
const std = @import("std");
const linux = @import("../target/linux.zig");
const modules = @import("../model/modules.zig");
const hooks = @import("allocation_hooks.zig");
const model = @import("allocation_capture.zig");
const events = @import("allocation_events.zig");
const wire = @import("allocation_perf.zig");
const perf = @import("linux_perf.zig");
const native = @import("linux_allocations.zig");
const a = std.heap.page_allocator;
const broker = @cImport({
    @cInclude("allocation_broker.h");
});

pub const Stop = enum { manual, duration, record_limit, memory_limit, evidence_gap, target_ended, thread_ended, image_changed, scope_changed, collector_error, shutdown };
pub const Config = struct {
    duration_ms: u32 = 60000,
    record_limit: u32 = events.default_records,
    memory_limit: u32 = model.default_memory_limit,
    pub fn validate(self: Config) !void {
        if (self.record_limit < 2 or self.record_limit > events.max_records or self.memory_limit < 1024 * 1024 or self.memory_limit > model.maximum_memory_limit) return error.InvalidAllocationConfig;
    }
};
pub const Context = struct {
    identity: model.Identity,
    generation: u64,
    threads: [native.max_threads]model.Thread = undefined,
    thread_count: usize,
};
const Job = struct {
    context: Context,
    region: modules.Region,
    config: Config,
    requests: [hooks.max_hooks]hooks.Request = undefined,
    request_count: usize = 0,
    helper: ?[:0]u8 = null,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    collector: ?*native.Collector = null,
    capture: ?*model.Capture = null,
    failure: ?perf.Failure = null,
    err: ?anyerror = null,
    broker_fd: c_int = -1,
    broker_pid: c_int = -1,
    fn open(ptr: *anyopaque, tid: i32, group: c_int, file: c_int, offset: u64, returning: bool, leader: bool) c_int {
        const self: *Job = @ptrCast(@alignCast(ptr));
        return broker.xodb_allocation_broker_open(self.broker_fd, self.context.identity.pid, tid, file, group, offset, @intFromBool(returning), @intFromBool(leader), cancelled, self);
    }
    fn cancelled(ptr: ?*anyopaque) callconv(.c) c_int {
        const self: *Job = @ptrCast(@alignCast(ptr.?));
        return @intFromBool(self.cancel.load(.acquire));
    }
    fn create(context_: Context, config: Config, region: modules.Region, requests: []const hooks.Request, helper: ?[:0]const u8) !*Job {
        if (requests.len == 0 or requests.len > hooks.max_hooks) return error.InvalidAllocationHooks;
        const self = try a.create(Job);
        self.* = .{ .context = context_, .region = region, .config = config };
        self.region.path = a.dupe(u8, region.path) catch |err| {
            a.destroy(self);
            return err;
        };
        errdefer self.deinit();
        for (requests) |request| {
            self.requests[self.request_count] = request;
            self.requests[self.request_count].name = try a.dupe(u8, request.name);
            self.request_count += 1;
        }
        if (helper) |path| self.helper = try a.dupeZ(u8, path);
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        var prepared = try hooks.prepare(self.context.identity.pid, self.region, self.requests[0..self.request_count], hooks.image_limit, &self.cancel);
        defer prepared.close();
        var tids: [native.max_threads]i32 = undefined;
        for (self.context.threads[0..self.context.thread_count], 0..) |thread, i| tids[i] = thread.tid;
        if (self.helper) |path| {
            if (broker.xodb_allocation_broker_start(path, &self.broker_fd, &self.broker_pid) != 0) return error.AllocationHelperStart;
        }
        defer {
            broker.xodb_allocation_broker_close(self.broker_fd, self.broker_pid);
            self.broker_fd = -1;
            self.broker_pid = -1;
        }
        const opened = try native.start(a, .{
            .pid = self.context.identity.pid,
            .tids = tids[0..self.context.thread_count],
            .sources = prepared.sources[0..prepared.count],
            .enable = false,
            .cancel = &self.cancel,
            .opener = if (self.helper != null) .{ .user = self, .call = open } else null,
        });
        switch (opened) {
            .failed => |failure| {
                self.failure = failure;
                return error.AllocationCollectorOpen;
            },
            .collector => |collector| self.collector = collector,
        }
        var described: [hooks.max_hooks]model.Hook = undefined;
        for (prepared.sources[0..prepared.count], prepared.locations[0..prepared.count], self.requests[0..prepared.count], 0..) |source, location, request, i| {
            described[i] = .{ .id = source.id, .kind = source.kind, .name = request.name, .path = self.region.path, .device = source.identity.device, .inode = source.identity.inode, .file_offset = source.offset, .link_address = location.link_address, .runtime_address = location.runtime_address };
        }
        self.capture = try model.Capture.create(a, self.context.identity, .{ .record_limit = self.config.record_limit, .memory_limit = self.config.memory_limit }, self.context.threads[0..self.context.thread_count], described[0..prepared.count], 0);
    }
    fn deinit(self: *Job) void {
        self.cancel.store(true, .release);
        if (self.worker) |thread| thread.join();
        if (self.collector) |collector| collector.close();
        if (self.capture) |capture| capture.deinit();
        for (self.requests[0..self.request_count]) |request| a.free(request.name);
        a.free(self.region.path);
        if (self.helper) |path| a.free(path);
        a.destroy(self);
    }
};

// unregistering uprobes can wait for kernel grace periods; never close all
// descriptors on the GUI/MCP event loop during normal completion.
const Cleanup = struct {
    collector: *native.Collector,
    worker: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    fn run(self: *Cleanup) void {
        self.collector.close();
        self.done.store(true, .release);
    }
    fn create(collector: *native.Collector) !*Cleanup {
        const self = try a.create(Cleanup);
        errdefer a.destroy(self);
        self.* = .{ .collector = collector };
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn deinit(self: *Cleanup) void {
        self.worker.?.join();
        a.destroy(self);
    }
};
pub const Live = struct {
    capture: ?*model.Capture = null,
    collector: ?*native.Collector = null,
    job: ?*Job = null,
    cleanup: ?*Cleanup = null,
    next_id: u64 = 1,
    serial: u64 = 0,
    config: Config = .{},
    reason: ?Stop = null,
    stopped_ns: ?u64 = null,
    unread: bool = false,
    failure: ?perf.Failure = null,
    err: ?anyerror = null,
    pub fn preparing(self: *const Live) bool {
        return self.job != null;
    }
    pub fn collecting(self: *const Live) bool {
        return self.collector != null or self.cleanup != null;
    }
    pub fn start(self: *Live, context_: Context, config: Config, region: modules.Region, requests: []const hooks.Request, helper: ?[:0]const u8) !void {
        try config.validate();
        if (linux.architecture != .x86_64) return error.UnsupportedAllocationArchitecture;
        if (self.job != null or self.collecting()) return error.AllocationBusy;
        if (context_.thread_count == 0 or context_.thread_count > native.max_threads) return error.InvalidAllocationThreads;
        if (self.capture) |capture| {
            capture.poll();
            if (capture.worker != null) return error.AllocationAnalysisBusy;
        }
        var context = context_;
        context.identity.capture_id = self.next_id;
        self.job = try Job.create(context, config, region, requests, helper);
        self.next_id += 1;
        self.serial += 1;
        self.err = null;
        self.failure = null;
    }
    pub fn pendingContext(self: *const Live) ?Context {
        return if (self.job) |job| job.context else null;
    }
    pub fn stop(self: *Live, reason: Stop) void {
        if (self.job) |job| {
            job.cancel.store(true, .release);
            self.serial += 1;
        }
        const collector = self.collector orelse return;
        if (self.reason != null) return;
        self.serial += 1;
        self.reason = reason;
        if (collector.stop()) |failure| {
            self.failure = failure;
            self.unread = true;
        }
        self.stopped_ns = linux.now();
        if (reason == .image_changed or reason == .scope_changed or reason == .collector_error) self.capture.?.abort(.identity);
        std.debug.print("xodb: allocation capture {d} stop={s}\n", .{ self.capture.?.identity.capture_id, @tagName(reason) });
    }
    fn complete(self: *Live) void {
        self.serial += 1;
        if (self.collector) |collector| {
            self.cleanup = Cleanup.create(collector) catch |err| blk: {
                // Resource exhaustion still needs deterministic descriptor
                // cleanup; report the exceptional synchronous fallback.
                std.debug.print("xodb: allocation cleanup worker failed: {s}; closing synchronously\n", .{@errorName(err)});
                collector.close();
                break :blk null;
            };
            self.collector = null;
            if (self.cleanup != null) {
                self.capture.?.state = .stopping;
                return;
            }
        }
        const capture = self.capture orelse return;
        capture.finish(@max(self.stopped_ns orelse linux.now(), capture.observed_until_ns), self.unread) catch |err| {
            self.err = err;
            return;
        };
        capture.requestAnalysis(false) catch {};
    }
    /// `pending_valid` is computed on the session owner from stop/image/thread
    /// identities. Preparation may never publish a capture against a new stop.
    pub fn poll(self: *Live, pending_valid: bool, boundary: ?Stop) void {
        if (self.capture) |capture| capture.poll();
        if (self.cleanup) |cleanup| if (cleanup.done.load(.acquire)) {
            cleanup.deinit();
            self.cleanup = null;
            self.complete();
        };
        if (self.job) |job| if (job.done.load(.acquire)) {
            self.serial += 1;
            if (self.capture) |old| if (old.worker != null) return;
            defer {
                job.deinit();
                self.job = null;
            }
            self.err = if (job.cancel.load(.acquire)) error.AllocationPreparationCancelled else job.err orelse if (!pending_valid) error.StaleAllocationPreparation else null;
            self.failure = job.failure;
            if (self.err == null) {
                const candidate = job.capture.?;
                const collector = job.collector.?;
                candidate.started_ns = linux.now();
                candidate.observed_until_ns = candidate.started_ns;
                if (collector.enable()) |failure| {
                    self.failure = failure;
                    self.err = error.AllocationEnable;
                } else {
                    if (self.capture) |old| old.deinit();
                    self.capture = candidate;
                    job.capture = null;
                    self.collector = collector;
                    job.collector = null;
                    self.config = job.config;
                    self.reason = null;
                    self.stopped_ns = null;
                    self.unread = false;
                    std.debug.print("xodb: allocation capture {d} started: {d} threads, {d} hooks\n", .{ candidate.identity.capture_id, candidate.thread_count, candidate.hook_count });
                }
            }
            if (self.err) |err| {
                std.debug.print("xodb: allocation preparation failed: {s}\n", .{@errorName(err)});
                if (self.failure) |failure| std.debug.print("xodb: allocations: syscall={s} errno={d} tid={d}; {s}\n", .{ failure.syscall, failure.errno, failure.tid, failure.detail });
            }
        };
        const collector = self.collector orelse return;
        const capture = self.capture.?;
        if (boundary) |reason| self.stop(reason);
        if (self.reason == null and self.config.duration_ms > 0 and linux.now() -| capture.started_ns >= @as(u64, self.config.duration_ms) * 1000000) self.stop(.duration);
        var items: [256]native.Item = undefined;
        const drained = collector.drain(&items);
        for (items[0..drained.count]) |item| {
            if (capture.store.finished) {
                self.unread = true;
                break;
            }
            const raw = item.record;
            const event: ?events.Event = switch (raw.data) {
                .sample => wire.normalizedSample(raw) catch blk: {
                    capture.abort(.decode_error);
                    self.unread = true;
                    break :blk null;
                },
                .lost => |n| .{ .time_ns = raw.time_ns, .data = .{ .lost = n } },
                .throttle => .{ .time_ns = raw.time_ns, .data = .throttle },
                .unthrottle => .{ .time_ns = raw.time_ns, .data = .unthrottle },
                .thread_exit => .{ .time_ns = raw.time_ns, .data = .thread_exit },
                .exec => .{ .time_ns = raw.time_ns, .data = .exec },
                .fork => blk: {
                    capture.abort(.identity);
                    self.stop(.scope_changed);
                    break :blk null;
                },
                .rename => null,
            };
            if (event) |value| capture.feed(item.lane, value) catch |err| {
                self.err = err;
                self.unread = true;
            };
            if (raw.data == .exec) self.stop(.image_changed);
            if (raw.data == .thread_exit) self.stop(.thread_ended);
        }
        if (drained.failure) |failure| {
            self.failure = failure;
            self.unread = true;
            capture.abort(.decode_error);
            self.stop(.collector_error);
            self.complete();
            return;
        }
        if (capture.store.finished) {
            self.unread = self.unread or drained.more;
            self.stop(if ((if (self.err) |err| err == error.AllocationRecordLimit else false)) .record_limit else if ((if (self.err) |err| err == error.OutOfMemory else false)) .memory_limit else if (capture.store.first_gap) |gap| switch (gap.reason) {
                .memory_limit => .memory_limit,
                .record_limit => .record_limit,
                else => .evidence_gap,
            } else .record_limit);
            self.complete();
            return;
        }
        if (self.reason != null and !drained.more) self.complete();
    }
    pub fn deinit(self: *Live) void {
        self.stop(.shutdown);
        if (self.job) |job| job.deinit();
        if (self.cleanup) |cleanup| cleanup.deinit();
        if (self.collector) |collector| collector.close();
        if (self.capture) |capture| capture.deinit();
        self.* = .{};
    }
};

test "allocation preparation cancellation and stale completion preserve retained evidence" {
    const model_threads = [_]model.Thread{.{ .id = 1, .tid = 1 }};
    const model_hooks = [_]model.Hook{.{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture", .device = 1, .inode = 1, .file_offset = 1, .link_address = 1, .runtime_address = 1 }};
    var live = Live{};
    defer live.deinit();
    live.capture = try model.Capture.create(a, .{ .session_id = 1, .capture_id = 1, .process_id = 1, .pid = 1, .image_epoch = 1 }, .{}, &model_threads, &model_hooks, 1);
    try live.capture.?.finish(2, false);
    const old = live.capture.?;
    for ([_]bool{ false, true }) |cancel| {
        const job = try a.create(Job);
        job.* = .{
            .context = .{ .identity = old.identity, .generation = 1, .thread_count = 1 },
            .config = .{},
            .region = .{ .start = 0, .end = 1, .offset = 0, .inode = 1, .device_major = 0, .device_minor = 0, .permissions = "r-xp".*, .path = try a.dupe(u8, "/fixture") },
        };
        live.job = job;
        if (cancel) live.stop(.manual);
        job.done.store(true, .release);
        live.poll(false, null);
        try std.testing.expect(live.job == null and live.capture.? == old);
        try std.testing.expectEqual(if (cancel) error.AllocationPreparationCancelled else error.StaleAllocationPreparation, live.err.?);
    }
}
