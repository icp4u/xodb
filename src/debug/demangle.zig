//! Presentation only. Raw linkage names remain the lookup/identity key.
const std = @import("std");
extern fn xodb_demangle_name(name: [*]const u8, length: usize, out: [*]u8, capacity: usize) c_int;

fn number(name: []const u8, at: *usize) ?usize {
    if (at.* == name.len or !std.ascii.isDigit(name[at.*])) return null;
    var n: usize = 0;
    while (at.* < name.len and std.ascii.isDigit(name[at.*])) : (at.* += 1) {
        n = std.math.mul(usize, n, 10) catch return null;
        n = std.math.add(usize, n, name[at.*] - '0') catch return null;
    }
    if (n == 0 or n > name.len - at.*) return null;
    return n;
}

fn swiftName(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (name.len < 3 or !(std.mem.startsWith(u8, name, "$s") or std.mem.startsWith(u8, name, "$S"))) return null;
    var at: usize = 2;
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    while (count < parts.len) {
        const length = number(name, &at) orelse {
            if (count == 2 and at < name.len and std.mem.indexOfScalar(u8, "CVOP", name[at]) != null) {
                at += 1;
                continue;
            }
            break;
        };
        // `private` and `fileprivate` names carry a file discriminator
        // (identifier, then "LL"); it is not part of the readable name.
        if (count > 0 and std.mem.startsWith(u8, name[at + length ..], "LL")) {
            at += length + 2;
            continue;
        }
        parts[count] = name[at .. at + length];
        at += length;
        count += 1;
    }
    if (count < 2) return null;
    const joined = try std.mem.join(a, ".", parts[0..count]);
    return @as(?[]const u8, joined);
}

fn linkageDisplay(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (try swiftName(a, name)) |swift_name| return swift_name;
    if (!std.mem.startsWith(u8, name, "_Z")) return name;
    var out: [1024]u8 = undefined;
    if (xodb_demangle_name(name.ptr, name.len, &out, out.len) == 0) return name;
    const end = std.mem.indexOfScalar(u8, &out, 0) orelse return name;
    return a.dupe(u8, out[0..end]);
}

pub fn display(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len > 4096) return name;
    const bang = std.mem.indexOfScalar(u8, name, '!');
    const first = if (bang) |i| i + 1 else 0;
    const offset = std.mem.indexOfPos(u8, name, first, "+0x") orelse name.len;
    const linkage = name[first..offset];
    const shown = try linkageDisplay(a, linkage);
    if (shown.ptr == linkage.ptr and shown.len == linkage.len) return name;
    defer a.free(shown);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ name[0..first], shown, name[offset..] });
}

test "compact Swift linkage name" {
    const shown = try display(std.testing.allocator, "swiftprog!$s9swiftprog8bpTargetyySiF+0x4");
    defer std.testing.allocator.free(shown);
    try std.testing.expectEqualStrings("swiftprog!swiftprog.bpTarget+0x4", shown);
    const private = try display(std.testing.allocator, "$s4main3foo33_0123456789ABCDEF0123456789ABCDEFLLyyF");
    defer std.testing.allocator.free(private);
    try std.testing.expectEqualStrings("main.foo", private);
    const method = try display(std.testing.allocator, "$s4main3FooV3baryyF");
    defer std.testing.allocator.free(method);
    try std.testing.expectEqualStrings("main.Foo.bar", method);
}
