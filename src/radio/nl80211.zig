//! A small nl80211 client over generic netlink: the reads burrito mode
//! needs (interface type and channel, station signal/bitrate/retries, the
//! channel survey, whether a wiphy supports monitor) and the two receive-only
//! changes it makes on an explicitly chosen card (interface type, channel).
//! Nothing here scans, associates or transmits. Interface up/down is an
//! ioctl on an inet socket (SIOCSIFFLAGS).
const std = @import("std");
const linux = std.os.linux;

pub const cmd = struct {
    pub const get_wiphy = 1;
    pub const set_wiphy = 2;
    pub const get_interface = 5;
    pub const set_interface = 6;
    pub const get_station = 17;
    pub const get_survey = 50;
};
pub const attr = struct {
    pub const wiphy = 1;
    pub const ifindex = 3;
    pub const ifname = 4;
    pub const iftype = 5;
    pub const sta_info = 21;
    pub const supported_iftypes = 32;
    pub const wiphy_freq = 38;
    pub const wiphy_channel_type = 39;
    pub const survey_info = 84;
    pub const split_wiphy_dump = 174;
};
pub const iftype = struct {
    pub const station = 2;
    pub const monitor = 6;
};
const sta = struct {
    const signal = 7;
    const tx_bitrate = 8;
    const tx_packets = 10;
    const tx_retries = 11;
    const tx_failed = 12;
    const signal_avg = 13;
    const beacon_loss = 18;
};
const rate_bitrate = 1;
const rate_bitrate32 = 5;
const survey = struct {
    const frequency = 1;
    const noise = 2;
    const in_use = 3;
    const time = 4;
    const time_busy = 5;
    const time_rx = 7;
    const time_tx = 8;
};

const NLM_F_REQUEST = 1;
const NLM_F_ACK = 4;
const NLM_F_DUMP = 0x300;
const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;
const GENL_ID_CTRL = 16;
const CTRL_CMD_GETFAMILY = 3;
const CTRL_ATTR_FAMILY_ID = 1;
const CTRL_ATTR_FAMILY_NAME = 2;
const ERFKILL = 132;

pub const Error = error{ NoNl80211, Permission, Busy, RfKill, NoDevice, Netlink, Truncated };

fn fail(errno: i32) Error {
    return switch (errno) {
        1, 13 => error.Permission, // EPERM, EACCES
        16 => error.Busy,
        19 => error.NoDevice,
        ERFKILL => error.RfKill,
        else => error.Netlink,
    };
}

// --- Attributes (pure) -----------------------------------------------------------

pub const Builder = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    fn header(self: *Builder, family: u16, flags: u16, seq: u32, command: u8) void {
        self.len = 20;
        std.mem.writeInt(u16, self.buf[4..6], family, .little);
        std.mem.writeInt(u16, self.buf[6..8], flags, .little);
        std.mem.writeInt(u32, self.buf[8..12], seq, .little);
        std.mem.writeInt(u32, self.buf[12..16], 0, .little);
        self.buf[16] = command;
        self.buf[17] = 1; // version
        self.buf[18] = 0;
        self.buf[19] = 0;
    }
    pub fn put(self: *Builder, kind: u16, payload: []const u8) void {
        const total = 4 + payload.len;
        std.mem.writeInt(u16, self.buf[self.len..][0..2], @intCast(total), .little);
        std.mem.writeInt(u16, self.buf[self.len + 2 ..][0..2], kind, .little);
        @memcpy(self.buf[self.len + 4 ..][0..payload.len], payload);
        const padded = std.mem.alignForward(usize, total, 4);
        @memset(self.buf[self.len + total .. self.len + padded], 0);
        self.len += padded;
    }
    pub fn putU32(self: *Builder, kind: u16, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        self.put(kind, &b);
    }
    fn finish(self: *Builder) []const u8 {
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.len), .little);
        return self.buf[0..self.len];
    }
};

