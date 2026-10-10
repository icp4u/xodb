//! Original system-control chrome drawn from rectangles; no platform assets.
const std = @import("std");
const draw = @import("draw.zig");
const vw = @import("view.zig");
const rgb = @import("../../appearance.zig").rgb;
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const View = vw.View;
pub const Menu = enum { file, view, panels, help, start };
pub const Action = enum { file, view, panels, help, start, close_menu, quit, minimize, maximize, redact, about, dismiss, scroll_up, scroll_down, page_up, page_down };
const menu_titles = [_][]const u8{ "File", "View", "Panels", "Help" };
pub const Scroll = struct { track: Rect, thumb_h: f32, thumb_y: f32, grab: f32 = 0, max: usize };
pub fn drag(v: *View) void {
    const scroll = v.classic_scroll orelse return;
    const range = scroll.track.h - scroll.thumb_h;
    if (range <= 0) return;
    const ratio = std.math.clamp((v.pointer[1] - scroll.track.y - scroll.grab) / range, 0, 1);
    const top: usize = @intFromFloat(@round(ratio * @as(f32, @floatFromInt(scroll.max))));
    if (v.panel == .files) v.files.top = top else v.scroll[@intFromEnum(v.panel)] = top;
}
const Item = struct { label: []const u8, action: View.Action };

fn item(menu: Menu, index: usize, v: *const View) Item {
    return switch (menu) {
        .panels, .start => .{ .label = vw.titles[index], .action = .{ .panel = @enumFromInt(index) } },
        .file => ([_]Item{
            .{ .label = "Summary", .action = .{ .panel = .summary } },
            .{ .label = "Processes", .action = .{ .panel = .processes } },
            .{ .label = "Exit", .action = .{ .classic = .quit } },
        })[index],
        .view => ([_]Item{
            .{ .label = if (v.paused) "Resume sampling" else "Pause sampling", .action = .pause },
            .{ .label = "Next theme", .action = .theme },
            .{ .label = if (v.redact) "Redaction enabled" else "Enable redaction", .action = .{ .classic = .redact } },
        })[index],
        .help => .{ .label = "About / keyboard help", .action = .{ .classic = .about } },
    };
}
fn count(menu: Menu) usize {
    return switch (menu) {
        .panels, .start => vw.panel_count,
        .file, .view => 3,
        .help => 1,
    };
}
fn control(v: *View, ctx: Ctx, rect: Rect, label: []const u8, selected: bool, action: View.Action) !void {
    try ctx.button(rect, selected);
    const pad: f32 = if (rect.w < 40) 3 else 8;
    try ctx.textFit(rect.x + pad, rect.y + @floor((rect.h - 20) / 2), rect.w - pad * 2, label, ctx.p.text);
    v.hit(rect, action);
}
/// Small original application icon: three bar-meter columns in a framed square.
fn icon(ctx: Ctx, x: f32, y: f32) !void {
    try ctx.r.rect(.{ .x = x, .y = y, .w = 16, .h = 16 }, rgb(0xffffff));
    try ctx.r.rect(.{ .x = x + 1, .y = y + 1, .w = 14, .h = 14 }, rgb(0x000080));
    for (0..3) |i| {
        const h: f32 = @as(f32, @floatFromInt(i)) * 3 + 4;
        try ctx.r.rect(.{ .x = x + 3 + @as(f32, @floatFromInt(i)) * 4, .y = y + 13 - h, .w = 2, .h = h }, rgb(0x00ff80));
    }
}
fn hourglass(ctx: Ctx, x: f32, y: f32) !void {
    const black = rgb(0x000000);
    try ctx.r.rect(.{ .x = x, .y = y, .w = 14, .h = 2 }, black);
    try ctx.r.rect(.{ .x = x, .y = y + 14, .w = 14, .h = 2 }, black);
    try ctx.poly(&.{ .{ x + 2, y + 3 }, .{ x + 12, y + 3 }, .{ x + 7, y + 8 } }, &.{rgb(0xffffff)});
    try ctx.poly(&.{ .{ x + 7, y + 8 }, .{ x + 12, y + 13 }, .{ x + 2, y + 13 } }, &.{rgb(0xffd060)});
}
pub fn title(ctx: Ctx, rect: Rect, label: []const u8) !void {
    const navy = rgb(0x000080);
    const blue = rgb(0x1084d0);
    try ctx.r.shape(rect, navy, .{ .colors = .{ navy, blue, navy, blue } });
    try ctx.textFit(rect.x + 6, rect.y + 3, rect.w - 12, label, rgb(0xffffff));
}
fn menuBar(v: *View, ctx: Ctx) !void {
    for (menu_titles, 0..) |label, i| {
        const rect = Rect{ .x = 12 + @as(f32, @floatFromInt(i)) * 72, .y = 38, .w = 66, .h = 24 };
        const on = v.classic_menu == @as(Menu, @enumFromInt(i));
        if (on) try ctx.button(rect, true);
        try ctx.text(rect.x + 8, rect.y + 2, label, ctx.p.text);
        v.hit(rect, .{ .classic = @enumFromInt(i) });
    }
}

