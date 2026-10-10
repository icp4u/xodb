//! Retained-stop adapter for the C Emacs Lisp reader. No target evaluation.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const Module = @import("../model/modules.zig").Module;
const A = std.mem.Allocator;
fn read(ctx: ?*anyopaque, at: u64, out: ?*anyopaque, n: usize) callconv(.c) c_int {
    const session: *model.Session = @ptrCast(@alignCast(ctx.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(at, bytes[0..n]) catch return -1) == n) 0 else -1;
}
fn reader(session: *model.Session) c.struct_xel_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
fn reason(a: A, value: [*c]const u8) !?[]const u8 {
    return if (value == null) null else try a.dupe(u8, std.mem.span(value));
}
fn buildId(a: A, layout: *const c.struct_xel_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
fn runtimeModule(session: *model.Session) !*Module {
    // Initial profile: a standalone/static Emacs Lisp executable, identified by
    // kernel PHDR evidence. A shared-library runtime stays unavailable.
    const runtime = @import("../target/runtime.zig");
    var loader = std.mem.zeroes(runtime.c.struct_xrt_loader);
    _ = runtime.c.xrt_target_loader(session.target.handle, &loader, null);
    if (loader.main_phdr == 0) return error.ElispModuleIdentityUnavailable;
    const module = session.modules.at(loader.main_phdr) catch return error.ElispModuleIdentityUnavailable;
    if (module.symbols().findSymbol("emacs_version") == null or module.symbols().findSymbol("Fdebugger_trap") == null) return error.ElispStaticRuntimeUnavailable;
    return module;
}
fn constant(session: *model.Session, module: *Module, name: []const u8, expected: []const u8) !void {
    const sym = module.symbols().findSymbol(name) orelse return error.ElispVersionUnavailable;
    if (!sym.hasAddress() or sym.size != expected.len + 1 or sym.size > 128) return error.ElispVersionUnsupported;
    var loaded: [128]u8 = undefined;
    const size: usize = @intCast(sym.size);
    if (try session.target.readMemory(try module.runtimeAddress(sym.value), loaded[0..size]) != size) return error.ElispVersionUnavailable;
    if (loaded[size - 1] != 0 or !std.mem.eql(u8, loaded[0 .. size - 1], expected)) return error.ElispVersionUnsupported;
    for (0..module.image.header.segment_count) |i| {
        const seg = try module.image.segment(@intCast(i));
        if (seg.type != .load or sym.value < seg.vaddr) continue;
        const off = sym.value - seg.vaddr;
        if (off > seg.file_size or size > seg.file_size - off) continue;
        const data = try module.image.segmentData(seg);
        if (!std.mem.eql(u8, data[@intCast(off)..][0..size], loaded[0..size])) return error.ElispVersionMismatch;
        return;
    }
    return error.ElispVersionUnavailable;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xel_layout {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.ElispArchitectureUnsupported;
    const id = module.image.buildId() orelse return error.ElispBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.ElispBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.ElispBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.ElispBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.target.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len])) return error.ElispBuildIdMismatch;
    try constant(session, module, "emacs_version", c.XEL_VERSION);
    if (module.elisp_layout == null) {
        const debug = module.debugInfo() catch |err| return if (err == error.DebugMetadataPending) err else error.ElispDwarfUnavailable;
        var layout: c.struct_xel_layout = undefined;
        if (c.xel_layout_build(debug.dwarf, id.ptr, id.len, c.XEL_VERSION, &layout)) |why| {
            inline for (.{ error.ElispDwarfMalformed, error.ElispDwarfWorkLimit, error.ElispDwarfAmbiguous, error.ElispDwarfTypesUnavailable, error.ElispDwarfConstantsUnavailable, error.ElispConstantMismatch, error.ElispRuntimeMultiple }) |err| {
                if (std.mem.eql(u8, std.mem.span(why), @errorName(err))) return err;
            }
            return error.ElispLayoutUnsupported;
        }
        module.elisp_layout = layout;
    }
    return &module.elisp_layout.?;
}
fn globalAddress(module: *Module, name: []const u8) !u64 {
    const sym = module.symbols().findSymbol(name) orelse return error.ElispRuntimeSymbolsUnavailable;
    if (!sym.hasAddress()) return error.ElispRuntimeSymbolsUnavailable;
    return module.runtimeAddress(sym.value);
}
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    return .{ .version = c.XEL_VERSION, .build_id = try buildId(a, layout), .basis = "same-image DWARF + loaded identity" };
}
pub const Anchor = struct { frame: usize, pc: []const u8, symbol: []const u8 };
pub const Runtime = struct { language: []const u8 = "elisp", implementation: []const u8 = "GNU Emacs", version: []const u8 = c.XEL_VERSION, build_id: []const u8, layout_source: []const u8 = "same-image DWARF" };
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "elisp:thread_state", address: []const u8, scope: []const u8 = "main native thread at this retained stop only" };
pub const Frame = struct {
    name: []const u8,
    name_reason: ?[]const u8,
    file: ?[]const u8 = null,
    line: ?u32 = null,
    kind: []const u8 = "native/unknown",
    reason: ?[]const u8,
    record: []const u8,
    function: []const u8,
    args: []const u8,
    depth: u64,
    argument_count: ?u64,
    arguments_unevaluated: bool,
    kind_basis: ?[]const u8,
    active_function: ?[]const u8,
    native_binding: ?Anchor,
    provenance: []const u8 = "external_read",
};
pub const Control = struct {
    kind: []const u8,
    runtime_kind: u32,
    record: []const u8,
    depth: ?u64,
    frame: ?usize,
    reason: ?[]const u8,
};
pub const Segment = struct {
    runtime: Runtime,
    runtime_instance: Instance,
    anchor: ?Anchor,
    additional_anchors: []Anchor,
    frames: []Frame,
    controls: []Control,
    chain_complete: bool,
    state: []const u8 = "partial",
    reason: ?[]const u8,
    classification_reason: ?[]const u8,
    memory_reads: usize,
    memory_bytes: usize,
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    segments: []Segment,
    native_stack_incomplete: bool,
    basis: []const u8 = "main-thread specpdl; unique native argument bindings and bytecode saved-slot proofs when available; segment links otherwise; no target calls",
};
pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (session.target.gdbRemoteInfo() != null) return error.ElispThreadAssociationUnproved;
    const snap = session.target.snapshot();
    if (snap.state != .stopped) return error.NotStopped;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var context = try readContext(module);
    var r = reader(session);
    const raw = try a.create(c.struct_xel_stack);
    c.xel_stack_main(layout, &r, &context, try globalAddress(module, "current_thread"), try globalAddress(module, "main_thread"), snap.pid, tid, raw);
    if (raw.reason != null and raw.count == 0) {
        inline for (.{ error.ElispThreadAssociationUnproved, error.ElispStateChanged, error.ElispSpecpdlInvalid, error.ElispSpecpdlLimit, error.ElispMemoryUnavailable, error.ElispTagConstantsMismatch, error.ElispReadLimit }) |err| {
            if (std.mem.eql(u8, std.mem.span(raw.reason), @errorName(err))) return err;
        }
        return error.ElispStackUnavailable;
    }
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    var anchors: std.ArrayList(Anchor) = .empty;
    var activations: [64]c.struct_xel_activation = undefined;
    var activation_count: usize = 0;
    for (native[first..]) |f| {
        const symbol = f.symbol orelse continue;
        if (!std.mem.eql(u8, symbol, "Ffuncall") and !std.mem.eql(u8, symbol, "exec_byte_code") and !std.mem.eql(u8, symbol, "eval_sub") and !std.mem.eql(u8, symbol, "funcall_lambda") and !std.mem.eql(u8, symbol, "funcall_subr") and !std.mem.eql(u8, symbol, "apply_lambda")) continue;
        if ((session.modules.at(f.pc) catch continue) != module) continue;
        try anchors.append(a, .{ .frame = f.index, .pc = try hex(a, f.pc), .symbol = try a.dupe(u8, symbol) });
        if (std.mem.eql(u8, symbol, "funcall_lambda") or std.mem.eql(u8, symbol, "apply_lambda")) {
            if (nativeActivation(session, a, module, native, f) catch |err| result: {
                if (err == error.OutOfMemory) return err;
                break :result null;
            }) |activation| {
                activations[activation_count] = activation;
                activation_count += 1;
            }
        }
    }
    c.xel_stack_kinds(layout, &r, &context, &activations, activation_count, raw);
    const frames = try a.alloc(Frame, raw.count);
    for (raw.frames[0..raw.count], frames) |v, *out| out.* = .{
        .name = try a.dupe(u8, std.mem.sliceTo(&v.name, 0)),
        .name_reason = try reason(a, v.name_reason),
        .kind = switch (v.execution_kind) {
            c.XEL_INTERPRETED => "interpreted",
            c.XEL_BYTECODE => "bytecode",
            else => "native/unknown",
        },
        .kind_basis = try reason(a, v.kind_basis),
        .active_function = if (v.active_function == 0) null else try hex(a, v.active_function),
        .native_binding = if (v.execution_kind != c.XEL_UNKNOWN and v.native_frame < native.len) .{ .frame = v.native_frame, .pc = try hex(a, native[v.native_frame].pc), .symbol = try a.dupe(u8, native[v.native_frame].symbol orelse "") } else null,
        .reason = try reason(a, v.kind_reason),
        .record = try hex(a, v.record),
        .function = try hex(a, v.function),
        .args = try hex(a, v.args),
        .depth = v.depth,
        .argument_count = if (v.nargs < 0) null else @intCast(v.nargs),
        .arguments_unevaluated = v.nargs < 0,
    };
    const controls = try a.alloc(Control, raw.control_count);
    for (raw.controls[0..raw.control_count], controls) |v, *out| out.* = .{
        .kind = if (v.kind == c.XEL_UNWIND) "unwind cleanup" else switch (v.runtime_kind) {
            c.XEL_C_CATCHER => "catch",
            c.XEL_C_CONDITION_CASE => "condition-case",
            c.XEL_C_CATCHER_ALL => "catch all",
            c.XEL_C_CATCHER_ALL_DEBUGGABLE => "catch all debuggable",
            c.XEL_C_HANDLER_BIND => "handler-bind",
            else => "skip conditions",
        },
        .runtime_kind = v.runtime_kind,
        .record = try hex(a, v.record),
        .depth = if (v.depth == std.math.maxInt(u64)) null else v.depth,
        .frame = if (v.frame == std.math.maxInt(usize)) null else v.frame,
        .reason = try reason(a, v.reason),
    };
    const segments = try a.alloc(Segment, 1);
    const all_anchors = try anchors.toOwnedSlice(a);
    segments[0] = .{
        .runtime = .{ .build_id = try buildId(a, layout) },
        .runtime_instance = .{ .address = try hex(a, raw.thread) },
        .anchor = if (all_anchors.len == 0) null else all_anchors[0],
        .additional_anchors = if (all_anchors.len == 0) &.{} else all_anchors[1..],
        .frames = frames,
        .controls = controls,
        .chain_complete = raw.reason == null,
        .reason = (try reason(a, raw.reason)) orelse "ElispNativePairingUnproved",
        .classification_reason = try reason(a, raw.classification_reason),
        .memory_reads = r.reads,
        .memory_bytes = r.bytes,
    };
    try session.target.expectGeneration(snap.generation);
    return .{ .session_id = session.id, .generation = snap.generation, .tid = tid, .segments = segments, .native_stack_incomplete = native.len == 64 or native[native.len - 1].diagnostic != null };
}

