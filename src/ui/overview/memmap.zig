//! The overview's Memory map panel: one process's virtual memory as a grid of
//! fixed-size cells (default 2 MiB), its THP coverage, and the system-wide
//! buddy fragmentation and THP/compaction activity. Three looks, cycled by
//! `t` on this panel: a Windows 9x "Disk Defragmenter" dialog, the MS-DOS 6
//! DEFRAG text screen (the same 80x25 composer as `xodb --memdefrag`), and a
//! plain modern grid (the seam for the later high-resolution visualiser).
//! Data comes from the shared memory observer; rendering copies a bounded
//! Map under the publication lock and never reads /proc itself.
const std = @import("std");
const c = @import("../../c.zig").api;
const draw = @import("draw.zig");
const vw = @import("view.zig");
const m = @import("model.zig");
pub const md = @import("../../memdefrag/model.zig");
const dos = @import("../../memdefrag/dos.zig");
const vga = @import("../../memdefrag/vga.zig");
const Collector = @import("../../model/system.zig").Collector;
const Font = @import("../../render/font.zig").Font;
const rgb = @import("../../appearance.zig").rgb;
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const Color = draw.Color;
const fade = draw.fade;
const mix = draw.mix;

pub const Look = enum { win9x, dos, modern };
pub const look_names = [_][]const u8{ "Windows 9x Defrag", "MS-DOS DEFRAG", "modern" };
pub const Button = enum { stop, pause, legend, details, close_legend, look, picker };
pub const Click = union(enum) { button: Button, pick: usize, cell: usize, scroll: i32 };
const zooms = [_]u64{ 2 << 20, 512 << 10, 128 << 10, 32 << 10, 8 << 10, 4 << 10 };
const ease_ns: u64 = 420_000_000;
/// The grid never draws more cells than this in one frame (vertex budget).
const max_visible: usize = 11000;

pub const State = struct {
    look: Look = .win9x,
    target: ?md.Identity = null,
    target_since: u64 = 0,
    reader: md.Reader = .{},
    current: ?*md.Owned = null,
    previous: ?*md.Owned = null,
    /// Replay maps belong to the replay sample, not to this state.
    replay_current: ?*const md.Map = null,
    replay_previous: ?*const md.Map = null,
    replay_stopped: bool = false,
    replay_system: md.Map = .{},
    accepted_at: u64 = 0,
    zoom: usize = 0,
    scroll: usize = 0,
    cursor: ?usize = null,
    hover: ?usize = null,
    legend: bool = false,
    compact: bool = false,
    picker_open: bool = false,
    pick: usize = 0,
    picks: [64]md.Identity = undefined,
    pick_count: usize = 0,
    worker_pct: ?f64 = null,
    cost_at: u64 = 0,
    cost_cpu: u64 = 0,
    message: [96]u8 = undefined,
    message_len: usize = 0,
    blink_phase: u64 = 0,
    visible_rows: usize = 1,
    grid_cols: usize = 1,

    pub fn deinit(self: *State) void {
        if (self.current) |p| p.destroy();
        if (self.previous) |p| p.destroy();
        self.current = null;
        self.previous = null;
    }
    pub fn map(self: *const State) ?*const md.Map {
        if (self.replay_current) |p| {
            if (!self.replay_stopped) return p;
            // Stopped in a replay: the recorded system part only.
            const sv: *md.Map = @constCast(&self.replay_system);
            sv.* = p.*;
            sv.process = null;
            sv.cells = &.{};
            sv.vmas = &.{};
            sv.refresh_ns = p.system_refresh_ns;
            sv.cost_limited = p.system_cost_limited;
            return sv;
        }
        return if (self.current) |p| &p.map else null;
    }
    pub fn prev(self: *const State) ?*const md.Map {
        if (self.replay_current != null) return self.replay_previous;
        return if (self.previous) |p| &p.map else null;
    }
    /// Opens the map of one process (pid + start identity), or the system view.
    pub fn open(self: *State, id: ?md.Identity, now: u64) void {
        if (std.meta.eql(id, self.target)) return;
        self.target = id;
        self.target_since = now;
        self.reader.reset();
        self.cursor = null;
        self.hover = null;
        self.scroll = 0;
        self.zoom = 0;
        self.deinit();
    }

    /// Live: renew demand and copy a newer publication. True when it changed.
    pub fn refresh(self: *State, gpa: std.mem.Allocator, owner: *Collector, now: u64, paused: bool, redact: bool) bool {
        if (paused or self.replay_current != null) return false;
        const observer = owner.memoryObserver() catch return false;
        self.reader.renew(observer, self.target, now);
        const anchor: u64 = if (self.zoom == 0) 0 else blk: {
            const mp = self.map() orelse break :blk 0;
            if (self.cursor) |i| if (i < mp.cells.len) break :blk mp.cells[i].start;
            break :blk if (mp.cells.len > 0) mp.cells[0].start else 0;
        };
        const got = (self.reader.read(gpa, observer, self.target, .{ .cell_bytes = zooms[self.zoom], .anchor = anchor, .redact = redact }) catch null) orelse return false;
        // A process map waits for its first scan; keep the earlier one meanwhile.
        if (self.target != null and got.map.process == null) if (self.current) |cur| if (cur.map.process != null) {
            got.destroy();
            return false;
        };
        // Worker cost over this view's own clock: publications of the process
        // scope and of the system counters interleave, so their stamps differ.
        if (got.map.worker_cpu_ns) |w| {
            if (self.cost_at == 0 or w < self.cost_cpu) {
                self.cost_at = now;
                self.cost_cpu = w;
            } else if (now -| self.cost_at >= 3_000_000_000) {
                self.worker_pct = @as(f64, @floatFromInt(w - self.cost_cpu)) * 100 / @as(f64, @floatFromInt(now - self.cost_at));
                self.cost_at = now;
                self.cost_cpu = w;
            }
        }
        if (self.previous) |p| p.destroy();
        self.previous = self.current;
        self.current = got;
        self.accepted_at = now;
        return true;
    }
    /// Replay: each recorded frame is one publication.
    pub fn acceptReplay(self: *State, map_: *const md.Map, now: u64) void {
        if (self.replay_current) |cur| if (cur.sequence == map_.sequence) return;
        self.costFrom(self.replay_current, map_);
        self.replay_previous = self.replay_current;
        self.replay_current = map_;
        self.accepted_at = now;
        if (self.target == null and !self.replay_stopped) if (map_.process) |p| {
            self.target = .{ .pid = p.pid, .start = p.start_ticks };
        };
    }
    fn costFrom(self: *State, before: ?*const md.Map, after: *const md.Map) void {
        const b = before orelse return;
        const w0 = b.worker_cpu_ns orelse return;
        const w1 = after.worker_cpu_ns orelse return;
        if (after.sampled_ns <= b.sampled_ns or w1 < w0) return;
        self.worker_pct = @as(f64, @floatFromInt(w1 - w0)) * 100 / @as(f64, @floatFromInt(after.sampled_ns - b.sampled_ns));
    }
    pub fn ease(self: *const State, now: u64) f32 {
        if (self.prev() == null or self.accepted_at == 0) return 1;
        const x = std.math.clamp(@as(f32, @floatFromInt(now -| self.accepted_at)) / @as(f32, @floatFromInt(ease_ns)), 0, 1);
        return 1 - (1 - x) * (1 - x) * (1 - x);
    }
    pub fn animating(self: *const State, now: u64) bool {
        return self.ease(now) < 1;
    }
    /// The DOS look blinks changed cells: redraw at the VGA blink rate.
    pub fn waitMs(self: *const State, now: u64) u64 {
        if (self.look != .dos) return 250;
        const into = now % vga.blink_half_ns;
        return @max(1, (vga.blink_half_ns - into) / 1_000_000);
    }
    pub fn tick(self: *State, now: u64) bool {
        if (self.look != .dos) return false;
        const phase = now / vga.blink_half_ns;
        if (phase == self.blink_phase) return false;
        self.blink_phase = phase;
        return true;
    }
    pub fn setMessage(self: *State, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.message, fmt, args) catch return;
        self.message_len = s.len;
    }
    fn zoomTo(self: *State, z: usize) void {
        if (z == self.zoom or self.replay_current != null) return;
        self.zoom = z;
        self.reader.seen_any = false;
        self.scroll = 0;
    }
};

// --- Input ------------------------------------------------------------------------

/// Panel keys; false lets the overview handle the key.
pub fn key(v: *vw.View, event: @import("../../platform/input.zig").Event, now: u64) bool {
    const s = &v.memmap;
    if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return false;
    if (s.picker_open) {
        switch (event.sym) {
            0xff1b => s.picker_open = false,
            0xff0d, 0xff8d => choose(v, s.pick, now),
            0xff52 => s.pick -|= 1,
            0xff54 => s.pick = @min(s.pick + 1, s.pick_count),
            else => return event.shortcut != 'q',
        }
        return true;
    }
    switch (event.sym) {
        0xff52 => return moveCursor(s, -@as(i64, @intCast(s.grid_cols))),
        0xff54 => return moveCursor(s, @intCast(s.grid_cols)),
        0xff51 => return moveCursor(s, -1),
        0xff53 => return moveCursor(s, 1),
        0xff55 => return scrollBy(s, -@as(i64, @intCast(s.visible_rows -| 1))),
        0xff56 => return scrollBy(s, @intCast(s.visible_rows -| 1)),
        0xff1b => {
            if (s.legend) s.legend = false else if (s.cursor != null) s.cursor = null else press(v, .stop, now);
            return true;
        },
        0xff0d, 0xff8d => return true, // no debugger hand-off from here
        else => {},
    }
    switch (event.shortcut) {
        't' => press(v, .look, now),
        'g' => press(v, .legend, now),
        'd' => press(v, .details, now),
        'o' => press(v, .picker, now),
        '=', '+' => s.zoomTo(@min(s.zoom + 1, zooms.len - 1)),
        '-' => s.zoomTo(s.zoom -| 1),
        '[' => stepProcess(v, -1, now),
        ']' => stepProcess(v, 1, now),
        else => return false,
    }
    return true;
}
pub fn click(v: *vw.View, what: Click, now: u64) void {
    const s = &v.memmap;
    switch (what) {
        .button => |b| press(v, b, now),
        .pick => |i| {
            s.pick = i;
            choose(v, i, now);
        },
        .cell => |i| s.cursor = if (s.cursor == i) null else i,
        .scroll => |by| _ = scrollBy(s, by),
    }
}
fn press(v: *vw.View, b: Button, now: u64) void {
    const s = &v.memmap;
    switch (b) {
        .stop => {
            if (s.target) |id| v.setStatus("Stopped observing pid {d}; system memory view", .{id.pid}, now);
            s.open(null, now);
            if (s.replay_current != null) s.replay_stopped = true;
        },
        .pause => {
            v.paused = !v.paused;
            v.setStatus("{s}", .{if (v.paused) "Paused: page scans lapse after their three-second demand" else "Resumed"}, now);
        },
        .legend => s.legend = !s.legend,
        .close_legend => s.legend = false,
        .details => s.compact = !s.compact,
        .look => {
            s.look = @enumFromInt((@intFromEnum(s.look) + 1) % 3);
            v.setStatus("Memory map look: {s}", .{look_names[@intFromEnum(s.look)]}, now);
        },
        .picker => s.picker_open = !s.picker_open,
    }
}
fn choose(v: *vw.View, index: usize, now: u64) void {
    const s = &v.memmap;
    s.picker_open = false;
    if (index == 0) return press(v, .stop, now);
    if (index - 1 >= s.pick_count) return;
    const id = s.picks[index - 1];
    if (v.action_hook == null) {
        if (s.replay_current) |cur| if (cur.process) |p| if (p.pid == id.pid and p.start_ticks == id.start) {
            s.replay_stopped = false;
            s.target = id;
            return;
        };
        v.setStatus("Replay: no memory map was recorded for pid {d}", .{id.pid}, now);
        return;
    }
    s.open(id, now);
    v.setStatus("Memory map for pid {d} (start {d}): page metadata at most once per second", .{ id.pid, id.start }, now);
}
fn stepProcess(v: *vw.View, by: i32, now: u64) void {
    const s = &v.memmap;
    pickList(v);
    const n: i64 = @intCast(s.pick_count + 1);
    s.pick = @intCast(@mod(@as(i64, @intCast(s.pick)) + by, n));
    choose(v, s.pick, now);
}
fn moveCursor(s: *State, by: i64) bool {
    const mp = s.map() orelse return true;
    const count = cellCount(mp);
    if (count == 0) return true;
    const at: i64 = if (s.cursor) |i| @as(i64, @intCast(i)) + by else 0;
    s.cursor = @intCast(std.math.clamp(at, 0, @as(i64, @intCast(count - 1))));
    const row = s.cursor.? / @max(1, s.grid_cols);
    if (row < s.scroll) s.scroll = row;
    if (row >= s.scroll + s.visible_rows) s.scroll = row + 1 - s.visible_rows;
    return true;
}
fn scrollBy(s: *State, by: i64) bool {
    s.scroll = @intCast(@max(0, @as(i64, @intCast(s.scroll)) + by));
    return true;
}
/// Processes Panel: open the selected row's map.
pub fn openSelected(v: *vw.View, now: u64) void {
    const id = v.selected orelse {
        v.setStatus("Select a process first", .{}, now);
        return;
    };
    if (v.findProcess(id) == null) {
        v.setStatus("Process {d} exited; nothing to map", .{id.pid}, now);
        return;
    }
    v.show(.memory_map);
    if (v.action_hook == null) {
        v.setStatus("Replay: memory maps are recorded per replay, not per row", .{}, now);
        return;
    }
    v.memmap.open(.{ .pid = id.pid, .start = id.start }, now);
    v.setStatus("Memory map for pid {d} (start {d}): page metadata at most once per second", .{ id.pid, id.start }, now);
}

