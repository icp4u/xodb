//! MCP reply adapter; JSON input mapping is shared with native frontends.
const std = @import("std");
const api = @import("../model/command.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const Decoded = @import("../model/json_command.zig").Decoded;
pub const handles = @import("../model/json_command.zig").handles;
pub const decode = @import("../model/json_command.zig").decode;
fn value(a: A, data: anytype) !V {
    return (try std.json.parseFromSlice(V, a, try std.json.Stringify.valueAlloc(a, data, .{}), .{ .allocate = .alloc_always })).value;
}
pub fn reply(a: A, session: anytype, op: api.Operation, result: anytype) !V {
    if (op == .breakpoint) switch (op.breakpoint) {
        .source => {
            const skipped = session.modules.skipped();
            return value(a, .{ .id = result.ids[0], .ids = result.ids, .images_not_searched = skipped.count, .image_budget = skipped.first, .session = session.snapshot() });
        },
        .symbol => return value(a, .{ .id = result.ids[0], .pending = result.pending, .session = session.snapshot() }),
        .policy => |policy| return value(a, .{ .id = policy.id, .policy = session.probes.rule(policy.id).?.*, .session = session.snapshot() }),
        else => {},
    };
    if (op == .control) switch (op.control) {
        .finish_frame, .run_to, .restart, .detach => return value(a, session.snapshot()),
        .run_to_source => {
            var out = try value(a, session.snapshot());
            const skipped = session.modules.skipped();
            try out.object.put(a, "images_not_searched", .{ .integer = @intCast(skipped.count) });
            try out.object.put(a, "image_budget", if (skipped.first) |first| .{ .string = try a.dupe(u8, first) } else .null);
            return out;
        },
        else => {},
    };
    return value(a, .{ .id = if (result.ids.len > 0) @as(?u64, result.ids[0]) else null, .session = session.snapshot() });
}

test "core protocol requests decode to typed values without caller authority" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(V, a, "{\"generation\":17,\"file\":\"fixture.c\",\"line\":9}", .{});
    defer parsed.deinit();
    const decoded = try decode("set_breakpoint", parsed.value);
    try std.testing.expectEqual(@as(u64, 17), decoded.generation);
    try std.testing.expectEqualStrings("fixture.c", decoded.operation.breakpoint.source.path);
    try std.testing.expectEqual(@as(u32, 9), decoded.operation.breakpoint.source.line);
    const injected = try std.json.parseFromSlice(V, a, "{\"generation\":17,\"client\":42}", .{});
    defer injected.deinit();
    try std.testing.expectError(error.InvalidArguments, decode("continue", injected.value));
    const no_generation = try std.json.parseFromSlice(V, a, "{}", .{});
    defer no_generation.deinit();
    try std.testing.expectError(error.GenerationRequired, decode("continue", no_generation.value));
    // Breakpoint addresses keep their hex contract; run_to keeps base detection.
    const unprefixed = try std.json.parseFromSlice(V, a, "{\"generation\":1,\"address\":\"401000\"}", .{});
    defer unprefixed.deinit();
    try std.testing.expectEqual(@as(u64, 0x401000), (try decode("set_breakpoint", unprefixed.value)).operation.breakpoint.address);
    const run = try std.json.parseFromSlice(V, a, "{\"generation\":1,\"tid\":1,\"address\":\"0x401000\"}", .{});
    defer run.deinit();
    try std.testing.expectEqual(@as(u64, 0x401000), (try decode("run_to", run.value)).operation.control.run_to.address);
    const no_thread = try std.json.parseFromSlice(V, a, "{\"generation\":1,\"id\":1,\"tid\":0}", .{});
    defer no_thread.deinit();
    try std.testing.expectError(error.UnknownThread, decode("configure_breakpoint", no_thread.value));
}

test "migrated tool catalog agrees with the command execution effect" {
    const catalog = @import("tool_catalog.zig");
    const parsed = try std.json.parseFromSlice(V, std.testing.allocator, catalog.native_definitions, .{});
    defer parsed.deinit();
    var count: usize = 0;
    for (parsed.value.array.items) |definition| {
        const name = definition.object.get("name").?.string;
        if (!handles(name)) continue;
        try std.testing.expectEqual(catalog.Access.controller, try catalog.access(definition));
        try std.testing.expect(!try catalog.readOnly(definition));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), count);
    try std.testing.expectEqual(api.Effect.execution, (api.Operation{ .control = .continue_execution }).effect());
    try std.testing.expectEqual(api.Effect.execution, (api.Operation{ .breakpoint = .{ .address = 1 } }).effect());
}

test "generated command input rejects schema violations before semantic mapping" {
    const cases = .{
        .{ "finish", "{\"generation\":1,\"tid\":1,\"frame\":63}" },
        .{ "continue", "{\"generation\":1,\"process_id\":1025}" },
        .{ "step_source", "{\"generation\":1}" },
        .{ "configure_breakpoint", "{\"generation\":1,\"id\":1,\"enabled\":1}" },
        .{ "configure_breakpoint", "{\"generation\":1,\"id\":1,\"mode\":\"other\"}" },
        .{ "run_to", "{\"generation\":1,\"tid\":1,\"file\":\"fixture.c\",\"line\":0}" },
    };
    inline for (cases) |case| {
        const parsed = try std.json.parseFromSlice(V, std.testing.allocator, case[1], .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidArguments, decode(case[0], parsed.value));
    }
}
