//! pcap and pcapng reader over bytes held in memory.
//!
//! The caller owns `bytes` for as long as the result is used: every record
//! points at its packet bytes by offset, so raw evidence stays addressable and
//! is never copied. Parsing never fails on content: a truncated or corrupt
//! file gives the records before the fault, the fault's kind and byte offset,
//! and counts of everything skipped. The only errors are allocation failure
//! and bytes that are not a capture at all.
//!
//! pcapng: SHB (both byte orders, several sections), IDB (if_name, if_tsresol,
//! if_tsoffset), EPB (epb_dropcount), SPB, ISB (ifrecv/ifdrop/osdrop), and the
//! obsolete PB. Other block types are counted and skipped. Times are
//! nanoseconds in the file's clock, which pcap and pcapng define as
//! CLOCK_REALTIME (seconds since the Unix epoch); SPB records have none.
const std = @import("std");

pub const Format = enum { pcap, pcapng };
pub const Stop = enum {
    /// Every byte was accounted for.
    complete,
    /// The file ends inside a header or block.
    truncated,
    /// A length, trailer or magic is inconsistent; later bytes are not trusted.
    corrupt,
    /// The record or interface limit was reached.
    limit,
};

/// Largest packet a record may claim. Larger lengths are treated as corruption.
pub const max_packet = 256 * 1024;
pub const max_interfaces = 1024;
pub const Limits = struct { max_records: usize = 4 * 1024 * 1024 };

pub const Interface = struct {
    link_type: u16,
    snaplen: u32,
    /// pcapng section ordinal (0 for pcap).
    section: u32,
    /// Byte order declared by the containing pcap file or pcapng section.
    /// Native-layout link headers (notably Linux usbmon) use this order.
    big_endian: bool = false,
    /// if_tsresol byte: bit 7 clear means 10^-n seconds, set means 2^-n.
    tsresol: u8 = 6,
    tsoffset_s: i64 = 0,
    /// if_name, borrowed from the file; empty when absent.
    name: []const u8 = "",
    packets: u64 = 0,
    /// Records whose captured length is below the original length.
    truncated_packets: u64 = 0,
    /// Sum of epb_dropcount options (packets lost between this and the previous packet).
    epb_drops: u64 = 0,
    /// Latest ISB counters; null when no ISB carried them.
    isb_ifrecv: ?u64 = null,
    isb_ifdrop: ?u64 = null,
    isb_osdrop: ?u64 = null,
    isb_count: u32 = 0,
};

pub const Block = enum(u8) { pcap_record, epb, spb, pb };
pub const Record = struct {
    /// Offset of the packet bytes in the file.
    offset: u32,
    caplen: u32,
    origlen: u32,
    /// Index into `Result.interfaces`.
    interface: u32,
    /// Offset of the record or block header.
    block_offset: u32,
    block: Block,
    time_known: bool,
    /// Nanoseconds since the Unix epoch in the file's clock; 0 when not known.
    time_ns: u64,
};

pub const Result = struct {
    format: Format,
    /// Byte order of the first section (pcapng) or file (pcap).
    big_endian: bool,
    /// pcap only: the magic declared nanosecond timestamps.
    nanosecond: bool = false,
    sections: u32 = 0,
    interfaces: []Interface,
    records: []Record,
    blocks: u64 = 0,
    /// pcapng blocks of types this reader does not interpret (NRB, DSB, custom...).
    unknown_blocks: u64 = 0,
    /// Packet blocks naming an interface that does not exist in their section.
    orphan_records: u64 = 0,
    /// Options whose length runs past their block; the rest of that block's options are skipped.
    bad_options: u64 = 0,
    /// Times that do not fit 64-bit nanoseconds since the epoch.
    time_overflow: u64 = 0,
    stop: Stop = .complete,
    stop_offset: u64 = 0,
    stop_reason: []const u8 = "",

    pub fn data(self: *const Result, bytes: []const u8, i: usize) []const u8 {
        const r = self.records[i];
        return bytes[r.offset..][0..r.caplen];
    }
    pub fn deinit(self: *Result, a: std.mem.Allocator) void {
        a.free(self.interfaces);
        a.free(self.records);
    }
};

