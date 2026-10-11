//! Recorded and reconstructed sample stacks from immutable owner display data.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const style = @import("style.zig");
const theme = style.theme;
const model = @import("../model/sample_view.zig");
const Filter = @import("../profile/capture.zig").Filter;
pub const Inspector = struct {
    open: bool = false,
    ordinal: usize = std.math.maxInt(usize),
    session: u64 = 0,
    capture: u64 = 0,
    scroll: usize = 0,
    max_scroll: usize = 0,
    view: ?model.View = null,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    pub fn scrollBy(self: *Inspector, delta: i32) void {
        self.scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.scroll)) + delta, 0, @as(i64, @intCast(self.max_scroll))));
    }
    pub fn request(self: *const Inspector, filter: Filter) ?model.Request {
        if (!self.open) return null;
        return .{ .session = self.session, .capture = self.capture, .ordinal = self.ordinal, .filter = filter };
    }
    pub fn present(self: *Inspector, value: ?model.View, filter: Filter) void {
        self.view = null;
        const incoming = value orelse return;
        const wanted = self.request(filter) orelse return;
        if (!std.meta.eql(filter, incoming.normalized.filter)) return;
        const replaced = self.session != incoming.normalized.session or self.capture != incoming.normalized.capture;
        self.view = incoming; // Navigation identities remain useful while detail is pending.
        if (!replaced and !std.meta.eql(wanted, incoming.request) and !std.meta.eql(wanted, incoming.normalized)) return;
        if (replaced or self.ordinal != incoming.normalized.ordinal) self.scroll = 0;
        self.session = incoming.normalized.session;
        self.capture = incoming.normalized.capture;
        self.ordinal = incoming.normalized.ordinal;
        self.view = incoming;
    }
    /// Navigation uses ordinal identities, never recorded evidence. Repeated
    /// inputs can advance while details for an earlier ordinal are in flight.
    pub fn step(self: *Inspector, filter: Filter, delta: i32) void {
        const view = self.view orelse return;
        if (!std.meta.eql(filter, view.normalized.filter)) return;
        if (delta == 0 or view.matching.len == 0) return;
        if (delta > 0) {
            for (view.matching) |ordinal| if (ordinal > self.ordinal) {
                self.ordinal = ordinal;
                self.scroll = 0;
                return;
            };
        } else {
            var i = view.matching.len;
            while (i > 0) {
                i -= 1;
                if (view.matching[i] < self.ordinal) {
                    self.ordinal = view.matching[i];
                    self.scroll = 0;
                    return;
                }
            }
        }
    }
    pub fn draw(self: *Inspector, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect) !void {
        self.bounds = bounds;
        if (!self.open) return;
        const saved = r.clip;
        defer r.clip = saved;
        r.clip = bounds;
        try style.shadow(r, bounds, 8, 0.7);
        try style.box(r, bounds, theme.surface, theme.border, @splat(8));
        const view = self.view orelse {
            try r.textFit(font, bounds.x + 14, bounds.y + 10, bounds.w - 28, "Preparing the selected sample", theme.weak);
            return;
        };
        if (self.ordinal != view.normalized.ordinal) {
            try r.textFit(font, bounds.x + 14, bounds.y + 10, bounds.w - 28, "Preparing the selected sample", theme.weak);
            return;
        }
        if (view.diagnostic) |line| {
            try r.textFit(font, bounds.x + 14, bounds.y + bounds.h - 44, bounds.w - 28, line.text, toneColor(line.tone));
        }
        const n = view.count;
        if (self.ordinal >= n) {
            try r.textFit(font, bounds.x + 14, bounds.y + 10, bounds.w - 28, "SAMPLE: none in the current selection (I / Esc closes)", theme.weak);
            return;
        }
        const w = bounds.w - 28;
        var y = bounds.y + 9;
        try r.textFit(font, bounds.x + 14, y, w, view.heading, theme.text);
        y += 22;
        try r.textFit(font, bounds.x + 14, y, w, view.identity, theme.weak);
        y += 20;
        try r.textFit(font, bounds.x + 14, y, w, view.state, theme.weak);
        y += 20;
        try r.textFit(font, bounds.x + 14, y, w, view.pc, theme.text);
        y += 24;
        if (view.jit) |line| {
            try r.textFit(font, bounds.x + 14, y, w, line.text, toneColor(line.tone));
            y += 22;
        }
        try r.rect(.{ .x = bounds.x + 10, .y = y, .w = bounds.w - 20, .h = 1 }, theme.border);
        y += 6;
        const half = (bounds.w - 36) / 2;
        const left = bounds.x + 14;
        const right = left + half + 8;
        try r.textFit(font, left, y, half, "RECORDED kernel callchain", theme.neutral);
        try r.textFit(font, right, y, half, "DERIVED from saved stack + CFI", theme.neutral);
        y += 22;
        const rows: usize = @intFromFloat(@max(0, (bounds.y + bounds.h - y - 66) / 20));
        const derived_count = view.derived.len;
        self.max_scroll = @max(view.recorded.len, derived_count) -| @max(1, rows);
        self.scroll = @min(self.scroll, self.max_scroll);
        const recorded_start = @min(self.scroll, view.recorded.len);
        const derived_start = @min(self.scroll, derived_count);
        try label(r, font, left, bounds.y + bounds.h - 64, half, theme.weak, "{d}-{d} / {d} frames", .{ recorded_start, @min(view.recorded.len, recorded_start + rows), view.recorded.len });
        try label(r, font, right, bounds.y + bounds.h - 64, half, theme.weak, "{d}-{d} / {d} frames", .{ derived_start, @min(derived_count, derived_start + rows), derived_count });
        try r.textFit(font, left, bounds.y + bounds.h - 24, w, "Wheel / Up / Down: frames   [ ]: samples   I / Esc: close", theme.weak);
        for (view.recorded[recorded_start..@min(view.recorded.len, recorded_start + rows)], 0..) |line, i| {
            try r.textFit(font, left, y + @as(f32, @floatFromInt(i)) * 20, half, line.text, toneColor(line.tone));
        }
        if (view.recorded.len == 0) try r.textFit(font, left, y, half, "(no kernel callchain recorded)", theme.weak);
        for (view.derived[derived_start..@min(view.derived.len, derived_start + rows)], 0..) |line, i| {
            try r.textFit(font, right, y + @as(f32, @floatFromInt(i)) * 20, half, line.text, toneColor(line.tone));
        }
        try r.textFit(font, right, y, half, view.result.text, toneColor(view.result.tone));
        try r.textFit(font, right, bounds.y + bounds.h - 44, half, view.terminal.text, toneColor(view.terminal.tone));
    }
};
fn toneColor(tone: model.Tone) gpu.Color {
    return switch (tone) {
        .text => theme.text,
        .weak => theme.weak,
        .warm => theme.warm,
        .good => theme.good,
    };
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    if (width <= 0) return;
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}
