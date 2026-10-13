//! Street-level camera. Integer avenues stay outside every tower footprint
//! (centres are half-integers, half-width .36); turns happen at intersections.
const std = @import("std");
const city = @import("city.zig");
const m = city.math;
pub const Pose = struct { eye: m.Vec3, target: m.Vec3, up: m.Vec3 = .{ 0, 1, 0 }, fov: f32 = 1.05, near: f32 = 0.035 };
pub fn overview(camera: city.Camera, width: f32, depth: f32) Pose {
    const distance = @max(5, @max(width, depth)) * camera.zoom * camera.dolly;
    const target: m.Vec3 = .{ width / 2 + camera.pan[0], 0.6, depth / 2 + camera.pan[1] };
    return .{ .eye = m.add(target, .{ @sin(camera.yaw) * @cos(camera.pitch) * distance, @sin(camera.pitch) * distance, @cos(camera.yaw) * @cos(camera.pitch) * distance }), .target = target, .fov = 0.95, .near = 0.05 };
}
pub fn matrix(pose: Pose, span: f32, aspect: f32) ?m.Mat4 {
    return m.mul(m.perspective(pose.fov, aspect, pose.near, @max(5, span) * 20 + 100) orelse return null, m.lookAt(pose.eye, pose.target, pose.up) orelse return null);
}
pub const Flight = struct {
    on: bool = false,
    returning: bool = false,
    automatic: bool = true,
    saved: city.Camera = .{},
    eye: m.Vec3 = .{ 0, 1.2, -1 },
    heading: f32 = 0,
    bank: f32 = 0,
    speed: f32 = 1.5,
    cruise: f32 = 1.5,
    direction: u2 = 0,
    turn: i8 = 0,
    altitude: f32 = 0,
    until_corner: f32 = 1,
    last: u64 = 0,
    return_at: u64 = 0,
    return_from: Pose = .{ .eye = .{ 0, 1, 0 }, .target = .{ 0, 1, 1 } },
    roof: f32 = 5,
    destination: [2]f32 = .{ 0, 0 },
    visits: usize = 0,
    leg: u2 = 0,
    corners: u64 = 0,

    pub fn active(self: *const Flight) bool {
        return self.on or self.returning;
    }
    pub fn pose(self: *const Flight) Pose {
        const forward: m.Vec3 = .{ @sin(self.heading), -0.035, @cos(self.heading) };
        return .{ .eye = self.eye, .target = m.add(self.eye, forward), .up = .{ @cos(self.heading) * @sin(self.bank), @cos(self.bank), -@sin(self.heading) * @sin(self.bank) } };
    }
    pub fn toggle(self: *Flight, camera: *city.Camera, layout: *const city.Layout, now: u64) void {
        if (self.returning) return;
        if (self.on) {
            self.on = false;
            self.returning = true;
            self.return_at = now;
            self.return_from = self.pose();
            self.roof = @max(self.eye[1], overview(self.saved, layout.width, layout.depth).eye[1]) + 1;
            for (layout.places.items) |p| self.roof = @max(self.roof, p.height + 1);
            return;
        }
        if (layout.districts.items.len == 0) return;
        self.* = .{ .on = true, .saved = camera.*, .last = now };
        self.saved.automatic = false; // F completes the cycle in manual mode.
        // Largest district is a reproducible first attraction; subsequent visits
        // tour the remaining districts, whose page changes remain visible.
        var largest: usize = 0;
        for (layout.districts.items, 0..) |d, i| if (d.count > layout.districts.items[largest].count) {
            largest = i;
        };
        self.visits = largest;
        const d = layout.districts.items[largest];
        self.eye = .{ d.x + d.width + 1, 1.2, d.z - 1 };
        self.destination = .{ self.eye[0], d.z + d.depth + 1 };
        camera.cancelMotion(now);
        camera.automatic = false;
    }
    pub fn steer(self: *Flight, turn: i8, altitude: f32) void {
        if (!self.on) return;
        if (turn != 0 or altitude != 0) self.automatic = false;
        if (turn != 0) self.turn = turn;
        self.altitude = altitude;
    }
    pub fn faster(self: *Flight, amount: f32) void {
        self.cruise = std.math.clamp(self.cruise * @exp(amount * 0.2), 0.4, 5);
    }
    fn corner(self: *Flight, layout: *const city.Layout) void {
        self.corners += 1;
        if (self.automatic) {
            if (@abs(self.eye[0] - self.destination[0]) + @abs(self.eye[2] - self.destination[1]) < 0.1) {
                self.leg +%= 1;
                if (self.leg == 0) self.visits += 1;
                if (layout.districts.items.len > 0) {
                    const d = layout.districts.items[self.visits % layout.districts.items.len];
                    self.destination = switch (self.leg) {
                        0 => .{ d.x + d.width + 1, d.z + d.depth + 1 },
                        1 => .{ d.x - 1, d.z + d.depth + 1 },
                        2 => .{ d.x - 1, d.z - 1 },
                        3 => .{ d.x + d.width + 1, d.z - 1 },
                    };
                }
            }
            const dx = self.destination[0] - self.eye[0];
            const dz = self.destination[1] - self.eye[2];
            const desired: u2 = if (@abs(dx) > @abs(dz)) (if (dx > 0) 1 else 3) else (if (dz > 0) 0 else 2);
            self.direction = desired;
        } else if (self.turn != 0) {
            // Screen right of heading h is (-cos h, 0, sin h): a right turn
            // is one step down the direction ring.
            self.direction +%= if (self.turn > 0) @as(u2, 3) else 1;
            self.turn = 0;
        }
    }
    pub fn tick(self: *Flight, camera: *city.Camera, layout: *const city.Layout, now: u64) Pose {
        const dt: f32 = @as(f32, @floatFromInt(@min(now -| self.last, 100_000_000))) / 1e9;
        self.last = now;
        if (self.returning) {
            const t = @min(1, @as(f32, @floatFromInt(now -| self.return_at)) / 1_200_000_000);
            const end = overview(self.saved, layout.width, layout.depth);
            const from = self.return_from.eye;
            const high_from: m.Vec3 = .{ from[0], self.roof, from[2] };
            const high_end: m.Vec3 = .{ end.eye[0], self.roof, end.eye[2] };
            // Rise above the roofs before crossing the grid, then descend to
            // the saved overview. No diagonal shortcut through a building.
            self.eye = if (t < 0.3) lerp(from, high_from, smooth(t / 0.3)) else if (t < 0.75) lerp(high_from, high_end, smooth((t - 0.3) / 0.45)) else lerp(high_end, end.eye, smooth((t - 0.75) / 0.25));
            if (t >= 1) {
                camera.* = self.saved;
                camera.cancelMotion(now);
                // Preserve automatic preference but don't restart the idle orbit.
                camera.auto_until = now;
                self.returning = false;
                return end;
            }
            return .{ .eye = self.eye, .target = lerp(self.return_from.target, end.target, smooth(t)), .up = lerp(self.return_from.up, end.up, smooth(t)), .fov = 1.05 - 0.10 * smooth(t), .near = 0.035 + 0.015 * smooth(t) };
        }
        if (!self.on or !camera.active) return self.pose();
        const approaching = if (self.automatic) @abs(self.eye[0] - self.destination[0]) + @abs(self.eye[2] - self.destination[1]) else if (self.turn != 0) self.until_corner else 3;
        const wanted = self.cruise * (0.55 + 0.45 * @min(1, approaching / 2));
        self.speed += (wanted - self.speed) * (1 - @exp(-dt * 5));
        var travel = self.speed * dt;
        // dt and speed are capped: at most one full grid segment per frame.
        for (0..2) |_| {
            const step = @min(travel, self.until_corner);
            switch (self.direction) {
                0 => self.eye[2] += step,
                1 => self.eye[0] += step,
                2 => self.eye[2] -= step,
                3 => self.eye[0] -= step,
            }
            travel -= step;
            self.until_corner -= step;
            if (self.until_corner > 0.00001) break;
            self.eye[0] = @round(self.eye[0]);
            self.eye[2] = @round(self.eye[2]);
            self.corner(layout);
            self.until_corner = 1;
        }
        self.eye[1] = std.math.clamp(self.eye[1] + self.altitude * dt, 0.45, 4);
        const target = @as(f32, @floatFromInt(self.direction)) * std.math.pi / 2;
        const angle = @mod(target - self.heading + std.math.pi, std.math.tau) - std.math.pi;
        self.heading += angle * (1 - @exp(-dt * 7));
        // Positive bank leans the camera's up vector left; lean into the turn.
        self.bank += (std.math.clamp(angle * 0.4, -0.3, 0.3) - self.bank) * (1 - @exp(-dt * 5));
        return self.pose();
    }
};
fn smooth(t: f32) f32 {
    return t * t * (3 - 2 * t);
}
fn lerp(a: m.Vec3, b: m.Vec3, t: f32) m.Vec3 {
    return m.add(a, m.scale(m.sub(b, a), t));
}

