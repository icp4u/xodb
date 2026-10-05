const std = @import("std");
const build_options = @import("build_options");
const c = @import("c.zig").api;
const ProcessTree = @import("model/process_tree.zig").Tree;
const Session = @import("model/session.zig").Session;
const Window = @import("platform/wayland.zig").Window;
const Renderer = @import("render/vulkan.zig").Renderer;
const Font = @import("render/font.zig").Font;
const Workspace = @import("ui/workspace.zig").Workspace;
const Server = @import("mcp/server.zig").Server;
const linux = @import("target/linux.zig");
var quitting: c.sig_atomic_t = 0;
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}

pub fn main(init: std.process.Init) !void {
    const startup_started = linux.now();
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var allocation_helper: ?[:0]const u8 = null;
    var config_path: ?[:0]const u8 = null;
    var theme_path: ?[:0]const u8 = null;
    var headless = !build_options.gui;
    var mcp = false;
    var follow_forks = false;
    var process_limit: usize = 32;
    var attach: ?i32 = null;
    var listen: ?[:0]const u8 = null;
    var connect: ?[:0]const u8 = null;
    var ssh: ?[:0]const u8 = null;
    var runtime_agent: ?[:0]const u8 = null;
    var runtime_ssh: ?[:0]const u8 = null;
    var ssh_config: ?[:0]const u8 = null;
    var remote_xodb: [:0]const u8 = "xodb";
    var scope_explicit = false;
    var agent_scope: @import("model/session.zig").AgentScope = .observe;
    var source: ?[:0]const u8 = null;
    var font_path: [:0]const u8 = build_options.font_path ++ "";
    var frames: u64 = 0;
    var record_path: ?[:0]const u8 = null;
    var profile_out: ?[:0]const u8 = null;
    var capture_out: ?[:0]const u8 = null;
    var core_file: ?[:0]const u8 = null;
    var core_executable: ?[:0]const u8 = null;
    var open_capture: ?[:0]const u8 = null;
    var compare_capture: ?[:0]const u8 = null;
    var open_profile: ?[:0]const u8 = null;
    var symbols: ?[:0]const u8 = null;
    var debug_files: std.ArrayList([:0]const u8) = .empty;
    var debug_dirs: std.ArrayList([:0]const u8) = .empty;
    var source_maps: std.ArrayList([:0]const u8) = .empty;
    var reanalyze = false;
    var initial_breakpoint: ?[]const u8 = null;
    var launch: []const [:0]const u8 = &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\xodb — native Linux debugger (M1 workstation baseline)
                \\Usage: xodb [--source FILE] [--mcp] [--headless] [--attach PID | -- PROGRAM ARGS...]
                \\       xodb [--font FILE] [--frames N]
                \\GUI keys: SPACE / F5 / F6 continue or interrupt, F11 source step, F10 source step over (instruction fallback),
                \\          F4 restart owned launch, F9 run to source cursor, F12 finish selected frame, B breakpoint manager,
                \\          M memory/search, R floating-point/SIMD, I inline scopes, C stop/crash details, F8 agent control toggle, TAB locals/registers, W watch, G flow,
                \\          P start/stop CPU capture, F flame graph, Z zoom frame, Backspace zoom out, Enter browse,
                \\          click source gutter for breakpoint, D detach, J/K thread, arrows scroll, Q quit; Esc cancels archive work.
                \\--connect ADDRESS:PORT opens the remote GUI (numeric IPv4 or [IPv6]).
                \\--ssh HOST --remote-xodb PATH opens the GUI with a headless server over SSH.
                \\--runtime-agent PATH uses the standalone C agent with host-side analysis.
                \\--runtime-ssh HOST [--ssh-config FILE] runs that agent over SSH.
                \\--listen ADDRESS:PORT serves one plaintext TCP client; requires --headless --mcp.
                \\With --mcp, --source FILE explicitly shares that source file with remote viewers.
                \\--allocation-helper PATH explicitly permits sudo -n to open allocation probes (see docs/ALLOCATIONS.md).
                \\A opens allocations; P in that panel starts/stops capture on the selected thread.
                \\--theme FILE|builtin:dark|builtin:light|builtin:contrast selects GUI colors at startup.
                \\--config FILE loads provisional JSON preferences (see config/preferences.example.json).
                \\T cycles the next capture duration in the profile view; 0 in config/MCP means until stopped.
                \\--debug-dir DIR replaces default /usr/lib/debug roots (repeatable); local companions are verified.
                \\--source-map FROM=TO substitutes absolute source directory prefixes (repeatable; server paths).
                \\--debug-file FILE explicitly supplies a build-ID-matched debug ELF (repeatable; server path).
                \\--break SYMBOL installs a symbolic breakpoint; unloaded glibc libraries remain pending.
                \\--follow-forks follows x86-64 process creation; --process-limit N bounds retained processes (1..1024, default 32).
                \\O opens process selection; MCP process_id defaults to the original process regardless of GUI selection.
                \\--agent-scope observe|control|mutate limits MCP access (default: observe).
                \\--record FILE saves investigation evidence at shutdown (must be a new file).
                \\--profile-out FILE saves the full CPU aggregate as Speedscope JSON at shutdown (new file).
                \\--capture-out FILE saves a native archive at shutdown (new file, no durability sync).
                \\--core FILE opens a read-only x86-64 ELF core; --exe FILE supplies a matching moved executable.
                \\--open-profile FILE opens an imported simpleperf JSON profile (see scripts/import-simpleperf).
                \\--open-capture FILE opens an offline archive; --symbols DIR optionally loads SHA-256-named ELF assets.
                \\--compare-capture BASE with --open-capture AFTER compares recorded CPU sample shares; V switches views.
                \\--resolve-capture-symbols explicitly derives new labels from verified assets; default is recorded labels.
                \\MCP uses stdio; --headless --mcp runs without a display. Inferior output goes to stderr.
                \\Owned targets are killed on close. Attached targets are detached and preserved.
                \\--frames N exits after N rendered frames for graphical smoke testing.
                \\
            , .{});
            return;
        } else if (std.mem.eql(u8, arg, "--resolve-capture-symbols")) reanalyze = true else if (std.mem.eql(u8, arg, "--follow-forks")) follow_forks = true else if (std.mem.eql(u8, arg, "--headless")) headless = true else if (std.mem.eql(u8, arg, "--mcp")) mcp = true else if (std.mem.eql(u8, arg, "--")) {
            launch = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--runtime-agent") or std.mem.eql(u8, arg, "--runtime-ssh") or std.mem.eql(u8, arg, "--ssh-config") or std.mem.eql(u8, arg, "--allocation-helper") or std.mem.eql(u8, arg, "--process-limit") or std.mem.eql(u8, arg, "--core") or std.mem.eql(u8, arg, "--exe") or std.mem.eql(u8, arg, "--debug-dir") or std.mem.eql(u8, arg, "--source-map") or std.mem.eql(u8, arg, "--connect") or std.mem.eql(u8, arg, "--ssh") or std.mem.eql(u8, arg, "--remote-xodb") or std.mem.eql(u8, arg, "--listen") or std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "--source") or std.mem.eql(u8, arg, "--font") or std.mem.eql(u8, arg, "--theme") or std.mem.eql(u8, arg, "--attach") or std.mem.eql(u8, arg, "--frames") or std.mem.eql(u8, arg, "--agent-scope") or std.mem.eql(u8, arg, "--break") or std.mem.eql(u8, arg, "--record") or std.mem.eql(u8, arg, "--profile-out") or std.mem.eql(u8, arg, "--capture-out") or std.mem.eql(u8, arg, "--open-profile") or std.mem.eql(u8, arg, "--compare-capture") or std.mem.eql(u8, arg, "--open-capture") or std.mem.eql(u8, arg, "--symbols") or std.mem.eql(u8, arg, "--debug-file")) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            if (std.mem.eql(u8, arg, "--runtime-agent")) runtime_agent = args[i];
            if (std.mem.eql(u8, arg, "--runtime-ssh")) runtime_ssh = args[i];
            if (std.mem.eql(u8, arg, "--ssh-config")) ssh_config = args[i];
            if (std.mem.eql(u8, arg, "--allocation-helper")) allocation_helper = args[i];
            if (std.mem.eql(u8, arg, "--process-limit")) process_limit = try std.fmt.parseInt(usize, args[i], 10);
            if (std.mem.eql(u8, arg, "--core")) core_file = args[i];
            if (std.mem.eql(u8, arg, "--exe")) core_executable = args[i];
            if (std.mem.eql(u8, arg, "--connect")) connect = args[i];
            if (std.mem.eql(u8, arg, "--ssh")) ssh = args[i];
            if (std.mem.eql(u8, arg, "--remote-xodb")) remote_xodb = args[i];
            if (std.mem.eql(u8, arg, "--listen")) listen = args[i];
            if (std.mem.eql(u8, arg, "--config")) config_path = args[i];
            if (std.mem.eql(u8, arg, "--record")) record_path = args[i];
            if (std.mem.eql(u8, arg, "--profile-out")) profile_out = args[i];
            if (std.mem.eql(u8, arg, "--capture-out")) capture_out = args[i];
            if (std.mem.eql(u8, arg, "--open-profile")) open_profile = args[i];
            if (std.mem.eql(u8, arg, "--open-capture")) open_capture = args[i];
            if (std.mem.eql(u8, arg, "--compare-capture")) compare_capture = args[i];
            if (std.mem.eql(u8, arg, "--symbols")) symbols = args[i];
            if (std.mem.eql(u8, arg, "--debug-dir")) try debug_dirs.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--source-map")) try source_maps.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--debug-file")) try debug_files.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--break")) initial_breakpoint = args[i];
            if (std.mem.eql(u8, arg, "--agent-scope")) scope_explicit = true;
            if (std.mem.eql(u8, arg, "--agent-scope")) agent_scope = std.meta.stringToEnum(@import("model/session.zig").AgentScope, args[i]) orelse return error.InvalidAgentScope;
            if (std.mem.eql(u8, arg, "--source")) source = args[i];
            if (std.mem.eql(u8, arg, "--font")) font_path = args[i];
            if (std.mem.eql(u8, arg, "--theme")) theme_path = args[i];
            if (std.mem.eql(u8, arg, "--attach")) attach = try std.fmt.parseInt(i32, args[i], 10);
            if (std.mem.eql(u8, arg, "--frames")) frames = try std.fmt.parseInt(u64, args[i], 10);
        } else return error.UnknownArgument;
    }
    if (compare_capture != null and (open_capture == null or symbols != null or reanalyze)) return error.ComparisonRequiresRecordedCpuArchives;
    if (process_limit == 0 or process_limit > @import("model/process_tree.zig").maximum) return error.InvalidProcessLimit;
    if ((follow_forks or process_limit != 32) and (core_file != null or open_capture != null or open_profile != null or connect != null or ssh != null)) return error.ProcessOptionsRequireLocalLiveTarget;
    if (core_executable != null and core_file == null) return error.ExecutableRequiresCore;
    if (core_file != null and (attach != null or launch.len > 0 or open_profile != null or open_capture != null or connect != null or ssh != null or initial_breakpoint != null or profile_out != null or capture_out != null or record_path != null or symbols != null or reanalyze)) return error.CoreOptionConflict;
    if (open_profile != null and (open_capture != null or attach != null or launch.len > 0 or initial_breakpoint != null or source != null or symbols != null or reanalyze or connect != null or ssh != null or capture_out != null or profile_out != null or record_path != null)) return error.ImportOptionConflict;
    if ((debug_dirs.items.len > 0 or source_maps.items.len > 0) and (open_profile != null or open_capture != null or connect != null)) return error.SymbolOptionsRequireLiveServer;
    if (debug_files.items.len > 0 and (open_profile != null or open_capture != null or connect != null)) return error.DebugFilesRequireLiveServer;
    if (allocation_helper != null and (connect != null or ssh != null or open_capture != null or open_profile != null or core_file != null)) return error.AllocationHelperRequiresLiveServer;
    const runtime_remote = runtime_agent != null or runtime_ssh != null;
    if (runtime_remote and (connect != null or ssh != null or core_file != null or open_capture != null or open_profile != null)) return error.RuntimeAgentOptionConflict;
    if (ssh_config != null and runtime_ssh == null) return error.SshConfigRequiresRuntimeSsh;
    const remote_gui = connect != null or ssh != null;
    if (remote_gui and (headless or mcp or listen != null or open_capture != null or symbols != null or record_path != null or capture_out != null or profile_out != null)) return error.RemoteGuiOptionConflict;
    if (connect != null and (ssh != null or attach != null or launch.len > 0 or source != null or initial_breakpoint != null or scope_explicit)) return error.RemoteConnectTargetBelongsOnServer;
    if (ssh != null and attach == null and launch.len == 0) return error.RemoteSshRequiresTarget;
    if (listen != null and (!headless or !mcp)) return error.ListenRequiresHeadlessMcp;
    if (headless and !mcp) return error.HeadlessRequiresMcp;
    if (attach != null and launch.len > 0) return error.ConflictingTargets;
    if (open_capture != null and (attach != null or launch.len > 0 or initial_breakpoint != null or source != null)) return error.ConflictingTargets;
    if ((symbols != null or reanalyze) and open_capture == null) return error.SymbolsRequireArchive;
    const preferences = if (config_path) |path| @import("preferences.zig").load(a, path) catch |err| {
        std.debug.print("xodb: preferences failed: {s}; {s}\n", .{ @errorName(err), path });
        return err;
    } else @import("preferences.zig").Preferences{};
    if (!headless) @import("appearance.zig").init(try @import("preferences.zig").themeSelection(a, &preferences, config_path, theme_path));
    try @import("target/runtime.zig").saveLaunchSignals();
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    if (remote_gui) {
        if (comptime build_options.gui) {
            var remote_args: std.ArrayList([:0]const u8) = .empty;
            const endpoint: @import("remote/client.zig").Endpoint = if (connect) |address| .{ .tcp = address } else blk: {
                try remote_args.appendSlice(a, &.{ remote_xodb, "--headless", "--mcp", "--agent-scope", if (scope_explicit) try a.dupeZ(u8, @tagName(agent_scope)) else "control" });
                if (source) |path| try remote_args.appendSlice(a, &.{ "--source", path });
                for (debug_dirs.items) |path| try remote_args.appendSlice(a, &.{ "--debug-dir", path });
                for (source_maps.items) |spec| try remote_args.appendSlice(a, &.{ "--source-map", spec });
                for (debug_files.items) |path| try remote_args.appendSlice(a, &.{ "--debug-file", path });
                if (initial_breakpoint) |name| try remote_args.appendSlice(a, &.{ "--break", try a.dupeZ(u8, name) });
                if (attach) |pid| {
                    try remote_args.appendSlice(a, &.{ "--attach", try std.fmt.allocPrintSentinel(a, "{d}", .{pid}, 0) });
                } else {
                    try remote_args.append(a, "--");
                    try remote_args.appendSlice(a, launch);
                }
                break :blk .{ .ssh = .{ .host = ssh.?, .args = remote_args.items } };
            };
            const remote_label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (connect != null) "TCP" else "SSH", connect orelse ssh.? });
            try @import("ui/remote.zig").run(endpoint, remote_label, font_path, frames, &quitting, startup_started);
            return;
        } else return error.GuiNotBuilt;
    }
    var connection = @import("remote/transport.zig").Stream{};
    defer connection.close();
    if (listen) |endpoint| connection = try @import("remote/transport.zig").acceptOne(endpoint, &quitting);
    const session = try a.create(Session);
    session.* = Session.init();
    session.agent_scope = agent_scope;
    session.profile_defaults = preferences.profile.config();
    session.allocation_defaults = preferences.allocations;
    session.allocation_helper = allocation_helper;
    defer session.deinit();
    if (runtime_remote) {
        var transport: std.ArrayList([:0]const u8) = .empty;
        const agent = runtime_agent orelse "xodb-agent";
        if (runtime_ssh) |host| {
            try transport.appendSlice(a, &.{ "ssh", "-T", "-o", "BatchMode=yes" });
            if (ssh_config) |path| try transport.appendSlice(a, &.{ "-F", path });
            try transport.appendSlice(a, &.{ "--", host, try @import("remote/transport.zig").shellCommand(a, &.{ agent, "--stdio" }) });
        } else try transport.appendSlice(a, &.{ agent, "--stdio" });
        try session.target.connectRemote(transport.items);
    }
    var tree = ProcessTree{ .limit = process_limit };
    tree.init(session);
    defer tree.deinit();
    session.debug_files.automatic = preferences.symbols.automatic;
    session.debug_files.auto_file_limit = preferences.symbols.auto_file_bytes;
    session.debug_files.auto_total_limit = preferences.symbols.auto_total_bytes;
    for (debug_dirs.items) |path| try session.debug_files.addRoot(path);
    for (source_maps.items) |spec| try session.source_maps.add(spec);
    for (debug_files.items) |path| session.debug_files.add(path) catch |err| {
        std.debug.print("xodb: debug file failed: {s}; {s}\n", .{ @errorName(err), path });
        return err;
    };
    defer if (profile_out) |path| {
        if (session.profile) |capture| {
            if (capture.collector != null) capture.stop(.manual, linux.now());
            if (@import("profile/export.zig").save(capture, path, .{})) |result| {
                std.debug.print("xodb: exported profile #{d}: {d} samples, {d} bytes to {s}\n", .{ capture.id, result.samples, result.bytes, path });
            } else |err| std.debug.print("xodb: profile export failed: {s}; {s}\n", .{ @errorName(err), path });
        } else std.debug.print("xodb: profile export skipped: no capture; {s}\n", .{path});
    };
    defer if (record_path) |path| session.saveInvestigations(path) catch |err| std.debug.print("Evidence export failed: {s}\n", .{@errorName(err)});
    if (core_file) |path| try session.openCore(path, core_executable);
    if (open_capture) |path| try session.openArchive(path, symbols, reanalyze);
    if (open_profile) |path| try session.openImported(path);
    if (compare_capture) |path| session.comparison = try @import("profile/comparison.zig").Job.start(path, open_capture.?);
    if (attach) |pid| {
        const started = linux.now();
        std.debug.print("xodb: attaching to pid={d}\n", .{pid});
        session.target.attach(pid) catch |err| {
            std.debug.print("xodb: attach failed: {s}; pid={d} elapsed_ms={d}\n", .{ @errorName(err), pid, (linux.now() -| started) / 1_000_000 });
            return err;
        };
        std.debug.print("xodb: attached pid={d} threads={d} state={s} elapsed_ms={d}\n", .{ pid, session.target.snapshot().thread_count, @tagName(session.target.snapshot().state), (linux.now() -| started) / 1_000_000 });
    }
    if (launch.len > 0) try session.launch(launch);
    if (follow_forks) try session.target.setFollowProcesses(true);
    if (initial_breakpoint) |name| {
        try session.refreshMaps();
        _ = try session.persistent.addSymbol(session, name);
    }
    const server = try a.create(Server);
    server.* = .{ .source_path = source };
    if (listen != null) {
        server.input_fd = connection.fd;
        server.output_fd = connection.fd;
    }
    if (mcp) try server.init();
    defer if (mcp) server.deinit();
    if (headless) {
        while (quitting == 0) {
            try tree.poll();
            try server.pump(session);
            if (server.closed and server.queued == 0) break;
            _ = c.usleep(2000);
        }
        try finishRequestedArchive(session, capture_out);
        return;
    }
    if (comptime build_options.gui) {
        var window = Window{};
        try window.init();
        defer window.deinit();
        var renderer = Renderer{};
        defer renderer.deinit();
        var renderer_ready = false;
        var render_retry: u64 = 0;
        const font = try a.create(Font);
        font.* = .{};
        try font.init(font_path);
        defer font.deinit();
        var workspaces: [@import("model/process_tree.zig").maximum]?*Workspace = @splat(null);
        workspaces[0] = try a.create(Workspace);
        workspaces[0].?.* = .{};
        var workspace = workspaces[0].?;
        defer for (workspaces) |entry| if (entry) |view| view.deinit();
        var last_process: u64 = 1;
        var last_tree_revision: u64 = 0;
        workspace.show_profile = open_capture != null;
        workspace.comparison.open = compare_capture != null;
        if (open_capture != null) workspace.status = "Opening capture archive";
        if (core_file != null) workspace.status = "Read-only core dump; execution and mutation are disabled";
        var archive_status: [512]u8 = undefined;
        var archive_completed_id: u64 = 0;
        var archive_status_time: u64 = 0;
        if (source) |path| try workspace.loadSource(path);
        var rendered: u64 = 0;
        var last_generation: u64 = std.math.maxInt(u64);
        var last_frame = linux.now();
        var last_profile_revision: u64 = 0;
        var last_profile_id: u64 = 0;
        var last_view_serial: u64 = 0;
        var last_import_serial: u64 = 0;
        var last_allocation_serial: u64 = 0;
        var last_allocation_revision: u64 = 0;
        var last_allocation_state: ?@import("profile/allocation_capture.zig").State = null;
        while (!window.closing and quitting == 0) {
            var phase_started = linux.now();
            try window.pump(window.input.timeoutMs(phase_started, 8));
            reportSlow("Wayland event pump", phase_started);
            if (window.closing or quitting != 0) break;
            window.input.tick(linux.now());
            if (window.input.count > 0) window.dirty = true;
            phase_started = linux.now();
            try tree.poll();
            reportSlow("target/session poll", phase_started);
            const active = tree.active();
            if (workspaces[tree.selected] == null) {
                workspaces[tree.selected] = try a.create(Workspace);
                workspaces[tree.selected].?.* = .{};
            }
            workspace = workspaces[tree.selected].?;
            if (active.process_id != last_process) {
                window.dirty = true;
                archive_completed_id = 0;
                last_allocation_serial = 0;
                last_allocation_revision = 0;
                last_allocation_state = null;
                last_profile_id = 0;
                last_profile_revision = 0;
                last_view_serial = 0;
                last_generation = std.math.maxInt(u64);
                last_process = active.process_id;
            }
            if (tree.revision != last_tree_revision) window.dirty = true;
            if (active.archive_job) |job| {
                const state = job.status();
                if ((!state.done and linux.now() -| archive_status_time > 100_000_000) or (state.done and state.id != archive_completed_id)) {
                    workspace.status = std.fmt.bufPrint(&archive_status, "Archive {s}: {s}{s}{s}", .{ state.kind, if (!state.done) state.phase else if (state.publication) |p| @tagName(p.state) else if (state.error_name != null) "failed" else if (std.mem.eql(u8, state.kind, "open")) "offline capture ready" else "ready", if (state.error_name != null) " / " else "", state.error_name orelse "" }) catch "Archive operation";
                    archive_status_time = linux.now();
                    if (state.done) archive_completed_id = state.id;
                    window.dirty = true;
                }
            }
            if (mcp) {
                try server.pump(session);
                if (server.closed and server.queued == 0) break;
            }
            phase_started = linux.now();
            workspace.input(&window, active);
            if (tree.active() != active) continue;
            reportSlow("workspace input/inspection", phase_started);
            if (window.closing or quitting != 0) break;
            const current = linux.now();
            const allocation_state = if (active.allocations.capture) |capture| capture.state else null;
            const allocations_changed = active.allocations.serial != last_allocation_serial or allocation_state != last_allocation_state or
                (if (active.allocations.capture) |capture| capture.revision != last_allocation_revision and current -| last_frame >= 250_000_000 else false);
            const profile_changed = if (active.profile) |capture| (capture.id != last_profile_id or capture.revision != last_profile_revision) and current -| last_frame >= 250_000_000 else false;
            if ((if (active.imported) |state| state.serial != last_import_serial else false) or active.recorded_views.serial != last_view_serial or allocations_changed or profile_changed or window.dirty or workspace.animating or active.target.snapshot().generation != last_generation or frames > 0 or current - last_frame > 1_000_000_000) {
                if (current < render_retry) continue;
                if (!renderer_ready) {
                    phase_started = linux.now();
                    renderer.init(&window) catch |err| {
                        workspace.status = @errorName(err);
                        std.debug.print("Renderer initialization failed: {s}; retrying, target retained\n", .{@errorName(err)});
                        render_retry = current + 1_000_000_000;
                        continue;
                    };
                    reportSlow("Vulkan initialization", phase_started);
                    renderer_ready = true;
                    font.dirty = true;
                }
                const presented = renderFrame(&renderer, font, workspace, &window, active) catch |err| {
                    workspace.status = @errorName(err);
                    std.debug.print("Frame failed: {s}; recreating renderer, target retained\n", .{@errorName(err)});
                    // A failed submit may leave the frame fence unsignalled. Recreate
                    // the renderer instead of waiting on that fence next frame.
                    renderer.deinit();
                    renderer_ready = false;
                    render_retry = current + 1_000_000_000;
                    continue;
                };
                window.dirty = !presented;
                if (!presented) continue;
                if (rendered == 0) @import("startup.zig").report(startup_started, mcp);
                last_allocation_serial = active.allocations.serial;
                last_allocation_state = allocation_state;
                if (active.allocations.capture) |capture| last_allocation_revision = capture.revision;
                last_generation = active.target.snapshot().generation;
                last_tree_revision = tree.revision;
                last_view_serial = active.recorded_views.serial;
                if (active.imported) |state| last_import_serial = state.serial;
                if (active.profile) |capture| {
                    last_profile_id = capture.id;
                    last_profile_revision = if (workspace.show_profile and capture.offline) workspace.flame.revision else capture.revision;
                }
                last_frame = current;
                rendered += 1;
                if (frames > 0 and rendered >= frames) break;
            }
        }
        if (capture_out == null and (window.closing or quitting != 0)) {
            if (session.archive_job) |job| if (job.kind != .save and !job.done.load(.acquire)) job.progress.cancel.store(true, .release);
        }
        const reason = if (quitting != 0) "signal" else if (window.closing) @tagName(window.close_reason) else if (mcp and server.closed) "mcp_eof" else if (frames > 0 and rendered >= frames) "frame_limit" else "loop_exit";
        try finishRequestedArchive(session, capture_out);
        std.debug.print("xodb: {d} frames, clean shutdown (reason={s}, signal={d})\n", .{ rendered, reason, quitting });
    }
}
fn finishRequestedArchive(session: *Session, path: ?[:0]const u8) !void {
    session.finishArchive() catch |err| {
        // An MCP job reports its own failure. Failed CLI opening must still
        // produce a nonzero process result, even if stdin immediately closed.
        if (session.offline and session.artifact == null) return err;
    };
    if (path) |destination| {
        if (session.profile) |capture| {
            if (capture.collector != null) try session.stopProfile();
        }
        if (session.profile == null) {
            session.allocations.stop(.manual);
            const deadline = @import("target/linux.zig").now() + 10_000_000_000;
            while (session.allocations.preparing() or session.allocations.collecting()) {
                session.allocations.poll(false, null);
                if (@import("target/linux.zig").now() > deadline) return error.AllocationArchiveShutdownDeadline;
                _ = @import("c.zig").api.usleep(1000);
            }
            if (session.allocations.capture) |capture| while (capture.worker != null) {
                capture.poll();
                if (@import("target/linux.zig").now() > deadline) return error.AllocationArchiveShutdownDeadline;
                _ = @import("c.zig").api.usleep(1000);
            };
        }
        _ = (if (session.profile == null and session.allocations.capture != null) session.saveAllocationArchive(destination) else session.saveArchive(destination)) catch |err| {
            std.debug.print("xodb: requested archive save failed: {s}; {s}\n", .{ @errorName(err), destination });
            return err;
        };
        try session.finishArchive();
    }
}
fn reportSlow(phase: []const u8, started: u64) void {
    const elapsed = linux.now() -| started;
    if (elapsed >= 250_000_000) std.debug.print("xodb: slow {s}: {d} ms\n", .{ phase, elapsed / 1_000_000 });
}
fn renderFrame(renderer: *Renderer, font: *Font, workspace: *Workspace, window: *Window, session: *Session) !bool {
    var started = linux.now();
    if (!try renderer.begin(window.width, window.height)) return false;
    reportSlow("Vulkan frame begin", started);
    started = linux.now();
    workspace.draw(renderer, font, window, session) catch |err| {
        // Geometry exhaustion or allocation failure can leave a partial frame;
        // presenting it is safe and the next frame reports the error.
        workspace.status = @errorName(err);
        std.debug.print("Workspace draw failed: {s}; target retained\n", .{@errorName(err)});
    };
    reportSlow("workspace draw/inspection", started);
    started = linux.now();
    const presented = try renderer.end(font);
    reportSlow("Vulkan submit/present", started);
    return presented;
}

