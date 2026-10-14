//! On-demand benchmarks for `xodb --fetch --bench` and the xodbfetch panel.
//! Never run on their own: they heat the machine. Each phase runs for a
//! fixed wall time; the last result is kept in xodb's state directory.
const std = @import("std");
const c = @import("../../c_ui.zig").api;

fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
pub const default_mb = 256;
/// Wall time per CPU/memory phase.
pub const phase_ns: u64 = 400_000_000;
const sha_block = 1 << 20;

pub const Result = struct {
    /// Unix seconds when the run finished.
    when: i64 = 0,
    sha_one_mbs: f64 = 0,
    sha_all_mbs: f64 = 0,
    threads: u32 = 0,
    memcpy_gbs: f64 = 0,
    latency_ns: f64 = 0,
    buffer_mb: u32 = 0,
    /// GUI only: scene3d boxes drawn per second of GPU time, at `gpu_size`.
    gpu_instances_ps: ?f64 = null,
    gpu_instances: u32 = 0,
    gpu_size: [2]u32 = .{ 0, 0 },
    /// The Vulkan device the panel draws on (a GPU name: hidden when redacted)
    /// and its kind: discrete, integrated, virtual, cpu (a software renderer).
    gpu_device: []const u8 = "",
    gpu_kind: []const u8 = "",
};

/// "software renderer (llvmpipe ...)", the device name, or only its kind when redacted.
pub fn device(buf: []u8, r: Result, redact: bool) []const u8 {
    if (std.mem.eql(u8, r.gpu_kind, "cpu")) return if (redact or r.gpu_device.len == 0) "software renderer" else std.fmt.bufPrint(buf, "software renderer ({s})", .{r.gpu_device}) catch "software renderer";
    if (!redact and r.gpu_device.len > 0) return r.gpu_device;
    if (r.gpu_kind.len == 0 or std.mem.eql(u8, r.gpu_kind, "other")) return "the drawing GPU";
    return std.fmt.bufPrint(buf, "the {s} GPU", .{r.gpu_kind}) catch "the drawing GPU";
}

pub const method =
    \\SHA-256 over a 1 MiB buffer for 0.4 s on one thread, then on every logical CPU (MB/s = 10^6 bytes/s);
    \\memcpy between two buffers of the chosen size for 0.4 s (GB/s = 10^9 bytes copied/s);
    \\latency: a random cycle of 64-byte lines in one buffer, dependent loads for 0.4 s (ns per load);
    \\GPU (panel only): scene3d instanced boxes on the Vulkan device the panel draws on, instances per second of GPU timestamp time
;

pub const Progress = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    /// 0 idle, 1 sha one, 2 sha all, 3 memcpy, 4 latency, 5 done
    phase: std.atomic.Value(u32) = .init(0),
};
pub const phase_names = [_][]const u8{ "idle", "SHA-256, one core", "SHA-256, all cores", "memcpy", "memory latency", "done" };

fn shaLoop(buf: []const u8, until: u64, cancel: *const std.atomic.Value(bool), out: *u64) void {
    var n: u64 = 0;
    var digest: [32]u8 = undefined;
    while (now() < until and !cancel.load(.monotonic)) {
        std.crypto.hash.sha2.Sha256.hash(buf, &digest, .{});
        n += buf.len;
    }
    std.mem.doNotOptimizeAway(digest);
    out.* = n;
}

