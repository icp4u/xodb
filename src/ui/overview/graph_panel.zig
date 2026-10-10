const std = @import("std");
const c = @import("../../c.zig").api;
const vw = @import("view.zig");
const draw = @import("draw.zig");
const fm = @import("files_model.zig");
const Input = @import("../../platform/input.zig").Event;

pub fn key(v: *vw.View, event: Input) bool {
    if (event.kind != .press or !event.plain()) return false;
    if (event.sym == 0xff1b) {
        v.graph.all();
        return true;
    }
    switch (event.shortcut) {
        'e' => {
            v.graph.toggleEvents();
            return true;
        },
        'c' => {
            v.graph.collapse = !v.graph.collapse;
            v.graph.dirty = true;
            return true;
        },
        '+', '=' => {
            v.graph.max_stars = @min(128, v.graph.max_stars * 2);
            v.graph.dirty = true;
            return true;
        },
        '-' => {
            v.graph.max_stars = @max(8, v.graph.max_stars / 2);
            v.graph.dirty = true;
            return true;
        },
        'l' => if (v.graph.focus) |id| {
            v.files.scope(.{ .pid = id.pid, .start = id.start });
            v.show(.files);
            return true;
        },
        else => {},
    }
    return false;
}
pub fn openResource(v: *vw.View, node: u32) void {
    const g = v.graph.graph orelse return;
    if (node >= g.node_count or g.nodes[node].type != c.XRT_FDG_RESOURCE) return;
    const n = g.nodes[node];
    if (n.flags & c.XRT_FDG_IDENTITY_UNKNOWN == 0) {
        v.files.all();
        v.files.file_filter = .{ .device = n.device, .inode = n.inode };
        v.files.show(.files);
    } else {
        const owner = g.nodes[n.source_process];
        v.files.scope(.{ .pid = owner.pid, .start = owner.start });
    }
    v.show(.files);
}
fn kindColor(ctx: draw.Ctx, kind: u32) draw.Color {
    return switch (kind) {
        c.XRT_FD_PIPE => ctx.p.accent2,
        c.XRT_FD_SOCKET => ctx.p.ok,
        c.XRT_FD_MEMFD => ctx.p.warn,
        c.XRT_FD_ANON => ctx.p.dim,
        c.XRT_FD_DEVICE => ctx.p.crit,
        else => ctx.p.accent,
    };
}
fn dot(ctx: draw.Ctx, x: f32, y: f32, radius: f32, color: draw.Color) !void {
    try ctx.r.shape(.{ .x = x - radius, .y = y - radius, .w = radius * 2, .h = radius * 2 }, color, .{ .radii = @splat(radius) });
}
fn starLabel(v: *vw.View, index: u32, buffer: []u8) []const u8 {
    const p = v.graph.projection.?;
    const g = v.graph.graph.?;
    const s = v.graph.snapshot.?;
    const star = p.stars[index];
    if (star.mixed_groups != 0) return std.fmt.bufPrint(buffer, "{d} processes · grouped", .{star.processes}) catch "grouped";
    if (star.processes > 1) {
        const group = v.graph.cgroup(star.sample_node);
        return if (v.redact or group.len == 0) std.fmt.bufPrint(buffer, "cgroup · {d} processes", .{star.processes}) catch "group" else std.fs.path.basename(group);
    }
    const node = g.nodes[star.source_node];
    if (v.redact or node.source_process >= s.process_count) return std.fmt.bufPrint(buffer, "pid {d}", .{node.pid}) catch "process";
    return fm.State.churnLabel(buffer, fm.State.name(@ptrCast(&s.processes[node.source_process])), node.pid, 24);
}
fn drawStar(v: *vw.View, ctx: draw.Ctx, index: u32, at: [2]f32, label_width: f32) !void {
    const s = v.graph.projection.?.stars[index];
    const color = if (s.denied != 0) ctx.p.warn else if (s.stale != 0 or s.cgroup_stale != 0) ctx.p.dim else ctx.p.text;
    const flow = if (v.graph.metrics) |metrics| metrics.stars[index] else std.mem.zeroes(c.struct_xrt_fdflow_metric);
    const radius: f32 = (if (s.processes > 1) @as(f32, 9) else 6) + growth(flow);
    const energy = pulse(v, flow, @import("../../target/linux.zig").now());
    try dot(ctx, at[0], at[1], radius + 5 + energy * 5, draw.fade(color, 0.12 + energy * 0.2));
    try dot(ctx, at[0], at[1], radius, color);
    const hit = draw.Rect{ .x = at[0] - 14, .y = at[1] - 14, .w = 28, .h = 28 };
    v.hit(hit, .{ .graph_star = index });
    if (c.getenv("XODB_OVERVIEW_AUDIT") != null) {
        const pid: i32 = if (s.source_node < v.graph.graph.?.processes) v.graph.graph.?.nodes[s.source_node].pid else 0;
        std.debug.print("xodb: fdgraph-star panel={s} star={d} pid={d} x={d:.1} y={d:.1}\n", .{ @tagName(v.panel), index, pid, at[0], at[1] });
    }
    var label: [96]u8 = undefined;
    const name = starLabel(v, index, &label);
    if (s.denied == s.processes and s.denied != 0)
        v.hover(hit, "{s} · fd table denied; needs /proc access · click for process", .{name})
    else
        v.hover(hit, "{s} · {d} processes · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} cached memberships · sampled inode joins", .{ name, s.processes, s.descriptors, flow.read_rate, flow.write_rate, s.cgroup_stale });
    if (label_width > 0) {
        const width = @min(label_width, ctx.measure(name));
        // The classic skin has no glow to lift a label off the links and dots under it.
        if (ctx.p.win95) try ctx.r.rect(.{ .x = @round(at[0] - width / 2) - 3, .y = @round(at[1] + 16) + 1, .w = width + 6, .h = 18 }, ctx.p.panel);
        try ctx.textFit(at[0] - width / 2, at[1] + 16, width, name, color);
    }
}
fn point(rect: draw.Rect, vertex: c.struct_xrt_fdgraph_vertex) [2]f32 {
    return .{ rect.x + vertex.x * rect.w, rect.y + vertex.y * rect.h };
}

