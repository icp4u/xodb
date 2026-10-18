const std = @import("std");
const redact = @import("../redact.zig");
const log = @import("../log.zig");
const c = @import("../c_ui.zig").api;
const Window = @import("../platform/window.zig").Window;
const phases = @import("../startup_phases.zig");
const fonts = @import("font.zig");
const select = @import("vk_select.zig");
/// `--vk-device`: an index from `--vk-list` or part of a device name. It wins
/// over XODB_VK_DEVICE.
pub var device_request: ?[]const u8 = null;
/// `--no-vk-layers`: implicit loader layers off for xodb's own instance.
pub var no_implicit_layers = false;
const child_env = @import("../child_env.zig");
pub const scene3d = @import("scene3d/gpu.zig");
pub const Color = [4]f32;
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: Color, local: [2]f32 = .{ 0, 0 }, half: [2]f32 = .{ 0, 0 }, shape: [3]f32 = .{ 0, 0, 0 } };
/// How a rectangle is drawn beyond a flat fill. Corners are ordered top-left, top-right,
/// bottom-left, bottom-right; `colors` gives one color per corner for gradients.
pub const Shape = struct { radii: [4]f32 = @splat(0), border: f32 = 0, softness: f32 = 0, colors: ?[4]Color = null };
const vertex_bytes = 8 * 1024 * 1024;
/// One instanced cell of a dense field (the Memory map's deep look): six
/// vertices from one 32-byte record instead of six 60-byte vertices.
/// `kind` bits 0-1 pick the base (0 fill, 1 hatch, 2 dots, 3 lower `fraction`
/// in `accent`); bit 2 adds light hatching; bit 3 an inner ring and bit 4 a
/// top-left edge, both in `overlay`; bit 5 rounds/insets modern cells;
/// bits 8-15 hold the fraction and 16-23 the measured-change pulse (0-255).
pub const Cell = extern struct { rect: [4]f32, fill: [4]u8, accent: [4]u8, overlay: [4]u8, kind: u32 };
pub const cell_capacity = 65536 + 8192;
const cell_offset = vertex_bytes + fonts.atlas_size * fonts.atlas_size;
/// Mapped storage size, also used by CPU-side renderer tests.
const cloud_vertex_offset = cell_offset + cell_capacity * @sizeOf(Cell);
const cloud_vertex_bytes = 4 * 1024 * 1024;
const cloud_cell_offset = cloud_vertex_offset + cloud_vertex_bytes;
const cloud_stride = cloud_vertex_bytes + 22000 * @sizeOf(Cell);
pub const CloudSlot = u1;
pub const buffer_bytes = cloud_vertex_offset + 2 * cloud_stride;
/// A run of cells drawn after the vertices recorded before it, clipped to `clip`.
const CellBatch = struct { at: usize, first: u32, count: u32, clip: Rect, cloud: ?CloudSlot = null, additive: bool = false, transform: [6]f32 = .{ 1, 1, 0, 0, 1, 0 } };
fn info(comptime T: type, kind: c.VkStructureType) T {
    var v = std.mem.zeroes(T);
    v.sType = kind;
    return v;
}
fn check(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) {
        log.err(.render, "Vulkan result: {d}\n", .{result});
        return error.VulkanFailed;
    }
}

/// A failed create leaves its output undefined. Clear it so that unwinding
/// a partial initialization never destroys or unmaps an invalid handle.
fn created(result: c.VkResult, output: anytype) !void {
    if (result != c.VK_SUCCESS) output.* = null;
    try check(result);
}

/// Vulkan enumeration counts belong to the driver. Query, allocate and retry
/// VK_INCOMPLETE; a fixed array can make initialization fail on another GPU.
fn enumerate(comptime T: type, comptime query: anytype, args: anytype, comptime label: []const u8) !std.ArrayList(T) {
    const a = std.heap.page_allocator;
    for (0..4) |_| {
        var count: u32 = 0;
        const counted = @call(.auto, query, args ++ .{ &count, null });
        if (counted != c.VK_SUCCESS and counted != c.VK_INCOMPLETE) {
            log.err(.render, "xodb: {s} count failed: {d}\n", .{ label, counted });
            return error.VulkanFailed;
        }
        if (count > 4096) {
            log.err(.render, "xodb: {s} count {d} exceeds enumeration limit 4096\n", .{ label, count });
            return error.VulkanEnumerationLimit;
        }
        if (count == 0) return .empty;
        const values = try a.alloc(T, count);
        const result = @call(.auto, query, args ++ .{ &count, values.ptr });
        if (result == c.VK_INCOMPLETE) {
            a.free(values);
            continue;
        }
        if (result != c.VK_SUCCESS or count > values.len) {
            a.free(values);
            log.err(.render, "xodb: {s} enumeration failed: {d} (count {d})\n", .{ label, result, count });
            return error.VulkanFailed;
        }
        return .{ .items = values[0..count], .capacity = values.len };
    }
    log.err(.render, "xodb: {s} enumeration still incomplete after four attempts\n", .{label});
    return error.VulkanEnumerationUnstable;
}

