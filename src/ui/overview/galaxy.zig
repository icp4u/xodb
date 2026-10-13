//! Source-neutral galaxy presentation: layout, cloud, edges and activity.
//! Domain adapters own captions, hover text and selection routing.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const draw = @import("draw.zig");
const rgb = @import("../../appearance.zig").rgb;
const Palette = @import("theme.zig").Palette;
const Color = draw.Color;
const Cell = @import("../../render/vulkan.zig").Cell;

const model = @import("galaxy_model.zig");
pub const Scene = model.Scene;
pub const max_stars = model.max_stars;
pub const max_particles = model.max_particles;
pub const max_junctions = model.max_junctions;
pub const max_clusters = model.max_clusters;
pub const max_strands = model.max_strands;
pub const drawn_strands = model.drawn_strands;
pub const drawn_impulses = model.drawn_impulses;
pub const cloud_points = model.cloud_points;
pub const mesh_segments = model.mesh_segments;
pub const bead_cells = model.bead_cells;
pub const max_labels = model.max_labels;
pub const group_motes = model.group_motes;
pub const linger_ns = model.linger_ns;
pub const none = model.none;
pub const golden = model.golden;
pub const mix = model.mix;
pub const unit = model.unit;
pub const hash = model.hash;
pub const Rng = model.Rng;
pub const size = model.size;
pub const energy = model.energy;
pub const rateText = model.rateText;
pub const Counts = model.Counts;
// --- Drawing --------------------------------------------------------------------

pub const Look = struct { plain: bool, field: Color, text: Color, dim: Color, warn: Color, hot: Color, thread: Color, hues: [8]Color, hue_count: usize };
pub fn look(p: *const Palette) Look {
    if (p.win95) return .{ .plain = true, .field = p.panel, .text = p.text, .dim = p.dim, .warn = p.warn, .hot = p.crit, .thread = p.dim, .hues = @splat(p.accent), .hue_count = 1 };
    const pink = rgb(0xff4f8b);
    if (std.mem.eql(u8, p.name, "dark") or std.mem.eql(u8, p.name, "light"))
        return .{ .plain = false, .field = rgb(0x04060a), .text = rgb(0xe6ebf2), .dim = rgb(0x8291a6), .warn = rgb(0xf5c45e), .hot = pink, .thread = rgb(0xdfe6f0), .hues = .{ rgb(0x5fe3c0), rgb(0xffc94d), rgb(0xb79cff), rgb(0x6ab8ff), rgb(0xd8dde6), rgb(0xff8f6b), rgb(0xa6e36a), rgb(0x59d0e8) }, .hue_count = 8 };
    return .{ .plain = false, .field = draw.mix(p.background, .{ 0, 0, 0, 1 }, 0.5), .text = p.text, .dim = p.dim, .warn = p.warn, .hot = if (p.monochrome) p.crit else pink, .thread = p.text, .hues = .{ p.accent, p.accent2, p.accent3, p.ok, p.warn, p.text, p.accent, p.accent2 }, .hue_count = 6 };
}
fn disc(ctx: draw.Ctx, at: [2]f32, radius: f32, color: Color) !void {
    try ctx.r.shape(.{ .x = at[0] - radius, .y = at[1] - radius, .w = radius * 2, .h = radius * 2 }, color, .{ .radii = @splat(radius) });
}
/// A soft-edged glow: full color at the centre, clear at `radius`.
fn glow(ctx: draw.Ctx, at: [2]f32, radius: f32, color: Color) !void {
    try ctx.r.shape(.{ .x = at[0] - radius, .y = at[1] - radius, .w = radius * 2, .h = radius * 2 }, color, .{ .radii = @splat(radius), .softness = radius });
}
fn bezier(a: [2]f32, m: [2]f32, b: [2]f32, t: f32) [2]f32 {
    const u = 1 - t;
    return .{ u * u * a[0] + 2 * u * t * m[0] + t * t * b[0], u * u * a[1] + 2 * u * t * m[1] + t * t * b[1] };
}
/// Each thread bows by its own amount, so a bundle between two stars fans into a web.
fn control(a: [2]f32, b: [2]f32, seed: u32, junction: bool) [2]f32 {
    const bend = (unit(mix(seed)) - 0.5) * @as(f32, if (junction) 0.3 else 0.62);
    const bow = if (@abs(bend) < 0.06) @as(f32, if (bend < 0) -0.06 else 0.06) else bend;
    return .{ (a[0] + b[0]) / 2 - (b[1] - a[1]) * bow, (a[1] + b[1]) / 2 + (b[0] - a[0]) * bow };
}

