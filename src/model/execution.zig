//! Inferior calls (`execute_call`): the first path that runs target code on
//! purpose. This file resolves the callee, reads its prototype, evaluates the
//! arguments with the read-only evaluator and classifies them for x86-64
//! SysV. The C runtime (xrt_infcall.h) owns the register/stack transaction,
//! the trap, the timeout and the byte-exact restore, locally or in the agent.
//!
//! Authority is checked by the caller (execute scope, controller lease) and
//! again here. Every attempt that reaches the target is journaled, and the
//! target generation advances after every call.
const std = @import("std");
const model = @import("session.zig");
const eval = @import("../debug/evaluate.zig");
const info = @import("../debug/info.zig");
const linux = @import("../target/linux.zig");
const rt = linux.runtime_c;

pub const default_timeout_ms: u64 = 5000;
pub const max_timeout_ms: u64 = rt.XRT_INFCALL_TIMEOUT_MAX_MS;
pub const max_arguments = 16;

pub const Request = struct {
    tid: i32,
    frame: usize = 0,
    callee: []const u8,
    arguments: []const []const u8 = &.{},
    /// Explicit C prototype, e.g. "int(const char *, ...)". Required for
    /// variadic callees and for callees without DWARF.
    prototype: ?[]const u8 = null,
    /// Explicit `this` expression for C++ member functions.
    this: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
};

const state = @import("execution_state.zig");
pub const Outcome = state.Outcome;
pub const Entry = state.Entry;
pub const Active = state.Active;
pub const State = state.State;
pub const journal_capacity = state.journal_capacity;
pub const Session = model.Session;
fn outcomeOf(code: u32) Outcome {
    return switch (code) {
        rt.XRT_INFCALL_RETURNED => .returned,
        rt.XRT_INFCALL_TIMEOUT => .timeout,
        rt.XRT_INFCALL_SIGNAL => .signal,
        rt.XRT_INFCALL_BREAKPOINT => .breakpoint,
        rt.XRT_INFCALL_EXCEPTION => .exception,
        rt.XRT_INFCALL_TRAP => .trap,
        rt.XRT_INFCALL_EVENT => .event,
        rt.XRT_INFCALL_EXITED => .exited,
        rt.XRT_INFCALL_STOP_UNCONFIRMED => .stop_unconfirmed,
        rt.XRT_INFCALL_RESTORE_FAILED => .restore_failed,
        rt.XRT_INFCALL_RESTORED => .restored,
        rt.XRT_INFCALL_ABANDONED => .abandoned,
        else => .refused,
    };
}
fn refusalName(code: u32) []const u8 {
    return switch (code) {
        rt.XRT_INFCALL_ACTIVE => "CallFrameActive",
        rt.XRT_INFCALL_STOP_STATE => "ExecutionStopStateUnsupported",
        rt.XRT_INFCALL_SHADOW_STACK => "ShadowStackUnsupported",
        rt.XRT_INFCALL_SCRATCH => "ScratchUnavailable",
        rt.XRT_INFCALL_TRAP_SITE => "ReturnTrapUnavailable",
        rt.XRT_INFCALL_REQUEST => "InvalidCallRequest",
        rt.XRT_INFCALL_XSTATE => "VectorStateUnavailable",
        rt.XRT_INFCALL_NOT_ACTIVE => "NoActiveCallFrame",
        else => "ExecutionRefused",
    };
}
fn mismatchName(code: u32) ?[]const u8 {
    return switch (code) {
        rt.XRT_INFCALL_MISMATCH_GPR => "general_registers",
        rt.XRT_INFCALL_MISMATCH_XSTATE => "vector_state",
        rt.XRT_INFCALL_MISMATCH_STACK => "borrowed_stack",
        rt.XRT_INFCALL_MISMATCH_WRITE => "write_back",
        else => null,
    };
}

pub const Argument = struct { expression: []const u8, type: []const u8, class: []const u8 };
pub const Field = struct { name: []const u8, value: model.ValueSummary };
pub const Result = struct {
    outcome: Outcome,
    tid: i32,
    /// The frame used to look up argument names; the call ran on the
    /// thread's current stack.
    lookup_frame: usize,
    reason: ?[]const u8 = null,
    callee: []const u8,
    callee_display: ?[]const u8 = null,
    address: u64,
    resolution: []const u8,
    dispatched_to: ?[]const u8 = null,
    prototype_source: []const u8,
    return_type: ?[]const u8,
    value: ?model.ValueSummary = null,
    /// One level of members for an aggregate result.
    fields: []const Field = &.{},
    raw: ?[]const u8 = null,
    arguments: []const Argument = &.{},
    call_frame_active: bool,
    restored: bool,
    verified: bool,
    mismatch: ?[]const u8 = null,
    stack_balanced: bool = true,
    signal: ?[]const u8 = null,
    signal_number: ?i32 = null,
    fault_address: ?u64 = null,
    stop_pc: ?u64 = null,
    blocked_syscall: ?u64 = null,
    ptrace_event: ?u32 = null,
    duration_ns: u64 = 0,
    trap_address: ?u64 = null,
    borrowed_stack: ?struct { low: u64, high: u64, bytes: u64 } = null,
    compared: ?struct { general_register_bytes: u64, vector_state_bytes: u64, stack_bytes: u64 } = null,
    generation_before: u64,
    generation: u64,
    journal_sequence: u64,
    effects: []const u8 = effects_note,
};
pub const effects_note = "target code ran on the selected thread with other threads stopped; saved registers, vector state and borrowed stack bytes are restored, but memory, files, locks and allocations the callee changed are not rolled back";

// ---------------------------------------------------------------- ABI

