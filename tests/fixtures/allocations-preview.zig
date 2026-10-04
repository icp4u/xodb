//! GUI fixture, copied into src/ only in the isolated test tree. No live
//! target, probes, tracefs, privilege changes or allocation-capture CLI flag.
const std = @import("std");
const model = @import("profile/allocation_capture.zig");
const events = @import("profile/allocation_events.zig");
const life = @import("profile/allocation_lifetimes.zig");
const Panel = @import("ui/allocations.zig").Panel;
const Window = @import("platform/wayland.zig").Window;
const Renderer = @import("render/vulkan.zig").Renderer;
const Font = @import("render/font.zig").Font;
const wire = @import("mcp/profile.zig");
pub var panel = Panel{};
pub var capture: ?*model.Capture = null;
var serial: u64 = 100;
var force_frame = false;
const a = std.heap.page_allocator;
pub fn deinit() void {
    if (capture) |data| data.deinit();
    panel.deinit();
}
fn sample(time: u64, phase: events.Phase, kind: life.Kind, sp: u64, arg: u64, result: u64) events.Event {
    return .{ .time_ns = time, .data = .{ .sample = .{ .phase = phase, .hook = if (kind == .malloc) 1 else 2, .kind = kind, .stack_key = sp, .arg0 = arg, .result = result } } };
}
pub fn scenario(name: []const u8) !void {
    if (capture) |old| old.deinit();
    capture = null;
    serial += 1;
    force_frame = true;
    panel.show();
    if (std.mem.eql(u8, name, "empty")) return;
    const result = try model.Capture.create(a, .{ .session_id = serial, .capture_id = 5, .process_id = 1, .pid = 5000, .image_epoch = serial }, .{ .callstacks = true }, &.{ .{ .id = 11, .tid = 5000 }, .{ .id = 22, .tid = 5001 } }, &.{
        .{ .id = 1, .kind = .malloc, .name = "malloc", .path = "/fixture/allocator.so", .device = 1, .inode = 9, .file_offset = 0x1000, .link_address = 0x1000, .runtime_address = 0x401000 },
        .{ .id = 2, .kind = .free, .name = "free", .path = "/fixture/allocator.so", .device = 1, .inode = 9, .file_offset = 0x1100, .link_address = 0x1100, .runtime_address = 0x401100 },
    }, 100);
    capture = result;
    var caller = @import("profile/allocation_stacks.zig").Stack{ .count = 3, .status = .prefix };
    caller.pcs[0..3].* = .{ 0x401000, 0x402004, 0x403004 };
    const stack_id = (try result.stacks.intern(result.budget.allocator(), caller)).?;
    for ([_][]const u8{ "malloc", "retain_block", "request_handler" }, caller.addresses(), 0..) |label, pc, depth| {
        const lookup = if (depth == 0) pc else pc - 1;
        try result.labels.put(result.budget.allocator(), lookup, .{ .kind = .code, .address = lookup, .lookup_address = lookup, .name = try result.budget.allocator().dupe(u8, label), .module = try result.budget.allocator().dupe(u8, "/constructed/fixture") });
    }
    const many = std.mem.eql(u8, name, "many");
    const count: usize = if (many) 2500 else 80;
    for (0..count) |i| {
        const time = 110 + i * 20;
        const pointer = 0x100000 + i * 0x100;
        var entry = sample(time, .enter, .malloc, 0x8000, 24 + i * 8, 0);
        entry.data.sample.stack = stack_id;
        try result.feed(0, entry);
        if (i % 11 == 0) {
            try result.feed(0, sample(time + 1, .enter, .malloc, 0x7f00, 24 + i * 8, 0));
            try result.feed(0, sample(time + 3, .leave, .malloc, 0x7f00, 0, pointer));
        }
        try result.feed(0, sample(time + 5, .leave, .malloc, 0x8000, 0, pointer));
    }
    const after = 110 + count * 20;
    if (!many) for (0..count) |i| {
        if (i % 3 != 0) continue;
        try result.feed(1, sample(after + i * 10, .enter, .free, 0x9000, 0x100000 + i * 0x100, 0));
        try result.feed(1, sample(after + i * 10 + 2, .leave, .free, 0x9000, 0, 0));
    };
    const end = after + count * 10 + 10;
    if (std.mem.eql(u8, name, "collecting")) return;
    if (std.mem.eql(u8, name, "stopping")) {
        result.abort(.decode_error);
        return;
    }
    if (std.mem.eql(u8, name, "loss")) try result.feed(0, .{ .time_ns = end, .data = .{ .lost = 3 } });
    try result.finish(end, std.mem.eql(u8, name, "loss"));
    if (std.mem.eql(u8, name, "memory")) {
        // Deliberately inject worker exhaustion after retaining valid events.
        result.budget.limit = result.budget.used + 128;
        result.config.memory_limit = result.budget.limit + @sizeOf(model.Capture);
    }
}
pub fn input(window: *Window) void {
    if (capture) |data| {
        const before = data.state;
        data.poll();
        if (data.state != before) force_frame = true;
    }
    while (window.input.next()) |event| {
        if (event.kind == .button_press and event.code == 272) panel.press(capture, event.x, event.y) else if (!panel.open and event.kind == .press and event.shortcut == 'a') panel.show() else _ = panel.key(capture, event);
        force_frame = true;
    }
    if (window.scroll != 0) {
        panel.wheel(window.scroll);
        window.scroll = 0;
        force_frame = true;
    }
    if (panel.heap_pending) force_frame = true;
    if (force_frame) window.dirty = true;
    force_frame = false;
}
pub fn draw(renderer: *Renderer, font: *Font, width: f32, height: f32) !void {
    try panel.draw(renderer, font, width, height, capture);
    try renderer.textFit(font, 20, 70, width - 40, "FIXTURE DATA / allocation panel prototype / no live process traced", .{ 1, 0.7, 0.25, 1 });
}
pub fn call(allocator: std.mem.Allocator, name: []const u8, args: std.json.Value) !std.json.Value {
    if (std.mem.eql(u8, name, "allocation_preview_save")) {
        try wire.fields(args, &.{"path"});
        const value = args.object.get("path") orelse return error.InvalidArguments;
        if (value != .string) return error.InvalidArguments;
        const bytes = try @import("profile/allocation_archive.zig").encode(allocator, capture.?, null);
        const path = try allocator.dupeZ(u8, value.string);
        return wire.value(allocator, @import("profile/archive.zig").publish(path, bytes, null));
    } else if (std.mem.eql(u8, name, "allocation_preview_scenario")) {
        try wire.fields(args, &.{"name"});
        const value = args.object.get("name") orelse return error.InvalidArguments;
        if (value != .string) return error.InvalidArguments;
        try scenario(value.string);
    } else if (!std.mem.eql(u8, name, "allocation_preview_status")) return @import("mcp/allocations.zig").call(allocator, capture, name, args);
    return wire.value(allocator, .{ .open = panel.open, .display_key = panel.key_, .mode = panel.mode, .metric = panel.metric, .heap_hits = panel.heap_count, .zoom = panel.zoom, .start = panel.start, .next = panel.next, .count = panel.count, .selected = panel.selectedOrdinal(), .thread_id = panel.filter.thread_id, .history = panel.history.items.len, .message = panel.message, .state = if (capture) |data| @as(?model.State, data.state) else null, .key = if (capture) |data| @as(?model.Key, data.key()) else null });
}
