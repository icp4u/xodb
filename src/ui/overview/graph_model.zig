//! Presentation of coherent C descriptor graph publications. No target IO here.
const std = @import("std");
const system = @import("../../model/system.zig");
const c = system.c;
const Identity = @import("view.zig").Identity;
pub const State = struct {
    snapshot: ?*c.struct_xrt_fd_snapshot = null,
    graph: ?*c.struct_xrt_fdgraph = null,
    projection: ?*c.struct_xrt_fdgraph_projection = null,
    layout: ?*c.struct_xrt_fdgraph_layout = null,
    request_at: u64 = 0,
    focus: ?Identity = null,
    group_path: [4096]u8 = undefined,
    group_len: usize = 0,
    collapse: bool = true,
    max_stars: u32 = 64,
    dirty: bool = true,
    poll_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    peer_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    peer_reason: ?[]const u8 = null,
    owner_cpu_ns: u64 = 0,
    pub fn deinit(self: *State) void {
        c.xrt_fdgraph_layout_free(self.layout);
        c.xrt_fdgraph_projection_free(self.projection);
        c.xrt_fdgraph_free(self.graph);
        c.xrt_fd_snapshot_free(self.snapshot);
        self.layout = null;
        self.projection = null;
        self.graph = null;
        self.snapshot = null;
    }
    pub fn refresh(self: *State, owner: *system.Collector, now: u64, paused: bool) !bool {
        if (paused) return self.reproject();
        const ctx = try owner.descriptors();
        if (self.request_at == 0 or now -| self.request_at >= 500_000_000) {
            const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .poll_all = 1, .graph = 1 };
            if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) self.request_at = now;
        }
        var published: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(ctx, &published) == 0) return self.reproject();
        var fresh: ?*c.struct_xrt_fdgraph = null;
        var snapshot: ?*c.struct_xrt_fd_snapshot = null;
        {
            defer c.xrt_fdactivity_release(ctx);
            self.poll_status = published.poll_status;
            self.peer_status = published.peer_status;
            self.peer_reason = if (published.peer_reason != null) std.mem.span(published.peer_reason) else null;
            self.owner_cpu_ns = published.owner_cpu_ns;
            if (published.graph != null and published.poll != null and
                (self.graph == null or self.graph.?.sequence != published.graph.*.sequence))
            {
                fresh = c.xrt_fdgraph_copy(published.graph) orelse return error.OutOfMemory;
                errdefer c.xrt_fdgraph_free(fresh);
                snapshot = c.xrt_fd_snapshot_copy(published.poll) orelse return error.OutOfMemory;
            }
        }
        if (fresh) |g| {
            self.deinit();
            self.graph = g;
            self.snapshot = snapshot;
            self.dirty = true;
        }
        return try self.reproject();
    }
    fn reproject(self: *State) !bool {
        if (!self.dirty) return false;
        const g = self.graph orelse return false;
        var selected: u32 = std.math.maxInt(u32);
        var group: u64 = 0;
        if (self.focus) |id| {
            for (g.nodes[0..g.processes], 0..) |n, i| if (n.pid == id.pid and n.start == id.start) {
                selected = @intCast(i);
                break;
            };
            if (selected == std.math.maxInt(u32)) {
                self.focus = null;
                self.group_len = 0;
            }
        }
        if (self.group_len > 0) {
            for (g.nodes[0..g.processes], 0..) |_, i| if (std.mem.eql(u8, self.cgroup(@intCast(i)), self.group_path[0..self.group_len])) {
                group = g.groups[i];
                break;
            };
            if (group == 0) self.group_len = 0;
        }
        const options = c.struct_xrt_fdgraph_project_options{
            .max_stars = self.max_stars,
            .max_particles = 1024,
            .focus_process = selected,
            .collapse_cgroups = @intFromBool(self.collapse and group == 0),
            .focus_group = group,
        };
        var projection: ?*c.struct_xrt_fdgraph_projection = null;
        if (c.xrt_fdgraph_project(g, &options, &projection) != c.XRT_OK) return error.GraphProjectionFailed;
        errdefer c.xrt_fdgraph_projection_free(projection);
        var layout: ?*c.struct_xrt_fdgraph_layout = null;
        if (c.xrt_fdgraph_layout(g, projection, 128, 2048, &layout) != c.XRT_OK) return error.GraphLayoutFailed;
        c.xrt_fdgraph_projection_free(self.projection);
        c.xrt_fdgraph_layout_free(self.layout);
        self.projection = projection;
        self.layout = layout;
        self.dirty = false;
        return true;
    }
    pub fn cgroup(self: *const State, node: u32) []const u8 {
        const g = self.graph orelse return "";
        const s = self.snapshot orelse return "";
        if (node >= g.processes) return "";
        const source = g.nodes[node].source_process;
        if (source >= s.process_count) return "";
        const p = s.processes[source];
        if (p.cgroup_status != c.XRT_FD_CGROUP_CURRENT or p.cgroup_length == 0 or
            p.cgroup >= s.strings_length or p.cgroup_length >= s.strings_length - p.cgroup) return "";
        return s.strings[p.cgroup..][0..p.cgroup_length];
    }
    pub fn focusStar(self: *State, star: u32) void {
        const p = self.projection orelse return;
        const g = self.graph orelse return;
        if (star >= p.star_count) return;
        const s = p.stars[star];
        if (s.processes == 1) {
            const n = g.nodes[s.source_node];
            self.focus = .{ .pid = n.pid, .start = n.start };
        } else if (s.mixed_groups == 0) {
            const group = self.cgroup(s.sample_node);
            self.group_len = @min(group.len, self.group_path.len);
            @memcpy(self.group_path[0..self.group_len], group[0..self.group_len]);
        } else self.max_stars = @min(128, self.max_stars * 2);
        self.dirty = true;
    }
    pub fn all(self: *State) void {
        self.focus = null;
        self.group_len = 0;
        self.dirty = true;
    }
};
