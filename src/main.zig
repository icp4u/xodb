const std = @import("std");
const log = @import("log.zig");
const build_options = @import("build_options");
const c = @import("c.zig").api;
const ProcessTree = @import("model/process_tree.zig").Tree;
const Session = @import("model/session.zig").Session;
const Window = @import("platform/window.zig").Window;
const Renderer = @import("render/vulkan.zig").Renderer;
const Font = @import("render/font.zig").Font;
const Workspace = @import("ui/workspace.zig").Workspace;
const Server = @import("mcp/server.zig").Server;
const SharedSession = @import("mcp/shared.zig").Endpoint;
const linux = @import("target/linux.zig");
const snapshot = @import("binary/snapshot.zig");
var quitting: c.sig_atomic_t = 0;
fn imageBudgetError(err: anyerror, option: []const u8, value: []const u8) anyerror {
    log.err(.session, "xodb: {s} {s}: expected a size from 1M to {d}G (bytes, or a whole number with K, M or G)\n", .{ option, value, snapshot.max_limit >> 30 });
    return err;
}
/// The debugger options that are followed by a value. The parser in main and
/// log.init share the list, so a value is never read as an option.
const value_options = [_][]const u8{ "--language-off", "--wine-threads", "--observe-recipe", "--observation-out", "--open-observation", "--browse-observation", "--observation-threshold-ns", "--static-analysis", "--decompile", "--function", "--gdb-remote", "--runtime-agent", "--runtime-ssh", "--ssh-config", "--allocation-helper", "--process-limit", "--core", "--exe", "--debug-dir", "--source-map", "--connect", "--ssh", "--remote-xodb", "--session-socket", "--listen", "--config", "--source", "--font", "--theme", "--ui-scale", "--platform", "--expected-start-ticks", "--attach", "--frames", "--vk-device", "--agent-scope", "--break", "--record", "--profile-out", "--capture-out", "--open-frames", "--open-profile", "--compare-capture", "--open-capture", "--open-pcap", "--live-capture", "--capture-tool", "--capture-ring-bytes", "--tls-key-log", "--open-mitmproxy", "--symbols", "--debug-file", "--image-limit", "--image-total-limit" };
fn named(names: []const []const u8, arg: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}
/// Every parser xodb dispatches to after log.init: the debugger, the overview
/// and the scene3d probe ("--instances"; its "--frames" is in the other two).
fn takesValue(arg: []const u8) bool {
    return named(&value_options, arg) or named(&@import("ui/overview/options.zig").takes, arg) or named(&@import("ui/overview/fetch.zig").takes, arg) or std.mem.eql(u8, arg, "--instances");
}
fn parseUiScale(value: []const u8) !f32 {
    const scale = std.fmt.parseFloat(f32, value) catch return error.InvalidUiScale;
    return @import("platform/window.zig").validateScale(scale);
}
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}

