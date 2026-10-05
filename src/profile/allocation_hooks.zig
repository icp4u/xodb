//! Allocation labels over the common verified function-hook resolver.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const modules = @import("../model/modules.zig");
const rt = @import("../target/runtime.zig").c;
const Kind = @import("allocation_lifetimes.zig").Kind;
const hooks = @import("uprobe_hooks.zig");
pub const max_hooks = hooks.max_hooks;
pub const image_limit = hooks.image_limit;
pub const symbol_limit = hooks.symbol_limit;
pub const Identity = hooks.Identity;
pub const identity = hooks.identity;
pub const Location = hooks.Location;
pub const resolve = hooks.resolve;
pub const Source = struct { id: u16, kind: Kind, fd: c_int, offset: u64, identity: Identity };
pub const Request = struct { id: u16, kind: Kind, name: []const u8 };
pub const Prepared = struct {
    fd: c_int,
    count: usize,
    sources: [max_hooks]Source = undefined,
    locations: [max_hooks]Location = undefined,
    pub fn close(self: *Prepared) void {
        _ = c.close(self.fd);
        self.fd = -1;
    }
};
pub fn prepare(pid: i32, region: modules.Region, requests: []const Request, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Prepared {
    return prepareTarget(null, pid, region, requests, limit, cancel);
}
pub fn prepareTarget(target: ?*const rt.struct_xrt_target, pid: i32, region: modules.Region, requests: []const Request, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Prepared {
    if (requests.len == 0 or requests.len > max_hooks) return error.InvalidAllocationHooks;
    var generic: [max_hooks]hooks.Request = undefined;
    for (requests, 0..) |request, i| generic[i] = .{ .id = request.id, .name = request.name };
    const prepared = try hooks.prepareTarget(target, pid, region, generic[0..requests.len], limit, cancel);
    var result = Prepared{ .fd = prepared.fd, .count = prepared.count, .locations = prepared.locations };
    for (prepared.sources[0..prepared.count], requests, 0..) |source, request, i| result.sources[i] = .{ .id = source.id, .kind = request.kind, .fd = source.fd, .offset = source.offset, .identity = source.identity };
    return result;
}

test "allocation hooks resolve real libc functions from their mapped runtime file" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var maps = modules.Modules.init(std.testing.allocator);
    defer maps.deinit();
    try maps.refresh(c.getpid());
    const address = @intFromPtr(&c.malloc);
    const region = for (maps.regions.items) |r| {
        if (address >= r.start and address < r.end) break r;
    } else return error.TestLibcMapping;
    const requests = [_]Request{
        .{ .id = 0, .kind = .malloc, .name = "malloc" },
        .{ .id = 1, .kind = .calloc, .name = "calloc" },
        .{ .id = 2, .kind = .realloc, .name = "realloc" },
        .{ .id = 3, .kind = .free, .name = "free" },
    };
    var ready = try prepare(c.getpid(), region, &requests, image_limit, null);
    defer ready.close();
    try std.testing.expectEqual(address, ready.locations[0].runtime_address);
    try std.testing.expectEqual(@as(usize, 4), ready.count);
    for (ready.sources[0..ready.count], ready.locations[0..ready.count]) |source, location| {
        try std.testing.expectEqual(region.offset + location.runtime_address - region.start, source.offset);
        try std.testing.expectEqual(region.inode, source.identity.inode);
    }
    var wrong = region;
    wrong.inode +%= 1;
    try std.testing.expectError(error.AllocationMappingIdentity, prepare(c.getpid(), wrong, &requests, image_limit, null));
    try std.testing.expectError(error.BinarySnapshotLimit, prepare(c.getpid(), region, &requests, 1, null));
    try std.testing.expectError(error.DuplicateAllocationHook, prepare(c.getpid(), region, &.{ requests[0], requests[0] }, image_limit, null));
    var stop = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.AllocationPreparationCancelled, prepare(c.getpid(), region, &requests, image_limit, &stop));
}

