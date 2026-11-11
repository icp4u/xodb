//! Session catalog navigation; import/index work belongs to the owner loop.
const std = @import("std");
const model = @import("../profile/agent_time.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/window.zig").Window;
const keys = @import("../platform/input.zig");
const theme = @import("style.zig").theme;

pub const Browser = struct {
    selected: usize = 0,
    top: usize = 0,
    agent: u8 = 0,
    query: [128]u8 = @splat(0),
    query_len: usize = 0,
    project: [128]u8 = @splat(0),
    project_len: usize = 0,
    dates: [64]u8 = @splat(0),
    dates_len: usize = 0,
    editing: enum { none, query, project, dates } = .none,
    row_ids: [128]usize = undefined,
    row_count: usize = 0,
    fleet_requested: bool = false,
    const agents = [_][]const u8{ "all", "codex", "claude", "grok" };

    pub fn matches(self: *const Browser, e: model.Catalog.Entry) bool {
        return self.matchesMode(e, false);
    }
    fn matchesMode(self: *const Browser, e: model.Catalog.Entry, fleet: bool) bool {
        if (self.agent != 0 and !std.mem.eql(u8, agents[self.agent], e.agent)) return false;
        if (self.project_len > 0 and std.ascii.indexOfIgnoreCase(e.project, self.project[0..self.project_len]) == null) return false;
        if (self.query_len > 0 and std.ascii.indexOfIgnoreCase(e.title, self.query[0..self.query_len]) == null and std.ascii.indexOfIgnoreCase(e.project, self.query[0..self.query_len]) == null) return false;
        if (self.dates_len > 0) {
            const dates = self.dates[0..self.dates_len];
            const split = std.mem.indexOf(u8, dates, "..");
            const since = dates[0 .. split orelse dates.len];
            const until = if (split) |at| dates[at + 2 ..] else "";
            if (fleet and !e.indexed) return true; // Unknown child extent: let the worker decide.
            const first_date = if (fleet and e.activity_date.len > 0) e.activity_date else e.date;
            const last_date = if (fleet) e.ended else e.date;
            if (first_date.len == 0) return fleet;
            if (since.len > 0 and last_date.len > 0 and std.mem.order(u8, last_date, since) == .lt) return false;
            if (until.len > 0 and std.mem.order(u8, first_date, until) == .gt) return false;
        }
        return true;
    }
    pub fn fleetOptions(self: *const Browser, allocator: std.mem.Allocator, catalog: *const model.Catalog) ![]u8 {
        const Entry = struct { agent: []const u8, path: []const u8 };
        var entries: [32]Entry = undefined;
        var count: usize = 0;
        var matched: usize = 0;
        var bytes: usize = 0;
        for (catalog.entries) |entry| {
            if (!self.matchesMode(entry, true)) continue;
            matched += 1;
            const estimate = entry.path.len * 6 + 128;
            if (count == entries.len or bytes + estimate > 48000) continue;
            entries[count] = .{ .agent = entry.agent, .path = entry.path };
            count += 1;
            bytes += estimate;
        }
        return std.json.Stringify.valueAlloc(allocator, .{ .sessions = entries[0..count], .matched = matched, .dates = self.dates[0..self.dates_len] }, .{});
    }
    fn first(self: *Browser, catalog: *const model.Catalog) void {
        self.selected = 0;
        self.top = 0;
        for (catalog.entries, 0..) |e, index| if (self.matches(e)) {
            self.selected = index;
            break;
        };
    }
    fn move(self: *Browser, catalog: *const model.Catalog, direction: i32) void {
        var index: i64 = @as(i64, @intCast(self.selected)) + direction;
        while (index >= 0 and index < catalog.entries.len) : (index += direction) {
            if (self.matches(catalog.entries[@intCast(index)])) {
                self.selected = @intCast(index);
                if (self.selected < self.top) self.top = self.selected;
                if (self.row_count > 0 and self.selected > self.row_ids[self.row_count - 1]) self.top = self.selected;
                return;
            }
        }
    }
    pub fn input(self: *Browser, window: *Window, catalog: ?*model.Catalog) ?usize {
        while (window.input.next()) |event| {
            window.dirty = true;
            if (event.kind == .button_press and event.code == 0x110 and event.y >= 140) {
                const row: usize = @intFromFloat((event.y - 140) / 52);
                if (row < self.row_count) self.selected = self.row_ids[row];
                continue;
            }
            if (event.kind != .press and event.kind != .repeat) continue;
            if (self.editing != .none) {
                const buffer: []u8 = switch (self.editing) {
                    .query => &self.query,
                    .project => &self.project,
                    .dates => &self.dates,
                    .none => unreachable,
                };
                const len: *usize = switch (self.editing) {
                    .query => &self.query_len,
                    .project => &self.project_len,
                    .dates => &self.dates_len,
                    .none => unreachable,
                };
                switch (event.sym) {
                    keys.sym.escape, 0xff0d => self.editing = .none,
                    0xff08 => if (len.* > 0) {
                        len.* -= 1;
                        while (len.* > 0 and buffer[len.*] & 0xc0 == 0x80) len.* -= 1;
                    },
                    else => {
                        const text = event.text();
                        if (len.* + text.len <= buffer.len) {
                            @memcpy(buffer[len.*..][0..text.len], text);
                            len.* += text.len;
                        }
                    },
                }
                if (catalog) |c| self.first(c);
                continue;
            }
            if (!event.plain()) continue;
            switch (event.shortcut) {
                'q' => window.closing = true,
                '/' => self.editing = .query,
                'p' => self.editing = .project,
                'd' => self.editing = .dates,
                'f' => self.fleet_requested = true,
                'a' => {
                    self.agent = (self.agent + 1) % @as(u8, agents.len);
                    if (catalog) |c| self.first(c);
                },
                'x' => {
                    self.query_len = 0;
                    self.project_len = 0;
                    self.dates_len = 0;
                    self.agent = 0;
                    if (catalog) |c| self.first(c);
                },
                keys.sym.up => if (catalog) |c| {
                    self.move(c, -1);
                },
                keys.sym.down => if (catalog) |c| {
                    self.move(c, 1);
                },
                0xff0d => if (catalog) |c| {
                    if (self.selected < c.entries.len and self.matches(c.entries[self.selected])) return self.selected;
                },
                else => {},
            }
        }
        if (window.scroll != 0) {
            if (catalog) |c| self.move(c, if (window.scroll > 0) 1 else -1);
            window.scroll = 0;
            window.dirty = true;
        }
        return null;
    }
    pub fn draw(self: *Browser, r: *gpu.Renderer, font: *Font, window: *Window, catalog: ?*model.Catalog, failure: ?anyerror, indexing: ?usize) !void {
        const width: f32 = @floatFromInt(window.width);
        const height: f32 = @floatFromInt(window.height);
        r.clip = .{ .x = 0, .y = 0, .w = width, .h = height };
        try r.rect(r.clip, theme.background);
        try label(r, font, 12, 10, width - 24, theme.good, "xodb / Agent sessions / newest activity first", .{});
        try label(r, font, 12, 38, width - 24, theme.text, "Agent: {s}   Project: {s}   Dates: {s}", .{ agents[self.agent], self.project[0..self.project_len], self.dates[0..self.dates_len] });
        try label(r, font, 12, 64, width - 24, theme.text, "Search: {s}   Editing: {s}", .{ self.query[0..self.query_len], @tagName(self.editing) });
        var cached: usize = 0;
        if (catalog) |c| for (c.entries) |entry| {
            cached += @intFromBool(entry.cached);
        };
        try label(r, font, 12, 90, width - 24, theme.weak, "Cached totals: {d} / '?' is unknown, not zero / index runs on a worker", .{cached});
        try label(r, font, 12, height - 28, width - 24, theme.weak, "Enter open   F fleet (32 newest matches)   A agent   P project   D dates   / search   X clear   Q quit", .{});
        self.row_count = 0;
        if (failure) |err| {
            try label(r, font, 12, 140, width - 24, theme.warm, "Catalog unavailable: {s}", .{@errorName(err)});
            return;
        }
        const c = catalog orelse {
            try label(r, font, 12, 140, width - 24, theme.text, "Discovering local session logs…", .{});
            return;
        };
        var shown: usize = 0;
        for (c.entries[@min(self.top, c.entries.len)..], self.top..) |e, index| {
            if (!self.matches(e)) continue;
            const y = 140 + @as(f32, @floatFromInt(shown)) * 52;
            if (y + 49 > height - 42 or shown == self.row_ids.len) break;
            self.row_ids[shown] = index;
            shown += 1;
            if (index == self.selected) try r.rect(.{ .x = 8, .y = y - 3, .w = width - 16, .h = 49 }, theme.header);
            try label(r, font, 12, y, width - 24, if (index == self.selected) theme.good else theme.text, "{s} / {s} / {s}", .{ e.agent, e.project, e.title });
            var dur_buf: [48]u8 = undefined;
            var tok_buf: [48]u8 = undefined;
            var turn_buf: [32]u8 = undefined;
            const duration = if (e.duration) |v| std.fmt.bufPrint(&dur_buf, "{d:.1}s", .{v}) catch "?" else "?";
            const tokens = if (e.tokens) |v| std.fmt.bufPrint(&tok_buf, "{d}", .{v}) catch "?" else if (e.indexed) "unavailable" else "?";
            const turns = if (e.turn_count) |v| std.fmt.bufPrint(&turn_buf, "{d}", .{v}) catch "?" else "?";
            try label(r, font, 12, y + 23, width - 24, theme.text, "{s} / duration {s} / tokens {s} / turns {s} / {s}", .{ e.started, duration, tokens, turns, e.failure orelse if (indexing == index) "indexing" else e.cache_state });
        }
        self.row_count = shown;
        if (shown == 0) try label(r, font, 12, 140, width - 24, theme.weak, "No sessions match these filters", .{});
    }
};
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [2048]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, @max(0, width), value, color);
}
