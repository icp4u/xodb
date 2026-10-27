//! GDScript (Godot 4 / Redot) call stacks from stopped memory. No target
//! code is called and nothing is written.
//!
//! The engine keeps one thread-local reverse list of `CallLevel` records,
//! each a local of one `GDScriptFunction::call` native frame. The list head
//! and its length are thread-locals of the main executable; struct layouts
//! come from that executable's own DWARF (editor and template builds differ).
//! Everything read from the target is untrusted: every pointer, length and
//! chain is bounded and checked before it is used.
const std = @import("std");
const c = @import("../c.zig").api;
const Context = @import("context.zig").Context;
const Module = @import("context.zig").Module;
const tls = @import("../binary/tls.zig");
const A = std.mem.Allocator;

pub const singleton_symbol = "_ZN16GDScriptLanguage9singletonE";
const call_stack_symbol = "_ZN16GDScriptLanguage11_call_stackE";
const call_stack_size_symbol = "_ZN16GDScriptLanguage16_call_stack_sizeE";
/// `GDScriptFunction::call(...)`, and the parts a compiler splits from it.
const call_prefix = "_ZN16GDScriptFunction4callE";

/// Levels walked to prove the chain length, and levels decoded for display.
pub const max_chain = 1024;
pub const max_frames = 64;
/// Code points kept of one engine string; longer ones are cut and marked.
pub const max_chars = 1024;
/// Target reads allowed for one stack: the walk, plus every decoded level.
const max_reads = max_chain + 1 + max_frames * 16 + 16;
/// DIEs visited to find the layouts: about six times what a 1.4 GB engine needs.
const dwarf_work = 1 << 25;

pub const values = @import("gdscript_values.zig");
pub const Field = @import("layouts.zig").GDScriptField;
const stack_type_names = [_][*:0]const u8{ "GDScriptLanguage::CallLevel", "GDScriptFunction", "GDScript", "GDScriptInstance", "GDScriptLanguage", "StringName::_Data", "StringName", "String", "Engine" };
fn want(owner: u8, name: [*:0]const u8, kind: c_uint, width: u8, optional: bool) c.struct_xdt_field {
    return .{ .owner = owner, .name = name, .kind = @intCast(kind), .width = width, .optional = @intFromBool(optional) };
}
// In `Field` order.
const stack_wanted = [_]c.struct_xdt_field{
    want(0, "stack", c.XDT_POINTER, 8, false),
    want(0, "function", c.XDT_POINTER, 8, false),
    want(0, "instance", c.XDT_POINTER, 8, false),
    want(0, "ip", c.XDT_POINTER, 8, false),
    want(0, "line", c.XDT_POINTER, 8, false),
    want(0, "prev", c.XDT_POINTER, 8, false),
    want(1, "name", c.XDT_ANY, 8, false),
    want(1, "source", c.XDT_ANY, 8, false),
    want(1, "_script", c.XDT_POINTER, 8, false),
    want(2, "path", c.XDT_ANY, 8, false),
    want(3, "owner_id", c.XDT_ANY, 8, true),
    want(4, "track_call_stack", c.XDT_BOOLEAN, 1, false),
    want(4, "_debug_max_call_stack", c.XDT_UNSIGNED, 4, false),
    want(5, "name", c.XDT_ANY, 8, false),
    want(6, "_data", c.XDT_POINTER, 8, false),
    want(7, "_cowdata", c.XDT_ANY, 8, false),
    want(8, "_process_frames", c.XDT_UNSIGNED, 8, true),
    want(8, "_physics_frames", c.XDT_UNSIGNED, 8, true),
    want(8, "_in_physics", c.XDT_BOOLEAN, 1, true),
};
comptime {
    std.debug.assert(stack_wanted.len == @typeInfo(Field).@"enum".fields.len);
}
// The value reader's types follow, each of them optional: a build without
// one of them still has its stack.
const type_names = stack_type_names ++ values.type_names;
const wanted = stack_wanted ++ values.wanted(stack_type_names.len);

pub const Layout = @import("layouts.zig").GDScript;

/// Counted target reads. Tests supply their own memory.
pub const Memory = struct {
    context: *anyopaque,
    readFn: *const fn (*anyopaque, u64, []u8) bool,
    reads: usize = 0,
    bytes: usize = 0,
    limit: usize = max_reads,
    pub fn read(self: *Memory, address: u64, out: []u8) bool {
        if (self.reads >= self.limit) return false;
        self.reads += 1;
        self.bytes += out.len;
        if (address > std.math.maxInt(u64) - out.len) return false;
        return self.readFn(self.context, address, out);
    }
    pub fn word(self: *Memory, address: u64) ?u64 {
        var bytes: [8]u8 = undefined;
        return if (self.read(address, &bytes)) std.mem.readInt(u64, &bytes, .little) else null;
    }
};

pub const Text = struct { text: []const u8 = "", reason: ?[]const u8 = null, truncated: bool = false, length: u64 = 0 };
/// An engine `String`: one pointer to UTF-32 data. Its CowData header keeps
/// a reference count at -16 and the element count, terminator included, at
/// -8. The header is checked against the data it describes: the count must
/// lead to the terminator and every element must be a code point.
pub fn string(memory: *Memory, a: A, data: u64) !Text {
    return stringCut(memory, a, data, max_chars);
}
/// The same, keeping at most `most` (<= max_chars) code points.
pub fn stringCut(memory: *Memory, a: A, data: u64, most: usize) !Text {
    if (data == 0) return .{};
    if (data < 16 or data % 4 != 0) return .{ .reason = "GDScriptStringInvalid" };
    var header: [16]u8 = undefined;
    if (!memory.read(data - 16, &header)) return .{ .reason = "GDScriptStringUnreadable" };
    const references = std.mem.readInt(u64, header[0..8], .little);
    const size = std.mem.readInt(u64, header[8..16], .little);
    if (references == 0 or references > std.math.maxInt(u32) or size == 0 or size > 1 << 24) return .{ .reason = "GDScriptStringInvalid" };
    const whole = size <= most + 1;
    const units: usize = if (whole) @intCast(size) else most;
    var raw: [(max_chars + 1) * 4]u8 = undefined;
    if (!memory.read(data, raw[0 .. units * 4])) return .{ .reason = "GDScriptStringUnreadable" };
    const body = if (whole) units - 1 else units;
    if (whole and std.mem.readInt(u32, raw[body * 4 ..][0..4], .little) != 0) return .{ .reason = "GDScriptStringInvalid" };
    var out: std.ArrayList(u8) = .empty;
    for (0..body) |i| {
        const point = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        if (point == 0 or point > 0x10ffff or (point >= 0xd800 and point <= 0xdfff)) return .{ .reason = "GDScriptStringInvalid" };
        // Control characters never reach a status line or a terminal: C0,
        // DEL, and C1 (U+009B is a terminal's CSI even as UTF-8).
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(if (point < 0x20 or (point >= 0x7f and point < 0xa0)) '?' else @intCast(point), &encoded) catch unreachable;
        try out.appendSlice(a, encoded[0..n]);
    }
    return .{ .text = try out.toOwnedSlice(a), .truncated = !whole, .length = size - 1 };
}
/// A `StringName` stored at `address`: a pointer to shared `_Data`, whose
/// `name` is a String. Null is the empty name.
pub fn stringName(memory: *Memory, a: A, layout: *const Layout, address: u64) !Text {
    const data = memory.word(address +% layout.at(.string_name_data)) orelse return .{ .reason = "GDScriptStringUnreadable" };
    return nameData(memory, a, layout, data);
}
/// The name behind a `StringName::_Data` pointer. Names are interned: equal
/// names are one pointer.
pub fn nameData(memory: *Memory, a: A, layout: *const Layout, data: u64) !Text {
    if (data == 0) return .{};
    if (data % 8 != 0) return .{ .reason = "GDScriptStringInvalid" };
    const chars = memory.word(data +% layout.at(.name_string) +% layout.at(.string_data)) orelse return .{ .reason = "GDScriptStringUnreadable" };
    return string(memory, a, chars);
}

