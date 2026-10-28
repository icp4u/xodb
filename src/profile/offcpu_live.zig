//! Host collector for sched_switch. The ring is the volume bound; lost
//! records increment `dropped` and are not reconstructed.
const std = @import("std");
const model = @import("offcpu.zig");
const perf = @import("linux_perf.zig");
const runtime = @import("runtime.zig");
const rt = runtime.c;
pub const data_pages: u8 = 4;
pub fn ringBytes(threads: usize) u64 {
    return threads * @as(u64, data_pages) * rt.xrt_perf_page_size();
}
pub const Opened = union(enum) { collector: *Collector, failed: perf.Failure };
pub const Collector = struct {
    allocator: std.mem.Allocator,
    handle: *rt.struct_xrt_perf,
    layout: model.Layout,
    tracker: model.Tracker,
    tracker_taken: bool = false,
    pub fn close(self: *Collector) void {
        rt.xrt_perf_destroy(self.handle);
        if (!self.tracker_taken) self.tracker.deinit();
        self.allocator.destroy(self);
    }
    pub fn stop(self: *Collector) ?perf.Failure {
        var f: rt.struct_xrt_perf_failure = undefined;
        return if (rt.xrt_perf_stop(self.handle, &f)) null else runtime.failure(f);
    }
    /// The capture keeps the intervals. The ring fd closes with `close`.
    pub fn takeTracker(self: *Collector) model.Tracker {
        self.tracker_taken = true;
        return self.tracker;
    }
    const Decoding = struct {
        self: *Collector,
        more: bool = false,
        failure: ?anyerror = null,
        fn decode(raw: ?*anyopaque, view: [*c]const rt.struct_xrt_perf_ring, out: [*c]rt.struct_xrt_perf_consumed) callconv(.c) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            const ring = view[0];
            var tail = ring.tail;
            const status = ctx.consume(ring, &tail) catch |err| blk: {
                ctx.failure = err;
                break :blk rt.XRT_PERF_DRAIN_MALFORMED;
            };
            out[0] = .{ .bytes = tail - ring.tail, .status = status };
        }
        fn consume(ctx: *@This(), ring: rt.struct_xrt_perf_ring, tail: *u64) !c_uint {
            var count: usize = 0;
            while (tail.* < ring.head and count < 64) : (count += 1) {
                if (ring.head - tail.* < 8) return error.OffCpuRingIncomplete;
                var header: [8]u8 = undefined;
                runtime.copy(ring.data[0..ring.size], tail.*, &header);
                const kind = std.mem.readInt(u32, header[0..4], .little);
                const length = std.mem.readInt(u16, header[6..8], .little);
                if (length < 8 or length > 8192 or length > ring.head - tail.* or length % 8 != 0) return error.OffCpuRecordSize;
                var bytes: [8192]u8 = undefined;
                runtime.copy(ring.data[0..ring.size], tail.*, bytes[0..length]);
                tail.* += length;
                if (kind == 2 and length >= 24) {
                    ctx.self.tracker.dropped +|= std.mem.readInt(u64, bytes[16..24], .little);
                } else if (kind == 14 and length >= 24) {
                    // PERF_RECORD_SWITCH in this thread's ring. sample_id_all
                    // appends pid, tid, time. A switch-in closes the interval.
                    const misc = std.mem.readInt(u16, header[4..6], .little);
                    if (misc & 0x2000 == 0) {
                        const tid = std.mem.readInt(i32, bytes[12..16], .little);
                        const time = rt.xrt_perf_timestamp(ctx.self.handle, std.mem.readInt(u64, bytes[16..24], .little));
                        try ctx.self.tracker.resumed(tid, time);
                    }
                } else if (kind == 9) {
                    var frames: [model.max_frames]u64 = undefined;
                    if (model.parseSample(bytes[8..length], ctx.self.layout, &frames)) |parsed| {
                        const time = rt.xrt_perf_timestamp(ctx.self.handle, parsed.time_ns);
                        const wait: model.Wait = if (parsed.prev_state) |state| (if (model.isRunQueueWait(state)) .runqueue else .blocking) else .blocking;
                        try ctx.self.tracker.switchedWait(parsed.prev_pid, parsed.next_pid, time, parsed.frames, wait);
                    }
                }
            }
            ctx.more = ctx.more or tail.* < ring.head;
            return rt.XRT_PERF_DRAIN_OK;
        }
    };
    pub fn drain(self: *Collector) !bool {
        var ctx = Decoding{ .self = self };
        const status = rt.xrt_perf_drain(self.handle, Decoding.decode, &ctx);
        if (ctx.failure) |err| return err;
        if (status == rt.XRT_PERF_DRAIN_CANCELLED) return error.RemoteCancelled;
        if (status == rt.XRT_PERF_DRAIN_OUTCOME_UNKNOWN) return error.RemoteOutcomeUnknown;
        if (status == rt.XRT_PERF_DRAIN_MALFORMED) return error.OffCpuRingLayout;
        return ctx.more or status == rt.XRT_PERF_DRAIN_CAPACITY;
    }
    pub fn finish(self: *Collector, until_ns: u64) !void {
        try self.tracker.finish(until_ns);
    }
};
pub fn start(a: std.mem.Allocator, tids: []const i32, ring_budget: u64) !Opened {
    var layout: rt.struct_xrt_offcpu_layout = undefined;
    var f: rt.struct_xrt_perf_failure = undefined;
    const handle = rt.xrt_offcpu_start(tids.ptr, tids.len, data_pages, ring_budget, &layout, &f) orelse return .{ .failed = runtime.failure(f) };
    errdefer rt.xrt_perf_destroy(handle);
    var tracker = try model.Tracker.init(a, tids);
    errdefer tracker.deinit();
    const self = try a.create(Collector);
    self.* = .{ .allocator = a, .handle = handle, .layout = .{ .prev_pid_off = layout.prev_pid_off, .next_pid_off = layout.next_pid_off, .prev_state_off = layout.prev_state_off, .prev_state_size = layout.prev_state_size }, .tracker = tracker };
    return .{ .collector = self };
}
