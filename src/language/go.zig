//! Retained-stop adapter for the C Go runtime reader. Goroutines come from
//! runtime.allgs; layout from the image's own DWARF. No target calls.
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
pub fn reader(session: *model.Session) c.struct_xgo_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null };
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
fn reason(a: A, value: [*c]const u8) !?[]const u8 {
    return if (value == null) null else try a.dupe(u8, std.mem.span(value));
}
fn buildId(a: A, layout: *const c.struct_xgo_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, layout.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (layout.build_id[0..layout.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
fn runtimeModule(session: *model.Session) !*Module {
    // Initial profile: a statically linked Go executable (the default
    // `go build` output), identified by kernel PHDR evidence.
    const runtime = @import("../target/runtime.zig");
    var loader = std.mem.zeroes(runtime.c.struct_xrt_loader);
    _ = runtime.c.xrt_target_loader(session.target.handle, &loader, null);
    if (loader.main_phdr == 0) return error.GoModuleIdentityUnavailable;
    const module = session.modules.at(loader.main_phdr) catch return error.GoModuleIdentityUnavailable;
    if (module.symbols().findSymbol("runtime.buildVersion") == null or module.symbols().findSymbol("runtime.allgs") == null) return error.GoRuntimeUnavailable;
    return module;
}
pub fn globalAddress(module: *Module, name: []const u8) !u64 {
    const sym = module.symbols().findSymbol(name) orelse return error.GoRuntimeSymbolsUnavailable;
    if (!sym.hasAddress()) return error.GoRuntimeSymbolsUnavailable;
    return module.runtimeAddress(sym.value);
}
fn word(session: *model.Session, at: u64) !u64 {
    var bytes: [8]u8 = undefined;
    if (try session.target.readMemory(at, &bytes) != bytes.len) return error.GoRuntimeUnreadable;
    return std.mem.readInt(u64, &bytes, .little);
}
/// runtime.buildVersion as stored by the linker in the loaded image.
fn loadedVersion(session: *model.Session, module: *Module, out: *[64]u8) ![]const u8 {
    const at = try globalAddress(module, "runtime.buildVersion");
    const ptr = try word(session, at);
    const len = try word(session, at + 8);
    if (len == 0 or len > out.len) return error.GoVersionUnavailable;
    if (try session.target.readMemory(ptr, out[0..@intCast(len)]) != len) return error.GoVersionUnavailable;
    return out[0..@intCast(len)];
}
fn verify(session: *model.Session, module: *Module) ![]const u8 {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (session.target.arch() != .x86_64) return error.GoArchitectureUnsupported;
    const id = module.image.buildId() orelse return error.GoBuildIdUnavailable;
    if (id.len == 0 or id.len > 64) return error.GoBuildIdUnavailable;
    const note = module.image.sectionByName(".note.gnu.build-id") orelse return error.GoBuildIdUnavailable;
    if (note.flags & 2 == 0 or note.size > 256) return error.GoBuildIdUnavailable;
    const expected = try module.image.sectionData(note);
    var actual: [256]u8 = undefined;
    if (try session.target.readMemory(try module.runtimeAddress(note.addr), actual[0..expected.len]) != expected.len or !std.mem.eql(u8, expected, actual[0..expected.len])) return error.GoBuildIdMismatch;
    var version: [64]u8 = undefined;
    if (!std.mem.eql(u8, try loadedVersion(session, module, &version), c.XGO_VERSION)) return error.GoVersionUnsupported;
    return id;
}
pub fn verifiedModule(session: *model.Session) !*Module {
    const module = try runtimeModule(session);
    _ = try verify(session, module);
    return module;
}
fn profile(session: *model.Session, module: *Module) !*const c.struct_xgo_layout {
    const id = try verify(session, module);
    if (module.go_layout == null) {
        const debug = module.debugInfo() catch |err| return if (err == error.DebugMetadataPending) err else error.GoDwarfUnavailable;
        var layout: c.struct_xgo_layout = undefined;
        if (c.xgo_layout_build(debug.dwarf, id.ptr, id.len, &layout)) |why| {
            inline for (.{ error.GoDwarfMalformed, error.GoDwarfWorkLimit, error.GoDwarfAmbiguous, error.GoDwarfTypesUnavailable, error.GoDwarfTypesUnsupported, error.GoDwarfConstantsUnavailable, error.GoConstantMismatch, error.GoDwarfUnitLimit }) |err| {
                if (std.mem.eql(u8, std.mem.span(why), @errorName(err))) return err;
            }
            return error.GoLayoutUnsupported;
        }
        module.go_layout = layout;
    }
    return &module.go_layout.?;
}
fn globals(module: *Module) !c.struct_xgo_globals {
    const wait = module.symbols().findSymbol("runtime.waitReasonStrings") orelse return error.GoRuntimeSymbolsUnavailable;
    const status = module.symbols().findSymbol("runtime.gStatusStrings") orelse return error.GoRuntimeSymbolsUnavailable;
    if (wait.size == 0 or wait.size % 16 != 0 or status.size == 0 or status.size % 16 != 0) return error.GoRuntimeSymbolsUnavailable;
    return .{
        .allgs = try globalAddress(module, "runtime.allgs"),
        .allglen = try globalAddress(module, "runtime.allglen"),
        .moduledata = try globalAddress(module, "runtime.firstmoduledata"),
        .wait_strings = try globalAddress(module, "runtime.waitReasonStrings"),
        .wait_count = wait.size / 16,
        .status_strings = try globalAddress(module, "runtime.gStatusStrings"),
        .status_count = status.size / 16,
    };
}
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    return .{ .version = c.XGO_VERSION, .build_id = try buildId(a, layout), .basis = "same-image DWARF + runtime.buildVersion" };
}
pub const Anchor = struct { frame: usize, pc: []const u8, symbol: []const u8 };
pub const Runtime = struct { language: []const u8 = "go", implementation: []const u8 = "gc", version: []const u8 = c.XGO_VERSION, build_id: []const u8, layout_source: []const u8 = "same-image DWARF (runtime.g, runtime.moduledata, runtime._func) + pclntab" };
pub const Instance = struct { kind: []const u8 = "address", namespace: []const u8 = "go:g", address: []const u8, scope: []const u8 = "this retained stop only; goroutines move between threads and stacks move on growth" };
pub const Frame = struct { name: []const u8, file: ?[]const u8, line: ?u32, kind: []const u8, pc: []const u8, function_entry: ?[]const u8, go_traceback_visible: bool, reason: ?[]const u8, line_reason: ?[]const u8, provenance: []const u8 = "external_read" };
pub const Created = struct { function: []const u8, file: ?[]const u8, line: ?u32, pc: []const u8, parent_goid: u64, go_traceback_visible: bool = false, reason: ?[]const u8 };
pub const Goroutine = struct { id: u64, status: []const u8, wait_reason: ?[]const u8, state: []const u8, scan: bool, system: bool, thread: ?i32, g: []const u8, start_function: ?[]const u8, created_by: ?Created, unwind: []const u8 };
pub const Segment = struct { title: []const u8, runtime: Runtime, runtime_instance: Instance, anchor: ?Anchor, frames: []Frame, chain_complete: bool = false, state: []const u8 = "partial", reason: ?[]const u8, goroutine: Goroutine, memory_reads: usize, memory_bytes: usize };
pub const Stack = struct { session_id: u64, generation: u64, tid: i32, segments: []Segment, total_goroutines: usize, dead_goroutines: usize, truncated: bool, reason: ?[]const u8, memory_reads: usize, memory_bytes: usize, basis: []const u8 = "runtime.allgs; parked goroutines unwound from g.sched/syscall state by the amd64 frame-pointer chain, running ones from thread registers (CFI); names from pclntab, lines and inlining from DWARF; no target calls" };

const Raw = struct { pc: u64, lookup: u64, func: c.struct_xgo_func, reason: ?[]const u8 };
/// Expand one physical frame into its DWARF inline chain, innermost first.
fn expand(session: *model.Session, a: A, layout: *const c.struct_xgo_layout, out: *std.ArrayList(Frame), raw: Raw, callee: *?u8) !void {
    const fname = std.mem.sliceTo(&raw.func.name, 0);
    const pc = try hex(a, raw.pc);
    const entry: ?[]const u8 = if (raw.func.entry != 0) try hex(a, raw.func.entry) else null;
    if (fname.len == 0) {
        try out.append(a, .{ .name = "(unknown)", .file = null, .line = null, .kind = "go", .pc = pc, .function_entry = null, .go_traceback_visible = false, .reason = raw.reason orelse (try reason(a, raw.func.reason)) orelse "GoFunctionUnavailable", .line_reason = "GoFunctionUnavailable" });
        return;
    }
    var line_reason: ?[]const u8 = null;
    const site: ?@import("../debug/info.zig").Site = session.sourceAt(a, raw.lookup) catch |err| blk: {
        line_reason = @errorName(err);
        break :blk null;
    };
    var inlined: []@import("../debug/info.zig").Inline = &.{};
    if (session.modules.at(raw.lookup)) |module| {
        if (module.debugInfo()) |debug| {
            inlined = debug.inlineAt(a, try module.linkAddress(raw.lookup)) catch &.{};
        } else |_| {}
    } else |_| {}
    var file: ?[]const u8 = if (site) |s| s.path else null;
    var line: ?u32 = if (site) |s| s.line else null;
    for (inlined) |item| {
        const visible = c.xgo_traceback_visible(layout, (try a.dupeZ(u8, item.name)).ptr, @intCast(layout.constants[c.XGO_C_FUNC_NORMAL]), @intFromBool(out.items.len == 0), @intFromBool(callee.* != null), callee.* orelse 0) != 0;
        try out.append(a, .{ .name = try a.dupe(u8, item.name), .file = file, .line = line, .kind = "go-inlined", .pc = pc, .function_entry = null, .go_traceback_visible = visible, .reason = null, .line_reason = line_reason });
        callee.* = @intCast(layout.constants[c.XGO_C_FUNC_NORMAL]);
        file = if (item.call_path) |path| try session.sourceMaps().forward(a, path) else null;
        line = item.call_line;
        if (file == null or line == null) line_reason = "GoInlineCallSiteUnavailable";
    }
    const visible = c.xgo_traceback_visible(layout, &raw.func.name, raw.func.id, @intFromBool(out.items.len == 0), @intFromBool(callee.* != null), callee.* orelse 0) != 0;
    try out.append(a, .{ .name = try a.dupe(u8, fname), .file = file, .line = line, .kind = "go", .pc = pc, .function_entry = entry, .go_traceback_visible = visible, .reason = raw.reason orelse try reason(a, raw.func.reason), .line_reason = line_reason });
    callee.* = raw.func.id;
}
fn created(session: *model.Session, a: A, layout: *const c.struct_xgo_layout, g: *const c.struct_xgo_goroutine) !?Created {
    if (g.gopc == 0) return null;
    const name = std.mem.sliceTo(&g.creator.name, 0);
    if (name.len == 0) return .{ .function = "(unknown)", .file = null, .line = null, .pc = try hex(a, g.gopc), .parent_goid = g.parent, .reason = (try reason(a, g.creator.reason)) orelse "GoFunctionUnavailable" };
    // The runtime prints the creating call's line at gopc-1.
    const lookup = if (g.gopc > g.creator.entry) g.gopc - 1 else g.gopc;
    const site = session.sourceAt(a, lookup) catch null;
    // Go prints "created by" for every goroutine but 1 when showframe allows it.
    const visible = g.goid != 1 and c.xgo_traceback_visible(layout, &g.creator.name, @intCast(layout.constants[c.XGO_C_FUNC_NORMAL]), 0, 1, @intCast(layout.constants[c.XGO_C_FUNC_NORMAL])) != 0;
    return .{ .function = try a.dupe(u8, name), .file = if (site) |s| s.path else null, .line = if (site) |s| s.line else null, .pc = try hex(a, g.gopc), .parent_goid = g.parent, .go_traceback_visible = visible, .reason = try reason(a, g.creator.reason) };
}
fn traced(session: *model.Session, tid: u64) ?i32 {
    for (session.target.threadSlice()) |thread| if (thread.state != .exited and @as(u64, @intCast(thread.tid)) == tid) return thread.tid;
    return null;
}
pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    if (first != 0) return error.InvalidFrame;
    const generation = session.target.snapshot().generation;
    const module = try runtimeModule(session);
    const layout = try profile(session, module);
    const roots = try globals(module);
    var r = reader(session);
    const raw = try a.create(c.struct_xgo_snapshot);
    c.xgo_goroutines_read(layout, &r, &roots, raw);
    const build_id = try buildId(a, layout);
    var segments: std.ArrayList(Segment) = .empty;
    for (raw.items[0..raw.count]) |*g| {
        var frames: std.ArrayList(Frame) = .empty;
        var callee: ?u8 = null;
        var why: ?[]const u8 = try reason(a, g.reason);
        var complete = g.complete != 0;
        var thread: ?i32 = null;
        var anchor: ?Anchor = null;
        var unwind: []const u8 = if (g.status == layout.constants[c.XGO_C_GSYSCALL]) "syscall" else "sched";
        if (g.running != 0) {
            unwind = "thread_registers";
            thread = traced(session, g.thread);
            if (why == null and thread == null) why = "GoThreadNotTraced";
            if (why == null) {
                // Running: CFI-unwind the thread, keep frames on this g's stack.
                const native = try session.stack(a, thread.?, 64);
                const sp_index = session.target.arch().sp();
                var started = false;
                for (native) |f| {
                    const sp = f.registers[sp_index] orelse break;
                    if (sp < g.stack_lo or sp >= g.stack_hi) {
                        if (started) break;
                        continue;
                    }
                    if (!started and thread.? == tid) anchor = .{ .frame = f.index, .pc = try hex(a, f.pc), .symbol = try a.dupe(u8, f.symbol orelse "(unnamed)") };
                    if (!started and f.index != 0) why = "GoRunningOnSystemStack";
                    started = true;
                    var func: c.struct_xgo_func = undefined;
                    c.xgo_func_at(layout, &r, &roots, f.pc, &func);
                    try expand(session, a, layout, &frames, .{ .pc = f.pc, .lookup = f.lookup_pc, .func = func, .reason = f.diagnostic }, &callee);
                    if (func.reason == null and func.id == layout.constants[c.XGO_C_FUNC_GOEXIT]) {
                        complete = true;
                        break;
                    }
                    if (f.diagnostic != null) break;
                }
                if (!started and why == null) why = "GoRunningOnSystemStack";
                if (!complete and why == null) why = "GoUnwindIncomplete";
            }
        } else for (g.frames[0..g.count]) |*f| {
            try expand(session, a, layout, &frames, .{ .pc = f.pc, .lookup = f.lookup_pc, .func = f.func, .reason = try reason(a, f.reason) }, &callee);
        }
        const status = std.mem.sliceTo(&g.status_name, 0);
        const wait = std.mem.sliceTo(&g.wait_name, 0);
        const shown = if (wait.len > 0) wait else status;
        const state = if (g.scan != 0) try std.fmt.allocPrint(a, "{s} (scan)", .{shown}) else try a.dupe(u8, shown);
        const start = std.mem.sliceTo(&g.start.name, 0);
        try segments.append(a, .{
            .title = try std.fmt.allocPrint(a, "goroutine {d} [{s}]{s}", .{ g.goid, state, if (g.system != 0) " (runtime)" else "" }),
            .runtime = .{ .build_id = build_id },
            .runtime_instance = .{ .address = try hex(a, g.g) },
            .anchor = anchor,
            .frames = try frames.toOwnedSlice(a),
            .chain_complete = complete and why == null,
            .state = if (complete and why == null) "complete" else "partial",
            .reason = why,
            .goroutine = .{ .id = g.goid, .status = try a.dupe(u8, status), .wait_reason = if (wait.len > 0) try a.dupe(u8, wait) else null, .state = state, .scan = g.scan != 0, .system = g.system != 0, .thread = thread, .g = try hex(a, g.g), .start_function = if (start.len > 0) try a.dupe(u8, start) else null, .created_by = try created(session, a, layout, g), .unwind = unwind },
            .memory_reads = 0,
            .memory_bytes = 0,
        });
    }
    // The goroutine on the selected thread first, then user goroutines in
    // allgs order, then runtime-internal ones (Go's own traceback order).
    const items = segments.items;
    std.mem.sortUnstable(Segment, items, {}, struct {
        fn rank(s: Segment) u8 {
            return if (s.anchor != null) 0 else if (!s.goroutine.system) 1 else 2;
        }
        fn less(_: void, x: Segment, y: Segment) bool {
            return rank(x) < rank(y) or (rank(x) == rank(y) and x.goroutine.id < y.goroutine.id);
        }
    }.less);
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = try segments.toOwnedSlice(a), .total_goroutines = raw.total, .dead_goroutines = raw.dead, .truncated = raw.truncated != 0, .reason = try reason(a, raw.reason), .memory_reads = r.reads, .memory_bytes = r.bytes };
}
