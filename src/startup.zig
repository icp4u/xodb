//! Best-effort startup diagnostic: main entry to first accepted presentation.
//! This does not wait for compositor scanout or asynchronous target/data loading.
const std = @import("std");
const log = @import("log.zig");
const linux = @import("target/linux.zig");
const c = @import("c_ui.zig").api;

pub fn report(started: u64, protocol_stdout: bool) void {
    const elapsed_us = (linux.now() -| started) / 1000;
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "xodb: first window frame submitted in {d}.{d:0>3} ms\n", .{ elapsed_us / 1000, elapsed_us % 1000 }) catch return;
    // MCP owns stdout; GUI diagnostics must not enter its JSON stream.
    if (protocol_stdout or log.toFile()) return log.info(.window, "{s}", .{line});
    if (log.on(.window, .info)) _ = c.write(1, line.ptr, line.len);
}
