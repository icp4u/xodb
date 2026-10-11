//! Immutable cached runtime-watch values and owner-only watch actions.
const std = @import("std");
const model = @import("session.zig");
const language = @import("language_view.zig");
const watches = @import("language_watches.zig");
pub const View = struct {
    session: u64 = 0,
    generation: u64 = 0,
    revision: u64 = 0,
    selected_language: @import("language_tabs.zig").Tab = .registers,
    entries: []const watches.Entry = &.{},
    diagnostic: ?[]const u8 = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
/// Owner only; list copies cached comparison results and never reads a target.
pub fn snapshot(session: *const model.Session, a: std.mem.Allocator) View {
    return .{ .session = session.id, .generation = session.target.snapshot().generation, .revision = session.language_watches.revision, .selected_language = session.language_tabs.selected, .entries = session.language_watches.list(a) catch |err| return .{ .session = session.id, .generation = session.target.snapshot().generation, .revision = session.language_watches.revision, .selected_language = session.language_tabs.selected, .diagnostic = @errorName(err) } };
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn refresh(self: *Capture, session: *const model.Session) void {
        if (self.value.diagnostic == null and self.value.session == session.id and self.value.generation == session.target.snapshot().generation and self.value.revision == session.language_watches.revision and self.value.selected_language == session.language_tabs.selected) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = snapshot(session, self.arena.allocator());
    }
};
pub const Action = union(enum) {
    add: struct { selected: language.SelectedKey, metadata: u64, expression: ?[]const u8 = null, row: ?usize = null },
    remove: u64,
};
/// Owner only. Queue validation supplies actor authority and process stamp;
/// named-row creation additionally requires its exact logical selection.
pub fn apply(session: *model.Session, actor: model.Actor, action: Action) !?u64 {
    switch (action) {
        .add => |request| {
            const state = language.header(session);
            const selected = state.selectedKey() orelse return error.SelectLanguageFrame;
            if (!std.meta.eql(selected, request.selected) or state.metadata != request.metadata) return error.StaleLanguageFrame;
            const id = try session.language_watches.add(session, selected.language, selected.tid, selected.segment, selected.frame, request.expression, request.row);
            session.record(actor, "add_language_watch");
            return id;
        },
        .remove => |id| {
            try session.language_watches.remove(id);
            session.record(actor, "remove_language_watch");
            return null;
        },
    }
}

test "runtime watch publication survives cache removal and frontend actions stay local" {
    const c = @import("../c.zig").api;
    const boundary = @import("remote_owner.zig");
    var session = model.Session.init();
    defer session.deinit();
    session.language_tabs.selected = .lua;
    // Cached comparisons require a confirmed, nonzero generation. Advancing
    // this owned empty native target needs no inferior or transport operation.
    try session.target.invalidate();
    session.language_watches.core = c.xlw_create() orelse return error.OutOfMemory;
    var scope = std.mem.zeroes(c.struct_xlw_scope);
    scope.language = c.XLW_LUA;
    scope.session = session.id;
    scope.thread = 7;
    scope.runtime[0] = 11;
    scope.frame[0] = 13;
    scope.frame[1] = 17;
    var id: u64 = 0;
    try std.testing.expectEqual(@as(c.enum_xlw_result, c.XLW_OK), c.xlw_add(session.language_watches.core, &scope, "value", &id));
    var bytes = [_]u8{ 1, 2, 3 };
    const sample = c.struct_xlw_sample{ .kind = 1, .bytes = &bytes, .size = bytes.len, .type = "string", .display = "retained" };
    const generation = session.target.snapshot().generation;
    try std.testing.expectEqual(@as(c.enum_xlw_result, c.XLW_OK), c.xlw_feed(session.language_watches.core, id, generation, &scope, c.XLW_COMPLETE, &sample, null));
    bytes[0] = 4;
    try session.target.invalidate();
    try std.testing.expectEqual(@as(c.enum_xlw_result, c.XLW_OK), c.xlw_feed(session.language_watches.core, id, session.target.snapshot().generation, &scope, c.XLW_COMPLETE, &sample, null));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var prepared = snapshot(&session, arena.allocator());
    const publication = boundary.Publication.create(std.testing.allocator, .{ .stamp = @import("remote_dispatch.zig").stamp(1, &session), .revision = 1, .taken_ns = 1, .status = .ready, .runtime_watches = prepared }) catch |err| {
        arena.deinit();
        return err;
    };
    defer publication.destroy();
    arena.deinit();
    prepared = undefined;
    @memset(&bytes, 9);
    const view = publication.value.runtime_watches.?;
    var panel: @import("../ui/language_watches.zig").Panel = .{ .selected = id };
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    try std.testing.expect(panel.keyView(view, 27) == .local);
    const action = panel.keyView(view, 111);
    try std.testing.expectEqual(id, action.remove);
    try std.testing.expectEqual(@as(usize, 1), c.xlw_count(session.language_watches.core));
    try session.language_watches.remove(id);
    try std.testing.expectEqual(@as(usize, 0), c.xlw_count(session.language_watches.core));
    try std.testing.expectEqualStrings("value", view.entries[0].expression);
    try std.testing.expectEqualStrings("retained", view.entries[0].current.?.display);
    try std.testing.expect(view.entries[0].comparison == .same_slot_different);
    try std.testing.expect(std.mem.indexOf(u8, view.entries[0].identity, "unproved") != null);
}

test "runtime watch creation refuses obsolete logical metadata before reading" {
    var session = model.Session.init();
    defer session.deinit();
    session.language_tabs.selected = .lua;
    session.language_tabs.logical_selection = .{ .generation = session.target.snapshot().generation, .tid = 42, .language = .lua, .segment = 0, .frame = 1, .native_anchor = null, .native_pc = null, .anchor_basis = .unproved };
    const state = language.header(&session);
    const request = Action{ .add = .{ .selected = state.selectedKey().?, .metadata = state.metadata, .expression = "value" } };
    session.metadata.revision += 1;
    try std.testing.expectError(error.StaleLanguageFrame, apply(&session, .human, request));
    try std.testing.expect(session.language_watches.core == null);
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
}
