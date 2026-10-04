//! Capture timeline: CPU sample density over time plus one lane per thread.
//!
//! The caller owns every input slice and passes the current `Data` on each call.
//! The view keeps only scalars (capture identity, selection, view range and the
//! last drawn geometry) plus caches derived from them, never a pointer into a
//! capture. Times are nanoseconds since capture start; ranges are half-open.
//! Sample density counts samples. Lanes show elapsed scheduling time. A gap
//! without samples is not evidence of waiting.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const style = @import("style.zig");
const theme = style.theme;
/// The shared model: the profile filter this view returns.
const model = @import("../profile/timeline.zig");

/// The debugger's thread capacity; captures select at most this many TIDs.
pub const max_lanes = 1024;
/// Widest plot measured in pixel columns; wider plots are drawn coarser.
pub const max_columns = 4096;
pub const max_visible_lanes = 64;
/// Overview buckets. At most two quads each (all threads, selected thread).
pub const max_buckets = 1024;
/// Lane geometry quads per frame: state runs, density runs and edge markers.
/// Text, overview, marks and labels have separate fixed caps below.
pub const lane_quads = 4096;
const max_state_runs = lane_quads / 2;
const max_density_runs = lane_quads * 3 / 8;
const max_markers = lane_quads / 8;
const max_drawn_marks = 128;
const max_lane_marks = 16;
const max_interval_labels = 48;
const lane_h: f32 = 24;
const header_h: f32 = 34;
const overview_h: f32 = 40;
const axis_h: f32 = 20;
const footer_h: f32 = 24;
/// A press and release closer than this is a click, not a range.
const drag_threshold: f32 = 3;
/// Narrowest view the overview wheel zooms to.
const min_span_ns: u64 = 1000;

pub const State = enum(u8) { running, off_cpu, unknown };

/// One scheduling span of a thread, like the model's `Span`. `from_observed`/
/// `to_observed` are false when an end is a cut rather than a recorded
/// transition (live capture edge, collection stop); the real span may extend
/// beyond it. `preempted` marks an off-CPU span opened by a preempting
/// switch-out (`Span.switch_out_preempted`): a transition attribute, not a cause.
/// `detail` is shown on hover, such as an unknown span's reason.
pub const Interval = struct {
    from_ns: u64,
    to_ns: u64,
    state: State,
    from_observed: bool = true,
    to_observed: bool = true,
    preempted: bool = false,
    detail: []const u8 = "",
};
pub const MarkKind = enum(u8) { loss, debugger_stop, application, syscall };
/// A capture-wide (`tid == null`) or per-thread time range with special meaning.
/// A zero-length mark is drawn as a tick.
pub const Mark = struct { from_ns: u64, to_ns: u64, kind: MarkKind, tid: ?u32 = null, label: []const u8 = "" };
pub const Lane = struct {
    tid: u32,
    /// Stable color identity, as the debugger's thread ID; 0 uses the lane order.
    debugger_id: u64 = 0,
    label: []const u8 = "",
    /// Sample times, sorted ascending; equal times are allowed.
    samples: []const u64 = &.{},
    /// Sorted, non-overlapping spans. Time covered by none is unknown.
    intervals: []const Interval = &.{},
};
pub const Data = struct {
    capture_id: u64,
    revision: u64,
    /// The capture covers [0, extent_ns).
    extent_ns: u64,
    live: bool = false,
    state_label: ?[]const u8 = null,
    /// False when lanes carry CPU samples only; then every lane is unknown.
    scheduling: bool = false,
    lanes: []const Lane,
    marks: []const Mark = &.{},
    /// Loss reported without a time, such as perf lost-sample counts.
    lost_samples: u64 = 0,
    debugger_marks_dropped: u64 = 0,
    application_count: usize = 0,
    syscall_count: usize = 0,

    /// Null when the contract holds; otherwise a reason. O(total records).
    pub fn validate(self: *const Data) ?[]const u8 {
        if (self.lanes.len > max_lanes) return "more lanes than the thread limit";
        for (self.lanes, 0..) |lane, i| {
            if (lane.tid == 0) return "lane without a TID";
            for (self.lanes[0..i]) |other| if (other.tid == lane.tid) return "duplicate lane TID";
            for (lane.samples[0..lane.samples.len -| 1], lane.samples[@min(1, lane.samples.len)..]) |a, b| if (b < a) return "unsorted samples";
            var end: u64 = 0;
            for (lane.intervals) |interval| {
                if (interval.to_ns < interval.from_ns) return "interval ends before it starts";
                if (interval.from_ns < end) return "overlapping or unsorted intervals";
                end = interval.to_ns;
            }
        }
        for (self.marks) |mark| if (mark.to_ns < mark.from_ns) return "mark ends before it starts";
        return null;
    }
};
pub const Range = struct { from_ns: u64, to_ns: u64 };
/// What the coordinator applies to flames and MCP. Matches the profile filter:
/// `[from_ns, to_ns)` with a null `to_ns` meaning no upper bound, and an optional thread selection.
pub const Selection = struct {
    capture_id: u64,
    from_ns: u64 = 0,
    to_ns: ?u64 = null,
    tid: ?u32 = null,
    tids: model.ThreadSet = .{},
};
const Area = enum { header, overview, plot, labels };
const Drag = struct { area: Area, x: f32, y: f32, anchor_ns: u64, lane: ?usize, additive: bool = false };
const Geometry = struct {
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    overview: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    plot: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    labels: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    fit: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    reset: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    visible: usize = 0,
    cols: usize = 0,
};
const Run = struct { x0: u16, x1: u16, value: u8 };
const Marker = struct { x: u16, kind: enum(u8) { open_from, open_to, preempted } };
const Key = struct { capture_id: u64, revision: u64, extent_ns: u64, view: Range, cols: usize, first_lane: usize, visible: usize, tid: ?u32, tids: model.ThreadSet, scheduling: bool };
const running_bit: u8 = 1;
const off_bit: u8 = 2;
const unknown_bit: u8 = 4;

