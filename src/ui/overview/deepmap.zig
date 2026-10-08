//! The Memory map's deep look: a dense, zoomable, pannable field of up to
//! 65,536 fixed-size cells, from 2 MiB per cell down to one 4 KiB page, driven
//! by one explicit viewport request (the same request selects what the
//! collector samples and how its publication is projected). A minimap strip
//! shows the whole address space with gaps compressed and the viewport boxed.
//!
//! Honesty rules: cells the request has not sampled yet are drawn as pending
//! (dotted), never as the previous data; unobserved cells are hatched; gaps
//! are dark; the three change kinds stay apart (changed fill, collapse ring,
//! split edge); the huge zero page is never THP; NUMA is shown only as the
//! whole VMA's totals. Cells are one instanced batch (render/cell.vert).
const std = @import("std");
const c = @import("../../c.zig").api;
const draw = @import("draw.zig");
const vw = @import("view.zig");
const m = @import("model.zig");
const mm = @import("memmap.zig");
const md = mm.md;
const gpu = @import("../../render/vulkan.zig");
const rgb = @import("../../appearance.zig").rgb;
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const Color = draw.Color;
const fade = draw.fade;
const mix = draw.mix;

/// Cell sizes: about 1 px per 2 MiB block, down to one cell per 4 KiB page.
pub const levels = [_]u64{ 2 << 20, 1 << 20, 512 << 10, 256 << 10, 128 << 10, 64 << 10, 32 << 10, 16 << 10, 8 << 10, 4 << 10 };
const min_pitch: f32 = 3;
/// A moving view reaches the collector only after it rests this long.
const settle_ns: u64 = 150_000_000;
/// Highest address the field pans to (57-bit user space).
const top_address: u64 = 1 << 57;
/// Address gaps wider than this split the minimap into islands.
const island_gap: u64 = 1 << 30;

const Drag = struct { x: f32, y: f32, origin: u64, moved: bool = false };
const zero_rect = Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };

pub const Counts = struct { pending: usize = 0, unknown: usize = 0, gap: usize = 0, thp: usize = 0, mixed: usize = 0, anon: usize = 0, file: usize = 0, zero: usize = 0, other: usize = 0, changed: usize = 0, collapsed: usize = 0, split: usize = 0 };

pub const Deep = struct {
    level: usize = 0,
    origin: u64 = 0,
    /// The first map placed the view (fit); later maps leave it alone. Until
    /// the user moves it, a resized field fits again.
    placed: bool = false,
    moved: bool = false,
    fitted_count: usize = 0,
    cols: usize = 0,
    rows: usize = 0,
    pitch: f32 = 0,
    field: Rect = zero_rect,
    mini: Rect = zero_rect,
    /// What the view shows now, and since when.
    wanted: ?md.Request = null,
    wanted_at: u64 = 0,
    /// What the reader asks the collector for (settled).
    request: ?md.Request = null,
    /// The newest response to `request` had no cells yet.
    pending: bool = false,
    pending_since: u64 = 0,
    drag: ?Drag = null,
    selected: ?u64 = null,
    hover: ?u64 = null,
    cache_key: u64 = 0,
    counts: Counts = .{},
    perf: Perf = .{},

    pub fn reset(self: *Deep) void {
        self.* = .{ .perf = self.perf };
    }
    pub fn cell(self: *const Deep) u64 {
        return levels[self.level];
    }
    pub fn count(self: *const Deep) usize {
        return self.cols * self.rows;
    }
    fn span(self: *const Deep) u64 {
        return @as(u64, self.count()) * self.cell();
    }
    /// Moves the view; never below 0 or past the top of user space.
    fn moveTo(self: *Deep, origin: i128) void {
        const top: i128 = top_address - @as(i128, self.span());
        const cell_ = self.cell();
        const clamped: u64 = @intCast(std.math.clamp(origin, 0, @max(0, top)));
        self.origin = clamped - clamped % cell_;
    }
    /// The user moved or zoomed the view: a resize no longer refits it.
    fn user(self: *Deep) *Deep {
        self.moved = true;
        return self;
    }
};

/// Frame cost evidence (XODB_MEMMAP_PERF=1): cell build and whole-frame CPU.
const Perf = struct {
    window_start: u64 = 0,
    frames: u64 = 0,
    builds: u64 = 0,
    build_ns: u64 = 0,
    build_max: u64 = 0,
    frame_ns: u64 = 0,
    frame_max: u64 = 0,
};

// --- Request and publication ----------------------------------------------------------

/// The settled request for the reader. Before the view is placed the compact
/// map supplies the VMA list for the first fit.
pub fn request(s: *mm.State, redact: bool, now: u64) md.Request {
    const d = &s.deep;
    if (s.target == null or !d.placed or d.count() == 0) return .{ .redact = redact };
    const want = md.Request{ .cell_bytes = d.cell(), .range = .{ .start = d.origin, .end = d.origin + d.span() }, .numa = true, .redact = redact };
    if (!std.meta.eql(d.wanted, @as(?md.Request, want))) {
        d.wanted = want;
        d.wanted_at = now;
    }
    if (d.request == null or d.request.?.range == null or now -| d.wanted_at >= settle_ns) d.request = want;
    return d.request.?;
}
/// A new publication. A pending one keeps the shown data (its cells are
/// never relabelled: lookups go by address and cell size).
pub fn accept(s: *mm.State, got: *md.Owned, now: u64, scanned: bool) bool {
    const d = &s.deep;
    const waiting = got.map.pending or (s.target != null and got.map.process == null);
    if (waiting) {
        if (!d.pending) d.pending_since = now;
        d.pending = true;
        if (s.current == null) {
            s.current = got;
            s.accepted_at = now;
        } else got.destroy();
        return true;
    }
    d.pending = false;
    // The same page scan with newer system counters: no animation.
    if (!scanned) if (s.current) |cur| if (cur.map.cells.len > 0) {
        cur.destroy();
        s.current = got;
        return true;
    };
    if (s.previous) |p| p.destroy();
    s.previous = s.current;
    s.current = got;
    s.accepted_at = now;
    return true;
}

// --- Cell lookup ----------------------------------------------------------------------