pub const pcap_us = 0xa1b2c3d4;
pub const pcap_ns = 0xa1b23c4d;
pub const pcapng_shb = 0x0a0d0d0a;
const byte_order_magic = 0x1a2b3c4d;

pub fn detect(bytes: []const u8) ?Format {
    if (bytes.len < 4) return null;
    const le = std.mem.readInt(u32, bytes[0..4], .little);
    const be = std.mem.readInt(u32, bytes[0..4], .big);
    if (le == pcapng_shb) return .pcapng;
    for ([_]u32{ le, be }) |m| if (m == pcap_us or m == pcap_ns) return .pcap;
    return null;
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8, limits: Limits) !Result {
    const format = detect(bytes) orelse return error.NotACapture;
    if (bytes.len > std.math.maxInt(u32)) return error.CaptureTooLarge;
    var p = Parser{ .a = a, .bytes = bytes, .limits = limits };
    errdefer {
        p.interfaces.deinit(a);
        p.records.deinit(a);
    }
    var result = Result{ .format = format, .big_endian = false, .interfaces = &.{}, .records = &.{} };
    switch (format) {
        .pcap => try p.pcap(&result),
        .pcapng => try p.pcapng(&result),
    }
    result.interfaces = try p.interfaces.toOwnedSlice(a);
    result.records = try p.records.toOwnedSlice(a);
    return result;
}