pub const TimelineView = struct {
    capture_id: u64 = 0,
    revision: u64 = 0,
    extent_ns: u64 = 0,
    lane_count: usize = 0,
    /// Committed selection. Null range selects the whole capture; no explicit threads selects all.
    range: ?Range = null,
    tid: ?u32 = null,
    tids: model.ThreadSet = .{},
    /// Null follows the whole (possibly growing) capture.
    view: ?Range = null,
    first_lane: usize = 0,
    drag: ?Drag = null,
    pointer: ?[2]f32 = null,
    geometry: Geometry = .{},
    live: bool = false,
    lane_tids: [max_lanes]u32 = @splat(0),
    diagnostic: ?[]const u8 = null,
    key: ?Key = null,
    rebuilds: u64 = 0,
    // Caches for `key`.
    bucket_count: usize = 0,
    bucket_px: usize = 1,
    bucket_peak: u32 = 0,
    buckets: [max_buckets][2]u32 = undefined,
    density_peak: u32 = 0,
    state_runs: [max_state_runs]Run = undefined,
    density_runs: [max_density_runs]Run = undefined,
    markers: [max_markers]Marker = undefined,
    state_first: [max_visible_lanes + 1]u16 = @splat(0),
    density_first: [max_visible_lanes + 1]u16 = @splat(0),
    marker_first: [max_visible_lanes + 1]u16 = @splat(0),
    masks: [max_columns]u8 = undefined,
    counts: [max_columns]u32 = undefined,

    /// Call with the current data before input and drawing. Returns true when
    /// the committed selection changed, so the coordinator must re-filter.
    pub fn sync(self: *TimelineView, data: *const Data) bool {
        if (data.capture_id != self.capture_id) {
            // A replacement capture: nothing selected in the old one applies.
            const had = self.range != null or self.hasThreadSelection();
            self.* = .{ .capture_id = data.capture_id, .geometry = self.geometry, .pointer = self.pointer };
            self.revision = data.revision;
            self.extent_ns = data.extent_ns;
            self.lane_count = data.lanes.len;
            self.diagnostic = data.validate();
            return had;
        }
        if (data.revision == self.revision and data.extent_ns == self.extent_ns and data.lanes.len == self.lane_count) return false;
        self.revision = data.revision;
        self.extent_ns = data.extent_ns;
        self.lane_count = data.lanes.len;
        self.diagnostic = data.validate();
        var changed = false;
        // Growth keeps the selection. A shorter extent clips it, and a range
        // wholly beyond the new end selects the whole capture again.
        if (self.range) |range| {
            if (range.from_ns >= data.extent_ns) {
                self.range = null;
                changed = true;
            } else if (range.to_ns > data.extent_ns) {
                self.range = .{ .from_ns = range.from_ns, .to_ns = data.extent_ns };
                changed = true;
            }
        }
        if (self.view) |view| {
            if (view.to_ns > data.extent_ns) self.view = if (view.from_ns <= data.extent_ns and data.extent_ns - view.from_ns >= min_span_ns) .{ .from_ns = view.from_ns, .to_ns = data.extent_ns } else null;
        }
        if (self.tid) |tid| {
            for (data.lanes) |lane| {
                if (lane.tid == tid) break;
            } else {
                self.tid = null;
                changed = true;
            }
        }
        if (self.tids.len > 0) {
            var kept: [max_lanes]u32 = undefined;
            var count: usize = 0;
            for (self.tids.slice()) |tid| {
                for (data.lanes) |lane| if (lane.tid == tid) {
                    kept[count] = tid;
                    count += 1;
                    break;
                };
            }
            if (count != self.tids.len) {
                var f = self.filter();
                f.setThreads(kept[0..count]) catch unreachable;
                self.tid = f.tid;
                self.tids = f.tids;
                changed = true;
            }
        }
        self.first_lane = @min(self.first_lane, data.lanes.len -| 1);
        return changed;
    }
    pub fn selection(self: *const TimelineView) Selection {
        return .{ .capture_id = self.capture_id, .from_ns = if (self.range) |r| r.from_ns else 0, .to_ns = if (self.range) |r| r.to_ns else null, .tid = self.tid, .tids = self.tids };
    }
    /// The committed selection as the shared profile filter (for flames and MCP).
    /// No range is `[0, maxInt)`, which follows a growing capture.
    pub fn filter(self: *const TimelineView) model.Filter {
        return .{ .tid = self.tid, .tids = self.tids, .from_ns = if (self.range) |r| r.from_ns else 0, .to_ns = if (self.range) |r| r.to_ns else std.math.maxInt(u64) };
    }
    /// Whole capture, all threads, unzoomed. Returns true if the selection changed.
    pub fn reset(self: *TimelineView) bool {
        const had = self.range != null or self.hasThreadSelection();
        self.range = null;
        self.tid = null;
        self.tids = .{};
        self.view = null;
        self.drag = null;
        return had;
    }
    /// Zooms the lanes to the selected range.
    pub fn fitRange(self: *TimelineView) void {
        const range = self.range orelse return;
        self.view = if (range.to_ns - range.from_ns >= self.extent_ns) null else range;
    }
    fn currentView(self: *const TimelineView) Range {
        return self.view orelse .{ .from_ns = 0, .to_ns = self.extent_ns };
    }
    fn areaAt(self: *const TimelineView, x: f32, y: f32) ?Area {
        const g = self.geometry;
        if (inside(g.overview, x, y)) return .overview;
        if (inside(g.plot, x, y)) return .plot;
        if (inside(g.labels, x, y)) return .labels;
        return null;
    }
    fn laneAt(self: *const TimelineView, y: f32) ?usize {
        const g = self.geometry;
        if (y < g.plot.y or g.visible == 0) return null;
        const row: usize = @intFromFloat((y - g.plot.y) / lane_h);
        if (row >= g.visible) return null;
        const lane = self.first_lane + row;
        return if (lane < self.lane_count) lane else null;
    }
    fn timeAt(self: *const TimelineView, area: Area, x: f32) u64 {
        const g = self.geometry;
        return switch (area) {
            .overview => timeAtX(x, g.overview, 0, self.extent_ns),
            else => blk: {
                const view = self.currentView();
                break :blk timeAtX(x, g.plot, view.from_ns, view.to_ns - view.from_ns);
            },
        };
    }
    /// A button press. Returns true when the timeline consumed it.
    pub fn press(self: *TimelineView, x: f32, y: f32) bool {
        return self.pressModified(x, y, false);
    }
    /// Capture Ctrl at press time, even if it is released before the pointer.
    pub fn pressModified(self: *TimelineView, x: f32, y: f32, additive: bool) bool {
        if (!inside(self.geometry.bounds, x, y)) return false;
        self.pointer = .{ x, y };
        // Header buttons act on release, like a click elsewhere.
        const area = self.areaAt(x, y) orelse .header;
        self.drag = .{ .area = area, .x = x, .y = y, .anchor_ns = self.timeAt(area, x), .lane = self.laneAt(y), .additive = additive };
        return true;
    }
    /// Pointer motion. Cheap: updates the hover/drag position only. Returns true
    /// when a redraw is needed.
    pub fn motion(self: *TimelineView, x: f32, y: f32) bool {
        const was = self.pointer;
        self.pointer = if (inside(self.geometry.bounds, x, y) or self.drag != null) .{ x, y } else null;
        if (was == null and self.pointer == null) return false;
        if (was == null or self.pointer == null) return true;
        return was.?[0] != x or was.?[1] != y;
    }
    /// A button release. Commits a range, a thread, or a header button.
    /// Returns true when the committed selection changed.
    pub fn release(self: *TimelineView, x: f32, y: f32) bool {
        const drag = self.drag orelse return false;
        self.drag = null;
        self.pointer = .{ x, y };
        if (@abs(x - drag.x) < drag_threshold) {
            if (inside(self.geometry.reset, drag.x, drag.y) and inside(self.geometry.reset, x, y)) return self.reset();
            if (inside(self.geometry.fit, drag.x, drag.y) and inside(self.geometry.fit, x, y)) {
                self.fitRange();
                return false;
            }
            // A click (no width) never makes or clears a range. On a lane it
            // toggles that thread's filter.
            if (drag.area == .overview or drag.area == .header) return false;
            const lane = drag.lane orelse return false;
            if (self.laneAt(y) != lane) return false;
            return self.toggleLane(lane, drag.additive);
        }
        if (drag.area == .labels or drag.area == .header) return false;
        const end = self.timeAt(drag.area, x);
        const from = @min(drag.anchor_ns, end);
        const to = @max(drag.anchor_ns, end);
        // Both ends clamped to the same edge leave no time to select.
        if (from == to) return false;
        const range = Range{ .from_ns = from, .to_ns = to };
        if (from == 0 and to == self.extent_ns and !self.live) {
            if (self.range == null) return false;
            self.range = null;
            return true;
        }
        if (self.range != null and self.range.?.from_ns == from and self.range.?.to_ns == to) return false;
        self.range = range;
        return true;
    }
    pub fn selectLane(self: *TimelineView, tid: ?u32) bool {
        if (self.tid == tid and self.tids.len == 0) return false;
        self.tid = tid;
        self.tids = .{};
        return true;
    }
    fn hasThreadSelection(self: *const TimelineView) bool {
        return self.tid != null or self.tids.len > 0;
    }
    fn selectedThread(self: *const TimelineView, tid: u32) bool {
        return self.tid == tid or self.tids.has(tid);
    }
    fn toggleLane(self: *TimelineView, lane: usize, additive: bool) bool {
        if (lane >= @min(self.lane_count, max_lanes)) return false;
        const tid = self.lane_tids[lane];
        if (additive) {
            var f = self.filter();
            f.toggleThread(tid) catch return false;
            self.tid = f.tid;
            self.tids = f.tids;
            return true;
        }
        return self.selectLane(if (self.tid == tid) null else tid);
    }
    /// Mouse wheel: over the overview zooms the lanes around the pointer;
    /// elsewhere it scrolls lanes. Returns true when consumed.
    pub fn wheel(self: *TimelineView, x: f32, y: f32, delta: i32) bool {
        if (!inside(self.geometry.bounds, x, y) or delta == 0) return false;
        if (self.areaAt(x, y) == .overview) {
            if (self.extent_ns <= min_span_ns) return true;
            const view = self.currentView();
            const span = view.to_ns - view.from_ns;
            const center = timeAtX(x, self.geometry.overview, 0, self.extent_ns);
            const scale: f64 = if (delta > 0) 1.25 else 0.8;
            const steps: f64 = @floatFromInt(@abs(delta));
            const wanted = boundedTime(@max(@as(f64, @floatFromInt(min_span_ns)), @as(f64, @floatFromInt(span)) * std.math.pow(f64, scale, steps)), self.extent_ns);
            if (wanted >= self.extent_ns) {
                self.view = null;
                return true;
            }
            const from = @min(center -| wanted / 2, self.extent_ns - wanted);
            self.view = .{ .from_ns = from, .to_ns = from + wanted };
            return true;
        }
        const last = self.lane_count -| @max(1, self.geometry.visible);
        const next = @as(i64, @intCast(self.first_lane)) + delta;
        self.first_lane = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(last))));
        return true;
    }

    /// Computes geometry for `bounds`. `draw` calls this; tests may call it alone.
    pub fn layout(self: *TimelineView, bounds: gpu.Rect, data: *const Data) void {
        _ = self.sync(data);
        self.live = data.live;
        for (data.lanes[0..@min(data.lanes.len, max_lanes)], 0..) |lane, i| self.lane_tids[i] = lane.tid;
        var g = Geometry{ .bounds = bounds };
        const inner_x = bounds.x + 10;
        const inner_w = @max(0, bounds.w - 20);
        const label_w: f32 = if (inner_w < 320) 0 else std.math.clamp(inner_w * 0.16, 96, 190);
        const plot_x = inner_x + label_w;
        const plot_w = @max(0, inner_w - label_w);
        g.reset = .{ .x = bounds.x + bounds.w - 90, .y = bounds.y + 5, .w = 80, .h = 24 };
        g.fit = if (bounds.w < 420) .{ .x = 0, .y = 0, .w = 0, .h = 0 } else .{ .x = bounds.x + bounds.w - 214, .y = bounds.y + 5, .w = 116, .h = 24 };
        const top = bounds.y + header_h;
        if (bounds.h >= header_h + overview_h + footer_h and plot_w >= 8) {
            g.overview = .{ .x = plot_x, .y = top, .w = plot_w, .h = overview_h - 6 };
            const lanes_y = top + overview_h + axis_h;
            const room = bounds.y + bounds.h - footer_h - lanes_y;
            const rows: usize = if (room >= lane_h) @intFromFloat(room / lane_h) else 0;
            g.visible = @min(@min(rows, max_visible_lanes), data.lanes.len);
            g.plot = .{ .x = plot_x, .y = lanes_y, .w = plot_w, .h = @as(f32, @floatFromInt(g.visible)) * lane_h };
            g.labels = .{ .x = inner_x, .y = lanes_y, .w = label_w, .h = g.plot.h };
            g.cols = std.math.clamp(@as(usize, @intFromFloat(plot_w)), 1, max_columns);
        }
        self.geometry = g;
        self.first_lane = @min(self.first_lane, data.lanes.len -| g.visible);
    }

    fn rebuild(self: *TimelineView, data: *const Data) void {
        const g = self.geometry;
        const view = self.currentView();
        const key = Key{ .capture_id = data.capture_id, .revision = data.revision, .extent_ns = data.extent_ns, .view = view, .cols = g.cols, .first_lane = self.first_lane, .visible = g.visible, .tid = self.tid, .tids = self.tids, .scheduling = data.scheduling };
        if (self.key != null and std.meta.eql(self.key.?, key)) return;
        self.key = key;
        self.rebuilds += 1;
        self.state_first = @splat(0);
        self.density_first = @splat(0);
        self.marker_first = @splat(0);
        self.bucket_count = 0;
        self.bucket_peak = 0;
        self.density_peak = 0;
        if (self.diagnostic != null or g.cols == 0) return;
        // Overview: every sample over the whole capture, and the selected thread.
        if (data.extent_ns > 0) {
            self.bucket_px = (g.cols + max_buckets - 1) / max_buckets;
            self.bucket_count = (g.cols + self.bucket_px - 1) / self.bucket_px;
            @memset(self.buckets[0..self.bucket_count], .{ 0, 0 });
            for (data.lanes) |lane| {
                const selected = self.selectedThread(lane.tid);
                for (lane.samples) |t| {
                    if (t >= data.extent_ns) break;
                    const b: usize = @intCast(@as(u128, t) * self.bucket_count / data.extent_ns);
                    self.buckets[b][0] += 1;
                    if (selected) self.buckets[b][1] += 1;
                }
            }
            for (self.buckets[0..self.bucket_count]) |b| self.bucket_peak = @max(self.bucket_peak, b[0]);
        }
        const span = view.to_ns - view.from_ns;
        if (span == 0 or g.visible == 0) return;
        const cols = g.cols;
        // Density uses one scale for all visible lanes so heights compare.
        for (data.lanes[self.first_lane..][0..g.visible]) |lane| {
            self.countColumns(lane, view, cols);
            for (self.counts[0..cols]) |n| self.density_peak = @max(self.density_peak, n);
        }
        var states: usize = 0;
        var densities: usize = 0;
        var markers: usize = 0;
        for (data.lanes[self.first_lane..][0..g.visible], 0..) |lane, row| {
            // Lanes with few runs leave their share to the lanes below.
            const left = g.visible - row;
            const state_cap = (max_state_runs - states) / left;
            const density_cap = (max_density_runs - densities) / left;
            const marker_cap = (max_markers - markers) / left;
            if (data.scheduling) {
                self.maskColumns(lane, view, cols);
                states += mergeRuns(self.masks[0..cols], self.state_runs[states..][0..state_cap], .mask);
                markers += self.edgeMarkers(lane, view, cols, self.markers[markers..][0..marker_cap]);
            }
            self.state_first[row + 1] = @intCast(states);
            self.marker_first[row + 1] = @intCast(markers);
            self.countColumns(lane, view, cols);
            // Quantize to drawable pixel heights; any sample shows. Without
            // scheduling evidence the samples get the whole lane.
            const levels: u64 = if (data.scheduling) 7 else 18;
            for (self.counts[0..cols], self.masks[0..cols]) |n, *level| level.* = if (n == 0) 0 else @intCast(@max(1, (@as(u64, n) * levels + self.density_peak - 1) / self.density_peak));
            densities += mergeRuns(self.masks[0..cols], self.density_runs[densities..][0..density_cap], .level);
            self.density_first[row + 1] = @intCast(densities);
        }
    }
    fn countColumns(self: *TimelineView, lane: Lane, view: Range, cols: usize) void {
        @memset(self.counts[0..cols], 0);
        const span = view.to_ns - view.from_ns;
        var i = lowerBound(lane.samples, view.from_ns);
        while (i < lane.samples.len and lane.samples[i] < view.to_ns) : (i += 1) {
            self.counts[@intCast(@as(u128, lane.samples[i] - view.from_ns) * cols / span)] += 1;
        }
    }
    fn maskColumns(self: *TimelineView, lane: Lane, view: Range, cols: usize) void {
        @memset(self.masks[0..cols], 0);
        const span = view.to_ns - view.from_ns;
        var i = firstEndingAfter(lane.intervals, view.from_ns);
        while (i < lane.intervals.len and lane.intervals[i].from_ns < view.to_ns) : (i += 1) {
            const interval = lane.intervals[i];
            if (interval.to_ns == interval.from_ns) continue; // no elapsed time
            const from = @max(interval.from_ns, view.from_ns) - view.from_ns;
            const to = @min(interval.to_ns, view.to_ns) - view.from_ns;
            const c0: usize = @intCast(@as(u128, from) * cols / span);
            var c1: usize = @intCast((@as(u128, to) * cols + span - 1) / span);
            c1 = @min(cols, @max(c1, c0 + 1));
            const bit: u8 = switch (interval.state) {
                .running => running_bit,
                .off_cpu => off_bit,
                .unknown => unknown_bit,
            };
            for (self.masks[@min(c0, cols - 1)..c1]) |*m| m.* |= bit;
        }
    }
    fn edgeMarkers(self: *TimelineView, lane: Lane, view: Range, cols: usize, out: []Marker) usize {
        _ = self;
        const span = view.to_ns - view.from_ns;
        var n: usize = 0;
        var last: ?Marker = null;
        var i = firstEndingAfter(lane.intervals, view.from_ns);
        // Include a span ending exactly at the view start: its end marker is visible.
        if (i > 0 and lane.intervals[i - 1].to_ns == view.from_ns) i -= 1;
        while (i < lane.intervals.len and lane.intervals[i].from_ns <= view.to_ns and n < out.len) : (i += 1) {
            const interval = lane.intervals[i];
            const edges = [_]struct { t: u64, on: bool, kind: @FieldType(Marker, "kind") }{
                .{ .t = interval.from_ns, .on = !interval.from_observed, .kind = .open_from },
                .{ .t = interval.to_ns, .on = !interval.to_observed, .kind = .open_to },
                .{ .t = interval.from_ns, .on = interval.preempted and interval.state == .off_cpu, .kind = .preempted },
            };
            for (edges) |edge| {
                if (!edge.on or edge.t < view.from_ns or edge.t > view.to_ns or n == out.len) continue;
                const x: u16 = @intCast(@min(cols - 1, @as(u128, edge.t - view.from_ns) * cols / span));
                // One marker of a kind per two pixel columns is enough to see.
                if (last != null and last.?.kind == edge.kind and x -| last.?.x < 2) continue;
                out[n] = .{ .x = x, .kind = edge.kind };
                last = out[n];
                n += 1;
            }
        }
        return n;
    }

    pub fn draw(self: *TimelineView, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, data: ?*const Data) !void {
        const saved_clip = r.clip;
        defer r.clip = saved_clip;
        r.clip = bounds;
        try style.box(r, bounds, theme.surface, theme.border, @splat(8));
        try r.textFit(font, bounds.x + 14, bounds.y + 9, 120, "TIMELINE", theme.text);
        const current = data orelse {
            self.geometry = .{ .bounds = bounds };
            try r.textFit(font, bounds.x + 14, bounds.y + 40, bounds.w - 28, "No capture. Sample density and thread lanes appear while capturing.", theme.weak);
            return;
        };
        self.layout(bounds, current);
        const g = self.geometry;
        try self.header(r, font, current);
        if (self.diagnostic) |reason| {
            try label(r, font, bounds.x + 14, bounds.y + header_h + 6, bounds.w - 28, theme.warm, "Timeline data rejected: {s}", .{reason});
            return;
        }
        if (g.cols == 0) return;
        self.rebuild(current);
        try self.drawOverview(r, font, current);
        try self.drawAxis(r, font);
        try self.drawLanes(r, font, current);
        try self.drawSelection(r, g.plot, self.currentView());
        try self.footer(r, font, current);
    }
    fn header(self: *TimelineView, r: *gpu.Renderer, font: *Font, data: *const Data) !void {
        const g = self.geometry;
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        var c: [32]u8 = undefined;
        var t: [24]u8 = undefined;
        const thread = if (self.tid) |tid| std.fmt.bufPrint(&t, "  /  TID {d}", .{tid}) catch "" else if (self.tids.len > 0) std.fmt.bufPrint(&t, "  /  {d} threads", .{self.tids.len}) catch "" else "  /  all threads";
        const text_w = (if (g.fit.w > 0) g.fit.x else g.reset.x) - g.bounds.x - 120;
        if (self.range) |range| {
            try label(r, font, g.bounds.x + 110, g.bounds.y + 9, text_w, theme.warm, "[{s}, {s})  {s}{s}", .{ duration(&a, range.from_ns), duration(&b, range.to_ns), duration(&c, range.to_ns - range.from_ns), thread });
        } else {
            try label(r, font, g.bounds.x + 110, g.bounds.y + 9, text_w, if (self.hasThreadSelection()) theme.warm else theme.weak, "#{d}  {s}{s}  /  {s}", .{ data.capture_id, data.state_label orelse (if (data.live) "live" else "complete"), thread, duration(&a, data.extent_ns) });
        }
        if (g.fit.w > 0) try pill(r, font, g.fit, "Fit range", if (self.range != null) theme.text else theme.weak);
        try pill(r, font, g.reset, "Reset", if (self.range != null or self.hasThreadSelection() or self.view != null) theme.good else theme.weak);
    }
    fn drawOverview(self: *TimelineView, r: *gpu.Renderer, font: *Font, data: *const Data) !void {
        const o = self.geometry.overview;
        try r.shape(o, style.fade(theme.header, 0.9), .{ .radii = @splat(4) });
        if (data.extent_ns == 0) {
            try r.textFit(font, o.x + 8, o.y + 8, o.w - 16, "Waiting for the first samples", theme.weak);
            return;
        }
        const col_w = o.w / @as(f32, @floatFromInt(self.bucket_count));
        const peak: f32 = @floatFromInt(@max(1, self.bucket_peak));
        for (self.buckets[0..self.bucket_count], 0..) |bucket, i| {
            if (bucket[0] == 0) continue;
            const x = o.x + @as(f32, @floatFromInt(i)) * col_w;
            const h = @max(2, @as(f32, @floatFromInt(bucket[0])) / peak * (o.h - 4));
            try r.rect(.{ .x = x, .y = o.y + o.h - h, .w = @max(1, col_w - 0.25), .h = h }, style.fade(theme.neutral, if (self.hasThreadSelection()) 0.35 else 0.8));
            if (bucket[1] > 0) {
                const s = @max(2, @as(f32, @floatFromInt(bucket[1])) / peak * (o.h - 4));
                try r.rect(.{ .x = x, .y = o.y + o.h - s, .w = @max(1, col_w - 0.25), .h = s }, theme.warm);
            }
        }
        try self.drawMarks(r, o, .{ .from_ns = 0, .to_ns = data.extent_ns }, data, null, max_drawn_marks);
        if (self.bucket_peak == 0) try r.textFit(font, o.x + 8, o.y + 8, o.w - 16, "No CPU samples yet. Empty time is not evidence of waiting.", theme.weak);
        // Selection over the whole capture, then the lanes' view window.
        try self.drawSelection(r, o, .{ .from_ns = 0, .to_ns = data.extent_ns });
        if (self.view) |view| {
            const x0 = xAt(o, 0, data.extent_ns, view.from_ns);
            const x1 = @max(x0 + 2, xAt(o, 0, data.extent_ns, view.to_ns));
            try r.shape(.{ .x = x0, .y = o.y - 2, .w = x1 - x0, .h = o.h + 4 }, style.fade(theme.text, 0.7), .{ .radii = @splat(3), .border = 1 });
        }
    }
    /// Marks over `rect`. A lane (`tid` set) shows capture-wide marks and its
    /// own; the overview (`tid` null) shows all.
    fn drawMarks(self: *TimelineView, r: *gpu.Renderer, rect: gpu.Rect, view: Range, data: *const Data, tid: ?u32, cap: usize) !void {
        _ = self;
        var drawn: usize = 0;
        var last_x: f32 = -1;
        var last_kind: ?MarkKind = null;
        for (data.marks) |mark| {
            if (drawn == cap) break;
            if (mark.to_ns < view.from_ns or mark.from_ns > view.to_ns) continue;
            if (tid != null and mark.tid != null and mark.tid.? != tid.?) continue;
            const x0 = xAt(rect, view.from_ns, view.to_ns - view.from_ns, @max(mark.from_ns, view.from_ns));
            const x1 = @max(x0 + 1.5, xAt(rect, view.from_ns, view.to_ns - view.from_ns, @min(mark.to_ns, view.to_ns)));
            if (last_kind == mark.kind and x1 - last_x < 1) continue;
            last_x = x1;
            last_kind = mark.kind;
            const color = switch (mark.kind) {
                .loss => style.fade(theme.breakpoint, 0.55),
                .debugger_stop => style.fade(theme.text, 0.10),
                .application => style.fade(theme.focus, 0.22),
                .syscall => style.fade(theme.warm, 0.24),
            };
            try r.rect(.{ .x = x0, .y = rect.y, .w = x1 - x0, .h = rect.h }, color);
            drawn += 1;
        }
    }
    fn drawAxis(self: *TimelineView, r: *gpu.Renderer, font: *Font) !void {
        const p = self.geometry.plot;
        const view = self.currentView();
        const span = view.to_ns - view.from_ns;
        const y = self.geometry.overview.y + overview_h - 2;
        if (span == 0) return;
        // A 1/2/5 step leaving at least 110 px between labels.
        const wanted = @as(f64, @floatFromInt(span)) * 110 / @max(1, p.w);
        var step: u64 = 1;
        while (@as(f64, @floatFromInt(step)) < wanted and step < std.math.maxInt(u64)) {
            const digit = step / std.math.pow(u64, 10, std.math.log10_int(step));
            step = if (digit == 1) step *| 2 else if (digit == 2) step / 2 *| 5 else step *| 2;
        }
        // The first tick and the step after the last tick may exceed u64.
        var tick = (@as(u128, view.from_ns) + step - 1) / step * step;
        var buffer: [32]u8 = undefined;
        while (tick <= view.to_ns) : (tick += step) {
            const t: u64 = @intCast(tick);
            const x = xAt(p, view.from_ns, span, t);
            try r.rect(.{ .x = x, .y = y + 14, .w = 1, .h = 6 + p.h }, style.fade(theme.border, 0.8));
            if (x + 4 < p.x + p.w - 40) try r.textFit(font, x + 4, y, 100, axisLabel(&buffer, t, step), theme.weak);
        }
    }
    fn drawLanes(self: *TimelineView, r: *gpu.Renderer, font: *Font, data: *const Data) !void {
        const g = self.geometry;
        const view = self.currentView();
        const span = view.to_ns - view.from_ns;
        if (g.visible == 0) {
            if (data.lanes.len > 0) try r.textFit(font, g.overview.x, g.overview.y + overview_h + axis_h, g.overview.w, "Enlarge the window to show thread lanes", theme.weak);
            return;
        }
        const cols: f32 = @floatFromInt(g.cols);
        const col_w = g.plot.w / cols;
        var interval_labels: usize = 0;
        for (0..g.visible) |row| {
            const index = self.first_lane + row;
            const lane = data.lanes[index];
            const y = g.plot.y + @as(f32, @floatFromInt(row)) * lane_h;
            const lane_rect = gpu.Rect{ .x = g.labels.x, .y = y, .w = g.labels.w + g.plot.w, .h = lane_h };
            if (index % 2 == 1) try r.rect(lane_rect, theme.stripe);
            const color = style.threadColor(if (lane.debugger_id != 0) lane.debugger_id else index + 1);
            const selected = self.selectedThread(lane.tid);
            if (selected) try style.focus(r, lane_rect, 4, 1);
            if (g.labels.w > 0) {
                try style.disc(r, g.labels.x + 8, y + lane_h / 2, 4, color);
                try label(r, font, g.labels.x + 18, y + 3, g.labels.w - 24, if (selected) theme.text else theme.weak, "{d} {s}", .{ lane.tid, lane.label });
            }
            r.clip = g.plot;
            // Unknown time is the empty baseline.
            try r.rect(.{ .x = g.plot.x, .y = y + 7, .w = g.plot.w, .h = 1 }, style.fade(theme.weak, 0.25));
            for (self.state_runs[self.state_first[row]..self.state_first[row + 1]]) |run| {
                const x = g.plot.x + @as(f32, @floatFromInt(run.x0)) * col_w;
                const w = @as(f32, @floatFromInt(run.x1 - run.x0)) * col_w;
                const mixed = @popCount(run.value) > 1;
                if (run.value & running_bit != 0) {
                    try r.rect(.{ .x = x, .y = y + 2, .w = w, .h = 11 }, style.fade(color, if (mixed) 0.55 else 0.9));
                } else if (run.value & off_bit != 0) {
                    try r.rect(.{ .x = x, .y = y + 4, .w = w, .h = 7 }, if (mixed) style.fade(theme.border, 0.8) else style.mix(theme.border, theme.weak, 0.35));
                    if (!mixed and w >= 96 and interval_labels < max_interval_labels) {
                        const mid = view.from_ns + boundedTime(@as(f64, @floatFromInt(run.x0 + run.x1)) / 2 / cols * @as(f64, @floatFromInt(span)), span);
                        if (intervalAt(lane.intervals, mid)) |interval| {
                            var buffer: [32]u8 = undefined;
                            const open = !interval.from_observed or !interval.to_observed;
                            try label(r, font, x + 6, y - 1, w - 12, theme.text, "off CPU {s}{s}", .{ if (open) "\u{2265}" else "", compact(&buffer, interval.to_ns - interval.from_ns) });
                            interval_labels += 1;
                        }
                    }
                }
            }
            for (self.density_runs[self.density_first[row]..self.density_first[row + 1]]) |run| {
                if (run.value == 0) continue;
                const h: f32 = @floatFromInt(run.value);
                try r.rect(.{ .x = g.plot.x + @as(f32, @floatFromInt(run.x0)) * col_w, .y = y + lane_h - 2 - h, .w = @max(1, @as(f32, @floatFromInt(run.x1 - run.x0)) * col_w), .h = h }, style.fade(theme.neutral, 0.85));
            }
            for (self.markers[self.marker_first[row]..self.marker_first[row + 1]]) |marker| {
                const x = g.plot.x + @as(f32, @floatFromInt(marker.x)) * col_w;
                switch (marker.kind) {
                    // A broken edge: the transition at this end was not observed.
                    .open_from, .open_to => {
                        try r.rect(.{ .x = x - 1, .y = y + 1, .w = 2, .h = 4 }, theme.warm);
                        try r.rect(.{ .x = x - 1, .y = y + 10, .w = 2, .h = 4 }, theme.warm);
                    },
                    .preempted => try r.rect(.{ .x = x - 1.5, .y = y, .w = 3, .h = 3 }, theme.text),
                }
            }
            try self.drawMarks(r, .{ .x = g.plot.x, .y = y, .w = g.plot.w, .h = lane_h }, view, data, lane.tid, max_lane_marks);
            r.clip = g.bounds;
        }
        if (data.lanes.len > g.visible) {
            // Scroll position for virtualized lanes.
            const track = gpu.Rect{ .x = g.bounds.x + g.bounds.w - 6, .y = g.plot.y, .w = 3, .h = g.plot.h };
            const total: f32 = @floatFromInt(data.lanes.len);
            try r.rect(track, style.fade(theme.border, 0.6));
            try r.shape(.{ .x = track.x, .y = track.y + @as(f32, @floatFromInt(self.first_lane)) / total * track.h, .w = 3, .h = @max(8, @as(f32, @floatFromInt(g.visible)) / total * track.h) }, theme.weak, .{ .radii = @splat(1.5) });
        }
    }
    fn drawSelection(self: *TimelineView, r: *gpu.Renderer, rect: gpu.Rect, view: Range) !void {
        if (rect.w <= 0 or rect.h <= 0) return;
        const span = view.to_ns - view.from_ns;
        if (span == 0) return;
        var range = self.range;
        if (self.drag) |drag| if (self.pointer) |p| if ((drag.area == .overview or drag.area == .plot) and @abs(p[0] - drag.x) >= drag_threshold) {
            const end = self.timeAt(drag.area, p[0]);
            range = .{ .from_ns = @min(drag.anchor_ns, end), .to_ns = @max(drag.anchor_ns, end) };
        };
        const selected = range orelse return;
        if (selected.to_ns <= view.from_ns or selected.from_ns >= view.to_ns) return;
        const x0 = xAt(rect, view.from_ns, span, @max(selected.from_ns, view.from_ns));
        const x1 = @max(x0 + 1, xAt(rect, view.from_ns, span, @min(selected.to_ns, view.to_ns)));
        try r.rect(.{ .x = x0, .y = rect.y, .w = x1 - x0, .h = rect.h }, style.fade(theme.focus, 0.13));
        if (selected.from_ns >= view.from_ns) try r.rect(.{ .x = x0, .y = rect.y, .w = 1, .h = rect.h }, style.fade(theme.focus, 0.9));
        if (selected.to_ns <= view.to_ns) try r.rect(.{ .x = x1 - 1, .y = rect.y, .w = 1, .h = rect.h }, style.fade(theme.focus, 0.9));
    }
    fn footer(self: *TimelineView, r: *gpu.Renderer, font: *Font, data: *const Data) !void {
        const g = self.geometry;
        const y = g.bounds.y + g.bounds.h - footer_h + 2;
        const w = g.bounds.w - 28;
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        if (data.debugger_marks_dropped > 0) return label(r, font, g.bounds.x + 14, y, w, theme.warm, "Debugger-stop overlays incomplete: {d} spans/markers omitted; inspect MCP control history.", .{data.debugger_marks_dropped});
        if (self.pointer) |p| if (self.areaAt(p[0], p[1])) |area| if (area != .labels) {
            const view = if (area == .overview) Range{ .from_ns = 0, .to_ns = data.extent_ns } else self.currentView();
            const rect = if (area == .overview) g.overview else g.plot;
            const t = self.timeAt(area, p[0]);
            // The one pixel column under the pointer.
            const per_px = (view.to_ns - view.from_ns) / @max(1, @as(u64, @intFromFloat(rect.w)));
            if (area == .plot) if (self.laneAt(p[1])) |index| {
                const lane = data.lanes[index];
                const n = lowerBound(lane.samples, t +| @max(1, per_px)) - lowerBound(lane.samples, t);
                const state = if (!data.scheduling) "no scheduling evidence" else if (intervalAt(lane.intervals, t)) |i| stateName(i) else "unknown (no record)";
                return label(r, font, g.bounds.x + 14, y, w, theme.text, "+{s}  TID {d}  {s}  /  samples: {d} in {s}{s}", .{ duration(&a, t), lane.tid, state, n, compact(&b, @max(1, per_px)), markText(data.marks, t, lane.tid) });
            };
            return label(r, font, g.bounds.x + 14, y, w, theme.text, "+{s}{s}  /  wheel here zooms lanes; drag selects a range", .{ duration(&a, t), markText(data.marks, t, null) });
        };
        if (data.lost_samples > 0) return label(r, font, g.bounds.x + 14, y, w, theme.warm, "{d} perf records/samples lost at unknown times: sparse regions may be loss", .{data.lost_samples});
        if (data.syscall_count > 0) return label(r, font, g.bounds.x + 14, y, w, theme.weak, "{d} syscall spans: amber overlays (bounded drawing); hover or X for detail. Elapsed includes off CPU and debugger pauses.", .{data.syscall_count});
        if (data.application_count > 0) return label(r, font, g.bounds.x + 14, y, w, theme.weak, "{d} imported application intervals: blue overlays, hover for label; zoom to inspect crowded ranges. Timing is caller-supplied.", .{data.application_count});
        if (!data.scheduling) return r.textFit(font, g.bounds.x + 14, y, w, "Bars are CPU samples. No scheduling evidence: time without samples is unknown, not waiting.", theme.weak);
        try r.textFit(font, g.bounds.x + 14, y, w, "Running / off CPU are elapsed time; bars below are CPU samples. Blank is unknown. Orange ticks: edge not observed.", theme.weak);
    }
};

