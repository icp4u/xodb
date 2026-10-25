//! Bounded offline Linux usbmon decoding over X1's pcap/pcapng reader.
//! No device is opened here: records and descriptor bytes remain borrowed
//! from the immutable parent stream.
const std = @import("std");
const evidence = @import("stream.zig");
const sockets = @import("sockets.zig");

pub const decoder = "xodb-usbmon";
pub const decoder_version: u32 = 1;
pub const link_usb_linux: u16 = 189;
pub const link_usb_linux_mmapped: u16 = 220;
pub const stream_id: u32 = 4;
pub const max_records: usize = 1_048_576;
pub const max_descriptors_per_record: usize = 256;
pub const max_devices: usize = 4096;
pub const max_endpoints: usize = 65_536;
/// Decoded descriptors kept for the whole stream (~64 bytes each). Two input
/// bytes can make one descriptor, so a per-record cap alone is not enough.
pub const max_total_descriptors: usize = 2 * 1024 * 1024;

pub const Event = enum { submit, complete, error_event, unknown };
pub const Transfer = enum { isochronous, interrupt, control, bulk, unknown };
pub const Direction = enum { out, in };
pub const Reason = enum {
    none,
    truncated_header,
    invalid_event,
    invalid_transfer,
    truncated_iso_descriptors,
    truncated_data,
    malformed_descriptor,
    descriptor_limit,
};

pub const Setup = struct {
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
};

pub const DescriptorKind = enum { device, configuration, string, interface, endpoint, hid, cdc_functional, unknown };
pub const Descriptor = struct {
    kind: DescriptorKind,
    descriptor_type: u8,
    length: u8,
    vendor_id: ?u16 = null,
    product_id: ?u16 = null,
    device_class: ?u8 = null,
    configuration_value: ?u8 = null,
    interface_number: ?u8 = null,
    alternate_setting: ?u8 = null,
    class_code: ?u8 = null,
    subclass: ?u8 = null,
    protocol: ?u8 = null,
    endpoint_address: ?u8 = null,
    attributes: ?u8 = null,
    max_packet_size: ?u16 = null,
    interval: ?u8 = null,
    cdc_subtype: ?u8 = null,
    text: ?[]const u8 = null,
};

pub const Record = struct {
    source_record: u32,
    time_ns: ?u64,
    urb_id: u64 = 0,
    event: Event = .unknown,
    transfer: Transfer = .unknown,
    direction: Direction = .out,
    endpoint: u8 = 0,
    device: u8 = 0,
    bus: u16 = 0,
    status: i32 = 0,
    requested_length: u32 = 0,
    captured_length: u32 = 0,
    setup: ?Setup = null,
    peer_record: ?u32 = null,
    latency_ns: ?u64 = null,
    data: []const u8 = &.{},
    descriptors: []const Descriptor = &.{},
    reason: Reason = .none,
};

pub const Device = struct {
    bus: u16,
    address: u8,
    first_record: u32,
    last_record: u32,
    transfers: u64 = 0,
    errors: u64 = 0,
    vendor_id: ?u16 = null,
    product_id: ?u16 = null,
    class_code: ?u8 = null,
    addressed_as: ?u8 = null,
};

pub const Endpoint = struct {
    bus: u16,
    device: u8,
    endpoint: u8,
    direction: Direction,
    transfer: Transfer,
    first_record: u32,
    last_record: u32,
    submits: u64 = 0,
    completions: u64 = 0,
    errors: u64 = 0,
    captured_bytes: u64 = 0,
};

pub const Loss = struct {
    pcap_ifdrop: u64,
    pcap_osdrop: u64,
    pcap_epb_drops: u64,
    pcap_truncated: u64,
    malformed: u64,
    orphan_completions: u64,
    unmatched_submits: u64,
    derived_dropped: u64,
};