fn nativeActivation(session: *model.Session, a: A, module: *Module, native: []const model.Frame, frame: model.Frame) !?c.struct_xel_activation {
    // A saved backtrace can briefly outlive its callee while returning. Require
    // a live evaluator child; an object changed in place must agree with this
    // path as well as the unique argument storage.
    if (frame.index == 0) return null;
    var child = frame.index - 1;
    if (std.mem.eql(u8, frame.symbol orelse "", "apply_lambda") and std.mem.eql(u8, native[child].symbol orelse "", "funcall_lambda")) {
        if (child == 0 or (session.modules.at(native[child].pc) catch return null) != module) return null;
        child -= 1;
    }
    if ((session.modules.at(native[child].pc) catch return null) != module) return null;
    const symbol = native[child].symbol orelse return null;
    const kind: u32 = if (std.mem.eql(u8, symbol, "exec_byte_code")) c.XEL_BYTECODE else if (std.mem.eql(u8, symbol, "eval_sub") or std.mem.eql(u8, symbol, "Fprogn")) c.XEL_INTERPRETED else return null;
    const locals = try session.frameLocals(a, frame);
    const argc = if (std.mem.eql(u8, frame.symbol orelse "", "apply_lambda")) "numargs" else "nargs";
    var values: [3]?u64 = @splat(null);
    for (locals) |local| {
        const slot: usize = if (std.mem.eql(u8, local.name, "fun")) 0 else if (std.mem.eql(u8, local.name, "arg_vector")) 1 else if (std.mem.eql(u8, local.name, argc)) 2 else continue;
        if (local.value.type.size != 8) continue;
        if (slot == 0 and (!local.parameter or local.value.type.kind != .pointer or !std.mem.eql(u8, local.value.type.name, "Lisp_Object"))) continue;
        if (slot == 1) {
            if (local.value.type.kind != .pointer) continue;
            const child_type = local.value.type.child orelse continue;
            if (!std.mem.eql(u8, child_type.name, "Lisp_Object")) continue;
        }
        if (slot == 2 and local.value.type.kind != .signed) continue;
        const v = try session.evaluateInFrame(a, frame, locals, local.name);
        if (v.availability != .available) continue;
        if (values[slot] != null) return null;
        values[slot] = v.bits;
    }
    return .{ .function = values[0] orelse return null, .args = values[1] orelse return null, .nargs = @bitCast(values[2] orelse return null), .native_frame = frame.index, .execution_kind = kind };
}

