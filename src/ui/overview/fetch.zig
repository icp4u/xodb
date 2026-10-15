//! xodbfetch: a fastfetch-style card of this machine. `xodb --fetch` prints it
//! and exits (no window, no Vulkan); the overview's Fetch panel draws the same
//! lines live. Facts come from the overview collector (sysstat.zig) plus a few
//! bounded file reads; nothing runs a subprocess. With redaction the user,
//! host, machine model, GPU and monitor names are hidden as the overview
//! hides them, and the identity lines become obviously fake mad-libs (a
//! retro system's logo, OS and kernel, ...); serial numbers and addresses
//! are never read.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("../../c_ui.zig").api;
const m = @import("model.zig");
const png = @import("png.zig");
const bench = @import("fetch_bench.zig");

/// The sparkline (overview history) a GUI line draws beside its value.
pub const Spark = enum { none, cpu, boost, memory, swap, disk_io, net, temp, power, gpu, pressure, activity };
pub const Line = struct { key: []const u8, value: []const u8, spark: Spark = .none };

pub const usage =
    \\xodb --fetch [--json] [--redact] [--bench [--bench-mb N]]
    \\  A fastfetch-style card of this machine, then exit. No window.
    \\  --json        the same lines as JSON
    \\  --redact      hide user, host, machine model, GPU and monitor names; identity lines become
    \\                obviously fake retro mad-libs (OS, kernel, logo, shell, theme, ...)
    \\  --bench       also run the benchmarks (a few seconds; heats the CPU): SHA-256 one core and
    \\                all cores, memcpy bandwidth, memory latency; saved in the xodb state directory
    \\  --bench-mb N  memcpy/latency buffer size in MiB, 1..4096 (default 256)
    \\  Color and the logo follow the terminal: none when stdout is not a terminal or NO_COLOR is set.
    \\
;
pub const takes = [_][]const u8{"--bench-mb"};

// --- Small bounded readers ------------------------------------------------------

/// Reads until `buf` is full or the file ends; the bytes read.
fn readAll(fd: c_int, buf: []u8) []u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const got = c.read(fd, buf.ptr + n, buf.len - n);
        if (got <= 0) break;
        n += @intCast(got);
    }
    return buf[0..n];
}
fn readZ(buf: []u8, p: [:0]const u8) ?[]const u8 {
    const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    return std.mem.trim(u8, readAll(fd, buf), " \t\r\n\x00");
}
/// A small text file at a formatted path, trimmed; null when unreadable or empty.
fn readf(buf: []u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    var pb: [512]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pb, fmt, args) catch return null;
    const t = readZ(buf, p) orelse return null;
    return if (t.len == 0) null else t;
}
fn env(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len == 0) null else s;
}
/// Entries of a directory (not . or ..), each passed to `each`; bounded.
fn entries(dir: [:0]const u8, context: anytype, comptime each: fn (@TypeOf(context), []const u8) void) bool {
    const d = c.opendir(dir.ptr) orelse return false;
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |e| : (n += 1) {
        if (n > 65536) break;
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        each(context, name);
    }
    return true;
}
fn countEntry(n: *u64, name: []const u8) void {
    if (name[0] != '.' and !std.mem.eql(u8, name, "ALPM_DB_VERSION")) n.* += 1;
}
fn countDir(dir: [:0]const u8) ?u64 {
    var n: u64 = 0;
    return if (entries(dir, &n, countEntry) and n > 0) n else null;
}
/// Occurrences of `needle` at line starts in a file, read in chunks (bounded 256 MiB).
fn countLines(p: [:0]const u8, needle: []const u8) ?u64 {
    const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [65536]u8 = undefined;
    var keep: usize = 0;
    var n: u64 = 0;
    var total: usize = 0;
    var start = true;
    while (total < 256 << 20) {
        const got = c.read(fd, &buf[keep], buf.len - keep);
        if (got <= 0) break;
        total += @intCast(got);
        const have = keep + @as(usize, @intCast(got));
        var i: usize = 0;
        while (i + needle.len <= have) : (i += 1) {
            if ((start or (i > 0 and buf[i - 1] == '\n')) and std.mem.eql(u8, buf[i..][0..needle.len], needle)) n += 1;
            start = false;
        }
        keep = @min(have, needle.len);
        std.mem.copyForwards(u8, buf[0..keep], buf[have - keep .. have]);
        start = false;
    }
    return if (n > 0) n else null;
}

// --- Mad-libs (--redact) --------------------------------------------------------------

/// Under redaction the card's hidden identity lines become obviously fake
/// retro ones: a system (logo, OS and kernel that match), a shell, a theme,
/// an icon set, an uptime, a package count and network rates. Display only:
/// src/redact.zig's placeholders, MCP and archives never see these. The
/// logos are original ASCII art, not anyone's trademark.
pub const Retro = struct { os: []const u8, kernel: []const u8, tint: [3]u8, logo: []const []const u8 };
pub const retro = [_]Retro{
    .{ .os = "OS/2 Warp 4 (i386)", .kernel = "OS2KRNL 14.104a (warp factor 9)", .tint = .{ 59, 111, 182 }, .logo = &.{
        " *    .   ---==>    .",
        "   .   OS/2 ===>>>   *",
        " .   ---==>     .",
        "   *      .   WARP 4",
    } },
    .{ .os = "BeOS R5 (BeBox)", .kernel = "kernel_ppc R5.0.3 (pervasively multithreaded)", .tint = .{ 222, 160, 40 }, .logo = &.{
        "    __     __",
        "   (  )\\ /(  )",
        "    \\  (o)  /    bzz",
        "    /  (_)  \\",
        "   (__)/ \\(__)   BeOS",
    } },
    .{ .os = "CP/M 2.2 (Z80)", .kernel = "BDOS 2.2 + CCP (64 KiB of RAM, all of it)", .tint = .{ 80, 200, 90 }, .logo = &.{
        " .------------------.",
        " | A>DIR            |",
        " | A: PIP     COM   |",
        " | A>_              |",
        " '------------------'",
    } },
    .{ .os = "MUMPS (PDP-11)", .kernel = "MUMPS-11 ANSI X11.1-1977 (it is all globals)", .tint = .{ 200, 120, 60 }, .logo = &.{
        " .------------------.",
        " | S ^X(\"hi\")=1     |",
        " | W $D(^X(\"hi\"))   |",
        " | 1                |",
        " '------------------'",
    } },
    .{ .os = "AmigaOS 3.1 (68000)", .kernel = "exec.library 40.10 (Kickstart 3.1, 512 KiB chip RAM)", .tint = .{ 220, 60, 50 }, .logo = &.{
        " #######################",
        " # Software Failure.   #",
        " # Guru Meditation     #",
        " # #00000004.0000AAC0  #",
        " #######################",
    } },
    .{ .os = "NeXTSTEP 3.3 (68040)", .kernel = "Mach 2.5 (Display PostScript, black hardware)", .tint = .{ 170, 90, 200 }, .logo = &.{
        "      .------.",
        "     /      /|",
        "    .------. |",
        "    |      | .",
        "    |      |/",
        "    '------'",
    } },
    .{ .os = "OpenVMS 5.5 (VAX)", .kernel = "VMS V5.5-2 (1 VUP, a cluster of one)", .tint = .{ 90, 160, 220 }, .logo = &.{
        " $ SHOW TIME",
        "    1-JAN-1990 00:00:00",
        " $ PURGE/KEEP=1",
        " %SYSTEM-S-NORMAL",
    } },
    .{ .os = "Plan 9 from Bell Labs (386)", .kernel = "9pccpu (everything is a file, even this)", .tint = .{ 120, 180, 160 }, .logo = &.{
        "  .---------.",
        "  | /dev    |",
        "  | /net    |",
        "  | /proc   |",
        "  '---------'   9P",
    } },
};
pub const ikea = [_][]const u8{ "BILLY", "SKRUVBY", "KALLAX", "LACK", "MALM", "FRAKTA", "TRASSLA", "VINGLIG", "SKRUVLOS" };
pub const pop = [_][]const u8{ "Michael Jackson", "Madonna", "Prince", "Cher", "Freddie Mercury", "Dolly Parton", "David Bowie", "Whitney Houston" };
pub const shell_madlib = "3rdseashell";

