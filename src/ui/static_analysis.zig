//! Static-analysis input and rendering from immutable owner publications.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const prepared = @import("../model/static_view.zig");
const host = @import("../semq/host.zig");
const style = @import("style.zig");
const theme = style.theme;
pub const Choice = prepared.Choice;
pub const Target = prepared.Target;
pub const Input = struct { handled: bool = true, cancel: ?u64 = null };
pub const Panel = struct {
    open: bool = false,
    decompile_open: bool = false,
    mode: prepared.Mode = .slice,
    phase: prepared.Phase = .questions,
    origin: prepared.Origin = .{ .pc = 0 },
    chosen: ?u64 = null,
    question: ?prepared.QuestionRef = null,
    retry: u64 = 0,
    target: Target = .{ .pc = 0 },
    questions: []const prepared.Question = &.{},
    rows: []const prepared.Row = &.{},
    heading: []const u8 = "",
    summary: []const u8 = "",
    parameters: []const u8 = "",
    selected: usize = 0,
    first: usize = 0,
    visible: usize = 0,
    list_y: f32 = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    running: bool = false,
    navigate: ?u64 = null,
    answers: u64 = 0,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    target_text: [600]u8 = @splat(0),
    view: ?prepared.View = null,
    native: ?*prepared.Capture = null,
    choose_pending: bool = false,
    decompile_line: u32 = 0,
    /// The PC the pane last followed; a click on a pseudo-C line stays put until this changes.
    decompile_synced: ?u64 = null,
    /// The stop PC the pane last saw, so a stop in another function reopens it there.
    decompile_stop: ?u64 = null,
    decompile_first: u32 = 1,
    decompile_rows: struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, count: usize = 0 } = .{},
    decompile_pcs: std.ArrayList(u64) = .empty,
    pub fn deinit(self: *Panel) void {
        self.decompile_pcs.deinit(std.heap.page_allocator);
        if (self.native) |capture| {
            capture.deinit();
            std.heap.page_allocator.destroy(capture);
        }
    }
    pub fn show(self: *Panel, target: Target) void {
        if (self.mode == .decompile) self.mode = .slice;
        const origin: prepared.Origin = switch (target) {
            .pc => |pc| .{ .pc = pc },
            .line => |line| prepared.Origin.source(line.path, line.line) catch |err| {
                self.say(@errorName(err));
                self.open = true;
                return;
            },
        };
        self.showOrigin(origin);
    }
    pub fn showOrigin(self: *Panel, origin: prepared.Origin) void {
        if (self.mode == .decompile) self.mode = .slice;
        self.open = true;
        self.navigate = null;
        if (std.meta.eql(self.origin, origin) and self.view != null) return;
        self.origin = origin;
        self.choose_pending = false;
        self.view = null;
        self.chosen = null;
        self.question = null;
        self.questions = &.{};
        self.rows = &.{};
        self.selected = 0;
        self.phase = .questions;
        self.message_len = 0;
    }
    pub fn showDecompile(self: *Panel, origin: prepared.Origin) void {
        self.decompile_open = true;
        self.mode = .decompile;
        self.navigate = null;
        if (std.meta.eql(self.origin, origin) and self.view != null and self.view.?.request.mode == .decompile) return;
        self.origin = origin;
        self.view = null;
        self.chosen = null;
        self.question = null;
        self.decompile_line = 0;
        self.decompile_synced = null;
        self.decompile_first = 1;
        self.decompile_pcs.clearRetainingCapacity();
    }
    pub fn hideDecompile(self: *Panel) void {
        self.decompile_open = false;
        self.decompile_stop = null;
        if (!self.open) self.view = null;
    }
    fn say(self: *Panel, text: []const u8) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }
    pub fn request(self: *const Panel, tid: i32, frame: usize) ?prepared.Request {
        if (!self.open and !self.decompile_open) return null;
        return .{ .origin = self.origin, .mode = self.mode, .chosen = self.chosen, .question = self.question, .retry = self.retry, .tid = tid, .frame = frame };
    }
    pub fn present(self: *Panel, value: ?prepared.View) void {
        // Retiring a publication invalidates every borrowed row, including
        // when its replacement answers an older local navigation request.
        self.view = null;
        self.target = .{ .pc = 0 };
        self.heading = "";
        self.summary = "";
        self.parameters = "";
        self.questions = &.{};
        self.rows = &.{};
        self.running = false;
        const v = value orelse return;
        if (!std.meta.eql(self.origin, v.request.origin) or self.mode != v.request.mode or
            self.retry != v.request.retry or !std.meta.eql(self.question, v.request.question) or
            (self.chosen != null and self.chosen != v.request.chosen)) return;
        self.view = v;
        if (self.phase != v.phase) self.selected = 0;
        self.phase = v.phase;
        self.target = v.target;
        self.chosen = v.request.chosen;
        self.questions = v.questions;
        self.rows = v.rows;
        self.heading = v.heading;
        self.summary = v.summary;
        self.parameters = v.parameters;
        self.running = v.status == .pending;
        self.answers = v.answers;
        self.selected = @min(self.selected, self.count() -| 1);
        if (v.request.mode == .decompile and self.decompile_line == 0) {
            for (v.pseudo_tokens) |token| if (token.pc != null) {
                self.decompile_line = token.line;
                break;
            };
        }
        if (self.choose_pending and self.count() > 0) {
            self.choose_pending = false;
            self.choose();
        }
    }
    fn count(self: *const Panel) usize {
        return switch (self.phase) {
            .functions => if (self.target == .line) self.target.line.functions.len else 0,
            .questions => self.questions.len,
            .answer => self.rows.len,
        };
    }
    fn move(self: *Panel, delta: i64) void {
        const n = self.count();
        if (n == 0) return;
        self.selected = @intCast(std.math.clamp(@as(i64, @intCast(self.selected)) + delta, 0, @as(i64, @intCast(n - 1))));
    }
    pub fn wheel(self: *Panel, amount: i32) void {
        self.move(amount);
    }
    pub fn press(self: *Panel, _: *Session, x: f32, y: f32) void {
        self.pressPrepared(x, y);
    }
    pub fn pressPrepared(self: *Panel, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) {
            self.open = false;
            return;
        }
        if (y < self.list_y or y >= self.list_y + @as(f32, @floatFromInt(self.visible)) * 24) return;
        self.selected = self.first + @as(usize, @intFromFloat((y - self.list_y) / 24));
        self.choose();
    }
    fn choose(self: *Panel) void {
        if (self.selected >= self.count()) {
            if (self.phase == .questions) self.choose_pending = true;
            return;
        }
        if (self.phase == .functions) {
            self.chosen = self.target.line.functions[self.selected].entry;
            self.phase = .questions;
            self.questions = &.{};
            self.selected = 0;
            return;
        }
        if (self.phase == .questions) {
            const view = self.view orelse return;
            self.question = prepared.QuestionRef.from(view.artifact, self.questions[self.selected]) catch |err| {
                self.say(@errorName(err));
                return;
            };
        } else if (self.rows[self.selected].address) |at| {
            self.navigate = at;
            self.open = false;
        }
    }
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        const input = self.keyPrepared(event);
        if (input.cancel) |id| prepared.cancel(session, .human, id) catch |err| {
            self.say(@errorName(err));
        };
        // Native input may contain Tab and Return in one batch. Prepare the
        // new mode before consuming its next key, including the answer trace.
        if (self.native) |capture| {
            const previous = if (capture.value) |v| v.request else return input.handled;
            capture.refresh(session, self.request(previous.tid, previous.frame));
            self.present(capture.value);
        }
        return input.handled;
    }
    pub fn keyPrepared(self: *Panel, event: keys.Event) Input {
        if (!self.open) return .{ .handled = false };
        if (event.kind != .press and event.kind != .repeat) return .{};
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return .{ .handled = false };
        if (!event.plain()) return .{};
        const k = event.shortcut;
        if (k == keys.sym.space) return .{ .handled = false };
        if (k == keys.sym.escape or (k == 's' and event.kind == .press)) {
            self.open = false;
            self.choose_pending = false;
            return .{};
        }
        if (k == keys.sym.up) self.move(-1);
        if (k == keys.sym.down) self.move(1);
        if (k == 0xff55) self.move(-8);
        if (k == 0xff56) self.move(8);
        if (event.kind != .press) return .{};
        if ((k == keys.sym.tab or k == 'c') and self.phase != .functions) {
            self.mode = if (self.mode == .slice) .controls else .slice;
            self.choose_pending = false;
            self.phase = .questions;
            self.question = null;
            self.questions = &.{};
            self.selected = 0;
        }
        if (k == 0xff0d) self.choose();
        if (k == 0xff08) {
            self.choose_pending = false;
            if (self.phase == .questions and self.target == .line and self.target.line.functions.len > 1) {
                self.phase = .functions;
                self.chosen = null;
            } else if (self.phase == .answer) {
                self.phase = .questions;
                self.question = null;
            }
            self.selected = 0;
        }
        if (k == 'r') {
            self.choose_pending = false;
            self.retry +%= 1;
            self.question = null;
            self.questions = &.{};
        }
        if (k == 'x') if (self.view) |view| if (view.status == .pending) if (view.job_id) |id| {
            self.say("Cancellation requested; the worker is stopped and reaped");
            return .{ .cancel = id };
        };
        return .{};
    }
    pub fn prepare(self: *Panel, session: *Session, tid: i32, frame: usize) !void {
        if (!self.open and !self.decompile_open) return;
        if (self.native == null) {
            const capture = try std.heap.page_allocator.create(prepared.Capture);
            capture.* = .{};
            self.native = capture;
        }
        self.native.?.refresh(session, self.request(tid, frame));
        self.present(self.native.?.value);
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session, tid: i32, frame: usize) !void {
        try self.prepare(session, tid, frame);
        try self.drawPrepared(r, font, width, height);
    }
    pub fn drawPrepared(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        var buffer: [1024]u8 = undefined;
        const x = b.x + 14;
        const w = b.w - 28;
        try r.textFit(font, x, b.y + 10, w, try std.fmt.bufPrint(&buffer, "STATIC ANALYSIS   {s}   Tab slice/controls   S / Esc close", .{if (self.mode == .slice) "what feeds this value?" else "what controls this operation?"}), theme.text);
        try style.box(r, .{ .x = x - 4, .y = b.y + 34, .w = w + 8, .h = 26 }, style.fade(theme.warm, 0.18), theme.warm, @splat(4));
        try r.textFit(font, x + 4, b.y + 38, w - 8, "STATIC  " ++ host.banner, theme.warm);
        var y = b.y + 70;
        const view = self.view orelse {
            try r.textFit(font, x, y, w, "Preparing static analysis", theme.weak);
            return self.footer(r, font, b);
        };
        if (view.status == .ready) {
            try r.textFit(font, x, y, w, view.qualification, if (view.unreliable) theme.breakpoint else theme.text);
            try r.textFit(font, x, y + 23, w, view.detail, theme.weak);
            y += 54;
            if (self.phase == .answer) {
                try r.textFit(font, x, y, w, self.heading, theme.neutral);
                try r.textFit(font, x, y + 23, w, self.summary, theme.weak);
                y += 46;
                if (self.parameters.len > 0) {
                    try r.textFit(font, x, y, w, self.parameters, theme.good);
                    y += 25;
                }
                if (view.observed.len > 0) {
                    try style.box(r, .{ .x = x - 4, .y = y - 3, .w = w + 8, .h = 25 }, style.fade(theme.thread_main, 0.12), style.fade(theme.thread_main, 0.6), @splat(3));
                    try r.textFit(font, x + 4, y, w - 8, view.observed, theme.thread_main);
                    y += 30;
                }
            } else {
                try r.textFit(font, x, y, w, view.title, theme.neutral);
                y += 28;
            }
            try self.list(r, font, x, y, w, b);
        } else {
            try r.textFit(font, x, y, w, view.title, if (view.status == .failed or view.status == .unavailable) theme.breakpoint else theme.text);
            try r.textFit(font, x, y + 26, w, view.detail, theme.weak);
            if (view.status == .functions) try self.list(r, font, x, y + 28, w, b);
            if (view.status == .failed) try r.textFit(font, x, y + 52, w, "R retries with a new bounded job", theme.weak);
            if (view.status == .unavailable) {
                var rest: []const u8 = host.how_to_build;
                var line_y = y + 60;
                while (rest.len > 0 and line_y + 20 < b.y + b.h - 70) : (line_y += 23) {
                    var cut: usize = @min(rest.len, 110);
                    if (cut < rest.len) if (std.mem.lastIndexOfScalar(u8, rest[0..cut], ' ')) |space| {
                        cut = space + 1;
                    };
                    try r.textFit(font, x, line_y, w, rest[0..cut], theme.text);
                    rest = rest[cut..];
                }
            }
        }
        try self.footer(r, font, b);
    }

    pub fn decompileView(self: *const Panel) ?prepared.View {
        const view = self.view orelse return null;
        if (!self.decompile_open or view.request.mode != .decompile) return null;
        return view;
    }

    /// Select the exact exported mappings on a pseudo-C line.  Empty lines
    /// select no instruction; there is deliberately no nearest-PC fallback.
    pub fn selectDecompileLine(self: *Panel, line: u32) void {
        self.decompile_line = line;
        self.decompile_pcs.clearRetainingCapacity();
        const view = self.decompileView() orelse return;
        for (view.pseudo_tokens) |token| if (token.line == line) if (token.pc) |pc| {
            var known = false;
            for (self.decompile_pcs.items) |seen| if (seen == pc) {
                known = true;
                break;
            };
            if (!known) self.decompile_pcs.append(std.heap.page_allocator, pc) catch return;
        };
        self.navigate = if (self.decompile_pcs.items.len > 0) self.decompile_pcs.items[0] else null;
    }

    pub fn selectDecompileAt(self: *Panel, x: f32, y: f32) bool {
        const rows = self.decompile_rows;
        if (!self.decompile_open or rows.count == 0 or x < rows.x or x >= rows.x + rows.w or y < rows.y - 2 or y >= rows.y - 2 + @as(f32, @floatFromInt(rows.count)) * 23) return false;
        self.selectDecompileLine(self.decompile_first + @as(u32, @intFromFloat((y - rows.y + 2) / 23)));
        return true;
    }

    pub fn syncDecompilePC(self: *Panel, pc: ?u64) void {
        const wanted = pc orelse return;
        const view = self.decompileView() orelse return;
        if (view.status != .ready or self.decompile_synced == wanted) return;
        self.decompile_synced = wanted;
        // A PC printed on several lines keeps the line the user clicked.
        if (std.mem.indexOfScalar(u64, self.decompile_pcs.items, wanted) != null) return;
        for (view.pseudo_tokens) |token| if (token.pc == wanted) {
            if (self.decompile_line != token.line) {
                self.selectDecompileLine(token.line);
                self.navigate = null;
                const visible: u32 = @intCast(self.decompile_rows.count);
                if (visible > 0) {
                    if (token.line < self.decompile_first) self.decompile_first = token.line;
                    if (token.line >= self.decompile_first + visible) self.decompile_first = token.line - visible + 1;
                }
            }
            return;
        };
    }

    pub fn wheelDecompile(self: *Panel, amount: i32) void {
        const view = self.decompileView() orelse return;
        if (view.pseudocode.len == 0 or self.decompile_rows.count == 0) return;
        const total: u32 = @intCast(std.mem.count(u8, view.pseudocode, "\n") + @intFromBool(view.pseudocode[view.pseudocode.len - 1] != '\n'));
        const visible: u32 = @intCast(self.decompile_rows.count);
        const last_first = if (total > visible) total - visible + 1 else 1;
        self.decompile_first = @intCast(std.math.clamp(@as(i64, self.decompile_first) + amount, 1, @as(i64, last_first)));
    }
    fn list(self: *Panel, r: *gpu.Renderer, font: *Font, x: f32, y: f32, w: f32, b: gpu.Rect) !void {
        self.list_y = y;
        const n = self.count();
        self.visible = @min(n, @as(usize, @intFromFloat(@max(1, (b.y + b.h - 74 - y) / 24))));
        self.selected = @min(self.selected, n -| 1);
        self.first = if (self.selected >= self.visible) self.selected - self.visible + 1 else 0;
        if (n == 0) {
            try r.textFit(font, x, y, w, if (self.phase == .answer) "No rows" else "No questions for this selection", theme.weak);
            return;
        }
        for (self.first..self.first + self.visible) |i| {
            const row_y = y + @as(f32, @floatFromInt(i - self.first)) * 24;
            if (i == self.selected) try style.focus(r, .{ .x = x - 6, .y = row_y - 2, .w = w + 12, .h = 24 }, 4, 1);
            if (self.phase == .functions) {
                const f = self.target.line.functions[i];
                try r.textFit(font, x, row_y, w, try std.fmt.bufPrint(&self.target_text, "{s}  0x{x}", .{ f.name, f.entry }), if (i == self.selected) theme.text else theme.weak);
            } else if (self.phase == .questions) {
                try r.textFit(font, x, row_y, w, self.questions[i].label, if (i == self.selected) theme.text else theme.weak);
            } else {
                const row = self.rows[i];
                const color = if (std.mem.eql(u8, row.certainty, "direct")) theme.text else if (std.mem.eql(u8, row.certainty, "possible")) theme.warm else theme.neutral;
                try r.textFit(font, x, row_y, 90, row.certainty, color);
                try r.textFit(font, x + 96, row_y, w - 96, row.label, if (i == self.selected) theme.text else theme.weak);
            }
        }
    }

    fn footer(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        const hint = if (self.phase == .answer) "Return/click: go to the cited instruction   Backspace: questions   Tab: slice/controls" else "Return: answer   Tab: slice/controls   R: retry a failed analysis   X: cancel a running one";
        try r.textFit(font, b.x + 14, b.y + b.h - 64, b.w - 28, if (self.message_len > 0) self.message[0..self.message_len] else if (self.view) |v| (if (v.message.len > 0) v.message else hint) else hint, theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 38, b.w - 28, "Rows are static possibilities over the exported graph; the qualification above bounds how far to trust them", theme.weak);
    }
};

