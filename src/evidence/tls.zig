//! TLS records derived from an immutable packet stream and a user-supplied
//! NSS SSLKEYLOGFILE. The key log is parsed, used, and wiped during open;
//! only authenticated plaintext records and provenance survive.
const std = @import("std");
const network = @import("stream.zig");
const decode = @import("decode.zig");

pub const decoder = "xodb-tls-keylog";
pub const decoder_version: u32 = 1;
pub const max_keylog_entries = 16_384;
pub const max_reassembled_bytes = 64 * 1024 * 1024;
pub const max_plaintext_bytes = 64 * 1024 * 1024;
pub const max_record_bytes = 18_432;

pub const Version = enum { tls12, tls13 };
pub const Direction = enum { client_to_server, server_to_client };
pub const Epoch = enum { handshake, application };
pub const State = enum { decrypted, authentication_failed };
pub const SessionState = enum { decrypted, missing_key, unsupported_cipher, incomplete_handshake, reassembly_gap };
pub const Cipher = enum {
    aes_128_gcm_sha256,
    aes_256_gcm_sha384,
    chacha20_poly1305_sha256,

    pub fn name(self: Cipher) []const u8 {
        return switch (self) {
            .aes_128_gcm_sha256 => "AES_128_GCM_SHA256",
            .aes_256_gcm_sha384 => "AES_256_GCM_SHA384",
            .chacha20_poly1305_sha256 => "CHACHA20_POLY1305_SHA256",
        };
    }
};

pub const Record = struct {
    index: u32,
    flow_id: u32,
    direction: Direction,
    source_record: u32,
    time_ns: ?u64,
    version: Version,
    cipher: Cipher,
    epoch: Epoch,
    sequence: u64,
    outer_type: u8,
    content_type: ?u8 = null,
    state: State,
    plaintext_length: u32 = 0,
    plaintext: []u8 = &.{},
    plaintext_sha256: ?[32]u8 = null,
};

