//! Logical-frame input and drawing from an immutable, bounded publication.
const std = @import("std");
const prepared = @import("../model/frame_view.zig");
const State = @import("../frames/state.zig").State;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const View = struct {
    open: bool = false,
    source: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    serial: u64 = 0,
    preview: bool = false,
    value: prepared.View = .{},
    message: ?[]const u8 = null,
    native: ?*prepared.Capture = null,
    pub fn deinit(self: *View) void {
        if (self.native) |capture| {
            capture.deinit();
            std.heap.page_allocator.destroy(capture);
        }
    }
    pub fn request(self: *const View, height: u32) ?prepared.Request {
        if (!self.open) return null;
        const h: f32 = @floatFromInt(height);
        return .{ .serial = self.serial, .source = self.source, .selected = self.selected, .scroll = self.scroll, .visible = @intFromFloat(@min(64, @max(1, (h - 246) / 24))), .preview_lines = @intFromFloat(@min(64, @max(1, (h - 301) / 22))), .preview = self.preview };
    }
    pub fn present(self: *View, value: ?prepared.View) void {
        const source_count = self.value.source_count;
        const function_count = self.value.function_count;
        self.value = .{ .source_count = source_count, .function_count = function_count, .busy = self.open, .title = "Preparing logical frames" };
        const incoming = value orelse return;
        const wanted = incoming.requested;
        if (incoming.request.serial == self.serial and
            (wanted.source != self.source or wanted.selected != self.selected or
                wanted.scroll != self.scroll or wanted.preview != self.preview)) return;
        self.value = incoming;
        const request_ = incoming.request;
        self.serial = request_.serial;
        self.source = request_.source;
        self.selected = request_.selected;
        self.scroll = request_.scroll;
        self.preview = request_.preview;
    }
    fn refresh(self: *View, state: *State, height: u32) !void {
        if (self.native == null) {
            const capture = try std.heap.page_allocator.create(prepared.Capture);
            capture.* = .{};
            self.native = capture;
        }
        self.native.?.refresh(state, self.request(height));
        self.present(self.native.?.value);
    }
    pub fn input(self: *View, w: *Window, state: *State) void {
        self.refresh(state, @intCast(w.height)) catch |err| {
            self.message = @errorName(err);
            return;
        };
        if (self.inputPrepared(w)) |action| prepared.apply(state, action) catch |err| {
            self.message = @errorName(err);
        };
    }
    /// Local navigation and source-preview intent never touch live evidence.
    /// At most one owner action is returned; later queued input stays queued.
    pub fn inputPrepared(self: *View, w: *Window) ?prepared.Action {
        while (w.input.next()) |event| {
            if ((event.kind == .press or event.kind == .repeat) and event.plain()) {
                w.dirty = true;
                switch (event.shortcut) {
                    'q' => if (event.kind == .press and event.mods.shift) {
                        w.closing = true;
                        w.close_reason = .quit_key;
                    },
                    'l' => self.open = false,
                    keys.sym.escape => return .{ .serial = self.serial, .source = self.source, .kind = .cancel },
                    keys.sym.up, 'k' => {
                        self.selected -|= 1;
                        self.preview = false;
                    },
                    keys.sym.down, 'j' => {
                        self.selected = @min(self.selected +| 1, self.value.function_count -| 1);
                        self.preview = false;
                    },
                    '[' => {
                        self.source -|= 1;
                        self.selected = 0;
                        self.scroll = 0;
                        self.preview = false;
                    },
                    ']' => {
                        if (self.source + 1 < self.value.source_count) self.source += 1;
                        self.selected = 0;
                        self.scroll = 0;
                        self.preview = false;
                    },
                    0xff0d => self.preview = true,
                    't' => if (event.kind == .press) return .{ .serial = self.serial, .source = self.source, .kind = .next_thread },
                    else => {},
                }
            } else if (event.kind == .button_press and event.code == 0x110 and event.y >= 200 and event.x < @as(f32, @floatFromInt(w.width)) * 0.56) {
                self.selected = @min(self.scroll + @as(usize, @intFromFloat((event.y - 200) / 24)), self.value.function_count -| 1);
                self.preview = true;
                w.dirty = true;
            }
        }
        if (w.scroll != 0) {
            if (w.scroll > 0) self.selected -|= 3 else self.selected = @min(self.selected +| 3, self.value.function_count -| 1);
            self.preview = false;
            w.scroll = 0;
            w.dirty = true;
        }
        return null;
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, state: *State) !void {
        try self.refresh(state, @intCast(w.height));
        try self.drawPrepared(r, font, w);
    }
    pub fn drawPrepared(self: *View, r: *gpu.Renderer, font: *Font, w: *Window) !void {
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        try r.rect(all, theme.background);
        try label(r, font, 16, 18, width - 32, theme.text, "LOGICAL FRAMES  /  separate from native stacks", .{});
        try label(r, font, 16, height - 28, width - 32, theme.weak, "L native workspace   [ / ] source   J/K select   Enter source   T thread   Esc cancel   Shift+Q quit", .{});
        const value = self.value;
        if (self.message orelse value.diagnostic) |why| try label(r, font, 16, 50, width - 32, theme.warm, "{s}", .{why});
        try label(r, font, 16, if (value.logical) 78 else 85, width - 32, theme.text, "{s}", .{value.title});
        try label(r, font, 16, if (value.logical) 106 else 116, width - 32, if (value.incomplete and value.evidence.len == 0) theme.warm else theme.text, "{s}", .{value.summary});
        if (!value.logical) return;
        try label(r, font, 16, 134, width - 32, if (value.incomplete) theme.warm else theme.weak, "{s}", .{value.evidence});
        const left = width * 0.56;
        try label(r, font, 16, 172, left - 32, theme.weak, "Inclusive / self count    Function", .{});
        for (value.rows, 0..) |row, i| {
            const y = 200 + @as(f32, @floatFromInt(i)) * 24;
            if (row.index == self.selected) try r.rect(.{ .x = 12, .y = y, .w = left - 24, .h = 24 }, theme.pop);
            try label(r, font, 16, y, left - 32, theme.text, "{s}", .{row.label});
        }
        if (value.name.len == 0) return;
        try label(r, font, left + 10, 172, width - left - 24, theme.text, "{s}", .{value.name});
        try label(r, font, left + 10, 200, width - left - 24, theme.warm, "{s}", .{value.location});
        try label(r, font, left + 10, 228, width - left - 24, theme.weak, "{s}", .{value.preview_status});
        for (value.preview, 0..) |line, i| try label(r, font, left + 10, 258 + @as(f32, @floatFromInt(i)) * 22, width - left - 24, if (line.selected) theme.warm else theme.text, "{d}  {s}", .{ line.number, line.text });
    }
};
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}

test "logical frame navigation is not reset by an older publication" {
    var view: View = .{ .open = true, .serial = 1, .selected = 3 };
    view.value = .{ .source_count = 2, .function_count = 40 };
    view.present(.{ .requested = .{ .serial = 1, .selected = 2 }, .request = .{ .serial = 1, .selected = 2 } });
    try std.testing.expectEqual(@as(usize, 3), view.selected);
    try std.testing.expectEqual(@as(usize, 40), view.value.function_count);
    try std.testing.expectEqual(@as(usize, 0), view.value.rows.len);
    view.present(.{ .requested = .{ .serial = 1, .selected = 3 }, .request = .{ .serial = 1, .selected = 3, .scroll = 2 } });
    try std.testing.expectEqual(@as(usize, 3), view.selected);
    try std.testing.expectEqual(@as(usize, 2), view.scroll);
    view.present(null);
    try std.testing.expectEqual(@as(usize, 3), view.selected);
    view.present(.{ .requested = .{ .serial = 1 }, .request = .{ .serial = 2 } });
    try std.testing.expectEqual(@as(usize, 0), view.selected);
    try std.testing.expectEqual(@as(u64, 2), view.serial);
}
