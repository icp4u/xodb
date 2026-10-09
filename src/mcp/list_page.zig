//! Shared MCP row budget and deterministic retained-view identities.
const std = @import("std");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const Budget = struct {
    used: usize = 0,
    pub const maximum = 192 * 1024;
    /// Project before measuring; the final reply boundary is idempotent. Count
    /// both the structured row and its escaped occurrence in content[].text.
    pub fn include(self: *Budget, a: A, row: *V) !bool {
        try @import("exact.zig").addresses(a, row);
        const bytes = try std.json.Stringify.valueAlloc(a, row.*, .{});
        defer a.free(bytes);
        var quoted: usize = 2;
        for (bytes) |b| quoted +|= if (b == '"' or b == '\\') @as(usize, 2) else if (b < 32) @as(usize, 6) else 1;
        const needed = bytes.len +| quoted +| 4; // commas in both row arrays
        if (needed > maximum - self.used) return false;
        self.used += needed;
        return true;
    }
};
pub const Identity = struct {
    hash: std.crypto.hash.sha2.Sha256,
    pub fn init(domain: []const u8) Identity {
        var self = Identity{ .hash = .init(.{}) };
        self.text(domain);
        return self;
    }
    pub fn number(self: *Identity, n: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, n, .little);
        self.hash.update(&bytes);
    }
    pub fn optional(self: *Identity, n: ?u64) void {
        self.number(@intFromBool(n != null));
        if (n) |v| self.number(v);
    }
    pub fn text(self: *Identity, value: []const u8) void {
        self.number(value.len);
        self.hash.update(value);
    }
    pub fn finish(self: *Identity) [64]u8 {
        var digest: [32]u8 = undefined;
        self.hash.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }
};

test "list byte budget covers exact words escaping and both reply forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try a.alloc(u8, 4096);
    @memset(name, 1);
    var rows = V{ .array = std.array_list.Managed(V).init(a) };
    var budget: Budget = .{};
    for (0..128) |_| {
        var row = try @import("profile.zig").value(a, .{ .name = name, .address = @as(u64, 0x20000000000001) });
        if (!try budget.include(a, &row)) break;
        try rows.array.append(row);
    }
    try std.testing.expect(rows.array.items.len > 0 and rows.array.items.len < 128);
    const data = try @import("profile.zig").value(a, .{ .rows = rows });
    const text = try std.json.Stringify.valueAlloc(a, data, .{});
    const envelope = try std.json.Stringify.valueAlloc(a, .{ .result = .{ .structuredContent = data, .content = .{.{ .type = "text", .text = text }} } }, .{});
    try std.testing.expect(envelope.len < Budget.maximum + 1024);
    const huge = try a.alloc(u8, Budget.maximum);
    @memset(huge, 'x');
    var row = try @import("profile.zig").value(a, .{ .name = huge });
    var empty: Budget = .{};
    try std.testing.expect(!try empty.include(a, &row));
}