const Sources = struct {
    maps: [16]*const md.Map = undefined,
    n: usize = 0,
    last: usize = 0,
    fn add(self: *Sources, map: *const md.Map) void {
        if (self.n < self.maps.len and map.range != null and map.cells.len > 0) {
            self.maps[self.n] = map;
            self.n += 1;
        }
    }
    const Found = struct { map: *const md.Map, cell: *const md.Cell };
    fn find(self: *Sources, cell_bytes: u64, address: u64) ?Found {
        for (0..self.n) |k| {
            const i = (self.last + k) % self.n;
            const map = self.maps[i];
            const r = map.range.?;
            if (map.cell_bytes != cell_bytes or address < r.start or address >= r.end) continue;
            const at = (address - r.start) / cell_bytes;
            if (at >= map.cells.len) continue;
            self.last = i;
            return .{ .map = map, .cell = &map.cells[at] };
        }
        return null;
    }
};
/// Live: the newest map with cells. Replay: the frame's recorded viewports.
fn sources(s: *const mm.State, previous: bool) Sources {
    var out: Sources = .{};
    if (s.replay_current != null) {
        for (if (previous) s.replay_viewports_prev else s.replay_viewports) |*map| out.add(map);
    } else if (if (previous) s.prev() else s.map()) |map| out.add(map);
    return out;
}

// --- Colours --------------------------------------------------------------------------

const Paint = struct {
    state: [md.state_count]Color,
    gap: Color,
    pending: Color,
    pending_dot: Color,
    hatch_bg: Color,
    hatch: Color,
    changed: Color,
    ring: Color,
    edge: Color,
};
fn solid(under: Color, x: Color) Color {
    var out = mix(under, x, x[3]);
    out[3] = 1;
    return out;
}
fn paint(p: *const @import("theme.zig").Palette) Paint {
    const pal = mm.modernPalette(p);
    var out: Paint = .{
        .state = undefined,
        .gap = solid(p.background, .{ 0, 0, 0, 0.55 }),
        .pending = solid(p.panel, fade(p.dim, 0.16)),
        .pending_dot = solid(p.panel, fade(p.dim, 0.75)),
        .hatch_bg = solid(p.panel, pal.hatch_bg),
        .hatch = solid(p.panel, pal.hatch),
        .changed = solid(p.panel, pal.changed),
        .ring = solid(p.panel, mix(p.text, rgb(0xffffff), 0.5)),
        .edge = solid(p.panel, mix(p.crit, rgb(0xffd000), 0.35)),
    };
    for (&out.state, pal.state) |*o, x| o.* = solid(p.panel, x);
    out.state[@intFromEnum(md.State.unmapped)] = out.gap;
    out.state[@intFromEnum(md.State.gap)] = out.gap;
    return out;
}
fn pack(x: Color) [4]u8 {
    var out: [4]u8 = undefined;
    for (&out, x) |*o, v| o.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    return out;
}

/// Base colour and pattern of one looked-up cell (without geometry).
fn style(pt: *const Paint, found: ?Sources.Found, counts: ?*Counts) gpu.Cell {
    var out = gpu.Cell{ .rect = @splat(0), .fill = pack(pt.pending), .accent = pack(pt.pending_dot), .overlay = .{ 0, 0, 0, 0 }, .kind = 2 };
    const f = found orelse {
        if (counts) |k| k.pending += 1;
        return out;
    };
    const look = md.classify(f.cell.*);
    if (counts) |k| switch (look.state) {
        .unknown => k.unknown += 1,
        .unmapped, .gap, .reserved => k.gap += 1,
        .thp => k.thp += 1,
        .mixed => k.mixed += 1,
        .anon => k.anon += 1,
        .file => k.file += 1,
        .zero => k.zero += 1,
        else => k.other += 1,
    };
    out.kind = 0;
    out.accent = .{ 0, 0, 0, 0 };
    switch (look.state) {
        .unknown => {
            out.fill = pack(pt.hatch_bg);
            out.accent = pack(pt.hatch);
            out.kind = 1;
            return out;
        },
        .mixed => {
            out.fill = pack(pt.state[@intFromEnum(md.State.anon)]);
            out.accent = pack(pt.state[@intFromEnum(md.State.thp)]);
            out.kind = 3 | (@as(u32, @intFromFloat(std.math.clamp(look.huge_fraction, 0.1, 0.9) * 255)) << 8);
        },
        else => out.fill = pack(pt.state[@intFromEnum(look.state)]),
    }
    if (look.partial) out.kind |= 4;
    switch (look.change) {
        .changed => {
            out.fill = pack(pt.changed);
            out.kind &= ~@as(u32, 3);
            if (counts) |k| k.changed += 1;
        },
        .collapsed => {
            out.overlay = pack(pt.ring);
            out.kind |= 8;
            if (counts) |k| k.collapsed += 1;
        },
        .split => {
            out.overlay = pack(pt.edge);
            out.kind |= 16;
            if (counts) |k| k.split += 1;
        },
        .none => {},
    }
    return out;
}
fn unpack(x: [4]u8) Color {
    return .{ @as(f32, @floatFromInt(x[0])) / 255, @as(f32, @floatFromInt(x[1])) / 255, @as(f32, @floatFromInt(x[2])) / 255, @as(f32, @floatFromInt(x[3])) / 255 };
}

// --- Geometry -------------------------------------------------------------------------

/// The largest pitch (at least `min_pitch`) whose grid fits the field with at
/// most 65,536 cells.
fn layout(d: *Deep, field: Rect) void {
    d.field = field;
    var p = @max(min_pitch, @sqrt(field.w * field.h / @as(f32, md.max_cells)));
    while (true) : (p *= 1.004) {
        const cols: usize = @intFromFloat(@max(1, @floor(field.w / p)));
        const rows: usize = @intFromFloat(@max(1, @floor(field.h / p)));
        if (cols * rows <= md.max_cells) {
            d.pitch = p;
            d.cols = cols;
            d.rows = rows;
            return;
        }
    }
}
fn cellRect(d: *const Deep, index: usize) Rect {
    const col: f32 = @floatFromInt(index % d.cols);
    const row: f32 = @floatFromInt(index / d.cols);
    const x0 = @round(col * d.pitch);
    const y0 = @round(row * d.pitch);
    const gap: f32 = if (d.pitch >= 6) 1 else 0;
    return .{ .x = d.field.x + x0, .y = d.field.y + y0, .w = @round((col + 1) * d.pitch) - x0 - gap, .h = @round((row + 1) * d.pitch) - y0 - gap };
}
fn indexAt(d: *const Deep, x: f32, y: f32) ?usize {
    if (d.count() == 0 or !draw.inside(d.field, x, y)) return null;
    const col: usize = @intFromFloat(@floor((x - d.field.x) / d.pitch));
    const row: usize = @intFromFloat(@floor((y - d.field.y) / d.pitch));
    if (col >= d.cols or row >= d.rows) return null;
    return row * d.cols + col;
}

