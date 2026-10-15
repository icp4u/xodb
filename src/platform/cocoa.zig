//! Cocoa platform contract. The checked-in C implementation is a native stub:
//! it lets the complete GUI compile with `-Dplatform=cocoa` before an AppKit
//! implementation and Mac test lane land, and refuses cleanly when opened.
const std = @import("std");
const vk = @import("../c_ui.zig").api;
const platform = @import("window.zig");
const input = @import("input.zig");
const Node = @import("../render/vk_select.zig").Node;
const shim = @cImport(@cInclude("cocoa_shim.h"));

pub const Keyboard = @import("input_macos.zig").Keyboard;

pub const Window = struct {
    input: Keyboard = .{},
    own_frame: bool = false,
    width: u32 = 1280,
    height: u32 = 800,
    maximized: bool = false,
    closing: bool = false,
    close_reason: platform.CloseReason = .none,
    dirty: bool = true,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    mouse_down: bool = false,
    scroll: i32 = 0,
    scale_override: ?f32 = null,
    minimum_ui: [2]i32 = .{ @import("../look.zig").minimum.width, @import("../look.zig").minimum.height },

    opened: bool = false,
    backing_scale: f32 = 1,
    surface_width: u32 = 1280,
    surface_height: u32 = 800,
    scroll_points: f32 = 0,
    cursor: platform.Cursor = .default,
    clip_destination: u64 = 0,
    clip_epoch: u64 = 0,
    clip_result: ?platform.clip.Result = null,

    pub fn init(self: *Window) !void {
        self.input = Keyboard.init();
        self.input.trace = std.c.getenv("XODB_INPUT_TRACE") != null;
        if (shim.xcocoa_open(self.width, self.height, "xodb") == 0) return error.CocoaUnavailable;
        self.opened = true;
        errdefer shim.xcocoa_close();
        var width = self.width;
        var height = self.height;
        var reported_scale = self.backing_scale;
        shim.xcocoa_size(&width, &height, &reported_scale);
        self.surface_width = if (width > 0) width else self.width;
        self.surface_height = if (height > 0) height else self.height;
        self.backing_scale = safeScale(reported_scale);
        self.syncScale();
        self.input.focus(true);
    }
    pub fn deinit(self: *Window) void {
        if (self.opened) shim.xcocoa_close();
        self.opened = false;
        self.input.deinit();
    }
    pub fn setOwnFrame(self: *Window, own: bool) void {
        self.own_frame = own;
        if (self.opened) shim.xcocoa_set_own_frame(@intFromBool(own));
    }
    pub fn setCursor(self: *Window, cursor: platform.Cursor) void {
        self.cursor = cursor;
        if (self.opened) shim.xcocoa_set_cursor(@intFromEnum(cursor));
    }
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        if (self.opened) shim.xcocoa_set_title(title);
    }
    pub fn setAppId(self: *Window, app_id: [*:0]const u8) void {
        if (self.opened) shim.xcocoa_set_app_id(app_id);
    }
    pub fn setMinSize(self: *Window, width: i32, height: i32) void {
        self.minimum_ui = .{ width, height };
        if (self.opened) shim.xcocoa_set_min_size(platform.minimumSurface(width, self.scale(), self.backing_scale), platform.minimumSurface(height, self.scale(), self.backing_scale));
    }
    pub fn minimize(self: *Window) void {
        if (self.opened) shim.xcocoa_minimize();
    }
    pub fn toggleMaximized(self: *Window) void {
        self.maximized = !self.maximized;
        if (self.opened) shim.xcocoa_toggle_maximized();
    }
    pub fn beginMove(self: *Window) void {
        if (self.opened) shim.xcocoa_begin_move();
    }
    pub fn beginResize(self: *Window, edge: platform.Edge) void {
        if (self.opened) shim.xcocoa_begin_resize(switch (edge) {
            .top => 1,
            .bottom => 2,
            .left => 3,
            .right => 4,
            .top_left => 5,
            .top_right => 6,
            .bottom_left => 7,
            .bottom_right => 8,
        });
    }
    pub fn scale(self: *const Window) f32 {
        return self.scale_override orelse safeScale(self.backing_scale);
    }
    fn syncScale(self: *Window) void {
        const pixels = self.bufferExtent();
        self.width = platform.uiExtent(pixels.width, self.scale());
        self.height = platform.uiExtent(pixels.height, self.scale());
        if (self.opened) shim.xcocoa_set_scale(self.backing_scale);
        self.setMinSize(self.minimum_ui[0], self.minimum_ui[1]);
    }
    pub fn bufferExtent(self: *const Window) platform.Extent {
        return .{ .width = platform.deviceExtent(self.surface_width, self.backing_scale), .height = platform.deviceExtent(self.surface_height, self.backing_scale) };
    }
    fn pointerUnits(self: *const Window, value: f32) f32 {
        return value * self.backing_scale / self.scale();
    }

    pub const vk_surface_extension: [*:0]const u8 = "VK_EXT_metal_surface";
    pub fn createSurface(_: *Window, instance: vk.VkInstance, surface: *vk.VkSurfaceKHR) vk.VkResult {
        surface.* = null;
        return @intCast(shim.xcocoa_create_surface(@ptrCast(instance), @ptrCast(surface)));
    }
    pub fn displayGpu(_: *Window) ?Node {
        return null;
    }
    pub fn displayFd(_: *Window) ?c_int {
        return null;
    }

    pub fn clipFocus(self: *Window, destination: u64, epoch: u64) void {
        if (self.clip_destination == destination and self.clip_epoch == epoch) return;
        self.clip_destination = destination;
        self.clip_epoch = epoch;
        self.clip_result = null;
    }
    pub fn clipRequest(self: *Window, primary: bool) platform.clip.Status {
        self.clip_result = null;
        if (primary or !self.opened) return .unavailable;
        var result = platform.clip.Result{
            .destination = self.clip_destination,
            .epoch = self.clip_epoch,
            .status = .unavailable,
            .size = 0,
            .bytes = @splat(0),
        };
        var size: usize = 0;
        const status = shim.xcocoa_clip_get(@ptrCast(&result.bytes), result.bytes.len, &size);
        result.size = @min(size, result.bytes.len);
        result.status = switch (status) {
            shim.XCOCOA_CLIP_READY => if (size > result.bytes.len) .truncated else .ready,
            shim.XCOCOA_CLIP_TRUNCATED => .truncated,
            else => return .unavailable,
        };
        self.clip_result = result;
        self.dirty = true;
        return result.status;
    }
    pub fn clipTake(self: *Window, out: *platform.clip.Result) bool {
        out.* = self.clip_result orelse return false;
        self.clip_result = null;
        return true;
    }
    pub fn clipPending(_: *const Window) bool {
        return false;
    }
    pub fn clipCopy(self: *Window, primary: bool, bytes: []const u8) bool {
        return !primary and self.opened and shim.xcocoa_clip_set(@ptrCast(bytes.ptr), bytes.len) != 0;
    }

    /// FIFO presentation provides pacing on Cocoa; no Wayland-style callback.
    pub fn frameReady(_: *const Window) bool {
        return true;
    }
    pub fn requestFrame(_: *Window) !void {}
    pub fn cancelFrame(_: *Window) void {}
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        if (!self.closing) self.drain(timeout_ms);
    }
    pub fn pumpDuringClose(self: *Window, timeout_ms: i32) !void {
        self.drain(timeout_ms);
    }
    fn drain(self: *Window, timeout_ms: i32) void {
        shim.xcocoa_pump(timeout_ms);
        var event: shim.xcocoa_event = undefined;
        while (shim.xcocoa_next(&event) != 0) self.applyEvent(&event);
    }
    fn applyEvent(self: *Window, event: *const shim.xcocoa_event) void {
        switch (event.kind) {
            shim.XCOCOA_EVENT_KEY => {
                var translated = input.Event{
                    .kind = if (event.flags & shim.XCOCOA_PRESSED == 0) .release else if (event.flags & shim.XCOCOA_REPEAT != 0) .repeat else .press,
                    .time_ms = event.time_ms,
                    .code = event.code,
                    .sym = event.sym,
                    .shortcut = event.shortcut,
                    .mods = eventMods(event.mods),
                };
                translated.text_len = @intCast(@min(event.text_len, translated.text_bytes.len));
                const text: [*]const u8 = @ptrCast(&event.text);
                @memcpy(translated.text_bytes[0..translated.text_len], text[0..translated.text_len]);
                self.input.translated(translated);
                self.dirty = true;
            },
            shim.XCOCOA_EVENT_BUTTON => {
                self.pointer_x = self.pointerUnits(event.x);
                self.pointer_y = self.pointerUnits(event.y);
                self.input.current = eventMods(event.mods);
                const pressed = event.flags & shim.XCOCOA_PRESSED != 0;
                self.input.button(event.time_ms, event.code, pressed, self.pointer_x, self.pointer_y);
                if (event.code == 272) self.mouse_down = pressed;
                self.dirty = true;
            },
            shim.XCOCOA_EVENT_MOTION => {
                self.pointer_x = self.pointerUnits(event.x);
                self.pointer_y = self.pointerUnits(event.y);
                if (self.mouse_down) self.dirty = true;
            },
            shim.XCOCOA_EVENT_SCROLL => {
                if (event.flags & shim.XCOCOA_PRECISE != 0) {
                    self.scroll_points += event.scroll_y;
                    const lines: i32 = @intFromFloat(@trunc(self.scroll_points / 16));
                    self.scroll_points -= @as(f32, @floatFromInt(lines)) * 16;
                    self.scroll += lines;
                    if (lines != 0) self.dirty = true;
                } else {
                    const lines: i32 = @intFromFloat(@round(event.scroll_y * 3));
                    self.scroll += lines;
                    if (lines != 0) self.dirty = true;
                }
            },
            shim.XCOCOA_EVENT_RESIZE => if (event.width > 0 and event.height > 0) {
                const previous_pointer_scale = self.backing_scale / self.scale();
                self.surface_width = @intCast(event.width);
                self.surface_height = @intCast(event.height);
                self.backing_scale = safeScale(event.scale);
                self.syncScale();
                const pointer_ratio = self.backing_scale / self.scale() / previous_pointer_scale;
                self.pointer_x *= pointer_ratio;
                self.pointer_y *= pointer_ratio;
                self.dirty = true;
            },
            shim.XCOCOA_EVENT_CLOSE => {
                self.closing = true;
                self.close_reason = .compositor_close;
            },
            shim.XCOCOA_EVENT_FOCUS => self.input.focus(event.flags & shim.XCOCOA_PRESSED != 0),
            else => {},
        }
    }
};

