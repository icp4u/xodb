//! Per-process presentation state. Reader evidence stays tied to its stop;
//! selecting a tab never modifies the inferior or its generation.
const std = @import("std");
const Session = @import("session.zig").Session;
const Modules = @import("modules.zig").Modules;
const rt = @import("../target/runtime.zig").c;
const Text = @import("probes.zig").Text;
const selection = @import("language_selection.zig");
pub const Tab = @import("../language/types.zig").Tab;
pub const order = [_]Tab{ .registers, .native, .python, .perl, .lua, .javascript, .ruby, .go, .elisp, .gdscript };
pub fn title(tab: Tab) []const u8 {
    return switch (tab) {
        .registers => "Regs",
        .native => "C/C++",
        .python => "Python",
        .perl => "Perl",
        .lua => "Lua",
        .javascript => "JS",
        .ruby => "Ruby",
        .go => "Go",
        .elisp => "Elisp",
        .gdscript => "GDScript",
    };
}
pub const Description = @import("../language/types.zig").Description;
const Entry = struct {
    thread: ?i32 = null,
    identity: ?@import("../language/types.zig").Identity = null,
    present: bool = false,
    checked: bool = false,
    version: Text = .{},
    build_id: Text = .{},
    basis: Text = .{},
    reason: ?[]const u8 = null,
    proof_generation: ?u64 = null,
    cursor: Modules.SymbolCursor = .{},
    found: bool = false,
};
pub const State = struct {
    enabled: bool = false,
    live: bool = true,
    selected: Tab = .native,
    follow_tid: ?i32 = null,
    native_selection: ?selection.Native = null,
    logical_selection: ?selection.Logical = null,
    offers: selection.Offers = .{},
    cache: selection.Cache = .{},
    revision: u64 = 0,
    epoch: u64 = std.math.maxInt(u64),
    generation: u64 = std.math.maxInt(u64),
    entries: [8]Entry = @splat(.{}),
    next: usize = 0,
    metadata_revision: u64 = 0,
    binding_maps: u64 = 0,
    binding_metadata: u64 = 0,
    binding_threads: u64 = 0,
    /// Full images loaded when the last pass over the runtimes ended.
    loaded_images: usize = 0,
    pub fn deinit(self: *State) void {
        self.cache.deinit();
    }
    /// Presentation scope only. Do not retain another thread's runtime identity
    /// while an ambiguous process is being resolved for the new selection.
    pub fn followThread(self: *State, tid: i32) void {
        if (!self.live or tid <= 0 or self.follow_tid == tid) return;
        self.follow_tid = tid;
        for (self.entries[0..2]) |*entry| entry.* = .{ .present = entry.present, .found = entry.found };
        self.next = 0;
        self.revision +%= 1;
    }
    pub fn syncSelection(self: *State, generation: u64) void {
        if (self.cache.key) |key| if (key.generation != generation) {
            self.cache.clear();
        };
        var changed = false;
        if (self.native_selection) |value| if (value.generation != generation) {
            self.native_selection = null;
            changed = true;
        };
        if (self.logical_selection) |value| if (value.generation != generation) {
            self.logical_selection = null;
            changed = true;
        };
        if (changed) {
            self.offers = .{};
            self.revision +%= 1;
        }
    }
    pub fn visible(self: *const State, tab: Tab) bool {
        const index = @intFromEnum(tab);
        return index < 2 or (self.live and self.entries[index - 2].present);
    }
    pub const Status = enum { ready, not_requested, pending, absent, disabled, unwitnessed, unavailable };
    pub fn status(self: *const State, tab: Tab) Status {
        const index = @intFromEnum(tab);
        if (index < 2) return .ready;
        if (!self.live) return .unavailable;
        if (!self.enabled) return .not_requested;
        const entry = &self.entries[index - 2];
        if (!entry.checked) return .pending;
        if (entry.reason) |reason| {
            if (std.mem.eql(u8, reason, "RuntimeNotDetected")) return .absent;
            if (std.mem.eql(u8, reason, "LanguageDisabled")) return .disabled;
        }
        if (entry.identity == .unwitnessed) return .unwitnessed;
        return if (entry.reason != null) .unavailable else .ready;
    }
    fn syncAvailability(self: *State, session: *const Session) void {
        const live = !session.offline and session.imported == null;
        if (self.live == live) return;
        self.live = live;
        self.entries = @splat(if (live) .{} else .{ .checked = true, .reason = "OfflineSession" });
        self.next = if (live) 0 else self.entries.len;
        self.epoch = std.math.maxInt(u64);
        self.generation = std.math.maxInt(u64);
        if (!self.visible(self.selected)) self.selected = .native;
        self.revision +%= 1;
    }
    pub fn request(self: *State, session: *const Session) void {
        self.enabled = true;
        self.syncAvailability(session);
    }
    pub fn select(self: *State, tab: Tab) !void {
        // A shown tab stays selectable while its runtime is rechecked; a
        // hidden one is pending until checked, then unavailable.
        if (!self.visible(tab)) {
            if (self.status(tab) == .pending) return error.LanguageTabPending;
            return error.LanguageTabUnavailable;
        }
        if (self.selected != tab) {
            self.selected = tab;
            if (self.logical_selection) |value| if (value.language != tab) {
                self.logical_selection = null;
            };
            self.revision +%= 1;
        }
    }
    pub fn cycle(self: *State) void {
        for (1..order.len + 1) |offset| {
            const tab = order[(@intFromEnum(self.selected) + offset) % order.len];
            if (self.visible(tab)) {
                self.select(tab) catch unreachable;
                return;
            }
        }
    }
    pub fn poll(self: *State, session: *Session) void {
        self.syncAvailability(session);
        if (!self.enabled or !self.live) return;
        const snapshot = session.target.snapshot();
        self.syncSelection(snapshot.generation);
        if (self.epoch != snapshot.image_epoch) {
            self.entries = @splat(.{});
            self.epoch = snapshot.image_epoch;
            self.generation = std.math.maxInt(u64);
            self.revision +%= 1;
        }
        if (snapshot.state != .stopped) {
            session.language_bindings.clear();
            if (self.entries[0].checked or self.entries[1].checked) {
                self.entries[0] = .{};
                self.entries[1] = .{};
                self.revision +%= 1;
            }
            return;
        }
        if (session.persistent.resolving or session.pending_continue != null) return;
        if (self.generation != snapshot.generation) {
            self.generation = snapshot.generation;
            self.next = 0;
            self.entries[0] = .{};
            self.entries[1] = .{};
            for (&self.entries) |*entry| {
                entry.checked = false;
                entry.cursor = .{};
                entry.found = false;
                entry.reason = null;
                entry.identity = null;
                entry.proof_generation = null;
            }
            self.revision +%= 1;
        }
        const binding_threads = @import("runtime_binding.zig").threadStamp(session);
        if (self.binding_maps != session.modules.maps_revision or self.binding_metadata != session.metadata.revision or self.binding_threads != binding_threads) {
            self.binding_maps = session.modules.maps_revision;
            self.binding_metadata = session.metadata.revision;
            self.binding_threads = binding_threads;
            self.entries[0] = .{};
            self.entries[1] = .{};
            self.next = 0;
            self.revision +%= 1;
        }
        // Consume a metadata change only once the pass is complete: a later
        // runtime's symbol scan may still be pending when JavaScript metadata
        // is cancelled or retried, and that change must not be lost.
        if (self.next == self.entries.len and self.metadata_revision != session.metadata.revision) {
            self.metadata_revision = session.metadata.revision;
            if (self.next == self.entries.len and self.entries[3].found) {
                self.next = 3;
                self.entries[3].checked = false;
                self.revision +%= 1;
            }
        }
        // A view refused for an image budget works once its image is loaded
        // for another reason, such as a stack frame in it. Look again then:
        // the tab must not say less than the view does.
        if (self.next == self.entries.len and self.loaded_images != session.modules.loaded.items.len) {
            self.loaded_images = session.modules.loaded.items.len;
            // The same for a runtime whose symbol tables were too large to
            // search without the image.
            for (&self.entries, 0..) |*entry, i| if (entry.reason) |why| if (std.mem.endsWith(u8, why, "ImageBudgetExceeded") or (!entry.found and std.mem.endsWith(u8, why, "SnapshotLimit"))) {
                self.next = i;
                entry.checked = false;
                self.revision +%= 1;
                break;
            };
        }
        if (self.next == self.entries.len) return;
        session.refreshMaps() catch |err| {
            self.finish(@errorName(err));
            return;
        };
        self.binding_maps = session.modules.maps_revision;
        const entry = &self.entries[self.next];
        // Off in the preferences: not searched for, and not offered.
        if (!session.languages.on(@enumFromInt(self.next))) {
            entry.* = .{};
            self.finish("LanguageDisabled");
            return;
        }
        if (self.next >= 2 and !entry.found) {
            const symbols = [_][]const u8{ "_PyRuntime", "Perl_runops_standard", "lua_ident", "_ZN2v88internal7Version15version_string_E", "ruby_version", "runtime.buildVersion", "emacs_version", @import("../language/gdscript.zig").singleton_symbol };
            var budget = std.mem.zeroInit(rt.struct_xrt_file_budget, .{
                .limit_bytes = 128 * 1024,
                .deadline_ns = @import("../target/linux.zig").now() + 25_000_000,
            });
            @import("../target/runtime.zig").check(rt.xrt_target_file_budget(session.target.handle, &budget)) catch |err| {
                self.finish(@errorName(err));
                return;
            };
            const result = session.modules.automaticSymbolAddress(symbols[self.next], &entry.cursor);
            _ = rt.xrt_target_file_budget(session.target.handle, null);
            _ = result catch |err| {
                if (pending(err)) {
                    entry.reason = @errorName(err);
                    return;
                }
                if (err == error.SymbolNotFound or err == error.BreakpointSymbolNotLoaded) {
                    entry.present = false;
                    entry.proof_generation = null;
                    self.finish("RuntimeNotDetected");
                    return;
                }
                self.finish(@errorName(err));
                return;
            };
            entry.found = true;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const description = switch (self.next) {
            0 => @import("../language/python.zig").describe(&session.languageContext(), a),
            1 => @import("../language/perl.zig").describe(&session.languageContext(), a),
            2 => @import("../language/lua.zig").describe(&session.languageContext(), a),
            3 => @import("../language/javascript.zig").describe(&session.languageContext(), a),
            4 => @import("../language/ruby.zig").describe(&session.languageContext(), a),
            5 => @import("../language/go.zig").describe(&session.languageContext(), a),
            6 => @import("../language/elisp.zig").describe(&session.languageContext(), a),
            7 => @import("../language/gdscript.zig").describe(&session.languageContext(), a),
            else => unreachable,
        };
        const scoped: anyerror!Description = description catch |err| blk: {
            if (err == error.PythonRuntimeAmbiguous or err == error.PerlValueRuntimeAmbiguous) {
                if (self.follow_tid) |tid| break :blk threadDescription(session, tid, self.next);
            }
            break :blk err;
        };
        const d = scoped catch |err| {
            if (pending(err)) {
                entry.reason = @errorName(err);
                return;
            }
            if (self.follow_tid != null and (err == error.PythonInterpreterFrameUnavailable or err == error.PerlInterpreterFrameUnavailable)) {
                entry.* = .{ .present = true, .found = true, .thread = self.follow_tid };
                self.finish(@errorName(err));
                return;
            }
            // No image defines the runtime anchor: an unexaminable mapping is
            // not evidence of this runtime. Direct requests keep the refusal.
            const no_candidate = (err == error.PythonModuleIdentityUnavailable or err == error.PerlModuleIdentityUnavailable) and session.language_bindings.vetoedWithoutCandidate(self.next);
            if (err == error.PythonRuntimeUnavailable or err == error.PerlRuntimeUnavailable or no_candidate) {
                entry.present = false;
                entry.proof_generation = null;
                entry.identity = null;
                self.finish("RuntimeNotDetected");
                return;
            }
            if (self.next < 2) {
                entry.found = true;
                entry.present = false;
                entry.proof_generation = null;
                entry.identity = null;
            }
            self.finish(@errorName(err));
            return;
        };
        const version = Text.init(d.version) catch {
            self.finish("LanguageDescriptionLimit");
            return;
        };
        const build_id = Text.init(d.build_id) catch {
            self.finish("LanguageDescriptionLimit");
            return;
        };
        const basis = Text.init(d.basis) catch {
            self.finish("LanguageDescriptionLimit");
            return;
        };
        entry.version = version;
        entry.build_id = build_id;
        entry.basis = basis;
        entry.present = true;
        entry.found = true;
        entry.identity = d.identity;
        entry.thread = d.thread;
        entry.proof_generation = if (d.identity == .unwitnessed) null else snapshot.generation;
        self.finish(if (d.identity == .unwitnessed) "RuntimeNotSeenExecuting" else null);
    }
    fn finish(self: *State, reason: ?[]const u8) void {
        self.entries[self.next].reason = reason;
        self.entries[self.next].checked = true;
        self.next += 1;
        if (self.next == self.entries.len and !self.visible(self.selected)) self.selected = .native;
        self.revision +%= 1;
    }
    pub fn jsonStringify(self: State, writer: anytype) !void {
        const Item = struct { thread: ?i32 = null, identity: ?@import("../language/types.zig").Identity = null, tab: Tab, title: []const u8, visible: bool, status: []const u8, reason: ?[]const u8, version: ?[]const u8, build_id: ?[]const u8, basis: ?[]const u8, proof_generation: ?u64 };
        var items: [order.len]Item = undefined;
        for (order, 0..) |tab, i| {
            items[i] = .{ .tab = tab, .title = title(tab), .visible = self.visible(tab), .status = @tagName(self.status(tab)), .reason = null, .version = null, .build_id = null, .basis = null, .proof_generation = null };
            if (i >= 2) {
                const entry = &self.entries[i - 2];
                items[i].identity = entry.identity;
                items[i].thread = entry.thread;
                items[i].reason = entry.reason;
                items[i].version = if (entry.present) entry.version.slice() else null;
                items[i].build_id = if (entry.present) entry.build_id.slice() else null;
                items[i].basis = if (entry.present) entry.basis.slice() else null;
                items[i].proof_generation = entry.proof_generation;
            }
        }
        try writer.write(.{ .native_selection = self.native_selection, .logical_selection = self.logical_selection, .offers = self.offers, .selected = self.selected, .revision = self.revision, .generation = if (self.generation == std.math.maxInt(u64)) null else @as(?u64, self.generation), .image_epoch = if (self.epoch == std.math.maxInt(u64)) null else @as(?u64, self.epoch), .complete = self.next == self.entries.len, .tabs = items });
    }
};
fn threadDescription(session: *Session, tid: i32, index: usize) !Description {
    inline for (.{ Tab.python, Tab.perl }, 0..) |language, i| if (index == i) {
        const stack = try selection.cachedRead(language, session, tid);
        if (stack.segments.len == 0) return @import("../language/binding_types.zig").noFrame(if (language == .python) .python else .perl);
        const runtime = stack.segments[0].runtime;
        return .{ .version = runtime.version, .build_id = runtime.build_id, .basis = "selected-thread interpreter frames; several runtime images loaded", .identity = stack.identity, .thread = tid };
    };
    return error.InvalidLanguage;
}
fn pending(err: anyerror) bool {
    return err == error.SymbolDiscoveryPending or err == error.SymbolDiscoveryBudgetExceeded or
        err == error.DebugMetadataPending or err == error.JavaScriptMetadataPending or err == error.JavaScriptDwarfPending;
}
test "thread scope invalidates identity without hiding an already selected tab" {
    var state = State{ .enabled = true, .selected = .python, .follow_tid = 10, .next = 8 };
    state.entries[0] = .{ .present = true, .checked = true, .found = true, .identity = .witnessed, .thread = 10, .proof_generation = 7 };
    state.followThread(20);
    try std.testing.expect(state.visible(.python) and state.selected == .python and state.next == 0);
    try std.testing.expect(state.entries[0].identity == null and state.entries[0].thread == null and state.entries[0].proof_generation == null and !state.entries[0].checked);
    const revision = state.revision;
    state.followThread(20);
    try std.testing.expectEqual(revision, state.revision);
}

test "tab selection belongs to each process and cycles only detected runtimes" {
    var first = State{};
    var second = State{};
    first.cycle();
    try std.testing.expectEqual(Tab.registers, first.selected);
    first.cycle();
    try std.testing.expectEqual(Tab.native, first.selected);
    try std.testing.expectError(error.LanguageTabUnavailable, first.select(.lua));
    first.entries[2].present = true;
    first.cycle();
    try std.testing.expectEqual(Tab.lua, first.selected);
    try std.testing.expectEqual(Tab.native, second.selected);
    try second.select(.registers);
    try std.testing.expectEqual(Tab.lua, first.selected);
}

test "unchecked tab selection is pending, not absent, without changing selection" {
    var state = State{ .enabled = true };
    const revision = state.revision;
    try std.testing.expectError(error.LanguageTabPending, state.select(.ruby));
    try std.testing.expectEqual(Tab.native, state.selected);
    try std.testing.expectEqual(revision, state.revision);
    const ruby = &state.entries[@intFromEnum(Tab.ruby) - 2];
    ruby.present = true; // A previously detected runtime is being rechecked.
    state.cycle();
    try std.testing.expectEqual(Tab.ruby, state.selected);
    try state.select(.native);
    ruby.checked = true;
    ruby.present = false;
    try std.testing.expectError(error.LanguageTabUnavailable, state.select(.ruby));
    ruby.present = true;
    try state.select(.ruby);
    try std.testing.expectEqual(Tab.ruby, state.selected);
}

test "offline and imported tabs are unavailable without discovery or revision churn" {
    for ([_]Session{ .{ .id = 1, .offline = true }, .{ .id = 2, .imported = .{} } }) |initial| {
        var session = initial;
        var state = State{ .selected = .ruby };
        state.entries[@intFromEnum(Tab.ruby) - 2].present = true;
        state.poll(&session); // Must not touch an uninitialized live target.
        state.request(&session);
        try std.testing.expectEqual(Tab.native, state.selected);
        try std.testing.expectEqual(state.entries.len, state.next);
        const revision = state.revision;
        state.followThread(123);
        state.poll(&session);
        state.request(&session);
        try std.testing.expectEqual(revision, state.revision);
        const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, state, .{});
        defer std.testing.allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
        defer parsed.deinit();
        for (order, 0..) |tab, i| {
            const item = parsed.value.object.get("tabs").?.array.items[i].object;
            try std.testing.expectEqualStrings(@tagName(state.status(tab)), item.get("status").?.string);
            if (i < 2) {
                try std.testing.expectEqual(State.Status.ready, state.status(tab));
                try state.select(tab);
            } else {
                try std.testing.expectEqual(State.Status.unavailable, state.status(tab));
                try std.testing.expect(!state.visible(tab));
                try std.testing.expectEqualStrings("OfflineSession", item.get("reason").?.string);
                try std.testing.expectError(error.LanguageTabUnavailable, state.select(tab));
            }
        }
        session.offline = false;
        session.imported = null;
        state.request(&session);
        try std.testing.expectEqual(@as(usize, 0), state.next);
        try std.testing.expectEqual(State.Status.pending, state.status(.ruby));
        try std.testing.expectError(error.LanguageTabPending, state.select(.ruby));
    }
}

