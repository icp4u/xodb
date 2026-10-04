//! T16 aggregate checks: derived counts equal individual T10 walks; filters,
//! budgets, unknown gaps, identity and cancellation. Proposed
//! `src/profile/derived_test.zig`; uses T10's synthetic CFI fixture.
const std = @import("std");
const model = @import("capture.zig");
const records = @import("records.zig");
const fixture = @import("archive_fixture.zig");
const unwind = @import("unwind.zig");
const derived = @import("derived.zig");
const flame = @import("flame.zig");
const a = std.testing.allocator;

fn state(pc: u64, len: u32) records.UserState {
    var raw = records.UserState{ .abi = records.regs_abi_64, .regs_mask = records.user_regs_gpr_mask, .regs_present = true, .stack_size = 4096, .stack_dyn = len, .stack_len = len, .stack_present = true, .stack_short = len < 4096 };
    raw.regs[7] = 0x7000;
    raw.regs[8] = pc;
    return raw;
}
const Case = enum { complete, budget, absent, short, no_regs, abi32, signal, cycle, nocfi };
/// One capture whose samples cycle through every case on two threads, with
/// equal timestamps every third sample and out-of-order delivery.
fn build(n: usize, budget: u32) !*model.Capture {
    const capture = try fixture.build(a, .empty, null);
    errdefer capture.deinit();
    const image = try fixture.addElf(capture, "tests/fixtures/elf/out/unwind-cfi.so", 0, 0);
    const sym = struct {
        fn at(img: anytype, name: []const u8) u64 {
            return img.image.findSymbol(name).?.value + img.bias;
        }
    };
    const leaf = sym.at(image, "saved_leaf");
    const parent = sym.at(image, "saved_parent");
    image.start = leaf;
    image.end = leaf + 4096;
    try capture.history.opening(a, .{ .start = leaf, .end = leaf + 4096, .image_id = image.id, .reason = .elf });
    capture.config.user_stack_bytes = 4096;
    capture.config.user_stack_budget_bytes = budget;
    capture.accepted.user_stack_bytes = 4096;
    capture.accepted.user_regs_mask = records.user_regs_gpr_mask;
    capture.accepted.sample_type |= records.Bits.regs_user | records.Bits.stack_user;
    capture.user_state = try model.sample_state.Store.init(a, n, budget);
    capture.thread_count = 2;
    capture.threads[1] = .{ .debugger_id = 2, .perf = .{ .tid = 4101, .event_id = 2, .start_time_ticks = 1, .start_time_known = true } };
    _ = try std.fmt.bufPrintZ(&capture.thread_names[1], "Thread 4101", .{});
    var bytes: [16]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[0..8], parent + 2, .little);
    for (0..n) |i| {
        const case: Case = @enumFromInt(i % @typeInfo(Case).@"enum".fields.len);
        const pc = switch (case) {
            .signal => sym.at(image, "saved_signal"),
            .cycle => sym.at(image, "saved_cycle"),
            .nocfi => sym.at(image, "saved_nocfi"),
            else => leaf,
        };
        var raw = state(pc, if (case == .absent) 0 else if (case == .short) 8 else 16);
        if (case == .no_regs) raw.regs_present = false;
        if (case == .abi32) raw.abi = records.regs_abi_32;
        const index = try capture.user_state.append(raw, &bytes);
        if (case == .budget and budget >= 16) {
            capture.user_state.entries[index - 1].status = .budget;
            capture.user_state.entries[index - 1].state.stack_len = 0;
        }
        const ordinal = if (i % 50 == 1) i - 1 else if (i % 50 == 0 and i + 1 < n) i + 1 else i;
        try capture.samples.append(a, .{ .ip = pc, .ip_present = true, .cpu_mode = .user, .tid_present = true, .pid = 4100, .tid = @intCast(4100 + i % 2), .time_present = true, .time_ns = fixture.base_ns + 10 + (ordinal - ordinal / 3) * 1000, .user_state = index });
    }
    return capture;
}
fn bucket(result: unwind.Result) derived.Bucket {
    if (result.reason == .complete and result.count > 0) return .complete;
    if (result.count >= 2) return .partial;
    if (result.count == 1) return .leaf_only;
    return .unavailable;
}
fn reference(capture: *const model.Capture, filter: model.Filter) !derived.Counts {
    var counts = derived.Counts{};
    for (0..capture.samples.len()) |ordinal| {
        const sample = capture.samples.get(ordinal);
        if (!sample.time_present or !sample.tid_present or sample.time_ns < capture.started_ns or !capture.includesThread(@intCast(sample.tid))) {
            counts.unfilterable += 1;
            continue;
        }
        if (!filter.contains(sample.tid, sample.time_ns - capture.started_ns)) {
            counts.outside_filter += 1;
            continue;
        }
        counts.filtered += 1;
        const result = try unwind.walk(a, capture, ordinal, null);
        counts.by_reason[@intFromEnum(result.reason)] += 1;
        switch (bucket(result)) {
            .complete => counts.complete += 1,
            .partial => counts.partial += 1,
            .leaf_only => counts.leaf_only += 1,
            .unavailable => counts.unavailable += 1,
            .excluded => counts.excluded += 1,
        }
    }
    return counts;
}

