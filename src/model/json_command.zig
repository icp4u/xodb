//! Shared JSON-to-command adapter; no transport or live session dependency.
const std = @import("std");
const api = @import("command.zig");
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
