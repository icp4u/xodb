//! `xodb --overview` entry: its own window and session, no debug target.
//! The window loop and the replay path are loop.zig; this adds the live system.
const std = @import("std");
const log = @import("../../log.zig");
const c = @import("../../c_ui.zig").api;
const Window = @import("../../platform/window.zig").Window;
const now = @import("../../target/linux.zig").now;
const m = @import("model.zig");
const vw = @import("view.zig");
const loop = @import("loop.zig");
const Options = @import("options.zig").Options;
const Collector = @import("../../model/system.zig").Collector;
const Shared = @import("../../mcp/shared.zig").Endpoint;
const Server = @import("../../mcp/server.zig").Server;
const Session = @import("../../model/session.zig").Session;
const Launcher = @import("actions.zig").Launcher;

pub fn main(args: []const [:0]const u8, startup_started: u64) !void {
    return loop.main(args, startup_started, live);
}

/// The live system as loop.zig's source.
const Source = struct {
    o: *const Options,
    gpa: std.mem.Allocator,
    collector: *Collector,
    session: *Session,
    shared: ?*Shared,
    server: ?*Server,
    launcher: *Launcher,
    sysstat: @import("sysstat.zig").Live,

    pub fn prepare(self: *Source, view: *vw.View) !void {
        if (self.o.memmap_pid) |pid| {
            // pid + start is the identity; without --memmap-start-ticks the current start is pinned.
            const start = if (self.o.memmap_start != 0) self.o.memmap_start else @import("../../memdefrag/tui.zig").startTicks(pid) orelse {
                log.err(.overview, "xodb: overview: process {d} not found\n", .{pid});
                return error.InvalidMemoryMapIdentity;
            };
            @import("../../model/process_identity.zig").validate(.{ .pid = pid, .start = start }) catch |err| {
                log.err(.overview, "xodb: overview: process {d} start {d}: {s}\n", .{ pid, start, @errorName(err) });
                return err;
            };
            view.memmap.open(.{ .pid = pid, .start = start }, now());
        }
    }
    pub fn interval(self: *Source, ns: u64) void {
        self.collector.fast_ns = ns;
    }
    /// MCP clients are served from the loop, so it must not sleep long.
    pub fn serving(self: *const Source) bool {
        return self.shared != null or self.server != null;
    }
    pub fn sample(self: *Source, gpa: std.mem.Allocator) !*m.Owned {
        return self.sysstat.sample(gpa);
    }
    pub fn poll(self: *Source, view: *vw.View, window: *Window, current: u64) !void {
        self.launcher.redact = view.redact;
        if (self.launcher.poll()) view.setStatus("Process action failed; check target identity and access", .{}, current);
        const started = vw.threadNs();
        self.collector.redact = view.redact;
        self.collector.graph_scene = if (view.panel == .galaxy) &@import("galaxy_descriptors.zig").navigation().scene else null;
        if (view.graph.flow_demand and ((view.panel != .graph and view.panel != .galaxy) or view.paused)) view.graph.stopCapture();
        if (view.treemap.flow_demand and (view.panel != .treemap or view.paused)) view.treemap.stopCapture();
        if (view.files.event_authorized and (view.panel != .files or view.paused)) view.files.stopCapture();
        if (view.files.refreshStatus(self.collector)) window.dirty = true;
        if (view.panel == .files) {
            const changed = view.files.refresh(self.gpa, self.collector, current, view.paused) catch |err| blk: {
                view.setStatus("Descriptor sampling failed: {s}", .{@errorName(err)}, current);
                break :blk false;
            };
            view.files.rebuild(self.gpa, view.redact) catch |err| view.setStatus("Descriptor list failed: {s}", .{@errorName(err)}, current);
            if (changed) {
                window.dirty = true;
                if (c.getenv("XODB_OVERVIEW_AUDIT") != null) if (view.files.file_filter) |file| log.info(.overview, "xodb: files-resource device={d} inode={d} rows={d}\n", .{ file.device, file.inode, view.files.rows.items.len });
                if (c.getenv("XODB_OVERVIEW_AUDIT") != null) log.info(.overview, "xodb: files collector opens={d} sequence={d} filter_pid={d} start={d} rows={d} mode={s} selected_pid={d} selected_fd={d} row={d} top={d} visible={d}\n", .{ self.collector.fd_opens, if (view.files.snapshot) |snap| snap.sequence else 0, if (view.files.filter) |id| id.pid else 0, if (view.files.filter) |id| id.start else 0, view.files.rows.items.len, @tagName(view.files.mode), if (view.files.selected) |id| id.owner.pid else 0, if (view.files.selected) |id| id.fd else -1, view.files.selected_row, view.files.top, view.files.visible });
            }
        }
        // A synthetic galaxy reads no descriptors and starts no tracing.
        if (view.graph.demo == 0 and (view.panel == .graph or view.panel == .galaxy or view.panel == .inheritance)) {
            if (view.graph.refresh(self.collector, current, view.paused, view.panel != .inheritance) catch |err| blk: {
                view.setStatus("Graph update failed: {s}", .{@errorName(err)}, current);
                break :blk false;
            }) {
                window.dirty = true;
                if (c.getenv("XODB_OVERVIEW_AUDIT") != null) if (view.graph.graph) |graph| {
                    const projection = view.graph.projection.?;
                    log.info(.overview, "xodb: fdgraph sequence={d} processes={d} descriptors={d} peer_edges={d} stars={d} particles={d} scope_count={d}\n", .{ graph.sequence, graph.processes, graph.member_count, graph.peer_edges, projection.star_count, projection.particle_count, self.o.graph_count });
                    var rate: f64 = 0;
                    if (view.graph.metrics) |metrics| for (metrics.stars[0..metrics.star_count]) |metric| {
                        rate += metric.read_rate + metric.write_rate;
                    };
                    log.info(.overview, "xodb: fdgraph-flow running={d} requested={d} sequence={d} matched={d} bytes={d} unknown={d} rate={d:.0} lost={d} cpus={d}/{d} status={d}\n", .{ @intFromBool(view.graph.flow_running), @intFromBool(view.graph.flow_requested), view.graph.flow_sequence, if (view.graph.metrics) |metrics| metrics.matched_rows else 0, view.graph.flow_bytes, view.graph.flow_unknown, rate, view.graph.flow_lost, view.graph.flow_active_cpus, view.graph.flow_online_cpus, view.graph.flow_status });
                };
            }
        }
        if (view.panel == .treemap) {
            if (view.treemap.refresh(self.collector, current, view.paused) catch |err| blk: {
                view.setStatus("Treemap update failed: {s}", .{@errorName(err)}, current);
                break :blk false;
            }) {
                window.dirty = true;
                if (c.getenv("XODB_OVERVIEW_AUDIT") != null) if (view.treemap.tree) |tree|
                    log.info(.overview, "xodb: fdtreemap sequence={d} flow={d} fds={d} nodes={d} focus={d} scope_count={d} running={d} measured={d} read={d} write={d}\n", .{ tree.sequence, tree.flow_sequence, tree.fd_count, tree.count, view.treemap.focus, self.o.graph_count, @intFromBool(view.treemap.flow_running), tree.nodes[0].total.flow_measured, tree.nodes[0].total.read_bytes, tree.nodes[0].total.write_bytes });
            }
        }
        if (view.panel == .inheritance and view.graph.refreshInheritance()) {
            window.dirty = true;
            if (c.getenv("XODB_OVERVIEW_AUDIT") != null) if (view.graph.inheritance) |rows|
                log.info(.overview, "xodb: fdinherit sequence={d} matched={d} shown={d} cloexec={d} no_cloexec={d} unknown={d} scope_count={d}\n", .{ rows.sequence, rows.matched, rows.count, rows.cloexec, rows.no_cloexec, rows.flags_unknown, self.o.graph_count });
        }
        if (view.panel == .memory_map) {
            if (view.memmap.refresh(self.gpa, self.collector, current, view.paused, view.redact)) window.dirty = true;
        }
        _ = self.collector.tick(current, if (view.paused) 0 else view.groups(true), view.panel == .processes) catch |err| blk: {
            view.setStatus("Sampling failed: {s}", .{@errorName(err)}, current);
            break :blk false;
        };
        view.sourceCost(vw.threadNs() -| started);
        if (self.shared) |endpoint| try endpoint.pump(self.session);
        if (self.server) |p| try p.pump(self.session);
    }
};

