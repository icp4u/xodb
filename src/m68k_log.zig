const std = @import("std");
extern "c" fn write(c_int, [*]const u8, usize) isize;
extern "c" fn _exit(c_int) noreturn;
var buf: [16384]u8 = undefined;
pub noinline fn print(comptime format: []const u8, args: anytype) void {
    const bytes = std.fmt.bufPrint(&buf, format, args) catch "xodb: log formatting failed\n";
    var at: usize = 0;
    while (at < bytes.len) { const n = write(2, bytes.ptr + at, bytes.len - at); if (n <= 0) break; at += @intCast(n); }
}
pub fn panicMessage(message: []const u8, _: ?usize) noreturn {
    print("xodb panic: {s}\n", .{message});
    _exit(134);
}