/// Runs every CPU and memory phase. `mb` sizes the memcpy and latency buffers.
pub fn run(a: std.mem.Allocator, mb: u32, progress: *Progress) !Result {
    var r = Result{ .buffer_mb = mb };
    const block = try a.alloc(u8, sha_block);
    defer a.free(block);
    for (block, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);

    progress.phase.store(1, .monotonic);
    var t0 = now();
    var bytes: u64 = 0;
    shaLoop(block, t0 + phase_ns, &progress.cancel, &bytes);
    r.sha_one_mbs = @as(f64, @floatFromInt(bytes)) * 1e3 / @as(f64, @floatFromInt(@max(1, now() - t0)));
    if (progress.cancel.load(.monotonic)) return error.Canceled;

    progress.phase.store(2, .monotonic);
    const cpus: u32 = @intCast(@min(256, std.Thread.getCpuCount() catch 1));
    r.threads = cpus;
    var counts: [256]u64 = @splat(0);
    var threads: [256]?std.Thread = @splat(null);
    t0 = now();
    for (0..cpus) |i| threads[i] = std.Thread.spawn(.{}, shaLoop, .{ block, t0 + phase_ns, &progress.cancel, &counts[i] }) catch null;
    var total: u64 = 0;
    for (threads[0..cpus], counts[0..cpus]) |t, *n| if (t) |thread| {
        thread.join();
        total += n.*;
    };
    r.sha_all_mbs = @as(f64, @floatFromInt(total)) * 1e3 / @as(f64, @floatFromInt(@max(1, now() - t0)));
    if (progress.cancel.load(.monotonic)) return error.Canceled;

    progress.phase.store(3, .monotonic);
    const size = @as(usize, mb) << 20;
    const src = try a.alloc(u64, size / 8);
    defer a.free(src);
    const dst = try a.alloc(u64, size / 8);
    defer a.free(dst);
    @memset(src, 0x5a5a5a5a5a5a5a5a);
    @memset(dst, 0); // fault every page in before timing
    t0 = now();
    var copied: u64 = 0;
    while (now() - t0 < phase_ns and !progress.cancel.load(.monotonic)) {
        @memcpy(dst, src);
        std.mem.doNotOptimizeAway(dst.ptr);
        copied += size;
    }
    r.memcpy_gbs = @as(f64, @floatFromInt(copied)) / @as(f64, @floatFromInt(@max(1, now() - t0)));
    if (progress.cancel.load(.monotonic)) return error.Canceled;

    progress.phase.store(4, .monotonic);
    // One u64 "next" index per 64-byte line, in a single random cycle (Sattolo).
    const lines = @max(2, size / 64);
    const chain = dst;
    var order = try a.alloc(u32, lines);
    defer a.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(0x0fe7c4);
    const random = prng.random();
    var i = lines - 1;
    while (i > 0) : (i -= 1) std.mem.swap(u32, &order[i], &order[random.uintLessThan(usize, i)]);
    for (0..lines) |k| chain[@as(usize, order[k]) * 8] = @as(u64, order[(k + 1) % lines]) * 8;
    var at: u64 = 0;
    var loads: u64 = 0;
    t0 = now();
    while (now() - t0 < phase_ns and !progress.cancel.load(.monotonic)) {
        for (0..65536) |_| at = chain[at];
        loads += 65536;
    }
    std.mem.doNotOptimizeAway(at);
    r.latency_ns = @as(f64, @floatFromInt(now() - t0)) / @as(f64, @floatFromInt(@max(1, loads)));
    if (progress.cancel.load(.monotonic)) return error.Canceled;
    progress.phase.store(5, .monotonic);
    r.when = c.time(null);
    return r;
}

/// $XDG_STATE_HOME/xodb/fetch-bench.json, else ~/.local/state/xodb/...
fn path(buf: []u8, dir_only: bool) ?[:0]const u8 {
    const leaf = if (dir_only) "" else "/fetch-bench.json";
    if (c.getenv("XDG_STATE_HOME")) |d| if (d[0] == '/')
        return std.fmt.bufPrintZ(buf, "{s}/xodb{s}", .{ std.mem.span(d), leaf }) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/state/xodb{s}", .{ std.mem.span(home), leaf }) catch null;
}

