//! Identity supplied by a sampled process row. Never use the PID alone.
const std = @import("std");
const c = @import("../c.zig").api;
pub const Identity = struct { pid: i32, start: u64 };

pub fn parse(stat: []const u8) !u64 {
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(u8, stat[end + 1 ..], ' ');
    for (0..19) |_| _ = fields.next() orelse return error.ProcessIdentityUnavailable;
    const value = fields.next() orelse return error.ProcessIdentityUnavailable;
    return std.fmt.parseInt(u64, std.mem.trim(u8, value, "\n"), 10) catch error.ProcessIdentityUnavailable;
}

pub fn validate(id: Identity) !void {
    if (id.pid <= 1 or id.start == 0) return error.InvalidProcessIdentity;
    var path: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{id.pid});
    const fd = c.open(name.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ProcessIdentityUnavailable;
    defer _ = c.close(fd);
    var bytes: [4096]u8 = undefined;
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0 or n == bytes.len) return error.ProcessIdentityUnavailable;
    if (try parse(bytes[0..@intCast(n)]) != id.start) return error.ProcessIdentityChanged;
}

test "process identity handles spaces and closing parentheses in comm" {
    try std.testing.expectEqual(12345, try parse("12 (some ) command) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345 20\n"));
    try std.testing.expectError(error.ProcessIdentityUnavailable, parse("12 (gone) S 1"));
}
