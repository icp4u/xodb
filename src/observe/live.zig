//! Owner-thread lifecycle around C uprobe setup/drain and bounded host evidence.
const std = @import("std");
const model = @import("capture.zig");
const hooks = @import("../profile/uprobe_hooks.zig");
const modules = @import("../model/modules.zig");
const native = @import("linux.zig");
const perf = @import("../profile/linux_perf.zig");
const linux = @import("../target/linux.zig");
const types = @import("types.zig");
const runtime = @import("../profile/runtime.zig");
const producer = @import("../profile/producer.zig");
const a = std.heap.page_allocator;
pub const Context = struct {
    target: *const @import("../target/runtime.zig").c.struct_xrt_target,
    scope: runtime.c.struct_xrt_function_scope,
    producer: ?producer.Producer,
    identity: model.Identity,
    threads: [32]model.Thread = undefined,
    thread_count: usize,
};
const Preparation = struct {
    context: Context,
    config: model.Config,
    region: modules.Region,
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
    fn create(context: Context, config: model.Config, region: modules.Region, requests: []const hooks.Request, helper: ?[:0]const u8) !*Preparation {
        if (requests.len == 0 or requests.len > hooks.max_hooks) return error.InvalidObservationFunctions;
        const self = try a.create(Preparation);
        errdefer a.destroy(self);
        const path = try a.dupe(u8, region.path);
        self.* = .{ .context = context, .config = config, .region = region };
        self.region.path = path;
        errdefer self.clear();
        for (requests) |request| {
            self.requests[self.request_count] = .{ .id = request.id, .name = try a.dupe(u8, request.name) };
            self.request_count += 1;
        }
        if (helper) |path_| self.helper = try a.dupeZ(u8, path_);
        self.worker = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Preparation) void {
        self.execute() catch |err| {
            self.err = err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Preparation) !void {
        // Native setup uses only the owner's immutable snapshot. Remote file
        // calls use the serialized connection, never its mutable target view.
        const target = if (self.context.scope.remote) self.context.target else null;
        var prepared = try hooks.prepareTarget(target, self.context.scope.file_pid, self.region, self.requests[0..self.request_count], hooks.image_limit, &self.cancel);
        defer prepared.close();
        var threads: [32]native.Thread = undefined;
        for (self.context.threads[0..self.context.thread_count], 0..) |thread, i| threads[i] = .{ .id = thread.id, .tid = thread.tid };
        switch (try native.start(a, .{ .target = @ptrCast(target), .scope = self.context.scope, .mapping = self.region, .pid = self.context.identity.pid, .threads = threads[0..self.context.thread_count], .sources = prepared.sources[0..prepared.count], .helper = self.helper, .enable = false, .callstacks = self.config.callstacks, .cancel = &self.cancel })) {
            .collector => |collector| self.collector = collector,
            .failed => |failure| {
                self.failure = failure;
                return error.FunctionCollectorOpen;
            },
        }
        var functions: [hooks.max_hooks]model.Function = undefined;
        for (prepared.sources[0..prepared.count], prepared.locations[0..prepared.count], self.requests[0..prepared.count], 0..) |source, location, request, i| {
            functions[i] = .{ .id = source.id, .name = request.name, .path = self.region.path, .identity = source.identity, .file_offset = source.offset, .link_address = location.link_address, .runtime_address = location.runtime_address };
        }
        self.capture = try model.Capture.create(a, self.context.identity, self.config, self.context.threads[0..self.context.thread_count], functions[0..prepared.count]);
        self.capture.?.producer = self.context.producer;
    }
    fn clear(self: *Preparation) void {
        if (self.collector) |collector| collector.close();
        if (self.capture) |capture| capture.deinit();
        for (self.requests[0..self.request_count]) |request| a.free(request.name);
        a.free(self.region.path);
        if (self.helper) |path| a.free(path);
    }
    fn deinit(self: *Preparation) void {
        self.cancel.store(true, .release);
        if (self.worker) |thread| thread.join();
        self.clear();
        a.destroy(self);
    }
};
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
    preparation: ?*Preparation = null,
    cleanup: ?*Cleanup = null,
    next_id: u64 = 1,
    reason: ?model.Stop = null,
    failure: ?perf.Failure = null,
    err: ?anyerror = null,
    unread: bool = false,
    pub fn busy(self: *const Live) bool {
        return self.preparation != null or self.collector != null or self.cleanup != null;
    }
    pub fn start(self: *Live, context: Context, config: model.Config, region: modules.Region, requests: []const hooks.Request, helper: ?[:0]const u8) !void {
        try config.validate();
        if (self.busy()) return error.ObservationBusy;
        if (context.thread_count == 0 or context.thread_count > 32) return error.InvalidObservationThreads;
        var assigned = context;
        assigned.identity.capture_id = self.next_id;
        self.preparation = try Preparation.create(assigned, config, region, requests, helper);
        self.next_id += 1;
        self.err = null;
        self.failure = null;
    }
    pub fn pendingContext(self: *const Live) ?Context {
        return if (self.preparation) |job| job.context else null;
    }
    pub fn stop(self: *Live, reason: model.Stop) void {
        if (self.preparation) |job| job.cancel.store(true, .release);
        const collector = self.collector orelse return;
        if (self.reason != null) return;
        self.reason = reason;
        self.capture.?.stop_reason = reason;
        self.capture.?.ended_ns = linux.now();
        if (collector.stop()) |failure| {
            self.failure = failure;
            self.unread = true;
        }
        if (reason == .image_changed or reason == .mapping_changed or reason == .scope_changed or reason == .collector_error) {
            self.unread = true;
            // Drain the verified prefix before finalizing. The decoder stops
            // at the first terminal metadata record; the target owner may see
            // an exec stop before that already-recorded prefix is consumed.
        }
    }
    fn complete(self: *Live) void {
        const capture = self.capture orelse return;
        const reason: types.Reason = if (self.unread) .unread else switch (self.reason orelse .manual) {
            .manual => .stop,
            .cancelled, .shutdown => .cancelled,
            .target_ended => .process_exit,
            .thread_ended => .thread_exit,
            .duration => .capture_end,
            .record_limit => .record_limit,
            .memory_limit => .memory_limit,
            .image_changed => .exec,
            .mapping_changed, .scope_changed => .identity,
            .collector_error => .decode_error,
        };
        capture.store.finish(reason);
        if (self.unread) capture.store.unread_possible = true;
        capture.ended_ns = @max(capture.ended_ns orelse linux.now(), if (capture.store.records.items.len > 0) capture.store.records.items[capture.store.records.items.len - 1].event.time_ns else capture.started_ns);
        if (self.collector) |collector| {
            self.cleanup = Cleanup.create(collector) catch blk: {
                collector.close();
                break :blk null;
            };
            self.collector = null;
        }
    }
    /// Preparation is published only against its original held generation.
    pub fn poll(self: *Live, pending_valid: bool, boundary: ?model.Stop) void {
        if (self.cleanup) |cleanup| if (cleanup.done.load(.acquire)) {
            cleanup.deinit();
            self.cleanup = null;
        };
        if (self.preparation) |job| {
            if (!pending_valid) job.cancel.store(true, .release);
            if (job.done.load(.acquire)) {
                defer {
                    job.deinit();
                    self.preparation = null;
                }
                self.err = if (job.cancel.load(.acquire)) error.ObservationPreparationCancelled else job.err orelse if (!pending_valid) error.StaleObservationPreparation else null;
                self.failure = job.failure;
                if (self.err == null) {
                    const candidate = job.capture.?;
                    const collector = job.collector.?;
                    candidate.started_ns = linux.now();
                    if (collector.enable()) |failure| {
                        self.failure = failure;
                        self.err = error.FunctionCollectorEnable;
                    } else {
                        if (self.capture) |old| old.deinit();
                        self.capture = candidate;
                        job.capture = null;
                        self.collector = collector;
                        job.collector = null;
                        self.reason = null;
                        self.unread = false;
                    }
                }
            }
        }
        const collector = self.collector orelse return;
        const capture = self.capture.?;
        if (boundary) |reason| self.stop(reason);
        if (self.reason == null and capture.config.duration_ms > 0 and linux.now() -| capture.started_ns >= @as(u64, capture.config.duration_ms) * 1000000) self.stop(.duration);
        var items: [256]types.Event = undefined;
        const drained = collector.drain(&items);
        for (items[0..drained.count]) |event| {
            if (capture.store.finished) {
                self.unread = true;
                break;
            }
            capture.feed(event) catch |err| {
                self.err = err;
                self.unread = true;
            };
        }
        if (drained.failure) |failure| {
            self.failure = failure;
            self.unread = true;
            self.stop(.collector_error);
            self.complete();
            return;
        }
        if (drained.scope_changed) |reason| {
            self.stop(switch (reason) {
                .exec => .image_changed,
                .thread_exit => .thread_ended,
                else => .scope_changed,
            });
        }
        if (capture.store.finished and self.reason == null) {
            self.stop(switch (capture.store.finish_reason orelse .unread) {
                .record_limit => .record_limit,
                .memory_limit => .memory_limit,
                .exec => .image_changed,
                else => .scope_changed,
            });
        }
        if (capture.store.finished or (self.reason != null and !drained.more)) {
            self.unread = self.unread or drained.more;
            self.complete();
        }
    }
    pub fn deinit(self: *Live) void {
        self.stop(.shutdown);
        if (self.preparation) |job| job.deinit();
        if (self.cleanup) |cleanup| cleanup.deinit();
        if (self.collector) |collector| collector.close();
        if (self.capture) |capture| capture.deinit();
        self.* = .{};
    }
};