pub const Session = struct {
    flow_id: u32,
    version: ?Version = null,
    cipher: ?Cipher = null,
    state: SessionState,
    records: u32 = 0,
    authentication_failures: u32 = 0,
};

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32 = 2,
    parent_id: u32 = 1,
    label: []const u8,
    records: []Record,
    sessions: []Session,
    plaintext_bytes: u64 = 0,
    plaintext_dropped: u64 = 0,
    malformed_records: u64 = 0,
    reassembly_gaps: u64 = 0,
    keylog_entries: u32 = 0,

    /// `keylog` is always wiped before this function returns. The caller still
    /// owns and must free its allocation.
    pub fn open(a: std.mem.Allocator, source: *const network.Stream, keylog: []u8) !*Stream {
        defer std.crypto.secureZero(u8, keylog);
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(a),
            .backing = a,
            .label = undefined,
            .records = &.{},
            .sessions = &.{},
        };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try std.fmt.allocPrint(arena, "TLS from {s}", .{source.label});
        var secrets = try KeyLog.parse(a, keylog);
        defer secrets.deinit(a);
        self.keylog_entries = @intCast(secrets.entries.items.len);
        var records: std.ArrayList(Record) = .empty;
        var sessions: std.ArrayList(Session) = .empty;
        errdefer for (records.items) |record| if (record.plaintext.len != 0) std.crypto.secureZero(u8, record.plaintext);
        // Bucket packet records by flow once; scanning every record per flow
        // is quadratic on captures with many flows.
        const starts = try a.alloc(u32, source.flows.len + 1);
        defer a.free(starts);
        @memset(starts, 0);
        for (source.flow_of) |flow_of| if (flow_of) |f| {
            starts[f + 1] += 1;
        };
        for (1..starts.len) |k| starts[k] += starts[k - 1];
        const by_flow = try a.alloc(u32, starts[source.flows.len]);
        defer a.free(by_flow);
        {
            const fill = try a.dupe(u32, starts[0..source.flows.len]);
            defer a.free(fill);
            for (source.flow_of, 0..) |flow_of, record_index| if (flow_of) |f| {
                by_flow[fill[f]] = @intCast(record_index);
                fill[f] += 1;
            };
        }
        for (source.flows, 0..) |flow, flow_id_usize| {
            if (flow.key.protocol != 6) continue;
            const flow_id: u32 = @intCast(flow_id_usize);
            var reassembled = try reassemble(a, source, by_flow[starts[flow_id]..starts[flow_id + 1]], flow.key);
            defer reassembled.deinit(a);
            if (reassembled.a.bytes.items.len == 0 or reassembled.b.bytes.items.len == 0) continue;
            var raw_a = try parseRecords(a, &reassembled.a, &self.malformed_records);
            defer raw_a.deinit(a);
            var raw_b = try parseRecords(a, &reassembled.b, &self.malformed_records);
            defer raw_b.deinit(a);
            if (raw_a.items.len == 0 and raw_b.items.len == 0) continue;
            const hello = scanHellos(a, raw_a.items, raw_b.items) catch {
                try sessions.append(arena, .{ .flow_id = flow_id, .state = if (reassembled.gap) .reassembly_gap else .incomplete_handshake });
                if (reassembled.gap) self.reassembly_gaps += 1;
                continue;
            };
            const cipher = cipherOf(hello.cipher_suite, hello.version) orelse {
                try sessions.append(arena, .{ .flow_id = flow_id, .version = hello.version, .state = .unsupported_cipher });
                continue;
            };
            var summary = Session{ .flow_id = flow_id, .version = hello.version, .cipher = cipher, .state = .decrypted };
            const client_records = if (hello.client_is_a) raw_a.items else raw_b.items;
            const server_records = if (hello.client_is_a) raw_b.items else raw_a.items;
            switch (hello.version) {
                .tls13 => {
                    var ck = Traffic13.fromLog(&secrets, hello.client_random, cipher, true) orelse {
                        summary.state = .missing_key;
                        try sessions.append(arena, summary);
                        continue;
                    };
                    defer ck.wipe();
                    var sk = Traffic13.fromLog(&secrets, hello.client_random, cipher, false) orelse {
                        summary.state = .missing_key;
                        try sessions.append(arena, summary);
                        continue;
                    };
                    defer sk.wipe();
                    try decrypt13(self, arena, &records, flow_id, .client_to_server, client_records, &ck, source, &summary);
                    try decrypt13(self, arena, &records, flow_id, .server_to_client, server_records, &sk, source, &summary);
                },
                .tls12 => {
                    const master = secrets.find(.client_random, hello.client_random) orelse {
                        summary.state = .missing_key;
                        try sessions.append(arena, summary);
                        continue;
                    };
                    if (master.len != 48) {
                        summary.state = .missing_key;
                        try sessions.append(arena, summary);
                        continue;
                    }
                    var keys = derive12(cipher, master, hello.client_random, hello.server_random);
                    defer keys.wipe();
                    try decrypt12(self, arena, &records, flow_id, .client_to_server, client_records, keys.client, source, &summary);
                    try decrypt12(self, arena, &records, flow_id, .server_to_client, server_records, keys.server, source, &summary);
                },
            }
            if (reassembled.gap) {
                self.reassembly_gaps += 1;
                if (summary.records == 0) summary.state = .reassembly_gap;
            }
            try sessions.append(arena, summary);
        }
        self.records = records.items;
        self.sessions = sessions.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        for (self.records) |record| if (record.plaintext.len != 0) std.crypto.secureZero(u8, record.plaintext);
        self.arena.deinit();
        a.destroy(self);
    }
};

const Label = enum { client_random, client_handshake, server_handshake, client_application, server_application };
const Secret = struct {
    label: Label,
    random: [32]u8,
    bytes: [48]u8 = @splat(0),
    length: u8,
};
const KeyLog = struct {
    entries: std.ArrayList(Secret) = .empty,

    fn parse(a: std.mem.Allocator, bytes: []const u8) !KeyLog {
        var out = KeyLog{};
        errdefer out.deinit(a);
        // Reserve once: ArrayList growth would free unwiped copies of secrets.
        try out.entries.ensureTotalCapacityPrecise(a, @min(std.mem.count(u8, bytes, "\n") + 1, max_keylog_entries));
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            var words = std.mem.tokenizeAny(u8, line, " \t");
            const label_text = words.next() orelse continue;
            const label = std.meta.stringToEnum(Label, switchLabel(label_text) orelse continue).?;
            const random_text = words.next() orelse return error.InvalidTlsKeyLog;
            const secret_text = words.next() orelse return error.InvalidTlsKeyLog;
            if (words.next() != null or random_text.len != 64 or secret_text.len == 0 or secret_text.len > 96 or secret_text.len % 2 != 0) return error.InvalidTlsKeyLog;
            if (out.entries.items.len == max_keylog_entries) return error.TlsKeyLogLimit;
            var entry = Secret{ .label = label, .random = undefined, .length = @intCast(secret_text.len / 2) };
            _ = std.fmt.hexToBytes(&entry.random, random_text) catch return error.InvalidTlsKeyLog;
            _ = std.fmt.hexToBytes(entry.bytes[0..entry.length], secret_text) catch return error.InvalidTlsKeyLog;
            // Latest identical label/random wins, matching NSS key-log append use.
            for (out.entries.items) |*prior| if (prior.label == entry.label and std.mem.eql(u8, &prior.random, &entry.random)) {
                std.crypto.secureZero(u8, &prior.bytes);
                prior.* = entry;
                break;
            } else {} else out.entries.appendAssumeCapacity(entry);
            std.crypto.secureZero(u8, &entry.bytes);
        }
        return out;
    }

    fn find(self: *const KeyLog, label: Label, random: [32]u8) ?[]const u8 {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = &self.entries.items[i];
            if (entry.label == label and std.mem.eql(u8, &entry.random, &random)) return entry.bytes[0..entry.length];
        }
        return null;
    }

    fn deinit(self: *KeyLog, a: std.mem.Allocator) void {
        for (self.entries.items) |*entry| std.crypto.secureZero(u8, &entry.bytes);
        self.entries.deinit(a);
    }
};

