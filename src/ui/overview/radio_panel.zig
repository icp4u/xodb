//! The Radio panel (burrito mode): is it the microwave, and which channels
//! does it hit? The total-energy spectrum across 2.40-2.50 GHz (live bars
//! coloured by what the detector says each MHz is, a peak hold, a slowly
//! decaying max ghost, the 14 channel masks outlined beneath, each swept
//! region's age), the 14-channel strip below it (one lane per channel at its
//! true centre, scrolling: power, floor, power over the floor, busy share,
//! frames/s or retries), per-channel traffic, the verdicts in words, and the
//! cards. Drag across the spectrum or the strip to focus the sensors on a
//! span (they retune at once; the view zooms with a pop and the bars spring
//! up as samples land); double-click or Esc returns to the sweep. R2's
//! waterfall (time across) is the other view of the strip area.
//!
//! Cheap: every sample is added once (spectrum rows, strip cells, waterfall
//! columns); the verdicts are computed off the GUI thread once a second; a
//! frame is drawn when samples landed (at most 10 per second) or while the
//! pop animates (1.2 s after a focus change).
//!
//! This file holds the panel's state and does not import the view, so the
//! view can own it; the panel is drawn in panels.zig.
const std = @import("std");
const draw = @import("draw.zig");
pub const radio = @import("../../radio/radio.zig");

pub const sweep = radio.sweep;
const channels_mod = radio.channels;

pub const span_ns: u64 = 30_000_000_000;
/// The channel verdict window: long enough for two sweeps of every window.
const channels_ns: u64 = 12_000_000_000;
/// The strip: 500 ms rows, a minute of them.
pub const strip_rows = 120;
pub const strip_row_ns: u64 = 500_000_000;
/// The spectrum's dBm axis (per FFT bin).
pub const spec_floor_dbm: f32 = -118;
pub const spec_top_dbm: f32 = -38;
/// Data-driven frames at most this often; the pop animates at the view's 30 fps.
const data_frame_ns: u64 = 100_000_000;
const pop_ns: u64 = 1_200_000_000;
const zoom_ns: f32 = 450_000_000;
const peak_hold_ns: u64 = 1_500_000_000;

pub const Metric = enum { power, floor, over_floor, busy, frames, retry };
pub const metric_names = [_][]const u8{ "power", "floor", "over floor", "busy", "frames/s", "retry" };
pub const Mode = enum { channels, waterfall };
/// What the panel's chips do (the view routes clicks here).
pub const Click = union(enum) { metric: Metric, mode: Mode, sweep, fixed };
pub const columns = 150;
pub const col_ns: u64 = span_ns / columns;
/// One row per FFT bin across 2400-2500 MHz; the panel shows the observed rows.
pub const grid_lo_mhz: f32 = 2400;
pub const max_rows = 280;
const refresh_ns: u64 = 1_000_000_000;
const cards_ns: u64 = 5_000_000_000;
/// dBm (i8) to milliwatts, for mean power per cell.
const linear = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (0..256) |i| t[i] = std.math.pow(f32, 10, @as(f32, @floatFromInt(@as(i8, @bitCast(@as(u8, @intCast(i)))))) / 10);
    break :blk t;
};

/// The verdict and the cards, computed off the GUI thread once a second.
const Job = struct {
    arena: std.heap.ArenaAllocator,
    redact: bool,
    m: *radio.Monitor,
    want_cards: bool,
    report: ?radio.Report = null,
    chan: ?radio.ChannelsOut = null,
    buckets: [100]channels_mod.Bucket = @splat(.{}),
    cards: ?radio.Radios = null,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    fn run(self: *Job) void {
        const a = self.arena.allocator();
        const now = radio.fsx.monotonicNs();
        self.report = radio.reportBetween(a, self.m, now -| span_ns, now, self.redact) catch null;
        const revisit: u64 = @as(u64, self.m.planInfo().plan.revisitMs()) * 1_000_000;
        var full: channels_mod.Report = undefined;
        self.chan = radio.channelsBetween(a, self.m, now -| @max(channels_ns, 3 * revisit), now, &full) catch null;
        if (self.chan != null) self.buckets = full.buckets;
        if (self.want_cards) self.cards = radio.radios(a, radio.defaults.roots) catch null;
        self.done.store(true, .release);
    }
};

