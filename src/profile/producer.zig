//! Remote clock provenance. Capture times use the host CLOCK_MONOTONIC domain.
//! This fixed offset is approximate; it does not estimate subsequent drift.
const rt = @import("../target/runtime.zig").c;
const std = @import("std");
pub const Producer = struct {
    machine: u16,
    address_bits: u8,
    little_endian: bool,
    boot_id: ?[36]u8,
    monotonic_ns: u64,
    host_monotonic_ns: u64,
    uncertainty_ns: u64,
    pub fn supported(self: Producer) bool {
        if (self.machine != rt.XRT_X86_64 or self.address_bits != 64 or !self.little_endian) return false;
        if (self.boot_id) |id| for (id) |byte| {
            if (!std.ascii.isHex(byte) and byte != '-') return false;
        };
        return true;
    }
};
pub fn describe(target: ?*const rt.struct_xrt_target) ?Producer {
    var clock: rt.struct_xrt_clock = undefined;
    if (!rt.xrt_target_clock(target, &clock)) return null;
    const arch = rt.xrt_target_arch(target).*;
    return .{ .machine = arch.machine, .address_bits = arch.address_bits, .little_endian = arch.little_endian != 0, .boot_id = @import("../binary/snapshot.zig").bootIdTarget(target), .monotonic_ns = clock.producer_ns, .host_monotonic_ns = clock.host_ns, .uncertainty_ns = clock.uncertainty_ns };
}
