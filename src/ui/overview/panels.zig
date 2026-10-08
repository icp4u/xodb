//! The overview's destinations. Each draws from the current snapshot and
//! the view's history; unavailable values are hatched with their reason.
const std = @import("std");
const m = @import("model.zig");
const h = @import("history.zig");
const draw = @import("draw.zig");
const vw = @import("view.zig");
const View = vw.View;
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const Color = draw.Color;
const fade = draw.fade;
const Kind = vw.Kind;
const format = vw.format;

pub fn render(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    switch (v.panel) {
        .summary => try summary(v, ctx, rect, s, now),
        .performance => try performance(v, ctx, rect, s, now),
        .processes => try processes(v, ctx, rect, s, now),
        .memory => try memory(v, ctx, rect, s, now),
        .disk => try disks(v, ctx, rect, s, now),
        .disk_space => try diskSpace(v, ctx, rect, s),
        .network => try network(v, ctx, rect, s, now),
        .connections => try connections(v, ctx, rect, s),
        .power => try power(v, ctx, rect, s, now),
        .system => try system(v, ctx, rect, s),
        .users => try users(v, ctx, rect, s),
        .services => try services(v, ctx, rect, s),
        .apps => try apps(v, ctx, rect, s),
        .files => try @import("files_panel.zig").render(v, ctx, rect, now),
        .memory_map => try @import("memmap.zig").render(v, ctx, rect, now),
    }
}

// --- Widgets ------------------------------------------------------------------

const line_h: f32 = 22;

/// Card with a header label; returns the inner content rectangle.
fn card(ctx: Ctx, rect: Rect, label: []const u8, right: []const u8) !Rect {
    try ctx.panel(rect);
    // The label keeps priority; the right-hand note shows only where it fits.
    const label_w = @min(ctx.measure(label), rect.w - 24);
    try ctx.textFit(rect.x + 12, rect.y + 7, label_w + 1, label, ctx.p.dim);
    if (right.len > 0 and ctx.measure(right) + label_w + 24 + 56 <= rect.w) try ctx.textRight(rect.x + rect.w - 12, rect.y + 7, right, ctx.p.dim);
    return .{ .x = rect.x + 12, .y = rect.y + 32, .w = rect.w - 24, .h = rect.h - 42 };
}

/// An unavailable value: hatched chip with its reason, and the reason on hover.
fn missing(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, why: []const u8) !void {
    // A group not requested yet is sampled when its panel is shown.
    const reason = if (std.mem.eql(u8, why, "not collected")) "sampled when shown" else why;
    const tw = @min(w, ctx.measure(reason) + 12);
    const r = Rect{ .x = x, .y = y + 1, .w = tw, .h = 18 };
    try ctx.hatchLight(r);
    try ctx.textFit(x + 6, y, tw - 8, reason, ctx.p.dim);
    v.hover(r, "Unavailable: {s}", .{reason});
}
fn missingRight(v: *View, ctx: Ctx, right: f32, y: f32, w: f32, reason: []const u8) !void {
    const tw = @min(w, ctx.measure(reason) + 12);
    try missing(v, ctx, right - tw, y, tw, reason);
}

fn value(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, f: m.F, kind: Kind, color: Color) !void {
    var b: [48]u8 = undefined;
    if (f.get()) |x_| {
        try ctx.textFit(x, y, w, format(&b, kind, @floatCast(x_)), if (f.status == .stale) ctx.p.dim else color);
        if (f.status == .stale) v.hover(.{ .x = x, .y = y, .w = w, .h = 20 }, "Stale: {s}", .{f.reason});
    } else try missing(v, ctx, x, y, w, f.reason);
}
fn valueRight(v: *View, ctx: Ctx, right: f32, y: f32, w: f32, f: m.F, kind: Kind, color: Color) !void {
    var b: [48]u8 = undefined;
    if (f.get()) |x_| {
        const t = format(&b, kind, @floatCast(x_));
        try ctx.textRight(right, y, t, if (f.status == .stale) ctx.p.dim else color);
    } else try missingRight(v, ctx, right, y, w, f.reason);
}
/// Dense-table form of `missing`: a small hatched cell, the reason on hover
/// and once per column in the table footnote.
fn cell(v: *View, ctx: Ctx, right: f32, y: f32, w: f32, reason: []const u8, note: *[]const u8) !void {
    const cw = @min(w, 46);
    const r = Rect{ .x = right - cw, .y = y + 3, .w = cw, .h = 15 };
    try ctx.hatch(r);
    v.hover(r, "Unavailable: {s}", .{reason});
    if (note.len == 0) note.* = reason;
}

fn fromU(u: m.U) m.F {
    return .{ .status = u.status, .value = @floatFromInt(u.value), .reason = u.reason };
}
fn text(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, t: m.Text, color: Color) !void {
    if (t.ok()) try ctx.textFit(x, y, w, t.s, color) else try missing(v, ctx, x, y, w, t.why);
}
fn kv(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, key: []const u8, f: m.F, kind: Kind) !void {
    try ctx.text(x, y, key, ctx.p.dim);
    try valueRight(v, ctx, x + w, y, @max(40, w - ctx.measure(key) - 14), f, kind, ctx.p.text);
}
fn kvText(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, key: []const u8, t: m.Text) !void {
    try ctx.text(x, y, key, ctx.p.dim);
    const kw = @max(ctx.measure(key) + 16, w * 0.32);
    try text(v, ctx, x + kw, y, w - kw, t, ctx.p.text);
}

pub const Series = struct { ring: *const h.Ring, color: Color, label: []const u8 = "", fill: f32 = 0.30, sign: f32 = 1 };
pub const GraphOpts = struct {
    kind: Kind = .percent,
    max: ?f32 = null,
    scale: ?*h.Scale = null,
    /// Value at the bottom edge (sensor tiles zoom into their range).
    floor: f32 = 0,
    samples: usize = 120,
    smooth: bool = true,
    mirrored: bool = false,
    labels: bool = true,
    reason: []const u8 = "",
    width: f32 = 2,
};

/// History graph: anti-aliased traces over a gradient fill, adaptive
/// ceiling with a decaying peak, and hatching wherever a sample is missing.
pub fn graph(v: *View, ctx: Ctx, rect: Rect, series: []const Series, o: GraphOpts, now: u64) !void {
    const p = ctx.p;
    try ctx.r.shape(rect, fade(p.raised, 0.85), .{ .radii = @splat(4) });
    const n = @min(o.samples, h.capacity);
    var visible: f32 = 0;
    for (series) |sr| visible = @max(visible, sr.ring.max(n));
    const ceiling: f32 = o.max orelse if (o.scale) |sc| blk: {
        sc.observe(v.samples, visible);
        break :blk sc.ceiling();
    } else h.nice(@max(visible, 1));
    const saved = ctx.r.clip;
    ctx.r.clip = draw.intersect(saved, rect);
    defer ctx.r.clip = saved;
    const zero = if (o.mirrored) rect.y + rect.h / 2 else rect.y + rect.h;
    const span = if (o.mirrored) rect.h / 2 - 2 else rect.h - 2;
    // Grid.
    for (1..4) |i| {
        const y = rect.y + rect.h * @as(f32, @floatFromInt(i)) / 4;
        try ctx.r.rect(.{ .x = rect.x, .y = @round(y), .w = rect.w, .h = 1 }, p.grid);
    }
    for (1..6) |i| {
        const x = rect.x + rect.w * @as(f32, @floatFromInt(i)) / 6;
        try ctx.r.rect(.{ .x = @round(x), .y = rect.y, .w = 1, .h = rect.h }, fade(p.grid, 0.6));
    }
    if (o.mirrored) try ctx.r.rect(.{ .x = rect.x, .y = @round(zero), .w = rect.w, .h = 1 }, fade(p.dim, 0.4));
    const dx = rect.w / @as(f32, @floatFromInt(n - 1));
    const shift = (1 - v.ease(now)) * dx;
    // Missing samples: hatch the span instead of drawing zero.
    if (series.len > 0) {
        const ring = series[0].ring;
        var i: usize = 0;
        var any_measured = false;
        while (i <= n) : (i += 1) {
            if (i < ring.len and ring.back(i) == null) {
                var j = i;
                while (j + 1 <= n and j + 1 < ring.len and ring.back(j + 1) == null) j += 1;
                const x1 = rect.x + rect.w - @as(f32, @floatFromInt(i)) * dx + shift + dx / 2;
                const x0 = rect.x + rect.w - @as(f32, @floatFromInt(j)) * dx + shift - dx / 2;
                try ctx.hatch(.{ .x = @max(rect.x, x0), .y = rect.y, .w = @min(x1, rect.x + rect.w) - @max(rect.x, x0), .h = rect.h });
                i = j;
            } else if (i < ring.len) any_measured = true;
        }
        if (!any_measured) {
            const reason = if (o.reason.len > 0) o.reason else "no measured samples";
            try ctx.hatch(rect);
            const tw = @min(ctx.measure(reason), rect.w - 24);
            try ctx.r.shape(.{ .x = rect.x + rect.w / 2 - tw / 2 - 10, .y = rect.y + rect.h / 2 - 13, .w = tw + 20, .h = 26 }, p.panel, .{ .radii = @splat(5) });
            try ctx.textFit(rect.x + rect.w / 2 - tw / 2, rect.y + rect.h / 2 - 11, tw + 1, reason, p.dim);
            v.hover(rect, "Unavailable: {s}", .{reason});
        }
    }
    var raw: [h.capacity + 2]?[2]f32 = undefined;
    var smooth: [(h.capacity + 2) * 4]?[2]f32 = undefined;
    for (series) |sr| {
        for (0..n + 1) |i| {
            const val = sr.ring.back(i);
            raw[n - i] = if (val) |x| .{ rect.x + rect.w - @as(f32, @floatFromInt(i)) * dx + shift, zero - sr.sign * std.math.clamp((x - o.floor) / @max(ceiling - o.floor, 0.0001), 0, 1) * span } else null;
        }
        const pts: []const ?[2]f32 = if (o.smooth and dx >= 6) catmull(raw[0 .. n + 1], &smooth, zero, if (o.mirrored) rect.y else rect.y, rect.y + rect.h) else raw[0 .. n + 1];
        if (sr.fill > 0) {
            if (sr.sign > 0) try ctx.area(pts, zero, rect.y, sr.color, sr.fill) else try areaDown(ctx, pts, zero, rect.y + rect.h, sr.color, sr.fill);
        }
        try ctx.polyline(pts, o.width, sr.color, o.labels);
    }
    if (!o.labels) return;
    var b: [48]u8 = undefined;
    const top = format(&b, o.kind, ceiling);
    try ctx.r.shape(.{ .x = rect.x + 4, .y = rect.y + 3, .w = ctx.measure(top) + 10, .h = 19 }, fade(p.panel, 0.8), .{ .radii = @splat(4) });
    try ctx.text(rect.x + 9, rect.y + 2, top, p.dim);
    if (o.mirrored) {
        try ctx.r.shape(.{ .x = rect.x + 4, .y = rect.y + rect.h - 22, .w = ctx.measure(top) + 10, .h = 19 }, fade(p.panel, 0.8), .{ .radii = @splat(4) });
        try ctx.text(rect.x + 9, rect.y + rect.h - 23, top, p.dim);
    }
    // Legend, right-aligned: label and newest value per series, never over the axis label.
    const axis_end = rect.x + 9 + ctx.measure(top) + 8;
    var x = rect.x + rect.w - 8;
    var i = series.len;
    while (i > 0) {
        i -= 1;
        const sr = series[i];
        if (sr.label.len == 0) continue;
        var lb: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&lb, "{s} {s}", .{ sr.label, format(&b, o.kind, sr.ring.last()) }) catch sr.label;
        const w = ctx.measure(label) + 22;
        if (x - w < axis_end) break;
        x -= w;
        try ctx.r.shape(.{ .x = x, .y = rect.y + 3, .w = w, .h = 19 }, fade(p.panel, 0.8), .{ .radii = @splat(4) });
        try ctx.r.shape(.{ .x = x + 6, .y = rect.y + 9, .w = 8, .h = 8 }, sr.color, .{ .radii = @splat(4) });
        try ctx.text(x + 18, rect.y + 2, label, p.text);
        x -= 6;
    }
}

fn areaDown(ctx: Ctx, points: []const ?[2]f32, zero: f32, bottom: f32, color: Color, strength: f32) !void {
    const hgt = @max(1, bottom - zero);
    for (1..points.len) |i| {
        const a = points[i - 1] orelse continue;
        const b = points[i] orelse continue;
        const ca = fade(color, strength * (0.25 + 0.75 * (a[1] - zero) / hgt));
        const cb = fade(color, strength * (0.25 + 0.75 * (b[1] - zero) / hgt));
        const base = fade(color, strength * 0.1);
        try ctx.poly(&.{ .{ a[0], zero }, .{ b[0], zero }, b, a }, &.{ base, base, cb, ca });
    }
}

