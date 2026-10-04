//! Locate an uncompressed ELF inside a ZIP32 APK by its mapped file offset.
//! Reads only ZIP metadata; never extracts paths, decompresses data or scans for ELF magic.
//! Field layouts follow PKWARE APPNOTE 4.3.7/4.3.12/4.3.16. Original implementation.
const std = @import("std");
const c = @import("../c.zig").api;
const A = std.mem.Allocator;
pub const Entry = struct { offset: u64, size: usize };
const max_directory = 16 * 1024 * 1024;
fn rd(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
fn read(fd: c_int, bytes: []u8, offset: u64) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.pread(fd, bytes.ptr + done, bytes.len - done, std.math.cast(c.off_t, offset + done) orelse return error.InvalidApk);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.InvalidApk;
        done += @intCast(n);
    }
}
pub fn find(a: A, fd: c_int, size: u64, mapped_offset: u64) !Entry {
    if (size < 22) return error.NotElf;
    var signature: [4]u8 = undefined;
    try read(fd, &signature, 0);
    if (rd(u32, &signature, 0) != 0x04034b50) return error.NotElf;
    const tail = try a.alloc(u8, @intCast(@min(size, 65535 + 22)));
    defer a.free(tail);
    const tail_size: usize = @intCast(@min(size, tail.len));
    try read(fd, tail[0..tail_size], size - tail_size);
    var pos = tail_size - 22;
    const end = while (true) {
        if (rd(u32, tail, pos) == 0x06054b50 and pos + 22 + @as(usize, rd(u16, tail, pos + 20)) == tail_size) break tail[pos..][0..22];
        if (pos == 0) return error.InvalidApk;
        pos -= 1;
    };
    const count = rd(u16, end, 10);
    const directory_size = rd(u32, end, 12);
    const directory_offset = rd(u32, end, 16);
    if (count == 0xffff or directory_size == 0xffffffff or directory_offset == 0xffffffff) return error.UnsupportedApkZip64;
    if (rd(u16, end, 4) != 0 or rd(u16, end, 6) != 0 or rd(u16, end, 8) != count) return error.UnsupportedApkMultidisk;
    const end_offset = size - tail_size + pos;
    if (@as(u64, directory_offset) + directory_size != end_offset) return error.InvalidApk;
    if (directory_size > max_directory) return error.ApkDirectoryLimit;
    const directory = try a.alloc(u8, directory_size);
    defer a.free(directory);
    try read(fd, directory, directory_offset);
    var cursor: usize = 0;
    var found: ?Entry = null;
    for (0..count) |_| {
        if (directory.len - cursor < 46 or rd(u32, directory, cursor) != 0x02014b50) return error.InvalidApk;
        const header = directory[cursor..][0..46];
        const name_size = rd(u16, header, 28);
        const record_size: usize = 46 + @as(usize, name_size) + rd(u16, header, 30) + rd(u16, header, 32);
        if (record_size > directory.len - cursor) return error.InvalidApk;
        const name = directory[cursor + 46 ..][0..name_size];
        cursor += record_size;
        if (!std.mem.endsWith(u8, name, ".so")) continue;
        const compressed = rd(u32, header, 20);
        const expanded = rd(u32, header, 24);
        const local_offset = rd(u32, header, 42);
        if (compressed == 0xffffffff or expanded == 0xffffffff or local_offset == 0xffffffff) return error.UnsupportedApkZip64;
        if (rd(u16, header, 34) != 0) return error.UnsupportedApkMultidisk;
        if (@as(u64, local_offset) + 30 > directory_offset) return error.InvalidApk;
        var local: [30]u8 = undefined;
        try read(fd, &local, local_offset);
        if (rd(u32, &local, 0) != 0x04034b50 or rd(u16, &local, 26) != name_size or rd(u16, &local, 6) != rd(u16, header, 8) or rd(u16, &local, 8) != rd(u16, header, 10)) return error.InvalidApk;
        const offset = @as(u64, local_offset) + 30 + name_size + rd(u16, &local, 28);
        if (offset + compressed > directory_offset) return error.InvalidApk;
        if (mapped_offset < offset or mapped_offset >= offset + compressed) continue;
        if (rd(u16, header, 10) != 0) return error.UnsupportedApkCompression;
        if (rd(u16, header, 8) & ~@as(u16, 0x0808) != 0) return error.UnsupportedApkFlags;
        if (expanded != compressed or expanded == 0) return error.InvalidApk;
        if (rd(u16, header, 8) & 8 == 0 and (rd(u32, &local, 18) != compressed or rd(u32, &local, 22) != expanded or rd(u32, &local, 14) != rd(u32, header, 16))) return error.InvalidApk;
        const local_name = try a.alloc(u8, name_size);
        defer a.free(local_name);
        try read(fd, local_name, @as(u64, local_offset) + 30);
        if (!std.mem.eql(u8, local_name, name)) return error.InvalidApk;
        if (found != null) return error.AmbiguousApkEntry;
        found = .{ .offset = offset, .size = expanded };
    }
    if (cursor != directory.len) return error.InvalidApk;
    return found orelse error.NoApkElfAtOffset;
}