fn live(o: *const Options, startup_started: u64) !void {
    const gpa = std.heap.c_allocator;
    var collector: Collector = .{ .redact = o.redact, .fd_scope = o.graph_pids[0..o.graph_count] };
    defer collector.deinit();
    const session = try gpa.create(Session);
    defer gpa.destroy(session);
    session.* = Session.init();
    session.agent_scope = .observe;
    defer session.deinit();
    var shared: ?Shared = if (o.session_socket) |path| try Shared.init(path, null) else null;
    defer if (shared) |*endpoint| endpoint.deinit();
    if (shared) |*endpoint| {
        endpoint.overview_shared = &collector;
        endpoint.overview_only = true;
    }
    const server = if (o.mcp) try gpa.create(Server) else null;
    defer if (server) |p| {
        p.deinit();
        gpa.destroy(p);
    };
    if (server) |p| {
        p.* = .{ .overview_shared = &collector, .overview_only = true };
        try p.init();
        std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    }
    var view = try vw.View.init(gpa);
    defer view.deinit();
    var launcher: Launcher = .{ .redact = o.redact };
    view.action_hook = launchAction;
    view.action_context = &launcher;
    var source = Source{ .o = o, .gpa = gpa, .collector = &collector, .session = session, .shared = if (shared) |*endpoint| endpoint else null, .server = server, .launcher = &launcher, .sysstat = .{ .collector = &collector } };
    try loop.run(o, gpa, &view, &source, startup_started);
}

fn launchAction(context: ?*anyopaque, request: @import("actions.zig").Request) !void {
    const launcher: *@import("actions.zig").Launcher = @ptrCast(@alignCast(context.?));
    try launcher.launch(request);
}
