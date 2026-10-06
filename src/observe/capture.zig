//! One retained invocation capture; the C collector owns all live target access.
const std = @import("std");
const calls = @import("calls.zig");
const hooks = @import("../profile/uprobe_hooks.zig");
const Budget = @import("../profile/archive_budget.zig").Budget;
pub const Identity = struct { session_id: u64, capture_id: u64, process_id: u64, pid: i32, image_epoch: u64, generation: u64 };
pub const Thread = struct { id: u64, tid: i32 };
pub const Function = struct { id: u16, name: []const u8, path: []const u8, identity: hooks.Identity, file_offset: u64, link_address: u64, runtime_address: u64 };
pub const Config = struct {
    duration_ms: u32 = 60000,
    callstacks: bool = true,
    record_limit: u32 = 32768,
    memory_limit: u32 = 64 * 1024 * 1024,
    pub fn validate(self: Config) !void {
        if (self.duration_ms > 24 * 60 * 60 * 1000 or self.record_limit < 2 or self.record_limit > calls.max_records or self.memory_limit < 1024 * 1024 or self.memory_limit > 256 * 1024 * 1024) return error.InvalidObservationConfig;
    }
    pub fn store(self: Config) calls.Config {
        return .{ .record_limit = self.record_limit, .thread_limit = 32, .depth_limit = 64, .memory_limit = self.memory_limit };
    }
};
pub const Stop = enum { manual, duration, record_limit, memory_limit, target_ended, thread_ended, image_changed, mapping_changed, scope_changed, collector_error, cancelled, shutdown };
pub const Capture = struct {
    identity: Identity,
    config: Config,
    threads: []const Thread,
    functions: []const Function,
    producer: ?@import("../profile/producer.zig").Producer = null,
    started_ns: u64 = 0,
    ended_ns: ?u64 = null,
    stop_reason: ?Stop = null,
    store: calls.Store,
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    offline: bool = false,
    saved_associations: ?*@import("association_evidence.zig").Owned = null,
    recipe_json: ?[]const u8 = null,
    comparison_selection: ?@import("comparison.zig").Selection = null,
    pub fn create(a: std.mem.Allocator, identity: Identity, config: Config, threads: []const Thread, functions: []const Function) !*Capture {
        try config.validate();
        if (threads.len == 0 or threads.len > 32 or functions.len == 0 or functions.len > hooks.max_hooks) return error.InvalidObservationScope;
        for (threads, 0..) |thread, i| {
            if (thread.id == 0 or thread.tid <= 0) return error.InvalidObservationScope;
            for (threads[0..i]) |old| if (old.id == thread.id or old.tid == thread.tid) return error.InvalidObservationScope;
        }
        for (functions, 0..) |function, i| {
            if (function.id == 0 or function.name.len == 0 or function.name.len > 256 or function.path.len > 4096) return error.InvalidObservationScope;
            for (functions[0..i]) |old| if (old.id == function.id) return error.InvalidObservationScope;
        }
        const self = try a.create(Capture);
        self.* = .{ .identity = identity, .config = config, .threads = &.{}, .functions = &.{}, .store = try calls.Store.init(config.store()), .budget = .{ .backing = a, .limit = config.memory_limit }, .arena = undefined };
        self.arena = std.heap.ArenaAllocator.init(self.budget.allocator());
        errdefer self.deinit();
        const owned = self.arena.allocator();
        self.threads = try owned.dupe(Thread, threads);
        const retained = try owned.dupe(Function, functions);
        for (retained) |*function| {
            function.name = try owned.dupe(u8, function.name);
            function.path = try owned.dupe(u8, function.path);
        }
        self.functions = retained;
        return self;
    }
    pub fn feed(self: *Capture, event: calls.Event) !void {
        for (self.threads) |thread| {
            if (thread.id == event.thread_id and thread.tid == event.tid) break;
        } else {
            self.store.finish(.identity);
            return error.ObservationThreadIdentity;
        }
        if (event.data == .sample) {
            for (self.functions) |function| {
                if (function.id == event.data.sample.function_id) break;
            } else {
                self.store.finish(.identity);
                return error.ObservationFunctionIdentity;
            }
        }
        try self.store.feed(self.budget.allocator(), event);
    }
    pub fn deinit(self: *Capture) void {
        const a = self.budget.backing;
        if (self.saved_associations) |saved| saved.deinit();
        self.store.deinit(self.budget.allocator());
        self.arena.deinit();
        a.destroy(self);
    }
};