test "avenue flight is deterministic, stays outside towers and restores its camera" {
    const a = std.testing.allocator;
    var layout = city.Layout{};
    defer layout.deinit();
    try layout.districts.append(std.heap.page_allocator, .{ .vma = null, .first = 0, .count = 16, .x = 0, .z = 0, .width = 4, .depth = 4 });
    for (0..16) |i| try layout.places.append(std.heap.page_allocator, .{ .index = @intCast(i), .address = i, .x = @as(f32, @floatFromInt(i % 4)) + 0.5, .z = @as(f32, @floatFromInt(i / 4)) + 0.5, .height = 3 });
    _ = a;
    var camera = city.Camera{ .automatic = false, .yaw = 1.1, .pan = .{ 2, 1 } };
    const saved = camera;
    var flight = Flight{};
    flight.toggle(&camera, &layout, 1);
    var twin = flight;
    for (1..1201) |i| {
        const pose = flight.tick(&camera, &layout, i * 16_000_000);
        const other = twin.tick(&camera, &layout, i * 16_000_000);
        try std.testing.expectEqual(pose, other);
        for (layout.places.items) |p| try std.testing.expect(@abs(pose.eye[0] - p.x) >= 0.36 or @abs(pose.eye[2] - p.z) >= 0.36 or pose.eye[1] > p.height);
    }
    try std.testing.expect(flight.corners > 10);
    flight.toggle(&camera, &layout, 20_000_000_000);
    var returned: Pose = undefined;
    for (0..76) |i| {
        returned = flight.tick(&camera, &layout, 20_000_000_000 + i * 16_000_000);
        for (layout.places.items) |p| try std.testing.expect(@abs(returned.eye[0] - p.x) >= 0.36 or @abs(returned.eye[2] - p.z) >= 0.36 or returned.eye[1] > p.height);
    }
    // A saved pose alone is not sufficient: FOV/clip changes must also land
    // on the ordinary overview matrix without a final-frame zoom jump.
    const final_matrix = matrix(returned, @max(layout.width, layout.depth), 1.6).?;
    for (final_matrix, saved.matrix(layout.width, layout.depth, 1.6).?) |actual, expected| try std.testing.expectApproxEqAbs(expected, actual, 0.00001);
    try std.testing.expect(!flight.active());
    try std.testing.expectEqual(saved.yaw, camera.yaw);
    try std.testing.expectEqual(saved.pan, camera.pan);
    try std.testing.expect(!camera.animating(22_000_000_000));
}

test "a right turn goes to the camera's right and banks into it" {
    var layout = city.Layout{};
    var camera = city.Camera{ .automatic = false };
    var flight = Flight{ .on = true, .automatic = false, .last = 1 };
    const before = flight.pose();
    const right = m.cross(m.sub(before.target, before.eye), before.up);
    flight.steer(1, 0);
    flight.corner(&layout);
    const moved = flight.tick(&camera, &layout, 50_000_000);
    try std.testing.expect(m.dot(m.sub(moved.eye, before.eye), right) > 0);
    try std.testing.expect(m.dot(moved.up, right) > 0);
}
