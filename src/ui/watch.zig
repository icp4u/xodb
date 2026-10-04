//! Expression entry and a bounded watch list (T19).
//!
//! Each entry keeps the thread and frame it was typed in. A frame is found
//! again by its canonical frame address (CFA) plus function, never by index
//! alone; when it no longer exists the entry says "frame gone" and keeps its
//! last value only as a labelled past observation. While the target runs,
//! nothing is evaluated and values are shown as stale. Evaluation goes through
//! the same Session paths as MCP `evaluate_expression` and `get_value_children`.
const std = @import("std");
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const style = @import("style.zig");
const theme = style.theme;

pub const max_entries = 16;
pub const max_text = 256;
pub const max_history = 32;
pub const max_children = 16;
const max_display = 160;
const max_type = 64;
const max_symbol = 96;

fn Text(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = undefined,
        len: usize = 0,
        fn set(self: *@This(), value: []const u8) void {
            self.len = @min(n, value.len);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// Stable target/thread identity; a reused numeric TID is a different thread.
pub const Identity = struct { session: u64, image: u64, thread: u64 };
pub const Frame = struct { cfa: ?u64, symbol: ?[]const u8, module: ?u64, function: ?u64, pc: u64 };
pub const Stack = union(enum) { unavailable, frames: struct { items: []const Frame, complete: bool } };
/// CFA and function address are a matching heuristic, not proof of a call's
/// lifetime. Calls may return and reuse an address entirely between stops.
/// Once observed gone, an entry never rebinds; the user must add it again.
pub const FrameId = struct {
    tid: i32,
    identity: Identity,
    generation: u64,
    index: usize,
    cfa: ?u64,
    module: ?u64,
    function: ?u64,
    pc: u64,
    symbol: Text(max_symbol) = .{},
    pub fn of(tid: i32, index: usize, frame: Frame, identity: Identity, generation: u64) FrameId {
        var id = FrameId{ .tid = tid, .identity = identity, .generation = generation, .index = index, .cfa = frame.cfa, .module = frame.module, .function = frame.function, .pc = frame.pc };
        id.symbol.set(frame.symbol orelse "");
        return id;
    }
    fn persistent(self: *const FrameId) bool {
        return self.cfa != null and self.module != null and self.function != null;
    }
    fn matches(self: *const FrameId, frame: Frame, index: usize, generation: u64) bool {
        if (generation == self.generation) return index == self.index and frame.pc == self.pc;
        return self.persistent() and self.cfa == frame.cfa and self.module == frame.module and self.function == frame.function;
    }
};
pub const State = enum { pending, value, failed, frame_gone, thread_gone, context_changed, stack_unavailable, stale };
pub const Child = struct { name: []const u8, display: []const u8 };
/// One evaluation, filled by the context. Slices live until the next refresh.
pub const Result = union(enum) {
    value: struct { display: []const u8, type_name: []const u8, available: bool, expandable: bool = false, children: []const Child = &.{}, total: ?u64 = null, next: ?u64 = null },
    failed: anyerror,
};

pub const Entry = struct {
    text: Text(max_text) = .{},
    frame: FrameId,
    state: State = .pending,
    display: Text(max_display) = .{},
    type_name: Text(max_type) = .{},
    available: bool = false,
    /// `display` holds a value from a successful evaluation.
    has_value: bool = false,
    failure: ?anyerror = null,
    /// Value at the previous stop, for change marking.
    previous: u64 = 0,
    fingerprint: u64 = 0,
    has_previous: bool = false,
    changed: bool = false,
    resolved_index: ?usize = null,
    unverified: bool = false,
    expandable: bool = false,
    expanded: bool = false,
    page: u64 = 0,
    children: []const Child = &.{},
    total: ?u64 = null,
    next: ?u64 = null,
    seen_generation: u64 = 0,
    pub fn expression(self: *const Entry) []const u8 {
        return self.text.slice();
    }
};

pub const WatchList = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    selected: ?usize = null,
    first_row: usize = 0,
    reveal_selection: bool = true,
    /// Generation of the last evaluation; null forces the next one.
    generation: ?u64 = null,
    dirty: bool = true,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    /// Evaluations performed, for tests and measurements.
    evaluations: u64 = 0,
    /// Top of the first drawn row, for hit testing.
    rows_top: f32 = 0,
    pub fn rowAt(self: *const WatchList, y: f32, hits: *const [64]?usize) ?usize {
        if (y < self.rows_top) return null;
        const k: usize = @intFromFloat((y - self.rows_top) / 23);
        return if (k < hits.len) hits[k] else null;
    }

    pub fn deinit(self: *WatchList) void {
        self.arena.deinit();
    }
    pub fn add(self: *WatchList, text: []const u8, frame: FrameId) !usize {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.EmptyExpression;
        if (trimmed.len > max_text) return error.ExpressionTooLong;
        if (self.count == max_entries) return error.WatchListFull;
        var entry = Entry{ .frame = frame };
        entry.text.set(trimmed);
        self.entries[self.count] = entry;
        self.count += 1;
        self.selected = self.count - 1;
        self.reveal_selection = true;
        self.dirty = true;
        return self.count - 1;
    }
    pub fn remove(self: *WatchList, index: usize) void {
        if (index >= self.count) return;
        std.mem.copyForwards(Entry, self.entries[index .. self.count - 1], self.entries[index + 1 .. self.count]);
        self.count -= 1;
        self.selected = if (self.count == 0) null else @min(index, self.count - 1);
        self.reveal_selection = true;
    }
    pub fn scrollBy(self: *WatchList, amount: i32) void {
        self.first_row = @intCast(@max(0, @as(i64, @intCast(self.first_row)) + amount));
        self.reveal_selection = false;
    }
    pub fn items(self: *WatchList) []Entry {
        return self.entries[0..self.count];
    }
    pub fn toggleExpanded(self: *WatchList, index: usize) void {
        if (index >= self.count or !self.entries[index].expandable) return;
        self.entries[index].expanded = !self.entries[index].expanded;
        self.entries[index].page = 0;
        self.reveal_selection = true;
        self.dirty = true;
    }
    pub fn pageChildren(self: *WatchList, index: usize, forward: bool) void {
        if (index >= self.count or !self.entries[index].expanded) return;
        const entry = &self.entries[index];
        self.reveal_selection = true;
        if (forward) {
            entry.page = entry.next orelse return;
        } else entry.page -|= max_children;
        self.dirty = true;
    }

    /// Re-evaluates when the generation changed or entries did. `ctx` provides:
    ///   stopped() bool, ended() bool, generation() u64,
    ///   identity(tid) ?Identity, stack(tid) Stack,
    ///   evaluate(a, tid, frame_index, text, children: ?u64 page) Result.
    /// Nothing is evaluated (and no memory read) unless `stopped()`.
    pub fn refresh(self: *WatchList, ctx: anytype) void {
        if (ctx.ended()) {
            for (self.items()) |*entry| {
                entry.state = .thread_gone;
                entry.resolved_index = null;
            }
            self.generation = null;
            return;
        }
        if (!ctx.stopped()) {
            // Only current results go stale; "frame gone" and "thread gone"
            // already describe an older observation and stay as they are.
            for (self.items()) |*entry| if (entry.state == .value or entry.state == .failed) {
                entry.state = .stale;
            };
            self.generation = null;
            return;
        }
        const generation = ctx.generation();
        if (!self.dirty and self.generation != null and self.generation.? == generation) return;
        self.generation = generation;
        self.dirty = false;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        for (self.items()) |*entry| {
            entry.children = &.{};
            entry.resolved_index = null;
            // Terminal observations cannot be resurrected by CFA/TID reuse.
            if (entry.state == .frame_gone or entry.state == .thread_gone or entry.state == .context_changed) continue;
            const identity = ctx.identity(entry.frame.tid) orelse {
                entry.state = .thread_gone;
                continue;
            };
            if (!std.meta.eql(identity, entry.frame.identity) or
                (generation != entry.frame.generation and !entry.frame.persistent()))
            {
                entry.state = .context_changed;
                continue;
            }
            const stack = switch (ctx.stack(entry.frame.tid)) {
                .unavailable => {
                    entry.state = .stack_unavailable;
                    continue;
                },
                .frames => |frames| frames,
            };
            const index = for (stack.items, 0..) |frame, i| {
                if (entry.frame.matches(frame, i, generation)) break i;
            } else {
                entry.state = if (stack.complete) .frame_gone else .stack_unavailable;
                continue;
            };
            entry.resolved_index = index;
            entry.unverified = generation != entry.frame.generation;
            // Change marking compares with the value at this entry's previous
            // stop; re-evaluating within one stop (expand, page) keeps it.
            if (entry.seen_generation != generation) {
                entry.has_previous = entry.has_value;
                if (entry.has_previous) entry.previous = entry.fingerprint;
                entry.seen_generation = generation;
            }
            self.evaluations += 1;
            switch (ctx.evaluate(a, entry.frame.tid, index, entry.expression(), if (entry.expanded) entry.page else null)) {
                .value => |v| {
                    entry.state = .value;
                    entry.has_value = true;
                    entry.failure = null;
                    entry.display.set(v.display);
                    entry.type_name.set(v.type_name);
                    entry.fingerprint = std.hash.Wyhash.hash(std.hash.Wyhash.hash(@intFromBool(v.available), v.type_name), v.display);
                    entry.available = v.available;
                    entry.expandable = v.expandable;
                    if (!v.expandable) entry.expanded = false;
                    entry.children = v.children;
                    entry.total = v.total;
                    entry.next = v.next;
                },
                .failed => |err| {
                    entry.state = .failed;
                    entry.has_value = false;
                    entry.failure = err;
                    entry.display.len = 0;
                    entry.expandable = false;
                    entry.expanded = false;
                },
            }
            entry.changed = entry.has_previous and entry.has_value and entry.previous != entry.fingerprint;
        }
    }
};

/// Plain words for evaluator and target errors. A typo must never look like a value.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownVariable => "no variable with that name in this frame",
        error.UnknownRegister => "unknown register; use a name from the Registers pane",
        error.RegisterUnavailable => "register not recovered in this frame",
        error.UnknownField => "no field with that name",
        error.ExpectedStructure => "not a struct; . and -> need a struct",
        error.ExpectedPointer => "not a pointer or array",
        error.ExpectedIdentifier, error.InvalidExpression, error.InvalidCharacter, error.InvalidOperator => "cannot parse the expression",
        error.MissingParenthesis => "unbalanced ( )",
        error.MissingBracket => "unbalanced [ ]",
        error.NotAddressable => "has no address (& and fields need memory)",
        error.ValueUnavailable => "optimized out or unavailable here",
        error.IndexOutOfBounds => "index outside the array bounds",
        error.MemoryUnreadable, error.InvalidAddress, error.MemoryReadFailed, error.ShortRead => "memory at that address cannot be read",
        error.ShortCircuitNotSupported => "&& and || are not supported yet",
        error.ExpressionTooDeep => "expression nested too deeply",
        error.DivisionByZero => "division by zero",
        error.IntegerOverflow, error.Overflow => "integer overflow",
        error.InvalidShift => "shift amount out of range",
        error.InvalidPointerOperation => "invalid pointer arithmetic",
        error.InvalidFloatOperation => "operator not valid for floating point",
        error.ExpectedInteger => "needs an integer",
        error.UnsupportedType => "type not supported by the evaluator",
        error.NotStopped => "target is not stopped",
        error.InvalidFrame => "frame no longer exists",
        else => @errorName(err),
    };
}

