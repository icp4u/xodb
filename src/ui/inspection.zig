//! Memory and floating-point/vector inspection over the shared target/model.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const memory = @import("../model/memory.zig");
const xstate = @import("../target/xstate.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
pub const Panel = struct {
    open: bool = false,
    kind: enum { memory, vectors } = .memory,
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
    vector: ?xstate.State = null,
    previous: ?xstate.State = null,
    format: xstate.Format = .f32,
    width: usize = 16,
    row: usize = 0,
    pub fn show(self: *Panel, session: *Session, vectors: bool, address: u64) void {
        self.open = true;
        self.kind = if (vectors) .vectors else .memory;
        self.refresh = true;
        self.editor.open = false;
        self.row = 0;
        if (!vectors) self.address = address;
        self.message = if (vectors) "V lane format  W vector width  Up/Down scroll; values from selected thread" else "G address/expression  / search (hex: or text:)  P pin baseline";
        if (self.baseline) |id| {
            _ = session.memory.find(id) catch {
                self.baseline = null;
            };
        }
    }
    pub fn busy(self: *const Panel, session: *const Session) bool {
        if (!self.open or self.kind != .memory) return false;
        return if (session.memory.search) |search| search.state == .running else false;
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
    pub fn key(self: *Panel, session: *Session, tid: i32, frame: usize, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (self.editor.open) {
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.message = "Edit cancelled",
                .submit => |text| {
                    self.submit(session, tid, frame, text) catch |err| {
                        self.message = @errorName(err);
                        return true;
                    };
                    self.editor.open = false;
                },
            } else return false;
            return true;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return false;
        if (!event.plain()) return true;
        const k = event.shortcut;
        if (k == keys.sym.escape or k == 'm' or k == 'r') {
            self.open = false;
            return true;
        }
        if (k == keys.sym.space) return false;
        if (k == keys.sym.up or k == keys.sym.down or k == 0xff55 or k == 0xff56) {
            self.wheel(if (k == keys.sym.up) -1 else if (k == keys.sym.down) 1 else if (k == 0xff55) -16 else 16);
            return true;
        }
        if (event.kind == .repeat) return true;
        if (self.kind == .vectors) {
            if (k == 'v') self.format = @enumFromInt((@intFromEnum(self.format) + 1) % 6);
            if (k == 'w') {
                const max = if (self.vector) |v| v.vector_bytes else 16;
                self.width = if (self.width >= max) 16 else self.width * 2;
            }
            return true;
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
            self.baseline = self.snapshot;
            session.memory.pinned = self.baseline;
            self.message = "Pinned displayed snapshot; orange bytes differ, blue bytes became readable";
        } else if (k == 'n') {
            if (session.memory.search) |search| if (search.count > 0) {
                self.hit %= search.count;
                self.address = search.hits[self.hit];
                self.hit = (self.hit + 1) % search.count;
                self.refresh = true;
            };
        } else if (k == 'c') {
            if (session.memory.search) |*search| if (search.state == .running) {
                search.state = .cancelled;
            };
        } else if (k == 'w') {
            self.all_writable = !self.all_writable;
            self.message = if (self.all_writable) "/ now searches all writable private mappings at this stop" else "/ now searches the displayed address and length";
        } else if (k == 'u') {
            self.baseline = null;
            session.memory.pinned = null;
            self.message = "Baseline cleared";
        }
        return true;
    }
    fn submit(self: *Panel, session: *Session, tid: i32, frame: usize, text: []const u8) !void {
        switch (self.editing) {
            .address => {
                const address = std.fmt.parseInt(u64, text, 0) catch blk: {
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer arena.deinit();
                    const value = try session.evaluateExpression(arena.allocator(), tid, frame, text);
                    if (value.availability != .available) return error.ValueUnavailable;
                    break :blk switch (value.type.kind) {
                        .pointer, .unsigned, .signed => value.bits,
                        else => value.address orelse return error.ExpectedAddress,
                    };
                };
                if (address == 0) return error.InvalidMemoryRange;
                self.address = address;
                self.refresh = true;
                self.message = "Memory address updated";
            },
            .length => {
                const length = std.fmt.parseInt(usize, text, 0) catch return error.InvalidMemoryRange;
                if (length == 0 or length > memory.max_search) return error.InvalidMemoryRange;
                self.search_length = length;
                self.message = "Search length updated";
            },
            .pattern => {
                var bytes: [256]u8 = undefined;
                const data = if (std.mem.startsWith(u8, text, "text:")) text[5..] else blk: {
                    const hex = if (std.mem.startsWith(u8, text, "hex:")) text[4..] else text;
                    if (hex.len == 0 or hex.len % 2 != 0 or hex.len > 512) return error.InvalidMemoryPattern;
                    for (0..hex.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch return error.InvalidMemoryPattern;
                    break :blk bytes[0 .. hex.len / 2];
                };
                if (self.all_writable) {
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer arena.deinit();
                    try session.refreshMaps();
                    const ranges = try memory.regionRanges(arena.allocator(), session.modules.regions.items, .writable, false, 0, std.math.maxInt(u64));
                    _ = try session.memory.startSearchRanges(session, ranges, data, .{});
                } else _ = try session.memory.startSearch(session, self.address, self.search_length, data);
                self.hit = 0;
                self.message = "Searching; N jumps to next result, C cancels";
            },
        }
    }
    fn update(self: *Panel, session: *Session, tid: i32) void {
        if (session.target.snapshot().state != .stopped) return;
        if (!self.refresh and self.generation == session.target.snapshot().generation and self.tid == tid and self.image_epoch == session.target.snapshot().image_epoch) return;
        const same = self.tid == tid and self.image_epoch == session.target.snapshot().image_epoch;
        self.refresh = false;
        self.generation = session.target.snapshot().generation;
        self.image_epoch = session.target.snapshot().image_epoch;
        self.tid = tid;
        if (self.kind == .vectors) {
            self.previous = if (same) self.vector else null;
            self.vector = session.target.extendedRegisters(tid) catch |err| {
                self.vector = null;
                self.message = @errorName(err);
                return;
            };
            self.width = @min(self.width, self.vector.?.vector_bytes);
        } else {
            self.snapshot = session.memory.capture(session, self.address, 1024) catch |err| {
                self.snapshot = null;
                self.message = @errorName(err);
                return;
            };
        }
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session, tid: i32) !void {
        if (!self.open) return;
        self.update(session, tid);
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        var buffer: [1024]u8 = undefined;
        const title = try std.fmt.bufPrint(&buffer, "{s}   {s} / Esc close   tid {d}   stop {d}{s}", .{ if (self.kind == .memory) "MEMORY" else "FP / SIMD", if (self.kind == .memory) "M" else "R", tid, self.generation, if (session.target.snapshot().state != .stopped) " (historical: target running)" else "" });
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, title, theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, if (self.kind == .memory) "G address  P pin  U unpin  / find  L length  W all writable  N next  C cancel  PgUp/Down" else "V format  W width  Up/Down scroll  Orange = changed since previous stop", theme.weak);
        if (self.kind == .memory) try self.drawMemory(r, font, b, session) else try self.drawVectors(r, font, b);
        const y = b.y + b.h - 76;
        if (self.kind == .memory) if (session.memory.search) |search| {
            const progress = try std.fmt.bufPrint(&buffer, "Search {s}: {d}/{d} bytes in {d} ranges, {d} unreadable, {d} hits", .{ @tagName(search.state), search.scanned, search.length, search.ranges.len, search.unreadable, search.count });
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
    fn drawMemory(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect, session: *Session) !void {
        const snapshot = session.memory.find(self.snapshot orelse return) catch {
            self.refresh = true;
            return;
        };
        const baseline = if (self.baseline) |id| session.memory.find(id) catch null else null;
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
                const change = if (baseline) |old| memory.Memory.compare(snapshot, old, i) else .same;
                const color = if (change == .changed or change == .became_unreadable) theme.warm else if (change == .became_readable) theme.focus else if (!snapshot.valid[i]) theme.weak else theme.text;
                const label = if (snapshot.valid[i]) try std.fmt.bufPrint(&buffer, "{x:0>2}", .{snapshot.bytes[i]}) else "??";
                try r.text(font, b.x + 174 + @as(f32, @floatFromInt(j)) * 27, y, label, color);
                ascii[j] = if (!snapshot.valid[i]) '?' else if (snapshot.bytes[i] >= 32 and snapshot.bytes[i] < 127) snapshot.bytes[i] else '.';
            }
            try r.textFit(font, b.x + 184 + @as(f32, @floatFromInt(columns)) * 27, y, b.w - 198 - @as(f32, @floatFromInt(columns)) * 27, ascii[0..columns], theme.weak);
        }
    }
    fn drawVectors(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        const current = self.vector orelse return;
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
                    const changed = if (self.previous) |old| !std.mem.eql(u8, current.vectors[i][lane * lane_size ..][0..lane_size], old.vectors[i][lane * lane_size ..][0..lane_size]) else false;
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
            const changed = if (self.previous) |old| current.st_valid[i] != old.st_valid[i] or (current.st_valid[i] and !std.mem.eql(u8, &current.st[i], &old.st[i])) else false;
            try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, label, if (changed) theme.warm else theme.text);
        }
        if (lines >= self.row and lines < self.row + visible) try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, try std.fmt.allocPrint(a, "MXCSR 0x{x}   x87 control 0x{x} status 0x{x}", .{ current.mxcsr, current.control, current.status }), theme.weak);
        lines += 1;
        if (current.vector_bytes == 64) for (current.masks, 0..) |mask, i| {
            defer lines += 1;
            if (lines < self.row or lines >= self.row + visible) continue;
            try r.textFit(font, b.x + 14, b.y + 66 + @as(f32, @floatFromInt(lines - self.row)) * 22, b.w - 28, try std.fmt.allocPrint(a, "k{d}   0x{x:0>16}", .{ i, mask }), if (self.previous != null and self.previous.?.masks[i] != mask) theme.warm else theme.text);
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