/// The picker rows: the system view, then processes by resident memory.
fn pickList(v: *vw.View) void {
    const s = &v.memmap;
    s.pick_count = 0;
    const snap = v.snap() orelse return;
    var order: [512]u32 = undefined;
    var n: usize = 0;
    for (snap.processes, 0..) |p, i| {
        if (p.kernel or p.rss.get() == null or p.rss.get().? == 0) continue;
        if (n == order.len) break;
        order[n] = @intCast(i);
        n += 1;
    }
    std.mem.sort(u32, order[0..n], snap, struct {
        fn less(sn: *const m.Snapshot, a: u32, b: u32) bool {
            return sn.processes[a].rss.get().? > sn.processes[b].rss.get().?;
        }
    }.less);
    for (order[0..@min(n, s.picks.len)]) |i| {
        s.picks[s.pick_count] = .{ .pid = snap.processes[i].pid, .start = snap.processes[i].start };
        s.pick_count += 1;
    }
    // Keep the shown target selected.
    if (s.target) |t| {
        for (s.picks[0..s.pick_count], 0..) |id, k| {
            if (std.meta.eql(id, t)) s.pick = k + 1;
        }
    } else s.pick = 0;
}
fn pickLabel(v: *vw.View, buf: []u8, index: usize) []const u8 {
    const s = &v.memmap;
    if (index == 0) return "System memory (free blocks)";
    const id = s.picks[index - 1];
    const p = v.findProcess(.{ .pid = id.pid, .start = id.start }) orelse return std.fmt.bufPrint(buf, "{d}  (exited)", .{id.pid}) catch "";
    var nb: [24]u8 = undefined;
    var rb: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "{d:>7}  {s:<15} {s:>9}", .{ @as(u32, @intCast(@max(0, p.pid))), vw.processName(v, p, &nb), m.bytes(&rb, @floatFromInt(p.rss.get() orelse 0)) }) catch "";
}

// Reserve the RSS column before fitting PID/name; long names may elide.
fn drawPick(v: *vw.View, ctx: Ctx, r: Rect, index: usize, ink: Color) !void {
    var buf: [128]u8 = undefined;
    if (index == 0) return ctx.textFit(r.x, r.y, r.w, pickLabel(v, &buf, index), ink);
    const id = v.memmap.picks[index - 1];
    const p = v.findProcess(.{ .pid = id.pid, .start = id.start }) orelse
        return ctx.textFit(r.x, r.y, r.w, pickLabel(v, &buf, index), ink);
    var nb: [24]u8 = undefined;
    var rb: [32]u8 = undefined;
    const rss = if (p.rss.get()) |bytes| m.bytes(&rb, @floatFromInt(bytes)) else "—";
    const rss_w = ctx.measure(rss);
    const left = std.fmt.bufPrint(&buf, "{d}  {s}", .{ p.pid, vw.processName(v, p, &nb) }) catch "";
    try ctx.textFit(r.x, r.y, @max(0, r.w - rss_w - 10), left, ink);
    try ctx.textRight(r.x + r.w, r.y, rss, ink);
}

fn cellCount(mp: *const md.Map) usize {
    if (mp.process != null) return mp.cells.len;
    return systemCellsFor(mp).count;
}
var sys_cells: [max_visible]md.SysCell = undefined;
fn systemCellsFor(mp: *const md.Map) struct { count: usize, unit: u64 } {
    const s = mp.system orelse return .{ .count = 0, .unit = md.default_cell };
    if (!s.buddy.ok()) return .{ .count = 0, .unit = md.default_cell };
    const r = md.systemCells(&s, 4096, &sys_cells);
    return .{ .count = r.count, .unit = r.unit };
}

// --- Shared drawing helpers -------------------------------------------------------------

fn hex(x: u24) Color {
    return rgb(x);
}
fn label(v: *vw.View, buf: []u8) []const u8 {
    const s = &v.memmap;
    const mp = s.map();
    if (mp) |x| if (x.process) |p| {
        var ab: [24]u8 = undefined;
        const name = if (v.redact or p.name == null) md.alias(&ab, p.pid, p.start_ticks) else p.name.?;
        return std.fmt.bufPrint(buf, "pid {d} {s}", .{ p.pid, name }) catch "";
    };
    if (s.target) |id| return std.fmt.bufPrint(buf, "pid {d}", .{id.pid}) catch "";
    return "System memory";
}
fn costText(v: *vw.View, buf: []u8) []const u8 {
    const s = &v.memmap;
    const mp = s.map() orelse return "cost: waiting";
    const scan_ms: ?f64 = if (mp.process) |p| @as(f64, @floatFromInt(p.scan_cpu_ns)) / 1e6 else null;
    var wb: [24]u8 = undefined;
    const worker = if (s.worker_pct) |w| std.fmt.bufPrint(&wb, "{d:.2}%", .{w}) catch "?" else "measuring";
    if (v.action_hook == null) return std.fmt.bufPrint(buf, "recorded worker {s} of a core", .{worker}) catch "";
    if (scan_ms) |ms| return std.fmt.bufPrint(buf, "worker {s} of a core · scan {d:.1} ms · copy {d:.2} ms", .{ worker, ms, @as(f64, @floatFromInt(s.reader.copy_ns)) / 1e6 }) catch "";
    return std.fmt.bufPrint(buf, "worker {s} of a core · copy {d:.2} ms", .{ worker, @as(f64, @floatFromInt(s.reader.copy_ns)) / 1e6 }) catch "";
}
/// Replays have no live clock: their age reads "recorded".
fn liveNow(v: *vw.View, now: u64) ?u64 {
    return if (v.action_hook == null) null else now;
}
/// The DOS status line's right side: data age and the worker's cost.
fn costAge(v: *vw.View, mp: *const md.Map, now: u64, buf: []u8) []const u8 {
    var gb: [24]u8 = undefined;
    const age = md.ageText(&gb, md.cadence(mp, liveNow(v, now)));
    if (v.memmap.worker_pct) |w| return std.fmt.bufPrint(buf, "{s} · worker {d:.2}%", .{ age, w }) catch "";
    return std.fmt.bufPrint(buf, "{s} · worker measuring", .{age}) catch "";
}
/// "Refresh 5.0 s (cost-limited) · age 2.1 s": shown in every look.
fn freshness(v: *vw.View, mp: *const md.Map, now: u64, buf: []u8) []const u8 {
    const k = md.cadence(mp, liveNow(v, now));
    var rb: [48]u8 = undefined;
    var gb: [24]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} · {s}", .{ md.cadenceText(&rb, k), md.ageText(&gb, k) }) catch "";
}
fn findPrev(prev: ?*const md.Map, cur: *const md.Map, cell: md.Cell) ?md.Cell {
    const p = prev orelse return null;
    if (p.cell_bytes != cur.cell_bytes) return null;
    var lo: usize = 0;
    var hi: usize = p.cells.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.cells[mid].start < cell.start) lo = mid + 1 else hi = mid;
    }
    if (lo < p.cells.len and p.cells[lo].start == cell.start and p.cells[lo].end == cell.end) return p.cells[lo];
    return null;
}

/// Detail text of one cell: range, VMA, mapping, state, known bits.
fn detail(v: *vw.View, mp: *const md.Map, index: usize, buf: []u8) []const u8 {
    if (mp.process == null) {
        const r = systemCellsFor(mp);
        if (index >= r.count) return "";
        var ub: [32]u8 = undefined;
        const zone = mp.system.?.zones[sys_cells[index].zone];
        return std.fmt.bufPrint(buf, "{s} of free memory in node {d} {s}: {s}; counts by block size, not positions", .{ m.bytes(&ub, @floatFromInt(r.unit)), zone.node, zone.name, md.stateName(sys_cells[index].state) }) catch "";
    }
    if (index >= mp.cells.len) return "";
    const cell = mp.cells[index];
    const look = md.classify(cell);
    var kb: [64]u8 = undefined;
    var sb: [32]u8 = undefined;
    var hb: [32]u8 = undefined;
    const vma: []const u8 = if (cell.vma) |i| vmaText(v, mp.vmas[i]) else "no VMA";
    const perms: []const u8 = if (cell.vma) |i| mp.vmas[i].perms else "";
    const mapped = m.bytes(&sb, @floatFromInt(cell.mapped));
    const state = if (look.change != .none) md.changeName(look.change) else md.stateName(look.state);
    if (cell.gap > 0) return std.fmt.bufPrint(buf, "0x{x}-0x{x} {s} {s} · {s}", .{ cell.start, cell.end, perms, vma, state }) catch "";
    return std.fmt.bufPrint(buf, "0x{x}-0x{x} {s} {s} · {s} mapped, THP {s} · {s} · known: {s}", .{ cell.start, cell.end, perms, vma, mapped, m.bytes(&hb, @floatFromInt(cell.huge)), state, md.knownText(&kb, cell.known) }) catch "";
}

