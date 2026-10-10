//! Runtime metadata, candidate storage and typed values; all decoding stays in C.
const std = @import("std");
const c = @import("../c.zig").api;
const gpu = @import("../render/vulkan.zig");
const Font = @import("../render/font.zig").Font;
const keys = @import("../platform/input.zig");
const Session = @import("../model/session.zig").Session;
const cache = @import("../model/runtime_types.zig");
const instances = @import("../model/runtime_instances.zig");
const values = @import("../model/runtime_values.zig");
const style = @import("style.zig");
const theme = style.theme;
const Editor = @import("watch.zig").Editor;
const Focus = enum { types, items, value };
const Editing = enum { load, filter, address, search, container, write };
const SearchKey = struct { id: u64, count: usize, start: usize };
const Hit = struct { address: ?u64, type_index: u32, slot: u64, reason: ?[]const u8 };
fn text(g: *const c.struct_xjai_graph, offset: u32) []const u8 {
    return std.mem.span(g.text + offset);
}
fn number(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 0) catch error.ExpectedNumber;
}
fn typeSelector(g: *const c.struct_xjai_graph, name: []const u8) !u32 {
    if (std.mem.startsWith(u8, name, "0x")) {
        const index = c.xjai_type_at(g, try number(name));
        return if (index == c.XJAI_NONE) error.RuntimeTypeNotFound else index;
    }
    var found: ?u32 = null;
    for (g.types[0..g.type_count], 0..) |t, i| if (std.mem.eql(u8, text(g, t.name), name)) {
        if (found != null) return error.RuntimeTypeAmbiguous;
        found = @intCast(i);
    };
    return found orelse error.RuntimeTypeNotFound;
}
const hint = "L load   / filter   G address   S search   O container   W write   Shift+U undo   T context   Tab focus";
pub const Panel = struct {
    open: bool = false,
    editor: Editor = .{},
    editing: Editing = .filter,
    message: []const u8 = hint,
    context_id: ?u64 = null,
    selected_type: u32 = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    focus: Focus = .types,
    type_scroll: usize = 0,
    type_hits: [64]?u32 = @splat(null),
    item_hits: [64]?usize = @splat(null),
    item_start: usize = 0,
    item_selected: usize = 0,
    item_scroll: usize = 0,
    items_reason: ?[]const u8 = null,
    items: [64]Hit = undefined,
    item_count: usize = 0,
    item_total: u64 = 0,
    item_kind: enum { none, search, container } = .none,
    container_address: u64 = 0,
    container_type: u32 = 0,
    search_seen: ?SearchKey = null,
    value_rows: ?*c.struct_xjai_values = null,
    value_type: u32 = 0,
    value_address: u64 = 0,
    value_generation: u64 = 0,
    value_scroll: usize = 0,
    value_start: u64 = 0,
    bounds: gpu.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    divider: f32 = 0,
    value_top: f32 = 0,
    pub fn deinit(self: *Panel) void {
        self.clearValue();
    }
    fn clearValue(self: *Panel) void {
        if (self.value_rows) |v| c.xjai_values_free(v);
        self.value_rows = null;
        self.value_scroll = 0;
    }
    pub fn show(self: *Panel) void {
        self.open = true;
        self.message = hint;
    }
    fn entry(self: *Panel, session: *Session) !cache.Entry {
        if (self.context_id == null) {
            for (session.runtime_types.entries) |maybe| if (maybe) |e| {
                if (self.context_id == null or e.id > self.context_id.?) self.context_id = e.id;
            };
        }
        return session.runtime_types.find(self.context_id orelse return error.LoadRuntimeTypesFirst);
    }
    fn matches(self: *const Panel, g: *const c.struct_xjai_graph, index: u32) bool {
        if (std.mem.startsWith(u8, self.filter[0..self.filter_len], "0x")) {
            const address = std.fmt.parseInt(u64, self.filter[0..self.filter_len], 0) catch return false;
            return g.types[index].address == address;
        }
        return self.filter_len == 0 or std.ascii.indexOfIgnoreCase(text(g, g.types[index].name), self.filter[0..self.filter_len]) != null;
    }
    fn selectValid(self: *Panel, g: *const c.struct_xjai_graph) void {
        if (self.selected_type < g.type_count and self.matches(g, self.selected_type)) return;
        for (0..g.type_count) |i| if (self.matches(g, @intCast(i))) {
            self.selected_type = @intCast(i);
            return;
        };
        self.selected_type = c.XJAI_NONE;
    }
    fn moveType(self: *Panel, g: *const c.struct_xjai_graph, delta: i32) void {
        var index: i64 = if (self.selected_type == c.XJAI_NONE) 0 else self.selected_type;
        var left: u32 = @intCast(@abs(delta));
        while (left != 0) {
            index += if (delta < 0) @as(i64, -1) else 1;
            if (index < 0 or index >= g.type_count) break;
            if (self.matches(g, @intCast(index))) {
                self.selected_type = @intCast(index);
                left -= 1;
            }
        }
    }
    pub fn wheel(self: *Panel, session: *Session, amount: i32) void {
        const e = self.entry(session) catch return;
        const g = e.graph() catch return;
        switch (self.focus) {
            .types => self.moveType(g, amount),
            .items => self.item_selected = @intCast(@max(0, @min(@as(i64, @intCast(self.item_count)) - 1, @as(i64, @intCast(self.item_selected)) + amount))),
            .value => self.value_scroll = @intCast(@max(0, @min(255, @as(i64, @intCast(self.value_scroll)) + amount))),
        }
    }
    pub fn busy(self: *Panel, session: *Session) bool {
        if (!self.open) return false;
        const e = self.entry(session) catch return false;
        if (e.poll().state == c.XJAI_JOB_PENDING) return true;
        return self.item_kind == .search and session.memory.search != null and session.memory.search.?.state == .running;
    }
    pub fn press(self: *Panel, session: *Session, x: f32, y: f32) void {
        const b = self.bounds;
        if (x < b.x or x > b.x + b.w or y < b.y or y > b.y + b.h) {
            self.open = false;
            return;
        }
        if (self.editor.open or y < b.y + 96 or y >= b.y + b.h - 84) return;
        if (x < self.divider) {
            self.focus = .types;
            const row: usize = @intFromFloat((y - b.y - 96) / 23);
            if (row < self.type_hits.len) {
                if (self.type_hits[row]) |index| self.selected_type = index;
            }
        } else if (y < self.value_top) {
            self.focus = .items;
            const row: usize = @intFromFloat((y - b.y - 96) / 23);
            if (row < self.item_hits.len) if (self.item_hits[row]) |index| {
                self.item_selected = index;
                self.openItem(session) catch |err| {
                    self.message = @errorName(err);
                };
            };
        } else self.focus = .value;
    }
    fn edit(self: *Panel, mode: Editing) void {
        self.editing = mode;
        self.editor.start();
        self.message = switch (mode) {
            .write => "Write the open typed value: FIELD_PATH VALUE; Return writes, Esc cancels. Shift+U undoes.",
            .load => "Read-only metadata range: ADDRESS LENGTH (hex or decimal)",
            .filter => "Filter type names or an exact 0x type-record address; empty shows all",
            .address => "Address to read as the selected type",
            .container => "Address of the selected Bucket or array; O lists occupied storage",
            .search => "Search: ADDRESS LENGTH DIRECT_TYPE_FIELD [DERIVED_NAME_OR_ADDRESS]",
        };
    }
    pub fn key(self: *Panel, session: *Session, event: keys.Event) bool {
        if (!self.open) return false;
        if (event.kind != .press and event.kind != .repeat) return true;
        if (self.editor.open) {
            if (self.editor.key(event)) |action| switch (action) {
                .edited => {},
                .cancel => self.message = hint,
                .submit => |input| {
                    self.submit(session, input) catch |err| {
                        self.message = @errorName(err);
                        return true;
                    };
                    self.editor.open = false;
                },
            };
            return true;
        }
        if (event.shortcut >= 0xffbe and event.shortcut <= 0xffc9) return false;
        if (!event.plain()) return true;
        const k = event.shortcut;
        if (k == keys.sym.escape or k == 'y') {
            self.open = false;
            return true;
        }
        if (k == keys.sym.space) return false;
        if (k == keys.sym.tab) {
            self.focus = @enumFromInt((@intFromEnum(self.focus) + 1) % 3);
            return true;
        }
        if (k == keys.sym.up or k == keys.sym.down or k == 0xff55 or k == 0xff56) {
            self.wheel(session, if (k == keys.sym.up) -1 else if (k == keys.sym.down) 1 else if (k == 0xff55) -12 else 12);
            return true;
        }
        if (event.kind == .repeat) return true;
        if (k == 'l' or k == '/' or k == 'g' or k == 's' or k == 'o' or k == 'w') {
            self.edit(if (k == 'l') .load else if (k == '/') .filter else if (k == 'g') .address else if (k == 's') .search else if (k == 'w') .write else .container);
        } else if (k == 'u' and event.mods.shift) {
            const result = session.runtime_writes.undo(session, .human, session.target.snapshot().generation, session.runtime_writes.last(session), false) catch |err| {
                self.message = @errorName(err);
                return true;
            };
            self.message = @import("../model/runtime_writes.zig").reason(result.value.reason) orelse "Undo verified; original bytes restored";
        } else if (k == 't') {
            var next: ?u64 = null;
            var first: ?u64 = null;
            for (session.runtime_types.entries) |maybe| if (maybe) |e| {
                if (first == null or e.id < first.?) first = e.id;
                if (e.id > (self.context_id orelse 0) and (next == null or e.id < next.?)) next = e.id;
            };
            self.context_id = next orelse first;
            self.selected_type = 0;
            self.item_kind = .none;
            self.items_reason = null;
            self.item_count = 0;
            self.clearValue();
        } else if (k == 'x') {
            if (session.runtime_instances.query) |query| session.memory.cancelSearch(query.id, .{}) catch |err| {
                self.message = @errorName(err);
            };
        } else if (k == '[' or k == ']') {
            if (self.focus == .value) {
                self.pageValue(session, k == ']') catch |err| {
                    self.message = @errorName(err);
                };
            } else {
                self.item_start = if (k == '[') self.item_start -| 64 else if (self.item_start + 64 < self.item_total) self.item_start + 64 else self.item_start;
                self.item_selected = 0;
                self.item_scroll = 0;
                self.search_seen = null;
                if (self.item_kind == .container) self.readContainer(session) catch |err| {
                    self.message = @errorName(err);
                };
            }
        } else if (k == 0xff0d) self.openItem(session) catch |err| {
            self.message = @errorName(err);
        };
        return true;
    }
    fn submit(self: *Panel, session: *Session, input: []const u8) !void {
        if (self.editing == .filter) {
            if (input.len > self.filter.len) return error.FilterTooLong;
            @memcpy(self.filter[0..input.len], input);
            self.filter_len = input.len;
            self.selected_type = c.XJAI_NONE;
            self.type_scroll = 0;
            self.focus = .types;
            self.message = hint;
            return;
        }
        if (self.editing == .write) {
            const e = try self.entry(session);
            try e.requireStop(session);
            if (self.value_rows == null) return error.OpenTypedValueFirst;
            const clean = std.mem.trim(u8, input, " \t");
            const split = std.mem.indexOfAny(u8, clean, " \t") orelse return error.ExpectedFieldAndValue;
            const value = std.mem.trim(u8, clean[split..], " \t");
            const result = try session.runtime_writes.apply(session, .human, session.target.snapshot().generation, e, self.value_type, self.value_address, clean[0..split], value, false);
            self.message = @import("../model/runtime_writes.zig").reason(result.value.reason) orelse "Write verified; Shift+U restores the original bytes";
            return;
        }
        var tokens = std.mem.tokenizeAny(u8, input, " \t");
        const address = try number(tokens.next() orelse return error.ExpectedAddress);
        if (self.editing == .load) {
            const length = try number(tokens.next() orelse return error.ExpectedLength);
            if (tokens.next() != null or length == 0 or length > @import("../model/memory.zig").max_snapshot) return error.InvalidMemoryRange;
            const capture = try session.memory.capture(session, address, @intCast(length));
            self.context_id = try session.runtime_types.load(session, &.{capture}, .{});
            self.selected_type = c.XJAI_NONE;
            self.item_kind = .none;
            self.items_reason = null;
            self.item_count = 0;
            self.clearValue();
            self.message = "Discovering read-only runtime types";
            return;
        }
        const e = try self.entry(session);
        try e.requireStop(session);
        const g = try e.graph();
        self.selectValid(g);
        if (self.selected_type >= g.type_count) return error.SelectRuntimeType;
        if (self.editing == .search) {
            const length = try number(tokens.next() orelse return error.ExpectedLength);
            if (length == 0 or length > @import("../model/memory.zig").max_search) return error.InvalidMemoryRange;
            const member = try instances.selfField(g, self.selected_type, tokens.next() orelse return error.ExpectedTypeField);
            const needle = if (tokens.next()) |t| try typeSelector(g, t) else self.selected_type;
            if (tokens.next() != null) return error.TooManyArguments;
            _ = try session.runtime_instances.beginOwned(session, e, self.selected_type, needle, member, address, @intCast(length), .{});
            self.item_kind = .search;
            self.items_reason = null;
            self.item_start = 0;
            self.item_selected = 0;
            self.search_seen = null;
            self.focus = .items;
            self.message = "Type-pointer candidates; allocation lifetime is unproved. X cancels, Return opens.";
        } else {
            if (tokens.next() != null) return error.TooManyArguments;
            if (self.editing == .container) {
                self.container_address = address;
                self.container_type = self.selected_type;
                self.item_kind = .container;
                self.item_start = 0;
                self.item_selected = 0;
                self.focus = .items;
                try self.readContainer(session);
            } else try self.readValue(session, self.selected_type, address);
        }
    }
    fn readValue(self: *Panel, session: *Session, index: u32, address: u64) !void {
        return self.readValuePage(session, index, address, 0);
    }
    fn pageValue(self: *Panel, session: *Session, forward: bool) !void {
        const v = self.value_rows orelse return error.SelectAggregateValue;
        const e = try self.entry(session);
        const g = try e.graph();
        if (self.value_type >= g.type_count or (g.types[self.value_type].tag != 7 and g.types[self.value_type].tag != 8)) return error.SelectAggregateValue;
        const total = v.rows[0].total_count;
        const next = if (!forward) self.value_start -| 16 else if (self.value_start + 16 < total) self.value_start + 16 else self.value_start;
        try self.readValuePage(session, self.value_type, self.value_address, next);
    }
    fn readValuePage(self: *Panel, session: *Session, index: u32, address: u64, start: u64) !void {
        self.clearValue();
        const e = try self.entry(session);
        try e.requireStop(session);
        const g = try e.graph();
        var context = instances.Reader{ .session = session };
        var reader = context.reader();
        const options = c.struct_xjai_value_options{ .depth = 3, .limit = 16, .start = start, .follow_pointers = 0 };
        var result: ?*c.struct_xjai_values = null;
        if (c.xjai_value_read(g, index, address, &options, &reader, &result)) |why| {
            self.message = std.mem.span(why);
            return;
        }
        errdefer c.xjai_values_free(result.?);
        try e.requireStop(session);
        self.value_rows = result;
        self.value_start = start;
        self.value_type = index;
        self.value_address = address;
        self.value_generation = e.generation;
        self.focus = .value;
        self.message = "Typed storage at this stop; [ / ] page root fields, arrows scroll. Pointers are not followed.";
    }
    fn openItem(self: *Panel, session: *Session) !void {
        if (self.item_selected >= self.item_count) return error.SelectCandidate;
        const item = self.items[self.item_selected];
        if (item.reason) |why| {
            self.message = why;
            return;
        }
        try self.readValue(session, item.type_index, item.address orelse return error.CandidateUnavailable);
    }
    fn readContainer(self: *Panel, session: *Session) !void {
        self.item_count = 0;
        self.item_total = 0;
        self.items_reason = "Container read unavailable";
        const e = try self.entry(session);
        try e.requireStop(session);
        const g = try e.graph();
        var context = instances.Reader{ .session = session };
        var reader = context.reader();
        var rows: [64]c.struct_xjai_container_row = undefined;
        var page: c.struct_xjai_container_page = undefined;
        const why = c.xjai_container_read(g, self.container_type, self.container_address, self.item_start, &rows, rows.len, &reader, &page);
        try e.requireStop(session);
        if (why != null) {
            self.message = std.mem.span(why);
            self.items_reason = self.message;
            return;
        }
        self.items_reason = null;
        for (rows[0..page.count], 0..) |row, i| self.items[i] = .{ .address = row.address, .type_index = row.type, .slot = row.slot, .reason = null };
        self.item_count = page.count;
        self.item_total = page.total_count;
        self.message = "Occupied container storage; lifetime unproved. Return opens, [ / ] page.";
    }
    fn updateItems(self: *Panel, session: *Session, e: cache.Entry, g: *const c.struct_xjai_graph) void {
        if (e.stale(session) or session.target.snapshot().state != .stopped) {
            self.item_count = 0;
            self.items_reason = "Runtime types stale; load metadata at the new stop";
            self.clearValue();
            return;
        }
        if (self.item_kind == .none) {
            self.items_reason = null;
            self.item_count = 0;
            self.item_total = 0;
            return;
        }
        if (self.item_kind != .search) return;
        const query = session.runtime_instances.query orelse return;
        if (query.context_id != e.id) {
            self.item_count = 0;
            return;
        }
        _ = session.runtime_instances.find(session, query.id) catch |err| {
            self.item_count = 0;
            self.items_reason = @errorName(err);
            self.message = @errorName(err);
            return;
        };
        const search = &session.memory.search.?;
        const key_value: SearchKey = .{ .id = query.id, .count = search.count, .start = self.item_start };
        if (self.search_seen) |seen| if (std.meta.eql(seen, key_value)) return;
        const page = session.runtime_instances.page(session, query.id, self.item_start, 64) catch |err| {
            self.item_count = 0;
            self.items_reason = @errorName(err);
            self.message = @errorName(err);
            return;
        };
        for (page.rows[0..page.count], 0..) |row, i| self.items[i] = .{ .address = row.address, .type_index = if (row.type_address) |at| c.xjai_type_at(g, at) else c.XJAI_NONE, .slot = self.item_start + i, .reason = row.reason };
        self.item_count = page.count;
        self.items_reason = null;
        self.item_total = search.count;
        self.search_seen = key_value;
    }
    pub fn draw(self: *Panel, r: *gpu.Renderer, font: *Font, width: f32, height: f32, session: *Session) !void {
        if (!self.open) return;
        self.bounds = .{ .x = 20, .y = 96, .w = @max(0, width - 40), .h = @max(0, height - 136) };
        const b = self.bounds;
        self.divider = b.x + b.w * 0.4;
        self.value_top = b.y + @max(184, @min(270, b.h * 0.4));
        try r.rect(.{ .x = 0, .y = 84, .w = width, .h = @max(0, height - 110) }, theme.overlay);
        try style.box(r, b, theme.surface, theme.focus, @splat(8));
        try r.textFit(font, b.x + 14, b.y + 10, b.w - 28, "RUNTIME TYPES / Jai    Y or Esc close", theme.text);
        try r.textFit(font, b.x + 14, b.y + 36, b.w - 28, hint, theme.weak);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const e = self.entry(session) catch |err| {
            try r.textFit(font, b.x + 14, b.y + 70, b.w - 28, if (err == error.LoadRuntimeTypesFirst) "No type metadata. L loads a read-only address range; text input works before a stop." else @errorName(err), theme.warm);
            try self.footer(r, font, b);
            return;
        };
        const stale = e.stale(session) or session.target.snapshot().state != .stopped;
        const title = try std.fmt.allocPrint(a, "Context {d}  / stop {d}  / {s}  / focus: {s}", .{ e.id, e.generation, if (stale) "STALE: use L at a new stop" else "stopped", @tagName(self.focus) });
        try r.textFit(font, b.x + 14, b.y + 64, b.w - 28, title, if (stale) theme.warm else theme.weak);
        const g = e.graph() catch |err| {
            try r.textFit(font, b.x + 14, b.y + 98, b.w - 28, @errorName(err), theme.warm);
            try self.footer(r, font, b);
            return;
        };
        if (std.mem.eql(u8, self.message, "Discovering read-only runtime types")) self.message = hint;
        if (!stale and self.value_rows != null and self.value_generation != e.generation) {
            const message = self.message;
            self.readValuePage(session, self.value_type, self.value_address, self.value_start) catch |err| {
                self.message = @errorName(err);
            };
            if (self.value_rows != null) self.message = message;
        }
        self.selectValid(g);
        self.updateItems(session, e, g);
        self.type_hits = @splat(null);
        self.item_hits = @splat(null);
        const visible: usize = @min(64, @as(usize, @intFromFloat(@max(0, (b.h - 188) / 23))));
        var ordinal: usize = 0;
        var selected_ordinal: usize = 0;
        for (0..g.type_count) |i| if (self.matches(g, @intCast(i))) {
            if (i == self.selected_type) selected_ordinal = ordinal;
            ordinal += 1;
        };
        if (selected_ordinal < self.type_scroll) self.type_scroll = selected_ordinal;
        if (visible != 0 and selected_ordinal >= self.type_scroll + visible) self.type_scroll = selected_ordinal - visible + 1;
        ordinal = 0;
        for (g.types[0..g.type_count], 0..) |t, i| {
            if (!self.matches(g, @intCast(i))) continue;
            const position = ordinal;
            ordinal += 1;
            if (position < self.type_scroll or position >= self.type_scroll + visible) continue;
            const row = position - self.type_scroll;
            self.type_hits[row] = @intCast(i);
            const y = b.y + 96 + @as(f32, @floatFromInt(row)) * 23;
            if (i == self.selected_type) try r.rect(.{ .x = b.x + 8, .y = y - 2, .w = self.divider - b.x - 16, .h = 23 }, style.fade(theme.focus, 0.22));
            var count: ?usize = null;
            if (session.runtime_instances.query) |q| if (q.context_id == e.id and q.needle == i and session.memory.search != null and session.memory.search.?.id == q.id) {
                count = session.memory.search.?.count;
            };
            const label = if (count) |n| try std.fmt.allocPrint(a, "{s}  [{d} candidate hits{s}]", .{ text(g, t.name), n, if (stale) "; stale" else "" }) else try std.fmt.allocPrint(a, "{s}  @0x{x}", .{ if (text(g, t.name).len == 0) "(unnamed type)" else text(g, t.name), t.address });
            try r.textFit(font, b.x + 14, y, self.divider - b.x - 28, label, if (t.reason != null) theme.warm else theme.text);
        }
        if (ordinal == 0) try r.textFit(font, b.x + 14, b.y + 96, self.divider - b.x - 28, "No matching types; / changes filter", theme.weak);
        const right = self.divider + 12;
        const right_width = b.x + b.w - right - 14;
        const item_visible: usize = @min(64, @as(usize, @intFromFloat(@max(0, (self.value_top - b.y - 112) / 23))));
        self.item_selected = @min(self.item_selected, self.item_count -| 1);
        if (self.item_selected < self.item_scroll) self.item_scroll = self.item_selected;
        if (item_visible != 0 and self.item_selected >= self.item_scroll + item_visible) self.item_scroll = self.item_selected - item_visible + 1;
        const item_end = @min(self.item_count, self.item_scroll + item_visible);
        for (self.items[@min(self.item_scroll, self.item_count)..item_end], self.item_scroll..) |item, i| {
            self.item_hits[i - self.item_scroll] = i;
            const y = b.y + 96 + @as(f32, @floatFromInt(i - self.item_scroll)) * 23;
            if (i == self.item_selected) try r.rect(.{ .x = right - 4, .y = y - 2, .w = right_width + 4, .h = 23 }, style.fade(theme.focus, 0.18));
            const label = if (item.reason) |why| try std.fmt.allocPrint(a, "Candidate {d}: {s}", .{ item.slot, why }) else try std.fmt.allocPrint(a, "{s} {d}: 0x{x}", .{ if (self.item_kind == .container) "Occupied slot" else "Candidate", item.slot, item.address.? });
            try r.textFit(font, right, y, right_width, label, if (item.reason != null) theme.warm else theme.text);
        }
        if (self.item_count == 0) try r.textFit(font, right, b.y + 96, right_width, "S searches candidates; O lists occupied container slots", theme.weak);
        const item_type = if (self.item_kind == .container) self.container_type else if (session.runtime_instances.query) |q| q.needle else c.XJAI_NONE;
        const item_name = if (item_type < g.type_count) text(g, g.types[item_type].name) else "";
        const item_label = if (self.items_reason) |why| try std.fmt.allocPrint(a, "Unavailable: {s}", .{why}) else if (self.item_kind == .none) "No instance search yet; counts unmeasured" else try std.fmt.allocPrint(a, "{s} {d}+{d}/{d} / Lifetime unproved / {s}", .{ if (self.item_kind == .container) "Slots" else "Candidates", self.item_start, self.item_count, self.item_total, item_name });
        try r.textFit(font, right, self.value_top - 24, right_width, item_label, theme.warm);
        if (self.value_rows) |v| {
            const root = try values.rowSummary(a, e, g, v.rows[0]);
            try r.textFit(font, right, self.value_top + 2, right_width, try std.fmt.allocPrint(a, "{s} @ 0x{x} / start {d}{s}", .{ root.type, self.value_address, self.value_start, if (v.partial != 0) " / partial" else if (v.rows[0].truncated != 0) " / paged" else "" }), theme.focus);
            const n: usize = @intFromFloat(@max(0, (b.y + b.h - 112 - self.value_top - 30) / 23));
            for (v.rows[@min(self.value_scroll, v.count)..@min(v.count, self.value_scroll + n)], 0..) |row, i| {
                var depth: usize = 0;
                var parent = row.parent;
                while (parent < v.count and depth < 8) : (depth += 1) parent = v.rows[parent].parent;
                const summary = try values.rowSummary(a, e, g, row);
                const name = if (row.parent == c.XJAI_NONE) "value" else if (row.member < g.member_count) text(g, g.members[row.member].name) else try std.fmt.allocPrint(a, "[{d}]", .{row.index});
                const x = right + @as(f32, @floatFromInt(depth)) * 12;
                try r.textFit(font, x, self.value_top + 30 + @as(f32, @floatFromInt(i)) * 23, @max(0, right_width - (x - right)), try std.fmt.allocPrint(a, "{s}: {s}{s}", .{ name, summary.display, if (row.truncated != 0) " ..." else "" }), if (row.reason != null) theme.warm else theme.text);
            }
        } else if (self.selected_type < g.type_count) {
            const t = g.types[self.selected_type];
            try r.textFit(font, right, self.value_top + 2, right_width, try std.fmt.allocPrint(a, "{s} / size {d} / {d} fields", .{ text(g, t.name), t.size, t.member_count }), theme.focus);
            try r.textFit(font, right, self.value_top + 28, right_width, "G reads a typed address; Return opens the selected candidate", theme.weak);
            const n: usize = @intFromFloat(@max(0, (b.y + b.h - 112 - self.value_top - 54) / 23));
            for (g.members[t.first_member .. t.first_member + @min(t.member_count, n)], 0..) |m, i| try r.textFit(font, right, self.value_top + 54 + @as(f32, @floatFromInt(i)) * 23, right_width, try std.fmt.allocPrint(a, "{s}  +0x{x}", .{ text(g, m.name), m.offset }), theme.text);
        }
        if (self.item_kind == .search) if (session.memory.search) |*search| try r.textFit(font, b.x + 14, b.y + b.h - 106, b.w - 28, try std.fmt.allocPrint(a, "Search {s}: {d}/{d} bytes; {d} unreadable. X cancel; [ / ] page.", .{ @tagName(search.state), search.scanned, search.length, search.unreadable }), theme.weak);
        try self.footer(r, font, b);
    }
    fn footer(self: *Panel, r: *gpu.Renderer, font: *Font, b: gpu.Rect) !void {
        try r.textFit(font, b.x + 14, b.y + b.h - 74, b.w - 28, self.message, theme.text);
        if (self.editor.open) {
            try style.box(r, .{ .x = b.x + 10, .y = b.y + b.h - 48, .w = b.w - 20, .h = 30 }, theme.background, theme.focus, @splat(3));
            try self.editor.draw(r, font, .{ .x = b.x + 16, .y = b.y + b.h - 43, .w = b.w - 32, .h = 23 });
        }
    }
};
