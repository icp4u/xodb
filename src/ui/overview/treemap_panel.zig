const std = @import("std");
const c = @import("../../c.zig").api;
const vw = @import("view.zig");
const draw = @import("draw.zig");
const model = @import("treemap_model.zig");
const system = @import("../../model/system.zig");
const Input = @import("../../platform/input.zig").Event;
pub fn holder(v: *vw.View) void {
    const tree = v.treemap.tree orelse return;
    var who: c.struct_xrt_fdtreemap_holder = undefined;
    if (c.xrt_fdtreemap_holder(tree, v.treemap.focus, &who) != c.XRT_OK) return;
    v.files.scope(.{ .pid = who.pid, .start = who.start });
    v.show(.files);
}
pub fn key(v: *vw.View, event: Input) bool {
    if (event.kind != .press or !event.plain()) return false;
    switch (event.sym) {
        0xff1b => v.treemap.select(0),
        0xff08 => v.treemap.up(),
        0xff0d, 0xff8d => {}, // Enter never attaches from a path aggregate.
        else => switch (event.shortcut) {
            'e' => v.treemap.toggleEvents(),
            'l' => holder(v),
            '+', '=' => {
                v.treemap.max_tiles = @min(256, v.treemap.max_tiles * 2);
                v.treemap.dirty = true;
            },
            '-' => {
                v.treemap.max_tiles = @max(8, v.treemap.max_tiles / 2);
                v.treemap.dirty = true;
            },
            else => return false,
        },
    }
    return true;
}
fn button(v: *vw.View, ctx: draw.Ctx, r: draw.Rect, text: []const u8, action: vw.View.Action) !void {
    try ctx.r.rect(r, ctx.p.raised);
    try ctx.textFit(r.x + 6, r.y + 3, r.w - 12, text, ctx.p.text);
    v.hit(r, action);
}
pub fn render(v: *vw.View, ctx: draw.Ctx, rect: draw.Rect, now: u64) !void {
    const state = &v.treemap;
    var b: [640]u8 = undefined;
    var failure: [320]u8 = undefined;
    try ctx.textFit(rect.x + 8, rect.y + 4, rect.w - 16, "Descriptor path treemap · area = open handles", ctx.p.text);
    const banner: []const u8 = if (state.flow_running) system.graph_cost else if (v.paused) "PAUSED · tracing stopped" else if (!state.events_enabled) "POLLING · E to start live syscall tracing (~11% host cost)" else if (state.flow_status != c.XRT_OK and state.flow_status != c.XRT_STALE_SNAPSHOT)
        std.fmt.bufPrint(&b, "POLLING · {s} · E off/on retries", .{system.failureText(&failure, state.failure)}) catch "POLLING · tracing unavailable"
    else
        "Starting live syscall tracing (~11% host cost) · E to stop";
    try ctx.textFit(rect.x + 8, rect.y + 30, rect.w - 16, banner, ctx.p.warn);
    const tree = state.tree orelse {
        try ctx.textFit(rect.x + 8, rect.y + 64, rect.w - 16, if (state.build_status == c.XRT_OUT_OF_MEMORY) "Treemap unavailable: out of memory" else if (v.action_hook == null) "Descriptor data unavailable in this replay" else "Waiting for descriptor snapshot", ctx.p.dim);
        return;
    };
    const metric = tree.nodes[state.focus].total;
    const totals = std.fmt.bufPrint(&b, "{d} handles · {d} stale · {d} deleted · {d} unknown paths · {d} unexpanded", .{ metric.descriptors, metric.stale, metric.deleted, metric.unknown_paths, metric.unexpanded }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 56, rect.w - 16, totals, ctx.p.dim);
    const coverage = std.fmt.bufPrint(&b, "Scan: {d} denied / {d} unscanned / {d} gone · capped {d} processes / {d} fds · age {d:.1}s", .{ tree.denied, tree.unscanned, tree.gone, tree.dropped_processes, tree.dropped_fds, @as(f64, @floatFromInt(now -| tree.taken_ns)) / 1e9 }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 78, rect.w - 16, coverage, ctx.p.dim);
    const io = if (metric.flow_measured > 0) std.fmt.bufPrint(&b, "Sampled IO: {d:.0} read / {d:.0} write B/s · {d} handles measured · lost {d} / unattributed {d} B", .{ if (state.flow_running and !v.paused) metric.read_rate else 0, if (state.flow_running and !v.paused) metric.write_rate else 0, metric.flow_measured, state.lost, state.unknown }) catch "" else "Sampled IO not measured · offset progress is separate from syscall bytes";
    try ctx.textFit(rect.x + 8, rect.y + 100, rect.w - 16, io, ctx.p.dim);
    const note = if (state.focus_lost) "Selected path vanished or exceeded limits; returned to root" else if (state.poll_status != c.XRT_OK or state.build_status != c.XRT_OK) "Snapshot update unavailable; showing previous data" else "Path groups may combine different inodes/namespaces · blue: unmeasured, warm: sampled IO";
    try ctx.textFit(rect.x + 8, rect.y + 122, rect.w - 16, note, ctx.p.warn);
    const trace_coverage = std.fmt.bufPrint(&b, "Tracing: {d}/{d} CPUs · lost {d} events · unattributed {d} B · {s}", .{ state.active_cpus, state.online_cpus, state.lost, state.unknown, if (tree.flow_flags != 0 or tree.count_flags != 0) "incomplete or limited coverage" else "sampled association" }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 144, rect.w - 16, trace_coverage, ctx.p.dim);
    try button(v, ctx, .{ .x = rect.x + 8, .y = rect.y + 174, .w = 64, .h = 26 }, "Up", .treemap_up);
    try button(v, ctx, .{ .x = rect.x + 80, .y = rect.y + 174, .w = 64, .h = 26 }, "Root", .{ .treemap_node = 0 });
    try button(v, ctx, .{ .x = rect.x + 152, .y = rect.y + 174, .w = 248, .h = 26 }, "L: sampled holder Files", .treemap_holder);
    var path: [4098]u8 = undefined;
    var escaped: [512]u8 = undefined;
    var size: usize = 0;
    const name = if (v.redact) "path redacted" else if (c.xrt_fdtreemap_path(tree, state.focus, &path, path.len, &size) == c.XRT_OK) model.label(&escaped, path[0 .. size - 1]) else "path unavailable";
    try ctx.textFit(rect.x + 8, rect.y + 208, rect.w - 16, name, ctx.p.text);
    const body = draw.Rect{ .x = rect.x + 8, .y = rect.y + 236, .w = @max(1, rect.w - 16), .h = @max(1, rect.h - 274) };
    try state.project(std.math.clamp(@as(f64, body.w) / body.h, 0.01, 100));
    const layout = state.layout orelse return;
    const clip = ctx.r.clip;
    defer ctx.r.clip = clip;
    ctx.r.clip = draw.intersect(clip, body);
    for (layout.tiles[0..layout.count], 0..) |tile, index| {
        const r = draw.Rect{ .x = body.x + body.w * tile.x, .y = body.y + body.h * tile.y, .w = @max(0, body.w * tile.w - 2), .h = @max(0, body.h * tile.h - 2) };
        if (r.w < 1 or r.h < 1) continue;
        const measured = tile.metric.flow_measured > 0;
        const rate = if (state.flow_running and !v.paused) tile.metric.read_rate + tile.metric.write_rate else 0;
        const color = if (tile.metric.stale == tile.metric.descriptors) ctx.p.dim else if (rate > 0) ctx.p.warn else if (measured) ctx.p.ok else ctx.p.accent;
        const heat: f32 = @floatCast(@min(0.65, @log(1 + rate / 1024) * 0.07));
        try ctx.r.rect(r, draw.fade(color, 0.18 + heat));
        const node = tree.nodes[if (tile.node < tree.count) tile.node else state.focus];
        const label = switch (tile.kind) {
            c.XRT_FDT_OTHER => "Other (tile limit)",
            c.XRT_FDT_OVERFLOW => "Unexpanded paths",
            c.XRT_FDT_DIRECT => "Handles here",
            else => if (v.redact) "path redacted" else if (node.name_length == 0) "[empty component]" else model.label(&escaped, tree.text[node.name..][0..node.name_length]),
        };
        if (r.w >= 40 and r.h >= 28) try ctx.textFit(r.x + 6, r.y + 4, r.w - 12, label, ctx.p.text);
        if (r.w >= 70 and r.h >= 54) {
            const counts = std.fmt.bufPrint(&b, "{d} handles", .{tile.metric.descriptors}) catch "";
            try ctx.textFit(r.x + 6, r.y + 28, r.w - 12, counts, ctx.p.text);
        }
        if (r.w >= 160 and r.h >= 80) {
            const rates = if (measured) std.fmt.bufPrint(&b, "R {d:.0} / W {d:.0} B/s", .{ if (state.flow_running and !v.paused) tile.metric.read_rate else 0, if (state.flow_running and !v.paused) tile.metric.write_rate else 0 }) catch "" else "IO not measured";
            try ctx.textFit(r.x + 6, r.y + 52, r.w - 12, rates, ctx.p.dim);
        }
        if (tile.kind == c.XRT_FDT_CHILD) v.hit(r, .{ .treemap_node = tile.node });
        v.hover(r, "{s}: {d} handles; {d} measured; {d} stale; {d} deleted; {d} unexpanded; {d} grouped items", .{ label, tile.metric.descriptors, tile.metric.flow_measured, tile.metric.stale, tile.metric.deleted, tile.metric.unexpanded, tile.hidden_items });
        if (c.getenv("XODB_OVERVIEW_AUDIT") != null) std.debug.print("xodb: fdtreemap-tile focus={d} index={d} node={d} kind={d} fds={d} x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n", .{ state.focus, index, tile.node, tile.kind, tile.metric.descriptors, r.x, r.y, r.w, r.h });
    }
    ctx.r.clip = clip;
    if (layout.count == 0) try ctx.textFit(body.x + 8, body.y + 8, body.w - 16, "No descriptors represented at this path", ctx.p.dim);
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 26, rect.w - 16, "Click to zoom · Backspace up · Esc root · +/- tile limit · E tracing · P pause", ctx.p.dim);
}
