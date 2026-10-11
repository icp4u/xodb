//! One optional 3D panel, rendered offscreen and composited into the 2D sequence.
//! The caller must have completed its frame fence before resizing or reserving.
const std = @import("std");
const c = @import("../../c.zig").api;
pub const types = @import("types.zig");
pub const math = @import("math.zig");
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
const color_format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
const depth_format = c.VK_FORMAT_D32_SFLOAT;
const max_pixels = 4096 * 4096;
const a = std.heap.page_allocator;
fn info(comptime T: type, kind: c.VkStructureType) T {
    var out = std.mem.zeroes(T);
    out.sType = kind;
    return out;
}
fn check(result: c.VkResult) !void {
    if (result != c.VK_SUCCESS) return error.SceneVulkanFailed;
}
fn created(result: c.VkResult, out: anytype) !void {
    if (result != c.VK_SUCCESS) out.* = null;
    try check(result);
}
pub const Context = struct {
    device: c.VkDevice,
    physical: c.VkPhysicalDevice,
    font_layout: c.VkDescriptorSetLayout,
    font_descriptor: c.VkDescriptorSet,
    family: u32,
};
fn memoryType(ctx: Context, bits: u32, flags: c.VkMemoryPropertyFlags) !u32 {
    var properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(ctx.physical, &properties);
    for (0..@min(properties.memoryTypeCount, 32)) |i| {
        if (bits & (@as(u32, 1) << @intCast(i)) != 0 and properties.memoryTypes[i].propertyFlags & flags == flags) return @intCast(i);
    }
    return error.SceneMemoryTypeUnavailable;
}
/// An instance upload exposes stores and copies, never readable GPU slices.
pub fn Writer(comptime T: type) type {
    return struct {
        destination: []T,
        pub fn set(self: @This(), index: usize, value: T) void {
            self.destination[index] = value;
        }
        pub fn copy(self: @This(), offset: usize, values: []const T) void {
            @memcpy(self.destination[offset..][0..values.len], values);
        }
    };
}

