//! Bounded memory observations and incremental search on the session owner.
const std = @import("std");
const A = std.heap.page_allocator;
const jobs = @import("../service/job_owner.zig");
const now = @import("../target/linux.zig").now;
/// One observation may cover a large section (e.g. a module's data segment)
/// so an agent can grab it during one short stop and page it later.
pub const max_snapshot = 16 * 1024 * 1024;
/// Captured bytes retained across all observations. Each byte also keeps a
/// validity flag, so resident memory is at most twice this. Oldest
/// replaceable observations are evicted first.
pub const max_retained = 64 * 1024 * 1024;
pub const max_snapshots = 64;
/// Bulk search reads at roughly a gigabyte per second, so this bounds one
/// stopped search to about a second. Memory use does not grow with length.
pub const max_search = 1024 * 1024 * 1024;
pub const max_hits = 4096;
/// Largest single local or core read. Remote targets use the agent protocol's
/// read limit (XRT_RPC_DATA_MAX) instead.
pub const bulk_read = 1024 * 1024;
pub const remote_read = 64 * 1024;
/// Owner-loop time spent scanning per poll; the loop stays responsive while
/// the stopped target is searched.
pub const tick_budget_ns = 4 * std.time.ns_per_ms;
const page = 4096;
pub const Snapshot = struct {
    owner: jobs.Owner = .{},
    id: u64,
    session_id: u64,
    image_epoch: u64,
    generation: u64,
    address: u64,
    bytes: []u8,
    valid: []bool,
    readable: usize,
    fn deinit(self: Snapshot) void {
        A.free(self.bytes);
        A.free(self.valid);
    }
};
pub const Search = struct {
    owner: jobs.Owner = .{},
    id: u64,
    generation: u64,
    image_epoch: u64,
    address: u64,
    length: usize,
    scanned: usize = 0,
    unreadable: usize = 0,
    state: enum { running, complete, cancelled, stale, match_limit } = .running,
    pattern: [256]u8 = undefined,
    pattern_len: usize,
    prefix: [256]usize = undefined,
    matched: usize = 0,
    hits: [max_hits]u64 = undefined,
    /// Bulk reads resume after the first readable page that follows a
    /// short or failed read.
    page_mode: bool = false,
    count: usize = 0,
};
/// Readable bytes at the front of a span, or unreadable bytes up to the next
/// page boundary. Bulk reads are tried first; after a short or failed read
/// the reader goes page by page until a whole page reads again, so holes and
/// remote partial failures are accounted exactly at page granularity.
const Span = struct { readable: usize = 0, unreadable: usize = 0 };
fn readSpan(target: anytype, address: u64, dest: []u8, page_mode: *bool) Span {
    if (!page_mode.*) {
        const n = @min(dest.len, target.readMemory(address, dest) catch 0);
        if (n == dest.len) return .{ .readable = n };
        page_mode.* = true;
        if (n > 0) return .{ .readable = n };
    }
    const count = @min(dest.len, page - @as(usize, @intCast(address % page)));
    const n = @min(count, target.readMemory(address, dest[0..count]) catch 0);
    if (n == count) page_mode.* = false;
    return if (n > 0) .{ .readable = n } else .{ .unreadable = count };
}
fn readLimit(target: anytype) usize {
    const T = @TypeOf(target.*);
    if (@hasDecl(T, "isRemote") and target.isRemote()) return remote_read;
    return bulk_read;
}
pub const Memory = struct {
    snapshots: [max_snapshots]?Snapshot = @splat(null),
    retained: usize = 0,
    next_id: u64 = 1,
    pinned: ?u64 = null,
    search: ?Search = null,
    buffer: []u8 = &.{},
    /// Upper bound on one read; tests lower it to exercise chunk boundaries.
    read_size: usize = bulk_read,
    pub fn deinit(self: *Memory) void {
        for (self.snapshots) |snapshot| if (snapshot) |s| s.deinit();
        self.snapshots = @splat(null);
        self.retained = 0;
        if (self.buffer.len > 0) A.free(self.buffer);
        self.buffer = &.{};
    }
    pub fn find(self: *const Memory, id: u64) !*const Snapshot {
        for (&self.snapshots) |*snapshot| if (snapshot.*) |*s| {
            if (s.id == id) return s;
        };
        return error.MemorySnapshotExpired;
    }
    pub fn capture(self: *Memory, session: anytype, address: u64, length: usize) !u64 {
        return self.captureOwned(session, address, length, .{});
    }
    pub fn captureOwned(self: *Memory, session: anytype, address: u64, length: usize, requester: jobs.Requester) !u64 {
        if (session.target.snapshot().state != .stopped) return error.NotStopped;
        if (length == 0 or length > max_snapshot or address == 0 or address > std.math.maxInt(u64) - length) return error.InvalidMemoryRange;
        // Choose victims, oldest first, before reading or allocating: a free
        // slot and room in the retained budget. An observer can recycle its
        // own captures but cannot evict a human/other client or the pin.
        var victims: [max_snapshots]bool = @splat(false);
        var retained = self.retained;
        var free = false;
        for (self.snapshots) |snapshot| free = free or snapshot == null;
        while (!free or retained + length > max_retained) {
            var oldest: ?usize = null;
            for (self.snapshots, 0..) |snapshot, index| if (snapshot) |old| {
                if (victims[index] or self.pinned == old.id) continue;
                old.owner.require(requester) catch continue;
                if (oldest == null or old.id < self.snapshots[oldest.?].?.id) oldest = index;
            };
            const index = oldest orelse return error.JobNotOwned;
            victims[index] = true;
            retained -= self.snapshots[index].?.bytes.len;
            free = true;
        }
        const bytes = try A.alloc(u8, length);
        errdefer A.free(bytes);
        @memset(bytes, 0);
        const valid = try A.alloc(bool, length);
        errdefer A.free(valid);
        @memset(valid, false);
        const limit = @min(self.read_size, readLimit(&session.target));
        var page_mode = false;
        var offset: usize = 0;
        var readable: usize = 0;
        while (offset < length) {
            const span = readSpan(&session.target, address + offset, bytes[offset..][0..@min(length - offset, limit)], &page_mode);
            @memset(valid[offset..][0..span.readable], true);
            readable += span.readable;
            offset += span.readable + span.unreadable;
        }
        var slot: ?usize = null;
        for (&self.snapshots, victims, 0..) |*snapshot, victim, index| {
            if (victim) {
                snapshot.*.?.deinit();
                snapshot.* = null;
            }
            if (snapshot.* == null and slot == null) slot = index;
        }
        const id = self.next_id;
        self.next_id += 1;
        self.snapshots[slot.?] = .{ .owner = requester.owner, .id = id, .session_id = session.id, .image_epoch = session.target.snapshot().image_epoch, .generation = session.target.snapshot().generation, .address = address, .bytes = bytes, .valid = valid, .readable = readable };
        self.retained = retained + length;
        return id;
    }
    pub const Comparison = enum { same, changed, became_readable, became_unreadable, unknown, outside_baseline };
    pub fn compare(current: *const Snapshot, baseline: *const Snapshot, offset: usize) Comparison {
        if (current.session_id != baseline.session_id or current.image_epoch != baseline.image_epoch) return .outside_baseline;
        const address = current.address + offset;
        if (address < baseline.address or address - baseline.address >= baseline.bytes.len) return .outside_baseline;
        const old: usize = @intCast(address - baseline.address);
        if (!current.valid[offset] and !baseline.valid[old]) return .unknown;
        if (!current.valid[offset]) return .became_unreadable;
        if (!baseline.valid[old]) return .became_readable;
        return if (current.bytes[offset] == baseline.bytes[old]) .same else .changed;
    }
    pub fn startSearch(self: *Memory, session: anytype, address: u64, length: usize, pattern: []const u8) !u64 {
        return self.startSearchOwned(session, address, length, pattern, .{});
    }
    pub fn startSearchOwned(self: *Memory, session: anytype, address: u64, length: usize, pattern: []const u8, requester: jobs.Requester) !u64 {
        if (session.target.snapshot().state != .stopped) return error.NotStopped;
        if (length == 0 or length > max_search or address == 0 or address > std.math.maxInt(u64) - length) return error.InvalidMemoryRange;
        if (pattern.len == 0 or pattern.len > 256) return error.InvalidMemoryPattern;
        if (self.search) |search| {
            try search.owner.require(requester);
            if (search.state == .running) return error.MemorySearchBusy;
        }
        var search = Search{ .owner = requester.owner, .id = self.next_id, .generation = session.target.snapshot().generation, .image_epoch = session.target.snapshot().image_epoch, .address = address, .length = length, .pattern_len = pattern.len };
        if (self.buffer.len == 0) self.buffer = try A.alloc(u8, bulk_read);
        @memcpy(search.pattern[0..pattern.len], pattern);
        search.prefix[0] = 0;
        var matched: usize = 0;
        for (pattern[1..], 1..) |byte, i| {
            while (matched > 0 and pattern[matched] != byte) matched = search.prefix[matched - 1];
            if (pattern[matched] == byte) matched += 1;
            search.prefix[i] = matched;
        }
        self.search = search;
        self.next_id += 1;
        return search.id;
    }
    pub fn cancelSearch(self: *Memory, id: u64, requester: jobs.Requester) !void {
        const search = if (self.search) |*v| v else return error.NoMemorySearch;
        if (search.id != id) return error.StaleMemorySearch;
        try search.owner.require(requester);
        if (search.state == .running) search.state = .cancelled;
    }
    pub fn poll(self: *Memory, session: anytype) void {
        self.pollBudget(session, tick_budget_ns);
    }
    /// Scans bulk reads until the time budget is spent; at least one read
    /// per call so progress never depends on clock resolution.
    pub fn pollBudget(self: *Memory, session: anytype, budget_ns: u64) void {
        const search = if (self.search) |*v| v else return;
        if (search.state != .running) return;
        if (session.target.snapshot().state != .stopped or session.target.snapshot().generation != search.generation or session.target.snapshot().image_epoch != search.image_epoch) {
            search.state = .stale;
            return;
        }
        const limit = @min(self.read_size, self.buffer.len, readLimit(&session.target));
        const started = now();
        while (search.scanned < search.length) {
            const address = search.address + search.scanned;
            const span = readSpan(&session.target, address, self.buffer[0..@min(search.length - search.scanned, limit)], &search.page_mode);
            if (span.unreadable > 0) {
                search.unreadable += span.unreadable;
                search.matched = 0;
                search.scanned += span.unreadable;
            } else if (!scan(search, address, self.buffer[0..span.readable])) return;
            if (now() -% started >= budget_ns) break;
        }
        if (search.scanned == search.length) search.state = .complete;
    }
    /// KMP over one readable run; the partial match carries into the next
    /// run. While nothing is matched, memchr-style skipping finds the first
    /// pattern byte. Returns false when the hit cap ends the search.
    fn scan(search: *Search, address: u64, bytes: []const u8) bool {
        const pattern = search.pattern[0..search.pattern_len];
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (search.matched == 0) i = std.mem.indexOfScalarPos(u8, bytes, i, pattern[0]) orelse break;
            const byte = bytes[i];
            while (search.matched > 0 and pattern[search.matched] != byte) search.matched = search.prefix[search.matched - 1];
            if (pattern[search.matched] == byte) search.matched += 1;
            if (search.matched == pattern.len) {
                search.hits[search.count] = address + i + 1 - pattern.len;
                search.count += 1;
                search.matched = search.prefix[search.matched - 1];
                if (search.count == search.hits.len) {
                    search.scanned += i + 1;
                    search.state = .match_limit;
                    return false;
                }
            }
        }
        search.scanned += bytes.len;
        return true;
    }
};