test {
    std.testing.refAllDecls(@import("appearance.zig"));
    std.testing.refAllDecls(@import("remote/transport.zig"));
    std.testing.refAllDecls(@import("remote/client.zig"));
    std.testing.refAllDecls(@import("mcp/remote.zig"));
    std.testing.refAllDecls(@import("mcp/server.zig"));
    std.testing.refAllDecls(@import("preferences.zig"));
    std.testing.refAllDecls(@import("profile/archive.zig"));
    std.testing.refAllDecls(@import("profile/linux_syscalls.zig"));
    std.testing.refAllDecls(@import("profile/allocation_lifetimes.zig"));
    std.testing.refAllDecls(@import("profile/allocation_events.zig"));
    std.testing.refAllDecls(@import("profile/allocation_perf.zig"));
    std.testing.refAllDecls(@import("profile/linux_allocations.zig"));
    std.testing.refAllDecls(@import("profile/allocation_hooks.zig"));
    std.testing.refAllDecls(@import("profile/allocation_capture.zig"));
    std.testing.refAllDecls(@import("profile/allocation_live.zig").Live);
    std.testing.refAllDecls(@import("mcp/allocations.zig"));
    std.testing.refAllDecls(@import("mcp/allocation_control.zig"));
    _ = @import("profile/archive_test.zig");
    _ = @import("profile/perf_test.zig");
    _ = @import("profile/recorded_view_test.zig");
    _ = @import("profile/user_state_test.zig");
    _ = @import("profile/sampled_test.zig");
    _ = @import("profile/derived_test.zig");
    std.testing.refAllDecls(@import("profile/sample_state.zig"));
    std.testing.refAllDecls(@import("profile/unwind.zig"));
    if (build_options.gui) {
        std.testing.refAllDecls(@import("platform/input.zig"));
        std.testing.refAllDecls(@import("ui/workspace.zig"));
        std.testing.refAllDecls(@import("ui/allocations.zig"));
        std.testing.refAllDecls(@import("ui/watch.zig"));
        _ = @import("ui/watch_test.zig");
        std.testing.refAllDecls(@import("ui/remote.zig"));
        std.testing.refAllDecls(@import("ui/timeline.zig"));
        std.testing.refAllDecls(@import("ui/capture_setup.zig"));
        std.testing.refAllDecls(@import("ui/capture_panel.zig"));
    }
    std.testing.refAllDecls(@import("model/session.zig"));
    _ = @import("target/process_test.zig");
    std.testing.refAllDecls(@import("model/modules.zig"));
    std.testing.refAllDecls(@import("binary/apk.zig"));
    std.testing.refAllDecls(@import("model/disassembly.zig"));
    std.testing.refAllDecls(@import("model/analysis_ir.zig"));
    std.testing.refAllDecls(@import("profile/export.zig"));
    std.testing.refAllDecls(@import("model/evaluate.zig"));
    std.testing.refAllDecls(@import("model/value_view.zig"));
    std.testing.refAllDecls(@import("debug/location.zig"));
}

test {
    _ = @import("profile/imported_test.zig");
}
