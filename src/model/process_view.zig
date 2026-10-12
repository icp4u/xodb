//! Immutable process-family rows and commands bound to the displayed identity.
const std = @import("std");
const model = @import("session.zig");
const Tree = @import("process_tree.zig").Tree;
const boundary = @import("remote_owner.zig");
pub const Row = struct {
    stamp: boundary.Stamp,
    parent: ?u64,
    state: @import("../target/linux.zig").State,
    following: bool,
    shared_vm: bool,
    held: usize,
    released: usize = 0,
    diagnostic: ?[]const u8,
};
pub const View = struct {
    revision: u64 = 0,
    selected: u64 = 0,
    limit: usize = 0,
    rows: []const Row = &.{},
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    connection: u64 = 0,
    root_session: u64 = 0,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = .{};
    }
    pub fn refresh(self: *Capture, tree: *Tree, connection: u64, enabled: bool) !void {
        if (!enabled) {
            self.clear();
            return;
        }
        if (self.value.revision == tree.revision and self.connection == connection and self.root_session == tree.root().id) return;
        self.clear();
        self.connection = connection;
        self.root_session = tree.root().id;
        const rows = try self.arena.allocator().alloc(Row, tree.count);
        for (tree.entries[0..tree.count], rows) |entry, *row| {
            const target = &entry.session.target;
            const state = target.snapshot();
            const diagnostic = entry.admission_error orelse entry.session.step_diagnostic;
            row.* = .{
                .stamp = @import("remote_dispatch.zig").stamp(connection, entry.session),
                .parent = entry.parent,
                .state = state.state,
                .following = state.follow_processes,
                .shared_vm = target.sharedVm(),
                .held = state.birth_count,
                .released = entry.released,
                .diagnostic = if (diagnostic) |text| try self.arena.allocator().dupe(u8, text) else null,
            };
        }
        self.value = .{ .revision = tree.revision, .selected = tree.active().process_id, .limit = tree.limit, .rows = rows };
    }
};
pub const Operation = union(enum) { select, following: bool, retry, detach_family };
pub const Intent = struct { stamp: boundary.Stamp, operation: Operation };
pub fn apply(tree: *Tree, identity: boundary.Stamp, actor: model.Actor, operation: Operation) !void {
    const session = (try tree.find(identity.process)).session;
    const current = @import("remote_dispatch.zig").stamp(identity.connection, session);
    if (!identity.sameProcess(current)) return error.StaleProcess;
    if (identity.image_epoch != current.image_epoch or identity.generation != current.generation) return error.StaleSnapshot;
    switch (operation) {
        .select => try tree.select(session.process_id),
        .following => |enabled| try tree.setFollowing(session, enabled, null, actor),
        .retry => {
            tree.retryAdmissions();
            session.record(actor, "retry_process_admission");
        },
        .detach_family => try tree.detachFamily(session, actor),
    }
}

test "process commands cannot follow a row to another session incarnation" {
    const a = std.testing.allocator;
    const tree = try a.create(Tree);
    defer a.destroy(tree);
    tree.* = .{};
    var session = model.Session.init();
    defer session.deinit();
    tree.init(&session);
    const identity = @import("remote_dispatch.zig").stamp(1, &session);
    const revision = tree.revision;
    var stale = identity;
    stale.session += 1;
    try std.testing.expectError(error.StaleProcess, apply(tree, stale, .human, .retry));
    stale = identity;
    stale.generation += 1;
    try std.testing.expectError(error.StaleSnapshot, apply(tree, stale, .human, .retry));
    try std.testing.expectEqual(revision, tree.revision);
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
}

test "process publication retains diagnostic storage and frontend row identity" {
    const a = std.testing.allocator;
    const tree = try a.create(Tree);
    defer a.destroy(tree);
    tree.* = .{};
    var session = model.Session.init();
    defer session.deinit();
    tree.init(&session);
    var reason = "HeldChild".*;
    tree.entries[0].admission_error = &reason;
    var capture: Capture = .{ .arena = .init(a) };
    defer capture.deinit();
    try capture.refresh(tree, 7, true);
    const publication = try boundary.Publication.create(a, .{ .stamp = @import("remote_dispatch.zig").stamp(7, &session), .revision = 1, .taken_ns = 1, .status = .ready, .processes = capture.value });
    defer publication.destroy();
    capture.clear();
    @memset(&reason, 'x');
    const view = publication.value.processes.?;
    try std.testing.expectEqualStrings("HeldChild", view.rows[0].diagnostic.?);
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    var panel: @import("../ui/processes.zig").Panel = .{};
    panel.show(view);
    const selected = panel.keyView(.{ .kind = .press, .shortcut = 0xff0d }).owner;
    try std.testing.expect(std.meta.eql(view.rows[0].stamp, selected.stamp));
    try std.testing.expect(selected.operation == .select);
    try apply(tree, selected.stamp, .human, selected.operation);
    try std.testing.expectEqual(@as(usize, 0), tree.selected);
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
    try capture.refresh(tree, 7, false);
    try std.testing.expectEqual(@as(usize, 0), capture.value.rows.len);
}
