//! Apply validated ARM64 compact recipes to explicit stopped state. Precise
//! prologue/epilogue handling belongs to the caller; a recipe describes the
//! established frame. Missing saved nonvolatile registers remain unknown.
const std = @import("std");
const loc = @import("location.zig");
const info = @import("info.zig");

fn word(context: loc.Context, address: u64) !u64 {
    var bytes: [8]u8 = undefined;
    if (try context.read(context.user, address, &bytes) != bytes.len) return error.MemoryUnreadable;
    return std.mem.readInt(u64, &bytes, .little);
}
pub fn unwind(encoding: u32, context: loc.Context, mask: u64) !info.Unwind {
    var caller: loc.RegisterSet = @splat(null);
    for (19..30) |i| caller[i] = context.registers[i];
    const mode = encoding & 0x0f000000;
    if (mode == 0x03000000) return error.MachODwarfUnwindRequired;
    var cfa: u64 = undefined;
    if (mode == 0x02000000) {
        // Only the stack-size field is defined for the frameless encodings
        // emitted by this compiler. Do not reinterpret reserved register bits.
        if (encoding & 0x00000fff != 0) return error.MachOCompactEncodingUnsupported;
        const sp = context.registers[31] orelse return error.RegisterUnavailable;
        cfa = std.math.add(u64, sp, @as(u64, (encoding & 0x00fff000) >> 12) * 16) catch return error.InvalidAddress;
        caller[32] = (context.registers[30] orelse return error.ReturnAddressUnavailable) & mask;
    } else if (mode == 0x04000000) {
        if (encoding & 0x00fff0e0 != 0) return error.MachOCompactEncodingUnsupported;
        const fp = context.registers[29] orelse return error.RegisterUnavailable;
        const sp = context.registers[31] orelse return error.RegisterUnavailable;
        if (fp % 16 != 0 or fp < sp) return error.InvalidFrame;
        cfa = std.math.add(u64, fp, 16) catch return error.InvalidAddress;
        var pair: [16]u8 = undefined;
        if (try context.read(context.user, fp, &pair) != pair.len) return error.MemoryUnreadable;
        caller[29] = std.mem.readInt(u64, pair[0..8], .little) & mask;
        caller[32] = std.mem.readInt(u64, pair[8..16], .little) & mask;
        var saved = fp;
        for (0..9) |pair_index| {
            const bit: u5 = @intCast(if (pair_index < 5) pair_index else pair_index + 3);
            if (encoding & (@as(u32, 1) << bit) == 0) continue;
            const first = if (pair_index < 5) 19 + pair_index * 2 else 72 + (pair_index - 5) * 2;
            for (0..2) |i| {
                saved = std.math.sub(u64, saved, 8) catch return error.InvalidAddress;
                // The current transport register set contains integer
                // registers only; omitted SIMD registers are never invented.
                if (first + i < caller.len) caller[first + i] = word(context, saved) catch null;
            }
        }
    } else return error.MachOCompactEncodingUnsupported;
    caller[31] = cfa;
    if (caller[32] == 0) return error.ReturnAddressUnavailable;
    return .{ .cfa = cfa, .caller = caller, .method = .macho_compact };
}

test "ARM64 compact leaf restores SP and LR without inventing volatile registers" {
    const Reader = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) !usize {
            return error.UnexpectedMemoryRead;
        }
    };
    var user: u8 = 0;
    var regs: loc.RegisterSet = @splat(null);
    regs[0] = 99;
    regs[19] = 42;
    regs[29] = 0x8000;
    regs[30] = 0xff80000100002000;
    regs[31] = 0x7000;
    const result = try unwind(0x02001000, .{ .registers = regs, .user = &user, .read = Reader.read }, 0x7fffffffffff);
    try std.testing.expectEqual(@as(?u64, 0x100002000), result.caller[32]);
    try std.testing.expectEqual(@as(u64, 0x7010), result.cfa);
    try std.testing.expectEqual(@as(?u64, 42), result.caller[19]);
    try std.testing.expectEqual(@as(?u64, null), result.caller[0]);
}

test "Apple EH frame preserves link addresses and decodes a nonstandard Swift frame" {
    const c = @import("../c.zig").api;
    const Fixture = struct {
        bytes: []const u8,
        fn file(user: ?*anyopaque, at: u64, out: ?*anyopaque, count: usize) callconv(.c) c.enum_xmo_status {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            if (at > self.bytes.len or count > self.bytes.len - at) return c.XMO_MALFORMED;
            const dest: [*]u8 = @ptrCast(out.?);
            @memcpy(dest[0..count], self.bytes[@intCast(at)..][0..count]);
            return c.XMO_OK;
        }
        fn memory(_: *anyopaque, at: u64, bytes: []u8) !usize {
            if (bytes.len != 8) return error.UnexpectedMemoryRead;
            const value: u64 = switch (at) {
                0x7058 => 0x2000,
                0x7050 => 0x8000,
                0x7040 => 55,
                else => return error.UnexpectedMemoryRead,
            };
            std.mem.writeInt(u64, bytes[0..8], value, .little);
            return bytes.len;
        }
    };
    const owned_data = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/macos-names/corpus/out/swift/arm64-Onone/libXFDep.dylib", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(owned_data);
    var fixture = Fixture{ .bytes = owned_data };
    const source = c.struct_xmo_source{ .context = &fixture, .size = fixture.bytes.len, .layout = c.XMO_FILE, .read = Fixture.file };
    var image: ?*c.struct_xmo_image = null;
    try std.testing.expectEqual(@as(c.enum_xmo_status, c.XMO_OK), c.xmo_load(&source, null, &image));
    defer c.xmo_destroy(image);
    var container: c.struct_xmo_dwarf = std.mem.zeroes(c.struct_xmo_dwarf);
    try std.testing.expectEqual(@as(c.enum_xmo_status, c.XMO_OK), c.xmo_dwarf_build(image, 1024 * 1024, &container));
    defer c.xmo_dwarf_free(&container);
    var cfi = try info.Cfi.init(.aarch64, container.bytes[0..container.size]);
    defer cfi.deinit();
    var regs: loc.RegisterSet = @splat(null);
    regs[29] = 0x7050;
    regs[31] = 0x7000;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // llvm-dwarfdump: from 0x1918, CFA=x29+16; x20=[CFA-32],
    // x29=[CFA-16], x30=[CFA-8]. The compiler cannot encode this saved x20
    // alone as a compact register pair and selects the DWARF recipe.
    const body = try cfi.unwind(arena.allocator(), 0x1918, .{ .registers = regs, .user = &fixture, .read = Fixture.memory });
    try std.testing.expect(!body.outermost);
    try std.testing.expectEqual(@as(u64, 0x7060), body.cfa);
    try std.testing.expectEqual(@as(?u64, 0x2000), body.caller[32]);
    try std.testing.expectEqual(@as(?u64, 55), body.caller[20]);
    try std.testing.expectEqual(@as(?u64, 0x8000), body.caller[29]);
    regs[30] = 0x3000;
    const entry = try cfi.unwind(arena.allocator(), 0x1908, .{ .registers = regs, .user = &fixture, .read = Fixture.memory });
    try std.testing.expect(!entry.outermost);
    try std.testing.expectEqual(@as(u64, 0x7000), entry.cfa);
    try std.testing.expectEqual(@as(?u64, 0x3000), entry.caller[32]);
}
