//! One redaction policy for every mode (`--redact`): what is private on this
//! machine and how it is shown. A leaf: std only, no session, UI or MCP.
//!
//! Private: paths under home directories, the user's names, the host's names,
//! the distribution's names,
//! IPv4/IPv6 addresses outside loopback, unspecified, broadcast and the
//! documentation ranges, and MAC addresses. Shown as:
//!   /home/NAME/...            ~/...
//!   user name, host name      user, host (any case; as a token: between
//!                             non-letters or at a camelCase step; names of
//!                             8+ characters anywhere, even inside a word)
//!   distribution name        system
//!   address                   ip-XXXXXXXX, mac-XXXXXXXX: the first 4 bytes of
//!                             HMAC-SHA256(key, address), so one peer keeps one
//!                             name within a session (or archive) and the key,
//!                             never stored, makes names unlinkable across them.
//! Text is rewritten with `scrub` (sizes may change), raw bytes with `mask`
//! (same length, matches become 'x'). SSIDs, BSSIDs, Bluetooth addresses and
//! serial numbers are not read by any mode yet.
const std = @import("std");

pub const Kind = enum(u8) { home, user, host, distro };

pub const Policy = struct {
    /// Never written anywhere; per session, or per saved archive (`rekeyed`).
    key: [32]u8,
    words: [max_words]Word = undefined,
    word_count: u8 = 0,
    storage: [1024]u8 = undefined,
    used: u16 = 0,

    const max_words = 16;
    const Word = struct { at: u16, len: u16, kind: Kind };

    pub fn init(key: [32]u8) Policy {
        return .{ .key = key };
    }
    /// The names of this machine: $HOME, the passwd entry, $USER, $LOGNAME and
    /// the host name with its first label.
    pub fn fromMachine(key: [32]u8) Policy {
        var p = init(key);
        const home = env("HOME");
        if (home) |h| p.add(.home, h);
        if (std.c.getpwuid(std.c.getuid())) |pw| {
            if (pw.dir) |d| p.add(.home, std.mem.span(d));
            if (pw.name) |n| p.add(.user, std.mem.span(n));
        }
        if (env("USER")) |u| p.add(.user, u);
        if (env("LOGNAME")) |u| p.add(.user, u);
        if (home) |h| p.add(.user, std.fs.path.basename(std.mem.trimEnd(u8, h, "/")));
        const uts = std.posix.uname();
        const node = std.mem.sliceTo(&uts.nodename, 0);
        p.add(.host, node);
        p.add(.host, node[0 .. std.mem.indexOfScalar(u8, node, '.') orelse node.len]);
        p.addDistroNames();
        return p;
    }
    fn addDistroNames(self: *Policy) void {
        var buffer: [4096]u8 = undefined;
        const text = readFile("/etc/os-release", &buffer) orelse readFile("/usr/lib/os-release", &buffer) orelse return;
        self.addDistroText(text);
    }
    fn addDistroText(self: *Policy, text: []const u8) void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..equal];
            if (!std.mem.eql(u8, key, "PRETTY_NAME") and !std.mem.eql(u8, key, "NAME")) continue;
            var value = std.mem.trim(u8, line[equal + 1 ..], " \t\r");
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) value = value[1 .. value.len - 1];
            self.add(.distro, value);
        }
    }
    /// The same names under another key (one per saved archive).
    pub fn rekeyed(self: *const Policy, key: [32]u8) Policy {
        var copy = self.*;
        copy.key = key;
        return copy;
    }
    pub fn add(self: *Policy, kind: Kind, raw: []const u8) void {
        const text = if (kind == .home) std.mem.trimEnd(u8, raw, "/") else raw;
        // "localhost" and "root" are no one's private names; a one-letter
        // name would eat every word.
        if (text.len < 2 or std.ascii.eqlIgnoreCase(text, "localhost") or std.ascii.eqlIgnoreCase(text, "root")) return;
        if (kind == .home and text[0] != '/') return;
        for (self.words[0..self.word_count]) |w| if (w.kind == kind and std.ascii.eqlIgnoreCase(self.word(w), text)) return;
        if (self.word_count == max_words or self.used + text.len > self.storage.len) return;
        @memcpy(self.storage[self.used..][0..text.len], text);
        // Longest first, so "/home/a/b" wins over a user name inside it.
        var at: usize = self.word_count;
        while (at > 0 and self.words[at - 1].len < text.len) : (at -= 1) self.words[at] = self.words[at - 1];
        self.words[at] = .{ .at = self.used, .len = @intCast(text.len), .kind = kind };
        self.word_count += 1;
        self.used += @intCast(text.len);
    }
    fn word(self: *const Policy, w: Word) []const u8 {
        return self.storage[w.at..][0..w.len];
    }

    /// `text` with every private item replaced; stops when `w` is full.
    pub fn scrub(self: *const Policy, w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        var i: usize = 0;
        var plain: usize = 0;
        while (i < text.len) {
            const m = self.match(text, i) orelse {
                i += 1;
                continue;
            };
            try w.writeAll(text[plain..i]);
            switch (m.what) {
                .home => try w.writeAll("~"),
                .user => try w.writeAll("user"),
                .host => try w.writeAll("host"),
                .distro => try w.writeAll("system"),
                .ip => try w.print("ip-{s}", .{&self.tag("ip", &m.bytes)}),
                .mac => try w.print("mac-{s}", .{&self.tag("mac", m.bytes[0..6])}),
            }
            i += m.len;
            plain = i;
        }
        try w.writeAll(text[plain..]);
    }
    /// Scrubbed into `buffer`, truncated when it does not fit.
    pub fn scrubInto(self: *const Policy, buffer: []u8, text: []const u8) []const u8 {
        var w = std.Io.Writer.fixed(buffer);
        self.scrub(&w, text) catch {};
        return w.buffered();
    }
    pub fn scrubAlloc(self: *const Policy, a: std.mem.Allocator, text: []const u8) ![]u8 {
        var out = std.Io.Writer.Allocating.init(a);
        errdefer out.deinit();
        self.scrub(&out.writer, text) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
    /// Raw bytes (stack copies, fixed-size names): each private item becomes
    /// 'x' bytes of the same length, so offsets and sizes stay valid.
    pub fn mask(self: *const Policy, bytes: []u8) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.match(bytes, i)) |m| {
                @memset(bytes[i..][0..m.len], 'x');
                i += m.len;
            } else i += 1;
        }
    }
    /// Tag text for an address: 8 hex digits of HMAC-SHA256(key, domain ++ bytes).
    pub fn tag(self: *const Policy, domain: []const u8, bytes: []const u8) [8]u8 {
        var mac: [32]u8 = undefined;
        var h = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.key);
        h.update(domain);
        h.update(bytes);
        h.final(&mac);
        return std.fmt.bytesToHex(mac[0..4].*, .lower);
    }
    /// A 16-byte stand-in for a private address in a binary record: the
    /// HMAC of it, unlinkable without the key.
    pub fn tag16(self: *const Policy, domain: []const u8, bytes: []const u8) [16]u8 {
        var mac: [32]u8 = undefined;
        var h = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.key);
        h.update(domain);
        h.update(bytes);
        h.final(&mac);
        return mac[0..16].*;
    }
    /// Scrubs every string value of a JSON document (object keys stay: they are
    /// names from a schema), except the top-level member `keep` (a JSON-RPC id
    /// goes back as the client sent it). Numbers are copied as written.
    pub fn scrubJson(self: *const Policy, a: std.mem.Allocator, json: []const u8, keep: ?[]const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        var value = try std.json.parseFromSliceLeaky(std.json.Value, aa, json, .{ .parse_numbers = false, .allocate = .alloc_always, .duplicate_field_behavior = .use_last });
        if (value == .object and keep != null) {
            var it = value.object.iterator();
            while (it.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, keep.?)) try self.scrubValue(aa, entry.value_ptr);
        } else try self.scrubValue(aa, &value);
        return std.json.Stringify.valueAlloc(a, value, .{});
    }
    pub fn scrubValue(self: *const Policy, a: std.mem.Allocator, value: *std.json.Value) !void {
        switch (value.*) {
            .string => |s| value.* = .{ .string = try self.scrubAlloc(a, s) },
            .array => |*list| for (list.items) |*item| try self.scrubValue(a, item),
            .object => |*map| for (map.values()) |*item| try self.scrubValue(a, item),
            else => {},
        }
    }

    const Match = struct { len: usize, what: enum { home, user, host, distro, ip, mac }, bytes: [16]u8 = @splat(0) };
    fn match(self: *const Policy, t: []const u8, i: usize) ?Match {
        for ([_][]const u8{ "/home/", "/Users/" }) |prefix| if (std.mem.startsWith(u8, t[i..], prefix)) {
            var end = i + prefix.len;
            while (end < t.len and !pathStop(t[end])) end += 1;
            if (end > i + prefix.len) return .{ .len = end - i, .what = .home };
        };
        for (self.words[0..self.word_count]) |w| {
            const text = self.word(w);
            if (i + text.len > t.len) continue;
            const here = t[i..][0..text.len];
            const after = if (i + text.len < t.len) t[i + text.len] else 0;
            if (w.kind == .home) {
                if (std.mem.eql(u8, here, text) and (after == 0 or pathStop(after) or after == '/')) return .{ .len = text.len, .what = .home };
                continue;
            }
            if (!std.ascii.eqlIgnoreCase(here, text)) continue;
            if (text.len < substring_len and !(startsToken(t, i, text.len) and endsToken(t, i + text.len, text.len))) continue;
            return .{ .len = text.len, .what = switch (w.kind) {
                .user => .user,
                .host => .host,
                .distro => .distro,
                .home => unreachable,
            } };
        }
        if (i > 0 and (std.ascii.isAlphanumeric(t[i - 1]) or t[i - 1] == '.' or t[i - 1] == ':')) return null;
        if (!std.ascii.isHex(t[i]) and t[i] != ':') return null;
        if (macAt(t, i)) |bytes| {
            var m = Match{ .len = 17, .what = .mac };
            @memcpy(m.bytes[0..6], &bytes);
            return if (privateMac(bytes)) m else null;
        }
        var end = i;
        var colons: usize = 0;
        while (end < t.len and (std.ascii.isHex(t[end]) or t[end] == ':' or t[end] == '.')) : (end += 1) colons += @intFromBool(t[end] == ':');
        if (colons >= 2) {
            var run = t[i..end];
            if (run.len > 1 and (run[run.len - 1] == '.' or (run[run.len - 1] == ':' and run[run.len - 2] != ':'))) run = run[0 .. run.len - 1];
            if (i + run.len >= t.len or !std.ascii.isAlphanumeric(t[i + run.len])) if (parse6(run)) |bytes| {
                return if (private6(bytes)) .{ .len = run.len, .what = .ip, .bytes = bytes } else null;
            };
        }
        end = i;
        while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) end += 1;
        var run = t[i..end];
        if (run.len > 0 and run[run.len - 1] == '.') run = run[0 .. run.len - 1];
        if (i + run.len < t.len and std.ascii.isAlphanumeric(t[i + run.len])) return null;
        const v4 = parse4(run) orelse return null;
        if (!private4(v4)) return null;
        return .{ .len = run.len, .what = .ip, .bytes = mapped(v4) };
    }
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}
fn readFile(path: []const u8, buffer: []u8) ?[]const u8 {
    if (@import("builtin").os.tag == .windows) return null;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer _ = std.c.close(fd);
    var used: usize = 0;
    while (used < buffer.len) {
        const got = std.posix.read(fd, buffer[used..]) catch return null;
        if (got == 0) break;
        used += got;
    }
    return buffer[0..used];
}
/// Names this long are distinctive: hidden anywhere, even inside a word.
/// Shorter ones only as a token, so a 3-letter name does not eat "stream".
const substring_len = 8;
/// A token edge: a non-letter (path separator, '@', '.', '_', '-', digit), or
/// a camelCase step. Two-letter names also need a non-'_', non-digit edge.
fn startsToken(t: []const u8, i: usize, len: usize) bool {
    if (i == 0) return true;
    return edge(t[i - 1], len) or (len >= 3 and std.ascii.isLower(t[i - 1]) and std.ascii.isUpper(t[i]));
}
fn endsToken(t: []const u8, end: usize, len: usize) bool {
    if (end == t.len) return true;
    return edge(t[end], len) or (len >= 3 and std.ascii.isLower(t[end - 1]) and std.ascii.isUpper(t[end]));
}
fn edge(ch: u8, len: usize) bool {
    if (len < 3) return !std.ascii.isAlphanumeric(ch) and ch != '_';
    return !std.ascii.isAlphabetic(ch);
}
fn pathStop(ch: u8) bool {
    return switch (ch) {
        '/', ' ', '\t', '\n', '\r', '"', '\'', '`', '<', '>', ':', ';', ',', '|', '(', ')', '[', ']', '{', '}', '=', 0 => true,
        else => false,
    };
}

