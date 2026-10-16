//! Linux window host. One binary embeds the Wayland and X11 backends and
//! chooses at run time: `--platform`, else a set WAYLAND_DISPLAY, else DISPLAY.
//! The public Window owns the fields the UI writes. Each call copies them into
//! the live backend and copies them back, because listeners keep the backend's
//! own address.
const std = @import("std");
const log = @import("../log.zig");
const vk = @import("../c_ui.zig").api;
const platform = @import("window.zig");
const wayland = @import("wayland.zig");
const x11 = @import("x11.zig");
const clip = platform.clip;

pub const Keyboard = @import("xkb.zig").Keyboard;

const Active = enum { unset, wayland, x11 };

fn nonempty(name: [*:0]const u8) bool {
    const value = std.c.getenv(name) orelse return false;
    return value[0] != 0;
}

fn choose() !Active {
    if (platform.requestedPlatform()) |choice| return switch (choice) {
        .wayland => .wayland,
        .x11 => .x11,
    };
    if (nonempty("WAYLAND_DISPLAY")) return .wayland;
    if (nonempty("DISPLAY")) return .x11;
    log.err(.window, "xodb: no window system display is set\n", .{});
    return error.NoDisplay;
}

pub const Window = struct {
    wayland: wayland.Window = .{},
    x11: x11.Window = .{},
    active: Active = .unset,
    width: u32 = 1280,
    height: u32 = 800,
    dirty: bool = true,
    closing: bool = false,
    close_reason: platform.CloseReason = .none,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    mouse_down: bool = false,
    scroll: i32 = 0,
    maximized: bool = false,
    own_frame: bool = false,
    input: Keyboard = .{},
    scale_override: ?f32 = null,
    backing_scale: f32 = 1,
    pub const vk_surface_extension = wayland.Window.vk_surface_extension;

    fn write(self: *Window, dest: anytype) void {
        dest.width = self.width;
        dest.height = self.height;
        dest.dirty = self.dirty;
        dest.closing = self.closing;
        dest.close_reason = self.close_reason;
        dest.pointer_x = self.pointer_x;
        dest.pointer_y = self.pointer_y;
        dest.mouse_down = self.mouse_down;
        dest.scroll = self.scroll;
        dest.maximized = self.maximized;
        dest.own_frame = self.own_frame;
        dest.input = self.input;
        dest.scale_override = self.scale_override;
        dest.backing_scale = self.backing_scale;
    }
    fn read(self: *Window, src: anytype) void {
        self.width = src.width;
        self.height = src.height;
        self.dirty = src.dirty;
        self.closing = src.closing;
        self.close_reason = src.close_reason;
        self.pointer_x = src.pointer_x;
        self.pointer_y = src.pointer_y;
        self.mouse_down = src.mouse_down;
        self.scroll = src.scroll;
        self.maximized = src.maximized;
        self.own_frame = src.own_frame;
        self.input = src.input;
        self.scale_override = src.scale_override;
        self.backing_scale = src.backing_scale;
    }

    pub fn init(self: *Window) !void {
        const which = try choose();
        switch (which) {
            .wayland => {
                self.write(&self.wayland);
                try self.wayland.init();
            },
            .x11 => {
                self.write(&self.x11);
                try self.x11.init();
            },
            .unset => unreachable,
        }
        self.active = which;
        switch (which) {
            .wayland => self.read(&self.wayland),
            .x11 => self.read(&self.x11),
            .unset => unreachable,
        }
    }
    pub fn deinit(self: *Window) void {
        switch (self.active) {
            .wayland => self.wayland.deinit(),
            .x11 => self.x11.deinit(),
            .unset => {},
        }
        self.active = .unset;
        self.input = .{};
    }
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        switch (self.active) {
            .unset => return error.NoDisplay,
            .wayland => {
                self.write(&self.wayland);
                defer self.read(&self.wayland);
                try self.wayland.pump(timeout_ms);
            },
            .x11 => {
                self.write(&self.x11);
                defer self.read(&self.x11);
                try self.x11.pump(timeout_ms);
            },
        }
    }
    pub fn pumpDuringClose(self: *Window, timeout_ms: i32) !void {
        switch (self.active) {
            .unset => return error.NoDisplay,
            .wayland => {
                self.write(&self.wayland);
                defer self.read(&self.wayland);
                try self.wayland.pumpDuringClose(timeout_ms);
            },
            .x11 => {
                self.write(&self.x11);
                defer self.read(&self.x11);
                try self.x11.pumpDuringClose(timeout_ms);
            },
        }
    }
    pub fn scale(self: *const Window) f32 {
        return switch (self.active) {
            .wayland => self.wayland.scale(),
            .x11 => self.x11.scale(),
            .unset => self.scale_override orelse 1,
        };
    }
    pub fn bufferExtent(self: *const Window) platform.Extent {
        return switch (self.active) {
            .wayland => self.wayland.bufferExtent(),
            .x11 => self.x11.bufferExtent(),
            .unset => .{ .width = @max(1, self.width), .height = @max(1, self.height) },
        };
    }
    pub fn frameReady(self: *const Window) bool {
        return switch (self.active) {
            .wayland => self.wayland.frameReady(),
            .x11 => self.x11.frameReady(),
            .unset => true,
        };
    }
    pub fn requestFrame(self: *Window) !void {
        switch (self.active) {
            .wayland => try self.wayland.requestFrame(),
            .x11 => try self.x11.requestFrame(),
            .unset => {},
        }
    }
    pub fn cancelFrame(self: *Window) void {
        switch (self.active) {
            .wayland => self.wayland.cancelFrame(),
            .x11 => self.x11.cancelFrame(),
            .unset => {},
        }
    }
    pub fn setCursor(self: *Window, shape: platform.Cursor) void {
        switch (self.active) {
            .wayland => self.wayland.setCursor(shape),
            .x11 => self.x11.setCursor(shape),
            .unset => {},
        }
    }
    pub fn setOwnFrame(self: *Window, own: bool) void {
        self.own_frame = own;
        switch (self.active) {
            .wayland => self.wayland.setOwnFrame(own),
            .x11 => self.x11.setOwnFrame(own),
            .unset => {},
        }
    }
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        switch (self.active) {
            .wayland => self.wayland.setTitle(title),
            .x11 => self.x11.setTitle(title),
            .unset => {},
        }
    }
    pub fn setAppId(self: *Window, id: [*:0]const u8) void {
        switch (self.active) {
            .wayland => self.wayland.setAppId(id),
            .x11 => self.x11.setAppId(id),
            .unset => {},
        }
    }
    pub fn setMinSize(self: *Window, width: i32, height: i32) void {
        switch (self.active) {
            .wayland => self.wayland.setMinSize(width, height),
            .x11 => self.x11.setMinSize(width, height),
            .unset => {},
        }
    }
    pub fn minimize(self: *Window) void {
        switch (self.active) {
            .wayland => self.wayland.minimize(),
            .x11 => self.x11.minimize(),
            .unset => {},
        }
    }
    pub fn toggleMaximized(self: *Window) void {
        switch (self.active) {
            .wayland => {
                self.wayland.maximized = self.maximized;
                self.wayland.toggleMaximized();
                self.maximized = self.wayland.maximized;
            },
            .x11 => {
                self.x11.maximized = self.maximized;
                self.x11.toggleMaximized();
                self.maximized = self.x11.maximized;
            },
            .unset => {},
        }
    }
    pub fn beginMove(self: *Window) void {
        switch (self.active) {
            .wayland => self.wayland.beginMove(),
            .x11 => self.x11.beginMove(),
            .unset => {},
        }
    }
    pub fn beginResize(self: *Window, edge: platform.Edge) void {
        switch (self.active) {
            .wayland => self.wayland.beginResize(edge),
            .x11 => self.x11.beginResize(edge),
            .unset => {},
        }
    }
    pub fn clipFocus(self: *Window, destination: u64, epoch: u64) void {
        switch (self.active) {
            .wayland => self.wayland.clipFocus(destination, epoch),
            .x11 => self.x11.clipFocus(destination, epoch),
            .unset => {},
        }
    }
    pub fn clipRequest(self: *Window, primary: bool) clip.Status {
        return switch (self.active) {
            .wayland => self.wayland.clipRequest(primary),
            .x11 => self.x11.clipRequest(primary),
            .unset => .unavailable,
        };
    }
    pub fn clipTake(self: *Window, out: *clip.Result) bool {
        return switch (self.active) {
            .wayland => self.wayland.clipTake(out),
            .x11 => self.x11.clipTake(out),
            .unset => false,
        };
    }
    pub fn clipPending(self: *const Window) bool {
        return switch (self.active) {
            .wayland => self.wayland.clipPending(),
            .x11 => self.x11.clipPending(),
            .unset => false,
        };
    }
    pub fn clipCopy(self: *Window, primary: bool, bytes: []const u8) bool {
        return switch (self.active) {
            .wayland => self.wayland.clipCopy(primary, bytes),
            .x11 => self.x11.clipCopy(primary, bytes),
            .unset => false,
        };
    }
    pub fn displayFd(self: *Window) ?i32 {
        return switch (self.active) {
            .wayland => self.wayland.displayFd(),
            .x11 => self.x11.displayFd(),
            .unset => null,
        };
    }
    pub fn displayGpu(self: *Window) @typeInfo(@TypeOf(wayland.Window.displayGpu)).@"fn".return_type.? {
        return switch (self.active) {
            .wayland => self.wayland.displayGpu(),
            else => null,
        };
    }
    pub fn surfaceExtension(self: *const Window) [*:0]const u8 {
        return switch (self.active) {
            .x11 => x11.Window.vk_surface_extension,
            .wayland, .unset => vk_surface_extension,
        };
    }
    pub fn createSurface(self: *Window, instance: vk.VkInstance, surface: *vk.VkSurfaceKHR) vk.VkResult {
        return switch (self.active) {
            .wayland => self.wayland.createSurface(instance, surface),
            .x11 => self.x11.createSurface(instance, surface),
            .unset => vk.VK_ERROR_INITIALIZATION_FAILED,
        };
    }
};
