//! Borrowed native-frame evidence shared by the model and inspection providers.
const info = @import("info.zig");
const loc = @import("location.zig");
pub const Frame = struct {
    architecture: @import("../target/arch.zig").Arch = .x86_64,
    tid: i32 = 0,
    index: usize,
    pc: u64,
    lookup_pc: u64,
    registers: loc.RegisterSet,
    cfa: ?u64 = null,
    module_id: ?u64 = null,
    symbol: ?[]const u8 = null,
    source: ?info.Site = null,
    unwind_method: ?[]const u8 = null,
    inline_frames: []const info.Inline = &.{},
    inline_diagnostic: ?[]const u8 = null,
    diagnostic: ?[]const u8 = null,
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.write(.{ .index = self.index, .pc = self.pc, .lookup_pc = self.lookup_pc, .registers = self.registers[0..self.architecture.count()], .cfa = self.cfa, .module_id = self.module_id, .symbol = self.symbol, .source = self.source, .unwind_method = self.unwind_method, .inline_frames = self.inline_frames, .inline_diagnostic = self.inline_diagnostic, .diagnostic = self.diagnostic });
    }
};
