//! Owner-prepared breakpoint policy rows and edits bound to displayed evidence.
const std = @import("std");
const model = @import("session.zig");
const policy = @import("probes.zig");
pub const Key = struct { session: u64, image: u64, generation: u64, sequence: u64, logs: u64, dropped: u64, persistent: u64 };
pub fn sessionKey(session: *const model.Session) Key {
    const state = session.target.snapshot();
    return .{ .session = session.id, .image = state.image_epoch, .generation = state.generation, .sequence = state.sequence, .logs = session.probes.log_sequence, .dropped = session.probes.dropped_logs, .persistent = session.persistent.display_revision };
}
pub const Rule = struct {
    options: policy.Options,
    matched_hits: u64,
    thread_label: []const u8,
    last_error: ?[]const u8,
};
pub const Row = struct {
    probe: @import("../target/breakpoints.zig").Breakpoint,
    rule: ?Rule,
    pending_text: []const u8,
    diagnostic: ?[]const u8,
};
pub const View = struct {
    key: ?Key = null,
    rows: []const Row = &.{},
    last_log: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = .{};
    }
    pub fn changed(self: *const Capture, session: *const model.Session) bool {
        return self.value.key == null or !std.meta.eql(self.value.key.?, sessionKey(session));
    }
    pub fn refresh(self: *Capture, session: *model.Session, enabled: bool) void {
        if (!enabled) {
            self.clear();
            return;
        }
        if (!self.changed(session)) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .key = sessionKey(session) };
        self.prepare(session) catch |err| {
            self.value.diagnostic = @errorName(err);
        };
    }
    fn prepare(self: *Capture, session: *model.Session) !void {
        const a = self.arena.allocator();
        const probes = session.target.breakpointSlice();
        const rows = try a.alloc(Row, probes.len);
        for (probes, rows) |probe, *row| {
            row.* = .{ .probe = probe, .rule = null, .pending_text = "", .diagnostic = null };
            if (session.probes.rule(probe.id)) |rule| {
                var thread_label: []const u8 = "all";
                if (rule.thread_id) |id| {
                    thread_label = "ended";
                    for (session.target.threadSlice()) |thread| if (thread.id == id) {
                        thread_label = try std.fmt.allocPrint(a, "{d}", .{thread.tid});
                        break;
                    };
                }
                row.rule = .{
                    .options = .{ .condition = try a.dupe(u8, rule.condition.slice()), .log_expression = try a.dupe(u8, rule.log_expression.slice()), .thread_id = rule.thread_id, .ignore_count = rule.ignore_remaining, .mode = rule.mode },
                    .matched_hits = rule.matched_hits,
                    .thread_label = thread_label,
                    .last_error = if (rule.last_error) |text| try a.dupe(u8, text) else null,
                };
            }
            if (session.persistent.entry(probe.id)) |entry| {
                row.pending_text = try a.dupe(u8, if (entry.symbol.len > 0) entry.symbol.slice() else entry.path);
                row.diagnostic = if (entry.diagnostic) |text| try a.dupe(u8, text) else null;
            } else if (row.rule) |rule| row.pending_text = rule.options.condition;
        }
        self.value.rows = rows;
        if (session.probes.log_count > 0) {
            const log = &session.probes.logs[session.probes.log_count - 1];
            self.value.last_log = try std.fmt.allocPrint(a, "Log #{d} tid {d}: {s} = {s}  (dropped {d})", .{ log.sequence, log.tid, log.expression.slice(), log.display.slice(), session.probes.dropped_logs });
        }
    }
};
pub const TextEdit = struct { id: u64, text: []const u8 };
pub const Edit = union(enum) {
    symbol: []const u8,
    remove: u64,
    toggle: u64,
    stop: u64,
    condition: TextEdit,
    log: TextEdit,
    ignore: struct { id: u64, count: u64 },
    thread: struct { id: u64, tid: ?i32 },
};
pub const Request = struct { key: Key, edit: Edit };
pub const Outcome = enum { updated, removed, symbol_added };
pub fn apply(session: *model.Session, request: Request, actor: model.Actor) !Outcome {
    const current = sessionKey(session);
    if (request.key.session != current.session or request.key.image != current.image or request.key.generation != current.generation) return error.StaleSnapshot;
    if (request.edit == .symbol) {
        _ = try session.persistent.addSymbol(session, request.edit.symbol);
        session.record(actor, "set_breakpoint");
        return .symbol_added;
    }
    const id = switch (request.edit) {
        .symbol => unreachable,
        .remove, .toggle, .stop => |ident| ident,
        inline else => |edit| edit.id,
    };
    const probe = @import("persistent.zig").Manager.probe(session, id) orelse return error.UnknownBreakpoint;
    if (probe.internal) return error.InternalBreakpoint;
    if (request.edit == .remove) {
        try session.target.removeBreakpoint(id);
        session.record(actor, "remove_breakpoint");
        return .removed;
    }
    var enabled = probe.enabled;
    var options: policy.Options = if (session.probes.rule(id)) |rule| .{ .condition = rule.condition.slice(), .log_expression = rule.log_expression.slice(), .thread_id = rule.thread_id, .ignore_count = rule.ignore_remaining, .mode = rule.mode } else .{};
    switch (request.edit) {
        .symbol, .remove => unreachable,
        .toggle => enabled = !enabled,
        .stop => options.mode = .stop,
        .condition => |edit| options.condition = edit.text,
        .log => |edit| {
            options.log_expression = edit.text;
            options.mode = .log;
        },
        .ignore => |edit| options.ignore_count = edit.count,
        .thread => |edit| {
            options.thread_id = null;
            if (edit.tid) |tid| {
                for (session.target.threadSlice()) |thread| {
                    if (thread.tid == tid and thread.state != .exited) {
                        options.thread_id = thread.id;
                        break;
                    }
                } else return error.ThreadUnavailable;
            }
        },
    }
    try session.probes.configure(&session.target, id, options, enabled);
    session.record(actor, "configure_breakpoint");
    return .updated;
}

