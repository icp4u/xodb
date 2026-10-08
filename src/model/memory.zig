//! Bounded memory observations and incremental search on the session owner.
const std = @import("std");
const A = std.heap.page_allocator;
const jobs = @import("../service/job_owner.zig");
pub const max_snapshot = 64 * 1024;
pub const max_search = 64 * 1024 * 1024;
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
    hits: [1024]u64 = undefined,
    count: usize = 0,
};
pub const Memory = struct {
    snapshots: [8]?Snapshot = @splat(null),
    next_id: u64 = 1,
    slot: usize = 0,
    pinned: ?u64 = null,
    search: ?Search = null,
    pub fn deinit(self: *Memory) void {
        for (self.snapshots) |snapshot| if (snapshot) |s| s.deinit();
        self.snapshots = @splat(null);
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
        // Find a replaceable slot before reading or allocating. An observer
        // can recycle its own captures but cannot evict a human/other client.
        var selected: ?usize = null;
        for (0..self.snapshots.len) |offset_| {
            const index = (self.slot + offset_) % self.snapshots.len;
            if (self.snapshots[index]) |old| {
                if (self.pinned == old.id) continue;
                old.owner.require(requester) catch continue;
            }
            selected = index;
            break;
        }
        const slot = selected orelse return error.JobNotOwned;
        const bytes = try A.alloc(u8, length);
        errdefer A.free(bytes);
        @memset(bytes, 0);
        const valid = try A.alloc(bool, length);
        errdefer A.free(valid);
        @memset(valid, false);
        var offset: usize = 0;
        var readable: usize = 0;
        while (offset < length) {
            const count = @min(length - offset, 4096 - @as(usize, @intCast((address + offset) % 4096)));
            const n = session.target.readMemory(address + offset, bytes[offset..][0..count]) catch 0;
            @memset(valid[offset..][0..n], true);
            readable += n;
            offset += count;
        }
        const id = self.next_id;
        self.next_id += 1;
        if (self.snapshots[slot]) |old| old.deinit();
        self.snapshots[slot] = .{ .owner = requester.owner, .id = id, .session_id = session.id, .image_epoch = session.target.snapshot().image_epoch, .generation = session.target.snapshot().generation, .address = address, .bytes = bytes, .valid = valid, .readable = readable };
        self.slot = (slot + 1) % self.snapshots.len;
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
        const search = if (self.search) |*v| v else return;
        if (search.state != .running) return;
        if (session.target.snapshot().state != .stopped or session.target.snapshot().generation != search.generation or session.target.snapshot().image_epoch != search.image_epoch) {
            search.state = .stale;
            return;
        }
        const end = @min(search.length, search.scanned + 64 * 1024);
        var bytes: [4096]u8 = undefined;
        while (search.scanned < end) {
            const address = search.address + search.scanned;
            const count = @min(end - search.scanned, 4096 - @as(usize, @intCast(address % 4096)));
            const n = session.target.readMemory(address, bytes[0..count]) catch 0;
            for (bytes[0..n], 0..) |byte, i| {
                while (search.matched > 0 and search.pattern[search.matched] != byte) search.matched = search.prefix[search.matched - 1];
                if (search.pattern[search.matched] == byte) search.matched += 1;
                if (search.matched == search.pattern_len) {
                    search.hits[search.count] = address + i + 1 - search.pattern_len;
                    search.count += 1;
                    search.matched = search.prefix[search.matched - 1];
                    if (search.count == search.hits.len) {
                        search.scanned += i + 1;
                        search.state = .match_limit;
                        return;
                    }
                }
            }
            if (n < count) {
                search.unreadable += count - n;
                search.matched = 0;
            }
            search.scanned += count;
        }
        if (search.scanned == search.length) search.state = .complete;
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
    var ids: [8]u64 = undefined;
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
