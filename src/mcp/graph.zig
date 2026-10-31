//! The same bounded graph adapters feed GUI peers and this observer projection.
//! This tool asks for inventory, never for syscall tracing or profiler capture.
const std = @import("std");
const model = @import("../ui/overview/galaxy_model.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const wire = @import("profile.zig");

pub fn kind(args: Value) ![]const u8 {
    const value = args.object.get("kind") orelse return error.InvalidArguments;
    if (value != .string) return error.InvalidArguments;
    if (!std.mem.eql(u8, value.string, "descriptors") and !std.mem.eql(u8, value.string, "redot")) return error.InvalidArguments;
    return value.string;
}
/// `process_id` routes only the Redot kind; descriptors have no process routing.
fn validate(args: Value, routed: bool) !void {
    try wire.fields(args, if (routed) &.{ "kind", "scope", "process_id" } else &.{ "kind", "scope" });
    _ = try kind(args);
    if (args.object.get("scope")) |scope| if (scope != .string or !std.mem.eql(u8, scope.string, "current")) return error.InvalidArguments;
}
fn asValue(a: Allocator, value: anytype) !Value {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    return try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
}
fn id(a: Allocator, tag: []const u8, number: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ tag, number });
}
fn endpoint(a: Allocator, s: *const model.Scene, vertex: u16) ![]const u8 {
    if (vertex < s.star_count) return id(a, "node", s.stars[vertex].seed);
    if (vertex >= model.max_stars and vertex - model.max_stars < s.junction_count) return id(a, "resource", s.junctions[vertex - model.max_stars].identity);
    return error.InvalidGraphEndpoint;
}
pub fn encode(a: Allocator, s: *const model.Scene, graph_kind: []const u8, redact: bool) !Value {
    var nodes: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    var clusters: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    var edges: Value = .{ .array = std.array_list.Managed(Value).init(a) };
    for (s.stars[0..s.star_count]) |node| try nodes.array.append(try asValue(a, .{
        .id = try id(a, "node", node.seed),
        .label = if (redact) "redacted" else node.label(),
        .entity = "node",
        .cluster = try id(a, "cluster", s.clusters[node.cluster].key),
        .members = node.members,
        .units = node.units,
        .alerts = node.alerts,
        .incoming = node.incoming,
        .outgoing = node.outgoing,
        .last_ns = node.last_ns,
        .unavailable = node.unavailable,
        .stale = node.stale,
    }));
    for (s.junctions[0..s.junction_count]) |junction| try nodes.array.append(try asValue(a, .{
        .id = try id(a, "resource", junction.identity),
        .label = "shared resource",
        .entity = "resource",
        .cluster = @as(?u64, null),
        .kind = junction.kind,
        .members = junction.holders,
        .incoming = junction.incoming,
        .outgoing = junction.outgoing,
    }));
    for (s.clusters[0..s.cluster_count]) |cl| try clusters.array.append(try asValue(a, .{
        .id = try id(a, "cluster", cl.key),
        .parent = if (cl.parent) |parent| try id(a, "cluster", parent) else null,
        .label = if (redact) "redacted" else cl.label(),
        .nodes = cl.stars,
        .members = cl.members,
        .units = cl.units,
        .alerts = cl.alerts,
        .rate = cl.rate,
    }));
    for (s.strands[0..s.strand_count], 0..) |edge, ordinal| try edges.array.append(try asValue(a, .{
        .id = try std.fmt.allocPrint(a, "edge:{d}:{d}", .{ edge.seed, ordinal }),
        .source = try endpoint(a, s, edge.a),
        .target = try endpoint(a, s, edge.b),
        .kind = edge.kind,
        .weight = edge.weight,
        .directed = edge.directed,
        .stale = edge.stale,
        .peer = edge.peer,
        .pulse = .{ .forward = edge.pulse.ab, .reverse = edge.pulse.ba, .last_ns = edge.pulse.last_ns },
    }));
    var result = try asValue(a, .{
        .kind = graph_kind,
        .scope = "current",
        .synthetic = s.synthetic,
        .redacted = redact,
        .bounded = true,
        .caps = .{ .nodes = model.max_stars, .resources = model.max_junctions, .clusters = model.max_clusters, .edges = model.max_strands },
        .semantics = if (std.mem.eql(u8, graph_kind, "redot")) "Engine nodes; units = 1 + child count; directed parent-child edges. Signal connections and activity unavailable." else "Process nodes, descriptor units, shared resources and sampled flow rates in bytes/s. Source inventory/projection may omit or group entries.",
    });
    try result.object.put(a, "nodes", nodes);
    try result.object.put(a, "clusters", clusters);
    try result.object.put(a, "edges", edges);
    return result;
}
pub fn descriptors(a: Allocator, owner: *@import("../model/system.zig").Collector, args: Value) !Value {
    try validate(args, false);
    if (!std.mem.eql(u8, try kind(args), "descriptors")) return error.GraphKindUnavailable;
    if (owner.graph_scene) |opaque_scene| {
        const scene: *const model.Scene = @ptrCast(@alignCast(opaque_scene));
        var result = try encode(a, scene, "descriptors", owner.redact);
        try result.object.put(a, "source", .{ .string = "visible_gui_model" });
        try result.object.put(a, "pending", .{ .bool = false });
        return result;
    }
    var graph: @import("../ui/overview/graph_model.zig").State = .{};
    defer graph.deinit();
    try graph.observe(owner);
    const scene = try a.create(model.Scene);
    scene.* = .{};
    var view = .{ .graph = graph, .redact = owner.redact };
    @import("../ui/overview/galaxy_descriptors.zig").fromLive(scene, &view);
    var result = try encode(a, scene, "descriptors", owner.redact);
    try result.object.put(a, "source", .{ .string = "retained_descriptor_publication" });
    try result.object.put(a, "pending", .{ .bool = graph.graph == null });
    try result.object.put(a, "sequence", .{ .integer = if (graph.graph) |g| @intCast(g.sequence) else 0 });
    return result;
}
pub fn redot(a: Allocator, session: *@import("../model/session.zig").Session, args: Value) !Value {
    try validate(args, true);
    if (!std.mem.eql(u8, try kind(args), "redot")) return error.GraphKindUnavailable;
    var snapshot = session.redot.snapshot();
    if (snapshot.nodes.len == 0 and !snapshot.scene_pending) {
        session.redot.requestScene() catch |err| switch (err) {
            error.RedotDebuggerPending, error.RedotDebuggerClosed, error.RedotDebuggerProtocolError => {},
            else => return err,
        };
        snapshot = session.redot.snapshot();
    }
    const scene = try a.create(model.Scene);
    scene.* = .{};
    @import("../ui/redot_galaxy.zig").fill(scene, snapshot.nodes);
    var result = try encode(a, scene, "redot", false);
    try result.object.put(a, "source", .{ .string = "engine_debugger_protocol" });
    try result.object.put(a, "pending", .{ .bool = snapshot.scene_pending });
    try result.object.put(a, "omitted", .{ .integer = @intCast(snapshot.nodes.len - scene.star_count) });
    try result.object.put(a, "revision", .{ .integer = @intCast(snapshot.scene_revision) });
    try result.object.put(a, "state", .{ .string = @tagName(snapshot.state) });
    return result;
}

