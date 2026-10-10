//! Which Vulkan device draws the window, and what to say when that choice may
//! not reach the screen. Pure policy over a described device list; the
//! renderer fills the list in and the tests stub it.
const std = @import("std");

/// A DRM device node, as (major, minor).
pub const Node = struct {
    major: u32,
    minor: u32,
    /// Linux dev_t layout (glibc gnu_dev_major / gnu_dev_minor).
    pub fn fromDev(dev: u64) Node {
        return .{
            .major = @intCast(((dev >> 32) & 0xfffff000) | ((dev >> 8) & 0xfff)),
            .minor = @intCast(((dev >> 12) & 0xffffff00) | (dev & 0xff)),
        };
    }
    fn eql(a: Node, b: Node) bool {
        return a.major == b.major and a.minor == b.minor;
    }
};
pub const Kind = enum { discrete, integrated, virtual, cpu, other };
pub const Device = struct {
    name: []const u8,
    kind: Kind = .other,
    /// Has a swapchain and a graphics queue that presents to the window.
    usable: bool = true,
    primary: ?Node = null,
    render: ?Node = null,
    pub fn drives(self: Device, display: ?Node) bool {
        const d = display orelse return false;
        return (if (self.primary) |n| n.eql(d) else false) or (if (self.render) |n| n.eql(d) else false);
    }
};
pub const Why = enum { requested, display, ranked };
pub const Choice = struct { index: usize, why: Why };
pub const Error = error{ NoPresentDevice, VulkanDeviceNotFound, VulkanDeviceCannotPresent };

fn rank(kind: Kind) u8 {
    return switch (kind) {
        .discrete => 3,
        .integrated => 2,
        .virtual, .cpu, .other => 1,
    };
}

/// `request` is an index into `devices` or a case-insensitive part of a name.
/// Without one, the device behind the compositor's DRM node wins; when that is
/// unknown or absent, the first usable device of the best kind does.
pub fn choose(devices: []const Device, request: ?[]const u8, display: ?Node) Error!Choice {
    const wanted = std.mem.trim(u8, request orelse "", " \t");
    if (wanted.len != 0) {
        var found: ?usize = null;
        if (std.fmt.parseInt(usize, wanted, 10)) |index| {
            if (index < devices.len) found = index;
        } else |_| for (devices, 0..) |device, i| {
            if (std.ascii.indexOfIgnoreCase(device.name, wanted) == null) continue;
            if (found == null or (device.usable and !devices[found.?].usable)) found = i;
        }
        const index = found orelse return error.VulkanDeviceNotFound;
        if (!devices[index].usable) return error.VulkanDeviceCannotPresent;
        return .{ .index = index, .why = .requested };
    }
    for (devices, 0..) |device, i| if (device.usable and device.drives(display)) return .{ .index = i, .why = .display };
    var best: ?usize = null;
    for (devices, 0..) |device, i| {
        if (device.usable and (best == null or rank(device.kind) > rank(devices[best.?].kind))) best = i;
    }
    return .{ .index = best orelse return error.NoPresentDevice, .why = .ranked };
}

/// The driver library named by a loader message about an ICD that did not load,
/// or null for any other message.
pub fn failedDriver(message: []const u8) ?[]const u8 {
    const key = "ICD JSON ";
    if (std.mem.indexOf(u8, message, "Failed loading library") == null) return null;
    const at = (std.mem.indexOf(u8, message, key) orelse return null) + key.len;
    const rest = message[at..];
    const name = rest[0 .. std.mem.indexOf(u8, rest, ". Ignoring") orelse rest.len];
    return if (name.len == 0) null else name;
}

/// One line for stderr when the picture may never reach the screen: the chosen
/// device is not the compositor's, or a driver failed to load. Null otherwise.
pub fn warning(buf: []u8, devices: []const Device, choice: Choice, display: ?Node, failed_driver: ?[]const u8) ?[]const u8 {
    const name = devices[choice.index].name;
    const off_display = display != null and !devices[choice.index].drives(display);
    if (!off_display and failed_driver == null) return null;
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("xodb: vulkan: ") catch {};
    if (failed_driver) |driver| w.print("driver {s} failed to load (driver/library mismatch after an update? a reboot usually fixes it); ", .{driver}) catch {};
    w.print("rendering on {s}", .{name}) catch {};
    if (off_display) {
        const d = display.?;
        w.print(", which is not the display GPU (drm {d}:{d}", .{ d.major, d.minor }) catch {};
        for (devices) |device| if (device.drives(display)) {
            w.print(", {s}", .{device.name}) catch {};
            break;
        };
        w.writeAll(") and may leave the window blank") catch {};
        if (choice.why == .requested) w.writeAll(" (as requested)") catch {};
    }
    w.writeAll("; --vk-list shows the devices, --vk-device or XODB_VK_DEVICE picks one") catch {};
    return w.buffered();
}

const stub = [_]Device{
    .{ .name = "Fast Discrete 9000", .kind = .discrete, .primary = .{ .major = 226, .minor = 1 }, .render = .{ .major = 226, .minor = 128 } },
    .{ .name = "Small Integrated (OPEN DRIVER)", .kind = .integrated, .primary = .{ .major = 226, .minor = 0 }, .render = .{ .major = 226, .minor = 129 } },
    .{ .name = "softpipe (CPU)", .kind = .cpu },
    .{ .name = "Fast Discrete 9000 compute-only", .kind = .discrete, .usable = false },
};

