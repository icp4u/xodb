//! Logical evidence view. Retains only selection indices and its own source
//! preview; temporary C strings are copied before rendering.
const std = @import("std");
const model = @import("../frames/model.zig");
const c = model.c;
const State = @import("../frames/state.zig").State;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const Window = @import("../platform/wayland.zig").Window;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const View = struct {
    open: bool = false,
    source: usize = 0,
    selected: usize = 0,
    scroll: usize = 0,
    serial: u64 = 0,
    preview: c.struct_xfb_input = std.mem.zeroes(c.struct_xfb_input),
    preview_line: usize = 0,
    preview_status: []const u8 = "Enter opens the recorded source location",
    pub fn deinit(self: *View) void {
        c.xfb_input_free(&self.preview);
    }
    fn current(self: *View, state: *State) ?*model.Source {
        if (state.count == 0) return null;
        self.source = @min(self.source, state.count - 1);
        return state.sources[self.source];
    }
    fn function(self: *View, source: *model.Source) ?u32 {
        if (source.jit_owner != null) return null;
        const doc = source.doc();
        if (doc.function_count == 0) return null;
        self.selected = @min(self.selected, doc.function_count - 1);
        return if (source.aggregate) |agg| agg.order[self.selected] else @intCast(self.selected);
    }
    fn load(self: *View, state: *State) void {
        c.xfb_input_free(&self.preview);
        const source = self.current(state) orelse return;
        const index = self.function(source) orelse return;
        const doc = source.doc();
        const f = doc.functions[index];
        if (f.code == c.XLF_NONE) {
            self.preview_status = "No source file recorded";
            return;
        }
        const code = doc.codes[f.code];
        if (code.path.ptr == null) {
            self.preview_status = "No source path recorded";
            return;
        }
        const path = code.path.ptr[0..code.path.len];
        if (path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) {
            self.preview_status = "Source path cannot be opened";
            return;
        }
        const name = std.heap.page_allocator.dupeZ(u8, path) catch {
            self.preview_status = "Source preview memory limit";
            return;
        };
        defer std.heap.page_allocator.free(name);
        model.bundleCheck(c.xfb_read(name, 1024 * 1024, null, &self.preview)) catch |err| {
            self.preview_status = @errorName(err);
            return;
        };
        if (!std.unicode.utf8ValidateSlice(self.preview.bytes[0..self.preview.size])) {
            c.xfb_input_free(&self.preview);
            self.preview_status = "Source is not UTF-8";
            return;
        }
        self.preview_line = if (f.first_line > 0) @intCast(f.first_line) else 1;
        self.preview_status = if (code.sha256.ptr == null) "Source identity was not recorded" else if (std.mem.eql(u8, code.sha256.ptr[0..code.sha256.len], self.preview.sha256[0..64])) "Source matches recorded SHA-256" else "Source has changed since collection";
    }
    fn clearPreview(self: *View) void {
        c.xfb_input_free(&self.preview);
        self.preview_status = "Enter opens the recorded source location";
    }
    pub fn input(self: *View, w: *Window, state: *State) void {
        if (state.serial != self.serial) {
            self.serial = state.serial;
            self.selected = 0;
            self.scroll = 0;
            self.clearPreview();
        }
        while (w.input.next()) |event| {
            if ((event.kind == .press or event.kind == .repeat) and event.plain()) {
                w.dirty = true;
                switch (event.shortcut) {
                    'q' => {
                        w.closing = true;
                        w.close_reason = .quit_key;
                    },
                    'l' => self.open = false,
                    keys.sym.escape => state.cancel(),
                    keys.sym.up, 'k' => {
                        self.selected -|= 1;
                        self.clearPreview();
                    },
                    keys.sym.down, 'j' => {
                        self.selected += 1;
                        self.clearPreview();
                    },
                    '[' => {
                        self.source -|= 1;
                        self.selected = 0;
                        self.scroll = 0;
                        self.clearPreview();
                    },
                    ']' => {
                        if (self.source + 1 < state.count) self.source += 1;
                        self.selected = 0;
                        self.scroll = 0;
                        self.clearPreview();
                    },
                    0xff0d => self.load(state),
                    't' => if (event.kind == .press) {
                        if (self.current(state)) |source| {
                            if (source.jit_owner != null) continue;
                            const next: ?u32 = if (source.metadata.selected_thread) |thread| (if (thread + 1 < source.doc().thread_count) thread + 1 else null) else (if (source.doc().thread_count > 0) @as(u32, 0) else null);
                            state.select(self.source, next) catch |err| {
                                self.preview_status = @errorName(err);
                            };
                        }
                    },
                    else => {},
                }
            } else if (event.kind == .button_press and event.code == 0x110 and event.y >= 200 and event.x < @as(f32, @floatFromInt(w.width)) * 0.56) {
                self.selected = self.scroll + @as(usize, @intFromFloat((event.y - 200) / 24));
                w.dirty = true;
                self.load(state);
            }
        }
        if (w.scroll != 0) {
            if (w.scroll > 0) self.selected -|= 3 else self.selected += 3;
            self.clearPreview();
            w.scroll = 0;
            w.dirty = true;
        }
    }
    pub fn draw(self: *View, r: *gpu.Renderer, font: *Font, w: *Window, state: *State) !void {
        const width: f32 = @floatFromInt(w.width);
        const height: f32 = @floatFromInt(w.height);
        const all = gpu.Rect{ .x = 0, .y = 0, .w = width, .h = height };
        r.clip = all;
        try r.rect(all, theme.background);
        try label(r, font, 16, 18, width - 32, theme.text, "LOGICAL FRAMES  /  separate from native stacks", .{});
        try label(r, font, 16, height - 28, width - 32, theme.weak, "L native workspace   [ / ] source   J/K select   Enter source   T thread   Esc cancel   Q quit", .{});
        if (state.attachment.failure) |err| {
            try label(r, font, 16, 50, width - 32, theme.warm, "Archive attachments {s}: {s} (original bytes retained)", .{ @tagName(state.attachment.state), @errorName(err) });
        } else if (state.failure) |err| try label(r, font, 16, 50, width - 32, theme.warm, "Frame job: {s}", .{@errorName(err)});
        const source = self.current(state) orelse {
            try label(r, font, 16, 85, width - 32, theme.text, "{s}", .{if (state.busy()) "Importing frame evidence..." else "No logical evidence imported"});
            return;
        };
        if (source.jit_owner) |jit| {
            try label(r, font, 16, 85, width - 32, theme.text, "JIT source {d}/{d}: {s} / {d} versions / {d} diagnostics", .{ self.source + 1, state.count, @tagName(source.kind), jit.version_count, jit.diag_count });
            try label(r, font, 16, 116, width - 32, theme.weak, "L returns to native profiles; I opens sampled stacks with JIT labels", .{});
            return;
        }
        const doc = source.doc();
        var budget = @import("../profile/archive_budget.zig").Budget{ .backing = std.heap.page_allocator, .limit = 512 * 1024 };
        var arena = std.heap.ArenaAllocator.init(budget.allocator());
        defer arena.deinit();
        const a = arena.allocator();
        const language = try model.ownBounded(a, doc.header.language, 512);
        const method = try model.ownBounded(a, doc.header.method, 512);
        const unit = try model.ownBounded(a, doc.header.weight_unit, 512);
        try label(r, font, 16, 78, width - 32, theme.text, "Source {d}/{d}: {s} / {s} / read {s}", .{ self.source + 1, state.count, language orelse "unknown", method orelse "unspecified", std.mem.span(c.xlf_stability_name(source.input.stability)) });
        if (source.aggregate) |agg| {
            try label(r, font, 16, 106, width - 32, theme.text, "Weight {s} {s}  /  partial {s}  /  unknown leaf {s}  /  marker {s}", .{ agg.total, unit orelse "count", agg.partial, agg.unknown_leaf, agg.marker });
            try label(r, font, 16, 134, width - 32, if (agg.input_incomplete) theme.warm else theme.weak, "{d} stacks / {d} partial / incomplete {} / thread {?d} / {s}", .{ agg.stacks, agg.partial_stacks, agg.input_incomplete, agg.thread, if (state.busy()) "worker pending" else model.algorithm });
        } else try label(r, font, 16, 106, width - 32, theme.warm, "Saved analysis is stale; T explicitly recomputes from retained evidence", .{});
        const selected = self.function(source);
        const left = width * 0.56;
        try label(r, font, 16, 172, left - 32, theme.weak, "Inclusive / self count    Function", .{});
        const visible: usize = @intFromFloat(@min(64, @max(1, (height - 246) / 24)));
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected - visible + 1;
        for (self.scroll..@min(doc.function_count, self.scroll + visible)) |row| {
            const index: usize = if (source.aggregate) |agg| agg.order[row] else row;
            const f = try model.ownBounded(a, doc.functions[index], 512);
            const y = 200 + @as(f32, @floatFromInt(row - self.scroll)) * 24;
            if (row == self.selected) try r.rect(.{ .x = 12, .y = y, .w = left - 24, .h = 24 }, theme.pop);
            const inclusive = if (source.aggregate) |agg| agg.inclusive[index] else "?";
            const own_weight = if (source.aggregate) |agg| agg.self[index] else "?";
            try label(r, font, 16, y, left - 32, theme.text, "{s} / {s}   {s}", .{ inclusive, own_weight, f.qualified orelse f.name orelse "unknown" });
        }
        if (selected) |index| {
            const f = try model.ownBounded(a, doc.functions[index], 512);
            try label(r, font, left + 10, 172, width - left - 24, theme.text, "{s}", .{f.qualified orelse f.name orelse "unknown"});
            if (f.code != c.XLF_NONE) {
                const code = try model.ownBounded(a, doc.codes[f.code], 512);
                try label(r, font, left + 10, 200, width - left - 24, theme.warm, "{s}:{d}", .{ if (code.path) |path| std.fs.path.basename(path) else "source unavailable", f.first_line });
            }
            try label(r, font, left + 10, 228, width - left - 24, theme.weak, "{s}", .{self.preview_status});
            if (self.preview.bytes != null) {
                var lines = std.mem.splitScalar(u8, self.preview.bytes[0..self.preview.size], '\n');
                var number: usize = 1;
                var y: f32 = 258;
                while (lines.next()) |line| : (number += 1) {
                    if (number + 3 < self.preview_line) continue;
                    if (y > height - 65) break;
                    try label(r, font, left + 10, y, width - left - 24, if (number == self.preview_line) theme.warm else theme.text, "{d}  {s}", .{ number, model.preview(line, 512) });
                    y += 22;
                }
            }
        }
    }
};
fn label(r: *gpu.Renderer, font: *Font, x: f32, y: f32, width: f32, color: gpu.Color, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, fmt, args) catch return;
    try r.textFit(font, x, y, width, text, color);
}