pub const Madlib = struct {
    system: usize,
    uptime_s: u64,
    packages: u32,
    theme: usize,
    icons: usize,
    /// The panel's rates: MB/s in, packets/s in, MB/s out, packets/s out.
    net: [4]f64,
    /// --fetch's totals since boot: bytes in, packets in, bytes out, packets out.
    totals: [4]f64,

    pub fn pick(seed: u64) Madlib {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var k: Madlib = .{
            .system = r.uintLessThan(usize, retro.len),
            // under ten years even after the live panel adds this run's uptime
            .uptime_s = r.uintLessThan(u64, 9 * 365 * 86400),
            .packages = 100 + r.uintLessThan(u32, 9000),
            .theme = r.uintLessThan(usize, ikea.len),
            .icons = r.uintLessThan(usize, pop.len),
            .net = .{ 0.01 + r.float(f64) * 40, @floor(10 + r.float(f64) * 30000), 0.01 + r.float(f64) * 8, @floor(10 + r.float(f64) * 9000) },
            .totals = undefined,
        };
        const in = 1e9 + r.float(f64) * 4e12;
        const out = in * (0.05 + r.float(f64) * 0.5);
        k.totals = .{ in, @floor(in / (500 + r.float(f64) * 900)), out, @floor(out / (200 + r.float(f64) * 600)) };
        return k;
    }
};

/// One seed per process, so a card (and the panel across redaction toggles)
/// stays self-consistent.
var madlib_seed: ?u64 = null;
fn madlibSeed() u64 {
    if (madlib_seed == null) {
        var b: [8]u8 = undefined;
        const got = if (builtin.os.tag == .linux) std.os.linux.getrandom(&b, b.len, 0) else 0;
        madlib_seed = if (got == b.len) std.mem.readInt(u64, &b, .little) else @intFromPtr(&madlib_seed) ^ 0x9e3779b97f4a7c15;
    }
    return madlib_seed.?;
}

// --- Static facts (read once) -----------------------------------------------------

pub const Static = struct {
    arena: std.heap.ArenaAllocator,
    redacted: bool,
    user: []const u8 = "",
    os_name: ?[]const u8 = null,
    os_id: []const u8 = "linux",
    /// The card's accent: the logo's dominant colour, else os-release ANSI_COLOR.
    tint: ?[3]u8 = null,
    logo: ?png.Image = null,
    host_model: ?[]const u8 = null,
    packages: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    displays: []const []const u8 = &.{},
    de: ?[]const u8 = null,
    wm: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    icons: ?[]const u8 = null,
    font: ?[]const u8 = null,
    terminal: ?[]const u8 = null,
    locale: ?[]const u8 = null,
    nvme: []const []const u8 = &.{},
    /// Under redaction: the fake identity lines (see Madlib).
    madlib: ?Madlib = null,
    scheduler: ?[]const u8 = null,
    /// Collector GPU names resolved through pci.ids, read once per name.
    gpu_names: std.ArrayList([2][]const u8) = .empty,

    pub fn deinit(self: *Static) void {
        self.arena.deinit();
    }

    /// `display_fd`: the GUI's Wayland connection, whose peer is the WM line.
    pub fn read(gpa: std.mem.Allocator, redact: bool, terminal: bool, display_fd: ?c_int) !Static {
        var s = Static{ .arena = .init(gpa), .redacted = redact };
        errdefer s.arena.deinit();
        const a = s.arena.allocator();
        var b: [4096]u8 = undefined;
        if (!redact) s.user = try a.dupe(u8, env("USER") orelse env("LOGNAME") orelse "user");
        if (readf(&b, "/etc/os-release", .{}) orelse readf(&b, "/usr/lib/os-release", .{})) |text| {
            var logo_name: ?[]const u8 = null;
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const value = std.mem.trim(u8, line[eq + 1 ..], "\"' ");
                const k = line[0..eq];
                if (std.mem.eql(u8, k, "PRETTY_NAME") or (std.mem.eql(u8, k, "NAME") and s.os_name == null)) s.os_name = try a.dupe(u8, value);
                if (std.mem.eql(u8, k, "ID")) s.os_id = try a.dupe(u8, value);
                if (std.mem.eql(u8, k, "LOGO")) logo_name = try a.dupe(u8, value);
                if (std.mem.eql(u8, k, "ANSI_COLOR")) s.tint = ansiColor(value);
            }
            // Redacted, the card wears a retro system's ASCII logo instead.
            if (!redact) s.logo = loadLogo(gpa, logo_name orelse s.os_id);
            if (s.logo) |*img| if (png.dominant(img)) |rgb| {
                s.tint = rgb;
            };
        }
        // The product name, else the board (desktops often leave the product unset).
        if (!redact) for ([_][2][]const u8{ .{ "product_name", "product_version" }, .{ "board_name", "board_vendor" } }) |pair| {
            var nb: [128]u8 = undefined;
            var vb: [128]u8 = undefined;
            const name = readf(&nb, "/sys/class/dmi/id/{s}", .{pair[0]}) orelse continue;
            if (placeholder(name)) continue;
            const other = readf(&vb, "/sys/class/dmi/id/{s}", .{pair[1]}) orelse "";
            s.host_model = try if (placeholder(other)) a.dupe(u8, name) else if (pair[0][0] == 'p') std.fmt.allocPrint(a, "{s} ({s})", .{ name, other }) else std.fmt.allocPrint(a, "{s} {s}", .{ other, name });
            break;
        };
        s.packages = try packages(a);
        if (env("SHELL")) |sh| s.shell = try a.dupe(u8, std.fs.path.basename(sh));
        if (redact) {
            const ml = Madlib.pick(madlibSeed());
            s.madlib = ml;
            s.tint = retro[ml.system].tint;
            s.packages = try std.fmt.allocPrint(a, "{d} (floppies)", .{ml.packages});
            s.shell = shell_madlib;
        }
        s.displays = try displays(a, redact);
        s.de = try desktop(a);
        s.wm = try peerComm(a, display_fd orelse -1) orelse try sessionCompositor(a);
        // Theme and icon names are free text (often the distribution's own):
        // redacted, a made-up name keeps only the toolkit suffix; no font.
        try gtkSettings(a, &s);
        if (s.madlib) |ml| {
            if (s.theme != null) s.theme = try std.fmt.allocPrint(a, "{s} [GTK3]", .{ikea[ml.theme]});
            if (s.icons != null) s.icons = try std.fmt.allocPrint(a, "{s} [GTK3]", .{pop[ml.icons]});
            s.font = null;
        }
        if (terminal) s.terminal = try terminalName(a);
        s.locale = if (env("LC_ALL") orelse env("LANG")) |l| try a.dupe(u8, l) else null;
        s.nvme = try nvme(a);
        if (readf(&b, "/sys/kernel/sched_ext/state", .{})) |state| if (std.mem.eql(u8, state, "enabled")) {
            var ob: [128]u8 = undefined;
            s.scheduler = try std.fmt.allocPrint(a, "sched_ext {s}", .{readf(&ob, "/sys/kernel/sched_ext/root/ops", .{}) orelse "(unnamed)"});
        };
        return s;
    }
};

fn placeholder(v: []const u8) bool {
    const junk = [_][]const u8{ "", "None", "To Be Filled By O.E.M.", "Default string", "System Product Name", "System Version", "Not Applicable", "0", "Type1ProductConfigId" };
    for (junk) |j| if (std.mem.eql(u8, v, j)) return true;
    return false;
}

fn ansiColor(v: []const u8) ?[3]u8 {
    // "38;2;R;G;B" (truecolor) or a basic "1;34" style code
    var it = std.mem.splitScalar(u8, v, ';');
    var nums: [8]u32 = undefined;
    var n: usize = 0;
    while (it.next()) |p| : (n += 1) {
        if (n == nums.len) break;
        nums[n] = std.fmt.parseInt(u32, p, 10) catch return null;
    }
    if (n >= 5 and nums[0] == 38 and nums[1] == 2) return .{ @intCast(@min(255, nums[2])), @intCast(@min(255, nums[3])), @intCast(@min(255, nums[4])) };
    const basic = [8][3]u8{ .{ 0, 0, 0 }, .{ 205, 49, 49 }, .{ 13, 188, 121 }, .{ 229, 229, 16 }, .{ 36, 114, 200 }, .{ 188, 63, 188 }, .{ 17, 168, 205 }, .{ 229, 229, 229 } };
    for (nums[0..n]) |k| if (k >= 30 and k <= 37) return basic[k - 30];
    return null;
}