/// An irregular outline, so a cloud is not a disc.
fn lobed(seed: u64, angle: f32) f32 {
    return 0.74 + 0.2 * @sin(3 * angle + unit(seed) * std.math.tau) + 0.12 * @sin(5 * angle + unit(seed >> 20) * std.math.tau);
}
/// Points too many for six vertices each: gathered, then drawn as one instanced batch.
const Dust = struct {
    items: []Cell,
    count: usize = 0,
    fn put(self: *Dust, x: f32, y: f32, extent: f32, color: Color) void {
        if (self.count == self.items.len or color[3] <= 0.01) return;
        var fill: [4]u8 = undefined;
        for (&fill, color) |*out, channel| out.* = @intFromFloat(std.math.clamp(channel, 0, 1) * 255);
        self.items[self.count] = .{ .rect = .{ @round(x - extent / 2), @round(y - extent / 2), extent, extent }, .fill = fill, .accent = fill, .overlay = fill, .kind = 0 };
        self.count += 1;
    }
    fn flush(self: *Dust, ctx: draw.Ctx, additive: bool) void {
        defer self.count = 0;
        const out = (if (additive) ctx.r.glowingCells(self.count) else ctx.r.cells(self.count)) catch return;
        @memcpy(out, self.items[0..self.count]);
    }
};
var cloud_cells: [cloud_points]Cell = undefined;
var bead_store: [bead_cells]Cell = undefined;
const web_side = 44;
var web: [web_side * web_side][2]f32 = undefined;
var web_on: [web_side * web_side]bool = undefined;

const Placed = struct {
    boxes: [max_labels + 8]draw.Rect = undefined,
    count: usize = 0,
    field: draw.Rect,
    fn free(self: *const Placed, box: draw.Rect) bool {
        if (box.x < self.field.x + 4 or box.y < self.field.y + 4 or box.x + box.w > self.field.x + self.field.w - 4 or box.y + box.h > self.field.y + self.field.h - 4) return false;
        for (self.boxes[0..self.count]) |other| {
            const overlap = draw.intersect(.{ .x = box.x - 14, .y = box.y - 4, .w = box.w + 28, .h = box.h + 8 }, other);
            if (overlap.w > 0 and overlap.h > 0) return false;
        }
        return true;
    }
    fn add(self: *Placed, box: draw.Rect) void {
        if (self.count == self.boxes.len) return;
        self.boxes[self.count] = box;
        self.count += 1;
    }
};
/// A bold name with a dim caption under it, at the first free spot around `at`.
fn label(ctx: draw.Ctx, placed: *Placed, lk: Look, at: [2]f32, clear: f32, name: []const u8, caption: []const u8, name_color: Color, caption_color: Color) !bool {
    if (placed.count == placed.boxes.len or name.len == 0) return false;
    const w = @min(420, @max(ctx.measure(name) + 1, ctx.measure(caption)));
    const h: f32 = if (caption.len > 0) 40 else 20;
    const spots = [_][2]f32{ .{ at[0] + clear + 10, at[1] - 11 }, .{ at[0] - clear - 10 - w, at[1] - 11 }, .{ at[0] - w / 2, at[1] + clear + 6 }, .{ at[0] - w / 2, at[1] - clear - 6 - h }, .{ at[0] + clear + 10, at[1] + clear }, .{ at[0] + clear + 10, at[1] - clear - h } };
    for (spots) |spot| {
        const box = draw.Rect{ .x = @round(spot[0]), .y = @round(spot[1]), .w = w, .h = h };
        if (!placed.free(box)) continue;
        placed.add(box);
        if (lk.plain) try ctx.r.rect(.{ .x = box.x - 3, .y = box.y + 1, .w = w + 6, .h = h }, ctx.p.panel) else try ctx.r.shape(.{ .x = box.x - 10, .y = box.y - 6, .w = w + 20, .h = h + 12 }, draw.fade(lk.field, 0.62), .{ .radii = @splat(10), .softness = 8 });
        try ctx.textFit(box.x, box.y, w, name, name_color);
        // A second strike one pixel over reads as bold in the one face we have.
        if (!lk.plain) try ctx.r.textFit(ctx.font, box.x + 1, box.y, w, name, name_color);
        if (caption.len > 0) try ctx.textFit(box.x, box.y + 19, w, caption, caption_color);
        return true;
    }
    return false;
}

pub const State = struct {
    cloud_slot: @import("../../render/vulkan.zig").CloudSlot = 0,
    scene: Scene = .{},
    motion: @import("galaxy_motion.zig").Motion = .{},
    cached_mesh: u32 = 0,
    cloud_builds: u64 = 0,
    thread_hover: ?struct { seed: u32, a: u16, b: u16 } = null,
};

