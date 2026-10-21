//! Runtime layout identity is separate from evidence of interpreter execution.
//! All discovery and native unwinding runs on the stopped target's owner.
const std = @import("std");
const model = @import("session.zig");
const Module = @import("modules.zig").Module;
const A = std.mem.Allocator;
const c = @import("../c.zig").api;
pub const Budget = @import("../language/binding_types.zig").Budget;
pub const Witness = @import("../language/binding_types.zig").Witness;
pub const Language = @import("../language/binding_types.zig").Language;
pub const Identity = @import("../language/binding_types.zig").Identity;
pub const Token = @import("../language/binding_types.zig").Token;
pub const Binding = struct {
    python_stack: ?*const c.struct_xpy_stack = null,
    budget: Budget = .{},
    module: *Module,
    identity: Identity,
    token: Token,
};
const Key = struct { session: u64, generation: u64, epoch: u64, maps: u64, metadata: u64, threads: u64 };
const Scan = struct {
    discovered: bool = false,
    /// The last search found no image defining the anchor and was refused
    /// only because another mapped image could not be examined.
    vetoed_empty: bool = false,
    modules: [4]*Module = undefined,
    count: usize = 0,
    witnessed: [4]bool = @splat(false),
    next: usize = 0,
    done: bool = false,
};
pub const State = struct {
    key: ?Key = null,
    scans: [2]Scan = @splat(.{}),
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    native: ?[]model.Frame = null,
    tid: ?i32 = null,
    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }
    /// A program with no such runtime must not gain a "detected" tab from an
    /// unrelated unexaminable mapping (a JIT memfd, a deleted library).
    pub fn vetoedWithoutCandidate(self: *const State, index: usize) bool {
        return index < self.scans.len and self.scans[index].vetoed_empty;
    }
    pub fn clear(self: *State) void {
        _ = self.arena.reset(.free_all);
        self.key = null;
        self.scans = @splat(.{});
        self.native = null;
        self.tid = null;
    }
    fn prepare(self: *State, session: *model.Session, comptime language: Language) !*Scan {
        try session.languages.require(switch (language) {
            .python => .python,
            .perl => .perl,
        });
        const snapshot = session.target.snapshot();
        if (snapshot.state != .stopped) {
            self.clear();
            return error.NotStopped;
        }
        if (snapshot.thread_count > 1024) return error.LanguageThreadLimit;
        try session.refreshMaps();
        const key = Key{ .session = session.id, .generation = snapshot.generation, .epoch = snapshot.image_epoch, .maps = session.modules.maps_revision, .metadata = session.metadata.revision, .threads = threadStamp(session) };
        if (self.key == null or !std.meta.eql(self.key.?, key)) {
            self.clear();
            self.key = key;
        }
        const scan = &self.scans[@intFromEnum(language)];
        if (!scan.discovered) {
            if (session.modules.regions.items.len > 4096) return switch (language) {
                .python => error.PythonModuleLimit,
                .perl => error.PerlModuleLimit,
            };
            const found = session.modules.definers(switch (language) {
                .python => "_PyRuntime",
                .perl => "Perl_runops_standard",
            }) catch |err| return moduleError(language, err);
            scan.vetoed_empty = false;
            // One examined anchor is sufficient for a cooperative target:
            // unrelated JIT or deleted mappings cannot identify this runtime.
            if (found.unexamined) |err| if (found.modules.len == 0 or (found.modules.len != 1 and !overBudget(err))) {
                scan.vetoed_empty = found.modules.len == 0 and !overBudget(err);
                return moduleError(language, err);
            };
            if (found.modules.len == 0) return unavailable(language);
            if (found.modules.len > scan.modules.len) return error.SymbolDefinerLimit;
            @memcpy(scan.modules[0..found.modules.len], found.modules);
            scan.count = found.modules.len;
            scan.discovered = true;
        }
        return scan;
    }
    fn walk(self: *State, session: *model.Session, tid: i32) ![]model.Frame {
        if (self.tid != tid or self.native == null) {
            _ = self.arena.reset(.free_all);
            self.native = null;
            self.tid = tid;
            const frames = try session.stack(self.arena.allocator(), tid, 64);
            for (frames) |frame| if (frame.diagnostic) |why| {
                if (std.mem.endsWith(u8, why, "Pending")) return error.SymbolDiscoveryPending;
            };
            self.native = frames;
        }
        return self.native.?;
    }
};
pub fn threadStamp(session: *model.Session) u64 {
    if (session.target.snapshot().thread_count > 1024) return std.math.maxInt(u64);
    var hash = std.hash.Wyhash.init(0);
    for (session.target.threadSlice()) |entry| {
        hash.update(std.mem.asBytes(&entry.id));
        hash.update(std.mem.asBytes(&entry.tid));
        hash.update(std.mem.asBytes(&entry.state));
    }
    return hash.final();
}
fn overBudget(err: anyerror) bool {
    return err == error.BinarySnapshotLimit or err == error.SymbolSnapshotLimit;
}
fn moduleError(comptime language: Language, err: anyerror) anyerror {
    if (err == error.SymbolDiscoveryPending or err == error.SymbolDiscoveryCancelled or err == error.SymbolDiscoveryBudgetExceeded or err == error.RemoteCancelled or err == error.RemoteOutcomeUnknown) return err;
    return switch (language) {
        .python => if (overBudget(err)) error.PythonImageBudgetExceeded else error.PythonModuleIdentityUnavailable,
        .perl => if (overBudget(err)) error.PerlImageBudgetExceeded else error.PerlModuleIdentityUnavailable,
    };
}
fn unavailable(comptime language: Language) anyerror {
    return switch (language) {
        .python => error.PythonRuntimeUnavailable,
        .perl => error.PerlRuntimeUnavailable,
    };
}
pub const noFrame = @import("../language/binding_types.zig").noFrame;
fn ambiguous(comptime language: Language) anyerror {
    return switch (language) {
        .python => error.PythonRuntimeAmbiguous,
        .perl => error.PerlValueRuntimeAmbiguous,
    };
}
pub fn owns(session: *model.Session, module: *Module, frame: model.Frame) bool {
    // A loaded candidate's identity includes the mapped file and load bias.
    // Do not turn a return PC at a mapping boundary into another image.
    const owner = session.modules.cachedAt(frame.lookup_pc) catch return false;
    return owner.id == module.id and owner.bias == module.bias and owner.inode == module.inode and owner.device_major == module.device_major and owner.device_minor == module.device_minor;
}
fn witnessed(comptime language: Language, session: *model.Session, a: A, module: *Module, tid: i32, native: []const model.Frame, first: usize, budget: *Budget) !Witness {
    return switch (language) {
        .python => @import("../language/python.zig").runtimeWitness(&session.languageContext(), a, model.Session.languageModule(module), tid, native, first, budget),
        .perl => .{ .seen = try @import("../language/perl.zig").runtimeWitness(&session.languageContext(), model.Session.languageModule(module), native) },
    };
}
fn bind(session: *model.Session, module: *Module, identity: Identity) Binding {
    const snapshot = session.target.snapshot();
    return .{ .module = module, .identity = identity, .token = .{ .module_id = module.id, .generation = snapshot.generation, .epoch = snapshot.image_epoch, .maps = session.modules.maps_revision } };
}
pub fn discover(comptime language: Language, session: *model.Session) !void {
    _ = try session.language_bindings.prepare(session, language);
}
/// At most one native thread walk per call. The caller retries pending work.
pub fn process(comptime language: Language, session: *model.Session) !Binding {
    const state = &session.language_bindings;
    const scan = try state.prepare(session, language);
    const generation = state.key.?.generation;
    if (!scan.done) {
        const threads = session.target.threadSlice();
        while (scan.next < threads.len and threads[scan.next].state != .stopped) scan.next += 1;
        if (scan.next < threads.len) {
            const tid = threads[scan.next].tid;
            const native = try state.walk(session, tid);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var budget = Budget{};
            for (scan.modules[0..scan.count], 0..) |module, i| {
                if ((try witnessed(language, session, arena.allocator(), module, tid, native, 0, &budget)).seen) scan.witnessed[i] = true;
            }
            try session.target.expectGeneration(generation);
            scan.next += 1;
            // Further threads cannot change a witnessed sole candidate.
            var seen: usize = 0;
            for (scan.witnessed[0..scan.count]) |hit| seen += @intFromBool(hit);
            const settled = seen > 1 or (seen == 1 and scan.count == 1);
            if (!settled and scan.next < threads.len) return error.SymbolDiscoveryPending;
        }
        scan.done = true;
    }
    var chosen: ?*Module = null;
    for (scan.modules[0..scan.count], scan.witnessed[0..scan.count]) |module, seen| if (seen) {
        if (chosen != null) return ambiguous(language);
        chosen = module;
    };
    try session.target.expectGeneration(generation);
    if (chosen) |module| return bind(session, module, .witnessed);
    if (scan.count != 1) return ambiguous(language);
    return bind(session, scan.modules[0], .unwitnessed);
}
/// A direct stack request never borrows another thread's runtime witness.
pub fn thread(comptime language: Language, session: *model.Session, a: A, tid: i32, native: []const model.Frame, first: usize) !Binding {
    const state = &session.language_bindings;
    const scan = try state.prepare(session, language);
    const generation = state.key.?.generation;
    var chosen: ?Binding = null;
    var budget = Budget{};
    for (scan.modules[0..scan.count]) |module| {
        const proof = try witnessed(language, session, a, module, tid, native, first, &budget);
        if (!proof.seen) continue;
        if (chosen != null) return ambiguous(language);
        var found = bind(session, module, .witnessed);
        found.python_stack = proof.python_stack;
        chosen = found;
    }
    try session.target.expectGeneration(generation);
    var result = chosen orelse return noFrame(language);
    result.budget = budget;
    return result;
}
/// Resolve only the instance retained with the canonical language segment.
pub fn retained(session: *model.Session, token: Token) !*Module {
    const snapshot = session.target.snapshot();
    if (snapshot.state != .stopped or snapshot.generation != token.generation or snapshot.image_epoch != token.epoch or session.modules.maps_revision != token.maps) return error.StaleLanguageFrame;
    for (session.modules.loaded.items) |module| if (module.id == token.module_id) return module;
    return error.StaleLanguageFrame;
}
