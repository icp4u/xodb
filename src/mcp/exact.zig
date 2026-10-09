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

// Compatibility fields remain untouched. Only integer tokens are projected:
// converting through f64 here would already have lost the low bits.
fn integerHex(a: std.mem.Allocator, value: V) !?V {
    const n: i128 = switch (value) {
        .integer => |n| n,
        .number_string => |s| std.fmt.parseInt(i128, s, 10) catch return error.InvalidEvidenceWord,
        .null => return .null,
        else => return null,
    };
    if (n < std.math.minInt(i64) or n > std.math.maxInt(u64)) return error.InvalidEvidenceWord;
    return .{ .string = if (n < 0) try std.fmt.allocPrint(a, "-0x{x}", .{-n}) else try std.fmt.allocPrint(a, "0x{x}", .{n}) };
}
// Unclassified IDs, counts and clocks may also exceed a JSON Number's range.
// Keep ordinary small counters compact; never lose a newly introduced wide word.
fn wideWord(value: V) !bool {
    if (value == .array) {
        for (value.array.items) |item| if (try wideWord(item)) return true;
        return false;
    }
    const n: i128 = switch (value) {
        .integer => |n| n,
        .number_string => |text| std.fmt.parseInt(i128, text, 10) catch return error.InvalidEvidenceWord,
        else => return false,
    };
    return n >= (1 << 53) or n <= -(1 << 53);
}
fn addressField(key: []const u8) bool {
    for ([_][]const u8{ "address", "pointer", "offset", "pc", "sp", "fp", "ip", "bias" }) |suffix| {
        if (std.mem.eql(u8, key, suffix)) return true;
        if (key.len > suffix.len and std.mem.endsWith(u8, key, suffix) and key[key.len - suffix.len - 1] == '_') return true;
    }
    return for ([_][]const u8{
        "start",            "end",            "base",       "entry",           "link_entry",     "local_entry",  "target",    "cfa",
        "bits",             "tagged",         "object",     "body",            "map",            "type_object",  "stackinfo", "root_register",
        "runtime_location", "frame_location", "prototype",  "unpatched_probe", "offset_advance", "before",       "after",     "previous",
        "pcs",              "registers",      "running_to", "main_phdr",       "interpreter",    "displacement", "immediate", "bci",
        "realtime_ns",      "raw_marker",     "result",     "return_value",    "argument_value", "args",         "arg0",      "arg1",
    }) |name| {
        if (std.mem.eql(u8, key, name)) break true;
    } else false;
}
fn projected(a: std.mem.Allocator, value: V) !?V {
    if (value != .array) return integerHex(a, value);
    // Saved register banks and address arrays retain positional nulls. Object
    // rows (get_debug_view registers) instead receive their own value_hex.
    for (value.array.items) |item| switch (item) {
        .integer, .number_string, .null => {},
        else => return null,
    };
    var out: std.array_list.Managed(V) = .init(a);
    for (value.array.items) |item| try out.append((try integerHex(a, item)).?);
    return .{ .array = out };
}
fn hexEqual(left: V, right: V) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .string => |s| std.mem.eql(u8, s, right.string),
        .array => |items| blk: {
            if (items.items.len != right.array.items.len) break :blk false;
            for (items.items, right.array.items) |x, y| if (!hexEqual(x, y)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}
/// One projection for every successful MCP tool result, including nested rows.
/// Existing hex strings remain strings; numeric fields gain *_hex siblings.
pub fn addresses(a: std.mem.Allocator, value: *V) !void {
    try addressRows(a, value, "");
}
fn addressRows(a: std.mem.Allocator, value: *V, parent: []const u8) anyerror!void {
    switch (value.*) {
        .array => |*array| for (array.items) |*item| try addressRows(a, item, parent),
        .object => |*object| {
            const original_count = object.count();
            const js_frame = object.contains("frame_pointer");
            // Index the original entries afresh after each insertion: put may
            // relocate this map. Never hold an iterator or value pointer then.
            for (0..original_count) |i| {
                const key = object.keys()[i];
                try addressRows(a, &object.values()[i], key);
                const register = std.mem.eql(u8, parent, "registers") and std.mem.eql(u8, key, "value");
                const js_pointer = js_frame and (std.mem.eql(u8, key, "function") or std.mem.eql(u8, key, "shared") or std.mem.eql(u8, key, "code") or std.mem.eql(u8, key, "context") or std.mem.eql(u8, key, "bytecode"));
                const wide = try wideWord(object.values()[i]);
                if (!addressField(key) and !register and !js_pointer and !wide) continue;
                // The coverage summary also has an integer count named
                // registers. Only register banks get a parallel array.
                if (std.mem.eql(u8, key, "registers") and object.values()[i] != .array and !wide) continue;
                const hex = (try projected(a, object.values()[i])) orelse continue;
                const sibling = try std.fmt.allocPrint(a, "{s}_hex", .{key});
                if (object.get(sibling)) |old| {
                    // Idempotent, but never silently retain contradictory data.
                    if (!hexEqual(old, hex)) return error.ConflictingEvidenceWord;
                } else try object.put(a, sibling, hex);
            }
        },
        else => {},
    }
}
test "additive addresses preserve integer tokens and exact signed magnitudes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a,
        \\{"address":9007199254740993,"offset":-9223372036854775808,"pc":18446744073709551615,"pointer":null,"data_address":"0xffffffffffffffff","rate":1.25,"generation":7,"rows":[{"registers":[0,null,18446744073709551615]},{"registers":[{"name":"rax","value":9007199254740993}]}]}
    , .{})).value;
    try addresses(a, &v);
    try std.testing.expectEqual(@as(i64, 9007199254740993), v.object.get("address").?.integer);
    try std.testing.expectEqualStrings("18446744073709551615", v.object.get("pc").?.number_string);
    try std.testing.expectEqualStrings("0x20000000000001", v.object.get("address_hex").?.string);
    try std.testing.expectEqualStrings("-0x8000000000000000", v.object.get("offset_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", v.object.get("pc_hex").?.string);
    try std.testing.expect(v.object.get("pointer_hex").? == .null);
    try std.testing.expect(!v.object.contains("data_address_hex"));
    try std.testing.expect(!v.object.contains("generation_hex"));
    try std.testing.expect(!v.object.contains("rate_hex"));
    const rows = v.object.get("rows").?.array.items;
    const bank = rows[0].object.get("registers_hex").?.array.items;
    try std.testing.expect(bank[1] == .null);
    try std.testing.expectEqualStrings("0xffffffffffffffff", bank[2].string);
    const reg = rows[1].object.get("registers").?.array.items[0];
    try std.testing.expectEqualStrings("0x20000000000001", reg.object.get("value_hex").?.string);
    const before = try std.json.Stringify.valueAlloc(a, v, .{});
    try addresses(a, &v);
    try std.testing.expectEqualStrings(before, try std.json.Stringify.valueAlloc(a, v, .{}));
    try v.object.put(a, "address_hex", .{ .string = "0x0" });
    try std.testing.expectError(error.ConflictingEvidenceWord, addresses(a, &v));
}

