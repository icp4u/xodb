//! Bounded read-only aggregate views. Language/producer plus DWARF field
//! metadata recognize slices; no hard-coded field offsets or target calls.
const std = @import("std");
const eval = @import("evaluate.zig");
pub const max_children = 64;
pub const max_preview = 64;
pub const basis = "DWARF types and member offsets; Rust/Zig slice names or Go DW_AT_go_kind plus CU language/producer; stopped target memory; no inferior function calls";
/// reflect.Kind values cmd/link stores in DW_AT_go_kind.
pub const go_kind = struct {
    pub const chan = 18;
    pub const func = 19;
    pub const interface = 20;
    pub const map = 21;
    pub const slice = 23;
    pub const string = 24;
};
pub const Presentation = enum { scalar, fields, array, slice, bytes };
const Layout = struct { pointer: eval.Field, length: eval.Field, capacity: ?eval.Field = null };
fn layout(t: *const eval.Type) ?Layout {
    const go_sequence = t.language == .go and (t.go_kind == go_kind.string or t.go_kind == go_kind.slice);
    if (t.kind != .structure or t.fields.len != @as(usize, if (go_sequence and t.go_kind == go_kind.slice) 3 else 2)) return null;
    const named_slice = switch (t.language) {
        .rust => std.mem.eql(u8, t.name, "&str") or std.mem.eql(u8, t.name, "&mut str") or
            std.mem.startsWith(u8, t.name, "&[") or std.mem.startsWith(u8, t.name, "&mut ["),
        .zig => std.mem.startsWith(u8, t.name, "[]"),
        .go => go_sequence,
        .unknown => false,
    };
    if (!named_slice) return null;
    var pointer: ?eval.Field = null;
    var length: ?eval.Field = null;
    const pointer_name = switch (t.language) {
        .rust => "data_ptr",
        .go => if (t.go_kind == go_kind.string) "str" else "array",
        else => "ptr",
    };
    for (t.fields) |f| {
        if (std.mem.eql(u8, f.name, pointer_name)) pointer = f;
        if (std.mem.eql(u8, f.name, if (t.language == .rust) "length" else "len")) length = f;
        if (f.offset > t.size or f.type.size > t.size - f.offset) return null;
    }
    const p = pointer orelse return null;
    const n = length orelse return null;
    var capacity: ?eval.Field = null;
    if (t.language == .go and t.go_kind == go_kind.slice) {
        for (t.fields) |f| if (std.mem.eql(u8, f.name, "cap")) {
            capacity = f;
        };
        const k = capacity orelse return null;
        if (k.type.kind != .signed or k.type.size != 8) return null;
    }
    // Go's len is a signed int; a negative length is refused in sequence().
    const length_kind_ok = n.type.kind == .unsigned or (t.language == .go and n.type.kind == .signed and n.type.size == 8);
    if (p.type.kind != .pointer or p.type.size != 8 or p.type.child == null or !length_kind_ok or n.type.size == 0 or n.type.size > 8) return null;
    if (p.offset < n.offset + n.type.size and n.offset < p.offset + p.type.size) return null;
    return .{ .pointer = p, .length = n, .capacity = capacity };
}
fn field(v: eval.Value, f: eval.Field) !eval.Value {
    return eval.subvalue(v, f.type, f.offset);
}
pub const Sequence = struct { address: u64, count: u64, element: *const eval.Type, presentation: Presentation, capacity: ?u64 = null };
pub fn sequence(ctx: eval.Context, v: eval.Value) !?Sequence {
    if (v.availability != .available) return error.ValueUnavailable;
    if (v.type.kind == .array and v.address == null) return null;
    if (v.type.kind == .array) return .{ .address = v.address orelse return error.NotAddressable, .count = v.type.count, .element = v.type.child orelse return error.UnsupportedType, .presentation = .array };
    const l = layout(v.type) orelse return null;
    const p = try eval.materialize(ctx, try field(v, l.pointer));
    const n = try eval.materialize(ctx, try field(v, l.length));
    if (l.length.type.kind == .signed and n.bits >> 63 != 0) return error.InvalidLength;
    const child = p.type.child.?;
    const bytes = std.math.mul(u64, n.bits, child.size) catch return error.InvalidAddress;
    _ = std.math.add(u64, p.bits, bytes) catch return error.InvalidAddress;
    var capacity: ?u64 = null;
    if (l.capacity) |k| {
        const cap = try eval.materialize(ctx, try field(v, k));
        if (cap.bits >> 63 != 0 or cap.bits < n.bits) return error.InvalidLength;
        capacity = cap.bits;
    }
    return .{ .address = p.bits, .count = n.bits, .element = child, .presentation = if (child.kind == .unsigned and child.size == 1) .bytes else .slice, .capacity = capacity };
}
pub const Preview = struct {
    presentation: Presentation,
    data_address: u64,
    count: u64,
    element_type: []const u8,
    capacity: ?u64 = null,
    text: ?[]const u8 = null,
    hex: ?[]const u8 = null,
    preview_bytes: usize = 0,
    truncated: bool = false,
    /// An extent check raised an advisory; false does not certify an extent.
    extent_advisory: bool = false,
    diagnostic: ?[]const u8 = null,
    basis: []const u8 = basis,
    perl: ?PerlValue = null,
    python: ?PythonValue = null,
    javascript: ?JavaScriptValue = null,
    lua: ?LuaValue = null,
    ruby: ?RubyValue = null,
    elisp: ?ElispValue = null,
};
pub const ElispItem = struct { tagged: u64, key: []const u8, type: []const u8, display: []const u8, diagnostic: ?[]const u8 };
pub const ElispValue = struct {
    type: []const u8,
    display: []const u8,
    tagged: u64,
    object: u64,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    layout_source: []const u8 = "same-image DWARF",
    memory_reads: usize,
    memory_bytes: usize,
    liveness: []const u8 = "unproved; consistent headers do not prove GC liveness or allocation extents",
    items: []ElispItem,
};
pub const RubyValue = struct { value: @import("language_locals.zig").Value, tagged: u64, runtime_version: []const u8, runtime_build_id: []const u8, memory_reads: usize, memory_bytes: usize, liveness: []const u8 = "unproved; consistent tags do not prove GC liveness" };
pub const LuaItem = struct { address: u64, key: []const u8, type: []const u8, display: []const u8, diagnostic: ?[]const u8, advisory: bool = false };
pub const LuaValue = struct {
    advisory: bool = false,
    type: []const u8,
    display: []const u8,
    object: u64,
    array_capacity: u64,
    hash_capacity: u64,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    layout_source: []const u8 = "same-image DWARF",
    type_proof: []const u8,
    liveness: []const u8 = "unproved; header consistency is not GC liveness",
    memory_reads: usize,
    memory_bytes: usize,
    items: []LuaItem,
};
pub const JavaScriptItem = struct { tagged: u64, key: []const u8, type: []const u8, display: []const u8, diagnostic: ?[]const u8, truncated: bool = false, extent_advisory: bool = false, name_diagnostic: ?[]const u8 = null };
pub const JavaScriptValue = struct {
    name_diagnostic: ?[]const u8 = null,
    type: []const u8,
    display: []const u8,
    tagged: u64,
    map: u64,
    instance_type: u16,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    layout_source: []const u8,
    dwarf_fields: u64 = 0,
    memory_reads: usize,
    memory_bytes: usize,
    items: []JavaScriptItem,
};
pub const PerlItem = struct { address: u64, key: []const u8, type: []const u8, display: []const u8, diagnostic: ?[]const u8 };
pub const PerlValue = struct {
    class_name: ?[]const u8 = null,
    stored_value_only: bool = false,
    utf8: bool = false,
    type: []const u8,
    display: []const u8,
    refcount: u32,
    flags: u32,
    body: u64,
    runtime_build_id: []const u8,
    items: []PerlItem,
};
pub const PythonItem = struct { address: u64, key: []const u8, type: []const u8, display: []const u8, diagnostic: ?[]const u8 };
pub const PythonValue = struct {
    type: []const u8,
    display: []const u8,
    refcount: u64,
    immortal: bool,
    type_object: u64,
    runtime_version: []const u8,
    runtime_build_id: []const u8,
    items: []PythonItem,
};
pub fn preview(ctx: eval.Context, v: eval.Value) !?Preview {
    if (layout(v.type) == null) return null;
    const seq = (try sequence(ctx, v)).?;
    var result = Preview{ .presentation = seq.presentation, .data_address = seq.address, .count = seq.count, .element_type = seq.element.name, .capacity = seq.capacity };
    if (seq.presentation != .bytes) return result;
    var buffer: [max_preview]u8 = undefined;
    const wanted: usize = @intCast(@min(seq.count, buffer.len));
    const n = if (wanted == 0) 0 else ctx.read(ctx.user, seq.address, buffer[0..wanted]) catch |err| {
        result.diagnostic = @errorName(err);
        result.truncated = seq.count > 0;
        return result;
    };
    result.preview_bytes = n;
    result.truncated = n < seq.count;
    if (n < wanted) result.diagnostic = "PartialMemoryRead";
    const length = n; // A cut UTF-8 codepoint remains exact hex evidence.
    if (std.unicode.utf8ValidateSlice(buffer[0..length])) {
        result.text = try ctx.allocator.dupe(u8, buffer[0..length]);
        result.preview_bytes = length;
    } else {
        const hex = try ctx.allocator.alloc(u8, n * 2);
        const digits = "0123456789abcdef";
        for (buffer[0..n], 0..) |b, i| {
            hex[i * 2] = digits[b >> 4];
            hex[i * 2 + 1] = digits[b & 15];
        }
        result.hex = hex;
    }
    return result;
}
pub const Child = struct { index: u64, name: []const u8, value: eval.Value };
pub const Page = struct { presentation: Presentation, total: u64, start: u64, next: ?u64, children: []Child };
pub fn children(ctx: eval.Context, v: eval.Value, start: u64, limit: usize, raw: bool) !Page {
    if (limit == 0 or limit > max_children) return error.InvalidValuePage;
    if (v.availability != .available) return error.ValueUnavailable;
    if (v.type.kind == .unknown) return error.UnsupportedType;
    const seq = if (raw) null else try sequence(ctx, v);
    const total = if (seq) |s| s.count else if (v.type.kind == .structure) v.type.fields.len else if (v.type.kind == .array) v.type.count else 0;
    if (start > total) return error.InvalidValuePage;
    const end = start + @min(limit, total - start);
    const items = try ctx.allocator.alloc(Child, @intCast(end - start));
    for (items, 0..) |*item, i| {
        const index = start + i;
        if (seq) |s| {
            const offset = std.math.mul(u64, index, s.element.size) catch return error.InvalidAddress;
            item.* = .{ .index = index, .name = try std.fmt.allocPrint(ctx.allocator, "[{d}]", .{index}), .value = .{ .type = s.element, .address = std.math.add(u64, s.address, offset) catch return error.InvalidAddress } };
        } else if (v.type.kind == .array) {
            const child = v.type.child orelse return error.UnsupportedType;
            const offset = std.math.mul(u64, index, child.size) catch return error.InvalidAddress;
            item.* = .{ .index = index, .name = try std.fmt.allocPrint(ctx.allocator, "[{d}]", .{index}), .value = try eval.subvalue(v, child, offset) };
        } else {
            const f = v.type.fields[@intCast(index)];
            item.* = .{ .index = index, .name = f.name, .value = try field(v, f) };
        }
    }
    return .{ .presentation = if (seq) |s| s.presentation else if (v.type.kind == .structure) .fields else if (v.type.kind == .array) .array else .scalar, .total = total, .start = start, .next = if (end < total) end else null, .children = items };
}
test "slice adapters require producer metadata, use recorded offsets and bound reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const Fixture = struct {
        data: [160]u8 = @splat(0),
        reads: usize = 0,
        largest: usize = 0,
        fn lookup(_: *anyopaque, _: []const u8) !eval.Value {
            return error.UnknownVariable;
        }
        fn read(p: *anyopaque, address: u64, out: []u8) !usize {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.reads += 1;
            self.largest = @max(self.largest, out.len);
            if (address > self.data.len or out.len > self.data.len - address) return error.MemoryUnreadable;
            @memcpy(out, self.data[@intCast(address)..][0..out.len]);
            return out.len;
        }
    };
    var f = Fixture{};
    const ctx = eval.Context{ .allocator = arena.allocator(), .user = &f, .read = Fixture.read, .lookup = Fixture.lookup };
    const u8type = eval.Type{ .name = "u8", .kind = .unsigned, .size = 1 };
    const ptr = eval.Type{ .name = "[*]u8", .kind = .pointer, .size = 8, .child = &u8type };
    var t = eval.Type{ .name = "[]u8", .kind = .structure, .size = 16, .language = .zig, .fields = &.{ .{ .name = "len", .offset = 0, .type = &eval.uint_type }, .{ .name = "ptr", .offset = 8, .type = &ptr } } };
    // Reversed offsets deliberately reject a hard-coded (ptr,len) assumption.
    std.mem.writeInt(u64, f.data[0..8], 100, .little);
    std.mem.writeInt(u64, f.data[8..16], 32, .little);
    @memset(f.data[32..132], 'a');
    const v = eval.Value{ .type = &t, .address = 0 };
    const shown = (try preview(ctx, v)).?;
    try std.testing.expectEqual(100, shown.count);
    try std.testing.expectEqual(64, shown.preview_bytes);
    try std.testing.expect(shown.truncated);
    try std.testing.expectEqual(64, f.largest);
    const page = try children(ctx, v, 98, 64, false);
    try std.testing.expectEqual(2, page.children.len);
    try std.testing.expectEqual(130, page.children[0].value.address.?);
    try std.testing.expectError(error.InvalidValuePage, children(ctx, v, 101, 1, false));
    try std.testing.expectError(error.InvalidValuePage, children(ctx, v, 0, 65, false));
    t.language = .unknown;
    const before = f.reads;
    try std.testing.expectEqual(null, try preview(ctx, v));
    try std.testing.expectEqual(before, f.reads);
    t.language = .zig;
    std.mem.writeInt(u64, f.data[0..8], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidAddress, sequence(ctx, v));
    std.mem.writeInt(u64, f.data[0..8], 0, .little);
    std.mem.writeInt(u64, f.data[8..16], std.math.maxInt(u64), .little);
    try std.testing.expectEqualStrings("", (try preview(ctx, v)).?.text.?);
    std.mem.writeInt(u64, f.data[0..8], 3, .little);
    std.mem.writeInt(u64, f.data[8..16], 32, .little);
    @memcpy(f.data[32..35], &[_]u8{ 0, 255, 65 });
    try std.testing.expectEqualStrings("00ff41", (try preview(ctx, v)).?.hex.?);
    std.mem.writeInt(u64, f.data[8..16], 900, .little);
    try std.testing.expectEqualStrings("MemoryUnreadable", (try preview(ctx, v)).?.diagnostic.?);
}