pub const Stream = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    id: u32 = stream_id,
    parent: *evidence.Stream,
    label: []const u8,
    records: []Record,
    devices: []Device,
    endpoints: []Endpoint,
    malformed: u64 = 0,
    orphan_completions: u64 = 0,
    unmatched_submits: u64 = 0,
    derived_dropped: u64 = 0,

    pub fn open(a: std.mem.Allocator, parent: *evidence.Stream) !?*Stream {
        var compatible = false;
        for (parent.parsed.interfaces) |iface| if (iface.link_type == link_usb_linux or iface.link_type == link_usb_linux_mmapped) {
            compatible = true;
            break;
        };
        if (!compatible) return null;
        const self = try a.create(Stream);
        errdefer a.destroy(self);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(a), .backing = a, .parent = parent, .label = undefined, .records = &.{}, .devices = &.{}, .endpoints = &.{} };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.label = try std.fmt.allocPrint(arena, "USB: {s}", .{parent.label});
        var records: std.ArrayList(Record) = .empty;
        var pending: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        var devices: std.ArrayList(Device) = .empty;
        var device_index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        var endpoints: std.ArrayList(Endpoint) = .empty;
        var endpoint_index: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        var descriptor_budget: usize = max_total_descriptors;
        for (parent.parsed.records, 0..) |source, source_index| {
            const iface = parent.parsed.interfaces[source.interface];
            if (iface.link_type != link_usb_linux and iface.link_type != link_usb_linux_mmapped) continue;
            if (records.items.len == max_records) {
                self.derived_dropped += 1;
                continue;
            }
            var record = decodeRecord(parent.raw(source_index), iface.link_type, if (iface.big_endian) .big else .little);
            record.source_record = @intCast(source_index);
            const time = parent.timeOf(source_index);
            record.time_ns = if (time.known) time.stream_ns else null;
            if (record.event == .complete or record.event == .error_event) {
                if (pending.fetchRemove(record.urb_id)) |entry| {
                    const submit = &records.items[entry.value];
                    record.peer_record = entry.value;
                    submit.peer_record = @intCast(records.items.len);
                    record.setup = submit.setup;
                    if (submit.time_ns != null and record.time_ns != null and record.time_ns.? >= submit.time_ns.?) {
                        record.latency_ns = record.time_ns.? - submit.time_ns.?;
                        submit.latency_ns = record.latency_ns;
                    }
                } else self.orphan_completions += 1;
            }
            if (record.reason == .none and record.setup != null and record.data.len != 0 and record.setup.?.request == 6 and record.setup.?.request_type & 0x80 != 0) {
                if (descriptor_budget == 0) {
                    record.reason = .descriptor_limit;
                    self.derived_dropped += 1;
                } else {
                    record.descriptors = try parseDescriptors(arena, record.data, &record.reason, @min(max_descriptors_per_record, descriptor_budget));
                    descriptor_budget -= record.descriptors.len;
                }
            }
            if (record.reason != .none and record.reason != .descriptor_limit) self.malformed += 1;
            const record_index: u32 = @intCast(records.items.len);
            if (record.event == .submit) {
                if (try pending.fetchPut(arena, record.urb_id, record_index)) |_| self.unmatched_submits += 1;
            }
            if (record.reason != .truncated_header) try updateLifecycle(arena, &devices, &device_index, &endpoints, &endpoint_index, record_index, &record);
            try records.append(arena, record);
        }
        self.unmatched_submits += pending.count();
        self.records = records.items;
        self.devices = devices.items;
        self.endpoints = endpoints.items;
        return self;
    }

    pub fn destroy(self: *Stream) void {
        const a = self.backing;
        self.arena.deinit();
        a.destroy(self);
    }

    pub fn loss(self: *const Stream) Loss {
        const parent = self.parent.loss();
        return .{ .pcap_ifdrop = parent.isb_ifdrop, .pcap_osdrop = parent.isb_osdrop, .pcap_epb_drops = parent.epb_drops, .pcap_truncated = parent.truncated_packets, .malformed = self.malformed, .orphan_completions = self.orphan_completions, .unmatched_submits = self.unmatched_submits, .derived_dropped = self.derived_dropped };
    }

    pub fn correlate(self: *const Stream, index: usize) sockets.UsbJoin {
        const record = self.records[index];
        const ctx = switch (sockets.Context.joinPrecondition(
            &self.parent.context,
            .missing_usb_context,
            null,
        )) {
            .ready => |ctx| ctx,
            .unavailable => |refusal| return .{ .reason = refusal.render() },
        };
        return sockets.correlateUsb(ctx, record.bus, record.device, self.parent.timeOf(record.source_record).monotonic_ns);
    }
};

