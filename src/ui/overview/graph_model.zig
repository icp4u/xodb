//! Presentation of coherent C descriptor graph publications. No target IO here.
const std = @import("std");
const system = @import("../../model/system.zig");
const c = system.c;
const Identity = @import("view.zig").Identity;
pub const State = struct {
    snapshot: ?*c.struct_xrt_fd_snapshot = null,
    inheritance: ?*c.struct_xrt_fdinherit = null,
    inheritance_attempt: ?u64 = null,
    inheritance_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    graph: ?*c.struct_xrt_fdgraph = null,
    projection: ?*c.struct_xrt_fdgraph_projection = null,
    layout: ?*c.struct_xrt_fdgraph_layout = null,
    metrics: ?*c.struct_xrt_fdflow_graph = null,
    context: ?*c.struct_xrt_fdactivity = null,
    events_enabled: bool = true,
    flow_demand: bool = false,
    flow_running: bool = false,
    flow_requested: bool = false,
    flow_sequence: u64 = 0,
    flow_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    flow_failure: c.struct_xrt_perf_failure = std.mem.zeroes(c.struct_xrt_perf_failure),
    flow_flags: u32 = 0,
    flow_lost: u64 = 0,
    flow_unknown: u64 = 0,
    flow_bytes: u64 = 0,
    flow_active_cpus: u32 = 0,
    flow_online_cpus: u32 = 0,
    request_at: u64 = 0,
    focus: ?Identity = null,
    group_path: [4096]u8 = undefined,
    group_len: usize = 0,
    collapse: bool = true,
    max_stars: u32 = 64,
    dirty: bool = true,
    poll_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    graph_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    peer_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    peer_reason: ?[]const u8 = null,
    owner_cpu_ns: u64 = 0,
    pub fn deinit(self: *State) void {
        c.xrt_fdinherit_free(self.inheritance);
        self.inheritance = null;
        self.inheritance_attempt = null;
        self.inheritance_status = c.XRT_STALE_SNAPSHOT;
        c.xrt_fdflow_graph_free(self.metrics);
        self.metrics = null;
        self.flow_sequence = 0;
        c.xrt_fdgraph_layout_free(self.layout);
        c.xrt_fdgraph_projection_free(self.projection);
        c.xrt_fdgraph_free(self.graph);
        c.xrt_fd_snapshot_free(self.snapshot);
        self.layout = null;
        self.projection = null;
        self.graph = null;
        self.snapshot = null;
    }
    pub fn refresh(self: *State, owner: *system.Collector, now: u64, paused: bool, live: bool) !bool {
        const ctx = try owner.descriptors();
        self.context = ctx;
        if (!paused and (self.request_at == 0 or now -| self.request_at >= 500_000_000)) {
            const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .poll_all = 1, .graph = 1, .fdinfo_all = @intFromBool(!live), .flow = @intFromBool(self.events_enabled and live), .stop_flow = @intFromBool(!self.events_enabled or !live) };
            if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) {
                self.request_at = now;
                self.flow_demand = self.events_enabled and live;
            }
        }
        var published: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(ctx, &published) == 0) return self.reproject();
        var changed = false;
        var fresh: ?*c.struct_xrt_fdgraph = null;
        var snapshot: ?*c.struct_xrt_fd_snapshot = null;
        var flow_copy: ?*c.struct_xrt_fdflow_live = null;
        defer c.xrt_fdflow_live_free(flow_copy);
        {
            defer c.xrt_fdactivity_release(ctx);
            changed = self.poll_status != published.poll_status or self.graph_status != published.graph_status or self.peer_status != published.peer_status;
            self.graph_status = published.graph_status;
            self.poll_status = published.poll_status;
            self.peer_status = published.peer_status;
            self.peer_reason = if (published.peer_reason != null) std.mem.span(published.peer_reason) else null;
            self.owner_cpu_ns = published.owner_cpu_ns;
            const flow = published.flow;
            changed = changed or self.flow_running != (flow.stream.running != 0) or self.flow_status != flow.status or self.flow_requested != (flow.requested != 0);
            self.flow_running = flow.stream.running != 0;
            self.flow_requested = flow.requested != 0;
            self.flow_status = flow.status;
            self.flow_failure = flow.failure;
            self.flow_flags = flow.stream.flags | (flow.counts.flags << 16);
            self.flow_lost = flow.stream.lost;
            self.flow_unknown = flow.counts.unknown_read +| flow.counts.unknown_write;
            self.flow_bytes = flow.counts.read_bytes +| flow.counts.write_bytes;
            self.flow_active_cpus = flow.stream.active_cpus;
            self.flow_online_cpus = flow.stream.online_cpus;
            if (!paused and published.graph != null and published.poll != null and
                (self.graph == null or self.graph.?.sequence != published.graph.*.sequence))
            {
                fresh = c.xrt_fdgraph_copy(published.graph) orelse return error.OutOfMemory;
                errdefer c.xrt_fdgraph_free(fresh);
                snapshot = c.xrt_fd_snapshot_copy(published.poll) orelse return error.OutOfMemory;
            }
            // Copy only; the metrics build runs after release.
            if (!paused and fresh == null and self.graph != null and self.snapshot != null and self.projection != null and self.layout != null and (self.metrics == null or self.flow_sequence != flow.sequence))
                flow_copy = c.xrt_fdflow_live_copy(&flow) orelse return error.OutOfMemory;
        }
        if (flow_copy) |flow| {
            var metrics: ?*c.struct_xrt_fdflow_graph = null;
            if (c.xrt_fdflow_graph(self.graph, self.snapshot, self.projection, self.layout, flow, &metrics) != c.XRT_OK) return error.FlowProjectionFailed;
            c.xrt_fdflow_graph_free(self.metrics);
            self.metrics = metrics;
            self.flow_sequence = flow.sequence;
            changed = true;
        }
        if (fresh) |g| {
            self.deinit();
            self.graph = g;
            self.snapshot = snapshot;
            self.dirty = true;
        }
        return (try self.reproject()) or changed;
    }
    pub fn refreshInheritance(self: *State) bool {
        const snapshot = self.snapshot orelse return false;
        if (self.inheritance_attempt != null and self.inheritance_attempt.? == snapshot.sequence) return false;
        self.inheritance_attempt = snapshot.sequence;
        c.xrt_fdinherit_free(self.inheritance);
        self.inheritance = null;
        self.inheritance_status = c.xrt_fdinherit_build(snapshot, 8192, &self.inheritance);
        return true;
    }
    pub fn stopCapture(self: *State) void {
        if (!self.flow_demand) return;
        const ctx = self.context orelse return;
        const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .stop_flow = 1 };
        if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) {
            self.flow_demand = false;
            self.request_at = 0;
        }
    }
    pub fn toggleEvents(self: *State) void {
        self.events_enabled = !self.events_enabled;
        self.request_at = 0;
        if (!self.events_enabled) self.stopCapture();
    }
    pub fn flowing(self: *const State, now: u64) bool {
        const metrics = self.metrics orelse return false;
        return self.flow_running and metrics.last_ns != 0 and now -| metrics.last_ns < 700_000_000;
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
        c.xrt_fdflow_graph_free(self.metrics);
        self.metrics = null;
        self.flow_sequence = 0;
        self.dirty = false;
        return true;
    }
    pub fn failure(self: *const State) ?[]const u8 {
        const status = if (self.poll_status != c.XRT_OK and self.poll_status != c.XRT_STALE_SNAPSHOT) self.poll_status else self.graph_status;
        return switch (status) {
            c.XRT_OK, c.XRT_STALE_SNAPSHOT => null,
            c.XRT_OUT_OF_MEMORY => "Not enough memory for a descriptor snapshot",
            c.XRT_INVALID_ARGUMENT => "Invalid descriptor snapshot",
            c.XRT_PERMISSION_DENIED => "Descriptor snapshot denied; check process access",
            else => "Descriptor snapshot unavailable",
        };
    }
    pub fn cgroup(self: *const State, node: u32) []const u8 {
        const g = self.graph orelse return "";
        const s = self.snapshot orelse return "";
        if (node >= g.processes) return "";
        const source = g.nodes[node].source_process;
        if (source >= s.process_count) return "";
        const p = s.processes[source];
        if ((p.cgroup_status != c.XRT_FD_CGROUP_CURRENT and p.cgroup_status != c.XRT_FD_CGROUP_STALE) or p.cgroup_length == 0 or
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
