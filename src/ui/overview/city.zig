//! Memory-city layout and camera. These are world coordinates, never projected
//! geometry or a depth sort. The GPU consumes one box instance per sampled cell.
const std = @import("std");
const md = @import("../../memdefrag/model.zig");
pub const math = @import("../../render/scene3d/math.zig");
const Box = @import("../../render/scene3d/types.zig").Box;
const a = std.heap.page_allocator;
pub const Height = enum { resident, huge, swapped };
pub const Colour = enum { backing, district };
pub const Place = struct { index: u32, address: u64, x: f32, z: f32, height: f32 = 0, unknown: bool = true };
pub const District = struct { vma: ?u32, first: usize, count: usize, x: f32, z: f32, width: f32, depth: f32 };
pub const Counts = struct { unknown: usize = 0, partial: usize = 0, collapsed: usize = 0, split: usize = 0, gaps: usize = 0 };
pub const Layout = struct {
    places: std.ArrayList(Place) = .empty,
    districts: std.ArrayList(District) = .empty,
    width: f32 = 1,
    depth: f32 = 1,
    stamp: u64 = 0,
    sequence: u64 = 0,
    identity: ?md.Identity = null,
    counts: Counts = .{},
    pub fn deinit(self: *Layout) void {
        self.places.deinit(a);
        self.districts.deinit(a);
        self.* = .{};
    }
    pub fn ensure(self: *Layout, map: *const md.Map, stamp: u64) !bool {
        const process = map.process orelse {
            self.deinit();
            return false;
        };
        const id = md.Identity{ .pid = process.pid, .start = process.start_ticks };
        if (self.stamp == stamp and self.sequence == map.sequence and std.meta.eql(self.identity, id)) return false;
        if (map.cells.len > md.max_cells) return error.CityCellLimit;
        self.places.clearRetainingCapacity();
        self.districts.clearRetainingCapacity();
        errdefer self.deinit();
        self.width = 1;
        self.depth = 1;
        self.counts = .{};
        var count: usize = 0;
        for (map.cells) |cell| {
            if (visible(cell)) count += 1 else self.counts.gaps += 1;
        }
        try self.places.ensureTotalCapacity(a, count);
        const span: f32 = @max(8, @ceil(@sqrt(@as(f32, @floatFromInt(count))) * 1.3));
        var x: f32 = 0;
        var z: f32 = 0;
        var row_depth: f32 = 0;
        var i: usize = 0;
        while (i < map.cells.len) {
            if (!visible(map.cells[i])) {
                i += 1;
                continue;
            }
            const vma = map.cells[i].vma;
            const start = i;
            while (i < map.cells.len and visible(map.cells[i]) and map.cells[i].vma == vma) i += 1;
            const n = i - start;
            const cols: usize = @max(1, @as(usize, @intFromFloat(@min(span, @ceil(@sqrt(@as(f32, @floatFromInt(n))))))));
            const rows = (n + cols - 1) / cols;
            const width: f32 = @floatFromInt(cols);
            const depth: f32 = @floatFromInt(rows);
            if (x != 0 and x + width > span) {
                x = 0;
                z += row_depth + 2;
                row_depth = 0;
            }
            try self.districts.append(a, .{ .vma = vma, .first = self.places.items.len, .count = n, .x = x, .z = z, .width = width, .depth = depth });
            for (start..i) |index| {
                const k = index - start;
                self.places.appendAssumeCapacity(.{ .index = @intCast(index), .address = map.cells[index].start, .x = x + @as(f32, @floatFromInt(k % cols)) + 0.5, .z = z + @as(f32, @floatFromInt(k / cols)) + 0.5 });
            }
            self.width = @max(self.width, x + width);
            self.depth = @max(self.depth, z + depth);
            x += width + 2;
            row_depth = @max(row_depth, depth);
        }
        self.stamp = stamp;
        self.sequence = map.sequence;
        self.identity = id;
        return true;
    }
    pub fn fill(self: *Layout, boxes: []Box, map: *const md.Map, previous: ?*const md.Map, height: Height, colour: Colour, ease: f32, selected: ?u64) void {
        std.debug.assert(boxes.len == self.places.items.len);
        self.counts.unknown = 0;
        self.counts.partial = 0;
        self.counts.collapsed = 0;
        self.counts.split = 0;
        for (self.places.items, boxes) |*place, *box| {
            const cell = map.cells[place.index];
            const value = bytes(cell, height);
            var h: f32 = if (value) |v| units(v) else 1.2;
            // Never interpolate from unknown, another process, or a replaced VMA.
            if (value != null) {
                if (before(previous, map, cell)) |old| {
                    if (bytes(old, height)) |v| h = units(v) + (h - units(v)) * ease;
                }
            }
            place.height = h;
            place.unknown = value == null;
            const state = md.classify(cell);
            self.counts.unknown += @intFromBool(value == null);
            self.counts.partial += @intFromBool(state.partial);
            self.counts.collapsed += @intFromBool(state.change == .collapsed);
            self.counts.split += @intFromBool(state.change == .split);
            var tint = backing(cell);
            if (colour == .district) {
                const hues = [_][4]f32{ .{ 0.1, 0.8, 1, 0.14 }, .{ 1, 0.12, 0.6, 0.14 }, .{ 1, 0.6, 0.12, 0.14 }, .{ 0.45, 0.3, 1, 0.14 } };
                tint = hues[(cell.vma orelse 0) % hues.len];
            }
            if (value == null) tint = .{ 0.36, 0.65, 0.72, 0.28 };
            const chosen = selected != null and selected.? == cell.start;
            if (chosen) tint = .{ 1, 0.9, 0.45, 0.26 };
            const flash: f32 = if (state.change == .collapsed) (1 - ease) * 4 else 0;
            box.* = .{ .center = .{ place.x, h / 2, place.z }, .half = .{ 0.36, h / 2, 0.36 }, .wire_only = if (value == null) 1 else 0, .color = tint, .emission = 0.4 + flash + @as(f32, if (chosen) 0.8 else 0) };
        }
    }
    pub fn pick(self: *const Layout, ray: math.Ray) ?u64 {
        var nearest: f32 = std.math.inf(f32);
        var found: ?u64 = null;
        for (self.places.items) |place| {
            // Nonresident cells have a flat footprint, still selectable.
            const h = @max(0.015, place.height);
            const distance = ray.box(.{ place.x - 0.36, 0, place.z - 0.36 }, .{ place.x + 0.36, h, place.z + 0.36 }) orelse continue;
            if (distance < nearest) {
                nearest = distance;
                found = place.address;
            }
        }
        return found;
    }
};
fn visible(cell: md.Cell) bool {
    return cell.gap == 0 and (cell.mapped != 0 or !cell.mapping_known);
}
fn units(value: u64) f32 {
    return @as(f32, @floatFromInt(value)) / (2 << 20) * 3;
}
pub fn bytes(cell: md.Cell, height: Height) ?u64 {
    const mask: u64 = switch (height) {
        .resident => md.present_bit,
        .huge => md.huge_bit | md.zero_bit | md.present_bit,
        .swapped => md.swapped_bit,
    };
    if (!cell.mapping_known or cell.observed == 0 or cell.known & mask != mask) return null;
    return switch (height) {
        .resident => cell.present,
        .huge => cell.huge,
        .swapped => cell.swapped,
    };
}
pub fn backing(cell: md.Cell) [4]f32 {
    return switch (md.classify(cell).state) {
        .thp, .mixed => .{ 0.05, 0.9, 1, 0.14 },
        .file => .{ 1, 0.5, 0.06, 0.14 },
        .swapped => .{ 0.7, 0.025, 0.05, 0.16 },
        .unknown => .{ 0.36, 0.65, 0.72, 0.28 },
        .anon => if (cell.known & md.huge_bit != 0) .{ 1, 0.06, 0.58, 0.14 } else .{ 0.6, 0.38, 0.85, 0.14 },
        else => .{ 0.25, 0.35, 0.5, 0.12 },
    };
}
fn before(previous: ?*const md.Map, map: *const md.Map, cell: md.Cell) ?md.Cell {
    const old = previous orelse return null;
    const p = map.process orelse return null;
    const q = old.process orelse return null;
    if (p.pid != q.pid or p.start_ticks != q.start_ticks or map.cell_bytes != old.cell_bytes) return null;
    var lo: usize = 0;
    var hi = old.cells.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (old.cells[mid].start < cell.start) lo = mid + 1 else hi = mid;
    }
    if (lo == old.cells.len) return null;
    const c = old.cells[lo];
    if (c.start != cell.start or c.end != cell.end or c.vma == null or cell.vma == null) return null;
    if (c.vma.? >= old.vmas.len or cell.vma.? >= map.vmas.len) return null;
    const a_vma = old.vmas[c.vma.?];
    const b_vma = map.vmas[cell.vma.?];
    if (a_vma.start != b_vma.start or a_vma.end != b_vma.end or a_vma.kind != b_vma.kind or !std.mem.eql(u8, a_vma.perms, b_vma.perms)) return null;
    if ((a_vma.path == null) != (b_vma.path == null)) return null;
    if (a_vma.path) |path| if (!std.mem.eql(u8, path, b_vma.path.?)) return null;
    return c;
}