fn switchLabel(label: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, label, "CLIENT_RANDOM")) return "client_random";
    if (std.mem.eql(u8, label, "CLIENT_HANDSHAKE_TRAFFIC_SECRET")) return "client_handshake";
    if (std.mem.eql(u8, label, "SERVER_HANDSHAKE_TRAFFIC_SECRET")) return "server_handshake";
    if (std.mem.eql(u8, label, "CLIENT_TRAFFIC_SECRET_0")) return "client_application";
    if (std.mem.eql(u8, label, "SERVER_TRAFFIC_SECRET_0")) return "server_application";
    return null;
}

const Segment = struct { seq: u32, record: u32, bytes: []const u8 };
const Span = struct { first: usize, last: usize, record: u32 };
const DirectionBytes = struct {
    bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    segments: std.ArrayList(Segment) = .empty,
    anchor: ?u32 = null,

    fn deinit(self: *DirectionBytes, a: std.mem.Allocator) void {
        self.bytes.deinit(a);
        self.spans.deinit(a);
        self.segments.deinit(a);
    }
    fn source(self: *const DirectionBytes, offset: usize) u32 {
        // Spans are appended in byte order and never overlap.
        const spans = self.spans.items;
        if (spans.len == 0) return 0;
        var low: usize = 0;
        var high: usize = spans.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (spans[mid].last <= offset) low = mid + 1 else high = mid;
        }
        return if (low < spans.len and offset >= spans[low].first) spans[low].record else spans[spans.len - 1].record;
    }
};
const Reassembled = struct {
    a: DirectionBytes = .{},
    b: DirectionBytes = .{},
    gap: bool = false,
    fn deinit(self: *Reassembled, allocator: std.mem.Allocator) void {
        self.a.deinit(allocator);
        self.b.deinit(allocator);
    }
};

fn reassemble(a: std.mem.Allocator, source: *const network.Stream, flow_records: []const u32, key: decode.Flow) !Reassembled {
    var out = Reassembled{};
    errdefer out.deinit(a);
    for (flow_records) |record_index| {
        const summary = source.summaries[record_index];
        if (summary.protocol != 6) continue;
        const a_to_b = std.mem.eql(u8, &summary.src, &key.src) and summary.src_port == key.src_port;
        const direction = if (a_to_b) &out.a else &out.b;
        // SYN (client) and SYN-ACK (server) both fix their direction's ISN.
        if (summary.tcp_flags & 0x02 != 0) direction.anchor = summary.seq +% 1;
        if (summary.payload_captured == 0) continue;
        const bytes = tcpPayload(source.parsed.interfaces[source.parsed.records[record_index].interface].link_type, source.raw(record_index), summary) orelse continue;
        if (bytes.len == 0) continue;
        try direction.segments.append(a, .{ .seq = summary.seq, .record = @intCast(record_index), .bytes = bytes });
    }
    const gap_a = try linearize(a, &out.a);
    const gap_b = try linearize(a, &out.b);
    out.gap = gap_a or gap_b;
    return out;
}

fn linearize(a: std.mem.Allocator, direction: *DirectionBytes) !bool {
    if (direction.segments.items.len == 0) return false;
    const anchor = direction.anchor orelse blk: {
        // No SYN: the earliest segment in 32-bit serial order, so a
        // reordered first capture does not silently drop earlier bytes.
        var low = direction.segments.items[0].seq;
        for (direction.segments.items[1..]) |segment| if (@as(i32, @bitCast(segment.seq -% low)) < 0) {
            low = segment.seq;
        };
        break :blk low;
    };
    const Ctx = struct {
        anchor: u32,
        fn less(ctx: @This(), lhs: Segment, rhs: Segment) bool {
            return lhs.seq -% ctx.anchor < rhs.seq -% ctx.anchor;
        }
    };
    std.mem.sort(Segment, direction.segments.items, Ctx{ .anchor = anchor }, Ctx.less);
    var expected: usize = 0;
    var gap = false;
    for (direction.segments.items) |segment| {
        const relative_u32 = segment.seq -% anchor;
        if (relative_u32 > std.math.maxInt(i32)) continue;
        const relative: usize = relative_u32;
        if (relative > expected) {
            gap = true;
            break;
        }
        const overlap = expected - relative;
        if (overlap >= segment.bytes.len) continue;
        const tail = segment.bytes[overlap..];
        if (direction.bytes.items.len + tail.len > max_reassembled_bytes) {
            gap = true;
            break;
        }
        const first = direction.bytes.items.len;
        try direction.bytes.appendSlice(a, tail);
        expected += tail.len;
        try direction.spans.append(a, .{ .first = first, .last = direction.bytes.items.len, .record = segment.record });
    }
    return gap;
}

