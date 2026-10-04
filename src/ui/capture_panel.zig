//! Capture setup panel and outcome summary (T14 prototype; proposed home
//! `src/ui/capture_panel.zig`). Draws from an immutable `Snapshot`, the
//! session defaults, the selection and optional capture `Facts`; input returns
//! explicit `Action`s, which `apply` performs on the caller's state. Retained
//! state is scalars plus the refs of rows drawn last frame (for hit testing),
//! never pointers into target or capture storage.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
const profile = @import("../profile/capture.zig");
const setup = @import("capture_setup.zig");

pub const row_h: f32 = 22;
pub const max_rows = 64;
const max_hits = 32;

pub const Action = union(enum) {
    close,
    set_duration: u32,
    set_frequency: u32,
    toggle_scheduling,
    toggle_syscalls,
    set_stack_bytes: u32,
    set_stack_budget: u32,
    select_all,
    start_subset,
    toggle_thread: setup.ThreadRef,
    /// Inclusive range in list order, among rows matching the name filter.
    select_range: struct { from: setup.ThreadRef, to: setup.ThreadRef },
    /// Adds every live row matching the name filter.
    select_matching,
    drop_missing,
    start,
    edit: Field,
    page: Page,
};
/// In a small window the settings and the thread list are separate pages.
pub const Page = enum { settings, threads };
pub const Field = enum { none, duration, frequency, filter };
pub const Effect = enum { none, redraw, start_requested, closed };
const Hit = struct { rect: gpu.Rect, action: Action };
const RowHit = struct { y: f32, ref: setup.ThreadRef, state: setup.ThreadState };