/// The one-line expression field. Owns Escape, BackSpace, Return, Up/Down,
/// chords and typed text while open, so typing never triggers letter or Space
/// shortcuts. Function keys pass through.
pub const Editor = struct {
    open: bool = false,
    text: Text(max_text) = .{},
    history: [max_history]Text(max_text) = undefined,
    history_count: usize = 0,
    history_at: ?usize = null,
    message: []const u8 = "",
    pub const Action = union(enum) { edited, cancel, submit: []const u8 };
    pub fn start(self: *Editor) void {
        self.open = true;
        self.text.len = 0;
        self.history_at = null;
        self.message = "";
    }
    pub fn key(self: *Editor, event: keys.Event) ?Action {
        if (!self.open or event.kind == .release) return null;
        // Function keys are not text: F5-F11 (run, step, agent) keep working.
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return null;
        switch (event.shortcut) {
            keys.sym.escape => {
                self.open = false;
                return .cancel;
            },
            0xff08 => {
                self.text.len -|= 1;
                return .edited;
            },
            0xff0d, 0xff8d => {
                const value = std.mem.trim(u8, self.text.slice(), " \t");
                if (value.len == 0) return .edited;
                self.remember(value);
                return .{ .submit = self.text.slice() };
            },
            keys.sym.up, keys.sym.down => {
                self.recall(event.shortcut == keys.sym.up);
                return .edited;
            },
            else => {},
        }
        if (event.mods.ctrl and event.shortcut == 'u') {
            self.text.len = 0;
            return .edited;
        }
        if (!event.plain()) return .edited;
        for (event.text()) |ch| if (ch >= 0x20 and ch < 0x7f and self.text.len < max_text) {
            self.text.bytes[self.text.len] = ch;
            self.text.len += 1;
        };
        self.history_at = null;
        return .edited;
    }
    fn remember(self: *Editor, value: []const u8) void {
        if (self.history_count > 0 and std.mem.eql(u8, self.history[(self.history_count - 1) % max_history].slice(), value)) return;
        self.history[self.history_count % max_history].set(value);
        self.history_count += 1;
        self.history_at = null;
    }
    fn recall(self: *Editor, older: bool) void {
        const kept = @min(self.history_count, max_history);
        if (kept == 0) return;
        // Positions count back from the newest entry: 0 is the newest.
        const at: usize = if (self.history_at) |p| (if (older) @min(p + 1, kept - 1) else p -| 1) else if (older) 0 else return;
        if (!older and self.history_at != null and self.history_at.? == 0) {
            self.history_at = null;
            self.text.len = 0;
            return;
        }
        self.history_at = at;
        self.text = self.history[(self.history_count - 1 - at) % max_history];
    }
};

