//! Descriptor and seeded-demo sources for the neutral galaxy model.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const vw = @import("view.zig");
const fm = @import("files_model.zig");
const panel = @import("graph_panel.zig");
const model = @import("galaxy_model.zig");
const Scene = model.Scene;
const max_stars = model.max_stars;
const max_particles = model.max_particles;
const max_junctions = model.max_junctions;
const max_clusters = model.max_clusters;
const none = model.none;
const mix = model.mix;
const hash = model.hash;
const Rng = model.Rng;

pub fn projectionDetailBudget(stars: u32) u32 {
    return @max(1024, stars * c.XRT_FD_KINDS);
}
const LiveNames = struct {
    v: *vw.View,
    keys: []const u64,
    by_name: []const bool,
    pub fn cluster(self: LiveNames, star: u32, buffer: []u8) []const u8 {
        const p = self.v.graph.projection.?;
        const g = self.v.graph.graph.?;
        const s = self.v.graph.snapshot.?;
        const record = p.stars[star];
        if (self.v.redact) return std.fmt.bufPrint(buffer, "group {x:0>4}", .{self.keys[star] & 0xffff}) catch "";
        if (self.by_name[star] and record.source_node < g.processes and g.nodes[record.source_node].source_process < s.process_count)
            return std.fmt.bufPrint(buffer, "{s}", .{clip(fm.State.name(@ptrCast(&s.processes[g.nodes[record.source_node].source_process])), buffer.len)}) catch "";
        const path = self.v.graph.cgroup(if (record.processes > 1) record.sample_node else record.source_node);
        const base = std.fs.path.basename(path);
        return std.fmt.bufPrint(buffer, "{s}", .{clip(if (base.len > 0) base else if (path.len > 0) "root cgroup" else "no cgroup", buffer.len)}) catch "";
    }
};
fn clip(text: []const u8, limit: usize) []const u8 {
    var n = @min(text.len, limit);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    return text[0..n];
}

