const std = @import("std");
pub const Kind = enum { signed, unsigned, boolean, float, pointer, array, structure, unknown };
pub const Field = struct { name: []const u8, offset: u64, type: *const Type };
pub const Language = enum { unknown, rust, zig };
pub const Enumerator = struct { name: []const u8, bits: u64 };
pub const Type = struct { name: []const u8, kind: Kind, size: u64, child: ?*const Type = null, count: u64 = 0, fields: []const Field = &.{}, language: Language = .unknown, enumerators: []const Enumerator = &.{}, enumerators_complete: bool = true };
pub fn enumeratorName(value: Value) ?[]const u8 {
    if (value.type.size == 0 or value.type.size > 8) return null;
    const mask: u64 = if (value.type.size == 8) std.math.maxInt(u64) else (@as(u64, 1) << @as(u6, @intCast(value.type.size * 8))) - 1;
    for (value.type.enumerators) |item| if (item.bits & mask == value.bits & mask) return item.name;
    return null;
}
pub const Availability = enum { available, optimized_out, unavailable, unsupported };
pub const Value = struct { type: *const Type, address: ?u64 = null, bits: u64 = 0, availability: Availability = .available, data: ?[]const u8 = null, valid: ?[]const u8 = null };
pub const Context = struct {
    user: *anyopaque,
    lookup: *const fn (*anyopaque, []const u8) anyerror!Value,
    read: *const fn (*anyopaque, u64, []u8) anyerror!usize,
    allocator: std.mem.Allocator,
};
pub const int_type = Type{ .name = "int64", .kind = .signed, .size = 8 };
pub const uint_type = Type{ .name = "uint64", .kind = .unsigned, .size = 8 };
pub const bool_type = Type{ .name = "bool", .kind = .boolean, .size = 1 };
pub const float_type = Type{ .name = "double", .kind = .float, .size = 8 };

