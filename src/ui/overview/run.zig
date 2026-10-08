//! `xodb --overview` entry: its own window and session, no debug target.
const std = @import("std");
const c = @import("../../c.zig").api;
const Window = @import("../../platform/wayland.zig").Window;
const Renderer = @import("../../render/vulkan.zig").Renderer;
const Font = @import("../../render/font.zig").Font;
const now = @import("../../target/linux.zig").now;
const m = @import("model.zig");
const themes = @import("theme.zig");
const vw = @import("view.zig");
const Replay = @import("replay.zig").Replay;
const Live = @import("sysstat.zig").Live;
const Collector = @import("../../model/system.zig").Collector;
const Shared = @import("../../mcp/shared.zig").Endpoint;
const Server = @import("../../mcp/server.zig").Server;
const Session = @import("../../model/session.zig").Session;

pub const usage =
    \\xodb --overview [--replay FILE] [--redact] [--theme NAME] [--panel NAME] [--interval-ms N] [--pause] [--frames N] [--font FILE]
    \\  A system overview window with no debug target: CPU, memory, disks, network,
    \\  connections, sensors, processes, users, services and packages. Unmeasured values
    \\  show their reason; nothing unmeasured is drawn as zero.
    \\  --replay FILE   collector JSON (one snapshot, or one per line) instead of the live system
    \\  --redact        hide hostname, users, addresses, mount points and command arguments
    \\  --theme NAME    dark, light, green, amber, blue or mono (builtin: prefix accepted)
    \\  --panel NAME    start on summary, performance, processes, memory, disk, disk_space,
    \\                  network, connections, power, system, users, services or apps
    \\  --interval-ms N sampling interval, 250..10000 (live default 500; processes refresh
    \\                  at 1 Hz; off Processes, per-process IO and fd counts wait until shown)
    \\  --session-socket PATH  share this live cache with observer-only MCP clients
    \\  --mcp           serve observer-only MCP on stdin/stdout alongside the live view
    \\  --pause         start paused (replay: show the last frame with full history)
    \\Keys: 1-9 0 Tab panels, arrows, / search, s sort, r reverse, v tree, L files, F profile, Enter debugger (all confirmed),
    \\      t theme, p pause, x redact (cannot be turned off), q quit. Mouse: click and wheel.
    \\
;

var quitting: c.sig_atomic_t = 0;
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}

pub const Options = struct {
    replay: ?[:0]const u8 = null,
    session_socket: ?[:0]const u8 = null,
    mcp: bool = false,
    redact: bool = false,
    theme: ?[]const u8 = null,
    panel: ?vw.Panel = null,
    interval_ms: ?u64 = null,
    paused: bool = false,
    frames: u64 = 0,
    font: [:0]const u8 = @import("build_options").font_path ++ "",
};

/// Parses overview arguments (args[0] is the program). Debugger options are
/// rejected: the overview has no target.
pub fn parse(args: []const [:0]const u8) !Options {
    var o = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--overview")) continue;
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
        const takes = [_][]const u8{ "--replay", "--theme", "--panel", "--interval-ms", "--frames", "--font", "--session-socket" };
        var known = false;
        for (takes) |t| known = known or std.mem.eql(u8, arg, t);
        if (!known) {
            std.debug.print("xodb: --overview does not accept {s}\n{s}", .{ arg, usage });
            return error.OverviewOptionConflict;
        }
        i += 1;
        if (i == args.len) return error.MissingArgument;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--replay")) o.replay = value;
        if (std.mem.eql(u8, arg, "--session-socket")) o.session_socket = value;
        if (std.mem.eql(u8, arg, "--theme")) {
            _ = themes.find(value) orelse return error.UnknownOverviewTheme;
            o.theme = value;
        }
        if (std.mem.eql(u8, arg, "--panel")) o.panel = std.meta.stringToEnum(vw.Panel, value) orelse return error.UnknownOverviewPanel;
        if (std.mem.eql(u8, arg, "--interval-ms")) {
            const ms = try std.fmt.parseInt(u64, value, 10);
            if (ms < 250 or ms > 10_000) return error.InvalidOverviewInterval;
            o.interval_ms = ms;
        }
        if (std.mem.eql(u8, arg, "--frames")) o.frames = try std.fmt.parseInt(u64, value, 10);
        if (std.mem.eql(u8, arg, "--font")) o.font = value;
    }
    if (o.replay != null and (o.mcp or o.session_socket != null)) return error.ReplayHasNoLiveSession;
    return o;
}

const Source = union(enum) {
    replay: Replay,
    live: Live,
};

