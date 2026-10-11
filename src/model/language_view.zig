//! Owner-side language pane preparation. Editors, scrolling, hit testing and
//! rendering consume these const values without borrowing a live Session.
const std = @import("std");
const Session = @import("session.zig").Session;
const linux = @import("../target/linux.zig");
const tabs = @import("language_tabs.zig");
const selection = @import("language_selection.zig");
const named = @import("language_locals.zig");
pub const Row = struct { following: usize = 0, name: []const u8, location: []const u8, reason: ?[]const u8, segment: usize, frame: ?usize };
pub const SelectedKey = struct { session: u64 = 0, generation: u64, tid: i32, language: tabs.Tab, segment: usize, frame: usize };
pub const Key = struct { session: u64, generation: u64, revision: u64, metadata: u64, tid: i32, frame: usize, tab: tabs.Tab };
pub const Entry = struct {
    present: bool = false,
    checked: bool = false,
    found: bool = false,
    version: []const u8 = "",
    basis: []const u8 = "",
    reason: ?[]const u8 = null,
    proof_generation: ?u64 = null,
};
pub const Header = struct {
    session: u64,
    generation: u64,
    metadata: u64,
    revision: u64,
    state: linux.State,
    selected: tabs.Tab,
    native_selection: ?selection.Native,
    logical_selection: ?selection.Logical,
    entries: [tabs.order.len - 2]Entry = @splat(.{}),
    offered: [tabs.order.len]bool = @splat(false),
    pub fn visible(self: Header, tab: tabs.Tab) bool {
        const index = @intFromEnum(tab);
        return index < 2 or self.entries[index - 2].present;
    }
    pub fn selectedKey(self: Header) ?SelectedKey {
        const row = self.logical_selection orelse return null;
        if (row.generation != self.generation or row.language != self.selected) return null;
        return .{ .session = self.session, .generation = row.generation, .tid = row.tid, .language = row.language, .segment = row.segment, .frame = row.frame };
    }
    pub fn key(self: Header, tid: i32, frame: usize) Key {
        return .{ .session = self.session, .generation = self.generation, .revision = self.revision, .metadata = self.metadata, .tid = tid, .frame = frame, .tab = self.selected };
    }
};
/// Owner-only borrowed projection. Text slices reference Session storage until
/// the publication copies them; the caches/cursors themselves never escape.
pub fn header(session: *const Session) Header {
    const state = &session.language_tabs;
    const snapshot = session.target.snapshot();
    var result = Header{ .session = session.id, .generation = snapshot.generation, .metadata = session.metadata.revision, .revision = state.revision, .state = snapshot.state, .selected = state.selected, .native_selection = state.native_selection, .logical_selection = state.logical_selection };
    for (&state.entries, &result.entries) |*entry, *out| out.* = .{ .present = entry.present, .checked = entry.checked, .found = entry.found, .version = entry.version.slice(), .basis = entry.basis.slice(), .reason = entry.reason, .proof_generation = entry.proof_generation };
    for (state.offers.items[0..state.offers.count]) |offer| result.offered[@intFromEnum(offer.language)] = true;
    return result;
}
pub const Request = struct {
    tid: i32,
    frame: usize,
    selected: ?SelectedKey,
    binding_start: usize = 0,
    expression: []const u8 = "",
};
pub const Action = union(enum) {
    tab: tabs.Tab,
    native: struct { tid: i32, frame: usize },
    logical: struct { key: Key, segment: usize, frame: usize },
};
/// Owner only. Presentation selection performs no inferior mutation; logical
/// indices still require the exact metadata/selection context that showed them.
pub fn apply(session: *Session, action: Action) !void {
    switch (action) {
        .tab => |tab| try session.language_tabs.select(tab),
        .native => |row| try selection.selectNative(session, row.tid, row.frame),
        .logical => |row| {
            const current = header(session);
            if (row.key.session != current.session or row.key.generation != current.generation or row.key.metadata != current.metadata or row.key.tab != current.selected) return error.StaleLanguageView;
            try selection.selectLogical(session, row.key.tid, row.key.tab, row.segment, row.frame);
        },
    }
}
pub const Presentation = struct {
    header: Header,
    key: Key,
    selected: ?SelectedKey = null,
    rows: []const Row = &.{},
    stack_basis: ?[]const u8 = null,
    message: []const u8 = "No stopped thread",
    bindings: ?named.Result = null,
    bindings_reason: []const u8 = "Select a logical frame for named locals",
    binding_start: usize = 0,
    expression: []const u8 = "",
    expression_result: ?named.Result = null,
    expression_reason: ?[]const u8 = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(Presentation);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: Presentation = undefined,
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn refresh(self: *Capture, session: *Session, request: Request) void {
        _ = self.arena.reset(.retain_capacity);
        const state = header(session);
        self.value = .{ .header = state, .key = state.key(request.tid, request.frame), .selected = state.selectedKey() };
        const selected = self.value.selected;
        const same = selected != null and request.selected != null and std.meta.eql(selected.?, request.selected.?);
        if (same) {
            self.value.binding_start = request.binding_start;
            if (request.expression.len > 128) {
                self.value.expression_reason = "InvalidArguments";
            } else self.value.expression = self.arena.allocator().dupe(u8, request.expression) catch {
                self.value.expression_reason = "OutOfMemory";
                return;
            };
        }
        if (state.state != .stopped or request.tid == 0 or @intFromEnum(state.selected) < 2) return;
        const tid = request.tid;
        const tab = state.selected;
        const a = self.arena.allocator();
        switch (tab) {
            .python => self.collect(selection.cachedRead(.python, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .perl => self.collect(selection.cachedRead(.perl, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .lua => self.collect(selection.cachedRead(.lua, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .ruby => self.collect(selection.cachedRead(.ruby, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .javascript => self.collect(selection.cachedRead(.javascript, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .elisp => self.collect(selection.cachedRead(.elisp, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .go => self.collect(selection.cachedRead(.go, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            .gdscript => self.collect(selection.cachedRead(.gdscript, session, tid) catch |err| {
                self.value.message = @errorName(err);
                return;
            }) catch {
                self.value.message = "OutOfMemory";
            },
            else => unreachable,
        }
        if (selected) |row| {
            self.value.bindings = named.read(session, a, row.language, row.tid, row.segment, row.frame, self.value.binding_start, 32) catch |err| result: {
                self.value.bindings_reason = @errorName(err);
                break :result null;
            };
            if (self.value.expression.len != 0) self.value.expression_result = named.evaluate(session, a, row.language, row.tid, row.segment, row.frame, self.value.expression) catch |err| result: {
                self.value.expression_reason = @errorName(err);
                break :result null;
            };
        }
    }
    /// A project path (res://...) is shown whole when it is short, and by
    /// its end otherwise: the line number after it must stay visible.
    fn shownPath(a: std.mem.Allocator, stack: anytype, file: []const u8) ![]const u8 {
        if (!@hasField(@TypeOf(stack), "level_per_native_frame")) return std.fs.path.basename(file);
        const keep = 18;
        if (file.len <= keep) return file;
        var start = file.len - (keep - 3);
        while (start < file.len and file[start] & 0xc0 == 0x80) start += 1; // not inside a UTF-8 sequence
        return std.fmt.allocPrint(a, "...{s}", .{file[start..]});
    }
    fn collect(self: *Capture, stack: anytype) !void {
        const a = self.arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        self.value.message = "Segment anchor; frame pairing unproved";
        var count: usize = 0;
        for (stack.segments, 0..) |segment, segment_index| {
            if (rows.items.len >= 128) {
                self.value.message = "LanguageFrameLimit";
                break;
            }
            if (@hasField(@TypeOf(segment), "layout_source")) self.value.stack_basis = try a.dupe(u8, segment.layout_source);
            const anchor_name: ?[]const u8 = if (segment.anchor) |anchor| anchor.symbol else null;
            const segment_title: ?[]const u8 = if (@hasField(@TypeOf(segment), "title")) segment.title else anchor_name;
            try rows.append(a, .{ .name = if (segment_title) |name| try a.dupe(u8, name) else try std.fmt.allocPrint(a, "Segment {d}", .{segment_index}), .location = if (@hasField(@TypeOf(stack), "level_per_native_frame")) segment.state else if (segment.anchor) |anchor| try std.fmt.allocPrint(a, "segment {d} / native #{d}", .{ segment_index, anchor.frame }) else "native anchor unproved", .reason = if (segment.reason) |value| try a.dupe(u8, value) else null, .segment = segment_index, .frame = null });
            for (segment.frames, 0..) |frame, frame_index| {
                if (count == 64 or rows.items.len == 128) {
                    self.value.message = "LanguageFrameLimit";
                    break;
                }
                const paired = @hasField(@TypeOf(stack), "level_per_native_frame");
                if (@hasField(@TypeOf(frame), "native_binding")) self.value.message = if (paired) "One native frame each" else "C argument links; other links partial";
                const label = if (@hasField(@TypeOf(frame), "qualified_name"))
                    if (frame.qualified_name) |text| try a.dupe(u8, text) else try std.fmt.allocPrint(a, "{s} [owner unproved]", .{frame.name})
                else if (paired)
                    // The native frame that runs this level, beside its name.
                    if (frame.native_binding) |anchor| try std.fmt.allocPrint(a, "{s}  [native #{d}]", .{ frame.name, anchor.frame }) else try a.dupe(u8, frame.name)
                else
                    try a.dupe(u8, frame.name);
                const location = if (@hasField(@TypeOf(frame), "argument_count"))
                    if (frame.argument_count) |n| try std.fmt.allocPrint(a, "{s} / {d} args", .{ frame.kind, n }) else try std.fmt.allocPrint(a, "{s} / unevaluated", .{frame.kind})
                else if (frame.file) |file|
                    if (frame.line) |line| try std.fmt.allocPrint(a, "{s}:{d}", .{ try shownPath(a, stack, file), line }) else try a.dupe(u8, try shownPath(a, stack, file))
                else
                    "source position unproved";
                try rows.append(a, .{ .name = label, .location = location, .reason = if (frame.reason) |value| try a.dupe(u8, value) else null, .segment = segment_index, .frame = frame_index });
                count += 1;
                if (@hasField(@TypeOf(frame), "native_binding") and !paired) {
                    if (frame.native_binding) |anchor| {
                        if (rows.items.len < 128) {
                            rows.items[rows.items.len - 1].following = 1;
                            try rows.append(a, .{
                                .name = try std.fmt.allocPrint(a, "C: {s}", .{anchor.symbol}),
                                .location = try std.fmt.allocPrint(a, "arguments / native #{d}", .{anchor.frame}),
                                .reason = null,
                                .segment = segment_index,
                                .frame = null,
                            });
                        }
                    }
                }
                if (@hasField(@TypeOf(segment), "controls")) {
                    for (segment.controls) |control| {
                        if (control.frame == null or control.frame.? != frame_index or rows.items.len == 128) continue;
                        try rows.append(a, .{ .name = try a.dupe(u8, control.kind), .location = "control record; callback not evaluated", .reason = null, .segment = segment_index, .frame = null });
                    }
                }
            }
        }
        if (@hasField(@TypeOf(stack), "native_argument_diagnostics")) {
            for (stack.native_argument_diagnostics) |item| {
                if (rows.items.len == 128) break;
                try rows.append(a, .{ .name = try std.fmt.allocPrint(a, "native #{d}: no state argument", .{item.frame}), .location = try a.dupe(u8, item.reason), .reason = null, .segment = 0, .frame = null });
            }
        }
        self.value.rows = try rows.toOwnedSlice(a);
    }
};

test "language request text and paging cannot cross session identity" {
    var session = Session.init();
    defer session.deinit();
    session.id = 7;
    session.language_tabs.selected = .python;
    session.language_tabs.logical_selection = .{ .generation = session.target.snapshot().generation, .tid = 42, .language = .python, .segment = 0, .frame = 1, .native_anchor = null, .native_pc = null, .anchor_basis = .unproved };
    const selected = header(&session).selectedKey().?;
    var capture = Capture{};
    defer capture.deinit();
    var text = [_]u8{ 'n', 'a', 'm', 'e' };
    const request = Request{ .tid = 42, .frame = 0, .selected = selected, .binding_start = 17, .expression = &text };
    // The idle target avoids a reader call: this exercises request ownership
    // and context validation independently of a runtime's decoded bindings.
    capture.refresh(&session, request);
    @memset(&text, 'x');
    try std.testing.expectEqualStrings("name", capture.value.expression);
    try std.testing.expectEqual(@as(usize, 17), capture.value.binding_start);
    session.id = 8;
    capture.refresh(&session, request);
    try std.testing.expectEqual(@as(usize, 0), capture.value.expression.len);
    try std.testing.expectEqual(@as(usize, 0), capture.value.binding_start);
    try std.testing.expectEqual(@as(u64, 8), capture.value.selected.?.session);
}
