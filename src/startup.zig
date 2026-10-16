//! Best-effort startup diagnostic: main entry to first accepted presentation.
//! This does not wait for compositor scanout or asynchronous target/data loading.
const std = @import("std");
const log = @import("log.zig");
const c = @import("c_ui.zig").api;
const phases = @import("startup_phases.zig");

fn millis(phase: phases.Phase) struct { u64, u64 } {
    const us = phases.microseconds(phase);
    return .{ us / 1000, us % 1000 };
}

pub fn report(started: u64, protocol_stdout: bool) void {
    // Present ends this when the queue accepts the image. Ending here covers a
    // caller that reports without that hook, and is a no-op once it has ended.
    phases.end(.draw);
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const now = @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    const elapsed_us = (now -| started) / 1000;
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "xodb: first window frame submitted in {d}.{d:0>3} ms\n", .{ elapsed_us / 1000, elapsed_us % 1000 }) catch return;
    // MCP owns stdout; GUI diagnostics must not enter its JSON stream.
    if (protocol_stdout or log.toFile()) log.info(.window, "{s}", .{line}) else if (log.on(.window, .info)) _ = c.write(1, line.ptr, line.len);
    const connect = millis(.connect);
    const window = millis(.window);
    const instance = millis(.instance);
    const device = millis(.device);
    const swapchain = millis(.swapchain);
    const draw = millis(.draw);
    // Same text on Wayland, X11 and macOS. Debug, so the info line above stays
    // the only default stdout line. Durations are exclusive; 0.000 was not marked.
    log.debug(.window, "startup connect={d}.{d:0>3} window={d}.{d:0>3} instance={d}.{d:0>3} device={d}.{d:0>3} swapchain={d}.{d:0>3} draw={d}.{d:0>3} ms\n", .{
        connect[0], connect[1], window[0], window[1], instance[0], instance[1], device[0], device[1], swapchain[0], swapchain[1], draw[0], draw[1],
    });
}
