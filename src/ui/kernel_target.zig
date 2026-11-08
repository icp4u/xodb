//! Optional F7 kernel inventory; input and drawing use copied owner data only.
const std = @import("std");
const model = @import("../model/kernel_view.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const layout = @import("../layout_snapshot.zig");
const style = @import("style.zig");
const theme = style.theme;
const f7 = 0xffc4;
pub const Panel = struct {
    open: bool = false,
    section: model.Section = .tasks,
    first: usize = 0,
    visible: usize = 1,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    view: model.View = .{},

    pub fn key(self: *Panel, event: keys.Event) bool {
        if (!self.open) return false;
        if ((event.kind != .press and event.kind != .repeat) or !event.plain()) return true;
        switch (event.shortcut) {
            f7, keys.sym.escape => self.open = false,
            keys.sym.tab => {
                self.section = @enumFromInt((@as(usize, @intFromEnum(self.section)) + 1) % 4);
                self.first = 0;
            },
            '1'...'4' => {
                self.section = @enumFromInt(event.shortcut - '1');
                self.first = 0;
            },
            keys.sym.up, 'k' => self.wheel(-1),
            keys.sym.down, 'j' => self.wheel(1),
            0xff55 => self.wheel(-@as(i32, @intCast(self.visible))),
            0xff56 => self.wheel(@intCast(self.visible)),
            else => {},
        }
        return true;
    }
    pub fn wheel(self: *Panel, delta: i32) void {
        if (delta < 0) self.first -|= @intCast(-delta) else self.first +|= @intCast(delta);
        self.first = @min(self.first, self.count() -| self.visible);
    }
    fn count(self: *const Panel) usize {
        if (self.section != .waits) return self.view.count(self.section);
        var total: usize = 0;
        for (self.view.waits) |wait| total += 1 + wait.hops.len;
        return total;
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x >= b.x + b.w or y < b.y or y >= b.y + b.h) {
            self.open = false;
            return;
        }
        if (y >= b.y + 34 and y < b.y + 64) {
            self.section = @enumFromInt(@min(3, @as(usize, @intFromFloat((x - b.x) * 4 / b.w))));
            self.first = 0;
        }
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, report: *layout.Snapshot) !void {
        if (!self.open) return;
        const previous_clip = r.clip;
        r.clip = .{ .x = 0, .y = 0, .w = width, .h = height };
        defer r.clip = previous_clip;
        const b: gpu.Rect = .{ .x = 20, .y = 96, .w = @max(0, width - 40), .h = @max(0, height - 136) };
        self.bounds = b;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 112 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        report.available = true;
        report.pane_count = 0;
        report.row_count = 0;
        report.control_count = 0;
        report.rows_truncated = false;
        report.controls_truncated = false;
        try r.textFit(font, b.x + 12, b.y + 8, b.w - 24, "KERNEL TARGET   F7 / Esc close   1-4 / Tab sections   Arrows / Wheel", theme.text);
        const names = [_][]const u8{ "Tasks", "CPUs", "Modules", "Waits" };
        const shortcuts = [_][]const u8{ "1", "2", "3", "4" };
        for (names, 0..) |name, i| {
            const tab: gpu.Rect = .{ .x = b.x + @as(f32, @floatFromInt(i)) * b.w / 4 + 4, .y = b.y + 34, .w = b.w / 4 - 8, .h = 28 };
            if (i == @intFromEnum(self.section)) try r.rect(tab, theme.focus);
            try r.textFit(font, tab.x + 8, tab.y + 4, tab.w - 16, name, theme.text);
            report.control(name, shortcuts[i], .{ .x = tab.x, .y = tab.y, .w = tab.w, .h = tab.h }, false);
        }
        var status: [256]u8 = undefined;
        const note = if (!self.view.prepared) "Preparing kernel inventory" else self.view.reason orelse "Cached stop inventory; live memory is not an atomic snapshot";
        try r.textFit(font, b.x + 12, b.y + 70, b.w - 24, note, theme.weak);
        const total = self.count();
        self.visible = @intFromFloat(@max(1, (b.h - 120) / 42));
        self.first = @min(self.first, total -| self.visible);
        const end = @min(total, self.first + self.visible);
        for (self.first..end, 0..) |index, offset| {
            var label_buf: [256]u8 = undefined;
            var value_buf: [512]u8 = undefined;
            const text = self.row(index, &label_buf, &value_buf);
            const y = b.y + 94 + @as(f32, @floatFromInt(offset)) * 42;
            try r.textFit(font, b.x + 12, y, b.w - 24, text.label, theme.text);
            try r.textFit(font, b.x + 12, y + 19, b.w - 24, text.value, theme.weak);
            const pane = switch (self.section) {
                .tasks => "kernel_tasks",
                .cpus => "kernel_cpus",
                .modules => "kernel_modules",
                .waits => "kernel_waits",
            };
            report.row(pane, .{ .x = b.x + 12, .y = y, .w = b.w - 24, .h = 39 }, text.label, text.value, r.measure(font, text.label) > b.w - 24, r.measure(font, text.value) > b.w - 24, false);
        }
        const footer = std.fmt.bufPrint(&status, "{d}-{d} / {d} rows   generation {d}{s}", .{ if (total == 0) @as(usize, 0) else self.first + 1, end, total, self.view.generation, if (self.view.truncated) "   TRUNCATED" else "" }) catch "Kernel inventory";
        try r.textFit(font, b.x + 12, b.y + b.h - 22, b.w - 24, footer, theme.weak);
    }
    const Text = struct { label: []const u8, value: []const u8 };
    fn row(self: *const Panel, index: usize, label: []u8, value: []u8) Text {
        switch (self.section) {
            .tasks => {
                const task = self.view.tasks[index];
                return .{ .label = std.fmt.bufPrint(label, "{d}  {s}", .{ task.pid, task.name }) catch task.name, .value = std.fmt.bufPrint(value, "state={?d}  CPU={?d}  task={s}  debugger tid={?d}", .{ task.state, task.cpu, task.address, task.tid }) catch "Task details unavailable" };
            },
            .cpus => {
                const cpu = self.view.cpus[index];
                return .{ .label = std.fmt.bufPrint(label, "CPU {d}  {s}", .{ cpu.cpu, cpu.name }) catch cpu.name, .value = std.fmt.bufPrint(value, "current pid={?d}  task={s}  online state unknown", .{ cpu.pid, cpu.current_task orelse "unavailable" }) catch "CPU details unavailable" };
            },
            .modules => {
                const module = self.view.modules[index];
                return .{ .label = module.name, .value = std.fmt.bufPrint(value, "{s}  {s}-{s}{s}{s}", .{ module.reason orelse @tagName(module.status), module.start, module.end, if (module.detail != null) " / " else "", module.detail orelse "" }) catch module.reason orelse @tagName(module.status) };
            },
            .waits => {
                var at = index;
                for (self.view.waits) |wait| {
                    if (at == 0) return .{ .label = std.fmt.bufPrint(label, "{d}  {s}", .{ wait.pid, wait.name }) catch wait.name, .value = std.fmt.bufPrint(value, "wait_chain: {d} hops / {s}", .{ wait.hops.len, @tagName(wait.end) }) catch "Wait chain" };
                    if (at <= wait.hops.len) {
                        const hop = wait.hops[at - 1];
                        return .{ .label = std.fmt.bufPrint(label, "  hop {d}: {s}  lock=0x{x}", .{ at, @tagName(hop.kind), hop.lock }) catch "Wait hop", .value = std.fmt.bufPrint(value, "owner={s}  CPU={?d}  readers={any}  unknown_owner={any}", .{ if (hop.owner_len == 0) "unknown" else hop.owner[0..hop.owner_len], hop.owner_cpu, hop.readers, hop.unknown_owner }) catch "Wait owner unavailable" };
                    }
                    at -= 1 + wait.hops.len;
                }
                return .{ .label = "", .value = "" };
            },
        }
    }
};