pub fn chrome(v: *View, ctx: Ctx) !Rect {
    const w = v.width;
    const h = v.height;
    try ctx.r.rect(.{ .x = 0, .y = 0, .w = w, .h = h }, rgb(0x008080));
    if (w < 64 or h < 100) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const frame = Rect{ .x = 6, .y = 6, .w = w - 12, .h = h - 50 };
    try ctx.bevel(frame, false);
    try title(ctx, .{ .x = 10, .y = 10, .w = w - 20, .h = 26 }, "");
    if (v.snap() == null) try hourglass(ctx, 15, 15) else try icon(ctx, 15, 15);
    try ctx.textFit(39, 13, w - 144, "xodb overview", rgb(0xffffff));
    const caption = [_]struct { label: []const u8, action: Action, hint: []const u8 }{
        .{ .label = "_", .action = .minimize, .hint = "Minimize window" },
        .{ .label = "□", .action = .maximize, .hint = "Maximize / restore window" },
        .{ .label = "×", .action = .quit, .hint = "Close overview" },
    };
    for (caption, 0..) |cap, i| {
        const rect = Rect{ .x = w - 86 + @as(f32, @floatFromInt(i)) * 24, .y = 13, .w = 22, .h = 20 };
        try control(v, ctx, rect, cap.label, false, .{ .classic = cap.action });
        v.hover(rect, "{s}", .{cap.hint});
    }
    try menuBar(v, ctx);
    const nav_w: f32 = if (w >= 760) 180 else 0;
    if (nav_w > 0) {
        const nav = Rect{ .x = 12, .y = 70, .w = nav_w, .h = @max(0, h - 146) };
        try ctx.bevel(nav, true);
        const row_h = @min(29, @floor((nav.h - 8) / vw.panel_count));
        if (row_h >= 20) for (vw.titles, 0..) |label, i| {
            const rect = Rect{ .x = nav.x + 5, .y = nav.y + 4 + @as(f32, @floatFromInt(i)) * row_h, .w = nav.w - 10, .h = row_h - 2 };
            const panel: vw.Panel = @enumFromInt(i);
            try control(v, ctx, rect, label, v.panel == panel, .{ .panel = panel });
            v.hover(rect, "Open {s}", .{label});
        };
    }
    const x = nav_w + 20;
    // Property-sheet tab and its raised page edge.
    const tab = Rect{ .x = x, .y = 66, .w = @min(w - x - 16, ctx.measure(vw.titles[@intFromEnum(v.panel)]) + 30), .h = 27 };
    try ctx.bevel(.{ .x = x, .y = 90, .w = @max(0, w - x - 14), .h = @max(0, h - 164) }, false);
    try ctx.bevel(tab, false);
    try ctx.r.rect(.{ .x = tab.x + 2, .y = tab.y + tab.h - 2, .w = @max(0, tab.w - 4), .h = 4 }, ctx.p.panel);
    try ctx.textFit(tab.x + 12, tab.y + 4, tab.w - 24, vw.titles[@intFromEnum(v.panel)], ctx.p.text);
    var status_buf: [100]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buf, "{s}{s}{s}", .{ v.source_label, if (v.paused) "  PAUSED" else "", if (v.redact) "  REDACTED" else "" }) catch "";
    try ctx.textRight(w - 22, 68, status, ctx.p.dim);
    // Taskbar with real panel shortcuts and a UTC clock, labelled explicitly.
    const bar = Rect{ .x = 0, .y = h - 40, .w = w, .h = 40 };
    try ctx.bevel(bar, false);
    try control(v, ctx, .{ .x = 5, .y = h - 35, .w = 90, .h = 30 }, "  xodb", v.classic_menu == .start, .{ .classic = .start });
    try icon(ctx, 11, h - 28);
    const tray_w: f32 = if (w >= 760) 302 else 104;
    const tray = Rect{ .x = @max(100, w - tray_w - 6), .y = h - 35, .w = @min(tray_w, w - 106), .h = 30 };
    const shortcuts = [_]vw.Panel{ .summary, .processes, .memory, .files };
    var tx: f32 = 103;
    for (shortcuts) |panel| {
        const bw: f32 = 128;
        if (tx + bw + 6 > tray.x) break;
        try control(v, ctx, .{ .x = tx, .y = h - 35, .w = bw, .h = 30 }, vw.titles[@intFromEnum(panel)], v.panel == panel, .{ .panel = panel });
        tx += bw + 4;
    }
    try ctx.bevel(tray, true);
    var b: [80]u8 = undefined;
    const seconds: u64 = @intCast(@mod(@import("../../c.zig").api.time(null), 86400));
    const time_text = std.fmt.bufPrint(&b, "{d:0>2}:{d:0>2} UTC", .{ @divTrunc(seconds, 3600), @divTrunc(@mod(seconds, 3600), 60) }) catch "";
    try ctx.textRight(tray.x + tray.w - 8, tray.y + 5, time_text, ctx.p.text);
    if (w >= 760) {
        var cpu: [32]u8 = undefined;
        var mem: [32]u8 = undefined;
        const meters = std.fmt.bufPrint(&b, "CPU {s} MEM {s}", .{ vw.format(&cpu, .percent, v.hist.cpu_total.last()), vw.format(&mem, .percent, v.hist.mem_used.last()) }) catch "";
        try ctx.textFit(tray.x + 8, tray.y + 5, tray.w - 100, meters, ctx.p.text);
    }
    v.hover(tray, "Host CPU / memory utilization; current clock in UTC", .{});
    return .{ .x = x + 8, .y = 100, .w = @max(0, w - x - 30), .h = @max(0, h - 182) };
}

