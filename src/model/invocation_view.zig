//! Owner-side ended-observation projection and citation resolution.
const std = @import("std");
const log = @import("../log.zig");
const session_model = @import("session.zig");
const Session = session_model.Session;
const model = @import("../observe/capture.zig");
const calls = @import("../observe/calls.zig");
const types = @import("../observe/types.zig");
const comparison = @import("../observe/comparison.zig");
const analysis = @import("../observe/analysis.zig");
const timeline = @import("../ui/timeline.zig");
pub const default_threshold_ns: u64 = 4_000_000;
pub const List = enum { all, slow, fast, incomplete, records };
const ProjectionKey = struct { session_id: u64, capture_id: u64, job: u64, list: List };
pub const Citation = union(enum) { list: List, row: usize, entry, ret, parent, citing, call: u32 };
const State = struct {
    requester: @import("../service/job_owner.zig").Requester = .{},
    /// Startup threshold for the first comparison; later changes are explicit.
    threshold_ns: ?u64 = null,
    identity: ?[2]u64 = null,
    list: List = .all,
    previous: List = .all,
    call: ?u32 = null,
    record: ?u32 = null,
    /// Call that cites `record`, found once per record selection.
    citing: ?u32 = null,
    top: usize = 0,
    visible: usize = 1,
    projection: std.ArrayList(u32) = .empty,
    key: ?ProjectionKey = null,
    projection_builds: u64 = 0,
    seen_job: u64 = 0,
    failed_open: u64 = 0,
    message: []const u8 = "",
    message_buffer: [192]u8 = undefined,
    trace: bool = false,

    pub fn deinit(self: *State) void {
        self.projection.deinit(std.heap.page_allocator);
    }
    fn capture(session: *Session) ?*model.Capture {
        const value = session.observations.capture orelse return null;
        return if (value.store.finished) value else null;
    }
    fn job(session: *Session, value: *const model.Capture) ?*analysis.Job {
        const current = session.observation_analysis orelse return null;
        return if (std.meta.eql(current.capture.identity, value.identity)) current else null;
    }
    fn say(self: *State, comptime format: []const u8, args: anytype) void {
        self.message = std.fmt.bufPrint(&self.message_buffer, format, args) catch "";
    }
    fn note(self: *State, event: []const u8) void {
        if (!self.trace) return;
        log.info(.session, "observation-view {s} list={s} call={?d} record={?d} top={d} rows={d} builds={d}\n", .{ event, @tagName(self.list), self.call, self.record, self.top, self.visible, self.projection_builds });
    }
    /// Re-resolves the capture and rebuilds the projection only on a key change.
    /// The first sight of a capture requests its comparison once.
    pub fn sync(self: *State, session: *Session) void {
        const value = capture(session) orelse {
            if (session.observation_archive) |archive| if (archive.done.load(.acquire) and archive.err != null and archive.id != self.failed_open) {
                self.failed_open = archive.id;
                if (self.trace) log.info(.session, "observation-view open-failed error={s}\n", .{@errorName(archive.err.?)});
            };
            return;
        };
        const identity = [2]u64{ value.identity.session_id, value.identity.capture_id };
        if (self.identity == null or !std.mem.eql(u64, &self.identity.?, &identity)) {
            self.identity = identity;
            self.list = .all;
            self.previous = .all;
            self.call = if (value.store.calls.items.len > 0) 0 else null;
            self.record = if (value.store.records.items.len > 0) 0 else null;
            self.citing = null;
            self.top = 0;
            self.key = null;
            self.seen_job = 0;
            if (job(session, value) == null) self.recompute(session, self.threshold_ns orelse if (value.comparison_selection) |s| s.threshold_ns else default_threshold_ns);
            self.note("ready");
        }
        if (job(session, value)) |current| if (current.id != self.seen_job and current.done.load(.acquire)) {
            self.seen_job = current.id;
            if (self.trace) {
                if (current.result) |result| {
                    log.info(.session, "observation-view comparison id={d} threshold={d} total={d} matched={d} complete={d} incomplete={d} fast={d} slow={d}\n", .{ current.id, current.selection.threshold_ns, result.summary.total_calls, result.summary.matched_calls, result.summary.complete_calls, result.summary.incomplete_calls, result.fast.count, result.slow.count });
                } else log.info(.session, "observation-view comparison id={d} failed={s}\n", .{ current.id, if (current.err) |err| @errorName(err) else "unknown" });
            }
        };
        const current = job(session, value);
        const key = ProjectionKey{ .session_id = identity[0], .capture_id = identity[1], .job = if (current) |j| j.id else 0, .list = self.list };
        if (self.key != null and std.meta.eql(self.key.?, key)) return;
        self.key = key;
        self.projection.clearRetainingCapacity();
        if (self.list == .all or self.list == .records) return;
        self.projection_builds += 1;
        const store = &value.store;
        self.projection.ensureTotalCapacityPrecise(std.heap.page_allocator, store.calls.items.len) catch {
            self.say("Not enough memory for this list", .{});
            return;
        };
        for (store.calls.items) |item| {
            const keep = switch (self.list) {
                .incomplete => store.duration(item) == null,
                .slow, .fast => if (current) |j| cohort(store, item, j.selection) == self.list else false,
                else => unreachable,
            };
            if (keep) self.projection.appendAssumeCapacity(item.id);
        }
    }
    fn count(self: *const State, value: *const model.Capture) usize {
        return switch (self.list) {
            .all => value.store.calls.items.len,
            .records => value.store.records.items.len,
            else => self.projection.items.len,
        };
    }
    fn rowId(self: *const State, index: usize) u32 {
        return switch (self.list) {
            .all, .records => @intCast(index),
            else => self.projection.items[index],
        };
    }
    /// Row of the current selection in the current list, if it is listed.
    fn position(self: *const State) ?usize {
        const id = (if (self.list == .records) self.record else self.call) orelse return null;
        return switch (self.list) {
            .all, .records => id,
            else => std.sort.binarySearch(u32, self.projection.items, id, order),
        };
    }
    fn order(id: u32, item: u32) std.math.Order {
        return std.math.order(id, item);
    }
    fn select(self: *State, value: *const model.Capture, index: usize) void {
        const total = self.count(value);
        if (total == 0) return;
        const row = @min(index, total - 1);
        const id = self.rowId(row);
        if (self.list == .records) {
            if (self.record != id) self.citeRecord(value, id);
        } else self.call = id;
        if (row < self.top) self.top = row;
        if (row >= self.top + self.visible) self.top = row + 1 - self.visible;
    }
    fn citeRecord(self: *State, value: *const model.Capture, ordinal: u32) void {
        self.record = ordinal;
        self.citing = null;
        for (value.store.calls.items) |item| {
            if (item.entry_record == ordinal or item.return_record == ordinal) {
                self.citing = item.id;
                break;
            }
        }
    }
    fn move(self: *State, value: *const model.Capture, delta: i64) void {
        const total = self.count(value);
        if (total == 0) return;
        const from: i64 = @intCast(self.position() orelse self.top);
        self.select(value, @intCast(std.math.clamp(from + delta, 0, @as(i64, @intCast(total - 1)))));
    }
    fn showList(self: *State, session: *Session, value: *const model.Capture, list: List) void {
        if (list != self.list) {
            self.previous = self.list;
            self.list = list;
        }
        self.sync(session);
        if (self.position()) |row| self.select(value, row) else {
            self.top = 0;
            self.select(value, 0);
        }
    }
    /// The same operation and busy rule as MCP `compare_observation`.
    fn recompute(self: *State, session: *Session, limit: u64) void {
        const value = capture(session) orelse return;
        var selection = if (job(session, value)) |current| current.selection else value.comparison_selection orelse comparison.Selection{ .threshold_ns = default_threshold_ns };
        selection.threshold_ns = limit;
        const id = session.compareObservationOwned(selection, self.requester) catch |err| {
            self.say("Comparison not started: {s}", .{@errorName(err)});
            self.note("recompute-refused");
            return;
        };
        self.say("Comparison #{d} started: threshold {d} ns", .{ id, limit });
        self.note("recompute");
    }
    fn threshold(session: *Session, value: *const model.Capture) u64 {
        return if (job(session, value)) |current| current.selection.threshold_ns else if (value.comparison_selection) |s| s.threshold_ns else default_threshold_ns;
    }
    fn cite(self: *State, session: *Session, value: *const model.Capture, action: Citation) void {
        switch (action) {
            .entry, .ret => {
                const id = self.call orelse return;
                const item = value.store.calls.items[id];
                const ordinal = (if (action == .entry) item.entry_record else item.return_record) orelse {
                    self.say("Call #{d} has no {s} record ({s}); none is inferred", .{ id, if (action == .entry) "entry" else "return", @tagName(item.reason) });
                    self.note("citation-missing");
                    return;
                };
                self.citeRecord(value, ordinal);
                self.showList(session, value, .records);
                self.say("Record #{d} cited by call #{d}", .{ ordinal, id });
                self.note(if (action == .entry) "cite-entry" else "cite-return");
            },
            .parent => {
                const id = self.call orelse return;
                const parent = value.store.calls.items[id].parent_call orelse {
                    self.say("Call #{d} has no recorded parent call", .{id});
                    return;
                };
                self.focusCall(session, value, parent);
                self.note("cite-parent");
            },
            .citing => {
                if (self.list != .records) return;
                const id = self.citing orelse {
                    self.say("Record #{d} is not cited by any call", .{self.record orelse 0});
                    return;
                };
                self.focusCall(session, value, id);
                self.note("cite-call");
            },
            .call => |id| {
                self.focusCall(session, value, id);
                self.note("cite-example");
            },
            else => {},
        }
    }
    fn focusCall(self: *State, session: *Session, value: *const model.Capture, id: u32) void {
        if (id >= value.store.calls.items.len) return;
        self.call = id;
        var list = if (self.list == .records) self.previous else self.list;
        if (list == .records) list = .all;
        self.showList(session, value, list);
        if (self.position() == null) self.showList(session, value, .all);
    }
    fn cycle(list: List) List {
        return switch (list) {
            .all => .slow,
            .slow => .fast,
            .fast => .incomplete,
            .incomplete => .records,
            .records => .all,
        };
    }
};
/// Monospace columns padded by code point, so unit symbols such as µ align.
const Line = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,
    fn add(self: *Line, text: []const u8, width: usize) void {
        const n = @min(text.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len..][0..n], text[0..n]);
        self.len += n;
        var cells = std.unicode.utf8CountCodepoints(text[0..n]) catch n;
        while (cells < width and self.len < self.bytes.len) : (cells += 1) {
            self.bytes[self.len] = ' ';
            self.len += 1;
        }
    }
    fn slice(self: *const Line) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn cohort(store: *const calls.Store, item: types.Call, selection: comparison.Selection) List {
    const duration = store.duration(item) orelse return .incomplete;
    if (comparison.matches(store, item, selection) != .yes) return .all;
    return if (duration >= selection.threshold_ns) .slow else .fast;
}
fn tabName(list: List) []const u8 {
    return switch (list) {
        .all => "All calls",
        .slow => "Slow",
        .fast => "Fast",
        .incomplete => "Incomplete",
        .records => "Raw records",
    };
}
fn functionName(value: *const model.Capture, id: u32) []const u8 {
    for (value.functions) |function| if (function.id == id) return function.name;
    return "?";
}
fn relative(buffer: []u8, value: *const model.Capture, time: u64) []const u8 {
    if (time < value.started_ns) return std.fmt.bufPrint(buffer, "-{d} ns", .{value.started_ns - time}) catch "?";
    return timeline.duration(buffer, time - value.started_ns);
}
fn word(buffer: []u8, sample: types.Sample, index: usize) []const u8 {
    if (index >= sample.arg_count) return "-";
    return std.fmt.bufPrint(buffer, "0x{x}", .{sample.args[index]}) catch "?";
}
fn nsLabel(buffer: []u8, value: ?u64) []const u8 {
    return if (value) |v| timeline.duration(buffer, v) else "n/a";
}

