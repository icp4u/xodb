//! Session-owned stopped-language observations. Runtime decoding and comparison
//! live in C; this adapter schedules reads on the target owner's thread.
const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("session.zig").Session;
const Tab = @import("language_tabs.zig").Tab;
const lua = @import("../language/lua.zig");
const python = @import("../language/python.zig");
const perl = @import("../language/perl.zig");
const Capture = @import("../language/watch.zig").Capture;
const A = std.mem.Allocator;
const Attempt = struct { id: u64, generation: u64, metadata: u64 };
pub const State = struct {
    core: ?*c.struct_xlw_set = null,
    attempts: [c.XLW_ENTRIES]?Attempt = @splat(null),
    revision: u64 = 0,
    pub fn deinit(self: *State) void {
        c.xlw_destroy(self.core);
        self.core = null;
    }
    pub fn add(self: *State, session: *Session, language: Tab, tid: i32, segment: usize, frame: usize, expression: ?[]const u8, row: ?usize) !u64 {
        if (language != .lua and language != .python and language != .perl) return error.LanguageWatchRuntimeUnsupported;
        if (session.target.snapshot().state != .stopped) return error.NotStopped;
        if (segment >= 64 or frame >= 64 or tid <= 0) return error.InvalidArguments;
        if (c.xlw_count(self.core) >= c.XLW_ENTRIES) return error.LanguageWatchLimit;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const capture = switch (language) {
            .lua => try lua.createWatch(session, arena.allocator(), tid, segment, frame, expression, row),
            .python => try python.createWatch(session, arena.allocator(), tid, segment, frame, expression, row),
            .perl => try perl.createWatch(session, arena.allocator(), tid, segment, frame, expression, row),
            else => unreachable,
        };
        if (self.core == null) self.core = c.xlw_create() orelse return error.OutOfMemory;
        var id: u64 = 0;
        try check(c.xlw_add(self.core, &capture.scope, capture.expression, &id));
        errdefer _ = c.xlw_remove(self.core, id);
        try self.feed(id, session.target.snapshot().generation, capture);
        self.revision +%= 1;
        return id;
    }
    pub fn remove(self: *State, id: u64) !void {
        if (self.core == null) return error.LanguageWatchNotFound;
        try check(c.xlw_remove(self.core, id));
        self.revision +%= 1;
    }
    fn feed(self: *State, id: u64, generation: u64, capture: Capture) !void {
        try check(c.xlw_feed(self.core, id, generation, &capture.scope, capture.observation, if (capture.sample) |*sample| sample else null, if (capture.diagnostic) |why| why.ptr else null));
    }
    pub fn poll(self: *State, session: *Session) void {
        if (self.core == null) return;
        const snapshot = session.target.snapshot();
        if (snapshot.state == .running) {
            c.xlw_running(self.core);
            return;
        }
        // One bounded runtime inspection per owner-loop iteration. Never read
        // the target from a worker or on behalf of a cached-results request.
        var ordinal: usize = 0;
        while (ordinal < c.xlw_count(self.core)) : (ordinal += 1) {
            var view: c.struct_xlw_view = undefined;
            if (c.xlw_get(self.core, ordinal, &view) != c.XLW_OK) return;
            if (view.state == c.XLW_GONE or view.state == c.XLW_CONTEXT_CHANGED) continue;
            var scope = view.scope;
            scope.session = session.id;
            scope.image = snapshot.image_epoch;
            const tid: ?i32 = for (session.target.threadSlice()) |thread| {
                if (thread.id == view.scope.thread) break thread.tid;
            } else null;
            if (tid == null) scope.thread = 0;
            if (scope.session != view.scope.session or scope.image != view.scope.image or tid == null) {
                _ = c.xlw_feed(self.core, view.id, @max(snapshot.generation, view.observed_generation), &scope, c.XLW_INCOMPLETE, null, "LanguageWatchContextChanged");
                self.revision +%= 1;
                continue;
            }
            if (snapshot.state != .stopped) continue;
            if (view.observed_generation == snapshot.generation and view.state == c.XLW_VALUE) continue;
            const attempt = Attempt{ .id = view.id, .generation = snapshot.generation, .metadata = session.metadata.revision };
            if (self.attempts[ordinal]) |old| if (std.meta.eql(old, attempt)) continue;
            self.attempts[ordinal] = attempt;
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const capture = (switch (scope.language) {
                c.XLW_LUA => lua.observeWatch(session, arena.allocator(), tid.?, scope, std.mem.span(view.expression)),
                c.XLW_PYTHON => python.observeWatch(session, arena.allocator(), tid.?, scope, std.mem.span(view.expression)),
                c.XLW_PERL => perl.observeWatch(session, arena.allocator(), tid.?, scope, std.mem.span(view.expression)),
                else => error.LanguageWatchRuntimeUnsupported,
            }) catch |err| {
                if (session.target.snapshot().state != .stopped or session.target.snapshot().generation != snapshot.generation) return;
                _ = c.xlw_feed(self.core, view.id, snapshot.generation, &scope, c.XLW_INCOMPLETE, null, @errorName(err).ptr);
                self.revision +%= 1;
                return;
            };
            self.feed(view.id, snapshot.generation, capture) catch |err| {
                _ = c.xlw_feed(self.core, view.id, snapshot.generation, &scope, c.XLW_INCOMPLETE, null, @errorName(err).ptr);
            };
            self.revision +%= 1;
            return;
        }
    }
    pub fn list(self: *const State, a: A) ![]Entry {
        const entries = try a.alloc(Entry, c.xlw_count(self.core));
        for (entries, 0..) |*entry, ordinal| {
            var view: c.struct_xlw_view = undefined;
            try check(c.xlw_get(self.core, ordinal, &view));
            entry.* = .{ .semantics = if (view.scope.language == c.XLW_PERL) "stopped complete scalar representations; public IOK/NOK/POK changes count; no coercion or automatic interruption" else sample_semantics, .identity = if (view.scope.language == c.XLW_PERL) "stackinfo/context index and CV match; continuous activation lifetime between stops unproved" else frame_identity, .id = view.id, .language = switch (view.scope.language) {
                c.XLW_PYTHON => .python,
                c.XLW_PERL => .perl,
                else => .lua,
            }, .expression = try a.dupe(u8, std.mem.span(view.expression)), .observed_generation = view.observed_generation, .session = view.scope.session, .image_epoch = view.scope.image, .thread_id = view.scope.thread, .runtime_location = view.scope.runtime[1], .frame_location = view.scope.frame[0], .prototype = view.scope.frame[1], .selector = if (binding(view.scope)) .binding else .expression, .declaration = if (binding(view.scope)) view.scope.frame[3] else null, .state = switch (view.state) {
                c.XLW_PENDING => .pending,
                c.XLW_VALUE => .value,
                c.XLW_UNAVAILABLE => .unavailable,
                c.XLW_RUNNING => .running,
                c.XLW_GONE => .gone,
                c.XLW_CONTEXT_CHANGED => .context_changed,
                else => unreachable,
            }, .comparison = switch (view.comparison) {
                c.XLW_NOT_COMPARED => .not_compared,
                c.XLW_SAME_SLOT_EQUAL => .same_slot_equal,
                c.XLW_SAME_SLOT_DIFFERENT => .same_slot_different,
                else => unreachable,
            }, .diagnostic = if (view.reason[0] == 0) null else try a.dupe(u8, std.mem.span(view.reason)), .changed = view.changed != 0, .current = if (view.has_value != 0) try value(a, view.current) else null, .previous = if (view.has_previous != 0) try value(a, view.previous) else null };
        }
        return entries;
    }
};
fn binding(scope: c.struct_xlw_scope) bool {
    return if (scope.language == c.XLW_PYTHON) scope.frame[2] & 1 != 0 else scope.frame[2] != 0;
}
fn check(result: c.enum_xlw_result) !void {
    return switch (result) {
        c.XLW_OK => {},
        c.XLW_NOMEM => error.OutOfMemory,
        c.XLW_FULL => error.LanguageWatchLimit,
        c.XLW_STALE => error.StaleSnapshot,
        c.XLW_NOT_FOUND => error.LanguageWatchNotFound,
        else => error.InvalidLanguageWatchSample,
    };
}
pub const Value = struct { generation: u64, kind: u32, type: []const u8, display: []const u8, comparison_bytes: usize };
fn value(a: A, v: c.struct_xlw_value) !Value {
    return .{ .generation = v.generation, .kind = v.kind, .type = try a.dupe(u8, std.mem.span(v.type)), .display = try a.dupe(u8, std.mem.span(v.display)), .comparison_bytes = v.size };
}
const sample_semantics = "stopped typed-byte comparison; storage re-resolved each stop; no automatic interruption";
const frame_identity = "frame location and code/prototype match; continuous activation lifetime between stops unproved";
pub const Entry = struct {
    id: u64,
    language: Tab,
    expression: []const u8,
    observed_generation: u64,
    session: u64,
    image_epoch: u64,
    thread_id: u64,
    runtime_location: u64,
    frame_location: u64,
    prototype: u64,
    selector: enum { expression, binding },
    declaration: ?u64,
    state: enum { pending, value, unavailable, running, gone, context_changed },
    diagnostic: ?[]const u8,
    changed: bool,
    comparison: enum { not_compared, same_slot_equal, same_slot_different },
    current: ?Value,
    previous: ?Value,
    semantics: []const u8 = sample_semantics,
    identity: []const u8 = frame_identity,
};
