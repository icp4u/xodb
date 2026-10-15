//! JSON adapter only. Execution and authority belong to model commands.
const std = @import("std");
const api = @import("../model/command.zig");
const input = @import("command_decode.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const Decoded = struct { operation: api.Operation, generation: u64 };
pub const handles = input.handles;
fn thread(value_: u64) !i32 {
    if (value_ == 0 or value_ > std.math.maxInt(i32)) return error.InvalidArguments;
    return @intCast(value_);
}
fn source(path: ?[]const u8, line: ?u64) !api.Source {
    const number = line orelse return error.InvalidArguments;
    if (number == 0 or number > std.math.maxInt(u32)) return error.InvalidArguments;
    return .{ .path = path orelse return error.InvalidArguments, .line = @intCast(number) };
}
fn address(given: ?[]const u8, base: u8) !u64 {
    const text = given orelse return error.InvalidArguments;
    const digits = if (base == 16 and std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    return std.fmt.parseInt(u64, digits, base) catch error.InvalidArguments;
}
pub fn decode(name: []const u8, args: V) !Decoded {
    const request = try input.decode(name, args);
    const generation = switch (request) {
        inline else => |p| p.generation,
    };
    const operation: api.Operation = switch (request) {
        .@"continue" => .{ .control = .continue_execution },
        .interrupt => .{ .control = .interrupt },
        .restart => .{ .control = .restart },
        .detach => .{ .control = .detach },
        .step_instruction => |p| .{ .control = .{ .step_instruction = try thread(p.tid) } },
        .step_over_instruction => |p| .{ .control = .{ .step_over_instruction = try thread(p.tid) } },
        inline .step_source, .step_over => |p| .{ .control = .{ .step_source = .{ .tid = try thread(p.tid), .over = request == .step_over } } },
        .set_breakpoint => |p| blk: {
            if (p.file != null) {
                if (p.address != null or p.symbol != null) return error.InvalidArguments;
                break :blk .{ .breakpoint = .{ .source = try source(p.file, p.line) } };
            }
            if (p.line != null) return error.InvalidArguments;
            if (p.symbol) |symbol| {
                if (p.address != null) return error.InvalidArguments;
                break :blk .{ .breakpoint = .{ .symbol = symbol } };
            }
            // set_breakpoint has always meant hex, with optional 0x.
            break :blk .{ .breakpoint = .{ .address = try address(p.address, 16) } };
        },
        .remove_breakpoint => |p| .{ .breakpoint = .{ .remove = p.id } },
        .configure_breakpoint => |p| blk: {
            var policy: api.Policy = .{ .id = p.id, .enabled = p.enabled orelse true, .condition = p.condition orelse "", .log_expression = p.log_expression orelse "", .ignore_count = p.ignore_count orelse 0 };
            policy.mode = std.meta.stringToEnum(@FieldType(api.Policy, "mode"), p.mode orelse "stop") orelse return error.InvalidArguments;
            if (p.tid) |tid| policy.tid = thread(tid) catch return error.UnknownThread;
            break :blk .{ .breakpoint = .{ .policy = policy } };
        },
        .finish => |p| blk: {
            const frame = p.frame orelse 0;
            break :blk .{ .control = .{ .finish_frame = .{ .tid = try thread(p.tid), .frame = @intCast(frame) } } };
        },
        .run_to => |p| blk: {
            const tid = try thread(p.tid);
            if (p.file != null) {
                if (p.address != null) return error.InvalidArguments;
                const location = try source(p.file, p.line);
                break :blk .{ .control = .{ .run_to_source = .{ .tid = tid, .path = location.path, .line = location.line } } };
            }
            if (p.line != null) return error.InvalidArguments;
            // run_to retains its base-detection contract.
            break :blk .{ .control = .{ .run_to = .{ .tid = tid, .address = try address(p.address, 0) } } };
        },
    };
    return .{ .operation = operation, .generation = generation };
}
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
