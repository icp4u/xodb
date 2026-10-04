//! Standalone allocation evidence archives; CPU archives keep their format.
//! Opening validates and replays raw events, never trusts stored lifetime totals.
const std = @import("std");
const model = @import("allocation_capture.zig");
const events = @import("allocation_events.zig");
const stacks = @import("allocation_stacks.zig");
const flame = @import("flame.zig");
const Budget = @import("archive_budget.zig").Budget;
const Progress = @import("archive_progress.zig").Progress;
pub const magic = "XODBALLOC\x01\r\n";
pub const max_bytes = 64 * 1024 * 1024;
const Wire = struct {
    version: u32 = 1,
    architecture: []const u8 = "x86_64",
    identity: model.Identity,
    origin: ?model.Identity = null,
    revision: u64,
    config: model.Config,
    started_ns: u64,
    ended_ns: u64,
    threads: []const model.Thread,
    hooks: []const model.Hook,
    records: []const events.Record,
    stacks: []const stacks.Stack,
    labels: []const flame.Frame,
    first_gap: ?events.Gap,
    unread_possible: bool,
    rejected: u64,
    stacks_omitted: u64,
};
fn cancelled(progress: ?*Progress) !void {
    if (progress) |p| if (p.cancel.load(.acquire)) return error.ArchiveCancelled;
}
pub fn encode(a: std.mem.Allocator, capture: *const model.Capture, progress: ?*Progress) ![]u8 {
    try cancelled(progress);
    if (capture.ended_ns == null or capture.worker != null) return error.AllocationCaptureNotFinalized;
    var budget = Budget{ .backing = a, .limit = 128 * 1024 * 1024 };
    const scratch = budget.allocator();
    const labels = try scratch.alloc(flame.Frame, capture.labels.count());
    defer scratch.free(labels);
    var it = capture.labels.valueIterator();
    var n: usize = 0;
    while (it.next()) |frame| : (n += 1) labels[n] = frame.*;
    std.mem.sort(flame.Frame, labels, {}, struct {
        fn less(_: void, left: flame.Frame, right: flame.Frame) bool {
            return left.lookup_address < right.lookup_address;
        }
    }.less);
    const body = try std.json.Stringify.valueAlloc(scratch, Wire{
        .identity = capture.identity,
        .origin = capture.origin,
        .revision = capture.revision,
        .config = capture.config,
        .started_ns = capture.started_ns,
        .ended_ns = capture.ended_ns.?,
        .threads = capture.threads[0..capture.thread_count],
        .hooks = capture.hooks[0..capture.hook_count],
        .records = capture.store.records.items,
        .stacks = capture.stacks.entries.items,
        .labels = labels,
        .first_gap = capture.store.first_gap,
        .unread_possible = capture.store.unread_possible,
        .rejected = capture.store.rejected,
        .stacks_omitted = capture.stacks.omitted,
    }, .{});
    defer scratch.free(body);
    try cancelled(progress);
    if (body.len > max_bytes - magic.len - 32) return error.ArchiveTooLarge;
    const bytes = try a.alloc(u8, magic.len + 32 + body.len);
    @memcpy(bytes[0..magic.len], magic);
    std.crypto.hash.sha2.Sha256.hash(body, bytes[magic.len..][0..32], .{});
    @memcpy(bytes[magic.len + 32 ..], body);
    return bytes;
}
pub fn decode(a: std.mem.Allocator, bytes: []const u8, progress: ?*Progress) !*model.Capture {
    try cancelled(progress);
    if (bytes.len > max_bytes or bytes.len < magic.len + 32 or !std.mem.startsWith(u8, bytes, magic)) return error.InvalidAllocationArchive;
    const body = bytes[magic.len + 32 ..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[magic.len..][0..32])) return error.AllocationArchiveChecksum;
    var budget = Budget{ .backing = a, .limit = 256 * 1024 * 1024 };
    const parsed = try std.json.parseFromSlice(Wire, budget.allocator(), body, .{ .max_value_len = 4096 });
    defer parsed.deinit();
    const saved = parsed.value;
    if (saved.version != 1 or !std.mem.eql(u8, saved.architecture, "x86_64") or saved.revision == 0 or saved.ended_ns < saved.started_ns or
        saved.records.len > saved.config.record_limit or saved.stacks.len > stacks.max_stacks or saved.labels.len > 65536) return error.InvalidAllocationArchive;
    if (saved.first_gap) |gap| {
        if (gap.reason == .pending or gap.reason == .complete) return error.InvalidAllocationArchive;
        if (gap.record) |record| if (record >= saved.records.len) return error.InvalidAllocationArchive;
    }
    const capture = try model.Capture.create(a, saved.identity, saved.config, saved.threads, saved.hooks, saved.started_ns);
    errdefer capture.deinit();
    capture.origin = saved.origin orelse saved.identity;
    capture.archived = true;
    const owned = capture.budget.allocator();
    for (saved.stacks, 0..) |stack, i| {
        try cancelled(progress);
        if (stack.status == .disabled or stack.count > stacks.max_frames) return error.InvalidAllocationArchive;
        for (stack.addresses()) |pc| if (pc == 0 or pc >= 0x8000000000000000) return error.InvalidAllocationArchive;
        const id = (try capture.stacks.intern(owned, stack)) orelse return error.InvalidAllocationArchive;
        if (id != i) return error.InvalidAllocationArchive;
    }
    capture.stacks.omitted = saved.stacks_omitted;
    for (saved.records) |record| {
        try cancelled(progress);
        const before = capture.store.records.items.len;
        capture.feed(record.lane, record.event) catch {
            // Some retained records deliberately diagnose an invalid pairing.
            // Reject failures which did not retain precisely this input record.
            if (capture.store.records.items.len != before + 1 or capture.store.first_gap == null) return error.InvalidAllocationArchive;
        };
    }
    if (capture.store.first_gap) |derived| {
        if (!std.meta.eql(@as(?events.Gap, derived), saved.first_gap)) return error.InvalidAllocationArchive;
    } else if (saved.first_gap) |gap| {
        // A source-side boundary has no fabricated event citation.
        if (gap.record != null) return error.InvalidAllocationArchive;
        if (gap.reason != .capture_end and gap.reason != .unread) capture.abort(gap.reason);
    }
    try capture.finish(saved.ended_ns, saved.unread_possible);
    if (!std.meta.eql(capture.store.first_gap, saved.first_gap)) return error.InvalidAllocationArchive;
    if (capture.store.unread_possible and !saved.unread_possible) return error.InvalidAllocationArchive;
    capture.store.unread_possible = saved.unread_possible;
    capture.store.rejected = saved.rejected;
    capture.revision = saved.revision;
    for (saved.labels) |label| {
        try cancelled(progress);
        if ((label.kind != .code and label.kind != .unknown) or label.name.len > 4096 or label.module.len > 4096 or label.mapping_note.len != 0 or
            label.lookup_address >= 0x8000000000000000 or capture.labels.contains(label.lookup_address)) return error.InvalidAllocationArchive;
        var frame = label;
        frame.name = try owned.dupe(u8, label.name);
        errdefer owned.free(frame.name);
        frame.module = try owned.dupe(u8, label.module);
        errdefer owned.free(frame.module);
        try capture.labels.put(owned, frame.lookup_address, frame);
    }
    return capture;
}
