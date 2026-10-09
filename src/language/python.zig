//! Owner-thread adapter for the memory-only C CPython reader. No target code
//! is called. Native anchors and logical frames remain separate observations;
//! an anchor is cited only when the activation's entry frame lies inside that
//! native frame's [sp, cfa) on the stopped thread's stack.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const Module = @import("../model/modules.zig").Module;
const eval = @import("../model/evaluate.zig");
const view = @import("../model/value_view.zig");
const A = std.mem.Allocator;

fn read(ctx: ?*anyopaque, address: u64, out: ?*anyopaque, n: usize) callconv(.c) c_int {
    const session: *model.Session = @ptrCast(@alignCast(ctx.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(address, bytes[0..n]) catch return -1) == n) 0 else -1;
}
fn reader(session: *model.Session) c.struct_xpy_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, address: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{address});
}
fn buildId(a: A, layout: *const c.struct_xpy_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 15];
    }
    return out;
}
fn versionText(a: A, v: u64) ![]const u8 {
    const level: u64 = (v >> 4) & 15;
    const suffix = switch (level) {
        0xa => "a",
        0xb => "b",
        0xc => "rc",
        else => "",
    };
    if (level == 0xf) return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ (v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255 });
    return std.fmt.allocPrint(a, "{d}.{d}.{d}{s}{d}", .{ (v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, suffix, v & 15 });
}
fn text(a: A, bytes: []const u8) ![]const u8 {
    // The C reader writes UTF-8 (surrogates escaped); keep a guard anyway.
    if (std.unicode.utf8ValidateSlice(bytes)) return a.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| {
        if (b >= 32 and b < 127 and b != '\\') try out.append(a, b) else {
            var buf: [4]u8 = undefined;
            try out.appendSlice(a, try std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{b}));
        }
    }
    return out.toOwnedSlice(a);
}
fn reason(a: A, ptr: [*c]const u8) !?[]const u8 {
    return if (ptr == null) null else try a.dupe(u8, std.mem.span(ptr));
}
fn published(session: *model.Session, module: *Module, runtime: u64, link: u64, out: *[c.XPY_DEBUG_OFFSETS_BYTES]u8) !void {
    if (try session.target.readMemory(runtime, out) != out.len) return error.PythonDebugOffsetsUnavailable;
    // The loaded offsets must be the image's own static initializer.
    const section = module.image.sectionByName(".PyRuntime") orelse return error.PythonDebugOffsetsUnverified;
    if (link < section.addr or link - section.addr > section.size or section.size - (link - section.addr) < out.len) return error.PythonDebugOffsetsUnverified;
    const data = try module.image.sectionData(section);
    const start: usize = @intCast(link - section.addr);
    if (data.len < start + out.len) return error.PythonDebugOffsetsUnverified;
    const positions = c.xpy_published_positions(std.mem.readInt(u64, out[8..16], .little)) orelse return error.PythonVersionUnsupported;
    var extent: usize = 24;
    for (positions[0..c.XPY_PUBLISHED_COUNT]) |p| extent = @max(extent, @as(usize, p) + 8);
    if (!std.mem.eql(u8, data[start .. start + extent], out[0..extent])) return error.PythonDebugOffsetsMismatch;
}
fn refusal(name: []const u8) anyerror {
    const known = [_]struct { []const u8, anyerror }{
        .{ "PythonVersionUnsupported", error.PythonVersionUnsupported },
        .{ "PythonStackRefUnsupported", error.PythonStackRefUnsupported },
        .{ "PythonFreeThreadedUnsupported", error.PythonFreeThreadedUnsupported },
        .{ "PythonLayoutUnverified", error.PythonLayoutUnverified },
        .{ "PythonLayoutMismatch", error.PythonLayoutMismatch },
        .{ "PythonDebugOffsetsLayoutMismatch", error.PythonDebugOffsetsLayoutMismatch },
        .{ "PythonDwarfTypesUnavailable", error.PythonDwarfTypesUnavailable },
        .{ "PythonDebugOffsetsUnavailable", error.PythonDebugOffsetsUnavailable },
        .{ "PythonDebugOffsetsInvalid", error.PythonDebugOffsetsInvalid },
    };
    for (known) |k| if (std.mem.eql(u8, name, k[0])) return k[1];
    return error.PythonLayoutUnsupported;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xpy_layout {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.PythonArchitectureUnsupported;
    if (module.symbols().findSymbol("_Py_stackref_get_object")) |debug_ref| {
        if (debug_ref.hasAddress()) return error.PythonStackRefUnsupported;
    }
    const id = module.image.buildId() orelse return error.PythonBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.PythonBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.PythonBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.PythonBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.target.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len]))
        return error.PythonBuildIdMismatch;
    const symbol = module.symbols().findSymbol("_PyRuntime") orelse return error.PythonRuntimeUnavailable;
    if (!symbol.hasAddress()) return error.PythonRuntimeUnavailable;
    const runtime = try module.runtimeAddress(symbol.value);
    var bytes: [c.XPY_DEBUG_OFFSETS_BYTES]u8 = undefined;
    try published(session, module, runtime, symbol.value, &bytes);
    if (module.python_layout == null) {
        // DWARF is optional only for a final release (checked in C).
        const dwarf: ?*c.Dwarf = if (module.debugInfo()) |debug| debug.dwarf else |_| null;
        var layout: c.struct_xpy_layout = undefined;
        if (c.xpy_layout_build(&bytes, bytes.len, dwarf, id.ptr, id.len, &layout)) |why| {
            return refusal(std.mem.span(why));
        }
        for (0..c.XPY_TYPE_COUNT) |i| {
            const type_symbol = module.symbols().findSymbol(std.mem.span(c.xpy_type_symbols[i])) orelse return error.PythonTypeSymbolsUnavailable;
            if (!type_symbol.hasAddress()) return error.PythonTypeSymbolsUnavailable;
            layout.types[i] = try module.runtimeAddress(type_symbol.value);
        }
        layout.runtime = runtime;
        module.python_layout = layout;
    }
    if (c.xpy_layout_check(&module.python_layout.?, &bytes, bytes.len, id.ptr, id.len)) |_| return error.PythonBuildIdMismatch;
    if (module.python_layout.?.runtime != runtime) return error.PythonBuildIdMismatch;
    return &module.python_layout.?;
}

