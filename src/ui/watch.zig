//! Expression entry and a bounded watch list (T19).
//!
//! Pinned entries keep the thread and frame they were typed in. A frame is found
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
pub const Mode = enum { pinned, live };
pub const State = enum { pending, value, failed, frame_gone, thread_gone, context_changed, stack_unavailable, stale, not_in_scope };
pub const Child = struct { name: []const u8, display: []const u8, extent_advisory: bool = false };
/// One evaluation, filled by the context. Slices live until the next refresh.
pub const Result = union(enum) {
    value: struct { display: []const u8, type_name: []const u8, available: bool, extent_advisory: bool = false, expandable: bool = false, children: []const Child = &.{}, total: ?u64 = null, next: ?u64 = null },
    failed: anyerror,
};

pub const Entry = struct {
    text: Text(max_text) = .{},
    frame: FrameId,
    mode: Mode = .pinned,
    state: State = .pending,
    display: Text(max_display) = .{},
    type_name: Text(max_type) = .{},
    available: bool = false,
    extent_advisory: bool = false,
    /// `display` holds a value from a successful evaluation.
    has_value: bool = false,
    ever_resolved: bool = false,
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
    fn unavailableDisplay(self: *Entry, state: State) void {
        self.state = state;
        self.has_value = false;
        self.available = false;
        self.extent_advisory = false;
        self.display.len = 0;
        self.type_name.len = 0;
        self.changed = false;
        self.resolved_index = null;
        self.expandable = false;
        self.children = &.{};
    }
};