test "observer memory work cannot evict or cancel a human or another client" {
    const FakeTarget = struct {
        reads: usize = 0,
        pub fn snapshot(_: *@This()) struct { state: enum { stopped }, image_epoch: u64, generation: u64 } {
            return .{ .state = .stopped, .image_epoch = 1, .generation = 4 };
        }
        pub fn readMemory(self: *@This(), _: u64, bytes: []u8) !usize {
            self.reads += 1;
            @memset(bytes, 0);
            return bytes.len;
        }
    };
    var session = struct { id: u64 = 7, target: FakeTarget = .{} }{};
    var memory = Memory{};
    defer memory.deinit();
    var ids: [max_snapshots]u64 = undefined;
    for (&ids) |*id| id.* = try memory.capture(&session, 4096, 64);
    const stdio = jobs.Requester{ .owner = jobs.Owner.agent(null) };
    const peer = jobs.Requester{ .owner = jobs.Owner.agent(7) };
    const other = jobs.Requester{ .owner = jobs.Owner.agent(8) };
    const control = jobs.Requester{ .owner = peer.owner, .controller = true };
    const reads = session.target.reads;
    const next = memory.next_id;
    try std.testing.expectError(error.JobNotOwned, memory.captureOwned(&session, 4096, 64, stdio));
    try std.testing.expectError(error.JobNotOwned, memory.captureOwned(&session, 4096, 64, peer));
    try std.testing.expectEqual(reads, session.target.reads);
    try std.testing.expectEqual(next, memory.next_id);
    for (ids) |id| _ = try memory.find(id);
    const owned = try memory.captureOwned(&session, 4096, 64, control);
    const replacement = try memory.captureOwned(&session, 4096, 64, peer);
    try std.testing.expectError(error.MemorySnapshotExpired, memory.find(owned));
    _ = try memory.find(replacement);
    try std.testing.expectError(error.JobNotOwned, memory.captureOwned(&session, 4096, 64, other));
    for (ids[1..]) |id| _ = try memory.find(id);

    const human_search = try memory.startSearch(&session, 4096, 4096, "needle");
    try std.testing.expectError(error.JobNotOwned, memory.cancelSearch(human_search, stdio));
    try std.testing.expectEqual(.running, memory.search.?.state);
    try memory.cancelSearch(human_search, control);
    const own_search = try memory.startSearchOwned(&session, 4096, 4096, "needle", control);
    try std.testing.expectError(error.JobNotOwned, memory.cancelSearch(own_search, other));
    try std.testing.expectEqual(.running, memory.search.?.state);
    try memory.cancelSearch(own_search, peer);
    try std.testing.expectEqual(.cancelled, memory.search.?.state);
    try std.testing.expectError(error.JobNotOwned, memory.startSearchOwned(&session, 4096, 4096, "needle", other));
    _ = try memory.startSearch(&session, 4096, 4096, "needle");
}