/// Fills the scene from the published graph, projection, layout and flow metrics.
pub fn fromLive(s: *Scene, v: *vw.View) void {
    s.reset();
    s.synthetic = false;
    const p = v.graph.projection orelse return;
    const g = v.graph.graph orelse return;
    const snap = v.graph.snapshot orelse return;
    const metrics = v.graph.metrics;
    const zero = std.mem.zeroes(c.struct_xrt_fdflow_metric);
    const n: u32 = @min(p.star_count, max_stars);
    const S = struct {
        var keys: [max_stars]u64 = undefined;
        var names: [max_stars]u64 = undefined;
        var sorted: [max_stars]u64 = undefined;
        var by_name: [max_stars]bool = undefined;
    };
    // Process stars cluster by cgroup. Where cgroups say little (a flat host),
    // processes that share a name form the clusters instead.
    var singles: u32 = 0;
    var groups: u32 = 0;
    for (0..n) |i| {
        const record = p.stars[i];
        const single = record.processes == 1 and record.source_node < g.processes;
        const path = v.graph.cgroup(if (single) record.source_node else record.sample_node);
        const node = if (record.source_node < g.processes) g.nodes[record.source_node] else std.mem.zeroes(c.struct_xrt_fdgraph_node);
        var buffer: [96]u8 = undefined;
        const flow = if (metrics) |m| m.stars[i] else zero;
        const seed = if (single) mix(@as(u64, @bitCast(@as(i64, node.pid))) ^ mix(node.start)) else if (record.mixed_groups != 0) mix(0x6d69786564) else hash(path) ^ 1;
        S.keys[i] = if (single) hash(path) else seed;
        S.names[i] = if (single and node.source_process < snap.process_count) hash(fm.State.name(@ptrCast(&snap.processes[node.source_process]))) else 0;
        S.by_name[i] = false;
        if (single) {
            singles += 1;
            var seen = false;
            for (S.keys[0..i]) |key| seen = seen or key == S.keys[i];
            if (!seen) groups += 1;
        }
        _ = s.addStar(.{ .seed = seed, .members = record.processes, .units = record.descriptors, .incoming = flow.read_rate, .outgoing = flow.write_rate, .last_ns = flow.last_ns, .unavailable = record.denied != 0 and record.denied == record.processes, .stale = record.stale != 0 or record.cgroup_stale != 0 }, panel.starLabel(v, @intCast(i), &buffer));
    }
    if (singles > 12 and groups < 3) {
        @memcpy(S.sorted[0..n], S.names[0..n]);
        std.mem.sort(u64, S.sorted[0..n], {}, std.sort.asc(u64));
        for (0..n) |i| {
            if (S.names[i] == 0) continue;
            const at = std.sort.lowerBound(u64, S.sorted[0..n], S.names[i], struct {
                fn order(want: u64, item: u64) std.math.Order {
                    return std.math.order(want, item);
                }
            }.order);
            if (at + 1 < n and S.sorted[at + 1] == S.names[i]) {
                S.keys[i] = S.names[i];
                S.by_name[i] = true;
            }
        }
    }
    for (s.stars[0..s.star_count], 0..) |*star, i| star.key = S.keys[i];
    for (p.particles[0..@min(p.particle_count, max_particles)], 0..) |particle, i| {
        const flow = if (metrics) |m| m.particles[i] else zero;
        s.addParticle(.{ .star = @intCast(@min(particle.star, max_stars)), .kind = @intCast(particle.kind), .stale = particle.stale > 0, .units = particle.descriptors, .alerts = particle.deleted, .incoming = flow.read_rate, .outgoing = flow.write_rate, .last_ns = flow.last_ns, .node = particle.source_node });
    }
    s.group(LiveNames{ .v = v, .keys = S.keys[0..n], .by_name = S.by_name[0..n] });
    const l = v.graph.layout orelse return;
    if (l.star_count != p.star_count or l.star_count > max_stars) return;
    // One pass finds each shared descriptor's holders; two holders make a
    // direct thread, more meet at a junction.
    const Res = struct { first: u32 = none, second: u32 = none, holders: u32 = 0, peer: bool = false, junction: u32 = none };
    var res: [1024]Res = @splat(.{});
    const resources = @min(l.resource_count, res.len);
    const links = l.links[0..l.link_count];
    for (links, 0..) |link, i| {
        if (link.kind == c.XRT_FDG_UNIX_PEER) {
            for ([2]u32{ link.from, link.to }) |vertex| if (vertex >= l.star_count and vertex - l.star_count < resources) {
                res[vertex - l.star_count].peer = true;
            };
            continue;
        }
        if (link.from >= l.star_count or link.to < l.star_count or link.to - l.star_count >= resources) continue;
        const r = &res[link.to - l.star_count];
        if (r.holders == 0) r.first = @intCast(i) else if (r.holders == 1) r.second = @intCast(i);
        r.holders += 1;
    }
    const kindOf = struct {
        fn f(graph: *const c.struct_xrt_fdgraph, layout: *const c.struct_xrt_fdgraph_layout, vertex: u32) c.struct_xrt_fdgraph_node {
            const node = layout.vertices[vertex].source_node;
            return if (node < graph.node_count) graph.nodes[node] else std.mem.zeroes(c.struct_xrt_fdgraph_node);
        }
    }.f;
    for (res[0..resources], 0..) |*r, i| {
        const vertex: u32 = l.star_count + @as(u32, @intCast(i));
        const node = kindOf(g, l, vertex);
        if (r.holders == 2 and !r.peer) {
            const a = links[r.first];
            const b = links[r.second];
            const fa = if (metrics) |m| m.links[r.first] else zero;
            const fb = if (metrics) |m| m.links[r.second] else zero;
            // A holds link carries its star's writes out and its reads back.
            s.addStrand(.{ .a = @intCast(a.from), .b = @intCast(b.from), .kind = @intCast(node.kind), .stale = (a.flags | b.flags) & c.XRT_FDG_STALE != 0, .weight = a.descriptors + b.descriptors, .pulse = .{ .ab = if (fa.write_rate > 0) @max(fa.write_rate, fb.read_rate) else if (fa.read_rate == 0) fb.read_rate else 0, .ba = if (fb.write_rate > 0) @max(fb.write_rate, fa.read_rate) else if (fb.read_rate == 0) fa.read_rate else 0, .last_ns = @max(fa.last_ns, fb.last_ns) }, .seed = @truncate(mix(node.inode ^ node.device)) });
        } else if ((r.holders > 2 or (r.holders == 2 and r.peer)) and s.junction_count < max_junctions) {
            r.junction = s.junction_count;
            const flow = if (metrics) |m| m.vertices[vertex] else zero;
            s.junctions[s.junction_count] = .{ .kind = @intCast(node.kind), .node = l.vertices[vertex].source_node, .identity = node.inode ^ node.device, .incoming = flow.read_rate, .outgoing = flow.write_rate };
            s.junction_count += 1;
        }
    }
    for (links, 0..) |link, i| {
        const flow = if (metrics) |m| m.links[i] else zero;
        if (link.kind == c.XRT_FDG_UNIX_PEER) {
            if (link.from < l.star_count or link.to < l.star_count or link.from - l.star_count >= resources or link.to - l.star_count >= resources) continue;
            var ends: [2]u16 = undefined;
            var ok = true;
            for ([2]u32{ link.from, link.to }, 0..) |vertex, side| {
                const r = res[vertex - l.star_count];
                if (r.junction != none) ends[side] = @intCast(max_stars + r.junction) else if (r.holders == 1) ends[side] = @intCast(links[r.first].from) else ok = false;
            }
            if (!ok) continue;
            // What one end writes, its peer receives.
            const fa = if (metrics) |m| m.vertices[link.from] else zero;
            const fb = if (metrics) |m| m.vertices[link.to] else zero;
            s.addStrand(.{ .a = ends[0], .b = ends[1], .kind = c.XRT_FD_SOCKET, .peer = true, .stale = link.flags & c.XRT_FDG_STALE != 0, .weight = link.descriptors, .pulse = .{ .ab = fa.write_rate, .ba = fb.write_rate, .last_ns = flow.last_ns }, .seed = @truncate(mix(kindOf(g, l, link.from).inode ^ 0x70)) });
        } else if (link.from < l.star_count and link.to >= l.star_count and link.to - l.star_count < resources) {
            const junction = res[link.to - l.star_count].junction;
            if (junction == none) continue;
            s.addStrand(.{ .a = @intCast(link.from), .b = @intCast(max_stars + junction), .kind = s.junctions[junction].kind, .stale = link.flags & c.XRT_FDG_STALE != 0, .weight = link.descriptors, .pulse = .{ .ab = flow.write_rate, .ba = flow.read_rate, .last_ns = flow.last_ns }, .seed = @truncate(mix(s.junctions[junction].identity ^ link.from)) });
        }
    }
}

