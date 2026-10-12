//! Presentation-only easing. World geometry is retained while camera motion is
//! a GPU transform; new layouts settle by stable process/group identity.
const std = @import("std");
const draw = @import("draw.zig");
const Look = @import("../../preferences.zig").Galaxy;
const Point = struct { key: u64, at: [2]f32, r: f32 };
pub const Motion = struct {
    stars: [1024]Point = undefined,
    clusters: [40]Point = undefined,
    star_count: usize = 0,
    cluster_count: usize = 0,
    last: u64 = 0,
    zoom: f32 = 1,
    shift: [2]f32 = .{ 0, 0 },
    active: bool = false,
    focus: ?u64 = null,
    hover: ?u64 = null,
    pointer: [2]f32 = .{ -1, -1 },

    fn blend(old: f32, target: f32, t: f32, moving: *bool) f32 {
        if (@abs(old - target) < 0.01) return target;
        // A step below f32 resolution would never arrive, and the view would
        // keep requesting frames: land instead.
        const next = old + (target - old) * t;
        if (next == old) return target;
        moving.* = true;
        return next;
    }
    fn settle(items: anytype, saved: []Point, count: *usize, t: f32, moving: *bool, comptime key: []const u8) void {
        var previous: [1024]Point = undefined;
        @memcpy(previous[0..count.*], saved[0..count.*]);
        for (items, 0..) |*item, i| {
            const id = @field(item, key);
            const matched: ?Point = if (i < count.* and previous[i].key == id) previous[i] else found: {
                for (previous[0..count.*]) |old| if (old.key == id) break :found old;
                break :found null;
            };
            if (matched) |old| {
                for (0..2) |axis| item.at[axis] = blend(old.at[axis], item.at[axis], t, moving);
                item.r = blend(old.r, item.r, t, moving);
            }
            saved[i] = .{ .key = id, .at = item.at, .r = item.r };
        }
        count.* = items.len;
    }
    pub fn layout(self: *Motion, s: anytype, now: u64, prefs: Look) f32 {
        const dt: f32 = @floatFromInt(@min(now -| self.last, 100_000_000));
        const t = 1 - @exp(-dt / (prefs.easing_ms * 1_000_000 / 4));
        self.last = now;
        self.active = false;
        settle(s.stars[0..s.star_count], &self.stars, &self.star_count, t, &self.active, "seed");
        settle(s.clusters[0..s.cluster_count], &self.clusters, &self.cluster_count, t, &self.active, "key");
        return t;
    }
    pub fn camera(self: *Motion, s: anytype, body: draw.Rect, pointer: [2]f32, selected: ?u64, t: f32, prefs: Look) void {
        const world = [2]f32{ (pointer[0] - self.shift[0]) / self.zoom, (pointer[1] - self.shift[1]) / self.zoom };
        var target: ?usize = null;
        var best: f32 = 1;
        const moved = !std.meta.eql(pointer, self.pointer);
        self.pointer = pointer;
        if (moved) self.hover = null;
        for (s.clusters[0..s.cluster_count]) |cl| {
            const dx = world[0] - cl.at[0];
            const dy = world[1] - cl.at[1];
            const score = (dx * dx + dy * dy) / @max(1, cl.r * cl.r);
            if (moved and draw.inside(body, pointer[0], pointer[1]) and score < best) {
                best = score;
                self.hover = cl.key;
            }
        }
        if (self.hover orelse selected) |key| {
            for (s.clusters[0..s.cluster_count], 0..) |cl, i| if (cl.key == key) {
                target = i;
                break;
            };
        }
        self.focus = if (target) |i| s.clusters[i].key else null;
        const zoom: f32 = if (target != null) prefs.camera_zoom else 1;
        const center = [2]f32{ body.x + body.w / 2, body.y + body.h / 2 };
        const at = if (target) |i| s.clusters[i].at else center;
        self.zoom = blend(self.zoom, zoom, t, &self.active);
        for (0..2) |axis| self.shift[axis] = blend(self.shift[axis], center[axis] - at[axis] * zoom, t, &self.active);
    }
    pub fn transform(self: *const Motion) [4]f32 {
        return .{ self.zoom, 1, self.shift[0], self.shift[1] };
    }
    pub fn project(self: *const Motion, s: anytype) void {
        for (s.stars[0..s.star_count]) |*star| {
            self.point(&star.at);
            star.r *= self.zoom;
        }
        for (s.clusters[0..s.cluster_count]) |*cl| {
            self.point(&cl.at);
            cl.r *= self.zoom;
        }
        for (s.junctions[0..s.junction_count]) |*j| self.point(&j.at);
    }
    fn point(self: *const Motion, at: *[2]f32) void {
        for (0..2) |axis| at[axis] = at[axis] * self.zoom + self.shift[axis];
    }
};

test "an easing step below float resolution lands instead of animating forever" {
    var moving = false;
    try std.testing.expectEqual(@as(f32, 4000.02), Motion.blend(4000, 4000.02, 0.001, &moving));
    try std.testing.expect(!moving);
    try std.testing.expect(Motion.blend(0, 100, 0.5, &moving) == 50 and moving);
}

test "camera eases, holds its hovered identity while moving, and returns on leave" {
    var camera_state = Motion{};
    const fake = struct { clusters: [1]Point, cluster_count: usize }{ .clusters = .{.{ .key = 7, .at = .{ 200, 200 }, .r = 80 }}, .cluster_count = 1 };
    const body = draw.Rect{ .x = 0, .y = 0, .w = 800, .h = 600 };
    camera_state.camera(&fake, body, .{ 200, 200 }, null, 0.2, .{});
    try std.testing.expect(camera_state.zoom > 1 and camera_state.zoom < 1.35);
    try std.testing.expectEqual(@as(?u64, 7), camera_state.focus);
    const first = camera_state.zoom;
    camera_state.camera(&fake, body, .{ 200, 200 }, null, 0.2, .{});
    try std.testing.expect(camera_state.zoom > first);
    const zoomed = camera_state.zoom;
    camera_state.camera(&fake, body, .{ -1, -1 }, null, 0.2, .{});
    try std.testing.expect(camera_state.zoom < zoomed and camera_state.focus == null);
    camera_state.camera(&fake, body, .{ -1, -1 }, 7, 0.2, .{});
    try std.testing.expectEqual(@as(?u64, 7), camera_state.focus);
}
