//! GUI source-copy cache. Authorization, limits and identity checks live in C.
const std = @import("std");
const c = @import("../c.zig").api;
const runtime = @import("../target/runtime.zig");
const rt = runtime.c;
const Sha = std.crypto.hash.sha2.Sha256;

fn key(meta: rt.struct_xrt_source_file, path: []const u8) [32]u8 {
    var hash = Sha.init(.{});
    hash.update("xodb-source-v1\x00");
    hash.update(meta.build_id[0..meta.build_id_size]);
    hash.update(&.{0});
    hash.update(path);
    hash.update(&.{0});
    const id = meta.identity;
    for ([_]u64{ id.device, id.inode, @bitCast(id.size), @bitCast(id.mtime_sec), @bitCast(id.mtime_ns), @bitCast(id.ctime_sec), @bitCast(id.ctime_ns) }) |v| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, v, .little);
        hash.update(&bytes);
    }
    return hash.finalResult();
}
fn directory(a: std.mem.Allocator) !c_int {
    const base = if (c.getenv("XDG_CACHE_HOME")) |p| blk: {
        const s = std.mem.span(p);
        if (s.len > 0 and s[0] == '/') break :blk s;
        return error.SourceCacheUnavailable;
    } else if (c.getenv("HOME")) |p| try std.fmt.allocPrint(a, "{s}/.cache", .{std.mem.span(p)}) else return error.SourceCacheUnavailable;
    const root = try a.dupeZ(u8, base);
    _ = c.mkdir(root, @as(c_uint, 0o700));
    const path = try std.fmt.allocPrintSentinel(a, "{s}/xodb-source-v1", .{base}, 0);
    _ = c.mkdir(path, @as(c_uint, 0o700));
    const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.SourceCacheUnavailable;
    errdefer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_uid != c.geteuid() or st.st_mode & 0o077 != 0) return error.SourceCacheUnavailable;
    return fd;
}
fn readAll(fd: c_int, bytes: []u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.read(fd, bytes.ptr + done, bytes.len - done);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}
fn writeAll(fd: c_int, bytes: []const u8) bool {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = c.write(fd, bytes.ptr + done, bytes.len - done);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return false;
        done += @intCast(n);
    }
    return true;
}
fn slot(digest: [32]u8) [3:0]u8 {
    const digits = "0123456789abcdef";
    const n = digest[0] & 127;
    return .{ digits[n >> 4], digits[n & 15], 's' };
}
fn cached(dir: c_int, digest: [32]u8, out: []u8) bool {
    const name = slot(digest);
    const fd = c.openat(dir, &name, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_NONBLOCK);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_mode & 0o077 != 0 or st.st_uid != c.geteuid() or st.st_nlink != 1 or st.st_size != out.len + 64) return false;
    var header: [64]u8 = undefined;
    if (!readAll(fd, &header) or !std.mem.eql(u8, header[0..32], &digest) or !readAll(fd, out)) return false;
    var actual: [32]u8 = undefined;
    Sha.hash(out, &actual, .{});
    return std.mem.eql(u8, header[32..], &actual);
}
fn store(dir: c_int, digest: [32]u8, bytes: []const u8) void {
    const name = slot(digest);
    const temporary: [4:0]u8 = .{ name[0], name[1], name[2], 't' };
    // Fixed slots bound retained files, including crash leftovers. A lease
    // permits safe reuse of an abandoned temporary while an active writer
    // yields immediately. Never truncate a renamed, already published inode.
    const fd = c.openat(dir, &temporary, c.O_WRONLY | c.O_CLOEXEC | c.O_CREAT | c.O_NOFOLLOW | c.O_NONBLOCK, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var opened: c.struct_stat = undefined;
    var named: c.struct_stat = undefined;
    if (c.fstat(fd, &opened) != 0 or opened.st_mode & c.S_IFMT != c.S_IFREG or
        opened.st_mode & 0o077 != 0 or opened.st_uid != c.geteuid() or opened.st_nlink != 1 or
        c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return;
    if (c.fstatat(dir, &temporary, &named, c.AT_SYMLINK_NOFOLLOW) != 0 or
        named.st_dev != opened.st_dev or named.st_ino != opened.st_ino) return;
    var published = false;
    defer if (!published) {
        _ = c.unlinkat(dir, &temporary, 0);
    };
    if (c.ftruncate(fd, 0) != 0) return;
    var header: [64]u8 = undefined;
    @memcpy(header[0..32], &digest);
    Sha.hash(bytes, header[32..64], .{});
    if (!writeAll(fd, &header) or !writeAll(fd, bytes)) return;
    published = c.renameat(dir, &temporary, dir, &name) == 0;
}
fn reason(meta: rt.struct_xrt_source_file) anyerror {
    return switch (meta.reason) {
        rt.XRT_SOURCE_AGENT_UPDATE => error.SourceAgentNeedsUpdating,
        rt.XRT_SOURCE_NOT_LISTED => error.SourcePathNotListed,
        rt.XRT_SOURCE_DEBUG_UNAVAILABLE => error.SourceDebugInfoUnavailable,
        rt.XRT_SOURCE_DEBUG_LIMIT => error.SourceDebugInfoLimit,
        rt.XRT_SOURCE_TOO_LARGE => error.SourceFileTooLarge,
        rt.XRT_SOURCE_COUNT_LIMIT => error.SourceRequestLimit,
        rt.XRT_SOURCE_CHANGED => error.SourceFileChanged,
        rt.XRT_SOURCE_PATH_UNSAFE => error.SourcePathUnsafe,
        rt.XRT_SOURCE_KERNEL_UNSUPPORTED => error.SourceKernelNeedsOpenat2,
        rt.XRT_SOURCE_FILESYSTEM_UNSUPPORTED => error.SourceFilesystemUnsupported,
        else => error.RemoteSourceUnavailable,
    };
}
pub fn fetch(a: std.mem.Allocator, target: *const rt.struct_xrt_target, request: *const rt.struct_xrt_file_request, path: []const u8, expected_build_id: []const u8) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const s = scratch.allocator();
    const name = try s.dupeZ(u8, path);
    var meta: rt.struct_xrt_source_file = undefined;
    if (rt.xrt_source_open(target, request, name, &meta) != rt.XRT_OK) return reason(meta);
    defer if (meta.handle != 0) {
        _ = rt.xrt_source_close(target, &meta);
    };
    if (!std.mem.eql(u8, meta.build_id[0..meta.build_id_size], expected_build_id)) return error.SourceBuildIdMismatch;
    const bytes = try a.alloc(u8, @intCast(meta.identity.size));
    errdefer a.free(bytes);
    const digest = key(meta, path);
    const dir = directory(s) catch -1;
    defer if (dir >= 0) {
        _ = c.close(dir);
    };
    const hit = dir >= 0 and cached(dir, digest, bytes);
    if (!hit) {
        var at: usize = 0;
        while (at < bytes.len) {
            const n = @min(65536, bytes.len - at);
            try runtime.check(rt.xrt_source_read(target, &meta, at, bytes.ptr + at, n));
            at += n;
        }
    }
    // Even a cache hit reopens the authorized source and checks identity at
    // close. Changed/unavailable files never fall back to an old cached copy.
    try runtime.check(rt.xrt_source_close(target, &meta));
    if (!hit and dir >= 0) store(dir, digest, bytes);
    return bytes;
}

test "remote source cache key includes source identity and build ID" {
    var meta = std.mem.zeroes(rt.struct_xrt_source_file);
    meta.build_id_size = 2;
    meta.build_id[0] = 1;
    meta.identity.size = 5;
    const initial = key(meta, "/src/demo.c");
    try std.testing.expect(!std.mem.eql(u8, &initial, &key(meta, "/src/other.c")));
    meta.identity.mtime_ns = 1;
    try std.testing.expect(!std.mem.eql(u8, &initial, &key(meta, "/src/demo.c")));
    meta.identity.mtime_ns = 0;
    meta.build_id[1] = 9;
    try std.testing.expect(!std.mem.eql(u8, &initial, &key(meta, "/src/demo.c")));
}

test "source cache rejects corrupt bytes, collisions, symlinks and FIFOs without blocking" {
    const a = std.testing.allocator;
    const tmp = if (c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    const template = try std.fmt.allocPrintSentinel(a, "{s}/xodb-source-cache-XXXXXX", .{tmp}, 0);
    defer a.free(template);
    const dir_name = c.mkdtemp(template.ptr) orelse return error.TestDirectoryUnavailable;
    defer _ = c.rmdir(dir_name);
    const dir = c.open(dir_name, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
    try std.testing.expect(dir >= 0);
    defer _ = c.close(dir);
    var digest: [32]u8 = @splat(3);
    const name = slot(digest);
    const temp: [4:0]u8 = .{ name[0], name[1], name[2], 't' };
    defer _ = c.unlinkat(dir, &name, 0);
    defer _ = c.unlinkat(dir, &temp, 0);
    var out: [4]u8 = undefined;
    store(dir, digest, "test");
    try std.testing.expect(cached(dir, digest, &out));
    try std.testing.expectEqualStrings("test", &out);
    const fd = c.openat(dir, &name, c.O_WRONLY | c.O_CLOEXEC);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, 1), c.pwrite(fd, "!", 1, 64));
    _ = c.close(fd);
    try std.testing.expect(!cached(dir, digest, &out));
    store(dir, digest, "test");
    digest[1] = 7;
    try std.testing.expect(!cached(dir, digest, &out));
    store(dir, digest, "next");
    try std.testing.expect(cached(dir, digest, &out));
    try std.testing.expectEqualStrings("next", &out);
    _ = c.unlinkat(dir, &name, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat(&temp, dir, &name));
    try std.testing.expect(!cached(dir, digest, &out));
    _ = c.unlinkat(dir, &name, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifoat(dir, &name, 0o600));
    try std.testing.expect(!cached(dir, digest, &out));
    _ = c.unlinkat(dir, &name, 0);
    const stale = c.openat(dir, &temp, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    try std.testing.expect(stale >= 0);
    try std.testing.expectEqual(@as(c_int, 0), c.flock(stale, c.LOCK_EX | c.LOCK_NB));
    store(dir, digest, "test");
    try std.testing.expect(!cached(dir, digest, &out));
    _ = c.close(stale);
    store(dir, digest, "test");
    try std.testing.expect(cached(dir, digest, &out));
    try std.testing.expectEqualStrings("test", &out);
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifoat(dir, &temp, 0o600));
    store(dir, digest, "nope");
    try std.testing.expect(cached(dir, digest, &out));
    try std.testing.expectEqualStrings("test", &out);
    _ = c.unlinkat(dir, &temp, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.symlinkat(&name, dir, &temp));
    store(dir, digest, "nope");
    try std.testing.expect(cached(dir, digest, &out));
    try std.testing.expectEqualStrings("test", &out);
}