test "static navigation rejects an earlier mode and retains Return until questions arrive" {
    var panel: Panel = .{};
    panel.showOrigin(.{ .pc = 0x1000 });
    const questions = [_]prepared.Question{.{ .op = 7, .input = 1, .label = "old input" }};
    panel.present(.{ .request = panel.request(1, 0).?, .status = .ready, .artifact = "same-artifact", .questions = &questions });
    const old = panel.view.?;
    _ = panel.keyPrepared(.{ .kind = .press, .shortcut = keys.sym.tab });
    _ = panel.keyPrepared(.{ .kind = .press, .shortcut = 0xff0d });
    try std.testing.expect(panel.choose_pending);
    panel.present(old);
    try std.testing.expect(panel.view == null);
    try std.testing.expectEqual(@as(usize, 0), panel.questions.len);
    try std.testing.expect(panel.choose_pending);
    const controls = [_]prepared.Question{.{ .op = 8, .input = null, .label = "control" }};
    panel.present(.{ .request = panel.request(1, 0).?, .status = .ready, .artifact = "same-artifact", .questions = &controls });
    try std.testing.expect(!panel.choose_pending);
    try std.testing.expectEqual(@as(u32, 8), panel.question.?.op);
    try std.testing.expect(panel.question.?.input == null);
    panel.present(old);
    try std.testing.expectEqual(@as(u32, 8), panel.question.?.op);
}

