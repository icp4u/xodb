//! Shared look metrics. Layout and input use the same rectangles and priorities.
const std = @import("std");
pub const Density = enum { auto, normal, compact };
pub const minimum = .{ .width = 640, .height = 400 };
pub const Metrics = struct {
    font: f32 = 16,
    gap: f32 = 8,
    toolbar_height: f32 = 29,
    row: f32 = 25,
};
pub const normal = Metrics{};
pub const compact = Metrics{ .font = 14, .gap = 6, .toolbar_height = 27, .row = 22 };
pub const overflow = .{ .width = 250, .top = 86, .row = 32, .height = 30, .margin = 10 };
pub const tooltip = .{ .margin = 12, .padding = 10, .top = 90, .row = 22 };
pub const overview = .{ .header = 52, .footer = 28, .footer_small = 52, .small_width = 1280, .nav = 196, .nav_wide = 236, .line = 22, .service_columns = [_]f32{ 92, 88, 44, 96, 72, 88 } };
pub fn compactFor(density: Density, width: f32, previous: bool) bool {
    return switch (density) {
        .normal => false,
        .compact => true,
        .auto => width < (if (previous) @as(f32, 1040) else 960),
    };
}
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    pub fn contains(self: Rect, x: f32, y: f32) bool {
        return self.w > 0 and self.h > 0 and x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};
