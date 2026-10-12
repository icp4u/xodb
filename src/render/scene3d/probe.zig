//! Explicitly synthetic GPU probe, also used by the private GUI regression lane.
const std = @import("std");
const Window = @import("../../platform/window.zig").Window;
const Renderer = @import("../vulkan.zig").Renderer;
const Font = @import("../font.zig").Font;
const math = @import("math.zig");
const now = @import("../../target/linux.zig").now;

pub fn main(args: []const [:0]const u8) !void {
    var count: usize = 4000;
    var frames: u64 = 0;
    var reverse = false;
    var retry_scene = false;
    var bloom: f32 = 0.7;
    for (args[1..], 1..) |arg, i| {
        if (std.mem.eql(u8, arg, "--instances") and i + 1 < args.len) count = try std.fmt.parseInt(usize, args[i + 1], 10);
        if (std.mem.eql(u8, arg, "--frames") and i + 1 < args.len) frames = try std.fmt.parseInt(u64, args[i + 1], 10);
        if (std.mem.eql(u8, arg, "--retry-scene")) retry_scene = true;
        if (std.mem.eql(u8, arg, "--reverse")) reverse = true;
        if (std.mem.eql(u8, arg, "--no-bloom")) bloom = 0;
    }
    if (count < 4 or count > @import("types.zig").max_instances) return error.SceneInstanceLimit;
    var window = Window{};
    try window.init();
    defer window.deinit();
    window.setMinSize(32, 32);
    window.setTitle("xodb synthetic scene3d probe");
    var renderer = Renderer{};
    try renderer.init(&window);
    defer renderer.deinit();
    std.debug.print("scene3d base framebuffers={d}\n", .{renderer.count});
    const font = try std.heap.page_allocator.create(Font);
    defer std.heap.page_allocator.destroy(font);
    font.* = .{};
    try font.initRetro();
    defer font.deinit();
    var frame: u64 = 0;
    var hidden = false;
    var generation: u32 = 0;
    var zero_extent = false;
    while (!window.closing and (frames == 0 or frame < frames)) {
        try window.pump(1);
        while (window.input.next()) |event| {
            if (event.kind != .press) continue;
            switch (event.shortcut) {
                'q' => return,
                'r' => reverse = !reverse,
                'b' => bloom = if (bloom == 0) 0.7 else 0,
                'h' => hidden = !hidden,
                'z' => zero_extent = true,
                'x' => {
                    renderer.deinit();
                    try renderer.init(&window);
                    font.dirty = true;
                    generation += 1;
                },
                else => {},
            }
        }
        _ = try font.setScale(window.scale());
        if (!try renderer.begin(window.width, window.height, window.scale())) continue;
        if (zero_extent) {
            zero_extent = false;
            if (renderer.scene_gpu) |*gpu| {
                try gpu.extent(0, 0, renderer.pass);
                if (gpu.width != 0 or gpu.height != 0 or gpu.color.image != null or gpu.depth.image != null or gpu.frame != null) return error.ZeroExtentRetainsImages;
                std.debug.print("scene3d zero_extent images=0\n", .{});
            }
        }
        const start = now();
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        try renderer.rect(.{ .x = 0, .y = 0, .w = width, .h = height }, .{ 0.05, 0.15, 0.25, 1 });
        const bounds = @import("../vulkan.zig").Rect{ .x = 32, .y = 48, .w = @max(0, width - 64), .h = @max(0, height - 80) };
        if (bounds.w > 0 and bounds.h > 0) {
            const behind = try renderer.cells(1);
            behind[0] = .{ .rect = .{ bounds.x, bounds.y, bounds.w, bounds.h }, .fill = .{ 0, 0, 255, 255 }, .accent = @splat(0), .overlay = @splat(0), .kind = 0 };
        }
        if (!hidden and bounds.w > 0 and bounds.h > 0) {
            const vp = math.mul(math.perspective(1, bounds.w / bounds.h, 0.1, 1000).?, math.lookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }).?);
            const available = renderer.scene(bounds, vp) catch |err| blk: {
                if (!retry_scene) return err;
                std.debug.print("scene3d refused={s} now={d} retry={d}\n", .{ @errorName(err), now(), renderer.scene_retry.next });
                break :blk null;
            };
            if (available) |scene| {
                scene.bloom = bloom;
                const boxes = try scene.boxes(count);
                const side: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(count - 4)))))));
                const pitch: f32 = 4.4 / @as(f32, @floatFromInt(side));
                for (0..count) |k| {
                    const i = if (reverse) count - 1 - k else k;
                    if (i < 2) {
                        // Red is in front, green behind: the center pixel must
                        // remain red in either submission order.
                        boxes.set(k, .{ .center = .{ 0, 0, if (i == 0) 0 else -1 }, .half = .{ 0.7, 0.7, 0.2 }, .color = if (i == 0) .{ 1, 0.01, 0.01, 1 } else .{ 0.01, 1, 0.01, 1 } });
                    } else if (i < 4) {
                        boxes.set(k, .{ .center = .{ 1.5, 0.5, if (i == 2) 0 else -0.2 }, .half = .{ 0.25, 0.25, 0.25 }, .emission = 0.5, .color = if (i == 2) .{ 1, 0, 0.2, 0.25 } else .{ 0, 0.8, 1, 0.25 } });
                    } else {
                        const x: f32 = (@as(f32, @floatFromInt((i - 4) % side)) + 0.5) * pitch - 2.2;
                        const y: f32 = (@as(f32, @floatFromInt((i - 4) / side)) + 0.5) * pitch - 2.2;
                        boxes.set(k, .{ .center = .{ x, y, -3 }, .half = .{ pitch * 0.30, pitch * 0.30, 0.01 }, .color = .{ 0.05, 0.4, 0.8, 1 } });
                    }
                }
                const points = try scene.points(2);
                points.set(0, .{ .position = .{ -1.5, 0.5, 0 }, .pixels = 30, .color = .{ 0, 6, 2, 1 } });
                points.set(1, .{ .position = .{ 0, 0, -2 }, .pixels = 40, .color = .{ 0, 10, 0, 1 } });
                const lines = try scene.lines(1);
                lines.set(0, .{ .a = .{ -1.5, -1, 0 }, .b = .{ 1.5, -1, 0 }, .emission = 4, .color = .{ 0, 0.7, 1, 1 } });
                try renderer.sceneText(font, .{ 0, 1.3, 0 }, .{ -44, -8 }, "GPU LABEL", .{ 1, 1, 1, 1 });
                // A second, clipped label forces atlas-instance buffer growth;
                // the visible first label must survive copying the old storage.
                try renderer.sceneText(font, .{ 100, 100, 0 }, .{ 0, 0 }, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", .{ 1, 1, 1, 1 });
            }
        }
        if (bounds.w > 0 and bounds.h > 0) {
            const above = try renderer.cells(1);
            above[0] = .{ .rect = .{ width / 2 + 40, height / 2 - 16, 16, 8 }, .fill = .{ 255, 255, 0, 255 }, .accent = @splat(0), .overlay = @splat(0), .kind = 0 };
        }
        // Solid magenta overlay tests restoration of the 2D pipeline.
        try renderer.rect(.{ .x = width / 2 - 16, .y = height / 2 - 16, .w = 32, .h = 8 }, .{ 1, 0, 1, 1 });
        try renderer.text(font, 8, 8, "SYNTHETIC SCENE3D — depth / instances / bloom / atlas", .{ 1, 1, 1, 1 });
        if (!try renderer.end(font)) continue;
        frame += 1;
        const elapsed = now() - start;
        if (renderer.scene_gpu) |*scene| {
            std.debug.print("scene3d frame={d} size={d}x{d} boxes={d} glyphs={d} bytes={d} draws={d} submit_wall_ns={d} gpu_ns={?d} reverse={} bloom={d} generation={d}\n", .{ frame, window.width, window.height, scene.stats.boxes, scene.stats.glyphs, scene.stats.allocated_bytes, scene.stats.draw_calls, elapsed, scene.stats.gpu_ns, reverse, bloom, generation });
        } else std.debug.print("scene3d frame={d} hidden bytes=0\n", .{frame});
    }
}
