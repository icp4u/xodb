//! TLS records derived from an immutable packet stream and a user-supplied
//! NSS SSLKEYLOGFILE. The key log is parsed, used, and wiped during open;
//! only authenticated plaintext records and provenance survive.
const std = @import("std");
const network = @import("stream.zig");
const decode = @import("decode.zig");
const reassembly = @import("reassembly.zig");

pub const decoder = "xodb-tls-keylog";
pub const decoder_version: u32 = 1;
pub const max_keylog_entries = 16_384;
pub const max_reassembled_bytes = 64 * 1024 * 1024;
pub const max_plaintext_bytes = 64 * 1024 * 1024;
pub const max_record_bytes = 18_432;
pub const max_derived_records = 256 * 1024;

pub const Version = enum { tls12, tls13 };
pub const Direction = enum { client_to_server, server_to_client };
pub const Epoch = enum { handshake, application };
pub const State = enum { decrypted, authentication_failed };
pub const SessionState = enum { decrypted, partial, missing_key, unsupported_cipher, incomplete_handshake, reassembly_gap };
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
    malformed_directions: u8 = 0,
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
    derived_limit_hit: bool = false,

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
        // Records use the backing allocator so ArrayList growth releases old
        // buffers. Arena-backed growth retained every prior buffer and made a
        // cap-sized stream consume close to 2 GiB.
        var records: std.ArrayList(Record) = .empty;
        errdefer records.deinit(a);
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
            var reassembled = try reassembly.reassemble(a, source, by_flow[starts[flow_id]..starts[flow_id + 1]], flow.key, max_reassembled_bytes);
            defer reassembled.deinit(a);
            if (reassembled.a.bytes.items.len == 0 or reassembled.b.bytes.items.len == 0) continue;
            var malformed_a = false;
            var raw_a = try parseRecords(a, &reassembled.a, &self.malformed_records, &malformed_a);
            defer raw_a.deinit(a);
            var malformed_b = false;
            var raw_b = try parseRecords(a, &reassembled.b, &self.malformed_records, &malformed_b);
            defer raw_b.deinit(a);
            if (raw_a.items.len == 0 and raw_b.items.len == 0) continue;
            const hello = scanHellos(a, raw_a.items, raw_b.items) catch {
                try sessions.append(arena, .{ .flow_id = flow_id, .state = if (reassembled.incomplete()) .reassembly_gap else .incomplete_handshake });
                if (reassembled.incomplete()) self.reassembly_gaps += 1;
                continue;
            };
            const cipher = cipherOf(hello.cipher_suite, hello.version) orelse {
                try sessions.append(arena, .{ .flow_id = flow_id, .version = hello.version, .state = .unsupported_cipher });
                continue;
            };
            var summary = Session{
                .flow_id = flow_id,
                .version = hello.version,
                .cipher = cipher,
                .state = .decrypted,
                .malformed_directions = @as(u8, @intFromBool(malformed_a)) + @intFromBool(malformed_b),
            };
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
                    decrypt13(self, a, arena, &records, flow_id, .client_to_server, client_records, &ck, source, &summary) catch |err| switch (err) {
                        error.TlsRecordLimit => self.derived_limit_hit = true,
                        else => return err,
                    };
                    if (!self.derived_limit_hit) decrypt13(self, a, arena, &records, flow_id, .server_to_client, server_records, &sk, source, &summary) catch |err| switch (err) {
                        error.TlsRecordLimit => self.derived_limit_hit = true,
                        else => return err,
                    };
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
                    decrypt12(self, a, arena, &records, flow_id, .client_to_server, client_records, &keys.client, source, &summary) catch |err| switch (err) {
                        error.TlsRecordLimit => self.derived_limit_hit = true,
                        else => return err,
                    };
                    if (!self.derived_limit_hit) decrypt12(self, a, arena, &records, flow_id, .server_to_client, server_records, &keys.server, source, &summary) catch |err| switch (err) {
                        error.TlsRecordLimit => self.derived_limit_hit = true,
                        else => return err,
                    };
                },
            }
            if (summary.state == .decrypted and (summary.malformed_directions != 0 or self.derived_limit_hit)) summary.state = .partial;
            if (reassembled.incomplete()) {
                self.reassembly_gaps += 1;
                if (summary.records == 0 and summary.malformed_directions == 0 and !self.derived_limit_hit) summary.state = .reassembly_gap;
            }
            try sessions.append(arena, summary);
            if (self.derived_limit_hit) break;
        }
        self.records = try records.toOwnedSlice(a);
        self.sessions = sessions.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        for (self.records) |record| if (record.plaintext.len != 0) std.crypto.secureZero(u8, record.plaintext);
        std.crypto.secureZero(u8, std.mem.sliceAsBytes(self.records));
        a.free(self.records);
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