test "pseudo-C lines select exported PCs exactly and leave unmapped lines empty" {
    var panel: Panel = .{};
    panel.showDecompile(.{ .pc = 0x1000 });
    const tokens = [_]prepared.PseudoToken{
        .{ .index = 0, .line = 4, .col = 2, .kind = "variable", .text = "a", .pc = 0x1010 },
        .{ .index = 1, .line = 4, .col = 4, .kind = "op", .text = "+", .pc = 0x1020 },
        .{ .index = 2, .line = 4, .col = 6, .kind = "variable", .text = "b", .pc = 0x1010 },
        .{ .index = 3, .line = 5, .col = 0, .kind = "syntax", .text = "}" },
    };
    panel.present(.{ .request = panel.request(1, 0).?, .status = .ready, .pseudocode = "\n\n\n  a + b\n}", .pseudo_tokens = &tokens });
    panel.selectDecompileLine(4);
    try std.testing.expectEqual(@as(usize, 2), panel.decompile_pcs.items.len);
    try std.testing.expectEqual(@as(u64, 0x1010), panel.decompile_pcs.items[0]);
    try std.testing.expectEqual(@as(u64, 0x1020), panel.decompile_pcs.items[1]);
    try std.testing.expectEqual(@as(?u64, 0x1010), panel.navigate);
    panel.selectDecompileLine(5);
    try std.testing.expectEqual(@as(usize, 0), panel.decompile_pcs.items.len);
    try std.testing.expectEqual(@as(?u64, null), panel.navigate);
}