pub const WatchList = struct {
    pub const Selection = struct { tid: i32, index: usize };
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    selected: ?usize = null,
    first_row: usize = 0,
    reveal_selection: bool = true,
    /// Generation of the last evaluation; null forces the next one.
    generation: ?u64 = null,
    dirty: bool = true,
    display_frame: ?Selection = null,
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
        return self.addMode(text, frame, .pinned);
    }
    pub fn addMode(self: *WatchList, text: []const u8, frame: FrameId, mode: Mode) !usize {
        const trimmed = std.mem.trim(u8, text, " \t");
        if (trimmed.len == 0) return error.EmptyExpression;
        if (trimmed.len > max_text) return error.ExpressionTooLong;
        if (self.count == max_entries) return error.WatchListFull;
        var entry = Entry{ .frame = frame, .mode = mode };
        entry.text.set(trimmed);
        self.entries[self.count] = entry;
        self.count += 1;
        self.selected = self.count - 1;
        self.reveal_selection = true;
        self.dirty = true;
        return self.count - 1;
    }
    pub fn setDisplayFrame(self: *WatchList, selection: ?Selection) void {
        if (std.meta.eql(self.display_frame, selection)) return;
        self.display_frame = selection;
        for (self.items()) |entry| if (entry.mode == .live) {
            self.dirty = true;
            break;
        };
    }
    pub fn toggleMode(self: *WatchList, index: usize, frame: FrameId) void {
        if (index >= self.count) return;
        const old = self.entries[index];
        self.entries[index] = .{ .text = old.text, .frame = frame, .mode = if (old.mode == .pinned) .live else .pinned };
        self.dirty = true;
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
            for (self.items()) |*entry| if (entry.state == .value or entry.state == .failed or entry.state == .not_in_scope) {
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
            if (entry.mode == .live) {
                const selected = self.display_frame orelse {
                    entry.unavailableDisplay(.not_in_scope);
                    continue;
                };
                const identity = ctx.identity(selected.tid) orelse {
                    entry.unavailableDisplay(.not_in_scope);
                    continue;
                };
                const stack = switch (ctx.stack(selected.tid)) {
                    .unavailable => {
                        entry.unavailableDisplay(.stack_unavailable);
                        continue;
                    },
                    .frames => |frames| frames.items,
                };
                if (selected.index >= stack.len) {
                    entry.unavailableDisplay(.not_in_scope);
                    continue;
                }
                entry.frame = FrameId.of(selected.tid, selected.index, stack[selected.index], identity, generation);
                entry.state = .pending;
            }
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
                    entry.ever_resolved = true;
                    entry.failure = null;
                    entry.display.set(v.display);
                    entry.type_name.set(v.type_name);
                    entry.fingerprint = std.hash.Wyhash.hash(std.hash.Wyhash.hash(@intFromBool(v.available), v.type_name), v.display);
                    entry.available = v.available;
                    entry.extent_advisory = v.extent_advisory;
                    entry.expandable = v.expandable;
                    if (!v.expandable) entry.expanded = false;
                    entry.children = v.children;
                    entry.total = v.total;
                    entry.next = v.next;
                },
                .failed => |err| {
                    entry.state = if (entry.mode == .live and entry.ever_resolved and err == error.UnknownVariable) .not_in_scope else .failed;
                    entry.has_value = false;
                    entry.extent_advisory = false;
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
        error.UnknownVariable => "unknown name here",
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

/// Shared single-line editing. Clipboard bytes enter through insert(), never
/// through the key queue; only a physical Return can submit a field.
pub const Editor = struct {
    open: bool = false,
    mode: Mode = .pinned,
    text: Text(max_text) = .{},
    history: [max_history]Text(max_text) = undefined,
    history_count: usize = 0,
    history_at: ?usize = null,
    message: []const u8 = "",
    limit: usize = max_text,
    digits_only: bool = false,
    allow_empty: bool = false,
    history_enabled: bool = true,
    cursor: ?usize = null,
    anchor: ?usize = null,
    epoch: u64 = 0,
    selection_dirty: bool = false,
    dragging: bool = false,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    positions: [max_text + 1]f32 = @splat(0),
    view_start: usize = 0,
    pub const Action = union(enum) { edited, cancel, submit: []const u8 };
    const Window = @import("../platform/wayland.zig").Window;
    const c = @import("../c.zig").api;

    pub fn start(self: *Editor) void {
        self.open = true;
        self.mode = .pinned;
        self.text.len = 0;
        self.history_at = null;
        self.message = "";
        self.limit = max_text;
        self.digits_only = false;
        self.allow_empty = false;
        self.history_enabled = true;
        self.cursor = null;
        self.anchor = null;
        self.epoch +%= 1;
        self.selection_dirty = false;
        self.dragging = false;
        self.bounds.w = 0;
        self.view_start = 0;
    }
    fn at(self: *const Editor) usize {
        return @min(self.cursor orelse self.text.len, self.text.len);
    }
    fn previous(self: *const Editor, pos: usize) usize {
        var n = pos -| 1;
        while (n > 0 and self.text.bytes[n] & 0xc0 == 0x80) n -= 1;
        return n;
    }
    fn next(self: *const Editor, pos: usize) usize {
        var n = @min(pos + 1, self.text.len);
        while (n < self.text.len and self.text.bytes[n] & 0xc0 == 0x80) n += 1;
        return n;
    }
    fn range(self: *const Editor) [2]usize {
        const pos = self.at();
        const a = @min(self.anchor orelse pos, self.text.len);
        return .{ @min(pos, a), @max(pos, a) };
    }
    pub fn selectedText(self: *const Editor) []const u8 {
        const selected = self.range();
        return self.text.bytes[selected[0]..selected[1]];
    }
    fn move(self: *Editor, pos: usize, extend: bool) void {
        if (extend) {
            if (self.anchor == null) self.anchor = self.at();
        } else self.anchor = null;
        self.cursor = pos;
        self.selection_dirty = true;
    }
    fn erase(self: *Editor, from: usize, to: usize) void {
        std.mem.copyForwards(u8, self.text.bytes[from..], self.text.bytes[to..self.text.len]);
        self.text.len -= to - from;
        self.cursor = from;
        self.anchor = null;
        self.history_at = null;
        self.view_start = 0;
        self.selection_dirty = true;
    }
    /// Keeps complete UTF-8 characters, removing controls, format characters
    /// and line separators so pasted text cannot hide or reorder an expression.
    /// The caller's numeric filter and byte limit apply equally to typing/paste.
    pub fn insert(self: *Editor, bytes: []const u8, transfer_truncated: bool) void {
        const selected = self.range();
        var clean: [max_text]u8 = undefined;
        var len: usize = 0;
        var i: usize = 0;
        var removed = false;
        var truncated = transfer_truncated;
        const room = @min(self.limit, max_text) -| (self.text.len - (selected[1] - selected[0]));
        while (i < bytes.len) {
            const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                removed = true;
                i += 1;
                continue;
            };
            if (n > bytes.len - i) {
                removed = true;
                break;
            }
            const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch {
                removed = true;
                i += 1;
                continue;
            };
            const piece = bytes[i..][0..n];
            i += n;
            if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or c.xtext_format(cp) != 0 or cp == 0x2028 or cp == 0x2029 or (self.digits_only and (cp < '0' or cp > '9'))) {
                removed = true;
                continue;
            }
            if (len + n > room) {
                truncated = true;
                break;
            }
            @memcpy(clean[len..][0..n], piece);
            len += n;
        }
        // Empty or wholly refused text must not delete the selection.
        if (len > 0) {
            self.erase(selected[0], selected[1]);
            const pos = self.at();
            std.mem.copyBackwards(u8, self.text.bytes[pos + len ..][0 .. self.text.len - pos], self.text.bytes[pos..self.text.len]);
            @memcpy(self.text.bytes[pos..][0..len], clean[0..len]);
            self.text.len += len;
            self.cursor = pos + len;
        }
        self.message = if (truncated) "Paste/text truncated to field limit" else if (removed) "Controls or invalid characters removed" else "";
    }
    pub fn key(self: *Editor, event: keys.Event) ?Action {
        if (!self.open or (event.kind != .press and event.kind != .repeat)) return null;
        // Function keys remain available while editing.
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return null;
        switch (event.shortcut) {
            keys.sym.escape => {
                self.open = false;
                self.dragging = false;
                return .cancel;
            },
            0xff51, 0xff53, 0xff50, 0xff57 => {
                const selected = self.range();
                const pos = switch (event.shortcut) {
                    0xff50 => 0,
                    0xff57 => self.text.len,
                    0xff51 => if (!event.mods.shift and selected[0] != selected[1]) selected[0] else self.previous(self.at()),
                    else => if (!event.mods.shift and selected[0] != selected[1]) selected[1] else self.next(self.at()),
                };
                self.move(pos, event.mods.shift);
                return .edited;
            },
            0xff08, 0xffff => {
                var selected = self.range();
                if (selected[0] == selected[1]) {
                    if (event.shortcut == 0xff08) selected[0] = self.previous(selected[0]) else selected[1] = self.next(selected[1]);
                }
                self.erase(selected[0], selected[1]);
                self.message = "";
                return .edited;
            },
            0xff0d, 0xff8d => {
                const value = std.mem.trim(u8, self.text.slice(), " \t");
                if (value.len == 0 and !self.allow_empty) return .edited;
                if (value.len > 0 and self.history_enabled) self.remember(value);
                return .{ .submit = self.text.slice() };
            },
            keys.sym.up, keys.sym.down => {
                if (self.history_enabled) self.recall(event.shortcut == keys.sym.up);
                return .edited;
            },
            else => {},
        }
        if (event.mods.ctrl and event.shortcut == 'u') {
            self.erase(0, self.text.len);
            self.message = "";
            return .edited;
        }
        if (event.plain() and event.text().len > 0) self.insert(event.text(), false);
        return .edited;
    }
    /// Bind a completion to this exact field opening. Leaving it (including
    /// window focus loss) closes its pipe and discards any pending result.
    pub fn focus(w: *Window, editor: ?*Editor) void {
        const e = if (w.input.focused) editor else null;
        if (!w.input.focused) if (editor) |v| {
            v.dragging = false;
            if (std.mem.eql(u8, v.message, "Pasting...")) {
                v.message = "Paste cancelled (focus changed)";
                w.dirty = true;
            }
        };
        c.xclip_focus(w.clipboard, if (e) |v| @intFromPtr(v) else 0, if (e) |v| v.epoch else 0);
        if (e) |v| {
            if (v.dragging) {
                if (w.mouse_down) {
                    const pos = v.position(w.pointer_x);
                    if (pos != v.at()) {
                        v.move(pos, true);
                        w.dirty = true;
                    }
                }
            }
            var result: c.xclip_result = undefined;
            if (c.xclip_take(w.clipboard, &result) and result.destination == @intFromPtr(v) and result.epoch == v.epoch) {
                switch (result.status) {
                    c.XCLIP_READY, c.XCLIP_TRUNCATED => v.insert(result.bytes[0..result.size], result.status == c.XCLIP_TRUNCATED),
                    c.XCLIP_TIMEOUT => v.message = "Paste timed out; field unchanged",
                    c.XCLIP_UNAVAILABLE => v.message = "Clipboard has no plain text",
                    else => v.message = "Paste failed; field unchanged",
                }
                if (w.input.trace) std.debug.print("editor clipboard result={d} bytes={d} field_bytes={d} cursor={d}\n", .{ result.status, result.size, v.text.len, v.at() });
                w.dirty = true;
            } else if (!c.xclip_pending(w.clipboard) and std.mem.eql(u8, v.message, "Pasting...")) {
                v.message = "Paste cancelled (focus changed)";
                w.dirty = true;
            }
            if (v.selection_dirty) {
                v.selection_dirty = false;
                const selected = v.selectedText();
                if (selected.len > 0) _ = c.xclip_copy(w.clipboard, true, w.last_input_serial, selected.ptr, selected.len);
            }
        }
    }
    fn inside(self: *const Editor, x: f32, y: f32) bool {
        return x >= self.bounds.x and x < self.bounds.x + self.bounds.w and y >= self.bounds.y and y < self.bounds.y + self.bounds.h;
    }
    fn position(self: *const Editor, x: f32) usize {
        var pos = self.view_start;
        while (pos < self.text.len) {
            const n = self.next(pos);
            if (x < (self.positions[pos] + self.positions[n]) / 2) return pos;
            pos = n;
        }
        return self.text.len;
    }
    /// Handles only field-local clipboard and pointer selection events.
    pub fn clipboard(self: *Editor, w: *Window, event: keys.Event) bool {
        if (!self.open or !w.input.focused) return false;
        if (event.kind == .button_release and event.code == 272 and self.dragging) {
            self.move(self.position(event.x), true);
            self.dragging = false;
            w.dirty = true;
            return true;
        }
        if (event.kind == .button_press and self.inside(event.x, event.y)) {
            if (event.code == 272) {
                self.move(self.position(event.x), event.mods.shift);
                if (self.anchor == null) self.anchor = self.at();
                self.dragging = true;
                w.dirty = true;
                return true;
            }
            if (event.code == 274) {
                const status = c.xclip_request(w.clipboard, true);
                // An absent primary-selection protocol must not move the
                // cursor or cancel another transfer.
                if (status == c.XCLIP_IDLE) return true;
                if (status == c.XCLIP_UNAVAILABLE) {
                    var ignored: c.xclip_result = undefined;
                    _ = c.xclip_take(w.clipboard, &ignored);
                    return true;
                }
                if (status == c.XCLIP_PENDING or status == c.XCLIP_READY or status == c.XCLIP_TRUNCATED) self.move(self.position(event.x), false);
                w.dirty = true;
                return true;
            }
        }
        if ((event.kind != .press and event.kind != .repeat) or !event.mods.ctrl or event.mods.alt or event.mods.logo) return false;
        if (event.shortcut == 'v') {
            if (event.kind == .press) {
                const status = c.xclip_request(w.clipboard, false);
                if (status == c.XCLIP_PENDING) self.message = "Pasting...";
                w.dirty = true;
            }
            return true;
        }
        if (event.shortcut == 'c') {
            if (event.kind == .press) {
                const selected = self.selectedText();
                const bytes = if (selected.len > 0) selected else self.text.slice();
                self.message = if (c.xclip_copy(w.clipboard, false, w.last_input_serial, bytes.ptr, bytes.len)) "Copied text" else "Clipboard unavailable";
                w.dirty = true;
            }
            return true;
        }
        return false;
    }
    pub fn draw(self: *Editor, r: *gpu.Renderer, font: *Font, bounds: gpu.Rect) !void {
        self.bounds = bounds;
        const clip = r.clip;
        defer r.clip = clip;
        r.clip = .{ .x = @max(bounds.x, clip.x), .y = @max(bounds.y, clip.y), .w = 0, .h = 0 };
        r.clip.w = @max(0, @min(bounds.x + bounds.w, clip.x + clip.w) - r.clip.x);
        r.clip.h = @max(0, @min(bounds.y + bounds.h, clip.y + clip.h) - r.clip.y);
        const block = @import("../appearance.zig").active.block_selection;
        const cell = if (block) r.measure(font, " ") else 1;
        const pos = self.at();
        self.view_start = @min(self.view_start, pos);
        while (self.view_start < pos and r.measure(font, self.text.bytes[self.view_start..pos]) > bounds.w - (if (block) cell + 2 else 3)) self.view_start = self.next(self.view_start);
        var i = self.view_start;
        while (true) {
            self.positions[i] = bounds.x + r.measure(font, self.text.bytes[self.view_start..i]);
            if (i == self.text.len) break;
            i = self.next(i);
        }
        const selected = self.range();
        if (selected[0] != selected[1] and selected[1] > self.view_start) {
            const x = self.positions[@max(self.view_start, selected[0])];
            try r.rect(.{ .x = x, .y = bounds.y, .w = self.positions[selected[1]] - x, .h = bounds.h }, style.fade(theme.focus, 0.35));
        }
        try r.text(font, bounds.x, bounds.y, self.text.bytes[self.view_start..self.text.len], theme.text);
        if (block) {
            try r.rect(.{ .x = @round(self.positions[pos]), .y = @round(bounds.y + 2), .w = cell, .h = 16 }, theme.focus);
            // The shared editor can insert in the middle after a click/paste.
            // Keep the character under the block readable in the panel color.
            if (pos < self.text.len) try r.text(font, self.positions[pos], bounds.y, self.text.bytes[pos..self.next(pos)], theme.surface);
        } else try r.rect(.{ .x = self.positions[pos], .y = bounds.y, .w = 1, .h = bounds.h }, theme.focus);
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
        const index: usize = if (self.history_at) |p| (if (older) @min(p + 1, kept - 1) else p -| 1) else if (older) 0 else return;
        if (!older and self.history_at != null and self.history_at.? == 0) {
            self.history_at = null;
            self.text.len = 0;
        } else {
            self.history_at = index;
            self.text = self.history[(self.history_count - 1 - index) % max_history];
        }
        self.cursor = null;
        self.anchor = null;
        self.view_start = 0;
        self.selection_dirty = true;
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
            break :blk if (entry.resolved_index) |i| std.fmt.bufPrint(buffer, "{s}{s}#{d} {s}", .{ tid, if (entry.mode == .live) "selected " else if (entry.unverified) "CFA match " else if (!entry.frame.persistent()) "stop only " else "", i, name }) catch "" else std.fmt.bufPrint(buffer, "{s}{s}", .{ tid, name }) catch "";
        },
    };
}

