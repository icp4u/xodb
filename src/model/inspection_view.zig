//! Owner-side memory/vector observations and immutable display projections.
const std = @import("std");
const Session = @import("session.zig").Session;
const linux = @import("../target/linux.zig");
const memory = @import("memory.zig");
const xstate = @import("../target/xstate.zig");
pub const Kind = enum { memory, vectors };
pub const Request = struct {
    kind: Kind,
    tid: i32,
    address: u64,
    baseline: ?u64 = null,
    revision: u64 = 0,
};
pub const Bytes = struct {
    id: u64,
    generation: u64,
    address: u64,
    bytes: []const u8,
    valid: []const bool,
    changes: []const memory.Memory.Comparison,
};
pub const Search = struct {
    id: u64,
    state: @FieldType(memory.Search, "state"),
    scanned: usize,
    length: usize,
    unreadable: usize,
    hits: []const u64,
    range_count: usize = 1,
};
pub const View = struct {
    session: u64 = 0,
    generation: u64 = 0,
    metadata: u64 = 0,
    observed_generation: u64 = 0,
    image_epoch: u64 = 0,
    tid: i32 = 0,
    state: linux.State = .idle,
    request: ?Request = null,
    snapshot: ?Bytes = null,
    baseline: ?u64 = null,
    vector: ?xstate.State = null,
    previous: ?xstate.State = null,
    search: ?Search = null,
    diagnostic: ?[]const u8 = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    session: u64 = 0,
    generation: u64 = 0,
    image_epoch: u64 = 0,
    request: ?Request = null,
    snapshot: ?u64 = null,
    vector_tid: i32 = 0,
    vector_generation: u64 = 0,
    vector: ?xstate.State = null,
    previous: ?xstate.State = null,
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = .{};
        self.request = null;
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const request = wanted orelse {
            self.clear();
            return;
        };
        const state = session.target.snapshot();
        const same_process = self.session == session.id and self.image_epoch == state.image_epoch;
        const previous_request = self.request;
        if (!same_process) {
            self.snapshot = null;
            self.vector = null;
            self.previous = null;
            self.generation = 0;
            self.diagnostic = null;
        }
        self.session = session.id;
        self.image_epoch = state.image_epoch;
        const expired = if (self.snapshot) |id| failed: {
            _ = session.memory.find(id) catch break :failed true;
            break :failed false;
        } else false;
        if (expired) {
            self.snapshot = null;
            self.diagnostic = "MemorySnapshotExpired";
        }
        const changed = if (previous_request) |old| old.kind != request.kind or old.tid != request.tid or old.address != request.address or old.revision != request.revision else true;
        if (state.state == .stopped and (!same_process or self.generation != state.generation or changed or expired)) {
            self.generation = state.generation;
            self.diagnostic = null;
            if (request.kind == .vectors) {
                self.previous = if (same_process and self.vector_tid == request.tid) self.vector else null;
                self.vector_tid = request.tid;
                self.vector_generation = state.generation;
                self.vector = session.target.extendedRegisters(request.tid) catch |err| failed: {
                    self.diagnostic = @errorName(err);
                    break :failed null;
                };
            } else {
                self.snapshot = session.memory.capture(session, request.address, 1024) catch |err| failed: {
                    self.diagnostic = @errorName(err);
                    break :failed null;
                };
            }
        }
        self.request = request;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .session = session.id, .generation = state.generation, .metadata = session.metadata.revision, .observed_generation = if (request.kind == .vectors) self.vector_generation else self.generation, .image_epoch = state.image_epoch, .tid = if (request.kind == .vectors and self.vector != null) self.vector_tid else request.tid, .state = state.state, .request = request, .vector = if (request.kind == .vectors) self.vector else null, .previous = if (request.kind == .vectors) self.previous else null, .diagnostic = self.diagnostic };
        self.project(session, request, same_process) catch |err| {
            self.value.diagnostic = @errorName(err);
        };
    }
    fn project(self: *Capture, session: *Session, request: Request, same_process: bool) !void {
        if (request.kind != .memory) return;
        if (session.memory.search) |*search| self.value.search = .{ .id = search.id, .state = search.state, .scanned = search.scanned, .length = search.length, .unreadable = search.unreadable, .hits = search.hits[0..search.count], .range_count = search.ranges.len };
        const baseline = if (same_process and request.baseline != null) session.memory.find(request.baseline.?) catch null else null;
        if (baseline) |old| self.value.baseline = old.id;
        const current = try session.memory.find(self.snapshot orelse return);
        self.value.observed_generation = current.generation;
        const changes = try self.arena.allocator().alloc(memory.Memory.Comparison, current.bytes.len);
        for (changes, 0..) |*change, i| change.* = if (baseline) |old| memory.Memory.compare(current, old, i) else .same;
        self.value.snapshot = .{ .id = current.id, .generation = current.generation, .address = current.address, .bytes = current.bytes, .valid = current.valid, .changes = changes };
    }
};

