//! Overview drawing vocabulary built on the renderer's quads, rounded
//! shapes and triangles: clipped anti-aliased polylines and areas, arcs,
//! hatching for unavailable values, VFD seven-segment digits and segmented
//! bar meters. Edges are feathered by one pixel instead of multisampling.
const std = @import("std");
const gpu = @import("../../render/vulkan.zig");
const Font = @import("../../render/font.zig").Font;
const Palette = @import("theme.zig").Palette;
pub const Color = gpu.Color;
pub const Rect = gpu.Rect;

pub fn fade(color: Color, alpha: f32) Color {
    return .{ color[0], color[1], color[2], color[3] * alpha };
}
pub fn mix(a: Color, b: Color, t: f32) Color {
    var out: Color = undefined;
    for (&out, a, b) |*channel, from, to| channel.* = from + (to - from) * t;
    return out;
}
pub fn inside(r: Rect, x: f32, y: f32) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}
pub fn inset(r: Rect, by: f32) Rect {
    return .{ .x = r.x + by, .y = r.y + by, .w = @max(0, r.w - 2 * by), .h = @max(0, r.h - 2 * by) };
}

const V = struct { p: [2]f32, c: Color };
fn lerpV(a: V, b: V, t: f32) V {
    return .{ .p = .{ a.p[0] + (b.p[0] - a.p[0]) * t, a.p[1] + (b.p[1] - a.p[1]) * t }, .c = mix(a.c, b.c, t) };
}

/// Optional layout audit: every text box drawn this frame, so tests can
/// assert that no two labels collide (XODB_OVERVIEW_LAYOUT=1).
pub const Layout = struct {
    boxes: [4096]Rect = undefined,
    labels: [4096][28]u8 = undefined,
    lens: [4096]u8 = undefined,
    count: usize = 0,
    pub fn add(self: *Layout, r: Rect, s: []const u8) void {
        if (self.count == self.boxes.len or r.w < 1 or s.len == 0) return;
        if (std.mem.trim(u8, s, " ").len == 0) return;
        self.boxes[self.count] = r;
        const n = @min(s.len, 28);
        @memcpy(self.labels[self.count][0..n], s[0..n]);
        self.lens[self.count] = @intCast(n);
        self.count += 1;
    }
    /// Pairs of boxes that overlap, or sit on one row closer than `gap`
    /// pixels (two labels that read as one phrase); reports the first three.
    pub fn overlaps(self: *const Layout, first: *[6][]const u8) usize {
        var n: usize = 0;
        for (0..self.count) |i| for (i + 1..self.count) |j| {
            // Glyph marks (tree twisties, state letters) may sit tight; words may not.
            const gap: f32 = if (self.lens[i] >= 4 and self.lens[j] >= 4) 12 else 0;
            const x = self.boxes[i];
            const a = intersect(.{ .x = x.x - gap / 2, .y = x.y, .w = x.w + gap, .h = x.h }, .{ .x = self.boxes[j].x - gap / 2, .y = self.boxes[j].y, .w = self.boxes[j].w + gap, .h = self.boxes[j].h });
            if (a.w > 2 and a.h > 4) {
                if (n < 3) {
                    first[n * 2] = self.labels[i][0..self.lens[i]];
                    first[n * 2 + 1] = self.labels[j][0..self.lens[j]];
                }
                n += 1;
            }
        };
        return n;
    }
};

