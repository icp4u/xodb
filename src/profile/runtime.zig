//! C-owned perf handles; host decoders consume borrowed data through callbacks.
const std = @import("std");
pub const c = @cImport({
    @cInclude("xrt_perf.h");
    @cInclude("xrt_remote.h");
    @cInclude("xrt_allocations.h");
});
pub const testing = @import("builtin").is_test;
pub const internal = if (testing) @cImport({
    @cInclude("perf_internal.h");
}) else struct {};
pub fn state(handle: *c.struct_xrt_perf) *internal.struct_xrt_perf {
    if (!testing) @compileError("collector fault injection is test-only");
    return @ptrCast(@alignCast(handle));
}
pub fn failure(f: c.struct_xrt_perf_failure) @import("linux_perf.zig").Failure {
    return .{ .kind = @enumFromInt(f.kind), .syscall = std.mem.span(f.syscall), .errno = f.@"error", .tid = f.tid, .opened_then_closed = f.opened_then_closed, .detail = std.mem.span(f.detail) };
}
pub fn info(handle: *const c.struct_xrt_perf) c.struct_xrt_perf_info {
    var value: c.struct_xrt_perf_info = undefined;
    c.xrt_perf_info(handle, &value);
    return value;
}
pub fn copy(ring: []const u8, tail: u64, out: []u8) void {
    std.debug.assert(c.xrt_perf_copy(ring.ptr, ring.len, tail, out.ptr, out.len));
}