const Class = enum { none, integer, sse };
const Pass = union(enum) {
    /// Eightbyte classes for a value of at most 16 bytes passed in registers.
    registers: [2]Class,
    memory,
};
fn merge(a: Class, b: Class) Class {
    if (a == b or b == .none) return a;
    if (a == .none) return b;
    return .integer;
}
fn classifyInto(t: *const eval.Type, offset: u64, classes: *[2]Class, depth: usize) !void {
    if (depth > 16) return error.UnsupportedArgumentType;
    switch (t.kind) {
        .signed, .unsigned, .boolean, .pointer => {
            if (t.size == 0 or t.size > 8) return error.UnsupportedArgumentType;
            if (offset % t.size != 0) return error.UnalignedField;
            classes[@intCast(offset / 8)] = merge(classes[@intCast(offset / 8)], .integer);
        },
        .float => {
            if (t.size != 4 and t.size != 8) return error.LongDoubleUnsupported;
            if (offset % t.size != 0) return error.UnalignedField;
            classes[@intCast(offset / 8)] = merge(classes[@intCast(offset / 8)], .sse);
        },
        .structure => {
            if (t.fields.len == 0) return error.UnsupportedArgumentType;
            if (t.javascript_handle != 0 or t.ruby_value or t.elisp_object or t.go_kind != 0) return error.UnsupportedArgumentType;
            for (t.fields) |field| try classifyInto(field.type, offset + field.offset, classes, depth + 1);
        },
        .array => {
            const child = t.child orelse return error.UnsupportedArgumentType;
            if (t.count == 0 or t.count > 16 or child.size == 0) return error.UnsupportedArgumentType;
            for (0..@intCast(t.count)) |i| try classifyInto(child, offset + i * child.size, classes, depth + 1);
        },
        .unknown => return error.UnsupportedArgumentType,
    }
}
fn known(t: *const eval.Type, depth: usize) !void {
    if (depth > 16) return error.UnsupportedArgumentType;
    switch (t.kind) {
        .signed, .unsigned, .boolean, .pointer => if (t.size == 0 or t.size > 8) return error.UnsupportedArgumentType,
        .float => if (t.size != 4 and t.size != 8) return error.LongDoubleUnsupported,
        .structure => {
            if (t.fields.len == 0) return error.UnsupportedArgumentType;
            for (t.fields) |field| try known(field.type, depth + 1);
        },
        .array => try known(t.child orelse return error.UnsupportedArgumentType, depth + 1),
        .unknown => return error.UnsupportedArgumentType,
    }
}
/// SysV x86-64 classification (psABI 3.2.3) for the types this milestone
/// supports. Long double, __int128, vectors, bit-fields and unknown layouts
/// are refused rather than approximated.
fn classify(t: *const eval.Type) !Pass {
    switch (t.kind) {
        .signed, .unsigned, .boolean, .pointer => {
            if (t.size == 0 or t.size > 8) return error.UnsupportedArgumentType;
            return .{ .registers = .{ .integer, .none } };
        },
        .float => {
            if (t.size != 4 and t.size != 8) return error.LongDoubleUnsupported;
            return .{ .registers = .{ .sse, .none } };
        },
        .structure, .array => {
            if (t.size == 0) return error.UnsupportedArgumentType;
            var classes: [2]Class = .{ .none, .none };
            if (t.size > 16) {
                // Larger aggregates go in memory, but unknown members are
                // still refused rather than copied as opaque bytes.
                try known(t, 0);
                return .memory;
            }
            classifyInto(t, 0, &classes, 0) catch |err| {
                if (err == error.UnalignedField) return .memory;
                return err;
            };
            if (t.size <= 8) classes[1] = .none;
            return .{ .registers = classes };
        },
        .unknown => return error.UnsupportedArgumentType,
    }
}
fn eightbytes(t: *const eval.Type) usize {
    return @intCast((t.size + 7) / 8);
}

// ---------------------------------------------------------------- prototypes

/// A parameter or return type from DWARF or from an explicit prototype.
const Prototype = struct {
    source: []const u8,
    name: []const u8,
    return_type: ?*const eval.Type,
    parameters: []const *const eval.Type,
    variadic: bool,
    member: bool = false,
    virtual: bool = false,
    vtable_index: ?u64 = null,
    class: ?*const eval.Type = null,
};
const named_types = [_]struct { name: []const u8, kind: eval.Kind, size: u64 }{
    .{ .name = "_Bool", .kind = .boolean, .size = 1 },          .{ .name = "bool", .kind = .boolean, .size = 1 },
    .{ .name = "char", .kind = .signed, .size = 1 },            .{ .name = "signed char", .kind = .signed, .size = 1 },
    .{ .name = "unsigned char", .kind = .unsigned, .size = 1 }, .{ .name = "short", .kind = .signed, .size = 2 },
    .{ .name = "short int", .kind = .signed, .size = 2 },       .{ .name = "unsigned short", .kind = .unsigned, .size = 2 },
    .{ .name = "int", .kind = .signed, .size = 4 },             .{ .name = "signed", .kind = .signed, .size = 4 },
    .{ .name = "signed int", .kind = .signed, .size = 4 },      .{ .name = "unsigned", .kind = .unsigned, .size = 4 },
    .{ .name = "unsigned int", .kind = .unsigned, .size = 4 },  .{ .name = "long", .kind = .signed, .size = 8 },
    .{ .name = "long int", .kind = .signed, .size = 8 },        .{ .name = "unsigned long", .kind = .unsigned, .size = 8 },
    .{ .name = "long long", .kind = .signed, .size = 8 },       .{ .name = "unsigned long long", .kind = .unsigned, .size = 8 },
    .{ .name = "size_t", .kind = .unsigned, .size = 8 },        .{ .name = "ssize_t", .kind = .signed, .size = 8 },
    .{ .name = "ptrdiff_t", .kind = .signed, .size = 8 },       .{ .name = "intptr_t", .kind = .signed, .size = 8 },
    .{ .name = "uintptr_t", .kind = .unsigned, .size = 8 },     .{ .name = "int8_t", .kind = .signed, .size = 1 },
    .{ .name = "uint8_t", .kind = .unsigned, .size = 1 },       .{ .name = "int16_t", .kind = .signed, .size = 2 },
    .{ .name = "uint16_t", .kind = .unsigned, .size = 2 },      .{ .name = "int32_t", .kind = .signed, .size = 4 },
    .{ .name = "uint32_t", .kind = .unsigned, .size = 4 },      .{ .name = "int64_t", .kind = .signed, .size = 8 },
    .{ .name = "uint64_t", .kind = .unsigned, .size = 8 },      .{ .name = "float", .kind = .float, .size = 4 },
    .{ .name = "double", .kind = .float, .size = 8 },
};
var void_type = eval.Type{ .name = "void", .kind = .unknown, .size = 0 };
/// Scalar and pointer C types only; aggregates need DWARF.
fn parseType(a: std.mem.Allocator, text: []const u8) !?*const eval.Type {
    var rest = std.mem.trim(u8, text, " \t");
    var stars: usize = 0;
    while (rest.len > 0 and rest[rest.len - 1] == '*') {
        stars += 1;
        rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 1], " \t");
        if (std.mem.endsWith(u8, rest, " const")) rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 6], " \t");
    }
    // Drop qualifiers and collapse whitespace.
    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    while (it.next()) |word| {
        if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "volatile") or std.mem.eql(u8, word, "restrict")) continue;
        if (std.mem.eql(u8, word, "struct") or std.mem.eql(u8, word, "union") or std.mem.eql(u8, word, "class") or std.mem.eql(u8, word, "enum")) {
            if (stars == 0) return error.PrototypeTypeUnsupported;
        }
        if (n == words.len) return error.InvalidPrototype;
        words[n] = word;
        n += 1;
    }
    if (n == 0) return error.InvalidPrototype;
    const base_name = try std.mem.join(a, " ", words[0..n]);
    var base: *const eval.Type = &void_type;
    var is_void = std.mem.eql(u8, base_name, "void");
    if (!is_void) {
        const row = for (named_types) |row| {
            if (std.mem.eql(u8, row.name, base_name)) break row;
        } else null;
        const t = try a.create(eval.Type);
        if (row) |known_row| {
            t.* = .{ .name = known_row.name, .kind = known_row.kind, .size = known_row.size };
        } else {
            // An opaque pointee: only a pointer to it can be passed.
            if (stars == 0) return error.PrototypeTypeUnsupported;
            t.* = .{ .name = base_name, .kind = .unknown, .size = 0 };
        }
        base = t;
    }
    if (is_void and stars == 0) return null;
    var current = base;
    for (0..stars) |_| {
        const p = try a.create(eval.Type);
        p.* = .{ .name = try std.fmt.allocPrint(a, "{s} *", .{current.name}), .kind = .pointer, .size = 8, .child = current };
        current = p;
        is_void = false;
    }
    return current;
}
fn parsePrototype(a: std.mem.Allocator, text: []const u8) !Prototype {
    if (text.len == 0 or text.len > 1024) return error.InvalidPrototype;
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return error.InvalidPrototype;
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.InvalidPrototype;
    if (close < open or std.mem.trim(u8, text[close + 1 ..], " \t").len != 0) return error.InvalidPrototype;
    const return_type = try parseType(a, text[0..open]);
    var parameters: std.ArrayList(*const eval.Type) = .empty;
    var variadic = false;
    const inside = std.mem.trim(u8, text[open + 1 .. close], " \t");
    if (inside.len != 0 and !std.mem.eql(u8, inside, "void")) {
        var parts = std.mem.splitScalar(u8, inside, ',');
        while (parts.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (variadic) return error.InvalidPrototype;
            if (std.mem.eql(u8, p, "...")) {
                variadic = true;
                continue;
            }
            const t = try parseType(a, p) orelse return error.InvalidPrototype;
            try parameters.append(a, t);
            if (parameters.items.len > max_arguments) return error.TooManyArguments;
        }
    }
    return .{ .source = "explicit", .name = "", .return_type = return_type, .parameters = try parameters.toOwnedSlice(a), .variadic = variadic };
}