pub const Key = struct { session: u64 = 0, identity: ?[2]u64 = null, job: u64 = 0, revision: u64 = 0 };
pub const Request = struct { visible: usize = 1, threshold_ns: ?u64 = null, trace: bool = false };
pub const Action = struct {
    key: Key,
    kind: union(enum) {
        cite: Citation,
        move: i64,
        scroll: i64,
        back,
        threshold: u64,
        cancel_archive: u64,
        cancel_comparison: u64,
    },
    event: enum { none, click, move, list, back } = .none,
};
pub const Row = struct { ordinal: usize, id: u32, label: []const u8, warm: bool };
pub const CallDetail = struct { item: types.Call, entry: ?types.Event, ret: ?types.Event, duration: ?u64, group: List, function: []const u8 };
pub const RecordDetail = struct { record: types.Record, function: []const u8 };
pub const Distribution = struct { known: u64, distinct: u64, unavailable: u64, values: []const comparison.ValueCount };
pub const Cohort = struct { count: u64, duration: comparison.Duration, arguments: [1]Distribution };
pub const Comparison = struct { summary: comparison.Summary, fast: Cohort, slow: Cohort };
pub const Job = struct { id: u64, done: bool, failure: ?[]const u8, threshold_ns: u64, result: ?Comparison };
pub const View = struct {
    key: Key = .{},
    request: Request = .{},
    identity: ?[2]u64 = null,
    list: List = .all,
    previous: List = .all,
    call: ?u32 = null,
    record: ?u32 = null,
    citing: ?u32 = null,
    top: usize = 0,
    visible: usize = 1,
    position: ?usize = null,
    total: usize = 0,
    calls: usize = 0,
    records: usize = 0,
    projection_builds: u64 = 0,
    ready: bool = false,
    busy: bool = false,
    archive_id: ?u64 = null,
    path: []const u8 = "",
    unavailable: []const u8 = "No observation capture.",
    unavailable_warm: bool = false,
    title: []const u8 = "",
    evidence: []const u8 = "",
    degraded: bool = false,
    started_ns: u64 = 0,
    job: ?Job = null,
    threshold_ns: u64 = default_threshold_ns,
    rows: []const Row = &.{},
    call_detail: ?CallDetail = null,
    record_detail: ?RecordDetail = null,
    message: []const u8 = "",
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    state: State = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    revision: u64 = 0,
    refreshed_ns: u64 = 0,
    pub fn deinit(self: *Capture) void {
        self.state.deinit();
        self.arena.deinit();
    }
    fn current(self: *const Capture, session: *Session) Key {
        const capture = State.capture(session);
        return .{ .session = session.id, .identity = if (capture) |v| .{ v.identity.session_id, v.identity.capture_id } else null, .job = if (capture) |v| if (State.job(session, v)) |j| j.id else 0 else 0, .revision = self.revision };
    }
    pub fn changed(self: *const Capture, session: *Session) bool {
        const view = self.value orelse return false;
        if (!std.meta.eql(view.key, self.current(session))) return true;
        if (session.observation_archive) |archive| {
            if (view.archive_id != archive.id and !archive.done.load(.acquire)) return true;
            if (view.archive_id != null and (archive.done.load(.acquire) or @import("../target/linux.zig").now() -| self.refreshed_ns >= 100 * std.time.ns_per_ms)) return true;
        } else if (view.archive_id != null) return true;
        if (view.job) |j| if (session.observation_analysis) |job| if (j.done != job.done.load(.acquire)) return true;
        return false;
    }
    pub fn apply(self: *Capture, session: *Session, actor: session_model.Actor, action: Action) !void {
        if (!std.meta.eql(action.key, self.current(session))) return error.StaleInvocationView;
        defer self.revision +%= 1;
        self.state.requester = if (actor == .human) .{} else session.jobRequester();
        defer self.state.requester = .{};
        const state = &self.state;
        switch (action.kind) {
            .cancel_archive => |id| {
                // Archive-open is a human frontend action; there is no agent
                // ownership identity in the observation archive format.
                if (actor != .human) return error.JobNotOwned;
                const archive = session.observation_archive orelse return error.NoObservationArchive;
                if (archive.id != id or archive.done.load(.acquire)) return error.StaleObservationArchive;
                archive.progress.cancel.store(true, .release);
                state.say("Cancelling archive open", .{});
            },
            .cancel_comparison => |id| {
                const job = session.observation_analysis orelse return error.NoObservationAnalysis;
                if (job.id != id or job.done.load(.acquire)) return error.StaleObservationAnalysis;
                try job.owner.require(state.requester);
                job.cancel.store(true, .release);
                state.say("Cancelling comparison #{d}", .{id});
            },
            else => {
                const value = State.capture(session) orelse return error.NoEndedObservation;
                switch (action.kind) {
                    .cite => |citation| switch (citation) {
                        .list => |list| state.showList(session, value, list),
                        .row => |row| {
                            if (row >= state.count(value)) return error.StaleInvocationRow;
                            state.select(value, row);
                        },
                        else => state.cite(session, value, citation),
                    },
                    .move => |delta| {
                        if (delta < -64 or delta > 64) return error.InvalidArguments;
                        state.move(value, delta);
                    },
                    .scroll => |delta| {
                        if (delta < -192 or delta > 192) return error.InvalidArguments;
                        state.top = @intCast(std.math.clamp(@as(i64, @intCast(state.top)) + delta, 0, @as(i64, @intCast(state.count(value) -| state.visible))));
                    },
                    .back => state.showList(session, value, if (state.previous == state.list) .all else state.previous),
                    .threshold => |ns| state.recompute(session, ns),
                    else => unreachable,
                }
            },
        }
        if (action.event != .none) state.note(@tagName(action.event));
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const request = wanted orelse {
            self.value = null;
            _ = self.arena.reset(.free_all);
            self.state.projection.deinit(std.heap.page_allocator);
            self.state.projection = .empty;
            self.state.key = null;
            return;
        };
        const bounded: Request = .{ .visible = std.math.clamp(request.visible, 1, 64), .threshold_ns = request.threshold_ns, .trace = request.trace };
        if (self.value) |old| if (std.meta.eql(old.request, bounded) and !self.changed(session)) return;
        self.state.trace = request.trace;
        self.state.threshold_ns = request.threshold_ns;
        self.state.visible = bounded.visible;
        self.state.sync(session);
        _ = self.arena.reset(.retain_capacity);
        self.refreshed_ns = @import("../target/linux.zig").now();
        self.value = .{ .key = self.current(session), .request = bounded };
        self.prepare(session) catch |err| {
            self.value.?.unavailable = @errorName(err);
            self.value.?.unavailable_warm = true;
            self.value.?.ready = false;
        };
    }
    fn copy(self: *Capture, text_value: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text_value[0..@min(text_value.len, 1024)]);
    }
    fn prepare(self: *Capture, session: *Session) !void {
        const a = self.arena.allocator();
        const view = &self.value.?;
        const state = &self.state;
        view.message = try self.copy(state.message);
        if (session.observation_archive) |archive| {
            view.path = try self.copy(archive.path);
            const status = archive.status();
            if (status.state == .running) {
                view.archive_id = archive.id;
                view.busy = true;
                view.unavailable = try std.fmt.allocPrint(a, "Opening on worker: {s} ({d} units). Esc cancels.", .{ @tagName(status.phase), status.units });
            } else {
                view.unavailable = try std.fmt.allocPrint(a, "Open {s}: {s}. Nothing is shown from an unverified archive.", .{ @tagName(status.state), status.error_name orelse "no capture" });
                view.unavailable_warm = true;
            }
        } else if (session.observations.capture != null) view.unavailable = "Capture still collecting; stop it to browse calls.";
        const value = State.capture(session) orelse return;
        const store = &value.store;
        const current_job = State.job(session, value);
        view.ready = true;
        view.identity = state.identity;
        view.list = state.list;
        view.previous = state.previous;
        view.call = state.call;
        view.record = state.record;
        view.citing = state.citing;
        view.visible = state.visible;
        view.total = state.count(value);
        state.top = @min(state.top, view.total -| state.visible);
        view.top = state.top;
        view.position = state.position();
        view.calls = store.calls.items.len;
        view.records = store.records.items.len;
        view.projection_builds = state.projection_builds;
        view.started_ns = value.started_ns;
        view.threshold_ns = State.threshold(session, value);
        var names: [256]u8 = undefined;
        var names_len: usize = 0;
        for (value.functions, 0..) |function, i| {
            const piece = std.fmt.bufPrint(names[names_len..], "{s}{s}", .{ if (i == 0) "" else ", ", function.name }) catch break;
            names_len += piece.len;
        }
        view.title = try std.fmt.allocPrint(a, "{s} #{d}/{d}  pid {d}  {s}  threads {d}  records {d}  calls {d}  stop {s}  finish {s}", .{ if (value.offline) "Saved" else "Live", value.identity.session_id, value.identity.capture_id, value.identity.pid, names[0..names_len], value.threads.len, store.records.items.len, store.calls.items.len, if (value.stop_reason) |s| @tagName(s) else "none", if (store.finish_reason) |s| @tagName(s) else "none" });
        view.degraded = store.lost > 0 or store.throttles > 0 or store.rejected > 0 or store.first_gap != null or store.unread_possible;
        var buffer: [64]u8 = undefined;
        view.evidence = if (store.first_gap) |gap| try std.fmt.allocPrint(a, "Loss: {d} lost events  {d} throttles  {d} rejected  first gap {s} at record {s}  unread suffix possible: {s}", .{ store.lost, store.throttles, store.rejected, @tagName(gap.reason), if (gap.record) |n| try std.fmt.bufPrint(&buffer, "#{d}", .{n}) else "end", if (store.unread_possible) "yes" else "no" }) else try std.fmt.allocPrint(a, "Loss: {d} lost events  {d} throttles  {d} rejected  no gap  unread suffix possible: {s}", .{ store.lost, store.throttles, store.rejected, if (store.unread_possible) "yes" else "no" });
        if (current_job) |job| {
            const done = job.done.load(.acquire);
            view.busy = view.busy or !done;
            view.job = .{ .id = job.id, .done = done, .failure = if (done) if (job.err) |err| @errorName(err) else null else null, .threshold_ns = job.selection.threshold_ns, .result = null };
            if (done) if (job.result) |result| {
                view.job.?.result = .{ .summary = result.summary, .fast = try self.cohortView(result.fast), .slow = try self.cohortView(result.slow) };
            };
        }
        try self.prepareRows(value, current_job);
        if (state.call) |id| if (id < store.calls.items.len) {
            const item = store.calls.items[id];
            view.call_detail = .{ .item = item, .entry = if (item.entry_record) |n| store.records.items[n].event else null, .ret = if (item.return_record) |n| store.records.items[n].event else null, .duration = store.duration(item), .group = if (current_job) |j| cohort(store, item, j.selection) else .all, .function = try self.copy(functionName(value, item.function_id)) };
        };
        if (state.record) |id| if (id < store.records.items.len) {
            const record = store.records.items[id];
            view.record_detail = .{ .record = record, .function = if (record.event.data == .sample) try self.copy(functionName(value, record.event.data.sample.function_id)) else "" };
        };
    }
    fn cohortView(self: *Capture, source: comparison.Cohort) !Cohort {
        const d = source.arguments[0];
        return .{ .count = source.count, .duration = source.duration, .arguments = .{.{ .known = d.known, .distinct = d.distinct, .unavailable = d.unavailable, .values = try self.arena.allocator().dupe(comparison.ValueCount, d.values[0..@min(d.values.len, 3)]) }} };
    }
    fn prepareRows(self: *Capture, value: *const model.Capture, current_job: ?*analysis.Job) !void {
        const a = self.arena.allocator();
        const view = &self.value.?;
        const store = &value.store;
        var buffer_rel: [64]u8 = undefined;
        var rows: std.ArrayList(Row) = .empty;
        for (view.top..@min(view.total, view.top + view.visible)) |row| {
            const id = self.state.rowId(row);
            var line = Line{};
            var piece: [64]u8 = undefined;
            line.add(std.fmt.bufPrint(&piece, "#{d}", .{id}) catch "?", 8);
            if (view.list == .records) {
                const event = store.records.items[id].event;
                line.add(std.fmt.bufPrint(&piece, "T{d}/{d}", .{ event.thread_id, event.tid }) catch "?", 10);
                line.add(relative(&buffer_rel, value, event.time_ns), 12);
                switch (event.data) {
                    .sample => |sample| {
                        line.add(if (sample.phase == .enter) "enter" else "return", 8);
                        line.add(functionName(value, sample.function_id), 15);
                        if (sample.phase == .enter) {
                            line.add(if (sample.arg_count > 0) std.fmt.bufPrint(&piece, "DI 0x{x}", .{sample.args[0]}) catch "?" else "DI -", 0);
                        } else line.add(if (sample.result) |bits| std.fmt.bufPrint(&piece, "AX 0x{x}", .{bits}) catch "?" else "AX -", 0);
                    },
                    .lost => |n| line.add(std.fmt.bufPrint(&piece, "LOST {d} events", .{n}) catch "?", 0),
                    else => line.add(@tagName(event.data), 0),
                }
                try rows.append(a, .{ .ordinal = row, .id = id, .label = try self.copy(line.slice()), .warm = event.data != .sample });
            } else {
                const item = store.calls.items[id];
                const entry = if (item.entry_record) |n| store.records.items[n].event else null;
                const duration = store.duration(item);
                const group: List = if (duration == null) .incomplete else if (current_job) |j| cohort(store, item, j.selection) else .all;
                line.add(std.fmt.bufPrint(&piece, "T{d}/{d}", .{ item.thread_id, item.tid }) catch "?", 10);
                line.add(functionName(value, item.function_id), 15);
                line.add(if (entry) |e| relative(&buffer_rel, value, e.time_ns) else "no entry", 12);
                line.add(if (duration) |d| timeline.duration(&piece, d) else @tagName(item.reason), 15);
                line.add(switch (group) {
                    .slow => "slow",
                    .fast => "fast",
                    .incomplete => "incompl",
                    else => "-",
                }, 9);
                line.add(if (entry) |e| word(&piece, e.data.sample, 0) else "-", 0);
                try rows.append(a, .{ .ordinal = row, .id = id, .label = try self.copy(line.slice()), .warm = group == .incomplete });
            }
        }
        view.rows = rows.items;
    }
};

