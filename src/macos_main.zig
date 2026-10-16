//! Native presentation entry while local debugger ownership is being ported.
//! Reuse the real remote client and renderer; unsupported modes refuse explicitly.
const std = @import("std");
const log = @import("log.zig");
const transport = @import("remote/transport.zig");
var quitting: transport.c.sig_atomic_t = 0;
extern fn xodb_macos_ignore_sigpipe() void;
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}
fn takesValue(arg: []const u8) bool {
    for ([_][]const u8{ "--connect", "--frames", "--font", "--ui-scale", "--theme" }) |name|
        if (std.mem.eql(u8, arg, name)) return true;
    return false;
}
pub fn main(init: std.process.Init) !void {
    const started = transport.now();
    const a = init.arena.allocator();
    const args = log.init(try a.dupe([:0]const u8, try init.minimal.args.toSlice(a)), takesValue);
    var endpoint: ?[]const u8 = null;
    var frames: u64 = 0;
    var font: [:0]const u8 = @import("build_options").font_path ++ "";
    var theme: ?[:0]const u8 = null;
    var scale: ?f32 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            log.info(.window, "xodb macOS presentation client: --connect HOST:PORT [--frames N] [--font FILE] [--ui-scale N] [--theme FILE]\nLocal launch/attach and overview collectors are not available in this build yet.\n", .{});
            return;
        }
        if (!takesValue(arg)) return error.MacModeNotAvailable;
        i += 1;
        if (i == args.len) return error.MissingOptionValue;
        if (std.mem.eql(u8, arg, "--connect")) endpoint = args[i];
        if (std.mem.eql(u8, arg, "--frames")) frames = try std.fmt.parseInt(u64, args[i], 10);
        if (std.mem.eql(u8, arg, "--font")) font = args[i];
        if (std.mem.eql(u8, arg, "--theme")) theme = args[i];
        if (std.mem.eql(u8, arg, "--ui-scale")) scale = try @import("platform/window.zig").validateScale(try std.fmt.parseFloat(f32, args[i]));
    }
    _ = transport.c.signal(transport.c.SIGINT, onSignal);
    _ = transport.c.signal(transport.c.SIGTERM, onSignal);
    xodb_macos_ignore_sigpipe();
    @import("appearance.zig").init(theme);
    try @import("ui/remote.zig").run(if (endpoint) |address| .{ .tcp = address } else .none, if (endpoint != null) "remote" else "macOS presentation preview / local debugging not yet available", font, scale, frames, &quitting, started);
}

test {
    _ = @import("platform/window.zig");
    _ = @import("ui/remote.zig");
}
