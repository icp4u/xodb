//! Verified immutable debug companions, explicit or discovered locally.
const std = @import("std");
const c = @import("../c.zig").api;
const elf = @import("elf.zig");
const snapshot = @import("snapshot.zig");
pub const File = struct {
    path: [:0]const u8,
    image: elf.Image,
    bytes: snapshot.Bytes,
    build_id: []const u8,
    verification: enum { explicit_build_id, build_id, debuglink_crc } = .explicit_build_id,
    crc: ?u32 = null,
};
pub const Files = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*File) = .empty,
    retained: usize = 0,
    automatic: bool = true,
    auto_file_limit: usize = 64 * 1024 * 1024,
    auto_total_limit: usize = 128 * 1024 * 1024,
    auto_retained: usize = 0,
    roots: std.ArrayList([:0]const u8) = .empty,
    pub fn deinit(self: *Files) void {
        for (self.items.items) |file| self.destroy(file);
        self.items.deinit(self.allocator);
        for (self.roots.items) |path| self.allocator.free(path);
        self.roots.deinit(self.allocator);
    }
    fn destroy(self: *Files, file: *File) void {
        _ = c.munmap(file.bytes.ptr, file.bytes.len);
        self.allocator.free(file.path);
        self.allocator.destroy(file);
    }
    pub fn addRoot(self: *Files, path: []const u8) !void {
        if (self.roots.items.len >= 16) return error.DebugDirectoryLimit;
        if (path.len == 0 or path.len > 4096 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidDebugDirectory;
        const copy = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(copy);
        try self.roots.append(self.allocator, copy);
    }
    fn read(self: *Files, path: [:0]const u8, limit: usize) !*File {
        if (self.items.items.len >= 64) return error.DebugFileLimit;
        const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.DebugFileUnavailable;
        defer _ = c.close(fd);
        const bytes = try snapshot.read(fd, @min(limit, snapshot.total_limit - self.retained), null);
        errdefer _ = c.munmap(bytes.ptr, bytes.len);
        const image = try elf.Image.parse(bytes);
        if (image.sectionByName(".debug_info") == null and image.sectionByName(".zdebug_info") == null) return error.DebugFileMissingDwarf;
        const name = try self.allocator.dupeZ(u8, path);
        errdefer self.allocator.free(name);
        const file = try self.allocator.create(File);
        file.* = .{ .path = name, .image = image, .bytes = bytes, .build_id = image.buildId() orelse &.{} };
        return file;
    }
    fn retain(self: *Files, file: *File) !void {
        try self.items.append(self.allocator, file);
        self.retained += file.bytes.len;
    }
    pub fn add(self: *Files, path: [:0]const u8) !void {
        const file = try self.read(path, snapshot.per_image_limit);
        errdefer self.destroy(file);
        if (file.build_id.len == 0) return error.DebugFileMissingBuildId;
        for (self.items.items) |existing| if (std.mem.eql(u8, existing.build_id, file.build_id)) return error.DuplicateDebugBuildId;
        try self.retain(file);
    }
    pub fn matching(self: *const Files, image: *const elf.Image) !?*const File {
        const id = image.buildId() orelse return null;
        for (self.items.items) |file| {
            if (!std.mem.eql(u8, file.build_id, id)) continue;
            if (!compatible(image, &file.image)) return error.DebugFileLayoutMismatch;
            return file;
        }
        return null;
    }
    fn verify(file: *File, runtime: *const elf.Image, crc: ?u32) !void {
        if (!compatible(runtime, &file.image)) return error.DebugFileLayoutMismatch;
        if (runtime.buildId()) |id| {
            if (!std.mem.eql(u8, id, file.build_id)) return error.DebugFileBuildIdMismatch;
        } else if (crc == null) return error.DebugFileMissingBuildId;
        if (crc) |expected| {
            if (file.crc == null) file.crc = std.hash.crc.Crc32.hash(file.bytes);
            if (file.crc.? != expected) return error.DebugFileCrcMismatch;
        }
    }
    fn candidate(self: *Files, runtime: *const elf.Image, path: [:0]const u8, crc: ?u32) !?*const File {
        for (self.items.items) |file| if (std.mem.eql(u8, file.path, path)) {
            try verify(file, runtime, crc);
            return file;
        };
        if (self.auto_retained >= self.auto_total_limit) return error.AutomaticDebugBudget;
        const file = self.read(path, @min(self.auto_file_limit, self.auto_total_limit - self.auto_retained)) catch |err| {
            if (err == error.DebugFileUnavailable) return null;
            return err;
        };
        errdefer self.destroy(file);
        try verify(file, runtime, crc);
        file.verification = if (crc != null) .debuglink_crc else .build_id;
        try self.retain(file);
        self.auto_retained += file.bytes.len;
        return file;
    }
    fn attempt(self: *Files, runtime: *const elf.Image, path: [:0]const u8, crc: ?u32) ?*const File {
        return self.candidate(runtime, path, crc) catch |err| {
            std.debug.print("xodb: automatic debug companion rejected: {s}; {s}\n", .{ @errorName(err), path });
            return null;
        };
    }
    pub fn discover(self: *Files, image: *const elf.Image, path: []const u8) !?*const File {
        if (try self.matching(image)) |file| return file;
        if (!self.automatic or image.sectionByName(".debug_info") != null or image.sectionByName(".zdebug_info") != null) return null;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const default_roots = [_][:0]const u8{"/usr/lib/debug"};
        const roots = if (self.roots.items.len == 0) &default_roots else self.roots.items;
        if (image.buildId()) |id| if (id.len >= 2 and id.len <= 64) {
            const hex = try a.alloc(u8, id.len * 2);
            const digits = "0123456789abcdef";
            for (id, 0..) |v, i| {
                hex[2 * i] = digits[v >> 4];
                hex[2 * i + 1] = digits[v & 15];
            }
            for (roots) |root| if (self.attempt(image, try std.fmt.allocPrintSentinel(a, "{s}/.build-id/{s}/{s}.debug", .{ root, hex[0..2], hex[2..] }, 0), null)) |file| return file;
        };
        const section = image.sectionByName(".gnu_debuglink") orelse return null;
        const bytes = try image.sectionData(section);
        const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidDebugLink;
        if (end == 0 or end > 255) return error.InvalidDebugLink;
        const name = bytes[0..end];
        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidDebugLink;
        const crc_at = (end + 1 + 3) & ~@as(usize, 3);
        if (crc_at > bytes.len or bytes.len - crc_at != 4) return error.InvalidDebugLink;
        const crc = std.mem.readInt(u32, bytes[crc_at..][0..4], .little);
        const dir = std.fs.path.dirname(path) orelse return null;
        for ([_][]const u8{ "", ".debug/" }) |middle| if (self.attempt(image, try std.fmt.allocPrintSentinel(a, "{s}/{s}{s}", .{ dir, middle, name }, 0), crc)) |file| return file;
        if (dir.len > 0 and dir[0] == '/') for (roots) |root| if (self.attempt(image, try std.fmt.allocPrintSentinel(a, "{s}{s}/{s}", .{ root, dir, name }, 0), crc)) |file| return file;
        return null;
    }
};
/// Debug-only objcopy files have different file extents but preserve the loaded
/// virtual layout. Build ID plus layout is a build association, not authentication.
pub fn compatible(runtime: *const elf.Image, debug: *const elf.Image) bool {
    if (runtime.header.machine != debug.header.machine or runtime.header.type != debug.header.type) return false;
    var r: u32 = 0;
    var d: u32 = 0;
    while (true) {
        const rs = nextLoad(runtime, &r);
        const ds = nextLoad(debug, &d);
        if (rs == null or ds == null) return rs == null and ds == null;
        if (rs.?.vaddr != ds.?.vaddr or rs.?.mem_size != ds.?.mem_size or rs.?.flags != ds.?.flags or rs.?.alignment != ds.?.alignment) return false;
    }
}
fn nextLoad(image: *const elf.Image, index: *u32) ?elf.Segment {
    while (index.* < image.header.segment_count) {
        const segment = image.segment(index.*) catch return null;
        index.* += 1;
        if (segment.type == .load) return segment;
    }
    return null;
}

