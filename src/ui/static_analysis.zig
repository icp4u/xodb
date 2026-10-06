//! Static slice and control-dependence panel (S on an assembly row, a source
//! line, or the current instruction). The answer comes from the supervised
//! Ghidra worker through src/semq and is always labelled static; values read
//! from the stopped target appear in a separate "observed now" block.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const host = @import("../semq/host.zig");
const answer = @import("../semq/answer.zig");
const style = @import("style.zig");
const theme = style.theme;

/// A source line carries every line-table row and every function those rows
/// fall in; with more than one function the user chooses, nothing is picked.
pub const Choice = struct { name: []const u8, entry: u64 };
pub const Target = union(enum) { pc: u64, line: struct { path: []const u8, line: u32, addresses: []const u64, functions: []const Choice } };
const max_rows = 64;
const max_functions = 16;
const Question = struct { op: u32, input: ?u32, label: []const u8 };
const Row = struct { address: ?u64, certainty: []const u8, label: []const u8 };

pub const Panel = struct {
    open: bool = false,
    mode: enum { slice, controls } = .slice,
    phase: enum { functions, questions, answer } = .questions,
    target: Target = .{ .pc = 0 },
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    artifact: [96]u8 = @splat(0),
    artifact_len: usize = 0,
    questions: []Question = &.{},
    rows: []Row = &.{},
    heading: []const u8 = "",
    summary: []const u8 = "",
    parameters: []const u8 = "",
    selected: usize = 0,
    first: usize = 0,
    visible: usize = 0,
    list_y: f32 = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    retry: bool = false,
    running: bool = false,
    /// A citation chosen with Return or a click; the workspace browses to it.
    navigate: ?u64 = null,
    /// Increments per computed answer (the input trace reports each once).
    answers: u64 = 0,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    target_text: [600]u8 = @splat(0),
    path: [512]u8 = @splat(0),
    line_addresses: [max_rows]u64 = @splat(0),
    functions: [max_functions]Choice = undefined,
    function_names: [max_functions][128]u8 = undefined,
    /// The function chosen for a source line (index into the line's functions).
    chosen: ?usize = null,

    pub fn show(self: *Panel, target: Target) void {
        // Re-opening on the same selection keeps the last answer.
        const same = std.meta.activeTag(target) == std.meta.activeTag(self.target) and switch (target) {
            .pc => |pc| pc == self.target.pc,
            .line => |l| l.line == self.target.line.line and std.mem.eql(u8, l.path, self.target.line.path),
        };
        self.open = true;
        self.navigate = null;
        if (same and self.artifact_len > 0) return;
        _ = self.arena.reset(.retain_capacity);
        self.target = switch (target) {
            .pc => target,
            .line => |l| blk: {
                const n = @min(l.path.len, self.path.len);
                @memcpy(self.path[0..n], l.path[0..n]);
                const rows = @min(l.addresses.len, max_rows);
                @memcpy(self.line_addresses[0..rows], l.addresses[0..rows]);
                const count_functions = @min(l.functions.len, max_functions);
                for (l.functions[0..count_functions], 0..) |f, i| {
                    const m = @min(f.name.len, self.function_names[i].len);
                    @memcpy(self.function_names[i][0..m], f.name[0..m]);
                    self.functions[i] = .{ .name = self.function_names[i][0..m], .entry = f.entry };
                }
                break :blk .{ .line = .{ .path = self.path[0..n], .line = l.line, .addresses = self.line_addresses[0..rows], .functions = self.functions[0..count_functions] } };
            },
        };
        self.artifact_len = 0;
        self.questions = &.{};
        self.rows = &.{};
        self.chosen = if (self.target == .line and self.target.line.functions.len == 1) 0 else null;
        self.phase = if (self.target == .line and self.chosen == null) .functions else .questions;
        self.selected = 0;
        self.retry = false;
        self.message_len = 0;
    }
    fn say(self: *Panel, text: []const u8) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }
    fn address(self: *const Panel) u64 {
        return switch (self.target) {
            .pc => |pc| pc,
            .line => |l| l.functions[self.chosen.?].entry,
        };
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
    pub fn press(self: *Panel, session: *Session, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) {
            self.open = false;
            return;
        }
        if (y < self.list_y or y >= self.list_y + @as(f32, @floatFromInt(self.visible)) * 24) return;
        self.selected = self.first + @as(usize, @intFromFloat((y - self.list_y) / 24));
        if (self.selected >= self.count()) return;
        self.choose(session);
    }
    fn choose(self: *Panel, session: *Session) void {
        if (self.phase == .functions) {
            if (self.selected >= self.count()) return;
            self.chosen = self.selected;
            self.phase = .questions;
            self.selected = 0;
            self.artifact_len = 0;
            return;
        }
        if (self.phase == .questions) return self.run(session);
        if (self.selected < self.rows.len) if (self.rows[self.selected].address) |at| {
            self.navigate = at;
            self.open = false;
        };
    }
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return false;
        if (!event.plain()) return true;
        const k = event.shortcut;
        if (k == keys.sym.space) return false;
        if (k == keys.sym.escape or (k == 's' and event.kind == .press)) {
            self.open = false;
            return true;
        }
        if (k == keys.sym.up) self.move(-1);
        if (k == keys.sym.down) self.move(1);
        if (k == 0xff55) self.move(-8);
        if (k == 0xff56) self.move(8);
        if (event.kind != .press) return true;
        if ((k == keys.sym.tab or k == 'c') and self.phase != .functions) {
            self.mode = if (self.mode == .slice) .controls else .slice;
            self.phase = .questions;
            self.artifact_len = 0; // rebuild the questions for this mode
            self.selected = 0;
        }
        if (k == 0xff0d) self.choose(session);
        if (k == 0xff08) {
            // Back: answer -> questions -> the function choice of a line.
            if (self.phase == .questions and self.target == .line and self.target.line.functions.len > 1) {
                self.phase = .functions;
                self.chosen = null;
            } else if (self.phase == .answer) self.phase = .questions;
            self.selected = 0;
        }
        if (k == 'r') {
            self.retry = true;
            self.artifact_len = 0;
        }
        if (k == 'x') if (session.static_analysis.job) |job| if (job.running()) {
            job.requestCancel();
            self.say("Cancellation requested; the worker is stopped and reaped");
        };
        return true;
    }

    fn print(self: *Panel, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), format, args) catch "";
    }
    fn where(self: *Panel, ref: ?answer.OpRef) []const u8 {
        const op = ref orelse return "";
        if (op.source) |s| return self.print("{s} @{x}  {s}:{d}", .{ op.opcode, op.address, std.fs.path.basename(s.path), s.line });
        return self.print("{s} @{x}", .{ op.opcode, op.address });
    }
    fn value(self: *Panel, v: answer.ValueRef) []const u8 {
        if (v.param) |p| return self.print("param {d} ({s})", .{ p, v.register orelse "?" });
        if (std.mem.eql(u8, v.role, "constant")) return self.print("constant 0x{x}", .{v.offset});
        if (v.register) |name| return self.print("{s} {s}", .{ v.role, name });
        return self.print("{s} v{d}", .{ v.role, v.id });
    }

    /// Questions for the selection: each sliceable input (and the output) of
    /// each op cited there, or each op for control dependences. The user picks;
    /// nothing is chosen for them.
    fn build(self: *Panel, session: *Session, analysis: *host.Analysis) void {
        const a = self.arena.allocator();
        const selector: answer.Selector = switch (self.target) {
            .pc => |pc| .{ .pc = pc },
            .line => |l| .{ .line = .{ .path = l.path, .line = l.line, .addresses = l.addresses } },
        };
        const found = answer.candidates(a, session, analysis, selector, null) catch |err| {
            self.say(@errorName(err));
            return;
        };
        var questions: std.ArrayList(Question) = .empty;
        for (found) |cand| {
            const op = cand.op;
            const callee = if (op.call) |name| self.print(" {s}", .{name}) else "";
            if (self.mode == .controls) {
                questions.append(a, .{ .op = op.op, .input = null, .label = self.print("What controls {s}{s} @{x}?", .{ op.opcode, callee, op.address }) }) catch {};
                continue;
            }
            for (cand.inputs) |input| if (input.sliceable) {
                const arg = if (op.call != null and input.index > 0) self.print(" (argument {d})", .{input.index - 1}) else "";
                questions.append(a, .{ .op = op.op, .input = input.index, .label = self.print("What feeds {s}{s} input {d}{s} @{x}?  {s}", .{ op.opcode, callee, input.index, arg, op.address, self.value(input.value) }) }) catch {};
            };
            if (cand.output) |out| questions.append(a, .{ .op = op.op, .input = null, .label = self.print("What feeds the output of {s}{s} @{x}?  {s}", .{ op.opcode, callee, op.address, self.value(out) }) }) catch {};
        }
        self.questions = questions.items;
        self.selected = @min(self.selected, self.questions.len -| 1);
        if (found.len == 0) {
            if (self.target == .line) {
                // Say why, never "no code": the rows may be inlined code.
                const miss = answer.lineMiss(a, session, analysis, self.target.line.addresses) catch null;
                if (miss) |m| {
                    var text: std.ArrayList(u8) = .empty;
                    text.print(a, "{s}: no exported op is cited at this line's rows", .{m.reason}) catch {};
                    for (m.rows) |row| {
                        text.print(a, "  0x{x}", .{row.address}) catch {};
                        if (row.inlined.len > 0) text.print(a, " (inlined {s})", .{row.inlined[0]}) catch {};
                    }
                    self.say(text.items);
                }
            } else self.say("No op of the analysed graph is cited here (the instruction may have no surviving p-code)");
        }
        const n = @min(analysis.artifact_id.len, self.artifact.len);
        @memcpy(self.artifact[0..n], analysis.artifact_id[0..n]);
        self.artifact_len = n;
    }

    fn run(self: *Panel, session: *Session) void {
        if (self.selected >= self.questions.len) return;
        const q = self.questions[self.selected];
        const analysis = session.static_analysis.find(self.artifact[0..self.artifact_len]) orelse {
            self.artifact_len = 0;
            return;
        };
        const a = self.arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        if (self.mode == .slice) {
            const s = answer.slice(a, session, analysis, q.op, q.input, false, .{}) catch |err| {
                self.say(@errorName(err));
                return;
            };
            self.heading = q.label;
            self.summary = self.print("{s}  data and control  status {s}  limit {s}  exhaustive {s}  memory complete {s}  {d} values", .{ s.trust.result_trust, s.status, s.limit, if (s.exhaustive) "yes" else "no", if (s.memory_complete) "yes" else "no", s.contributions_total });
            var params: std.ArrayList(u8) = .empty;
            for (s.parameters) |p| params.print(a, "param {d} {s}: {s}    ", .{ p.index, p.registers, p.relevance }) catch {};
            self.parameters = params.items;
            for (s.contributions) |row| {
                const at = row.defined_by orelse row.read_by;
                rows.append(a, .{ .address = if (at) |op| op.address else null, .certainty = row.certainty, .label = self.print("{s}  ({s})  {s}{s}", .{ self.value(row.value), row.step, if (row.defined_by != null) "defined by " else if (row.read_by != null) "read by " else "", self.where(at) }) }) catch {};
            }
            for (s.boundaries) |bd| rows.append(a, .{ .address = if (bd.op) |op| op.address else null, .certainty = bd.certainty, .label = self.print("boundary {s}  {s}", .{ bd.kind, self.where(bd.op) }) }) catch {};
        } else {
            const ctl = answer.controls(a, session, analysis, q.op, .{}) catch |err| {
                self.say(@errorName(err));
                return;
            };
            self.heading = q.label;
            self.summary = self.print("{s}  status {s}  limit {s}  {d} control dependences", .{ ctl.trust.result_trust, ctl.status, ctl.limit, ctl.controls_total });
            self.parameters = "";
            for (ctl.controls) |row| {
                var feeds: std.ArrayList(u8) = .empty;
                for (row.condition_parameters) |p| if (!std.mem.eql(u8, p.relevance, "irrelevant")) feeds.print(a, " param {d} {s} ({s})", .{ p.index, p.registers, p.relevance }) catch {};
                rows.append(a, .{ .address = row.branch.address, .certainty = row.certainty, .label = self.print("{s} {s}  edge {s} -> block {d}  condition fed by:{s}", .{ row.relation, self.where(row.branch), row.edge, row.controlled_block, if (feeds.items.len > 0) feeds.items else " no parameter" }) }) catch {};
            }
        }
        self.rows = rows.items;
        self.answers += 1;
        self.phase = .answer;
        self.selected = 0;
        self.message_len = 0;
    }

    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session, tid: i32, frame: usize) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = width - 40, .h = height - 136 };
        const b = self.bounds;
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = height - 110 }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        var buffer: [1024]u8 = undefined;
        const x = b.x + 14;
        const w = b.w - 28;
        try r.textFit(font, x, b.y + 10, w, try std.fmt.bufPrint(&buffer, "STATIC ANALYSIS   {s}   Tab slice/controls   S / Esc close", .{if (self.mode == .slice) "what feeds this value?" else "what controls this operation?"}), theme.text);
        // The banner is unconditional: every answer below is static.
        try style.box(r, .{ .x = x - 4, .y = b.y + 34, .w = w + 8, .h = 26 }, style.fade(theme.warm, 0.18), theme.warm, @splat(4));
        try r.textFit(font, x + 4, b.y + 38, w - 8, "STATIC  " ++ host.banner, theme.warm);
        var y = b.y + 70;
        self.running = false;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (self.phase == .functions) {
            const l = self.target.line;
            try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "{s}:{d} has code in {d} functions: choose one (Up/Down, Return); nothing is chosen for you", .{ std.fs.path.basename(l.path), l.line, l.functions.len }), theme.neutral);
            try self.list(r, font, x, y + 28, w, b);
            return self.footer(r, font, b);
        }
        const status = session.static_analysis.request(arena.allocator(), session, self.address(), .{ .retry = self.retry }) catch |err| {
            self.retry = false;
            try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "{s} at 0x{x}", .{ @errorName(err), self.address() }), theme.breakpoint);
            try r.textFit(font, x, y + 26, w, "Static analysis needs function bounds from the session's symbols (ELF or DWARF)", theme.weak);
            return self.footer(r, font, b);
        };
        self.retry = false;
        switch (status) {
            .unavailable => |u| {
                try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "Static analysis unavailable: {s}", .{u.reason}), theme.breakpoint);
                try r.textFit(font, x, y + 26, w, u.detail, theme.weak);
                // The build hint is long; show it on short lines.
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
                return self.footer(r, font, b);
            },
            .running => |job| {
                self.running = true;
                try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "Analysing {s} (0x{x}, {d} bytes) with the supervised Ghidra worker: {d} ms of {d} ms", .{ job.function.name, job.function.runtime(job.function.key.entry), job.function.key.size, job.elapsedMs(), job.deadline_ms }), theme.text);
                try r.textFit(font, x, y + 26, w, "The worker is a separate process tree, never the target; X cancels it", theme.weak);
                return self.footer(r, font, b);
            },
            .failed => |job| {
                const f = job.failure.?;
                try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "Analysis of {s} {s}: {s}", .{ job.function.name, if (std.mem.eql(u8, f.code, "cancelled")) "cancelled" else "failed", f.code }), theme.breakpoint);
                try r.textFit(font, x, y + 26, w, f.detail, theme.weak);
                try r.textFit(font, x, y + 52, w, "R retries with a new bounded job", theme.weak);
                return self.footer(r, font, b);
            },
            .ready => |analysis| {
                if (self.artifact_len == 0 or !std.mem.eql(u8, self.artifact[0..self.artifact_len], analysis.artifact_id)) {
                    _ = self.arena.reset(.retain_capacity);
                    self.phase = .questions;
                    self.build(session, analysis);
                }
                var reasons: std.ArrayList(u8) = .empty;
                for (analysis.reasons) |reason| reasons.print(arena.allocator(), "{s} ", .{reason.code}) catch {};
                // Trust first, so a narrow window truncates the identity, not the trust.
                try r.textFit(font, x, y, w, try std.fmt.bufPrint(&buffer, "result_trust graph_{s}   verified_semantics no   qualification {s}: {s}", .{ analysis.level, analysis.level, reasons.items }), if (std.mem.eql(u8, analysis.level, "unreliable")) theme.breakpoint else theme.text);
                try r.textFit(font, x, y + 23, w, try std.fmt.bufPrint(&buffer, "{s}  0x{x}+{d}  ({s})   artifact {s}   image sha256 {s}", .{ analysis.function.name, analysis.function.runtime(analysis.function.key.entry), analysis.function.key.size, analysis.function.bounds_source, analysis.artifact_id, analysis.function.key.image_sha256[0..16] }), theme.weak);
                y += 54;
                if (self.phase == .answer) {
                    try r.textFit(font, x, y, w, self.heading, theme.neutral);
                    try r.textFit(font, x, y + 23, w, self.summary, theme.weak);
                    y += 46;
                    if (self.parameters.len > 0) {
                        try r.textFit(font, x, y, w, self.parameters, theme.good);
                        y += 25;
                    }
                    if (self.mode == .slice) y = try self.observed(r, font, x, y, w, session, analysis, tid, frame, &arena);
                } else {
                    const target_text = switch (self.target) {
                        .pc => |pc| try std.fmt.bufPrint(&self.target_text, "Instruction 0x{x}: choose a question (Up/Down, Return)", .{pc}),
                        .line => |l| try std.fmt.bufPrint(&self.target_text, "{s}:{d}: choose a question (Up/Down, Return)", .{ std.fs.path.basename(l.path), l.line }),
                    };
                    try r.textFit(font, x, y, w, target_text, theme.neutral);
                    y += 28;
                }
                try self.list(r, font, x, y, w, b);
            },
        }
        try self.footer(r, font, b);
    }

    /// Observed now: kept apart from the static rows and labelled as such.
    fn observed(self: *Panel, r: *gpu.Renderer, font: *Font, x: f32, y: f32, w: f32, session: *Session, analysis: *host.Analysis, tid: i32, frame: usize, arena: *std.heap.ArenaAllocator) !f32 {
        _ = self;
        if (tid == 0) return y;
        const seen = (answer.observed(arena.allocator(), session, analysis, tid, frame) catch null) orelse return y;
        var text: std.ArrayList(u8) = .empty;
        const a = arena.allocator();
        try text.print(a, "OBSERVED NOW (tid {d} frame {d}, generation {d}; not part of the static answer):", .{ seen.tid, seen.frame, seen.generation });
        for (seen.parameters) |p| try text.print(a, "  {s} = {s}", .{ p.name, p.value });
        try style.box(r, .{ .x = x - 4, .y = y - 3, .w = w + 8, .h = 25 }, style.fade(theme.thread_main, 0.12), style.fade(theme.thread_main, 0.6), @splat(3));
        try r.textFit(font, x + 4, y, w - 8, text.items, theme.thread_main);
        return y + 30;
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
        try r.textFit(font, b.x + 14, b.y + b.h - 64, b.w - 28, if (self.message_len > 0) self.message[0..self.message_len] else hint, theme.weak);
        try r.textFit(font, b.x + 14, b.y + b.h - 38, b.w - 28, "Rows are static possibilities over the exported graph; the qualification above bounds how far to trust them", theme.weak);
    }
};
