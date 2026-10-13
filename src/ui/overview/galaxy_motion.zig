//! Presentation-only easing. World geometry is retained while camera motion is
//! a GPU transform; new layouts settle by stable process/group identity.
const std = @import("std");
const draw = @import("draw.zig");
const Look = @import("../../preferences.zig").Galaxy;
const model = @import("galaxy_model.zig");
const Point = struct { key: u64, at: [2]f32, r: f32 };
pub const Motion = struct {
    stars: [model.max_stars]Point = undefined,
    clusters: [model.max_clusters]Point = undefined,
    star_count: usize = 0,
    cluster_count: usize = 0,
    last: u64 = 0,
    navigation: @import("galaxy_camera.zig").Camera = .{},
    active: bool = false,
    layout_active: bool = false,
    camera_active: bool = false,
    signature: u64 = 0,
    layout_until: u64 = 0,
    focus: ?u64 = null,
    pointer: [2]f32 = .{ -1, -1 },

    fn blend(old: f32, target: f32, t: f32, moving: *bool) f32 {
        if (t >= 1) return target;
        if (@abs(old - target) < 0.01) return target;
        // A step below f32 resolution would never arrive, and the view would
        // keep requesting frames: land instead.
        const next = old + (target - old) * t;
        if (next == old) return target;
        moving.* = true;
        return next;
    }
    fn settle(items: anytype, saved: []Point, count: *usize, t: f32, moving: *bool, body: draw.Rect, pixel: f32, comptime key: []const u8) void {
        var previous: [model.max_stars]Point = undefined;
        @memcpy(previous[0..count.*], saved[0..count.*]);
        for (items, 0..) |*item, i| {
            const id = @field(item, key);
            const matched: ?Point = if (i < count.* and previous[i].key == id) previous[i] else found: {
                for (previous[0..count.*]) |old| if (old.key == id) break :found old;
                break :found null;
            };
            if (matched) |old| {
                // Invisible and sub-pixel changes land at once. Radius-only
                // metadata refreshes must not wake a motionless scene.
                const visible = draw.inside(body, old.at[0], old.at[1]) or draw.inside(body, item.at[0], item.at[1]);
                if (visible and (@abs(old.at[0] - item.at[0]) >= pixel or @abs(old.at[1] - item.at[1]) >= pixel)) {
                    for (0..2) |axis| item.at[axis] = blend(old.at[axis], item.at[axis], t, moving);
                    item.r = blend(old.r, item.r, t, moving);
                }
            }
            saved[i] = .{ .key = id, .at = item.at, .r = item.r };
        }
        count.* = items.len;
    }
    pub fn layout(self: *Motion, s: anytype, body: draw.Rect, now: u64, prefs: Look) f32 {
        const dt: f32 = @floatFromInt(@min(now -| self.last, 100_000_000));
        const t = 1 - @exp(-dt / (prefs.easing_ms * 1_000_000 / 4));
        const previous = self.last;
        self.last = now;
        self.active = false;
        if (s.signature != self.signature) {
            self.signature = s.signature;
            // One finite transition per publication, never an exponential tail
            // restarted by each rendered frame. Startup is already settled.
            self.layout_until = if (self.star_count == 0) now else now + 100_000_000;
        }
        const step: f32 = if (now >= self.layout_until) 1 else @min(1, @as(f32, @floatFromInt(now -| previous)) / @as(f32, @floatFromInt(@max(1, self.layout_until -| previous))));
        var minimum = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var maximum = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        for ([_][2]f32{ .{ body.x, body.y }, .{ body.x + body.w, body.y }, .{ body.x, body.y + body.h }, .{ body.x + body.w, body.y + body.h } }) |corner| {
            const world = self.navigation.unproject(corner);
            for (0..2) |axis| {
                minimum[axis] = @min(minimum[axis], world[axis]);
                maximum[axis] = @max(maximum[axis], world[axis]);
            }
        }
        const visible = draw.Rect{ .x = minimum[0], .y = minimum[1], .w = maximum[0] - minimum[0], .h = maximum[1] - minimum[1] };
        self.layout_active = false;
        settle(s.stars[0..s.star_count], &self.stars, &self.star_count, step, &self.layout_active, visible, 1 / self.navigation.zoom, "seed");
        settle(s.clusters[0..s.cluster_count], &self.clusters, &self.cluster_count, step, &self.layout_active, visible, 1 / self.navigation.zoom, "key");
        self.active = self.layout_active;
        return t;
    }
    pub fn camera(self: *Motion, s: *const model.Scene, field: draw.Rect, pointer: [2]f32, selected: ?u64, now: u64, prefs: Look) void {
        self.pointer = pointer;
        self.navigation.field = field;
        self.navigation.update(s, now, prefs);
        self.focus = selected;
        if (self.navigation.selection) |selection| switch (selection) {
            .cluster => |key| self.focus = key,
            .node => |key| for (s.stars[0..s.star_count]) |star| {
                if (star.seed == key) {
                    self.focus = s.clusters[star.cluster].key;
                    break;
                }
            },
        };
        self.camera_active = self.navigation.active;
        self.active = self.layout_active or self.camera_active;
    }
    pub fn transform(self: *const Motion) [6]f32 {
        return self.navigation.transform();
    }
    pub fn project(self: *const Motion, s: anytype) void {
        for (s.stars[0..s.star_count]) |*star| {
            self.point(&star.at);
            star.r *= self.navigation.zoom;
        }
        for (s.clusters[0..s.cluster_count]) |*cl| {
            self.point(&cl.at);
            cl.r *= self.navigation.zoom;
        }
        for (s.junctions[0..s.junction_count]) |*j| self.point(&j.at);
    }
    fn point(self: *const Motion, at: *[2]f32) void {
        at.* = self.navigation.project(at.*);
    }
};