pub fn main(init: std.process.Init) !void {
    const startup_started = linux.now();
    const a = init.arena.allocator();
    const given = try init.minimal.args.toSlice(a);
    // lsof-top is a separate terminal program over the C fd scanner. Only
    // xodb's own options count: a launched program's arguments follow "--".
    for (given[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (!std.mem.eql(u8, arg, "--lsof-top")) continue;
        const argv = try a.alloc(?[*:0]u8, given.len + 1);
        for (given, 0..) |text, k| argv[k] = @constCast(text.ptr);
        argv[given.len] = null;
        std.process.exit(@intCast(c.xodb_lsof_top(@intCast(given.len), @ptrCast(argv.ptr)) & 0xff));
    }
    // The memory defrag terminal view needs no window and no target.
    for (given[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--memdefrag")) std.process.exit(@import("memdefrag/tui.zig").main(given));
    }
    // Everything below logs through log.zig and never sees its options.
    const args = log.init(try a.dupe([:0]const u8, given), takesValue);
    // Vulkan device choice applies to every window; the list needs no target.
    if (comptime build_options.gui) for (args[1..], 1..) |arg, k| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--vk-device") and k + 1 < args.len) @import("render/vulkan.zig").device_request = args[k + 1];
        if (!std.mem.eql(u8, arg, "--platform")) continue;
        if (k + 1 >= args.len) {
            log.err(.window, "xodb: --platform needs wayland or x11\n", .{});
            return error.InvalidPlatform;
        }
        try @import("platform/window.zig").requestPlatform(args[k + 1]);
    };
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--vk-list")) return vkList();
    }
    if (comptime build_options.gui) for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--scene3d-probe")) return @import("render/scene3d/probe.zig").main(args);
    };
    // The fetch card prints and exits: no window, no target.
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--fetch")) return @import("ui/overview/fetch.zig").main(args);
    }
    // The overview is its own window and session with no debug target;
    // headless, it is the collector and MCP alone (no window code runs).
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--overview") or std.mem.eql(u8, arg, "--attach-exe")) {
            for (args[1..]) |other| if (std.mem.eql(u8, other, "--headless")) return overviewHeadless(args);
            return @import("ui/overview/run.zig").main(args, startup_started);
        }
    }
    var allocation_helper: ?[:0]const u8 = null;
    var static_analysis: ?[:0]const u8 = if (@import("c.zig").api.getenv("XODB_STATIC_ANALYSIS")) |dir| std.mem.span(dir) else null;
    var static_decompile: ?[:0]const u8 = null;
    var static_function: []const u8 = "";
    var no_ghidra_prestart = false;
    var config_path: ?[:0]const u8 = null;
    var languages_off = @import("preferences.zig").Languages{};
    var theme_path: ?[:0]const u8 = null;
    var ui_scale_cli: ?f32 = null;
    var headless = !build_options.gui;
    var mcp = false;
    var session_socket: ?[:0]const u8 = null;
    var follow_forks = false;
    var process_limit: usize = 32;
    var attach: ?i32 = null;
    var hide_wine_threads: ?bool = null;
    var expected_start: ?u64 = null;
    var start_profile = false;
    var redot_debugger = false;
    var redact = false;
    var listen: ?[:0]const u8 = null;
    var connect: ?[:0]const u8 = null;
    var ssh: ?[:0]const u8 = null;
    var runtime_agent: ?[:0]const u8 = null;
    var gdb_remote: ?[:0]const u8 = null;
    var runtime_ssh: ?[:0]const u8 = null;
    var ssh_config: ?[:0]const u8 = null;
    var remote_xodb: [:0]const u8 = "xodb";
    var scope_explicit = false;
    var agent_scope: @import("model/session.zig").AgentScope = .observe;
    var source: ?[:0]const u8 = null;
    var fetch_source = false;
    var font_path: [:0]const u8 = build_options.font_path ++ "";
    var frames: u64 = 0;
    var record_path: ?[:0]const u8 = null;
    var profile_out: ?[:0]const u8 = null;
    var capture_out: ?[:0]const u8 = null;
    var core_file: ?[:0]const u8 = null;
    var core_executable: ?[:0]const u8 = null;
    var open_capture: ?[:0]const u8 = null;
    var open_pcap: ?[:0]const u8 = null;
    var live_capture: ?[:0]const u8 = null;
    var capture_tool: ?[:0]const u8 = null;
    var capture_ring_bytes: usize = @import("capture/live.zig").default_ring_bytes;
    var tls_key_log: ?[:0]const u8 = null;
    var open_mitmproxy: ?[:0]const u8 = null;
    var compare_capture: ?[:0]const u8 = null;
    var open_frames: ?[:0]const u8 = null;
    var open_profile: ?[:0]const u8 = null;
    var observation_recipe: ?[:0]const u8 = null;
    var observation_out: ?[:0]const u8 = null;
    var open_observation: ?[:0]const u8 = null;
    var browse_observation: ?[:0]const u8 = null;
    var observation_threshold: ?u64 = null;
    var symbols: ?[:0]const u8 = null;
    var image_limit: ?u64 = null;
    var image_total_limit: ?u64 = null;
    var debug_files: std.ArrayList([:0]const u8) = .empty;
    var debug_dirs: std.ArrayList([:0]const u8) = .empty;
    var source_maps: std.ArrayList([:0]const u8) = .empty;
    var reanalyze = false;
    var initial_breakpoints: [64][]const u8 = undefined;
    var initial_breakpoint_count: usize = 0;
    var launch: []const [:0]const u8 = &.{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--start-profile")) {
            start_profile = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redot-debugger")) {
            redot_debugger = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--redact")) {
            redact = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\xodb — native Linux debugger (M1 workstation baseline)
                \\Usage: xodb [--source FILE] [--mcp] [--headless] [--attach PID | -- PROGRAM ARGS...]
                \\       xodb [--font FILE] [--frames N]
                \\GUI keys: SPACE / F5 / F6 continue or interrupt, F11 source step, F10 source step over (instruction fallback),
                \\          F4 restart owned launch, F9 run to source cursor, F12 finish selected frame, B breakpoint manager,
                \\          M memory/search, Y runtime types, R floating-point/SIMD, I inline scopes, C stop/crash details, F8 agent control toggle, TAB locals/registers, W watch, G flow,
                \\          P start/stop CPU capture, F flame graph, Z zoom frame, Backspace zoom out, Enter browse,
                \\          click source gutter for breakpoint, D detach, J/K thread, arrows scroll, Q quit; Esc cancels archive work.
                \\--connect ADDRESS:PORT opens the remote GUI (numeric IPv4 or [IPv6]).
                \\--ssh HOST --remote-xodb PATH opens the GUI with a headless server over SSH.
                \\--runtime-agent PATH uses the standalone C agent with host-side analysis.
                \\--runtime-ssh HOST [--ssh-config FILE] runs that agent over SSH.
                \\--session-socket PATH serves local MCP observers and one leased controller (GUI or --headless).
                \\--listen ADDRESS:PORT serves one plaintext TCP client; requires --headless --mcp.
                \\With --mcp, --source FILE explicitly shares that source file with remote viewers.
                \\--allocation-helper PATH explicitly permits sudo -n to open allocation probes (see docs/ALLOCATIONS.md).
                \\A opens allocations; P in that panel starts/stops capture on the selected thread.
                \\--theme FILE|builtin:dark|builtin:light|builtin:contrast|builtin:vga selects the GUI theme at startup.
                \\--config FILE loads provisional JSON preferences (see config/preferences.example.json).
                \\--ui-scale N sets device pixels per UI unit (0.5..4); otherwise appearance.ui_scale or the compositor wins.
                \\--platform wayland|x11 selects the window system; otherwise a set WAYLAND_DISPLAY, then DISPLAY.
                \\--language-off NAME|all turns a language view off, as "languages" in the preferences does; repeatable.
                \\--wine-threads show|hide controls Wine-internal name hints (default show); H toggles in the GUI.
                \\--attach-exe opens the process picker with an editable .exe filter; Enter confirms attach.
                \\T cycles the next capture duration in the profile view; 0 in config/MCP means until stopped.
                \\--debug-dir DIR replaces default /usr/lib/debug roots (repeatable); local companions are verified.
                \\--fetch-source opts in to bounded source copies from --runtime-ssh/--runtime-agent; local files and --source-map win.
                \\--source-map FROM=TO substitutes absolute source directory prefixes (repeatable; server paths).
                \\--debug-file FILE explicitly supplies a build-ID-matched debug ELF (repeatable; server path).
                \\--image-limit SIZE and --image-total-limit SIZE bound full ELF images read for code, source and types
                \\  (bytes, or K/M/G; default 1G per image and 4G in total; a refused image says what to raise).
                \\--break SYMBOL is repeatable (up to 64): symbols install in order; duplicates share a breakpoint.
                \\Unloaded glibc library symbols remain pending without dropping other --break requests.
                \\--follow-forks follows x86-64 process creation; --process-limit N bounds retained processes (1..1024, default 32).
                \\O opens process selection; U opens the Redot/Godot scene tree and inspector (local launches).
                \\MCP process_id defaults to the original process regardless of GUI selection.
                \\--gdb-remote HOST:PORT connects to an existing all-stop gdbserver, QEMU or Apple debugserver target.
                \\--redot-debugger adds a private loopback scene-debugger peer to a local owned Redot/Godot launch.
                \\--agent-scope observe|control|mutate limits MCP access (default: observe).
                \\--redact hides home paths, user and host names, and addresses outside loopback/documentation ranges in the GUI,
                \\  MCP replies, logs and saved archives (not exports yet); raw packet and decrypted payload replies are refused.
                \\  Addresses become per-session tags (docs/GUIDE.md "Redaction").
                \\--record FILE saves investigation evidence at shutdown (must be a new file).
                \\--expected-start-ticks N refuses attach if the sampled process identity changed.
                \\--start-profile attaches, starts a 99 Hz / 10 s CPU capture, and resumes the target.
                \\--profile-out FILE saves the full CPU aggregate as Speedscope JSON at shutdown (new file).
                \\--capture-out FILE saves a native archive at shutdown (new file, no durability sync).
                \\--core FILE opens a read-only x86-64 ELF core; --exe FILE supplies a matching moved executable.
                \\With --gdb-remote, --exe may supply its fixed-address ELF when the stub cannot list images.
                \\--open-frames FILE opens logical-frame JSONL or a saved .xof bundle.
                \\--open-profile FILE opens an imported simpleperf JSON profile (see scripts/import-simpleperf).
                \\--observe-recipe FILE --observation-out FILE runs a bounded headless function investigation and saves .xoi evidence.
                \\--open-observation FILE reopens .xoi and prints cohorts; add --mcp for immutable agent queries.
                \\--browse-observation FILE opens .xoi in the GUI invocation/cohort browser (N reopens it).
                \\--observation-threshold-ns N overrides the fast/slow wall-duration threshold (see docs/OBSERVATIONS.md).
                \\--open-capture FILE opens an offline archive; --symbols DIR optionally loads SHA-256-named ELF assets.
                \\--open-pcap FILE opens network, Linux usbmon or dbus-monitor pcap/pcapng as read-only evidence; with --open-capture, aligns and correlates it.
                \\--live-capture INTERFACE starts one owned dumpcap/tcpdump child and a bounded 64 MiB packet ring.
                \\--capture-tool PATH selects dumpcap or tcpdump explicitly; --capture-ring-bytes SIZE sets 64K..256M.
                \\--tls-key-log FILE decrypts TLS 1.2/1.3 records in --open-pcap; secrets are consumed in memory and never logged.
                \\--open-mitmproxy FILE opens a mitmproxy flow dump as a read-only evidence stream.
                \\--compare-capture BASE with --open-capture AFTER compares recorded CPU sample shares; V switches views.
                \\--resolve-capture-symbols explicitly derives new labels from verified assets; default is recorded labels.
                \\MCP uses stdio; --headless --mcp runs without a display. Inferior output goes to stderr.
                \\Owned targets are killed on close. Attached targets are detached and preserved.
                \\--frames N exits after N rendered frames for graphical smoke testing.
                \\--vk-list prints the Vulkan devices and marks the one xodb uses; --vk-device INDEX|NAME picks
                \\  another (XODB_VK_DEVICE does the same). A blank window usually means the wrong GPU or a
                \\  driver that did not load: stderr names it in one "xodb: vulkan:" line (docs/GUIDE.md).
                \\--lsof-top runs the terminal open-file and fd activity view (--lsof-top --help; docs/LSOF_TOP.md).
                \\--overview opens the system overview (no target); xodb --overview --help lists its options.
                \\--fetch prints a fastfetch-style card of this machine and exits (--fetch --help; docs/FETCH.md).
                \\Graph/galaxy default: LIVE SYSCALL TRACING · ~11% host syscall overhead · E to stop
                \\--memdefrag runs the terminal memory map and THP "defrag" view (--memdefrag --help).
                \\--static-analysis DIR enables pseudo-C (D), static slices (S), and decompile_function over MCP with the
                \\  native Ghidra worker built in DIR (tools/ghx); XODB_STATIC_ANALYSIS=DIR does the same.
                \\--decompile FILE [--function NAME] prints Ghidra pseudo-C from a private immutable static-image session.
                \\--no-ghidra-prestart leaves the configured Ghidra sidecar idle until pseudo-C is requested.
                \\-q shows warnings and errors only, -qq errors only; -v adds debug lines (decisions), -vv trace lines
                \\  (per-event detail). --log=LEVEL names the level (error|warn|info|debug|trace) and
                \\  --log=TOPIC=LEVEL[,...] sets it per topic: render, window, runtime, agent, session, mcp, sidecar,
                \\  semq, overview, redot, profile. XODB_LOG takes the same value; the option wins.
                \\--log-file FILE appends these lines to FILE (created 0600) and leaves stderr quiet; XODB_LOG_FILE=FILE
                \\  does the same, and is how the processes xodb starts are given the file.
                \\
            , .{});
            return;
        } else if (std.mem.eql(u8, arg, "--fetch-source")) fetch_source = true else if (std.mem.eql(u8, arg, "--resolve-capture-symbols")) reanalyze = true else if (std.mem.eql(u8, arg, "--follow-forks")) follow_forks = true else if (std.mem.eql(u8, arg, "--no-ghidra-prestart")) no_ghidra_prestart = true else if (std.mem.eql(u8, arg, "--headless")) headless = true else if (std.mem.eql(u8, arg, "--mcp")) mcp = true else if (std.mem.eql(u8, arg, "--redact")) redact = true else if (std.mem.eql(u8, arg, "--")) {
            launch = args[i + 1 ..];
            break;
        } else if (named(&value_options, arg)) {
            i += 1;
            if (i == args.len) return error.MissingArgument;
            if (std.mem.eql(u8, arg, "--wine-threads")) hide_wine_threads = if (std.mem.eql(u8, args[i], "hide")) true else if (std.mem.eql(u8, args[i], "show")) false else return error.InvalidWineThreadVisibility;
            if (std.mem.eql(u8, arg, "--observe-recipe")) {
                observation_recipe = args[i];
                headless = true;
            }
            if (std.mem.eql(u8, arg, "--observation-out")) observation_out = args[i];
            if (std.mem.eql(u8, arg, "--open-observation")) {
                open_observation = args[i];
                headless = true;
            }
            if (std.mem.eql(u8, arg, "--browse-observation")) browse_observation = args[i];
            if (std.mem.eql(u8, arg, "--observation-threshold-ns")) observation_threshold = try std.fmt.parseInt(u64, args[i], 10);
            if (std.mem.eql(u8, arg, "--runtime-agent")) runtime_agent = args[i];
            if (std.mem.eql(u8, arg, "--gdb-remote")) gdb_remote = args[i];
            if (std.mem.eql(u8, arg, "--static-analysis")) static_analysis = args[i];
            if (std.mem.eql(u8, arg, "--decompile")) static_decompile = args[i];
            if (std.mem.eql(u8, arg, "--function")) static_function = args[i];
            if (std.mem.eql(u8, arg, "--runtime-ssh")) runtime_ssh = args[i];
            if (std.mem.eql(u8, arg, "--ssh-config")) ssh_config = args[i];
            if (std.mem.eql(u8, arg, "--allocation-helper")) allocation_helper = args[i];
            if (std.mem.eql(u8, arg, "--process-limit")) process_limit = try std.fmt.parseInt(usize, args[i], 10);
            if (std.mem.eql(u8, arg, "--core")) core_file = args[i];
            if (std.mem.eql(u8, arg, "--exe")) core_executable = args[i];
            if (std.mem.eql(u8, arg, "--connect")) connect = args[i];
            if (std.mem.eql(u8, arg, "--ssh")) ssh = args[i];
            if (std.mem.eql(u8, arg, "--remote-xodb")) remote_xodb = args[i];
            if (std.mem.eql(u8, arg, "--session-socket")) session_socket = args[i];
            if (std.mem.eql(u8, arg, "--listen")) listen = args[i];
            if (std.mem.eql(u8, arg, "--config")) config_path = args[i];
            if (std.mem.eql(u8, arg, "--language-off")) languages_off.turnOff(args[i]) catch |err| {
                log.err(.session, "xodb: --language-off takes all, python, perl, lua, javascript, ruby, go, elisp or gdscript; not {s}\n", .{args[i]});
                return err;
            };
            if (std.mem.eql(u8, arg, "--record")) record_path = args[i];
            if (std.mem.eql(u8, arg, "--expected-start-ticks")) expected_start = try std.fmt.parseInt(u64, args[i], 10);
            if (std.mem.eql(u8, arg, "--profile-out")) profile_out = args[i];
            if (std.mem.eql(u8, arg, "--capture-out")) capture_out = args[i];
            if (std.mem.eql(u8, arg, "--open-frames")) open_frames = args[i];
            if (std.mem.eql(u8, arg, "--open-profile")) open_profile = args[i];
            if (std.mem.eql(u8, arg, "--open-capture")) open_capture = args[i];
            if (std.mem.eql(u8, arg, "--open-pcap")) open_pcap = args[i];
            if (std.mem.eql(u8, arg, "--live-capture")) live_capture = args[i];
            if (std.mem.eql(u8, arg, "--capture-tool")) capture_tool = args[i];
            if (std.mem.eql(u8, arg, "--capture-ring-bytes")) capture_ring_bytes = std.math.cast(usize, snapshot.parseSize(args[i]) catch return error.InvalidCaptureRingSize) orelse return error.InvalidCaptureRingSize;
            if (std.mem.eql(u8, arg, "--tls-key-log")) tls_key_log = args[i];
            if (std.mem.eql(u8, arg, "--open-mitmproxy")) open_mitmproxy = args[i];
            if (std.mem.eql(u8, arg, "--compare-capture")) compare_capture = args[i];
            if (std.mem.eql(u8, arg, "--symbols")) symbols = args[i];
            if (std.mem.eql(u8, arg, "--debug-dir")) try debug_dirs.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--source-map")) try source_maps.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--debug-file")) try debug_files.append(a, args[i]);
            if (std.mem.eql(u8, arg, "--image-limit") or std.mem.eql(u8, arg, "--image-total-limit")) {
                const size = snapshot.parseSize(args[i]) catch |err| return imageBudgetError(err, arg, args[i]);
                if (size < snapshot.min_limit or size > snapshot.max_limit) return imageBudgetError(error.InvalidImageBudget, arg, args[i]);
                if (arg.len == "--image-limit".len) image_limit = size else image_total_limit = size;
            }
            if (std.mem.eql(u8, arg, "--break")) {
                if (initial_breakpoint_count == initial_breakpoints.len) return error.InitialBreakpointLimit;
                initial_breakpoints[initial_breakpoint_count] = args[i];
                initial_breakpoint_count += 1;
            }
            if (std.mem.eql(u8, arg, "--agent-scope")) scope_explicit = true;
            if (std.mem.eql(u8, arg, "--agent-scope")) agent_scope = std.meta.stringToEnum(@import("model/session.zig").AgentScope, args[i]) orelse return error.InvalidAgentScope;
            if (std.mem.eql(u8, arg, "--source")) source = args[i];
            if (std.mem.eql(u8, arg, "--font")) font_path = args[i];
            if (std.mem.eql(u8, arg, "--theme")) theme_path = args[i];
            if (std.mem.eql(u8, arg, "--ui-scale")) ui_scale_cli = try parseUiScale(args[i]);
            if (std.mem.eql(u8, arg, "--attach")) attach = try std.fmt.parseInt(i32, args[i], 10);
            if (std.mem.eql(u8, arg, "--frames")) frames = try std.fmt.parseInt(u64, args[i], 10);
        } else return error.UnknownArgument;
    }
    if (static_function.len != 0 and static_decompile == null) return error.FunctionRequiresStaticDecompile;
    if (static_decompile != null and (launch.len != 0 or attach != null or mcp or session_socket != null or listen != null or connect != null or ssh != null or runtime_agent != null or runtime_ssh != null or gdb_remote != null or core_file != null or open_capture != null or open_profile != null or open_frames != null or observation_recipe != null or open_observation != null or browse_observation != null or initial_breakpoint_count != 0)) return error.StaticDecompileOptionConflict;
    if (observation_recipe != null) {
        if (observation_out == null or open_observation != null or browse_observation != null or mcp or session_socket != null or listen != null or connect != null or ssh != null or core_file != null or open_capture != null or open_profile != null or initial_breakpoint_count != 0 or follow_forks or capture_out != null or profile_out != null or record_path != null) return error.ObservationRecipeOptionConflict;
        if (launch.len == 0 and attach == null) return error.ObservationRecipeRequiresTarget;
    } else if (observation_out != null) return error.ObservationOutputRequiresRecipe;
    if (browse_observation != null and (open_observation != null or headless)) return error.BrowseObservationRequiresGui;
    if ((open_observation != null or browse_observation != null) and (launch.len > 0 or attach != null or core_file != null or open_capture != null or open_profile != null or runtime_agent != null or runtime_ssh != null or gdb_remote != null or connect != null or ssh != null or initial_breakpoint_count != 0 or follow_forks or capture_out != null or profile_out != null or record_path != null or allocation_helper != null or symbols != null or reanalyze)) return error.ObservationOpenOptionConflict;
    if (observation_threshold != null and observation_recipe == null and open_observation == null and browse_observation == null) return error.ObservationThresholdRequiresInvestigation;
    if (observation_threshold != null and (mcp or session_socket != null)) return error.ObservationThresholdUseMcpComparison;
    if (compare_capture != null and (open_capture == null or symbols != null or reanalyze)) return error.ComparisonRequiresRecordedCpuArchives;
    if (process_limit == 0 or process_limit > @import("model/process_tree.zig").maximum) return error.InvalidProcessLimit;
    if ((follow_forks or process_limit != 32) and (core_file != null or open_capture != null or open_profile != null or connect != null or ssh != null)) return error.ProcessOptionsRequireLocalLiveTarget;
    if (core_executable != null and core_file == null and gdb_remote == null) return error.ExecutableRequiresCoreOrGdbRemote;
    if (core_file != null and (attach != null or launch.len > 0 or open_profile != null or open_capture != null or connect != null or ssh != null or initial_breakpoint_count != 0 or profile_out != null or capture_out != null or record_path != null or symbols != null or reanalyze)) return error.CoreOptionConflict;
    if (open_frames != null and (open_profile != null or connect != null or ssh != null or observation_recipe != null or open_observation != null or browse_observation != null)) return error.FrameOptionConflict;
    if (open_profile != null and (open_capture != null or attach != null or launch.len > 0 or initial_breakpoint_count != 0 or source != null or symbols != null or reanalyze or connect != null or ssh != null or capture_out != null or profile_out != null or record_path != null)) return error.ImportOptionConflict;
    if ((debug_dirs.items.len > 0 or source_maps.items.len > 0) and (open_profile != null or open_capture != null or connect != null)) return error.SymbolOptionsRequireLiveServer;
    if (debug_files.items.len > 0 and (open_profile != null or open_capture != null or connect != null)) return error.DebugFilesRequireLiveServer;
    if (allocation_helper != null and (connect != null or ssh != null or open_capture != null or open_profile != null or core_file != null)) return error.AllocationHelperRequiresLiveServer;
    const runtime_remote = runtime_agent != null or runtime_ssh != null or gdb_remote != null;
    if (gdb_remote != null and (runtime_agent != null or runtime_ssh != null or attach != null or launch.len != 0 or follow_forks or allocation_helper != null)) return error.GdbRemoteTargetBelongsToStub;
    if (runtime_remote and (connect != null or ssh != null or core_file != null or open_capture != null or open_profile != null)) return error.RuntimeAgentOptionConflict;
    if (ssh_config != null and runtime_ssh == null) return error.SshConfigRequiresRuntimeSsh;
    const remote_gui = connect != null or ssh != null;
    if (session_socket != null and (mcp or listen != null or remote_gui)) return error.SharedSessionOptionConflict;
    if (remote_gui and (headless or mcp or listen != null or open_capture != null or symbols != null or record_path != null or capture_out != null or profile_out != null)) return error.RemoteGuiOptionConflict;
    if (fetch_source and (runtime_agent == null and runtime_ssh == null or connect != null or ssh != null or core_file != null or open_profile != null or open_capture != null)) return error.SourceFetchRequiresRuntimeAgent;
    if (connect != null and (ssh != null or attach != null or launch.len > 0 or source != null or initial_breakpoint_count != 0 or scope_explicit or image_limit != null or image_total_limit != null)) return error.RemoteConnectTargetBelongsOnServer;
    if (ssh != null and attach == null and launch.len == 0) return error.RemoteSshRequiresTarget;
    if (listen != null and (!headless or !mcp)) return error.ListenRequiresHeadlessMcp;
    if (headless and !mcp and session_socket == null and observation_recipe == null and open_observation == null and static_decompile == null) return error.HeadlessRequiresMcp;
    if ((expected_start != null or start_profile) and (attach == null or runtime_remote or remote_gui)) return error.IdentityRequiresLocalAttach;
    if (attach != null and launch.len > 0) return error.ConflictingTargets;
    if (redot_debugger and (launch.len == 0 or attach != null or runtime_remote or remote_gui or core_file != null or open_capture != null or open_profile != null)) return error.RedotDebuggerRequiresLocalOwnedLaunch;
    if (open_capture != null and (attach != null or launch.len > 0 or initial_breakpoint_count != 0 or source != null)) return error.ConflictingTargets;
    if (open_pcap != null and (live_capture != null or attach != null or launch.len > 0 or core_file != null or open_profile != null or connect != null or ssh != null or gdb_remote != null or runtime_remote or compare_capture != null or open_observation != null or browse_observation != null or observation_recipe != null)) return error.OpenPcapOptionConflict;
    if (live_capture != null and (open_capture != null or open_mitmproxy != null or open_profile != null or core_file != null or connect != null or ssh != null or open_observation != null or browse_observation != null or observation_recipe != null)) return error.LiveCaptureOptionConflict;
    if (live_capture == null and (capture_tool != null or capture_ring_bytes != @import("capture/live.zig").default_ring_bytes)) return error.CaptureOptionRequiresLiveCapture;
    if (tls_key_log != null and open_pcap == null) return error.TlsKeyLogRequiresPcap;
    if (open_mitmproxy != null and (open_pcap != null or live_capture != null or tls_key_log != null or open_capture != null or attach != null or launch.len > 0 or core_file != null or open_profile != null or connect != null or ssh != null or gdb_remote != null or runtime_remote or compare_capture != null or open_observation != null or browse_observation != null or observation_recipe != null)) return error.OpenMitmproxyOptionConflict;
    if ((symbols != null or reanalyze) and open_capture == null) return error.SymbolsRequireArchive;
    // Before any thread starts: the policy is read without locks afterwards.
    if (redact) @import("redact.zig").enable();
    const preferences = if (config_path) |path| @import("preferences.zig").load(a, path) catch |err| {
        log.err(.session, "xodb: preferences failed: {s}; {s}\n", .{ @errorName(err), path });
        if (err == error.InvalidImageBudget) log.err(.session, "xodb: symbols.image_bytes and symbols.image_total_bytes take bytes from {d} to {d}\n", .{ snapshot.min_limit, snapshot.max_limit });
        return err;
    } else @import("preferences.zig").Preferences{};
    const ui_scale = ui_scale_cli orelse preferences.appearance.ui_scale;
    const ghidra_prestart = preferences.decompiler.prestart and !no_ghidra_prestart;
    // Off in either place is off.
    var languages = preferences.languages;
    inline for (@typeInfo(@TypeOf(languages)).@"struct".fields) |field| @field(languages, field.name) = @field(languages, field.name) and @field(languages_off, field.name);
    // The command line wins over the config file; both were range-checked.
    try snapshot.configure(image_limit orelse preferences.symbols.image_bytes, image_total_limit orelse preferences.symbols.image_total_bytes);
    if (static_decompile) |path| return @import("semq/static_image.zig").decompile(a, path, static_function);
    if (!headless) @import("appearance.zig").init(try @import("preferences.zig").themeSelection(a, &preferences, config_path, theme_path));
    try @import("target/runtime.zig").saveLaunchSignals();
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    // Saved profiles, captures and observations have no code to decompile.
    const archive_viewer = open_profile != null or open_capture != null or open_pcap != null or open_mitmproxy != null or open_observation != null or browse_observation != null;
    // The GUI starts the sidecar after its first frame: on a small or busy
    // machine the starter's javac and JVM warm-up compete with Vulkan setup.
    const sidecar_prestart = !remote_gui and !archive_viewer and ghidra_prestart;
    if (sidecar_prestart and headless) @import("semq/ghidra_sidecar.zig").prestart();
    if (remote_gui) {
        if (comptime build_options.gui) {
            var remote_args: std.ArrayList([:0]const u8) = .empty;
            if (connect != null and !std.meta.eql(languages, .{})) log.warn(.session, "xodb: the server owns the target; language views are turned off where it was started, not here\n", .{});
            const endpoint: @import("remote/client.zig").Endpoint = if (connect) |address| .{ .tcp = address } else blk: {
                try remote_args.appendSlice(a, &.{ remote_xodb, "--headless", "--mcp", "--agent-scope", if (scope_explicit) try a.dupeZ(u8, @tagName(agent_scope)) else "control" });
                if (log.value()) |setting| try remote_args.appendSlice(a, &.{ "--log", setting });
                // The server reads the target, so the switches go with it.
                if (!languages.enabled) try remote_args.appendSlice(a, &.{ "--language-off", "all" });
                inline for (@typeInfo(@TypeOf(languages).Name).@"enum".fields) |field| {
                    if (!@field(languages, field.name)) try remote_args.appendSlice(a, &.{ "--language-off", field.name });
                }
                if (source) |path| try remote_args.appendSlice(a, &.{ "--source", path });
                if (!ghidra_prestart) try remote_args.append(a, "--no-ghidra-prestart");
                if (redact) try remote_args.append(a, "--redact");
                for (debug_dirs.items) |path| try remote_args.appendSlice(a, &.{ "--debug-dir", path });
                for (source_maps.items) |spec| try remote_args.appendSlice(a, &.{ "--source-map", spec });
                for (debug_files.items) |path| try remote_args.appendSlice(a, &.{ "--debug-file", path });
                if (image_limit) |n| try remote_args.appendSlice(a, &.{ "--image-limit", try std.fmt.allocPrintSentinel(a, "{d}", .{n}, 0) });
                if (image_total_limit) |n| try remote_args.appendSlice(a, &.{ "--image-total-limit", try std.fmt.allocPrintSentinel(a, "{d}", .{n}, 0) });
                for (initial_breakpoints[0..initial_breakpoint_count]) |name| try remote_args.appendSlice(a, &.{ "--break", try a.dupeZ(u8, name) });
                if (attach) |pid| {
                    try remote_args.appendSlice(a, &.{ "--attach", try std.fmt.allocPrintSentinel(a, "{d}", .{pid}, 0) });
                } else {
                    try remote_args.append(a, "--");
                    try remote_args.appendSlice(a, launch);
                }
                break :blk .{ .ssh = .{ .host = ssh.?, .args = remote_args.items } };
            };
            const remote_label = try std.fmt.allocPrint(a, "{s} {s}", .{ if (connect != null) "TCP" else "SSH", connect orelse ssh.? });
            try @import("ui/remote.zig").run(endpoint, remote_label, font_path, ui_scale, frames, &quitting, startup_started);
            return;
        } else return error.GuiNotBuilt;
    }
    var connection = @import("remote/transport.zig").Stream{};
    defer connection.close();
    if (listen) |endpoint| connection = try @import("remote/transport.zig").acceptOne(endpoint, &quitting);
    const session = try a.create(Session);
    session.* = Session.init();
    session.persistent.cancel = &quitting;
    session.agent_scope = agent_scope;
    session.shared_jobs = !headless or session_socket != null;
    session.profile_defaults = preferences.profile.config();
    session.languages = languages;
    session.allocation_defaults = preferences.allocations;
    session.allocation_helper = allocation_helper;
    var redot_launch: std.ArrayList([:0]const u8) = .empty;
    if (redot_debugger) {
        const port = try session.redot.listen();
        try redot_launch.appendSlice(a, launch);
        try redot_launch.appendSlice(a, &.{ "--remote-debug", try std.fmt.allocPrintSentinel(a, "tcp://127.0.0.1:{d}", .{port}, 0) });
        launch = redot_launch.items;
        log.info(.redot, "xodb: Redot/Godot scene debugger listening on private loopback port {d}; waiting for owned pid\n", .{port});
    }
    if (gdb_remote != null) {
        session.gdb_map.symbols.executable = core_executable;
        session.modules.gdb_executable = core_executable;
    }
    session.static_analysis.toolchain_dir = static_analysis;
    session.static_analysis.warmup_enabled = ghidra_prestart;
    session.static_analysis.eager_library_bytes = preferences.decompiler.eager_library_bytes;
    if (static_analysis != null) {
        const swept = @import("semq/host.zig").sweepStale();
        if (swept > 0) log.info(.session, "xodb: removed {d} static analysis scratch director{s} of exited xodb processes\n", .{ swept, if (swept == 1) "y" else "ies" });
    }
    var remote_destroyed = false; // Read only after the remote owner finishes.
    defer if (!remote_destroyed) session.deinit();
    if (live_capture) |interface| {
        const tool = capture_tool orelse @import("capture/live.zig").defaultTool();
        session.live_capture = try @import("capture/live.zig").Live.start(std.heap.page_allocator, tool, interface, capture_ring_bytes);
        const version = session.live_capture.?.version;
        log.info(.session, "xodb: live capture started with {s} {d}.{d}; ring limit {d} bytes; it stops with this session\n", .{ @tagName(version.producer), version.major, version.minor, capture_ring_bytes });
    }
    // Bind before any launch/attach: a conflicting endpoint cannot touch a target.
    var shared: ?SharedSession = if (session_socket) |path| try SharedSession.init(path, source, redact) else null;
    defer if (shared) |*endpoint| endpoint.deinit();
    // First native ownership slice: ordinary live debugger windows. Retained
    // offline views and the separate scene-debugger adapter keep their own
    // lifecycle until their publication contracts are migrated.
    const native_owner = !headless and !runtime_remote and !redot_debugger and
        (attach != null or launch.len > 0) and core_file == null and
        open_capture == null and open_profile == null and open_pcap == null and
        open_mitmproxy == null and open_observation == null and browse_observation == null and observation_recipe == null;
    const async_remote_start = runtime_remote or native_owner;
    var remote_transport: std.ArrayList([:0]const u8) = .empty;
    if (!async_remote_start) if (gdb_remote) |endpoint| try session.target.connectGdbRemote(endpoint);
    if (runtime_agent != null or runtime_ssh != null) {
        const agent = runtime_agent orelse "xodb-agent";
        if (runtime_ssh) |host| {
            try remote_transport.appendSlice(a, &.{ "ssh", "-T", "-o", "BatchMode=yes" });
            if (ssh_config) |path| try remote_transport.appendSlice(a, &.{ "-F", path });
            // Retain a remote shell to translate a signal into 128 + signo.
            // SSH otherwise collapses a directly signalled agent to exit 255.
            // SSH does not carry the environment, so the log setting rides in the command.
            const agent_command = if (log.value()) |setting|
                try @import("remote/transport.zig").shellCommand(a, &.{ "env", try std.fmt.allocPrintSentinel(a, "XODB_LOG={s}", .{setting}, 0), agent, "--stdio" })
            else
                try @import("remote/transport.zig").shellCommand(a, &.{ agent, "--stdio" });
            const command = try std.fmt.allocPrintSentinel(a, "({s}); xodb_status=$?; exit \"$xodb_status\"", .{agent_command}, 0);
            try remote_transport.appendSlice(a, &.{ "--", host, command });
        } else try remote_transport.appendSlice(a, &.{ agent, "--stdio" });
        if (!async_remote_start) try session.target.connectRemote(remote_transport.items);
    }
    var tree = ProcessTree{ .limit = process_limit };
    tree.init(session);
    defer if (!remote_destroyed) tree.deinit();
    session.debug_files.automatic = preferences.symbols.automatic;
    session.debug_files.auto_file_limit = preferences.symbols.auto_file_bytes;
    session.debug_files.auto_total_limit = preferences.symbols.auto_total_bytes;
    for (debug_dirs.items) |path| try session.debug_files.addRoot(path);
    for (source_maps.items) |spec| try session.source_maps.add(spec);
    session.fetch_source = fetch_source;
    for (debug_files.items) |path| session.debug_files.add(path) catch |err| {
        log.err(.session, "xodb: debug file failed: {s}; {s}\n", .{ @errorName(err), path });
        if (err == error.BinarySnapshotLimit) log.err(.session, "xodb: image budget is {d} MiB per image and {d} MiB in total (--image-limit, --image-total-limit)\n", .{ snapshot.per_image_limit >> 20, snapshot.total_limit >> 20 });
        return err;
    };
    defer if (!remote_destroyed) exportProfileOnExit(session, profile_out);
    defer if (!remote_destroyed) if (record_path) |path| session.saveInvestigations(path) catch |err| log.err(.session, "Evidence export failed: {s}\n", .{@errorName(err)});
    if (core_file) |path| try session.openCore(path, core_executable);
    if (open_capture) |path| try session.openArchive(path, symbols, reanalyze);
    if (open_pcap) |path| try openPcap(session, path, open_capture, tls_key_log);
    if (open_mitmproxy) |path| try openMitmproxy(session, path);
    if (open_profile) |path| try session.openImported(path);
    if (open_frames) |path| try session.openFrames(path);
    if (compare_capture) |path| session.comparison = try @import("profile/comparison.zig").Job.start(path, open_capture.?);
    if (!async_remote_start) {
        if (attach) |pid| {
            if (expected_start) |ticks| try @import("model/process_identity.zig").validate(.{ .pid = pid, .start = ticks });
            const started = linux.now();
            log.info(.session, "xodb: attaching to pid={d}\n", .{pid});
            session.target.attach(pid) catch |err| {
                log.err(.session, "xodb: attach failed: {s}; pid={d} elapsed_ms={d}\n", .{ @errorName(err), pid, (linux.now() -| started) / 1_000_000 });
                return err;
            };
            if (expected_start) |ticks| @import("model/process_identity.zig").validate(.{ .pid = pid, .start = ticks }) catch |err| {
                session.target.detach() catch {};
                return err;
            };
            if (start_profile) {
                _ = try session.startProfile(.{ .frequency_hz = 99, .duration_ms = 10_000 });
                try session.continueExecution(.human);
            }
            log.info(.session, "xodb: attached pid={d} threads={d} state={s} elapsed_ms={d}\n", .{ pid, session.target.snapshot().thread_count, @tagName(session.target.snapshot().state), (linux.now() -| started) / 1_000_000 });
        }
        if (launch.len > 0) try session.launch(launch);
        if (follow_forks) try session.target.setFollowProcesses(true);
        for (initial_breakpoints[0..initial_breakpoint_count]) |name| {
            _ = try session.breakSymbol(name);
        }
    }
    if (!async_remote_start) if (observation_recipe) |path| {
        try @import("observe/cli.zig").run(a, session, path, observation_out.?, observation_threshold, &quitting);
        return;
    };
    // The GUI browser never waits here: the view reports the open worker.
    if (browse_observation) |path| try session.openObservation(path);
    if (open_observation) |path| {
        try @import("observe/cli.zig").open(a, session, path, observation_threshold, mcp or shared != null, &quitting);
        if (!mcp and shared == null) return;
    }
    const server = try a.create(Server);
    const private_transport: @import("mcp/evidence.zig").Transport = if (listen != null) .listen else if (runtime_remote) .remote else .stdio;
    server.* = .{
        .source_path = source,
        .overview_shared = if (shared) |*endpoint| endpoint.collector() else null,
        .private_access = .init(private_transport, redact),
    };
    // --redact: the system tools (processes, connections, fds, memory maps)
    // also apply the overview's own rules: other accounts, command lines.
    if (redact) (server.overview_shared orelse &server.overview).redact = true;
    if (listen != null) {
        server.input_fd = connection.fd;
        server.output_fd = connection.fd;
    }
    if (mcp) try server.init();
    defer if (mcp) server.deinit();
    if (headless) {
        if (runtime_remote) {
            var startup = RemoteStartup{ .session = session, .gdb = gdb_remote, .transport = remote_transport.items, .attach = attach, .launch = launch, .follow = follow_forks, .breakpoints = initial_breakpoints[0..initial_breakpoint_count], .observation = if (observation_recipe) |path| .{ .allocator = a, .path = path, .output = observation_out.?, .threshold = observation_threshold } else null, .report_attach = true };
            var shutdown = RemoteShutdown{ .tree = &tree, .session = session, .destroyed = &remote_destroyed, .capture_out = capture_out, .profile_out = profile_out, .record_path = record_path, .startup = &startup };
            const owner = try @import("model/remote_worker.zig").Worker.start(&tree, .{
                .connection = 1,
                .bootstrap = .{ .context = &startup, .run = RemoteStartup.run },
                .run_once = if (observation_recipe != null) .{ .context = &startup, .run = RemoteStartup.observe } else null,
                .shutdown = .{ .context = &shutdown, .run = RemoteShutdown.run },
                .test_directory = @import("model/remote_test.zig").Probes.environment(),
                .server = if (mcp) server else null,
                .endpoint = if (shared) |*endpoint| endpoint else null,
                .source = source,
            });
            defer owner.destroy();
            var startup_input_closed = false;
            while (quitting == 0 and !owner.done.load(.acquire) and !owner.stopping.load(.acquire)) {
                if (owner.startup_error.load(.acquire) != 0) break;
                // Inspect closure only; buffered MCP requests still belong to
                // the owner. Once connected, its normal EOF/drain path applies.
                if (mcp and !owner.connected.load(.acquire) and startupInputClosed(server.input_fd)) {
                    startup_input_closed = true;
                    break;
                }
                _ = c.usleep(20000);
            }
            owner.join();
            const startup_error = owner.startup_error.load(.acquire);
            if (quitting == 0 and !startup_input_closed and startup_error != 0) return @errorFromInt(startup_error);
            if (owner.failure) |err| return err;
            return;
        }
        while (quitting == 0) {
            try tree.poll();
            if (mcp) {
                try server.overviewTick();
                try server.pump(session);
                if (server.closed and server.queued == 0) break;
            }
            if (shared) |*endpoint| try endpoint.pump(session);
            _ = c.usleep(2000);
        }
        try finishRequestedArchive(session, capture_out);
        return;
    }
    if (comptime build_options.gui) {
        var window = Window{ .scale_override = ui_scale };
        try window.init();
        defer window.deinit();
        var renderer = Renderer{};
        defer renderer.deinit();
        var recovery = @import("render/recovery.zig").Recovery{};
        const font = try a.create(Font);
        font.* = .{};
        try font.initSelected(font_path, @import("build_options").font_path ++ "");
        defer font.deinit();
        var workspaces: [@import("model/process_tree.zig").maximum]?*Workspace = @splat(null);
        workspaces[0] = try a.create(Workspace);
        workspaces[0].?.* = .{ .density = preferences.appearance.density, .thread_list = .{ .hide_internal = hide_wine_threads orelse preferences.wine.hide_internal_threads }, .redot_panel = .{ .look = preferences.galaxy } };
        var workspace = workspaces[0].?;
        defer for (workspaces) |entry| if (entry) |view| view.deinit();
        var last_process: u64 = 1;
        var last_tree_revision: u64 = 0;
        workspace.show_profile = open_capture != null or open_pcap != null or open_mitmproxy != null or live_capture != null;
        workspace.logical_frames.open = open_frames != null;
        workspace.comparison.open = compare_capture != null;
        workspace.invocations.open = browse_observation != null;
        workspace.invocations.threshold_ns = observation_threshold;
        if (open_capture != null) workspace.status = "Opening capture archive";
        if (core_file != null) workspace.status = "Read-only core dump; execution and mutation are disabled";
        var archive_status: [512]u8 = undefined;
        var archive_completed_id: u64 = 0;
        var archive_status_time: u64 = 0;
        if (runtime_remote or native_owner) {
            const first_workspace = workspaces[0].?;
            var incarnation: u64 = 1;
            var protocol_server: ?*Server = if (mcp) server else null;
            var startup = RemoteStartup{ .session = session, .gdb = gdb_remote, .transport = remote_transport.items, .attach = attach, .launch = launch, .follow = follow_forks, .breakpoints = initial_breakpoints[0..initial_breakpoint_count], .expected_start = expected_start, .start_profile = start_profile, .report_attach = native_owner };
            while (true) {
                var shutdown = RemoteShutdown{ .tree = &tree, .session = session, .destroyed = &remote_destroyed, .capture_out = if (incarnation == 1) capture_out else null, .profile_out = if (incarnation == 1) profile_out else null, .record_path = if (incarnation == 1) record_path else null };
                const reconnect = lifecycle: {
                    const owner = try @import("model/remote_worker.zig").Worker.start(&tree, .{
                        .connection = incarnation,
                        .local = native_owner,
                        .bootstrap = .{ .context = &startup, .run = RemoteStartup.run },
                        .shutdown = .{ .context = &shutdown, .run = RemoteShutdown.run },
                        .trace = window.input.trace,
                        .test_directory = @import("model/remote_test.zig").Probes.environment(),
                        .server = protocol_server,
                        .endpoint = if (shared) |*endpoint| endpoint else null,
                        .source = source,
                        .initial_view = .{ .process = 1, .selection = .{ .tid = 0 }, .request_id = 0, .kind = .debugger },
                    });
                    defer owner.destroy();
                    break :lifecycle try remoteGui(owner, &window, &renderer, font, &workspaces, frames, startup_started, mcp, sidecar_prestart);
                };
                if (!reconnect) return;
                if (!remote_destroyed or session.target.handle != null) return error.RemoteReadersStillActive;
                // Recreate the listener as well as peers: even a not-yet-
                // accepted old socket must not submit into the new session.
                if (shared) |*endpoint| {
                    endpoint.deinit();
                    shared = null;
                    shared = try SharedSession.init(session_socket.?, source, redact);
                }
                // Stdio cannot identify a new peer. Terminate that channel;
                // shared clients may connect again and acquire a new lease.
                if (protocol_server) |old| {
                    old.closed = true;
                    // Keep descriptors 0/1 occupied. Once freed, the next
                    // pipe or socket (the new cancellation wake, a transport)
                    // would take those numbers, and any stray stdout write
                    // or stdin read in this process would then land in it.
                    _ = c.fcntl(old.output_fd, c.F_SETFL, old.stdout_flags);
                    const sink = c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC);
                    if (sink >= 0) {
                        _ = c.dup2(sink, old.input_fd);
                        if (old.output_fd != old.input_fd) _ = c.dup2(sink, old.output_fd);
                        if (sink != old.input_fd and sink != old.output_fd) _ = c.close(sink);
                    } else {
                        _ = c.close(old.input_fd);
                        if (old.output_fd != old.input_fd) _ = c.close(old.output_fd);
                    }
                    old.input_fd = -1;
                    old.output_fd = -1;
                    protocol_server = null;
                }
                for (&workspaces, 0..) |*entry, index| if (entry.*) |view| {
                    view.deinit();
                    if (index != 0) std.heap.page_allocator.destroy(view);
                    entry.* = null;
                };
                workspaces[0] = first_workspace;
                workspaces[0].?.* = .{ .density = preferences.appearance.density, .thread_list = .{ .hide_internal = hide_wine_threads orelse preferences.wine.hide_internal_threads }, .redot_panel = .{ .look = preferences.galaxy } };
                session.* = Session.init();
                remote_destroyed = false;
                session.persistent.cancel = &quitting;
                session.agent_scope = .observe;
                session.shared_jobs = true;
                session.profile_defaults = preferences.profile.config();
                session.allocation_defaults = preferences.allocations;
                session.allocation_helper = allocation_helper;
                if (gdb_remote != null) {
                    session.gdb_map.symbols.executable = core_executable;
                    session.modules.gdb_executable = core_executable;
                }
                session.static_analysis.toolchain_dir = static_analysis;
                session.static_analysis.warmup_enabled = ghidra_prestart;
                session.static_analysis.eager_library_bytes = preferences.decompiler.eager_library_bytes;
                session.debug_files.automatic = preferences.symbols.automatic;
                session.debug_files.auto_file_limit = preferences.symbols.auto_file_bytes;
                session.debug_files.auto_total_limit = preferences.symbols.auto_total_bytes;
                for (debug_dirs.items) |path| try session.debug_files.addRoot(path);
                for (source_maps.items) |spec| try session.source_maps.add(spec);
                for (debug_files.items) |path| try session.debug_files.add(path);
                session.fetch_source = fetch_source;
                tree = .{ .limit = process_limit };
                tree.init(session);
                startup.initial_actions = false;
                incarnation = std.math.add(u64, incarnation, 1) catch return error.ConnectionIncarnationExhausted;
                window.dirty = true;
            }
        }
        if (source) |path| try workspace.loadSource(path);
        var rendered: u64 = 0;
        var last_generation: u64 = std.math.maxInt(u64);
        var last_frame = linux.now();
        var last_profile_revision: u64 = 0;
        var last_profile_id: u64 = 0;
        var last_language_revision: u64 = 0;
        var last_redot_revision: u64 = 0;
        var last_language_watch_revision: u64 = 0;
        var last_compatibility_revision: u64 = 0;
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
                workspaces[tree.selected].?.* = .{ .density = preferences.appearance.density, .thread_list = .{ .hide_internal = hide_wine_threads orelse preferences.wine.hide_internal_threads }, .redot_panel = .{ .look = preferences.galaxy } };
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
                try server.overviewTick();
                try server.pump(session);
                if (server.closed and server.queued == 0) break;
            }
            if (shared) |*endpoint| try endpoint.pump(session);
            const fd_state = (server.overview_shared orelse &server.overview).fdEventState();
            if (workspace.fd_event_state != fd_state) {
                workspace.fd_event_state = fd_state;
                window.dirty = true;
            }
            phase_started = linux.now();
            if (shared != null and workspace.shared_clients == null) workspace.shared_clients = 0;
            workspace.input(&window, active);
            if (shared) |*endpoint| {
                if (workspace.shared_scope_changed) {
                    try endpoint.revoke();
                    workspace.shared_scope_changed = false;
                }
                const ownership = try endpoint.state(session);
                const owner: ?u64 = if (ownership.controller == 0) null else ownership.controller;
                if (workspace.shared_clients != ownership.peer_count or workspace.shared_controller != owner) window.dirty = true;
                workspace.shared_clients = ownership.peer_count;
                workspace.shared_controller = owner;
            }
            if (tree.active() != active) continue;
            if (last_compatibility_revision != active.compatibility.revision) {
                last_compatibility_revision = active.compatibility.revision;
                window.dirty = true;
            }
            if (last_language_watch_revision != active.language_watches.revision) {
                last_language_watch_revision = active.language_watches.revision;
                window.dirty = true;
            }
            if (last_language_revision != active.language_tabs.revision) {
                last_language_revision = active.language_tabs.revision;
                window.dirty = true;
            }
            if (last_redot_revision != active.redot.revision) {
                last_redot_revision = active.redot.revision;
                window.dirty = true;
            }
            reportSlow("workspace input/inspection", phase_started);
            if (window.closing or quitting != 0) break;
            const current = linux.now();
            const allocation_state = if (active.allocations.capture) |capture| capture.state else null;
            const allocations_changed = active.allocations.serial != last_allocation_serial or allocation_state != last_allocation_state or
                (if (active.allocations.capture) |capture| capture.revision != last_allocation_revision and current -| last_frame >= 250_000_000 else false);
            const profile_changed = if (active.profile) |capture| (capture.id != last_profile_id or capture.revision != last_profile_revision) and current -| last_frame >= 250_000_000 else false;
            const animation_due = workspace.animating and (!workspace.redot_panel.moving() or current -| last_frame >= 33_333_334);
            if ((if (active.imported) |state| state.serial != last_import_serial else false) or active.recorded_views.serial != last_view_serial or allocations_changed or profile_changed or window.dirty or animation_due or active.target.snapshot().generation != last_generation or frames > 0 or current - last_frame > 1_000_000_000) {
                if (current < recovery.retry_at) continue;
                if (!recovery.ready) {
                    phase_started = linux.now();
                    if (!try recovery.init(&renderer, &window, current)) {
                        if (recovery.last_error) |err| workspace.status = @errorName(err);
                        continue;
                    }
                    reportSlow("Vulkan initialization", phase_started);
                    font.dirty = true;
                }
                const presented = renderFrame(&renderer, font, workspace, &window, active) catch |err| {
                    workspace.status = @errorName(err);
                    log.err(.render, "Frame failed: {s}; recreating renderer, target retained\n", .{@errorName(err)});
                    // A failed submit may leave the frame fence unsignalled. Recreate
                    // the renderer instead of waiting on that fence next frame.
                    recovery.lost(&renderer, current);
                    continue;
                };
                window.dirty = !presented;
                if (!presented) continue;
                if (rendered == 0) {
                    @import("startup.zig").report(startup_started, mcp);
                    if (sidecar_prestart) @import("semq/ghidra_sidecar.zig").prestart();
                }
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
        log.info(.session, "xodb: {d} frames, clean shutdown (reason={s}, signal={d})\n", .{ rendered, reason, quitting });
    }
}
/// The live family belongs exclusively to the worker for this loop's lifetime.
/// The frame thread receives no Session, Tree, Server or Endpoint pointer.
fn remoteGui(owner: *@import("model/remote_worker.zig").Worker, window: *Window, renderer: *Renderer, font: *Font, workspaces: *[@import("model/process_tree.zig").maximum]?*Workspace, frames: usize, startup_started: u64, mcp: bool, sidecar_prestart: bool) !bool {
    var frontend = @import("ui/remote_workspace.zig").Frontend{ .owner = owner };
    defer frontend.deinit();
    // All stack-owned model/server/endpoint storage remains alive while the
    // owner drains its readers and reaps its transport. Never join a live
    // owner from a frame, including an early renderer/window error.
    defer finishRemoteOwner(owner, window);
    const rt = @import("target/runtime.zig").c;
    rt.xrt_remote_io_guard_strict(comptime @import("builtin").mode == .Debug);
    rt.xrt_remote_io_guard(true);
    defer {
        rt.xrt_remote_io_guard(false);
        rt.xrt_remote_io_guard_strict(false);
    }
    var workspace = workspaces[0].?;
    workspace.status = if (owner.options.local) "Starting local target" else if (owner.options.connection == 1) "Connecting; Ctrl+Shift+R starts a fresh connection" else "Reconnecting; target continuity and prior control outcomes are unconfirmed";
    var reconnect = false;
    defer renderer.deinit();
    var renderer_ready = false;
    var renderer_started = false;
    var render_retry: u64 = 0;
    var rendered: usize = 0;
    var last_frame = linux.now();
    var confirmed_connection = false;
    while (!window.closing and quitting == 0 and !owner.done.load(.acquire) and !owner.stopping.load(.acquire)) {
        try window.pump(window.input.timeoutMs(linux.now(), 8));
        if (window.closing or quitting != 0) break;
        window.input.tick(linux.now());
        if (window.input.count > 0) window.dirty = true;
        const keys = @import("platform/input.zig");
        for (0..window.input.count) |offset| {
            const event = &window.input.queue[(window.input.head + offset) % keys.capacity];
            if (event.kind == .press and event.mods.ctrl and !event.mods.alt and !event.mods.super and event.shortcut == 'r') {
                if (event.mods.shift) {
                    if (!owner.options.local) reconnect = true;
                } else {
                    frontend.invalidateInspection();
                }
                event.* = .{ .kind = .release };
            }
        }
        if (reconnect) break;
        const startup_error = owner.startup_error.load(.acquire);
        if (startup_error != 0) {
            workspace.status = std.fmt.bufPrint(&workspace.presentation_status, "{s}: {s}{s}", .{ if (owner.options.local) "Local startup failed" else "Connection unavailable", @errorName(@errorFromInt(startup_error)), if (owner.options.local) "" else "; Ctrl+Shift+R reconnects" }) catch "Session unavailable";
        }
        frontend.pump();
        if (try frontend.take()) {
            const process = frontend.header.process;
            if (process == 0 or process > workspaces.len) return error.InvalidProcess;
            const index: usize = @intCast(process - 1);
            if (workspaces[index] == null) {
                workspaces[index] = try std.heap.page_allocator.create(Workspace);
                workspaces[index].?.* = .{};
            }
            if (workspace != workspaces[index].?) frontend.invalidateInspection();
            workspace = workspaces[index].?;
            frontend.present(workspace, window);
            if (!confirmed_connection) {
                workspace.status = if (owner.options.local) "Local target ready; Ctrl+R retries inspection" else if (owner.options.connection == 1) "Connected; Ctrl+R retries inspection; Ctrl+Shift+R reconnects" else "Fresh connection; previous target and control outcomes remain unconfirmed";
                confirmed_connection = true;
            }
        }
        workspace.input(window, &frontend);
        frontend.inspect(workspace, window);
        frontend.pump();
        if (window.closing or quitting != 0) break;
        const now = linux.now();
        if (!window.dirty and !workspace.animating and frames == 0 and now -| last_frame < std.time.ns_per_s) continue;
        if (now < render_retry) continue;
        if (!renderer_ready) {
            renderer.init(window) catch |err| {
                if (!renderer_started and (err == error.VulkanDeviceNotFound or err == error.VulkanDeviceCannotPresent)) return err;
                workspace.status = @errorName(err);
                log.err(.render, "Renderer initialization failed: {s}; retrying, target retained\n", .{@errorName(err)});
                render_retry = now + std.time.ns_per_s;
                continue;
            };
            renderer_ready = true;
            renderer_started = true;
            font.dirty = true;
        }
        const presented = renderFrame(renderer, font, workspace, window, &frontend) catch |err| {
            workspace.status = @errorName(err);
            log.err(.render, "Frame failed: {s}; recreating renderer, target retained\n", .{@errorName(err)});
            renderer.deinit();
            renderer_ready = false;
            render_retry = now + std.time.ns_per_s;
            continue;
        };
        window.dirty = !presented;
        if (!presented) continue;
        if (rendered == 0) {
            @import("startup.zig").report(startup_started, mcp);
            if (sidecar_prestart) @import("semq/ghidra_sidecar.zig").prestart();
        }
        last_frame = now;
        rendered += 1;
        if (window.input.trace) log.info(.runtime, "xodb: remote frame={d} publication={d} editor={s} preparations={d}\n", .{ rendered, if (frontend.current) |p| p.value.revision else 0, if (workspace.activeEditor(&frontend) != null) "open" else "closed", owner.preparation_attempts.load(.monotonic) });
        if (frames > 0 and rendered >= frames) break;
    }
    finishRemoteOwner(owner, window);
    if (owner.failure) |err| return err;
    if (owner.options.local) {
        const startup_failure = owner.startup_error.load(.acquire);
        if (startup_failure != 0) return @errorFromInt(startup_failure);
    }
    const reason = if (quitting != 0) "signal" else if (window.closing) @tagName(window.close_reason) else if (frames > 0 and rendered >= frames) "frame_limit" else "owner_exit";
    if (owner.options.local) {
        log.info(.session, "xodb: {d} frames, clean shutdown (reason={s}, signal={d})\n", .{ rendered, reason, quitting });
    } else log.warn(.runtime, "xodb: {d} frames, remote owner closed (reason={s}, signal={d}); remote target cleanup unconfirmed\n", .{ rendered, reason, quitting });
    if (reconnect) {
        // Discard input collected while the old owner was quiescing.
        window.input.count = 0;
        log.info(.runtime, "xodb: remote incarnation={d} retired; no controls replayed\n", .{owner.options.connection});
    }
    return reconnect and !window.closing and quitting == 0;
}