// ---------------------------------------------------------------- callee

const Callee = struct { address: u64, name: []const u8, resolution: []const u8 };

/// Already-resolved runtime evidence for an imported function: the GOT slot
/// the dynamic linker filled for a JUMP_SLOT or GLOB_DAT relocation. This
/// is how PLT stubs and GNU IFUNCs are followed without calling a resolver.
/// A slot that still points into its own image (a lazy, unbound PLT stub)
/// is not evidence.
fn resolvedImport(session: *Session, name: []const u8) ?u64 {
    for (session.modules.loaded.items) |module| {
        if (module.kernel or module.explicit_gdb) continue;
        const dynsym = (module.image.symbols(.dynsym) catch continue) orelse continue;
        for ([_][]const u8{ ".rela.plt", ".rela.dyn" }) |section_name| {
            const section = module.image.sectionByName(section_name) orelse continue;
            const bytes = module.image.sectionData(section) catch continue;
            var at: usize = 0;
            while (at + 24 <= bytes.len and at < 24 * 65536) : (at += 24) {
                const offset = std.mem.readInt(u64, bytes[at..][0..8], .little);
                const r_info = std.mem.readInt(u64, bytes[at + 8 ..][0..8], .little);
                const kind: u32 = @truncate(r_info);
                if (kind != 7 and kind != 6) continue; // R_X86_64_JUMP_SLOT, R_X86_64_GLOB_DAT
                const symbol = dynsym.get(@intCast(r_info >> 32)) catch continue;
                if (!std.mem.eql(u8, symbol.name, name)) continue;
                const slot = module.runtimeAddress(offset) catch continue;
                var word: [8]u8 = undefined;
                if ((session.target.readMemory(slot, &word) catch 0) != 8) continue;
                const value = std.mem.readInt(u64, &word, .little);
                if (value >= module.start and value < module.end) continue;
                for (session.modules.regions.items) |r| if (value >= r.start and value < r.end) {
                    if (r.permissions[2] == 'x') return value;
                    break;
                };
            }
        }
    }
    return null;
}
fn normalized(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| if (ch != ' ' and ch != '\t') try out.append(a, ch);
    var result = out.items;
    if (std.mem.endsWith(u8, result, "const")) result = result[0 .. result.len - 5];
    return result;
}
/// The qualified name part of a demangled signature: no return type (a
/// template function's demangling starts with one) and no parameters.
fn qualifiedName(display: []const u8) []const u8 {
    var depth: usize = 0;
    var end = display.len;
    var start: usize = 0;
    for (display, 0..) |ch, i| switch (ch) {
        '<' => depth += 1,
        '>' => depth -|= 1,
        '(' => if (depth == 0) {
            end = i;
            break;
        },
        ' ' => if (depth == 0) {
            start = i + 1;
        },
        else => {},
    };
    return display[start..end];
}
const Candidate = struct { address: u64, display: []const u8 };
/// The part of a name before template arguments or parameters.
fn baseName(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "<(") orelse text.len;
    return std.mem.trim(u8, text[0..end], " \t");
}
/// One parameter type spelled canonically: words sorted, a redundant "int"
/// dropped ("long unsigned int" and "unsigned long" agree), no spaces
/// around '*' or '&'.
fn canonicalType(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var spaced: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch == '*' or ch == '&') {
            try spaced.appendSlice(a, " ");
            try spaced.append(a, ch);
            try spaced.appendSlice(a, " ");
        } else try spaced.append(a, ch);
    }
    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, spaced.items, " \t");
    var modifier = false;
    while (it.next()) |word| {
        // DWARF type names drop qualifiers; overloads on const alone are not told apart.
        if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "volatile")) continue;
        if (std.mem.eql(u8, word, "long") or std.mem.eql(u8, word, "short") or std.mem.eql(u8, word, "unsigned") or std.mem.eql(u8, word, "signed")) modifier = true;
        try words.append(a, word);
    }
    // Sort only the words before the first declarator.
    var head: usize = 0;
    while (head < words.items.len and !std.mem.eql(u8, words.items[head], "*") and !std.mem.eql(u8, words.items[head], "&")) head += 1;
    std.mem.sort([]const u8, words.items[0..head], {}, struct {
        fn less(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.order(u8, l, r) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (words.items, 0..) |word, i| {
        if (modifier and i < head and std.mem.eql(u8, word, "int")) continue;
        if (out.items.len > 0) try out.append(a, ' ');
        try out.appendSlice(a, word);
    }
    return out.items;
}
fn canonicalParameters(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '(');
    for (list, 0..) |item, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, try canonicalType(a, item));
    }
    try out.append(a, ')');
    return out.items;
}
/// The DWARF spelling of a candidate: its qualified name with template
/// arguments (DW_AT_name carries them) and its explicit parameter types.
/// The compact demangler omits both, so overloads and instantiations are
/// told apart only with debug info.
fn describe(session: *Session, a: std.mem.Allocator, address: u64, compact: []const u8) !struct { name: []const u8, parameters: []const u8 } {
    const module = try session.modules.at(address);
    const found = try (try module.debugInfo()).prototypeAt(a, try module.linkAddress(address));
    const base = baseName(compact);
    const qualifier = if (std.mem.lastIndexOf(u8, base, "::")) |sep| base[0 .. sep + 2] else "";
    var types: std.ArrayList([]const u8) = .empty;
    for (found.parameters) |parameter| if (!parameter.artificial) try types.append(a, parameter.type.name);
    return .{ .name = try std.fmt.allocPrint(a, "{s}{s}", .{ qualifier, found.name }), .parameters = try canonicalParameters(a, types.items) };
}
fn cxxCandidates(session: *Session, a: std.mem.Allocator, callee: []const u8, templates: *usize) ![]Candidate {
    const paren = std.mem.indexOfScalar(u8, callee, '(');
    const head = std.mem.trim(u8, callee[0 .. paren orelse callee.len], " \t");
    const want_base = baseName(callee);
    const want_template = std.mem.indexOfScalar(u8, head, '<') != null;
    const want_name = try normalized(a, head);
    const want_parameters: ?[]const u8 = if (paren) |at| blk: {
        const close = std.mem.lastIndexOfScalar(u8, callee, ')') orelse return error.InvalidArguments;
        if (close < at) return error.InvalidArguments;
        const inside = std.mem.trim(u8, callee[at + 1 .. close], " \t");
        var list: std.ArrayList([]const u8) = .empty;
        if (inside.len > 0 and !std.mem.eql(u8, inside, "void")) {
            var parts = std.mem.splitScalar(u8, inside, ',');
            while (parts.next()) |part| try list.append(a, part);
        }
        break :blk try canonicalParameters(a, list.items);
    } else null;
    var found: std.ArrayList(Candidate) = .empty;
    var scanned: usize = 0;
    for (session.modules.loaded.items) |module| {
        if (module.kernel or module.explicit_gdb) continue;
        const image = module.symbols();
        for ([_]@import("../binary/elf.zig").SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
            const table = (image.symbols(kind) catch continue) orelse continue;
            var i: u32 = 1;
            while (i < table.count()) : (i += 1) {
                scanned += 1;
                if (scanned > 400_000) return error.SymbolScanLimit;
                const symbol = table.get(i) catch continue;
                if (symbol.type != .func or !symbol.hasAddress() or !std.mem.startsWith(u8, symbol.name, "_Z")) continue;
                const shown = @import("../debug/demangle.zig").display(a, symbol.name) catch continue;
                if (std.mem.startsWith(u8, shown, "_Z")) continue;
                const qualified = qualifiedName(shown);
                if (!std.mem.eql(u8, baseName(qualified), want_base)) continue;
                const address = module.runtimeAddress(symbol.value) catch continue;
                const template = std.mem.indexOfScalar(u8, qualified, '<') != null;
                if (template and !want_template) {
                    templates.* += 1;
                    continue;
                }
                var display = shown;
                if (want_template or want_parameters != null) {
                    const full = describe(session, a, address, qualified) catch |err| switch (err) {
                        error.DebugMetadataPending, error.DebugMetadataCancelled, error.SymbolDiscoveryPending => return err,
                        else => continue,
                    };
                    if (want_template and !std.mem.eql(u8, try normalized(a, full.name), want_name)) continue;
                    if (want_parameters) |wanted| if (!std.mem.eql(u8, full.parameters, wanted)) continue;
                    display = try std.fmt.allocPrint(a, "{s}{s}", .{ full.name, full.parameters });
                } else if (describe(session, a, address, qualified)) |full| {
                    display = try std.fmt.allocPrint(a, "{s}{s}", .{ full.name, full.parameters });
                } else |_| {}
                for (found.items) |item| {
                    if (item.address == address) break;
                } else try found.append(a, .{ .address = address, .display = display });
            }
        }
    }
    return found.toOwnedSlice(a);
}
fn plainIdentifier(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}
fn ensureMainLoaded(session: *Session) void {
    for (session.modules.regions.items) |r| {
        if (r.permissions[2] != 'x' or r.path.len == 0 or r.path[0] != '/') continue;
        _ = session.modules.at(r.start) catch {};
        return;
    }
}
fn resolveCallee(session: *Session, a: std.mem.Allocator, request: Request, detail: *?[]const u8) !Callee {
    const text = std.mem.trim(u8, request.callee, " \t");
    if (text.len == 0 or text.len > 1024) return error.InvalidArguments;
    // A local function-pointer variable or an address expression.
    const expression = !plainIdentifier(text) and (!(std.ascii.isAlphabetic(text[0]) or text[0] == '_') or std.mem.indexOf(u8, text, "->") != null or std.mem.indexOfAny(u8, text, ".[") != null);
    if (plainIdentifier(text) or expression) {
        if (session.evaluateAtDepth(a, request.tid, request.frame, 0, text)) |value| {
            if (value.type.kind == .pointer or value.type.kind == .unsigned or value.type.kind == .signed) {
                if (value.bits == 0) return error.NullFunctionPointer;
                return .{ .address = value.bits, .name = text, .resolution = "function_pointer" };
            }
            return error.CalleeNotFunction;
        } else |err| switch (err) {
            error.UnknownVariable, error.ExpectedIdentifier, error.InvalidExpression => {},
            error.ExecutionRequired => return error.NestedCallUnsupported,
            else => if (!plainIdentifier(text)) return err,
        }
    }
    ensureMainLoaded(session);
    if (plainIdentifier(text)) {
        if (resolvedImport(session, text)) |address| return .{ .address = address, .name = text, .resolution = "got" };
        if (session.modules.findSymbol(text)) |symbol| {
            if (symbol.ifunc) {
                detail.* = "the symbol is a GNU IFUNC resolver and no image has a bound GOT slot for it; calling the resolver is not attempted";
                return error.UnresolvedIfunc;
            }
            return .{ .address = symbol.address, .name = symbol.name, .resolution = "symbol" };
        } else |err| switch (err) {
            error.SymbolNotFound, error.UnknownSymbol => {},
            else => return err,
        }
    } else if (std.mem.startsWith(u8, text, "_Z")) {
        const symbol = try session.modules.findSymbol(text);
        return .{ .address = symbol.address, .name = symbol.name, .resolution = "symbol" };
    }
    var templates: usize = 0;
    const candidates = try cxxCandidates(session, a, text, &templates);
    if (candidates.len == 1) return .{ .address = candidates[0].address, .name = candidates[0].display, .resolution = "demangled" };
    if (candidates.len > 1) {
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(a, "candidates: ");
        for (candidates[0..@min(candidates.len, 8)], 0..) |item, i| {
            if (i > 0) try list.appendSlice(a, "; ");
            try list.appendSlice(a, item.display);
        }
        detail.* = list.items;
        return error.OverloadAmbiguous;
    }
    if (templates > 0) {
        detail.* = try std.fmt.allocPrint(a, "{d} instantiations exist; name one, e.g. {s}<int>", .{ templates, text });
        return error.TemplateInstantiationRequired;
    }
    return error.UnknownFunction;
}

