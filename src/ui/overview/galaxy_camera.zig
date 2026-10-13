//! User-owned camera shared by every galaxy adapter. Data and hover never
//! retarget it; world positions are sampled only by an explicit frame gesture.
const std = @import("std");
const draw = @import("draw.zig");
const model = @import("galaxy_model.zig");
const input = @import("../../platform/input.zig");
const Look = @import("../../preferences.zig").Galaxy;
pub const Selection = union(enum) { node: u64, cluster: u64 };
pub const hints = "WASD pan (S not sort) / wheel zoom / drag / Enter frame / arrows clusters / , . rotate / H fit / O tour / ?";
pub const Camera = struct {
    zoom: f32 = 1,
    shift: [2]f32 = .{ 0, 0 },
    angle: f32 = 0,
    target_zoom: f32 = 1,
    target_shift: [2]f32 = .{ 0, 0 },
    target_angle: f32 = 0,
    field: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    selection: ?Selection = null,
    held: [3]f32 = @splat(0),
    active: bool = false,
    tour: bool = false,
    tour_at: u64 = 0,
    last: u64 = 0,
    focus_revision: u64 = 0,
    focus_seen: bool = false,
    help: bool = true,
    help_until: u64 = 0,
    frame_zoom: f32 = 1.35,
    drag: ?struct { pointer: [2]f32, shift: [2]f32 } = null,
    click_at: u64 = 0,
    click: ?Selection = null,

    pub fn transform(self: *const Camera) [6]f32 {
        return .{ self.zoom, 1, self.shift[0], self.shift[1], @cos(self.angle), @sin(self.angle) };
    }
    fn rotate(point: [2]f32, angle: f32) [2]f32 {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{ point[0] * c - point[1] * s, point[0] * s + point[1] * c };
    }
    pub fn project(self: *const Camera, point: [2]f32) [2]f32 {
        const p = rotate(point, self.angle);
        return .{ p[0] * self.zoom + self.shift[0], p[1] * self.zoom + self.shift[1] };
    }
    pub fn unproject(self: *const Camera, point: [2]f32) [2]f32 {
        return rotate(.{ (point[0] - self.shift[0]) / self.zoom, (point[1] - self.shift[1]) / self.zoom }, -self.angle);
    }
    fn center(self: *const Camera) [2]f32 {
        return .{ self.field.x + self.field.w / 2, self.field.y + self.field.h / 2 };
    }
    fn anchor(self: *Camera, world: [2]f32, screen: [2]f32) void {
        const at = rotate(world, self.target_angle);
        self.target_shift = .{ screen[0] - at[0] * self.target_zoom, screen[1] - at[1] * self.target_zoom };
        self.active = true;
    }
    pub fn stopTour(self: *Camera) void {
        if (self.tour) {
            self.target_zoom = self.zoom;
            self.target_angle = self.angle;
            self.target_shift = self.shift;
        }
        self.tour = false;
        self.tour_at = 0;
    }
    pub fn fit(self: *Camera) void {
        self.stopTour();
        self.selection = null;
        self.target_zoom = 1;
        // Drop whole turns first: after a long tour the fit must not spin
        // back through every revolution the drift accumulated.
        const turns = @round(self.angle / std.math.tau) * std.math.tau;
        self.angle -= turns;
        self.target_angle = 0;
        self.target_shift = .{ 0, 0 };
        self.active = true;
    }
    /// Scene coordinates here are the displayed positions: identical to picking.
    pub fn frame(self: *Camera, scene: *const model.Scene) void {
        self.frameAt(scene, true);
    }
    fn frameAt(self: *Camera, scene: *const model.Scene, projected: bool) void {
        const selected = self.selection orelse return;
        switch (selected) {
            .node => |id| for (scene.stars[0..scene.star_count]) |node| {
                if (node.seed != id) continue;
                self.target_zoom = @max(self.zoom, self.frame_zoom * 3);
                self.anchor(if (projected) self.unproject(node.at) else node.at, self.center());
                return;
            },
            .cluster => |id| for (scene.clusters[0..scene.cluster_count]) |cluster| {
                if (cluster.key != id) continue;
                self.target_zoom = std.math.clamp(@min(self.field.w, self.field.h) * 0.38 / @max(12, cluster.r / if (projected) self.zoom else 1), self.frame_zoom, 12);
                self.anchor(if (projected) self.unproject(cluster.at) else cluster.at, self.center());
                return;
            },
        }
    }
    pub fn pick(scene: *const model.Scene, point: [2]f32) ?Selection {
        var i: usize = scene.star_count;
        while (i > 0) {
            i -= 1;
            const node = scene.stars[i];
            if (@abs(point[0] - node.at[0]) < 12 and @abs(point[1] - node.at[1]) < 12) return .{ .node = node.seed };
        }
        for (scene.clusters[0..scene.cluster_count]) |cluster| {
            const dx = point[0] - cluster.at[0];
            const dy = point[1] - cluster.at[1];
            if (dx * dx + dy * dy <= cluster.r * cluster.r) return .{ .cluster = cluster.key };
        }
        return null;
    }
    pub fn press(self: *Camera, scene: *const model.Scene, point: [2]f32, now: u64) bool {
        self.stopTour();
        if (!draw.inside(self.field, point[0], point[1])) return false;
        if (pick(scene, point)) |selected| {
            self.selection = selected;
            if (self.click != null and std.meta.eql(self.click.?, selected) and now -| self.click_at < 350_000_000) self.frame(scene);
            self.click = selected;
            self.click_at = now;
        } else {
            self.click = null;
            self.drag = .{ .pointer = point, .shift = self.shift };
        }
        return true;
    }
    pub fn pointer(self: *Camera, point: [2]f32) void {
        // The compositor's initial pointer position is not a user gesture.
        if (self.last != 0) self.stopTour();
        const drag = self.drag orelse return;
        self.target_shift = .{ drag.shift[0] + point[0] - drag.pointer[0], drag.shift[1] + point[1] - drag.pointer[1] };
        self.shift = self.target_shift;
        self.active = true;
    }
    pub fn wheel(self: *Camera, lines: i32, point: [2]f32, prefs: Look) void {
        self.stopTour();
        const world = self.unproject(point);
        self.target_zoom = std.math.clamp(self.zoom * std.math.pow(f32, prefs.zoom_speed, -@as(f32, @floatFromInt(lines))), 0.4, 12);
        // Zoom and translation land together so the pointed world point never
        // slips, including midway through an earlier framing transition.
        self.target_angle = self.angle;
        self.anchor(world, point);
        self.zoom = self.target_zoom;
        self.shift = self.target_shift;
    }
    pub fn carousel(self: *Camera, scene: *const model.Scene, direction: i32) void {
        self.advance(scene, direction, true);
    }
    fn advance(self: *Camera, scene: *const model.Scene, direction: i32, projected: bool) void {
        const n: usize = scene.cluster_count;
        if (n == 0) return;
        var order: [model.max_clusters]u16 = undefined;
        for (order[0..n], 0..) |*entry, i| entry.* = @intCast(i);
        const Context = struct {
            scene: *const model.Scene,
            fn less(ctx: @This(), a: u16, b: u16) bool {
                const ca = ctx.scene.clusters[a];
                const cb = ctx.scene.clusters[b];
                if (ca.rate != cb.rate) return ca.rate > cb.rate;
                if (ca.members != cb.members) return ca.members > cb.members;
                if (ca.stars != cb.stars) return ca.stars > cb.stars;
                return ca.key < cb.key;
            }
        };
        std.mem.sort(u16, order[0..n], Context{ .scene = scene }, Context.less);
        var next: usize = if (direction < 0) n - 1 else 0;
        if (self.selection) |selected| {
            const selected_key: ?u64 = switch (selected) {
                .cluster => |id| id,
                .node => |id| found: {
                    for (scene.stars[0..scene.star_count]) |star| if (star.seed == id) break :found scene.clusters[star.cluster].key;
                    break :found null;
                },
            };
            for (order[0..n], 0..) |index, i| if (scene.clusters[index].key == selected_key) {
                next = if (direction < 0) (i + n - 1) % n else (i + 1) % n;
                break;
            };
        }
        self.selection = .{ .cluster = scene.clusters[order[next]].key };
        self.frameAt(scene, projected);
    }
    pub fn key(self: *Camera, scene: *const model.Scene, event: input.Event) bool {
        if (event.kind != .press and event.kind != .repeat) return false;
        if (event.plain() and event.shortcut == 'o') {
            if (event.kind == .press) {
                if (self.tour) self.stopTour() else {
                    self.tour = true;
                    self.tour_at = 0;
                    self.active = true;
                }
            }
            return true;
        }
        self.stopTour();
        if (!event.plain()) return false;
        if (event.sym == '?') {
            self.help = true;
            self.help_until = 0;
            return true;
        }
        switch (event.shortcut) {
            'w', 'a', 's', 'd', ',', '.' => return true,
            'h', 0xff50 => self.fit(),
            0xff51, 0xff53 => if (event.kind == .press) self.carousel(scene, if (event.shortcut == 0xff51) -1 else 1),
            0xff0d => if (event.kind == .press) self.frame(scene),
            '?' => if (event.kind == .press) {
                self.help = !self.help;
            },
            else => return false,
        }
        return true;
    }
    pub fn controls(self: *Camera, keyboard: *const input.Keyboard, enabled: bool) bool {
        const mods = keyboard.mods();
        const focused = enabled and keyboard.focused and !mods.ctrl and !mods.alt and !mods.super;
        if (self.focus_seen and (self.focus_revision != keyboard.focus_revision or !focused)) {
            // Losing focus releases keys and drags. It is not a gesture, so a
            // tour being watched or recorded from another window keeps going.
            self.held = @splat(0);
            self.drag = null;
            self.focus_revision = keyboard.focus_revision;
        }
        if (focused) {
            self.focus_seen = true;
            self.focus_revision = keyboard.focus_revision;
        }
        var held: [3]f32 = @splat(0);
        if (focused) {
            const positive = [_]u32{ 'd', 's', '.' };
            const negative = [_]u32{ 'a', 'w', ',' };
            for (&held, positive, negative) |*value, plus, minus| value.* = @as(f32, if (keyboard.heldShortcut(plus)) 1 else 0) - @as(f32, if (keyboard.heldShortcut(minus)) 1 else 0);
        }
        const changed = !std.meta.eql(held, self.held);
        self.held = held;
        if (!std.meta.eql(held, @as([3]f32, @splat(0)))) {
            self.stopTour();
            self.active = true;
        }
        // Wake on input transitions only. The owner's animation deadline
        // schedules subsequent frames; marking every pump dirty defeats it.
        return changed;
    }
    fn ease(current: *f32, target: f32, fraction: f32, epsilon: f32) bool {
        if (@abs(target - current.*) <= epsilon) {
            current.* = target;
            return false;
        }
        const next = current.* + (target - current.*) * fraction;
        if (next == current.*) {
            current.* = target;
            return false;
        }
        current.* = next;
        return true;
    }
    /// `scene` contains world positions, before the drawing transform.
    pub fn update(self: *Camera, scene: *const model.Scene, now: u64, prefs: Look) void {
        const dt: f32 = @as(f32, @floatFromInt(@min(now -| self.last, 50_000_000))) / 1e9;
        self.last = now;
        self.frame_zoom = prefs.camera_zoom;
        if (self.help and self.help_until == 0) self.help_until = now + 8_000_000_000;
        if (self.help_until != 0 and now >= self.help_until) self.help = false;
        if (self.tour and (self.tour_at == 0 or now >= self.tour_at)) {
            self.advance(scene, 1, false);
            self.tour_at = now + @as(u64, @intFromFloat(prefs.tour_seconds * 1e9));
        }
        const turn = self.held[2] * prefs.rotate_speed + (if (self.tour and prefs.tour_drift) prefs.tour_drift_speed else @as(f32, 0));
        if (turn != 0) {
            const center_ = self.center();
            const world = rotate(.{ (center_[0] - self.target_shift[0]) / self.target_zoom, (center_[1] - self.target_shift[1]) / self.target_zoom }, -self.target_angle);
            self.target_angle += turn * dt;
            self.anchor(world, center_);
        }
        self.target_shift[0] -= self.held[0] * prefs.pan_speed * dt;
        self.target_shift[1] -= self.held[1] * prefs.pan_speed * dt;
        // A tour hop is watched, not steered: glide for about a second
        // instead of the quick ease that suits a key or a click.
        const settle_seconds = if (self.tour) @max(prefs.easing_ms / 4000, prefs.tour_seconds / 12) else prefs.easing_ms / 4000;
        const fraction = 1 - @exp(-dt / settle_seconds);
        var moving = ease(&self.zoom, self.target_zoom, fraction, 0.0001);
        moving = ease(&self.angle, self.target_angle, fraction, 0.0001) or moving;
        for (0..2) |axis| moving = ease(&self.shift[axis], self.target_shift[axis], fraction, 0.01) or moving;
        self.active = moving or self.tour or !std.meta.eql(self.held, @as([3]f32, @splat(0)));
    }
};

