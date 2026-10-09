//! Read-only imported profile workspace. It never asks the native target for data.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const model = @import("../profile/imported.zig");
const jobs = @import("../profile/imported_job.zig");
const timeline = @import("timeline.zig");
const style = @import("style.zig");
const theme = style.theme;
const Rect = gpu.Rect;
const Hit = struct { rect: Rect, node: u32 };
pub const View = struct {
    timeline: timeline.TimelineView = .{},
    lanes: [1024]timeline.Lane = undefined,
    selected: u32 = 0,
    zoom: u32 = 0,
    scroll: f32 = 0,
    view_id: [64]u8 = @splat(0),
    hits: [2048]Hit = undefined,
    hit_count: usize = 0,
    inspector: bool = false,
    ordinal: ?usize = null,
    stack_scroll: usize = 0,
    stack_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    fn data(self: *View, profile: *const model.Profile) timeline.Data {
        for (profile.threads, 0..) |thread, i| self.lanes[i] = .{ .tid = thread.tid, .debugger_id = thread.tid, .label = thread.name, .samples = thread.times };
        return .{ .capture_id = 1, .revision = 1, .extent_ns = profile.extent_ns, .scheduling = false, .state_label = "imported", .lanes = self.lanes[0..profile.threads.len], .lost_samples = profile.counter("userspace_lost_samples") orelse 0 };
    }
    fn ready(self: *View, state: *jobs.State) ?*const model.View {
        state.gui_filter = self.timeline.filter();
        const view = switch (state.request(self.timeline.filter(), .gui)) {
            .ready => |v| v,
            else => return null,
        };
        if (!std.mem.eql(u8, &self.view_id, &view.id)) {
            self.view_id = view.id;
            self.selected = 0;
            self.zoom = 0;
            self.scroll = 0;
            self.stack_scroll = 0;
            self.ordinal = example(view, 0);
            self.hit_count = 0;
        }
        return view;
    }
    fn example(view: *const model.View, node: usize) ?usize {
        return if (node < view.graph.nodes.items.len and view.examples[node] != std.math.maxInt(usize)) view.examples[node] else null;
    }
    fn publish(self: *View, state: *jobs.State) void {
        state.gui_filter = self.timeline.filter();
        state.gui_sample = if (self.inspector) self.ordinal else null;
        state.gui_selected = self.selected;
        state.gui_zoom = self.zoom;
        state.gui_stack_start = self.stack_scroll;
        state.gui_view_id = null;
        if (state.profile) |profile| {
            const expected = profile.viewId(self.timeline.filter());
            if (std.mem.eql(u8, &expected, &self.view_id)) state.gui_view_id = self.view_id;
        }
    }
    fn moveSample(self: *View, profile: *const model.Profile, direction: i32) void {
        const current = self.ordinal orelse return;
        var next: i64 = @as(i64, @intCast(current)) + direction;
        while (next >= 0 and next < profile.wire.samples.len) : (next += direction) {
            const ordinal: usize = @intCast(next);
            const sample = profile.wire.samples[ordinal];
            if (self.timeline.filter().contains(sample.tid, profile.times[ordinal] - profile.first_ns)) {
                self.ordinal = ordinal;
                self.stack_scroll = 0;
                return;
            }
        }
    }
    pub fn input(self: *View, window: *Window, state: *jobs.State) void {
        if (state.profile) |profile| {
            const d = self.data(profile);
            _ = self.timeline.sync(&d);
        }
        const view = self.ready(state);
        while (window.input.next()) |event| {
            if ((event.kind == .press or event.kind == .repeat) and event.plain()) {
                window.dirty = true;
                switch (event.shortcut) {
                    'q' => if (event.kind == .press and event.mods.shift) {
                        window.closing = true;
                        window.close_reason = .quit_key;
                    },
                    keys.sym.escape => {
                        if (self.inspector) self.inspector = false else state.cancel(.gui);
                    },
                    'r' => state.retry(.gui),
                    'x' => {
                        _ = self.timeline.reset();
                        self.hit_count = 0;
                    },
                    'i' => self.inspector = !self.inspector,
                    'z' => {
                        if (view != null) {
                            self.zoom = self.selected;
                            self.scroll = 0;
                        }
                    },
                    0xff08 => {
                        if (view) |v| {
                            self.zoom = v.graph.nodes.items[self.zoom].parent orelse 0;
                            self.scroll = 0;
                        }
                    },
                    '[' => {
                        if (state.profile) |profile| self.moveSample(profile, -1);
                    },
                    ']' => {
                        if (state.profile) |profile| self.moveSample(profile, 1);
                    },
                    keys.sym.up, 'k' => {
                        if (self.inspector) self.stack_scroll -|= 1 else self.scroll += 24;
                    },
                    keys.sym.down, 'j' => {
                        if (self.inspector) self.stack_scroll += 1 else self.scroll = @max(0, self.scroll - 24);
                    },
                    else => {},
                }
            } else if (event.kind == .button_press and event.code == 0x110) {
                window.dirty = true;
                if (self.timeline.pressModified(event.x, event.y, event.mods.ctrl)) {
                    self.hit_count = 0;
                    continue;
                }
                if (view) |v| for (self.hits[0..self.hit_count]) |hit| {
                    if (inside(hit.rect, event.x, event.y)) {
                        self.selected = hit.node;
                        self.ordinal = example(v, hit.node);
                        self.stack_scroll = 0;
                        break;
                    }
                };
            } else if (event.kind == .button_release and event.code == 0x110) {
                if (self.timeline.release(event.x, event.y)) {
                    self.hit_count = 0;
                    window.dirty = true;
                }
            }
        }
        if (self.timeline.motion(window.pointer_x, window.pointer_y)) window.dirty = true;
        if (window.scroll != 0) {
            window.dirty = true;
            if (!self.timeline.wheel(window.pointer_x, window.pointer_y, window.scroll)) {
                if (self.inspector and inside(self.stack_rect, window.pointer_x, window.pointer_y)) {
                    self.stack_scroll = @intCast(@max(0, @as(i64, @intCast(self.stack_scroll)) + window.scroll));
                } else self.scroll = @max(0, self.scroll + @as(f32, @floatFromInt(window.scroll)) * 18);
            }
            window.scroll = 0;
        }
        // A changed filter invalidates all hit rectangles immediately.
        if (view) |v| {
            if (!std.meta.eql(v.filter, self.timeline.filter())) self.hit_count = 0;
        }
        self.publish(state);
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, window: *Window, state: *jobs.State) !void {
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        const all = Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 42 }, theme.header);
        try label(r, font, 16, 10, width - 32, theme.good, "xodb / Imported simpleperf profile", .{});
        try label(r, font, 16, height - 29, width - 32, theme.weak, "{s}", .{if (self.inspector) "[ ] sample  Up/Down scroll  I close  X all  Shift+Q quit" else "Z zoom  Backspace out  I sample  X all  Shift+Q quit"});
        const profile = state.profile orelse {
            if (state.failure) |err| {
                try label(r, font, 16, 62, width - 32, theme.warm, "Import failed: {s}", .{@errorName(err)});
            } else {
                try label(r, font, 16, 62, width - 32, theme.text, "Loading profile on worker; Esc cancels", .{});
            }
            return;
        };
        const d = self.data(profile);
        _ = self.timeline.sync(&d);
        try label(r, font, 16, 49, width - 32, theme.text, "{s} / {s} / {d} samples / {d} threads", .{ profile.wire.architecture, profile.wire.event, profile.wire.samples.len, profile.threads.len });
        var loss_buffers: [2][32]u8 = undefined;
        try label(r, font, 16, 72, width - 32, theme.weak, "Loss: {s} kernel records, {s} samples / unwind completeness unknown", .{ countLabel(&loss_buffers[0], profile.counter("kernelspace_lost_records")), countLabel(&loss_buffers[1], profile.counter("userspace_lost_samples")) });
        const split = @min(@max(240, height * 0.65), @max(160, height - 200));
        const timeline_bounds = Rect{ .x = 8, .y = split, .w = width - 16, .h = @max(0, height - split - 34) };
        self.timeline.layout(timeline_bounds, &d);
        var bounds = Rect{ .x = 10, .y = 100, .w = width - 20, .h = @max(0, split - 108) };
        const view = self.ready(state) orelse {
            self.hit_count = 0;
            const result = state.request(self.timeline.filter(), .gui);
            switch (result) {
                .failed => |err| try label(r, font, 16, 110, width - 32, theme.warm, "View failed: {s}. R retries; X resets.", .{@errorName(err)}),
                else => try label(r, font, 16, 110, width - 32, theme.text, "Building selected view on worker…", .{}),
            }
            try self.timeline.draw(r, font, timeline_bounds, &d);
            self.publish(state);
            return;
        };
        var weight_buffer: [64]u8 = undefined;
        try label(r, font, 16, bounds.y, width - 32, theme.text, "{d} samples / {s} weight / {d} unresolved stacks", .{ view.samples, weightLabel(&weight_buffer, view.total_period, profile.wire.unit), view.unresolved_samples });
        bounds.y += 26;
        bounds.h -= 26;
        if (self.inspector) {
            if (width >= 1100) {
                bounds.w = (width - 30) * 0.52;
                self.stack_rect = .{ .x = bounds.x + bounds.w + 10, .y = bounds.y, .w = width - bounds.w - 30, .h = bounds.h };
            } else self.stack_rect = bounds;
        } else self.stack_rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!self.inspector or width >= 1100) try self.drawFlames(r, font, bounds, view, profile.wire.unit) else self.hit_count = 0;
        if (self.inspector) try self.drawSample(r, font, profile);
        r.clip = all;
        try self.timeline.draw(r, font, timeline_bounds, &d);
        self.publish(state);
    }
    fn drawFlames(self: *View, r: *gpu.Renderer, font: *Font, bounds: Rect, view: *const model.View, unit: []const u8) !void {
        r.clip = bounds;
        self.hit_count = 0;
        const viewport = Rect{ .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = @max(0, bounds.h - 51) };
        const graph = &view.graph;
        const root = graph.nodes.items[self.zoom];
        var deepest: u16 = root.depth;
        for (graph.nodes.items) |node| deepest = @max(deepest, node.depth);
        self.scroll = std.math.clamp(self.scroll, 0, @max(0, @as(f32, @floatFromInt(deepest - root.depth + 1)) * 24 - viewport.h));
        const denominator: f64 = @floatFromInt(@max(1, if (self.zoom == 0) view.total_period else root.inclusive));
        r.clip = viewport;
        if (view.samples == 0) try label(r, font, viewport.x + 6, viewport.y + 10, viewport.w - 12, theme.weak, "No samples in this selection. X resets.", .{});
        var hidden: usize = 0;
        for (graph.nodes.items) |node| {
            if (node.depth < root.depth or node.x < root.x or node.x + node.inclusive > root.x + root.inclusive or node.inclusive == 0) continue;
            const x = viewport.x + @as(f32, @floatCast(@as(f64, @floatFromInt(node.x - root.x)) / denominator)) * viewport.w;
            const width = @as(f32, @floatCast(@as(f64, @floatFromInt(node.inclusive)) / denominator)) * viewport.w;
            const y = viewport.y + viewport.h - @as(f32, @floatFromInt(node.depth - root.depth + 1)) * 24 + self.scroll;
            if (width < 1 or y + 23 <= viewport.y or y >= viewport.y + viewport.h) continue;
            if (self.hit_count == self.hits.len) {
                hidden += 1;
                continue;
            }
            const rect = Rect{ .x = x, .y = @max(viewport.y, y), .w = width, .h = @min(y + 23, viewport.y + viewport.h) - @max(y, viewport.y) };
            self.hits[self.hit_count] = .{ .rect = rect, .node = node.id };
            self.hit_count += 1;
            const tone: f32 = @as(f32, @floatFromInt(std.hash.Wyhash.hash(0, node.frame.name) % 101)) / 100;
            const color: gpu.Color = switch (node.frame.kind) {
                .code => style.mix(theme.flame_low, theme.flame_high, tone),
                .root, .thread => theme.flame_root,
                else => theme.flame_import_unknown,
            };
            try r.rect(.{ .x = x + 0.5, .y = y, .w = @max(0, width - 1), .h = 23 }, color);
            if (node.id == self.selected) try style.focus(r, .{ .x = x, .y = y, .w = width, .h = 23 }, 2, 1);
            if (width > 35) try r.textFit(font, x + 5, y + 2, width - 10, short(node.frame.name), theme.text);
        }
        r.clip = bounds;
        const selected = graph.nodes.items[self.selected];
        try label(r, font, bounds.x + 4, viewport.y + viewport.h + 5, bounds.w - 8, theme.warm, "{s}", .{short(selected.frame.name)});
        if (view.graph.rejected > 0 or hidden > 0) {
            try label(r, font, bounds.x + 4, viewport.y + viewport.h + 27, bounds.w - 8, theme.warm, "Excluded: {d} samples / {d} {s}; display omitted: {d} bars", .{ view.graph.rejected, view.excluded_period, unit, hidden });
        } else {
            var buffers: [2][64]u8 = undefined;
            try label(r, font, bounds.x + 4, viewport.y + viewport.h + 27, bounds.w - 8, theme.weak, "Inclusive {s} / self {s} / simpleperf labels", .{ weightLabel(&buffers[0], selected.inclusive, unit), weightLabel(&buffers[1], selected.self, unit) });
        }
    }
    fn drawSample(self: *View, r: *gpu.Renderer, font: *Font, profile: *const model.Profile) !void {
        const bounds = self.stack_rect;
        r.clip = bounds;
        try r.rect(bounds, theme.header);
        const ordinal = self.ordinal orelse {
            try label(r, font, bounds.x + 8, bounds.y + 8, bounds.w - 16, theme.weak, "No sample in this selection", .{});
            return;
        };
        const sample = profile.wire.samples[ordinal];
        try label(r, font, bounds.x + 8, bounds.y + 5, bounds.w - 16, theme.good, "Sample {d} / TID {d} / {d} frames / [ ] navigate", .{ ordinal, sample.tid, sample.stack.len });
        try label(r, font, bounds.x + 8, bounds.y + 27, bounds.w - 16, theme.text, "t +{d} ns / {s} {s} / raw reported sites", .{ profile.times[ordinal] - profile.first_ns, sample.period, profile.wire.unit });
        const visible: usize = @intFromFloat(@max(1, @floor((bounds.h - 55) / 44)));
        self.stack_scroll = @min(self.stack_scroll, sample.stack.len -| visible);
        for (sample.stack[self.stack_scroll..@min(sample.stack.len, self.stack_scroll + visible)], self.stack_scroll..) |site, i| {
            const frame = profile.wire.frames[site.frame];
            const y = bounds.y + 55 + @as(f32, @floatFromInt(i - self.stack_scroll)) * 44;
            try label(r, font, bounds.x + 8, y, bounds.w - 16, if (frame.resolved) theme.text else theme.weak, "{d} {s}", .{ i, short(frame.name) });
            try label(r, font, bounds.x + 8, y + 21, bounds.w - 16, theme.weak, "PC {s} / {s} / vaddr {s}", .{ site.ip, short(std.fs.path.basename(profile.wire.modules[frame.module].path)), site.vaddr });
        }
    }
};
fn short(value: []const u8) []const u8 {
    var end = @min(value.len, 512);
    while (end < value.len and end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}
fn countLabel(buffer: []u8, n: ?u64) []const u8 {
    return if (n) |value| std.fmt.bufPrint(buffer, "{d}", .{value}) catch "?" else "unknown";
}
fn inside(rect: Rect, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, value, color);
}

fn weightLabel(buffer: []u8, weight: u64, unit: []const u8) []const u8 {
    return if (std.mem.eql(u8, unit, "nanoseconds")) timeline.duration(buffer, weight) else std.fmt.bufPrint(buffer, "{d} cycles", .{weight}) catch "?";
}