fn stateName(interval: Interval) []const u8 {
    if (interval.detail.len > 0) return interval.detail;
    return switch (interval.state) {
        .running => "running",
        .off_cpu => if (interval.preempted) "off CPU after preemption" else "off CPU",
        .unknown => "unknown",
    };
}
/// Readout suffix for marks covering `t` (capture-wide, or for `tid` when given).
fn markText(marks: []const Mark, t: u64, tid: ?u32) []const u8 {
    var stop = false;
    var loss = false;
    var application: ?[]const u8 = null;
    for (marks) |mark| {
        if (t < mark.from_ns or t > mark.to_ns or (t == mark.to_ns and mark.to_ns > mark.from_ns)) continue;
        if (tid != null and mark.tid != null and mark.tid.? != tid.?) continue;
        switch (mark.kind) {
            .loss => loss = true,
            .debugger_stop => stop = true,
            .application, .syscall => if (application == null) {
                application = mark.label;
            },
        }
    }
    return if (stop and loss) "  /  debugger stop, records lost" else if (stop) "  /  debugger stop" else if (loss) "  /  records lost" else application orelse "";
}
fn inside(rect: gpu.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}
/// Screen x of `t`. The origin is subtracted in integers before conversion,
/// so large capture offsets keep nanosecond-level relative precision.
fn xAt(rect: gpu.Rect, from: u64, span: u64, t: u64) f32 {
    if (span == 0) return rect.x;
    const delta = @min(t -| from, span);
    return rect.x + @as(f32, @floatCast(@as(f64, @floatFromInt(delta)) / @as(f64, @floatFromInt(span)) * rect.w));
}
/// Time at screen x. Positions at or beyond an edge give exactly that edge.
fn timeAtX(x: f32, rect: gpu.Rect, from: u64, span: u64) u64 {
    if (x <= rect.x or rect.w <= 0) return from;
    if (x >= rect.x + rect.w) return from + span;
    const fraction = @as(f64, x - rect.x) / @as(f64, rect.w);
    return from + boundedTime(fraction * @as(f64, @floatFromInt(span)), span);
}
/// Clamp before conversion: f64 rounds maxInt(u64) up to 2^64.
fn boundedTime(value: f64, limit: u64) u64 {
    if (!(value > 0)) return 0;
    if (value >= @as(f64, @floatFromInt(limit))) return limit;
    return @min(limit, @as(u64, @intFromFloat(value)));
}
fn lowerBound(items: []const u64, t: u64) usize {
    var lo: usize = 0;
    var hi = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] < t) lo = mid + 1 else hi = mid;
    }
    return lo;
}
fn upperBound(items: []const u64, t: u64) usize {
    var lo: usize = 0;
    var hi = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid] <= t) lo = mid + 1 else hi = mid;
    }
    return lo;
}
fn firstEndingAfter(intervals: []const Interval, t: u64) usize {
    var lo: usize = 0;
    var hi = intervals.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (intervals[mid].to_ns <= t) lo = mid + 1 else hi = mid;
    }
    return lo;
}
/// The non-empty interval covering `t`, if any.
fn intervalAt(intervals: []const Interval, t: u64) ?Interval {
    var i = firstEndingAfter(intervals, t);
    while (i < intervals.len and intervals[i].from_ns == intervals[i].to_ns) i += 1;
    if (i < intervals.len and intervals[i].from_ns <= t) return intervals[i];
    return null;
}
/// Merges equal adjacent columns into runs, skipping zero. When the runs do not
/// fit `out`, columns are combined in pairs (mask: union; level: maximum) until
/// they do, so the geometry stays bounded even for pathological data.
fn mergeRuns(columns: []u8, out: []Run, comptime combine: enum { mask, level }) usize {
    var width: usize = 1;
    while (true) {
        var n: usize = 0;
        var x: usize = 0;
        var fits = true;
        while (x < columns.len) {
            var value: u8 = 0;
            for (columns[x..@min(columns.len, x + width)]) |v| value = if (combine == .mask) value | v else @max(value, v);
            const end = @min(columns.len, x + width);
            if (value != 0) {
                if (n > 0 and out[n - 1].value == value and out[n - 1].x1 == x) {
                    out[n - 1].x1 = @intCast(end);
                } else if (n == out.len) {
                    fits = false;
                    break;
                } else {
                    out[n] = .{ .x0 = @intCast(x), .x1 = @intCast(end), .value = value };
                    n += 1;
                }
            }
            x = end;
        }
        if (fits) return n;
        if (out.len == 0) return 0;
        // The runs filled `out` within the first x columns: widen by at least
        // the remaining factor so one or two more passes suffice.
        width *= std.math.ceilPowerOfTwoAssert(usize, @max(2, (columns.len + x - 1) / @max(1, x)));
    }
}
/// A nanosecond count at a useful unit with three decimals, for exact readouts.
pub fn duration(buffer: []u8, ns: u64) []const u8 {
    const unit = Unit.of(ns);
    if (unit.scale == 1) return std.fmt.bufPrint(buffer, "{d} ns", .{ns}) catch "";
    return std.fmt.bufPrint(buffer, "{d:.3} {s}", .{ @as(f64, @floatFromInt(ns)) / unit.scale, unit.name }) catch "";
}
/// Three significant figures, for labels where space is short.
pub fn compact(buffer: []u8, ns: u64) []const u8 {
    const unit = Unit.of(ns);
    const v = @as(f64, @floatFromInt(ns)) / unit.scale;
    return (if (v >= 100 or unit.scale == 1)
        std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ v, unit.name })
    else if (v >= 10)
        std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ v, unit.name })
    else
        std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ v, unit.name })) catch "";
}
const Unit = struct {
    scale: f64,
    name: []const u8,
    fn of(ns: u64) Unit {
        return if (ns >= 1_000_000_000) .{ .scale = 1e9, .name = "s" } else if (ns >= 1_000_000) .{ .scale = 1e6, .name = "ms" } else if (ns >= 1_000) .{ .scale = 1e3, .name = "\u{b5}s" } else .{ .scale = 1, .name = "ns" };
    }
};
/// Tick labels in the step's unit, so every label on the axis shares one unit.
fn axisLabel(buffer: []u8, t: u64, step: u64) []const u8 {
    if (t == 0) return "0";
    const unit = Unit.of(step);
    return std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ @as(f64, @floatFromInt(t)) / unit.scale, unit.name }) catch "";
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    if (width <= 0) return;
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}
/// A mouse-only header button in the toolbar-button style, without a key chip.
fn pill(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, text: []const u8, color: gpu.Color) !void {
    try style.box(r, rect, style.mix(theme.header, theme.highlight, 0.035), style.mix(theme.border, color, 0.3), @splat(rect.h / 2));
    try r.textFit(font, rect.x + 12, rect.y + 3, rect.w - 20, text, color);
}