pub const Attr = struct {
    kind: u16,
    data: []const u8,
    pub fn u32_(self: Attr) ?u32 {
        return if (self.data.len >= 4) std.mem.readInt(u32, self.data[0..4], .little) else null;
    }
    pub fn u64_(self: Attr) ?u64 {
        return if (self.data.len >= 8) std.mem.readInt(u64, self.data[0..8], .little) else if (self.data.len >= 4) std.mem.readInt(u32, self.data[0..4], .little) else null;
    }
    pub fn u16_(self: Attr) ?u16 {
        return if (self.data.len >= 2) std.mem.readInt(u16, self.data[0..2], .little) else null;
    }
    pub fn s8_(self: Attr) ?i8 {
        return if (self.data.len >= 1) @bitCast(self.data[0]) else null;
    }
};
pub const Attrs = struct {
    rest: []const u8,
    pub fn next(self: *Attrs) ?Attr {
        if (self.rest.len < 4) return null;
        const len = std.mem.readInt(u16, self.rest[0..2], .little);
        const kind = std.mem.readInt(u16, self.rest[2..4], .little) & 0x3fff;
        if (len < 4 or len > self.rest.len) return null;
        const a = Attr{ .kind = kind, .data = self.rest[4..len] };
        self.rest = self.rest[@min(self.rest.len, std.mem.alignForward(usize, len, 4))..];
        return a;
    }
    pub fn find(data: []const u8, kind: u16) ?Attr {
        var it = Attrs{ .rest = data };
        while (it.next()) |a| if (a.kind == kind) return a;
        return null;
    }
};

pub const Station = struct {
    signal_dbm: ?i8 = null,
    signal_avg_dbm: ?i8 = null,
    /// Last TX rate, 100 kbit/s units.
    tx_bitrate: ?u32 = null,
    tx_packets: ?u32 = null,
    tx_retries: ?u32 = null,
    tx_failed: ?u32 = null,
    beacon_loss: ?u32 = null,
};
pub fn parseStation(genl_payload: []const u8) ?Station {
    const info = Attrs.find(genl_payload, attr.sta_info) orelse return null;
    var s = Station{};
    var it = Attrs{ .rest = info.data };
    while (it.next()) |a| switch (a.kind) {
        sta.signal => s.signal_dbm = a.s8_(),
        sta.signal_avg => s.signal_avg_dbm = a.s8_(),
        sta.tx_packets => s.tx_packets = a.u32_(),
        sta.tx_retries => s.tx_retries = a.u32_(),
        sta.tx_failed => s.tx_failed = a.u32_(),
        sta.beacon_loss => s.beacon_loss = a.u32_(),
        sta.tx_bitrate => {
            if (Attrs.find(a.data, rate_bitrate32)) |r| s.tx_bitrate = r.u32_() else if (Attrs.find(a.data, rate_bitrate)) |r| s.tx_bitrate = if (r.u16_()) |x| x else null;
        },
        else => {},
    };
    return s;
}

pub const Survey = struct {
    freq_mhz: u32 = 0,
    in_use: bool = false,
    noise_dbm: ?i8 = null,
    /// Cumulative milliseconds.
    time_ms: ?u64 = null,
    busy_ms: ?u64 = null,
    rx_ms: ?u64 = null,
    tx_ms: ?u64 = null,
};
pub fn parseSurvey(genl_payload: []const u8) ?Survey {
    const info = Attrs.find(genl_payload, attr.survey_info) orelse return null;
    var s = Survey{};
    var it = Attrs{ .rest = info.data };
    while (it.next()) |a| switch (a.kind) {
        survey.frequency => s.freq_mhz = a.u32_() orelse 0,
        survey.in_use => s.in_use = true,
        survey.noise => s.noise_dbm = a.s8_(),
        survey.time => s.time_ms = a.u64_(),
        survey.time_busy => s.busy_ms = a.u64_(),
        survey.time_rx => s.rx_ms = a.u64_(),
        survey.time_tx => s.tx_ms = a.u64_(),
        else => {},
    };
    return s;
}