fn decodeRecord(bytes: []const u8, link: u16, endian: std.builtin.Endian) Record {
    var out = Record{ .source_record = 0, .time_ns = null };
    const header_len: usize = if (link == link_usb_linux_mmapped) 64 else 48;
    if (bytes.len < header_len) {
        out.reason = .truncated_header;
        return out;
    }
    out.urb_id = std.mem.readInt(u64, bytes[0..8], endian);
    out.event = switch (bytes[8]) {
        'S' => .submit,
        'C' => .complete,
        'E' => .error_event,
        else => .unknown,
    };
    if (out.event == .unknown) out.reason = .invalid_event;
    out.transfer = switch (bytes[9] & 0x7f) {
        0 => .isochronous,
        1 => .interrupt,
        2 => .control,
        3 => .bulk,
        else => .unknown,
    };
    if (out.transfer == .unknown and out.reason == .none) out.reason = .invalid_transfer;
    out.direction = if (bytes[10] & 0x80 != 0) .in else .out;
    out.endpoint = bytes[10] & 0x0f;
    out.device = bytes[11];
    out.bus = std.mem.readInt(u16, bytes[12..14], endian);
    out.status = std.mem.readInt(i32, bytes[28..32], endian);
    out.requested_length = std.mem.readInt(u32, bytes[32..36], endian);
    out.captured_length = std.mem.readInt(u32, bytes[36..40], endian);
    if (out.transfer == .control and bytes[14] == 0) out.setup = .{
        .request_type = bytes[40],
        .request = bytes[41],
        .value = std.mem.readInt(u16, bytes[42..44], .little),
        .index = std.mem.readInt(u16, bytes[44..46], .little),
        .length = std.mem.readInt(u16, bytes[46..48], .little),
    };
    var data_at = header_len;
    if (link == link_usb_linux_mmapped and out.transfer == .isochronous) {
        const count = std.mem.readInt(u32, bytes[60..64], endian);
        if (count > 128 or @as(usize, count) * 16 > bytes.len - data_at) {
            if (out.reason == .none) out.reason = .truncated_iso_descriptors;
            return out;
        }
        data_at += @as(usize, count) * 16;
    }
    const available = bytes.len - data_at;
    const captured = @min(available, out.captured_length);
    out.data = bytes[data_at..][0..captured];
    if (out.captured_length > available and out.reason == .none) out.reason = .truncated_data;
    return out;
}

fn parseDescriptors(a: std.mem.Allocator, data: []const u8, reason: *Reason, limit: usize) ![]const Descriptor {
    var list: std.ArrayList(Descriptor) = .empty;
    var at: usize = 0;
    while (at < data.len and list.items.len < limit) {
        if (data.len - at < 2 or data[at] < 2 or data[at] > data.len - at) {
            reason.* = .malformed_descriptor;
            break;
        }
        const bytes = data[at..][0..data[at]];
        var d = Descriptor{ .kind = descriptorKind(bytes[1]), .descriptor_type = bytes[1], .length = bytes[0] };
        switch (d.kind) {
            .device => if (bytes.len >= 18) {
                d.device_class = bytes[4];
                d.vendor_id = std.mem.readInt(u16, bytes[8..10], .little);
                d.product_id = std.mem.readInt(u16, bytes[10..12], .little);
            },
            .configuration => {
                if (bytes.len >= 9) d.configuration_value = bytes[5];
            },
            .string => {
                if (bytes.len >= 2) d.text = try stringDescriptor(a, bytes[2..]);
            },
            .interface => if (bytes.len >= 9) {
                d.interface_number = bytes[2];
                d.alternate_setting = bytes[3];
                d.class_code = bytes[5];
                d.subclass = bytes[6];
                d.protocol = bytes[7];
            },
            .endpoint => if (bytes.len >= 7) {
                d.endpoint_address = bytes[2];
                d.attributes = bytes[3];
                d.max_packet_size = std.mem.readInt(u16, bytes[4..6], .little);
                d.interval = bytes[6];
            },
            .cdc_functional => {
                if (bytes.len >= 3) d.cdc_subtype = bytes[2];
            },
            else => {},
        }
        try list.append(a, d);
        at += bytes.len;
    }
    if (at < data.len and list.items.len == limit) reason.* = if (limit == max_descriptors_per_record) .malformed_descriptor else .descriptor_limit;
    return list.items;
}