/// Rows: the open editor, then entries and expanded children. Keeps the
/// selected entry in view. Returns per-row entry indices for hit testing.
pub fn draw(list: *WatchList, editor: *Editor, r: *gpu.Renderer, font: *Font, rect: gpu.Rect, hits: *[64]?usize) !void {
    const row_h: f32 = 23;
    var y = rect.y + 8;
    const x = rect.x + 12;
    const w = rect.w - 24;
    for (hits) |*h| h.* = null;
    if (editor.open) {
        try r.shape(.{ .x = rect.x + 6, .y = y - 3, .w = rect.w - 12, .h = row_h + 2 }, style.fade(theme.focus, 0.18), .{ .radii = @splat(5) });
        try editor.draw(r, font, .{ .x = x, .y = y, .w = w, .h = row_h });
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
    if (list.selected) |selected| if (list.entries[selected].extent_advisory and list.entries[selected].has_value) {
        try r.textFit(font, x, y, w, "Extent unproved / dimmed preview", theme.weak);
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
    for (rows[list.first_row..n], 0..) |row, k| {
        if (k >= visible or k >= hits.len) break;
        hits[k] = row.entry;
        const entry = &list.entries[row.entry];
        const type_w: f32 = if (w > 560 and entry.state == .value) 150 else 0;
        const ry = y + @as(f32, @floatFromInt(k)) * row_h;
        if (row.child) |c| {
            var buffer: [320]u8 = undefined;
            const text = if (c < entry.children.len)
                std.fmt.bufPrint(&buffer, "    {s} = {s}", .{ entry.children[c].name, entry.children[c].display }) catch ""
            else if (entry.next) |next|
                std.fmt.bufPrint(&buffer, "    {d}..{d} of {d}; PgDn more", .{ entry.page, next, entry.total orelse next }) catch ""
            else
                std.fmt.bufPrint(&buffer, "    {d} item{s}", .{ entry.total orelse entry.children.len, if ((entry.total orelse entry.children.len) == 1) "" else "s" }) catch "";
            try r.textFit(font, x, ry, w, text, if (c < entry.children.len and !entry.children[c].extent_advisory) theme.text else theme.weak);
            continue;
        }
        if (list.selected != null and list.selected.? == row.entry) try style.focus(r, .{ .x = rect.x + 4, .y = ry - 3, .w = rect.w - 8, .h = row_h }, 6, 1);
        var tag_buffer: [160]u8 = undefined;
        const tag = frameTag(&tag_buffer, entry, w > 560);
        const tag_w = if (w > 560) @min(r.measure(font, tag), w * 0.35) else 0;
        var expression_buffer: [max_text + 8]u8 = undefined;
        const expr = if (entry.mode == .live) std.fmt.bufPrint(&expression_buffer, "~ {s}", .{entry.expression()}) catch entry.expression() else entry.expression();
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
            .not_in_scope => .{ "not in scope here", theme.weak },
            .stale => .{ if (!entry.has_value) "stale: running" else std.fmt.bufPrint(&value_buffer, "stale: running / {s}", .{entry.display.slice()}) catch "stale: running", theme.weak },
            .frame_gone => .{ if (entry.has_value) std.fmt.bufPrint(&value_buffer, "frame gone; last seen {s}", .{entry.display.slice()}) catch "" else "frame gone", theme.warm },
            .thread_gone => .{ "thread gone", theme.warm },
            .context_changed => .{ "frame identity changed; re-add", theme.warm },
            .stack_unavailable => .{ "stack unavailable; value not refreshed", theme.warm },
        };
        if (entry.changed and entry.state == .value) try r.shape(.{ .x = value_x - 4, .y = ry - 2, .w = @min(value_w, r.measure(font, value) + 8), .h = row_h - 2 }, theme.fresh, .{ .radii = @splat(5) });
        try r.textFit(font, value_x, ry, value_w, value, if (entry.extent_advisory) theme.weak else if (entry.changed and entry.state == .value) theme.warm else color);
        if (type_w > 0 and entry.state == .value) try r.textFit(font, x + w - tag_w - 12 - type_w, ry, type_w - 8, entry.type_name.slice(), theme.weak);
        if (tag_w > 0) try r.textFit(font, x + w - tag_w, ry, tag_w, tag, if (entry.state == .frame_gone or entry.state == .thread_gone or entry.state == .context_changed or entry.state == .stack_unavailable or entry.unverified) theme.warm else theme.weak);
    }
}
