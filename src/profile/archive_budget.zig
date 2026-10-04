//! Counts all Zig allocations for one archive operation, including arena slack.
const std = @import("std");
pub const Budget = struct {
    backing: std.mem.Allocator,
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    denied: bool = false,
    pub fn allocator(self: *Budget) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn fits(self: *Budget, old: usize, new: usize) bool {
        if (new > self.limit - (self.used - old)) {
            self.denied = true;
            return false;
        }
        return true;
    }
    fn account(self: *Budget, old: usize, new: usize) void {
        self.used = self.used - old + new;
        self.peak = @max(self.peak, self.used);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.fits(0, n)) return null;
        const p = self.backing.rawAlloc(n, alignment, ra) orelse return null;
        self.account(0, n);
        return p;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.fits(memory.len, n) or !self.backing.rawResize(memory, alignment, n, ra)) return false;
        self.account(memory.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        if (!self.fits(memory.len, n)) return null;
        const p = self.backing.rawRemap(memory, alignment, n, ra) orelse return null;
        self.account(memory.len, n);
        return p;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
        self.used -= memory.len;
    }
};
