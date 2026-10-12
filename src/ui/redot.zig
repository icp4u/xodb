//! Local cooperative engine view. Socket work stays in Session.poll; drawing
//! only consumes the adapter's retained snapshot on the same owner thread.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/window.zig").Window;
const keys = @import("../platform/input.zig");
const protocol = @import("../redot/protocol.zig");
const style = @import("style.zig");
const theme = style.theme;

/// A leading part of `text` of at most `limit` bytes, whole characters only:
/// names come from the game and the label buffer is fixed.
fn clip(text: []const u8, limit: usize) []const u8 {
    var end = @min(text.len, limit);
    while (end < text.len and end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

pub const Panel = struct {
    open: bool = false,
    cursor: usize = 0,
    first: usize = 0,
    property_first: usize = 0,
    inspector_focus: bool = false,
    signals: bool = false,
    visible: usize = 1,
    message: []const u8 = "",
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn show(self: *Panel, adapter: *protocol.Adapter) void {
        self.open = true;
        self.message = "";
        adapter.requestScene() catch |err| {
            self.message = @errorName(err);
        };
    }
    fn select(self: *Panel, adapter: *protocol.Adapter) void {
        self.cursor = @min(self.cursor, adapter.nodes.len -| 1);
        if (adapter.nodes.len == 0) return;
        self.property_first = 0;
        adapter.inspect(adapter.nodes[self.cursor].object_id) catch |err| {
            self.message = @errorName(err);
        };
    }
    fn wheel(self: *Panel, adapter: *protocol.Adapter, delta: i32) void {
        if (self.inspector_focus) {
            const count = if (self.signals) adapter.object.signals.len else adapter.object.properties.len;
            self.property_first = @intCast(std.math.clamp(@as(i64, @intCast(self.property_first)) + delta, 0, @as(i64, @intCast(count -| 1))));
        } else {
            self.cursor = @intCast(std.math.clamp(@as(i64, @intCast(self.cursor)) + delta, 0, @as(i64, @intCast(adapter.nodes.len -| 1))));
            self.select(adapter);
        }
    }
    pub fn input(self: *Panel, w: *Window, adapter: *protocol.Adapter) void {
        if (w.scroll != 0) {
            self.inspector_focus = w.pointer_x >= self.bounds.x + self.bounds.w * 0.38;
            self.wheel(adapter, w.scroll);
            w.scroll = 0;
            w.dirty = true;
        }
        while (w.input.next()) |event| {
            w.dirty = true;
            if (event.kind == .button_press and event.code == 272) {
                const b = self.bounds;
                self.inspector_focus = event.x >= b.x + b.w * 0.38;
                if (!self.inspector_focus and event.y >= b.y + 104 and event.y < b.y + b.h - 54 and adapter.nodes.len > 0) {
                    self.cursor = @min(adapter.nodes.len - 1, self.first + @as(usize, @intFromFloat((event.y - b.y - 104) / 28)));
                    self.select(adapter);
                }
            }
            if (!event.plain() or (event.kind != .press and event.kind != .repeat)) continue;
            switch (event.shortcut) {
                keys.sym.escape, 'u' => {
                    self.open = false;
                    return;
                },
                keys.sym.up, 'k' => self.wheel(adapter, -1),
                keys.sym.down, 'j' => self.wheel(adapter, 1),
                0xff55 => self.wheel(adapter, -@as(i32, @intCast(self.visible))),
                0xff56 => self.wheel(adapter, @intCast(self.visible)),
                keys.sym.tab => self.inspector_focus = !self.inspector_focus,
                's', 'p' => {
                    self.signals = event.shortcut == 's';
                    self.property_first = 0;
                    self.inspector_focus = true;
                },
                0xff0d => self.select(adapter),
                'r' => {
                    self.message = "";
                    adapter.requestScene() catch |err| {
                        self.message = @errorName(err);
                    };
                    self.select(adapter);
                },
                else => {},
            }
        }
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, view: protocol.Snapshot) !void {
        if (!self.open) return;
        const b = gpu.Rect{ .x = 16, .y = 92, .w = @max(0, width - 32), .h = @max(0, height - 128) };
        self.bounds = b;
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        const left = b.w * 0.38;
        const right = b.x + left + 16;
        const rw = b.w - left - 30;
        var buffer: [1024]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "REDOT / GODOT   U / Esc close   R refresh   Tab focus   P properties   S signals", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, try std.fmt.bufPrint(&buffer, "ENGINE DEBUGGER PROTOCOL / cooperative   {s}{s}   tree #{d}   object #{d}", .{ @tagName(view.state), if (view.scene_pending or view.object_pending) " / awaiting engine" else "", view.scene_revision, view.object_revision }), theme.weak);
        try r.rect(.{ .x = b.x + left, .y = b.y + 68, .w = 1, .h = @max(0, b.h - 112) }, theme.border);
        try r.textFit(font, b.x + 14, b.y + 72, left - 28, try std.fmt.bufPrint(&buffer, "SCENE TREE / {d} nodes{s}", .{ view.nodes.len, if (!self.inspector_focus) " / focused" else "" }), theme.good);
        self.visible = @intFromFloat(@max(1, (b.h - 158) / 28));
        self.cursor = @min(self.cursor, view.nodes.len -| 1);
        if (self.cursor < self.first) self.first = self.cursor;
        if (self.cursor >= self.first + self.visible) self.first = self.cursor + 1 - self.visible;
        self.first = @min(self.first, view.nodes.len);
        for (view.nodes[self.first..][0..@min(self.visible, view.nodes.len - self.first)], self.first..) |node, i| {
            const y = b.y + 104 + @as(f32, @floatFromInt(i - self.first)) * 28;
            if (self.cursor == i) try style.focus(r, .{ .x = b.x + 7, .y = y - 2, .w = left - 14, .h = 26 }, 4, 1);
            const indent = @as(f32, @floatFromInt(@min(node.depth, 12))) * 14;
            try r.textFit(font, b.x + 14 + indent, y, @max(0, left - 28 - indent), try std.fmt.bufPrint(&buffer, "{s}  / {s}", .{ clip(node.name, 400), clip(node.type_name, 400) }), theme.text);
        }
        const selected = if (view.nodes.len > 0) view.nodes[self.cursor].object_id else null;
        const matches = selected != null and selected.? == view.object.id;
        // Filled in below: which rows of how many the inspector shows.
        var shown_first: usize = 0;
        var shown: usize = 0;
        var total: usize = 0;
        if (matches) {
            const object = view.object;
            try r.textFit(font, right, b.y + 104, rw, try std.fmt.bufPrint(&buffer, "{s}  #{d}", .{ clip(object.class_name, 400), object.id }), theme.text);
            try r.textFit(font, right, b.y + 130, rw, try std.fmt.bufPrint(&buffer, "Script: {s}", .{clip(object.script_path orelse view.nodes[self.cursor].script_path orelse "none reported", 900)}), theme.weak);
            if (self.signals) {
                try r.textFit(font, right, b.y + 158, rw, "Declared signals / connections are not enumerated by this protocol.", theme.weak);
                if (object.signals.len == 0) try r.textFit(font, right, b.y + 194, rw, "No Signal-valued properties reported.", theme.text);
                self.property_first = @min(self.property_first, object.signals.len -| 1);
                shown_first = self.property_first;
                total = object.signals.len;
                for (object.signals[self.property_first..], 0..) |signal, i| {
                    const y = b.y + 194 + @as(f32, @floatFromInt(i)) * 48;
                    if (y + 44 > b.y + b.h - 54) break;
                    shown = i + 1;
                    try r.textFit(font, right, y, rw, signal.property, theme.weak);
                    try r.textFit(font, right, y + 22, rw, signal.display, theme.text);
                }
            } else {
                self.property_first = @min(self.property_first, object.properties.len -| 1);
                shown_first = self.property_first;
                total = object.properties.len;
                for (object.properties[self.property_first..], 0..) |property, i| {
                    const y = b.y + 166 + @as(f32, @floatFromInt(i)) * 48;
                    if (y + 44 > b.y + b.h - 54) break;
                    shown = i + 1;
                    try r.textFit(font, right, y, rw, try std.fmt.bufPrint(&buffer, "{s} / {s}", .{ clip(property.name, 900), property.variant_type }), theme.weak);
                    try r.textFit(font, right + 8, y + 22, rw - 8, property.display, theme.text);
                }
            }
        } else try r.textFit(font, right, b.y + 112, rw, "Select a node. The engine must be running to answer.", theme.weak);
        const title = if (self.signals) "SIGNAL VALUES" else "OBJECT INSPECTOR";
        const focused = if (self.inspector_focus) " / focused" else "";
        try r.textFit(font, right, b.y + 72, rw, if (shown == 0)
            try std.fmt.bufPrint(&buffer, "{s} / engine-reported properties{s}", .{ title, focused })
        else
            try std.fmt.bufPrint(&buffer, "{s} / {d}-{d} of {d} engine-reported{s}", .{ title, shown_first + 1, shown_first + shown, total, focused }), theme.good);
        try r.textFit(font, b.x + 14, b.y + b.h - 48, b.w - 28, view.diagnostic orelse if (view.state == .off) "Launch with --redot-debugger to enable the engine view." else if (view.state == .listening or view.state == .connected) "Waiting for the game. Close this pane to use Continue / O process controls." else "Arrows / wheel browse the focused pane. R refreshes retained snapshots; paused games cannot answer.", theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 24, b.w - 28, self.message, theme.warm);
    }
};