/// Fit: the densest cluster of VMAs that one view can hold, at the finest
/// cell size that shows it whole.
pub fn fit(d: *Deep, vmas: []const md.Vma) void {
    if (vmas.len == 0 or d.count() == 0) return;
    const cap = @as(u64, d.count()) * levels[0];
    var best_start: u64 = vmas[0].start;
    var best_end: u64 = vmas[0].end;
    var best_weight: u64 = 0;
    var i: usize = 0;
    while (i < vmas.len) {
        var j = i;
        var weight: u64 = 0;
        while (j < vmas.len and vmas[j].end -| vmas[i].start <= cap) : (j += 1) weight += vmas[j].rss orelse (vmas[j].end - vmas[j].start);
        if (j == i) {
            weight = vmas[i].end - vmas[i].start;
            j = i + 1;
        }
        if (weight > best_weight) {
            best_weight = weight;
            best_start = vmas[i].start;
            best_end = @min(vmas[j - 1].end, vmas[i].start +| cap);
        }
        i = j;
    }
    var level: usize = 0;
    for (levels, 0..) |size, k| {
        const first = best_start - best_start % size;
        if ((best_end - first + size - 1) / size <= d.count()) level = k;
    }
    d.level = level;
    d.moveTo(best_start);
    d.moved = false;
    d.fitted_count = d.count();
}

/// Cell size change anchored at one field cell: its address stays put.
fn zoom(d: *Deep, to: usize, anchor: usize) void {
    if (to == d.level or d.count() == 0) return;
    const k = @min(anchor, d.count() - 1);
    const address = d.origin + @as(u64, k) * d.cell();
    d.level = to;
    const size = d.cell();
    d.moveTo(@as(i128, address - address % size) - @as(i128, k) * size);
}
fn anchorIndex(v: *vw.View) usize {
    const d = &v.memmap.deep;
    return indexAt(d, v.pointer[0], v.pointer[1]) orelse d.count() / 2;
}
fn pan(d: *Deep, cells: i64) void {
    d.moveTo(@as(i128, d.origin) + @as(i128, cells) * d.cell());
}

/// The VMAs the view knows about (the header map's list).
fn vmaList(s: *const mm.State) []const md.Vma {
    return if (s.map()) |x| x.vmas else &.{};
}
/// `[` / `]`: put the previous or next VMA's start at the top-left and select it.
fn jump(v: *vw.View, by: i32, now: u64) void {
    const s = &v.memmap;
    const d = &s.deep;
    const vmas = vmaList(s);
    if (vmas.len == 0) return;
    const focus = d.selected orelse d.origin;
    var target: ?usize = null;
    if (by > 0) {
        for (vmas, 0..) |x, i| if (x.start > focus) {
            target = i;
            break;
        };
    } else {
        var i = vmas.len;
        while (i > 0) {
            i -= 1;
            if (vmas[i].start < focus) {
                target = i;
                break;
            }
        }
    }
    const i = target orelse {
        v.setStatus("No {s} VMA", .{if (by > 0) "later" else "earlier"}, now);
        return;
    };
    d.selected = vmas[i].start;
    d.user().moveTo(vmas[i].start);
    var ab: [32]u8 = undefined;
    v.setStatus("VMA {d} of {d}: {s} {s}", .{ i + 1, vmas.len, std.fmt.bufPrint(&ab, "0x{x}", .{vmas[i].start}) catch "", mm.vmaText(v, vmas[i]) }, now);
}

// --- Input ------------------------------------------------------------------------------

/// Deep-look keys; false hands the key to the shared Memory map keys.
pub fn key(v: *vw.View, sym: u32, shortcut: u32, now: u64) bool {
    const s = &v.memmap;
    const d = &s.deep;
    if (d.count() == 0) return false;
    const page: i64 = @intCast(@max(1, d.rows -| 1) * d.cols);
    const step_rows: i64 = @intCast(@max(1, d.rows / 8) * d.cols);
    const step_cols: i64 = @intCast(@max(1, d.cols / 8));
    switch (sym) {
        0xff52 => pan(d.user(), -step_rows),
        0xff54 => pan(d.user(), step_rows),
        0xff51 => pan(d.user(), -step_cols),
        0xff53 => pan(d.user(), step_cols),
        0xff55 => pan(d.user(), -page),
        0xff56 => pan(d.user(), page),
        0xff1b => {
            if (d.selected == null or s.legend) return false;
            d.selected = null;
        },
        0xff0d, 0xff8d => d.selected = d.hover orelse d.selected,
        else => switch (shortcut) {
            '=', '+' => zoom(d.user(), @min(d.level + 1, levels.len - 1), anchorIndex(v)),
            '-' => zoom(d.user(), d.level -| 1, anchorIndex(v)),
            '0' => {
                fit(d, vmaList(s));
                v.setStatus("Fit: {s} cells", .{sizeText(d.cell())}, now);
            },
            '[' => jump(v, -1, now),
            ']' => jump(v, 1, now),
            else => return false,
        },
    }
    return true;
}
/// Wheel: up zooms in, down zooms out, anchored at the pointer.
pub fn wheel(v: *vw.View, lines: i32) void {
    const d = &v.memmap.deep;
    if (lines == 0 or d.count() == 0) return;
    const to = if (lines < 0) @min(d.level + 1, levels.len - 1) else d.level -| 1;
    zoom(d.user(), to, anchorIndex(v));
}
/// Left press: in the field it starts a drag (or a click); in the minimap it
/// centres the view there. False when the press is elsewhere.
pub fn press(v: *vw.View, x: f32, y: f32) bool {
    const d = &v.memmap.deep;
    if (d.count() == 0) return false;
    if (draw.inside(d.field, x, y)) {
        d.drag = .{ .x = x, .y = y, .origin = d.origin };
        return true;
    }
    if (draw.inside(d.mini, x, y)) {
        if (miniAddress(x)) |address| d.user().moveTo(@as(i128, address) - @as(i128, d.span() / 2));
        return true;
    }
    return false;
}
fn dragDelta(d: *const Deep, x: f32, y: f32) i64 {
    const g = d.drag.?;
    const cols: i64 = @intFromFloat(@round((x - g.x) / d.pitch));
    const rows: i64 = @intFromFloat(@round((y - g.y) / d.pitch));
    return rows * @as(i64, @intCast(d.cols)) + cols;
}
pub fn motion(v: *vw.View) void {
    const d = &v.memmap.deep;
    const g = &(d.drag orelse return);
    if (@abs(v.pointer[0] - g.x) + @abs(v.pointer[1] - g.y) >= 3) g.moved = true;
    if (!g.moved) return;
    d.user().moveTo(@as(i128, g.origin) - @as(i128, dragDelta(d, v.pointer[0], v.pointer[1])) * d.cell());
}
pub fn release(v: *vw.View, x: f32, y: f32) void {
    const d = &v.memmap.deep;
    const g = d.drag orelse return;
    defer d.drag = null;
    if (!g.moved and @abs(x - g.x) + @abs(y - g.y) < 3) {
        const i = indexAt(d, x, y) orelse return;
        const address = d.origin + @as(u64, i) * d.cell();
        d.selected = if (d.selected != null and d.selected.? == address) null else address;
        return;
    }
    d.user().moveTo(@as(i128, g.origin) - @as(i128, dragDelta(d, x, y)) * d.cell());
}

