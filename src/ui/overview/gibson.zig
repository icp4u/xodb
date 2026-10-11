//! The GPU memory city consumes the same bounded page observations as the 2D map.
const std = @import("std");
const c = @import("../../c.zig").api;
const city = @import("city.zig");
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
    layout: city.Layout = .{},
    camera: city.Camera = .{},
    height: city.Height = .resident,
    colour: city.Colour = .backing,
    field: draw.Rect = empty,
    inverse: ?math.Mat4 = null,
    selected: ?u64 = null,
    drag: ?[2]f32 = null,
    last: [2]f32 = .{ 0, 0 },
    moved: bool = false,
    frames: u64 = 0,
    /// Shells are built here: the GPU instance buffer is write-only memory.
    shells: std.ArrayList(Box) = .empty,
    pub fn deinit(self: *State) void {
        self.layout.deinit();
        self.shells.deinit(std.heap.page_allocator);
        self.* = .{};
    }
};

pub fn key(v: *vw.View, sym: u32, shortcut: u32) bool {
    const s = &v.memmap.city;
    const camera = &s.camera;
    switch (sym) {
        0xff1b => {
            if (s.selected == null) return false;
            s.selected = null;
            v.memmap.cursor = null;
            return true;
        },
        0xff52, 0xff54 => {
            camera.automatic = false;
            camera.pitch = std.math.clamp(camera.pitch + @as(f32, if (sym == 0xff52) 0.06 else -0.06), 0.10, 1.45);
            return true;
        },
        0xff51, 0xff53 => {
            camera.automatic = false;
            camera.yaw += @as(f32, if (sym == 0xff51) -0.10 else 0.10);
            return true;
        },
        else => {},
    }
    const span = @max(s.layout.width, s.layout.depth);
    switch (shortcut) {
        'w' => camera.move(1, 0, span),
        's' => camera.move(-1, 0, span),
        'a' => camera.move(0, -1, span),
        'd' => camera.move(0, 1, span),
        'f' => camera.automatic = !camera.automatic,
        'r' => camera.* = .{},
        'h' => s.height = @enumFromInt((@as(usize, @intFromEnum(s.height)) + 1) % 3),
        'c' => s.colour = if (s.colour == .backing) .district else .backing,
        '+', '=' => camera.wheel(-1),
        '-' => camera.wheel(1),
        else => return false,
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
    try ctx.textFit(inner.x, inner.y, inner.w, std.fmt.bufPrint(&buffer, "G I B S O N   /   {s}", .{mm.label(v, &label)}) catch "GIBSON", cyan);
    if (inner.h < 96 or inner.w < 120) return;
    const mp = ms.map();
    try ctx.textFit(inner.x, inner.y + 24, inner.w, "WASD move   drag orbit   wheel zoom   F fly   R reset   H height   C colour   G legend   O process", muted);
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
        s.camera.tick(now);
        const vp = s.camera.matrix(s.layout.width, s.layout.depth, field.w / field.h) orelse return;
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
    const encoding = std.fmt.bufPrint(&buffer, "H height: {s}   C colour: {s}   {s}", .{ height_name, @tagName(s.colour), if (s.camera.automatic) "AUTO ORBIT + DOLLY" else "MANUAL CAMERA" }) catch "";
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
        std.debug.print("xodb: gibson frame={d} seq={d} x={d:.1} y={d:.1} w={d:.1} h={d:.1} towers={d} districts={d} unknown={d} partial={d} pending={d} collapsed={d} split={d} ease={d:.3} auto={} yaw={d:.3} pitch={d:.3} zoom={d:.3} selected={?d} height={s} colour={s} redacted={} labels={d} gpu_ns={?d}\n", .{ s.frames, map.sequence, s.field.x, s.field.y, s.field.w, s.field.h, s.layout.places.items.len, s.layout.districts.items.len, counts.unknown, counts.partial, @intFromBool(map.pending), counts.collapsed, counts.split, ms.ease(now), s.camera.automatic, s.camera.yaw, s.camera.pitch, s.camera.zoom, s.selected, @tagName(s.height), @tagName(s.colour), v.redact or map.redacted, if (ctx.r.scene_gpu) |gpu| gpu.stats.glyphs else @as(u32, 0), if (ctx.r.scene_gpu) |gpu| gpu.stats.gpu_ns else null });
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
    @memcpy(boxes[0..n], s.shells.items);
    // A dim opaque core gives each measured tower depth; its neon shell stays
    // translucent. Without the core, hundreds of additive rear faces merge
    // into one bright slab. Unknown cages never acquire an opaque core.
    for (s.shells.items, boxes[n..]) |shell, *out| {
        var core = shell;
        core.half[0] *= 0.88;
        core.half[2] *= 0.88;
        core.color = .{ shell.color[0] * 0.055, shell.color[1] * 0.055, shell.color[2] * 0.055, if (shell.wire_only > 0) 0 else 1 };
        core.emission = 0;
        out.* = core;
    }
    const points = try scene.points(s.layout.counts.partial);
    var point: usize = 0;
    for (s.layout.places.items) |place| {
        if (!md.classify(map.cells[place.index]).partial) continue;
        points[point] = .{ .position = .{ place.x, place.height + 0.06, place.z }, .pixels = 4, .color = .{ 1, 0.55, 0.10, 1 } };
        point += 1;
    }
    const grid = try scene.lines(66);
    const span = @max(5, @max(s.layout.width, s.layout.depth));
    const center = math.Vec3{ s.layout.width / 2, -0.015, s.layout.depth / 2 };
    for (0..33) |i| {
        const at = (@as(f32, @floatFromInt(i)) / 32 - 0.5) * span * 3;
        grid[i * 2] = .{ .a = math.add(center, .{ at, 0, -span * 1.5 }), .b = math.add(center, .{ at, 0, span * 1.5 }), .color = .{ 0.025, 0.14, 0.22, 0.75 }, .emission = 0.2 };
        grid[i * 2 + 1] = .{ .a = math.add(center, .{ -span * 1.5, 0, at }), .b = math.add(center, .{ span * 1.5, 0, at }), .color = .{ 0.025, 0.14, 0.22, 0.75 }, .emission = 0.2 };
    }
    if (!v.redact and !map.redacted) {
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