const testing = std.testing;
fn testView() !*TimelineView {
    const view = try testing.allocator.create(TimelineView);
    view.* = .{};
    return view;
}
fn monotonic() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
const test_bounds = gpu.Rect{ .x = 0, .y = 0, .w = 1210, .h = 400 };
// Labels take 190 px, so the plot spans x = 200..1200 (1000 px).
fn dragTo(view: *TimelineView, x0: f32, y0: f32, x1: f32, y1: f32) bool {
    _ = view.press(x0, y0);
    _ = view.motion(x1, y1);
    return view.release(x1, y1);
}

test "drag selects a sorted half-open range and clamps at edges" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const lanes = [_]Lane{ .{ .tid = 11 }, .{ .tid = 12 } };
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1_000_000, .lanes = &lanes };
    view.layout(test_bounds, &data);
    try testing.expectEqual(@as(f32, 200), view.geometry.plot.x);
    try testing.expectEqual(@as(f32, 1000), view.geometry.plot.w);
    const y = view.geometry.plot.y + 5;
    try testing.expect(dragTo(view, 450, y, 300, y));
    try testing.expectEqual(Range{ .from_ns = 100_000, .to_ns = 250_000 }, view.range.?);
    // Beyond either edge gives exactly the capture's ends.
    try testing.expect(dragTo(view, 700, y, 150, y));
    try testing.expectEqual(Range{ .from_ns = 0, .to_ns = 500_000 }, view.range.?);
    try testing.expect(dragTo(view, 700, y, 1300, y));
    try testing.expectEqual(Range{ .from_ns = 500_000, .to_ns = 1_000_000 }, view.range.?);
    // Both ends clamped to one edge select no time and change nothing.
    try testing.expect(!dragTo(view, 200, y, 100, y));
    try testing.expectEqual(@as(u64, 1_000_000), view.range.?.to_ns);
    // A press in the label column never starts a range.
    try testing.expect(!dragTo(view, 150, y, 700, y));
    try testing.expectEqual(@as(u64, 500_000), view.range.?.from_ns);
    // The whole completed capture is the same as no range.
    try testing.expect(dragTo(view, 200, y, 1300, y));
    try testing.expect(view.range == null);
    const s = view.selection();
    try testing.expectEqual(@as(?u64, null), s.to_ns);
    try testing.expectEqual(@as(u64, 0), s.from_ns);
    try testing.expectEqual(model.Filter{}, view.filter());
    try testing.expect(dragTo(view, 450, y, 300, y));
    try testing.expectEqual(model.Filter{ .from_ns = 100_000, .to_ns = 250_000 }, view.filter());
}