const DirectionBytes = reassembly.Direction;

const RawRecord = struct { outer_type: u8, version: u16, header: [5]u8, payload: []const u8, offset: usize, source_record: u32 };

fn parseRecords(a: std.mem.Allocator, bytes: *const DirectionBytes, malformed: *u64, stopped_malformed: *bool) !std.ArrayList(RawRecord) {
    var out: std.ArrayList(RawRecord) = .empty;
    errdefer out.deinit(a);
    var at: usize = 0;
    while (at < bytes.bytes.items.len) {
        if (bytes.bytes.items.len - at < 5) {
            malformed.* += 1;
            stopped_malformed.* = true;
            break;
        }
        const header: [5]u8 = bytes.bytes.items[at..][0..5].*;
        const length = std.mem.readInt(u16, header[3..5], .big);
        if (length > max_record_bytes or length > bytes.bytes.items.len - at - 5 or header[0] < 20 or header[0] > 24) {
            malformed.* += 1;
            stopped_malformed.* = true;
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
                var key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 16);
                @memcpy(out.bytes[0..key.len], &key);
                std.crypto.secureZero(u8, &key);
            } else {
                var key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 32);
                @memcpy(&out.bytes, &key);
                std.crypto.secureZero(u8, &key);
            }
            var iv = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "iv", "", 12);
            out.iv = iv;
            std.crypto.secureZero(u8, &iv);
            std.crypto.secureZero(u8, &prk);
        },
        .aes_256_gcm_sha384 => {
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha384;
            const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
            var prk: [Hkdf.prk_length]u8 = @splat(0);
            @memcpy(prk[0..@min(secret.len, prk.len)], secret[0..@min(secret.len, prk.len)]);
            var key = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "key", "", 32);
            @memcpy(&out.bytes, &key);
            std.crypto.secureZero(u8, &key);
            var iv = std.crypto.tls.hkdfExpandLabel(Hkdf, prk, "iv", "", 12);
            out.iv = iv;
            std.crypto.secureZero(u8, &iv);
            std.crypto.secureZero(u8, &prk);
        },
    }
    return out;
}

fn nonceFor(iv: *const [12]u8, sequence: u64) [12]u8 {
    var nonce = iv.*;
    var seq: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq, sequence, .big);
    for (seq, 4..) |b, i| nonce[i] ^= b;
    return nonce;
}

fn decrypt13(stream: *Stream, record_a: std.mem.Allocator, storage_a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, records: []const RawRecord, keys: *const Traffic13, source: *const network.Stream, summary: *Session) !void {
    const cipher = if (keys.application) |*key| key.cipher else keys.handshake.?.cipher;
    var epoch: Epoch = if (keys.handshake != null) .handshake else .application;
    var handshake_seq: u64 = 0;
    var application_seq: u64 = 0;
    for (records) |record| {
        if (record.outer_type != 23) continue;
        const plaintext = try stream.backing.alloc(u8, record.payload.len -| 16);
        // Wiped on every exit, including a TlsRecordLimit/OOM from appendPlain.
        defer {
            std.crypto.secureZero(u8, plaintext);
            stream.backing.free(plaintext);
        }
        var sequence = if (epoch == .handshake) handshake_seq else application_seq;
        var used_epoch = epoch;
        var ok = switch (epoch) {
            .handshake => if (keys.handshake) |*key| decrypt13Record(key, sequence, record.header, record.payload, plaintext) else false,
            .application => if (keys.application) |*key| decrypt13Record(key, sequence, record.header, record.payload, plaintext) else false,
        };
        if (!ok and epoch == .handshake) if (keys.application) |*application| {
            if (decrypt13Record(application, application_seq, record.header, record.payload, plaintext)) {
                epoch = .application;
                used_epoch = .application;
                sequence = application_seq;
                ok = true;
            }
        };
        if (used_epoch == .handshake) handshake_seq +%= 1 else application_seq +%= 1;
        if (!ok) {
            try appendFailure(record_a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, source);
            summary.authentication_failures += 1;
            continue;
        }
        var end = plaintext.len;
        while (end > 0 and plaintext[end - 1] == 0) end -= 1;
        if (end == 0) {
            try appendFailure(record_a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, source);
            summary.authentication_failures += 1;
            continue;
        }
        const content_type = plaintext[end - 1];
        const content = plaintext[0 .. end - 1];
        try appendPlain(stream, record_a, storage_a, out, flow_id, direction, record, .tls13, cipher, used_epoch, sequence, content_type, content, source, summary);
    }
}