// --- Minimap ------------------------------------------------------------------------------

const Island = struct { start: u64, end: u64, x: f32, w: f32 };
var islands: [64]Island = undefined;
var island_count: usize = 0;
var mini_rect: Rect = zero_rect;
const break_w: f32 = 12;

/// Islands of VMAs (gaps over 1 GiB compressed to a fixed break), each as
/// wide as the square root of its span: big and small regions both show.
fn layoutMini(vmas: []const md.Vma, r: Rect) void {
    mini_rect = r;
    island_count = 0;
    for (vmas) |x| {
        if (island_count > 0 and x.start -| islands[island_count - 1].end <= island_gap) {
            islands[island_count - 1].end = @max(islands[island_count - 1].end, x.end);
        } else if (island_count < islands.len) {
            islands[island_count] = .{ .start = x.start, .end = x.end, .x = 0, .w = 0 };
            island_count += 1;
        } else islands[island_count - 1].end = @max(islands[island_count - 1].end, x.end);
    }
    if (island_count == 0) return;
    var total: f32 = 0;
    for (islands[0..island_count]) |is| total += @sqrt(@as(f32, @floatFromInt(is.end - is.start)));
    const room = r.w - break_w * @as(f32, @floatFromInt(island_count + 1));
    var x = r.x + break_w;
    for (islands[0..island_count]) |*is| {
        is.x = x;
        is.w = @max(2, room * @sqrt(@as(f32, @floatFromInt(is.end - is.start))) / total);
        x += is.w + break_w;
    }
}
fn frac(a: u64, lo: u64, hi: u64) f32 {
    if (hi <= lo) return 0;
    return @floatCast(@as(f64, @floatFromInt(@min(a, hi) -| lo)) / @as(f64, @floatFromInt(hi - lo)));
}
fn miniX(address: u64) f32 {
    if (island_count == 0) return mini_rect.x;
    const first = islands[0];
    if (address < first.start) return mini_rect.x + break_w * frac(address, 0, first.start);
    for (islands[0..island_count], 0..) |is, i| {
        if (address <= is.end) return is.x + is.w * frac(address, is.start, is.end);
        const next_start = if (i + 1 < island_count) islands[i + 1].start else top_address;
        if (address < next_start) return is.x + is.w + break_w * frac(address, is.end, next_start);
    }
    return mini_rect.x + mini_rect.w;
}
fn miniAddress(x: f32) ?u64 {
    if (island_count == 0) return null;
    for (islands[0..island_count]) |is| {
        if (x < is.x) return is.start;
        if (x <= is.x + is.w) return is.start + @as(u64, @intFromFloat(@as(f64, @floatCast(std.math.clamp((x - is.x) / is.w, 0, 1))) * @as(f64, @floatFromInt(is.end - is.start))));
    }
    return islands[island_count - 1].end;
}
fn vmaColor(pt: *const Paint, x: md.Vma) Color {
    if (std.mem.startsWith(u8, x.perms, "---")) return pt.state[@intFromEnum(md.State.not_present)];
    return switch (x.kind) {
        .anon, .heap, .stack => pt.state[@intFromEnum(md.State.anon)],
        .file => pt.state[@intFromEnum(md.State.file)],
        .special => pt.state[@intFromEnum(md.State.unmovable)],
        .hugetlb => pt.state[@intFromEnum(md.State.thp)],
        .pseudo => pt.state[@intFromEnum(md.State.swapped)],
    };
}
fn drawMini(ctx: Ctx, d: *const Deep, vmas: []const md.Vma, pt: *const Paint) !void {
    const r = mini_rect;
    try ctx.r.rect(r, pt.gap);
    for (islands[0..island_count], 0..) |is, i| {
        // Compressed gap marks between islands.
        const bx = is.x - break_w;
        if (i > 0 or is.x > r.x + break_w * 0.5) {
            try ctx.thin(.{ bx + 3, r.y + r.h - 4 }, .{ bx + 7, r.y + 4 }, 1, fade(ctx.p.dim, 0.7));
            try ctx.thin(.{ bx + 6, r.y + r.h - 4 }, .{ bx + 10, r.y + 4 }, 1, fade(ctx.p.dim, 0.7));
        }
    }
    var last_x: f32 = -1;
    for (vmas) |x| {
        const x0 = miniX(x.start);
        const x1 = @max(x0 + 1, miniX(x.end));
        if (@floor(x1) <= last_x) continue;
        last_x = @floor(x0);
        const box = Rect{ .x = x0, .y = r.y + 3, .w = x1 - x0, .h = r.h - 6 };
        try ctx.r.rect(box, vmaColor(pt, x));
        // THP share of the VMA (smaps AnonHugePages), from the bottom.
        if (x.anon_huge) |huge| if (huge > 0) {
            const f = std.math.clamp(@as(f32, @floatFromInt(huge)) / @as(f32, @floatFromInt(x.end - x.start)), 0.08, 1);
            try ctx.r.rect(.{ .x = box.x, .y = box.y + box.h * (1 - f), .w = box.w, .h = box.h * f }, pt.state[@intFromEnum(md.State.thp)]);
        };
    }
    // The viewport box, at least 3 px wide so it never vanishes.
    const bx0 = miniX(d.origin);
    const bx1 = @max(bx0 + 3, miniX(d.origin + d.span()));
    try ctx.r.shape(.{ .x = bx0 - 1, .y = r.y, .w = bx1 - bx0 + 2, .h = r.h }, ctx.p.text, .{ .border = 2 });
}

