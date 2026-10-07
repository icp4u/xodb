//! Invocation and cohort browser for an ended function observation, usually
//! an opened `.xoi`. Owner thread only. The view keeps stable IDs (capture
//! identity, comparison job id, call id, record ordinal) and re-resolves the
//! Session's capture and job every frame; it never holds their pointers
//! across frames. Rows are drawn for the visible window only. The filtered
//! call projection is rebuilt only when its key changes, never while paging.
//! Durations are measured wall intervals and words are raw untyped registers.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const model = @import("../observe/capture.zig");
const calls = @import("../observe/calls.zig");
const types = @import("../observe/types.zig");
const comparison = @import("../observe/comparison.zig");
const analysis = @import("../observe/analysis.zig");
const watch_ui = @import("watch.zig");
const timeline = @import("timeline.zig");
const style = @import("style.zig");
const theme = style.theme;
const Rect = gpu.Rect;

pub const default_threshold_ns: u64 = 4_000_000;
pub const List = enum { all, slow, fast, incomplete, records };
const row_h: f32 = 22;
const max_rows = 64;
const registers = [types.max_arguments][]const u8{ "DI", "SI", "DX", "CX", "R8", "R9" };
const Key = struct { session_id: u64, capture_id: u64, job: u64, list: List };
const Action = union(enum) { list: List, row: usize, entry, ret, parent, citing, call: u32 };
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
    projection: std.ArrayList(u32) = .empty,
    key: ?Key = null,
    projection_builds: u64 = 0,
    seen_job: u64 = 0,
    failed_open: u64 = 0,
    editor: watch_ui.Editor = .{},
    message: []const u8 = "",
    message_buffer: [192]u8 = undefined,
    hits: [max_rows + 24]Hit = undefined,
    hit_count: usize = 0,
    trace: bool = false,

    pub fn deinit(self: *View) void {
        self.projection.deinit(std.heap.page_allocator);
    }
    fn capture(session: *Session) ?*model.Capture {
        const value = session.observations.capture orelse return null;
        return if (value.store.finished) value else null;
    }
    fn job(session: *Session, value: *const model.Capture) ?*analysis.Job {
        const current = session.observation_analysis orelse return null;
        return if (std.meta.eql(current.capture.identity, value.identity)) current else null;
    }
    fn say(self: *View, comptime format: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.message_buffer, format, args) catch "";
    }
    fn note(self: *View, event: []const u8) void {
        if (!self.trace) return;
        std.debug.print("observation-view {s} list={s} call={?d} record={?d} top={d} rows={d} builds={d}\n", .{ event, @tagName(self.list), self.call, self.record, self.top, self.visible, self.projection_builds });
    }
    /// Re-resolves the capture and rebuilds the projection only on a key change.
    /// The first sight of a capture requests its comparison once.
    pub fn sync(self: *View, session: *Session) void {
        const value = capture(session) orelse {
            if (session.observation_archive) |archive| if (archive.done.load(.acquire) and archive.err != null and archive.id != self.failed_open) {
                self.failed_open = archive.id;
                if (self.trace) std.debug.print("observation-view open-failed error={s}\n", .{@errorName(archive.err.?)});
            };
            return;
        };
        const identity = [2]u64{ value.identity.session_id, value.identity.capture_id };
        if (self.identity == null or !std.mem.eql(u64, &self.identity.?, &identity)) {
            self.identity = identity;
            self.list = .all;
            self.previous = .all;
            self.call = if (value.store.calls.items.len > 0) 0 else null;
            self.record = if (value.store.records.items.len > 0) 0 else null;
            self.citing = null;
            self.top = 0;
            self.key = null;
            self.seen_job = 0;
            if (job(session, value) == null) self.recompute(session, self.threshold_ns orelse if (value.comparison_selection) |s| s.threshold_ns else default_threshold_ns);
            self.note("ready");
        }
        if (job(session, value)) |current| if (current.id != self.seen_job and current.done.load(.acquire)) {
            self.seen_job = current.id;
            if (self.trace) {
                if (current.result) |result| {
                    std.debug.print("observation-view comparison id={d} threshold={d} total={d} matched={d} complete={d} incomplete={d} fast={d} slow={d}\n", .{ current.id, current.selection.threshold_ns, result.summary.total_calls, result.summary.matched_calls, result.summary.complete_calls, result.summary.incomplete_calls, result.fast.count, result.slow.count });
                } else std.debug.print("observation-view comparison id={d} failed={s}\n", .{ current.id, if (current.err) |err| @errorName(err) else "unknown" });
            }
        };
        const current = job(session, value);
        const key = Key{ .session_id = identity[0], .capture_id = identity[1], .job = if (current) |j| j.id else 0, .list = self.list };
        if (self.key != null and std.meta.eql(self.key.?, key)) return;
        self.key = key;
        self.projection.clearRetainingCapacity();
        if (self.list == .all or self.list == .records) return;
        self.projection_builds += 1;
        const store = &value.store;
        self.projection.ensureTotalCapacityPrecise(std.heap.page_allocator, store.calls.items.len) catch {
            self.say("Not enough memory for this list", .{});
            return;
        };
        for (store.calls.items) |item| {
            const keep = switch (self.list) {
                .incomplete => store.duration(item) == null,
                .slow, .fast => if (current) |j| cohort(store, item, j.selection) == self.list else false,
                else => unreachable,
            };
            if (keep) self.projection.appendAssumeCapacity(item.id);
        }
    }
    fn count(self: *const View, value: *const model.Capture) usize {
        return switch (self.list) {
            .all => value.store.calls.items.len,
            .records => value.store.records.items.len,
            else => self.projection.items.len,
        };
    }
    fn rowId(self: *const View, index: usize) u32 {
        return switch (self.list) {
            .all, .records => @intCast(index),
            else => self.projection.items[index],
        };
    }
    /// Row of the current selection in the current list, if it is listed.
    fn position(self: *const View) ?usize {
        const id = (if (self.list == .records) self.record else self.call) orelse return null;
        return switch (self.list) {
            .all, .records => id,
            else => std.sort.binarySearch(u32, self.projection.items, id, order),
        };
    }
    fn order(id: u32, item: u32) std.math.Order {
        return std.math.order(id, item);
    }
    fn select(self: *View, value: *const model.Capture, index: usize) void {
        const total = self.count(value);
        if (total == 0) return;
        const row = @min(index, total - 1);
        const id = self.rowId(row);
        if (self.list == .records) {
            if (self.record != id) self.citeRecord(value, id);
        } else self.call = id;
        if (row < self.top) self.top = row;
        if (row >= self.top + self.visible) self.top = row + 1 - self.visible;
    }
    fn citeRecord(self: *View, value: *const model.Capture, ordinal: u32) void {
        self.record = ordinal;
        self.citing = null;
        for (value.store.calls.items) |item| {
            if (item.entry_record == ordinal or item.return_record == ordinal) {
                self.citing = item.id;
                break;
            }
        }
    }
    fn move(self: *View, value: *const model.Capture, delta: i64) void {
        const total = self.count(value);
        if (total == 0) return;
        const from: i64 = @intCast(self.position() orelse self.top);
        self.select(value, @intCast(std.math.clamp(from + delta, 0, @as(i64, @intCast(total - 1)))));
    }
    fn showList(self: *View, session: *Session, value: *const model.Capture, list: List) void {
        if (list != self.list) {
            self.previous = self.list;
            self.list = list;
        }
        self.sync(session);
        if (self.position()) |row| self.select(value, row) else {
            self.top = 0;
            self.select(value, 0);
        }
    }
    /// The same operation and busy rule as MCP `compare_observation`.
    fn recompute(self: *View, session: *Session, limit: u64) void {
        const value = capture(session) orelse return;
        var selection = if (job(session, value)) |current| current.selection else value.comparison_selection orelse comparison.Selection{ .threshold_ns = default_threshold_ns };
        selection.threshold_ns = limit;
        const id = session.compareObservation(selection) catch |err| {
            self.say("Comparison not started: {s}", .{@errorName(err)});
            self.note("recompute-refused");
            return;
        };
        self.say("Comparison #{d} started: threshold {d} ns", .{ id, limit });
        self.note("recompute");
    }
    fn threshold(session: *Session, value: *const model.Capture) u64 {
        return if (job(session, value)) |current| current.selection.threshold_ns else if (value.comparison_selection) |s| s.threshold_ns else default_threshold_ns;
    }
    fn cite(self: *View, session: *Session, value: *const model.Capture, action: Action) void {
        switch (action) {
            .entry, .ret => {
                const id = self.call orelse return;
                const item = value.store.calls.items[id];
                const ordinal = (if (action == .entry) item.entry_record else item.return_record) orelse {
                    self.say("Call #{d} has no {s} record ({s}); none is inferred", .{ id, if (action == .entry) "entry" else "return", @tagName(item.reason) });
                    self.note("citation-missing");
                    return;
                };
                self.citeRecord(value, ordinal);
                self.showList(session, value, .records);
                self.say("Record #{d} cited by call #{d}", .{ ordinal, id });
                self.note(if (action == .entry) "cite-entry" else "cite-return");
            },
            .parent => {
                const id = self.call orelse return;
                const parent = value.store.calls.items[id].parent_call orelse {
                    self.say("Call #{d} has no recorded parent call", .{id});
                    return;
                };
                self.focusCall(session, value, parent);
                self.note("cite-parent");
            },
            .citing => {
                if (self.list != .records) return;
                const id = self.citing orelse {
                    self.say("Record #{d} is not cited by any call", .{self.record orelse 0});
                    return;
                };
                self.focusCall(session, value, id);
                self.note("cite-call");
            },
            .call => |id| {
                self.focusCall(session, value, id);
                self.note("cite-example");
            },
            else => {},
        }
    }
    fn focusCall(self: *View, session: *Session, value: *const model.Capture, id: u32) void {
        if (id >= value.store.calls.items.len) return;
        self.call = id;
        var list = if (self.list == .records) self.previous else self.list;
        if (list == .records) list = .all;
        self.showList(session, value, list);
        if (self.position() == null) self.showList(session, value, .all);
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
    pub fn input(self: *View, w: *Window, session: *Session) void {
        self.trace = w.input.trace;
        watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
        defer watch_ui.Editor.focus(w, if (self.open and self.editor.open) &self.editor else null);
        self.sync(session);
        const value = capture(session);
        if (w.scroll != 0) {
            if (value) |v| {
                const total = self.count(v);
                self.top = @intCast(std.math.clamp(@as(i64, @intCast(self.top)) + w.scroll * 3, 0, @as(i64, @intCast(total -| self.visible))));
            }
            w.scroll = 0;
            w.dirty = true;
        }
        while (w.input.next()) |event| {
            if (w.closing) return;
            watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
            if (self.editor.open and self.editor.clipboard(w, event)) continue;
            if (event.kind == .button_press and event.code == 272) {
                w.dirty = true;
                const v = value orelse continue;
                for (self.hits[0..self.hit_count]) |target| {
                    if (event.x < target.rect.x or event.x >= target.rect.x + target.rect.w or event.y < target.rect.y or event.y >= target.rect.y + target.rect.h) continue;
                    switch (target.action) {
                        .list => |list| self.showList(session, v, list),
                        .row => |row| self.select(v, row),
                        else => self.cite(session, v, target.action),
                    }
                    self.note("click");
                    break;
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
                        self.editor.open = false;
                        self.recompute(session, requested);
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
            switch (event.shortcut) {
                'q' => {
                    w.closing = true;
                    w.close_reason = .quit_key;
                    return;
                },
                'n' => {
                    self.open = false;
                    self.note("close");
                    return;
                },
                keys.sym.escape => {
                    if (session.observation_archive) |archive| if (!archive.done.load(.acquire)) {
                        archive.progress.cancel.store(true, .release);
                        self.say("Cancelling archive open", .{});
                        continue;
                    };
                    if (value) |v| if (job(session, v)) |current| if (!current.done.load(.acquire)) {
                        current.cancel.store(true, .release);
                        self.say("Cancelling comparison #{d}", .{current.id});
                        continue;
                    };
                    self.open = false;
                    self.note("close");
                    return;
                },
                't' => if (value != null) {
                    self.editor.start();
                    self.editor.message = "Threshold in nanoseconds; Enter applies, Esc cancels";
                },
                '[', ']' => if (value) |v| {
                    const old = threshold(session, v);
                    self.recompute(session, if (event.shortcut == '[') @max(1, old / 2) else std.math.mul(u64, old, 2) catch old);
                },
                else => if (value) |v| switch (event.shortcut) {
                    keys.sym.tab => {
                        self.showList(session, v, cycle(self.list));
                        self.note("list");
                    },
                    'j', keys.sym.down => self.move(v, 1),
                    'k', keys.sym.up => self.move(v, -1),
                    0xff56 => self.move(v, @intCast(self.visible)),
                    0xff55 => self.move(v, -@as(i64, @intCast(self.visible))),
                    0xff50 => self.select(v, 0),
                    0xff57 => self.select(v, self.count(v) -| 1),
                    'e' => self.cite(session, v, .entry),
                    'r' => self.cite(session, v, .ret),
                    'p' => self.cite(session, v, .parent),
                    'c', 0xff0d => self.cite(session, v, .citing),
                    0xff08 => {
                        self.showList(session, v, if (self.previous == self.list) .all else self.previous);
                        self.note("back");
                    },
                    else => {},
                },
            }
            if (navigation) self.note("move");
        }
    }
    pub fn busy(session: *Session) bool {
        if (session.observation_archive) |archive| if (!archive.done.load(.acquire)) return true;
        if (session.observation_analysis) |current| if (!current.done.load(.acquire)) return true;
        return false;
    }
    fn hit(self: *View, rect: Rect, action: Action) void {
        if (self.hit_count == self.hits.len) return;
        self.hits[self.hit_count] = .{ .rect = rect, .action = action };
        self.hit_count += 1;
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, session: *Session, reserved: f32) !void {
        self.trace = w.input.trace;
        watch_ui.Editor.focus(w, if (self.editor.open) &self.editor else null);
        defer watch_ui.Editor.focus(w, if (self.open and self.editor.open) &self.editor else null);
        self.sync(session);
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        self.hit_count = 0;
        try r.rect(all, theme.background);
        try r.rect(.{ .x = 0, .y = 0, .w = width, .h = 44 }, theme.header);
        try r.rect(.{ .x = 0, .y = 43, .w = width, .h = 1 }, theme.border);
        const footer = height - 28 - reserved;
        try label(r, font, 18, footer + 4, width - 36, theme.weak, "{s}", .{"J/K PgDn rows  Tab list  E R P C citations  Bksp back  [ ] T threshold  Esc cancel  N close  Q quit"});
        const archive = session.observation_archive;
        const path = if (archive) |job_| job_.path else "";
        try label(r, font, 18, 12, width - 36, theme.text, "xodb / Invocations  {s}", .{path});
        const value = capture(session) orelse {
            const state = if (archive) |job_| job_.status() else null;
            if (state) |s| {
                if (s.state == .running) {
                    try label(r, font, 18, 60, width - 36, theme.text, "Opening on worker: {s} ({d} units). Esc cancels.", .{ @tagName(s.phase), s.units });
                } else try label(r, font, 18, 60, width - 36, theme.warm, "Open {s}: {s}. Nothing is shown from an unverified archive.", .{ @tagName(s.state), s.error_name orelse "no capture" });
            } else if (session.observations.capture != null) {
                try label(r, font, 18, 60, width - 36, theme.text, "Capture still collecting; stop it to browse calls.", .{});
            } else try label(r, font, 18, 60, width - 36, theme.weak, "No observation capture.", .{});
            return;
        };
        const store = &value.store;
        var buffers: [6][64]u8 = undefined;
        // Capture identity and evidence quality.
        var names: [256]u8 = undefined;
        var names_len: usize = 0;
        for (value.functions, 0..) |function, i| {
            const piece = std.fmt.bufPrint(names[names_len..], "{s}{s}", .{ if (i == 0) "" else ", ", function.name }) catch break;
            names_len += piece.len;
        }
        try label(r, font, 18, 52, width - 36, theme.text, "{s} #{d}/{d}  pid {d}  {s}  threads {d}  records {d}  calls {d}  stop {s}  finish {s}", .{ if (value.offline) "Saved" else "Live", value.identity.session_id, value.identity.capture_id, value.identity.pid, names[0..names_len], value.threads.len, store.records.items.len, store.calls.items.len, if (value.stop_reason) |s| @tagName(s) else "none", if (store.finish_reason) |s| @tagName(s) else "none" });
        const degraded = store.lost > 0 or store.throttles > 0 or store.rejected > 0 or store.first_gap != null or store.unread_possible;
        if (store.first_gap) |gap| {
            try label(r, font, 18, 74, width - 36, if (degraded) theme.warm else theme.weak, "Loss: {d} lost events  {d} throttles  {d} rejected  first gap {s} at record {s}  unread suffix possible: {s}", .{ store.lost, store.throttles, store.rejected, @tagName(gap.reason), if (gap.record) |n| std.fmt.bufPrint(&buffers[0], "#{d}", .{n}) catch "?" else "end", if (store.unread_possible) "yes" else "no" });
        } else try label(r, font, 18, 74, width - 36, if (degraded) theme.warm else theme.weak, "Loss: {d} lost events  {d} throttles  {d} rejected  no gap  unread suffix possible: {s}", .{ store.lost, store.throttles, store.rejected, if (store.unread_possible) "yes" else "no" });
        // Cohort summary from the retained comparison job.
        var y: f32 = 104;
        const current = job(session, value);
        if (current) |j| {
            const done = j.done.load(.acquire);
            try label(r, font, 18, y, width - 36, theme.focus, "Comparison #{d} {s}  threshold {d} ns (fast < T <= slow)  entry-to-return wall duration, not CPU time", .{ j.id, if (!done) "running (Esc cancels)" else if (j.err != null) "failed" else "completed", j.selection.threshold_ns });
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
                for ([2]comparison.Cohort{ result.fast, result.slow }, names_, colors) |c, name, color| {
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
                try label(r, font, 18, y, width - 36, theme.warm, "Comparison failed: {s}. [ ] or T starts another.", .{if (j.err) |err| @errorName(err) else "unknown"});
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
                .all => store.calls.items.len,
                .records => store.records.items.len,
                else => if (list == self.list) self.projection.items.len else null,
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
        if (self.editor.open) {
            const b = Rect{ .x = width / 2 - 260, .y = height / 2 - 50, .w = 520, .h = 92 };
            try style.box(r, b, theme.header, theme.focus, @splat(8));
            try r.textFit(font, b.x + 10, b.y + 8, b.w - 20, "Cohort threshold (ns)", theme.focus);
            try self.editor.draw(r, font, .{ .x = b.x + 10, .y = b.y + 34, .w = b.w - 20, .h = 22 });
            try r.textFit(font, b.x + 10, b.y + 61, b.w - 20, self.editor.message, theme.warm);
        }
        if (self.message.len > 0) try label(r, font, 18, footer - 24, width - 36, theme.warm, "{s}", .{self.message});
    }
    fn drawList(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const model.Capture, current: ?*analysis.Job) !void {
        const store = &value.store;
        try style.box(r, area, theme.surface, theme.border, @splat(6));
        r.clip = area;
        try label(r, font, area.x + 8, area.y + 4, area.w - 16, theme.focus, "{s}", .{if (self.list == .records) "RECORD  THREAD    TIME        KIND    FUNCTION       RAW WORD" else "CALL    THREAD    FUNCTION       ENTRY       WALL DURATION  COHORT   DI"});
        self.visible = @max(1, @min(max_rows, @as(usize, @intFromFloat(@max(0, @floor((area.h - 30) / row_h))))));
        const total = self.count(value);
        self.top = @min(self.top, total -| self.visible);
        if (total == 0) {
            const why: []const u8 = switch (self.list) {
                .slow, .fast => if (current == null) "No comparison yet." else "No calls in this cohort.",
                .incomplete => "Every call has a validated entry/return pair.",
                .records => "The capture contains no raw records.",
                .all => "The capture contains no calls.",
            };
            try label(r, font, area.x + 8, area.y + 32, area.w - 16, theme.weak, "{s}", .{why});
        }
        const selected = self.position();
        for (self.top..@min(total, self.top + self.visible)) |row| {
            const y = area.y + 28 + row_h * @as(f32, @floatFromInt(row - self.top));
            const rect = Rect{ .x = area.x + 2, .y = y, .w = area.w - 4, .h = row_h };
            if (row % 2 == 1) try r.rect(rect, theme.stripe);
            if (selected == row) try style.focus(r, rect, 3, 1);
            self.hit(rect, .{ .row = row });
            const id = self.rowId(row);
            var line = Line{};
            var piece: [64]u8 = undefined;
            line.add(std.fmt.bufPrint(&piece, "#{d}", .{id}) catch "?", 8);
            if (self.list == .records) {
                const event = store.records.items[id].event;
                line.add(std.fmt.bufPrint(&piece, "T{d}/{d}", .{ event.thread_id, event.tid }) catch "?", 10);
                line.add(relative(&buffer_rel, value, event.time_ns), 12);
                switch (event.data) {
                    .sample => |sample| {
                        line.add(if (sample.phase == .enter) "enter" else "return", 8);
                        line.add(functionName(value, sample.function_id), 15);
                        if (sample.phase == .enter) {
                            line.add(if (sample.arg_count > 0) std.fmt.bufPrint(&piece, "DI 0x{x}", .{sample.args[0]}) catch "?" else "DI -", 0);
                        } else line.add(if (sample.result) |bits| std.fmt.bufPrint(&piece, "AX 0x{x}", .{bits}) catch "?" else "AX -", 0);
                    },
                    .lost => |n| line.add(std.fmt.bufPrint(&piece, "LOST {d} events", .{n}) catch "?", 0),
                    else => line.add(@tagName(event.data), 0),
                }
                try r.textFit(font, rect.x + 6, y + 1, rect.w - 12, line.slice(), if (event.data == .sample) theme.text else theme.warm);
            } else {
                const item = store.calls.items[id];
                const entry = if (item.entry_record) |n| store.records.items[n].event else null;
                const duration = store.duration(item);
                const group: List = if (duration == null) .incomplete else if (current) |j| cohort(store, item, j.selection) else .all;
                line.add(std.fmt.bufPrint(&piece, "T{d}/{d}", .{ item.thread_id, item.tid }) catch "?", 10);
                line.add(functionName(value, item.function_id), 15);
                line.add(if (entry) |e| relative(&buffer_rel, value, e.time_ns) else "no entry", 12);
                line.add(if (duration) |d| timeline.duration(&piece, d) else @tagName(item.reason), 15);
                line.add(switch (group) {
                    .slow => "slow",
                    .fast => "fast",
                    .incomplete => "incompl",
                    else => "-",
                }, 9);
                line.add(if (entry) |e| word(&piece, e.data.sample, 0) else "-", 0);
                try r.textFit(font, rect.x + 6, y + 1, rect.w - 12, line.slice(), if (group == .incomplete) theme.warm else theme.text);
            }
        }
        if (self.top + self.visible < total) try style.fadeBottom(r, area, 0.6);
    }
    fn drawCall(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const model.Capture, current: ?*analysis.Job) !void {
        const store = &value.store;
        const x = area.x + 10;
        const w = area.w - 20;
        var y = area.y + 6;
        const id = self.call orelse {
            try label(r, font, x, y, w, theme.weak, "No call selected.", .{});
            return;
        };
        const item = store.calls.items[id];
        const entry = if (item.entry_record) |n| store.records.items[n].event else null;
        const ret = if (item.return_record) |n| store.records.items[n].event else null;
        try label(r, font, x, y, w, theme.focus, "Call #{d}  {s} (function #{d})", .{ id, functionName(value, item.function_id), item.function_id });
        y += 22;
        try label(r, font, x, y, w, theme.text, "Thread T{d} / TID {d}", .{ item.thread_id, item.tid });
        y += 22;
        if (store.duration(item)) |d| {
            try label(r, font, x, y, w, theme.text, "Wall duration {d} ns (complete pair)", .{d});
            y += 20;
            try label(r, font, x, y, w, theme.weak, "Includes waiting, scheduling and probe overhead.", .{});
            y += 22;
            if (current) |j| {
                const group = cohort(store, item, j.selection);
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
    fn drawRecord(self: *View, r: *gpu.Renderer, font: *Font, area: Rect, value: *const model.Capture) !void {
        const store = &value.store;
        const x = area.x + 10;
        const w = area.w - 20;
        var y = area.y + 6;
        const ordinal = self.record orelse {
            try label(r, font, x, y, w, theme.weak, "No record selected.", .{});
            return;
        };
        const record = store.records.items[ordinal];
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
                try label(r, font, x, y, w, theme.text, "{s} of {s} (function #{d})", .{ if (sample.phase == .enter) "Entry" else "Return", functionName(value, sample.function_id), sample.function_id });
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
// Scratch for row/detail formatting; owner-thread drawing only.
var buffer_rel: [64]u8 = undefined;
/// Monospace columns padded by code point, so unit symbols such as µ align.
const Line = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn add(self: *Line, text: []const u8, width: usize) void {
        const n = @min(text.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], text[0..n]);
        self.len += n;
        var cells = std.unicode.utf8CountCodepoints(text[0..n]) catch n;
        while (cells < width and self.len < self.bytes.len) : (cells += 1) {
            self.bytes[self.len] = ' ';
            self.len += 1;
        }
    }
    fn slice(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn cohort(store: *const calls.Store, item: types.Call, selection: comparison.Selection) List {
    const duration = store.duration(item) orelse return .incomplete;
    if (comparison.matches(store, item, selection) != .yes) return .all;
    return if (duration >= selection.threshold_ns) .slow else .fast;
}
fn tabName(list: List) []const u8 {
    return switch (list) {
        .all => "All calls",
        .slow => "Slow",
        .fast => "Fast",
        .incomplete => "Incomplete",
        .records => "Raw records",
    };
}
fn functionName(value: *const model.Capture, id: u32) []const u8 {
    for (value.functions) |function| if (function.id == id) return function.name;
    return "?";
}
fn relative(buffer: []u8, value: *const model.Capture, time: u64) []const u8 {
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
    try std.testing.expectEqual(@as(usize, 50_000), view.projection.items.len);
    try std.testing.expectEqual(@as(?u32, 1), view.call);
    const builds = view.projection_builds;
    const capacity = view.projection.capacity;
    for (0..500) |_| {
        w.input.queue[0] = .{ .kind = .repeat, .shortcut = 0xff56 };
        w.input.head = 0;
        w.input.count = 1;
        w.scroll = 2;
        view.input(&w, &session);
    }
    try std.testing.expectEqual(builds, view.projection_builds);
    try std.testing.expectEqual(capacity, view.projection.capacity);
    try std.testing.expectEqual(@as(?u32, view.projection.items[500 * 30 + 0]), view.call);
    try std.testing.expect(view.top + view.visible > view.position().? and view.top <= view.position().?);
    // Incomplete calls are listed with their reason and no duration.
    view.showList(&session, session.observations.capture.?, .incomplete);
    try std.testing.expectEqual(@as(usize, 1), view.projection.items.len);
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
    const value = session.observations.capture.?;
    view.focusCall(&session, value, 3);
    view.cite(&session, value, .entry);
    try std.testing.expectEqual(List.records, view.list);
    try std.testing.expectEqual(@as(?u32, 6), view.record);
    try std.testing.expectEqual(@as(?u32, 3), view.citing);
    view.cite(&session, value, .citing);
    try std.testing.expectEqual(List.all, view.list);
    try std.testing.expectEqual(@as(?u32, 3), view.call);
    view.cite(&session, value, .ret);
    try std.testing.expectEqual(@as(?u32, 7), view.record);
    w.input.queue[0] = .{ .kind = .press, .shortcut = 0xff08 };
    w.input.head = 0;
    w.input.count = 1;
    view.input(&w, &session);
    try std.testing.expectEqual(List.all, view.list);
    // The trailing call has no return; navigation reports it instead.
    view.focusCall(&session, value, 8);
    view.cite(&session, value, .ret);
    try std.testing.expectEqual(List.all, view.list);
    try std.testing.expect(std.mem.indexOf(u8, view.message, "no return record") != null);
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
    view.recompute(&session, 1);
    try std.testing.expect(std.mem.indexOf(u8, view.message, "ObservationAnalysisBusy") != null);
    session.observation_analysis.?.done.store(true, .release);
}
test "row columns pad by code point" {
    var line = Line{};
    line.add("+1.000 \u{b5}s", 12);
    line.add("enter", 0);
    var plain = Line{};
    plain.add("+1.000 ms", 12);
    plain.add("enter", 0);
    try std.testing.expectEqual(std.unicode.utf8CountCodepoints(line.slice()) catch 0, std.unicode.utf8CountCodepoints(plain.slice()) catch 1);
}
