//! The MS-DOS 6 DEFRAG / Speed Disk homage as an 80x25 text screen. One
//! composer serves the overview's DOS look (drawn with the GUI font) and the
//! `xodb --memdefrag` terminal, so both show the same characters.
const std = @import("std");
const model = @import("model.zig");
const vga = @import("vga.zig");

pub const Cell = struct { ch: u21 = ' ', fg: u4 = vga.light_grey, bg: u4 = vga.blue, blink: bool = false };

/// Map area inside the double frame.
pub const map_x: usize = 1;
pub const map_y: usize = 2;
pub const map_cols: usize = 78;
pub const map_rows: usize = 15;
pub const map_capacity = map_cols * map_rows;

pub const Screen = struct {
    cells: [vga.rows][vga.cols]Cell = @splat(@splat(.{})),

    pub fn clear(self: *Screen) void {
        self.cells = @splat(@splat(.{}));
    }
    pub fn put(self: *Screen, x: usize, y: usize, ch: u21, fg: u4, bg: u4) void {
        if (x >= vga.cols or y >= vga.rows) return;
        self.cells[y][x] = .{ .ch = ch, .fg = fg, .bg = bg };
    }
    /// Writes UTF-8 text clipped at `limit` columns; returns columns used.
    pub fn textN(self: *Screen, x: usize, y: usize, limit: usize, s: []const u8, fg: u4, bg: u4) usize {
        var it = (std.unicode.Utf8View.init(s) catch return 0).iterator();
        var n: usize = 0;
        while (it.nextCodepoint()) |cp| {
            if (n >= limit) break;
            self.put(x + n, y, if (cp < 32) '?' else cp, fg, bg);
            n += 1;
        }
        return n;
    }
    pub fn text(self: *Screen, x: usize, y: usize, s: []const u8, fg: u4, bg: u4) usize {
        return self.textN(x, y, vga.cols -| x, s, fg, bg);
    }
    pub fn fill(self: *Screen, x0: usize, y0: usize, x1: usize, y1: usize, ch: u21, fg: u4, bg: u4) void {
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) self.put(x, y, ch, fg, bg);
        }
    }
    pub fn box(self: *Screen, x0: usize, y0: usize, x1: usize, y1: usize, double: bool, fg: u4, bg: u4, title: []const u8) void {
        const h: u21 = if (double) '═' else '─';
        const v: u21 = if (double) '║' else '│';
        self.fill(x0 + 1, y0 + 1, x1 - 1, y1 - 1, ' ', fg, bg);
        for (x0 + 1..x1) |x| {
            self.put(x, y0, h, fg, bg);
            self.put(x, y1, h, fg, bg);
        }
        for (y0 + 1..y1) |y| {
            self.put(x0, y, v, fg, bg);
            self.put(x1, y, v, fg, bg);
        }
        self.put(x0, y0, if (double) '╔' else '┌', fg, bg);
        self.put(x1, y0, if (double) '╗' else '┐', fg, bg);
        self.put(x0, y1, if (double) '╚' else '└', fg, bg);
        self.put(x1, y1, if (double) '╝' else '┘', fg, bg);
        if (title.len > 0) {
            const w = std.unicode.utf8CountCodepoints(title) catch title.len;
            const span = x1 - x0 + 1;
            const x = x0 + (span -| (w + 2)) / 2;
            self.put(x, y0, ' ', fg, bg);
            const used = self.textN(x + 1, y0, span -| 4, title, fg, bg);
            self.put(x + 1 + used, y0, ' ', fg, bg);
        }
    }
    /// One row as UTF-8 (tests, plain captures).
    pub fn row(self: *const Screen, y: usize, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.cells[y]) |cell| {
            const len = std.unicode.utf8Encode(cell.ch, buf[n..]) catch break;
            n += len;
        }
        return buf[0..n];
    }
};