fn tcpPayload(link_type: u16, frame: []const u8, summary: decode.Summary) ?[]const u8 {
    var at: usize = switch (link_type) {
        decode.link_ethernet => 14 + @as(usize, summary.vlan_count) * 4,
        decode.link_sll => 16,
        decode.link_sll2 => 20,
        decode.link_null => 4,
        decode.link_raw, decode.link_ipv4, decode.link_ipv6 => 0,
        else => return null,
    };
    if (at >= frame.len) return null;
    switch (summary.family) {
        .ipv4 => {
            if (frame.len - at < 20) return null;
            at += @as(usize, frame[at] & 0x0f) * 4;
        },
        .ipv6 => {
            if (frame.len - at < 40) return null;
            var next = frame[at + 6];
            at += 40;
            var count: u8 = 0;
            while (next == 0 or next == 43 or next == 44 or next == 60 or next == 51 or next == 135) {
                if (count == decode.max_extension_headers or frame.len - at < 8) return null;
                count += 1;
                const length: usize = switch (next) {
                    44 => 8,
                    51 => (@as(usize, frame[at + 1]) + 2) * 4,
                    else => (@as(usize, frame[at + 1]) + 1) * 8,
                };
                next = frame[at];
                if (length > frame.len - at) return null;
                at += length;
            }
        },
        .none => return null,
    }
    if (frame.len - at < 20) return null;
    const tcp_header = @as(usize, frame[at + 12] >> 4) * 4;
    if (tcp_header < 20 or tcp_header > frame.len - at) return null;
    at += tcp_header;
    const length = @min(@as(usize, summary.payload_captured), frame.len - at);
    return frame[at..][0..length];
}

const RawRecord = struct { outer_type: u8, version: u16, header: [5]u8, payload: []const u8, offset: usize, source_record: u32 };

fn parseRecords(a: std.mem.Allocator, bytes: *const DirectionBytes, malformed: *u64) !std.ArrayList(RawRecord) {
    var out: std.ArrayList(RawRecord) = .empty;
    errdefer out.deinit(a);
    var at: usize = 0;
    while (at < bytes.bytes.items.len) {
        if (bytes.bytes.items.len - at < 5) {
            malformed.* += 1;
            break;
        }
        const header: [5]u8 = bytes.bytes.items[at..][0..5].*;
        const length = std.mem.readInt(u16, header[3..5], .big);
        if (length > max_record_bytes or length > bytes.bytes.items.len - at - 5 or header[0] < 20 or header[0] > 24) {
            malformed.* += 1;
            break;
        }
        try out.append(a, .{ .outer_type = header[0], .version = std.mem.readInt(u16, header[1..3], .big), .header = header, .payload = bytes.bytes.items[at + 5 ..][0..length], .offset = at, .source_record = bytes.source(at) });
        at += 5 + length;
    }
    return out;
}

const Hello = struct { client_random: [32]u8, server_random: [32]u8, cipher_suite: u16, version: Version, client_is_a: bool };