const demo_apps = [_][]const u8{ "web", "db", "cache", "queue", "shell", "build", "media", "sync", "mail", "audit", "proxy", "render", "index", "logs" };
const DemoNames = struct {
    s: *const Scene,
    pub fn cluster(self: DemoNames, star: u32, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}", .{demo_apps[self.s.stars[star].key % demo_apps.len]}) catch "";
    }
};
/// A seeded synthetic galaxy: no process is read. `idle` leaves every thread without flow.
pub fn demo(s: *Scene, count: u32, idle: bool, clock: u64) void {
    s.reset();
    s.synthetic = true;
    const n = std.math.clamp(count, 1, max_stars);
    var rng = Rng{ .state = @as(u64, 0x67616c617879) ^ n };
    const groups: u32 = if (n < 4) 1 else std.math.clamp(n / 7, 2, 12);
    var hubs: [16]u32 = @splat(none);
    var sizes: [16]u32 = @splat(0);
    for (0..n) |i| {
        const u = rng.next();
        const group: u32 = @min(groups - 1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(groups)) * std.math.pow(f32, u, 1.6))));
        const pid: u32 = 1000 + @as(u32, @intCast(i)) * 7 + group;
        var buffer: [40]u8 = undefined;
        const fds: u32 = 3 + @as(u32, @intFromFloat(@exp(rng.next() * 5.4)));
        const hot = i % 19 == 7;
        const star = s.addStar(.{ .seed = mix(pid), .key = group, .units = fds }, std.fmt.bufPrint(&buffer, "{s}[{d}]", .{ demo_apps[group % demo_apps.len], pid }) catch "") orelse break;
        _ = star;
        if (hubs[group] == none) hubs[group] = @intCast(i);
        sizes[group] += 1;
        const per: u32 = @min(5, max_particles / n);
        for (0..per) |k| {
            const kind: u8 = ([_]u8{ c.XRT_FD_REGULAR, c.XRT_FD_PIPE, c.XRT_FD_SOCKET, c.XRT_FD_ANON, c.XRT_FD_DEVICE })[k];
            s.addParticle(.{ .star = @intCast(i), .kind = kind, .units = @max(1, fds / (2 + @as(u32, @intCast(k)))), .alerts = if (hot and k == 0) 2 else 0 });
        }
    }
    const rate = struct {
        fn f(r: *Rng, quiet: bool, chance: f32) f64 {
            // Both draws always happen, so an idle scene has the same threads as a busy one.
            const on = r.next() <= chance;
            const value = 1024.0 * std.math.pow(f64, 2, r.next() * 14);
            return if (quiet or !on) 0 else value;
        }
    }.f;
    for (0..s.star_count) |i| {
        const group: u32 = @intCast(s.stars[i].key);
        const hub = hubs[group];
        if (hub != i and rng.next() < 0.75) s.addStrand(.{ .a = @intCast(hub), .b = @intCast(i), .kind = if (rng.next() < 0.5) c.XRT_FD_PIPE else c.XRT_FD_SOCKET, .weight = 1 + @as(u32, @intFromFloat(rng.next() * 3)), .pulse = .{ .ab = rate(&rng, idle, 0.3), .ba = rate(&rng, idle, 0.2), .last_ns = clock }, .seed = @truncate(rng.state) });
        if (i > 0 and rng.next() < 0.22) {
            var other: u32 = @intFromFloat(rng.next() * @as(f32, @floatFromInt(i)));
            if (s.stars[other].key != group) other = hub;
            s.addStrand(.{ .a = @intCast(i), .b = @intCast(other), .kind = c.XRT_FD_PIPE, .pulse = .{ .ab = rate(&rng, idle, 0.4), .last_ns = clock }, .seed = @truncate(rng.state) });
        }
    }
    for (0..groups) |group| {
        if (hubs[group] == none) continue;
        const next = hubs[(group + 1) % groups];
        if (next != none) s.addStrand(.{ .a = @intCast(hubs[group]), .b = @intCast(next), .kind = c.XRT_FD_SOCKET, .peer = true, .weight = 2, .pulse = .{ .ab = rate(&rng, idle, 0.7), .ba = rate(&rng, idle, 0.5), .last_ns = clock }, .seed = @truncate(mix(group)) });
        if (group >= 2) for (0..3) |k| s.addStrand(.{ .a = @intCast(hubs[group]), .b = @intCast(hubs[0]), .kind = c.XRT_FD_SOCKET, .peer = true, .pulse = .{ .ab = rate(&rng, idle, 0.5), .last_ns = clock }, .seed = @truncate(mix(group * 8 + k)) });
        // A file shared by several members meets at a junction.
        if (sizes[group] >= 4 and s.junction_count < max_junctions) {
            const junction = s.junction_count;
            s.junctions[junction] = .{ .kind = c.XRT_FD_REGULAR, .identity = mix(group ^ 0x66) };
            s.junction_count += 1;
            var holders: u32 = 0;
            for (0..s.star_count) |i| if (s.stars[i].key == group and holders < 5 and rng.next() < 0.6) {
                s.addStrand(.{ .a = @intCast(i), .b = @intCast(max_stars + junction), .kind = c.XRT_FD_REGULAR, .pulse = .{ .ab = rate(&rng, idle, 0.35), .ba = rate(&rng, idle, 0.35), .last_ns = clock }, .seed = @truncate(mix(i)) });
                holders += 1;
            };
        }
    }
    for (s.strands[0..s.strand_count]) |strand| for ([2]u16{ strand.a, strand.b }, [2]f64{ strand.pulse.ba, strand.pulse.ab }, [2]f64{ strand.pulse.ab, strand.pulse.ba }) |index, in, out| if (index < max_stars) {
        s.stars[index].incoming += in;
        s.stars[index].outgoing += out;
        if (in + out > 0) s.stars[index].last_ns = clock;
    };
    s.group(DemoNames{ .s = s });
}

