const std = @import("std");
const view = @import("recorded_view.zig");
const fixture = @import("archive_fixture.zig");
const model = @import("capture.zig");
const flame = @import("flame.zig");
const Budget = @import("archive_budget.zig").Budget;
const a = std.testing.allocator;
const elf_path = "zig-out/bin/xodb-profile-fixture";

fn compare(left: *const flame.Graph, right: *const flame.Graph) !void {
    try std.testing.expectEqualDeep(left.nodes.items, right.nodes.items);
    try std.testing.expectEqual(left.rejected, right.rejected);
    try std.testing.expectEqual(left.partial_samples, right.partial_samples);
    try std.testing.expectEqual(left.unverified_samples, right.unverified_samples);
}

test "recorded snapshot preserves recursion filters equal timestamps and mapping history" {
    const original = try fixture.build(a, .representative, elf_path);
    defer original.deinit();
    original.samples.coreMut(11).time_ns = original.samples.core(10).time_ns;
    const input = try view.snapshot(a, original);
    defer input.deinit();
    var multiple = model.Filter{};
    try multiple.setThreads(&.{ 4100, 4103 });
    for ([_]model.Filter{ .{}, multiple, .{ .tid = 4100 }, .{ .from_ns = 1_000_000_000, .to_ns = 1_500_000_000 }, .{ .tid = 4103, .from_ns = 10, .to_ns = 1_100_000_000 } }) |filter| {
        var expected = try original.graphDirect(a, filter);
        defer expected.deinit();
        var actual = try input.graphDirect(a, filter);
        defer actual.deinit();
        try compare(&expected, &actual);
    }
    try std.testing.expect(input.images.loaded.items[0] != original.images.loaded.items[0]);
    try std.testing.expect(input.images.loaded.items[0].debug == null);
    try std.testing.expect(!input.images.loaded.items[0].owns_mapping);
}

test "recorded worker sees dispatch snapshot while original data changes" {
    const original = try fixture.build(a, .representative, elf_path);
    defer original.deinit();
    var expected = try original.graphDirect(a, .{});
    defer expected.deinit();
    try expected.ownLabels();
    const job = try view.Job.create(1, original, .{});
    defer job.deinit();
    const key = job.key;
    const count = original.samples.len();
    try job.start();
    // A live drain can grow chunks, replace map entries and alter symbol trust.
    for (0..5000) |_| try original.samples.append(a, original.samples.get(0));
    original.samples.coreMut(0).tid = 9999;
    original.trusted_before_ns = 0;
    original.history.entries.items[1].path = "changed after dispatch";
    original.history.entries.items[1].image_id = 0;
    _ = try original.history.add(a, fixture.base_ns + 10, .{ .start = 1, .end = 2, .reason = .anonymous, .path = "new map" });
    @memset(&original.thread_names[0], 'X');
    original.revision += 1;
    original.mapping_revision += 1;
    job.join();
    try std.testing.expect(job.failure == null);
    var result = job.take() orelse return error.MissingView;
    defer result.deinit();
    try std.testing.expectEqual(count, result.sample_count);
    try std.testing.expect(key.eql(result.key));
    try std.testing.expect(!key.eql(view.Key.of(original, .{})));
    try compare(&expected, &result.graph);
    try std.testing.expect(job.input == null);
}

test "published graph and clones survive retired capture and worker destruction" {
    const original = try fixture.build(a, .representative, elf_path);
    var original_owned = true;
    defer if (original_owned) original.deinit();
    var expected = try original.graphDirect(a, .{});
    defer expected.deinit();
    try expected.ownLabels();
    const job = try view.Job.create(1, original, .{});
    var job_owned = true;
    defer if (job_owned) job.deinit();
    job.owns_source = true;
    original_owned = false;
    try job.start();
    job.join();
    var result = job.take() orelse return error.MissingView;
    var result_owned = true;
    defer if (result_owned) result.deinit();
    job.deinit();
    job_owned = false;
    try compare(&expected, &result.graph);
    var cloned = try result.graph.clone(a);
    defer cloned.deinit();
    result.deinit();
    result_owned = false;
    try compare(&expected, &cloned);
}

fn copyFailure(allocator: std.mem.Allocator, original: *const model.Capture) !void {
    var budget = Budget{ .backing = allocator, .limit = view.memory_limit };
    defer std.debug.assert(budget.used == 0);
    const input = try view.snapshot(budget.allocator(), original);
    defer input.deinit();
    var graph = try input.graphDirect(budget.allocator(), .{});
    defer graph.deinit();
    try graph.ownLabels();
}

test "recorded snapshot and graph clean up every allocation failure including ELF descriptors" {
    const original = try fixture.build(a, .representative, elf_path);
    defer original.deinit();
    try std.testing.checkAllAllocationFailures(a, copyFailure, .{original});
}

