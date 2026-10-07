const std = @import("std");
const arch = @import("arch.zig");
pub const Breakpoint = struct {
    architecture: arch.Arch = arch.native,
    id: u64,
    address: u64,
    original: [4]u8,
    patched: bool = true,
    enabled: bool = true,
    hit_count: u64 = 0,
    pending: bool = false,
    internal: bool = false,
    temporary: bool = false,
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        // Preserve x86's published numeric original byte. ARM64 stores one LE word.
        const original: u32 = switch (self.architecture) {
            .x86_64 => self.original[0],
            .aarch64, .loongarch64 => std.mem.readInt(u32, &self.original, .little),
            .m68k => std.mem.readInt(u16, self.original[0..2], .big),
        };
        try writer.write(.{ .id = self.id, .address = self.address, .original = original, .patched = self.patched, .temporary = self.temporary, .enabled = self.enabled, .hit_count = self.hit_count, .pending = self.pending, .internal = self.internal });
    }
};
pub const WatchKind = enum { write, read_write, execute };
pub const Watchpoint = struct { id: u64, address: u64, length: u8, kind: WatchKind, previous: u64 = 0 };
pub const StopReason = enum { none, exec, interrupt, signal, breakpoint, watchpoint, single_step, clone, fork, vfork, vfork_done };
pub const ArmWatchHit = struct {
    pc: u64,
    address: u64,
    code: i32,
    before: [4]?u64 = @splat(null),
    other_threads_running: bool = false,
};
pub const Step = struct { tid: i32, rearm: ?u64, stop_after: bool, interrupted: bool = false, watch: ?ArmWatchHit = null, exec_entry_pc: ?u64 = null };
pub const DebugRegisters = struct { address: [4]usize, status: usize, control: usize };
