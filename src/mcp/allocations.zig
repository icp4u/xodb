//! Read-only pages over retained allocation evidence.
const std = @import("std");
const model = @import("../profile/allocation_capture.zig");
const wire = @import("profile.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
fn hex(a: Allocator, n: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{n});
}
fn boolean(args: Value, key: []const u8) !bool {
    const item = args.object.get(key) orelse return false;
    if (item != .bool) return error.InvalidArguments;
    return item.bool;
}
fn expected(capture: *const model.Capture, args: Value) !model.Key {
    var key = capture.key();
    key.identity.session_id = try wire.number(args, "session_id", null);
    key.identity.capture_id = try wire.number(args, "capture_id", null);
    key.revision = try wire.number(args, "revision", null);
    try capture.validate(key);
    return key;
}
fn record(a: Allocator, row: model.RecordRow) !Value {
    const event = row.event;
    const data = switch (event.data) {
        .sample => |sample| try wire.value(a, .{ .kind = "sample", .phase = sample.phase, .hook_id = sample.hook, .allocation_kind = sample.kind, .stack_key = try hex(a, sample.stack_key), .ip = try hex(a, sample.ip), .arg0 = try hex(a, sample.arg0), .arg1 = try hex(a, sample.arg1), .result = try hex(a, sample.result), .stack_id = sample.stack }),
        .lost => |n| try wire.value(a, .{ .kind = "lost", .count = n }),
        else => try wire.value(a, .{ .kind = @tagName(event.data) }),
    };
    return wire.value(a, .{ .ordinal = row.ordinal, .thread_id = row.thread.id, .tid = row.thread.tid, .time_ns = event.time_ns, .event = data });
}
pub fn status(a: Allocator, capture: *model.Capture) !Value {
    var hooks: std.ArrayList(Value) = .empty;
    for (capture.hooks[0..capture.hook_count]) |hook| try hooks.append(a, try wire.value(a, .{
        .id = hook.id,
        .kind = hook.kind,
        .name = hook.name,
        .path = hook.path,
        .device = hook.device,
        .inode = hook.inode,
        .file_offset = try hex(a, hook.file_offset),
        .link_address = try hex(a, hook.link_address),
        .runtime_address = try hex(a, hook.runtime_address),
    }));
    return wire.value(a, .{
        .key = capture.key(),
        .archived = capture.archived,
        .origin = capture.origin,
        .state = capture.state,
        .started_ns = capture.started_ns,
        .ended_ns = capture.ended_ns,
        .threads = capture.threads[0..capture.thread_count],
        .hooks = hooks.items,
        .config = capture.config,
        .memory = capture.memory(),
        .record_count = capture.store.records.items.len,
        .span_count = capture.store.spans.items.len,
        .stack_count = capture.stacks.entries.items.len,
        .stacks_omitted = capture.stacks.omitted,
        .stack_method = "perf_frame_pointers_and_entry_return_address",
        .stack_completeness = "prefix_only",
        .symbol_basis = if (capture.archived) "recorded_archive_annotations" else "opening_immutable_elf_snapshots",
        .lost = capture.store.lost,
        .throttles = capture.store.throttles,
        .rejected = capture.store.rejected,
        .nested = capture.store.nested,
        .unread_possible = capture.store.unread_possible,
        .first_gap = capture.store.first_gap,
        .analysis_error = if (capture.failure) |err| @errorName(err) else null,
        .summary = capture.summary(),
        .summary_scope = "capture",
        .coverage = "selected_threads_and_hooks",
        .outstanding_is_leak_proof = false,
        .analysis_algorithm = model.algorithm,
    });
}
/// Caller supplies the explicitly routed process's capture. Arguments do not
/// mutate target state or change the GUI's selected process/thread.
pub fn call(a: Allocator, current: ?*model.Capture, name: []const u8, args: Value) !Value {
    const is_status = std.mem.eql(u8, name, "get_allocation_capture");
    const records = std.mem.eql(u8, name, "get_allocation_events");
    const spans = std.mem.eql(u8, name, "get_allocation_calls");
    const lifetimes = std.mem.eql(u8, name, "get_allocation_lifetimes");
    const stack_query = std.mem.eql(u8, name, "get_allocation_stack");
    const heap = std.mem.eql(u8, name, "get_allocation_flamegraph");
    if (!is_status and !records and !spans and !lifetimes and !stack_query and !heap) return error.UnknownTool;
    if (stack_query) {
        try wire.fields(args, &.{ "session_id", "capture_id", "revision", "allocation_span" });
        const capture = current orelse return error.NoAllocationCapture;
        capture.poll();
        const key = try expected(capture, args);
        const ordinal = try wire.number(args, "allocation_span", null);
        if (ordinal >= capture.store.spans.items.len) return error.InvalidArguments;
        const span = capture.store.spans.items[@intCast(ordinal)];
        const id = if (span.entry_record) |entry| capture.store.records.items[entry].event.data.sample.stack else null;
        const stack = if (id) |n| capture.stacks.entries.items[n] else @import("../profile/allocation_stacks.zig").Stack{};
        var frames: std.ArrayList(Value) = .empty;
        for (stack.addresses(), 0..) |pc, depth| {
            const frame = capture.stackFrame(pc, depth);
            try frames.append(a, try wire.value(a, .{ .pc = try hex(a, pc), .lookup_address = try hex(a, frame.lookup_address), .symbol_address = try hex(a, frame.address), .name = frame.name, .module = frame.module, .kind = frame.kind }));
        }
        return wire.value(a, .{ .key = key, .allocation_span = ordinal, .stack_id = id, .status = if (id != null) @tagName(stack.status) else if (capture.config.callstacks) "not_retained" else "disabled", .method = "perf_frame_pointers_and_entry_return_address", .complete = false, .frames = frames.items });
    }
    try wire.fields(args, if (is_status) &.{} else if (heap) &.{ "session_id", "capture_id", "revision", "start", "limit", "thread_id", "from_ns", "to_ns", "metric" } else if (lifetimes)
        &.{ "session_id", "capture_id", "revision", "start", "limit", "thread_id", "from_ns", "to_ns", "outstanding_only", "retry" }
    else
        &.{ "session_id", "capture_id", "revision", "start", "limit", "thread_id", "from_ns", "to_ns" });
    const capture = current orelse return error.NoAllocationCapture;
    capture.poll();
    if (is_status) return status(a, capture);
    const key = try expected(capture, args);
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    const filter = model.Filter{
        .thread_id = if (args.object.contains("thread_id")) try wire.number(args, "thread_id", null) else null,
        .from_ns = try wire.number(args, "from_ns", 0),
        .to_ns = try wire.number(args, "to_ns", std.math.maxInt(u64)),
        .outstanding_only = if (lifetimes) try boolean(args, "outstanding_only") else false,
    };
    if (limit == 0 or limit > model.page_limit or filter.from_ns > filter.to_ns or start > @import("../profile/allocation_events.zig").max_records) return error.InvalidArguments;
    if (filter.thread_id) |id| {
        const found = for (capture.threads[0..capture.thread_count]) |thread| {
            if (thread.id == id) break true;
        } else false;
        if (!found) return error.InvalidAllocationThread;
    }
    if (heap) {
        const value = args.object.get("metric") orelse Value{ .string = "allocated_bytes" };
        if (value != .string or start > @import("../profile/flame.zig").max_nodes) return error.InvalidArguments;
        const metric = std.meta.stringToEnum(@import("../profile/allocation_heap.zig").Metric, value.string) orelse return error.InvalidArguments;
        const view = (try capture.heapView(filter, metric, .mcp)) orelse return wire.value(a, .{ .key = key, .pending = true, .metric = metric, .filter = filter });
        if (start > view.graph.nodes.items.len) return error.InvalidArguments;
        const end = @min(view.graph.nodes.items.len, start + limit);
        var nodes: std.ArrayList(Value) = .empty;
        for (view.graph.nodes.items[@intCast(start)..@intCast(end)]) |node| try nodes.append(a, try wire.value(a, .{
            .id = node.id,
            .parent = node.parent,
            .kind = node.frame.kind,
            .name = node.frame.name,
            .module = node.frame.module,
            .address = try hex(a, node.frame.address),
            .inclusive = node.inclusive,
            .self = node.self,
            .depth = node.depth,
        }));
        return wire.value(a, .{ .key = key, .pending = false, .metric = metric, .unit = if (metric == .allocations) "allocations" else "requested_bytes", .filter = filter, .filter_basis = "allocation_entry", .nodes = nodes.items, .next = if (end < view.graph.nodes.items.len) @as(?u64, end) else null, .total_weight = view.graph.nodes.items[0].inclusive, .excluded_weight = view.excluded_weight, .allocations = view.allocations, .caller_stacks = view.caller_stacks, .missing_stacks = view.missing_stacks, .zero_weight = view.zero_weight, .outstanding_is_leak_proof = false });
    }
    if (records) {
        const page = try capture.recordPage(a, key, filter, @intCast(start), @intCast(limit));
        defer a.free(page.rows);
        var rows: std.ArrayList(Value) = .empty;
        for (page.rows) |row| try rows.append(a, try record(a, row));
        return wire.value(a, .{ .key = key, .events = rows.items, .next = page.next, .scanned = page.scanned, .total_unfiltered = page.total_unfiltered });
    }
    if (spans) {
        const page = try capture.spanPage(a, key, filter, @intCast(start), @intCast(limit));
        defer a.free(page.rows);
        var rows: std.ArrayList(Value) = .empty;
        for (page.rows) |row| try rows.append(a, try wire.value(a, .{
            .ordinal = row.ordinal,
            .thread_id = row.thread.id,
            .tid = row.thread.tid,
            .parent = row.parent,
            .reason = row.reason,
            .entry = if (row.entry) |r| try record(a, r) else null,
            .returned = if (row.returned) |r| try record(a, r) else null,
        }));
        return wire.value(a, .{ .key = key, .calls = rows.items, .next = page.next, .scanned = page.scanned, .total_unfiltered = page.total_unfiltered });
    }
    // Validate before spawning work, including strict boolean and cursor bounds.
    const retry = try boolean(args, "retry");
    if (start > @import("../profile/allocation_lifetimes.zig").max_calls) return error.InvalidArguments;
    try capture.requestAnalysis(retry);
    if (capture.state == .analyzing) return wire.value(a, .{ .key = key, .pending = true, .analysis_algorithm = model.algorithm });
    const page = try capture.lifetimePage(a, key, filter, @intCast(start), @intCast(limit));
    defer a.free(page.rows);
    var rows: std.ArrayList(Value) = .empty;
    for (page.rows) |row| try rows.append(a, try wire.value(a, .{
        .ordinal = row.ordinal,
        .pointer = try hex(a, row.pointer),
        .requested_bytes = row.requested_bytes,
        .state = row.state,
        .allocation_span = row.allocation_span,
        .release_span = row.release_span,
        .allocation_thread_id = row.allocation_thread.id,
        .allocation_tid = row.allocation_thread.tid,
        .min_ns = row.min_ns,
        .max_ns = row.max_ns,
    }));
    return wire.value(a, .{
        .key = key,
        .pending = false,
        .lifetimes = rows.items,
        .next = page.next,
        .scanned = page.scanned,
        .total_unfiltered = page.total_unfiltered,
        .summary = capture.summary(),
        .summary_scope = "capture",
        .filter_basis = "allocation_entry",
        .outstanding_is_leak_proof = false,
        .analysis_algorithm = model.algorithm,
    });
}