/// IPv4 addresses that name no one: loopback, unspecified, broadcast and the
/// documentation ranges (RFC 5737).
pub fn private4(b: [4]u8) bool {
    if (b[0] == 127) return false;
    if (std.mem.allEqual(u8, &b, 0) or std.mem.allEqual(u8, &b, 255)) return false;
    if (b[0] == 192 and b[1] == 0 and b[2] == 2) return false;
    if (b[0] == 198 and b[1] == 51 and b[2] == 100) return false;
    if (b[0] == 203 and b[1] == 0 and b[2] == 113) return false;
    return true;
}
/// IPv6: :: and ::1, 2001:db8::/32 (RFC 3849), and v4-mapped by the IPv4 rule.
pub fn private6(b: [16]u8) bool {
    if (std.mem.allEqual(u8, b[0..15], 0) and b[15] <= 1) return false;
    if (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8) return false;
    if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff) return private4(b[12..16].*);
    return true;
}
/// An address as stored in a 16-byte field: IPv4 in the first four bytes.
pub fn privateAddress(v6: bool, bytes: [16]u8) bool {
    return if (v6) private6(bytes) else private4(bytes[0..4].*);
}
fn privateMac(b: [6]u8) bool {
    return !std.mem.allEqual(u8, &b, 0) and !std.mem.allEqual(u8, &b, 0xff);
}
fn mapped(v4: [4]u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[10] = 0xff;
    out[11] = 0xff;
    @memcpy(out[12..16], &v4);
    return out;
}
fn parse4(s: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4 or part.len == 0 or part.len > 3) return null;
        out[n] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (n == 4) out else null;
}
fn parse6(s: []const u8) ?[16]u8 {
    var groups: [8]u16 = undefined;
    var count: usize = 0;
    var gap: ?usize = null;
    var rest = s;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = 0;
        rest = rest[2..];
    } else if (rest.len > 0 and rest[0] == ':') return null;
    var tail_v4: ?[4]u8 = null;
    while (rest.len > 0) {
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const part = rest[0 .. colon orelse rest.len];
        if (part.len == 0) return null;
        if (colon == null and std.mem.indexOfScalar(u8, part, '.') != null) {
            tail_v4 = parse4(part) orelse return null;
            rest = "";
            break;
        }
        if (part.len > 4 or count == 8) return null;
        groups[count] = std.fmt.parseInt(u16, part, 16) catch return null;
        count += 1;
        if (colon) |at| {
            rest = rest[at + 1 ..];
            if (rest.len > 0 and rest[0] == ':') {
                if (gap != null) return null;
                gap = count;
                rest = rest[1..];
            } else if (rest.len == 0) return null;
        } else rest = "";
    }
    const total = count + @as(usize, if (tail_v4 != null) 2 else 0);
    if (gap == null and total != 8) return null;
    if (gap != null and total > 7) return null;
    var out: [16]u8 = @splat(0);
    const head = gap orelse count;
    for (groups[0..head], 0..) |g, k| std.mem.writeInt(u16, out[k * 2 ..][0..2], g, .big);
    const tail_groups = count - head;
    const tail_at = 16 - (if (tail_v4 != null) @as(usize, 4) else 0) - tail_groups * 2;
    for (groups[head..count], 0..) |g, k| std.mem.writeInt(u16, out[tail_at + k * 2 ..][0..2], g, .big);
    if (tail_v4) |v4| @memcpy(out[12..16], &v4);
    return out;
}
fn macAt(t: []const u8, i: usize) ?[6]u8 {
    if (i + 17 > t.len) return null;
    const sep = t[i + 2];
    if (sep != ':' and sep != '-') return null;
    var out: [6]u8 = undefined;
    for (0..6) |k| {
        const at = i + k * 3;
        if (k < 5 and t[at + 2] != sep) return null;
        out[k] = std.fmt.parseInt(u8, t[at..][0..2], 16) catch return null;
    }
    if (i + 17 < t.len and (std.ascii.isHex(t[i + 17]) or t[i + 17] == sep)) return null;
    return out;
}