// --- Rendering ------------------------------------------------------------------------

pub fn render(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const s = &v.memmap;
    pickList(v);
    s.hover = null;
    switch (s.look) {
        .win9x => try win9x(v, ctx, rect, now),
        .dos => try dosLook(v, ctx, rect, now),
        .modern => try modern(v, ctx, rect, now),
    }
}

/// Cell colours per look. `t` blends from the previous poll's state.
const Palette = struct {
    state: [md.state_count]Color,
    changed: Color,
    collapsed: Color,
    split: Color,
    hatch: Color,
    hatch_bg: Color,
};
fn win9xPalette() Palette {
    var p: Palette = .{ .state = undefined, .changed = hex(0x10d010), .collapsed = hex(0xffffff), .split = hex(0xff1010), .hatch = hex(0x6a6a6a), .hatch_bg = hex(0xb0b0b0) };
    p.state = .{ hex(0x2a2a2a), hex(0x2a2a2a), hex(0xb8b8b8), hex(0xb0b0b0), hex(0xb8b8b8), hex(0x7c7c7c), hex(0xe8e800), hex(0x00d8d8), hex(0x00d8d8), hex(0x1838d8), hex(0xd00000), hex(0xffffff), hex(0xe8f8f8), hex(0xd8c8f0) };
    return p;
}
fn modernPalette(p: *const @import("theme.zig").Palette) Palette {
    var out: Palette = .{ .state = undefined, .changed = p.ok, .collapsed = p.text, .split = p.crit, .hatch = fade(p.hatch, 0.8), .hatch_bg = fade(p.hatch, 0.25) };
    const weak = mix(p.panel, p.accent, 0.40);
    out.state = .{ fade(p.border, 0.35), fade(p.border, 0.9), fade(p.dim, 0.35), fade(p.hatch, 0.25), fade(p.dim, 0.30), p.dim, p.warn, weak, weak, p.accent, p.crit, p.text, fade(p.text, 0.4), mix(p.panel, p.accent3, 0.45) };
    return out;
}
fn cellColor(pal: *const Palette, look: md.Look) Color {
    if (look.change == .changed) return pal.changed;
    return pal.state[@intFromEnum(look.state)];
}

const Grid = struct {
    area: Rect,
    cols: usize,
    rows: usize,
    visible: usize,
    pitch: f32,
    count: usize,
};
/// The largest square pitch, within bounds, that shows every cell; at the
/// minimum pitch the grid scrolls instead. Never more cells than the budget.
fn layoutGrid(area: Rect, count: usize, min_pitch: f32, max_pitch: f32) Grid {
    const budget = @ceil(@sqrt(area.w * area.h / @as(f32, @floatFromInt(max_visible))));
    const lo = @max(min_pitch, budget);
    var p = @max(lo, max_pitch);
    while (p > lo) : (p -= 1) {
        const cols = @max(1, @floor(area.w / p));
        const rows = @ceil(@as(f32, @floatFromInt(@max(count, 1))) / cols);
        if (rows * p <= area.h) break;
    }
    const cols: usize = @max(1, @as(usize, @intFromFloat(@floor(area.w / p))));
    const visible: usize = @max(1, @as(usize, @intFromFloat(@floor(area.h / p))));
    return .{ .area = area, .cols = cols, .rows = (count + cols - 1) / cols, .visible = visible, .pitch = p, .count = count };
}
/// Height the grid needs at its pitch (all rows, or the area when it scrolls).
fn gridHeight(g: Grid) f32 {
    return @min(g.area.h, @as(f32, @floatFromInt(@min(g.rows, g.visible))) * g.pitch);
}
fn cellRect(g: Grid, row: usize, col: usize) Rect {
    return .{ .x = g.area.x + @as(f32, @floatFromInt(col)) * g.pitch, .y = g.area.y + @as(f32, @floatFromInt(row)) * g.pitch, .w = g.pitch, .h = g.pitch };
}
fn hatchRect(ctx: Ctx, rect: Rect, bg: Color, line: Color, step: f32) !void {
    try ctx.r.rect(rect, bg);
    const saved = ctx.r.clip;
    defer ctx.r.clip = saved;
    ctx.r.clip = draw.intersect(saved, rect);
    var k: f32 = -rect.h;
    while (k < rect.w) : (k += step) try ctx.thin(.{ rect.x + k, rect.y + rect.h }, .{ rect.x + k + rect.h, rect.y }, 1, line);
}

const GridStyle = enum { win9x, modern };
/// Paints the cell grid. Win9x runs equal cells into one quad per run and
/// lays 1 px gridlines over them; modern draws separated tiles.
fn paintGrid(v: *vw.View, ctx: Ctx, g: Grid, mp: *const md.Map, pal: *const Palette, style: GridStyle, now: u64) !void {
    const s = &v.memmap;
    const prev = s.prev();
    const e = s.ease(now);
    const system = mp.process == null;
    const sys = if (system) systemCellsFor(mp) else null;
    s.grid_cols = g.cols;
    s.visible_rows = g.visible;
    if (s.scroll + g.visible > g.rows) s.scroll = g.rows -| g.visible;
    const first_row = s.scroll;
    const last_row = @min(g.rows, first_row + g.visible);
    const gap: f32 = if (style == .modern) @max(1, @round(g.pitch * 0.14)) else 0;
    for (first_row..last_row) |row| {
        var col: usize = 0;
        while (col < g.cols) {
            const i = row * g.cols + col;
            if (i >= g.count) break;
            const look: md.Look = if (system) .{ .state = sys_cells[i].state } else md.classify(mp.cells[i]);
            var color = cellColor(pal, look);
            if (!system and e < 1) if (findPrev(prev, mp, mp.cells[i])) |old| {
                color = mix(cellColor(pal, md.classify(old)), color, e);
            };
            // Extend a run of identical cells (Win9x only).
            var run: usize = 1;
            if (style == .win9x and look.state != .unknown and !look.partial and look.state != .mixed and look.change != .collapsed and look.change != .split and look.state != .gap and look.state != .reserved) {
                while (col + run < g.cols and i + run < g.count) : (run += 1) {
                    const j = i + run;
                    const l2: md.Look = if (system) .{ .state = sys_cells[j].state } else md.classify(mp.cells[j]);
                    if (l2.state != look.state or l2.change != look.change or l2.partial or l2.state == .mixed) break;
                    if (!system and e < 1) if (findPrev(prev, mp, mp.cells[j])) |old| if (md.classify(old).state != md.classify(mp.cells[i]).state or md.classify(old).change != .none) break;
                }
            }
            const r0 = cellRect(g, row - first_row, col);
            const rr = Rect{ .x = r0.x + gap / 2, .y = r0.y + gap / 2, .w = g.pitch * @as(f32, @floatFromInt(run)) - gap, .h = g.pitch - gap };
            if (look.state == .unknown) {
                try hatchRect(ctx, rr, pal.hatch_bg, pal.hatch, @max(3, g.pitch * 0.5));
            } else {
                try ctx.r.rect(rr, color);
                if (look.state == .mixed) {
                    const hf = std.math.clamp(look.huge_fraction, 0.1, 0.9);
                    try ctx.r.rect(.{ .x = rr.x, .y = rr.y + rr.h * (1 - hf), .w = rr.w, .h = rr.h * hf }, pal.state[@intFromEnum(md.State.thp)]);
                }
                if (look.partial) try hatchRect(ctx, rr, fade(color, 0), fade(pal.hatch, 0.7), @max(3, g.pitch * 0.5));
                if (look.state == .gap or look.state == .reserved) {
                    // Compressed range: a small "≈" break mark.
                    const cy = rr.y + rr.h / 2;
                    const mk = fade(if (style == .win9x) hex(0xd0d0d0) else ctx.p.dim, 0.9);
                    try ctx.thin(.{ rr.x + rr.w * 0.2, cy - rr.h * 0.12 }, .{ rr.x + rr.w * 0.8, cy - rr.h * 0.22 }, 1, mk);
                    try ctx.thin(.{ rr.x + rr.w * 0.2, cy + rr.h * 0.18 }, .{ rr.x + rr.w * 0.8, cy + rr.h * 0.08 }, 1, mk);
                }
                if (look.state == .free_frag) try ctx.r.rect(.{ .x = rr.x + rr.w * 0.35, .y = rr.y + rr.h * 0.35, .w = @max(1, rr.w * 0.3), .h = @max(1, rr.h * 0.3) }, hex(0x5a8a8a));
            }
            switch (look.change) {
                .collapsed => {
                    // One-poll highlight: the new THP gets a bright inner ring.
                    try ctx.r.shape(draw.inset(rr, 1), fade(pal.collapsed, 0.95), .{ .border = @max(1, @round(g.pitch * 0.16)) });
                },
                .split => try ctx.r.shape(rr, pal.split, .{ .border = @max(2, @round(g.pitch * 0.22)) }),
                else => {},
            }
            col += run;
        }
    }
    if (style == .win9x) {
        // Gridlines: a dark line closes each cell, a light one bevels it.
        const top = g.area.y;
        const shown_rows = last_row - first_row;
        const h = @as(f32, @floatFromInt(shown_rows)) * g.pitch;
        const w = @as(f32, @floatFromInt(g.cols)) * g.pitch;
        if (shown_rows > 0) {
            for (0..g.cols + 1) |k| {
                const x = g.area.x + @as(f32, @floatFromInt(k)) * g.pitch;
                try ctx.r.rect(.{ .x = x - 1, .y = top, .w = 1, .h = h }, fade(hex(0x000000), 0.85));
                if (k < g.cols) try ctx.r.rect(.{ .x = x, .y = top, .w = 1, .h = h }, fade(hex(0xffffff), 0.28));
            }
            for (0..shown_rows + 1) |k| {
                const y = top + @as(f32, @floatFromInt(k)) * g.pitch;
                try ctx.r.rect(.{ .x = g.area.x, .y = y - 1, .w = w, .h = 1 }, fade(hex(0x000000), 0.85));
                if (k < shown_rows) try ctx.r.rect(.{ .x = g.area.x, .y = y, .w = w, .h = 1 }, fade(hex(0xd8d8d8), 0.55));
            }
        }
        // The partial last row ends like the drive's end: plain face after it.
        if (last_row == g.rows and g.count % g.cols != 0) {
            const tail = g.count % g.cols;
            const r0 = cellRect(g, last_row - 1 - first_row, tail);
            try ctx.r.rect(.{ .x = r0.x, .y = r0.y - 1, .w = g.area.x + w - r0.x + 1, .h = g.pitch + 1 }, hex(0xffffff));
        }
    }
    // Pointer and cursor.
    if (draw.inside(.{ .x = g.area.x, .y = g.area.y, .w = @as(f32, @floatFromInt(g.cols)) * g.pitch, .h = @as(f32, @floatFromInt(last_row - first_row)) * g.pitch }, v.pointer[0], v.pointer[1])) {
        const col: usize = @intFromFloat((v.pointer[0] - g.area.x) / g.pitch);
        const row: usize = @intFromFloat((v.pointer[1] - g.area.y) / g.pitch);
        const i = (first_row + row) * g.cols + col;
        if (i < g.count) s.hover = i;
    }
    for ([_]?usize{ s.hover, s.cursor }, 0..) |which, k| if (which) |i| if (i / g.cols >= first_row and i / g.cols < last_row) {
        const r0 = cellRect(g, i / g.cols - first_row, i % g.cols);
        const outer = Rect{ .x = r0.x - 2, .y = r0.y - 2, .w = r0.w + 3, .h = r0.h + 3 };
        try ctx.r.shape(outer, if (style == .win9x) hex(0x000000) else ctx.p.text, .{ .border = 2 });
        if (k == 1) try ctx.r.shape(draw.inset(outer, 2), hex(0xffff00), .{ .border = 1 });
    };
    if (v.layout != null) audit(g, first_row, @intFromEnum(style));
    // Every visible cell is clickable through one hit region.
    const area = Rect{ .x = g.area.x, .y = g.area.y, .w = @as(f32, @floatFromInt(g.cols)) * g.pitch, .h = @as(f32, @floatFromInt(last_row - first_row)) * g.pitch };
    if (s.hover) |i| v.hit(area, .{ .memmap = .{ .cell = i } });
    _ = sys;
}

