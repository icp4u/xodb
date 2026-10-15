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
pub const compact = Metrics{ .font = 14, .gap = 6, .toolbar_height = 27, .row = 24 };
pub const workspace = .{ .code_row = 23, .local_row = 48, .local_focus = 47, .source_y = frame.body_y + 44, .pseudo_qualification_y = 39, .focus_top = 2, .footer_text = 23 };
pub const frame = .{
    .margin = 8,
    .pane_gap = 6,
    .split_inset = 4,
    .split_border = 2,
    .body_y = 91,
    .content_bottom_inset = 5,
    .footer = 37,
    .tab_strip = 28,
    .tab_bottom = 62,
    .tab_width = 120,
    .tab_height = 26,
    .tab_gap = 4,
    .header_breakpoint = 900,
    .toolbar_breakpoint = 1224,
    .watch_breakpoint = 640,
    .process_x = 91,
    .process_width = 171,
    .process_small = 120,
    .flame_x = 380,
    .flame_small_x = 220,
    .flame_width = 178,
    .flame_small = 94,
    .header_y = 8,
    .header_height = 29,
    .toolbar_y = 50,
    .toolbar_x = 18,
    .more_width = 72,
    .more_margin = 10,
    .more_reserve = 90,
    .values_fraction = 0.79,
    .bottom_fraction = 0.73,
    .watch_fraction = 0.56,
    .thread_fraction = 0.36,
};
pub const overflow = .{ .width = 250, .top = 86, .row = 32, .height = 30, .margin = 10 };
pub const tooltip = .{ .margin = 12, .padding = 10, .top = 90, .row = 22 };
pub const overview = .{ .header = 52, .footer = 28, .footer_small = 52, .small_width = 1280, .nav = 196, .nav_wide = 236, .line = 22, .service_columns = [_]f32{ 92, 88, 44, 96, 72, 88 } };
pub const memory = struct {
    pub const gap: f32 = 10;
    pub const composition: f32 = 214;
    pub const middle: f32 = 150;
    pub const middle_compact: f32 = 120;
    pub const history_min: f32 = 116;
    pub const compact_below: f32 = 450;
    pub fn middleHeight(height: f32) f32 {
        return @min(middle, @max(middle_compact, height - composition - 2 * gap - history_min));
    }
};
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
pub const pane_tab_names = [_][]const u8{ "Src", "Asm", "Vals", "Thr", "Stack", "Evts" };
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
    body_y: f32 = frame.body_y,
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
        const end = self.panes[4].x + self.panes[4].w + frame.split_inset;
        const edge = std.math.clamp(@round(end * fraction), pane_min[3].w + frame.margin + frame.split_inset, end - pane_min[4].w - frame.split_inset);
        self.panes[3].w = edge - frame.margin - frame.split_inset;
        self.panes[4].x = edge;
        self.panes[4].w = end - edge - frame.split_inset;
    }
    fn fits(self: Layout, width: f32, height: f32) bool {
        // Outer gutters plus inter-pane gaps are part of the fit, not taken
        // from a pane after it has passed its minimum-size check.
        var top: f32 = frame.margin + frame.split_border;
        var bottom = top;
        for (pane_min, 0..) |m, i| if (!self.collapsed[i]) {
            if (i < 3) top += m.w + frame.pane_gap else bottom += m.w + frame.pane_gap;
        };
        const has_bottom = self.visible(.threads) or self.visible(.stack) or self.visible(.events);
        const tabs: f32 = if (std.mem.indexOfScalar(bool, &self.collapsed, true) != null) frame.tab_strip else 0;
        return @max(top, bottom) <= width and frame.body_y + frame.content_bottom_inset + pane_min[0].h + frame.footer + tabs + @as(f32, if (has_bottom) pane_min[3].h else 0) <= height;
    }
    pub fn compute(width: f32, height: f32, split: f32, dense: bool, pinned: ?Pane, watch: bool) Layout {
        var l = Layout{};
        const g = frame;
        const edge = g.margin + g.split_border;
        const first_inset = g.margin + g.split_inset;
        const content_bottom = g.body_y + g.content_bottom_inset;
        if (width < minimum.width or height < minimum.height) return l;
        l.processes = .{ .x = g.process_x, .y = g.header_y, .w = if (width < g.header_breakpoint) g.process_small else g.process_width, .h = g.header_height };
        l.flames = .{ .x = if (width < g.header_breakpoint) g.flame_small_x else g.flame_x, .y = g.header_y, .w = if (width < g.header_breakpoint) g.flame_small else g.flame_width, .h = g.header_height };
        for (give_way) |p| {
            if (l.fits(width, height)) break;
            if (pinned == p or (watch and pinned == null and p == .events)) continue;
            l.collapsed[@intFromEnum(p)] = true;
        }
        // An explicit reopen can temporarily take the whole body. The source
        // is the last tab to give way, and Alt+1 brings it back.
        if (!l.fits(width, height) and ((pinned != null and pinned != .source) or watch)) l.collapsed[@intFromEnum(Pane.source)] = true;
        const has_tabs = std.mem.indexOfScalar(bool, &l.collapsed, true) != null;
        const floor = height - g.footer - @as(f32, if (has_tabs) g.tab_strip else 0);
        const has_bottom = l.visible(.threads) or l.visible(.stack) or l.visible(.events);
        const has_top = l.visible(.source) or l.visible(.assembly) or l.visible(.registers);
        l.bottom = if (!has_top) g.body_y else if (has_bottom) std.math.clamp(@round(height * @as(f32, if (watch and height < g.watch_breakpoint) g.watch_fraction else g.bottom_fraction)), content_bottom + pane_min[0].h, floor - pane_min[3].h) else floor;
        const right = if (!l.visible(.source) and !l.visible(.assembly)) g.pane_gap else if (l.visible(.registers)) @min(@round(width * g.values_fraction), width - pane_min[2].w - edge) else width - g.split_inset;
        const left = if (!l.visible(.source)) g.pane_gap else if (l.visible(.assembly)) std.math.clamp(@round(width * split), pane_min[0].w + first_inset, right - pane_min[1].w - g.pane_gap) else right;
        l.left = left;
        l.right = right;
        if (l.visible(.source)) l.panes[0] = .{ .x = g.margin, .y = g.body_y, .w = left - first_inset, .h = l.bottom - content_bottom };
        if (l.visible(.assembly)) l.panes[1] = .{ .x = left + g.split_border, .y = g.body_y, .w = right - left - g.pane_gap, .h = l.bottom - content_bottom };
        if (l.visible(.registers)) l.panes[2] = .{ .x = right + g.split_border, .y = g.body_y, .w = width - right - edge, .h = l.bottom - content_bottom };
        const bottom_min = @as(f32, if (l.visible(.threads)) pane_min[3].w + first_inset else g.margin) + @as(f32, if (l.visible(.stack)) pane_min[4].w + g.split_inset else 0);
        const end = if (l.visible(.events) and (l.visible(.threads) or l.visible(.stack))) @max(bottom_min, @min(left, width - pane_min[5].w - edge)) else width - g.margin;
        const thread_end = if (l.visible(.stack)) @max(pane_min[3].w + first_inset, @round(end * g.thread_fraction)) else end;
        if (l.visible(.threads)) l.panes[3] = .{ .x = g.margin, .y = l.bottom, .w = thread_end - first_inset, .h = floor - l.bottom };
        const stack_x = if (l.visible(.threads)) thread_end else g.margin;
        if (l.visible(.stack)) l.panes[4] = .{ .x = stack_x, .y = l.bottom, .w = end - stack_x - g.split_inset, .h = floor - l.bottom };
        const event_x = if (l.visible(.threads) or l.visible(.stack)) end + g.split_border else g.margin;
        if (l.visible(.events)) l.panes[5] = .{ .x = event_x, .y = l.bottom, .w = width - event_x - g.margin, .h = floor - l.bottom };
        var tx: f32 = g.margin;
        for (l.collapsed, 0..) |hidden, i| if (hidden) {
            l.tabs[i] = .{ .x = tx, .y = height - g.tab_bottom, .w = g.tab_width, .h = g.tab_height };
            tx += g.tab_width + g.tab_gap;
        };
        const m = if (dense) compact else normal;
        if (width >= g.toolbar_breakpoint and !dense) {
            for (actions, 0..) |a, i| l.toolbar[i] = .{ .x = a.x, .y = g.toolbar_y, .w = a.w, .h = m.toolbar_height };
        } else {
            var visible_actions = [_]bool{true} ** actions.len;
            var total: f32 = g.toolbar_x + g.more_reserve;
            for (actions) |a| total += a.w + m.gap;
            var priority: usize = actions.len;
            while (total > width and priority > 0) {
                priority -= 1;
                for (actions, 0..) |a, i| if (a.priority == priority) {
                    visible_actions[i] = false;
                    total -= a.w + m.gap;
                };
            }
            var x: f32 = g.toolbar_x;
            for (actions, 0..) |a, i| if (visible_actions[i]) {
                l.toolbar[i] = .{ .x = x, .y = g.toolbar_y, .w = a.w, .h = m.toolbar_height };
                x += a.w + m.gap;
            };
            l.more = .{ .x = width - g.more_width - g.more_margin, .y = g.toolbar_y, .w = g.more_width, .h = m.toolbar_height };
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

test "small memory layout reserves history and all pressure rows" {
    for ([_]f32{ 470, 700 }) |height| {
        const history = height - memory.composition - memory.middleHeight(height) - 2 * memory.gap;
        try std.testing.expect(history >= memory.history_min);
    }
    try std.testing.expectEqual(@as(f32, 150), memory.middleHeight(700));
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
