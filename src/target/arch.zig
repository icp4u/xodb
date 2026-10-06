//! Target ISA descriptions. Native ptrace currently supports the host ISA only.
//! ELF/debug-info consumers use the image's machine, independently of the host.
const std = @import("std");
const c = @import("runtime.zig").c;
pub const Arch = enum(u16) {
    m68k = c.XRT_M68K,
    x86_64 = c.XRT_X86_64,
    aarch64 = c.XRT_AARCH64,
    pub fn descriptor(self: Arch) *const c.struct_xrt_arch {
        return c.xrt_arch_get(@intFromEnum(self));
    }
    pub fn registerNumber(self: Arch, name: []const u8) ?usize {
        const reg = c.xrt_arch_register(@intFromEnum(self), name.ptr, name.len);
        if (reg == null or reg.*.dwarf >= self.count()) return null;
        return reg.*.dwarf;
    }
    pub fn addressBytes(self: Arch) usize {
        return self.descriptor().address_bits / 8;
    }
    pub fn endian(self: Arch) std.builtin.Endian {
        return if (self.descriptor().little_endian != 0) .little else .big;
    }
    pub fn pc(self: Arch) usize {
        const reg = c.xrt_arch_role(self.descriptor(), c.XRT_ROLE_PC) orelse return 0;
        return reg.*.dwarf;
    }
    pub fn sp(self: Arch) usize {
        const reg = c.xrt_arch_role(self.descriptor(), c.XRT_ROLE_SP) orelse return 0;
        return reg.*.dwarf;
    }
    /// Dense DWARF index used by unwind. x86 16 and m68k 24 are historical
    /// numbers; m68k 24 is the PC, not a link-register role.
    pub fn ra(self: Arch) usize {
        return switch (self) {
            .x86_64 => 16,
            .m68k => 24,
            .aarch64 => 30,
        };
    }
    pub fn count(self: Arch) usize {
        return self.descriptor().dwarf_count;
    }
    pub fn trap(self: Arch) []const u8 {
        const desc = self.descriptor();
        return desc.trap[0..desc.trap_size];
    }
    pub fn validBreakpoint(self: Arch, address: u64, size: usize) bool {
        return c.xrt_arch_breakpoint_valid(@intFromEnum(self), address, size) != 0;
    }
    pub fn breakpointPc(self: Arch, raw: u64) ?u64 {
        var result: u64 = undefined;
        return if (c.xrt_arch_breakpoint_pc(@intFromEnum(self), raw, &result) != 0) result else null;
    }
    pub fn callerLookup(self: Arch, raw: u64) ?u64 {
        var result: u64 = undefined;
        return if (c.xrt_arch_caller_pc(@intFromEnum(self), raw, &result) != 0) result else null;
    }
};
pub const native: Arch = switch (@import("builtin").cpu.arch) {
    .x86_64 => .x86_64,
    .aarch64 => .aarch64,
    else => @compileError("native targets currently require x86-64 or AArch64 Linux"),
};
test "breakpoint PC and caller lookup have separate ISA rules" {
    try std.testing.expectEqual(@as(?u64, 0x1000), Arch.aarch64.breakpointPc(0x1000));
    try std.testing.expectEqual(@as(?u64, 0xffc), Arch.aarch64.callerLookup(0x1000));
    try std.testing.expectEqual(@as(?u64, 0xfff), Arch.x86_64.breakpointPc(0x1000));
    try std.testing.expectEqual(@as(?u64, null), Arch.x86_64.breakpointPc(0));
    try std.testing.expectEqual(@as(?u64, null), Arch.aarch64.callerLookup(3));
}