pub fn preview(session: *model.Session, a: A, value: @import("../model/evaluate.zig").Value) !?@import("../model/value_view.zig").Preview {
    const view = @import("../model/value_view.zig");
    if (value.availability != .available or !value.type.elisp_object or value.type.kind != .pointer or value.type.size != 8) return null;
    const snap = session.target.snapshot();
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var context = try readContext(module);
    var r = reader(session);
    const raw = try a.create(c.struct_xel_value);
    c.xel_value_read(layout, &r, &context, value.bits, raw);
    const after = session.target.snapshot();
    if (after.state != .stopped or after.generation != snap.generation) return error.StaleSnapshot;
    const items = try a.alloc(view.ElispItem, raw.item_count);
    for (raw.items[0..raw.item_count], items) |item, *out| out.* = .{
        .tagged = item.tagged,
        .key = try a.dupe(u8, std.mem.sliceTo(&item.key, 0)),
        .type = try a.dupe(u8, std.mem.sliceTo(&item.type, 0)),
        .display = try a.dupe(u8, std.mem.sliceTo(&item.display, 0)),
        .diagnostic = try reason(a, item.reason),
    };
    return .{
        .presentation = .scalar,
        .data_address = raw.object,
        .count = raw.count,
        .element_type = value.type.name,
        .truncated = raw.truncated != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = "Emacs Lisp_Object typedef; loaded identity and same-image DWARF; bounded stopped memory; no target calls",
        .elisp = .{ .type = try a.dupe(u8, std.mem.sliceTo(&raw.type, 0)), .display = try a.dupe(u8, std.mem.sliceTo(&raw.display, 0)), .tagged = value.bits, .object = raw.object, .runtime_version = c.XEL_VERSION, .runtime_build_id = try buildId(a, layout), .memory_reads = r.reads, .memory_bytes = r.bytes, .items = items },
    };
}