/// Draws the galaxy into `field`; `reserved` are text rows labels must avoid.
pub fn renderModel(v: anytype, state: *State, ctx: draw.Ctx, field: draw.Rect, body: draw.Rect, reserved: []const draw.Rect, selected: ?u64, now: u64) !Counts {
    const s = &state.scene;
    const motion = &state.motion;
    const lk = look(ctx.p);
    const st = v.graph;
    const clock = st.clock;
    s.layout(body);
    const easing = motion.layout(s, body, clock, st.look);
    const pointer_changed = !std.meta.eql(v.pointer, motion.pointer);
    const previous_view = motion.transform();
    motion.camera(s, body, v.pointer, selected, easing, st.look);
    s.settle(clock);
    var counts = Counts{ .stars = s.star_count, .clusters = s.cluster_count, .strands = s.strand_count };
    const audit = c.getenv("XODB_OVERVIEW_AUDIT") != null;

    if (!lk.plain) {
        var cloud_hash = std.hash.Wyhash.init(s.signature);
        cloud_hash.update(std.mem.asBytes(&lk.hues));
        cloud_hash.update(std.mem.asBytes(&st.look.cloud_size));
        cloud_hash.update(std.mem.asBytes(&st.look.brightness));
        const focus = motion.focus orelse 0;
        cloud_hash.update(std.mem.asBytes(&focus));
        for (s.stars[0..s.star_count]) |star| {
            cloud_hash.update(std.mem.asBytes(&star.at));
            cloud_hash.update(std.mem.asBytes(&star.r));
            const flags = [2]u8{ @intFromBool(star.stale), @intFromBool(star.unavailable) };
            cloud_hash.update(&flags);
        }
        for (s.clusters[0..s.cluster_count]) |cl| {
            cloud_hash.update(std.mem.asBytes(&cl.at));
            cloud_hash.update(std.mem.asBytes(&cl.r));
        }
        const signature = cloud_hash.final() | 1;
        // The old cloud remains a backdrop through the short layout transition.
        // Only the settled geometry is uploaded, not every intermediate frame.
        if (ctx.r.clouds[state.cloud_slot].signature != signature and (!motion.layout_active or ctx.r.clouds[state.cloud_slot].signature == 0)) {
            const first_vertex = ctx.r.vertices;
            const saved_clip = ctx.r.clip;
            // Retain the full world-space cloud, including geometry outside today's
            // viewport. Camera moves reveal it without regenerating/clipping it.
            ctx.r.clip = .{ .x = -10000, .y = -10000, .w = 20000, .h = 20000 };
            defer ctx.r.clip = saved_clip;
            // Nebulae: a soft haze per cluster, a scatter of faint points denser toward
            // each centre, and fibres of points joined by hair-thin segments.
            var dust = Dust{ .items = &cloud_cells };
            var total: f32 = 0;
            for (s.clusters[0..s.cluster_count]) |cl| total += cl.weight;
            total = @max(1, total);
            for (s.clusters[0..s.cluster_count]) |cl| {
                const dim: f32 = if (motion.focus != null and motion.focus.? != cl.key) 0.4 else 1;
                const hue = draw.fade(lk.hues[cl.key % lk.hue_count], dim * st.look.brightness);
                try glow(ctx, cl.at, cl.r * 1.7 * st.look.cloud_size, draw.fade(hue, 0.08));
                try glow(ctx, cl.at, cl.r * 0.9 * st.look.cloud_size, draw.fade(hue, 0.05));
                var rng = Rng{ .state = mix(cl.key ^ 0x636c) };
                var points: u32 = @intFromFloat(cl.weight / total * cloud_points * 0.3);
                while (points > 0) : (points -= 1) {
                    const angle = rng.next() * std.math.tau;
                    const u = rng.next();
                    const far = cl.r * 1.45 * st.look.cloud_size * lobed(cl.key, angle) * std.math.pow(f32, u, 0.8);
                    const bright = rng.next();
                    dust.put(cl.at[0] + @cos(angle) * far, cl.at[1] + @sin(angle) * far, 1, draw.fade(hue, 0.16 + 0.5 * (1 - u) * bright));
                }
            }
            var motes: u32 = 0;
            for (s.stars[0..s.star_count]) |*star| {
                const share = size(star) * size(star) / total;
                const hue = lk.hues[s.clusters[star.cluster].key % lk.hue_count];
                const pale = draw.mix(hue, lk.text, 0.55);
                const dimmed: f32 = @as(f32, if (star.stale or star.unavailable) 0.55 else 1) * st.look.brightness * @as(f32, if (motion.focus != null and motion.focus.? != s.clusters[star.cluster].key) 0.4 else 1);
                var rng = Rng{ .state = star.seed };
                var segments: u32 = if (ctx.r.used() > 0.4) 0 else @intFromFloat(share * mesh_segments);
                var points: u32 = @min(3000, @as(u32, @intFromFloat(share * cloud_points * 0.45)));
                // A large star gets a proportionally tighter cloud, so one giant does not fog the field.
                const reach = @min(star.r * 2.3, 60 + star.r * 1.1) * st.look.cloud_size;
                const step = std.math.clamp(star.r * 0.13, 4, 12);
                // The web: a jittered honeycomb of nodes that thins toward a ragged edge,
                // each tied to its neighbours, so segments stay short and the net uneven.
                const budget: f32 = @floatFromInt(@max(1, segments));
                const spacing = @max(std.math.clamp(reach / 8, 8, 18), @max(reach * @sqrt(3.2 / budget), 2 * reach / @as(f32, web_side - 1)));
                const cols: usize = @min(web_side, @as(usize, @intFromFloat(2 * reach / spacing)) + 1);
                const rows: usize = @min(web_side, @as(usize, @intFromFloat(2 * reach / (spacing * 0.87))) + 1);
                for (0..rows) |row| for (0..cols) |col| {
                    const odd = row & 1;
                    const x = star.at[0] - reach + (@as(f32, @floatFromInt(col)) + 0.5 * @as(f32, @floatFromInt(odd)) + (rng.next() - 0.5) * 0.75) * spacing;
                    const y = star.at[1] - reach + (@as(f32, @floatFromInt(row)) * 0.87 + (rng.next() - 0.5) * 0.75) * spacing;
                    const dx = x - star.at[0];
                    const dy = y - star.at[1];
                    const far = @sqrt(dx * dx + dy * dy) / (reach * lobed(star.seed, std.math.atan2(dy, dx)));
                    const at = row * web_side + col;
                    web_on[at] = far < 0.3 + 0.75 * rng.next();
                    web[at] = .{ x, y };
                    const bright = rng.next();
                    const links = [3]f32{ rng.next(), rng.next(), rng.next() };
                    if (!web_on[at]) continue;
                    const fall = @max(0, 1 - far * 0.85);
                    dust.put(x, y, if (bright > 0.9) 2 else 1, draw.fade(pale, (0.3 + 0.6 * fall) * dimmed));
                    const up = col + odd;
                    const near = [3]?usize{ if (col > 0) at - 1 else null, if (row > 0 and up > 0) at + odd - web_side - 1 else null, if (row > 0 and up < cols) at + odd - web_side else null };
                    for (near, links) |other, chance| if (other) |index| {
                        if (!web_on[index] or chance > 0.82 or counts.mesh == mesh_segments) continue;
                        try ctx.thin(web[at], web[index], 1, draw.fade(hue, (0.08 + 0.2 * fall) * dimmed));
                        counts.mesh += 1;
                        segments -|= 1;
                    };
                };
                // Wisps: short wandering fibres that fray the cloud's edge.
                segments = @min(segments, @as(u32, @intFromFloat(share * mesh_segments * 0.15)));
                while (segments > 0 and counts.mesh < mesh_segments) {
                    const start = rng.next() * std.math.tau;
                    const far = (0.45 + 0.6 * rng.next()) * reach * lobed(star.seed, start);
                    var at = [2]f32{ star.at[0] + @cos(start) * far, star.at[1] + @sin(start) * far };
                    var heading = start + (rng.next() - 0.5) * 2;
                    var walk: u32 = @min(segments, 2 + @as(u32, @intFromFloat(rng.next() * 4)));
                    segments -= walk;
                    while (walk > 0) : (walk -= 1) {
                        heading += (rng.next() - 0.5) * 1.6;
                        const to = [2]f32{ at[0] + @cos(heading) * step, at[1] + @sin(heading) * step };
                        const dx = to[0] - star.at[0];
                        const dy = to[1] - star.at[1];
                        const fall = 1 - @sqrt(dx * dx + dy * dy) / (reach * 1.35);
                        if (fall <= 0) break;
                        try ctx.thin(at, to, 1, draw.fade(hue, (0.06 + 0.2 * fall) * dimmed));
                        dust.put(to[0], to[1], 1, draw.fade(pale, (0.25 + 0.5 * fall) * dimmed));
                        counts.mesh += 1;
                        at = to;
                    }
                }
                while (points > 0) : (points -= 1) {
                    const angle = rng.next() * std.math.tau;
                    const u = rng.next();
                    const far = reach * 1.2 * lobed(star.seed, angle) * std.math.pow(f32, u, 1.25);
                    const bright = rng.next();
                    const speck = bright > 0.95;
                    dust.put(star.at[0] + @cos(angle) * far, star.at[1] + @sin(angle) * far, if (speck) 2 else 1, draw.fade(if (speck) pale else hue, (0.2 + 0.7 * (1 - u) * bright) * dimmed));
                }
                // A folded group shows its members as motes; the count is exact up to the cap.
                if (star.members > 1) for (0..@min(star.members, 400)) |member| {
                    if (motes == group_motes) break;
                    motes += 1;
                    const f = @sqrt((@as(f32, @floatFromInt(member)) + 0.5) / @as(f32, @floatFromInt(star.members)));
                    const angle = @as(f32, @floatFromInt(member)) * golden + unit(star.seed) * std.math.tau;
                    dust.put(star.at[0] + @cos(angle) * star.r * 1.5 * f, star.at[1] + @sin(angle) * star.r * 1.5 * f, 2, draw.fade(pale, 0.8 * dimmed));
                };
            }
            counts.cloud = @intCast(dust.count);
            try ctx.r.retainCloud(state.cloud_slot, first_vertex, dust.items[0..dust.count], signature);
            state.cached_mesh = counts.mesh;
            state.cloud_builds += 1;
        }
        counts.mesh = state.cached_mesh;
        counts.cloud = ctx.r.clouds[state.cloud_slot].cells;
        try ctx.r.cloud(state.cloud_slot, motion.transform(), st.look.additive);
    }

    motion.project(s);
    for (s.clusters[0..s.cluster_count]) |cl| {
        v.clusterHit(.{ .x = cl.at[0] - 12, .y = cl.at[1] - 12, .w = 24, .h = 24 }, cl.key);
    }
    if (audit and s.cluster_count > 0) std.debug.print("xodb: galaxy-cluster x={d:.1} y={d:.1}\n", .{ s.clusters[0].at[0], s.clusters[0].at[1] });
    // The pointer's star lifts its own threads out of the web.
    var hovered: u32 = none;
    for (s.stars[0..s.star_count], 0..) |star, i| {
        if (@abs(v.pointer[0] - star.at[0]) < 12 and @abs(v.pointer[1] - star.at[1]) < 12) hovered = @intCast(i);
    }
    var hot_thread: u32 = none;
    var nearest: f32 = 6;
    if (pointer_changed) state.thread_hover = null;
    for (s.order[0..@min(s.strand_count, drawn_strands)]) |index| {
        const strand = s.strands[index];
        if (!pointer_changed) {
            if (state.thread_hover) |hot| if (hot.seed == strand.seed and hot.a == strand.a and hot.b == strand.b) {
                hot_thread = index;
            };
            continue;
        }
        // Hit the geometry under the arriving pointer, before this frame's
        // camera step. Keep that logical thread while the camera moves it.
        var a = s.end(strand.a);
        var b = s.end(strand.b);
        for (0..2) |axis| {
            a[axis] = (a[axis] - motion.shift[axis]) / motion.zoom * previous_view[0] + previous_view[axis + 2];
            b[axis] = (b[axis] - motion.shift[axis]) / motion.zoom * previous_view[0] + previous_view[axis + 2];
        }
        const mid = control(a, b, strand.seed, strand.b >= max_stars);
        var from = a;
        for (1..25) |part| {
            const to = bezier(a, mid, b, @as(f32, @floatFromInt(part)) / 24);
            const dx = to[0] - from[0];
            const dy = to[1] - from[1];
            const t = std.math.clamp(((v.pointer[0] - from[0]) * dx + (v.pointer[1] - from[1]) * dy) / @max(0.01, dx * dx + dy * dy), 0, 1);
            const distance = @sqrt(std.math.pow(f32, v.pointer[0] - from[0] - dx * t, 2) + std.math.pow(f32, v.pointer[1] - from[1] - dy * t, 2));
            if (distance < nearest) {
                nearest = distance;
                hot_thread = index;
            }
            from = to;
        }
    }
    if (pointer_changed and hot_thread != none) {
        const hot = s.strands[hot_thread];
        state.thread_hover = .{ .seed = hot.seed, .a = hot.a, .b = hot.b };
    }

    // Gossamer: the heaviest and busiest threads, as curves. A thread with
    // traffic turns into a string of beads, like dew on a web.
    var beads = Dust{ .items = &bead_store };
    counts.strands_drawn = @min(s.strand_count, drawn_strands);
    for (s.stars[0..s.star_count]) |*star| star.flash = 0;
    for (s.order[0..counts.strands_drawn]) |index| {
        if (ctx.r.used() > 0.7) break;
        const strand = s.strands[index];
        const a = s.end(strand.a);
        const b = s.end(strand.b);
        const m = control(a, b, strand.seed, strand.b >= max_stars);
        if (audit and index == s.order[0]) {
            const mid = bezier(a, m, b, 0.5);
            std.debug.print("xodb: galaxy-thread x={d:.1} y={d:.1}\n", .{ mid[0], mid[1] });
        }
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const length = @sqrt(dx * dx + dy * dy);
        if (length < 2) continue;
        const live = energy(clock, strand.pulse.last_ns) * @as(f32, if (strand.pulse.ab + strand.pulse.ba > 0) 1 else 0);
        const lifted = index == hot_thread or (hovered != none and (strand.a == hovered or strand.b == hovered));
        const tinted: u32 = if (strand.a < s.star_count) strand.a else if (strand.b < s.star_count) strand.b else none;
        const hue = if (lk.plain or tinted == none) lk.thread else draw.mix(lk.hues[s.clusters[s.stars[tinted].cluster].key % lk.hue_count], lk.thread, 0.4);
        const alpha = @min(0.9, (if (strand.stale) @as(f32, 0.1) else 0.22) + 0.05 * @log2(@as(f32, @floatFromInt(strand.weight))) + 0.08 * live + @as(f32, if (lifted) 0.5 else 0)) * @as(f32, if (lk.plain) 2.2 else 1);
        const steps: usize = @intFromFloat(std.math.clamp(length / 18, 5, 16));
        var from = a;
        for (1..steps + 1) |i| {
            const to = bezier(a, m, b, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps)));
            try ctx.line(from, to, if (lifted) 1.6 else 1, draw.fade(hue, alpha));
            from = to;
        }
        if (live > 0 and !lk.plain) {
            const count: usize = @intFromFloat(std.math.clamp(length / 9, 3, 90));
            for (1..count) |i| {
                const at = bezier(a, m, b, @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count)));
                beads.put(at[0], at[1], 2, draw.fade(draw.mix(hue, .{ 1, 1, 1, 1 }, 0.35), 0.55 * live));
            }
        }
    }
    for (s.junctions[0..s.junction_count]) |junction| {
        if (junction.holders == 0) continue;
        const color = v.kindColor(ctx.p, junction.kind);
        try ctx.r.shape(.{ .x = junction.at[0] - 4, .y = junction.at[1] - 4, .w = 8, .h = 8 }, draw.fade(color, 0.85), .{ .radii = @splat(4), .border = 1 });
        const hit = draw.Rect{ .x = junction.at[0] - 7, .y = junction.at[1] - 7, .w = 14, .h = 14 };
        v.junctionHit(hit, junction);
    }

    // Impulses: bright heads with fading tails, in the direction the bytes went.
    var until: u64 = 0;
    const Head = struct { at: [2]f32, color: Color, live: f32 };
    var heads: [drawn_impulses]Head = undefined;
    for (s.order[0..counts.strands_drawn]) |index| {
        const strand = s.strands[index];
        const live = energy(clock, strand.pulse.last_ns);
        if (live <= 0) continue;
        const a = s.end(strand.a);
        const b = s.end(strand.b);
        const m = control(a, b, strand.seed, strand.b >= max_stars);
        const color = v.kindColor(ctx.p, strand.kind);
        for ([2]f64{ strand.pulse.ab, strand.pulse.ba }, 0..) |rate, back| {
            if (rate <= 0) continue;
            until = @max(until, strand.pulse.last_ns +| linger_ns);
            // Count and speed step with the logarithm of the rate, so a refresh rarely moves a phase.
            const level: u32 = @min(4, @as(u32, @intFromFloat(@log2(1 + rate / 1024) / 3.5)));
            const period: u64 = ([5]u64{ 2400, 1900, 1500, 1150, 850 })[level] * 1_000_000;
            const base = @as(f32, @floatFromInt(clock % period)) / @as(f32, @floatFromInt(period)) + unit(mix(strand.seed ^ back));
            for (0..level + 1) |k| {
                if (counts.impulses == drawn_impulses or ctx.r.used() > 0.8) break;
                const t = @mod(base + @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(level + 1)), 1);
                const target = if (back == 0) strand.b else strand.a;
                const landed = t * @as(f32, @floatFromInt(period)) / 280_000_000.0;
                if (landed < 1 and target < max_stars) s.stars[target].flash = @max(s.stars[target].flash, (1 - landed) * live);
                const dx = b[0] - a[0];
                const dy = b[1] - a[1];
                const spacing = 3.5 / @max(40, @sqrt(dx * dx + dy * dy));
                for (0..12) |tail| {
                    const back_t = t - @as(f32, @floatFromInt(tail)) * spacing;
                    if (back_t < 0) break;
                    const at = bezier(a, m, b, if (back == 0) back_t else 1 - back_t);
                    const fall = 1 - @as(f32, @floatFromInt(tail)) / 12;
                    if (lk.plain) {
                        try disc(ctx, at, 3, lk.text);
                        break;
                    }
                    if (tail == 0) heads[counts.impulses] = .{ .at = at, .color = color, .live = live } else beads.put(at[0], at[1], if (tail < 5) 3 else 2, draw.fade(draw.mix(color, .{ 1, 1, 1, 1 }, 0.5), 0.85 * fall * fall * live));
                }
                counts.impulses += 1;
            }
        }
    }
    beads.flush(ctx, !lk.plain and st.look.additive);
    if (!lk.plain) for (heads[0..counts.impulses]) |head| {
        try glow(ctx, head.at, 11, draw.fade(head.color, 0.6 * head.live));
        try disc(ctx, head.at, 2.4, draw.fade(draw.mix(head.color, .{ 1, 1, 1, 1 }, 0.85), head.live));
    };
    counts.moving = counts.impulses > 0 and !v.paused;
    st.impulse_until = if (counts.impulses == 0 or v.paused) 0 else if (s.synthetic) now + linger_ns else until;
    st.layout_only = motion.layout_active and !motion.camera_active and counts.impulses == 0;
    st.motion_until = 0;
    if (motion.active and !v.paused) {
        counts.moving = true;
        st.motion_until = now + 200_000_000;
    }

    // Descriptors: the hoverable points around each star.
    for (s.particles[0..s.particle_count]) |particle| {
        const star = s.stars[particle.star];
        const lone = s.star_count == 1;
        // In a crowd only what stands out keeps a dot; the cloud carries the rest.
        if (!lone and star.r < 7 and particle.alerts == 0 and particle.incoming + particle.outgoing == 0) continue;
        if (ctx.r.used() > 0.88) break;
        const f = @sqrt((@as(f32, @floatFromInt(particle.ordinal)) + 0.5) / @as(f32, @floatFromInt(@max(1, star.particles))));
        const angle = @as(f32, @floatFromInt(particle.ordinal)) * golden + unit(star.seed >> 8) * std.math.tau;
        const orbit = if (lone) star.r * 1.3 * f else @max(13, star.r * (0.5 + 0.55 * f));
        const at = [2]f32{ star.at[0] + @cos(angle) * orbit, star.at[1] + @sin(angle) * orbit };
        const flow = particle.incoming + particle.outgoing;
        const radius: f32 = @min(if (lk.plain) @as(f32, 9) else 4.5, (if (lk.plain) @as(f32, 3) else 1.2) + 0.3 * @log2(@as(f32, @floatFromInt(@max(1, particle.units)))) + @as(f32, @floatCast(@min(2.0, @log(1.0 + flow / 1024.0) * 0.4))));
        const color = if (particle.alerts > 0 and !lk.plain) lk.hot else v.kindColor(ctx.p, particle.kind);
        const pulse = if (flow > 0) energy(clock, particle.last_ns) else 0;
        if (!lk.plain and pulse > 0) try glow(ctx, at, radius + 7, draw.fade(color, 0.45 * pulse));
        if (particle.alerts > 0) try disc(ctx, at, radius + 3, draw.fade(lk.hot, 0.3));
        try disc(ctx, at, radius, draw.fade(color, if (particle.stale) 0.5 else 0.95));
        const reach = @max(radius + 2, 6);
        const hit = draw.Rect{ .x = at[0] - reach, .y = at[1] - reach, .w = reach * 2, .h = reach * 2 };
        v.detailHit(hit, particle);
    }

    // Stars: a small bright core; a landing impulse flashes it.
    for (s.stars[0..s.star_count], 0..) |star, i| {
        const hue = lk.hues[s.clusters[star.cluster].key % lk.hue_count];
        const flagged = star.alerts > 0;
        const color = if (lk.plain) (if (star.unavailable) ctx.p.warn else if (star.stale) ctx.p.dim else ctx.p.text) else if (flagged) lk.hot else if (star.unavailable or star.stale) draw.mix(hue, lk.dim, 0.7) else draw.mix(hue, .{ 1, 1, 1, 1 }, 0.55);
        const busy: f32 = @floatCast(@min(3.0, @log(1.0 + (star.incoming + star.outgoing) / 1024.0) * 0.5));
        const core: f32 = std.math.clamp(star.r * 0.11, 1.5, 3) + (if (star.members > 1) @as(f32, 1) else 0) + busy * 0.4 + (if (flagged) @as(f32, 0.8) else 0);
        const pulse = if (star.incoming + star.outgoing > 0) energy(clock, star.last_ns) else 0;
        if (lk.plain) {
            try disc(ctx, star.at, core + 5, draw.fade(color, 0.12 + pulse * 0.2));
            try disc(ctx, star.at, core + 2, color);
        } else {
            if (s.star_count <= 400 or pulse > 0 or flagged) try glow(ctx, star.at, core * 3 + 6 + 4 * pulse, draw.fade(color, 0.3 + 0.2 * pulse));
            if (star.flash > 0) try glow(ctx, star.at, core * 3 + 16, draw.fade(.{ 1, 1, 1, 1 }, 0.6 * star.flash));
            try ctx.r.shape(.{ .x = @round(star.at[0] - core), .y = @round(star.at[1] - core), .w = @round(core * 2), .h = @round(core * 2) }, color, .{ .radii = @splat(1) });
        }
        const hit = draw.Rect{ .x = star.at[0] - 14, .y = star.at[1] - 14, .w = 28, .h = 28 };
        v.nodeHit(hit, star, @intCast(i), s.synthetic, audit);
    }

    // Labels: clusters first, then the pointer's star and the busiest few.
    var placed = Placed{ .field = field };
    for (reserved) |row| placed.add(row);
    if (hot_thread != none) {
        const strand = s.strands[hot_thread];
        const hit = draw.Rect{ .x = v.pointer[0] - 4, .y = v.pointer[1] - 4, .w = 8, .h = 8 };
        v.threadHit(hit, strand);
        for ([2]u16{ strand.a, strand.b }) |end| {
            const at = s.end(end);
            const name = if (end < max_stars) s.stars[end].label() else v.junctionName();
            const width = @min(ctx.measure(name) + 12, 230);
            const tag = draw.Rect{ .x = at[0] + 14, .y = at[1] + 16, .w = width, .h = 25 };
            if (placed.free(tag)) {
                placed.add(tag);
                try ctx.r.rect(tag, draw.fade(lk.field, 0.95));
                try ctx.r.shape(tag, v.kindColor(ctx.p, strand.kind), .{ .border = 1 });
                try ctx.textFit(tag.x + 6, tag.y + 2, tag.w - 12, name, lk.text);
            }
        }
    }
    const budget: usize = @intFromFloat(std.math.clamp(body.w * body.h / 52000, 3, max_labels));
    var name_buffer: [64]u8 = undefined;
    var caption_buffer: [96]u8 = undefined;
    var rate_buffer: [32]u8 = undefined;
    for (s.clusters[0..s.cluster_count]) |cl| {
        if (cl.stars < 2 or counts.labels >= budget * 2 / 3 + 1) continue;
        const hue = lk.hues[cl.key % lk.hue_count];
        const caption = v.clusterCaption(cl, &caption_buffer, &rate_buffer);
        if (try label(ctx, &placed, lk, .{ cl.at[0] + cl.r * 0.55, cl.at[1] - cl.r * 0.75 }, 4, cl.name[0..cl.name_len], caption, if (lk.plain) lk.text else hue, lk.dim)) counts.labels += 1;
    }
    var shown: [max_labels]u32 = undefined;
    var shown_count: usize = 0;
    while (counts.labels < budget and shown_count < shown.len) {
        var best: u32 = none;
        var best_score: f32 = -1;
        for (s.stars[0..s.star_count], 0..) |star, i| {
            if (std.mem.indexOfScalar(u32, shown[0..shown_count], @intCast(i)) != null) continue;
            var score: f32 = @floatCast(@log2(1 + star.incoming + star.outgoing) * 8 + @log2(1.0 + @as(f64, @floatFromInt(star.units))));
            if (star.units == 0 and star.incoming + star.outgoing == 0) score = -2;
            if (i == hovered) score += 1e6;
            if (star.alerts > 0) score += 60;
            if (star.members > 1) score += 40;
            if (s.clusters[star.cluster].stars == 1) score += 20;
            if (score > best_score) {
                best_score = score;
                best = @intCast(i);
            }
        }
        if (best == none) break;
        shown[shown_count] = best;
        shown_count += 1;
        const star = s.stars[best];
        const caption = v.nodeCaption(star, &caption_buffer, &rate_buffer);
        const name = std.fmt.bufPrint(&name_buffer, "{s}", .{star.label()}) catch "";
        const flagged = star.alerts > 0 and !lk.plain;
        if (try label(ctx, &placed, lk, star.at, @min(star.r * 0.5 + 6, 26), name, caption, if (flagged) lk.hot else if (star.unavailable or star.stale) lk.dim else lk.text, if (flagged) draw.fade(lk.hot, 0.8) else lk.dim)) counts.labels += 1;
    }
    counts.used = ctx.r.used();
    if (audit) std.debug.print("xodb: galaxy-look builds={d} zoom={d:.4} camera={d} layout={d} thread={d} additive={d} cloud_size={d:.2} max_stars={d} unfolded={d}\n", .{ state.cloud_builds, motion.zoom, @intFromBool(motion.camera_active), @intFromBool(motion.layout_active), hot_thread, @intFromBool(st.look.additive), st.look.cloud_size, st.max_stars, @intFromBool(!st.collapse) });
    return counts;
}
