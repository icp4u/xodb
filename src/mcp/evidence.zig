//! MCP tools over external evidence streams (src/evidence): list_streams,
//! query_stream, correlate. Read-only; the stream is opened at startup.
const std = @import("std");
const evidence = @import("../evidence/stream.zig");
const decode = evidence.decode;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "list_streams", "query_stream", "correlate" }) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

fn value(a: Allocator, object: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(a, object, .{});
    return (try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn fields(args: Value, allowed: []const []const u8) !void {
    var it = args.object.iterator();
    while (it.next()) |entry| {
        // The server routes by process_id; evidence belongs to the root session.
        if (std.mem.eql(u8, entry.key_ptr.*, "process_id")) continue;
        for (allowed) |key| {
            if (std.mem.eql(u8, key, entry.key_ptr.*)) break;
        } else return error.InvalidArguments;
    }
}
fn number(args: Value, key: []const u8) !?u64 {
    const v = args.object.get(key) orelse return null;
    if (v != .integer or v.integer < 0) return error.InvalidArguments;
    return @intCast(v.integer);
}
fn boolean(args: Value, key: []const u8) !?bool {
    const v = args.object.get(key) orelse return null;
    if (v != .bool) return error.InvalidArguments;
    return v.bool;
}
fn stream(session_stream: ?*evidence.Stream, args: Value) !*evidence.Stream {
    const s = session_stream orelse return error.NoEvidenceStream;
    if ((try number(args, "stream_id") orelse 1) != s.id) return error.UnknownStream;
    return s;
}

pub fn call(a: Allocator, session_stream: ?*evidence.Stream, name: []const u8, args: Value) !Value {
    if (std.mem.eql(u8, name, "list_streams")) {
        try fields(args, &.{});
        var list = std.json.Array.init(a);
        if (session_stream) |s| try list.append(try describe(a, s));
        var out = Value{ .object = .empty };
        try out.object.put(a, "streams", .{ .array = list });
        return out;
    }
    if (std.mem.eql(u8, name, "query_stream")) {
        try fields(args, &.{ "stream_id", "clock", "from_ns", "to_ns", "flow_id", "interface", "protocol", "port", "undecoded", "include_raw", "flows", "start", "limit" });
        const s = try stream(session_stream, args);
        var filter = evidence.Stream.Filter{ .from_ns = try number(args, "from_ns"), .to_ns = try number(args, "to_ns"), .undecoded = try boolean(args, "undecoded") };
        if (args.object.get("clock")) |v| {
            if (v != .string) return error.InvalidArguments;
            filter.clock = std.meta.stringToEnum(evidence.Stream.Clock, v.string) orelse return error.InvalidArguments;
        }
        if (try number(args, "flow_id")) |v| filter.flow = std.math.cast(u32, v) orelse return error.InvalidArguments;
        if (try number(args, "interface")) |v| filter.interface = std.math.cast(u32, v) orelse return error.InvalidArguments;
        if (try number(args, "port")) |v| filter.port = std.math.cast(u16, v) orelse return error.InvalidArguments;
        if (args.object.get("protocol")) |v| {
            if (v != .string) return error.InvalidArguments;
            const table = [_]struct { []const u8, u8 }{ .{ "tcp", 6 }, .{ "udp", 17 }, .{ "icmp", 1 }, .{ "icmpv6", 58 } };
            for (table) |entry| {
                if (std.mem.eql(u8, entry[0], v.string)) filter.protocol = entry[1];
            }
            if (filter.protocol == null) return error.InvalidArguments;
        }
        const include_raw = try boolean(args, "include_raw") orelse false;
        // Payload bytes cannot be redacted, only withheld.
        if (include_raw and @import("../redact.zig").active() != null) return error.RawPayloadRedacted;
        const limit = try number(args, "limit") orelse 64;
        if (limit == 0 or limit > 256) return error.InvalidArguments;
        const start = try number(args, "start") orelse 0;
        const n = s.parsed.records.len;
        var rows = std.json.Array.init(a);
        var i: usize = @min(start, n);
        var next: ?usize = null;
        while (i < n) : (i += 1) {
            if (!s.matches(i, filter)) continue;
            if (rows.items.len == limit) {
                next = i;
                break;
            }
            try rows.append(try record(a, s, i, include_raw));
        }
        var out = Value{ .object = .empty };
        try out.object.put(a, "stream_id", .{ .integer = s.id });
        try out.object.put(a, "records", .{ .array = rows });
        try out.object.put(a, "next", if (next) |v| .{ .integer = @intCast(v) } else .null);
        try out.object.put(a, "total_records", .{ .integer = @intCast(n) });
        if (try boolean(args, "flows") orelse false) {
            var flows = std.json.Array.init(a);
            for (s.flows[@min(start, s.flows.len)..@min(s.flows.len, start + limit)], @min(start, s.flows.len)..) |f, id| {
                var text: [2][64]u8 = undefined;
                try flows.append(try value(a, .{ .flow_id = id, .protocol = decode.protocolName(f.key.protocol), .family = @tagName(f.key.family), .a = decode.formatAddress(&text[0], f.key.family, f.key.src), .a_port = f.key.src_port, .b = decode.formatAddress(&text[1], f.key.family, f.key.dst), .b_port = f.key.dst_port, .packets = f.packets, .bytes = f.bytes, .first_record = f.first, .last_record = f.last }));
            }
            try out.object.put(a, "flows", .{ .array = flows });
        }
        return out;
    }
    if (std.mem.eql(u8, name, "correlate")) {
        try fields(args, &.{ "stream_id", "record" });
        const s = try stream(session_stream, args);
        const index = try number(args, "record") orelse return error.InvalidArguments;
        if (index >= s.parsed.records.len) return error.UnknownRecord;
        const i: usize = @intCast(index);
        const join = s.correlate(i);
        var out = Value{ .object = .empty };
        try out.object.put(a, "stream_id", .{ .integer = s.id });
        try out.object.put(a, "record", try record(a, s, i, false));
        try out.object.put(a, "basis", .{ .string = @tagName(join.basis) });
        try out.object.put(a, "reason", .{ .string = join.reason });
        try out.object.put(a, "direction", if (join.socket == null) .null else .{ .string = if (join.outbound) "outbound" else "inbound" });
        if (join.process) |p| {
            try out.object.put(a, "process", try value(a, .{ .pid = p.pid, .comm = std.mem.sliceTo(&p.comm, 0) }));
        } else try out.object.put(a, "process", if (join.socket) |sock| try value(a, .{ .pid = sock.pid, .comm = @as(?[]const u8, null) }) else .null);
        if (join.socket) |sock| {
            var text: [2][64]u8 = undefined;
            try out.object.put(a, "socket", try value(a, .{ .fd = sock.fd, .inode = sock.inode, .protocol = @tagName(sock.protocol), .family = @tagName(sock.family), .local = evidence.sockets.formatEnd(&text[0], sock.family, sock.local, sock.local_tagged), .local_port = sock.local_port, .remote = evidence.sockets.formatEnd(&text[1], sock.family, sock.remote, sock.remote_tagged), .remote_port = sock.remote_port, .state = sock.state }));
            const table = s.context.?.tables[join.table.?];
            try out.object.put(a, "table", try value(a, .{ .when = @tagName(table.when), .sampled_ns = table.sampled_ns }));
        } else {
            try out.object.put(a, "socket", .null);
            try out.object.put(a, "table", .null);
        }
        try out.object.put(a, "thread", .null);
        try out.object.put(a, "thread_reason", .{ .string = "socket tables name the process, not the thread; thread attribution needs syscall/fd-flow evidence (not joined in this version)" });
        return out;
    }
    return error.UnknownTool;
}

fn describe(a: Allocator, s: *evidence.Stream) !Value {
    var interfaces = std.json.Array.init(a);
    for (s.parsed.interfaces, 0..) |iface, id| try interfaces.append(try value(a, .{
        .interface = id,
        .section = iface.section,
        .link_type = iface.link_type,
        .link = linkName(iface.link_type),
        // A file's bytes are not always UTF-8; JSON would turn them into a number array.
        .name = if (std.unicode.utf8ValidateSlice(iface.name)) @as(?[]const u8, iface.name) else null,
        .snaplen = iface.snaplen,
        .tsresol = iface.tsresol,
        .tsoffset_s = iface.tsoffset_s,
        .packets = iface.packets,
        .truncated_packets = iface.truncated_packets,
        .epb_drops = iface.epb_drops,
        .isb_ifrecv = iface.isb_ifrecv,
        .isb_ifdrop = iface.isb_ifdrop,
        .isb_osdrop = iface.isb_osdrop,
        .isb_count = iface.isb_count,
    }));
    const loss = s.loss();
    const m = s.mapping;
    var tables = std.json.Array.init(a);
    if (s.context) |ctx| for (ctx.tables) |t| try tables.append(try value(a, .{ .when = @tagName(t.when), .sampled_ns = t.sampled_ns, .sockets = t.sockets.len, .unreadable = t.unreadable, .truncated = t.truncated }));
    var out = try value(a, .{
        .stream_id = s.id,
        .kind = @tagName(s.kind),
        .label = if (std.unicode.utf8ValidateSlice(s.label)) @as(?[]const u8, s.label) else null,
        .format = @tagName(s.parsed.format),
        .byte_order = if (s.parsed.big_endian) "big" else "little",
        .sections = s.parsed.sections,
        .records = s.parsed.records.len,
        .undecoded = s.undecoded,
        .flows = s.flows.len,
        .flows_dropped = s.flows_dropped,
        .decoder = .{ .name = decode.decoder, .version = decode.decoder_version },
        .file = .{ .bytes = s.bytes.len, .stop = @tagName(s.parsed.stop), .stop_offset = s.parsed.stop_offset, .stop_reason = s.parsed.stop_reason, .blocks = s.parsed.blocks, .unknown_blocks = s.parsed.unknown_blocks, .orphan_records = s.parsed.orphan_records, .bad_options = s.parsed.bad_options, .time_overflow = s.parsed.time_overflow },
        .loss = .{ .epb_drops = loss.epb_drops, .isb_ifdrop = loss.isb_ifdrop, .isb_osdrop = loss.isb_osdrop, .truncated_packets = loss.truncated_packets, .orphan_records = loss.orphan_records, .file_stop = @tagName(loss.file_stop) },
        .time_range = .{ .first_ns = s.first_time_ns, .last_ns = s.last_time_ns },
        .clock = .{
            .domain = @tagName(s.domain),
            .declared_by = "pcap/pcapng file format: seconds since the Unix epoch (CLOCK_REALTIME of the capturing host)",
            .mapping = .{ .state = @tagName(m.state), .to = "CLOCK_MONOTONIC of the opened capture archive", .offset_ns = if (m.state == .aligned) std.math.cast(i64, m.offset_ns) else null, .uncertainty_ns = if (m.state == .aligned) @as(?u64, m.uncertainty_ns) else null, .pairs = m.pairs, .spread_ns = m.spread_ns, .reason = m.reason },
        },
        .context = .{ .present = s.context != null, .redacted = if (s.context) |ctx| ctx.redacted else false, .capture_pid = if (s.context) |ctx| @as(?i32, ctx.pid) else null, .capture_started_ns = if (s.context) |ctx| @as(?u64, ctx.capture_started_ns) else null },
    });
    try out.object.put(a, "interfaces", .{ .array = interfaces });
    try out.object.getPtr("context").?.object.put(a, "tables", .{ .array = tables });
    return out;
}

pub fn linkName(link: u16) []const u8 {
    return switch (link) {
        decode.link_null => "null_loopback",
        decode.link_ethernet => "ethernet",
        decode.link_raw, decode.link_ipv4, decode.link_ipv6 => "raw_ip",
        decode.link_sll => "linux_sll",
        decode.link_sll2 => "linux_sll2",
        else => "unknown",
    };
}

fn record(a: Allocator, s: *const evidence.Stream, i: usize, include_raw: bool) !Value {
    const r = s.parsed.records[i];
    const sum = &s.summaries[i];
    const t = s.timeOf(i);
    var text: [2][64]u8 = undefined;
    var out = try value(a, .{
        .index = i,
        .interface = r.interface,
        .block = @tagName(r.block),
        .time = .{ .known = t.known, .clock = "realtime", .stream_ns = if (t.known) @as(?u64, t.stream_ns) else null, .capture_ns = t.capture_ns, .monotonic_ns = t.monotonic_ns, .uncertainty_ns = t.uncertainty_ns },
        .caplen = r.caplen,
        .origlen = r.origlen,
        .raw = .{ .offset = r.offset, .length = r.caplen },
        .flow_id = s.flow_of[i],
        .layer = @tagName(sum.layer),
        .undecoded = if (sum.undecoded()) @as(?[]const u8, @tagName(sum.reason)) else null,
        .decoded = .{
            .link = @tagName(sum.link),
            .ether_type = sum.ether_type,
            .vlans = sum.vlans[0..sum.vlan_count],
            .family = @tagName(sum.family),
            .src = decode.formatAddress(&text[0], sum.family, sum.src),
            .dst = decode.formatAddress(&text[1], sum.family, sum.dst),
            .protocol = if (sum.layer == .transport or sum.family != .none) @as(?[]const u8, decode.protocolName(sum.protocol)) else null,
            .ip_protocol = sum.protocol,
            .src_port = if (sum.hasPorts()) @as(?u16, sum.src_port) else null,
            .dst_port = if (sum.hasPorts()) @as(?u16, sum.dst_port) else null,
            .tcp_flags = if (sum.layer == .transport and sum.protocol == 6) @as(?u8, sum.tcp_flags) else null,
            .seq = if (sum.layer == .transport and sum.protocol == 6) @as(?u32, sum.seq) else null,
            .ack = if (sum.layer == .transport and sum.protocol == 6) @as(?u32, sum.ack) else null,
            .icmp_type = if (sum.layer == .transport and (sum.protocol == 1 or sum.protocol == 58)) @as(?u8, sum.icmp_type) else null,
            .icmp_code = if (sum.layer == .transport and (sum.protocol == 1 or sum.protocol == 58)) @as(?u8, sum.icmp_code) else null,
            .payload_length = sum.payload_length,
            .payload_captured = sum.payload_captured,
            .fragment = sum.fragment,
            .extension_headers = sum.extension_headers,
        },
    });
    if (include_raw) {
        const bytes = s.raw(i);
        const shown = bytes[0..@min(bytes.len, 256)];
        const hex = try a.alloc(u8, shown.len * 2);
        const digits = "0123456789abcdef";
        for (shown, 0..) |b, k| {
            hex[k * 2] = digits[b >> 4];
            hex[k * 2 + 1] = digits[b & 15];
        }
        try out.object.put(a, "raw_hex", .{ .string = hex });
    }
    return out;
}
