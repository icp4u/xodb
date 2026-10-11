//! Process selection over copied rows; family controls execute on the owner.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Tree = @import("../model/process_tree.zig").Tree;
const prepared = @import("../model/process_view.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const Panel = struct {
    open: bool = false,
    view: prepared.View = .{},
    cursor: usize = 0,
    cursor_process: u64 = 0,
    first: usize = 0,
    visible: usize = 0,
    message: []const u8 = "",
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn present(self: *Panel, view: prepared.View) void {
        self.view = view;
        self.cursor = @min(self.cursor, view.rows.len -| 1);
        for (view.rows, 0..) |row, i| if (row.stamp.process == self.cursor_process) {
            self.cursor = i;
            break;
        };
        self.rememberCursor();
        self.first = @min(self.first, view.rows.len -| 1);
    }
    fn rememberCursor(self: *Panel) void {
        self.cursor_process = if (self.view.rows.len > 0) self.view.rows[self.cursor].stamp.process else 0;
    }
    pub fn show(self: *Panel, view: prepared.View) void {
        self.open = true;
        self.cursor_process = view.selected;
        self.present(view);
        self.first = 0;
        self.message = "";
    }
    pub fn wheel(self: *Panel, delta: i32) void {
        self.cursor = @intCast(std.math.clamp(@as(i64, @intCast(self.cursor)) + delta, 0, @as(i64, @intCast(self.view.rows.len -| 1))));
        self.rememberCursor();
    }
    fn intent(self: *Panel, shortcut: u32) ?prepared.Intent {
        if (shortcut == 'o' or shortcut == keys.sym.escape) {
            self.open = false;
            return null;
        }
        if (self.view.rows.len == 0) return null;
        const row = self.view.rows[self.cursor];
        const operation: prepared.Operation = switch (shortcut) {
            0xff0d => .select,
            'f' => .{ .following = !row.following },
            'r' => .retry,
            'd' => .detach_family,
            else => return null,
        };
        return .{ .stamp = row.stamp, .operation = operation };
    }
    fn apply(self: *Panel, tree: *Tree, intent_: prepared.Intent) void {
        prepared.apply(tree, intent_.stamp, .human, intent_.operation) catch |err| {
            self.message = @errorName(err);
            return;
        };
        self.complete(intent_.operation);
    }
    pub fn complete(self: *Panel, operation: prepared.Operation) void {
        switch (operation) {
            .select => self.open = false,
            .following => self.message = "Following changed for this process; existing children keep their own setting",
            .retry => self.message = "Retry requested for held child admissions",
            .detach_family => self.message = "Shared family detached; independent fork sessions remain attached",
        }
    }
    pub const KeyAction = union(enum) { ignored, local, owner: prepared.Intent };
    pub fn key(self: *Panel, tree: *Tree, event: keys.Event) bool {
        return switch (self.keyView(event)) {
            .ignored => false,
            .local => true,
            .owner => |intent_| done: {
                self.apply(tree, intent_);
                break :done true;
            },
        };
    }
    pub fn keyView(self: *Panel, event: keys.Event) KeyAction {
        if (!self.open) return .ignored;
        if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return .local;
        switch (event.shortcut) {
            keys.sym.up, 'k' => self.wheel(-1),
            keys.sym.down, 'j' => self.wheel(1),
            0xff55 => self.wheel(-@as(i32, @intCast(@max(1, self.visible)))),
            0xff56 => self.wheel(@intCast(@max(1, self.visible))),
            else => if (event.kind == .press and (event.shortcut != 'd' or event.mods.shift)) {
                if (self.intent(event.shortcut)) |intent_| return .{ .owner = intent_ };
            },
        }
        return .local;
    }
    pub fn press(self: *Panel, tree: *Tree, x: f32, y: f32) void {
        if (self.pressView(x, y)) |intent_| self.apply(tree, intent_);
    }
    pub fn pressView(self: *Panel, x: f32, y: f32) ?prepared.Intent {
        const b = self.bounds;
        if (x < b.x or x >= b.x + b.w or y < b.y or y >= b.y + b.h) {
            self.open = false;
            return null;
        }
        if (y >= b.y + 64 and y < b.y + 93) {
            const shortcut: u32 = if (x < b.x + 185) 'f' else if (x < b.x + 340) 'r' else 'd';
            return self.intent(shortcut);
        } else if (y >= b.y + 112 and y < b.y + 112 + @as(f32, @floatFromInt(self.visible)) * 28 and self.view.rows.len > 0) {
            self.cursor = @min(self.view.rows.len - 1, self.first + @as(usize, @intFromFloat((y - b.y - 112) / 28)));
            self.rememberCursor();
            return self.intent(0xff0d);
        }
        return null;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        const b = gpu.Rect{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        self.bounds = b;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 112 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "PROCESSES   O / Esc close   Click / Enter select   Arrows / Wheel", theme.text);
        var buffer: [512]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, try std.fmt.bufPrint(&buffer, "Viewing #{d}  /  {d} of {d} retained slots  /  MCP defaults to #1", .{ self.view.selected, self.view.rows.len, self.view.limit }), theme.weak);
        if (self.view.rows.len == 0) {
            self.visible = 0;
            try r.textFit(font, b.x + 14, b.y + 64, b.w - 28, "Process list pending", theme.weak);
            return;
        }
        const current = self.view.rows[self.cursor];
        try style.button(r, font, .{ .x = b.x + 12, .y = b.y + 64, .w = 166, .h = 29 }, if (current.following) "Follow: on" else "Follow: off", "F", theme.good, 0, 0);
        try style.button(r, font, .{ .x = b.x + 187, .y = b.y + 64, .w = 145, .h = 29 }, "Retry held", "R", theme.text, 0, 0);
        try style.button(r, font, .{ .x = b.x + 342, .y = b.y + 64, .w = @min(218, b.w - 354), .h = 29 }, "Detach family", "Shift+D", theme.warm, 0, 0);
        const count: usize = @intFromFloat(@max(1, (b.h - 206) / 28));
        if (self.cursor < self.first) self.first = self.cursor;
        if (self.cursor >= self.first + count) self.first = self.cursor + 1 - count;
        self.visible = @min(count, self.view.rows.len - self.first);
        for (self.view.rows[self.first..][0..self.visible], self.first..) |row, i| {
            const y = b.y + 112 + @as(f32, @floatFromInt(i - self.first)) * 28;
            if (i == self.cursor) try style.focus(r, .{ .x = b.x + 8, .y = y - 2, .w = b.w - 16, .h = 26 }, 4, 1);
            try r.textFit(font, b.x + 14, y, b.w - 28, try std.fmt.bufPrint(&buffer, "#{d}  PID {d}  {s}  parent {any}  /  {s}{s}  held {d}", .{ row.stamp.process, row.stamp.pid, @tagName(row.state), row.parent, if (row.following) "follow" else "fixed", if (row.shared_vm) " / shared VM" else "", row.held }), if (i == self.cursor) theme.text else theme.weak);
        }
        try r.textFit(font, b.x + 14, b.y + b.h - 78, b.w - 28, try std.fmt.bufPrint(&buffer, "Row #{d}: {s}", .{ current.stamp.process, current.diagnostic orelse "Children stop for inspection; controls apply to the highlighted row." }), theme.text);
        try r.textFit(font, b.x + 14, b.y + b.h - 52, b.w - 28, "Detach family releases shared-vfork members and pending children.", theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 28, b.w - 28, if (self.message.len > 0) self.message else "Independent fork children stay attached. Process slots include exited sessions.", theme.weak);
    }
};