// --- Rendering ------------------------------------------------------------------------------

var cache: [md.max_cells]gpu.Cell = undefined;
var swatches: [24]gpu.Cell = undefined;
var audited: [12]u64 = @splat(0);
var audited_detail: u64 = 0;

fn sizeText(bytes: u64) []const u8 {
    return switch (bytes) {
        2 << 20 => "2 MiB",
        1 << 20 => "1 MiB",
        512 << 10 => "512 KiB",
        256 << 10 => "256 KiB",
        128 << 10 => "128 KiB",
        64 << 10 => "64 KiB",
        32 << 10 => "32 KiB",
        16 << 10 => "16 KiB",
        8 << 10 => "8 KiB",
        else => "4 KiB",
    };
}

pub fn render(v: *vw.View, ctx: Ctx, rect: Rect, now: u64) !void {
    const s = &v.memmap;
    const d = &s.deep;
    const p = ctx.p;
    const pt = paint(p);
    var buf: [256]u8 = undefined;
    var lb: [96]u8 = undefined;
    const side_w = try mm.sidePanels(v, ctx, rect);
    const main = Rect{ .x = rect.x + side_w, .y = rect.y, .w = rect.w - side_w, .h = rect.h };
    try ctx.panel(main);
    const mp = s.map();
    const x0 = main.x + 14;
    const inner_w = main.w - 28;
    // Row 1: process, worker cost.
    const cost = mm.costText(v, &buf);
    const cost_w = @min(ctx.measure(cost), inner_w * 0.55);
    try ctx.textFit(main.x + main.w - 14 - cost_w, main.y + 8, cost_w, cost, p.dim);
    try ctx.textFit(x0, main.y + 8, inner_w - cost_w - 24, mm.label(v, &lb), p.text);
    // Row 2: coverage (whole process), cadence and age.
    var fb: [96]u8 = undefined;
    const fresh: []const u8 = if (mp) |x| mm.freshness(v, x, now, &fb) else "Refresh unknown · waiting";
    const fresh_w = @min(ctx.measure(fresh), inner_w * 0.45);
    try ctx.textFit(main.x + main.w - 14 - fresh_w, main.y + 34, fresh_w, fresh, if (mp != null and md.cadence(mp.?, null).cost_limited) p.warn else p.dim);
    const cov = if (mp) |x| md.coverage(x) else md.Coverage{ .unknown = "no sample" };
    const bar = Rect{ .x = x0, .y = main.y + 37, .w = @min(160, inner_w * 0.2), .h = 12 };
    if (cov == .value) {
        try ctx.r.rect(bar, fade(p.accent, p.ghost + 0.05));
        try ctx.r.rect(.{ .x = bar.x, .y = bar.y, .w = bar.w * @as(f32, @floatCast(cov.value.fraction)), .h = bar.h }, p.accent);
    } else try ctx.hatch(bar);
    var nb: [32]u8 = undefined;
    var db: [32]u8 = undefined;
    const ctext: []const u8 = switch (cov) {
        .value => |val| std.fmt.bufPrint(&buf, "{d:.1}% THP coverage (whole process) · {s} of {s}", .{ val.fraction * 100, m.bytes(&nb, @floatFromInt(val.numerator)), m.bytes(&db, @floatFromInt(val.denominator)) }) catch "",
        .none => if (s.target == null) "system view" else "nothing THP-eligible",
        .unknown => |why| std.fmt.bufPrint(&buf, "coverage unknown: {s}", .{why}) catch "",
    };
    try ctx.textFit(bar.x + bar.w + 12, main.y + 34, inner_w - bar.w - 12 - fresh_w - 24, ctext, if (cov == .unknown) p.warn else p.text);
    // Row 3: the viewport and its request state.
    const live = v.action_hook != null;
    const pend_text: []const u8 = if (s.target == null) "" else if (!live) (if (d.counts.pending > 0) "pending: not recorded in this replay" else "replay viewport") else if (d.pending)
        (std.fmt.bufPrint(&nb, "viewport pending {d:.1} s", .{@as(f64, @floatFromInt(now -| d.pending_since)) / 1e9}) catch "")
    else if (d.counts.pending > 0) "viewport requested" else "viewport sampled";
    const pend_w = ctx.measure(pend_text);
    try ctx.textFit(main.x + main.w - 14 - pend_w, main.y + 60, pend_w, pend_text, if (d.pending or d.counts.pending > 0) p.warn else p.dim);
    const field_top = main.y + 116;
    // Bottom: details (three lines) and the legend.
    const legend_h: f32 = if (inner_w < legendWidth(ctx)) 44 else 22;
    const details_h: f32 = 66;
    const field = Rect{ .x = x0, .y = field_top, .w = inner_w, .h = main.h - (field_top - main.y) - details_h - legend_h - 22 };
    if (s.compact or field.h < 40) return;
    layout(d, field);
    const vmas = vmaList(s);
    if (s.target != null and vmas.len > 0 and (!d.placed or !d.moved and d.fitted_count != d.count())) {
        fit(d, vmas);
        d.placed = true;
    }
    if (d.count() > 0) d.moveTo(d.origin);
    const vtext = std.fmt.bufPrint(&buf, "{s} cells · {d} × {d} = {d} · 0x{x}–0x{x}", .{ sizeText(d.cell()), d.cols, d.rows, d.count(), d.origin, d.origin + d.span() }) catch "";
    try ctx.textFit(x0, main.y + 60, inner_w - pend_w - 24, vtext, p.dim);
    // Minimap.
    layoutMini(vmas, .{ .x = x0, .y = main.y + 86, .w = inner_w, .h = 22 });
    d.mini = mini_rect;
    try drawMini(ctx, d, vmas, &pt);

    if (s.target == null) {
        try ctx.hatchLight(.{ .x = field.x, .y = field.y, .w = field.w, .h = 60 });
        try ctx.textFit(field.x + 12, field.y + 20, field.w - 24, "The deep map is per process: pick one with o (the system view has no address space)", p.dim);
        return legend(v, ctx, .{ .x = x0, .y = field.y + field.h + details_h + 18, .w = inner_w, .h = legend_h }, &pt);
    }
    // Exited, denied or reused: say so instead of drawing a field. A pending
    // map is not a problem: its cells draw as pending.
    if (mp) |x| if (x.process) |proc| if (!std.mem.eql(u8, proc.maps.state, "pending")) if (md.processProblem(&s.message, proc)) |why| {
        try ctx.hatchLight(.{ .x = field.x, .y = field.y, .w = field.w, .h = 60 });
        try ctx.textFit(field.x + 12, field.y + 20, field.w - 24, why, p.dim);
        return;
    };

    // The field: one instanced batch, rebuilt only when its inputs change or
    // while a new publication eases in.
    try ctx.r.rect(field, pt.gap);
    const started = md.threadNs();
    const e = s.ease(now);
    var src = sources(s, false);
    var key_hasher = std.hash.Wyhash.init(0);
    key_hasher.update(std.mem.asBytes(&d.origin));
    key_hasher.update(std.mem.asBytes(&d.level));
    key_hasher.update(std.mem.asBytes(&d.cols));
    key_hasher.update(std.mem.asBytes(&d.rows));
    key_hasher.update(std.mem.asBytes(&field));
    key_hasher.update(std.mem.asBytes(&d.pitch));
    key_hasher.update(std.mem.asBytes(&p));
    for (src.maps[0..src.n]) |x| key_hasher.update(std.mem.asBytes(&x));
    const key_now = key_hasher.final();
    const count = d.count();
    if (key_now != d.cache_key or e < 1) {
        var prev_src = sources(s, true);
        var counts: Counts = .{};
        const cell_bytes = d.cell();
        for (0..count) |i| {
            const address = d.origin + @as(u64, i) * cell_bytes;
            var out = style(&pt, src.find(cell_bytes, address), &counts);
            if (e < 1) if (prev_src.find(cell_bytes, address)) |old| {
                const before = style(&pt, old, null);
                if (before.kind & 3 != 2) out.fill = pack(mix(unpack(before.fill), unpack(out.fill), e));
            };
            const r = cellRect(d, i);
            out.rect = .{ r.x, r.y, r.w, r.h };
            cache[i] = out;
        }
        d.counts = counts;
        d.cache_key = if (e < 1) 0 else key_now;
        d.perf.builds += 1;
        const took = md.threadNs() -| started;
        d.perf.build_ns += took;
        d.perf.build_max = @max(d.perf.build_max, took);
    }
    const saved = ctx.r.clip;
    ctx.r.clip = draw.intersect(saved, field);
    const out = try ctx.r.cells(count);
    @memcpy(out, cache[0..count]);
    ctx.r.clip = saved;

    // Hover and selection outlines, above the cells.
    d.hover = null;
    if (d.drag == null) if (indexAt(d, v.pointer[0], v.pointer[1])) |i| {
        d.hover = d.origin + @as(u64, i) * d.cell();
    };
    for ([_]?u64{ d.hover, d.selected }, 0..) |which, k| if (which) |address| {
        if (address < d.origin or address >= d.origin + d.span()) continue;
        const r = cellRect(d, @intCast((address - d.origin) / d.cell()));
        const outer = Rect{ .x = r.x - 2, .y = r.y - 2, .w = r.w + 4, .h = r.h + 4 };
        try ctx.r.shape(outer, if (k == 0) p.text else rgb(0xffd000), .{ .border = 2 });
    };
    // Details: the hovered cell, else the selected one.
    try details(v, ctx, .{ .x = x0, .y = field.y + field.h + 8, .w = inner_w, .h = details_h }, &src);
    try legend(v, ctx, .{ .x = x0, .y = field.y + field.h + details_h + 18, .w = inner_w, .h = legend_h }, &pt);
    if (v.layout != null) audit(d);
}