const draw = @import("draw.zig");
const galaxy = @import("galaxy.zig");
const rateText = model.rateText;
const Palette = @import("theme.zig").Palette;
const Color = draw.Color;
fn descriptorColor(p: *const Palette, kind: u32) Color {
    return switch (kind) {
        c.XRT_FD_PIPE => p.accent2,
        c.XRT_FD_SOCKET => p.ok,
        c.XRT_FD_MEMFD => p.warn,
        c.XRT_FD_ANON => p.dim,
        c.XRT_FD_DEVICE => p.crit,
        else => p.accent,
    };
}
var state: galaxy.State = .{};
pub fn navigation() *galaxy.State {
    return &state;
}
pub fn render(v: *vw.View, ctx: draw.Ctx, field: draw.Rect, body: draw.Rect, reserved: []const draw.Rect, now: u64) !model.Counts {
    const st = &v.graph;
    if (!v.paused or st.clock == 0) st.clock = now;
    const s = &state.scene;
    if (st.demo != 0) demo(s, st.demo, st.demo_idle, st.clock) else fromLive(s, v);
    var selected: ?u64 = st.camera_cluster;
    if (selected == null and !s.synthetic) if (st.focus) |id| {
        if (st.projection) |p| if (st.graph) |g| {
            for (p.stars[0..s.star_count], 0..) |star, i| if (star.source_node < g.node_count and g.nodes[star.source_node].pid == id.pid) {
                selected = s.clusters[s.stars[i].cluster].key;
                break;
            };
        };
    };

    var host = Host{ .v = v, .graph = st, .pointer = v.pointer, .paused = v.paused };
    return galaxy.renderModel(&host, &state, ctx, field, body, reserved, selected, now);
}
const Host = struct {
    v: *vw.View,
    graph: *@import("graph_model.zig").State,
    pointer: [2]f32,
    paused: bool,
    pub fn kindColor(_: *Host, p: *const Palette, kind: u32) Color {
        return descriptorColor(p, kind);
    }
    pub fn clusterHit(self: *Host, hit: draw.Rect, key: u64) void {
        self.v.hit(hit, .{ .graph_cluster = key });
    }
    pub fn junctionName(_: *Host) []const u8 {
        return "shared descriptor";
    }
    pub fn junctionHit(self: *Host, hit: draw.Rect, junction: model.Junction) void {
        if (junction.node != none) self.v.hit(hit, .{ .graph_resource = junction.node });
        self.v.hover(hit, "{s} · {d} holders shown · read {d:.0} B/s / write {d:.0} B/s · sampled", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(junction.kind))), junction.holders, junction.incoming, junction.outgoing });
    }
    pub fn detailHit(self: *Host, hit: draw.Rect, particle: model.Detail) void {
        if (particle.node != none) self.v.hit(hit, .{ .graph_resource = particle.node });
        self.v.hover(hit, "{s} · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} deleted · sampled inode joins", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(particle.kind))), particle.units, particle.incoming, particle.outgoing, particle.alerts });
    }
    pub fn nodeHit(self: *Host, hit: draw.Rect, star: model.Node, i: u32, synthetic: bool, audit: bool) void {
        if (!synthetic) self.v.hit(hit, .{ .graph_star = @intCast(i) });
        if (audit and !synthetic) panel.auditStar(self.v, @intCast(i), star.at);
        if (star.unavailable and star.units == 0)
            self.v.hover(hit, "{s} · fd table denied; needs /proc access · click for process", .{star.label()})
        else
            self.v.hover(hit, "{s} · {d} processes · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} deleted · sampled inode joins", .{ star.label(), star.members, star.units, star.incoming, star.outgoing, star.alerts });
    }
    pub fn threadHit(self: *Host, hit: draw.Rect, strand: model.Edge) void {
        var forward: [24]u8 = undefined;
        var reverse: [24]u8 = undefined;
        // Short enough to fit the tooltip with both directions visible.
        self.v.hover(hit, "{s} thread · {d} shared · forward {s} / reverse {s}{s}", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(strand.kind))), strand.weight, rateText(&forward, strand.pulse.ab), rateText(&reverse, strand.pulse.ba), if (strand.stale) " · stale" else " · sampled" });
    }
    pub fn clusterCaption(_: *Host, cl: model.Cluster, caption_buffer: *[96]u8, rate_buffer: *[32]u8) []const u8 {
        return if (cl.rate > 0) std.fmt.bufPrint(caption_buffer, "{d} processes · {d} fds · {s}", .{ cl.members, cl.units, rateText(rate_buffer, cl.rate) }) catch "" else std.fmt.bufPrint(caption_buffer, "{d} processes · {d} fds", .{ cl.members, cl.units }) catch "";
    }
    pub fn nodeCaption(_: *Host, star: model.Node, caption_buffer: *[96]u8, rate_buffer: *[32]u8) []const u8 {
        const rate = star.incoming + star.outgoing;
        return if (star.unavailable and star.units == 0)
            "fd table denied"
        else if (star.alerts > 0)
            std.fmt.bufPrint(caption_buffer, "{d} fds · {d} deleted, still open", .{ star.units, star.alerts }) catch ""
        else if (star.members > 1)
            std.fmt.bufPrint(caption_buffer, "{d} processes · {d} fds", .{ star.members, star.units }) catch ""
        else if (rate > 0)
            std.fmt.bufPrint(caption_buffer, "{d} fds · {s}", .{ star.units, rateText(rate_buffer, rate) }) catch ""
        else
            std.fmt.bufPrint(caption_buffer, "{d} fds", .{star.units}) catch "";
    }
};