pub const Bounds = struct { low: u64, high: u64 };
pub const Level = struct {
    address: u64,
    stack: u64 = 0,
    function: u64,
    instance: u64,
    line_address: u64,
    name: []const u8 = "",
    file: ?[]const u8 = null,
    script_path: ?[]const u8 = null,
    line: ?u32 = null,
    owner_id: ?u64 = null,
    reason: ?[]const u8 = null,
};
pub const Chain = struct {
    /// Innermost first; at most `max_frames`.
    levels: []Level = &.{},
    /// Levels linked from the head, as far as the walk got.
    depth: usize = 0,
    /// What the engine counts (`_call_stack_size`).
    size: u32 = 0,
    /// The list ended at null and its length is the engine's count (or one
    /// more, while the innermost level is being linked or unlinked).
    complete: bool = false,
    /// The innermost level is linked but not counted: the engine is entering
    /// or leaving that call and its fields may be stale.
    top_in_transition: bool = false,
    reason: ?[]const u8 = null,
};
/// Walk the list from `head`. `thread_stack` is the part of the thread's stack that
/// can hold live frames; a level outside it, misaligned, or not above the one
/// before it ends the walk. At most `max_chain` + 1 levels are read.
pub fn chain(memory: *Memory, a: A, layout: *const Layout, head: u64, size: u32, limit: u32, thread_stack: Bounds) !Chain {
    var out = Chain{ .size = size };
    if (size > limit) {
        out.reason = "GDScriptCallStackSizeInvalid";
        return out;
    }
    const level_size: usize = layout.level_size;
    var raw: [256]u8 = undefined;
    if (level_size > raw.len) return error.GDScriptLayoutUnsupported;
    var levels: std.ArrayList(Level) = .empty;
    const most: usize = @min(@as(usize, limit), max_chain) + 1;
    var at = head;
    var previous: u64 = 0;
    while (at != 0) {
        if (out.depth == most) {
            out.reason = "GDScriptCallStackSizeMismatch";
            break;
        }
        if (at % 8 != 0 or at < thread_stack.low or at >= thread_stack.high or thread_stack.high - at < level_size) {
            out.reason = "GDScriptCallLevelOutsideStack";
            break;
        }
        // A callee's frame is below its caller's: addresses only grow.
        if (out.depth != 0 and at <= previous) {
            out.reason = "GDScriptCallLevelOrder";
            break;
        }
        if (!memory.read(at, raw[0..level_size])) {
            out.reason = "GDScriptCallLevelUnreadable";
            break;
        }
        if (levels.items.len < max_frames) try levels.append(a, .{
            .address = at,
            .stack = std.mem.readInt(u64, raw[layout.at(.level_stack)..][0..8], .little),
            .function = std.mem.readInt(u64, raw[layout.at(.level_function)..][0..8], .little),
            .instance = std.mem.readInt(u64, raw[layout.at(.level_instance)..][0..8], .little),
            .line_address = std.mem.readInt(u64, raw[layout.at(.level_line)..][0..8], .little),
        });
        out.depth += 1;
        previous = at;
        at = std.mem.readInt(u64, raw[layout.at(.level_prev)..][0..8], .little);
    }
    if (out.reason == null) {
        if (out.depth == size) {
            out.complete = true;
        } else if (out.depth == @as(usize, size) + 1) {
            out.complete = true;
            out.top_in_transition = true;
        } else out.reason = "GDScriptCallStackSizeMismatch";
    }
    for (levels.items, 0..) |*level, i| {
        try decode(memory, a, layout, level, thread_stack);
        if (i == 0 and out.top_in_transition) level.reason = "GDScriptCallLevelInTransition";
    }
    out.levels = try levels.toOwnedSlice(a);
    return out;
}
fn decode(memory: *Memory, a: A, layout: *const Layout, level: *Level, thread_stack: Bounds) !void {
    if (level.function == 0 or level.function % 8 != 0) {
        level.reason = "GDScriptFunctionInvalid";
        return;
    }
    const name = try stringName(memory, a, layout, level.function +% layout.at(.function_name));
    level.name = name.text;
    level.reason = name.reason;
    // `source` is what the engine itself reports for a stack level.
    const source = try stringName(memory, a, layout, level.function +% layout.at(.function_source));
    if (source.text.len != 0) level.file = source.text;
    if (level.reason == null) level.reason = source.reason;
    if (memory.word(level.function +% layout.at(.function_script))) |script| {
        if (script != 0 and script % 8 == 0) {
            if (memory.word(script +% layout.at(.script_path) +% layout.at(.string_data))) |chars| {
                const path = try string(memory, a, chars);
                if (path.text.len != 0) level.script_path = path.text;
            }
        }
    }
    if (level.file == null) level.file = level.script_path;
    // The current line is a local of the same native frame.
    if (level.line_address % 4 == 0 and level.line_address >= thread_stack.low and level.line_address < thread_stack.high and thread_stack.high - level.line_address >= 4) {
        var bytes: [4]u8 = undefined;
        if (memory.read(level.line_address, &bytes)) {
            const line = std.mem.readInt(i32, &bytes, .little);
            if (line >= 0 and line < 1 << 24) level.line = @intCast(line);
        }
    }
    if (level.line == null and level.reason == null) level.reason = "GDScriptLineUnavailable";
    if (layout.offsets[@intFromEnum(Field.instance_owner_id)]) |offset| {
        if (level.instance != 0 and level.instance % 8 == 0) level.owner_id = memory.word(level.instance +% offset);
    }
}