fn growth(metric: c.struct_xrt_fdflow_metric) f32 {
    return @floatCast(@min(7.0, @log(1.0 + (metric.read_rate + metric.write_rate) / 1024.0)));
}
fn pulse(v: *const vw.View, metric: c.struct_xrt_fdflow_metric, now: u64) f32 {
    if (!v.graph.flow_running or v.paused or metric.last_ns == 0) return 0;
    return 1.0 - @as(f32, @floatFromInt(@min(700_000_000, now -| metric.last_ns))) / 700_000_000.0;
}

pub fn render(v: *vw.View, ctx: draw.Ctx, rect: draw.Rect, now: u64) !void {
    var buffer: [512]u8 = undefined;
    var failure_buffer: [320]u8 = undefined;
    try ctx.textFit(rect.x + 8, rect.y + 4, rect.w - 16, if (v.panel == .galaxy) "Descriptor galaxy" else "Shared files & IPC", ctx.p.text);
    try ctx.r.shape(.{ .x = rect.x + 8, .y = rect.y + 32, .w = rect.w - 16, .h = 30 }, draw.fade(ctx.p.warn, 0.12), .{ .radii = @splat(5) });
    const banner: []const u8 = if (v.graph.flow_running)
        @import("../../model/system.zig").graph_cost
    else if (v.paused) "PAUSED · tracing stopped" else if (!v.graph.events_enabled) "POLLING · E to start live syscall tracing (~11% host cost)" else if (v.graph.flow_status != c.XRT_OK and v.graph.flow_status != c.XRT_STALE_SNAPSHOT)
        std.fmt.bufPrint(&buffer, "POLLING · {s} · E off/on retries", .{@import("../../model/system.zig").failureText(&failure_buffer, v.graph.flow_failure)}) catch "POLLING · tracing unavailable"
    else
        "Starting live syscall tracing (~11% host cost) · E to stop";
    try ctx.textFit(rect.x + 16, rect.y + 38, rect.w - 32, banner, ctx.p.warn);
    const g = v.graph.graph orelse {
        try ctx.textFit(rect.x + 12, rect.y + 84, rect.w - 24, v.graph.failure() orelse "Waiting for descriptor snapshot", ctx.p.dim);
        return;
    };
    const p = v.graph.projection orelse return;
    const stats = std.fmt.bufPrint(&buffer, "{d} processes · {d} fds · {d} denied · {d} stale · {d} unknown · CPUs {d}/{d} · lost {d}", .{ g.processes, g.member_count, g.denied_processes, g.stale_descriptors, g.unknown_descriptors, if (v.graph.flow_running) v.graph.flow_active_cpus else 0, v.graph.flow_online_cpus, v.graph.flow_lost }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 72, rect.w - 16, stats, ctx.p.dim);
    const omissions = std.fmt.bufPrint(&buffer, "{d} unscanned · {d} gone · capped: {d} processes / {d} fds · {d} unmatched peers", .{ g.unscanned_processes, g.gone_processes, g.dropped_processes, g.dropped_descriptors, g.unmatched_peers }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + 94, rect.w - 16, omissions, ctx.p.dim);
    if (v.graph.failure()) |reason| {
        const failure = std.fmt.bufPrint(&buffer, "{s} · showing previous snapshot ({d:.1}s old)", .{ reason, @as(f64, @floatFromInt(now -| g.taken_ns)) / 1_000_000_000.0 }) catch reason;
        try ctx.textFit(rect.x + 8, rect.y + 116, rect.w - 16, failure, ctx.p.warn);
    }
    const body = draw.Rect{ .x = rect.x + 24, .y = rect.y + 150, .w = @max(1, rect.w - 48), .h = @max(1, rect.h - 234) };
    const clip = ctx.r.clip;
    ctx.r.clip = body;
    defer ctx.r.clip = clip;
    if (v.panel == .galaxy) {
        const cols: u32 = @max(1, @as(u32, @intFromFloat(@sqrt(@as(f32, @floatFromInt(p.star_count)) * body.w / body.h))));
        const rows = @max(1, (p.star_count + cols - 1) / cols);
        const width = body.w / @as(f32, @floatFromInt(cols));
        const height = body.h / @as(f32, @floatFromInt(rows));
        for (0..p.star_count) |i| {
            const x = body.x + (@as(f32, @floatFromInt(i % cols)) + 0.5) * width;
            const y = body.y + (@as(f32, @floatFromInt(i / cols)) + 0.44) * height;
            const radius = @max(14, @min(width, height) * 0.30) * 0.75;
            try ctx.r.shape(.{ .x = x - radius, .y = y - radius, .w = radius * 2, .h = radius * 2 }, draw.fade(ctx.p.accent, 0.16), .{ .radii = @splat(radius), .border = 1 });
        }
        for (p.particles[0..p.particle_count], 0..) |particle, i| {
            const center = [2]f32{ body.x + (@as(f32, @floatFromInt(particle.star % cols)) + 0.5) * width, body.y + (@as(f32, @floatFromInt(particle.star / cols)) + 0.44) * height };
            const angle: f32 = @as(f32, @floatFromInt(i)) * 2.3999632;
            const spread: f32 = if (p.star_count == 1 and particle.source_fd != std.math.maxInt(u32)) @sqrt(@as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(p.particle_count))) else 0.75;
            const orbit = @max(14, @min(width, height) * 0.30) * spread;
            const at = [2]f32{ center[0] + @cos(angle) * orbit, center[1] + @sin(angle) * orbit };
            const flow = if (v.graph.metrics) |metrics| metrics.particles[i] else std.mem.zeroes(c.struct_xrt_fdflow_metric);
            const radius: f32 = growth(flow) + if (particle.descriptors > 1) @min(11, 3 + @log(@as(f32, @floatFromInt(particle.descriptors)))) else 3;
            const color = kindColor(ctx, particle.kind);
            const energy = pulse(v, flow, now);
            if (energy > 0) try dot(ctx, at[0], at[1], radius + 4 + energy * 3, draw.fade(color, energy * 0.3));
            if (particle.deleted > 0) try dot(ctx, at[0], at[1], radius + 4, draw.fade(ctx.p.crit, 0.3));
            try dot(ctx, at[0], at[1], radius, draw.fade(color, if (particle.stale > 0) 0.5 else 0.95));
            const hit = draw.Rect{ .x = at[0] - radius - 2, .y = at[1] - radius - 2, .w = (radius + 2) * 2, .h = (radius + 2) * 2 };
            if (particle.source_node != std.math.maxInt(u32)) v.hit(hit, .{ .graph_resource = particle.source_node });
            v.hover(hit, "{s} · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} deleted · sampled inode joins", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(particle.kind))), particle.descriptors, flow.read_rate, flow.write_rate, particle.deleted });
        }
        for (0..p.star_count) |i| try drawStar(v, ctx, @intCast(i), .{ body.x + (@as(f32, @floatFromInt(i % cols)) + 0.5) * width, body.y + (@as(f32, @floatFromInt(i / cols)) + 0.44) * height }, if (height > 70) @max(0, width - 16) else 0);
    } else if (v.graph.layout) |layout| {
        for (layout.links[0..layout.link_count], 0..) |link, i| {
            const flow = if (v.graph.metrics) |metrics| metrics.links[i] else std.mem.zeroes(c.struct_xrt_fdflow_metric);
            const energy = pulse(v, flow, now);
            const color = if (link.kind == c.XRT_FDG_UNIX_PEER) ctx.p.ok else ctx.p.accent2;
            const from = point(body, layout.vertices[link.from]);
            const to = point(body, layout.vertices[link.to]);
            try ctx.line(from, to, 1 + growth(flow) * 0.4 + energy, draw.fade(color, @min(0.95, (if (link.flags & c.XRT_FDG_STALE != 0) @as(f32, 0.13) else 0.4) + energy * 0.4)));
            if (energy > 0) {
                const phase = @as(f32, @floatFromInt(now % 700_000_000)) / 700_000_000.0;
                const along = if (link.kind == c.XRT_FDG_UNIX_PEER) @as(f32, 0.5) else if (flow.write_rate >= flow.read_rate) phase else 1 - phase;
                try dot(ctx, from[0] + (to[0] - from[0]) * along, from[1] + (to[1] - from[1]) * along, 2 + energy * 2, draw.fade(color, energy));
            }
        }
        for (layout.vertices[layout.star_count..layout.vertex_count], layout.star_count..) |vertex, i| {
            const n = g.nodes[vertex.source_node];
            const at = point(body, vertex);
            const color = kindColor(ctx, n.kind);
            const flow = if (v.graph.metrics) |metrics| metrics.vertices[i] else std.mem.zeroes(c.struct_xrt_fdflow_metric);
            try dot(ctx, at[0], at[1], 4 + growth(flow), color);
            const hit = draw.Rect{ .x = at[0] - 7, .y = at[1] - 7, .w = 14, .h = 14 };
            v.hit(hit, .{ .graph_resource = vertex.source_node });
            v.hover(hit, "{s} · {d} holders · inode {d} · read {d:.0} B/s / write {d:.0} B/s · sampled", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(n.kind))), n.holders, n.inode, flow.read_rate, flow.write_rate });
        }
        for (layout.vertices[0..layout.star_count], 0..) |vertex, i| try drawStar(v, ctx, @intCast(i), point(body, vertex), if (layout.star_count > 12) 0 else if (ctx.p.win95 and layout.star_count <= 4) 200 else 120);
    }
    ctx.r.clip = clip;
    const group_text = std.fmt.bufPrint(&buffer, "{d} stars · {d} particles · cgroups: {d} fresh / {d} cached / {d} unknown · UNIX peers: {s}", .{ p.star_count, p.particle_count, g.cgroup_processes, g.cgroup_stale_processes, g.processes - g.cgroup_processes - g.cgroup_stale_processes, if (v.graph.peer_status == c.XRT_OK) "current namespace" else v.graph.peer_reason orelse "unavailable" }) catch "";
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 72, rect.w - 16, group_text, ctx.p.dim);
    if (v.graph.layout) |layout| {
        const limit_text = std.fmt.bufPrint(&buffer, "Sampled joins · {d} bytes unattributed · {d} resources / {d} links omitted · {s}", .{ v.graph.flow_unknown, layout.omitted_resources, layout.omitted_links, if (v.graph.flow_flags != 0) "capture incomplete" else "no capture loss reported" }) catch "";
        try ctx.textFit(rect.x + 8, rect.y + rect.h - 48, rect.w - 16, limit_text, if (layout.omitted_resources + layout.omitted_links > 0) ctx.p.warn else ctx.p.dim);
    }
    try ctx.textFit(rect.x + 8, rect.y + rect.h - 24, rect.w - 16, "E tracing on/off · C cgroups · +/- detail · Esc all · click expand/holders · L files", ctx.p.dim);
}
