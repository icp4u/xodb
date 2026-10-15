//! Catalog validation shared by the build and the runtime policy reader.
const std = @import("std");
const Value = std.json.Value;
pub const Access = enum { observer, requester, controller, mutator, lease };
/// Target read-only hints do not describe ownership of retained host jobs.
/// Missing or invalid classifications fail closed instead of inferring from names.
pub fn access(definition: Value) !Access {
    if (definition != .object) return error.MissingToolSessionAccess;
    const annotations = definition.object.get("annotations") orelse return error.MissingToolSessionAccess;
    if (annotations != .object) return error.InvalidToolSessionAccess;
    const value = annotations.object.get("xodbSessionAccess") orelse return error.MissingToolSessionAccess;
    if (value != .string) return error.InvalidToolSessionAccess;
    const required = std.meta.stringToEnum(Access, value.string) orelse return error.InvalidToolSessionAccess;
    if (!try readOnly(definition) and required == .observer) return error.InvalidToolSessionAccess;
    if (required == .requester) {
        const name = definition.object.get("name") orelse return error.InvalidToolSessionAccess;
        if (name != .string or (!std.mem.eql(u8, name.string, "request_system_capture") and !std.mem.eql(u8, name.string, "cancel_system_capture"))) return error.InvalidToolSessionAccess;
    }
    return required;
}
pub fn readOnly(definition: Value) !bool {
    if (definition != .object) return error.InvalidToolSessionAccess;
    const annotations = definition.object.get("annotations") orelse return error.InvalidToolSessionAccess;
    if (annotations != .object) return error.InvalidToolSessionAccess;
    const value = annotations.object.get("readOnlyHint") orelse return error.InvalidToolSessionAccess;
    if (value != .bool) return error.InvalidToolSessionAccess;
    return value.bool;
}

pub const Group = enum { native, imported, session };
pub const Catalog = struct { name: []const u8, text: []const u8, group: Group };
pub const Failure = struct { catalog: []const u8, reason: anyerror };
pub const inputs = [_]Catalog{
    .{ .name = "src/mcp/base_tools.json", .text = @embedFile("base_tools.json"), .group = .native },
    .{ .name = "src/mcp/static_tools.json", .text = @embedFile("static_tools.json"), .group = .native },
    .{ .name = "src/mcp/runtime_type_tools.json", .text = @embedFile("runtime_type_tools.json"), .group = .native },
    .{ .name = "src/mcp/macho_tools.json", .text = @embedFile("macho_tools.json"), .group = .native },
    .{ .name = "src/mcp/overview_tools.json", .text = @embedFile("overview_tools.json"), .group = .native },
    .{ .name = "src/mcp/fd_tools.json", .text = @embedFile("fd_tools.json"), .group = .native },
    .{ .name = "src/mcp/memstat_tools.json", .text = @embedFile("memstat_tools.json"), .group = .native },
    .{ .name = "src/mcp/redot_tools.json", .text = @embedFile("redot_tools.json"), .group = .native },
    .{ .name = "src/mcp/evidence_tools.json", .text = @embedFile("evidence_tools.json"), .group = .native },
    .{ .name = "src/mcp/imported_tools.json", .text = @embedFile("imported_tools.json"), .group = .imported },
    .{ .name = "src/mcp/session_tools.json", .text = @embedFile("session_tools.json"), .group = .session },
};

/// Distinct publication groups can share a tool name. All fragments of one
/// group share a name table, matching the catalogs the server concatenates.
pub fn validate(a: std.mem.Allocator, catalogs: []const Catalog, failure: *?Failure) !void {
    failure.* = null;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var names: [3]std.StringHashMapUnmanaged(void) = @splat(.empty);
    for (catalogs) |catalog| {
        errdefer |err| failure.* = .{ .catalog = catalog.name, .reason = err };
        const parsed = try std.json.parseFromSliceLeaky(Value, scratch, catalog.text, .{});
        if (parsed != .array) return error.InvalidToolCatalog;
        for (parsed.array.items) |definition| {
            if (definition != .object) return error.InvalidToolDefinition;
            const name = definition.object.get("name") orelse return error.MissingToolName;
            if (name != .string or name.string.len == 0) return error.InvalidToolName;
            const required = try access(definition);
            if (catalog.group != .session and required == .lease) return error.InvalidToolSessionAccess;
            const saved = try names[@intFromEnum(catalog.group)].getOrPut(scratch, name.string);
            if (saved.found_existing) return error.DuplicateToolName;
        }
    }
}

/// Keep the same array assembly in the build check and every published list.
/// Empty fragments contribute no comma; all JSON whitespace is permitted.
/// Validation handles malformed envelopes before the application is compiled.
pub fn join(comptime fragments: []const Catalog) []const u8 {
    return comptime assembled: {
        var result: []const u8 = "[";
        for (fragments) |fragment| {
            const text = std.mem.trim(u8, fragment.text, " \r\n\t");
            const body = if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']')
                std.mem.trim(u8, text[1 .. text.len - 1], " \r\n\t")
            else
                text;
            if (body.len == 0) continue;
            result = result ++ (if (result.len > 1) "," else "") ++ body;
        }
        break :assembled result ++ "]";
    };
}

pub const native_definitions = join(inputs[0..9]);
pub const overview_definitions = join(inputs[4..7]);

pub fn validateInputs(a: std.mem.Allocator, failure: *?Failure) !void {
    try validate(a, &inputs, failure);
    try validate(a, &.{.{ .name = "assembled native", .text = native_definitions, .group = .native }}, failure);
    try validate(a, &.{.{ .name = "assembled overview", .text = overview_definitions, .group = .native }}, failure);
}

test "catalog assembly handles JSON whitespace and empty fragments" {
    const t = std.testing;
    const sample = "{\"name\":\"sample\",\"annotations\":{\"xodbSessionAccess\":\"observer\",\"readOnlyHint\":true}}";
    const joined = join(&.{
        .{ .name = "empty first", .text = " \r\n[ \t]\r\n", .group = .native },
        .{ .name = "sample", .text = "\n[\n" ++ sample ++ "\n]\t", .group = .native },
        .{ .name = "empty last", .text = "[]", .group = .native },
    });
    try t.expectEqualStrings("[" ++ sample ++ "]", joined);
    var failure: ?Failure = null;
    try validate(t.allocator, &.{.{ .name = "joined", .text = joined, .group = .native }}, &failure);
    try t.expectEqualStrings("[]", join(&.{}));
    try t.expectEqualStrings("[]", join(&.{.{ .name = "empty", .text = "[]", .group = .native }}));
    try validateInputs(t.allocator, &failure);
}
