//! Fixed-capacity graph data and deterministic layout, independent of its source.
//! Sources supply stable identities, grouped nodes, weighted edges and activity.
const std = @import("std");
const draw = @import("draw.zig");
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
pub const linger_ns = 2_500_000_000;
pub const none = std.math.maxInt(u32);
pub const golden = 2.3999632;

pub const Node = struct {
    seed: u64 = 0,
    key: u64 = 0,
    cluster: u16 = 0,
    members: u32 = 1,
    units: u32 = 0,
    alerts: u32 = 0,
    incoming: f64 = 0,
    outgoing: f64 = 0,
    last_ns: u64 = 0,
    unavailable: bool = false,
    stale: bool = false,
    particles: u16 = 0,
    at: [2]f32 = .{ 0, 0 },
    r: f32 = 0,
    flash: f32 = 0,
    name: [40]u8 = undefined,
    name_len: u8 = 0,
    pub fn label(self: *const Node) []const u8 {
        return self.name[0..self.name_len];
    }
};
pub const Detail = struct { star: u16, ordinal: u16 = 0, kind: u8, stale: bool = false, units: u32, alerts: u32 = 0, incoming: f64 = 0, outgoing: f64 = 0, last_ns: u64 = 0, node: u32 = none };
pub const Junction = struct { at: [2]f32 = .{ 0, 0 }, holders: u16 = 0, kind: u8 = 0, node: u32 = none, identity: u64 = 0, incoming: f64 = 0, outgoing: f64 = 0 };
/// Ends below `max_stars` are stars; the rest are junctions (a hyperedge with three or more ends).
pub const Pulse = struct { ab: f64 = 0, ba: f64 = 0, last_ns: u64 = 0 };
pub const Edge = struct { a: u16, b: u16, kind: u8, peer: bool = false, stale: bool = false, weight: u32 = 1, pulse: Pulse = .{}, directed: bool = false, seed: u32 = 0, score: f32 = 0 };
pub const Cluster = struct {
    parent: ?u64 = null,
    key: u64 = 0,
    stars: u16 = 0,
    placed: u16 = 0,
    members: u32 = 0,
    units: u32 = 0,
    alerts: u32 = 0,
    rate: f64 = 0,
    weight: f32 = 0,
    at: [2]f32 = .{ 0, 0 },
    r: f32 = 0,
    name: [40]u8 = undefined,
    name_len: u8 = 0,
};
pub const Counts = struct { used: f32 = 0, stars: u32 = 0, clusters: u32 = 0, strands: u32 = 0, strands_drawn: u32 = 0, impulses: u32 = 0, cloud: u32 = 0, mesh: u32 = 0, labels: u32 = 0, moving: bool = false };