/// Catmull-Rom subdivision (3 steps per segment), clamped to the plot.
fn catmull(src: []const ?[2]f32, out: []?[2]f32, _: f32, lo: f32, hi: f32) []const ?[2]f32 {
    var k: usize = 0;
    for (0..src.len) |i| {
        const p1 = src[i] orelse {
            out[k] = null;
            k += 1;
            continue;
        };
        out[k] = p1;
        k += 1;
        if (i + 1 >= src.len) break;
        const p2 = src[i + 1] orelse continue;
        const p0 = if (i > 0) src[i - 1] orelse p1 else p1;
        const p3 = if (i + 2 < src.len) src[i + 2] orelse p2 else p2;
        for ([_]f32{ 0.25, 0.5, 0.75 }) |t| {
            const t2 = t * t;
            const t3 = t2 * t;
            var q: [2]f32 = undefined;
            for (0..2) |d| q[d] = 0.5 * ((2 * p1[d]) + (-p0[d] + p2[d]) * t + (2 * p0[d] - 5 * p1[d] + 4 * p2[d] - p3[d]) * t2 + (-p0[d] + 3 * p1[d] - 3 * p2[d] + p3[d]) * t3);
            q[1] = std.math.clamp(q[1], lo, hi);
            if (k < out.len) out[k] = q;
            k += 1;
        }
    }
    return out[0..@min(k, out.len)];
}

/// Arc gauge with a VFD readout in the middle.
fn gauge(v: *View, ctx: Ctx, rect: Rect, label: []const u8, f: m.F, max: f64, readout: []const u8, sub: []const u8, color: Color, prev: ?f64, now: u64) !void {
    const p = ctx.p;
    const inner = try card(ctx, rect, label, "");
    const radius = @min(inner.w * 0.4, (inner.h - 30) / 2) - 2;
    const cx = inner.x + inner.w / 2;
    const cy = inner.y + radius + 6;
    const a0: f32 = std.math.pi * 0.75;
    const sweep: f32 = std.math.pi * 1.5;
    try ctx.arc(cx, cy, radius, 10, a0, a0 + sweep, fade(p.grid, 2.2));
    for (0..11) |i| {
        const t = a0 + sweep * @as(f32, @floatFromInt(i)) / 10;
        try ctx.thin(.{ cx + @cos(t) * (radius - 14), cy + @sin(t) * (radius - 14) }, .{ cx + @cos(t) * (radius - 9), cy + @sin(t) * (radius - 9) }, 1.2, fade(p.dim, 0.6));
    }
    if (f.get()) |x| {
        const shown = if (prev) |pv| pv + (x - pv) * v.ease(now) else x;
        const frac: f32 = @floatCast(std.math.clamp(shown / max, 0, 1));
        const c = if (p.monochrome) color else if (frac > 0.9) p.crit else if (frac > 0.75) p.warn else color;
        try ctx.arc(cx, cy, radius, 10, a0, a0 + sweep * frac, c);
        const dh = radius * 0.42;
        const w = Ctx.vfdWidth(dh, readout);
        _ = try ctx.vfd(cx - w / 2, cy - dh * 0.62, dh, readout, c);
    } else {
        const w = @min(inner.w - 20, ctx.measure(f.reason) + 16);
        try ctx.hatch(.{ .x = cx - w / 2, .y = cy - 14, .w = w, .h = 26 });
        try ctx.text(cx - w / 2 + 8, cy - 12, f.reason, p.hatch);
        v.hover(.{ .x = cx - radius, .y = cy - radius, .w = radius * 2, .h = radius * 2 }, "{s} unavailable: {s}", .{ label, f.reason });
    }
    const sw = ctx.measure(sub);
    try ctx.textFit(@max(inner.x, cx - sw / 2), cy + radius * 0.78, inner.w, sub, p.dim);
}

fn prevF(prev: ?*const m.Snapshot, comptime field: []const u8) ?f64 {
    const s = prev orelse return null;
    return @field(s, field).get();
}

// --- Summary ------------------------------------------------------------------

fn summary(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const top_h = @min(280, rect.h * 0.3);
    const gw = (rect.w - gap * 3) / 4;
    var b: [64]u8 = undefined;
    var sb: [96]u8 = undefined;
    var t1: [24]u8 = undefined;
    var t2: [24]u8 = undefined;
    var t3: [24]u8 = undefined;
    // CPU gauge.
    {
        const readout = if (s.cpu_total.get()) |x| std.fmt.bufPrint(&b, "{d:.0}%", .{x}) catch "" else "";
        const sub = std.fmt.bufPrint(&sb, "load {s} {s} {s}", .{ num(&t1, s.load1), num(&t2, s.load5), num(&t3, s.load15) }) catch "";
        try gauge(v, ctx, .{ .x = rect.x, .y = rect.y, .w = gw, .h = top_h }, "CPU", s.cpu_total, 100, readout, sub, p.accent, prevF(v.prev(), "cpu_total"), now);
    }
    // Memory gauge.
    {
        const used = vw.pct(s.memory.used.get(), s.memory.total.get());
        const f: m.F = if (used) |u| m.F.of(u) else m.F.missing(if (s.memory.used.get() == null) s.memory.used.reason else s.memory.total.reason);
        const readout = if (used) |u| std.fmt.bufPrint(&b, "{d:.0}%", .{u}) catch "" else "";
        const sub = if (s.memory.used.get()) |u| (if (s.memory.total.get()) |t| std.fmt.bufPrint(&sb, "{s} of {s}", .{ m.bytes(&t1, @floatFromInt(u)), m.bytes(&t2, @floatFromInt(t)) }) catch "" else std.fmt.bufPrint(&sb, "{s} used · total: {s}", .{ m.bytes(&t1, @floatFromInt(u)), s.memory.total.reason }) catch "") else "";
        const pv: ?f64 = if (v.prev()) |ps| vw.pct(ps.memory.used.get(), ps.memory.total.get()) else null;
        try gauge(v, ctx, .{ .x = rect.x + gw + gap, .y = rect.y, .w = gw, .h = top_h }, "Memory", f, 100, readout, sub, p.accent3, pv, now);
    }
    // GPU gauge: the busiest measured device, or the first device's reason.
    {
        var f = m.F.missing("no GPU");
        var sub: []const u8 = "";
        var pv: ?f64 = null;
        if (s.gpus.len > 0) {
            var g = s.gpus[0];
            for (s.gpus) |x| if (x.busy.get()) |busy| {
                if (g.busy.get() == null or busy > g.busy.get().?) g = x;
            };
            f = g.busy;
            sub = if (g.power_w.get()) |w| std.fmt.bufPrint(&sb, "{s} {s} · {d:.1} W", .{ g.card, g.driver, w }) catch "" else std.fmt.bufPrint(&sb, "{s} · power {s}", .{ g.card, g.power_w.reason }) catch "";
            if (v.prev()) |ps| for (ps.gpus) |x| if (std.mem.eql(u8, x.card, g.card)) {
                pv = x.busy.get();
            };
        }
        const readout = if (f.get()) |x| std.fmt.bufPrint(&b, "{d:.0}%", .{x}) catch "" else "";
        try gauge(v, ctx, .{ .x = rect.x + 2 * (gw + gap), .y = rect.y, .w = gw, .h = top_h }, "GPU", f, 100, readout, sub, p.accent2, pv, now);
    }
    // CPU temperature.
    {
        const f = s.cpu_package_temp;
        const readout = if (f.get()) |x| std.fmt.bufPrint(&b, "{d:.0}", .{x}) catch "" else "";
        const sub = if (s.cpu_package_power.get()) |w| std.fmt.bufPrint(&sb, "°C · package {d:.1} W", .{w}) catch "" else std.fmt.bufPrint(&sb, "°C · package power: {s}", .{s.cpu_package_power.reason}) catch "";
        try gauge(v, ctx, .{ .x = rect.x + 3 * (gw + gap), .y = rect.y, .w = gw, .h = top_h }, "CPU temperature", f, 100, readout, sub, p.warn, prevF(v.prev(), "cpu_package_temp"), now);
    }
    // History row.
    const mid_y = rect.y + top_h + gap;
    const mid_h = (rect.h - top_h - gap * 2) * 0.5;
    const hw = (rect.w - gap * 2) / 3;
    const H = v.hist;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = mid_y, .w = hw, .h = mid_h }, "CPU history", "user · system");
        try graph(v, ctx, inner, &.{ .{ .ring = &H.cpu_total, .color = p.accent, .label = "busy" }, .{ .ring = &H.cpu_system, .color = p.accent2, .fill = 0.15, .label = "sys" } }, .{ .max = 100 }, now);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + hw + gap, .y = mid_y, .w = hw, .h = mid_h }, "Disk throughput", "read ▲  write ▼");
        try graph(v, ctx, inner, &.{ .{ .ring = &H.disk_read, .color = p.accent, .label = "read" }, .{ .ring = &H.disk_write, .color = p.accent2, .label = "write", .sign = -1 } }, .{ .kind = .rate, .scale = &H.scales[@intFromEnum(vw.ScaleId.disk_total)], .mirrored = true, .reason = s.group(.disks).reason }, now);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + 2 * (hw + gap), .y = mid_y, .w = hw, .h = mid_h }, "Network", "receive ▲  send ▼");
        try graph(v, ctx, inner, &.{ .{ .ring = &H.net_rx, .color = p.accent3, .label = "rx" }, .{ .ring = &H.net_tx, .color = p.accent2, .label = "tx", .sign = -1 } }, .{ .kind = .rate, .scale = &H.scales[@intFromEnum(vw.ScaleId.net_total)], .mirrored = true, .reason = if (s.group(.network).status != .ok) s.group(.network).reason else if (s.net_rx_bps.get() == null) s.net_rx_bps.reason else s.net_tx_bps.reason }, now);
    }
    // Bottom row: top processes, facts, and the honesty card.
    const low_y = mid_y + mid_h + gap;
    const low_h = rect.y + rect.h - low_y;
    if (low_h < 80) return;
    const lw = (rect.w - gap * 2) / 3;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = low_y, .w = lw, .h = low_h }, "Top processes by CPU", "3 opens Processes");
        try topProcesses(v, ctx, inner, s);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + lw + gap, .y = low_y, .w = lw, .h = low_h }, "System", "");
        var y = inner.y;
        const w = inner.w;
        try kv(v, ctx, inner.x, y, w, "Processes", fromU(s.process_count), .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, w, "Threads", fromU(s.thread_count), .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, w, "Running / blocked", fromU(s.running), .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, w, "Context switches /s", s.context_switches_ps, .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, w, "Forks /s", s.forks_ps, .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, w, "Swap used", fromU(s.memory.swap_used), .bytes);
        y += line_h;
        if (y + line_h < inner.y + inner.h) {
            try kv(v, ctx, inner.x, y, w, "Fullest filesystem", fullestMount(s), .percent);
            y += line_h;
        }
        const more = [_]struct { []const u8, m.F, Kind }{
            .{ "Memory pressure (some, 10 s)", s.psi_memory.some10, .percent },
            .{ "I/O pressure (some, 10 s)", s.psi_io.some10, .percent },
            .{ "CPU pressure (some, 10 s)", s.psi_cpu.some10, .percent },
            .{ "Interrupts /s", s.interrupts_ps, .count },
            .{ "Load (1 min)", s.load1, .plain },
            .{ "Uptime (days)", if (s.uptime_s.get()) |u| m.F.of(u / 86400) else s.uptime_s, .plain },
            .{ "Network receive", s.net_rx_bps, .rate },
            .{ "Network send", s.net_tx_bps, .rate },
            .{ "Battery", s.battery_pct, .percent },
        };
        for (more) |row| {
            if (y + line_h > inner.y + inner.h) break;
            try kv(v, ctx, inner.x, y, w, row[0], row[1], row[2]);
            y += line_h;
        }
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + 2 * (lw + gap), .y = low_y, .w = lw, .h = low_h }, "Not measured right now", "never shown as zero");
        try honesty(v, ctx, inner, s);
    }
}

fn num(buf: []u8, f: m.F) []const u8 {
    return if (f.get()) |x| std.fmt.bufPrint(buf, "{d:.2}", .{x}) catch "?" else "—";
}
fn fullestMount(s: *const m.Snapshot) m.F {
    var best: ?f64 = null;
    for (s.mounts) |mount| if (mount.used_pct.get()) |x| {
        best = @max(best orelse 0, x);
    };
    return if (best) |x| m.F.of(x) else m.F.missing(s.group(.filesystems).reason);
}

fn topProcesses(v: *View, ctx: Ctx, inner: Rect, s: *const m.Snapshot) !void {
    var best: [24]?usize = @splat(null);
    for (s.processes, 0..) |proc, i| {
        const c = proc.cpu.get() orelse continue;
        for (&best, 0..) |*slot, k| {
            if (slot.* == null or c > (s.processes[slot.*.?].cpu.get() orelse -1)) {
                var j: usize = best.len - 1;
                while (j > k) : (j -= 1) best[j] = best[j - 1];
                slot.* = i;
                break;
            }
        }
    }
    if (best[0] == null) return missing(v, ctx, inner.x, inner.y, inner.w, if (s.group(.processes).status != .ok) s.group(.processes).reason else "no CPU rates yet (first sample)");
    var y = inner.y;
    for (best) |slot| {
        const i = slot orelse break;
        if (y + line_h > inner.y + inner.h) break;
        const proc = s.processes[i];
        var nb: [24]u8 = undefined;
        try ctx.textFit(inner.x, y, inner.w * 0.44 - 16, vw.processName(v, &proc, &nb), ctx.p.text);
        var b: [16]u8 = undefined;
        try ctx.text(inner.x + inner.w * 0.44, y, std.fmt.bufPrint(&b, "{d}", .{proc.pid}) catch "", ctx.p.dim);
        try ctx.bar(.{ .x = inner.x + inner.w * 0.58, .y = y + 7, .w = inner.w * 0.24, .h = 7 }, (proc.cpu.get() orelse 0) / 100, ctx.p.accent);
        try valueRight(v, ctx, inner.x + inner.w, y, inner.w * 0.16, proc.cpu, .percent, ctx.p.text);
        y += line_h;
    }
}