test "a click selects a lane's thread and never a range" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const lanes = [_]Lane{ .{ .tid = 11 }, .{ .tid = 12 } };
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1_000_000, .lanes = &lanes };
    view.layout(test_bounds, &data);
    const row2 = view.geometry.plot.y + lane_h + 5;
    try testing.expect(dragTo(view, 500, row2, 501, row2));
    try testing.expectEqual(@as(?u32, 12), view.tid);
    try testing.expect(view.range == null);
    // The label column selects too; clicking the selected thread clears it.
    try testing.expect(dragTo(view, 50, row2, 50, row2));
    try testing.expectEqual(@as(?u32, null), view.tid);
    // Press on one lane, release on another: no selection.
    try testing.expect(!dragTo(view, 500, row2, 500, row2 - lane_h));
    // A click on the overview does nothing.
    try testing.expect(!dragTo(view, 500, view.geometry.overview.y + 5, 500, view.geometry.overview.y + 5));
    // Below the last lane there is no lane.
    try testing.expect(!dragTo(view, 500, view.geometry.plot.y + 3 * lane_h, 500, view.geometry.plot.y + 3 * lane_h));
    try testing.expect(view.tid == null and view.range == null);
}

test "adjacent ranges share their boundary exactly" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const samples = [_]u64{ 0, 1, 2, 333_333, 333_334, 999_999 };
    const lanes = [_]Lane{.{ .tid = 5, .samples = &samples }};
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1_000_000, .lanes = &lanes };
    view.layout(test_bounds, &data);
    const y = view.geometry.plot.y + 5;
    var total: usize = 0;
    var previous: u64 = 0;
    // Drags meeting at the same pixel meet at the same nanosecond.
    const edges = [_]f32{ 200, 533.3, 866.7, 1205 };
    for (edges[0 .. edges.len - 1], edges[1..]) |x0, x1| {
        _ = dragTo(view, x0, y, x1, y);
        const range = view.range orelse Range{ .from_ns = 0, .to_ns = 1_000_000 };
        try testing.expectEqual(previous, range.from_ns);
        total += lowerBound(&samples, range.to_ns) - lowerBound(&samples, range.from_ns);
        previous = range.to_ns;
    }
    try testing.expectEqual(@as(u64, 1_000_000), previous);
    try testing.expectEqual(samples.len, total);
}