pub const Camera = struct {
    // User preference; an expired idle deadline pauses it without disabling it.
    automatic: bool = true,
    yaw: f32 = 0.7,
    pitch: f32 = 0.58,
    zoom: f32 = 1,
    pan: [2]f32 = .{ 0, 0 },
    elapsed: f32 = 0,
    dolly: f32 = 1,
    last: u64 = 0,
    auto_until: u64 = 0,
    active: bool = true,
    // Forward, right, yaw, pitch and logarithmic zoom, in units per second.
    held: [5]f32 = @splat(0),
    velocity: [5]f32 = @splat(0),
    pub const idle_ns = 5 * std.time.ns_per_s;

    pub fn orbiting(self: *const Camera, now: u64) bool {
        return self.active and self.automatic and (self.auto_until == 0 or now < self.auto_until);
    }
    pub fn interact(self: *Camera, now: u64) void {
        if (self.active and self.automatic) self.auto_until = now +| idle_ns;
    }
    pub fn animating(self: *const Camera, now: u64) bool {
        if (!self.active) return false;
        if (self.orbiting(now)) return true;
        for (self.held, self.velocity) |held, velocity| if (held != 0 or velocity != 0) return true;
        return false;
    }
    pub fn cancelMotion(self: *Camera, now: u64) void {
        self.held = @splat(0);
        self.velocity = @splat(0);
        self.last = now;
    }
    pub fn controls(self: *Camera, held: [5]f32, active: bool, now: u64, span: f32) bool {
        if (!active) {
            const changed = self.active;
            self.cancelMotion(now);
            self.active = false;
            return changed;
        }
        if (self.active and std.meta.eql(held, self.held)) return false;
        if (self.active) self.tick(now, span) else self.last = now;
        const regained = !self.active;
        self.active = true;
        if (regained) self.interact(now);
        self.held = held;
        for (held) |value| if (value != 0) {
            self.automatic = false;
            break;
        };
        return true;
    }
    pub fn fly(self: *Camera, now: u64) void {
        self.cancelMotion(now);
        self.automatic = !self.automatic or (self.auto_until != 0 and now >= self.auto_until);
        self.auto_until = now +| idle_ns;
    }
    pub fn tick(self: *Camera, now: u64, span: f32) void {
        const dt = @as(f32, @floatFromInt(@min(now -| self.last, 100_000_000))) / 1e9;
        const first = self.last == 0;
        self.last = now;
        if (!self.active) return;
        if (self.automatic) {
            if (self.auto_until == 0) self.auto_until = now +| idle_ns;
            if (now < self.auto_until and !first) {
                self.elapsed += dt;
                self.yaw += dt * 0.045;
                self.dolly = 1 + @sin(self.elapsed * 0.17) * 0.12;
            }
        }
        if (first or dt == 0) return;
        // Integrate exponential easing analytically, so changing frame or key
        // repeat rate does not change distance over the same held interval.
        const tau: f32 = 0.04;
        const decay = @exp(-dt / tau);
        var distance: [5]f32 = undefined;
        for (&self.velocity, self.held, &distance) |*velocity, target, *step| {
            step.* = target * dt + (velocity.* - target) * tau * (1 - decay);
            velocity.* = target + (velocity.* - target) * decay;
            if (target == 0 and @abs(velocity.*) < 0.001) velocity.* = 0;
        }
        const speed = @max(6, span * 0.24) * self.zoom;
        self.pan[0] += (-@sin(self.yaw) * distance[0] + @cos(self.yaw) * distance[1]) * speed;
        self.pan[1] += (-@cos(self.yaw) * distance[0] - @sin(self.yaw) * distance[1]) * speed;
        self.pan[0] = std.math.clamp(self.pan[0], -span * 3, span * 3);
        self.pan[1] = std.math.clamp(self.pan[1], -span * 3, span * 3);
        self.yaw += distance[2] * 1.5;
        self.pitch = std.math.clamp(self.pitch + distance[3], 0.10, 1.45);
        self.zoom = std.math.clamp(self.zoom * @exp(distance[4] * 1.2), 0.10, 4);
    }
    pub fn matrix(self: *const Camera, width: f32, depth: f32, aspect: f32) ?math.Mat4 {
        const span = @max(5, @max(width, depth));
        const distance = span * self.zoom * self.dolly;
        const target: math.Vec3 = .{ width / 2 + self.pan[0], 0.6, depth / 2 + self.pan[1] };
        const eye = math.add(target, .{ @sin(self.yaw) * @cos(self.pitch) * distance, @sin(self.pitch) * distance, @cos(self.yaw) * @cos(self.pitch) * distance });
        return math.mul((math.perspective(0.95, aspect, 0.05, span * 20 + 100) orelse return null), math.lookAt(eye, target, .{ 0, 1, 0 }) orelse return null);
    }
    pub fn move(self: *Camera, forward: f32, right: f32, span: f32) void {
        self.automatic = false;
        const step = @max(0.3, span * 0.012) * self.zoom;
        self.pan[0] += (-@sin(self.yaw) * forward + @cos(self.yaw) * right) * step;
        self.pan[1] += (-@cos(self.yaw) * forward - @sin(self.yaw) * right) * step;
        self.pan[0] = std.math.clamp(self.pan[0], -span * 3, span * 3);
        self.pan[1] = std.math.clamp(self.pan[1], -span * 3, span * 3);
    }
    pub fn wheel(self: *Camera, lines: i32) void {
        self.automatic = false;
        self.zoom = std.math.clamp(self.zoom * @exp(@as(f32, @floatFromInt(std.math.clamp(lines, -20, 20))) * 0.10), 0.10, 4);
    }
};

