//! Explicit prefix substitutions. Longest whole-directory match wins.
const std = @import("std");
const A = std.heap.page_allocator;
pub const Rule = struct { from: []const u8, to: []const u8 };
pub const Maps = struct {
    rules: std.ArrayList(Rule) = .empty,
    pub fn deinit(self: *Maps) void {
        for (self.rules.items) |rule| {
            A.free(rule.from);
            A.free(rule.to);
        }
        self.rules.deinit(A);
    }
    pub fn add(self: *Maps, spec: []const u8) !void {
        if (self.rules.items.len >= 32) return error.SourceMapLimit;
        const split = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidSourceMap;
        const from = std.mem.trimEnd(u8, spec[0..split], "/");
        const to = std.mem.trimEnd(u8, spec[split + 1 ..], "/");
        if (from.len == 0 or to.len == 0 or from.len > 4096 or to.len > 4096 or from[0] != '/' or to[0] != '/' or std.mem.indexOfScalar(u8, spec, 0) != null) return error.InvalidSourceMap;
        for (self.rules.items) |rule| if (std.mem.eql(u8, rule.from, from)) return error.DuplicateSourceMap;
        const f = try A.dupe(u8, from);
        errdefer A.free(f);
        const t = try A.dupe(u8, to);
        errdefer A.free(t);
        try self.rules.append(A, .{ .from = f, .to = t });
    }
    fn matches(path: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, path, prefix) and (path.len == prefix.len or path[prefix.len] == '/');
    }
    pub fn forward(self: *const Maps, a: std.mem.Allocator, path: []const u8) ![]const u8 {
        var chosen: ?Rule = null;
        for (self.rules.items) |rule| if (matches(path, rule.from) and (chosen == null or rule.from.len > chosen.?.from.len)) {
            chosen = rule;
        };
        return if (chosen) |rule| std.mem.concat(a, u8, &.{ rule.to, path[rule.from.len..] }) else path;
    }
    /// Several build roots may map to one local tree. Test each candidate against
    /// DWARF, rather than selecting an arbitrary reverse substitution.
    pub fn originals(self: *const Maps, a: std.mem.Allocator, path: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        try result.append(a, path);
        for (self.rules.items) |rule| if (matches(path, rule.to)) {
            const candidate = try std.mem.concat(a, u8, &.{ rule.from, path[rule.to.len..] });
            if (std.mem.eql(u8, try self.forward(a, candidate), path)) try result.append(a, candidate);
        };
        return result.toOwnedSlice(a);
    }
};
test "source maps respect directory boundaries, longest prefixes and reverse ambiguity" {
    var maps = Maps{};
    defer maps.deinit();
    try maps.add("/build=/local");
    try maps.add("/build/vendor=/vendor");
    try maps.add("/other=/local");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/local/a.c", try maps.forward(a, "/build/a.c"));
    try std.testing.expectEqualStrings("/vendor/a.c", try maps.forward(a, "/build/vendor/a.c"));
    try std.testing.expectEqualStrings("/builder/a.c", try maps.forward(a, "/builder/a.c"));
    const originals = try maps.originals(a, "/local/a.c");
    try std.testing.expectEqual(@as(usize, 3), originals.len);
    try std.testing.expectError(error.InvalidSourceMap, maps.add("relative=/local"));
    try std.testing.expectError(error.DuplicateSourceMap, maps.add("/build=/replacement"));
}