pub const Scene = struct {
    stars: [max_stars]Node = undefined,
    star_count: u32 = 0,
    particles: [max_particles]Detail = undefined,
    particle_count: u32 = 0,
    junctions: [max_junctions]Junction = undefined,
    junction_count: u32 = 0,
    strands: [max_strands]Edge = undefined,
    strand_count: u32 = 0,
    order: [max_strands]u16 = undefined,
    clusters: [max_clusters]Cluster = undefined,
    cluster_count: u32 = 0,
    synthetic: bool = false,
    /// Layout cache: recomputed only when membership, sizes or the field change.
    signature: u64 = 0,
    laid: [max_stars][3]f32 = undefined,
    laid_clusters: [max_clusters][3]f32 = undefined,

    pub fn reset(self: *Scene) void {
        self.star_count = 0;
        self.particle_count = 0;
        self.junction_count = 0;
        self.strand_count = 0;
        self.cluster_count = 0;
    }
    pub fn addStar(self: *Scene, star: Node, name: []const u8) ?*Node {
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
    pub fn addParticle(self: *Scene, particle: Detail) void {
        if (self.particle_count == max_particles or particle.star >= self.star_count) return;
        var p = particle;
        const star = &self.stars[p.star];
        p.ordinal = star.particles;
        star.particles +|= 1;
        star.alerts += p.alerts;
        self.particles[self.particle_count] = p;
        self.particle_count += 1;
    }
    pub fn addStrand(self: *Scene, strand: Edge) void {
        if (self.strand_count == max_strands or strand.a == strand.b) return;
        self.strands[self.strand_count] = strand;
        self.strand_count += 1;
    }
    pub fn end(self: *const Scene, index: u16) [2]f32 {
        return if (index < max_stars) self.stars[index].at else self.junctions[index - max_stars].at;
    }

    /// Groups stars into clusters by key; groups beyond the cap share the last cluster.
    pub fn group(self: *Scene, names: anytype) void {
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
            cl.members += star.members;
            cl.units += star.units;
            cl.alerts += star.alerts;
            cl.rate += star.incoming + star.outgoing;
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
    pub fn settle(self: *Scene, clock: u64) void {
        var sums: [max_junctions][3]f32 = @splat(.{ 0, 0, 0 });
        for (self.strands[0..self.strand_count]) |strand| {
            if (strand.b < max_stars or strand.a >= max_stars) continue;
            const at = self.stars[strand.a].at;
            const sum = &sums[strand.b - max_stars];
            sum.* = .{ sum[0] + at[0], sum[1] + at[1], sum[2] + 1 };
        }
        for (self.junctions[0..self.junction_count], 0..) |*junction, i| {
            const n = @max(1, sums[i][2]);
            const angle = unit(mix(junction.identity ^ 0x6a)) * std.math.tau;
            junction.at = .{ sums[i][0] / n + @cos(angle) * 22, sums[i][1] / n + @sin(angle) * 22 };
            junction.holders = @intFromFloat(sums[i][2]);
        }
        for (self.strands[0..self.strand_count], 0..) |*strand, i| {
            const live = energy(clock, strand.pulse.last_ns) > 0 and strand.pulse.ab + strand.pulse.ba > 0;
            strand.score = (if (live) 100 + @as(f32, @floatCast(@log2(1 + strand.pulse.ab + strand.pulse.ba))) else 0) + @log2(1 + @as(f32, @floatFromInt(strand.weight))) - if (strand.stale) @as(f32, 4) else 0;
            self.order[i] = @intCast(i);
        }
        std.mem.sort(u16, self.order[0..self.strand_count], self, struct {
            pub fn before(s: *Scene, a: u16, b: u16) bool {
                return if (s.strands[a].score != s.strands[b].score) s.strands[a].score > s.strands[b].score else a < b;
            }
        }.before);
    }
};

pub fn mix(value: u64) u64 {
    var x = value +% 0x9e3779b97f4a7c15;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}
pub fn unit(h: u64) f32 {
    return @as(f32, @floatFromInt(h & 0xfffff)) / 1048576.0;
}
pub fn hash(bytes: []const u8) u64 {
    return mix(std.hash.Wyhash.hash(0, bytes));
}
pub const Rng = struct {
    state: u64,
    pub fn next(self: *Rng) f32 {
        self.state = mix(self.state);
        return unit(self.state >> 11);
    }
};
/// Size steps only when the source weight doubles, so sampling noise does not move the layout.
pub fn size(star: *const Node) f32 {
    // A zero-weight node remains visible as a speck.
    if (star.units == 0) return 0.45 + if (star.members > 1) 0.3 * @log2(@as(f32, @floatFromInt(star.members))) else @as(f32, 0);
    const units: f32 = @floatFromInt(std.math.log2_int(u32, star.units +| 1));
    const members: f32 = if (star.members > 1) 0.45 * @log2(@as(f32, @floatFromInt(star.members))) else 0;
    return 1 + 0.28 * units + members;
}
pub fn energy(clock: u64, last_ns: u64) f32 {
    if (last_ns == 0) return 0;
    const age = clock -| last_ns;
    if (age >= linger_ns) return 0;
    return @min(1, @as(f32, @floatFromInt(linger_ns - age)) / 1_000_000_000.0);
}
pub fn rateText(buffer: []u8, rate: f64) []const u8 {
    return if (rate >= 1048576) std.fmt.bufPrint(buffer, "{d:.1} MB/s", .{rate / 1048576}) catch "" else if (rate >= 1024) std.fmt.bufPrint(buffer, "{d:.1} kB/s", .{rate / 1024}) catch "" else std.fmt.bufPrint(buffer, "{d:.0} B/s", .{rate}) catch "";
}