fn decrypt13Record(key: *const Key, sequence: u64, header: [5]u8, payload: []const u8, out: []u8) bool {
    if (payload.len < 16 or out.len != payload.len - 16) return false;
    const cipher = payload[0 .. payload.len - 16];
    const tag: [16]u8 = payload[payload.len - 16 ..][0..16].*;
    var nonce = nonceFor(&key.iv, sequence);
    defer std.crypto.secureZero(u8, &nonce);
    var key_bytes = key.bytes;
    defer std.crypto.secureZero(u8, &key_bytes);
    switch (key.cipher) {
        .aes_128_gcm_sha256 => {
            var k: [16]u8 = key_bytes[0..16].*;
            defer std.crypto.secureZero(u8, &k);
            std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(out, cipher, tag, &header, nonce, k) catch return false;
        },
        .aes_256_gcm_sha384 => {
            std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, cipher, tag, &header, nonce, key_bytes) catch return false;
        },
        .chacha20_poly1305_sha256 => {
            std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(out, cipher, tag, &header, nonce, key_bytes) catch return false;
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
    defer std.crypto.secureZero(u8, std.mem.asBytes(&initial));
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
        std.crypto.secureZero(u8, std.mem.asBytes(&round));
        const take = @min(digest.len, out.len - at);
        @memcpy(out[at..][0..take], digest[0..take]);
        at += take;
        var next = Hmac.init(secret);
        next.update(&a_value);
        next.final(&a_value);
        std.crypto.secureZero(u8, std.mem.asBytes(&next));
        std.crypto.secureZero(u8, &digest);
    }
    std.crypto.secureZero(u8, &a_value);
}

fn decrypt12(stream: *Stream, record_a: std.mem.Allocator, storage_a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, records: []const RawRecord, key: *const Key, source: *const network.Stream, summary: *Session) !void {
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
            try appendFailure(record_a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, source);
            summary.authentication_failures += 1;
            sequence +%= 1;
            continue;
        }
        const plaintext = try stream.backing.alloc(u8, record.payload.len - overhead);
        defer {
            std.crypto.secureZero(u8, plaintext);
            stream.backing.free(plaintext);
        }
        const ok = decrypt12Record(key, sequence, record.header, record.payload, plaintext);
        if (!ok) {
            try appendFailure(record_a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, source);
            summary.authentication_failures += 1;
            sequence +%= 1;
            continue;
        }
        try appendPlain(stream, record_a, storage_a, out, flow_id, direction, record, .tls12, key.cipher, .application, sequence, record.outer_type, plaintext, source, summary);
        sequence +%= 1;
    }
}

fn decrypt12Record(key: *const Key, sequence: u64, header: [5]u8, payload: []const u8, out: []u8) bool {
    var aad: [13]u8 = undefined;
    std.mem.writeInt(u64, aad[0..8], sequence, .big);
    @memcpy(aad[8..11], header[0..3]);
    std.mem.writeInt(u16, aad[11..13], @intCast(out.len), .big);
    var nonce: [12]u8 = undefined;
    defer std.crypto.secureZero(u8, &nonce);
    const cipher_text = if (key.cipher == .chacha20_poly1305_sha256) payload[0 .. payload.len - 16] else blk: {
        @memcpy(nonce[0..4], key.iv[0..4]);
        @memcpy(nonce[4..12], payload[0..8]);
        break :blk payload[8 .. payload.len - 16];
    };
    if (key.cipher == .chacha20_poly1305_sha256) nonce = nonceFor(&key.iv, sequence);
    if (cipher_text.len != out.len) return false;
    const tag: [16]u8 = payload[payload.len - 16 ..][0..16].*;
    var key_bytes = key.bytes;
    defer std.crypto.secureZero(u8, &key_bytes);
    switch (key.cipher) {
        .aes_128_gcm_sha256 => {
            var k: [16]u8 = key_bytes[0..16].*;
            defer std.crypto.secureZero(u8, &k);
            std.crypto.aead.aes_gcm.Aes128Gcm.decrypt(out, cipher_text, tag, &aad, nonce, k) catch return false;
        },
        .aes_256_gcm_sha384 => std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, cipher_text, tag, &aad, nonce, key_bytes) catch return false,
        .chacha20_poly1305_sha256 => std.crypto.aead.chacha_poly.ChaCha20Poly1305.decrypt(out, cipher_text, tag, &aad, nonce, key_bytes) catch return false,
    }
    return true;
}