pub fn main(args: []const [:0]const u8, startup_started: u64) !void {
    if (comptime !@import("build_options").gui) return error.GuiNotBuilt;
    for (args) |arg| if (std.mem.eql(u8, arg, "--help")) {
        std.debug.print("{s}", .{usage});
        return;
    };
    const o = try parse(args);
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    const gpa = std.heap.c_allocator;
    var collector: Collector = .{ .redact = o.redact };
    defer collector.deinit();
    const session = try gpa.create(Session);
    defer gpa.destroy(session);
    session.* = Session.init();
    session.agent_scope = .observe;
    defer session.deinit();
    var shared: ?Shared = if (o.session_socket) |path| try Shared.init(path, null) else null;
    defer if (shared) |*endpoint| endpoint.deinit();
    if (shared) |*endpoint| {
        endpoint.overview_shared = &collector;
        endpoint.overview_only = true;
    }
    const server = if (o.mcp) try gpa.create(Server) else null;
    defer if (server) |p| {
        p.deinit();
        gpa.destroy(p);
    };
    if (server) |p| {
        p.* = .{ .overview_shared = &collector, .overview_only = true };
        try p.init();
        std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    }
    var source: Source = if (o.replay) |path| blk: {
        const bytes = readFile(gpa, path) catch |err| {
            std.debug.print("xodb: overview replay failed: {s}; {s}\n", .{ @errorName(err), path });
            return err;
        };
        defer gpa.free(bytes);
        break :blk .{ .replay = try Replay.load(gpa, bytes) };
    } else .{ .live = .{ .collector = &collector } };
    defer switch (source) {
        .replay => |*r| r.deinit(),
        .live => {},
    };
    var view = try vw.View.init(gpa);
    defer view.deinit();
    var layout: ?*@import("draw.zig").Layout = null;
    if (c.getenv("XODB_OVERVIEW_LAYOUT") != null) {
        layout = try gpa.create(@import("draw.zig").Layout);
        layout.?.* = .{};
        view.layout = layout;
    }
    defer if (layout) |l| gpa.destroy(l);
    var launcher: @import("actions.zig").Launcher = .{ .redact = o.redact };
    if (source == .live) {
        view.action_hook = launchAction;
        view.action_context = &launcher;
    }
    view.redact = o.redact;
    view.paused = o.paused;
    if (o.theme) |t| view.palette = themes.find(t).?;
    if (o.panel) |p| view.show(p);
    view.source_label = if (source == .replay) "REPLAY" else "live";
    view.owns_samples = source == .live;

    var window = Window{};
    try window.init();
    defer window.deinit();
    if (window.top) |top| {
        c.xdg_toplevel_set_title(top, "xodb overview");
        c.xdg_toplevel_set_app_id(top, "xodb-overview");
    }
    var renderer = Renderer{};
    defer renderer.deinit();
    const font = try gpa.create(Font);
    defer gpa.destroy(font);
    font.* = .{};
    try font.initMode(o.font, false);
    defer font.deinit();

    const interval = (o.interval_ms orelse if (source == .live) @as(u64, 500) else 1000) * 1_000_000;
    collector.fast_ns = interval;
    // The owner clock refreshes processes at 1 Hz, independently of MCP calls.
    var next_sample: u64 = 0;
    var shown_panel = view.panel;
    // Animate transitions only when samples are far enough apart to see them;
    // at 4 Hz the samples themselves are the motion.
    view.ease_ns = if (interval >= 1_000_000_000 and view.panel != .processes) 150_000_000 else 0;
    // A replay fills history from every frame so graphs are complete at once.
    if (source == .replay) {
        for (0..source.replay.frames.len) |_| view.accept(source.replay.advance(), now());
        view.sample_time = 0;
        next_sample = now() + interval;
    }
    const frame_gap: u64 = 33_000_000;
    var ready = false;
    var retry: u64 = 0;
    var rendered: u64 = 0;
    var last_frame: u64 = 0;
    while (!window.closing and quitting == 0) {
        const t = now();
        // Eases redraw at 30 fps; idle waits for the next sample or input.
        const wait_ms: i32 = if (window.dirty) 4 else if (view.animating(t)) @intCast(@max(1, (last_frame + frame_gap -| t) / 1_000_000)) else @intCast(@min(if (shared != null or server != null) @as(u64, 20) else 250, (next_sample -| t) / 1_000_000 + 1));
        try window.pump(window.input.timeoutMs(t, wait_ms));
        window.input.tick(now());
        view.input(&window, now());
        if (window.closing or quitting != 0) break;
        const current = now();
        view.roll(current);
        launcher.redact = view.redact;
        if (launcher.poll()) view.setStatus("Process action failed; check target identity and access", .{}, current);
        // A newly shown panel gets its groups at once rather than at the next slow tick.
        if (view.panel != shown_panel) {
            shown_panel = view.panel;
            view.ease_ns = if (interval >= 1_000_000_000 and view.panel != .processes) 150_000_000 else 0;
            next_sample = 0;
        }
        if (source == .live) {
            const started = vw.threadNs();
            collector.redact = view.redact;
            _ = collector.tick(current, if (view.paused) 0 else view.groups(true), view.panel == .processes) catch |err| blk: {
                view.setStatus("Sampling failed: {s}", .{@errorName(err)}, current);
                break :blk false;
            };
            view.sourceCost(vw.threadNs() -| started);
            if (shared) |*endpoint| try endpoint.pump(session);
            if (server) |p| try p.pump(session);
        }
        if (!view.paused and current >= next_sample) {
            const started = vw.threadNs();
            switch (source) {
                .replay => |*r| view.accept(r.advance(), current),
                .live => |*l| {
                    const sample = l.sample(gpa) catch |err| {
                        view.setStatus("Sampling failed: {s}", .{@errorName(err)}, current);
                        next_sample = current + interval;
                        continue;
                    };
                    view.accept(sample, current);
                },
            }
            view.sourceCost(vw.threadNs() -| started);
            next_sample = current + interval;
            window.dirty = true;
        } else if (view.paused) next_sample = @max(next_sample, current + 50_000_000);
        const eased = view.animating(current) and current -| last_frame >= frame_gap;
        if (!(window.dirty or eased or o.frames > 0 or current -| last_frame > 1_000_000_000)) continue;
        if (current < retry) continue;
        if (!ready) {
            renderer.init(&window) catch |err| {
                std.debug.print("xodb: overview renderer failed: {s}; retrying\n", .{@errorName(err)});
                retry = current + 1_000_000_000;
                continue;
            };
            ready = true;
            font.dirty = true;
        }
        const presented = frame(&renderer, font, &view, &window, current) catch |err| {
            std.debug.print("xodb: overview frame failed: {s}; recreating renderer\n", .{@errorName(err)});
            renderer.deinit();
            ready = false;
            retry = current + 1_000_000_000;
            continue;
        };
        window.dirty = !presented;
        if (!presented) continue;
        if (rendered == 0) @import("../../startup.zig").report(startup_started, o.mcp);
        last_frame = current;
        rendered += 1;
        if (o.frames > 0 and rendered >= o.frames) break;
    }
    const reason = if (quitting != 0) "signal" else if (window.closing) @tagName(window.close_reason) else "frame_limit";
    std.debug.print("xodb: overview {d} frames, {d} samples, clean shutdown (reason={s})\n", .{ rendered, view.samples, reason });
}

