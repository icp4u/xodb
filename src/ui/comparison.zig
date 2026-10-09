//! Full-archive CPU comparison, independent of the ordinary flame selection.
const std = @import("std");
const model = @import("../profile/comparison.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const style = @import("style.zig");
const theme = style.theme;
pub const Panel = struct {
    open: bool = false,
    flames: bool = false,
    scroll: usize = 0,
    zoom: u32 = 0,
    selected: ?u32 = null,
    hits: [512]struct { rect: gpu.Rect, node: u32 } = undefined,
    hit_count: usize = 0,
    pub fn input(self: *Panel, w: *Window, job: *model.Job) void {
        if (w.scroll != 0) {
            self.scrollBy(w.scroll);
            w.scroll = 0;
            w.dirty = true;
        }
        while (w.input.next()) |event| {
            if (event.kind == .button_press and event.code == 0x110) {
                w.dirty = true;
                for (self.hits[0..self.hit_count]) |hit| if (event.x >= hit.rect.x and event.x < hit.rect.x + hit.rect.w and event.y >= hit.rect.y and event.y < hit.rect.y + hit.rect.h) {
                    self.zoom = hit.node;
                    self.selected = hit.node;
                    self.scroll = 0;
                    break;
                };
            }
            if (!event.plain() or (event.kind != .press and event.kind != .repeat)) continue;
            switch (event.shortcut) {
                'q' => if (event.kind == .press and event.mods.shift) {
                    w.closing = true;
                    w.close_reason = .quit_key;
                },
                'v' => self.open = false,
                0xff1b => {
                    if (!job.done.load(.acquire)) job.progress.cancel.store(true, .release);
                    self.open = false;
                },
                'f', 0xff09 => {
                    self.flames = !self.flames;
                    self.scroll = 0;
                },
                'r' => {
                    self.flames = false;
                    self.scroll = 0;
                },
                0xff08 => {
                    self.zoom = 0;
                    self.scroll = 0;
                },
                'j', 0xff54 => self.scrollBy(1),
                'k', 0xff52 => self.scrollBy(-1),
                0xff56 => self.scrollBy(12),
                0xff55 => self.scrollBy(-12),
                else => {},
            }
            w.dirty = true;
        }
    }
    fn scrollBy(self: *Panel, amount: i32) void {
        self.scroll = @intCast(std.math.clamp(@as(i64, @intCast(self.scroll)) + amount, 0, @as(i64, if (self.flames) 128 else model.max_nodes)));
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, w: *Window, job: *model.Job) !void {
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        self.hit_count = 0;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 44 }, theme.header);
        try r.textFit(font, 18, 12, width - 36, "CPU COMPARISON   F flames / rankings   V after capture   Backspace reset   Shift+Q quit", theme.text);
        var buffer: [512]u8 = undefined;
        try r.textFit(font, 18, 56, width - 36, std.fmt.bufPrint(&buffer, "Before: {s}", .{job.paths[0]}) catch "Before", theme.weak);
        try r.textFit(font, 18, 80, width - 36, std.fmt.bufPrint(&buffer, "After:  {s}", .{job.paths[1]}) catch "After", theme.weak);
        if (!job.done.load(.acquire)) {
            try r.text(font, 18, 118, "Building comparison... Esc cancels", theme.text);
            return;
        }
        if (job.failure) |err| {
            try r.text(font, 18, 118, @errorName(err), theme.warm);
            return;
        }
        const view = &job.result.?;
        try r.textFit(font, 18, 110, width - 36, std.fmt.bufPrint(&buffer, "Samples {d} -> {d} | lost {d} -> {d} | partial stacks {d} -> {d} | unverified {d} -> {d}", .{ view.totals[0], view.totals[1], job.coverage[0].lost, job.coverage[1].lost, job.coverage[0].partial, job.coverage[1].partial, job.coverage[0].unverified, job.coverage[1].unverified }) catch "", theme.text);
        try r.textFit(font, 18, 138, width - 36, "Changes are percentage points of sample share; they do not measure elapsed time or speedup.", theme.weak);
        if (!self.flames) {
            try r.textFit(font, 18, 178, width - 36, "BEFORE    AFTER     CHANGE       INCLUSIVE CHANGE    FUNCTION / MODULE", theme.focus);
            const visible: usize = @intFromFloat(@max(0, @floor((height - 236) / 26)));
            self.scroll = @min(self.scroll, view.ranking.len -| visible);
            const end = @min(view.ranking.len, self.scroll + visible);
            for (self.scroll..end) |n| {
                const row = view.rows[view.ranking[n]];
                const change = model.delta(row.counts.self, view.totals);
                const y: f32 = 208 + 26 * @as(f32, @floatFromInt(n - self.scroll));
                const label = std.fmt.bufPrint(&buffer, "{d: >6.2}%   {d: >6.2}%   {s}{d:.2} pp      {s}{d:.2} pp", .{ model.share(row.counts.self[0], view.totals[0]), model.share(row.counts.self[1], view.totals[1]), if (change >= 0) "+" else "", change, if (model.delta(row.counts.inclusive, view.totals) >= 0) "+" else "", model.delta(row.counts.inclusive, view.totals) }) catch "";
                try r.textFit(font, 18, y, @min(width - 36, 500), label, if (change > 0) theme.warm else if (change < 0) theme.good else theme.weak);
                if (width > 550) try r.textFit(font, 520, y, width - 538, std.fmt.bufPrint(&buffer, "{s}  {s}  [{s}]", .{ row.name, std.fs.path.basename(row.module), @tagName(row.match) }) catch row.name, theme.text);
            }
        } else {
            try r.textFit(font, 18, 178, width - 36, "Warm: share increased | Green: decreased | Width: larger share per leaf path | Click to zoom", theme.focus);
            const graph = &view.graph;
            const root = graph.nodes.items[self.zoom];
            const available = @max(1, width - 36);
            const unit = available / @as(f32, @floatFromInt(root.inclusive));
            const levels: usize = @intFromFloat(@max(0, @floor((height - 262) / 27)));
            var max_depth: usize = 0;
            for (graph.nodes.items) |node| if (descends(graph, node.id, self.zoom)) {
                max_depth = @max(max_depth, node.depth - root.depth);
            };
            self.scroll = @min(self.scroll, (max_depth + 1) -| levels);
            for (graph.nodes.items, view.counts) |node, count| {
                if (!descends(graph, node.id, self.zoom) or node.depth < root.depth + self.scroll or node.inclusive == 0) continue;
                const depth = node.depth - root.depth - self.scroll;
                if (depth >= levels) continue;
                const rect = gpu.Rect{ .x = 18 + @as(f32, @floatFromInt(node.x - root.x)) * unit, .y = 208 + 27 * @as(f32, @floatFromInt(depth)), .w = @max(0, @as(f32, @floatFromInt(node.inclusive)) * unit - 1), .h = 25 };
                if (rect.w < 1) continue;
                const change = model.delta(count.inclusive, view.totals);
                const fill = style.mix(theme.surface, if (change > 0) theme.warm else if (change < 0) theme.good else theme.focus, @floatCast(0.22 + @min(@abs(change) / 50, 0.5)));
                try r.rect(rect, fill);
                r.clip = rect;
                try r.textFit(font, rect.x + 5, rect.y + 3, rect.w - 10, std.fmt.bufPrint(&buffer, "{s}  {s}{d:.2} pp", .{ node.frame.name, if (change >= 0) "+" else "", change }) catch node.frame.name, theme.text);
                r.clip = all;
                if (self.hit_count < self.hits.len) {
                    self.hits[self.hit_count] = .{ .rect = rect, .node = node.id };
                    self.hit_count += 1;
                }
            }
            if (self.selected) |id| {
                const node = graph.nodes.items[id];
                try r.textFit(font, 18, height - 49, width - 36, std.fmt.bufPrint(&buffer, "{s}  {s}", .{ node.frame.name, node.frame.module }) catch node.frame.name, theme.text);
            }
        }
        try r.textFit(font, 18, height - 25, width - 36, "Full archives. Unique path + symbol matching; unresolved callers are grouped in flames.", theme.weak);
    }
};
fn descends(graph: *const @import("../profile/flame.zig").Graph, id: u32, ancestor: u32) bool {
    var at: ?u32 = id;
    while (at) |n| {
        if (n == ancestor) return true;
        at = graph.nodes.items[n].parent;
    }
    return false;
}