test "capture growth keeps selection; shorter extent clips; replacement clears" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    var lanes = [_]Lane{ .{ .tid = 11 }, .{ .tid = 12 } };
    var data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1_000_000, .live = true, .lanes = &lanes };
    view.layout(test_bounds, &data);
    const y = view.geometry.plot.y + 5;
    try testing.expect(dragTo(view, 300, y, 600, y));
    try testing.expect(dragTo(view, 500, y + lane_h, 500, y + lane_h));
    const chosen = view.range.?;
    data.revision = 2;
    data.extent_ns = 5_000_000;
    try testing.expect(!view.sync(&data));
    try testing.expectEqual(chosen, view.range.?);
    try testing.expectEqual(@as(?u32, 12), view.tid);
    // A revision that removes a thread clears only the thread filter.
    data.revision = 3;
    data.lanes = lanes[0..1];
    try testing.expect(view.sync(&data));
    try testing.expectEqual(@as(?u32, null), view.tid);
    try testing.expectEqual(chosen, view.range.?);
    // A shorter extent clips; one before the range start drops it.
    data.revision = 4;
    data.extent_ns = 300_000;
    try testing.expect(view.sync(&data));
    try testing.expectEqual(Range{ .from_ns = 100_000, .to_ns = 300_000 }, view.range.?);
    data.revision = 5;
    data.extent_ns = 50_000;
    try testing.expect(view.sync(&data));
    try testing.expect(view.range == null);
    // A replaced capture starts with nothing selected, even at equal revision.
    try testing.expect(dragTo(view, 300, y, 600, y));
    data.capture_id = 2;
    try testing.expect(view.sync(&data));
    try testing.expect(view.range == null and view.tid == null and view.view == null);
    try testing.expectEqual(@as(u64, 2), view.selection().capture_id);
    // A drag in progress does not survive replacement.
    _ = view.press(300, y);
    data.capture_id = 3;
    _ = view.sync(&data);
    try testing.expect(!view.release(600, y));
}