test "an easing step below float resolution lands instead of animating forever" {
    var moving = false;
    try std.testing.expectEqual(@as(f32, 4000.02), Motion.blend(4000, 4000.02, 0.001, &moving));
    try std.testing.expect(!moving);
    try std.testing.expect(Motion.blend(0, 100, 0.5, &moving) == 50 and moving);
}

test "hover and refreshed selection stay still; explicit frame and fit ease" {
    var camera_state = Motion{};
    const fake = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(fake);
    fake.* = .{};
    fake.clusters[0] = .{ .key = 7, .at = .{ 200, 200 }, .r = 80 };
    fake.cluster_count = 1;
    const body = draw.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    camera_state.camera(fake, body, .{ 200, 200 }, null, 1, .{});
    camera_state.camera(fake, body, .{ 400, 300 }, 7, 30_000_001, .{});
    try std.testing.expect(camera_state.navigation.zoom == 1 and !camera_state.active);
    try std.testing.expectEqual(@as(?u64, 7), camera_state.focus);
    camera_state.navigation.selection = .{ .cluster = 7 };
    camera_state.navigation.frame(fake);
    camera_state.camera(fake, body, .{ 200, 200 }, 7, 60_000_001, .{});
    try std.testing.expect(camera_state.navigation.zoom > 1 and camera_state.active);
    const zoomed = camera_state.navigation.zoom;
    camera_state.navigation.fit();
    camera_state.camera(fake, body, .{ -1, -1 }, null, 90_000_001, .{});
    try std.testing.expect(camera_state.navigation.zoom < zoomed and camera_state.focus == null);
}

test "sub-pixel and off-screen layout changes do not request animation" {
    var saved = [_]Point{
        .{ .key = 1, .at = .{ 100, 100 }, .r = 10 },
        .{ .key = 2, .at = .{ 2000, 2000 }, .r = 10 },
    };
    var target = [_]Point{
        .{ .key = 1, .at = .{ 100.5, 100.25 }, .r = 20 },
        .{ .key = 2, .at = .{ 2500, 2000 }, .r = 30 },
    };
    var count: usize = 2;
    var moving = false;
    Motion.settle(&target, &saved, &count, 0.1, &moving, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, "key");
    try std.testing.expect(!moving);
    try std.testing.expectEqual(@as(f32, 100.5), target[0].at[0]);
    try std.testing.expectEqual(@as(f32, 2500), target[1].at[0]);
}

test "camera-hidden layout movement lands without waking the view" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    scene.stars[0] = .{ .seed = 1, .at = .{ 600, 100 }, .r = 10 };
    scene.star_count = 1;
    scene.signature = 1;
    const body = draw.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var motion = Motion{};
    _ = motion.layout(scene, body, 1, .{});
    motion.navigation.zoom = 2;
    scene.stars[0].at[0] = 700;
    scene.signature = 2;
    _ = motion.layout(scene, body, 30_000_001, .{});
    try std.testing.expect(!motion.active);
    try std.testing.expectEqual(@as(f32, 700), scene.stars[0].at[0]);
}