const TestZip = struct {
    bytes: [4608]u8 = @splat(0),
    const data = 4096;
    const central = data + 16;
    const name = "lib/test.so";
    const record = 46 + name.len;
    fn wr(self: *TestZip, comptime T: type, at: usize, value: T) void {
        std.mem.writeInt(T, self.bytes[at..][0..@sizeOf(T)], value, .little);
    }
    fn init() TestZip {
        var self = TestZip{};
        self.wr(u32, 0, 0x04034b50);
        self.wr(u32, 18, 16);
        self.wr(u32, 22, 16);
        self.wr(u16, 26, name.len);
        self.wr(u16, 28, data - 30 - name.len);
        @memcpy(self.bytes[30..][0..name.len], name);
        self.wr(u32, central, 0x02014b50);
        self.wr(u32, central + 20, 16);
        self.wr(u32, central + 24, 16);
        self.wr(u16, central + 28, name.len);
        @memcpy(self.bytes[central + 46 ..][0..name.len], name);
        return self;
    }
    fn check(self: *TestZip, count: u16, offset: u64) !Entry {
        const eocd = central + record * @as(usize, count);
        self.wr(u32, eocd, 0x06054b50);
        self.wr(u16, eocd + 8, count);
        self.wr(u16, eocd + 10, count);
        self.wr(u32, eocd + 12, @intCast(record * count));
        self.wr(u32, eocd + 16, central);
        const fd = c.memfd_create("xodb-apk-unit", c.MFD_CLOEXEC);
        if (fd < 0) return error.TestFixture;
        defer _ = c.close(fd);
        const size = eocd + 22;
        if (c.write(fd, &self.bytes, size) != size) return error.TestFixture;
        return find(std.testing.allocator, fd, size, offset);
    }
};
test "APK metadata selects an entry by offset and rejects ambiguous or unsupported data" {
    const t = std.testing;
    var z = TestZip.init();
    try t.expectEqual(Entry{ .offset = 4096, .size = 16 }, try z.check(1, 4096));
    try t.expectError(error.NoApkElfAtOffset, z.check(1, 0));
    try t.expectError(error.NoApkElfAtOffset, z.check(1, 4112));
    @memcpy(z.bytes[TestZip.central + TestZip.record ..][0..TestZip.record], z.bytes[TestZip.central..][0..TestZip.record]);
    try t.expectError(error.AmbiguousApkEntry, z.check(2, 4096));
    z = TestZip.init();
    z.wr(u16, 8, 8);
    z.wr(u16, TestZip.central + 10, 8);
    try t.expectError(error.UnsupportedApkCompression, z.check(1, 4096));
    z = TestZip.init();
    z.wr(u16, 6, 1);
    z.wr(u16, TestZip.central + 8, 1);
    try t.expectError(error.UnsupportedApkFlags, z.check(1, 4096));
    z = TestZip.init();
    z.bytes[30] = 'X';
    try t.expectError(error.InvalidApk, z.check(1, 4096));
    z = TestZip.init();
    z.wr(u32, TestZip.central + 42, 0xffffffff);
    try t.expectError(error.UnsupportedApkZip64, z.check(1, 4096));
    z = TestZip.init();
    z.wr(u32, TestZip.central + 24, 17);
    try t.expectError(error.InvalidApk, z.check(1, 4096));
    z = TestZip.init();
    z.wr(u32, TestZip.central + 20, 0xfffffffe);
    try t.expectError(error.InvalidApk, z.check(1, 4096));
    // Data descriptors permit zero sizes in the local header.
    z = TestZip.init();
    z.wr(u16, 6, 8);
    z.wr(u16, TestZip.central + 8, 8);
    z.wr(u32, 18, 0);
    z.wr(u32, 22, 0);
    try t.expectEqual(@as(u64, 4096), (try z.check(1, 4096)).offset);
}
