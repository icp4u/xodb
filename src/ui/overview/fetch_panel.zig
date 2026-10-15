//! The xodbfetch panel's state and its left column: the distro logo (from
//! the running system, or redacted a retro system's ASCII logo; its glow
//! follows CPU load and the legend says so) and
//! the benchmarks. B runs them (CPU and memory on a thread, then scene3d on
//! the GPU), Esc cancels. The card itself is drawn in panels.zig. This file
//! does not import the view, so the view can own the state.
const std = @import("std");
const log = @import("../../log.zig");
const m = @import("model.zig");
const draw = @import("draw.zig");
const fetch = @import("fetch.zig");
const bench = @import("fetch_bench.zig");
const png = @import("png.zig");
const math = @import("../../render/scene3d/math.zig");
const Ctx = draw.Ctx;
const Rect = draw.Rect;
const Color = draw.Color;
const fade = draw.fade;

const logo_cells = 128;
const gpu_boxes = 65536;
const gpu_frames = 60;

const Job = struct {
    progress: bench.Progress = .{},
    result: ?bench.Result = null,
    failed: ?anyerror = null,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    fn run(self: *Job) void {
        self.result = bench.run(std.heap.c_allocator, bench.default_mb, &self.progress) catch |err| blk: {
            self.failed = err;
            break :blk null;
        };
        self.done.store(true, .release);
    }
};

