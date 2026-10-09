//! Retained-stop adapter for the C CRuby reader. No target evaluation.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const Module = @import("../model/modules.zig").Module;
const eval = @import("../model/evaluate.zig");
const view = @import("../model/value_view.zig");
const named = @import("../model/language_locals.zig");
const A = std.mem.Allocator;
fn read(ctx: ?*anyopaque, at: u64, out: ?*anyopaque, n: usize) callconv(.c) c_int {
    const session: *model.Session = @ptrCast(@alignCast(ctx.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(at, bytes[0..n]) catch return -1) == n) 0 else -1;
}
fn reader(session: *model.Session) c.struct_xrb_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
fn reason(a: A, value: [*c]const u8) !?[]const u8 {
    return if (value == null) null else try a.dupe(u8, std.mem.span(value));
}
fn buildId(a: A, layout: *const c.struct_xrb_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
fn runtimeModule(session: *model.Session) !*Module {
    // Initial profile: a standalone/static CRuby executable, identified by
    // kernel PHDR evidence. A shared-library runtime stays unavailable.
    const runtime = @import("../target/runtime.zig");
    var loader = std.mem.zeroes(runtime.c.struct_xrt_loader);
    _ = runtime.c.xrt_target_loader(session.target.handle, &loader, null);
    if (loader.main_phdr == 0) return error.RubyModuleIdentityUnavailable;
    const module = session.modules.at(loader.main_phdr) catch return error.RubyModuleIdentityUnavailable;
    if (module.symbols().findSymbol("ruby_version") == null or module.symbols().findSymbol("rb_vm_exec") == null) return error.RubyStaticRuntimeUnavailable;
    return module;
}
fn constant(session: *model.Session, module: *Module, name: []const u8, expected: []const u8) !void {
    const sym = module.symbols().findSymbol(name) orelse return error.RubyVersionUnavailable;
    if (!sym.hasAddress() or sym.size != expected.len + 1 or sym.size > 128) return error.RubyVersionUnsupported;
    var loaded: [128]u8 = undefined;
    const size: usize = @intCast(sym.size);
    if (try session.target.readMemory(try module.runtimeAddress(sym.value), loaded[0..size]) != size) return error.RubyVersionUnavailable;
    if (loaded[size - 1] != 0 or !std.mem.eql(u8, loaded[0 .. size - 1], expected)) return error.RubyVersionUnsupported;
    for (0..module.image.header.segment_count) |i| {
        const seg = try module.image.segment(@intCast(i));
        if (seg.type != .load or sym.value < seg.vaddr) continue;
        const off = sym.value - seg.vaddr;
        if (off > seg.file_size or size > seg.file_size - off) continue;
        const data = try module.image.segmentData(seg);
        if (!std.mem.eql(u8, data[@intCast(off)..][0..size], loaded[0..size])) return error.RubyVersionMismatch;
        return;
    }
    return error.RubyVersionUnavailable;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xrb_layout {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.RubyArchitectureUnsupported;
    const id = module.image.buildId() orelse return error.RubyBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.RubyBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.RubyBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.RubyBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.target.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len])) return error.RubyBuildIdMismatch;
    try constant(session, module, "ruby_version", c.XRB_VERSION);
    try constant(session, module, "ruby_revision", c.XRB_REVISION);
    if (module.ruby_layout == null) {
        const debug = module.debugInfo() catch |err| return if (err == error.DebugMetadataPending) err else error.RubyDwarfUnavailable;
        var layout: c.struct_xrb_layout = undefined;
        if (c.xrb_layout_build(debug.dwarf, id.ptr, id.len, c.XRB_VERSION, c.XRB_REVISION, &layout)) |why| {
            inline for (.{ error.RubyDwarfMalformed, error.RubyDwarfWorkLimit, error.RubyDwarfAmbiguous, error.RubyDwarfTypesUnavailable, error.RubyDwarfConstantsUnavailable, error.RubyConstantMismatch, error.RubyRuntimeMultiple }) |err| {
                if (std.mem.eql(u8, std.mem.span(why), @errorName(err))) return err;
            }
            return error.RubyLayoutUnsupported;
        }
        module.ruby_layout = layout;
    }
    return &module.ruby_layout.?;
}
fn globalAddress(module: *Module, name: []const u8) !u64 {
    const sym = module.symbols().findSymbol(name) orelse return error.RubyRuntimeSymbolsUnavailable;
    if (!sym.hasAddress()) return error.RubyRuntimeSymbolsUnavailable;
    return module.runtimeAddress(sym.value);
}
fn zjitEntry(session: *model.Session, module: *Module) !u64 {
    var bytes: [8]u8 = undefined;
    if (try session.target.readMemory(try globalAddress(module, "rb_zjit_entry"), &bytes) != bytes.len) return error.RubyJitStateUnavailable;
    return std.mem.readInt(u64, &bytes, .little);
}
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    return .{ .version = c.XRB_VERSION ++ "dev", .build_id = try buildId(a, layout), .basis = "DWARF + exact revision" };
}
fn converted(a: A, v: *const c.struct_xrb_value) !named.Value {
    const children = try a.alloc(named.Child, v.item_count);
    for (v.items[0..v.item_count], children) |child, *out| out.* = .{
        .key = try a.dupe(u8, std.mem.sliceTo(&child.key, 0)),
        .type = try a.dupe(u8, std.mem.sliceTo(&child.type, 0)),
        .display = try a.dupe(u8, std.mem.sliceTo(&child.display, 0)),
        .address = null,
        .diagnostic = try reason(a, child.reason),
        .advisory = true,
    };
    return .{ .type = try a.dupe(u8, std.mem.sliceTo(&v.type, 0)), .display = try a.dupe(u8, std.mem.sliceTo(&v.display, 0)), .count = if (std.mem.eql(u8, std.mem.sliceTo(&v.type, 0), "String") or std.mem.eql(u8, std.mem.sliceTo(&v.type, 0), "Array") or std.mem.eql(u8, std.mem.sliceTo(&v.type, 0), "Symbol") or std.mem.eql(u8, std.mem.sliceTo(&v.type, 0), "Hash")) v.count else null, .diagnostic = try reason(a, v.reason), .truncated = v.truncated != 0, .children = children };
}
pub fn preview(session: *model.Session, a: A, value: eval.Value) !?view.Preview {
    if (value.availability != .available or !value.type.ruby_value or value.type.kind != .unsigned or value.type.size != 8) return null;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var r = reader(session);
    const raw = try a.create(c.struct_xrb_value);
    const context = try readContext(module, "");
    c.xrb_value_read(layout, &r, &context, value.bits, raw);
    const v = try converted(a, raw);
    return .{ .presentation = .scalar, .data_address = value.address orelse 0, .count = v.count orelse 0, .element_type = value.type.name, .truncated = v.truncated, .diagnostic = v.diagnostic, .basis = "CRuby public VALUE typedef; loaded identity and same-image DWARF; no inferior calls", .ruby = .{ .value = v, .tagged = value.bits, .runtime_version = c.XRB_VERSION ++ "dev", .runtime_build_id = try buildId(a, layout), .memory_reads = r.reads, .memory_bytes = r.bytes } };
}
pub const Anchor = struct { frame: usize, pc: []const u8, symbol: []const u8 = "rb_vm_exec", argument: []const u8 = "ec" };
pub const Runtime = struct { language: []const u8 = "ruby", implementation: []const u8 = "CRuby", version: []const u8 = c.XRB_VERSION ++ "dev", revision: []const u8 = c.XRB_REVISION, build_id: []const u8, layout_source: []const u8 = "same-image DWARF + exact revision" };
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "ruby:execution_context", address: []const u8, scope: []const u8 = "this retained stop only; fibers have separate execution contexts" };
pub const Frame = struct { name: []const u8, file: ?[]const u8, line: ?u32, kind: []const u8, reason: ?[]const u8, line_reason: ?[]const u8, control_frame: []const u8, environment: []const u8, instruction_sequence: []const u8, provenance: []const u8 = "external_read" };
pub const Segment = struct { runtime: Runtime, runtime_instance: Instance, anchor: ?Anchor, additional_anchors: []Anchor = &.{}, frames: []Frame, chain_complete: bool = false, state: []const u8 = "partial", reason: ?[]const u8, memory_reads: usize, memory_bytes: usize };
pub const ArgumentDiagnostic = struct { frame: usize, reason: []const u8 };
pub const Stack = struct { session_id: u64, generation: u64, tid: i32, segments: []Segment, native_stack_incomplete: bool, native_argument_diagnostics: []ArgumentDiagnostic, basis: []const u8 = "CRuby control frames from native rb_vm_exec ec; segment anchor only, logical/native pairing unproved; no target calls" };
pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    const zjit = try zjitEntry(session, module);
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    var segments: std.ArrayList(Segment) = .empty;
    var diagnostics: std.ArrayList(ArgumentDiagnostic) = .empty;
    for (native[first..]) |f| {
        if (!std.mem.eql(u8, f.symbol orelse "", "rb_vm_exec")) continue;
        if ((session.modules.at(f.pc) catch continue) != module) continue;
        const ec = recoveredEc(session, a, f) catch |err| {
            if (err == error.OutOfMemory) return err;
            try diagnostics.append(a, .{ .frame = f.index, .reason = @errorName(err) });
            continue;
        };
        const address = try hex(a, ec);
        var seen = false;
        for (segments.items) |*previous| if (std.mem.eql(u8, previous.runtime_instance.address, address)) {
            const anchors = try a.alloc(Anchor, previous.additional_anchors.len + 1);
            @memcpy(anchors[0..previous.additional_anchors.len], previous.additional_anchors);
            anchors[anchors.len - 1] = .{ .frame = f.index, .pc = try hex(a, f.pc) };
            previous.additional_anchors = anchors;
            seen = true;
            break;
        };
        if (seen) continue;
        if (segments.items.len == 8) return error.RubyExecutionContextLimit;
        var r = reader(session);
        const raw = try a.create(c.struct_xrb_stack);
        c.xrb_stack_read(layout, &r, ec, zjit, raw);
        const frames = try a.alloc(Frame, raw.count);
        for (raw.frames[0..raw.count], frames) |v, *out| out.* = .{
            .name = try a.dupe(u8, std.mem.sliceTo(&v.name, 0)),
            .file = if (v.file[0] == 0) null else try a.dupe(u8, std.mem.sliceTo(&v.file, 0)),
            .line = if (v.line == 0) null else v.line,
            .kind = try a.dupe(u8, std.mem.sliceTo(&v.kind, 0)),
            .reason = try reason(a, v.reason),
            .line_reason = try reason(a, v.line_reason),
            .control_frame = try hex(a, v.cfp),
            .environment = try hex(a, v.ep),
            .instruction_sequence = try hex(a, v.iseq),
        };
        try segments.append(a, .{ .runtime = .{ .build_id = try buildId(a, layout) }, .runtime_instance = .{ .address = address }, .anchor = .{ .frame = f.index, .pc = try hex(a, f.pc) }, .frames = frames, .chain_complete = raw.reason == null, .reason = (try reason(a, raw.reason)) orelse "RubyNativePairingUnproved", .memory_reads = r.reads, .memory_bytes = r.bytes });
    }
    if (segments.items.len == 0 and diagnostics.items.len == 0) return error.RubyExecutionContextUnavailable;
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = try segments.toOwnedSlice(a), .native_argument_diagnostics = try diagnostics.toOwnedSlice(a), .native_stack_incomplete = native.len == 64 or native[native.len - 1].diagnostic != null };
}
fn recoveredEc(session: *model.Session, a: A, frame: model.Frame) !u64 {
    const locals = try session.frameLocals(a, frame);
    for (locals) |local| {
        if (!local.parameter or !std.mem.eql(u8, local.name, "ec") or local.value.type.kind != .pointer) continue;
        const child = local.value.type.child orelse continue;
        if (!std.mem.eql(u8, child.name, "rb_execution_context_t") and !std.mem.eql(u8, child.name, "rb_execution_context_struct")) continue;
        const v = try session.evaluateInFrame(a, frame, locals, local.name);
        if (v.availability != .available or v.bits == 0) return error.RubyExecutionContextArgumentUnavailable;
        return v.bits;
    }
    return error.RubyExecutionContextArgumentUnavailable;
}
pub fn readLocals(session: *model.Session, a: A, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !named.Result {
    return bindings(session, a, tid, segment, frame, start, limit, null);
}
fn checkedExpression(a: A, text: []const u8) ![:0]const u8 {
    if (text.len == 0 or text.len > c.XLW_EXPRESSION or std.mem.indexOfScalar(u8, text, 0) != null) return error.UnsupportedRubyExpression;
    const query = try a.dupeZ(u8, text);
    if (c.xrb_expression_check(query) != null) return error.UnsupportedRubyExpression;
    return query;
}
fn readContext(module: *Module, expression: []const u8) !c.struct_xrb_context {
    var context = std.mem.zeroes(c.struct_xrb_context);
    context.symbols = try globalAddress(module, "ruby_global_symbols");
    context.hash_class = try globalAddress(module, "rb_cHash");
    context.array_class = try globalAddress(module, "rb_cArray");
    if (std.mem.indexOfScalar(u8, expression, '[') == null) return context;
    inline for (.{
        .{ "hash_salt", "hash_salt" },
        .{ "string_class", "rb_cString" },
        .{ "integer_class", "rb_cInteger" },
        .{ "symbol_class", "rb_cSymbol" },
        .{ "hash_aref", "rb_hash_aref" },
        .{ "array_aref", "rb_ary_aref" },
        .{ "string_hash", "rb_str_hash_m" },
        .{ "string_eql", "rb_str_eql" },
        .{ "object_hash", "rb_obj_hash" },
        .{ "object_eql", "rb_obj_equal" },
        .{ "numeric_eql", "num_eql" },
        .{ "any_hash", "rb_any_hash" },
        .{ "any_cmp", "rb_any_cmp" },
    }) |entry| @field(context, entry[0]) = try globalAddress(module, entry[1]);
    return context;
}
pub fn evaluateLocal(session: *model.Session, a: A, tid: i32, segment: usize, frame: usize, expression: []const u8) !named.Result {
    _ = try checkedExpression(a, expression);
    return bindings(session, a, tid, segment, frame, 0, 1, expression);
}
fn bindings(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize, expression: ?[]const u8) !named.Result {
    const observed = try @import("../model/language_selection.zig").cachedRead(.ruby, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment = observed.segments[segment_index];
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var r = reader(session);
    const raw = try a.create(c.struct_xrb_locals);
    const ec = try std.fmt.parseInt(u64, segment.runtime_instance.address, 0);
    const zjit = try zjitEntry(session, module);
    const context = try readContext(module, expression orelse "");
    if (expression) |text| {
        c.xrb_expression_find(layout, &r, &context, ec, zjit, frame, try a.dupeZ(u8, text), raw);
    } else c.xrb_locals_read(layout, &r, ec, zjit, &context, frame, start, limit, raw);
    const rows = try a.alloc(named.Row, raw.count);
    for (raw.items[0..raw.count], rows) |item, *out| out.* = .{
        .name = try a.dupe(u8, std.mem.sliceTo(&item.name, 0)),
        .name_diagnostic = try reason(a, item.reason),
        .scope = if (item.depth == 0) .local else .upvalue,
        .ordinal = item.ordinal,
        .address = null,
        .slot_address = if (item.address == 0) null else item.address,
        .hidden = item.hidden != 0,
        .storage_lifetime = if (item.escaped != 0) "escaped Ruby environment; resolve again after resume/GC" else "Ruby VM stack slot; resolve again after resume/fiber switch",
        .value = try converted(a, &item.value),
    };
    try session.target.expectGeneration(observed.generation);
    return .{ .generation = observed.generation, .tid = tid, .language = .ruby, .segment = segment_index, .frame = frame, .start = raw.start, .total = raw.total, .truncated = raw.truncated != 0, .rows = rows, .diagnostic = try reason(a, raw.reason), .runtime_version = segment.runtime.version, .runtime_build_id = segment.runtime.build_id, .basis = "same-image DWARF; CRuby local table and validated stack/escaped environment; nearest lexical environment first; no target calls", .memory_reads = r.reads, .memory_bytes = r.bytes };
}

const WatchCapture = @import("watch.zig").Capture;
// Runtime words: module/execution context. Frame words: control frame/iseq/
// binding selector/lexical ordinal. Environment and VALUE addresses are never
// retained: Binding creation, fiber switches and compacting GC can move them.
fn watchValue(session: *model.Session, a: A, capture: *WatchCapture, frame: usize, row: ?usize) !void {
    const module = try runtimeModule(session);
    if (module.id != capture.scope.runtime[0]) return error.RubyWatchRuntimeChanged;
    const layout = try profile(session, module);
    var r = reader(session);
    defer {
        capture.reads = r.reads;
        capture.bytes = r.bytes;
    }
    const raw = try a.create(c.struct_xrb_locals);
    const zjit = try zjitEntry(session, module);
    const context = try readContext(module, if (row == null and capture.scope.frame[2] == 0) capture.expression else "");
    if (row) |ordinal| {
        c.xrb_locals_read(layout, &r, capture.scope.runtime[1], zjit, &context, frame, ordinal, 1, raw);
    } else if (capture.scope.frame[2] != 0) {
        c.xrb_locals_read(layout, &r, capture.scope.runtime[1], zjit, &context, frame, @intCast(capture.scope.frame[3]), 1, raw);
    } else {
        c.xrb_expression_find(layout, &r, &context, capture.scope.runtime[1], zjit, frame, capture.expression, raw);
    }
    if (raw.reason != null or raw.count != 1) {
        capture.diagnostic = try a.dupeZ(u8, if (raw.reason != null) std.mem.span(raw.reason) else "RubyWatchBindingUnavailable");
        return;
    }
    const item = &raw.items[0];
    if (item.reason != null or item.hidden != 0 or item.address == 0) {
        capture.diagnostic = try a.dupeZ(u8, if (item.reason != null) std.mem.span(item.reason) else "RubyWatchBindingUnavailable");
        return;
    }
    if (row != null) {
        capture.expression = try a.dupeZ(u8, std.mem.sliceTo(&item.name, 0));
        if (capture.expression.len == 0 or capture.expression.len > c.XLW_EXPRESSION) return error.RubyWatchNameTooLong;
        capture.scope.frame[2] = 1;
        capture.scope.frame[3] = item.ordinal;
    } else if (capture.scope.frame[2] != 0 and !std.mem.eql(u8, std.mem.sliceTo(&item.name, 0), capture.expression)) {
        capture.diagnostic = try a.dupeZ(u8, "RubyWatchBindingUnavailable");
        return;
    }
    const sample = try a.create(c.struct_xrb_sample);
    c.xrb_sample_read(layout, &r, item.tagged, sample);
    if (sample.reason != null) {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(sample.reason));
        return;
    }
    capture.observation = c.XLW_COMPLETE;
    capture.sample = .{ .kind = sample.kind, .bytes = &sample.bytes, .size = sample.size, .type = &sample.type, .display = &sample.display };
}
pub fn watchExpression(a: A, expression: ?[]const u8, row: ?usize) ![:0]const u8 {
    if ((expression == null) == (row == null)) return error.InvalidArguments;
    if (row) |index| if (index >= 4096) return error.InvalidArguments;
    return if (expression) |query| try checkedExpression(a, query) else try a.dupeZ(u8, "binding");
}
pub fn createWatch(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, expression: ?[]const u8, row: ?usize) !WatchCapture {
    const checked_expression = try watchExpression(a, expression, row);
    const observed = try @import("../model/language_selection.zig").cachedRead(.ruby, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment = observed.segments[segment_index];
    if (frame >= segment.frames.len) return error.InvalidLanguageFrame;
    const selected = segment.frames[frame];
    if (selected.reason != null) return error.RubyWatchFrameUnproved;
    const thread = for (session.target.threadSlice()) |entry| {
        if (entry.tid == tid) break entry.id;
    } else return error.InvalidThread;
    var capture = WatchCapture{ .scope = .{
        .language = c.XLW_RUBY,
        .session = session.id,
        .image = session.target.snapshot().image_epoch,
        .thread = thread,
        .runtime = .{ (try runtimeModule(session)).id, try std.fmt.parseInt(u64, segment.runtime_instance.address, 0), 0, 0 },
        .frame = .{ try std.fmt.parseInt(u64, selected.control_frame, 0), try std.fmt.parseInt(u64, selected.instruction_sequence, 0), 0, 0 },
    }, .expression = checked_expression };
    try watchValue(session, a, &capture, frame, row);
    if (row != null and capture.scope.frame[2] == 0) return error.RubyWatchBindingUnavailable;
    try session.target.expectGeneration(observed.generation);
    return capture;
}
pub fn observeWatch(session: *model.Session, a: A, tid: i32, scope: c.struct_xlw_scope, expression: []const u8) !WatchCapture {
    var capture = WatchCapture{ .scope = scope, .expression = try a.dupeZ(u8, expression) };
    const observed = try @import("../model/language_selection.zig").cachedRead(.ruby, session, tid);
    const module_id = (try runtimeModule(session)).id;
    if (module_id != scope.runtime[0]) {
        capture.scope.runtime[0] = module_id;
        capture.diagnostic = try a.dupeZ(u8, "RubyWatchRuntimeChanged");
        return capture;
    }
    var saw_runtime = false;
    var complete = true;
    for (observed.segments) |segment| {
        if (try std.fmt.parseInt(u64, segment.runtime_instance.address, 0) != scope.runtime[1]) continue;
        saw_runtime = true;
        complete = complete and segment.chain_complete;
        for (segment.frames, 0..) |frame, index| {
            if (try std.fmt.parseInt(u64, frame.control_frame, 0) != scope.frame[0] or try std.fmt.parseInt(u64, frame.instruction_sequence, 0) != scope.frame[1]) continue;
            if (frame.reason) |why| {
                capture.diagnostic = try a.dupeZ(u8, why);
                return capture;
            }
            try watchValue(session, a, &capture, index, null);
            try session.target.expectGeneration(observed.generation);
            return capture;
        }
    }
    if (saw_runtime and complete) {
        capture.observation = c.XLW_FRAME_GONE;
        capture.diagnostic = try a.dupeZ(u8, "RubyWatchFrameGone");
    } else capture.diagnostic = try a.dupeZ(u8, "RubyWatchFrameNotObserved");
    try session.target.expectGeneration(observed.generation);
    return capture;
}