/// With the layout audit on, tests learn the grid geometry to aim the pointer.
var audited: [6]f32 = @splat(-1);
fn audit(g: Grid, first_row: usize, style: u32) void {
    const now_ = [6]f32{ g.area.x, g.area.y, g.pitch, @floatFromInt(g.cols), @floatFromInt(first_row), @floatFromInt(style) };
    if (std.mem.eql(f32, &now_, &audited)) return;
    audited = now_;
    std.debug.print("xodb: memmap grid x={d:.1} y={d:.1} pitch={d:.1} cols={d} first_row={d} count={d} style={d}\n", .{ g.area.x, g.area.y, g.pitch, g.cols, first_row, g.count, style });
}
fn auditText(ox: f32, oy: f32, cw: f32, ch: f32) void {
    const now_ = [6]f32{ ox, oy, cw, ch, 0, 9 };
    if (std.mem.eql(f32, &now_, &audited)) return;
    audited = now_;
    std.debug.print("xodb: memmap text x={d:.1} y={d:.1} cw={d:.2} ch={d:.2}\n", .{ ox, oy, cw, ch });
}

/// With the layout audit on, the DOS screen's rows are logged when they change,
/// so tests read the exact characters instead of OCR.
var audited_rows: u64 = 0;
fn auditRows(scr: *const dos.Screen) void {
    var hasher = std.hash.Wyhash.init(0);
    for (scr.cells) |row| for (row) |cell| hasher.update(std.mem.asBytes(&cell.ch));
    const hv = hasher.final();
    if (hv == audited_rows) return;
    audited_rows = hv;
    var buf: [400]u8 = undefined;
    for (0..vga.rows) |y| std.debug.print("xodb: memmap row {d:0>2} {s}\n", .{ y, scr.row(y, &buf) });
}

// --- Windows 9x ------------------------------------------------------------------------

const face = 0xc0c0c0;
fn bevel(ctx: Ctx, r: Rect, raised: bool, thick: bool) !void {
    const tl_outer = if (raised) hex(if (thick) 0xdfdfdf else 0xffffff) else hex(0x808080);
    const br_outer = if (raised) hex(0x000000) else hex(0xffffff);
    try ctx.r.rect(.{ .x = r.x, .y = r.y, .w = r.w, .h = 1 }, tl_outer);
    try ctx.r.rect(.{ .x = r.x, .y = r.y, .w = 1, .h = r.h }, tl_outer);
    try ctx.r.rect(.{ .x = r.x, .y = r.y + r.h - 1, .w = r.w, .h = 1 }, br_outer);
    try ctx.r.rect(.{ .x = r.x + r.w - 1, .y = r.y, .w = 1, .h = r.h }, br_outer);
    const tl_inner = if (raised) hex(if (thick) 0xffffff else 0xdfdfdf) else hex(0x000000);
    const br_inner = if (raised) hex(0x808080) else hex(0xdfdfdf);
    try ctx.r.rect(.{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = 1 }, tl_inner);
    try ctx.r.rect(.{ .x = r.x + 1, .y = r.y + 1, .w = 1, .h = r.h - 2 }, tl_inner);
    try ctx.r.rect(.{ .x = r.x + 1, .y = r.y + r.h - 2, .w = r.w - 2, .h = 1 }, br_inner);
    try ctx.r.rect(.{ .x = r.x + r.w - 2, .y = r.y + 1, .w = 1, .h = r.h - 2 }, br_inner);
}
fn boldText(ctx: Ctx, x: f32, y: f32, w: f32, s: []const u8, color: Color) !void {
    try ctx.textFit(x, y, w, s, color);
    try ctx.r.textFit(ctx.font, @round(x) + 1, @round(y), w, s, color);
}
/// A 9x window: face, bevels and a gradient title bar. Returns the client area.
fn window9x(v: *vw.View, ctx: Ctx, r: Rect, title: []const u8, active: bool, close: ?Click) !Rect {
    // Drop shadow on the desktop.
    try ctx.r.rect(.{ .x = r.x + 4, .y = r.y + 4, .w = r.w, .h = r.h }, fade(hex(0x000000), 0.28));
    try ctx.r.rect(r, hex(face));
    try bevel(ctx, r, true, true);
    const bar = Rect{ .x = r.x + 3, .y = r.y + 3, .w = r.w - 6, .h = 22 };
    const c0 = hex(if (active) 0x000080 else 0x808080);
    const c1 = hex(if (active) 0x1084d0 else 0xb5b5b5);
    try ctx.r.shape(bar, c0, .{ .colors = .{ c0, c1, c0, c1 } });
    // Title icon: a tiny memory chip.
    try ctx.r.rect(.{ .x = bar.x + 4, .y = bar.y + 5, .w = 14, .h = 12 }, hex(0x008000));
    for (0..4) |k| try ctx.r.rect(.{ .x = bar.x + 5 + @as(f32, @floatFromInt(k)) * 3.4, .y = bar.y + 3, .w = 1.5, .h = 16 }, hex(0xe0c000));
    try boldText(ctx, bar.x + 24, bar.y + 1, bar.w - 24 - 58, title, hex(0xffffff));
    // Minimise, maximise, close.
    for (0..3) |k| {
        const bx = bar.x + bar.w - 2 - @as(f32, @floatFromInt(3 - k)) * 18 + (if (k == 2) @as(f32, 2) else 0);
        const b = Rect{ .x = bx, .y = bar.y + 3, .w = 16, .h = 16 };
        try ctx.r.rect(b, hex(face));
        try bevel(ctx, b, true, false);
        const ink = hex(0x000000);
        switch (k) {
            0 => try ctx.r.rect(.{ .x = b.x + 4, .y = b.y + 10, .w = 6, .h = 2 }, ink),
            1 => {
                try ctx.r.shape(.{ .x = b.x + 3, .y = b.y + 3, .w = 9, .h = 9 }, ink, .{ .border = 1 });
                try ctx.r.rect(.{ .x = b.x + 3, .y = b.y + 4, .w = 9, .h = 1 }, ink);
            },
            else => {
                try ctx.thin(.{ b.x + 4, b.y + 4 }, .{ b.x + 11, b.y + 11 }, 1.6, ink);
                try ctx.thin(.{ b.x + 11, b.y + 4 }, .{ b.x + 4, b.y + 11 }, 1.6, ink);
                if (close) |action| v.hit(b, .{ .memmap = action });
            },
        }
    }
    return .{ .x = r.x + 6, .y = bar.y + bar.h + 4, .w = r.w - 12, .h = r.h - (bar.h + 13) };
}
fn button9x(v: *vw.View, ctx: Ctx, r: Rect, text: []const u8, action: Click, pressed: bool) !void {
    try ctx.r.rect(r, hex(face));
    // The default-button frame of the original dialog.
    try ctx.r.shape(r, hex(0x000000), .{ .border = 1 });
    try bevel(ctx, draw.inset(r, 1), !pressed, true);
    const w = ctx.measure(text);
    try ctx.textFit(r.x + @max(4, (r.w - w) / 2) + (if (pressed) @as(f32, 1) else 0), r.y + (r.h - 20) / 2 + (if (pressed) @as(f32, 1) else 0), r.w - 8, text, hex(0x000000));
    v.hit(r, .{ .memmap = action });
}
fn sunken(ctx: Ctx, r: Rect, fill: Color) !void {
    try ctx.r.rect(r, fill);
    try bevel(ctx, r, false, true);
}

