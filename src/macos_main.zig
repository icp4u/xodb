//! Native GUI entry. A worker owns local debugserver or the remote connection.
const std = @import("std");
const log = @import("log.zig");
const transport = @import("remote/transport.zig");
var quitting: transport.c.sig_atomic_t = 0;
extern fn xodb_macos_ignore_sigpipe() void;
fn onSignal(signal: c_int) callconv(.c) void {
    quitting = signal;
}
fn takesValue(arg: []const u8) bool {
    for ([_][]const u8{ "--connect", "--frames", "--font", "--ui-scale", "--theme", "--attach", "--exe", "--source", "--break" }) |name|
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
    var local: @import("model/macos_session.zig").Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            local.argv = args[i + 1 ..];
            if (local.argv.len == 0) return error.MissingProgram;
            break;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            log.info(.window, "xodb macOS: -- PROGRAM [ARGS...] | --attach PID [--exe FILE] | --connect HOST:PORT\nOptions: --break SYMBOL --source FILE --frames N --font FILE --ui-scale N --theme FILE\nNative DWARF source lines/locals and overview collectors are not available.\n", .{});
            return;
        }
        if (!takesValue(arg)) return error.MacModeNotAvailable;
        i += 1;
        if (i == args.len) return error.MissingOptionValue;
        if (std.mem.eql(u8, arg, "--connect")) endpoint = args[i];
        if (std.mem.eql(u8, arg, "--frames")) frames = try std.fmt.parseInt(u64, args[i], 10);
        if (std.mem.eql(u8, arg, "--font")) font = args[i];
        if (std.mem.eql(u8, arg, "--theme")) theme = args[i];
        if (std.mem.eql(u8, arg, "--attach")) {
            local.attach = try std.fmt.parseInt(i32, args[i], 10);
            if (local.attach <= 0) return error.InvalidPid;
        }
        if (std.mem.eql(u8, arg, "--exe")) local.executable = args[i];
        if (std.mem.eql(u8, arg, "--source")) local.source = args[i];
        if (std.mem.eql(u8, arg, "--break")) local.breakpoint = args[i];
        if (std.mem.eql(u8, arg, "--ui-scale")) scale = try @import("platform/window.zig").validateScale(try std.fmt.parseFloat(f32, args[i]));
    }
    const is_local = local.argv.len != 0 or local.attach != 0;
    if ((local.argv.len != 0 and local.attach != 0) or (is_local and endpoint != null)) return error.ConflictingTargets;
    if (!is_local and (local.executable != null or local.source != null or local.breakpoint != null)) return error.LocalTargetRequired;
    _ = transport.c.signal(transport.c.SIGINT, onSignal);
    _ = transport.c.signal(transport.c.SIGTERM, onSignal);
    xodb_macos_ignore_sigpipe();
    @import("appearance.zig").init(theme);
    var owner: @import("remote/native_owner.zig").Owner = .{ .options = local };
    try @import("ui/remote.zig").run(if (is_local) owner.endpoint() else if (endpoint) |address| .{ .tcp = address } else .none, if (is_local) "local / Apple debugserver" else if (endpoint != null) "remote" else "macOS presentation preview", font, scale, frames, &quitting, started);
}

test {
    _ = @import("platform/window.zig");
    _ = @import("ui/remote.zig");
}
