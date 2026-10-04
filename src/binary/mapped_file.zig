//! Shared live mapping identity for symbols and allocator hook preparation.
const std = @import("std");
const c = @import("../c.zig").api;

fn matching(path: [:0]const u8, pid: i32, region: anytype) c_int {
    const fd = c.open(path, c.O_RDONLY | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return -1;
    if (c.xodb_mapped_file_matches(fd, pid, region.start, region.end, region.device_major, region.device_minor, region.inode, 0) == 1) return fd;
    _ = c.close(fd);
    return -1;
}
pub fn open(pid: i32, region: anytype) !c_int {
    if (region.inode == 0 or region.path.len == 0 or region.path[0] != '/' or std.mem.indexOfScalar(u8, region.path, 0) != null) return error.BinaryIdentityUnavailable;
    var path: [8192]u8 = undefined;
    if (pid > 0) {
        var fd = matching(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/map_files/{x}-{x}", .{ pid, region.start, region.end }, 0), pid, region);
        if (fd >= 0) return fd;
        fd = matching(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/exe", .{pid}, 0), pid, region);
        if (fd >= 0) return fd;
        fd = matching(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/root{s}", .{ pid, region.path }, 0), pid, region);
        if (fd >= 0) return fd;
    }
    const fd = matching(try std.fmt.bufPrintSentinel(&path, "{s}", .{region.path}, 0), pid, region);
    if (fd >= 0) return fd;
    return error.BinaryIdentityUnavailable;
}
