//! GDScript values from stopped memory: the locals and members of one call
//! level, `Variant` previews, and containers and objects one level at a
//! time. Every offset, size and `Variant::Type` value comes from the engine
//! binary's own DWARF (see gdscript.zig); a type or member this build does
//! not have is a named reason, never a guessed offset. Reads are counted and
//! every length and chain taken from the target is bounded.
const std = @import("std");
const c = @import("../c.zig").api;
const gd = @import("gdscript.zig");
const named = @import("../model/language_locals.zig");
const A = std.mem.Allocator;
const Memory = gd.Memory;
const Layout = gd.Layout;

pub const instance_vtable_symbol = "_ZTV16GDScriptInstance";
/// Target reads for one page of locals, and for one expression.
pub const page_reads = 1 << 14;
pub const path_reads = 1 << 20;
/// Stack slots, members and debug records looked at for one level.
const max_slots = 1024;
const max_members = 2048;
const max_debug = 4096;
/// Dictionary pairs walked to find one key or reach one page.
const max_scan = 1 << 18;
/// Elements shown in a container's own line, and children listed under it.
const inline_items = 8;
const nested_items = 4;
const line_bytes = 240;
pub const row_children = 12;
pub const path_children = 32;
const top_chars = 96;
const inner_chars = 40;
const max_path_steps = 8;

pub const Type = enum(u8) { variant, variant_type, obj_data, array, dictionary, pair, stack_debug, debug_list, debug_element, property, member_element, object, node, node_path, node_path_data, packed_ref, callable, signal, function, script, instance };
pub const type_names = [_][*:0]const u8{
    "Variant",
    "Variant::Type",
    "Variant::ObjData",
    "ArrayPrivate",
    "DictionaryPrivate",
    "HashMapElement<Variant, Variant>",
    "GDScriptFunction::StackDebug",
    "List<GDScriptFunction::StackDebug, DefaultAllocator>::_Data",
    "List<GDScriptFunction::StackDebug, DefaultAllocator>::Element",
    "PropertyInfo",
    "HashMapElement<StringName, GDScript::MemberInfo>",
    "Object",
    "Node",
    "NodePath",
    "NodePath::Data",
    // Every PackedArrayRef<T> is a reference count and one Vector<T>.
    "Variant::PackedArrayRef<String>",
    "Callable",
    "Signal",
    "GDScriptFunction",
    "GDScript",
    "GDScriptInstance",
};
pub const F = enum(u8) { variant_type, variant_data, obj_id, obj_ptr, array_ptr, dict_head, dict_count, pair_next, pair_key, pair_value, debug_line, debug_pos, debug_added, debug_identifier, list_first, element_value, element_next, property_name, member_next, member_key, member_index, object_id, object_script_instance, object_class_name, node_name, node_parent, path_data, path_names, path_subnames, path_absolute, packed_ptr, callable_method, signal_name, signal_object, function_argument_count, function_stack_size, function_stack_debug, function_arguments, script_members, instance_members, instance_script };
const Spec = struct { Type, [*:0]const u8, c_uint, u8, bool };
// In `F` order. A member path goes through members held by value only.
const specs = [_]Spec{
    .{ .variant, "type", c.XDT_ANY, 4, false },
    .{ .variant, "_data", c.XDT_ANY, 16, false },
    .{ .obj_data, "id", c.XDT_ANY, 8, false },
    .{ .obj_data, "obj", c.XDT_POINTER, 8, false },
    .{ .array, "array._cowdata._ptr", c.XDT_POINTER, 8, false },
    .{ .dictionary, "variant_map.head_element", c.XDT_POINTER, 8, false },
    .{ .dictionary, "variant_map.num_elements", c.XDT_UNSIGNED, 4, false },
    .{ .pair, "next", c.XDT_POINTER, 8, false },
    .{ .pair, "data.key", c.XDT_ANY, 24, false },
    .{ .pair, "data.value", c.XDT_ANY, 24, false },
    .{ .stack_debug, "line", c.XDT_SIGNED, 4, false },
    .{ .stack_debug, "pos", c.XDT_SIGNED, 4, false },
    .{ .stack_debug, "added", c.XDT_BOOLEAN, 1, false },
    .{ .stack_debug, "identifier", c.XDT_ANY, 8, false },
    .{ .debug_list, "first", c.XDT_POINTER, 8, false },
    .{ .debug_element, "value", c.XDT_ANY, 0, false },
    .{ .debug_element, "next_ptr", c.XDT_POINTER, 8, false },
    .{ .property, "name", c.XDT_ANY, 8, false },
    .{ .member_element, "next", c.XDT_POINTER, 8, false },
    .{ .member_element, "data.key", c.XDT_ANY, 8, false },
    .{ .member_element, "data.value.index", c.XDT_SIGNED, 4, false },
    .{ .object, "_instance_id", c.XDT_ANY, 8, false },
    .{ .object, "script_instance", c.XDT_POINTER, 8, false },
    .{ .object, "_class_name_ptr", c.XDT_POINTER, 8, true },
    .{ .node, "data.name", c.XDT_ANY, 8, false },
    .{ .node, "data.parent", c.XDT_POINTER, 8, true },
    .{ .node_path, "data", c.XDT_POINTER, 8, false },
    .{ .node_path_data, "path._cowdata._ptr", c.XDT_POINTER, 8, false },
    .{ .node_path_data, "subpath._cowdata._ptr", c.XDT_POINTER, 8, true },
    .{ .node_path_data, "absolute", c.XDT_BOOLEAN, 1, true },
    .{ .packed_ref, "array._cowdata._ptr", c.XDT_POINTER, 8, false },
    .{ .callable, "method", c.XDT_ANY, 8, false },
    .{ .signal, "name", c.XDT_ANY, 8, false },
    .{ .signal, "object", c.XDT_ANY, 8, false },
    .{ .function, "_argument_count", c.XDT_SIGNED, 4, false },
    .{ .function, "_stack_size", c.XDT_SIGNED, 4, false },
    .{ .function, "stack_debug._data", c.XDT_POINTER, 8, true },
    .{ .function, "method_info.arguments._cowdata._ptr", c.XDT_POINTER, 8, true },
    .{ .script, "member_indices.head_element", c.XDT_POINTER, 8, false },
    .{ .instance, "members._cowdata._ptr", c.XDT_POINTER, 8, false },
    .{ .instance, "script.reference", c.XDT_POINTER, 8, false },
};
pub const field_count = specs.len;
/// `Variant::Type`, in the engine's order: the enumerator the value is read
/// from, and the name GDScript gives the type.
pub const Kind = enum(u8) { nil, bool, int, float, string, vector2, vector2i, rect2, rect2i, vector3, vector3i, transform2d, vector4, vector4i, plane, quaternion, aabb, basis, transform3d, projection, color, string_name, node_path, rid, object, callable, signal, dictionary, array, packed_byte_array, packed_int32_array, packed_int64_array, packed_float32_array, packed_float64_array, packed_string_array, packed_vector2_array, packed_vector3_array, packed_color_array, packed_vector4_array };
const kind_names = [_]struct { [*:0]const u8, []const u8 }{
    .{ "NIL", "Nil" },                                   .{ "BOOL", "bool" },                               .{ "INT", "int" },                             .{ "FLOAT", "float" },
    .{ "STRING", "String" },                             .{ "VECTOR2", "Vector2" },                         .{ "VECTOR2I", "Vector2i" },                   .{ "RECT2", "Rect2" },
    .{ "RECT2I", "Rect2i" },                             .{ "VECTOR3", "Vector3" },                         .{ "VECTOR3I", "Vector3i" },                   .{ "TRANSFORM2D", "Transform2D" },
    .{ "VECTOR4", "Vector4" },                           .{ "VECTOR4I", "Vector4i" },                       .{ "PLANE", "Plane" },                         .{ "QUATERNION", "Quaternion" },
    .{ "AABB", "AABB" },                                 .{ "BASIS", "Basis" },                             .{ "TRANSFORM3D", "Transform3D" },             .{ "PROJECTION", "Projection" },
    .{ "COLOR", "Color" },                               .{ "STRING_NAME", "StringName" },                  .{ "NODE_PATH", "NodePath" },                  .{ "RID", "RID" },
    .{ "OBJECT", "Object" },                             .{ "CALLABLE", "Callable" },                       .{ "SIGNAL", "Signal" },                       .{ "DICTIONARY", "Dictionary" },
    .{ "ARRAY", "Array" },                               .{ "PACKED_BYTE_ARRAY", "PackedByteArray" },       .{ "PACKED_INT32_ARRAY", "PackedInt32Array" }, .{ "PACKED_INT64_ARRAY", "PackedInt64Array" },
    .{ "PACKED_FLOAT32_ARRAY", "PackedFloat32Array" },   .{ "PACKED_FLOAT64_ARRAY", "PackedFloat64Array" }, .{ "PACKED_STRING_ARRAY", "PackedStringArray" }, .{ "PACKED_VECTOR2_ARRAY", "PackedVector2Array" },
    .{ "PACKED_VECTOR3_ARRAY", "PackedVector3Array" },   .{ "PACKED_COLOR_ARRAY", "PackedColorArray" },     .{ "PACKED_VECTOR4_ARRAY", "PackedVector4Array" },
};
pub const kind_count = kind_names.len;
comptime {
    std.debug.assert(specs.len == @typeInfo(F).@"enum".fields.len and type_names.len == @typeInfo(Type).@"enum".fields.len and kind_names.len == @typeInfo(Kind).@"enum".fields.len);
}
/// The schema rows after gdscript.zig's own: members, then enumerators.
pub fn wanted(comptime base: usize) [specs.len + kind_names.len]c.struct_xdt_field {
    var out: [specs.len + kind_names.len]c.struct_xdt_field = undefined;
    for (specs, 0..) |spec, i| out[i] = .{ .owner = @intCast(base + @intFromEnum(spec[0])), .name = spec[1], .kind = @intCast(spec[2]), .width = spec[3], .optional = @intFromBool(spec[4]) };
    for (kind_names, 0..) |kind, i| out[specs.len + i] = .{ .owner = @intCast(base + @intFromEnum(Type.variant_type)), .name = kind[0], .kind = c.XDT_ANY, .width = 0, .optional = 1 };
    return out;
}
/// Null when a Variant can be read at all in this build: 24 bytes (a
/// single-precision engine), with its type tag and 16 data bytes inside.
pub fn usable(layout: *const Layout) ?[]const u8 {
    const tag = layout.value_offsets[@intFromEnum(F.variant_type)] orelse return "GDScriptValueLayoutUnavailable";
    const data = layout.value_offsets[@intFromEnum(F.variant_data)] orelse return "GDScriptValueLayoutUnavailable";
    if (layout.value_sizes[@intFromEnum(Type.variant)] != 24 or tag > 20 or data > 8 or layout.kinds[0] == null) return "GDScriptValueLayoutUnavailable";
    return null;
}