pub fn sessionRead(context: *anyopaque, address: u64, out: []u8) bool {
    const session: *const Context = @ptrCast(@alignCast(context));
    return (session.readMemory(address, out) catch return false) == out.len;
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
pub fn buildId(a: A, layout: *const Layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
fn overBudget(err: anyerror) bool {
    return err == error.BinarySnapshotLimit or err == error.SymbolSnapshotLimit;
}
fn moduleError(err: anyerror) error{ GDScriptImageBudgetExceeded, DebugMetadataPending, DebugMetadataCancelled, SymbolDiscoveryPending, SymbolDiscoveryCancelled, SymbolDiscoveryBudgetExceeded, GDScriptModuleIdentityUnavailable } {
    if (overBudget(err)) return error.GDScriptImageBudgetExceeded;
    if (err == error.DebugMetadataPending) return error.DebugMetadataPending;
    if (err == error.DebugMetadataCancelled) return error.DebugMetadataCancelled;
    if (err == error.SymbolDiscoveryPending) return error.SymbolDiscoveryPending;
    if (err == error.SymbolDiscoveryCancelled) return error.SymbolDiscoveryCancelled;
    if (err == error.SymbolDiscoveryBudgetExceeded) return error.SymbolDiscoveryBudgetExceeded;
    return error.GDScriptModuleIdentityUnavailable;
}
/// The engine is the main executable, found by the kernel's own record of
/// its program headers: only the executable's thread-locals have a fixed
/// place, and an engine's symbol tables are too large for a name scan. The
/// Remote layout reads use a types-only section projection under image budgets.
pub fn runtimeModule(session: *const Context) !Module {
    try session.languages.require(.gdscript);
    try session.refreshMaps();
    const main_phdr = session.mainPhdr();
    if (main_phdr == 0) return error.GDScriptModuleIdentityUnavailable;
    const module = session.runtimeModuleAt(main_phdr) catch |err| return moduleError(err);
    if (module.layouts.gdscript != null) return module;
    const singleton = module.symbols().findSymbol(singleton_symbol) orelse return error.GDScriptRuntimeUnavailable;
    if (!singleton.hasAddress()) return error.GDScriptRuntimeUnavailable;
    return module;
}
fn layoutError(why: []const u8) anyerror {
    if (std.mem.eql(u8, why, "DwarfTypesUnavailable")) return error.GDScriptDwarfUnavailable;
    if (std.mem.eql(u8, why, "DwarfTypesWorkLimit") or std.mem.eql(u8, why, "DwarfTypesUnitLimit")) return error.GDScriptDwarfWorkLimit;
    if (std.mem.eql(u8, why, "DwarfTypesMalformed")) return error.GDScriptDwarfMalformed;
    // A type or member is missing, differs between units, or is not what
    // this reader knows how to read.
    return error.GDScriptLayoutUnsupported;
}
fn tlsObject(module: Module, block: tls.Block, name: []const u8, size: u64) !u64 {
    const symbol = module.symbols().findSymbol(name) orelse return error.GDScriptCallStackSymbolUnavailable;
    if (symbol.type != .tls) return error.GDScriptCallStackSymbolUnavailable;
    if (symbol.size != size) return error.GDScriptLayoutUnsupported;
    // Checked here once; the per-thread address is `executableAddress`.
    _ = tls.executableAddress(block, block.below, symbol.value, size) catch return error.GDScriptLayoutUnsupported;
    return symbol.value;
}
pub fn profile(session: *const Context, module: Module) !*const Layout {
    if (!session.snapshot().stopped) return error.NotStopped;
    if (session.arch() != .x86_64) return error.GDScriptArchitectureUnsupported;
    // The DWARF read from the file must describe the image that is running.
    const id = module.image.buildId() orelse return error.GDScriptBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.GDScriptBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.GDScriptBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.GDScriptBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len])) return error.GDScriptBuildIdMismatch;
    if (module.layouts.gdscript) |*layout| {
        if (!std.mem.eql(u8, layout.build_id[0..layout.build_id_len], id)) return error.GDScriptBuildIdMismatch;
        return layout;
    }
    if (module.layouts.gdscript_refusal) |why| return why;
    const singleton = module.symbols().findSymbol(singleton_symbol) orelse return error.GDScriptRuntimeUnavailable;
    if (!singleton.hasAddress() or singleton.size != 8) return error.GDScriptRuntimeUnavailable;
    const block = tls.imageBlock(module.image) catch return error.GDScriptCallStackSymbolUnavailable;
    const call_stack = try tlsObject(module, block, call_stack_symbol, 8);
    const call_stack_size = try tlsObject(module, block, call_stack_size_symbol, 4);
    const debug = module.debugInfo() catch |err| return if (err == error.DebugMetadataPending) err else error.GDScriptDwarfUnavailable;
    const schema = c.struct_xdt_schema{ .types = @ptrCast(&type_names), .fields = &wanted, .type_count = type_names.len, .field_count = wanted.len, .optional_types = (((@as(u64, 1) << values.type_names.len) - 1) << stack_type_names.len) | (1 << 8) };
    var slots: [wanted.len]c.struct_xdt_slot = undefined;
    var sizes: [type_names.len]u32 = undefined;
    comptime std.debug.assert(wanted.len <= c.XDT_MAX_FIELDS and type_names.len <= c.XDT_MAX_TYPES);
    var stats: c.struct_xdt_stats = undefined;
    // A refusal is the answer for this image: the search is not repeated at
    // every stop and for every request.
    if (c.xdt_layout_build(debug.dwarf, &schema, dwarf_work, &slots, &sizes, &stats)) |why| {
        module.layouts.gdscript_refusal = layoutError(std.mem.span(why));
        return module.layouts.gdscript_refusal.?;
    }
    // String and StringName are one pointer each; a level holds six.
    if (sizes[6] != 8 or sizes[7] != 8 or sizes[0] < 48 or sizes[0] > 256) {
        module.layouts.gdscript_refusal = error.GDScriptLayoutUnsupported;
        return error.GDScriptLayoutUnsupported;
    }
    var layout = Layout{ .level_size = sizes[0], .offsets = undefined, .block = block, .call_stack = call_stack, .call_stack_size = call_stack_size, .singleton = try module.runtimeAddress(singleton.value), .units = stats.units };
    if (module.symbols().findSymbol("_ZN6Engine9singletonE")) |engine| {
        if (engine.hasAddress() and engine.size == 8) layout.engine_singleton = try module.runtimeAddress(engine.value);
    }
    for (slots[0..stack_wanted.len], &layout.offsets) |slot, *offset| offset.* = if (slot.present != 0) slot.offset else null;
    for (slots[stack_wanted.len..][0..values.field_count], &layout.value_offsets) |slot, *offset| offset.* = if (slot.present != 0) slot.offset else null;
    for (slots[stack_wanted.len + values.field_count ..], &layout.kinds) |slot, *kind| kind.* = if (slot.present != 0) slot.offset else null;
    @memcpy(&layout.value_sizes, sizes[stack_type_names.len..]);
    if (module.symbols().findSymbol(values.instance_vtable_symbol)) |vtable| {
        // An object's vtable pointer is past the offset-to-top and RTTI slots.
        if (vtable.hasAddress() and vtable.size >= 16) layout.instance_vtable = (module.runtimeAddress(vtable.value) catch 0) +% 16;
    }
    @memcpy(layout.build_id[0..id.len], id);
    layout.build_id_len = @intCast(id.len);
    module.layouts.gdscript = layout;
    return &module.layouts.gdscript.?;
}
pub const FrameCounters = struct { process: u64, physics: u64, in_physics: bool };
pub fn frameCounters(session: *const Context) !FrameCounters {
    const layout = try profile(session, try runtimeModule(session));
    var memory = Memory{ .context = @constCast(session), .readFn = sessionRead };
    const pointer = layout.engine_singleton orelse return error.RedotFrameCounterUnavailable;
    const engine = memory.word(pointer) orelse return error.RedotFrameCounterUnreadable;
    if (engine == 0) return error.RedotFrameCounterUnavailable;
    const process = layout.offsets[@intFromEnum(Field.engine_process_frames)] orelse return error.RedotFrameCounterUnavailable;
    const physics = layout.offsets[@intFromEnum(Field.engine_physics_frames)] orelse return error.RedotFrameCounterUnavailable;
    const inside = layout.offsets[@intFromEnum(Field.engine_in_physics)] orelse return error.RedotFrameCounterUnavailable;
    var flag: [1]u8 = undefined;
    if (!memory.read(engine +% inside, &flag) or flag[0] > 1) return error.RedotFrameCounterUnreadable;
    return .{ .process = memory.word(engine +% process) orelse return error.RedotFrameCounterUnreadable, .physics = memory.word(engine +% physics) orelse return error.RedotFrameCounterUnreadable, .in_physics = flag[0] != 0 };
}
const Language = struct { address: u64, limit: u32 };
/// The language singleton's own switches. A build that does not track the
/// call stack (a release template without the project setting) has no list.
fn language(memory: *Memory, layout: *const Layout) !Language {
    const address = memory.word(layout.singleton) orelse return error.GDScriptLanguageUnreadable;
    if (address == 0) return error.GDScriptLanguageNotInitialized;
    if (address % 8 != 0) return error.GDScriptLayoutMismatch;
    var track: [1]u8 = undefined;
    var limit: [4]u8 = undefined;
    if (!memory.read(address +% layout.at(.language_track), &track) or !memory.read(address +% layout.at(.language_max), &limit)) return error.GDScriptLanguageUnreadable;
    if (track[0] > 1) return error.GDScriptLayoutMismatch;
    if (track[0] == 0) return error.GDScriptCallStackNotTracked;
    const most = std.mem.readInt(u32, &limit, .little);
    if (most == 0 or most > 1 << 24) return error.GDScriptLayoutMismatch;
    return .{ .address = address, .limit = most };
}

