//! Owner-side runtime metadata, candidates and typed value preparation.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("session.zig");
const Session = model.Session;
const cache = @import("runtime_types.zig");
const instances = @import("runtime_instances.zig");
const values = @import("runtime_values.zig");
pub const Focus = enum { types, items, value };
pub const Editing = enum { load, filter, address, search, container, write };
const SearchKey = struct { id: u64, count: usize, start: usize };
const Hit = struct { address: ?u64, type_index: u32, slot: u64, reason: ?[]const u8 };
fn text(g: *const c.struct_xjai_graph, offset: u32) []const u8 {
    return std.mem.span(g.text + offset);
}
fn number(s: []const u8) !u64 {
    return std.fmt.parseInt(u64, s, 0) catch error.ExpectedNumber;
}
fn typeSelector(g: *const c.struct_xjai_graph, name: []const u8) !u32 {
    const selector: cache.Selector = if (std.mem.startsWith(u8, name, "0x"))
        .{ .address = try number(name) }
    else
        .{ .name = name };
    return selector.find(g);
}

pub const hint = "L load   / filter   G address   S search   O container   W write   Shift+U undo   T context   Tab focus";
const State = struct {
    message: []const u8 = hint,
    editing: Editing = .filter,
    context_id: ?u64 = null,
    selected_type: u32 = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    focus: Focus = .types,
    type_scroll: usize = 0,
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
    fn clearValue(self: *State) void {
        if (self.value_rows) |v| c.xjai_values_free(v);
        self.value_rows = null;
        self.value_scroll = 0;
    }
    fn entry(self: *State, session: *Session) !cache.Entry {
        if (self.context_id == null) {
            for (session.runtime_types.entries) |maybe| if (maybe) |e| {
                if (self.context_id == null or e.id > self.context_id.?) self.context_id = e.id;
            };
        }
        return session.runtime_types.find(self.context_id orelse return error.LoadRuntimeTypesFirst);
    }
    fn matches(self: *const State, g: *const c.struct_xjai_graph, index: u32) bool {
        if (std.mem.startsWith(u8, self.filter[0..self.filter_len], "0x")) {
            const address = std.fmt.parseInt(u64, self.filter[0..self.filter_len], 0) catch return false;
            return g.types[index].address == address;
        }
        return self.filter_len == 0 or std.ascii.indexOfIgnoreCase(text(g, g.types[index].name), self.filter[0..self.filter_len]) != null;
    }
    fn selectValid(self: *State, g: *const c.struct_xjai_graph) void {
        if (self.selected_type < g.type_count and self.matches(g, self.selected_type)) return;
        for (0..g.type_count) |i| if (self.matches(g, @intCast(i))) {
            self.selected_type = @intCast(i);
            return;
        };
        self.selected_type = c.XJAI_NONE;
    }
    fn moveType(self: *State, g: *const c.struct_xjai_graph, delta: i32) void {
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
    pub fn wheel(self: *State, session: *Session, amount: i32) void {
        const e = self.entry(session) catch return;
        const g = e.graph() catch return;
        switch (self.focus) {
            .types => self.moveType(g, amount),
            .items => self.item_selected = @intCast(@max(0, @min(@as(i64, @intCast(self.item_count)) - 1, @as(i64, @intCast(self.item_selected)) + amount))),
            .value => self.value_scroll = @intCast(@max(0, @min(255, @as(i64, @intCast(self.value_scroll)) + amount))),
        }
    }
    fn submit(self: *State, session: *Session, actor: model.Actor, input: []const u8) !void {
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
            const result = try session.runtime_writes.apply(session, actor, session.target.snapshot().generation, e, self.value_type, self.value_address, clean[0..split], value, false);
            self.message = @import("../model/runtime_writes.zig").reason(result.value.reason) orelse "Write verified; Shift+U restores the original bytes";
            return;
        }
        var tokens = std.mem.tokenizeAny(u8, input, " \t");
        const address = try number(tokens.next() orelse return error.ExpectedAddress);
        if (self.editing == .load) {
            const length = try number(tokens.next() orelse return error.ExpectedLength);
            if (tokens.next() != null or length == 0 or length > @import("../model/memory.zig").max_snapshot) return error.InvalidMemoryRange;
            const capture = try session.memory.capture(session, address, @intCast(length));
            self.context_id = try session.runtime_types.load(session, &.{capture}, if (actor == .human) .{} else session.jobRequester());
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
            _ = try session.runtime_instances.beginOwned(session, e, self.selected_type, needle, member, &.{.{ .address = address, .length = length }}, if (actor == .human) .{} else session.jobRequester());
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
    fn readValue(self: *State, session: *Session, index: u32, address: u64) !void {
        return self.readValuePage(session, index, address, 0);
    }
    fn pageValue(self: *State, session: *Session, forward: bool) !void {
        const v = self.value_rows orelse return error.SelectAggregateValue;
        const e = try self.entry(session);
        const g = try e.graph();
        if (self.value_type >= g.type_count or (g.types[self.value_type].tag != 7 and g.types[self.value_type].tag != 8)) return error.SelectAggregateValue;
        const total = v.rows[0].total_count;
        const next = if (!forward) self.value_start -| 16 else if (self.value_start + 16 < total) self.value_start + 16 else self.value_start;
        try self.readValuePage(session, self.value_type, self.value_address, next);
    }
    fn readValuePage(self: *State, session: *Session, index: u32, address: u64, start: u64) !void {
        self.clearValue();
        const e = try self.entry(session);
        try e.requireStop(session);
        const g = try e.graph();
        var context = cache.LiveReader{ .session = session };
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
    fn openItem(self: *State, session: *Session) !void {
        if (self.item_selected >= self.item_count) return error.SelectCandidate;
        const item = self.items[self.item_selected];
        if (item.reason) |why| {
            self.message = why;
            return;
        }
        try self.readValue(session, item.type_index, item.address orelse return error.CandidateUnavailable);
    }
    fn readContainer(self: *State, session: *Session) !void {
        self.item_count = 0;
        self.item_total = 0;
        self.items_reason = "Container read unavailable";
        const e = try self.entry(session);
        try e.requireStop(session);
        const g = try e.graph();
        var context = cache.LiveReader{ .session = session };
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
    fn updateItems(self: *State, session: *Session, e: cache.Entry, g: *const c.struct_xjai_graph) void {
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
};

pub const Key = struct {
    session: u64 = 0,
    generation: u64 = 0,
    revision: u64 = 0,
    context: ?u64 = null,
};
pub const Request = struct { types: usize = 1, items: usize = 1, values: usize = 1 };
pub const Action = struct {
    key: Key,
    kind: union(enum) {
        edit: struct { mode: Editing, text: []const u8 },
        wheel: struct { focus: Focus, amount: i32 },
        select_type: u32,
        open_item: ?usize,
        undo: u64,
        context,
        cancel: u64,
        page: struct { focus: Focus, forward: bool },
    },
};
pub const TypeRow = struct { index: u32, label: []const u8, unavailable: bool };
pub const ItemRow = struct { index: usize, label: []const u8, unavailable: bool };
pub const ValueRow = struct { depth: usize = 0, label: []const u8, unavailable: bool = false };
pub const View = struct {
    key: Key = .{},
    request: Request = .{},
    focus: Focus = .types,
    selected_type: u32 = 0,
    selected_item: usize = 0,
    context: bool = false,
    graph: bool = false,
    stale: bool = false,
    busy: bool = false,
    types_total: usize = 0,
    items_total: usize = 0,
    title: []const u8 = "",
    detail: []const u8 = "No type metadata. L loads a read-only address range; text input works before a stop.",
    message: []const u8 = hint,
    item_label: []const u8 = "",
    value_title: []const u8 = "",
    value_hint: []const u8 = "",
    value_offset: f32 = 30,
    search_label: []const u8 = "",
    search_id: ?u64 = null,
    undo_id: u64 = 0,
    types: []const TypeRow = &.{},
    items: []const ItemRow = &.{},
    values: []const ValueRow = &.{},
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}

pub const Capture = struct {
    state: State = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    revision: u64 = 0,
    signature: u64 = 0,
    session_id: u64 = 0,
    image_epoch: u64 = 0,
    search_count: usize = 0,
    search_scanned: u64 = 0,
    search_state: ?@FieldType(@import("memory.zig").Search, "state") = null,
    pub fn deinit(self: *Capture) void {
        self.state.clearValue();
        self.arena.deinit();
    }
    fn current(self: *const Capture, session: *const Session) Key {
        return .{ .session = session.id, .generation = session.target.snapshot().generation, .revision = self.revision, .context = self.state.context_id };
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        const view = self.value orelse return false;
        if (!std.meta.eql(view.key, self.current(session)) or self.signature != session.runtime_types.signature()) return true;
        if (session.memory.search) |search| return self.search_count != search.count or self.search_scanned != search.scanned or self.search_state != search.state;
        return self.search_state != null;
    }
    pub fn apply(self: *Capture, session: *Session, actor: model.Actor, action: Action) !void {
        if (!std.meta.eql(action.key, self.current(session))) return error.StaleRuntimeTypeView;
        defer self.revision +%= 1;
        const state = &self.state;
        switch (action.kind) {
            .edit => |edit| {
                if (edit.text.len > 4096) return error.RuntimeTypeInputTooLong;
                state.editing = edit.mode;
                try state.submit(session, actor, edit.text);
            },
            .wheel => |wheel| {
                if (wheel.amount < -64 or wheel.amount > 64) return error.InvalidArguments;
                state.focus = wheel.focus;
                state.wheel(session, wheel.amount);
            },
            .select_type => |index| {
                const e = try state.entry(session);
                const g = try e.graph();
                if (index >= g.type_count or !state.matches(g, index)) return error.StaleRuntimeTypeView;
                state.selected_type = index;
                state.focus = .types;
            },
            .open_item => |maybe_index| {
                if (maybe_index) |index| state.item_selected = index;
                try state.openItem(session);
            },
            .undo => |id| {
                if (id == 0 or id != session.runtime_writes.last(session)) return error.StaleRuntimeWrite;
                const result = try session.runtime_writes.undo(session, actor, action.key.generation, id, false);
                state.message = @import("runtime_writes.zig").reason(result.value.reason) orelse "Undo verified; original bytes restored";
            },
            .context => {
                var next: ?u64 = null;
                var first: ?u64 = null;
                for (session.runtime_types.entries) |maybe| if (maybe) |e| {
                    if (first == null or e.id < first.?) first = e.id;
                    if (e.id > (state.context_id orelse 0) and (next == null or e.id < next.?)) next = e.id;
                };
                state.context_id = next orelse first;
                state.selected_type = 0;
                state.item_kind = .none;
                state.items_reason = null;
                state.item_count = 0;
                state.clearValue();
            },
            .cancel => |id| {
                const query = session.runtime_instances.query orelse return error.NoInstanceSearch;
                if (query.id != id or query.context_id != state.context_id) return error.StaleRuntimeTypeView;
                try session.memory.cancelSearch(id, if (actor == .human) .{} else session.jobRequester());
            },
            .page => |page| {
                state.focus = page.focus;
                if (page.focus == .value) {
                    try state.pageValue(session, page.forward);
                } else {
                    state.item_start = if (!page.forward) state.item_start -| 64 else if (state.item_start + 64 < state.item_total) state.item_start + 64 else state.item_start;
                    state.item_selected = 0;
                    state.item_scroll = 0;
                    state.search_seen = null;
                    if (state.item_kind == .container) try state.readContainer(session);
                }
            },
        }
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const request = wanted orelse {
            self.value = null;
            self.state.clearValue();
            _ = self.arena.reset(.free_all);
            return;
        };
        const snapshot = session.target.snapshot();
        if (self.session_id != session.id or self.image_epoch != snapshot.image_epoch) {
            self.state.clearValue();
            self.state = .{};
            self.revision +%= 1;
            self.session_id = session.id;
            self.image_epoch = snapshot.image_epoch;
        }
        const bounded: Request = .{ .types = @min(64, request.types), .items = @min(64, request.items), .values = @min(64, request.values) };
        if (self.value) |old| if (std.meta.eql(old.request, bounded) and !self.changed(session)) return;
        _ = self.arena.reset(.retain_capacity);
        self.signature = session.runtime_types.signature();
        self.search_count = if (session.memory.search) |s| s.count else 0;
        self.search_scanned = if (session.memory.search) |s| s.scanned else 0;
        self.search_state = if (session.memory.search) |s| s.state else null;
        self.value = .{ .key = self.current(session), .request = bounded };
        self.prepare(session) catch |err| {
            self.value.?.detail = @errorName(err);
        };
        self.value.?.key = self.current(session);
        self.value.?.focus = self.state.focus;
        self.value.?.message = self.copy(self.state.message) catch "OutOfMemory";
    }
    fn copy(self: *Capture, text_value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text_value[0..@min(text_value.len, 1024)]);
    }
    fn prepare(self: *Capture, session: *Session) !void {
        const a = self.arena.allocator();
        const state = &self.state;
        const view = &self.value.?;
        const e = state.entry(session) catch |err| {
            if (err != error.LoadRuntimeTypesFirst) return err;
            return;
        };
        view.context = true;
        view.stale = e.stale(session) or session.target.snapshot().state != .stopped;
        view.busy = e.poll().state == c.XJAI_JOB_PENDING;
        view.title = try std.fmt.allocPrint(a, "Context {d}  / stop {d}  / {s}", .{ e.id, e.generation, if (view.stale) "STALE: use L at a new stop" else "stopped" });
        const g = try e.graph();
        view.graph = true;
        view.detail = "";
        view.undo_id = session.runtime_writes.last(session);
        if (std.mem.eql(u8, state.message, "Discovering read-only runtime types")) state.message = hint;
        if (!view.stale and state.value_rows != null and state.value_generation != e.generation) {
            const message = state.message;
            state.readValuePage(session, state.value_type, state.value_address, state.value_start) catch |err| {
                state.message = @errorName(err);
            };
            if (state.value_rows != null) state.message = message;
        }
        state.selectValid(g);
        state.updateItems(session, e, g);
        view.selected_type = state.selected_type;
        var selected_ordinal: usize = 0;
        for (0..g.type_count) |i| if (state.matches(g, @intCast(i))) {
            if (i == state.selected_type) selected_ordinal = view.types_total;
            view.types_total += 1;
        };
        if (selected_ordinal < state.type_scroll) state.type_scroll = selected_ordinal;
        if (view.request.types != 0 and selected_ordinal >= state.type_scroll + view.request.types) state.type_scroll = selected_ordinal - view.request.types + 1;
        var type_rows: std.ArrayList(TypeRow) = .empty;
        var ordinal: usize = 0;
        for (g.types[0..g.type_count], 0..) |t, i| {
            if (!state.matches(g, @intCast(i))) continue;
            const position = ordinal;
            ordinal += 1;
            if (position < state.type_scroll or type_rows.items.len == view.request.types) continue;
            var count: ?usize = null;
            if (session.runtime_instances.query) |q| if (q.context_id == e.id and q.needle == i and session.memory.search != null and session.memory.search.?.id == q.id) {
                count = session.memory.search.?.count;
            };
            const name = try self.copy(text(g, t.name));
            const label = if (count) |n| try std.fmt.allocPrint(a, "{s}  [{d} candidate hits{s}]", .{ name, n, if (view.stale) "; stale" else "" }) else try std.fmt.allocPrint(a, "{s}  @0x{x}", .{ if (name.len == 0) "(unnamed type)" else name, t.address });
            try type_rows.append(a, .{ .index = @intCast(i), .label = label, .unavailable = t.reason != null });
        }
        view.types = type_rows.items;
        try self.prepareItems(session, e, g);
        try self.prepareValues(e, g);
    }
    fn prepareItems(self: *Capture, session: *Session, e: cache.Entry, g: *const c.struct_xjai_graph) !void {
        const a = self.arena.allocator();
        const state = &self.state;
        const view = &self.value.?;
        state.item_selected = @min(state.item_selected, state.item_count -| 1);
        if (state.item_selected < state.item_scroll) state.item_scroll = state.item_selected;
        if (view.request.items != 0 and state.item_selected >= state.item_scroll + view.request.items) state.item_scroll = state.item_selected - view.request.items + 1;
        view.selected_item = state.item_selected;
        view.items_total = state.item_count;
        var rows: std.ArrayList(ItemRow) = .empty;
        for (state.items[@min(state.item_scroll, state.item_count)..@min(state.item_count, state.item_scroll + view.request.items)], state.item_scroll..) |item, i| {
            const label = if (item.reason) |why| try std.fmt.allocPrint(a, "Candidate {d}: {s}", .{ item.slot, try self.copy(why) }) else try std.fmt.allocPrint(a, "{s} {d}: 0x{x}", .{ if (state.item_kind == .container) "Occupied slot" else "Candidate", item.slot, item.address.? });
            try rows.append(a, .{ .index = i, .label = label, .unavailable = item.reason != null });
        }
        view.items = rows.items;
        const item_type = if (state.item_kind == .container) state.container_type else if (session.runtime_instances.query) |q| q.needle else c.XJAI_NONE;
        const item_name = if (item_type < g.type_count) try self.copy(text(g, g.types[item_type].name)) else "";
        view.item_label = if (state.items_reason) |why| try std.fmt.allocPrint(a, "Unavailable: {s}", .{try self.copy(why)}) else if (state.item_kind == .none) "No instance search yet; counts unmeasured" else try std.fmt.allocPrint(a, "{s} {d}+{d}/{d} / Lifetime unproved / {s}", .{ if (state.item_kind == .container) "Slots" else "Candidates", state.item_start, state.item_count, state.item_total, item_name });
        if (state.item_kind == .search) if (session.memory.search) |search| {
            if (session.runtime_instances.query) |query| {
                if (query.context_id == e.id and query.id == search.id) view.search_id = query.id;
            }
            view.busy = search.state == .running;
            view.search_label = try std.fmt.allocPrint(a, "Search {s}: {d}/{d} bytes; {d} unreadable. X cancel; [ / ] page.", .{ @tagName(search.state), search.scanned, search.length, search.unreadable });
        };
    }
    fn prepareValues(self: *Capture, e: cache.Entry, g: *const c.struct_xjai_graph) !void {
        const a = self.arena.allocator();
        const state = &self.state;
        const view = &self.value.?;
        var rows: std.ArrayList(ValueRow) = .empty;
        if (state.value_rows) |v| {
            if (v.count == 0) return;
            const root = try values.rowSummary(a, e, g, v.rows[0]);
            view.value_title = try std.fmt.allocPrint(a, "{s} @ 0x{x} / start {d}{s}", .{ try self.copy(root.type), state.value_address, state.value_start, if (v.partial != 0) " / partial" else if (v.rows[0].truncated != 0) " / paged" else "" });
            for (v.rows[@min(state.value_scroll, v.count)..@min(v.count, state.value_scroll + view.request.values)]) |row| {
                var depth: usize = 0;
                var parent = row.parent;
                while (parent < v.count and depth < 8) : (depth += 1) parent = v.rows[parent].parent;
                const summary = try values.rowSummary(a, e, g, row);
                const name = if (row.parent == c.XJAI_NONE) "value" else if (row.member < g.member_count) try self.copy(text(g, g.members[row.member].name)) else try std.fmt.allocPrint(a, "[{d}]", .{row.index});
                try rows.append(a, .{ .depth = depth, .label = try std.fmt.allocPrint(a, "{s}: {s}{s}", .{ name, try self.copy(summary.display), if (row.truncated != 0) " ..." else "" }), .unavailable = row.reason != null });
            }
        } else if (state.selected_type < g.type_count) {
            const t = g.types[state.selected_type];
            view.value_title = try std.fmt.allocPrint(a, "{s} / size {d} / {d} fields", .{ try self.copy(text(g, t.name)), t.size, t.member_count });
            view.value_hint = "G reads a typed address; Return opens the selected candidate";
            view.value_offset = 54;
            for (g.members[t.first_member .. t.first_member + @min(t.member_count, view.request.values -| 1)]) |m| try rows.append(a, .{ .label = try std.fmt.allocPrint(a, "{s}  +0x{x}", .{ try self.copy(text(g, m.name)), m.offset }) });
        }
        view.values = rows.items;
    }
};

test "runtime type commands reject retired selection before touching session data" {
    var session = Session{ .id = 41 };
    defer session.deinit();
    var capture = Capture{};
    defer capture.deinit();
    const key = capture.current(&session);
    try capture.apply(&session, .human, .{ .key = key, .kind = .{ .edit = .{ .mode = .filter, .text = "needle" } } });
    try std.testing.expectError(error.StaleRuntimeTypeView, capture.apply(&session, .human, .{ .key = key, .kind = .{ .edit = .{ .mode = .write, .text = "field 7" } } }));
    try std.testing.expectEqualStrings("needle", capture.state.filter[0..capture.state.filter_len]);
    capture.refresh(&session, .{ .types = 999, .items = 999, .values = 999 });
    try std.testing.expectEqual(@as(usize, 64), capture.value.?.request.types);
    try std.testing.expect(session.runtime_writes.journal == null);
}

test "runtime type publication retains names and value rows after owner retirement" {
    const boundary = @import("remote_owner.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    const label = try a.dupe(u8, "SyntheticType");
    const rows = try a.alloc(TypeRow, 1);
    rows[0] = .{ .index = 2, .label = label, .unavailable = false };
    const publication = try boundary.Publication.create(std.testing.allocator, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 42, .image_epoch = 1, .generation = 1 }, .revision = 1, .taken_ns = 1, .status = .ready, .runtime_types = .{ .types = rows } });
    defer publication.destroy();
    @memset(label, 'x');
    arena.deinit();
    try std.testing.expectEqualStrings("SyntheticType", publication.value.runtime_types.?.types[0].label);
}
