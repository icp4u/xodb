//! Allocation display data prepared by the session owner. Pages and flame
//! labels own their storage; the frontend never borrows a capture or job.
const std = @import("std");
const model = @import("../profile/allocation_capture.zig");
const live_model = @import("../profile/allocation_live.zig");
const heap = @import("../profile/allocation_heap.zig");
const flame = @import("../profile/flame.zig");
const events = @import("../profile/allocation_events.zig");
pub const max_rows = 64;
pub const max_label_bytes = 384;
pub const Mode = enum { calls, lifetimes, outstanding, events, heap };
pub const Row = union(enum) { call: model.SpanRow, lifetime: model.LifetimeRow, event: model.RecordRow };
pub const Request = struct {
    identity: ?model.Identity = null,
    mode: Mode = .calls,
    filter: model.Filter = .{},
    start: usize = 0,
    limit: usize = max_rows,
    metric: heap.Metric = .allocated_bytes,
};
pub const Node = struct {
    id: u32,
    parent: ?u32,
    kind: flame.Kind,
    name: []const u8,
    color: u8,
    inclusive: u64,
    depth: u16,
    x: u64,
};
pub const Heap = struct { nodes: []const Node, excluded_weight: u64, missing_stacks: u64 };
pub const View = struct {
    request: ?Request = null,
    key: ?model.Key = null,
    state: ?model.State = null,
    archived: bool = false,
    threads: []const model.Thread = &.{},
    header: []const u8 = "",
    summary: []const u8 = "",
    warning: bool = false,
    rows: []const Row = &.{},
    next: ?usize = null,
    scanned: usize = 0,
    total: usize = 0,
    diagnostic: []const u8 = "",
    heap: ?Heap = null,
    heap_pending: bool = false,
    banner: []const u8 = "",
    banner_warning: bool = false,
    preparing: bool = false,
    collecting: bool = false,
    serial: u64 = 0,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
const Signature = struct {
    key: ?model.Key,
    state: ?model.State,
    analysis_done: bool,
    heap_done: bool,
    archived: bool,
    preparing: bool,
    collecting: bool,
    serial: u64,
    reason: ?live_model.Stop,
    err: ?anyerror,
    permission: bool,
    tid: i32,
    fn read(live: *const live_model.Live, tid: i32) Signature {
        const capture = live.capture;
        const job = if (capture) |v| v.heap_jobs[@intFromEnum(heap.Owner.gui)] else null;
        return .{
            .key = if (capture) |v| v.key() else null,
            .state = if (capture) |v| v.state else null,
            .analysis_done = if (capture) |v| v.done.load(.acquire) else false,
            .heap_done = if (job) |v| v.done.load(.acquire) else false,
            .archived = if (capture) |v| v.archived else false,
            .preparing = live.preparing(),
            .collecting = live.collecting(),
            .serial = live.serial,
            .reason = live.reason,
            .err = live.err,
            .permission = if (live.failure) |v| v.kind == .permission else false,
            .tid = tid,
        };
    }
};
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    signature: ?Signature = null,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = .{};
        self.signature = null;
    }
    pub fn changed(self: *const Capture, live: *const live_model.Live, tid: i32) bool {
        return self.signature == null or !std.meta.eql(self.signature.?, Signature.read(live, tid));
    }
    pub fn refresh(self: *Capture, live: *live_model.Live, wanted: ?Request, tid: i32) void {
        var request = wanted orelse {
            self.clear();
            return;
        };
        request.limit = @min(max_rows, @max(1, request.limit));
        if (live.capture) |capture| {
            capture.poll();
            if (capture.ended_ns != null) capture.requestAnalysis(false) catch {};
            if (request.identity == null or !std.meta.eql(request.identity.?, capture.identity)) {
                request.identity = capture.identity;
                request.start = 0;
                request.filter = .{};
            }
        } else {
            request.identity = null;
            request.start = 0;
            request.filter = .{};
        }
        if (!self.changed(live, tid) and std.meta.eql(self.value.request, @as(?Request, request))) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .request = request, .serial = live.serial, .preparing = live.preparing(), .collecting = live.collecting() };
        self.prepare(live, request, tid) catch |err| {
            self.value.diagnostic = @errorName(err);
        };
        self.signature = Signature.read(live, tid);
        if (self.value.heap_pending) self.signature.?.heap_done = false;
        if (self.value.state == .analyzing) self.signature.?.analysis_done = false;
    }
    fn prepare(self: *Capture, live: *live_model.Live, request: Request, tid: i32) !void {
        const a = self.arena.allocator();
        const archived = if (live.capture) |capture| capture.archived else false;
        self.value.archived = archived;
        self.value.banner_warning = live.err != null;
        self.value.banner = if (archived) "Offline allocation evidence; S saves a copy" else if (live.failure != null and live.failure.?.kind == .permission) "Permission denied; see docs/ALLOCATIONS.md" else if (live.err) |err| @errorName(err) else if (live.preparing()) "Preparing probes; keep target paused" else if (live.collecting() and live.reason != null) "Stopping capture; releasing probes" else if (live.collecting()) "Tracing selected threads; Space continues/pauses" else if (live.reason) |reason| try std.fmt.allocPrint(a, "Capture stopped: {s}; next start selects TID {d}", .{ @tagName(reason), tid }) else try std.fmt.allocPrint(a, "Start on stopped TID {d}: malloc/calloc/realloc/free", .{tid});
        const capture = live.capture orelse return;
        self.value.key = capture.key();
        self.value.state = capture.state;
        self.value.threads = try a.dupe(model.Thread, capture.threads[0..capture.thread_count]);
        self.value.header = try std.fmt.allocPrint(a, "Process #{d} / PID {d} / capture #{d} / {s} / {d} selected threads, {d} hooks", .{ capture.identity.process_id, capture.identity.pid, capture.identity.capture_id, @tagName(capture.state), capture.thread_count, capture.hook_count });
        self.value.summary = if (capture.summary()) |s| try std.fmt.allocPrint(a, "Whole capture: {d} outstanding / {d} requested bytes / {d} successful allocations", .{ s.outstanding_count, s.outstanding_bytes, s.successful_allocations }) else if (capture.store.first_gap) |gap| try std.fmt.allocPrint(a, "Lifetime totals unavailable: {s}; lost {d}, rejected {d}, unread {s}", .{ @tagName(gap.reason), capture.store.lost, capture.store.rejected, if (capture.store.unread_possible) "possible" else "no" }) else if (capture.failure) |err| try std.fmt.allocPrint(a, "Analysis failed: {s}. Retained calls remain available; R retries.", .{@errorName(err)}) else if (capture.state == .analyzing) "Building lifetime analysis; retained evidence is available" else if (capture.state == .stopping) "Waiting for source cleanup and the final capture boundary" else "Lifetime totals become available after collection ends";
        self.value.warning = capture.store.first_gap != null or capture.failure != null;
        var filter = request.filter;
        filter.outstanding_only = request.mode == .outstanding;
        switch (request.mode) {
            .heap => {
                const result = try capture.heapView(filter, request.metric, .gui) orelse {
                    self.value.heap_pending = true;
                    return;
                };
                self.value.heap = try copyHeap(a, result);
            },
            .calls => try self.page(.call, try capture.spanPage(a, capture.key(), filter, request.start, request.limit)),
            .events => try self.page(.event, try capture.recordPage(a, capture.key(), filter, request.start, request.limit)),
            .lifetimes, .outstanding => try self.page(.lifetime, try capture.lifetimePage(a, capture.key(), filter, request.start, request.limit)),
        }
    }
    fn page(self: *Capture, comptime tag: std.meta.Tag(Row), value: anytype) !void {
        const rows = try self.arena.allocator().alloc(Row, value.rows.len);
        for (value.rows, rows) |row, *out| out.* = @unionInit(Row, @tagName(tag), row);
        self.value.rows = rows;
        self.value.next = value.next;
        self.value.scanned = value.scanned;
        self.value.total = value.total_unfiltered;
    }
};
fn copyHeap(a: std.mem.Allocator, value: *const heap.View) !Heap {
    const nodes = try a.alloc(Node, value.graph.nodes.items.len);
    for (value.graph.nodes.items, nodes) |node, *out| out.* = .{
        .id = node.id,
        .parent = node.parent,
        .kind = node.frame.kind,
        .name = try displayLabel(a, node.frame.name),
        .color = @intCast(std.hash.Wyhash.hash(0, node.frame.name) % 100),
        .inclusive = node.inclusive,
        .depth = node.depth,
        .x = node.x,
    };
    return .{ .nodes = nodes, .excluded_weight = value.excluded_weight, .missing_stacks = value.missing_stacks };
}
fn displayLabel(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len <= max_label_bytes) return a.dupe(u8, text);
    // Only the display prefix is bounded. Capture symbols and MCP citations
    // remain complete, and colors still hash the original name.
    var end: usize = max_label_bytes - 3;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return std.mem.concat(a, u8, &.{ text[0..end], "..." });
}
pub const Action = union(enum) {
    retry: model.Key,
    start: struct { tid: i32, serial: u64 },
    stop: struct { identity: ?model.Identity, serial: u64 },
    save: struct { key: model.Key, path: []const u8 },
};
pub fn apply(session: *@import("session.zig").Session, action: Action, actor: @import("session.zig").Actor) !void {
    const live = &session.allocations;
    switch (action) {
        .retry => |key| {
            const capture = live.capture orelse return error.NoAllocationCapture;
            try capture.validate(key);
            try capture.requestAnalysisOwned(true, if (actor == .human) .{} else session.jobRequester());
        },
        .start => |request| {
            if (request.serial != live.serial) return error.StaleAllocationCapture;
            if (live.preparing() or live.collecting()) return error.AllocationCaptureBusy;
            try session.startAllocations(actor, &.{request.tid}, session.allocation_defaults, null, &@import("session.zig").Session.allocation_hooks);
        },
        .stop => |request| {
            const identity = if (live.capture) |capture| @as(?model.Identity, capture.identity) else null;
            if (request.serial != live.serial or !std.meta.eql(request.identity, identity)) return error.StaleAllocationCapture;
            live.stop(.manual);
            session.record(actor, "stop_allocations");
        },
        .save => |request| {
            const capture = live.capture orelse return error.NoAllocationCapture;
            try capture.validate(request.key);
            _ = try session.saveAllocationArchive(request.path);
            session.record(actor, "save_allocation_archive");
        },
    }
}

