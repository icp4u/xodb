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
    \\  --kernel-pid N         restrict the opt-in get_kernel_stacks census to one process
    \\  --radio IFACE          burrito mode: take this spare card (or up to four, comma-separated) for spectrum
    \\                         (root, receive-only); the cards sweep the band
    \\  --radio-traffic IFACE  count frames per channel on this spare card (root, receive-only, counts only)
    \\  --radio-channel N      one fixed window on channel N, 1..14, instead of the sweep
    \\  --radio-focus LO-HI    sweep only LO-HI MHz
    \\  --radio-hop            sweep the band (the default)
    \\  --radio-ping           ping the in-use link's gateway at 50 Hz (the one thing xodb sends; off by default)
    \\  --radio-demo SCENE     SYNTHETIC spectrum and traffic for demos and tests (kitchen, microwave60, inverter, ...)
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
    kernel_pid: ?i32 = null,
    radio: ?[:0]const u8 = null,
    radio_traffic: ?[:0]const u8 = null,
    radio_channel: ?u8 = null,
    radio_focus: ?@import("../radio/sweep.zig").Request = null,
    radio_hop: bool = false,
    radio_ping: bool = false,
    radio_demo: ?@import("../radio/detect.zig").Synth.Scene = null,
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
        if (std.mem.eql(u8, arg, "--radio-hop")) {
            o.radio_hop = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--radio-ping")) {
            o.radio_ping = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redact")) {
            o.redact = true;
            continue;
        }
        const takes = std.mem.eql(u8, arg, "--session-socket") or std.mem.eql(u8, arg, "--interval-ms") or std.mem.eql(u8, arg, "--graph-pid") or std.mem.eql(u8, arg, "--agent-scope") or std.mem.eql(u8, arg, "--radio") or std.mem.eql(u8, arg, "--radio-channel") or std.mem.eql(u8, arg, "--radio-demo") or std.mem.eql(u8, arg, "--radio-traffic") or std.mem.eql(u8, arg, "--radio-focus");
        if (!takes and !std.mem.eql(u8, arg, "--kernel-pid")) {
            log.err(.overview, "xodb: --overview --headless does not accept {s}\n{s}", .{ arg, usage });
            return error.OverviewOptionConflict;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--kernel-pid")) {
            o.kernel_pid = std.fmt.parseInt(i32, value, 10) catch return error.InvalidKernelPid;
            if (o.kernel_pid.? <= 0) return error.InvalidKernelPid;
        }
        if (std.mem.eql(u8, arg, "--agent-scope")) o.agent_scope = std.meta.stringToEnum(@import("../model/command.zig").AgentScope, value) orelse return error.InvalidAgentScope;
        if (std.mem.eql(u8, arg, "--session-socket")) o.session_socket = value;
        if (std.mem.eql(u8, arg, "--radio")) o.radio = value;
        if (std.mem.eql(u8, arg, "--radio-traffic")) o.radio_traffic = value;
        if (std.mem.eql(u8, arg, "--radio-focus")) o.radio_focus = @import("../radio/burrito.zig").parseFocus(value) orelse return error.InvalidRadioFocus;
        if (std.mem.eql(u8, arg, "--radio-demo")) o.radio_demo = std.meta.stringToEnum(@import("../radio/detect.zig").Synth.Scene, value) orelse return error.InvalidRadioDemo;
        if (std.mem.eql(u8, arg, "--radio-channel")) {
            const ch = std.fmt.parseInt(u8, value, 10) catch return error.InvalidRadioChannel;
            if (ch < 1 or ch > 14) return error.InvalidRadioChannel;
            o.radio_channel = ch;
        }
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
