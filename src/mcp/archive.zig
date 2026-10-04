const std = @import("std");
const Session = @import("../model/session.zig").Session;
const Value = std.json.Value;
fn asValue(a: std.mem.Allocator, object: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, object, .{}), .{ .allocate = .alloc_always })).value;
}
fn number(args: Value, key: []const u8) !u64 {
    const v = args.object.get(key) orelse return error.InvalidArguments;
    if (v != .integer or v.integer < 0) return error.InvalidArguments;
    return @intCast(v.integer);
}
pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "save_capture_archive") or std.mem.eql(u8, name, "get_archive_status") or std.mem.eql(u8, name, "cancel_archive_job");
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: Value) !Value {
    if (args != .object) return error.InvalidArguments;
    const save = std.mem.eql(u8, name, "save_capture_archive");
    const cancel = std.mem.eql(u8, name, "cancel_archive_job");
    const allowed: []const []const u8 = if (save) &.{ "generation", "capture_id", "revision", "path" } else if (cancel) &.{ "generation", "job_id" } else &.{};
    var keys = args.object.iterator();
    while (keys.next()) |key| {
        for (allowed) |known| {
            if (std.mem.eql(u8, key.key_ptr.*, known)) break;
        } else return error.InvalidArguments;
    }
    if (save) {
        try session.authorize(.agent, .execution, try number(args, "generation"));
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id") != capture.id) return error.StaleCapture;
        if (try number(args, "revision") != capture.revision) return error.StaleProfile;
        const path = args.object.get("path") orelse return error.InvalidArguments;
        if (path != .string or path.string.len == 0 or path.string.len > 4096 or std.mem.indexOfScalar(u8, path.string, 0) != null) return error.InvalidArguments;
        const id = try session.saveArchive(path.string);
        session.record(.agent, "save_capture_archive");
        return asValue(a, .{ .job_id = id, .generation = session.target.generation, .completion = "poll get_archive_status for publication; accepting a job does not mean the file was saved" });
    }
    if (cancel) {
        try session.authorize(.agent, .execution, try number(args, "generation"));
        const job = session.archive_job orelse return error.NoArchiveJob;
        if (try number(args, "job_id") != job.id) return error.StaleArchiveJob;
        if (!job.done.load(.acquire)) job.progress.cancel.store(true, .release);
        session.record(.agent, "cancel_archive_job");
    }
    const artifact = if (session.artifact) |*opened| opened else null;
    const digest = if (artifact) |opened| try a.dupe(u8, &std.fmt.bytesToHex(opened.source.archive_sha256, .lower)) else null;
    const view = if (artifact) |opened| try a.dupe(u8, &opened.viewId(.{})) else null;
    return asValue(a, .{ .offline = session.offline, .generation = session.target.generation, .job = if (session.archive_job) |job| job.status() else null, .artifact_sha256 = digest, .recorded_origin = if (artifact) |opened| opened.source else null, .default_view_id = view, .view_basis = if (artifact) |opened| (if (opened.capture.reanalyzed) "verified_assets_reanalysis" else "recorded_annotations") else null, .analysis_version = @import("../profile/archive.zig").analysis_version, .decoded_allocation_peak = if (artifact) |opened| opened.budget.peak else null, .limits = .{ .archive_bytes = @import("../profile/archive.zig").max_file_bytes, .decoded_zig_bytes = @import("../profile/archive.zig").max_memory_bytes, .per_asset_bytes = @import("../binary/snapshot.zig").per_image_limit, .total_asset_bytes = @import("../binary/snapshot.zig").total_limit }, .durability = "not_requested" });
}