const Buffer = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped: ?*anyopaque = null,
    capacity: usize = 0,
    allocated: u64 = 0,
    fn deinit(self: *Buffer, ctx: Context) void {
        if (self.mapped != null) c.vkUnmapMemory(ctx.device, self.memory);
        if (self.buffer != null) c.vkDestroyBuffer(ctx.device, self.buffer, null);
        if (self.memory != null) c.vkFreeMemory(ctx.device, self.memory, null);
        self.* = .{};
    }
    fn ensure(self: *Buffer, ctx: Context, bytes: usize) !void {
        if (bytes <= self.capacity) return;
        var capacity: usize = 4096;
        while (capacity < bytes) capacity *= 2;
        var next = Buffer{ .capacity = capacity };
        errdefer next.deinit(ctx);
        var create = info(c.VkBufferCreateInfo, c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO);
        create.size = capacity;
        create.usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
        try created(c.vkCreateBuffer(ctx.device, &create, null, &next.buffer), &next.buffer);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(ctx.device, next.buffer, &req);
        var allocation = info(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        allocation.allocationSize = req.size;
        allocation.memoryTypeIndex = try memoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        try created(c.vkAllocateMemory(ctx.device, &allocation, null, &next.memory), &next.memory);
        try check(c.vkBindBufferMemory(ctx.device, next.buffer, next.memory, 0));
        try created(c.vkMapMemory(ctx.device, next.memory, 0, req.size, 0, &next.mapped), &next.mapped);
        if (self.mapped) |old| @memcpy(@as([*]u8, @ptrCast(next.mapped.?))[0..self.capacity], @as([*]const u8, @ptrCast(old))[0..self.capacity]);
        next.allocated = req.size;
        self.deinit(ctx);
        self.* = next;
    }
    fn slice(self: *Buffer, comptime T: type, n: usize) []T {
        if (n == 0) return &.{};
        const ptr: [*]T = @ptrCast(@alignCast(self.mapped.?));
        return ptr[0..n];
    }
};
const Image = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    allocated: u64 = 0,
    fn deinit(self: *Image, ctx: Context) void {
        if (self.view != null) c.vkDestroyImageView(ctx.device, self.view, null);
        if (self.image != null) c.vkDestroyImage(ctx.device, self.image, null);
        if (self.memory != null) c.vkFreeMemory(ctx.device, self.memory, null);
        self.* = .{};
    }
    fn init(self: *Image, ctx: Context, width: u32, height: u32, depth: bool) !void {
        var create = info(c.VkImageCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
        create.imageType = c.VK_IMAGE_TYPE_2D;
        create.format = if (depth) depth_format else color_format;
        create.extent = .{ .width = width, .height = height, .depth = 1 };
        create.mipLevels = 1;
        create.arrayLayers = 1;
        create.samples = c.VK_SAMPLE_COUNT_1_BIT;
        create.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        create.usage = if (depth) c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT else c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        try created(c.vkCreateImage(ctx.device, &create, null, &self.image), &self.image);
        errdefer self.deinit(ctx);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.device, self.image, &req);
        var allocation = info(c.VkMemoryAllocateInfo, c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
        allocation.allocationSize = req.size;
        allocation.memoryTypeIndex = try memoryType(ctx, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try created(c.vkAllocateMemory(ctx.device, &allocation, null, &self.memory), &self.memory);
        try check(c.vkBindImageMemory(ctx.device, self.image, self.memory, 0));
        var view = info(c.VkImageViewCreateInfo, c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
        view.image = self.image;
        view.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view.format = create.format;
        view.subresourceRange = .{ .aspectMask = if (depth) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        try created(c.vkCreateImageView(ctx.device, &view, null, &self.view), &self.view);
        self.allocated = req.size;
    }
};
const PostPush = extern struct { rect: [4]f32, settings: [4]f32 };
pub const Stats = struct { boxes: u32 = 0, points: u32 = 0, lines: u32 = 0, glyphs: u32 = 0, allocated_bytes: u64 = 0, draw_calls: u32 = 0, gpu_ns: ?u64 = null };
pub const Gpu = struct {
    ctx: Context,
    pass: c.VkRenderPass = null,
    post_pass: c.VkRenderPass = null,
    layout: c.VkPipelineLayout = null,
    post_layout: c.VkPipelineLayout = null,
    post_descriptors: c.VkDescriptorSetLayout = null,
    pool: c.VkDescriptorPool = null,
    sets: [4]c.VkDescriptorSet = @splat(null),
    sampler: c.VkSampler = null,
    faces: c.VkPipeline = null,
    edges: c.VkPipeline = null,
    translucent: c.VkPipeline = null,
    point_pipeline: c.VkPipeline = null,
    line_pipeline: c.VkPipeline = null,
    glyph_pipeline: c.VkPipeline = null,
    blur_pipeline: c.VkPipeline = null,
    composite_pipeline: c.VkPipeline = null,
    color: Image = .{},
    depth: Image = .{},
    blur_a: Image = .{},
    blur_b: Image = .{},
    frame: c.VkFramebuffer = null,
    post_frames: [2]c.VkFramebuffer = @splat(null),
    width: u32 = 0,
    height: u32 = 0,
    small_width: u32 = 0,
    small_height: u32 = 0,
    box_buffer: Buffer = .{},
    point_buffer: Buffer = .{},
    line_buffer: Buffer = .{},
    glyph_buffer: Buffer = .{},
    stats: Stats = .{},
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    push: types.Push = .{ .view_projection = math.identity(), .viewport = .{ 1, 1 } },
    bloom: f32 = 0.7,
    exposure: f32 = 1,
    queries: c.VkQueryPool = null,
    query_pending: bool = false,
    timestamp_bits: u32 = 0,
    timestamp_period: f32 = 0,
    pub fn init(self: *Gpu) !void {
        errdefer self.deinit();
        var format: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(self.ctx.physical, color_format, &format);
        const required = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT | c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
        if (format.optimalTilingFeatures & required != required) return error.SceneColorFormatUnsupported;
        c.vkGetPhysicalDeviceFormatProperties(self.ctx.physical, depth_format, &format);
        if (format.optimalTilingFeatures & c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT == 0) return error.SceneDepthFormatUnsupported;
        self.pass = try renderPass(self.ctx, true);
        self.post_pass = try renderPass(self.ctx, false);
        var push = c.VkPushConstantRange{ .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, .offset = 0, .size = @sizeOf(types.Push) };
        var layout = info(c.VkPipelineLayoutCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
        layout.setLayoutCount = 1;
        layout.pSetLayouts = &self.ctx.font_layout;
        layout.pushConstantRangeCount = 1;
        layout.pPushConstantRanges = &push;
        try created(c.vkCreatePipelineLayout(self.ctx.device, &layout, null, &self.layout), &self.layout);
        var bindings: [2]c.VkDescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*binding, i| binding.* = .{ .binding = @intCast(i), .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null };
        var descriptors = info(c.VkDescriptorSetLayoutCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO);
        descriptors.bindingCount = bindings.len;
        descriptors.pBindings = &bindings;
        try created(c.vkCreateDescriptorSetLayout(self.ctx.device, &descriptors, null, &self.post_descriptors), &self.post_descriptors);
        layout.pSetLayouts = &self.post_descriptors;
        push.size = @sizeOf(PostPush);
        try created(c.vkCreatePipelineLayout(self.ctx.device, &layout, null, &self.post_layout), &self.post_layout);
        const pool_size = c.VkDescriptorPoolSize{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 8 };
        var pool = info(c.VkDescriptorPoolCreateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
        pool.maxSets = 4;
        pool.poolSizeCount = 1;
        pool.pPoolSizes = &pool_size;
        try created(c.vkCreateDescriptorPool(self.ctx.device, &pool, null, &self.pool), &self.pool);
        const layouts = [_]c.VkDescriptorSetLayout{self.post_descriptors} ** 4;
        var alloc = info(c.VkDescriptorSetAllocateInfo, c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
        alloc.descriptorPool = self.pool;
        alloc.descriptorSetCount = layouts.len;
        alloc.pSetLayouts = &layouts;
        try check(c.vkAllocateDescriptorSets(self.ctx.device, &alloc, &self.sets));
        var sampler = info(c.VkSamplerCreateInfo, c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO);
        sampler.magFilter = c.VK_FILTER_LINEAR;
        sampler.minFilter = c.VK_FILTER_LINEAR;
        sampler.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
        sampler.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        sampler.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        try created(c.vkCreateSampler(self.ctx.device, &sampler, null, &self.sampler), &self.sampler);
        const box align(4) = @embedFile("scene_box_vert").*;
        const point align(4) = @embedFile("scene_point_vert").*;
        const line align(4) = @embedFile("scene_line_vert").*;
        const glyph align(4) = @embedFile("scene_glyph_vert").*;
        const frag align(4) = @embedFile("scene_scene_frag").*;
        const post align(4) = @embedFile("scene_post_vert").*;
        const blur align(4) = @embedFile("scene_blur_frag").*;
        var desc = Pipeline{ .vert = &box, .frag = &frag, .pass = self.pass, .layout = self.layout, .stride = @sizeOf(types.Box), .attributes = 3, .depth = true, .write_depth = true };
        self.faces = try pipeline(self.ctx, desc);
        desc.write_depth = false;
        desc.additive = true;
        self.translucent = try pipeline(self.ctx, desc);
        desc.lines = true;
        self.edges = try pipeline(self.ctx, desc);
        desc.vert = &line;
        desc.stride = @sizeOf(types.Line);
        self.line_pipeline = try pipeline(self.ctx, desc);
        desc.vert = &point;
        desc.stride = @sizeOf(types.Point);
        desc.attributes = 2;
        desc.lines = false;
        self.point_pipeline = try pipeline(self.ctx, desc);
        desc.vert = &glyph;
        desc.stride = @sizeOf(types.Glyph);
        desc.attributes = 4;
        desc.additive = false;
        self.glyph_pipeline = try pipeline(self.ctx, desc);
        self.blur_pipeline = try pipeline(self.ctx, .{ .vert = &post, .frag = &blur, .pass = self.post_pass, .layout = self.post_layout, .blend = false });
        var count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.ctx.physical, &count, null);
        if (count > 4096 or self.ctx.family >= count) return error.SceneQueueFamilyUnavailable;
        const families = try a.alloc(c.VkQueueFamilyProperties, count);
        defer a.free(families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.ctx.physical, &count, families.ptr);
        self.timestamp_bits = @min(64, families[self.ctx.family].timestampValidBits);
        if (self.timestamp_bits != 0) {
            var properties: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(self.ctx.physical, &properties);
            self.timestamp_period = properties.limits.timestampPeriod;
            var queries = info(c.VkQueryPoolCreateInfo, c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO);
            queries.queryType = c.VK_QUERY_TYPE_TIMESTAMP;
            queries.queryCount = 2;
            try created(c.vkCreateQueryPool(self.ctx.device, &queries, null, &self.queries), &self.queries);
        }
    }
    fn framebuffer(self: *Gpu, pass: c.VkRenderPass, views: []const c.VkImageView, w: u32, h: u32) !c.VkFramebuffer {
        var create = info(c.VkFramebufferCreateInfo, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO);
        create.renderPass = pass;
        create.attachmentCount = @intCast(views.len);
        create.pAttachments = views.ptr;
        create.width = w;
        create.height = h;
        create.layers = 1;
        var out: c.VkFramebuffer = null;
        try check(c.vkCreateFramebuffer(self.ctx.device, &create, null, &out));
        return out;
    }
    pub fn extent(self: *Gpu, w: u32, h: u32, ui_pass: c.VkRenderPass) !void {
        if (self.width == w and self.height == h) return;
        self.destroyExtent();
        if (w == 0 or h == 0) return;
        if (@as(u64, w) * h > max_pixels) return error.SceneExtentLimit;
        errdefer self.destroyExtent();
        self.width = w;
        self.height = h;
        self.small_width = @max(1, (w + 3) / 4);
        self.small_height = @max(1, (h + 3) / 4);
        try self.color.init(self.ctx, w, h, false);
        try self.depth.init(self.ctx, w, h, true);
        try self.blur_a.init(self.ctx, self.small_width, self.small_height, false);
        try self.blur_b.init(self.ctx, self.small_width, self.small_height, false);
        self.frame = try self.framebuffer(self.pass, &.{ self.color.view, self.depth.view }, w, h);
        self.post_frames[0] = try self.framebuffer(self.post_pass, &.{self.blur_a.view}, self.small_width, self.small_height);
        self.post_frames[1] = try self.framebuffer(self.post_pass, &.{self.blur_b.view}, self.small_width, self.small_height);
        const sources = [4][2]c.VkImageView{ .{ self.color.view, self.color.view }, .{ self.blur_a.view, self.blur_a.view }, .{ self.blur_b.view, self.blur_b.view }, .{ self.color.view, self.blur_a.view } };
        for (sources, 0..) |views, i| for (views, 0..) |view, binding| {
            const image = c.VkDescriptorImageInfo{ .sampler = self.sampler, .imageView = view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
            var write = info(c.VkWriteDescriptorSet, c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
            write.dstSet = self.sets[i];
            write.dstBinding = @intCast(binding);
            write.descriptorCount = 1;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            write.pImageInfo = &image;
            c.vkUpdateDescriptorSets(self.ctx.device, 1, &write, 0, null);
        };
        const vert align(4) = @embedFile("scene_post_vert").*;
        const frag align(4) = @embedFile("scene_composite_frag").*;
        self.composite_pipeline = try pipeline(self.ctx, .{ .vert = &vert, .frag = &frag, .pass = ui_pass, .layout = self.post_layout, .blend = false });
    }
    pub fn timerRead(self: *Gpu) void {
        if (!self.query_pending) return;
        self.query_pending = false;
        var values = [_]u64{0} ** 4;
        const result = c.vkGetQueryPoolResults(self.ctx.device, self.queries, 0, 2, @sizeOf(@TypeOf(values)), &values, 16, c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
        self.stats.gpu_ns = null;
        if (result != c.VK_SUCCESS or values[1] == 0 or values[3] == 0) return;
        const mask: u64 = @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - self.timestamp_bits));
        const delta = (values[2] -% values[0]) & mask;
        const nanos = @as(f64, @floatFromInt(delta)) * self.timestamp_period;
        if (std.math.isFinite(nanos) and nanos >= 0 and nanos < @as(f64, @floatFromInt(std.math.maxInt(u64)))) self.stats.gpu_ns = @intFromFloat(nanos);
    }
    pub fn timerStart(self: *Gpu, cmd: c.VkCommandBuffer) void {
        if (self.queries == null) return;
        c.vkCmdResetQueryPool(cmd, self.queries, 0, 2);
        c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, self.queries, 0);
    }
    pub fn timerEnd(self: *Gpu, cmd: c.VkCommandBuffer) void {
        if (self.queries == null) return;
        c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, self.queries, 1);
        self.query_pending = true;
    }
    fn draw(self: *Gpu, cmd: c.VkCommandBuffer, p: c.VkPipeline, buffer: *const Buffer, count: u32, vertices: u32, mode: f32) void {
        if (count == 0) return;
        self.push.mode = mode;
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, p);
        const offset: u64 = 0;
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &buffer.buffer, &offset);
        c.vkCmdPushConstants(cmd, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(types.Push), &self.push);
        c.vkCmdDraw(cmd, vertices, count, 0, 0);
        self.stats.draw_calls += 1;
    }
    pub fn record(self: *Gpu, cmd: c.VkCommandBuffer) void {
        self.stats.draw_calls = 0;
        self.stats.allocated_bytes = self.allocated();
        const clears = [_]c.VkClearValue{ .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } }, .{ .depthStencil = .{ .depth = 1, .stencil = 0 } } };
        var pass = info(c.VkRenderPassBeginInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO);
        pass.renderPass = self.pass;
        pass.framebuffer = self.frame;
        pass.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } };
        pass.clearValueCount = 2;
        pass.pClearValues = &clears;
        c.vkCmdBeginRenderPass(cmd, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
        const viewport = c.VkViewport{ .x = self.bounds.x, .y = self.bounds.y, .width = self.bounds.w, .height = self.bounds.h, .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        const clip = scissor(self.bounds, self.width, self.height);
        c.vkCmdSetScissor(cmd, 0, 1, &clip);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.layout, 0, 1, &self.ctx.font_descriptor, 0, null);
        self.push.viewport = .{ self.bounds.w, self.bounds.h };
        self.draw(cmd, self.faces, &self.box_buffer, self.stats.boxes, 36, 0);
        self.draw(cmd, self.translucent, &self.box_buffer, self.stats.boxes, 36, 5);
        self.draw(cmd, self.edges, &self.box_buffer, self.stats.boxes, 24, 1);
        self.draw(cmd, self.point_pipeline, &self.point_buffer, self.stats.points, 6, 2);
        self.draw(cmd, self.line_pipeline, &self.line_buffer, self.stats.lines, 2, 3);
        self.draw(cmd, self.glyph_pipeline, &self.glyph_buffer, self.stats.glyphs, 6, 4);
        c.vkCmdEndRenderPass(cmd);
        const w: f32 = @floatFromInt(self.small_width);
        const h: f32 = @floatFromInt(self.small_height);
        const small_view = c.VkViewport{ .x = 0, .y = 0, .width = w, .height = h, .minDepth = 0, .maxDepth = 1 };
        const small_clip = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.small_width, .height = self.small_height } };
        pass.renderPass = self.post_pass;
        pass.renderArea = small_clip;
        pass.clearValueCount = 1;
        for (0..3) |i| {
            pass.framebuffer = self.post_frames[i % 2];
            c.vkCmdBeginRenderPass(cmd, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
            c.vkCmdSetViewport(cmd, 0, 1, &small_view);
            c.vkCmdSetScissor(cmd, 0, 1, &small_clip);
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.blur_pipeline);
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.post_layout, 0, 1, &self.sets[i], 0, null);
            const push = PostPush{ .rect = .{ 0, 0, w, h }, .settings = .{ w, h, @floatFromInt(i), 1 } };
            c.vkCmdPushConstants(cmd, self.post_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostPush), &push);
            c.vkCmdDraw(cmd, 6, 1, 0, 0);
            self.stats.draw_calls += 1;
            c.vkCmdEndRenderPass(cmd);
        }
    }
    /// Called inside the UI render pass, exactly between the caller's background
    /// and overlay commands. The caller restores its pipeline and bindings.
    pub fn composite(self: *Gpu, cmd: c.VkCommandBuffer) void {
        const w: f32 = @floatFromInt(self.width);
        const h: f32 = @floatFromInt(self.height);
        const viewport = c.VkViewport{ .x = 0, .y = 0, .width = w, .height = h, .minDepth = 0, .maxDepth = 1 };
        const clip = scissor(self.bounds, self.width, self.height);
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);
        c.vkCmdSetScissor(cmd, 0, 1, &clip);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.composite_pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.post_layout, 0, 1, &self.sets[3], 0, null);
        const push = PostPush{ .rect = .{ self.bounds.x, self.bounds.y, self.bounds.w, self.bounds.h }, .settings = .{ w, h, std.math.clamp(self.exposure, 0.01, 8), std.math.clamp(self.bloom, 0, 4) } };
        c.vkCmdPushConstants(cmd, self.post_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostPush), &push);
        c.vkCmdDraw(cmd, 6, 1, 0, 0);
        self.stats.draw_calls += 1;
    }
    pub fn boxes(self: *Gpu, n: usize) !Writer(types.Box) {
        if (n > types.max_instances) return error.SceneInstanceLimit;
        try self.box_buffer.ensure(self.ctx, n * @sizeOf(types.Box));
        self.stats.boxes = @intCast(n);
        return .{ .destination = self.box_buffer.slice(types.Box, n) };
    }
    pub fn points(self: *Gpu, n: usize) !Writer(types.Point) {
        if (n > types.max_instances) return error.SceneInstanceLimit;
        try self.point_buffer.ensure(self.ctx, n * @sizeOf(types.Point));
        self.stats.points = @intCast(n);
        return .{ .destination = self.point_buffer.slice(types.Point, n) };
    }
    pub fn lines(self: *Gpu, n: usize) !Writer(types.Line) {
        if (n > types.max_instances) return error.SceneInstanceLimit;
        try self.line_buffer.ensure(self.ctx, n * @sizeOf(types.Line));
        self.stats.lines = @intCast(n);
        return .{ .destination = self.line_buffer.slice(types.Line, n) };
    }
    pub fn glyphs(self: *Gpu, n: usize) !Writer(types.Glyph) {
        if (n > types.max_glyphs) return error.SceneInstanceLimit;
        try self.glyph_buffer.ensure(self.ctx, n * @sizeOf(types.Glyph));
        self.stats.glyphs = @intCast(n);
        return .{ .destination = self.glyph_buffer.slice(types.Glyph, n) };
    }
    pub fn allocated(self: *const Gpu) u64 {
        return self.box_buffer.allocated + self.point_buffer.allocated + self.line_buffer.allocated + self.glyph_buffer.allocated + self.color.allocated + self.depth.allocated + self.blur_a.allocated + self.blur_b.allocated;
    }
    pub fn destroyExtent(self: *Gpu) void {
        if (self.composite_pipeline != null) c.vkDestroyPipeline(self.ctx.device, self.composite_pipeline, null);
        if (self.frame != null) c.vkDestroyFramebuffer(self.ctx.device, self.frame, null);
        for (self.post_frames) |f| if (f != null) c.vkDestroyFramebuffer(self.ctx.device, f, null);
        self.color.deinit(self.ctx);
        self.depth.deinit(self.ctx);
        self.blur_a.deinit(self.ctx);
        self.blur_b.deinit(self.ctx);
        self.composite_pipeline = null;
        self.frame = null;
        self.post_frames = @splat(null);
        self.width = 0;
        self.height = 0;
    }
    pub fn deinit(self: *Gpu) void {
        self.destroyExtent();
        self.box_buffer.deinit(self.ctx);
        self.point_buffer.deinit(self.ctx);
        self.line_buffer.deinit(self.ctx);
        self.glyph_buffer.deinit(self.ctx);
        for ([_]c.VkPipeline{ self.faces, self.translucent, self.edges, self.point_pipeline, self.line_pipeline, self.glyph_pipeline, self.blur_pipeline }) |p| if (p != null) c.vkDestroyPipeline(self.ctx.device, p, null);
        if (self.queries != null) c.vkDestroyQueryPool(self.ctx.device, self.queries, null);
        if (self.sampler != null) c.vkDestroySampler(self.ctx.device, self.sampler, null);
        if (self.pool != null) c.vkDestroyDescriptorPool(self.ctx.device, self.pool, null);
        if (self.layout != null) c.vkDestroyPipelineLayout(self.ctx.device, self.layout, null);
        if (self.post_layout != null) c.vkDestroyPipelineLayout(self.ctx.device, self.post_layout, null);
        if (self.post_descriptors != null) c.vkDestroyDescriptorSetLayout(self.ctx.device, self.post_descriptors, null);
        if (self.pass != null) c.vkDestroyRenderPass(self.ctx.device, self.pass, null);
        if (self.post_pass != null) c.vkDestroyRenderPass(self.ctx.device, self.post_pass, null);
        self.* = .{ .ctx = self.ctx };
    }
};