test "camera projection, wheel anchor and transformed pick agree" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    var camera = Camera{ .zoom = 2, .angle = 0.7, .shift = .{ -80, 50 } };
    const world = [2]f32{ 170, 110 };
    const point = camera.project(world);
    const back = camera.unproject(point);
    for (0..2) |axis| try std.testing.expectApproxEqAbs(world[axis], back[axis], 0.0001);
    camera.wheel(-3, point, .{});
    const anchored = camera.project(world);
    for (0..2) |axis| try std.testing.expectApproxEqAbs(point[axis], anchored[axis], 0.0001);
    _ = scene.addStar(.{ .seed = 41, .at = anchored }, "picked");
    try std.testing.expectEqual(@as(u64, 41), Camera.pick(scene, point).?.node);
    try std.testing.expect(Camera.pick(scene, .{ point[0] + 13, point[1] }) == null);
}

test "selection is still, double click frames once, refresh cannot follow" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    _ = scene.addStar(.{ .seed = 7, .at = .{ 120, 160 } }, "node");
    var camera = Camera{ .field = .{ .x = 0, .y = 0, .w = 800, .h = 600 } };
    try std.testing.expect(camera.press(scene, .{ 120, 160 }, 1));
    camera.update(scene, 30_000_001, .{});
    try std.testing.expectEqual(@as(f32, 1), camera.zoom);
    try std.testing.expect(!camera.active);
    try std.testing.expect(camera.press(scene, .{ 120, 160 }, 100_000_001));
    const target = camera.target_shift;
    scene.stars[0].at = .{ 220, 300 };
    camera.pointer(.{ 220, 300 });
    for (0..100) |i| camera.update(scene, 130_000_001 + i * 30_000_000, .{});
    try std.testing.expectEqual(target, camera.shift);
    try std.testing.expect(!camera.active and camera.zoom > 1);
    camera.fit();
    for (0..100) |i| camera.update(scene, 4_000_000_001 + i * 30_000_000, .{});
    try std.testing.expectEqual(@as([2]f32, .{ 0, 0 }), camera.shift);
    try std.testing.expectEqual(@as(f32, 1), camera.zoom);
    try std.testing.expect(!camera.active and camera.selection == null);
}