pub const Interface = struct { iftype: u32 = 0, wiphy: ?u32 = null, freq_mhz: ?u32 = null };

// --- The socket -------------------------------------------------------------------

pub const Socket = struct {
    fd: i32,
    family: u16,
    seq: u32 = 1,
    buf: [32768]u8 align(4) = undefined,

    pub fn open() Error!Socket {
        const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, linux.NETLINK.GENERIC);
        if (linux.errno(rc) != .SUCCESS) return error.NoNl80211;
        var self = Socket{ .fd = @intCast(rc), .family = GENL_ID_CTRL };
        errdefer self.close();
        // Replies to a dump can be large; a short receive timeout keeps a stuck kernel from hanging us.
        const tv = linux.timeval{ .sec = 1, .usec = 0 };
        _ = linux.setsockopt(self.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        var b = Builder{};
        b.header(GENL_ID_CTRL, NLM_F_REQUEST, self.next(), CTRL_CMD_GETFAMILY);
        b.put(CTRL_ATTR_FAMILY_NAME, "nl80211\x00");
        try self.send(b.finish());
        var family: ?u16 = null;
        try self.receive(struct {
            fn f(out: *?u16, payload: []const u8) void {
                if (Attrs.find(payload, CTRL_ATTR_FAMILY_ID)) |a| out.* = a.u16_();
            }
        }.f, &family);
        self.family = family orelse return error.NoNl80211;
        return self;
    }
    pub fn close(self: *Socket) void {
        _ = linux.close(self.fd);
    }
    fn next(self: *Socket) u32 {
        self.seq +%= 1;
        return self.seq;
    }
    fn send(self: *Socket, msg: []const u8) Error!void {
        var to = linux.sockaddr.nl{ .pid = 0, .groups = 0 };
        const rc = linux.sendto(self.fd, msg.ptr, msg.len, 0, @ptrCast(&to), @sizeOf(linux.sockaddr.nl));
        if (linux.errno(rc) != .SUCCESS) return error.Netlink;
    }
    /// Reads replies to the last request until DONE, an ACK or a single
    /// non-multipart reply; calls `each` with every genl payload (after the
    /// 4-byte genl header).
    fn receive(self: *Socket, comptime each: anytype, context: anytype) Error!void {
        while (true) {
            const rc = linux.recvfrom(self.fd, &self.buf, self.buf.len, 0, null, null);
            if (linux.errno(rc) != .SUCCESS) return error.Netlink;
            var rest: []const u8 = self.buf[0..rc];
            var multi = false;
            while (rest.len >= 16) {
                const len = std.mem.readInt(u32, rest[0..4], .little);
                const kind = std.mem.readInt(u16, rest[4..6], .little);
                const flags = std.mem.readInt(u16, rest[6..8], .little);
                const seq = std.mem.readInt(u32, rest[8..12], .little);
                if (len < 16 or len > rest.len) return error.Truncated;
                const body = rest[16..len];
                rest = rest[@min(rest.len, std.mem.alignForward(usize, len, 4))..];
                if (seq != self.seq) continue;
                if (kind == NLMSG_DONE) return;
                if (kind == NLMSG_ERROR) {
                    if (body.len < 4) return error.Truncated;
                    const errno = -std.mem.readInt(i32, body[0..4], .little);
                    if (errno == 0) return;
                    return fail(errno);
                }
                if (flags & 2 != 0) multi = true; // NLM_F_MULTI
                if (body.len >= 4) each(context, body[4..]);
            }
            if (!multi) return;
        }
    }

    pub fn interface(self: *Socket, ifindex: u32) Error!Interface {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST, self.next(), cmd.get_interface);
        b.putU32(attr.ifindex, ifindex);
        try self.send(b.finish());
        var out = Interface{};
        try self.receive(struct {
            fn f(o: *Interface, p: []const u8) void {
                var it = Attrs{ .rest = p };
                while (it.next()) |a| switch (a.kind) {
                    attr.iftype => o.iftype = a.u32_() orelse 0,
                    attr.wiphy => o.wiphy = a.u32_(),
                    attr.wiphy_freq => o.freq_mhz = a.u32_(),
                    else => {},
                };
            }
        }.f, &out);
        return out;
    }
    pub fn station(self: *Socket, ifindex: u32) Error!?Station {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST | NLM_F_DUMP, self.next(), cmd.get_station);
        b.putU32(attr.ifindex, ifindex);
        try self.send(b.finish());
        var out: ?Station = null;
        try self.receive(struct {
            fn f(o: *?Station, p: []const u8) void {
                if (o.* == null) o.* = parseStation(p);
            }
        }.f, &out);
        return out;
    }
    /// The survey entry of the channel in use, if the driver reports one.
    pub fn surveyInUse(self: *Socket, ifindex: u32) Error!?Survey {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST | NLM_F_DUMP, self.next(), cmd.get_survey);
        b.putU32(attr.ifindex, ifindex);
        try self.send(b.finish());
        var out: ?Survey = null;
        try self.receive(struct {
            fn f(o: *?Survey, p: []const u8) void {
                const s = parseSurvey(p) orelse return;
                if (s.in_use) o.* = s;
            }
        }.f, &out);
        return out;
    }
    pub fn supportsMonitor(self: *Socket, wiphy: u32) Error!bool {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST | NLM_F_DUMP, self.next(), cmd.get_wiphy);
        b.putU32(attr.wiphy, wiphy);
        b.put(attr.split_wiphy_dump, "");
        try self.send(b.finish());
        const Found = struct { wiphy: u32, yes: bool = false };
        var found = Found{ .wiphy = wiphy };
        try self.receive(struct {
            fn f(o: *Found, p: []const u8) void {
                const w = Attrs.find(p, attr.wiphy) orelse return;
                if (w.u32_() != o.wiphy) return;
                const types = Attrs.find(p, attr.supported_iftypes) orelse return;
                if (Attrs.find(types.data, iftype.monitor) != null) o.yes = true;
            }
        }.f, &found);
        return found.yes;
    }
    /// Receive-only reconfiguration (root): the interface type.
    pub fn setType(self: *Socket, ifindex: u32, kind: u32) Error!void {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST | NLM_F_ACK, self.next(), cmd.set_interface);
        b.putU32(attr.ifindex, ifindex);
        b.putU32(attr.iftype, kind);
        try self.send(b.finish());
        try self.receive(struct {
            fn f(_: *u8, _: []const u8) void {}
        }.f, @as(*u8, @constCast(&self.buf[0])));
    }
    /// Receive-only reconfiguration (root): a monitor interface's channel, 20 MHz no-HT.
    pub fn setFreq(self: *Socket, ifindex: u32, mhz: u32) Error!void {
        return self.setFreqType(ifindex, mhz, 0);
    }
    /// The same with a channel type: 0 no-HT, 1 HT20, 2 HT40-, 3 HT40+.
    pub fn setFreqType(self: *Socket, ifindex: u32, mhz: u32, channel_type: u32) Error!void {
        var b = Builder{};
        b.header(self.family, NLM_F_REQUEST | NLM_F_ACK, self.next(), cmd.set_wiphy);
        b.putU32(attr.ifindex, ifindex);
        b.putU32(attr.wiphy_freq, mhz);
        b.putU32(attr.wiphy_channel_type, channel_type);
        try self.send(b.finish());
        try self.receive(struct {
            fn f(_: *u8, _: []const u8) void {}
        }.f, @as(*u8, @constCast(&self.buf[0])));
    }
};

