//! `xodb --overview` options, for every entry that opens the overview.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const themes = @import("theme.zig");
const vw = @import("view.zig");

pub const usage =
    \\xodb --overview [--replay FILE] [--redact] [--theme NAME] [--panel NAME] [--interval-ms N] [--pause] [--frames N] [--font FILE]
    \\               [--ui-scale N] [--config FILE]
    \\               [--look win95|win9x|dos|modern|deep|gibson] [--memmap-pid N [--memmap-start-ticks N]]
    \\  A system overview window with no debug target: CPU, memory, disks, network,
    \\  connections, sensors, processes, users, services and packages. Unmeasured values
    \\  show their reason; nothing unmeasured is drawn as zero.
    \\  --attach-exe    open the process picker with an editable .exe search filter
    \\  --replay FILE   collector JSON (one snapshot, or one per line) instead of the live system
    \\  --redact        hide hostname, users, addresses, mount points and command arguments
    \\  --theme NAME    dark, light, green, amber, blue, mono or win95 (builtin: prefix accepted)
    \\  --ui-scale N   device pixels per UI unit, 0.5..4 (otherwise config or compositor)
    \\  --config FILE  load UI scale and galaxy look from provisional JSON preferences
    \\  --panel NAME    start on summary, performance, processes, memory, disk, disk_space,
    \\                  network, connections, power, system, users, services, apps, files, memory_map, graph, galaxy, inheritance, treemap or fetch
    \\  Graph/galaxy/treemap starts LIVE SYSCALL TRACING · ~11% host syscall overhead · E to stop
    \\  --graph-pid N   restrict descriptor collection and captured threads to these PIDs (repeatable)
    \\  --files-pid N   start Files & IO scoped to one process; its first observed start is pinned
    \\  --files-start-ticks N  require this exact identity with --files-pid
    \\  --look NAME     win95: whole overview skin; memory map: win9x (Disk Defragmenter), dos (MS-DOS DEFRAG), modern, deep (zoomable), gibson (3D city)
    \\  --gibson-flight start the memory city in street-level auto-flight (F returns)
    \\  --gibson-film  start auto-flight with the faster film preset (V toggles speed)
    \\  --memmap-pid N  start on the Memory map of one process; --memmap-start-ticks pins its start
    \\  --interval-ms N sampling interval, 250..10000 (live default 500; processes refresh
    \\                  at 1 Hz; process IO/fd detail is collected by panes that show it)
    \\  --session-socket PATH  share this live cache with observer-only MCP clients
    \\  --mcp           serve observer-only MCP on stdin/stdout alongside the live view; exits when stdin closes
    \\  --headless      no window: collector and MCP only (with --mcp and/or --session-socket; xodb --overview --headless --help)
    \\  --galaxy-demo N[:idle]  FD Galaxy with N synthetic processes (1-1024); reads and traces nothing
    \\  --galaxy-tour   start the galaxy's explicit camera tour (O stops; any control takes over)
    \\  --pause         start paused (replay: show the last frame with full history)
    \\  --vk-device X   Vulkan device by its `xodb --vk-list` index or part of its name (also XODB_VK_DEVICE)
    \\  -q, -qq, -v, -vv, --log=LEVEL|TOPIC=LEVEL[,...] and --log-file FILE choose what is logged (xodb --help).
    \\Keys: 1-9 0 Tab panels, arrows, / search, s sort, r reverse, v tree, L files, M memory map, F profile, Enter debugger (all confirmed),
    \\      B treemap, N xodbfetch (B there runs benchmarks), t theme, p pause, x redact (cannot be turned off), q quit. Mouse: click and wheel.
    \\
;

pub const Options = struct {
    attach_exe: bool = false,
    replay: ?[:0]const u8 = null,
    session_socket: ?[:0]const u8 = null,
    mcp: bool = false,
    redact: bool = false,
    theme: ?[]const u8 = null,
    config: ?[:0]const u8 = null,
    ui_scale: ?f32 = null,
    panel: ?vw.Panel = null,
    files_pid: ?i32 = null,
    files_start: u64 = 0,
    graph_pids: [c.XRT_FD_INTEREST_MAX]i32 = @splat(0),
    graph_count: usize = 0,
    galaxy_demo: u32 = 0,
    galaxy_demo_idle: bool = false,
    galaxy_tour: bool = false,
    look: ?vw.memmap.Look = null,
    gibson_flight: bool = false,
    gibson_film: bool = false,
    memmap_pid: ?i32 = null,
    memmap_start: u64 = 0,
    interval_ms: ?u64 = null,
    paused: bool = false,
    frames: u64 = 0,
    font: [:0]const u8 = @import("build_options").font_path ++ "",
};

