//! Runtime-type input and rendering consume immutable owner projections.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const prepared = @import("../model/runtime_type_view.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
pub const Input = struct { handled: bool = true, action: ?prepared.Action = null };
pub const Panel = struct {
    open: bool = false,
    editor: Editor = .{},
    editing: prepared.Editing = .filter,
    edit_key: prepared.Key = .{},
    edit_serial: u64 = 0,
    pending_editor: ?u64 = null,
    pending: bool = false,
    message: []const u8 = prepared.hint,
    focus: prepared.Focus = .types,
    view: ?prepared.View = null,
    native: ?*prepared.Capture = null,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    divider: f32 = 0,
    value_top: f32 = 0,
    pub fn deinit(self: *Panel) void {
        if (self.native) |capture| {
            capture.deinit();
            std.heap.page_allocator.destroy(capture);
        }
    }
    pub fn show(self: *Panel) void {
        self.open = true;
        self.message = prepared.hint;
    }
    fn emit(self: *Panel, kind: @FieldType(prepared.Action, "kind")) Input {
        if (self.pending) {
            self.message = "Runtime-type operation pending";
            return .{};
        }
        const view = self.view orelse {
            self.message = "Preparing runtime types";
            return .{};
        };
        self.pending = true;
        return .{ .action = .{ .key = view.key, .kind = kind } };
    }
    pub fn complete(self: *Panel, failure: ?anyerror) void {
        self.pending = false;
        if (failure) |err| self.message = @errorName(err) else {
            self.message = prepared.hint;
            if (self.pending_editor == self.edit_serial) self.editor.open = false;
        }
        self.pending_editor = null;
    }
    pub fn present(self: *Panel, value: ?prepared.View) void {
        if (value) |v| {
            if (self.view == null or self.view.?.key.revision != v.key.revision) self.focus = v.focus;
        }
        self.view = value;
    }
    pub fn request(self: *const Panel, height: f32) ?prepared.Request {
        if (!self.open) return null;
        const h = @max(0, height - 136);
        const value_top = @max(184, @min(270, h * 0.4));
        return .{ .types = @intFromFloat(@min(64, @max(0, (h - 188) / 23))), .items = @intFromFloat(@min(64, @max(0, (value_top - 112) / 23))), .values = @intFromFloat(@min(64, @max(0, (h - 142 - value_top) / 23))) };
    }
    pub fn busy(self: *Panel, _: *Session) bool {
        return self.busyPrepared();
    }
    pub fn busyPrepared(self: *const Panel) bool {
        return self.open and (self.pending or (if (self.view) |v| v.busy else false));
    }
    fn nativeApply(self: *Panel, session: *Session, input: Input) void {
        if (input.action) |action| {
            const capture = self.native orelse {
                self.complete(error.RuntimeTypesPending);
                return;
            };
            capture.apply(session, .human, action) catch |err| {
                self.complete(err);
                return;
            };
            self.complete(null);
            const request_value = if (capture.value) |v| v.request else prepared.Request{};
            capture.refresh(session, request_value);
            self.present(capture.value);
        }
    }
    pub fn wheel(self: *Panel, session: *Session, amount: i32) void {
        self.nativeApply(session, self.wheelPrepared(amount));
    }
    pub fn wheelPrepared(self: *Panel, amount: i32) Input {
        return self.emit(.{ .wheel = .{ .focus = self.focus, .amount = std.math.clamp(amount, -64, 64) } });
    }
    pub fn press(self: *Panel, session: *Session, x: f32, y: f32) void {
        self.nativeApply(session, self.pressPrepared(x, y));
    }
    pub fn pressPrepared(self: *Panel, x: f32, y: f32) Input {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) {
            self.open = false;
            return .{};
        }
        if (self.editor.open or y < b.y + 96 or y >= b.y + b.h - 84) return .{};
        const view = self.view orelse return .{};
        if (x < self.divider) {
            self.focus = .types;
            const row: usize = @intFromFloat((y - b.y - 96) / 23);
            if (row < view.types.len) return self.emit(.{ .select_type = view.types[row].index });
        } else if (y < self.value_top) {
            self.focus = .items;
            const row: usize = @intFromFloat((y - b.y - 96) / 23);
            if (row < view.items.len) return self.emit(.{ .open_item = view.items[row].index });
        } else self.focus = .value;
        return .{};
    }
    fn edit(self: *Panel, mode: prepared.Editing) void {
        self.editing = mode;
        self.edit_serial +%= 1;
        self.edit_key = if (self.view) |v| v.key else .{};
        self.editor.start();
        self.message = switch (mode) {
            .write => "Write the open typed value: FIELD_PATH VALUE; Return writes, Esc cancels. Shift+U undoes.",
            .load => "Read-only metadata range: ADDRESS LENGTH (hex or decimal)",
            .filter => "Filter type names or an exact 0x type-record address; empty shows all",
            .address => "Address to read as the selected type",
            .container => "Address of the selected Bucket or array; O lists occupied storage",
            .search => "Search: ADDRESS LENGTH DIRECT_TYPE_FIELD [DERIVED_NAME_OR_ADDRESS]",
        };
    }
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        const input = self.keyPrepared(event);
        self.nativeApply(session, input);
        return input.handled;
    }
    pub fn keyPrepared(self: *Panel, event: keys.Event) Input {
        if (!self.open) return .{ .handled = false };
        if (event.kind != .press and event.kind != .repeat) return .{};
        if (self.editor.open) {
            if (self.editor.key(event)) |action| switch (action) {
                .edited => self.pending_editor = null,
                .cancel => self.message = prepared.hint,
                .submit => |text| {
                    var input = self.emit(.{ .edit = .{ .mode = self.editing, .text = text } });
                    if (input.action) |*value| {
                        // Writes and reads retain the context displayed when
                        // entry began; load/filter do not address a selection.
                        if (self.editing != .load and self.editing != .filter) value.key = self.edit_key;
                        self.pending_editor = self.edit_serial;
                    }
                    return input;
                },
            };
            return .{};
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return .{ .handled = false };
        if (!event.plain()) return .{};
        const k = event.shortcut;
        if (k == keys.sym.escape or k == 'y') {
            self.open = false;
            return .{};
        }
        if (k == keys.sym.space) return .{ .handled = false };
        if (k == keys.sym.tab) {
            self.focus = @enumFromInt((@intFromEnum(self.focus) + 1) % 3);
            return .{};
        }
        if (k == keys.sym.up or k == keys.sym.down or k == 0xff55 or k == 0xff56) return self.wheelPrepared(if (k == keys.sym.up) -1 else if (k == keys.sym.down) 1 else if (k == 0xff55) -12 else 12);
        if (event.kind == .repeat) return .{};
        if (k == 'l' or k == '/' or k == 'g' or k == 's' or k == 'o' or k == 'w') {
            self.edit(if (k == 'l') .load else if (k == '/') .filter else if (k == 'g') .address else if (k == 's') .search else if (k == 'w') .write else .container);
        } else if (k == 'u' and event.mods.shift) {
            if (self.view) |v| return self.emit(.{ .undo = v.undo_id });
        } else if (k == 't') return self.emit(.context) else if (k == 'x') {
            if (self.view) |v| if (v.search_id) |id| return self.emit(.{ .cancel = id });
        } else if (k == '[' or k == ']') return self.emit(.{ .page = .{ .focus = self.focus, .forward = k == ']' } }) else if (k == 0xff0d) return self.emit(.{ .open_item = null });
        return .{};
    }
    pub fn prepare(self: *Panel, session: *Session, height: f32) !void {
        if (self.native == null and self.open) {
            const capture = try std.heap.page_allocator.create(prepared.Capture);
            capture.* = .{};
            self.native = capture;
        }
        if (self.native) |capture| {
            capture.refresh(session, self.request(height));
            self.present(capture.value);
        }
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session) !void {
        try self.prepare(session, height);
        try self.drawPrepared(r, font, width, height);
    }
    pub fn drawPrepared(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = @max(0, width - 40), .h = @max(0, height - 136) };
        const b = self.bounds;
        self.divider = b.x + b.w * 0.4;
        self.value_top = b.y + @max(184, @min(270, b.h * 0.4));
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = @max(0, height - 110) }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "RUNTIME TYPES / Jai    Y or Esc close", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, prepared.hint, theme.weak);
        const view = self.view orelse {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, "Preparing runtime types", theme.weak);
            return self.footer(r, font, b);
        };
        if (!view.context) {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, view.detail, theme.warm);
            return self.footer(r, font, b);
        }
        var buffer: [2048]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 64, b.w - 28, try std.fmt.bufPrint(&buffer, "{s}  / focus: {s}", .{ view.title, @tagName(self.focus) }), if (view.stale) theme.warm else theme.weak);
        if (!view.graph) {
            try r.textFit(font, b.x + 14, b.y + 98, b.w - 28, view.detail, theme.warm);
            return self.footer(r, font, b);
        }
        for (view.types, 0..) |row, i| {
            const y = b.y + 96 + @as(f32, @floatFromInt(i)) * 23;
            if (row.index == view.selected_type) try r.rect(.{ .x = b.x + 8, .y = y - 2, .w = self.divider - b.x - 16, .h = 23 }, style.fade(theme.focus, 0.22));
            try r.textFit(font, b.x + 14, y, self.divider - b.x - 28, row.label, if (row.unavailable) theme.warm else theme.text);
        }
        if (view.types_total == 0) try r.textFit(font, b.x + 14, b.y + 96, self.divider - b.x - 28, "No matching types; / changes filter", theme.weak);
        const right = self.divider + 12;
        const right_width = b.x + b.w - right - 14;
        for (view.items, 0..) |row, i| {
            const y = b.y + 96 + @as(f32, @floatFromInt(i)) * 23;
            if (row.index == view.selected_item) try r.rect(.{ .x = right - 4, .y = y - 2, .w = right_width + 4, .h = 23 }, style.fade(theme.focus, 0.18));
            try r.textFit(font, right, y, right_width, row.label, if (row.unavailable) theme.warm else theme.text);
        }
        if (view.items_total == 0) try r.textFit(font, right, b.y + 96, right_width, "S searches candidates; O lists occupied container slots", theme.weak);
        try r.textFit(font, right, self.value_top - 24, right_width, view.item_label, theme.warm);
        try r.textFit(font, right, self.value_top + 2, right_width, view.value_title, theme.focus);
        if (view.value_hint.len > 0) try r.textFit(font, right, self.value_top + 28, right_width, view.value_hint, theme.weak);
        for (view.values, 0..) |row, i| {
            const x = right + @as(f32, @floatFromInt(row.depth)) * 12;
            try r.textFit(font, x, self.value_top + view.value_offset + @as(f32, @floatFromInt(i)) * 23, @max(0, right_width - (x - right)), row.label, if (row.unavailable) theme.warm else theme.text);
        }
        if (view.search_label.len > 0) try r.textFit(font, b.x + 14, b.y + b.h - 106, b.w - 28, view.search_label, theme.weak);
        try self.footer(r, font, b);
    }
    fn footer(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        const message = if (std.mem.eql(u8, self.message, prepared.hint)) if (self.view) |v| v.message else self.message else self.message;
        try r.textFit(font, b.x + 14, b.y + b.h - 74, b.w - 28, message, theme.text);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = b.y + b.h - 48, .w = b.w - 20, .h = 30 }, theme.background, theme.focus, @splat(3));
            try self.editor.draw(r, font, .{ .x = b.x + 16, .y = b.y + b.h - 43, .w = b.w - 32, .h = 23 });
        }
    }
};