/// LOGO= resolved through pixmaps and the hicolor icon theme; PNG only.
fn loadLogo(gpa: std.mem.Allocator, name: []const u8) ?png.Image {
    if (name.len == 0 or name.len > 64 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    var pb: [256]u8 = undefined;
    const sizes = [_][]const u8{ "256x256", "128x128", "512x512", "96x96", "64x64", "48x48" };
    var k: usize = 0;
    while (k < sizes.len + 1) : (k += 1) {
        const p = (if (k == 0) std.fmt.bufPrintZ(&pb, "/usr/share/pixmaps/{s}.png", .{name}) else std.fmt.bufPrintZ(&pb, "/usr/share/icons/hicolor/{s}/apps/{s}.png", .{ sizes[k - 1], name })) catch return null;
        const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        var st: c.struct_stat = undefined;
        if (c.fstat(fd, &st) != 0 or st.st_mode & c.S_IFMT != c.S_IFREG or st.st_size <= 0 or st.st_size > png.max_file) continue;
        const bytes = gpa.alloc(u8, @intCast(st.st_size)) catch return null;
        defer gpa.free(bytes);
        if (readAll(fd, bytes).len != bytes.len) continue;
        return png.decode(gpa, bytes) catch continue;
    }
    return null;
}

fn packages(a: std.mem.Allocator) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pb: [512]u8 = undefined;
    const user_flatpak = if (env("HOME")) |home| std.fmt.bufPrintZ(&pb, "{s}/.local/share/flatpak/app", .{home}) catch null else null;
    const found = [_]struct { []const u8, ?u64 }{
        .{ "pacman", countDir("/var/lib/pacman/local") },
        .{ "dpkg", countLines("/var/lib/dpkg/status", "Status: install ok installed") },
        .{ "apk", countLines("/lib/apk/db/installed", "P:") },
        .{ "flatpak-system", countDir("/var/lib/flatpak/app") },
        .{ "flatpak-user", if (user_flatpak) |p| countDir(p) else null },
    };
    for (found) |f| if (f[1]) |n| try out.print(a, "{s}{d} ({s})", .{ if (out.items.len > 0) ", " else "", n, f[0] });
    return if (out.items.len > 0) out.items else null;
}

/// Connected DRM outputs: the EDID's preferred timing (size and refresh) and
/// the monitor's model name. The serial-number descriptor is never read.
fn displays(a: std.mem.Allocator, redact: bool) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const Collect = struct {
        fn each(list: *std.ArrayList([]const u8), name: []const u8) void {
            if (!std.mem.startsWith(u8, name, "card") or std.mem.indexOfScalar(u8, name, '-') == null or list.items.len >= 16) return;
            list.append(std.heap.c_allocator, std.heap.c_allocator.dupe(u8, name) catch return) catch {};
        }
    };
    _ = entries("/sys/class/drm", &names, Collect.each);
    defer {
        for (names.items) |n| std.heap.c_allocator.free(n);
        names.deinit(std.heap.c_allocator);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var out: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        var sb: [64]u8 = undefined;
        const status = readf(&sb, "/sys/class/drm/{s}/status", .{name}) orelse continue;
        if (!std.mem.eql(u8, status, "connected")) continue;
        const connector = name[std.mem.indexOfScalar(u8, name, '-').? + 1 ..];
        var eb: [512]u8 = undefined;
        var pb: [256]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pb, "/sys/class/drm/{s}/edid", .{name}) catch continue;
        const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
        const got: isize = if (fd < 0) -1 else c.read(fd, &eb, 128);
        if (fd >= 0) _ = c.close(fd);
        if (got >= 128) if (edid(eb[0..128])) |e| {
            const model = if (redact or e.name.len == 0) "" else e.name;
            try out.append(a, try std.fmt.allocPrint(a, "{d}x{d} @ {d:.0} Hz ({s}{s}{s}, preferred)", .{ e.w, e.h, e.hz, connector, if (model.len > 0) ", " else "", model }));
            continue;
        };
        var mb: [64]u8 = undefined;
        const mode = readf(&mb, "/sys/class/drm/{s}/modes", .{name}) orelse continue;
        const first = mode[0 .. std.mem.indexOfScalar(u8, mode, '\n') orelse mode.len];
        try out.append(a, try std.fmt.allocPrint(a, "{s} ({s}, preferred)", .{ first, connector }));
    }
    return out.items;
}
const Edid = struct { w: u32, h: u32, hz: f64, name: []const u8 };
fn edid(e: []const u8) ?Edid {
    if (!std.mem.eql(u8, e[0..8], "\x00\xff\xff\xff\xff\xff\xff\x00")) return null;
    const d = e[54..72];
    const clock = @as(u32, std.mem.readInt(u16, d[0..2], .little)) * 10_000;
    if (clock == 0) return null;
    const hact = @as(u32, d[2]) | (@as(u32, d[4] >> 4) << 8);
    const hblank = @as(u32, d[3]) | (@as(u32, d[4] & 0xf) << 8);
    const vact = @as(u32, d[5]) | (@as(u32, d[7] >> 4) << 8);
    const vblank = @as(u32, d[6]) | (@as(u32, d[7] & 0xf) << 8);
    if (hact == 0 or vact == 0) return null;
    var out = Edid{ .w = hact, .h = vact, .hz = @as(f64, @floatFromInt(clock)) / @as(f64, @floatFromInt((hact + hblank) * (vact + vblank))), .name = "" };
    var k: usize = 72;
    while (k + 18 <= 126) : (k += 18) {
        const x = e[k..][0..18];
        // 0xFC: monitor name. (0xFF, the serial number, is skipped.)
        if (x[0] == 0 and x[1] == 0 and x[2] == 0 and x[3] == 0xfc) {
            const text = x[5..18];
            out.name = std.mem.trimEnd(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " ");
        }
    }
    for (out.name) |ch| if (ch < 0x20 or ch > 0x7e) {
        out.name = "";
        break;
    };
    return out;
}

/// A desktop environment from the session's environment. Bare compositor
/// names are left to the WM line, which names the compositor actually used.
fn desktop(a: std.mem.Allocator) !?[]const u8 {
    const known = [_][]const u8{ "GNOME", "KDE", "XFCE", "LXQt", "LXDE", "Cinnamon", "MATE", "Budgie", "COSMIC", "Unity", "Pantheon", "Deepin", "Enlightenment" };
    const d = env("XDG_CURRENT_DESKTOP") orelse env("XDG_SESSION_DESKTOP") orelse return null;
    var it = std.mem.tokenizeScalar(u8, d, ':');
    while (it.next()) |name| for (known) |k| if (std.ascii.eqlIgnoreCase(name, k)) return try a.dupe(u8, k);
    return null;
}

/// The process at the other end of a Unix socket (SO_PEERCRED), by name.
fn peerComm(a: std.mem.Allocator, fd: c_int) !?[]const u8 {
    if (builtin.os.tag != .linux or fd < 0) return null;
    const linux = std.os.linux;
    var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
    var len: linux.socklen_t = @sizeOf(@TypeOf(cred));
    if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, @ptrCast(&cred), &len)) != .SUCCESS or cred.pid <= 0) return null;
    var b: [64]u8 = undefined;
    return if (readf(&b, "/proc/{d}/comm", .{cred.pid})) |comm| try a.dupe(u8, comm) else null;
}

/// `--fetch` in a terminal: the compositor serving this session's
/// $WAYLAND_DISPLAY (connect, ask the kernel who listens, close).
fn sessionCompositor(a: std.mem.Allocator) !?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const linux = std.os.linux;
    const name = env("WAYLAND_DISPLAY") orelse return null;
    var addr = linux.sockaddr.un{ .path = @splat(0) };
    const p = (if (name[0] == '/') std.fmt.bufPrint(&addr.path, "{s}", .{name}) else std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ env("XDG_RUNTIME_DIR") orelse return null, name })) catch return null;
    if (p.len >= addr.path.len) return null;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: c_int = @intCast(rc);
    defer _ = c.close(fd);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) return null;
    return peerComm(a, fd);
}

fn gtkSettings(a: std.mem.Allocator, s: *Static) !void {
    var b: [8192]u8 = undefined;
    const text = (if (env("XDG_CONFIG_HOME")) |d| readf(&b, "{s}/gtk-3.0/settings.ini", .{d}) else null) orelse
        (if (env("HOME")) |h| readf(&b, "{s}/.config/gtk-3.0/settings.ini", .{h}) else null) orelse return;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " ");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \"");
        if (v.len == 0 or v.len > 64) continue;
        if (std.mem.eql(u8, k, "gtk-theme-name")) s.theme = try std.fmt.allocPrint(a, "{s} [GTK3]", .{v});
        if (std.mem.eql(u8, k, "gtk-icon-theme-name")) s.icons = try std.fmt.allocPrint(a, "{s} [GTK3]", .{v});
        if (std.mem.eql(u8, k, "gtk-font-name")) s.font = try std.fmt.allocPrint(a, "{s} [GTK3]", .{v});
    }
}