test "debug companions require build identity and matching virtual layout" {
    const t = std.testing;
    var files = Files{ .allocator = t.allocator };
    defer files.deinit();
    try files.add("tests/fixtures/elf/out/gcc-pie.debug");
    try t.expectError(error.DuplicateDebugBuildId, files.add("tests/fixtures/elf/out/gcc-pie"));
    try t.expectError(error.DebugFileMissingDwarf, files.add("tests/fixtures/elf/out/gcc-pie.stripped"));
    const fd = c.open("tests/fixtures/elf/out/gcc-pie.stripped", c.O_RDONLY | c.O_CLOEXEC);
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    const bytes = try snapshot.read(fd, snapshot.per_image_limit, null);
    defer _ = c.munmap(bytes.ptr, bytes.len);
    var image = try elf.Image.parse(bytes);
    try t.expect((try files.matching(&image)).? == files.items.items[0]);
    image.header.machine = .aarch64;
    try t.expectError(error.DebugFileLayoutMismatch, files.matching(&image));
    image.header.machine = .x86_64;
    const segments = try t.allocator.dupe(u8, image.segment_table);
    defer t.allocator.free(segments);
    image.segment_table = segments;
    for (0..image.header.segment_count) |i| {
        const s = try image.segment(@intCast(i));
        if (s.type != .load) continue;
        std.mem.writeInt(u64, segments[i * 56 + 16 ..][0..8], s.vaddr + 4096, .little);
        break;
    }
    try t.expectError(error.DebugFileLayoutMismatch, files.matching(&image));
    // A similarly named foreign build must leave the runtime image usable alone.
    const foreign_fd = c.open("tests/fixtures/elf/out/libfix.so", c.O_RDONLY | c.O_CLOEXEC);
    try t.expect(foreign_fd >= 0);
    defer _ = c.close(foreign_fd);
    const foreign_bytes = try snapshot.read(foreign_fd, snapshot.per_image_limit, null);
    defer _ = c.munmap(foreign_bytes.ptr, foreign_bytes.len);
    const foreign = try elf.Image.parse(foreign_bytes);
    try t.expect(try files.matching(&foreign) == null);
}
