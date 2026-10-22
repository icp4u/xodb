//! Owner-only timeline history preparation. Frontends receive bounded
//! display caches; raw samples, scheduling and overlays remain with the owner.
const std = @import("std");
const timeline = @import("../ui/timeline.zig");
const profile = @import("../profile/capture.zig");
const linux = @import("../target/linux.zig");
const evidence = @import("../evidence/stream.zig");
const live_capture = @import("../capture/live.zig");
/// The timeline's display data for the session capture: per-thread sample
/// times and debugger stop ranges. Rebuilt when the capture revision changes,
/// at most four times a second while collecting. Samples follow the capture's
/// own validity rule (time and TID present, not before start, an opening
/// thread), so counts agree with flames and `get_profile_timeline`.
/// Scheduling intervals use the same reconstruction as MCP.
pub const Source = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    data: ?timeline.Data = null,
    capture_id: u64 = 0,
    revision: u64 = 0,
    built_ns: u64 = 0,
    /// External evidence drawn as one extra lane (read-only, set by the owner).
    stream: ?*const evidence.Stream = null,
    /// A live source is snapshotted on the same bounded GUI refresh cadence.
    live: ?*live_capture.Live = null,
    live_snapshot: ?live_capture.Snapshot = null,

    pub fn deinit(self: *Source) void {
        if (self.live_snapshot) |*snapshot| snapshot.destroy();
        self.arena.deinit();
    }
    pub fn clear(self: *Source) void {
        if (self.live_snapshot) |*snapshot| snapshot.destroy();
        self.live_snapshot = null;
        self.live = null;
        self.stream = null;
        _ = self.arena.reset(.free_all);
        self.data = null;
        self.capture_id = 0;
        self.revision = 0;
        self.built_ns = 0;
    }
    pub fn refresh(self: *Source, capture: ?*profile.Capture) ?*const timeline.Data {
        if (self.live) |live| {
            const opened = live.snapshot(std.heap.page_allocator, 1) catch return if (self.data) |*data| data else null;
            if (self.live_snapshot) |*snapshot| snapshot.destroy();
            self.live_snapshot = opened;
            self.stream = opened.stream;
        }
        const current = capture orelse {
            // A stream without a capture is drawn on its own clock, once.
            const stream = self.stream orelse {
                self.data = null;
                return null;
            };
            if (self.live == null and self.data != null and self.capture_id == 0) return &self.data.?;
            self.buildStreamOnly(stream) catch {
                self.data = null;
                return null;
            };
            return &self.data.?;
        };
        const same = self.live == null and self.data != null and current.id == self.capture_id;
        if (same and current.revision == self.revision) return &self.data.?;
        if (same and current.collector != null and linux.now() -| self.built_ns < 250_000_000) return &self.data.?;
        self.build(current) catch {
            self.data = null;
            return null;
        };
        return &self.data.?;
    }
    pub const max_stop_spans = 4096;
    pub fn build(self: *Source, capture: *profile.Capture) !void {
        self.data = null;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const n = capture.thread_count;
        var lane_of: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        try lane_of.ensureTotalCapacity(a, @intCast(n));
        for (capture.threads[0..n], 0..) |thread, i| lane_of.putAssumeCapacity(@intCast(thread.perf.tid), @intCast(i));
        const counts = try a.alloc(usize, n);
        @memset(counts, 0);
        for (0..capture.samples.len()) |ordinal| {
            const sample = capture.samples.core(ordinal);
            if (valid(capture, sample)) if (lane_of.get(sample.tid)) |i| {
                counts[i] += 1;
            };
        }
        const lanes = try a.alloc(timeline.Lane, n);
        const times = try a.alloc([]u64, n);
        for (lanes, times, counts, capture.threads[0..n]) |*lane, *slot, count, thread| {
            slot.* = try a.alloc(u64, count);
            lane.* = .{ .tid = @intCast(thread.perf.tid), .debugger_id = thread.debugger_id };
        }
        @memset(counts, 0);
        for (0..capture.samples.len()) |ordinal| {
            const sample = capture.samples.core(ordinal);
            if (valid(capture, sample)) if (lane_of.get(sample.tid)) |i| {
                times[i][counts[i]] = sample.time_ns - capture.started_ns;
                counts[i] += 1;
            };
        }
        for (lanes, times) |*lane, slot| {
            std.mem.sort(u64, slot, {}, std.sort.asc(u64));
            lane.samples = slot;
        }
        const extent = capture.extentNs();
        if (capture.config.context_switch) for (lanes, 0..) |*lane, i| {
            const spans = try capture.switches.spans(a, i, extent, .{ .from_ns = 0, .to_ns = extent }, capture.schedulingCoverage());
            const intervals = try a.alloc(timeline.Interval, spans.len);
            for (spans, intervals) |span, *interval| interval.* = .{
                .from_ns = span.from_ns,
                .to_ns = span.to_ns,
                .state = switch (span.state) {
                    .running => .running,
                    .off_cpu => .off_cpu,
                    .unknown => .unknown,
                },
                .from_observed = span.from_ns != 0 and span.state != .unknown,
                .to_observed = span.to_ns != extent and span.state != .unknown,
                .preempted = span.switch_out_preempted orelse false,
                .detail = if (span.unknown_reason) |reason| @tagName(reason) else "",
            };
            lane.intervals = intervals;
        };
        var omitted: u64 = 0;
        const stops_ = try stops(a, capture, extent, &omitted);
        const imported = capture.application_intervals.items.items;
        const marks = try a.alloc(timeline.Mark, stops_.len + imported.len + capture.syscalls.items.items.len);
        @memcpy(marks[0..stops_.len], stops_);
        for (imported, marks[stops_.len..][0..imported.len]) |interval, *mark| mark.* = .{ .from_ns = interval.from_ns, .to_ns = interval.to_ns, .kind = .application, .tid = interval.tid, .label = try std.fmt.allocPrint(a, "  /  imported {s}: {s}", .{ @tagName(interval.kind), interval.label() }) };
        for (capture.syscalls.items.items, marks[stops_.len + imported.len ..]) |span, *mark| {
            const from = (span.entry_ns orelse span.exit_ns.?) -| capture.started_ns;
            const to = (span.exit_ns orelse span.entry_ns.?) -| capture.started_ns;
            mark.* = .{ .from_ns = from, .to_ns = to, .kind = .syscall, .tid = @intCast(capture.threads[span.thread_index].perf.tid), .label = if (span.elapsed()) |ns| try std.fmt.allocPrint(a, "  /  syscall {s} ({d}): {d:.3} ms elapsed", .{ @import("../profile/syscalls.zig").name(span.nr) orelse "?", span.nr, @as(f64, @floatFromInt(ns)) / 1000000 }) else try std.fmt.allocPrint(a, "  /  syscall ({d}): {s}, duration unknown", .{ span.nr, @tagName(span.reason) }) };
        }
        self.data = .{ .capture_id = capture.id, .revision = capture.revision, .extent_ns = extent, .live = capture.collector != null, .scheduling = capture.config.context_switch, .lanes = lanes, .marks = marks, .application_count = imported.len, .syscall_count = capture.syscalls.items.items.len, .debugger_marks_dropped = omitted +| capture.debugger_marker_dropped +| capture.debugger_events_lost, .lost_samples = capture.lost_samples, .stream = if (self.stream) |stream| try streamLane(a, stream, capture.started_ns, extent) else null };
        self.capture_id = capture.id;
        self.revision = capture.revision;
        self.built_ns = linux.now();
    }
    fn buildStreamOnly(self: *Source, stream: *const evidence.Stream) !void {
        self.data = null;
        _ = self.arena.reset(.retain_capacity);
        const first = stream.first_time_ns orelse 0;
        const extent = if (stream.last_time_ns) |last| (last - first) +| 1 else 1;
        var lane = try streamLane(self.arena.allocator(), stream, null, extent);
        lane.note = if (self.live != null) "live bounded ring; CLOCK_REALTIME, time since the oldest retained record" else "stream clock (CLOCK_REALTIME from the file), time since its first record; no capture opened";
        self.data = .{ .capture_id = 0, .revision = 1, .extent_ns = extent, .state_label = if (self.live != null) "live pcap" else "pcap only", .lanes = &.{}, .stream = lane };
        self.capture_id = 0;
        self.revision = 1;
        self.built_ns = linux.now();
    }
    /// Ticks on this capture's axis. With `capture_started_ns` the stream must
    /// be aligned through that same capture's ECTX pairs; otherwise records
    /// stay off the axis and are counted. Null places them on the stream's own
    /// clock, relative to its first record.
    fn streamLane(a: std.mem.Allocator, stream: *const evidence.Stream, capture_started_ns: ?u64, extent: u64) !timeline.StreamLane {
        var ticks: std.ArrayList(timeline.Tick) = .empty;
        var off_axis: u64 = 0;
        const same_capture = if (stream.context) |ctx| capture_started_ns != null and ctx.capture_started_ns == capture_started_ns.? else false;
        const aligned = same_capture and stream.mapping.state == .aligned;
        for (0..stream.parsed.records.len) |i| {
            const t = stream.timeOf(i);
            const at: ?u64 = if (capture_started_ns == null)
                (if (t.known) t.stream_ns - (stream.first_time_ns orelse t.stream_ns) else null)
            else if (aligned) t.capture_ns else null;
            if (at == null or at.? >= extent) {
                off_axis += 1;
                continue;
            }
            try ticks.append(a, .{ .t_ns = at.?, .bytes = stream.parsed.records[i].origlen, .undecoded = stream.summaries[i].undecoded() });
        }
        std.mem.sort(timeline.Tick, ticks.items, {}, struct {
            fn less(_: void, l: timeline.Tick, r: timeline.Tick) bool {
                return l.t_ns < r.t_ns;
            }
        }.less);
        var note_buffer: [160]u8 = undefined;
        const note = if (capture_started_ns == null)
            ""
        else if (stream.context == null)
            "unaligned: the capture archive has no clock pairs (ECTX); records are not placed on its clock"
        else if (stream.context.?.collection.reason()) |reason|
            try std.fmt.bufPrint(&note_buffer, "unaligned: {s}; records are not placed on the capture clock", .{reason})
        else if (!same_capture)
            "unaligned: clock pairs belong to a different capture"
        else if (!aligned)
            "unaligned: ECTX has no usable clock pairs"
        else
            try std.fmt.bufPrint(&note_buffer, "aligned to the capture clock from paired samples, +/-{d} ns", .{stream.mapping.uncertainty_ns});
        return .{ .label = stream.label, .ticks = ticks.items, .off_axis = off_axis, .undecoded = stream.undecoded, .note = try a.dupe(u8, note) };
    }
    fn valid(capture: *const profile.Capture, sample: anytype) bool {
        return sample.timePresent() and sample.tidPresent() and sample.time_ns >= capture.started_ns;
    }
    /// Debugger stop ranges from the capture's observed control markers. These
    /// are debugger timestamps, not exact scheduler boundaries. With lost events
    /// a pairing could span a missed resume, so none are shown; a stop still open
    /// at the last retained marker is omitted when later markers were dropped.
    fn stops(a: std.mem.Allocator, capture: *const profile.Capture, extent: u64, omitted: *u64) ![]timeline.Mark {
        var out: std.ArrayList(timeline.Mark) = .empty;
        if (capture.debugger_events_lost > 0) return out.items;
        for (capture.threads[0..capture.thread_count]) |thread| {
            var from: ?u64 = null;
            for (capture.debugger_markers.items) |marker| {
                if (thread.enrolled_ns) |enrolled| if (marker.offset_ns < enrolled -| capture.started_ns) continue;
                const all = marker.kind == .capture_open_stopped or marker.kind == .continued or marker.kind == .detach;
                if (!all and marker.tid != thread.perf.tid) continue;
                switch (marker.kind) {
                    .capture_open_stopped, .stop, .breakpoint_hit, .watchpoint_hit, .step_complete => {
                        if (from == null) from = marker.offset_ns;
                    },
                    .continued, .step_started, .exit, .detach => if (from) |start| {
                        if (marker.offset_ns > start) try stopSpan(a, &out, omitted, .{ .from_ns = start, .to_ns = marker.offset_ns, .kind = .debugger_stop, .tid = @intCast(thread.perf.tid) });
                        from = null;
                    },
                }
            }
            if (from) |start| if (capture.debugger_marker_dropped == 0 and extent > start) try stopSpan(a, &out, omitted, .{ .from_ns = start, .to_ns = extent, .kind = .debugger_stop, .tid = @intCast(thread.perf.tid) });
        }
        return out.items;
    }
    fn stopSpan(a: std.mem.Allocator, out: *std.ArrayList(timeline.Mark), omitted: *u64, mark: timeline.Mark) !void {
        if (out.items.len == max_stop_spans) {
            omitted.* +|= 1;
        } else try out.append(a, mark);
    }
};