pub const State = struct {
    static: ?fetch.Static = null,
    arena: ?std.heap.ArenaAllocator = null,
    lines: []const fetch.Line = &.{},
    title: []const u8 = "",
    built: u64 = std.math.maxInt(u64),
    /// The logo downsampled to blocks once (premultiplied mean colours).
    blocks: ?*[logo_cells * logo_cells][4]u8 = null,
    last: ?bench.Result = null,
    /// Holds the strings of `last` (loaded or measured).
    keep: ?std.heap.ArenaAllocator = null,
    job: ?*Job = null,
    /// The CPU result waiting for the GPU phase, its frames and GPU time.
    pending: ?bench.Result = null,
    gpu_frame: u32 = 0,
    gpu_ns: u64 = 0,
    gpu_samples: u32 = 0,
    message: []const u8 = "",

    pub fn busy(self: *const State) bool {
        return self.job != null or self.pending != null;
    }
    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        if (self.job) |job| {
            job.progress.cancel.store(true, .monotonic);
            job.thread.?.join();
            gpa.destroy(job);
            self.job = null;
        }
        self.drop(gpa);
        if (self.keep) |*k| k.deinit();
        self.keep = null;
    }
    fn drop(self: *State, gpa: std.mem.Allocator) void {
        if (self.static) |*st| {
            if (st.logo) |*img| img.deinit(gpa);
            st.deinit();
        }
        if (self.arena) |*a| a.deinit();
        if (self.blocks) |b| gpa.destroy(b);
        self.static = null;
        self.arena = null;
        self.blocks = null;
        self.built = std.math.maxInt(u64);
    }

    /// B runs the benchmarks, Esc cancels them: the status to show, or null
    /// when the key is not the panel's.
    pub fn key(self: *State, gpa: std.mem.Allocator, event: @import("../../platform/input.zig").Event) ?[]const u8 {
        if (event.kind != .press) return null;
        if (event.sym == 0xff1b) {
            if (!self.busy()) return null;
            if (self.job) |job| job.progress.cancel.store(true, .monotonic);
            if (self.pending != null) self.message = "canceled";
            self.pending = null;
            return "Benchmark canceled";
        }
        if (!event.plain() or event.shortcut != 'b') return null;
        if (self.busy()) return "Benchmark already running (Esc cancels)";
        const job = gpa.create(Job) catch return "Benchmark: out of memory";
        job.* = .{};
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            gpa.destroy(job);
            return "Benchmark thread did not start";
        };
        self.job = job;
        self.message = "";
        return "Benchmarking: CPU and memory, then GPU (Esc cancels)";
    }

    /// Reads the facts once (again when redaction changes), joins a finished
    /// benchmark thread and rebuilds the lines for a new sample.
    /// `display_fd` is the window's Wayland connection: its peer is the WM.
    pub fn prepare(self: *State, gpa: std.mem.Allocator, redact: bool, display_fd: ?c_int, s: *const m.Snapshot, samples: u64, extra: fetch.Extra) !bool {
        self.poll(gpa);
        if (self.static) |st| if (st.redacted != redact) self.drop(gpa);
        if (self.static == null) {
            self.static = try fetch.Static.read(gpa, redact, false, display_fd);
            if (self.static.?.logo) |*img| {
                const b = try gpa.create([logo_cells * logo_cells][4]u8);
                for (0..logo_cells) |y| for (0..logo_cells) |x| {
                    b[y * logo_cells + x] = png.block(img, logo_cells, logo_cells, @intCast(x), @intCast(y));
                };
                self.blocks = b;
            }
        }
        if (self.keep == null) {
            self.keep = .init(gpa);
            self.last = bench.load(self.keep.?.allocator());
        }
        if (self.built == samples) return false;
        if (self.arena) |*a| _ = a.reset(.retain_capacity) else self.arena = .init(gpa);
        const a = self.arena.?.allocator();
        self.lines = try fetch.lines(a, &self.static.?, s, extra);
        self.title = try fetch.title(a, &self.static.?, s);
        self.built = samples;
        return true;
    }
    fn poll(self: *State, gpa: std.mem.Allocator) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.?.join();
        if (job.result) |r| {
            self.pending = r;
            self.gpu_frame = 0;
            self.gpu_ns = 0;
            self.gpu_samples = 0;
        } else self.message = if (job.failed != null and job.failed.? == error.Canceled) "canceled" else "failed";
        gpa.destroy(job);
        self.job = null;
    }
    fn finish(self: *State, gpa: std.mem.Allocator, r: bench.Result) void {
        self.pending = null;
        self.last = r;
        if (self.keep) |*k| self.last.?.gpu_device = k.allocator().dupe(u8, r.gpu_device) catch "";
        self.built = std.math.maxInt(u64);
        bench.save(gpa, r) catch {
            self.message = "result not saved";
        };
    }

    /// The card's accent: the logo's dominant colour (else os-release's),
    /// moved toward the text colour until it reads on the panel.
    pub fn tint(self: *const State, p: *const @import("theme.zig").Palette) Color {
        const t = (self.static orelse return p.accent).tint orelse return p.accent;
        var col: Color = .{ @as(f32, @floatFromInt(t[0])) / 255, @as(f32, @floatFromInt(t[1])) / 255, @as(f32, @floatFromInt(t[2])) / 255, 1 };
        const luma = struct {
            fn f(x: Color) f32 {
                return 0.2126 * x[0] + 0.7152 * x[1] + 0.0722 * x[2];
            }
        }.f;
        var k: usize = 0;
        while (k < 4 and @abs(luma(col) - luma(p.panel)) < 0.35) : (k += 1) col = draw.mix(col, p.text, 0.3);
        return col;
    }

    /// The logo (or the GPU benchmark in its place) and the benchmark card.
    pub fn drawLeft(self: *State, gpa: std.mem.Allocator, ctx: Ctx, left: Rect, height: f32, load: f32) !void {
        const p = ctx.p;
        const tint_ = self.tint(p);
        try ctx.panel(left);
        const side = @min(left.w - 32, @max(96, height * 0.44));
        const logo = Rect{ .x = left.x + (left.w - side) / 2, .y = left.y + 16, .w = side, .h = side };
        // The glow is bound to CPU load; the legend below says so.
        try ctx.r.shape(.{ .x = logo.x - 18, .y = logo.y - 18, .w = logo.w + 36, .h = logo.h + 36 }, fade(tint_, 0.08 + 0.42 * load), .{ .radii = @splat(side * 0.5), .softness = 10 + 22 * load });
        if (self.pending != null) {
            try self.gpuPhase(gpa, ctx, logo);
        } else if (self.blocks) |blocks| {
            const cell = logo.w / logo_cells;
            var n: usize = 0;
            for (blocks) |b| n += @intFromBool(b[3] > 8);
            const out = try ctx.r.cells(n);
            var k: usize = 0;
            for (blocks, 0..) |b, i| if (b[3] > 8) {
                const x: f32 = @floatFromInt(i % logo_cells);
                const y: f32 = @floatFromInt(i / logo_cells);
                out[k] = .{ .rect = .{ logo.x + x * cell, logo.y + y * cell, cell + 0.5, cell + 0.5 }, .fill = b, .accent = @splat(0), .overlay = @splat(0), .kind = 0 };
                k += 1;
            };
        } else if (self.static.?.madlib) |ml| {
            // Redacted: the retro system's ASCII logo, one glyph per fixed cell
            // so the art keeps its shape in a proportional face. Art, not text:
            // drawn past the layout audit like the PNG cells.
            const art = fetch.retro[ml.system].logo;
            var cols: usize = 1;
            for (art) |row| cols = @max(cols, row.len);
            const pitch = @min(logo.w / @as(f32, @floatFromInt(cols)), ctx.measure("M"));
            const row_h: f32 = 20;
            const x0 = logo.x + (logo.w - pitch * @as(f32, @floatFromInt(cols))) / 2;
            const y0 = logo.y + (logo.h - row_h * @as(f32, @floatFromInt(art.len))) / 2;
            for (art, 0..) |row, r| for (row, 0..) |ch, k| if (ch != ' ') {
                try ctx.r.text(ctx.font, @round(x0 + pitch * @as(f32, @floatFromInt(k))), @round(y0 + row_h * @as(f32, @floatFromInt(r))), row[k..][0..1], tint_);
            };
        } else {
            // No PNG logo: the distribution's name on its colour.
            try ctx.r.shape(logo, tint_, .{ .radii = @splat(side * 0.2), .colors = .{ tint_, tint_, p.accent2, p.accent2 } });
            const label = self.static.?.os_id;
            const lw = @min(logo.w - 16, ctx.measure(label));
            try ctx.textFit(logo.x + (logo.w - lw) / 2, logo.y + logo.h / 2 - 10, logo.w - 16, label, p.background);
        }
        var y = logo.y + logo.h + 14;
        const bx = left.x + 12;
        const bw = left.w - 24;
        var b0: [96]u8 = undefined;
        try ctx.textFit(bx, y, bw, std.fmt.bufPrint(&b0, "glow = CPU load {d:.0}%", .{load * 100}) catch "", p.dim);
        y += 30;
        try ctx.r.rect(.{ .x = bx, .y = y - 6, .w = bw, .h = 1 }, p.border);
        try ctx.textFit(bx, y, bw, "Benchmarks", p.text);
        y += 24;
        if (self.busy()) {
            const phase: u32 = if (self.job) |job| job.progress.phase.load(.monotonic) else 5;
            const label = if (self.job != null) bench.phase_names[@min(phase, 5)] else std.fmt.bufPrint(&b0, "GPU scene3d {d}/{d}", .{ self.gpu_frame, gpu_frames }) catch "";
            try ctx.textFit(bx, y, bw, label, p.warn);
            y += 22;
            const done = @as(f64, @floatFromInt(phase -| 1)) + if (self.job == null) @as(f64, @floatFromInt(self.gpu_frame)) / gpu_frames else 0;
            try ctx.bar(.{ .x = bx, .y = y + 2, .w = bw, .h = 10 }, done / 5, p.accent);
        } else if (self.last) |r| {
            var b1: [96]u8 = undefined;
            var b2: [96]u8 = undefined;
            var b3: [96]u8 = undefined;
            var b4: [96]u8 = undefined;
            var b5: [48]u8 = undefined;
            var b6: [160]u8 = undefined;
            var b7: [160]u8 = undefined;
            const items = [_][]const u8{
                std.fmt.bufPrint(&b0, "SHA x1  {d:.0} MB/s", .{r.sha_one_mbs}) catch "",
                std.fmt.bufPrint(&b1, "SHA x{d}  {d:.0} MB/s", .{ r.threads, r.sha_all_mbs }) catch "",
                std.fmt.bufPrint(&b2, "memcpy  {d:.1} GB/s", .{r.memcpy_gbs}) catch "",
                std.fmt.bufPrint(&b3, "latency  {d:.1} ns", .{r.latency_ns}) catch "",
                if (r.gpu_instances_ps) |ips| (if (ips < 1e7) std.fmt.bufPrint(&b4, "GPU  {d:.2} M boxes/s", .{ips / 1e6}) else std.fmt.bufPrint(&b4, "GPU  {d:.0} M boxes/s", .{ips / 1e6})) catch "" else "GPU  not measured",
                if (r.gpu_instances_ps != null) std.fmt.bufPrint(&b7, "  on {s}", .{bench.device(&b6, r, self.static.?.redacted)}) catch "" else "",
                bench.date(&b5, r.when),
            };
            for (items, 0..) |t, i| {
                if (t.len == 0) continue;
                if (y + 20 > left.y + left.h - 8) break;
                try ctx.textFit(bx, y, bw, t, if (i == items.len - 1) p.dim else p.text);
                y += 21;
            }
        } else try ctx.textFit(bx, y, bw, "B runs them, ~3 s", p.dim);
        if (self.message.len > 0 and !self.busy() and y + 44 < left.y + left.h) try ctx.textFit(bx, y + 4, bw, self.message, p.warn);
    }

    /// The GPU benchmark: scene3d instanced boxes in the logo's square for a
    /// fixed number of frames; instances per second of GPU timestamp time.
    fn gpuPhase(self: *State, gpa: std.mem.Allocator, ctx: Ctx, area: Rect) !void {
        const vp = math.mul(math.perspective(1, 1, 0.1, 100).?, math.lookAt(.{ 0, 0, 6 }, .{ 0, 0, 0 }, .{ 0, 1, 0 }).?);
        const scene = (ctx.r.scene(area, vp) catch null) orelse return self.finish(gpa, self.pending.?);
        // The timestamps read here are an earlier frame's; skip the warm-up.
        if (self.gpu_frame > 5) if (scene.stats.gpu_ns) |ns| if (ns > 0) {
            self.gpu_ns += ns;
            self.gpu_samples += 1;
        };
        scene.bloom = 0.4;
        const boxes = try scene.boxes(gpu_boxes);
        const side: usize = 256;
        const pitch: f32 = 4.4 / @as(f32, @floatFromInt(side));
        const turn: f32 = @as(f32, @floatFromInt(self.gpu_frame)) * 0.05;
        for (0..gpu_boxes) |i| {
            const x = (@as(f32, @floatFromInt(i % side)) + 0.5) * pitch - 2.2;
            const y = (@as(f32, @floatFromInt(i / side)) + 0.5) * pitch - 2.2;
            const z = 0.3 * @sin(x * 2 + turn) * @cos(y * 2 - turn);
            boxes.set(i, .{ .center = .{ x, y, z }, .half = .{ pitch * 0.35, pitch * 0.35, pitch * 0.35 }, .color = .{ 0.2 + z, 0.5, 0.9, 1 } });
        }
        self.gpu_frame += 1;
        if (self.gpu_frame < gpu_frames) return;
        var r = self.pending.?;
        if (self.gpu_samples > 0) {
            const mean_ns = @as(f64, @floatFromInt(self.gpu_ns)) / @as(f64, @floatFromInt(self.gpu_samples));
            r.gpu_instances_ps = gpu_boxes * 1e9 / mean_ns;
            r.gpu_instances = gpu_boxes;
            r.gpu_size = .{ @intFromFloat(area.w), @intFromFloat(area.h) };
            r.gpu_device = std.mem.sliceTo(&ctx.r.gpu_name, 0);
            r.gpu_kind = @tagName(ctx.r.gpu_kind);
        }
        log.info(.overview, "xodb: fetch gpu bench frames={d} timed={d} instances_ps={d:.0} kind={s}\n", .{ self.gpu_frame, self.gpu_samples, r.gpu_instances_ps orelse 0, r.gpu_kind });
        self.finish(gpa, r);
    }
};