/// Synthetic address space: '.' background with an 'A' every seventh byte,
/// planted strings, and unmapped pages. `whole` mimics a remote read that
/// fails outright when any byte is unreadable; otherwise reads stop short at
/// the first hole like process_vm_readv.
const Space = struct {
    holes: []const u64 = &.{},
    plants: []const Plant = &.{},
    whole: bool = false,
    fill: ?u8 = null,
    generation: u64 = 1,
    running: bool = false,
    reads: usize = 0,
    const Plant = struct { at: u64, text: []const u8 };
    pub fn snapshot(self: *@This()) struct { state: enum { stopped, running }, image_epoch: u64, generation: u64 } {
        return .{ .state = if (self.running) .running else .stopped, .image_epoch = 1, .generation = self.generation };
    }
    fn hole(self: *const @This(), at: u64) bool {
        for (self.holes) |h| if (at >= h and at - h < page) return true;
        return false;
    }
    fn byte(self: *const @This(), at: u64) u8 {
        for (self.plants) |p| if (at >= p.at and at - p.at < p.text.len) return p.text[@intCast(at - p.at)];
        return self.fill orelse if (at % 7 == 0) 'A' else '.';
    }
    pub fn readMemory(self: *@This(), address: u64, bytes: []u8) !usize {
        self.reads += 1;
        if (self.fill) |f| if (self.holes.len == 0 and self.plants.len == 0) {
            @memset(bytes, f);
            return bytes.len;
        };
        for (bytes, 0..) |*b, i| {
            if (self.hole(address + i)) return if (self.whole or i == 0) error.MemoryUnreadable else i;
            b.* = self.byte(address + i);
        }
        return bytes.len;
    }
};
fn runSearch(memory: *Memory, session: anytype, address: u64, length: usize, pattern: []const u8) !*Search {
    _ = try memory.startSearch(session, address, length, pattern);
    var polls: usize = 0;
    while (memory.search.?.state == .running) : (polls += 1) {
        try std.testing.expect(polls < 1 << 20);
        memory.pollBudget(session, 0);
    }
    return &memory.search.?;
}