/// The terminal emulator this process runs in: the first known name among
/// its ancestors, else $TERM_PROGRAM or $TERM.
fn terminalName(a: std.mem.Allocator) !?[]const u8 {
    const known = [_][]const u8{ "foot", "footclient", "alacritty", "kitty", "wezterm-gui", "konsole", "gnome-terminal-", "xfce4-terminal", "tilix", "xterm", "urxvt", "st", "ghostty", "terminator", "sakura", "lxterminal", "qterminal", "terminology", "rio", "contour", "tmux: server", "tmux: client", "screen" };
    var pid: i64 = c.getppid();
    var depth: usize = 0;
    while (pid > 1 and depth < 12) : (depth += 1) {
        var b: [512]u8 = undefined;
        const stat = readf(&b, "/proc/{d}/stat", .{pid}) orelse break;
        const open = std.mem.indexOfScalar(u8, stat, '(') orelse break;
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse break;
        const comm = stat[open + 1 .. close];
        for (known) |k| if (std.mem.eql(u8, comm, k)) return try a.dupe(u8, if (std.mem.startsWith(u8, k, "tmux")) "tmux" else std.mem.trimEnd(u8, k, "-"));
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        _ = fields.next();
        pid = std.fmt.parseInt(i64, fields.next() orelse break, 10) catch break;
    }
    return if (env("TERM_PROGRAM") orelse env("TERM")) |t| try a.dupe(u8, t) else null;
}

/// NVMe controllers: model and current PCIe link. Serial numbers are not read.
fn nvme(a: std.mem.Allocator) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (0..8) |i| {
        var mb: [128]u8 = undefined;
        const model = readf(&mb, "/sys/class/nvme/nvme{d}/model", .{i}) orelse continue;
        var sb: [64]u8 = undefined;
        var wb: [16]u8 = undefined;
        const speed = readf(&sb, "/sys/class/nvme/nvme{d}/device/current_link_speed", .{i});
        const width = readf(&wb, "/sys/class/nvme/nvme{d}/device/current_link_width", .{i});
        const gt = if (speed) |sp| std.fmt.parseFloat(f64, sp[0 .. std.mem.indexOfScalar(u8, sp, ' ') orelse sp.len]) catch 0 else 0;
        const gen: u32 = if (gt >= 60) 6 else if (gt >= 30) 5 else if (gt >= 15) 4 else if (gt >= 7) 3 else if (gt >= 4) 2 else if (gt >= 2) 1 else 0;
        try out.append(a, if (gen > 0 and width != null) try std.fmt.allocPrint(a, "{s} · PCIe {d}.0 x{s}", .{ model, gen, width.? }) else try a.dupe(u8, model));
    }
    return out.items;
}

// --- Lines -------------------------------------------------------------------------

pub const Extra = struct {
    /// GUI: rates, load and xodb's own renderer; the CLI has one sample, no rates.
    gui: bool = false,
    vulkan: []const u8 = "",
    draw_ms: ?f64 = null,
    startup_ms: ?f64 = null,
    bench: ?bench.Result = null,
    /// CLI: bytes in, packets in, bytes out, packets out since boot over
    /// physical links (netTotals); the panel shows live rates instead.
    net_totals: ?[4]f64 = null,
};

/// Appends one " · "-separated part.
fn part(a: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    if (list.items.len > 0) try list.appendSlice(a, " · ");
    try list.print(a, fmt, args);
}
fn pct(used: u64, total: u64) f64 {
    return if (total == 0) 0 else @as(f64, @floatFromInt(used)) * 100 / @as(f64, @floatFromInt(total));
}
fn ofTotal(a: std.mem.Allocator, used: m.U, total: m.U) !?[]const u8 {
    const u = used.get() orelse return null;
    const t = total.get() orelse return null;
    if (t == 0) return null;
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    return try std.fmt.allocPrint(a, "{s} / {s} ({d:.0}%)", .{ m.bytes(&b1, @floatFromInt(u)), m.bytes(&b2, @floatFromInt(t)), pct(u, t) });
}
/// "3 days, 4 hours, 5 mins" as fetch tools write it.
pub fn uptime(buf: []u8, seconds: f64, with_seconds: bool) []const u8 {
    const s: u64 = @intFromFloat(@max(0, seconds));
    var w: std.Io.Writer = .fixed(buf);
    const parts = [_]struct { u64, []const u8 }{ .{ s / 86400, "day" }, .{ s % 86400 / 3600, "hour" }, .{ s % 3600 / 60, "min" }, .{ if (with_seconds) s % 60 else 0, "sec" } };
    var any = false;
    for (parts) |p| if (p[0] > 0) {
        w.print("{s}{d} {s}{s}", .{ if (any) ", " else "", p[0], p[1], if (p[0] == 1) "" else "s" }) catch break;
        any = true;
    };
    if (!any) return "0 mins";
    return w.buffered();
}
fn ghz(mhz: f64) f64 {
    return mhz / 1000;
}
/// A collector GPU name as people know it, cached for the live panel.
fn gpuName(st: *Static, text: []const u8) ![]const u8 {
    for (st.gpu_names.items) |pair| if (std.mem.eql(u8, pair[0], text)) return pair[1];
    const a = st.arena.allocator();
    const name = try resolveGpu(a, text);
    try st.gpu_names.append(a, .{ try a.dupe(u8, text), name });
    return name;
}
/// "8086:3e92"-style ids resolved through pci.ids; else the text unchanged.
fn resolveGpu(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    // the collector writes "<driver> <vendor>:<device>" without a product name
    const sp = std.mem.lastIndexOfScalar(u8, text, ' ');
    const id = if (sp) |k| text[k + 1 ..] else text;
    if (id.len != 9 or id[4] != ':') return a.dupe(u8, text);
    const driver = if (sp) |k| text[0..k] else "";
    const ids = pciName(a, id[0..4], id[5..9]) catch null;
    if (ids) |n| return if (driver.len > 0) std.fmt.allocPrint(a, "{s} [{s}]", .{ n, driver }) else n;
    return a.dupe(u8, text);
}
fn pciName(a: std.mem.Allocator, vendor: []const u8, device: []const u8) !?[]const u8 {
    for ([_][:0]const u8{ "/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids" }) |p| {
        const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) continue;
        defer _ = c.close(fd);
        const data = try a.alloc(u8, 8 << 20);
        defer a.free(data);
        var vendor_name: ?[]const u8 = null;
        var it = std.mem.splitScalar(u8, readAll(fd, data), '\n');
        while (it.next()) |line| {
            if (line.len < 6 or line[0] == '#') continue;
            if (line[0] != '\t') {
                if (vendor_name != null) break; // past our vendor
                if (std.ascii.eqlIgnoreCase(line[0..4], vendor)) vendor_name = std.mem.trim(u8, line[4..], " ");
            } else if (vendor_name != null and line[1] != '\t' and line.len > 6 and std.ascii.eqlIgnoreCase(line[1..5], device)) {
                const product = std.mem.trim(u8, line[5..], " ");
                // Prefer the bracketed marketing name: "TU104 [GeForce RTX 2080]".
                const short = if (std.mem.indexOfScalar(u8, product, '[')) |o| if (std.mem.lastIndexOfScalar(u8, product, ']')) |e| product[o + 1 .. e] else product else product;
                const vshort = if (std.mem.indexOfScalar(u8, vendor_name.?, '[')) |o| vendor_name.?[o + 1 .. std.mem.lastIndexOfScalar(u8, vendor_name.?, ']') orelse vendor_name.?.len] else vendor_name.?;
                const vfirst = vshort[0 .. std.mem.indexOfAny(u8, vshort, " /,") orelse vshort.len];
                return try std.fmt.allocPrint(a, "{s} {s}", .{ vfirst, short });
            }
        }
    }
    return null;
}