pub fn materialize(ctx: Context, value: Value) !Value {
    if (value.availability != .available) return error.ValueUnavailable;
    var v = value;
    if (v.type.kind == .structure or v.type.kind == .array) return v;
    if (v.data) |data| {
        if (v.type.size == 0 or v.type.size > 8) return error.UnsupportedType;
        const size: usize = @intCast(v.type.size);
        if (size > data.len) return error.PartialValue;
        if (v.valid) |valid| {
            if (size > valid.len) return error.PartialValue;
            for (valid[0..size]) |mask| if (mask != 255) return error.PartialValue;
        }
        var bytes: [8]u8 = @splat(0);
        @memcpy(bytes[0..size], data[0..size]);
        v.bits = std.mem.readInt(u64, &bytes, .little);
    } else if (v.address) |address| {
        if (v.type.size == 0 or v.type.size > 8) return error.UnsupportedType;
        var bytes: [8]u8 = @splat(0);
        const size: usize = @intCast(v.type.size);
        if (try ctx.read(ctx.user, address, bytes[0..size]) != size) return error.MemoryUnreadable;
        v.bits = std.mem.readInt(u64, &bytes, .little);
    }
    if (v.type.size == 0 or v.type.size > 8 or v.type.kind == .unknown) return error.UnsupportedType;
    if (v.type.size < 8) {
        const shift: u6 = @intCast(64 - v.type.size * 8);
        v.bits = if (v.type.kind == .signed) @bitCast(@as(i64, @bitCast(v.bits << shift)) >> shift) else (v.bits << shift) >> shift;
    }
    return v;
}
/// Select a child without inventing an address for register/composite values.
pub fn subvalue(v: Value, t: *const Type, offset: u64) !Value {
    if (offset > v.type.size or t.size > v.type.size - offset) return error.InvalidValueLayout;
    if (v.data) |data| {
        const start: usize = @intCast(@min(offset, data.len));
        const end: usize = @intCast(@min(data.len, offset + t.size));
        const validity = if (v.valid) |valid| valid[@min(start, valid.len)..@min(end, valid.len)] else null;
        return .{ .type = t, .availability = v.availability, .data = data[start..end], .valid = validity };
    }
    if (v.address) |address| return .{ .type = t, .availability = v.availability, .address = std.math.add(u64, address, offset) catch return error.InvalidAddress };
    if (v.type.size <= 8 and offset < 8) return .{ .type = t, .availability = v.availability, .bits = v.bits >> @as(u6, @intCast(offset * 8)) };
    return error.PartialValue;
}
pub fn hasMissingBits(v: Value) bool {
    const data = v.data orelse return false;
    if (data.len < v.type.size) return true;
    if (v.valid) |valid| {
        if (valid.len < v.type.size) return true;
        for (valid[0..@intCast(v.type.size)]) |mask| if (mask != 255) return true;
    }
    return false;
}
fn scalar(v: Value) !i128 {
    return switch (v.type.kind) {
        .signed => @as(i64, @bitCast(v.bits)),
        .unsigned, .boolean, .pointer => v.bits,
        else => error.ExpectedInteger,
    };
}
fn floating(v: Value) !f64 {
    if (v.type.kind == .float) return switch (v.type.size) {
        4 => @floatCast(@as(f32, @bitCast(@as(u32, @truncate(v.bits))))),
        8 => @bitCast(v.bits),
        else => error.UnsupportedType,
    };
    return @floatFromInt(try scalar(v));
}
fn integer(value: i128) !Value {
    if (value < std.math.minInt(i64) or value > std.math.maxInt(u64)) return error.IntegerOverflow;
    return .{ .type = if (value > std.math.maxInt(i64)) &uint_type else &int_type, .bits = if (value < 0) @bitCast(@as(i64, @intCast(value))) else @intCast(value) };
}
pub fn evaluate(ctx: Context, source: []const u8) !Value {
    if (source.len == 0 or source.len > 4096) return error.InvalidExpression;
    var parser = Parser{ .ctx = ctx, .source = source };
    const value = try parser.expression(0, 0);
    parser.space();
    if (parser.pos != source.len) return error.InvalidExpression;
    return materialize(ctx, value);
}
const Parser = struct {
    ctx: Context,
    source: []const u8,
    pos: usize = 0,
    fn space(self: *Parser) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) self.pos += 1;
    }
    fn take(self: *Parser, text: []const u8) bool {
        self.space();
        if (std.mem.startsWith(u8, self.source[self.pos..], text)) {
            self.pos += text.len;
            return true;
        }
        return false;
    }
    fn identifier(self: *Parser) ![]const u8 {
        self.space();
        const start = self.pos;
        if (start == self.source.len or !(std.ascii.isAlphabetic(self.source[start]) or self.source[start] == '_' or self.source[start] == '$')) return error.ExpectedIdentifier;
        self.pos += 1;
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
        return self.source[start..self.pos];
    }
    fn pointer(self: *Parser, child: *const Type) !*const Type {
        const t = try self.ctx.allocator.create(Type);
        t.* = .{ .name = "pointer", .kind = .pointer, .size = 8, .child = child };
        return t;
    }
    fn prefix(self: *Parser, depth: u32) anyerror!Value {
        if (depth > 64) return error.ExpressionTooDeep;
        if (self.take("(")) {
            const value = try self.expression(0, depth + 1);
            if (!self.take(")")) return error.MissingParenthesis;
            return value;
        }
        if (self.take("&")) {
            const value = try self.expression(12, depth + 1);
            return .{ .type = try self.pointer(value.type), .bits = value.address orelse return error.NotAddressable };
        }
        if (self.take("*")) {
            const value = try materialize(self.ctx, try self.expression(12, depth + 1));
            if (value.type.kind != .pointer) return error.ExpectedPointer;
            return .{ .type = value.type.child orelse return error.UnsupportedType, .address = value.bits };
        }
        if (self.take("-")) {
            const value = try materialize(self.ctx, try self.expression(12, depth + 1));
            if (value.type.kind == .float) return .{ .type = &float_type, .bits = @bitCast(-(try floating(value))) };
            return integer(-(try scalar(value)));
        }
        if (self.take("+")) return self.expression(12, depth + 1);
        if (self.take("!")) return .{ .type = &bool_type, .bits = @intFromBool(try floating(try materialize(self.ctx, try self.expression(12, depth + 1))) == 0) };
        if (self.take("~")) {
            const value = try materialize(self.ctx, try self.expression(12, depth + 1));
            _ = try scalar(value);
            return .{ .type = &uint_type, .bits = ~value.bits };
        }
        self.space();
        if (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            const start = self.pos;
            while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '.')) self.pos += 1;
            const str = self.source[start..self.pos];
            if (std.mem.indexOfScalar(u8, str, '.') != null) return .{ .type = &float_type, .bits = @bitCast(try std.fmt.parseFloat(f64, str)) };
            const value = try std.fmt.parseInt(u64, str, 0);
            return integer(value);
        }
        const name = try self.identifier();
        if (std.mem.eql(u8, name, "true")) return .{ .type = &bool_type, .bits = 1 };
        if (std.mem.eql(u8, name, "false")) return .{ .type = &bool_type, .bits = 0 };
        return self.ctx.lookup(self.ctx.user, name);
    }
    fn postfix(self: *Parser, value: Value, depth: u32) anyerror!Value {
        var v = value;
        while (true) {
            if (self.take("[")) {
                const subscript = try materialize(self.ctx, try self.expression(0, depth + 1));
                const index = try scalar(subscript);
                if (!self.take("]")) return error.MissingBracket;
                const child = v.type.child orelse return error.ExpectedPointer;
                if (v.type.kind == .array) {
                    if (index < 0 or index >= v.type.count) return error.IndexOutOfBounds;
                    const offset = std.math.mul(u64, @intCast(index), child.size) catch return error.InvalidAddress;
                    v = try subvalue(v, child, offset);
                } else if (v.type.kind == .pointer) {
                    const base = (try materialize(self.ctx, v)).bits;
                    const offset = std.math.mul(i128, index, child.size) catch return error.InvalidAddress;
                    const address = std.math.add(i128, base, offset) catch return error.InvalidAddress;
                    if (address < 0 or address > std.math.maxInt(u64)) return error.InvalidAddress;
                    v = .{ .type = child, .address = @intCast(address) };
                } else return error.ExpectedPointer;
            } else {
                const arrow = self.take("->");
                if (!arrow and !self.take(".")) return v;
                if (arrow) {
                    const ptr = try materialize(self.ctx, v);
                    if (ptr.type.kind != .pointer) return error.ExpectedPointer;
                    v = .{ .type = ptr.type.child orelse return error.UnsupportedType, .address = ptr.bits };
                }
                if (v.type.kind != .structure) return error.ExpectedStructure;
                const name = try self.identifier();
                var found = false;
                for (v.type.fields) |field| if (std.mem.eql(u8, field.name, name)) {
                    v = try subvalue(v, field.type, field.offset);
                    found = true;
                    break;
                };
                if (!found) return error.UnknownField;
            }
        }
    }
    const Operator = struct { text: []const u8, precedence: u8 };
    const operators = [_]Operator{
        .{ .text = "||", .precedence = 1 }, .{ .text = "&&", .precedence = 2 },
        .{ .text = "==", .precedence = 6 }, .{ .text = "!=", .precedence = 6 },
        .{ .text = "<=", .precedence = 7 }, .{ .text = ">=", .precedence = 7 },
        .{ .text = "<<", .precedence = 8 }, .{ .text = ">>", .precedence = 8 },
        .{ .text = "|", .precedence = 3 },  .{ .text = "^", .precedence = 4 },
        .{ .text = "&", .precedence = 5 },  .{ .text = "<", .precedence = 7 },
        .{ .text = ">", .precedence = 7 },  .{ .text = "+", .precedence = 9 },
        .{ .text = "-", .precedence = 9 },  .{ .text = "*", .precedence = 10 },
        .{ .text = "/", .precedence = 10 }, .{ .text = "%", .precedence = 10 },
    };
    fn expression(self: *Parser, minimum: u8, depth: u32) anyerror!Value {
        if (depth > 64) return error.ExpressionTooDeep;
        var left = try self.postfix(try self.prefix(depth + 1), depth + 1);
        while (true) {
            self.space();
            var op: ?Operator = null;
            for (operators) |candidate| if (std.mem.startsWith(u8, self.source[self.pos..], candidate.text)) {
                op = candidate;
                break;
            };
            const selected = op orelse break;
            if (selected.precedence < minimum) break;
            self.pos += selected.text.len;
            // Logical operations are deliberately excluded until lazy evaluation
            // can preserve short-circuit behavior for unreadable target pointers.
            if (std.mem.eql(u8, selected.text, "&&") or std.mem.eql(u8, selected.text, "||")) return error.ShortCircuitNotSupported;
            const right = try self.expression(selected.precedence + 1, depth + 1);
            left = try self.binary(selected.text, try materialize(self.ctx, left), try materialize(self.ctx, right));
        }
        return left;
    }
    fn binary(self: *Parser, op: []const u8, left: Value, right: Value) !Value {
        _ = self;
        if (left.type.kind == .pointer and (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-"))) {
            const scale = (left.type.child orelse return error.UnsupportedType).size;
            if (right.type.kind == .pointer) {
                if (!std.mem.eql(u8, op, "-") or scale == 0 or left.type.child != right.type.child) return error.InvalidPointerOperation;
                return integer(@divTrunc(@as(i128, left.bits) - right.bits, scale));
            }
            const offset = std.math.mul(i128, try scalar(right), scale) catch return error.InvalidAddress;
            const address = if (std.mem.eql(u8, op, "+")) @as(i128, left.bits) + offset else @as(i128, left.bits) - offset;
            if (address < 0 or address > std.math.maxInt(u64)) return error.InvalidAddress;
            return .{ .type = left.type, .bits = @intCast(address) };
        }
        const comparison = std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">=");
        if (left.type.kind == .float or right.type.kind == .float) {
            const l = try floating(left);
            const r = try floating(right);
            if (comparison) return .{ .type = &bool_type, .bits = @intFromBool(compare(op, l, r)) };
            if (std.mem.eql(u8, op, "+")) return .{ .type = &float_type, .bits = @bitCast(l + r) };
            if (std.mem.eql(u8, op, "-")) return .{ .type = &float_type, .bits = @bitCast(l - r) };
            if (std.mem.eql(u8, op, "*")) return .{ .type = &float_type, .bits = @bitCast(l * r) };
            if (std.mem.eql(u8, op, "/")) return .{ .type = &float_type, .bits = @bitCast(l / r) };
            return error.InvalidFloatOperation;
        }
        const l = try scalar(left);
        const r = try scalar(right);
        if (comparison) return .{ .type = &bool_type, .bits = @intFromBool(compare(op, l, r)) };
        if (std.mem.eql(u8, op, "+")) return integer(l + r);
        if (std.mem.eql(u8, op, "-")) return integer(l - r);
        if (std.mem.eql(u8, op, "*")) return integer(std.math.mul(i128, l, r) catch return error.IntegerOverflow);
        if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
            if (r == 0) return error.DivisionByZero;
            return integer(if (op[0] == '/') @divTrunc(l, r) else @rem(l, r));
        }
        if (std.mem.eql(u8, op, "&")) return .{ .type = &uint_type, .bits = left.bits & right.bits };
        if (std.mem.eql(u8, op, "|")) return .{ .type = &uint_type, .bits = left.bits | right.bits };
        if (std.mem.eql(u8, op, "^")) return .{ .type = &uint_type, .bits = left.bits ^ right.bits };
        if (r < 0 or r > 63) return error.InvalidShift;
        const shift: u6 = @intCast(r);
        if (std.mem.eql(u8, op, "<<")) return integer(l << shift);
        if (std.mem.eql(u8, op, ">>")) return integer(l >> shift);
        return error.InvalidOperator;
    }
};
fn compare(op: []const u8, l: anytype, r: @TypeOf(l)) bool {
    if (std.mem.eql(u8, op, "==")) return l == r;
    if (std.mem.eql(u8, op, "!=")) return l != r;
    if (std.mem.eql(u8, op, "<")) return l < r;
    if (std.mem.eql(u8, op, ">")) return l > r;
    if (std.mem.eql(u8, op, "<=")) return l <= r;
    return l >= r;
}
const TestMemory = struct {
    bytes: [32]u8 = @splat(0),
    fn read(ptr: *anyopaque, address: u64, out: []u8) !usize {
        const self: *TestMemory = @ptrCast(@alignCast(ptr));
        if (address < 0x1000 or address - 0x1000 + out.len > self.bytes.len) return error.MemoryUnreadable;
        @memcpy(out, self.bytes[@intCast(address - 0x1000)..][0..out.len]);
        return out.len;
    }
    fn lookup(_: *anyopaque, name: []const u8) !Value {
        if (std.mem.eql(u8, name, "x")) return .{ .type = &int_type, .address = 0x1000 };
        if (std.mem.eql(u8, name, "missing")) return .{ .type = &int_type, .availability = .optimized_out };
        return error.UnknownVariable;
    }
};
test "expression precedence, dereference, pointer arithmetic and explicit failures" {
    var memory = TestMemory{};
    std.mem.writeInt(u64, memory.bytes[0..8], 7, .little);
    std.mem.writeInt(u64, memory.bytes[8..16], 12, .little);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ctx = Context{ .user = &memory, .read = TestMemory.read, .lookup = TestMemory.lookup, .allocator = arena.allocator() };
    try std.testing.expectEqual(@as(u64, 22), (try evaluate(ctx, "x + 3 * 5")).bits);
    try std.testing.expectEqual(@as(u64, 12), (try evaluate(ctx, "*(&x + 1)")).bits);
    try std.testing.expectEqual(@as(u64, 1), (try evaluate(ctx, "x == 7")).bits);
    try std.testing.expectEqual(@as(u64, 4), (try evaluate(ctx, "(3 + 5) >> 1")).bits);
    try std.testing.expectError(error.DivisionByZero, evaluate(ctx, "1 / 0"));
    try std.testing.expectError(error.ValueUnavailable, evaluate(ctx, "missing + 1"));
    try std.testing.expectError(error.InvalidExpression, evaluate(ctx, "x = 3"));
    try std.testing.expectError(error.ShortCircuitNotSupported, evaluate(ctx, "0 && *(&x + 100)"));
}

