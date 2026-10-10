//! Go native-value adapter. C owns runtime storage, limits and validation;
//! DWARF supplies actual child types, not guessed runtime-name matches.
const std = @import("std");
const c = @import("../c.zig").api;
const go = @import("go.zig");
const model = @import("../model/session.zig");
const Module = @import("../model/modules.zig").Module;
const eval = @import("../model/evaluate.zig");
const view = @import("../model/value_view.zig");
const A = std.mem.Allocator;
pub fn supported(t: *const eval.Type) bool {
    return t.language == .go and (t.go_kind == view.go_kind.map or t.go_kind == view.go_kind.chan or t.go_kind == view.go_kind.interface);
}
fn layoutError(why: [*c]const u8) anyerror {
    inline for (.{ error.GoBuildIdUnavailable, error.GoDwarfUnavailable, error.GoDwarfMalformed, error.GoDwarfWorkLimit, error.GoDwarfAmbiguous, error.GoDwarfTypesUnsupported, error.GoDwarfTypesUnavailable, error.GoConstantMismatch, error.GoDwarfTypeDepthLimit, error.GoDwarfSchemaLimit, error.GoDwarfUnitLimit, error.GoDwarfConstantsUnavailable, error.GoValueLayoutTooLarge, error.GoMapLayoutTooLarge }) |err| {
        if (std.mem.eql(u8, std.mem.span(why), @errorName(err))) return err;
    }
    return error.GoValueLayoutUnsupported;
}
fn valueProfile(module: *Module) !*const c.struct_xgv_layout {
    if (module.go_map_layout) |p| return &p.values;
    if (module.go_value_layout) |p| return p;
    const debug = try module.debugInfo();
    const id = module.image.buildId() orelse return error.GoBuildIdUnavailable;
    const p = try module.debug_allocator.create(c.struct_xgv_layout);
    errdefer module.debug_allocator.destroy(p);
    if (c.xgv_layout_build(debug.dwarf, id.ptr, id.len, p)) |why| return layoutError(why);
    module.go_value_layout = p;
    return p;
}
fn mapProfile(module: *Module) !*const c.struct_xgm_layout {
    if (module.go_map_layout) |p| return p;
    const debug = try module.debugInfo();
    const id = module.image.buildId() orelse return error.GoBuildIdUnavailable;
    const p = try module.debug_allocator.create(c.struct_xgm_layout);
    errdefer module.debug_allocator.destroy(p);
    if (c.xgm_layout_build(debug.dwarf, id.ptr, id.len, p)) |why| return layoutError(why);
    module.go_map_layout = p;
    return p;
}
const Context = struct {
    session: *model.Session,
    module: *Module,
    generation: u64,
    moduledata: u64,
    types: u64,
    etypes: u64,
    fn init(session: *model.Session, t: *const eval.Type) !Context {
        const generation = session.target.snapshot().generation;
        const module = try go.verifiedModule(session);
        const debug = try module.debugInfo();
        const dwarf = debug.dwarf orelse return error.GoDwarfUnavailable;
        if (t.go_dwarf != @as(*const anyopaque, @ptrCast(dwarf))) return error.GoRuntimeTypeImageMismatch;
        const types = try go.globalAddress(module, "runtime.types");
        const etypes = try go.globalAddress(module, "runtime.etypes");
        if (types >= etypes) return error.GoRuntimeTypeImageMismatch;
        return .{ .session = session, .module = module, .generation = generation, .moduledata = try go.globalAddress(module, "runtime.firstmoduledata"), .types = types, .etypes = etypes };
    }
    fn finish(self: Context) !void {
        try self.session.target.expectGeneration(self.generation);
    }
    fn typeAddress(self: Context, t: *const eval.Type) !u64 {
        if (t.go_dwarf != @as(*const anyopaque, @ptrCast((try self.module.debugInfo()).dwarf.?))) return error.GoRuntimeTypeImageMismatch;
        const offset = t.go_runtime_offset orelse return error.GoRuntimeTypeMetadataUnavailable;
        if (offset >= self.etypes - self.types) return error.GoRuntimeTypeMetadataUnavailable;
        return self.types + offset;
    }
    fn checkType(self: Context, t: *const eval.Type, raw: *const c.struct_xgv_type_info) !void {
        if (raw.section_start != self.types or raw.section_end != self.etypes) return error.GoRuntimeTypeImageMismatch;
        if (try self.typeAddress(t) != raw.address or t.size != raw.size or (t.go_kind != 0 and t.go_kind != raw.kind)) return error.GoRuntimeTypeMetadataMismatch;
    }
    fn dynamicType(self: Context, raw: *const c.struct_xgv_type_info) !*const eval.Type {
        if (raw.section_start != self.types or raw.section_end != self.etypes or raw.address < self.types or raw.address >= self.etypes) return error.GoRuntimeTypeImageMismatch;
        const t = try (try self.module.debugInfo()).goRuntimeType(raw.address - self.types);
        try self.checkType(t, raw);
        return t;
    }
    fn interface(self: Context, v: eval.Value, out: *c.struct_xgv_interface) !void {
        const layout = try valueProfile(self.module);
        const nonempty = v.type.go_interface_nonempty orelse return error.GoInterfaceRepresentationUnproved;
        var r = go.reader(self.session);
        if (eval.hasMissingBits(v)) return error.PartialValue;
        if (v.data) |bytes| {
            if (v.type.size > bytes.len) return error.PartialValue;
            c.xgv_interface_from_bytes(layout, &r, self.moduledata, bytes.ptr, @intCast(v.type.size), @intFromBool(nonempty), out);
        } else if (v.address) |at| {
            c.xgv_interface_read(layout, &r, self.moduledata, at, @intFromBool(nonempty), out);
        } else return error.GoInterfaceHeaderUnavailable;
    }
    fn map(self: Context, v: eval.Value, start: u64, limit: usize, out: *c.struct_xgm_page) !void {
        const layout = try mapProfile(self.module);
        var r = go.reader(self.session);
        c.xgm_map_read(layout, &r, self.moduledata, try self.typeAddress(v.type), v.bits, start, @intCast(limit), out);
        if (out.reason == null) {
            try self.checkType(v.type.go_key orelse return error.GoMapTypeMetadataUnavailable, &out.key_type);
            try self.checkType(v.type.go_element orelse return error.GoMapTypeMetadataUnavailable, &out.element_type);
        }
    }
};
fn dynamicValue(a: A, t: *const eval.Type, raw: *const c.struct_xgv_interface) !eval.Value {
    if (raw.type.direct == 0) return .{ .type = t, .address = raw.value_address };
    // A direct value may itself be a one-pointer struct/array. Preserve all
    // eight bytes so normal DWARF subvalues work even without an address.
    const bytes = try a.alloc(u8, 8);
    std.mem.writeInt(u64, bytes[0..8], raw.data, .little);
    return .{ .type = t, .data = bytes };
}
fn partial(a: A, out: *model.ValueSummary, why: []const u8) !void {
    out.partial = true;
    out.diagnostic = try a.dupe(u8, why);
    out.display = try std.fmt.allocPrint(a, "partial: {s}", .{why});
}
fn preview(ctx: Context, a: A, v: eval.Value, out: *model.ValueSummary) anyerror!void {
    switch (v.type.go_kind) {
        view.go_kind.map => {
            var raw: c.struct_xgm_page = undefined;
            try ctx.map(v, 0, 1, &raw);
            if (raw.reason != null) return partial(a, out, std.mem.span(raw.reason));
            out.display = if (raw.is_nil != 0) try std.fmt.allocPrint(a, "nil {s}", .{v.type.name}) else try std.fmt.allocPrint(a, "{s} len {d}", .{ v.type.name, raw.total });
            out.visualization = .{ .presentation = .fields, .data_address = v.bits, .count = raw.total, .element_type = v.type.go_element.?.name, .basis = "same-image Go DWARF; C stored map slots/counts; no target calls" };
        },
        view.go_kind.chan => {
            var r = go.reader(ctx.session);
            var raw: c.struct_xgv_channel = undefined;
            c.xgv_channel_read(try valueProfile(ctx.module), &r, ctx.moduledata, v.bits, &raw);
            if (raw.header_valid == 0) return partial(a, out, if (raw.reason != null) std.mem.span(raw.reason) else "GoChannelUnavailable");
            if (raw.is_nil != 0) {
                out.display = try std.fmt.allocPrint(a, "nil {s}", .{v.type.name});
                return;
            }
            try ctx.checkType(v.type.go_element orelse return error.GoChannelTypeMetadataUnavailable, &raw.element);
            out.display = try std.fmt.allocPrint(a, "{s} len {d} cap {d} {s}; queue entries send {s}{d}, recv {s}{d}, select {d}", .{ v.type.name, raw.length, raw.capacity, if (raw.closed != 0) "closed" else "open", if (raw.waits_complete == 0) ">=" else "", raw.send_entries, if (raw.waits_complete == 0) ">=" else "", raw.receive_entries, raw.select_entries });
            if (raw.reason != null) {
                out.partial = true;
                out.diagnostic = try a.dupe(u8, std.mem.span(raw.reason));
            }
        },
        view.go_kind.interface => {
            var raw: c.struct_xgv_interface = undefined;
            try ctx.interface(v, &raw);
            if (raw.reason != null) return partial(a, out, std.mem.span(raw.reason));
            if (raw.is_nil != 0) {
                out.display = "nil interface";
                return;
            }
            const t = try ctx.dynamicType(&raw.type);
            const value = try ctx.session.summarize(a, try dynamicValue(a, t, &raw));
            out.display = try std.fmt.allocPrint(a, "{s}({s})", .{ t.name, value.display });
            out.partial = value.partial;
            out.diagnostic = value.diagnostic;
        },
        else => unreachable,
    }
}
pub fn summarize(session: *model.Session, a: A, v: eval.Value, out: *model.ValueSummary) !bool {
    if (!supported(v.type)) return false;
    const ctx = Context.init(session, v.type) catch |err| {
        try partial(a, out, @errorName(err));
        return true;
    };
    preview(ctx, a, v, out) catch |err| try partial(a, out, @errorName(err));
    try ctx.finish();
    return true;
}
pub fn children(session: *model.Session, a: A, v: eval.Value, start: u64, limit: usize) anyerror!model.Session.ValuePage {
    if (limit == 0 or limit > view.max_children or v.availability != .available) return error.InvalidValuePage;
    const ctx = try Context.init(session, v.type);
    var items: std.ArrayList(model.Session.ValueChild) = .empty;
    var total: u64 = 0;
    var next: ?u64 = null;
    if (v.type.go_kind == view.go_kind.map) {
        var raw: c.struct_xgm_page = undefined;
        // Native callers may pass an unmaterialized address/composite pointer.
        const materialized = try eval.materialize(.{ .allocator = a, .user = session, .read = read, .lookup = lookup }, v);
        try ctx.map(materialized, start, limit, &raw);
        if (raw.reason != null) return error.GoMapPageUnavailable;
        total = raw.total;
        if (start > total) return error.InvalidValuePage;
        const key = v.type.go_key.?;
        const element = v.type.go_element.?;
        for (raw.entries[0..raw.count], 0..) |entry, i| {
            const k = try session.summarize(a, .{ .type = key, .address = entry.key });
            try items.append(a, .{ .index = start + i, .name = try std.fmt.allocPrint(a, "[{s}]", .{k.display}), .value = try session.summarize(a, .{ .type = element, .address = entry.value }) });
        }
        if (raw.complete == 0) next = raw.next;
    } else if (v.type.go_kind == view.go_kind.interface) {
        var raw: c.struct_xgv_interface = undefined;
        try ctx.interface(v, &raw);
        if (raw.reason != null) return error.GoInterfaceValueUnavailable;
        total = if (raw.is_nil != 0) 0 else 1;
        if (raw.is_nil == 0) {
            const t = try ctx.dynamicType(&raw.type);
            const dynamic = try dynamicValue(a, t, &raw);
            // Expand the concrete aggregate itself, so an interface containing
            // a map or struct exposes useful entries/fields in the same view.
            if (t.kind == .structure or t.kind == .array or t.go_kind == view.go_kind.map) {
                var page = try session.valueChildren(a, dynamic, start, limit, false);
                page.value = try session.summarize(a, v);
                page.basis = "concrete Go runtime type resolved by same-image DWARF; no target calls";
                try ctx.finish();
                return page;
            }
            if (start == 0) try items.append(a, .{ .index = 0, .name = "value", .value = try session.summarize(a, dynamic) });
        }
        if (start > total) return error.InvalidValuePage;
    } else if (start != 0) return error.InvalidValuePage;
    try ctx.finish();
    return .{ .value = try session.summarize(a, v), .presentation = .fields, .total = total, .start = start, .next = next, .children = try items.toOwnedSlice(a), .basis = "same-image Go DWARF; C runtime storage; retained stopped generation; no target calls" };
}
fn read(ptr: *anyopaque, at: u64, out: []u8) !usize {
    const session: *model.Session = @ptrCast(@alignCast(ptr));
    return session.target.readMemory(at, out);
}
fn lookup(_: *anyopaque, _: []const u8) !eval.Value {
    return error.UnknownVariable;
}