fn testPut(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn testElf() [8192]u8 {
    var b: [8192]u8 = @splat(0);
    @memcpy(b[0..7], "\x7fELF\x02\x01\x01");
    testPut(u16, &b, 16, 3);
    testPut(u16, &b, 18, 62);
    testPut(u32, &b, 20, 1);
    testPut(u64, &b, 32, 64);
    testPut(u64, &b, 40, 0x100);
    testPut(u16, &b, 52, 64);
    testPut(u16, &b, 54, 56);
    testPut(u16, &b, 56, 1);
    testPut(u16, &b, 58, 64);
    testPut(u16, &b, 60, 4);
    testPut(u32, &b, 64, 1);
    testPut(u32, &b, 68, 5);
    testPut(u64, &b, 72, 0x1000);
    testPut(u64, &b, 80, 0x4000);
    testPut(u64, &b, 96, 0x100);
    testPut(u64, &b, 104, 0x200);
    testPut(u64, &b, 112, 0x1000);
    testPut(u32, &b, 0x144, 1);
    testPut(u64, &b, 0x148, 6);
    testPut(u64, &b, 0x150, 0x4000);
    testPut(u64, &b, 0x158, 0x1000);
    testPut(u64, &b, 0x160, 0x100);
    testPut(u32, &b, 0x184, 2);
    testPut(u64, &b, 0x198, 0x300);
    testPut(u64, &b, 0x1a0, 72);
    testPut(u32, &b, 0x1a8, 3);
    testPut(u64, &b, 0x1b8, 24);
    testPut(u32, &b, 0x1c4, 3);
    testPut(u64, &b, 0x1d8, 0x400);
    testPut(u64, &b, 0x1e0, 8);
    testPut(u32, &b, 0x318, 1);
    b[0x31c] = 0x12;
    testPut(u16, &b, 0x31e, 1);
    testPut(u64, &b, 0x320, 0x4040);
    testPut(u64, &b, 0x328, 16);
    @memcpy(b[0x400..0x408], "\x00malloc\x00");
    return b;
}
const test_region = modules.Region{ .start = 0x704000, .end = 0x705000, .offset = 0x1000, .inode = 1, .device_major = 1, .device_minor = 1, .permissions = "r-xp".*, .path = "/fixture" };
test "hook addresses translate from executable ELF file offsets through one observed VMA" {
    var bytes = testElf();
    var image = try elf.Image.parse(&bytes);
    const location = try resolve(&image, test_region, "malloc", null);
    try std.testing.expectEqual(Location{ .offset = 0x1040, .link_address = 0x4040, .runtime_address = 0x704040 }, location);
    // Same-address duplicates are common between ELF symbol tables/aliases.
    @memcpy(bytes[0x330..0x348], bytes[0x318..0x330]);
    try std.testing.expectEqual(location, try resolve(&image, test_region, "malloc", null));
    testPut(u64, &bytes, 0x338, 0x4048);
    try std.testing.expectError(error.AmbiguousAllocationSymbol, resolve(&image, test_region, "malloc", null));
}
test "hook preparation rejects IFUNC, data, undefined and non-file-backed code" {
    var bytes = testElf();
    var image = try elf.Image.parse(&bytes);
    for ([_]u8{ 0x1a, 0x11, 0x10 }) |typ| {
        bytes[0x31c] = typ;
        try std.testing.expectError(error.UnsupportedAllocationSymbol, resolve(&image, test_region, "malloc", null));
    }
    bytes = testElf();
    testPut(u16, &bytes, 0x31e, 0);
    try std.testing.expectError(error.AllocationSymbolNotFound, resolve(&image, test_region, "malloc", null));
    bytes = testElf();
    testPut(u64, &bytes, 96, 0x20);
    try std.testing.expectError(error.AllocationSymbolNotFileBacked, resolve(&image, test_region, "malloc", null));
    bytes = testElf();
    testPut(u64, &bytes, 0x148, 2);
    try std.testing.expectError(error.AllocationSymbolNotExecutable, resolve(&image, test_region, "malloc", null));
    bytes = testElf();
    var region = test_region;
    region.permissions = "rw-p".*;
    try std.testing.expectError(error.AllocationMappingNotExecutable, resolve(&image, region, "malloc", null));
    region = test_region;
    region.end = region.start + 0x30;
    try std.testing.expectError(error.AllocationSymbolOutsideMapping, resolve(&image, region, "malloc", null));
    try std.testing.expectError(error.AllocationSymbolNotFound, resolve(&image, test_region, "free", null));
    var stop = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.AllocationPreparationCancelled, resolve(&image, test_region, "malloc", &stop));
}