// ------------------------------------------------------------ the session policy

/// Set once by `enable`, before any thread starts; read-only afterwards.
var global: ?Policy = null;
pub fn active() ?*const Policy {
    return if (global) |*p| p else null;
}
/// Turns redaction on for this process with a fresh session key.
pub fn enable() void {
    global = Policy.fromMachine(randomKey());
}
pub fn randomKey() [32]u8 {
    var key: [32]u8 = undefined;
    var got: usize = 0;
    while (got < key.len) {
        const n = std.os.linux.getrandom(key[got..].ptr, key.len - got, 0);
        if (@as(isize, @bitCast(n)) <= 0) continue;
        got += n;
    }
    return key;
}

// ------------------------------------------------------------ tests (synthetic names)

fn testPolicy() Policy {
    var p = Policy.init(@splat(7));
    p.add(.home, "/srv/people/zed/");
    p.add(.user, "zed");
    p.add(.user, "Quinella");
    p.add(.host, "quarkbox.example.org");
    p.add(.host, "quarkbox");
    return p;
}

test "os-release names are private text" {
    var p = Policy.init(@splat(4));
    p.addDistroText("PRETTY_NAME=\"Example Workstation 42\"\nNAME='Example Linux'\nID=example\n");
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("system and system; example stays", p.scrubInto(&buffer, "Example Workstation 42 and Example Linux; example stays"));
}

