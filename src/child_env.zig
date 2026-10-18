//! xodb's own process-environment changes that a child must not inherit.
//! Vulkan setup sets loader variables (the display driver filter, and
//! --no-vk-layers) for the length of vkCreateInstance, on the main thread or
//! on the early Vulkan thread. A target or agent launch, which may run on
//! another thread at the same time, waits until they are cleared.
const std = @import("std");

var held = std.atomic.Value(u32).init(0);

/// Before setting a variable for xodb's own use; release() once it is unset.
pub fn hold() void {
    _ = held.fetchAdd(1, .acq_rel);
}
pub fn release() void {
    _ = held.fetchSub(1, .acq_rel);
}
/// Before a fork/exec: until no variable is held. Bounded (a driver that
/// hangs in vkCreateInstance must not hang every launch); the bound is far
/// above any instance creation seen (NVIDIA without a display: ~70 ms).
pub fn settle() void {
    const pause = std.c.timespec{ .sec = 0, .nsec = 500_000 };
    var waits: u32 = 0;
    while (held.load(.acquire) != 0 and waits < 10_000) : (waits += 1) _ = std.c.nanosleep(&pause, null);
}

test "settle returns once every hold is released" {
    hold();
    hold();
    release();
    release();
    settle();
    try std.testing.expectEqual(@as(u32, 0), held.load(.acquire));
}