fn win9x(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const s = &v.memmap;
    try ctx.r.rect(rect, hex(0x008080));
    const black = hex(0x000000);
    var buf: [256]u8 = undefined;
    var lb: [64]u8 = undefined;
    const name = label(v, &lb);
    const margin: f32 = 16;
    const narrow = rect.w < 1200;
    const side_w: f32 = if (s.compact) 0 else std.math.clamp(rect.w * 0.24, 250, 360);
    if (!s.compact) {
        // Select Process.
        const list_h = @floor((rect.h - 3 * margin) * 0.52);
        const lw = Rect{ .x = rect.x + margin, .y = rect.y + margin, .w = side_w, .h = list_h };
        const client = try window9x(v, ctx, lw, "Select Process", false, null);
        try ctx.textFit(client.x + 2, client.y, client.w - 4, "Which process do you want to defragment?", black);
        const box = Rect{ .x = client.x + 2, .y = client.y + 24, .w = client.w - 4, .h = client.h - 28 };
        try sunken(ctx, box, hex(0xffffff));
        const row_h: f32 = 20;
        const rows: usize = @intFromFloat(@max(1, @floor((box.h - 6) / row_h)));
        const top = if (s.pick >= rows) s.pick + 1 - rows else 0;
        for (0..rows) |k| {
            const i = top + k;
            if (i > s.pick_count) break;
            const rr = Rect{ .x = box.x + 3, .y = box.y + 3 + @as(f32, @floatFromInt(k)) * row_h, .w = box.w - 6, .h = row_h };
            const on = i == s.pick;
            if (on) try ctx.r.rect(rr, hex(0x000080));
            try drawPick(v, ctx, .{ .x = rr.x + 3, .y = rr.y, .w = rr.w - 6, .h = rr.h }, i, if (on) hex(0xffffff) else black);
            v.hit(rr, .{ .memmap = .{ .pick = i } });
        }
        // System Memory: buddy orders, THP and compaction counters.
        const sw = Rect{ .x = rect.x + margin, .y = lw.y + lw.h + margin, .w = side_w, .h = rect.h - list_h - 3 * margin };
        const sc = try window9x(v, ctx, sw, "System Memory", false, null);
        try systemStrip(v, ctx, sc, .win9x);
    }
    // The main dialog.
    const dlg_full = Rect{ .x = rect.x + 2 * margin + side_w, .y = rect.y + margin, .w = rect.w - 3 * margin - side_w, .h = rect.h - 2 * margin };
    const dlg = if (s.compact) Rect{ .x = rect.x + (rect.w - @min(700, rect.w - 40)) / 2, .y = rect.y + (rect.h - 150) / 2, .w = @min(700, rect.w - 40), .h = 150 } else dlg_full;
    const title = std.fmt.bufPrint(&buf, "Defragmenting Memory: {s}", .{name}) catch "Defragmenting Memory";
    const client = try window9x(v, ctx, dlg, title, true, .{ .button = .stop });
    const mp = s.map();
    const bottom_h: f32 = 100;
    const btn_w: f32 = @max(if (narrow) @as(f32, 104) else 118, ctx.measure("Show Details") + 26);
    const btn_h: f32 = 28;
    if (!s.compact) {
        const body = Rect{ .x = client.x + 4, .y = client.y + 4, .w = client.w - 8, .h = client.h - bottom_h - 12 };
        const max_pitch: f32 = if (rect.h >= 900) 18 else 14;
        var frame = body;
        var list: ?Rect = null;
        var grid: ?Grid = null;
        if (mp) |x| {
            const count = cellCount(x);
            if (count > 0) {
                var g = layoutGrid(.{ .x = body.x + 3, .y = body.y + 3, .w = body.w - 6 - 17, .h = body.h - 6 }, count, 5, max_pitch);
                // The VMA list takes the room the grid does not need.
                if (x.process != null) {
                    const need = gridHeight(g) + 6;
                    const scrolls = g.rows > g.visible;
                    const split = if (scrolls) @floor(body.h * 0.68) else need;
                    if (body.h - split >= 130) {
                        frame.h = split;
                        list = .{ .x = body.x, .y = body.y + split + 8, .w = body.w, .h = body.h - split - 8 };
                        if (scrolls) g = layoutGrid(.{ .x = body.x + 3, .y = body.y + 3, .w = body.w - 6 - 17, .h = split - 6 }, count, 5, max_pitch);
                    }
                }
                grid = g;
            }
        }
        try sunken(ctx, frame, hex(0xffffff));
        const inner = Rect{ .x = frame.x + 3, .y = frame.y + 3, .w = frame.w - 6 - 17, .h = frame.h - 6 };
        // Scrollbar.
        const sb = Rect{ .x = frame.x + frame.w - 2 - 17, .y = frame.y + 2, .w = 17, .h = frame.h - 4 };
        try hatchRect(ctx, sb, hex(0xe0e0e0), hex(0xc8c8c8), 2);
        const up = Rect{ .x = sb.x, .y = sb.y, .w = 17, .h = 17 };
        const down = Rect{ .x = sb.x, .y = sb.y + sb.h - 17, .w = 17, .h = 17 };
        for ([_]Rect{ up, down }, 0..) |b, k| {
            try ctx.r.rect(b, hex(face));
            try bevel(ctx, b, true, true);
            const cx = b.x + 8.5;
            const cy = b.y + 8.5;
            const d: f32 = if (k == 0) -1 else 1;
            try ctx.poly(&.{ .{ cx - 4, cy - 2 * d }, .{ cx + 4, cy - 2 * d }, .{ cx, cy + 2 * d } }, &.{black});
        }
        v.hit(up, .{ .memmap = .{ .scroll = -3 } });
        v.hit(down, .{ .memmap = .{ .scroll = 3 } });
        if (mp) |x| {
            if (grid) |g| {
                try paintGrid(v, ctx, g, x, &win9xPalette(), .win9x, now);
                if (g.rows > g.visible) {
                    const track = sb.h - 34;
                    const th = @max(12, track * @as(f32, @floatFromInt(g.visible)) / @as(f32, @floatFromInt(g.rows)));
                    const ty = sb.y + 17 + (track - th) * @as(f32, @floatFromInt(s.scroll)) / @as(f32, @floatFromInt(@max(1, g.rows - g.visible)));
                    const thumb = Rect{ .x = sb.x, .y = ty, .w = 17, .h = th };
                    try ctx.r.rect(thumb, hex(face));
                    try bevel(ctx, thumb, true, true);
                }
            } else try ctx.textFit(inner.x + 16, inner.y + 16, inner.w - 32, emptyReason(v, x), black);
            if (list) |lr| try vmaList(v, ctx, lr, x, .win9x);
        } else try ctx.textFit(inner.x + 16, inner.y + 16, inner.w - 32, if (s.target != null) "Reading page tables..." else "Waiting for the memory observer...", black);
    }
    // Status, progress and buttons.
    const by = if (s.compact) client.y + 8 else client.y + client.h - bottom_h;
    const text_w = client.w - 2 * btn_w - 32;
    const act = if (mp) |x| md.activity(x) else md.Activity{ .text = "Waiting for system counters", .known = false, .busy = false };
    const verb: []const u8 = if (v.paused) "Paused" else if (mp != null and mp.?.process == null) "Analyzing free memory" else "Defragmenting memory";
    const status_line = if (act.busy) std.fmt.bufPrint(&buf, "{s}: {s}{s}  (system-wide {s} +{d})", .{ verb, act.text, if (v.paused) "" else "...", act.counter, act.count }) catch "" else if (act.known) std.fmt.bufPrint(&buf, "{s}: idle, no THP or compaction activity", .{verb}) catch "" else std.fmt.bufPrint(&buf, "{s}: {s}", .{ verb, act.text }) catch "";
    const short_line = std.fmt.bufPrint(&lb, "{s}: {s}{s}", .{ verb, if (act.known and !act.busy) "idle" else act.text, if (act.busy and !v.paused) "..." else "" }) catch "";
    try ctx.textFit(client.x + 6, by, text_w, if (ctx.measure(status_line) <= text_w) status_line else short_line, black);
    v.hover(.{ .x = client.x + 6, .y = by, .w = text_w, .h = 20 }, "Activity from system-wide vmstat deltas over the last interval; never attributed to the selected process", .{});
    const bar = Rect{ .x = client.x + 6, .y = by + 24, .w = text_w, .h = 22 };
    try sunken(ctx, bar, hex(0xffffff));
    const cov = if (mp) |x| md.coverage(x) else md.Coverage{ .unknown = "no sample" };
    const segs = Rect{ .x = bar.x + 3, .y = bar.y + 3, .w = bar.w - 6, .h = bar.h - 6 };
    switch (cov) {
        .value => |val| {
            const seg_w: f32 = 9;
            const n_seg: usize = @intFromFloat(@floor((segs.w + 2) / (seg_w + 2)));
            const lit: usize = @intFromFloat(@round(val.fraction * @as(f64, @floatFromInt(n_seg))));
            for (0..lit) |k| try ctx.r.rect(.{ .x = segs.x + @as(f32, @floatFromInt(k)) * (seg_w + 2), .y = segs.y, .w = seg_w, .h = segs.h }, hex(0x000080));
        },
        .none => {},
        .unknown => try hatchRect(ctx, segs, hex(0xd8d8d8), hex(0x808080), 5),
    }
    var nb: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    const system_view = mp != null and mp.?.process == null;
    const pct: []const u8 = switch (cov) {
        .value => |val| std.fmt.bufPrint(&buf, "{d:.0}% {s}", .{ val.fraction * 100, if (system_view) "Contiguous" else "Complete" }) catch "",
        .none => if (system_view) "No free memory reported" else "Nothing THP-eligible",
        .unknown => |why| std.fmt.bufPrint(&buf, "Coverage unknown: {s}", .{why}) catch "",
    };
    try ctx.textFit(client.x + 6, by + 52, @min(text_w, 200), pct, black);
    if (cov == .value) {
        const sub = std.fmt.bufPrint(&lb, "{s} of {s} {s}", .{ m.bytes(&nb, @floatFromInt(cov.value.numerator)), m.bytes(&db, @floatFromInt(cov.value.denominator)), if (system_view) "free in >=2 MiB blocks" else "eligible in THP" }) catch "";
        try ctx.textFit(client.x + 214, by + 52, text_w - 214, sub, hex(0x404040));
        v.hover(.{ .x = client.x + 6, .y = by + 24, .w = text_w, .h = 48 }, "{s}", .{if (system_view) "Free memory in blocks of PMD order or larger, from /proc/buddyinfo; not a completion percentage" else "AnonHugePages in THP-eligible private anonymous VMAs / their PMD-aligned span; excludes huge zero pages"});
    }
    const bx = client.x + client.w - 2 * btn_w - 14;
    try button9x(v, ctx, .{ .x = bx, .y = by, .w = btn_w, .h = btn_h }, "Stop", .{ .button = .stop }, false);
    try button9x(v, ctx, .{ .x = bx + btn_w + 8, .y = by, .w = btn_w, .h = btn_h }, if (v.paused) "Resume" else "Pause", .{ .button = .pause }, v.paused);
    try button9x(v, ctx, .{ .x = bx, .y = by + btn_h + 10, .w = btn_w, .h = btn_h }, "Legend", .{ .button = .legend }, s.legend);
    try button9x(v, ctx, .{ .x = bx + btn_w + 8, .y = by + btn_h + 10, .w = btn_w, .h = btn_h }, if (s.compact) "Show Details" else "Hide Details", .{ .button = .details }, false);
    // Keep freshness readable; truncate optional cost detail first.
    var ctb: [160]u8 = undefined;
    const cost = costText(v, &ctb);
    const cost_w = @min(client.w * 0.30, ctx.measure(cost));
    if (mp) |x| {
        var fb: [96]u8 = undefined;
        const fr = freshness(v, x, now, &fb);
        const limited = md.cadence(x, null).cost_limited;
        const fresh_w = client.w - 12 - cost_w - 28;
        try ctx.textFit(client.x + 6, by + btn_h * 2 + 18, fresh_w, fr, if (limited) hex(0x800000) else hex(0x404040));
        v.hover(.{ .x = client.x + 6, .y = by + btn_h * 2 + 18, .w = fresh_w, .h = 20 }, "Actual refresh of this map; expensive maps refresh slower to hold the worker's CPU target. Highlights compare the last two snapshots.", .{});
    }
    try ctx.textFit(client.x + client.w - 8 - cost_w, by + btn_h * 2 + 18, cost_w, cost, hex(0x404040));
    // Hover details as a 9x tooltip.
    const shown = s.hover orelse s.cursor;
    if (mp) |x| if (shown) |i| {
        const d = detail(v, x, i, &buf);
        if (d.len > 0) {
            v.hover(.{ .x = 0, .y = 0, .w = 99999, .h = 99999 }, "{s}", .{d});
            v.tooltip_style = .win9x;
        }
    };
    if (s.legend) try legend9x(v, ctx, rect, mp);
}
fn vmaText(v: *vw.View, vma: md.Vma) []const u8 {
    if (v.redact) switch (vma.kind) {
        .anon, .file, .special, .hugetlb => {
            var hidden = vma;
            hidden.path = null;
            return md.vmaLabel(hidden);
        },
        else => {},
    };
    return md.vmaLabel(vma);
}
/// The VMA table under the grid, the row of the hovered cell highlighted.
fn vmaList(v: *vw.View, ctx: Ctx, r: Rect, mp: *const md.Map, style: GridStyle) !void {
    const s = &v.memmap;
    const ink = if (style == .win9x) hex(0x000000) else ctx.p.text;
    const dim = if (style == .win9x) hex(0x404040) else ctx.p.dim;
    if (style == .win9x) try sunken(ctx, r, hex(0xffffff)) else try ctx.r.shape(r, fade(ctx.p.raised, 0.6), .{ .radii = @splat(4) });
    const wide = r.w >= 1000;
    const cols = [_]struct { []const u8, f32 }{ .{ "Address", if (wide) 170 else 148 }, .{ "Size", 96 }, .{ "Perm", if (wide) 56 else 50 }, .{ "Eligible", if (wide) 100 else 90 }, .{ "AnonHuge", if (wide) 100 else 88 }, .{ "Resident", if (wide) 100 else 84 }, .{ "Mapping", 0 } };
    var x = r.x + 3;
    const hy = r.y + 3;
    for (cols, 0..) |col, k| {
        const w = if (k + 1 == cols.len) r.x + r.w - 3 - x else col[1];
        if (w < 30) break;
        const hr = Rect{ .x = x, .y = hy, .w = w, .h = 22 };
        if (style == .win9x) {
            try ctx.r.rect(hr, hex(face));
            try bevel(ctx, hr, true, false);
        }
        try ctx.textFit(hr.x + 6, hr.y + 1, hr.w - 10, col[0], if (style == .win9x) ink else dim);
        x += w;
    }
    const row_h: f32 = 20;
    const rows: usize = @intFromFloat(@max(1, @floor((r.h - 30) / row_h)));
    const shown = s.hover orelse s.cursor;
    var current: ?usize = null;
    if (shown) |i| if (i < mp.cells.len) {
        current = if (mp.cells[i].vma) |k| k else null;
    };
    const top = if (current) |k| (if (k >= rows) k + 1 - rows else 0) else 0;
    const saved = ctx.r.clip;
    defer ctx.r.clip = saved;
    ctx.r.clip = draw.intersect(saved, draw.inset(r, 2));
    var buf: [192]u8 = undefined;
    for (0..rows) |n| {
        const i = top + n;
        if (i >= mp.vmas.len) break;
        const vma = mp.vmas[i];
        const y = r.y + 27 + @as(f32, @floatFromInt(n)) * row_h;
        const on = current != null and current.? == i;
        if (on) try ctx.r.rect(.{ .x = r.x + 3, .y = y, .w = r.w - 6, .h = row_h }, if (style == .win9x) hex(0x000080) else ctx.p.selection);
        const fg = if (on and style == .win9x) hex(0xffffff) else ink;
        var cx = r.x + 3;
        var sb: [32]u8 = undefined;
        const fields = [_][]const u8{
            std.fmt.bufPrint(&buf, "0x{x:0>12}", .{vma.start}) catch "",
            m.bytes(&sb, @floatFromInt(vma.end - vma.start)),
            vma.perms,
            if (vma.thp_eligible) |e| (if (e) "yes" else "no") else "unknown",
            "",
            "",
            vmaText(v, vma),
        };
        for (cols, 0..) |col, k| {
            const w = if (k + 1 == cols.len) r.x + r.w - 3 - cx else col[1];
            if (w < 30) break;
            var fb: [32]u8 = undefined;
            const text = switch (k) {
                4 => if (vma.anon_huge) |b| m.bytes(&fb, @floatFromInt(b)) else "—",
                5 => if (vma.rss) |b| m.bytes(&fb, @floatFromInt(b)) else "—",
                else => fields[k],
            };
            if (k == 0) {
                var ab: [24]u8 = undefined;
                try ctx.textFit(cx + 6, y, w - 10, std.fmt.bufPrint(&ab, "0x{x:0>12}", .{vma.start}) catch "", fg);
            } else try ctx.textFit(cx + 6, y, w - 10, text, if (k == 3 and vma.thp_eligible == null and !on) dim else fg);
            cx += w;
        }
    }
}
fn emptyReason(v: *vw.View, mp: *const md.Map) []const u8 {
    if (mp.process) |p| {
        if (md.processProblem(&v.memmap.message, p)) |why| return why;
        if (mp.cells.len == 0) return if (!p.pages.ok()) p.pages.reason else "No mapped memory";
    }
    if (v.memmap.target != null and mp.process == null) return "Reading page tables...";
    if (mp.system) |sys| if (!sys.buddy.ok()) return sys.buddy.reason;
    return "No free memory reported";
}

