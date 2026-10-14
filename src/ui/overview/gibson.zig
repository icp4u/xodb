//! The GPU memory city consumes the same bounded page observations as the 2D map.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const city = @import("city.zig");
const flight = @import("gibson_flight.zig");
const mm = @import("memmap.zig");
const vw = @import("view.zig");
const draw = @import("draw.zig");
const md = mm.md;
const math = city.math;
const Box = @import("../../render/scene3d/types.zig").Box;
const cyan: draw.Color = .{ 0.25, 0.92, 1, 1 };
const muted: draw.Color = .{ 0.48, 0.63, 0.72, 1 };
const white: draw.Color = .{ 0.9, 0.94, 1, 1 };
const amber: draw.Color = .{ 1, 0.68, 0.28, 1 };
const empty = draw.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub const State = struct {
    look: @import("../../preferences.zig").Gibson = .{},
    layout: city.Layout = .{},
    camera: city.Camera = .{},
    flight: flight.Flight = .{},
    start_flight: bool = false,
    eye: math.Vec3 = .{ 0, 0, 0 },
    face_labels: u32 = 0,
    far_labels: u32 = 0,
    height: city.Height = .resident,
    colour: city.Colour = .backing,
    field: draw.Rect = empty,
    inverse: ?math.Mat4 = null,
    selected: ?u64 = null,
    drag: ?[2]f32 = null,
    last: [2]f32 = .{ 0, 0 },
    moved: bool = false,
    frames: u64 = 0,
    input_revision: u64 = 0,
    /// Shells are built here: the GPU instance buffer is write-only memory.
    shells: std.ArrayList(Box) = .empty,
    pub fn deinit(self: *State) void {
        const look = self.look;
        self.layout.deinit();
        self.shells.deinit(std.heap.page_allocator);
        self.* = .{};
        self.look = look;
    }
};

pub fn heldInput(v: *vw.View, keyboard: *const @import("../../platform/input.zig").Keyboard, enabled: bool, now: u64) bool {
    const s = &v.memmap.city;
    const mods = keyboard.mods();
    if (s.input_revision != keyboard.focus_revision) {
        s.camera.cancelMotion(now);
        s.drag = null;
        s.input_revision = keyboard.focus_revision;
    }
    const active = enabled and keyboard.focused and !mods.ctrl and !mods.alt and !mods.super;
    var held: [5]f32 = @splat(0);
    if (active) {
        const positive = [_]u32{ 'w', 'd', 0xff53, 0xff52, '-' };
        const negative = [_]u32{ 's', 'a', 0xff51, 0xff54, '=' };
        for (&held, positive, negative) |*value, plus, minus| value.* = @as(f32, if (keyboard.heldShortcut(plus)) 1 else 0) - @as(f32, if (keyboard.heldShortcut(minus)) 1 else 0);
        if (keyboard.heldShortcut('+')) held[4] = -1;
    }
    if (s.flight.active()) {
        s.flight.steer(if (held[2] > 0 or held[1] > 0) 1 else if (held[2] < 0 or held[1] < 0) -1 else 0, held[3] + held[0]);
        const changed = s.camera.controls(@splat(0), active, now, @max(s.layout.width, s.layout.depth));
        if (!active) s.flight.altitude = 0;
        return changed;
    }
    const changed = s.camera.controls(held, active, now, @max(s.layout.width, s.layout.depth));
    if (changed and v.layout != null) std.debug.print("xodb: gibson input focused={} now={d} pan_x={d:.6} pan_z={d:.6}\n", .{ active, now, s.camera.pan[0], s.camera.pan[1] });
    return changed;
}

