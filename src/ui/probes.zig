//! Breakpoint policy editor. All mutations go through the shared session model.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const policy = @import("../model/probes.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
pub const Panel = struct {
    open: bool = false,
    selected: usize = 0,
    scroll: usize = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    editor: Editor = .{},
    editing: enum { condition, log, ignore, thread, symbol } = .condition,
    editing_id: u64 = 0,
    message: []const u8 = "Select a breakpoint; C condition, L logpoint, H ignore count, T thread",
    fn options(session: *Session, id: u64) policy.Options {
        if (session.probes.rule(id)) |rule| return .{ .condition = rule.condition.slice(), .log_expression = rule.log_expression.slice(), .thread_id = rule.thread_id, .ignore_count = rule.ignore_remaining, .mode = rule.mode };
        return .{};
    }
    fn apply(self: *Panel, session: *Session, id: u64, opt: policy.Options, enabled: bool) void {
        session.probes.configure(&session.target, id, opt, enabled) catch |err| {
            self.message = @errorName(err);
            return;
        };
        session.record(.human, "configure_breakpoint");
        self.message = "Breakpoint updated";
    }
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (self.editor.open) {
            if (event.shortcut == 0xff0d and self.editor.text.len == 0) {
                self.submit(session, "");
                return true;
            }
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.message = "Edit cancelled",
                .submit => |value| self.submit(session, value),
            } else return false;
            return true;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return false;
        if (!event.plain()) return true;
        const key_ = event.shortcut;
        if (key_ == keys.sym.escape or key_ == 'b') {
            self.open = false;
            return true;
        }
        const count = session.target.snapshot().breakpoint_count;
        if (key_ == 'n') {
            self.editing = .symbol;
            self.editor.start();
            self.message = "Symbol name; resolves now or stays pending until its library loads";
            return true;
        }
        if (count == 0) return true;
        self.selected = @min(self.selected, count - 1);
        if (key_ == keys.sym.up) {
            self.selected -|= 1;
            return true;
        }
        if (key_ == keys.sym.down) {
            self.selected = @min(count - 1, self.selected + 1);
            return true;
        }
        if (event.kind == .repeat) return true;
        const probe = session.target.breakpointSlice()[self.selected];
        if (probe.internal) {
            self.message = "Internal loader breakpoint (read-only)";
            return true;
        }
        if (key_ == 0xffff or key_ == 0xff08) { // Delete or BackSpace (compact keyboards)
            session.target.removeBreakpoint(probe.id) catch |err| {
                self.message = @errorName(err);
                return true;
            };
            session.record(.human, "remove_breakpoint");
            self.message = "Breakpoint removed";
        } else if (key_ == keys.sym.space) {
            self.apply(session, probe.id, options(session, probe.id), !probe.enabled);
        } else if (key_ == 'o') {
            var opt = options(session, probe.id);
            opt.mode = .stop;
            self.apply(session, probe.id, opt, probe.enabled);
        } else if (key_ == 'c' or key_ == 'l' or key_ == 'h' or key_ == 't') {
            self.editing = if (key_ == 'c') .condition else if (key_ == 'l') .log else if (key_ == 'h') .ignore else .thread;
            self.editing_id = probe.id;
            self.editor.start();
            const rule = session.probes.rule(probe.id);
            const initial = if (rule) |v| switch (self.editing) {
                .condition => v.condition.slice(),
                .log => v.log_expression.slice(),
                else => "",
            } else "";
            const n = @min(initial.len, self.editor.text.bytes.len);
            @memcpy(self.editor.text.bytes[0..n], initial[0..n]);
            self.editor.text.len = n;
            self.message = switch (self.editing) {
                .condition => "Condition expression (empty clears)",
                .log => "Log expression (empty records hits); O restores stopping",
                .ignore => "Number of matching-thread hits to ignore",
                .thread => "Thread TID (empty selects all threads)",
                .symbol => unreachable,
            };
        }
        return true;
    }
    fn submit(self: *Panel, session: *Session, value: []const u8) void {
        if (self.editing == .symbol) {
            _ = session.persistent.addSymbol(session, value) catch |err| {
                self.message = @errorName(err);
                return;
            };
            session.record(.human, "set_breakpoint");
            self.editor.open = false;
            self.message = "Symbol breakpoint added (pending when unloaded)";
            return;
        }
        var enabled = true;
        for (session.target.breakpointSlice()) |probe| {
            if (probe.id == self.editing_id) {
                enabled = probe.enabled;
                break;
            }
        } else {
            self.message = "Breakpoint no longer exists";
            self.editor.open = false;
            return;
        }
        var opt = options(session, self.editing_id);
        switch (self.editing) {
            .symbol => unreachable,
            .condition => opt.condition = value,
            .log => {
                opt.log_expression = value;
                opt.mode = .log;
            },
            .ignore => opt.ignore_count = if (value.len == 0) 0 else std.fmt.parseInt(u64, value, 10) catch {
                self.message = "Enter a nonnegative integer";
                return;
            },
            .thread => {
                opt.thread_id = null;
                if (value.len > 0) {
                    const tid = std.fmt.parseInt(i32, value, 10) catch {
                        self.message = "Enter a live thread TID";
                        return;
                    };
                    for (session.target.threadSlice()) |thread| {
                        if (thread.tid == tid and thread.state != .exited) {
                            opt.thread_id = thread.id;
                            break;
                        }
                    } else {
                        self.message = "Thread unavailable";
                        return;
                    }
                }
            },
        }
        self.apply(session, self.editing_id, opt, enabled);
        self.editor.open = false;
    }
    pub fn press(self: *Panel, x: f32, y: f32, count: usize) void {
        if (x < self.bounds.x or x >= self.bounds.x + self.bounds.w or y < self.bounds.y or y >= self.bounds.y + self.bounds.h) {
            self.open = false;
            return;
        }
        if (y >= self.bounds.y + 64 and y < self.bounds.y + self.bounds.h - 124 and count > 0) self.selected = @min(count - 1, self.scroll + @as(usize, @intFromFloat((y - self.bounds.y - 64) / 24)));
    }
    pub fn wheel(self: *Panel, amount: i32, count: usize) void {
        self.selected = @intCast(@max(0, @min(@as(i64, @intCast(count -| 1)), @as(i64, @intCast(self.selected)) + amount)));
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.text(font, b.x + 14, b.y + 10, "BREAKPOINTS   B / Esc close", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, "N new  Space toggle  Del  C if  L log  O stop  H ignore  T thread", theme.weak);
        const count = session.target.snapshot().breakpoint_count;
        const visible: usize = @intFromFloat(@max(1, (b.h - 188) / 24));
        self.selected = @min(self.selected, count -| 1);
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.selected >= self.scroll + visible) self.scroll = self.selected - visible + 1;
        var buffer: [1024]u8 = undefined;
        for (session.target.breakpointSlice()[self.scroll..@min(count, self.scroll + visible)], self.scroll..) |probe, i| {
            const y = b.y + 64 + @as(f32, @floatFromInt(i - self.scroll)) * 24;
            if (i == self.selected) try r.rect(.{ .x = b.x + 6, .y = y - 1, .w = b.w - 12, .h = 24 }, style.fade(theme.focus, 0.16));
            const rule = session.probes.rule(probe.id);
            const mode = if (probe.internal) "loader" else if (probe.pending) "PENDING" else if (rule) |v| @tagName(v.mode) else "stop";
            const condition = if (rule) |v| v.condition.slice() else "";
            const row = try std.fmt.bufPrint(&buffer, "#{d} {s}  0x{x}  hits {d}  {s}  {s}", .{ probe.id, if (probe.enabled) "on " else "off", probe.address, probe.hit_count, mode, if (probe.pending) (if (session.persistent.entry(probe.id)) |v| (if (v.symbol.len > 0) v.symbol.slice() else v.path) else condition) else condition });
            try r.textFit(font, b.x + 14, y, b.w - 28, row, if (probe.enabled) theme.text else theme.weak);
        }
        if (count == 0) try r.text(font, b.x + 14, b.y + 70, "Set a source/assembly breakpoint to configure it here", theme.weak);
        const y = b.y + b.h - 112;
        if (count > 0) if (session.probes.rule(session.target.breakpointSlice()[self.selected].id)) |rule| {
            var thread_buffer: [40]u8 = undefined;
            var thread_label: []const u8 = "all";
            if (rule.thread_id) |id| {
                thread_label = "ended";
                for (session.target.threadSlice()) |thread| if (thread.id == id) {
                    thread_label = try std.fmt.bufPrint(&thread_buffer, "{d}", .{thread.tid});
                };
            }
            const detail = try std.fmt.bufPrint(&buffer, "matched {d}  ignore {d}  thread {s}  {s}", .{ rule.matched_hits, rule.ignore_remaining, thread_label, rule.last_error orelse "" });
            try r.textFit(font, b.x + 14, y, b.w - 28, detail, if (rule.last_error != null) theme.warm else theme.weak);
        };
        if (count > 0) if (session.persistent.entry(session.target.breakpointSlice()[self.selected].id)) |definition| {
            if (definition.diagnostic) |diagnostic| try r.textFit(font, b.x + 14, y, b.w - 28, diagnostic, theme.warm);
        };
        try r.textFit(font, b.x + 14, y + 24, b.w - 28, self.message, theme.text);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = y + 48, .w = b.w - 20, .h = 27 }, theme.background, theme.focus, @splat(3));
            try r.textFit(font, b.x + 16, y + 52, b.w - 32, self.editor.text.slice(), theme.text);
        } else if (session.probes.log_count > 0) {
            const log = &session.probes.logs[session.probes.log_count - 1];
            const message = try std.fmt.bufPrint(&buffer, "Log #{d} tid {d}: {s} = {s}  (dropped {d})", .{ log.sequence, log.tid, log.expression.slice(), log.display.slice(), session.probes.dropped_logs });
            try r.textFit(font, b.x + 14, y + 52, b.w - 28, message, theme.neutral);
        }
        try r.textFit(font, b.x + 14, y + 80, b.w - 28, "F4 restart  F5 continue/pause  F12 finish  F9 run to source line", theme.weak);
    }
};
