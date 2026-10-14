//! Packet summaries: Ethernet, 802.1Q/802.1ad VLAN, Linux cooked (SLL, SLL2),
//! BSD loopback, raw IP; IPv4, IPv6 (bounded extension headers); TCP, UDP,
//! ICMP and ICMPv6. Pure functions over the captured bytes: no allocation,
//! no reassembly, no checksum verification. A frame that cannot be followed
//! to its transport header keeps everything decoded so far and says why.
const std = @import("std");

pub const decoder = "xodb-net-summary";
pub const decoder_version: u32 = 1;

pub const Link = enum(u8) { unknown, ethernet, sll, sll2, null_loopback, raw };
pub const Layer = enum(u8) { none, link, network, transport };
pub const Family = enum(u8) { none, ipv4, ipv6 };
pub const Reason = enum(u8) {
    none,
    unknown_link_type,
    truncated_link,
    unsupported_ethertype,
    vlan_depth,
    truncated_network,
    bad_ip_version,
    bad_ip_header,
    non_first_fragment,
    extension_header_limit,
    truncated_transport,
    bad_transport_header,
    unsupported_protocol,
};
pub const max_vlans = 2;
pub const max_extension_headers = 8;

pub const Summary = struct {
    link: Link = .unknown,
    layer: Layer = .none,
    reason: Reason = .none,
    ether_type: u16 = 0,
    vlan_count: u8 = 0,
    vlans: [max_vlans]u16 = .{ 0, 0 },
    family: Family = .none,
    src: [16]u8 = @splat(0),
    dst: [16]u8 = @splat(0),
    /// IP protocol after extension headers (6 TCP, 17 UDP, 1 ICMP, 58 ICMPv6).
    protocol: u8 = 0,
    hop_limit: u8 = 0,
    /// IP total length as declared (IPv4 total length, IPv6 payload + 40).
    ip_length: u32 = 0,
    extension_headers: u8 = 0,
    fragment: bool = false,
    src_port: u16 = 0,
    dst_port: u16 = 0,
    tcp_flags: u8 = 0,
    seq: u32 = 0,
    ack: u32 = 0,
    window: u16 = 0,
    icmp_type: u8 = 0,
    icmp_code: u8 = 0,
    /// Transport payload bytes declared by the IP/UDP lengths, and captured.
    payload_length: u32 = 0,
    payload_captured: u32 = 0,

    pub fn undecoded(self: *const Summary) bool {
        return self.reason != .none;
    }
    pub fn hasPorts(self: *const Summary) bool {
        return self.layer == .transport and (self.protocol == 6 or self.protocol == 17);
    }
    pub fn addressLength(self: *const Summary) usize {
        return switch (self.family) {
            .ipv4 => 4,
            .ipv6 => 16,
            .none => 0,
        };
    }
    pub fn flow(self: *const Summary) ?Flow {
        if (self.layer != .transport and !(self.layer == .network and self.reason == .non_first_fragment)) return null;
        if (self.family == .none) return null;
        return .{ .family = self.family, .protocol = self.protocol, .src = self.src, .dst = self.dst, .src_port = self.src_port, .dst_port = self.dst_port };
    }
};

/// A directed 5-tuple. `canonical` orders the two ends so both directions share a key.
pub const Flow = struct {
    family: Family,
    protocol: u8,
    src: [16]u8,
    dst: [16]u8,
    src_port: u16,
    dst_port: u16,

    pub fn reversed(self: Flow) Flow {
        return .{ .family = self.family, .protocol = self.protocol, .src = self.dst, .dst = self.src, .src_port = self.dst_port, .dst_port = self.src_port };
    }
    pub fn canonical(self: Flow) Flow {
        const order = std.mem.order(u8, &self.src, &self.dst);
        if (order == .gt or (order == .eq and self.src_port > self.dst_port)) return self.reversed();
        return self;
    }
    pub fn eql(self: Flow, other: Flow) bool {
        return std.meta.eql(self, other);
    }
};

pub const link_null = 0;
pub const link_ethernet = 1;
pub const link_raw = 101;
pub const link_sll = 113;
pub const link_ipv4 = 228;
pub const link_ipv6 = 229;
pub const link_sll2 = 276;

