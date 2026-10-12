//! Read-only Redot/Godot scene and object views from the engine debugger peer.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Value = std.json.Value;

pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_redot_scene_tree") or std.mem.eql(u8, name, "inspect_redot_object");
}

fn asValue(a: std.mem.Allocator, value: anytype) !Value {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    return (try std.json.parseFromSlice(Value, a, text, .{ .allocate = .alloc_always })).value;
}

fn fields(args: Value, allowed: []const []const u8) !void {
    if (args != .object) return error.InvalidArguments;
    var it = args.object.iterator();
    while (it.next()) |field| for (allowed) |name| {
        if (std.mem.eql(u8, field.key_ptr.*, name)) break;
    } else return error.InvalidArguments;
}

fn number(args: Value, key: []const u8, default: u64, maximum: u64) !u64 {
    const value = args.object.get(key) orelse return default;
    if (value != .integer or value.integer < 0 or value.integer > maximum) return error.InvalidArguments;
    return @intCast(value.integer);
}

fn boolean(args: Value, key: []const u8) !bool {
    const value = args.object.get(key) orelse return false;
    if (value != .bool) return error.InvalidArguments;
    return value.bool;
}

fn objectId(args: Value) !u64 {
    const value = args.object.get("object_id") orelse return error.InvalidArguments;
    return switch (value) {
        .integer => |id| if (id > 0) @intCast(id) else error.InvalidArguments,
        .string => |id| value: {
            const parsed = std.fmt.parseInt(u64, id, 10) catch return error.InvalidArguments;
            if (parsed == 0) return error.InvalidArguments;
            break :value parsed;
        },
        else => error.InvalidArguments,
    };
}

const Node = struct {
    depth: u16,
    child_count: u32,
    name: []const u8,
    type_name: []const u8,
    object_id: []const u8,
    scene_path: []const u8,
    script_path: ?[]const u8,
    view_flags: u8,
};

const Object = struct {
    id: []const u8,
    class_name: []const u8,
    script_path: ?[]const u8,
    properties: []const @import("../redot/protocol.zig").Property,
    signals: []const @import("../redot/protocol.zig").Signal,
};

pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value) !Value {
    const snapshot = session.redot.snapshot();
    if (std.mem.eql(u8, name, "get_redot_scene_tree")) {
        try fields(args, &.{ "start", "limit", "refresh" });
        const start = try number(args, "start", 0, snapshot.nodes.len);
        const limit = try number(args, "limit", 256, 512);
        if (limit == 0) return error.InvalidArguments;
        if ((snapshot.nodes.len == 0 or try boolean(args, "refresh")) and !snapshot.scene_pending) session.redot.requestScene() catch |err| switch (err) {
            // The answer's state and diagnostic say why nothing was asked.
            error.RedotDebuggerPending, error.RedotDebuggerClosed, error.RedotDebuggerProtocolError => {},
            else => return err,
        };
        const current = session.redot.snapshot();
        const end = @min(current.nodes.len, start + limit);
        const rows = try a.alloc(Node, end - start);
        for (current.nodes[start..end], rows) |node, *row| row.* = .{
            .depth = node.depth,
            .child_count = node.child_count,
            .name = node.name,
            .type_name = node.type_name,
            .object_id = try std.fmt.allocPrint(a, "{d}", .{node.object_id}),
            .scene_path = node.scene_path,
            .script_path = node.script_path,
            .view_flags = node.view_flags,
        };
        return asValue(a, .{ .source = "engine_debugger_protocol", .state = current.state, .diagnostic = current.diagnostic, .revision = current.scene_revision, .pending = current.scene_pending, .total = current.nodes.len, .start = start, .next = if (end < current.nodes.len) end else null, .nodes = rows });
    }
    try fields(args, &.{ "object_id", "refresh" });
    const id = try objectId(args);
    if (snapshot.selected_id != id or try boolean(args, "refresh") or snapshot.object.id != id) session.redot.inspect(id) catch |err| switch (err) {
        // The answer's state and diagnostic say why nothing was asked.
        error.RedotDebuggerPending, error.RedotDebuggerClosed, error.RedotDebuggerProtocolError => {},
        else => return err,
    };
    const current = session.redot.snapshot();
    const object: ?Object = if (current.object.id == id) .{
        .id = try std.fmt.allocPrint(a, "{d}", .{current.object.id}),
        .class_name = current.object.class_name,
        .script_path = current.object.script_path,
        .properties = current.object.properties,
        .signals = current.object.signals,
    } else null;
    return asValue(a, .{ .source = "engine_debugger_protocol", .state = current.state, .diagnostic = current.diagnostic, .revision = current.object_revision, .pending = current.object_pending, .requested_id = try std.fmt.allocPrint(a, "{d}", .{id}), .object = object, .signal_scope = "Signal-valued properties only; this protocol version does not enumerate declared connections" });
}
