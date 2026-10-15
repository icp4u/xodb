//! Transport-independent command values. No live handle or frontend type.
pub const AgentScope = enum { observe, control, mutate };
pub const Actor = enum { human, agent };
pub const Effect = enum { execution, mutation };
pub const Caller = union(enum) {
    human,
    agent: struct { client: u64, lease: ?u64 },
};
pub const Stamp = struct {
    connection: u64,
    session: u64,
    process: u64,
    pid: i32,
    start_ticks: ?u64 = null,
    image_epoch: u64,
    generation: u64,
    pub fn sameProcess(a: Stamp, b: Stamp) bool {
        return a.connection == b.connection and a.session == b.session and
            a.process == b.process and a.pid == b.pid and
            (a.start_ticks == null or b.start_ticks == null or a.start_ticks == b.start_ticks);
    }
};
pub const Selection = struct { tid: i32, frame: usize = 0 };
pub const Source = struct { path: []const u8, line: u32 };
pub const Control = union(enum) {
    interrupt,
    continue_execution,
    cancel_continue,
    step_instruction: i32,
    step_over_instruction: i32,
    step_source: struct { tid: i32, over: bool },
    finish_frame: Selection,
    run_to: struct { tid: i32, address: u64 },
    run_to_source: struct { tid: i32, path: []const u8, line: u32 },
    restart,
    detach,
    follow_processes: struct { enabled: bool, limit: ?usize },
};
pub const Policy = struct {
    id: u64,
    enabled: bool = true,
    condition: []const u8 = "",
    log_expression: []const u8 = "",
    tid: ?i32 = null,
    /// Stable thread identity retained by the GUI's existing policy editor.
    thread_id: ?u64 = null,
    ignore_count: u64 = 0,
    mode: enum { stop, log } = .stop,
};
pub const Breakpoint = union(enum) {
    address: u64,
    source: Source,
    symbol: []const u8,
    toggle_source: Source,
    remove: u64,
    enabled: struct { id: u64, enabled: bool },
    policy: Policy,
};
pub const Operation = union(enum) {
    control: Control,
    breakpoint: Breakpoint,
    pub fn needsObservation(self: Operation) bool {
        return !(self == .control and (self.control == .interrupt or self.control == .cancel_continue));
    }
    pub fn effect(_: Operation) Effect {
        return .execution;
    }
};
pub const Request = struct { stamp: Stamp, caller: Caller, operation: Operation };

test "interrupt and cancellation do not depend on the displayed observation" {
    const testing = @import("std").testing;
    try testing.expect(!(Operation{ .control = .interrupt }).needsObservation());
    try testing.expect(!(Operation{ .control = .cancel_continue }).needsObservation());
    try testing.expect((Operation{ .control = .continue_execution }).needsObservation());
    try testing.expect((Operation{ .breakpoint = .{ .address = 1 } }).needsObservation());
}