pub const Renderer = struct {
    window: ?*Window = null,
    deferral: Deferral = .{},
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    family: u32 = 0,
    swap: c.VkSwapchainKHR = null,
    format: c.VkFormat = c.VK_FORMAT_B8G8R8A8_UNORM,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    ui_width: f32 = 0,
    ui_height: f32 = 0,
    ui_scale: f32 = 1,
    count: u32 = 0,
    images: std.ArrayList(c.VkImage) = .empty,
    views: []c.VkImageView = &.{},
    framebuffers: []c.VkFramebuffer = &.{},
    finished: []c.VkSemaphore = &.{},
    pass: c.VkRenderPass = null,
    pass_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    pipeline: c.VkPipeline = null,
    cell_pipeline: c.VkPipeline = null,
    glow_pipeline: c.VkPipeline = null,
    glow_cell_pipeline: c.VkPipeline = null,
    /// Independent retained regions: views explicitly own a slot, so drawing
    /// a second graph cannot overwrite an earlier batch in the same frame.
    clouds: [2]struct { signature: u64 = 0, vertices: u32 = 0, cells: u32 = 0 } = @splat(.{}),
    layout: c.VkPipelineLayout = null,
    descriptor_layout: c.VkDescriptorSetLayout = null,
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor: c.VkDescriptorSet = null,
    pool: c.VkCommandPool = null,
    command: c.VkCommandBuffer = null,
    available: c.VkSemaphore = null,
    fence: c.VkFence = null,
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped: ?*anyopaque = null,
    atlas: c.VkImage = null,
    atlas_memory: c.VkDeviceMemory = null,
    atlas_view: c.VkImageView = null,
    sampler: c.VkSampler = null,
    atlas_ready: bool = false,
    /// A linear, host-visible atlas written in place (GENERAL layout): no
    /// copy command, so no driver copy shader to build on a first run.
    atlas_linear: bool = false,
    atlas_mapped: ?[*]u8 = null,
    atlas_pitch: usize = 0,
    vertices: usize = 0,
    cells_used: u32 = 0,
    batches: [8]CellBatch = undefined,
    batch_count: usize = 0,
    scene_gpu: ?scene3d.Gpu = null,
    scene_requested: bool = false,
    scene_retry: @import("scene3d/retry.zig").Retry = .{},
    scene_at: usize = 0,
    scene_after_batches: usize = 0,
    clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    gpu_name: [256]u8 = @splat(0),
    /// The chosen device's kind; .cpu is a software renderer (llvmpipe, lavapipe).
    gpu_kind: select.Kind = .other,
    /// Instance has VK_KHR_get_physical_device_properties2 for DRM nodes.
    device_nodes: bool = false,
    /// A driver library the loader reported as failing to load, if any.
    failed_driver: [96]u8 = undefined,
    failed_driver_len: usize = 0,

    pub fn init(self: *Renderer, window: *Window) !void {
        if (takeEarly()) |ready| {
            self.* = ready;
            self.window = window;
            // Only a device that cannot present to this window starts over;
            // any other failure is the renderer's, as on the ordinary path.
            if (self.adopt(window)) return else |err| {
                self.deinit();
                if (err != error.VulkanDeviceCannotPresent) return err;
                log.debug(.render, "Vulkan early device cannot present to this window; starting over\n", .{});
            }
        }
        self.window = window;
        errdefer self.deinit();
        const display = window.displayGpu();
        // Without a device request the display's GPU is chosen, so every other
        // ICD the loader opens is startup cost (NVIDIA's alone is 30-70 ms).
        // Ask the loader for the display driver's ICD only, and retry with all
        // of them when that yields nothing that can present.
        // Children (targets: child_env.settle) and --vk-list never see the filter.
        child_env.hold();
        var filter = loaderFilter(display);
        if (filter) |pattern| _ = c.setenv("VK_LOADER_DRIVERS_SELECT", pattern, 1);
        const layers_off = implicitLayersOff();
        const instance_made = self.createInstance();
        if (filter != null) _ = c.unsetenv("VK_LOADER_DRIVERS_SELECT");
        if (layers_off) _ = c.unsetenv("VK_LOADER_LAYERS_DISABLE");
        child_env.release();
        // No matching manifest, or the matching driver failed to load: the
        // loader then has no driver at all; load every one, as without a filter.
        if (instance_made) |_| {} else |err| if (filter) |pattern| {
            log.debug(.render, "Vulkan loader drivers {s} gave no instance ({s}); loading every driver\n", .{ pattern, @errorName(err) });
            filter = null;
            try self.createInstance();
        } else return err;
        try created(window.createSurface(self.instance, &self.surface), &self.surface);
        phases.begin(.device);
        var found = try self.probe();
        defer found.deinit(std.heap.page_allocator);
        if (filter) |pattern| if (for (found.items) |item| {
            if (item.device.usable) break false;
        } else true) {
            log.debug(.render, "Vulkan loader drivers {s} gave no device that can present; loading every driver\n", .{pattern});
            found.deinit(std.heap.page_allocator);
            found = .empty;
            c.vkDestroySurfaceKHR(self.instance, self.surface, null);
            self.surface = null;
            c.vkDestroyInstance(self.instance, null);
            self.instance = null;
            try self.createInstance();
            try created(window.createSurface(self.instance, &self.surface), &self.surface);
            found = try self.probe();
        };
        const choice = try pick(found.items, display);
        self.physical = found.items[choice.index].physical;
        self.family = found.items[choice.index].family;
        self.gpu_name = found.items[choice.index].name;
        self.gpu_kind = found.items[choice.index].device.kind;
        log.info(.render, "Vulkan device: {s}\n", .{std.mem.sliceTo(@as([]const u8, &self.gpu_name), 0)});
        logChoice(choice, found.items.len);
        self.warn(found.items, choice, display);
        try self.createDevice();
        const pixels = window.bufferExtent();
        try self.createSwap(pixels.width, pixels.height);
    }
    fn logChoice(choice: select.Choice, count: usize) void {
        log.debug(.render, "Vulkan device {d} of {d} chosen: {s}\n", .{ choice.index, count, switch (choice.why) {
            .requested => "requested with --vk-device or XODB_VK_DEVICE",
            .display => "it drives the compositor's display",
            .ranked => "best kind that can present; the display's device is unknown or unusable",
        } });
    }
    /// The early thread's part: everything but the surface and swapchain.
    /// Devices are probed without a surface (any graphics family) and chosen
    /// by the same rule, the display's DRM node first; `adopt` checks that the
    /// chosen family presents to the window.
    fn prepare(self: *Renderer, display: ?select.Node) !void {
        errdefer self.deinit();
        const instance_made = self.createInstance();
        // The loader has read its variables; a child launched from now on
        // (on any thread) must not inherit them.
        earlyRestore();
        try instance_made;
        phases.begin(.device);
        var found = try self.probe();
        defer found.deinit(std.heap.page_allocator);
        const choice = try pick(found.items, display);
        self.physical = found.items[choice.index].physical;
        self.family = found.items[choice.index].family;
        self.gpu_name = found.items[choice.index].name;
        self.gpu_kind = found.items[choice.index].device.kind;
        log.info(.render, "Vulkan device: {s}\n", .{std.mem.sliceTo(@as([]const u8, &self.gpu_name), 0)});
        logChoice(choice, found.items.len);
        self.warn(found.items, choice, display);
        try self.createDevice();
        // The usual swapchain format; createSwap rebuilds pass and pipelines if the surface differs.
        self.format = c.VK_FORMAT_B8G8R8A8_UNORM;
        try self.createPass();
    }
    fn adopt(self: *Renderer, window: *Window) !void {
        try created(window.createSurface(self.instance, &self.surface), &self.surface);
        var present: c.VkBool32 = 0;
        try check(c.vkGetPhysicalDeviceSurfaceSupportKHR(self.physical, self.family, self.surface, &present));
        if (present == 0) return error.VulkanDeviceCannotPresent;
        const pixels = window.bufferExtent();
        try self.createSwap(pixels.width, pixels.height);
    }
    /// The logical device for `physical` and `family`, and everything that
    /// needs only the device: queue, commands, sync, buffers, atlas, descriptors.
    fn createDevice(self: *Renderer) !void {
        const priority: f32 = 1;
        var queue_info = info(c.VkDeviceQueueCreateInfo, c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO);
        queue_info.queueFamilyIndex = self.family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;
        const device_ext = [_][*c]const u8{"VK_KHR_swapchain"};
        var device_info = info(c.VkDeviceCreateInfo, c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
        device_info.queueCreateInfoCount = 1;
        device_info.pQueueCreateInfos = &queue_info;
        device_info.enabledExtensionCount = device_ext.len;
        device_info.ppEnabledExtensionNames = &device_ext;
        try created(c.vkCreateDevice(self.physical, &device_info, null, &self.device), &self.device);
        phases.end(.device);
        c.vkGetDeviceQueue(self.device, self.family, 0, &self.queue);
        var pool_info = info(c.VkCommandPoolCreateInfo, c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
        pool_info.queueFamilyIndex = self.family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try created(c.vkCreateCommandPool(self.device, &pool_info, null, &self.pool), &self.pool);
        var cmd_info = info(c.VkCommandBufferAllocateInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
        cmd_info.commandPool = self.pool;
        cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_info.commandBufferCount = 1;
        try check(c.vkAllocateCommandBuffers(self.device, &cmd_info, &self.command));
        var semaphore_info = info(c.VkSemaphoreCreateInfo, c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
        try created(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.available), &self.available);
        var fence_info = info(c.VkFenceCreateInfo, c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO);
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        try created(c.vkCreateFence(self.device, &fence_info, null, &self.fence), &self.fence);
        try self.createBuffer();
        try self.createAtlas();
        try self.createDescriptors();
    }
    /// With --no-vk-layers: implicit layers (overlays, capture hooks, Mesa's
    /// device_select) off for xodb's own instance, unless the user configured
    /// layers or requested a device. True when set.
    fn implicitLayersOff() bool {
        // Opt-in: it also turns off OBS vkcapture, MangoHud and Steam overlay hooks.
        if (!no_implicit_layers) return false;
        // Mesa's device_select layer orders the devices; --vk-device indices
        // follow --vk-list, so a request keeps the layers.
        if (device_request != null or c.getenv("XODB_VK_DEVICE") != null) return false;
        for ([_][*:0]const u8{ "VK_LOADER_LAYERS_ENABLE", "VK_LOADER_LAYERS_DISABLE", "VK_INSTANCE_LAYERS" }) |name| {
            if (c.getenv(name) != null) return false;
        }
        _ = c.setenv("VK_LOADER_LAYERS_DISABLE", "~implicit~", 1);
        return true;
    }
    /// The loader filter for the display GPU's kernel driver, or null: when
    /// there is no device request, the user set no loader driver variables,
    /// and the driver is in the table.
    fn loaderFilter(display: ?select.Node) ?[:0]const u8 {
        const node = display orelse return null;
        if (device_request != null or c.getenv("XODB_VK_DEVICE") != null) return null;
        for ([_][*:0]const u8{ "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "VK_ADD_DRIVER_FILES", "VK_LOADER_DRIVERS_SELECT", "VK_LOADER_DRIVERS_DISABLE", "VK_LOADER_DEVICE_ID_FILTER", "VK_LOADER_VENDOR_ID_FILTER", "VK_LOADER_DRIVER_ID_FILTER" }) |name| {
            if (c.getenv(name) != null) return null;
        }
        var path: [64]u8 = undefined;
        const link = std.fmt.bufPrintZ(&path, "/sys/dev/char/{d}:{d}/device/driver", .{ node.major, node.minor }) catch return null;
        var target: [256]u8 = undefined;
        const n = c.readlink(link.ptr, &target, target.len);
        if (n <= 0) return null;
        const driver = std.fs.path.basename(target[0..@intCast(n)]);
        const pattern = select.loaderPattern(driver) orelse return null;
        log.debug(.render, "Vulkan loader drivers {s} for the display's kernel driver {s}\n", .{ pattern, driver });
        return pattern;
    }
    /// The instance, with two optional extensions when the loader has them:
    /// device DRM nodes (to find the display GPU) and loader messages (to hear
    /// about a driver that did not load). The messenger lives for this call only.
    fn createInstance(self: *Renderer) !void {
        phases.begin(.instance);
        var app = info(c.VkApplicationInfo, c.VK_STRUCTURE_TYPE_APPLICATION_INFO);
        app.pApplicationName = "xodb";
        app.apiVersion = c.VK_API_VERSION_1_0;
        const surface_ext = if (self.window) |w| w.surfaceExtension() else Window.vk_surface_extension;
        const extensions = [_][*c]const u8{ "VK_KHR_surface", surface_ext, "VK_KHR_get_physical_device_properties2", "VK_EXT_debug_utils" };
        var messenger = info(c.VkDebugUtilsMessengerCreateInfoEXT, c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT);
        messenger.messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
        messenger.messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT;
        messenger.pfnUserCallback = loaderMessage;
        messenger.pUserData = self;
        var instance_info = info(c.VkInstanceCreateInfo, c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
        instance_info.pApplicationInfo = &app;
        instance_info.ppEnabledExtensionNames = &extensions;
        instance_info.enabledExtensionCount = extensions.len;
        instance_info.pNext = &messenger;
        self.failed_driver_len = 0;
        // Drop the optional extensions from the end until the loader accepts the rest.
        var result: c.VkResult = c.VK_ERROR_EXTENSION_NOT_PRESENT;
        var count: u32 = extensions.len;
        while (result == c.VK_ERROR_EXTENSION_NOT_PRESENT and count >= 2) : (count -= 1) {
            instance_info.enabledExtensionCount = count;
            instance_info.pNext = if (count == extensions.len) &messenger else null;
            self.device_nodes = count >= 3;
            result = c.vkCreateInstance(&instance_info, null, &self.instance);
        }
        try created(result, &self.instance);
        phases.end(.instance);
    }
    fn loaderMessage(_: c.VkDebugUtilsMessageSeverityFlagBitsEXT, _: c.VkDebugUtilsMessageTypeFlagsEXT, data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT, user: ?*anyopaque) callconv(.c) c.VkBool32 {
        const self: *Renderer = @ptrCast(@alignCast(user orelse return c.VK_FALSE));
        if (data == null or data.*.pMessage == null or self.failed_driver_len != 0) return c.VK_FALSE;
        const driver = select.failedDriver(std.mem.span(data.*.pMessage)) orelse return c.VK_FALSE;
        self.failed_driver_len = @min(driver.len, self.failed_driver.len);
        @memcpy(self.failed_driver[0..self.failed_driver_len], driver[0..self.failed_driver_len]);
        return c.VK_FALSE;
    }
    const Found = struct {
        physical: c.VkPhysicalDevice,
        family: u32 = 0,
        name: [256]u8,
        device: select.Device,
        fn describe(self: *const Found) select.Device {
            var result = self.device;
            result.name = std.mem.sliceTo(@as([]const u8, &self.name), 0);
            return result;
        }
    };
    /// Every physical device, with the first graphics queue family that can
    /// present to the surface (any graphics family when there is no surface).
    fn probe(self: *Renderer) !std.ArrayList(Found) {
        const a = std.heap.page_allocator;
        var devices = try enumerate(c.VkPhysicalDevice, c.vkEnumeratePhysicalDevices, .{self.instance}, "vkEnumeratePhysicalDevices");
        defer devices.deinit(a);
        var found: std.ArrayList(Found) = .empty;
        errdefer found.deinit(a);
        // The loader exports only the core name; the extension entry point is looked up.
        const properties2: c.PFN_vkGetPhysicalDeviceProperties2 = if (self.device_nodes) @ptrCast(c.vkGetInstanceProcAddr(self.instance, "vkGetPhysicalDeviceProperties2KHR")) else null;
        for (devices.items) |physical| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(physical, &props);
            var device = Found{ .physical = physical, .name = props.deviceName, .device = .{ .name = "", .usable = false, .kind = switch (props.deviceType) {
                c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => .discrete,
                c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => .integrated,
                c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => .virtual,
                c.VK_PHYSICAL_DEVICE_TYPE_CPU => .cpu,
                else => .other,
            } } };
            const name = std.mem.sliceTo(@as([]const u8, &props.deviceName), 0);
            if (properties2 != null and hasExtension(physical, "VK_EXT_physical_device_drm")) {
                var drm = info(c.VkPhysicalDeviceDrmPropertiesEXT, c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT);
                var props2 = info(c.VkPhysicalDeviceProperties2, c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2);
                props2.pNext = &drm;
                properties2.?(physical, &props2);
                if (drm.hasPrimary != 0) device.device.primary = .{ .major = @intCast(drm.primaryMajor), .minor = @intCast(drm.primaryMinor) };
                if (drm.hasRender != 0) device.device.render = .{ .major = @intCast(drm.renderMajor), .minor = @intCast(drm.renderMinor) };
            }
            // One unusable device must not hide another that can present.
            if (!hasExtension(physical, "VK_KHR_swapchain")) {
                log.warn(.render, "xodb: Vulkan device {s} lacks VK_KHR_swapchain; skipped\n", .{name});
                try found.append(a, device);
                continue;
            }
            var n: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &n, null);
            if (n > 4096) return error.VulkanEnumerationLimit;
            const families = try a.alloc(c.VkQueueFamilyProperties, n);
            defer a.free(families);
            c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &n, families.ptr);
            if (n > families.len) return error.VulkanEnumerationUnstable;
            for (families[0..n], 0..) |family, i| {
                var present: c.VkBool32 = 1;
                if (self.surface != null) {
                    const queried = c.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(i), self.surface, &present);
                    if (queried != c.VK_SUCCESS) {
                        log.warn(.render, "xodb: Vulkan device {s} queue family {d} surface support query failed: {d}; skipped\n", .{ name, i, queried });
                        continue;
                    }
                }
                if (present == 0 or family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                device.family = @intCast(i);
                device.device.usable = true;
                break;
            }
            try found.append(a, device);
        }
        return found;
    }
    fn describeAll(found: []const Found, out: []select.Device) []select.Device {
        const n = @min(found.len, out.len);
        for (found[0..n], out[0..n]) |*from, *to| to.* = from.describe();
        return out[0..n];
    }
    /// Applies the request (flag, then environment) and the display GPU rule.
    /// A request that cannot be honoured is an error with the list, never a
    /// silent fallback.
    fn pick(found: []const Found, display: ?select.Node) !select.Choice {
        var described: [64]select.Device = undefined;
        const devices = describeAll(found, &described);
        const request: ?[]const u8 = device_request orelse if (c.getenv("XODB_VK_DEVICE")) |value| std.mem.span(value) else null;
        return select.choose(devices, request, display) catch |err| {
            switch (err) {
                error.NoPresentDevice => return err,
                error.VulkanDeviceNotFound => log.err(.render, "xodb: no Vulkan device matches \"{s}\"; the devices are:\n", .{request.?}),
                error.VulkanDeviceCannotPresent => log.err(.render, "xodb: the Vulkan device requested with \"{s}\" cannot present to this window; the devices are:\n", .{request.?}),
            }
            for (devices, 0..) |device, i| log.err(.render, "  {d}  {s}{s}\n", .{ i, device.name, if (device.usable) "" else "  (cannot present)" });
            return err;
        };
    }
    fn failedDriver(self: *const Renderer) ?[]const u8 {
        return if (self.failed_driver_len == 0) null else self.failed_driver[0..self.failed_driver_len];
    }
    /// At most one line per process: a retried initialization does not repeat it.
    fn warn(self: *const Renderer, found: []const Found, choice: select.Choice, display: ?select.Node) void {
        const Once = struct {
            var said = false;
        };
        var described: [64]select.Device = undefined;
        var buf: [768]u8 = undefined;
        const line = select.warning(&buf, describeAll(found, &described), choice, display, self.failedDriver()) orelse return;
        if (Once.said) return;
        Once.said = true;
        log.warn(.render, "{s}\n", .{line});
    }
    /// `--vk-list`: every device on stdout, with the one xodb would use. Only
    /// with a window can it check presentation and name the display's device.
    pub fn list(window: ?*Window) !void {
        var self = Renderer{};
        defer self.deinit();
        try self.createInstance();
        if (window) |w| try created(w.createSurface(self.instance, &self.surface), &self.surface);
        var found = try self.probe();
        defer found.deinit(std.heap.page_allocator);
        const display = if (window) |w| w.displayGpu() else null;
        var described: [64]select.Device = undefined;
        const devices = describeAll(found.items, &described);
        const choice: ?select.Choice = pick(found.items, display) catch null;
        var buffer: [16384]u8 = undefined;
        const bytes = select.listing(&buffer, devices, choice, display, window != null);
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = c.write(1, bytes.ptr + sent, bytes.len - sent);
            if (n <= 0) break;
            sent += @intCast(n);
        }
        if (choice) |ch| self.warn(found.items, ch, display) else if (self.failedDriver()) |driver| log.warn(.render, "xodb: vulkan: driver {s} failed to load\n", .{driver});
    }
    fn hasExtension(physical: c.VkPhysicalDevice, comptime wanted: []const u8) bool {
        var extensions = enumerate(c.VkExtensionProperties, c.vkEnumerateDeviceExtensionProperties, .{ physical, @as([*c]const u8, null) }, "vkEnumerateDeviceExtensionProperties") catch return false;
        defer extensions.deinit(std.heap.page_allocator);
        for (extensions.items) |extension| {
            if (std.mem.eql(u8, std.mem.sliceTo(@as([]const u8, &extension.extensionName), 0), wanted)) return true;
        }
        return false;
    }
    fn memoryType(self: *Renderer, bits: u32, flags: u32) !u32 {
        var props: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical, &props);
        for (0..@min(props.memoryTypeCount, props.memoryTypes.len)) |i| if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and (props.memoryTypes[i].propertyFlags & flags) == flags) return @intCast(i);
        return error.NoMemoryType;
    }
    fn allocate(self: *Renderer, req: c.VkMemoryRequirements, flags: u32, memory: *c.VkDeviceMemory) !void {
        var allocation = info(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        allocation.allocationSize = req.size;
        allocation.memoryTypeIndex = try self.memoryType(req.memoryTypeBits, flags);
        try created(c.vkAllocateMemory(self.device, &allocation, null, memory), memory);
    }
    fn createBuffer(self: *Renderer) !void {
        var buffer_info = info(c.VkBufferCreateInfo, c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
        buffer_info.size = buffer_bytes;
        buffer_info.usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try created(c.vkCreateBuffer(self.device, &buffer_info, null, &self.buffer), &self.buffer);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, self.buffer, &req);
        try self.allocate(req, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &self.memory);
        try check(c.vkBindBufferMemory(self.device, self.buffer, self.memory, 0));
        try created(c.vkMapMemory(self.device, self.memory, 0, buffer_bytes, 0, &self.mapped), &self.mapped);
    }
    fn createView(self: *Renderer, img: c.VkImage, format: c.VkFormat, view: *c.VkImageView) !void {
        var create = info(c.VkImageViewCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
        create.image = img;
        create.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        create.format = format;
        create.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try created(c.vkCreateImageView(self.device, &create, null, view), view);
    }
    fn createAtlas(self: *Renderer) !void {
        self.createLinearAtlas() catch {
            if (self.atlas != null) c.vkDestroyImage(self.device, self.atlas, null);
            if (self.atlas_memory != null) c.vkFreeMemory(self.device, self.atlas_memory, null);
            self.atlas = null;
            self.atlas_memory = null;
            self.atlas_linear = false;
            self.atlas_mapped = null;
            return self.createOptimalAtlas();
        };
        try self.createSampler();
    }
    fn createLinearAtlas(self: *Renderer) !void {
        var format: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(self.physical, c.VK_FORMAT_R8_UNORM, &format);
        if (format.linearTilingFeatures & c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT == 0) return error.LinearAtlasUnsupported;
        var create = info(c.VkImageCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
        create.imageType = c.VK_IMAGE_TYPE_2D;
        create.format = c.VK_FORMAT_R8_UNORM;
        create.extent = .{ .width = fonts.atlas_size, .height = fonts.atlas_size, .depth = 1 };
        create.mipLevels = 1;
        create.arrayLayers = 1;
        create.samples = c.VK_SAMPLE_COUNT_1_BIT;
        create.tiling = c.VK_IMAGE_TILING_LINEAR;
        create.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT;
        create.initialLayout = c.VK_IMAGE_LAYOUT_PREINITIALIZED;
        try created(c.vkCreateImage(self.device, &create, null, &self.atlas), &self.atlas);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.atlas, &req);
        try self.allocate(req, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &self.atlas_memory);
        try check(c.vkBindImageMemory(self.device, self.atlas, self.atlas_memory, 0));
        const subresource = c.VkImageSubresource{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .arrayLayer = 0 };
        var layout: c.VkSubresourceLayout = undefined;
        c.vkGetImageSubresourceLayout(self.device, self.atlas, &subresource, &layout);
        if (layout.rowPitch < fonts.atlas_size) return error.LinearAtlasUnsupported;
        var mapped: ?*anyopaque = null;
        try check(c.vkMapMemory(self.device, self.atlas_memory, 0, c.VK_WHOLE_SIZE, 0, &mapped));
        self.atlas_mapped = @as([*]u8, @ptrCast(mapped.?)) + layout.offset;
        self.atlas_pitch = @intCast(layout.rowPitch);
        try self.createView(self.atlas, c.VK_FORMAT_R8_UNORM, &self.atlas_view);
        self.atlas_linear = true;
    }
    fn createOptimalAtlas(self: *Renderer) !void {
        var create = info(c.VkImageCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
        create.imageType = c.VK_IMAGE_TYPE_2D;
        create.format = c.VK_FORMAT_R8_UNORM;
        create.extent = .{ .width = fonts.atlas_size, .height = fonts.atlas_size, .depth = 1 };
        create.mipLevels = 1;
        create.arrayLayers = 1;
        create.samples = c.VK_SAMPLE_COUNT_1_BIT;
        create.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        create.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        try created(c.vkCreateImage(self.device, &create, null, &self.atlas), &self.atlas);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.atlas, &req);
        try self.allocate(req, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.atlas_memory);
        try check(c.vkBindImageMemory(self.device, self.atlas, self.atlas_memory, 0));
        try self.createView(self.atlas, c.VK_FORMAT_R8_UNORM, &self.atlas_view);
        try self.createSampler();
    }
    fn createSampler(self: *Renderer) !void {
        var sampler = info(c.VkSamplerCreateInfo, c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO);
        sampler.magFilter = c.VK_FILTER_NEAREST;
        sampler.minFilter = c.VK_FILTER_NEAREST;
        sampler.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        try created(c.vkCreateSampler(self.device, &sampler, null, &self.sampler), &self.sampler);
    }
    fn createDescriptors(self: *Renderer) !void {
        const binding = c.VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null };
        var layout = info(c.VkDescriptorSetLayoutCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO);
        layout.bindingCount = 1;
        layout.pBindings = &binding;
        try created(c.vkCreateDescriptorSetLayout(self.device, &layout, null, &self.descriptor_layout), &self.descriptor_layout);
        const size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
        var pool = info(c.VkDescriptorPoolCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
        pool.maxSets = 1;
        pool.poolSizeCount = 1;
        pool.pPoolSizes = &size;
        try created(c.vkCreateDescriptorPool(self.device, &pool, null, &self.descriptor_pool), &self.descriptor_pool);
        var alloc = info(c.VkDescriptorSetAllocateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
        alloc.descriptorPool = self.descriptor_pool;
        alloc.descriptorSetCount = 1;
        alloc.pSetLayouts = &self.descriptor_layout;
        try check(c.vkAllocateDescriptorSets(self.device, &alloc, &self.descriptor));
        const image = c.VkDescriptorImageInfo{ .sampler = self.sampler, .imageView = self.atlas_view, .imageLayout = if (self.atlas_linear) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        var write = info(c.VkWriteDescriptorSet, c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
        write.dstSet = self.descriptor;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &image;
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
        const push = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 32 };
        var pipeline_layout = info(c.VkPipelineLayoutCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
        pipeline_layout.setLayoutCount = 1;
        pipeline_layout.pSetLayouts = &self.descriptor_layout;
        pipeline_layout.pushConstantRangeCount = 1;
        pipeline_layout.pPushConstantRanges = &push;
        try created(c.vkCreatePipelineLayout(self.device, &pipeline_layout, null, &self.layout), &self.layout);
    }
    fn createSwap(self: *Renderer, width: u32, height: u32) !void {
        phases.begin(.swapchain);
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface, &caps));
        var formats = try enumerate(c.VkSurfaceFormatKHR, c.vkGetPhysicalDeviceSurfaceFormatsKHR, .{ self.physical, self.surface }, "vkGetPhysicalDeviceSurfaceFormatsKHR");
        defer formats.deinit(std.heap.page_allocator);
        if (formats.items.len == 0) return error.NoSurfaceFormat;
        var chosen = formats.items[0];
        for (formats.items) |f| if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM) {
            chosen = f;
            break;
        };
        self.format = chosen.format;
        // Driver-reported limits feed shifts, increments and clamps below; reject
        // impossible values as an initialization failure, not a process abort.
        if (caps.supportedCompositeAlpha == 0 or caps.minImageCount > 64 or
            caps.minImageExtent.width > caps.maxImageExtent.width or caps.minImageExtent.height > caps.maxImageExtent.height)
        {
            log.err(.render, "xodb: unusable surface capabilities: alpha 0x{x}, min images {d}, extent {d}x{d}..{d}x{d}\n", .{ caps.supportedCompositeAlpha, caps.minImageCount, caps.minImageExtent.width, caps.minImageExtent.height, caps.maxImageExtent.width, caps.maxImageExtent.height });
            return error.SurfaceCapabilitiesInvalid;
        }
        self.extent = if (caps.currentExtent.width != std.math.maxInt(u32)) caps.currentExtent else .{
            .width = std.math.clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height),
        };
        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0) image_count = @min(image_count, caps.maxImageCount);
        var create = info(c.VkSwapchainCreateInfoKHR, c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
        create.surface = self.surface;
        create.minImageCount = image_count;
        create.imageFormat = chosen.format;
        create.imageColorSpace = chosen.colorSpace;
        create.imageExtent = self.extent;
        create.imageArrayLayers = 1;
        create.imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        create.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        create.preTransform = caps.currentTransform;
        create.compositeAlpha = @as(u32, 1) << @as(u5, @intCast(@ctz(caps.supportedCompositeAlpha)));
        create.presentMode = c.VK_PRESENT_MODE_FIFO_KHR;
        create.clipped = c.VK_TRUE;
        const old = self.swap;
        create.oldSwapchain = old;
        var replacement: c.VkSwapchainKHR = null;
        try check(c.vkCreateSwapchainKHR(self.device, &create, null, &replacement));
        self.swap = replacement;
        if (old != null) c.vkDestroySwapchainKHR(self.device, old, null);
        self.images = try enumerate(c.VkImage, c.vkGetSwapchainImagesKHR, .{ self.device, self.swap }, "vkGetSwapchainImagesKHR");
        self.count = @intCast(self.images.items.len);
        if (self.count == 0) return error.NoSwapchainImages;
        self.views = try std.heap.page_allocator.alloc(c.VkImageView, self.count);
        @memset(self.views, null);
        self.framebuffers = try std.heap.page_allocator.alloc(c.VkFramebuffer, self.count);
        @memset(self.framebuffers, null);
        self.finished = try std.heap.page_allocator.alloc(c.VkSemaphore, self.count);
        @memset(self.finished, null);
        if (self.pass != null and self.pass_format != self.format) {
            c.vkDestroyPipeline(self.device, self.pipeline, null);
            c.vkDestroyPipeline(self.device, self.cell_pipeline, null);
            c.vkDestroyPipeline(self.device, self.glow_pipeline, null);
            c.vkDestroyPipeline(self.device, self.glow_cell_pipeline, null);
            c.vkDestroyRenderPass(self.device, self.pass, null);
            self.pipeline = null;
            self.cell_pipeline = null;
            self.glow_pipeline = null;
            self.glow_cell_pipeline = null;
            self.pass = null;
        }
        if (self.pass == null) try self.createPass();
        for (0..self.count) |i| {
            try self.createView(self.images.items[i], self.format, &self.views[i]);
            var framebuffer = info(c.VkFramebufferCreateInfo, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO);
            framebuffer.renderPass = self.pass;
            framebuffer.attachmentCount = 1;
            framebuffer.pAttachments = &self.views[i];
            framebuffer.width = self.extent.width;
            framebuffer.height = self.extent.height;
            framebuffer.layers = 1;
            try created(c.vkCreateFramebuffer(self.device, &framebuffer, null, &self.framebuffers[i]), &self.framebuffers[i]);
            var sem = info(c.VkSemaphoreCreateInfo, c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
            try created(c.vkCreateSemaphore(self.device, &sem, null, &self.finished[i]), &self.finished[i]);
        }
        phases.end(.swapchain);
    }
    fn createPass(self: *Renderer) !void {
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = self.format;
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        const reference = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &reference;
        const dependency = c.VkSubpassDependency{ .srcSubpass = c.VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dependencyFlags = 0 };
        var pass = info(c.VkRenderPassCreateInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO);
        pass.attachmentCount = 1;
        pass.pAttachments = &attachment;
        pass.subpassCount = 1;
        pass.pSubpasses = &subpass;
        pass.dependencyCount = 1;
        pass.pDependencies = &dependency;
        try created(c.vkCreateRenderPass(self.device, &pass, null, &self.pass), &self.pass);
        self.pass_format = self.format;
        try self.createPipeline();
    }
    fn shader(self: *Renderer, bytes: []const u8) !c.VkShaderModule {
        const aligned: []align(4) const u8 = @alignCast(bytes);
        var create = info(c.VkShaderModuleCreateInfo, c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
        create.codeSize = aligned.len;
        create.pCode = @ptrCast(aligned.ptr);
        var module: c.VkShaderModule = null;
        try check(c.vkCreateShaderModule(self.device, &create, null, &module));
        return module;
    }
    const ui_binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
    const ui_attrs = [_]c.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "position") },
        .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "color") },
        .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "local") },
        .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "half") },
        .{ .location = 5, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Vertex, "shape") },
    };
    const cell_binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Cell), .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE };
    const cell_attrs = [_]c.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Cell, "rect") },
        .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(Cell, "fill") },
        .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(Cell, "accent") },
        .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(Cell, "overlay") },
        .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(Cell, "kind") },
    };
    const vert_spv align(4) = @embedFile("vert_spv").*;
    const frag_spv align(4) = @embedFile("frag_spv").*;
    const cell_vert_spv align(4) = @embedFile("cell_vert_spv").*;
    const cell_frag_spv align(4) = @embedFile("cell_frag_spv").*;
    /// The plain UI pipeline every frame uses; the cell and additive ones are
    /// made by the first frame that draws them (ensurePipelines).
    fn createPipeline(self: *Renderer) !void {
        self.pipeline = try self.makePipeline(&vert_spv, &frag_spv, ui_binding, &ui_attrs, false);
    }
    /// Graphics pipelines made so far (2D ones; scene3d has its own).
    pub fn pipelineCount(self: *const Renderer) usize {
        var n: usize = 0;
        for ([_]c.VkPipeline{ self.pipeline, self.cell_pipeline, self.glow_pipeline, self.glow_cell_pipeline }) |p| n += @intFromBool(p != null);
        return n;
    }
    fn ensurePipelines(self: *Renderer) !void {
        for (self.batches[0..self.batch_count]) |b| {
            if (b.additive) {
                if (self.glow_cell_pipeline == null) self.glow_cell_pipeline = try self.makePipeline(&cell_vert_spv, &cell_frag_spv, cell_binding, &cell_attrs, true);
                if (b.cloud != null and self.glow_pipeline == null) self.glow_pipeline = try self.makePipeline(&vert_spv, &frag_spv, ui_binding, &ui_attrs, true);
            } else if (self.cell_pipeline == null) self.cell_pipeline = try self.makePipeline(&cell_vert_spv, &cell_frag_spv, cell_binding, &cell_attrs, false);
        }
    }
    fn makePipeline(self: *Renderer, vert_bytes: []const u8, frag_bytes: []const u8, binding: c.VkVertexInputBindingDescription, attrs: []const c.VkVertexInputAttributeDescription, additive: bool) !c.VkPipeline {
        const vert = try self.shader(vert_bytes);
        defer c.vkDestroyShaderModule(self.device, vert, null);
        const frag = try self.shader(frag_bytes);
        defer c.vkDestroyShaderModule(self.device, frag, null);
        var stages: [2]c.VkPipelineShaderStageCreateInfo = .{ info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO), info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO) };
        stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vert;
        stages[0].pName = "main";
        stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = frag;
        stages[1].pName = "main";
        var input = info(c.VkPipelineVertexInputStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
        input.vertexBindingDescriptionCount = 1;
        input.pVertexBindingDescriptions = &binding;
        input.vertexAttributeDescriptionCount = @intCast(attrs.len);
        input.pVertexAttributeDescriptions = attrs.ptr;
        var assembly = info(c.VkPipelineInputAssemblyStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO);
        assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        var viewport = info(c.VkPipelineViewportStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO);
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        var raster = info(c.VkPipelineRasterizationStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
        raster.polygonMode = c.VK_POLYGON_MODE_FILL;
        raster.cullMode = c.VK_CULL_MODE_NONE;
        raster.lineWidth = 1;
        var samples = info(c.VkPipelineMultisampleStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO);
        samples.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.blendEnable = c.VK_TRUE;
        blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        blend_attachment.dstColorBlendFactor = if (additive) c.VK_BLEND_FACTOR_ONE else c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend_attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
        blend_attachment.colorWriteMask = 15;
        var blend = info(c.VkPipelineColorBlendStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO);
        blend.attachmentCount = 1;
        blend.pAttachments = &blend_attachment;
        const states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic = info(c.VkPipelineDynamicStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
        dynamic.dynamicStateCount = states.len;
        dynamic.pDynamicStates = &states;
        var create = info(c.VkGraphicsPipelineCreateInfo, c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
        create.stageCount = stages.len;
        create.pStages = &stages;
        create.pVertexInputState = &input;
        create.pInputAssemblyState = &assembly;
        create.pViewportState = &viewport;
        create.pRasterizationState = &raster;
        create.pMultisampleState = &samples;
        create.pColorBlendState = &blend;
        create.pDynamicState = &dynamic;
        create.layout = self.layout;
        create.renderPass = self.pass;
        var pipeline: c.VkPipeline = null;
        try check(c.vkCreateGraphicsPipelines(self.device, null, 1, &create, null, &pipeline));
        return pipeline;
    }
    /// Releases what depends on the extent. The swapchain handle survives to seed its replacement.
    fn destroySwap(self: *Renderer) void {
        if (self.scene_gpu) |*scene_gpu| scene_gpu.destroyExtent();
        for (self.framebuffers) |framebuffer| if (framebuffer != null) c.vkDestroyFramebuffer(self.device, framebuffer, null);
        for (self.views) |view| if (view != null) c.vkDestroyImageView(self.device, view, null);
        for (self.finished) |semaphore| if (semaphore != null) c.vkDestroySemaphore(self.device, semaphore, null);
        std.heap.page_allocator.free(self.framebuffers);
        std.heap.page_allocator.free(self.views);
        std.heap.page_allocator.free(self.finished);
        self.images.deinit(std.heap.page_allocator);
        self.images = .empty;
        self.count = 0;
        self.framebuffers = &.{};
        self.views = &.{};
        self.finished = &.{};
    }
    pub fn deinit(self: *Renderer) void {
        if (self.window) |window| window.cancelFrame();
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
            if (self.scene_gpu) |*scene_gpu| scene_gpu.deinit();
            self.scene_gpu = null;
            self.destroySwap();
            if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
            if (self.cell_pipeline != null) c.vkDestroyPipeline(self.device, self.cell_pipeline, null);
            if (self.glow_pipeline != null) c.vkDestroyPipeline(self.device, self.glow_pipeline, null);
            if (self.glow_cell_pipeline != null) c.vkDestroyPipeline(self.device, self.glow_cell_pipeline, null);
            if (self.pass != null) c.vkDestroyRenderPass(self.device, self.pass, null);
            if (self.swap != null) c.vkDestroySwapchainKHR(self.device, self.swap, null);
            c.vkDestroyPipelineLayout(self.device, self.layout, null);
            c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
            c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
            c.vkDestroySampler(self.device, self.sampler, null);
            c.vkDestroyImageView(self.device, self.atlas_view, null);
            c.vkDestroyImage(self.device, self.atlas, null);
            c.vkFreeMemory(self.device, self.atlas_memory, null);
            if (self.mapped != null) c.vkUnmapMemory(self.device, self.memory);
            c.vkDestroyBuffer(self.device, self.buffer, null);
            c.vkFreeMemory(self.device, self.memory, null);
            c.vkDestroyFence(self.device, self.fence, null);
            c.vkDestroySemaphore(self.device, self.available, null);
            c.vkDestroyCommandPool(self.device, self.pool, null);
            c.vkDestroyDevice(self.device, null);
        }
        if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.* = .{};
    }
    /// False means no frame can be drawn yet. Keep pumping the event loop and
    /// do not overwrite mapped vertices or reset commands until the fence signals.
    pub fn begin(self: *Renderer, width: u32, height: u32, scale: f32) !bool {
        if (self.window) |window| if (!window.frameReady()) {
            self.deferral.pending("compositor frame callback");
            return false;
        };
        const ready = c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, 0);
        if (ready == c.VK_TIMEOUT) {
            self.deferral.pending("frame fence");
            return false;
        }
        try check(ready);
        if (self.scene_gpu) |*scene_gpu| scene_gpu.timerRead();
        self.scene_requested = false;
        const changed = @as(u32, @intFromFloat(self.ui_width)) != width or @as(u32, @intFromFloat(self.ui_height)) != height or self.ui_scale != scale;
        self.ui_scale = try @import("../platform/window.zig").validateScale(scale);
        const pixels = if (self.window) |window| window.bufferExtent() else @import("../platform/window.zig").Extent{
            .width = @import("../platform/window.zig").deviceExtent(width, self.ui_scale),
            .height = @import("../platform/window.zig").deviceExtent(height, self.ui_scale),
        };
        const physical_width = pixels.width;
        const physical_height = pixels.height;
        if (physical_width != self.extent.width or physical_height != self.extent.height) {
            try check(c.vkDeviceWaitIdle(self.device));
            self.destroySwap();
            try self.createSwap(physical_width, physical_height);
        }
        // Keep projection and pixel clipping on exactly the same scale even
        // when the final UI unit only partly fits in a fractional-size window.
        self.ui_width = @as(f32, @floatFromInt(self.extent.width)) / self.ui_scale;
        self.ui_height = @as(f32, @floatFromInt(self.extent.height)) / self.ui_scale;
        if (changed and c.getenv("XODB_INPUT_TRACE") != null)
            log.info(.render, "ui layout units={d}x{d} buffer={d}x{d} scale={d:.2}\n", .{ width, height, self.extent.width, self.extent.height, self.ui_scale });
        self.vertices = 0;
        self.cells_used = 0;
        self.batch_count = 0;
        self.clip = self.fullClip();
        return true;
    }
    pub fn fullClip(self: *const Renderer) Rect {
        return .{ .x = 0, .y = 0, .w = self.ui_width, .h = self.ui_height };
    }
    /// Record one clipped scene at the current UI layer. Call only after begin
    /// returns true; returned instance writers remain valid until the next reserve.
    pub fn scene(self: *Renderer, bounds: Rect, view_projection: scene3d.math.Mat4) !?*scene3d.Gpu {
        if (self.scene_requested) return error.SceneAlreadyRecorded;
        for ([_]f32{ bounds.x, bounds.y, bounds.w, bounds.h, bounds.x + bounds.w, bounds.y + bounds.h }) |v| if (!std.math.isFinite(v)) return error.InvalidSceneBounds;
        for (view_projection) |v| if (!std.math.isFinite(v)) return error.InvalidSceneMatrix;
        const x0 = @max(0, @max(self.clip.x, bounds.x));
        const y0 = @max(0, @max(self.clip.y, bounds.y));
        const x1 = @min(self.ui_width, @min(self.clip.x + self.clip.w, bounds.x + bounds.w));
        const y1 = @min(self.ui_height, @min(self.clip.y + self.clip.h, bounds.y + bounds.h));
        if (x1 <= x0 or y1 <= y0) return null;
        const now = Wait.now();
        if (self.scene_retry.waiting(now)) |err| return err;
        if (self.scene_gpu == null) {
            self.scene_gpu = .{ .ctx = .{ .device = self.device, .physical = self.physical, .font_layout = self.descriptor_layout, .font_descriptor = self.descriptor, .family = self.family } };
            self.scene_gpu.?.init() catch |err| {
                self.scene_gpu = null;
                self.scene_retry.failed(now, err);
                return err;
            };
        }
        const out = &self.scene_gpu.?;
        out.extent(self.extent.width, self.extent.height, self.pass) catch |err| {
            self.scene_retry.failed(now, err);
            return err;
        };
        self.scene_retry = .{};
        out.stats = .{ .gpu_ns = out.stats.gpu_ns };
        const px0 = @floor(x0 * self.ui_scale);
        const py0 = @floor(y0 * self.ui_scale);
        const px1 = @ceil(x1 * self.ui_scale);
        const py1 = @ceil(y1 * self.ui_scale);
        out.bounds = .{ .x = px0, .y = py0, .w = px1 - px0, .h = py1 - py0 };
        out.push.view_projection = view_projection;
        out.push.scale = self.ui_scale;
        self.scene_at = self.vertices;
        self.scene_after_batches = self.batch_count;
        self.scene_requested = true;
        return out;
    }
    /// Screen-sized glyphs anchored in world space, using the ordinary shaped
    /// glyph cache and atlas. The GPU projects the anchor and depth-tests them.
    pub fn sceneText(self: *Renderer, font: *fonts.Font, anchor: [3]f32, offset: [2]f32, str: []const u8, color: Color) !void {
        return self.sceneTextBasis(font, anchor, offset, str, color, null);
    }
    /// World-space glyph quads on a surface, with one world vector per font pixel.
    pub fn sceneSurfaceText(self: *Renderer, font: *fonts.Font, anchor: [3]f32, right: [3]f32, down: [3]f32, str: []const u8, color: Color) !void {
        return self.sceneTextBasis(font, anchor, .{ 0, 0 }, str, color, .{ right, down });
    }
    fn sceneTextBasis(self: *Renderer, font: *fonts.Font, anchor: [3]f32, offset: [2]f32, str: []const u8, color: Color, basis: ?[2][3]f32) !void {
        if (!self.scene_requested) return error.SceneNotRecorded;
        if (str.len > 4096) return error.SceneTextLimit;
        const run = shapeRun(font, str);
        const gpu = &self.scene_gpu.?;
        const first = gpu.stats.glyphs;
        const glyphs = try gpu.glyphs(@as(usize, first) + run.count);
        var pen = offset[0];
        for (0..run.count) |i| {
            const pos = run.positions[i];
            const g = font.glyph(run.glyphs[i].codepoint) catch try font.glyph(0);
            glyphs.set(first + i, .{
                .anchor = .{ anchor[0], anchor[1], anchor[2], if (basis == null) 1 else 0 },
                .right = if (basis) |b| .{ b[0][0], b[0][1], b[0][2], 0 } else @splat(0),
                .down = if (basis) |b| .{ b[1][0], b[1][1], b[1][2], 0 } else @splat(0),
                .rect = .{ deviceSnap(self, pen + fontMetric(font, pos.x_offset) + glyphMetric(font, g.left)), deviceSnap(self, offset[1] + 16 - glyphMetric(font, g.top) - fontMetric(font, pos.y_offset)), glyphMetric(font, g.w), glyphMetric(font, g.h) },
                .uv = .{ @as(f32, @floatFromInt(g.x)) / fonts.atlas_size, @as(f32, @floatFromInt(g.y)) / fonts.atlas_size, @as(f32, @floatFromInt(g.w)) / fonts.atlas_size, @as(f32, @floatFromInt(g.h)) / fonts.atlas_size },
                .color = color,
            });
            pen += fontMetric(font, pos.x_advance);
        }
    }
    fn sceneComposite(self: *Renderer) void {
        self.scene_gpu.?.composite(self.command);
        c.vkCmdBindPipeline(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        const offset: u64 = 0;
        c.vkCmdBindVertexBuffers(self.command, 0, 1, &self.buffer, &offset);
        c.vkCmdBindDescriptorSets(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layout, 0, 1, &self.descriptor, 0, null);
        const size = [8]f32{ self.ui_width, self.ui_height, 1, 1, 0, 0, 1, 0 };
        c.vkCmdPushConstants(self.command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(size)), &size);
        const clip = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        c.vkCmdSetScissor(self.command, 0, 1, &clip);
    }
    pub fn quad(self: *Renderer, bounds: Rect, uv: Rect, color: Color) !void {
        const x0 = @max(bounds.x, self.clip.x);
        const y0 = @max(bounds.y, self.clip.y);
        const x1 = @min(bounds.x + bounds.w, self.clip.x + self.clip.w);
        const y1 = @min(bounds.y + bounds.h, self.clip.y + self.clip.h);
        if (x1 <= x0 or y1 <= y0) return;
        const tex_x0 = uv.x + uv.w * (x0 - bounds.x) / bounds.w;
        const v0 = uv.y + uv.h * (y0 - bounds.y) / bounds.h;
        const tex_x1 = uv.x + uv.w * (x1 - bounds.x) / bounds.w;
        const v1 = uv.y + uv.h * (y1 - bounds.y) / bounds.h;
        if ((self.vertices + 6) * @sizeOf(Vertex) > vertex_bytes) return error.VertexBufferFull;
        const vertices: [*]Vertex = @ptrCast(@alignCast(self.mapped.?));
        const a = Vertex{ .position = .{ x0, y0 }, .uv = .{ tex_x0, v0 }, .color = color };
        const b = Vertex{ .position = .{ x1, y0 }, .uv = .{ tex_x1, v0 }, .color = color };
        const d = Vertex{ .position = .{ x0, y1 }, .uv = .{ tex_x0, v1 }, .color = color };
        const e = Vertex{ .position = .{ x1, y1 }, .uv = .{ tex_x1, v1 }, .color = color };
        vertices[self.vertices..][0..6].* = .{ a, b, e, a, e, d };
        self.vertices += 6;
    }
    /// A rounded, bordered, soft-edged, or gradient rectangle, clipped like `quad`.
    /// Softness is inside the bounds, so a soft shadow needs bounds grown by twice its softness.
    pub fn shape(self: *Renderer, bounds: Rect, color: Color, s: Shape) !void {
        const x0 = @max(bounds.x, self.clip.x);
        const y0 = @max(bounds.y, self.clip.y);
        const x1 = @min(bounds.x + bounds.w, self.clip.x + self.clip.w);
        const y1 = @min(bounds.y + bounds.h, self.clip.y + self.clip.h);
        if (x1 <= x0 or y1 <= y0) return;
        if ((self.vertices + 6) * @sizeOf(Vertex) > vertex_bytes) return error.VertexBufferFull;
        const colors = s.colors orelse [4]Color{ color, color, color, color };
        const white = @as(f32, 0.5) / fonts.atlas_size;
        var v: [4]Vertex = undefined;
        for ([4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y1 } }, 0..) |p, i| {
            // Corner attributes at the clipped position: weights of the four original corners.
            const u = (p[0] - bounds.x) / bounds.w;
            const t = (p[1] - bounds.y) / bounds.h;
            const weights = [4]f32{ (1 - u) * (1 - t), u * (1 - t), (1 - u) * t, u * t };
            var tint: Color = @splat(0);
            var radius: f32 = 0;
            for (weights, 0..) |weight, corner| {
                for (&tint, colors[corner]) |*channel, value| channel.* += weight * value;
                radius += weight * s.radii[corner];
            }
            v[i] = .{ .position = p, .uv = .{ white, white }, .color = tint, .local = .{ p[0] - bounds.x - bounds.w / 2, p[1] - bounds.y - bounds.h / 2 }, .half = .{ bounds.w / 2, bounds.h / 2 }, .shape = .{ radius, s.border, s.softness } };
        }
        const vertices: [*]Vertex = @ptrCast(@alignCast(self.mapped.?));
        vertices[self.vertices..][0..6].* = .{ v[0], v[1], v[3], v[0], v[3], v[2] };
        self.vertices += 6;
    }
    /// Reserves `n` instanced cells, drawn above everything recorded so far and
    /// below what follows, clipped to the current clip. Fill every record.
    pub fn cells(self: *Renderer, n: usize) ![]Cell {
        if (n == 0) return &.{};
        if (self.batch_count == self.batches.len or self.cells_used + n > cell_capacity) return error.VertexBufferFull;
        const all: [*]Cell = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self.mapped.?)) + cell_offset));
        self.batches[self.batch_count] = .{ .at = self.vertices, .first = self.cells_used, .count = @intCast(n), .clip = self.clip };
        self.batch_count += 1;
        defer self.cells_used += @intCast(n);
        return all[self.cells_used..][0..n];
    }

    /// Retain static galaxy geometry in a separate mapped region. begin() has
    /// waited for the single in-flight fence; subsequent frames need no upload.
    /// The transient vertices since `first` must contain only cloud geometry.
    pub fn retainCloud(self: *Renderer, slot: CloudSlot, first: usize, points: []const Cell, signature: u64) !void {
        const count = self.vertices - first;
        const bytes = count * @sizeOf(Vertex);
        if (bytes > cloud_vertex_bytes or points.len > 22000) return error.VertexBufferFull;
        const mapped: [*]u8 = @ptrCast(self.mapped.?);
        const offset = @as(usize, slot) * cloud_stride;
        @memcpy(mapped[cloud_vertex_offset + offset ..][0..bytes], mapped[first * @sizeOf(Vertex) ..][0..bytes]);
        @memcpy(mapped[cloud_cell_offset + offset ..][0 .. points.len * @sizeOf(Cell)], std.mem.sliceAsBytes(points));
        self.vertices = first;
        self.clouds[slot] = .{ .vertices = @intCast(count), .cells = @intCast(points.len), .signature = signature };
    }
    pub fn glowingCells(self: *Renderer, n: usize) ![]Cell {
        const points = try self.cells(n);
        if (n > 0) self.batches[self.batch_count - 1].additive = true;
        return points;
    }
    pub fn cloud(self: *Renderer, slot: CloudSlot, transform: [6]f32, additive: bool) !void {
        if (self.batch_count == self.batches.len) return error.VertexBufferFull;
        self.batches[self.batch_count] = .{ .at = self.vertices, .first = 0, .count = self.clouds[slot].cells, .clip = self.clip, .cloud = slot, .additive = additive, .transform = transform };
        self.batch_count += 1;
    }
    /// Fraction of this frame's vertex buffer already used (0..1).
    pub fn used(self: *const Renderer) f32 {
        return @as(f32, @floatFromInt(self.vertices * @sizeOf(Vertex))) / vertex_bytes;
    }
    /// One flat-shaded triangle with a color per corner. Not clipped: callers
    /// clip polygons first (ui/overview/draw.zig does).
    pub fn triangle(self: *Renderer, p: [3][2]f32, colors: [3]Color) !void {
        if ((self.vertices + 3) * @sizeOf(Vertex) > vertex_bytes) return error.VertexBufferFull;
        const white = @as(f32, 0.5) / fonts.atlas_size;
        const vertices: [*]Vertex = @ptrCast(@alignCast(self.mapped.?));
        for (0..3) |i| vertices[self.vertices + i] = .{ .position = p[i], .uv = .{ white, white }, .color = colors[i] };
        self.vertices += 3;
    }
    pub fn rect(self: *Renderer, r: Rect, color: Color) !void {
        try self.quad(r, .{ .x = @as(f32, 0.5) / fonts.atlas_size, .y = @as(f32, 0.5) / fonts.atlas_size, .w = 0, .h = 0 }, color);
    }
    const Run = struct { glyphs: [*c]c.hb_glyph_info_t, positions: [*c]c.hb_glyph_position_t, count: u32 };
    /// --redact: drawn and measured text is scrubbed here, below every pane.
    /// HarfBuzz copies the text, so one scratch buffer serves every call.
    var redact_scratch: [16384]u8 = undefined;
    fn shapeRun(font: *fonts.Font, given: []const u8) Run {
        const str = if (redact.active()) |policy| policy.scrubInto(&redact_scratch, given) else given;
        c.hb_buffer_reset(font.buffer);
        c.hb_buffer_add_utf8(font.buffer, str.ptr, @intCast(str.len), 0, @intCast(str.len));
        c.hb_buffer_guess_segment_properties(font.buffer);
        c.hb_shape(font.hb, font.buffer, null, 0);
        var count: u32 = 0;
        const glyphs = c.hb_buffer_get_glyph_infos(font.buffer, &count);
        const positions = c.hb_buffer_get_glyph_positions(font.buffer, null);
        if (font.pixel and count != 0) for (positions[0..count]) |*position| {
            position.x_advance = @intFromFloat(@round(@as(f64, @floatFromInt(position.x_advance)) / 64) * 64);
            position.x_offset = @intFromFloat(@round(@as(f64, @floatFromInt(position.x_offset)) / 64) * 64);
            position.y_offset = @intFromFloat(@round(@as(f64, @floatFromInt(position.y_offset)) / 64) * 64);
        };
        return .{ .glyphs = glyphs, .positions = positions, .count = count };
    }
    fn fontMetric(font: *const fonts.Font, value: anytype) f32 {
        return @as(f32, @floatFromInt(value)) / 64 / font.raster_scale;
    }
    fn glyphMetric(font: *const fonts.Font, value: anytype) f32 {
        return @as(f32, @floatFromInt(value)) / font.raster_scale;
    }
    fn deviceSnap(self: *const Renderer, value: f32) f32 {
        return @round(value * self.ui_scale) / self.ui_scale;
    }
    /// Draws one shaped glyph and returns the pen position after it.
    fn glyphAt(self: *Renderer, font: *fonts.Font, id: u32, pos: c.hb_glyph_position_t, pen: f32, y: f32, color: Color) !f32 {
        const next = pen + fontMetric(font, pos.x_advance);
        // Report degradation once and use the reserved missing-glyph box.
        const g = font.glyph(id) catch |err| fallback: {
            if (!font.degraded) log.warn(.render, "Text rendering degraded: {s}; using missing-glyph boxes\n", .{@errorName(err)});
            font.degraded = true;
            break :fallback font.glyph(0) catch return next;
        };
        try self.quad(.{ .x = deviceSnap(self, pen + fontMetric(font, pos.x_offset) + glyphMetric(font, g.left)), .y = deviceSnap(self, y + 16 - glyphMetric(font, g.top) - fontMetric(font, pos.y_offset)), .w = glyphMetric(font, g.w), .h = glyphMetric(font, g.h) }, .{ .x = @as(f32, @floatFromInt(g.x)) / fonts.atlas_size, .y = @as(f32, @floatFromInt(g.y)) / fonts.atlas_size, .w = @as(f32, @floatFromInt(g.w)) / fonts.atlas_size, .h = @as(f32, @floatFromInt(g.h)) / fonts.atlas_size }, color);
        return next;
    }
    pub fn text(self: *Renderer, font: *fonts.Font, x: f32, y: f32, str: []const u8, color: Color) !void {
        const run = shapeRun(font, str);
        var pen = x;
        for (0..run.count) |i| pen = try self.glyphAt(font, run.glyphs[i].codepoint, run.positions[i], pen, y, color);
    }
    /// Word wrapping in a bounded cell. Only an overlong word or the last
    /// available line is elided; textFit supplies its visible ellipsis.
    pub fn textWrap(self: *Renderer, font: *fonts.Font, cell: Rect, str: []const u8, color: Color) !void {
        const step = font.ui_size + 6;
        var rest = std.mem.trim(u8, str, " \n");
        var y = cell.y;
        while (rest.len > 0 and y + font.ui_size <= cell.y + cell.h) : (y += step) {
            if (y + step + font.ui_size > cell.y + cell.h or self.measure(font, rest) <= cell.w) {
                try self.textFit(font, cell.x, y, cell.w, rest, color);
                break;
            }
            var line_end: usize = 0;
            var words = std.mem.tokenizeAny(u8, rest, " \n");
            while (words.next()) |word| {
                const next = @intFromPtr(word.ptr) - @intFromPtr(rest.ptr) + word.len;
                if (self.measure(font, rest[0..next]) > cell.w) {
                    if (line_end == 0) line_end = next;
                    break;
                }
                line_end = next;
            }
            if (line_end == 0) break;
            try self.textFit(font, cell.x, y, cell.w, rest[0..line_end], color);
            rest = std.mem.trimStart(u8, rest[line_end..], " \n");
        }
    }
    /// Advance width of `str` in pixels.
    pub fn measure(_: *Renderer, font: *fonts.Font, str: []const u8) f32 {
        const run = shapeRun(font, str);
        var advance: i32 = 0;
        for (0..run.count) |i| advance += run.positions[i].x_advance;
        return fontMetric(font, advance);
    }
    /// Draws `str` in at most `width` pixels. An overflowing run ends in three dots,
    /// each at half the alpha of the one before (after RAD Debugger's truncation).
    pub fn textFit(self: *Renderer, font: *fonts.Font, x: f32, y: f32, width: f32, str: []const u8, color: Color) !void {
        const dot = shapeRun(font, ".");
        if (dot.count != 1) return self.text(font, x, y, str, color);
        const dot_id = dot.glyphs[0].codepoint;
        const dot_pos = dot.positions[0];
        const dots = 3 * fontMetric(font, dot_pos.x_advance);
        const run = shapeRun(font, str);
        var total: i32 = 0;
        for (0..run.count) |i| total += run.positions[i].x_advance;
        const fits = fontMetric(font, total) <= width;
        var pen = x;
        for (0..run.count) |i| {
            if (!fits and pen + fontMetric(font, run.positions[i].x_advance) + dots > x + width) break;
            pen = try self.glyphAt(font, run.glyphs[i].codepoint, run.positions[i], pen, y, color);
        }
        if (fits or dots > width) return;
        var faded = color;
        for (0..3) |_| {
            pen = try self.glyphAt(font, dot_id, dot_pos, pen, y, faded);
            faded[3] *= 0.5;
        }
    }
    pub fn end(self: *Renderer, font: *fonts.Font) !bool {
        if (!self.scene_requested) {
            if (self.scene_gpu) |*scene_gpu| scene_gpu.deinit();
            self.scene_gpu = null;
        }
        // Before acquiring: a failed pipeline must not leave an image acquired.
        try self.ensurePipelines();
        var image_index: u32 = 0;
        var call_started = Wait.now();
        const acquired = c.vkAcquireNextImageKHR(self.device, self.swap, 0, self.available, null, &image_index);
        reportSlowCall("vkAcquireNextImageKHR", call_started);
        if (acquired == c.VK_TIMEOUT or acquired == c.VK_NOT_READY) {
            self.deferral.pending("swapchain image");
            return false;
        }
        self.deferral.drawing();
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) {
            self.extent.width = 0;
            return false;
        }
        if (acquired != c.VK_SUBOPTIMAL_KHR) try check(acquired);
        try check(c.vkResetCommandBuffer(self.command, 0));
        var begin_info = info(c.VkCommandBufferBeginInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(c.vkBeginCommandBuffer(self.command, &begin_info));
        if (self.scene_requested) self.scene_gpu.?.timerStart(self.command);
        if (font.dirty and self.atlas_linear) {
            // The previous frame's fence has signalled (begin), so nothing
            // samples the atlas now; submission makes these writes visible.
            const rows = font.usedRows();
            for (0..rows) |row| @memcpy(self.atlas_mapped.?[row * self.atlas_pitch ..][0..fonts.atlas_size], font.pixels.?[row * fonts.atlas_size ..][0..fonts.atlas_size]);
            if (!self.atlas_ready) {
                var barrier = info(c.VkImageMemoryBarrier, c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
                barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_PREINITIALIZED;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
                barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
                barrier.image = self.atlas;
                barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
                c.vkCmdPipelineBarrier(self.command, c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            }
            font.dirty = false;
            self.atlas_ready = true;
        }
        if (font.dirty) {
            const dest: [*]u8 = @ptrCast(self.mapped.?);
            // Only the rows glyphs reached: the rest of the atlas is never sampled.
            const rows = font.usedRows();
            @memcpy(dest[vertex_bytes..][0 .. rows * fonts.atlas_size], font.pixels.?[0 .. rows * fonts.atlas_size]);
            var barrier = info(c.VkImageMemoryBarrier, c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER);
            barrier.srcAccessMask = if (self.atlas_ready) c.VK_ACCESS_SHADER_READ_BIT else 0;
            barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.oldLayout = if (self.atlas_ready) c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else c.VK_IMAGE_LAYOUT_UNDEFINED;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = self.atlas;
            barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            c.vkCmdPipelineBarrier(self.command, if (self.atlas_ready) c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT else c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
            var copy = std.mem.zeroes(c.VkBufferImageCopy);
            copy.bufferOffset = vertex_bytes;
            copy.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
            copy.imageExtent = .{ .width = fonts.atlas_size, .height = rows, .depth = 1 };
            c.vkCmdCopyBufferToImage(self.command, self.buffer, self.atlas, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            c.vkCmdPipelineBarrier(self.command, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            font.dirty = false;
            self.atlas_ready = true;
        }
        if (self.scene_requested) self.scene_gpu.?.record(self.command);
        const clear = c.VkClearValue{ .color = .{ .float32 = @import("../appearance.zig").active.colors.background } };
        var pass = info(c.VkRenderPassBeginInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO);
        pass.renderPass = self.pass;
        pass.framebuffer = self.framebuffers[image_index];
        pass.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        pass.clearValueCount = 1;
        pass.pClearValues = &clear;
        c.vkCmdBeginRenderPass(self.command, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(self.extent.width), .height = @floatFromInt(self.extent.height), .minDepth = 0, .maxDepth = 1 };
        const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = self.extent };
        c.vkCmdSetViewport(self.command, 0, 1, &viewport);
        c.vkCmdSetScissor(self.command, 0, 1, &scissor);
        c.vkCmdBindPipeline(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        const offset: u64 = 0;
        c.vkCmdBindVertexBuffers(self.command, 0, 1, &self.buffer, &offset);
        c.vkCmdBindDescriptorSets(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layout, 0, 1, &self.descriptor, 0, null);
        const size = [8]f32{ self.ui_width, self.ui_height, 1, 1, 0, 0, 1, 0 };
        c.vkCmdPushConstants(self.command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(size)), &size);
        var drawn: usize = 0;
        var scene_drawn = false;
        for (self.batches[0..self.batch_count], 0..) |b, batch_index| {
            if (self.scene_requested and !scene_drawn and batch_index == self.scene_after_batches) {
                if (self.scene_at > drawn) c.vkCmdDraw(self.command, @intCast(self.scene_at - drawn), 1, @intCast(drawn), 0);
                drawn = self.scene_at;
                self.sceneComposite();
                scene_drawn = true;
            }
            if (b.at > drawn) c.vkCmdDraw(self.command, @intCast(b.at - drawn), 1, @intCast(drawn), 0);
            drawn = b.at;
            const x0: i32 = @intFromFloat(@max(0, @floor(b.clip.x * self.ui_scale)));
            const y0: i32 = @intFromFloat(@max(0, @floor(b.clip.y * self.ui_scale)));
            const x1: i32 = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.extent.width)), @ceil((b.clip.x + b.clip.w) * self.ui_scale))));
            const y1: i32 = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(self.extent.height)), @ceil((b.clip.y + b.clip.h) * self.ui_scale))));
            if (x1 <= x0 or y1 <= y0) continue;
            const clip = c.VkRect2D{ .offset = .{ .x = x0, .y = y0 }, .extent = .{ .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) } };
            c.vkCmdSetScissor(self.command, 0, 1, &clip);
            if (b.cloud) |slot| {
                const transformed = [8]f32{ size[0], size[1], b.transform[0], b.transform[1], b.transform[2], b.transform[3], b.transform[4], b.transform[5] };
                c.vkCmdPushConstants(self.command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(transformed)), &transformed);
                c.vkCmdBindPipeline(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (b.additive) self.glow_pipeline else self.pipeline);
                const cloud_at: u64 = cloud_vertex_offset + @as(u64, slot) * cloud_stride;
                c.vkCmdBindVertexBuffers(self.command, 0, 1, &self.buffer, &cloud_at);
                c.vkCmdDraw(self.command, self.clouds[slot].vertices, 1, 0, 0);
            }
            c.vkCmdBindPipeline(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (b.additive) self.glow_cell_pipeline else self.cell_pipeline);
            const cells_at: u64 = if (b.cloud) |slot| cloud_cell_offset + @as(u64, slot) * cloud_stride else cell_offset;
            c.vkCmdBindVertexBuffers(self.command, 0, 1, &self.buffer, &cells_at);
            c.vkCmdDraw(self.command, 6, b.count, 0, b.first);
            if (b.cloud != null) c.vkCmdPushConstants(self.command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(size)), &size);
            c.vkCmdSetScissor(self.command, 0, 1, &scissor);
            c.vkCmdBindPipeline(self.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
            c.vkCmdBindVertexBuffers(self.command, 0, 1, &self.buffer, &offset);
        }
        if (self.scene_requested and !scene_drawn) {
            if (self.scene_at > drawn) c.vkCmdDraw(self.command, @intCast(self.scene_at - drawn), 1, @intCast(drawn), 0);
            drawn = self.scene_at;
            self.sceneComposite();
        }
        if (self.vertices > drawn) c.vkCmdDraw(self.command, @intCast(self.vertices - drawn), 1, @intCast(drawn), 0);
        c.vkCmdEndRenderPass(self.command);
        if (self.scene_requested) self.scene_gpu.?.timerEnd(self.command);
        try check(c.vkEndCommandBuffer(self.command));
        try check(c.vkResetFences(self.device, 1, &self.fence));
        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        var submit = info(c.VkSubmitInfo, c.VK_STRUCTURE_TYPE_SUBMIT_INFO);
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &self.available;
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &self.command;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &self.finished[image_index];
        call_started = Wait.now();
        phases.begin(.draw);
        const submitted = c.vkQueueSubmit(self.queue, 1, &submit, self.fence);
        reportSlowCall("vkQueueSubmit", call_started);
        try check(submitted);
        var present = info(c.VkPresentInfoKHR, c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &self.finished[image_index];
        present.swapchainCount = 1;
        present.pSwapchains = &self.swap;
        present.pImageIndices = &image_index;
        // A compositor can withhold frame callbacks for hidden workspaces.
        // Request pacing on this exact commit before Vulkan commits the surface.
        if (self.window) |window| try window.requestFrame();
        call_started = Wait.now();
        const result = c.vkQueuePresentKHR(self.queue, &present);
        if (result == c.VK_SUCCESS or result == c.VK_SUBOPTIMAL_KHR) phases.end(.draw);
        reportSlowCall("vkQueuePresentKHR", call_started);
        if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            if (self.window) |window| window.cancelFrame();
        }
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or acquired == c.VK_SUBOPTIMAL_KHR) self.extent.width = 0 else try check(result);
        return result != c.VK_ERROR_OUT_OF_DATE_KHR;
    }
};

