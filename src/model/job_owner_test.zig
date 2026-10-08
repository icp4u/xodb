const std = @import("std");
const jobs = @import("../service/job_owner.zig");
const Session = @import("session.zig").Session;

test "observation replacement preserves human comparison and archive selection" {
    const capture_model = @import("../observe/capture.zig");
    const peer = jobs.Requester{ .owner = jobs.Owner.agent(7) };
    const other = jobs.Requester{ .owner = jobs.Owner.agent(8) };
    const control = jobs.Requester{ .owner = peer.owner, .controller = true };
    var session = Session.init();
    defer session.deinit();
    const capture = try capture_model.Capture.create(std.heap.page_allocator, .{ .session_id = session.id, .capture_id = 1, .process_id = 1, .pid = 42, .image_epoch = 1, .generation = 1 }, .{}, &.{.{ .id = 1, .tid = 42 }}, &.{.{ .id = 1, .name = "fixture", .path = "/fixture", .identity = .{ .device = 1, .inode = 1, .size = 8192, .mtime_sec = 0, .mtime_ns = 0, .ctime_sec = 0, .ctime_ns = 0 }, .file_offset = 0, .link_address = 4096, .runtime_address = 4096 }});
    session.observations.capture = capture;
    capture.store.finish(.stop);
    _ = try session.compareObservation(.{ .threshold_ns = 10 });
    const human = session.observation_analysis.?;
    human.worker.?.join();
    human.worker = null;
    try std.testing.expectError(error.JobNotOwned, session.compareObservationOwned(.{ .threshold_ns = 20 }, peer));
    try std.testing.expect(session.observation_analysis.? == human);
    try std.testing.expectEqual(@as(u64, 10), capture.comparison_selection.?.threshold_ns);
    try std.testing.expect(!human.cancel.load(.acquire));
    _ = try session.compareObservationOwned(.{ .threshold_ns = 20 }, control);
    const owned = session.observation_analysis.?;
    owned.worker.?.join();
    owned.worker = null;
    try std.testing.expectError(error.JobNotOwned, session.compareObservationOwned(.{ .threshold_ns = 30 }, other));
    try std.testing.expectEqual(@as(u64, 20), capture.comparison_selection.?.threshold_ns);
    _ = try session.compareObservationOwned(.{ .threshold_ns = 30 }, peer);
}