pub const Pane = enum { source, assembly, registers, threads, stack, events };
pub const pane_names = [_][]const u8{ "Source", "Assembly", "Values", "Threads", "Stack", "Events" };
pub const pane_tab_keys = [_][]const u8{ "1", "2", "3", "4", "5", "6" };
pub const pane_keys = [_][]const u8{ "Alt+1", "Alt+2", "Alt+3", "Alt+4", "Alt+5", "Alt+6" };
pub const give_way = [_]Pane{ .events, .registers, .stack, .threads, .assembly };
pub const pane_min = [_]Rect{
    .{ .w = 360, .h = 180 }, .{ .w = 300, .h = 180 }, .{ .w = 260, .h = 180 },
    .{ .w = 160, .h = 140 }, .{ .w = 280, .h = 140 }, .{ .w = 380, .h = 140 },
};
pub const Action = struct { label: []const u8, key: []const u8, code: u32, x: f32, w: f32, priority: u8 };
pub const actions = [_]Action{
    .{ .label = "Continue", .key = "SPACE", .code = 57, .x = 18, .w = 174, .priority = 0 },
    .{ .label = "Detach", .key = "Shift+D", .code = 32, .x = 200, .w = 166, .priority = 6 },
    .{ .label = "Step", .key = "F11", .code = 87, .x = 375, .w = 104, .priority = 1 },
    .{ .label = "Over", .key = "F10", .code = 68, .x = 485, .w = 110, .priority = 2 },
    .{ .label = "Agent", .key = "F8", .code = 66, .x = 605, .w = 200, .priority = 5 },
    .{ .label = "Watch", .key = "W", .code = 17, .x = 940, .w = 110, .priority = 3 },
    .{ .label = "Flow", .key = "G", .code = 34, .x = 1068, .w = 138, .priority = 4 },
};
pub const Layout = struct {
    panes: [6]Rect = @splat(.{}),
    tabs: [6]Rect = @splat(.{}),
    collapsed: [6]bool = @splat(false),
    toolbar: [actions.len]Rect = @splat(.{}),
    more: Rect = .{},
    processes: Rect = .{},
    flames: Rect = .{},
    body_y: f32 = 91,
    bottom: f32 = 0,
    left: f32 = 0,
    right: f32 = 0,

    pub fn visible(self: Layout, p: Pane) bool {
        return !self.collapsed[@intFromEnum(p)];
    }
    pub fn rect(self: Layout, p: Pane) Rect {
        return self.panes[@intFromEnum(p)];
    }
    pub fn threadFraction(self: *Layout, fraction: f32) void {
        if (!self.visible(.threads) or !self.visible(.stack)) return;
        const end = self.panes[4].x + self.panes[4].w + 4;
        const edge = std.math.clamp(@round(end * fraction), 172, end - 284);
        self.panes[3].w = edge - 12;
        self.panes[4].x = edge;
        self.panes[4].w = end - edge - 4;
    }
    fn fits(self: Layout, width: f32, height: f32) bool {
        // Outer gutters plus inter-pane gaps are part of the fit, not taken
        // from a pane after it has passed its minimum-size check.
        var top: f32 = 10;
        var bottom: f32 = 10;
        for (pane_min, 0..) |m, i| if (!self.collapsed[i]) {
            if (i < 3) top += m.w + 6 else bottom += m.w + 6;
        };
        const has_bottom = self.visible(.threads) or self.visible(.stack) or self.visible(.events);
        const tabs: f32 = if (std.mem.indexOfScalar(bool, &self.collapsed, true) != null) 28 else 0;
        return @max(top, bottom) <= width and 96 + 180 + 37 + tabs + @as(f32, if (has_bottom) 140 else 0) <= height;
    }
    pub fn compute(width: f32, height: f32, split: f32, dense: bool, pinned: ?Pane, watch: bool) Layout {
        var l = Layout{};
        if (width < minimum.width or height < minimum.height) return l;
        l.processes = .{ .x = 91, .y = 8, .w = if (width < 900) 120 else 171, .h = 29 };
        l.flames = .{ .x = if (width < 900) 220 else 380, .y = 8, .w = if (width < 900) 94 else 178, .h = 29 };
        for (give_way) |p| {
            if (l.fits(width, height)) break;
            if (pinned == p or (watch and pinned == null and p == .events)) continue;
            l.collapsed[@intFromEnum(p)] = true;
        }
        // An explicit reopen can temporarily take the whole body. The source
        // is the last tab to give way, and Alt+1 brings it back.
        if (!l.fits(width, height) and ((pinned != null and pinned != .source) or watch)) l.collapsed[@intFromEnum(Pane.source)] = true;
        const has_tabs = std.mem.indexOfScalar(bool, &l.collapsed, true) != null;
        const floor = height - 37 - @as(f32, if (has_tabs) 28 else 0);
        const has_bottom = l.visible(.threads) or l.visible(.stack) or l.visible(.events);
        const has_top = l.visible(.source) or l.visible(.assembly) or l.visible(.registers);
        l.bottom = if (!has_top) 91 else if (has_bottom) std.math.clamp(@round(height * @as(f32, if (watch and height < 640) 0.56 else 0.73)), 96 + pane_min[0].h, floor - pane_min[3].h) else floor;
        const right = if (!l.visible(.source) and !l.visible(.assembly)) 6 else if (l.visible(.registers)) @min(@round(width * 0.79), width - pane_min[2].w - 10) else width - 4;
        const left = if (!l.visible(.source)) 6 else if (l.visible(.assembly)) std.math.clamp(@round(width * split), pane_min[0].w + 12, right - pane_min[1].w - 6) else right;
        l.left = left;
        l.right = right;
        if (l.visible(.source)) l.panes[0] = .{ .x = 8, .y = 91, .w = left - 12, .h = l.bottom - 96 };
        if (l.visible(.assembly)) l.panes[1] = .{ .x = left + 2, .y = 91, .w = right - left - 6, .h = l.bottom - 96 };
        if (l.visible(.registers)) l.panes[2] = .{ .x = right + 2, .y = 91, .w = width - right - 10, .h = l.bottom - 96 };
        const bottom_min = @as(f32, if (l.visible(.threads)) pane_min[3].w + 12 else 8) + @as(f32, if (l.visible(.stack)) pane_min[4].w + 4 else 0);
        const end = if (l.visible(.events) and (l.visible(.threads) or l.visible(.stack))) @max(bottom_min, @min(left, width - pane_min[5].w - 10)) else width - 8;
        const thread_end = if (l.visible(.stack)) @max(172, @round(end * 0.36)) else end;
        if (l.visible(.threads)) l.panes[3] = .{ .x = 8, .y = l.bottom, .w = thread_end - 12, .h = floor - l.bottom };
        const stack_x = if (l.visible(.threads)) thread_end else 8;
        if (l.visible(.stack)) l.panes[4] = .{ .x = stack_x, .y = l.bottom, .w = end - stack_x - 4, .h = floor - l.bottom };
        const event_x = if (l.visible(.threads) or l.visible(.stack)) end + 2 else 8;
        if (l.visible(.events)) l.panes[5] = .{ .x = event_x, .y = l.bottom, .w = width - event_x - 8, .h = floor - l.bottom };
        var tx: f32 = 8;
        for (l.collapsed, 0..) |hidden, i| if (hidden) {
            l.tabs[i] = .{ .x = tx, .y = height - 62, .w = 120, .h = 26 };
            tx += 124;
        };
        const m = if (dense) compact else normal;
        if (width >= 1224 and !dense) {
            for (actions, 0..) |a, i| l.toolbar[i] = .{ .x = a.x, .y = 50, .w = a.w, .h = m.toolbar_height };
        } else {
            var visible_actions = [_]bool{true} ** actions.len;
            var total: f32 = 18 + 90;
            for (actions) |a| total += a.w + m.gap;
            var priority: usize = actions.len;
            while (total > width and priority > 0) {
                priority -= 1;
                for (actions, 0..) |a, i| if (a.priority == priority) {
                    visible_actions[i] = false;
                    total -= a.w + m.gap;
                };
            }
            var x: f32 = 18;
            for (actions, 0..) |a, i| if (visible_actions[i]) {
                l.toolbar[i] = .{ .x = x, .y = 50, .w = a.w, .h = m.toolbar_height };
                x += a.w + m.gap;
            };
            l.more = .{ .x = width - 82, .y = 50, .w = 72, .h = m.toolbar_height };
        }
        return l;
    }
};