fn dwarfPrototype(session: *Session, a: std.mem.Allocator, address: u64) !Prototype {
    const module = try session.modules.at(address);
    const debug = try module.debugInfo();
    const found = try debug.prototypeAt(a, try module.linkAddress(address));
    for (found.parameters) |p| if (p.nontrivial_class) return error.NonTrivialCopyArgument;
    if (found.return_nontrivial_class) return error.NonTrivialCopyReturn;
    var parameters = try a.alloc(*const eval.Type, found.parameters.len);
    for (found.parameters, 0..) |p, i| parameters[i] = p.type;
    return .{ .source = "dwarf", .name = found.name, .return_type = found.return_type, .parameters = parameters, .variadic = found.variadic, .member = found.member, .virtual = found.virtual, .vtable_index = found.vtable_index, .class = if (found.member) found.parameters[0].type.child else null };
}

// ---------------------------------------------------------------- arguments

const Words = struct {
    request: rt.struct_xrt_infcall_request = std.mem.zeroes(rt.struct_xrt_infcall_request),
    int_limit: u32 = 6,
    fn stack(self: *Words, bytes: []const u8) !void {
        const size: u32 = @intCast((bytes.len + 7) / 8 * 8);
        if (self.request.stack_size + size > rt.XRT_INFCALL_STACK_MAX) return error.TooManyArgumentBytes;
        @memcpy(self.request.stack[self.request.stack_size..][0..bytes.len], bytes);
        self.request.stack_size += size;
    }
    fn place(self: *Words, t: *const eval.Type, bytes: []const u8) ![]const u8 {
        const pass = try classify(t);
        switch (pass) {
            .memory => {
                try self.stack(bytes);
                return "memory";
            },
            .registers => |classes| {
                const n = eightbytes(t);
                var ints: u32 = 0;
                var sses: u32 = 0;
                for (classes[0..n]) |cls| switch (cls) {
                    .integer => ints += 1,
                    .sse => sses += 1,
                    .none => {},
                };
                if (self.request.int_count + ints > self.int_limit or self.request.sse_count + sses > rt.XRT_INFCALL_SSE_REGS) {
                    try self.stack(bytes);
                    return "stack";
                }
                for (classes[0..n], 0..) |cls, k| {
                    var word: [8]u8 = @splat(0);
                    const from = k * 8;
                    const len = @min(8, bytes.len - from);
                    @memcpy(word[0..len], bytes[from..][0..len]);
                    switch (cls) {
                        .integer => {
                            self.request.int_args[self.request.int_count] = std.mem.readInt(u64, &word, .little);
                            self.request.int_count += 1;
                        },
                        .sse => {
                            self.request.sse_args[self.request.sse_count] = @splat(0);
                            @memcpy(self.request.sse_args[self.request.sse_count][0..8], &word);
                            self.request.sse_count += 1;
                        },
                        .none => {},
                    }
                }
                return if (ints > 0 and sses > 0) "integer+sse" else if (sses > 0) "sse" else "integer";
            },
        }
    }
};
fn floatOf(v: eval.Value) !f64 {
    return switch (v.type.kind) {
        .float => if (v.type.size == 4) @floatCast(@as(f32, @bitCast(@as(u32, @truncate(v.bits))))) else @bitCast(v.bits),
        .signed => @floatFromInt(@as(i64, @bitCast(v.bits))),
        .unsigned, .boolean => @floatFromInt(v.bits),
        else => error.ArgumentTypeMismatch,
    };
}
fn scalarBits(v: eval.Value, target: *const eval.Type) !u64 {
    switch (v.type.kind) {
        .signed, .unsigned, .boolean, .pointer => {},
        .float => {
            if (target.kind == .pointer) return error.ArgumentTypeMismatch;
            const f = try floatOf(v);
            if (std.math.isNan(f) or f > 1.8e19 or f < -9.3e18) return error.ArgumentTypeMismatch;
            return if (f < 0) @bitCast(@as(i64, @intFromFloat(f))) else @intFromFloat(f);
        },
        // C array-to-pointer decay; only for memory-resident arrays.
        .array => if (target.kind == .pointer) return v.address orelse error.NotAddressable else return error.ArgumentTypeMismatch,
        else => return error.ArgumentTypeMismatch,
    }
    var bits = v.bits;
    if (target.size < 8) {
        const shift: u6 = @intCast(64 - target.size * 8);
        bits = if (target.kind == .signed) @bitCast(@as(i64, @bitCast(bits << shift)) >> shift) else (bits << shift) >> shift;
    }
    if (target.kind == .boolean) bits = @intFromBool(bits != 0);
    return bits;
}
/// The argument value converted to the parameter type, as the bytes the
/// callee expects. Integer conversions follow C; aggregates must match.
fn encode(session: *Session, a: std.mem.Allocator, v: eval.Value, target: *const eval.Type) ![]const u8 {
    switch (target.kind) {
        .signed, .unsigned, .boolean, .pointer => {
            const bits = try scalarBits(v, target);
            const out = try a.alloc(u8, 8);
            std.mem.writeInt(u64, out[0..8], bits, .little);
            return out;
        },
        .float => {
            const f = try floatOf(v);
            const out = try a.alloc(u8, 8);
            @memset(out, 0);
            if (target.size == 4) std.mem.writeInt(u32, out[0..4], @bitCast(@as(f32, @floatCast(f))), .little) else std.mem.writeInt(u64, out[0..8], @bitCast(f), .little);
            return out;
        },
        .structure, .array => {
            if (v.type.kind != target.kind or v.type.size != target.size or (v.type.name.len > 0 and target.name.len > 0 and !std.mem.eql(u8, v.type.name, target.name))) return error.ArgumentTypeMismatch;
            if (target.size > rt.XRT_INFCALL_STACK_MAX) return error.TooManyArgumentBytes;
            const out = try a.alloc(u8, @intCast(target.size));
            if (v.data) |data| {
                if (eval.hasMissingBits(v) or data.len < out.len) return error.PartialValue;
                @memcpy(out, data[0..out.len]);
            } else if (v.address) |address| {
                if (try session.target.readMemory(address, out) != out.len) return error.MemoryUnreadable;
            } else return error.PartialValue;
            return out;
        },
        .unknown => return error.UnsupportedArgumentType,
    }
}
var promoted_int = eval.Type{ .name = "int", .kind = .signed, .size = 8 };
var promoted_uint = eval.Type{ .name = "unsigned long", .kind = .unsigned, .size = 8 };
var promoted_double = eval.Type{ .name = "double", .kind = .float, .size = 8 };
var promoted_pointer = eval.Type{ .name = "void *", .kind = .pointer, .size = 8 };
/// Default argument promotions for the variadic part.
fn promoted(v: eval.Value) !*const eval.Type {
    return switch (v.type.kind) {
        .signed, .boolean => &promoted_int,
        .unsigned => &promoted_uint,
        .float => &promoted_double,
        .pointer, .array => &promoted_pointer,
        else => error.UnsupportedVariadicArgument,
    };
}

