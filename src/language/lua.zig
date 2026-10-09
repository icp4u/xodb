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
    inline for (.{ error.LuaRuntimeMultiple, error.LuaDwarfUnavailable, error.LuaDwarfMalformed, error.LuaDwarfUnitLimit, error.LuaDwarfWorkLimit, error.LuaDwarfTypeDepthLimit, error.LuaDwarfAmbiguous, error.LuaDwarfTypesUnavailable, error.LuaVersionUnsupported }) |err| {
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
fn singleRuntime(module: *Module) !void {
    // A static middleware copy may have local/hidden symbols. Do not let the
    // ordinary global-first lookup assign its state the other copy's version.
    // Symtab/dynsym and a debug companion can repeat the same definition.
    const elf = @import("../binary/elf.zig");
    var definitions: [2]?u64 = .{ null, null };
    var remaining: u32 = 1_000_000;
    const images = [_]*const elf.Image{ &module.image, module.symbols() };
    for (images, 0..) |image, index| {
        if (index == 1 and images[0] == image) continue;
        for ([_]elf.SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
            const table = (image.symbols(kind) catch return error.LuaSymbolMalformed) orelse continue;
            if (table.count() > remaining) return error.LuaSymbolWorkLimit;
            remaining -= table.count();
            var i: u32 = 1;
            while (i < table.count()) : (i += 1) {
                const symbol = table.get(i) catch return error.LuaSymbolMalformed;
                if (!symbol.hasAddress()) continue;
                const slot: usize = if (symbol.type == .object and std.mem.eql(u8, symbol.name, "lua_ident")) 0 else if (symbol.type == .func and std.mem.eql(u8, symbol.name, "luaV_execute")) 1 else continue;
                if (definitions[slot]) |old| {
                    if (old != symbol.value) return error.LuaRuntimeMultiple;
                } else definitions[slot] = symbol.value;
            }
        }
    }
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
    if (module.lua_layout == null) try singleRuntime(module);
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
    const stack_value = std.mem.eql(u8, child.name, "StackValue");
    if (!state and !stack_value and !std.mem.eql(u8, child.name, "TValue") and !std.mem.eql(u8, child.name, "lua_TValue")) return null;
    const module = runtimeModule(session) catch |err| return if (err == error.LuaRuntimeUnavailable) null else err;
    const layout = try profile(session, module);
    if (state) {
        // A public-header forward declaration is opaque. A full definition
        // must agree with the runtime's state/CallInfo/stack field evidence.
        if (child.size != 0 and (child.size != layout.sizes[c.XL_T_STATE] or
            !matchesField(child, "ci", layout.fields[c.XL_STATE_CI].offset, 8) or
            !matchesField(child, if (layout.version[1] == 4) "stack.p" else "stack", layout.fields[c.XL_STATE_STACK].offset, 8))) return null;
    } else if (stack_value) {
        if (layout.version[1] != 4 or child.size != layout.sizes[c.XL_T_STACK] or
            !matchesField(child, "val", 0, layout.sizes[c.XL_T_TVALUE]) or
            !matchesField(child, "val.tt_", layout.fields[c.XL_TAG].offset, layout.fields[c.XL_TAG].size) or
            !matchesField(child, "val.value_", layout.fields[c.XL_BITS].offset, layout.fields[c.XL_BITS].size)) return null;
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
        .advisory = item.advisory != 0,
    };
    return .{
        .presentation = .scalar,
        .data_address = value.bits,
        .count = raw.count,
        .element_type = child.name,
        .truncated = raw.truncated != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = if (module.debug_file != null) "Lua version and loaded build-id checked; build-id companion DWARF; bounded stopped memory; no target calls or metamethods; GC liveness and allocation extents unproved" else "Lua version and loaded build-id checked; same-image DWARF; bounded stopped memory; no target calls or metamethods; GC liveness and allocation extents unproved",
        .lua = .{
            .type = try a.dupe(u8, std.mem.sliceTo(&raw.type, 0)),
            .advisory = raw.advisory != 0,
            .layout_source = if (module.debug_file != null) "build-id companion DWARF" else "same-image DWARF",
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
    identity_proved: bool,
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
    chain_complete: bool,
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
fn fromFrame(session: *model.Session, a: A, frame: model.Frame, requested: ?u64, candidates: *std.ArrayList(Candidate)) !void {
    const locals = try session.frameLocals(a, frame);
    var typed_parameter = false;
    var recovered_parameter = false;
    var unavailable: anyerror = error.LuaStateArgumentUnavailable;
    for (locals) |local| {
        if (!local.parameter or local.value.type.kind != .pointer) continue;
        const child = local.value.type.child orelse continue;
        if (!stateType(child)) continue;
        typed_parameter = true;
        if (local.diagnostic) |why| if (std.mem.eql(u8, why, "EntryValueUnavailable")) {
            unavailable = error.EntryValueUnavailable;
        };
        const v = session.evaluateInFrame(a, frame, locals, local.name) catch continue;
        if (v.availability != .available or v.bits == 0) continue;
        recovered_parameter = true;
        if (requested) |address| if (v.bits != address) continue;
        const symbol = frame.symbol orelse "<native frame>";
        const anchored = std.mem.eql(u8, symbol, "luaV_execute") or std.mem.startsWith(u8, symbol, "luaD_");
        if (candidates.items.len == 256) return error.LuaStateCandidateLimit;
        try candidates.append(a, .{ .address = v.bits, .anchor = if (anchored) .{ .frame = frame.index, .pc = try hex(a, frame.pc), .symbol = try a.dupe(u8, symbol), .argument = try a.dupe(u8, local.name) } else null });
    }
    if (typed_parameter and !recovered_parameter) return unavailable;
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
        fromFrame(session, a, frame, requested, &candidates) catch |err| {
            if (err == error.OutOfMemory) return err;
            // A native frame's missing locals cannot invalidate independently
            // recovered states in other Lua frames. Keep the failed evidence.
            try diagnostics.append(a, .{ .frame = frame.index, .reason = @errorName(err) });
        };
    }
    if (candidates.items.len == 0 and diagnostics.items.len == 0) return error.LuaStateArgumentUnavailable;
    var segments: std.ArrayList(Segment) = .empty;
    var r = reader(session);
    for (candidates.items, 0..) |candidate, index| {
        var seen = false;
        for (candidates.items[0..index]) |previous| if (previous.address == candidate.address) {
            seen = true;
            break;
        };
        if (seen) continue;
        if (segments.items.len == 8) {
            try diagnostics.append(a, .{ .frame = if (candidate.anchor) |anchor| anchor.frame else first, .reason = "LuaStateLimit" });
            break;
        }
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
            out.* = .{ .name = name, .file = if (f.file[0] != 0) try a.dupe(u8, std.mem.sliceTo(&f.file, 0)) else null, .line = if (f.line > 0) @intCast(f.line) else null, .defined_line = if (f.defined_line >= 0) @intCast(f.defined_line) else null, .kind = if (f.is_c != 0) "C" else "Lua", .call_info = try hex(a, f.ci), .function_slot = try hex(a, f.function), .prototype = if (f.proto != 0) try hex(a, f.proto) else null, .native_function = if (f.native_function != 0) try hex(a, f.native_function) else null, .tail_call = f.tail_call != 0, .identity_proved = f.identity_proved != 0, .reason = try reason(a, f.reason) };
        }
        try segments.append(a, .{ .runtime = .{ .version = try versionText(a, layout), .build_id = try buildId(a, layout), .layout_source = if (module.debug_file != null) "build-id companion DWARF" else "same-image DWARF" }, .runtime_instance = .{ .address = try hex(a, candidate.address) }, .anchor = if (anchors.items.len > 0) anchors.items[0] else null, .additional_anchors = if (anchors.items.len > 1) try a.dupe(Anchor, anchors.items[1..]) else &.{}, .reason = (try reason(a, raw.reason)) orelse if (anchors.items.len > 0) "LuaNativeSegmentBoundaryUnproved" else "LuaNativeAnchorUnavailable", .frames = frames, .chain_complete = raw.chain_complete != 0, .memory_reads = r.reads - before_reads, .memory_bytes = r.bytes - before_bytes });
        if (r.@"error") |why| {
            if (std.mem.eql(u8, std.mem.span(why), "LuaReadBudget")) break;
            r.@"error" = null;
        }
    }
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = try segments.toOwnedSlice(a), .native_stack_incomplete = native.len == 64 or (native.len > 0 and native[native.len - 1].diagnostic != null), .native_argument_diagnostics = try diagnostics.toOwnedSlice(a) };
}

/// Runtime identity and proof from the existing stopped-memory reader.
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    return .{ .version = try versionText(a, layout), .build_id = try buildId(a, layout), .basis = if (module.debug_file != null) "build-id companion DWARF" else "same-image DWARF" };
}

