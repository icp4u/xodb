//! Identity-checked target files. Native and remote access share the C runtime.
const std = @import("std");
const runtime = @import("../target/runtime.zig");
const rt = runtime.c;
pub fn open(pid: i32, region: anytype) !c_int {
    return openTarget(null, pid, region);
}
pub fn openTarget(target: ?*const rt.struct_xrt_target, pid: i32, region: anytype) !c_int {
    return openIdentity(target, pid, region, null);
}
pub fn openIdentity(target: ?*const rt.struct_xrt_target, pid: i32, region: anytype, identity: ?*rt.struct_xrt_file_identity) !c_int {
    if (std.mem.indexOfScalar(u8, region.path, 0) != null or region.path.len >= 8192) return error.BinaryIdentityUnavailable;
    var path: [8192]u8 = undefined;
    @memcpy(path[0..region.path.len], region.path);
    path[region.path.len] = 0;
    const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_MAPPED, .mapping = .{ .start = region.start, .end = region.end, .offset = region.offset, .device_major = region.device_major, .device_minor = region.device_minor, .inode = region.inode, .path = @as([*:0]const u8, @ptrCast(&path)) } });
    var fd: c_int = -1;
    try runtime.check(if (target) |t| rt.xrt_target_file_open(t, &request, &fd, identity) else rt.xrt_process_file(pid, &request, &fd));
    errdefer _ = std.c.close(fd);
    if (target == null) if (identity) |out| try runtime.check(rt.xrt_file_identity(fd, out));
    return fd;
}