const Parser = struct {
    a: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
    interfaces: std.ArrayList(Interface) = .empty,
    records: std.ArrayList(Record) = .empty,

    fn halt(result: *Result, stop: Stop, offset: usize, reason: []const u8) void {
        result.stop = stop;
        result.stop_offset = offset;
        result.stop_reason = reason;
    }
    fn add(self: *Parser, result: *Result, record: Record) !bool {
        if (self.records.items.len >= self.limits.max_records) {
            halt(result, .limit, record.block_offset, "record limit");
            return false;
        }
        try self.records.append(self.a, record);
        const iface = &self.interfaces.items[record.interface];
        iface.packets += 1;
        if (record.caplen < record.origlen) iface.truncated_packets += 1;
        return true;
    }

    fn pcap(self: *Parser, result: *Result) !void {
        const b = self.bytes;
        const first = std.mem.readInt(u32, b[0..4], .little);
        const endian: std.builtin.Endian = if (first == pcap_us or first == pcap_ns) .little else .big;
        result.big_endian = endian == .big;
        const magic = std.mem.readInt(u32, b[0..4], endian);
        result.nanosecond = magic == pcap_ns;
        if (b.len < 24) return halt(result, .truncated, 0, "file header");
        result.sections = 1;
        const zone = std.mem.readInt(i32, b[8..12], endian);
        const snaplen = std.mem.readInt(u32, b[16..20], endian);
        const link = std.mem.readInt(u32, b[20..24], endian);
        try self.interfaces.append(self.a, .{ .link_type = @truncate(link), .snaplen = snaplen, .section = 0, .big_endian = endian == .big, .tsresol = if (result.nanosecond) 9 else 6 });
        var at: usize = 24;
        while (at < b.len) {
            if (b.len - at < 16) return halt(result, .truncated, at, "record header");
            const sec = std.mem.readInt(u32, b[at..][0..4], endian);
            const frac = std.mem.readInt(u32, b[at + 4 ..][0..4], endian);
            const caplen = std.mem.readInt(u32, b[at + 8 ..][0..4], endian);
            const origlen = std.mem.readInt(u32, b[at + 12 ..][0..4], endian);
            if (caplen > max_packet and caplen > snaplen) return halt(result, .corrupt, at, "record length");
            if (frac >= (if (result.nanosecond) @as(u32, 1_000_000_000) else 1_000_000)) return halt(result, .corrupt, at, "fraction of a second out of range");
            if (b.len - at - 16 < caplen) return halt(result, .truncated, at, "record data");
            const seconds = @as(i64, sec) + zone;
            const ns = timeFrom(@as(i128, seconds) * 1_000_000_000 + @as(i128, frac) * (if (result.nanosecond) @as(i128, 1) else 1000));
            if (ns == null) result.time_overflow += 1;
            if (!try self.add(result, .{ .offset = @intCast(at + 16), .caplen = caplen, .origlen = origlen, .interface = 0, .block_offset = @intCast(at), .block = .pcap_record, .time_known = ns != null, .time_ns = ns orelse 0 })) return;
            result.blocks += 1;
            at += 16 + caplen;
        }
    }

    fn pcapng(self: *Parser, result: *Result) !void {
        const b = self.bytes;
        var endian: std.builtin.Endian = .little;
        var section_first: usize = 0;
        var at: usize = 0;
        while (at < b.len) {
            if (b.len - at < 12) return halt(result, .truncated, at, "block header");
            const raw_type = std.mem.readInt(u32, b[at..][0..4], .little);
            if (raw_type == pcapng_shb) {
                const order = b[at + 8 ..][0..4];
                if (std.mem.readInt(u32, order, .little) == byte_order_magic) {
                    endian = .little;
                } else if (std.mem.readInt(u32, order, .big) == byte_order_magic) {
                    endian = .big;
                } else return halt(result, .corrupt, at, "section byte-order magic");
                if (result.sections == 0) result.big_endian = endian == .big;
            } else if (result.sections == 0) return halt(result, .corrupt, at, "first block is not a section header");
            const kind = std.mem.readInt(u32, b[at..][0..4], endian);
            const length = std.mem.readInt(u32, b[at + 4 ..][0..4], endian);
            if (length < 12 or length % 4 != 0) return halt(result, .corrupt, at, "block length");
            if (length > b.len - at) return halt(result, .truncated, at, "block body");
            if (std.mem.readInt(u32, b[at + length - 4 ..][0..4], endian) != length) return halt(result, .corrupt, at, "block trailer");
            const body = b[at + 8 .. at + length - 4];
            result.blocks += 1;
            switch (kind) {
                pcapng_shb => {
                    if (body.len < 16) return halt(result, .corrupt, at, "section header");
                    if (std.mem.readInt(u16, body[4..6], endian) != 1) return halt(result, .corrupt, at, "section major version");
                    result.sections += 1;
                    section_first = self.interfaces.items.len;
                },
                1 => {
                    if (body.len < 8) return halt(result, .corrupt, at, "interface description");
                    if (self.interfaces.items.len >= max_interfaces) return halt(result, .limit, at, "interface limit");
                    var iface = Interface{ .link_type = std.mem.readInt(u16, body[0..2], endian), .snaplen = std.mem.readInt(u32, body[4..8], endian), .section = result.sections - 1, .big_endian = endian == .big };
                    var options = Options{ .bytes = body[8..], .endian = endian };
                    while (options.next()) |o| switch (o.code) {
                        2 => iface.name = o.value,
                        9 => if (o.value.len >= 1) {
                            iface.tsresol = o.value[0];
                        },
                        14 => if (o.value.len >= 8) {
                            iface.tsoffset_s = std.mem.readInt(i64, o.value[0..8], endian);
                        },
                        else => {},
                    };
                    if (options.bad) result.bad_options += 1;
                    try self.interfaces.append(self.a, iface);
                },
                6, 2 => {
                    // EPB: u32 interface; PB: u16 interface, u16 drops.
                    if (body.len < 20) return halt(result, .corrupt, at, "packet block");
                    const id: u32 = if (kind == 6) std.mem.readInt(u32, body[0..4], endian) else std.mem.readInt(u16, body[0..2], endian);
                    const caplen = std.mem.readInt(u32, body[12..16], endian);
                    const origlen = std.mem.readInt(u32, body[16..20], endian);
                    if (caplen > body.len - 20) return halt(result, .corrupt, at, "captured length exceeds block");
                    const index = section_first + id;
                    if (index >= self.interfaces.items.len) {
                        result.orphan_records += 1;
                    } else {
                        const iface = &self.interfaces.items[index];
                        if (kind == 2) iface.epb_drops += std.mem.readInt(u16, body[2..4], endian);
                        const units = (@as(u64, std.mem.readInt(u32, body[4..8], endian)) << 32) | std.mem.readInt(u32, body[8..12], endian);
                        const ns = scale(units, iface.tsresol, iface.tsoffset_s);
                        if (ns == null) result.time_overflow += 1;
                        var options = Options{ .bytes = if (pad4(caplen) > body.len - 20) &.{} else body[20 + pad4(caplen) ..], .endian = endian };
                        while (options.next()) |o| if (kind == 6 and o.code == 4 and o.value.len >= 8) {
                            iface.epb_drops +|= std.mem.readInt(u64, o.value[0..8], endian);
                        };
                        if (options.bad) result.bad_options += 1;
                        if (!try self.add(result, .{ .offset = @intCast(at + 28), .caplen = caplen, .origlen = origlen, .interface = @intCast(index), .block_offset = @intCast(at), .block = if (kind == 6) .epb else .pb, .time_known = ns != null, .time_ns = ns orelse 0 })) return;
                    }
                },
                3 => {
                    if (body.len < 4) return halt(result, .corrupt, at, "simple packet block");
                    if (section_first >= self.interfaces.items.len) {
                        result.orphan_records += 1;
                    } else {
                        const origlen = std.mem.readInt(u32, body[0..4], endian);
                        const iface = self.interfaces.items[section_first];
                        var caplen: u32 = @intCast(body.len - 4);
                        caplen = @min(caplen, origlen);
                        if (iface.snaplen != 0) caplen = @min(caplen, iface.snaplen);
                        if (!try self.add(result, .{ .offset = @intCast(at + 12), .caplen = caplen, .origlen = origlen, .interface = @intCast(section_first), .block_offset = @intCast(at), .block = .spb, .time_known = false, .time_ns = 0 })) return;
                    }
                },
                5 => {
                    if (body.len < 12) return halt(result, .corrupt, at, "interface statistics");
                    const index = section_first + std.mem.readInt(u32, body[0..4], endian);
                    if (index >= self.interfaces.items.len) {
                        result.orphan_records += 1;
                    } else {
                        const iface = &self.interfaces.items[index];
                        iface.isb_count += 1;
                        var options = Options{ .bytes = body[12..], .endian = endian };
                        while (options.next()) |o| if (o.value.len >= 8) {
                            const v = std.mem.readInt(u64, o.value[0..8], endian);
                            switch (o.code) {
                                4 => iface.isb_ifrecv = v,
                                5 => iface.isb_ifdrop = v,
                                7 => iface.isb_osdrop = v,
                                else => {},
                            }
                        };
                        if (options.bad) result.bad_options += 1;
                    }
                },
                else => result.unknown_blocks += 1,
            }
            at += length;
        }
    }
};

