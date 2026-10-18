//! Which Wi-Fi cards exist, what each can contribute, and which are in use.
//!
//! An interface is in use when it is associated (or up with a link in any
//! mode), up with a default route, shares its card with another interface
//! that is up, or is managed by NetworkManager, iwd, ConnMan, wpa_supplicant
//! or hostapd (read-only checks of their runtime files and processes; a
//! manager that does not say which cards it holds claims them all). In-use cards are only ever read
//! (station, survey, gateway ping); monitor mode and spectral scan need an
//! explicit choice (`--radio NAME`) of a card that is not in use.
const std = @import("std");
const fsx = @import("fsx.zig");
const nl = @import("nl80211.zig");

pub const Roots = struct {
    sys: []const u8 = "/sys",
    proc: []const u8 = "/proc",
    run: []const u8 = "/run",
    debug: []const u8 = "/sys/kernel/debug",
};

pub const Spectral = enum {
    /// ath9k / ath9k_htc: the HT20 sample reader here applies.
    ath9k,
    /// ath10k / ath11k have spectral scan; xodb does not read their samples yet.
    other_driver,
    none,
};
pub const Role = enum { in_use, spare, blocked, absent };

pub fn Text(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,
        const Self = @This();
        pub fn set(self: *Self, s: []const u8) void {
            self.len = @min(s.len, n);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }
        pub fn add(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const sep = if (self.len > 0) "; " else "";
            const got = std.fmt.bufPrint(self.buf[self.len..], "{s}" ++ fmt, .{sep} ++ args) catch return;
            self.len += got.len;
        }
        pub fn get(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Card = struct {
    phy: Text(16) = .{},
    phy_index: u32 = 0,
    iface: Text(16) = .{},
    ifindex: u32 = 0,
    driver: Text(32) = .{},
    bus: Text(8) = .{},
    up: bool = false,
    carrier: bool = false,
    default_route: bool = false,
    /// nl80211 interface type (2 station, 6 monitor), when it could be read.
    iftype: ?u32 = null,
    freq_mhz: ?u32 = null,
    monitor: ?bool = null,
    soft_blocked: bool = false,
    hard_blocked: bool = false,
    rfkill: Text(16) = .{},
    managed_by: ?[]const u8 = null,
    spectral: Spectral = .none,
    /// The debugfs control was found (needs root to look).
    spectral_dir: Text(96) = .{},
    spectral_checked: bool = false,
    role: Role = .absent,
    why: Text(200) = .{},

    pub fn associated(self: *const Card) bool {
        return self.up and self.carrier and (self.iftype orelse nl.iftype.station) == nl.iftype.station;
    }
    /// Why monitor/spectral must not be used on this card, or null.
    pub fn refusal(self: *const Card, buf: []u8) ?[]const u8 {
        return switch (self.role) {
            .in_use => std.fmt.bufPrint(buf, "{s} is in use ({s}): xodb only reads it passively", .{ self.iface.get(), self.why.get() }) catch "in use",
            .blocked => if (self.hard_blocked)
                std.fmt.bufPrint(buf, "{s} is switched off by a hardware radio switch (rfkill)", .{self.iface.get()}) catch "blocked"
            else
                std.fmt.bufPrint(buf, "{s} is switched off by rfkill (soft block); xodb does not unblock radios, because a network manager may then start scanning. If nothing manages it, `rfkill unblock {s}` and run again", .{ self.iface.get(), self.rfkill.get()[@min(6, self.rfkill.len)..] }) catch "blocked",
            .absent => "no network interface on this card",
            .spare => null,
        };
    }
    /// What the card can contribute, in words.
    pub fn contributes(self: *const Card, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        switch (self.role) {
            .in_use => w.print("passive link evidence: signal, bitrate, retries, channel survey, gateway ping", .{}) catch {},
            .spare, .blocked => {
                if (self.spectral == .ath9k) w.print("2.4 GHz waterfall (ath9k spectral scan, root) with --radio {s}", .{self.iface.get()}) catch {} else if (self.spectral == .other_driver) w.print("spectral-capable driver ({s}), not read by xodb yet", .{self.driver.get()}) catch {} else if (self.monitor orelse false) w.print("receive-only traffic counts per channel (frames, airtime, retries, networks) with --traffic {s}", .{self.iface.get()}) catch {} else w.print("nothing for burrito mode", .{}) catch {};
                if (self.role == .blocked) w.print(" once unblocked", .{}) catch {};
            },
            .absent => {},
        }
        return w.buffered();
    }
};

pub const max_cards = 8;
pub const List = struct {
    cards: [max_cards]Card = undefined,
    len: usize = 0,
    connman: bool = false,
    pub fn items(self: *const List) []const Card {
        return self.cards[0..self.len];
    }
    pub fn find(self: *const List, iface: []const u8) ?*const Card {
        for (self.items()) |*c| if (std.mem.eql(u8, c.iface.get(), iface)) return c;
        return null;
    }
    /// What is missing for burrito mode, honestly.
    pub fn needs(self: *const List, buf: []u8) []const u8 {
        var spectral_free = false;
        var spectral_any = false;
        var spectral_blocked = false;
        var link = false;
        for (self.items()) |*c| {
            if (c.spectral == .ath9k) spectral_any = true;
            if (c.spectral == .ath9k and c.role == .spare) spectral_free = true;
            if (c.spectral == .ath9k and c.role == .blocked) spectral_blocked = true;
            if (c.role == .in_use and c.associated()) link = true;
        }
        const tail = if (link) "" else "; no associated Wi-Fi link, so no link lanes";
        const t = if (self.len == 0)
            std.fmt.bufPrint(buf, "no Wi-Fi cards: an AR9271 USB adapter adds the 2.4 GHz waterfall", .{})
        else if (spectral_free)
            std.fmt.bufPrint(buf, "spectral-capable card available: run as root with --radio NAME for the waterfall{s}", .{tail})
        else if (spectral_blocked)
            std.fmt.bufPrint(buf, "the spectral-capable card is switched off by rfkill: unblock it (if nothing manages it) for the waterfall{s}", .{tail})
        else if (spectral_any)
            std.fmt.bufPrint(buf, "the spectral-capable card is in use: it is only read passively; a second (spare) AR9271 adds the waterfall{s}", .{tail})
        else
            std.fmt.bufPrint(buf, "no spectral-capable adapter: showing link-quality evidence only; an AR9271 USB adapter adds the 2.4 GHz waterfall{s}", .{tail});
        return t catch "";
    }
};

const Procs = struct { iwd: bool = false, connman: bool = false, nm: bool = false, hostapd: bool = false, wpa_any: bool = false, wpa_ifaces: Text(160) = .{} };
fn scanProcs(roots: Roots) Procs {
    var p = Procs{};
    const Ctx = struct { roots: Roots, p: *Procs };
    fsx.list("{s}", .{roots.proc}, Ctx{ .roots = roots, .p = &p }, struct {
        fn f(ctx: Ctx, name: []const u8) bool {
            if (name.len == 0 or !std.ascii.isDigit(name[0])) return true;
            var b: [64]u8 = undefined;
            const comm = fsx.line(&b, "{s}/{s}/comm", .{ ctx.roots.proc, name }) orelse return true;
            if (std.mem.eql(u8, comm, "iwd")) ctx.p.iwd = true;
            if (std.mem.eql(u8, comm, "connmand")) ctx.p.connman = true;
            if (std.mem.eql(u8, comm, "NetworkManager")) ctx.p.nm = true;
            if (std.mem.eql(u8, comm, "hostapd")) ctx.p.hostapd = true;
            if (std.mem.eql(u8, comm, "wpa_supplicant")) {
                // -iNAME or -i NAME on its command line names a managed interface.
                var cb: [2048]u8 = undefined;
                const cmdline = fsx.read(&cb, "{s}/{s}/cmdline", .{ ctx.roots.proc, name }) orelse return true;
                var it = std.mem.splitScalar(u8, cmdline, 0);
                var want = false;
                var named = false;
                while (it.next()) |arg| {
                    if (want) ctx.p.wpa_ifaces.add("{s}", .{arg});
                    want = std.mem.eql(u8, arg, "-i");
                    if (std.mem.startsWith(u8, arg, "-i") and arg.len > 2) ctx.p.wpa_ifaces.add("{s}", .{arg[2..]});
                    if (std.mem.startsWith(u8, arg, "-i")) named = true;
                }
                // D-Bus mode (-u, NetworkManager's or ConnMan's backend): any card may be added at any time.
                if (!named) ctx.p.wpa_any = true;
            }
            return true;
        }
    }.f);
    return p;
}

fn defaultRoute(roots: Roots, iface: []const u8) bool {
    var b: [16384]u8 = undefined;
    if (fsx.read(&b, "{s}/net/route", .{roots.proc})) |t| {
        var lines = std.mem.splitScalar(u8, t, '\n');
        _ = lines.next();
        while (lines.next()) |l| {
            var f = std.mem.tokenizeAny(u8, l, " \t");
            const name = f.next() orelse continue;
            const dest = f.next() orelse continue;
            if (std.mem.eql(u8, name, iface) and std.mem.eql(u8, dest, "00000000")) return true;
        }
    }
    if (fsx.read(&b, "{s}/net/ipv6_route", .{roots.proc})) |t| {
        var lines = std.mem.splitScalar(u8, t, '\n');
        while (lines.next()) |l| {
            var f = std.mem.tokenizeAny(u8, l, " \t");
            const dest = f.next() orelse continue;
            const plen = f.next() orelse continue;
            var name: []const u8 = "";
            while (f.next()) |x| name = x;
            if (std.mem.eql(u8, name, iface) and std.mem.eql(u8, plen, "00") and std.mem.allEqual(u8, dest, '0')) return true;
        }
    }
    return false;
}

/// Reads the cards. `sock` (nl80211) adds interface type, channel and
/// monitor support; without it those stay unknown.
pub fn enumerate(roots: Roots, sock: ?*nl.Socket) List {
    var list = List{};
    const procs = scanProcs(roots);
    list.connman = procs.connman;
    const Ctx = struct { list: *List };
    fsx.list("{s}/class/ieee80211", .{roots.sys}, Ctx{ .list = &list }, struct {
        fn f(ctx: Ctx, name: []const u8) bool {
            if (ctx.list.len >= max_cards) return false;
            var c = Card{};
            c.phy.set(name);
            ctx.list.cards[ctx.list.len] = c;
            ctx.list.len += 1;
            return true;
        }
    }.f);
    std.mem.sortUnstable(Card, list.cards[0..list.len], {}, struct {
        fn lt(_: void, a: Card, b: Card) bool {
            return std.mem.order(u8, a.phy.get(), b.phy.get()) == .lt;
        }
    }.lt);
    for (list.cards[0..list.len]) |*c| fill(roots, c, &procs, sock);
    return list;
}

fn fill(roots: Roots, c: *Card, procs: *const Procs, sock: ?*nl.Socket) void {
    const phy = c.phy.get();
    c.phy_index = @intCast(fsx.number("{s}/class/ieee80211/{s}/index", .{ roots.sys, phy }) orelse 0);
    var b: [128]u8 = undefined;
    if (fsx.linkBase(&b, "{s}/class/ieee80211/{s}/device/driver", .{ roots.sys, phy })) |d| c.driver.set(d);
    if (fsx.linkBase(&b, "{s}/class/ieee80211/{s}/device/subsystem", .{ roots.sys, phy })) |d| c.bus.set(d);
    const Ctx = struct { c: *Card };
    // The first interface (by name) speaks for the card; any other one that is up makes it in use.
    var siblings = Text(160){};
    const NetCtx = struct { c: *Card, all: *Text(160) };
    fsx.list("{s}/class/ieee80211/{s}/device/net", .{ roots.sys, phy }, NetCtx{ .c = c, .all = &siblings }, struct {
        fn f(ctx: NetCtx, name: []const u8) bool {
            if (ctx.c.iface.len == 0 or std.mem.order(u8, name, ctx.c.iface.get()) == .lt) ctx.c.iface.set(name);
            ctx.all.add("{s}", .{name});
            return true;
        }
    }.f);
    fsx.list("{s}/class/ieee80211/{s}", .{ roots.sys, phy }, Ctx{ .c = c }, struct {
        fn f(ctx: Ctx, name: []const u8) bool {
            if (std.mem.startsWith(u8, name, "rfkill")) ctx.c.rfkill.set(name);
            return true;
        }
    }.f);
    if (c.rfkill.len > 0) {
        c.soft_blocked = (fsx.number("{s}/class/ieee80211/{s}/{s}/soft", .{ roots.sys, phy, c.rfkill.get() }) orelse 0) != 0;
        c.hard_blocked = (fsx.number("{s}/class/ieee80211/{s}/{s}/hard", .{ roots.sys, phy, c.rfkill.get() }) orelse 0) != 0;
    }
    const drv = c.driver.get();
    c.spectral = if (std.mem.eql(u8, drv, "ath9k") or std.mem.eql(u8, drv, "ath9k_htc")) .ath9k else if (std.mem.startsWith(u8, drv, "ath10k") or std.mem.startsWith(u8, drv, "ath11k")) .other_driver else .none;
    if (c.spectral == .ath9k and fsx.exists("{s}/ieee80211/{s}/{s}/spectral_scan_ctl", .{ roots.debug, phy, drv })) {
        c.spectral_checked = true;
        var pb: [96]u8 = undefined;
        c.spectral_dir.set(std.fmt.bufPrint(&pb, "{s}/ieee80211/{s}/{s}", .{ roots.debug, phy, drv }) catch "");
    }
    if (sock) |s| c.monitor = s.supportsMonitor(c.phy_index) catch null;
    const iface = c.iface.get();
    if (iface.len == 0) {
        c.role = .absent;
        return;
    }
    c.ifindex = @intCast(fsx.number("{s}/class/net/{s}/ifindex", .{ roots.sys, iface }) orelse 0);
    c.up = ((fsx.number("{s}/class/net/{s}/flags", .{ roots.sys, iface }) orelse 0) & 1) != 0;
    c.carrier = c.up and (fsx.number("{s}/class/net/{s}/carrier", .{ roots.sys, iface }) orelse 0) == 1;
    c.default_route = defaultRoute(roots, iface);
    if (sock) |s| if (s.interface(c.ifindex)) |i| {
        c.iftype = i.iftype;
        c.freq_mhz = i.freq_mhz;
    } else |_| {};
    // Managers, read-only.
    var mb: [256]u8 = undefined;
    if (fsx.read(&mb, "{s}/NetworkManager/devices/{d}", .{ roots.run, c.ifindex })) |t| {
        if (std.mem.indexOf(u8, t, "managed=false") == null) c.managed_by = "NetworkManager";
    } else if (procs.nm) c.managed_by = "NetworkManager";
    if (c.managed_by == null and procs.iwd) c.managed_by = "iwd";
    if (c.managed_by == null and procs.connman) c.managed_by = "ConnMan";
    if (c.managed_by == null and (procs.wpa_any or fsx.exists("{s}/wpa_supplicant/{s}", .{ roots.run, iface }) or listed(procs.wpa_ifaces.get(), iface))) c.managed_by = "wpa_supplicant";
    if (c.managed_by == null and (procs.hostapd or fsx.exists("{s}/hostapd/{s}", .{ roots.run, iface }))) c.managed_by = "hostapd";

    if (c.associated()) c.why.add("associated", .{}) else if (c.carrier and (c.iftype orelse nl.iftype.station) != nl.iftype.monitor) c.why.add("up with a link", .{});
    {
        var it = std.mem.splitSequence(u8, siblings.get(), "; ");
        while (it.next()) |other| {
            if (other.len == 0 or std.mem.eql(u8, other, iface)) continue;
            if (((fsx.number("{s}/class/net/{s}/flags", .{ roots.sys, other }) orelse 0) & 1) != 0) c.why.add("{s} on the same card is up", .{other});
        }
    }
    if (c.up and c.default_route) c.why.add("up with a default route", .{});
    if (c.managed_by) |m| c.why.add("managed by {s}", .{m});
    if (c.why.len > 0) {
        c.role = .in_use;
    } else if (c.soft_blocked or c.hard_blocked) {
        c.role = .blocked;
        c.why.add("rfkill {s} block", .{if (c.hard_blocked) "hard" else "soft"});
    } else {
        c.role = .spare;
        c.why.add("{s}, not associated, no default route, no manager", .{if (c.up) "up" else "down"});
    }
}
fn listed(names: []const u8, iface: []const u8) bool {
    var it = std.mem.splitSequence(u8, names, "; ");
    while (it.next()) |n| if (std.mem.eql(u8, n, iface)) return true;
    return false;
}

// --- Tests: a synthetic sysfs/procfs tree ------------------------------------------

const testing = std.testing;
fn mk(dir: []const u8, comptime rel: []const u8, args: anytype, body: ?[]const u8) !void {
    var pb: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&pb, "{s}/" ++ rel, .{dir} ++ args);
    const parent = std.fs.path.dirname(p).?;
    var cb: [600]u8 = undefined;
    // mkdir -p
    var at: usize = 1;
    while (std.mem.indexOfScalarPos(u8, parent, at, '/')) |slash| : (at = slash + 1) {
        _ = std.os.linux.mkdir(try std.fmt.bufPrintZ(&cb, "{s}", .{parent[0..slash]}), 0o755);
    }
    _ = std.os.linux.mkdir(try std.fmt.bufPrintZ(&cb, "{s}", .{parent}), 0o755);
    if (body) |b| {
        const rc = std.os.linux.open(try std.fmt.bufPrintZ(&cb, "{s}", .{p}), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        try testing.expect(std.os.linux.errno(rc) == .SUCCESS);
        _ = std.os.linux.write(@intCast(rc), b.ptr, b.len);
        _ = std.os.linux.close(@intCast(rc));
    }
}
fn symlinkAt(dir: []const u8, comptime rel: []const u8, args: anytype, target: [:0]const u8) !void {
    var pb: [512]u8 = undefined;
    try mk(dir, rel, args, null);
    const p = try std.fmt.bufPrintZ(&pb, "{s}/" ++ rel, .{dir} ++ args);
    _ = std.os.linux.symlink(target, p);
}

fn phyTree(dir: []const u8, phy: []const u8, index: u8, driver: [:0]const u8, iface: []const u8, ifindex: u8, flags: []const u8, carrier: []const u8, soft: []const u8) !void {
    try mk(dir, "sys/class/ieee80211/{s}/index", .{phy}, &.{ '0' + index, '\n' });
    try symlinkAt(dir, "sys/class/ieee80211/{s}/device/driver", .{phy}, driver);
    try symlinkAt(dir, "sys/class/ieee80211/{s}/device/subsystem", .{phy}, "../../bus/usb");
    try mk(dir, "sys/class/ieee80211/{s}/device/net/{s}/x", .{ phy, iface }, "");
    try mk(dir, "sys/class/ieee80211/{s}/rfkill{d}/soft", .{ phy, index }, soft);
    try mk(dir, "sys/class/ieee80211/{s}/rfkill{d}/hard", .{ phy, index }, "0\n");
    try mk(dir, "sys/class/net/{s}/ifindex", .{iface}, &.{ '0' + ifindex, '\n' });
    try mk(dir, "sys/class/net/{s}/flags", .{iface}, flags);
    try mk(dir, "sys/class/net/{s}/carrier", .{iface}, carrier);
}

/// A laptop-like tree for tests: phy0 the built-in card, associated with the
/// default route and managed by wpa_supplicant (the internet link); phy1 a
/// spare USB AR9271; phy2 an rfkill-blocked ath9k.
pub fn writeTestTree(dir: []const u8) !void {
    // phy0: a laptop's built-in card, associated with the default route (the internet link).
    try phyTree(dir, "phy0", 0, "../../drivers/rtw89_8852be", "wlp1s0", 3, "0x1003\n", "1\n", "0\n");
    // phy1: a USB AR9271, down and spare.
    try phyTree(dir, "phy1", 1, "../../drivers/ath9k_htc", "wlan1", 5, "0x1002\n", "0\n", "0\n");
    // phy2: another ath9k, soft-blocked.
    try phyTree(dir, "phy2", 2, "../../drivers/ath9k", "wlan2", 6, "0x1002\n", "0\n", "1\n");
    try mk(dir, "proc/net/route", .{}, "Iface\tDestination\tGateway\nwlp1s0\t00000000\t0101A8C0\n");
    try mk(dir, "proc/1/comm", .{}, "init\n");
    try mk(dir, "proc/77/comm", .{}, "wpa_supplicant\n");
    try mk(dir, "proc/77/cmdline", .{}, "wpa_supplicant\x00-B\x00-i\x00wlp1s0\x00");
    try mk(dir, "run/x", .{}, "");
    try mk(dir, "debug/ieee80211/phy1/ath9k_htc/spectral_scan_ctl", .{}, "disable");
}
pub fn testRoots(buf: *[4][160]u8, dir: []const u8) !Roots {
    return .{
        .sys = try std.fmt.bufPrint(&buf[0], "{s}/sys", .{dir}),
        .proc = try std.fmt.bufPrint(&buf[1], "{s}/proc", .{dir}),
        .run = try std.fmt.bufPrint(&buf[2], "{s}/run", .{dir}),
        .debug = try std.fmt.bufPrint(&buf[3], "{s}/debug", .{dir}),
    };
}

test "in-use, spare and blocked cards from a synthetic tree" {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    try writeTestTree(dir);
    var rb: [4][160]u8 = undefined;
    const roots = Roots{
        .sys = try std.fmt.bufPrint(&rb[0], "{s}/sys", .{dir}),
        .proc = try std.fmt.bufPrint(&rb[1], "{s}/proc", .{dir}),
        .run = try std.fmt.bufPrint(&rb[2], "{s}/run", .{dir}),
        .debug = try std.fmt.bufPrint(&rb[3], "{s}/debug", .{dir}),
    };
    const list = enumerate(roots, null);
    try testing.expectEqual(@as(usize, 3), list.len);
    const laptop = list.find("wlp1s0").?;
    try testing.expectEqual(Role.in_use, laptop.role);
    try testing.expect(std.mem.indexOf(u8, laptop.why.get(), "associated") != null);
    try testing.expect(std.mem.indexOf(u8, laptop.why.get(), "default route") != null);
    try testing.expect(std.mem.indexOf(u8, laptop.why.get(), "wpa_supplicant") != null);
    var b: [400]u8 = undefined;
    try testing.expect(laptop.refusal(&b) != null);
    try testing.expectEqual(Spectral.none, laptop.spectral);
    const ar = list.find("wlan1").?;
    try testing.expectEqual(Role.spare, ar.role);
    try testing.expectEqual(Spectral.ath9k, ar.spectral);
    try testing.expect(ar.spectral_checked);
    try testing.expectEqual(@as(?[]const u8, null), ar.refusal(&b));
    try testing.expectEqualStrings("usb", ar.bus.get());
    const blocked = list.find("wlan2").?;
    try testing.expectEqual(Role.blocked, blocked.role);
    try testing.expect(std.mem.indexOf(u8, blocked.refusal(&b).?, "rfkill unblock 2`") != null);
    try testing.expect(std.mem.startsWith(u8, list.needs(&b), "spectral-capable card available"));
    // iwd running claims every card.
    try mk(dir, "proc/90/comm", .{}, "iwd\n");
    const with_iwd = enumerate(roots, null);
    try testing.expectEqual(Role.in_use, with_iwd.find("wlan1").?.role);
    try testing.expect(std.mem.startsWith(u8, with_iwd.needs(&b), "the spectral-capable card is in use"));
    _ = std.os.linux.unlink(try std.fmt.bufPrintZ(&b, "{s}/proc/90/comm", .{dir}));
    try testing.expectEqual(Role.spare, enumerate(roots, null).find("wlan1").?.role);
    // Managers that do not say which cards they hold claim them all.
    for ([_][]const u8{ "connmand\n", "NetworkManager\n", "hostapd\n" }) |comm| {
        try mk(dir, "proc/91/comm", .{}, comm);
        const l = enumerate(roots, null);
        try testing.expectEqual(Role.in_use, l.find("wlan1").?.role);
    }
    try mk(dir, "proc/91/comm", .{}, "wpa_supplicant\n");
    try mk(dir, "proc/91/cmdline", .{}, "wpa_supplicant\x00-u\x00-s\x00");
    try testing.expectEqual(Role.in_use, enumerate(roots, null).find("wlan1").?.role);
    _ = std.os.linux.unlink(try std.fmt.bufPrintZ(&b, "{s}/proc/91/comm", .{dir}));
    // A second interface on the same card that is up (an AP, a p2p or monitor vif) makes it in use.
    try mk(dir, "sys/class/ieee80211/phy1/device/net/wlan1ap/x", .{}, "");
    try mk(dir, "sys/class/net/wlan1ap/flags", .{}, "0x1003\n");
    const sib = enumerate(roots, null).find("wlan1").?;
    try testing.expectEqual(Role.in_use, sib.role);
    try testing.expect(std.mem.indexOf(u8, sib.why.get(), "wlan1ap on the same card is up") != null);
}
