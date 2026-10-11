//! Inline scopes share a physical frame's machine state. This panel makes that
//! relationship explicit while allowing caller-local inspection and evaluation.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const model = @import("../model/session.zig");
const prepared = @import("../model/inline_view.zig");
const style = @import("style.zig");
const theme = style.theme;
const watch = @import("watch.zig");
pub const Panel = struct {
    open: bool = false,
    view: prepared.View = .{},
    depth: usize = 0,
    scope_count: usize = 0,
    row: usize = 0,
    generation: u64 = 0,
    tid: i32 = 0,
    frame: usize = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    list_y: f32 = 0,
    first: usize = 0,
    visible: usize = 0,
    editor: watch.Editor = .{},
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    pub fn show(self: *Panel) void {
        self.open = true;
        self.depth = 0;
        self.row = 0;
        self.editor.open = false;
        self.message_len = 0;
    }
    fn say(self: *Panel, text: []const u8) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }
    fn select(self: *Panel, depth: usize) void {
        self.depth = @min(depth, self.scope_count -| 1);
        self.row = 0;
        self.message_len = 0;
    }
    pub fn wheel(self: *Panel, amount: i32) void {
        self.row = @intCast(@max(0, @min(4096, @as(i64, @intCast(self.row)) + amount)));
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) {
            self.open = false;
            return;
        }
        if (y >= self.list_y and y < self.list_y + @as(f32, @floatFromInt(self.visible)) * 24) self.select(self.first + @as(usize, @intFromFloat((y - self.list_y) / 24)));
    }
    pub fn request(self: *Panel, tid: i32, frame: usize, generation: u64) ?prepared.Request {
        if (!self.open) return null;
        if (self.generation != generation or self.tid != tid or self.frame != frame) self.resetSelection();
        self.generation = generation;
        self.tid = tid;
        self.frame = frame;
        return .{ .generation = generation, .tid = tid, .frame = frame, .depth = self.depth };
    }
    fn resetSelection(self: *Panel) void {
        self.depth = 0;
        self.row = 0;
        self.message_len = 0;
        self.editor.open = false;
    }
    pub fn present(self: *Panel, view: prepared.View) void {
        const previous = self.view.key;
        self.view = view;
        const scope_key = view.key orelse return;
        if (previous == null or previous.?.session != scope_key.session or previous.?.image != scope_key.image or self.generation != scope_key.request.generation or self.tid != scope_key.request.tid or self.frame != scope_key.request.frame) self.resetSelection();
        self.generation = scope_key.request.generation;
        self.tid = scope_key.request.tid;
        self.frame = scope_key.request.frame;
        self.depth = scope_key.request.depth;
        self.scope_count = if (view.frame) |frame| frame.inline_frames.len + 1 else 0;
    }
    pub const KeyAction = union(enum) { ignored, local, owner: prepared.Expression };
    pub fn key(self: *Panel, session: *model.Session, tid: i32, frame: usize, event: keys.Event) bool {
        return switch (self.keyView(tid, frame, session.metadata.revision, event)) {
            .ignored => false,
            .local => true,
            .owner => |expression| done: {
                const result = prepared.evaluate(session, expression) catch |err| {
                    self.say(@errorName(err));
                    break :done true;
                };
                self.complete(result);
                break :done true;
            },
        };
    }
    /// Remote callers match the submitted command sequence before completion.
    pub fn complete(self: *Panel, message: prepared.Message) void {
        self.say(message.slice());
        self.editor.open = false;
    }
    pub fn keyView(self: *Panel, tid: i32, frame: usize, metadata: u64, event: keys.Event) KeyAction {
        if (!self.open) return .ignored;
        if (event.kind != .press and event.kind != .repeat) return .local;
        if (self.editor.open) {
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.say("Expression cancelled"),
                .submit => |text| return .{ .owner = .{ .tid = tid, .frame = frame, .depth = self.depth, .metadata = metadata, .text = text } },
            };
            return .local;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return .ignored;
        if (!event.plain()) return .local;
        const k = event.shortcut;
        if (k == keys.sym.escape or k == 'i') {
            self.open = false;
            return .local;
        }
        if (k == keys.sym.space) return .ignored;
        if (k == keys.sym.up) self.select(self.depth -| 1);
        if (k == keys.sym.down) self.select(self.depth + 1);
        if (k == 0xff55) self.wheel(-8);
        if (k == 0xff56) self.wheel(8);
        if (k == 'e' and event.kind == .press) {
            self.editor.start();
            self.say("Read-only expression in selected inline scope");
        }
        return .local;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        var buffer: [1024]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, try std.fmt.bufPrint(&buffer, "INLINE SCOPES   physical frame {d} / tid {d}   I / Esc close", .{ self.frame, self.tid }), theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, "Up/Down or click scope   E expression   Wheel/PgUp/Down locals", theme.weak);
        if (self.view.state != .stopped) {
            self.visible = 0;
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, "Target running; stop to inspect inline scopes", theme.weak);
            return;
        }
        const frame = self.view.frame orelse {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, self.view.diagnostic orelse "Inline scopes pending", theme.weak);
            try self.footer(r, font, b);
            return;
        };
        self.visible = @min(self.scope_count, @as(usize, @intFromFloat(@max(1, @min(6, (b.h - 228) / 24)))));
        self.first = if (self.depth >= self.visible) self.depth - self.visible + 1 else 0;
        self.list_y = b.y + 64;
        for (self.first..self.first + self.visible) |i| {
            const y = self.list_y + @as(f32, @floatFromInt(i - self.first)) * 24;
            if (i == self.depth) try style.focus(r, .{ .x = b.x + 8, .y = y - 2, .w = b.w - 16, .h = 24 }, 4, 1);
            const name = if (i < frame.inline_frames.len) frame.inline_frames[i].name else frame.symbol orelse "?";
            try r.textFit(font, b.x + 14, y, b.w - 28, (std.fmt.bufPrint(&buffer, "{d}  {s}  {s}", .{ i, if (i < frame.inline_frames.len) "inline" else "physical", name }) catch name), if (i == self.depth) theme.text else theme.weak);
        }
        var y = self.list_y + @as(f32, @floatFromInt(self.visible)) * 24 + 8;
        if (self.depth < frame.inline_frames.len) {
            const scope = frame.inline_frames[self.depth];
            try r.textFit(font, b.x + 14, y, b.w - 28, (std.fmt.bufPrint(&buffer, "Called at {s}:{d}", .{ scope.call_path orelse "?", scope.call_line orelse 0 }) catch "Call-site path exceeds display limit"), theme.weak);
        } else try r.textFit(font, b.x + 14, y, b.w - 28, frame.inline_diagnostic orelse "Inline calls share this frame's registers and stack", theme.weak);
        y += 28;
        const locals = self.view.locals;
        self.row = @min(self.row, locals.len -| 1);
        if (locals.len == 0) try r.textFit(font, b.x + 14, y, b.w - 28, "No locals described for this scope", theme.weak);
        for (locals[self.row..]) |local| {
            if (y + 20 > b.y + b.h - 74) break;
            const value = local.value;
            try r.textFit(font, b.x + 14, y, b.w - 28, (std.fmt.bufPrint(&buffer, "{s}  {s}  = {s}{s}", .{ local.name, value.type, value.display, if (value.partial) " (partial)" else "" }) catch local.name), if (value.availability == .available) theme.text else theme.weak);
            y += 23;
        }
        try self.footer(r, font, b);
    }
    fn footer(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        try r.textFit(font, b.x + 14, b.y + b.h - 64, b.w - 28, if (self.view.diagnostic) |message| message else if (self.message_len > 0) self.message[0..self.message_len] else "Scopes are logical calls; frame numbers and machine registers stay physical", theme.weak);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = b.y + b.h - 38, .w = b.w - 20, .h = 27 }, theme.background, theme.focus, @splat(3));
            try self.editor.draw(r, font, .{ .x = b.x + 16, .y = b.y + b.h - 34, .w = b.w - 32, .h = 22 });
        }
    }
};