/// Lists every top-level item that is not measured now, with its reason.
fn honesty(v: *View, ctx: Ctx, inner: Rect, s: *const m.Snapshot) !void {
    var y = inner.y;
    var shown: usize = 0;
    const Item = struct { label: []const u8, reason: []const u8 };
    var list: [48]Item = undefined;
    var count: usize = 0;
    const add = struct {
        fn f(l: *[48]Item, c: *usize, label: []const u8, reason: []const u8) void {
            if (c.* < l.len) {
                l[c.*] = .{ .label = label, .reason = reason };
                c.* += 1;
            }
        }
    }.f;
    inline for (std.meta.fields(m.Group), 0..) |g, i| {
        const st = s.groups[i];
        if (st.status != .ok and !std.mem.eql(u8, st.reason, "not collected")) add(&list, &count, g.name, if (st.detail.len > 0) st.detail else st.reason);
    }
    if (s.cpu_package_power.get() == null) add(&list, &count, "CPU package power", s.cpu_package_power.reason);
    if (s.cpu_package_temp.get() == null) add(&list, &count, "CPU temperature", s.cpu_package_temp.reason);
    if (s.cpus.len > 0 and s.cpus[0].temp_c.get() == null) add(&list, &count, "Per-core temperature", s.cpus[0].temp_c.reason);
    for (s.gpus) |g| {
        if (g.busy.get() == null) add(&list, &count, "GPU busy", g.busy.reason);
        if (g.power_w.get() == null) add(&list, &count, "GPU power", g.power_w.reason);
    }
    var unresolved_fds: usize = 0;
    var fd_reason: []const u8 = "not collected";
    var net_reason: []const u8 = "";
    for (s.processes) |proc| {
        if (proc.fds.get() == null) {
            unresolved_fds += 1;
            fd_reason = proc.fds.reason;
        }
        if (proc.net_bps.get() == null) net_reason = proc.net_bps.reason;
    }
    if (net_reason.len > 0) add(&list, &count, "Per-process network", net_reason);
    var fb: [64]u8 = undefined;
    if (unresolved_fds > 0) add(&list, &count, std.fmt.bufPrint(&fb, "Open files of {d} processes", .{unresolved_fds}) catch "Open files", if (std.mem.eql(u8, fd_reason, "not collected")) "sampled on Processes" else fd_reason);
    if (s.owners_unresolved.get()) |n| if (n > 0) add(&list, &count, "Socket owners", "needs privilege");
    if (count == 0) {
        try ctx.text(inner.x, y, "Everything requested was measured.", ctx.p.ok);
        return;
    }
    for (list[0..count]) |item| {
        if (y + line_h > inner.y + inner.h) {
            var mb: [32]u8 = undefined;
            try ctx.text(inner.x, y - 2, std.fmt.bufPrint(&mb, "+{d} more", .{count - shown}) catch "", ctx.p.dim);
            break;
        }
        try ctx.r.shape(.{ .x = inner.x, .y = y + 6, .w = 8, .h = 8 }, ctx.p.hatch, .{ .radii = @splat(4) });
        try ctx.textFit(inner.x + 16, y, inner.w * 0.5 - 16, item.label, ctx.p.text);
        try missingRight(v, ctx, inner.x + inner.w, y, inner.w * 0.5, item.reason);
        y += line_h;
        shown += 1;
    }
}

// --- Performance ----------------------------------------------------------------

fn performance(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const top_h = @min(220, rect.h * 0.28);
    const H = v.hist;
    // Headline: VFD total and facts, then the big graph.
    const left_w: f32 = 300;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = rect.y, .w = left_w, .h = top_h }, "Total CPU", if (s.cpu_model.ok()) "" else s.cpu_model.why);
        var b: [32]u8 = undefined;
        if (s.cpu_total.get()) |x| {
            const t = std.fmt.bufPrint(&b, "{d:.1}%", .{x}) catch "";
            _ = try ctx.vfd(inner.x, inner.y + 4, 64, t, p.accent);
        } else try missing(v, ctx, inner.x, inner.y + 20, inner.w, s.cpu_total.reason);
        var y = inner.y + 84;
        var mhz: f64 = 0;
        var n: f64 = 0;
        var max_mhz: f64 = 0;
        for (s.cpus) |c| if (c.mhz.get()) |x| {
            mhz += x;
            n += 1;
            max_mhz = @max(max_mhz, x);
        };
        try kv(v, ctx, inner.x, y, inner.w, "Average clock", if (n > 0) m.F.of(mhz / n) else m.F.missing(if (s.cpus.len > 0) s.cpus[0].mhz.reason else "no CPUs"), .mhz);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "Fastest core", if (n > 0) m.F.of(max_mhz) else m.F.missing("no frequency"), .mhz);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "Package", s.cpu_package_temp, .celsius);
        y += line_h;
        if (y + line_h <= inner.y + inner.h) try kv(v, ctx, inner.x, y, inner.w, "Package power", s.cpu_package_power, .watts);
    }
    {
        var rb: [96]u8 = undefined;
        const right = std.fmt.bufPrint(&rb, "{s} · {s}", .{ if (s.freq_driver.ok()) s.freq_driver.s else "driver ?", if (s.governor.ok()) s.governor.s else "governor ?" }) catch "";
        const inner = try card(ctx, .{ .x = rect.x + left_w + gap, .y = rect.y, .w = rect.w - left_w - gap, .h = top_h }, if (s.cpu_model.ok()) s.cpu_model.s else "CPU", right);
        try graph(v, ctx, inner, &.{ .{ .ring = &H.cpu_total, .color = p.accent, .label = "busy" }, .{ .ring = &H.cpu_user, .color = p.accent3, .fill = 0, .label = "user", .sign = 1 }, .{ .ring = &H.cpu_system, .color = p.accent2, .fill = 0.12, .label = "system" } }, .{ .max = 100, .samples = 180 }, now);
    }
    // Per-CPU grid grouped by package and cache domain.
    const grid = Rect{ .x = rect.x, .y = rect.y + top_h + gap, .w = rect.w, .h = rect.h - top_h - gap };
    const count = @min(s.cpus.len, 512);
    if (count == 0) return missing(v, ctx, grid.x, grid.y, grid.w, s.group(.cpu).reason);
    var order: [512]u16 = undefined;
    for (0..count) |i| order[i] = @intCast(i);
    // Unknown topology: one group in CPU-number order, labelled with the reason.
    const topology_why = topologyWhy(s);
    if (topology_why.len == 0) std.mem.sort(u16, order[0..count], s.cpus, struct {
        fn less(cpus: []const m.Cpu, a: u16, b: u16) bool {
            const x = cpus[a];
            const y = cpus[b];
            if (x.package != y.package) return x.package < y.package;
            if (x.cache != y.cache) return x.cache < y.cache;
            if (x.core != y.core) return x.core < y.core;
            if (x.smt != y.smt) return x.smt < y.smt;
            return x.id < y.id;
        }
    }.less);
    // Domains: runs of equal (package, cache).
    var domains: [64][2]u16 = undefined; // start, end in order
    var dn: usize = 0;
    var start: usize = 0;
    for (1..count + 1) |i| {
        if (i == count or (topology_why.len == 0 and (s.cpus[order[i]].package != s.cpus[order[start]].package or s.cpus[order[i]].cache != s.cpus[order[start]].cache))) {
            if (dn < domains.len) {
                domains[dn] = .{ @intCast(start), @intCast(i) };
                dn += 1;
            }
            start = i;
        }
    }
    // Columns per domain: domains side by side when few, stacked otherwise.
    const per_row_domains: usize = if (dn <= 2) dn else if (dn <= 4) 2 else 4;
    const domain_rows = (dn + per_row_domains - 1) / per_row_domains;
    const dw = (grid.w - gap * @as(f32, @floatFromInt(per_row_domains - 1))) / @as(f32, @floatFromInt(per_row_domains));
    const dh = (grid.h - gap * @as(f32, @floatFromInt(domain_rows - 1))) / @as(f32, @floatFromInt(domain_rows));
    for (domains[0..dn], 0..) |d, di| {
        const col = di % per_row_domains;
        const row = di / per_row_domains;
        const box = Rect{ .x = grid.x + @as(f32, @floatFromInt(col)) * (dw + gap), .y = grid.y + @as(f32, @floatFromInt(row)) * (dh + gap), .w = dw, .h = dh };
        const first = s.cpus[order[d[0]]];
        var lb: [96]u8 = undefined;
        var cores: usize = 0;
        for (d[0]..d[1]) |i| {
            if (s.cpus[order[i]].smt == 0) cores += 1;
        }
        const label = if (topology_why.len > 0)
            std.fmt.bufPrint(&lb, "{d} logical CPUs · topology unavailable: {s}", .{ d[1] - d[0], topology_why }) catch ""
        else
            std.fmt.bufPrint(&lb, "Package {d} · L3 domain {d} · {d} cores / {d} threads", .{ first.package, first.cache, cores, d[1] - d[0] }) catch "";
        var temp_b: [48]u8 = undefined;
        const temp_label: []const u8 = if (di < s.cpu_temps.len) (if (s.cpu_temps[di].value.get()) |t| std.fmt.bufPrint(&temp_b, "{s} {d:.1} °C", .{ s.cpu_temps[di].label, t }) catch "" else "") else "";
        const inner = try card(ctx, box, label, temp_label);
        if (!someCoreTemps(s) and s.cpus[0].temp_c.reason.len > 0) v.hover(.{ .x = box.x, .y = box.y, .w = box.w, .h = 30 }, "Per-core temperature: {s}; package and CCD sensors are on Power & Thermals", .{s.cpus[0].temp_c.reason});
        const n = d[1] - d[0];
        // Tile layout: as square-ish as fits.
        var cols: usize = 1;
        while (cols < n) : (cols += 1) {
            const rows_ = (n + cols - 1) / cols;
            const tw = inner.w / @as(f32, @floatFromInt(cols));
            const th = inner.h / @as(f32, @floatFromInt(rows_));
            if (tw / th < 2.2) break;
        }
        const rows = (n + cols - 1) / cols;
        const tw = (inner.w - 6 * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
        const th = (inner.h - 6 * @as(f32, @floatFromInt(rows - 1))) / @as(f32, @floatFromInt(rows));
        for (d[0]..d[1], 0..) |oi, k| {
            const ci = order[oi];
            const tile = Rect{ .x = inner.x + @as(f32, @floatFromInt(k % cols)) * (tw + 6), .y = inner.y + @as(f32, @floatFromInt(k / cols)) * (th + 6), .w = tw, .h = th };
            if (ctx.r.used() > 0.85) break;
            try cpuTile(v, ctx, tile, s, ci, now);
        }
    }
}

/// The first CPU's topology reason when any CPU's topology is unknown.
fn topologyWhy(s: *const m.Snapshot) []const u8 {
    for (s.cpus) |c| if (c.topology_why.len > 0) return c.topology_why;
    return "";
}

/// Per-core temperature hatching only helps when some cores have it; when
/// none do, the domain header says why once.
fn someCoreTemps(s: *const m.Snapshot) bool {
    for (s.cpus) |c| if (c.temp_c.get() != null) return true;
    return false;
}