fn pad4(n: u32) usize {
    return (@as(usize, n) + 3) & ~@as(usize, 3);
}

const Option = struct { code: u16, value: []const u8 };
const Options = struct {
    bytes: []const u8,
    endian: std.builtin.Endian,
    bad: bool = false,
    fn next(self: *Options) ?Option {
        if (self.bytes.len < 4) return null;
        const code = std.mem.readInt(u16, self.bytes[0..2], self.endian);
        const len = std.mem.readInt(u16, self.bytes[2..4], self.endian);
        if (code == 0) return null;
        if (pad4(len) > self.bytes.len - 4) {
            self.bad = true;
            return null;
        }
        const value = self.bytes[4..][0..len];
        self.bytes = self.bytes[4 + pad4(len) ..];
        return .{ .code = code, .value = value };
    }
};

fn timeFrom(ns: i128) ?u64 {
    if (ns < 0 or ns > std.math.maxInt(u64)) return null;
    return @intCast(ns);
}

/// Timestamp units to nanoseconds since the epoch: if_tsresol bit 7 clear is
/// 10^-n seconds, set is 2^-n seconds; if_tsoffset seconds are added.
pub fn scale(units: u64, tsresol: u8, offset_s: i64) ?u64 {
    const n: u32 = tsresol & 0x7f;
    var ns: i128 = undefined;
    if (tsresol & 0x80 == 0) {
        if (n > 38) return null;
        const p = std.math.powi(i128, 10, @as(i128, @intCast(if (n > 9) n - 9 else 9 - n))) catch return null;
        ns = if (n <= 9) @as(i128, units) * p else @divTrunc(@as(i128, units), p);
    } else {
        if (n > 127) return null;
        const wide = @as(u256, units) * 1_000_000_000;
        ns = @intCast(wide >> @intCast(n));
    }
    return timeFrom(ns + @as(i128, offset_s) * 1_000_000_000);
}

