//! Bounded, transport-independent invocation pairing. Raw evidence is retained
//! once, and call IDs/citations are stable. A lane is quarantined after a gap:
//! stale uretprobe returns must not make a later entry look like a proven pair.
const std = @import("std");
pub const types = @import("types.zig");
pub const Event = types.Event;
pub const Reason = types.Reason;
pub const Call = types.Call;
pub const Record = types.Record;
const Allocator = std.mem.Allocator;
pub const max_threads = 128;
pub const max_depth = 64;
pub const max_records = 1024 * 1024;
pub const Config = struct {
    record_limit: usize = 32768,
    thread_limit: usize = 32,
    depth_limit: usize = 32,
    memory_limit: usize = 64 * 1024 * 1024,
};
const Lane = struct {
    thread_id: u64,
    tid: u32,
    stack: [max_depth]u32 = undefined,
    depth: usize = 0,
    last_ns: u64 = 0,
    poison: ?Reason = null,
    closed: bool = false,
};
pub const Store = struct {
    config: Config,
    records: std.ArrayList(Record) = .empty,
    calls: std.ArrayList(Call) = .empty,
    lanes: std.ArrayList(Lane) = .empty,
    finished: bool = false,
    finish_reason: ?Reason = null,
    first_gap: ?types.Gap = null,
    lost: u64 = 0,
    rejected: u64 = 0,
    nested: u64 = 0,
    throttles: u64 = 0,
    unread_possible: bool = false,

    pub fn init(config: Config) !Store {
        if (config.record_limit == 0 or config.record_limit > max_records or
            config.thread_limit == 0 or config.thread_limit > max_threads or
            config.depth_limit == 0 or config.depth_limit > max_depth or
            config.memory_limit == 0 or config.memory_limit > 512 * 1024 * 1024)
            return error.InvalidObservationConfig;
        return .{ .config = config };
    }
    pub fn deinit(self: *Store, a: Allocator) void {
        self.records.deinit(a);
        self.calls.deinit(a);
        self.lanes.deinit(a);
    }
    pub fn allocatedBytes(self: *const Store) usize {
        return self.records.capacity * @sizeOf(Record) + self.calls.capacity * @sizeOf(Call) + self.lanes.capacity * @sizeOf(Lane);
    }
    fn gap(self: *Store, reason: Reason, ordinal: ?u32) void {
        if (self.first_gap == null) self.first_gap = .{ .reason = reason, .record = ordinal };
    }
    fn boundary(self: *Store, lane: *Lane, reason: Reason) void {
        for (lane.stack[0..lane.depth]) |id| self.calls.items[id].reason = reason;
        lane.depth = 0;
    }
    fn quarantine(self: *Store, lane: *Lane, reason: Reason, ordinal: u32) void {
        self.gap(reason, ordinal);
        self.boundary(lane, reason);
        if (lane.poison == null) lane.poison = reason;
    }
    /// Finish after disabling/draining sources. Use .unread if draining is not
    /// complete. This never changes an already complete call or its duration.
    pub fn finish(self: *Store, reason: Reason) void {
        std.debug.assert(reason != .pending and reason != .complete);
        if (self.finished) return;
        for (self.lanes.items) |*lane| {
            if (lane.depth != 0) self.gap(reason, null);
            self.boundary(lane, reason);
        }
        self.finished = true;
        self.finish_reason = reason;
        if (switch (reason) {
            .record_limit, .thread_limit, .memory_limit, .decode_error, .identity, .scope_changed, .unread => true,
            else => false,
        }) {
            self.unread_possible = true;
            self.gap(reason, null);
        }
    }
    fn nextCapacity(current: usize, needed: usize, limit: usize) usize {
        return if (needed <= current) current else @min(limit, @max(8, current * 2));
    }
    fn reserve(self: *Store, a: Allocator, sample: bool, new_lane: bool) !void {
        const nr = nextCapacity(self.records.capacity, self.records.items.len + 1, self.config.record_limit);
        const nc = nextCapacity(self.calls.capacity, self.calls.items.len + @intFromBool(sample), self.config.record_limit);
        const nl = nextCapacity(self.lanes.capacity, self.lanes.items.len + @intFromBool(new_lane), self.config.thread_limit);
        const bytes = nr * @sizeOf(Record) + nc * @sizeOf(Call) + nl * @sizeOf(Lane);
        if (bytes > self.config.memory_limit) return error.ObservationMemoryLimit;
        // All potentially failing allocations precede accepted evidence/state.
        // A successful earlier reserve may change capacity, never contents.
        try self.records.ensureTotalCapacityPrecise(a, nr);
        try self.calls.ensureTotalCapacityPrecise(a, nc);
        try self.lanes.ensureTotalCapacityPrecise(a, nl);
    }
    fn unpaired(self: *Store, event: Event, ordinal: u32, reason: Reason) void {
        const sample = event.data.sample;
        self.calls.appendAssumeCapacity(.{
            .id = @intCast(self.calls.items.len),
            .thread_id = event.thread_id,
            .tid = event.tid,
            .function_id = sample.function_id,
            .entry_record = if (sample.phase == .enter) ordinal else null,
            .return_record = if (sample.phase == .leave) ordinal else null,
            .reason = reason,
        });
    }
    /// Structural uncertainty is accepted as raw evidence and quarantines only
    /// its lane. Resource/config/identity errors end the store and return an
    /// error; no partial raw record is appended on allocation failure.
    pub fn feed(self: *Store, a: Allocator, event: Event) !void {
        if (self.finished) return error.ObservationFinished;
        if (event.thread_id == 0 or event.tid == 0 or (event.data == .sample and
            (event.data.sample.function_id == 0 or event.data.sample.arg_count > types.max_arguments or event.data.sample.stack.len > types.max_stack_pcs or event.data.sample.stack_word_size > 8 or event.data.sample.stack_word_valid > event.data.sample.stack_word_size)))
        {
            self.rejected +|= 1;
            self.finish(.identity);
            return error.InvalidObservationEvent;
        }
        if (self.records.items.len == self.config.record_limit) {
            self.rejected +|= 1;
            self.finish(.record_limit);
            return error.ObservationRecordLimit;
        }
        var index: ?usize = null;
        for (self.lanes.items, 0..) |lane, i| {
            if (lane.thread_id == event.thread_id) {
                if (lane.tid != event.tid or lane.closed) {
                    self.rejected +|= 1;
                    self.finish(.identity);
                    return error.InvalidObservationIdentity;
                }
                index = i;
                break;
            }
            if (lane.tid == event.tid and !lane.closed) {
                self.rejected +|= 1;
                self.finish(.identity);
                return error.InvalidObservationIdentity;
            }
        }
        if (index == null and self.lanes.items.len == self.config.thread_limit) {
            self.rejected +|= 1;
            self.finish(.thread_limit);
            return error.ObservationThreadLimit;
        }
        self.reserve(a, event.data == .sample, index == null) catch |err| {
            self.rejected +|= 1;
            self.finish(.memory_limit);
            return err;
        };
        if (index == null) {
            index = self.lanes.items.len;
            self.lanes.appendAssumeCapacity(.{ .thread_id = event.thread_id, .tid = event.tid });
        }
        const ordinal: u32 = @intCast(self.records.items.len);
        self.records.appendAssumeCapacity(.{ .ordinal = ordinal, .event = event });
        const lane = &self.lanes.items[index.?];
        // The explicit loss count remains evidence even if its clock is bad.
        if (event.data == .lost) self.lost +|= event.data.lost;
        if (event.data == .throttle) self.throttles +|= 1;
        if (event.time_ns < lane.last_ns) {
            self.quarantine(lane, .time_reversed, ordinal);
            if (event.data == .sample) self.unpaired(event, ordinal, .time_reversed);
            // A reversed terminal event still closes the relevant identity.
            if (event.data == .thread_exit) lane.closed = true;
            if (event.data == .exec) self.finish(.exec);
            if (event.data == .mapping_change or event.data == .fork) self.finish(.scope_changed);
            return;
        }
        lane.last_ns = event.time_ns;
        switch (event.data) {
            .lost => self.quarantine(lane, .loss, ordinal),
            .throttle, .unthrottle => self.quarantine(lane, .throttle, ordinal),
            .decode_error => self.quarantine(lane, .decode_error, ordinal),
            .thread_exit => {
                if (lane.depth != 0) self.gap(.thread_exit, ordinal);
                self.boundary(lane, .thread_exit);
                lane.closed = true;
            },
            .exec => {
                self.gap(.exec, ordinal);
                self.finish(.exec);
            },
            .mapping_change, .fork => {
                self.gap(.scope_changed, ordinal);
                self.finish(.scope_changed);
            },
            .sample => |sample| {
                if (lane.poison) |reason| {
                    self.unpaired(event, ordinal, reason);
                    return;
                }
                if (sample.stack_key == 0) {
                    self.quarantine(lane, .stack_mismatch, ordinal);
                    self.unpaired(event, ordinal, .stack_mismatch);
                    return;
                }
                if (sample.phase == .enter) {
                    if (lane.depth != 0) {
                        const parent = self.calls.items[lane.stack[lane.depth - 1]];
                        const previous = self.records.items[parent.entry_record.?].event.data.sample;
                        if (sample.stack_key >= previous.stack_key) {
                            self.quarantine(lane, .stack_changed, ordinal);
                            self.unpaired(event, ordinal, .stack_changed);
                            return;
                        }
                    }
                    if (lane.depth == self.config.depth_limit) {
                        self.quarantine(lane, .nesting_limit, ordinal);
                        self.unpaired(event, ordinal, .nesting_limit);
                        return;
                    }
                    const id: u32 = @intCast(self.calls.items.len);
                    self.calls.appendAssumeCapacity(.{
                        .id = id,
                        .thread_id = event.thread_id,
                        .tid = event.tid,
                        .function_id = sample.function_id,
                        .entry_record = ordinal,
                        .parent_call = if (lane.depth == 0) null else lane.stack[lane.depth - 1],
                    });
                    if (lane.depth != 0) self.nested +|= 1;
                    lane.stack[lane.depth] = id;
                    lane.depth += 1;
                } else {
                    if (lane.depth == 0) {
                        self.quarantine(lane, .missing_entry, ordinal);
                        self.unpaired(event, ordinal, .missing_entry);
                        return;
                    }
                    const call = &self.calls.items[lane.stack[lane.depth - 1]];
                    const entry = self.records.items[call.entry_record.?].event.data.sample;
                    const mismatch: ?Reason = if (entry.function_id != sample.function_id) .function_mismatch else if (entry.stack_key != sample.stack_key) .stack_mismatch else null;
                    if (mismatch) |reason| {
                        self.quarantine(lane, reason, ordinal);
                        self.unpaired(event, ordinal, reason);
                        return;
                    }
                    call.return_record = ordinal;
                    call.reason = .complete;
                    lane.depth -= 1;
                }
            },
        }
    }
    pub fn callById(self: *const Store, id: u32) ?*const Call {
        return if (id < self.calls.items.len) &self.calls.items[id] else null;
    }
    pub fn recordByOrdinal(self: *const Store, ordinal: u32) ?*const Record {
        return if (ordinal < self.records.items.len) &self.records.items[ordinal] else null;
    }
    pub fn duration(self: *const Store, call: Call) ?u64 {
        if (call.reason != .complete) return null;
        const entry = self.records.items[call.entry_record.?].event;
        const ret = self.records.items[call.return_record.?].event;
        return ret.time_ns - entry.time_ns;
    }
    /// Borrowed immutable slices: valid until deinit. Ended stores never append.
    pub fn callPage(self: *const Store, offset: usize, limit: usize) ![]const Call {
        if (!self.finished) return error.ObservationStillCollecting;
        if (limit > 4096) return error.ObservationPageLimit;
        if (offset >= self.calls.items.len) return &.{};
        return self.calls.items[offset .. offset + @min(limit, self.calls.items.len - offset)];
    }
    pub fn recordPage(self: *const Store, offset: usize, limit: usize) ![]const Record {
        if (!self.finished) return error.ObservationStillCollecting;
        if (limit > 4096) return error.ObservationPageLimit;
        if (offset >= self.records.items.len) return &.{};
        return self.records.items[offset .. offset + @min(limit, self.records.items.len - offset)];
    }
};