fn details(v: *vw.View, ctx: Ctx, r: Rect, src: *Sources) !void {
    const s = &v.memmap;
    const d = &s.deep;
    const p = ctx.p;
    try ctx.r.shape(r, fade(p.raised, 0.6), .{ .radii = @splat(4) });
    const which = d.hover orelse d.selected;
    const label_: []const u8 = if (d.hover != null) "Hover" else if (d.selected != null) "Selected" else "";
    var l1: [256]u8 = undefined;
    var l2: [256]u8 = undefined;
    var l3: [256]u8 = undefined;
    var lines: [3][]const u8 = .{ "Hover or click a cell for its range, VMA, mapping, state bits and the VMA's NUMA totals", "", "" };
    if (which) |address| {
        const size = d.cell();
        if (src.find(size, address)) |f| {
            lines = describe(v, f, address, size, label_, &l1, &l2, &l3);
        } else {
            lines[0] = std.fmt.bufPrint(&l1, "{s} 0x{x}–0x{x} · pending: {s}", .{ label_, address, address + size, if (v.action_hook == null) "this zoom and range were not recorded in the replay" else "requested, not yet sampled at this cell size" }) catch "";
            lines[1] = "No data is shown for pending cells; the previous view's cells are never relabelled.";
            lines[2] = "";
        }
    }
    for (lines, 0..) |line, k| if (line.len > 0)
        try ctx.textFit(r.x + 10, r.y + 3 + @as(f32, @floatFromInt(k)) * 20, r.w - 20, line, if (k == 0) p.text else p.dim);
    if (v.layout != null) {
        var hv = std.hash.Wyhash.init(1);
        for (lines) |line| hv.update(line);
        const h = hv.final();
        if (h != audited_detail) {
            audited_detail = h;
            std.debug.print("xodb: memmap deep detail {s} | {s} | {s}\n", .{ lines[0], lines[1], lines[2] });
        }
    }
}
fn describe(v: *vw.View, f: Sources.Found, address: u64, size: u64, label_: []const u8, l1: []u8, l2: []u8, l3: []u8) [3][]const u8 {
    const cell = f.cell.*;
    const look = md.classify(cell);
    var out: [3][]const u8 = .{ "", "", "" };
    const vma: ?md.Vma = if (cell.vma) |i| (if (i < f.map.vmas.len) f.map.vmas[i] else null) else null;
    var sb: [5][24]u8 = undefined;
    const vma_text: []const u8 = if (vma) |x| mm.vmaText(v, x) else if (cell.mapping_known) "no VMA (unmapped)" else "mapping unknown";
    const perms: []const u8 = if (vma) |x| x.perms else "";
    out[0] = std.fmt.bufPrint(l1, "{s} 0x{x}–0x{x} ({s}) · {s} {s} · {s}", .{ label_, address, address + size, sizeText(size), perms, vma_text, if (look.change != .none) md.changeName(look.change) else md.stateName(look.state) }) catch "";
    var kb: [64]u8 = undefined;
    out[1] = std.fmt.bufPrint(l2, "mapped {s} · present {s} · huge {s} · zero {s} · swapped {s} · known: {s}{s}", .{
        m.bytes(&sb[0], @floatFromInt(cell.mapped)),
        m.bytes(&sb[1], @floatFromInt(cell.present)),
        m.bytes(&sb[2], @floatFromInt(cell.huge)),
        m.bytes(&sb[3], @floatFromInt(cell.zero)),
        m.bytes(&sb[4], @floatFromInt(cell.swapped)),
        md.knownText(&kb, cell.known),
        if (cell.zero > 0) " · huge zero page counted as zero, not THP" else if (look.partial) " · partly observed (hatched)" else "",
    }) catch "";
    out[2] = numaText(f.map, vma, l3);
    return out;
}
/// NUMA as the whole VMA's totals only: numa_maps has no per-page node.
fn numaText(map: *const md.Map, vma: ?md.Vma, buf: []u8) []const u8 {
    const x = vma orelse return "VMA totals: no VMA";
    const nodes = x.numa_vma_totals orelse {
        const st = if (map.process) |p| p.numa else md.Status{};
        return std.fmt.bufPrint(buf, "VMA totals (NUMA): {s}: {s}", .{ st.state, st.reason }) catch "";
    };
    var w = (std.fmt.bufPrint(buf, "VMA totals (whole VMA, not per page){s}:", .{if (x.numa_partial) ", partial" else ""}) catch return "").len;
    const page = x.numa_page_size orelse 4096;
    for (nodes) |n| {
        var nb: [24]u8 = undefined;
        const piece = std.fmt.bufPrint(buf[w..], " N{d} {s}", .{ n.node, m.bytes(&nb, @floatFromInt(n.pages * page)) }) catch break;
        w += piece.len;
    }
    if (nodes.len == 0) if (std.fmt.bufPrint(buf[w..], " none resident", .{})) |piece| {
        w += piece.len;
    } else |_| {};
    return buf[0..w];
}