// ---------------------------------------------------------------- results

fn decodeReturn(a: std.mem.Allocator, t: *const eval.Type, out: *const rt.struct_xrt_infcall_result) !eval.Value {
    const pass = try classify(t);
    switch (pass) {
        .memory => {
            if (out.sret_size != t.size) return error.ReturnValueUnavailable;
            return .{ .type = t, .data = try a.dupe(u8, out.sret[0..out.sret_size]) };
        },
        .registers => |classes| {
            var bytes: [16]u8 = @splat(0);
            const ints = [_]u64{ out.rax, out.rdx };
            const xmm = [_][16]u8{ out.xmm0, out.xmm1 };
            var next_int: usize = 0;
            var next_sse: usize = 0;
            for (classes[0..eightbytes(t)], 0..) |cls, k| switch (cls) {
                .integer => {
                    std.mem.writeInt(u64, bytes[k * 8 ..][0..8], ints[next_int], .little);
                    next_int += 1;
                },
                .sse => {
                    @memcpy(bytes[k * 8 ..][0..8], xmm[next_sse][0..8]);
                    next_sse += 1;
                },
                .none => {},
            };
            const size: usize = @intCast(t.size);
            if (t.kind == .structure or t.kind == .array) return .{ .type = t, .data = try a.dupe(u8, bytes[0..size]) };
            var bits = std.mem.readInt(u64, bytes[0..8], .little);
            if (size < 8) {
                const shift: u6 = @intCast(64 - size * 8);
                bits = if (t.kind == .signed) @bitCast(@as(i64, @bitCast(bits << shift)) >> shift) else (bits << shift) >> shift;
            }
            return .{ .type = t, .bits = bits };
        },
    }
}
fn hex(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    return out;
}

