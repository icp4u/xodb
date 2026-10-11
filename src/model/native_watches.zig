//! Bounded native expression watches and owner-side Session evaluation.
const std = @import("std");
const model = @import("session.zig");
const Session = model.Session;
const info = @import("../debug/info.zig");

pub const max_entries = 16;
pub const max_text = 256;
pub const max_children = 16;
pub const max_display = 160;
pub const max_type = 64;
pub const max_symbol = 96;

pub fn Text(comptime n: usize) type {
    return struct {
        bytes: [n]u8 = undefined,
        len: usize = 0,
        pub fn set(self: *@This(), value: []const u8) void {
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
    pub fn persistent(self: *const FrameId) bool {
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
    failure: ?[]const u8 = null,
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
    revision: u64 = 0,
    metadata_revision: ?u64 = null,
    runtime_type_signature: ?u64 = null,
    /// Generation of the last evaluation; null forces the next one.
    generation: ?u64 = null,
    dirty: bool = true,
    display_frame: ?Selection = null,
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    /// Evaluations performed, for tests and measurements.
    evaluations: u64 = 0,
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
        self.revision += 1;
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
        self.revision += 1;
        self.dirty = true;
    }
    pub fn remove(self: *WatchList, index: usize) void {
        if (index >= self.count) return;
        std.mem.copyForwards(Entry, self.entries[index .. self.count - 1], self.entries[index + 1 .. self.count]);
        self.count -= 1;
        self.revision += 1;
    }
    pub fn items(self: *WatchList) []Entry {
        return self.entries[0..self.count];
    }
    pub fn toggleExpanded(self: *WatchList, index: usize) void {
        if (index >= self.count or !self.entries[index].expandable) return;
        self.entries[index].expanded = !self.entries[index].expanded;
        self.entries[index].page = 0;
        self.revision += 1;
        self.dirty = true;
    }
    pub fn pageChildren(self: *WatchList, index: usize, forward: bool) void {
        if (index >= self.count or !self.entries[index].expanded) return;
        const entry = &self.entries[index];
        self.revision += 1;
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
                if (entry.state != .thread_gone or entry.resolved_index != null) self.revision += 1;
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
                self.revision += 1;
            };
            self.generation = null;
            return;
        }
        const generation = ctx.generation();
        if (!self.dirty and self.generation != null and self.generation.? == generation) return;
        self.generation = generation;
        self.revision += 1;
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
                    entry.failure = explain(err);
                    entry.display.len = 0;
                    entry.expandable = false;
                    entry.expanded = false;
                },
            }
            entry.changed = entry.has_previous and entry.has_value and entry.previous != entry.fingerprint;
        }
    }
};