fn cpuTile(v: *View, ctx: Ctx, tile: Rect, s: *const m.Snapshot, index: usize, now: u64) !void {
    const p = ctx.p;
    const c = s.cpus[index];
    try ctx.r.shape(tile, p.raised, .{ .radii = @splat(4) });
    // SMT siblings share a tint so the core pairing reads at a glance.
    const known = c.topology_why.len == 0;
    if (known and c.smt > 0) try ctx.r.rect(.{ .x = tile.x, .y = tile.y + 4, .w = 2, .h = tile.h - 8 }, fade(p.accent3, 0.5));
    var lb: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "CPU {d}", .{c.id}) catch "";
    try ctx.text(tile.x + 8, tile.y + 2, label, p.text);
    var cb: [32]u8 = undefined;
    const core = std.fmt.bufPrint(&cb, "core {d}", .{c.core}) catch "";
    if (known and tile.w > ctx.measure(label) + ctx.measure(core) + 100) try ctx.text(tile.x + 22 + ctx.measure(label), tile.y + 2, core, p.dim);
    if (c.online == false) return missing(v, ctx, tile.x + 8, tile.y + 24, tile.w - 16, "offline");
    // VFD readout of this CPU's busy share.
    if (c.total.get()) |busy| {
        var vb: [16]u8 = undefined;
        const t = std.fmt.bufPrint(&vb, "{d:.0}%", .{busy}) catch "";
        const dh: f32 = if (tile.h >= 70) 20 else 14;
        const hot = !p.monochrome and busy > 90;
        _ = try ctx.vfd(tile.x + tile.w - 8 - Ctx.vfdWidth(dh, t), tile.y + 3, dh, t, if (hot) p.warn else p.accent);
    } else try missingRight(v, ctx, tile.x + tile.w - 8, tile.y + 2, 90, c.total.reason);
    const has_graph = tile.h >= 70;
    const meter_y = tile.y + tile.h - (if (tile.h >= 54) @as(f32, 34) else 16);
    if (has_graph) {
        const g = Rect{ .x = tile.x + 6, .y = tile.y + 24, .w = tile.w - 12, .h = meter_y - tile.y - 28 };
        const samples: usize = @intFromFloat(std.math.clamp(g.w / 5, 16, 60));
        if (g.h > 12) try graph(v, ctx, g, &.{.{ .ring = &v.hist.cpus[index], .color = p.accent, .fill = 0.35 }}, .{ .max = 100, .samples = samples, .smooth = false, .labels = false, .width = 1.5 }, now);
    }
    const prev_total: ?f64 = if (v.prev()) |ps| if (index < ps.cpus.len) ps.cpus[index].total.get() else null else null;
    const shown: ?f64 = if (c.total.get()) |x| (if (prev_total) |pv| pv + (x - pv) * v.ease(now) else x) / 100 else null;
    try ctx.segments(.{ .x = tile.x + 8, .y = meter_y, .w = tile.w - 16, .h = 10 }, shown, p.accent);
    if (tile.h >= 54) {
        var fb: [32]u8 = undefined;
        if (c.mhz.get()) |mhz| try ctx.text(tile.x + 8, meter_y + 12, std.fmt.bufPrint(&fb, "{d:.0} MHz", .{mhz}) catch "", p.dim) else try missing(v, ctx, tile.x + 8, meter_y + 12, tile.w * 0.5, c.mhz.reason);
        if (c.temp_c.get()) |t| try ctx.textRight(tile.x + tile.w - 8, meter_y + 12, std.fmt.bufPrint(&fb, "{d:.0} °C", .{t}) catch "", p.dim) else if (someCoreTemps(s)) {
            const r = Rect{ .x = tile.x + tile.w - 34, .y = meter_y + 14, .w = 26, .h = 16 };
            try ctx.hatch(r);
            v.hover(r, "CPU {d} temperature: {s}", .{ c.id, c.temp_c.reason });
        }
    }
    if (!known) v.hover(tile, "CPU {d}: topology unavailable: {s}", .{ c.id, c.topology_why }) else if (c.online == null) v.hover(tile, "CPU {d}: online state unavailable: {s}", .{ c.id, c.online_why }) else v.hover(tile, "CPU {d}: package {d}, L3 {d}, core {d}, thread {d}", .{ c.id, c.package, c.cache, c.core, c.smt });
}

// --- Processes ----------------------------------------------------------------

const Column = struct { label: []const u8, width: f32, sort: ?vw.Sort, right: bool = true };

fn processes(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    try v.buildRows();
    // Toolbar: search, sort, tree.
    const bar_h: f32 = 34;
    try ctx.r.shape(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = bar_h }, p.panel, .{ .radii = @splat(6) });
    const narrow = rect.w < 1400;
    const search = Rect{ .x = rect.x + 8, .y = rect.y + 5, .w = if (narrow) rect.w * 0.2 else @min(360, rect.w * 0.3), .h = 24 };
    try ctx.r.shape(search, p.raised, .{ .radii = @splat(5) });
    try ctx.r.shape(search, if (v.searching) p.accent else p.border, .{ .radii = @splat(5), .border = 1 });
    v.hit(search, .search);
    const q = v.searchText();
    if (q.len > 0 or v.searching) {
        try ctx.textFit(search.x + 8, search.y + 2, search.w - 16, q, p.text);
        if (v.searching) try ctx.r.rect(.{ .x = search.x + 9 + ctx.measure(q), .y = search.y + 4, .w = 2, .h = 16 }, p.accent);
    } else try ctx.textFit(search.x + 8, search.y + 2, search.w - 16, "/ search name, pid or command", p.dim);
    var x = search.x + search.w + 14;
    if (!narrow) {
        try ctx.text(x, rect.y + 7, "sort", p.dim);
        x += ctx.measure("sort") + 8;
    }
    for (vw.sort_names, 0..) |name, i| {
        const sort: vw.Sort = @enumFromInt(i);
        const on = v.sort == sort;
        var nb: [24]u8 = undefined;
        const label = if (on) std.fmt.bufPrint(&nb, "{s} {s}", .{ name, if (v.descending) "▼" else "▲" }) catch name else name;
        const w = ctx.measure(label) + 16;
        const chip = Rect{ .x = x, .y = rect.y + 6, .w = w, .h = 22 };
        try ctx.r.shape(chip, if (on) fade(p.accent, 0.18) else fade(p.raised, 1), .{ .radii = @splat(11) });
        if (on) try ctx.r.shape(chip, fade(p.accent, 0.7), .{ .radii = @splat(11), .border = 1 });
        try ctx.text(x + 8, rect.y + 7, label, if (on) p.accent else p.dim);
        v.hit(chip, .{ .sort = sort });
        x += w + 4;
    }
    {
        const label = if (v.tree) "tree ✓" else "tree";
        const w = ctx.measure(label) + 16;
        const chip = Rect{ .x = x + 8, .y = rect.y + 6, .w = w, .h = 22 };
        try ctx.r.shape(chip, if (v.tree) fade(p.accent3, 0.18) else p.raised, .{ .radii = @splat(11) });
        try ctx.text(chip.x + 8, rect.y + 7, label, if (v.tree) p.accent3 else p.dim);
        v.hit(chip, .tree);
        x = chip.x + chip.w;
    }
    // Row counts take the space left; the short form when narrow, none if no room.
    var cb: [96]u8 = undefined;
    const long = std.fmt.bufPrint(&cb, "{d} shown · {d} total{s}", .{ v.rows.items.len, s.processes.len, if (s.processes_truncated > 0) " · truncated" else "" }) catch "";
    var cb2: [48]u8 = undefined;
    const counts = if (ctx.measure(long) + 20 < rect.x + rect.w - 10 - x) long else std.fmt.bufPrint(&cb2, "{d}/{d}", .{ v.rows.items.len, s.processes.len }) catch "";
    if (ctx.measure(counts) + 20 < rect.x + rect.w - 10 - x) try ctx.textRight(rect.x + rect.w - 10, rect.y + 7, counts, p.dim);

    // Detail strip for the selection.
    const detail_h: f32 = 92;
    const table = Rect{ .x = rect.x, .y = rect.y + bar_h + 8, .w = rect.w, .h = rect.h - bar_h - 8 - detail_h - 8 };
    try ctx.panel(table);
    const wide = rect.w > 1300;
    const cols_all = [_]Column{
        .{ .label = "Name", .width = 0, .sort = .name, .right = false },
        .{ .label = "PID", .width = if (narrow) 56 else 70, .sort = .pid },
        .{ .label = "User", .width = if (narrow) 64 else 92, .sort = null, .right = false },
        .{ .label = "S", .width = 22, .sort = null, .right = false },
        .{ .label = "CPU", .width = if (narrow) 112 else 150, .sort = .cpu },
        .{ .label = "Memory", .width = if (narrow) 124 else 150, .sort = .memory },
        .{ .label = "Disk", .width = if (narrow) 104 else 104, .sort = .disk },
        .{ .label = "Net", .width = if (narrow) 50 else 104, .sort = .net },
        .{ .label = "Thr", .width = 54, .sort = .threads },
        .{ .label = "FDs", .width = 64, .sort = .fds },
        .{ .label = "Command", .width = 330, .sort = null, .right = false },
    };
    const cols: []const Column = if (wide) &cols_all else cols_all[0..10];
    var fixed: f32 = 0;
    for (cols[1..]) |c| fixed += c.width + 10;
    const name_w = @max(140, table.w - 24 - fixed);
    // Header.
    var cx = table.x + 12;
    const hy = table.y + 6;
    for (cols, 0..) |c, i| {
        const w = if (i == 0) name_w else c.width;
        const on = c.sort != null and c.sort.? == v.sort;
        var lb: [24]u8 = undefined;
        const label = if (on) std.fmt.bufPrint(&lb, "{s}{s}", .{ c.label, if (v.descending) " ▼" else " ▲" }) catch c.label else c.label;
        if (c.right) try ctx.textRight(cx + w, hy, label, if (on) p.accent else p.dim) else try ctx.text(cx, hy, label, if (on) p.accent else p.dim);
        if (c.sort) |sort| v.hit(.{ .x = cx, .y = hy, .w = w, .h = 22 }, .{ .sort = sort });
        cx += w + 10;
    }
    try ctx.r.rect(.{ .x = table.x + 8, .y = table.y + 30, .w = table.w - 16, .h = 1 }, p.border);
    const row_h: f32 = 24;
    const body = Rect{ .x = table.x, .y = table.y + 34, .w = table.w, .h = table.h - 38 };
    v.visible_rows = @max(1, @as(usize, @intFromFloat((body.h - 22) / row_h)));
    const top = &v.scroll[@intFromEnum(vw.Panel.processes)];
    top.* = @min(top.*, v.rows.items.len -| v.visible_rows);
    if (v.rows.items.len == 0) {
        try missing(v, ctx, body.x + 12, body.y + 8, body.w - 24, if (s.group(.processes).status != .ok) s.group(.processes).reason else if (q.len > 0) "no process matches the search" else "no processes");
    }
    const total_mem: f64 = @floatFromInt(s.memory.total.get() orelse 1);
    var max_rss: f64 = 1;
    var max_io: f64 = 1;
    for (s.processes) |proc| {
        max_rss = @max(max_rss, @as(f64, @floatFromInt(proc.rss.get() orelse 0)));
        max_io = @max(max_io, (proc.read_bps.get() orelse 0) + (proc.write_bps.get() orelse 0));
    }
    _ = total_mem;
    var notes: [11][]const u8 = @splat("");
    var row_index = top.*;
    var y = body.y;
    const rows_bottom = body.y + body.h - 22;
    while (row_index < v.rows.items.len and y + row_h <= rows_bottom) : (row_index += 1) {
        if (ctx.r.used() > 0.85) {
            try ctx.text(table.x + 12, y, "… more rows not drawn this frame (geometry budget)", p.warn);
            break;
        }
        const row = v.rows.items[row_index];
        const proc = &s.processes[row.index];
        const r = Rect{ .x = table.x + 4, .y = y, .w = table.w - 8, .h = row_h };
        const selected = v.selected != null and v.selected.?.pid == proc.pid and v.selected.?.start == proc.start;
        if (selected) {
            try ctx.r.shape(r, p.selection, .{ .radii = @splat(4) });
            try ctx.r.shape(r, fade(p.accent, 0.6), .{ .radii = @splat(4), .border = 1 });
        } else if (row_index % 2 == 1) try ctx.r.rect(r, fade(p.grid, 0.5));
        if (draw.inside(r, v.pointer[0], v.pointer[1]) and !selected) try ctx.r.shape(r, fade(p.selection, 0.5), .{ .radii = @splat(4) });
        v.hit(r, .{ .row = row_index });
        const ty = y + 2;
        cx = table.x + 12;
        for (cols, 0..) |c, i| {
            const w = if (i == 0) name_w else c.width;
            switch (i) {
                0 => {
                    const indent: f32 = if (v.tree) @as(f32, @floatFromInt(@min(row.depth, 24))) * 14 else 0;
                    if (v.tree and row.children > 0) try ctx.text(cx + indent, ty, if (row.collapsed) "▸" else "▾", p.dim);
                    const nx = cx + indent + (if (v.tree) @as(f32, 14) else 0);
                    var nb: [24]u8 = undefined;
                    const pname = vw.processName(v, proc, &nb);
                    try ctx.textFit(nx, ty, w - (nx - cx), pname, if (proc.kernel) p.dim else p.text);
                    if (row.collapsed) {
                        var kb: [24]u8 = undefined;
                        const k = std.fmt.bufPrint(&kb, "+{d}", .{row.children}) catch "";
                        try ctx.text(@min(nx + ctx.measure(pname) + 8, cx + w - 30), ty, k, p.dim);
                    }
                },
                1 => {
                    var b: [16]u8 = undefined;
                    try ctx.textRight(cx + w, ty, std.fmt.bufPrint(&b, "{d}", .{proc.pid}) catch "", p.dim);
                },
                2 => try userCell(v, ctx, cx, ty, w, proc),
                3 => {
                    const st = [1]u8{proc.state};
                    try ctx.text(cx + 4, ty, &st, if (proc.state == 'R') p.ok else if (proc.state == 'D') p.warn else if (proc.state == 'Z') p.crit else p.dim);
                },
                4 => {
                    if (proc.cpu.get()) |pc| {
                        try ctx.bar(.{ .x = cx, .y = y + 9, .w = w - 64, .h = 6 }, pc / 100, p.accent);
                        var b: [16]u8 = undefined;
                        try ctx.textRight(cx + w, ty, format(&b, .percent, @floatCast(pc)), p.text);
                    } else try cell(v, ctx, cx + w, y, w, proc.cpu.reason, &notes[4]);
                },
                5 => {
                    if (proc.rss.get()) |rss| {
                        const f: f64 = @floatFromInt(rss);
                        try ctx.bar(.{ .x = cx, .y = y + 9, .w = w - 82, .h = 6 }, f / max_rss, p.accent3);
                        var b: [24]u8 = undefined;
                        try ctx.textRight(cx + w, ty, m.bytes(&b, f), p.text);
                    } else try cell(v, ctx, cx + w, y, w, proc.rss.reason, &notes[5]);
                },
                6 => {
                    if (proc.read_bps.get() == null or proc.write_bps.get() == null) try cell(v, ctx, cx + w, y, w, if (proc.read_bps.get() == null) proc.read_bps.reason else proc.write_bps.reason, &notes[6]) else {
                        var b: [24]u8 = undefined;
                        const io = proc.read_bps.get().? + proc.write_bps.get().?;
                        try ctx.textRight(cx + w, ty, if (io == 0) "0" else m.rate(&b, io), if (io > 0) p.accent2 else p.dim);
                    }
                },
                7 => {
                    if (proc.net_bps.get()) |nb| {
                        var b: [24]u8 = undefined;
                        try ctx.textRight(cx + w, ty, m.rate(&b, nb), p.text);
                    } else try cell(v, ctx, cx + w, y, w, proc.net_bps.reason, &notes[7]);
                },
                8 => if (proc.threads.get()) |n| {
                    var b: [16]u8 = undefined;
                    try ctx.textRight(cx + w, ty, std.fmt.bufPrint(&b, "{d}", .{n}) catch "", p.text);
                } else try cell(v, ctx, cx + w, y, w, proc.threads.reason, &notes[8]),
                9 => if (proc.fds.get()) |n| {
                    var b: [16]u8 = undefined;
                    try ctx.textRight(cx + w, ty, std.fmt.bufPrint(&b, "{d}", .{n}) catch "", p.text);
                } else try cell(v, ctx, cx + w, y, w, proc.fds.reason, &notes[9]),
                10 => try text(v, ctx, cx, ty, w, v.private(proc.cmdline), p.dim),
                else => {},
            }
            cx += w + 10;
        }
        y += row_h;
    }
    // Footnote: why the hatched cells are empty, once per column.
    {
        var fx = table.x + 12;
        const fy = body.y + body.h - 20;
        var any = false;
        for (notes, 0..) |note, i| {
            if (note.len == 0) continue;
            if (!any) {
                try ctx.hatch(.{ .x = fx, .y = fy + 3, .w = 22, .h = 14 });
                fx += 30;
                try ctx.text(fx, fy, "not measured:", p.dim);
                fx += ctx.measure("not measured:") + 10;
                any = true;
            }
            var nb: [96]u8 = undefined;
            const t = std.fmt.bufPrint(&nb, "{s} — {s}", .{ cols_all[i].label, note }) catch note;
            if (fx + ctx.measure(t) > table.x + table.w - 12) break;
            try ctx.text(fx, fy, t, p.hatch);
            fx += ctx.measure(t) + 22;
        }
    }
    if (v.rows.items.len > v.visible_rows) {
        const frac = @as(f32, @floatFromInt(v.visible_rows)) / @as(f32, @floatFromInt(v.rows.items.len));
        const pos = @as(f32, @floatFromInt(top.*)) / @as(f32, @floatFromInt(v.rows.items.len));
        try ctx.r.shape(.{ .x = table.x + table.w - 6, .y = body.y + body.h * pos, .w = 3, .h = @max(20, body.h * frac) }, fade(p.dim, 0.5), .{ .radii = @splat(1.5) });
    }
    try processDetail(v, ctx, .{ .x = rect.x, .y = rect.y + rect.h - detail_h, .w = rect.w, .h = detail_h }, now);
}