// ---------------------------------------------------------------- entry points

fn authority(session: *Session, actor: model.Actor, generation: ?u64) !void {
    if (session.offline) return error.OfflineSession;
    try session.authorize(actor, .inferior_call, generation);
    if (actor == .agent and session.agent_client_id != null) {
        const lease = session.agent_lease orelse return error.ControlLeaseRequired;
        if (!session.agent_controller or !lease.valid(linux.now(), @intFromEnum(session.agent_scope))) return error.ControlLeaseRequired;
    }
}
fn backend(session: *Session) !void {
    if (session.target.core != null) return error.ReadOnlyCore;
    if (session.target.gdbRemoteInfo() != null) return error.ExecutionBackendUnavailable;
    if (session.target.arch() != .x86_64) return error.ExecutionArchitectureUnsupported;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
}
fn scopeName(session: *const Session, actor: model.Actor) []const u8 {
    return if (actor == .human) "human" else @tagName(session.agent_scope);
}

/// Validates, classifies and runs one call. Refusals before the target is
/// touched are errors (with `detail`); every attempt that reached the
/// target returns a Result and is journaled.
pub fn call(session: *Session, a: std.mem.Allocator, actor: model.Actor, generation: ?u64, request: Request, detail: *?[]const u8) !Result {
    try authority(session, actor, generation);
    try backend(session);
    if (session.execution.active) |active| {
        detail.* = try std.fmt.allocPrint(a, "thread {d} is inside a call to {s}; restore or abandon it with resolve_execution", .{ active.tid, active.callee });
        return error.CallFrameActive;
    }
    if (request.timeout_ms == 0 or request.timeout_ms > max_timeout_ms) return error.InvalidTimeout;
    if (request.arguments.len > max_arguments) return error.TooManyArguments;
    if (request.frame >= 64) return error.InvalidFrame;
    for (session.target.threadSlice()) |thread| {
        if (thread.tid == request.tid) break;
    } else return error.UnknownThread;

    const callee = try resolveCallee(session, a, request, detail);
    var prototype: Prototype = undefined;
    if (request.prototype) |text| {
        prototype = try parsePrototype(a, text);
        // DWARF still says whether this is a C++ member.
        if (dwarfPrototype(session, a, callee.address)) |declared| {
            if (declared.member) return error.ExplicitPrototypeForMember;
            // A variadic callee reads %al and va_arg; a fixed prototype for it
            // would leave both wrong.
            if (declared.variadic != prototype.variadic) {
                detail.* = if (declared.variadic) "DWARF declares the callee variadic; end the prototype with \", ...\"" else "DWARF declares a fixed parameter list; drop the \"...\"";
                return error.PrototypeMismatch;
            }
        } else |err| switch (err) {
            error.DebugMetadataPending, error.DebugMetadataCancelled, error.SymbolDiscoveryPending => return err,
            else => {},
        }
    } else {
        prototype = dwarfPrototype(session, a, callee.address) catch |err| switch (err) {
            // Image preparation is retried by the caller; nothing was written.
            error.NonTrivialCopyArgument, error.NonTrivialCopyReturn, error.VtableLayoutUnsupported, error.DebugMetadataPending, error.DebugMetadataCancelled, error.SymbolDiscoveryPending => return err,
            else => {
                detail.* = try std.fmt.allocPrint(a, "no DWARF prototype at the callee ({s}); pass an explicit prototype such as \"size_t(const char *)\"", .{@errorName(err)});
                return error.PrototypeUnavailable;
            },
        };
        if (prototype.variadic) {
            detail.* = "the callee is variadic; pass an explicit prototype ending in \", ...\" so %al and promotions are explicit";
            return error.VariadicPrototypeRequired;
        }
    }
    if (prototype.member and request.this == null) return error.ThisRequired;
    if (!prototype.member and request.this != null) return error.ThisUnexpected;
    const declared = if (prototype.member) prototype.parameters[1..] else prototype.parameters;
    if (request.arguments.len < declared.len or (request.arguments.len > declared.len and !prototype.variadic)) {
        detail.* = try std.fmt.allocPrint(a, "the prototype takes {d} argument(s){s}; {d} given", .{ declared.len, if (prototype.variadic) " and more" else "", request.arguments.len });
        return error.ArgumentCountMismatch;
    }

    var words = Words{};
    var sret_size: u32 = 0;
    if (prototype.return_type) |ret| {
        const pass = classify(ret) catch |err| {
            detail.* = try std.fmt.allocPrint(a, "return type {s}", .{ret.name});
            return err;
        };
        if (pass == .memory) {
            if (ret.size > rt.XRT_INFCALL_SRET_MAX) return error.ReturnValueTooLarge;
            sret_size = @intCast(ret.size);
            words.int_limit = 5;
        }
    }
    var arguments: std.ArrayList(Argument) = .empty;
    var address = callee.address;
    var dispatched: ?[]const u8 = null;
    if (prototype.member) {
        const text = request.this.?;
        if (std.mem.indexOfScalar(u8, text, '"') != null) return error.ScratchUnavailable;
        const this_value = session.evaluateAtDepth(a, request.tid, request.frame, 0, text) catch |err| return if (err == error.ExecutionRequired) error.NestedCallUnsupported else err;
        if (this_value.type.kind != .pointer and this_value.type.kind != .unsigned) return error.ThisNotPointer;
        const object = this_value.bits;
        const class = prototype.class orelse return error.UnsupportedClass;
        if (class.kind != .structure and class.kind != .unknown) return error.UnsupportedClass;
        if (object == 0 or object % 8 != 0 and prototype.virtual) return error.InvalidThis;
        // The object must be readable for its declared size.
        var probe: [8]u8 = undefined;
        if (class.size > 0) {
            const last = std.math.add(u64, object, class.size - 1) catch return error.InvalidThis;
            if ((session.target.readMemory(object, probe[0..1]) catch 0) != 1 or (session.target.readMemory(last, probe[0..1]) catch 0) != 1) return error.InvalidThis;
        }
        if (this_value.type.kind == .pointer) if (this_value.type.child) |pointee| {
            if (!prototype.virtual and pointee.name.len > 0 and class.name.len > 0 and !std.mem.eql(u8, pointee.name, class.name)) {
                detail.* = try std.fmt.allocPrint(a, "this is {s} *, the method belongs to {s}", .{ pointee.name, class.name });
                return error.ThisTypeMismatch;
            }
        };
        if (prototype.virtual) {
            // Itanium ABI: the vptr is at offset 0 of a polymorphic class
            // without virtual bases; slot N is 8*N bytes past it.
            if ((session.target.readMemory(object, &probe) catch 0) != 8) return error.InvalidThis;
            const vptr = std.mem.readInt(u64, &probe, .little);
            const vtable = session.modules.symbolAt(vptr) catch |err| {
                detail.* = try std.fmt.allocPrint(a, "the object's first word 0x{x} names no symbol ({s})", .{ vptr, @errorName(err) });
                return error.InvalidThis;
            };
            // Itanium vtable symbols are _ZTV<class>.
            const vtable_name = @import("../debug/demangle.zig").display(a, vtable.name) catch vtable.name;
            if (!std.mem.startsWith(u8, vtable.name, "_ZTV")) {
                detail.* = try std.fmt.allocPrint(a, "the object's first word 0x{x} is in {s}, not a vtable", .{ vptr, vtable_name });
                return error.InvalidThis;
            }
            const slot = std.math.add(u64, vptr, 8 * (prototype.vtable_index orelse return error.VtableLayoutUnsupported)) catch return error.InvalidThis;
            if ((session.target.readMemory(slot, &probe) catch 0) != 8) return error.InvalidThis;
            address = std.mem.readInt(u64, &probe, .little);
            const target_symbol = session.modules.symbolAt(address) catch return error.InvalidThis;
            const shown = @import("../debug/demangle.zig").display(a, target_symbol.name) catch target_symbol.name;
            if (std.mem.startsWith(u8, shown, "virtual thunk") or std.mem.startsWith(u8, shown, "non-virtual thunk")) return error.VirtualThunkUnsupported;
            const method = blk: {
                const q = qualifiedName(callee.name);
                const sep = std.mem.lastIndexOf(u8, q, "::") orelse break :blk q;
                break :blk q[sep + 2 ..];
            };
            const target_method = blk: {
                const q = qualifiedName(shown);
                const sep = std.mem.lastIndexOf(u8, q, "::") orelse break :blk q;
                break :blk q[sep + 2 ..];
            };
            if (target_symbol.address != address or !std.mem.eql(u8, method, target_method)) {
                detail.* = try std.fmt.allocPrint(a, "vtable slot {d} holds {s}, not a {s} override", .{ prototype.vtable_index.?, shown, method });
                return error.InvalidThis;
            }
            dispatched = shown;
        }
        var this_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &this_bytes, object, .little);
        _ = try words.place(prototype.parameters[0], &this_bytes);
        try arguments.append(a, .{ .expression = text, .type = prototype.parameters[0].name, .class = "integer" });
    }
    for (request.arguments, 0..) |text, i| {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len > 0 and (trimmed[0] == '"' or trimmed[0] == '{' or trimmed[0] == '\'')) {
            detail.* = "string, character and array literals need target scratch memory; this milestone borrows only stack and refuses them";
            return error.ScratchUnavailable;
        }
        const value = session.evaluateAtDepth(a, request.tid, request.frame, 0, trimmed) catch |err| {
            detail.* = try std.fmt.allocPrint(a, "argument {d}: {s}", .{ i + 1, @errorName(err) });
            return if (err == error.ExecutionRequired) error.NestedCallUnsupported else err;
        };
        const target = if (i < declared.len) declared[i] else promoted(value) catch |err| {
            detail.* = try std.fmt.allocPrint(a, "variadic argument {d} has type {s}", .{ i + 1, value.type.name });
            return err;
        };
        const bytes = encode(session, a, value, target) catch |err| {
            detail.* = try std.fmt.allocPrint(a, "argument {d}: {s} to {s}", .{ i + 1, value.type.name, target.name });
            return err;
        };
        const class = words.place(target, bytes) catch |err| {
            detail.* = try std.fmt.allocPrint(a, "argument {d} of type {s}", .{ i + 1, target.name });
            return err;
        };
        try arguments.append(a, .{ .expression = trimmed, .type = target.name, .class = class });
    }
    var request_words = words.request;
    request_words.tid = request.tid;
    request_words.function = address;
    request_words.timeout_ms = request.timeout_ms;
    request_words.sret_size = sret_size;
    request_words.variadic = prototype.variadic;
    if (findSentinel(session)) |terminate| {
        request_words.sentinels[0] = terminate;
        request_words.sentinel_count = 1;
    }

    const before = session.target.snapshot().generation;
    var out = std.mem.zeroes(rt.struct_xrt_infcall_result);
    session.target.infcall(&request_words, &out) catch |err| {
        // A backend error after a target write (an agent link lost mid-call,
        // a resume refused after the restore) is still an execution attempt.
        // A lost agent reply leaves the host generation unchanged, so that
        // case is named explicitly.
        if (session.target.snapshot().generation != before or err == error.RemoteOutcomeUnknown) {
            _ = journal(session, actor, request, "execute_call", callee.name, address, callee.resolution, .refused, @errorName(err), &out, before);
            detail.* = "the call reached the target; get_execution_state has its journal row";
        }
        return err;
    };
    const outcome = outcomeOf(out.outcome);
    const reason: ?[]const u8 = if (outcome == .refused) refusalName(out.refusal) else null;
    var result = Result{
        .outcome = outcome,
        .tid = request.tid,
        .lookup_frame = request.frame,
        .reason = reason,
        .callee = callee.name,
        .callee_display = @import("../debug/demangle.zig").display(a, callee.name) catch null,
        .address = address,
        .resolution = callee.resolution,
        .dispatched_to = dispatched,
        .prototype_source = prototype.source,
        .return_type = if (prototype.return_type) |t| t.name else "void",
        .arguments = arguments.items,
        .call_frame_active = out.active,
        .restored = out.restored,
        .verified = out.verified,
        .mismatch = mismatchName(out.mismatch),
        .stack_balanced = out.stack_balanced or outcome != .returned,
        .duration_ns = out.duration_ns,
        .trap_address = if (out.trap != 0) out.trap else null,
        .borrowed_stack = if (out.borrowed_high != 0) .{ .low = out.borrowed_low, .high = out.borrowed_high, .bytes = out.borrowed_high - out.borrowed_low } else null,
        .compared = if (out.restored) .{ .general_register_bytes = out.gpr_bytes, .vector_state_bytes = out.xstate_bytes, .stack_bytes = out.stack_bytes } else null,
        .generation_before = before,
        .generation = session.target.snapshot().generation,
        .journal_sequence = 0,
    };
    if (outcome != .returned and outcome != .refused) {
        result.stop_pc = out.pc;
        if (out.signal != 0) {
            result.signal_number = out.signal;
            result.signal = linux.signalName(out.signal);
        }
        if (out.fault_address != 0) result.fault_address = out.fault_address;
        if (out.syscall != std.math.maxInt(u64)) result.blocked_syscall = out.syscall;
        if (out.event != 0) result.ptrace_event = out.event;
    }
    if (outcome == .returned) if (prototype.return_type) |ret| {
        const value = try decodeReturn(a, ret, &out);
        result.value = try session.summarize(a, value);
        if (ret.kind == .structure) {
            var fields: std.ArrayList(Field) = .empty;
            for (ret.fields[0..@min(ret.fields.len, 64)]) |field| {
                const member = eval.subvalue(value, field.type, field.offset) catch continue;
                try fields.append(a, .{ .name = field.name, .value = try session.summarize(a, member) });
            }
            result.fields = fields.items;
        }
        if (value.data) |data| result.raw = try hex(a, data) else {
            var word: [8]u8 = undefined;
            std.mem.writeInt(u64, &word, value.bits, .little);
            result.raw = try hex(a, word[0..@intCast(@min(8, ret.size))]);
        }
    };
    result.journal_sequence = journal(session, actor, request, "execute_call", callee.name, address, callee.resolution, outcome, reason, &out, before);
    session.execution.active = if (out.active) .{ .tid = request.tid, .callee = session.execution.journal[session.execution.count - 1].callee, .outcome = outcome, .sequence = result.journal_sequence } else null;
    result.generation = session.target.snapshot().generation;
    return result;
}
fn findSentinel(session: *Session) ?u64 {
    // The Itanium unwinder calls std::terminate when an exception reaches
    // the debugger's return frame, before abort runs.
    const symbol = session.modules.findSymbol("_ZSt9terminatev") catch return null;
    return if (symbol.ifunc) null else symbol.address;
}
fn journal(session: *Session, actor: model.Actor, request: Request, action: []const u8, callee: []const u8, address: ?u64, resolution: []const u8, outcome: Outcome, reason: ?[]const u8, out: *const rt.struct_xrt_infcall_result, before: u64) u64 {
    session.execution.append(.{
        .sequence = 0,
        .actor = actor,
        .client_id = if (actor == .agent) session.agent_client_id else null,
        .scope = scopeName(session, actor),
        .tid = request.tid,
        .frame = request.frame,
        .action = action,
        .callee = callee,
        .address = address,
        .resolution = resolution,
        .argument_count = request.arguments.len,
        .outcome = outcome,
        .reason = reason,
        .restored = out.restored,
        .verified = out.verified,
        .call_frame_active = out.active,
        .duration_ns = out.duration_ns,
        .generation_before = before,
        .generation_after = session.target.snapshot().generation,
        .time_ns = linux.now(),
    });
    session.record(actor, action);
    return session.execution.sequence;
}