pub fn save(a: std.mem.Allocator, r: Result) !void {
    var buf: [1024]u8 = undefined;
    const dir = path(&buf, true) orelse return error.NoStateDirectory;
    // mkdir -p, one component at a time
    var k: usize = 1;
    while (k <= dir.len) : (k += 1) if (k == dir.len or dir[k] == '/') {
        var part: [1024]u8 = undefined;
        const p = std.fmt.bufPrintZ(&part, "{s}", .{dir[0..k]}) catch return error.NoStateDirectory;
        _ = c.mkdir(p.ptr, 0o755);
    };
    var fb: [1024]u8 = undefined;
    const file = path(&fb, false).?;
    var tb: [1040]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&tb, "{s}.tmp", .{file});
    const text = try std.json.Stringify.valueAlloc(a, r, .{});
    defer a.free(text);
    const fd = c.open(tmp.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.StateWriteFailed;
    const n = c.write(fd, text.ptr, text.len);
    _ = c.close(fd);
    if (n != text.len or c.rename(tmp.ptr, file.ptr) != 0) return error.StateWriteFailed;
}

/// The last saved result, or null when none is readable. Its strings live in `a`.
pub fn load(a: std.mem.Allocator) ?Result {
    var buf: [1024]u8 = undefined;
    const file = path(&buf, false) orelse return null;
    var bytes: [2048]u8 = undefined;
    const fd = c.open(file.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, &bytes, bytes.len);
    if (n <= 0 or n >= bytes.len) return null;
    return std.json.parseFromSliceLeaky(Result, a, bytes[0..@intCast(n)], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// "2026-10-14 21:05 UTC"
pub fn date(buf: []u8, unix: i64) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "?";
}

/// One line: "SHA-256 1.9 GB/s 1 core, 40 GB/s 32 cores (21x) · memcpy 18 GB/s · latency 84 ns".
pub fn summary(buf: []u8, r: Result) []const u8 {
    return std.fmt.bufPrint(buf, "SHA-256 {d:.0} MB/s 1 core, {d:.0} MB/s {d} cores ({d:.1}x) · memcpy {d:.1} GB/s · latency {d:.1} ns ({d} MiB)", .{
        r.sha_one_mbs, r.sha_all_mbs, r.threads, r.sha_all_mbs / @max(1, r.sha_one_mbs), r.memcpy_gbs, r.latency_ns, r.buffer_mb,
    }) catch "?";
}

test "a tiny bench run measures every phase, saves and reloads" {
    const a = std.testing.allocator;
    var dir_buf: [256]u8 = undefined;
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/xodb-fetch-bench-{d}", .{ tmp, c.getpid() });
    _ = c.setenv("XDG_STATE_HOME", dir.ptr, 1);
    defer _ = c.unsetenv("XDG_STATE_HOME");
    var progress = Progress{};
    const r = try run(a, 1, &progress);
    try std.testing.expect(r.sha_one_mbs > 0 and r.sha_all_mbs > 0 and r.memcpy_gbs > 0 and r.latency_ns > 0);
    try std.testing.expectEqual(@as(u32, 5), progress.phase.load(.monotonic));
    var with_gpu = r;
    with_gpu.gpu_device = "Demo GPU";
    try save(a, with_gpu);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const back = load(arena.allocator()).?;
    try std.testing.expectEqual(r.when, back.when);
    try std.testing.expectEqualStrings("Demo GPU", back.gpu_device);
    var nb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("the drawing GPU", device(&nb, back, true));
    with_gpu.gpu_kind = "integrated";
    try std.testing.expectEqualStrings("the integrated GPU", device(&nb, with_gpu, true));
    with_gpu.gpu_kind = "cpu";
    try std.testing.expectEqualStrings("software renderer (Demo GPU)", device(&nb, with_gpu, false));
    var pb: [256]u8 = undefined;
    const file = path(&pb, false).?;
    _ = c.unlink(file.ptr);
    var db: [256]u8 = undefined;
    _ = c.rmdir((path(&db, true).?).ptr);
    _ = c.rmdir(dir.ptr);
    var cancel = Progress{};
    cancel.cancel.store(true, .monotonic);
    try std.testing.expectError(error.Canceled, run(a, 1, &cancel));
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-02 00:00 UTC", date(&b, 86400));
}