test "recorded snapshot detaches offline annotation strings" {
    const original = try fixture.build(a, .representative, elf_path);
    defer original.deinit();
    const archive = @import("archive.zig");
    const bytes = try archive.encode(a, original, .{});
    defer a.free(bytes);
    var opened = try archive.decode(a, bytes, .{ .local_id = 8 });
    var opened_owned = true;
    defer if (opened_owned) opened.deinit();
    const input = try view.snapshot(a, opened.capture);
    defer input.deinit();
    var expected = try opened.capture.graph(a, .{});
    defer expected.deinit();
    opened.deinit();
    opened_owned = false;
    var actual = try input.graphDirect(a, .{});
    defer actual.deinit();
    try compare(&expected, &actual);
}

test "recorded job cancellation memory refusal and abandoned dispatch release input" {
    const original = try fixture.build(a, .representative, null);
    defer original.deinit();
    const abandoned = try view.Job.create(1, original, .{});
    abandoned.deinit();
    const cancelled = try view.Job.create(2, original, .{});
    defer cancelled.deinit();
    cancelled.cancel.store(true, .release);
    try cancelled.start();
    cancelled.join();
    try std.testing.expectEqual(error.ArchiveCancelled, cancelled.failure.?);
    try std.testing.expect(cancelled.input == null);
    try std.testing.expect(cancelled.take() == null);
    try std.testing.expectEqual(@as(usize, 0), cancelled.budget.?.used);
    const refused = try view.Job.create(3, original, .{});
    defer refused.deinit();
    refused.budget.?.limit = refused.budget.?.used;
    try refused.start();
    refused.join();
    try std.testing.expectEqual(error.ProfileViewMemoryLimit, refused.failure.?);
    try std.testing.expectEqual(@as(usize, 0), refused.budget.?.used);
    try std.testing.expect(refused.take() == null);
    try std.testing.expectError(error.UnknownProfileThread, view.Job.create(4, original, .{ .tid = 9999 }));
}

test "maximum recorded snapshot fits worker budget and reports copy and build costs" {
    const original = try fixture.build(a, .scaled, null);
    defer original.deinit();
    const path = try original.arena.allocator().alloc(u8, 1023);
    @memset(path, 'x');
    path[0] = '/';
    for (original.history.entries.items[0..original.history.opening_count]) |*entry| entry.path = path;
    // Combine the largest mapping-path fixture with both compressible and
    // unique wide callchains. A normal compact fixture alone understates peak.
    for ([_]bool{ false, true }) |wide| {
        if (wide) {
            const records = @import("records.zig");
            var samples = model.sample_store.Store{ .max_samples = model.max_sample_limit };
            errdefer samples.deinit(a);
            for (0..original.samples.len()) |ordinal| {
                var sample = original.samples.get(ordinal);
                for (sample.frames[0..sample.frame_count], 0..) |*frame, depth| {
                    frame.raw_marker = 1 + ordinal * records.max_frames + depth;
                }
                samples.append(a, sample) catch |err| {
                    if (err == error.SampleBudget) break;
                    return err;
                };
            }
            try std.testing.expect(samples.len() > model.max_samples);
            original.samples.deinit(a);
            original.samples = samples;
        }
        const job = try view.Job.create(1, original, .{});
        defer job.deinit();
        const input_bytes = job.budget.?.used;
        try job.start();
        job.join();
        try std.testing.expect(job.failure == null);
        var result = job.take() orelse return error.MissingView;
        defer result.deinit();
        try std.testing.expect(result.peak_bytes <= view.memory_limit);
        @import("../m68k_log.zig").print("recorded worker: wide={} samples={d} input_bytes={d} peak_bytes={d} snapshot_us={d} build_us={d} nodes={d} rejected={d}\n", .{ wide, result.sample_count, input_bytes, result.peak_bytes, result.snapshot_ns / 1000, result.build_ns / 1000, result.graph.nodes.items.len, result.graph.rejected });
    }
}

const Session = @import("../model/session.zig").Session;
const rpc = @import("../mcp/profile.zig");
fn query(allocator: std.mem.Allocator, session: *Session, name: []const u8, args: anytype) !std.json.Value {
    return rpc.call(allocator, session, name, try rpc.value(allocator, args));
}

test "recorded MCP polls and pages one snapshot across new samples and rejects eviction" {
    var session = Session.init();
    defer session.deinit();
    session.profile = try fixture.build(a, .representative, elf_path);
    const capture = session.profile.?;
    const revision = capture.revision;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const pending = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id });
    try std.testing.expectEqual(@as(i64, @intCast(revision)), pending.object.get("revision").?.integer);
    try std.testing.expect(pending.object.get("pending").?.bool);
    const id = pending.object.get("view_id").?.string;
    const retained = capture.samples.len();
    try capture.samples.append(a, capture.samples.get(0));
    capture.revision += 1;
    session.recorded_views.job.?.join();
    const ready = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = revision, .view_id = id, .limit = 1 });
    try std.testing.expect(!ready.object.get("pending").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(retained)), ready.object.get("snapshot_samples").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(capture.revision)), ready.object.get("current_revision").?.integer);
    const page = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = revision, .view_id = id, .start = 1, .limit = 1 });
    try std.testing.expectEqual(@as(i64, 1), page.object.get("nodes").?.array.items[0].object.get("id").?.integer);
    _ = try query(mem, &session, "get_profile_frame", .{ .capture_id = capture.id, .revision = revision, .view_id = id, .node = 1 });
    try std.testing.expectError(error.ProfileViewRequired, query(mem, &session, "get_profile_frame", .{ .capture_id = capture.id, .revision = revision, .node = 1 }));
    try std.testing.expectError(error.ProfileViewRequired, query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = revision, .start = 1 }));
    try std.testing.expectError(error.StaleProfileView, query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = revision, .view_id = id, .tid = 4100 }));
    _ = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = capture.revision });
    session.recorded_views.job.?.join();
    session.recorded_views.poll(capture);
    try std.testing.expectError(error.StaleProfileView, query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = revision, .view_id = id }));
}