const chip_names = [_][]const u8{ "THP", "part THP", "4 KiB", "file", "zero page", "swapped", "not present", "unmovable", "gap", "unknown", "pending", "changed", "collapse ring", "split edge" };
fn legendWidth(ctx: Ctx) f32 {
    var w: f32 = 0;
    for (chip_names) |name| w += 18 + ctx.measure(name) + 16;
    return w;
}
/// Legend chips drawn with the same cell pipeline as the field.
fn legend(v: *vw.View, ctx: Ctx, r: Rect, pt: *const Paint) !void {
    _ = v;
    const p = ctx.p;
    const Chip = struct { []const u8, gpu.Cell };
    const plain = struct {
        fn of(x: Color) gpu.Cell {
            return .{ .rect = @splat(0), .fill = pack(x), .accent = .{ 0, 0, 0, 0 }, .overlay = .{ 0, 0, 0, 0 }, .kind = 0 };
        }
    }.of;
    var mixed = plain(pt.state[@intFromEnum(md.State.anon)]);
    mixed.accent = pack(pt.state[@intFromEnum(md.State.thp)]);
    mixed.kind = 3 | (128 << 8);
    var unknown = plain(pt.hatch_bg);
    unknown.accent = pack(pt.hatch);
    unknown.kind = 1;
    var pending = plain(pt.pending);
    pending.accent = pack(pt.pending_dot);
    pending.kind = 2;
    var collapsed = plain(pt.state[@intFromEnum(md.State.thp)]);
    collapsed.overlay = pack(pt.ring);
    collapsed.kind = 8;
    var split = plain(pt.state[@intFromEnum(md.State.anon)]);
    split.overlay = pack(pt.edge);
    split.kind = 16;
    const chips = [_]Chip{
        .{ "THP", plain(pt.state[@intFromEnum(md.State.thp)]) },
        .{ "part THP", mixed },
        .{ "4 KiB", plain(pt.state[@intFromEnum(md.State.anon)]) },
        .{ "file", plain(pt.state[@intFromEnum(md.State.file)]) },
        .{ "zero page", plain(pt.state[@intFromEnum(md.State.zero)]) },
        .{ "swapped", plain(pt.state[@intFromEnum(md.State.swapped)]) },
        .{ "not present", plain(pt.state[@intFromEnum(md.State.not_present)]) },
        .{ "unmovable", plain(pt.state[@intFromEnum(md.State.unmovable)]) },
        .{ "gap", plain(pt.gap) },
        .{ "unknown", unknown },
        .{ "pending", pending },
        .{ "changed", plain(pt.changed) },
        .{ "collapse ring", collapsed },
        .{ "split edge", split },
    };
    var lx = r.x;
    var ly = r.y;
    var n: usize = 0;
    for (chips) |chip| {
        const w = 18 + ctx.measure(chip[0]) + 16;
        if (lx + w > r.x + r.w) {
            lx = r.x;
            ly += 22;
        }
        if (ly + 18 > r.y + r.h + 4) break;
        swatches[n] = chip[1];
        swatches[n].rect = .{ lx, ly + 4, 12, 12 };
        n += 1;
        try ctx.text(lx + 18, ly, chip[0], p.dim);
        lx += w;
    }
    const out = try ctx.r.cells(n);
    @memcpy(out, swatches[0..n]);
}

