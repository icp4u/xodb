//! Read-only pages of the same kernel inventory used by the optional GUI panel.
const std = @import("std");
const model = @import("../model/kernel_view.zig");
const wire = @import("profile.zig");
const Value = std.json.Value;

pub fn call(a: std.mem.Allocator, session: anytype, args: Value) !Value {
    try wire.fields(args, &.{ "section", "start", "limit", "generation" });
    const raw = args.object.get("section") orelse Value{ .string = "tasks" };
    if (raw != .string) return error.InvalidArguments;
    const section = std.meta.stringToEnum(model.Section, raw.string) orelse return error.InvalidArguments;
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    if (limit == 0 or limit > 128) return error.InvalidArguments;
    if (!session.modules.measure_kernel_slide) return error.KernelTargetRequired;
    if (args.object.contains("generation") and try wire.number(args, "generation", null) != session.target.snapshot().generation) return error.StaleSnapshot;
    const view = try model.capture(a, session, true);
    return page(a, view, section, start, limit);
}
pub fn page(a: std.mem.Allocator, view: model.View, section: model.Section, start: u64, limit: u64) !Value {
    if (limit == 0 or limit > 128 or start > view.count(section)) return error.InvalidArguments;
    return switch (section) {
        .tasks => rows(a, view, section, view.tasks, @intCast(start), @intCast(limit)),
        .cpus => rows(a, view, section, view.cpus, @intCast(start), @intCast(limit)),
        .modules => rows(a, view, section, view.modules, @intCast(start), @intCast(limit)),
        .waits => rows(a, view, section, view.waits, @intCast(start), @intCast(limit)),
    };
}
fn rows(a: std.mem.Allocator, view: model.View, section: model.Section, values: anytype, start: usize, limit: usize) !Value {
    const end = start + @min(limit, values.len - start);
    return wire.value(a, .{
        .section = section,
        .generation = view.generation,
        .reason = view.reason,
        .atomic_snapshot = false,
        .truncated = view.truncated,
        .rows = values[start..end],
        .total = values.len,
        .next = if (end < values.len) @as(?usize, end) else null,
        .limits = .{ .tasks = model.max_tasks, .cpus = model.max_cpus, .modules = model.max_modules, .waits = model.max_waits, .hops = 4, .page = 128 },
    });
}

test "kernel pages preserve unavailable states and unverified modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const view: model.View = .{ .enabled = true, .generation = 9, .modules = &.{
        .{ .name = "owned.ko", .start = "0x1000", .end = "0x2000", .status = .loaded },
        .{ .name = "owned.ko", .start = "0x1000", .end = "0x2000", .status = .load_failure, .reason = "KernelModuleUnverified" },
    } };
    const first = try page(a, view, .modules, 0, 1);
    try std.testing.expectEqual(@as(i64, 1), first.object.get("next").?.integer);
    const second = try page(a, view, .modules, 1, 1);
    try std.testing.expectEqualStrings("KernelModuleUnverified", second.object.get("rows").?.array.items[0].object.get("reason").?.string);
    try std.testing.expect(second.object.get("next").? == .null);
    try std.testing.expectError(error.InvalidArguments, page(a, view, .modules, 3, 1));
    try std.testing.expectError(error.InvalidArguments, page(a, view, .modules, 0, 129));
}
