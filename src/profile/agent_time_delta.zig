//! Immutable work-log documents. Splice updates share records, never old arenas.
const std = @import("std");
const Allocator = std.mem.Allocator;
const V = std.json.Value;
const names = [_][]const u8{ "turns", "spans", "tokens" };
const limits = [_]usize{ 20000, 150000, 150000 };
fn field(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn list(v: V) ![]const V {
    return switch (v) {
        .array => v.array.items,
        .null => &.{},
        else => error.InvalidLiveDelta,
    };
}
fn index(v: V) !usize {
    if (v != .integer or v.integer < 0) return error.InvalidLiveDelta;
    return std.math.cast(usize, v.integer) orelse error.InvalidLiveDelta;
}
fn clone(a: Allocator, v: V, depth: usize) anyerror!V {
    if (depth > 32) return error.InvalidLiveDelta;
    return switch (v) {
        .string => .{ .string = try a.dupe(u8, v.string) },
        .number_string => .{ .number_string = try a.dupe(u8, v.number_string) },
        .array => blk: {
            var out = std.json.Array.init(a);
            try out.ensureTotalCapacity(v.array.items.len);
            for (v.array.items) |item| out.appendAssumeCapacity(try clone(a, item, depth + 1));
            break :blk .{ .array = out };
        },
        .object => blk: {
            var out: std.json.ObjectMap = .empty;
            var it = v.object.iterator();
            while (it.next()) |entry| try out.put(a, try a.dupe(u8, entry.key_ptr.*), try clone(a, entry.value_ptr.*, depth + 1));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

const Chunk = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(usize) = .init(1),
    fn create(a: Allocator) !*Chunk {
        const self = try a.create(Chunk);
        self.* = .{ .allocator = a, .arena = .init(a) };
        return self;
    }
    fn retain(self: *Chunk) *Chunk {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *Chunk) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
};
const Row = struct { value: V, chunk: *Chunk };
const Rows = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(usize) = .init(1),
    rows: []Row,
    values: []V,
    filled: usize = 0,
    fn create(a: Allocator, count: usize) !*Rows {
        const self = try a.create(Rows);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .rows = &.{}, .values = &.{} };
        errdefer self.arena.deinit();
        self.rows = try self.arena.allocator().alloc(Row, count);
        self.values = try self.arena.allocator().alloc(V, count);
        return self;
    }
    fn retain(self: *Rows) *Rows {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *Rows) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.rows[0..self.filled]) |row| row.chunk.release();
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
    fn append(self: *Rows, values: []const V) !void {
        var at: usize = 0;
        while (at < values.len) {
            const end = @min(values.len, at + 128);
            const chunk = try Chunk.create(self.allocator);
            defer chunk.release();
            for (values[at..end]) |value| {
                const owned = try clone(chunk.arena.allocator(), value, 0);
                self.rows[self.filled] = .{ .value = owned, .chunk = chunk.retain() };
                self.values[self.filled] = owned;
                self.filled += 1;
            }
            at = end;
        }
    }
    fn share(self: *Rows, rows: []const Row) void {
        for (rows) |row| {
            self.rows[self.filled] = .{ .value = row.value, .chunk = row.chunk.retain() };
            self.values[self.filled] = row.value;
            self.filled += 1;
        }
    }
    fn from(a: Allocator, value: V, limit: usize) !*Rows {
        const values = try list(value);
        if (values.len > limit) return error.AgentLogSnapshotLimit;
        const self = try create(a, values.len);
        errdefer self.release();
        try self.append(values);
        return self;
    }
    fn patch(self: *Rows, change: V, limit: usize) !*Rows {
        if (try index(field(change, "length")) != self.rows.len) return error.InvalidLiveDelta;
        const ops = try list(field(change, "ops"));
        if (ops.len == 0) return self.retain();
        var count = self.rows.len;
        var cursor: usize = 0;
        for (ops) |op| {
            const parts = try list(op);
            if (parts.len != 3) return error.InvalidLiveDelta;
            const start = try index(parts[0]);
            const end = try index(parts[1]);
            if (start < cursor or end < start or end > self.rows.len) return error.InvalidLiveDelta;
            const added = try list(parts[2]);
            count = std.math.add(usize, count - (end - start), added.len) catch return error.AgentLogSnapshotLimit;
            if (count > limit) return error.AgentLogSnapshotLimit;
            cursor = end;
        }
        const out = try create(self.allocator, count);
        errdefer out.release();
        cursor = 0;
        for (ops) |op| {
            const parts = op.array.items;
            const start = try index(parts[0]);
            const end = try index(parts[1]);
            out.share(self.rows[cursor..start]);
            try out.append(try list(parts[2]));
            cursor = end;
        }
        out.share(self.rows[cursor..]);
        std.debug.assert(out.filled == count);
        return out;
    }
};

