//! Owned read-only ELF bytes; never retain a mapping of a mutable file.
const std = @import("std");
const c = @import("../c.zig").api;
pub const per_image_limit: usize = 256 * 1024 * 1024;
pub const total_limit: usize = 512 * 1024 * 1024;
pub const Bytes = []align(std.heap.page_size_min) u8;
pub fn read(fd: c_int, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Bytes {
    var before: c.struct_stat = undefined;
    if (c.fstat(fd, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG or before.st_size <= 0) return error.BinaryUnavailable;
    const bytes = try readRange(fd, 0, @intCast(before.st_size), limit, cancel);
    errdefer _ = c.munmap(bytes.ptr, bytes.len);
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or before.st_size != after.st_size or
        before.st_mtim.tv_sec != after.st_mtim.tv_sec or before.st_mtim.tv_nsec != after.st_mtim.tv_nsec or
        before.st_ctim.tv_sec != after.st_ctim.tv_sec or before.st_ctim.tv_nsec != after.st_ctim.tv_nsec) return error.BinaryChangedDuringRead;
    return bytes;
}
/// Snapshot exactly one ELF entry, so a large APK is not retained per library.
pub fn readRange(fd: c_int, file_offset: u64, size: usize, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Bytes {
    var before: c.struct_stat = undefined;
    if (c.fstat(fd, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG or before.st_size <= 0 or size == 0) return error.BinaryUnavailable;
    if (size > limit) return error.BinarySnapshotLimit;
    const end = std.math.add(u64, file_offset, size) catch return error.BinaryUnavailable;
    if (end > @as(u64, @intCast(before.st_size))) return error.BinaryUnavailable;
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
    if (ptr == std.c.MAP_FAILED) return error.OutOfMemory;
    const bytes: Bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr.?)))[0..size];
    errdefer _ = c.munmap(bytes.ptr, bytes.len);
    var offset: usize = 0;
    while (offset < size) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.ArchiveCancelled;
        const n = c.pread(fd, bytes.ptr + offset, @min(1024 * 1024, size - offset), @intCast(file_offset + offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.BinaryChangedDuringRead;
        offset += @intCast(n);
    }
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or before.st_size != after.st_size or
        before.st_mtim.tv_sec != after.st_mtim.tv_sec or before.st_mtim.tv_nsec != after.st_mtim.tv_nsec or
        before.st_ctim.tv_sec != after.st_ctim.tv_sec or before.st_ctim.tv_nsec != after.st_ctim.tv_nsec) return error.BinaryChangedDuringRead;
    if (c.mprotect(bytes.ptr, size, c.PROT_READ) != 0) return error.BinaryUnavailable;
    return bytes;
}
pub fn bootId() ?[36]u8 {
    return bootIdTarget(null);
}
pub fn bootIdTarget(target: ?*const @import("../target/runtime.zig").c.struct_xrt_target) ?[36]u8 {
    const rt = @import("../target/runtime.zig").c;
    const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_BOOT_ID });
    var fd: c_int = -1;
    const status = if (target) |t| rt.xrt_target_file(t, &request, &fd) else rt.xrt_process_file(0, &request, &fd);
    if (status != rt.XRT_OK) return null;
    defer _ = c.close(fd);
    var value: [36]u8 = undefined;
    if (c.read(fd, &value, value.len) != value.len) return null;
    for (value) |b| if (!std.ascii.isHex(b) and b != '-') return null;
    return value;
}