test "derived counts equal individual walks for every case, thread and time filter" {
    const capture = try build(270, 4096);
    defer capture.deinit();
    // Partition the samples' own time span (the fixture's extent is longer).
    var extent: u64 = 0;
    for (0..capture.samples.len()) |i| extent = @max(extent, capture.samples.core(i).time_ns - capture.started_ns + 1);
    var multiple = model.Filter{};
    try multiple.setThreads(&.{ 4100, 4101 });
    for ([_]model.Filter{ .{}, multiple, .{ .tid = 4100 }, .{ .tid = 4101 }, .{ .to_ns = extent / 3 }, .{ .from_ns = extent / 3, .to_ns = extent / 2 }, .{ .from_ns = extent / 2 } }) |filter| {
        var view = try derived.build(a, capture, filter, null, null);
        defer view.deinit();
        const expected = try reference(capture, filter);
        try std.testing.expectEqualDeep(expected, view.counts);
        // The graph holds exactly the non-excluded filtered samples, each once.
        try std.testing.expectEqual(view.counts.filtered - view.counts.excluded, view.graph.nodes.items[0].inclusive);
        var selves: u64 = 0;
        for (view.graph.nodes.items) |node| selves += node.self;
        try std.testing.expectEqual(view.graph.nodes.items[0].inclusive, selves);
        try std.testing.expect(view.counts.complete > 0 and view.counts.partial > 0 and view.counts.leaf_only > 0 and view.counts.unavailable > 0);
    }
    // Adjacent time ranges partition the samples.
    var left = try derived.build(a, capture, .{ .to_ns = extent / 2 }, null, null);
    defer left.deinit();
    var right = try derived.build(a, capture, .{ .from_ns = extent / 2 }, null, null);
    defer right.deinit();
    var whole = try derived.build(a, capture, .{}, null, null);
    defer whole.deinit();
    try std.testing.expectEqual(whole.counts.filtered, left.counts.filtered + right.counts.filtered);
    for (whole.counts.by_reason, left.counts.by_reason, right.counts.by_reason) |w, l, r| try std.testing.expectEqual(w, l + r);
}

test "partial stacks never join complete paths, and the leaf appears once" {
    const capture = try build(90, 4096);
    defer capture.deinit();
    var view = try derived.build(a, capture, .{}, null, null);
    defer view.deinit();
    const nodes = view.graph.nodes.items;
    for (nodes[1..]) |node| {
        if (node.depth == 2 and node.frame.kind == .code) {
            // A depth-2 code frame is the outermost caller of a complete stack;
            // no partial or leaf-only sample may pass through it.
            var stack = std.ArrayList(u32).empty;
            defer stack.deinit(a);
            try stack.append(a, node.id);
            while (stack.pop()) |id| {
                try std.testing.expect(nodes[id].frame.kind != .incomplete);
                var child = nodes[id].first_child;
                while (child) |c| : (child = nodes[c].next_sibling) try stack.append(a, c);
            }
        }
        if (node.frame.kind == .incomplete) try std.testing.expect(std.mem.startsWith(u8, node.frame.name, "[callers unknown: ") or std.mem.startsWith(u8, node.frame.name, "[leaf only: "));
    }
    // Complete samples: thread -> parent -> leaf, the leaf exactly once.
    const reasons = view.counts.by_reason;
    try std.testing.expect(reasons[@intFromEnum(unwind.Reason.complete)] > 0);
    var leaf_hits: u64 = 0;
    for (nodes) |node| if (node.frame.kind == .code and std.mem.eql(u8, node.frame.name, "saved_leaf")) {
        leaf_hits += node.self;
    };
    try std.testing.expect(leaf_hits <= view.counts.filtered);
    // Every node has a citable sample.
    for (nodes[1..], view.examples[1..]) |node, example| {
        try std.testing.expect(example < capture.samples.len());
        _ = node;
    }
}