test "a clicked pseudo-C line is kept when its PC is also printed on an earlier line" {
    var panel: Panel = .{};
    defer panel.deinit();
    panel.showDecompile(.{ .pc = 0x1000 });
    const tokens = [_]prepared.PseudoToken{
        .{ .index = 0, .line = 1, .col = 0, .kind = "variable", .text = "a", .pc = 0x1010 },
        .{ .index = 1, .line = 2, .col = 0, .kind = "variable", .text = "b", .pc = 0x1010 },
        .{ .index = 2, .line = 3, .col = 0, .kind = "syntax", .text = "}" },
        .{ .index = 3, .line = 4, .col = 0, .kind = "variable", .text = "c", .pc = 0x1020 },
    };
    panel.present(.{ .request = panel.request(1, 0).?, .status = .ready, .pseudocode = "a\nb\n}\nc", .pseudo_tokens = &tokens });
    panel.syncDecompilePC(0x1020);
    try std.testing.expectEqual(@as(u32, 4), panel.decompile_line);
    panel.selectDecompileLine(2);
    panel.syncDecompilePC(0x1010);
    try std.testing.expectEqual(@as(u32, 2), panel.decompile_line);
    panel.selectDecompileLine(3);
    panel.syncDecompilePC(0x1010);
    try std.testing.expectEqual(@as(u32, 3), panel.decompile_line);
    panel.syncDecompilePC(0x1020);
    try std.testing.expectEqual(@as(u32, 4), panel.decompile_line);
}