pub const Action = union(enum) {
    address: struct { tid: i32, frame: usize, metadata: u64, text: []const u8 },
    pin: ?u64,
    search: struct { address: u64, length: usize, text: []const u8, all_writable: bool = false },
    cancel: u64,
};
/// Queue stamp/actor validation precedes this call. A native GUI uses the same
/// operation synchronously. Returned numbers are address or retained search ID.
pub fn apply(session: *Session, actor: @import("session.zig").Actor, action: Action) !?u64 {
    switch (action) {
        .address => |request| {
            const address = std.fmt.parseInt(u64, request.text, 0) catch blk: {
                if (request.metadata != session.metadata.revision) return error.StaleSnapshot;
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                const value = try session.evaluateExpression(arena.allocator(), request.tid, request.frame, request.text);
                if (request.metadata != session.metadata.revision) return error.StaleSnapshot;
                if (value.availability != .available) return error.ValueUnavailable;
                break :blk switch (value.type.kind) {
                    .pointer, .unsigned, .signed => value.bits,
                    else => value.address orelse return error.ExpectedAddress,
                };
            };
            if (address == 0) return error.InvalidMemoryRange;
            return address;
        },
        .pin => |id| {
            if (id) |snapshot| {
                _ = try session.memory.find(snapshot);
            }
            session.memory.pinned = id;
            session.record(actor, "pin_memory_snapshot");
        },
        .search => |request| {
            var bytes: [256]u8 = undefined;
            const data = if (std.mem.startsWith(u8, request.text, "text:")) request.text[5..] else blk: {
                const hex = if (std.mem.startsWith(u8, request.text, "hex:")) request.text[4..] else request.text;
                if (hex.len == 0 or hex.len % 2 != 0 or hex.len > 512) return error.InvalidMemoryPattern;
                for (0..hex.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch return error.InvalidMemoryPattern;
                break :blk bytes[0 .. hex.len / 2];
            };
            const requester = if (actor == .human) @import("../service/job_owner.zig").Requester{} else session.jobRequester();
            const id = if (request.all_writable) blk: {
                var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer arena.deinit();
                try session.refreshMaps();
                const ranges = try memory.regionRanges(arena.allocator(), session.modules.regions.items, .writable, false, 0, std.math.maxInt(u64));
                break :blk try session.memory.startSearchRanges(session, ranges, data, requester);
            } else try session.memory.startSearchOwned(session, request.address, request.length, data, requester);
            session.record(actor, "search_memory");
            return id;
        },
        .cancel => |id| {
            const search = if (session.memory.search) |*value| value else return error.NoMemorySearch;
            if (search.id != id) return error.StaleMemorySearch;
            try session.memory.cancelSearch(id, if (actor == .human) .{} else session.jobRequester());
            session.record(actor, "cancel_memory_search");
        },
    }
    return null;
}

test "inspection publication survives expired memory and released projection storage" {
    const boundary = @import("remote_owner.zig");
    const a = std.heap.page_allocator;
    var session = Session.init();
    defer session.deinit();
    session.memory.snapshots[0] = .{ .id = 7, .session_id = session.id, .image_epoch = 0, .generation = 2, .address = 0x1000, .bytes = try a.dupe(u8, &.{ 1, 2 }), .valid = try a.dupe(bool, &.{ true, false }), .readable = 1 };
    session.memory.snapshots[1] = .{ .id = 6, .session_id = session.id, .image_epoch = 0, .generation = 1, .address = 0x1000, .bytes = try a.dupe(u8, &.{ 1, 3 }), .valid = try a.dupe(bool, &.{ true, true }), .readable = 2 };
    session.memory.search = .{ .ranges = &.{}, .id = 8, .generation = 2, .image_epoch = 0, .address = 0x1000, .length = 2, .pattern_len = 1, .count = 1 };
    session.memory.search.?.hits[0] = 0x1000;
    var capture: Capture = .{ .arena = .init(std.testing.allocator), .snapshot = 7, .value = .{ .session = session.id } };
    defer capture.deinit();
    try capture.project(&session, .{ .kind = .memory, .tid = 1, .address = 0x1000, .baseline = 6 }, true);
    const publication = try boundary.Publication.create(std.testing.allocator, .{ .stamp = @import("remote_dispatch.zig").stamp(1, &session), .revision = 1, .taken_ns = 1, .status = .ready, .memory = capture.value });
    defer publication.destroy();
    capture.clear();
    session.memory.search.?.hits[0] = 0x2000;
    session.memory.deinit();
    const view = publication.value.memory.?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, view.snapshot.?.bytes);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, view.snapshot.?.valid);
    try std.testing.expectEqualSlices(memory.Memory.Comparison, &.{ .same, .became_unreadable }, view.snapshot.?.changes);
    try std.testing.expectEqual(@as(u64, 0x1000), view.search.?.hits[0]);
}

