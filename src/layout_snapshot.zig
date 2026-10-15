//! Bounded, copied presentation diagnostics; no renderer, session or UI imports.
//! The frame thread publishes after drawing. Observers never dereference GUI state.
const std = @import("std");
const look = @import("look.zig");
fn copyText(out: []u8, text: []const u8) void {
    var n = @min(out.len - 1, text.len);
    while (n > 0 and n < text.len and text[n] & 0xc0 == 0x80) n -= 1;
    @memcpy(out[0..n], text[0..n]);
}
pub const Pane = struct { name: []const u8, key: []const u8, rect: look.Rect, tab: look.Rect, collapsed: bool };
pub const Control = struct { name: []const u8, key: []const u8, rect: look.Rect, overflow: bool = false };
pub const Row = struct {
    pane: []const u8,
    rect: look.Rect,
    label: [96]u8 = @splat(0),
    value: [256]u8 = @splat(0),
    label_elided: bool = false,
    value_elided: bool = false,
    ellipsis: bool = false,
    identifier: bool = false,
    full_text_truncated: bool = false,
    pub fn jsonStringify(self: Row, writer: anytype) !void {
        try writer.write(.{ .pane = self.pane, .rect = self.rect, .label = std.mem.sliceTo(&self.label, 0), .value = std.mem.sliceTo(&self.value, 0), .label_elided = self.label_elided, .value_elided = self.value_elided, .ellipsis = self.ellipsis, .identifier = self.identifier, .full_text_truncated = self.full_text_truncated });
    }
};
pub const Snapshot = struct {
    view: enum { debugger, overview } = .debugger,
    available: bool = false,
    text_overlaps: usize = 0,
    unmarked_text: usize = 0,
    too_small: bool = false,
    revision: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    buffer_width: u32 = 0,
    buffer_height: u32 = 0,
    ui_scale: f32 = 1,
    backing_scale: f32 = 1,
    density: look.Density = .auto,
    compact: bool = false,
    font_size: f32 = 16,
    panes: [6]Pane = undefined,
    pane_count: usize = 0,
    controls: [32]Control = undefined,
    control_count: usize = 0,
    controls_truncated: bool = false,
    rows: [256]Row = undefined,
    row_count: usize = 0,
    rows_truncated: bool = false,
    pub fn control(self: *Snapshot, name: []const u8, key: []const u8, rect: look.Rect, overflow: bool) void {
        if (self.control_count == self.controls.len) {
            self.controls_truncated = true;
            return;
        }
        self.controls[self.control_count] = .{ .name = name, .key = key, .rect = rect, .overflow = overflow };
        self.control_count += 1;
    }
    pub fn row(self: *Snapshot, pane: []const u8, rect: look.Rect, label: []const u8, value: []const u8, label_elided: bool, value_elided: bool, identifier: bool) void {
        if (self.row_count == self.rows.len) {
            self.rows_truncated = true;
            return;
        }
        var entry = Row{ .pane = pane, .rect = rect, .label_elided = label_elided, .value_elided = value_elided, .ellipsis = value_elided, .identifier = identifier, .full_text_truncated = value.len >= 256 or label.len >= 96 };
        copyText(&entry.label, label);
        copyText(&entry.value, value);
        self.rows[self.row_count] = entry;
        self.row_count += 1;
    }
    pub fn jsonStringify(self: *const Snapshot, writer: anytype) !void {
        try writer.write(.{ .view = self.view, .available = self.available, .too_small = self.too_small, .revision = self.revision, .window = .{ .width = self.width, .height = self.height, .buffer_width = self.buffer_width, .buffer_height = self.buffer_height, .ui_scale = self.ui_scale, .backing_scale = self.backing_scale, .minimum_width = look.minimum.width, .minimum_height = look.minimum.height }, .density = self.density, .compact = self.compact, .font_size = self.font_size, .panes = self.panes[0..self.pane_count], .controls = self.controls[0..self.control_count], .rows = self.rows[0..self.row_count], .rows_truncated = self.rows_truncated, .controls_truncated = self.controls_truncated, .text_overlaps = self.text_overlaps, .unmarked_text = self.unmarked_text });
    }
};
var mutex: std.atomic.Mutex = .unlocked;
var current: Snapshot = .{};
pub fn publish(value: *const Snapshot) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();
    const revision = current.revision +% 1;
    current = value.*;
    current.revision = revision;
}
pub fn read(out: *Snapshot) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();
    out.* = current;
}
pub fn unavailable() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
    defer mutex.unlock();
    current.available = false;
    current.pane_count = 0;
    current.control_count = 0;
    current.row_count = 0;
}
