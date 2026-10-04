//! History of observed mappings, not a complete VMA/syscall history.
//! A cursor replays changes once in timestamp order while samples are walked.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const max_opening = 16384;
pub const max_changes = 4096;
pub const coverage = "opening snapshot plus observed perf MMAP2 events; munmap/mremap and in-place code changes are not fully observed and can invalidate attribution";
pub const Reason = enum { elf, anonymous, image_unavailable, image_limit, non_executable, unsupported_record, truncated_path };
pub const Mapping = struct {
    id: u32 = 0,
    start: u64,
    end: u64,
    offset: u64 = 0,
    image_id: u64 = 0,
    device_major: u64 = 0,
    device_minor: u64 = 0,
    inode: u64 = 0,
    executable: bool = true,
    reason: Reason = .anonymous,
    path: []const u8 = "",

    fn same(a: Mapping, b: Mapping) bool {
        return a.start == b.start and a.end == b.end and a.offset == b.offset and
            a.image_id == b.image_id and a.device_major == b.device_major and
            a.device_minor == b.device_minor and a.inode == b.inode and
            a.executable == b.executable and a.reason == b.reason and std.mem.eql(u8, a.path, b.path);
    }
};
pub const Change = struct { time_ns: u64, id: u32 };
pub const History = struct {
    entries: std.ArrayList(Mapping) = .empty,
    changes: std.ArrayList(Change) = .empty,
    opening_count: usize = 0,

    pub fn deinit(self: *History, a: Allocator) void {
        self.entries.deinit(a);
        self.changes.deinit(a);
    }
    pub fn opening(self: *History, a: Allocator, mapping: Mapping) !void {
        if (self.changes.items.len != 0 or mapping.start >= mapping.end) return error.InvalidMapping;
        if (self.opening_count == max_opening) return error.MappingHistoryLimit;
        if (self.opening_count > 0 and self.entries.items[self.opening_count - 1].end > mapping.start) return error.InvalidMapping;
        var entry = mapping;
        entry.id = @intCast(self.entries.items.len + 1);
        try self.entries.append(a, entry);
        self.opening_count += 1;
    }
    /// The caller owns path strings for the history's whole lifetime.
    pub fn add(self: *History, a: Allocator, time_ns: u64, mapping: Mapping) !u32 {
        if (mapping.start >= mapping.end or time_ns == 0) return error.InvalidMapping;
        for (self.changes.items) |change| {
            if (change.time_ns == time_ns and Mapping.same(self.get(change.id).*, mapping)) return change.id;
        }
        if (self.changes.items.len == max_changes) return error.MappingHistoryLimit;
        try self.entries.ensureUnusedCapacity(a, 1);
        try self.changes.ensureUnusedCapacity(a, 1);
        var entry = mapping;
        entry.id = @intCast(self.entries.items.len + 1);
        self.entries.appendAssumeCapacity(entry);
        self.changes.appendAssumeCapacity(.{ .time_ns = time_ns, .id = entry.id });
        return entry.id;
    }
    pub fn get(self: *const History, id: u32) *const Mapping {
        return &self.entries.items[id - 1];
    }
};
pub const Found = struct { mapping: *const Mapping, ambiguous: bool };
const Range = struct { start: u64, end: u64, id: u32, changed_ns: u64 = 0, conflict: bool = false };
pub const Cursor = struct {
    allocator: Allocator,
    history: *const History,
    order: []Change,
    next: usize = 0,
    time_ns: u64 = 0,
    ranges: std.ArrayList(Range) = .empty,
    scratch: std.ArrayList(Range) = .empty,

    pub fn init(a: Allocator, history: *const History) !Cursor {
        var self = Cursor{ .allocator = a, .history = history, .order = try a.dupe(Change, history.changes.items) };
        errdefer self.deinit();
        std.mem.sort(Change, self.order, {}, struct {
            fn less(_: void, l: Change, r: Change) bool {
                return if (l.time_ns == r.time_ns) l.id < r.id else l.time_ns < r.time_ns;
            }
        }.less);
        try self.ranges.ensureTotalCapacity(a, history.opening_count + 2 * history.changes.items.len);
        for (history.entries.items[0..history.opening_count]) |entry| {
            self.ranges.appendAssumeCapacity(.{ .start = entry.start, .end = entry.end, .id = entry.id });
        }
        return self;
    }
    pub fn deinit(self: *Cursor) void {
        self.allocator.free(self.order);
        self.ranges.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
    }
    pub fn advance(self: *Cursor, time_ns: u64) !void {
        if (time_ns < self.time_ns) return error.MappingTimeReversed;
        while (self.next < self.order.len and self.order[self.next].time_ns <= time_ns) : (self.next += 1) {
            try self.apply(self.order[self.next]);
        }
        self.time_ns = time_ns;
    }
    fn firstEndingAfter(self: *const Cursor, address: u64) usize {
        var low: usize = 0;
        var high = self.ranges.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.ranges.items[mid].end <= address) low = mid + 1 else high = mid;
        }
        return low;
    }
    pub fn at(self: *const Cursor, address: u64) ?Found {
        const i = self.firstEndingAfter(address);
        if (i == self.ranges.items.len or self.ranges.items[i].start > address) return null;
        const range = self.ranges.items[i];
        return .{ .mapping = self.history.get(range.id), .ambiguous = range.conflict or (range.changed_ns != 0 and range.changed_ns == self.time_ns) };
    }
    fn push(self: *Cursor, range: Range) !void {
        if (range.start >= range.end) return;
        if (self.scratch.items.len > 0) {
            const last = &self.scratch.items[self.scratch.items.len - 1];
            if (last.end == range.start and last.id == range.id and last.changed_ns == range.changed_ns and last.conflict == range.conflict) {
                last.end = range.end;
                return;
            }
        }
        try self.scratch.append(self.allocator, range);
    }
    fn apply(self: *Cursor, change: Change) !void {
        const entry = self.history.get(change.id);
        const first = self.firstEndingAfter(entry.start);
        var last = first;
        var position = entry.start;
        self.scratch.clearRetainingCapacity();
        while (last < self.ranges.items.len and self.ranges.items[last].start < entry.end) : (last += 1) {
            const old = self.ranges.items[last];
            if (old.start < entry.start) {
                var left = old;
                left.end = entry.start;
                try self.push(left);
            }
            try self.push(.{ .start = position, .end = @min(old.start, entry.end), .id = entry.id, .changed_ns = change.time_ns });
            const finish = @min(old.end, entry.end);
            try self.push(.{ .start = @max(old.start, entry.start), .end = finish, .id = entry.id, .changed_ns = change.time_ns, .conflict = old.changed_ns == change.time_ns });
            position = finish;
            if (old.end > entry.end) {
                var right = old;
                right.start = entry.end;
                try self.push(right);
            }
        }
        try self.push(.{ .start = position, .end = entry.end, .id = entry.id, .changed_ns = change.time_ns });
        try self.ranges.replaceRange(self.allocator, first, last - first, self.scratch.items);
    }
};