fn scanHellos(a: std.mem.Allocator, a_records: []const RawRecord, b_records: []const RawRecord) !Hello {
    const ca = try helloOf(a, a_records, 1);
    defer if (ca) |v| a.free(v);
    const cb = try helloOf(a, b_records, 1);
    defer if (cb) |v| a.free(v);
    const sa = try helloOf(a, a_records, 2);
    defer if (sa) |v| a.free(v);
    const sb = try helloOf(a, b_records, 2);
    defer if (sb) |v| a.free(v);
    const client_is_a = ca != null and sb != null;
    const client = if (client_is_a) ca orelse return error.IncompleteTlsHandshake else cb orelse return error.IncompleteTlsHandshake;
    const server = if (client_is_a) sb orelse return error.IncompleteTlsHandshake else sa orelse return error.IncompleteTlsHandshake;
    if (client.len < 34 or server.len < 38) return error.IncompleteTlsHandshake;
    var out = Hello{ .client_random = client[2..34].*, .server_random = server[2..34].*, .cipher_suite = 0, .version = .tls12, .client_is_a = client_is_a };
    const sid_len = server[34];
    const cipher_at = 35 + @as(usize, sid_len);
    if (server.len < cipher_at + 3) return error.IncompleteTlsHandshake;
    out.cipher_suite = std.mem.readInt(u16, server[cipher_at..][0..2], .big);
    const extensions_at = cipher_at + 3;
    if (server.len >= extensions_at + 2) {
        const extensions_len = std.mem.readInt(u16, server[extensions_at..][0..2], .big);
        if (extensions_len <= server.len - extensions_at - 2) {
            var at = extensions_at + 2;
            const end = at + extensions_len;
            while (at + 4 <= end) {
                const kind = std.mem.readInt(u16, server[at..][0..2], .big);
                const length = std.mem.readInt(u16, server[at + 2 ..][0..2], .big);
                at += 4;
                if (length > end - at) break;
                if (kind == 43 and length == 2 and std.mem.readInt(u16, server[at..][0..2], .big) == 0x0304) out.version = .tls13;
                at += length;
            }
        }
    }
    return out;
}

fn helloOf(a: std.mem.Allocator, records: []const RawRecord, wanted: u8) !?[]u8 {
    var handshake: std.ArrayList(u8) = .empty;
    defer handshake.deinit(a);
    for (records) |record| {
        // In TLS 1.2, handshake records after ChangeCipherSpec are ciphertext
        // even though the outer content type remains handshake.
        if (record.outer_type == 20) break;
        if (record.outer_type != 22) continue;
        if (handshake.items.len + record.payload.len > 256 * 1024) return error.TlsHandshakeLimit;
        try handshake.appendSlice(a, record.payload);
        var at: usize = 0;
        while (handshake.items.len - at >= 4) {
            const length = (@as(usize, handshake.items[at + 1]) << 16) | (@as(usize, handshake.items[at + 2]) << 8) | handshake.items[at + 3];
            if (length > 128 * 1024) return error.TlsHandshakeLimit;
            if (handshake.items.len - at - 4 < length) break;
            if (handshake.items[at] == wanted) return try a.dupe(u8, handshake.items[at + 4 ..][0..length]);
            at += 4 + length;
        }
        if (at != 0) {
            std.mem.copyForwards(u8, handshake.items, handshake.items[at..]);
            handshake.items.len -= at;
        }
    }
    return null;
}

fn cipherOf(id: u16, version: Version) ?Cipher {
    return if (version == .tls13) switch (id) {
        0x1301 => .aes_128_gcm_sha256,
        0x1302 => .aes_256_gcm_sha384,
        0x1303 => .chacha20_poly1305_sha256,
        else => null,
    } else switch (id) {
        0x009c, 0xc02b, 0xc02f => .aes_128_gcm_sha256,
        0x009d, 0xc02c, 0xc030 => .aes_256_gcm_sha384,
        0xcca8, 0xcca9, 0xccaa => .chacha20_poly1305_sha256,
        else => null,
    };
}

const Key = struct {
    cipher: Cipher,
    bytes: [32]u8 = @splat(0),
    length: u8,
    iv: [12]u8,
    fn wipe(self: *Key) void {
        std.crypto.secureZero(u8, &self.bytes);
        std.crypto.secureZero(u8, &self.iv);
    }
};
const Traffic13 = struct {
    handshake: ?Key,
    application: ?Key,
    fn fromLog(log: *const KeyLog, random: [32]u8, cipher: Cipher, client: bool) ?Traffic13 {
        const secret_len: usize = if (cipher == .aes_256_gcm_sha384) 48 else 32;
        const hs_found = log.find(if (client) .client_handshake else .server_handshake, random);
        const app_found = log.find(if (client) .client_application else .server_application, random);
        const hs = if (hs_found) |secret| if (secret.len == secret_len) secret else null else null;
        const app = if (app_found) |secret| if (secret.len == secret_len) secret else null else null;
        if (hs == null and app == null) return null;
        return .{ .handshake = if (hs) |secret| derive13(cipher, secret) else null, .application = if (app) |secret| derive13(cipher, secret) else null };
    }
    fn wipe(self: *Traffic13) void {
        if (self.handshake) |*key| key.wipe();
        if (self.application) |*key| key.wipe();
    }
};

