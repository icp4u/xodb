const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Tab = @import("../model/language_tabs.zig").Tab;
fn number(args: std.json.Value, key: []const u8, maximum: u64) !u64 {
    const value = args.object.get(key) orelse return error.InvalidArguments;
    if (value != .integer or value.integer < 0 or value.integer > maximum) return error.InvalidArguments;
    return @intCast(value.integer);
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: std.json.Value) !std.json.Value {
    const expression = std.mem.eql(u8, name, "evaluate_language_expression");
    if (args != .object) return error.InvalidArguments;
    var fields = args.object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const allowed = for ([_][]const u8{ "generation", "language", "tid", "segment", "frame", "start", "limit", "expression" }) |property| {
            if (std.mem.eql(u8, key, property)) break true;
        } else false;
        if (!allowed or (expression and (std.mem.eql(u8, key, "start") or std.mem.eql(u8, key, "limit"))) or
            (!expression and std.mem.eql(u8, key, "expression"))) return error.InvalidArguments;
    }
    if (args.object.get("generation") == null) return error.GenerationRequired;
    try session.target.expectGeneration(try number(args, "generation", std.math.maxInt(u64)));
    const lang = args.object.get("language") orelse return error.InvalidArguments;
    if (lang != .string) return error.InvalidArguments;
    const language = std.meta.stringToEnum(Tab, lang.string) orelse return error.InvalidArguments;
    const tid = try number(args, "tid", std.math.maxInt(i32));
    if (tid == 0) return error.InvalidArguments;
    const named = @import("../model/language_locals.zig");
    const segment: usize = @intCast(try number(args, "segment", 63));
    const frame: usize = @intCast(try number(args, "frame", 63));
    const result = if (expression) result: {
        const text_arg = args.object.get("expression") orelse return error.InvalidArguments;
        if (text_arg != .string) return error.InvalidArguments;
        break :result try named.evaluate(session, a, language, @intCast(tid), segment, frame, text_arg.string);
    } else try named.read(session, a, language, @intCast(tid), segment, frame, if (args.object.get("start") != null) @intCast(try number(args, "start", 4096)) else 0, if (args.object.get("limit") != null) @intCast(try number(args, "limit", 32)) else 32);
    const text = try std.json.Stringify.valueAlloc(a, result, .{});
    return (try std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_always })).value;
}