test "zoom on a long capture keeps nanosecond precision" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const lanes = [_]Lane{.{ .tid = 1 }};
    // Ten hours. f32 nanoseconds would be ~4 seconds coarse here.
    const extent: u64 = 36_000_000_000_000;
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = extent, .lanes = &lanes };
    view.layout(test_bounds, &data);
    view.view = .{ .from_ns = extent - 1000, .to_ns = extent };
    const y = view.geometry.plot.y + 5;
    try testing.expect(dragTo(view, 400, y, 700, y));
    try testing.expectEqual(Range{ .from_ns = extent - 800, .to_ns = extent - 500 }, view.range.?);
    try testing.expectApproxEqAbs(@as(f32, 400), xAt(view.geometry.plot, extent - 1000, 1000, extent - 800), 0.01);
    // Wheel over the overview zooms out around the pointer and returns to the whole capture.
    var steps: usize = 0;
    while (view.view != null) : (steps += 1) _ = view.wheel(1000, view.geometry.overview.y + 5, 10);
    try testing.expect(steps > 0 and steps < 20);
    _ = view.wheel(700, view.geometry.overview.y + 5, -3);
    const zoomed = view.view.?;
    try testing.expect(zoomed.to_ns <= extent and zoomed.to_ns - zoomed.from_ns < extent);
    view.fitRange();
    try testing.expectEqual(view.range.?, view.view.?);
}

test "imported u64 time bounds survive overview zoom and edge selection" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const extent = std.math.maxInt(u64);
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = extent, .lanes = &.{} };
    view.layout(test_bounds, &data);
    try testing.expectEqual(extent, boundedTime(@as(f64, @floatFromInt(extent)), extent));
    _ = view.wheel(700, view.geometry.overview.y + 5, 10);
    try testing.expect(view.view == null);
    _ = view.wheel(700, view.geometry.overview.y + 5, -3);
    try testing.expect(view.view.?.to_ns <= extent);
    try testing.expectEqual(extent - 500, timeAtX(50, .{ .x = 0, .y = 0, .w = 100, .h = 10 }, extent - 1000, 1000));
    try testing.expectEqual(extent, timeAtX(100, .{ .x = 0, .y = 0, .w = 100, .h = 10 }, 0, extent));
}

test "validation rejects broken contracts and accepts equal timestamps" {
    const ok = [_]Interval{ .{ .from_ns = 0, .to_ns = 5, .state = .running }, .{ .from_ns = 5, .to_ns = 5, .state = .off_cpu }, .{ .from_ns = 5, .to_ns = 9, .state = .off_cpu } };
    const overlap = [_]Interval{ .{ .from_ns = 0, .to_ns = 5, .state = .running }, .{ .from_ns = 4, .to_ns = 9, .state = .off_cpu } };
    const equal = [_]u64{ 3, 3, 3 };
    const unsorted = [_]u64{ 4, 3 };
    var lanes = [_]Lane{ .{ .tid = 1, .samples = &equal, .intervals = &ok }, .{ .tid = 2 } };
    var data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 10, .lanes = &lanes };
    try testing.expectEqual(@as(?[]const u8, null), data.validate());
    lanes[1].intervals = &overlap;
    try testing.expect(data.validate() != null);
    lanes[1].intervals = &.{};
    lanes[1].samples = &unsorted;
    try testing.expect(data.validate() != null);
    lanes[1].samples = &.{};
    lanes[1].tid = 1;
    try testing.expect(data.validate() != null);
    lanes[1].tid = 0;
    try testing.expect(data.validate() != null);
    lanes[1].tid = 2;
    const backwards = [_]Mark{.{ .from_ns = 5, .to_ns = 4, .kind = .loss }};
    data.marks = &backwards;
    try testing.expect(data.validate() != null);
}

test "lane columns clip to the view and mark unobserved edges" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const intervals = [_]Interval{
        .{ .from_ns = 0, .to_ns = 100, .state = .running, .from_observed = false },
        .{ .from_ns = 100, .to_ns = 400, .state = .off_cpu },
        .{ .from_ns = 400, .to_ns = 400, .state = .running }, // equal timestamps: no elapsed time
        .{ .from_ns = 400, .to_ns = 450, .state = .running },
        .{ .from_ns = 450, .to_ns = 450, .state = .off_cpu, .preempted = true },
        // 450..600 has no evidence: unknown
        .{ .from_ns = 600, .to_ns = 1000, .state = .running, .to_observed = false },
    };
    const samples = [_]u64{ 10, 20, 420, 420, 700 };
    const lanes = [_]Lane{.{ .tid = 7, .samples = &samples, .intervals = &intervals }};
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1000, .scheduling = true, .lanes = &lanes };
    view.layout(test_bounds, &data);
    // Zoom to [50, 650): the first and last spans are clipped.
    view.view = .{ .from_ns = 50, .to_ns = 650 };
    view.rebuild(&data);
    const runs = view.state_runs[view.state_first[0]..view.state_first[1]];
    // 600 ns over 1000 px: 5/3 px per ns.
    const expected = [_]Run{
        .{ .x0 = 0, .x1 = 83, .value = running_bit },
        .{ .x0 = 83, .x1 = 84, .value = running_bit | off_bit },
        .{ .x0 = 84, .x1 = 583, .value = off_bit },
        .{ .x0 = 583, .x1 = 584, .value = running_bit | off_bit },
        .{ .x0 = 584, .x1 = 667, .value = running_bit },
        .{ .x0 = 916, .x1 = 1000, .value = running_bit },
    };
    try testing.expectEqualSlices(Run, &expected, runs);
    const markers = view.markers[view.marker_first[0]..view.marker_first[1]];
    // The open start at 0 and open end at 1000 are outside the view; the
    // preemption at 450 is inside, even on an empty span.
    try testing.expectEqual(@as(usize, 1), markers.len);
    try testing.expectEqual(@as(u16, 666), markers[0].x);
    // Density: two samples at one instant are visible, in one column.
    var n: usize = 0;
    for (view.density_runs[view.density_first[0]..view.density_first[1]]) |run| n += run.x1 - run.x0;
    try testing.expectEqual(@as(usize, 1), n);
    const at = intervalAt(&intervals, 400).?;
    try testing.expectEqual(@as(u64, 450), at.to_ns);
    try testing.expect(intervalAt(&intervals, 500) == null);
    // Unzoomed: the open start is visible at x = 0.
    view.view = null;
    view.rebuild(&data);
    try testing.expectEqual(@as(u16, 0), view.markers[view.marker_first[0]].x);
}

