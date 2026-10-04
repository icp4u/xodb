//! Capture-owned copies of perf user registers and stack bytes.
//! Allocation occurs before collection. Retention exhaustion never mutates a
//! kernel callchain or stops the ordinary CPU collector.
const std = @import("std");
const records = @import("records.zig");
pub const max_budget_bytes: u32 = 64 * 1024 * 1024;
pub const default_budget_bytes: u32 = 32 * 1024 * 1024;
pub const Status = enum { captured, budget };
pub const Entry = struct { state: records.UserState, status: Status = .captured };
pub const Store = struct {
    entries: []Entry = &.{},
    bytes: []u8 = &.{},
    count: usize = 0,
    used: usize = 0,
    exhausted: bool = false,
    skipped: usize = 0,
    first_skipped: ?usize = null,
    pub fn init(a: std.mem.Allocator, capacity: usize, byte_budget: u32) !Store {
        if (byte_budget > max_budget_bytes) return error.InvalidStackBudget;
        const entries = try a.alloc(Entry, capacity);
        errdefer a.free(entries);
        return .{ .entries = entries, .bytes = try a.alloc(u8, byte_budget) };
    }
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        a.free(self.entries);
        a.free(self.bytes);
        self.* = .{};
    }
    pub fn append(self: *Store, source: records.UserState, bytes: []const u8) !u32 {
        if (self.count == self.entries.len) return error.SampleStateLimit;
        if (source.stack_len != source.stack_dyn or source.stack_dyn > source.stack_size or source.stack_size > records.max_user_stack or
            source.stack_off > bytes.len or source.stack_len > bytes.len - source.stack_off) return error.InvalidSampleState;
        var entry = Entry{ .state = source };
        entry.state.stack_off = 0;
        if (source.stack_len != 0) {
            if (self.exhausted or source.stack_len > self.bytes.len - self.used) {
                self.exhausted = true;
                self.skipped += 1;
                if (self.first_skipped == null) self.first_skipped = self.count;
                entry.status = .budget;
                entry.state.stack_len = 0;
            } else {
                entry.state.stack_off = @intCast(self.used);
                @memcpy(self.bytes[self.used..][0..source.stack_len], bytes[source.stack_off..][0..source.stack_len]);
                self.used += source.stack_len;
            }
        }
        self.entries[self.count] = entry;
        self.count += 1;
        return @intCast(self.count);
    }
    pub fn stack(self: *const Store, entry: Entry) []const u8 {
        return self.bytes[entry.state.stack_off..][0..entry.state.stack_len];
    }
    pub fn allocationBytes(self: *const Store) usize {
        return self.entries.len * @sizeOf(Entry) + self.bytes.len;
    }
};
test "sample state survives drain reuse and explicitly retains only a prefix at its byte budget" {
    const a = std.testing.allocator;
    var store = try Store.init(a, 4, 24);
    defer store.deinit(a);
    var bytes: [16]u8 = @splat(7);
    var state = records.UserState{ .abi = 2, .regs_mask = 1 << 7, .regs_present = true, .stack_size = 16, .stack_dyn = 16, .stack_len = 16, .stack_present = true };
    state.regs[7] = 0x7000;
    try std.testing.expectEqual(@as(u32, 1), try store.append(state, &bytes));
    @memset(&bytes, 9);
    state.regs[7] = 0x8000;
    try std.testing.expectEqual(@as(u32, 2), try store.append(state, &bytes));
    try std.testing.expectEqual(@as(u8, 7), store.stack(store.entries[0])[0]);
    try std.testing.expectEqual(@as(u64, 0x7000), store.entries[0].state.regs[7]);
    try std.testing.expectEqual(Status.budget, store.entries[1].status);
    try std.testing.expectEqual(@as(u64, 16), store.entries[1].state.stack_dyn);
    try std.testing.expectEqual(@as(u32, 0), store.entries[1].state.stack_len);
    try std.testing.expectEqual(@as(u64, 0x8000), store.entries[1].state.regs[7]);
    state.stack_size = 8;
    state.stack_dyn = 8;
    state.stack_len = 8;
    _ = try store.append(state, &bytes);
    try std.testing.expectEqual(Status.budget, store.entries[2].status);
    try std.testing.expectEqual(@as(?usize, 1), store.first_skipped);
    try std.testing.expectEqual(@as(usize, 2), store.skipped);
    try std.testing.expectEqual(@as(usize, 16), store.used);
}

fn allocationFailure(a: std.mem.Allocator) !void {
    var store = try Store.init(a, 4, 4096);
    defer store.deinit(a);
}
test "sampled state allocation fails before publication and releases partial storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
