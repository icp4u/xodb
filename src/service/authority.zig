//! Live shared-session authorization, independent of a protocol frontend.
pub const c = @import("lease.zig").c;
pub const Caller = struct {
    actor: @import("../model/command.zig").Actor,
    client: ?u64 = null,
    lease: ?@import("lease.zig").Lease = null,
};
pub fn check(result: c.enum_xsvc_result) !void {
    switch (result) {
        c.XSVC_OK => {},
        c.XSVC_BAD_REQUEST => return error.InvalidArguments,
        c.XSVC_NO_CLIENT => return error.UnknownSessionClient,
        c.XSVC_SCOPE_DENIED => return error.ScopeDenied,
        c.XSVC_CONTROLLER_BUSY => return error.ControllerBusy,
        c.XSVC_CONTROL_REQUIRED => return error.ControlLeaseRequired,
        c.XSVC_LIMIT => return error.SessionLimit,
        else => return error.SessionServiceFailed,
    }
}
pub const Required = enum { control, mutate, execute };
pub fn authorize(service: *c.struct_xsvc, client: u64, required: Required, now: u64) !void {
    const result = c.xsvc_authorize(service, client, switch (required) {
        .control => c.XSVC_CONTROL,
        .mutate => c.XSVC_MUTATE,
        .execute => c.XSVC_EXECUTE,
    }, now);
    if (result == c.XSVC_SCOPE_DENIED) return error.AgentScopeDenied;
    try check(result);
}
