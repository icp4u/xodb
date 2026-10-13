//! The overview's window loop and its replay entry. Nothing here refers to
//! the debug engine, a session, MCP or a collector: a live source (run.zig)
//! is handed in, and without one the overview replays a collector file.
const std = @import("std");
const c = @import("../../c_ui.zig").api;
const Window = @import("../../platform/window.zig").Window;
const Renderer = @import("../../render/vulkan.zig").Renderer;
const Font = @import("../../render/font.zig").Font;
const themes = @import("theme.zig");
const vw = @import("view.zig");
const Replay = @import("replay.zig").Replay;
const options = @import("options.zig");
const Options = options.Options;

pub var quitting: c.sig_atomic_t = 0;
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}
fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

/// `live` runs the overview on the live system; an entry without one (null)
/// only replays.
pub fn main(args: []const [:0]const u8, startup_started: u64, comptime live: ?fn (*const Options, u64) anyerror!void) !void {
    if (comptime !@import("build_options").gui) return error.GuiNotBuilt;
    for (args) |arg| if (std.mem.eql(u8, arg, "--help")) {
        std.debug.print("{s}", .{options.usage});
        return;
    };
    const o = try options.parse(args);
    _ = c.signal(c.SIGINT, onSignal);
    _ = c.signal(c.SIGTERM, onSignal);
    _ = c.signal(c.SIGHUP, onSignal);
    if (o.replay) |path| return replay(&o, path, startup_started);
    if (live) |run_live| return run_live(&o, startup_started);
    return error.OverviewNeedsReplay;
}

fn replay(o: *const Options, path: [:0]const u8, startup_started: u64) !void {
    const gpa = std.heap.c_allocator;
    var source = blk: {
        const bytes = readFile(gpa, path) catch |err| {
            std.debug.print("xodb: overview replay failed: {s}; {s}\n", .{ @errorName(err), path });
            return err;
        };
        defer gpa.free(bytes);
        break :blk try Replay.load(gpa, bytes);
    };
    defer source.deinit();
    var view = try vw.View.init(gpa);
    defer view.deinit();
    try run(o, gpa, &view, &source, startup_started);
}