pub fn decode(link_type: u16, bytes: []const u8) Summary {
    var s = Summary{};
    var rest = bytes;
    var ether: u16 = 0;
    switch (link_type) {
        link_ethernet => {
            s.link = .ethernet;
            if (rest.len < 14) return fail(&s, .truncated_link);
            ether = be16(rest[12..14]);
            rest = rest[14..];
            while (ether == 0x8100 or ether == 0x88a8 or ether == 0x9100) {
                if (s.vlan_count == max_vlans) return failAt(&s, .link, .vlan_depth);
                if (rest.len < 4) return fail(&s, .truncated_link);
                s.vlans[s.vlan_count] = be16(rest[0..2]) & 0x0fff;
                s.vlan_count += 1;
                ether = be16(rest[2..4]);
                rest = rest[4..];
            }
        },
        link_sll => {
            s.link = .sll;
            if (rest.len < 16) return fail(&s, .truncated_link);
            ether = be16(rest[14..16]);
            rest = rest[16..];
        },
        link_sll2 => {
            s.link = .sll2;
            if (rest.len < 20) return fail(&s, .truncated_link);
            ether = be16(rest[0..2]);
            rest = rest[20..];
        },
        link_null => {
            s.link = .null_loopback;
            if (rest.len < 4) return fail(&s, .truncated_link);
            // Host byte order of the writer: accept either (the other order reads as a value >= 2^24).
            const family = @min(std.mem.readInt(u32, rest[0..4], .little), std.mem.readInt(u32, rest[0..4], .big));
            ether = switch (family) {
                2 => 0x0800,
                10, 24, 28, 30 => 0x86dd,
                else => 0,
            };
            rest = rest[4..];
        },
        link_raw, link_ipv4, link_ipv6 => {
            s.link = .raw;
            if (rest.len < 1) return fail(&s, .truncated_link);
            ether = switch (rest[0] >> 4) {
                4 => 0x0800,
                6 => 0x86dd,
                else => {
                    s.layer = .link;
                    return failAt(&s, .link, .bad_ip_version);
                },
            };
        },
        else => return fail(&s, .unknown_link_type),
    }
    s.layer = .link;
    s.ether_type = ether;
    switch (ether) {
        0x0800 => ipv4(&s, rest),
        0x86dd => ipv6(&s, rest),
        else => s.reason = .unsupported_ethertype,
    }
    return s;
}

fn fail(s: *Summary, reason: Reason) Summary {
    s.reason = reason;
    return s.*;
}
fn failAt(s: *Summary, layer: Layer, reason: Reason) Summary {
    s.layer = layer;
    s.reason = reason;
    return s.*;
}
fn be16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

fn ipv4(s: *Summary, b: []const u8) void {
    if (b.len < 20) {
        s.reason = .truncated_network;
        return;
    }
    if (b[0] >> 4 != 4) {
        s.reason = .bad_ip_version;
        return;
    }
    const ihl = @as(usize, b[0] & 0x0f) * 4;
    const total = be16(b[2..4]);
    if (ihl < 20 or total < ihl) {
        s.reason = .bad_ip_header;
        return;
    }
    if (b.len < ihl) {
        s.reason = .truncated_network;
        return;
    }
    s.layer = .network;
    s.family = .ipv4;
    s.ip_length = total;
    s.hop_limit = b[8];
    s.protocol = b[9];
    @memcpy(s.src[0..4], b[12..16]);
    @memcpy(s.dst[0..4], b[16..20]);
    const frag = be16(b[6..8]);
    s.fragment = frag & 0x3fff != 0;
    if (frag & 0x1fff != 0) {
        s.reason = .non_first_fragment;
        return;
    }
    // Ethernet padding past the IP total length is not payload.
    const end = @min(b.len, total);
    transport(s, b[ihl..end], @intCast(total - ihl));
}

fn ipv6(s: *Summary, b: []const u8) void {
    if (b.len < 40) {
        s.reason = .truncated_network;
        return;
    }
    if (b[0] >> 4 != 6) {
        s.reason = .bad_ip_version;
        return;
    }
    s.layer = .network;
    s.family = .ipv6;
    const payload = be16(b[4..6]);
    s.ip_length = @as(u32, payload) + 40;
    s.hop_limit = b[7];
    @memcpy(&s.src, b[8..24]);
    @memcpy(&s.dst, b[24..40]);
    var next = b[6];
    var rest = b[40..@min(b.len, 40 + @as(usize, payload))];
    var declared: u32 = payload;
    while (true) switch (next) {
        0, 43, 44, 60, 51, 135 => {
            if (s.extension_headers == max_extension_headers) {
                s.protocol = next;
                s.reason = .extension_header_limit;
                return;
            }
            if (rest.len < 8) {
                s.protocol = next;
                s.reason = .truncated_network;
                return;
            }
            s.extension_headers += 1;
            const length: usize = switch (next) {
                44 => 8,
                51 => (@as(usize, rest[1]) + 2) * 4,
                else => (@as(usize, rest[1]) + 1) * 8,
            };
            if (next == 44) {
                s.fragment = true;
                if (be16(rest[2..4]) & 0xfff8 != 0) {
                    s.protocol = rest[0];
                    s.reason = .non_first_fragment;
                    return;
                }
            }
            if (rest.len < length or declared < length) {
                s.protocol = next;
                s.reason = .truncated_network;
                return;
            }
            next = rest[0];
            rest = rest[length..];
            declared -= @intCast(length);
        },
        else => break,
    };
    s.protocol = next;
    transport(s, rest, declared);
}