test "integer projection covers every u64 bit without a float intermediary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (0..64) |bit| {
        const n = (@as(u64, 1) << @intCast(bit)) | 1;
        const json = try std.fmt.allocPrint(a, "{{\"slot_address\":{d}}}", .{n});
        var v = (try std.json.parseFromSlice(V, a, json, .{})).value;
        try addresses(a, &v);
        const hex = v.object.get("slot_address_hex").?.string;
        try std.testing.expectEqual(n, try std.fmt.parseInt(u64, hex, 0));
        // Serialization must preserve the legacy integer token byte for byte.
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{n}), try std.json.Stringify.valueAlloc(a, v.object.get("slot_address").?, .{}));
    }
    try std.testing.expectError(error.InvalidEvidenceWord, integerHex(a, .{ .number_string = "18446744073709551616" }));
    try std.testing.expectError(error.InvalidEvidenceWord, integerHex(a, .{ .number_string = "-9223372036854775809" }));
    try std.testing.expect((try integerHex(a, .{ .float = 9007199254740992.0 })) == null);
}

test "runtime pointer names and storage locations retain exact siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a,
        \\{"frames":[{"frame_pointer":1,"function":2,"shared":3,"code":4,"context":5,"bytecode":6,"pc":7}],"scope":{"runtime_location":8,"frame_location":9,"prototype":10},"value":{"tagged":11,"map":12,"body":13,"type_object":14,"object":15,"data_address":16},"stackinfo":17,"trap_address":18,"root_register":19,"entry_frame_pointer":20}
    , .{})).value;
    try addresses(a, &v);
    const frame = v.object.get("frames").?.array.items[0].object;
    for ([_][]const u8{ "frame_pointer", "function", "shared", "code", "context", "bytecode", "pc" }, 1..) |field, expected| {
        const name = try std.fmt.allocPrint(a, "{s}_hex", .{field});
        try std.testing.expectEqual(expected, try std.fmt.parseInt(u64, frame.get(name).?.string, 0));
    }
    try std.testing.expectEqualStrings("0x8", v.object.get("scope").?.object.get("runtime_location_hex").?.string);
    try std.testing.expectEqualStrings("0xe", v.object.get("value").?.object.get("type_object_hex").?.string);
    try std.testing.expectEqualStrings("0x11", v.object.get("stackinfo_hex").?.string);
    try std.testing.expectEqualStrings("0x14", v.object.get("entry_frame_pointer_hex").?.string);
}