pub const Anchor = struct {
    frame: usize,
    pc: []const u8,
    symbol: ?[]const u8,
    interpreter_loop_symbol: bool,
    entry_frame: []const u8,
    proof: []const u8 = "entry frame address inside this native frame's [sp, cfa)",
};
pub const Runtime = struct { language: []const u8 = "python", implementation: []const u8 = "cpython", version: []const u8, build_id: []const u8, layout: []const u8 };
pub const Instance = struct {
    kind: []const u8 = "address",
    namespace: []const u8 = "python:interpreter",
    address: []const u8,
    interpreter_id: u64,
    thread_state: []const u8,
    scope: []const u8 = "this process instance and retained stop; not stable identity",
};
pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: ?u32,
    code_kind: []const u8,
    owner: []const u8,
    kind: []const u8 = "interpreter",
    provenance: []const u8 = "external_read",
    frame_address: []const u8,
    code: []const u8,
    instruction: []const u8,
    reason: ?[]const u8,
    identity_proved: bool = false,
};
pub const Segment = struct {
    runtime: Runtime,
    runtime_instance: ?Instance,
    anchor: ?Anchor,
    source_kind: []const u8 = "stopped_snapshot",
    state: []const u8,
    reason: ?[]const u8,
    frames: []Frame,
    examined_frames: usize,
    chain_complete: bool = false,
    /// Symbolized interpreter-loop frames (not the innermost) that own no
    /// entry frame on the chain: their Python frames may be merged here.
    unanchored_loop_frames: []const usize = &.{},
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    segments: []Segment,
    native_stack_incomplete: bool,
    memory_reads: usize,
    memory_bytes: usize,
    basis: []const u8 = "CPython published _Py_DebugOffsets from the verified loaded image (build-id, cookie, version), per-version table for unpublished fields (DWARF-verified when present), retained stopped memory; anchors proved by entry-frame containment in native [sp, cfa); no inferior calls",
};
fn isLoop(name: []const u8) bool {
    const base = "_PyEval_EvalFrameDefault";
    return std.mem.eql(u8, name, base) or (std.mem.startsWith(u8, name, base) and name[base.len] == '.');
}
fn codeKind(flags: u32, name: []const u8) []const u8 {
    if (flags & 0x200 != 0) return "async_generator";
    if (flags & 0x80 != 0) return "coroutine";
    if (flags & 0x20 != 0) return "generator";
    if (std.mem.eql(u8, name, "<module>")) return "module";
    return "function";
}
fn ownerName(owner: u8) []const u8 {
    return switch (owner) {
        0 => "thread",
        1 => "generator",
        2 => "frame_object",
        else => "interpreter",
    };
}
fn runtimeOf(a: A, layout: *const c.struct_xpy_layout) !Runtime {
    return .{
        .version = try versionText(a, layout.version),
        .build_id = try buildId(a, layout),
        .layout = if (layout.dwarf_verified != 0) "published offsets + DWARF-verified table" else "published offsets + final-release table (no DWARF)",
    };
}
fn readRuntime(session: *model.Session, a: A, module: *Module, tid: i32, native: []const model.Frame, first: usize, segments: *std.ArrayList(Segment), totals: *[2]usize) !void {
    const layout = try profile(session, module);
    // Every native frame is a candidate: the proof is containment of the
    // entry frame in [sp, cfa), not a symbol name (stripped builds split the
    // loop into unnamed parts).
    var ranges: [c.XPY_MAX_RANGES]c.struct_xpy_range = undefined;
    const count = @min(native.len, ranges.len);
    for (native[0..count], ranges[0..count]) |frame, *range| {
        const sp = frame.registers[session.target.arch().sp()];
        range.* = if (sp != null and frame.cfa != null and frame.cfa.? > sp.?) .{ .low = sp.?, .high = frame.cfa.? } else .{ .low = 0, .high = 0 };
    }
    const raw = try a.create(c.struct_xpy_stack);
    var r = reader(session);
    c.xpy_stack_read(layout, &r, @intCast(tid), &ranges, count, first, raw);
    totals[0] += r.reads;
    totals[1] += r.bytes;
    const runtime = try runtimeOf(a, layout);
    if (raw.reason != null and raw.segment_count == 0) {
        try segments.append(a, .{ .runtime = runtime, .runtime_instance = null, .anchor = null, .state = "partial", .reason = try reason(a, raw.reason), .frames = &.{}, .examined_frames = 0 });
        return;
    }
    if (raw.thread_states == 0) {
        try segments.append(a, .{ .runtime = runtime, .runtime_instance = null, .anchor = null, .state = "partial", .reason = "PythonThreadStateUnavailable", .frames = &.{}, .examined_frames = 0 });
        return;
    }
    // Every raw segment, including those before `first`, so that skipped
    // activations still constrain the segments returned.
    const all = try a.alloc(Segment, raw.segment_count);
    for (raw.segments[0..raw.segment_count], all) |s, *seg| {
        var anchor: ?Anchor = null;
        if (s.anchor >= 0) {
            const frame = native[@intCast(s.anchor)];
            anchor = .{
                .frame = frame.index,
                .pc = try hex(a, frame.pc),
                .symbol = if (frame.symbol) |name| try a.dupe(u8, name) else null,
                .interpreter_loop_symbol = if (frame.symbol) |name| isLoop(name) else false,
                .entry_frame = try hex(a, s.entry_frame),
            };
        }
        const frames = try a.alloc(Frame, s.count);
        for (raw.frames[s.first .. s.first + s.count], frames) |f, *out| {
            const name = try text(a, std.mem.sliceTo(&f.name, 0));
            out.* = .{
                .name = name,
                .file = if (f.file[0] != 0) try text(a, std.mem.sliceTo(&f.file, 0)) else null,
                .line = if (f.line > 0) f.line else null,
                .code_kind = codeKind(f.code_flags, name),
                .owner = ownerName(f.owner),
                .frame_address = try hex(a, f.address),
                .code = try hex(a, f.code),
                .instruction = try hex(a, f.instr),
                .reason = try reason(a, f.reason),
                .identity_proved = f.identity_proved != 0,
            };
        }
        // A whole-read limit is reported once, below; proven segments keep
        // their own state.
        seg.* = .{
            .runtime = runtime,
            .runtime_instance = .{ .address = try hex(a, s.interpreter), .interpreter_id = s.interpreter_id, .thread_state = try hex(a, s.thread_state) },
            .anchor = anchor,
            .state = if (s.reason == null) "complete" else "partial",
            .reason = try reason(a, s.reason),
            .frames = frames,
            .examined_frames = s.examined,
            .chain_complete = s.chain_complete != 0,
        };
    }
    // Only the innermost interpreter loop may lack its entry frame (prologue
    // or epilogue). Any other symbolized loop without one means the chain
    // skipped an activation: its frames could sit in the next outer segment.
    var orphans: std.ArrayList(usize) = .empty;
    var innermost = true;
    for (native[0..count], 0..) |frame, i| {
        const name = frame.symbol orelse continue;
        if (!isLoop(name)) continue;
        if (innermost) {
            innermost = false;
            continue;
        }
        if (raw.entry_found[i] == 0) try orphans.append(a, frame.index);
    }
    var unclaimed: std.ArrayList(usize) = .empty;
    for (orphans.items) |index| {
        var outer: ?*Segment = null;
        for (all) |*seg| if (seg.anchor) |anchor| if (anchor.frame > index and (outer == null or anchor.frame < outer.?.anchor.?.frame)) {
            outer = seg;
        };
        if (outer) |seg| {
            const list = try a.alloc(usize, seg.unanchored_loop_frames.len + 1);
            @memcpy(list[0..seg.unanchored_loop_frames.len], seg.unanchored_loop_frames);
            list[list.len - 1] = index;
            seg.unanchored_loop_frames = list;
            seg.state = "partial";
            seg.reason = "InterpreterLoopWithoutEntryFrame";
        } else try unclaimed.append(a, index);
    }
    for (all) |seg| {
        if (seg.anchor) |anchor| if (anchor.frame < first) continue;
        try segments.append(a, seg);
    }
    // Loops with no outer segment at all (a chain cut short or an unreadable
    // current frame): the stop must not look complete.
    if (unclaimed.items.len > 0) try segments.append(a, .{ .runtime = runtime, .runtime_instance = null, .anchor = null, .state = "partial", .reason = "InterpreterLoopWithoutEntryFrame", .frames = &.{}, .examined_frames = 0, .unanchored_loop_frames = try unclaimed.toOwnedSlice(a) });
    if (raw.reason != null) try segments.append(a, .{ .runtime = runtime, .runtime_instance = null, .anchor = null, .state = "partial", .reason = try reason(a, raw.reason), .frames = &.{}, .examined_frames = 0 });
}
fn anchorOrder(_: void, x: Segment, y: Segment) bool {
    const xi = if (x.anchor) |n| n.frame else std.math.maxInt(usize);
    const yi = if (y.anchor) |n| n.frame else std.math.maxInt(usize);
    return xi < yi;
}

pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (first >= 64) return error.InvalidFrame;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    var segments: std.ArrayList(Segment) = .empty;
    var totals = [2]usize{ 0, 0 };
    try readRuntime(session, a, try runtimeModule(session), tid, native, first, &segments, &totals);
    std.mem.sort(Segment, segments.items, {}, anchorOrder);
    try session.target.expectGeneration(generation);
    return .{
        .session_id = session.id,
        .generation = generation,
        .tid = tid,
        .segments = try segments.toOwnedSlice(a),
        .native_stack_incomplete = native.len == 64 or (native.len > 0 and native[native.len - 1].diagnostic != null),
        .memory_reads = totals[0],
        .memory_bytes = totals[1],
    };
}

// Type aliases carry no owning image id. Refuse ambiguous runtimes rather
// than choosing the first CPython image found in the mappings.
fn runtimeModule(session: *model.Session) !*Module {
    var chosen: ?*Module = null;
    if (session.modules.regions.items.len > 4096) return error.PythonModuleLimit;
    for (session.modules.regions.items) |r| {
        if ((r.offset != 0 and r.permissions[2] != 'x') or r.path.len == 0 or r.path[0] != '/') continue;
        const module = session.modules.load(r) catch |err| {
            if (err == error.NotElf or err == error.NoBinaryImage) continue;
            return error.PythonModuleIdentityUnavailable;
        };
        const symbol = module.symbols().findSymbol("_PyRuntime") orelse continue;
        if (!symbol.hasAddress()) continue;
        if (chosen) |previous| {
            if (previous.id == module.id) continue;
            return error.PythonRuntimeAmbiguous;
        } else chosen = module;
    }
    return chosen orelse error.PythonRuntimeUnavailable;
}
/// A DWARF struct that begins with a CPython object head: `ob_type` at 8,
/// or `ob_base` at 0 leading (recursively) to one.
fn objectHead(t: *const eval.Type, depth: u32) bool {
    if (t.kind != .structure or depth > 4 or t.size < 16) return false;
    for (t.fields) |f| {
        if (std.mem.eql(u8, f.name, "ob_type") and f.offset == 8 and f.type.kind == .pointer and f.type.size == 8) return true;
        if (std.mem.eql(u8, f.name, "ob_base") and f.offset == 0) return objectHead(f.type, depth + 1);
    }
    return false;
}
pub fn preview(session: *model.Session, a: A, value: eval.Value) !?view.Preview {
    if (value.availability != .available or value.type.kind != .pointer or value.bits == 0) return null;
    const child = value.type.child orelse return null;
    if (!objectHead(child, 0)) return null;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    // A non-Python program may have its own object-like structs.
    const module = runtimeModule(session) catch |err| return if (err == error.PythonRuntimeUnavailable) null else err;
    const layout = try profile(session, module);
    var r = reader(session);
    const raw = try a.create(c.struct_xpy_value);
    c.xpy_value_read(layout, &r, value.bits, raw);
    const items = try a.alloc(view.PythonItem, raw.item_count);
    for (raw.items[0..raw.item_count], items) |item, *out| out.* = .{
        .address = item.address,
        .key = try text(a, std.mem.sliceTo(&item.key, 0)),
        .type = try text(a, std.mem.sliceTo(&item.type, 0)),
        .display = try text(a, std.mem.sliceTo(&item.display, 0)),
        .diagnostic = try reason(a, item.reason),
    };
    return .{
        .presentation = .scalar,
        .data_address = value.bits,
        .count = raw.count,
        .element_type = child.name,
        .truncated = raw.truncated != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = "CPython object layout from the verified image's published offsets; stopped memory; no __repr__ or inferior calls",
        .python = .{
            .type = try text(a, std.mem.sliceTo(&raw.type, 0)),
            .display = try text(a, std.mem.sliceTo(&raw.display, 0)),
            .refcount = raw.refcount,
            .immortal = raw.immortal != 0,
            .type_object = raw.type_object,
            .runtime_version = try versionText(a, layout.version),
            .runtime_build_id = try buildId(a, layout),
            .items = items,
        },
    };
}

