//! Invocation browser input and rendering from immutable owner pages.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/window.zig").Window;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const types = @import("../observe/types.zig");
const model = @import("../observe/capture.zig");
const calls = @import("../observe/calls.zig");
const prepared = @import("../model/invocation_view.zig");
const watch_ui = @import("watch.zig");
const timeline = @import("timeline.zig");
const style = @import("style.zig");
const theme = style.theme;
const Rect = gpu.Rect;

pub const default_threshold_ns: u64 = 4_000_000;
pub const List = prepared.List;
const row_h: f32 = 22;
const max_rows = 64;
const registers = [types.max_arguments][]const u8{ "DI", "SI", "DX", "CX", "R8", "R9" };
const Action = prepared.Citation;
const Hit = struct { rect: Rect, action: Action };

pub const View = struct {
    open: bool = false,
    /// Startup threshold for the first comparison; later changes are explicit.
    threshold_ns: ?u64 = null,
    identity: ?[2]u64 = null,
    list: List = .all,
    previous: List = .all,
    call: ?u32 = null,
    record: ?u32 = null,
    /// Call that cites `record`, found once per record selection.
    citing: ?u32 = null,
    top: usize = 0,
    visible: usize = 1,
    projection_builds: u64 = 0,
    editor: watch_ui.Editor = .{},
    message: []const u8 = "",
    message_buffer: [192]u8 = undefined,
    hits: [max_rows + 24]Hit = undefined,
    hit_count: usize = 0,
    trace: bool = false,

    view: ?prepared.View = null,
    native: ?*prepared.Capture = null,
    fn say(self: *View, comptime format: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.message_buffer, format, args) catch "";
    }
    fn note(self: *View, event: []const u8) void {
        if (!self.trace) return;
        std.debug.print("observation-view {s} list={s} call={?d} record={?d} top={d} rows={d} builds={d}\n", .{ event, @tagName(self.list), self.call, self.record, self.top, self.visible, self.projection_builds });
    }
    fn cycle(list: List) List {
        return switch (list) {
            .all => .slow,
            .slow => .fast,
            .fast => .incomplete,
            .incomplete => .records,
            .records => .all,
        };
    }
    pub fn deinit(self: *View) void {
        if (self.native) |capture| {
            capture.deinit();
            std.heap.page_allocator.destroy(capture);
        }
    }
    pub fn request(self: *const View, trace: bool) ?prepared.Request {
        return if (self.open) .{ .visible = self.visible, .threshold_ns = self.threshold_ns, .trace = trace } else null;
    }
    pub fn present(self: *View, value: ?prepared.View) void {
        self.view = value;
        const v = value orelse return;
        self.identity = v.identity;
        self.list = v.list;
        self.previous = v.previous;
        self.call = v.call;
        self.record = v.record;
        self.citing = v.citing;
        self.top = v.top;
        self.projection_builds = v.projection_builds;
    }
    pub fn complete(self: *View, failure: ?anyerror) void {
        if (failure) |err| self.say("{s}", .{@errorName(err)}) else self.message = "";
    }
    fn refreshNative(self: *View, session: *Session, trace: bool) !void {
        if (self.native == null) {
            const capture = try std.heap.page_allocator.create(prepared.Capture);
            capture.* = .{};
            self.native = capture;
        }
        self.native.?.refresh(session, self.request(trace));
        self.present(self.native.?.value);
    }
    pub fn input(self: *View, w: *Window, session: *Session) void {
        self.refreshNative(session, w.input.trace) catch |err| {
            self.complete(err);
            return;
        };
        while (self.inputPrepared(w)) |action| {
            self.native.?.apply(session, .human, action) catch |err| {
                self.complete(err);
                continue;
            };
            self.complete(null);
            self.refreshNative(session, w.input.trace) catch |err| {
                self.complete(err);
                return;
            };
        }
    }
    fn command(self: *const View, kind: @FieldType(prepared.Action, "kind"), event: @FieldType(prepared.Action, "event")) ?prepared.Action {
        const view = self.view orelse return null;
        return .{ .key = view.key, .kind = kind, .event = event };
    }
    /// Stop at an owner command so subsequent input keeps its order with the
    /// resulting selection. Local editor and close input need no remote IO.
    pub fn inputPrepared(self: *View, w: *Window) ?prepared.Action {
        self.trace = w.input.trace;
        watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
        defer watch_ui.Editor.focus(w, if (self.open and self.editor.open) &self.editor else null);
        if (w.scroll != 0) {
            const amount = std.math.clamp(@as(i64, w.scroll) * 3, -192, 192);
            w.scroll = 0;
            w.dirty = true;
            if (self.view != null and self.view.?.ready) return self.command(.{ .scroll = amount }, .none);
        }
        while (w.input.next()) |event| {
            if (w.closing) return null;
            watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
            if (self.editor.open and self.editor.clipboard(w, event)) continue;
            if (event.kind == .button_press and event.code == 272) {
                w.dirty = true;
                if (self.editor.open) continue;
                for (self.hits[0..self.hit_count]) |target| {
                    if (event.x < target.rect.x or event.x >= target.rect.x + target.rect.w or event.y < target.rect.y or event.y >= target.rect.y + target.rect.h) continue;
                    return self.command(.{ .cite = target.action }, .click);
                }
                continue;
            }
            if (event.kind != .press and event.kind != .repeat) continue;
            w.dirty = true;
            if (self.editor.open) {
                if (self.editor.key(event)) |action| switch (action) {
                    .submit => |text| {
                        const requested = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t"), 10) catch {
                            self.editor.message = "Enter whole nanoseconds, e.g. 4000000";
                            continue;
                        };
                        if (self.view == null or !self.view.?.ready) {
                            self.editor.message = "Stop an observation capture before comparing calls";
                            continue;
                        }
                        self.editor.open = false;
                        return self.command(.{ .threshold = requested }, .none);
                    },
                    else => {},
                };
                continue;
            }
            if (!event.plain()) continue;
            const navigation = switch (event.shortcut) {
                'j', 'k', keys.sym.up, keys.sym.down, 0xff55, 0xff56 => true,
                else => false,
            };
            if (event.kind == .repeat and !navigation) continue;
            if (event.shortcut == 'q' and event.kind == .press and event.mods.shift) {
                w.closing = true;
                w.close_reason = .quit_key;
                return null;
            }
            if (event.shortcut == 'n') {
                self.open = false;
                self.note("close");
                return null;
            }
            if (event.shortcut == keys.sym.escape) {
                if (self.view) |v| {
                    if (v.archive_id) |id| return self.command(.{ .cancel_archive = id }, .none);
                    if (v.job) |job| if (!job.done) return self.command(.{ .cancel_comparison = job.id }, .none);
                }
                self.open = false;
                self.note("close");
                return null;
            }
            if (event.shortcut == 't') {
                self.editor.start();
                self.editor.message = "Threshold in nanoseconds; Enter applies, Esc cancels";
                continue;
            }
            const v = self.view orelse continue;
            if (!v.ready) continue;
            switch (event.shortcut) {
                '[', ']' => return self.command(.{ .threshold = if (event.shortcut == '[') @max(1, v.threshold_ns / 2) else std.math.mul(u64, v.threshold_ns, 2) catch v.threshold_ns }, .none),
                keys.sym.tab => return self.command(.{ .cite = .{ .list = cycle(self.list) } }, .list),
                'j', keys.sym.down => return self.command(.{ .move = 1 }, .move),
                'k', keys.sym.up => return self.command(.{ .move = -1 }, .move),
                0xff56 => return self.command(.{ .move = @intCast(self.visible) }, .move),
                0xff55 => return self.command(.{ .move = -@as(i64, @intCast(self.visible)) }, .move),
                0xff50 => return self.command(.{ .cite = .{ .row = 0 } }, .none),
                0xff57 => return self.command(.{ .cite = .{ .row = v.total -| 1 } }, .none),
                'e' => return self.command(.{ .cite = .entry }, .none),
                'r' => return self.command(.{ .cite = .ret }, .none),
                'p' => return self.command(.{ .cite = .parent }, .none),
                'c', 0xff0d => return self.command(.{ .cite = .citing }, .none),
                0xff08 => return self.command(.back, .back),
                else => {},
            }
        }
        return null;
    }
    pub fn busy(session: *Session) bool {
        if (session.observation_archive) |archive| if (!archive.done.load(.acquire)) return true;
        if (session.observation_analysis) |job| if (!job.done.load(.acquire)) return true;
        return false;
    }
    pub fn busyPrepared(self: *const View) bool {
        return if (self.view) |v| v.busy else false;
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, session: *Session, reserved: f32) !void {
        try self.refreshNative(session, w.input.trace);
        try self.drawPrepared(r, font, w, reserved);
    }
    fn drawList(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const prepared.View, current: ?prepared.Job) !void {
        try style.box(r, area, theme.surface, theme.border, @splat(6));
        r.clip = area;
        try label(r, font, area.x + 8, area.y + 4, area.w - 16, theme.focus, "{s}", .{if (self.list == .records) "RECORD  THREAD    TIME        KIND    FUNCTION       RAW WORD" else "CALL    THREAD    FUNCTION       ENTRY       WALL DURATION  COHORT   DI"});
        self.visible = @max(1, @min(max_rows, @as(usize, @intFromFloat(@max(0, @floor((area.h - 30) / row_h))))));
        if (value.total == 0) {
            const why: []const u8 = switch (self.list) {
                .slow, .fast => if (current == null) "No comparison yet." else "No calls in this cohort.",
                .incomplete => "Every call has a validated entry/return pair.",
                .records => "The capture contains no raw records.",
                .all => "The capture contains no calls.",
            };
            try label(r, font, area.x + 8, area.y + 32, area.w - 16, theme.weak, "{s}", .{why});
        }
        for (value.rows[0..@min(value.rows.len, self.visible)], 0..) |row, i| {
            const y = area.y + 28 + row_h * @as(f32, @floatFromInt(i));
            const rect = Rect{ .x = area.x + 2, .y = y, .w = area.w - 4, .h = row_h };
            if (row.ordinal % 2 == 1) try r.rect(rect, theme.stripe);
            if (value.position == row.ordinal) try style.focus(r, rect, 3, 1);
            self.hit(rect, .{ .row = row.ordinal });
            try r.textFit(font, rect.x + 6, y + 1, rect.w - 12, row.label, if (row.warm) theme.warm else theme.text);
        }
        if (value.top + self.visible < value.total) try style.fadeBottom(r, area, 0.6);
    }
    fn hit(self: *View, rect: Rect, action: Action) void {
        if (self.hit_count == self.hits.len) return;
        self.hits[self.hit_count] = .{ .rect = rect, .action = action };
        self.hit_count += 1;
    }
    pub fn drawPrepared(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, reserved: f32) !void {
        self.trace = w.input.trace;
        watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
        defer watch_ui.Editor.focus(w, if (self.open and self.editor.open) &self.editor else null);
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        self.hit_count = 0;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 44 }, theme.header);
        try r.rect(.{ .x = 0, .y = 43, .w = width, .h = 1 }, theme.border);
        const footer = height - 28 - reserved;
        try label(r, font, 18, footer + 4, width - 36, theme.weak, "{s}", .{"J/K PgDn rows  Tab list  E R P C citations  Bksp back  [ ] T threshold  Esc cancel  N close  Shift+Q quit"});
        const value = &(self.view orelse {
            try label(r, font, 18, 60, width - 36, theme.weak, "Preparing invocation details", .{});
            try self.drawEditor(r, font, width, height);
            return;
        });
        try label(r, font, 18, 12, width - 36, theme.text, "xodb / Invocations  {s}", .{value.path});
        if (!value.ready) {
            try label(r, font, 18, 60, width - 36, if (value.unavailable_warm) theme.warm else theme.text, "{s}", .{value.unavailable});
            try self.drawEditor(r, font, width, height);
            return;
        }
        var buffers: [6][64]u8 = undefined;
        try label(r, font, 18, 52, width - 36, theme.text, "{s}", .{value.title});
        try label(r, font, 18, 74, width - 36, if (value.degraded) theme.warm else theme.weak, "{s}", .{value.evidence});
        // Cohort summary from the retained comparison job.
        var y: f32 = 104;
        const current = value.job;
        if (current) |j| {
            const done = j.done;
            try label(r, font, 18, y, width - 36, theme.focus, "Comparison #{d} {s}  threshold {d} ns (fast < T <= slow)  entry-to-return wall duration, not CPU time", .{ j.id, if (!done) "running (Esc cancels)" else if (j.failure != null) "failed" else "completed", j.threshold_ns });
            y += 22;
            if (done) if (j.result) |result| {
                const s = result.summary;
                var reasons: [256]u8 = undefined;
                var reasons_len: usize = 0;
                for (s.incomplete_by_reason, 0..) |n, i| if (n > 0) {
                    const piece = std.fmt.bufPrint(reasons[reasons_len..], " {s} {d}", .{ @tagName(@as(types.Reason, @enumFromInt(i))), n }) catch break;
                    reasons_len += piece.len;
                };
                try label(r, font, 18, y, width - 36, theme.text, "Calls {d}: matched {d}, filtered {d}, filter-unavailable {d}; complete {d}, incomplete {d}{s}{s}", .{ s.total_calls, s.matched_calls, s.filtered_calls, s.unavailable_filter_calls, s.complete_calls, s.incomplete_calls, if (reasons_len > 0) " -" else "", reasons[0..reasons_len] });
                y += 22;
                const names_ = [2][]const u8{ "FAST", "SLOW" };
                const colors = [2]gpu.Color{ theme.good, theme.warm };
                for ([2]prepared.Cohort{ result.fast, result.slow }, names_, colors) |c, name, color| {
                    const d = c.duration;
                    try label(r, font, 18, y, width - 36, color, "{s} {d}: p50 {s}  p90 {s}  p99 {s}  min {s}  max {s}  sum {d} ns (inclusive, may overlap)", .{ name, c.count, nsLabel(&buffers[0], d.p50_ns), nsLabel(&buffers[1], d.p90_ns), nsLabel(&buffers[2], d.p99_ns), nsLabel(&buffers[3], d.min_ns), nsLabel(&buffers[4], d.max_ns), d.total_ns });
                    y += 20;
                    var x: f32 = 36;
                    const a0 = c.arguments[0];
                    var text_buffer: [160]u8 = undefined;
                    const head = std.fmt.bufPrint(&text_buffer, "DI words: {d} known, {d} distinct, {d} unavailable; examples", .{ a0.known, a0.distinct, a0.unavailable }) catch "";
                    try r.textFit(font, x, y, width - x - 18, head, theme.weak);
                    x += r.measure(font, head) + 8;
                    for (a0.values[0..@min(a0.values.len, 3)]) |item| {
                        const piece = std.fmt.bufPrint(&text_buffer, "0x{x} x{d} call #{d}", .{ item.value, item.count, item.representative_call }) catch "";
                        const piece_w = r.measure(font, piece);
                        if (x + piece_w > width - 18) break;
                        try r.text(font, x, y, piece, theme.focus);
                        self.hit(.{ .x = x, .y = y, .w = piece_w, .h = 20 }, .{ .call = item.representative_call });
                        x += piece_w + 14;
                    }
                    y += 22;
                }
            } else {
                try label(r, font, 18, y, width - 36, theme.warm, "Comparison failed: {s}. [ ] or T starts another.", .{if (j.failure) |err| err else "unknown"});
                y += 22;
            };
        } else {
            try label(r, font, 18, y, width - 36, theme.weak, "No comparison for this capture. [ ] or T starts one.", .{});
            y += 22;
        }
        // List tabs.
        y = @max(y + 4, 214);
        var x: f32 = 18;
        const tabs = [_]List{ .all, .slow, .fast, .incomplete, .records };
        for (tabs) |list| {
            var text_buffer: [64]u8 = undefined;
            const n: ?usize = switch (list) {
                .all => value.calls,
                .records => value.records,
                else => if (list == self.list) value.total else null,
            };
            const text = if (n) |v| std.fmt.bufPrint(&text_buffer, "{s} {d}", .{ tabName(list), v }) catch "" else tabName(list);
            const tab = Rect{ .x = x, .y = y, .w = r.measure(font, text) + 20, .h = 24 };
            try style.box(r, tab, if (list == self.list) style.fade(theme.focus, 0.18) else theme.surface, if (list == self.list) theme.focus else theme.border, @splat(6));
            try r.text(font, tab.x + 10, tab.y + 2, text, if (list == self.list) theme.text else theme.weak);
            self.hit(tab, .{ .list = list });
            x += tab.w + 8;
        }
        y += 32;
        // Virtualized list and the selected item's detail.
        const split = width >= 1000;
        const list_w = if (split) @floor(width * 0.58) else width - 36;
        const bottom = footer - 30;
        const list_h = if (split) bottom - y else @max(row_h * 3, (bottom - y) * 0.5);
        const area = Rect{ .x = 18, .y = y, .w = list_w, .h = @max(0, list_h) };
        const detail = if (split) Rect{ .x = area.x + area.w + 14, .y = y, .w = width - area.w - 50, .h = @max(0, bottom - y) } else Rect{ .x = 18, .y = y + area.h + 8, .w = width - 36, .h = @max(0, bottom - y - area.h - 8) };
        try self.drawList(r, font, area, value, current);
        try style.box(r, detail, theme.surface, theme.border, @splat(6));
        r.clip = detail;
        if (self.list == .records) try self.drawRecord(r, font, detail, value) else try self.drawCall(r, font, detail, value, current);
        r.clip = all;
        try self.drawEditor(r, font, width, height);
        const message = if (self.message.len > 0) self.message else value.message;
        if (message.len > 0) try label(r, font, 18, footer - 24, width - 36, theme.warm, "{s}", .{message});
    }
    fn drawEditor(self: *View, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (self.editor.open) {
            const b = Rect{ .x = width / 2 - 260, .y = height / 2 - 50, .w = 520, .h = 92 };
            try style.box(r, b, theme.header, theme.focus, @splat(8));
            try r.textFit(font, b.x + 10, b.y + 8, b.w - 20, "Cohort threshold (ns)", theme.focus);
            try self.editor.draw(r, font, .{ .x = b.x + 10, .y = b.y + 34, .w = b.w - 20, .h = 22 });
            try r.textFit(font, b.x + 10, b.y + 61, b.w - 20, self.editor.message, theme.warm);
        }
    }
    fn drawCall(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const prepared.View, current: ?prepared.Job) !void {
        const x = area.x + 10;
        const w = area.w - 20;
        var y = area.y + 6;
        const details = value.call_detail orelse {
            try label(r, font, x, y, w, theme.weak, "No call selected.", .{});
            return;
        };
        const item = details.item;
        const id = item.id;
        const entry = details.entry;
        const ret = details.ret;
        try label(r, font, x, y, w, theme.focus, "Call #{d}  {s} (function #{d})", .{ id, details.function, item.function_id });
        y += 22;
        try label(r, font, x, y, w, theme.text, "Thread T{d} / TID {d}", .{ item.thread_id, item.tid });
        y += 22;
        if (details.duration) |d| {
            try label(r, font, x, y, w, theme.text, "Wall duration {d} ns (complete pair)", .{d});
            y += 20;
            try label(r, font, x, y, w, theme.weak, "Includes waiting, scheduling and probe overhead.", .{});
            y += 22;
            if (current) |j| {
                const group = details.group;
                try label(r, font, x, y, w, if (group == .slow) theme.warm else theme.good, "{s} in comparison #{d}", .{ switch (group) {
                    .slow => "Slow (>= T)",
                    .fast => "Fast (< T)",
                    else => "Not matched by the filter",
                }, j.id });
                y += 22;
            }
        } else {
            try label(r, font, x, y, w, theme.warm, "Incomplete: {s}", .{@tagName(item.reason)});
            y += 20;
            try label(r, font, x, y, w, theme.weak, "No duration; no entry or return is inferred.", .{});
            y += 22;
        }
        y += 4;
        var buffer: [128]u8 = undefined;
        const entry_text = if (item.entry_record) |n| std.fmt.bufPrint(&buffer, "Entry record #{d}  +{s}  (E)", .{ n, relative(&buffer_rel, value, entry.?.time_ns) }) catch "" else "Entry: missing raw record";
        try self.citation(r, font, x, y, w, entry_text, item.entry_record != null, .entry);
        y += 22;
        var return_buffer: [128]u8 = undefined;
        const return_text = if (item.return_record) |n| std.fmt.bufPrint(&return_buffer, "Return record #{d}  +{s}  (R)", .{ n, relative(&buffer_rel, value, ret.?.time_ns) }) catch "" else std.fmt.bufPrint(&return_buffer, "Return: missing ({s})", .{@tagName(item.reason)}) catch "";
        try self.citation(r, font, x, y, w, return_text, item.return_record != null, .ret);
        y += 22;
        var parent_buffer: [64]u8 = undefined;
        const parent_text = if (item.parent_call) |p| std.fmt.bufPrint(&parent_buffer, "Parent call #{d}  (P)", .{p}) catch "" else "No recorded parent call";
        try self.citation(r, font, x, y, w, parent_text, item.parent_call != null, .parent);
        y += 28;
        try label(r, font, x, y, w, theme.weak, "Raw argument words (SysV registers, untyped):", .{});
        y += 22;
        for (registers, 0..) |name, i| {
            if (entry) |e| {
                if (i < e.data.sample.arg_count) {
                    try label(r, font, x + 12, y, w - 12, theme.text, "{s}  0x{x:0>16}  ({d})", .{ name, e.data.sample.args[i], e.data.sample.args[i] });
                } else try label(r, font, x + 12, y, w - 12, theme.weak, "{s}  not captured", .{name});
            } else try label(r, font, x + 12, y, w - 12, theme.weak, "{s}  unknown (no entry record)", .{name});
            y += 20;
        }
        if (ret) |e| {
            if (e.data.sample.result) |v| {
                try label(r, font, x, y, w, theme.text, "AX return word  0x{x:0>16}  ({d})", .{ v, v });
            } else try label(r, font, x, y, w, theme.weak, "AX return word not captured", .{});
        } else try label(r, font, x, y, w, theme.weak, "AX return word unknown (no return record)", .{});
        y += 26;
        if (entry) |e| {
            const stack = e.data.sample.stack;
            try label(r, font, x, y, w, theme.weak, "Entry callchain: {d} raw PCs{s}, not symbolic frames", .{ stack.len, if (stack.truncated) ", truncated" else "" });
            y += 20;
            for (stack.pcs[0..stack.len]) |pc| {
                if (y + 20 > area.y + area.h) break;
                try label(r, font, x + 12, y, w - 12, theme.text, "0x{x}", .{pc});
                y += 20;
            }
        }
    }
    fn drawRecord(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const prepared.View) !void {
        const x = area.x + 10;
        const w = area.w - 20;
        var y = area.y + 6;
        const details = value.record_detail orelse {
            try label(r, font, x, y, w, theme.weak, "No record selected.", .{});
            return;
        };
        const record = details.record;
        const ordinal = record.ordinal;
        const event = record.event;
        try label(r, font, x, y, w, theme.focus, "Raw record #{d}", .{ordinal});
        y += 22;
        try label(r, font, x, y, w, theme.text, "Thread T{d} / TID {d}  time {d} ns (+{s})", .{ event.thread_id, event.tid, event.time_ns, relative(&buffer_rel, value, event.time_ns) });
        y += 22;
        var buffer: [96]u8 = undefined;
        const citing_text = if (self.citing) |id| std.fmt.bufPrint(&buffer, "Cited by call #{d}  (C)", .{id}) catch "" else "Not cited by any call";
        try self.citation(r, font, x, y, w, citing_text, self.citing != null, .citing);
        y += 28;
        switch (event.data) {
            .sample => |sample| {
                try label(r, font, x, y, w, theme.text, "{s} of {s} (function #{d})", .{ if (sample.phase == .enter) "Entry" else "Return", details.function, sample.function_id });
                y += 20;
                try label(r, font, x, y, w, theme.text, "Stack key 0x{x}  IP 0x{x}", .{ sample.stack_key, sample.ip });
                y += 22;
                if (sample.phase == .enter) {
                    try label(r, font, x, y, w, theme.weak, "{d} raw argument words captured (untyped)", .{sample.arg_count});
                    y += 20;
                    for (sample.args[0..sample.arg_count], 0..) |bits, i| {
                        try label(r, font, x + 12, y, w - 12, theme.text, "{s}  0x{x:0>16}", .{ registers[i], bits });
                        y += 20;
                    }
                } else if (sample.result) |bits| {
                    try label(r, font, x, y, w, theme.text, "AX return word  0x{x:0>16}", .{bits});
                    y += 20;
                } else {
                    try label(r, font, x, y, w, theme.weak, "AX return word not captured", .{});
                    y += 20;
                }
                try label(r, font, x, y, w, theme.weak, "Perf registers {s}; stack word {d}/{d} bytes", .{ if (sample.raw_registers != null) "retained" else "not retained", sample.stack_word_valid, sample.stack_word_size });
                y += 20;
                try label(r, font, x, y, w, theme.weak, "Callchain {d} raw PCs{s}; not symbolic frames", .{ sample.stack.len, if (sample.stack.truncated) " (truncated)" else "" });
            },
            .lost => |n| try label(r, font, x, y, w, theme.warm, "Loss: {d} events lost here. Later events in this thread stay unpaired evidence.", .{n}),
            .throttle, .unthrottle => try label(r, font, x, y, w, theme.warm, "Kernel {s}; this thread's pairing is quarantined from here.", .{@tagName(event.data)}),
            .decode_error => try label(r, font, x, y, w, theme.warm, "Decode error; this thread's pairing is quarantined from here.", .{}),
            else => try label(r, font, x, y, w, theme.warm, "Boundary event: {s}. Open calls end without a return.", .{@tagName(event.data)}),
        }
    }
    fn citation(self: *View, r: *gpu.Renderer, font: *Font, x: f32, y: f32, w: f32, text: []const u8, available: bool, action: Action) !void {
        if (!available) return r.textFit(font, x, y, w, text, theme.warm);
        const rect = Rect{ .x = x - 4, .y = y - 1, .w = @min(w + 4, r.measure(font, text) + 8), .h = 21 };
        try style.box(r, rect, style.fade(theme.focus, 0.08), style.fade(theme.focus, 0.5), @splat(4));
        try r.textFit(font, x, y, w, text, theme.focus);
        self.hit(rect, action);
    }
};
// Frame-local formatting scratch, never used by the owner.
var buffer_rel: [64]u8 = undefined;
fn tabName(list: List) []const u8 {
    return switch (list) {
        .all => "All calls",
        .slow => "Slow",
        .fast => "Fast",
        .incomplete => "Incomplete",
        .records => "Raw records",
    };
}
fn relative(buffer: []u8, value: *const prepared.View, time: u64) []const u8 {
    if (time < value.started_ns) return std.fmt.bufPrint(buffer, "-{d} ns", .{value.started_ns - time}) catch "?";
    return timeline.duration(buffer, time - value.started_ns);
}
fn word(buffer: []u8, sample: types.Sample, index: usize) []const u8 {
    if (index >= sample.arg_count) return "-";
    return std.fmt.bufPrint(buffer, "0x{x}", .{sample.args[index]}) catch "?";
}
fn nsLabel(buffer: []u8, value: ?u64) []const u8 {
    return if (value) |v| timeline.duration(buffer, v) else "n/a";
}
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    try r.textFit(font, x, y, @max(0, width), text, color);
}