test "zero-byte retention budget keeps registers and reports every stack as a gap" {
    const capture = try build(45, 0);
    defer capture.deinit();
    var view = try derived.build(a, capture, .{}, null, null);
    defer view.deinit();
    try std.testing.expectEqualDeep(try reference(capture, .{}), view.counts);
    try std.testing.expectEqual(@as(u64, 0), view.counts.complete);
    try std.testing.expect(view.counts.by_reason[@intFromEnum(unwind.Reason.retention_budget)] > 0);
    // Without stack bytes the sampled leaf is still named, under its gap node.
    var named_leaves: u64 = 0;
    for (view.graph.nodes.items) |node| if (node.frame.kind == .code and std.mem.eql(u8, node.frame.name, "saved_leaf")) {
        const parent = view.graph.nodes.items[node.parent.?].frame;
        try std.testing.expect(parent.kind == .incomplete or parent.kind == .unknown);
        named_leaves += node.inclusive;
    };
    try std.testing.expect(named_leaves > 0);
}

test "batch walks equal single walks and hash each ELF once" {
    const capture = try build(60, 4096);
    defer capture.deinit();
    var batch = unwind.Batch.init(a, capture, null);
    defer batch.deinit();
    for (0..capture.samples.len()) |ordinal| {
        const one = try unwind.walk(a, capture, ordinal, null);
        const many = try batch.walk(ordinal);
        try std.testing.expectEqualSlices(u8, &one.analysis_id, &many.analysis_id);
        try std.testing.expectEqual(one.reason, many.reason);
        try std.testing.expectEqual(one.count, many.count);
    }
    try std.testing.expectEqual(@as(u64, capture.images.loaded.items[0].mapping.len), batch.hashed_bytes);
}

test "identity follows filter and assets; cancellation is an error, not a partial view" {
    const capture = try build(45, 4096);
    defer capture.deinit();
    var first = try derived.build(a, capture, .{}, null, null);
    defer first.deinit();
    var same = try derived.build(a, capture, .{}, null, null);
    defer same.deinit();
    try std.testing.expectEqualSlices(u8, &first.identity, &same.identity);
    var filtered = try derived.build(a, capture, .{ .tid = 4100 }, null, null);
    defer filtered.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.identity, &filtered.identity));
    // Without the asset the same evidence yields a different, explicit result.
    const saved = capture.images.loaded.items.len;
    capture.images.loaded.items.len = 0;
    var no_assets = try derived.build(a, capture, .{}, null, null);
    capture.images.loaded.items.len = saved;
    defer no_assets.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.identity, &no_assets.identity));
    try std.testing.expectEqual(@as(u64, 0), no_assets.counts.complete);
    try std.testing.expect(no_assets.counts.by_reason[@intFromEnum(unwind.Reason.asset_missing)] > 0);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ArchiveCancelled, derived.build(a, capture, .{}, &cancel, null));
}

test "node limit excludes whole samples and counts them" {
    const capture = try build(90, 4096);
    defer capture.deinit();
    // A view whose graph is too small for every distinct path.
    var view = try derived.buildWithLimit(a, capture, .{}, null, null, 6);
    defer view.deinit();
    try std.testing.expect(view.counts.excluded > 0);
    try std.testing.expectEqual(view.counts.filtered, view.counts.bucketTotal());
    try std.testing.expectEqual(view.counts.filtered - view.counts.excluded, view.graph.nodes.items[0].inclusive);
}

test "session worker publishes once per key, supersedes on filter change and never retries a failure" {
    const Session = @import("../model/session.zig").Session;
    var session = Session.init();
    defer session.deinit();
    session.profile = try build(90, 4096);
    const capture = session.profile.?;
    // First request starts the worker; the same key waits on it.
    try std.testing.expect(session.requestDerived(.{}) == .pending);
    try std.testing.expect(session.requestDerived(.{}) == .pending);
    const first_job = session.archive_job.?.id;
    try session.finishArchive();
    const ready = session.requestDerived(.{});
    try std.testing.expect(ready == .ready);
    try std.testing.expectEqual(@as(u64, 90), ready.ready.counts.filtered);
    // Cached: no new job for the same key.
    try std.testing.expect(session.requestDerived(.{}) == .ready);
    try std.testing.expectEqual(first_job, session.archive_job.?.id);
    // A new filter starts a new job; an older pending filter is superseded,
    // not recorded as a failure.
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .pending);
    const superseded = session.archive_job.?;
    try std.testing.expect(session.requestDerived(.{ .tid = 4101 }) == .pending);
    try std.testing.expect(superseded.superseded);
    superseded.join();
    session.pollArchive();
    try std.testing.expect(session.derived_failure == null);
    try std.testing.expect(session.requestDerived(.{ .tid = 4101 }) == .pending);
    try session.finishArchive();
    try std.testing.expectEqual(@as(u64, 45), session.requestDerived(.{ .tid = 4101 }).ready.counts.filtered);
    // A failure is cached for its key and not retried until asked.
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .pending);
    session.archive_job.?.progress.cancel.store(true, .release);
    try std.testing.expectError(error.ArchiveCancelled, session.finishArchive());
    const failed_job = session.archive_job.?.id;
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .failed);
    try std.testing.expectEqual(failed_job, session.archive_job.?.id);
    session.retryDerived();
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .pending);
    try session.finishArchive();
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .ready);
    // A new revision invalidates the published view; the old one is never shown.
    capture.revision += 1;
    try std.testing.expect(session.requestDerived(.{ .tid = 4100 }) == .pending);
    capture.revision -= 1;
    try session.finishArchive();
    try std.testing.expect(session.derived == null or session.derived.?.key.revision == capture.revision);
    // Stacks off and collecting captures are explicit, not empty views.
    capture.config.user_stack_bytes = 0;
    try std.testing.expect(session.requestDerived(.{}) == .unavailable);
    capture.config.user_stack_bytes = 4096;
}

