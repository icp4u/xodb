//! Allocation-entry caller evidence. Addresses are copied out of the perf ring.
//! Frame-pointer prefixes never claim a complete unwind or a proven leak.
const std = @import("std");
pub const max_frames = 32;
pub const max_stacks = 16384;
pub const Status = enum { disabled, missing, prefix, depth_limit, caller_missing };
pub const Stack = struct {
    pcs: [max_frames]u64 = @splat(0),
    count: u8 = 0,
    status: Status = .disabled,
    pub fn addresses(self: *const Stack) []const u64 {
        return self.pcs[0..self.count];
    }
};
pub const Store = struct {
    entries: std.ArrayList(Stack) = .empty,
    index: std.AutoHashMapUnmanaged(Stack, u32) = .empty,
    omitted: u64 = 0,
    pub fn deinit(self: *Store, a: std.mem.Allocator) void {
        self.entries.deinit(a);
        self.index.deinit(a);
    }
    pub fn intern(self: *Store, a: std.mem.Allocator, stack: Stack) !?u32 {
        if (stack.count > max_frames) return error.InvalidAllocationStack;
        for (stack.pcs[stack.count..]) |pc| if (pc != 0) return error.InvalidAllocationStack;
        if (stack.status == .disabled) return null;
        if (self.index.get(stack)) |id| return id;
        if (self.entries.items.len == max_stacks) {
            self.omitted +|= 1;
            return null;
        }
        try self.entries.ensureUnusedCapacity(a, 1);
        try self.index.ensureUnusedCapacity(a, 1);
        const id: u32 = @intCast(self.entries.items.len);
        self.entries.appendAssumeCapacity(stack);
        self.index.putAssumeCapacity(stack, id);
        return id;
    }
};

test "allocation stack interning owns evidence and preserves prefix status" {
    const a = std.testing.allocator;
    var store = Store{};
    defer store.deinit(a);
    var stack = Stack{ .count = 2, .status = .prefix };
    stack.pcs[0] = 0x1234;
    stack.pcs[1] = 0x5678;
    const id = (try store.intern(a, stack)).?;
    try std.testing.expectEqual(id, (try store.intern(a, stack)).?);
    stack.pcs[1] = 0x9999;
    try std.testing.expectEqual(@as(u64, 0x5678), store.entries.items[id].pcs[1]);
    try std.testing.expectEqual(@as(?u32, null), try store.intern(a, .{}));
    stack.pcs[31] = 1;
    try std.testing.expectError(error.InvalidAllocationStack, store.intern(a, stack));
}