test "city preserves unknown, zero, partial and PMD evidence; never blends process identities" {
    const t = std.testing;
    const B = 2 << 20;
    const known = md.present_bit | md.huge_bit | md.zero_bit | md.swapped_bit | md.file_bit;
    var cells = [_]md.Cell{
        .{ .start = B, .end = 2 * B, .vma = 0, .mapped = B, .observed = B, .present = B, .huge = B, .known = known, .pmd_known = true, .collapsed = B },
        .{ .start = 2 * B, .end = 3 * B, .vma = 0, .mapped = B },
        .{ .start = 3 * B, .end = 4 * B, .vma = 0, .mapped = B, .observed = B, .known = known },
        .{ .start = 4 * B, .end = 5 * B, .vma = 1, .mapped = B, .observed = B / 2, .present = B / 2, .known = known },
        .{ .start = 5 * B, .end = 6 * B, .vma = 1, .mapped = B, .observed = B, .present = B, .zero = B, .known = known },
        .{ .start = 6 * B, .end = 9 * B, .gap = 3 * B },
    };
    const vmas = [_]md.Vma{ .{ .start = B, .end = 4 * B, .kind = .heap }, .{ .start = 4 * B, .end = 6 * B, .kind = .file, .path = "fixture.so" } };
    var map = md.Map{ .process = .{ .pid = 42, .start_ticks = 1 }, .cells = &cells, .vmas = &vmas, .sequence = 1 };
    var prior_cells = cells;
    prior_cells[0].present = 0;
    prior_cells[0].huge = 0;
    var prior = map;
    prior.cells = &prior_cells;
    var layout = Layout{};
    defer layout.deinit();
    try t.expect(try layout.ensure(&map, 1));
    try t.expectEqual(@as(usize, 5), layout.places.items.len);
    try t.expectEqual(@as(usize, 2), layout.districts.items.len);
    try t.expectEqual(@as(usize, 1), layout.counts.gaps);
    const left = layout.districts.items[0];
    const right = layout.districts.items[1];
    try t.expect(right.x >= left.x + left.width + 2 or right.z >= left.z + left.depth + 2);
    var boxes: [5]Box = undefined;
    layout.fill(&boxes, &map, &prior, .resident, .backing, 0.5, null);
    try t.expectApproxEqAbs(@as(f32, 1.5), boxes[0].half[1] * 2, 0.0001);
    try t.expect(boxes[0].emission > 1);
    try t.expectEqual(@as(f32, 1), boxes[1].wire_only);
    try t.expectEqual(@as(f32, 0), boxes[2].half[1]);
    try t.expectEqual(@as(usize, 1), layout.counts.unknown);
    try t.expectEqual(@as(usize, 1), layout.counts.partial);
    try t.expectEqual(@as(usize, 1), layout.counts.collapsed);
    try t.expectEqual(@as(?u64, B), bytes(cells[4], .resident));
    try t.expectEqual(@as(?u64, 0), bytes(cells[4], .huge));
    prior.process.?.start_ticks = 2;
    layout.fill(&boxes, &map, &prior, .resident, .backing, 0, null);
    try t.expectEqual(@as(f32, 3), boxes[0].half[1] * 2);
    cells[0].pmd_known = false;
    layout.fill(&boxes, &map, null, .resident, .backing, 0, null);
    try t.expectEqual(@as(usize, 0), layout.counts.collapsed);
    try t.expectApproxEqAbs(@as(f32, 0.4), boxes[0].emission, 0.0001);
    const target = layout.places.items[2];
    try t.expectEqual(@as(?u64, target.address), layout.pick(.{ .origin = .{ target.x, 10, target.z }, .direction = .{ 0, -1, 0 } }));
    try t.expectEqual(@as(?u64, null), layout.pick(.{ .origin = .{ -10, 10, -10 }, .direction = .{ 0, -1, 0 } }));
    try t.expect(!try layout.ensure(&map, 1));
    layout.deinit();
    try t.expectEqual(@as(usize, 0), layout.places.capacity);
    try t.expectEqual(@as(usize, 0), layout.districts.capacity);
}

