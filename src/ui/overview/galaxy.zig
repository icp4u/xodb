//! The descriptor galaxy's picture: processes are stars inside tinted nebulae
//! (one per cgroup or application), shared descriptors are thin curved threads
//! between them, and measured bytes travel along the threads as impulses.
//!
//! A `Scene` is filled from the live graph or from a seeded synthetic one
//! (`--galaxy-demo`), laid out deterministically from process and group
//! identity, and drawn. Every loop is bounded by the caps below; the cloud is
//! texture whose size follows descriptor counts, not one dot per descriptor.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const vw = @import("view.zig");
const draw = @import("draw.zig");
const fm = @import("files_model.zig");
const panel = @import("graph_panel.zig");
const rgb = @import("../../appearance.zig").rgb;
const Palette = @import("theme.zig").Palette;
const Color = draw.Color;
const Cell = @import("../../render/vulkan.zig").Cell;

pub const max_stars = 1024;
pub const max_particles = 2048;
pub const max_junctions = 128;
pub const max_clusters = 40;
/// Threads considered each frame, and the busiest/heaviest of them drawn.
pub const max_strands = 2048;
pub const drawn_strands = 192;
pub const drawn_impulses = 320;
/// Cloud points, thread beads and impulse tails are instanced cells (32 bytes each).
pub const cloud_points = 22000;
pub const mesh_segments = 7000;
pub const bead_cells = 6000;
pub const max_labels = 14;
pub const group_motes = 1600;
/// A thread keeps its impulses this long after its last measured byte.
const linger_ns = 2_500_000_000;
const none = std.math.maxInt(u32);
const golden = 2.3999632;

const Star = struct {
    seed: u64 = 0,
    key: u64 = 0,
    cluster: u16 = 0,
    processes: u32 = 1,
    fds: u32 = 0,
    deleted: u32 = 0,
    read: f64 = 0,
    write: f64 = 0,
    last_ns: u64 = 0,
    denied: bool = false,
    stale: bool = false,
    particles: u16 = 0,
    at: [2]f32 = .{ 0, 0 },
    r: f32 = 0,
    flash: f32 = 0,
    name: [40]u8 = undefined,
    name_len: u8 = 0,
    fn label(self: *const Star) []const u8 {
        return self.name[0..self.name_len];
    }
};
const Particle = struct { star: u16, ordinal: u16 = 0, kind: u8, stale: bool = false, fds: u32, deleted: u32 = 0, read: f64 = 0, write: f64 = 0, last_ns: u64 = 0, node: u32 = none };
const Junction = struct { at: [2]f32 = .{ 0, 0 }, holders: u16 = 0, kind: u8 = 0, node: u32 = none, inode: u64 = 0, read: f64 = 0, write: f64 = 0 };
/// Ends below `max_stars` are stars; the rest are junctions (a descriptor with three or more holders).
const Strand = struct { a: u16, b: u16, kind: u8, peer: bool = false, stale: bool = false, weight: u32 = 1, ab: f64 = 0, ba: f64 = 0, last_ns: u64 = 0, seed: u32 = 0, score: f32 = 0 };
const Cluster = struct {
    key: u64 = 0,
    stars: u16 = 0,
    placed: u16 = 0,
    processes: u32 = 0,
    fds: u32 = 0,
    deleted: u32 = 0,
    rate: f64 = 0,
    weight: f32 = 0,
    at: [2]f32 = .{ 0, 0 },
    r: f32 = 0,
    name: [40]u8 = undefined,
    name_len: u8 = 0,
};
pub const Counts = struct { used: f32 = 0, stars: u32 = 0, clusters: u32 = 0, strands: u32 = 0, strands_drawn: u32 = 0, impulses: u32 = 0, cloud: u32 = 0, mesh: u32 = 0, labels: u32 = 0, moving: bool = false };