test "kernel panel is opt-in and modal; wait hops remain individually visible" {
    var panel: Panel = .{};
    try std.testing.expect(!panel.open);
    panel.open = true;
    try std.testing.expect(panel.key(.{ .kind = .press, .shortcut = 'd' }));
    try std.testing.expect(panel.open);
    _ = panel.key(.{ .kind = .press, .shortcut = '4' });
    const hops = [_]@import("../model/kernel_aware.zig").WaitHop{ .{ .lock = 0x1000, .readers = true }, .{ .lock = 0x2000, .unknown_owner = true } };
    panel.view.waits = &.{.{ .pid = 7, .name = "owned", .hops = &hops, .end = .truncated }};
    try std.testing.expectEqual(@as(usize, 3), panel.count());
    var label: [256]u8 = undefined;
    var value: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, panel.row(0, &label, &value).value, "truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel.row(2, &label, &value).value, "unknown_owner=true") != null);
    _ = panel.key(.{ .kind = .press, .shortcut = keys.sym.escape });
    try std.testing.expect(!panel.open);
    panel.section = .modules;
    panel.view.modules = &.{.{ .name = "owned.ko", .start = "0x1000", .end = "0x2000", .status = .load_failure, .reason = "KernelModuleUnverified" }};
    try std.testing.expect(std.mem.startsWith(u8, panel.row(0, &label, &value).value, "KernelModuleUnverified"));
}
