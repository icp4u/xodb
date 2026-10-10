//! Native previews of captured runtime types. C owns all value interpretation;
//! this adapter selects the retained graph and formats its bounded value rows.
const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("session.zig").Session;
const eval = @import("evaluate.zig");
const cache = @import("runtime_types.zig");
const A = std.mem.Allocator;
fn text(g: *const c.struct_xjai_graph, at: u32) []const u8 {
    return std.mem.span(g.text + at);
}
const Selection = struct { entry: cache.Entry, graph: *const c.struct_xjai_graph, index: u32 };
fn select(session: *Session, name: []const u8) !Selection {
    if (name.len == 0 or name.len > 1024) return error.InvalidRuntimeTypeExpression;
    const address: ?u64 = if (std.mem.startsWith(u8, name, "0x")) std.fmt.parseInt(u64, name, 0) catch return error.InvalidRuntimeTypeExpression else null;
    var found: ?Selection = null;
    var pending = false;
    var stale = false;
    var failed = false;
    for (session.runtime_types.entries) |maybe| if (maybe) |entry| {
        if (entry.stale(session)) {
            stale = true;
            continue;
        }
        const status = entry.poll();
        if (status.state == c.XJAI_JOB_PENDING) {
            pending = true;
            continue;
        }
        if (status.state == c.XJAI_JOB_FAILED) {
            failed = true;
            continue;
        }
        const g = try entry.graph();
        for (g.types[0..g.type_count], 0..) |t, i| {
            if (if (address) |at| t.address != at else !std.mem.eql(u8, text(g, t.name), name)) continue;
            if (found) |previous| {
                if (previous.graph.types[previous.index].address != t.address) return error.RuntimeTypeAmbiguous;
                if (previous.entry.id > entry.id) continue;
            }
            found = .{ .entry = entry, .graph = g, .index = @intCast(i) };
        }
    };
    // Never choose a type while another current discovery can change whether
    // the name is unique. Duplicate captures at one address are the same type.
    if (pending) return error.RuntimeTypesPending;
    if (found) |f| return f;
    if (stale) return error.RuntimeTypesStale;
    if (failed) return error.RuntimeTypesFailed;
    return error.RuntimeTypeNotFound;
}
fn kind(t: c.struct_xjai_type) eval.Kind {
    return switch (t.tag) {
        0, 11 => if (t.is_signed != 0) .signed else .unsigned,
        1 => .float,
        2 => .boolean,
        4, 13 => .pointer,
        7 => .structure,
        8 => .array,
        else => .unknown,
    };
}
fn typeName(a: A, g: *const c.struct_xjai_graph, t: c.struct_xjai_type) ![]const u8 {
    const name = text(g, t.name);
    if (name.len != 0) return a.dupe(u8, name);
    return switch (t.tag) {
        0 => if (t.size <= 8) std.fmt.allocPrint(a, "{s}{d}", .{ if (t.is_signed != 0) "s" else "u", t.size * 8 }) else a.dupe(u8, "integer (unproved width)"),
        1 => if (t.size <= 8) std.fmt.allocPrint(a, "f{d}", .{t.size * 8}) else a.dupe(u8, "float (unproved width)"),
        2 => a.dupe(u8, "bool"),
        3 => a.dupe(u8, "string"),
        4 => a.dupe(u8, "pointer"),
        6 => a.dupe(u8, "void"),
        8 => a.dupe(u8, "array"),
        13 => a.dupe(u8, "Type"),
        else => a.dupe(u8, "unsupported Jai type"),
    };
}
fn read(context: ?*anyopaque, at: u64, out: ?*anyopaque, size: usize) callconv(.c) c_int {
    const session: *Session = @ptrCast(@alignCast(context.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return @intFromBool((session.target.readMemory(at, bytes[0..size]) catch return 0) == size);
}
const Rows = struct {
    selected: Selection,
    values: *c.struct_xjai_values,
    fn deinit(self: Rows) void {
        c.xjai_values_free(self.values);
    }
};
fn rows(session: *Session, v: eval.Value, depth: u32, start: u64, limit: usize) !Rows {
    const ref = v.runtime_type orelse return error.RuntimeTypeNotFound;
    const entry = try session.runtime_types.find(ref.context_id);
    try entry.requireStop(session);
    if (ref.generation != entry.generation) return error.RuntimeTypesStale;
    const g = try entry.graph();
    const index = c.xjai_type_at(g, ref.type_address);
    if (index == c.XJAI_NONE) return error.RuntimeTypeNotFound;
    if (limit == 0 or limit > 64) return error.InvalidArguments;
    var reader = c.struct_xjai_live_reader{ .context = session, .read = read, .reads = 0, .bytes = 0 };
    const options = c.struct_xjai_value_options{ .depth = depth, .limit = @intCast(limit), .start = start, .follow_pointers = 0 };
    var values: ?*c.struct_xjai_values = null;
    if (c.xjai_value_read(g, index, v.address orelse return error.NotAddressable, &options, &reader, &values)) |why| {
        if (std.mem.eql(u8, std.mem.span(why), "JaiOutOfMemory")) return error.OutOfMemory;
        return error.RuntimeValueUnavailable;
    }
    errdefer c.xjai_values_free(values.?);
    try entry.requireStop(session);
    return .{ .selected = .{ .entry = entry, .graph = g, .index = index }, .values = values.? };
}
pub fn cast(session: *Session, a: A, operand: eval.Value, name: []const u8) !eval.Value {
    if (operand.availability != .available) return error.ValueUnavailable;
    const at = switch (operand.type.kind) {
        .structure, .array => operand.address orelse return error.NotAddressable,
        .pointer, .unsigned => operand.bits,
        .signed => if (@as(i64, @bitCast(operand.bits)) < 0) return error.InvalidAddress else operand.bits,
        else => return error.ExpectedInteger,
    };
    const selected = try select(session, name);
    try selected.entry.requireStop(session);
    const t = selected.graph.types[selected.index];
    const descriptor = try a.create(eval.Type);
    descriptor.* = .{ .name = try typeName(a, selected.graph, t), .kind = kind(t), .size = t.size };
    var v = eval.Value{ .type = descriptor, .address = at, .runtime_type = .{ .context_id = selected.entry.id, .type_address = t.address, .generation = selected.entry.generation } };
    const result = try rows(session, v, 0, 0, 1);
    defer result.deinit();
    const root = result.values.rows[0];
    if (root.has_bits != 0) v.bits = root.bits;
    if (root.reason != null) v.availability = .unavailable;
    return v;
}
fn summary(a: A, selected: Selection, r: c.struct_xjai_value_row) !@import("session.zig").ValueSummary {
    const g = selected.graph;
    if (r.type >= g.type_count) return .{ .type = "unknown Jai type", .kind = .unknown, .size = 0, .address = null, .bits = null, .display = "JaiValueTypeUnavailable", .availability = .unavailable, .diagnostic = "JaiValueTypeUnavailable", .provider = "jai" };
    const t = g.types[r.type];
    var out = @import("session.zig").ValueSummary{ .type = try typeName(a, g, t), .kind = kind(t), .size = t.size, .address = if (r.address == 0) null else r.address, .bits = if (r.has_bits != 0) r.bits else null, .display = "", .availability = if (r.reason == null) .available else .unavailable, .provider = "jai", .runtime_type = .{ .context_id = selected.entry.id, .type_address = t.address, .generation = selected.entry.generation } };
    if (r.reason != null) {
        out.diagnostic = try a.dupe(u8, std.mem.span(r.reason));
        out.display = out.diagnostic.?;
        out.partial = true;
        return out;
    }
    out.display = switch (t.tag) {
        0, 11 => if (t.is_signed != 0) try std.fmt.allocPrint(a, "{d}", .{@as(i64, @bitCast(r.bits))}) else try std.fmt.allocPrint(a, "{d}", .{r.bits}),
        1 => if (t.size == 4) try std.fmt.allocPrint(a, "{d}", .{@as(f32, @bitCast(@as(u32, @truncate(r.bits))))}) else try std.fmt.allocPrint(a, "{d}", .{@as(f64, @bitCast(r.bits))}),
        2 => if (r.bits == 0) "false" else "true",
        4, 13 => try std.fmt.allocPrint(a, "0x{x}", .{r.bits}),
        6 => "void",
        7 => try std.fmt.allocPrint(a, "{{{d} fields}}", .{r.total_count}),
        8 => try std.fmt.allocPrint(a, "[{d} elements]", .{r.total_count}),
        3 => blk: {
            const bytes = r.preview[0..r.preview_bytes];
            const shown = if (std.unicode.utf8ValidateSlice(bytes)) try std.json.Stringify.valueAlloc(a, bytes, .{}) else try std.fmt.allocPrint(a, "hex {x}", .{bytes});
            break :blk try std.fmt.allocPrint(a, "{s}{s} [{d} bytes]", .{ shown, if (r.truncated != 0) "..." else "", r.total_count });
        },
        else => "unsupported Jai type",
    };
    if (r.enum_name != c.XJAI_NONE) {
        out.enumerator = try a.dupe(u8, text(g, r.enum_name));
        out.display = try std.fmt.allocPrint(a, "{s} ({s})", .{ out.enumerator.?, out.display });
    }
    if (t.tag == 13 and r.referenced_type < g.type_count) out.display = try std.fmt.allocPrint(a, "{s} @ 0x{x}", .{ try typeName(a, g, g.types[r.referenced_type]), r.bits });
    return out;
}
/// Format an already decoded C row for a runtime browser without re-reading it.
pub fn rowSummary(a: A, entry: cache.Entry, graph: *const c.struct_xjai_graph, row: c.struct_xjai_value_row) !@import("session.zig").ValueSummary {
    return summary(a, .{ .entry = entry, .graph = graph, .index = row.type }, row);
}
pub fn preview(session: *Session, a: A, v: eval.Value) !@import("session.zig").ValueSummary {
    const result = try rows(session, v, 0, 0, 1);
    defer result.deinit();
    return summary(a, result.selected, result.values.rows[0]);
}
pub fn children(session: *Session, a: A, v: eval.Value, start: u64, limit: usize) !Session.ValuePage {
    const result = try rows(session, v, 1, start, limit);
    defer result.deinit();
    const g = result.selected.graph;
    const root = result.values.rows[0];
    const out = try a.alloc(Session.ValueChild, result.values.count - 1);
    for (result.values.rows[1..result.values.count], out) |r, *child| {
        child.* = .{ .index = r.index, .name = if (r.member < g.member_count) try a.dupe(u8, text(g, g.members[r.member].name)) else try std.fmt.allocPrint(a, "[{d}]", .{r.index}), .value = try summary(a, result.selected, r) };
    }
    const end = start + out.len;
    return .{ .value = try summary(a, result.selected, root), .presentation = if (v.type.kind == .structure) .fields else if (v.type.kind == .array) .array else .scalar, .total = root.total_count, .start = start, .next = if (out.len != 0 and end < root.total_count) end else null, .children = out, .basis = "captured Jai runtime type metadata and exact external reads at the same stopped generation; no target execution" };
}