pub const Panel = struct {
    open: bool = false,
    page: Page = .settings,
    first: usize = 0,
    cursor: usize = 0,
    anchor: ?setup.ThreadRef = null,
    editing: Field = .none,
    number: setup.NumberField = setup.NumberField.begin(.duration_s),
    filter: [32]u8 = undefined,
    filter_len: usize = 0,
    message: []const u8 = "",
    // Geometry and hits from the last draw.
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    list: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hits: [max_hits]Hit = undefined,
    hit_count: usize = 0,
    rows: [max_rows]RowHit = undefined,
    row_count: usize = 0,
    matching: usize = 0,
    visible_rows: usize = 0,

    pub fn containsPoint(self: *const Panel, x: f32, y: f32) bool {
        return self.open and inside(self.bounds, x, y);
    }
    pub fn filterText(self: *const Panel) []const u8 {
        return self.filter[0..self.filter_len];
    }
    fn matches(self: *const Panel, row: setup.ThreadRow) bool {
        const want = self.filterText();
        if (want.len == 0) return true;
        if (std.ascii.indexOfIgnoreCase(row.name, want) != null) return true;
        var buffer: [16]u8 = undefined;
        const tid = std.fmt.bufPrint(&buffer, "{d}", .{row.ref.tid}) catch return false;
        return std.mem.startsWith(u8, tid, want);
    }

    /// A button press. Shift extends a range from the last clicked row.
    pub fn press(self: *Panel, x: f32, y: f32, shift: bool) ?Action {
        if (!self.open or !inside(self.bounds, x, y)) return null;
        for (self.hits[0..self.hit_count]) |hit| if (inside(hit.rect, x, y)) return hit.action;
        if (inside(self.list, x, y)) for (self.rows[0..self.row_count], 0..) |row, i| {
            if (y < row.y or y >= row.y + row_h) continue;
            self.cursor = self.first + i;
            if (shift and self.anchor != null) return .{ .select_range = .{ .from = self.anchor.?, .to = row.ref } };
            self.anchor = row.ref;
            return .{ .toggle_thread = row.ref };
        };
        // A click elsewhere in the panel ends an edit without applying it.
        if (self.editing != .none) return .{ .edit = .none };
        return null;
    }
    pub fn wheel(self: *Panel, x: f32, y: f32, delta: i32) bool {
        if (!self.open or !inside(self.list, x, y)) return false;
        const last = self.matching -| self.visible_rows;
        self.first = @intCast(std.math.clamp(@as(i64, @intCast(self.first)) + delta, 0, @as(i64, @intCast(last))));
        return true;
    }
    /// Keys while the panel is open. Returns null when the key is not the
    /// panel's (the workspace then handles it, e.g. P and T). While a field is
    /// being edited, text, BackSpace, Return and Escape belong to the field.
    pub fn key(self: *Panel, event: keys.Event, snapshot: *const setup.Snapshot, limits: setup.Limits) ?Action {
        if (!self.open or event.kind == .release) return null;
        if (self.editing != .none) {
            switch (event.shortcut) {
                0xff1b => return .{ .edit = .none }, // Escape cancels the edit only
                0xff08 => {
                    if (self.editing == .filter) self.filter_len -|= 1 else self.number.backspace();
                    self.first = 0;
                    return .{ .edit = self.editing };
                },
                0xff0d => {
                    if (self.editing == .filter) return .{ .edit = .none };
                    const value = self.number.commit(limits) catch |err| {
                        self.message = switch (err) {
                            error.NumberOutOfRange => "Sample rate must be 1 to 1000 Hz",
                            error.NumberTooLarge => "That duration is too long",
                            else => "Type a number",
                        };
                        return .{ .edit = self.editing };
                    };
                    self.message = "";
                    return if (self.editing == .duration) .{ .set_duration = value } else .{ .set_frequency = value };
                },
                else => {},
            }
            if (!event.plain()) return .{ .edit = self.editing };
            const typed = event.text();
            if (self.editing == .filter) {
                for (typed) |ch| if (ch >= 0x20 and ch < 0x7f and self.filter_len < self.filter.len) {
                    self.filter[self.filter_len] = ch;
                    self.filter_len += 1;
                };
                self.first = 0;
                self.cursor = 0;
            } else self.number.type_(typed);
            return .{ .edit = self.editing };
        }
        if (!event.plain()) return null;
        const navigation = switch (event.shortcut) {
            keys.sym.up, 'k' => -1,
            keys.sym.down, 'j' => @as(i32, 1),
            else => 0,
        };
        if (navigation != 0) {
            self.moveCursor(navigation);
            return .{ .edit = .none };
        }
        if (event.kind == .repeat) return null;
        switch (event.shortcut) {
            0xff0d => return if (self.rowAt(snapshot, self.cursor)) |row| .{ .toggle_thread = row.ref } else null,
            0xff1b => return .close,
            's' => return .close,
            'y' => return .toggle_syscalls,
            else => return null,
        }
    }
    fn moveCursor(self: *Panel, delta: i32) void {
        if (self.matching == 0) return;
        self.cursor = @intCast(std.math.clamp(@as(i64, @intCast(self.cursor)) + delta, 0, @as(i64, @intCast(self.matching - 1))));
        if (self.cursor < self.first) self.first = self.cursor;
        if (self.visible_rows > 0 and self.cursor >= self.first + self.visible_rows) self.first = self.cursor + 1 - self.visible_rows;
    }
    /// The `n`th row matching the filter, by value.
    fn rowAt(self: *const Panel, snapshot: *const setup.Snapshot, n: usize) ?setup.ThreadRow {
        var seen: usize = 0;
        for (snapshot.threads) |row| if (self.matches(row)) {
            if (seen == n) return row;
            seen += 1;
        };
        return null;
    }

    /// Performs an action on the caller's state.
    pub fn apply(self: *Panel, action: Action, snapshot: *const setup.Snapshot, defaults: *profile.Config, selection: *setup.Selection) !Effect {
        switch (action) {
            .close => {
                self.open = false;
                self.editing = .none;
                return .closed;
            },
            .edit => |field| {
                if (field != self.editing) {
                    self.editing = field;
                    self.message = "";
                    if (field == .duration) {
                        self.number = setup.NumberField.begin(.duration_s);
                        var buffer: [12]u8 = undefined;
                        if (defaults.duration_ms % 1000 == 0) self.number.type_(std.fmt.bufPrint(&buffer, "{d}", .{defaults.duration_ms / 1000}) catch "");
                    } else if (field == .frequency) {
                        self.number = setup.NumberField.begin(.frequency_hz);
                        var buffer: [12]u8 = undefined;
                        self.number.type_(std.fmt.bufPrint(&buffer, "{d}", .{defaults.frequency_hz}) catch "");
                    }
                }
                return .redraw;
            },
            .set_duration => |ms| {
                defaults.duration_ms = ms;
                self.editing = .none;
            },
            .set_frequency => |hz| {
                defaults.frequency_hz = hz;
                self.editing = .none;
            },
            .toggle_scheduling => defaults.context_switch = !defaults.context_switch,
            .toggle_syscalls => {
                defaults.syscall_timing = !defaults.syscall_timing;
                self.message = if (defaults.syscall_timing) "Syscalls: choose 1..32 threads; X opens recorded detail" else "Syscall recording off for the next capture";
            },
            .set_stack_bytes => |bytes| {
                var next = defaults.*;
                next.user_stack_bytes = bytes;
                // The same validation as start; an invalid value is not applied.
                next.validate() catch return .redraw;
                defaults.* = next;
            },
            .set_stack_budget => |bytes| {
                var next = defaults.*;
                next.user_stack_budget_bytes = bytes;
                next.validate() catch return .redraw;
                defaults.* = next;
            },
            .select_all => selection.selectAll(),
            .start_subset => selection.startSubset(),
            .toggle_thread => |ref| for (snapshot.threads) |row| if (row.ref.id == ref.id and row.ref.tid == ref.tid) {
                try selection.toggle(snapshot, row);
                break;
            },
            .select_range => |range| {
                var inside_range = false;
                for (snapshot.threads) |row| {
                    if (!self.matches(row)) continue;
                    const edge = row.ref.id == range.from.id or row.ref.id == range.to.id;
                    if (edge or inside_range) if (row.state != .exited) try selection.add(row.ref);
                    if (edge) {
                        if (inside_range or range.from.id == range.to.id) break;
                        inside_range = true;
                    }
                }
                self.anchor = range.to;
            },
            .select_matching => for (snapshot.threads) |row| if (self.matches(row) and row.state != .exited) try selection.add(row.ref),
            .drop_missing => self.message = if (selection.dropMissing(snapshot) > 0) "Exited threads removed from the selection" else "",
            .start => return .start_requested,
            .page => |page| self.page = page,
        }
        return .redraw;
    }

    pub const Context = struct {
        snapshot: *const setup.Snapshot,
        defaults: profile.Config,
        selection: *const setup.Selection,
        limits: setup.Limits = .{},
        facts: ?setup.Facts = null,
        clock: setup.Clock,
        /// Last failed start, kept distinct from capture-stop reasons.
        start_error: ?[]const u8 = null,
        start_failure: ?@import("../profile/linux_perf.zig").Failure = null,
        requested_threads: usize = 0,
    };

    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, ctx: Context) !void {
        self.bounds = bounds;
        self.hit_count = 0;
        self.row_count = 0;
        self.list = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!self.open) return;
        const saved = r.clip;
        defer r.clip = saved;
        r.clip = bounds;
        try style.shadow(r, bounds, 8, 0.7);
        try style.box(r, bounds, theme.surface, theme.border, @splat(8));
        try r.textFit(font, bounds.x + 14, bounds.y + 9, 180, "NEXT CAPTURE", theme.text);
        try self.hitButton(r, font, .{ .x = bounds.x + bounds.w - 104, .y = bounds.y + 5, .w = 94, .h = 26 }, "Close", "S", theme.text, .close);
        var y = bounds.y + 38;
        // Side by side when there is room; otherwise one page at a time, and
        // the thread page keeps only the one-line summary.
        const wide = bounds.w >= 900 and bounds.h >= 420;
        y = try self.drawOutcome(r, font, bounds, y, ctx, !wide and (self.page == .threads or bounds.h < 450) and !ctx.snapshot.offline);
        if (wide) {
            const left = gpu.Rect{ .x = bounds.x + 14, .y = y, .w = std.math.clamp(bounds.w * 0.42, 420, 560), .h = 0 };
            _ = try self.drawSettings(r, font, left, ctx);
            // A recorded capture has no live threads to choose from.
            if (ctx.snapshot.offline) return;
            const list_x = left.x + left.w + 20;
            return self.drawThreads(r, font, .{ .x = list_x, .y = y, .w = bounds.x + bounds.w - 14 - list_x, .h = bounds.y + bounds.h - 10 - y }, ctx);
        }
        if (ctx.snapshot.offline) {
            _ = try self.drawSettings(r, font, .{ .x = bounds.x + 14, .y = y, .w = bounds.w - 28, .h = 0 }, ctx);
            return;
        }
        var count_buffer: [48]u8 = undefined;
        const chosen = if (ctx.selection.mode == .all) "all" else std.fmt.bufPrint(&count_buffer, "{d}", .{ctx.selection.liveCount(ctx.snapshot)}) catch "";
        var tab_buffer: [64]u8 = undefined;
        const tabs = [_]struct { page: Page, text: []const u8 }{ .{ .page = .settings, .text = "Settings" }, .{ .page = .threads, .text = std.fmt.bufPrint(&tab_buffer, "Threads ({s})", .{chosen}) catch "Threads" } };
        var x = bounds.x + 14;
        for (tabs) |tab| {
            const w = r.measure(font, tab.text) + 24;
            try chip(r, font, .{ .x = x, .y = y, .w = w, .h = 24 }, tab.text, self.page == tab.page, theme.text);
            self.addHit(.{ .x = x, .y = y, .w = w, .h = 24 }, .{ .page = tab.page });
            x += w + 6;
        }
        y += 32;
        const area = gpu.Rect{ .x = bounds.x + 14, .y = y, .w = bounds.w - 28, .h = bounds.y + bounds.h - 10 - y };
        if (self.page == .settings) _ = try self.drawSettings(r, font, area, ctx) else try self.drawThreads(r, font, area, ctx);
    }
    fn addHit(self: *Panel, rect: gpu.Rect, action: Action) void {
        if (self.hit_count == self.hits.len) return;
        self.hits[self.hit_count] = .{ .rect = rect, .action = action };
        self.hit_count += 1;
    }
    fn hitButton(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, text: []const u8, key_text: []const u8, color: gpu.Color, action: Action) !void {
        if (rect.w < 30) return;
        if (key_text.len > 0) try style.button(r, font, rect, text, key_text, color, 0, 0) else try chip(r, font, rect, text, false, color);
        self.addHit(rect, action);
    }
    /// Recorded outcome of the current capture, or the last failed start.
    fn drawOutcome(self: *Panel, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect, top: f32, ctx: Context, compact: bool) !f32 {
        _ = self;
        var y = top;
        const w = bounds.w - 28;
        var buffer: [512]u8 = undefined;
        if (ctx.start_error) |message| {
            const failed = setup.startFailure(&buffer, message, ctx.start_failure, ctx.requested_threads, ctx.limits);
            try label(r, font, bounds.x + 14, y, w, theme.warm, "Did not start: {s}", .{failed.title});
            try r.textFit(font, bounds.x + 14, y + 20, w, failed.next, theme.text);
            return y + 46;
        }
        const facts = ctx.facts orelse {
            try r.textFit(font, bounds.x + 14, y, w, "No capture yet. Settings below apply to the next one.", theme.weak);
            return y + 26;
        };
        if (compact) {
            var line: [512]u8 = undefined;
            try r.textFit(font, bounds.x + 14, y, w, headerLine(&line, facts, ctx.limits, ctx.clock), theme.text);
            return y + 24;
        }
        try r.textFit(font, bounds.x + 14, y, w, setup.summaryLine(&buffer, facts, ctx.limits, ctx.clock), theme.text);
        y += 20;
        const why = setup.reason(facts.status);
        const color = switch (why.severity) {
            .normal => theme.good,
            .warning => theme.warm,
            .failure => theme.breakpoint,
        };
        var remaining: [32]u8 = undefined;
        if (setup.remainingNs(facts, ctx.clock)) |left| {
            try label(r, font, bounds.x + 14, y, w, theme.good, "Capturing  /  {s} left before the time limit", .{setup.elapsedText(&remaining, left)});
        } else if (facts.collecting) {
            try r.textFit(font, bounds.x + 14, y, w, "Capturing until you stop it (P); storage and scope limits can still end it", theme.good);
        } else try label(r, font, bounds.x + 14, y, w, color, "{s}{s}{s}", .{ why.title, if (why.next.len > 0) "  /  " else "", why.next });
        y += 20;
        var detail_buffer: [256]u8 = undefined;
        const detail = setup.detailLine(&detail_buffer, facts, ctx.limits);
        if (detail.len > 0) {
            try r.textFit(font, bounds.x + 14, y, w, detail, theme.text);
            y += 20;
        }
        // Further conditions observed after the first, in observation order.
        if (facts.stop_reasons.len > 1) {
            var also: [384]u8 = undefined;
            var n: usize = 0;
            for (facts.stop_reasons, 0..) |stop, i| {
                if (i == 0 and stop == facts.status) continue;
                const piece = std.fmt.bufPrint(also[n..], "{s}{s}", .{ if (n == 0) "Also: " else "; ", setup.reason(stop).title }) catch break;
                n += piece.len;
            }
            if (n > 0) {
                try r.textFit(font, bounds.x + 14, y, w, also[0..n], theme.warm);
                y += 20;
            }
        }
        var loss: [256]u8 = undefined;
        const lost = setup.lossLine(&loss, facts);
        if (lost.len > 0) {
            try r.textFit(font, bounds.x + 14, y, w, lost, theme.warm);
            y += 20;
        }
        var stack_buffer: [256]u8 = undefined;
        const stack_line = setup.stackLine(&stack_buffer, facts);
        if (stack_line.len > 0) {
            try r.textFit(font, bounds.x + 14, y, w, stack_line, if (facts.stacks.budget_gaps > 0) theme.warm else theme.text);
            y += 20;
        }
        if (facts.offline) {
            try r.textFit(font, bounds.x + 14, y, w, "Recorded capture: settings shown are what it used. Live capture controls are unavailable.", theme.weak);
            y += 20;
        }
        try r.rect(.{ .x = bounds.x + 10, .y = y + 3, .w = bounds.w - 20, .h = 1 }, theme.border);
        return y + 10;
    }
    fn drawSettings(self: *Panel, r: *gpu.Renderer, font: *Font, area: gpu.Rect, ctx: Context) !f32 {
        var y = area.y;
        const compact = area.h > 0 and area.h < 280;
        const offline = ctx.snapshot.offline;
        if (offline) {
            try r.textFit(font, area.x, y, area.w, "Offline: nothing here can start a capture.", theme.weak);
            return y + 24;
        }
        const d = ctx.defaults;
        try r.textFit(font, area.x, y + 4, 90, "Duration", theme.weak);
        var x = area.x + 90;
        var buffer: [32]u8 = undefined;
        for (setup.duration_presets) |ms| {
            const text = setup.durationText(&buffer, ms);
            const w = r.measure(font, text) + 20;
            if (x + w > area.x + area.w) {
                x = area.x + 90;
                y += 28;
            }
            try chip(r, font, .{ .x = x, .y = y, .w = w, .h = 24 }, text, d.duration_ms == ms, theme.text);
            self.addHit(.{ .x = x, .y = y, .w = w, .h = 24 }, .{ .set_duration = ms });
            x += w + 6;
        }
        y += if (compact) 28 else 30;
        try self.numberRow(r, font, area.x + 90, y, area.w - 90, .duration, if (setup.isPresetDuration(d.duration_ms)) "custom" else setup.durationText(&buffer, d.duration_ms), "s", !setup.isPresetDuration(d.duration_ms));
        y += if (compact) 28 else 32;
        try r.textFit(font, area.x, y + 4, 90, "Rate", theme.weak);
        x = area.x + 90;
        for (setup.frequency_presets) |hz| {
            const text = std.fmt.bufPrint(&buffer, "{d} Hz", .{hz}) catch "";
            const w = r.measure(font, text) + 20;
            if (x + w > area.x + area.w) {
                x = area.x + 90;
                y += 28;
            }
            try chip(r, font, .{ .x = x, .y = y, .w = w, .h = 24 }, text, d.frequency_hz == hz, theme.text);
            self.addHit(.{ .x = x, .y = y, .w = w, .h = 24 }, .{ .set_frequency = hz });
            x += w + 6;
        }
        y += if (compact) 28 else 30;
        const preset_rate = std.mem.indexOfScalar(u32, &setup.frequency_presets, d.frequency_hz) != null;
        try self.numberRow(r, font, area.x + 90, y, area.w - 90, .frequency, if (preset_rate) "custom" else std.fmt.bufPrint(&buffer, "{d}", .{d.frequency_hz}) catch "", "Hz", !preset_rate);
        y += if (compact) 28 else 32;
        try r.textFit(font, area.x, y + 4, 90, "Schedule", theme.weak);
        const half = @max(0, (area.w - 96) / 2);
        const sched = gpu.Rect{ .x = area.x + 90, .y = y, .w = half, .h = 24 };
        try chip(r, font, sched, if (d.context_switch) "Scheduling on" else "Scheduling off", d.context_switch, theme.text);
        self.addHit(sched, .toggle_scheduling);
        const calls = gpu.Rect{ .x = sched.x + half + 6, .y = y, .w = half, .h = 24 };
        try chip(r, font, calls, if (d.syscall_timing) "Syscalls on (Y)" else "Syscalls off (Y)", d.syscall_timing, theme.text);
        self.addHit(calls, .toggle_syscalls);
        y += if (compact) 28 else 32;
        // Sampled user stacks (T10): size per sample, then the total budget.
        try r.textFit(font, area.x, y + 4, 90, "Stacks", theme.weak);
        var sx = area.x + 90;
        var size_buffer: [24]u8 = undefined;
        for (setup.stack_presets) |bytes| {
            const text = setup.sizeText(&size_buffer, bytes);
            const w = r.measure(font, text) + 20;
            if (sx + w > area.x + area.w) break;
            try chip(r, font, .{ .x = sx, .y = y, .w = w, .h = 24 }, text, d.user_stack_bytes == bytes, theme.text);
            self.addHit(.{ .x = sx, .y = y, .w = w, .h = 24 }, .{ .set_stack_bytes = bytes });
            sx += w + 6;
        }
        if (std.mem.indexOfScalar(u32, &setup.stack_presets, d.user_stack_bytes) == null and sx < area.x + area.w - 60) try r.textFit(font, sx, y + 4, area.x + area.w - sx, setup.sizeText(&size_buffer, d.user_stack_bytes), theme.text);
        if (d.user_stack_bytes != 0) {
            // Short panels keep the budget on the Stacks row, as every preset
            // when it fits or else one chip that cycles, so Threads and Start
            // stay visible at 640x480. Tall panels give it a row of its own.
            var need: f32 = 14;
            for (setup.stack_budget_presets) |bytes| need += r.measure(font, setup.sizeText(&size_buffer, bytes)) + 26;
            var cycle_buffer: [40]u8 = undefined;
            const cycle_text = std.fmt.bufPrint(&cycle_buffer, "budget {s}", .{setup.sizeText(&size_buffer, d.user_stack_budget_bytes)}) catch "";
            const cycle_w = r.measure(font, cycle_text) + 20;
            const room = area.x + area.w - sx;
            const layout: enum { inline_presets, cycle, own_row } = if (area.h >= 400) .own_row else if (need <= room) .inline_presets else if (14 + cycle_w <= room) .cycle else .own_row;
            switch (layout) {
                .cycle => {
                    const at = std.mem.indexOfScalar(u32, &setup.stack_budget_presets, d.user_stack_budget_bytes);
                    const next = setup.stack_budget_presets[if (at) |i| (i + 1) % setup.stack_budget_presets.len else 0];
                    try r.textFit(font, sx, y + 4, 14, "/", theme.weak);
                    try chip(r, font, .{ .x = sx + 14, .y = y, .w = cycle_w, .h = 24 }, cycle_text, true, theme.text);
                    self.addHit(.{ .x = sx + 14, .y = y, .w = cycle_w, .h = 24 }, .{ .set_stack_budget = next });
                },
                .inline_presets, .own_row => {
                    if (layout == .inline_presets) {
                        try r.textFit(font, sx, y + 4, 14, "/", theme.weak);
                        sx += 14;
                    } else {
                        y += if (compact) 28 else 32;
                        try r.textFit(font, area.x, y + 4, 90, "Budget", theme.weak);
                        sx = area.x + 90;
                    }
                    for (setup.stack_budget_presets) |bytes| {
                        const text = setup.sizeText(&size_buffer, bytes);
                        const w = r.measure(font, text) + 20;
                        if (sx + w > area.x + area.w) break;
                        try chip(r, font, .{ .x = sx, .y = y, .w = w, .h = 24 }, text, d.user_stack_budget_bytes == bytes, theme.text);
                        self.addHit(.{ .x = sx, .y = y, .w = w, .h = 24 }, .{ .set_stack_budget = bytes });
                        sx += w + 6;
                    }
                    // Roughly how many full-size stacks fit; registers continue after.
                    var fit_buffer: [48]u8 = undefined;
                    if (layout == .own_row and sx < area.x + area.w - 80) try r.textFit(font, sx + 4, y + 4, area.x + area.w - sx - 4, std.fmt.bufPrint(&fit_buffer, "~{d} full stacks", .{d.user_stack_budget_bytes / d.user_stack_bytes}) catch "", theme.weak);
                },
            }
        }
        y += if (compact) 28 else 32;
        try r.textFit(font, area.x, y + 4, 90, "Threads", theme.weak);
        const live = ctx.selection.liveCount(ctx.snapshot);
        var all_buffer: [48]u8 = undefined;
        var total: usize = 0;
        for (ctx.snapshot.threads) |row| total += @intFromBool(row.state != .exited);
        const all_text = std.fmt.bufPrint(&all_buffer, "All ({d}){s}", .{ total, if (d.follow_threads) " + new" else "" }) catch "";
        const all_w = r.measure(font, all_text) + 20;
        try chip(r, font, .{ .x = area.x + 90, .y = y, .w = all_w, .h = 24 }, all_text, ctx.selection.mode == .all, theme.text);
        self.addHit(.{ .x = area.x + 90, .y = y, .w = all_w, .h = 24 }, .select_all);
        var sub_buffer: [48]u8 = undefined;
        const sub_text = std.fmt.bufPrint(&sub_buffer, "Chosen ({d})", .{if (ctx.selection.mode == .subset) live else 0}) catch "";
        const sub_w = r.measure(font, sub_text) + 20;
        const sub_x = area.x + 96 + all_w;
        if (sub_x + sub_w <= area.x + area.w) {
            try chip(r, font, .{ .x = sub_x, .y = y, .w = sub_w, .h = 24 }, sub_text, ctx.selection.mode == .subset, theme.text);
            self.addHit(.{ .x = sub_x, .y = y, .w = sub_w, .h = 24 }, .start_subset);
        }
        y += if (compact) 30 else 34;
        // What the next start would do, using the same checks as the start.
        var tids: [1]i32 = undefined;
        _ = &tids;
        const outcome = previewStart(ctx);
        const start = gpu.Rect{ .x = area.x, .y = y, .w = @min(area.w, 220), .h = 28 };
        try self.hitButton(r, font, start, if (ctx.snapshot.collecting) "Stop capture" else "Start capture", "P", if (outcome == null or ctx.snapshot.collecting) theme.good else theme.weak, .start);
        // What the start would do, or why it cannot, on its own line.
        y += if (compact) 30 else 34;
        if (outcome) |problem| {
            try r.textFit(font, area.x, y, area.w, setup.problemText(problem), if (ctx.snapshot.collecting) theme.weak else theme.warm);
            if (problem == .missing_threads) {
                y += 26;
                try self.hitButton(r, font, .{ .x = area.x, .y = y, .w = @min(area.w, 220), .h = 26 }, "Drop exited threads", "", theme.text, .drop_missing);
                y += 6;
            }
        } else {
            var next: [96]u8 = undefined;
            const scope = if (ctx.selection.mode == .all) (if (d.follow_threads) "all threads + new" else "current threads only") else std.fmt.bufPrint(&next, "{d} chosen thread{s}", .{ live, if (live == 1) "" else "s" }) catch "";
            try label(r, font, area.x, y, area.w, theme.weak, "Next: {d} Hz / {s} / {s}", .{ d.frequency_hz, setup.durationText(&buffer, d.duration_ms), scope });
        }
        y += 26;
        if (self.message.len > 0) {
            try r.textFit(font, area.x, y, area.w, self.message, theme.warm);
            y += 22;
        }
        return y;
    }
    fn numberRow(self: *Panel, r: *gpu.Renderer, font: *Font, x: f32, y: f32, w: f32, field: Field, shown: []const u8, unit: []const u8, active: bool) !void {
        const rect = gpu.Rect{ .x = x, .y = y, .w = @min(w, 200), .h = 26 };
        const editing = self.editing == field;
        try style.box(r, rect, if (editing) theme.header else theme.background, if (editing) theme.focus else theme.border, @splat(4));
        var buffer: [48]u8 = undefined;
        const text = if (editing) std.fmt.bufPrint(&buffer, "{s}_ {s}", .{ self.number.text(), unit }) catch "" else shown;
        try r.textFit(font, rect.x + 8, rect.y + 4, rect.w - 16, text, if (editing or active) theme.text else theme.weak);
        self.addHit(rect, .{ .edit = field });
        if (editing) try r.textFit(font, rect.x + rect.w + 10, y + 4, w - rect.w - 10, if (field == .duration) "Return applies; 0 = until stopped" else "Return applies; 1 to 1000", theme.weak);
    }
    fn drawThreads(self: *Panel, r: *gpu.Renderer, font: *Font, area: gpu.Rect, ctx: Context) !void {
        if (area.h < 70 or area.w < 160) return;
        const filter_rect = gpu.Rect{ .x = area.x, .y = area.y, .w = @min(area.w * 0.45, 260), .h = 26 };
        const editing = self.editing == .filter;
        try style.box(r, filter_rect, if (editing) theme.header else theme.background, if (editing) theme.focus else theme.border, @splat(4));
        var buffer: [64]u8 = undefined;
        const shown = if (self.filter_len == 0 and !editing) "Filter by name or TID" else std.fmt.bufPrint(&buffer, "{s}{s}", .{ self.filterText(), if (editing) "_" else "" }) catch "";
        try r.textFit(font, filter_rect.x + 8, filter_rect.y + 4, filter_rect.w - 16, shown, if (self.filter_len == 0 and !editing) theme.weak else theme.text);
        self.addHit(filter_rect, .{ .edit = .filter });
        const add_rect = gpu.Rect{ .x = filter_rect.x + filter_rect.w + 8, .y = area.y, .w = 128, .h = 26 };
        if (add_rect.x + add_rect.w <= area.x + area.w) try self.hitButton(r, font, add_rect, "Add shown", "", theme.text, .select_matching);
        // Whole-list choices stay reachable when settings are on another page.
        const all_rect = gpu.Rect{ .x = add_rect.x + add_rect.w + 8, .y = area.y, .w = 56, .h = 26 };
        if (all_rect.x + all_rect.w <= area.x + area.w) {
            try chip(r, font, all_rect, "All", ctx.selection.mode == .all, theme.text);
            self.addHit(all_rect, .select_all);
        }
        const none_rect = gpu.Rect{ .x = all_rect.x + all_rect.w + 6, .y = area.y, .w = 66, .h = 26 };
        if (none_rect.x + none_rect.w <= area.x + area.w) try self.hitButton(r, font, none_rect, "None", "", theme.text, .start_subset);
        // Count rows that match, and clamp scrolling, before drawing.
        var matching: usize = 0;
        for (ctx.snapshot.threads) |row| matching += @intFromBool(self.matches(row));
        self.matching = matching;
        const top = area.y + 34;
        try r.textFit(font, area.x, top, area.w, "      TID  name", theme.weak);
        self.list = .{ .x = area.x, .y = top + 22, .w = area.w, .h = @max(0, area.y + area.h - top - 22) };
        self.visible_rows = @min(max_rows, @as(usize, @intFromFloat(self.list.h / row_h)));
        self.first = @min(self.first, matching -| self.visible_rows);
        self.cursor = @min(self.cursor, matching -| 1);
        if (matching == 0) {
            try r.textFit(font, area.x, self.list.y + 4, area.w, if (ctx.snapshot.threads.len == 0) "No threads: launch or attach a target" else "No thread matches the filter", theme.weak);
            return;
        }
        r.clip = self.list;
        var index: usize = 0;
        for (ctx.snapshot.threads) |row| {
            if (!self.matches(row)) continue;
            defer index += 1;
            if (index < self.first) continue;
            if (self.row_count == self.visible_rows) break;
            const y = self.list.y + @as(f32, @floatFromInt(self.row_count)) * row_h;
            self.rows[self.row_count] = .{ .y = y, .ref = row.ref, .state = row.state };
            self.row_count += 1;
            const included = ctx.selection.included(row);
            if (index % 2 == 1) try r.rect(.{ .x = area.x, .y = y, .w = area.w, .h = row_h }, theme.stripe);
            if (index == self.cursor) try style.focus(r, .{ .x = area.x, .y = y, .w = area.w - 8, .h = row_h }, 3, 1);
            const box = gpu.Rect{ .x = area.x + 6, .y = y + 5, .w = 12, .h = 12 };
            try r.shape(box, if (included) theme.good else theme.background, .{ .radii = @splat(3) });
            try r.shape(box, if (row.state == .exited) theme.weak else theme.border, .{ .radii = @splat(3), .border = 1 });
            var line: [96]u8 = undefined;
            const text = std.fmt.bufPrint(&line, "{d: >7}  {s}{s}", .{ @as(u32, @bitCast(row.ref.tid)), if (row.name.len > 0) row.name else "(no name)", if (row.state == .exited) "  exited" else if (row.state == .running) "  running" else "" }) catch "";
            try r.textFit(font, area.x + 24, y + 2, area.w - 36, text, if (row.state == .exited) theme.weak else if (included) theme.text else theme.weak);
        }
        r.clip = self.bounds;
        if (matching > self.visible_rows) {
            const track = gpu.Rect{ .x = area.x + area.w - 5, .y = self.list.y, .w = 3, .h = @as(f32, @floatFromInt(self.visible_rows)) * row_h };
            const total: f32 = @floatFromInt(matching);
            try r.rect(track, style.fade(theme.border, 0.6));
            try r.rect(.{ .x = track.x, .y = track.y + @as(f32, @floatFromInt(self.first)) / total * track.h, .w = 3, .h = @max(8, @as(f32, @floatFromInt(self.visible_rows)) / total * track.h) }, theme.weak);
        }
    }
};
/// The check `prepareStart` would make, without building a request.
pub fn previewStart(ctx: Panel.Context) ?setup.StartProblem {
    var tids: [@import("../profile/linux_perf.zig").max_threads]i32 = undefined;
    return switch (setup.prepareStart(ctx.snapshot, ctx.defaults, ctx.selection, ctx.limits, &tids)) {
        .ready => null,
        .rejected => |rejected| rejected.problem,
    };
}
/// One-line outcome for the flame header: summary plus readable reason.
pub fn headerLine(buffer: []u8, facts: setup.Facts, limits: setup.Limits, clock: setup.Clock) []const u8 {
    var line: [256]u8 = undefined;
    const summary = setup.summaryLine(&line, facts, limits, clock);
    if (facts.collecting) return std.fmt.bufPrint(buffer, "{s}", .{summary}) catch "";
    const why = setup.reason(facts.status);
    const extra = facts.stop_reasons.len -| @intFromBool(facts.stop_reasons.len > 0 and facts.stop_reasons[0] == facts.status);
    var more: [32]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}  /  {s}{s}", .{ summary, why.title, if (extra > 0) std.fmt.bufPrint(&more, " (+{d} more, S)", .{extra}) catch "" else "" }) catch "";
}
fn chip(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, text: []const u8, selected: bool, color: gpu.Color) !void {
    try style.box(r, rect, if (selected) style.fade(theme.focus, 0.28) else theme.header, if (selected) theme.focus else theme.border, @splat(rect.h / 2));
    try r.textFit(font, rect.x + 10, rect.y + (rect.h - 18) / 2, rect.w - 16, text, if (selected) theme.text else color);
}
fn inside(rect: gpu.Rect, x: f32, y: f32) bool {
    return x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h;
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    if (width <= 0) return;
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}

