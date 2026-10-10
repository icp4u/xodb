//! Bounded presentation cache. C owns path identity, metrics and geometry.
const std = @import("std");
const system = @import("../../model/system.zig");
const c = system.c;
pub const options = c.struct_xrt_fdtreemap_options{ .max_nodes = 4096, .max_text = 1024 * 1024, .max_depth = 32 };
pub const State = struct {
    tree: ?*c.struct_xrt_fdtreemap = null,
    layout: ?*c.struct_xrt_fdtreemap_layout = null,
    context: ?*c.struct_xrt_fdactivity = null,
    focus: u32 = 0,
    focus_lost: bool = false,
    max_tiles: u32 = 64,
    aspect: f64 = 0,
    dirty: bool = true,
    events_enabled: bool = true,
    flow_demand: bool = false,
    flow_running: bool = false,
    flow_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    failure: c.struct_xrt_perf_failure = std.mem.zeroes(c.struct_xrt_perf_failure),
    lost: u64 = 0,
    unknown: u64 = 0,
    active_cpus: u32 = 0,
    online_cpus: u32 = 0,
    poll_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    build_status: c.enum_xrt_status = c.XRT_STALE_SNAPSHOT,
    request_at: u64 = 0,
    build_at: u64 = 0,
    pub fn deinit(self: *State) void {
        c.xrt_fdtreemap_layout_free(self.layout);
        c.xrt_fdtreemap_free(self.tree);
        self.layout = null;
        self.tree = null;
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
    pub fn refresh(self: *State, owner: *system.Collector, now: u64, paused: bool) !bool {
        const ctx = try owner.descriptors();
        self.context = ctx;
        if (!paused and (self.request_at == 0 or now -| self.request_at >= 500_000_000)) {
            // poll_all refreshes seekable offsets every scan; fdinfo_all would only re-read pipes/sockets.
            const request = c.struct_xrt_fdactivity_request{ .interval_ms = 1000, .poll_all = 1, .flow = @intFromBool(self.events_enabled), .stop_flow = @intFromBool(!self.events_enabled) };
            if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) {
                self.request_at = now;
                self.flow_demand = self.events_enabled;
            }
        }
        var published: c.struct_xrt_fdactivity_view = undefined;
        if (c.xrt_fdactivity_acquire(ctx, &published) == 0) return false;
        // Copy under the lock, build after release: the flow drain waits on it.
        var snapshot: ?*c.struct_xrt_fd_snapshot = null;
        var flow_copy: ?*c.struct_xrt_fdflow_live = null;
        var changed = false;
        {
            defer c.xrt_fdactivity_release(ctx);
            const flow = published.flow;
            changed = self.flow_running != (flow.stream.running != 0) or self.flow_status != flow.status or self.poll_status != published.poll_status;
            self.flow_running = flow.stream.running != 0;
            self.flow_status = flow.status;
            self.failure = flow.failure;
            self.poll_status = published.poll_status;
            self.lost = flow.stream.lost;
            self.unknown = flow.counts.unknown_read +| flow.counts.unknown_write;
            self.active_cpus = if (self.flow_running) flow.stream.active_cpus else 0;
            self.online_cpus = flow.stream.online_cpus;
            const poll: *const c.struct_xrt_fd_snapshot = if (published.poll != null) @ptrCast(published.poll) else return changed;
            if (paused) return changed;
            if (self.tree) |tree| {
                if (tree.sequence == poll.sequence and tree.flow_sequence == flow.sequence and tree.flow_running == flow.stream.running) return changed;
                if (now -| self.build_at < 500_000_000 and tree.flow_running == flow.stream.running) return changed;
            }
            self.build_at = now;
            snapshot = c.xrt_fd_snapshot_copy(poll) orelse return error.OutOfMemory;
            flow_copy = c.xrt_fdflow_live_copy(&flow) orelse {
                c.xrt_fd_snapshot_free(snapshot);
                return error.OutOfMemory;
            };
        }
        defer c.xrt_fd_snapshot_free(snapshot);
        defer c.xrt_fdflow_live_free(flow_copy);
        var fresh: ?*c.struct_xrt_fdtreemap = null;
        self.build_status = c.xrt_fdtreemap_build(snapshot, flow_copy, &options, &fresh);
        if (self.build_status != c.XRT_OK) return true;
        var focus: u32 = 0;
        if (self.tree) |old| {
            if (self.focus != 0) {
                self.focus_lost = c.xrt_fdtreemap_relocate(old, self.focus, fresh, &focus) != c.XRT_OK;
                if (self.focus_lost) focus = 0;
            }
        }
        self.deinit();
        self.tree = fresh;
        self.focus = focus;
        self.dirty = true;
        changed = true;
        return changed;
    }
    pub fn select(self: *State, node: u32) void {
        const tree = self.tree orelse return;
        if (node >= tree.count) return;
        self.focus = node;
        self.focus_lost = false;
        self.dirty = true;
    }
    pub fn up(self: *State) void {
        const tree = self.tree orelse return;
        self.select(if (self.focus == 0) 0 else tree.nodes[self.focus].parent);
    }
    pub fn project(self: *State, aspect: f64) !void {
        if (!self.dirty and self.aspect == aspect) return;
        const tree = self.tree orelse return;
        var layout: ?*c.struct_xrt_fdtreemap_layout = null;
        if (c.xrt_fdtreemap_layout(tree, self.focus, self.max_tiles, aspect, &layout) != c.XRT_OK) return error.TreemapLayoutUnavailable;
        c.xrt_fdtreemap_layout_free(self.layout);
        self.layout = layout;
        self.aspect = aspect;
        self.dirty = false;
    }
};
/// Visible escaping keeps control bytes from changing the label's layout.
/// Exact bytes are available through MCP path_hex when redaction is off.
pub fn label(out: []u8, value: []const u8) []const u8 {
    var used: usize = 0;
    for (value) |byte| {
        if (used + 4 > out.len) break;
        if (byte >= 32 and byte < 127 and byte != '\\') {
            out[used] = byte;
            used += 1;
        } else {
            const hex = "0123456789abcdef";
            out[used..][0..4].* = .{ '\\', 'x', hex[byte >> 4], hex[byte & 15] };
            used += 4;
        }
    }
    return out[0..used];
}
