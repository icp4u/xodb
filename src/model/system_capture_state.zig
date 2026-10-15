//! Bounded capture consent and publication. Requesting never grants control.
//! The owner clock drives expiry; readers cannot renew an approved deadline.
const std = @import("std");
const command = @import("command.zig");
pub const Caller = command.Caller;
pub const Mode = enum { unavailable, gui, headless };
pub const Kind = enum { cpu, fd_flow };
pub const Phase = enum { pending, approved, running, complete, denied, expired, revoked, failed };
pub const Spec = struct {
    kind: Kind,
    pid: i32 = 0,
    start_ticks: u64 = 0,
    duration_ms: u32 = 1000,
    frequency_hz: u32 = 99,
    interval_ms: u32 = 1000,
    pub fn validate(self: Spec) !void {
        if (self.duration_ms < 100 or self.duration_ms > 10_000) return error.InvalidCaptureDuration;
        switch (self.kind) {
            .cpu => if (self.pid <= 1 or self.start_ticks == 0 or self.frequency_hz == 0 or self.frequency_hz > 99) return error.InvalidCaptureProfile,
            .fd_flow => if (self.pid != 0 or self.start_ticks != 0 or (self.interval_ms != 250 and self.interval_ms != 1000)) return error.InvalidCaptureFlow,
        }
    }
};
pub const Record = struct {
    id: u64,
    spec: Spec,
    caller: Caller,
    phase: Phase,
    requested_ns: u64,
    approval_expires_ns: u64,
    started_ns: ?u64 = null,
    deadline_ns: ?u64 = null,
    ended_ns: ?u64 = null,
    reason: ?[]const u8 = null,
    pub fn active(self: Record) bool {
        return self.phase == .pending or self.phase == .approved or self.phase == .running;
    }
};
pub const Audit = struct { sequence: u64, request_id: u64, caller: Caller, spec: Spec, phase: Phase, at_ns: u64, reason: ?[]const u8 };
pub const State = struct {
    mode: Mode = .unavailable,
    current: ?Record = null,
    next_id: u64 = 1,
    last_request_ns: ?u64 = null,
    audit: [32]Audit = undefined,
    audit_count: usize = 0,
    sequence: u64 = 0,
    /// Held until backend cleanup, even after the public phase is terminal.
    backend_busy: bool = false,
    result_id: ?u64 = null,
    result_kind: ?Kind = null,
    /// Only this requester (or the human) reads the retained result.
    result_caller: ?Caller = null,
    /// A human denial holds off re-prompting so the dialog cannot be spammed.
    denied_until_ns: u64 = 0,
    pub fn ownsFlow(self: *const State) bool {
        return self.backend_busy and self.current != null and self.current.?.spec.kind == .fd_flow;
    }
    pub fn submit(self: *State, caller: Caller, scope: command.AgentScope, spec: Spec, now: u64) !u64 {
        if (self.mode == .unavailable) return error.CaptureRequestsUnavailable;
        if (caller != .agent) return error.AgentRequestRequired;
        if (self.mode == .headless and scope == .observe) return error.AgentScopeDenied;
        try spec.validate();
        if (self.backend_busy or (self.current != null and self.current.?.active())) return error.CaptureRequestBusy;
        if (self.last_request_ns) |last| if (now -| last < std.time.ns_per_s) return error.CaptureRequestRateLimited;
        if (now < self.denied_until_ns) return error.CaptureRequestRateLimited;
        const id = self.next_id;
        self.next_id +|= 1;
        self.last_request_ns = now;
        self.current = .{ .id = id, .spec = spec, .caller = caller, .phase = .pending, .requested_ns = now, .approval_expires_ns = now +| 30 * std.time.ns_per_s };
        self.record(caller, now);
        if (self.mode == .headless) self.transition(.approved, caller, "headless_scope_policy", now);
        return id;
    }
    pub fn approve(self: *State, id: u64, now: u64) !void {
        const r = self.current orelse return error.UnknownCaptureRequest;
        if (r.id != id or r.phase != .pending or self.mode != .gui) return error.CaptureApprovalUnavailable;
        if (now >= r.approval_expires_ns) {
            self.transition(.expired, .human, "approval_timeout", now);
            return error.CaptureApprovalExpired;
        }
        self.transition(.approved, .human, "human_confirmation", now);
    }
    pub fn cancel(self: *State, caller: Caller, id: u64, now: u64) !void {
        const r = self.current orelse return error.UnknownCaptureRequest;
        if (r.id != id) return error.UnknownCaptureRequest;
        if (caller == .agent and (r.caller != .agent or caller.agent.client != r.caller.agent.client)) return error.CaptureRequesterRequired;
        if (!r.active()) return;
        if (caller == .human and r.phase == .pending) self.denied_until_ns = now +| 5 * std.time.ns_per_s;
        self.transition(if (r.phase == .pending) .denied else .revoked, caller, "cancelled", now);
    }
    pub fn readable(self: *const State, caller: Caller, id: u64) !void {
        if (self.result_id != id) return error.CaptureResultUnavailable;
        const owner = self.result_caller orelse return error.CaptureResultUnavailable;
        if (caller == .agent and (owner != .agent or owner.agent.client != caller.agent.client)) return error.CaptureRequesterRequired;
    }
    pub fn check(self: *State, scope: command.AgentScope, requester_present: bool, now: u64) void {
        const r = self.current orelse return;
        if (!r.active()) return;
        if (!requester_present) return self.transition(.revoked, r.caller, "requester_disconnected", now);
        if (self.mode == .headless and scope == .observe) return self.transition(.revoked, .human, "scope_revoked", now);
        if (r.phase == .pending and now >= r.approval_expires_ns) return self.transition(.expired, r.caller, "approval_timeout", now);
        if (r.deadline_ns) |deadline| if (now >= deadline) self.transition(.complete, r.caller, "duration", now);
    }
    pub fn started(self: *State, now: u64) void {
        const r = self.current orelse return;
        if (r.phase != .approved) return;
        self.current.?.started_ns = now;
        self.current.?.deadline_ns = now +| @as(u64, r.spec.duration_ms) * std.time.ns_per_ms;
        self.backend_busy = true;
        self.transition(.running, r.caller, null, now);
    }
    pub fn finish(self: *State, phase: Phase, reason: ?[]const u8, now: u64) void {
        const r = self.current orelse return;
        self.transition(phase, r.caller, reason, now);
    }
    fn transition(self: *State, phase: Phase, caller: Caller, reason: ?[]const u8, now: u64) void {
        if (self.current) |*r| {
            r.phase = phase;
            r.reason = reason;
            if (!r.active()) r.ended_ns = now;
            self.record(caller, now);
        }
    }
    fn record(self: *State, caller: Caller, now: u64) void {
        if (self.audit_count == self.audit.len) {
            std.mem.copyForwards(Audit, self.audit[0 .. self.audit.len - 1], self.audit[1..]);
            self.audit_count -= 1;
        }
        const r = self.current.?;
        self.sequence +|= 1;
        self.audit[self.audit_count] = .{ .sequence = self.sequence, .request_id = r.id, .caller = caller, .spec = r.spec, .phase = r.phase, .at_ns = now, .reason = r.reason };
        self.audit_count += 1;
    }
};

