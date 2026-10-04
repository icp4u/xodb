//! Resolve explicit allocator hooks only against a verified mapped runtime ELF.
//! No debug companions, global symbol guesses, target writes or probe creation.
//! Caller holds the target stopped, selects its executable VMA, and retains the
//! returned descriptor until the collector has pinned and rechecked it.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const snapshot = @import("../binary/snapshot.zig");
const modules = @import("../model/modules.zig");
const Kind = @import("allocation_lifetimes.zig").Kind;
pub const max_hooks = 16;
pub const image_limit = 64 * 1024 * 1024;
pub const symbol_limit = 1024 * 1024;
pub const Identity = struct {
    device: u64,
    inode: u64,
    size: i64,
    mtime_sec: i64,
    mtime_ns: i64,
    ctime_sec: i64,
    ctime_ns: i64,
    pub fn fromStat(s: anytype) Identity {
        return .{ .device = s.st_dev, .inode = s.st_ino, .size = s.st_size, .mtime_sec = s.st_mtim.tv_sec, .mtime_ns = s.st_mtim.tv_nsec, .ctime_sec = s.st_ctim.tv_sec, .ctime_ns = s.st_ctim.tv_nsec };
    }
};
pub fn identity(fd: c_int) !Identity {
    var s: c.struct_stat = undefined;
    if (c.fstat(fd, &s) != 0 or s.st_mode & c.S_IFMT != c.S_IFREG or s.st_size <= 0) return error.AllocationFileUnavailable;
    return Identity.fromStat(s);
}
pub const Source = struct { id: u16, kind: Kind, fd: c_int, offset: u64, identity: Identity };
pub const Request = struct { id: u16, kind: Kind, name: []const u8 };
pub const Location = struct { offset: u64, link_address: u64, runtime_address: u64 };
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
fn cancelled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.AllocationPreparationCancelled;
}
fn matching(path: [:0]const u8, region: modules.Region) c_int {
    const fd = c.open(path, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return -1;
    var s: c.struct_stat = undefined;
    if (c.fstat(fd, &s) == 0 and s.st_mode & c.S_IFMT == c.S_IFREG and s.st_ino == region.inode and
        c.major(s.st_dev) == region.device_major and c.minor(s.st_dev) == region.device_minor) return fd;
    _ = c.close(fd);
    return -1;
}
fn open(pid: i32, region: modules.Region) !c_int {
    if (pid <= 0 or region.inode == 0 or region.path.len == 0 or region.path[0] != '/' or std.mem.indexOfScalar(u8, region.path, 0) != null) return error.AllocationMappingIdentity;
    var path: [8192]u8 = undefined;
    var fd = matching(try std.fmt.bufPrintZ(&path, "/proc/{d}/map_files/{x}-{x}", .{ pid, region.start, region.end }), region);
    if (fd >= 0) return fd;
    fd = matching(try std.fmt.bufPrintZ(&path, "/proc/{d}/exe", .{pid}), region);
    if (fd >= 0) return fd;
    // Target mount namespace before local path; both still require dev/inode.
    fd = matching(try std.fmt.bufPrintZ(&path, "/proc/{d}/root{s}", .{ pid, region.path }), region);
    if (fd >= 0) return fd;
    fd = matching(try std.fmt.bufPrintZ(&path, "{s}", .{region.path}), region);
    if (fd >= 0) return fd;
    return error.AllocationMappingIdentity;
}
/// Exact defined function names only. Duplicate table entries at one address
/// are fine; different definitions, IFUNC resolvers and data labels are not.
pub fn resolve(image: *const elf.Image, region: modules.Region, name: []const u8, cancel: ?*const std.atomic.Value(bool)) !Location {
    try cancelled(cancel);
    if (image.header.machine != .x86_64) return error.UnsupportedAllocationArchitecture;
    if (region.start >= region.end or region.permissions[2] != 'x') return error.AllocationMappingNotExecutable;
    if (name.len == 0 or name.len > 256 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidAllocationSymbol;
    // Avoid silently ignoring a second same-kind symbol table.
    var symtabs: usize = 0;
    var dynsyms: usize = 0;
    for (0..image.header.section_count) |i| {
        const section = try image.section(@intCast(i));
        if (section.type == .symtab) symtabs += 1;
        if (section.type == .dynsym) dynsyms += 1;
    }
    if (symtabs > 1 or dynsyms > 1) return error.AmbiguousAllocationSymbolTables;
    var found: ?u64 = null;
    var visited: usize = 0;
    for ([_]elf.SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
        const table = try image.symbols(kind) orelse continue;
        if (table.count() > symbol_limit - visited) return error.AllocationSymbolLimit;
        visited += table.count();
        for (0..table.count()) |i| {
            if (i % 1024 == 0) try cancelled(cancel);
            const symbol = try table.get(@intCast(i));
            if (!std.mem.eql(u8, symbol.name, name) or symbol.placement == .undefined) continue;
            if (symbol.type != .func or symbol.placement != .section) return error.UnsupportedAllocationSymbol;
            const section = try image.section(symbol.placement.section);
            if (section.type != .progbits or section.flags & elf.shf.execinstr == 0 or section.flags & elf.shf.alloc == 0 or
                symbol.value < section.addr or symbol.value - section.addr >= section.size) return error.AllocationSymbolNotExecutable;
            if (found != null and found.? != symbol.value) return error.AmbiguousAllocationSymbol;
            found = symbol.value;
        }
    }
    const link = found orelse return error.AllocationSymbolNotFound;
    const bias = try modules.Modules.observedBias(image, region);
    const runtime = try std.math.add(u64, bias, link);
    if (runtime < region.start or runtime >= region.end) return error.AllocationSymbolOutsideMapping;
    var offset: ?u64 = null;
    for (0..image.header.segment_count) |i| {
        const segment = try image.segment(@intCast(i));
        if (segment.type != .load or segment.flags & elf.pf.x == 0 or link < segment.vaddr or link - segment.vaddr >= segment.file_size) continue;
        _ = try image.segmentData(segment);
        const candidate = try std.math.add(u64, segment.offset, link - segment.vaddr);
        if (offset != null and offset.? != candidate) return error.AmbiguousAllocationOffset;
        offset = candidate;
    }
    const file_offset = offset orelse return error.AllocationSymbolNotFileBacked;
    if (file_offset != try std.math.add(u64, region.offset, runtime - region.start)) return error.AllocationMappingMismatch;
    return .{ .offset = file_offset, .link_address = link, .runtime_address = runtime };
}
pub fn prepare(pid: i32, region: modules.Region, requests: []const Request, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Prepared {
    try cancelled(cancel);
    if (requests.len == 0 or requests.len > max_hooks or limit == 0 or limit > image_limit) return error.InvalidAllocationHooks;
    var result = Prepared{ .fd = try open(pid, region), .count = requests.len };
    errdefer result.close();
    const before = try identity(result.fd);
    const bytes = snapshot.read(result.fd, limit, cancel) catch |err| return if (err == error.ArchiveCancelled) error.AllocationPreparationCancelled else err;
    defer _ = c.munmap(bytes.ptr, bytes.len);
    const image = try elf.Image.parse(bytes);
    for (requests, 0..) |request, i| {
        const location = try resolve(&image, region, request.name, cancel);
        for (result.sources[0..i]) |old| if (old.id == request.id or old.offset == location.offset) return error.DuplicateAllocationHook;
        result.sources[i] = .{ .id = request.id, .kind = request.kind, .fd = result.fd, .offset = location.offset, .identity = before };
        result.locations[i] = location;
    }
    if (!std.meta.eql(before, try identity(result.fd))) return error.AllocationFileChanged;
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