pub const Anchor = struct {
    frame: usize,
    pc: []const u8,
    symbol: ?[]const u8,
    call_level: []const u8,
    proof: []const u8 = "CallLevel record inside this GDScriptFunction::call frame's [sp, cfa)",
};
pub const Runtime = struct { language: []const u8 = "gdscript", implementation: []const u8 = "godot-vm", version: []const u8 = version_text, build_id: []const u8, layout: []const u8 = layout_text };
const version_text = "debug-enabled build";
const layout_text = "DWARF + static TLS";
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "gdscript:language", address: []const u8, scope: []const u8 = "this process instance" };
pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: ?u32,
    kind: []const u8 = "script",
    provenance: []const u8 = "external_read",
    call_level: []const u8,
    function: []const u8,
    instance: ?[]const u8,
    owner_id: ?u64,
    script_path: ?[]const u8,
    native_binding: ?Anchor,
    reason: ?[]const u8,
};
pub const Segment = struct {
    title: []const u8,
    runtime: Runtime,
    runtime_instance: Instance,
    /// The innermost level's native frame, then those of the outer levels.
    anchor: ?Anchor,
    additional_anchors: []const Anchor,
    source_kind: []const u8 = "stopped_snapshot",
    state: []const u8,
    reason: ?[]const u8,
    frames: []Frame,
    /// Levels linked on this thread, and the engine's own count of them.
    depth: usize,
    call_stack_size: u32,
    max_call_stack: u32,
    chain_complete: bool,
    top_in_transition: bool,
    truncated: bool,
    /// Native `GDScriptFunction::call` frames in the unwound stack, and the
    /// innermost one when it holds no level yet (entering or leaving a call).
    native_call_frames: usize,
    native_call_frame_without_level: ?usize,
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    in_script: bool,
    segments: []Segment,
    native_stack_incomplete: bool,
    /// For views: every frame names its own native frame, and paths are
    /// project paths (res://...) to show whole.
    level_per_native_frame: bool = true,
    memory_reads: usize,
    memory_bytes: usize,
    basis: []const u8 = "GDScriptLanguage thread-local call stack of the main executable (fs_base, PT_TLS); layouts from the image's own DWARF, image proved by build-id; chain bounded by the engine's own count and limit and by the thread's stack; each level joined to the native frame that contains it; no inferior calls",
};
fn isCall(symbol: ?[]const u8) bool {
    return if (symbol) |name| std.mem.startsWith(u8, name, call_prefix) else false;
}
const Range = struct { low: u64, high: u64, call: bool };
/// The native frame whose [sp, cfa) holds `size` bytes at `address`.
fn containing(ranges: []const Range, address: u64, size: u64) ?usize {
    for (ranges, 0..) |range, i| {
        if (range.high > range.low and address >= range.low and address < range.high and range.high - address >= size) return i;
    }
    return null;
}
const Join = struct { frames: [max_frames]?usize = @splat(null), reason: ?[]const u8 = null, without_level: ?usize = null, calls: usize = 0 };
/// Pair levels (innermost first) with native frames. Every level must sit in
/// a `GDScriptFunction::call` frame, deeper levels in outer frames, and when
/// the native stack is whole the two counts must agree: one innermost call
/// frame may hold no level while the engine enters or leaves it.
fn join(levels: []const Level, level_size: u64, depth: usize, ranges: []const Range, native_whole: bool) Join {
    var out = Join{};
    for (ranges) |range| {
        if (range.call) out.calls += 1;
    }
    var last: ?usize = null;
    for (levels, 0..) |level, i| {
        const found = containing(ranges, level.address, level_size) orelse {
            if (native_whole and out.reason == null) out.reason = "GDScriptNativeFrameNotFound";
            continue;
        };
        if (!ranges[found].call or (last != null and found <= last.?)) {
            if (out.reason == null) out.reason = "GDScriptNativeJoinInconsistent";
            continue;
        }
        out.frames[i] = found;
        last = found;
    }
    const innermost = for (ranges, 0..) |range, i| {
        if (range.call) break i;
    } else null;
    if (innermost) |frame| {
        if (levels.len == 0 or out.frames[0] == null or out.frames[0].? != frame) out.without_level = frame;
    }
    if (native_whole and out.reason == null) {
        const expected = depth + @intFromBool(out.without_level != null);
        if (out.calls != expected) out.reason = "GDScriptNativeFrameCountMismatch";
    }
    return out;
}

