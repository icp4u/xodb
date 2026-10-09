//! Per-process presentation state. Reader evidence stays tied to its stop;
//! selecting a tab never modifies the inferior or its generation.
const std = @import("std");
const Session = @import("session.zig").Session;
const Modules = @import("modules.zig").Modules;
const rt = @import("../target/runtime.zig").c;
const Text = @import("probes.zig").Text;
const selection = @import("language_selection.zig");
pub const Tab = enum { registers, native, python, perl, lua, javascript, ruby, go };
pub const order = [_]Tab{ .registers, .native, .python, .perl, .lua, .javascript, .ruby, .go };
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
    };
}
pub const Description = struct { version: []const u8, build_id: []const u8, basis: []const u8 };
const Entry = struct {
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
    selected: Tab = .native,
    native_selection: ?selection.Native = null,
    logical_selection: ?selection.Logical = null,
    offers: selection.Offers = .{},
    cache: selection.Cache = .{},
    revision: u64 = 0,
    epoch: u64 = std.math.maxInt(u64),
    generation: u64 = std.math.maxInt(u64),
    entries: [6]Entry = @splat(.{}),
    next: usize = 0,
    metadata_revision: u64 = 0,
    pub fn deinit(self: *State) void {
        self.cache.deinit();
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
        return index < 2 or self.entries[index - 2].present;
    }
    pub fn select(self: *State, tab: Tab) !void {
        if (!self.visible(tab)) return error.LanguageTabUnavailable;
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
        if (!self.enabled or session.offline or session.imported != null) return;
        const snapshot = session.target.snapshot();
        self.syncSelection(snapshot.generation);
        if (self.epoch != snapshot.image_epoch) {
            self.entries = @splat(.{});
            self.epoch = snapshot.image_epoch;
            self.generation = std.math.maxInt(u64);
            self.revision +%= 1;
        }
        if (snapshot.state != .stopped or session.persistent.resolving or session.pending_continue != null) return;
        if (self.generation != snapshot.generation) {
            self.generation = snapshot.generation;
            self.next = 0;
            for (&self.entries) |*entry| {
                entry.checked = false;
                entry.cursor = .{};
                entry.found = false;
                entry.reason = null;
            }
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
        if (self.next == self.entries.len) return;
        session.refreshMaps() catch |err| {
            self.finish(@errorName(err));
            return;
        };
        const entry = &self.entries[self.next];
        if (!entry.found) {
            const symbols = [_][]const u8{ "_PyRuntime", "Perl_runops_standard", "lua_ident", "_ZN2v88internal7Version15version_string_E", "ruby_version", "runtime.buildVersion" };
            var budget = std.mem.zeroInit(rt.struct_xrt_file_budget, .{
                .limit_bytes = 128 * 1024,
                .deadline_ns = @import("../target/linux.zig").now() + 25_000_000,
            });
            rt.xrt_target_file_budget(session.target.handle, &budget);
            const result = session.modules.automaticSymbolAddress(symbols[self.next], &entry.cursor);
            rt.xrt_target_file_budget(session.target.handle, null);
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
            0 => @import("../language/python.zig").describe(session, a),
            1 => @import("../language/perl.zig").describe(session, a),
            2 => @import("../language/lua.zig").describe(session, a),
            3 => @import("../language/javascript.zig").describe(session, a),
            4 => @import("../language/ruby.zig").describe(session, a),
            5 => @import("../language/go.zig").describe(session, a),
            else => unreachable,
        };
        const d = description catch |err| {
            if (pending(err)) {
                entry.reason = @errorName(err);
                return;
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
        entry.proof_generation = snapshot.generation;
        self.finish(null);
    }
    fn finish(self: *State, reason: ?[]const u8) void {
        self.entries[self.next].reason = reason;
        self.entries[self.next].checked = true;
        self.next += 1;
        if (self.next == self.entries.len and !self.visible(self.selected)) self.selected = .native;
        self.revision +%= 1;
    }
    pub fn jsonStringify(self: State, writer: anytype) !void {
        const Item = struct { tab: Tab, title: []const u8, visible: bool, status: []const u8, reason: ?[]const u8, version: ?[]const u8, build_id: ?[]const u8, basis: ?[]const u8, proof_generation: ?u64 };
        var items: [order.len]Item = undefined;
        for (order, 0..) |tab, i| {
            items[i] = .{ .tab = tab, .title = title(tab), .visible = self.visible(tab), .status = "ready", .reason = null, .version = null, .build_id = null, .basis = null, .proof_generation = null };
            if (i >= 2) {
                const entry = &self.entries[i - 2];
                items[i].status = if (!self.enabled) "not_requested" else if (!entry.checked) "pending" else if (entry.reason != null and std.mem.eql(u8, entry.reason.?, "RuntimeNotDetected")) "absent" else if (entry.reason != null) "unavailable" else "ready";
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
fn pending(err: anyerror) bool {
    return err == error.SymbolDiscoveryPending or err == error.SymbolDiscoveryBudgetExceeded or
        err == error.DebugMetadataPending or err == error.JavaScriptMetadataPending or err == error.JavaScriptDwarfPending;
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