test "GUI capture request is not consent, approval expires, cancellation is attributable" {
    const t = std.testing;
    const caller: Caller = .{ .agent = .{ .client = 7, .lease = null } };
    var state: State = .{ .mode = .gui };
    const id = try state.submit(caller, .observe, .{ .kind = .fd_flow }, 1);
    try t.expectEqual(Phase.pending, state.current.?.phase);
    try t.expect(!state.backend_busy);
    try t.expectError(error.CaptureRequesterRequired, state.cancel(.{ .agent = .{ .client = 8, .lease = null } }, id, 2));
    try state.approve(id, 3);
    state.started(4);
    state.check(.observe, true, 5); // Human consent is not general debugger scope.
    try t.expectEqual(Phase.running, state.current.?.phase);
    try state.cancel(.human, id, 6);
    try t.expectEqual(Phase.revoked, state.current.?.phase);
    try t.expectEqual(@as(u64, 0), state.denied_until_ns); // revoking a running capture is not a denial
    try t.expect(state.backend_busy); // Owner must still close the backend.
    try t.expect(state.audit[state.audit_count - 1].caller == .human);
    state.backend_busy = false;
    const second = try state.submit(caller, .observe, .{ .kind = .fd_flow }, 2 * std.time.ns_per_s);
    try t.expectError(error.CaptureApprovalExpired, state.approve(second, 32 * std.time.ns_per_s));
    const third = try state.submit(caller, .observe, .{ .kind = .fd_flow }, 40 * std.time.ns_per_s);
    try state.cancel(.human, third, 41 * std.time.ns_per_s);
    try t.expectEqual(Phase.denied, state.current.?.phase);
    try t.expectError(error.CaptureRequestRateLimited, state.submit(caller, .observe, .{ .kind = .fd_flow }, 45 * std.time.ns_per_s));
    _ = try state.submit(caller, .observe, .{ .kind = .fd_flow }, 46 * std.time.ns_per_s);
    try t.expect(state.audit[state.audit_count - 1].spec.kind == .fd_flow);
    state.result_id = third;
    state.result_caller = caller;
    try state.readable(caller, third);
    try state.readable(.human, third);
    try t.expectError(error.CaptureRequesterRequired, state.readable(.{ .agent = .{ .client = 8, .lease = null } }, third));
    try t.expectError(error.CaptureResultUnavailable, state.readable(caller, third + 1));
}