pub const Raw = [24]u8;
pub const Slot = struct { raw: Raw, address: ?u64 = null };
pub const Shown = struct { type: []const u8, display: []const u8, count: ?u64 = null, reason: ?[]const u8 = null, truncated: bool = false, object: ?u64 = null };
pub const Described = struct { shown: Shown, children: []named.Child = &.{} };
pub const Expanded = struct { count: u64 = 0, children: []named.Child = &.{}, reason: ?[]const u8 = null };
const Span = struct { ptr: u64 = 0, count: u64 = 0, reason: ?[]const u8 = null };
const Class = struct { name: []const u8 = "Object", node: bool = false };
const Object = struct {
    id: i64,
    ptr: u64,
    state: enum { null, live, freed, unreadable, unproved } = .live,
    class: Class = .{},
    /// The object's GDScriptInstance, proved by its vtable pointer.
    instance: u64 = 0,
};
const Member = struct { name: u64, index: u32 };
const Members = struct { names: []Member = &.{}, values: Span = .{}, reason: ?[]const u8 = null };

const Out = struct {
    a: A,
    list: std.ArrayList(u8) = .empty,
    fn add(self: *Out, text: []const u8) !void {
        try self.list.appendSlice(self.a, text);
    }
    fn print(self: *Out, comptime format: []const u8, args: anytype) !void {
        try self.add(try std.fmt.allocPrint(self.a, format, args));
    }
    fn float(self: *Out, comptime T: type, x: T) !void {
        if (std.math.isNan(x)) return self.add("nan");
        if (std.math.isInf(x)) return self.add(if (x < 0) "-inf" else "inf");
        const size = @abs(x);
        if (size != 0 and (size >= 1e15 or size < 1e-5)) return self.print("{e}", .{x});
        const text = try std.fmt.allocPrint(self.a, "{d}", .{x});
        try self.add(text);
        if (std.mem.indexOfScalar(u8, text, '.') == null) try self.add(".0");
    }
    /// "(a, b, c)" from `n` consecutive f32 or i32.
    fn tuple(self: *Out, bytes: []const u8, n: usize, integers: bool) !void {
        return self.group(bytes, n, integers, true);
    }
    /// The engine writes a quaternion's whole components without ".0".
    fn group(self: *Out, bytes: []const u8, n: usize, integers: bool, point: bool) !void {
        try self.add("(");
        for (0..n) |i| {
            if (i != 0) try self.add(", ");
            const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
            if (integers) try self.print("{d}", .{@as(i32, @bitCast(bits))}) else if (point) try self.float(f32, @bitCast(bits)) else try self.print("{d}", .{@as(f32, @bitCast(bits))});
        }
        try self.add(")");
    }
};
fn u64At(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
/// Bytes of one packed-array element, and the Variant type it is shown as.
fn packedElement(kind: Kind) ?struct { usize, Kind } {
    return switch (kind) {
        .packed_byte_array => .{ 1, .int },
        .packed_int32_array => .{ 4, .int },
        .packed_int64_array => .{ 8, .int },
        .packed_float32_array => .{ 4, .float },
        .packed_float64_array => .{ 8, .float },
        .packed_string_array => .{ 8, .string },
        .packed_vector2_array => .{ 8, .vector2 },
        .packed_vector3_array => .{ 12, .vector3 },
        .packed_color_array => .{ 16, .color },
        .packed_vector4_array => .{ 16, .vector4 },
        else => null,
    };
}
/// Components of the value types that are held inside the Variant.
const Component = struct { name: []const u8, at: u8, kind: Kind };
fn components(kind: Kind) []const Component {
    return switch (kind) {
        .vector2 => &.{ .{ .name = "x", .at = 0, .kind = .float }, .{ .name = "y", .at = 4, .kind = .float } },
        .vector2i => &.{ .{ .name = "x", .at = 0, .kind = .int }, .{ .name = "y", .at = 4, .kind = .int } },
        .vector3 => &.{ .{ .name = "x", .at = 0, .kind = .float }, .{ .name = "y", .at = 4, .kind = .float }, .{ .name = "z", .at = 8, .kind = .float } },
        .vector3i => &.{ .{ .name = "x", .at = 0, .kind = .int }, .{ .name = "y", .at = 4, .kind = .int }, .{ .name = "z", .at = 8, .kind = .int } },
        .vector4, .quaternion => &.{ .{ .name = "x", .at = 0, .kind = .float }, .{ .name = "y", .at = 4, .kind = .float }, .{ .name = "z", .at = 8, .kind = .float }, .{ .name = "w", .at = 12, .kind = .float } },
        .vector4i => &.{ .{ .name = "x", .at = 0, .kind = .int }, .{ .name = "y", .at = 4, .kind = .int }, .{ .name = "z", .at = 8, .kind = .int }, .{ .name = "w", .at = 12, .kind = .int } },
        .color => &.{ .{ .name = "r", .at = 0, .kind = .float }, .{ .name = "g", .at = 4, .kind = .float }, .{ .name = "b", .at = 8, .kind = .float }, .{ .name = "a", .at = 12, .kind = .float } },
        .rect2 => &.{ .{ .name = "position", .at = 0, .kind = .vector2 }, .{ .name = "size", .at = 8, .kind = .vector2 } },
        .rect2i => &.{ .{ .name = "position", .at = 0, .kind = .vector2i }, .{ .name = "size", .at = 8, .kind = .vector2i } },
        else => &.{},
    };
}
/// A class name from the C++ ABI's type name: "4Node", or "N3Foo3BarE".
fn abiName(a: A, bytes: []const u8) !?[]const u8 {
    var at: usize = @intFromBool(bytes.len > 0 and bytes[0] == '*');
    const nested = at < bytes.len and bytes[at] == 'N';
    if (nested) at += 1;
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var length: usize = 0;
        const digits = at;
        while (at < bytes.len and bytes[at] >= '0' and bytes[at] <= '9' and at - digits < 3) : (at += 1) length = length * 10 + (bytes[at] - '0');
        if (at == digits or length == 0 or length > bytes.len - at) return null;
        for (bytes[at..][0..length]) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return null;
        }
        if (out.items.len != 0) try out.appendSlice(a, "::");
        try out.appendSlice(a, bytes[at..][0..length]);
        at += length;
        if (!nested) break;
        if (at < bytes.len and bytes[at] == 'E') {
            at += 1;
            break;
        }
    }
    if (at >= bytes.len or bytes[at] != 0) return null;
    return out.items;
}

/// "[a, b, …]" or "{k: a, …}" from the first `most` of `total` children;
/// true when some are left out.
fn bracket(out: *Out, pairs: bool, items: []const named.Child, total: u64, most: usize) !bool {
    const begin = out.list.items.len;
    try out.add(if (pairs) "{" else "[");
    var shown: usize = 0;
    for (items[0..@min(items.len, most)]) |item| {
        if (out.list.items.len - begin > line_bytes) break;
        if (shown != 0) try out.add(", ");
        if (pairs) try out.print("{s}: ", .{item.key});
        try out.add(item.display);
        shown += 1;
    }
    const cut = shown < total;
    if (cut) try out.add(if (shown == 0) "…" else ", …");
    try out.add(if (pairs) "}" else "]");
    return cut;
}

