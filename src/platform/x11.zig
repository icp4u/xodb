//! X11 backend of window.zig. libxcb, libxcb-xinput, libxcb-randr and
//! libxkbcommon-x11 are loaded at run time, so a Wayland-only machine still
//! starts. The first frame is one connection, one batched atom and resource
//! round trip, then the window is mapped. Keyboard and pointer setup wait
//! until that frame has been accepted.
const std = @import("std");
const log = @import("../log.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // as in c_ui.zig
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("VK_USE_PLATFORM_XCB_KHR", "1");
    @cInclude("dlfcn.h");
    @cInclude("stdlib.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/randr.h");
    @cInclude("xcb/xinput.h");
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
    @cInclude("vulkan/vulkan.h");
});
const vk = @import("../c_ui.zig").api;
const phases = @import("../startup_phases.zig");
const platform = @import("window.zig");
const clip = platform.clip;
const Node = @import("../render/vk_select.zig").Node;
pub const Keyboard = @import("xkb.zig").Keyboard;

const atom_names = [_][]const u8{
    "WM_PROTOCOLS",
    "WM_DELETE_WINDOW",
    "_NET_WM_NAME",
    "UTF8_STRING",
    "CLIPBOARD",
    "TARGETS",
    "INCR",
    "_NET_WM_STATE",
    "_NET_WM_STATE_MAXIMIZED_VERT",
    "_NET_WM_STATE_MAXIMIZED_HORZ",
    "_NET_WM_MOVERESIZE",
    "WM_CHANGE_STATE",
    "_MOTIF_WM_HINTS",
    "XODB_SELECTION",
};

const Atoms = struct {
    wm_protocols: u32 = 0,
    wm_delete: u32 = 0,
    net_wm_name: u32 = 0,
    utf8: u32 = 0,
    clipboard: u32 = 0,
    targets: u32 = 0,
    incr: u32 = 0,
    net_wm_state: u32 = 0,
    max_vert: u32 = 0,
    max_horz: u32 = 0,
    moveresize: u32 = 0,
    wm_change_state: u32 = 0,
    motif: u32 = 0,
    xodb_selection: u32 = 0,
};

fn enumInt(value: anytype) u32 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intCast(@intFromEnum(value)),
        else => @intCast(value),
    };
}

fn monotonic() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn must(handle: *anyopaque, name: [*:0]const u8, comptime T: type) !T {
    const found = c.dlsym(handle, name) orelse return error.X11Unavailable;
    return @as(T, @ptrCast(@alignCast(found)));
}

