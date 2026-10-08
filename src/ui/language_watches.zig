//! Presentation of the shared C comparison model; drawing never reads a target.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Session = @import("../model/session.zig").Session;
const style = @import("style.zig");
const theme = style.theme;
pub const Panel = struct {
    selected: ?u64 = null,
    scroll: usize = 0,
    reveal: bool = false,
    hits: [16]?struct { id: u64, rect: gpu.Rect } = @splat(null),
    pub fn scrollBy(self: *Panel, amount: i32) void {
        const n: usize = @intCast(@abs(@as(i64, amount)));
        if (amount < 0) self.scroll -|= n else self.scroll = @min(15, self.scroll +| n);
    }
    pub fn click(self: *Panel, x: f32, y: f32) void {
        for (self.hits) |maybe| if (maybe) |hit| {
            if (x >= hit.rect.x and x < hit.rect.x + hit.rect.w and y >= hit.rect.y and y < hit.rect.y + hit.rect.h) self.selected = hit.id;
        };
    }
    pub fn key(self: *Panel, session: *Session, code: u32) !bool {
        if (code == 26 or code == 27) {
            self.scrollBy(if (code == 26) -1 else 1);
            return true;
        }
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const entries = try session.language_watches.list(arena.allocator());
        const index = for (entries, 0..) |entry, i| {
            if (self.selected != null and entry.id == self.selected.?) break i;
        } else return false;
        if (code == 111 or code == 14) {
            try session.language_watches.remove(entries[index].id);
            self.selected = null;
            session.record(.human, "remove_language_watch");
            return true;
        }
        if (code == 103 or code == 108) {
            const next = if (code == 103) index -| 1 else @min(index + 1, entries.len - 1);
            self.selected = entries[next].id;
            self.scroll = next;
            return true;
        }
        return code == 17 or code == 28;
    }
    pub fn draw(self: *Panel, session: *Session, r: *gpu.Renderer, font: *Font, rect: gpu.Rect) !void {
        self.hits = @splat(null);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const entries = try session.language_watches.list(a);
        var y = rect.y + 8;
        if (entries.len == 0) {
            try r.textFit(font, rect.x + 12, y, rect.w - 24, "Click a named Lua/Python binding, then W; Shift+E adds a name watch", theme.weak);
            return;
        }
        if (self.reveal and self.selected != null) {
            for (entries, 0..) |entry, index| if (entry.id == self.selected.?) {
                self.scroll = index;
                break;
            };
            self.reveal = false;
        }
        self.scroll = @min(self.scroll, entries.len - 1);
        for (entries[self.scroll..], self.scroll..) |entry, index| {
            if (y + 65 > rect.y + rect.h - 6) break;
            const bounds = gpu.Rect{ .x = rect.x + 4, .y = y - 3, .w = rect.w - 8, .h = 68 };
            self.hits[index] = .{ .id = entry.id, .rect = bounds };
            if (self.selected != null and self.selected.? == entry.id) try style.focus(r, bounds, 4, 1);
            // Put the identity caveat before the possibly long expression so
            // textFit cannot truncate it at the moment a difference appears.
            const title = try std.fmt.allocPrint(a, "{s} {s}: {s} [{s}]", .{ if (entry.comparison == .same_slot_different) "DIFF (activation unproved)" else @tagName(entry.state), @tagName(entry.language), entry.expression, @tagName(entry.selector) });
            try r.textFit(font, rect.x + 12, y, rect.w - 24, title, if (entry.changed) theme.warm else theme.neutral);
            y += 22;
            const current = if (entry.current) |v| v.display else "No complete value";
            const first = if (entry.state == .value) try std.fmt.allocPrint(a, "now: {s}", .{current}) else try std.fmt.allocPrint(a, "{s}; last: {s}", .{ entry.diagnostic orelse @tagName(entry.state), current });
            try r.textFit(font, rect.x + 12, y, rect.w - 24, first, theme.text);
            y += 22;
            const second = if (entry.changed and entry.previous != null) try std.fmt.allocPrint(a, "before (stop {d}): {s}", .{ entry.previous.?.generation, entry.previous.?.display }) else "Compared at stops; frame lifetime between stops unproved";
            try r.textFit(font, rect.x + 12, y, rect.w - 24, second, theme.weak);
            y += 27;
        }
    }
};