/// Where a pull-down opens and its row height. The box always lies inside the
/// window: narrow windows slide it left and short ones squeeze the rows.
pub fn popupRect(menu: Menu, width: f32, height: f32) struct { rect: Rect, row: f32 } {
    const n: f32 = @floatFromInt(count(menu));
    var rh = @min(26, @max(14, (height - 100) / n));
    if (n * rh + 8 > height) rh = @max(0, (height - 8) / n);
    const h = n * rh + 8;
    const w = @min(258, width);
    const x: f32 = if (menu == .start) 5 else 12 + @as(f32, @floatFromInt(@intFromEnum(menu))) * 72;
    const y: f32 = if (menu == .start) height - 40 - h else 62;
    return .{ .rect = .{ .x = @max(0, @min(x, width - w)), .y = @max(0, @min(y, height - h)), .w = w, .h = h }, .row = rh };
}
pub fn popup(v: *View, ctx: Ctx) !void {
    const menu = v.classic_menu orelse return;
    if (v.width < 80 or v.height < 100) return;
    const n = count(menu);
    const place = popupRect(menu, v.width, v.height);
    const rect = place.rect;
    const rh = place.row;
    const x = rect.x;
    const y = rect.y;
    v.hit_count = 0;
    v.hover_len = 0;
    v.hit(.{ .x = 0, .y = 0, .w = v.width, .h = v.height }, .{ .classic = .close_menu });
    try menuBar(v, ctx);
    try ctx.bevel(rect, false);
    for (0..n) |i| {
        const row = Rect{ .x = x + 4, .y = y + 4 + @as(f32, @floatFromInt(i)) * rh, .w = rect.w - 8, .h = rh };
        const selected = i == v.classic_cursor or draw.inside(row, v.pointer[0], v.pointer[1]);
        if (selected) try ctx.r.rect(row, ctx.p.accent);
        const entry = item(menu, i, v);
        try ctx.textFit(row.x + 10, row.y + (rh - 20) / 2, row.w - 20, entry.label, if (selected) rgb(0xffffff) else ctx.p.text);
        v.hit(row, entry.action);
    }
}
pub fn key(v: *View, event: @import("../../platform/input.zig").Event, now: u64) bool {
    if (v.classic_about) {
        if (event.sym == 0xff1b or event.sym == 0xff0d) v.classic_about = false;
        return true;
    }
    if (v.classic_menu) |menu| {
        const n = count(menu);
        switch (event.sym) {
            0xff1b => v.classic_menu = null,
            0xff52 => v.classic_cursor = (v.classic_cursor + n - 1) % n,
            0xff54 => v.classic_cursor = (v.classic_cursor + 1) % n,
            0xff0d, 0xff8d => {
                const action = item(menu, v.classic_cursor, v).action;
                v.classic_menu = null;
                v.activate(action, now);
            },
            else => {},
        }
        return true;
    }
    if (event.sym == 0xffc7 and !v.searching and !v.files.searching and !v.memmap.picker_open) { // F10
        v.classic_menu = .file;
        v.classic_cursor = 0;
        return true;
    }
    return false;
}
pub fn about(v: *View, ctx: Ctx) !void {
    if (!v.classic_about) return;
    v.hit_count = 0;
    v.hover_len = 0;
    const box = Rect{ .x = @max(0, (v.width - 560) / 2), .y = @max(0, (v.height - 230) / 2), .w = @min(v.width, 560), .h = @min(v.height, 230) };
    try ctx.bevel(box, false);
    try title(ctx, .{ .x = box.x + 4, .y = box.y + 4, .w = box.w - 8, .h = 26 }, "About xodb overview");
    try icon(ctx, box.x + 18, box.y + 48);
    const lines = [_][]const u8{ "System overview with live or replay data", "1-9 / 0 / Tab: panels     F10: menu", "t: theme   p: pause   x: redact   q: quit", "Unknown measurements retain their reasons.", "Bitmap type: Spleen, BSD-2-Clause" };
    for (lines, 0..) |line, i| try ctx.textFit(box.x + 48, box.y + 43 + @as(f32, @floatFromInt(i)) * 25, box.w - 64, line, ctx.p.text);
    try control(v, ctx, .{ .x = box.x + box.w - 100, .y = box.y + box.h - 42, .w = 82, .h = 28 }, "OK", false, .{ .classic = .dismiss });
}