test "scrub hides homes, names and private addresses, keeps loopback and documentation" {
    const p = testPolicy();
    var buf: [512]u8 = undefined;
    const out = p.scrubInto(&buf, "/home/alice/src/a.c /srv/people/zed/x QUINELLA@QuarkBox.example.org zed 10.1.2.3:443 127.0.0.1 192.0.2.7 fe80::1%eth0 2001:db8::1 ::1 aa:bb:cc:dd:ee:0f v1.2.3");
    for ([_][]const u8{ "alice", "zed", "uinella", "uark", "10.1.2.3", "fe80", "aa:bb" }) |gone| try std.testing.expect(std.ascii.indexOfIgnoreCase(out, gone) == null);
    for ([_][]const u8{ "~/src/a.c", "~/x", "user@host", "127.0.0.1", "192.0.2.7", "2001:db8::1", " ::1 ", "v1.2.3", ":443", "%eth0", "ip-", "mac-" }) |kept| try std.testing.expect(std.mem.indexOf(u8, out, kept) != null);
    // One peer, one name; another key, another name.
    const again = p.scrubInto(buf[400..], "10.1.2.3");
    try std.testing.expect(std.mem.indexOf(u8, out, again) != null);
    const other = p.rekeyed(@splat(9));
    var buf2: [32]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, again, other.scrubInto(&buf2, "10.1.2.3")));
    // v4-mapped IPv6 is the same peer.
    var buf3: [32]u8 = undefined;
    try std.testing.expectEqualStrings(again, p.scrubInto(&buf3, "::ffff:10.1.2.3"));
}

