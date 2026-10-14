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
    film: bool = false,
    direction: u2 = 0,
    turn: i8 = 0,
    altitude: f32 = 0,
    until_corner: f32 = 1,
    last: u64 = 0,
    return_at: u64 = 0,
    return_from: Pose = .{ .eye = .{ 0, 1, 0 }, .target = .{ 0, 1, 1 } },
    roof: f32 = 5,
    destination: [2]f32 = .{ 0, 0 },
    exit: [2]f32 = .{ 0, 0 },
    two_sided: u32 = 0,
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
    pub fn toggle(self: *Flight, camera: *city.Camera, layout: *const city.Layout, now: u64, prefs: @import("../../preferences.zig").Gibson) void {
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
        self.preset(prefs);
        self.speed = self.cruise;
        self.saved.automatic = false; // F completes the cycle in manual mode.
        // Start at a substantial district, then visit every district in layout
        // order. Each visit traverses one lined avenue, never its perimeter.
        var largest: usize = 0;
        for (layout.districts.items, 0..) |d, i| if (d.count > layout.districts.items[largest].count) {
            largest = i;
        };
        self.visits = largest;
        self.route(layout);
        self.eye = .{ self.destination[0], 1.2, self.destination[1] };
        self.destination = self.exit;
        self.leg = 1;
        self.aim();
        self.heading = @as(f32, @floatFromInt(self.direction)) * std.math.pi / 2;
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
    pub fn preset(self: *Flight, prefs: @import("../../preferences.zig").Gibson) void {
        self.film = prefs.film;
        self.cruise = if (prefs.film) prefs.film_speed else prefs.flight_speed;
    }
    const Avenue = struct { a: [2]f32, b: [2]f32, wide: bool = true };
    const Score = struct { rank: u32 = 0, both: u32 = 0 };
    fn score(layout: *const city.Layout, avenue: Avenue) Score {
        const axis: usize = if (avenue.a[0] == avenue.b[0]) 1 else 0;
        const cross = 1 - axis;
        var sides: [2]u32 = .{ 0, 0 };
        for (layout.places.items) |p| {
            const point = [2]f32{ p.x, p.z };
            if (point[axis] < @min(avenue.a[axis], avenue.b[axis]) or point[axis] > @max(avenue.a[axis], avenue.b[axis])) continue;
            const offset = point[cross] - avenue.a[cross];
            if (@abs(offset) > (if (avenue.wide) @as(f32, 1.8) else 0.65)) continue;
            sides[if (offset < 0) @as(usize, 0) else 1] += 1;
        }
        const both = @min(sides[0], sides[1]);
        return .{ .rank = (if (both > 0) @as(u32, 100_000) else 0) + (if (both > 0 and avenue.wide) @as(u32, 100_000) else 0) + both * 8 + sides[0] + sides[1], .both = both };
    }
    fn route(self: *Flight, layout: *const city.Layout) void {
        if (layout.districts.items.len == 0) return;
        const d = layout.districts.items[self.visits % layout.districts.items.len];
        var choices: [6]Avenue = .{
            .{ .a = .{ d.x - 1, d.z - 1 }, .b = .{ d.x - 1, d.z + d.depth + 1 } },
            .{ .a = .{ d.x + d.width + 1, d.z - 1 }, .b = .{ d.x + d.width + 1, d.z + d.depth + 1 } },
            .{ .a = .{ d.x - 1, d.z - 1 }, .b = .{ d.x + d.width + 1, d.z - 1 } },
            .{ .a = .{ d.x - 1, d.z + d.depth + 1 }, .b = .{ d.x + d.width + 1, d.z + d.depth + 1 } },
            .{ .a = .{ d.x + @floor(d.width / 2), d.z }, .b = .{ d.x + @floor(d.width / 2), d.z + d.depth }, .wide = false },
            .{ .a = .{ d.x, d.z + @floor(d.depth / 2) }, .b = .{ d.x + d.width, d.z + @floor(d.depth / 2) }, .wide = false },
        };
        var chosen: usize = 0;
        var best: Score = .{};
        for (&choices, 0..) |*avenue, i| {
            if ((i == 4 and d.width < 2) or (i == 5 and d.depth < 2)) continue;
            var rank = score(layout, avenue.*);
            // The street just flown is usually the next district's nearest
            // lined avenue too. Flying it again means a U-turn past the same
            // walls: any street that can be entered by a turn beats it.
            const ends = self.nearest(avenue.*);
            if (self.behind(ends[0]) or (self.behind(ends[1]) and @abs(self.ahead(ends[0])[1]) < 0.1)) rank.rank = 0;
            if (rank.rank > best.rank) {
                chosen = i;
                best = rank;
            }
        }
        const ends = self.nearest(choices[chosen]);
        self.destination = ends[0];
        self.exit = ends[1];
        self.two_sided = best.both;
    }
    fn away(self: *const Flight, point: [2]f32) f32 {
        return @abs(self.eye[0] - point[0]) + @abs(self.eye[2] - point[1]);
    }
    /// The avenue's ends, nearer one first.
    fn nearest(self: *const Flight, avenue: Avenue) [2][2]f32 {
        return if (self.away(avenue.a) <= self.away(avenue.b)) .{ avenue.a, avenue.b } else .{ avenue.b, avenue.a };
    }
    /// Distance ahead of the camera and across its lane.
    fn ahead(self: *const Flight, point: [2]f32) [2]f32 {
        const dx = point[0] - self.eye[0];
        const dz = point[1] - self.eye[2];
        return switch (self.direction) {
            0 => .{ dz, dx },
            1 => .{ dx, dz },
            2 => .{ -dz, dx },
            3 => .{ -dx, dz },
        };
    }
    /// Straight behind on the lane being flown: only a U-turn reaches it.
    fn behind(self: *const Flight, point: [2]f32) bool {
        const o = self.ahead(point);
        return o[0] < -0.1 and @abs(o[1]) < 0.1;
    }
    fn aim(self: *Flight) void {
        const dx = self.destination[0] - self.eye[0];
        const dz = self.destination[1] - self.eye[2];
        // Finish a straight before taking the cross street; alternating axes
        // at every corner makes a diagonal transfer an unpleasant slalom.
        if (self.ahead(self.destination)[0] > 0.1) return;
        const along_x: u2 = if (dx > 0) 1 else 3;
        const along_z: u2 = if (dz > 0) 0 else 2;
        var want = if (@abs(dx) > @abs(dz)) along_x else along_z;
        // Take the cross street first rather than reversing on the spot.
        if (want == self.direction +% 2 and @min(@abs(dx), @abs(dz)) > 0.1) want = if (want == along_x) along_z else along_x;
        self.direction = want;
    }
    fn corner(self: *Flight, layout: *const city.Layout) void {
        self.corners += 1;
        if (self.automatic) {
            // A new district's entry may be the previous one's exit. Consume
            // that zero-distance waypoint here instead of stepping past it.
            for (0..2) |_| {
                if (@abs(self.eye[0] - self.destination[0]) + @abs(self.eye[2] - self.destination[1]) >= 0.1) break;
                if (self.leg == 0) {
                    self.leg = 1;
                    self.destination = self.exit;
                } else {
                    self.leg = 0;
                    self.visits += 1;
                    self.route(layout);
                }
            }
            self.aim();
        } else {
            if (self.turn != 0) {
                // Screen right of heading h is (-cos h, 0, sin h): a right turn
                // is one step down the direction ring.
                self.direction +%= if (self.turn > 0) @as(u2, 3) else 1;
                self.turn = 0;
            }
            // Manual flight stays inside the perimeter street: at the edge,
            // turn along it toward the larger part of the city.
            const z_axis = self.direction == 0 or self.direction == 2;
            const forward: f32 = if (self.direction < 2) 1 else -1;
            const next = (if (z_axis) self.eye[2] else self.eye[0]) + forward;
            if (next < -1 or next > (if (z_axis) layout.depth else layout.width) + 1) {
                const inward = if (z_axis) layout.width / 2 - self.eye[0] else layout.depth / 2 - self.eye[2];
                self.direction = if (z_axis) (if (inward >= 0) @as(u2, 1) else 3) else (if (inward >= 0) @as(u2, 0) else 2);
            }
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
    flight.toggle(&camera, &layout, 1, .{});
    var twin = flight;
    for (1..1201) |i| {
        const pose = flight.tick(&camera, &layout, i * 16_000_000);
        const other = twin.tick(&camera, &layout, i * 16_000_000);
        try std.testing.expectEqual(pose, other);
        for (layout.places.items) |p| try std.testing.expect(@abs(pose.eye[0] - p.x) >= 0.36 or @abs(pose.eye[2] - p.z) >= 0.36 or pose.eye[1] > p.height);
    }
    try std.testing.expect(flight.corners > 10);
    flight.toggle(&camera, &layout, 20_000_000_000, .{});
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

test "tour prefers two-sided wide avenues and reaches every district at film speed" {
    var layout: city.Layout = .{};
    defer layout.deinit();
    for (0..3) |district| {
        const x: f32 = @floatFromInt(district * 6);
        try layout.districts.append(std.heap.page_allocator, .{ .vma = null, .first = district * 16, .count = 16, .x = x, .z = 0, .width = 4, .depth = 4 });
        for (0..16) |i| try layout.places.append(std.heap.page_allocator, .{ .index = @intCast(district * 16 + i), .address = district * 16 + i, .x = x + @as(f32, @floatFromInt(i % 4)) + 0.5, .z = @as(f32, @floatFromInt(i / 4)) + 0.5, .height = 3 });
    }
    var camera: city.Camera = .{ .automatic = false };
    var flight: Flight = .{};
    flight.toggle(&camera, &layout, 1, .{ .film = true });
    try std.testing.expectEqual(@as(f32, 5), flight.eye[0]);
    try std.testing.expect(flight.two_sided >= 4 and flight.cruise > 3);
    var visited: [3]bool = @splat(false);
    for (1..1801) |i| {
        const pose = flight.tick(&camera, &layout, i * 16_000_000);
        visited[flight.visits % 3] = true;
        try std.testing.expect(flight.two_sided > 0);
        for (layout.places.items) |tower| try std.testing.expect(@abs(pose.eye[0] - tower.x) >= 0.36 or @abs(pose.eye[2] - tower.z) >= 0.36);
    }
    for (visited) |seen| try std.testing.expect(seen);
    flight.preset(.{});
    try std.testing.expectEqual(@as(f32, 1.5), flight.cruise);
}

fn blocks(layout: *city.Layout, columns: usize, rows: usize, side: usize) !void {
    for (0..columns * rows) |district| {
        const x: f32 = @floatFromInt((district % columns) * (side + 2));
        const z: f32 = @floatFromInt((district / columns) * (side + 2));
        try layout.districts.append(std.heap.page_allocator, .{ .vma = null, .first = district * side * side, .count = side * side, .x = x, .z = z, .width = @floatFromInt(side), .depth = @floatFromInt(side) });
        for (0..side * side) |i| try layout.places.append(std.heap.page_allocator, .{ .index = @intCast(district * side * side + i), .address = district * side * side + i, .x = x + @as(f32, @floatFromInt(i % side)) + 0.5, .z = z + @as(f32, @floatFromInt(i / side)) + 0.5, .height = 3 });
        layout.width = @max(layout.width, x + @as(f32, @floatFromInt(side)));
        layout.depth = @max(layout.depth, z + @as(f32, @floatFromInt(side)));
    }
}

test "tour flies beside every district of a grid city, inside the perimeter, without U-turns" {
    var layout: city.Layout = .{};
    defer layout.deinit();
    try blocks(&layout, 3, 4, 2);
    var camera: city.Camera = .{ .automatic = false };
    var flight: Flight = .{};
    flight.toggle(&camera, &layout, 1, .{ .film = true });
    const first = flight.visits;
    var beside: [12]bool = @splat(false);
    var direction = flight.direction;
    var i: u64 = 1;
    while (flight.visits < first + 12) : (i += 1) {
        try std.testing.expect(i < 20_000); // 320 s of flight: the tour must end
        const eye = flight.tick(&camera, &layout, i * 16_000_000).eye;
        try std.testing.expect(eye[0] >= -1 and eye[0] <= layout.width + 1 and eye[2] >= -1 and eye[2] <= layout.depth + 1);
        try std.testing.expect(flight.direction != direction +% 2);
        direction = flight.direction;
        for (layout.places.items) |tower| try std.testing.expect(@abs(eye[0] - tower.x) >= 0.36 or @abs(eye[2] - tower.z) >= 0.36);
        // Count a district only while it is the one being toured, and only
        // from a street or lane touching it: the camera, not the counter.
        const d = layout.districts.items[flight.visits % 12];
        if (eye[0] >= d.x - 1 and eye[0] <= d.x + d.width + 1 and eye[2] >= d.z - 1 and eye[2] <= d.z + d.depth + 1) beside[flight.visits % 12] = true;
    }
    for (beside) |seen| try std.testing.expect(seen);
}

test "manual flight turns along the perimeter street instead of leaving the city" {
    var layout: city.Layout = .{};
    defer layout.deinit();
    try blocks(&layout, 2, 2, 2);
    var camera: city.Camera = .{ .automatic = false };
    var flight: Flight = .{};
    flight.toggle(&camera, &layout, 1, .{ .flight_speed = 5 });
    for (1..4001) |i| {
        // Steer the same way every second: an outward turn must not stick.
        flight.steer(if (i % 60 == 0) 1 else 0, 0);
        const eye = flight.tick(&camera, &layout, i * 16_000_000).eye;
        try std.testing.expect(!flight.automatic or i < 60);
        try std.testing.expect(eye[0] >= -1 and eye[0] <= layout.width + 1 and eye[2] >= -1 and eye[2] <= layout.depth + 1);
    }
    try std.testing.expect(flight.corners > 100);
}
