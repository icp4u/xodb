//! Paged, read-only access to the explicitly opened CPU archive comparison.
const std = @import("std");
const wire = @import("profile.zig");
const model = @import("../profile/comparison.zig");
pub fn call(a: std.mem.Allocator, session: *@import("../model/session.zig").Session, args: std.json.Value) !std.json.Value {
    try wire.fields(args, &.{ "start", "limit", "view" });
    const start = std.math.cast(usize, try wire.number(args, "start", 0)) orelse return error.InvalidArguments;
    const limit = std.math.cast(usize, try wire.number(args, "limit", 64)) orelse return error.InvalidArguments;
    if (start > model.max_nodes or limit == 0 or limit > 256) return error.InvalidArguments;
    const mode = args.object.get("view") orelse std.json.Value{ .string = "functions" };
    if (mode != .string or (!std.mem.eql(u8, mode.string, "functions") and !std.mem.eql(u8, mode.string, "flames"))) return error.InvalidArguments;
    const job = session.comparison orelse return error.NoProfileComparison;
    if (!job.done.load(.acquire)) return wire.value(a, .{ .pending = true, .phase = @tagName(job.progress.phase.load(.acquire)) });
    if (job.failure) |err| return err;
    const view = &job.result.?;
    const flames = std.mem.eql(u8, mode.string, "flames");
    const total = if (flames) view.graph.nodes.items.len else view.ranking.len;
    const end = @min(start + limit, total);
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (@min(start, total)..end) |n| {
        if (flames) {
            const node = view.graph.nodes.items[n];
            const counts = view.counts[n];
            try rows.append(a, try wire.value(a, .{ .id = node.id, .parent = node.parent, .name = node.frame.name, .module = node.frame.module, .kind = node.frame.kind, .depth = node.depth, .x = node.x, .width = node.inclusive, .counts = counts, .delta_pp = model.delta(counts.inclusive, view.totals), .match = if (node.frame.address == 0) "root" else if (node.frame.address == model.unresolved_ancestry) "unresolved_ancestry_category" else @tagName(view.rows[@intCast(node.frame.address - 1)].match) }));
        } else {
            const id = view.ranking[n];
            const row = view.rows[id];
            try rows.append(a, try wire.value(a, .{ .id = id, .name = row.name, .module = row.module, .kind = row.kind, .match = row.match, .counts = row.counts, .before_self_percent = model.share(row.counts.self[0], view.totals[0]), .after_self_percent = model.share(row.counts.self[1], view.totals[1]), .self_delta_pp = model.delta(row.counts.self, view.totals), .inclusive_delta_pp = model.delta(row.counts.inclusive, view.totals) }));
        }
    }
    return wire.value(a, .{ .pending = false, .view = mode.string, .before = job.coverage[0], .after = job.coverage[1], .identical_evidence = std.mem.eql(u8, &job.coverage[0].sha256, &job.coverage[1].sha256), .rows = rows.items, .total = total, .next = if (end < total) end else @as(?usize, null), .total_width = view.graph.nodes.items[0].inclusive, .units = "percentage points of included sample count; not elapsed time or speedup", .matching = "identical archives use recorded frame identity; otherwise unique module path plus recorded symbol name; ambiguous and unknown functions stay run-local; unresolved ancestors are grouped as an explicit gap category in flames", .ranking = "absolute self-share delta, descending", .width_basis = "sum of max(before share, after share) for each leaf path, quantized to 1e-9", .scope = "full archives, threads aggregated; inclusive function counts deduplicate recursive ancestry", .annotation_basis = "recorded annotations; no host files or target memory read", .peak_comparison_bytes = job.budget.peak });
}
