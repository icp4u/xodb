//! Resolve exact function hooks against a verified mapped runtime ELF.
//! Shared by allocations and generic function observations; no ABI interpretation.
//! No debug companions, global symbol guesses, target writes or probe creation.
//! Caller holds the target stopped, selects its executable VMA, and retains the
//! returned descriptor until the collector has pinned and rechecked it.
const std = @import("std");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const snapshot = @import("../binary/snapshot.zig");
const modules = @import("../model/modules.zig");
const rt = @import("../target/runtime.zig").c;
pub const max_hooks = 16;
// Bound the immutable preparation snapshot, including unstripped debug builds.
pub const image_limit = 128 * 1024 * 1024;
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
pub const Source = struct { id: u16, fd: c_int, offset: u64, identity: Identity };
pub const Request = struct { id: u16, name: []const u8 };
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
    return prepareTarget(null, pid, region, requests, limit, cancel);
}
pub fn prepareTarget(target: ?*const rt.struct_xrt_target, pid: i32, region: modules.Region, requests: []const Request, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Prepared {
    try cancelled(cancel);
    if (requests.len == 0 or requests.len > max_hooks or limit == 0 or limit > image_limit) return error.InvalidAllocationHooks;
    if (pid <= 0) return error.AllocationMappingIdentity;
    var original: rt.struct_xrt_file_identity = undefined;
    var result = Prepared{ .fd = @import("../binary/mapped_file.zig").openIdentity(target, pid, region, &original) catch return error.AllocationMappingIdentity, .count = requests.len };
    const target_identity = Identity{ .device = original.device, .inode = original.inode, .size = original.size, .mtime_sec = original.mtime_sec, .mtime_ns = original.mtime_ns, .ctime_sec = original.ctime_sec, .ctime_ns = original.ctime_ns };
    errdefer result.close();
    const before = try identity(result.fd);
    const bytes = snapshot.read(result.fd, limit, cancel) catch |err| return if (err == error.ArchiveCancelled) error.AllocationPreparationCancelled else err;
    defer _ = c.munmap(bytes.ptr, bytes.len);
    const image = try elf.Image.parse(bytes);
    for (requests, 0..) |request, i| {
        const location = try resolve(&image, region, request.name, cancel);
        for (result.sources[0..i]) |old| if (old.id == request.id or old.offset == location.offset) return error.DuplicateAllocationHook;
        result.sources[i] = .{ .id = request.id, .fd = result.fd, .offset = location.offset, .identity = target_identity };
        result.locations[i] = location;
    }
    if (!std.meta.eql(before, try identity(result.fd))) return error.AllocationFileChanged;
    return result;
}