/// Window-independent Vulkan setup on a thread from GUI startup, so that
/// instance and device creation (most of the time to the first frame) overlap
/// the session, window and font setup. Only for Wayland, where the
/// compositor's DRM node, and with it the device choice and loader filter,
/// can be asked for on a short private connection before the window exists.
const Early = struct {
    thread: ?std.Thread = null,
    renderer: Renderer = .{},
    display: ?select.Node = null,
    filtered: bool = false,
    layers_off: bool = false,
    failed: bool = false,
};
var early: Early = .{};
/// Call once, before the window, in a process that will draw a GUI window,
/// with the compositor's node from window.earlyDisplayGpu. The loader
/// variables are set here and cleared by the thread once its vkCreateInstance
/// returns (earlyRestore); launches wait for that in child_env.settle.
pub fn startEarly(display: ?select.Node) void {
    if (early.thread != null) return;
    early.display = display;
    child_env.hold();
    if (Renderer.loaderFilter(early.display)) |pattern| {
        _ = c.setenv("VK_LOADER_DRIVERS_SELECT", pattern, 1);
        early.filtered = true;
    }
    early.layers_off = Renderer.implicitLayersOff();
    early.thread = std.Thread.spawn(.{}, earlyRun, .{}) catch {
        earlyRestore();
        return;
    };
}
/// Once, on the early thread (or here when it could not start).
fn earlyRestore() void {
    if (early.filtered) _ = c.unsetenv("VK_LOADER_DRIVERS_SELECT");
    if (early.layers_off) _ = c.unsetenv("VK_LOADER_LAYERS_DISABLE");
    early.filtered = false;
    early.layers_off = false;
    child_env.release();
}
fn earlyRun() void {
    early.renderer.prepare(early.display) catch |err| {
        log.debug(.render, "Vulkan early setup failed: {s}; the window will set up Vulkan itself\n", .{@errorName(err)});
        early.failed = true;
    };
}
fn takeEarly() ?Renderer {
    const thread = early.thread orelse return null;
    thread.join();
    early.thread = null;
    if (early.failed) return null;
    defer early.renderer = .{};
    return early.renderer;
}