test "carousel is ordered by activity, size and stable identity" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    scene.cluster_count = 4;
    scene.clusters[0] = .{ .key = 9, .members = 3 };
    scene.clusters[1] = .{ .key = 3, .members = 3 };
    scene.clusters[2] = .{ .key = 1, .members = 20 };
    scene.clusters[3] = .{ .key = 7, .rate = 1 };
    var camera = Camera{};
    for ([_]u64{ 7, 1, 3, 9, 7 }) |expected| {
        camera.carousel(scene, 1);
        try std.testing.expectEqual(expected, camera.selection.?.cluster);
    }
    camera.carousel(scene, -1);
    try std.testing.expectEqual(@as(u64, 9), camera.selection.?.cluster);
}

test "held pan and rotation ease to finite idle; fit clears rotation" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    var camera = Camera{ .field = .{ .x = 0, .y = 0, .w = 800, .h = 600 } };
    for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 } }) |held| {
        camera.held = held;
        const before = camera.target_shift;
        camera.update(scene, camera.last + 30_000_000, .{});
        for (0..2) |axis| try std.testing.expectApproxEqAbs(before[axis] - held[axis] * 340 * 0.03, camera.target_shift[axis], 0.001);
    }
    const centre = camera.center();
    const world = camera.unproject(centre);
    camera.target_shift = camera.shift;
    camera.held = .{ 0, 0, 1 };
    camera.update(scene, camera.last + 30_000_000, .{});
    try std.testing.expect(camera.target_angle > 0);
    camera.held = @splat(0);
    for (0..100) |_| camera.update(scene, camera.last + 30_000_000, .{});
    const point = camera.project(world);
    for (0..2) |axis| try std.testing.expectApproxEqAbs(centre[axis], point[axis], 0.001);
    try std.testing.expect(!camera.active);
    camera.fit();
    for (0..100) |_| camera.update(scene, camera.last + 30_000_000, .{});
    try std.testing.expectEqual(@as(f32, 0), camera.angle);
    try std.testing.expect(!camera.active);
    // Many turns of accumulated drift fit back by the short way round.
    camera.angle = 5 * std.math.tau + 0.3;
    camera.target_angle = camera.angle;
    camera.fit();
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), camera.angle, 0.001);
    for (0..100) |_| camera.update(scene, camera.last + 30_000_000, .{});
    try std.testing.expectEqual(@as(f32, 0), camera.angle);
}