fn frame(r: *Renderer, font: *Font, view: *vw.View, window: *Window, t: u64) !bool {
    if (!try r.begin(window.width, window.height)) return false;
    view.frame(r, font, window, t) catch |err| {
        // A partial frame is safe to present; report and continue.
        view.setStatus("Draw failed: {s}", .{@errorName(err)}, t);
    };
    return r.end(font);
}

fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) ![]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.ReplayOpenFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG) return error.ReplayNotRegular;
    if (st.st_size < 0 or st.st_size > @import("replay.zig").max_bytes) return error.ReplayTooLarge;
    const bytes = try gpa.alloc(u8, @intCast(st.st_size));
    errdefer gpa.free(bytes);
    var n: usize = 0;
    while (n < bytes.len) {
        const got = c.read(fd, bytes.ptr + n, bytes.len - n);
        if (got < 0 and std.c._errno().* == c.EINTR) continue;
        if (got <= 0) return error.ReplayReadFailed;
        n += @intCast(got);
    }
    return bytes;
}

test "overview options reject debugger targets and bad values" {
    const ok = try parse(&.{ "xodb", "--overview", "--redact", "--theme", "builtin:green", "--panel", "disk_space", "--interval-ms", "250" });
    try std.testing.expect(ok.redact);
    try std.testing.expectEqual(vw.Panel.disk_space, ok.panel.?);
    try std.testing.expectEqual(@as(?u64, 250), ok.interval_ms);
    try std.testing.expectError(error.OverviewOptionConflict, parse(&.{ "xodb", "--overview", "--attach", "1" }));
    try std.testing.expectError(error.UnknownOverviewTheme, parse(&.{ "xodb", "--overview", "--theme", "neon" }));
    try std.testing.expectError(error.InvalidOverviewInterval, parse(&.{ "xodb", "--overview", "--interval-ms", "10" }));
    try std.testing.expectError(error.UnknownOverviewPanel, parse(&.{ "xodb", "--overview", "--panel", "flight" }));
}

fn launchAction(context: ?*anyopaque, request: @import("actions.zig").Request) !void {
    const launcher: *@import("actions.zig").Launcher = @ptrCast(@alignCast(context.?));
    try launcher.launch(request);
}