pub fn key(v: *vw.View, event: @import("../../platform/input.zig").Event, now: u64) bool {
    const s = &v.memmap.city;
    const camera = &s.camera;
    switch (event.sym) {
        0xff1b => {
            if (s.selected == null) return false;
            s.selected = null;
            v.memmap.cursor = null;
            return true;
        },
        0xff51...0xff54 => {
            if (s.flight.on and event.kind == .press) s.flight.steer(if (event.sym == 0xff51) -1 else if (event.sym == 0xff53) 1 else 0, 0);
            if (event.kind == .press) camera.automatic = false;
            return true; // Motion comes from authoritative held state.
        },
        else => {},
    }
    switch (event.shortcut) {
        '+', '=', '-' => {
            if (s.flight.on and event.kind == .press) s.flight.faster(if (event.shortcut == '-') -1 else 1);
            if (event.kind == .press) camera.automatic = false;
            return true;
        },
        'w', 's', 'a', 'd' => {
            if (s.flight.on and event.kind == .press) s.flight.steer(if (event.shortcut == 'a') -1 else if (event.shortcut == 'd') 1 else 0, 0);
            if (event.kind == .press) camera.automatic = false;
            return true;
        },
        'f', 'r', 'h', 'c', 'v' => {},
        else => return false,
    }
    if (event.kind != .press) return true;
    switch (event.shortcut) {
        'f' => {
            if (s.flight.active() or camera.automatic) s.flight.toggle(camera, &s.layout, now, s.look) else camera.fly(now);
        },
        'v' => {
            s.look.film = !s.look.film;
            if (s.flight.on) s.flight.preset(s.look);
        },
        'r' => {
            s.flight = .{};
            camera.* = .{ .last = now };
        },
        'h' => s.height = @enumFromInt((@as(usize, @intFromEnum(s.height)) + 1) % 3),
        'c' => s.colour = if (s.colour == .backing) .district else .backing,
        else => unreachable,
    }
    return true;
}
pub fn press(v: *vw.View, x: f32, y: f32) bool {
    const s = &v.memmap.city;
    if (!draw.inside(s.field, x, y) or s.inverse == null) return false;
    s.drag = .{ x, y };
    s.last = .{ x, y };
    s.moved = false;
    return true;
}
pub fn motion(v: *vw.View) void {
    const s = &v.memmap.city;
    const start = s.drag orelse return;
    const p = v.pointer;
    if (@abs(p[0] - start[0]) + @abs(p[1] - start[1]) > 3) s.moved = true;
    if (s.moved) {
        if (s.flight.on) {
            s.flight.steer(if (p[0] > s.last[0]) 1 else if (p[0] < s.last[0]) -1 else 0, 0);
            s.last = p;
            return;
        }
        s.camera.automatic = false;
        s.camera.yaw -= (p[0] - s.last[0]) * 0.005;
        s.camera.pitch = std.math.clamp(s.camera.pitch + (p[1] - s.last[1]) * 0.005, 0.10, 1.45);
    }
    s.last = p;
}
pub fn release(v: *vw.View, x: f32, y: f32) void {
    const s = &v.memmap.city;
    if (s.drag == null) return;
    v.pointer = .{ x, y };
    motion(v);
    s.drag = null;
    if (s.moved or !draw.inside(s.field, x, y)) return;
    const inv = s.inverse orelse return;
    const ray = math.ray(inv, 2 * (x - s.field.x) / s.field.w - 1, 2 * (y - s.field.y) / s.field.h - 1) orelse return;
    s.selected = s.layout.pick(ray);
}
fn selectedIndex(s: *State, map: *const md.Map) ?usize {
    const address = s.selected orelse return null;
    for (map.cells, 0..) |cell, i| if (cell.start == address) return i;
    s.selected = null;
    return null;
}

fn modeName(s: *const State, now: u64) []const u8 {
    if (s.flight.returning) return "RETURNING TO CAMERA";
    if (s.flight.on) return if (s.flight.film) (if (s.flight.automatic) "AUTO FLIGHT / FILM" else "MANUAL FLIGHT / FILM") else if (s.flight.automatic) "AUTO FLIGHT / AVENUES" else "MANUAL FLIGHT / AVENUES";
    return if (s.camera.orbiting(now)) "AUTO ORBIT + DOLLY" else if (s.camera.automatic) "AUTO ORBIT PAUSED" else "MANUAL CAMERA";
}