pub const Picker = struct { labels: []const []const u8, selected: usize = 0 };
pub const Options = struct {
    /// "pid 1234 proc-abcde" or "System memory".
    label: []const u8 = "System memory",
    elapsed_s: ?f64 = null,
    blink_on: bool = true,
    /// Index of the cell under the cursor (process cells or system cells).
    cursor: ?usize = null,
    /// First visible map row.
    scroll: usize = 0,
    cost: []const u8 = "",
    /// "Refresh 5.0 s (cost-limited)": the data's actual cadence.
    cadence: []const u8 = "",
    hint: []const u8 = "o=Select  t=Look  p=Pause  +/-=Zoom  g=Legend  q=Exit",
    paused: bool = false,
    /// A process was chosen but has no publication yet.
    waiting: bool = false,
    picker: ?Picker = null,
    legend: bool = false,
};
pub const Result = struct { rows: usize, unit: u64, cells: usize };

fn bytesText(buf: []u8, v: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var x: f64 = @floatFromInt(v);
    var i: usize = 0;
    while (x >= 1024 and i + 1 < units.len) : (i += 1) x /= 1024;
    return (if (i == 0 or x >= 100 or @floor(x) == x) std.fmt.bufPrint(buf, "{d:.0} {s}", .{ x, units[i] }) else std.fmt.bufPrint(buf, "{d:.1} {s}", .{ x, units[i] })) catch "?";
}

/// Glyph of model cell `i`, with the cursor shown in reverse.
fn mapGlyph(map: *const model.Map, i: usize) vga.Glyph {
    const cell = map.cells[i];
    return vga.glyph(model.classify(cell), model.writeLike(cell));
}