test "mapping history handles out-of-order partial replacement, permissions and address reuse" {
    const a = std.testing.allocator;
    var history = History{};
    defer history.deinit(a);
    try history.opening(a, .{ .start = 100, .end = 300, .image_id = 1, .reason = .elf });
    const newer = try history.add(a, 30, .{ .start = 150, .end = 180, .image_id = 2, .reason = .elf });
    _ = try history.add(a, 20, .{ .start = 140, .end = 200, .executable = false, .reason = .non_executable });
    var cursor = try Cursor.init(a, &history);
    defer cursor.deinit();
    try cursor.advance(10);
    try std.testing.expectEqual(@as(u64, 1), cursor.at(160).?.mapping.image_id);
    try cursor.advance(21);
    try std.testing.expect(!cursor.at(160).?.mapping.executable);
    try std.testing.expectEqual(@as(u64, 1), cursor.at(210).?.mapping.image_id);
    try cursor.advance(30);
    try std.testing.expect(cursor.at(160).?.ambiguous);
    try cursor.advance(31);
    try std.testing.expectEqual(newer, cursor.at(160).?.mapping.id);
    try std.testing.expect(!cursor.at(160).?.ambiguous);
    try std.testing.expect(!cursor.at(190).?.mapping.executable);
    try std.testing.expect(cursor.at(300) == null);
    try std.testing.expectError(error.MappingTimeReversed, cursor.advance(29));
}

test "duplicate mapping records retain identity; equal-time overlap stays ambiguous only in intersection" {
    const a = std.testing.allocator;
    var history = History{};
    defer history.deinit(a);
    const entry = Mapping{ .start = 100, .end = 200, .image_id = 1, .reason = .elf };
    const id = try history.add(a, 10, entry);
    try std.testing.expectEqual(id, try history.add(a, 10, entry));
    _ = try history.add(a, 10, .{ .start = 150, .end = 250, .image_id = 2, .reason = .elf });
    _ = try history.add(a, 20, .{ .start = 160, .end = 180 });
    var cursor = try Cursor.init(a, &history);
    defer cursor.deinit();
    try cursor.advance(11);
    try std.testing.expect(!cursor.at(120).?.ambiguous);
    try std.testing.expect(cursor.at(160).?.ambiguous);
    try std.testing.expect(!cursor.at(220).?.ambiguous);
    try cursor.advance(21);
    try std.testing.expect(!cursor.at(170).?.ambiguous);
    try std.testing.expect(cursor.at(190).?.ambiguous);
    try std.testing.expectError(error.InvalidMapping, history.add(a, 50, .{ .start = 20, .end = 20 }));
}