/// With the layout audit on, tests learn the field geometry and what it shows.
fn audit(d: *const Deep) void {
    const k = d.counts;
    const now_ = [12]u64{ @intFromFloat(d.field.x * 10), @intFromFloat(d.field.y * 10), @intFromFloat(d.pitch * 1000), d.cols, d.rows, d.origin, d.cell(), k.pending, k.unknown, k.split + k.collapsed * 7 + k.changed * 131, @intFromFloat(miniX(d.origin) * 10), k.zero };
    if (std.mem.eql(u64, &now_, &audited)) return;
    audited = now_;
    std.debug.print("xodb: memmap deep x={d:.1} y={d:.1} pitch={d:.3} cols={d} rows={d} origin=0x{x} cell={d} count={d} pending={d} unknown={d} gap={d} thp={d} mixed={d} anon={d} file={d} zero={d} other={d} changed={d} collapsed={d} split={d} mini={d:.1},{d:.1},{d:.1},{d:.1} box={d:.1}..{d:.1}\n", .{
        d.field.x, d.field.y, d.pitch,  d.cols,   d.rows,          d.origin,                   d.cell(), d.count(), k.pending, k.unknown, k.gap, k.thp, k.mixed, k.anon, k.file, k.zero, k.other, k.changed, k.collapsed, k.split,
        d.mini.x,  d.mini.y,  d.mini.w, d.mini.h, miniX(d.origin), miniX(d.origin + d.span()),
    });
}
/// Called for every look: the deep look reports its cell count, the others 0.
pub fn perfLine(v: *vw.View, d: *Deep, look: []const u8, cells: usize, now: u64) void {
    if (c.getenv("XODB_MEMMAP_PERF") == null) return;
    const pf = &d.perf;
    if (pf.window_start == 0) pf.window_start = now;
    pf.frames += 1;
    pf.frame_ns += v.last_frame_ns;
    pf.frame_max = @max(pf.frame_max, v.last_frame_ns);
    if (now -| pf.window_start < 1_000_000_000) return;
    const secs = @as(f64, @floatFromInt(now - pf.window_start)) / 1e9;
    std.debug.print("xodb: memmap perf look={s} frames={d} fps={d:.1} cells={d} frame_cpu_ms_avg={d:.3} frame_cpu_ms_max={d:.3} builds={d} build_ms_avg={d:.3} build_ms_max={d:.3}\n", .{
        look,                                                                            pf.frames,                                   @as(f64, @floatFromInt(pf.frames)) / secs, cells,
        @as(f64, @floatFromInt(pf.frame_ns)) / 1e6 / @as(f64, @floatFromInt(pf.frames)), @as(f64, @floatFromInt(pf.frame_max)) / 1e6, pf.builds,                                 if (pf.builds == 0) 0 else @as(f64, @floatFromInt(pf.build_ns)) / 1e6 / @as(f64, @floatFromInt(pf.builds)),
        @as(f64, @floatFromInt(pf.build_max)) / 1e6,
    });
    pf.* = .{ .window_start = now };
}

test "deep field geometry stays within 65,536 cells and zoom keeps the anchor" {
    var d = Deep{};
    layout(&d, .{ .x = 0, .y = 0, .w = 1560, .h = 760 });
    try std.testing.expect(d.count() <= md.max_cells and d.count() > 60000);
    layout(&d, .{ .x = 0, .y = 0, .w = 900, .h = 400 });
    try std.testing.expect(d.pitch >= min_pitch and d.count() <= md.max_cells);
    d.level = 5;
    d.moveTo(0x7f0000000000);
    const k: usize = 1234;
    const address = d.origin + k * d.cell();
    zoom(&d, levels.len - 1, k);
    try std.testing.expectEqual(address, d.origin + k * d.cell());
    zoom(&d, 0, k);
    try std.testing.expect(d.origin % levels[0] == 0);
    try std.testing.expect(address >= d.origin + k * d.cell() and address < d.origin + (k + 1) * d.cell());
    d.moveTo(-5);
    try std.testing.expectEqual(@as(u64, 0), d.origin);
}

test "fit picks the densest VMA cluster at the finest cell size that holds it" {
    var d = Deep{};
    layout(&d, .{ .x = 0, .y = 0, .w = 1560, .h = 760 });
    const vmas = [_]md.Vma{
        .{ .start = 0x555555400000, .end = 0x555555400000 + (8 << 20) },
        .{ .start = 0x7f3a00000000, .end = 0x7f3a00000000 + (1 << 30) },
        .{ .start = 0x7f3a40000000, .end = 0x7f3a40000000 + (256 << 20) },
        .{ .start = 0x7ffd40000000, .end = 0x7ffd40000000 + (8 << 20) },
    };
    fit(&d, &vmas);
    try std.testing.expectEqual(@as(u64, 0x7f3a00000000), d.origin);
    try std.testing.expect(d.cell() * d.count() >= (1 << 30) + (256 << 20));
    try std.testing.expect(d.level > 0 and d.cell() / 2 * d.count() < (1 << 30) + (256 << 20));
}

test "cells: pending is not data, unknown hatched, huge zero page not THP, change kinds apart" {
    const p = @import("theme.zig").all[0];
    const pt = paint(&p);
    var k: Counts = .{};
    try std.testing.expectEqual(@as(u32, 2), style(&pt, null, &k).kind);
    const B: u64 = 4096;
    const all = md.present_bit | md.swapped_bit | md.file_bit | md.huge_bit | md.zero_bit;
    const map = md.Map{};
    const zero = md.Cell{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .zero = B, .known = all };
    const z = style(&pt, .{ .map = &map, .cell = &zero }, &k);
    try std.testing.expect(!std.mem.eql(u8, &z.fill, &pack(pt.state[@intFromEnum(md.State.thp)])));
    const unknown = md.Cell{ .start = 0, .end = B, .mapped = B };
    try std.testing.expectEqual(@as(u32, 1), style(&pt, .{ .map = &map, .cell = &unknown }, &k).kind & 3);
    var thp = md.Cell{ .start = 0, .end = B, .mapped = B, .observed = B, .present = B, .huge = B, .known = all, .pmd_known = true, .collapsed = B };
    const ring = style(&pt, .{ .map = &map, .cell = &thp }, &k);
    thp.collapsed = 0;
    thp.split = B;
    const edge = style(&pt, .{ .map = &map, .cell = &thp }, &k);
    thp.split = 0;
    thp.changed = md.present_bit;
    thp.change_known = md.present_bit;
    const changed = style(&pt, .{ .map = &map, .cell = &thp }, &k);
    try std.testing.expect(ring.kind & 8 != 0 and ring.kind & 16 == 0);
    try std.testing.expect(edge.kind & 16 != 0 and edge.kind & 8 == 0);
    try std.testing.expect(changed.kind & 24 == 0 and !std.mem.eql(u8, &changed.fill, &ring.fill));
    try std.testing.expectEqual(@as(usize, 1), k.pending);
    try std.testing.expectEqual(@as(usize, 1), k.zero);
}