/// Opens the window and runs until it closes. `source` is a *Replay, or a
/// live source with `prepare`, `interval`, `serving`, `poll` and `sample`.
pub fn run(o: *const Options, gpa: std.mem.Allocator, view: *vw.View, source: anytype, startup_started: u64) !void {
    const live = comptime @TypeOf(source) != *Replay;
    var layout: ?*@import("draw.zig").Layout = null;
    if (c.getenv("XODB_OVERVIEW_LAYOUT") != null) {
        layout = try gpa.create(@import("draw.zig").Layout);
        layout.?.* = .{};
        view.layout = layout;
    }
    defer if (layout) |l| gpa.destroy(l);
    view.font_path = o.font;
    view.redact = o.redact;
    view.paused = o.paused;
    view.graph.demo = o.galaxy_demo;
    view.graph.demo_idle = o.galaxy_demo_idle;
    const preferences = if (o.config) |path| @import("../../preferences.zig").load(gpa, path) catch |err| {
        std.debug.print("xodb: preferences failed: {s}; {s}\n", .{ @errorName(err), path });
        return err;
    } else @import("../../preferences.zig").Preferences{};
    view.graph.look = preferences.galaxy;
    view.graph.max_stars = view.graph.look.max_stars;
    view.graph.collapse = !view.graph.look.unfold;
    view.graph.collapse_auto = false;
    if (o.theme) |t| view.palette = themes.find(t).?;
    if (o.panel) |p| view.show(p);
    if (o.galaxy_tour) @import("galaxy_descriptors.zig").navigation().motion.navigation.tour = true;
    if (o.attach_exe) {
        view.show(.processes);
        @memcpy(view.search[0..4], ".exe");
        view.search_len = 4;
        view.rows_dirty = true;
    }
    if (o.files_pid) |pid| view.files.scope(.{ .pid = pid, .start = o.files_start });
    if (o.look) |look| view.memmap.look = look;
    if (live) try source.prepare(view);
    // After prepare: opening the --memmap-pid target resets the city state.
    view.memmap.city.start_flight = o.gibson_flight;
    view.source_label = if (live) "live" else "REPLAY";
    view.owns_samples = live;

    const ui_scale: ?f32 = if (o.ui_scale) |scale| scale else preferences.appearance.ui_scale;
    var window = Window{ .own_frame = view.pal().win95, .scale_override = ui_scale };
    try window.init();
    defer window.deinit();
    window.setTitle("xodb overview");
    window.setAppId("xodb-overview");
    var renderer = Renderer{};
    defer renderer.deinit();
    const font = try gpa.create(Font);
    defer gpa.destroy(font);
    font.* = .{};
    if (view.pal().win95) try font.initRetro() else try font.initMode(o.font, false);
    defer font.deinit();

    const interval = (o.interval_ms orelse if (live) @as(u64, 500) else 1000) * 1_000_000;
    if (live) source.interval(interval);
    view.files.interval_ms = if (o.interval_ms == 250) 250 else 1000;
    // The owner clock refreshes processes at 1 Hz, independently of MCP calls.
    var next_sample: u64 = 0;
    var shown_panel = view.panel;
    // Animate transitions only when samples are far enough apart to see them;
    // at 4 Hz the samples themselves are the motion.
    view.ease_ns = if (interval >= 1_000_000_000 and view.panel != .processes) 150_000_000 else 0;
    // A replay fills history from every frame so graphs are complete at once.
    if (!live) {
        for (0..source.frames.len) |_| view.accept(source.advance(), now());
        view.sample_time = 0;
        next_sample = now() + interval;
    }
    var recovery = @import("../../render/recovery.zig").Recovery{};
    var rendered: u64 = 0;
    var last_frame: u64 = 0;
    while (!window.closing and quitting == 0) {
        const t = now();
        const frame_gap: u64 = if (view.panel == .galaxy and view.graph.layout_only) 100_000_000 else if (view.panel == .files) 66_000_000 else 33_000_000;
        // Eases redraw at 30 fps; idle waits for the next sample or input.
        const idle_cap: u64 = if (live and source.serving()) 20 else if (view.panel == .memory_map) view.memmap.waitMs(t) else 250;
        const wait_ms: i32 = if (window.dirty) 4 else if (view.animating(t)) @intCast(@max(1, (last_frame + frame_gap -| t) / 1_000_000)) else @intCast(@min(idle_cap, (next_sample -| t) / 1_000_000 + 1));
        try window.pump(window.input.timeoutMs(t, wait_ms));
        window.input.tick(now());
        view.input(&window, now());
        if (window.closing or quitting != 0) break;
        const current = now();
        view.roll(current);
        // A newly shown panel gets its groups at once rather than at the next slow tick.
        if (view.panel != shown_panel) {
            shown_panel = view.panel;
            view.ease_ns = if (interval >= 1_000_000_000 and view.panel != .processes) 150_000_000 else 0;
            next_sample = 0;
        }
        if (live) try source.poll(view, &window, current);
        if (!view.paused and current >= next_sample) {
            const started = vw.threadNs();
            if (live) {
                const sample = source.sample(gpa) catch |err| {
                    view.setStatus("Sampling failed: {s}", .{@errorName(err)}, current);
                    next_sample = current + interval;
                    continue;
                };
                view.accept(sample, current);
            } else view.accept(source.advance(), current);
            view.sourceCost(vw.threadNs() -| started);
            next_sample = current + interval;
            window.dirty = true;
        } else if (view.paused) next_sample = @max(next_sample, current + 50_000_000);
        if (view.panel == .memory_map and view.memmap.tick(current)) window.dirty = true;
        const eased = view.animating(current) and current -| last_frame >= frame_gap;
        if (!(window.dirty or eased or o.frames > 0 or current -| last_frame > 1_000_000_000)) continue;
        if (current < recovery.retry_at) continue;
        if (!recovery.ready) {
            if (!try recovery.init(&renderer, &window, current)) continue;
            font.dirty = true;
        }
        const presented = frame(&renderer, font, view, &window, current) catch |err| {
            std.debug.print("xodb: overview frame failed: {s}; recreating renderer\n", .{@errorName(err)});
            recovery.lost(&renderer, current);
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
    _ = try font.setScale(window.scale());
    if (!try r.begin(window.width, window.height, window.scale())) return false;
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