fn testCapture(a: std.mem.Allocator, n: usize) !*model.Capture {
    const identity = model.Identity{ .session_id = 7, .capture_id = 1, .process_id = 1, .pid = 100, .image_epoch = 1, .generation = 1 };
    const functions = [_]model.Function{.{ .id = 1, .name = "work", .path = "/fixture", .identity = std.mem.zeroes(@import("../profile/uprobe_hooks.zig").Identity), .file_offset = 0, .link_address = 0, .runtime_address = 0x1000 }};
    const value = try model.Capture.create(a, identity, .{ .record_limit = @intCast(@min(calls.max_records, n * 2 + 8)), .memory_limit = 256 * 1024 * 1024 }, &.{.{ .id = 1, .tid = 101 }}, &functions);
    errdefer value.deinit();
    for (0..n) |i| {
        var entry = calls.fixtureEvent(i * 100, 1, .enter, 1, 100);
        entry.data.sample.arg_count = 1;
        entry.data.sample.args[0] = i % 2;
        try value.feed(entry);
        var ret = calls.fixtureEvent(i * 100 + @as(u64, if (i % 2 == 0) 10 else 60), 1, .leave, 1, 100);
        ret.data.sample.result = i;
        try value.feed(ret);
    }
    // A trailing entry stays incomplete: no return is invented.
    try value.feed(calls.fixtureEvent(n * 100, 1, .enter, 1, 100));
    value.store.finish(.capture_end);
    value.offline = true;
    return value;
}
fn awaitJob(session: *Session) !void {
    const current = session.observation_analysis orelse return error.NoObservationComparison;
    while (!current.done.load(.acquire)) std.Thread.yield() catch {};
}
test "large captures page without per-record allocation or projection rebuilds" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    session.offline = true;
    session.observations.capture = try testCapture(std.heap.page_allocator, 100_000);
    var view = View{ .open = true, .threshold_ns = 50 };
    defer view.deinit();
    var w = Window{ .width = 1280, .height = 800 };
    view.input(&w, &session);
    try awaitJob(&session);
    try std.testing.expectEqual(@as(u64, 50), session.observation_analysis.?.selection.threshold_ns);
    try std.testing.expectEqual(@as(?u32, 0), view.call);
    view.visible = 30;
    w.input.queue[0] = .{ .kind = .press, .shortcut = keys.sym.tab };
    w.input.head = 0;
    w.input.count = 1;
    view.input(&w, &session);
    try std.testing.expectEqual(List.slow, view.list);
    try std.testing.expectEqual(@as(usize, 50_000), view.native.?.state.projection.items.len);
    try std.testing.expectEqual(@as(?u32, 1), view.call);
    const builds = view.projection_builds;
    const capacity = view.native.?.state.projection.capacity;
    for (0..500) |_| {
        w.input.queue[0] = .{ .kind = .repeat, .shortcut = 0xff56 };
        w.input.head = 0;
        w.input.count = 1;
        w.scroll = 2;
        view.input(&w, &session);
    }
    try std.testing.expectEqual(builds, view.projection_builds);
    try std.testing.expectEqual(capacity, view.native.?.state.projection.capacity);
    try std.testing.expectEqual(@as(?u32, view.native.?.state.projection.items[500 * 30 + 0]), view.call);
    try std.testing.expect(view.top + view.visible > view.view.?.position.? and view.top <= view.view.?.position.?);
    // Incomplete calls are listed with their reason and no duration.
    try testAction(&view, &session, .{ .cite = .{ .list = .incomplete } });
    try std.testing.expectEqual(@as(usize, 1), view.native.?.state.projection.items.len);
    try std.testing.expectEqual(types.Reason.capture_end, session.observations.capture.?.store.calls.items[view.call.?].reason);
}
test "selection survives recomputation and close while citations follow raw ordinals" {
    var session = Session{ .id = 1 };
    defer session.deinit();
    session.offline = true;
    session.observations.capture = try testCapture(std.heap.page_allocator, 8);
    var view = View{ .open = true };
    defer view.deinit();
    var w = Window{ .width = 1280, .height = 800 };
    view.input(&w, &session);
    try awaitJob(&session);
    try testAction(&view, &session, .{ .cite = .{ .call = 3 } });
    try testAction(&view, &session, .{ .cite = .entry });
    try std.testing.expectEqual(List.records, view.list);
    try std.testing.expectEqual(@as(?u32, 6), view.record);
    try std.testing.expectEqual(@as(?u32, 3), view.citing);
    try testAction(&view, &session, .{ .cite = .citing });
    try std.testing.expectEqual(List.all, view.list);
    try std.testing.expectEqual(@as(?u32, 3), view.call);
    try testAction(&view, &session, .{ .cite = .ret });
    try std.testing.expectEqual(@as(?u32, 7), view.record);
    w.input.queue[0] = .{ .kind = .press, .shortcut = 0xff08 };
    w.input.head = 0;
    w.input.count = 1;
    view.input(&w, &session);
    try std.testing.expectEqual(List.all, view.list);
    // The trailing call has no return; navigation reports it instead.
    try testAction(&view, &session, .{ .cite = .{ .call = 8 } });
    try testAction(&view, &session, .{ .cite = .ret });
    try std.testing.expectEqual(List.all, view.list);
    try std.testing.expect(std.mem.indexOf(u8, view.view.?.message, "no return record") != null);
    // Doubling the threshold starts a new job; the selected call stays.
    const first = session.observation_analysis.?.id;
    w.input.queue[0] = .{ .kind = .press, .shortcut = ']' };
    w.input.head = 0;
    w.input.count = 1;
    view.input(&w, &session);
    try awaitJob(&session);
    try std.testing.expect(session.observation_analysis.?.id != first);
    try std.testing.expectEqual(default_threshold_ns * 2, session.observation_analysis.?.selection.threshold_ns);
    try std.testing.expectEqual(@as(?u32, 8), view.call);
    w.input.queue[0] = .{ .kind = .press, .shortcut = 'n' };
    w.input.head = 0;
    w.input.count = 1;
    view.input(&w, &session);
    try std.testing.expect(!view.open);
    view.open = true;
    view.input(&w, &session);
    try std.testing.expectEqual(@as(?u32, 8), view.call);
    // Running comparisons are never replaced: the model's busy rule applies.
    session.observation_analysis.?.done.store(false, .release);
    try testAction(&view, &session, .{ .threshold = 1 });
    try std.testing.expect(std.mem.indexOf(u8, view.view.?.message, "ObservationAnalysisBusy") != null);
    session.observation_analysis.?.done.store(true, .release);
}
fn testAction(view: *View, session: *Session, kind: @FieldType(prepared.Action, "kind")) !void {
    try view.refreshNative(session, false);
    try view.native.?.apply(session, .human, view.command(kind, .none).?);
    try view.refreshNative(session, false);
}

test "invocation threshold entry captures keys before any observation exists" {
    var view = View{ .open = true };
    defer view.deinit();
    var w = Window{};
    w.input.count = 2;
    w.input.queue[0] = .{ .kind = .press, .shortcut = 't' };
    w.input.queue[1] = .{ .kind = .press, .shortcut = 'n' };
    try std.testing.expect(view.inputPrepared(&w) == null);
    try std.testing.expect(view.open and view.editor.open);
}