fn safeScale(value: f32) f32 {
    if (!std.math.isFinite(value) or value <= 0) return 1;
    return std.math.clamp(value, platform.min_ui_scale, platform.max_ui_scale);
}
fn eventMods(mods: u32) input.Mods {
    return .{
        .shift = mods & shim.XCOCOA_SHIFT != 0,
        .ctrl = mods & shim.XCOCOA_CTRL != 0,
        .alt = mods & shim.XCOCOA_ALT != 0,
        .super = mods & shim.XCOCOA_COMMAND != 0,
        .caps = mods & shim.XCOCOA_CAPS != 0,
        .num = mods & shim.XCOCOA_NUM != 0,
    };
}

test "Cocoa events keep logical coordinates separate from backing scale" {
    var window = Window{};
    var resize = std.mem.zeroes(shim.xcocoa_event);
    resize.kind = shim.XCOCOA_EVENT_RESIZE;
    resize.width = 900;
    resize.height = 600;
    resize.scale = 2;
    window.applyEvent(&resize);
    try std.testing.expectEqual(@as(u32, 900), window.width);
    try std.testing.expectEqual(@as(u32, 600), window.height);
    try std.testing.expectEqual(@as(f32, 2), window.scale());
    window.scale_override = 1.5;
    window.syncScale();
    try std.testing.expectEqual(@as(f32, 1.5), window.scale());
    try std.testing.expectEqual(@as(u32, 1200), window.width);
    try std.testing.expectEqual(@as(u32, 800), window.height);
    try std.testing.expectEqual(platform.Extent{ .width = 1800, .height = 1200 }, window.bufferExtent());
    var click = std.mem.zeroes(shim.xcocoa_event);
    click.kind = shim.XCOCOA_EVENT_BUTTON;
    click.flags = shim.XCOCOA_PRESSED;
    click.code = 272;
    click.x = 525;
    click.y = 48.75;
    window.applyEvent(&click);
    const button_event = window.input.next().?;
    try std.testing.expectEqual(@as(f32, 700), button_event.x);
    try std.testing.expectEqual(@as(f32, 65), button_event.y);
    // Moving to a 1x display with an explicit UI size preserves pixel size,
    // changes layout space, and reprojects a stationary pointer.
    resize.scale = 1;
    window.applyEvent(&resize);
    try std.testing.expectEqual(@as(u32, 600), window.width);
    try std.testing.expectEqual(@as(f32, 350), window.pointer_x);
    try std.testing.expectEqual(platform.Extent{ .width = 900, .height = 600 }, window.bufferExtent());

    var focus = std.mem.zeroes(shim.xcocoa_event);
    focus.kind = shim.XCOCOA_EVENT_FOCUS;
    focus.flags = shim.XCOCOA_PRESSED;
    window.applyEvent(&focus);
    var key = std.mem.zeroes(shim.xcocoa_event);
    key.kind = shim.XCOCOA_EVENT_KEY;
    key.flags = shim.XCOCOA_PRESSED;
    key.code = 30;
    key.sym = 'A';
    key.shortcut = 'a';
    key.mods = shim.XCOCOA_COMMAND;
    key.text_len = 1;
    key.text[0] = 'a';
    window.applyEvent(&key);
    const translated = window.input.next().?;
    try std.testing.expect(translated.mods.super and translated.shortcut == 'a');
    try std.testing.expectEqualStrings("a", translated.text());

    var scroll = std.mem.zeroes(shim.xcocoa_event);
    scroll.kind = shim.XCOCOA_EVENT_SCROLL;
    scroll.flags = shim.XCOCOA_PRECISE;
    scroll.scroll_y = 32;
    window.applyEvent(&scroll);
    try std.testing.expectEqual(@as(i32, 2), window.scroll);
}

test "native Cocoa stub refuses before creating a Vulkan surface" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    var window = Window{};
    try std.testing.expectError(error.CocoaUnavailable, window.init());
    var surface: vk.VkSurfaceKHR = undefined;
    try std.testing.expectEqual(vk.VK_ERROR_EXTENSION_NOT_PRESENT, window.createSurface(null, &surface));
    try std.testing.expect(surface == null);
}
