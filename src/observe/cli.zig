//! Headless investigation orchestration; shared Session/collector/analysis APIs.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const c = @import("../c.zig").api;
const recipe = @import("recipe.zig");
const analysis = @import("analysis.zig");
fn awaitArchive(session: *Session, quit: *volatile c.sig_atomic_t, preserve_interrupted_capture: bool) !void {
    const job = session.observation_archive orelse return error.NoObservationArchive;
    // A capture interrupted by a signal still gets its one bounded save. A
    // signal during an ordinary open/save cancels that worker cooperatively.
    while (!job.done.load(.acquire)) {
        if (quit.* != 0 and !preserve_interrupted_capture) job.progress.cancel.store(true, .release);
        try session.poll();
        _ = c.usleep(2000);
    }
    try session.poll();
    if (job.err) |err| return err;
    if (job.publication) |publication| if (publication.state != .published) {
        std.debug.print("xodb: observation archive failed: {s}; {s}\n", .{ publication.error_name orelse "unknown", job.path });
        return error.ObservationArchiveNotPublished;
    };
}
fn compare(session: *Session, threshold: ?u64, quit: *volatile c.sig_atomic_t) !void {
    const capture = session.observations.capture orelse return error.NoObservation;
    var selection = capture.comparison_selection orelse @import("comparison.zig").Selection{ .threshold_ns = 4000000 };
    if (threshold) |ns| selection.threshold_ns = ns;
    try selection.validate();
    capture.comparison_selection = selection;
    session.observation_analysis = try analysis.Job.create(session.next_observation_analysis, capture, selection);
    session.next_observation_analysis += 1;
    const job = session.observation_analysis.?;
    while (!job.done.load(.acquire)) {
        if (quit.* != 0) job.cancel.store(true, .release);
        _ = c.usleep(2000);
    }
    if (job.err) |err| return err;
}
fn emit(a: std.mem.Allocator, session: *Session, outcome: ?recipe.Outcome, comparison_error: ?anyerror) !void {
    var value = try @import("../mcp/profile.zig").value(a, .{
        .observation = try @import("../mcp/observation.zig").status(a, session),
        .outcome = outcome,
        .comparison = if (session.observation_analysis) |job| job.result else null,
        .comparison_error = if (comparison_error) |err| @errorName(err) else null,
        .archive = if (session.observation_archive) |job| job.status() else null,
    });
    // status already contains strings; this pass formats the comparison too.
    try @import("../mcp/exact.zig").observation(a, &value);
    const json = try std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
    var offset: usize = 0;
    while (offset < json.len) {
        const n = c.write(1, json.ptr + offset, json.len - offset);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ObservationOutputFailed;
        offset += @intCast(n);
    }
    if (c.write(1, "\n", 1) != 1) return error.ObservationOutputFailed;
}
pub fn run(a: std.mem.Allocator, session: *Session, path: [:0]const u8, destination: []const u8, threshold: ?u64, quit: *volatile c.sig_atomic_t) !void {
    var parsed = try recipe.load(a, path);
    defer parsed.deinit();
    const outcome = try recipe.run(session, &parsed.value, quit);
    const capture = session.observations.capture orelse return error.ObservationRecipeNoCapture;
    capture.recipe_json = try std.json.Stringify.valueAlloc(capture.arena.allocator(), parsed.value, .{});
    var comparison_error: ?anyerror = null;
    compare(session, threshold orelse parsed.value.threshold_ns, quit) catch |err| {
        comparison_error = err;
    };
    _ = try session.saveObservation(destination);
    try awaitArchive(session, quit, quit.* != 0);
    try emit(a, session, outcome, comparison_error);
    if (comparison_error) |err| return err;
    switch (outcome.reason) {
        .stop_symbol, .duration, .target_exit, .limit => {},
        else => return error.ObservationRunInterrupted,
    }
}
pub fn open(a: std.mem.Allocator, session: *Session, path: []const u8, threshold: ?u64, mcp: bool, quit: *volatile c.sig_atomic_t) !void {
    try session.openObservation(path);
    try awaitArchive(session, quit, false);
    if (!mcp) {
        try compare(session, threshold, quit);
        try emit(a, session, null, null);
    }
}