fn derive13(cipher: Cipher, secret: []const u8) Key {
    var out = Key{ .cipher = cipher, .length = if (cipher == .aes_128_gcm_sha256) 16 else 32, .iv = undefined };
    switch (cipher) {
        .aes_128_gcm_sha256, .chacha20_poly1305_sha256 => {
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
            var prk: [Hkdf.prk_length]u8 = @splat(0);
            @memcpy(prk[0..@min(secret.len, prk.len)], secret[0..@min(secret.len, prk.len)]);
            if (cipher == .aes_128_gcm_sha256) {
                const key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 16);
                @memcpy(out.bytes[0..key.len], &key);
            } else {
                const key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 32);
                @memcpy(&out.bytes, &key);
            }
            out.iv = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "iv", "", 12);
            std.crypto.secureZero(u8, &prk);
        },
        .aes_256_gcm_sha384 => {
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha384;
            const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
            var prk: [Hkdf.prk_length]u8 = @splat(0);
            @memcpy(prk[0..@min(secret.len, prk.len)], secret[0..@min(secret.len, prk.len)]);
            const key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 32);
            @memcpy(&out.bytes, &key);
            out.iv = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "iv", "", 12);
            std.crypto.secureZero(u8, &prk);
        },
    }
    return out;
}

fn nonceFor(iv: [12]u8, sequence: u64) [12]u8 {
    var nonce = iv;
    var seq: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq, sequence, .big);
    for (seq, 4..) |b, i| nonce[i] ^= b;
    return nonce;
}

fn decrypt13(stream: *Stream, a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, records: []const RawRecord, keys: *const Traffic13, source: *const network.Stream, summary: *Session) !void {
    const cipher = if (keys.application) |key| key.cipher else keys.handshake.?.cipher;
    var epoch: Epoch = if (keys.handshake != null) .handshake else .application;
    var handshake_seq: u64 = 0;
    var application_seq: u64 = 0;
    for (records) |record| {
        if (record.outer_type != 23) continue;
        const plaintext = try stream.backing.alloc(u8, record.payload.len -| 16);
        var sequence = if (epoch == .handshake) handshake_seq else application_seq;
        var used_epoch = epoch;
        const active = if (epoch == .handshake) keys.handshake else keys.application;
        var ok = if (active) |key| decrypt13Record(key, sequence, record.header, record.payload, plaintext) else false;
        if (!ok and epoch == .handshake and keys.application != null) {
            if (decrypt13Record(keys.application.?, application_seq, record.header, record.payload, plaintext)) {
                epoch = .application;
                used_epoch = .application;
                sequence = application_seq;
                ok = true;
            }
        }
        if (used_epoch == .handshake) handshake_seq +%= 1 else application_seq +%= 1;
        if (!ok) {
            std.crypto.secureZero(u8, plaintext);
            stream.backing.free(plaintext);
            summary.authentication_failures += 1;
            try appendFailure(a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, source);
            continue;
        }
        var end = plaintext.len;
        while (end > 0 and plaintext[end - 1] == 0) end -= 1;
        if (end == 0) {
            std.crypto.secureZero(u8, plaintext);
            stream.backing.free(plaintext);
            summary.authentication_failures += 1;
            try appendFailure(a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, source);
            continue;
        }
        const content_type = plaintext[end - 1];
        const content = plaintext[0 .. end - 1];
        try appendPlain(stream, a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, content_type, content, source, summary);
        std.crypto.secureZero(u8, plaintext);
        stream.backing.free(plaintext);
    }
}

fn decrypt13Record(key: Key, sequence: u64, header: [5]u8, payload: []const u8, out: []u8) bool {
    if (payload.len < 16 or out.len != payload.len - 16) return false;
    const cipher = payload[0 .. payload.len - 16];
    const tag: [16]u8 = payload[payload.len - 16 ..][0..16].*;
    const nonce = nonceFor(key.iv, sequence);
    switch (key.cipher) {
        .aes_128_gcm_sha256 => {
            const k: [16]u8 = key.bytes[0..16].*;
            std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(out, cipher, tag, &header, nonce, k) catch return false;
        },
        .aes_256_gcm_sha384 => {
            std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, cipher, tag, &header, nonce, key.bytes) catch return false;
        },
        .chacha20_poly1305_sha256 => {
            std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(out, cipher, tag, &header, nonce, key.bytes) catch return false;
        },
    }
    return true;
}

const Pair12 = struct {
    client: Key,
    server: Key,
    fn wipe(self: *Pair12) void {
        self.client.wipe();
        self.server.wipe();
    }
};