/// Context for the frame tag of a row: which thread/frame the entry belongs to.
fn frameTag(buffer: []u8, entry: *const Entry, with_tid: bool) []const u8 {
    const symbol = entry.frame.symbol.slice();
    const name = if (symbol.len > 0) symbol else "?";
    return switch (entry.state) {
        .thread_gone => std.fmt.bufPrint(buffer, "{d} gone", .{entry.frame.tid}) catch "",
        .context_changed => "re-add in frame",
        .stack_unavailable => "stack unavailable",
        .frame_gone => std.fmt.bufPrint(buffer, "{s} gone", .{name}) catch "",
        else => blk: {
            var tid_buffer: [16]u8 = undefined;
            const tid = if (with_tid) std.fmt.bufPrint(&tid_buffer, "{d} ", .{entry.frame.tid}) catch "" else "";
            break :blk if (entry.resolved_index) |i| std.fmt.bufPrint(buffer, "{s}{s}#{d} {s}", .{ tid, if (entry.unverified) "CFA match " else if (!entry.frame.persistent()) "stop only " else "", i, name }) catch "" else std.fmt.bufPrint(buffer, "{s}{s}", .{ tid, name }) catch "";
        },
    };
}

/// Rows: the open editor, then entries and expanded children. Keeps the
/// selected entry in view. Returns per-row entry indices for hit testing.
pub fn draw(list: *WatchList, editor: *const Editor, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, hits: *[64]?usize) !void {
    const row_h: f32 = 23;
    var y = rect.y + 8;
    const x = rect.x + 12;
    const w = rect.w - 24;
    for (hits) |*h| h.* = null;
    if (editor.open) {
        try r.shape(.{ .x = rect.x + 6, .y = y - 3, .w = rect.w - 12, .h = row_h + 2 }, style.fade(theme.focus, 0.18), .{ .radii = @splat(5) });
        var buffer: [max_text + 8]u8 = undefined;
        const shown = std.fmt.bufPrint(&buffer, "> {s}_", .{editor.text.slice()}) catch "";
        // Keep the end of long input visible.
        var start: usize = 0;
        while (start < shown.len and r.measure(font, shown[start..]) > w) start += 1;
        try r.text(font, x, y, shown[start..], theme.text);
        y += row_h + 2;
        if (editor.message.len > 0) {
            try r.textFit(font, x, y, w, editor.message, theme.warm);
            y += row_h;
        }
    }
    if (list.count == 0) {
        try r.textFit(font, x, y, w, if (editor.open) "Return adds to the watch list; Esc cancels; Up/Down recall" else "E evaluates an expression in the selected frame", theme.weak);
        return;
    }
    // Small panes give the selected entry dedicated type/context lines rather
    // than squeezing the value between three truncated columns.
    if (w <= 560) if (list.selected) |selected| {
        const entry = &list.entries[selected];
        var detail: [240]u8 = undefined;
        const label = if (entry.type_name.len == 0) @tagName(entry.state) else std.fmt.bufPrint(&detail, "{s} / {s}", .{ entry.type_name.slice(), if (entry.state != .value) @tagName(entry.state) else if (entry.available) "available" else "unavailable" }) catch "";
        try r.textFit(font, x, y, w, label, theme.weak);
        y += row_h;
        var context: [240]u8 = undefined;
        var tag: [180]u8 = undefined;
        const label_context = std.fmt.bufPrint(&context, "tid {d} / {s}", .{ entry.frame.tid, frameTag(&tag, entry, false) }) catch "";
        try r.textFit(font, x, y, w, label_context, theme.weak);
        y += row_h;
    };
    // Flatten entries and expanded children into rows.
    const Row = struct { entry: usize, child: ?usize };
    var rows: [max_entries * (max_children + 2)]Row = undefined;
    var n: usize = 0;
    var selected_row: usize = 0;
    for (list.items(), 0..) |*entry, i| {
        if (list.selected != null and list.selected.? == i) selected_row = n;
        rows[n] = .{ .entry = i, .child = null };
        n += 1;
        if (entry.expanded and entry.state == .value) {
            for (0..entry.children.len + 1) |c| {
                rows[n] = .{ .entry = i, .child = c };
                n += 1;
            }
        }
    }
    list.rows_top = y - 3;
    const visible: usize = @intFromFloat(@max(1, @floor((rect.y + rect.h - y) / row_h)));
    if (list.reveal_selection) {
        if (selected_row < list.first_row) list.first_row = selected_row;
        if (selected_row >= list.first_row + visible) list.first_row = selected_row + 1 - visible;
        list.reveal_selection = false;
    }
    list.first_row = @min(list.first_row, n -| visible);
    const type_w: f32 = if (w > 560) 150 else 0;
    for (rows[list.first_row..n], 0..) |row, k| {
        if (k >= visible or k >= hits.len) break;
        hits[k] = row.entry;
        const entry = &list.entries[row.entry];
        const ry = y + @as(f32, @floatFromInt(k)) * row_h;
        if (row.child) |c| {
            var buffer: [320]u8 = undefined;
            const text = if (c < entry.children.len)
                std.fmt.bufPrint(&buffer, "    {s} = {s}", .{ entry.children[c].name, entry.children[c].display }) catch ""
            else if (entry.next) |next|
                std.fmt.bufPrint(&buffer, "    {d}..{d} of {d}; PgDn more", .{ entry.page, next, entry.total orelse next }) catch ""
            else
                std.fmt.bufPrint(&buffer, "    {d} item{s}", .{ entry.total orelse entry.children.len, if ((entry.total orelse entry.children.len) == 1) "" else "s" }) catch "";
            try r.textFit(font, x, ry, w, text, if (c < entry.children.len) theme.text else theme.weak);
            continue;
        }
        if (list.selected != null and list.selected.? == row.entry) try style.focus(r, .{ .x = rect.x + 4, .y = ry - 3, .w = rect.w - 8, .h = row_h }, 6, 1);
        var tag_buffer: [160]u8 = undefined;
        const tag = frameTag(&tag_buffer, entry, w > 560);
        const tag_w = if (w > 560) @min(r.measure(font, tag), w * 0.35) else 0;
        const expr = entry.expression();
        const expr_w = @min(r.measure(font, expr), w * 0.4);
        try r.textFit(font, x, ry, expr_w, expr, theme.neutral);
        const value_x = x + expr_w + 10;
        const value_w = w - expr_w - 10 - tag_w - 12 - type_w;
        var value_buffer: [max_display + 64]u8 = undefined;
        const marker = if (entry.expandable) (if (entry.expanded) "- " else "+ ") else "";
        const value: []const u8, const color: gpu.Color = switch (entry.state) {
            .value => .{ std.fmt.bufPrint(&value_buffer, "= {s}{s}", .{ marker, entry.display.slice() }) catch "", if (entry.available) theme.text else theme.weak },
            .failed => .{ std.fmt.bufPrint(&value_buffer, "error: {s}", .{explain(entry.failure.?)}) catch "", theme.warm },
            .pending => .{ "not evaluated yet", theme.weak },
            .stale => .{ if (!entry.has_value) "stale: running" else std.fmt.bufPrint(&value_buffer, "= {s}  (stale: running)", .{entry.display.slice()}) catch "", theme.weak },
            .frame_gone => .{ if (entry.has_value) std.fmt.bufPrint(&value_buffer, "frame gone; last seen {s}", .{entry.display.slice()}) catch "" else "frame gone", theme.warm },
            .thread_gone => .{ "thread gone", theme.warm },
            .context_changed => .{ "frame identity changed; re-add", theme.warm },
            .stack_unavailable => .{ "stack unavailable; value not refreshed", theme.warm },
        };
        if (entry.changed and entry.state == .value) try r.shape(.{ .x = value_x - 4, .y = ry - 2, .w = @min(value_w, r.measure(font, value) + 8), .h = row_h - 2 }, theme.fresh, .{ .radii = @splat(5) });
        try r.textFit(font, value_x, ry, value_w, value, if (entry.changed and entry.state == .value) theme.warm else color);
        if (type_w > 0 and entry.state == .value) try r.textFit(font, x + w - tag_w - 12 - type_w, ry, type_w - 8, entry.type_name.slice(), theme.weak);
        if (tag_w > 0) try r.textFit(font, x + w - tag_w, ry, tag_w, tag, if (entry.state == .frame_gone or entry.state == .thread_gone or entry.state == .context_changed or entry.state == .stack_unavailable or entry.unverified) theme.warm else theme.weak);
    }
}