fn userCell(v: *View, ctx: Ctx, x: f32, y: f32, w: f32, proc: *const m.Process) !void {
    const t = v.private(proc.user);
    if (t.ok()) return ctx.textFit(x, y, w, t.s, ctx.p.dim);
    // Redacted names keep the root/user distinction, which is not private.
    if (proc.uid.get()) |uid| {
        var b: [24]u8 = undefined;
        return ctx.textFit(x, y, w, if (uid == 0) "root" else std.fmt.bufPrint(&b, "uid ≥1000", .{}) catch "user", ctx.p.dim);
    }
    try missing(v, ctx, x, y, w, t.why);
}

fn processDetail(v: *View, ctx: Ctx, rect: Rect, now: u64) !void {
    const p = ctx.p;
    try ctx.panel(rect);
    const id = v.selected orelse {
        try ctx.text(rect.x + 14, rect.y + 12, "Select a process (↑↓ or click) to see its identity and open it in the debugger.", p.dim);
        return;
    };
    const proc = v.findProcess(id) orelse {
        var b: [96]u8 = undefined;
        try ctx.text(rect.x + 14, rect.y + 12, std.fmt.bufPrint(&b, "pid {d} (start {d}) has exited; its identity is not reused.", .{ id.pid, id.start }) catch "", p.warn);
        return;
    };
    // Three columns that never overlap: identity, sparklines, the hand-off button.
    const button_label = "Debugger  Enter";
    const bw: f32 = ctx.measure(button_label) + 32;
    const left_w = rect.w * 0.46;
    var b: [160]u8 = undefined;
    var nb: [24]u8 = undefined;
    const pname = vw.processName(v, proc, &nb);
    const name_w = @min(ctx.measure(pname), left_w * 0.4);
    try ctx.textFit(rect.x + 14, rect.y + 8, name_w + 1, pname, p.text);
    const ident = std.fmt.bufPrint(&b, "pid {d}  ·  start tick {d}  ·  parent {d}  ·  state {c}", .{ proc.pid, proc.start, proc.ppid, proc.state }) catch "";
    try ctx.textFit(rect.x + 14 + name_w + 14, rect.y + 8, left_w - name_w - 28, ident, p.dim);
    try ctx.text(rect.x + 14, rect.y + 34, "cgroup", p.dim);
    try text(v, ctx, rect.x + 104, rect.y + 34, left_w - 104, v.private(proc.cgroup), p.text);
    try ctx.text(rect.x + 14, rect.y + 58, "command", p.dim);
    try text(v, ctx, rect.x + 104, rect.y + 58, left_w - 104, v.private(proc.cmdline), p.text);
    // Sparklines of the selection since it was selected.
    const gx = rect.x + left_w + 10;
    const gw = @max(40, (rect.w - left_w - 10 - bw - 40 - 12) / 2);
    try ctx.text(gx, rect.y + 6, "CPU", p.dim);
    try graph(v, ctx, .{ .x = gx, .y = rect.y + 28, .w = gw, .h = rect.h - 36 }, &.{.{ .ring = &v.hist.selected_cpu, .color = p.accent }}, .{ .scale = &v.hist.scales[8], .samples = 60, .labels = false, .smooth = false, .width = 1.5, .reason = proc.cpu.reason }, now);
    try ctx.text(gx + gw + 12, rect.y + 6, "Memory", p.dim);
    try graph(v, ctx, .{ .x = gx + gw + 12, .y = rect.y + 28, .w = gw, .h = rect.h - 36 }, &.{.{ .ring = &v.hist.selected_mem, .color = p.accent3 }}, .{ .kind = .bytes, .scale = &v.hist.scales[9], .samples = 60, .labels = false, .smooth = false, .width = 1.5, .reason = proc.rss.reason }, now);
    // Every action opens a cost/privilege confirmation before launch.
    for ([_][]const u8{ "Files  L", "Profile  F", button_label }, [_]View.Action{ .files, .profile, .attach }, 0..) |label, action, i| {
        const button = Rect{ .x = rect.x + rect.w - bw - 14, .y = rect.y + 4 + @as(f32, @floatFromInt(i)) * 27, .w = bw, .h = 25 };
        const hot = draw.inside(button, v.pointer[0], v.pointer[1]);
        try ctx.r.shape(button, fade(p.accent, if (hot) 0.32 else 0.2), .{ .radii = @splat(5) });
        try ctx.text(button.x + 12, button.y + 2, label, p.text);
        v.hit(button, action);
    }
}

// --- Memory -------------------------------------------------------------------

fn memory(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const mem = s.memory;
    const H = v.hist;
    const top_h: f32 = 190;
    {
        var rb: [64]u8 = undefined;
        var tb: [24]u8 = undefined;
        const right = if (mem.total.get()) |t| std.fmt.bufPrint(&rb, "{s} installed", .{m.bytes(&tb, @floatFromInt(t))}) catch "" else "";
        const inner = try card(ctx, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = top_h }, "Memory composition", right);
        var b: [32]u8 = undefined;
        if (mem.used.get()) |u| {
            const dw = try ctx.vfd(inner.x, inner.y + 2, 54, std.fmt.bufPrint(&b, "{d:.1}", .{@as(f64, @floatFromInt(u)) / (1 << 30)}) catch "", p.accent3);
            try ctx.text(inner.x + dw + 8, inner.y + 30, "GiB in use", p.dim);
        } else try missing(v, ctx, inner.x, inner.y + 10, 300, mem.used.reason);
        // Stacked composition bar. Parts that were not measured are hatched.
        const bar = Rect{ .x = inner.x + 260, .y = inner.y + 8, .w = inner.w - 260, .h = 40 };
        const total = mem.total.get() orelse 0;
        const used_other: ?u64 = if (mem.used.get()) |u| u -| (mem.shared.get() orelse 0) else null;
        const parts = [_]struct { label: []const u8, f: m.U, color: Color }{
            .{ .label = "In use", .f = if (used_other) |x| m.U.of(x) else mem.used, .color = p.accent3 },
            .{ .label = "Shared", .f = mem.shared, .color = p.accent2 },
            .{ .label = "Cached", .f = mem.cached, .color = p.accent },
            .{ .label = "Buffers", .f = mem.buffers, .color = fade(p.accent, 0.6) },
            .{ .label = "Free", .f = mem.free, .color = fade(p.dim, 0.35) },
        };
        try ctx.r.shape(bar, fade(p.grid, 1.5), .{ .radii = @splat(6) });
        if (total == 0) try ctx.hatch(bar) else {
            var x = bar.x;
            for (parts) |part| {
                const val = part.f.get() orelse continue;
                const w = bar.w * @as(f32, @floatFromInt(@min(val, total))) / @as(f32, @floatFromInt(total));
                const seg = Rect{ .x = x, .y = bar.y, .w = @min(w, bar.x + bar.w - x), .h = bar.h };
                try ctx.r.rect(seg, part.color);
                if (p.glow > 0) try ctx.r.rect(.{ .x = seg.x, .y = seg.y, .w = seg.w, .h = 2 }, fade(p.text, 0.25));
                var tb2: [24]u8 = undefined;
                v.hover(seg, "{s}: {s}", .{ part.label, m.bytes(&tb2, @floatFromInt(val)) });
                x += w;
            }
        }
        // Legend.
        var lx = bar.x;
        const ly = bar.y + bar.h + 10;
        for (parts) |part| {
            try ctx.r.shape(.{ .x = lx, .y = ly + 5, .w = 10, .h = 10 }, part.color, .{ .radii = @splat(2) });
            try ctx.text(lx + 16, ly, part.label, p.dim);
            const lw = ctx.measure(part.label);
            var vb: [24]u8 = undefined;
            if (part.f.get()) |val| try ctx.text(lx + 16, ly + 20, m.bytes(&vb, @floatFromInt(val)), p.text) else try missing(v, ctx, lx + 16, ly + 20, 130, part.f.reason);
            lx += @max(lw + 30, 150);
        }
        var y = inner.y + 72;
        const kw: f32 = 240;
        try kv(v, ctx, inner.x, y, kw, "Available", fromU(mem.available), .bytes);
        y += line_h;
        try kv(v, ctx, inner.x, y, kw, "Dirty", fromU(mem.dirty), .bytes);
        y += line_h;
        try kv(v, ctx, inner.x, y, kw, "Writeback", fromU(mem.writeback), .bytes);
        y += line_h;
        try kv(v, ctx, inner.x, y, kw, "Committed", fromU(mem.committed), .bytes);
    }
    // Swap and zswap.
    const row_y = rect.y + top_h + gap;
    const row_h: f32 = 150;
    const third = (rect.w - 2 * gap) / 3;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = row_y, .w = third, .h = row_h }, "Swap", "");
        if (mem.swap_total.get()) |t| {
            if (t == 0) try ctx.text(inner.x, inner.y, "No swap configured", p.dim) else {
                const used = mem.swap_used.get();
                try ctx.segments(.{ .x = inner.x, .y = inner.y + 4, .w = inner.w, .h = 16 }, if (used) |u| @as(f64, @floatFromInt(u)) / @as(f64, @floatFromInt(t)) else null, p.accent2);
                try kv(v, ctx, inner.x, inner.y + 30, inner.w, "Used", fromU(mem.swap_used), .bytes);
                try kv(v, ctx, inner.x, inner.y + 52, inner.w, "Total", fromU(mem.swap_total), .bytes);
                try kv(v, ctx, inner.x, inner.y + 74, inner.w, "Swap in / out (pages/s)", mem.swap_out_ps, .count);
            }
        } else try missing(v, ctx, inner.x, inner.y, inner.w, mem.swap_total.reason);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + third + gap, .y = row_y, .w = third, .h = row_h }, "zswap", "compressed swap cache");
        const pool = mem.zswap_pool.get();
        const stored = mem.zswap_stored.get();
        if (pool != null and stored != null and pool.? > 0) {
            const ratio = @as(f64, @floatFromInt(stored.?)) / @as(f64, @floatFromInt(pool.?));
            var b: [24]u8 = undefined;
            const w = try ctx.vfd(inner.x, inner.y + 2, 40, std.fmt.bufPrint(&b, "{d:.1}", .{ratio}) catch "", p.accent);
            try ctx.text(inner.x + w + 6, inner.y + 18, "× compression", p.dim);
            try kv(v, ctx, inner.x, inner.y + 52, inner.w, "Pool (RAM)", fromU(mem.zswap_pool), .bytes);
            try kv(v, ctx, inner.x, inner.y + 74, inner.w, "Stored (original)", fromU(mem.zswap_stored), .bytes);
        } else if (pool != null and pool.? == 0) {
            try ctx.text(inner.x, inner.y, "zswap pool is empty", p.dim);
        } else try missing(v, ctx, inner.x, inner.y, inner.w, mem.zswap_pool.reason);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + 2 * (third + gap), .y = row_y, .w = third, .h = row_h }, "Faults", "");
        try kv(v, ctx, inner.x, inner.y, inner.w, "Major faults /s", mem.major_faults_ps, .count);
        try kv(v, ctx, inner.x, inner.y + 22, inner.w, "Swap in pages /s", mem.swap_in_ps, .count);
        try kv(v, ctx, inner.x, inner.y + 44, inner.w, "Swap out pages /s", mem.swap_out_ps, .count);
        try kv(v, ctx, inner.x, inner.y + 66, inner.w, "Slab (reclaimable)", fromU(mem.slab), .bytes);
    }
    // History and pressure.
    const low_y = row_y + row_h + gap;
    const low_h = rect.y + rect.h - low_y;
    if (low_h < 100) return;
    const half = (rect.w - gap) / 2;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = low_y, .w = half, .h = low_h }, "Memory in use", "% of installed");
        try graph(v, ctx, inner, &.{ .{ .ring = &H.mem_used, .color = p.accent3, .label = "used" }, .{ .ring = &H.mem_cached, .color = p.accent, .fill = 0.1, .label = "cached" }, .{ .ring = &H.swap_used, .color = p.accent2, .fill = 0, .label = "swap" } }, .{ .max = 100, .samples = 180 }, now);
    }
    {
        const inner = try card(ctx, .{ .x = rect.x + half + gap, .y = low_y, .w = half, .h = low_h }, "Pressure stall (PSI, avg10)", "some = any task stalled · full = all stalled");
        const third_h = (inner.h - 2 * 6) / 3;
        const names = [_][]const u8{ "CPU", "Memory", "I/O" };
        const reasons = [_][]const u8{ s.psi_cpu.some10.reason, s.psi_memory.some10.reason, s.psi_io.some10.reason };
        for (0..3) |i| {
            const g = Rect{ .x = inner.x + 70, .y = inner.y + @as(f32, @floatFromInt(i)) * (third_h + 6), .w = inner.w - 70, .h = third_h };
            try ctx.text(inner.x, g.y + g.h / 2 - 10, names[i], p.dim);
            try graph(v, ctx, g, &.{ .{ .ring = &H.psi[i * 2], .color = p.warn, .label = "some" }, .{ .ring = &H.psi[i * 2 + 1], .color = p.crit, .fill = 0.2, .label = "full" } }, .{ .scale = &H.scales[10 + i], .samples = 120, .reason = reasons[i] }, now);
        }
    }
}