fn derive12(cipher: Cipher, master: []const u8, client_random: [32]u8, server_random: [32]u8) Pair12 {
    var seed: [64]u8 = undefined;
    @memcpy(seed[0..32], &server_random);
    @memcpy(seed[32..64], &client_random);
    var block: [88]u8 = @splat(0);
    const key_len: usize = if (cipher == .aes_128_gcm_sha256) 16 else 32;
    const iv_len: usize = if (cipher == .chacha20_poly1305_sha256) 12 else 4;
    const length = key_len * 2 + iv_len * 2;
    switch (cipher) {
        .aes_256_gcm_sha384 => pHash(std.crypto.auth.hmac.sha2.HmacSha384, block[0..length], master, &.{ "key expansion", &seed }),
        else => pHash(std.crypto.auth.hmac.sha2.HmacSha256, block[0..length], master, &.{ "key expansion", &seed }),
    }
    var out = Pair12{
        .client = .{ .cipher = cipher, .length = @intCast(key_len), .iv = @splat(0) },
        .server = .{ .cipher = cipher, .length = @intCast(key_len), .iv = @splat(0) },
    };
    @memcpy(out.client.bytes[0..key_len], block[0..key_len]);
    @memcpy(out.server.bytes[0..key_len], block[key_len..][0..key_len]);
    @memcpy(out.client.iv[0..iv_len], block[key_len * 2 ..][0..iv_len]);
    @memcpy(out.server.iv[0..iv_len], block[key_len * 2 + iv_len ..][0..iv_len]);
    std.crypto.secureZero(u8, &block);
    return out;
}

fn pHash(comptime Hmac: type, out: []u8, secret: []const u8, seed_parts: []const []const u8) void {
    var initial = Hmac.init(secret);
    for (seed_parts) |part| initial.update(part);
    var a_value: [Hmac.mac_length]u8 = undefined;
    initial.final(&a_value);
    var at: usize = 0;
    while (at < out.len) {
        var round = Hmac.init(secret);
        round.update(&a_value);
        for (seed_parts) |part| round.update(part);
        var digest: [Hmac.mac_length]u8 = undefined;
        round.final(&digest);
        const take = @min(digest.len, out.len - at);
        @memcpy(out[at..][0..take], digest[0..take]);
        at += take;
        var next = Hmac.init(secret);
        next.update(&a_value);
        next.final(&a_value);
        std.crypto.secureZero(u8, &digest);
    }
    std.crypto.secureZero(u8, &a_value);
}

fn decrypt12(stream: *Stream, a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, records: []const RawRecord, key: Key, source: *const network.Stream, summary: *Session) !void {
    var encrypted = false;
    var sequence: u64 = 0;
    for (records) |record| {
        if (record.outer_type == 20) {
            encrypted = true;
            sequence = 0;
            continue;
        }
        if (!encrypted) continue;
        const overhead: usize = if (key.cipher == .chacha20_poly1305_sha256) 16 else 24;
        if (record.payload.len < overhead) {
            summary.authentication_failures += 1;
            try appendFailure(a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, source);
            sequence +%= 1;
            continue;
        }
        const plaintext = try stream.backing.alloc(u8, record.payload.len - overhead);
        const ok = decrypt12Record(key, sequence, record.header, record.payload, plaintext);
        if (!ok) {
            std.crypto.secureZero(u8, plaintext);
            stream.backing.free(plaintext);
            summary.authentication_failures += 1;
            try appendFailure(a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, source);
            sequence +%= 1;
            continue;
        }
        try appendPlain(stream, a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, record.outer_type, plaintext, source, summary);
        std.crypto.secureZero(u8, plaintext);
        stream.backing.free(plaintext);
        sequence +%= 1;
    }
}

fn decrypt12Record(key: Key, sequence: u64, header: [5]u8, payload: []const u8, out: []u8) bool {
    var aad: [13]u8 = undefined;
    std.mem.writeInt(u64, aad[0..8], sequence, .big);
    @memcpy(aad[8..11], header[0..3]);
    std.mem.writeInt(u16, aad[11..13], @intCast(out.len), .big);
    var nonce: [12]u8 = undefined;
    const cipher_text = if (key.cipher == .chacha20_poly1305_sha256) payload[0 .. payload.len - 16] else blk: {
        @memcpy(nonce[0..4], key.iv[0..4]);
        @memcpy(nonce[4..12], payload[0..8]);
        break :blk payload[8 .. payload.len - 16];
    };
    if (key.cipher == .chacha20_poly1305_sha256) nonce = nonceFor(key.iv, sequence);
    if (cipher_text.len != out.len) return false;
    const tag: [16]u8 = payload[payload.len - 16 ..][0..16].*;
    switch (key.cipher) {
        .aes_128_gcm_sha256 => {
            const k: [16]u8 = key.bytes[0..16].*;
            std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(out, cipher_text, tag, &aad, nonce, k) catch return false;
        },
        .aes_256_gcm_sha384 => std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, cipher_text, tag, &aad, nonce, key.bytes) catch return false,
        .chacha20_poly1305_sha256 => std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(out, cipher_text, tag, &aad, nonce, key.bytes) catch return false,
    }
    return true;
}

