//! Process selection and explicit family controls, on the ptrace owner thread.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Tree = @import("../model/process_tree.zig").Tree;
const style = @import("style.zig");
const theme = style.theme;
pub const Panel = struct {
    open: bool = false,
    cursor: usize = 0,
    first: usize = 0,
    visible: usize = 0,
    message: []const u8 = "",
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn show(self: *Panel, tree: *Tree) void {
        self.open = true;
        self.cursor = tree.selected;
        self.first = 0;
        self.message = "";
    }
    pub fn wheel(self: *Panel, tree: *Tree, delta: i32) void {
        self.cursor = @intCast(std.math.clamp(@as(i64, @intCast(self.cursor)) + delta, 0, @as(i64, @intCast(tree.count -| 1))));
    }
    fn action(self: *Panel, tree: *Tree, shortcut: u32) !void {
        const session = tree.entries[self.cursor].session;
        switch (shortcut) {
            'o', keys.sym.escape => self.open = false,
            0xff0d => {
                try tree.select(session.process_id);
                self.open = false;
            },
            'f' => {
                try tree.setFollowing(session, !session.target.follow_processes, null, .human);
                self.message = "Following changed for this process; existing children keep their own setting";
            },
            'r' => {
                tree.retryAdmissions();
                session.record(.human, "retry_process_admission");
                self.message = "Retry requested for held child admissions";
            },
            'd' => {
                try tree.detachFamily(session, .human);
                self.message = "Shared family detached; independent fork sessions remain attached";
            },
            else => {},
        }
    }
    pub fn key(self: *Panel, tree: *Tree, event: keys.Event) bool {
        if (!self.open) return false;
        if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return true;
        switch (event.shortcut) {
            keys.sym.up, 'k' => self.wheel(tree, -1),
            keys.sym.down, 'j' => self.wheel(tree, 1),
            0xff55 => self.wheel(tree, -@as(i32, @intCast(@max(1, self.visible)))),
            0xff56 => self.wheel(tree, @intCast(@max(1, self.visible))),
            else => if (event.kind == .press) {
                self.action(tree, event.shortcut) catch |err| {
                    self.message = @errorName(err);
                };
            },
        }
        return true;
    }
    pub fn press(self: *Panel, tree: *Tree, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x >= b.x + b.w or y < b.y or y >= b.y + b.h) {
            self.open = false;
            return;
        }
        if (y >= b.y + 64 and y < b.y + 93) {
            const shortcut: u32 = if (x < b.x + 185) 'f' else if (x < b.x + 340) 'r' else 'd';
            self.action(tree, shortcut) catch |err| {
                self.message = @errorName(err);
            };
        } else if (y >= b.y + 112 and y < b.y + 112 + @as(f32, @floatFromInt(self.visible)) * 28) {
            self.cursor = self.first + @as(usize, @intFromFloat((y - b.y - 112) / 28));
            self.action(tree, 0xff0d) catch |err| {
                self.message = @errorName(err);
            };
        }
    }
    pub fn draw(self: *Panel, tree: *Tree, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        const b = gpu.Rect{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        self.bounds = b;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 112 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "PROCESSES   O / Esc close   Click / Enter select   Arrows / Wheel", theme.text);
        var buffer: [512]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, try std.fmt.bufPrint(&buffer, "Viewing #{d}  /  {d} of {d} retained slots  /  MCP defaults to #1", .{ tree.active().process_id, tree.count, tree.limit }), theme.weak);
        const current = tree.entries[self.cursor];
        try style.button(r, font, .{ .x = b.x + 12, .y = b.y + 64, .w = 166, .h = 29 }, if (current.session.target.follow_processes) "Follow: on" else "Follow: off", "F", theme.good, 0, 0);
        try style.button(r, font, .{ .x = b.x + 187, .y = b.y + 64, .w = 145, .h = 29 }, "Retry held", "R", theme.text, 0, 0);
        try style.button(r, font, .{ .x = b.x + 342, .y = b.y + 64, .w = @min(218, b.w - 354), .h = 29 }, "Detach family", "D", theme.warm, 0, 0);
        const count: usize = @intFromFloat(@max(1, (b.h - 206) / 28));
        if (self.cursor < self.first) self.first = self.cursor;
        if (self.cursor >= self.first + count) self.first = self.cursor + 1 - count;
        self.visible = @min(count, tree.count - self.first);
        for (tree.entries[self.first..][0..self.visible], self.first..) |entry, i| {
            const target = &entry.session.target;
            const y = b.y + 112 + @as(f32, @floatFromInt(i - self.first)) * 28;
            if (i == self.cursor) try style.focus(r, .{ .x = b.x + 8, .y = y - 2, .w = b.w - 16, .h = 26 }, 4, 1);
            try r.textFit(font, b.x + 14, y, b.w - 28, try std.fmt.bufPrint(&buffer, "#{d}  PID {d}  {s}  parent {any}  /  {s}{s}  held {d}", .{ entry.id, target.pid, @tagName(target.state), entry.parent, if (target.follow_processes) "follow" else "fixed", if (target.sharedVm()) " / shared VM" else "", target.birth_count }), if (i == self.cursor) theme.text else theme.weak);
        }
        try r.textFit(font, b.x + 14, b.y + b.h - 78, b.w - 28, try std.fmt.bufPrint(&buffer, "Row #{d}: {s}", .{ current.id, current.admission_error orelse current.session.step_diagnostic orelse "Children stop for inspection; controls apply to the highlighted row." }), theme.text);
        try r.textFit(font, b.x + 14, b.y + b.h - 52, b.w - 28, "Detach family releases shared-vfork members and pending children.", theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 28, b.w - 28, if (self.message.len > 0) self.message else "Independent fork children stay attached. Process slots include exited sessions.", theme.weak);
    }
};