fn finishRemoteOwner(owner: *@import("model/remote_worker.zig").Worker, window: *Window) void {
    owner.requestGracefulStop();
    while (!owner.done.load(.acquire)) {
        owner.cancelExpiredStop(linux.now());
        window.pumpDuringClose(8) catch {
            _ = c.usleep(8000);
        };
    }
    owner.joinCompleted();
}
fn startupInputClosed(fd: c_int) bool {
    var poll = c.pollfd{ .fd = fd, .events = c.POLLIN | c.POLLRDHUP, .revents = 0 };
    if (c.poll(&poll, 1, 0) > 0 and poll.revents & (c.POLLHUP | c.POLLRDHUP | c.POLLNVAL) != 0) {
        // A client may write its whole batch and close before startup ends.
        // Those requests are still owed an answer once the session connects.
        var unread: c_int = 0;
        return std.posix.errno(std.os.linux.ioctl(fd, std.os.linux.T.FIONREAD, @intFromPtr(&unread))) != .SUCCESS or unread <= 0;
    }
    // Empty redirected files have EOF without a pipe/socket hangup event.
    // lseek(SEEK_CUR) observes the position without consuming protocol bytes.
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return false;
    const position = c.lseek(fd, 0, c.SEEK_CUR);
    return position >= 0 and position >= stat.st_size;
}
const RemoteStartup = struct {
    session: *Session,
    gdb: ?[:0]const u8,
    transport: []const [:0]const u8,
    attach: ?i32,
    launch: []const [:0]const u8,
    follow: bool,
    breakpoints: []const []const u8,
    initial_actions: bool = true,
    observation: ?struct { allocator: std.mem.Allocator, path: [:0]const u8, output: [:0]const u8, threshold: ?u64 } = null,
    report_attach: bool = false, // headless prints the same attach lines as a local attach
    expected_start: ?u64 = null,
    start_profile: bool = false,
    completed: bool = false, // owner thread only: written here, read by RemoteShutdown
    fn run(context: *anyopaque, cancel: *@import("target/runtime.zig").c.struct_xrt_cancel) !void {
        const self: *RemoteStartup = @ptrCast(@alignCast(context));
        if (self.gdb) |endpoint| {
            log.debug(.runtime, "connecting to GDB remote stub {s}\n", .{endpoint});
            try self.session.target.connectGdbRemoteCancel(endpoint, cancel);
        } else if (self.transport.len > 0) {
            log.debug(.runtime, "starting runtime agent transport {s} ({d} arguments)\n", .{ self.transport[0], self.transport.len - 1 });
            try self.session.target.connectRemoteCancel(self.transport, cancel);
        }
        if (@import("target/runtime.zig").c.xrt_cancel_requested(cancel)) return error.RemoteCancelled;
        // A reconnect establishes a new transport only. Never replay attach,
        // launch, breakpoints, resume, or the old session's controller grant.
        if (!self.initial_actions) {
            self.completed = true;
            return;
        }
        if (self.attach) |pid| {
            if (self.expected_start) |ticks| try @import("model/process_identity.zig").validate(.{ .pid = pid, .start = ticks });
            const started = linux.now();
            if (self.report_attach) log.info(.session, "xodb: attaching to pid={d}\n", .{pid});
            self.session.target.attach(pid) catch |err| {
                if (self.report_attach) log.err(.session, "xodb: attach failed: {s}; pid={d} elapsed_ms={d}\n", .{ @errorName(err), pid, (linux.now() -| started) / 1_000_000 });
                return err;
            };
            if (self.expected_start) |ticks| @import("model/process_identity.zig").validate(.{ .pid = pid, .start = ticks }) catch |err| {
                self.session.target.detach() catch {};
                return err;
            };
            if (self.start_profile) {
                _ = try self.session.startProfile(.{ .frequency_hz = 99, .duration_ms = 10_000 });
                try self.session.continueExecution(.human);
            }
            if (self.report_attach) log.info(.session, "xodb: attached pid={d} threads={d} state={s} elapsed_ms={d}\n", .{ pid, self.session.target.snapshot().thread_count, @tagName(self.session.target.snapshot().state), (linux.now() -| started) / 1_000_000 });
        }
        if (self.launch.len > 0) try self.session.launch(self.launch);
        if (self.follow) try self.session.target.setFollowProcesses(true);
        for (self.breakpoints) |name| {
            _ = try self.session.breakSymbol(name);
        }
        self.completed = true;
    }
    fn observe(context: *anyopaque) !void {
        const self: *RemoteStartup = @ptrCast(@alignCast(context));
        const recipe = self.observation.?;
        try @import("observe/cli.zig").run(recipe.allocator, self.session, recipe.path, recipe.output, recipe.threshold, &quitting);
    }
};
const RemoteShutdown = struct {
    tree: *ProcessTree,
    session: *Session,
    destroyed: *bool,
    capture_out: ?[:0]const u8,
    profile_out: ?[:0]const u8,
    record_path: ?[:0]const u8,
    startup: ?*const RemoteStartup = null,
    fn run(context: *anyopaque) !void {
        const self: *RemoteShutdown = @ptrCast(@alignCast(context));
        defer self.destroyed.* = true;
        defer self.session.deinit();
        defer if (self.session.target.isRemote()) self.tree.deinitRemote() else self.tree.deinit();
        defer if (self.record_path) |path| self.session.saveInvestigations(path) catch |err| log.err(.session, "Evidence export failed: {s}\n", .{@errorName(err)});
        defer exportProfileOnExit(self.session, self.profile_out);
        // A startup that failed or was cancelled has nothing to archive: the
        // startup error, not a missing capture, is the result to report.
        const started = if (self.startup) |startup| startup.completed else true;
        try finishRequestedArchive(self.session, if (started) self.capture_out else null);
    }
};
fn exportProfileOnExit(session: *Session, profile_out: ?[:0]const u8) void {
    if (profile_out) |path| {
        if (session.profile) |capture| {
            if (capture.collector != null) capture.stop(.manual, linux.now());
            if (@import("profile/export.zig").save(capture, path, .{})) |result| {
                log.info(.profile, "xodb: exported profile #{d}: {d} samples, {d} bytes to {s}\n", .{ capture.id, result.samples, result.bytes, path });
            } else |err| log.err(.profile, "xodb: profile export failed: {s}; {s}\n", .{ @errorName(err), path });
        } else log.warn(.profile, "xodb: profile export skipped: no capture; {s}\n", .{path});
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
            log.err(.session, "xodb: requested archive save failed: {s}; {s}\n", .{ @errorName(err), destination });
            return err;
        };
        try session.finishArchive();
    }
}
fn reportSlow(phase: []const u8, started: u64) void {
    const elapsed = linux.now() -| started;
    if (elapsed >= 250_000_000) log.debug(.window, "slow {s}: {d} ms\n", .{ phase, elapsed / 1_000_000 });
}
/// `xodb --overview --headless`: the overview collector and its observer MCP
/// endpoints on the owner thread, without any window code.
fn overviewHeadless(args: []const [:0]const u8) !void {
    const options = @import("mcp/overview_serve.zig");
    for (args) |arg| if (std.mem.eql(u8, arg, "--help")) {
        std.debug.print("{s}", .{options.usage});
        return;
    };
    const o = try options.parse(args);
    if (o.redact) @import("redact.zig").enable();
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    // c.SIG_IGN translates to a misaligned function pointer on aarch64;
    // std's SIG.IGN is typed align(1) and compiles on every target.
    std.posix.sigaction(std.posix.SIG.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    const a = std.heap.c_allocator;
    var collector: @import("model/system.zig").Collector = .{ .redact = o.redact, .fd_scope = o.graph_pids[0..o.graph_count], .fast_ns = o.interval_ms * 1_000_000 };
    collector.capture.mode = .headless;
    defer collector.deinit();
    const session = try a.create(Session);
    defer a.destroy(session);
    session.* = Session.init();
    session.agent_scope = o.agent_scope;
    defer session.deinit();
    var shared: ?SharedSession = if (o.session_socket) |path| try SharedSession.init(path, null, o.redact) else null;
    defer if (shared) |*endpoint| endpoint.deinit();
    if (shared) |*endpoint| {
        endpoint.overview_shared = &collector;
        endpoint.overview_only = true;
    }
    const server = if (o.mcp) try a.create(Server) else null;
    defer if (server) |p| {
        p.deinit();
        a.destroy(p);
    };
    if (server) |p| {
        p.* = .{ .overview_shared = &collector, .overview_only = true, .private_access = .init(.stdio, o.redact) };
        try p.init();
    }
    log.info(.overview, "xodb: headless overview serving mcp={} socket={} interval_ms={d}\n", .{ o.mcp, o.session_socket != null, o.interval_ms });
    var capture: @import("model/system_capture.zig").Owner(Session) = .{ .collector = &collector, .root = session, .service = if (shared) |*endpoint| endpoint.service else null };
    defer capture.deinit(linux.now());
    if (shared) |*endpoint| endpoint.overview_capture = &capture.cpu;
    if (server) |p| p.overview_capture = &capture.cpu;
    var samples: u64 = 0;
    while (quitting == 0) {
        // The owner clock: history groups at their periods, plus requested groups.
        if (collector.tick(linux.now(), @import("model/system_history.zig").groups(), false) catch |err| blk: {
            log.warn(.overview, "xodb: headless overview sampling failed: {s}\n", .{@errorName(err)});
            break :blk false;
        }) samples += 1;
        if (shared) |*endpoint| try endpoint.pump(session);
        if (server) |p| {
            try p.pump(session);
            if (p.closed and p.queued == 0) break;
        }
        capture.stdio_alive = if (server) |p| !p.input_eof else false;
        capture.tick(linux.now());
        // Wake at once for stdin; peers and the clock are served every 20 ms.
        var fd = c.pollfd{ .fd = if (server) |p| (if (p.input_eof) -1 else p.input_fd) else -1, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&fd, 1, 20);
    }
    const reason = if (quitting != 0) "signal" else "mcp_eof";
    log.info(.overview, "xodb: headless overview {d} samples, history {d} rows {d} KiB, clean shutdown (reason={s})\n", .{ samples, collector.history.len, collector.history.bytes() / 1024, reason });
}

/// With a compositor the list also says which devices present and which is the display's.
fn vkList() !void {
    if (comptime !build_options.gui) return error.GuiNotBuilt;
    var window = Window{};
    const connected = if (window.init()) true else |_| false;
    defer if (connected) window.deinit();
    try Renderer.list(if (connected) &window else null);
}
fn renderFrame(renderer: *Renderer, font: *Font, workspace: *Workspace, window: *Window, context: anytype) !bool {
    var started = linux.now();
    _ = try font.setScale(window.scale());
    workspace.updateLayout(window);
    try font.setUiSize(if (workspace.compact) @import("look.zig").compact.font else @import("look.zig").normal.font);
    if (!try renderer.begin(window.width, window.height, window.scale())) return false;
    reportSlow("Vulkan frame begin", started);
    started = linux.now();
    (if (@TypeOf(context) == *Session) workspace.draw(renderer, font, window, context) else context.draw(workspace, renderer, font, window)) catch |err| {
        // Geometry exhaustion or allocation failure can leave a partial frame;
        // presenting it is safe and the next frame reports the error.
        workspace.status = @errorName(err);
        log.err(.render, "Workspace draw failed: {s}; target retained\n", .{@errorName(err)});
    };
    reportSlow("workspace draw/inspection", started);
    started = linux.now();
    const presented = try renderer.end(font);
    reportSlow("Vulkan submit/present", started);
    return presented;
}

/// Reads a pcap/pcapng file into the session's evidence stream. With a
/// capture archive, its ECTX section supplies the clock pairs and socket
/// tables for alignment and correlation; without one the stream is unaligned.
fn openPcap(session: *Session, path: [:0]const u8, capture: ?[:0]const u8, keylog_path: ?[:0]const u8) !void {
    const archive = @import("profile/archive.zig");
    const a = std.heap.page_allocator;
    const bytes = archive.readFile(a, path, archive.max_file_bytes, null) catch |err| {
        log.err(.session, "xodb: --open-pcap could not read the file: {s}\n", .{@errorName(err)});
        return err;
    };
    const stream = @import("evidence/stream.zig").Stream.open(a, bytes, std.fs.path.basename(path)) catch |err| {
        a.free(bytes);
        log.err(.session, "xodb: --open-pcap: {s}\n", .{@errorName(err)});
        return err;
    };
    errdefer stream.destroy();
    if (capture) |archive_path| {
        const xoc = try archive.readFile(a, archive_path, archive.max_file_bytes, null);
        defer a.free(xoc);
        if (try archive.evidenceContext(xoc)) |payload| try stream.attachContext(payload, try archive.usbEvidenceContext(xoc));
    }
    const loss = stream.loss();
    log.info(.session, "xodb: evidence stream {d}: {s} {d} records, {d} undecoded, {d} flows, file {s}, clock {s}; drops ifdrop={d} osdrop={d} epb={d}\n", .{ stream.id, @tagName(stream.parsed.format), stream.parsed.records.len, stream.undecoded, stream.flows.len, @tagName(stream.parsed.stop), @tagName(stream.mapping.state), loss.isb_ifdrop, loss.isb_osdrop, loss.epb_drops });
    var usb_stream: ?*@import("evidence/usb.zig").Stream = null;
    errdefer if (usb_stream) |derived| derived.destroy();
    if (try @import("evidence/usb.zig").Stream.open(a, stream)) |derived| {
        const usb_loss = derived.loss();
        log.info(.session, "xodb: USB evidence stream {d}: {d} URBs, {d} devices, {d} endpoints; malformed={d} unmatched={d} orphan={d} dropped={d}\n", .{ derived.id, derived.records.len, derived.devices.len, derived.endpoints.len, usb_loss.malformed, usb_loss.unmatched_submits, usb_loss.orphan_completions, usb_loss.derived_dropped });
        usb_stream = derived;
    }
    var tls_stream: ?*@import("evidence/tls.zig").Stream = null;
    errdefer if (tls_stream) |derived| derived.destroy();
    var dbus_stream: ?*@import("evidence/dbus.zig").Stream = null;
    errdefer if (dbus_stream) |derived| derived.destroy();
    if (try @import("evidence/dbus.zig").Stream.open(a, stream)) |derived| {
        log.info(.session, "xodb: D-Bus evidence stream {d}: {d} messages, {d} paired calls, {d} identities; malformed={d} orphan={d} pending={d} dropped={d}\n", .{ derived.id, derived.records.len, derived.paired, derived.identities.len, derived.malformed, derived.orphan_replies, derived.pending_calls, derived.derived_dropped + derived.pending_dropped });
        dbus_stream = derived;
    }
    if (keylog_path) |secret_path| {
        const keylog = try archive.readFile(a, secret_path, 16 * 1024 * 1024, null);
        defer {
            std.crypto.secureZero(u8, keylog);
            a.free(keylog);
        }
        const derived = try @import("evidence/tls.zig").Stream.open(a, stream, keylog);
        errdefer derived.destroy();
        log.info(.session, "xodb: TLS evidence stream {d}: {d} sessions, {d} authenticated records, {d} authentication failures, {d} retained records, {d} reassembly gaps; record_limit_hit={}\n", .{ derived.id, derived.sessions.len, blk: {
            var authenticated: u64 = 0;
            for (derived.sessions) |summary| authenticated += summary.records;
            break :blk authenticated;
        }, blk: {
            var failures: u64 = 0;
            for (derived.sessions) |summary| failures += summary.authentication_failures;
            break :blk failures;
        }, derived.records.len, derived.reassembly_gaps, derived.derived_limit_hit });
        tls_stream = derived;
    }
    var protocol_stream: ?*@import("evidence/protocol.zig").Stream = null;
    const candidate = try @import("evidence/protocol.zig").Stream.open(a, stream, if (tls_stream == null) 2 else 3);
    if (candidate.records.len == 0 and (usb_stream != null or dbus_stream != null)) {
        candidate.destroy();
    } else {
        protocol_stream = candidate;
        log.info(.session, "xodb: protocol evidence stream {d}: {d} HTTP/1 records, {d} DNS records, {d} reassembly gaps\n", .{ candidate.id, candidate.http_records, candidate.dns_records, candidate.reassembly_gaps });
    }
    errdefer if (protocol_stream) |derived| derived.destroy();
    session.tls_stream = tls_stream;
    session.protocol_stream = protocol_stream;
    session.usb_stream = usb_stream;
    session.dbus_stream = dbus_stream;
    session.evidence_stream = stream;
}

fn openMitmproxy(session: *Session, path: [:0]const u8) !void {
    const archive = @import("profile/archive.zig");
    const a = std.heap.page_allocator;
    const bytes = archive.readFile(a, path, archive.max_file_bytes, null) catch |err| {
        log.err(.session, "xodb: --open-mitmproxy could not read the file: {s}\n", .{@errorName(err)});
        return err;
    };
    const stream = @import("evidence/mitm.zig").Stream.open(a, bytes, std.fs.path.basename(path)) catch |err| {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
        log.err(.session, "xodb: --open-mitmproxy: {s}\n", .{@errorName(err)});
        return err;
    };
    log.info(.session, "xodb: mitmproxy evidence stream {d}: {d} flows, {d} unsupported, file {s}\n", .{ stream.id, stream.records.len, stream.unsupported, @tagName(stream.stop) });
    session.mitm_stream = stream;
}

test {
    std.testing.refAllDecls(@import("redot/protocol.zig"));
    std.testing.refAllDecls(@import("redact.zig"));
    std.testing.refAllDecls(@import("appearance.zig"));
    std.testing.refAllDecls(@import("remote/transport.zig"));
    std.testing.refAllDecls(@import("remote/client.zig"));
    std.testing.refAllDecls(@import("mcp/remote.zig"));
    std.testing.refAllDecls(@import("mcp/server.zig"));
    std.testing.refAllDecls(@import("preferences.zig"));
    std.testing.refAllDecls(@import("model/compatibility.zig"));
    std.testing.refAllDecls(@import("ui/thread_list.zig"));
    std.testing.refAllDecls(@import("profile/archive.zig"));
    std.testing.refAllDecls(@import("profile/linux_syscalls.zig"));
    std.testing.refAllDecls(@import("observe/context.zig"));
    std.testing.refAllDecls(@import("observe/calls.zig"));
    std.testing.refAllDecls(@import("observe/comparison.zig"));
    std.testing.refAllDecls(@import("observe/associations.zig"));
    std.testing.refAllDecls(@import("observe/association_job.zig"));
    std.testing.refAllDecls(@import("mcp/associations.zig"));
    std.testing.refAllDecls(@import("observe/perf.zig"));
    std.testing.refAllDecls(@import("observe/linux.zig"));
    std.testing.refAllDecls(@import("observe/archive.zig"));
    std.testing.refAllDecls(@import("observe/recipe.zig"));
    std.testing.refAllDecls(@import("mcp/exact.zig"));
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
    _ = @import("evidence/stream.zig");
    _ = @import("evidence/tls.zig");
    _ = @import("evidence/usb.zig");
    _ = @import("evidence/dbus.zig");
    _ = @import("evidence/mitm.zig");
    _ = @import("profile/net_context.zig");
    _ = @import("mcp/evidence.zig");
    _ = @import("profile/perf_test.zig");
    _ = @import("profile/recorded_view_test.zig");
    _ = @import("profile/user_state_test.zig");
    _ = @import("profile/sampled_test.zig");
    _ = @import("profile/pe_test.zig");
    _ = @import("profile/derived_test.zig");
    std.testing.refAllDecls(@import("profile/sample_state.zig"));
    std.testing.refAllDecls(@import("profile/unwind.zig"));
    if (build_options.gui) {
        std.testing.refAllDecls(@import("render/font.zig"));
        _ = @import("render/vk_select.zig");
        std.testing.refAllDecls(@import("platform/input.zig"));
        _ = @import("platform/window.zig");
        std.testing.refAllDecls(@import("ui/workspace.zig"));
        std.testing.refAllDecls(@import("ui/allocations.zig"));
        std.testing.refAllDecls(@import("ui/watch.zig"));
        _ = @import("ui/watch_test.zig");
        std.testing.refAllDecls(@import("ui/remote.zig"));
        std.testing.refAllDecls(@import("ui/timeline.zig"));
        std.testing.refAllDecls(@import("ui/capture_setup.zig"));
        std.testing.refAllDecls(@import("ui/capture_panel.zig"));
        _ = @import("ui/invocations.zig");
        _ = @import("ui/overview/theme.zig");
        _ = @import("ui/overview/model.zig");
        _ = @import("ui/overview/history.zig");
        _ = @import("ui/overview/draw.zig");
        _ = @import("ui/overview/replay.zig");
        _ = @import("ui/overview/sysstat.zig");
        _ = @import("ui/overview/view.zig");
        _ = @import("ui/overview/run.zig");
        _ = @import("ui/overview/options.zig");
        _ = @import("ui/overview/loop.zig");
        _ = @import("ui/overview/memmap.zig");
        _ = @import("ui/overview/deepmap.zig");
        _ = @import("ui/overview/fetch_panel.zig");
    }
    _ = @import("ui/overview/fetch.zig");
    _ = @import("ui/overview/fetch_bench.zig");
    _ = @import("ui/overview/png.zig");
    _ = @import("memdefrag/model.zig");
    _ = @import("memdefrag/vga.zig");
    _ = @import("memdefrag/dos.zig");
    _ = @import("memdefrag/tui.zig");
    std.testing.refAllDecls(@import("model/session.zig"));
    std.testing.refAllDecls(@import("model/memory.zig"));
    _ = @import("model/job_owner_test.zig");
    _ = @import("model/remote_source.zig");
    _ = @import("model/remote_owner.zig");
    _ = @import("model/remote_dispatch.zig");
    _ = @import("model/command.zig");
    _ = @import("mcp/commands.zig");
    _ = @import("model/remote_worker.zig");
    if (build_options.gui) _ = @import("ui/remote_workspace.zig");
    _ = @import("binary/tls.zig");
    _ = @import("language/gdscript.zig");
    _ = @import("semq/adapter.zig");
    _ = @import("semq/answer.zig");
    _ = @import("semq/host.zig");
    std.testing.refAllDecls(@import("mcp/static_analysis.zig"));
    std.testing.refAllDecls(@import("mcp/overview.zig"));
    std.testing.refAllDecls(@import("mcp/overview_serve.zig"));
    std.testing.refAllDecls(@import("model/system_history.zig"));
    _ = @import("target/process_test.zig");
    std.testing.refAllDecls(@import("model/modules.zig"));
    std.testing.refAllDecls(@import("binary/apk.zig"));
    std.testing.refAllDecls(@import("model/disassembly.zig"));
    std.testing.refAllDecls(@import("model/analysis_ir.zig"));
    std.testing.refAllDecls(@import("profile/export.zig"));
    std.testing.refAllDecls(@import("model/evaluate.zig"));
    std.testing.refAllDecls(@import("model/value_view.zig"));
    std.testing.refAllDecls(@import("debug/location.zig"));
    std.testing.refAllDecls(@import("debug/macho_unwind.zig"));
    std.testing.refAllDecls(@import("model/image_label.zig"));
}

test {
    _ = @import("profile/imported_test.zig");
}