test "graph export preserves exact ids and directed endpoints from the shared adapter" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scene = try a.create(model.Scene);
    scene.* = .{};
    @import("../ui/overview/galaxy_descriptors.zig").demo(scene, 24, true, 0);
    scene.strands[0].directed = true;
    const result = try encode(a, scene, "descriptors", false);
    try std.testing.expectEqual(scene.star_count + scene.junction_count, result.object.get("nodes").?.array.items.len);
    try std.testing.expectEqual(scene.strand_count, result.object.get("edges").?.array.items.len);
    try std.testing.expect(result.object.get("edges").?.array.items[0].object.get("directed").?.bool);
    try std.testing.expectEqualStrings(try id(a, "node", scene.stars[0].seed), result.object.get("nodes").?.array.items[0].object.get("id").?.string);
    try validate(try std.json.parseFromSliceLeaky(Value, a, "{\"kind\":\"redot\",\"scope\":\"current\",\"process_id\":1}", .{}), true);
    try std.testing.expectError(error.InvalidArguments, validate(try std.json.parseFromSliceLeaky(Value, a, "{\"kind\":\"descriptors\",\"process_id\":1}", .{}), false));
    const hidden = try encode(a, scene, "descriptors", true);
    try std.testing.expectEqualStrings("redacted", hidden.object.get("nodes").?.array.items[0].object.get("label").?.string);
}

test "headless graph observer reads an owned scope without requesting tracing" {
    const c = @import("../c_ui.zig").api;
    // The descriptor collector deliberately excludes its own process. Keep an
    // owned child alive for this scope, and reap it on every exit path.
    // spawn-allow: test child kept for the owned scope and reaped on every exit
    const pid = c.fork();
    if (pid < 0) return error.FixtureForkFailed;
    if (pid == 0) {
        while (true) _ = c.pause();
    }
    defer {
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        _ = @import("../c.zig").api.waitpid(pid, &status, 0);
    }
    const pids = [_]i32{pid};
    var owner: @import("../model/system.zig").Collector = .{ .fd_scope = &pids, .redact = true };
    defer owner.deinit();
    const now = @import("../target/linux.zig").now;
    const started = now();
    while (true) {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const args = try std.json.parseFromSliceLeaky(Value, a, "{\"kind\":\"descriptors\",\"scope\":\"current\"}", .{});
        const result = try descriptors(a, &owner, args);
        if (!result.object.get("pending").?.bool) {
            const nodes = result.object.get("nodes").?.array.items;
            if (nodes.len == 0) return error.OwnedGraphNodeMissing;
            try std.testing.expectEqualStrings("redacted", nodes[0].object.get("label").?.string);
            var pub_view: c.struct_xrt_fdactivity_view = undefined;
            while (c.xrt_fdactivity_acquire(owner.fd_collector.?, &pub_view) == 0) {
                if (now() -| started > 4 * std.time.ns_per_s) return error.GraphPublicationTimeout;
                _ = c.usleep(1000);
            }
            defer c.xrt_fdactivity_release(owner.fd_collector.?);
            try std.testing.expect(pub_view.flow.requested == 0);
            try std.testing.expect(pub_view.event_requested == 0);
            return;
        }
        if (now() -| started > 4 * std.time.ns_per_s) return error.GraphPublicationTimeout;
        _ = c.usleep(1000);
    }
}