pub fn stack(session: *const Context, a: A, tid: i32, first: usize) !Stack {
    return stackWithNative(session, a, tid, first, null);
}
/// Reuse an unwind from the same stopped generation for a joined sample.
pub fn stackWithNative(session: *const Context, a: A, tid: i32, first: usize, native_input: ?[]const @import("context.zig").Frame) !Stack {
    try session.languages.require(.gdscript);
    if (first != 0) return error.InvalidFrame;
    if (!session.snapshot().stopped) return error.NotStopped;
    const generation = session.snapshot().generation;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    var memory = Memory{ .context = @constCast(session), .readFn = sessionRead };
    const lang = try language(&memory, layout);
    const native = native_input orelse try session.unwindStack(a, tid, 64);
    if (native.len == 0) return error.InvalidFrame;
    const pointer = (try session.registerValue(tid, "fs_base")) orelse return error.GDScriptThreadPointerUnavailable;
    const head_at = tls.executableAddress(layout.block, pointer, layout.call_stack, 8) catch return error.GDScriptThreadPointerUnavailable;
    const size_at = tls.executableAddress(layout.block, pointer, layout.call_stack_size, 4) catch return error.GDScriptThreadPointerUnavailable;
    const head = memory.word(head_at) orelse return error.GDScriptCallStackUnreadable;
    var size_bytes: [4]u8 = undefined;
    if (!memory.read(size_at, &size_bytes)) return error.GDScriptCallStackUnreadable;
    const size = std.mem.readInt(u32, &size_bytes, .little);
    // Live frames are at or above the stack pointer, inside its mapping.
    const sp = native[0].registers[session.arch().sp()] orelse return error.GDScriptThreadStackUnavailable;
    const region = session.mappedRange(sp) orelse return error.GDScriptThreadStackUnavailable;
    const bounds = Bounds{ .low = sp, .high = region.end };
    const found = try chain(&memory, a, layout, head, size, lang.limit, bounds);

    const ranges = try a.alloc(Range, native.len);
    for (native, ranges) |frame, *range| {
        const low = frame.registers[session.arch().sp()];
        range.* = if (low != null and frame.cfa != null and frame.cfa.? > low.?) .{ .low = low.?, .high = frame.cfa.?, .call = isCall(frame.symbol) } else .{ .low = 0, .high = 0, .call = isCall(frame.symbol) };
    }
    const native_incomplete = native.len == 64 or native[native.len - 1].diagnostic != null;
    const joined = join(found.levels, layout.level_size, found.depth, ranges, !native_incomplete and found.complete);
    const frames = try a.alloc(Frame, found.levels.len);
    var frame_reason: ?[]const u8 = null;
    for (found.levels, frames, 0..) |level, *out, i| {
        var binding: ?Anchor = null;
        var why = level.reason;
        var line = level.line;
        if (joined.frames[i]) |index| {
            const frame = native[index];
            binding = .{ .frame = frame.index, .pc = try hex(a, frame.pc), .symbol = if (frame.symbol) |name| try a.dupe(u8, name) else null, .call_level = try hex(a, level.address) };
            // The line is a local of the same call: it must be in that frame.
            if (line != null and containing(ranges[index .. index + 1], level.line_address, 4) == null) {
                line = null;
                if (why == null) why = "GDScriptLineOutsideFrame";
            }
        }
        if (why != null and frame_reason == null and !(i == 0 and found.top_in_transition)) frame_reason = why;
        out.* = .{
            .name = if (level.name.len != 0) level.name else "<unnamed>",
            .file = level.file,
            .line = line,
            .call_level = try hex(a, level.address),
            .function = try hex(a, level.function),
            .instance = if (level.instance != 0) try hex(a, level.instance) else null,
            .owner_id = level.owner_id,
            .script_path = level.script_path,
            .native_binding = binding,
            .reason = why,
        };
    }
    var outer: std.ArrayList(Anchor) = .empty;
    for (frames, 0..) |frame, i| {
        if (i != 0) if (frame.native_binding) |binding| try outer.append(a, binding);
    }
    const reason = found.reason orelse joined.reason orelse frame_reason;
    const segments = try a.alloc(Segment, 1);
    segments[0] = .{
        .title = if (found.depth == 0 and reason == null) "Not in script code" else try std.fmt.allocPrint(a, "Script stack: {d} level{s}", .{ found.depth, if (found.depth == 1) "" else "s" }),
        .runtime = .{ .build_id = try buildId(a, layout) },
        .runtime_instance = .{ .address = try hex(a, lang.address) },
        .anchor = if (frames.len > 0) frames[0].native_binding else null,
        .additional_anchors = try outer.toOwnedSlice(a),
        .state = if (reason == null) "complete" else "partial",
        .reason = reason,
        .frames = frames,
        .depth = found.depth,
        .call_stack_size = found.size,
        .max_call_stack = lang.limit,
        .chain_complete = found.complete,
        .top_in_transition = found.top_in_transition,
        .truncated = found.depth > frames.len,
        .native_call_frames = joined.calls,
        .native_call_frame_without_level = if (joined.without_level) |index| native[index].index else null,
    };
    try session.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .in_script = found.depth != 0, .segments = segments, .native_stack_incomplete = native_incomplete, .memory_reads = memory.reads, .memory_bytes = memory.bytes };
}
/// Runtime identity and proof for the language tab.
pub fn describe(session: *const Context, a: A) !@import("types.zig").Description {
    try session.languages.require(.gdscript);
    const layout = try profile(session, try runtimeModule(session));
    var memory = Memory{ .context = @constCast(session), .readFn = sessionRead };
    _ = try language(&memory, layout);
    return .{ .version = version_text, .build_id = try buildId(a, layout), .basis = layout_text };
}

const named = @import("locals_types.zig");
pub fn readLocals(session: *const Context, a: A, observed: Stack, tid: i32, segment: usize, frame: usize, start: usize, limit: usize) !named.Result {
    return readBindings(session, a, observed, tid, segment, frame, start, limit, null, null);
}
/// A local, parameter or member name, or `self`, then `.member`, `[index]`
/// and `["key"]` steps: storage only, nothing is evaluated.
pub fn evaluateLocal(session: *const Context, a: A, observed: Stack, tid: i32, segment: usize, frame: usize, text: []const u8, path: values.Path) !named.Result {
    return readBindings(session, a, observed, tid, segment, frame, 0, 1, text, path);
}
fn readBindings(session: *const Context, a: A, observed: Stack, tid: i32, segment: usize, frame: usize, start: usize, limit: usize, expression: ?[]const u8, path: ?values.Path) !named.Result {
    try session.languages.require(.gdscript);
    if (segment != 0 or observed.segments.len != 1) return error.InvalidLanguageSegment;
    if (frame >= observed.segments[0].frames.len) return error.InvalidLanguageFrame;
    const selected = observed.segments[0].frames[frame];
    // A level the engine is still entering or leaving has no settled stack.
    if (frame == 0 and observed.segments[0].top_in_transition) return error.GDScriptCallLevelInTransition;
    const layout = try profile(session, try runtimeModule(session));
    if (values.usable(layout) != null) return error.GDScriptValueLayoutUnavailable;
    var memory = Memory{ .context = @constCast(session), .readFn = sessionRead, .limit = if (path == null) values.page_reads else values.path_reads };
    var r = values.Reader{ .memory = &memory, .a = a, .layout = layout };
    const found = try values.frame(&r, .{ .call_level = try std.fmt.parseInt(u64, selected.call_level, 0), .function = try std.fmt.parseInt(u64, selected.function, 0), .line = selected.line });
    var rows: std.ArrayList(named.Row) = .empty;
    var diagnostic = found.diagnostic;
    var total = found.bindings.len;
    var first = @min(start, total);
    if (path) |wanted_path| {
        total = 0;
        first = 0;
        if (try values.resolve(&r, &found, &wanted_path)) |target| {
            total = 1;
            try rows.append(a, try row(&r, expression.?, target.scope, 0, target.slot, values.path_children));
        } else diagnostic = r.why;
    } else for (found.bindings[first..@min(total, first + limit)], first..) |*binding, ordinal|
        try rows.append(a, try row(&r, try values.bindingName(&r, binding), binding.scope, ordinal, binding.slot, values.row_children));
    try session.expectGeneration(observed.generation);
    return .{
        .generation = observed.generation,
        .tid = tid,
        .language = .gdscript,
        .segment = segment,
        .frame = frame,
        .start = first,
        .total = total,
        .truncated = memory.reads >= memory.limit,
        .rows = rows.items,
        .diagnostic = if (memory.reads >= memory.limit) "GDScriptReadLimit" else diagnostic,
        .runtime_version = version_text,
        .runtime_build_id = try buildId(a, layout),
        .basis = "the call level's own Variant stack, its function's debug records and signature, and the instance's script members; Variant, container and object layouts and Variant::Type values from the image's DWARF; object classes from their vtables' type information; bounded reads, no inferior calls",
        .memory_reads = memory.reads,
        .memory_bytes = memory.bytes,
    };
}
fn row(r: *values.Reader, name: []const u8, scope: values.Scope, ordinal: usize, slot: values.Slot, children: usize) !named.Row {
    const described = try r.describe(&slot.raw, children);
    const shown = described.shown;
    return .{
        .name = name,
        .scope = switch (scope) {
            .parameter => .parameter,
            .local => .local,
            .context => .context,
            .member => .member,
        },
        .ordinal = ordinal,
        .address = shown.object,
        .slot_address = slot.address,
        .provenance = switch (scope) {
            .parameter, .local => "Variant slot of the call level's stack",
            .context => "slot 0 of the call level's stack",
            .member => "Variant slot of the script instance's members",
        },
        .value = .{ .count = shown.count, .type = shown.type, .display = shown.display, .diagnostic = shown.reason, .truncated = shown.truncated, .children = described.children },
    };
}

