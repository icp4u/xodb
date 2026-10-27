//! Synchronous, borrowed inspection access. No run control or session escape.
//! The owner supplies callbacks; providers neither cast nor retain their handles.
//! Calls are synchronous but may re-enter a provider: runtime_thread can ask
//! witnessed() to call python.runtimeWitness(). Keep per-call scratch local;
//! do not hold a non-reentrant lock or assume exclusive provider execution.
const std = @import("std");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const info = @import("../debug/info.zig");
const eval = @import("../debug/evaluate.zig");
const binding = @import("binding_types.zig");
const values = @import("value_types.zig");
pub const Frame = @import("../debug/frame.zig").Frame;
const A = std.mem.Allocator;
const Arch = @import("../target/arch.zig").Arch;
/// Incomplete metadata is not proof that a runtime or a frame is absent.
pub fn metadataFailure(err: anyerror, fallback: anyerror) anyerror {
    return switch (err) {
        error.DebugMetadataPending,
        error.DebugMetadataCancelled,
        error.SymbolDiscoveryPending,
        error.SymbolDiscoveryCancelled,
        => err,
        else => fallback,
    };
}
pub fn requirePreparedFrames(frames: []const Frame) !void {
    for (frames) |frame| if (frame.diagnostic) |why| {
        if (std.mem.eql(u8, why, "DebugMetadataPending") or std.mem.eql(u8, why, "SymbolDiscoveryPending")) return error.DebugMetadataPending;
        if (std.mem.eql(u8, why, "DebugMetadataCancelled") or std.mem.eql(u8, why, "SymbolDiscoveryCancelled")) return error.DebugMetadataCancelled;
    };
}
pub const Snapshot = struct { pid: i32, generation: u64, image_epoch: u64, stopped: bool };
pub const Symbol = struct { name: []const u8, offset: u64 };
pub const MemoryRange = struct { start: u64, end: u64 };
pub const Binding = struct {
    python_stack: ?*const c.struct_xpy_stack = null,
    budget: binding.Budget = .{},
    module: Module,
    identity: binding.Identity,
    token: binding.Token,
};

/// Image identity and metadata retain the owner's original lifetime and caches.
pub const Module = struct {
    id: u64,
    identity: *anyopaque,
    image: *const elf.Image,
    symbol_image: *const elf.Image,
    bias: u64,
    layouts: *@import("layouts.zig").Layouts,
    debug_allocator: A,
    has_debug_companion: bool,
    debug_info: *const fn (*anyopaque) anyerror!*info.Image,

    pub fn symbols(self: Module) *const elf.Image {
        return self.symbol_image;
    }
    pub fn runtimeAddress(self: Module, link: u64) !u64 {
        return std.math.add(u64, link, self.bias) catch error.InvalidAddress;
    }
    pub fn linkAddress(self: Module, runtime: u64) !u64 {
        if (runtime < self.bias) return error.UnmappedAddress;
        return runtime - self.bias;
    }
    pub fn debugInfo(self: Module) !*info.Image {
        return self.debug_info(self.identity);
    }
};

