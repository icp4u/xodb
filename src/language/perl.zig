//! Owner-thread adapter for the memory-only C Perl reader. No target code is
//! called. Native anchors and logical frames remain separate observations.
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
fn reader(session: *model.Session) c.struct_xpl_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, address: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{address});
}
fn buildId(a: A, layout: *const c.struct_xpl_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 15];
    }
    return out;
}
fn text(a: A, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return a.dupe(u8, bytes);
    // Raw target bytes are not assumed to be UTF-8. Escaping preserves them.
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| {
        if (b >= 32 and b < 127 and b != '\\') try out.append(a, b) else {
            var buf: [4]u8 = undefined;
            const part = try std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{b});
            try out.appendSlice(a, part);
        }
    }
    return out.toOwnedSlice(a);
}
fn reason(a: A, ptr: [*c]const u8) !?[]const u8 {
    return if (ptr == null) null else try a.dupe(u8, std.mem.span(ptr));
}
fn layoutError(message: [*c]const u8) anyerror {
    inline for (.{ error.PerlDwarfUnitLimit, error.PerlDwarfLimit, error.PerlMalformedDwarf, error.PerlDwarfTypesUnavailable }) |err| {
        if (std.mem.eql(u8, std.mem.span(message), @errorName(err))) return err;
    }
    return error.PerlLayoutUnsupported;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xpl_layout {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.PerlArchitectureUnsupported;
    const id = module.image.buildId() orelse return error.PerlBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.PerlBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.PerlBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.PerlBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    const address = try module.runtimeAddress(note.addr);
    if (try session.target.readMemory(address, actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len]))
        return error.PerlBuildIdMismatch;
    var version: [3]u8 = undefined;
    for ([_][]const u8{ "PL_revision", "PL_version", "PL_subversion" }, &version) |name, *part| {
        const symbol = module.symbols().findSymbol(name) orelse return error.PerlVersionUnavailable;
        if (!symbol.hasAddress() or symbol.size != 1) return error.PerlVersionUnavailable;
        if (try session.target.readMemory(try module.runtimeAddress(symbol.value), @as(*[1]u8, @ptrCast(part))) != 1) return error.PerlVersionUnavailable;
    }
    if (!std.mem.eql(u8, &version, &.{ 5, 44, 0 })) return error.PerlVersionUnsupported;
    if (module.perl_layout == null) {
        var layout: c.struct_xpl_layout = undefined;
        const failure = c.xpl_layout_build((try module.debugInfo()).dwarf, id.ptr, id.len, &version, &layout);
        if (failure != null) return layoutError(failure);
        module.perl_layout = layout;
    }
    if (c.xpl_layout_check(&module.perl_layout.?, id.ptr, id.len, &version) != null) return error.PerlBuildIdMismatch;
    return &module.perl_layout.?;
}
pub const Anchor = struct { frame: usize, pc: []const u8, symbol: []const u8 };
pub const Runtime = struct { language: []const u8 = "perl", implementation: []const u8 = "perl5", version: []const u8 = "5.44.0", build_id: []const u8 };
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "perl:interpreter", address: []const u8, scope: []const u8 = "this process instance and retained stop; not stable identity" };
pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: ?u32,
    context_type: []const u8,
    kind: []const u8 = "interpreter",
    provenance: []const u8 = "external_read",
    cv: []const u8,
    context_address: []const u8,
    stackinfo: u64 = 0,
    context_index: u64 = 0,
    identity_proved: bool = false,
    reason: ?[]const u8,
};
pub const Segment = struct {
    runtime: Runtime,
    runtime_instance: ?Instance,
    anchor: ?Anchor,
    additional_anchors: []Anchor = &.{},
    source_kind: []const u8 = "stopped_snapshot",
    chain_complete: bool = false,
    state: []const u8,
    reason: ?[]const u8,
    frames: []Frame,
    current_op: ?[]const u8,
    memory_reads: usize,
    memory_bytes: usize,
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    segments: []Segment,
    native_stack_incomplete: bool,
    basis: []const u8 = "Perl 5.44.0 threaded DWARF layout, verified loaded build-id, retained stopped memory; no inferior calls or inferred native/logical merge",
};
fn instance(session: *model.Session, a: A, frame: model.Frame) !u64 {
    const locals = try session.frameLocals(a, frame);
    for (locals) |local| if (std.mem.eql(u8, local.name, "my_perl")) {
        const v = try session.evaluateInFrame(a, frame, locals, "my_perl");
        if (v.availability != .available or v.type.kind != .pointer or v.bits == 0) return error.PerlInterpreterUnavailable;
        return v.bits;
    };
    return error.PerlInterpreterUnavailable;
}
fn segment(session: *model.Session, a: A, frame: model.Frame, anchored: bool) !Segment {
    const module = try session.modules.at(frame.lookup_pc);
    const layout = try profile(session, module);
    const build = try buildId(a, layout);
    const anchor: ?Anchor = if (anchored) .{ .frame = frame.index, .pc = try hex(a, frame.pc), .symbol = try a.dupe(u8, frame.symbol.?) } else null;
    const pointer = instance(session, a, frame) catch return .{
        .runtime = .{ .build_id = build },
        .runtime_instance = null,
        .anchor = anchor,
        .state = "partial",
        .reason = "PerlInterpreterUnavailable",
        .frames = &.{},
        .current_op = null,
        .memory_reads = 0,
        .memory_bytes = 0,
    };
    const raw = try a.create(c.struct_xpl_stack);
    var r = reader(session);
    c.xpl_stack_read(layout, &r, pointer, raw);
    const frames = try a.alloc(Frame, raw.count);
    for (raw.frames[0..raw.count], frames) |f, *out| out.* = .{
        .name = try text(a, std.mem.sliceTo(&f.name, 0)),
        .file = if (f.file[0] != 0) try text(a, std.mem.sliceTo(&f.file, 0)) else null,
        .line = if (f.line > 0) f.line else null,
        .context_type = switch (f.context_type) {
            9 => "sub",
            10 => "format",
            11 => "eval",
            0x8b => "try",
            else => "main",
        },
        .cv = try hex(a, f.cv),
        .context_address = try hex(a, f.context_address),
        .stackinfo = f.stackinfo,
        .context_index = f.context_index,
        .identity_proved = f.identity_proved != 0,
        .reason = try reason(a, f.reason),
    };
    return .{
        .runtime = .{ .build_id = build },
        .runtime_instance = .{ .address = try hex(a, pointer) },
        .anchor = anchor,
        .state = if (raw.reason == null) "complete" else "partial",
        .chain_complete = raw.chain_complete != 0,
        .reason = try reason(a, raw.reason),
        .frames = frames,
        .current_op = if (raw.op != 0) try hex(a, raw.op) else null,
        .memory_reads = r.reads,
        .memory_bytes = r.bytes,
    };
}
fn constrainBoundary(s: *Segment, unresolved_inner: bool) void {
    if (unresolved_inner and s.runtime_instance != null) {
        s.state = "partial";
        s.reason = "InnerInterpreterAnchorUnresolved";
        s.chain_complete = false;
    }
}
// Only the retained native anchor order establishes "inner" and "outer".
// An unresolved inner interpreter cannot donate its current contexts to a
// complete outer segment, even when that outer interpreter is recoverable.
test "unresolved inner interpreter keeps outward segments partial" {
    var s = Segment{ .runtime = .{ .build_id = "synthetic" }, .runtime_instance = .{ .address = "0x1000" }, .anchor = .{ .frame = 3, .pc = "0x2000", .symbol = "Perl_runops_standard" }, .state = "complete", .reason = null, .frames = &.{}, .current_op = null, .memory_reads = 0, .memory_bytes = 0 };
    constrainBoundary(&s, false);
    try std.testing.expectEqualStrings("complete", s.state);
    constrainBoundary(&s, true);
    try std.testing.expectEqualStrings("partial", s.state);
    try std.testing.expectEqualStrings("InnerInterpreterAnchorUnresolved", s.reason.?);
}
const SkippedAnchor = struct { instance: Instance, build_id: []const u8, anchor: Anchor };
fn constrainSkipped(a: A, segment_: *Segment, skipped: []const SkippedAnchor) !void {
    const current_instance = segment_.runtime_instance orelse return;
    var count: usize = 0;
    for (skipped) |inner| if (std.mem.eql(u8, inner.instance.address, current_instance.address) and std.mem.eql(u8, inner.build_id, segment_.runtime.build_id)) {
        count += 1;
    };
    if (count == 0) return;
    const anchors = try a.alloc(Anchor, count);
    var at: usize = 0;
    for (skipped) |inner| if (std.mem.eql(u8, inner.instance.address, current_instance.address) and std.mem.eql(u8, inner.build_id, segment_.runtime.build_id)) {
        anchors[at] = inner.anchor;
        at += 1;
    };
    segment_.additional_anchors = anchors;
    segment_.state = "partial";
    segment_.reason = "RepeatedInterpreterAnchorBoundaryUnavailable";
    segment_.chain_complete = false;
}

pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (first >= 64) return error.InvalidFrame;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    var segments: std.ArrayList(Segment) = .empty;
    var unresolved_inner = false;
    var recovered_anchor = false;
    var skipped: [64]SkippedAnchor = undefined;
    var skipped_count: usize = 0;
    for (native) |frame| {
        const name = frame.symbol orelse continue;
        if (!std.mem.eql(u8, name, "Perl_runops_standard") and !std.mem.eql(u8, name, "Perl_runops_debug")) continue;
        var s = try segment(session, a, frame, true);
        if (s.runtime_instance == null) unresolved_inner = true;
        if (frame.index < first) {
            if (s.runtime_instance) |skipped_instance| {
                skipped[skipped_count] = .{ .instance = skipped_instance, .build_id = s.runtime.build_id, .anchor = s.anchor.? };
                skipped_count += 1;
            }
            continue;
        }
        if (s.runtime_instance != null) recovered_anchor = true;
        constrainBoundary(&s, unresolved_inner);
        try constrainSkipped(a, &s, skipped[0..skipped_count]);
        var duplicate = false;
        if (s.runtime_instance) |current| for (segments.items) |*previous| {
            if (previous.runtime_instance) |old| if (std.mem.eql(u8, old.address, current.address) and std.mem.eql(u8, previous.runtime.build_id, s.runtime.build_id)) {
                const anchors = try a.alloc(Anchor, previous.additional_anchors.len + 1);
                @memcpy(anchors[0..previous.additional_anchors.len], previous.additional_anchors);
                anchors[anchors.len - 1] = s.anchor.?;
                previous.additional_anchors = anchors;
                previous.state = "partial";
                previous.reason = "RepeatedInterpreterAnchorBoundaryUnavailable";
                previous.chain_complete = false;
                duplicate = true;
                break;
            };
        };
        if (!duplicate) try segments.append(a, s);
    }
    // A readable current-frame argument can provide an unanchored observation;
    // it never establishes ordering relative to a different runtime segment.
    if (!recovered_anchor) {
        const frame = native[first];
        const module = try session.modules.at(frame.lookup_pc);
        if (module.symbols().findSymbol("Perl_runops_standard") != null) {
            var fallback = try segment(session, a, frame, false);
            if (fallback.runtime_instance != null) {
                fallback.state = "partial";
                fallback.reason = "NativeInterpreterAnchorUnavailable";
                try segments.append(a, fallback);
            } else if (segments.items.len == 0) try segments.append(a, fallback);
        }
    }
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = try segments.toOwnedSlice(a), .native_stack_incomplete = native.len == 64 or (native.len > 0 and native[native.len - 1].diagnostic != null) };
}
// Type aliases currently carry no owning image id. Refuse ambiguous layouts
// rather than choosing the first interpreter library found in the mappings.
fn valueModule(session: *model.Session) !*Module {
    var chosen: ?*Module = null;
    if (session.modules.regions.items.len > 4096) return error.PerlModuleLimit;
    for (session.modules.regions.items) |r| {
        if ((r.offset != 0 and r.permissions[2] != 'x') or r.path.len == 0 or r.path[0] != '/') continue;
        const module = session.modules.load(r) catch |err| {
            if (err == error.NotElf or err == error.NoBinaryImage) continue;
            return error.PerlModuleIdentityUnavailable;
        };
        const symbol = module.symbols().findSymbol("Perl_runops_standard") orelse continue;
        if (!symbol.hasAddress()) continue;
        if (chosen) |previous| {
            if (previous.id == module.id) continue;
            const a_id = previous.image.buildId() orelse return error.PerlBuildIdUnavailable;
            const b_id = module.image.buildId() orelse return error.PerlBuildIdUnavailable;
            if (!std.mem.eql(u8, a_id, b_id)) return error.PerlValueRuntimeAmbiguous;
            _ = try profile(session, module);
        } else chosen = module;
    }
    return chosen orelse error.PerlRuntimeUnavailable;
}
pub fn preview(session: *model.Session, a: A, value: eval.Value) !?view.Preview {
    if (value.availability != .available or value.type.kind != .pointer or value.bits == 0) return null;
    const child = value.type.child orelse return null;
    if (child.kind != .structure or child.size != 24) return null;
    const names = [_][]const u8{ "SV", "AV", "HV", "CV", "GV", "sv", "av", "hv", "cv", "gv" };
    var matches = false;
    for (names) |name| if (std.mem.eql(u8, child.name, name)) {
        matches = true;
        break;
    };
    if (!matches) return null;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    // A type name alone is insufficient: require the native head's fields.
    const fields = [_]struct { name: []const u8, index: usize }{
        .{ .name = "sv_any", .index = c.XPL_ANY },     .{ .name = "sv_refcnt", .index = c.XPL_REFCNT },
        .{ .name = "sv_flags", .index = c.XPL_FLAGS }, .{ .name = "sv_u", .index = c.XPL_UNION },
    };
    for (fields) |wanted| {
        var found = false;
        for (child.fields) |field| if (std.mem.eql(u8, field.name, wanted.name)) {
            found = true;
            break;
        };
        if (!found) return null;
    }
    const module = try valueModule(session);
    const layout = try profile(session, module);
    for (fields) |wanted| {
        var found = false;
        for (child.fields) |field| if (std.mem.eql(u8, field.name, wanted.name) and field.offset == layout.fields[wanted.index].offset and field.type.size == layout.fields[wanted.index].size) {
            found = true;
            break;
        };
        if (!found) return null;
    }
    var r = reader(session);
    const raw = try a.create(c.struct_xpl_value);
    c.xpl_value_read(layout, &r, value.bits, raw);
    const items = try a.alloc(view.PerlItem, raw.item_count);
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
        .preview_bytes = raw.byte_count,
        .truncated = raw.truncated != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = "Perl flags and DWARF layout for verified libperl build-id; stopped memory; no magic or inferior calls",
        .perl = .{
            .type = try text(a, std.mem.sliceTo(&raw.type, 0)),
            .display = try text(a, std.mem.sliceTo(&raw.display, 0)),
            .class_name = if (raw.class_name[0] != 0) try text(a, std.mem.sliceTo(&raw.class_name, 0)) else null,
            .refcount = raw.refcount,
            .flags = raw.flags,
            .stored_value_only = raw.stored_value_only != 0,
            .utf8 = raw.utf8 != 0,
            .body = raw.body,
            .runtime_build_id = try buildId(a, layout),
            .items = items,
        },
    };
}