pub const Reader = struct {
    memory: *Memory,
    a: A,
    layout: *const Layout,
    /// Why the last `select` or `frame` step found nothing.
    why: ?[]const u8 = null,
    classes: std.ArrayList(struct { vptr: u64, class: Class }) = .empty,

    fn off(self: *const Reader, field: F) ?u32 {
        return self.layout.value_offsets[@intFromEnum(field)];
    }
    fn size(self: *const Reader, t: Type) u32 {
        return self.layout.value_sizes[@intFromEnum(t)];
    }
    pub fn kindOf(self: *const Reader, raw: *const Raw) ?Kind {
        const tag = std.mem.readInt(u32, raw[self.off(.variant_type).?..][0..4], .little);
        for (self.layout.kinds, 0..) |value, i| {
            if (value != null and value.? == tag) return @enumFromInt(i);
        }
        return null;
    }
    fn data(self: *const Reader, raw: *const Raw) *const [16]u8 {
        return raw[self.off(.variant_data).?..][0..16];
    }
    /// A Variant of `kind` around `bytes`, for values that have no Variant of
    /// their own in the target (packed elements, components).
    fn make(self: *const Reader, kind: Kind, bytes: []const u8) ?Raw {
        const tag = self.layout.kinds[@intFromEnum(kind)] orelse return null;
        var raw: Raw = @splat(0);
        std.mem.writeInt(u32, raw[self.off(.variant_type).?..][0..4], tag, .little);
        @memcpy(raw[self.off(.variant_data).?..][0..bytes.len], bytes);
        return raw;
    }
    /// The same from one stored element: a byte or an int32 widens to the
    /// Variant's int64, a float32 to its double.
    fn element(self: *const Reader, kind: Kind, bytes: []const u8) ?Raw {
        var wide: [8]u8 = undefined;
        if (kind == .int and bytes.len < 8) {
            std.mem.writeInt(i64, &wide, if (bytes.len == 1) bytes[0] else std.mem.readInt(i32, bytes[0..4], .little), .little);
            return self.make(kind, &wide);
        }
        if (kind == .float and bytes.len == 4) {
            const value: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
            std.mem.writeInt(u64, &wide, @bitCast(@as(f64, value)), .little);
            return self.make(kind, &wide);
        }
        return self.make(kind, bytes);
    }
    fn limited(self: *const Reader, reason: []const u8) []const u8 {
        return if (self.memory.reads >= self.memory.limit) "GDScriptReadLimit" else reason;
    }
    /// The elements behind a CowData pointer: the count is stored before
    /// them, after the reference count.
    fn cow(self: *Reader, ptr: u64) Span {
        if (ptr == 0) return .{};
        if (ptr < 16 or ptr % 8 != 0) return .{ .reason = "GDScriptContainerInvalid" };
        var header: [16]u8 = undefined;
        if (!self.memory.read(ptr - 16, &header)) return .{ .reason = self.limited("GDScriptContainerUnreadable") };
        const references = u64At(&header, 0);
        const count = u64At(&header, 8);
        if (references == 0 or references > std.math.maxInt(u32) or count > std.math.maxInt(u32)) return .{ .reason = "GDScriptContainerInvalid" };
        return .{ .ptr = ptr, .count = count };
    }
    /// The Vector inside the private object a Variant points at.
    fn vector(self: *Reader, raw: *const Raw, field: F, missing: []const u8) Span {
        const at = self.off(field) orelse return .{ .reason = missing };
        const private = u64At(self.data(raw), 0);
        if (private == 0) return .{};
        if (private % 8 != 0) return .{ .reason = "GDScriptContainerInvalid" };
        return self.cow(self.memory.word(private +% at) orelse return .{ .reason = self.limited("GDScriptContainerUnreadable") });
    }
    fn quoted(self: *Reader, out: *Out, shown: *Shown, prefix: []const u8, text: gd.Text) !void {
        _ = self;
        if (text.reason) |why| {
            shown.reason = why;
            return out.add("unreadable");
        }
        try out.print("{s}\"{s}{s}\"", .{ prefix, text.text, if (text.truncated) "…" else "" });
        if (text.truncated) {
            shown.truncated = true;
            shown.count = text.length;
        }
    }
    fn name(self: *Reader, data_ptr: u64) ![]const u8 {
        const text = try gd.nameData(self.memory, self.a, self.layout, data_ptr);
        return if (text.reason != null) "?" else text.text;
    }

    fn typeName(self: *Reader, info: u64) !?[]const u8 {
        const at = self.memory.word(info +% 8) orelse return null;
        var bytes: [80]u8 = undefined;
        const got: []const u8 = if (self.memory.read(at, &bytes)) &bytes else if (self.memory.read(at, bytes[0..24])) bytes[0..24] else return null;
        return abiName(self.a, got);
    }
    /// The object's C++ class and whether it is a Node, from the type
    /// information its own vtable points at (single inheritance only, as the
    /// engine's Object classes are). Without it, the engine's cached name.
    fn classOf(self: *Reader, address: u64) !Class {
        const vptr = self.memory.word(address) orelse return .{};
        for (self.classes.items) |known| {
            if (known.vptr == vptr) return known.class;
        }
        var class = Class{};
        var proved = false;
        if (vptr >= 16 and vptr % 8 == 0) {
            var info = self.memory.word(vptr - 8) orelse 0;
            for (0..24) |depth| {
                if (info == 0 or info % 8 != 0) break;
                const text = try self.typeName(info) orelse break;
                if (depth == 0) {
                    class.name = text;
                    proved = true;
                }
                if (std.mem.eql(u8, text, "Node")) class.node = true;
                if (class.node or std.mem.eql(u8, text, "Object")) break;
                info = self.memory.word(info +% 16) orelse break;
            }
        }
        if (!proved) {
            if (self.off(.object_class_name)) |at| {
                const cached = self.memory.word(address +% at) orelse 0;
                if (cached != 0 and cached % 8 == 0) {
                    const text = try gd.stringName(self.memory, self.a, self.layout, cached);
                    if (text.reason == null and text.text.len != 0) class.name = text.text;
                }
            }
        }
        if (self.classes.items.len < 64) try self.classes.append(self.a, .{ .vptr = vptr, .class = class });
        return class;
    }
    fn object(self: *Reader, raw: *const Raw) !Object {
        const data_bytes = self.data(raw);
        const id_at = self.off(.obj_id) orelse return .{ .id = 0, .ptr = 0, .state = .unproved };
        const ptr_at = self.off(.obj_ptr) orelse return .{ .id = 0, .ptr = 0, .state = .unproved };
        var out = Object{ .id = @bitCast(u64At(data_bytes, id_at)), .ptr = u64At(data_bytes, ptr_at) };
        if (out.ptr == 0) {
            out.state = .null;
            return out;
        }
        const stored_at = self.off(.object_id) orelse {
            out.state = .unproved;
            return out;
        };
        // The object must still carry the id the Variant remembers.
        const stored = if (out.ptr % 8 == 0) self.memory.word(out.ptr +% stored_at) else null;
        if (stored == null) {
            out.state = .unreadable;
            return out;
        }
        if (stored.? != @as(u64, @bitCast(out.id))) {
            out.state = .freed;
            return out;
        }
        out.class = try self.classOf(out.ptr);
        if (self.off(.object_script_instance)) |at| {
            const instance = self.memory.word(out.ptr +% at) orelse 0;
            if (instance != 0 and instance % 8 == 0 and self.layout.instance_vtable != null) {
                if (self.memory.word(instance)) |vptr| {
                    if (vptr == self.layout.instance_vtable.?) out.instance = instance;
                }
            }
        }
        return out;
    }
    fn scriptPath(self: *Reader, instance: u64) !?[]const u8 {
        const at = self.off(.instance_script) orelse return null;
        const script = self.memory.word(instance +% at) orelse return null;
        if (script == 0 or script % 8 != 0) return null;
        const chars = self.memory.word(script +% self.layout.at(.script_path) +% self.layout.at(.string_data)) orelse return null;
        const text = try gd.stringCut(self.memory, self.a, chars, 256);
        return if (text.reason == null and text.text.len != 0) text.text else null;
    }
    /// "/root/Main/Player" by following parents; null for a node with none.
    fn nodePath(self: *Reader, node: u64, own: []const u8) !?[]const u8 {
        const name_at = self.off(.node_name) orelse return null;
        const parent_at = self.off(.node_parent) orelse return null;
        var names: [32][]const u8 = undefined;
        var count: usize = 0;
        var at = node;
        while (count < names.len) {
            const parent = self.memory.word(at +% parent_at) orelse return null;
            if (parent == 0) break;
            if (parent % 8 != 0) return null;
            const text = try gd.stringName(self.memory, self.a, self.layout, parent +% name_at);
            if (text.reason != null) return null;
            names[count] = text.text;
            count += 1;
            at = parent;
        } else return null;
        if (count == 0) return null;
        var out = Out{ .a = self.a };
        var i = count;
        while (i > 0) : (i -= 1) try out.print("/{s}", .{names[i - 1]});
        try out.print("/{s}", .{own});
        return out.list.items;
    }
    fn showObject(self: *Reader, raw: *const Raw, deep: bool, out: *Out, shown: *Shown) !void {
        const found = try self.object(raw);
        switch (found.state) {
            .null => return out.add("<null>"),
            .unproved => {
                shown.reason = "GDScriptObjectLayoutUnavailable";
                return out.print("<Object#{d}>", .{found.id});
            },
            .unreadable => {
                shown.reason = self.limited("GDScriptObjectUnreadable");
                return out.print("<Object#{d}>", .{found.id});
            },
            .freed => {
                shown.reason = "GDScriptObjectFreed";
                return out.print("<Freed Object#{d}>", .{found.id});
            },
            .live => {},
        }
        shown.object = found.ptr;
        shown.type = found.class.name;
        var node_name: ?[]const u8 = null;
        if (found.class.node) {
            if (self.off(.node_name)) |at| {
                const text = try gd.stringName(self.memory, self.a, self.layout, found.ptr +% at);
                if (text.reason == null) node_name = text.text;
            }
        }
        if (node_name) |text| try out.print("{s}:", .{text});
        try out.print("<{s}#{d}>", .{ found.class.name, found.id });
        if (!deep) return;
        if (node_name) |text| {
            if (try self.nodePath(found.ptr, text)) |path| try out.print(" {s}", .{path});
        }
        if (found.instance != 0) {
            if (try self.scriptPath(found.instance)) |path| try out.print(" ({s})", .{path});
        }
    }
    fn showNodePath(self: *Reader, raw: *const Raw, out: *Out, shown: *Shown) !void {
        const names_at = self.off(.path_names) orelse {
            shown.reason = "GDScriptNodePathLayoutUnavailable";
            return out.add("^\"…\"");
        };
        const data_ptr = u64At(self.data(raw), 0);
        try out.add("^\"");
        if (data_ptr != 0 and data_ptr % 8 == 0) {
            var absolute: [1]u8 = .{0};
            if (self.off(.path_absolute)) |at| _ = self.memory.read(data_ptr +% at, &absolute);
            var first = absolute[0] == 0;
            for ([_]?u32{ names_at, self.off(.path_subnames) }, 0..) |field, part| {
                const span = self.cow(self.memory.word(data_ptr +% (field orelse continue)) orelse 0);
                if (span.reason) |why| shown.reason = why;
                var words: [16 * 8]u8 = undefined;
                const n: usize = @intCast(@min(span.count, 16));
                if (n == 0 or !self.memory.read(span.ptr, words[0 .. n * 8])) continue;
                for (0..n) |i| {
                    try out.add(if (part == 1) ":" else if (first) "" else "/");
                    first = false;
                    try out.add(try self.name(u64At(&words, i * 8)));
                }
                if (span.count > n) {
                    try out.add("…");
                    shown.truncated = true;
                }
            }
        }
        try out.add("\"");
    }
    /// Transform2D, AABB, Basis, Transform3D and Projection live outside the
    /// Variant: `n` floats behind one pointer.
    fn showHeap(self: *Reader, kind: Kind, raw: *const Raw, out: *Out, shown: *Shown) !void {
        const n: usize = switch (kind) {
            .transform2d, .aabb => 6,
            .basis => 9,
            .transform3d => 12,
            else => 16,
        };
        var bytes: [64]u8 = undefined;
        const at = u64At(self.data(raw), 0);
        if (at == 0 or at % 4 != 0 or !self.memory.read(at, bytes[0 .. n * 4])) {
            shown.reason = self.limited("GDScriptValueUnreadable");
            return out.add("unreadable");
        }
        switch (kind) {
            .transform2d => inline for (.{ "[X: ", ", Y: ", ", O: " }, 0..) |label, i| {
                try out.add(label);
                try out.tuple(bytes[i * 8 ..], 2, false);
            },
            .aabb => inline for (.{ "[P: ", ", S: " }, 0..) |label, i| {
                try out.add(label);
                try out.tuple(bytes[i * 12 ..], 3, false);
            },
            // A Basis stores rows; GDScript shows its axes, the columns.
            .basis, .transform3d => {
                inline for (.{ "[X: ", ", Y: ", ", Z: " }, 0..) |label, column| {
                    var axis: [12]u8 = undefined;
                    for (0..3) |row| @memcpy(axis[row * 4 ..][0..4], bytes[(row * 3 + column) * 4 ..][0..4]);
                    try out.add(label);
                    try out.tuple(&axis, 3, false);
                }
                if (kind == .transform3d) {
                    try out.add(", O: ");
                    try out.tuple(bytes[36..], 3, false);
                }
            },
            else => for (0..4) |i| {
                try out.add(if (i == 0) "[" else ", ");
                try out.tuple(bytes[i * 16 ..], 4, false);
            },
        }
        try out.add("]");
    }
    /// One value on one line. `deep` is the value asked for itself; a value
    /// shown inside another is cut shorter and its containers only counted.
    pub fn show(self: *Reader, raw: *const Raw, deep: bool) anyerror!Shown {
        const kind = self.kindOf(raw) orelse return .{ .type = "unknown", .display = "unknown Variant type", .reason = "GDScriptVariantTypeUnknown" };
        var shown = Shown{ .type = kind_names[@intFromEnum(kind)][1], .display = "" };
        var out = Out{ .a = self.a };
        const bytes = self.data(raw);
        const chars: usize = if (deep) top_chars else inner_chars;
        switch (kind) {
            .nil => try out.add("null"),
            .bool => try out.add(if (bytes[0] != 0) "true" else "false"),
            .int => try out.print("{d}", .{@as(i64, @bitCast(u64At(bytes, 0)))}),
            .float => try out.float(f64, @bitCast(u64At(bytes, 0))),
            .string => try self.quoted(&out, &shown, "", try gd.stringCut(self.memory, self.a, u64At(bytes, 0), chars)),
            .string_name => try self.quoted(&out, &shown, "&", try gd.nameData(self.memory, self.a, self.layout, u64At(bytes, 0))),
            .node_path => try self.showNodePath(raw, &out, &shown),
            .vector2 => try out.tuple(bytes, 2, false),
            .vector2i => try out.tuple(bytes, 2, true),
            .vector3 => try out.tuple(bytes, 3, false),
            .vector3i => try out.tuple(bytes, 3, true),
            .vector4, .color => try out.tuple(bytes, 4, false),
            .quaternion => try out.group(bytes, 4, false, false),
            .vector4i => try out.tuple(bytes, 4, true),
            .rect2, .rect2i => {
                try out.add("[P: ");
                try out.tuple(bytes, 2, kind == .rect2i);
                try out.add(", S: ");
                try out.tuple(bytes[8..], 2, kind == .rect2i);
                try out.add("]");
            },
            .plane => {
                try out.add("[N: ");
                try out.tuple(bytes, 3, false);
                try out.add(", D: ");
                try out.float(f32, @bitCast(std.mem.readInt(u32, bytes[12..16], .little)));
                try out.add("]");
            },
            .transform2d, .aabb, .basis, .transform3d, .projection => try self.showHeap(kind, raw, &out, &shown),
            .rid => try out.print("RID({d})", .{u64At(bytes, 0)}),
            .object => try self.showObject(raw, deep, &out, &shown),
            .callable => {
                // A method name and an object id, or a custom callable.
                const at = self.off(.callable_method);
                if (at == null or at.? != 0 or self.size(.callable) != 16) {
                    shown.reason = "GDScriptCallableLayoutUnavailable";
                    try out.add("Callable");
                } else if (u64At(bytes, 0) == 0) {
                    try out.add(if (u64At(bytes, 8) == 0) "Callable(null)" else "Callable(custom)");
                } else try out.print("Callable({s} on #{d})", .{ try self.name(u64At(bytes, 0)), @as(i64, @bitCast(u64At(bytes, 8))) });
            },
            .signal => {
                const name_at = self.off(.signal_name);
                const object_at = self.off(.signal_object);
                if (name_at == null or object_at == null or name_at.? > 8 or object_at.? > 8) {
                    shown.reason = "GDScriptSignalLayoutUnavailable";
                    try out.add("Signal");
                } else try out.print("Signal({s} on #{d})", .{ try self.name(u64At(bytes, name_at.?)), @as(i64, @bitCast(u64At(bytes, object_at.?))) });
            },
            .dictionary => {
                const count = self.dictionary(raw);
                shown.count = count.count;
                shown.reason = count.reason;
                try out.print("Dictionary({d})", .{count.count});
            },
            .array => {
                const span = self.vector(raw, .array_ptr, "GDScriptArrayLayoutUnavailable");
                shown.count = span.count;
                shown.reason = span.reason;
                try out.print("Array({d})", .{span.count});
            },
            else => {
                const span = self.vector(raw, .packed_ptr, "GDScriptPackedArrayLayoutUnavailable");
                shown.count = span.count;
                shown.reason = span.reason;
                try out.print("{s}({d})", .{ shown.type, span.count });
            },
        }
        shown.display = out.list.items;
        return shown;
    }
    /// A dictionary's first pair and its own count.
    fn dictionary(self: *Reader, raw: *const Raw) Span {
        const head_at = self.off(.dict_head) orelse return .{ .reason = "GDScriptDictionaryLayoutUnavailable" };
        const count_at = self.off(.dict_count) orelse return .{ .reason = "GDScriptDictionaryLayoutUnavailable" };
        if (self.off(.pair_next) == null or self.off(.pair_key) == null or self.off(.pair_value) == null or self.size(.pair) > 256) return .{ .reason = "GDScriptDictionaryLayoutUnavailable" };
        const private = u64At(self.data(raw), 0);
        if (private == 0) return .{};
        if (private % 8 != 0) return .{ .reason = "GDScriptContainerInvalid" };
        const head = self.memory.word(private +% head_at) orelse return .{ .reason = self.limited("GDScriptContainerUnreadable") };
        var count: [4]u8 = undefined;
        if (!self.memory.read(private +% count_at, &count)) return .{ .reason = self.limited("GDScriptContainerUnreadable") };
        return .{ .ptr = head, .count = std.mem.readInt(u32, &count, .little) };
    }
    const Pair = struct { key: Raw, value: Slot };
    /// The pair at `node` and the next one: insertion order, as GDScript
    /// iterates. Null ends the walk; `self.why` says when that is an error.
    fn pair(self: *Reader, node: *u64) ?Pair {
        if (node.* == 0) return null;
        var bytes: [256]u8 = undefined;
        const key_at = self.off(.pair_key).?;
        const value_at = self.off(.pair_value).?;
        const next_at = self.off(.pair_next).?;
        const span = @max(@max(key_at, value_at) + 24, next_at + 8);
        if (node.* % 8 != 0 or span > bytes.len or !self.memory.read(node.*, bytes[0..span])) {
            self.why = self.limited("GDScriptContainerUnreadable");
            return null;
        }
        const out = Pair{ .key = bytes[key_at..][0..24].*, .value = .{ .raw = bytes[value_at..][0..24].*, .address = node.* +% value_at } };
        node.* = u64At(&bytes, next_at);
        return out;
    }
    /// `inner`: a container listed under another also shows its own first
    /// elements, one step and no further.
    fn child(self: *Reader, key: []const u8, slot: Slot, inner: bool) !named.Child {
        var shown = try self.show(&slot.raw, false);
        if (inner and shown.reason == null and shown.count != null and shown.count.? != 0) {
            const kind = self.kindOf(&slot.raw).?;
            if (kind != .object and kind != .string) {
                const found = try self.expand(&slot.raw, 0, nested_items, false);
                var out = Out{ .a = self.a };
                try out.add(shown.display);
                try out.add(" ");
                _ = try bracket(&out, kind == .dictionary, found.children, found.count, nested_items);
                shown.display = out.list.items;
            }
        }
        return .{ .key = key, .type = shown.type, .display = shown.display, .address = slot.address, .diagnostic = shown.reason, .advisory = false };
    }
    /// The script members of one instance: names in declaration order (base
    /// classes first) and the vector of their values.
    fn members(self: *Reader, instance: u64) !Members {
        const script_at = self.off(.instance_script) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const values_at = self.off(.instance_members) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const head_at = self.off(.script_members) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const next_at = self.off(.member_next) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const key_at = self.off(.member_key) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const index_at = self.off(.member_index) orelse return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        var bytes: [256]u8 = undefined;
        const span = @max(@max(next_at, key_at) + 8, index_at + 4);
        if (span > bytes.len) return .{ .reason = "GDScriptMemberLayoutUnavailable" };
        const script = self.memory.word(instance +% script_at) orelse return .{ .reason = self.limited("GDScriptMembersUnreadable") };
        if (script == 0 or script % 8 != 0) return .{ .reason = "GDScriptMembersUnreadable" };
        var node = self.memory.word(script +% head_at) orelse return .{ .reason = self.limited("GDScriptMembersUnreadable") };
        var out = Members{};
        var list: std.ArrayList(Member) = .empty;
        while (node != 0) {
            if (list.items.len == max_members) {
                out.reason = "GDScriptMemberLimit";
                break;
            }
            if (node % 8 != 0 or !self.memory.read(node, bytes[0..span])) {
                out.reason = self.limited("GDScriptMembersUnreadable");
                break;
            }
            const index = std.mem.readInt(i32, bytes[index_at..][0..4], .little);
            if (index >= 0) try list.append(self.a, .{ .name = u64At(&bytes, key_at), .index = @intCast(index) });
            node = u64At(&bytes, next_at);
        }
        out.names = list.items;
        out.values = self.cow(self.memory.word(instance +% values_at) orelse 0);
        if (out.reason == null) out.reason = out.values.reason;
        return out;
    }
    fn member(self: *Reader, found: *const Members, index: u32) ?Slot {
        if (index >= found.values.count) return null;
        var slot = Slot{ .raw = undefined, .address = found.values.ptr +% @as(u64, index) * 24 };
        return if (self.memory.read(slot.address.?, &slot.raw)) slot else null;
    }
    /// Children `start..start+limit` of a container or of an object's script.
    pub fn expand(self: *Reader, raw: *const Raw, start: u64, limit: usize, inner: bool) anyerror!Expanded {
        const kind = self.kindOf(raw) orelse return .{};
        var list: std.ArrayList(named.Child) = .empty;
        var out = Expanded{};
        switch (kind) {
            .dictionary => {
                const found = self.dictionary(raw);
                out = .{ .count = found.count, .reason = found.reason };
                var node = found.ptr;
                var index: u64 = 0;
                self.why = null;
                while (index < found.count and index < start + limit and index < max_scan) : (index += 1) {
                    const next = self.pair(&node) orelse break;
                    if (index < start) continue;
                    const key = try self.show(&next.key, false);
                    try list.append(self.a, try self.child(key.display, next.value, inner));
                }
                if (self.why) |why| out.reason = why;
            },
            .object => {
                const found = try self.object(raw);
                if (found.instance == 0) return .{};
                const all = try self.members(found.instance);
                out = .{ .count = all.names.len, .reason = all.reason };
                var index = start;
                while (index < all.names.len and index < start + limit) : (index += 1) {
                    const item = all.names[@intCast(index)];
                    const key = try self.name(item.name);
                    if (self.member(&all, item.index)) |slot| try list.append(self.a, try self.child(key, slot, inner)) else try list.append(self.a, .{ .key = key, .type = "unavailable", .display = "unavailable", .address = null, .diagnostic = self.limited("GDScriptMemberUnreadable"), .advisory = false });
                }
            },
            .array => {
                const span = self.vector(raw, .array_ptr, "GDScriptArrayLayoutUnavailable");
                out = .{ .count = span.count, .reason = span.reason };
                const n: usize = @intCast(@min(span.count -| start, limit));
                if (n == 0) return out;
                const bytes = try self.a.alloc(u8, n * 24);
                if (!self.memory.read(span.ptr +% start * 24, bytes)) {
                    out.reason = self.limited("GDScriptContainerUnreadable");
                    return out;
                }
                for (0..n) |i| try list.append(self.a, try self.child(try std.fmt.allocPrint(self.a, "{d}", .{start + i}), .{ .raw = bytes[i * 24 ..][0..24].*, .address = span.ptr +% (start + i) * 24 }, inner));
            },
            else => {
                const each = packedElement(kind) orelse return .{};
                const span = self.vector(raw, .packed_ptr, "GDScriptPackedArrayLayoutUnavailable");
                out = .{ .count = span.count, .reason = span.reason };
                const n: usize = @intCast(@min(span.count -| start, limit));
                if (n == 0) return out;
                const bytes = try self.a.alloc(u8, n * each[0]);
                if (!self.memory.read(span.ptr +% start * each[0], bytes)) {
                    out.reason = self.limited("GDScriptContainerUnreadable");
                    return out;
                }
                for (0..n) |i| {
                    const made = self.element(each[1], bytes[i * each[0] ..][0..each[0]]) orelse continue;
                    try list.append(self.a, try self.child(try std.fmt.allocPrint(self.a, "{d}", .{start + i}), .{ .raw = made, .address = span.ptr +% (start + i) * each[0] }, false));
                }
            },
        }
        out.children = list.items;
        return out;
    }
    /// A value with its first children: a container's line also shows its
    /// first elements.
    pub fn describe(self: *Reader, raw: *const Raw, limit: usize) !Described {
        var shown = try self.show(raw, true);
        const kind = self.kindOf(raw) orelse return .{ .shown = shown };
        const container = kind == .array or kind == .dictionary or packedElement(kind) != null;
        if ((!container and kind != .object) or shown.reason != null or (container and shown.count == 0)) return .{ .shown = shown };
        const found = try self.expand(raw, 0, @max(limit, inline_items), true);
        if (kind == .object) {
            shown.count = if (found.children.len != 0 or found.reason != null) found.count else null;
        } else {
            var out = Out{ .a = self.a };
            try out.add(shown.display);
            try out.add(" ");
            if (try bracket(&out, kind == .dictionary, found.children, found.count, inline_items)) shown.truncated = true;
            shown.display = out.list.items;
        }
        if (shown.reason == null) shown.reason = found.reason;
        if (found.count > limit) shown.truncated = true;
        return .{ .shown = shown, .children = found.children[0..@min(found.children.len, limit)] };
    }
    fn textIs(self: *Reader, raw: *const Raw, kind: Kind, want: []const u8) !bool {
        const at = u64At(self.data(raw), 0);
        const text = if (kind == .string) try gd.stringCut(self.memory, self.a, at, @min(want.len + 1, gd.max_chars)) else try gd.nameData(self.memory, self.a, self.layout, at);
        return text.reason == null and !text.truncated and std.mem.eql(u8, text.text, want);
    }
    /// One step of a path from a value. Null with `self.why` when the value
    /// has no such element.
    pub fn select(self: *Reader, from: Slot, step: Step) anyerror!?Slot {
        self.why = null;
        const kind = self.kindOf(&from.raw) orelse {
            self.why = "GDScriptVariantTypeUnknown";
            return null;
        };
        const key: ?[]const u8 = switch (step) {
            .key, .attr => |text| text,
            .index => null,
        };
        switch (kind) {
            .dictionary => {
                const found = self.dictionary(&from.raw);
                if (found.reason) |why| {
                    self.why = why;
                    return null;
                }
                var node = found.ptr;
                var index: u64 = 0;
                while (index < found.count) : (index += 1) {
                    if (index == max_scan) {
                        self.why = "GDScriptDictionaryScanLimit";
                        return null;
                    }
                    const next = self.pair(&node) orelse break;
                    const key_kind = self.kindOf(&next.key) orelse continue;
                    const bytes = self.data(&next.key);
                    const equal = if (key) |text|
                        (key_kind == .string or key_kind == .string_name) and try self.textIs(&next.key, key_kind, text)
                    else if (key_kind == .int)
                        @as(i64, @bitCast(u64At(bytes, 0))) == step.index
                    else
                        key_kind == .float and @as(f64, @bitCast(u64At(bytes, 0))) == @as(f64, @floatFromInt(step.index));
                    if (equal) return next.value;
                }
                if (self.why == null) self.why = "GDScriptKeyNotFound";
                return null;
            },
            .object => {
                const text = key orelse {
                    self.why = "GDScriptPathNotIndexable";
                    return null;
                };
                const found = try self.object(&from.raw);
                if (found.state != .live or found.instance == 0) {
                    self.why = switch (found.state) {
                        .live => "GDScriptObjectHasNoScript",
                        .null => "GDScriptObjectNull",
                        .freed => "GDScriptObjectFreed",
                        else => "GDScriptObjectUnreadable",
                    };
                    return null;
                }
                const all = try self.members(found.instance);
                for (all.names) |item| {
                    const have = try gd.nameData(self.memory, self.a, self.layout, item.name);
                    if (have.reason != null or !std.mem.eql(u8, have.text, text)) continue;
                    if (self.member(&all, item.index)) |slot| return slot;
                    self.why = self.limited("GDScriptMemberUnreadable");
                    return null;
                }
                self.why = all.reason orelse "GDScriptMemberNotFound";
                return null;
            },
            .array => {
                const span = self.vector(&from.raw, .array_ptr, "GDScriptArrayLayoutUnavailable");
                const index = self.position(span, step) orelse return null;
                var slot = Slot{ .raw = undefined, .address = span.ptr +% index * 24 };
                if (self.memory.read(slot.address.?, &slot.raw)) return slot;
                self.why = self.limited("GDScriptContainerUnreadable");
                return null;
            },
            else => {
                if (packedElement(kind)) |each| {
                    const span = self.vector(&from.raw, .packed_ptr, "GDScriptPackedArrayLayoutUnavailable");
                    const index = self.position(span, step) orelse return null;
                    var bytes: [16]u8 = undefined;
                    const made = if (self.memory.read(span.ptr +% index * each[0], bytes[0..each[0]])) self.element(each[1], bytes[0..each[0]]) else null;
                    if (made) |raw| return .{ .raw = raw, .address = span.ptr +% index * each[0] };
                    self.why = self.limited("GDScriptContainerUnreadable");
                    return null;
                }
                if (key) |text| {
                    for (components(kind)) |part| {
                        if (!std.mem.eql(u8, part.name, text)) continue;
                        const width: usize = if (part.kind == .vector2 or part.kind == .vector2i) 8 else 4;
                        const bytes = self.data(&from.raw)[part.at..][0..width];
                        if (self.element(part.kind, bytes)) |raw| return .{ .raw = raw, .address = if (from.address) |at| at +% self.off(.variant_data).? + part.at else null };
                    }
                }
                self.why = "GDScriptPathNotContainer";
                return null;
            },
        }
    }
    /// An index into `span`, negative from the end as in GDScript.
    fn position(self: *Reader, span: Span, step: Step) ?u64 {
        if (span.reason) |why| {
            self.why = why;
            return null;
        }
        if (step != .index) {
            self.why = "GDScriptPathNeedsIndex";
            return null;
        }
        const index = if (step.index < 0) step.index + @as(i64, @intCast(span.count)) else step.index;
        if (index < 0 or @as(u64, @intCast(index)) >= span.count) {
            self.why = "GDScriptIndexOutOfRange";
            return null;
        }
        return @intCast(index);
    }
};