pub const Resolution = struct {
    outcome: Outcome,
    reason: ?[]const u8 = null,
    tid: i32,
    callee: []const u8,
    call_frame_active: bool,
    restored: bool,
    verified: bool,
    mismatch: ?[]const u8 = null,
    compared: ?struct { general_register_bytes: u64, vector_state_bytes: u64, stack_bytes: u64 } = null,
    generation_before: u64,
    generation: u64,
    journal_sequence: u64,
};
/// Restore the saved context of the active call frame, or abandon it and
/// keep the thread where it stopped inside the callee.
pub fn resolve(session: *Session, actor: model.Actor, generation: ?u64, restore: bool) !Resolution {
    try authority(session, actor, generation);
    if (session.target.core != null) return error.ReadOnlyCore;
    if (session.target.snapshot().state == .exited) session.execution.active = null;
    const active = session.execution.active orelse return error.NoActiveCallFrame;
    const before = session.target.snapshot().generation;
    var out = std.mem.zeroes(rt.struct_xrt_infcall_result);
    try session.target.infcallResolve(restore, &out);
    const outcome = outcomeOf(out.outcome);
    const reason: ?[]const u8 = if (outcome == .refused) refusalName(out.refusal) else null;
    if (outcome == .refused and out.refusal == rt.XRT_INFCALL_NOT_ACTIVE) session.execution.active = null;
    const sequence = journal(session, actor, .{ .tid = active.tid, .callee = active.callee }, if (restore) "restore_execution" else "abandon_execution", active.callee, null, "active_frame", outcome, reason, &out, before);
    if (outcome != .refused) session.execution.active = if (out.active) active else null;
    return .{ .outcome = outcome, .reason = reason, .tid = active.tid, .callee = active.callee, .call_frame_active = out.active, .restored = out.restored, .verified = out.verified, .mismatch = mismatchName(out.mismatch), .compared = if (out.restored) .{ .general_register_bytes = out.gpr_bytes, .vector_state_bytes = out.xstate_bytes, .stack_bytes = out.stack_bytes } else null, .generation_before = before, .generation = session.target.snapshot().generation, .journal_sequence = sequence };
}

