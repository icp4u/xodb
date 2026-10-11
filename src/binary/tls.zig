//! Static thread-local storage of the main executable, from its PT_TLS
//! header alone. No target memory is read and no loader state is trusted.
const std = @import("std");
const elf = @import("elf.zig");

pub const Block = struct {
    /// Distance from the thread pointer down to the start of the block.
    below: u64,
    size: u64,
};
/// x86-64 (TLS variant II): the main executable's block is the first one the
/// loader places, directly below the thread pointer. It ends at the thread
/// pointer rounded so that the block start is congruent to `vaddr` modulo
/// `alignment`, which is glibc's and musl's placement for module 1.
pub fn executableBlock(mem_size: u64, alignment: u64, vaddr: u64) !Block {
    const a = @max(alignment, 1);
    if (!std.math.isPowerOfTwo(a) or a > 1 << 30 or mem_size == 0 or mem_size > 1 << 40) return error.TlsSegmentUnsupported;
    const first = (a - (vaddr & (a - 1))) & (a - 1);
    // A block smaller than the gap up to the next aligned address still
    // starts at an address congruent to `vaddr`: it ends `first` bytes later.
    if (mem_size < first) return .{ .below = first, .size = mem_size };
    const rounded = std.mem.alignForward(u64, mem_size - first, a) + first;
    return .{ .below = rounded, .size = mem_size };
}
/// Address of a TLS object of the main executable in the thread whose thread
/// pointer (fs_base on x86-64) is given. `offset` is the symbol's st_value,
/// which is relative to the start of the TLS segment.
pub fn executableAddress(block: Block, thread_pointer: u64, offset: u64, size: u64) !u64 {
    if (offset > block.size or size > block.size - offset) return error.TlsSymbolOutsideSegment;
    if (thread_pointer < block.below) return error.TlsThreadPointerInvalid;
    return thread_pointer - block.below + offset;
}
/// The PT_TLS block of an executable image, if it has exactly one.
pub fn imageBlock(image: *const elf.Image) !Block {
    var found: ?Block = null;
    for (0..image.header.segment_count) |i| {
        const segment = try image.segment(@intCast(i));
        if (segment.type != .tls) continue;
        if (found != null) return error.TlsSegmentUnsupported;
        found = try executableBlock(segment.mem_size, segment.alignment, segment.vaddr);
    }
    return found orelse error.TlsSegmentUnavailable;
}

test "the main executable's TLS block sits below the thread pointer" {
    // Two real layouts: memsz 0xa48 and 0xa28, align 16, aligned vaddr.
    const dev = try executableBlock(0xa48, 0x10, 0x4f2ab30 & ~@as(u64, 15));
    try std.testing.expectEqual(@as(u64, 0xa50), dev.below);
    try std.testing.expectEqual(@as(u64, 0x7f0000001000 - 0x970), try executableAddress(dev, 0x7f0000001000, 0xe0, 8));
    const template = try executableBlock(0xa28, 0x10, 0x542ab30);
    try std.testing.expectEqual(@as(u64, 0xa30), template.below);
    try std.testing.expectEqual(@as(u64, 0x7f0000001000 - 0x948), try executableAddress(template, 0x7f0000001000, 0xe8, 8));
    // A segment whose address is not aligned keeps its misalignment.
    const skewed = try executableBlock(0x25, 0x40, 0x1038);
    try std.testing.expectEqual(@as(u64, 0x48), skewed.below);
    try std.testing.expectEqual(@as(u64, 0x38), (0x7f0000001000 - skewed.below) & 0x3f);
    // The same when the block is smaller than its misalignment: below =
    // memsz + ((-vaddr - memsz) mod align), as the linker and the loader have it.
    const small = try executableBlock(4, 0x40, 0x1038);
    try std.testing.expectEqual(@as(u64, 8), small.below);
    try std.testing.expectEqual(@as(u64, 0x38), (0x7f0000001000 - small.below) & 0x3f);
    try std.testing.expectEqual(@as(u64, 0x7f0000001000 - 8), try executableAddress(small, 0x7f0000001000, 0, 4));
    // No alignment requirement.
    try std.testing.expectEqual(@as(u64, 0x25), (try executableBlock(0x25, 0, 0x1001)).below);
    try std.testing.expectEqual(@as(u64, 0x25), (try executableBlock(0x25, 1, 0x1001)).below);
}
test "TLS objects outside the segment and impossible thread pointers are refused" {
    const block = try executableBlock(0x100, 0x10, 0);
    try std.testing.expectError(error.TlsSymbolOutsideSegment, executableAddress(block, 0x7000, 0xfc, 8));
    try std.testing.expectError(error.TlsSymbolOutsideSegment, executableAddress(block, 0x7000, 0x101, 0));
    try std.testing.expectError(error.TlsSymbolOutsideSegment, executableAddress(block, 0x7000, std.math.maxInt(u64), 8));
    try std.testing.expectEqual(@as(u64, 0x7000 - 0x100 + 0xf8), try executableAddress(block, 0x7000, 0xf8, 8));
    try std.testing.expectError(error.TlsThreadPointerInvalid, executableAddress(block, 0xff, 0, 8));
    try std.testing.expectError(error.TlsSegmentUnsupported, executableBlock(0x100, 24, 0));
    try std.testing.expectError(error.TlsSegmentUnsupported, executableBlock(0, 16, 0));
    try std.testing.expectError(error.TlsSegmentUnsupported, executableBlock(std.math.maxInt(u64), 16, 0));
}