/// The card's lines in fastfetch order, then what fetch tools cannot show.
/// A line with nothing honest to show is omitted.
pub fn lines(a: std.mem.Allocator, st: *Static, s: *const m.Snapshot, x: Extra) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    const redact = st.redacted;
    const add = struct {
        fn f(list: *std.ArrayList(Line), al: std.mem.Allocator, key: []const u8, value: ?[]const u8, spark: Spark) !void {
            if (value) |v| if (v.len > 0) try list.append(al, .{ .key = key, .value = v, .spark = spark });
        }
    }.f;
    const arch = if (s.arch.ok()) s.arch.s else "";
    const ml = st.madlib;
    const sys: ?Retro = if (ml) |k| retro[k.system] else null;
    try add(&out, a, "OS", if (sys) |r| r.os else try std.fmt.allocPrint(a, "{s} {s}", .{ st.os_name orelse "Linux", arch }), .none);
    try add(&out, a, "Host", st.host_model, .none);
    try add(&out, a, "Kernel", if (sys) |r| r.kernel else if (redact or !s.kernel.ok()) null else try std.fmt.allocPrint(a, "Linux {s}", .{s.kernel.s}), .none);
    var ub: [64]u8 = undefined;
    // Redacted: a random start, ticking with this machine's uptime.
    const up: ?f64 = if (ml) |k| @as(f64, @floatFromInt(k.uptime_s)) + @min(s.uptime_s.get() orelse 0, 365 * 86400) else s.uptime_s.get();
    try add(&out, a, "Uptime", if (up) |u| try a.dupe(u8, uptime(&ub, u, x.gui)) else null, .none);
    try add(&out, a, "Packages", st.packages, .none);
    try add(&out, a, "Shell", st.shell, .none);
    for (st.displays) |d| try add(&out, a, "Display", d, .none);
    try add(&out, a, "DE", st.de, .none);
    try add(&out, a, "WM", st.wm, .none);
    try add(&out, a, "Theme", st.theme, .none);
    try add(&out, a, "Icons", st.icons, .none);
    try add(&out, a, "Font", st.font, .none);
    if (!x.gui) try add(&out, a, "Terminal", st.terminal, .none);
    var max_mhz: f64 = 0;
    var fastest: f64 = 0;
    for (s.cpus) |cpu| {
        max_mhz = @max(max_mhz, cpu.max_mhz.get() orelse 0);
        fastest = @max(fastest, cpu.mhz.get() orelse 0);
    }
    if (s.cpu_model.ok()) {
        const model = s.cpu_model.s;
        try add(&out, a, "CPU", if (max_mhz > 0) try std.fmt.allocPrint(a, "{s} ({d}) @ {d:.2} GHz", .{ model, s.cpus.len, ghz(max_mhz) }) else try std.fmt.allocPrint(a, "{s} ({d})", .{ model, s.cpus.len }), .none);
    }
    // One GPU line per device: the collector's name, resolved through pci.ids.
    if (redact) {
        if (s.gpu_names.len > 0 or s.gpus.len > 0) try add(&out, a, "GPU", "hidden (redacted)", if (x.gui and s.gpus.len > 0) .gpu else .none);
    } else if (s.gpus.len > 0) {
        for (s.gpus, 0..) |g, i| {
            const name = if (g.name.ok()) try gpuName(st, g.name.s) else g.card;
            const named = if (std.mem.indexOfScalar(u8, name, '[') == null and g.driver.len > 0) try std.fmt.allocPrint(a, "{s} [{s}]", .{ name, g.driver }) else name;
            try add(&out, a, "GPU", named, if (x.gui and i == 0) .gpu else .none);
        }
    } else for (s.gpu_names) |g| if (g.ok()) try add(&out, a, "GPU", try gpuName(st, g.s), .none);
    const total = if (s.memory.total.get() != null) s.memory.total else s.memory_total;
    try add(&out, a, "Memory", try ofTotal(a, s.memory.used, total), if (x.gui) .memory else .none);
    if ((s.memory.swap_total.get() orelse 0) > 0) try add(&out, a, "Swap", try ofTotal(a, s.memory.swap_used, s.memory.swap_total), if (x.gui) .swap else .none);
    for (s.mounts) |mount| if (mount.path.ok() and std.mem.eql(u8, mount.path.s, "/")) {
        if (try ofTotal(a, mount.used, mount.total)) |v| try add(&out, a, "Disk (/)", try std.fmt.allocPrint(a, "{s} - {s}", .{ v, mount.fstype }), .none);
        break;
    };
    if (s.battery_pct.get()) |b| try add(&out, a, "Battery", try std.fmt.allocPrint(a, "{d:.0}%", .{b}), .none);
    try add(&out, a, "Locale", st.locale, .none);

    // What fetch tools do not show.
    if (x.gui) if (s.cpu_total.get()) |load| try add(&out, a, "CPU load", try std.fmt.allocPrint(a, "{d:.1}% · load {d:.2}", .{ load, s.load1.get() orelse 0 }), .cpu);
    if (fastest > 0 and max_mhz > 0) try add(&out, a, "Boost", try std.fmt.allocPrint(a, "{d:.2} GHz fastest core now / {d:.2} GHz max", .{ ghz(fastest), ghz(max_mhz) }), if (x.gui) .boost else .none);
    if (x.gui) if (s.context_switches_ps.get()) |cs| try add(&out, a, "Activity", try std.fmt.allocPrint(a, "{d:.0} context switches/s · {d:.0} forks/s · {d} tasks", .{ cs, s.forks_ps.get() orelse 0, s.thread_count.get() orelse 0 }), .activity);
    if (s.psi_cpu.some10.get()) |cpu| try add(&out, a, "Pressure", try std.fmt.allocPrint(a, "cpu {d:.1}% · memory {d:.1}% · io {d:.1}% (some, 10 s)", .{ cpu, s.psi_memory.some10.get() orelse 0, s.psi_io.some10.get() orelse 0 }), if (x.gui) .pressure else .none);
    {
        var tb: std.ArrayList(u8) = .empty;
        if (s.cpu_package_temp.get()) |t| {
            if (s.cpu_temp_label.len > 0)
                try part(a, &tb, "{s} {d:.0} °C{s}", .{ s.cpu_temp_label, @round(t), nice(t, x.gui) })
            else
                try part(a, &tb, "CPU {d:.0} °C{s}", .{ @round(t), nice(t, x.gui) });
        }
        for (s.gpus) |g| if (g.temp_c.get()) |t| try part(a, &tb, "GPU {d:.0} °C{s}", .{ @round(t), nice(t, x.gui) });
        for (s.disks) |d| if (d.temp_c.get()) |t| if (std.mem.startsWith(u8, d.name, "nvme")) {
            try part(a, &tb, "NVMe {d:.0} °C", .{t});
            break;
        };
        for (s.sensors) |sensor| if (sensor.kind == .fan) if (sensor.value.get()) |rpm| if (rpm > 0) {
            try part(a, &tb, "fan {d:.0} rpm", .{rpm});
            break;
        };
        try add(&out, a, "Temps", tb.items, if (x.gui) .temp else .none);
    }
    {
        var pb: std.ArrayList(u8) = .empty;
        if (s.cpu_package_power.get()) |w| {
            const word = if (std.mem.indexOf(u8, s.cpu_power_label, "System") != null) "System" else "CPU";
            try part(a, &pb, "{s} {d:.1} W", .{ word, w });
        }
        for (s.gpus) |g| if (g.power_w.get()) |w| try part(a, &pb, "GPU {d:.1} W", .{w});
        try add(&out, a, "Power", pb.items, if (x.gui) .power else .none);
    }
    for (st.nvme) |n| try add(&out, a, "NVMe", n, .none);
    if (x.gui) {
        var rd: ?f64 = if (s.disks.len > 0) 0 else null;
        var wr: f64 = 0;
        for (s.disks) |d| {
            rd = if (rd != null and d.read_bps.get() != null) rd.? + d.read_bps.get().? else null;
            wr += d.write_bps.get() orelse 0;
        }
        var r1: [32]u8 = undefined;
        var r2: [32]u8 = undefined;
        if (rd) |r| try add(&out, a, "Disk IO", try std.fmt.allocPrint(a, "read {s} · write {s}", .{ m.rate(&r1, r), m.rate(&r2, wr) }), .disk_io);
    }
    if (s.governor.ok()) try add(&out, a, "Governor", if (s.freq_driver.ok()) try std.fmt.allocPrint(a, "{s} · {s}", .{ s.governor.s, s.freq_driver.s }) else s.governor.s, .none);
    try add(&out, a, "Network", try network(a, s, ml, x), if (x.gui and ml == null) .net else .none);
    try add(&out, a, "Scheduler", st.scheduler, .none);
    {
        var fb: [128]u8 = undefined;
        if (readf(&fb, "/proc/sys/fs/file-nr", .{})) |nr| {
            var it = std.mem.tokenizeAny(u8, nr, " \t");
            if (it.next()) |open| try add(&out, a, "Open files", try std.fmt.allocPrint(a, "{s} handles system-wide", .{open}), .none);
        }
    }
    // The Vulkan device is a GPU name: hidden under redaction like the GPU line.
    if (x.gui and x.vulkan.len > 0) try add(&out, a, "xodb", try std.fmt.allocPrint(a, "Vulkan {s}", .{if (redact) "device hidden (redacted)" else x.vulkan}), .none);
    if (x.gui and (x.draw_ms != null or x.startup_ms != null)) try add(&out, a, "xodb frame", try std.fmt.allocPrint(a, "draw {d:.2} ms · first frame {d:.0} ms after start", .{ x.draw_ms orelse 0, x.startup_ms orelse 0 }), .none);
    if (x.bench) |r| {
        var sb: [256]u8 = undefined;
        try add(&out, a, "Benchmark", try std.fmt.allocPrint(a, "{s}", .{bench.summary(&sb, r)}), .none);
        var gb: [128]u8 = undefined;
        if (r.gpu_instances_ps) |ips| try add(&out, a, "GPU bench", try std.fmt.allocPrint(a, "{d:.1} M instances/s on {s} ({d} boxes at {d}x{d})", .{ ips / 1e6, bench.device(&gb, r, redact), r.gpu_instances, r.gpu_size[0], r.gpu_size[1] }), .none);
    }
    return out.items;
}

