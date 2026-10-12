//! Image names come from a target or a local filename. The image/symbol
//! separator belongs to the formatter and cannot be supplied by that name.
const std = @import("std");
pub fn format(a: std.mem.Allocator, path: []const u8, symbol: ?[]const u8, offset: ?u64) ![]u8 {
    const image = try a.dupe(u8, std.fs.path.basename(path));
    defer a.free(image);
    const utf8 = std.unicode.utf8ValidateSlice(image);
    for (image) |*byte| if (byte.* == '!' or byte.* < 32 or byte.* == 127 or (!utf8 and byte.* >= 128)) {
        byte.* = '?';
    };
    if (symbol) |name| {
        return if (offset) |value| std.fmt.allocPrint(a, "{s}!{s}+0x{x}", .{ image, name, value }) else std.fmt.allocPrint(a, "{s}!{s}", .{ image, name });
    }
    return if (offset) |value| std.fmt.allocPrint(a, "{s}+0x{x}", .{ image, value }) else a.dupe(u8, image);
}
test "image labels reserve the separator while preserving C++ library names" {
    const a = std.testing.allocator;
    const forged = try format(a, "/owned/lib.so!fake", null, 16);
    defer a.free(forged);
    try std.testing.expectEqualStrings("lib.so?fake+0x10", forged);
    const real = try format(a, "/owned/libc++.so", "function", 2);
    defer a.free(real);
    try std.testing.expectEqualStrings("libc++.so!function+0x2", real);
    const pe = try format(a, "/owned/a!b.dll", "function", null);
    defer a.free(pe);
    try std.testing.expectEqualStrings("a?b.dll!function", pe);
}