fn descriptorKind(value: u8) DescriptorKind {
    return switch (value) {
        1 => .device,
        2 => .configuration,
        3 => .string,
        4 => .interface,
        5 => .endpoint,
        0x21 => .hid,
        0x24, 0x25 => .cdc_functional,
        else => .unknown,
    };
}

fn stringDescriptor(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, bytes.len / 2);
    var used: usize = 0;
    var at: usize = 0;
    while (at + 1 < bytes.len) : (at += 2) {
        const value = std.mem.readInt(u16, bytes[at..][0..2], .little);
        out[used] = if (value >= 0x20 and value <= 0x7e) @intCast(value) else '?';
        used += 1;
    }
    return out[0..used];
}

fn className(code: u8, subclass: ?u8, protocol: ?u8) []const u8 {
    return switch (code) {
        2 => "cdc_control",
        3 => if (subclass == 1 and protocol == 1) "hid_keyboard" else if (subclass == 1 and protocol == 2) "hid_mouse" else "hid",
        8 => if (subclass == 6 and protocol == 0x50) "mass_storage_scsi_bulk_only" else "mass_storage",
        10 => "cdc_data",
        else => "other",
    };
}

pub fn descriptorClassName(d: Descriptor) ?[]const u8 {
    const code = d.class_code orelse d.device_class orelse return null;
    return className(code, d.subclass, d.protocol);
}

fn updateLifecycle(a: std.mem.Allocator, devices: *std.ArrayList(Device), device_index: *std.AutoHashMapUnmanaged(u32, u32), endpoints: *std.ArrayList(Endpoint), endpoint_index: *std.AutoHashMapUnmanaged(u64, u32), index: u32, record: *const Record) !void {
    const device_key = (@as(u32, record.bus) << 8) | record.device;
    const di = device_index.get(device_key) orelse blk: {
        if (devices.items.len == max_devices) break :blk null;
        const value: u32 = @intCast(devices.items.len);
        try device_index.put(a, device_key, value);
        try devices.append(a, .{ .bus = record.bus, .address = record.device, .first_record = index, .last_record = index });
        break :blk value;
    };
    if (di) |value| {
        const device = &devices.items[value];
        device.last_record = index;
        device.transfers += 1;
        if (record.event == .error_event or record.status != 0) device.errors += 1;
        if (record.setup) |setup| {
            if (setup.request_type == 0 and setup.request == 5) device.addressed_as = @truncate(setup.value);
        }
        for (record.descriptors) |descriptor| if (descriptor.kind == .device) {
            device.vendor_id = descriptor.vendor_id;
            device.product_id = descriptor.product_id;
            device.class_code = descriptor.device_class;
        };
    }
    const endpoint_key = (@as(u64, record.bus) << 32) | (@as(u64, record.device) << 24) | (@as(u64, @intFromEnum(record.direction)) << 16) | (@as(u64, record.endpoint) << 8) | @intFromEnum(record.transfer);
    const ei = endpoint_index.get(endpoint_key) orelse blk: {
        if (endpoints.items.len == max_endpoints) break :blk null;
        const value: u32 = @intCast(endpoints.items.len);
        try endpoint_index.put(a, endpoint_key, value);
        try endpoints.append(a, .{ .bus = record.bus, .device = record.device, .endpoint = record.endpoint, .direction = record.direction, .transfer = record.transfer, .first_record = index, .last_record = index });
        break :blk value;
    };
    if (ei) |value| {
        const endpoint = &endpoints.items[value];
        endpoint.last_record = index;
        endpoint.captured_bytes += record.data.len;
        switch (record.event) {
            .submit => endpoint.submits += 1,
            .complete => endpoint.completions += 1,
            .error_event => endpoint.errors += 1,
            .unknown => {},
        }
        if (record.status != 0 and record.event != .error_event) endpoint.errors += 1;
    }
}