test "geometry stays within budget for 1024 pathological lanes" {
    const a = testing.allocator;
    const view = try testView();
    defer a.destroy(view);
    const per_lane = 4000;
    const intervals = try a.alloc(Interval, per_lane);
    defer a.free(intervals);
    const samples = try a.alloc(u64, 16);
    defer a.free(samples);
    // Alternating states every 2.5 columns with open edges and preemption.
    for (intervals, 0..) |*interval, i| interval.* = .{ .from_ns = i * 250, .to_ns = i * 250 + 250, .state = if (i % 2 == 0) .running else .off_cpu, .preempted = i % 2 == 1, .from_observed = i % 3 != 0 };
    for (samples, 0..) |*s, i| s.* = i * 62_500;
    const lanes = try a.alloc(Lane, max_lanes);
    defer a.free(lanes);
    for (lanes, 0..) |*lane, i| lane.* = .{ .tid = @intCast(i + 1), .label = "worker", .samples = samples, .intervals = intervals };
    const marks = [_]Mark{ .{ .from_ns = 0, .to_ns = 100_000, .kind = .debugger_stop }, .{ .from_ns = 500_000, .to_ns = 500_000, .kind = .loss } };
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = per_lane * 250, .scheduling = true, .lanes = lanes, .marks = &marks };
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.init("/usr/share/fonts/TTF/DejaVuSansMono.ttf");
    defer font.deinit();
    const vertex_bytes = 8 * 1024 * 1024;
    const buffer = try a.alignedAlloc(u8, .@"16", vertex_bytes);
    defer a.free(buffer);
    var r = gpu.Renderer{};
    r.mapped = buffer.ptr;
    const bounds = gpu.Rect{ .x = 0, .y = 0, .w = 3840, .h = 2160 };
    r.clip = bounds;
    view.first_lane = 300;
    try view.draw(&r, font, bounds, &data);
    try testing.expectEqual(@as(usize, max_visible_lanes), view.geometry.visible);
    try testing.expect(view.state_first[max_visible_lanes] <= max_state_runs);
    try testing.expect(view.density_first[max_visible_lanes] <= max_density_runs);
    try testing.expect(view.marker_first[max_visible_lanes] <= max_markers);
    // Timed: a cache rebuild at this budget, then draws reusing the cache.
    var started = monotonic();
    view.key = null;
    view.rebuild(&data);
    const rebuild_ns = monotonic() - started;
    var draw_ns: u64 = std.math.maxInt(u64);
    var quads: usize = 0;
    for (0..20) |i| {
        r.vertices = 0;
        // Pointer motion alone reuses the cache.
        _ = view.motion(1000 + @as(f32, @floatFromInt(i)), 500);
        started = monotonic();
        try view.draw(&r, font, bounds, &data);
        draw_ns = @min(draw_ns, monotonic() - started);
        quads = r.vertices / 6;
    }
    try testing.expectEqual(@as(u64, 2), view.rebuilds);
    @import("../m68k_log.zig").print("\ntimeline budget: 64 of 1024 lanes, 4,000 intervals/lane, 3840x2160: rebuild {d} us, draw {d} us, {d} quads ({d} KiB vertices)\n", .{ rebuild_ns / 1000, draw_ns / 1000, quads, quads * 6 * 60 / 1024 });
    try testing.expect(quads < 12_000);
}

test "narrow and empty layouts draw without lanes or failures" {
    const a = testing.allocator;
    const view = try testView();
    defer a.destroy(view);
    const font = try a.create(Font);
    defer a.destroy(font);
    font.* = .{};
    try font.init("/usr/share/fonts/TTF/DejaVuSansMono.ttf");
    defer font.deinit();
    const buffer = try a.alignedAlloc(u8, .@"16", 8 * 1024 * 1024);
    defer a.free(buffer);
    var r = gpu.Renderer{};
    r.mapped = buffer.ptr;
    const lanes = [_]Lane{.{ .tid = 1 }};
    const empty = Data{ .capture_id = 1, .revision = 1, .extent_ns = 0, .live = true, .lanes = &lanes };
    for ([_]gpu.Rect{ .{ .x = 0, .y = 0, .w = 200, .h = 60 }, .{ .x = 0, .y = 0, .w = 330, .h = 130 }, .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .{ .x = 10, .y = 10, .w = 900, .h = 300 } }) |bounds| {
        r.clip = bounds;
        try view.draw(&r, font, bounds, &empty);
        try view.draw(&r, font, bounds, null);
        // Input on an empty capture is harmless.
        _ = dragTo(view, bounds.x + bounds.w / 2, bounds.y + bounds.h - 30, bounds.x + bounds.w, bounds.y + bounds.h - 30);
        _ = view.wheel(bounds.x + bounds.w / 2, bounds.y + 50, 3);
    }
    try testing.expect(view.range == null);
    const no_lanes = Data{ .capture_id = 2, .revision = 1, .extent_ns = 100, .lanes = &.{} };
    try view.draw(&r, font, .{ .x = 0, .y = 0, .w = 900, .h = 300 }, &no_lanes);
    _ = view.wheel(400, 200, 3);
    try testing.expectEqual(@as(usize, 0), view.first_lane);
    // Imported timestamps are full u64 values, including adversarial extents.
    const extreme = Data{ .capture_id = 3, .revision = 1, .extent_ns = std.math.maxInt(u64), .lanes = &lanes };
    try view.draw(&r, font, .{ .x = 0, .y = 0, .w = 900, .h = 300 }, &extreme);
    view.view = .{ .from_ns = extreme.extent_ns - 1000, .to_ns = extreme.extent_ns };
    try view.draw(&r, font, .{ .x = 0, .y = 0, .w = 21, .h = 300 }, &extreme);
}

test "header buttons act on release" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const lanes = [_]Lane{.{ .tid = 3 }};
    const data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1000, .lanes = &lanes };
    view.layout(test_bounds, &data);
    const y = view.geometry.plot.y + 5;
    try testing.expect(dragTo(view, 400, y, 600, y));
    const fit = view.geometry.fit;
    try testing.expect(!dragTo(view, fit.x + 5, fit.y + 5, fit.x + 5, fit.y + 5));
    try testing.expectEqual(view.range.?, view.view.?);
    const reset = view.geometry.reset;
    // Pressing a button and releasing elsewhere does nothing.
    try testing.expect(!dragTo(view, reset.x + 5, reset.y + 5, reset.x - 50, reset.y + 5));
    try testing.expect(dragTo(view, reset.x + 5, reset.y + 5, reset.x + 6, reset.y + 5));
    try testing.expect(view.range == null and view.view == null);
    try testing.expect(!view.reset());
}

test "imported interval hover respects half-open edges and thread identity" {
    const marks = [_]Mark{.{ .from_ns = 10, .to_ns = 20, .kind = .application, .tid = 3, .label = "  /  imported frame: 60" }};
    try testing.expectEqualStrings("", markText(&marks, 10, 4));
    try testing.expectEqualStrings(marks[0].label, markText(&marks, 10, 3));
    try testing.expectEqualStrings(marks[0].label, markText(&marks, 19, null));
    try testing.expectEqualStrings("", markText(&marks, 20, 3));
}

test "Ctrl click unions lanes; plain click replaces; range and pruning survive" {
    const view = try testView();
    defer testing.allocator.destroy(view);
    const lanes = [_]Lane{ .{ .tid = 11 }, .{ .tid = 22 }, .{ .tid = 33 } };
    var data = Data{ .capture_id = 1, .revision = 1, .extent_ns = 1000, .lanes = &lanes };
    view.layout(test_bounds, &data);
    const x = view.geometry.labels.x + 5;
    const y = view.geometry.plot.y + 5;
    view.range = .{ .from_ns = 100, .to_ns = 500 };
    try testing.expect(view.pressModified(x, y, true));
    try testing.expect(view.release(x, y));
    try testing.expectEqual(@as(?u32, 11), view.filter().tid);
    try testing.expect(view.pressModified(x, y + lane_h, true));
    try testing.expect(view.release(x, y + lane_h));
    try testing.expectEqualSlices(u32, &.{ 11, 22 }, view.tids.slice());
    try testing.expect(view.selectedThread(11) and view.selectedThread(22) and !view.selectedThread(33));
    try testing.expectEqual(@as(u64, 100), view.filter().from_ns);
    // Press-time Ctrl survives a release with no modifier input.
    try testing.expect(view.pressModified(x, y, true));
    try testing.expect(view.release(x, y));
    try testing.expectEqual(@as(?u32, 22), view.tid);
    try testing.expect(view.press(x, y + 2 * lane_h));
    try testing.expect(view.release(x, y + 2 * lane_h));
    try testing.expectEqual(@as(?u32, 33), view.tid);
    try testing.expect(view.pressModified(x, y + 2 * lane_h, true));
    try testing.expect(view.release(x, y + 2 * lane_h));
    try testing.expect(!view.hasThreadSelection());
    _ = view.pressModified(x, y, true);
    _ = view.release(x, y);
    _ = view.pressModified(x, y + lane_h, true);
    _ = view.release(x, y + lane_h);
    data.revision += 1;
    data.lanes = lanes[1..];
    try testing.expect(view.sync(&data));
    try testing.expectEqual(@as(?u32, 22), view.tid);
    try testing.expectEqual(@as(u16, 0), view.tids.len);
    try testing.expect(view.reset());
    try testing.expectEqual(model.Filter{}, view.filter());
}