// ---------------------------------------------------------------- tests

/// Test writer: builds pcapng blocks in either byte order.
pub const TestWriter = struct {
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    endian: std.builtin.Endian = .little,

    pub fn deinit(self: *TestWriter) void {
        self.out.deinit(self.a);
    }
    fn int(self: *TestWriter, comptime T: type, v: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, v, self.endian);
        try self.out.appendSlice(self.a, &buf);
    }
    fn padTo4(self: *TestWriter) !void {
        while (self.out.items.len % 4 != 0) try self.out.append(self.a, 0);
    }
    fn begin(self: *TestWriter, kind: u32) !usize {
        const start = self.out.items.len;
        try self.int(u32, kind);
        try self.int(u32, 0);
        return start;
    }
    fn end(self: *TestWriter, start: usize) !void {
        try self.padTo4();
        const length: u32 = @intCast(self.out.items.len - start + 4);
        try self.int(u32, length);
        std.mem.writeInt(u32, self.out.items[start + 4 ..][0..4], length, self.endian);
    }
    fn option(self: *TestWriter, code: u16, value: []const u8) !void {
        try self.int(u16, code);
        try self.int(u16, @intCast(value.len));
        try self.out.appendSlice(self.a, value);
        try self.padTo4();
    }
    pub fn shb(self: *TestWriter) !void {
        const s = try self.begin(pcapng_shb);
        try self.int(u32, byte_order_magic);
        try self.int(u16, 1);
        try self.int(u16, 0);
        try self.int(i64, -1);
        try self.end(s);
    }
    pub fn idb(self: *TestWriter, link: u16, tsresol: ?u8, name: []const u8) !void {
        const s = try self.begin(1);
        try self.int(u16, link);
        try self.int(u16, 0);
        try self.int(u32, 65535);
        if (name.len > 0) try self.option(2, name);
        if (tsresol) |r| try self.option(9, &.{r});
        if (name.len > 0 or tsresol != null) try self.int(u32, 0);
        try self.end(s);
    }
    pub fn epb(self: *TestWriter, iface: u32, units: u64, data_: []const u8, origlen: u32, drops: ?u64) !void {
        const s = try self.begin(6);
        try self.int(u32, iface);
        try self.int(u32, @intCast(units >> 32));
        try self.int(u32, @truncate(units));
        try self.int(u32, @intCast(data_.len));
        try self.int(u32, origlen);
        try self.out.appendSlice(self.a, data_);
        try self.padTo4();
        if (drops) |d| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, d, self.endian);
            try self.option(4, &buf);
            try self.int(u32, 0);
        }
        try self.end(s);
    }
    pub fn spb(self: *TestWriter, data_: []const u8) !void {
        const s = try self.begin(3);
        try self.int(u32, @intCast(data_.len));
        try self.out.appendSlice(self.a, data_);
        try self.end(s);
    }
    pub fn isb(self: *TestWriter, iface: u32, ifdrop: u64, osdrop: u64) !void {
        const s = try self.begin(5);
        try self.int(u32, iface);
        try self.int(u32, 0);
        try self.int(u32, 0);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, ifdrop, self.endian);
        try self.option(5, &buf);
        std.mem.writeInt(u64, &buf, osdrop, self.endian);
        try self.option(7, &buf);
        try self.int(u32, 0);
        try self.end(s);
    }
    pub fn unknown(self: *TestWriter, kind: u32) !void {
        const s = try self.begin(kind);
        try self.int(u32, 0x01020304);
        try self.end(s);
    }
};