test "SysV classification of scalars and small aggregates" {
    const t = std.testing;
    const int = eval.Type{ .name = "int", .kind = .signed, .size = 4 };
    const dbl = eval.Type{ .name = "double", .kind = .float, .size = 8 };
    const flt = eval.Type{ .name = "float", .kind = .float, .size = 4 };
    try t.expectEqual(Pass{ .registers = .{ .integer, .none } }, try classify(&int));
    try t.expectEqual(Pass{ .registers = .{ .sse, .none } }, try classify(&dbl));
    const pair = eval.Type{ .name = "pair", .kind = .structure, .size = 16, .fields = &.{ .{ .name = "a", .offset = 0, .type = &int }, .{ .name = "b", .offset = 8, .type = &dbl } } };
    try t.expectEqual(Pass{ .registers = .{ .integer, .sse } }, try classify(&pair));
    const floats = eval.Type{ .name = "f2", .kind = .structure, .size = 8, .fields = &.{ .{ .name = "x", .offset = 0, .type = &flt }, .{ .name = "y", .offset = 4, .type = &flt } } };
    try t.expectEqual(Pass{ .registers = .{ .sse, .none } }, try classify(&floats));
    const mixed = eval.Type{ .name = "m", .kind = .structure, .size = 8, .fields = &.{ .{ .name = "x", .offset = 0, .type = &flt }, .{ .name = "y", .offset = 4, .type = &int } } };
    try t.expectEqual(Pass{ .registers = .{ .integer, .none } }, try classify(&mixed));
    const long = eval.Type{ .name = "long", .kind = .signed, .size = 8 };
    const big = eval.Type{ .name = "big", .kind = .structure, .size = 24, .fields = &.{ .{ .name = "a", .offset = 0, .type = &long }, .{ .name = "b", .offset = 8, .type = &long }, .{ .name = "c", .offset = 16, .type = &long } } };
    try t.expectEqual(Pass.memory, try classify(&big));
    // An aggregate whose layout is unknown is refused, never copied as bytes.
    const opaque_big = eval.Type{ .name = "opaque", .kind = .structure, .size = 24, .fields = &.{} };
    try t.expectError(error.UnsupportedArgumentType, classify(&opaque_big));
    const ld = eval.Type{ .name = "long double", .kind = .float, .size = 16 };
    try t.expectError(error.LongDoubleUnsupported, classify(&ld));
}

test "explicit prototypes parse scalars, pointers and varargs and refuse aggregates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parsePrototype(a, "size_t(const char *)");
    try std.testing.expectEqual(@as(usize, 1), p.parameters.len);
    try std.testing.expectEqual(eval.Kind.pointer, p.parameters[0].kind);
    try std.testing.expectEqual(@as(u64, 8), p.return_type.?.size);
    const v = try parsePrototype(a, "int (int, ...)");
    try std.testing.expect(v.variadic);
    try std.testing.expect((try parsePrototype(a, "void(void)")).return_type == null);
    try std.testing.expectError(error.PrototypeTypeUnsupported, parsePrototype(a, "int(struct pair)"));
    try std.testing.expectError(error.InvalidPrototype, parsePrototype(a, "int(..., int)"));
    try std.testing.expectEqualStrings("Counter::add", qualifiedName("Counter::add(int)"));
    try std.testing.expectEqualStrings("maxof<int>", qualifiedName("int maxof<int>(int, int)"));
    try std.testing.expectEqualStrings("(long, long unsigned, char *)", try canonicalParameters(a, &.{ "long int", "long unsigned int", "const char *" }));
    try std.testing.expectEqualStrings("Counter::add", baseName("Counter::add(long)"));
}