test "generated usbmon pcapng pairs URBs and decodes standard and class descriptors" {
    const a = std.testing.allocator;
    var writer = evidence.pcap.TestWriter{ .a = a };
    defer writer.deinit();
    try writer.shb();
    try writer.idb(link_usb_linux_mmapped, 9, "usbmon1");
    var submit: [64]u8 = @splat(0);
    std.mem.writeInt(u64, submit[0..8], 0x1234, .little);
    submit[8] = 'S';
    submit[9] = 2;
    submit[10] = 0x80;
    submit[11] = 5;
    std.mem.writeInt(u16, submit[12..14], 3, .little);
    submit[14] = 0;
    submit[40] = 0x80;
    submit[41] = 6;
    std.mem.writeInt(u16, submit[42..44], 0x0100, .little);
    std.mem.writeInt(u16, submit[46..48], 18, .little);
    const descriptor = [_]u8{ 18, 1, 0, 2, 0, 0, 0, 64, 0x34, 0x12, 0x78, 0x56, 0, 1, 1, 2, 3, 1 };
    var complete: [64 + descriptor.len]u8 = @splat(0);
    std.mem.writeInt(u64, complete[0..8], 0x1234, .little);
    complete[8] = 'C';
    complete[9] = 2;
    complete[10] = 0x80;
    complete[11] = 5;
    std.mem.writeInt(u16, complete[12..14], 3, .little);
    complete[14] = 1;
    complete[15] = 0;
    std.mem.writeInt(u32, complete[32..36], 18, .little);
    std.mem.writeInt(u32, complete[36..40], 18, .little);
    @memcpy(complete[64..], &descriptor);
    try writer.epb(0, 1_000, &submit, submit.len, null);
    try writer.epb(0, 1_125, &complete, complete.len, null);
    const bytes = try a.dupe(u8, writer.out.items);
    const parent = try evidence.Stream.open(a, bytes, "synthetic-usb.pcapng");
    defer parent.destroy();
    const stream = (try Stream.open(a, parent)).?;
    defer stream.destroy();
    try std.testing.expectEqual(@as(usize, 2), stream.records.len);
    try std.testing.expectEqual(@as(?u32, 1), stream.records[0].peer_record);
    try std.testing.expectEqual(@as(?u64, 125), stream.records[1].latency_ns);
    try std.testing.expectEqual(@as(u16, 0x1234), stream.records[1].descriptors[0].vendor_id.?);
    try std.testing.expectEqual(@as(u16, 0x5678), stream.devices[0].product_id.?);
    try std.testing.expectEqual(@as(u64, 0), stream.loss().orphan_completions);
    try std.testing.expectEqualStrings("no capture context: open with --open-capture an archive containing USB fd tables", stream.correlate(1).reason);

    // A remote archive's empty ECTX is "not collected", not "no descriptor matched".
    const remote = try sockets.encode(a, .{ .capture_started_ns = 1_000, .pid = 9, .pairs = &.{}, .tables = &.{}, .collection = .not_collected_remote });
    defer a.free(remote);
    try parent.attachContext(remote, null);
    try std.testing.expectEqualStrings("not collected: remote", stream.correlate(1).reason);
}

test "USB class labels cover HID, CDC and mass storage basics" {
    try std.testing.expectEqualStrings("hid_keyboard", className(3, 1, 1));
    try std.testing.expectEqualStrings("cdc_control", className(2, null, null));
    try std.testing.expectEqualStrings("cdc_data", className(10, null, null));
    try std.testing.expectEqualStrings("mass_storage_scsi_bulk_only", className(8, 6, 0x50));
}