pub const Step = union(enum) { index: i64, key: []const u8, attr: []const u8 };
pub const Path = struct { root: []const u8, steps: [max_path_steps]Step = undefined, count: usize = 0 };
fn identifier(text: []const u8, from: usize) usize {
    var at = from;
    while (at < text.len and (std.ascii.isAlphanumeric(text[at]) or text[at] == '_' or text[at] >= 0x80)) at += 1;
    return if (at > from and !std.ascii.isDigit(text[from])) at else from;
}
/// `name`, then up to eight `.member`, `[integer]` or `["text"]` steps.
pub fn parse(text: []const u8) error{GDScriptExpressionUnsupported}!Path {
    var at = identifier(text, 0);
    if (at == 0) return error.GDScriptExpressionUnsupported;
    var path = Path{ .root = text[0..at] };
    while (at < text.len) {
        if (path.count == max_path_steps) return error.GDScriptExpressionUnsupported;
        if (text[at] == '.') {
            const end = identifier(text, at + 1);
            if (end == at + 1) return error.GDScriptExpressionUnsupported;
            path.steps[path.count] = .{ .attr = text[at + 1 .. end] };
            at = end;
        } else if (text[at] == '[') {
            at += 1;
            if (at < text.len and (text[at] == '"' or text[at] == '\'')) {
                const end = std.mem.indexOfScalarPos(u8, text, at + 1, text[at]) orelse return error.GDScriptExpressionUnsupported;
                if (std.mem.indexOfScalar(u8, text[at + 1 .. end], '\\') != null) return error.GDScriptExpressionUnsupported;
                path.steps[path.count] = .{ .key = text[at + 1 .. end] };
                at = end + 1;
            } else {
                const end = std.mem.indexOfScalarPos(u8, text, at, ']') orelse return error.GDScriptExpressionUnsupported;
                path.steps[path.count] = .{ .index = std.fmt.parseInt(i64, text[at..end], 10) catch return error.GDScriptExpressionUnsupported };
                at = end;
            }
            if (at >= text.len or text[at] != ']') return error.GDScriptExpressionUnsupported;
            at += 1;
        } else return error.GDScriptExpressionUnsupported;
        path.count += 1;
    }
    return path;
}