/// A frame is deferred while the compositor's frame callback, the frame fence
/// or a swapchain image is not ready: the usual cause is a hidden window. One
/// debug line when a deferral has lasted a second, naming what was awaited,
/// and one when frames flow again, with how long none was drawn. A throttled
/// window that draws about once a second stays inside one period. A compositor
/// that keeps sending slow callbacks to a hidden window can still end and
/// restart a period whenever xodb's own redraws become sparse, so the pair is
/// written at most once per `quiet`; a period inside that time says nothing.
const Deferral = struct {
    since: ?u64 = null,
    hidden: ?u64 = null,
    resumed: u64 = 0,
    label: []const u8 = "",
    said: bool = false,
    const long = 1_000_000_000;
    const quiet = 10 * long;
    fn pending(self: *Deferral, label: []const u8) void {
        const current = Wait.now();
        if (self.since == null) self.since = current;
        if (self.hidden != null or current -| self.since.? < long) return;
        self.hidden = self.since;
        self.resumed = 0;
        self.label = label;
        self.said = log.every(quiet, .debug, .render, "render {s} not ready for {d} ms; frame deferred, event loop remains active\n", .{ label, (current -| self.since.?) / 1_000_000 });
    }
    /// Every gate passed and this frame will be drawn. The period ends with
    /// the first frame that did not itself wait long.
    fn drawing(self: *Deferral) void {
        const since = self.since;
        self.since = null;
        const start = self.hidden orelse return;
        const current = Wait.now();
        if (since != null and current -| since.? >= long / 2) {
            self.resumed = current;
            return;
        }
        if (self.said) log.debug(.render, "render {s} ready after {d} ms\n", .{ self.label, (self.resumed -| start) / 1_000_000 });
        self.hidden = null;
    }
};
const Wait = struct {
    fn now() u64 {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    }
};

