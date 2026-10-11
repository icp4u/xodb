//! Owned synthetic PE bytes shared by fast cache and profile tests.
const std = @import("std");
const bias: u64 = 0x180000000;
fn put(bytes: []u8, at: usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
pub fn binary(version: u8) [0x600]u8 {
    var b: [0x600]u8 = @splat(0);
    @memcpy(b[0..2], "MZ");
    put(&b, 60, u32, 64);
    @memcpy(b[64..68], "PE\x00\x00");
    put(&b, 68, u16, 0x8664);
    put(&b, 70, u16, 1);
    put(&b, 84, u16, 240);
    const opt = 88;
    put(&b, opt, u16, 0x20b);
    put(&b, opt + 24, u64, bias);
    put(&b, opt + 32, u32, 0x1000);
    put(&b, opt + 36, u32, 0x200);
    put(&b, opt + 56, u32, 0x2000);
    put(&b, opt + 60, u32, 0x200);
    put(&b, opt + 108, u32, 16);
    put(&b, opt + 136, u32, 0x1200);
    put(&b, opt + 140, u32, 24);
    @memcpy(b[328..333], ".text");
    put(&b, 336, u32, 0x400);
    put(&b, 340, u32, 0x1000);
    put(&b, 344, u32, 0x400);
    put(&b, 348, u32, 0x200);
    put(&b, 364, u32, 0x60000020);
    @memset(b[0x200..0x300], 0x90);
    put(&b, 0x400, u32, 0x1000);
    put(&b, 0x404, u32, 0x1010);
    put(&b, 0x408, u32, 0x1240);
    put(&b, 0x40c, u32, 0x1020);
    put(&b, 0x410, u32, 0x1030);
    put(&b, 0x414, u32, 0x1248);
    @memcpy(b[0x440..0x446], &[_]u8{ version, 4, 1, 0, 4, 0x32 }); // ALLOC_SMALL 32
    b[0x448] = 1;
    return b;
}
