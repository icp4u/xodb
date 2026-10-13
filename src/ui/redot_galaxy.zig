//! Scene snapshot adapter. No target reads, protocol requests or invented flow
//! occur during drawing; node picks are routed back to the existing inspector.
const std = @import("std");
const protocol = @import("../redot/protocol.zig");
const model = @import("overview/galaxy_model.zig");
const galaxy = @import("overview/galaxy.zig");
const draw = @import("overview/draw.zig");
const palette = @import("overview/theme.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const c = @import("../c_ui.zig").api;

const Presentation = struct {
    look: @import("../preferences.zig").Galaxy = .{},
    clock: u64 = 0,
    impulse_until: u64 = 0,
    motion_until: u64 = 0,
    layout_only: bool = false,
    max_stars: u32 = model.max_stars,
    collapse: bool = false,
};
pub const View = struct {
    state: galaxy.State = .{ .cloud_slot = 1 },
    presentation: Presentation = .{},
    pointer: [2]f32 = .{ -1, -1 },
    /// The inspector's node, ringed so the tree and the galaxy agree.
    selected_node: ?u64 = null,
    revision: ?u64 = null,
    hover: [384]u8 = undefined,
    hover_len: usize = 0,
    omitted: usize = 0,
    moving: bool = false,

    pub fn render(self: *View, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, snapshot: protocol.Snapshot) !void {
        if (self.revision != snapshot.scene_revision) {
            self.state.scene.signature = 0;
            self.revision = snapshot.scene_revision;
        }
        // renderModel projects the scene in place. Refill scalar data/identities
        // each frame; deterministic layout restores its world-space positions.
        fill(&self.state.scene, snapshot.nodes);
        self.omitted = snapshot.nodes.len - self.state.scene.star_count;
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        self.presentation.clock = @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
        self.hover_len = 0;
        var host = Host{ .view = self, .graph = &self.presentation, .pointer = self.pointer };
        const ctx = draw.Ctx{ .r = r, .font = font, .p = &palette.all[0] };
        const field = draw.Rect{ .x = bounds.x + 8, .y = bounds.y + 102, .w = @max(1, bounds.w - 16), .h = @max(1, bounds.h - 204) };
        const body = draw.Rect{ .x = field.x + 32, .y = field.y + 16, .w = @max(1, field.w - 64), .h = @max(1, field.h - 32) };
        const old_clip = r.clip;
        r.clip = draw.intersect(old_clip, field);
        defer r.clip = old_clip;
        const counts = try galaxy.renderModel(&host, &self.state, ctx, field, body, &.{}, null, self.presentation.clock);
        self.moving = counts.moving;
        var chosen: ?model.Node = null;
        if (self.selected_node) |id| for (self.state.scene.stars[0..self.state.scene.star_count]) |star| if (star.seed == id) {
            chosen = star;
            const selection = self.state.motion.navigation.selection;
            if (selection == null or selection.? != .node or selection.?.node != id)
                try r.shape(.{ .x = star.at[0] - 9, .y = star.at[1] - 9, .w = 18, .h = 18 }, palette.all[0].ok, .{ .radii = @splat(9), .border = 2 });
            break;
        };
        r.clip = old_clip;
        var buffer: [256]u8 = undefined;
        const navigation = &self.state.motion.navigation;
        try r.textFit(font, bounds.x + 14, bounds.y + 72, bounds.w - 28, try std.fmt.bufPrint(&buffer, "SCENE GALAXY{s} / {d} nodes / {d} clusters / {d} parent-child threads / {d} omitted", .{ if (navigation.tour) " / TOUR" else "", counts.stars, counts.clusters, counts.strands, self.omitted }), palette.all[0].ok);
        try r.textFit(font, bounds.x + 14, bounds.y + bounds.h - 92, bounds.w - 28, if (navigation.help) @import("overview/galaxy_camera.zig").hints else "Click selects / Enter frames. G tree / P inspector / R refresh / ? navigation. S pans, not signals.", palette.all[0].text);
        try r.textFit(font, bounds.x + 14, bounds.y + bounds.h - 68, bounds.w - 28, "Signal connections / emissions: unavailable from this engine protocol; no signal activity is inferred.", palette.all[0].warn);
        if (self.hover_len == 0) if (chosen) |star| {
            const text = std.fmt.bufPrint(&self.hover, "Ringed: {s} / object #{d} / selected in the inspector", .{ star.label(), star.seed }) catch "";
            self.hover_len = text.len;
        };
        if (self.hover_len > 0) try r.textFit(font, bounds.x + 14, bounds.y + bounds.h - 44, bounds.w - 28, self.hover[0..self.hover_len], palette.all[0].text);
        if (c.getenv("XODB_OVERVIEW_AUDIT") != null) std.debug.print("xodb: redot-galaxy nodes={d} clusters={d} edges={d} impulses={d} omitted={d} moving={d} revision={d} selected={d}\n", .{ counts.stars, counts.clusters, counts.strands, counts.impulses, self.omitted, @intFromBool(counts.moving), snapshot.scene_revision, if (chosen) |star| star.seed else 0 });
    }
};

/// Prefix order preserves all represented ancestors. Each edge is a real
/// parent-child relation; scene/script identities determine the cloud groups.
pub fn fill(scene: *model.Scene, nodes: []const protocol.Node) void {
    scene.reset();
    scene.synthetic = false;
    const n = @min(nodes.len, model.max_stars);
    var names: [model.max_stars][]const u8 = undefined;
    var parents: [model.max_stars]struct { depth: u16, index: u16, scene: []const u8 } = undefined;
    var depth: usize = 0;
    for (nodes[0..n], 0..) |node, i| {
        while (depth > 0 and parents[depth - 1].depth >= node.depth) depth -= 1;
        const inherited = if (depth > 0) parents[depth - 1].scene else "Scene tree";
        const scene_path = if (node.scene_path.len > 0) node.scene_path else inherited;
        const group = node.script_path orelse scene_path;
        names[i] = group;
        _ = scene.addStar(.{ .seed = node.object_id, .key = model.hash(group), .units = 1 + node.child_count }, node.name);
        if (depth > 0 and @as(u32, parents[depth - 1].depth) + 1 == node.depth) {
            const parent = parents[depth - 1].index;
            scene.addStrand(.{ .a = parent, .b = @intCast(i), .kind = 0, .directed = true, .seed = @truncate(model.mix(nodes[parent].object_id ^ node.object_id)) });
        }
        parents[depth] = .{ .depth = node.depth, .index = @intCast(i), .scene = scene_path };
        depth += 1;
    }
    scene.group(Names{ .items = names[0..n] });
}
const Names = struct {
    items: []const []const u8,
    pub fn cluster(self: Names, index: u32, buffer: []u8) []const u8 {
        const path = self.items[index];
        const label = std.fs.path.basename(path);
        var n = @min(label.len, buffer.len);
        while (n > 0 and n < label.len and label[n] & 0xc0 == 0x80) n -= 1;
        @memcpy(buffer[0..n], label[0..n]);
        return buffer[0..n];
    }
};
const Host = struct {
    view: *View,
    graph: *Presentation,
    pointer: [2]f32,
    paused: bool = false,
    pub fn kindColor(_: *Host, p: *const palette.Palette, _: u32) draw.Color {
        return p.accent;
    }
    pub fn junctionName(_: *Host) []const u8 {
        return "scene junction";
    }
    pub fn clusterHit(_: *Host, _: draw.Rect, _: u64) void {}
    pub fn nodeHit(self: *Host, _: draw.Rect, node: model.Node, _: u32, _: bool, audit: bool) void {
        if (@abs(self.pointer[0] - node.at[0]) < 12 and @abs(self.pointer[1] - node.at[1]) < 12) {
            const text = std.fmt.bufPrint(&self.view.hover, "{s} / object #{d} / click selects; P inspects", .{ node.label(), node.seed }) catch "";
            self.view.hover_len = text.len;
        }
        if (audit) std.debug.print("xodb: redot-galaxy-node id={d} x={d:.1} y={d:.1}\n", .{ node.seed, node.at[0], node.at[1] });
    }
    pub fn junctionHit(_: *Host, _: draw.Rect, _: model.Junction) void {}
    pub fn detailHit(_: *Host, _: draw.Rect, _: model.Detail) void {}
    pub fn threadHit(self: *Host, _: draw.Rect, _: model.Edge) void {
        const text = "Parent → child / scene snapshot; not a measured signal emission";
        @memcpy(self.view.hover[0..text.len], text);
        self.view.hover_len = text.len;
    }
    pub fn clusterCaption(_: *Host, cl: model.Cluster, buffer: *[96]u8, _: *[32]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{d} scene nodes", .{cl.members}) catch "";
    }
    pub fn nodeCaption(_: *Host, node: model.Node, buffer: *[96]u8, _: *[32]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "object #{d}", .{node.seed}) catch "";
    }
};