test "row columns pad by code point" {
    var line = Line{};
    line.add("+1.000 \u{b5}s", 12);
    line.add("enter", 0);
    var plain = Line{};
    plain.add("+1.000 ms", 12);
    plain.add("enter", 0);
    try std.testing.expectEqual(std.unicode.utf8CountCodepoints(line.slice()) catch 0, std.unicode.utf8CountCodepoints(plain.slice()) catch 1);
}

test "invocation pages retire capture storage and refuse stale citation commands" {
    const a = std.testing.allocator;
    var session = Session{ .id = 1, .offline = true };
    defer session.deinit();
    const identity = model.Identity{ .session_id = 7, .capture_id = 1, .process_id = 1, .pid = 100, .image_epoch = 1, .generation = 1 };
    const functions = [_]model.Function{.{ .id = 1, .name = "work", .path = "/fixture", .identity = std.mem.zeroes(@import("../profile/uprobe_hooks.zig").Identity), .file_offset = 0, .link_address = 0, .runtime_address = 0x1000 }};
    const value = try model.Capture.create(a, identity, .{}, &.{.{ .id = 1, .tid = 101 }}, &functions);
    session.observations.capture = value;
    for (0..100) |i| {
        try value.feed(calls.fixtureEvent(i * 100, 1, .enter, 1, 100));
        try value.feed(calls.fixtureEvent(i * 100 + 10, 1, .leave, 1, 100));
    }
    value.store.finish(.capture_end);
    var owner = Capture{};
    defer owner.deinit();
    owner.refresh(&session, .{ .visible = 1000, .threshold_ns = 50 });
    try std.testing.expectEqual(@as(usize, 64), owner.value.?.rows.len);
    const old = owner.value.?.key;
    try owner.apply(&session, .human, .{ .key = old, .kind = .{ .cite = .{ .call = 3 } } });
    owner.refresh(&session, .{ .visible = 64, .threshold_ns = 50 });
    try std.testing.expectError(error.StaleInvocationView, owner.apply(&session, .human, .{ .key = old, .kind = .{ .cite = .ret } }));
    try std.testing.expectEqual(@as(?u32, 3), owner.value.?.call);
    const boundary = @import("remote_owner.zig");
    const publication = try boundary.Publication.create(a, .{ .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 100, .image_epoch = 1, .generation = 1 }, .revision = 1, .taken_ns = 1, .status = .ready, .invocations = owner.value });
    defer publication.destroy();
    if (session.observation_analysis) |job| job.deinit();
    session.observation_analysis = null;
    value.deinit();
    session.observations.capture = null;
    owner.refresh(&session, null);
    try std.testing.expectEqual(@as(usize, 0), owner.arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 0), owner.state.projection.capacity);
    try std.testing.expectEqualStrings("work", publication.value.invocations.?.call_detail.?.function);
    try std.testing.expectEqual(@as(?u64, 10), publication.value.invocations.?.call_detail.?.duration);
    try std.testing.expectEqual(@as(u32, 3), publication.value.invocations.?.call_detail.?.item.id);
}