fn shader(ctx: Context, bytes: []align(4) const u8) !c.VkShaderModule {
    var create = info(c.VkShaderModuleCreateInfo, c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
    create.codeSize = bytes.len;
    create.pCode = @ptrCast(bytes.ptr);
    var module: c.VkShaderModule = null;
    try check(c.vkCreateShaderModule(ctx.device, &create, null, &module));
    return module;
}
const Pipeline = struct {
    vert: []align(4) const u8,
    frag: []align(4) const u8,
    pass: c.VkRenderPass,
    layout: c.VkPipelineLayout,
    stride: u32 = 0,
    attributes: u32 = 0,
    lines: bool = false,
    depth: bool = false,
    write_depth: bool = false,
    additive: bool = false,
    blend: bool = true,
};
fn pipeline(ctx: Context, desc: Pipeline) !c.VkPipeline {
    const vert = try shader(ctx, desc.vert);
    defer c.vkDestroyShaderModule(ctx.device, vert, null);
    const frag = try shader(ctx, desc.frag);
    defer c.vkDestroyShaderModule(ctx.device, frag, null);
    var stages = [_]c.VkPipelineShaderStageCreateInfo{ info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO), info(c.VkPipelineShaderStageCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO) };
    stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vert;
    stages[0].pName = "main";
    stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = frag;
    stages[1].pName = "main";
    const binding = c.VkVertexInputBindingDescription{ .binding = 0, .stride = desc.stride, .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE };
    var attrs: [4]c.VkVertexInputAttributeDescription = undefined;
    for (&attrs, 0..) |*attr, i| attr.* = .{ .location = @intCast(i), .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @intCast(i * 16) };
    var vertex = info(c.VkPipelineVertexInputStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
    vertex.vertexBindingDescriptionCount = if (desc.stride > 0) 1 else 0;
    vertex.pVertexBindingDescriptions = &binding;
    vertex.vertexAttributeDescriptionCount = desc.attributes;
    vertex.pVertexAttributeDescriptions = &attrs;
    var assembly = info(c.VkPipelineInputAssemblyStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO);
    assembly.topology = if (desc.lines) c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST else c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    var viewport = info(c.VkPipelineViewportStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO);
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    var raster = info(c.VkPipelineRasterizationStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
    raster.polygonMode = c.VK_POLYGON_MODE_FILL;
    raster.cullMode = c.VK_CULL_MODE_NONE;
    raster.frontFace = c.VK_FRONT_FACE_CLOCKWISE;
    raster.lineWidth = 1;
    var ms = info(c.VkPipelineMultisampleStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO);
    ms.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
    var depth = info(c.VkPipelineDepthStencilStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO);
    depth.depthTestEnable = @intFromBool(desc.depth);
    depth.depthWriteEnable = @intFromBool(desc.write_depth);
    depth.depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL;
    var attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    attachment.blendEnable = @intFromBool(desc.blend);
    attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
    attachment.dstColorBlendFactor = if (desc.additive) c.VK_BLEND_FACTOR_ONE else c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
    attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
    attachment.colorWriteMask = 15;
    var blend = info(c.VkPipelineColorBlendStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO);
    blend.attachmentCount = 1;
    blend.pAttachments = &attachment;
    const states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamic = info(c.VkPipelineDynamicStateCreateInfo, c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
    dynamic.dynamicStateCount = states.len;
    dynamic.pDynamicStates = &states;
    var create = info(c.VkGraphicsPipelineCreateInfo, c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
    create.stageCount = stages.len;
    create.pStages = &stages;
    create.pVertexInputState = &vertex;
    create.pInputAssemblyState = &assembly;
    create.pViewportState = &viewport;
    create.pRasterizationState = &raster;
    create.pMultisampleState = &ms;
    create.pDepthStencilState = &depth;
    create.pColorBlendState = &blend;
    create.pDynamicState = &dynamic;
    create.layout = desc.layout;
    create.renderPass = desc.pass;
    var out: c.VkPipeline = null;
    const result = c.vkCreateGraphicsPipelines(ctx.device, null, 1, &create, null, &out);
    if (result != c.VK_SUCCESS) {
        if (out != null) c.vkDestroyPipeline(ctx.device, out, null);
        try check(result);
    }
    return out;
}
fn renderPass(ctx: Context, with_depth: bool) !c.VkRenderPass {
    var attachments = [_]c.VkAttachmentDescription{std.mem.zeroes(c.VkAttachmentDescription)} ** 2;
    for (&attachments, 0..) |*attachment, i| {
        attachment.format = if (i == 0) color_format else depth_format;
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachment.storeOp = if (i == 0) c.VK_ATTACHMENT_STORE_OP_STORE else c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachment.finalLayout = if (i == 0) c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    }
    const color = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    const depth = c.VkAttachmentReference{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color;
    subpass.pDepthStencilAttachment = if (with_depth) &depth else null;
    const stages = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    const deps = [_]c.VkSubpassDependency{
        .{ .srcSubpass = c.VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | stages, .dstStageMask = stages, .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT, .dependencyFlags = 0 },
        .{ .srcSubpass = 0, .dstSubpass = c.VK_SUBPASS_EXTERNAL, .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT, .dependencyFlags = 0 },
    };
    var create = info(c.VkRenderPassCreateInfo, c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO);
    create.attachmentCount = if (with_depth) 2 else 1;
    create.pAttachments = &attachments;
    create.subpassCount = 1;
    create.pSubpasses = &subpass;
    create.dependencyCount = deps.len;
    create.pDependencies = &deps;
    var out: c.VkRenderPass = null;
    try check(c.vkCreateRenderPass(ctx.device, &create, null, &out));
    return out;
}

fn scissor(r: Rect, width: u32, height: u32) c.VkRect2D {
    const x0: u32 = @intFromFloat(@max(0, @floor(r.x)));
    const y0: u32 = @intFromFloat(@max(0, @floor(r.y)));
    const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(width)), @ceil(r.x + r.w)));
    const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(height)), @ceil(r.y + r.h)));
    return .{ .offset = .{ .x = @intCast(x0), .y = @intCast(y0) }, .extent = .{ .width = x1 -| x0, .height = y1 -| y0 } };
}