pub const Scope = enum { parameter, local, context, member };
pub const Binding = struct {
    /// Decoded, or the interned name still to decode.
    name: []const u8 = "",
    name_data: u64 = 0,
    scope: Scope,
    slot: Slot,
};
pub const Level = struct { call_level: u64, function: u64, line: ?u32 };
pub const Frame = struct {
    bindings: []Binding = &.{},
    diagnostic: ?[]const u8 = null,
};
const Live = struct { name: u64, positions: std.ArrayList(u32) = .empty };
/// The names in scope at `line`, replayed from the function's debug records
/// by the engine's own rule: stop at the first record at or past the line; a
/// record adds a name at a stack slot or ends its block.
fn replay(r: *Reader, function: u64, line: u32) !?[]Live {
    const list_at = r.off(.function_stack_debug) orelse return null;
    const first_at = r.off(.list_first) orelse return null;
    const value_at = r.off(.element_value) orelse return null;
    const next_at = r.off(.element_next) orelse return null;
    const fields = [_]?u32{ r.off(.debug_line), r.off(.debug_pos), r.off(.debug_added), r.off(.debug_identifier) };
    for (fields) |field| if (field == null) return null;
    var bytes: [128]u8 = undefined;
    const span = @max(value_at + r.size(.stack_debug), next_at + 8);
    if (r.size(.stack_debug) < 16 or span > bytes.len) return null;
    const data = r.memory.word(function +% list_at) orelse return null;
    // The engine keeps no list at all when it does not track locals.
    if (data == 0) return null;
    var node = r.memory.word(data +% first_at) orelse return null;
    var live: std.ArrayList(Live) = .empty;
    var seen: usize = 0;
    while (node != 0 and seen < max_debug) : (seen += 1) {
        if (node % 8 != 0 or !r.memory.read(node, bytes[0..span])) return null;
        const record = bytes[value_at..];
        if (@as(i64, std.mem.readInt(i32, record[fields[0].?..][0..4], .little)) >= @as(i64, line)) break;
        const pos = std.mem.readInt(i32, record[fields[1].?..][0..4], .little);
        const id = u64At(record, fields[3].?);
        const index = for (live.items, 0..) |item, i| {
            if (item.name == id) break i;
        } else null;
        if (record[fields[2].?] != 0) {
            if (pos < 0 or pos >= max_slots) return null;
            if (index) |i| try live.items[i].positions.append(r.a, @intCast(pos)) else {
                try live.append(r.a, .{ .name = id });
                try live.items[live.items.len - 1].positions.append(r.a, @intCast(pos));
            }
        } else if (index) |i| {
            _ = live.items[i].positions.pop();
            if (live.items[i].positions.items.len == 0) _ = live.orderedRemove(i);
        }
        node = u64At(&bytes, next_at);
    }
    return live.items;
}
/// Parameters, locals, `self` and its members of one call level, in that
/// order. Local names exist only when the engine recorded them; parameter
/// names are also in the function's own signature.
pub fn frame(r: *Reader, level: Level) !Frame {
    const layout = r.layout;
    if (usable(layout) != null) return error.GDScriptValueLayoutUnavailable;
    const count_at = r.off(.function_argument_count) orelse return error.GDScriptFunctionLayoutUnavailable;
    const size_at = r.off(.function_stack_size) orelse return error.GDScriptFunctionLayoutUnavailable;
    var record: [256]u8 = undefined;
    if (layout.level_size > record.len or level.call_level % 8 != 0 or !r.memory.read(level.call_level, record[0..layout.level_size])) return error.StaleLanguageFrame;
    // The record must still be the one the stack showed.
    if (u64At(&record, layout.at(.level_function)) != level.function) return error.StaleLanguageFrame;
    const stack = u64At(&record, layout.at(.level_stack));
    const instance = u64At(&record, layout.at(.level_instance));
    var counts: [2][4]u8 = undefined;
    if (!r.memory.read(level.function +% count_at, &counts[0]) or !r.memory.read(level.function +% size_at, &counts[1])) return error.GDScriptFunctionUnreadable;
    const arguments = std.mem.readInt(i32, &counts[0], .little);
    const size = std.mem.readInt(i32, &counts[1], .little);
    // Slots 0..2 are self, the class and nil; the arguments follow.
    if (arguments < 0 or size < 3 or size > 1 << 20 or arguments > size - 3) return error.GDScriptFunctionInvalid;
    if (stack == 0 or stack % 8 != 0) return error.GDScriptStackUnreadable;
    const slots: usize = @intCast(@min(size, max_slots));
    const bytes = try r.a.alloc(u8, slots * 24);
    if (!r.memory.read(stack, bytes)) return error.GDScriptStackUnreadable;
    var out = Frame{};
    var list: std.ArrayList(Binding) = .empty;
    const first: usize = 3;
    const last = first + @as(usize, @intCast(arguments));
    const live = if (level.line) |line| try replay(r, level.function, line) else null;
    if (live) |names| {
        for (names) |item| {
            const pos = item.positions.items[item.positions.items.len - 1];
            if (pos >= slots) continue;
            try list.append(r.a, .{ .name_data = item.name, .scope = if (pos >= first and pos < last) .parameter else .local, .slot = .{ .raw = bytes[pos * 24 ..][0..24].*, .address = stack +% pos * 24 } });
        }
    } else {
        out.diagnostic = if (level.line == null) "GDScriptLineUnavailable" else "GDScriptLocalNamesNotTracked";
        // The signature names the parameters when it has one name each.
        var names: Span = .{};
        if (r.off(.function_arguments)) |at| names = r.cow(r.memory.word(level.function +% at) orelse 0);
        const stride = r.size(.property);
        const named_arguments = names.reason == null and names.count == @as(u64, @intCast(arguments)) and stride != 0 and r.off(.property_name) != null;
        for (first..@min(slots, @as(usize, @intCast(size)))) |pos| {
            const slot = Slot{ .raw = bytes[pos * 24 ..][0..24].*, .address = stack +% pos * 24 };
            if (pos < last) {
                var text: []const u8 = try std.fmt.allocPrint(r.a, "arg{d}", .{pos - first});
                if (named_arguments) {
                    if (r.memory.word(names.ptr +% (pos - first) * stride +% r.off(.property_name).? +% layout.at(.string_data))) |chars| {
                        const have = try gd.stringCut(r.memory, r.a, chars, 128);
                        if (have.reason == null and have.text.len != 0) text = have.text;
                    }
                }
                try list.append(r.a, .{ .name = text, .scope = .parameter, .slot = slot });
            } else if (r.kindOf(&slot.raw) != .nil) {
                // A local or a temporary: the engine did not keep which.
                try list.append(r.a, .{ .name = try std.fmt.allocPrint(r.a, "stack[{d}]", .{pos}), .scope = .local, .slot = slot });
            }
        }
    }
    if (instance != 0 and instance % 8 == 0) {
        try list.append(r.a, .{ .name = "self", .scope = .context, .slot = .{ .raw = bytes[0..24].*, .address = stack } });
        const all = try r.members(instance);
        if (out.diagnostic == null) out.diagnostic = all.reason;
        // A script with more members than are listed still shows the first.
        const held: usize = @intCast(@min(all.values.count, max_members));
        if (held != 0) {
            const values = try r.a.alloc(u8, held * 24);
            if (r.memory.read(all.values.ptr, values)) {
                for (all.names) |item| {
                    if (item.index >= held) continue;
                    try list.append(r.a, .{ .name_data = item.name, .scope = .member, .slot = .{ .raw = values[@as(usize, item.index) * 24 ..][0..24].*, .address = all.values.ptr +% @as(u64, item.index) * 24 } });
                }
            } else if (out.diagnostic == null) out.diagnostic = r.limited("GDScriptMembersUnreadable");
        }
    }
    out.bindings = list.items;
    return out;
}
pub fn bindingName(r: *Reader, binding: *const Binding) ![]const u8 {
    return if (binding.name.len != 0) binding.name else r.name(binding.name_data);
}
/// The value an expression names in a level: a local or parameter (the
/// innermost declaration wins), `self`, or a member; then each path step.
pub fn resolve(r: *Reader, found: *const Frame, path: *const Path) !?struct { slot: Slot, scope: Scope } {
    r.why = "GDScriptNameNotFound";
    var chosen: ?*const Binding = null;
    for (found.bindings) |*binding| {
        // Locals shadow members; a later local of the same name shadows an earlier one.
        if (chosen != null and binding.scope == .member) continue;
        if (std.mem.eql(u8, try bindingName(r, binding), path.root)) chosen = binding;
    }
    const root = chosen orelse return null;
    var slot = root.slot;
    for (path.steps[0..path.count]) |step| slot = try r.select(slot, step) orelse return null;
    r.why = null;
    return .{ .slot = slot, .scope = root.scope };
}