test "scene adapter preserves object identity, parents and static provenance" {
    const a = std.testing.allocator;
    const scene = try a.create(model.Scene);
    defer a.destroy(scene);
    scene.* = .{};
    const root = protocol.Node{ .depth = 0, .child_count = 1, .name = "World", .type_name = "Node", .object_id = 10, .scene_path = "res://world.tscn", .script_path = null, .view_flags = 0 };
    var child = root;
    child.depth = 1;
    child.child_count = 0;
    child.name = "Player";
    child.object_id = 20;
    child.scene_path = "";
    child.script_path = "res://player.gd";
    fill(scene, &.{ root, child });
    try std.testing.expectEqual(@as(u32, 2), scene.star_count);
    try std.testing.expectEqual(@as(u32, 2), scene.cluster_count);
    try std.testing.expectEqual(@as(u32, 1), scene.strand_count);
    try std.testing.expectEqual(@as(u64, 20), scene.stars[1].seed);
    try std.testing.expect(scene.strands[0].directed and scene.strands[0].a == 0 and scene.strands[0].b == 1);
    try std.testing.expectEqual(@as(u64, 0), scene.strands[0].pulse.last_ns);
    try std.testing.expectEqual(@as(f64, 0), scene.strands[0].pulse.ab + scene.strands[0].pulse.ba);
    fill(scene, &.{root});
    try std.testing.expectEqual(@as(u32, 1), scene.star_count);
    try std.testing.expectEqual(@as(u32, 0), scene.strand_count);
}

test "shared galaxy picking matches the lifted star in a dense scene" {
    const scene = try std.testing.allocator.create(model.Scene);
    defer std.testing.allocator.destroy(scene);
    scene.* = .{};
    scene.clusters[0] = .{ .key = 5, .at = .{ 100, 100 }, .r = 12 };
    scene.cluster_count = 1;
    const camera = @import("overview/galaxy_camera.zig").Camera;
    try std.testing.expectEqual(@as(u64, 5), camera.pick(scene, .{ 100, 100 }).?.cluster);
    // Stars centred at x=100 and x=113: a click at 100 is in both 28 px boxes
    // but only the first star is within the 12 px the renderer highlights.
    scene.stars[0] = .{ .seed = 1, .at = .{ 100, 100 } };
    scene.stars[1] = .{ .seed = 2, .at = .{ 113, 100 } };
    scene.star_count = 2;
    try std.testing.expectEqual(@as(u64, 1), camera.pick(scene, .{ 100, 100 }).?.node);
    try std.testing.expectEqual(@as(u64, 2), camera.pick(scene, .{ 110, 100 }).?.node);
}