test "city camera rejects empty aspect, bounds dolly and pan, and pauses flythrough" {
    const t = std.testing;
    var camera = Camera{};
    try t.expect(camera.matrix(10, 10, 0) == null);
    try t.expect(math.inverse(camera.matrix(10, 10, 16.0 / 9.0).?) != null);
    camera.tick(1, 10);
    camera.tick(1_000_000_001, 10);
    try t.expect(camera.yaw > 0.7 and camera.yaw < 0.71);
    camera.wheel(-1000);
    for (0..100) |_| camera.wheel(-1000);
    try t.expectEqual(@as(f32, 0.1), camera.zoom);
    const yaw = camera.yaw;
    camera.tick(2_000_000_001, 10);
    try t.expectEqual(yaw, camera.yaw);
    for (0..10000) |_| camera.move(1, 1, 10);
    try t.expect(@abs(camera.pan[0]) <= 30 and @abs(camera.pan[1]) <= 30);
}

test "held camera distance follows elapsed time across frame rates and settles without redraw" {
    const t = std.testing;
    var fine = Camera{ .automatic = false };
    var coarse = fine;
    const held: [5]f32 = .{ 1, 1, 0, 0, 0 };
    _ = fine.controls(held, true, 1, 10);
    _ = coarse.controls(held, true, 1, 10);
    for (1..101) |i| fine.tick(1 + i * 10_000_000, 10);
    for (1..21) |i| coarse.tick(1 + i * 50_000_000, 10);
    for (fine.pan, coarse.pan) |left, right| try t.expectApproxEqAbs(left, right, 0.00001);
    const expected = 6 * (1 - 0.04 * (1 - @exp(@as(f32, -25))));
    const distance = @sqrt(fine.pan[0] * fine.pan[0] + fine.pan[1] * fine.pan[1]);
    const wrong = std.c.getenv("XODB_TEST_WRONG_CAMERA") != null;
    try t.expectApproxEqAbs(expected * @sqrt(@as(f32, if (wrong) 1 else 2)), distance, 0.00001);
    _ = fine.controls(@splat(0), true, 1_000_000_001, 10);
    try t.expect(fine.animating(1_000_000_001));
    for (1..21) |i| fine.tick(1_000_000_001 + i * 20_000_000, 10);
    try t.expect(!fine.animating(1_400_000_001));
    const stopped = fine.pan;
    fine.tick(2_000_000_001, 10);
    try t.expectEqual(stopped, fine.pan);
}

