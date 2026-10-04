//! Read-only allocation inspection over the common evidence owner. The panel
//! retains copied rows and identities, never a target or capture pointer.
const std = @import("std");
const model = @import("../profile/allocation_capture.zig");
const events = @import("../profile/allocation_events.zig");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const Mode = enum { calls, lifetimes, outstanding, events, heap };
pub const Row = union(enum) { call: model.SpanRow, lifetime: model.LifetimeRow, event: model.RecordRow };
const a = std.heap.page_allocator;
const max_rows = 64;
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
    rows: [max_rows]Row = undefined,
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
    pub fn cycleThread(self: *Panel, capture: *const model.Capture) void {
        var next: ?u64 = null;
        if (self.filter.thread_id) |id| {
            for (capture.threads[0..capture.thread_count], 0..) |thread, i| if (thread.id == id) {
                if (i + 1 < capture.thread_count) next = capture.threads[i + 1].id;
                break;
            };
        } else next = capture.threads[0].id;
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
    pub fn key(self: *Panel, capture: ?*model.Capture, event: keys.Event) bool {
        if (!self.open) return false;
        if (!event.plain() or (event.kind != .press and event.kind != .repeat)) return true;
        switch (event.shortcut) {
            keys.sym.up, 'k' => self.wheel(-1),
            keys.sym.down, 'j' => self.wheel(1),
            0xff55 => self.back(),
            0xff56 => self.forward(),
            keys.sym.space, 0xffc2, 0xffc3 => return false,
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
                't' => if (capture) |current| self.cycleThread(current),
                'r' => if (capture) |current| {
                    current.requestAnalysis(true) catch |err| {
                        self.message = @errorName(err);
                    };
                    self.dirty = true;
                },
                else => {},
            },
        }
        return true;
    }
    pub fn press(self: *Panel, capture: ?*model.Capture, x: f32, y: f32) void {
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
                0 => if (capture) |current| self.cycleThread(current),
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
    pub fn refresh(self: *Panel, capture: *model.Capture, wanted: usize) void {
        capture.poll();
        if (self.key_) |old| {
            if (!std.meta.eql(old.identity, capture.identity)) {
                self.resetPage();
                self.filter = .{};
            }
        } else self.resetPage();
        if (capture.ended_ns != null) capture.requestAnalysis(false) catch {};
        const current = capture.key();
        const limit = @min(max_rows, @max(1, wanted));
        if (!self.dirty and self.key_ != null and std.meta.eql(self.key_.?, current) and self.built_state == capture.state and self.built_count == limit) return;
        self.key_ = current;
        self.built_state = capture.state;
        self.built_count = limit;
        self.dirty = false;
        self.count = 0;
        self.next = null;
        self.message = "";
        self.scanned = 0;
        self.total = 0;
        var filter = self.filter;
        filter.outstanding_only = self.mode == .outstanding;
        switch (self.mode) {
            .heap => {},
            .calls => {
                const page = capture.spanPage(a, current, filter, self.start, limit) catch |err| {
                    self.message = @errorName(err);
                    return;
                };
                defer a.free(page.rows);
                for (page.rows, 0..) |row, i| self.rows[i] = .{ .call = row };
                self.count = page.rows.len;
                self.next = page.next;
                self.scanned = page.scanned;
                self.total = page.total_unfiltered;
            },
            .events => {
                const page = capture.recordPage(a, current, filter, self.start, limit) catch |err| {
                    self.message = @errorName(err);
                    return;
                };
                defer a.free(page.rows);
                for (page.rows, 0..) |row, i| self.rows[i] = .{ .event = row };
                self.count = page.rows.len;
                self.next = page.next;
                self.scanned = page.scanned;
                self.total = page.total_unfiltered;
            },
            .lifetimes, .outstanding => {
                const page = capture.lifetimePage(a, current, filter, self.start, limit) catch |err| {
                    self.message = @errorName(err);
                    return;
                };
                defer a.free(page.rows);
                for (page.rows, 0..) |row, i| self.rows[i] = .{ .lifetime = row };
                self.count = page.rows.len;
                self.next = page.next;
                self.scanned = page.scanned;
                self.total = page.total_unfiltered;
            },
        }
        self.selected = @min(self.selected, self.count -| 1);
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
    fn drawHeap(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect, capture: *model.Capture) !void {
        self.heap_count = 0;
        self.heap_pending = false;
        const maybe = capture.heapView(self.filter, self.metric, .gui) catch |err| {
            try r.textFit(font, b.x + 12, b.y + 160, b.w - 24, @errorName(err), theme.warm);
            return;
        };
        const view = maybe orelse {
            self.heap_pending = true;
            try r.textFit(font, b.x + 12, b.y + 160, b.w - 24, "Building allocation call tree", theme.weak);
            return;
        };
        const graph = &view.graph;
        if (self.zoom >= graph.nodes.items.len) self.zoom = 0;
        const root = graph.nodes.items[self.zoom];
        var buffer: [512]u8 = undefined;
        try r.textFit(font, b.x + 12, b.y + 157, b.w - 24, try std.fmt.bufPrint(&buffer, "M metric: {s} / {d} total / {d} excluded / {d} allocations missing caller stacks", .{ switch (self.metric) {
            .allocated_bytes => "Allocated bytes",
            .outstanding_bytes => "Outstanding bytes",
            .allocations => "Allocation count",
        }, graph.nodes.items[0].inclusive, view.excluded_weight, view.missing_stacks }), theme.text);
        const bounds = gpu.Rect{ .x = b.x + 12, .y = b.y + 184, .w = b.w - 24, .h = @max(0, b.h - 228) };
        if (root.inclusive == 0) {
            try r.textFit(font, bounds.x, bounds.y, bounds.w, "No positive weight for this metric and filter", theme.weak);
            return;
        }
        const scale = bounds.w / @as(f32, @floatFromInt(root.inclusive));
        for (graph.nodes.items) |node| {
            if (node.depth < root.depth or node.inclusive == 0 or node.x < root.x or node.x - root.x >= root.inclusive) continue;
            var ancestor: ?u32 = node.id;
            while (ancestor != null and ancestor.? != self.zoom) ancestor = graph.nodes.items[ancestor.?].parent;
            if (ancestor == null) continue;
            const depth = node.depth - root.depth;
            if (depth < self.heap_scroll) continue;
            const y = bounds.y + @as(f32, @floatFromInt(depth - self.heap_scroll)) * 24;
            if (y + 23 > bounds.y + bounds.h) continue;
            const rect = gpu.Rect{ .x = bounds.x + @as(f32, @floatFromInt(node.x - root.x)) * scale, .y = y, .w = @max(0, @as(f32, @floatFromInt(node.inclusive)) * scale - 1), .h = 23 };
            if (rect.w < 1) continue;
            const fill = switch (node.frame.kind) {
                .root, .thread => theme.flame_root,
                .incomplete, .unknown, .unverified => theme.flame_unknown,
                .code => style.mix(theme.flame_low, theme.flame_high, @as(f32, @floatFromInt(std.hash.Wyhash.hash(0, node.frame.name) % 100)) / 100),
            };
            try r.rect(rect, fill);
            if (rect.w > 20) try r.textFit(font, rect.x + 4, rect.y + 2, rect.w - 8, node.frame.name, theme.flame_text);
            if (self.heap_count < self.heap_hits.len) {
                self.heap_hits[self.heap_count] = .{ .rect = rect, .node = node.id };
                self.heap_count += 1;
            }
        }
        try r.textFit(font, b.x + 12, b.y + b.h - 30, b.w - 24, try std.fmt.bufPrint(&buffer, "Click to zoom; Back resets. {s}: {d}. Outstanding is not proof of a leak.", .{ root.frame.name, root.inclusive }), theme.weak);
    }
    pub fn drawLive(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, live: *@import("../profile/allocation_live.zig").Live, tid: i32) !void {
        if (!self.open) return;
        try self.draw(r, font, width, height, live.capture);
        const b = gpu.Rect{ .x = 20, .y = 60, .w = @max(0, width - 40), .h = 36 };
        try style.box(r, b, theme.surface, theme.focus, @splat(6));
        var buffer: [256]u8 = undefined;
        const archived = if (live.capture) |capture| capture.archived else false;
        const message = if (archived) "Offline allocation evidence; S saves a copy" else if (live.failure != null and live.failure.?.kind == .permission) "Permission denied; see docs/ALLOCATIONS.md" else if (live.err) |err| @errorName(err) else if (live.preparing()) "Preparing probes; keep target paused" else if (live.collecting() and live.reason != null) "Stopping capture; releasing probes" else if (live.collecting()) "Tracing selected threads; Space continues/pauses" else if (live.reason) |reason| try std.fmt.bufPrint(&buffer, "Capture stopped: {s}; next start selects TID {d}", .{ @tagName(reason), tid }) else try std.fmt.bufPrint(&buffer, "Start on stopped TID {d}: malloc/calloc/realloc/free", .{tid});
        try r.textFit(font, b.x + 10, b.y + 9, b.w - 190, message, if (live.err != null) theme.warm else theme.text);
        if (archived) return;
        try style.button(r, font, liveButton(width), if (live.preparing()) "Cancel" else if (live.collecting()) "Stop capture" else "Start capture", "P", theme.focus, 0, 0);
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, current: ?*model.Capture) !void {
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
        const capture = current orelse {
            self.count = 0;
            self.next = null;
            self.key_ = null;
            self.filter = .{};
            self.resetPage();
            try r.textFit(font, b.x + 12, b.y + 84, b.w - 24, "No allocation capture in this process.", theme.weak);
            return;
        };
        const wanted: usize = @intFromFloat(@min(max_rows, @max(1, (b.h - 254) / 22)));
        self.refresh(capture, wanted);
        try r.textFit(font, b.x + 12, b.y + 74, b.w - 24, try std.fmt.bufPrint(&buffer, "Process #{d} / PID {d} / capture #{d} / {s} / {d} selected threads, {d} hooks", .{ capture.identity.process_id, capture.identity.pid, capture.identity.capture_id, @tagName(capture.state), capture.thread_count, capture.hook_count }), theme.weak);
        const summary = if (capture.summary()) |s| try std.fmt.bufPrint(&buffer, "Whole capture: {d} outstanding / {d} requested bytes / {d} successful allocations", .{ s.outstanding_count, s.outstanding_bytes, s.successful_allocations }) else if (capture.store.first_gap) |gap| try std.fmt.bufPrint(&buffer, "Lifetime totals unavailable: {s}; lost {d}, rejected {d}, unread {s}", .{ @tagName(gap.reason), capture.store.lost, capture.store.rejected, if (capture.store.unread_possible) "possible" else "no" }) else if (capture.failure) |err| try std.fmt.bufPrint(&buffer, "Analysis failed: {s}. Retained calls remain available; R retries.", .{@errorName(err)}) else if (capture.state == .analyzing) "Building lifetime analysis; retained evidence is available" else if (capture.state == .stopping) "Waiting for source cleanup and the final capture boundary" else "Lifetime totals become available after collection ends";
        try r.textFit(font, b.x + 12, b.y + 96, b.w - 24, summary, if (capture.store.first_gap != null or capture.failure != null) theme.warm else theme.text);
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
            try self.drawHeap(r, font, b, capture);
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