fn transport(s: *Summary, b: []const u8, declared: u32) void {
    switch (s.protocol) {
        6 => {
            if (b.len < 20) return failTransport(s, b, .truncated_transport);
            const offset = @as(usize, b[12] >> 4) * 4;
            if (offset < 20 or declared < offset) return failTransport(s, b, .bad_transport_header);
            s.src_port = be16(b[0..2]);
            s.dst_port = be16(b[2..4]);
            s.seq = be32(b[4..8]);
            s.ack = be32(b[8..12]);
            s.tcp_flags = b[13];
            s.window = be16(b[14..16]);
            s.layer = .transport;
            s.payload_length = declared - @as(u32, @intCast(offset));
            s.payload_captured = @intCast(b.len -| offset);
            if (b.len < offset) s.reason = .truncated_transport;
        },
        17 => {
            if (b.len < 8) return failTransport(s, b, .truncated_transport);
            const length = be16(b[4..6]);
            if (length < 8) return failTransport(s, b, .bad_transport_header);
            s.src_port = be16(b[0..2]);
            s.dst_port = be16(b[2..4]);
            s.layer = .transport;
            s.payload_length = @min(length, declared) -| 8;
            s.payload_captured = @intCast(@min(b.len, length) - 8);
        },
        1, 58 => {
            if (b.len < 4) return failTransport(s, b, .truncated_transport);
            s.icmp_type = b[0];
            s.icmp_code = b[1];
            s.layer = .transport;
            s.payload_length = declared -| 4;
            s.payload_captured = @intCast(b.len - 4);
        },
        else => s.reason = .unsupported_protocol,
    }
}
fn failTransport(s: *Summary, b: []const u8, reason: Reason) void {
    // Ports of a truncated header are still useful when they were captured.
    if ((s.protocol == 6 or s.protocol == 17) and b.len >= 4) {
        s.src_port = be16(b[0..2]);
        s.dst_port = be16(b[2..4]);
    }
    s.reason = reason;
}

pub fn protocolName(p: u8) []const u8 {
    return switch (p) {
        1 => "icmp",
        6 => "tcp",
        17 => "udp",
        58 => "icmpv6",
        50 => "esp",
        else => "other",
    };
}