// ------------------------------------------------------------ tests

const testing = std.testing;
fn testFont(a: std.mem.Allocator) !*Font {
    const font = try a.create(Font);
    font.* = .{};
    try font.init("/usr/share/fonts/TTF/DejaVuSansMono.ttf");
    return font;
}
pub fn manyRows(a: std.mem.Allocator, n: usize) ![]setup.ThreadRow {
    const out = try a.alloc(setup.ThreadRow, n);
    const names = [_][]const u8{ "main", "RenderThread", "AudioMixer", "TaskGraphThreadNP 12", "a-very-long-thread-name-that-truncates", "worker" };
    for (out, 0..) |*row, i| row.* = .{ .ref = .{ .id = i + 1, .tid = @intCast(40000 + i) }, .state = if (i % 97 == 5) .exited else .stopped, .name = names[i % names.len] };
    return out;
}
const Fixture = struct {
    font: *Font,
    buffer: []align(16) u8,
    r: gpu.Renderer,
    fn init(a: std.mem.Allocator) !Fixture {
        var f = Fixture{ .font = try testFont(a), .buffer = try a.alignedAlloc(u8, .@"16", 8 * 1024 * 1024), .r = .{} };
        f.r.mapped = f.buffer.ptr;
        return f;
    }
    fn deinit(self: *Fixture, a: std.mem.Allocator) void {
        self.font.deinit();
        a.destroy(self.font);
        a.free(self.buffer);
    }
};