// --- Disk -----------------------------------------------------------------------

fn disks(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    if (s.disks.len == 0) return missing(v, ctx, rect.x, rect.y, rect.w, if (s.group(.disks).status != .ok) s.group(.disks).reason else "no block devices");
    const n = s.disks.len;
    const cols: usize = if (n <= 1) 1 else 2;
    const rows = (n + cols - 1) / cols;
    const ch = @max(200, (rect.h - gap * @as(f32, @floatFromInt(rows - 1))) / @as(f32, @floatFromInt(rows)));
    const cw = (rect.w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const first = v.scroll[@intFromEnum(vw.Panel.disk)] * cols;
    for (s.disks, 0..) |d, i| {
        if (i < first) continue;
        const k = i - first;
        const box = Rect{ .x = rect.x + @as(f32, @floatFromInt(k % cols)) * (cw + gap), .y = rect.y + @as(f32, @floatFromInt(k / cols)) * (ch + gap), .w = cw, .h = ch };
        if (box.y + 120 > rect.y + rect.h) break;
        var tb: [96]u8 = undefined;
        var sb: [24]u8 = undefined;
        const model = d.model;
        const head = std.fmt.bufPrint(&tb, "{s}  {s}", .{ d.name, if (model.ok()) model.s else "" }) catch d.name;
        const size = if (d.size.get()) |x| m.bytes(&sb, @floatFromInt(x)) else "";
        const inner = try card(ctx, .{ .x = box.x, .y = box.y, .w = box.w, .h = @min(box.h, rect.y + rect.h - box.y) }, head, size);
        const side: f32 = 230;
        const slot = v.hist.disks.find(d.name);
        if (slot) |si| {
            const rings = &v.hist.disks.rings[si];
            try graph(v, ctx, .{ .x = inner.x, .y = inner.y, .w = inner.w - side - 12, .h = inner.h }, &.{ .{ .ring = &rings[0], .color = p.accent, .label = "read" }, .{ .ring = &rings[1], .color = p.accent2, .label = "write", .sign = -1 } }, .{ .kind = .rate, .scale = &v.hist.disks.scales[si], .mirrored = true, .reason = d.read_bps.reason }, now);
        }
        const sx = inner.x + inner.w - side;
        var y = inner.y;
        try ctx.text(sx, y, "Busy", p.dim);
        try valueRight(v, ctx, sx + side, y, side * 0.6, d.busy, .percent, p.text);
        y += 22;
        const prev_busy: ?f64 = if (v.prev()) |ps| for (ps.disks) |pd| {
            if (std.mem.eql(u8, pd.name, d.name)) break pd.busy.get();
        } else null else null;
        try ctx.segments(.{ .x = sx, .y = y, .w = side, .h = 12 }, if (d.busy.get()) |b| ((if (prev_busy) |pb| pb + (b - pb) * v.ease(now) else b) / 100) else null, p.accent);
        y += 22;
        try kv(v, ctx, sx, y, side, "Read", d.read_bps, .rate);
        y += line_h;
        try kv(v, ctx, sx, y, side, "Write", d.write_bps, .rate);
        y += line_h;
        try kv(v, ctx, sx, y, side, "Read IOPS", d.read_iops, .count);
        y += line_h;
        try kv(v, ctx, sx, y, side, "Write IOPS", d.write_iops, .count);
        y += line_h;
        if (y + line_h <= inner.y + inner.h) try kv(v, ctx, sx, y, side, "Queue depth", d.queue, .plain);
        y += line_h;
        if (y + line_h <= inner.y + inner.h) try kv(v, ctx, sx, y, side, "Latency (ms)", d.latency_ms, .plain);
        y += line_h;
        if (y + line_h <= inner.y + inner.h) try kv(v, ctx, sx, y, side, "Temperature", d.temp_c, .celsius);
    }
}

// --- Disk space -------------------------------------------------------------------

fn diskSpace(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    const inner = try card(ctx, rect, "Filesystems", "used / (used + available), as df");
    if (s.mounts.len == 0) return missing(v, ctx, inner.x, inner.y, inner.w, if (s.group(.filesystems).status != .ok) s.group(.filesystems).reason else "no filesystems");
    const row_h: f32 = 48;
    var y = inner.y;
    const first = @min(v.scroll[@intFromEnum(vw.Panel.disk_space)], s.mounts.len -| 1);
    for (s.mounts[first..]) |mount| {
        if (y + row_h > inner.y + inner.h) break;
        const path = v.mountPath(mount.path);
        try text(v, ctx, inner.x, y, inner.w * 0.28, path, p.text);
        var db: [96]u8 = undefined;
        const dev = v.private(mount.device);
        const devtext = std.fmt.bufPrint(&db, "{s}{s}{s}", .{ if (dev.ok()) dev.s else "device hidden", if (mount.fstype.len > 0) " · " else "", mount.fstype }) catch "";
        try ctx.textFit(inner.x, y + 21, inner.w * 0.28, devtext, p.dim);
        const bar = Rect{ .x = inner.x + inner.w * 0.3, .y = y + 6, .w = inner.w * 0.42, .h = 16 };
        const frac: ?f64 = if (mount.used_pct.get()) |x| x / 100 else null;
        const color = if (frac) |f| if (p.monochrome) p.accent else if (f > 0.9) p.crit else if (f > 0.8) p.warn else p.accent else p.accent;
        try ctx.segments(bar, frac, color);
        if (frac == null) v.hover(bar, "Usage unavailable: {s}", .{mount.used_pct.reason});
        if (mount.read_only) try ctx.text(bar.x, y + 24, "read-only", p.warn);
        var b1: [24]u8 = undefined;
        var b2: [24]u8 = undefined;
        var b3: [24]u8 = undefined;
        const rx = inner.x + inner.w * 0.74;
        if (mount.used.get() != null and mount.total.get() != null) {
            const line = std.fmt.bufPrint(&db, "{s} of {s}", .{ m.bytes(&b1, @floatFromInt(mount.used.get().?)), m.bytes(&b2, @floatFromInt(mount.total.get().?)) }) catch "";
            try ctx.text(rx, y + 2, line, p.text);
        } else try missing(v, ctx, rx, y + 2, 200, mount.total.reason);
        if (mount.available.get()) |a| try ctx.text(rx, y + 22, std.fmt.bufPrint(&db, "{s} free", .{m.bytes(&b3, @floatFromInt(a))}) catch "", p.dim);
        try valueRight(v, ctx, inner.x + inner.w, y + 2, 90, mount.used_pct, .percent, color);
        if (mount.inodes_total.get()) |it| if (it > 0) if (mount.inodes_free.get()) |fr| {
            var ib: [32]u8 = undefined;
            try ctx.textRight(inner.x + inner.w, y + 22, std.fmt.bufPrint(&ib, "inodes {d:.0}%", .{100 - @as(f64, @floatFromInt(fr)) * 100 / @as(f64, @floatFromInt(it))}) catch "", p.dim);
        };
        y += row_h;
        try ctx.r.rect(.{ .x = inner.x, .y = y - 4, .w = inner.w, .h = 1 }, fade(p.border, 0.6));
    }
}

// --- Network ----------------------------------------------------------------------

fn network(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    var shown: [64]usize = undefined;
    var n: usize = 0;
    // Physical and active interfaces first; loopback last.
    for (0..2) |pass| for (s.nets, 0..) |net, i| {
        if ((pass == 0) == net.loopback) continue;
        if (n < shown.len) {
            shown[n] = i;
            n += 1;
        }
    };
    if (n == 0) return missing(v, ctx, rect.x, rect.y, rect.w, if (s.group(.network).status != .ok) s.group(.network).reason else "no interfaces");
    const ch: f32 = @max(190, @min(260, (rect.h - gap * @as(f32, @floatFromInt(@min(n, 3) - 1))) / @as(f32, @floatFromInt(@min(n, 3)))));
    const first = @min(v.scroll[@intFromEnum(vw.Panel.network)], n - 1);
    var y = rect.y;
    for (shown[first..n]) |i| {
        if (y + 120 > rect.y + rect.h) break;
        const net = s.nets[i];
        var hb: [96]u8 = undefined;
        var sb: [32]u8 = undefined;
        const st = net.state;
        const right = std.fmt.bufPrint(&hb, "{s}{s}{s}", .{ if (st.ok()) st.s else "state ?", if (net.speed_mbps.get() != null) " · " else "", if (net.speed_mbps.get()) |sp| std.fmt.bufPrint(&sb, "{d} Mb/s", .{sp}) catch "" else "" }) catch "";
        const box_h = @min(ch, rect.y + rect.h - y);
        const inner = try card(ctx, .{ .x = rect.x, .y = y, .w = rect.w, .h = box_h }, net.name, right);
        const side: f32 = 300;
        if (v.hist.nets.find(net.name)) |si| {
            const rings = &v.hist.nets.rings[si];
            try graph(v, ctx, .{ .x = inner.x, .y = inner.y, .w = inner.w - side - 14, .h = inner.h }, &.{ .{ .ring = &rings[0], .color = p.accent3, .label = "rx" }, .{ .ring = &rings[1], .color = p.accent2, .label = "tx", .sign = -1 } }, .{ .kind = .rate, .scale = &v.hist.nets.scales[si], .mirrored = true, .reason = net.rx_bps.reason }, now);
        }
        const sx = inner.x + inner.w - side;
        var ly = inner.y;
        try kv(v, ctx, sx, ly, side, "Receive", net.rx_bps, .rate);
        ly += line_h;
        try kv(v, ctx, sx, ly, side, "Send", net.tx_bps, .rate);
        ly += line_h;
        try kv(v, ctx, sx, ly, side, "Packets in /s", net.rx_pps, .count);
        ly += line_h;
        try kv(v, ctx, sx, ly, side, "Errors / drops /s", net.errors_ps, .plain);
        ly += line_h;
        try kvText(v, ctx, sx, ly, side, "MAC", v.private(net.mac));
        ly += line_h;
        for (net.addresses) |ad| {
            if (ly + line_h > inner.y + inner.h) break;
            try kvText(v, ctx, sx, ly, side, "Address", v.address(ad));
            ly += line_h;
        }
        y += box_h + gap;
    }
}

// --- Connections ------------------------------------------------------------------

fn connections(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    var sb: [160]u8 = undefined;
    var tcp: usize = 0;
    var udp: usize = 0;
    var unix: usize = 0;
    var listen: usize = 0;
    var est: usize = 0;
    for (s.connections) |c| {
        if (std.mem.eql(u8, c.proto, "tcp")) tcp += 1 else if (std.mem.eql(u8, c.proto, "udp")) udp += 1 else unix += 1;
        if (std.mem.eql(u8, c.state, "LISTEN")) listen += 1;
        if (std.mem.eql(u8, c.state, "ESTABLISHED")) est += 1;
    }
    // Counts only from a collected socket list; an unavailable group has no zeros.
    const measured = s.group(.connections).status != .unavailable or s.connections.len > 0;
    var ub: [48]u8 = undefined;
    const owners: []const u8 = if (s.owners_unresolved.get()) |u| (if (u > 0) std.fmt.bufPrint(&ub, " · {d} owners unresolved", .{u}) catch "" else "") else "";
    const right = if (measured) std.fmt.bufPrint(&sb, "tcp {d} · udp {d} · unix {d} · listening {d} · established {d}{s}{s}", .{ tcp, udp, unix, listen, est, if (s.connections_truncated > 0) " · truncated" else "", owners }) catch "" else "";
    const inner = try card(ctx, rect, "Connections", right);
    if (!measured) return missing(v, ctx, inner.x, inner.y, inner.w, if (s.group(.connections).detail.len > 0) s.group(.connections).detail else s.group(.connections).reason);
    const cols = [_]struct { label: []const u8, w: f32 }{ .{ .label = "Proto", .w = 60 }, .{ .label = "State", .w = 120 }, .{ .label = "Local", .w = inner.w * 0.27 }, .{ .label = "Remote", .w = inner.w * 0.27 }, .{ .label = "PID", .w = 80 }, .{ .label = "Process", .w = 0 } };
    var x = inner.x;
    const hy = inner.y + 6;
    for (cols) |c| {
        try ctx.text(x, hy, c.label, p.dim);
        x += c.w + 12;
    }
    try ctx.r.rect(.{ .x = inner.x, .y = hy + 24, .w = inner.w, .h = 1 }, p.border);
    var y = hy + 30;
    const first = @min(v.scroll[@intFromEnum(vw.Panel.connections)], s.connections.len -| 1);
    for (s.connections[first..], 0..) |c, i| {
        if (y + line_h > inner.y + inner.h or ctx.r.used() > 0.85) break;
        if (i % 2 == 1) try ctx.r.rect(.{ .x = inner.x - 4, .y = y, .w = inner.w + 8, .h = line_h }, fade(p.grid, 0.5));
        x = inner.x;
        try ctx.text(x, y, c.proto, p.dim);
        x += cols[0].w + 12;
        try ctx.text(x, y, c.state, if (std.mem.eql(u8, c.state, "LISTEN")) p.accent else if (std.mem.eql(u8, c.state, "ESTABLISHED")) p.ok else p.dim);
        x += cols[1].w + 12;
        try text(v, ctx, x, y, cols[2].w, v.address(c.local), p.text);
        x += cols[2].w + 12;
        try text(v, ctx, x, y, cols[3].w, v.address(c.remote), p.text);
        x += cols[3].w + 12;
        if (c.pid.get()) |pid| {
            var b: [16]u8 = undefined;
            try ctx.text(x, y, std.fmt.bufPrint(&b, "{d}", .{pid}) catch "", p.dim);
            x += cols[4].w + 12;
            var ob: [24]u8 = undefined;
            try ctx.textFit(x, y, inner.x + inner.w - x, vw.ownerName(v, pid, c.owner, &ob), p.text);
        } else try missing(v, ctx, x, y, cols[4].w + 200, c.pid.reason);
        y += line_h;
    }
}

// --- Power & thermals ---------------------------------------------------------------

fn power(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot, now: u64) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const top_h: f32 = 200;
    // CPU package power and temperature: the privileged reading shows its reason.
    const cw: f32 = @min(420, rect.w * 0.3);
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = rect.y, .w = cw, .h = top_h }, "CPU package", "RAPL · hwmon");
        var b: [32]u8 = undefined;
        if (s.cpu_package_temp.get()) |t| {
            const w = try ctx.vfd(inner.x, inner.y + 4, 56, std.fmt.bufPrint(&b, "{d:.1}", .{t}) catch "", p.warn);
            try ctx.text(inner.x + w + 6, inner.y + 4, "°C", p.dim);
        } else try missing(v, ctx, inner.x, inner.y + 20, inner.w, s.cpu_package_temp.reason);
        const py = inner.y + 78;
        try ctx.text(inner.x, py, "Package power", p.dim);
        if (s.cpu_package_power.get()) |w| {
            try ctx.text(inner.x + 130, py, std.fmt.bufPrint(&b, "{d:.1} W", .{w}) catch "", p.text);
        } else {
            const box = Rect{ .x = inner.x, .y = py + 24, .w = inner.w, .h = 40 };
            try ctx.hatch(box);
            var rb: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&rb, "CPU package power: {s}", .{s.cpu_package_power.reason}) catch "";
            try ctx.r.shape(.{ .x = box.x + 8, .y = box.y + 9, .w = ctx.measure(msg) + 12, .h = 22 }, p.panel, .{ .radii = @splat(4) });
            try ctx.text(box.x + 14, box.y + 10, msg, p.text);
            v.hover(box, "RAPL energy counters are readable by root only on this kernel; nothing is estimated", .{});
        }
    }
    // GPUs.
    {
        const gx = rect.x + cw + gap;
        const gw = rect.w - cw - gap;
        if (s.gpus.len == 0) {
            const inner = try card(ctx, .{ .x = gx, .y = rect.y, .w = gw, .h = top_h }, "GPU", "");
            try missing(v, ctx, inner.x, inner.y, inner.w, "no GPU found");
        } else {
            const each = (gw - gap * @as(f32, @floatFromInt(s.gpus.len - 1))) / @as(f32, @floatFromInt(s.gpus.len));
            for (s.gpus, 0..) |g, i| {
                var hb: [96]u8 = undefined;
                const name = v.private(g.name);
                const head = std.fmt.bufPrint(&hb, "{s} · {s} {s}", .{ g.card, g.driver, if (name.ok()) name.s else "" }) catch g.card;
                const inner = try card(ctx, .{ .x = gx + @as(f32, @floatFromInt(i)) * (each + gap), .y = rect.y, .w = each, .h = top_h }, head, "");
                const side: f32 = 190;
                if (v.hist.gpus.find(g.card)) |si| {
                    const rings = &v.hist.gpus.rings[si];
                    try graph(v, ctx, .{ .x = inner.x, .y = inner.y, .w = inner.w - side - 10, .h = inner.h }, &.{.{ .ring = &rings[0], .color = p.accent2, .label = "busy" }}, .{ .max = 100, .reason = g.busy.reason }, now);
                }
                const sx = inner.x + inner.w - side;
                try kv(v, ctx, sx, inner.y, side, "Busy", g.busy, .percent);
                try kv(v, ctx, sx, inner.y + 22, side, "Power", g.power_w, .watts);
                try kv(v, ctx, sx, inner.y + 44, side, "Temperature", g.temp_c, .celsius);
                try kv(v, ctx, sx, inner.y + 66, side, "VRAM used", fromU(g.vram_used), .bytes);
                try kv(v, ctx, sx, inner.y + 88, side, "VRAM total", fromU(g.vram_total), .bytes);
                try kv(v, ctx, sx, inner.y + 110, side, "GPU MHz", g.graphics_mhz, .mhz);
                try kv(v, ctx, sx, inner.y + 132, side, "Mem MHz", g.memory_mhz, .mhz);
            }
        }
    }
    // Backend explanations remain visible even when other power sensors work.
    const explanation = s.group(.power).detail;
    const note_h: f32 = if (explanation.len > 0) 26 else 0;
    if (explanation.len > 0)
        try ctx.textFit(rect.x + 8, rect.y + top_h + 5, rect.w - 16, explanation, p.dim);
    // Every hwmon sensor, with history.
    const grid = Rect{ .x = rect.x, .y = rect.y + top_h + gap + note_h, .w = rect.w, .h = rect.h - top_h - gap - note_h };
    const inner = try card(ctx, grid, "Sensors (hwmon)", "every input the kernel exposes");
    if (s.sensors.len == 0) return missing(v, ctx, inner.x, inner.y, inner.w, if (s.group(.power).status != .ok) s.group(.power).reason else "no hwmon sensors");
    const tw: f32 = if (inner.w > 1400) 260 else 230;
    const cols: usize = @max(1, @as(usize, @intFromFloat((inner.w + 8) / (tw + 8))));
    const sensor_rows = (s.sensors.len + cols - 1) / cols;
    const th: f32 = std.math.clamp((inner.h - 8 * @as(f32, @floatFromInt(sensor_rows - 1))) / @as(f32, @floatFromInt(sensor_rows)), 92, 170);
    const tile_w = (inner.w - 8 * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    const first = @min(v.scroll[@intFromEnum(vw.Panel.power)] * cols, s.sensors.len -| 1);
    for (s.sensors[first..], 0..) |sensor, k| {
        const tile = Rect{ .x = inner.x + @as(f32, @floatFromInt(k % cols)) * (tile_w + 8), .y = inner.y + @as(f32, @floatFromInt(k / cols)) * (th + 8), .w = tile_w, .h = th };
        if (tile.y + th > inner.y + inner.h or ctx.r.used() > 0.85) break;
        try ctx.r.shape(tile, p.raised, .{ .radii = @splat(4) });
        try ctx.textFit(tile.x + 8, tile.y + 2, tile.w - 16, sensor.chip, p.dim);
        try ctx.textFit(tile.x + 8, tile.y + 20, tile.w * 0.55, sensor.label, p.text);
        const kind: Kind = switch (sensor.kind) {
            .temp => .celsius,
            .power => .watts,
            .fan => .rpm,
            .voltage => .volts,
            .current => .amps,
            .freq => .mhz,
            .pwm => .percent,
            else => .plain,
        };
        const crit = sensor.crit.get() orelse sensor.max.get();
        const hot = if (sensor.value.get()) |x| crit != null and x >= crit.? * 0.9 else false;
        if (sensor.value.get()) |x| {
            var b: [24]u8 = undefined;
            const t = switch (sensor.kind) {
                .temp => std.fmt.bufPrint(&b, "{d:.1}", .{x}) catch "",
                .voltage => std.fmt.bufPrint(&b, "{d:.2}", .{x}) catch "",
                else => std.fmt.bufPrint(&b, "{d:.0}", .{x}) catch "",
            };
            const dh: f32 = 26;
            const unit = m.unit(sensor.kind);
            const uw = ctx.measure(unit);
            const w = Ctx.vfdWidth(dh, t);
            const stale = sensor.value.status == .stale;
            _ = try ctx.vfd(tile.x + tile.w - 10 - uw - 4 - w, tile.y + 6, dh, t, if (stale) p.dim else if (hot and !p.monochrome) p.crit else p.accent);
            try ctx.text(tile.x + tile.w - 8 - uw, tile.y + 14, unit, p.dim);
            if (stale) {
                try ctx.text(tile.x + tile.w * 0.55 - 10, tile.y + 20, "stale", p.dim);
                v.hover(tile, "{s} {s}: stale ({s}); the last reading is shown dimmed", .{ sensor.chip, sensor.label, sensor.value.reason });
            }
        } else try missingRight(v, ctx, tile.x + tile.w - 8, tile.y + 14, tile.w * 0.45, sensor.value.reason);
        var key: [96]u8 = undefined;
        const k2 = std.fmt.bufPrint(&key, "{s}/{s}", .{ sensor.chip, sensor.label }) catch "";
        if (v.hist.sensors.find(k2)) |si| {
            const ring = &v.hist.sensors.rings[si][0];
            const g = Rect{ .x = tile.x + 6, .y = tile.y + 44, .w = tile.w - 12, .h = th - 50 };
            // Zoom into the recent range so a 2 °C drift is visible; the range is printed.
            var lo: f32 = std.math.floatMax(f32);
            var hi: f32 = -std.math.floatMax(f32);
            for (0..@min(ring.len, 90)) |j| if (ring.back(j)) |x| {
                lo = @min(lo, x);
                hi = @max(hi, x);
            };
            if (lo > hi) {
                lo = 0;
                hi = 1;
            }
            const pad = @max((hi - lo) * 0.15, @as(f32, if (sensor.kind == .voltage) 0.02 else 1));
            const floor = @max(0, lo - pad);
            const top = hi + pad;
            try graph(v, ctx, g, &.{.{ .ring = ring, .color = if (hot and !p.monochrome) p.crit else p.accent, .fill = 0.25 }}, .{ .kind = kind, .max = top, .floor = floor, .samples = 90, .smooth = g.w / 90 >= 6, .labels = false, .width = 1.5, .reason = sensor.value.reason }, now);
            if (g.h >= 40) {
                var rb: [48]u8 = undefined;
                var b1: [20]u8 = undefined;
                var b2: [20]u8 = undefined;
                const range = std.fmt.bufPrint(&rb, "{s} – {s}", .{ format(&b1, kind, floor), format(&b2, kind, top) }) catch "";
                try ctx.text(g.x + 4, g.y + g.h - 20, range, fade(p.dim, 0.8));
            }
        }
        if (crit) |cv| {
            var cb: [64]u8 = undefined;
            var vb: [24]u8 = undefined;
            v.hover(tile, "{s} {s}: critical at {s}", .{ sensor.chip, sensor.label, format(&vb, kind, @floatCast(cv)) });
            _ = &cb;
        }
    }
}