test "inspection frontend cancellation keeps its observed search identity" {
    var session = Session.init();
    defer session.deinit();
    session.memory.search = .{ .ranges = &.{}, .id = 9, .generation = 1, .image_epoch = 0, .address = 0x1000, .length = 2, .pattern_len = 1 };
    var panel: @import("../ui/inspection.zig").Panel = .{ .open = true, .view = .{ .search = .{ .id = 8, .state = .running, .scanned = 0, .length = 2, .unreadable = 0, .hits = &.{} } } };
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    const action = (try panel.keyView(1, 0, 0, .{ .kind = .press, .shortcut = 'c' })).owner;
    try std.testing.expectError(error.StaleMemorySearch, apply(&session, .human, action));
    try std.testing.expect(session.memory.search.?.state == .running);
    try std.testing.expectError(error.StaleSnapshot, apply(&session, .human, .{ .address = .{ .tid = 1, .frame = 0, .metadata = session.metadata.revision + 1, .text = "&value" } }));
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
}

test "historical vectors retain their thread and stop across other inspection requests" {
    var session = Session.init();
    defer session.deinit();
    var capture: Capture = .{
        .arena = .init(std.testing.allocator),
        .session = session.id,
        .image_epoch = session.target.snapshot().image_epoch,
        .generation = 8,
        .vector_tid = 42,
        .vector_generation = 4,
        .vector = .{},
        .snapshot = 99,
    };
    defer capture.deinit();
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    capture.refresh(&session, .{ .kind = .memory, .tid = 43, .address = 0x1000 });
    try std.testing.expect(capture.snapshot == null);
    try std.testing.expectEqualStrings("MemorySnapshotExpired", capture.value.diagnostic.?);
    capture.refresh(&session, .{ .kind = .vectors, .tid = 43, .address = 0 });
    try std.testing.expectEqual(@as(i32, 42), capture.value.tid);
    try std.testing.expectEqual(@as(u64, 4), capture.value.observed_generation);
    try std.testing.expectEqual(@as(i32, 43), capture.value.request.?.tid);
    try std.testing.expect(capture.value.vector != null);
}

test "typed memory cancellation preserves a foreign running job" {
    var session = Session.init();
    defer session.deinit();
    session.agent_client_id = 7;
    session.agent_controller = false;
    session.memory.search = .{ .ranges = &.{}, .id = 1, .generation = 1, .image_epoch = 0, .address = 4096, .length = 64, .pattern_len = 1 };
    try std.testing.expectError(error.JobNotOwned, apply(&session, .agent, .{ .cancel = 1 }));
    try std.testing.expectEqual(.running, session.memory.search.?.state);
    session.memory.search.?.owner = @import("../service/job_owner.zig").Owner.agent(7);
    _ = try apply(&session, .agent, .{ .cancel = 1 });
    try std.testing.expectEqual(.cancelled, session.memory.search.?.state);
}