/// The reported status is the one selection uses, for every state.
fn expectStatus(state: *const State, tab: Tab, want: State.Status) !void {
    try std.testing.expectEqual(want, state.status(tab));
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, state.*, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    const item = parsed.value.object.get("tabs").?.array.items[@intFromEnum(tab)].object;
    try std.testing.expectEqualStrings(@tagName(want), item.get("status").?.string);
    if (!state.visible(tab)) {
        var copy = state.*;
        try std.testing.expectError(if (want == .pending) error.LanguageTabPending else error.LanguageTabUnavailable, copy.select(tab));
    }
}
test "tab status keeps shown rechecks selectable and preserves diagnostic states" {
    var state = State{};
    try expectStatus(&state, .ruby, .not_requested);
    state.enabled = true;
    try expectStatus(&state, .ruby, .pending);
    const entry = &state.entries[@intFromEnum(Tab.ruby) - 2];
    entry.present = true;
    try state.select(.ruby);
    try expectStatus(&state, .ruby, .pending);
    entry.checked = true;
    try expectStatus(&state, .ruby, .ready);
    entry.present = false; // Absent and disabled runtimes are hidden.
    entry.reason = "RuntimeNotDetected";
    try expectStatus(&state, .ruby, .absent);
    entry.reason = "LanguageDisabled";
    try expectStatus(&state, .ruby, .disabled);
    entry.present = true;
    entry.reason = "RuntimeNotSeenExecuting";
    entry.identity = .unwitnessed;
    try expectStatus(&state, .ruby, .unwitnessed);
    entry.identity = null;
    entry.reason = "DebugMetadataCancelled";
    try expectStatus(&state, .ruby, .unavailable);
}
