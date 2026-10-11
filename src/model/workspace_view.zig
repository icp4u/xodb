//! Small workspace facts published by the session owner alongside pane data.
const std = @import("std");
const Session = @import("session.zig").Session;
pub const Header = struct {
    process: u64 = 0,
    scope: @import("session.zig").AgentScope = .observe,
    pending_continue: bool = false,
    running_to: bool = false,
    observation_available: bool = false,
    logical_frames_available: bool = false,
    metadata: ?@import("debug_metadata.zig").JobStatus = null,
    frame_failure: ?[]const u8 = null,
    frame_state: []const u8 = "",
    shared_clients: ?usize = null,
    shared_controller: ?u64 = null,
    fd_events: @import("system.zig").FdEventState = .inactive,
};
comptime {
    @import("debugger_view.zig").requireImmutable(Header);
}
pub fn signature(value: Header) u64 {
    var hash = std.hash.Wyhash.init(0);
    inline for (.{ "process", "scope", "pending_continue", "running_to", "observation_available", "logical_frames_available", "shared_clients", "shared_controller", "fd_events" }) |field| std.hash.autoHash(&hash, @field(value, field));
    hash.update(value.frame_failure orelse "");
    hash.update(value.frame_state);
    if (value.metadata) |job| {
        std.hash.autoHash(&hash, job.id);
        std.hash.autoHash(&hash, job.units);
        std.hash.autoHash(&hash, job.source_bytes);
        hash.update(job.state);
    }
    return hash.final();
}
pub fn capture(session: *Session) Header {
    const metadata = session.metadata.snapshot();
    const pending: ?@import("debug_metadata.zig").JobStatus = for (metadata.items[0..metadata.count]) |job| {
        if (!std.mem.eql(u8, job.state, "ready") and !std.mem.eql(u8, job.state, "failed") and !std.mem.eql(u8, job.state, "cancelled")) break job;
    } else null;
    return .{
        .process = session.process_id,
        .scope = session.agent_scope,
        .pending_continue = session.pending_continue != null,
        .running_to = session.run_to != null,
        .logical_frames_available = session.frames.count > 0 or session.frames.job != null or session.frames.attachment.failure != null,
        .observation_available = session.observations.capture != null or session.observation_archive != null,
        .metadata = pending,
        .frame_failure = if (session.frames.attachment.failure) |err| @errorName(err) else null,
        .frame_state = @tagName(session.frames.attachment.state),
    };
}

pub const Action = union(enum) {
    cancel_continue,
    run_to_source: struct { tid: i32, path: []const u8, line: u32 },
    toggle_source: struct { path: []const u8, line: u32 },
    watch_local: struct { tid: i32, frame: usize, metadata: u64, name: []const u8, address: u64 },
};
pub fn apply(a: std.mem.Allocator, session: *Session, action: Action) !void {
    switch (action) {
        .cancel_continue => {
            session.cancelStep();
            session.record(.human, "cancel_pending_continue");
        },
        .run_to_source => |source| {
            if (source.tid <= 0 or source.line == 0 or source.path.len == 0 or source.path.len > 4096) return error.InvalidArguments;
            const addresses = try session.sourceAddresses(a, source.path, source.line);
            if (addresses.len == 0) return error.NoCodeForSourceLine;
            try session.runTo(source.tid, addresses[0], null, .human);
            session.record(.human, "run_to");
        },
        .toggle_source => |source| {
            if (source.line == 0 or source.path.len == 0 or source.path.len > 4096) return error.InvalidArguments;
            const addresses = try session.sourceAddresses(a, source.path, source.line);
            var removed = false;
            for (addresses) |address| {
                for (session.target.breakpointSlice()) |probe| if (probe.address == address) {
                    if (@import("persistent.zig").Manager.probe(session, probe.id)) |entry| if (entry.internal) continue;
                    try session.target.removeBreakpoint(probe.id);
                    removed = true;
                    break;
                };
            }
            if (!removed) _ = try session.setSourceBreakpoint(a, source.path, source.line);
            session.record(.human, "toggle_source_breakpoint");
        },
        .watch_local => |local| {
            if (local.metadata != session.metadata.revision) return error.StaleDebugMetadata;
            if (local.tid <= 0 or local.frame >= 64 or local.name.len == 0 or local.name.len > 4096) return error.InvalidArguments;
            for (session.target.watchpointSlice()) |maybe| if (maybe) |watch| if (watch.address == local.address) {
                try session.target.removeWatchpoint(watch.id);
                session.record(.human, "remove_watchpoint");
                return;
            };
            _ = try session.investigateWrite(local.tid, local.frame, "Why did the selected value change?", local.name);
            session.record(.human, "investigate_write");
        },
    }
}
