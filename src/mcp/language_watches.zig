const std = @import("std");
const Session = @import("../model/session.zig").Session;
const wire = @import("profile.zig");
const Tab = @import("../model/language_tabs.zig").Tab;
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_language_watches") or std.mem.eql(u8, name, "add_language_watch") or std.mem.eql(u8, name, "remove_language_watch");
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: std.json.Value) !std.json.Value {
    const get = std.mem.eql(u8, name, "get_language_watches");
    const add = std.mem.eql(u8, name, "add_language_watch");
    if (!get and !session.agent_controller) return error.AgentScopeDenied;
    if (get) try wire.fields(args, &.{"generation"}) else if (add) try wire.fields(args, &.{ "generation", "language", "tid", "segment", "frame", "expression", "row" }) else try wire.fields(args, &.{ "generation", "id" });
    if (!get or args.object.get("generation") != null) try session.target.expectGeneration(try wire.number(args, "generation", null));
    var added: ?u64 = null;
    if (add) {
        const language = args.object.get("language") orelse return error.InvalidArguments;
        if (language != .string) return error.InvalidArguments;
        const tab: Tab = if (std.mem.eql(u8, language.string, "lua")) .lua else if (std.mem.eql(u8, language.string, "python")) .python else if (std.mem.eql(u8, language.string, "perl")) .perl else if (std.mem.eql(u8, language.string, "ruby")) .ruby else if (std.mem.eql(u8, language.string, "javascript")) .javascript else return error.LanguageWatchRuntimeUnsupported;
        const tid = try wire.number(args, "tid", null);
        const segment = try wire.number(args, "segment", null);
        const frame = try wire.number(args, "frame", null);
        if (tid == 0 or tid > std.math.maxInt(i32) or segment >= 64 or frame >= 64) return error.InvalidArguments;
        const text: ?[]const u8 = if (args.object.get("expression")) |arg| (if (arg == .string) arg.string else return error.InvalidArguments) else null;
        const row: ?usize = if (args.object.get("row") != null) @intCast(try wire.number(args, "row", null)) else null;
        added = try session.language_watches.add(session, tab, @intCast(tid), @intCast(segment), @intCast(frame), text, row);
    } else if (!get) try session.language_watches.remove(try wire.number(args, "id", null));
    const text = try std.json.Stringify.valueAlloc(a, .{ .generation = session.target.snapshot().generation, .revision = session.language_watches.revision, .added = added, .watches = try session.language_watches.list(a) }, .{});
    return (try std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_always })).value;
}