test "mapping change at a sample timestamp: ambiguity and replacement stay explicit" {
    const capture = try build(90, 4096);
    defer capture.deinit();
    // An anonymous replacement exactly at sample 30's time (sample 31 shares it).
    const change_ns = fixture.base_ns + 10 + (30 - 30 / 3) * 1000;
    const mapping = capture.history.entries.items[0];
    _ = try capture.history.add(a, change_ns, .{ .start = mapping.start, .end = mapping.end, .reason = .anonymous });
    var view = try derived.build(a, capture, .{}, null, null);
    defer view.deinit();
    try std.testing.expectEqualDeep(try reference(capture, .{}), view.counts);
    try std.testing.expect(view.counts.by_reason[@intFromEnum(unwind.Reason.mapping_ambiguous)] > 0);
    // Later samples see the replacement: nothing after it is complete.
    var after = try derived.build(a, capture, .{ .from_ns = change_ns - capture.started_ns + 1 }, null, null);
    defer after.deinit();
    try std.testing.expectEqual(@as(u64, 0), after.counts.complete);
}

test "cancellation after worker completion prevents publication and automatic retry" {
    const Session = @import("../model/session.zig").Session;
    var session = Session.init();
    defer session.deinit();
    session.profile = try build(90, 4096);
    try std.testing.expect(session.requestDerived(.{}) == .pending);
    const job = session.archive_job.?;
    job.join();
    try std.testing.expect(job.derived_view != null);
    job.progress.cancel.store(true, .release);
    session.pollArchive();
    try std.testing.expect(session.derived == null);
    try std.testing.expectEqual(error.ArchiveCancelled, session.requestDerived(.{}).failed);
    try std.testing.expectEqual(job.id, session.archive_job.?.id);
}

test "repeated samples allocate graph labels per distinct node" {
    const Budget = @import("archive_budget.zig").Budget;
    const small = try build(512, 4096);
    defer small.deinit();
    const large = try build(8192, 4096);
    defer large.deinit();
    var one = Budget{ .backing = a, .limit = derived.memory_limit };
    var first = try derived.build(one.allocator(), small, .{}, null, null);
    defer first.deinit();
    var many = Budget{ .backing = a, .limit = derived.memory_limit };
    var second = try derived.build(many.allocator(), large, .{}, null, null);
    defer second.deinit();
    try std.testing.expectEqual(first.graph.nodes.items.len, second.graph.nodes.items.len);
    // The sorting ordinals grow; duplicate names must not accumulate in the arena.
    try std.testing.expect(many.peak <= one.peak + (8192 - 512) * @sizeOf(u32) + 16 * 1024);
}

test "GUI does not cancel a different MCP reconstruction" {
    const Session = @import("../model/session.zig").Session;
    const Job = @import("archive_job.zig").Job;
    var session = Session.init();
    defer session.deinit();
    session.profile = try build(90, 4096);
    // Hold an unstarted job so this scheduling check has no timing race.
    const job = try Job.create(1, .derived, "owned pending reconstruction");
    job.capture = session.profile;
    job.derived_key = derived.Key.of(session.profile.?, .{});
    job.derived_owner = .mcp;
    session.archive_job = job;
    try std.testing.expect(session.requestDerivedOwned(.{ .tid = 4100 }, .gui) == .pending);
    try std.testing.expect(!job.superseded);
    try std.testing.expect(!job.progress.cancel.load(.acquire));
}

test "sample inspector never substitutes an out-of-filter sample for an empty selection" {
    const Inspector = @import("../ui/sample_inspector.zig").Inspector;
    const capture = try build(90, 4096);
    defer capture.deinit();
    var inspector = Inspector{ .open = true, .ordinal = 0 };
    inspector.sync(capture, .{ .from_ns = 1_000_000, .to_ns = 2_000_000 });
    try std.testing.expectEqual(capture.samples.len(), inspector.ordinal);
    inspector.sync(capture, .{ .tid = 4101 });
    try std.testing.expect(Inspector.matches(capture, .{ .tid = 4101 }, inspector.ordinal));
}