// --- Link flags -----------------------------------------------------------------

fn ifreq(name: []const u8) !linux.ifreq {
    var r = std.mem.zeroes(linux.ifreq);
    if (name.len == 0 or name.len >= r.ifrn.name.len) return error.NoDevice;
    @memcpy(r.ifrn.name[0..name.len], name);
    return r;
}
pub fn isUp(name: []const u8) !bool {
    var r = try ifreq(name);
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Netlink;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.ioctl(@intCast(fd), linux.SIOCGIFFLAGS, @intFromPtr(&r))) != .SUCCESS) return error.NoDevice;
    return r.ifru.flags.UP;
}
/// ip link set NAME up|down (root).
pub fn setUp(name: []const u8, up: bool) Error!void {
    var r = ifreq(name) catch return error.NoDevice;
    const fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(fd) != .SUCCESS) return error.Netlink;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.ioctl(@intCast(fd), linux.SIOCGIFFLAGS, @intFromPtr(&r))) != .SUCCESS) return error.NoDevice;
    if (r.ifru.flags.UP == up) return;
    r.ifru.flags.UP = up;
    const e = linux.errno(linux.ioctl(@intCast(fd), linux.SIOCSIFFLAGS, @intFromPtr(&r)));
    if (e != .SUCCESS) return fail(@intFromEnum(e));
}

