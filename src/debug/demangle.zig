//! Presentation only. Raw linkage names remain the lookup/identity key.
const std = @import("std");
extern fn xodb_demangle_name(name: [*]const u8, length: usize, out: [*]u8, capacity: usize) c_int;

pub fn display(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len > 4096 or !std.mem.startsWith(u8, name, "_Z")) return name;
    var out: [1024]u8 = undefined;
    if (xodb_demangle_name(name.ptr, name.len, &out, out.len) == 0) return name;
    const end = std.mem.indexOfScalar(u8, &out, 0) orelse return name;
    return a.dupe(u8, out[0..end]);
}