test "version text, code kinds and object heads" {
    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    try std.testing.expectEqualStrings("3.14.7", try versionText(fba.allocator(), 0x030e07f0));
    try std.testing.expectEqualStrings("3.16.0a0", try versionText(fba.allocator(), 0x031000a0));
    try std.testing.expectEqualStrings("3.15.0rc2", try versionText(fba.allocator(), 0x030f00c2));
    try std.testing.expectEqualStrings("coroutine", codeKind(0x80 | 0x20, "f"));
    try std.testing.expectEqualStrings("module", codeKind(0, "<module>"));
    try std.testing.expect(isLoop("_PyEval_EvalFrameDefault") and isLoop("_PyEval_EvalFrameDefault.cold") and !isLoop("_PyEval_EvalFrameDefaultX"));
    const pointer = eval.Type{ .name = "pointer", .kind = .pointer, .size = 8 };
    const head = eval.Type{ .name = "_object", .kind = .structure, .size = 16, .fields = &.{ .{ .name = "", .offset = 0, .type = &eval.int_type }, .{ .name = "ob_type", .offset = 8, .type = &pointer } } };
    const list = eval.Type{ .name = "PyListObject", .kind = .structure, .size = 40, .fields = &.{.{ .name = "ob_base", .offset = 0, .type = &head }} };
    const other = eval.Type{ .name = "pair", .kind = .structure, .size = 16, .fields = &.{ .{ .name = "a", .offset = 0, .type = &eval.int_type }, .{ .name = "ob_type", .offset = 0, .type = &pointer } } };
    try std.testing.expect(objectHead(&head, 0) and objectHead(&list, 0) and !objectHead(&other, 0));
}