test "focus loss drops held keys and drags but leaves a tour running; tour hops glide" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    scene.cluster_count = 1;
    scene.clusters[0] = .{ .key = 5, .at = .{ 200, 150 }, .r = 40 };
    var keyboard = input.Keyboard{};
    keyboard.focused = true;
    var camera = Camera{ .field = .{ .x = 0, .y = 0, .w = 800, .h = 600 } };
    _ = camera.controls(&keyboard, true);
    try std.testing.expect(camera.key(scene, .{ .kind = .press, .shortcut = 'o' }));
    camera.drag = .{ .pointer = .{ 0, 0 }, .shift = .{ 0, 0 } };
    camera.held = .{ 1, 0, 0 };
    keyboard.focused = false;
    keyboard.focus_revision += 1;
    _ = camera.controls(&keyboard, true);
    try std.testing.expect(camera.tour and camera.drag == null and camera.held[0] == 0);
    camera.update(scene, 30_000_001, .{});
    camera.update(scene, 60_000_001, .{});
    const toured = camera.zoom - 1;
    var direct = Camera{ .field = camera.field, .selection = .{ .cluster = 5 } };
    direct.frameAt(scene, false);
    direct.update(scene, 30_000_001, .{});
    direct.update(scene, 60_000_001, .{});
    try std.testing.expect(toured > 0 and toured < (direct.zoom - 1) / 2);
}

test "empty drag pans; tour advances and any key or pointer stops it" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    scene.cluster_count = 1;
    scene.clusters[0] = .{ .key = 5, .at = .{ 200, 150 }, .r = 40 };
    var camera = Camera{ .field = .{ .x = 0, .y = 0, .w = 800, .h = 600 } };
    try std.testing.expect(camera.press(scene, .{ 10, 10 }, 1));
    camera.pointer(.{ 50, 30 });
    try std.testing.expectEqual(@as([2]f32, .{ 40, 20 }), camera.shift);
    camera.drag = null;
    try std.testing.expect(camera.key(scene, .{ .kind = .press, .shortcut = 'o' }));
    camera.update(scene, 30_000_001, .{});
    try std.testing.expect(camera.tour and camera.active and camera.selection.?.cluster == 5);
    _ = camera.key(scene, .{ .kind = .press, .shortcut = 'q' });
    try std.testing.expect(!camera.tour);
    _ = camera.key(scene, .{ .kind = .press, .shortcut = 'o' });
    camera.pointer(.{ 55, 30 });
    camera.update(scene, 60_000_001, .{});
    try std.testing.expect(!camera.tour and !camera.active);
}