// --- System info, users, services, apps -------------------------------------------

fn system(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const half = (rect.w - gap) / 2;
    {
        const inner = try card(ctx, .{ .x = rect.x, .y = rect.y, .w = half, .h = rect.h }, "System", "");
        var y = inner.y;
        const w = inner.w;
        try kvText(v, ctx, inner.x, y, w, "Hostname", v.private(s.hostname));
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Operating system", if (v.redact) m.Text.of("Linux (distribution hidden)") else s.os);
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Kernel", v.kernelText(s.kernel));
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Architecture", s.arch);
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Init system", s.init);
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Package manager", s.package_manager);
        y += line_h * 1.5;
        try kvText(v, ctx, inner.x, y, w, "CPU", s.cpu_model);
        y += line_h;
        var b: [64]u8 = undefined;
        try kvText(v, ctx, inner.x, y, w, "Logical CPUs", m.Text.of(std.fmt.bufPrint(&b, "{d}", .{s.cpus.len}) catch ""));
        y += line_h;
        try kv(v, ctx, inner.x, y, w * 0.5, "Physical cores", fromU(s.physical_cores), .count);
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Frequency driver", s.freq_driver);
        y += line_h;
        try kvText(v, ctx, inner.x, y, w, "Governor", s.governor);
        y += line_h;
        try kv(v, ctx, inner.x, y, w * 0.5, "Memory", fromU(if (s.memory_total.get() != null) s.memory_total else s.memory.total), .bytes);
        y += line_h * 1.5;
        for (s.gpu_names) |g| {
            try kvText(v, ctx, inner.x, y, w, "GPU", v.private(g));
            y += line_h;
        }
        var ub: [32]u8 = undefined;
        try kvText(v, ctx, inner.x, y, w, "Uptime", if (s.uptime_s.get()) |u| m.Text.of(m.duration(&ub, u)) else m.Text.missing(s.uptime_s.reason));
        y += line_h;
        try kv(v, ctx, inner.x, y, w * 0.5, "Load (1 min)", s.load1, .plain);
        y += line_h;
        try kv(v, ctx, inner.x, y, w * 0.5, "Load (5 min)", s.load5, .plain);
        y += line_h;
        try kv(v, ctx, inner.x, y, w * 0.5, "Load (15 min)", s.load15, .plain);
    }
    {
        var rb: [48]u8 = undefined;
        const inner = try card(ctx, .{ .x = rect.x + half + gap, .y = rect.y, .w = half, .h = rect.h }, "Collector groups", std.fmt.bufPrint(&rb, "sample #{d}{s}", .{ s.sequence, if (s.redacted) " · redacted" else "" }) catch "");
        var y = inner.y;
        try ctx.text(inner.x, y, "Group", p.dim);
        try ctx.text(inner.x + 130, y, "State", p.dim);
        try ctx.textRight(inner.x + inner.w, y, "Cost", p.dim);
        y += line_h + 4;
        inline for (std.meta.fields(m.Group), 0..) |g, i| {
            const st = s.groups[i];
            try ctx.text(inner.x, y, g.name, p.text);
            if (st.status == .ok) try ctx.text(inner.x + 130, y, "ok", p.ok) else try missing(v, ctx, inner.x + 130, y, inner.w - 240, if (st.detail.len > 0) st.detail else st.reason);
            if (st.cost_ns) |ns| {
                var cb: [24]u8 = undefined;
                try ctx.textRight(inner.x + inner.w, y, std.fmt.bufPrint(&cb, "{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1e6}) catch "", p.dim);
            }
            y += line_h;
        }
        y += line_h;
        try ctx.text(inner.x, y, "Collector self-cost", p.dim);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "Wall time (ms)", s.cost.wall_ms, .plain);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "CPU time (ms)", s.cost.cpu_ms, .plain);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "CPU, % of one core", s.cost.cpu_pct, .percent);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "Syscalls (estimate)", fromU(s.cost.syscalls), .count);
        y += line_h;
        try kv(v, ctx, inner.x, y, inner.w, "Sample interval (s)", s.interval_s, .plain);
        y += line_h;
        if (v.view_pct) |vp| try kv(v, ctx, inner.x, y, inner.w, "This view, % of one core", m.F.of(vp), .percent);
    }
}