test "pcapng blocks in both byte orders" {
    const a = std.testing.allocator;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| {
        var w = TestWriter{ .a = a, .endian = endian };
        defer w.deinit();
        try w.shb();
        try w.idb(1, null, "lo");
        try w.idb(101, 9, "");
        try w.epb(0, 1_700_000_000_000_001, "abcdef", 6, 3);
        try w.epb(1, 1_700_000_000_000_000_007, "xyz", 40, null);
        try w.spb("simple");
        try w.isb(0, 5, 2);
        try w.unknown(0x40000bad);
        var r = try parse(a, w.out.items, .{});
        defer r.deinit(a);
        try std.testing.expectEqual(Format.pcapng, r.format);
        try std.testing.expectEqual(endian == .big, r.big_endian);
        try std.testing.expectEqual(Stop.complete, r.stop);
        try std.testing.expectEqual(@as(usize, 2), r.interfaces.len);
        try std.testing.expectEqualStrings("lo", r.interfaces[0].name);
        try std.testing.expectEqual(@as(usize, 3), r.records.len);
        try std.testing.expectEqual(@as(u64, 1_700_000_000_000_001_000), r.records[0].time_ns);
        try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_007), r.records[1].time_ns);
        try std.testing.expectEqualStrings("abcdef", r.data(w.out.items, 0));
        try std.testing.expectEqualStrings("xyz", r.data(w.out.items, 1));
        try std.testing.expectEqual(@as(u32, 40), r.records[1].origlen);
        try std.testing.expectEqual(@as(u64, 1), r.interfaces[1].truncated_packets);
        try std.testing.expect(!r.records[2].time_known);
        try std.testing.expectEqualStrings("simple", r.data(w.out.items, 2));
        try std.testing.expectEqual(@as(u64, 3), r.interfaces[0].epb_drops);
        try std.testing.expectEqual(@as(?u64, 5), r.interfaces[0].isb_ifdrop);
        try std.testing.expectEqual(@as(?u64, 2), r.interfaces[0].isb_osdrop);
        try std.testing.expectEqual(@as(u64, 1), r.unknown_blocks);
    }
}

test "pcapng sections reset interfaces, binary resolution, orphan records" {
    const a = std.testing.allocator;
    var w = TestWriter{ .a = a };
    defer w.deinit();
    try w.shb();
    try w.idb(1, 0x80 | 10, "");
    try w.epb(0, 1024 * 5, "a", 1, null); // 5 seconds in 2^-10 units
    try w.shb();
    try w.idb(113, null, "");
    try w.epb(0, 7, "b", 1, null);
    try w.epb(3, 7, "c", 1, null);
    var r = try parse(a, w.out.items, .{});
    defer r.deinit(a);
    try std.testing.expectEqual(@as(u32, 2), r.sections);
    try std.testing.expectEqual(@as(usize, 2), r.records.len);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), r.records[0].time_ns);
    try std.testing.expectEqual(@as(u32, 1), r.records[1].interface);
    try std.testing.expectEqual(@as(u64, 7000), r.records[1].time_ns);
    try std.testing.expectEqual(@as(u64, 1), r.orphan_records);
}

