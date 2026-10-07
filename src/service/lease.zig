//! A borrowed controller lease for an owner-thread deferred operation.
pub const c = @cImport({
    @cInclude("session.h");
});
pub const Lease = struct {
    service: *c.struct_xsvc,
    client: u64,
    id: u64,
    pub fn capture(service: *c.struct_xsvc, client: u64) ?Lease {
        var state: c.struct_xsvc_state = undefined;
        if (c.xsvc_state(service, &state) != c.XSVC_OK or state.controller != client or state.lease_id == 0) return null;
        return .{ .service = service, .client = client, .id = state.lease_id };
    }
    pub fn valid(self: Lease, now: u64, scope: u32) bool {
        if (c.xsvc_tick(self.service, now, scope) != c.XSVC_OK or
            c.xsvc_authorize(self.service, self.client, c.XSVC_CONTROL, now) != c.XSVC_OK) return false;
        var state: c.struct_xsvc_state = undefined;
        return c.xsvc_state(self.service, &state) == c.XSVC_OK and state.lease_id == self.id;
    }
};
