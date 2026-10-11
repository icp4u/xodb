//! Read-only allocation inspection over the common evidence owner. The panel
//! retains copied rows and identities, never a target or capture pointer.
const std = @import("std");
const model = @import("../profile/allocation_capture.zig");
const display = @import("../model/allocation_view.zig");
const events = @import("../profile/allocation_events.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const Mode = display.Mode;
pub const Row = display.Row;
const a = std.heap.page_allocator;
const max_rows = display.max_rows;
pub const Input = union(enum) { unhandled, local, owner: display.Action };
fn inside(b: gpu.Rect, x: f32, y: f32) bool {
    return x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
}
pub const Panel = struct {
    open: bool = false,
    mode: Mode = .calls,
    filter: model.Filter = .{},
    start: usize = 0,
    next: ?usize = null,
    selected: usize = 0,
    count: usize = 0,
    scanned: usize = 0,
    total: usize = 0,
    rows: []const Row = &.{},
    view: display.View = .{},
    wanted: usize = max_rows,
    history: std.ArrayList(u32) = .empty,
    key_: ?model.Key = null,
    built_state: ?model.State = null,
    built_count: usize = 0,
    dirty: bool = true,
    message: []const u8 = "",
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    list: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    tabs: [5]gpu.Rect = undefined,
    metric: @import("../profile/allocation_heap.zig").Metric = .allocated_bytes,
    zoom: u32 = 0,
    heap_scroll: u16 = 0,
    heap_hits: [512]struct { rect: gpu.Rect, node: u32 } = undefined,
    heap_count: usize = 0,
    heap_pending: bool = false,
    controls: [3]gpu.Rect = undefined,
    ready_hits: bool = false,
    pub fn deinit(self: *Panel) void {
        self.history.deinit(a);
    }
    pub fn show(self: *Panel) void {
        self.open = true;
        self.dirty = true;
    }
    fn resetPage(self: *Panel) void {
        self.start = 0;
        self.zoom = 0;
        self.heap_scroll = 0;
        self.heap_count = 0;
        self.next = null;
        self.selected = 0;
        self.history.clearRetainingCapacity();
        self.dirty = true;
    }
    pub fn setMode(self: *Panel, mode: Mode) void {
        self.mode = mode;
        self.resetPage();
    }
    pub fn setFilter(self: *Panel, filter: model.Filter) void {
        self.filter = filter;
        self.filter.outstanding_only = false;
        self.resetPage();
    }
    pub fn cycleThread(self: *Panel) void {
        var next: ?u64 = null;
        if (self.filter.thread_id) |id| {
            for (self.view.threads, 0..) |thread, i| if (thread.id == id) {
                if (i + 1 < self.view.threads.len) next = self.view.threads[i + 1].id;
                break;
            };
        } else if (self.view.threads.len > 0) next = self.view.threads[0].id;
        var filter = self.filter;
        filter.thread_id = next;
        self.setFilter(filter);
    }
    pub fn forward(self: *Panel) void {
        const next = self.next orelse return;
        if (next <= self.start or self.history.items.len >= events.max_records) return;
        if (self.history.items.len == self.history.capacity) self.history.ensureTotalCapacityPrecise(a, @min(events.max_records, @max(64, self.history.capacity * 2))) catch {
            self.message = "Navigation memory unavailable";
            return;
        };
        self.history.appendAssumeCapacity(@intCast(self.start));
        self.start = next;
        self.selected = 0;
        self.dirty = true;
    }
    pub fn back(self: *Panel) void {
        if (self.mode == .heap) {
            self.zoom = 0;
            self.heap_scroll = 0;
            return;
        }
        if (self.history.items.len == 0) return;
        self.start = self.history.pop().?;
        self.selected = 0;
        self.dirty = true;
    }
    pub fn wheel(self: *Panel, delta: i32) void {
        if (self.mode == .heap) {
            self.heap_scroll = @intCast(std.math.clamp(@as(i32, self.heap_scroll) + delta, 0, 32));
            return;
        }
        if (delta > 0) {
            if (self.selected + @as(usize, @intCast(delta)) < self.count) self.selected += @intCast(delta) else self.forward();
        } else if (delta < 0) {
            const amount: usize = @intCast(-@as(i64, delta));
            if (self.selected >= amount) self.selected -= amount else self.back();
        }
    }
    pub fn key(self: *Panel, event: keys.Event) Input {
        if (!self.open) return .unhandled;
        if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return .local;
        switch (event.shortcut) {
            keys.sym.up, 'k' => self.wheel(-1),
            keys.sym.down, 'j' => self.wheel(1),
            0xff55 => self.back(),
            0xff56 => self.forward(),
            keys.sym.space, 0xffc2, 0xffc3 => return .unhandled,
            else => if (event.kind == .press) switch (event.shortcut) {
                keys.sym.escape => self.open = false,
                'c' => self.setMode(.calls),
                'l' => self.setMode(.lifetimes),
                'o' => self.setMode(.outstanding),
                'e' => self.setMode(.events),
                'f' => self.setMode(.heap),
                'm' => if (self.mode == .heap) {
                    self.metric = @enumFromInt((@as(u32, @intFromEnum(self.metric)) + 1) % 3);
                    self.resetPage();
                },
                0xff09 => self.setMode(@enumFromInt((@as(u32, @intFromEnum(self.mode)) + 1) % 5)),
                't' => self.cycleThread(),
                'r' => if (self.key_) |identity| return .{ .owner = .{ .retry = identity } },
                else => {},
            },
        }
        return .local;
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        if (!self.open) return;
        if (!inside(self.bounds, x, y)) {
            self.open = false;
            return;
        }
        if (!self.ready_hits) return;
        for (self.tabs, 0..) |rect, i| if (inside(rect, x, y)) {
            self.setMode(@enumFromInt(i));
            return;
        };
        for (self.controls, 0..) |rect, i| if (inside(rect, x, y)) {
            switch (i) {
                0 => self.cycleThread(),
                1 => self.back(),
                2 => if (self.mode == .heap) {
                    self.metric = @enumFromInt((@as(u32, @intFromEnum(self.metric)) + 1) % 3);
                    self.resetPage();
                } else self.forward(),
                else => unreachable,
            }
            return;
        };
        if (self.mode == .heap) {
            for (self.heap_hits[0..self.heap_count]) |hit| if (inside(hit.rect, x, y)) {
                self.zoom = hit.node;
                self.heap_scroll = 0;
                return;
            };
            return;
        }
        if (inside(self.list, x, y)) {
            const row: usize = @intFromFloat((y - self.list.y) / 22);
            if (row < self.count) self.selected = row;
        }
    }
    pub fn request(self: *Panel, height: f32) ?display.Request {
        self.wanted = @intFromFloat(@min(max_rows, @max(1, (height - 390) / 22)));
        if (!self.open) return null;
        return self.currentRequest();
    }
    fn currentRequest(self: *const Panel) display.Request {
        return .{ .identity = if (self.key_) |id| id.identity else null, .mode = self.mode, .filter = self.filter, .start = self.start, .limit = self.wanted, .metric = self.metric };
    }
    pub fn present(self: *Panel, view: display.View) void {
        self.view = .{};
        self.rows = &.{};
        self.count = 0;
        self.next = null;
        self.ready_hits = false;
        self.message = "";
        self.heap_count = 0;
        self.heap_pending = false;
        const incoming = view.request orelse {
            self.view = .{};
            self.rows = &.{};
            self.count = 0;
            self.heap_count = 0;
            return;
        };
        // A result for an earlier tab/page never repaints the new selection.
        if (incoming.mode != self.mode or incoming.metric != self.metric or incoming.limit != self.wanted) return;
        if (view.key) |identity| {
            if (self.key_ == null or !std.meta.eql(self.key_.?.identity, identity.identity)) {
                self.resetPage();
                self.filter = .{};
                self.key_ = identity;
            }
            if (!std.meta.eql(incoming, self.currentRequest())) return;
        } else {
            self.resetPage();
            self.filter = .{};
        }
        self.view = view;
        self.rows = view.rows;
        self.key_ = view.key;
        self.built_state = view.state;
        self.built_count = incoming.limit;
        self.count = view.rows.len;
        self.next = view.next;
        self.scanned = view.scanned;
        self.total = view.total;
        self.heap_pending = view.heap_pending;
        self.message = view.diagnostic;
        self.selected = @min(self.selected, self.count -| 1);
        self.dirty = false;
    }
    fn current(self: *const Panel) bool {
        return if (self.view.request) |value| std.meta.eql(value, self.currentRequest()) else false;
    }
    pub fn selectedOrdinal(self: *const Panel) ?u32 {
        if (self.count == 0 or self.selected >= self.count) return null;
        return switch (self.rows[self.selected]) {
            inline else => |row| row.ordinal,
        };
    }
    fn line(row: Row, buffer: []u8) ![]const u8 {
        return switch (row) {
            .call => |call| blk: {
                const event = if (call.entry) |entry| entry.event else call.returned.?.event;
                const sample = event.data.sample;
                break :blk std.fmt.bufPrint(buffer, "#{d}  TID {d}  {s}  {s}  entry {any} / return {any}{s}", .{ call.ordinal, call.thread.tid, @tagName(sample.kind), @tagName(call.reason), if (call.entry) |entry| @as(?u32, entry.ordinal) else null, if (call.returned) |ret| @as(?u32, ret.ordinal) else null, if (call.parent != null) "  nested" else "" });
            },
            .lifetime => |row_| std.fmt.bufPrint(buffer, "#{d}  TID {d}  0x{x}  {d} bytes  {s}", .{ row_.ordinal, row_.allocation_thread.tid, row_.pointer, row_.requested_bytes, @tagName(row_.state) }),
            .event => |row_| if (row_.event.data == .sample) std.fmt.bufPrint(buffer, "#{d}  TID {d}  {s} {s}  hook {d}  time {d}", .{ row_.ordinal, row_.thread.tid, @tagName(row_.event.data.sample.kind), @tagName(row_.event.data.sample.phase), row_.event.data.sample.hook, row_.event.time_ns }) else std.fmt.bufPrint(buffer, "#{d}  TID {d}  {s}  time {d}", .{ row_.ordinal, row_.thread.tid, @tagName(row_.event.data), row_.event.time_ns }),
        };
    }
    fn detail(row: Row, second: bool, buffer: []u8) ![]const u8 {
        return switch (row) {
            .call => |call| if (second) std.fmt.bufPrint(buffer, "Pairing: {s}; parent call {any}. Event IDs cite retained evidence.", .{ @tagName(call.reason), call.parent }) else blk: {
                const entry = if (call.entry) |v| v.event.data.sample else null;
                const ret = if (call.returned) |v| v.event.data.sample else null;
                break :blk std.fmt.bufPrint(buffer, "Call #{d}: arg0 0x{?x} / arg1 0x{?x} / return bits 0x{?x}", .{ call.ordinal, if (entry) |v| @as(?u64, v.arg0) else null, if (entry) |v| @as(?u64, v.arg1) else null, if (ret) |v| @as(?u64, v.result) else null });
            },
            .lifetime => |v| if (second) std.fmt.bufPrint(buffer, "Observed lifetime bounds: min {any} ns / max {any} ns. Filters select allocation origin.", .{ v.min_ns, v.max_ns }) else std.fmt.bufPrint(buffer, "Lifetime #{d}: allocation call #{d} / release call {any} / {s}", .{ v.ordinal, v.allocation_span, v.release_span, @tagName(v.state) }),
            .event => |v| if (v.event.data == .sample) blk: {
                const s = v.event.data.sample;
                break :blk if (second) std.fmt.bufPrint(buffer, "stack key 0x{x} / IP 0x{x} / hook {d}", .{ s.stack_key, s.ip, s.hook }) else std.fmt.bufPrint(buffer, "Event #{d}: arg0 0x{x} / arg1 0x{x} / result 0x{x}", .{ v.ordinal, s.arg0, s.arg1, s.result });
            } else std.fmt.bufPrint(buffer, "Event #{d}: {s}{s}", .{ v.ordinal, @tagName(v.event.data), if (second) "; incomplete evidence cannot establish lifetime totals" else "" }),
        };
    }
    pub fn liveButton(width: f32) gpu.Rect {
        return .{ .x = @max(20, width - 190), .y = 64, .w = 170, .h = 28 };
    }
    pub fn liveHit(width: f32, x: f32, y: f32) bool {
        return inside(liveButton(width), x, y);
    }
    fn drawHeap(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        self.heap_count = 0;
        if (self.view.diagnostic.len > 0) {
            try r.textFit(font, b.x + 12, b.y + 160, b.w - 24, self.view.diagnostic, theme.warm);
            return;
        }
        const view = self.view.heap orelse {
            try r.textFit(font, b.x + 12, b.y + 160, b.w - 24, "Building allocation call tree", theme.weak);
            return;
        };
        if (view.nodes.len == 0) return;
        if (self.zoom >= view.nodes.len) self.zoom = 0;
        const root = view.nodes[self.zoom];
        var buffer: [512]u8 = undefined;
        try r.textFit(font, b.x + 12, b.y + 157, b.w - 24, try std.fmt.bufPrint(&buffer, "M metric: {s} / {d} total / {d} excluded / {d} allocations missing caller stacks", .{ switch (self.metric) {
            .allocated_bytes => "Allocated bytes",
            .outstanding_bytes => "Outstanding bytes",
            .allocations => "Allocation count",
        }, view.nodes[0].inclusive, view.excluded_weight, view.missing_stacks }), theme.text);
        const bounds = gpu.Rect{ .x = b.x + 12, .y = b.y + 184, .w = b.w - 24, .h = @max(0, b.h - 228) };
        if (root.inclusive == 0) {
            try r.textFit(font, bounds.x, bounds.y, bounds.w, "No positive weight for this metric and filter", theme.weak);
            return;
        }
        const scale = bounds.w / @as(f32, @floatFromInt(root.inclusive));
        for (view.nodes) |node| {
            if (node.depth < root.depth or node.inclusive == 0 or node.x < root.x or node.x - root.x >= root.inclusive) continue;
            var ancestor: ?u32 = node.id;
            while (ancestor != null and ancestor.? != self.zoom) ancestor = view.nodes[ancestor.?].parent;
            if (ancestor == null) continue;
            const depth = node.depth - root.depth;
            if (depth < self.heap_scroll) continue;
            const y = bounds.y + @as(f32, @floatFromInt(depth - self.heap_scroll)) * 24;
            if (y + 23 > bounds.y + bounds.h) continue;
            const rect = gpu.Rect{ .x = bounds.x + @as(f32, @floatFromInt(node.x - root.x)) * scale, .y = y, .w = @max(0, @as(f32, @floatFromInt(node.inclusive)) * scale - 1), .h = 23 };
            if (rect.w < 1) continue;
            const fill = switch (node.kind) {
                .root, .thread => theme.flame_root,
                .incomplete, .unknown, .unverified => theme.flame_unknown,
                .code => style.mix(theme.flame_low, theme.flame_high, @as(f32, @floatFromInt(node.color)) / 100),
            };
            try r.rect(rect, fill);
            if (rect.w > 20) try r.textFit(font, rect.x + 4, rect.y + 2, rect.w - 8, node.name, theme.flame_text);
            if (self.heap_count < self.heap_hits.len) {
                self.heap_hits[self.heap_count] = .{ .rect = rect, .node = node.id };
                self.heap_count += 1;
            }
        }
        try r.textFit(font, b.x + 12, b.y + b.h - 30, b.w - 24, try std.fmt.bufPrint(&buffer, "Click to zoom; Back resets. {s}: {d}. Outstanding is not proof of a leak.", .{ root.name, root.inclusive }), theme.weak);
    }
    pub fn drawLive(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        try self.draw(r, font, width, height);
        const b = gpu.Rect{ .x = 20, .y = 60, .w = @max(0, width - 40), .h = 36 };
        try style.box(r, b, theme.surface, theme.focus, @splat(6));
        try r.textFit(font, b.x + 10, b.y + 9, b.w - 190, self.view.banner, if (self.view.banner_warning) theme.warm else theme.text);
        if (self.view.archived) return;
        try style.button(r, font, liveButton(width), if (self.view.preparing) "Cancel" else if (self.view.collecting) "Stop capture" else "Start capture", "P", theme.focus, 0, 0);
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.ready_hits = false;
        const b = gpu.Rect{ .x = 20, .y = 96, .w = @max(0, width - 40), .h = @max(0, height - 136) };
        self.bounds = b;
        const old_clip = r.clip;
        defer r.clip = old_clip;
        r.clip = b;
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        if (b.w < 400 or b.h < 280) {
            try r.textFit(font, b.x + 10, b.y + 10, b.w - 20, "Allocation panel needs a larger window", theme.weak);
            return;
        }
        try r.textFit(font, b.x + 12, b.y + 10, b.w - 24, "ALLOCATIONS   Esc close   C/L/O/E/F views   T thread   S save   R retry analysis", theme.text);
        const tab_width = @min(180, (b.w - 48) / 5);
        const labels = [_][]const u8{ "Calls", "Lifetimes", "Outstanding", "Events", "Flames" };
        const shortcuts = [_][]const u8{ "C", "L", "O", "E", "F" };
        for (labels, 0..) |label, i| {
            const rect = gpu.Rect{ .x = b.x + 12 + @as(f32, @floatFromInt(i)) * (tab_width + 6), .y = b.y + 36, .w = tab_width, .h = 28 };
            self.tabs[i] = rect;
            try style.button(r, font, rect, label, shortcuts[i], if (@intFromEnum(self.mode) == i) theme.focus else theme.weak, 0, 0);
        }
        var buffer: [768]u8 = undefined;
        if (!self.current()) {
            try r.textFit(font, b.x + 12, b.y + 84, b.w - 24, "Preparing allocation view", theme.weak);
            return;
        }
        if (self.view.key == null) {
            try r.textFit(font, b.x + 12, b.y + 84, b.w - 24, "No allocation capture in this process.", theme.weak);
            return;
        }
        const wanted = self.wanted;
        try r.textFit(font, b.x + 12, b.y + 74, b.w - 24, self.view.header, theme.weak);
        try r.textFit(font, b.x + 12, b.y + 96, b.w - 24, self.view.summary, if (self.view.warning) theme.warm else theme.text);
        self.controls = .{
            .{ .x = b.x + 12, .y = b.y + 122, .w = 168, .h = 28 },
            .{ .x = b.x + 188, .y = b.y + 122, .w = 126, .h = 28 },
            .{ .x = b.x + 322, .y = b.y + 122, .w = 126, .h = 28 },
        };
        const thread_label = if (self.filter.thread_id) |id| try std.fmt.bufPrint(&buffer, "Thread #{d}", .{id}) else "All threads";
        try style.button(r, font, self.controls[0], thread_label, "T", theme.text, 0, 0);
        try style.button(r, font, self.controls[1], "Back", "PgUp", if (self.history.items.len > 0 or self.mode == .heap) theme.text else theme.weak, 0, 0);
        try style.button(r, font, self.controls[2], if (self.mode == .heap) "Metric" else "Next", if (self.mode == .heap) "M" else "PgDn", if (self.next != null or self.mode == .heap) theme.text else theme.weak, 0, 0);
        if (self.mode != .heap) try r.textFit(font, b.x + 458, b.y + 127, b.w - 470, try std.fmt.bufPrint(&buffer, "{d} rows / {d} retained / start #{d}", .{ self.count, self.total, self.start }), theme.weak);
        self.list = .{ .x = b.x + 8, .y = b.y + 160, .w = b.w - 16, .h = @as(f32, @floatFromInt(wanted)) * 22 };
        self.ready_hits = true;
        if (self.mode == .heap) {
            try self.drawHeap(r, font, b);
            return;
        }
        for (self.rows[0..self.count], 0..) |row, i| {
            const y = self.list.y + @as(f32, @floatFromInt(i)) * 22;
            if (i == self.selected) try style.focus(r, .{ .x = self.list.x, .y = y - 1, .w = self.list.w, .h = 22 }, 3, 1);
            try r.textFit(font, b.x + 12, y, b.w - 24, try line(row, &buffer), if (i == self.selected) theme.text else theme.weak);
        }
        if (self.count == 0) try r.textFit(font, b.x + 12, self.list.y, b.w - 24, if (self.message.len > 0) self.message else if (self.next != null) "No matches in this chunk; Next searches later evidence" else "No matching rows", theme.weak);
        if (self.count > 0) {
            try r.textFit(font, b.x + 12, b.y + b.h - 80, b.w - 24, try detail(self.rows[self.selected], false, &buffer), theme.text);
            try r.textFit(font, b.x + 12, b.y + b.h - 56, b.w - 24, try detail(self.rows[self.selected], true, &buffer), theme.weak);
        }
        try r.textFit(font, b.x + 12, b.y + b.h - 30, b.w - 24, "Selected scope only; outstanding is not proof of a leak.", theme.weak);
    }
};
