//! The backend with no window system (-Dplatform=null). A window cannot be
//! opened (`init` fails), but one can be declared and fed by hand, which is
//! all the unit tests need; it also shows what window.zig asks of a backend.
const std = @import("std");
const vk = @import("../c_ui.zig").api;
const platform = @import("window.zig");
const input = @import("input.zig");
const Node = @import("../render/vk_select.zig").Node;

pub const Keyboard = struct {
    queue: [input.capacity]input.Event = undefined,
    head: usize = 0,
    count: usize = 0,
    dropped: u64 = 0,
    keymap_errors: u64 = 0,
    focused: bool = false,
    focus_revision: u64 = 0,
    trace: bool = false,

    pub fn mods(_: *const Keyboard) input.Mods {
        return .{};
    }
    pub fn heldShortcut(_: *const Keyboard, _: u32) bool {
        return false;
    }
    pub fn button(self: *Keyboard, time_ms: u32, code: u32, pressed: bool, x: f32, y: f32) void {
        if (self.count == input.capacity) {
            self.dropped += 1;
            return;
        }
        self.queue[(self.head + self.count) % input.capacity] = .{ .kind = if (pressed) .button_press else .button_release, .time_ms = time_ms, .code = code, .x = x, .y = y };
        self.count += 1;
    }
    pub fn tick(_: *Keyboard, _: u64) void {}
    pub fn timeoutMs(_: *const Keyboard, _: u64, idle_ms: i32) i32 {
        return idle_ms;
    }
    pub fn next(self: *Keyboard) ?input.Event {
        if (self.count == 0) return null;
        const event = self.queue[self.head];
        self.head = (self.head + 1) % input.capacity;
        self.count -= 1;
        return event;
    }
};

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

    pub fn init(_: *Window) !void {
        return error.NoDisplay;
    }
    pub fn deinit(_: *Window) void {}
    pub fn setOwnFrame(self: *Window, own: bool) void {
        self.own_frame = own;
    }
    pub fn setCursor(_: *Window, _: platform.Cursor) void {}
    pub fn setTitle(_: *Window, _: [*:0]const u8) void {}
    pub fn setAppId(_: *Window, _: [*:0]const u8) void {}
    pub fn setMinSize(_: *Window, _: i32, _: i32) void {}
    pub fn minimize(_: *Window) void {}
    pub fn toggleMaximized(self: *Window) void {
        self.maximized = !self.maximized;
    }
    pub fn beginMove(_: *Window) void {}
    pub fn beginResize(_: *Window, _: platform.Edge) void {}
    pub fn scale(self: *const Window) f32 {
        return self.scale_override orelse 1;
    }
    pub const vk_surface_extension: [*:0]const u8 = "VK_EXT_headless_surface";
    pub fn createSurface(_: *Window, _: vk.VkInstance, _: *vk.VkSurfaceKHR) vk.VkResult {
        return vk.VK_ERROR_INITIALIZATION_FAILED;
    }
    pub fn displayGpu(_: *Window) ?Node {
        return null;
    }
    pub fn clipFocus(_: *Window, _: u64, _: u64) void {}
    pub fn clipRequest(_: *Window, _: bool) platform.clip.Status {
        return .unavailable;
    }
    pub fn clipTake(_: *Window, _: *platform.clip.Result) bool {
        return false;
    }
    pub fn clipPending(_: *const Window) bool {
        return false;
    }
    pub fn clipCopy(_: *Window, _: bool, _: []const u8) bool {
        return false;
    }
    pub fn frameReady(_: *const Window) bool {
        return true;
    }
    pub fn requestFrame(_: *Window) !void {}
    pub fn cancelFrame(_: *Window) void {}
    /// Nothing can arrive; sleep the wait so a caller's loop does not spin.
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        if (!self.closing) return self.pumpDuringClose(timeout_ms);
    }
    pub fn pumpDuringClose(_: *Window, timeout_ms: i32) !void {
        _ = vk.poll(null, 0, timeout_ms);
    }
};

test "the null window queues what the program feeds it and nothing else" {
    var w = Window{};
    try std.testing.expectError(error.NoDisplay, w.init());
    w.input.button(1, 272, true, 3, 4);
    w.input.button(2, 272, false, 5, 6);
    try w.pump(0);
    try std.testing.expectEqual(input.Kind.button_press, w.input.next().?.kind);
    try std.testing.expectEqual(@as(f32, 5), w.input.next().?.x);
    try std.testing.expect(w.input.next() == null);
    for (0..input.capacity + 2) |_| w.input.button(0, 272, true, 0, 0);
    try std.testing.expectEqual(@as(u64, 2), w.input.dropped);
    w.toggleMaximized();
    try std.testing.expect(w.maximized and !w.clipCopy(false, "x") and w.clipRequest(false) == .unavailable);
    var surface: vk.VkSurfaceKHR = null;
    try std.testing.expect(w.createSurface(null, &surface) != vk.VK_SUCCESS and surface == null);
}
