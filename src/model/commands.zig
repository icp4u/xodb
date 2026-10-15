//! Owner-thread command semantics shared by synchronous and queued adapters.
//! Session is supplied by its owner, like the persistent/probe managers; the
//! executor imports no Session, frontend, protocol or publication machinery.
const std = @import("std");
const A = std.mem.Allocator;
const api = @import("command.zig");
const authority = @import("../service/authority.zig");
const leases = @import("../service/lease.zig");
pub const Result = struct { ids: []const u64 = &.{}, pending: bool = false };

pub fn execute(a: A, session: anytype, connection: u64, service: ?*authority.c.struct_xsvc, request: api.Request, now: u64) !Result {
    if (!request.stamp.sameProcess(stamp(connection, session))) return error.StaleProcess;
    var caller: authority.Caller = .{ .actor = if (request.caller == .human) .human else .agent };
    if (request.caller == .agent) {
        const agent = request.caller.agent;
        if (service) |shared| {
            const root = if (session.process_tree) |tree| tree.root() else session;
            try authority.check(authority.c.xsvc_tick(shared, now, @intFromEnum(root.agent_scope)));
            try authority.check(authority.c.xsvc_authorize(shared, agent.client, authority.c.XSVC_OBSERVE, now));
            try authority.authorize(shared, agent.client, request.operation.effect() == .mutation, now);
            const lease = leases.Lease.capture(shared, agent.client) orelse return error.ControlLeaseRequired;
            if (agent.lease != lease.id) return error.ControlLeaseRequired;
            caller.client = agent.client;
            caller.lease = lease;
        } else if (agent.client != 0 or agent.lease != null) return error.UnknownSessionClient;
    }
    const current = session.target.snapshot();
    if (request.operation.needsObservation() and request.stamp.image_epoch != current.image_epoch) return error.StaleSnapshot;
    // Old-view interrupt/cancellation still checks identity and live authority,
    // but does not require the stop that happened to be painted by the caller.
    try session.authorize(caller.actor, request.operation.effect(), if (request.operation.needsObservation()) request.stamp.generation else current.generation);
    if (session.offline) return error.OfflineSession;
    // A rejected command must not adopt an earlier operation's later resumes.
    const prior_actor = session.probe_resume_actor;
    const prior_lease = session.probe_resume_lease;
    errdefer {
        session.probe_resume_actor = prior_actor;
        session.probe_resume_lease = prior_lease;
    }
    var result: Result = .{};
    const action: []const u8 = switch (request.operation) {
        .control => |control| switch (control) {
            .interrupt => blk: {
                session.cancelStep();
                try session.target.interrupt();
                break :blk "interrupt";
            },
            .cancel_continue => blk: {
                session.cancelStep();
                // Supersede already queued resumes from the cancelled view,
                // including human requests (whose audit does not bump it).
                try session.target.invalidate();
                break :blk "cancel_pending_continue";
            },
            .continue_execution => blk: {
                try session.continueAs(caller);
                break :blk "continue";
            },
            .step_instruction, .step_over_instruction => |tid| blk: {
                if (tid <= 0) return error.InvalidArguments;
                session.probe_resume_actor = caller.actor;
                session.probe_resume_lease = caller.lease;
                if (control == .step_instruction) try session.stepInstruction(tid) else try session.stepOverInstruction(tid);
                break :blk if (control == .step_instruction) "step_instruction" else "step_over_instruction";
            },
            .step_source => |step| blk: {
                if (step.tid <= 0) return error.InvalidArguments;
                session.probe_resume_actor = caller.actor;
                session.probe_resume_lease = caller.lease;
                try session.startSourceStep(step.tid, step.over);
                break :blk if (step.over) "step_over" else "step_source";
            },
            .finish_frame => |selection| blk: {
                if (selection.tid <= 0) return error.InvalidArguments;
                try session.finishAs(selection.tid, selection.frame, caller);
                break :blk "finish";
            },
            .run_to => |run| blk: {
                if (run.tid <= 0) return error.InvalidArguments;
                try session.runToAs(run.tid, run.address, null, caller);
                break :blk "run_to";
            },
            .run_to_source => |run| blk: {
                if (run.tid <= 0) return error.InvalidArguments;
                try sourceValid(.{ .path = run.path, .line = run.line });
                const addresses = try session.sourceAddresses(a, run.path, run.line);
                if (addresses.len == 0) return error.NoSourceAddress;
                try session.runToAs(run.tid, addresses[0], null, caller);
                break :blk "run_to";
            },
            .restart => blk: {
                try session.restart();
                break :blk "restart";
            },
            .detach => blk: {
                session.cancelStep();
                try session.detach();
                break :blk "detach";
            },
            .follow_processes => |follow| {
                const tree = session.process_tree orelse return error.UnknownProcess;
                try tree.setFollowing(session, follow.enabled, follow.limit, caller.actor);
                return result;
            },
        },
        .breakpoint => |bp| switch (bp) {
            .address => |address| blk: {
                const ids = try a.alloc(u64, 1);
                ids[0] = try session.target.setBreakpoint(address, false);
                result.ids = ids;
                break :blk "set_breakpoint";
            },
            .source => |source| blk: {
                try sourceValid(source);
                result.ids = try session.setSourceBreakpoint(a, source.path, source.line);
                break :blk "set_breakpoint";
            },
            .symbol => |symbol| blk: {
                const ids = try a.alloc(u64, 1);
                ids[0] = try session.breakSymbol(symbol);
                result.ids = ids;
                result.pending = if (session.breakpoint(ids[0])) |probe| probe.pending else false;
                break :blk "set_breakpoint";
            },
            .toggle_source => |source| blk: {
                try sourceValid(source);
                const addresses = try session.sourceAddresses(a, source.path, source.line);
                var removed = false;
                for (addresses) |address| {
                    for (session.target.breakpointSlice()) |probe| if (probe.address == address) {
                        if (probe.internal) continue;
                        try session.target.removeBreakpoint(probe.id);
                        removed = true;
                        break;
                    };
                }
                if (!removed) result.ids = try session.setSourceBreakpoint(a, source.path, source.line);
                break :blk "toggle_source_breakpoint";
            },
            .remove => |id| blk: {
                try publicBreakpoint(session, id);
                try session.target.removeBreakpoint(id);
                break :blk "remove_breakpoint";
            },
            .enabled => |change| blk: {
                try publicBreakpoint(session, change.id);
                try session.target.enableBreakpoint(change.id, change.enabled);
                break :blk "configure_breakpoint";
            },
            .policy => |policy| blk: {
                try publicBreakpoint(session, policy.id);
                var options: @import("probes.zig").Options = .{ .condition = policy.condition, .log_expression = policy.log_expression, .ignore_count = policy.ignore_count, .mode = std.meta.stringToEnum(@FieldType(@import("probes.zig").Options, "mode"), @tagName(policy.mode)).? };
                if (policy.tid) |tid| {
                    for (session.target.threadSlice()) |thread| {
                        if (thread.tid == tid and thread.state != .exited) {
                            options.thread_id = thread.id;
                            break;
                        }
                    } else return error.UnknownThread;
                }
                if (policy.tid == null) options.thread_id = policy.thread_id;
                try session.probes.configure(&session.target, policy.id, options, policy.enabled);
                break :blk "configure_breakpoint";
            },
        },
    };
    session.recordAs(caller, action);
    return result;
}
fn sourceValid(source: api.Source) !void {
    if (source.line == 0 or source.path.len == 0 or source.path.len > 4096) return error.InvalidArguments;
}
pub fn stamp(connection: u64, session: anytype) api.Stamp {
    const state = session.target.snapshot();
    return .{ .connection = connection, .session = session.id, .process = session.process_id, .pid = state.pid, .image_epoch = state.image_epoch, .generation = state.generation };
}
fn publicBreakpoint(session: anytype, id: u64) !void {
    if (session.breakpoint(id)) |probe| if (probe.internal) return error.InternalBreakpoint;
}
