//! `xodb --overview --headless` options. The composition root (main.zig)
//! runs the overview's collector cache and its observer-only MCP endpoints
//! with no window, Vulkan or compositor: same tools, cache and pending/age
//! semantics as the window, and the owner keeps the history groups sampled
//! so get_history has series without a view.
const std = @import("std");
const log = @import("../log.zig");
const c = @import("../c_ui.zig").api;

pub const usage =
    \\xodb --overview --headless (--mcp | --session-socket PATH) [--agent-scope SCOPE] [--interval-ms N] [--redact] [--graph-pid N]...
    \\  The system overview's collector and observer-only MCP tools without a window:
    \\  no display, Vulkan or compositor. Exits when stdin closes (--mcp) or on a signal.
    \\  --mcp                  serve MCP on stdin/stdout
    \\  --agent-scope SCOPE    observe (default), control or mutate; control permits bounded capture requests
    \\  --session-socket PATH  share the cache with local MCP peers
    \\  --interval-ms N        owner sampling interval, 250..10000 (default 500); processes at 1 Hz
    \\  --redact               every reply redacted
    \\  --graph-pid N          restrict descriptor collection to these PIDs (repeatable)
    \\
;

pub const Options = struct {
    mcp: bool = false,
    session_socket: ?[:0]const u8 = null,
    interval_ms: u64 = 500,
    redact: bool = false,
    agent_scope: @import("../model/command.zig").AgentScope = .observe,
    graph_pids: [c.XRT_FD_INTEREST_MAX]i32 = @splat(0),
    graph_count: usize = 0,
};

pub fn parse(args: []const [:0]const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--overview") or std.mem.eql(u8, arg, "--headless")) continue;
        if (std.mem.eql(u8, arg, "--mcp")) {
            o.mcp = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redact")) {
            o.redact = true;
            continue;
        }
        const takes = std.mem.eql(u8, arg, "--session-socket") or std.mem.eql(u8, arg, "--interval-ms") or std.mem.eql(u8, arg, "--graph-pid") or std.mem.eql(u8, arg, "--agent-scope");
        if (!takes) {
            log.err(.overview, "xodb: --overview --headless does not accept {s}\n{s}", .{ arg, usage });
            return error.OverviewOptionConflict;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--agent-scope")) o.agent_scope = std.meta.stringToEnum(@import("../model/command.zig").AgentScope, value) orelse return error.InvalidAgentScope;
        if (std.mem.eql(u8, arg, "--session-socket")) o.session_socket = value;
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            o.interval_ms = std.fmt.parseInt(u64, value, 10) catch return error.InvalidOverviewInterval;
            if (o.interval_ms < 250 or o.interval_ms > 10_000) return error.InvalidOverviewInterval;
        }
        if (std.mem.eql(u8, arg, "--graph-pid")) {
            const pid = std.fmt.parseInt(i32, value, 10) catch return error.InvalidGraphScope;
            if (pid <= 0 or o.graph_count == o.graph_pids.len) return error.InvalidGraphScope;
            if (std.mem.indexOfScalar(i32, o.graph_pids[0..o.graph_count], pid) == null) {
                o.graph_pids[o.graph_count] = pid;
                o.graph_count += 1;
            }
        }
    }
    if (!o.mcp and o.session_socket == null) {
        log.err(.overview, "xodb: --overview --headless needs --mcp or --session-socket\n{s}", .{usage});
        return error.HeadlessOverviewNeedsClient;
    }
    return o;
}

test "headless overview options need a client and refuse window options" {
    const ok = try parse(&.{ "xodb", "--overview", "--headless", "--mcp", "--interval-ms", "250", "--graph-pid", "7" });
    try std.testing.expect(ok.mcp and ok.interval_ms == 250 and ok.graph_count == 1);
    try std.testing.expectError(error.HeadlessOverviewNeedsClient, parse(&.{ "xodb", "--overview", "--headless" }));
    try std.testing.expectError(error.OverviewOptionConflict, parse(&.{ "xodb", "--overview", "--headless", "--mcp", "--panel", "processes" }));
    try std.testing.expectError(error.InvalidOverviewInterval, parse(&.{ "xodb", "--overview", "--headless", "--mcp", "--interval-ms", "10" }));
}