fn parsed(a: Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, text, .{ .allocate = .alloc_always })).value;
}
fn fixture(a: Allocator, sealed: bool) !*model.Capture {
    const capture = try model.Capture.create(a, .{ .session_id = 41, .capture_id = 5, .process_id = 3, .pid = 42, .image_epoch = 7 }, .{}, &.{.{ .id = 11, .tid = 42 }}, &.{.{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture.so", .device = 1, .inode = 9, .file_offset = 0x1000, .link_address = 0x1000, .runtime_address = 0x401000 }}, 100);
    errdefer capture.deinit();
    try capture.feed(0, .{ .time_ns = 110, .data = .{ .sample = .{ .hook = 1, .kind = .malloc, .phase = .enter, .stack_key = 0x8000, .arg0 = 24 } } });
    try capture.feed(0, .{ .time_ns = 120, .data = .{ .sample = .{ .hook = 1, .kind = .malloc, .phase = .leave, .stack_key = 0x8000, .result = 0xfffffffffffff123 } } });
    if (sealed) try capture.finish(130, false);
    return capture;
}
test "allocation MCP adapter preserves exact addresses and cross-links lifetime evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const capture = try fixture(std.testing.allocator, true);
    defer capture.deinit();
    const status_ = try call(a, capture, "get_allocation_capture", try parsed(a, "{}"));
    try std.testing.expectEqual(@as(i64, 3), status_.object.get("key").?.object.get("identity").?.object.get("process_id").?.integer);
    try std.testing.expectEqual(Value.null, status_.object.get("summary").?);
    const args = try parsed(a, "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"limit\":1}");
    const first = try call(a, capture, "get_allocation_events", args);
    try std.testing.expectEqual(@as(i64, 1), first.object.get("next").?.integer);
    const calls = try call(a, capture, "get_allocation_calls", args);
    const returned = calls.object.get("calls").?.array.items[0].object.get("returned").?;
    try std.testing.expectEqualStrings("0xfffffffffffff123", returned.object.get("event").?.object.get("result").?.string);
    const pending = try call(a, capture, "get_allocation_lifetimes", args);
    try std.testing.expect(pending.object.get("pending").?.bool);
    var i: usize = 0;
    while (capture.worker != null and i < 5000) : (i += 1) {
        capture.poll();
        if (capture.worker != null) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(capture.worker == null);
    const result = try call(a, capture, "get_allocation_lifetimes", args);
    const row = result.object.get("lifetimes").?.array.items[0];
    try std.testing.expectEqualStrings("0xfffffffffffff123", row.object.get("pointer").?.string);
    try std.testing.expectEqual(@as(i64, 0), row.object.get("allocation_span").?.integer);
    try std.testing.expect(!result.object.get("outstanding_is_leak_proof").?.bool);
    try std.testing.expectEqualStrings("capture", result.object.get("summary_scope").?.string);
}
test "allocation MCP adapter rejects stale and malformed requests before starting a worker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const capture = try fixture(std.testing.allocator, true);
    defer capture.deinit();
    for ([_][]const u8{
        "{\"session_id\":42,\"capture_id\":5,\"revision\":4}",
        "{\"session_id\":41,\"capture_id\":6,\"revision\":4}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":3}",
    }) |text| try std.testing.expectError(error.StaleAllocationCapture, call(a, capture, "get_allocation_lifetimes", try parsed(a, text)));
    for ([_][]const u8{
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"retry\":1}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"limit\":257}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"limit\":-1}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"start\":65537}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"pid\":99}",
        "{\"session_id\":41,\"capture_id\":5,\"revision\":4,\"from_ns\":9,\"to_ns\":8}",
        "{}",
        "[]",
    }) |text| try std.testing.expectError(error.InvalidArguments, call(a, capture, "get_allocation_lifetimes", try parsed(a, text)));
    try std.testing.expectError(error.NoAllocationCapture, call(a, null, "get_allocation_capture", try parsed(a, "{}")));
    try std.testing.expectError(error.UnknownTool, call(a, capture, "continue", try parsed(a, "{}")));
    try std.testing.expect(capture.worker == null and capture.state == .finalized);
}

test "allocation MCP cannot derive totals from paired records before source cleanup or across an unread suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const capture = try fixture(std.testing.allocator, false);
    defer capture.deinit();
    capture.abort(.decode_error);
    const status_ = try call(a, capture, "get_allocation_capture", try parsed(a, "{}"));
    try std.testing.expectEqualStrings("stopping", status_.object.get("state").?.string);
    try std.testing.expect(status_.object.get("ended_ns").? == .null);
    const args = try parsed(a, "{\"session_id\":41,\"capture_id\":5,\"revision\":4}");
    try std.testing.expectError(error.AllocationCaptureNotFinalized, call(a, capture, "get_allocation_lifetimes", args));
    try capture.finish(130, true);
    const closed = try parsed(a, "{\"session_id\":41,\"capture_id\":5,\"revision\":5}");
    try std.testing.expectError(error.AllocationEvidenceGap, call(a, capture, "get_allocation_lifetimes", closed));
    const calls = try call(a, capture, "get_allocation_calls", closed);
    try std.testing.expectEqualStrings("complete", calls.object.get("calls").?.array.items[0].object.get("reason").?.string);
    try std.testing.expect(capture.summary() == null and capture.worker == null);
}
