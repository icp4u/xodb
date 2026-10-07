//! Retained-stop adapter for the C Lua reader. No target code is executed.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const Module = @import("../model/modules.zig").Module;
const eval = @import("../model/evaluate.zig");
const view = @import("../model/value_view.zig");
const A = std.mem.Allocator;
fn read(ctx: ?*anyopaque, at: u64, out: ?*anyopaque, n: usize) callconv(.c) c_int {
    const session: *model.Session = @ptrCast(@alignCast(ctx.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(at, bytes[0..n]) catch return -1) == n) 0 else -1;
}
fn reader(session: *model.Session) c.struct_xl_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
fn reason(a: A, ptr: [*c]const u8) !?[]const u8 {
    return if (ptr == null) null else try a.dupe(u8, std.mem.span(ptr));
}
fn versionText(a: A, p: *const c.struct_xl_layout) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ p.version[0], p.version[1], p.version[2] });
}
fn buildId(a: A, p: *const c.struct_xl_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, p.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (p.build_id[0..p.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
fn layoutError(message: [*c]const u8) anyerror {
    inline for (.{ error.LuaDwarfUnavailable, error.LuaDwarfMalformed, error.LuaDwarfUnitLimit, error.LuaDwarfWorkLimit, error.LuaDwarfTypeDepthLimit, error.LuaDwarfAmbiguous, error.LuaDwarfTypesUnavailable, error.LuaVersionUnsupported }) |err| {
        if (std.mem.eql(u8, std.mem.span(message), @errorName(err))) return err;
    }
    return error.LuaLayoutUnsupported;
}
fn fileBytes(module: *Module, address: u64, out: []u8) !void {
    for (0..module.image.header.segment_count) |i| {
        const seg = try module.image.segment(@intCast(i));
        if (seg.type != .load or address < seg.vaddr) continue;
        const offset = address - seg.vaddr;
        if (offset > seg.file_size or out.len > seg.file_size - offset) continue;
        const data = try module.image.segmentData(seg);
        @memcpy(out, data[@intCast(offset)..][0..out.len]);
        return;
    }
    return error.LuaVersionUnavailable;
}
fn runtimeModule(session: *model.Session) !*Module {
    // These profiles cover standalone interpreters and static embedded hosts.
    // Kernel PHDR evidence identifies their image without loading unrelated
    // modules or treating a filename as runtime identity.
    const runtime = @import("../target/runtime.zig");
    var loader = std.mem.zeroes(runtime.c.struct_xrt_loader);
    _ = runtime.c.xrt_target_loader(session.target.handle, &loader, null);
    if (loader.main_phdr == 0) return error.LuaModuleIdentityUnavailable;
    const module = session.modules.at(loader.main_phdr) catch return error.LuaModuleIdentityUnavailable;
    if (module.symbols().findSymbol("lua_ident") == null) return error.LuaRuntimeUnavailable;
    if (module.symbols().findSymbol("luaV_execute") == null) return error.LuaImplementationUnsupported;
    return module;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xl_layout {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.LuaArchitectureUnsupported;
    const id = module.image.buildId() orelse return error.LuaBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.LuaBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.LuaBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.LuaBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.target.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len])) return error.LuaBuildIdMismatch;
    const symbol = module.symbols().findSymbol("lua_ident") orelse return error.LuaVersionUnavailable;
    if (!symbol.hasAddress() or symbol.size == 0 or symbol.size > 256) return error.LuaVersionUnavailable;
    var file: [256]u8 = undefined;
    const length: usize = @intCast(symbol.size);
    try fileBytes(module, symbol.value, file[0..length]);
    if (try session.target.readMemory(try module.runtimeAddress(symbol.value), actual[0..length]) != length or !std.mem.eql(u8, file[0..length], actual[0..length])) return error.LuaVersionMismatch;
    const version: [3]u8 = if (std.mem.startsWith(u8, file[0..length], "$LuaVersion: Lua 5.4.9 ")) .{ 5, 4, 9 } else if (std.mem.startsWith(u8, file[0..length], "$LuaVersion: Lua 5.2.4 ")) .{ 5, 2, 4 } else return error.LuaVersionUnsupported;
    if (module.lua_layout == null) {
        var layout: c.struct_xl_layout = undefined;
        const debug = module.debugInfo() catch return error.LuaDwarfMalformed;
        if (c.xl_layout_build(debug.dwarf, id.ptr, id.len, &version, &layout)) |why| return layoutError(why);
        module.lua_layout = layout;
    }
    if (c.xl_layout_check(&module.lua_layout.?, id.ptr, id.len, &version) != null) return error.LuaBuildIdMismatch;
    return &module.lua_layout.?;
}
fn stateType(t: *const eval.Type) bool {
    return std.mem.eql(u8, t.name, "lua_State");
}
fn matchesField(t: *const eval.Type, path: []const u8, offset: u32, size: u32) bool {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const name = if (dot) |i| path[0..i] else path;
    for (t.fields) |f| if (std.mem.eql(u8, f.name, name)) {
        if (dot) |i| return f.offset <= offset and matchesField(f.type, path[i + 1 ..], @intCast(offset - f.offset), size);
        return f.offset == offset and f.type.size == size;
    };
    return false;
}
pub fn preview(session: *model.Session, a: A, value: eval.Value) !?view.Preview {
    if (value.availability != .available or value.type.kind != .pointer or value.bits == 0) return null;
    const child = value.type.child orelse return null;
    const state = stateType(child);
    if (!state and !std.mem.eql(u8, child.name, "TValue") and !std.mem.eql(u8, child.name, "lua_TValue")) return null;
    const module = runtimeModule(session) catch |err| return if (err == error.LuaRuntimeUnavailable) null else err;
    const layout = try profile(session, module);
    if (state) {
        // A public-header forward declaration is opaque. A full definition
        // must agree with the runtime's state/CallInfo/stack field evidence.
        if (child.size != 0 and (child.size != layout.sizes[c.XL_T_STATE] or
            !matchesField(child, "ci", layout.fields[c.XL_STATE_CI].offset, 8) or
            !matchesField(child, if (layout.version[1] == 4) "stack.p" else "stack", layout.fields[c.XL_STATE_STACK].offset, 8))) return null;
    } else if (child.size != layout.sizes[c.XL_T_TVALUE] or
        !matchesField(child, "tt_", layout.fields[c.XL_TAG].offset, layout.fields[c.XL_TAG].size) or
        !matchesField(child, "value_", layout.fields[c.XL_BITS].offset, layout.fields[c.XL_BITS].size)) return null;
    var r = reader(session);
    const raw = try a.create(c.struct_xl_value);
    if (state) c.xl_state_read(layout, &r, value.bits, raw) else c.xl_value_read(layout, &r, value.bits, raw);
    const items = try a.alloc(view.LuaItem, raw.item_count);
    for (raw.items[0..raw.item_count], items) |item, *out| out.* = .{
        .address = item.address,
        .key = try a.dupe(u8, std.mem.sliceTo(&item.key, 0)),
        .type = try a.dupe(u8, std.mem.sliceTo(&item.type, 0)),
        .display = try a.dupe(u8, std.mem.sliceTo(&item.display, 0)),
        .diagnostic = try reason(a, item.reason),
    };
    return .{
        .presentation = .scalar,
        .data_address = value.bits,
        .count = raw.count,
        .element_type = child.name,
        .truncated = raw.truncated != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = "Lua version and loaded build-id checked; same-image DWARF; bounded stopped memory; no target calls or metamethods; GC liveness and allocation extents unproved",
        .lua = .{
            .type = try a.dupe(u8, std.mem.sliceTo(&raw.type, 0)),
            .display = try a.dupe(u8, std.mem.sliceTo(&raw.display, 0)),
            .object = raw.object,
            .array_capacity = raw.array_capacity,
            .hash_capacity = raw.hash_capacity,
            .runtime_version = try versionText(a, layout),
            .runtime_build_id = try buildId(a, layout),
            .type_proof = if (state and child.size == 0) "opaque lua_State declaration and checked runtime structure" else "DWARF fields cross-checked with runtime layout",
            .memory_reads = r.reads,
            .memory_bytes = r.bytes,
            .items = items,
        },
    };
}
pub const Anchor = struct { frame: usize, pc: []const u8, symbol: []const u8, argument: []const u8 };
pub const Runtime = struct { language: []const u8 = "lua", implementation: []const u8 = "PUC Lua", version: []const u8, build_id: []const u8, layout_source: []const u8 = "same-image DWARF" };
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "lua:state", address: []const u8, scope: []const u8 = "this process instance and retained stop; each coroutine is separate" };
pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: ?u32,
    defined_line: ?u32,
    kind: []const u8,
    provenance: []const u8 = "external_read",
    call_info: []const u8,
    function_slot: []const u8,
    prototype: ?[]const u8,
    native_function: ?[]const u8,
    tail_call: bool,
    reason: ?[]const u8,
};
pub const Segment = struct {
    runtime: Runtime,
    runtime_instance: Instance,
    anchor: ?Anchor,
    additional_anchors: []Anchor = &.{},
    source_kind: []const u8 = "stopped_snapshot",
    state: []const u8 = "partial",
    reason: ?[]const u8,
    anchor_scope: []const u8 = "recovered state argument only; no inferred native/logical frame merge",
    frames: []Frame,
    memory_reads: usize,
    memory_bytes: usize,
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    segments: []Segment,
    native_stack_incomplete: bool,
    native_argument_diagnostics: []ArgumentDiagnostic,
    basis: []const u8 = "Lua CallInfo chain for each distinct state; native state arguments are separate evidence; no inferred coroutine merge or target calls",
};
pub const ArgumentDiagnostic = struct { frame: usize, reason: []const u8 };
const Candidate = struct { address: u64, anchor: ?Anchor };
fn fromFrame(session: *model.Session, a: A, frame: model.Frame) !?Candidate {
    const locals = try session.frameLocals(a, frame);
    var found: ?Candidate = null;
    for (locals) |local| {
        if (!local.parameter or local.value.type.kind != .pointer) continue;
        const child = local.value.type.child orelse continue;
        if (!stateType(child)) continue;
        const v = session.evaluateInFrame(a, frame, locals, local.name) catch continue;
        if (v.availability != .available or v.bits == 0) continue;
        if (found) |previous| {
            if (previous.address != v.bits) return error.LuaStateArgumentAmbiguous;
            continue;
        }
        const symbol = frame.symbol orelse "<native frame>";
        const anchored = std.mem.eql(u8, symbol, "luaV_execute") or std.mem.startsWith(u8, symbol, "luaD_");
        found = .{ .address = v.bits, .anchor = if (anchored) .{ .frame = frame.index, .pc = try hex(a, frame.pc), .symbol = try a.dupe(u8, symbol), .argument = try a.dupe(u8, local.name) } else null };
    }
    return found;
}
pub fn stack(session: *model.Session, a: A, tid: i32, first: usize, requested: ?u64) !Stack {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var candidates: std.ArrayList(Candidate) = .empty;
    var diagnostics: std.ArrayList(ArgumentDiagnostic) = .empty;
    if (requested) |address| {
        if (address == 0) return error.InvalidAddress;
        try candidates.append(a, .{ .address = address, .anchor = null });
    }
    for (native[first..]) |frame| {
        const symbol = frame.symbol orelse "";
        if (frame.index != first and !std.mem.eql(u8, symbol, "luaV_execute") and !std.mem.startsWith(u8, symbol, "luaD_")) continue;
        const recovered = fromFrame(session, a, frame) catch |err| blk: {
            // An explicit state read does not depend on debug locals in an
            // unrelated selected frame. Retain failed anchor recovery as
            // evidence instead of preventing the requested observation.
            if (requested == null) return err;
            try diagnostics.append(a, .{ .frame = frame.index, .reason = @errorName(err) });
            break :blk null;
        };
        if (recovered) |candidate| {
            if (requested) |address| {
                if (candidate.address != address) continue;
            }
            try candidates.append(a, candidate);
        }
    }
    if (candidates.items.len == 0) return error.LuaStateArgumentUnavailable;
    var segments: std.ArrayList(Segment) = .empty;
    var r = reader(session);
    for (candidates.items, 0..) |candidate, index| {
        var seen = false;
        for (candidates.items[0..index]) |previous| if (previous.address == candidate.address) {
            seen = true;
            break;
        };
        if (seen) continue;
        if (segments.items.len == 8) return error.LuaStateLimit;
        var anchors: std.ArrayList(Anchor) = .empty;
        for (candidates.items[index..]) |other| if (other.address == candidate.address) {
            if (other.anchor) |anchor| try anchors.append(a, anchor);
        };
        const raw = try a.create(c.struct_xl_stack);
        const before_reads = r.reads;
        const before_bytes = r.bytes;
        c.xl_stack_read(layout, &r, candidate.address, raw);
        const frames = try a.alloc(Frame, raw.count);
        for (raw.frames[0..raw.count], frames) |f, *out| {
            var name = try a.dupe(u8, std.mem.sliceTo(&f.name, 0));
            if (f.native_function != 0) {
                if (session.modules.symbolAt(f.native_function)) |symbol| {
                    if (symbol.offset == 0) name = try a.dupe(u8, symbol.name);
                } else |_| {}
            }
            out.* = .{ .name = name, .file = if (f.file[0] != 0) try a.dupe(u8, std.mem.sliceTo(&f.file, 0)) else null, .line = if (f.line > 0) @intCast(f.line) else null, .defined_line = if (f.defined_line >= 0) @intCast(f.defined_line) else null, .kind = if (f.is_c != 0) "C" else "Lua", .call_info = try hex(a, f.ci), .function_slot = try hex(a, f.function), .prototype = if (f.proto != 0) try hex(a, f.proto) else null, .native_function = if (f.native_function != 0) try hex(a, f.native_function) else null, .tail_call = f.tail_call != 0, .reason = try reason(a, f.reason) };
        }
        try segments.append(a, .{ .runtime = .{ .version = try versionText(a, layout), .build_id = try buildId(a, layout) }, .runtime_instance = .{ .address = try hex(a, candidate.address) }, .anchor = if (anchors.items.len > 0) anchors.items[0] else null, .additional_anchors = if (anchors.items.len > 1) try a.dupe(Anchor, anchors.items[1..]) else &.{}, .reason = (try reason(a, raw.reason)) orelse if (anchors.items.len > 0) "LuaNativeSegmentBoundaryUnproved" else "LuaNativeAnchorUnavailable", .frames = frames, .memory_reads = r.reads - before_reads, .memory_bytes = r.bytes - before_bytes });
        if (r.@"error") |why| {
            if (std.mem.eql(u8, std.mem.span(why), "LuaReadBudget")) break;
            r.@"error" = null;
        }
    }
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = try segments.toOwnedSlice(a), .native_stack_incomplete = native.len == 64 or (native.len > 0 and native[native.len - 1].diagnostic != null), .native_argument_diagnostics = try diagnostics.toOwnedSlice(a) };
}