const legend_states = [_]md.State{ .thp, .mixed, .anon, .file, .zero, .swapped, .not_present, .unmovable, .unmapped, .gap, .unknown, .free_contig, .free_frag };
fn legend9x(v: *vw.View, ctx: Ctx, rect: Rect, mp: ?*const md.Map) !void {
    const w: f32 = @min(700, rect.w - 40);
    const h: f32 = 452;
    const r = Rect{ .x = rect.x + (rect.w - w) / 2, .y = rect.y + @max(10, (rect.h - h) / 2), .w = w, .h = @min(h, rect.h - 20) };
    // A modal dialog swallows clicks beneath it.
    v.hit(rect, .{ .memmap = .{ .button = .legend } });
    v.hit(r, .{ .memmap = .{ .scroll = 0 } });
    const client = try window9x(v, ctx, r, "Defrag Legend", true, .{ .button = .close_legend });
    const pal = win9xPalette();
    var y = client.y + 4;
    for (legend_states) |st| {
        const sw = Rect{ .x = client.x + 10, .y = y + 3, .w = 15, .h = 15 };
        if (st == .unknown) try hatchRect(ctx, sw, pal.hatch_bg, pal.hatch, 4) else try ctx.r.rect(sw, pal.state[@intFromEnum(st)]);
        try ctx.r.shape(sw, hex(0x000000), .{ .border = 1 });
        try ctx.textFit(client.x + 34, y, client.w - 44, md.stateName(st), hex(0x000000));
        y += 22;
    }
    const changes = [_]struct { md.Change, Color }{ .{ .changed, pal.changed }, .{ .collapsed, pal.state[@intFromEnum(md.State.thp)] }, .{ .split, pal.state[@intFromEnum(md.State.anon)] } };
    for (changes) |ch| {
        const sw = Rect{ .x = client.x + 10, .y = y + 3, .w = 15, .h = 15 };
        try ctx.r.rect(sw, ch[1]);
        if (ch[0] == .collapsed) try ctx.r.shape(draw.inset(sw, 1), pal.collapsed, .{ .border = 2 });
        if (ch[0] == .split) try ctx.r.shape(sw, pal.split, .{ .border = 3 });
        try ctx.r.shape(sw, hex(0x000000), .{ .border = 1 });
        try ctx.textFit(client.x + 34, y, client.w - 44, md.changeName(ch[0]), hex(0x000000));
        y += 22;
    }
    y += 4;
    const backend: []const u8 = if (mp) |x| if (x.process) |p| switch (p.backend) {
        .pagemap_scan => "Backend: PAGEMAP_SCAN (huge pages observable)",
        .pagemap_flags => "Backend: pagemap flags; page size unknown (hatched)",
        .none => "Backend: no page states (cells unknown)",
    } else "System view: buddyinfo counts, no positions" else "No sample yet";
    try ctx.textFit(client.x + 10, y, client.w - 20, backend, hex(0x000080));
    try ctx.textFit(client.x + 10, y + 22, client.w - 20, "Physical migration is not observable in this per-process view.", hex(0x404040));
    const ok = Rect{ .x = client.x + client.w - 100, .y = client.y + client.h - 34, .w = 92, .h = 28 };
    try button9x(v, ctx, ok, "Close", .{ .button = .close_legend }, false);
}

/// Buddy orders per zone, THP/compaction deltas and THP settings.
fn systemStrip(v: *vw.View, ctx: Ctx, r: Rect, style: GridStyle) !void {
    const s = &v.memmap;
    const ink = if (style == .win9x) hex(0x000000) else ctx.p.text;
    const dim = if (style == .win9x) hex(0x404040) else ctx.p.dim;
    const bar_c = if (style == .win9x) hex(0x000080) else ctx.p.accent;
    const big_c = if (style == .win9x) hex(0x008080) else ctx.p.ok;
    var buf: [160]u8 = undefined;
    const mp = s.map() orelse {
        try ctx.textFit(r.x + 4, r.y + 4, r.w - 8, "Waiting for the memory observer...", dim);
        return;
    };
    const sys = mp.system orelse {
        try ctx.textFit(r.x + 4, r.y + 4, r.w - 8, "No system sample", dim);
        return;
    };
    var y = r.y + 2;
    const save = ctx.r.clip;
    defer ctx.r.clip = save;
    ctx.r.clip = draw.intersect(save, r);
    if (!sys.buddy.ok()) {
        try ctx.textFit(r.x + 4, y, r.w - 8, sys.buddy.reason, dim);
        y += 22;
    }
    try ctx.textFit(r.x + 4, y, r.w - 8, "Free blocks by order (log scale)", dim);
    y += 22;
    const order9 = md.pmdOrder(sys.page_size);
    for (sys.zones) |z| {
        if (y + 40 > r.y + r.h) break;
        const t = md.zoneFree(z, order9);
        var fb: [32]u8 = undefined;
        const pct: f64 = if (t.free_pages > 0) @as(f64, @floatFromInt(t.contig_pages)) * 100 / @as(f64, @floatFromInt(t.free_pages)) else 0;
        try ctx.textFit(r.x + 4, y, r.w - 8, std.fmt.bufPrint(&buf, "Node {d} {s}: {s} free, {d:.0}% >=2M", .{ z.node, z.name, m.bytes(&fb, @floatFromInt(t.free_pages * sys.page_size)), pct }) catch "", ink);
        y += 20;
        const n = z.blocks.len;
        if (n > 0) {
            const bw = (r.w - 8) / @as(f32, @floatFromInt(n));
            for (z.blocks, 0..) |count, o| {
                const hgt = if (count == 0) 0 else @min(18, 3 + 2.2 * @log2(@as(f32, @floatFromInt(count)) + 1));
                try ctx.r.rect(.{ .x = r.x + 4 + @as(f32, @floatFromInt(o)) * bw, .y = y + 18 - hgt, .w = @max(1, bw - 2), .h = hgt }, if (o >= order9) big_c else bar_c);
            }
        }
        y += 24;
    }
    if (y + 20 < r.y + r.h) {
        try ctx.textFit(r.x + 4, y, r.w - 8, if (sys.interval_ns > 0) "System-wide over the last interval" else "Counters: first interval, deltas unknown", dim);
        y += 22;
    }
    const shown = [_]struct { []const u8, []const u8 }{ .{ "thp_fault_alloc", "THP faults" }, .{ "thp_fault_fallback", "THP fault fallbacks" }, .{ "thp_collapse_alloc", "collapses" }, .{ "thp_split_pmd", "PMD splits" }, .{ "compact_stall", "compaction stalls" }, .{ "compact_success", "compaction successes" }, .{ "compact_migrate_scanned", "migrate-scanned" }, .{ "pgmigrate_success", "pages migrated" } };
    for (shown) |k| {
        if (y + 20 > r.y + r.h) break;
        const ctr = md.counter(&sys, k[0]) orelse continue;
        try ctx.textFit(r.x + 4, y, r.w * 0.62, k[1], ink);
        const val = if (ctr.delta) |d| std.fmt.bufPrint(&buf, "+{d}", .{d}) catch "" else "—";
        try ctx.textRight(r.x + r.w - 4, y, val, if (ctr.delta != null and ctr.delta.? > 0) bar_c else dim);
        y += 20;
    }
    if (y + 20 < r.y + r.h) {
        const en = if (md.setting(&sys, "enabled")) |x| md.selected(x) else "?";
        const df = if (md.setting(&sys, "defrag")) |x| md.selected(x) else "?";
        try ctx.textFit(r.x + 4, y + 2, r.w - 8, std.fmt.bufPrint(&buf, "THP {s}, defrag {s}", .{ en, df }) catch "", dim);
    }
}

// --- MS-DOS DEFRAG ----------------------------------------------------------------------