test "allocation pages are owned and stale page responses cannot repaint navigation" {
    const a = std.testing.allocator;
    var live: live_model.Live = .{};
    defer live.deinit();
    live.capture = try model.Capture.create(a, .{ .session_id = 1, .capture_id = 2, .process_id = 1, .pid = 7, .image_epoch = 1 }, .{}, &.{.{ .id = 11, .tid = 7 }}, &.{.{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture/allocator", .device = 1, .inode = 2, .file_offset = 1, .link_address = 1, .runtime_address = 1 }}, 1);
    const source = live.capture.?;
    for (0..80) |i| {
        try source.feed(0, .{ .time_ns = 2 + i * 2, .data = .{ .sample = .{ .kind = .malloc, .phase = .enter, .hook = 1, .stack_key = 0x8000, .arg0 = 32 } } });
        try source.feed(0, .{ .time_ns = 3 + i * 2, .data = .{ .sample = .{ .kind = .malloc, .phase = .leave, .hook = 1, .stack_key = 0x8000, .result = 0x1000 + i * 64 } } });
    }
    var capture: Capture = .{ .arena = .init(a) };
    defer capture.deinit();
    var panel: @import("../ui/allocations.zig").Panel = .{ .open = true };
    defer panel.deinit();
    capture.refresh(&live, panel.request(720), 7);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .allocations = capture.value,
    });
    defer publication.destroy();
    capture.refresh(&live, null, 7);
    try std.testing.expectEqual(@as(usize, 0), capture.arena.queryCapacity());
    source.deinit();
    live.capture = null;
    const value = publication.value.allocations.?;
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    panel.present(value);
    try std.testing.expectEqual(@as(usize, 15), panel.count);
    try std.testing.expectEqual(@as(u32, 0), panel.selectedOrdinal().?);
    try std.testing.expectEqualStrings("Start on stopped TID 7: malloc/calloc/realloc/free", panel.view.banner);
    panel.forward();
    try std.testing.expectEqual(@as(usize, 15), panel.start);
    panel.present(value);
    try std.testing.expectEqual(@as(usize, 0), panel.count);
    try std.testing.expect(panel.selectedOrdinal() == null);
    panel.back();
    panel.present(value);
    const retry = panel.key(.{ .kind = .press, .shortcut = 'r' }).owner.retry;
    try std.testing.expect(std.meta.eql(retry, value.key.?));
    panel.cycleThread();
    try std.testing.expectEqual(@as(u64, 11), panel.filter.thread_id.?);
    // A newly selected capture resets the previous capture's page and filter.
    var replacement = value;
    replacement.key.?.identity.capture_id += 1;
    replacement.request.?.identity = replacement.key.?.identity;
    panel.present(replacement);
    try std.testing.expect(panel.filter.thread_id == null);
    try std.testing.expectEqual(@as(usize, 15), panel.count);
}

test "allocation flame projection bounds display labels and survives source retirement" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var graph = try flame.Graph.init(a);
    defer graph.deinit();
    var name: [1200]u8 = undefined;
    for (0..name.len / 3) |i| @memcpy(name[i * 3 ..][0..3], "界");
    try graph.nodes.ensureTotalCapacity(a, flame.max_nodes);
    for (1..flame.max_nodes) |i| graph.nodes.appendAssumeCapacity(.{ .id = @intCast(i), .parent = 0, .frame = .{ .kind = .code, .name = &name }, .inclusive = 1, .x = i - 1, .depth = 1 });
    graph.nodes.items[0].inclusive = flame.max_nodes - 1;
    const source: heap.View = .{ .graph = graph, .excluded_weight = 3, .missing_stacks = 2 };
    const projected = try copyHeap(arena.allocator(), &source);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .allocations = .{ .heap = projected },
    });
    defer publication.destroy();
    _ = arena.reset(.free_all);
    const view = publication.value.allocations.?.heap.?;
    try std.testing.expectEqual(flame.max_nodes, view.nodes.len);
    try std.testing.expect(publication.bytes < 4 * 1024 * 1024);
    try std.testing.expectEqual(@as(u64, 3), view.excluded_weight);
    for (view.nodes[1..]) |node| {
        try std.testing.expect(node.name.len <= max_label_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(node.name));
        try std.testing.expect(std.mem.endsWith(u8, node.name, "..."));
        try std.testing.expectEqual(@as(u8, @intCast(std.hash.Wyhash.hash(0, &name) % 100)), node.color);
    }
}