test "Perl layout search bounds retain their diagnostics" {
    try std.testing.expectEqual(error.PerlDwarfUnitLimit, layoutError("PerlDwarfUnitLimit"));
    try std.testing.expectEqual(error.PerlDwarfTypesUnavailable, layoutError("PerlDwarfTypesUnavailable"));
    try std.testing.expectEqual(error.PerlDwarfLimit, layoutError("PerlDwarfLimit"));
}

/// Runtime identity and proof from the existing stopped-memory reader.
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const module = try valueModule(session);
    const layout = try profile(session, module);
    return .{ .version = "5.44.0", .build_id = try buildId(a, layout), .basis = if (module.debug_file != null) "build-id companion DWARF" else "same-image DWARF" };
}

/// Frame selection comes from the retained canonical stack, never raw client
/// interpreter/CV/pad addresses. The C reader revalidates that context's pad.
pub fn readLocals(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize) !@import("../model/language_locals.zig").Result {
    return readBindings(session, a, tid, segment_index, frame, start, limit, null);
}
pub fn evaluateLocal(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, expression: []const u8) !@import("../model/language_locals.zig").Result {
    return readBindings(session, a, tid, segment_index, frame, 0, 1, expression);
}
fn readBindings(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, start: usize, limit: usize, expression: ?[]const u8) !@import("../model/language_locals.zig").Result {
    const named = @import("../model/language_locals.zig");
    const observed = try @import("../model/language_selection.zig").cachedRead(.perl, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const selected = observed.segments[segment_index];
    if (frame >= selected.frames.len) return error.InvalidLanguageFrame;
    const instance_ = selected.runtime_instance orelse return error.PerlInterpreterUnavailable;
    const interpreter = try std.fmt.parseInt(u64, instance_.address, 0);
    const cv = try std.fmt.parseInt(u64, selected.frames[frame].cv, 0);
    const context = try std.fmt.parseInt(u64, selected.frames[frame].context_address, 0);
    const generation = observed.generation;
    const version = try a.dupe(u8, selected.runtime.version);
    const id = try a.dupe(u8, selected.runtime.build_id);
    const stack_reason = if (selected.reason) |why| try a.dupe(u8, why) else null;
    const module = if (selected.anchor) |anchor|
        try session.modules.at(try std.fmt.parseInt(u64, anchor.pc, 0))
    else
        try valueModule(session);
    const layout = try profile(session, module);
    if (!std.mem.eql(u8, id, try buildId(a, layout))) return error.PerlBuildIdMismatch;
    var r = reader(session);
    const raw = try a.create(c.struct_xpl_locals);
    if (expression) |query| c.xpl_local_find(layout, &r, interpreter, frame, try a.dupeZ(u8, query), raw) else c.xpl_locals_read(layout, &r, interpreter, frame, start, limit, raw);
    if ((raw.cv != 0 and raw.cv != cv) or (raw.context_address != 0 and raw.context_address != context)) return error.StaleLanguageFrame;
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
            .scope = switch (item.scope) {
                c.XPL_OUTER => .free,
                c.XPL_STATE => .state,
                else => .local,
            },
            .ordinal = @intCast(item.ordinal),
            .address = if (item.sv != 0) item.sv else null,
            .slot_address = if (item.slot_address != 0) item.slot_address else null,
            .value = .{
                .type = if (value.type[0] == 0) "unavailable" else try text(a, std.mem.sliceTo(&value.type, 0)),
                .display = if (value.display[0] == 0) why orelse "Value unavailable" else try text(a, std.mem.sliceTo(&value.display, 0)),
                .diagnostic = why,
                .advisory = value.stored_value_only != 0,
                .truncated = value.truncated != 0,
                .children = children,
            },
        };
    }
    try session.target.expectGeneration(generation);
    return .{
        .generation = generation,
        .tid = tid,
        .language = .perl,
        .segment = segment_index,
        .frame = frame,
        .start = raw.start,
        .total = raw.total,
        .truncated = raw.truncated != 0,
        .rows = rows,
        .diagnostic = (try reason(a, raw.reason)) orelse stack_reason,
        .runtime_version = version,
        .runtime_build_id = id,
        .basis = "Perl 5.44.0 threaded DWARF layout and verified build-id; canonical context CV/depth/COP lexical scope; retained pad bindings only; no magic, globals, uncaptured outer traversal or inferior calls",
        .memory_reads = r.reads,
        .memory_bytes = r.bytes,
    };
}