/// " (nice)" after a temperature that rounds to 69 °C, in the terminal card.
fn nice(t: f64, gui: bool) []const u8 {
    return if (!gui and @round(t) == 69) " (nice)" else "";
}

/// Physical links only (bridges, veth and tunnels repeat their traffic), in
/// and out: the panel's live MB/s and packets/s, or --fetch's totals since
/// boot (a show-off card, not a monitor: one read, no waiting); redacted,
/// the card's made-up numbers.
fn network(a: std.mem.Allocator, s: *const m.Snapshot, ml: ?Madlib, x: Extra) !?[]const u8 {
    if (!x.gui) {
        const t = if (ml) |k| k.totals else x.net_totals orelse return null;
        var b: [4][32]u8 = undefined;
        return try std.fmt.allocPrint(a, "in {s}, {s} pkts · out {s}, {s} pkts (total since boot)", .{ m.bytes(&b[0], t[0]), count(&b[1], t[1]), m.bytes(&b[2], t[2]), count(&b[3], t[3]) });
    }
    if (ml) |k| return try std.fmt.allocPrint(a, "in {d:.2} MB/s, {d:.0} pkt/s · out {d:.2} MB/s, {d:.0} pkt/s", .{ k.net[0], k.net[1], k.net[2], k.net[3] });
    const rx = s.net_rx_bps.get() orelse return null;
    const tx = s.net_tx_bps.get() orelse return null;
    var pps: ?[2]f64 = .{ 0, 0 };
    for (s.nets) |n| if (n.physical) {
        pps = if (pps != null and n.rx_pps.get() != null and n.tx_pps.get() != null) .{ pps.?[0] + n.rx_pps.get().?, pps.?[1] + n.tx_pps.get().? } else null;
    };
    if (pps) |p| return try std.fmt.allocPrint(a, "in {d:.2} MB/s, {d:.0} pkt/s · out {d:.2} MB/s, {d:.0} pkt/s", .{ rx / 1e6, p[0], tx / 1e6, p[1] });
    return try std.fmt.allocPrint(a, "in {d:.2} MB/s · out {d:.2} MB/s", .{ rx / 1e6, tx / 1e6 });
}

/// 980, 12.3 k, 456 M, 1.23 G: three figures, as m.bytes.
fn count(buf: []u8, v: f64) []const u8 {
    const units = [_][]const u8{ "", " k", " M", " G", " T" };
    var x = v;
    var i: usize = 0;
    while (x >= 1000 and i + 1 < units.len) : (i += 1) x /= 1000;
    return (if (i == 0 or x >= 100) std.fmt.bufPrint(buf, "{d:.0}{s}", .{ x, units[i] }) else if (x >= 10) std.fmt.bufPrint(buf, "{d:.1}{s}", .{ x, units[i] }) else std.fmt.bufPrint(buf, "{d:.2}{s}", .{ x, units[i] })) catch "?";
}

/// Bytes and packets in and out since boot, summed over the links the
/// collector marks physical, from /proc/net/dev text; null when none is.
pub fn netTotals(text: []const u8, nets: []const m.Net) ?[4]f64 {
    var t: [4]f64 = .{ 0, 0, 0, 0 };
    var any = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const physical = for (nets) |n| (if (std.mem.eql(u8, n.name, name)) break n.physical) else false;
        if (!physical) continue;
        // rx bytes packets errs drop fifo frame compressed multicast, tx bytes packets ...
        var v: [10]f64 = undefined;
        var f = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        for (&v) |*x| x.* = @floatFromInt(std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null);
        t = .{ t[0] + v[0], t[1] + v[1], t[2] + v[8], t[3] + v[9] };
        any = true;
    }
    return if (any) t else null;
}

/// "user@host", or a neutral placeholder under redaction.
pub fn title(a: std.mem.Allocator, st: *const Static, s: *const m.Snapshot) ![]const u8 {
    if (st.redacted or !s.hostname.ok()) return "user@host";
    return std.fmt.allocPrint(a, "{s}@{s}", .{ st.user, s.hostname.s });
}

// --- Sampling for the CLI ---------------------------------------------------------

/// One collector sample of the groups the card reads, converted to the
/// overview's model. Rates are absent (one sample); unredacted, the network
/// group is there for its physical-link flags (see netTotals).
pub fn sample(a: std.mem.Allocator, redact: bool) !*m.Snapshot {
    var limits: c.struct_xrt_sys_limits = undefined;
    c.xrt_sys_limits_default(&limits);
    const ids = [_]c_uint{ c.XRT_SYS_G_SUMMARY, c.XRT_SYS_G_CPU, c.XRT_SYS_G_MEMORY, c.XRT_SYS_G_DISKS, c.XRT_SYS_G_FILESYSTEMS, c.XRT_SYS_G_POWER, c.XRT_SYS_G_SYSINFO };
    var mask: u32 = 0;
    for (ids) |id| mask |= @as(u32, 1) << @intCast(id);
    const net: u32 = @as(u32, 1) << @intCast(c.XRT_SYS_G_NETWORK);
    if (!redact) mask |= net;
    limits.groups = mask;
    limits.flags = if (redact) c.XRT_SYS_REDACT else c.XRT_SYS_SHOW_HOSTNAME;
    const ctx = c.xrt_sys_open(&limits) orelse return error.OutOfMemory;
    defer c.xrt_sys_close(ctx);
    c.xrt_sys_configure(ctx, mask, limits.flags);
    const raw = try std.heap.c_allocator.create(c.struct_xrt_sys_snapshot);
    defer std.heap.c_allocator.destroy(raw);
    raw.* = std.mem.zeroes(c.struct_xrt_sys_snapshot);
    if (c.xrt_sys_sample(ctx, raw) != c.XRT_OK) return error.OutOfMemory;
    defer c.xrt_sys_snapshot_free(raw);
    if (redact) c.xrt_sys_snapshot_redact(raw);
    const s = try a.create(m.Snapshot);
    s.* = .{};
    try @import("sysstat.zig").convert(a, raw, s);
    return s;
}

// --- Terminal output ----------------------------------------------------------------

const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    fn print(self: *Out, comptime fmt: []const u8, args: anytype) void {
        self.buf.print(self.a, fmt, args) catch {};
    }
    fn flush(self: *Out) void {
        var done: usize = 0;
        while (done < self.buf.items.len) {
            const n = c.write(1, self.buf.items.ptr + done, self.buf.items.len - done);
            if (n <= 0) break;
            done += @intCast(n);
        }
    }
};

const logo_cols = 32;
const logo_rows = 16; // two pixel rows per text row ("▀")

