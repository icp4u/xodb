//! Bounded memory observations and incremental search on the session owner.
const std = @import("std");
const A = std.heap.page_allocator;
pub const max_snapshot = 64 * 1024;
pub const max_search = 64 * 1024 * 1024;
pub const Snapshot = struct {
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
        if (session.target.state != .stopped) return error.NotStopped;
        if (length == 0 or length > max_snapshot or address == 0 or address > @as(u64, std.math.maxInt(u64)) - length) return error.InvalidMemoryRange;
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
        if (self.snapshots[self.slot]) |old| {
            if (self.pinned == old.id) self.slot = (self.slot + 1) % self.snapshots.len;
        }
        if (self.snapshots[self.slot]) |old| old.deinit();
        self.snapshots[self.slot] = .{ .id = id, .session_id = session.id, .image_epoch = session.target.image_epoch, .generation = session.target.generation, .address = address, .bytes = bytes, .valid = valid, .readable = readable };
        self.slot = (self.slot + 1) % self.snapshots.len;
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
        if (session.target.state != .stopped) return error.NotStopped;
        if (length == 0 or length > max_search or address == 0 or address > @as(u64, std.math.maxInt(u64)) - length) return error.InvalidMemoryRange;
        if (pattern.len == 0 or pattern.len > 256) return error.InvalidMemoryPattern;
        if (self.search) |search| if (search.state == .running) return error.MemorySearchBusy;
        var search = Search{ .id = self.next_id, .generation = session.target.generation, .image_epoch = session.target.image_epoch, .address = address, .length = length, .pattern_len = pattern.len };
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
    pub fn poll(self: *Memory, session: anytype) void {
        const search = if (self.search) |*v| v else return;
        if (search.state != .running) return;
        if (session.target.state != .stopped or session.target.generation != search.generation or session.target.image_epoch != search.image_epoch) {
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