test "camera focus loss cancels immediately and idle flythrough preserves its last pose" {
    const t = std.testing;
    var camera = Camera{};
    _ = camera.controls(.{ 1, 0, 1, 1, -1 }, true, 1, 10);
    camera.tick(50_000_001, 10);
    _ = camera.controls(@splat(0), false, 50_000_001, 10);
    const stopped = camera;
    camera.tick(1_000_000_001, 10);
    try t.expectEqual(stopped.pan, camera.pan);
    try t.expectEqual(stopped.yaw, camera.yaw);
    try t.expectEqual(stopped.pitch, camera.pitch);
    try t.expectEqual(stopped.zoom, camera.zoom);
    try t.expect(!camera.animating(1_000_000_001));
    _ = camera.controls(@splat(0), true, 1_000_000_001, 10);
    camera.fly(1_000_000_001);
    camera.tick(1_050_000_001, 10);
    const matrix = camera.matrix(10, 10, 1).?;
    camera.tick(1_000_000_001 + Camera.idle_ns, 10);
    try t.expect(!camera.animating(1_000_000_001 + Camera.idle_ns));
    try t.expectEqual(matrix, camera.matrix(10, 10, 1).?);
    // An idle deadline can precede the next repaint. F still restarts orbit.
    camera.automatic = true;
    camera.fly(camera.auto_until + 1);
    try t.expect(camera.automatic);
}