pub fn fixtureEvent(time: u64, thread_id: u64, phase: types.Phase, function_id: u32, key: u64) Event {
    return .{ .time_ns = time, .thread_id = thread_id, .tid = @intCast(thread_id + 100), .data = .{ .sample = .{ .phase = phase, .function_id = function_id, .stack_key = key } } };
}
test "recursive and nested calls retain independent thread ordering and raw bits" {
    const a = std.testing.allocator;
    var store = try Store.init(.{});
    defer store.deinit(a);
    var entry = fixtureEvent(10, 1, .enter, 3, 100);
    entry.data.sample.arg_count = 2;
    entry.data.sample.args[0] = 0xffffffffffffffff;
    entry.data.sample.stack = .{ .pcs = .{0xff0000} ++ @as([31]u64, @splat(0)), .len = 1 };
    try store.feed(a, entry);
    try store.feed(a, fixtureEvent(11, 1, .enter, 3, 80));
    try store.feed(a, fixtureEvent(12, 1, .leave, 3, 80));
    try store.feed(a, fixtureEvent(20, 1, .leave, 3, 100));
    try store.feed(a, fixtureEvent(1, 2, .enter, 5, 900));
    try store.feed(a, fixtureEvent(4, 2, .leave, 5, 900));
    try std.testing.expectError(error.ObservationStillCollecting, store.callPage(0, 10));
    store.finish(.capture_end);
    try std.testing.expectEqual(@as(usize, 3), (try store.callPage(0, 10)).len);
    try std.testing.expectEqual(@as(?u32, 0), store.calls.items[1].parent_call);
    try std.testing.expectEqual(@as(?u64, 10), store.duration(store.calls.items[0]));
    try std.testing.expectEqual(@as(?u64, 1), store.duration(store.calls.items[1]));
    try std.testing.expectEqual(@as(?u64, 3), store.duration(store.calls.items[2]));
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), store.records.items[0].event.data.sample.args[0]);
    try std.testing.expectEqual(@as(u64, 0xff0000), store.records.items[0].event.data.sample.stack.pcs[0]);
    try std.testing.expectEqual(@as(usize, 0), (try store.recordPage(std.math.maxInt(usize), 10)).len);
    try std.testing.expectError(error.ObservationFinished, store.feed(a, entry));
}
test "loss quarantines a lane and never pairs stale returns with new entries" {
    const a = std.testing.allocator;
    var store = try Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
    try store.feed(a, .{ .thread_id = 1, .tid = 101, .time_ns = 2, .data = .{ .lost = 4 } });
    try store.feed(a, fixtureEvent(3, 1, .enter, 1, 100));
    try store.feed(a, fixtureEvent(4, 1, .leave, 1, 100));
    try store.feed(a, fixtureEvent(5, 1, .leave, 1, 100));
    try store.feed(a, fixtureEvent(1, 2, .enter, 1, 100));
    try store.feed(a, fixtureEvent(2, 2, .leave, 1, 100));
    store.finish(.capture_end);
    for (store.calls.items[0..4]) |call| {
        try std.testing.expectEqual(Reason.loss, call.reason);
        try std.testing.expectEqual(@as(?u64, null), store.duration(call));
    }
    try std.testing.expectEqual(Reason.complete, store.calls.items[4].reason);
    try std.testing.expectEqual(@as(u64, 4), store.lost);
}
test "tail aliases nonlocal escapes reversed clocks and wrong returns are incomplete" {
    const a = std.testing.allocator;
    for (0..5) |scenario| {
        var store = try Store.init(.{});
        defer store.deinit(a);
        try store.feed(a, fixtureEvent(5, 1, .enter, 1, 100));
        const event = switch (scenario) {
            0 => fixtureEvent(6, 1, .enter, 1, 100),
            1 => fixtureEvent(6, 1, .enter, 1, 120),
            2 => fixtureEvent(4, 1, .leave, 1, 100),
            3 => fixtureEvent(6, 1, .leave, 2, 100),
            else => fixtureEvent(6, 1, .leave, 1, 120),
        };
        try store.feed(a, event);
        try store.feed(a, fixtureEvent(7, 1, .leave, 1, 100));
        store.finish(.capture_end);
        try std.testing.expectEqual(@as(usize, 3), store.records.items.len);
        for (store.calls.items) |call| try std.testing.expect(store.duration(call) == null);
    }
}
test "terminal boundaries retain pending calls and completed prefix" {
    const a = std.testing.allocator;
    for ([_]Reason{ .cancelled, .stop, .process_exit, .exec, .unread }) |reason| {
        var store = try Store.init(.{});
        defer store.deinit(a);
        try store.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
        try store.feed(a, fixtureEvent(2, 1, .leave, 1, 100));
        try store.feed(a, fixtureEvent(3, 1, .enter, 1, 100));
        store.finish(reason);
        try std.testing.expectEqual(Reason.complete, store.calls.items[0].reason);
        try std.testing.expectEqual(reason, store.calls.items[1].reason);
    }
}
test "record thread depth and byte limits preserve accepted evidence" {
    const a = std.testing.allocator;
    var short = try Store.init(.{ .record_limit = 1 });
    defer short.deinit(a);
    try short.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
    try std.testing.expectError(error.ObservationRecordLimit, short.feed(a, fixtureEvent(2, 1, .leave, 1, 100)));
    try std.testing.expectEqual(Reason.record_limit, short.calls.items[0].reason);
    try std.testing.expectEqual(@as(usize, 1), short.records.items.len);
    var threads = try Store.init(.{ .thread_limit = 1 });
    defer threads.deinit(a);
    try threads.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
    try std.testing.expectError(error.ObservationThreadLimit, threads.feed(a, fixtureEvent(1, 2, .enter, 1, 100)));
    var deep = try Store.init(.{ .depth_limit = 1 });
    defer deep.deinit(a);
    try deep.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
    try deep.feed(a, fixtureEvent(2, 1, .enter, 1, 80));
    try std.testing.expectEqual(Reason.nesting_limit, deep.calls.items[0].reason);
    try std.testing.expectEqual(Reason.nesting_limit, deep.calls.items[1].reason);
    var tiny = try Store.init(.{ .memory_limit = 1 });
    defer tiny.deinit(a);
    try std.testing.expectError(error.ObservationMemoryLimit, tiny.feed(a, fixtureEvent(1, 1, .enter, 1, 100)));
    try std.testing.expectEqual(@as(usize, 0), tiny.records.items.len);
    try std.testing.expectEqual(@as(usize, 0), tiny.allocatedBytes());
}
test "thread exit permits TID reuse only under a new stable identity" {
    const a = std.testing.allocator;
    var store = try Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, fixtureEvent(1, 1, .enter, 1, 100));
    try store.feed(a, .{ .time_ns = 2, .thread_id = 1, .tid = 101, .data = .thread_exit });
    var next = fixtureEvent(3, 2, .enter, 1, 100);
    next.tid = 101;
    try store.feed(a, next);
    next.time_ns = 4;
    next.data.sample.phase = .leave;
    try store.feed(a, next);
    store.finish(.capture_end);
    try std.testing.expectEqual(Reason.thread_exit, store.calls.items[0].reason);
    try std.testing.expectEqual(Reason.complete, store.calls.items[1].reason);
}
fn allocationFailure(a: Allocator) !void {
    var store = try Store.init(.{});
    defer store.deinit(a);
    for (0..100) |i| {
        try store.feed(a, fixtureEvent(i * 2, 1 + i % 8, .enter, 1, 100));
        try store.feed(a, fixtureEvent(i * 2 + 1, 1 + i % 8, .leave, 1, 100));
    }
    store.finish(.capture_end);
    try std.testing.expectEqual(@as(usize, 100), store.calls.items.len);
}
test "all allocation failures release storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