test "attribute builder and parser agree; station and survey decode" {
    var b = Builder{};
    b.header(28, NLM_F_REQUEST, 7, cmd.get_station);
    b.putU32(attr.ifindex, 5);
    b.put(attr.ifname, "wlan9\x00");
    const msg = b.finish();
    try std.testing.expectEqual(@as(usize, 20 + 8 + 12), msg.len);
    var it = Attrs{ .rest = msg[20..] };
    try std.testing.expectEqual(@as(?u32, 5), it.next().?.u32_());
    try std.testing.expectEqualStrings("wlan9\x00", it.next().?.data);
    try std.testing.expectEqual(@as(?Attr, null), it.next());

    // A STA_INFO nest: signal -61, tx bitrate 72.2 Mbit/s, retries 9.
    var rate = Builder{};
    rate.len = 0;
    rate.putU32(rate_bitrate32, 722);
    var info = Builder{};
    info.len = 0;
    info.put(sta.signal, &.{@bitCast(@as(i8, -61))});
    info.put(sta.tx_bitrate, rate.buf[0..rate.len]);
    info.putU32(sta.tx_retries, 9);
    var top = Builder{};
    top.len = 0;
    top.put(attr.sta_info, info.buf[0..info.len]);
    const s = parseStation(top.buf[0..top.len]).?;
    try std.testing.expectEqual(@as(?i8, -61), s.signal_dbm);
    try std.testing.expectEqual(@as(?u32, 722), s.tx_bitrate);
    try std.testing.expectEqual(@as(?u32, 9), s.tx_retries);
    try std.testing.expectEqual(@as(?u32, null), s.tx_failed);

    var si = Builder{};
    si.len = 0;
    si.putU32(survey.frequency, 2437);
    si.put(survey.in_use, "");
    si.put(survey.noise, &.{@bitCast(@as(i8, -92))});
    var t: [8]u8 = undefined;
    std.mem.writeInt(u64, &t, 5000, .little);
    si.put(survey.time, &t);
    std.mem.writeInt(u64, &t, 1250, .little);
    si.put(survey.time_busy, &t);
    var st = Builder{};
    st.len = 0;
    st.put(attr.survey_info, si.buf[0..si.len]);
    const sv = parseSurvey(st.buf[0..st.len]).?;
    try std.testing.expect(sv.in_use);
    try std.testing.expectEqual(@as(u32, 2437), sv.freq_mhz);
    try std.testing.expectEqual(@as(?i8, -92), sv.noise_dbm);
    try std.testing.expectEqual(@as(?u64, 1250), sv.busy_ms);
    // Truncated and hostile attribute streams stop cleanly.
    var bad = Attrs{ .rest = &.{ 0xff, 0x00, 1, 0, 9 } };
    try std.testing.expectEqual(@as(?Attr, null), bad.next());
}