var screen: dos.Screen = .{};
fn dosLook(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const s = &v.memmap;
    try ctx.r.rect(rect, hex(0x000000));
    const empty = md.Map{};
    const mp = s.map() orelse &empty;
    var lb: [64]u8 = undefined;
    var cb: [160]u8 = undefined;
    var kb: [48]u8 = undefined;
    var labels: [65][]const u8 = undefined;
    var label_bufs: [65][80]u8 = undefined;
    const n = @min(s.pick_count + 1, labels.len);
    for (0..n) |i| labels[i] = pickLabel(v, &label_bufs[i], i);
    const blink_on = v.paused or (now / vga.blink_half_ns) % 2 == 0;
    // Geometry: integer-ish scale of 720x400, centred, in a bezel.
    const sw = vga.cell_w * vga.cols;
    const sh = vga.cell_h * vga.rows * vga.pixel_aspect;
    var scale = @min((rect.w - 40) / sw, (rect.h - 40) / sh);
    if (scale >= 1) scale = @floor(scale * 4) / 4;
    const cw = vga.cell_w * scale;
    const ch = vga.cell_h * scale * vga.pixel_aspect;
    const ox = @round(rect.x + (rect.w - cw * vga.cols) / 2);
    const oy = @round(rect.y + (rect.h - ch * vga.rows) / 2);
    // Cursor from the pointer, before composing.
    const mx = v.pointer[0] - ox;
    const my = v.pointer[1] - oy;
    if (mx >= 0 and my >= 0) {
        const col: usize = @intFromFloat(mx / cw);
        const row: usize = @intFromFloat(my / ch);
        if (col >= dos.map_x and col < dos.map_x + dos.map_cols and row >= dos.map_y and row < dos.map_y + dos.map_rows and !s.picker_open and !s.legend) {
            const i = (s.scroll + row - dos.map_y) * dos.map_cols + (col - dos.map_x);
            if (i < cellCount(mp)) s.hover = i;
        }
    }
    s.grid_cols = dos.map_cols;
    s.visible_rows = dos.map_rows;
    const res = dos.compose(&screen, mp, .{
        .label = label(v, &lb),
        .elapsed_s = if (s.target_since > 0) @as(f64, @floatFromInt(now -| s.target_since)) / 1e9 else null,
        .blink_on = blink_on,
        .cursor = s.hover orelse s.cursor,
        .scroll = s.scroll,
        .cost = costAge(v, mp, now, &cb),
        .cadence = md.cadenceText(&kb, md.cadence(mp, liveNow(v, now))),
        .hint = "o=Select t=Look p=Pause g=Legend Esc=Stop",
        .paused = v.paused,
        .waiting = s.target != null and mp.process == null,
        .picker = if (s.picker_open) .{ .labels = labels[0..n], .selected = s.pick } else null,
        .legend = s.legend,
    });
    if (s.scroll + dos.map_rows > res.rows) s.scroll = res.rows -| dos.map_rows;
    // Bezel.
    try ctx.r.shape(.{ .x = ox - 18, .y = oy - 18, .w = cw * vga.cols + 36, .h = ch * vga.rows + 36 }, hex(0x101010), .{ .radii = @splat(14) });
    try drawScreen(ctx, &screen, ox, oy, cw, ch, scale);
    if (v.layout != null) {
        auditText(ox, oy, cw, ch);
        auditRows(&screen);
    }
    // Faint scanlines: the tube.
    var y: f32 = oy;
    const step = @max(2, @round(scale * 2));
    while (y < oy + ch * vga.rows) : (y += step) try ctx.r.rect(.{ .x = ox, .y = y, .w = cw * vga.cols, .h = 1 }, .{ 0, 0, 0, 0.10 });
    // Menu items are clickable: Optimize=select, Analyze=legend, Configure=look, Exit=stop.
    const menu = [_]struct { usize, usize, Button }{ .{ 1, 8, .picker }, .{ 11, 7, .legend }, .{ 20, 9, .look }, .{ 31, 4, .stop } };
    for (menu) |item| v.hit(.{ .x = ox + @as(f32, @floatFromInt(item[0])) * cw, .y = oy, .w = @as(f32, @floatFromInt(item[1])) * cw, .h = ch }, .{ .memmap = .{ .button = item[2] } });
    if (s.picker_open) {
        const shown = @min(n, 12);
        const top = if (s.pick >= shown) s.pick + 1 - shown else 0;
        for (0..shown) |k| v.hit(.{ .x = ox + 16 * cw, .y = oy + @as(f32, @floatFromInt(5 + k)) * ch, .w = 48 * cw, .h = ch }, .{ .memmap = .{ .pick = top + k } });
    } else if (s.hover) |i| {
        v.hit(.{ .x = ox + cw, .y = oy + 2 * ch, .w = 78 * cw, .h = 15 * ch }, .{ .memmap = .{ .cell = i } });
        var db: [256]u8 = undefined;
        const d = detail(v, mp, i, &db);
        if (d.len > 0) {
            v.hover(.{ .x = 0, .y = 0, .w = 99999, .h = 99999 }, "{s}", .{d});
            v.tooltip_style = .dos;
        }
    }
}
/// Box-drawing glyph as lines: weight 1 single, 2 double; a corner joins
/// toward dx (+1 right, -1 left) and dy (+1 down, -1 up).
const Box = struct { weight: u2, kind: enum { horizontal, vertical, corner }, dx: f32 = 0, dy: f32 = 0 };
fn boxDrawing(cp: u21) ?Box {
    return switch (cp) {
        '═' => .{ .weight = 2, .kind = .horizontal },
        '║' => .{ .weight = 2, .kind = .vertical },
        '╔' => .{ .weight = 2, .kind = .corner, .dx = 1, .dy = 1 },
        '╗' => .{ .weight = 2, .kind = .corner, .dx = -1, .dy = 1 },
        '╚' => .{ .weight = 2, .kind = .corner, .dx = 1, .dy = -1 },
        '╝' => .{ .weight = 2, .kind = .corner, .dx = -1, .dy = -1 },
        '─' => .{ .weight = 1, .kind = .horizontal },
        '│' => .{ .weight = 1, .kind = .vertical },
        '┌' => .{ .weight = 1, .kind = .corner, .dx = 1, .dy = 1 },
        '┐' => .{ .weight = 1, .kind = .corner, .dx = -1, .dy = 1 },
        '└' => .{ .weight = 1, .kind = .corner, .dx = 1, .dy = -1 },
        '┘' => .{ .weight = 1, .kind = .corner, .dx = -1, .dy = -1 },
        else => null,
    };
}
fn boxLines(ctx: Ctx, b: Box, cx: f32, cy: f32, cw: f32, ch: f32, scale: f32, fg: Color) !void {
    const t = @max(1, @round(scale));
    const mx = @round(cx + cw / 2 - t / 2);
    const my = @round(cy + ch / 2 - t / 2);
    const off = @round(2 * scale);
    const offsets: []const f32 = if (b.weight == 2) &.{ -off, off } else &.{0};
    for (offsets) |o| switch (b.kind) {
        .horizontal => try ctx.r.rect(.{ .x = cx, .y = my + o, .w = cw, .h = t }, fg),
        .vertical => try ctx.r.rect(.{ .x = mx + o, .y = cy, .w = t, .h = ch }, fg),
        .corner => {
            // The line pair's corner points sit diagonally; each runs to its edges.
            const px = mx + o * b.dx;
            const py = my + o * b.dy;
            const x_end = if (b.dx > 0) cx + cw else cx;
            const y_end = if (b.dy > 0) cy + ch else cy;
            try ctx.r.rect(.{ .x = @min(px, x_end), .y = py, .w = @abs(x_end - px) + (if (b.dx > 0) @as(f32, 0) else t), .h = t }, fg);
            try ctx.r.rect(.{ .x = px, .y = @min(py, y_end), .w = t, .h = @abs(y_end - py) + (if (b.dy > 0) @as(f32, 0) else t) }, fg);
        },
    };
}
/// Draws a text screen: background runs, block and box glyphs as geometry,
/// everything else from the font atlas scaled into the cell.
fn drawScreen(ctx: Ctx, scr: *const dos.Screen, ox: f32, oy: f32, cw: f32, ch: f32, scale: f32) !void {
    for (0..vga.rows) |y| {
        var x: usize = 0;
        while (x < vga.cols) {
            const bg = scr.cells[y][x].bg;
            var run: usize = 1;
            while (x + run < vga.cols and scr.cells[y][x + run].bg == bg) run += 1;
            try ctx.r.rect(.{ .x = ox + @as(f32, @floatFromInt(x)) * cw, .y = oy + @as(f32, @floatFromInt(y)) * ch, .w = @as(f32, @floatFromInt(run)) * cw, .h = ch }, vga.rgb(bg));
            x += run;
        }
        var first: ?usize = null;
        var last: usize = 0;
        for (0..vga.cols) |k| {
            const cell = scr.cells[y][k];
            if (cell.ch == ' ') continue;
            if (first == null) first = k;
            last = k;
            const cx = ox + @as(f32, @floatFromInt(k)) * cw;
            const cy = oy + @as(f32, @floatFromInt(y)) * ch;
            const fg = vga.rgb(cell.fg);
            try glyph(ctx, cell.ch, cx, cy, cw, ch, scale, fg);
        }
        // Layout audit: a text-mode row is one label.
        if (ctx.layout) |l| if (first) |f| {
            var rb: [400]u8 = undefined;
            l.add(.{ .x = ox + @as(f32, @floatFromInt(f)) * cw, .y = oy + @as(f32, @floatFromInt(y)) * ch + 2, .w = @as(f32, @floatFromInt(last + 1 - f)) * cw, .h = @min(16, ch - 1) }, std.mem.trim(u8, scr.row(y, &rb), " "));
        };
    }
}
fn glyph(ctx: Ctx, cp: u21, cx: f32, cy: f32, cw: f32, ch: f32, scale: f32, fg: Color) !void {
    switch (cp) {
        '█' => return ctx.r.rect(.{ .x = cx, .y = cy, .w = cw, .h = ch }, fg),
        '▀' => return ctx.r.rect(.{ .x = cx, .y = cy, .w = cw, .h = ch / 2 }, fg),
        '▄' => return ctx.r.rect(.{ .x = cx, .y = cy + ch / 2, .w = cw, .h = ch / 2 }, fg),
        '■' => return ctx.r.rect(.{ .x = cx + cw * 0.17, .y = cy + ch * 0.32, .w = cw * 0.66, .h = ch * 0.38 }, fg),
        '·' => return ctx.r.rect(.{ .x = cx + cw * 0.39, .y = cy + ch * 0.44, .w = @max(1, @round(cw * 0.22)), .h = @max(1, @round(cw * 0.22)) }, fg),
        // Shades as a pixel dither like the VGA ROM font: 1 in 4, 1 in 2, 3 in 4.
        '░', '▒', '▓' => return shade(ctx, cp, cx, cy, cw, ch, scale, fg),
        else => {},
    }
    if (boxDrawing(cp)) |b| return boxLines(ctx, b, cx, cy, cw, ch, scale, fg);
    // A font glyph, scaled with nearest sampling, centred in the cell.
    var enc: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &enc) catch return;
    const font: *Font = ctx.font;
    const id = c.FT_Get_Char_Index(font.face, cp);
    if (id == 0) return ctx.r.text(font, cx, cy, enc[0..n], fg);
    const g = font.glyph(id) catch return;
    if (g.w == 0 or g.h == 0) return;
    const s2 = scale;
    const gw = @as(f32, @floatFromInt(g.w)) * s2;
    const gh = @as(f32, @floatFromInt(g.h)) * s2 * vga.pixel_aspect;
    const baseline = cy + ch * 0.78;
    const atlas: f32 = @import("../../render/font.zig").atlas_size;
    try ctx.r.quad(.{ .x = @round(cx + (cw - gw) / 2), .y = @round(baseline - @as(f32, @floatFromInt(g.top)) * s2 * vga.pixel_aspect), .w = gw, .h = gh }, .{ .x = @as(f32, @floatFromInt(g.x)) / atlas, .y = @as(f32, @floatFromInt(g.y)) / atlas, .w = @as(f32, @floatFromInt(g.w)) / atlas, .h = @as(f32, @floatFromInt(g.h)) / atlas }, fg);
}
/// Shade glyphs fill the whole cell like the VGA ROM font: the font's own
/// dither stretched over the cell, or a flat blend when the font lacks it.
fn shade(ctx: Ctx, cp: u21, cx: f32, cy: f32, cw: f32, ch: f32, scale: f32, fg: Color) !void {
    _ = scale;
    const font: *Font = ctx.font;
    const id = c.FT_Get_Char_Index(font.face, cp);
    const density: f32 = switch (cp) {
        '░' => 0.25,
        '▒' => 0.5,
        else => 0.75,
    };
    if (id == 0) return ctx.r.rect(.{ .x = cx, .y = cy, .w = cw, .h = ch }, fade(fg, density));
    const g = font.glyph(id) catch return ctx.r.rect(.{ .x = cx, .y = cy, .w = cw, .h = ch }, fade(fg, density));
    const atlas: f32 = @import("../../render/font.zig").atlas_size;
    try ctx.r.quad(.{ .x = cx, .y = cy, .w = cw, .h = ch }, .{ .x = @as(f32, @floatFromInt(g.x)) / atlas, .y = @as(f32, @floatFromInt(g.y)) / atlas, .w = @as(f32, @floatFromInt(g.w)) / atlas, .h = @as(f32, @floatFromInt(g.h)) / atlas }, fg);
}

