const std = @import("std");
const c = @import("../c.zig").api;
const input = @import("input.zig");

/// Pointer images, as wp_cursor_shape_device_v1 shape values.
pub const Cursor = enum(u32) { default = 1, col_resize = 30 };

pub const Window = struct {
    display: *c.wl_display = undefined,
    registry: ?*c.wl_registry = null,
    clipboard: ?*c.xclip = null,
    last_input_serial: u32 = 0,
    compositor: ?*c.wl_compositor = null,
    wm: ?*c.xdg_wm_base = null,
    seat: ?*c.wl_seat = null,
    seat_name: u32 = 0,
    cursor_shapes: ?*c.wp_cursor_shape_manager_v1 = null,
    cursor_device: ?*c.wp_cursor_shape_device_v1 = null,
    cursor: Cursor = .default,
    pointer_serial: u32 = 0,
    pointer_inside: bool = false,
    /// Ordered key and button events; drain with `input.next()`.
    input: input.Keyboard = .{},
    keyboard: ?*c.wl_keyboard = null,
    pointer: ?*c.wl_pointer = null,
    surface: *c.wl_surface = undefined,
    xdg: ?*c.xdg_surface = null,
    top: ?*c.xdg_toplevel = null,
    width: u32 = 1280,
    height: u32 = 800,
    configured: bool = false,
    /// From the latest xdg_toplevel configure; the compositor decides it.
    maximized: bool = false,
    closing: bool = false,
    close_reason: enum { none, compositor_close, quit_key } = .none,
    dirty: bool = true,
    /// One compositor pacing callback for the last queued presentation. Hidden
    /// surfaces may never receive it until they become visible again.
    frame_callback: ?*c.wl_callback = null,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    mouse_down: bool = false,
    scroll: i32 = 0,
    scroll_remainder: i32 = 0,

    // Call on the final address: Wayland listeners retain this pointer.
    pub fn init(self: *Window) !void {
        self.input = input.Keyboard.init(null);
        self.input.trace = c.getenv("XODB_INPUT_TRACE") != null;
        errdefer self.input.deinit();
        self.display = c.wl_display_connect(null) orelse return error.WaylandUnavailable;
        errdefer c.wl_display_disconnect(self.display);
        self.clipboard = c.xclip_create(self.display);
        errdefer c.xclip_destroy(self.clipboard);
        self.registry = c.wl_display_get_registry(self.display);
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        if (c.wl_display_roundtrip(self.display) < 0) return error.WaylandDisconnected;
        if (self.compositor == null or self.wm == null) return error.WaylandGlobalsMissing;
        self.surface = c.wl_compositor_create_surface(self.compositor) orelse return error.SurfaceFailed;
        self.xdg = c.xdg_wm_base_get_xdg_surface(self.wm, self.surface);
        _ = c.xdg_surface_add_listener(self.xdg, &surface_listener, self);
        self.top = c.xdg_surface_get_toplevel(self.xdg);
        _ = c.xdg_toplevel_add_listener(self.top, &top_listener, self);
        c.xdg_toplevel_set_title(self.top, "xodb — hugs and kisses debugger");
        c.xdg_toplevel_set_app_id(self.top, "xodb");
        c.xdg_toplevel_set_min_size(self.top, 720, 480);
        c.wl_surface_commit(self.surface);
        while (!self.configured) if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDisconnected;
    }
    pub fn deinit(self: *Window) void {
        self.cancelFrame();
        self.dropSeat();
        if (self.cursor_shapes) |v| c.wp_cursor_shape_manager_v1_destroy(v);
        if (self.top) |v| c.xdg_toplevel_destroy(v);
        if (self.xdg) |v| c.xdg_surface_destroy(v);
        c.wl_surface_destroy(self.surface);
        if (self.wm) |v| c.xdg_wm_base_destroy(v);
        if (self.compositor) |v| c.wl_compositor_destroy(v);
        if (self.registry) |v| c.wl_registry_destroy(v);
        c.xclip_destroy(self.clipboard);
        c.wl_display_disconnect(self.display);
        self.input.deinit();
    }
    /// Releases the pointer, keyboard, and seat, and everything that hangs off them.
    fn dropSeat(self: *Window) void {
        self.dropPointer();
        self.dropKeyboard();
        if (self.seat) |v| {
            if (c.wl_seat_get_version(v) >= c.WL_SEAT_RELEASE_SINCE_VERSION) c.wl_seat_release(v) else c.wl_seat_destroy(v);
        }
        self.seat = null;
    }
    fn dropKeyboard(self: *Window) void {
        if (self.keyboard) |v| {
            if (c.wl_keyboard_get_version(v) >= c.WL_KEYBOARD_RELEASE_SINCE_VERSION) c.wl_keyboard_release(v) else c.wl_keyboard_destroy(v);
        }
        self.keyboard = null;
        self.input.seatRemoved();
        c.xclip_focus(self.clipboard, 0, 0);
    }
    fn dropPointer(self: *Window) void {
        if (self.cursor_device) |v| c.wp_cursor_shape_device_v1_destroy(v);
        self.cursor_device = null;
        if (self.pointer) |v| {
            if (c.wl_pointer_get_version(v) >= c.WL_POINTER_RELEASE_SINCE_VERSION) c.wl_pointer_release(v) else c.wl_pointer_destroy(v);
        }
        self.pointer = null;
        self.pointer_inside = false;
        self.mouse_down = false;
    }
    /// The cursor shape device belongs to one pointer; create it once both exist.
    fn attachCursor(self: *Window) void {
        if (self.cursor_device != null) return;
        const manager = self.cursor_shapes orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
        self.applyCursor();
    }
    /// Chooses the pointer image over this window. Without the cursor-shape
    /// protocol this does nothing and the compositor's cursor is left as it is.
    pub fn setCursor(self: *Window, shape: Cursor) void {
        if (shape == self.cursor) return;
        self.cursor = shape;
        self.applyCursor();
    }
    fn applyCursor(self: *Window) void {
        const device = self.cursor_device orelse return;
        if (self.pointer_inside) c.wp_cursor_shape_device_v1_set_shape(device, self.pointer_serial, @intFromEnum(self.cursor));
    }
    pub fn frameReady(self: *const Window) bool {
        return self.frame_callback == null;
    }
    /// Request immediately before the presentation's surface commit. A failed
    /// presentation must cancel this callback because it may never be committed.
    pub fn requestFrame(self: *Window) !void {
        std.debug.assert(self.frame_callback == null);
        const callback = c.wl_surface_frame(self.surface) orelse return error.FrameCallbackFailed;
        self.frame_callback = callback;
        _ = c.wl_callback_add_listener(callback, &frame_listener, self);
    }
    pub fn cancelFrame(self: *Window) void {
        if (self.frame_callback) |callback| c.wl_callback_destroy(callback);
        self.frame_callback = null;
    }
    pub fn pump(self: *Window, timeout_ms: i32) !void {
        if (c.xclip_tick(self.clipboard)) self.dirty = true;
        // Graphics libraries can read another queue on this display. Reserve a
        // read before polling: poll + dispatch can block after another reader
        // consumes the fd's readiness. Every reservation must be read or cancelled.
        while (c.wl_display_prepare_read(self.display) != 0) {
            if (std.c._errno().* != c.EAGAIN) return error.WaylandDisconnected;
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDisconnected;
            if (self.closing) return;
        }
        var prepared = true;
        defer if (prepared) c.wl_display_cancel_read(self.display);
        if (self.closing) return;
        var fd = c.pollfd{ .fd = c.wl_display_get_fd(self.display), .events = c.POLLIN, .revents = 0 };
        if (c.wl_display_flush(self.display) < 0) {
            if (std.c._errno().* != c.EAGAIN) return error.WaylandDisconnected;
            fd.events |= c.POLLOUT;
        }
        const wait_ms = if (c.xclip_busy(self.clipboard)) (if (timeout_ms < 0) 20 else @min(timeout_ms, 20)) else timeout_ms;
        const n = c.poll(&fd, 1, wait_ms);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) return;
            return error.WaylandPollFailed;
        }
        if (fd.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) return error.WaylandDisconnected;
        prepared = false;
        if (fd.revents & c.POLLIN != 0) {
            if (c.wl_display_read_events(self.display) < 0) return error.WaylandDisconnected;
        } else c.wl_display_cancel_read(self.display);
        if (fd.revents & c.POLLOUT != 0 and c.wl_display_flush(self.display) < 0 and std.c._errno().* != c.EAGAIN) return error.WaylandDisconnected;
        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDisconnected;
        if (c.xclip_tick(self.clipboard)) self.dirty = true;
    }
};
fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
fn window(data: ?*anyopaque) *Window {
    return @ptrCast(@alignCast(data.?));
}
fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const w = window(data);
    const s = std.mem.span(interface);
    if (std.mem.eql(u8, s, "wl_compositor")) w.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
    if (std.mem.eql(u8, s, "xdg_wm_base")) {
        w.wm = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1));
        _ = c.xdg_wm_base_add_listener(w.wm, &wm_listener, w);
    }
    if (std.mem.eql(u8, s, "wl_seat") and w.seat == null) {
        w.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 5)));
        w.seat_name = name;
        _ = c.wl_seat_add_listener(w.seat, &seat_listener, w);
    }
    if (std.mem.eql(u8, s, "wp_cursor_shape_manager_v1")) {
        w.cursor_shapes = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_cursor_shape_manager_v1_interface, 1));
        w.attachCursor();
    }
}
fn removed(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    const w = window(data);
    if (w.seat != null and name == w.seat_name) w.dropSeat();
}
fn ping(_: ?*anyopaque, wm: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(wm, serial);
}
fn configured(data: ?*anyopaque, surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    c.xdg_surface_ack_configure(surface, serial);
    window(data).configured = true;
    window(data).dirty = true;
}
pub fn hasState(states: []const u32, state: u32) bool {
    return std.mem.indexOfScalar(u32, states, state) != null;
}
fn resized(data: ?*anyopaque, _: ?*c.xdg_toplevel, width: i32, height: i32, states: ?*c.wl_array) callconv(.c) void {
    const w = window(data);
    const list: []const u32 = if (states) |s| (if (s.data) |p| @as([*]const u32, @ptrCast(@alignCast(p)))[0 .. s.size / 4] else &.{}) else &.{};
    w.maximized = hasState(list, c.XDG_TOPLEVEL_STATE_MAXIMIZED);
    if (width > 0) w.width = @intCast(width);
    if (height > 0) w.height = @intCast(height);
    w.dirty = true;
}
fn closed(data: ?*anyopaque, _: ?*c.xdg_toplevel) callconv(.c) void {
    window(data).closing = true;
    window(data).close_reason = .compositor_close;
}
fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, caps: u32) callconv(.c) void {
    const w = window(data);
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD == 0) {
        w.dropKeyboard();
    }
    if (caps & c.WL_SEAT_CAPABILITY_POINTER == 0) w.dropPointer();
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and w.keyboard == null) {
        w.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(w.keyboard, &keyboard_listener, w);
    }
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and w.pointer == null) {
        w.pointer = c.wl_seat_get_pointer(seat);
        _ = c.wl_pointer_add_listener(w.pointer, &pointer_listener, w);
        w.attachCursor();
    }
}
fn seatName(_: ?*anyopaque, _: ?*c.wl_seat, _: [*c]const u8) callconv(.c) void {}
fn keymap(data: ?*anyopaque, _: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    window(data).input.keymap(format, fd, size);
}
fn enter(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface, _: ?*c.wl_array) callconv(.c) void {
    window(data).input.enter();
}
fn leave(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    window(data).input.leave();
    c.xclip_focus(window(data).clipboard, 0, 0);
}
fn key(data: ?*anyopaque, _: ?*c.wl_keyboard, serial: u32, time: u32, code: u32, state: u32) callconv(.c) void {
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    window(data).last_input_serial = serial;
    window(data).input.key(time, code, pressed, now());
    if (pressed) window(data).dirty = true;
}
fn modifiers(data: ?*anyopaque, _: ?*c.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
    window(data).input.modifiers(depressed, latched, locked, group);
}
fn repeat(data: ?*anyopaque, _: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    window(data).input.repeatInfo(rate, delay);
}
fn pointerEnter(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, _: ?*c.wl_surface, x: i32, y: i32) callconv(.c) void {
    const w = window(data);
    w.pointer_x = @as(f32, @floatFromInt(x)) / 256;
    w.pointer_y = @as(f32, @floatFromInt(y)) / 256;
    // A cursor must be set on every enter; until then its image is undefined.
    w.pointer_serial = serial;
    w.pointer_inside = true;
    w.applyCursor();
}
fn pointerLeave(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: ?*c.wl_surface) callconv(.c) void {
    window(data).pointer_inside = false;
}
fn motion(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, x: i32, y: i32) callconv(.c) void {
    window(data).pointer_x = @as(f32, @floatFromInt(x)) / 256;
    window(data).pointer_y = @as(f32, @floatFromInt(y)) / 256;
    // Hover changes are detected by the workspace; motion alone redraws only while dragging.
    if (window(data).mouse_down) window(data).dirty = true;
}
fn button(data: ?*anyopaque, _: ?*c.wl_pointer, serial: u32, time: u32, code: u32, state: u32) callconv(.c) void {
    const w = window(data);
    const pressed = state == c.WL_POINTER_BUTTON_STATE_PRESSED;
    // Every edge is queued, so a press and release in one dispatch is still a click.
    w.last_input_serial = serial;
    w.input.button(time, code, pressed, w.pointer_x, w.pointer_y);
    if (code == 272) w.mouse_down = pressed;
    w.dirty = true;
}
fn axis(data: ?*anyopaque, _: ?*c.wl_pointer, _: u32, direction: u32, value: i32) callconv(.c) void {
    if (direction != c.WL_POINTER_AXIS_VERTICAL_SCROLL) return;
    // wl_fixed distance: one wheel notch is 15.0 and scrolls three lines; touchpads send fractions.
    const w = window(data);
    w.scroll_remainder += value;
    const lines = @divTrunc(w.scroll_remainder, 5 * 256);
    w.scroll_remainder -= lines * 5 * 256;
    w.scroll += lines;
    if (lines != 0) w.dirty = true;
}
fn frame(_: ?*anyopaque, _: ?*c.wl_pointer) callconv(.c) void {}
fn axisSource(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32) callconv(.c) void {}
fn axisStop(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn axisDiscrete(_: ?*anyopaque, _: ?*c.wl_pointer, _: u32, _: i32) callconv(.c) void {}
const registry_listener = c.wl_registry_listener{ .global = global, .global_remove = removed };
const wm_listener = c.xdg_wm_base_listener{ .ping = ping };
const surface_listener = c.xdg_surface_listener{ .configure = configured };
const top_listener = c.xdg_toplevel_listener{ .configure = resized, .close = closed, .configure_bounds = null, .wm_capabilities = null };
const seat_listener = c.wl_seat_listener{ .capabilities = seatCapabilities, .name = seatName };
const keyboard_listener = c.wl_keyboard_listener{ .keymap = keymap, .enter = enter, .leave = leave, .key = key, .modifiers = modifiers, .repeat_info = repeat };
const pointer_listener = c.wl_pointer_listener{ .enter = pointerEnter, .leave = pointerLeave, .motion = motion, .button = button, .axis = axis, .frame = frame, .axis_source = axisSource, .axis_stop = axisStop, .axis_discrete = axisDiscrete, .axis_value120 = null, .axis_relative_direction = null };

fn frameDone(data: ?*anyopaque, callback: ?*c.wl_callback, _: u32) callconv(.c) void {
    const w = window(data);
    std.debug.assert(w.frame_callback == callback);
    w.cancelFrame();
    // Readiness alone is not damage. Preserve the idle redraw rate; pending
    // input, animation and target changes already retain their dirty state.
}
const frame_listener = c.wl_callback_listener{ .done = frameDone };