// ---- tests: synthetic memory only ----
const testing = std.testing;
const Fake = struct {
    base: u64 = 0x10000,
    bytes: []u8,
    next: u64 = 0x10100,
    fn read(context: *anyopaque, address: u64, out: []u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (address < self.base or address - self.base > self.bytes.len or self.bytes.len - (address - self.base) < out.len) return false;
        @memcpy(out, self.bytes[@intCast(address - self.base)..][0..out.len]);
        return true;
    }
    fn at(self: *Fake, address: u64, n: usize) []u8 {
        return self.bytes[@intCast(address - self.base)..][0..n];
    }
    fn put(self: *Fake, address: u64, value: u64) void {
        std.mem.writeInt(u64, self.at(address, 8)[0..8], value, .little);
    }
    fn put32(self: *Fake, address: u64, value: u32) void {
        std.mem.writeInt(u32, self.at(address, 4)[0..4], value, .little);
    }
    /// `n` zero bytes behind a 16-byte CowData header that counts `count`.
    fn alloc(self: *Fake, n: usize, count: u64) u64 {
        const ptr = self.next + 16;
        self.next = (ptr + n + 15) & ~@as(u64, 15);
        self.put(ptr - 16, 1);
        self.put(ptr - 8, count);
        return ptr;
    }
    fn text(self: *Fake, value: []const u8) u64 {
        const ptr = self.alloc((value.len + 1) * 4, value.len + 1);
        for (value, 0..) |byte, i| self.put32(ptr + i * 4, byte);
        return ptr;
    }
    /// A StringName::_Data whose name is `value`.
    fn nameOf(self: *Fake, value: []const u8) u64 {
        const chars = self.text(value);
        const data = self.alloc(40, 0);
        self.put(data + 8, chars);
        return data;
    }
    fn memory(self: *Fake) Memory {
        return .{ .context = self, .readFn = read, .limit = path_reads };
    }
};
/// A template_debug layout: type at 0, data at 8, engine enumerator values.
fn testLayout() Layout {
    var layout = Layout{ .level_size = 48, .offsets = .{ 0, 8, 16, 24, 32, 40, 0, 8, 0xf0, 0x3b8, 8, 0x1b4, 0x1b0, 8, 0, 0, null, null, null }, .block = .{ .below = 0xa30, .size = 0xa28 }, .call_stack = 0xe8, .call_stack_size = 0xe0, .singleton = 0, .units = 1 };
    const offsets = [field_count]u32{ 0, 8, 0, 8, 0x10, 0x20, 0x34, 0, 0x10, 0x28, 0, 4, 8, 0x10, 0, 0, 0x18, 8, 0, 0x10, 0x18, 0x60, 0x70, 0xe0, 0x1e8, 0x150, 0, 0x10, 0x20, 0x38, 0x18, 0, 0, 8, 0xfc, 0x104, 0x170, 0xa0, 0x1e0, 0x48, 0x18 };
    for (offsets, &layout.value_offsets) |offset, *out| out.* = offset;
    layout.value_sizes = .{ 24, 4, 16, 64, 128, 64, 24, 24, 48, 48, 152, 312, 800, 8, 64, 32, 16, 16, 1144, 1088, 112 };
    for (&layout.kinds, 0..) |*kind, i| kind.* = @intCast(i);
    layout.instance_vtable = 0x7000;
    return layout;
}
fn variant(kind: Kind, payload: []const u8) Raw {
    var raw: Raw = @splat(0);
    raw[0] = @intFromEnum(kind);
    @memcpy(raw[8..][0..payload.len], payload);
    return raw;
}
fn word(value: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, value, .little);
    return out;
}
fn floats(comptime n: usize, values: [n]f32) [n * 4]u8 {
    var out: [n * 4]u8 = undefined;
    for (values, 0..) |value, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(value), .little);
    return out;
}
fn ints(comptime n: usize, values: [n]i32) [n * 4]u8 {
    var out: [n * 4]u8 = undefined;
    for (values, 0..) |value, i| std.mem.writeInt(i32, out[i * 4 ..][0..4], value, .little);
    return out;
}
test "scalars, strings and vectors are shown as GDScript writes them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .bytes = try a.alloc(u8, 0x10000) };
    @memset(fake.bytes, 0);
    const layout = testLayout();
    try testing.expect(usable(&layout) == null);
    var memory = fake.memory();
    var r = Reader{ .memory = &memory, .a = a, .layout = &layout };
    const cases = [_]struct { Raw, []const u8, []const u8 }{
        .{ variant(.nil, ""), "Nil", "null" },
        .{ variant(.bool, &.{1}), "bool", "true" },
        .{ variant(.int, &word(@bitCast(@as(i64, -42)))), "int", "-42" },
        .{ variant(.float, &word(@bitCast(@as(f64, 2.5)))), "float", "2.5" },
        .{ variant(.float, &word(@bitCast(@as(f64, 3)))), "float", "3.0" },
        .{ variant(.float, &word(@bitCast(@as(f64, 1e20)))), "float", "1e20" },
        .{ variant(.string, &word(fake.text("gamma"))), "String", "\"gamma\"" },
        .{ variant(.string, &word(0)), "String", "\"\"" },
        .{ variant(.string_name, &word(fake.nameOf("beta_name"))), "StringName", "&\"beta_name\"" },
        .{ variant(.vector2, &floats(2, .{ 3.25, -4.5 })), "Vector2", "(3.25, -4.5)" },
        .{ variant(.vector2i, &ints(2, .{ 7, -9 })), "Vector2i", "(7, -9)" },
        .{ variant(.vector3, &floats(3, .{ 1, 2, 0.5 })), "Vector3", "(1.0, 2.0, 0.5)" },
        .{ variant(.vector4, &floats(4, .{ 1, 2, 3, 4 })), "Vector4", "(1.0, 2.0, 3.0, 4.0)" },
        .{ variant(.rect2, &floats(4, .{ 1, 2, 30, 40 })), "Rect2", "[P: (1.0, 2.0), S: (30.0, 40.0)]" },
        .{ variant(.color, &floats(4, .{ 1, 0.5, 0.25, 1 })), "Color", "(1.0, 0.5, 0.25, 1.0)" },
        .{ variant(.rid, &word(77)), "RID", "RID(77)" },
        .{ variant(.object, ""), "Object", "<null>" },
        .{ variant(.callable, ""), "Callable", "Callable(null)" },
        .{ variant(.array, ""), "Array", "Array(0)" },
    };
    for (cases) |case| {
        const shown = try r.show(&case[0], true);
        try testing.expectEqualStrings(case[1], shown.type);
        try testing.expectEqualStrings(case[2], shown.display);
        try testing.expect(shown.reason == null);
    }
    // A long string is cut and says how long it is; a bad one is refused.
    const long = fake.text("x" ** 300);
    const cut = try r.show(&variant(.string, &word(long)), true);
    try testing.expect(cut.truncated and cut.count.? == 300 and std.mem.endsWith(u8, cut.display, "…\""));
    try testing.expectEqualStrings("GDScriptStringInvalid", (try r.show(&variant(.string, &word(long + 4)), true)).reason.?);
    // A type tag the build does not define, and a build without the types.
    var odd = variant(.nil, "");
    odd[0] = 99;
    try testing.expectEqualStrings("GDScriptVariantTypeUnknown", (try r.show(&odd, true)).reason.?);
    var bare = layout;
    bare.value_sizes[0] = 40;
    try testing.expectEqualStrings("GDScriptValueLayoutUnavailable", usable(&bare).?);
    bare = layout;
    bare.value_offsets[@intFromEnum(F.array_ptr)] = null;
    var r2 = Reader{ .memory = &memory, .a = a, .layout = &bare };
    try testing.expectEqualStrings("GDScriptArrayLayoutUnavailable", (try r2.show(&variant(.array, &word(0x10800)), true)).reason.?);
    try testing.expectEqualStrings("Node", (try abiName(a, "4Node\x00")).?);
    try testing.expectEqualStrings("Foo::Bar", (try abiName(a, "N3Foo3BarE\x00")).?);
    try testing.expect(try abiName(a, "3RefI4NodeE\x00") == null and try abiName(a, "9Node\x00") == null and try abiName(a, "") == null);
}
/// An Array of `items` and a Dictionary of `pairs` in `fake`.
fn arrayOf(fake: *Fake, items: []const Raw) Raw {
    const data = fake.alloc(items.len * 24, items.len);
    for (items, 0..) |item, i| @memcpy(fake.at(data + i * 24, 24), &item);
    const private = fake.alloc(64, 0);
    fake.put(private + 0x10, data);
    return variant(.array, &word(private));
}
fn dictionaryOf(fake: *Fake, pairs: []const [2]Raw) Raw {
    const private = fake.alloc(128, 0);
    var previous: u64 = 0;
    for (pairs) |item| {
        const node = fake.alloc(64, 0);
        @memcpy(fake.at(node + 0x10, 24), &item[0]);
        @memcpy(fake.at(node + 0x28, 24), &item[1]);
        if (previous == 0) fake.put(private + 0x20, node) else fake.put(previous, node);
        previous = node;
    }
    fake.put32(private + 0x34, @intCast(pairs.len));
    return variant(.dictionary, &word(private));
}
test "containers show their size and first elements, and paths step into them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .bytes = try a.alloc(u8, 0x20000) };
    @memset(fake.bytes, 0);
    const layout = testLayout();
    var memory = fake.memory();
    var r = Reader{ .memory = &memory, .a = a, .layout = &layout };
    const inner = arrayOf(&fake, &.{ variant(.int, &word(1)), variant(.int, &word(2)) });
    const sword = dictionaryOf(&fake, &.{.{ variant(.string, &word(fake.text("damage"))), variant(.int, &word(12)) }});
    const inventory = dictionaryOf(&fake, &.{
        .{ variant(.string, &word(fake.text("sword"))), sword },
        .{ variant(.string_name, &word(fake.nameOf("coins"))), inner },
        .{ variant(.int, &word(7)), variant(.float, &word(@bitCast(@as(f64, 2.5)))) },
    });
    const described = try r.describe(&inventory, row_children);
    try testing.expectEqualStrings("Dictionary(3) {\"sword\": Dictionary(1) {\"damage\": 12}, &\"coins\": Array(2) [1, 2], 7: 2.5}", described.shown.display);
    try testing.expect(described.shown.count.? == 3 and described.children.len == 3 and !described.shown.truncated);
    try testing.expectEqualStrings("&\"coins\"", described.children[1].key);
    try testing.expectEqualStrings("Array(2) [1, 2]", described.children[1].display);
    const from = Slot{ .raw = inventory };
    const path = try parse("inventory[\"sword\"].damage");
    try testing.expect(path.count == 2 and std.mem.eql(u8, path.root, "inventory"));
    var slot = (try r.select(from, path.steps[0])).?;
    slot = (try r.select(slot, path.steps[1])).?;
    try testing.expectEqualStrings("12", (try r.show(&slot.raw, true)).display);
    // A StringName key answers a text key; an int key an index; a float key too.
    slot = (try r.select(from, .{ .attr = "coins" })).?;
    try testing.expectEqualStrings("Array(2) [1, 2]", (try r.describe(&slot.raw, 4)).shown.display);
    try testing.expectEqualStrings("2", (try r.show(&(try r.select(slot, .{ .index = -1 })).?.raw, true)).display);
    try testing.expectEqualStrings("2.5", (try r.show(&(try r.select(from, .{ .index = 7 })).?.raw, true)).display);
    try testing.expect(try r.select(slot, .{ .index = 2 }) == null);
    try testing.expectEqualStrings("GDScriptIndexOutOfRange", r.why.?);
    try testing.expect(try r.select(from, .{ .key = "shield" }) == null);
    try testing.expectEqualStrings("GDScriptKeyNotFound", r.why.?);
    try testing.expect(try r.select(.{ .raw = variant(.int, &word(1)) }, .{ .index = 0 }) == null);
    try testing.expectEqualStrings("GDScriptPathNotContainer", r.why.?);
    // Components of a vector, and elements of a packed array.
    const position = Slot{ .raw = variant(.vector2, &floats(2, .{ 3.25, -4.5 })), .address = 0x500 };
    const y = (try r.select(position, .{ .attr = "y" })).?;
    try testing.expectEqualStrings("-4.5", (try r.show(&y.raw, true)).display);
    try testing.expectEqual(@as(?u64, 0x500 + 8 + 4), y.address);
    const packed_data = fake.alloc(12, 3);
    for ([_]u32{ 10, 20, @bitCast(@as(i32, -30)) }, 0..) |value, i| fake.put32(packed_data + i * 4, value);
    const packed_ref = fake.alloc(32, 0);
    fake.put(packed_ref + 0x18, packed_data);
    const numbers = variant(.packed_int32_array, &word(packed_ref));
    try testing.expectEqualStrings("PackedInt32Array(3) [10, 20, -30]", (try r.describe(&numbers, 4)).shown.display);
    try testing.expectEqualStrings("-30", (try r.show(&(try r.select(.{ .raw = numbers }, .{ .index = 2 })).?.raw, true)).display);
    // More elements than one line shows, and paging past them.
    var many: [20]Raw = undefined;
    for (&many, 0..) |*item, i| item.* = variant(.int, &word(i));
    const big = arrayOf(&fake, &many);
    const cut = try r.describe(&big, row_children);
    try testing.expectEqualStrings("Array(20) [0, 1, 2, 3, 4, 5, 6, 7, …]", cut.shown.display);
    try testing.expect(cut.shown.truncated and cut.children.len == row_children and cut.shown.count.? == 20);
    const page = try r.expand(&big, 16, 8, false);
    try testing.expect(page.children.len == 4 and std.mem.eql(u8, page.children[3].key, "19") and std.mem.eql(u8, page.children[3].display, "19"));
    // A count the storage does not back, a cycle of pairs, and the read bound.
    const liar = fake.alloc(64, 0);
    fake.put(liar + 0x10, 0x9000000);
    try testing.expectEqualStrings("GDScriptContainerUnreadable", (try r.show(&variant(.array, &word(liar)), true)).reason.?);
    const ring = dictionaryOf(&fake, &.{.{ variant(.int, &word(1)), variant(.int, &word(1)) }});
    const ring_private = u64At(&ring, 8);
    fake.put(u64At(fake.at(ring_private + 0x20, 8), 0), u64At(fake.at(ring_private + 0x20, 8), 0));
    fake.put32(ring_private + 0x34, 0xffffffff);
    const before = memory.reads;
    try testing.expect(try r.select(.{ .raw = ring }, .{ .key = "none" }) == null);
    try testing.expectEqualStrings("GDScriptDictionaryScanLimit", r.why.?);
    try testing.expect(memory.reads - before <= max_scan + 4);
    try testing.expectEqual(row_children, (try r.describe(&ring, row_children)).children.len);
    memory.limit = memory.reads;
    try testing.expectEqualStrings("GDScriptReadLimit", (try r.show(&big, true)).reason.?);
}
test "expressions are a name and bounded steps" {
    const path = try parse("items[2].name[\"a b\"]['c'][-1]");
    try testing.expect(path.count == 5 and path.steps[0].index == 2 and std.mem.eql(u8, path.steps[1].attr, "name") and std.mem.eql(u8, path.steps[2].key, "a b") and std.mem.eql(u8, path.steps[3].key, "c") and path.steps[4].index == -1);
    try testing.expect((try parse("self")).count == 0);
    for ([_][]const u8{ "", "1a", "a.", "a[", "a[]", "a[1", "a[\"x]", "a b", "a+1", "a.b()", "a[1.5]", "a[\"\\\"\"]", "a.b.c.d.e.f.g.h.i.j" }) |bad| try testing.expectError(error.GDScriptExpressionUnsupported, parse(bad));
}
test "a level's names follow the engine's replay rule; members come from the script" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .bytes = try a.alloc(u8, 0x20000) };
    @memset(fake.bytes, 0);
    const layout = testLayout();
    var memory = fake.memory();
    var r = Reader{ .memory = &memory, .a = a, .layout = &layout };
    // An instance with members hp (index 1) and tag (index 0) of one script.
    const script = fake.alloc(1088, 0);
    const instance = fake.alloc(112, 0);
    fake.put(instance, 0x7000);
    fake.put(instance + 0x18, script);
    const values = fake.alloc(48, 2);
    @memcpy(fake.at(values, 24), &variant(.string, &word(fake.text("hero"))));
    @memcpy(fake.at(values + 24, 24), &variant(.int, &word(90)));
    fake.put(instance + 0x48, values);
    var previous: u64 = 0;
    for ([_]struct { []const u8, u32 }{ .{ "hp", 1 }, .{ "tag", 0 } }) |item| {
        const node = fake.alloc(152, 0);
        fake.put(node + 0x10, fake.nameOf(item[0]));
        fake.put32(node + 0x18, item[1]);
        if (previous == 0) fake.put(script + 0x1e0, node) else fake.put(previous, node);
        previous = node;
    }
    // The owner object, which points back at the instance.
    const owner = fake.alloc(800, 0);
    fake.put(owner + 0x60, 1234);
    fake.put(owner + 0x70, instance);
    // A function with two arguments and two locals; `i` lives in a block
    // that ends at line 30, and a second `i` is declared at line 40.
    const function = fake.alloc(1144, 0);
    fake.put32(function + 0xfc, 2);
    fake.put32(function + 0x104, 8);
    const list = fake.alloc(24, 0);
    fake.put(function + 0x170, list);
    previous = 0;
    const amount = fake.nameOf("amount");
    const records = [_]struct { i32, i32, bool, u64 }{ .{ 10, 3, true, amount }, .{ 10, 4, true, fake.nameOf("who") }, .{ 12, 5, true, fake.nameOf("total") }, .{ 20, 6, true, fake.nameOf("i") }, .{ 30, 6, false, 0 }, .{ 40, 7, true, 0 } };
    var loop_name: u64 = 0;
    for (records, 0..) |item, i| {
        const node = fake.alloc(48, 0);
        fake.put32(node, @bitCast(item[0]));
        fake.put32(node + 4, @bitCast(item[1]));
        fake.at(node + 8, 1)[0] = @intFromBool(item[2]);
        if (i == 3) loop_name = item[3];
        fake.put(node + 0x10, if (item[3] != 0) item[3] else loop_name);
        if (previous == 0) fake.put(list, node) else fake.put(previous + 0x18, node);
        previous = node;
    }
    const stack = fake.alloc(8 * 24, 0);
    var self_value = variant(.object, &word(1234));
    std.mem.writeInt(u64, self_value[16..24], owner, .little);
    @memcpy(fake.at(stack, 24), &self_value);
    for ([_]u64{ 5, 6, 11, 100, 200 }, 3..) |value, pos| @memcpy(fake.at(stack + pos * 24, 24), &variant(.int, &word(value)));
    const level = fake.alloc(48, 0);
    fake.put(level, stack);
    fake.put(level + 8, function);
    fake.put(level + 16, instance);
    const expect = [_]struct { u32, []const []const u8 }{
        .{ 11, &.{ "amount", "who", "self", "hp", "tag" } },
        .{ 13, &.{ "amount", "who", "total", "self", "hp", "tag" } },
        .{ 25, &.{ "amount", "who", "total", "i", "self", "hp", "tag" } },
        .{ 35, &.{ "amount", "who", "total", "self", "hp", "tag" } },
        .{ 45, &.{ "amount", "who", "total", "i", "self", "hp", "tag" } },
    };
    for (expect) |case| {
        const found = try frame(&r, .{ .call_level = level, .function = function, .line = case[0] });
        try testing.expect(found.diagnostic == null);
        try testing.expectEqual(case[1].len, found.bindings.len);
        for (found.bindings, case[1]) |*binding, want| try testing.expectEqualStrings(want, try bindingName(&r, binding));
    }
    const found = try frame(&r, .{ .call_level = level, .function = function, .line = 45 });
    try testing.expect(found.bindings[0].scope == .parameter and found.bindings[2].scope == .local and found.bindings[4].scope == .context and found.bindings[5].scope == .member);
    // The second `i` is slot 7, the member hp is values[1], self.tag steps through the object.
    try testing.expectEqualStrings("200", (try r.show(&(try resolve(&r, &found, &try parse("i"))).?.slot.raw, true)).display);
    try testing.expectEqualStrings("90", (try r.show(&(try resolve(&r, &found, &try parse("hp"))).?.slot.raw, true)).display);
    try testing.expectEqualStrings("\"hero\"", (try r.show(&(try resolve(&r, &found, &try parse("self.tag"))).?.slot.raw, true)).display);
    try testing.expect(try resolve(&r, &found, &try parse("nothing")) == null);
    try testing.expectEqualStrings("GDScriptNameNotFound", r.why.?);
    try testing.expect(try resolve(&r, &found, &try parse("self.nothing")) == null);
    try testing.expectEqualStrings("GDScriptMemberNotFound", r.why.?);
    const self_shown = try r.describe(&found.bindings[4].slot.raw, row_children);
    try testing.expectEqualStrings("<Object#1234>", self_shown.shown.display);
    try testing.expect(self_shown.children.len == 2 and std.mem.eql(u8, self_shown.children[0].key, "hp") and std.mem.eql(u8, self_shown.children[0].display, "90"));
    // An object whose memory no longer carries the id is not described.
    fake.put(owner + 0x60, 99);
    try testing.expectEqualStrings("GDScriptObjectFreed", (try r.show(&self_value, true)).reason.?);
    fake.put(owner + 0x60, 1234);
    // Without debug records only the values are known: arguments by
    // position, other slots that hold something by their slot.
    fake.put(function + 0x170, 0);
    const unnamed = try frame(&r, .{ .call_level = level, .function = function, .line = 45 });
    try testing.expectEqualStrings("GDScriptLocalNamesNotTracked", unnamed.diagnostic.?);
    const names = [_][]const u8{ "arg0", "arg1", "stack[5]", "stack[6]", "stack[7]", "self", "hp", "tag" };
    try testing.expectEqual(names.len, unnamed.bindings.len);
    for (unnamed.bindings, names) |*binding, want| try testing.expectEqualStrings(want, try bindingName(&r, binding));
    // The signature names the arguments when it has one name for each.
    const properties = fake.alloc(96, 2);
    fake.put(properties + 8, fake.text("amount"));
    fake.put(properties + 48 + 8, fake.text("who"));
    fake.put(function + 0xa0, properties);
    const signed = try frame(&r, .{ .call_level = level, .function = function, .line = 45 });
    try testing.expectEqualStrings("amount", signed.bindings[0].name);
    try testing.expectEqualStrings("who", signed.bindings[1].name);
    // A record that changed since the stack was read, and impossible counts.
    try testing.expectError(error.StaleLanguageFrame, frame(&r, .{ .call_level = level, .function = function + 8, .line = 1 }));
    fake.put32(function + 0xfc, 9);
    try testing.expectError(error.GDScriptFunctionInvalid, frame(&r, .{ .call_level = level, .function = function, .line = 1 }));
    fake.put32(function + 0xfc, 2);
    fake.put(level, 0);
    try testing.expectError(error.GDScriptStackUnreadable, frame(&r, .{ .call_level = level, .function = function, .line = 1 }));
}