/// Borrowed on the owner; publication deep-copies entries and child strings.
pub const View = struct {
    session: u64 = 0,
    revision: u64 = 0,
    generation: ?u64 = null,
    entries: []const Entry = &.{},
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub fn snapshot(list: *const WatchList, session: *const Session) View {
    return .{ .session = session.id, .revision = list.revision, .generation = list.generation, .entries = list.entries[0..list.count] };
}
pub fn refresh(list: *WatchList, session: *Session, selection: ?WatchList.Selection) View {
    const signature = session.runtime_types.signature();
    if (list.runtime_type_signature == null or list.runtime_type_signature.? != signature) list.dirty = true;
    list.runtime_type_signature = signature;
    list.setDisplayFrame(selection);
    if (list.count > 0) {
        if (list.metadata_revision != session.metadata.revision) list.dirty = true;
        list.metadata_revision = session.metadata.revision;
        var source = Source{ .session = session };
        defer source.scratch.deinit();
        list.refresh(&source);
    }
    return snapshot(list, session);
}
/// The revision prevents an index from selecting a different entry after a
/// queued removal compacts the list. A stale frontend must obtain a new view.
pub const Token = struct { revision: u64, index: usize };
pub const Binding = struct { selection: WatchList.Selection, metadata: u64 };
pub const Action = union(enum) {
    add: struct { binding: Binding, text: []const u8, mode: Mode },
    remove: Token,
    toggle_mode: struct { entry: Token, binding: Binding },
    expand: Token,
    page: struct { entry: Token, forward: bool },
    investigate_write: Token,
};
fn check(list: *const WatchList, token: Token) !void {
    if (token.revision != list.revision) return error.StaleWatchList;
    if (token.index >= list.count) return error.WatchEntryNotFound;
}
fn frameId(session: *Session, binding: Binding) !FrameId {
    if (session.metadata.revision != binding.metadata) return error.StaleSnapshot;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    var source = Source{ .session = session };
    defer source.scratch.deinit();
    const identity = source.identity(binding.selection.tid) orelse return error.InvalidThread;
    const frames = switch (source.stack(binding.selection.tid)) {
        .unavailable => return error.InvalidFrame,
        .frames => |frames| frames.items,
    };
    if (session.metadata.revision != binding.metadata) return error.StaleSnapshot;
    if (binding.selection.index >= frames.len) return error.InvalidFrame;
    return FrameId.of(binding.selection.tid, binding.selection.index, frames[binding.selection.index], identity, source.generation());
}
/// Called after queue stamp and actor validation; native GUI uses the same
/// operation synchronously with its human actor.
pub fn apply(list: *WatchList, session: *Session, actor: model.Actor, action: Action) !?u64 {
    switch (action) {
        .add => |request| {
            const id = try list.addMode(request.text, try frameId(session, request.binding), request.mode);
            session.record(actor, "add_expression_watch");
            return @intCast(id);
        },
        .remove => |entry| {
            try check(list, entry);
            list.remove(entry.index);
            session.record(actor, "remove_expression_watch");
        },
        .toggle_mode => |request| {
            try check(list, request.entry);
            list.toggleMode(request.entry.index, try frameId(session, request.binding));
            session.record(actor, "change_expression_watch_mode");
        },
        .expand => |entry| {
            try check(list, entry);
            list.toggleExpanded(entry.index);
        },
        .page => |request| {
            try check(list, request.entry);
            list.pageChildren(request.entry.index, request.forward);
        },
        .investigate_write => |token| {
            try check(list, token);
            if (session.target.snapshot().state != .stopped or list.generation != session.target.snapshot().generation) return error.StaleSnapshot;
            const entry = &list.entries[token.index];
            if (entry.state != .value) return error.WatchValueUnavailable;
            const frame = entry.resolved_index orelse return error.InvalidFrame;
            _ = try session.investigateWrite(entry.frame.tid, frame, "Why did the watched expression change?", entry.expression());
            session.record(actor, "investigate_write");
        },
    }
    return null;
}

/// Plain words for evaluator and target errors. A typo must never look like a value.
pub fn explain(err: anyerror) []const u8 {
    return switch (err) {
        error.RuntimeTypesPending => "runtime types loading",
        error.RuntimeTypesStale => "runtime types stale; capture and load at this stop",
        error.RuntimeTypesExpired => "runtime type context released",
        error.RuntimeTypesFailed => "runtime type discovery failed",
        error.RuntimeTypeNotFound => "runtime type not found; load its read-only capture",
        error.RuntimeTypeAmbiguous => "runtime type name is ambiguous; use its record address",
        error.InvalidRuntimeTypeExpression => "use address as TypeName (one trailing cast)",
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

/// Watch-list evaluation through the same Session paths as MCP
/// `evaluate_expression`: one unwind per thread and one locals lookup per
/// frame for each refresh, shared by all entries.
pub const Source = struct {
    session: *Session,
    scratch: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    tids: [max_entries]i32 = undefined,
    frames: [max_entries][]const model.Frame = undefined,
    views: [max_entries][]Frame = undefined,
    stacks: usize = 0,
    local_keys: [max_entries]struct { tid: i32, index: usize } = undefined,
    locals: [max_entries][]const info.Local = undefined,
    local_count: usize = 0,
    pub fn stopped(self: *Source) bool {
        return self.session.target.snapshot().state == .stopped;
    }
    pub fn ended(self: *Source) bool {
        return self.session.target.snapshot().state == .exited or self.session.target.snapshot().state == .idle;
    }
    pub fn generation(self: *Source) u64 {
        return self.session.target.snapshot().generation;
    }
    fn slot(self: *Source, tid: i32) ?usize {
        for (self.tids[0..self.stacks], 0..) |t, i| if (t == tid) return i;
        return null;
    }
    pub fn identity(self: *Source, tid: i32) ?Identity {
        for (self.session.target.threadSlice()) |thread| {
            if (thread.tid == tid and thread.state != .exited) return .{ .session = self.session.id, .image = self.session.target.snapshot().image_epoch, .thread = thread.id };
        }
        return null;
    }
    pub fn frameView(session: *Session, frame: model.Frame) Frame {
        // Frame decoration must not fetch an unloaded remote caller's library.
        const found = if (session.target.isRemote()) session.modules.cachedSymbolAt(frame.lookup_pc) else session.modules.symbolAt(frame.lookup_pc);
        const function = if (found) |symbol| symbol.address else |_| null;
        return .{ .cfa = frame.cfa, .symbol = frame.symbol, .module = frame.module_id, .function = function, .pc = frame.pc };
    }
    pub fn stack(self: *Source, tid: i32) Stack {
        const i = self.slot(tid) orelse blk: {
            if (self.stacks == max_entries) return .unavailable;
            const a = self.scratch.allocator();
            const frames = self.session.stack(a, tid, 64) catch return .unavailable;
            const views = a.alloc(Frame, frames.len) catch return .unavailable;
            for (frames, views) |frame, *view| view.* = frameView(self.session, frame);
            const i = self.stacks;
            self.tids[i] = tid;
            self.frames[i] = frames;
            self.views[i] = views;
            self.stacks += 1;
            break :blk i;
        };
        const frames = self.frames[i];
        return .{ .frames = .{ .items = self.views[i], .complete = frames.len > 0 and frames.len < 64 and frames[frames.len - 1].diagnostic == null } };
    }
    fn frameLocals(self: *Source, tid: i32, index: usize, frame: model.Frame) []const info.Local {
        for (self.local_keys[0..self.local_count], 0..) |key, i| if (key.tid == tid and key.index == index) return self.locals[i];
        const values = self.session.frameLocals(self.scratch.allocator(), frame) catch &.{};
        if (self.local_count < max_entries) {
            self.local_keys[self.local_count] = .{ .tid = tid, .index = index };
            self.locals[self.local_count] = values;
            self.local_count += 1;
        }
        return values;
    }
    pub fn evaluate(self: *Source, a: std.mem.Allocator, tid: i32, index: usize, text: []const u8, page: ?u64) Result {
        const i = self.slot(tid) orelse return .{ .failed = error.InvalidFrame };
        if (index >= self.frames[i].len) return .{ .failed = error.InvalidFrame };
        const frame = self.frames[i][index];
        const value = self.session.evaluateInFrame(self.scratch.allocator(), frame, self.frameLocals(tid, index, frame), text) catch |err| return .{ .failed = err };
        const summary = self.session.summarize(a, value) catch |err| return .{ .failed = err };
        const expandable = value.type.kind == .structure or value.type.kind == .array or (value.type.language == .go and value.type.go_kind == @import("value_view.zig").go_kind.map);
        const extent_advisory = if (summary.visualization) |v| v.extent_advisory else false;
        var result = Result{ .value = .{ .display = summary.display, .type_name = summary.type, .available = summary.availability == .available, .extent_advisory = extent_advisory, .expandable = expandable } };
        if (page) |start| if (expandable) {
            const view = self.session.valueChildren(a, value, start, max_children, false) catch |err| return .{ .failed = err };
            const children = a.alloc(Child, view.children.len) catch return result;
            for (view.children, children) |child, *out| {
                const advisory = if (child.value.visualization) |v| v.extent_advisory else false;
                out.* = .{ .name = child.name, .display = if (advisory) std.fmt.allocPrint(a, "unproved extent: {s}", .{child.value.display}) catch child.value.display else child.value.display, .extent_advisory = advisory };
            }
            result.value.children = children;
            result.value.total = view.total;
            result.value.next = view.next;
        };
        return result;
    }
};
