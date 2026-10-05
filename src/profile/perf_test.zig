//! Collector enrollment needs the full target fixture; keep it out of the standalone decoder module.
const std = @import("std");
const perf = @import("linux_perf.zig");
const c = perf.c;
const runtime = @import("runtime.zig");
const Collector = perf.Collector;
const Failure = perf.Failure;
const FailureKind = perf.FailureKind;
const DrainStatus = perf.DrainStatus;
const start = perf.start;

test "enroll held newborn transactionally, reject budget and reuse, retire drained rings" {
    try @import("../test_support.zig").requireLive();
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
    const linux = @import("../target/linux.zig");
    var target = linux.Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/xodb-fixture", "profile-birth" });
    const opened = try start(std.testing.allocator, .{ .tids = &.{target.snapshot().pid}, .data_pages = 64 });
    const collector = switch (opened) {
        .collector => |value| value,
        .failed => |failure| {
            std.debug.print("perf enrollment test: {s} errno={d} {s}\n", .{ failure.syscall, failure.errno, failure.detail });
            return error.TestUnexpectedResult;
        },
    };
    defer collector.close();
    const Probe = struct {
        collector: *Collector,
        failure: ?Failure = null,
        calls: usize = 0,
        held_member: bool = false,
        fn born(raw: *anyopaque, thread: linux.Thread, member: bool) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.held_member = member and thread.state == .stopped;
            self.failure = self.collector.addThread(thread.tid);
        }
    };
    var probe = Probe{ .collector = collector };
    target.new_thread_observer = .{ .context = &probe, .before_resume = Probe.born };
    defer target.new_thread_observer = null;
    try target.continueExecution();
    const deadline = linux.now() + 2_000_000_000;
    while (probe.calls == 0 and linux.now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.held_member);
    try std.testing.expect(probe.failure == null);
    try std.testing.expectEqual(@as(u16, 2), runtime.info(collector.handle).threads);
    try std.testing.expect(collector.thread(1).?.event_id != collector.thread(0).?.event_id);
    try std.testing.expect(collector.addThread(target.snapshot().pid) != null);
    const enrolled_tid = collector.thread(1).?.tid;
    var new_samples: usize = 0;
    var new_mappings: usize = 0;
    while (target.snapshot().state != .exited and linux.now() < deadline) {
        try target.poll();
        const batch = collector.drain();
        try std.testing.expect(batch.status == .ok or batch.status == .capacity);
        for (batch.samples) |sample| if (sample.tid == enrolled_tid) {
            new_samples += 1;
        };
        for (batch.sides) |side| if (side.kind == .mmap and side.tid == enrolled_tid) {
            new_mappings += 1;
        };
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(linux.State.exited, target.snapshot().state);
    try std.testing.expect(new_samples > 0);
    try std.testing.expect(new_mappings > 0);
    const bytes = runtime.info(collector.handle).allocated_ring_bytes;
    runtime.state(collector.handle).budget = bytes;
    const rejected = collector.addThread(std.math.maxInt(i32)).?;
    try std.testing.expectEqual(FailureKind.resource, rejected.kind);
    runtime.state(collector.handle).budget += collector.ring_data_bytes;
    try std.testing.expectEqualStrings("perf_event_open", collector.addThread(std.math.maxInt(i32)).?.syscall);
    try std.testing.expectEqual(@as(u16, 2), runtime.info(collector.handle).threads);
    try std.testing.expectEqual(bytes, runtime.info(collector.handle).allocated_ring_bytes);
    // Deinit reaps only this fixture. Retired rings must retain queued data and
    // stable identities until drain, then return their memory/fd budget.
    const recorded_pid = target.snapshot().pid;
    target.deinit();
    for (0..runtime.info(collector.handle).threads) |i| try std.testing.expect(collector.retireThread(i) == null);
    for (0..32) |_| {
        const batch = collector.drain();
        if (batch.status == .ok) break;
        try std.testing.expectEqual(DrainStatus.capacity, batch.status);
    }
    try std.testing.expectEqual(@as(u64, 0), runtime.info(collector.handle).allocated_ring_bytes);
    for (runtime.state(collector.handle).slots[0..runtime.info(collector.handle).threads]) |slot| {
        try std.testing.expectEqual(@as(c_int, -1), slot.fds[0]);
        try std.testing.expect(!slot.owns_map);
    }
    try std.testing.expectEqual(@as(u16, 2), collector.acceptance().threads);
    try std.testing.expect(collector.addThread(recorded_pid) != null);
}