// --- Modern ---------------------------------------------------------------------------

/// Clean high-contrast grid in the overview's own palette. The later
/// high-resolution visualiser replaces `paintGrid(.modern)` here.
fn modern(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const s = &v.memmap;
    const p = ctx.p;
    var buf: [256]u8 = undefined;
    var lb: [64]u8 = undefined;
    const side_w: f32 = if (s.compact) 0 else std.math.clamp(rect.w * 0.23, 240, 340);
    if (!s.compact) {
        const list = Rect{ .x = rect.x, .y = rect.y, .w = side_w, .h = @floor(rect.h * 0.45) };
        try ctx.panel(list);
        try ctx.text(list.x + 12, list.y + 8, "Process", p.text);
        const row_h: f32 = 22;
        const rows: usize = @intFromFloat(@max(1, @floor((list.h - 44) / row_h)));
        const top = if (s.pick >= rows) s.pick + 1 - rows else 0;
        for (0..rows) |k| {
            const i = top + k;
            if (i > s.pick_count) break;
            const rr = Rect{ .x = list.x + 6, .y = list.y + 36 + @as(f32, @floatFromInt(k)) * row_h, .w = list.w - 12, .h = row_h };
            if (i == s.pick) try ctx.r.shape(rr, p.selection, .{ .radii = @splat(4) });
            try drawPick(v, ctx, .{ .x = rr.x + 6, .y = rr.y + 1, .w = rr.w - 12, .h = rr.h }, i, if (i == s.pick) p.text else p.dim);
            v.hit(rr, .{ .memmap = .{ .pick = i } });
        }
        const sys = Rect{ .x = rect.x, .y = list.y + list.h + 10, .w = side_w, .h = rect.h - list.h - 10 };
        try ctx.panel(sys);
        try ctx.text(sys.x + 12, sys.y + 8, "System memory", p.text);
        try systemStrip(v, ctx, .{ .x = sys.x + 8, .y = sys.y + 34, .w = sys.w - 16, .h = sys.h - 40 }, .modern);
    }
    const main = Rect{ .x = rect.x + side_w + (if (s.compact) @as(f32, 0) else 10), .y = rect.y, .w = rect.w - side_w - (if (s.compact) @as(f32, 0) else 10), .h = rect.h };
    try ctx.panel(main);
    const mp = s.map();
    try ctx.textFit(main.x + 14, main.y + 8, main.w * 0.5, label(v, &lb), p.text);
    try ctx.textRight(main.x + main.w - 14, main.y + 8, costText(v, &buf), p.dim);
    if (mp) |x| {
        var fb: [96]u8 = undefined;
        try ctx.textRight(main.x + main.w - 14, main.y + 60, freshness(v, x, now, &fb), if (md.cadence(x, null).cost_limited) p.warn else p.dim);
    }
    const cov = if (mp) |x| md.coverage(x) else md.Coverage{ .unknown = "no sample" };
    const bar = Rect{ .x = main.x + 14, .y = main.y + 38, .w = main.w * 0.45, .h = 14 };
    if (cov == .value) {
        // Coverage is good when high: one colour, no heat ramp.
        const seg: f32 = 5;
        const n_seg: usize = @intFromFloat(@floor((bar.w + 2) / (seg + 2)));
        const lit: usize = @intFromFloat(@round(cov.value.fraction * @as(f64, @floatFromInt(n_seg))));
        for (0..n_seg) |k| try ctx.r.rect(.{ .x = bar.x + @as(f32, @floatFromInt(k)) * (seg + 2), .y = bar.y, .w = seg, .h = bar.h }, if (k < lit) p.accent else fade(p.accent, p.ghost + 0.05));
    } else try ctx.hatch(bar);
    var nb: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    const system_view = mp != null and mp.?.process == null;
    const ctext: []const u8 = switch (cov) {
        .value => |val| std.fmt.bufPrint(&buf, "{d:.1}% {s} · {s} of {s}", .{ val.fraction * 100, if (system_view) "free in >=2 MiB blocks" else "THP coverage", m.bytes(&nb, @floatFromInt(val.numerator)), m.bytes(&db, @floatFromInt(val.denominator)) }) catch "",
        .none => if (system_view) "no free memory reported" else "nothing THP-eligible",
        .unknown => |why| std.fmt.bufPrint(&buf, "coverage unknown: {s}", .{why}) catch "",
    };
    try ctx.textFit(bar.x + bar.w + 14, main.y + 34, main.w - bar.w - 42, ctext, if (cov == .unknown) p.warn else p.text);
    const act = if (mp) |x| md.activity(x) else md.Activity{ .text = "waiting", .known = false, .busy = false };
    try ctx.textFit(main.x + 14, main.y + 60, main.w * 0.45, std.fmt.bufPrint(&lb, "system: {s}", .{act.text}) catch "", if (act.busy) p.accent else p.dim);
    // Legend chips, wrapped onto a second row when narrow.
    const pal = modernPalette(p);
    const chips = if (system_view) &[_]md.State{ .free_contig, .free_frag } else &[_]md.State{ .thp, .mixed, .anon, .file, .zero, .swapped, .not_present, .unmovable, .unmapped, .unknown };
    const change_names = [_][]const u8{ "changed", "collapsed", "split" };
    var total: f32 = 0;
    for (chips) |st| total += 34 + ctx.measure(shortName(st));
    if (!system_view) for (change_names) |name| {
        total += 34 + ctx.measure(name);
    };
    const legend_rows: f32 = if (total > main.w - 28) 2 else 1;
    var lx = main.x + 14;
    var ly = main.y + main.h - 8 - 22 * legend_rows;
    const wrap_at = main.x + main.w - 14;
    for (chips) |st| {
        const name = shortName(st);
        if (lx + 34 + ctx.measure(name) > wrap_at) {
            lx = main.x + 14;
            ly += 22;
        }
        const sw = Rect{ .x = lx, .y = ly + 4, .w = 12, .h = 12 };
        if (st == .unknown) try hatchRect(ctx, sw, pal.hatch_bg, pal.hatch, 3) else try ctx.r.rect(sw, pal.state[@intFromEnum(st)]);
        try ctx.text(lx + 18, ly, name, p.dim);
        lx += 18 + ctx.measure(name) + 16;
    }
    if (!system_view) for ([_]md.Change{ .changed, .collapsed, .split }, change_names) |k, name| {
        if (lx + 34 + ctx.measure(name) > wrap_at) {
            lx = main.x + 14;
            ly += 22;
        }
        const sw = Rect{ .x = lx, .y = ly + 4, .w = 12, .h = 12 };
        switch (k) {
            .changed => try ctx.r.rect(sw, pal.changed),
            .collapsed => {
                try ctx.r.rect(sw, pal.state[@intFromEnum(md.State.thp)]);
                try ctx.r.shape(sw, pal.collapsed, .{ .border = 2 });
            },
            else => {
                try ctx.r.rect(sw, pal.state[@intFromEnum(md.State.anon)]);
                try ctx.r.shape(sw, pal.split, .{ .border = 2 });
            },
        }
        try ctx.text(lx + 18, ly, name, p.dim);
        lx += 18 + ctx.measure(name) + 16;
    };
    const area = Rect{ .x = main.x + 14, .y = main.y + 90, .w = main.w - 28, .h = main.h - 90 - 16 - 22 * legend_rows };
    if (s.compact) return;
    if (mp) |x| {
        const count = cellCount(x);
        if (count == 0) {
            try ctx.hatchLight(.{ .x = area.x, .y = area.y, .w = area.w, .h = 60 });
            try ctx.textFit(area.x + 12, area.y + 20, area.w - 24, emptyReason(v, x), p.dim);
        } else {
            var g = layoutGrid(area, count, 5, if (rect.h >= 900) 22 else 16);
            if (x.process != null) {
                const scrolls = g.rows > g.visible;
                const split = if (scrolls) @floor(area.h * 0.68) else gridHeight(g);
                if (area.h - split >= 130) {
                    if (scrolls) g = layoutGrid(.{ .x = area.x, .y = area.y, .w = area.w, .h = split }, count, 5, if (rect.h >= 900) 22 else 16);
                    try vmaList(v, ctx, .{ .x = area.x, .y = area.y + split + 10, .w = area.w, .h = area.h - split - 10 }, x, .modern);
                }
            }
            try paintGrid(v, ctx, g, x, &pal, .modern, now);
        }
        const shown = s.hover orelse s.cursor;
        if (shown) |i| {
            var dbuf: [256]u8 = undefined;
            const d = detail(v, x, i, &dbuf);
            if (d.len > 0) v.hover(.{ .x = 0, .y = 0, .w = 99999, .h = 99999 }, "{s}", .{d});
        }
    } else try ctx.textFit(area.x + 12, area.y + 20, area.w - 24, if (s.target != null) "Reading page tables..." else "Waiting for the memory observer...", p.dim);
    if (s.legend) try legend9x(v, ctx, rect, mp);
}
fn shortName(st: md.State) []const u8 {
    return switch (st) {
        .thp => "THP",
        .mixed => "part THP",
        .anon => "4 KiB",
        .file => "file",
        .swapped => "swapped",
        .not_present => "not present",
        .unmovable => "unmovable",
        .unmapped => "unmapped",
        .unknown => "unknown",
        .free_contig => "free >= 2 MiB",
        .free_frag => "free, smaller",
        .zero => "zero page",
        else => md.stateName(st),
    };
}
