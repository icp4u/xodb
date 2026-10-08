const std = @import("std");
const context = @import("../observe/context.zig");
const Session = @import("../model/session.zig").Session;
const wire = @import("profile.zig");
const V = std.json.Value;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "start_inspection", "get_inspection", "cancel_inspection", "release_inspection" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
fn boolean(args: V, key: []const u8, default: bool) !bool {
    const v = args.object.get(key) orelse return default;
    return if (v == .bool) v.bool else error.InvalidArguments;
}
fn summary(a: std.mem.Allocator, job: *const context.Job) !V {
    return wire.value(a, .{ .id = job.id, .state = job.state, .identity = job.identity, .stopped_threads = job.threads, .completed_items = job.done, .total_items = job.request.count(), .diagnostic = job.diagnostic, .scope = "all traced threads held; shared memory may change through unobserved processes or devices", .memory_limit = context.memory_limit, .peak_bytes = job.budget.peak });
}
pub fn call(a: std.mem.Allocator, session: *Session, name: []const u8, args: V) !V {
    if (std.mem.eql(u8, name, "start_inspection")) {
        try wire.fields(args, &.{ "generation", "tid", "frame", "registers", "stack", "locals", "expressions", "memory" });
        const tid = try wire.number(args, "tid", null);
        const frame = try wire.number(args, "frame", 0);
        if (tid == 0 or tid > std.math.maxInt(i32) or frame >= 64) return error.InvalidArguments;
        var request = context.Request{ .generation = try wire.number(args, "generation", null), .tid = @intCast(tid), .frame = @intCast(frame), .registers = try boolean(args, "registers", true), .stack = try boolean(args, "stack", true), .locals = try boolean(args, "locals", false) };
        if (args.object.get("expressions")) |list| {
            if (list != .array or list.array.items.len > 16) return error.InvalidArguments;
            const expressions = try a.alloc([]const u8, list.array.items.len);
            for (list.array.items, expressions) |v, *out| {
                if (v != .string) return error.InvalidArguments;
                out.* = v.string;
            }
            request.expressions = expressions;
        }
        if (args.object.get("memory")) |list| {
            if (list != .array or list.array.items.len > 16) return error.InvalidArguments;
            const ranges = try a.alloc(context.Range, list.array.items.len);
            for (list.array.items, ranges) |v, *out| {
                try wire.fields(v, &.{ "address", "length" });
                const address = v.object.get("address") orelse return error.InvalidArguments;
                if (address != .string) return error.InvalidArguments;
                const length = try wire.number(v, "length", null);
                if (length == 0 or length > 4096) return error.InvalidArguments;
                out.* = .{ .address = std.fmt.parseInt(u64, address.string, 0) catch return error.InvalidArguments, .length = @intCast(length) };
            }
            request.memory = ranges;
        }
        request.validate() catch return error.InvalidArguments;
        return summary(a, try session.inspections.startOwned(session, request, session.jobRequester()));
    }
    const get = std.mem.eql(u8, name, "get_inspection");
    try wire.fields(args, if (get) &.{ "id", "start", "limit" } else &.{"id"});
    const id = try wire.number(args, "id", null);
    if (std.mem.eql(u8, name, "release_inspection")) {
        try session.inspections.releaseOwned(id, session.jobRequester());
        return wire.value(a, .{ .id = id, .released = true });
    }
    const job = try session.inspections.find(id);
    if (!get) {
        try job.owner.require(session.jobRequester());
        if (job.active()) job.state = .cancelled;
        return summary(a, job);
    }
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 1);
    if (start > job.done or limit == 0 or limit > 2) return error.InvalidArguments;
    const end = @min(job.done, start + limit);
    const Row = struct { ordinal: usize, kind: context.Kind, index: usize, data: ?V, diagnostic: ?[]const u8 };
    const rows = try a.alloc(Row, end - start);
    for (job.items[start..end], rows, start..) |item, *row, ordinal| row.* = .{ .ordinal = ordinal, .kind = item.kind, .index = item.index, .data = if (item.json) |json| (try std.json.parseFromSlice(V, a, json, .{ .allocate = .alloc_always })).value else null, .diagnostic = item.diagnostic };
    for (rows) |*row| if (row.data) |*data| try @import("exact.zig").inspection(a, data);
    var result = try summary(a, job);
    try result.object.put(a, "items", try wire.value(a, rows));
    try result.object.put(a, "start", try wire.value(a, start));
    try result.object.put(a, "next", try wire.value(a, if (end < job.request.count() and (job.active() or end < job.done)) @as(?usize, end) else null));
    return result;
}