pub const Context = struct {
    id: u64,
    languages: @import("types.zig").Languages,
    user: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        read_memory: *const fn (*anyopaque, u64, []u8) anyerror!usize,
        snapshot: *const fn (*anyopaque) Snapshot,
        arch: *const fn (*anyopaque) Arch,
        is_gdb: *const fn (*anyopaque) bool,
        main_phdr: *const fn (*anyopaque) u64,
        expect_generation: *const fn (*anyopaque, u64) anyerror!void,
        module_at: *const fn (*anyopaque, u64) anyerror!Module,
        refresh_maps: *const fn (*anyopaque) anyerror!void,
        runtime_module_at: *const fn (*anyopaque, u64) anyerror!Module,
        register_value: *const fn (*anyopaque, i32, []const u8) anyerror!?u64,
        mapped_range: *const fn (*anyopaque, u64) ?MemoryRange,
        symbol_at: *const fn (*anyopaque, u64) anyerror!Symbol,
        thread_identity: *const fn (*anyopaque, i32) anyerror!u64,
        live_thread: *const fn (*anyopaque, u64) ?i32,
        source_at: *const fn (*anyopaque, A, u64) anyerror!info.Site,
        map_source_path: *const fn (*anyopaque, A, []const u8) anyerror![]const u8,
        summarize: *const fn (*anyopaque, A, eval.Value) anyerror!values.ValueSummary,
        value_children: *const fn (*anyopaque, A, eval.Value, u64, usize, bool) anyerror!values.ValuePage,
        javascript_layout: *const fn (*anyopaque) anyerror!c.struct_xjs_layout,
        writable_range: *const fn (*anyopaque, u64, u64, u64) ?MemoryRange,
        runtime_discover: *const fn (*anyopaque, binding.Language) anyerror!void,
        runtime_process: *const fn (*anyopaque, binding.Language) anyerror!Binding,
        runtime_thread: *const fn (*anyopaque, binding.Language, A, i32, []const Frame, usize) anyerror!Binding,
        runtime_retained: *const fn (*anyopaque, binding.Token) anyerror!Module,
        runtime_owns: *const fn (*anyopaque, Module, Frame) bool,
        stack: *const fn (*anyopaque, A, i32, usize) anyerror![]Frame,
        unwind_stack: *const fn (*anyopaque, A, i32, usize) anyerror![]Frame,
        frame_locals: *const fn (*anyopaque, A, Frame) anyerror![]info.Local,
        evaluate_in_frame: *const fn (*anyopaque, A, Frame, []const info.Local, []const u8) anyerror!eval.Value,
    };
    pub fn readMemory(self: *const Context, at: u64, bytes: []u8) !usize {
        return self.ops.read_memory(self.user, at, bytes);
    }
    pub fn snapshot(self: *const Context) Snapshot {
        return self.ops.snapshot(self.user);
    }
    pub fn arch(self: *const Context) Arch {
        return self.ops.arch(self.user);
    }
    pub fn isGdb(self: *const Context) bool {
        return self.ops.is_gdb(self.user);
    }
    pub fn mainPhdr(self: *const Context) u64 {
        return self.ops.main_phdr(self.user);
    }
    pub fn expectGeneration(self: *const Context, generation: u64) !void {
        return self.ops.expect_generation(self.user, generation);
    }
    pub fn moduleAt(self: *const Context, address: u64) !Module {
        return self.ops.module_at(self.user, address);
    }
    pub fn refreshMaps(self: *const Context) !void {
        return self.ops.refresh_maps(self.user);
    }
    pub fn runtimeModuleAt(self: *const Context, address: u64) !Module {
        return self.ops.runtime_module_at(self.user, address);
    }
    pub fn registerValue(self: *const Context, tid: i32, name: []const u8) !?u64 {
        return self.ops.register_value(self.user, tid, name);
    }
    /// Bounds from known mappings without imposing an access-permission filter.
    pub fn mappedRange(self: *const Context, address: u64) ?MemoryRange {
        return self.ops.mapped_range(self.user, address);
    }
    pub fn symbolAt(self: *const Context, address: u64) !Symbol {
        return self.ops.symbol_at(self.user, address);
    }
    pub fn threadIdentity(self: *const Context, tid: i32) !u64 {
        return self.ops.thread_identity(self.user, tid);
    }
    pub fn liveThread(self: *const Context, tid: u64) ?i32 {
        return self.ops.live_thread(self.user, tid);
    }
    pub fn sourceAt(self: *const Context, a: A, address: u64) !info.Site {
        return self.ops.source_at(self.user, a, address);
    }
    pub fn mapSourcePath(self: *const Context, a: A, path: []const u8) ![]const u8 {
        return self.ops.map_source_path(self.user, a, path);
    }
    pub fn summarize(self: *const Context, a: A, value: eval.Value) anyerror!values.ValueSummary {
        return self.ops.summarize(self.user, a, value);
    }
    pub fn valueChildren(self: *const Context, a: A, value: eval.Value, start: u64, limit: usize, raw: bool) anyerror!values.ValuePage {
        return self.ops.value_children(self.user, a, value, start, limit, raw);
    }
    pub fn javascriptLayout(self: *const Context) !c.struct_xjs_layout {
        return self.ops.javascript_layout(self.user);
    }
    /// Bounds from the owner's already-known mappings; never refreshes them.
    pub fn writableRange(self: *const Context, address: u64, below: u64, above: u64) ?MemoryRange {
        return self.ops.writable_range(self.user, address, below, above);
    }
    pub fn discoverRuntime(self: *const Context, language: binding.Language) !void {
        return self.ops.runtime_discover(self.user, language);
    }
    pub fn runtimeProcess(self: *const Context, language: binding.Language) !Binding {
        return self.ops.runtime_process(self.user, language);
    }
    pub fn runtimeThread(self: *const Context, language: binding.Language, a: A, tid: i32, native: []const Frame, first: usize) !Binding {
        return self.ops.runtime_thread(self.user, language, a, tid, native, first);
    }
    pub fn retainedRuntime(self: *const Context, token: binding.Token) !Module {
        return self.ops.runtime_retained(self.user, token);
    }
    pub fn runtimeOwns(self: *const Context, module: Module, frame: Frame) bool {
        return self.ops.runtime_owns(self.user, module, frame);
    }
    pub fn stack(self: *const Context, a: A, tid: i32, limit: usize) ![]Frame {
        const frames = try self.ops.stack(self.user, a, tid, limit);
        try requirePreparedFrames(frames);
        return frames;
    }
    pub fn frameLocals(self: *const Context, a: A, frame: Frame) ![]info.Local {
        return self.ops.frame_locals(self.user, a, frame);
    }
    /// Native register/CFI join without requesting source or inline metadata.
    pub fn unwindStack(self: *const Context, a: A, tid: i32, limit: usize) ![]Frame {
        const frames = try self.ops.unwind_stack(self.user, a, tid, limit);
        try requirePreparedFrames(frames);
        return frames;
    }
    pub fn evaluateInFrame(self: *const Context, a: A, frame: Frame, locals: []const info.Local, text: []const u8) !eval.Value {
        return self.ops.evaluate_in_frame(self.user, a, frame, locals, text);
    }
};