test "nonstandard address and displacement names retain exact words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a,
        \\{"running_to":9007199254740993,"sample":{"ip":18446744073709551615,"raw_marker":18446744073709551614},"syscall":{"result":9007199254740993},"loader_reads":{"main_phdr":18446744073709551615,"interpreter":9007199254740993},"memory":{"displacement":-9223372036854775808},"immediate":-1,"bci":-1,"previous":18446744073709551615}
    , .{})).value;
    try addresses(a, &v);
    try std.testing.expectEqualStrings("0x20000000000001", v.object.get("running_to_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", v.object.get("loader_reads").?.object.get("main_phdr_hex").?.string);
    try std.testing.expectEqualStrings("-0x8000000000000000", v.object.get("memory").?.object.get("displacement_hex").?.string);
    try std.testing.expectEqualStrings("-0x1", v.object.get("immediate_hex").?.string);
    try std.testing.expectEqualStrings("-0x1", v.object.get("bci_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", v.object.get("previous_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", v.object.get("sample").?.object.get("ip_hex").?.string);
    try std.testing.expectEqualStrings("0xfffffffffffffffe", v.object.get("sample").?.object.get("raw_marker_hex").?.string);
    try std.testing.expectEqualStrings("0x20000000000001", v.object.get("syscall").?.object.get("result_hex").?.string);
}

test "register coverage counts remain summable numeric objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a, "{\"totals\":{\"samples\":3,\"registers\":2}}", .{})).value;
    try addresses(a, &v);
    const totals = v.object.get("totals").?.object;
    try std.testing.expectEqual(@as(usize, 2), totals.count());
    try std.testing.expectEqual(@as(i64, 2), totals.get("registers").?.integer);
}

test "wall-clock nanoseconds have exact additive siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a, "{\"realtime_ns\":1800000000000000123}", .{})).value;
    try addresses(a, &v);
    try std.testing.expectEqual(@as(i64, 1800000000000000123), v.object.get("realtime_ns").?.integer);
    try std.testing.expectEqual(@as(u64, 1800000000000000123), try std.fmt.parseInt(u64, v.object.get("realtime_ns_hex").?.string, 0));
}

// Imported frame clocks can be epoch nanoseconds, not only monotonic clocks.
test "wide nanosecond fields keep exact epoch clocks and signed offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a,
        \\{"stack":{"start_ns":1791158400000000000,"end_ns":null,"time_ns":-9223372036854775808,"future_clock_ns":18446744073709551615},"rate_ns":1.5,"declared_ns":"1791158400000000000"}
    , .{})).value;
    try addresses(a, &v);
    const stack = v.object.get("stack").?.object;
    try std.testing.expectEqual(@as(u64, 1791158400000000000), try std.fmt.parseInt(u64, stack.get("start_ns_hex").?.string, 0));
    try std.testing.expect(!stack.contains("end_ns_hex"));
    try std.testing.expect(stack.get("end_ns").? == .null);
    try std.testing.expectEqualStrings("-0x8000000000000000", stack.get("time_ns_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", stack.get("future_clock_ns_hex").?.string);
    try std.testing.expect(!v.object.contains("rate_ns_hex"));
    try std.testing.expect(!v.object.contains("declared_ns_hex"));
}

test "unknown wide fields and sentinel IDs cannot bypass exact projection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var v = (try std.json.parseFromSlice(V, a,
        \\{"opening_generation":18446744073709551615,"new_field":9007199254740993,"negative":-9007199254740993,"new_bank":[0,null,18446744073709551615],"counts":{"registers":9007199254740993},"small":9007199254740991}
    , .{})).value;
    try addresses(a, &v);
    try std.testing.expectEqualStrings("0xffffffffffffffff", v.object.get("opening_generation_hex").?.string);
    try std.testing.expectEqualStrings("0x20000000000001", v.object.get("new_field_hex").?.string);
    try std.testing.expectEqualStrings("-0x20000000000001", v.object.get("negative_hex").?.string);
    const bank = v.object.get("new_bank_hex").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), bank.len);
    try std.testing.expect(bank[1] == .null);
    try std.testing.expectEqualStrings("0xffffffffffffffff", bank[2].string);
    try std.testing.expectEqualStrings("0x20000000000001", v.object.get("counts").?.object.get("registers_hex").?.string);
    try std.testing.expect(!v.object.contains("small_hex"));
}