pub const Capture = struct {
    source: Source = .{},
    viewport: timeline.TimelineView = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?timeline.Prepared = null,
    session_id: u64 = 0,
    capture_id: u64 = 0,
    revision: u64 = 0,
    requested: ?timeline.Request = null,
    refreshed_ns: u64 = 0,
    pub fn deinit(self: *Capture) void {
        self.source.deinit();
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        self.source.clear();
        self.viewport = .{};
        _ = self.arena.reset(.free_all);
        self.value = null;
        self.requested = null;
        self.session_id = 0;
        self.capture_id = 0;
        self.revision = 0;
    }
    pub fn changed(self: *const Capture, session: *const @import("session.zig").Session) bool {
        if (self.session_id != session.id) return true;
        if (session.live_capture != null and linux.now() -| self.refreshed_ns >= 250 * std.time.ns_per_ms) return true;
        const current = session.profile orelse return self.capture_id != 0;
        if (self.capture_id != current.id) return true;
        return current.revision != self.revision and (current.collector == null or linux.now() -| self.refreshed_ns >= 250 * std.time.ns_per_ms);
    }
    pub fn refresh(self: *Capture, session: *@import("session.zig").Session, wanted: ?timeline.Request) void {
        const request_ = wanted orelse {
            self.clear();
            return;
        };
        if (!self.changed(session) and std.meta.eql(wanted, self.requested)) return;
        if (self.session_id != session.id) self.clear();
        self.source.stream = session.evidence_stream;
        self.source.live = session.live_capture;
        const current = self.source.refresh(session.profile);
        _ = self.arena.reset(.retain_capacity);
        self.value = if (current) |data| self.viewport.prepare(self.arena.allocator(), session.id, request_, data) catch null else null;
        self.requested = wanted;
        self.session_id = session.id;
        self.capture_id = if (session.profile) |capture| capture.id else 0;
        self.revision = if (current) |data| data.revision else 0;
        self.refreshed_ns = linux.now();
    }
};