const WatchCapture = @import("watch.zig").Capture;
// Runtime words: module/interpreter/stackinfo. Frame words: context index + 1
// (zero for main)/CV/binding selector/pad declaration. Never retain cxstack.
fn watchValue(session: *model.Session, a: A, capture: *WatchCapture, frame: usize, expected_context: u64, row: ?usize) !void {
    const module = try valueModule(session);
    if (module.id != capture.scope.runtime[0]) return error.PerlWatchRuntimeChanged;
    const layout = try profile(session, module);
    var r = reader(session);
    defer {
        capture.reads = r.reads;
        capture.bytes = r.bytes;
    }
    const raw = try a.create(c.struct_xpl_locals);
    if (row) |index| {
        c.xpl_locals_read(layout, &r, capture.scope.runtime[1], frame, index, 1, raw);
    } else if (capture.scope.frame[2] != 0) {
        c.xpl_local_binding(layout, &r, capture.scope.runtime[1], frame, capture.scope.frame[3], capture.expression, raw);
    } else c.xpl_local_find(layout, &r, capture.scope.runtime[1], frame, capture.expression, raw);
    if (raw.cv != 0 and (raw.cv != capture.scope.frame[1] or raw.context_address != expected_context)) return error.StaleLanguageFrame;
    if (raw.reason != null or raw.count != 1) {
        capture.diagnostic = try a.dupeZ(u8, if (raw.reason != null) std.mem.span(raw.reason) else "PerlWatchBindingUnavailable");
        return;
    }
    const item = &raw.items[0];
    if (row != null) {
        capture.expression = try a.dupeZ(u8, std.mem.sliceTo(&item.name, 0));
        if (capture.expression.len == 0 or capture.expression.len > c.XLW_EXPRESSION) return error.PerlWatchNameTooLong;
        if (!std.unicode.utf8ValidateSlice(capture.expression)) return error.PerlWatchNameInvalid;
        capture.scope.frame[2] = 1;
        capture.scope.frame[3] = item.ordinal;
    }
    if (item.reason != null) {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(item.reason));
        return;
    }
    const sample = try a.create(c.struct_xpl_sample);
    c.xpl_sample_read(layout, &r, item.sv, sample);
    if (sample.reason != null) {
        capture.diagnostic = try a.dupeZ(u8, std.mem.span(sample.reason));
        return;
    }
    capture.observation = c.XLW_COMPLETE;
    capture.sample = .{ .kind = sample.kind, .bytes = &sample.bytes, .size = sample.size, .type = &sample.type, .display = &sample.display };
}
pub fn createWatch(session: *model.Session, a: A, tid: i32, segment_index: usize, frame: usize, expression: ?[]const u8, row: ?usize) !WatchCapture {
    if ((expression == null) == (row == null)) return error.InvalidArguments;
    if (expression) |query| if (query.len == 0 or query.len > c.XLW_EXPRESSION or std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidArguments;
    if (row) |index| if (index >= c.XPL_MAX_PAD_NAMES) return error.InvalidArguments;
    const observed = try @import("../model/language_selection.zig").cachedRead(.perl, session, tid);
    if (segment_index >= observed.segments.len) return error.InvalidLanguageSegment;
    const segment_ = observed.segments[segment_index];
    const instance_ = segment_.runtime_instance orelse return error.PerlWatchRuntimeUnproved;
    if (frame >= segment_.frames.len) return error.InvalidLanguageFrame;
    const selected = segment_.frames[frame];
    if (!selected.identity_proved) return error.PerlWatchFrameUnproved;
    if (!std.mem.eql(u8, selected.context_type, "sub") and !std.mem.eql(u8, selected.context_type, "main")) return error.PerlWatchFrameUnsupported;
    const thread = for (session.target.threadSlice()) |entry| {
        if (entry.tid == tid) break entry.id;
    } else return error.InvalidThread;
    var capture = WatchCapture{ .scope = .{
        .language = c.XLW_PERL,
        .session = session.id,
        .image = session.target.snapshot().image_epoch,
        .thread = thread,
        .runtime = .{ (try valueModule(session)).id, try std.fmt.parseInt(u64, instance_.address, 0), selected.stackinfo, 0 },
        .frame = .{ if (selected.stackinfo == 0) 0 else selected.context_index + 1, try std.fmt.parseInt(u64, selected.cv, 0), 0, 0 },
    }, .expression = try a.dupeZ(u8, expression orelse "binding") };
    try watchValue(session, a, &capture, frame, try std.fmt.parseInt(u64, selected.context_address, 0), row);
    if (row != null and capture.scope.frame[2] == 0) return error.PerlWatchBindingUnavailable;
    try session.target.expectGeneration(observed.generation);
    return capture;
}
pub fn observeWatch(session: *model.Session, a: A, tid: i32, scope: c.struct_xlw_scope, expression: []const u8) !WatchCapture {
    var capture = WatchCapture{ .scope = scope, .expression = try a.dupeZ(u8, expression) };
    const observed = try @import("../model/language_selection.zig").cachedRead(.perl, session, tid);
    const module_id = (try valueModule(session)).id;
    if (module_id != scope.runtime[0]) {
        capture.scope.runtime[0] = module_id;
        capture.diagnostic = try a.dupeZ(u8, "PerlWatchRuntimeChanged");
        return capture;
    }
    var saw_runtime = false;
    var complete = true;
    for (observed.segments) |segment_| {
        const instance_ = segment_.runtime_instance orelse continue;
        if (try std.fmt.parseInt(u64, instance_.address, 0) != scope.runtime[1]) continue;
        saw_runtime = true;
        complete = complete and segment_.chain_complete;
        for (segment_.frames, 0..) |frame, index| {
            if (frame.stackinfo != scope.runtime[2] or (if (frame.stackinfo == 0) @as(u64, 0) else frame.context_index + 1) != scope.frame[0]) continue;
            if (!frame.identity_proved) {
                capture.diagnostic = try a.dupeZ(u8, frame.reason orelse "PerlWatchFrameUnproved");
                return capture;
            }
            if (try std.fmt.parseInt(u64, frame.cv, 0) != scope.frame[1]) continue;
            try watchValue(session, a, &capture, index, try std.fmt.parseInt(u64, frame.context_address, 0), null);
            try session.target.expectGeneration(observed.generation);
            return capture;
        }
    }
    if (saw_runtime and complete) {
        capture.observation = c.XLW_FRAME_GONE;
        capture.diagnostic = try a.dupeZ(u8, "PerlWatchFrameGone");
    } else capture.diagnostic = try a.dupeZ(u8, "PerlWatchFrameNotObserved");
    try session.target.expectGeneration(observed.generation);
    return capture;
}