test "headless scope, owner deadlines, request caps and disconnect do not depend on polling" {
    const t = std.testing;
    const caller: Caller = .{ .agent = .{ .client = 0, .lease = null } };
    var state: State = .{ .mode = .headless };
    const spec: Spec = .{ .kind = .cpu, .pid = 7, .start_ticks = 9, .duration_ms = 100 };
    try t.expectError(error.AgentScopeDenied, state.submit(caller, .observe, spec, 0));
    _ = try state.submit(caller, .control, spec, 0);
    try t.expectEqual(Phase.approved, state.current.?.phase);
    state.started(1);
    const deadline = state.current.?.deadline_ns.?;
    state.check(.control, true, deadline - 1);
    try t.expectEqual(Phase.running, state.current.?.phase);
    state.check(.control, true, deadline);
    try t.expectEqual(Phase.complete, state.current.?.phase);
    state.backend_busy = false;
    try t.expectError(error.CaptureRequestRateLimited, state.submit(caller, .control, spec, deadline));
    _ = try state.submit(caller, .control, spec, std.time.ns_per_s);
    state.check(.control, false, std.time.ns_per_s + 1);
    try t.expectEqual(Phase.revoked, state.current.?.phase);
    try t.expectError(error.InvalidCaptureDuration, (Spec{ .kind = .fd_flow, .duration_ms = 10_001 }).validate());
    try t.expectError(error.InvalidCaptureProfile, (Spec{ .kind = .cpu, .pid = 7, .start_ticks = 9, .frequency_hz = 100 }).validate());
    try t.expectError(error.InvalidCaptureFlow, (Spec{ .kind = .fd_flow, .interval_ms = 1 }).validate());
}

test "scope revocation and audit retention are bounded; a pending request keeps previous evidence" {
    const t = std.testing;
    const caller: Caller = .{ .agent = .{ .client = 7, .lease = null } };
    var state: State = .{ .mode = .headless, .result_id = 42, .result_kind = .cpu };
    for (0..40) |i| {
        const now = @as(u64, @intCast(i)) * std.time.ns_per_s;
        _ = try state.submit(caller, .control, .{ .kind = .fd_flow }, now);
        state.check(.observe, true, now + 1);
        try t.expectEqual(Phase.revoked, state.current.?.phase);
    }
    try t.expectEqual(32, state.audit_count);
    try t.expect(state.audit[0].sequence > 1);
    state.mode = .gui;
    _ = try state.submit(caller, .observe, .{ .kind = .fd_flow }, 41 * std.time.ns_per_s);
    try t.expectEqual(Phase.pending, state.current.?.phase);
    try t.expectEqual(@as(?u64, 42), state.result_id);
}