test "orbit idle deadline follows interaction without overriding manual control" {
    const t = std.testing;
    const start = 1;
    var camera = Camera{};
    camera.tick(start, 10);
    const original = camera.auto_until;
    camera.interact(start + Camera.idle_ns / 2);
    const renewed = camera.auto_until;
    const wrong = std.c.getenv("XODB_TEST_WRONG_CAMERA_IDLE") != null;
    try t.expectEqual(if (wrong) original else start + Camera.idle_ns / 2 + Camera.idle_ns, renewed);
    camera.tick(original, 10);
    try t.expect(camera.orbiting(original));
    const pose = camera.matrix(10, 10, 1).?;
    camera.tick(renewed, 10);
    try t.expect(!camera.animating(renewed));
    try t.expectEqual(pose, camera.matrix(10, 10, 1).?);
    // Ordinary repaints and unchanged held state do not renew the deadline.
    _ = camera.controls(@splat(0), true, renewed + 1, 10);
    camera.tick(renewed + Camera.idle_ns, 10);
    try t.expectEqual(renewed, camera.auto_until);
    camera.interact(renewed + Camera.idle_ns);
    try t.expect(camera.orbiting(renewed + Camera.idle_ns));
    _ = camera.controls(@splat(0), false, renewed + Camera.idle_ns + 1, 10);
    const paused_deadline = camera.auto_until;
    camera.interact(paused_deadline + 1);
    try t.expectEqual(paused_deadline, camera.auto_until);
    _ = camera.controls(@splat(0), true, paused_deadline + 1, 10);
    try t.expect(camera.orbiting(paused_deadline + 1));
    camera.fly(paused_deadline + 2); // Explicitly switch off active orbit.
    camera.interact(paused_deadline + 3);
    try t.expect(!camera.automatic and !camera.animating(paused_deadline + 3));
    camera.fly(paused_deadline + 4);
    camera.wheel(1);
    camera.interact(paused_deadline + 5);
    try t.expect(!camera.automatic);
    camera.fly(paused_deadline + 6);
    _ = camera.controls(.{ 1, 0, 0, 0, 0 }, true, paused_deadline + 7, 10);
    camera.interact(paused_deadline + 8);
    try t.expect(!camera.automatic);
}