test "panel actions select ranges and matches, edit numbers and keep Escape local" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit(a);
    const list = try manyRows(a, 1024);
    defer a.free(list);
    const snapshot = setup.Snapshot{ .target = .{ .pid = 40000, .image_epoch = 1 }, .stopped = true, .offline = false, .collecting = false, .threads = list };
    var selection = setup.Selection{};
    _ = selection.sync(&snapshot);
    var defaults = profile.Config{ .duration_ms = 60000, .frequency_hz = 99 };
    var panel = Panel{ .open = true };
    const bounds = gpu.Rect{ .x = 0, .y = 0, .w = 1200, .h = 700 };
    fx.r.clip = bounds;
    try panel.draw(&fx.r, fx.font, bounds, .{ .snapshot = &snapshot, .defaults = defaults, .selection = &selection, .clock = .{ .now_ns = 0 } });
    try testing.expect(panel.row_count > 10 and panel.row_count <= max_rows);
    // Filter by name, then add every match: a deliberate subset of a large process.
    _ = try panel.apply(.{ .edit = .filter }, &snapshot, &defaults, &selection);
    try testing.expect(panel.key(.{ .kind = .press, .shortcut = 'a', .text_len = 5, .text_bytes = "audio".* ++ @as([11]u8, @splat(0)) }, &snapshot, .{}) != null);
    try testing.expectEqualStrings("audio", panel.filterText());
    // Escape while editing ends the edit; it is not passed on (it would quit).
    const escape = panel.key(.{ .kind = .press, .shortcut = 0xff1b }, &snapshot, .{}).?;
    try testing.expectEqual(Field.none, escape.edit);
    _ = try panel.apply(escape, &snapshot, &defaults, &selection);
    _ = try panel.apply(.select_matching, &snapshot, &defaults, &selection);
    try testing.expectEqual(setup.Mode.subset, selection.mode);
    var expected: usize = 0;
    for (list) |row| expected += @intFromBool(row.state != .exited and std.mem.eql(u8, row.name, "AudioMixer"));
    try testing.expectEqual(expected, selection.count);
    // A shift range among filtered rows.
    panel.filter_len = 0;
    _ = try panel.apply(.{ .select_range = .{ .from = list[10].ref, .to = list[19].ref } }, &snapshot, &defaults, &selection);
    for (list[10..20]) |row| try testing.expect(selection.included(row) or row.state == .exited);
    // Numeric rate: type, commit; out-of-range keeps the field open.
    _ = try panel.apply(.{ .edit = .frequency }, &snapshot, &defaults, &selection);
    try testing.expectEqualStrings("99", panel.number.text());
    _ = panel.key(.{ .kind = .press, .shortcut = 0xff08 }, &snapshot, .{});
    _ = panel.key(.{ .kind = .press, .shortcut = 0xff08 }, &snapshot, .{});
    _ = panel.key(.{ .kind = .press, .shortcut = '2', .text_len = 4, .text_bytes = "2500".* ++ @as([12]u8, @splat(0)) }, &snapshot, .{});
    const too_fast = panel.key(.{ .kind = .press, .shortcut = 0xff0d }, &snapshot, .{}).?;
    try testing.expectEqual(Field.frequency, too_fast.edit);
    _ = panel.key(.{ .kind = .press, .shortcut = 0xff08 }, &snapshot, .{});
    const commit = panel.key(.{ .kind = .press, .shortcut = 0xff0d }, &snapshot, .{}).?;
    try testing.expectEqual(@as(u32, 250), commit.set_frequency);
    _ = try panel.apply(commit, &snapshot, &defaults, &selection);
    try testing.expectEqual(@as(u32, 250), defaults.frequency_hz);
    // P and T are left to the workspace.
    try testing.expect(panel.key(.{ .kind = .press, .shortcut = 'p' }, &snapshot, .{}) == null);
    try testing.expect(panel.key(.{ .kind = .press, .shortcut = 't' }, &snapshot, .{}) == null);
}