test "recorded coordinator cancels obsolete GUI filters and retires source without waiting" {
    var state = view.State{};
    defer state.deinit();
    const old = try fixture.build(a, .representative, elf_path);
    try std.testing.expectError(error.ProfileViewPending, state.request(old, old.revision, .{}, false));
    state.job.?.owner = .gui;
    try std.testing.expectError(error.ProfileViewBusy, state.request(old, old.revision, .{ .tid = 4100 }, false));
    try std.testing.expect(state.job.?.cancel.load(.acquire));
    const newer = try fixture.build(a, .empty, null);
    defer newer.deinit();
    newer.id += 1;
    state.retire(old);
    try std.testing.expect(state.job != null and state.job.?.owns_source);
    state.job.?.join();
    state.poll(newer);
    try std.testing.expect(state.result == null and state.failure == null and state.job == null);
    try std.testing.expectError(error.ProfileViewPending, state.request(newer, newer.revision, .{}, false));
    state.job.?.join();
    const result = try state.request(newer, newer.revision, .{}, false);
    try std.testing.expectEqual(newer.id, result.key.capture_id);
}

test "recorded worker failure is latched across clock revisions until explicit retry" {
    const capture = try fixture.build(a, .representative, null);
    defer capture.deinit();
    var state = view.State{};
    defer state.deinit();
    const job = try view.Job.create(1, capture, .{});
    job.budget.?.limit = job.budget.?.used;
    state.job = job;
    state.next_job = 2;
    try job.start();
    job.join();
    const failed_key = job.key;
    state.poll(capture);
    capture.revision += 1;
    try std.testing.expect(state.retained(failed_key));
    try std.testing.expectError(error.ProfileViewMemoryLimit, state.request(capture, failed_key.revision, .{}, false));
    try std.testing.expectError(error.ProfileViewMemoryLimit, state.request(capture, capture.revision, .{}, false));
    try std.testing.expect(state.job == null);
    try std.testing.expectEqual(@as(u64, 2), state.next_job);
    try std.testing.expectError(error.ProfileViewPending, state.request(capture, capture.revision, .{}, true));
    state.job.?.join();
    _ = try state.request(capture, capture.revision, .{}, false);
    try std.testing.expect(state.failure == null);
}

test "native MCP multi-thread snapshots and CPU lanes agree and reject ambiguous selection" {
    var session = Session.init();
    defer session.deinit();
    session.profile = try fixture.build(a, .representative, elf_path);
    const capture = session.profile.?;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const tids = [_]u32{ 4103, 4100 };
    const pending = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .tids = tids });
    try std.testing.expect(pending.object.get("pending").?.bool);
    session.recorded_views.job.?.join();
    const ready = try query(mem, &session, "get_flamegraph", .{ .capture_id = capture.id, .revision = capture.revision, .tids = [_]u32{ 4100, 4103 }, .view_id = pending.object.get("view_id").?.string });
    const timeline = try query(mem, &session, "get_profile_timeline", .{ .capture_id = capture.id, .revision = capture.revision, .tids = tids });
    try std.testing.expectEqual(@as(i64, 2), timeline.object.get("total_threads").?.integer);
    var expected: i64 = 0;
    for (0..capture.samples.len()) |ordinal| {
        const sample = capture.samples.core(ordinal);
        // The fixture deliberately retains one pre-capture sample for 4100.
        if (sample.time_ns >= capture.started_ns and (sample.tid == 4100 or sample.tid == 4103)) expected += 1;
    }
    try std.testing.expectEqual(expected, ready.object.get("samples").?.integer);
    try std.testing.expectEqual(expected, timeline.object.get("samples").?.integer);
    try std.testing.expectEqual(@as(usize, 2), ready.object.get("filter").?.object.get("tids").?.array.items.len);
    try std.testing.expectError(error.InvalidArguments, query(mem, &session, "get_profile_timeline", .{ .capture_id = capture.id, .revision = capture.revision, .tid = 4100, .tids = tids }));
    try std.testing.expectError(error.InvalidArguments, query(mem, &session, "get_profile_timeline", .{ .capture_id = capture.id, .revision = capture.revision, .tids = [_]u32{ 4100, 4100 } }));
    try std.testing.expectError(error.UnknownProfileThread, query(mem, &session, "get_profile_timeline", .{ .capture_id = capture.id, .revision = capture.revision, .tids = [_]u32{ 4100, 9999 } }));
}