/// What the terminal can show: nothing (a pipe or NO_COLOR), the 16 basic
/// colours, the 256-colour cube, or 24-bit colour (COLORTERM). The logo needs
/// UTF-8 for its half blocks; without it the card is text only.
pub const Term = struct {
    depth: enum { none, basic, cube, truecolor } = .none,
    utf8: bool = false,

    pub fn detect(tty: bool) Term {
        const term = env("TERM") orelse "";
        if (!tty or env("NO_COLOR") != null or std.mem.eql(u8, term, "dumb")) return .{};
        const ct = env("COLORTERM") orelse "";
        const lang = env("LC_ALL") orelse env("LC_CTYPE") orelse env("LANG") orelse "";
        return .{
            .depth = if (std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit")) .truecolor else if (std.mem.indexOf(u8, term, "256") != null or std.mem.indexOf(u8, term, "direct") != null) .cube else .basic,
            .utf8 = std.ascii.indexOfIgnoreCase(lang, "utf-8") != null or std.ascii.indexOfIgnoreCase(lang, "utf8") != null,
        };
    }
    /// The SGR parameters of a foreground (38/30) or background (48/40) colour.
    fn sgr(self: Term, buf: []u8, rgb: [3]u8, bg: bool) []const u8 {
        return switch (self.depth) {
            .none => "",
            .truecolor => std.fmt.bufPrint(buf, "{d};2;{d};{d};{d}", .{ @as(u8, if (bg) 48 else 38), rgb[0], rgb[1], rgb[2] }) catch "",
            .cube => std.fmt.bufPrint(buf, "{d};5;{d}", .{ @as(u8, if (bg) 48 else 38), 16 + 36 * @as(u32, cube(rgb[0])) + 6 * @as(u32, cube(rgb[1])) + cube(rgb[2]) }) catch "",
            .basic => blk: {
                // The nearest of the 8 colours, bright when light.
                const k = @as(u8, @intFromBool(rgb[0] > 96)) | @as(u8, @intFromBool(rgb[1] > 96)) << 1 | @as(u8, @intFromBool(rgb[2] > 96)) << 2;
                const bright = @max(rgb[0], rgb[1], rgb[2]) > 200;
                break :blk std.fmt.bufPrint(buf, "{d}", .{@as(u8, if (bg) (if (bright) 100 else 40) else (if (bright) 90 else 30)) + k}) catch "";
            },
        };
    }
    fn cube(v: u8) u8 {
        return if (v < 48) 0 else if (v < 115) 1 else @intCast((@as(u32, v) - 35) / 40);
    }
};

/// The logo as half-block cells, one string per text row.
fn logoRows(a: std.mem.Allocator, img: *const png.Image, t: Term) ![logo_rows][]const u8 {
    var rows: [logo_rows][]const u8 = undefined;
    for (0..logo_rows) |r| {
        var line: std.ArrayList(u8) = .empty;
        for (0..logo_cols) |col| {
            const top = png.block(img, logo_cols, logo_rows * 2, @intCast(col), @intCast(r * 2));
            const bottom = png.block(img, logo_cols, logo_rows * 2, @intCast(col), @intCast(r * 2 + 1));
            var fb: [24]u8 = undefined;
            var bb: [24]u8 = undefined;
            const t_on = top[3] >= 96;
            const b_on = bottom[3] >= 96;
            if (t_on and b_on) {
                try line.print(a, "\x1b[{s};{s}m▀\x1b[0m", .{ t.sgr(&fb, top[0..3].*, false), t.sgr(&bb, bottom[0..3].*, true) });
            } else if (t_on or b_on) {
                const px = if (t_on) top else bottom;
                try line.print(a, "\x1b[{s}m{s}\x1b[0m", .{ t.sgr(&fb, px[0..3].*, false), if (t_on) "▀" else "▄" });
            } else try line.append(a, ' ');
        }
        rows[r] = line.items;
    }
    return rows;
}

pub fn render(a: std.mem.Allocator, out: *Out, st: *const Static, head: []const u8, list: []const Line, t: Term) !void {
    const color = t.depth != .none;
    var kb: [24]u8 = undefined;
    const key = if (color) try std.fmt.allocPrint(a, "\x1b[1;{s}m", .{t.sgr(&kb, st.tint orelse .{ 23, 147, 209 }, false)}) else "";
    const reset = if (color) "\x1b[0m" else "";
    var text_rows: std.ArrayList([]const u8) = .empty;
    try text_rows.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ key, head, reset }));
    try text_rows.append(a, ("-" ** 64)[0..@min(64, std.unicode.utf8CountCodepoints(head) catch head.len)]);
    for (list) |l| try text_rows.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}: {s}", .{ key, l.key, reset, l.value }));
    if (color) {
        try text_rows.append(a, "");
        for (0..2) |row| {
            var blocks: std.ArrayList(u8) = .empty;
            for (0..8) |k| try blocks.print(a, "\x1b[{d}m   ", .{(if (row == 0) @as(usize, 40) else 100) + k});
            try blocks.appendSlice(a, "\x1b[0m");
            try text_rows.append(a, blocks.items);
        }
    }
    // The distribution's PNG as half blocks, or (redacted) the retro ASCII logo.
    var png_rows: [logo_rows][]const u8 = undefined;
    var logo: ?[]const []const u8 = null;
    var logo_w: usize = logo_cols;
    if (color and t.utf8) if (st.logo) |*img| {
        png_rows = try logoRows(a, img, t);
        logo = &png_rows;
    };
    if (color) if (st.madlib) |ml| {
        const art = retro[ml.system].logo;
        logo_w = 0;
        for (art) |row| logo_w = @max(logo_w, row.len);
        const rows = try a.alloc([]const u8, art.len);
        for (rows, art) |*r, row| r.* = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ key, row, reset, (" " ** 64)[0..@min(64, logo_w - row.len)] });
        logo = rows;
    };
    const logo_n = if (logo) |rows| rows.len else 0;
    const n = @max(text_rows.items.len, logo_n);
    for (0..n) |i| {
        if (logo) |rows| {
            if (i < logo_n) out.print("{s}", .{rows[i]}) else out.print("{s}", .{(" " ** 64)[0..@min(64, logo_w)]});
            out.print("   ", .{});
        }
        if (i < text_rows.items.len) out.print("{s}", .{text_rows.items[i]});
        out.print("\n", .{});
    }
}

fn json(a: std.mem.Allocator, head: []const u8, redacted: bool, list: []const Line, result: ?bench.Result) ![]const u8 {
    const J = struct { key: []const u8, value: []const u8 };
    const items = try a.alloc(J, list.len);
    for (items, list) |*j, l| j.* = .{ .key = l.key, .value = l.value };
    return std.json.Stringify.valueAlloc(a, .{ .schema = 1, .title = head, .redacted = redacted, .lines = items, .bench = result, .bench_method = if (result != null) bench.method else "" }, .{});
}