const Core = struct {
    connect: *const fn (?[*:0]const u8, *c_int) callconv(.c) *c.xcb_connection_t,
    disconnect: *const fn (*c.xcb_connection_t) callconv(.c) void,
    has_error: *const fn (*c.xcb_connection_t) callconv(.c) c_int,
    flush: *const fn (*c.xcb_connection_t) callconv(.c) c_int,
    get_setup: *const fn (*c.xcb_connection_t) callconv(.c) *const c.xcb_setup_t,
    roots: *const fn (*const c.xcb_setup_t) callconv(.c) c.xcb_screen_iterator_t,
    screen_next: *const fn (*c.xcb_screen_iterator_t) callconv(.c) void,
    generate_id: *const fn (*c.xcb_connection_t) callconv(.c) u32,
    get_fd: *const fn (*c.xcb_connection_t) callconv(.c) c_int,
    intern_atom: *const fn (*c.xcb_connection_t, u8, u16, [*]const u8) callconv(.c) c.xcb_intern_atom_cookie_t,
    intern_reply: *const fn (*c.xcb_connection_t, c.xcb_intern_atom_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_intern_atom_reply_t,
    get_property: *const fn (*c.xcb_connection_t, u8, u32, u32, u32, u32, u32) callconv(.c) c.xcb_get_property_cookie_t,
    property_reply: *const fn (*c.xcb_connection_t, c.xcb_get_property_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_get_property_reply_t,
    create_window: *const fn (*c.xcb_connection_t, u8, u32, u32, i16, i16, u16, u16, u16, u16, u32, u32, *const anyopaque) callconv(.c) c.xcb_void_cookie_t,
    change_property: *const fn (*c.xcb_connection_t, u8, u32, u32, u32, u8, u32, *const anyopaque) callconv(.c) c.xcb_void_cookie_t,
    change_attributes: *const fn (*c.xcb_connection_t, u32, u32, *const anyopaque) callconv(.c) c.xcb_void_cookie_t,
    map_window: *const fn (*c.xcb_connection_t, u32) callconv(.c) c.xcb_void_cookie_t,
    send_event: *const fn (*c.xcb_connection_t, u8, u32, u32, [*]const u8) callconv(.c) c.xcb_void_cookie_t,
    set_selection_owner: *const fn (*c.xcb_connection_t, u32, u32, u32) callconv(.c) c.xcb_void_cookie_t,
    convert_selection: *const fn (*c.xcb_connection_t, u32, u32, u32, u32, u32) callconv(.c) c.xcb_void_cookie_t,
    delete_property: *const fn (*c.xcb_connection_t, u32, u32) callconv(.c) c.xcb_void_cookie_t,
    request_check: *const fn (*c.xcb_connection_t, c.xcb_void_cookie_t) callconv(.c) ?*c.xcb_generic_error_t,
    poll_event: *const fn (*c.xcb_connection_t) callconv(.c) ?*c.xcb_generic_event_t,
    get_input_focus: *const fn (*c.xcb_connection_t) callconv(.c) c.xcb_get_input_focus_cookie_t,
    input_focus_reply: *const fn (*c.xcb_connection_t, c.xcb_get_input_focus_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_get_input_focus_reply_t,
    extension_data: *const fn (*c.xcb_connection_t, *c.xcb_extension_t) callconv(.c) ?*const c.xcb_query_extension_reply_t,
};

const Xi = struct {
    id: *c.xcb_extension_t,
    query_version: *const fn (*c.xcb_connection_t, u16, u16) callconv(.c) c.xcb_input_xi_query_version_cookie_t,
    query_reply: *const fn (*c.xcb_connection_t, c.xcb_input_xi_query_version_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_input_xi_query_version_reply_t,
    select_events: *const fn (*c.xcb_connection_t, u32, u16, *const c.xcb_input_event_mask_t) callconv(.c) c.xcb_void_cookie_t,
};

const Randr = struct {
    id: *c.xcb_extension_t,
    resources: *const fn (*c.xcb_connection_t, u32) callconv(.c) c.xcb_randr_get_screen_resources_current_cookie_t,
    resources_reply: *const fn (*c.xcb_connection_t, c.xcb_randr_get_screen_resources_current_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_randr_get_screen_resources_current_reply_t,
    output_info: *const fn (*c.xcb_connection_t, u32, u32) callconv(.c) c.xcb_randr_get_output_info_cookie_t,
    output_reply: *const fn (*c.xcb_connection_t, c.xcb_randr_get_output_info_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_randr_get_output_info_reply_t,
    crtc_info: *const fn (*c.xcb_connection_t, u32, u32) callconv(.c) c.xcb_randr_get_crtc_info_cookie_t,
    crtc_reply: *const fn (*c.xcb_connection_t, c.xcb_randr_get_crtc_info_cookie_t, ?*?*c.xcb_generic_error_t) callconv(.c) ?*c.xcb_randr_get_crtc_info_reply_t,
};

const XkbX11 = struct {
    setup: *const fn (*c.xcb_connection_t, u16, u16, c_uint, ?*u16, ?*u16, ?*u8, ?*u8) callconv(.c) c_int,
    device: *const fn (*c.xcb_connection_t) callconv(.c) i32,
    keymap: *const fn (*anyopaque, *c.xcb_connection_t, i32, c_uint) callconv(.c) ?*anyopaque,
    state: *const fn (*anyopaque, *c.xcb_connection_t, i32) callconv(.c) ?*anyopaque,
};

var core_ready = false;
var core_handle: ?*anyopaque = null;
var api: Core = undefined;
var xi_api: ?Xi = null;
var randr_api: ?Randr = null;
var xkb_api: ?XkbX11 = null;

fn loadCore() !void {
    if (core_ready) return;
    const handle = c.dlopen("libxcb.so.1", c.RTLD_NOW | c.RTLD_LOCAL) orelse {
        log.err(.window, "xodb: X11 was selected and libxcb is not installed\n", .{});
        return error.X11Unavailable;
    };
    errdefer if (!core_ready) {
        log.err(.window, "xodb: X11 was selected and libxcb did not load\n", .{});
        _ = c.dlclose(handle);
    };
    api = .{
        .connect = try must(handle, "xcb_connect", @TypeOf(api.connect)),
        .disconnect = try must(handle, "xcb_disconnect", @TypeOf(api.disconnect)),
        .has_error = try must(handle, "xcb_connection_has_error", @TypeOf(api.has_error)),
        .flush = try must(handle, "xcb_flush", @TypeOf(api.flush)),
        .get_setup = try must(handle, "xcb_get_setup", @TypeOf(api.get_setup)),
        .roots = try must(handle, "xcb_setup_roots_iterator", @TypeOf(api.roots)),
        .screen_next = try must(handle, "xcb_screen_next", @TypeOf(api.screen_next)),
        .generate_id = try must(handle, "xcb_generate_id", @TypeOf(api.generate_id)),
        .get_fd = try must(handle, "xcb_get_file_descriptor", @TypeOf(api.get_fd)),
        .intern_atom = try must(handle, "xcb_intern_atom", @TypeOf(api.intern_atom)),
        .intern_reply = try must(handle, "xcb_intern_atom_reply", @TypeOf(api.intern_reply)),
        .get_property = try must(handle, "xcb_get_property", @TypeOf(api.get_property)),
        .property_reply = try must(handle, "xcb_get_property_reply", @TypeOf(api.property_reply)),
        .create_window = try must(handle, "xcb_create_window", @TypeOf(api.create_window)),
        .change_property = try must(handle, "xcb_change_property", @TypeOf(api.change_property)),
        .change_attributes = try must(handle, "xcb_change_window_attributes", @TypeOf(api.change_attributes)),
        .map_window = try must(handle, "xcb_map_window", @TypeOf(api.map_window)),
        .send_event = try must(handle, "xcb_send_event", @TypeOf(api.send_event)),
        .set_selection_owner = try must(handle, "xcb_set_selection_owner", @TypeOf(api.set_selection_owner)),
        .convert_selection = try must(handle, "xcb_convert_selection", @TypeOf(api.convert_selection)),
        .delete_property = try must(handle, "xcb_delete_property", @TypeOf(api.delete_property)),
        .request_check = try must(handle, "xcb_request_check", @TypeOf(api.request_check)),
        .poll_event = try must(handle, "xcb_poll_for_event", @TypeOf(api.poll_event)),
        .get_input_focus = try must(handle, "xcb_get_input_focus", @TypeOf(api.get_input_focus)),
        .input_focus_reply = try must(handle, "xcb_get_input_focus_reply", @TypeOf(api.input_focus_reply)),
        .extension_data = try must(handle, "xcb_get_extension_data", @TypeOf(api.extension_data)),
    };
    core_handle = handle;
    core_ready = true;
}

fn abandon(handle: *anyopaque) void {
    _ = c.dlclose(handle);
}

fn loadXi() ?Xi {
    if (xi_api) |got| return got;
    const handle = c.dlopen("libxcb-xinput.so.0", c.RTLD_NOW | c.RTLD_LOCAL) orelse return null;
    const loaded: Xi = .{
        .id = must(handle, "xcb_input_id", *c.xcb_extension_t) catch return fail(Xi, handle),
        .query_version = must(handle, "xcb_input_xi_query_version", @TypeOf(@as(Xi, undefined).query_version)) catch return fail(Xi, handle),
        .query_reply = must(handle, "xcb_input_xi_query_version_reply", @TypeOf(@as(Xi, undefined).query_reply)) catch return fail(Xi, handle),
        .select_events = must(handle, "xcb_input_xi_select_events", @TypeOf(@as(Xi, undefined).select_events)) catch return fail(Xi, handle),
    };
    xi_api = loaded;
    return loaded;
}

fn loadRandr() ?Randr {
    if (randr_api) |got| return got;
    const handle = c.dlopen("libxcb-randr.so.0", c.RTLD_NOW | c.RTLD_LOCAL) orelse return null;
    const loaded: Randr = .{
        .id = must(handle, "xcb_randr_id", *c.xcb_extension_t) catch return fail(Randr, handle),
        .resources = must(handle, "xcb_randr_get_screen_resources_current", @TypeOf(@as(Randr, undefined).resources)) catch return fail(Randr, handle),
        .resources_reply = must(handle, "xcb_randr_get_screen_resources_current_reply", @TypeOf(@as(Randr, undefined).resources_reply)) catch return fail(Randr, handle),
        .output_info = must(handle, "xcb_randr_get_output_info", @TypeOf(@as(Randr, undefined).output_info)) catch return fail(Randr, handle),
        .output_reply = must(handle, "xcb_randr_get_output_info_reply", @TypeOf(@as(Randr, undefined).output_reply)) catch return fail(Randr, handle),
        .crtc_info = must(handle, "xcb_randr_get_crtc_info", @TypeOf(@as(Randr, undefined).crtc_info)) catch return fail(Randr, handle),
        .crtc_reply = must(handle, "xcb_randr_get_crtc_info_reply", @TypeOf(@as(Randr, undefined).crtc_reply)) catch return fail(Randr, handle),
    };
    randr_api = loaded;
    return loaded;
}

fn loadXkb() ?XkbX11 {
    if (xkb_api) |got| return got;
    const handle = c.dlopen("libxkbcommon-x11.so.0", c.RTLD_NOW | c.RTLD_LOCAL) orelse return null;
    const loaded: XkbX11 = .{
        .setup = must(handle, "xkb_x11_setup_xkb_extension", @TypeOf(@as(XkbX11, undefined).setup)) catch return fail(XkbX11, handle),
        .device = must(handle, "xkb_x11_get_core_keyboard_device_id", @TypeOf(@as(XkbX11, undefined).device)) catch return fail(XkbX11, handle),
        .keymap = must(handle, "xkb_x11_keymap_new_from_device", @TypeOf(@as(XkbX11, undefined).keymap)) catch return fail(XkbX11, handle),
        .state = must(handle, "xkb_x11_state_new_from_device", @TypeOf(@as(XkbX11, undefined).state)) catch return fail(XkbX11, handle),
    };
    xkb_api = loaded;
    return loaded;
}

/// Drops a library that did not export the symbols its backend needs.
fn fail(comptime T: type, handle: *anyopaque) ?T {
    abandon(handle);
    return null;
}

/// `Xft.dpi` divided by 96. The key is at the start of a line. Missing, or a
/// value outside 36..960, is null so the caller can try the output size.
pub fn parseDpi(text: []const u8) ?f32 {
    var rest = text;
    while (rest.len > 0) {
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trim(u8, rest[0..line_end], " \t\r");
        rest = if (line_end < rest.len) rest[line_end + 1 ..] else rest[rest.len..];
        if (!std.mem.startsWith(u8, line, "Xft.dpi")) continue;
        var i: usize = "Xft.dpi".len;
        if (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != ':') continue;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < line.len and line[i] == ':') i += 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        const token = std.mem.trim(u8, line[i..], " \t\r");
        const end = std.mem.indexOfAny(u8, token, " \t") orelse token.len;
        if (end == 0) return null;
        const dpi = std.fmt.parseFloat(f32, token[0..end]) catch return null;
        if (!std.math.isFinite(dpi) or dpi < 36 or dpi > 960) return null;
        return dpi / 96;
    }
    return null;
}

fn propertyBytes(reply: *const c.xcb_get_property_reply_t) []const u8 {
    if (reply.format != 8 or reply.value_len == 0) return "";
    const raw: [*]const u8 = @ptrCast(reply);
    const start = @sizeOf(c.xcb_get_property_reply_t);
    const total = 32 + @as(usize, reply.length) * 4;
    if (start >= total) return "";
    const len = @min(@as(usize, reply.value_len), total - start);
    return raw[start..][0..len];
}

const Paste = struct {
    destination: u64 = 0,
    epoch: u64 = 0,
    status: clip.Status = .idle,
    size: usize = 0,
    bytes: [clip.limit]u8 = undefined,
    owned: [clip.limit]u8 = undefined,
    owned_len: usize = 0,
    offer: bool = false,
};

pub const Window = struct {
    conn: ?*c.xcb_connection_t = null,
    window: u32 = 0,
    root: u32 = 0,
    visual: u32 = 0,
    ready: bool = false,
    width: u32 = 1280,
    height: u32 = 800,
    pixels_w: u32 = 1280,
    pixels_h: u32 = 800,
    backing_scale: f32 = 1,
    effective_scale: f32 = 1,
    reported_scale: f32 = 1,
    applied_override: ?f32 = null,
    own_frame: bool = false,
    maximized: bool = false,
    closing: bool = false,
    close_reason: platform.CloseReason = .none,
    dirty: bool = true,
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    mouse_down: bool = false,
    scroll: i32 = 0,
    scale_override: ?f32 = null,
    input: Keyboard = .{},
    cursor: platform.Cursor = .default,
    atoms: Atoms = .{},
    event_mask: u32 = 0,
    input_ready: bool = false,
    xi_opcode: u8 = 0,
    core_pointer: bool = false,
    down: std.StaticBitSet(256) = .initEmpty(),
    /// A key arrived for this window during the current pump.
    keyed: bool = false,
    /// A normal FocusOut arrived and has not been applied yet.
    lost_focus: bool = false,
    last_time: u32 = 0,
    root_x: i32 = 0,
    root_y: i32 = 0,
    last_button: u32 = 1,
    /// Paste listens here so the window connection's present path cannot eat the reply.
    clip_conn: ?*c.xcb_connection_t = null,
    clip_window: u32 = 0,
    minimum_ui: [2]i32 = .{ @import("../look.zig").minimum.width, @import("../look.zig").minimum.height },
    title: [192]u8 = @splat(0),
    title_len: usize = 0,
    app_id: [128]u8 = @splat(0),
    app_len: usize = 0,
    paste: Paste = .{},

    pub const vk_surface_extension: [*:0]const u8 = "VK_KHR_xcb_surface";
    pub fn surfaceExtension(_: *const Window) [*:0]const u8 {
        return vk_surface_extension;
    }

    pub fn init(self: *Window) !void {
        self.input = Keyboard.init(null);
        self.input.trace = c.getenv("XODB_INPUT_TRACE") != null;
        errdefer self.input.deinit();
        phases.begin(.connect);
        errdefer phases.end(.connect);
        try loadCore();
        var screen: c_int = 0;
        const conn = api.connect(null, &screen);
        self.conn = conn;
        errdefer self.dropConn();
        if (api.has_error(conn) != 0) {
            log.err(.window, "xodb: X11 was selected and the display connection failed\n", .{});
            return error.X11Unavailable;
        }
        const setup = api.get_setup(conn);
        var iter = api.roots(setup);
        var left = screen;
        while (left > 0 and iter.rem > 1) : (left -= 1) api.screen_next(&iter);
        if (iter.rem < 1 or iter.data == null) return error.X11Disconnected;
        const screen_info: *const c.xcb_screen_t = @ptrCast(@alignCast(iter.data.?));
        self.root = screen_info.root;
        self.visual = screen_info.root_visual;
        var cookies: [atom_names.len]c.xcb_intern_atom_cookie_t = undefined;
        for (atom_names, 0..) |name, i| cookies[i] = api.intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const resource_cookie = api.get_property(conn, 0, self.root, enumInt(c.XCB_ATOM_RESOURCE_MANAGER), 0, 0, 2048);
        _ = api.flush(conn);
        var values: [atom_names.len]u32 = undefined;
        for (cookies, 0..) |cookie, i| {
            const reply = api.intern_reply(conn, cookie, null) orelse return error.X11Disconnected;
            defer c.free(@ptrCast(reply));
            if (reply.atom == 0) return error.X11Disconnected;
            values[i] = reply.atom;
        }
        self.atoms = .{
            .wm_protocols = values[0],
            .wm_delete = values[1],
            .net_wm_name = values[2],
            .utf8 = values[3],
            .clipboard = values[4],
            .targets = values[5],
            .incr = values[6],
            .net_wm_state = values[7],
            .max_vert = values[8],
            .max_horz = values[9],
            .moveresize = values[10],
            .wm_change_state = values[11],
            .motif = values[12],
            .xodb_selection = values[13],
        };
        const resource = api.property_reply(conn, resource_cookie, null);
        defer if (resource) |reply| c.free(@ptrCast(reply));
        if (api.has_error(conn) != 0) return error.X11Disconnected;
        const resource_text: ?[]const u8 = if (resource) |reply| propertyBytes(reply) else null;
        phases.end(.connect);
        phases.begin(.window);
        errdefer phases.end(.window);
        try self.finishWindow(resource_text);
        phases.end(.window);
        self.ready = true;
    }

    fn dropConn(self: *Window) void {
        if (self.clip_conn) |conn| api.disconnect(conn);
        self.clip_conn = null;
        self.clip_window = 0;
        if (self.conn) |conn| api.disconnect(conn);
        self.conn = null;
    }

    fn finishWindow(self: *Window, resource_text: ?[]const u8) !void {
        const reported = if (resource_text) |text| parseDpi(text) orelse self.randrScale() orelse 1 else self.randrScale() orelse 1;
        const bounded_reported = std.math.clamp(reported, platform.min_ui_scale, platform.max_ui_scale);
        const effective = std.math.clamp(self.scale_override orelse bounded_reported, platform.min_ui_scale, platform.max_ui_scale);
        self.reported_scale = bounded_reported;
        self.applied_override = self.scale_override;
        self.effective_scale = effective;
        self.backing_scale = 1;
        self.pixels_w = platform.deviceExtent(self.width, effective);
        self.pixels_h = platform.deviceExtent(self.height, effective);
        self.width = platform.uiExtent(self.pixels_w, effective);
        self.height = platform.uiExtent(self.pixels_h, effective);
        if (self.title_len == 0) self.storeTitle("xodb — hugs and kisses debugger");
        if (self.app_len == 0) self.storeApp("xodb");
        const conn = self.conn.?;
        self.window = api.generate_id(conn);
        self.event_mask = enumInt(c.XCB_EVENT_MASK_KEY_PRESS) | enumInt(c.XCB_EVENT_MASK_KEY_RELEASE) | enumInt(c.XCB_EVENT_MASK_STRUCTURE_NOTIFY) | enumInt(c.XCB_EVENT_MASK_FOCUS_CHANGE) | enumInt(c.XCB_EVENT_MASK_EXPOSURE);
        const values = [_]u32{ 0, self.event_mask };
        _ = api.create_window(conn, 0, self.window, self.root, 0, 0, saturate16(self.pixels_w), saturate16(self.pixels_h), 0, @intCast(enumInt(c.XCB_WINDOW_CLASS_INPUT_OUTPUT)), self.visual, enumInt(c.XCB_CW_BACK_PIXMAP) | enumInt(c.XCB_CW_EVENT_MASK), &values);
        self.putProtocols();
        self.putTitle();
        self.putClass();
        self.putHints();
        self.putSizeHints();
        self.putMotif();
        _ = api.map_window(conn, self.window);
        _ = api.flush(conn);
        if (api.has_error(conn) != 0) return error.X11Disconnected;
        log.debug(.window, "ui scale effective={d:.2} reported={d:.2} override={s}\n", .{ effective, bounded_reported, if (self.scale_override != null) "yes" else "no" });
    }

    fn saturate16(value: u32) u16 {
        return @intCast(@min(value, std.math.maxInt(u16)));
    }

    fn randrScale(self: *Window) ?f32 {
        const rr = loadRandr() orelse return null;
        const conn = self.conn orelse return null;
        const ext = api.extension_data(conn, rr.id) orelse return null;
        if (ext.present == 0) return null;
        const cookie = rr.resources(conn, self.root);
        const reply = rr.resources_reply(conn, cookie, null) orelse return null;
        defer c.free(@ptrCast(reply));
        if (reply.num_outputs == 0 or reply.num_crtcs > 64) return null;
        const raw: [*]const u8 = @ptrCast(reply);
        const off = @sizeOf(c.xcb_randr_get_screen_resources_current_reply_t) + @as(usize, reply.num_crtcs) * 4;
        const n: usize = @min(reply.num_outputs, 16);
        const total = 32 + @as(usize, reply.length) * 4;
        if (off + n * 4 > total) return null;
        const outputs: [*]const u32 = @ptrCast(@alignCast(raw + off));
        var cookies: [16]c.xcb_randr_get_output_info_cookie_t = undefined;
        for (0..n) |i| cookies[i] = rr.output_info(conn, outputs[i], reply.config_timestamp);
        var chosen_crtc: u32 = 0;
        var chosen_mm: u32 = 0;
        for (0..n) |i| {
            const info = rr.output_reply(conn, cookies[i], null) orelse continue;
            defer c.free(@ptrCast(info));
            if (chosen_crtc != 0) continue;
            if (info.connection != @as(u8, @intCast(enumInt(c.XCB_RANDR_CONNECTION_CONNECTED))) or info.crtc == 0 or info.mm_width == 0) continue;
            chosen_crtc = info.crtc;
            chosen_mm = info.mm_width;
        }
        if (chosen_crtc == 0 or chosen_mm == 0) return null;
        const crtc_cookie = rr.crtc_info(conn, chosen_crtc, reply.config_timestamp);
        const crtc = rr.crtc_reply(conn, crtc_cookie, null) orelse return null;
        defer c.free(@ptrCast(crtc));
        if (crtc.width == 0) return null;
        const dpi = @as(f32, @floatFromInt(crtc.width)) * 25.4 / @as(f32, @floatFromInt(chosen_mm));
        const from_output = dpi / 96;
        if (!std.math.isFinite(from_output)) return null;
        return from_output;
    }

    pub fn deinit(self: *Window) void {
        if (!self.ready) return;
        self.ready = false;
        self.input.deinit();
        self.dropConn();
    }

    pub fn pump(self: *Window, timeout_ms: i32) !void {
        return self.pumpUntil(timeout_ms, false);
    }
    pub fn pumpDuringClose(self: *Window, timeout_ms: i32) !void {
        return self.pumpUntil(timeout_ms, true);
    }
    fn pumpUntil(self: *Window, timeout_ms: i32, draining: bool) !void {
        if (!self.ready) return error.X11Disconnected;
        if (phases.finished(.draw) and !self.input_ready) self.setupInput();
        self.applyOverride();
        self.keyed = false;
        self.lost_focus = false;
        defer self.finishFocus();
        try self.drain();
        self.drainClip();
        if (self.closing and !draining) return;
        var polled = c.pollfd{ .fd = api.get_fd(self.conn.?), .events = c.POLLIN, .revents = 0 };
        const n = c.poll(&polled, 1, timeout_ms);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) return;
            return error.X11PollFailed;
        }
        if ((polled.revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL)) != 0) return error.X11Disconnected;
        try self.drain();
        self.drainClip();
    }

    fn applyOverride(self: *Window) void {
        if (self.scale_override == null and self.applied_override == null) return;
        const same = if (self.scale_override) |next| if (self.applied_override) |prev| next == prev else false else self.applied_override == null;
        if (same) return;
        self.applied_override = self.scale_override;
        const effective = std.math.clamp(self.scale_override orelse self.reported_scale, platform.min_ui_scale, platform.max_ui_scale);
        if (@abs(effective - self.effective_scale) < 0.001) return;
        self.effective_scale = effective;
        self.width = platform.uiExtent(self.pixels_w, effective);
        self.height = platform.uiExtent(self.pixels_h, effective);
        self.dirty = true;
        self.putSizeHints();
    }

    fn finishFocus(self: *Window) void {
        // The server only delivers keys to the focused window. A FocusOut in
        // the same pump must not make the UI drop that key, and must not wipe
        // the modifier mask before a later key in the pump is translated.
        if (self.keyed) {
            self.input.focused = true;
            self.lost_focus = false;
            return;
        }
        if (self.lost_focus) self.input.leave();
    }

    fn drain(self: *Window) !void {
        const conn = self.conn orelse return error.X11Disconnected;
        while (api.poll_event(conn)) |event| {
            defer c.free(@ptrCast(event));
            self.one(event);
        }
        if (api.has_error(conn) != 0) return error.X11Disconnected;
    }
    /// SelectionNotify for a paste arrives on the requestor's connection.
    /// The short wait can end first, so the main pump keeps reading it.
    fn drainClip(self: *Window) void {
        const conn = self.clip_conn orelse return;
        while (api.poll_event(conn)) |event| {
            defer c.free(@ptrCast(event));
            const kind = event.response_type & 0x7f;
            if (kind == @as(u8, @intCast(c.XCB_SELECTION_NOTIFY))) self.onSelectionNotify(@ptrCast(event));
        }
        // A lost SelectionNotify still leaves the owner's property on this window.
        if (self.paste.status == .pending) self.pollClipProperty();
    }

    fn one(self: *Window, event: *c.xcb_generic_event_t) void {
        const kind = event.response_type & 0x7f;
        if (kind == 0) return;
        switch (kind) {
            c.XCB_KEY_PRESS, c.XCB_KEY_RELEASE => self.onKey(@ptrCast(event), kind == c.XCB_KEY_PRESS),
            c.XCB_BUTTON_PRESS, c.XCB_BUTTON_RELEASE => if (self.core_pointer) self.onCoreButton(@ptrCast(event), kind == c.XCB_BUTTON_PRESS),
            c.XCB_MOTION_NOTIFY => if (self.core_pointer) self.onCoreMotion(@ptrCast(event)),
            c.XCB_FOCUS_IN => self.onFocus(@ptrCast(event), true),
            c.XCB_FOCUS_OUT => self.onFocus(@ptrCast(event), false),
            c.XCB_CONFIGURE_NOTIFY => self.onConfigure(@ptrCast(event)),
            // Without a compositor the server keeps no copy of the window: redraw what was uncovered.
            c.XCB_EXPOSE => if (@as(*c.xcb_expose_event_t, @ptrCast(event)).count == 0) {
                self.dirty = true;
            },
            c.XCB_CLIENT_MESSAGE => self.onClient(@ptrCast(event)),
            c.XCB_SELECTION_REQUEST => self.onSelectionRequest(@ptrCast(event)),
            c.XCB_SELECTION_NOTIFY => self.onSelectionNotify(@ptrCast(event)),
            c.XCB_SELECTION_CLEAR => self.onSelectionClear(@ptrCast(event)),
            c.XCB_GE_GENERIC => self.onGeneric(@ptrCast(event)),
            else => {},
        }
    }

    fn onFocus(self: *Window, event: *c.xcb_focus_in_event_t, gained: bool) void {
        if (event.event != self.window) return;
        // Grabs report focus changes that are not a real loss of the keyboard.
        if (event.mode != @as(u8, @intCast(c.XCB_NOTIFY_MODE_NORMAL))) return;
        self.down = .initEmpty();
        if (gained) {
            self.lost_focus = false;
            self.input.enter();
        } else if (!self.stillFocused()) self.lost_focus = true;
    }

    fn stillFocused(self: *Window) bool {
        // A transient client can report a normal FocusOut while the server
        // still delivers keys here. Dropping that focus cancels a paste.
        const conn = self.conn orelse return false;
        const reply = api.input_focus_reply(conn, api.get_input_focus(conn), null) orelse return false;
        defer c.free(@ptrCast(reply));
        return reply.focus == self.window;
    }

    fn onKey(self: *Window, event: *c.xcb_key_press_event_t, pressed: bool) void {
        if (event.event != self.window) return;
        self.keyed = true;
        const xcode: usize = event.detail;
        self.last_time = event.time;
        if (pressed) {
            if (self.down.isSet(xcode)) return;
            self.down.set(xcode);
        } else self.down.unset(xcode);
        self.input.updateKey(@intCast(xcode), pressed);
        const evdev: u32 = if (xcode >= 8) @intCast(xcode - 8) else @intCast(xcode);
        self.input.key(event.time, evdev, pressed, monotonic());
        if (pressed) self.dirty = true;
    }

    fn onCoreButton(self: *Window, event: *c.xcb_button_press_event_t, pressed: bool) void {
        if (event.event != self.window) return;
        self.notePointer(event.root_x, event.root_y, event.event_x, event.event_y, event.detail, event.time);
        self.button(event.detail, pressed, event.time);
    }

    fn onCoreMotion(self: *Window, event: *c.xcb_motion_notify_event_t) void {
        if (event.event != self.window) return;
        self.place(@floatFromInt(event.event_x), @floatFromInt(event.event_y));
        self.root_x = event.root_x;
        self.root_y = event.root_y;
        if (self.mouse_down) self.dirty = true;
    }

    fn notePointer(self: *Window, root_x: i16, root_y: i16, event_x: i16, event_y: i16, which: u8, time: u32) void {
        self.root_x = root_x;
        self.root_y = root_y;
        self.last_button = which;
        self.last_time = time;
        self.place(@floatFromInt(event_x), @floatFromInt(event_y));
    }

    fn place(self: *Window, px: f32, py: f32) void {
        const factor = self.scale();
        self.pointer_x = px / factor;
        self.pointer_y = py / factor;
    }

    fn button(self: *Window, detail: u32, pressed: bool, time: u32) void {
        if (detail == 4 or detail == 5) {
            if (pressed) {
                self.scroll += if (detail == 4) @as(i32, -3) else 3;
                self.dirty = true;
            }
            return;
        }
        const code: ?u32 = switch (detail) {
            1 => 272,
            2 => 274,
            3 => 273,
            else => null,
        };
        const mapped = code orelse return;
        self.input.button(time, mapped, pressed, self.pointer_x, self.pointer_y);
        if (mapped == 272) self.mouse_down = pressed;
        self.dirty = true;
    }

    fn onConfigure(self: *Window, event: *c.xcb_configure_notify_event_t) void {
        if (event.window != self.window) return;
        const width: u32 = event.width;
        const height: u32 = event.height;
        if (width == 0 or height == 0) return;
        if (width == self.pixels_w and height == self.pixels_h) return;
        self.pixels_w = width;
        self.pixels_h = height;
        self.width = platform.uiExtent(self.pixels_w, self.effective_scale);
        self.height = platform.uiExtent(self.pixels_h, self.effective_scale);
        self.dirty = true;
        log.debug(.window, "window size {d}x{d}\n", .{ self.pixels_w, self.pixels_h });
    }

    fn onClient(self: *Window, event: *c.xcb_client_message_event_t) void {
        if (event.window != self.window) return;
        if (event.@"type" == self.atoms.wm_protocols and event.data.data32[0] == self.atoms.wm_delete) {
            self.closing = true;
            self.close_reason = .compositor_close;
        }
    }

    fn onGeneric(self: *Window, event: *c.xcb_ge_generic_event_t) void {
        if (event.extension != self.xi_opcode) return;
        const pointer: *c.xcb_input_button_press_event_t = @ptrCast(event);
        if (pointer.event != self.window) return;
        switch (event.event_type) {
            c.XCB_INPUT_BUTTON_PRESS, c.XCB_INPUT_BUTTON_RELEASE => {
                self.root_x = @divTrunc(pointer.root_x, 65536);
                self.root_y = @divTrunc(pointer.root_y, 65536);
                self.last_button = pointer.detail;
                self.last_time = pointer.time;
                self.place(@as(f32, @floatFromInt(pointer.event_x)) / 65536, @as(f32, @floatFromInt(pointer.event_y)) / 65536);
                self.button(pointer.detail, event.event_type == c.XCB_INPUT_BUTTON_PRESS, pointer.time);
            },
            c.XCB_INPUT_MOTION => {
                self.root_x = @divTrunc(pointer.root_x, 65536);
                self.root_y = @divTrunc(pointer.root_y, 65536);
                self.place(@as(f32, @floatFromInt(pointer.event_x)) / 65536, @as(f32, @floatFromInt(pointer.event_y)) / 65536);
                if (self.mouse_down) self.dirty = true;
            },
            else => {},
        }
    }

    fn setupInput(self: *Window) void {
        self.input_ready = true;
        self.input.repeatInfo(25, 660);
        self.setupXkb();
        if (!self.setupXi()) self.enableCorePointer();
    }

    fn setupXkb(self: *Window) void {
        const xkb = loadXkb() orelse {
            self.input.keymap_errors += 1;
            return;
        };
        const conn = self.conn orelse return;
        if (xkb.setup(conn, 1, 0, 0, null, null, null, null) != 1) {
            self.input.keymap_errors += 1;
            return;
        }
        const device = xkb.device(conn);
        if (device < 0) {
            self.input.keymap_errors += 1;
            return;
        }
        const context = self.input.context orelse {
            self.input.keymap_errors += 1;
            return;
        };
        const map = xkb.keymap(@ptrCast(context), conn, device, 0) orelse {
            self.input.keymap_errors += 1;
            return;
        };
        const state = xkb.state(map, conn, device) orelse {
            c.xkb_keymap_unref(@ptrCast(map));
            self.input.keymap_errors += 1;
            return;
        };
        self.input.adoptKeymap(map, state);
    }

    fn setupXi(self: *Window) bool {
        const xi = loadXi() orelse return false;
        const conn = self.conn orelse return false;
        const ext = api.extension_data(conn, xi.id) orelse return false;
        if (ext.present == 0) return false;
        self.xi_opcode = ext.major_opcode;
        const cookie = xi.query_version(conn, 2, 0);
        const reply = xi.query_reply(conn, cookie, null) orelse return false;
        defer c.free(@ptrCast(reply));
        if (reply.major_version < 2) return false;
        const Mask = extern struct { deviceid: u16, mask_len: u16, bits: u32 };
        const mask = Mask{
            .deviceid = @intCast(enumInt(c.XCB_INPUT_DEVICE_ALL_MASTER)),
            .mask_len = 1,
            .bits = enumInt(c.XCB_INPUT_XI_EVENT_MASK_BUTTON_PRESS) | enumInt(c.XCB_INPUT_XI_EVENT_MASK_BUTTON_RELEASE) | enumInt(c.XCB_INPUT_XI_EVENT_MASK_MOTION) | enumInt(c.XCB_INPUT_XI_EVENT_MASK_ENTER) | enumInt(c.XCB_INPUT_XI_EVENT_MASK_LEAVE),
        };
        _ = xi.select_events(conn, self.window, 1, @ptrCast(&mask));
        _ = api.flush(conn);
        return api.has_error(conn) == 0;
    }

    fn enableCorePointer(self: *Window) void {
        const conn = self.conn orelse return;
        self.event_mask |= enumInt(c.XCB_EVENT_MASK_BUTTON_PRESS) | enumInt(c.XCB_EVENT_MASK_BUTTON_RELEASE) | enumInt(c.XCB_EVENT_MASK_POINTER_MOTION);
        const values = [_]u32{self.event_mask};
        _ = api.change_attributes(conn, self.window, enumInt(c.XCB_CW_EVENT_MASK), &values);
        _ = api.flush(conn);
        self.core_pointer = true;
    }

    fn put(self: *Window, property: u32, type_atom: u32, format: u8, data_len: u32, data: *const anyopaque) void {
        const conn = self.conn orelse return;
        if (self.window == 0) return;
        _ = api.change_property(conn, @intCast(enumInt(c.XCB_PROP_MODE_REPLACE)), self.window, property, type_atom, format, data_len, data);
    }

    fn putProtocols(self: *Window) void {
        self.put(self.atoms.wm_protocols, enumInt(c.XCB_ATOM_ATOM), 32, 1, &self.atoms.wm_delete);
    }
    fn storeTitle(self: *Window, title: [*:0]const u8) void {
        const text = std.mem.span(title);
        const n = @min(text.len, self.title.len);
        @memcpy(self.title[0..n], text[0..n]);
        self.title_len = n;
    }
    fn storeApp(self: *Window, id: [*:0]const u8) void {
        const text = std.mem.span(id);
        const n = @min(text.len, self.app_id.len);
        @memcpy(self.app_id[0..n], text[0..n]);
        self.app_len = n;
    }
    fn putTitle(self: *Window) void {
        if (self.title_len == 0) return;
        self.put(enumInt(c.XCB_ATOM_WM_NAME), self.atoms.utf8, 8, @intCast(self.title_len), self.title[0..self.title_len].ptr);
        self.put(self.atoms.net_wm_name, self.atoms.utf8, 8, @intCast(self.title_len), self.title[0..self.title_len].ptr);
    }
    fn putClass(self: *Window) void {
        var buffer: [258]u8 = undefined;
        const n = @min(self.app_len, 128);
        if (n == 0) return;
        @memcpy(buffer[0..n], self.app_id[0..n]);
        buffer[n] = 0;
        @memcpy(buffer[n + 1 .. n + 1 + n], self.app_id[0..n]);
        buffer[n + 1 + n] = 0;
        self.put(enumInt(c.XCB_ATOM_WM_CLASS), enumInt(c.XCB_ATOM_STRING), 8, @intCast(n + 1 + n + 1), &buffer);
    }
    fn putHints(self: *Window) void {
        // InputHint so the window manager will offer keyboard focus.
        var hints = [_]u32{0} ** 9;
        hints[0] = 1;
        hints[1] = 1;
        self.put(enumInt(c.XCB_ATOM_WM_HINTS), enumInt(c.XCB_ATOM_WM_HINTS), 32, hints.len, &hints);
    }
    fn putSizeHints(self: *Window) void {
        var hints = [_]u32{0} ** 18;
        hints[0] = 16; // PMinSize
        const factor = self.scale();
        hints[5] = @intCast(@max(0, platform.minimumSurface(self.minimum_ui[0], factor, 1)));
        hints[6] = @intCast(@max(0, platform.minimumSurface(self.minimum_ui[1], factor, 1)));
        self.put(enumInt(c.XCB_ATOM_WM_NORMAL_HINTS), enumInt(c.XCB_ATOM_WM_SIZE_HINTS), 32, hints.len, &hints);
    }
    fn putMotif(self: *Window) void {
        var motif = [_]u32{ 2, 0, if (self.own_frame) 0 else 1, 0, 0 };
        self.put(self.atoms.motif, self.atoms.motif, 32, motif.len, &motif);
    }

    fn clientMessage(self: *Window, kind: u32, data: [5]u32) void {
        const conn = self.conn orelse return;
        var event = std.mem.zeroes(c.xcb_client_message_event_t);
        event.response_type = c.XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = self.window;
        event.@"type" = kind;
        event.data.data32 = data;
        _ = api.send_event(conn, 0, self.root, enumInt(c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT) | enumInt(c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY), @ptrCast(&event));
        _ = api.flush(conn);
    }

    pub fn setCursor(self: *Window, shape: platform.Cursor) void {
        self.cursor = shape;
    }
    pub fn setOwnFrame(self: *Window, own: bool) void {
        if (self.own_frame == own) return;
        self.own_frame = own;
        self.putMotif();
        if (self.conn) |conn| _ = api.flush(conn);
    }
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        self.storeTitle(title);
        self.putTitle();
        if (self.conn) |conn| _ = api.flush(conn);
    }
    pub fn setAppId(self: *Window, id: [*:0]const u8) void {
        self.storeApp(id);
        self.putClass();
        if (self.conn) |conn| _ = api.flush(conn);
    }
    pub fn setMinSize(self: *Window, width: i32, height: i32) void {
        self.minimum_ui = .{ width, height };
        self.putSizeHints();
        if (self.conn) |conn| _ = api.flush(conn);
    }
    pub fn minimize(self: *Window) void {
        self.clientMessage(self.atoms.wm_change_state, .{ 3, 0, 0, 0, 0 });
    }
    pub fn toggleMaximized(self: *Window) void {
        const action: u32 = if (self.maximized) 0 else 1;
        self.maximized = !self.maximized;
        self.clientMessage(self.atoms.net_wm_state, .{ action, self.atoms.max_vert, self.atoms.max_horz, 0, 0 });
    }
    pub fn beginMove(self: *Window) void {
        self.clientMessage(self.atoms.moveresize, .{ @as(u32, @bitCast(self.root_x)), @as(u32, @bitCast(self.root_y)), 8, self.last_button, 1 });
    }
    pub fn beginResize(self: *Window, edge: platform.Edge) void {
        const direction: u32 = switch (edge) {
            .top_left => 0,
            .top => 1,
            .top_right => 2,
            .right => 3,
            .bottom_right => 4,
            .bottom => 5,
            .bottom_left => 6,
            .left => 7,
        };
        self.clientMessage(self.atoms.moveresize, .{ @as(u32, @bitCast(self.root_x)), @as(u32, @bitCast(self.root_y)), direction, self.last_button, 1 });
    }
    pub fn scale(self: *const Window) f32 {
        return self.effective_scale;
    }
    pub fn bufferExtent(self: *const Window) platform.Extent {
        return .{ .width = @max(1, self.pixels_w), .height = @max(1, self.pixels_h) };
    }
    pub fn frameReady(_: *const Window) bool {
        return true;
    }
    pub fn requestFrame(_: *Window) !void {}
    pub fn cancelFrame(_: *Window) void {}
    pub fn displayFd(self: *Window) ?i32 {
        const conn = self.conn orelse return null;
        const fd = api.get_fd(conn);
        return if (fd < 0) null else fd;
    }
    pub fn displayGpu(_: *Window) ?Node {
        return null;
    }
    pub fn createSurface(self: *Window, instance: vk.VkInstance, surface: *vk.VkSurfaceKHR) vk.VkResult {
        const conn = self.conn orelse return vk.VK_ERROR_INITIALIZATION_FAILED;
        var info = std.mem.zeroes(c.VkXcbSurfaceCreateInfoKHR);
        info.sType = c.VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR;
        info.connection = conn;
        info.window = self.window;
        return c.vkCreateXcbSurfaceKHR(@ptrCast(instance), &info, null, @ptrCast(surface));
    }

    pub fn clipFocus(self: *Window, destination: u64, epoch: u64) void {
        // The UI rebinds the same editor on every event. Only a real change
        // cancels a transfer, matching the Wayland clipboard.
        if (self.paste.destination == destination and self.paste.epoch == epoch) return;
        if (self.paste.status != .idle) {
            self.paste.status = .idle;
            self.paste.size = 0;
        }
        self.paste.destination = destination;
        self.paste.epoch = epoch;
    }
    fn ensureClip(self: *Window) bool {
        if (self.clip_conn != null) return true;
        var screen: c_int = 0;
        const conn = api.connect(null, &screen);
        if (api.has_error(conn) != 0) {
            api.disconnect(conn);
            return false;
        }
        const window = api.generate_id(conn);
        const values = [_]u32{0};
        // Depth 0 and the screen visual match the main window. InputOnly with that visual is a BadMatch.
        const cookie = api.create_window(conn, 0, window, self.root, 0, 0, 1, 1, 0, @intCast(enumInt(c.XCB_WINDOW_CLASS_INPUT_OUTPUT)), self.visual, 0, &values);
        if (api.request_check(conn, cookie)) |err| {
            log.debug(.window, "clipboard clip create code={d}\n", .{err.error_code});
            c.free(@ptrCast(err));
            api.disconnect(conn);
            return false;
        }
        self.clip_conn = conn;
        self.clip_window = window;
        return true;
    }
    pub fn clipRequest(self: *Window, primary: bool) clip.Status {
        if (primary or self.conn == null) return .unavailable;
        // Our own selection: the request would come back to the window
        // connection, which nothing reads while this waits.
        if (self.paste.offer) {
            const n = self.paste.owned_len;
            @memcpy(self.paste.bytes[0..n], self.paste.owned[0..n]);
            self.paste.size = n;
            self.paste.status = .ready;
            self.dirty = true;
            log.debug(.window, "clipboard {s} {d} bytes\n", .{ @tagName(self.paste.status), n });
            return self.paste.status;
        }
        if (!self.ensureClip()) return .unavailable;
        self.paste.status = .pending;
        self.paste.size = 0;
        _ = api.delete_property(self.clip_conn.?, self.clip_window, self.atoms.xodb_selection);
        _ = api.convert_selection(self.clip_conn.?, self.clip_window, self.atoms.clipboard, self.atoms.utf8, self.atoms.xodb_selection, self.last_time);
        _ = api.flush(self.clip_conn.?);
        self.awaitSelection();
        return self.paste.status;
    }
    fn awaitSelection(self: *Window) void {
        const conn = self.clip_conn orelse return;
        var spins: u32 = 0;
        while (self.paste.status == .pending and spins < 30) : (spins += 1) {
            var polled = c.pollfd{ .fd = api.get_fd(conn), .events = c.POLLIN, .revents = 0 };
            const n = c.poll(&polled, 1, 10);
            if (n < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return;
            }
            self.drainClip();
        }
    }
    pub fn clipTake(self: *Window, out: *clip.Result) bool {
        if (self.paste.status == .idle or self.paste.status == .pending) return false;
        out.destination = self.paste.destination;
        out.epoch = self.paste.epoch;
        out.status = self.paste.status;
        out.size = self.paste.size;
        @memset(&out.bytes, 0);
        if (self.paste.size > 0) @memcpy(out.bytes[0..self.paste.size], self.paste.bytes[0..self.paste.size]);
        self.paste.status = .idle;
        return true;
    }
    pub fn clipPending(self: *const Window) bool {
        return self.paste.status == .pending;
    }
    pub fn clipCopy(self: *Window, primary: bool, bytes: []const u8) bool {
        if (primary or self.conn == null or bytes.len == 0 or bytes.len > clip.limit) return false;
        @memcpy(self.paste.owned[0..bytes.len], bytes);
        self.paste.owned_len = bytes.len;
        self.paste.offer = true;
        _ = api.set_selection_owner(self.conn.?, self.window, self.atoms.clipboard, self.last_time);
        _ = api.flush(self.conn.?);
        log.debug(.window, "clipboard copy {d} bytes\n", .{bytes.len});
        return true;
    }

    fn onSelectionClear(self: *Window, event: *c.xcb_selection_clear_event_t) void {
        if (event.selection == self.atoms.clipboard) self.paste.offer = false;
    }
    fn onSelectionRequest(self: *Window, event: *c.xcb_selection_request_event_t) void {
        const conn = self.conn orelse return;
        var property = event.property;
        if (event.selection != self.atoms.clipboard or !self.paste.offer) {
            property = 0;
        } else if (event.target == self.atoms.targets) {
            const list = [_]u32{ self.atoms.utf8, enumInt(c.XCB_ATOM_STRING) };
            if (property == 0) property = event.target;
            self.putOn(event.requestor, property, enumInt(c.XCB_ATOM_ATOM), 32, list.len, &list);
        } else if (event.target == self.atoms.utf8 or event.target == enumInt(c.XCB_ATOM_STRING)) {
            if (property == 0) property = event.target;
            self.putOn(event.requestor, property, event.target, 8, self.paste.owned_len, self.paste.owned[0..self.paste.owned_len].ptr);
        } else property = 0;
        var notify = std.mem.zeroes(c.xcb_selection_notify_event_t);
        notify.response_type = c.XCB_SELECTION_NOTIFY;
        notify.time = event.time;
        notify.requestor = event.requestor;
        notify.selection = event.selection;
        notify.target = event.target;
        notify.property = property;
        _ = api.send_event(conn, 0, event.requestor, enumInt(c.XCB_EVENT_MASK_NO_EVENT), @ptrCast(&notify));
        _ = api.flush(conn);
    }
    fn putOn(self: *Window, window: u32, property: u32, type_atom: u32, format: u8, data_len: usize, data: *const anyopaque) void {
        const conn = self.conn orelse return;
        _ = api.change_property(conn, @intCast(enumInt(c.XCB_PROP_MODE_REPLACE)), window, property, type_atom, format, @intCast(data_len), data);
    }
    fn onSelectionNotify(self: *Window, event: *c.xcb_selection_notify_event_t) void {
        if (self.paste.status != .pending or event.selection != self.atoms.clipboard) return;
        if (event.property == 0) return self.failPaste();
        const conn = self.clip_conn orelse return self.failPaste();
        const cookie = api.get_property(conn, 0, self.clip_window, event.property, 0, 0, 1024);
        const reply = api.property_reply(conn, cookie, null) orelse return self.failPaste();
        defer c.free(@ptrCast(reply));
        self.ingestPaste(reply, event.property);
    }
    fn pollClipProperty(self: *Window) void {
        const conn = self.clip_conn orelse return;
        const cookie = api.get_property(conn, 0, self.clip_window, self.atoms.xodb_selection, 0, 0, 1024);
        const reply = api.property_reply(conn, cookie, null) orelse return;
        defer c.free(@ptrCast(reply));
        if (reply.format != 8 or reply.value_len == 0) return;
        self.ingestPaste(reply, self.atoms.xodb_selection);
    }
    fn failPaste(self: *Window) void {
        self.paste.status = .failed;
        self.paste.size = 0;
        self.dirty = true;
        log.debug(.window, "clipboard {s} {d} bytes\n", .{ @tagName(self.paste.status), @as(u32, 0) });
    }
    fn ingestPaste(self: *Window, reply: *c.xcb_get_property_reply_t, property: u32) void {
        const conn = self.clip_conn orelse return self.failPaste();
        _ = api.delete_property(conn, self.clip_window, property);
        _ = api.flush(conn);
        if (reply.@"type" == self.atoms.incr) return self.failPaste();
        const bytes = propertyBytes(reply);
        const n = @min(bytes.len, clip.limit);
        if (n > 0) @memcpy(self.paste.bytes[0..n], bytes[0..n]);
        self.paste.size = n;
        self.paste.status = if (bytes.len > clip.limit or reply.bytes_after != 0) .truncated else .ready;
        self.dirty = true;
        log.debug(.window, "clipboard {s} {d} bytes\n", .{ @tagName(self.paste.status), self.paste.size });
    }
};

test "Xft.dpi is a scale and a missing key is none" {
    try std.testing.expectApproxEqAbs(@as(f32, 2), parseDpi("Xft.dpi:\t192\n").?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), parseDpi("Xft.antialias: 1\nXft.dpi: 96\n").?, 0.001);
    try std.testing.expect(parseDpi("Xft.hinting: 1\n") == null);
    try std.testing.expect(parseDpi("Xft.dpi: 10\n") == null);
    try std.testing.expect(parseDpi("Xft.dpi: 10000\n") == null);
}