test "allocation controls refuse a replacement capture before changing it" {
    var session = @import("session.zig").Session.init();
    defer session.deinit();
    session.allocations.capture = try model.Capture.create(std.testing.allocator, .{ .session_id = session.id, .capture_id = 2, .process_id = 1, .pid = 7, .image_epoch = 1 }, .{}, &.{.{ .id = 11, .tid = 7 }}, &.{.{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture/allocator", .device = 1, .inode = 2, .file_offset = 1, .link_address = 1, .runtime_address = 1 }}, 1);
    var stale = session.allocations.capture.?.key();
    stale.identity.capture_id += 1;
    try std.testing.expectError(error.StaleAllocationCapture, apply(&session, .{ .retry = stale }, .human));
    try std.testing.expectError(error.StaleAllocationCapture, apply(&session, .{ .save = .{ .key = stale, .path = "fixture.xoa" } }, .human));
    try std.testing.expectError(error.StaleAllocationCapture, apply(&session, .{ .stop = .{ .identity = stale.identity, .serial = 0 } }, .human));
    try std.testing.expectError(error.StaleAllocationCapture, apply(&session, .{ .start = .{ .tid = 7, .serial = 1 } }, .human));
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
    try std.testing.expect(session.allocations.reason == null);
    try std.testing.expect(session.archive_job == null);
}