test "scrub leaves ordinary text alone and short names only as words" {
    var p = Policy.init(@splat(1));
    p.add(.user, "ab");
    p.add(.user, "x"); // too short: ignored
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("tab user ns::get std::vector 1.2.3.4.5 0.0.0.0", p.scrubInto(&buf, "tab ab ns::get std::vector 1.2.3.4.5 0.0.0.0"));
}

test "short names only as tokens, long names anywhere" {
    var p = Policy.init(@splat(2));
    p.add(.user, "rea");
    p.add(.host, "ark");
    p.add(.host, "io");
    p.add(.user, "quinella");
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "query_stream steam team dream markdown park ioctl stdio.h io_uring io2 xuserx user",
        p.scrubInto(&buf, "query_stream steam team dream markdown park ioctl stdio.h io_uring io2 xquinellax QUINELLA"),
    );
    try std.testing.expectEqualStrings(
        "user@host.local /data/user/x user_profile.c user-profile.c myuser userProfile user2 host:22 [host] user",
        p.scrubInto(&buf, "rea@ark.local /data/rea/x rea_profile.c rea-profile.c myRea reaProfile rea2 io:22 [io] REA"),
    );
}

test "mask keeps length, scrubJson keeps keys and numbers" {
    const p = testPolicy();
    var bytes = "\x00/home/bob/.cache\x00zed\x0110.9.8.7\x00".*;
    const before = bytes.len;
    p.mask(&bytes);
    try std.testing.expectEqual(before, bytes.len);
    try std.testing.expect(std.mem.indexOf(u8, &bytes, "bob") == null and std.mem.indexOf(u8, &bytes, "zed") == null and std.mem.indexOf(u8, &bytes, "10.9") == null);
    const out = try p.scrubJson(std.testing.allocator, "{\"zed\":\"/home/zed/a\",\"n\":18446744073709551615,\"f\":1.50,\"l\":[\"quarkbox\",true,null],\"id\":\"zed\"}", "id");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"zed\":\"~/a\",\"n\":18446744073709551615,\"f\":1.50,\"l\":[\"host\",true,null],\"id\":\"zed\"}", out);
}

test "the machine's own names are hidden" {
    const p = Policy.fromMachine(randomKey());
    const uts = std.posix.uname();
    const node = std.mem.sliceTo(&uts.nodename, 0);
    var buf: [512]u8 = undefined;
    const out = p.scrubInto(&buf, node);
    if (node.len >= 3 and !std.ascii.eqlIgnoreCase(node, "localhost")) try std.testing.expect(std.ascii.indexOfIgnoreCase(out, node) == null);
    if (env("HOME")) |home| if (home.len > 1) {
        const scrubbed = p.scrubInto(&buf, home);
        try std.testing.expect(std.mem.indexOf(u8, scrubbed, home) == null);
    };
}

test "parse6 forms" {
    try std.testing.expect(parse6("::") != null);
    try std.testing.expect(parse6("1:2:3:4:5:6:7:8") != null);
    try std.testing.expect(parse6("1:2:3:4:5:6:7") == null);
    try std.testing.expect(parse6("1::2::3") == null);
    try std.testing.expect(parse6("::ffff:1.2.3.4").?[15] == 4);
    try std.testing.expectEqual(@as(u8, 1), parse6("fe80::1").?[15]);
    try std.testing.expectEqual(@as(u8, 0xfe), parse6("fe80::1").?[0]);
}
