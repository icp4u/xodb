//! Native locals pages share one stopped-frame identity without retaining values.
const std = @import("std");
const model = @import("../model/session.zig");
const info = @import("../debug/info.zig");
const wire = @import("profile.zig");
const paging = @import("list_page.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const Context = struct {
    session_id: u64,
    generation: u64,
    epoch: u64,
    metadata_revision: u64,
    debug_files: usize,
    tid: u64,
    frame: usize,
    depth: usize,
    pc: u64,
    cfa: ?u64,
};
fn identity(ctx: Context, locals: []const info.Local) [64]u8 {
    var h = paging.Identity.init("xodb-native-locals-v1");
    inline for (std.meta.fields(Context)) |field| {
        const v = @field(ctx, field.name);
        if (@typeInfo(@TypeOf(v)) == .optional) h.optional(v) else h.number(v);
    }
    h.number(locals.len);
    for (locals) |local| {
        h.text(local.name);
        h.number(@intFromBool(local.parameter));
        h.text(local.value.type.name);
        h.number(@intFromEnum(local.value.type.kind));
        h.number(local.value.type.size);
        h.optional(local.value.address);
        h.number(local.value.bits);
        h.number(@intFromEnum(local.value.availability));
        h.text(local.value.data orelse &.{});
        h.text(local.value.valid orelse &.{});
        h.text(local.diagnostic orelse "");
    }
    return h.finish();
}
fn checkView(args: V, view: *const [64]u8, start: u64) !void {
    if (args.object.get("view_id")) |given| {
        if (given != .string or given.string.len != view.len) return error.InvalidArguments;
        if (!std.mem.eql(u8, given.string, view)) return error.StaleLocalsView;
    } else if (start != 0) return error.LocalsViewRequired;
}
pub fn call(a: A, session: *model.Session, args: V) !V {
    try wire.fields(args, &.{ "tid", "generation", "frame", "inline_depth", "start", "limit", "view_id" });
    const tid = try wire.number(args, "tid", null);
    const frame = try wire.number(args, "frame", 0);
    const depth = try wire.number(args, "inline_depth", 0);
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 64);
    if (tid == 0 or tid > std.math.maxInt(i32) or frame >= 64 or depth > 64 or limit == 0 or limit > 128) return error.InvalidArguments;
    if (args.object.contains("generation")) try session.target.expectGeneration(try wire.number(args, "generation", null));
    const frames = try session.stack(a, @intCast(tid), @intCast(frame + 1));
    if (frame >= frames.len) return error.InvalidFrame;
    const selected = frames[@intCast(frame)];
    const locals = try session.frameLocalsAtDepth(a, selected, @intCast(depth));
    if (start > locals.len) return error.InvalidArguments;
    const snap = session.target.snapshot();
    const view = identity(.{ .session_id = session.id, .generation = snap.generation, .epoch = snap.image_epoch, .metadata_revision = session.metadata.revision, .debug_files = session.symbolFiles().items.items.len, .tid = tid, .frame = @intCast(frame), .depth = @intCast(depth), .pc = selected.lookup_pc, .cfa = selected.cfa }, locals);
    try checkView(args, &view, start);
    var rows = V{ .array = std.array_list.Managed(V).init(a) };
    var budget: paging.Budget = .{};
    var end: usize = @intCast(start);
    while (end < locals.len and end - start < limit) : (end += 1) {
        const local = locals[end];
        var row = try wire.value(a, .{ .name = local.name, .parameter = local.parameter, .value = try session.summarize(a, local.value), .diagnostic = local.diagnostic });
        if (!try budget.include(a, &row)) {
            if (end == start) return error.McpRowTooLarge;
            break;
        }
        try rows.array.append(row);
    }
    return wire.value(a, .{ .generation = snap.generation, .tid = tid, .frame = frame, .inline_depth = depth, .locals = rows, .total = locals.len, .start = start, .next = if (end < locals.len) @as(?usize, end) else null, .view_id = view[0..] });
}

test "native locals view binds stop frame metadata and resolved locations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var locals = [_]info.Local{.{ .name = "owned", .parameter = false, .value = .{ .type = &@import("../model/evaluate.zig").uint_type, .address = 0x20000000000001 } }};
    const context = Context{ .session_id = 1, .generation = 2, .epoch = 3, .metadata_revision = 4, .debug_files = 0, .tid = 5, .frame = 0, .depth = 0, .pc = 6, .cfa = 7 };
    const view = identity(context, &locals);
    const args = try wire.value(a, .{ .view_id = view[0..] });
    try checkView(args, &view, 1);
    try std.testing.expectError(error.LocalsViewRequired, checkView(.{ .object = .empty }, &view, 1));
    inline for (std.meta.fields(Context)) |field| {
        var changed = context;
        const value = @field(changed, field.name);
        @field(changed, field.name) = if (@typeInfo(@TypeOf(value)) == .optional) value.? + 1 else value + 1;
        const different = identity(changed, &locals);
        try std.testing.expectError(error.StaleLocalsView, checkView(args, &different, 1));
    }
    locals[0].value.address.? += 8;
    const moved = identity(context, &locals);
    try std.testing.expectError(error.StaleLocalsView, checkView(args, &moved, 1));
}