fn reportSlowCall(name: []const u8, started: u64) void {
    const elapsed = Wait.now() -| started;
    if (elapsed >= 250_000_000) log.debug(.render, "slow Vulkan {s}: {d} ms\n", .{ name, elapsed / 1_000_000 });
}

// Fast component lane: HarfBuzz returns null positions for an empty buffer.
test "retained cloud survives transient reuse and carries its own transform and blend" {
    const bytes = try std.testing.allocator.alignedAlloc(u8, .@"16", buffer_bytes);
    defer std.testing.allocator.free(bytes);
    var renderer = Renderer{ .mapped = bytes.ptr, .clip = .{ .x = 0, .y = 0, .w = 100, .h = 100 } };
    try renderer.rect(.{ .x = 2, .y = 3, .w = 4, .h = 5 }, .{ 1, 0, 0, 1 });
    const cell = Cell{ .rect = .{ 2, 3, 1, 1 }, .fill = .{ 255, 0, 0, 255 }, .accent = @splat(0), .overlay = @splat(0), .kind = 0 };
    try renderer.retainCloud(0, 0, &.{cell}, 7);
    try std.testing.expectEqual(@as(usize, 0), renderer.vertices);
    try std.testing.expectEqual(@as(u32, 6), renderer.clouds[0].vertices);
    try std.testing.expectEqual(@as(u64, 7), renderer.clouds[0].signature);
    try renderer.rect(.{ .x = 20, .y = 30, .w = 4, .h = 5 }, .{ 0, 1, 0, 1 });
    const retained: *const Vertex = @ptrCast(@alignCast(bytes.ptr + cloud_vertex_offset));
    try std.testing.expectEqual([2]f32{ 2, 3 }, retained.position);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&cell), bytes[cloud_cell_offset..][0..@sizeOf(Cell)]);
    try renderer.cloud(0, .{ 1.5, 1, 10, 20, 0, 1 }, true);
    const batch = renderer.batches[0];
    try std.testing.expect(batch.cloud == 0 and batch.additive and batch.at == 6 and batch.count == 1);
    try std.testing.expectEqual([6]f32{ 1.5, 1, 10, 20, 0, 1 }, batch.transform);
    try renderer.rect(.{ .x = 40, .y = 30, .w = 4, .h = 5 }, .{ 0, 0, 1, 1 });
    try renderer.retainCloud(1, 6, &.{cell}, 9);
    try renderer.cloud(1, .{ 1, 1, 0, 0, 1, 0 }, false);
    try std.testing.expectEqual([2]f32{ 2, 3 }, retained.position);
    const second: *const Vertex = @ptrCast(@alignCast(bytes.ptr + cloud_vertex_offset + cloud_stride));
    try std.testing.expectEqual([2]f32{ 40, 30 }, second.position);
    try std.testing.expectEqual(@as(u64, 7), renderer.clouds[0].signature);
    try std.testing.expectEqual(@as(u64, 9), renderer.clouds[1].signature);
    try std.testing.expect(renderer.batches[0].cloud == 0 and renderer.batches[1].cloud == 1);
}

