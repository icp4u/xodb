//! MCP surface for inferior calls. Authorization comes from the central
//! schema policy (xodbSessionAccess "executor") and is checked again by the
//! model; consent is the explicit allow_execution argument.
const std = @import("std");
const execution = @import("../model/execution.zig");
const Session = execution.Session;
const wire = @import("profile.zig");
const Value = std.json.Value;

pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "execute_call") or std.mem.eql(u8, name, "resolve_execution") or std.mem.eql(u8, name, "get_execution_state");
}
fn text(args: Value, key: []const u8) !?[]const u8 {
    const v = args.object.get(key) orelse return null;
    if (v != .string) return error.InvalidArguments;
    return v.string;
}
fn asValue(a: std.mem.Allocator, value: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{ .allocate = .alloc_always })).value;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value, detail: *?[]const u8) !Value {
    if (std.mem.eql(u8, name, "get_execution_state")) {
        try wire.fields(args, &.{});
        return asValue(a, .{ .generation = session.target.snapshot().generation, .call_frame_active = session.execution.active, .executions = session.execution.sequence, .journal = session.execution.entries(), .effects = execution.effects_note });
    }
    if (std.mem.eql(u8, name, "resolve_execution")) {
        try wire.fields(args, &.{ "action", "generation" });
        const action = (try text(args, "action")) orelse return error.InvalidArguments;
        const restore = if (std.mem.eql(u8, action, "restore")) true else if (std.mem.eql(u8, action, "abandon")) false else return error.InvalidArguments;
        if (args.object.get("generation") == null) return error.GenerationRequired;
        return asValue(a, try execution.resolve(session, .agent, try wire.number(args, "generation", null), restore));
    }
    try wire.fields(args, &.{ "tid", "frame", "callee", "arguments", "prototype", "this", "timeout_ms", "allow_execution", "generation" });
    const consent = args.object.get("allow_execution") orelse return error.ExecutionConsentRequired;
    if (consent != .bool) return error.InvalidArguments;
    if (!consent.bool) return error.ExecutionConsentRequired;
    if (args.object.get("generation") == null) return error.GenerationRequired;
    const generation = try wire.number(args, "generation", null);
    const tid = try wire.number(args, "tid", null);
    if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
    const frame = try wire.number(args, "frame", 0);
    if (frame >= 64) return error.InvalidArguments;
    const timeout = try wire.number(args, "timeout_ms", execution.default_timeout_ms);
    if (timeout == 0 or timeout > execution.max_timeout_ms) return error.InvalidArguments;
    var arguments: std.ArrayList([]const u8) = .empty;
    if (args.object.get("arguments")) |list| {
        if (list != .array or list.array.items.len > execution.max_arguments) return error.InvalidArguments;
        for (list.array.items) |item| {
            if (item != .string or item.string.len == 0 or item.string.len > 4096) return error.InvalidArguments;
            try arguments.append(a, item.string);
        }
    }
    const callee = (try text(args, "callee")) orelse return error.InvalidArguments;
    if (callee.len == 0 or callee.len > 1024) return error.InvalidArguments;
    const result = try execution.call(session, a, .agent, generation, .{
        .tid = @intCast(tid),
        .frame = @intCast(frame),
        .callee = callee,
        .arguments = arguments.items,
        .prototype = try text(args, "prototype"),
        .this = try text(args, "this"),
        .timeout_ms = timeout,
    }, detail);
    return asValue(a, result);
}