const max_strands = model.max_strands;
var test_scene: Scene = .{};

test "changed layout eases established identities without altering target layout" {
    const s = try std.testing.allocator.create(Scene);
    defer std.testing.allocator.destroy(s);
    s.* = .{};
    var moving = @import("galaxy_motion.zig").Motion{};
    demo(s, 24, true, 1);
    s.layout(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    _ = moving.layout(s, .{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, .{});
    const first = s.stars[0].at;
    s.layout(.{ .x = 200, .y = 0, .w = 800, .h = 600 });
    const target = s.stars[0].at;
    _ = moving.layout(s, .{ .x = 200, .y = 0, .w = 800, .h = 600 }, 30_000_001, .{});
    try std.testing.expect(moving.active and s.stars[0].at[0] > first[0] and s.stars[0].at[0] < target[0]);
    try std.testing.expectEqual(target[0], s.laid[0][0]);
    s.layout(.{ .x = 200, .y = 0, .w = 800, .h = 600 });
    _ = moving.layout(s, .{ .x = 200, .y = 0, .w = 800, .h = 600 }, 130_000_001, .{});
    try std.testing.expect(!moving.active and s.stars[0].at[0] == target[0]);
}

test "galaxy layout is deterministic, bounded and stays in the field" {
    const body = draw.Rect{ .x = 40, .y = 130, .w = 1000, .h = 520 };
    var first: [max_stars][3]f32 = undefined;
    for ([_]u32{ 1, 2, 24, 600, 5000 }) |count| {
        demo(&test_scene, count, false, 1_000_000_000);
        test_scene.signature = 0;
        test_scene.layout(body);
        test_scene.settle(1_000_000_000);
        const n = test_scene.star_count;
        try std.testing.expectEqual(@min(count, max_stars), n);
        try std.testing.expect(test_scene.strand_count <= max_strands and test_scene.cluster_count <= max_clusters and test_scene.particle_count <= max_particles);
        for (test_scene.stars[0..n], 0..) |star, i| {
            try std.testing.expect(star.at[0] >= body.x - 1 and star.at[0] <= body.x + body.w + 1 and star.at[1] >= body.y - 1 and star.at[1] <= body.y + body.h + 1);
            first[i] = .{ star.at[0], star.at[1], star.r };
        }
        if (count > 1) try std.testing.expect(test_scene.strand_count > 0);
        // Rebuilding from the same identities lands every star where it was, with and without the cache.
        for ([_]bool{ true, false }) |cached| {
            demo(&test_scene, count, true, 9_000_000_000);
            if (!cached) test_scene.signature = 0;
            test_scene.layout(body);
            for (test_scene.stars[0..n], 0..) |star, i| try std.testing.expectEqual(first[i], [3]f32{ star.at[0], star.at[1], star.r });
        }
        test_scene.settle(9_000_000_000);
        for (test_scene.strands[0..test_scene.strand_count]) |strand| try std.testing.expectEqual(@as(f64, 0), strand.pulse.ab + strand.pulse.ba);
    }
}