pub const Ctx = struct {
    r: *gpu.Renderer,
    font: *Font,
    p: *const Palette,
    layout: ?*Layout = null,
    fn note(self: Ctx, x: f32, y: f32, w: f32, s: []const u8) void {
        if (self.layout) |l| l.add(.{ .x = x, .y = y + 2, .w = w, .h = 16 }, s);
    }

    /// Convex polygon, clipped to the renderer's clip rectangle (Sutherland-Hodgman)
    /// and drawn as a fan.
    pub fn poly(self: Ctx, points: []const [2]f32, colors: []const Color) !void {
        var a: [16]V = undefined;
        var b: [16]V = undefined;
        var n: usize = @min(points.len, 8);
        for (0..n) |i| a[i] = .{ .p = points[i], .c = colors[@min(i, colors.len - 1)] };
        const clip = self.r.clip;
        const edges = [4]struct { axis: u1, limit: f32, keep_less: bool }{
            .{ .axis = 0, .limit = clip.x, .keep_less = false },
            .{ .axis = 0, .limit = clip.x + clip.w, .keep_less = true },
            .{ .axis = 1, .limit = clip.y, .keep_less = false },
            .{ .axis = 1, .limit = clip.y + clip.h, .keep_less = true },
        };
        var src = &a;
        var dst = &b;
        for (edges) |e| {
            var m: usize = 0;
            for (0..n) |i| {
                const cur = src[i];
                const prev = src[(i + n - 1) % n];
                const cin = if (e.keep_less) cur.p[e.axis] <= e.limit else cur.p[e.axis] >= e.limit;
                const pin = if (e.keep_less) prev.p[e.axis] <= e.limit else prev.p[e.axis] >= e.limit;
                if (cin != pin) {
                    const t = (e.limit - prev.p[e.axis]) / (cur.p[e.axis] - prev.p[e.axis]);
                    if (m < dst.len) dst[m] = lerpV(prev, cur, t);
                    m += 1;
                }
                if (cin) {
                    if (m < dst.len) dst[m] = cur;
                    m += 1;
                }
            }
            n = @min(m, dst.len);
            if (n < 3) return;
            const swap = src;
            src = dst;
            dst = swap;
        }
        for (1..n - 1) |i| try self.r.triangle(.{ src[0].p, src[i].p, src[i + 1].p }, .{ src[0].c, src[i].c, src[i + 1].c });
    }

    /// Anti-aliased segment: a solid core and a one-pixel feather on each side.
    pub fn line(self: Ctx, p0: [2]f32, p1: [2]f32, width: f32, color: Color) !void {
        const dx = p1[0] - p0[0];
        const dy = p1[1] - p0[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return;
        const nx = -dy / len;
        const ny = dx / len;
        const core = @max(0, width / 2 - 0.5);
        const outer = core + 1;
        const clear = fade(color, 0);
        const c0 = [2]f32{ p0[0] + nx * core, p0[1] + ny * core };
        const c1 = [2]f32{ p1[0] + nx * core, p1[1] + ny * core };
        const c2 = [2]f32{ p1[0] - nx * core, p1[1] - ny * core };
        const c3 = [2]f32{ p0[0] - nx * core, p0[1] - ny * core };
        if (core > 0) try self.poly(&.{ c0, c1, c2, c3 }, &.{color});
        const o0 = [2]f32{ p0[0] + nx * outer, p0[1] + ny * outer };
        const o1 = [2]f32{ p1[0] + nx * outer, p1[1] + ny * outer };
        const o2 = [2]f32{ p1[0] - nx * outer, p1[1] - ny * outer };
        const o3 = [2]f32{ p0[0] - nx * outer, p0[1] - ny * outer };
        try self.poly(&.{ o0, o1, c1, c0 }, &.{ clear, clear, color, color });
        try self.poly(&.{ c3, c2, o2, o3 }, &.{ color, color, clear, clear });
    }

    /// One-pixel-class segment without feathering (hatching, ticks).
    pub fn thin(self: Ctx, p0: [2]f32, p1: [2]f32, width: f32, color: Color) !void {
        const dx = p1[0] - p0[0];
        const dy = p1[1] - p0[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return;
        const nx = -dy / len * width / 2;
        const ny = dx / len * width / 2;
        try self.poly(&.{ .{ p0[0] + nx, p0[1] + ny }, .{ p1[0] + nx, p1[1] + ny }, .{ p1[0] - nx, p1[1] - ny }, .{ p0[0] - nx, p0[1] - ny } }, &.{color});
    }

    /// A wide, faint halo under a trace: the phosphor bloom.
    pub fn halo(self: Ctx, p0: [2]f32, p1: [2]f32, radius: f32, color: Color) !void {
        const dx = p1[0] - p0[0];
        const dy = p1[1] - p0[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 0.001) return;
        const nx = -dy / len * radius;
        const ny = dx / len * radius;
        const clear = fade(color, 0);
        try self.poly(&.{ .{ p0[0] + nx, p0[1] + ny }, .{ p1[0] + nx, p1[1] + ny }, p1, p0 }, &.{ clear, clear, color, color });
        try self.poly(&.{ p0, p1, .{ p1[0] - nx, p1[1] - ny }, .{ p0[0] - nx, p0[1] - ny } }, &.{ color, color, clear, clear });
    }

    pub fn polyline(self: Ctx, points: []const ?[2]f32, width: f32, color: Color, glow: bool) !void {
        if (glow and self.p.glow > 0) {
            for (1..points.len) |i| if (points[i - 1] != null and points[i] != null)
                try self.halo(points[i - 1].?, points[i].?, 5, fade(color, 0.22 * self.p.glow));
        }
        for (1..points.len) |i| if (points[i - 1] != null and points[i] != null)
            try self.line(points[i - 1].?, points[i].?, width, color);
    }

    /// Filled area from each segment down to `base`, fading with depth.
    pub fn area(self: Ctx, points: []const ?[2]f32, base: f32, top: f32, color: Color, strength: f32) !void {
        const h = @max(1, base - top);
        for (1..points.len) |i| {
            const a = points[i - 1] orelse continue;
            const b = points[i] orelse continue;
            const ca = fade(color, strength * (0.25 + 0.75 * (base - a[1]) / h));
            const cb = fade(color, strength * (0.25 + 0.75 * (base - b[1]) / h));
            const bottom = fade(color, strength * 0.1);
            try self.poly(&.{ a, b, .{ b[0], base }, .{ a[0], base } }, &.{ ca, cb, bottom, bottom });
        }
    }

    /// Annulus arc from `a0` to `a1` radians (0 = east, clockwise on screen).
    pub fn arc(self: Ctx, cx: f32, cy: f32, radius: f32, thick: f32, a0: f32, a1: f32, color: Color) !void {
        const span = a1 - a0;
        if (@abs(span) < 0.0001) return;
        const steps: usize = @max(2, @as(usize, @intFromFloat(@abs(span) / (std.math.pi * 2) * 96)));
        const inner = radius - thick / 2;
        const outer = radius + thick / 2;
        const clear = fade(color, 0);
        for (0..steps) |i| {
            const t0 = a0 + span * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            const t1 = a0 + span * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));
            const c0 = [2]f32{ @cos(t0), @sin(t0) };
            const c1 = [2]f32{ @cos(t1), @sin(t1) };
            const at = struct {
                fn f(cx_: f32, cy_: f32, d: [2]f32, rr: f32) [2]f32 {
                    return .{ cx_ + d[0] * rr, cy_ + d[1] * rr };
                }
            }.f;
            try self.poly(&.{ at(cx, cy, c0, inner), at(cx, cy, c0, outer), at(cx, cy, c1, outer), at(cx, cy, c1, inner) }, &.{color});
            try self.poly(&.{ at(cx, cy, c0, outer), at(cx, cy, c0, outer + 1), at(cx, cy, c1, outer + 1), at(cx, cy, c1, outer) }, &.{ color, clear, clear, color });
            try self.poly(&.{ at(cx, cy, c0, inner - 1), at(cx, cy, c0, inner), at(cx, cy, c1, inner), at(cx, cy, c1, inner - 1) }, &.{ clear, color, color, clear });
            if (self.p.glow > 0) {
                const g = fade(color, 0.18 * self.p.glow);
                const gc = fade(color, 0);
                try self.poly(&.{ at(cx, cy, c0, outer), at(cx, cy, c0, outer + 7), at(cx, cy, c1, outer + 7), at(cx, cy, c1, outer) }, &.{ g, gc, gc, g });
            }
        }
    }

    /// Diagonal hatching marks an unavailable value; it is never drawn as zero.
    pub fn hatch(self: Ctx, rect: Rect) !void {
        const saved = self.r.clip;
        defer self.r.clip = saved;
        self.r.clip = intersect(saved, rect);
        try self.r.rect(rect, fade(self.p.hatch, 0.08));
        const step: f32 = 9;
        var k: f32 = -rect.h;
        while (k < rect.w) : (k += step) {
            try self.thin(.{ rect.x + k, rect.y + rect.h }, .{ rect.x + k + rect.h, rect.y }, 1.3, fade(self.p.hatch, 0.6));
        }
        try self.r.shape(rect, fade(self.p.hatch, 0.6), .{ .border = 1 });
    }

    /// Hatching faint enough to carry a readable reason on top.
    pub fn hatchLight(self: Ctx, rect: Rect) !void {
        const saved = self.r.clip;
        defer self.r.clip = saved;
        self.r.clip = intersect(saved, rect);
        try self.r.rect(rect, fade(self.p.hatch, 0.10));
        var k: f32 = -rect.h;
        while (k < rect.w) : (k += 7) try self.thin(.{ rect.x + k, rect.y + rect.h }, .{ rect.x + k + rect.h, rect.y }, 1, fade(self.p.hatch, 0.25));
        try self.r.shape(rect, fade(self.p.hatch, 0.5), .{ .border = 1 });
    }
    pub fn text(self: Ctx, x: f32, y: f32, s: []const u8, color: Color) !void {
        if (self.layout != null) self.note(x, y, self.measure(s), s);
        try self.r.text(self.font, @round(x), @round(y), s, color);
    }
    pub fn textFit(self: Ctx, x: f32, y: f32, w: f32, s: []const u8, color: Color) !void {
        if (w <= 4) return;
        if (self.layout != null) self.note(x, y, @min(w, self.measure(s)), s);
        try self.r.textFit(self.font, @round(x), @round(y), w, s, color);
    }
    pub fn textRight(self: Ctx, right: f32, y: f32, s: []const u8, color: Color) !void {
        const w = self.r.measure(self.font, s);
        if (self.layout != null) self.note(right - w, y, w, s);
        try self.r.text(self.font, @round(right - w), @round(y), s, color);
    }
    pub fn measure(self: Ctx, s: []const u8) f32 {
        return self.r.measure(self.font, s);
    }
    /// Text with a soft phosphor bloom in glowing themes.
    pub fn glowText(self: Ctx, x: f32, y: f32, s: []const u8, color: Color) !void {
        if (self.p.glow > 0.5) {
            const w = self.measure(s);
            try self.r.shape(.{ .x = x - 8, .y = y - 2, .w = w + 16, .h = 24 }, fade(color, 0.10 * self.p.glow), .{ .radii = @splat(10), .softness = 7 });
        }
        try self.text(x, y, s, color);
    }

    pub fn panel(self: Ctx, rect: Rect) !void {
        if (self.p.win95) return self.bevel(rect, true);
        try self.r.shape(rect, self.p.panel, .{ .radii = @splat(6) });
        try self.r.shape(rect, self.p.border, .{ .radii = @splat(6), .border = 1 });
    }

    /// Four-color, two-pixel system-control edge. Small rectangles stay empty.
    pub fn bevel(self: Ctx, rect: Rect, sunken: bool) !void {
        if (rect.w < 4 or rect.h < 4) return;
        const rgb = @import("../../appearance.zig").rgb;
        const light = rgb(0xffffff);
        const gray = rgb(0xdfdfdf);
        const dark = rgb(0x808080);
        const black = rgb(0x000000);
        try self.r.rect(rect, rgb(0xc0c0c0));
        const upper = [2]Color{ if (sunken) dark else light, if (sunken) black else gray };
        const lower = [2]Color{ if (sunken) light else black, if (sunken) gray else dark };
        for (0..2) |i| {
            const q = inset(rect, @floatFromInt(i));
            try self.r.rect(.{ .x = q.x, .y = q.y, .w = q.w, .h = 1 }, upper[i]);
            try self.r.rect(.{ .x = q.x, .y = q.y, .w = 1, .h = q.h }, upper[i]);
            try self.r.rect(.{ .x = q.x, .y = q.y + q.h - 1, .w = q.w, .h = 1 }, lower[i]);
            try self.r.rect(.{ .x = q.x + q.w - 1, .y = q.y, .w = 1, .h = q.h }, lower[i]);
        }
    }
    pub fn button(self: Ctx, rect: Rect, selected: bool) !void {
        if (self.p.win95) {
            try self.bevel(rect, selected);
            if (selected) try self.r.rect(inset(rect, 2), self.p.raised);
        } else try self.r.shape(rect, if (selected) self.p.selection else self.p.raised, .{ .radii = @splat(5) });
    }
    pub fn list(self: Ctx, rect: Rect) !void {
        try self.panel(rect);
        if (self.p.win95) try self.r.rect(inset(rect, 2), .{ 1, 1, 1, 1 });
    }

    fn progress(self: Ctx, rect: Rect, value: ?f64) !void {
        if (rect.w < 4 or rect.h <= 0) return;
        const inset_by: f32 = if (rect.h >= 8) 2 else 0;
        if (inset_by > 0) try self.bevel(rect, true);
        const inner = inset(rect, inset_by);
        try self.r.rect(inner, self.p.raised);
        const v = value orelse return self.hatch(inner);
        const end = inner.w * @as(f32, @floatCast(std.math.clamp(v, 0, 1)));
        var x: f32 = 0;
        while (x < end) : (x += 8) try self.r.rect(.{ .x = inner.x + x, .y = inner.y, .w = @min(6, end - x), .h = inner.h }, self.p.accent);
    }

    /// Segmented VFD bar: `cells` discrete cells, lit up to `value` (0..1),
    /// unlit cells shown as ghosts. Null draws hatching.
    pub fn segments(self: Ctx, rect: Rect, value: ?f64, color: Color) !void {
        if (self.p.win95) return self.progress(rect, value);
        const v = value orelse return self.hatch(rect);
        const cell_w: f32 = if (rect.h >= 14) 5 else 4;
        const gap: f32 = 2;
        const cells: usize = @max(1, @as(usize, @intFromFloat(@max(0, (rect.w + gap) / (cell_w + gap)))));
        const lit: usize = @intFromFloat(@round(std.math.clamp(v, 0, 1) * @as(f64, @floatFromInt(cells))));
        if (self.p.glow > 0 and lit > 0) {
            const w = @as(f32, @floatFromInt(lit)) * (cell_w + gap);
            try self.r.shape(.{ .x = rect.x - 5, .y = rect.y - 5, .w = w + 10, .h = rect.h + 10 }, fade(color, 0.16 * self.p.glow), .{ .radii = @splat(6), .softness = 5 });
        }
        for (0..cells) |i| {
            const x = rect.x + @as(f32, @floatFromInt(i)) * (cell_w + gap);
            const on = i < lit;
            const heat = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(cells));
            const c = if (!on) fade(color, self.p.ghost + 0.03) else if (self.p.monochrome) color else if (heat > 0.9) self.p.crit else if (heat > 0.75) self.p.warn else color;
            try self.r.rect(.{ .x = x, .y = rect.y, .w = cell_w, .h = rect.h }, c);
        }
    }

    /// Smooth thin bar with rounded ends (dense tables).
    pub fn bar(self: Ctx, rect: Rect, value: ?f64, color: Color) !void {
        if (self.p.win95) return self.progress(rect, value);
        const v = value orelse return self.hatch(rect);
        try self.r.shape(rect, fade(self.p.grid, 1.4), .{ .radii = @splat(rect.h / 2) });
        const w = rect.w * @as(f32, @floatCast(std.math.clamp(v, 0, 1)));
        if (w >= rect.h / 2) try self.r.shape(.{ .x = rect.x, .y = rect.y, .w = @max(w, rect.h), .h = rect.h }, color, .{ .radii = @splat(rect.h / 2), .colors = .{ fade(color, 0.75), color, fade(color, 0.75), color } });
    }

    // Seven-segment layout: a top, b upper right, c lower right, d bottom,
    // e lower left, f upper left, g middle.
    const digit_segments = [_]u7{ 0b0111111, 0b0000110, 0b1011011, 0b1001111, 0b1100110, 0b1101101, 0b1111101, 0b0000111, 0b1111111, 0b1101111 };

    fn segment(self: Ctx, x0: f32, y0: f32, x1: f32, y1: f32, t: f32, color: Color, glow: bool) !void {
        // Hexagonal segment between two centre points, thickness t.
        const h = t / 2;
        const g = 0.6;
        if (glow and self.p.glow > 0) {
            try self.r.shape(.{ .x = @min(x0, x1) - h - 6, .y = @min(y0, y1) - h - 6, .w = @abs(x1 - x0) + t + 12, .h = @abs(y1 - y0) + t + 12 }, fade(color, 0.20 * self.p.glow), .{ .radii = @splat(h + 6), .softness = 6 });
        }
        if (y0 == y1) {
            try self.poly(&.{ .{ x0 + g, y0 }, .{ x0 + h + g, y0 - h }, .{ x1 - h - g, y1 - h }, .{ x1 - g, y1 }, .{ x1 - h - g, y1 + h }, .{ x0 + h + g, y0 + h } }, &.{color});
        } else {
            try self.poly(&.{ .{ x0, y0 + g }, .{ x0 + h, y0 + h + g }, .{ x1 + h, y1 - h - g }, .{ x1, y1 - g }, .{ x1 - h, y1 - h - g }, .{ x0 - h, y0 + h + g } }, &.{color});
        }
    }

    /// Width of one digit cell for height `h`.
    pub fn digitWidth(h: f32) f32 {
        return h * 0.56;
    }

    /// Big VFD number. Digits, '.', ':', '-', '%' and ' ' are drawn; unlit
    /// segments glow faintly like a real display. Returns the advance.
    pub fn vfd(self: Ctx, x: f32, y: f32, h: f32, s: []const u8, color: Color) !f32 {
        const w = digitWidth(h);
        const t = @max(2, h * 0.11);
        const ghost = fade(color, self.p.ghost);
        var pen = x;
        for (s) |ch| {
            switch (ch) {
                '.' => {
                    try self.r.shape(.{ .x = pen, .y = y + h - t, .w = t, .h = t }, color, .{ .radii = @splat(t / 2) });
                    pen += t * 2;
                },
                ':' => {
                    try self.r.shape(.{ .x = pen, .y = y + h * 0.28, .w = t, .h = t }, color, .{ .radii = @splat(t / 2) });
                    try self.r.shape(.{ .x = pen, .y = y + h * 0.68, .w = t, .h = t }, color, .{ .radii = @splat(t / 2) });
                    pen += t * 2.2;
                },
                '%' => {
                    const sz = h * 0.2;
                    try self.r.shape(.{ .x = pen, .y = y + h * 0.1, .w = sz, .h = sz }, color, .{ .radii = @splat(sz / 2), .border = @max(1.5, t * 0.45) });
                    try self.r.shape(.{ .x = pen + w * 0.6 - sz, .y = y + h * 0.9 - sz, .w = sz, .h = sz }, color, .{ .radii = @splat(sz / 2), .border = @max(1.5, t * 0.45) });
                    try self.line(.{ pen + w * 0.6 - sz * 0.3, y + h * 0.1 }, .{ pen + sz * 0.3, y + h * 0.9 }, @max(1.5, t * 0.5), color);
                    pen += w * 0.6 + t;
                },
                else => {
                    const bits: u7 = if (ch >= '0' and ch <= '9') digit_segments[ch - '0'] else if (ch == '-') 0b1000000 else 0;
                    const l = pen + t / 2;
                    const r = pen + w - t / 2;
                    const top = y + t / 2;
                    const mid = y + h / 2;
                    const bot = y + h - t / 2;
                    const segs = [7][4]f32{ .{ l, top, r, top }, .{ r, top, r, mid }, .{ r, mid, r, bot }, .{ l, bot, r, bot }, .{ l, mid, l, bot }, .{ l, top, l, mid }, .{ l, mid, r, mid } };
                    if (ch != ' ' or self.p.ghost > 0) for (segs, 0..) |sg, i| {
                        const on = (bits >> @intCast(i)) & 1 == 1;
                        try self.segment(sg[0], sg[1], sg[2], sg[3], t, if (on) color else ghost, on);
                    };
                    pen += w + t;
                },
            }
        }
        return pen - x;
    }
    pub fn vfdWidth(h: f32, s: []const u8) f32 {
        const w = digitWidth(h);
        const t = @max(2, h * 0.11);
        var total: f32 = 0;
        for (s) |ch| total += switch (ch) {
            '.' => t * 2,
            ':' => t * 2.2,
            '%' => w * 0.6 + t,
            else => w + t,
        };
        return total;
    }
};

pub fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

test "vfd width accounts for every glyph kind" {
    try std.testing.expect(Ctx.vfdWidth(40, "12.5%") > Ctx.vfdWidth(40, "12"));
    try std.testing.expectEqual(Ctx.vfdWidth(40, "8"), Ctx.digitWidth(40) + 40 * 0.11);
}
