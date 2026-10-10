//! The DRM device the compositor renders with, from linux-dmabuf feedback.
//! One short exchange on a private event queue at startup; nothing is retained.
const std = @import("std");
const c = @import("../c.zig").api;
const Node = @import("../render/vk_select.zig").Node;

const Probe = struct {
    dmabuf: ?*c.zwp_linux_dmabuf_v1 = null,
    node: ?Node = null,
};
fn probe(data: ?*anyopaque) *Probe {
    return @ptrCast(@alignCast(data.?));
}
fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const p = probe(data);
    // Default feedback, and with it the main device, arrived in version 4.
    if (p.dmabuf != null or version < 4 or !std.mem.eql(u8, std.mem.span(interface), "zwp_linux_dmabuf_v1")) return;
    p.dmabuf = @ptrCast(c.wl_registry_bind(registry, name, &c.zwp_linux_dmabuf_v1_interface, 4));
}
fn removed(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
fn done(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {}
fn formatTable(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, fd: i32, _: u32) callconv(.c) void {
    _ = c.close(fd);
}
fn mainDevice(data: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, device: ?*c.wl_array) callconv(.c) void {
    const array = device orelse return;
    const bytes = array.data orelse return;
    var dev: c.dev_t = undefined;
    if (array.size != @sizeOf(c.dev_t)) return;
    @memcpy(std.mem.asBytes(&dev), @as([*]const u8, @ptrCast(bytes))[0..@sizeOf(c.dev_t)]);
    probe(data).node = Node.fromDev(dev);
}
fn trancheDone(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1) callconv(.c) void {}
fn trancheDevice(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, _: ?*c.wl_array) callconv(.c) void {}
fn trancheFormats(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, _: ?*c.wl_array) callconv(.c) void {}
fn trancheFlags(_: ?*anyopaque, _: ?*c.zwp_linux_dmabuf_feedback_v1, _: u32) callconv(.c) void {}
const registry_listener = c.wl_registry_listener{ .global = global, .global_remove = removed };
const feedback_listener = c.zwp_linux_dmabuf_feedback_v1_listener{ .done = done, .format_table = formatTable, .main_device = mainDevice, .tranche_done = trancheDone, .tranche_target_device = trancheDevice, .tranche_formats = trancheFormats, .tranche_flags = trancheFlags };

/// Null when the compositor does not say (software rendering, an old protocol).
pub fn query(display: *c.wl_display) ?Node {
    const queue = c.wl_display_create_queue(display) orelse return null;
    defer c.wl_event_queue_destroy(queue);
    const wrapper: *c.wl_display = @ptrCast(c.wl_proxy_create_wrapper(display) orelse return null);
    c.wl_proxy_set_queue(@ptrCast(wrapper), queue);
    const registry = c.wl_display_get_registry(wrapper);
    c.wl_proxy_wrapper_destroy(wrapper);
    var p = Probe{};
    defer if (p.dmabuf) |v| c.zwp_linux_dmabuf_v1_destroy(v);
    defer c.wl_registry_destroy(registry);
    _ = c.wl_registry_add_listener(registry, &registry_listener, &p);
    if (c.wl_display_roundtrip_queue(display, queue) < 0) return null;
    const feedback = c.zwp_linux_dmabuf_v1_get_default_feedback(p.dmabuf orelse return null) orelse return null;
    defer c.zwp_linux_dmabuf_feedback_v1_destroy(feedback);
    _ = c.zwp_linux_dmabuf_feedback_v1_add_listener(feedback, &feedback_listener, &p);
    if (c.wl_display_roundtrip_queue(display, queue) < 0) return null;
    return p.node;
}