test "breakpoint edits reject a changed session or stop before mutation" {
    var session = model.Session.init();
    defer session.deinit();
    var identity = sessionKey(&session);
    identity.session += 1;
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    try std.testing.expectError(error.StaleSnapshot, apply(&session, .{ .key = identity, .edit = .{ .symbol = "fixture_hit" } }, .human));
    identity = sessionKey(&session);
    identity.generation += 1;
    try std.testing.expectError(error.StaleSnapshot, apply(&session, .{ .key = identity, .edit = .{ .remove = 1 } }, .human));
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
}

test "breakpoint publication owns strings and edits retain their opening context" {
    const boundary = @import("remote_owner.zig");
    var session = model.Session.init();
    defer session.deinit();
    var capture: Capture = .{ .arena = .init(std.testing.allocator) };
    defer capture.deinit();
    const a = capture.arena.allocator();
    const rows = try a.alloc(Row, 2);
    for (rows, 0..) |*row, i| row.* = .{
        .probe = .{ .id = i + 1, .address = 0x1000 + i, .original = @splat(0) },
        .rule = .{ .options = .{ .condition = try a.dupe(u8, "counter > 0"), .log_expression = try a.dupe(u8, "counter") }, .matched_hits = 2, .thread_label = try a.dupe(u8, "all"), .last_error = null },
        .pending_text = try a.dupe(u8, "fixture_hit"),
        .diagnostic = try a.dupe(u8, "SymbolDiscoveryPending"),
    };
    capture.value = .{ .key = sessionKey(&session), .rows = rows, .last_log = try a.dupe(u8, "counter = 3") };
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = @import("remote_dispatch.zig").stamp(1, &session),
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .probes = capture.value,
    });
    defer publication.destroy();
    capture.clear();
    const view = publication.value.probes.?;
    try std.testing.expectEqualStrings("counter > 0", view.rows[0].rule.?.options.condition);
    try std.testing.expectEqualStrings("SymbolDiscoveryPending", view.rows[0].diagnostic.?);
    try std.testing.expectEqualStrings("counter = 3", view.last_log.?);
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    var panel: @import("../ui/probes.zig").Panel = .{ .open = true };
    try std.testing.expect(panel.keyView(.{ .kind = .press, .shortcut = 'n' }) == .local);
    try std.testing.expect(!panel.editor.open);
    panel.present(view);
    try std.testing.expect(panel.keyView(.{ .kind = .press, .shortcut = 'c' }) == .local);
    try std.testing.expectEqualStrings("counter > 0", panel.editor.text.bytes[0..panel.editor.text.len]);
    var reordered = [_]Row{ view.rows[1], view.rows[0] };
    var next = view;
    next.rows = &reordered;
    next.key.?.generation += 1;
    panel.present(next);
    try std.testing.expectEqual(@as(usize, 1), panel.selected);
    const pending = panel.keyView(.{ .kind = .press, .shortcut = 0xff0d }).owner;
    try std.testing.expectEqual(@as(u64, 1), pending.edit.condition.id);
    try std.testing.expectEqual(view.key.?.generation, pending.key.generation);
    try std.testing.expect(pending.key.generation != next.key.?.generation);
    panel.editor.open = false;
    reordered[1].probe.internal = true;
    panel.present(next);
    try std.testing.expect(panel.keyView(.{ .kind = .press, .shortcut = 0xffff }) == .local);
    try std.testing.expectEqualStrings("Internal loader breakpoint (read-only)", panel.message);
}
