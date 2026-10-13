//! The seam between the interface and the window system. Rendering and UI
//! code import `Window` from here (and event types from input.zig) and nothing
//! else under platform/. build.zig picks the backend: -Dplatform.
//!
//! A backend is one file exporting `Window` and `Keyboard`. What the rest of
//! the program may use of them is listed in `comptime` below; units:
//!   width, height    content size in UI units, the units the UI lays out and
//!                    the renderer draws in. A resize sets them and `dirty`.
//!   scale()          device pixels per UI unit, as the window system reports it
//!   pointer_x/y      UI units from the content's top left
//!   scroll           whole text lines since the UI last cleared it, positive
//!                    towards the end of the content; one wheel notch is three
//!   input            key and button events (input.zig) in arrival order
//!   pump(ms)         wait up to ms (-1: until an event) and deliver events
//!   frameReady, requestFrame, cancelFrame
//!                    presentation pacing; a backend the swapchain paces
//!                    answers true and does nothing
//!   closing          set by the window system's close request, or by the UI
//!                    to close the window; `close_reason` says which
const std = @import("std");
const vk = @import("../c_ui.zig").api;
const backend = switch (@import("build_options").platform) {
    .wayland => @import("wayland.zig"),
    .cocoa => @import("cocoa.zig"),
    .null => @import("null.zig"),
};
pub const Window = backend.Window;
pub const Keyboard = backend.Keyboard;

pub const Cursor = enum { default, col_resize };
pub const CloseReason = enum { none, compositor_close, quit_key };
pub const Edge = enum { top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };
pub const min_ui_scale: f32 = 0.5;
pub const max_ui_scale: f32 = 4;

pub fn validateScale(value: f32) !f32 {
    if (!std.math.isFinite(value) or value < min_ui_scale or value > max_ui_scale) return error.InvalidUiScale;
    return value;
}

pub fn deviceExtent(logical: u32, scale: f32) u32 {
    const pixels = @ceil(@as(f64, @floatFromInt(logical)) * @as(f64, scale));
    return @max(1, @as(u32, @intFromFloat(@min(pixels, std.math.maxInt(u32)))));
}

/// Plain-text clipboard. A paste is asynchronous: `clipRequest` starts one for
/// the editor named by `clipFocus`, `clipTake` returns it once. `primary`
/// selects the select-to-copy selection where the window system has one.
pub const clip = struct {
    pub const limit = 4096;
    pub const Status = enum(u32) { idle, pending, ready, truncated, unavailable, timeout, failed };
    pub const Result = struct { destination: u64, epoch: u64, status: Status, size: usize, bytes: [limit]u8 };
};

comptime {
    for (.{
        .{ "width", u32 },           .{ "height", u32 },               .{ "dirty", bool },
        .{ "closing", bool },        .{ "close_reason", CloseReason }, .{ "pointer_x", f32 },
        .{ "pointer_y", f32 },       .{ "mouse_down", bool },          .{ "scroll", i32 },
        .{ "maximized", bool },      .{ "own_frame", bool },           .{ "input", Keyboard },
        .{ "scale_override", ?f32 },
    }) |field| if (@FieldType(Window, field[0]) != field[1]) @compileError("platform Window." ++ field[0]);
    for (.{
        "init",        "deinit",       "pump",        "pumpDuringClose", "scale",
        "frameReady",  "requestFrame", "cancelFrame", "setCursor",       "setOwnFrame",
        "setTitle",    "setAppId",     "setMinSize",  "minimize",        "toggleMaximized",
        "beginMove",   "beginResize",  "clipFocus",   "clipRequest",     "clipTake",
        "clipPending", "clipCopy",     "displayGpu",
    }) |name| if (!@hasDecl(Window, name)) @compileError("platform Window." ++ name);
    for (.{ "queue", "head", "count", "dropped", "keymap_errors", "focused", "focus_revision", "trace" }) |name|
        if (!@hasField(Keyboard, name)) @compileError("platform Keyboard." ++ name);
    for (.{ "next", "button", "tick", "timeoutMs", "mods", "heldShortcut" }) |name|
        if (!@hasDecl(Keyboard, name)) @compileError("platform Keyboard." ++ name);
    // Vulkan: the instance extension the window's surface needs, and the surface.
    if (@import("build_options").gui) {
        _ = @as([*:0]const u8, Window.vk_surface_extension);
        _ = @as(*const fn (*Window, vk.VkInstance, *vk.VkSurfaceKHR) vk.VkResult, &Window.createSurface);
    }
}

test {
    _ = backend;
}

test "UI scales are bounded and device extents round outward" {
    try std.testing.expectEqual(@as(f32, 0.5), try validateScale(0.5));
    try std.testing.expectEqual(@as(f32, 4), try validateScale(4));
    try std.testing.expectError(error.InvalidUiScale, validateScale(0.49));
    try std.testing.expectError(error.InvalidUiScale, validateScale(4.01));
    try std.testing.expectError(error.InvalidUiScale, validateScale(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 1920), deviceExtent(1280, 1.5));
    try std.testing.expectEqual(@as(u32, 2), deviceExtent(1, 1.5));
    try std.testing.expectEqual(std.math.maxInt(u32), deviceExtent(std.math.maxInt(u32), 4));
}