/// The overview options that are followed by a value.
pub const takes = [_][]const u8{ "--replay", "--theme", "--panel", "--interval-ms", "--frames", "--font", "--ui-scale", "--session-socket", "--files-pid", "--files-start-ticks", "--look", "--memmap-pid", "--memmap-start-ticks", "--graph-pid", "--galaxy-demo", "--vk-device", "--config" };

/// Parses overview arguments (args[0] is the program). Debugger options are
/// rejected: the overview has no target.
pub fn parse(args: []const [:0]const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--overview")) continue;
        if (std.mem.eql(u8, arg, "--galaxy-tour")) {
            o.galaxy_tour = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gibson-flight")) {
            o.gibson_flight = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--gibson-film")) {
            o.gibson_flight = true;
            o.gibson_film = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--attach-exe")) {
            o.attach_exe = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redact")) {
            o.redact = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--mcp")) {
            o.mcp = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--pause")) {
            o.paused = true;
            continue;
        }
        var known = false;
        for (takes) |t| known = known or std.mem.eql(u8, arg, t);
        if (!known) {
            std.debug.print("xodb: --overview does not accept {s}\n{s}", .{ arg, usage });
            return error.OverviewOptionConflict;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--config")) o.config = value;
        if (std.mem.eql(u8, arg, "--ui-scale")) {
            const scale = std.fmt.parseFloat(f32, value) catch return error.InvalidUiScale;
            o.ui_scale = try @import("../../platform/window.zig").validateScale(scale);
        }
        if (std.mem.eql(u8, arg, "--replay")) o.replay = value;
        if (std.mem.eql(u8, arg, "--session-socket")) o.session_socket = value;
        if (std.mem.eql(u8, arg, "--theme")) {
            _ = themes.find(value) orelse return error.UnknownOverviewTheme;
            o.theme = value;
        }
        if (std.mem.eql(u8, arg, "--panel")) o.panel = std.meta.stringToEnum(vw.Panel, value) orelse return error.UnknownOverviewPanel;
        if (std.mem.eql(u8, arg, "--graph-pid")) {
            const pid = try std.fmt.parseInt(i32, value, 10);
            if (pid <= 0 or o.graph_count == o.graph_pids.len) return error.InvalidGraphScope;
            if (std.mem.indexOfScalar(i32, o.graph_pids[0..o.graph_count], pid) == null) {
                o.graph_pids[o.graph_count] = pid;
                o.graph_count += 1;
            }
        }
        if (std.mem.eql(u8, arg, "--galaxy-demo")) {
            const idle = std.mem.endsWith(u8, value, ":idle");
            o.galaxy_demo = std.fmt.parseInt(u32, value[0 .. value.len - if (idle) @as(usize, 5) else 0], 10) catch return error.InvalidGalaxyDemo;
            if (o.galaxy_demo == 0 or o.galaxy_demo > 1024) return error.InvalidGalaxyDemo;
            o.galaxy_demo_idle = idle;
        }
        if (std.mem.eql(u8, arg, "--files-pid")) {
            const pid = try std.fmt.parseInt(i32, value, 10);
            if (pid <= 0) return error.InvalidFilesIdentity;
            o.files_pid = pid;
        }
        if (std.mem.eql(u8, arg, "--files-start-ticks")) {
            o.files_start = try std.fmt.parseInt(u64, value, 10);
            if (o.files_start == 0) return error.InvalidFilesIdentity;
        }
        if (std.mem.eql(u8, arg, "--look")) {
            if (std.mem.eql(u8, value, "win95")) o.theme = "win95" else o.look = std.meta.stringToEnum(vw.memmap.Look, value) orelse return error.UnknownMemoryMapLook;
        }
        if (std.mem.eql(u8, arg, "--memmap-pid")) {
            const pid = try std.fmt.parseInt(i32, value, 10);
            if (pid <= 0) return error.InvalidMemoryMapIdentity;
            o.memmap_pid = pid;
        }
        if (std.mem.eql(u8, arg, "--memmap-start-ticks")) {
            o.memmap_start = try std.fmt.parseInt(u64, value, 10);
            if (o.memmap_start == 0) return error.InvalidMemoryMapIdentity;
        }
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            const ms = try std.fmt.parseInt(u64, value, 10);
            if (ms < 250 or ms > 10_000) return error.InvalidOverviewInterval;
            o.interval_ms = ms;
        }
        if (std.mem.eql(u8, arg, "--frames")) o.frames = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, arg, "--font")) o.font = value;
    }
    if (o.replay != null and (o.mcp or o.session_socket != null)) return error.ReplayHasNoLiveSession;
    if (o.files_start != 0 and o.files_pid == null) return error.InvalidFilesIdentity;
    if (o.memmap_start != 0 and o.memmap_pid == null) return error.InvalidMemoryMapIdentity;
    if (o.memmap_pid != null) {
        if (o.replay != null or o.files_pid != null or (o.panel != null and o.panel.? != .memory_map)) return error.InvalidMemoryMapIdentity;
        o.panel = .memory_map;
    }
    if (o.files_pid != null) {
        if (o.replay != null or (o.panel != null and o.panel.? != .files)) return error.InvalidFilesIdentity;
        o.panel = .files;
    }
    if (o.galaxy_demo != 0) {
        if (o.graph_count > 0 or (o.panel != null and o.panel.? != .galaxy)) return error.InvalidGalaxyDemo;
        o.panel = .galaxy;
    }
    if (o.galaxy_tour) {
        if (o.panel != null and o.panel.? != .galaxy) return error.InvalidGalaxyTour;
        o.panel = .galaxy;
    }
    if (o.graph_count > 0) {
        if (o.replay != null or (o.panel != null and o.panel.? != .graph and o.panel.? != .galaxy and o.panel.? != .inheritance and o.panel.? != .treemap)) return error.InvalidGraphScope;
        if (o.panel == null) o.panel = .galaxy;
    }
    if (o.gibson_flight) {
        if ((o.panel != null and o.panel.? != .memory_map) or (o.look != null and o.look.? != .gibson)) return error.InvalidGibsonFlight;
        o.panel = .memory_map;
        o.look = .gibson;
    }
    return o;
}