/// One strip cell: one channel over one 500 ms row.
pub const Cell = struct {
    mw: f32 = 0,
    noise_mw: f32 = 0,
    n: u16 = 0,
    on: u16 = 0,
    frames: u32 = 0,
    retries: u32 = 0,
    eligible: u32 = 0,
    bad: u32 = 0,
    watched_ms: u32 = 0,
};
const Strip = struct {
    row_id: [strip_rows]u64 = @splat(std.math.maxInt(u64)),
    cells: [strip_rows][14]Cell = undefined,
};
pub const Drag = struct { x0: f32, x1: f32 };

const Grid = struct {
    col_id: [columns]u64 = @splat(std.math.maxInt(u64)),
    sum: [columns][max_rows]f32 = undefined,
    cnt: [columns][max_rows]u16 = undefined,
    band_max: [columns]?f32 = @splat(null),
    cells: [columns * max_rows]?i8 = undefined,
};

pub const State = struct {
    /// Holds `report` and `cards` from the last finished job.
    arena: ?std.heap.ArenaAllocator = null,
    job: ?*Job = null,
    built_ns: u64 = 0,
    cards_built_ns: u64 = 0,
    report: ?radio.Report = null,
    cards: ?radio.Radios = null,
    cards_arena: ?std.heap.ArenaAllocator = null,
    // The waterfall, kept incrementally: columns on the absolute monotonic
    // grid (col_ns), a ring of `columns`; each new sample is added once.
    grid: ?*Grid = null,
    seen_ns: u64 = 0,
    row_lo: usize = max_rows,
    row_hi: usize = 0,
    /// Generation of the waterfall: bumps when a sample lands.
    generation: u64 = 0,
    /// Display copies, oldest column first (the first columns * rows entries).
    cells: []?i8 = &.{},
    cells_generation: u64 = std.math.maxInt(u64),
    rows: usize = 0,
    lo_mhz: f32 = 0,
    hi_mhz: f32 = 0,
    band: [columns]?f32 = @splat(null),
    rtt: [columns]?f32 = @splat(null),
    lost: [columns]u16 = @splat(0),
    signal: [columns]?f32 = @splat(null),
    /// The last 100 ms: total power per 0.5 ms slot.
    pulse: [200]?f32 = @splat(null),
    status: []const u8 = "",
    status_buf: [400]u8 = undefined,

    // The channel verdict and what each MHz is (from the last job).
    chan: ?radio.ChannelsOut = null,
    buckets: [100]channels_mod.Bucket = @splat(.{}),
    plan: ?radio.Monitor.PlanInfo = null,
    // The spectrum, per FFT-bin row from 2400 MHz: samples since the last
    // frame, the live value, its age, the peak hold, the decaying max ghost
    // and the displayed bar (springing toward the live value after a focus).
    acc_mw: [max_rows]f32 = @splat(0),
    acc_n: [max_rows]u16 = @splat(0),
    live: [max_rows]?f32 = @splat(null),
    last_ns: [max_rows]u64 = @splat(0),
    peak: [max_rows]?f32 = @splat(null),
    peak_ns: [max_rows]u64 = @splat(0),
    ghost: [max_rows]?f32 = @splat(null),
    disp: [max_rows]f32 = @splat(spec_floor_dbm),
    vel: [max_rows]f32 = @splat(0),
    strip: ?*Strip = null,
    dwell_seen_ns: u64 = 0,
    // The view: its frequency span (animated), the focus asked for, the drag.
    view: [2]f32 = .{ 2400, 2500 },
    zoom_from: [2]f32 = .{ 2400, 2500 },
    zoom_to: [2]f32 = .{ 2400, 2500 },
    zoom_t0: u64 = 0,
    pop_until: u64 = 0,
    focus: ?[2]f32 = null,
    fixed: bool = false,
    pending: ?sweep.Request = null,
    drag: ?Drag = null,
    last_click_ms: u32 = 0,
    last_click_x: f32 = -100,
    /// Plot areas from the last draw (x and width are shared): pointer hit tests.
    spec_plot: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    strip_plot: draw.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    metric: Metric = .power,
    mode: Mode = .channels,
    // The idle rule: what was drawn, and when.
    gen_seen: u64 = 0,
    prepared_ns: u64 = 0,
    live_ns: u64 = 0,
    frames: u32 = 0,
    frames_log_ns: u64 = 0,
    focus_log: [64]u8 = undefined,
    /// "no spectral samples for N s (...)" while the stream is stalled.
    stall: []const u8 = "",
    stall_buf: [240]u8 = undefined,
    focus_log_len: usize = 0,

    pub fn deinit(self: *State) void {
        if (self.job) |j| {
            if (j.thread) |th| th.join();
            j.arena.deinit();
            std.heap.c_allocator.destroy(j);
            self.job = null;
        }
        if (self.arena) |*a| a.deinit();
        if (self.cards_arena) |*a| a.deinit();
        self.arena = null;
        self.cards_arena = null;
        if (self.grid) |g| std.heap.c_allocator.destroy(g);
        self.grid = null;
        if (self.strip) |g| std.heap.c_allocator.destroy(g);
        self.strip = null;
    }

    // --- Interaction ------------------------------------------------------------------

    /// Frequency under x in the plots.
    pub fn freqAt(self: *const State, x: f32) f32 {
        const r = self.spec_plot;
        if (r.w <= 0) return 2450;
        return self.view[0] + std.math.clamp((x - r.x) / r.w, 0, 1) * (self.view[1] - self.view[0]);
    }
    pub fn xAt(self: *const State, r: draw.Rect, mhz: f32) f32 {
        return r.x + (mhz - self.view[0]) / (self.view[1] - self.view[0]) * r.w;
    }
    fn inPlots(self: *const State, x: f32, y: f32) bool {
        return draw.inside(self.spec_plot, x, y) or (self.mode == .channels and draw.inside(self.strip_plot, x, y));
    }
    /// A press in the spectrum or the strip starts a drag; a second press soon after is a double-click.
    pub fn press(self: *State, x: f32, y: f32, time_ms: u32, now: u64) bool {
        if (!self.inPlots(x, y)) return false;
        if (time_ms -% self.last_click_ms < 400 and @abs(x - self.last_click_x) < 8) {
            self.drag = null;
            self.last_click_ms = 0;
            self.toSweep(now);
            return true;
        }
        self.last_click_ms = time_ms;
        self.last_click_x = x;
        self.drag = .{ .x0 = x, .x1 = x };
        return true;
    }
    pub fn motion(self: *State, x: f32) void {
        if (self.drag) |*d| d.x1 = x;
    }
    /// Ends a drag: a span of 6 px or more focuses there. Returns whether anything changed.
    pub fn release(self: *State, x: f32, now: u64) bool {
        const d = self.drag orelse return false;
        self.drag = null;
        if (@abs(x - d.x0) < 6) return true;
        var lo = @min(self.freqAt(d.x0), self.freqAt(x));
        var hi = @max(self.freqAt(d.x0), self.freqAt(x));
        if (hi - lo < 5) {
            const mid = (lo + hi) / 2;
            lo = mid - 2.5;
            hi = mid + 2.5;
        }
        self.focusOn(@max(2400, lo), @min(2500, hi), now);
        return true;
    }
    pub fn focusOn(self: *State, lo: f32, hi: f32, now: u64) void {
        self.focus = .{ lo, hi };
        self.pending = .{ .mode = if (self.fixed) .fixed else .focus, .lo_mhz = @intFromFloat(@floor(lo)), .hi_mhz = @intFromFloat(@ceil(hi)) };
        const pad = @max(2, (hi - lo) * 0.08);
        // At most the whole band: a wider view inverts the clamps below (a ReleaseSafe panic on a drag of 87 MHz or more).
        const w = @min(100, @max(12, hi - lo + 2 * pad));
        const mid = (lo + hi) / 2;
        self.pop(.{ std.math.clamp(mid - w / 2, 2400, 2500 - w), std.math.clamp(mid + w / 2, 2400 + w, 2500) }, now);
        self.focus_log_len = if (std.fmt.bufPrint(&self.focus_log, "focus lo={d:.0} hi={d:.0} mode={s}", .{ lo, hi, if (self.fixed) "fixed" else "focus" })) |x| x.len else |_| 0;
    }
    pub fn toSweep(self: *State, now: u64) void {
        self.focus = null;
        self.pending = .{};
        self.pop(.{ 2400, 2500 }, now);
        self.focus_log_len = if (std.fmt.bufPrint(&self.focus_log, "focus sweep", .{})) |x| x.len else |_| 0;
    }
    /// The zoom pop: the span eases (with a little overshoot) to `to`, and the
    /// bars in view drop to the floor and spring back up as samples land.
    fn pop(self: *State, to: [2]f32, now: u64) void {
        self.zoom_from = self.view;
        self.zoom_to = to;
        self.zoom_t0 = now;
        self.pop_until = now + pop_ns;
        for (&self.disp, &self.vel, 0..) |*d, *v, row| {
            const f = grid_lo_mhz + (@as(f32, @floatFromInt(row)) + 0.5) * radio.ath9k.bin_mhz;
            if (f >= to[0] and f <= to[1]) {
                d.* = spec_floor_dbm;
                v.* = 0;
            }
        }
    }
    pub fn click(self: *State, c: Click, now: u64) void {
        switch (c) {
            .metric => |m| self.metric = m,
            .mode => |m| self.mode = m,
            .sweep => self.toSweep(now),
            .fixed => {
                self.fixed = !self.fixed;
                if (self.focus) |f| self.focusOn(f[0], f[1], now);
            },
        }
    }
    /// [ and ] cycle the strip's metric; Esc returns to the sweep; f toggles a fixed window.
    pub fn key(self: *State, sym: u32, shortcut: u32, now: u64) bool {
        const n = @typeInfo(Metric).@"enum".fields.len;
        if (shortcut == ']') {
            self.metric = @enumFromInt((@intFromEnum(self.metric) + 1) % n);
            return true;
        }
        if (shortcut == '[') {
            self.metric = @enumFromInt((@intFromEnum(self.metric) + n - 1) % n);
            return true;
        }
        if (shortcut == 'f') {
            self.click(.fixed, now);
            return true;
        }
        if (sym == 0xff1b and self.focus != null) {
            self.toSweep(now);
            return true;
        }
        return false;
    }
    /// The pop animates for 1.2 s after a focus change; otherwise frames follow the data.
    pub fn animating(self: *const State, now: u64) bool {
        return now < self.pop_until;
    }
    /// New samples or traffic since the last frame, and the data frame rate allows one.
    pub fn due(self: *const State, now: u64) bool {
        const m = radio.global orelse return false;
        if (now -| self.prepared_ns < data_frame_ns) return false;
        return m.generation() != self.gen_seen or (self.job != null and self.job.?.done.load(.acquire));
    }

    fn poll(self: *State) void {
        const j = self.job orelse return;
        if (!j.done.load(.acquire)) return;
        if (j.thread) |th| th.join();
        if (j.want_cards) {
            // Cards live in the job's arena too; keep that arena while they are shown.
            if (self.cards_arena) |*a| a.deinit();
            if (self.arena) |*a| a.deinit();
            self.arena = null;
            self.cards_arena = j.arena;
            self.cards = j.cards;
        } else {
            if (self.arena) |*a| a.deinit();
            self.arena = j.arena;
        }
        self.report = j.report;
        self.chan = j.chan;
        if (j.chan != null) self.buckets = j.buckets;
        std.heap.c_allocator.destroy(j);
        self.job = null;
    }

    /// Adds new samples to the waterfall and refreshes the lanes; starts a
    /// verdict job once a second. Returns whether anything visible changed.
    pub fn prepare(self: *State, gpa: std.mem.Allocator, redact: bool, now: u64) !bool {
        _ = gpa;
        _ = now;
        self.poll();
        // The passive collector starts with the panel; a card is taken only by --radio.
        const m = radio.ensure(std.heap.c_allocator) orelse {
            self.status = "radio collector did not start";
            return false;
        };
        self.status = m.statusText(&self.status_buf);
        const t = radio.fsx.monotonicNs();
        if (self.pending) |req| {
            m.focus(req);
            self.pending = null;
        }
        self.gen_seen = m.generation();
        self.stall = radio.stallWords(&self.stall_buf, m.health());
        const dt = @min(0.05, @as(f32, @floatFromInt(t -| self.prepared_ns)) / 1e9);
        self.prepared_ns = t;
        self.plan = m.planInfo();
        if (self.job == null and t -| self.built_ns >= refresh_ns) {
            self.built_ns = t;
            const want_cards = self.cards == null or t -| self.cards_built_ns >= cards_ns;
            if (want_cards) self.cards_built_ns = t;
            const j = try std.heap.c_allocator.create(Job);
            j.* = .{ .arena = .init(std.heap.c_allocator), .redact = redact, .m = m, .want_cards = want_cards };
            j.thread = std.Thread.spawn(.{}, Job.run, .{j}) catch null;
            if (j.thread == null) j.run();
            self.job = j;
        }
        if (self.grid == null) {
            const g = try std.heap.c_allocator.create(Grid);
            g.* = .{};
            self.grid = g;
            self.cells = &g.cells;
        }
        if (self.strip == null) {
            const g = try std.heap.c_allocator.create(Strip);
            g.* = .{};
            self.strip = g;
        }
        // New samples only.
        var scratch = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        // A cursor ahead of the clock (samples mapped forward, then re-anchored) must not stall the views.
        if (self.seen_ns > t + 1_000_000_000) self.seen_ns = 0;
        if (self.dwell_seen_ns > t + 1_000_000_000) self.dwell_seen_ns = 0;
        const from = @max(self.seen_ns, t -| span_ns);
        const w = try m.between(sa, from, t);
        const changed = w.samples.len > 0;
        for (w.samples) |x| {
            self.add(&x);
            self.addStrip(&x);
        }
        if (changed) self.live_ns = t;
        // Finished traffic dwells into the strip.
        for (try m.finishedDwells(sa, @max(self.dwell_seen_ns + 1, t -| span_ns), t)) |*d| {
            self.addDwell(d);
            self.dwell_seen_ns = d.to_ns;
        }
        self.spectrumFrame(t, dt);
        if (w.samples.len > 0) self.seen_ns = w.samples[w.samples.len - 1].mono_ns + 1;
        if (changed) {
            self.generation +%= 1;
            self.pulse = @splat(null);
            const newest = w.samples[w.samples.len - 1].s.tsf_us;
            var k = w.samples.len;
            while (k > 0) {
                k -= 1;
                const s = w.samples[k].s;
                if (newest -| s.tsf_us >= 100_000) break;
                const slot = 199 - @min(199, (newest -| s.tsf_us) / 500);
                const total = s.total();
                if (self.pulse[slot] == null or total > self.pulse[slot].?) self.pulse[slot] = total;
            }
        }
        self.layout(t);
        // Link and ping lanes are small: rebuilt from the window.
        const lanes = try m.lanes(sa, t -| span_ns, t);
        const first_col = t / col_ns -| (columns - 1);
        self.rtt = @splat(null);
        self.lost = @splat(0);
        self.signal = @splat(null);
        var rtt_n: [columns]u16 = @splat(0);
        for (lanes.pings) |p| {
            const c = @min(columns - 1, (p.mono_ns / col_ns) -| first_col);
            if (p.rtt_us) |r| {
                self.rtt[c] = (self.rtt[c] orelse 0) + @as(f32, @floatFromInt(r)) / 1000;
                rtt_n[c] += 1;
            } else self.lost[c] += 1;
        }
        for (&self.rtt, rtt_n) |*r, n| if (r.*) |x| {
            r.* = x / @as(f32, @floatFromInt(n));
        };
        for (lanes.links) |l| {
            const c = @min(columns - 1, (l.mono_ns / col_ns) -| first_col);
            if (l.signal_dbm) |sd| self.signal[c] = @floatFromInt(sd);
        }
        const audit = @import("../../c_ui.zig").api.getenv("XODB_OVERVIEW_AUDIT") != null;
        if (changed and audit) if (self.report) |r| {
            @import("../../log.zig").info(.overview, "xodb: radio kind={s} mains={d} samples={d} rows={d} cards={d} spectral={} demo={}\n", .{ r.kind, r.verdict.mains_hz orelse 0, r.spectral.window_samples, self.rows, if (self.cards) |c| c.cards.len else 0, r.spectral.on, std.mem.startsWith(u8, r.status, "SYNTHETIC") });
        };
        // Once a second: frames drawn, the plan, the channel verdict (tests read these).
        self.frames += 1;
        if (audit and t -| self.frames_log_ns >= 1_000_000_000) {
            const p = self.plan.?;
            var blasted: u16 = 0;
            var watched: u16 = 0;
            if (self.chan) |c| for (c.channels) |ch| {
                if (ch.impact == .blasted) blasted |= @as(u16, 1) << @intCast(ch.channel);
                if (ch.traffic != null) watched |= @as(u16, 1) << @intCast(ch.channel);
            };
            const hh = m.health();
            @import("../../log.zig").info(.overview, "xodb: radio-health silent_ms={d} retriggers={d} rearms={d} held_back={d} tsf_steps={d} malformed={d} busy_ms={d} busy=\"{s}\"\n", .{ if (hh) |x| x.silent_ms else 0, if (hh) |x| x.retriggers else 0, if (hh) |x| x.rearms else 0, if (hh) |x| x.rejected else 0, if (hh) |x| x.steps else 0, if (hh) |x| x.malformed else 0, if (hh) |x| x.busy_ms else 0, if (hh) |x| x.busy_op.get() else "" });
            @import("../../log.zig").info(.overview, "xodb: radio-frames n={d} animating={d} plan={s} windows={d} lo={d} hi={d} sensors={d} centre={d} view={d:.0}-{d:.0} blasted=0x{x} traffic=0x{x} spec={d:.0},{d:.0},{d:.0},{d:.0} strip={d:.0},{d:.0},{d:.0},{d:.0} mode={s} metric={s} {s}\n", .{ self.frames, @intFromBool(self.animating(t)), @tagName(p.plan.mode), p.plan.windows.n, p.plan.lo_mhz, p.plan.hi_mhz, p.sensors, p.centres[0], self.view[0], self.view[1], blasted, watched, self.spec_plot.x, self.spec_plot.y, self.spec_plot.w, self.spec_plot.h, self.strip_plot.x, self.strip_plot.y, self.strip_plot.w, self.strip_plot.h, @tagName(self.mode), @tagName(self.metric), self.focus_log[0..self.focus_log_len] });
            if (self.chan) |c| @import("../../log.zig").info(.overview, "xodb: radio-channels {s}\n", .{c.words});
            self.frames = 0;
            self.frames_log_ns = t;
            self.focus_log_len = 0;
        }
        return changed;
    }

    /// Strip cells: each channel whose mask the sample's window sees well.
    fn addStrip(self: *State, x: *const radio.monitor.Stamped) void {
        const g = self.strip.?;
        const id = x.mono_ns / strip_row_ns;
        const slot: usize = @intCast(id % strip_rows);
        if (g.row_id[slot] != id) {
            g.row_id[slot] = id;
            g.cells[slot] = @splat(.{});
        }
        const wf: f32 = @floatFromInt(x.s.freq_mhz);
        for (1..15) |c| {
            const fc: f32 = @floatFromInt(sweep.channelMhz(@intCast(c)));
            const seen = @min(wf + 10, fc + 11) - @max(wf - 10, fc - 11);
            if (seen < @as(f32, @floatFromInt(channels_mod.min_seen_mhz))) continue;
            var mw: f32 = 0;
            for (x.s.power, 0..) |p, b| {
                const f = x.s.binMhz(b);
                if (f >= fc - 11 and f < fc + 11) mw += linear[@as(u8, @bitCast(p))];
            }
            // The card's noise floor for the part of the mask it sees; busy at 8 dB over it (+3, as the detector).
            const noise = @as(f32, @floatFromInt(x.s.noise)) + 10 * std.math.log10(seen / 20);
            const cell = &g.cells[slot][c - 1];
            cell.mw += mw;
            cell.noise_mw += std.math.pow(f32, 10, noise / 10);
            cell.n +|= 1;
            cell.on +|= @intFromBool(10 * std.math.log10(@max(mw, 1e-15)) >= noise + 11);
        }
    }
    fn addDwell(self: *State, d: *const radio.radiotap.Dwell) void {
        if (d.channel < 1 or d.channel > 14) return;
        const g = self.strip.?;
        const id = d.to_ns / strip_row_ns;
        const slot: usize = @intCast(id % strip_rows);
        if (g.row_id[slot] != id) {
            g.row_id[slot] = id;
            g.cells[slot] = @splat(.{});
        }
        const cell = &g.cells[slot][d.channel - 1];
        cell.frames += d.frames;
        cell.retries += d.retries;
        cell.eligible += d.retry_eligible;
        cell.bad += d.bad_fcs;
        cell.watched_ms += @intCast(@min(std.math.maxInt(u32), (d.to_ns -| d.from_ns) / 1_000_000));
    }
    /// The value a strip cell shows for the metric, or null when that cell measured nothing.
    pub fn cellValue(self: *const State, c: *const Cell) ?f32 {
        return switch (self.metric) {
            .power => if (c.n > 0) 10 * std.math.log10(@max(c.mw / @as(f32, @floatFromInt(c.n)), 1e-15)) else null,
            .floor => if (c.n > 0) 10 * std.math.log10(@max(c.noise_mw / @as(f32, @floatFromInt(c.n)), 1e-15)) else null,
            .over_floor => if (c.n > 0) 10 * std.math.log10(@max(c.mw / @max(c.noise_mw, 1e-15), 1e-6)) else null,
            .busy => if (c.n > 0) @as(f32, @floatFromInt(c.on)) / @as(f32, @floatFromInt(c.n)) else null,
            .frames => if (c.watched_ms > 0) @as(f32, @floatFromInt(c.frames)) * 1000 / @as(f32, @floatFromInt(c.watched_ms)) else null,
            .retry => if (c.eligible > 0) @as(f32, @floatFromInt(c.retries)) / @as(f32, @floatFromInt(c.eligible)) else null,
        };
    }
    /// 0..1 for colouring a value of the current metric.
    pub fn metricT(self: *const State, v: f32) f32 {
        return std.math.clamp(switch (self.metric) {
            .power, .floor => (v + 105) / 65,
            .over_floor => v / 50,
            .busy, .retry => v,
            .frames => @log10(1 + v) / 3,
        }, 0, 1);
    }
    pub fn stripRow(self: *const State, id: u64) ?*const [14]Cell {
        const g = self.strip orelse return null;
        const slot: usize = @intCast(id % strip_rows);
        return if (g.row_id[slot] == id) &g.cells[slot] else null;
    }

    /// The spectrum's live values, peak hold, ghost, springs and zoom for this frame.
    fn spectrumFrame(self: *State, t: u64, dt: f32) void {
        for (0..max_rows) |row| {
            if (self.acc_n[row] > 0) {
                const v = 10 * std.math.log10(@max(self.acc_mw[row] / @as(f32, @floatFromInt(self.acc_n[row])), 1e-15));
                self.live[row] = v;
                self.last_ns[row] = t;
                if (self.peak[row] == null or v >= self.peak[row].?) {
                    self.peak[row] = v;
                    self.peak_ns[row] = t;
                }
                self.ghost[row] = if (self.ghost[row]) |g| @max(g, v) else v;
                self.acc_mw[row] = 0;
                self.acc_n[row] = 0;
            }
            // The peak holds, then falls 20 dB/s; the ghost falls 3 dB/s.
            if (self.peak[row]) |*p| if (t -| self.peak_ns[row] > peak_hold_ns) {
                p.* = @max(self.live[row] orelse spec_floor_dbm, p.* - 20 * dt);
            };
            if (self.ghost[row]) |*g| g.* = @max(self.live[row] orelse spec_floor_dbm, g.* - 3 * dt);
            const target = self.live[row] orelse spec_floor_dbm;
            if (t < self.pop_until) {
                // An underdamped spring: the bars overshoot a little and settle.
                const a = 260 * (target - self.disp[row]) - 18 * self.vel[row];
                self.vel[row] += a * dt;
                self.disp[row] += self.vel[row] * dt;
            } else {
                self.disp[row] = target;
                self.vel[row] = 0;
            }
        }
        const k = std.math.clamp(@as(f32, @floatFromInt(t -| self.zoom_t0)) / zoom_ns, 0, 1);
        // easeOutBack.
        const c1: f32 = 1.70158;
        const e = 1 + (c1 + 1) * std.math.pow(f32, k - 1, 3) + c1 * std.math.pow(f32, k - 1, 2);
        for (&self.view, self.zoom_from, self.zoom_to) |*v, f, to| v.* = f + (to - f) * e;
        if (self.view[1] - self.view[0] < 4) self.view[1] = self.view[0] + 4;
    }

    fn add(self: *State, x: *const radio.monitor.Stamped) void {
        const g = self.grid.?;
        const id = x.mono_ns / col_ns;
        const slot: usize = @intCast(id % columns);
        if (g.col_id[slot] != id) {
            g.col_id[slot] = id;
            @memset(&g.sum[slot], 0);
            @memset(&g.cnt[slot], 0);
            g.band_max[slot] = null;
        }
        const total = x.s.total();
        if (g.band_max[slot] == null or total > g.band_max[slot].?) g.band_max[slot] = total;
        for (x.s.power, 0..) |p, b| {
            const f = x.s.binMhz(b) - grid_lo_mhz;
            if (f < 0) continue;
            const row: usize = @intFromFloat(f / radio.ath9k.bin_mhz);
            if (row >= max_rows) continue;
            // Mean power per cell (linear), so a sweeping carrier keeps its shape.
            g.sum[slot][row] += linear[@as(u8, @bitCast(p))];
            g.cnt[slot][row] +|= 1;
            self.acc_mw[row] += linear[@as(u8, @bitCast(p))];
            self.acc_n[row] +|= 1;
            self.row_lo = @min(self.row_lo, row);
            self.row_hi = @max(self.row_hi, row + 1);
        }
    }

    /// Display cells for the window ending at `t`, oldest column first; only when samples changed them.
    fn layout(self: *State, t: u64) void {
        const g = self.grid.?;
        const first_col = t / col_ns -| (columns - 1);
        if (self.row_hi <= self.row_lo) {
            self.rows = 0;
            return;
        }
        self.rows = self.row_hi - self.row_lo;
        self.lo_mhz = grid_lo_mhz + @as(f32, @floatFromInt(self.row_lo)) * radio.ath9k.bin_mhz;
        self.hi_mhz = grid_lo_mhz + @as(f32, @floatFromInt(self.row_hi)) * radio.ath9k.bin_mhz;
        const stamp = self.generation *% 1_000_003 +% first_col;
        if (stamp == self.cells_generation) return;
        self.cells_generation = stamp;
        for (0..columns) |c| {
            const id = first_col + c;
            const slot: usize = @intCast(id % columns);
            const live = g.col_id[slot] == id;
            self.band[c] = if (live) g.band_max[slot] else null;
            for (0..self.rows) |r| {
                const row = self.row_lo + r;
                const n = if (live) g.cnt[slot][row] else 0;
                self.cells[c * self.rows + r] = if (n == 0) null else @intFromFloat(std.math.clamp(@round(10 * std.math.log10(g.sum[slot][row] / @as(f32, @floatFromInt(n)))), -128, 127));
            }
        }
    }
};
