//! Inferior-call journal and active-frame state kept by the session. No
//! target access here; model/execution.zig owns the calls.
const std = @import("std");
const Actor = @import("command.zig").Actor;
pub const journal_capacity = 64;

pub const Outcome = enum { refused, returned, timeout, signal, breakpoint, exception, trap, event, exited, stop_unconfirmed, restore_failed, restored, abandoned };
/// One journal row. Argument texts and result values are not journaled;
/// they go only to the caller.
pub const Entry = struct {
    sequence: u64,
    actor: Actor,
    client_id: ?u64,
    scope: []const u8,
    tid: i32,
    frame: usize,
    action: []const u8,
    callee: []const u8,
    address: ?u64,
    resolution: []const u8,
    argument_count: usize,
    outcome: Outcome,
    reason: ?[]const u8,
    restored: bool,
    verified: bool,
    call_frame_active: bool,
    duration_ns: u64,
    generation_before: u64,
    generation_after: u64,
    time_ns: u64,
};
pub const Active = struct { tid: i32, callee: []const u8, outcome: Outcome, sequence: u64 };

pub const State = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    journal: [journal_capacity]Entry = undefined,
    count: usize = 0,
    sequence: u64 = 0,
    active: ?Active = null,
    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.* = .{};
    }
    pub fn entries(self: *const State) []const Entry {
        return self.journal[0..self.count];
    }
    fn keep(self: *State, text: []const u8) []const u8 {
        // Bounded: names are cut to 256 bytes; the arena is reset when it
        // grows past 1 MiB, after which old rows keep a placeholder.
        if (self.arena.queryCapacity() > 1 << 20) {
            for (self.journal[0..self.count]) |*row| row.callee = "[expired]";
            if (self.active) |*now| now.callee = "[expired]";
            _ = self.arena.reset(.retain_capacity);
        }
        return self.arena.allocator().dupe(u8, text[0..@min(text.len, 256)]) catch "[unavailable]";
    }
    pub fn append(self: *State, row: Entry) void {
        self.sequence += 1;
        var entry = row;
        entry.sequence = self.sequence;
        entry.callee = self.keep(row.callee);
        if (self.count == self.journal.len) {
            std.mem.copyForwards(Entry, self.journal[0 .. self.journal.len - 1], self.journal[1..]);
            self.count -= 1;
        }
        self.journal[self.count] = entry;
        self.count += 1;
    }
};