/// Buttons/page trough use the same scroll path as wheel input.
pub fn scrollbar(v: *View, ctx: Ctx, rect: Rect, top: usize, total: usize, visible: usize) !void {
    if (rect.h < 48 or total <= visible) return;
    const arrow_h: f32 = 16;
    const track = Rect{ .x = rect.x, .y = rect.y + arrow_h, .w = rect.w, .h = rect.h - 2 * arrow_h };
    // Flat trough in the dither's average tone: one quad at any height.
    try ctx.r.rect(track, rgb(0xdfdfdf));
    const thumb_h = @min(track.h, @max(18, track.h * @as(f32, @floatFromInt(visible)) / @as(f32, @floatFromInt(total))));
    const offset = (track.h - thumb_h) * @as(f32, @floatFromInt(@min(top, total - visible))) / @as(f32, @floatFromInt(total - visible));
    const thumb = Rect{ .x = track.x, .y = track.y + offset, .w = track.w, .h = thumb_h };
    try ctx.bevel(thumb, false);
    v.hit(thumb, .{ .classic_scroll = .{ .track = track, .thumb_h = thumb_h, .thumb_y = thumb.y, .max = total - visible } });
    v.hit(.{ .x = track.x, .y = track.y, .w = track.w, .h = offset }, .{ .classic = .page_up });
    v.hit(.{ .x = track.x, .y = thumb.y + thumb.h, .w = track.w, .h = track.h - offset - thumb.h }, .{ .classic = .page_down });
    for (0..2) |i| {
        const r = Rect{ .x = rect.x, .y = if (i == 0) rect.y else rect.y + rect.h - arrow_h, .w = rect.w, .h = arrow_h };
        try ctx.bevel(r, false);
        const center = [2]f32{ r.x + r.w / 2, r.y + 8 };
        const direction: f32 = if (i == 0) -1 else 1;
        try ctx.poly(&.{ .{ center[0] - 4, center[1] - direction * 2 }, .{ center[0] + 4, center[1] - direction * 2 }, .{ center[0], center[1] + direction * 3 } }, &.{ctx.p.text});
        v.hit(r, .{ .classic = if (i == 0) .scroll_up else .scroll_down });
    }
}