test "bulk search matches across read chunks and page fallback, resets at holes" {
    const holes = [_]u64{ 0x13000, 0x20000, 0x21000, 0x30000 };
    const plants = [_]Space.Plant{
        .{ .at = 0x10000 + 13 + 4099 - 2, .text = "ABABAC" }, // straddles odd chunks
        .{ .at = 0x12000 - 3, .text = "ABABAC" }, // straddles a page
        .{ .at = 0x13000 - 6, .text = "ABABAC" }, // ends exactly at a hole
        .{ .at = 0x22000, .text = "ABABAC" }, // starts right after two holes
        .{ .at = 0x30000 - 3, .text = "ABA" }, // first half of a broken match,
        .{ .at = 0x31000, .text = "BAC" }, //     second half past the hole
        .{ .at = 0x31000 + 40 - 6, .text = "ABABAC" }, // ends the range
    };
    inline for (.{ false, true }) |whole| {
        for ([_]usize{ 1, 7, 4096, 4099, 65536, bulk_read }) |read_size| {
            var session = struct { id: u64 = 1, target: Space = .{} }{};
            session.target = .{ .holes = &holes, .plants = &plants, .whole = whole };
            var memory = Memory{ .read_size = read_size };
            defer memory.deinit();
            const start: u64 = 0x10000 + 13;
            const length: usize = 0x31000 - 13 - 0x10000 + 40;
            const search = try runSearch(&memory, &session, start, length, "ABABAC");
            // Reference: naive comparison over each readable run.
            var expected: [16]u64 = undefined;
            var count: usize = 0;
            var at = start;
            while (at + 6 <= start + length) : (at += 1) {
                var ok = true;
                for (0..6) |i| ok = ok and !session.target.hole(at + i) and session.target.byte(at + i) == "ABABAC"[i];
                if (ok) {
                    expected[count] = at;
                    count += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 5), count);
            try std.testing.expectEqual(.complete, search.state);
            try std.testing.expectEqualSlices(u64, expected[0..count], search.hits[0..search.count]);
            try std.testing.expectEqual(length, search.scanned);
            try std.testing.expectEqual(@as(usize, holes.len * page), search.unreadable);
        }
    }
    // Overlapping matches carry partial state across one-byte reads.
    var session = struct { id: u64 = 1, target: Space = .{ .plants = &.{.{ .at = 0x5000 - 2, .text = "ABABA" }} } }{};
    var memory = Memory{ .read_size = 1 };
    defer memory.deinit();
    const search = try runSearch(&memory, &session, 0x5000 - 3, 8, "ABA");
    try std.testing.expectEqualSlices(u64, &.{ 0x5000 - 2, 0x5000 }, search.hits[0..search.count]);
}