/// Select through the canonical reader stack; raw target addresses are never
/// accepted as a substitute for the requested retained logical frame.
pub fn readLocals(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize) !@import("../model/language_locals.zig").Result {
    return readBindings(session, a, tid, segment_index, frame, start, limit, null);
}
pub fn evaluateLocal(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, text: []const u8) !@import("../model/language_locals.zig").Result {
    return readBindings(session, a, tid, segment_index, frame, 0, 1, text);
}
fn readBindings(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize, expression: ?[]const u8) !@import("../model/language_locals.zig").Result {
    const named = @import("../model/language_locals.zig");
    const observed = try stack(session, a, tid, 0, null);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment = observed.segments[segment_index];
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const state = try std.fmt.parseInt(u64, segment.runtime_instance.address, 0);
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var r = reader(session);
    const raw = try a.create(c.struct_xl_locals);
    if (expression) |text| c.xl_local_find(layout, &r, state, frame, try a.dupeZ(u8, text), raw) else c.xl_locals_read(layout, &r, state, frame, start, limit, raw);
    const ci = try std.fmt.parseInt(u64, segment.frames[frame].call_info, 0);
    if (raw.call_info != 0 and raw.call_info != ci) return error.StaleLanguageFrame;
    const rows = try a.alloc(named.Row, raw.count);
    for (raw.items[0..raw.count], rows) |item, *out| {
        const value = &item.value;
        const children = try a.alloc(named.Child, value.item_count);
        for (value.items[0..value.item_count], children) |child, *dest| dest.* = .{
            .key = try a.dupe(u8, std.mem.sliceTo(&child.key, 0)),
            .type = try a.dupe(u8, std.mem.sliceTo(&child.type, 0)),
            .display = try a.dupe(u8, std.mem.sliceTo(&child.display, 0)),
            .address = if (child.address != 0) child.address else null,
            .diagnostic = try reason(a, child.reason),
            .advisory = child.advisory != 0,
        };
        out.* = .{
            .name = try a.dupe(u8, std.mem.sliceTo(&item.name, 0)),
            .name_diagnostic = try reason(a, item.reason),
            .scope = switch (item.kind) {
                c.XL_LOCAL => .local,
                c.XL_VARARGS => .vararg,
                else => .upvalue,
            },
            .ordinal = item.ordinal,
            .address = if (item.address != 0) item.address else null,
            .value = .{
                .count = if (item.kind == c.XL_VARARGS) value.count else null,
                .type = try a.dupe(u8, std.mem.sliceTo(&value.type, 0)),
                .display = try a.dupe(u8, std.mem.sliceTo(&value.display, 0)),
                .diagnostic = try reason(a, value.reason),
                .advisory = value.advisory != 0,
                .truncated = value.truncated != 0,
                .children = children,
            },
        };
    }
    try session.target.expectGeneration(observed.generation);
    return .{
        .generation = observed.generation,
        .tid = tid,
        .language = .lua,
        .segment = segment_index,
        .frame = frame,
        .start = raw.start,
        .total = raw.total,
        .truncated = raw.truncated != 0,
        .rows = rows,
        .diagnostic = try reason(a, raw.reason),
        .runtime_version = segment.runtime.version,
        .runtime_build_id = segment.runtime.build_id,
        .basis = try std.fmt.allocPrint(a, "{s}; active LocVar scopes and closure upvalues; bounded retained memory; no target calls", .{segment.runtime.layout_source}),
        .memory_reads = r.reads,
        .memory_bytes = r.bytes,
    };
}