pub fn render(v: *vw.View, ctx: draw.Ctx, rect: draw.Rect, now: u64) !void {
    const s = &v.memmap.city;
    const ms = &v.memmap;
    s.field = empty;
    s.inverse = null;
    if (rect.w <= 0 or rect.h <= 0) return;
    try ctx.r.rect(rect, .{ 0.001, 0.003, 0.009, 1 });
    const inner = draw.inset(rect, 12);
    var buffer: [512]u8 = undefined;
    var label: [96]u8 = undefined;
    try ctx.textFit(inner.x, inner.y, inner.w, std.fmt.bufPrint(&buffer, "G I B S O N   /   {s}   /   {s}", .{ mm.label(v, &label), modeName(s, now) }) catch "GIBSON", cyan);
    if (inner.h < 96 or inner.w < 120) return;
    const mp = ms.map();
    try ctx.textFit(inner.x, inner.y + 24, inner.w, "F manual/orbit/flight   V film   arrows/drag steer   +/- speed   R reset   H height   C colour   O process", muted);
    if (ms.picker_open) {
        if (v.layout != null) std.debug.print("xodb: gibson picker selected={d} rows={d}\n", .{ ms.pick, ms.pick_count + 1 });
        try ctx.textFit(inner.x, inner.y + 50, inner.w, "Choose process: arrows / Enter / Esc", white);
        const rows: usize = @intFromFloat(@max(0, @floor((inner.h - 80) / 24)));
        const top = if (ms.pick >= rows and rows > 0) ms.pick + 1 - rows else 0;
        for (0..@min(rows, ms.pick_count + 1)) |k| {
            const i = top + k;
            if (i > ms.pick_count) break;
            const r = draw.Rect{ .x = inner.x, .y = inner.y + 78 + @as(f32, @floatFromInt(k)) * 24, .w = inner.w, .h = 22 };
            if (ms.pick == i) try ctx.r.rect(r, .{ 0.03, 0.14, 0.18, 1 });
            try mm.drawPick(v, ctx, r, i, if (ms.pick == i) cyan else muted);
            v.hit(r, .{ .memmap = .{ .pick = i } });
        }
        return;
    }
    const map = mp orelse {
        try ctx.textFit(inner.x, inner.y + 54, inner.w, "Waiting for a page sample. O chooses a process.", amber);
        return;
    };
    if (map.process == null) {
        s.layout.deinit();
        try ctx.textFit(inner.x, inner.y + 54, inner.w, "Choose a process with O. System totals have no virtual-address towers.", amber);
        return;
    }
    const old_identity = s.layout.identity;
    _ = s.layout.ensure(map, ms.accepted_at) catch |err| {
        try ctx.textFit(inner.x, inner.y + 54, inner.w, @errorName(err), amber);
        return;
    };
    if (!std.meta.eql(old_identity, s.layout.identity)) s.selected = null;
    ms.cursor = selectedIndex(s, map);
    const stale = v.action_hook != null and map.sampled_ns != 0 and now -| map.sampled_ns > @max(3_000_000_000, map.refresh_ns *| 3);
    var freshness_buffer: [128]u8 = undefined;
    const freshness = mm.freshness(v, map, now, &freshness_buffer);
    try ctx.textFit(inner.x, inner.y + 48, inner.w, std.fmt.bufPrint(&buffer, "{s}{s}{s}", .{ freshness, if (stale) "   STALE: last page sample" else "", if (map.pending) "   WAITING FOR PAGE SCAN" else "" }) catch freshness, if (stale or map.pending) amber else muted);
    const footer: f32 = if (ms.legend) 124 else 76;
    const field = draw.Rect{ .x = rect.x, .y = inner.y + 106, .w = rect.w, .h = @max(0, inner.h - 106 - footer) };
    if (field.w > 0 and field.h > 0 and ctx.r.device != null) {
        if (s.start_flight and s.layout.districts.items.len > 0) {
            s.flight.toggle(&s.camera, &s.layout, now, s.look);
            s.start_flight = false;
        }
        var vp: math.Mat4 = undefined;
        if (s.flight.active()) {
            const pose = s.flight.tick(&s.camera, &s.layout, now);
            s.eye = pose.eye;
            vp = flight.matrix(pose, @max(s.layout.width, s.layout.depth), field.w / field.h) orelse return;
        } else {
            s.camera.tick(now, @max(s.layout.width, s.layout.depth));
            s.eye = flight.overview(s.camera, s.layout.width, s.layout.depth).eye;
            vp = s.camera.matrix(s.layout.width, s.layout.depth, field.w / field.h) orelse return;
        }
        // An allocation/device failure leaves the ordinary UI and its status usable.
        renderScene(v, ctx, map, field, vp, now) catch |err| {
            try ctx.textFit(inner.x, field.y + 8, inner.w, std.fmt.bufPrint(&buffer, "City unavailable: {s}", .{@errorName(err)}) catch "City unavailable", amber);
        };
    }
    const counts = s.layout.counts;
    var problem_buffer: [192]u8 = undefined;
    const problem = md.processProblem(&problem_buffer, map.process.?);
    const summary = problem orelse (std.fmt.bufPrint(&buffer, "{d} towers / {d} districts   unknown {d}   partial {d}   pending {d}   collapse {d} / split {d}{s}", .{ s.layout.places.items.len, s.layout.districts.items.len, counts.unknown, counts.partial, @intFromBool(map.pending), counts.collapsed, counts.split, if (map.cells_truncated > 0) "   TRUNCATED" else "" }) catch "");
    try ctx.textFit(inner.x, inner.y + 72, inner.w, summary, if (problem != null or map.pending or map.cells_truncated > 0) amber else cyan);
    var y = field.y + field.h + 8;
    const height_name = switch (s.height) {
        .resident => "present MiB (includes zero page)",
        .huge => "THP-backed MiB",
        .swapped => "swapped MiB",
    };
    const encoding = std.fmt.bufPrint(&buffer, "H height: {s}   C colour: {s}   {s}", .{ height_name, @tagName(s.colour), modeName(s, now) }) catch "";
    try ctx.textFit(inner.x, y, inner.w, encoding, white);
    y += 24;
    if (ms.cursor) |index| {
        try ctx.textFit(inner.x, y, inner.w, mm.detail(v, map, index, &buffer), amber);
    } else try ctx.textFit(inner.x, y, inner.w, "Click a tower for block details. Streets separate VMAs; gaps and reserved spans are omitted.", muted);
    y += 24;
    if (ms.legend) {
        try ctx.textFit(inner.x, y, inner.w, "Cyan THP   magenta known 4 KiB   amber file   red swap   purple page size unknown", cyan);
        y += 24;
        try ctx.textFit(inner.x, y, inner.w, "Wire cages = unmeasured; amber dots = partial lower bounds. Flat = measured zero. H cycles byte encoding.", muted);
        y += 24;
    }
    try ctx.textFit(inner.x, y, inner.w, mm.costText(v, &buffer), muted);
    if (v.layout != null or c.getenv("XODB_MEMMAP_PERF") != null) {
        s.frames += 1;
        std.debug.print("xodb: gibson-flight on={} returning={} automatic={} x={d:.6} y={d:.6} z={d:.6} bank={d:.4} speed={d:.3} corners={d} faces={d} far={d}\n", .{ s.flight.on, s.flight.returning, s.flight.automatic, s.eye[0], s.eye[1], s.eye[2], s.flight.bank, s.flight.speed, s.flight.corners, s.face_labels, s.far_labels });
        std.debug.print("xodb: gibson-route visit={d} district={d} two_sided={d} film={} cruise={d:.2} street_names={} facts_alpha={d:.2}\n", .{ s.flight.visits, if (s.layout.districts.items.len > 0) s.flight.visits % s.layout.districts.items.len else 0, s.flight.two_sided, s.flight.film, s.flight.cruise, s.look.street_names, s.look.facts_alpha });
        std.debug.print("xodb: gibson frame={d} seq={d} x={d:.1} y={d:.1} w={d:.1} h={d:.1} towers={d} districts={d} unknown={d} partial={d} pending={d} collapsed={d} split={d} ease={d:.3} auto={} yaw={d:.3} pitch={d:.3} zoom={d:.3} pan_x={d:.6} pan_z={d:.6} now={d} auto_until={d} moving={} focused={} selected={?d} height={s} colour={s} redacted={} labels={d} gpu_ns={?d}\n", .{ s.frames, map.sequence, s.field.x, s.field.y, s.field.w, s.field.h, s.layout.places.items.len, s.layout.districts.items.len, counts.unknown, counts.partial, @intFromBool(map.pending), counts.collapsed, counts.split, ms.ease(now), s.camera.orbiting(now), s.camera.yaw, s.camera.pitch, s.camera.zoom, s.camera.pan[0], s.camera.pan[1], now, s.camera.auto_until, s.camera.animating(now) or (s.camera.active and s.flight.active()), s.camera.active, s.selected, @tagName(s.height), @tagName(s.colour), v.redact or map.redacted, if (ctx.r.scene_gpu) |gpu| gpu.stats.glyphs else @as(u32, 0), if (ctx.r.scene_gpu) |gpu| gpu.stats.gpu_ns else null });
    }
}
fn renderScene(v: *vw.View, ctx: draw.Ctx, map: *const md.Map, field: draw.Rect, vp: math.Mat4, now: u64) !void {
    const s = &v.memmap.city;
    const scene = (try ctx.r.scene(field, vp)) orelse return;
    scene.bloom = 0.40;
    const n = s.layout.places.items.len;
    const boxes = try scene.boxes(n * 2);
    // Never read the mapped instance buffer back: it is write-combined, and
    // at the cell cap that read alone cost tens of milliseconds a frame.
    try s.shells.resize(std.heap.page_allocator, n);
    s.layout.fill(s.shells.items, map, v.memmap.prev(), s.height, s.colour, v.memmap.ease(now), s.selected);
    boxes.copy(0, s.shells.items);
    // A dim opaque core gives each measured tower depth; its neon shell stays
    // translucent. Without the core, hundreds of additive rear faces merge
    // into one bright slab. Unknown cages never acquire an opaque core.
    for (s.shells.items, 0..) |shell, i| {
        var core = shell;
        core.half[0] *= 0.88;
        core.half[2] *= 0.88;
        core.color = .{ shell.color[0] * 0.055, shell.color[1] * 0.055, shell.color[2] * 0.055, if (shell.wire_only > 0) 0 else 1 };
        core.emission = 0;
        boxes.set(n + i, core);
    }
    const points = try scene.points(s.layout.counts.partial + @as(usize, if (s.flight.on) 6 else 0));
    var point: usize = 0;
    for (s.layout.places.items) |place| {
        if (!md.classify(map.cells[place.index]).partial) continue;
        points.set(point, .{ .position = .{ place.x, place.height + 0.06, place.z }, .pixels = 4, .color = .{ 1, 0.55, 0.10, 1 } });
        point += 1;
    }
    if (s.flight.on) {
        const ahead = math.add(s.eye, .{ @sin(s.flight.heading) * 25, -0.4, @cos(s.flight.heading) * 25 });
        for (0..6) |i| points.set(point + i, .{ .position = ahead, .pixels = 100 + @as(f32, @floatFromInt(i)) * 50, .color = .{ 0.03, 0.25, 0.38, 0.025 } });
    }
    const grid = try scene.lines(66);
    const span = @max(5, @max(s.layout.width, s.layout.depth));
    const center = math.Vec3{ s.layout.width / 2, -0.015, s.layout.depth / 2 };
    for (0..33) |i| {
        const at = (@as(f32, @floatFromInt(i)) / 32 - 0.5) * span * 3;
        grid.set(i * 2, .{ .a = math.add(center, .{ at, 0, -span * 1.5 }), .b = math.add(center, .{ at, 0, span * 1.5 }), .color = .{ 0.025, 0.14, 0.22, 0.75 }, .emission = 0.2 });
        grid.set(i * 2 + 1, .{ .a = math.add(center, .{ -span * 1.5, 0, at }), .b = math.add(center, .{ span * 1.5, 0, at }), .color = .{ 0.025, 0.14, 0.22, 0.75 }, .emission = 0.2 });
    }
    try towerText(v, ctx, map);
    if (!v.redact and !map.redacted and !s.flight.active()) {
        // One representative per district class keeps labels legible without
        // projecting or sorting geometry on the CPU. Selection has full detail.
        var chosen: [5]?usize = @splat(null);
        for (s.layout.districts.items, 0..) |district, i| {
            const index = district.vma orelse continue;
            if (index >= map.vmas.len) continue;
            const vma = map.vmas[index];
            const slot: usize = switch (vma.kind) {
                .heap => 0,
                .stack => 1,
                .anon => 2,
                .file => if (vma.path != null and std.mem.indexOf(u8, vma.path.?, ".so") != null) 3 else 4,
                else => continue,
            };
            if (chosen[slot] == null or district.count > s.layout.districts.items[chosen[slot].?].count) chosen[slot] = i;
        }
        const labels = [_][]const u8{ "HEAP", "STACK", "ANONYMOUS", "LIBRARIES", "FILE MAPPINGS" };
        for (chosen, labels) |which, name| {
            const district = s.layout.districts.items[which orelse continue];
            try ctx.r.sceneText(ctx.font, .{ district.x + district.width / 2, 4.2, district.z + district.depth / 2 }, .{ -ctx.measure(name) / 2, 0 }, name, .{ 0.6, 0.86, 1, 0.85 });
        }
    }
    s.field = field;
    s.inverse = math.inverse(vp);
}