test "bulk search uses few reads, cancels and goes stale mid-search, caps hits" {
    var session = struct { id: u64 = 1, target: Space = .{ .fill = '.' } }{};
    var memory = Memory{};
    defer memory.deinit();
    const id = try memory.startSearch(&session, 0x100000, 64 * bulk_read, "needle");
    memory.pollBudget(&session, 0);
    try std.testing.expectEqual(@as(usize, 1), session.target.reads);
    try std.testing.expectEqual(@as(usize, bulk_read), memory.search.?.scanned);
    try memory.cancelSearch(id, .{});
    memory.pollBudget(&session, 0);
    try std.testing.expectEqual(.cancelled, memory.search.?.state);
    try std.testing.expectEqual(@as(usize, bulk_read), memory.search.?.scanned);

    _ = try memory.startSearch(&session, 0x100000, 64 * bulk_read, "needle");
    memory.pollBudget(&session, 0);
    session.target.generation += 1;
    memory.pollBudget(&session, 0);
    try std.testing.expectEqual(.stale, memory.search.?.state);
    try std.testing.expectEqual(@as(usize, bulk_read), memory.search.?.scanned);
    session.target.generation -= 1;
    session.target.running = true;
    _ = memory.startSearch(&session, 0x100000, 4096, "needle") catch |err| try std.testing.expectEqual(error.NotStopped, err);
    session.target.running = false;

    session.target.reads = 0;
    const done = try runSearch(&memory, &session, 0x100000, max_search, "needle");
    try std.testing.expectEqual(.complete, done.state);
    try std.testing.expectEqual(@as(usize, max_search / bulk_read), session.target.reads);

    session.target.fill = 'A';
    const capped = try runSearch(&memory, &session, 0x100000, 3 * max_hits, "AA");
    try std.testing.expectEqual(.match_limit, capped.state);
    try std.testing.expectEqual(@as(usize, max_hits), capped.count);
    try std.testing.expectEqual(@as(usize, max_hits + 1), capped.scanned);
    try std.testing.expectEqual(@as(u64, 0x100000 + max_hits - 1), capped.hits[max_hits - 1]);
}

