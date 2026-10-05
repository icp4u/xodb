//! JSON consumers often use doubles. Encode addresses/register words as hex.
const std = @import("std");
const V = std.json.Value;
fn word(a: std.mem.Allocator, value: *V) !void {
    const n: u64 = switch (value.*) {
        .integer => |n| if (n >= 0) @intCast(n) else return error.InvalidEvidenceWord,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        .null, .string => return,
        else => return error.InvalidEvidenceWord,
    };
    value.* = .{ .string = try std.fmt.allocPrint(a, "0x{x}", .{n}) };
}
pub fn inspection(a: std.mem.Allocator, value: *V) !void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| try inspection(a, item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                var scalar = false;
                for ([_][]const u8{ "pc", "lookup_pc", "cfa", "address", "data_address", "bits" }) |name| if (std.mem.eql(u8, key, name)) {
                    scalar = true;
                    break;
                };
                if (scalar) {
                    try word(a, entry.value_ptr);
                    continue;
                }
                if (std.mem.eql(u8, key, "registers") and entry.value_ptr.* == .array) {
                    for (entry.value_ptr.array.items) |*item| try word(a, item);
                } else try inspection(a, entry.value_ptr);
            }
        },
        else => {},
    }
}
pub fn observation(a: std.mem.Allocator, value: *V) !void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| try observation(a, item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const key = entry.key_ptr.*;
                var scalar = false;
                for ([_][]const u8{ "stack_key", "ip", "ax", "cx", "dx", "si", "di", "sp", "r8", "r9", "mask", "result", "value", "file_offset", "link_address", "runtime_address" }) |name| if (std.mem.eql(u8, key, name)) {
                    scalar = true;
                    break;
                };
                if (scalar and (entry.value_ptr.* == .integer or entry.value_ptr.* == .number_string)) {
                    try word(a, entry.value_ptr);
                    continue;
                }
                if (std.mem.eql(u8, key, "stack_word")) {
                    var bytes: [8]u8 = undefined;
                    switch (entry.value_ptr.*) {
                        .string => |text| {
                            if (text.len == 16) continue; // Already projected.
                            if (text.len != 8) return error.InvalidEvidenceWord;
                            @memcpy(&bytes, text);
                        },
                        .array => |list| {
                            if (list.items.len != 8) return error.InvalidEvidenceWord;
                            for (list.items, &bytes) |item, *byte| {
                                if (item != .integer or item.integer < 0 or item.integer > 255) return error.InvalidEvidenceWord;
                                byte.* = @intCast(item.integer);
                            }
                        },
                        else => return error.InvalidEvidenceWord,
                    }
                    const hex = std.fmt.bytesToHex(bytes, .lower);
                    const text = try a.dupe(u8, &hex);
                    entry.value_ptr.* = .{ .string = text };
                    continue;
                }
                if ((std.mem.eql(u8, key, "args") or std.mem.eql(u8, key, "pcs")) and entry.value_ptr.* == .array) {
                    for (entry.value_ptr.array.items) |*item| try word(a, item);
                } else if (std.mem.eql(u8, key, "total_ns")) {
                    const text = switch (entry.value_ptr.*) {
                        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
                        .number_string => |s| s,
                        else => return error.InvalidEvidenceWord,
                    };
                    entry.value_ptr.* = .{ .string = text };
                } else try observation(a, entry.value_ptr);
            }
        },
        else => {},
    }
}
test "raw words and duration totals stay exact through JSON projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = (try std.json.parseFromSlice(V, a, "{\"result\":{\"total_ns\":184467440737095516160,\"value\":18446744073709551615},\"fast\":{\"total_ns\":12},\"args\":[0,18446744073709551615]}", .{})).value;
    try observation(a, &value);
    try std.testing.expectEqualStrings("184467440737095516160", value.object.get("result").?.object.get("total_ns").?.string);
    try std.testing.expectEqualStrings("12", value.object.get("fast").?.object.get("total_ns").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", value.object.get("result").?.object.get("value").?.string);
}
