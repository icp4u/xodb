//! Breakpoint policy input and painting over immutable owner-prepared rows.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const prepared = @import("../model/probe_view.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
pub const Panel = struct {
    open: bool = false,
    view: prepared.View = .{},
    selected: usize = 0,
    selected_id: ?u64 = null,
    scroll: usize = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    editor: Editor = .{},
    editing: enum { condition, log, ignore, thread, symbol } = .condition,
    editing_id: u64 = 0,
    editing_key: ?prepared.Key = null,
    message: []const u8 = "Select a breakpoint; C condition, L logpoint, H ignore count, T thread",
    pub fn present(self: *Panel, view: prepared.View) void {
        const previous = self.view.key;
        self.view = view;
        if (view.key) |current| {
            if (previous) |before| if (before.session != current.session or before.image != current.image) {
                self.editor.open = false;
                self.editing_key = null;
                self.selected_id = null;
                self.selected = 0;
            };
        }
        self.selected = @min(self.selected, view.rows.len -| 1);
        if (self.selected_id) |id| for (view.rows, 0..) |row, i| if (row.probe.id == id) {
            self.selected = i;
            break;
        };
        self.rememberSelection();
    }
    fn rememberSelection(self: *Panel) void {
        self.selected_id = if (self.view.rows.len > 0) self.view.rows[self.selected].probe.id else null;
    }
    pub const KeyAction = union(enum) { ignored, local, owner: prepared.Request };
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        return switch (self.keyView(event)) {
            .ignored => false,
            .local => true,
            .owner => |request| done: {
                const result = prepared.apply(session, request, .human) catch |err| {
                    self.failed(err);
                    break :done true;
                };
                self.complete(result);
                break :done true;
            },
        };
    }
    /// Remote callers match the command sequence before applying completion.
    pub fn complete(self: *Panel, result: prepared.Outcome) void {
        self.editor.open = false;
        self.message = switch (result) {
            .updated => "Breakpoint updated",
            .removed => "Breakpoint removed",
            .symbol_added => "Symbol breakpoint added (pending when unloaded)",
        };
    }
    pub fn failed(self: *Panel, failure: anyerror) void {
        self.message = switch (failure) {
            error.UnknownBreakpoint => "Breakpoint no longer exists",
            error.InternalBreakpoint => "Internal loader breakpoint (read-only)",
            error.ThreadUnavailable => "Thread unavailable",
            else => @errorName(failure),
        };
        if (failure == error.UnknownBreakpoint) self.editor.open = false;
    }
    fn makeRequest(self: *Panel, edit: prepared.Edit, editing: bool) KeyAction {
        const identity = (if (editing) self.editing_key else self.view.key) orelse {
            self.message = "Breakpoint view pending";
            return .local;
        };
        return .{ .owner = .{ .key = identity, .edit = edit } };
    }
    pub fn keyView(self: *Panel, event: keys.Event) KeyAction {
        if (!self.open) return .ignored;
        if (event.kind != .press and event.kind != .repeat) return .local;
        if (self.editor.open) {
            if (event.shortcut == 0xff0d and self.editor.text.len == 0) return self.submit("");
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.message = "Edit cancelled",
                .submit => |value| return self.submit(value),
            } else return .ignored;
            return .local;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return .ignored;
        if (!event.plain()) return .local;
        const shortcut = event.shortcut;
        if (shortcut == keys.sym.escape or shortcut == 'b') {
            self.open = false;
            return .local;
        }
        if (shortcut == 'n') {
            if (self.view.key == null) {
                self.message = "Breakpoint view pending";
                return .local;
            }
            self.editing = .symbol;
            self.editing_key = self.view.key;
            self.editor.start();
            self.message = "Symbol name; resolves now or stays pending until its library loads";
            return .local;
        }
        const count = self.view.rows.len;
        if (count == 0) return .local;
        self.selected = @min(self.selected, count - 1);
        if (shortcut == keys.sym.up or shortcut == keys.sym.down) {
            if (shortcut == keys.sym.up) self.selected -|= 1 else self.selected = @min(count - 1, self.selected + 1);
            self.rememberSelection();
            return .local;
        }
        if (event.kind == .repeat) return .local;
        const item = self.view.rows[self.selected];
        const probe = item.probe;
        if (probe.internal) {
            self.message = "Internal loader breakpoint (read-only)";
            return .local;
        }
        if (shortcut == 0xffff or shortcut == 0xff08) return self.makeRequest(.{ .remove = probe.id }, false);
        if (shortcut == keys.sym.space) return self.makeRequest(.{ .toggle = probe.id }, false);
        if (shortcut == 'o') return self.makeRequest(.{ .stop = probe.id }, false);
        if (shortcut == 'c' or shortcut == 'l' or shortcut == 'h' or shortcut == 't') {
            self.editing = if (shortcut == 'c') .condition else if (shortcut == 'l') .log else if (shortcut == 'h') .ignore else .thread;
            self.editing_id = probe.id;
            self.editing_key = self.view.key;
            self.editor.start();
            const initial = if (item.rule) |rule| switch (self.editing) {
                .condition => rule.options.condition,
                .log => rule.options.log_expression,
                else => "",
            } else "";
            const n = @min(initial.len, self.editor.text.bytes.len);
            @memcpy(self.editor.text.bytes[0..n], initial[0..n]);
            self.editor.text.len = n;
            self.message = switch (self.editing) {
                .condition => "Condition expression (empty clears)",
                .log => "Log expression (empty records hits); O restores stopping",
                .ignore => "Number of matching-thread hits to ignore",
                .thread => "Thread TID (empty selects all threads)",
                .symbol => unreachable,
            };
        }
        return .local;
    }
    fn submit(self: *Panel, value: []const u8) KeyAction {
        const edit: prepared.Edit = switch (self.editing) {
            .symbol => .{ .symbol = value },
            .condition => .{ .condition = .{ .id = self.editing_id, .text = value } },
            .log => .{ .log = .{ .id = self.editing_id, .text = value } },
            .ignore => .{ .ignore = .{ .id = self.editing_id, .count = if (value.len == 0) 0 else std.fmt.parseInt(u64, value, 10) catch {
                self.message = "Enter a nonnegative integer";
                return .local;
            } } },
            .thread => .{ .thread = .{ .id = self.editing_id, .tid = if (value.len == 0) null else std.fmt.parseInt(i32, value, 10) catch {
                self.message = "Enter a live thread TID";
                return .local;
            } } },
        };
        return self.makeRequest(edit, true);
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        if (x < self.bounds.x or x >= self.bounds.x + self.bounds.w or y < self.bounds.y or y >= self.bounds.y + self.bounds.h) {
            self.open = false;
            return;
        }
        const count = self.view.rows.len;
        if (y >= self.bounds.y + 64 and y < self.bounds.y + self.bounds.h - 124 and count > 0) self.selected = @min(count - 1, self.scroll + @as(usize, @intFromFloat((y - self.bounds.y - 64) / 24)));
        self.rememberSelection();
    }
    pub fn wheel(self: *Panel, amount: i32) void {
        const count = self.view.rows.len;
        self.selected = @intCast(@max(0, @min(@as(i64, @intCast(count -| 1)), @as(i64, @intCast(self.selected)) + amount)));
        self.rememberSelection();
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.text(font, b.x + 14, b.y + 10, "BREAKPOINTS   B / Esc close", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, "N new  Space toggle  Del  C if  L log  O stop  H ignore  T thread", theme.weak);
        const count = self.view.rows.len;
        const visible: usize = @intFromFloat(@max(1, (b.h - 188) / 24));
        self.selected = @min(self.selected, count -| 1);
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected - visible + 1;
        var buffer: [1024]u8 = undefined;
        for (self.view.rows[self.scroll..@min(count, self.scroll + visible)], self.scroll..) |item, i| {
            const probe = item.probe;
            const y = b.y + 64 + @as(f32, @floatFromInt(i - self.scroll)) * 24;
            if (i == self.selected) try r.rect(.{ .x = b.x + 6, .y = y - 1, .w = b.w - 12, .h = 24 }, style.fade(theme.focus, 0.16));
            const rule = item.rule;
            const mode = if (probe.internal) "loader" else if (probe.pending) "PENDING" else if (rule) |v| @tagName(v.options.mode) else "stop";
            const condition = if (rule) |v| v.options.condition else "";
            const row = try std.fmt.bufPrint(&buffer, "#{d} {s}  0x{x}  hits {d}  {s}  {s}", .{ probe.id, if (probe.enabled) "on " else "off", probe.address, probe.hit_count, mode, if (probe.pending) item.pending_text else condition });
            try r.textFit(font, b.x + 14, y, b.w - 28, row, if (probe.enabled) theme.text else theme.weak);
        }
        if (count == 0) try r.text(font, b.x + 14, b.y + 70, "Set a source/assembly breakpoint to configure it here", theme.weak);
        const y = b.y + b.h - 112;
        if (count > 0) {
            const item = self.view.rows[self.selected];
            if (item.rule) |rule| {
                const detail = try std.fmt.bufPrint(&buffer, "matched {d}  ignore {d}  thread {s}  {s}", .{ rule.matched_hits, rule.options.ignore_count, rule.thread_label, rule.last_error orelse "" });
                try r.textFit(font, b.x + 14, y, b.w - 28, detail, if (rule.last_error != null) theme.warm else theme.weak);
            }
            if (item.diagnostic) |diagnostic| try r.textFit(font, b.x + 14, y, b.w - 28, diagnostic, theme.warm);
        }
        if (self.view.diagnostic) |diagnostic| try r.textFit(font, b.x + 14, y, b.w - 28, diagnostic, theme.warm);
        try r.textFit(font, b.x + 14, y + 24, b.w - 28, self.message, theme.text);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = y + 48, .w = b.w - 20, .h = 27 }, theme.background, theme.focus, @splat(3));
            try self.editor.draw(r, font, .{ .x = b.x + 16, .y = y + 52, .w = b.w - 32, .h = 22 });
        } else if (self.view.last_log) |message| {
            try r.textFit(font, b.x + 14, y + 52, b.w - 28, message, theme.neutral);
        }
        try r.textFit(font, b.x + 14, y + 80, b.w - 28, "F4 restart  F5 continue/pause  F12 finish  F9 run to source line", theme.weak);
    }
};