test "priority collapse and whole toolbar at supported sizes" {
    for ([_][2]f32{ .{ 1600, 1000 }, .{ 1200, 800 }, .{ 950, 700 }, .{ 800, 500 }, .{ 640, 400 } }) |size| {
        const l = Layout.compute(size[0], size[1], 0.48, false, null, false);
        var previous = true;
        for (give_way) |p| {
            const hidden = l.collapsed[@intFromEnum(p)];
            try std.testing.expect(!hidden or previous);
            previous = hidden;
        }
        for (l.toolbar) |b| try std.testing.expect(b.x + b.w <= size[0]);
        for (l.panes) |b| {
            try std.testing.expect(b.w >= 0 and b.h >= 0);
            try std.testing.expect(b.x + b.w <= size[0] and b.y + b.h <= size[1]);
        }
    }
    try std.testing.expect(compactFor(.auto, 1000, true));
    try std.testing.expect(!compactFor(.auto, 1000, false));
}

test "every resize threshold includes gutters and every pane can be reopened" {
    for (640..1281) |width| {
        for ([_]f32{ 400, 480, 500, 700 }) |height| {
            for (0..14) |choice| {
                const pinned: ?Pane = if (choice % 7 == 6) null else @enumFromInt(choice % 7);
                const l = Layout.compute(@floatFromInt(width), height, 0.48, false, pinned, choice >= 7);
                for (l.panes, 0..) |p, i| {
                    try std.testing.expect(p.w >= 0 and p.h >= 0);
                    try std.testing.expect(p.x + p.w <= @as(f32, @floatFromInt(width)) and p.y + p.h <= height);
                    if (!l.collapsed[i]) {
                        if (p.w < pane_min[i].w or p.h < pane_min[i].h) @import("log.zig").err(.window, "layout minimum: {d}x{d} choice={d} pane={d} actual={d}x{d} minimum={d}x{d}\n", .{ width, height, choice, i, p.w, p.h, pane_min[i].w, pane_min[i].h });
                        try std.testing.expect(p.w >= pane_min[i].w);
                        try std.testing.expect(p.h >= pane_min[i].h);
                    }
                }
                if (pinned) |p| try std.testing.expect(l.visible(p));
            }
        }
    }
    const tiny = Layout.compute(66, 66, 0.48, false, null, false);
    for (tiny.panes) |p| try std.testing.expectEqual(@as(f32, 0), p.w);
}