/// A location watch re-resolves storage at every stop. CallInfo/prototype
/// matching does not prove an activation survived unseen between stops.
pub const WatchCapture = @import("watch.zig").Capture;
fn watchValue(session: *model.Session, a: A, capture: *WatchCapture, frame: usize, page: ?usize) !void {
    const module = try runtimeModule(session);
    if (module.id != capture.scope.runtime[0]) return error.LuaWatchRuntimeChanged;
    const layout = try profile(session, module);
    var r = reader(session);
    const raw = try a.create(c.struct_xl_locals);
    const state = capture.scope.runtime[1];
    if (page) |index| {
        c.xl_locals_read(layout, &r, state, frame, index, 1, raw);
    } else if (capture.scope.frame[2] == 0) {
        c.xl_local_find(layout, &r, state, frame, capture.expression, raw);
    } else {
        c.xl_local_binding(layout, &r, state, frame, if (capture.scope.frame[2] == 1) c.XL_LOCAL else c.XL_UPVALUE, @intCast(capture.scope.frame[3]), raw);
    }
    defer {
        capture.reads = r.reads;
        capture.bytes = r.bytes;
    }
    if (raw.call_info != 0 and raw.call_info != capture.scope.frame[0]) return error.StaleLanguageFrame;
    const why: [*c]const u8 = if (raw.reason != null) raw.reason else if (raw.count != 1) "LuaWatchBindingUnavailable" else raw.items[0].reason;
    if (why) |message| {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(message));
        return;
    }
    const item = &raw.items[0];
    if (item.kind == c.XL_VARARGS or (item.address == 0 and item.path_absent == 0)) return error.LuaWatchBindingHasNoStorage;
    if (item.name_truncated != 0) return error.LuaWatchNameTruncated;
    if (page != null) {
        capture.expression = try a.dupeZ(u8, std.mem.sliceTo(&item.name, 0));
        if (capture.expression.len > c.XLW_EXPRESSION) return error.LuaWatchNameTooLong;
        capture.scope.frame[2] = if (item.kind == c.XL_LOCAL) 1 else 2;
        capture.scope.frame[3] = item.declaration;
    }
    const bytes = try a.alloc(u8, c.XL_SAMPLE_BYTES);
    var length: usize = 0;
    var kind: c.enum_xl_sample_kind = undefined;
    if (c.xl_local_sample(layout, &r, item, bytes.ptr, bytes.len, &length, &kind)) |message| {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(message));
        return;
    }
    capture.observation = c.XLW_COMPLETE;
    capture.sample = .{ .kind = kind, .bytes = bytes.ptr, .size = length, .type = (try a.dupeZ(u8, std.mem.sliceTo(&item.value.type, 0))).ptr, .display = (try a.dupeZ(u8, std.mem.sliceTo(&item.value.display, 0))).ptr };
}
pub fn watchExpression(a: A, expression: ?[]const u8, row: ?usize) ![:0]const u8 {
    if ((expression == null) == (row == null)) return error.InvalidArguments;
    if (expression) |text| if (text.len == 0 or text.len > c.XLW_EXPRESSION or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArguments;
    if (row) |index| if (index >= 4096) return error.InvalidArguments;
    const checked_expression = try a.dupeZ(u8, expression orelse "binding");
    if (expression != null and c.xl_expression_valid(checked_expression) == 0) return error.LuaExpressionUnsupported;
    return checked_expression;
}
pub fn createWatch(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, expression: ?[]const u8, row: ?usize) !WatchCapture {
    const checked_expression = try watchExpression(a, expression, row);
    const observed = try @import("../model/language_selection.zig").cachedRead(.lua, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment = observed.segments[segment_index];
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const selected = segment.frames[frame];
    if (!selected.identity_proved or !std.mem.eql(u8, selected.kind, "Lua") or selected.prototype == null) return error.LuaWatchFrameUnproved;
    const stable_thread = for (session.target.threadSlice()) |thread| {
        if (thread.tid == tid) break thread.id;
    } else return error.InvalidThread;
    var capture = WatchCapture{ .scope = .{ .language = c.XLW_LUA, .session = session.id, .image = session.target.snapshot().image_epoch, .thread = stable_thread, .runtime = .{ (try runtimeModule(session)).id, try std.fmt.parseInt(u64, segment.runtime_instance.address, 0), 0, 0 }, .frame = .{ try std.fmt.parseInt(u64, selected.call_info, 0), try std.fmt.parseInt(u64, selected.prototype.?, 0), 0, 0 } }, .expression = checked_expression };
    try watchValue(session, a, &capture, frame, row);
    // A row whose binding cannot be established must not become a name watch.
    if (row != null and capture.scope.frame[2] == 0) return error.LuaWatchBindingUnavailable;
    try session.target.expectGeneration(observed.generation);
    return capture;
}
pub fn observeWatch(session: *model.Session, a: A, tid: i32, scope: c.struct_xlw_scope, expression: []const u8) !WatchCapture {
    var capture = WatchCapture{ .scope = scope, .expression = try a.dupeZ(u8, expression) };
    const observed = try @import("../model/language_selection.zig").cachedRead(.lua, session, tid);
    const module_id = (try runtimeModule(session)).id;
    if (module_id != scope.runtime[0]) {
        capture.scope.runtime[0] = module_id;
        capture.diagnostic = try a.dupeZ(u8, "LuaWatchRuntimeChanged");
        return capture;
    }
    for (observed.segments) |segment| {
        if (try std.fmt.parseInt(u64, segment.runtime_instance.address, 0) != scope.runtime[1]) continue;
        for (segment.frames, 0..) |frame, index| {
            if (try std.fmt.parseInt(u64, frame.call_info, 0) != scope.frame[0]) continue;
            if (!frame.identity_proved) {
                capture.diagnostic = try a.dupeZ(u8, frame.reason orelse "LuaWatchFrameUnproved");
                return capture;
            }
            if (frame.prototype == null or try std.fmt.parseInt(u64, frame.prototype.?, 0) != scope.frame[1]) break;
            try watchValue(session, a, &capture, index, null);
            try session.target.expectGeneration(observed.generation);
            return capture;
        }
        // Only a complete canonical CallInfo walk establishes absence. Native
        // pairing may remain partial independently of that walk.
        if (segment.chain_complete) {
            capture.observation = c.XLW_FRAME_GONE;
            capture.diagnostic = try a.dupeZ(u8, "LuaWatchFrameGone");
        } else capture.diagnostic = try a.dupeZ(u8, segment.reason orelse "LuaWatchFrameUnproved");
        try session.target.expectGeneration(observed.generation);
        return capture;
    }
    capture.diagnostic = try a.dupeZ(u8, "LuaWatchCoroutineNotObserved");
    return capture;
}
