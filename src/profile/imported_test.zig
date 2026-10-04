const std = @import("std");
const model = @import("imported.zig");
const fixture = @embedFile("imported_fixture.json");
test "import preserves raw sites and weighted time/thread partitions" {
    const p = try model.Profile.decode(fixture, null);
    defer p.deinit();
    try std.testing.expectEqual(@as(u64, 100), p.first_ns);
    try std.testing.expectEqual(@as(u64, 21), p.extent_ns);
    try std.testing.expectEqualStrings("0x1020", p.wire.samples[0].stack[1].ip);
    const full = try model.View.build(p, .{}, null);
    defer full.deinit();
    try std.testing.expectEqual(@as(u64, 31), full.graph.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(usize, 1), full.unresolved_samples);
    const thread = try model.View.build(p, .{ .tid = 1 }, null);
    defer thread.deinit();
    try std.testing.expectEqual(@as(u64, 20), thread.total_period);
    const range = try model.View.build(p, .{ .from_ns = 10, .to_ns = 20 }, null);
    defer range.deinit();
    try std.testing.expectEqual(@as(usize, 1), range.samples);
    try std.testing.expectEqual(@as(u64, 7), range.total_period);
    const empty = try model.View.build(p, .{ .from_ns = 40, .to_ns = 50 }, null);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.samples);
    try std.testing.expectEqual(std.math.maxInt(usize), empty.examples[0]);
    try std.testing.expect(!std.mem.eql(u8, &full.id, &range.id));
    for (full.graph.nodes.items) |node| {
        var child_sum: u64 = 0;
        var child = node.first_child;
        while (child) |id| {
            child_sum += full.graph.nodes.items[id].inclusive;
            child = full.graph.nodes.items[id].next_sibling;
        }
        try std.testing.expectEqual(node.inclusive, node.self + child_sum);
        try std.testing.expect(full.examples[node.id] < p.wire.samples.len);
    }
}
fn changed(old: []const u8, new: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, std.testing.allocator, fixture, old, new);
}
test "import rejects unsupported scope, references, units, integers and weight overflow" {
    const cases = .{
        .{ "\"version\":1", "\"version\":2", error.ImportVersionUnsupported },
        .{ "\"unit\":\"nanoseconds\"", "\"unit\":\"cycles\"", error.ImportUnitMismatch },
        .{ "\"frame\":2", "\"frame\":999", error.ImportReference },
        .{ "\"pid\":7,\"tid\":2", "\"pid\":8,\"tid\":2", error.ImportScopeUnsupported },
        .{ "\"period\":\"7\"", "\"period\":\"0\"", error.ImportInvalidPeriod },
        .{ "\"period\":\"7\"", "\"period\":\"18446744073709551615\"", error.ImportOverflow },
        .{ "\"period\":\"7\"", "\"period\":\"-1\"", error.ImportInvalidInteger },
    };
    inline for (cases) |case| {
        const input = try changed(case[0], case[1]);
        defer std.testing.allocator.free(input);
        try std.testing.expectError(case[2], model.Profile.decode(input, null));
    }
}
test "import cancellation and invalid thread filters stay explicit" {
    var progress = @import("archive_progress.zig").Progress{};
    progress.cancel.store(true, .release);
    try std.testing.expectError(error.ArchiveCancelled, model.Profile.decode(fixture, &progress));
    const p = try model.Profile.decode(fixture, null);
    defer p.deinit();
    try std.testing.expectError(error.InvalidProfileThread, model.View.build(p, .{ .tid = 77 }, null));
    try std.testing.expectError(error.ArchiveCancelled, model.View.build(p, .{}, &progress));
}

test "GUI and MCP imported workers publish independent views; cancellation wins" {
    const jobs = @import("imported_job.zig");
    const p = try model.Profile.decode(fixture, null);
    var state = jobs.State{ .profile = p, .full = try model.View.build(p, .{}, null) };
    defer state.deinit();
    const gui_filter = model.Filter{ .tid = 1 };
    const mcp_filter = model.Filter{ .tid = 2 };
    try std.testing.expect(state.request(gui_filter, .gui) == .pending);
    try std.testing.expect(state.request(mcp_filter, .mcp) == .pending);
    const deadline = @import("../target/linux.zig").now() + 5_000_000_000;
    while (state.gui.job != null or state.mcp.job != null) {
        try std.testing.expect(@import("../target/linux.zig").now() < deadline);
        _ = @import("../c.zig").api.usleep(1000);
        state.poll();
    }
    const gui = state.request(gui_filter, .gui).ready;
    const mcp = state.request(mcp_filter, .mcp).ready;
    try std.testing.expectEqual(@as(u64, 20), gui.total_period);
    try std.testing.expectEqual(@as(u64, 11), mcp.total_period);
    const next = model.Filter{ .to_ns = 10 };
    try std.testing.expect(state.request(next, .gui) == .pending);
    while (!state.gui.job.?.done.load(.acquire)) {
        try std.testing.expect(@import("../target/linux.zig").now() < deadline);
        _ = @import("../c.zig").api.usleep(1000);
    }
    state.cancel(.gui);
    state.poll();
    try std.testing.expectEqual(error.ImportCancelled, state.request(next, .gui).failed);
    try std.testing.expectEqual(mcp, state.request(mcp_filter, .mcp).ready);
    state.retry(.gui);
    try std.testing.expect(state.request(next, .gui) == .pending);
    // Deinit cancels and joins the outstanding worker before freeing its input.
}

test "import multi-thread views canonicalize identity and keep weights and time bounds" {
    const p = try model.Profile.decode(fixture, null);
    defer p.deinit();
    var filter = model.Filter{ .from_ns = 0, .to_ns = 15 };
    try filter.setThreads(&.{ 2, 1 });
    const view = try model.View.build(p, filter, null);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 2), view.samples);
    try std.testing.expectEqual(@as(u64, 18), view.total_period);
    var same = filter;
    try same.setThreads(&.{ 1, 2 });
    try std.testing.expectEqual(p.viewId(filter), p.viewId(same));
    try std.testing.expect(!std.mem.eql(u8, &p.viewId(filter), &p.viewId(.{ .from_ns = 0, .to_ns = 15 })));
    try same.setThreads(&.{ 1, 77 });
    try std.testing.expectError(error.InvalidProfileThread, model.View.build(p, same, null));
}
