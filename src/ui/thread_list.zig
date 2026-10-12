//! Local presentation/filtering only; runtime control and capture keep all rows.
const std = @import("std");
const linux = @import("../target/linux.zig");
const compat = @import("../model/compatibility.zig");
const gpu = @import("../render/vulkan.zig");
const style = @import("style.zig");
const Font = @import("../render/font.zig").Font;

pub const Panel = struct {
    hide_internal: bool = false,
    rows: [1024]usize = undefined,
    count: usize = 0,
    hidden: usize = 0,
    pub fn prepare(self: *Panel, threads: []const linux.Thread, labels: []const compat.Label, selected: usize) void {
        self.count = 0;
        self.hidden = 0;
        for ([_]bool{ false, true }) |group| for (threads, 0..) |thread, i| {
            const internal = i < labels.len and labels[i].id == thread.id and labels[i].tid == thread.tid and labels[i].internal_name;
            if (internal != group) continue;
            // A selected thread or an actual debugger stop must stay visible.
            const important = i == selected or (thread.state == .stopped and switch (thread.reason) {
                .breakpoint, .watchpoint, .exception, .signal, .single_step => true,
                else => false,
            });
            if (internal and self.hide_internal and !important) {
                self.hidden += 1;
                continue;
            }
            if (self.count == self.rows.len) break;
            self.rows[self.count] = i;
            self.count += 1;
        };
    }
    pub fn move(self: *Panel, selected: usize, down: bool) usize {
        if (self.count == 0) return selected;
        const at = std.mem.indexOfScalar(usize, self.rows[0..self.count], selected) orelse 0;
        return self.rows[if (down) (at + 1) % self.count else at -| 1];
    }
    pub fn hit(self: *Panel, rect: gpu.Rect, threads: []const linux.Thread, labels: []const compat.Label, selected: usize, x: f32, y: f32) ?usize {
        if (x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h) return null;
        self.prepare(threads, labels, selected);
        const heading: f32 = if (self.hide_internal) 20 else 0;
        if (y < rect.y + heading) return null;
        const visible: usize = @intFromFloat(@max(1, (rect.h - heading) / 39));
        const at = std.mem.indexOfScalar(usize, self.rows[0..self.count], selected) orelse 0;
        const first = (at + 1) -| visible;
        const row: usize = @intFromFloat((y - rect.y - heading) / 39);
        const result = first + row;
        return if (result < self.count and result < first + visible) self.rows[result] else null;
    }
    pub fn draw(self: *Panel, renderer: *gpu.Renderer, font: *Font, rect: gpu.Rect, threads: []const linux.Thread, labels: []const compat.Label, selected: usize) !void {
        if (rect.w <= 16 or rect.h < 20) return;
        self.prepare(threads, labels, selected);
        var buffer: [160]u8 = undefined;
        const heading: f32 = if (self.hide_internal) 20 else 0;
        if (self.hide_internal) {
            const count = std.fmt.bufPrint(&buffer, "{d} hidden / H show", .{self.hidden}) catch "Hidden threads";
            try renderer.textFit(font, rect.x + 8, rect.y, rect.w - 16, count, style.theme.weak);
        }
        const visible: usize = @intFromFloat(@max(1, (rect.h - heading) / 39));
        const at = std.mem.indexOfScalar(usize, self.rows[0..self.count], selected) orelse 0;
        const first = (at + 1) -| visible;
        for (self.rows[first..@min(self.count, first + visible)], 0..) |index, offset| {
            const thread = threads[index];
            const row = if (index < labels.len and labels[index].id == thread.id and labels[index].tid == thread.tid) &labels[index] else null;
            const y = rect.y + heading + @as(f32, @floatFromInt(offset)) * 39;
            if (index == selected) try style.focus(renderer, .{ .x = rect.x, .y = y - 2, .w = rect.w, .h = 38 }, 5, 1);
            const text = if (row) |name| if (name.readable) name.text() else if (index == 0) "main" else "" else "";
            const title = std.fmt.bufPrint(&buffer, "{d}{s}{s}{s}", .{ thread.tid, if (text.len > 0) " " else "", text, if (row != null and row.?.possibly_truncated) "~" else "" }) catch "";
            try renderer.textFit(font, rect.x + 8, y, rect.w - 16, title, if (index == selected) style.theme.text else style.theme.weak);
            const state = if (thread.reason != .none and thread.state == .stopped) @tagName(thread.reason) else @tagName(thread.state);
            const detail = if (row != null and row.?.dispatch_queue != null)
                std.fmt.bufPrint(&buffer, "{s} / queue 0x{x}", .{ state, row.?.dispatch_queue.? }) catch state
            else
                std.fmt.bufPrint(&buffer, "{s}{s}", .{ state, if (row != null and row.?.internal_name) " / Wine internal name" else if (row != null and row.?.source == .gdb_thread_info) "" else " / other" }) catch state;
            try renderer.textFit(font, rect.x + 8, y + 18, rect.w - 16, detail, style.theme.weak);
        }
    }
};

test "Wine filtering groups hints but preserves selected and faulting threads" {
    const threads = [_]linux.Thread{
        .{ .id = 1, .tid = 11, .state = .stopped, .reason = .interrupt },
        .{ .id = 2, .tid = 12, .state = .stopped, .reason = .interrupt },
        .{ .id = 3, .tid = 13, .state = .stopped, .reason = .signal },
    };
    var labels = [_]compat.Label{ .{ .id = 1, .tid = 11, .internal_name = true }, .{ .id = 2, .tid = 12 }, .{ .id = 3, .tid = 13, .internal_name = true } };
    var panel: Panel = .{};
    panel.prepare(&threads, &labels, 1);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 2 }, panel.rows[0..panel.count]);
    panel.hide_internal = true;
    panel.prepare(&threads, &labels, 1);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, panel.rows[0..panel.count]);
    try std.testing.expectEqual(@as(usize, 2), panel.move(1, true));
    panel.prepare(&threads, &labels, 0);
    try std.testing.expectEqual(@as(usize, 3), panel.count);
    labels[0].id = 99; // A recycled slot cannot inherit an old classification.
    panel.prepare(&threads, &labels, 1);
    try std.testing.expectEqual(@as(usize, 3), panel.count);
}

test "thread row hit follows the prepared visible order" {
    const threads = [_]linux.Thread{
        .{ .id = 1, .tid = 11, .state = .stopped },
        .{ .id = 2, .tid = 12, .state = .stopped },
        .{ .id = 3, .tid = 13, .state = .stopped },
    };
    var labels = [_]compat.Label{ .{ .id = 1, .tid = 11 }, .{ .id = 2, .tid = 12 }, .{ .id = 3, .tid = 13 } };
    var panel: Panel = .{};
    const rect = gpu.Rect{ .x = 10, .y = 20, .w = 200, .h = 80 };
    try std.testing.expectEqual(@as(?usize, 1), panel.hit(rect, &threads, &labels, 2, 20, 24));
    try std.testing.expectEqual(@as(?usize, 2), panel.hit(rect, &threads, &labels, 2, 20, 63));
    try std.testing.expectEqual(@as(?usize, null), panel.hit(rect, &threads, &labels, 2, 220, 24));
}
