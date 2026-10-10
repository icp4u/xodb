//! Runtime type provider tools. Jai is the first C provider; no target code runs.
const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("../model/session.zig").Session;
const cache = @import("../model/runtime_types.zig");
const instances = @import("../model/runtime_instances.zig");
const memory = @import("../model/memory.zig");
const wire = @import("profile.zig");
const V = std.json.Value;
pub const definitions = std.mem.trim(u8, @embedFile("runtime_type_tools.json"), " \r\n\t");
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "load_runtime_types", "list_runtime_types", "get_runtime_type", "read_runtime_value", "release_runtime_types", "search_runtime_instances", "get_runtime_instances", "read_runtime_container", "write_runtime_field", "list_runtime_writes", "undo_runtime_write" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn text(args: V, key: []const u8) ![]const u8 {
    const v = args.object.get(key) orelse return error.InvalidArguments;
    return if (v == .string) v.string else error.InvalidArguments;
}
fn flag(args: V, key: []const u8) !bool {
    const v = args.object.get(key) orelse return false;
    return if (v == .bool) v.bool else error.InvalidArguments;
}
fn hex(a: std.mem.Allocator, v: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{v});
}
fn reason(p: [*c]const u8) ?[]const u8 {
    return if (p == null) null else std.mem.span(p);
}
fn str(g: *const c.struct_xjai_graph, offset: u32) []const u8 {
    return std.mem.span(g.text + offset);
}
fn category(tag: u32) []const u8 {
    return switch (tag) {
        0 => "integer",
        1 => "float",
        2 => "bool",
        3 => "string",
        4 => "pointer",
        5 => "procedure",
        6 => "void",
        7 => "struct",
        8 => "array",
        10 => "any",
        11 => "enum",
        12 => "polymorph",
        13 => "type",
        18 => "variant",
        else => "unsupported",
    };
}
fn typeAddress(a: std.mem.Allocator, g: *const c.struct_xjai_graph, index: u32) !?[]const u8 {
    return if (index < g.type_count) try hex(a, g.types[index].address) else null;
}
fn selected(g: *const c.struct_xjai_graph, args: V) !u32 {
    if ((args.object.get("type_address") != null) == (args.object.get("type_name") != null)) return error.InvalidArguments;
    if (args.object.get("type_address") != null) {
        const at = std.fmt.parseInt(u64, try text(args, "type_address"), 0) catch return error.InvalidArguments;
        const index = c.xjai_type_at(g, at);
        return if (index == c.XJAI_NONE) error.RuntimeTypeNotFound else index;
    }
    const name = try text(args, "type_name");
    if (name.len == 0 or name.len > 1024) return error.InvalidArguments;
    var found: ?u32 = null;
    for (g.types[0..g.type_count], 0..) |t, i| if (std.mem.eql(u8, str(g, t.name), name)) {
        if (found != null) return error.RuntimeTypeAmbiguous;
        found = @intCast(i);
    };
    return found orelse error.RuntimeTypeNotFound;
}
const Type = struct { address_hex: []const u8, name: []const u8, category: []const u8, size_hex: []const u8, reason: ?[]const u8, member_count: u32, enum_count: u32, parameter_count: u32, signed: bool, element_hex: ?[]const u8, polymorph_source_hex: ?[]const u8, array_kind: ?[]const u8, array_count_hex: ?[]const u8 };
fn describe(a: std.mem.Allocator, g: *const c.struct_xjai_graph, t: c.struct_xjai_type) !Type {
    return .{ .address_hex = try hex(a, t.address), .name = str(g, t.name), .category = category(t.tag), .size_hex = try hex(a, t.size), .reason = reason(t.reason), .member_count = t.member_count, .enum_count = t.enum_count, .parameter_count = t.parameter_count, .signed = t.is_signed != 0, .element_hex = try typeAddress(a, g, t.element), .polymorph_source_hex = try typeAddress(a, g, t.polymorph), .array_kind = if (t.tag == 8) switch (t.array_kind) {
        0 => "fixed",
        1 => "view",
        2 => "resizable",
        else => "unproved",
    } else null, .array_count_hex = if (t.tag == 8 and t.array_kind == 0) try hex(a, t.array_count) else null };
}
const Member = struct { name: []const u8, type_address_hex: ?[]const u8, offset_hex: ?[]const u8, flags_hex: []const u8, constant: bool, using: bool, constant_address_hex: ?[]const u8, reason: ?[]const u8 };
fn members(a: std.mem.Allocator, g: *const c.struct_xjai_graph, first: u32, count: u32, start: usize, limit: usize) ![]Member {
    const end = @min(count, start + limit);
    const out = try a.alloc(Member, end - start);
    for (g.members[first + start .. first + end], out) |m, *item| {
        const constant = m.flags & g.layout.flags[c.XJAI_F_CONSTANT] != 0;
        item.* = .{ .name = str(g, m.name), .type_address_hex = try typeAddress(a, g, m.type), .offset_hex = if (constant or m.reason != null) null else try hex(a, m.offset), .flags_hex = try hex(a, m.flags), .constant = constant, .using = m.flags & g.layout.flags[c.XJAI_F_USING] != 0, .constant_address_hex = if (m.constant_address != 0) try hex(a, m.constant_address) else null, .reason = reason(m.reason) };
    }
    return out;
}
const ReadContext = struct { session: *Session, failure: ?anyerror = null };
fn read(context: ?*anyopaque, at: u64, out: ?*anyopaque, size: usize) callconv(.c) c_int {
    const ctx: *ReadContext = @ptrCast(@alignCast(context.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    const got = ctx.session.target.readMemory(at, bytes[0..size]) catch |err| {
        ctx.failure = err;
        return 0;
    };
    return @intFromBool(got == size);
}
fn readValue(a: std.mem.Allocator, session: *Session, entry: cache.Entry, g: *const c.struct_xjai_graph, args: V) !V {
    try session.target.expectGeneration(try wire.number(args, "generation", null));
    try entry.requireStop(session);
    var index = try selected(g, args);
    const address = std.fmt.parseInt(u64, try text(args, "address"), 0) catch return error.InvalidArguments;
    const depth = try wire.number(args, "depth", 3);
    const limit = try wire.number(args, "limit", 32);
    if (depth > 8 or limit == 0 or limit > 64) return error.InvalidArguments;
    const options = c.struct_xjai_value_options{ .depth = @intCast(depth), .limit = @intCast(limit), .start = try wire.number(args, "start", 0), .follow_pointers = @intFromBool(try flag(args, "follow_pointers")) };
    var ctx = ReadContext{ .session = session };
    var reader = c.struct_xjai_live_reader{ .context = &ctx, .read = read, .reads = 0, .bytes = 0 };
    if (args.object.get("self_type_field") != null) {
        const name = try text(args, "self_type_field");
        const t = g.types[index];
        if (t.tag != 7 or name.len == 0) return error.RuntimeSelfTypeFieldUnproved;
        var field: ?u32 = null;
        for (g.members[t.first_member .. t.first_member + t.member_count], t.first_member..) |m, i| if (std.mem.eql(u8, str(g, m.name), name)) {
            if (field != null) return error.RuntimeTypeAmbiguous;
            field = @intCast(i);
        };
        var actual: u32 = c.XJAI_NONE;
        if (c.xjai_self_type(g, index, address, field orelse return error.RuntimeSelfTypeFieldUnproved, &reader, &actual)) |why| return wire.value(a, .{ .id = entry.id, .state = "unavailable", .reason = std.mem.span(why), .rows = @as([]const V, &.{}) });
        index = actual;
    }
    var values: ?*c.struct_xjai_values = null;
    if (c.xjai_value_read(g, index, address, &options, &reader, &values)) |why| return wire.value(a, .{ .id = entry.id, .state = "unavailable", .reason = std.mem.span(why), .rows = @as([]const V, &.{}) });
    const result = values.?;
    defer c.xjai_values_free(result);
    try entry.requireStop(session);
    const Row = struct { parent: ?u32, index_hex: []const u8, name: ?[]const u8, type_address_hex: ?[]const u8, address_hex: ?[]const u8, category: []const u8, bits_hex: ?[]const u8, enum_name: ?[]const u8, referenced_type_hex: ?[]const u8, count_hex: []const u8, preview_hex: []const u8, truncated: bool, reason: ?[]const u8 };
    const out = try a.alloc(Row, result.count);
    var truncated = false;
    const digits = "0123456789abcdef";
    for (result.rows[0..result.count], out) |r, *row| {
        const preview = try a.alloc(u8, r.preview_bytes * 2);
        for (r.preview[0..r.preview_bytes], 0..) |byte, i| {
            preview[i * 2] = digits[byte >> 4];
            preview[i * 2 + 1] = digits[byte & 15];
        }
        truncated = truncated or r.truncated != 0;
        row.* = .{ .parent = if (r.parent == c.XJAI_NONE) null else r.parent, .index_hex = try hex(a, r.index), .name = if (r.member < g.member_count) str(g, g.members[r.member].name) else null, .type_address_hex = try typeAddress(a, g, r.type), .address_hex = if (r.address != 0) try hex(a, r.address) else null, .category = if (r.type < g.type_count) category(g.types[r.type].tag) else "unknown", .bits_hex = if (r.has_bits != 0) try hex(a, r.bits) else null, .enum_name = if (r.enum_name == c.XJAI_NONE) null else str(g, r.enum_name), .referenced_type_hex = try typeAddress(a, g, r.referenced_type), .count_hex = try hex(a, r.total_count), .preview_hex = preview, .truncated = r.truncated != 0, .reason = reason(r.reason) };
    }
    return wire.value(a, .{ .id = entry.id, .provider = "jai", .generation = entry.generation, .image_epoch = entry.image_epoch, .state = if (result.partial != 0) "partial" else if (truncated) "truncated" else "complete", .reason = reason(result.reason), .type_address_hex = try typeAddress(a, g, index), .rows = out, .memory_reads = reader.reads, .memory_bytes = reader.bytes, .backend_error = if (ctx.failure) |err| @errorName(err) else null, .basis = "external reads during the retained stop; no target execution; other threads may change mutable values" });
}
fn container(a: std.mem.Allocator, session: *Session, entry: cache.Entry, g: *const c.struct_xjai_graph, args: V) !V {
    try session.target.expectGeneration(try wire.number(args, "generation", null));
    try entry.requireStop(session);
    const index = try selected(g, args);
    const address = std.fmt.parseInt(u64, try text(args, "address"), 0) catch return error.InvalidArguments;
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    if (limit == 0 or limit > instances.max_page) return error.InvalidArguments;
    var context = instances.Reader{ .session = session };
    var reader = context.reader();
    var rows: [instances.max_page]c.struct_xjai_container_row = undefined;
    var page: c.struct_xjai_container_page = undefined;
    const why = c.xjai_container_read(g, index, address, start, &rows, @intCast(limit), &reader, &page);
    try entry.requireStop(session);
    const Row = struct { address_hex: []const u8, slot_hex: []const u8, type_address_hex: ?[]const u8 };
    const out = try a.alloc(Row, page.count);
    for (rows[0..page.count], out) |r, *item| item.* = .{ .address_hex = try hex(a, r.address), .slot_hex = try hex(a, r.slot), .type_address_hex = try typeAddress(a, g, r.type) };
    return wire.value(a, .{ .id = entry.id, .provider = "jai", .generation = entry.generation, .image_epoch = entry.image_epoch, .state = if (why != null) "unavailable" else if (page.truncated != 0) "truncated" else "complete", .reason = reason(why), .rows = out, .total_count_hex = if (why == null) try hex(a, page.total_count) else null, .capacity_hex = if (why == null) try hex(a, page.capacity) else null, .start = start, .next = if (why == null and start + page.count < page.total_count) @as(?u64, start + page.count) else null, .memory_reads = reader.reads, .memory_bytes = reader.bytes, .backend_error = if (context.failure) |err| @errorName(err) else null, .lifetime_proved = false, .basis = "occupied container storage at the retained stop; allocation identity and concurrent mutation unproved" });
}
fn searchInstances(a: std.mem.Allocator, session: *Session, args: V) !V {
    try wire.fields(args, &.{ "id", "generation", "type_address", "type_name", "dynamic_type_address", "self_type_field", "address", "length" });
    if (session.offline) return error.OfflineSession;
    try session.target.expectGeneration(try wire.number(args, "generation", null));
    const entry = try session.runtime_types.find(try wire.number(args, "id", null));
    try entry.requireStop(session);
    const g = try entry.graph();
    const declared = try selected(g, args);
    const member = try instances.selfField(g, declared, try text(args, "self_type_field"));
    var needle = declared;
    if (args.object.get("dynamic_type_address") != null) {
        const at = std.fmt.parseInt(u64, try text(args, "dynamic_type_address"), 0) catch return error.InvalidArguments;
        needle = c.xjai_type_at(g, at);
    }
    const address = std.fmt.parseInt(u64, try text(args, "address"), 0) catch return error.InvalidArguments;
    const length = try wire.number(args, "length", null);
    if (length == 0 or length > memory.max_search) return error.InvalidArguments;
    const id = try session.runtime_instances.begin(session, entry, declared, needle, member, address, @intCast(length));
    return wire.value(a, .{ .id = id, .context_id = entry.id, .state = "running", .candidate_kind = "type_pointer_match", .lifetime_proved = false, .cancel_tool = "cancel_memory_search" });
}
fn instancePage(a: std.mem.Allocator, session: *Session, args: V) !V {
    try wire.fields(args, &.{ "id", "generation", "start", "limit" });
    try session.target.expectGeneration(try wire.number(args, "generation", null));
    const id = try wire.number(args, "id", null);
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    if (start > memory.max_hits or limit == 0 or limit > instances.max_page) return error.InvalidArguments;
    const query = try session.runtime_instances.find(session, id);
    const page = try session.runtime_instances.page(session, id, @intCast(start), @intCast(limit));
    const search = &session.memory.search.?;
    const Row = struct { hit_hex: []const u8, candidate_address_hex: ?[]const u8, type_address_hex: ?[]const u8, reason: ?[]const u8 };
    const rows = try a.alloc(Row, page.count);
    for (page.rows[0..page.count], rows) |r, *row| row.* = .{ .hit_hex = try hex(a, r.hit), .candidate_address_hex = if (r.address) |v| try hex(a, v) else null, .type_address_hex = if (r.type_address) |v| try hex(a, v) else null, .reason = r.reason };
    const end = start + page.count;
    return wire.value(a, .{ .id = id, .context_id = query.context_id, .provider = "jai", .state = search.state, .generation = search.generation, .image_epoch = search.image_epoch, .candidate_hit_count = search.count, .start = start, .next = if (end < search.count) @as(?u64, end) else null, .rows = rows, .scanned_bytes = search.scanned, .range_bytes = search.length, .unreadable_bytes = search.unreadable, .memory_reads = page.reads, .memory_bytes = page.bytes, .backend_error = if (page.backend_error) |err| @errorName(err) else null, .lifetime_proved = false, .basis = "bounded type-pointer matches with explicit field/self-type corroboration; matching bytes can be unrelated storage" });
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "write_runtime_field")) return writeField(a, session, args);
    if (std.mem.eql(u8, name, "undo_runtime_write")) {
        try wire.fields(args, &.{ "write_id", "generation", "raw" });
        const result = try session.runtime_writes.undo(session, .agent, try wire.number(args, "generation", null), try wire.number(args, "write_id", null), try flag(args, "raw"));
        return wire.value(a, .{ .generation = session.target.snapshot().generation, .change = result });
    }
    if (std.mem.eql(u8, name, "list_runtime_writes")) return listWrites(a, session, args);
    if (std.mem.eql(u8, name, "search_runtime_instances")) return searchInstances(a, session, args);
    if (std.mem.eql(u8, name, "get_runtime_instances")) return instancePage(a, session, args);
    if (std.mem.eql(u8, name, "load_runtime_types")) {
        try wire.fields(args, &.{ "provider", "snapshot_ids", "generation" });
        if (!std.mem.eql(u8, try text(args, "provider"), "jai")) return error.RuntimeTypeProviderUnsupported;
        try session.target.expectGeneration(try wire.number(args, "generation", null));
        const list = args.object.get("snapshot_ids") orelse return error.InvalidArguments;
        if (list != .array or list.array.items.len == 0 or list.array.items.len > 16) return error.InvalidArguments;
        var ids: [16]u64 = undefined;
        for (list.array.items, 0..) |v, i| {
            if (v != .integer or v.integer <= 0) return error.InvalidArguments;
            ids[i] = @intCast(v.integer);
        }
        const id = try session.runtime_types.load(session, ids[0..list.array.items.len], session.jobRequester());
        return wire.value(a, .{ .id = id, .provider = "jai", .state = "pending" });
    }
    const listing = std.mem.eql(u8, name, "list_runtime_types");
    const get = std.mem.eql(u8, name, "get_runtime_type");
    const release = std.mem.eql(u8, name, "release_runtime_types");
    const containers = std.mem.eql(u8, name, "read_runtime_container");
    try wire.fields(args, if (listing) &.{ "id", "start", "limit" } else if (get) &.{ "id", "type_address", "type_name", "start", "limit", "parameter_start" } else if (release) &.{"id"} else if (containers) &.{ "id", "generation", "type_address", "type_name", "address", "start", "limit" } else &.{ "id", "generation", "type_address", "type_name", "address", "depth", "start", "limit", "follow_pointers", "self_type_field" });
    const id = try wire.number(args, "id", null);
    if (release) {
        try session.runtime_types.release(id, session.jobRequester());
        return wire.value(a, .{ .released = id });
    }
    const entry = try session.runtime_types.find(id);
    const status = entry.poll();
    if (status.state != c.XJAI_JOB_READY) return wire.value(a, .{ .id = id, .provider = "jai", .state = if (status.state == c.XJAI_JOB_PENDING) "pending" else "failed", .reason = reason(status.reason), .generation = entry.generation, .image_epoch = entry.image_epoch, .stale = entry.stale(session) });
    const g = try entry.graph();
    if (containers) return container(a, session, entry, g, args);
    if (!listing and !get) return readValue(a, session, entry, g, args);
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    if (limit == 0 or limit > 128) return error.InvalidArguments;
    if (listing) {
        if (start > g.type_count) return error.InvalidArguments;
        const end = @min(g.type_count, start + limit);
        const rows = try a.alloc(Type, end - start);
        for (g.types[start..end], rows) |t, *row| row.* = try describe(a, g, t);
        return wire.value(a, .{ .id = id, .provider = "jai", .state = "ready", .generation = entry.generation, .image_epoch = entry.image_epoch, .stale = entry.stale(session), .partial = g.partial != 0, .reason = reason(g.reason), .profile = g.layout.profile, .schema_fingerprint_hex = try hex(a, g.layout.fingerprint), .types = rows, .total = g.type_count, .start = start, .next = if (end < g.type_count) @as(?u64, end) else null, .invalid_types = g.invalid_types, .invalid_members = g.invalid_members, .rejected_candidates = g.rejected_candidates, .retained_bytes = g.allocated_bytes });
    }
    const index = try selected(g, args);
    const t = g.types[index];
    const total = if (t.tag == 11) t.enum_count else t.member_count;
    const parameter_start = try wire.number(args, "parameter_start", 0);
    if (start > total or parameter_start > t.parameter_count) return error.InvalidArguments;
    const end = @min(total, start + limit);
    const parameter_end = @min(t.parameter_count, parameter_start + limit);
    const Enum = struct { name: []const u8, bits_hex: []const u8 };
    const enums = try a.alloc(Enum, if (t.tag == 11) end - start else 0);
    if (t.tag == 11) for (g.enums[t.first_enum + start .. t.first_enum + end], enums) |e, *out| {
        out.* = .{ .name = str(g, e.name), .bits_hex = try hex(a, e.bits) };
    };
    return wire.value(a, .{ .id = id, .provider = "jai", .state = "ready", .generation = entry.generation, .image_epoch = entry.image_epoch, .stale = entry.stale(session), .type = try describe(a, g, t), .members = try members(a, g, t.first_member, t.member_count, if (t.tag == 11) 0 else @intCast(start), @intCast(limit)), .enumerators = enums, .parameters = try members(a, g, t.first_parameter, t.parameter_count, @intCast(parameter_start), @intCast(limit)), .start = start, .next = if (end < total) @as(?u64, end) else null, .parameter_next = if (parameter_end < t.parameter_count) @as(?u64, parameter_end) else null });
}