test "keyboard and wheel stay within the virtualized list" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit(a);
    const list = try manyRows(a, 1024);
    defer a.free(list);
    const snapshot = setup.Snapshot{ .target = .{ .pid = 1, .image_epoch = 1 }, .stopped = true, .offline = false, .collecting = false, .threads = list };
    var selection = setup.Selection{};
    var defaults_for_test = profile.Config{};
    var panel = Panel{ .open = true };
    const bounds = gpu.Rect{ .x = 0, .y = 0, .w = 624, .h = 352 };
    fx.r.clip = bounds;
    try panel.draw(&fx.r, fx.font, bounds, .{ .snapshot = &snapshot, .defaults = .{}, .selection = &selection, .clock = .{ .now_ns = 0 } });
    // A small window shows one page; the thread page holds the list.
    try testing.expectEqual(@as(usize, 0), panel.row_count);
    _ = try panel.apply(.{ .page = .threads }, &snapshot, &defaults_for_test, &selection);
    try panel.draw(&fx.r, fx.font, bounds, .{ .snapshot = &snapshot, .defaults = .{}, .selection = &selection, .clock = .{ .now_ns = 0 } });
    try testing.expect(panel.visible_rows >= 8);
    for (0..2000) |_| _ = panel.key(.{ .kind = .repeat, .shortcut = keys.sym.down }, &snapshot, .{});
    try testing.expectEqual(@as(usize, 1023), panel.cursor);
    try testing.expectEqual(1024 - panel.visible_rows, panel.first);
    try testing.expect(panel.wheel(panel.list.x + 5, panel.list.y + 5, -10000));
    try testing.expectEqual(@as(usize, 0), panel.first);
    const enter = panel.key(.{ .kind = .press, .shortcut = 0xff0d }, &snapshot, .{}).?;
    try testing.expectEqual(list[1023].ref, enter.toggle_thread);
}