pub fn compose(scr: *Screen, map: *const model.Map, o: Options) Result {
    scr.clear();
    var buf: [256]u8 = undefined;
    var b2: [64]u8 = undefined;
    // Menu bar.
    scr.fill(0, 0, vga.cols - 1, 0, ' ', vga.black, vga.light_grey);
    var x: usize = 1;
    for ([_][]const u8{ "Optimize", "Analyze", "Configure", "Exit" }) |item| {
        scr.put(x, 0, item[0], vga.red, vga.light_grey);
        _ = scr.text(x + 1, 0, item[1..], vga.black, vga.light_grey);
        x += item.len + 2;
    }
    const brand = "MS-DOS Memory Defrag";
    _ = scr.text(vga.cols - brand.len - 1, 0, brand, vga.black, vga.light_grey);

    // Map frame.
    const system_view = map.process == null and !o.waiting;
    const title = std.fmt.bufPrint(&buf, "{s} · {s}/cell", .{ o.label, if (system_view) "free" else bytesText(&b2, map.cell_bytes) }) catch o.label;
    scr.box(0, 1, vga.cols - 1, 17, true, vga.white, vga.blue, title);
    var result = Result{ .rows = 0, .unit = map.cell_bytes, .cells = 0 };
    var sys_cells: [map_capacity]model.SysCell = undefined;
    var sys_count: usize = 0;
    if (system_view) {
        if (map.system) |*s| if (s.buddy.ok()) {
            const r = model.systemCells(s, map_capacity, &sys_cells);
            sys_count = r.count;
            result.unit = r.unit;
        };
        result.cells = sys_count;
    } else result.cells = map.cells.len;
    result.rows = (result.cells + map_cols - 1) / map_cols;
    const message: ?[]const u8 = blk: {
        if (o.waiting) break :blk "Reading page tables...";
        if (map.process) |p| {
            if (model.processProblem(&b2, p)) |why| break :blk why;
            if (map.cells.len == 0) break :blk if (!p.pages.ok()) p.pages.reason else "No mapped memory";
        }
        if (system_view and sys_count == 0) break :blk if (map.system) |s| (if (!s.buddy.ok()) s.buddy.reason else "No free memory reported") else "Waiting for system counters...";
        break :blk null;
    };
    if (message) |text| {
        const w = @min(text.len, map_cols - 4);
        _ = scr.textN(map_x + (map_cols - w) / 2, map_y + map_rows / 2, w, text, vga.yellow, vga.blue);
    } else for (0..map_rows) |r| for (0..map_cols) |k| {
        const i = (o.scroll + r) * map_cols + k;
        if (i >= result.cells) break;
        var g: vga.Glyph = if (system_view) vga.glyph(.{ .state = sys_cells[i].state }, false) else mapGlyph(map, i);
        if (g.blink and !o.blink_on) g.ch = ' ';
        if (o.cursor == i) {
            const t = g.fg;
            g.fg = if (g.bg == t) vga.black else g.bg;
            g.bg = if (t == vga.blue) vga.white else t;
        }
        scr.put(map_x + k, map_y + r, g.ch, g.fg, g.bg);
        scr.cells[map_y + r][map_x + k].blink = g.blink;
    };
    if (result.rows > map_rows) {
        const shown = std.fmt.bufPrint(&buf, " rows {d}-{d} of {d} ", .{ o.scroll + 1, @min(o.scroll + map_rows, result.rows), result.rows }) catch "";
        _ = scr.text(vga.cols - 2 - shown.len, 17, shown, vga.white, vga.blue);
    }
    if (map.cells_truncated > 0) {
        const cut = std.fmt.bufPrint(&buf, " +{d} cells not built ", .{map.cells_truncated}) catch "";
        _ = scr.text(2, 17, cut, vga.yellow, vga.blue);
    }

    // Status box.
    scr.box(0, 18, 49, 23, false, vga.white, vga.blue, "Status");
    const inner = 46;
    const backend: []const u8 = if (map.process) |p| switch (p.backend) {
        .pagemap_scan => "PAGEMAP_SCAN",
        .pagemap_flags => "pagemap flags",
        .none => "no page states",
    } else "buddyinfo";
    const line1 = blk: {
        if (o.cursor) |i| {
            if (system_view and i < sys_count) break :blk std.fmt.bufPrint(&buf, "Cell: {s} free, {s}", .{ bytesText(&b2, result.unit), model.stateName(sys_cells[i].state) }) catch "";
            if (!system_view and i < map.cells.len) {
                const cell = map.cells[i];
                const look = model.classify(cell);
                break :blk std.fmt.bufPrint(&buf, "Block 0x{x} {s}", .{ cell.start, if (look.change != .none) model.changeName(look.change) else model.stateName(look.state) }) catch "";
            }
        }
        break :blk std.fmt.bufPrint(&buf, "Cluster: 1 cell = {s} {s} · {s}", .{ bytesText(&b2, result.unit), if (system_view) "free" else "block", backend }) catch "";
    };
    _ = scr.textN(2, 19, inner, line1, vga.white, vga.blue);
    var tb: [32]u8 = undefined;
    const elapsed = if (o.elapsed_s) |s| std.fmt.bufPrint(&tb, "{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intFromFloat(s)) / 3600, @as(u64, @intFromFloat(s)) / 60 % 60, @as(u64, @intFromFloat(s)) % 60 }) catch "?" else "--:--:--";
    _ = scr.textN(2, 20, inner, std.fmt.bufPrint(&buf, "Elapsed {s}  {s}", .{ elapsed, o.cadence }) catch "", vga.white, vga.blue);
    // Progress: THP coverage (process) or free memory in >= 2 MiB blocks (system).
    const bar_w = 26;
    switch (model.coverage(map)) {
        .value => |v| {
            const lit: usize = @intFromFloat(@round(v.fraction * bar_w));
            for (0..bar_w) |k| scr.put(2 + k, 21, if (k < lit) '█' else '░', vga.light_cyan, vga.blue);
            const pct = std.fmt.bufPrint(&buf, "{d:>3.0}% {s}", .{ v.fraction * 100, if (system_view) "contiguous" else "complete" }) catch "";
            _ = scr.text(2 + bar_w + 1, 21, pct, vga.white, vga.blue);
        },
        .none => {
            for (0..bar_w) |k| scr.put(2 + k, 21, '·', vga.light_blue, vga.blue);
            _ = scr.textN(2 + bar_w + 1, 21, inner - bar_w - 1, if (system_view) "no free memory" else "nothing eligible", vga.white, vga.blue);
        },
        .unknown => |why| {
            for (0..bar_w) |k| scr.put(2 + k, 21, '▒', vga.dark_grey, vga.light_grey);
            _ = why;
            _ = scr.textN(2 + bar_w + 1, 21, inner - bar_w - 1, "coverage unknown", vga.yellow, vga.blue);
        },
    }
    const act = model.activity(map);
    const act_text = if (act.busy) std.fmt.bufPrint(&buf, "System: {s}... +{d}", .{ act.text, act.count }) catch "" else std.fmt.bufPrint(&buf, "System: {s}", .{act.text}) catch "";
    _ = scr.textN(2, 22, inner, act_text, if (act.busy) vga.yellow else vga.light_grey, vga.blue);

    // Legend box.
    scr.box(50, 18, vga.cols - 1, 23, false, vga.white, vga.blue, "Legend");
    const L = struct {
        fn item(s: *Screen, lx: usize, ly: usize, g: vga.Glyph, label: []const u8) usize {
            s.put(lx, ly, g.ch, g.fg, g.bg);
            return 2 + s.text(lx + 2, ly, label, vga.white, vga.blue) + 1;
        }
    };
    if (system_view) {
        var at: usize = 52;
        at += L.item(scr, at, 19, vga.glyph(.{ .state = .free_contig }, false), "free >=2MiB");
        _ = L.item(scr, at, 19, vga.glyph(.{ .state = .free_frag }, false), "smaller");
        _ = scr.text(52, 20, std.fmt.bufPrint(&buf, "1 cell = {s} free", .{bytesText(&b2, result.unit)}) catch "", vga.white, vga.blue);
        _ = scr.text(52, 21, "counts by block size;", vga.light_grey, vga.blue);
        _ = scr.text(52, 22, "positions need privilege", vga.light_grey, vga.blue);
    } else {
        var at: usize = 52;
        at += L.item(scr, at, 19, vga.glyph(.{ .state = .thp }, false), "THP");
        at += L.item(scr, at, 19, vga.glyph(.{ .state = .anon }, false), "4K");
        _ = L.item(scr, at, 19, vga.glyph(.{ .state = .file }, false), "file");
        at = 52;
        at += L.item(scr, at, 20, vga.glyph(.{ .state = .swapped }, false), "swap");
        at += L.item(scr, at, 20, vga.glyph(.{ .state = .not_present }, false), "absent");
        _ = L.item(scr, at, 20, vga.glyph(.{ .state = .unmovable }, false), "unmov.");
        at = 52;
        at += L.item(scr, at, 21, vga.glyph(.{ .state = .unmapped }, false), "unmapped");
        _ = L.item(scr, at, 21, vga.glyph(.{ .state = .unknown }, false), "unknown");
        at = 52;
        scr.put(at, 22, 'r', vga.white, vga.green);
        scr.put(at + 1, 22, 'W', vga.white, vga.green);
        at += 3 + scr.text(at + 3, 22, "chg", vga.white, vga.blue) + 1;
        at += L.item(scr, at, 22, vga.glyph(.{ .state = .thp, .change = .collapsed }, false), "new");
        _ = L.item(scr, at, 22, vga.glyph(.{ .state = .anon, .change = .split }, false), "split");
    }

    // Bottom status line.
    scr.fill(0, 24, vga.cols - 1, 24, ' ', vga.black, vga.cyan);
    const hint = if (o.paused) "PAUSED  p=Resume  q=Exit" else o.hint;
    const right = o.cost;
    const right_w: usize = @min(right.len, 40);
    const used = scr.textN(1, 24, vga.cols -| (right_w + 4), hint, vga.black, vga.cyan);
    _ = used;
    const rw: usize = @min(right.len, 40);
    if (rw > 0) _ = scr.text(vga.cols - 1 - rw, 24, right[0..rw], vga.black, vga.cyan);

    if (o.picker) |p| picker(scr, p);
    if (o.legend) legend(scr, system_view);
    return result;
}

fn picker(scr: *Screen, p: Picker) void {
    const shown = @min(p.labels.len, 12);
    const y0: usize = 4;
    const y1 = y0 + shown + 3;
    scr.box(14, y0, 65, y1, true, vga.black, vga.light_grey, "Select Process");
    const top = if (p.selected >= shown) p.selected + 1 - shown else 0;
    for (0..shown) |k| {
        const i = top + k;
        if (i >= p.labels.len) break;
        const on = i == p.selected;
        const bg: u4 = if (on) vga.blue else vga.light_grey;
        const fg: u4 = if (on) vga.white else vga.black;
        scr.fill(16, y0 + 1 + k, 63, y0 + 1 + k, ' ', fg, bg);
        _ = scr.textN(17, y0 + 1 + k, 46, p.labels[i], fg, bg);
    }
    _ = scr.text(17, y1 - 1, "Enter=Select  Esc=Cancel  Up/Down", vga.black, vga.light_grey);
}

fn legend(scr: *Screen, system_view: bool) void {
    scr.box(6, 3, 73, if (system_view) 10 else 22, true, vga.black, vga.light_grey, "Legend");
    var y: usize = 4;
    const states = if (system_view) &[_]model.State{ .free_contig, .free_frag } else &[_]model.State{ .thp, .mixed, .anon, .file, .zero, .swapped, .not_present, .unmovable, .unmapped, .gap, .reserved, .unknown };
    for (states) |s| {
        const g = vga.glyph(.{ .state = s }, false);
        scr.put(8, y, g.ch, g.fg, g.bg);
        _ = scr.text(11, y, model.stateName(s), vga.black, vga.light_grey);
        y += 1;
    }
    if (!system_view) {
        for ([_]model.Change{ .changed, .collapsed, .split }) |k| {
            const g = vga.glyph(.{ .state = .thp, .change = k }, true);
            scr.put(8, y, g.ch, g.fg, g.bg);
            if (k == .changed) scr.put(9, y, 'r', g.fg, g.bg);
            _ = scr.text(11, y, model.changeName(k), vga.black, vga.light_grey);
            y += 1;
        }
        _ = scr.text(8, y, "Dark-grey ground: part of the cell unobserved or", vga.black, vga.light_grey);
        _ = scr.text(8, y + 1, "page size unknown. Physical migration: not shown.", vga.black, vga.light_grey);
    } else {
        _ = scr.text(8, y + 1, "Buddy allocator counts per order; no positions.", vga.black, vga.light_grey);
        _ = scr.text(8, y + 2, "Activity text: system-wide vmstat deltas only.", vga.dark_grey, vga.light_grey);
        return;
    }
    _ = scr.text(8, 21, "Activity text: system-wide vmstat deltas only.", vga.dark_grey, vga.light_grey);
}

test "the DOS screen names the menu, frames the map and draws unknown hatched" {
    const B = model.default_cell;
    const cells = [_]model.Cell{
        .{ .start = 0, .end = B, .vma = 0, .mapped = B, .observed = B, .present = B, .huge = B, .known = 15 },
        .{ .start = B, .end = 2 * B, .vma = 0, .mapped = B },
        .{ .start = 2 * B, .end = 3 * B, .vma = 0, .mapped = B, .observed = B, .present = B, .known = 15, .changed = 1, .change_known = 1 },
    };
    const vmas = [_]model.Vma{.{ .start = 0, .end = 3 * B }};
    const map = model.Map{ .process = .{ .pid = 4, .start_ticks = 5, .maps = .{ .state = "ok", .reason = "" }, .coverage_numerator = B }, .vmas = &vmas, .cells = &cells };
    var scr: Screen = .{};
    _ = compose(&scr, &map, .{ .label = "pid 4" });
    var buf: [400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, scr.row(0, &buf), "Optimize  Analyze  Configure  Exit") != null);
    try std.testing.expectEqual(@as(u21, '█'), scr.cells[map_y][map_x].ch);
    try std.testing.expectEqual(@as(u21, '▒'), scr.cells[map_y][map_x + 1].ch);
    try std.testing.expectEqual(@as(u21, 'W'), scr.cells[map_y][map_x + 2].ch);
    try std.testing.expect(scr.cells[map_y][map_x + 2].blink);
    // Unknown denominator: the bar is hatched and says unknown, never 0 %.
    const row21 = scr.row(21, &buf);
    try std.testing.expect(std.mem.indexOf(u8, row21, "unknown") != null and std.mem.indexOf(u8, row21, " 0%") == null);
}