fn groupBanner(v: *View, ctx: Ctx, inner: Rect, s: *const m.Snapshot, g: m.Group) !bool {
    const st = s.group(g);
    if (st.status == .ok) return false;
    const box = Rect{ .x = inner.x, .y = inner.y, .w = inner.w, .h = 56 };
    try ctx.hatchLight(box);
    var b: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&b, "{s}: {s}{s}{s}", .{ @tagName(g), st.reason, if (st.detail.len > 0) " — " else "", st.detail }) catch st.reason;
    try ctx.r.shape(.{ .x = box.x + 10, .y = box.y + 15, .w = ctx.measure(msg) + 16, .h = 26 }, ctx.p.panel, .{ .radii = @splat(5) });
    try ctx.text(box.x + 18, box.y + 17, msg, ctx.p.text);
    v.hover(box, "{s}", .{msg});
    return true;
}

fn users(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    var rb: [48]u8 = undefined;
    const inner = try card(ctx, rect, "Sessions (utmp)", std.fmt.bufPrint(&rb, "{d} sessions", .{s.users.len}) catch "");
    var y = inner.y;
    if (try groupBanner(v, ctx, inner, s, .users)) y += 66;
    const cols = [_]f32{ 0, 0.25, 0.42, 0.7, 0.85 };
    const labels = [_][]const u8{ "User", "Line", "From", "Login", "PID" };
    for (labels, cols) |l, c| try ctx.text(inner.x + inner.w * c, y, l, p.dim);
    y += line_h + 4;
    for (s.users, 0..) |u, i| {
        if (y + line_h > inner.y + inner.h) break;
        var nb: [24]u8 = undefined;
        const name = v.private(u.name);
        if (name.ok()) try ctx.text(inner.x, y, name.s, p.text) else try ctx.text(inner.x, y, std.fmt.bufPrint(&nb, "user {d}", .{i + 1}) catch "", p.dim);
        try ctx.text(inner.x + inner.w * cols[1], y, u.line, p.text);
        try text(v, ctx, inner.x + inner.w * cols[2], y, inner.w * 0.26, v.private(u.from), p.text);
        if (u.login_s.get()) |t| {
            var tb: [32]u8 = undefined;
            const ago = if (s.boot_time.get()) |_| t else t;
            try ctx.text(inner.x + inner.w * cols[3], y, std.fmt.bufPrint(&tb, "unix {d}", .{ago}) catch "", p.dim);
        } else try missing(v, ctx, inner.x + inner.w * cols[3], y, inner.w * 0.14, u.login_s.reason);
        try valueRight(v, ctx, inner.x + inner.w, y, inner.w * 0.14, fromU(u.pid), .count, p.dim);
        y += line_h;
    }
    if (s.users.len == 0 and s.group(.users).status == .ok) try ctx.text(inner.x, y, "No login sessions recorded in utmp.", p.dim);
}

fn services(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    var rb: [128]u8 = undefined;
    const mgr = s.service_manager;
    const inner = try card(ctx, rect, "Services", std.fmt.bufPrint(&rb, "{s} · {d} observed", .{ if (v.redact) "init: redacted" else if (mgr.ok()) mgr.s else mgr.why, s.services.len }) catch "");
    var y = inner.y;
    if (try groupBanner(v, ctx, inner, s, .services)) y += 66;
    if (s.group(.services).status == .ok and s.group(.services).detail.len > 0) {
        try ctx.textFit(inner.x, y, inner.w, s.group(.services).detail, p.warn);
        y += line_h;
    }
    try ctx.textFit(inner.x, y, inner.w, "Observed daemon processes · process state, not unit health · CPU % of one core", p.dim);
    y += line_h + 6;
    const fractions = [_]f32{ 0, 0.26, 0.38, 0.54, 0.62, 0.77, 0.88, 1 };
    const labels = [_][]const u8{ "Name", "PID", "User (UID)", "State", "Uptime", "CPU %", "RSS" };
    for (labels, 0..) |label, i| try ctx.textFit(inner.x + inner.w * fractions[i], y, inner.w * (fractions[i + 1] - fractions[i]) - 8, label, p.dim);
    y += line_h + 4;
    if (s.services.len == 0) {
        if (s.group(.services).status == .ok) try ctx.textFit(inner.x, y, inner.w, "No matching daemon processes observed", p.dim);
        return;
    }
    const first = @min(v.scroll[@intFromEnum(vw.Panel.services)], s.services.len - 1);
    for (s.services[first..]) |svc| {
        if (y + 48 > inner.y + inner.h) break;
        var pid: [32]u8 = undefined;
        var duration: [48]u8 = undefined;
        var cpu: [32]u8 = undefined;
        var rss: [32]u8 = undefined;
        const texts = [_][]const u8{
            if (v.redact) "service" else svc.name,
            if (svc.pid.get()) |id| std.fmt.bufPrint(&pid, "{d}", .{id}) catch "" else svc.pid.reason,
            if (v.redact) "redacted" else if (svc.user.ok()) svc.user.s else svc.user.why,
            if (svc.state.ok()) svc.state.s else svc.state.why,
            if (svc.uptime.get()) |sec| m.duration(&duration, sec) else svc.uptime.reason,
            if (svc.cpu.get()) |pct| std.fmt.bufPrint(&cpu, "{d:.1}", .{pct}) catch "" else svc.cpu.reason,
            if (svc.rss.get()) |bytes| m.bytes(&rss, @floatFromInt(bytes)) else svc.rss.reason,
        };
        for (texts, 0..) |content, i| try ctx.textFit(inner.x + inner.w * fractions[i], y, inner.w * (fractions[i + 1] - fractions[i]) - 8, content, if (i == 0) p.text else p.dim);
        if (svc.pid.get()) |id| {
            if (svc.start.get()) |start| v.hover(.{ .x = inner.x, .y = y, .w = inner.w, .h = line_h }, "PID {d}, start {d} ticks · state {s} · CPU: {s}", .{ id, start, texts[3], texts[5] });
        }
        const path = if (v.redact) "cgroup: redacted" else if (svc.cgroup.ok()) svc.cgroup.s else svc.cgroup.why;
        try ctx.textFit(inner.x + 12, y + line_h, inner.w - 24, path, p.dim);
        v.hover(.{ .x = inner.x, .y = y + line_h, .w = inner.w, .h = line_h }, "Cgroup: {s}", .{path});
        y += 52;
    }
}

fn apps(v: *View, ctx: Ctx, rect: Rect, s: *const m.Snapshot) !void {
    const p = ctx.p;
    const gap: f32 = 10;
    const top_h: f32 = 120;
    {
        const mgr = s.apps_manager;
        const inner = try card(ctx, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = top_h }, "Installed packages", if (mgr.ok()) mgr.s else mgr.why);
        var b: [32]u8 = undefined;
        if (s.apps_count.get()) |n| {
            const w = try ctx.vfd(inner.x, inner.y + 6, 48, std.fmt.bufPrint(&b, "{d}", .{n}) catch "", p.accent);
            try ctx.text(inner.x + w + 10, inner.y + 30, "packages", p.dim);
        } else try missing(v, ctx, inner.x, inner.y + 10, 300, s.apps_count.reason);
        if (s.apps_bytes.get()) |t| {
            const w = try ctx.vfd(inner.x + 420, inner.y + 6, 48, std.fmt.bufPrint(&b, "{d:.1}", .{@as(f64, @floatFromInt(t)) / (1 << 30)}) catch "", p.accent3);
            try ctx.text(inner.x + 420 + w + 10, inner.y + 30, "GiB installed", p.dim);
        } else try missing(v, ctx, inner.x + 420, inner.y + 10, 300, s.apps_bytes.reason);
    }
    const inner = try card(ctx, .{ .x = rect.x, .y = rect.y + top_h + gap, .w = rect.w, .h = rect.h - top_h - gap }, "Largest packages", "read-only package database");
    if (s.packages.len == 0) return missing(v, ctx, inner.x, inner.y, inner.w, if (s.group(.apps).status != .ok) s.group(.apps).reason else "package list not collected");
    var max: f64 = 1;
    for (s.packages) |pk| max = @max(max, @as(f64, @floatFromInt(pk.size.get() orelse 0)));
    var y = inner.y;
    const first = @min(v.scroll[@intFromEnum(vw.Panel.apps)], s.packages.len -| 1);
    for (s.packages[first..]) |pk| {
        if (y + line_h > inner.y + inner.h) break;
        try ctx.textFit(inner.x, y, inner.w * 0.25, pk.name, p.text);
        try ctx.textFit(inner.x + inner.w * 0.26, y, inner.w * 0.16, pk.version, p.dim);
        try ctx.bar(.{ .x = inner.x + inner.w * 0.44, .y = y + 8, .w = inner.w * 0.42, .h = 7 }, if (pk.size.get()) |sz| @as(f64, @floatFromInt(sz)) / max else null, p.accent);
        try valueRight(v, ctx, inner.x + inner.w, y, inner.w * 0.12, fromU(pk.size), .bytes, p.text);
        y += line_h;
    }
}