fn writeField(a: std.mem.Allocator, session: *Session, args: V) !V {
    try wire.fields(args, &.{ "id", "generation", "type_address", "type_name", "address", "path", "value", "raw" });
    const expected = try wire.number(args, "generation", null);
    try session.authorize(.agent, .mutation, expected);
    const entry = try session.runtime_types.find(try wire.number(args, "id", null));
    try entry.requireStop(session);
    const graph = try entry.graph();
    const address = std.fmt.parseInt(u64, try text(args, "address"), 0) catch return error.InvalidArguments;
    const result = try session.runtime_writes.apply(session, .agent, expected, entry, try selected(graph, args), address, try text(args, "path"), try text(args, "value"), try flag(args, "raw"));
    return wire.value(a, .{ .generation = session.target.snapshot().generation, .change = result });
}
fn listWrites(a: std.mem.Allocator, session: *Session, args: V) !V {
    try wire.fields(args, &.{ "start", "limit" });
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    const journal = session.runtime_writes.journal;
    const count = c.xjai_write_journal_count(journal);
    if (start > count or limit == 0 or limit > 128) return error.InvalidArguments;
    const end = @min(count, start + limit);
    const out = try a.alloc(V, @intCast(end - start));
    const current = session.runtime_writes.stamp(session, .human);
    for (out, @as(usize, @intCast(start))..) |*row, i| {
        const r = c.xjai_write_journal_get(journal, i + 1).*;
        var old: [128]u8 = undefined;
        var wanted: [128]u8 = undefined;
        var observed: [128]u8 = undefined;
        const format = @import("../model/runtime_writes.zig").hexBytes;
        row.* = try wire.value(a, .{ .id = r.id, .address_hex = try hex(a, r.plan.address), .type_address_hex = try hex(a, r.plan.type_address), .size = r.plan.size, .path = std.mem.sliceTo(&r.path, 0), .before_hex = format(&old, r.before[0..r.plan.size]), .requested_hex = format(&wanted, r.plan.bytes[0..r.plan.size]), .observed_hex = if (r.observed_valid != 0) format(&observed, r.observed[0..r.plan.size]) else null, .generation_before = r.initial.generation, .generation_after = r.after_generation, .actor = if (r.initial.actor == 0) "human" else "agent", .client_id = r.initial.client_id, .last_actor = if (r.last.actor == 0) "human" else "agent", .last_client_id = r.last.client_id, .raw = r.raw != 0, .last_raw = r.last_raw != 0, .last_undo = r.last_undo != 0, .undone = r.undone != 0, .attempts = r.attempts, .same_target = current.session_id == r.initial.session_id and current.target_id == r.initial.target_id and current.image_epoch == r.initial.image_epoch, .reason = reason(r.last_reason), .backend_reason = reason(r.backend_reason) });
    }
    return wire.value(a, .{ .rows = out, .total = count, .start = start, .next = if (end < count) @as(?u64, end) else null, .storage_bytes = c.xjai_write_journal_bytes(journal), .capacity = c.XJAI_WRITE_RECORDS, .basis = "retained sampled bytes; checked undo does not prove allocation lifetime" });
}
