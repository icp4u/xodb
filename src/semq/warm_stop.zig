//! Stop-generation debounce, independent of worker and host scheduling speed.
const std = @import("std");
pub const delay_ms = 150;

pub const Stop = struct {
    generation: ?u64 = null,
    since_ms: u64 = 0,

    pub fn ready(self: *Stop, generation: ?u64, now_ms: u64) bool {
        const current = generation orelse {
            self.generation = null;
            return false;
        };
        if (self.generation == null or self.generation.? != current) {
            self.generation = current;
            self.since_ms = now_ms;
            return false;
        }
        return now_ms -| self.since_ms >= delay_ms;
    }
};

test "fast instruction stops never become warm eligible; a stable stop does" {
    var stop: Stop = .{};
    var now: u64 = 1000;
    for (1..4) |generation| {
        try std.testing.expect(!stop.ready(generation, now));
        now += delay_ms - 1;
        try std.testing.expect(!stop.ready(generation, now));
    }
    try std.testing.expect(stop.ready(3, now + 1));
    try std.testing.expect(stop.ready(3, now + 100 * delay_ms));
    // A resume resets the clock even if the next stop reuses its generation.
    try std.testing.expect(!stop.ready(null, now + 100 * delay_ms));
    now += 101 * delay_ms;
    try std.testing.expect(!stop.ready(3, now));
    try std.testing.expect(!stop.ready(3, now + delay_ms - 1));
    try std.testing.expect(stop.ready(3, now + delay_ms));
    try std.testing.expect(!stop.ready(4, now + 1000 * delay_ms));
}
