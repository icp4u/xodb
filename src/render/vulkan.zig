const std = @import("std");
const c = @import("../c.zig").api;
const Window = @import("../platform/wayland.zig").Window;
const fonts = @import("font.zig");
pub const Color = [4]f32;
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: Color, local: [2]f32 = .{ 0, 0 }, half: [2]f32 = .{ 0, 0 }, shape: [3]f32 = .{ 0, 0, 0 } };
/// How a rectangle is drawn beyond a flat fill. Corners are ordered top-left, top-right,
/// bottom-left, bottom-right; `colors` gives one color per corner for gradients.
pub const Shape = struct { radii: [4]f32 = @splat(0), border: f32 = 0, softness: f32 = 0, colors: ?[4]Color = null };
const vertex_bytes = 8 * 1024 * 1024;
const buffer_bytes = vertex_bytes + fonts.atlas_size * fonts.atlas_size;
fn info(comptime T: type, kind: c.VkStructureType) T {
    var v = std.mem.zeroes(T);
    v.sType = kind;
    return v;
}
fn check(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) {
        std.debug.print("Vulkan result: {d}\n", .{result});
        return error.VulkanFailed;
    }
}

pub const Renderer = struct {
    window: ?*Window = null,
    compositor_wait: Wait = .{},
    fence_wait: Wait = .{},
    image_wait: Wait = .{},
    instance: c.VkInstance = null,
    surface: c.VkSurfaceKHR = null,
    physical: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    family: u32 = 0,
    swap: c.VkSwapchainKHR = null,
    format: c.VkFormat = c.VK_FORMAT_B8G8R8A8_UNORM,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    count: u32 = 0,
    images: [16]c.VkImage = @splat(null),
    views: [16]c.VkImageView = @splat(null),
    framebuffers: [16]c.VkFramebuffer = @splat(null),
    finished: [16]c.VkSemaphore = @splat(null),
    pass: c.VkRenderPass = null,
    pass_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    pipeline: c.VkPipeline = null,
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
    vertices: usize = 0,
    clip: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    gpu_name: [256]u8 = @splat(0),

    pub fn init(self: *Renderer, window: *Window) !void {
        self.window = window;
        errdefer self.deinit();
        var app = info(c.VkApplicationInfo, c.VK_STRUCTURE_TYPE_APPLICATION_INFO);
        app.pApplicationName = "xodb";
        app.apiVersion = c.VK_API_VERSION_1_0;
        const extensions = [_][*c]const u8{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
        var instance_info = info(c.VkInstanceCreateInfo, c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
        instance_info.pApplicationInfo = &app;
        instance_info.enabledExtensionCount = extensions.len;
        instance_info.ppEnabledExtensionNames = &extensions;
        try check(c.vkCreateInstance(&instance_info, null, &self.instance));
        var surface_info = info(c.VkWaylandSurfaceCreateInfoKHR, c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR);
        surface_info.display = window.display;
        surface_info.surface = window.surface;
        try check(c.vkCreateWaylandSurfaceKHR(self.instance, &surface_info, null, &self.surface));
        var devices: [16]c.VkPhysicalDevice = undefined;
        var count: u32 = devices.len;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, &devices));
        var best: i32 = -1;
        for (devices[0..count]) |physical| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(physical, &props);
            var families: [32]c.VkQueueFamilyProperties = undefined;
            var n: u32 = families.len;
            c.vkGetPhysicalDeviceQueueFamilyProperties(physical, &n, &families);
            for (families[0..n], 0..) |family, i| {
                var present: c.VkBool32 = 0;
                try check(c.vkGetPhysicalDeviceSurfaceSupportKHR(physical, @intCast(i), self.surface, &present));
                if (present == 0 or family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                const score: i32 = if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) 3 else if (props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) 2 else 1;
                if (score > best) {
                    self.physical = physical;
                    self.family = @intCast(i);
                    self.gpu_name = props.deviceName;
                    best = score;
                }
            }
        }
        if (self.physical == null) return error.NoPresentDevice;
        std.debug.print("Vulkan device: {s}\n", .{std.mem.sliceTo(@as([]const u8, &self.gpu_name), 0)});
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
        try check(c.vkCreateDevice(self.physical, &device_info, null, &self.device));
        c.vkGetDeviceQueue(self.device, self.family, 0, &self.queue);
        var pool_info = info(c.VkCommandPoolCreateInfo, c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
        pool_info.queueFamilyIndex = self.family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try check(c.vkCreateCommandPool(self.device, &pool_info, null, &self.pool));
        var cmd_info = info(c.VkCommandBufferAllocateInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
        cmd_info.commandPool = self.pool;
        cmd_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        cmd_info.commandBufferCount = 1;
        try check(c.vkAllocateCommandBuffers(self.device, &cmd_info, &self.command));
        var semaphore_info = info(c.VkSemaphoreCreateInfo, c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
        try check(c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.available));
        var fence_info = info(c.VkFenceCreateInfo, c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO);
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        try check(c.vkCreateFence(self.device, &fence_info, null, &self.fence));
        try self.createBuffer();
        try self.createAtlas();
        try self.createDescriptors();
        try self.createSwap(window.width, window.height);
    }
    fn memoryType(self: *Renderer, bits: u32, flags: u32) !u32 {
        var props: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical, &props);
        for (0..props.memoryTypeCount) |i| if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and (props.memoryTypes[i].propertyFlags & flags) == flags) return @intCast(i);
        return error.NoMemoryType;
    }
    fn allocate(self: *Renderer, req: c.VkMemoryRequirements, flags: u32, memory: *c.VkDeviceMemory) !void {
        var allocation = info(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        allocation.allocationSize = req.size;
        allocation.memoryTypeIndex = try self.memoryType(req.memoryTypeBits, flags);
        try check(c.vkAllocateMemory(self.device, &allocation, null, memory));
    }
    fn createBuffer(self: *Renderer) !void {
        var buffer_info = info(c.VkBufferCreateInfo, c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
        buffer_info.size = buffer_bytes;
        buffer_info.usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        try check(c.vkCreateBuffer(self.device, &buffer_info, null, &self.buffer));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, self.buffer, &req);
        try self.allocate(req, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &self.memory);
        try check(c.vkBindBufferMemory(self.device, self.buffer, self.memory, 0));
        try check(c.vkMapMemory(self.device, self.memory, 0, buffer_bytes, 0, &self.mapped));
    }
    fn createView(self: *Renderer, img: c.VkImage, format: c.VkFormat, view: *c.VkImageView) !void {
        var create = info(c.VkImageViewCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
        create.image = img;
        create.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        create.format = format;
        create.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try check(c.vkCreateImageView(self.device, &create, null, view));
    }
    fn createAtlas(self: *Renderer) !void {
        var create = info(c.VkImageCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
        create.imageType = c.VK_IMAGE_TYPE_2D;
        create.format = c.VK_FORMAT_R8_UNORM;
        create.extent = .{ .width = fonts.atlas_size, .height = fonts.atlas_size, .depth = 1 };
        create.mipLevels = 1;
        create.arrayLayers = 1;
        create.samples = c.VK_SAMPLE_COUNT_1_BIT;
        create.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        create.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        try check(c.vkCreateImage(self.device, &create, null, &self.atlas));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(self.device, self.atlas, &req);
        try self.allocate(req, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, &self.atlas_memory);
        try check(c.vkBindImageMemory(self.device, self.atlas, self.atlas_memory, 0));
        try self.createView(self.atlas, c.VK_FORMAT_R8_UNORM, &self.atlas_view);
        var sampler = info(c.VkSamplerCreateInfo, c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO);
        sampler.magFilter = c.VK_FILTER_NEAREST;
        sampler.minFilter = c.VK_FILTER_NEAREST;
        sampler.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        try check(c.vkCreateSampler(self.device, &sampler, null, &self.sampler));
    }
    fn createDescriptors(self: *Renderer) !void {
        const binding = c.VkDescriptorSetLayoutBinding{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null };
        var layout = info(c.VkDescriptorSetLayoutCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO);
        layout.bindingCount = 1;
        layout.pBindings = &binding;
        try check(c.vkCreateDescriptorSetLayout(self.device, &layout, null, &self.descriptor_layout));
        const size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1 };
        var pool = info(c.VkDescriptorPoolCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
        pool.maxSets = 1;
        pool.poolSizeCount = 1;
        pool.pPoolSizes = &size;
        try check(c.vkCreateDescriptorPool(self.device, &pool, null, &self.descriptor_pool));
        var alloc = info(c.VkDescriptorSetAllocateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
        alloc.descriptorPool = self.descriptor_pool;
        alloc.descriptorSetCount = 1;
        alloc.pSetLayouts = &self.descriptor_layout;
        try check(c.vkAllocateDescriptorSets(self.device, &alloc, &self.descriptor));
        const image = c.VkDescriptorImageInfo{ .sampler = self.sampler, .imageView = self.atlas_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        var write = info(c.VkWriteDescriptorSet, c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
        write.dstSet = self.descriptor;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.pImageInfo = &image;
        c.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
        const push = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT, .offset = 0, .size = 8 };
        var pipeline_layout = info(c.VkPipelineLayoutCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
        pipeline_layout.setLayoutCount = 1;
        pipeline_layout.pSetLayouts = &self.descriptor_layout;
        pipeline_layout.pushConstantRangeCount = 1;
        pipeline_layout.pPushConstantRanges = &push;
        try check(c.vkCreatePipelineLayout(self.device, &pipeline_layout, null, &self.layout));
    }
    fn createSwap(self: *Renderer, width: u32, height: u32) !void {
        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical, self.surface, &caps));
        var formats: [64]c.VkSurfaceFormatKHR = undefined;
        var n: u32 = formats.len;
        try check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical, self.surface, &n, &formats));
        if (n == 0) return error.NoSurfaceFormat;
        var chosen = formats[0];
        for (formats[0..n]) |f| if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM) {
            chosen = f;
            break;
        };
        self.format = chosen.format;
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
        self.count = self.images.len;
        try check(c.vkGetSwapchainImagesKHR(self.device, self.swap, &self.count, &self.images));
        if (self.pass != null and self.pass_format != self.format) {
            c.vkDestroyPipeline(self.device, self.pipeline, null);
            c.vkDestroyRenderPass(self.device, self.pass, null);
            self.pipeline = null;
            self.pass = null;
        }
        if (self.pass == null) try self.createPass();
        for (0..self.count) |i| {
            try self.createView(self.images[i], self.format, &self.views[i]);
            var framebuffer = info(c.VkFramebufferCreateInfo, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO);
            framebuffer.renderPass = self.pass;
            framebuffer.attachmentCount = 1;
            framebuffer.pAttachments = &self.views[i];
            framebuffer.width = self.extent.width;
            framebuffer.height = self.extent.height;
            framebuffer.layers = 1;
            try check(c.vkCreateFramebuffer(self.device, &framebuffer, null, &self.framebuffers[i]));
            var sem = info(c.VkSemaphoreCreateInfo, c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
            try check(c.vkCreateSemaphore(self.device, &sem, null, &self.finished[i]));
        }
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
        try check(c.vkCreateRenderPass(self.device, &pass, null, &self.pass));
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
    fn createPipeline(self: *Renderer) !void {
        const vert_bytes align(4) = @embedFile("vert_spv").*;
        const frag_bytes align(4) = @embedFile("frag_spv").*;
        const vert = try self.shader(&vert_bytes);
        defer c.vkDestroyShaderModule(self.device, vert, null);
        const frag = try self.shader(&frag_bytes);
        defer c.vkDestroyShaderModule(self.device, frag, null);
        var stages: [2]c.VkPipelineShaderStageCreateInfo = .{ info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO), info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO) };
        stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = vert;
        stages[0].pName = "main";
        stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = frag;
        stages[1].pName = "main";
        const binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Vertex), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        const attrs = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "position") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Vertex, "color") },
            .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "local") },
            .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Vertex, "half") },
            .{ .location = 5, .binding = 0, .format = c.VK_FORMAT_R32G32B32_SFLOAT, .offset = @offsetOf(Vertex, "shape") },
        };
        var input = info(c.VkPipelineVertexInputStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
        input.vertexBindingDescriptionCount = 1;
        input.pVertexBindingDescriptions = &binding;
        input.vertexAttributeDescriptionCount = attrs.len;
        input.pVertexAttributeDescriptions = &attrs;
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
        blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
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
        try check(c.vkCreateGraphicsPipelines(self.device, null, 1, &create, null, &self.pipeline));
    }
    /// Releases what depends on the extent. The swapchain handle survives to seed its replacement.
    fn destroySwap(self: *Renderer) void {
        for (0..self.count) |i| {
            if (self.framebuffers[i] != null) c.vkDestroyFramebuffer(self.device, self.framebuffers[i], null);
            if (self.views[i] != null) c.vkDestroyImageView(self.device, self.views[i], null);
            if (self.finished[i] != null) c.vkDestroySemaphore(self.device, self.finished[i], null);
        }
        self.count = 0;
        self.framebuffers = @splat(null);
        self.views = @splat(null);
        self.finished = @splat(null);
    }
    pub fn deinit(self: *Renderer) void {
        if (self.window) |window| window.cancelFrame();
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
            self.destroySwap();
            if (self.pipeline != null) c.vkDestroyPipeline(self.device, self.pipeline, null);
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
    pub fn begin(self: *Renderer, width: u32, height: u32) !bool {
        if (self.window) |window| if (!window.frameReady()) {
            self.compositor_wait.pending("compositor frame callback");
            return false;
        };
        self.compositor_wait.complete("compositor frame callback");
        const ready = c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, 0);
        if (ready == c.VK_TIMEOUT) {
            self.fence_wait.pending("frame fence");
            return false;
        }
        try check(ready);
        self.fence_wait.complete("frame fence");
        if (width != self.extent.width or height != self.extent.height) {
            try check(c.vkDeviceWaitIdle(self.device));
            self.destroySwap();
            try self.createSwap(width, height);
        }
        self.vertices = 0;
        self.clip = .{ .x = 0, .y = 0, .w = @floatFromInt(self.extent.width), .h = @floatFromInt(self.extent.height) };
        return true;
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
    pub fn rect(self: *Renderer, r: Rect, color: Color) !void {
        try self.quad(r, .{ .x = @as(f32, 0.5) / fonts.atlas_size, .y = @as(f32, 0.5) / fonts.atlas_size, .w = 0, .h = 0 }, color);
    }
    const Run = struct { glyphs: [*c]c.hb_glyph_info_t, positions: [*c]c.hb_glyph_position_t, count: u32 };
    fn shapeRun(font: *fonts.Font, str: []const u8) Run {
        c.hb_buffer_reset(font.buffer);
        c.hb_buffer_add_utf8(font.buffer, str.ptr, @intCast(str.len), 0, @intCast(str.len));
        c.hb_buffer_guess_segment_properties(font.buffer);
        c.hb_shape(font.hb, font.buffer, null, 0);
        var count: u32 = 0;
        const glyphs = c.hb_buffer_get_glyph_infos(font.buffer, &count);
        return .{ .glyphs = glyphs, .positions = c.hb_buffer_get_glyph_positions(font.buffer, null), .count = count };
    }
    /// Draws one shaped glyph and returns the pen position after it.
    fn glyphAt(self: *Renderer, font: *fonts.Font, id: u32, pos: c.hb_glyph_position_t, pen: f32, y: f32, color: Color) !f32 {
        const next = pen + @as(f32, @floatFromInt(pos.x_advance)) / 64;
        // Report degradation once and use the reserved missing-glyph box.
        const g = font.glyph(id) catch |err| fallback: {
            if (!font.degraded) std.debug.print("Text rendering degraded: {s}; using missing-glyph boxes\n", .{@errorName(err)});
            font.degraded = true;
            break :fallback font.glyph(0) catch return next;
        };
        try self.quad(.{ .x = @round(pen + @as(f32, @floatFromInt(pos.x_offset)) / 64 + @as(f32, @floatFromInt(g.left))), .y = @round(y + 16 - @as(f32, @floatFromInt(g.top)) - @as(f32, @floatFromInt(pos.y_offset)) / 64), .w = @floatFromInt(g.w), .h = @floatFromInt(g.h) }, .{ .x = @as(f32, @floatFromInt(g.x)) / fonts.atlas_size, .y = @as(f32, @floatFromInt(g.y)) / fonts.atlas_size, .w = @as(f32, @floatFromInt(g.w)) / fonts.atlas_size, .h = @as(f32, @floatFromInt(g.h)) / fonts.atlas_size }, color);
        return next;
    }
    pub fn text(self: *Renderer, font: *fonts.Font, x: f32, y: f32, str: []const u8, color: Color) !void {
        const run = shapeRun(font, str);
        var pen = x;
        for (0..run.count) |i| pen = try self.glyphAt(font, run.glyphs[i].codepoint, run.positions[i], pen, y, color);
    }
    /// Advance width of `str` in pixels.
    pub fn measure(_: *Renderer, font: *fonts.Font, str: []const u8) f32 {
        const run = shapeRun(font, str);
        var advance: i32 = 0;
        for (0..run.count) |i| advance += run.positions[i].x_advance;
        return @as(f32, @floatFromInt(advance)) / 64;
    }
    /// Draws `str` in at most `width` pixels. An overflowing run ends in three dots,
    /// each at half the alpha of the one before (after RAD Debugger's truncation).
    pub fn textFit(self: *Renderer, font: *fonts.Font, x: f32, y: f32, width: f32, str: []const u8, color: Color) !void {
        const dot = shapeRun(font, ".");
        if (dot.count != 1) return self.text(font, x, y, str, color);
        const dot_id = dot.glyphs[0].codepoint;
        const dot_pos = dot.positions[0];
        const dots = 3 * @as(f32, @floatFromInt(dot_pos.x_advance)) / 64;
        const run = shapeRun(font, str);
        var total: i32 = 0;
        for (0..run.count) |i| total += run.positions[i].x_advance;
        const fits = @as(f32, @floatFromInt(total)) / 64 <= width;
        var pen = x;
        for (0..run.count) |i| {
            if (!fits and pen + @as(f32, @floatFromInt(run.positions[i].x_advance)) / 64 + dots > x + width) break;
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
        var image_index: u32 = 0;
        var call_started = Wait.now();
        const acquired = c.vkAcquireNextImageKHR(self.device, self.swap, 0, self.available, null, &image_index);
        reportSlowCall("vkAcquireNextImageKHR", call_started);
        if (acquired == c.VK_TIMEOUT or acquired == c.VK_NOT_READY) {
            self.image_wait.pending("swapchain image");
            return false;
        }
        self.image_wait.complete("swapchain image");
        if (acquired == c.VK_ERROR_OUT_OF_DATE_KHR) {
            self.extent.width = 0;
            return false;
        }
        if (acquired != c.VK_SUBOPTIMAL_KHR) try check(acquired);
        try check(c.vkResetCommandBuffer(self.command, 0));
        var begin_info = info(c.VkCommandBufferBeginInfo, c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try check(c.vkBeginCommandBuffer(self.command, &begin_info));
        if (font.dirty) {
            const dest: [*]u8 = @ptrCast(self.mapped.?);
            @memcpy(dest[vertex_bytes..][0..font.pixels.len], &font.pixels);
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
            copy.imageExtent = .{ .width = fonts.atlas_size, .height = fonts.atlas_size, .depth = 1 };
            c.vkCmdCopyBufferToImage(self.command, self.buffer, self.atlas, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            c.vkCmdPipelineBarrier(self.command, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
            font.dirty = false;
            self.atlas_ready = true;
        }
        const clear = c.VkClearValue{ .color = .{ .float32 = .{ 0.035, 0.043, 0.06, 1 } } };
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
        const size = [2]f32{ @floatFromInt(self.extent.width), @floatFromInt(self.extent.height) };
        c.vkCmdPushConstants(self.command, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(size)), &size);
        c.vkCmdDraw(self.command, @intCast(self.vertices), 1, 0, 0);
        c.vkCmdEndRenderPass(self.command);
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
        reportSlowCall("vkQueuePresentKHR", call_started);
        if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            if (self.window) |window| window.cancelFrame();
        }
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR or acquired == c.VK_SUBOPTIMAL_KHR) self.extent.width = 0 else try check(result);
        return result != c.VK_ERROR_OUT_OF_DATE_KHR;
    }
};

/// Report persistent GPU readiness delays without treating them as device loss.
const Wait = struct {
    since: ?u64 = null,
    reported: bool = false,
    fn now() u64 {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    }
    fn pending(self: *Wait, label: []const u8) void {
        const current = now();
        if (self.since == null) self.since = current;
        if (!self.reported and current -| self.since.? >= 1_000_000_000) {
            std.debug.print("xodb: render {s} not ready for {d} ms; frame deferred, event loop remains active\n", .{ label, (current -| self.since.?) / 1_000_000 });
            self.reported = true;
        }
    }
    fn complete(self: *Wait, label: []const u8) void {
        if (self.reported) std.debug.print("xodb: render {s} ready after {d} ms\n", .{ label, (now() -| self.since.?) / 1_000_000 });
        self.* = .{};
    }
};

fn reportSlowCall(name: []const u8, started: u64) void {
    const elapsed = Wait.now() -| started;
    if (elapsed >= 250_000_000) std.debug.print("xodb: slow Vulkan {s}: {d} ms\n", .{ name, elapsed / 1_000_000 });
}
