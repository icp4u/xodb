//! Target ISA descriptions. Native ptrace currently supports the host ISA only.
//! ELF/debug-info consumers use the image's machine, independently of the host.
const std = @import("std");
pub const Arch = enum(u16) {
    m68k = 4,
    x86_64 = 62,
    aarch64 = 183,
    pub fn registerNames(self: Arch) []const []const u8 {
        if (self == .m68k) return &.{ "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "usp", "fp0", "fp1", "fp2", "fp3", "fp4", "fp5", "fp6", "fp7", "pc" };
        return if (self == .aarch64) &.{ "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "sp", "pc" } else &.{ "rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip" };
    }
    pub fn pc(self: Arch) usize {
        return if (self == .m68k) 24 else if (self == .aarch64) 32 else 16;
    }
    pub fn sp(self: Arch) usize {
        return if (self == .m68k) 15 else if (self == .aarch64) 31 else 7;
    }
    pub fn ra(self: Arch) usize {
        return if (self == .m68k) 24 else if (self == .aarch64) 30 else 16;
    }
    pub fn count(self: Arch) usize {
        return if (self == .m68k) 25 else if (self == .aarch64) 33 else 17;
    }
    pub fn trap(self: Arch) []const u8 {
        return if (self == .m68k) &.{ 0x4e, 0x4f } else if (self == .aarch64) &.{ 0, 0, 0x20, 0xd4 } else &.{0xcc};
    }
    pub fn breakpointPc(self: Arch, raw: u64) ?u64 {
        return if (self == .m68k) (if (raw >= 2) raw - 2 else null) else if (self == .aarch64) raw else if (raw > 0) raw - 1 else null;
    }
    pub fn callerLookup(self: Arch, raw: u64) ?u64 {
        const size: u64 = if (self == .m68k) 2 else if (self == .aarch64) 4 else 1;
        return if (raw >= size) raw - size else null;
    }
};
pub const native: Arch = switch (@import("builtin").cpu.arch) {
    .m68k => .m68k,
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