test "the compositor's device wins, then the best kind, in list order" {
    // Unknown display GPU: the previous rule, first discrete device.
    try std.testing.expectEqual(Choice{ .index = 0, .why = .ranked }, try choose(&stub, null, null));
    try std.testing.expectEqual(Choice{ .index = 0, .why = .ranked }, try choose(&stub, "  ", null));
    // The compositor on the integrated GPU, named by either node.
    try std.testing.expectEqual(Choice{ .index = 1, .why = .display }, try choose(&stub, null, .{ .major = 226, .minor = 129 }));
    try std.testing.expectEqual(Choice{ .index = 1, .why = .display }, try choose(&stub, null, .{ .major = 226, .minor = 0 }));
    try std.testing.expectEqual(Choice{ .index = 0, .why = .display }, try choose(&stub, null, .{ .major = 226, .minor = 128 }));
    // A display GPU with no Vulkan device (its driver did not load) falls back.
    try std.testing.expectEqual(Choice{ .index = 0, .why = .ranked }, try choose(stub[1..3], null, .{ .major = 226, .minor = 128 }));
    try std.testing.expectEqual(Choice{ .index = 0, .why = .ranked }, try choose(stub[2..3], null, null));
    try std.testing.expectError(error.NoPresentDevice, choose(stub[3..], null, null));
    try std.testing.expectError(error.NoPresentDevice, choose(&.{}, null, null));
}

test "a request selects by index or name and never falls back silently" {
    const display = Node{ .major = 226, .minor = 129 };
    try std.testing.expectEqual(Choice{ .index = 2, .why = .requested }, try choose(&stub, "2", display));
    try std.testing.expectEqual(Choice{ .index = 2, .why = .requested }, try choose(&stub, "SOFTPIPE", display));
    try std.testing.expectEqual(Choice{ .index = 1, .why = .requested }, try choose(&stub, " open driver ", null));
    // An ambiguous name prefers a device that can present.
    try std.testing.expectEqual(Choice{ .index = 0, .why = .requested }, try choose(&stub, "discrete", display));
    try std.testing.expectError(error.VulkanDeviceCannotPresent, choose(&stub, "3", display));
    try std.testing.expectError(error.VulkanDeviceCannotPresent, choose(&stub, "compute-only", display));
    try std.testing.expectError(error.VulkanDeviceNotFound, choose(&stub, "4", display));
    try std.testing.expectError(error.VulkanDeviceNotFound, choose(&stub, "no such gpu", display));
}

test "the warning names the device, the display GPU and a failed driver, once" {
    var buf: [512]u8 = undefined;
    const display = Node{ .major = 226, .minor = 129 };
    // Normal paths say nothing.
    try std.testing.expect(warning(&buf, &stub, try choose(&stub, null, display), display, null) == null);
    try std.testing.expect(warning(&buf, &stub, try choose(&stub, null, null), null, null) == null);
    const forced = warning(&buf, &stub, try choose(&stub, "softpipe", display), display, null).?;
    try std.testing.expectEqualStrings("xodb: vulkan: rendering on softpipe (CPU), which is not the display GPU (drm 226:129, Small Integrated (OPEN DRIVER)) and may leave the window blank (as requested); --vk-list shows the devices, --vk-device or XODB_VK_DEVICE picks one", forced);
    // The field case: the display GPU's driver did not load, so another device was ranked.
    const driver = failedDriver("loader_icd_scan: Failed loading library associated with ICD JSON libGLX_example.so.0. Ignoring this JSON").?;
    try std.testing.expectEqualStrings("libGLX_example.so.0", driver);
    const missing = warning(&buf, stub[1..3], try choose(stub[1..3], null, .{ .major = 226, .minor = 128 }), .{ .major = 226, .minor = 128 }, driver).?;
    try std.testing.expectEqualStrings("xodb: vulkan: driver libGLX_example.so.0 failed to load (driver/library mismatch after an update? a reboot usually fixes it); rendering on Small Integrated (OPEN DRIVER), which is not the display GPU (drm 226:128) and may leave the window blank; --vk-list shows the devices, --vk-device or XODB_VK_DEVICE picks one", missing);
    try std.testing.expect(std.mem.indexOfScalar(u8, missing, '\n') == null);
    // A failed driver is reported even when the display GPU is unknown.
    try std.testing.expect(std.mem.indexOf(u8, warning(&buf, &stub, try choose(&stub, null, null), null, driver).?, "failed to load") != null);
    try std.testing.expect(failedDriver("Searching for ICD drivers named libexample.so") == null);
    // A short buffer truncates; it never overruns.
    var small: [24]u8 = undefined;
    const cut = warning(&small, &stub, try choose(&stub, "2", display), display, null).?;
    try std.testing.expect(cut.len <= small.len and std.mem.startsWith(u8, cut, "xodb: vulkan: "));
}

test "dev_t decoding matches the Linux layout" {
    try std.testing.expectEqual(Node{ .major = 226, .minor = 129 }, Node.fromDev((226 << 8) | 129));
    try std.testing.expectEqual(Node{ .major = 226, .minor = 0x12345 }, Node.fromDev((226 << 8) | 0x45 | (0x123 << 20)));
}
