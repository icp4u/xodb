const std = @import("std");
const model = @import("../profile/agent_time_chart.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const theme = @import("style.zig").theme;
const Hit = struct { rect: gpu.Rect, index: usize };
pub const View = struct {
    selected: usize = 0,
    focus: ?struct { start: f64, end: f64 } = null,
    hits: [8192]Hit = undefined,
    hit_count: usize = 0,
    cache_overlay: bool = false,
    pub fn select(self: *View, x: f32, y: f32) void {
        for (self.hits[0..self.hit_count]) |h| if (x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h) {
            self.selected = h.index;
            return;
        };
    }
    pub fn zoom(self: *View, chart: *const model.Chart, tokens: bool) void {
        const spans = if (tokens) chart.tokens.items else chart.wall.items;
        if (self.selected >= spans.len) return;
        const s = spans[self.selected];
        const radius = @max(0.001, (chart.end - chart.start) * 0.01);
        self.focus = .{ .start = if (s.end > s.start) s.start else s.start - radius, .end = if (s.end > s.start) s.end else s.start + radius };
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, chart: *const model.Chart, tokens: bool, bounds: gpu.Rect, scroll: f32, query: []const u8) !void {
        const spans = if (tokens) chart.tokens.items else chart.wall.items;
        self.hit_count = 0;
        const start = if (self.focus) |f| f.start else chart.start;
        const end = if (self.focus) |f| f.end else chart.end;
        var buffer: [2048]u8 = undefined;
        const header = try std.fmt.bufPrint(&buffer, "Time chart +{d:.2}..{d:.2}s / {s}", .{ start - chart.start, end - chart.start, if (tokens) "token markers: height = log burn; select for count" else "x = elapsed time; parallel activity has separate lanes" });
        try r.textFit(font, bounds.x, bounds.y - 30, bounds.w, header, theme.text);
        if (self.selected < spans.len) {
            const s = spans[self.selected];
            const selected = if (tokens and self.cache_overlay) try std.fmt.bufPrint(&buffer, "Cache read {d:.0}/{d:.0} input / {s}", .{ s.cache_read, s.cache_input, s.label }) else try std.fmt.bufPrint(&buffer, "Selected: {s} / +{d:.3}s / {d:.3}s duration", .{ s.label, s.start - chart.start, s.end - s.start });
            try r.textFit(font, bounds.x, bounds.y + bounds.h + 4, bounds.w, selected, theme.weak);
        }
        r.clip = bounds;
        if (end <= start) return;
        var max_weight: u64 = 1;
        if (tokens) for (spans) |s| {
            max_weight = @max(max_weight, s.weight);
        };
        var culled: usize = 0;
        for (spans, 0..) |s, index| {
            if (s.end < start or s.start > end) continue;
            const y = bounds.y + @as(f32, @floatFromInt(s.depth)) * 27 - scroll;
            if (y < bounds.y or y + 25 > bounds.y + bounds.h) continue;
            if (self.hit_count == self.hits.len) {
                culled += 1;
                continue;
            }
            const x = bounds.x + bounds.w * @as(f32, @floatCast((@max(start, s.start) - start) / (end - start)));
            const width = if (tokens) @as(f32, 3) else @max(1, bounds.w * @as(f32, @floatCast((@min(end, s.end) - @max(start, s.start)) / (end - start))));
            const height = if (tokens) @as(f32, @floatCast(4 + 21 * @log(1 + @as(f64, @floatFromInt(s.weight))) / @log(1 + @as(f64, @floatFromInt(max_weight))))) else @as(f32, 25);
            const rect = gpu.Rect{ .x = x, .y = y + 25 - height, .w = width, .h = height };
            const selected = index == self.selected or (query.len > 0 and std.ascii.indexOfIgnoreCase(s.label, query) != null);
            const hash = std.hash.Wyhash.hash(3, s.label);
            const share: f32 = if (s.cache_input > 0) @floatCast(@max(0, @min(1, s.cache_read / s.cache_input))) else 0;
            const color: gpu.Color = if (selected) .{ 0.9, 0.65, 0.25, 1 } else if (tokens and self.cache_overlay) .{ 0.2, 0.2 + 0.7 * share, 0.25, 1 } else .{ 0.1 + @as(f32, @floatFromInt(hash % 16)) / 100, 0.12 + @as(f32, @floatFromInt((hash >> 8) % 16)) / 100, 0.22, 1 };
            try r.rect(rect, color);
            if (!tokens and width > 30) try r.textFit(font, x + 3, y + 4, width - 6, s.label, if (selected) .{ 0.05, 0.05, 0.05, 1 } else theme.text);
            self.hits[self.hit_count] = .{ .rect = rect, .index = index };
            self.hit_count += 1;
        }
        if (culled > 0 or chart.omitted > 0) {
            const note = try std.fmt.bufPrint(&buffer, "Zoom to inspect: {d} marks hidden at draw limit; {d} omitted by chart limits", .{ culled, chart.omitted });
            try r.textFit(font, bounds.x, bounds.y + bounds.h - 22, bounds.w, note, theme.warm);
        }
    }
};