pub const Scene = struct {
    stars: [max_stars]Star = undefined,
    star_count: u32 = 0,
    particles: [max_particles]Particle = undefined,
    particle_count: u32 = 0,
    junctions: [max_junctions]Junction = undefined,
    junction_count: u32 = 0,
    strands: [max_strands]Strand = undefined,
    strand_count: u32 = 0,
    order: [max_strands]u16 = undefined,
    clusters: [max_clusters]Cluster = undefined,
    cluster_count: u32 = 0,
    synthetic: bool = false,
    /// Layout cache: recomputed only when membership, sizes or the field change.
    signature: u64 = 0,
    laid: [max_stars][3]f32 = undefined,
    laid_clusters: [max_clusters][3]f32 = undefined,

    fn reset(self: *Scene) void {
        self.star_count = 0;
        self.particle_count = 0;
        self.junction_count = 0;
        self.strand_count = 0;
        self.cluster_count = 0;
    }
    fn addStar(self: *Scene, star: Star, name: []const u8) ?*Star {
        if (self.star_count == max_stars) return null;
        const out = &self.stars[self.star_count];
        out.* = star;
        var n = @min(name.len, out.name.len);
        while (n > 0 and n < name.len and name[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(out.name[0..n], name[0..n]);
        out.name_len = @intCast(n);
        self.star_count += 1;
        return out;
    }
    fn addParticle(self: *Scene, particle: Particle) void {
        if (self.particle_count == max_particles or particle.star >= self.star_count) return;
        var p = particle;
        const star = &self.stars[p.star];
        p.ordinal = star.particles;
        star.particles +|= 1;
        star.deleted += p.deleted;
        self.particles[self.particle_count] = p;
        self.particle_count += 1;
    }
    fn addStrand(self: *Scene, strand: Strand) void {
        if (self.strand_count == max_strands or strand.a == strand.b) return;
        self.strands[self.strand_count] = strand;
        self.strand_count += 1;
    }
    fn end(self: *const Scene, index: u16) [2]f32 {
        return if (index < max_stars) self.stars[index].at else self.junctions[index - max_stars].at;
    }

    /// Groups stars into clusters by key; groups beyond the cap share the last cluster.
    fn group(self: *Scene, names: anytype) void {
        for (self.stars[0..self.star_count], 0..) |*star, i| {
            var at: u32 = 0;
            while (at < self.cluster_count and self.clusters[at].key != star.key) at += 1;
            if (at == self.cluster_count) {
                if (at == max_clusters) {
                    at -= 1;
                    const pooled = "other groups";
                    @memcpy(self.clusters[at].name[0..pooled.len], pooled);
                    self.clusters[at].name_len = pooled.len;
                } else {
                    self.clusters[at] = .{ .key = star.key };
                    const name = names.cluster(@intCast(i), &self.clusters[at].name);
                    self.clusters[at].name_len = @intCast(name.len);
                    self.cluster_count += 1;
                }
            }
            star.cluster = @intCast(at);
            const cl = &self.clusters[at];
            cl.stars += 1;
            cl.processes += star.processes;
            cl.fds += star.fds;
            cl.deleted += star.deleted;
            cl.rate += star.read + star.write;
        }
    }

    /// Positions clusters and their stars inside `body`. The result depends only
    /// on identities, size buckets and the field, so it is stable between frames.
    pub fn layout(self: *Scene, body: draw.Rect) void {
        var sig = mix(@as(u64, @as(u32, @bitCast(body.w))) << 32 | @as(u32, @bitCast(body.h))) ^ mix(@as(u64, @as(u32, @bitCast(body.x))) << 32 | @as(u32, @bitCast(body.y)));
        var total: f32 = 0;
        var widest: f32 = 0;
        for (self.clusters[0..self.cluster_count]) |*cl| {
            cl.weight = 0;
            cl.placed = 0;
        }
        for (self.stars[0..self.star_count]) |*star| {
            const sz = size(star);
            self.clusters[star.cluster].weight += sz * sz;
            sig = mix(sig ^ star.seed ^ (@as(u64, star.cluster) << 52) ^ (@as(u64, @intFromFloat(sz * 64)) << 40));
        }
        for (self.clusters[0..self.cluster_count]) |cl| {
            total += cl.weight;
            widest = @max(widest, cl.weight);
        }
        if (sig == self.signature) {
            for (self.stars[0..self.star_count], self.laid[0..self.star_count]) |*star, at| {
                star.at = .{ at[0], at[1] };
                star.r = at[2];
            }
            for (self.clusters[0..self.cluster_count], self.laid_clusters[0..self.cluster_count]) |*cl, at| {
                cl.at = .{ at[0], at[1] };
                cl.r = at[2];
            }
            return;
        }
        if (self.star_count == 0) return;
        const pack: f32 = 1.2;
        var k = @sqrt(0.5 * body.w * body.h / (std.math.pi * pack * pack * @max(1, total)));
        k = @min(k, 0.42 * @min(body.w, body.h) / (pack * @sqrt(@max(1, widest))));
        const cx = body.x + body.w / 2;
        const cy = body.y + body.h / 2;
        for (self.clusters[0..self.cluster_count]) |*cl| {
            cl.r = pack * k * @sqrt(cl.weight);
            const h = mix(cl.key);
            const angle = unit(h) * std.math.tau;
            const far = @sqrt(unit(h >> 20)) * 0.48;
            cl.at = if (self.cluster_count == 1) .{ cx, cy } else .{ cx + @cos(angle) * body.w * far, cy + @sin(angle) * body.h * far };
        }
        for (0..200) |_| {
            for (0..self.cluster_count) |i| for (i + 1..self.cluster_count) |j| {
                const a = &self.clusters[i];
                const b = &self.clusters[j];
                var dx = b.at[0] - a.at[0];
                var dy = b.at[1] - a.at[1];
                var d = @sqrt(dx * dx + dy * dy);
                const want = (a.r + b.r) * 1.02 + 14;
                if (d >= want) continue;
                if (d < 0.01) {
                    const angle = unit(mix(a.key ^ b.key)) * std.math.tau;
                    dx = @cos(angle);
                    dy = @sin(angle);
                    d = 1;
                }
                // The lighter cluster yields more.
                const share = a.weight / (a.weight + b.weight);
                const push = (want - d) / d;
                a.at[0] -= dx * push * (1 - share);
                a.at[1] -= dy * push * (1 - share);
                b.at[0] += dx * push * share;
                b.at[1] += dy * push * share;
            };
            for (self.clusters[0..self.cluster_count]) |*cl| {
                cl.at[0] += (cx - cl.at[0]) * 0.004;
                cl.at[1] += (cy - cl.at[1]) * 0.004;
                const mx = @min(cl.r, body.w / 2);
                const my = @min(cl.r, body.h / 2);
                cl.at[0] = std.math.clamp(cl.at[0], body.x + mx, body.x + body.w - mx);
                cl.at[1] = std.math.clamp(cl.at[1], body.y + my, body.y + body.h - my);
            }
        }
        // Stretch the settled clusters to the field, so the picture uses the pane it has.
        if (self.cluster_count > 1) {
            var low = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
            var high = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
            for (self.clusters[0..self.cluster_count]) |cl| for (0..2) |axis| {
                low[axis] = @min(low[axis], cl.at[axis] - cl.r);
                high[axis] = @max(high[axis], cl.at[axis] + cl.r);
            };
            const origin = [2]f32{ body.x, body.y };
            const extent = [2]f32{ body.w, body.h };
            for (0..2) |axis| {
                const span = @max(1, high[axis] - low[axis]);
                const scale = std.math.clamp(extent[axis] / span, 1, 1.7);
                const middle = (low[axis] + high[axis]) / 2;
                for (self.clusters[0..self.cluster_count]) |*cl| cl.at[axis] = origin[axis] + extent[axis] / 2 + (cl.at[axis] - middle) * scale;
            }
        }
        for (self.stars[0..self.star_count], 0..) |*star, i| {
            const cl = &self.clusters[star.cluster];
            const sz = size(star);
            star.r = @max(3, k * sz);
            if (cl.stars <= 1) star.at = cl.at else {
                const j: f32 = @floatFromInt(cl.placed);
                const f = @sqrt((j + 0.5) / @as(f32, @floatFromInt(cl.stars)));
                const angle = j * golden + unit(mix(cl.key)) * std.math.tau;
                const reach = @max(0, cl.r - star.r * 0.7) * 0.94 * f;
                star.at = .{ cl.at[0] + @cos(angle) * reach, cl.at[1] + @sin(angle) * reach };
            }
            cl.placed += 1;
            self.laid[i] = .{ star.at[0], star.at[1], star.r };
        }
        for (self.clusters[0..self.cluster_count], 0..) |cl, i| self.laid_clusters[i] = .{ cl.at[0], cl.at[1], cl.r };
        self.signature = sig;
    }

    /// Junctions sit near the centroid of their holders; strand scores pick what is drawn.
    fn settle(self: *Scene, clock: u64) void {
        var sums: [max_junctions][3]f32 = @splat(.{ 0, 0, 0 });
        for (self.strands[0..self.strand_count]) |strand| {
            if (strand.b < max_stars or strand.a >= max_stars) continue;
            const at = self.stars[strand.a].at;
            const sum = &sums[strand.b - max_stars];
            sum.* = .{ sum[0] + at[0], sum[1] + at[1], sum[2] + 1 };
        }
        for (self.junctions[0..self.junction_count], 0..) |*junction, i| {
            const n = @max(1, sums[i][2]);
            const angle = unit(mix(junction.inode ^ 0x6a)) * std.math.tau;
            junction.at = .{ sums[i][0] / n + @cos(angle) * 22, sums[i][1] / n + @sin(angle) * 22 };
            junction.holders = @intFromFloat(sums[i][2]);
        }
        for (self.strands[0..self.strand_count], 0..) |*strand, i| {
            const live = energy(clock, strand.last_ns) > 0 and strand.ab + strand.ba > 0;
            strand.score = (if (live) 100 + @as(f32, @floatCast(@log2(1 + strand.ab + strand.ba))) else 0) + @log2(1 + @as(f32, @floatFromInt(strand.weight))) - if (strand.stale) @as(f32, 4) else 0;
            self.order[i] = @intCast(i);
        }
        std.mem.sort(u16, self.order[0..self.strand_count], self, struct {
            fn before(s: *Scene, a: u16, b: u16) bool {
                return if (s.strands[a].score != s.strands[b].score) s.strands[a].score > s.strands[b].score else a < b;
            }
        }.before);
    }
};

fn mix(value: u64) u64 {
    var x = value +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}
fn unit(h: u64) f32 {
    return @as(f32, @floatFromInt(h & 0xfffff)) / 1048576.0;
}
fn hash(bytes: []const u8) u64 {
    return mix(std.hash.Wyhash.hash(0, bytes));
}
const Rng = struct {
    state: u64,
    fn next(self: *Rng) f32 {
        self.state = mix(self.state);
        return unit(self.state >> 11);
    }
};
/// Size steps only when the descriptor count doubles, so sampling noise does not move the layout.
fn size(star: *const Star) f32 {
    // Nothing visible to hold (a kernel thread, or a table we may not read): a speck.
    if (star.fds == 0) return 0.45 + if (star.processes > 1) 0.3 * @log2(@as(f32, @floatFromInt(star.processes))) else @as(f32, 0);
    const fds: f32 = @floatFromInt(std.math.log2_int(u32, star.fds +| 1));
    const members: f32 = if (star.processes > 1) 0.45 * @log2(@as(f32, @floatFromInt(star.processes))) else 0;
    return 1 + 0.28 * fds + members;
}
fn energy(clock: u64, last_ns: u64) f32 {
    if (last_ns == 0) return 0;
    const age = clock -| last_ns;
    if (age >= linger_ns) return 0;
    return @min(1, @as(f32, @floatFromInt(linger_ns - age)) / 1_000_000_000.0);
}
fn rateText(buffer: []u8, rate: f64) []const u8 {
    return if (rate >= 1048576) std.fmt.bufPrint(buffer, "{d:.1} MB/s", .{rate / 1048576}) catch "" else if (rate >= 1024) std.fmt.bufPrint(buffer, "{d:.1} kB/s", .{rate / 1024}) catch "" else std.fmt.bufPrint(buffer, "{d:.0} B/s", .{rate}) catch "";
}

// --- Scene sources --------------------------------------------------------------

const LiveNames = struct {
    v: *vw.View,
    keys: []const u64,
    by_name: []const bool,
    fn cluster(self: LiveNames, star: u32, buffer: []u8) []const u8 {
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
        _ = s.addStar(.{ .seed = seed, .processes = record.processes, .fds = record.descriptors, .read = flow.read_rate, .write = flow.write_rate, .last_ns = flow.last_ns, .denied = record.denied != 0 and record.denied == record.processes, .stale = record.stale != 0 or record.cgroup_stale != 0 }, panel.starLabel(v, @intCast(i), &buffer));
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
        s.addParticle(.{ .star = @intCast(@min(particle.star, max_stars)), .kind = @intCast(particle.kind), .stale = particle.stale > 0, .fds = particle.descriptors, .deleted = particle.deleted, .read = flow.read_rate, .write = flow.write_rate, .last_ns = flow.last_ns, .node = particle.source_node });
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
            s.addStrand(.{ .a = @intCast(a.from), .b = @intCast(b.from), .kind = @intCast(node.kind), .stale = (a.flags | b.flags) & c.XRT_FDG_STALE != 0, .weight = a.descriptors + b.descriptors, .ab = if (fa.write_rate > 0) @max(fa.write_rate, fb.read_rate) else if (fa.read_rate == 0) fb.read_rate else 0, .ba = if (fb.write_rate > 0) @max(fb.write_rate, fa.read_rate) else if (fb.read_rate == 0) fa.read_rate else 0, .last_ns = @max(fa.last_ns, fb.last_ns), .seed = @truncate(mix(node.inode ^ node.device)) });
        } else if ((r.holders > 2 or (r.holders == 2 and r.peer)) and s.junction_count < max_junctions) {
            r.junction = s.junction_count;
            const flow = if (metrics) |m| m.vertices[vertex] else zero;
            s.junctions[s.junction_count] = .{ .kind = @intCast(node.kind), .node = l.vertices[vertex].source_node, .inode = node.inode ^ node.device, .read = flow.read_rate, .write = flow.write_rate };
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
            s.addStrand(.{ .a = ends[0], .b = ends[1], .kind = c.XRT_FD_SOCKET, .peer = true, .stale = link.flags & c.XRT_FDG_STALE != 0, .weight = link.descriptors, .ab = fa.write_rate, .ba = fb.write_rate, .last_ns = flow.last_ns, .seed = @truncate(mix(kindOf(g, l, link.from).inode ^ 0x70)) });
        } else if (link.from < l.star_count and link.to >= l.star_count and link.to - l.star_count < resources) {
            const junction = res[link.to - l.star_count].junction;
            if (junction == none) continue;
            s.addStrand(.{ .a = @intCast(link.from), .b = @intCast(max_stars + junction), .kind = s.junctions[junction].kind, .stale = link.flags & c.XRT_FDG_STALE != 0, .weight = link.descriptors, .ab = flow.write_rate, .ba = flow.read_rate, .last_ns = flow.last_ns, .seed = @truncate(mix(s.junctions[junction].inode ^ link.from)) });
        }
    }
}

const demo_apps = [_][]const u8{ "web", "db", "cache", "queue", "shell", "build", "media", "sync", "mail", "audit", "proxy", "render", "index", "logs" };
const DemoNames = struct {
    s: *const Scene,
    fn cluster(self: DemoNames, star: u32, buffer: []u8) []const u8 {
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
        const star = s.addStar(.{ .seed = mix(pid), .key = group, .fds = fds }, std.fmt.bufPrint(&buffer, "{s}[{d}]", .{ demo_apps[group % demo_apps.len], pid }) catch "") orelse break;
        _ = star;
        if (hubs[group] == none) hubs[group] = @intCast(i);
        sizes[group] += 1;
        const per: u32 = @min(5, max_particles / n);
        for (0..per) |k| {
            const kind: u8 = ([_]u8{ c.XRT_FD_REGULAR, c.XRT_FD_PIPE, c.XRT_FD_SOCKET, c.XRT_FD_ANON, c.XRT_FD_DEVICE })[k];
            s.addParticle(.{ .star = @intCast(i), .kind = kind, .fds = @max(1, fds / (2 + @as(u32, @intCast(k)))), .deleted = if (hot and k == 0) 2 else 0 });
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
        if (hub != i and rng.next() < 0.75) s.addStrand(.{ .a = @intCast(hub), .b = @intCast(i), .kind = if (rng.next() < 0.5) c.XRT_FD_PIPE else c.XRT_FD_SOCKET, .weight = 1 + @as(u32, @intFromFloat(rng.next() * 3)), .ab = rate(&rng, idle, 0.3), .ba = rate(&rng, idle, 0.2), .last_ns = clock, .seed = @truncate(rng.state) });
        if (i > 0 and rng.next() < 0.22) {
            var other: u32 = @intFromFloat(rng.next() * @as(f32, @floatFromInt(i)));
            if (s.stars[other].key != group) other = hub;
            s.addStrand(.{ .a = @intCast(i), .b = @intCast(other), .kind = c.XRT_FD_PIPE, .ab = rate(&rng, idle, 0.4), .last_ns = clock, .seed = @truncate(rng.state) });
        }
    }
    for (0..groups) |group| {
        if (hubs[group] == none) continue;
        const next = hubs[(group + 1) % groups];
        if (next != none) s.addStrand(.{ .a = @intCast(hubs[group]), .b = @intCast(next), .kind = c.XRT_FD_SOCKET, .peer = true, .weight = 2, .ab = rate(&rng, idle, 0.7), .ba = rate(&rng, idle, 0.5), .last_ns = clock, .seed = @truncate(mix(group)) });
        if (group >= 2) for (0..3) |k| s.addStrand(.{ .a = @intCast(hubs[group]), .b = @intCast(hubs[0]), .kind = c.XRT_FD_SOCKET, .peer = true, .ab = rate(&rng, idle, 0.5), .last_ns = clock, .seed = @truncate(mix(group * 8 + k)) });
        // A file shared by several members meets at a junction.
        if (sizes[group] >= 4 and s.junction_count < max_junctions) {
            const junction = s.junction_count;
            s.junctions[junction] = .{ .kind = c.XRT_FD_REGULAR, .inode = mix(group ^ 0x66) };
            s.junction_count += 1;
            var holders: u32 = 0;
            for (0..s.star_count) |i| if (s.stars[i].key == group and holders < 5 and rng.next() < 0.6) {
                s.addStrand(.{ .a = @intCast(i), .b = @intCast(max_stars + junction), .kind = c.XRT_FD_REGULAR, .ab = rate(&rng, idle, 0.35), .ba = rate(&rng, idle, 0.35), .last_ns = clock, .seed = @truncate(mix(i)) });
                holders += 1;
            };
        }
    }
    for (s.strands[0..s.strand_count]) |strand| for ([2]u16{ strand.a, strand.b }, [2]f64{ strand.ba, strand.ab }, [2]f64{ strand.ab, strand.ba }) |index, in, out| if (index < max_stars) {
        s.stars[index].read += in;
        s.stars[index].write += out;
        if (in + out > 0) s.stars[index].last_ns = clock;
    };
    s.group(DemoNames{ .s = s });
}

// --- Drawing --------------------------------------------------------------------

pub const Look = struct { plain: bool, field: Color, text: Color, dim: Color, warn: Color, hot: Color, thread: Color, hues: [8]Color, hue_count: usize };
pub fn look(p: *const Palette) Look {
    if (p.win95) return .{ .plain = true, .field = p.panel, .text = p.text, .dim = p.dim, .warn = p.warn, .hot = p.crit, .thread = p.dim, .hues = @splat(p.accent), .hue_count = 1 };
    const pink = rgb(0xff4f8b);
    if (std.mem.eql(u8, p.name, "dark") or std.mem.eql(u8, p.name, "light"))
        return .{ .plain = false, .field = rgb(0x04060a), .text = rgb(0xe6ebf2), .dim = rgb(0x8291a6), .warn = rgb(0xf5c45e), .hot = pink, .thread = rgb(0xdfe6f0), .hues = .{ rgb(0x5fe3c0), rgb(0xffc94d), rgb(0xb79cff), rgb(0x6ab8ff), rgb(0xd8dde6), rgb(0xff8f6b), rgb(0xa6e36a), rgb(0x59d0e8) }, .hue_count = 8 };
    return .{ .plain = false, .field = draw.mix(p.background, .{ 0, 0, 0, 1 }, 0.5), .text = p.text, .dim = p.dim, .warn = p.warn, .hot = if (p.monochrome) p.crit else pink, .thread = p.text, .hues = .{ p.accent, p.accent2, p.accent3, p.ok, p.warn, p.text, p.accent, p.accent2 }, .hue_count = 6 };
}
fn kindColor(p: *const Palette, kind: u32) Color {
    return switch (kind) {
        c.XRT_FD_PIPE => p.accent2,
        c.XRT_FD_SOCKET => p.ok,
        c.XRT_FD_MEMFD => p.warn,
        c.XRT_FD_ANON => p.dim,
        c.XRT_FD_DEVICE => p.crit,
        else => p.accent,
    };
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

var scene: Scene = .{};
var motion: @import("galaxy_motion.zig").Motion = .{};
var cached_mesh: u32 = 0;
var cloud_builds: u64 = 0;
var thread_hover: ?struct { seed: u32, a: u16, b: u16 } = null;

/// Draws the galaxy into `field`; `reserved` are text rows labels must avoid.
pub fn render(v: *vw.View, ctx: draw.Ctx, field: draw.Rect, body: draw.Rect, reserved: []const draw.Rect, now: u64) !Counts {
    const s = &scene;
    const lk = look(ctx.p);
    const st = &v.graph;
    if (!v.paused or st.clock == 0) st.clock = now;
    const clock = st.clock;
    if (st.demo != 0) demo(s, st.demo, st.demo_idle, clock) else fromLive(s, v);
    s.layout(body);
    const easing = motion.layout(s, clock, st.look);
    var selected: ?u64 = null;
    if (!s.synthetic) if (st.focus) |id| {
        if (st.projection) |p| if (st.graph) |g| {
            for (p.stars[0..s.star_count], 0..) |star, i| if (star.source_node < g.node_count and g.nodes[star.source_node].pid == id.pid) {
                selected = s.clusters[s.stars[i].cluster].key;
                break;
            };
        };
    };
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
            const flags = [2]u8{ @intFromBool(star.stale), @intFromBool(star.denied) };
            cloud_hash.update(&flags);
        }
        for (s.clusters[0..s.cluster_count]) |cl| {
            cloud_hash.update(std.mem.asBytes(&cl.at));
            cloud_hash.update(std.mem.asBytes(&cl.r));
        }
        const signature = cloud_hash.final() | 1;
        if (ctx.r.cloud_signature != signature) {
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
                const dimmed: f32 = @as(f32, if (star.stale or star.denied) 0.55 else 1) * st.look.brightness * @as(f32, if (motion.focus != null and motion.focus.? != s.clusters[star.cluster].key) 0.4 else 1);
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
                if (star.processes > 1) for (0..@min(star.processes, 400)) |member| {
                    if (motes == group_motes) break;
                    motes += 1;
                    const f = @sqrt((@as(f32, @floatFromInt(member)) + 0.5) / @as(f32, @floatFromInt(star.processes)));
                    const angle = @as(f32, @floatFromInt(member)) * golden + unit(star.seed) * std.math.tau;
                    dust.put(star.at[0] + @cos(angle) * star.r * 1.5 * f, star.at[1] + @sin(angle) * star.r * 1.5 * f, 2, draw.fade(pale, 0.8 * dimmed));
                };
            }
            counts.cloud = @intCast(dust.count);
            try ctx.r.retainCloud(first_vertex, dust.items[0..dust.count], signature);
            cached_mesh = counts.mesh;
            cloud_builds += 1;
        }
        counts.mesh = cached_mesh;
        counts.cloud = ctx.r.cloud_cells;
        try ctx.r.cloud(motion.transform(), st.look.additive);
    }

    motion.project(s);
    if (audit and s.cluster_count > 0) std.debug.print("xodb: galaxy-cluster x={d:.1} y={d:.1}\n", .{ s.clusters[0].at[0], s.clusters[0].at[1] });
    // The pointer's star lifts its own threads out of the web.
    var hovered: u32 = none;
    for (s.stars[0..s.star_count], 0..) |star, i| {
        if (@abs(v.pointer[0] - star.at[0]) < 12 and @abs(v.pointer[1] - star.at[1]) < 12) hovered = @intCast(i);
    }
    var hot_thread: u32 = none;
    var nearest: f32 = 6;
    if (pointer_changed) thread_hover = null;
    for (s.order[0..@min(s.strand_count, drawn_strands)]) |index| {
        const strand = s.strands[index];
        if (!pointer_changed) {
            if (thread_hover) |hot| if (hot.seed == strand.seed and hot.a == strand.a and hot.b == strand.b) {
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
        thread_hover = .{ .seed = hot.seed, .a = hot.a, .b = hot.b };
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
        const live = energy(clock, strand.last_ns) * @as(f32, if (strand.ab + strand.ba > 0) 1 else 0);
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
        const color = kindColor(ctx.p, junction.kind);
        try ctx.r.shape(.{ .x = junction.at[0] - 4, .y = junction.at[1] - 4, .w = 8, .h = 8 }, draw.fade(color, 0.85), .{ .radii = @splat(4), .border = 1 });
        const hit = draw.Rect{ .x = junction.at[0] - 7, .y = junction.at[1] - 7, .w = 14, .h = 14 };
        if (junction.node != none) v.hit(hit, .{ .graph_resource = junction.node });
        v.hover(hit, "{s} · {d} holders shown · read {d:.0} B/s / write {d:.0} B/s · sampled", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(junction.kind))), junction.holders, junction.read, junction.write });
    }

    // Impulses: bright heads with fading tails, in the direction the bytes went.
    var until: u64 = 0;
    const Head = struct { at: [2]f32, color: Color, live: f32 };
    var heads: [drawn_impulses]Head = undefined;
    for (s.order[0..counts.strands_drawn]) |index| {
        const strand = s.strands[index];
        const live = energy(clock, strand.last_ns);
        if (live <= 0) continue;
        const a = s.end(strand.a);
        const b = s.end(strand.b);
        const m = control(a, b, strand.seed, strand.b >= max_stars);
        const color = kindColor(ctx.p, strand.kind);
        for ([2]f64{ strand.ab, strand.ba }, 0..) |rate, back| {
            if (rate <= 0) continue;
            until = @max(until, strand.last_ns +| linger_ns);
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
    if (motion.active and !v.paused) {
        counts.moving = true;
        st.impulse_until = @max(st.impulse_until, now + 100_000_000);
    }

    // Descriptors: the hoverable points around each star.
    for (s.particles[0..s.particle_count]) |particle| {
        const star = s.stars[particle.star];
        const lone = s.star_count == 1;
        // In a crowd only what stands out keeps a dot; the cloud carries the rest.
        if (!lone and star.r < 7 and particle.deleted == 0 and particle.read + particle.write == 0) continue;
        if (ctx.r.used() > 0.88) break;
        const f = @sqrt((@as(f32, @floatFromInt(particle.ordinal)) + 0.5) / @as(f32, @floatFromInt(@max(1, star.particles))));
        const angle = @as(f32, @floatFromInt(particle.ordinal)) * golden + unit(star.seed >> 8) * std.math.tau;
        const orbit = if (lone) star.r * 1.3 * f else @max(13, star.r * (0.5 + 0.55 * f));
        const at = [2]f32{ star.at[0] + @cos(angle) * orbit, star.at[1] + @sin(angle) * orbit };
        const flow = particle.read + particle.write;
        const radius: f32 = @min(if (lk.plain) @as(f32, 9) else 4.5, (if (lk.plain) @as(f32, 3) else 1.2) + 0.3 * @log2(@as(f32, @floatFromInt(@max(1, particle.fds)))) + @as(f32, @floatCast(@min(2.0, @log(1.0 + flow / 1024.0) * 0.4))));
        const color = if (particle.deleted > 0 and !lk.plain) lk.hot else kindColor(ctx.p, particle.kind);
        const pulse = if (flow > 0) energy(clock, particle.last_ns) else 0;
        if (!lk.plain and pulse > 0) try glow(ctx, at, radius + 7, draw.fade(color, 0.45 * pulse));
        if (particle.deleted > 0) try disc(ctx, at, radius + 3, draw.fade(lk.hot, 0.3));
        try disc(ctx, at, radius, draw.fade(color, if (particle.stale) 0.5 else 0.95));
        const reach = @max(radius + 2, 6);
        const hit = draw.Rect{ .x = at[0] - reach, .y = at[1] - reach, .w = reach * 2, .h = reach * 2 };
        if (particle.node != none) v.hit(hit, .{ .graph_resource = particle.node });
        v.hover(hit, "{s} · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} deleted · sampled inode joins", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(particle.kind))), particle.fds, particle.read, particle.write, particle.deleted });
    }

    // Stars: a small bright core; a landing impulse flashes it.
    for (s.stars[0..s.star_count], 0..) |star, i| {
        const hue = lk.hues[s.clusters[star.cluster].key % lk.hue_count];
        const flagged = star.deleted > 0;
        const color = if (lk.plain) (if (star.denied) ctx.p.warn else if (star.stale) ctx.p.dim else ctx.p.text) else if (flagged) lk.hot else if (star.denied or star.stale) draw.mix(hue, lk.dim, 0.7) else draw.mix(hue, .{ 1, 1, 1, 1 }, 0.55);
        const busy: f32 = @floatCast(@min(3.0, @log(1.0 + (star.read + star.write) / 1024.0) * 0.5));
        const core: f32 = std.math.clamp(star.r * 0.11, 1.5, 3) + (if (star.processes > 1) @as(f32, 1) else 0) + busy * 0.4 + (if (flagged) @as(f32, 0.8) else 0);
        const pulse = if (star.read + star.write > 0) energy(clock, star.last_ns) else 0;
        if (lk.plain) {
            try disc(ctx, star.at, core + 5, draw.fade(color, 0.12 + pulse * 0.2));
            try disc(ctx, star.at, core + 2, color);
        } else {
            if (s.star_count <= 400 or pulse > 0 or flagged) try glow(ctx, star.at, core * 3 + 6 + 4 * pulse, draw.fade(color, 0.3 + 0.2 * pulse));
            if (star.flash > 0) try glow(ctx, star.at, core * 3 + 16, draw.fade(.{ 1, 1, 1, 1 }, 0.6 * star.flash));
            try ctx.r.shape(.{ .x = @round(star.at[0] - core), .y = @round(star.at[1] - core), .w = @round(core * 2), .h = @round(core * 2) }, color, .{ .radii = @splat(1) });
        }
        const hit = draw.Rect{ .x = star.at[0] - 14, .y = star.at[1] - 14, .w = 28, .h = 28 };
        if (!s.synthetic) v.hit(hit, .{ .graph_star = @intCast(i) });
        if (audit and !s.synthetic) panel.auditStar(v, @intCast(i), star.at);
        if (star.denied and star.fds == 0)
            v.hover(hit, "{s} · fd table denied; needs /proc access · click for process", .{star.label()})
        else
            v.hover(hit, "{s} · {d} processes · {d} fds · read {d:.0} B/s / write {d:.0} B/s · {d} deleted · sampled inode joins", .{ star.label(), star.processes, star.fds, star.read, star.write, star.deleted });
    }

    // Labels: clusters first, then the pointer's star and the busiest few.
    var placed = Placed{ .field = field };
    for (reserved) |row| placed.add(row);
    if (hot_thread != none) {
        const strand = s.strands[hot_thread];
        const hit = draw.Rect{ .x = v.pointer[0] - 4, .y = v.pointer[1] - 4, .w = 8, .h = 8 };
        var forward: [24]u8 = undefined;
        var reverse: [24]u8 = undefined;
        // Short enough to fit the tooltip with both directions visible.
        v.hover(hit, "{s} thread · {d} shared · forward {s} / reverse {s}{s}", .{ std.mem.span(c.xrt_fd_kind_name(@intCast(strand.kind))), strand.weight, rateText(&forward, strand.ab), rateText(&reverse, strand.ba), if (strand.stale) " · stale" else " · sampled" });
        for ([2]u16{ strand.a, strand.b }) |end| {
            const at = s.end(end);
            const name = if (end < max_stars) s.stars[end].label() else "shared descriptor";
            const width = @min(ctx.measure(name) + 12, 230);
            const tag = draw.Rect{ .x = at[0] + 14, .y = at[1] + 16, .w = width, .h = 25 };
            if (placed.free(tag)) {
                placed.add(tag);
                try ctx.r.rect(tag, draw.fade(lk.field, 0.95));
                try ctx.r.shape(tag, kindColor(ctx.p, strand.kind), .{ .border = 1 });
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
        const caption = if (cl.rate > 0) std.fmt.bufPrint(&caption_buffer, "{d} processes · {d} fds · {s}", .{ cl.processes, cl.fds, rateText(&rate_buffer, cl.rate) }) catch "" else std.fmt.bufPrint(&caption_buffer, "{d} processes · {d} fds", .{ cl.processes, cl.fds }) catch "";
        if (try label(ctx, &placed, lk, .{ cl.at[0] + cl.r * 0.55, cl.at[1] - cl.r * 0.75 }, 4, cl.name[0..cl.name_len], caption, if (lk.plain) lk.text else hue, lk.dim)) counts.labels += 1;
    }
    var shown: [max_labels]u32 = undefined;
    var shown_count: usize = 0;
    while (counts.labels < budget and shown_count < shown.len) {
        var best: u32 = none;
        var best_score: f32 = -1;
        for (s.stars[0..s.star_count], 0..) |star, i| {
            if (std.mem.indexOfScalar(u32, shown[0..shown_count], @intCast(i)) != null) continue;
            var score: f32 = @floatCast(@log2(1 + star.read + star.write) * 8 + @log2(1.0 + @as(f64, @floatFromInt(star.fds))));
            if (star.fds == 0 and star.read + star.write == 0) score = -2;
            if (i == hovered) score += 1e6;
            if (star.deleted > 0) score += 60;
            if (star.processes > 1) score += 40;
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
        const rate = star.read + star.write;
        const caption = if (star.denied and star.fds == 0)
            "fd table denied"
        else if (star.deleted > 0)
            std.fmt.bufPrint(&caption_buffer, "{d} fds · {d} deleted, still open", .{ star.fds, star.deleted }) catch ""
        else if (star.processes > 1)
            std.fmt.bufPrint(&caption_buffer, "{d} processes · {d} fds", .{ star.processes, star.fds }) catch ""
        else if (rate > 0)
            std.fmt.bufPrint(&caption_buffer, "{d} fds · {s}", .{ star.fds, rateText(&rate_buffer, rate) }) catch ""
        else
            std.fmt.bufPrint(&caption_buffer, "{d} fds", .{star.fds}) catch "";
        const name = std.fmt.bufPrint(&name_buffer, "{s}", .{star.label()}) catch "";
        const flagged = star.deleted > 0 and !lk.plain;
        if (try label(ctx, &placed, lk, star.at, @min(star.r * 0.5 + 6, 26), name, caption, if (flagged) lk.hot else if (star.denied or star.stale) lk.dim else lk.text, if (flagged) draw.fade(lk.hot, 0.8) else lk.dim)) counts.labels += 1;
    }
    counts.used = ctx.r.used();
    if (audit) std.debug.print("xodb: galaxy-look builds={d} zoom={d:.4} camera={d} thread={d} additive={d} cloud_size={d:.2} max_stars={d} unfolded={d}\n", .{ cloud_builds, motion.zoom, @intFromBool(motion.active), hot_thread, @intFromBool(st.look.additive), st.look.cloud_size, st.max_stars, @intFromBool(!st.collapse) });
    return counts;
}

test "changed layout eases established identities without altering target layout" {
    const s = try std.testing.allocator.create(Scene);
    defer std.testing.allocator.destroy(s);
    s.* = .{};
    var moving = @import("galaxy_motion.zig").Motion{};
    demo(s, 24, true, 1);
    s.layout(.{ .x = 0, .y = 0, .w = 800, .h = 600 });
    _ = moving.layout(s, 1, .{});
    const first = s.stars[0].at;
    s.layout(.{ .x = 200, .y = 0, .w = 800, .h = 600 });
    const target = s.stars[0].at;
    _ = moving.layout(s, 30_000_001, .{});
    try std.testing.expect(moving.active and s.stars[0].at[0] > first[0] and s.stars[0].at[0] < target[0]);
    try std.testing.expectEqual(target[0], s.laid[0][0]);
}

test "galaxy layout is deterministic, bounded and stays in the field" {
    const body = draw.Rect{ .x = 40, .y = 130, .w = 1000, .h = 520 };
    var first: [max_stars][3]f32 = undefined;
    for ([_]u32{ 1, 2, 24, 600, 5000 }) |count| {
        demo(&scene, count, false, 1_000_000_000);
        scene.signature = 0;
        scene.layout(body);
        scene.settle(1_000_000_000);
        const n = scene.star_count;
        try std.testing.expectEqual(@min(count, max_stars), n);
        try std.testing.expect(scene.strand_count <= max_strands and scene.cluster_count <= max_clusters and scene.particle_count <= max_particles);
        for (scene.stars[0..n], 0..) |star, i| {
            try std.testing.expect(star.at[0] >= body.x - 1 and star.at[0] <= body.x + body.w + 1 and star.at[1] >= body.y - 1 and star.at[1] <= body.y + body.h + 1);
            first[i] = .{ star.at[0], star.at[1], star.r };
        }
        if (count > 1) try std.testing.expect(scene.strand_count > 0);
        // Rebuilding from the same identities lands every star where it was, with and without the cache.
        for ([_]bool{ true, false }) |cached| {
            demo(&scene, count, true, 9_000_000_000);
            if (!cached) scene.signature = 0;
            scene.layout(body);
            for (scene.stars[0..n], 0..) |star, i| try std.testing.expectEqual(first[i], [3]f32{ star.at[0], star.at[1], star.r });
        }
        scene.settle(9_000_000_000);
        for (scene.strands[0..scene.strand_count]) |strand| try std.testing.expectEqual(@as(f64, 0), strand.ab + strand.ba);
    }
}