fn readContext(module: *Module) !c.struct_xel_context {
    var context = std.mem.zeroes(c.struct_xel_context);
    context.lispsym = try globalAddress(module, "lispsym");
    inline for (.{ "USE_LSB_TAG", "GCTYPEBITS", "INTTYPEBITS", "VALMASK", "PSEUDOVECTOR_FLAG", "ARRAY_MARK_FLAG", "Qnil" }, 0..) |name, i|
        context.globals[i] = try globalAddress(module, name);
    return context;
}
const named = @import("../model/language_locals.zig");
pub fn readLocals(session: *model.Session, a: A, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !named.Result {
    const observed = try @import("../model/language_selection.zig").cachedRead(.elisp, session, tid);
    if (segment != 0 or observed.segments.len != 1) return error.InvalidLanguageSegment;
    if (frame >= observed.segments[0].frames.len) return error.InvalidLanguageFrame;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var context = try readContext(module);
    var r = reader(session);
    const raw_stack = try a.create(c.struct_xel_stack);
    c.xel_stack_main(layout, &r, &context, try globalAddress(module, "current_thread"), try globalAddress(module, "main_thread"), session.target.snapshot().pid, tid, raw_stack);
    if (frame >= raw_stack.count or c.xel_stack_frames_available(raw_stack) == 0) return error.ElispBindingFrameUnavailable;
    const selected = observed.segments[0].frames[frame];
    if (raw_stack.frames[frame].record != try std.fmt.parseInt(u64, selected.record, 0) or
        raw_stack.frames[frame].function != try std.fmt.parseInt(u64, selected.function, 0)) return error.StaleLanguageFrame;
    const raw = try a.create(c.struct_xel_bindings);
    var reads = r.reads;
    var bytes = r.bytes;
    r = reader(session);
    c.xel_bindings_read(layout, &r, &context, raw_stack, frame, try globalAddress(module, "Qinternal_interpreter_environment"), raw);
    reads += r.reads;
    bytes += r.bytes;
    const first = @min(start, raw.count);
    const last = @min(raw.count, first + limit);
    const rows = try a.alloc(named.Row, last - first);
    const shown = try a.create(c.struct_xel_value);
    for (raw.rows[first..last], rows, first..) |item, *out, ordinal| {
        var value = named.Value{ .type = "unavailable", .display = "unavailable", .diagnostic = try reason(a, item.reason) };
        var object: ?u64 = null;
        if (item.has_value != 0) {
            var preview_reader = reader(session);
            c.xel_value_read(layout, &preview_reader, &context, item.value, shown);
            reads += preview_reader.reads;
            bytes += preview_reader.bytes;
            const children = try a.alloc(named.Child, shown.item_count);
            for (shown.items[0..shown.item_count], children) |child, *dest| dest.* = .{
                .key = try a.dupe(u8, std.mem.sliceTo(&child.key, 0)),
                .type = try a.dupe(u8, std.mem.sliceTo(&child.type, 0)),
                .display = try a.dupe(u8, std.mem.sliceTo(&child.display, 0)),
                .address = null,
                .diagnostic = try reason(a, child.reason),
                .advisory = true,
            };
            value = .{
                .count = shown.count,
                .type = try a.dupe(u8, std.mem.sliceTo(&shown.type, 0)),
                .display = try a.dupe(u8, std.mem.sliceTo(&shown.display, 0)),
                .diagnostic = try reason(a, shown.reason),
                .truncated = shown.truncated != 0,
                .children = children,
            };
            if (shown.object != 0) object = shown.object;
        }
        out.* = .{
            .name = try a.dupe(u8, std.mem.sliceTo(&item.name, 0)),
            .name_diagnostic = if (item.has_value != 0) try reason(a, item.reason) else null,
            .scope = if (item.scope == c.XEL_LEXICAL) .lexical else .dynamic,
            .ordinal = ordinal,
            .address = object,
            .slot_address = if (item.has_value != 0) item.slot else null,
            .context_address = if (item.environment != 0) item.environment & ~@as(u64, 7) else null,
            .provenance = if (item.scope == c.XEL_LEXICAL) "saved interpreter environment" else "specpdl binding and nearest younger saved value or live symbol slot",
            .value = value,
        };
    }
    try session.target.expectGeneration(observed.generation);
    return .{
        .generation = observed.generation,
        .tid = tid,
        .language = .elisp,
        .segment = segment,
        .frame = frame,
        .start = first,
        .total = raw.count,
        .truncated = raw.truncated != 0,
        .rows = rows,
        .diagnostic = try reason(a, raw.reason),
        .lexical_visibility = "saved interpreter environments only; optimized bytecode/native locals unproved",
        .runtime_version = c.XEL_VERSION,
        .runtime_build_id = try buildId(a, layout),
        .basis = "same-image DWARF; per-frame dynamic bindings and saved interpreter environments; no target evaluation or rewinding",
        .memory_reads = reads,
        .memory_bytes = bytes,
    };
}
