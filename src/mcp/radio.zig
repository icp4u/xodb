//! Burrito mode over MCP: `list_radios`, `radio_interference(window_ms)` and
//! `radio_channels(window_ms)` (per Wi-Fi channel: power, occupancy, traffic,
//! and how hard the interferer hits it).
//! Observer-only: the tools read cards and the shared collector; a card is
//! only ever taken by the operator's `--radio` option.
const std = @import("std");
const Value = std.json.Value;
const wire = @import("profile.zig");
const radio = @import("../radio/radio.zig");

pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "list_radios") or std.mem.eql(u8, name, "radio_interference") or std.mem.eql(u8, name, "radio_channels");
}

fn toValue(a: std.mem.Allocator, v: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, v, .{}), .{ .allocate = .alloc_always })).value;
}

pub fn call(a: std.mem.Allocator, name: []const u8, args: Value, redact_all: bool) !Value {
    if (std.mem.eql(u8, name, "list_radios")) {
        try wire.fields(args, &.{});
        return toValue(a, try radio.radios(a, radio.defaults.roots));
    }
    try wire.fields(args, &.{ "window_ms", "redact" });
    const window_ms = try wire.number(args, "window_ms", 30_000);
    if (window_ms < 1000 or window_ms > 600_000) return error.InvalidArguments;
    var redact = redact_all;
    if (args.object.get("redact")) |r| {
        if (r != .bool) return error.InvalidArguments;
        redact = redact or r.bool;
    }
    const m = radio.ensure(std.heap.c_allocator) orelse return error.RadioUnavailable;
    const started_ms = (radio.fsx.monotonicNs() - m.started_ns) / 1_000_000;
    if (std.mem.eql(u8, name, "radio_channels")) {
        // Counts only: no address, SSID or BSSID is ever in the reply (redact changes nothing here).
        const now = radio.fsx.monotonicNs();
        var v = try toValue(a, try radio.channelsBetween(a, m, now -| window_ms * 1_000_000, now, null));
        try v.object.put(a, "collector_age_ms", .{ .integer = @intCast(started_ms) });
        if (started_ms < window_ms) try v.object.put(a, "partial_window", .{ .string = "the collector started within this window; earlier evidence was not recorded" });
        return v;
    }
    const r = try radio.report(a, m, window_ms * 1_000_000, redact);
    var v = try toValue(a, r);
    try v.object.put(a, "collector_age_ms", .{ .integer = @intCast(started_ms) });
    if (started_ms < window_ms) try v.object.put(a, "partial_window", .{ .string = "the collector started within this window; earlier evidence was not recorded" });
    return v;
}
