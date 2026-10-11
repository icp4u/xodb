//! Memory and floating-point/vector inspection over the shared target/model.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const memory = @import("../model/memory.zig");
const xstate = @import("../target/xstate.zig");
const prepared = @import("../model/inspection_view.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
pub const Panel = struct {
    open: bool = false,
    kind: prepared.Kind = .memory,
    view: prepared.View = .{},
    request_revision: u64 = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    editor: Editor = .{},
    editing: enum { address, pattern, length } = .address,
    message: []const u8 = "G address/expression  / search (hex: or text:)  P pin baseline",
    address: u64 = 0,
    snapshot: ?u64 = null,
    baseline: ?u64 = null,
    generation: u64 = 0,
    image_epoch: u64 = 0,
    tid: i32 = 0,
    refresh: bool = true,
    search_length: usize = 64 * 1024,
    /// Search every writable private mapping instead of the displayed range.
    all_writable: bool = false,
    hit: usize = 0,
    format: xstate.Format = .f32,
    width: usize = 16,
    row: usize = 0,
    pub fn show(self: *Panel, vectors: bool, address: u64) void {
        self.open = true;
        self.kind = if (vectors) .vectors else .memory;
        self.refresh = true;
        self.editor.open = false;
        self.row = 0;
        if (!vectors) self.address = address;
        self.message = if (vectors) "V lane format  W vector width  Up/Down scroll; values from selected thread" else "G address/expression  / search (hex: or text:)  P pin baseline";
    }
    pub fn busy(self: *const Panel) bool {
        if (!self.open or self.kind != .memory) return false;
        return if (self.view.search) |search| search.state == .running else false;
    }
    pub fn request(self: *Panel, tid: i32) ?prepared.Request {
        if (!self.open) return null;
        if (self.refresh) {
            self.request_revision +%= 1;
            self.refresh = false;
        }
        return .{ .kind = self.kind, .tid = tid, .address = self.address, .baseline = self.baseline, .revision = self.request_revision };
    }
    pub fn present(self: *Panel, view: prepared.View) void {
        self.view = view;
        self.generation = view.observed_generation;
        self.image_epoch = view.image_epoch;
        self.tid = view.tid;
        if (view.request) |wanted| if (wanted.kind == .memory) {
            self.snapshot = if (view.snapshot) |snapshot| snapshot.id else null;
            self.baseline = view.baseline;
        };
        if (view.vector) |vector| self.width = @min(self.width, vector.vector_bytes);
        if (view.diagnostic) |message| self.message = message;
    }
    pub fn wheel(self: *Panel, amount: i32) void {
        if (self.kind == .vectors) {
            self.row = @intCast(@max(0, @min(1024, @as(i64, @intCast(self.row)) + amount)));
            return;
        }
        const delta = @as(i64, amount) * 16;
        self.address = if (delta < 0) self.address -| @as(u64, @intCast(-delta)) else self.address +| @as(u64, @intCast(delta));
        self.refresh = true;
    }
    pub fn press(self: *Panel, x: f32, y: f32) void {
        if (x < self.bounds.x or x > self.bounds.x + self.bounds.w or y < self.bounds.y or y > self.bounds.y + self.bounds.h) self.open = false;
    }
    pub const KeyAction = union(enum) { ignored, local, owner: prepared.Action };
    pub fn key(self: *Panel, session: *Session, tid: i32, frame: usize, event: keys.Event) bool {
        const result = self.keyView(tid, frame, session.metadata.revision, event) catch |err| {
            self.message = @errorName(err);
            return true;
        };
        return switch (result) {
            .ignored => false,
            .local => true,
            .owner => |action| done: {
                const value = prepared.apply(session, .human, action) catch |err| {
                    self.message = @errorName(err);
                    break :done true;
                };
                self.complete(action, value);
                break :done true;
            },
        };
    }
    pub fn keyView(self: *Panel, tid: i32, frame: usize, metadata: u64, event: keys.Event) !KeyAction {
        if (!self.open) return .ignored;
        if (event.kind != .press and event.kind != .repeat) return .local;
        if (self.editor.open) {
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.message = "Edit cancelled",
                .submit => |text| {
                    if (try self.submitView(tid, frame, metadata, text)) |owner_action| return .{ .owner = owner_action };
                    self.editor.open = false;
                },
            } else return .ignored;
            return .local;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return .ignored;
        if (!event.plain()) return .local;
        const k = event.shortcut;
        if (k == keys.sym.escape or k == 'm' or k == 'r') {
            self.open = false;
            return .local;
        }
        if (k == keys.sym.space) return .ignored;
        if (k == keys.sym.up or k == keys.sym.down or k == 0xff55 or k == 0xff56) {
            self.wheel(if (k == keys.sym.up) -1 else if (k == keys.sym.down) 1 else if (k == 0xff55) -16 else 16);
            return .local;
        }
        if (event.kind == .repeat) return .local;
        if (self.kind == .vectors) {
            if (k == 'v') self.format = @enumFromInt((@intFromEnum(self.format) + 1) % 6);
            if (k == 'w') {
                const max = if (self.view.vector) |v| v.vector_bytes else 16;
                self.width = if (self.width >= max) 16 else self.width * 2;
            }
            return .local;
        }
        if (k == 'g' or k == '/' or k == 'l') {
            self.editing = if (k == 'g') .address else if (k == 'l') .length else .pattern;
            self.editor.start();
            self.message = switch (self.editing) {
                .address => "Address (0x...) or native expression, such as &counter",
                .length => std.fmt.comptimePrint("Search length in bytes (1..{d}); search begins at displayed address", .{memory.max_search}),
                .pattern => "Pattern: hex:414241 or text:ABA; N next result, C cancel",
            };
        } else if (k == 'p') {
            return .{ .owner = .{ .pin = self.snapshot } };
        } else if (k == 'n') {
            if (self.view.search) |search| if (search.hits.len > 0) {
                self.hit %= search.hits.len;
                self.address = search.hits[self.hit];
                self.hit = (self.hit + 1) % search.hits.len;
                self.refresh = true;
            };
        } else if (k == 'c') {
            if (self.view.search) |search| if (search.state == .running) return .{ .owner = .{ .cancel = search.id } };
        } else if (k == 'w') {
            self.all_writable = !self.all_writable;
            self.message = if (self.all_writable) "/ now searches all writable private mappings at this stop" else "/ now searches the displayed address and length";
        } else if (k == 'u') {
            return .{ .owner = .{ .pin = null } };
        }
        return .local;
    }
    fn submitView(self: *Panel, tid: i32, frame: usize, metadata: u64, text: []const u8) !?prepared.Action {
        return switch (self.editing) {
            .address => .{ .address = .{ .tid = tid, .frame = frame, .metadata = metadata, .text = text } },
            .length => blk: {
                const length = std.fmt.parseInt(usize, text, 0) catch return error.InvalidMemoryRange;
                if (length == 0 or length > memory.max_search) return error.InvalidMemoryRange;
                self.search_length = length;
                self.message = "Search length updated";
                break :blk null;
            },
            .pattern => .{ .search = .{ .address = self.address, .length = self.search_length, .text = text, .all_writable = self.all_writable } },
        };
    }
    /// Frontend completion for the matching submitted intent. Remote callers
    /// associate this with the command sequence before retiring its request.
    pub fn complete(self: *Panel, action: prepared.Action, result: ?u64) void {
        switch (action) {
            .address => {
                self.address = result orelse return;
                self.refresh = true;
                self.editor.open = false;
                self.message = "Memory address updated";
            },
            .pin => |id| {
                self.baseline = id;
                self.message = if (id != null) "Pinned displayed snapshot; orange bytes differ, blue bytes became readable" else "Baseline cleared";
            },
            .search => {
                self.hit = 0;
                self.editor.open = false;
                self.message = "Searching; N jumps to next result, C cancels";
            },
            .cancel => self.message = "Search cancelled",
        }
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        var buffer: [1024]u8 = undefined;
        const title = try std.fmt.bufPrint(&buffer, "{s}   {s} / Esc close   tid {d}   stop {d}{s}", .{ if (self.kind == .memory) "MEMORY" else "FP / SIMD", if (self.kind == .memory) "M" else "R", self.tid, self.generation, if (self.view.state != .stopped) " (historical: target running)" else "" });
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, title, theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, if (self.kind == .memory) "G address  P pin  U unpin  / find  L length  W all writable  N next  C cancel  PgUp/Down" else "V format  W width  Up/Down scroll  Orange = changed since previous stop", theme.weak);
        if (self.kind == .memory) try self.drawMemory(r, font, b) else try self.drawVectors(r, font, b);
        const y = b.y + b.h - 76;
        if (self.kind == .memory) if (self.view.search) |search| {
            const progress = try std.fmt.bufPrint(&buffer, "Search {s}: {d}/{d} bytes in {d} ranges, {d} unreadable, {d} hits", .{ @tagName(search.state), search.scanned, search.length, search.range_count, search.unreadable, search.hits.len });
            try r.textFit(font, b.x + 14, y - 24, b.w - 28, progress, theme.weak);
        };
        try r.textFit(font, b.x + 14, y, b.w - 28, self.message, theme.text);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = y + 24, .w = b.w - 20, .h = 27 }, theme.background, theme.focus, @splat(3));
            try self.editor.draw(r, font, .{ .x = b.x + 16, .y = y + 28, .w = b.w - 32, .h = 22 });
        } else if (self.kind == .memory) {
            const label = if (self.all_writable)
                try std.fmt.bufPrint(&buffer, "0x{x}   scan all writable   baseline {d}   ?? unreadable", .{ self.address, self.baseline orelse 0 })
            else
                try std.fmt.bufPrint(&buffer, "0x{x}   scan {d} bytes   baseline {d}   ?? unreadable", .{ self.address, self.search_length, self.baseline orelse 0 });
            try r.textFit(font, b.x + 14, y + 28, b.w - 28, label, theme.weak);
        }
    }
    fn drawMemory(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        const snapshot = self.view.snapshot orelse return;
        const columns: usize = if (b.w < 900) 8 else 16;
        const rows: usize = @intFromFloat(@max(1, (b.h - 184) / 22));
        var buffer: [64]u8 = undefined;
        for (0..@min(rows, (snapshot.bytes.len + columns - 1) / columns)) |line| {
            const y = b.y + 66 + @as(f32, @floatFromInt(line)) * 22;
            const start = line * columns;
            try r.text(font, b.x + 14, y, try std.fmt.bufPrint(&buffer, "{x:0>16}", .{snapshot.address + start}), theme.weak);
            var ascii: [16]u8 = @splat(' ');
            for (0..columns) |j| {
                const i = start + j;
                if (i >= snapshot.bytes.len) break;
                const change = snapshot.changes[i];
                const color = if (change == .changed or change == .became_unreadable) theme.warm else if (change == .became_readable) theme.focus else if (!snapshot.valid[i]) theme.weak else theme.text;
                const label = if (snapshot.valid[i]) try std.fmt.bufPrint(&buffer, "{x:0>2}", .{snapshot.bytes[i]}) else "??";
                try r.text(font, b.x + 174 + @as(f32, @floatFromInt(j)) * 27, y, label, color);
                ascii[j] = if (!snapshot.valid[i]) '?' else if (snapshot.bytes[i] >= 32 and snapshot.bytes[i] < 127) snapshot.bytes[i] else '.';
            }
            try r.textFit(font, b.x + 184 + @as(f32, @floatFromInt(columns)) * 27, y, b.w - 198 - @as(f32, @floatFromInt(columns)) * 27, ascii[0..columns], theme.weak);
        }
    }
    fn drawVectors(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        const current = self.view.vector orelse return;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const lane_width: f32 = switch (self.format) {
            .f64 => 248,
            .f32 => 160,
            .hex, .u64 => 200,
            else => 116,
        };
        const perline: usize = @max(1, @as(usize, @intFromFloat((b.w - 110) / lane_width)));
        var lines: usize = 0;
        const visible: usize = @intFromFloat(@max(1, (b.h - 156) / 22));
        for (0..current.vector_count) |i| {
            const lanes = try xstate.lanes(a, current.vectors[i][0..self.width], self.format);
            var start: usize = 0;
            while (start < lanes.len) : (start += perline) {
                defer lines += 1;
                if (lines < self.row or lines >= self.row + visible) continue;
                const y = b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22;
                const prefix = if (start == 0) try std.fmt.allocPrint(a, "{s}{d}", .{ if (self.width == 16) "xmm" else if (self.width == 32) "ymm" else "zmm", i }) else try std.fmt.allocPrint(a, "[{d}]", .{start});
                try r.text(font, b.x + 14, y, prefix, theme.focus);
                const lane_size: usize = if (self.format == .hex or self.format == .f64 or self.format == .u64) 8 else 4;
                for (start..@min(lanes.len, start + perline)) |lane| {
                    const changed = if (self.view.previous) |old| !std.mem.eql(u8, current.vectors[i][lane * lane_size ..][0..lane_size], old.vectors[i][lane * lane_size ..][0..lane_size]) else false;
                    const step: f32 = lane_width;
                    try r.textFit(font, b.x + 90 + @as(f32, @floatFromInt(lane - start)) * step, y, step - 8, lanes[lane], if (changed) theme.warm else theme.text);
                }
            }
        }
        for (0..8) |i| {
            defer lines += 1;
            if (lines < self.row or lines >= self.row + visible) continue;
            const bits = std.mem.readInt(u80, &current.st[i], .little);
            const label = if (current.st_valid[i]) try std.fmt.allocPrint(a, "st{d}   {d}   0x{x:0>20}", .{ i, @as(f80, @bitCast(bits)), bits }) else try std.fmt.allocPrint(a, "st{d}   empty", .{i});
            const changed = if (self.view.previous) |old| current.st_valid[i] != old.st_valid[i] or (current.st_valid[i] and !std.mem.eql(u8, &current.st[i], &old.st[i])) else false;
            try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, label, if (changed) theme.warm else theme.text);
        }
        if (lines >= self.row and lines < self.row + visible) try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, try std.fmt.allocPrint(a, "MXCSR 0x{x}   x87 control 0x{x} status 0x{x}", .{ current.mxcsr, current.control, current.status }), theme.weak);
        lines += 1;
        if (current.vector_bytes == 64) for (current.masks, 0..) |mask, i| {
            defer lines += 1;
            if (lines < self.row or lines >= self.row + visible) continue;
            try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, try std.fmt.allocPrint(a, "k{d}   0x{x:0>16}", .{ i, mask }), if (self.view.previous != null and self.view.previous.?.masks[i] != mask) theme.warm else theme.text);
        };
        self.row = @min(self.row, lines -| 1);
        self.message = formatMessage(self.format);
    }
    fn formatMessage(format: xstate.Format) []const u8 {
        return switch (format) {
            .hex => "hex u64 lanes, least significant first",
            .f32 => "float32 lanes, least significant first",
            .f64 => "float64 lanes, least significant first",
            .i32 => "signed int32 lanes, least significant first",
            .u32 => "unsigned int32 lanes, least significant first",
            .u64 => "unsigned int64 lanes, least significant first",
        };
    }
};
