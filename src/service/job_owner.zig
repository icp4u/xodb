//! Thin retained-job ownership adapter; authorization lives in the C service.
const c = @import("lease.zig").c;
pub const Owner = struct {
    value: c.struct_xsvc_job_owner = .{ .client = 0, .kind = c.XSVC_JOB_HUMAN },
    pub fn agent(client: ?u64) Owner {
        return .{ .value = .{ .client = client orelse 0, .kind = if (client != null) c.XSVC_JOB_SHARED else c.XSVC_JOB_STDIO } };
    }
    pub fn require(self: Owner, requester: Requester) !void {
        if (!c.xsvc_job_may_change(self.value, requester.owner.value, requester.controller)) return error.JobNotOwned;
    }
};
pub const Requester = struct { owner: Owner = .{}, controller: bool = false };