test "enum names preserve signed narrow bits and unsigned 64-bit constants" {
    const t = Type{ .name = "Mode", .kind = .signed, .size = 2, .enumerators = &.{.{ .name = "negative", .bits = @bitCast(@as(i64, -2)) }} };
    try std.testing.expectEqualStrings("negative", enumeratorName(.{ .type = &t, .bits = 65534 }).?);
    try std.testing.expectEqual(null, enumeratorName(.{ .type = &t, .bits = 7 }));
    const high = Type{ .name = "Flags", .kind = .unsigned, .size = 8, .enumerators = &.{.{ .name = "high", .bits = 0x8000000000000001 }} };
    try std.testing.expectEqualStrings("high", enumeratorName(.{ .type = &high, .bits = 0x8000000000000001 }).?);
}

test "partial aggregates expose available children without invented addresses" {
    const pair = Type{ .name = "pair", .kind = .structure, .size = 16, .fields = &.{ .{ .name = "first", .offset = 0, .type = &uint_type }, .{ .name = "second", .offset = 8, .type = &uint_type } } };
    const bytes = [_]u8{ 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const valid = [_]u8{ 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0 };
    const v = Value{ .type = &pair, .data = &bytes, .valid = &valid };
    var memory = TestMemory{};
    const ctx = Context{ .user = &memory, .read = TestMemory.read, .lookup = TestMemory.lookup, .allocator = std.testing.allocator };
    try std.testing.expect(hasMissingBits(v));
    const first = try materialize(ctx, try subvalue(v, &uint_type, 0));
    try std.testing.expectEqual(@as(u64, 7), first.bits);
    try std.testing.expectEqual(null, first.address);
    try std.testing.expectError(error.PartialValue, materialize(ctx, try subvalue(v, &uint_type, 8)));
    try std.testing.expectError(error.InvalidValueLayout, subvalue(v, &uint_type, 12));
    const narrow = Type{ .name = "packed", .kind = .unsigned, .size = 1 };
    try std.testing.expectError(error.PartialValue, materialize(ctx, .{ .type = &narrow, .data = &.{7}, .valid = &.{15} }));
}