test "failed reserve preserves a completed prefix and raw pending entry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const a = failing.allocator();
    var store = try Store.init(.{});
    defer store.deinit(a);
    // Fill the initial eight-record capacity, ending with a pending entry.
    for (0..3) |i| {
        try store.feed(a, fixtureEvent(i * 2, 1, .enter, 1, 100));
        try store.feed(a, fixtureEvent(i * 2 + 1, 1, .leave, 1, 100));
    }
    try store.feed(a, .{ .time_ns = 6, .thread_id = 2, .tid = 102, .data = .thread_exit });
    try store.feed(a, fixtureEvent(7, 1, .enter, 1, 100));
    const saved = store.records.items[7];
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expectError(error.OutOfMemory, store.feed(a, fixtureEvent(8, 1, .leave, 1, 100)));
    try std.testing.expectEqual(@as(usize, 8), store.records.items.len);
    try std.testing.expectEqualDeep(saved, store.records.items[7]);
    for (store.calls.items[0..3]) |call| try std.testing.expectEqual(@as(?u64, 1), store.duration(call));
    try std.testing.expectEqual(Reason.memory_limit, store.calls.items[3].reason);
    try std.testing.expect(store.finished and store.unread_possible);
    try std.testing.expect(store.allocatedBytes() <= store.config.memory_limit);
}
test "missing entry zero stack and invalid identities never fabricate pairs" {
    const a = std.testing.allocator;
    var orphan = try Store.init(.{});
    defer orphan.deinit(a);
    try orphan.feed(a, fixtureEvent(1, 1, .leave, 1, 100));
    try orphan.feed(a, fixtureEvent(2, 1, .enter, 1, 100));
    try orphan.feed(a, fixtureEvent(3, 1, .leave, 1, 100));
    orphan.finish(.capture_end);
    for (orphan.calls.items) |call| try std.testing.expectEqual(Reason.missing_entry, call.reason);
    var keyless = try Store.init(.{});
    defer keyless.deinit(a);
    try keyless.feed(a, fixtureEvent(1, 1, .enter, 1, 0));
    try std.testing.expectEqual(Reason.stack_mismatch, keyless.calls.items[0].reason);
    var wrong = fixtureEvent(2, 1, .leave, 1, 100);
    wrong.tid = 999;
    try std.testing.expectError(error.InvalidObservationIdentity, keyless.feed(a, wrong));
    try std.testing.expectEqual(@as(usize, 1), keyless.records.items.len);
}
test "exec closes all lanes and clock reversal does not erase a loss count" {
    const a = std.testing.allocator;
    var store = try Store.init(.{});
    defer store.deinit(a);
    try store.feed(a, fixtureEvent(10, 1, .enter, 1, 100));
    try store.feed(a, .{ .time_ns = 9, .thread_id = 1, .tid = 101, .data = .{ .lost = 9 } });
    try store.feed(a, fixtureEvent(20, 2, .enter, 1, 100));
    try store.feed(a, .{ .time_ns = 21, .thread_id = 2, .tid = 102, .data = .exec });
    try std.testing.expectEqual(@as(u64, 9), store.lost);
    try std.testing.expectEqual(Reason.time_reversed, store.calls.items[0].reason);
    try std.testing.expectEqual(Reason.exec, store.calls.items[1].reason);
    try std.testing.expect(store.finished);
}

test "mapping and fork boundaries end all lanes while preserving partial raw stack words" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |forked| {
        var store = try Store.init(.{});
        defer store.deinit(a);
        var entry = fixtureEvent(1, 1, .enter, 1, 100);
        entry.data.sample.stack_word = .{ 0xde, 0xad, 0xbe, 0, 0, 0, 0, 0 };
        entry.data.sample.stack_word_size = 8;
        entry.data.sample.stack_word_valid = 3;
        try store.feed(a, entry);
        try store.feed(a, fixtureEvent(1, 2, .enter, 1, 100));
        try store.feed(a, .{ .time_ns = 2, .thread_id = 1, .tid = 101, .data = if (forked) .fork else .mapping_change });
        try std.testing.expect(store.finished and store.unread_possible);
        for (store.calls.items) |call| try std.testing.expectEqual(Reason.scope_changed, call.reason);
        try std.testing.expectEqual(@as(u8, 3), store.records.items[0].event.data.sample.stack_word_valid);
        try std.testing.expectEqual(@as(u8, 0xbe), store.records.items[0].event.data.sample.stack_word[2]);
    }
}
