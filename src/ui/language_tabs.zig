const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Session = @import("../model/session.zig").Session;
const tabs = @import("../model/language_tabs.zig");
const selection = @import("../model/language_selection.zig");
const style = @import("style.zig");
const theme = style.theme;
const Row = struct { name: []const u8, location: []const u8, reason: ?[]const u8, segment: usize, frame: ?usize };
const Hit = struct { rect: gpu.Rect, segment: usize, frame: usize };
const SelectedKey = struct { generation: u64, tid: i32, language: tabs.Tab, segment: usize, frame: usize };
const Key = struct { session: u64, generation: u64, revision: u64, metadata: u64, tid: i32, frame: usize, tab: tabs.Tab };
pub const Panel = struct {
    hits: [6]?gpu.Rect = @splat(null),
    content_y: f32 = 135,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    rows: []Row = &.{},
    row_hits: [64]?Hit = @splat(null),
    scroll: usize = 0,
    revealed: ?SelectedKey = null,
    stack_basis: ?[]const u8 = null,
    message: []const u8 = "",
    key: ?Key = null,
    pub fn deinit(self: *Panel) void {
        self.arena.deinit();
    }
    pub fn hit(self: *const Panel, x: f32, y: f32) ?tabs.Tab {
        for (self.hits, 0..) |maybe, i| if (maybe) |rect| {
            if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return tabs.order[i];
        };
        return null;
    }
    pub fn click(self: *Panel, session: *Session, x: f32, y: f32) !bool {
        const key = self.key orelse return false;
        for (self.row_hits) |maybe| if (maybe) |row| {
            const rect = row.rect;
            if (x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h) continue;
            if (key.session != session.id or key.generation != session.target.snapshot().generation or key.metadata != session.metadata.revision or key.tab != session.language_tabs.selected)
                return error.StaleLanguageView;
            try selection.selectLogical(session, key.tid, key.tab, row.segment, row.frame);
            return true;
        };
        return false;
    }
    pub fn scrollBy(self: *Panel, amount: i32) void {
        if (amount >= 0) self.scroll = @min(self.rows.len -| 1, self.scroll +| @as(usize, @intCast(amount))) else self.scroll -|= @intCast(-@as(i64, amount));
    }
    pub fn header(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, state: *const tabs.State) !void {
        self.hits = @splat(null);
        r.clip = rect;
        try style.box(r, rect, theme.background, theme.border, @splat(5));
        var x = rect.x + 6;
        var y = rect.y + 5;
        for (tabs.order, 0..) |tab, i| {
            if (!state.visible(tab)) continue;
            const width = r.measure(font, tabs.title(tab)) + 16;
            if (x + width > rect.x + rect.w - 5 and x > rect.x + 6) {
                x = rect.x + 6;
                y += 28;
            }
            const button = gpu.Rect{ .x = x, .y = y, .w = width, .h = 25 };
            self.hits[i] = button;
            if (state.selected == tab) try style.focus(r, button, 4, 1);
            try r.text(font, x + 8, y + 3, tabs.title(tab), if (state.selected == tab) theme.text else theme.weak);
            x += width + 2;
        }
        self.content_y = y + 39;
        try r.rect(.{ .x = rect.x + 1, .y = y + 31, .w = rect.w - 2, .h = 1 }, theme.border);
    }
    fn collect(self: *Panel, stack: anytype) !void {
        const a = self.arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        self.message = "Segment anchor; frame pairing unproved";
        var count: usize = 0;
        for (stack.segments, 0..) |segment, segment_index| {
            if (rows.items.len >= 128) {
                self.message = "LanguageFrameLimit";
                break;
            }
            if (@hasField(@TypeOf(segment), "layout_source")) self.stack_basis = segment.layout_source;
            try rows.append(a, .{ .name = try std.fmt.allocPrint(a, "Segment {d}", .{segment_index}), .location = if (segment.anchor) |anchor| try std.fmt.allocPrint(a, "native #{d} / segment link", .{anchor.frame}) else "native anchor unproved", .reason = segment.reason, .segment = segment_index, .frame = null });
            for (segment.frames, 0..) |frame, frame_index| {
                if (count == 64 or rows.items.len == 128) {
                    self.message = "LanguageFrameLimit";
                    break;
                }
                try rows.append(a, .{ .name = frame.name, .location = if (frame.file) |file|
                    if (frame.line) |line| try std.fmt.allocPrint(a, "{s}:{d}", .{ std.fs.path.basename(file), line }) else std.fs.path.basename(file)
                else
                    "source position unproved", .reason = frame.reason, .segment = segment_index, .frame = frame_index });
                count += 1;
            }
        }
        self.rows = try rows.toOwnedSlice(a);
    }
    pub fn refresh(self: *Panel, session: *Session, tid: i32, frame: usize) void {
        const tab = session.language_tabs.selected;
        if (@intFromEnum(tab) < 2) return;
        const key = Key{ .session = session.id, .generation = session.target.snapshot().generation, .revision = session.language_tabs.revision, .metadata = session.metadata.revision, .tid = tid, .frame = frame, .tab = tab };
        if (self.key) |previous| if (std.meta.eql(previous, key)) return;
        if (self.key == null or self.key.?.generation != key.generation or self.key.?.tab != tab or self.key.?.tid != tid) self.scroll = 0;
        self.key = key;
        self.stack_basis = null;
        _ = self.arena.reset(.retain_capacity);
        self.rows = &.{};
        self.message = "No stopped thread";
        if (session.target.snapshot().state != .stopped or tid == 0) return;
        const a = self.arena.allocator();
        switch (tab) {
            .python => self.collect(@import("../language/python.zig").stack(session, a, tid, 0) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .perl => self.collect(@import("../language/perl.zig").stack(session, a, tid, 0) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .lua => self.collect(@import("../language/lua.zig").stack(session, a, tid, 0, null) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            .javascript => self.collect(@import("../language/javascript.zig").stack(session, a, tid, 0) catch |err| {
                self.message = @errorName(err);
                return;
            }) catch {
                self.message = "OutOfMemory";
            },
            else => unreachable,
        }
    }
    fn wrapped(r: *gpu.Renderer, font: *Font, rect: gpu.Rect, y: *f32, text: []const u8, color: gpu.Color) !void {
        var remaining = text;
        for (0..3) |_| {
            if (remaining.len == 0 or y.* + 20 > rect.y + rect.h - 8) break;
            var end = remaining.len;
            while (end > 0 and r.measure(font, remaining[0..end]) > rect.w - 24) {
                const space = std.mem.lastIndexOfScalar(u8, remaining[0..end], ' ') orelse break;
                end = space;
            }
            if (end == 0) end = remaining.len;
            try r.textFit(font, rect.x + 12, y.*, rect.w - 24, remaining[0..end], color);
            y.* += 23;
            remaining = std.mem.trimStart(u8, remaining[end..], " ");
        }
    }
    fn explanation(reason: []const u8) []const u8 {
        if (std.mem.eql(u8, reason, "LuaStateArgumentUnavailable")) return "No Lua state at this native frame";
        if (std.mem.eql(u8, reason, "JavaScriptNativeAnchorUnavailable")) return "No JavaScript anchor at this stop";
        if (std.mem.eql(u8, reason, "PerlInterpreterUnavailable")) return "No Perl interpreter at this native frame";
        return reason;
    }
    fn basisText(basis: []const u8) []const u8 {
        if (std.mem.eql(u8, basis, "postmortem-metadata")) return "postmortem metadata";
        if (std.mem.eql(u8, basis, "version-table")) return "version table";
        if (std.mem.eql(u8, basis, "version-table+dwarf-crosscheck")) return "version table + DWARF checks";
        return basis;
    }
    pub fn body(self: *Panel, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, session: *Session, tid: i32, frame: usize) !void {
        self.row_hits = @splat(null);
        const logical = session.language_tabs.logical_selection;
        const logical_tid = if (logical) |selected| if (selected.generation == session.target.snapshot().generation and selected.language == session.language_tabs.selected) selected.tid else tid else tid;
        self.refresh(session, logical_tid, frame);
        const state = &session.language_tabs;
        const entry = &state.entries[@intFromEnum(state.selected) - 2];
        var y = self.content_y;
        try r.textFit(font, rect.x + 12, y, rect.w - 24, entry.version.slice(), theme.neutral);
        y += 23;
        try wrapped(r, font, rect, &y, basisText(self.stack_basis orelse entry.basis.slice()), theme.weak);
        if (entry.proof_generation == null or entry.proof_generation.? != session.target.snapshot().generation or entry.reason != null) {
            try r.textFit(font, rect.x + 12, y, rect.w - 24, entry.reason orelse "Runtime proof pending for this stop", theme.warm);
            y += 23;
        }
        try wrapped(r, font, rect, &y, explanation(self.message), theme.weak);
        y += 7;
        if (logical) |selected| {
            if (selected.native_anchor == null) try wrapped(r, font, rect, &y, "Selected logical row has no proved native anchor", theme.warm);
        }
        if (logical) |current| {
            const key = SelectedKey{ .generation = current.generation, .tid = current.tid, .language = current.language, .segment = current.segment, .frame = current.frame };
            if (self.revealed == null or !std.meta.eql(self.revealed.?, key)) {
                const visible: usize = @intFromFloat(@max(1, @floor((rect.y + rect.h - 8 - y) / 48)));
                for (self.rows, 0..) |row, index| {
                    if (row.segment != current.segment or row.frame == null or row.frame.? != current.frame) continue;
                    if (index < self.scroll) self.scroll = index else if (index >= self.scroll + visible) self.scroll = index -| (visible - 1);
                    break;
                }
                self.revealed = key;
            }
        } else self.revealed = null;
        var hit_count: usize = 0;
        for (self.rows, 0..) |row, index| {
            if (index < self.scroll) continue;
            if (y + 45 > rect.y + rect.h - 8) break;
            const selected = if (logical) |current| current.language == state.selected and current.segment == row.segment and row.frame != null and current.frame == row.frame.? else false;
            const bounds = gpu.Rect{ .x = rect.x + 4, .y = y - 3, .w = rect.w - 8, .h = 47 };
            if (selected) try style.focus(r, bounds, 4, 1);
            if (row.frame) |frame_index| {
                self.row_hits[hit_count] = .{ .rect = bounds, .segment = row.segment, .frame = frame_index };
                hit_count += 1;
            }
            try r.textFit(font, rect.x + 12, y, rect.w - 24, row.name, if (row.frame == null) theme.neutral else theme.text);
            try r.textFit(font, rect.x + 12, y + 21, rect.w - 24, row.location, theme.weak);
            y += 48;
            if (selected and row.reason != null) try wrapped(r, font, rect, &y, explanation(row.reason.?), theme.warm);
        }
    }
};