/// Runtime identity and proof from the existing stopped-memory reader.
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const layout = try profile(session, try runtimeModule(session));
    const runtime = try runtimeOf(a, layout);
    return .{ .version = runtime.version, .build_id = runtime.build_id, .basis = runtime.layout };
}

/// Read a frame/code pair selected from the canonical stopped Python stack.
/// The C reader owns name, stackref, cell and bounded-value decoding.
pub fn readLocals(session: *model.Session, a: A, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !@import("../model/language_locals.zig").Result {
    return readBindings(session, a, tid, segment, frame, start, limit, null);
}
pub fn evaluateLocal(session: *model.Session, a: A, tid: i32, segment: usize, frame: usize, expression: []const u8) !@import("../model/language_locals.zig").Result {
    if (c.xpy_expression_valid(try a.dupeZ(u8, expression)) == 0) return error.UnsupportedLanguageExpression;
    return readBindings(session, a, tid, segment, frame, 0, 1, expression);
}

const WatchCapture = @import("watch.zig").Capture;
// The adapter owns the meanings of scope words: runtime = module/interpreter/
// interpreter-id/thread-state, frame = frame/code/selector-flags/declaration.
const watch_binding: u64 = 1;
const watch_generator: u64 = 2;
fn watchValue(session: *model.Session, a: A, capture: *WatchCapture, row: ?usize) !void {
    const module = try runtimeModule(session);
    if (module.id != capture.scope.runtime[0]) return error.PythonWatchRuntimeChanged;
    const layout = try profile(session, module);
    var r = reader(session);
    defer {
        capture.reads = r.reads;
        capture.bytes = r.bytes;
    }
    const raw = try a.create(c.struct_xpy_locals);
    if (row) |index| {
        c.xpy_locals_read(layout, &r, capture.scope.frame[0], capture.scope.frame[1], index, 1, raw);
    } else if (capture.scope.frame[2] & watch_binding != 0) {
        c.xpy_locals_read(layout, &r, capture.scope.frame[0], capture.scope.frame[1], @intCast(capture.scope.frame[3]), 1, raw);
    } else c.xpy_local_find(layout, &r, capture.scope.frame[0], capture.scope.frame[1], capture.expression, raw);
    if (raw.reason != null or raw.count != 1) {
        const why: [*c]const u8 = if (raw.reason != null) raw.reason else "PythonWatchBindingUnavailable";
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(why));
        return;
    }
    const item = &raw.items[0];
    if (item.name_reason != null) {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(item.name_reason));
        return;
    }
    if (row != null) {
        capture.expression = try a.dupeZ(u8, std.mem.sliceTo(&item.name, 0));
        if (capture.expression.len == 0 or capture.expression.len > c.XLW_EXPRESSION) return error.PythonWatchNameTooLong;
        capture.scope.frame[2] |= watch_binding;
        capture.scope.frame[3] = item.ordinal;
    }
    const bytes = try a.alloc(u8, c.XPY_SAMPLE_BYTES);
    var length: usize = 0;
    var kind: c.enum_xpy_sample_kind = undefined;
    if (c.xpy_local_sample(layout, &r, item, bytes.ptr, bytes.len, &length, &kind)) |why| {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(why));
        return;
    }
    capture.observation = c.XLW_COMPLETE;
    capture.sample = .{ .kind = kind, .bytes = bytes.ptr, .size = length, .type = (try a.dupeZ(u8, std.mem.sliceTo(&item.value.type, 0))).ptr, .display = (try a.dupeZ(u8, std.mem.sliceTo(&item.value.display, 0))).ptr };
}
pub fn createWatch(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, expression: ?[]const u8, row: ?usize) !WatchCapture {
    if ((expression == null) == (row == null)) return error.InvalidArguments;
    if (expression) |query| if (query.len == 0 or query.len > c.XLW_EXPRESSION or std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidArguments;
    if (row) |index| if (index >= c.XPY_MAX_LOCALS) return error.InvalidArguments;
    const checked_expression = try a.dupeZ(u8, expression orelse "binding");
    if (expression != null and c.xpy_expression_valid(checked_expression) == 0) return error.UnsupportedLanguageExpression;
    const observed = try @import("../model/language_selection.zig").cachedRead(.python, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment = observed.segments[segment_index];
    const instance = segment.runtime_instance orelse return error.PythonWatchRuntimeUnproved;
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const selected = segment.frames[frame];
    if (!selected.identity_proved) return error.PythonWatchFrameUnproved;
    const thread = for (session.target.threadSlice()) |entry| {
        if (entry.tid == tid) break entry.id;
    } else return error.InvalidThread;
    var capture = WatchCapture{ .scope = .{
        .language = c.XLW_PYTHON,
        .session = session.id,
        .image = session.target.snapshot().image_epoch,
        .thread = thread,
        .runtime = .{ (try runtimeModule(session)).id, try std.fmt.parseInt(u64, instance.address, 0), instance.interpreter_id, try std.fmt.parseInt(u64, instance.thread_state, 0) },
        .frame = .{ try std.fmt.parseInt(u64, selected.frame_address, 0), try std.fmt.parseInt(u64, selected.code, 0), if (std.mem.eql(u8, selected.owner, "generator")) watch_generator else 0, 0 },
    }, .expression = checked_expression };
    try watchValue(session, a, &capture, row);
    if (row != null and capture.scope.frame[2] & watch_binding == 0) return error.PythonWatchBindingUnavailable;
    try session.target.expectGeneration(observed.generation);
    return capture;
}
pub fn observeWatch(session: *model.Session, a: A, tid: i32, scope: c.struct_xlw_scope, expression: []const u8) !WatchCapture {
    var capture = WatchCapture{ .scope = scope, .expression = try a.dupeZ(u8, expression) };
    const observed = try @import("../model/language_selection.zig").cachedRead(.python, session, tid);
    const module_id = (try runtimeModule(session)).id;
    if (module_id != scope.runtime[0]) {
        capture.scope.runtime[0] = module_id;
        capture.diagnostic = try a.dupeZ(u8, "PythonWatchRuntimeChanged");
        return capture;
    }
    var saw_state = false;
    var complete = true;
    for (observed.segments) |segment| {
        const instance = segment.runtime_instance orelse continue;
        if (try std.fmt.parseInt(u64, instance.address, 0) != scope.runtime[1] or
            try std.fmt.parseInt(u64, instance.thread_state, 0) != scope.runtime[3]) continue;
        if (instance.interpreter_id != scope.runtime[2]) {
            capture.scope.runtime[2] = instance.interpreter_id;
            capture.diagnostic = try a.dupeZ(u8, "PythonWatchRuntimeChanged");
            return capture;
        }
        saw_state = true;
        complete = complete and segment.chain_complete;
        for (segment.frames) |frame| {
            if (try std.fmt.parseInt(u64, frame.frame_address, 0) != scope.frame[0]) continue;
            if (!frame.identity_proved) {
                capture.diagnostic = try a.dupeZ(u8, frame.reason orelse "PythonWatchFrameUnproved");
                return capture;
            }
            if (try std.fmt.parseInt(u64, frame.code, 0) != scope.frame[1]) continue;
            try watchValue(session, a, &capture, null);
            try session.target.expectGeneration(observed.generation);
            return capture;
        }
    }
    // A suspended generator is intentionally absent from the thread chain.
    // Never read its remembered address or mistake that absence for retirement.
    if (saw_state and complete and scope.frame[2] & watch_generator == 0) {
        capture.observation = c.XLW_FRAME_GONE;
        capture.diagnostic = try a.dupeZ(u8, "PythonWatchFrameGone");
    } else capture.diagnostic = try a.dupeZ(u8, if (scope.frame[2] & watch_generator != 0) "PythonWatchGeneratorNotObserved" else "PythonWatchFrameNotObserved");
    try session.target.expectGeneration(observed.generation);
    return capture;
}
fn readBindings(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize, expression: ?[]const u8) !@import("../model/language_locals.zig").Result {
    const named = @import("../model/language_locals.zig");
    const observed = try @import("../model/language_selection.zig").cachedRead(.python, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const selected = observed.segments[segment_index];
    if (frame >= selected.frames.len) return error.InvalidLanguageFrame;
    const selected_frame = selected.frames[frame];
    const frame_address = try std.fmt.parseInt(u64, selected_frame.frame_address, 0);
    const code = try std.fmt.parseInt(u64, selected_frame.code, 0);
    const generation = observed.generation;
    const version = try a.dupe(u8, selected.runtime.version);
    const id = try a.dupe(u8, selected.runtime.build_id);
    const stack_reason = if (selected.reason) |why| try a.dupe(u8, why) else null;
    const layout = try profile(session, try runtimeModule(session));
    if (!std.mem.eql(u8, id, try buildId(a, layout))) return error.PythonBuildIdMismatch;
    var r = reader(session);
    const raw = try a.create(c.struct_xpy_locals);
    if (expression) |query| c.xpy_local_find(layout, &r, frame_address, code, try a.dupeZ(u8, query), raw) else c.xpy_locals_read(layout, &r, frame_address, code, start, limit, raw);
    const rows = try a.alloc(named.Row, raw.count);
    for (raw.items[0..raw.count], rows) |item, *out| {
        const value = &item.value;
        const children = try a.alloc(named.Child, value.item_count);
        for (value.items[0..value.item_count], children) |child, *dest| dest.* = .{
            .key = try text(a, std.mem.sliceTo(&child.key, 0)),
            .type = try text(a, std.mem.sliceTo(&child.type, 0)),
            .display = try text(a, std.mem.sliceTo(&child.display, 0)),
            .address = if (child.address != 0) child.address else null,
            .diagnostic = try reason(a, child.reason),
            .advisory = child.reason != null,
        };
        const why = try reason(a, item.reason);
        out.* = .{
            .name = try text(a, std.mem.sliceTo(&item.name, 0)),
            .name_diagnostic = try reason(a, item.name_reason),
            .scope = switch (item.scope) {
                c.XPY_PARAMETER => .parameter,
                c.XPY_CELL => .cell,
                c.XPY_FREE => .free,
                else => .local,
            },
            .ordinal = item.ordinal,
            .address = if (item.address != 0) item.address else null,
            .slot_address = if (item.slot_address != 0) item.slot_address else null,
            .hidden = item.hidden != 0,
            .immediate = item.immediate != 0,
            .value = .{
                .count = value.count,
                .type = if (value.type[0] == 0) "unavailable" else try text(a, std.mem.sliceTo(&value.type, 0)),
                .display = if (value.display[0] == 0) why orelse "Value unavailable" else try text(a, std.mem.sliceTo(&value.display, 0)),
                .diagnostic = why,
                .truncated = value.truncated != 0,
                .children = children,
            },
        };
    }
    try session.target.expectGeneration(generation);
    return .{
        .generation = generation,
        .tid = tid,
        .language = .python,
        .segment = segment_index,
        .frame = frame,
        .start = raw.start,
        .total = raw.total,
        .truncated = raw.truncated != 0,
        .rows = rows,
        .diagnostic = (try reason(a, raw.reason)) orelse stack_reason,
        .runtime_version = version,
        .runtime_build_id = id,
        .basis = "CPython verified build-id, published localsplus/name/kind offsets and cell layout; canonical retained frame/code; normal GIL stackrefs; fast-local roots and bounded exact builtin dict/list/tuple paths; no mapping locals, descriptors or inferior calls",
        .memory_reads = r.reads,
        .memory_bytes = r.bytes,
    };
}