test "drawing is bounded for 1,024 threads at any size, and timings are reported" {
    const a = testing.allocator;
    var fx = try Fixture.init(a);
    defer fx.deinit(a);
    const list = try manyRows(a, 1024);
    defer a.free(list);
    const snapshot = setup.Snapshot{ .target = .{ .pid = 1, .image_epoch = 1 }, .stopped = true, .offline = false, .collecting = true, .threads = list };
    var selection = setup.Selection{};
    _ = selection.sync(&snapshot);
    for (list[0..700]) |row| if (row.state != .exited) try selection.add(row.ref);
    const reasons = [_]profile.Stop{ .capacity, .metadata_lost, .thread_scope_changed };
    const facts = setup.Facts{ .id = 9, .offline = false, .collecting = false, .status = .capacity, .stop_reasons = &reasons, .started_ns = 0, .ended_ns = 61_000_000_000, .duration_ms = 0, .frequency_hz = 997, .context_switch = true, .samples = 16384, .discarded_samples = 912, .lost_samples = 40, .lost_records = 2, .selected_threads = 700, .unselected_threads = 300, .scope_change = .{ .pid = 1, .tid = 7, .parent_pid = 1, .parent_tid = 2, .time_ns = 5 }, .failure = null, .pid = 1 };
    var panel = Panel{ .open = true, .page = .threads };
    for ([_]gpu.Rect{ .{ .x = 8, .y = 91, .w = 624, .h = 352 }, .{ .x = 8, .y = 91, .w = 2544, .h = 1312 }, .{ .x = 0, .y = 0, .w = 100, .h = 40 } }) |bounds| {
        fx.r.clip = bounds;
        var best: u64 = std.math.maxInt(u64);
        for (0..20) |_| {
            fx.r.vertices = 0;
            const started = now();
            try panel.draw(&fx.r, fx.font, bounds, .{ .snapshot = &snapshot, .defaults = .{ .duration_ms = 125000, .frequency_hz = 333 }, .selection = &selection, .facts = facts, .clock = .{ .now_ns = 0 } });
            best = @min(best, now() - started);
        }
        try testing.expect(panel.row_count <= max_rows);
        std.debug.print("\npanel draw {d}x{d}: {d} us, {d} quads, {d} rows\n", .{ @as(u32, @intFromFloat(bounds.w)), @as(u32, @intFromFloat(bounds.h)), best / 1000, fx.r.vertices / 6, panel.row_count });
    }
}
fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