fn appendFailure(a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, raw: RawRecord, version: Version, cipher: Cipher, epoch: Epoch, sequence: u64, source: *const network.Stream) !void {
    try appendDerived(a, out, .{ .index = @intCast(out.items.len), .flow_id = flow_id, .direction = direction, .source_record = raw.source_record, .time_ns = timeOf(source, raw.source_record), .version = version, .cipher = cipher, .epoch = epoch, .sequence = sequence, .outer_type = raw.outer_type, .state = .authentication_failed }, max_derived_records);
}

fn appendPlain(stream: *Stream, record_a: std.mem.Allocator, storage_a: std.mem.Allocator, out: *std.ArrayList(Record), flow_id: u32, direction: Direction, raw: RawRecord, version: Version, cipher: Cipher, epoch: Epoch, sequence: u64, content_type: u8, plaintext: []const u8, source: *const network.Stream, summary: *Session) !void {
    if (out.items.len >= max_derived_records) return error.TlsRecordLimit;
    // Reserve before retaining plaintext so an allocation failure cannot leave
    // an unreferenced secret in arena storage.
    try out.ensureUnusedCapacity(record_a, 1);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(plaintext, &hash, .{});
    var copy: []u8 = &.{};
    if (stream.plaintext_bytes + plaintext.len <= max_plaintext_bytes) {
        copy = try storage_a.dupe(u8, plaintext);
        stream.plaintext_bytes += plaintext.len;
    } else stream.plaintext_dropped += plaintext.len;
    out.appendAssumeCapacity(.{ .index = @intCast(out.items.len), .flow_id = flow_id, .direction = direction, .source_record = raw.source_record, .time_ns = timeOf(source, raw.source_record), .version = version, .cipher = cipher, .epoch = epoch, .sequence = sequence, .outer_type = raw.outer_type, .content_type = content_type, .state = .decrypted, .plaintext_length = @intCast(plaintext.len), .plaintext = copy, .plaintext_sha256 = hash });
    summary.records += 1;
}

fn appendDerived(a: std.mem.Allocator, out: *std.ArrayList(Record), record: Record, limit: usize) !void {
    if (out.items.len >= limit) return error.TlsRecordLimit;
    try out.append(a, record);
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
    var nonce = nonceFor(&key.iv, sequence);
    defer std.crypto.secureZero(u8, &nonce);
    Aead.encrypt(&cipher, &tag, &inner, &header, nonce, k);
    const payload = cipher ++ tag;
    var plain: [inner.len]u8 = undefined;
    try std.testing.expect(decrypt13Record(&key, sequence, header, &payload, &plain));
    try std.testing.expectEqualSlices(u8, &inner, &plain);
    header[0] = 22;
    try std.testing.expect(!decrypt13Record(&key, sequence, header, &payload, &plain));
}

test "derived TLS records stop at their configured limit" {
    const a = std.testing.allocator;
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(a);
    const record = Record{ .index = 0, .flow_id = 0, .direction = .client_to_server, .source_record = 0, .time_ns = null, .version = .tls13, .cipher = .aes_128_gcm_sha256, .epoch = .application, .sequence = 0, .outer_type = 23, .state = .authentication_failed };
    try appendDerived(a, &records, record, 1);
    try std.testing.expectError(error.TlsRecordLimit, appendDerived(a, &records, record, 1));
    try std.testing.expectEqual(@as(usize, 1), records.items.len);
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