pub const Session = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    refs: std.atomic.Value(usize) = .init(1),
    rows: [3]?*Rows = @splat(null),
    children: std.ArrayList(*Session) = .empty,
    doc: V,
    row_count: usize = 0,
    pub fn retain(self: *Session) *Session {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Session) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.rows) |rows| if (rows) |r| r.release();
        for (self.children.items) |child| child.release();
        const a = self.allocator;
        self.arena.deinit();
        a.destroy(self);
    }
    fn create(a: Allocator, meta: V) !*Session {
        if (meta != .object or field(meta, "agent") != .string) return error.InvalidLiveDelta;
        const self = try a.create(Session);
        self.* = .{ .allocator = a, .arena = .init(a), .doc = .null };
        errdefer self.release();
        const aa = self.arena.allocator();
        self.doc = .{ .object = .empty };
        var it = meta.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "turns") or std.mem.eql(u8, key, "spans") or std.mem.eql(u8, key, "tokens") or std.mem.eql(u8, key, "children") or std.mem.eql(u8, key, "source_fingerprint")) continue;
            try self.doc.object.put(aa, try aa.dupe(u8, key), try clone(aa, entry.value_ptr.*, 0));
        }
        return self;
    }
    fn finish(self: *Session) !void {
        const aa = self.arena.allocator();
        for (names, self.rows) |name, rows| {
            const values = rows.?.values;
            try self.doc.object.put(aa, name, .{ .array = .{ .allocator = aa, .items = values, .capacity = values.len } });
            self.row_count += values.len;
        }
        var children = std.json.Array.init(aa);
        try children.ensureTotalCapacity(self.children.items.len);
        for (self.children.items) |child| {
            children.appendAssumeCapacity(child.doc);
            self.row_count += child.row_count;
        }
        if (self.row_count > 320000) return error.AgentLogSnapshotLimit;
        try self.doc.object.put(aa, "children", .{ .array = children });
    }
    fn from(a: Allocator, doc: V, depth: usize) anyerror!*Session {
        if (depth > 8) return error.AgentNestingLimit;
        const self = try create(a, doc);
        errdefer self.release();
        for (names, limits, 0..) |name, limit, i| self.rows[i] = try Rows.from(a, field(doc, name), limit);
        const children = try list(field(doc, "children"));
        if (children.len > 256) return error.AgentNestingLimit;
        try self.children.ensureTotalCapacity(self.arena.allocator(), children.len);
        for (children) |child| self.children.appendAssumeCapacity(try from(a, child, depth + 1));
        try self.finish();
        return self;
    }
    fn patch(self: *Session, change: V, depth: usize) anyerror!*Session {
        if (depth > 8) return error.AgentNestingLimit;
        const out = try create(self.allocator, field(change, "meta"));
        errdefer out.release();
        for (names, limits, self.rows, 0..) |name, limit, rows, i| {
            const delta = field(change, name);
            out.rows[i] = if (delta == .null) rows.?.retain() else try rows.?.patch(delta, limit);
        }
        const changes = field(change, "children");
        const items = field(changes, "items");
        if (items != .null) {
            if (try index(field(changes, "length")) != self.children.items.len) return error.InvalidLiveDelta;
            const entries = try list(items);
            if (entries.len > 256) return error.AgentNestingLimit;
            try out.children.ensureTotalCapacity(out.arena.allocator(), entries.len);
            var seen = std.StaticBitSet(256).initEmpty();
            for (entries) |entry| {
                const old = field(entry, "old");
                if (old != .null) {
                    const i = try index(old);
                    if (i >= self.children.items.len or seen.isSet(i)) return error.InvalidLiveDelta;
                    seen.set(i);
                    out.children.appendAssumeCapacity(self.children.items[i].retain());
                } else out.children.appendAssumeCapacity(try from(self.allocator, field(entry, "reset"), depth + 1));
            }
        } else {
            try out.children.ensureTotalCapacity(out.arena.allocator(), self.children.items.len);
            for (self.children.items) |child| out.children.appendAssumeCapacity(child.retain());
            if (changes != .null) {
                if (try index(field(changes, "length")) != self.children.items.len) return error.InvalidLiveDelta;
                var previous: ?usize = null;
                for (try list(field(changes, "patches"))) |entry| {
                    const parts = try list(entry);
                    if (parts.len != 2) return error.InvalidLiveDelta;
                    const i = try index(parts[0]);
                    if (i >= self.children.items.len or (previous != null and i <= previous.?)) return error.InvalidLiveDelta;
                    const child = try self.children.items[i].patch(parts[1], depth + 1);
                    out.children.items[i].release();
                    out.children.items[i] = child;
                    previous = i;
                }
            }
        }
        try out.finish();
        return out;
    }
};