test "overview options reject debugger targets and bad values" {
    const flight = try parse(&.{ "xodb", "--overview", "--gibson-flight" });
    const film = try parse(&.{ "xodb", "--overview", "--gibson-film" });
    try std.testing.expect(film.gibson_flight and film.gibson_film);
    try std.testing.expect(flight.gibson_flight and flight.look == .gibson and flight.panel == .memory_map);
    try std.testing.expectError(error.InvalidGibsonFlight, parse(&.{ "xodb", "--overview", "--gibson-flight", "--panel", "files" }));
    const ok = try parse(&.{ "xodb", "--overview", "--redact", "--theme", "builtin:green", "--panel", "disk_space", "--interval-ms", "250" });
    const classic = try parse(&.{ "xodb", "--overview", "--look", "win95", "--look", "deep" });
    try std.testing.expectEqualStrings("win95", classic.theme.?);
    try std.testing.expectEqual(vw.memmap.Look.deep, classic.look.?);
    try std.testing.expect(ok.redact);
    try std.testing.expectEqual(vw.Panel.disk_space, ok.panel.?);
    try std.testing.expectEqual(@as(?u64, 250), ok.interval_ms);
    try std.testing.expectError(error.OverviewOptionConflict, parse(&.{ "xodb", "--overview", "--attach", "1" }));
    try std.testing.expectError(error.UnknownOverviewTheme, parse(&.{ "xodb", "--overview", "--theme", "neon" }));
    try std.testing.expectError(error.InvalidOverviewInterval, parse(&.{ "xodb", "--overview", "--interval-ms", "10" }));
    try std.testing.expectError(error.UnknownOverviewPanel, parse(&.{ "xodb", "--overview", "--panel", "flight" }));
    const scale = try parse(&.{ "xodb", "--overview", "--config", "prefs.json", "--ui-scale", "1.5" });
    try std.testing.expectEqual(@as(?f32, 1.5), scale.ui_scale);
    try std.testing.expectEqualStrings("prefs.json", scale.config.?);
    for ([_][:0]const u8{ "0.49", "4.01", "nan" }) |bad| try std.testing.expectError(error.InvalidUiScale, parse(&.{ "xodb", "--overview", "--ui-scale", bad }));
    const demo = try parse(&.{ "xodb", "--overview", "--galaxy-demo", "600:idle" });
    try std.testing.expect(demo.galaxy_demo == 600 and demo.galaxy_demo_idle and demo.panel.? == .galaxy);
    for ([_][:0]const u8{ "0", "1025", "idle", "7:busy" }) |bad| try std.testing.expectError(error.InvalidGalaxyDemo, parse(&.{ "xodb", "--overview", "--galaxy-demo", bad }));
    try std.testing.expectError(error.InvalidGalaxyDemo, parse(&.{ "xodb", "--overview", "--galaxy-demo", "9", "--panel", "graph" }));
}