// ---- tests: synthetic memory only ----
const Fake = struct {
    base: u64,
    bytes: []u8,
    fn read(context: *anyopaque, address: u64, out: []u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context));
        if (address < self.base or address - self.base > self.bytes.len or self.bytes.len - (address - self.base) < out.len) return false;
        @memcpy(out, self.bytes[@intCast(address - self.base)..][0..out.len]);
        return true;
    }
    fn put(self: *Fake, address: u64, value: u64) void {
        std.mem.writeInt(u64, self.bytes[@intCast(address - self.base)..][0..8], value, .little);
    }
    fn put32(self: *Fake, address: u64, value: u32) void {
        std.mem.writeInt(u32, self.bytes[@intCast(address - self.base)..][0..4], value, .little);
    }
    /// A CowData string at `address` (header below it); returns the data pointer.
    fn text(self: *Fake, address: u64, value: []const u8) u64 {
        self.put(address - 16, 1);
        self.put(address - 8, value.len + 1);
        for (value, 0..) |byte, i| self.put32(address + i * 4, byte);
        self.put32(address + value.len * 4, 0);
        return address;
    }
    fn memory(self: *Fake) Memory {
        return .{ .context = self, .readFn = read };
    }
};
const test_layout = Layout{
    .level_size = 48,
    // stack, function, instance, ip, line, prev; name, source, _script; path; owner_id; track, max; _Data.name; _data; _cowdata
    .offsets = .{ 0, 8, 16, 24, 32, 40, 0, 8, 0xf0, 0x3b8, 8, 0x1b4, 0x1b0, 8, 0, 0, null, null, null },
    .block = .{ .below = 0xa30, .size = 0xa28 },
    .call_stack = 0xe8,
    .call_stack_size = 0xe0,
    .singleton = 0,
    .units = 1,
};
const heap: u64 = 0x10000;
const stack_low: u64 = 0x40000;
const stack_high: u64 = 0x42000;
/// Heap [0x10000, 0x20000) and a thread stack [0x40000, 0x42000) in one
/// buffer; three functions f0..f2 of res://a.gd with levels at increasing
/// addresses, innermost first.
fn world(a: A) !Fake {
    var fake = Fake{ .base = heap, .bytes = try a.alloc(u8, stack_high - heap) };
    @memset(fake.bytes, 0);
    const path = fake.text(0x11000, "res://a.gd");
    fake.put(0x11800 + 8, path); // StringName::_Data for the source
    fake.put(0x12000 + 0x3b8, path); // GDScript.path
    for (0..3) |i| {
        const function = 0x13000 + i * 0x1000;
        const name = fake.text(0x18000 + i * 0x100, &.{ 'f', '0' + @as(u8, @intCast(i)) });
        fake.put(0x19000 + i * 0x100 + 8, name); // _Data.name
        fake.put(function + 0, 0x19000 + i * 0x100);
        fake.put(function + 8, 0x11800);
        fake.put(function + 0xf0, 0x12000);
        const level = stack_low + 0x100 + i * 0x200;
        fake.put(level + 8, function);
        fake.put(level + 16, 0x1a000); // instance
        fake.put(level + 32, level + 0x40); // &line, in the same frame
        fake.put32(level + 0x40, @intCast(10 + i));
        fake.put(level + 40, if (i == 2) 0 else level + 0x200);
    }
    fake.put(0x1a000 + 8, 0x1234); // owner_id
    return fake;
}
test "a consistent chain yields names, paths and lines, innermost first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = try world(a);
    var memory = fake.memory();
    const found = try chain(&memory, a, &test_layout, stack_low + 0x100, 3, 1024, .{ .low = stack_low, .high = stack_high });
    try std.testing.expect(found.complete and !found.top_in_transition and found.reason == null);
    try std.testing.expectEqual(@as(usize, 3), found.depth);
    for (found.levels, 0..) |level, i| {
        try std.testing.expectEqualStrings(&.{ 'f', '0' + @as(u8, @intCast(i)) }, level.name);
        try std.testing.expectEqualStrings("res://a.gd", level.file.?);
        try std.testing.expectEqualStrings("res://a.gd", level.script_path.?);
        try std.testing.expectEqual(@as(?u32, @intCast(10 + i)), level.line);
        try std.testing.expectEqual(@as(?u64, 0x1234), level.owner_id);
        try std.testing.expect(level.reason == null);
    }
    // No script on this thread.
    const idle = try chain(&memory, a, &test_layout, 0, 0, 1024, .{ .low = stack_low, .high = stack_high });
    try std.testing.expect(idle.complete and idle.depth == 0 and idle.levels.len == 0 and idle.reason == null);
}
test "one level linked but not counted is a transition, anything else a mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = try world(a);
    var memory = fake.memory();
    const bounds = Bounds{ .low = stack_low, .high = stack_high };
    const entering = try chain(&memory, a, &test_layout, stack_low + 0x100, 2, 1024, bounds);
    try std.testing.expect(entering.complete and entering.top_in_transition and entering.reason == null and entering.depth == 3);
    try std.testing.expectEqualStrings("GDScriptCallLevelInTransition", entering.levels[0].reason.?);
    try std.testing.expect(entering.levels[1].reason == null);
    // A half-written innermost level: its function pointer is not one yet.
    fake.put(stack_low + 0x100 + 8, 0x1337);
    const half = try chain(&memory, a, &test_layout, stack_low + 0x100, 2, 1024, bounds);
    try std.testing.expect(half.complete and half.top_in_transition and half.depth == 3);
    try std.testing.expectEqualStrings("GDScriptCallLevelInTransition", half.levels[0].reason.?);
    try std.testing.expectEqualStrings("f1", half.levels[1].name);
    for ([_]u32{ 0, 1, 4, 5 }) |count| {
        const wrong = try chain(&memory, a, &test_layout, stack_low + 0x100, count, 1024, bounds);
        try std.testing.expect(!wrong.complete);
        try std.testing.expectEqualStrings("GDScriptCallStackSizeMismatch", wrong.reason.?);
    }
    const none = try chain(&memory, a, &test_layout, 0, 2, 1024, bounds);
    try std.testing.expectEqualStrings("GDScriptCallStackSizeMismatch", none.reason.?);
    const over = try chain(&memory, a, &test_layout, stack_low + 0x100, 9, 8, bounds);
    try std.testing.expectEqualStrings("GDScriptCallStackSizeInvalid", over.reason.?);
    try std.testing.expectEqual(@as(usize, 0), over.depth);
}
test "the walk stops at cycles, levels off the stack and unreadable levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = try world(a);
    const bounds = Bounds{ .low = stack_low, .high = stack_high };
    const first = stack_low + 0x100;
    // A cycle: the outermost level points back at the innermost.
    fake.put(first + 0x400 + 40, first);
    var memory = fake.memory();
    const cycle = try chain(&memory, a, &test_layout, first, 3, 1024, bounds);
    try std.testing.expectEqualStrings("GDScriptCallLevelOrder", cycle.reason.?);
    try std.testing.expect(!cycle.complete and cycle.depth == 3 and memory.reads < 64);
    // A self-link.
    fake.put(first + 40, first);
    memory = fake.memory();
    try std.testing.expectEqualStrings("GDScriptCallLevelOrder", (try chain(&memory, a, &test_layout, first, 3, 1024, bounds)).reason.?);
    // Into the heap, below the stack pointer, misaligned, past the end.
    for ([_]u64{ 0x13000, stack_low + 0x80, first + 0x204, stack_high - 40, stack_high, std.math.maxInt(u64) - 7 }) |bad| {
        fake.put(first + 40, bad);
        memory = fake.memory();
        const out = try chain(&memory, a, &test_layout, first, 3, 1024, .{ .low = stack_low + 0x100, .high = stack_high });
        try std.testing.expectEqualStrings("GDScriptCallLevelOutsideStack", out.reason.?);
        try std.testing.expect(!out.complete and out.depth == 1 and out.levels.len == 1);
        try std.testing.expectEqualStrings("f0", out.levels[0].name);
    }
    // The head itself outside the stack: nothing is read from it.
    memory = fake.memory();
    const outside = try chain(&memory, a, &test_layout, 0x13000, 1, 1024, bounds);
    try std.testing.expect(outside.depth == 0 and memory.reads == 0);
    try std.testing.expectEqualStrings("GDScriptCallLevelOutsideStack", outside.reason.?);
    // Unreadable stack memory.
    var hole = Fake{ .base = heap, .bytes = fake.bytes[0 .. stack_low + 0x100 - heap] };
    memory = hole.memory();
    try std.testing.expectEqualStrings("GDScriptCallLevelUnreadable", (try chain(&memory, a, &test_layout, first, 1, 1024, bounds)).reason.?);
}
test "a chain longer than the engine's limit is cut at the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 3000 well-formed levels, 48 bytes apart, none of them decodable.
    const low: u64 = 0x100000;
    const count = 3000;
    var fake = Fake{ .base = low, .bytes = try a.alloc(u8, count * 48) };
    @memset(fake.bytes, 0);
    for (0..count) |i| fake.put(low + i * 48 + 40, if (i == count - 1) 0 else low + (i + 1) * 48);
    const bounds = Bounds{ .low = low, .high = low + count * 48 };
    var memory = fake.memory();
    const deep = try chain(&memory, a, &test_layout, low, 3000, 1 << 20, bounds);
    try std.testing.expectEqualStrings("GDScriptCallStackSizeMismatch", deep.reason.?);
    try std.testing.expectEqual(@as(usize, max_chain + 1), deep.depth);
    try std.testing.expectEqual(@as(usize, max_frames), deep.levels.len);
    try std.testing.expect(memory.reads <= max_reads);
    for (deep.levels) |level| try std.testing.expectEqualStrings("GDScriptFunctionInvalid", level.reason.?);
    // The engine's own limit is the bound when it is smaller.
    memory = fake.memory();
    const limited = try chain(&memory, a, &test_layout, low, 16, 16, bounds);
    try std.testing.expectEqualStrings("GDScriptCallStackSizeMismatch", limited.reason.?);
    try std.testing.expectEqual(@as(usize, 17), limited.depth);
    // Exactly the count, with more levels than are decoded: complete.
    fake.put(low + 99 * 48 + 40, 0);
    memory = fake.memory();
    const hundred = try chain(&memory, a, &test_layout, low, 100, 1024, bounds);
    try std.testing.expect(hundred.complete and hundred.depth == 100 and hundred.levels.len == max_frames);
}
test "strings are bounded and checked against their own header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .base = heap, .bytes = try a.alloc(u8, 0x10000) };
    @memset(fake.bytes, 0);
    var memory = fake.memory();
    const at = fake.text(0x11000, "res://main.gd");
    try std.testing.expectEqualStrings("res://main.gd", (try string(&memory, a, at)).text);
    try std.testing.expectEqualStrings("", (try string(&memory, a, 0)).text);
    // Non-ASCII code points become UTF-8; control characters are replaced.
    fake.put32(at, 0xe9);
    fake.put32(at + 4, 0x1f600);
    fake.put32(at + 8, 0x1b);
    try std.testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x98\x80?://main.gd", (try string(&memory, a, at)).text);
    fake.put32(at + 12, 0x9b);
    fake.put32(at + 16, 0x7f);
    fake.put32(at + 20, 0xa0);
    try std.testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x98\x80???\xc2\xa0main.gd", (try string(&memory, a, at)).text);
    _ = fake.text(0x11000, "res://main.gd");
    // The count must lead to the terminator.
    fake.put(at - 8, 13);
    try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, at)).reason.?);
    fake.put(at - 8, 15);
    try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, at)).reason.?);
    // Absurd counts and reference counts are refused before any data read.
    for ([_][2]u64{ .{ 1, 0 }, .{ 1, (1 << 24) + 1 }, .{ 1, std.math.maxInt(u64) }, .{ 0, 14 }, .{ 1 << 32, 14 }, .{ 14, 1 << 32 } }) |header| {
        fake.put(at - 16, header[0]);
        fake.put(at - 8, header[1]);
        const before = memory.reads;
        try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, at)).reason.?);
        try std.testing.expectEqual(before + 1, memory.reads);
    }
    fake.put(at - 16, 1);
    fake.put(at - 8, 14);
    // Not code points: a surrogate, a value past U+10FFFF, an early zero.
    for ([_]u32{ 0xd800, 0x110000, 0 }) |unit| {
        fake.put32(at + 12, unit);
        try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, at)).reason.?);
    }
    // Misaligned and impossible pointers, and data that is not mapped.
    try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, at + 2)).reason.?);
    try std.testing.expectEqualStrings("GDScriptStringInvalid", (try string(&memory, a, 8)).reason.?);
    try std.testing.expectEqualStrings("GDScriptStringUnreadable", (try string(&memory, a, 0x90000)).reason.?);
    // A long string is cut at max_chars and says so; its count is trusted
    // only as far as what was read.
    const long = 0x12000;
    fake.put(long - 16, 2);
    fake.put(long - 8, 5000);
    for (0..max_chars + 8) |i| fake.put32(long + i * 4, 'x');
    const cut = try string(&memory, a, long);
    try std.testing.expect(cut.truncated and cut.reason == null);
    try std.testing.expectEqual(@as(usize, max_chars), cut.text.len);
    // A string that runs off mapped memory.
    const edge = heap + 0x10000 - 8;
    fake.put(edge - 16, 1);
    fake.put(edge - 8, 100);
    try std.testing.expectEqualStrings("GDScriptStringUnreadable", (try string(&memory, a, edge)).reason.?);
}
test "levels join native call frames by containment, in order, with counts checked" {
    const levels = [_]Level{
        .{ .address = 0x1100, .function = 8, .instance = 0, .line_address = 0x1140 },
        .{ .address = 0x1500, .function = 8, .instance = 0, .line_address = 0x1540 },
    };
    // native #0 leaf, #1 call, #2 helper, #3 call, #4 main
    var ranges = [_]Range{
        .{ .low = 0x1000, .high = 0x1080, .call = false },
        .{ .low = 0x1080, .high = 0x1400, .call = true },
        .{ .low = 0x1400, .high = 0x1480, .call = false },
        .{ .low = 0x1480, .high = 0x1800, .call = true },
        .{ .low = 0x1800, .high = 0x1900, .call = false },
    };
    const whole = join(&levels, 48, 2, &ranges, true);
    try std.testing.expect(whole.reason == null and whole.without_level == null and whole.calls == 2);
    try std.testing.expectEqual(@as(?usize, 1), whole.frames[0]);
    try std.testing.expectEqual(@as(?usize, 3), whole.frames[1]);
    // An innermost call frame that has not linked its level yet is allowed.
    const entering = join(levels[1..], 48, 1, &ranges, true);
    try std.testing.expect(entering.reason == null);
    try std.testing.expectEqual(@as(?usize, 1), entering.without_level);
    try std.testing.expectEqual(@as(?usize, 3), entering.frames[0]);
    // An outer call frame without a level is not.
    const missing = join(levels[0..1], 48, 1, &ranges, true);
    try std.testing.expectEqualStrings("GDScriptNativeFrameCountMismatch", missing.reason.?);
    // More levels than were decoded, native stack cut: no count claim.
    try std.testing.expect(join(&levels, 48, 70, &ranges, false).reason == null);
    try std.testing.expectEqualStrings("GDScriptNativeFrameCountMismatch", join(&levels, 48, 70, &ranges, true).reason.?);
    // A level in a frame that is not GDScriptFunction::call.
    ranges[1].call = false;
    const wrong = join(&levels, 48, 2, &ranges, true);
    try std.testing.expectEqualStrings("GDScriptNativeJoinInconsistent", wrong.reason.?);
    try std.testing.expect(wrong.frames[0] == null and wrong.frames[1].? == 3);
    ranges[1].call = true;
    // A level that straddles the top of its frame, or lies in none.
    const straddle = [_]Level{.{ .address = 0x13e0, .function = 8, .instance = 0, .line_address = 0 }};
    try std.testing.expectEqualStrings("GDScriptNativeFrameNotFound", join(&straddle, 48, 1, &ranges, true).reason.?);
    try std.testing.expect(join(&straddle, 48, 1, &ranges, false).frames[0] == null);
    // Two levels claiming one frame.
    const twice = [_]Level{ levels[0], .{ .address = 0x1200, .function = 8, .instance = 0, .line_address = 0 } };
    try std.testing.expectEqualStrings("GDScriptNativeJoinInconsistent", join(&twice, 48, 2, &ranges, true).reason.?);
    try std.testing.expect(isCall("_ZN16GDScriptFunction4callEP16GDScriptInstancePPK7VariantiRN8Callable9CallErrorEPNS_9CallStateE") and isCall("_ZN16GDScriptFunction4callEP16GDScriptInstance.cold") and !isCall("_ZN16GDScriptInstance5callpE") and !isCall(null));
}
test "the language's own switches: not initialized, not tracking, not this layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake = Fake{ .base = heap, .bytes = try arena.allocator().alloc(u8, 0x4000) };
    @memset(fake.bytes, 0);
    var layout = test_layout;
    layout.singleton = heap + 0x100;
    var memory = fake.memory();
    // A null singleton: the engine has not created the language yet.
    try std.testing.expectError(error.GDScriptLanguageNotInitialized, language(&memory, &layout));
    const object = heap + 0x1000;
    fake.put(layout.singleton, object);
    fake.put32(object + 0x1b0, 1024);
    // track_call_stack == 0: a release template without the project setting.
    try std.testing.expectError(error.GDScriptCallStackNotTracked, language(&memory, &layout));
    fake.bytes[@intCast(object + 0x1b4 - heap)] = 1;
    const found = try language(&memory, &layout);
    try std.testing.expect(found.address == object and found.limit == 1024);
    // A bool that is neither 0 nor 1, or an impossible limit, is another layout.
    fake.bytes[@intCast(object + 0x1b4 - heap)] = 2;
    try std.testing.expectError(error.GDScriptLayoutMismatch, language(&memory, &layout));
    fake.bytes[@intCast(object + 0x1b4 - heap)] = 1;
    for ([_]u32{ 0, (1 << 24) + 1, std.math.maxInt(u32) }) |limit| {
        fake.put32(object + 0x1b0, limit);
        try std.testing.expectError(error.GDScriptLayoutMismatch, language(&memory, &layout));
    }
    fake.put(layout.singleton, object + 4);
    try std.testing.expectError(error.GDScriptLayoutMismatch, language(&memory, &layout));
    fake.put(layout.singleton, 0x900000);
    try std.testing.expectError(error.GDScriptLanguageUnreadable, language(&memory, &layout));
    layout.singleton = 0x900000;
    try std.testing.expectError(error.GDScriptLanguageUnreadable, language(&memory, &layout));
    try std.testing.expectEqual(error.GDScriptDwarfUnavailable, layoutError("DwarfTypesUnavailable"));
    try std.testing.expectEqual(error.GDScriptLayoutUnsupported, layoutError("DwarfFieldNotFound"));
    try std.testing.expectEqual(error.GDScriptLayoutUnsupported, layoutError("DwarfTypeAmbiguous"));
    try std.testing.expectEqual(error.GDScriptDwarfWorkLimit, layoutError("DwarfTypesWorkLimit"));
}
test "one stack never issues more reads than its bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fake = Fake{ .base = heap, .bytes = try arena.allocator().alloc(u8, 64) };
    @memset(fake.bytes, 0);
    var memory = fake.memory();
    var word: [8]u8 = undefined;
    for (0..max_reads) |_| try std.testing.expect(memory.read(heap, &word));
    try std.testing.expect(!memory.read(heap, &word) and memory.word(heap) == null);
    try std.testing.expectEqual(@as(usize, max_reads), memory.reads);
    // An address range that wraps is refused without asking the target.
    memory = fake.memory();
    try std.testing.expect(!memory.read(std.math.maxInt(u64) - 3, &word));
}