test "large captures are exact across holes and the retained budget evicts oldest" {
    var session = struct { id: u64 = 1, target: Space = .{ .holes = &.{0x23000}, .whole = true } }{};
    var memory = Memory{ .read_size = 65536 };
    defer memory.deinit();
    const across = try memory.capture(&session, 0x20000 + 5, 0x8000);
    const snap = try memory.find(across);
    try std.testing.expectEqual(@as(usize, 0x8000 - page), snap.readable);
    for (snap.valid, 0..) |valid, i| try std.testing.expectEqual(!(0x20005 + i >= 0x23000 and 0x20005 + i < 0x24000), valid);
    try std.testing.expectEqual(@as(u8, 'A'), snap.bytes[0x2000a - 0x20005]);
    try std.testing.expectError(error.InvalidMemoryRange, memory.capture(&session, 0x1000, max_snapshot + 1));

    session.target = .{ .fill = 0x5a };
    memory.pinned = across;
    var ids: [max_retained / max_snapshot]u64 = undefined;
    for (&ids) |*id| id.* = try memory.capture(&session, 0x100000, max_snapshot);
    try std.testing.expect(memory.retained <= max_retained);
    // The pin survives; the oldest unpinned (ids[0]) made room for the last.
    _ = try memory.find(across);
    try std.testing.expectError(error.MemorySnapshotExpired, memory.find(ids[0]));
    for (ids[1..]) |id| try std.testing.expectEqual(@as(usize, max_snapshot), (try memory.find(id)).readable);
    // An observer cannot evict others' captures to make room.
    const observer = jobs.Requester{ .owner = jobs.Owner.agent(9) };
    try std.testing.expectError(error.JobNotOwned, memory.captureOwned(&session, 0x100000, max_snapshot, observer));
    _ = try memory.find(ids[1]);
}