fn appendFailure(a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, raw: RawRecord, version: Version, cipher: Cipher, epoch: Epoch, sequence: u64, source: *const network.Stream) !void {
    try out.append(a, .{ .index = @intCast(out.items.len), .flow_id = flow_id, .direction = direction, .source_record = raw.source_record, .time_ns = timeOf(source, raw.source_record), .version = version, .cipher = cipher, .epoch = epoch, .sequence = sequence, .outer_type = raw.outer_type, .state = .authentication_failed });
}

fn appendPlain(stream: *Stream, a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, raw: RawRecord, version: Version, cipher: Cipher, epoch: Epoch, sequence: u64, content_type: u8, plaintext: []const u8, source: *const network.Stream, summary: *Session) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plaintext, &hash, .{});
    var copy: []u8 = &.{};
    if (stream.plaintext_bytes + plaintext.len <= max_plaintext_bytes) {
        copy = try a.dupe(u8, plaintext);
        stream.plaintext_bytes += plaintext.len;
    } else stream.plaintext_dropped += plaintext.len;
    try out.append(a, .{ .index = @intCast(out.items.len), .flow_id = flow_id, .direction = direction, .source_record = raw.source_record, .time_ns = timeOf(source, raw.source_record), .version = version, .cipher = cipher, .epoch = epoch, .sequence = sequence, .outer_type = raw.outer_type, .content_type = content_type, .state = .decrypted, .plaintext_length = @intCast(plaintext.len), .plaintext = copy, .plaintext_sha256 = hash });
    summary.records += 1;
}

fn timeOf(source: *const network.Stream, record: u32) ?u64 {
    const time = source.timeOf(record);
    return if (time.known) time.stream_ns else null;
}

test "key log parser replaces duplicates and rejects wrong TLS 1.3 secret lengths" {
    const a = std.testing.allocator;
    const random: [32]u8 = @splat(0);
    const first: [48]u8 = @splat(0x11);
    const second: [48]u8 = @splat(0x22);
    const random_hex = std.fmt.bytesToHex(random, .lower);
    const first_hex = std.fmt.bytesToHex(first, .lower);
    const second_hex = std.fmt.bytesToHex(second, .lower);
    const bytes = try std.fmt.allocPrint(a, "# synthetic\nCLIENT_RANDOM {s} {s}\nCLIENT_RANDOM {s} {s}\nCLIENT_TRAFFIC_SECRET_0 {s} 01\n", .{ &random_hex, &first_hex, &random_hex, &second_hex, &random_hex });
    defer {
        std.crypto.secureZero(u8, bytes);
        a.free(bytes);
    }
    var parsed = try KeyLog.parse(a, bytes);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), parsed.entries.items.len);
    try std.testing.expectEqual(@as(u8, 0x22), parsed.entries.items[0].bytes[0]);
    try std.testing.expect(Traffic13.fromLog(&parsed, random, .aes_128_gcm_sha256, true) == null);
}

test "TLS 1.3 AES-GCM record decrypts only with its authenticated header" {
    const Aead = std.crypto.aead.aes_gcm.Aes128Gcm;
    const key = Key{ .cipher = .aes_128_gcm_sha256, .bytes = [_]u8{0x5a} ** 32, .length = 16, .iv = [_]u8{0xa5} ** 12 };
    const sequence: u64 = 7;
    const inner = [_]u8{ 1, 2, 3, 23 };
    var header = [5]u8{ 23, 3, 3, 0, inner.len + Aead.tag_length };
    var cipher: [inner.len]u8 = undefined;
    var tag: [Aead.tag_length]u8 = undefined;
    const k: [16]u8 = key.bytes[0..16].*;
    Aead.encrypt(&cipher, &tag, &inner, &header, nonceFor(key.iv, sequence), k);
    const payload = cipher ++ tag;
    var plain: [inner.len]u8 = undefined;
    try std.testing.expect(decrypt13Record(key, sequence, header, &payload, &plain));
    try std.testing.expectEqualSlices(u8, &inner, &plain);
    header[0] = 22;
    try std.testing.expect(!decrypt13Record(key, sequence, header, &payload, &plain));
}

test "TLS 1.2 PRF derives independent directional keys" {
    var master: [48]u8 = undefined;
    var client_random: [32]u8 = undefined;
    var server_random: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x120013);
    prng.random().bytes(&master);
    prng.random().bytes(&client_random);
    prng.random().bytes(&server_random);
    var keys = derive12(.aes_128_gcm_sha256, &master, client_random, server_random);
    defer keys.wipe();
    try std.testing.expect(!std.mem.eql(u8, keys.client.bytes[0..16], keys.server.bytes[0..16]));
    try std.testing.expect(!std.mem.eql(u8, keys.client.iv[0..4], keys.server.iv[0..4]));
}
