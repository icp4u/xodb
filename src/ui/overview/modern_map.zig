//! Modern memory-map presentation. The sampler and viewport remain in the
//! shared map model; this module draws actual system activity and VMA history.
const std = @import("std");
const draw = @import("draw.zig");
const vw = @import("view.zig");
const mm = @import("memmap.zig");
const rgb = @import("../../appearance.zig").rgb;
const history = @import("memmap_history.zig");
const Ctx = draw.Ctx;
const Rect = draw.Rect;

pub const palette = @import("theme.zig").Palette{
    .name = "memory night",
    .background = rgb(0x11121b),
    .panel = rgb(0x191b2a),
    .raised = rgb(0x23263b),
    .grid = rgb(0x30354d),
    .border = rgb(0x343953),
    .text = rgb(0xd6ddf5),
    .dim = rgb(0x939fbe),
    .accent = rgb(0x78cfe8),
    .accent2 = rgb(0xe4ad77),
    .accent3 = rgb(0xb3a0ef),
    .ok = rgb(0x9cce91),
    .warn = rgb(0xe8c77b),
    .crit = rgb(0xec819b),
    .hatch = rgb(0x697795),
    .selection = rgb(0x35415b),
    .glow = 0.25,
};

pub fn activity(v: *vw.View, ctx: Ctx, r: Rect) !void {
    if (r.w < 80 or r.h < 20) return;
    const map = v.memmap.map();
    const state = if (map) |x| mm.md.activity(x) else mm.md.Activity{ .text = "waiting for counters", .known = false, .busy = false };
    try ctx.r.shape(r, ctx.p.raised, .{ .radii = @splat(6) });
    try ctx.r.shape(.{ .x = r.x + 9, .y = r.y + 8, .w = 8, .h = 8 }, if (!state.known) ctx.p.hatch else if (state.busy) ctx.p.accent else ctx.p.dim, .{ .radii = @splat(4) });
    var buf: [192]u8 = undefined;
    const label = if (state.busy) std.fmt.bufPrint(&buf, "System-wide {s} · {s} +{d}", .{ state.text, state.counter, state.count }) catch "" else std.fmt.bufPrint(&buf, "System-wide THP / compaction: {s}", .{state.text}) catch "";
    try ctx.textFit(r.x + 26, r.y + 2, r.w - 34, label, if (state.known) ctx.p.text else ctx.p.dim);
    v.hover(r, "khugepaged / compaction activity comes from system-wide counter deltas, not from this process", .{});
}

/// The visible VMA ribbons follow the selected address, or the viewport. Every
/// range has its own measured history; selecting a ribbon moves the viewport.
pub fn ribbons(v: *vw.View, ctx: Ctx, r: Rect) !void {
    if (r.w < 160 or r.h < 46) return;
    const map = v.memmap.map() orelse return;
    if (map.vmas.len == 0) return;
    const hist = &v.memmap.history;
    if (v.layout != null and hist.audited_ns != map.sampled_ns) {
        hist.audited_ns = map.sampled_ns;
        var points: usize = 0;
        for (hist.ranges.values()) |series| points = @max(points, series.len);
        std.debug.print("xodb: memmap modern sample={d} history={d} ranges={d} omitted={d}\n", .{ map.sequence, points, hist.ranges.count(), hist.omitted });
    }
    const focus = v.memmap.deep.selected orelse v.memmap.deep.origin;
    var first: usize = 0;
    for (map.vmas, 0..) |vma, i| {
        first = i;
        if (vma.end > focus) break;
    }
    const n = @min(map.vmas.len - first, @as(usize, @intFromFloat(@max(1, @floor((r.w + 10) / 300)))));
    const gap: f32 = 10;
    const width = (r.w - gap * @as(f32, @floatFromInt(n - 1))) / @as(f32, @floatFromInt(n));
    for (map.vmas[first .. first + n], 0..) |vma, i| {
        const box = Rect{ .x = r.x + @as(f32, @floatFromInt(i)) * (width + gap), .y = r.y, .w = width, .h = r.h };
        try ctx.r.shape(box, if (vma.start <= focus and focus < vma.end) ctx.p.selection else ctx.p.raised, .{ .radii = @splat(8) });
        const series = v.memmap.history.get(vma);
        const graph = Rect{ .x = box.x + box.w - @min(110, box.w * 0.34) - 10, .y = box.y + 24, .w = @min(110, box.w * 0.34), .h = 18 };
        var buf: [144]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s}  {s}", .{ vma.perms, mm.vmaText(v, vma) }) catch "";
        try ctx.textFit(box.x + 10, box.y + 3, box.w - 20, label, ctx.p.text);
        // Current coverage comes from this map even if history hit its cap or
        // could not allocate. A retained history point is never a fresh value.
        const fraction = history.coverage(vma);
        const text = if (fraction) |f| std.fmt.bufPrint(&buf, "{d:.1}% huge", .{f * 100}) catch "" else "huge unknown";
        try ctx.textFit(box.x + 10, box.y + 24, graph.x - box.x - 22, text, ctx.p.dim);
        if (series) |s| try spark(ctx, graph, s) else try ctx.hatchLight(graph);
        v.hit(box, .{ .memmap = .{ .vma_address = vma.start } });
        v.hover(box, "VMA 0x{x}–0x{x}: AnonHugePages / whole VMA span; {d} actual scans, gaps are unmeasured{s}", .{ vma.start, vma.end, if (series) |s| s.len else @as(usize, 0), if (v.memmap.history.omitted > 0) "; history range limit reached" else "" });
    }
}

fn spark(ctx: Ctx, r: Rect, series: *const history.Series) !void {
    if (series.len == 0) return;
    const oldest = series.back(series.len - 1).?.sampled_ns;
    const newest = series.back(0).?.sampled_ns;
    var previous: ?[2]f32 = null;
    var i = series.len;
    while (i > 0) {
        i -= 1;
        const sample = series.back(i).?;
        const value = sample.fraction orelse {
            previous = null;
            continue;
        };
        const x = if (newest > oldest) @as(f32, @floatFromInt(sample.sampled_ns -| oldest)) / @as(f32, @floatFromInt(newest - oldest)) else 1;
        const point = [2]f32{ r.x + x * r.w, r.y + (1 - value) * (r.h - 2) + 1 };
        if (previous) |p| try ctx.line(p, point, 1.5, ctx.p.accent3) else try ctx.r.rect(.{ .x = point[0], .y = point[1], .w = 2, .h = 2 }, ctx.p.accent3);
        previous = point;
    }
}