/// `xodb --fetch`: print the card and exit.
pub fn main(args: []const [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var as_json = false;
    var redact = false;
    var run_bench = false;
    var mb: u32 = bench.default_mb;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--fetch")) continue;
        if (std.mem.eql(u8, arg, "--json")) as_json = true else if (std.mem.eql(u8, arg, "--redact")) redact = true else if (std.mem.eql(u8, arg, "--bench")) run_bench = true else if (std.mem.eql(u8, arg, "--bench-mb") and i + 1 < args.len) {
            i += 1;
            mb = std.fmt.parseInt(u32, args[i], 10) catch 0;
            if (mb < 1 or mb > 4096) {
                std.debug.print("xodb: --bench-mb takes 1..4096\n{s}", .{usage});
                return error.InvalidFetchOption;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var o = Out{ .a = a };
            o.print("{s}", .{usage});
            o.flush();
            return;
        } else {
            std.debug.print("xodb: --fetch does not accept {s}\n{s}", .{ arg, usage });
            return error.InvalidFetchOption;
        }
    }
    var st = try Static.read(std.heap.c_allocator, redact, true, null);
    defer {
        if (st.logo) |*img| img.deinit(std.heap.c_allocator);
        st.deinit();
    }
    const s = try sample(a, redact);
    var result: ?bench.Result = null;
    if (run_bench) {
        if (!as_json) std.debug.print("xodb: benchmarking ({d} MiB buffers, about 2 s)...\n", .{mb});
        var progress = bench.Progress{};
        result = try bench.run(std.heap.c_allocator, mb, &progress);
        bench.save(a, result.?) catch |err| std.debug.print("xodb: benchmark result not saved: {s}\n", .{@errorName(err)});
    } else result = bench.load(a);
    // The saved GPU device is a GPU name: not in redacted JSON.
    if (redact) if (result) |*r| {
        r.gpu_device = "";
    };
    var nb: [32768]u8 = undefined;
    const totals = if (redact) null else if (readZ(&nb, "/proc/net/dev")) |t| netTotals(t, s.nets) else null;
    const list = try lines(a, &st, s, .{ .bench = result, .net_totals = totals });
    const head = try title(a, &st, s);
    var out = Out{ .a = a };
    if (as_json) {
        out.print("{s}\n", .{try json(a, head, redact, list, result)});
    } else {
        try render(a, &out, &st, head, list, Term.detect(c.isatty(1) == 1));
    }
    out.flush();
}

test "fetch lines keep fastfetch order, omit the unmeasured and honour redaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = Static{ .arena = .init(std.testing.allocator), .redacted = false, .user = "demo", .os_name = "Demo Linux", .shell = "zsh", .packages = "12 (pacman)" };
    defer st.deinit();
    var s = m.Snapshot{ .hostname = m.Text.of("demo-host"), .kernel = m.Text.of("6.1.0"), .arch = m.Text.of("x86_64"), .uptime_s = m.F.of(90061), .cpu_model = m.Text.of("Demo CPU") };
    s.memory.total = m.U.of(8 << 30);
    s.memory.used = m.U.of(2 << 30);
    s.memory.swap_total = m.U.of(0);
    const list = try lines(a, &st, &s, .{});
    var keys: std.ArrayList(u8) = .empty;
    for (list) |l| try keys.print(a, "{s},", .{l.key});
    try std.testing.expect(std.mem.startsWith(u8, keys.items, "OS,Kernel,Uptime,Packages,Shell,CPU,Memory,"));
    try std.testing.expect(std.mem.indexOf(u8, keys.items, "Swap") == null);
    try std.testing.expectEqualStrings("1 day, 1 hour, 1 min", list[2].value);
    try std.testing.expectEqualStrings("2.00 GiB / 8.00 GiB (25%)", list[6].value);
    try std.testing.expectEqualStrings("demo@demo-host", try title(a, &st, &s));
    st.redacted = true;
    st.madlib = Madlib.pick(7);
    const sys = retro[st.madlib.?.system];
    const hidden = try lines(a, &st, &s, .{});
    try std.testing.expectEqualStrings("user@host", try title(a, &st, &s));
    try std.testing.expectEqualStrings(sys.os, hidden[0].value);
    try std.testing.expectEqualStrings("Kernel", hidden[1].key);
    try std.testing.expectEqualStrings(sys.kernel, hidden[1].value);
    for (hidden) |l| try std.testing.expect(std.mem.indexOf(u8, l.value, "6.1.0") == null);
    var out = Out{ .a = a };
    try render(a, &out, &st, "user@host", hidden, .{});
    try std.testing.expect(std.mem.indexOf(u8, out.buf.items, "demo-host") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.buf.items, "\x1b") == null);
    try std.testing.expect(std.mem.startsWith(u8, out.buf.items, "user@host\n---------\nOS: "));
    // Coloured, the retro ASCII logo leads the card.
    var tty = Out{ .a = a };
    try render(a, &tty, &st, "user@host", hidden, .{ .depth = .truecolor });
    try std.testing.expect(std.mem.indexOf(u8, tty.buf.items, sys.logo[1]) != null);
    // One seed, one card: the same pick every time.
    try std.testing.expectEqual(Madlib.pick(7).system, Madlib.pick(7).system);
}

test "a temperature rounding to 69 °C is nice in the terminal card only; no Mitigations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = Static{ .arena = .init(std.testing.allocator), .redacted = false };
    defer st.deinit();
    var s = m.Snapshot{ .cpu_package_temp = m.F.of(68.6), .net_rx_bps = m.F.of(2e6), .net_tx_bps = m.F.of(5e5) };
    s.nets = &.{
        .{ .name = "eth0", .physical = true, .rx_pps = m.F.of(1500), .tx_pps = m.F.of(400) },
        .{ .name = "br0", .rx_pps = m.F.of(9999), .tx_pps = m.F.of(9999) },
    };
    const value = struct {
        fn f(list: []const Line, key: []const u8) ?[]const u8 {
            for (list) |l| if (std.mem.eql(u8, l.key, key)) return l.value;
            return null;
        }
    }.f;
    // /proc/net/dev: only eth0 is physical.
    const dev =
        \\Inter-|   Receive                                                |  Transmit
        \\ face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
        \\    lo: 9999999    9999    0    0    0     0          0         0  9999999    9999    0    0    0     0       0          0
        \\  eth0: 1288490188800 980000000 0 0 0 0 0 0 332859965440 410000000 0 0 0 0 0 0
        \\   br0: 777777    77    0    0    0     0          0         0   777777      77    0    0    0     0       0          0
    ;
    const totals = netTotals(dev, s.nets).?;
    try std.testing.expectEqual([4]f64{ 1288490188800, 980000000, 332859965440, 410000000 }, totals);
    var list = try lines(a, &st, &s, .{ .net_totals = totals });
    try std.testing.expectEqualStrings("CPU 69 °C (nice)", value(list, "Temps").?);
    try std.testing.expectEqualStrings("in 1.17 TiB, 980 M pkts · out 310 GiB, 410 M pkts (total since boot)", value(list, "Network").?);
    try std.testing.expect(netTotals(dev, &.{}) == null);
    try std.testing.expect(value(list, "Mitigations") == null);
    list = try lines(a, &st, &s, .{ .gui = true });
    try std.testing.expectEqualStrings("CPU 69 °C", value(list, "Temps").?);
    try std.testing.expectEqualStrings("in 2.00 MB/s, 1500 pkt/s · out 0.50 MB/s, 400 pkt/s", value(list, "Network").?);
    s.cpu_package_temp = m.F.of(68.5);
    list = try lines(a, &st, &s, .{});
    try std.testing.expectEqualStrings("CPU 69 °C (nice)", value(list, "Temps").?);
    s.cpu_package_temp = m.F.of(69.6);
    list = try lines(a, &st, &s, .{});
    try std.testing.expectEqualStrings("CPU 70 °C", value(list, "Temps").?);
    st.madlib = Madlib.pick(3);
    list = try lines(a, &st, &s, .{ .net_totals = totals });
    try std.testing.expect(!std.mem.startsWith(u8, value(list, "Network").?, "in 1.17 TiB"));
    try std.testing.expect(std.mem.endsWith(u8, value(list, "Network").?, "pkts (total since boot)"));
    list = try lines(a, &st, &s, .{ .gui = true });
    try std.testing.expect(!std.mem.startsWith(u8, value(list, "Network").?, "in 2.00 MB/s"));
    s.cpu_temp_label = "P-cluster Temperature 2";
    s.cpu_package_temp = m.F.of(44.2);
    list = try lines(a, &st, &s, .{});
    try std.testing.expectEqualStrings("P-cluster Temperature 2 44 °C", value(list, "Temps").?);
}

test "EDID preferred timing and name; ANSI colour from os-release" {
    var e: [128]u8 = @splat(0);
    e[0..8].* = "\x00\xff\xff\xff\xff\xff\xff\x00".*;
    // 1920x1080, 148.5 MHz, blanking 280 x 45: 60 Hz
    e[54..72].* = .{ 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    e[72..90].* = .{ 0, 0, 0, 0xfc, 0, 'D', 'e', 'm', 'o', ' ', 'M', 'o', 'n', '\n', ' ', ' ', ' ', ' ' };
    const d = edid(&e).?;
    try std.testing.expectEqual(@as(u32, 1920), d.w);
    try std.testing.expectEqual(@as(u32, 1080), d.h);
    try std.testing.expect(@abs(d.hz - 60) < 0.01);
    try std.testing.expectEqualStrings("Demo Mon", d.name);
    try std.testing.expectEqual([3]u8{ 23, 147, 209 }, ansiColor("38;2;23;147;209").?);
    try std.testing.expectEqual([3]u8{ 36, 114, 200 }, ansiColor("1;34").?);
    var sb: [24]u8 = undefined;
    try std.testing.expectEqualStrings("38;2;23;147;209", (Term{ .depth = .truecolor }).sgr(&sb, .{ 23, 147, 209 }, false));
    try std.testing.expectEqualStrings("48;5;32", (Term{ .depth = .cube }).sgr(&sb, .{ 23, 147, 209 }, true));
    try std.testing.expectEqualStrings("96", (Term{ .depth = .basic }).sgr(&sb, .{ 23, 147, 209 }, false));
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0 mins", uptime(&b, 30, false));
    try std.testing.expectEqualStrings("2 hours, 1 sec", uptime(&b, 7201, true));
}