test "empty text is safe with the bitmap font" {
    const a = std.testing.allocator;
    const font = try a.create(fonts.Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initRetro();
    defer font.deinit();
    var renderer = Renderer{};
    try std.testing.expectEqual(@as(f32, 0), renderer.measure(font, ""));
    try renderer.text(font, 0, 0, "", .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(@as(f32, 32), renderer.measure(font, "xodb"));
}

test "scaled faces retain UI-unit text metrics and bitmap faces retain their raster" {
    const a = std.testing.allocator;
    const font = try a.create(fonts.Font);
    defer a.destroy(font);
    font.* = .{};
    try font.initMode(@import("build_options").font_path ++ "", false);
    defer font.deinit();
    var renderer = Renderer{};
    const one = renderer.measure(font, "xodb workspace");
    const glyph_one = try font.glyph(c.FT_Get_Char_Index(font.face, 'x'));
    inline for (.{ 1.5, 2.0 }) |scale| {
        try std.testing.expect(try font.setScale(scale));
        const width = renderer.measure(font, "xodb workspace");
        try std.testing.expect(@abs(width - one) < one * 0.15);
        const glyph = try font.glyph(c.FT_Get_Char_Index(font.face, 'x'));
        try std.testing.expect(glyph.h >= glyph_one.h);
        try std.testing.expectEqual(@as(f32, scale), font.raster_scale);
    }
    font.deinit();
    font.* = .{};
    try font.initRetro();
    try std.testing.expect(try font.setScale(2));
    try std.testing.expectEqual(@as(f32, 1), font.raster_scale);
    try std.testing.expectEqual(@as(f32, 32), renderer.measure(font, "xodb"));
}

test "scene rejects invalid bounds, matrices and counts before Vulkan allocation" {
    var renderer = Renderer{};
    const matrix = scene3d.math.identity();
    try std.testing.expect(try renderer.scene(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, matrix) == null);
    try std.testing.expect(renderer.scene_gpu == null);
    try std.testing.expectError(error.InvalidSceneBounds, renderer.scene(.{ .x = std.math.nan(f32), .y = 0, .w = 1, .h = 1 }, matrix));
    var invalid = matrix;
    invalid[0] = std.math.inf(f32);
    try std.testing.expectError(error.InvalidSceneMatrix, renderer.scene(.{ .x = 0, .y = 0, .w = 1, .h = 1 }, invalid));
    var gpu = scene3d.Gpu{ .ctx = .{ .device = null, .physical = null, .font_layout = null, .font_descriptor = null, .family = 0 } };
    try std.testing.expectError(error.SceneInstanceLimit, gpu.boxes(scene3d.types.max_instances + 1));
    try std.testing.expectError(error.SceneInstanceLimit, gpu.points(scene3d.types.max_instances + 1));
    try std.testing.expectError(error.SceneInstanceLimit, gpu.lines(scene3d.types.max_instances + 1));
    try std.testing.expectError(error.SceneInstanceLimit, gpu.glyphs(scene3d.types.max_glyphs + 1));
    try std.testing.expectEqual(@as(u64, 0), gpu.allocated());
}
