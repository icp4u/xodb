const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Tab = @import("../model/language_tabs.zig").Tab;
const selection = @import("../model/language_selection.zig");
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_language_tabs") or std.mem.eql(u8, name, "select_language_tab") or
        std.mem.eql(u8, name, "select_native_frame") or std.mem.eql(u8, name, "select_language_frame");
}
fn number(args: std.json.Value, key: []const u8, maximum: u64) !u64 {
    const value = args.object.get(key) orelse return error.InvalidArguments;
    if (value != .integer or value.integer < 0 or value.integer > maximum) return error.InvalidArguments;
    return @intCast(value.integer);
}
fn tab(args: std.json.Value, key: []const u8) !Tab {
    const value = args.object.get(key) orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    return std.meta.stringToEnum(Tab, value.string) orelse error.InvalidArguments;
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: std.json.Value) !std.json.Value {
    if (args != .object) return error.InvalidArguments;
    const selecting_tab = std.mem.eql(u8, name, "select_language_tab");
    const selecting_native = std.mem.eql(u8, name, "select_native_frame");
    const selecting_logical = std.mem.eql(u8, name, "select_language_frame");
    var fields = args.object.iterator();
    while (fields.next()) |field| {
        const key = field.key_ptr.*;
        const allowed = std.mem.eql(u8, key, "generation") or
            (selecting_tab and std.mem.eql(u8, key, "tab")) or
            ((selecting_native or selecting_logical) and (std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame"))) or
            (selecting_logical and (std.mem.eql(u8, key, "language") or std.mem.eql(u8, key, "segment")));
        if (!allowed) return error.InvalidArguments;
    }
    if (args.object.get("generation") != null) try session.target.expectGeneration(try number(args, "generation", std.math.maxInt(u64)));
    session.language_tabs.syncSelection(session.target.snapshot().generation);
    if (selecting_tab or selecting_native or selecting_logical) {
        if (!session.agent_controller) return error.AgentScopeDenied;
        if (args.object.get("generation") == null) return error.GenerationRequired;
        if (selecting_tab) {
            try session.language_tabs.select(try tab(args, "tab"));
        } else {
            const tid = try number(args, "tid", std.math.maxInt(i32));
            if (tid == 0) return error.InvalidArguments;
            const frame = try number(args, "frame", 63);
            if (selecting_native) try selection.selectNative(session, @intCast(tid), @intCast(frame)) else try selection.selectLogical(session, @intCast(tid), try tab(args, "language"), @intCast(try number(args, "segment", 63)), @intCast(frame));
        }
    }
    session.language_tabs.enabled = true;
    const text = try std.json.Stringify.valueAlloc(a, .{ .process_id = session.process_id, .session_id = session.id, .generation = session.target.snapshot().generation, .view = session.language_tabs }, .{});
    return (try std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_always })).value;
}