pub const State = struct {
    allocator: Allocator,
    root: ?*Session = null,
    generation: usize = 0,
    pub fn deinit(self: *State) void {
        if (self.root) |root| root.release();
        self.root = null;
        self.generation = 0;
    }
    /// Caller owns a reference. All validation/allocation precedes publication.
    pub fn apply(self: *State, frame: V) !*Session {
        if (try index(field(frame, "wire")) != 1) return error.InvalidLiveDelta;
        const generation = try index(field(frame, "generation"));
        if (generation == 0 or generation <= self.generation) return error.InvalidLiveDelta;
        if (try index(field(frame, "size")) > 64 * 1024 * 1024) return error.AgentLogSnapshotLimit;
        const next = if (field(frame, "reset") != .null)
            try Session.from(self.allocator, field(frame, "reset"), 0)
        else blk: {
            const root = self.root orelse return error.AgentLogDeltaBaseMismatch;
            if (try index(field(frame, "base")) != self.generation or generation != self.generation + 1) return error.AgentLogDeltaBaseMismatch;
            break :blk try root.patch(field(frame, "patch"), 0);
        };
        if (self.root) |old| old.release();
        self.root = next;
        self.generation = generation;
        return next.retain();
    }
};

fn testFrame(state: *State, bytes: []const u8) !*Session {
    const parsed = try std.json.parseFromSlice(V, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    return state.apply(parsed.value);
}

test "new child layouts share old siblings in order and reject duplicate references" {
    var state = State{ .allocator = std.testing.allocator };
    defer state.deinit();
    const old = try testFrame(&state,
        \\{"wire":1,"generation":1,"size":400,"reset":{"agent":"parent","children":[{"agent":"child","title":"a","spans":[{"detail":"kept"}]},{"agent":"child","title":"c"}]}}
    );
    defer old.release();
    const next = try testFrame(&state,
        \\{"wire":1,"generation":2,"base":1,"size":500,"patch":{"meta":{"agent":"parent"},"children":{"length":2,"items":[{"old":0},{"reset":{"agent":"child","title":"b"}},{"old":1}]}}}
    );
    defer next.release();
    try std.testing.expect(old.children.items[0] == next.children.items[0]);
    try std.testing.expect(old.children.items[1] == next.children.items[2]);
    try std.testing.expectEqualStrings("b", field(next.children.items[1].doc, "title").string);
    try std.testing.expectEqual(@as(usize, 2), old.children.items.len);
    try std.testing.expectError(error.InvalidLiveDelta, testFrame(&state,
        \\{"wire":1,"generation":3,"base":2,"size":500,"patch":{"meta":{"agent":"parent"},"children":{"length":3,"items":[{"old":0},{"old":0}]}}}
    ));
    try std.testing.expect(state.root.? == next);
    state.deinit();
    try std.testing.expectEqualStrings("kept", field(next.children.items[0].rows[1].?.values[0], "detail").string);
}

test "live deltas share unchanged records and children while old snapshots stay immutable" {
    var state = State{ .allocator = std.testing.allocator };
    defer state.deinit();
    const old = try testFrame(&state,
        \\{"wire":1,"generation":1,"size":400,"reset":{"agent":"synthetic","title":"before","turns":[{"title":"turn"}],"spans":[{"detail":"read","start":1,"end":2}],"tokens":[],"children":[{"agent":"child","title":"unchanged"}]}}
    );
    const next = try testFrame(&state,
        \\{"wire":1,"generation":2,"base":1,"size":450,"patch":{"meta":{"agent":"synthetic","title":"after"},"spans":{"length":1,"ops":[[1,1,[{"detail":"write","start":2,"end":3}]]]}}}
    );
    defer next.release();
    try std.testing.expectEqualStrings("before", field(old.doc, "title").string);
    try std.testing.expectEqualStrings("after", field(next.doc, "title").string);
    try std.testing.expect(old.rows[0].? == next.rows[0].?);
    try std.testing.expect(old.rows[2].? == next.rows[2].?);
    try std.testing.expect(old.children.items[0] == next.children.items[0]);
    try std.testing.expect(old.rows[1].?.rows[0].chunk == next.rows[1].?.rows[0].chunk);
    try std.testing.expectEqual(@as(usize, 1), field(old.doc, "spans").array.items.len);
    try std.testing.expectEqual(@as(usize, 2), field(next.doc, "spans").array.items.len);
    old.release();
    state.deinit();
    try std.testing.expectEqualStrings("read", field(next.rows[1].?.values[0], "detail").string);
    try std.testing.expectEqualStrings("unchanged", field(next.children.items[0].doc, "title").string);
}

test "live delta generation and splice errors leave the previous document intact" {
    var state = State{ .allocator = std.testing.allocator };
    defer state.deinit();
    const old = try testFrame(&state,
        \\{"wire":1,"generation":1,"size":100,"reset":{"agent":"test","spans":[{"detail":"kept"}]}}
    );
    defer old.release();
    try std.testing.expectError(error.AgentLogDeltaBaseMismatch, testFrame(&state,
        \\{"wire":1,"generation":2,"base":0,"size":100,"patch":{"meta":{"agent":"test"}}}
    ));
    try std.testing.expectError(error.InvalidLiveDelta, testFrame(&state,
        \\{"wire":1,"generation":2,"base":1,"size":100,"patch":{"meta":{"agent":"test"},"spans":{"length":1,"ops":[[0,2,[]]]}}}
    ));
    try std.testing.expectEqual(@as(usize, 1), state.generation);
    try std.testing.expect(state.root.? == old);
    const reset = try testFrame(&state,
        \\{"wire":1,"generation":2,"size":100,"reset":{"agent":"replacement"}}
    );
    defer reset.release();
    try std.testing.expectEqualStrings("kept", field(old.rows[1].?.values[0], "detail").string);
    try std.testing.expectEqual(@as(usize, 0), reset.row_count);
}

test "live child patches and repeated row replacement release superseded chunks" {
    var state = State{ .allocator = std.testing.allocator };
    defer state.deinit();
    (try testFrame(&state,
        \\{"wire":1,"generation":1,"size":200,"reset":{"agent":"root","spans":[{"detail":"first"}],"children":[{"agent":"child","title":"old"}]}}
    )).release();
    var buffer: [512]u8 = undefined;
    for (2..42) |generation| {
        const frame = try std.fmt.bufPrint(&buffer, "{{\"wire\":1,\"generation\":{d},\"base\":{d},\"size\":200,\"patch\":{{\"meta\":{{\"agent\":\"root\"}},\"spans\":{{\"length\":1,\"ops\":[[0,1,[{{\"detail\":\"new\"}}]]]}},\"children\":{{\"length\":1,\"patches\":[[0,{{\"meta\":{{\"agent\":\"child\",\"title\":\"new\"}}}}]]}}}}}}", .{ generation, generation - 1 });
        const next = try testFrame(&state, frame);
        try std.testing.expectEqual(@as(usize, 1), next.rows[1].?.rows[0].chunk.refs.load(.monotonic));
        try std.testing.expectEqualStrings("new", field(next.children.items[0].doc, "title").string);
        next.release();
    }
}