test "pcapng truncation and corruption keep earlier records" {
    const a = std.testing.allocator;
    var w = TestWriter{ .a = a };
    defer w.deinit();
    try w.shb();
    try w.idb(1, null, "");
    try w.epb(0, 1, "first", 5, null);
    const good = w.out.items.len;
    try w.epb(0, 2, "second", 6, null);
    // Every cut inside the second block keeps the first record and says truncated.
    for (good + 1..w.out.items.len) |cut| {
        var r = try parse(a, w.out.items[0..cut], .{});
        defer r.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), r.records.len);
        try std.testing.expectEqual(Stop.truncated, r.stop);
        try std.testing.expectEqual(@as(u64, good), r.stop_offset);
    }
    // A bad trailer is corruption.
    const copy = try a.dupe(u8, w.out.items);
    defer a.free(copy);
    copy[copy.len - 1] ^= 0xff;
    var r = try parse(a, copy, .{});
    defer r.deinit(a);
    try std.testing.expectEqual(Stop.corrupt, r.stop);
    try std.testing.expectEqual(@as(usize, 1), r.records.len);
    // A captured length past the block is corruption, not an out-of-bounds read.
    const copy2 = try a.dupe(u8, w.out.items);
    defer a.free(copy2);
    std.mem.writeInt(u32, copy2[good + 20 ..][0..4], 9999, .little);
    var r2 = try parse(a, copy2, .{});
    defer r2.deinit(a);
    try std.testing.expectEqual(Stop.corrupt, r2.stop);
    // Every single-byte corruption of the whole file is a typed result.
    for (0..w.out.items.len) |i| {
        const flip = try a.dupe(u8, w.out.items);
        defer a.free(flip);
        flip[i] ^= 0x5a;
        var any = parse(a, flip, .{}) catch |err| {
            try std.testing.expectEqual(error.NotACapture, err);
            continue;
        };
        any.deinit(a);
    }
}

test "pcap in both byte orders and resolutions" {
    const a = std.testing.allocator;
    for ([_]std.builtin.Endian{ .little, .big }) |endian| for ([_]u32{ pcap_us, pcap_ns }) |magic| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        var buf: [4]u8 = undefined;
        const fields = [_]u32{ magic, 2 | (4 << 16), 0, 0, 65535, 1 };
        for (fields, 0..) |v, i| {
            if (i == 1) {
                var h: [2]u8 = undefined;
                std.mem.writeInt(u16, &h, 2, endian);
                try out.appendSlice(a, &h);
                std.mem.writeInt(u16, &h, 4, endian);
                try out.appendSlice(a, &h);
                continue;
            }
            std.mem.writeInt(u32, &buf, v, endian);
            try out.appendSlice(a, &buf);
        }
        for ([_]u32{ 1_700_000_000, 123, 4, 60 }) |v| {
            std.mem.writeInt(u32, &buf, v, endian);
            try out.appendSlice(a, &buf);
        }
        try out.appendSlice(a, "pkt!");
        var r = try parse(a, out.items, .{});
        defer r.deinit(a);
        try std.testing.expectEqual(Format.pcap, r.format);
        try std.testing.expectEqual(Stop.complete, r.stop);
        try std.testing.expectEqual(@as(usize, 1), r.records.len);
        const frac: u64 = if (magic == pcap_ns) 123 else 123_000;
        try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_000 + frac), r.records[0].time_ns);
        try std.testing.expectEqualStrings("pkt!", r.data(out.items, 0));
        var t = try parse(a, out.items[0 .. out.items.len - 1], .{});
        defer t.deinit(a);
        try std.testing.expectEqual(Stop.truncated, t.stop);
        try std.testing.expectEqual(@as(usize, 0), t.records.len);
    };
    try std.testing.expectError(error.NotACapture, parse(a, "GIF89a..", .{}));
}

test "record limit stops with a typed result" {
    const a = std.testing.allocator;
    var w = TestWriter{ .a = a };
    defer w.deinit();
    try w.shb();
    try w.idb(1, null, "");
    for (0..5) |i| try w.epb(0, i, "x", 1, null);
    var r = try parse(a, w.out.items, .{ .max_records = 3 });
    defer r.deinit(a);
    try std.testing.expectEqual(Stop.limit, r.stop);
    try std.testing.expectEqual(@as(usize, 3), r.records.len);
}