fn towerText(v: *vw.View, ctx: draw.Ctx, map: *const md.Map) !void {
    const s = &v.memmap.city;
    s.face_labels = 0;
    s.far_labels = 0;
    if (v.redact or map.redacted) return; // Same rule as the existing city labels.
    const gpu = &ctx.r.scene_gpu.?;
    // Fixed CPU candidates and glyph budget, independent of scene size.
    var near: [24]struct { index: usize, distance: f32 } = undefined;
    var count: usize = 0;
    for (s.layout.places.items, 0..) |place, i| {
        const delta = math.sub(s.eye, .{ place.x, @min(s.eye[1], place.height), place.z });
        const distance = @sqrt(math.dot(delta, delta));
        if (distance >= 9 or place.height < 0.6) {
            s.far_labels += 1;
            continue;
        }
        var at: usize = 0;
        while (at < count and near[at].distance <= distance) at += 1;
        if (at == near.len) continue;
        var end = @min(count, near.len - 1);
        while (end > at) : (end -= 1) near[end] = near[end - 1];
        near[at] = .{ .index = i, .distance = distance };
        count = @min(count + 1, near.len);
    }
    for (near[0..count]) |item| {
        if (gpu.stats.glyphs + 256 > 3072) break;
        const place = s.layout.places.items[item.index];
        const cell = map.cells[place.index];
        const vi = cell.vma orelse continue;
        if (vi >= map.vmas.len) continue;
        const vma = map.vmas[vi];
        const raw = if (vma.path) |path| std.fs.path.basename(path) else @tagName(vma.kind);
        var length = @min(raw.len, 48);
        while (length > 0 and length < raw.len and raw[length] & 0xc0 == 0x80) length -= 1;
        const name = raw[0..length];
        const dx = s.eye[0] - place.x;
        const dz = s.eye[2] - place.z;
        const street = s.flight.on and s.look.street_names;
        const normal: math.Vec3 = if (if (street) (s.flight.direction == 0 or s.flight.direction == 2) else @abs(dx) > @abs(dz)) .{ if (dx >= 0) 1 else -1, 0, 0 } else .{ 0, 0, if (dz >= 0) 1 else -1 };
        const right: math.Vec3 = .{ normal[2], 0, -normal[0] };
        const alpha = std.math.clamp((9 - item.distance) / 4, 0, 1);
        const tint: draw.Color = .{ 0.75, 0.94, 1, alpha };
        const origin = math.add(.{ place.x, 0.24, place.z }, math.scale(normal, 0.367));
        const size = @min(0.015, (place.height - 0.4) / @max(1, ctx.measure(name)));
        try ctx.r.sceneSurfaceText(ctx.font, math.add(origin, math.scale(right, -0.18)), .{ 0, size, 0 }, math.scale(right, size), name, tint);
        var buffer: [96]u8 = undefined;
        const base = std.fmt.bufPrint(&buffer, "{d} KiB", .{(cell.end - cell.start) / 1024}) catch "";
        const small = @min(0.009, 0.62 / @max(1, ctx.measure(base)));
        try ctx.r.sceneSurfaceText(ctx.font, math.add(origin, math.scale(right, -0.31)), math.scale(right, small), .{ 0, -small, 0 }, base, tint);
        if (street or (s.look.facts and item.distance < 5)) {
            const side: math.Vec3 = if (normal[0] != 0) .{ 0, 0, if (dz >= 0) 1 else -1 } else .{ if (dx >= 0) 1 else -1, 0, 0 };
            const tangent: math.Vec3 = .{ side[2], 0, -side[0] };
            const at = math.add(.{ place.x, 0.3, place.z }, math.scale(side, 0.367));
            // Names remain visible head-on at a junction as well as along the
            // street. Facts use the spare narrow strip, with lower contrast.
            if (street) try ctx.r.sceneSurfaceText(ctx.font, math.add(at, math.scale(tangent, -0.18)), .{ 0, size, 0 }, math.scale(tangent, size), name, tint);
            if (!s.look.facts or item.distance >= 5) {
                s.face_labels += 1;
                continue;
            }
            // Only measured facts. Cells carry no dirty count, and an
            // unmeasured resident size draws nothing rather than a "?".
            const facts = (if (cell.known & md.present_bit != 0) std.fmt.bufPrint(&buffer, "{s}  res {d}K", .{ vma.perms, cell.present / 1024 }) else std.fmt.bufPrint(&buffer, "{s}", .{vma.perms})) catch "";
            // A long name on a short tower shrinks to fit; the facts shrink with
            // it so they never read larger than the name.
            const fact_size = @min(@min(0.007, size * 0.6), (place.height - 0.4) / @max(1, ctx.measure(facts)));
            const fact_tint = draw.fade(tint, s.look.facts_alpha);
            try ctx.r.sceneSurfaceText(ctx.font, math.add(at, math.scale(tangent, 0.12)), .{ 0, fact_size, 0 }, math.scale(tangent, fact_size), facts, fact_tint);
            const change = std.fmt.bufPrint(&buffer, "res {d}K / change {d}K", .{ cell.present / 1024, cell.changed / 1024 }) catch "";
            const change_size = @min(@min(0.006, size * 0.5), (place.height - 0.4) / @max(1, ctx.measure(change)));
            if (cell.known & md.present_bit != 0 and cell.change_known != 0) try ctx.r.sceneSurfaceText(ctx.font, math.add(at, math.scale(tangent, 0.26)), .{ 0, change_size, 0 }, math.scale(tangent, change_size), change, fact_tint);
        }
        s.face_labels += 1;
    }
}