/// "127.0.0.1" or an RFC 5952 IPv6 form; `buffer` holds at least 46 bytes.
pub fn formatAddress(buffer: []u8, family: Family, addr: [16]u8) []const u8 {
    var w = std.Io.Writer.fixed(buffer);
    switch (family) {
        .none => return "",
        .ipv4 => w.print("{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] }) catch return "",
        .ipv6 => {
            var words: [8]u16 = undefined;
            for (&words, 0..) |*word, i| word.* = std.mem.readInt(u16, addr[i * 2 ..][0..2], .big);
            // Longest run of two or more zero words becomes "::".
            var best: usize = 8;
            var best_len: usize = 0;
            var i: usize = 0;
            while (i < 8) {
                if (words[i] != 0) {
                    i += 1;
                    continue;
                }
                var j = i;
                while (j < 8 and words[j] == 0) j += 1;
                if (j - i > best_len and j - i >= 2) {
                    best = i;
                    best_len = j - i;
                }
                i = j;
            }
            i = 0;
            while (i < 8) {
                if (i == best) {
                    w.writeAll("::") catch return "";
                    i += best_len;
                    continue;
                }
                if (i != 0 and i != best + best_len) w.writeByte(':') catch return "";
                w.print("{x}", .{words[i]}) catch return "";
                i += 1;
            }
        },
    }
    return w.buffered();
}

// ---------------------------------------------------------------- tests

/// Test frame builder: Ethernet + IPv4/IPv6 + TCP/UDP with the given payload.
pub fn testFrame(out: []u8, family: Family, protocol: u8, src: [16]u8, dst: [16]u8, sport: u16, dport: u16, flags: u8, payload: []const u8) []u8 {
    var at: usize = 0;
    @memset(out[0..12], 0);
    std.mem.writeInt(u16, out[12..14], if (family == .ipv4) 0x0800 else 0x86dd, .big);
    at = 14;
    const l4: usize = if (protocol == 6) 20 else 8;
    const l4_len = l4 + payload.len;
    if (family == .ipv4) {
        @memset(out[at..][0..20], 0);
        out[at] = 0x45;
        std.mem.writeInt(u16, out[at + 2 ..][0..2], @intCast(20 + l4_len), .big);
        out[at + 8] = 64;
        out[at + 9] = protocol;
        @memcpy(out[at + 12 ..][0..4], src[0..4]);
        @memcpy(out[at + 16 ..][0..4], dst[0..4]);
        at += 20;
    } else {
        @memset(out[at..][0..40], 0);
        out[at] = 0x60;
        std.mem.writeInt(u16, out[at + 4 ..][0..2], @intCast(l4_len), .big);
        out[at + 6] = protocol;
        out[at + 7] = 64;
        @memcpy(out[at + 8 ..][0..16], &src);
        @memcpy(out[at + 24 ..][0..16], &dst);
        at += 40;
    }
    @memset(out[at..][0..l4], 0);
    std.mem.writeInt(u16, out[at..][0..2], sport, .big);
    std.mem.writeInt(u16, out[at + 2 ..][0..2], dport, .big);
    if (protocol == 6) {
        out[at + 12] = 5 << 4;
        out[at + 13] = flags;
    } else std.mem.writeInt(u16, out[at + 4 ..][0..2], @intCast(l4_len), .big);
    at += l4;
    @memcpy(out[at..][0..payload.len], payload);
    return out[0 .. at + payload.len];
}

pub fn v4(a: u8, b: u8, c: u8, d: u8) [16]u8 {
    var r: [16]u8 = @splat(0);
    r[0..4].* = .{ a, b, c, d };
    return r;
}

test "ethernet ipv4 tcp and udp" {
    var buf: [256]u8 = undefined;
    const tcp = testFrame(&buf, .ipv4, 6, v4(127, 0, 0, 1), v4(127, 0, 0, 1), 40000, 5000, 0x18, "hello");
    const s = decode(link_ethernet, tcp);
    try std.testing.expectEqual(Reason.none, s.reason);
    try std.testing.expectEqual(Layer.transport, s.layer);
    try std.testing.expectEqual(@as(u16, 40000), s.src_port);
    try std.testing.expectEqual(@as(u8, 0x18), s.tcp_flags);
    try std.testing.expectEqual(@as(u32, 5), s.payload_length);
    const flow = s.flow().?;
    try std.testing.expect(flow.canonical().eql(flow.reversed().canonical()));
    const udp = testFrame(&buf, .ipv4, 17, v4(192, 0, 2, 1), v4(192, 0, 2, 2), 53, 9999, 0, "abc");
    const u = decode(link_ethernet, udp);
    try std.testing.expectEqual(@as(u8, 17), u.protocol);
    try std.testing.expectEqual(@as(u32, 3), u.payload_length);
    var text: [64]u8 = undefined;
    try std.testing.expectEqualStrings("192.0.2.2", formatAddress(&text, u.family, u.dst));
}

test "ipv6 with extension headers and limits" {
    var buf: [512]u8 = undefined;
    var src: [16]u8 = @splat(0);
    src[0] = 0x20;
    src[1] = 0x01;
    src[2] = 0x0d;
    src[3] = 0xb8;
    src[15] = 1;
    var dst: [16]u8 = @splat(0);
    dst[15] = 1;
    const plain = testFrame(&buf, .ipv6, 17, src, dst, 1000, 2000, 0, "zz");
    const s = decode(link_ethernet, plain);
    try std.testing.expectEqual(Reason.none, s.reason);
    var text: [64]u8 = undefined;
    try std.testing.expectEqualStrings("2001:db8::1", formatAddress(&text, s.family, s.src));
    try std.testing.expectEqualStrings("::1", formatAddress(&text, s.family, s.dst));
    // Insert hop-by-hop + destination options before UDP.
    var with: [512]u8 = undefined;
    const ip = 14;
    @memcpy(with[0 .. ip + 40], plain[0 .. ip + 40]);
    with[ip + 6] = 0; // hop-by-hop
    @memset(with[ip + 40 ..][0..16], 0);
    with[ip + 40] = 60; // next: destination options
    with[ip + 48] = 17; // next: UDP
    @memcpy(with[ip + 56 ..][0 .. plain.len - ip - 40], plain[ip + 40 ..]);
    const total = plain.len + 16;
    std.mem.writeInt(u16, with[ip + 4 ..][0..2], @intCast(total - ip - 40), .big);
    const e = decode(link_ethernet, with[0..total]);
    try std.testing.expectEqual(Reason.none, e.reason);
    try std.testing.expectEqual(@as(u8, 2), e.extension_headers);
    try std.testing.expectEqual(@as(u16, 2000), e.dst_port);
    // A chain longer than the bound is typed, not followed.
    var chain: [512]u8 = undefined;
    @memcpy(chain[0 .. ip + 40], plain[0 .. ip + 40]);
    chain[ip + 6] = 60;
    for (0..10) |i| {
        @memset(chain[ip + 40 + i * 8 ..][0..8], 0);
        chain[ip + 40 + i * 8] = 60;
    }
    std.mem.writeInt(u16, chain[ip + 4 ..][0..2], 80, .big);
    const l = decode(link_ethernet, chain[0 .. ip + 40 + 80]);
    try std.testing.expectEqual(Reason.extension_header_limit, l.reason);
}

test "link types, vlan, cooked and malformed frames" {
    var buf: [256]u8 = undefined;
    const frame = testFrame(&buf, .ipv4, 6, v4(127, 0, 0, 1), v4(127, 0, 0, 2), 1, 2, 2, "");
    // VLAN tag.
    var tagged: [260]u8 = undefined;
    @memcpy(tagged[0..12], frame[0..12]);
    tagged[12..16].* = .{ 0x81, 0x00, 0x00, 0x2a };
    @memcpy(tagged[16 .. frame.len + 4], frame[12..]);
    const t = decode(link_ethernet, tagged[0 .. frame.len + 4]);
    try std.testing.expectEqual(@as(u16, 42), t.vlans[0]);
    try std.testing.expectEqual(Layer.transport, t.layer);
    // Raw IP, SLL, SLL2.
    try std.testing.expectEqual(Layer.transport, decode(link_raw, frame[14..]).layer);
    var sll: [300]u8 = undefined;
    @memset(sll[0..16], 0);
    sll[14..16].* = .{ 0x08, 0x00 };
    @memcpy(sll[16 .. 16 + frame.len - 14], frame[14..]);
    try std.testing.expectEqual(Link.sll, decode(link_sll, sll[0 .. frame.len + 2]).link);
    try std.testing.expectEqual(Layer.transport, decode(link_sll, sll[0 .. frame.len + 2]).layer);
    var sll2: [300]u8 = undefined;
    @memset(sll2[0..20], 0);
    sll2[0..2].* = .{ 0x08, 0x00 };
    @memcpy(sll2[20 .. 20 + frame.len - 14], frame[14..]);
    try std.testing.expectEqual(Layer.transport, decode(link_sll2, sll2[0 .. frame.len + 6]).layer);
    // Malformed and unknown.
    try std.testing.expectEqual(Reason.unknown_link_type, decode(147, frame).reason);
    try std.testing.expectEqual(Reason.truncated_link, decode(link_ethernet, frame[0..10]).reason);
    try std.testing.expectEqual(Reason.truncated_network, decode(link_ethernet, frame[0..20]).reason);
    try std.testing.expectEqual(Reason.truncated_transport, decode(link_ethernet, frame[0 .. 14 + 20 + 10]).reason);
    var arp = frame[0..42].*;
    arp[12..14].* = .{ 0x08, 0x06 };
    try std.testing.expectEqual(Reason.unsupported_ethertype, decode(link_ethernet, &arp).reason);
    var bad = frame[0..54].*;
    bad[14] = 0x41; // IHL 4 bytes
    try std.testing.expectEqual(Reason.bad_ip_header, decode(link_ethernet, &bad).reason);
    // Every truncation of a valid frame is a typed summary.
    for (0..frame.len) |n| _ = decode(link_ethernet, frame[0..n]);
    // BSD loopback: AF_INET in either byte order of the writer.
    var null_frame: [64]u8 = undefined;
    @memcpy(null_frame[4..][0 .. frame.len - 14], frame[14..]);
    for ([_][4]u8{ .{ 2, 0, 0, 0 }, .{ 0, 0, 0, 2 } }) |family| {
        null_frame[0..4].* = family;
        try std.testing.expectEqual(Layer.transport, decode(link_null, null_frame[0 .. frame.len - 10]).layer);
    }
}
