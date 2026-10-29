//! Read-only syscall detail, using the same capture filter and pages as MCP.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const profile = @import("../profile/capture.zig");
const style = @import("style.zig");
const theme = style.theme;
const model = @import("../model/syscall_view.zig");
pub const Panel = struct {
    open: bool = false,
    first: usize = 0,
    total: usize = 0,
    visible: usize = 0,
    selected: usize = 0,
    id: u64 = 0,
    revision: u64 = 0,
    filter: profile.Filter = .{},
    session: u64 = 0,
    view: ?model.View = null,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn show(self: *Panel) void {
        self.open = true;
        self.first = 0;
        self.selected = 0;
        self.id = 0;
        self.view = null;
    }
    pub fn wheel(self: *Panel, delta: i32) void {
        self.first = @intCast(std.math.clamp(@as(i64, @intCast(self.first)) + delta, 0, @as(i64, @intCast(self.total -| 1))));
        self.selected = 0;
        self.revision = 0;
    }
    pub fn key(self: *Panel, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (!event.plain()) return true;
        switch (event.shortcut) {
            'x', keys.sym.escape => self.open = false,
            keys.sym.up, 'k' => self.wheel(-1),
            keys.sym.down, 'j' => self.wheel(1),
            0xff55 => self.wheel(-@as(i32, @intCast(@max(1, self.visible)))),
            0xff56 => self.wheel(@intCast(@max(1, self.visible))),
            'p', keys.sym.space => return false,
            else => {},
        }
        return true;
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x >= b.x + b.w or y < b.y or y >= b.y + b.h) {
            self.open = false;
            return;
        }
        if (y >= b.y + 92 and y < b.y + 92 + @as(f32, @floatFromInt(self.visible)) * 24)
            self.selected = @intFromFloat((y - b.y - 92) / 24);
    }
    pub fn request(self: *Panel, height: f32, filter: profile.Filter) ?model.Request {
        if (!self.open) return null;
        if (!std.meta.eql(self.filter, filter)) {
            self.first = 0;
            self.selected = 0;
            self.filter = filter;
        }
        return .{ .session = self.session, .capture = self.id, .filter = filter, .first = self.first, .count = @intFromFloat(@min(64, @max(1, (height - 330) / 24))) };
    }
    pub fn present(self: *Panel, value: ?model.View, height: f32, filter: profile.Filter) void {
        self.view = null;
        const incoming = value orelse return;
        const wanted = self.request(height, filter) orelse return;
        if (incoming.normalized.session == self.session and incoming.normalized.capture == self.id and
            !std.meta.eql(wanted, incoming.request) and !std.meta.eql(wanted, incoming.normalized)) return;
        if (!std.meta.eql(filter, incoming.normalized.filter)) return;
        self.session = incoming.normalized.session;
        self.id = incoming.normalized.capture;
        self.revision = incoming.revision;
        self.first = incoming.normalized.first;
        self.total = incoming.total;
        self.selected = @min(self.selected, incoming.rows.len -| 1);
        self.view = incoming;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 112 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "SYSCALLS   X / Esc close   Wheel / PgUp / PgDown   Click a row", theme.text);
        try r.textFit(font, b.x + 14, b.y + 35, b.w - 28, "Elapsed includes off-CPU time and debugger pauses. Names use the capture's native syscall ABI.", theme.weak);
        const view = self.view orelse {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, "Preparing syscall details for the current selection", theme.weak);
            return;
        };
        if (view.normalized.capture == 0) {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, "No capture. Enable Syscalls in Setup (S), then choose 1..32 threads.", theme.weak);
            return;
        }
        const count: usize = @intFromFloat(@min(64, @max(1, (b.h - 194) / 24)));
        self.visible = @min(count, view.rows.len);
        var buffer: [512]u8 = undefined;
        try r.textFit(font, b.x + 14, b.y + 64, b.w - 28, try std.fmt.bufPrint(&buffer, "{s}   {d}..{d} of {d} filtered calls   lost {d} / throttles {d} / rejected {d}", .{ if (!view.recorded) "Not recorded" else if (view.collecting) "Recording" else "Recorded", if (self.visible > 0) self.first + 1 else 0, self.first + self.visible, self.total, view.lost, view.throttles, view.discarded }), theme.weak);
        for (view.rows[0..self.visible], 0..) |row, i| {
            const y = b.y + 92 + @as(f32, @floatFromInt(i)) * 24;
            if (i == self.selected) try style.focus(r, .{ .x = b.x + 8, .y = y - 2, .w = b.w - 16, .h = 24 }, 4, 1);
            var duration: [32]u8 = undefined;
            const elapsed = if (row.elapsed_ns) |ns| try std.fmt.bufPrint(&duration, "{d:.3} ms", .{@as(f64, @floatFromInt(ns)) / 1000000}) else "unknown";
            try r.textFit(font, b.x + 14, y, b.w - 28, try std.fmt.bufPrint(&buffer, "#{d}  TID {d}  {s} ({d})   {s}   {s}", .{ row.ordinal, row.thread.perf.tid, row.name orelse "?", row.nr, elapsed, @tagName(row.reason) }), if (i == self.selected) theme.text else theme.weak);
        }
        if (view.rows.len > 0) {
            const row = view.rows[self.selected];
            try r.textFit(font, b.x + 14, b.y + b.h - 92, b.w - 28, try std.fmt.bufPrint(&buffer, "Selected #{d}: return {any}  {s}  /  entry {any}, exit {any}", .{ row.ordinal, row.result, if (row.return_class) |v| @tagName(v) else "unknown", row.entry_ns, row.exit_ns }), theme.text);
            if (row.scheduling_overlap) |v| try r.textFit(font, b.x + 14, b.y + b.h - 66, b.w - 28, try std.fmt.bufPrint(&buffer, "Observed overlap: running {d:.3} ms / off CPU {d:.3} ms / unknown {d:.3} ms", .{ @as(f64, @floatFromInt(v.running_ns)) / 1000000, @as(f64, @floatFromInt(v.off_cpu_ns)) / 1000000, @as(f64, @floatFromInt(v.unknown_ns)) / 1000000 }), theme.text);
        }
        try r.textFit(font, b.x + 14, b.y + b.h - 34, b.w - 28, if (view.message.len > 0) view.message else if (view.unread_possible) "Collection ended with unread records possible; rejected count excludes that uncounted suffix." else "Uses the flame timeline's thread/time filter. Missing endpoints have no duration; overlap does not identify a wait cause.", theme.weak);
    }
};
