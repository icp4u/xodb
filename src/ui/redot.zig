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
    time: bool = false,
    time_panel: @import("redot_time.zig").Panel = .{},
    galaxy_open: bool = false,
    galaxy: ?*@import("redot_galaxy.zig").View = null,
    filtering: bool = false,
    filter: [128]u8 = @splat(0),
    filter_len: usize = 0,
    expanded: ?usize = null,
    property_total: usize = 0,
    row_map: [64]usize = @splat(0),
    row_count: usize = 0,
    visible: usize = 1,
    message: []const u8 = "",
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn deinit(self: *Panel) void {
        if (self.galaxy) |view| std.heap.page_allocator.destroy(view);
        self.galaxy = null;
    }
    pub fn moving(self: *const Panel) bool {
        return self.open and self.galaxy_open and self.galaxy != null and self.galaxy.?.moving;
    }
    fn toggleGalaxy(self: *Panel) void {
        if (self.galaxy == null) {
            const view = std.heap.page_allocator.create(@import("redot_galaxy.zig").View) catch {
                self.message = "Could not allocate the scene galaxy";
                return;
            };
            view.* = .{};
            self.galaxy = view;
        }
        self.galaxy_open = !self.galaxy_open;
    }

    fn matchesProperty(self: *const Panel, property: protocol.Property) bool {
        const needle = self.filter[0..self.filter_len];
        if (needle.len == 0 or std.ascii.indexOfIgnoreCase(property.name, needle) != null or std.ascii.indexOfIgnoreCase(property.display, needle) != null) return true;
        for (property.children) |child| if (std.ascii.indexOfIgnoreCase(child.label, needle) != null or std.ascii.indexOfIgnoreCase(child.display, needle) != null) return true;
        return false;
    }
    fn propertyRow(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect, x: f32, width: f32, property: usize, label: []const u8, value: []const u8, marker: []const u8, ordinal: *usize) !void {
        defer ordinal.* += 1;
        if (ordinal.* < self.property_first) return;
        const row = ordinal.* - self.property_first;
        const y = b.y + 190 + @as(f32, @floatFromInt(row)) * 26;
        if (row >= self.row_map.len or y + 24 > b.y + b.h - 54) return;
        self.row_map[row] = property;
        self.row_count = row + 1;
        var buffer: [1024]u8 = undefined;
        try r.textFit(font, x, y, width, try std.fmt.bufPrint(&buffer, "{s}{s} = {s}", .{ marker, clip(label, 400), clip(value, 570) }), theme.text);
    }

    pub fn show(self: *Panel, adapter: *protocol.Adapter) void {
        self.open = true;
        self.galaxy_open = false;
        self.message = "";
        adapter.requestScene() catch |err| {
            self.message = @errorName(err);
        };
    }
    fn select(self: *Panel, adapter: *protocol.Adapter) void {
        self.cursor = @min(self.cursor, adapter.nodes.len -| 1);
        if (adapter.nodes.len == 0) return;
        self.property_first = 0;
        self.expanded = null;
        adapter.inspect(adapter.nodes[self.cursor].object_id) catch |err| {
            self.message = @errorName(err);
        };
    }
    fn wheel(self: *Panel, adapter: *protocol.Adapter, delta: i32) void {
        if (self.inspector_focus) {
            const count = if (self.signals) adapter.object.signals.len else self.property_total;
            self.property_first = @intCast(std.math.clamp(@as(i64, @intCast(self.property_first)) + delta, 0, @as(i64, @intCast(count -| 1))));
        } else {
            self.cursor = @intCast(std.math.clamp(@as(i64, @intCast(self.cursor)) + delta, 0, @as(i64, @intCast(adapter.nodes.len -| 1))));
            self.select(adapter);
        }
    }
    pub fn input(self: *Panel, w: *Window, adapter: *protocol.Adapter) void {
        if (self.galaxy) |view| view.pointer = .{ w.pointer_x, w.pointer_y };
        if (w.scroll != 0) {
            self.inspector_focus = w.pointer_x >= self.bounds.x + self.bounds.w * 0.38;
            if (!self.galaxy_open) self.wheel(adapter, w.scroll);
            w.scroll = 0;
            w.dirty = true;
        }
        while (w.input.next()) |event| {
            w.dirty = true;
            if (self.filtering) {
                if (event.kind == .press or event.kind == .repeat) {
                    if (event.shortcut == keys.sym.escape or event.shortcut == 0xff0d) {
                        self.filtering = false;
                    } else if (event.shortcut == 0xff08) {
                        self.filter_len -|= 1;
                        while (self.filter_len > 0 and self.filter[self.filter_len] & 0xc0 == 0x80) self.filter_len -= 1;
                    } else if (event.plain() and event.text().len <= self.filter.len - self.filter_len) {
                        @memcpy(self.filter[self.filter_len..][0..event.text().len], event.text());
                        self.filter_len += event.text().len;
                    }
                    self.property_first = 0;
                }
                continue;
            }
            if (self.time and self.time_panel.input(event, &adapter.profiler, self.inspector_focus)) continue;
            if (self.galaxy_open and event.kind == .button_press and event.code == 272) {
                if (self.galaxy.?.select(event.x, event.y)) |id| {
                    for (adapter.nodes, 0..) |node, i| if (node.object_id == id) {
                        self.cursor = i;
                        self.select(adapter);
                        self.galaxy_open = false;
                        self.signals = false;
                        self.time = false;
                        self.inspector_focus = true;
                        break;
                    };
                }
                continue;
            }
            if (event.kind == .button_press and event.code == 272) {
                const b = self.bounds;
                self.inspector_focus = event.x >= b.x + b.w * 0.38;
                if (!self.inspector_focus and event.y >= b.y + 104 and event.y < b.y + b.h - 54 and adapter.nodes.len > 0) {
                    self.cursor = @min(adapter.nodes.len - 1, self.first + @as(usize, @intFromFloat((event.y - b.y - 104) / 28)));
                    self.select(adapter);
                } else if (self.inspector_focus and !self.signals and !self.time and event.y >= b.y + 190) {
                    const row: usize = @intFromFloat((event.y - b.y - 190) / 26);
                    if (row < self.row_count) {
                        const property = self.row_map[row];
                        self.expanded = if (self.expanded == property) null else property;
                    }
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
                'g' => {
                    self.time = false;
                    self.filtering = false;
                    self.toggleGalaxy();
                },
                's', 'p' => {
                    self.galaxy_open = false;
                    self.time = false;
                    self.signals = event.shortcut == 's';
                    self.property_first = 0;
                    self.inspector_focus = true;
                },
                't' => {
                    self.galaxy_open = false;
                    self.time = !self.time;
                    self.inspector_focus = true;
                },
                '/' => {
                    self.galaxy_open = false;
                    self.filtering = true;
                    self.time = false;
                    self.signals = false;
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
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "REDOT / GODOT   U / Esc close   R refresh   G galaxy   P properties   S signals   T time   / filter", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, try std.fmt.bufPrint(&buffer, "ENGINE DEBUGGER PROTOCOL / cooperative   {s}{s}   tree #{d}   object #{d}", .{ @tagName(view.state), if (view.scene_pending or view.object_pending) " / awaiting engine" else "", view.scene_revision, view.object_revision }), theme.weak);
        if (self.galaxy_open) {
            self.galaxy.?.selected_node = if (self.cursor < view.nodes.len) view.nodes[self.cursor].object_id else null;
            try self.galaxy.?.render(r, font, b, view);
            return;
        }
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
            if (self.time) {
                var cost: f64 = 0;
                if (self.time_panel.selected(view.profiler)) |frame| if (node.script_path) |path| for (frame.functions) |function| {
                    if (@import("../redot/profiler.zig").scriptPath(function.signature)) |script| if (std.mem.eql(u8, path, script)) {
                        cost += function.self_ms;
                    };
                };
                try r.textFit(font, b.x + 14 + indent, y, @max(0, left - 28 - indent), try std.fmt.bufPrint(&buffer, "{s} / script {d:.2} ms", .{ clip(node.name, 400), cost }), theme.text);
            } else try r.textFit(font, b.x + 14 + indent, y, @max(0, left - 28 - indent), try std.fmt.bufPrint(&buffer, "{s}  / {s}", .{ clip(node.name, 400), clip(node.type_name, 400) }), theme.text);
        }
        const selected = if (view.nodes.len > 0) view.nodes[self.cursor].object_id else null;
        const matches = selected != null and selected.? == view.object.id;
        // Filled in below: which rows of how many the inspector shows.
        var shown_first: usize = 0;
        var shown: usize = 0;
        var total: usize = 0;
        if (self.time) {
            try self.time_panel.draw(r, font, .{ .x = right, .y = b.y + 72, .w = rw, .h = b.h - 128 }, view.profiler, if (view.nodes.len > 0) view.nodes[self.cursor] else null);
        } else if (matches) {
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
                try r.textFit(font, right, b.y + 158, rw, try std.fmt.bufPrint(&buffer, "Filter{s}: {s}   / edit; click a container to expand (bounded)", .{ if (self.filtering) " [typing]" else "", self.filter[0..self.filter_len] }), theme.weak);
                self.row_count = 0;
                var ordinal: usize = 0;
                for ([_]bool{ true, false }) |members| for (object.properties, 0..) |property, index| {
                    if (property.usage & (64 | 128 | 256) != 0 or members != std.mem.startsWith(u8, property.name, "Members/")) continue;
                    if (!self.matchesProperty(property)) continue;
                    try self.propertyRow(r, font, b, right, rw, index, property.name, property.display, if (property.children.len == 0) "" else if (self.expanded == index) "- " else "+ ", &ordinal);
                    if (self.expanded == index) for (property.children) |child| {
                        const label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ "                "[0 .. @as(usize, child.depth) * 2], clip(child.label, 600) });
                        try self.propertyRow(r, font, b, right + 12, rw - 12, index, label, child.display, "", &ordinal);
                    };
                };
                self.property_total = ordinal;
                self.property_first = @min(self.property_first, ordinal -| 1);
                shown_first = self.property_first;
                shown = self.row_count;
                total = ordinal;
            }
        } else try r.textFit(font, right, b.y + 112, rw, "Select a node. The engine must be running to answer.", theme.weak);
        const title = if (self.signals) "SIGNAL VALUES" else "OBJECT INSPECTOR";
        const focused = if (self.inspector_focus) " / focused" else "";
        if (!self.time) try r.textFit(font, right, b.y + 72, rw, if (shown == 0)
            try std.fmt.bufPrint(&buffer, "{s} / engine-reported properties{s}", .{ title, focused })
        else
            try std.fmt.bufPrint(&buffer, "{s} / {d}-{d} of {d} engine-reported{s}", .{ title, shown_first + 1, shown_first + shown, total, focused }), theme.good);
        if (self.filtering and !matches) try r.textFit(font, right, b.y + 158, rw, try std.fmt.bufPrint(&buffer, "Filter [typing]: {s}", .{self.filter[0..self.filter_len]}), theme.text);
        try r.textFit(font, b.x + 14, b.y + b.h - 48, b.w - 28, view.diagnostic orelse if (self.time) "TIMINGS INCLUDE SAMPLING PAUSES. Amber (or amber-capped selection): stop-sampled, inflated. Blue: protocol-only." else if (view.state == .off) "Launch with --redot-debugger to enable the engine view." else if (view.state == .listening or view.state == .connected) "Waiting for the game. Close this pane to use Continue / O process controls." else "Arrows / wheel browse the focused pane. R refreshes retained snapshots; paused games cannot answer.", if (self.time) theme.warm else theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 24, b.w - 28, self.message, theme.warm);
    }
};
