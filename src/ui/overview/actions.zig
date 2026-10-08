//! Confirmed GUI handoffs use argv, retain the sampled identity, and reap children.
const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("spawn.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
});
const identity = @import("../../model/process_identity.zig");
pub const Kind = enum { files, profile, attach };
pub const Request = struct { kind: Kind, id: identity.Identity };
pub const Launcher = struct {
    children: [16]c.pid_t = @splat(0),
    redact: bool = false,
    pub fn poll(self: *Launcher) bool {
        var failed = false;
        for (&self.children) |*pid| if (pid.* != 0) {
            var status: c_int = 0;
            if (c.waitpid(pid.*, &status, c.WNOHANG) == pid.*) {
                pid.* = 0;
                failed = failed or status != 0;
            }
        };
        return failed;
    }
    pub fn launch(self: *Launcher, request: Request) !void {
        if (self.redact and request.kind != .files) return error.RedactedDebuggerUnavailable;
        try identity.validate(request.id);
        _ = self.poll();
        const slot = for (&self.children) |*pid| {
            if (pid.* == 0) break pid;
        } else return error.TooManyOverviewWindows;
        var exe_buf: [4096]u8 = undefined;
        const n = c.readlink("/proc/self/exe", &exe_buf, exe_buf.len - 1);
        if (n <= 0 or n >= exe_buf.len - 1) return error.ExecutableUnavailable;
        exe_buf[@intCast(n)] = 0;
        const exe: [*:0]const u8 = @ptrCast(&exe_buf);
        var pid_buf: [32]u8 = undefined;
        var start_buf: [32]u8 = undefined;
        const pid = try std.fmt.bufPrintZ(&pid_buf, "{d}", .{request.id.pid});
        const start = try std.fmt.bufPrintZ(&start_buf, "{d}", .{request.id.start});
        var args: [16:null]?[*:0]const u8 = @splat(null);
        var used: usize = 0;
        var program = exe;
        if (request.kind == .files) {
            program = for ([_][*:0]const u8{ "/usr/bin/foot", "/usr/bin/xterm", "/usr/bin/alacritty" }) |terminal| {
                if (c.access(terminal, c.X_OK) == 0) break terminal;
            } else return error.NoTerminalAvailable;
            args[used] = program;
            used += 1;
            args[used] = "-e";
            used += 1;
        }
        args[used] = exe;
        used += 1;
        args[used] = if (request.kind == .files) "--lsof-top" else "--attach";
        used += 1;
        if (request.kind == .files) {
            args[used] = "--pid";
            used += 1;
        }
        args[used] = pid.ptr;
        used += 1;
        args[used] = "--expected-start-ticks";
        used += 1;
        args[used] = start.ptr;
        used += 1;
        if (request.kind == .profile) {
            args[used] = "--start-profile";
            used += 1;
        }
        if (request.kind == .files and self.redact) {
            args[used] = "--redact";
            used += 1;
        }
        var fa: c.posix_spawn_file_actions_t = undefined;
        if (c.posix_spawn_file_actions_init(&fa) != 0) return error.ActionSpawnFailed;
        defer _ = c.posix_spawn_file_actions_destroy(&fa);
        if (c.posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", c.O_RDONLY, 0) != 0 or
            c.posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", c.O_WRONLY, 0) != 0) return error.ActionSpawnFailed;
        if (c.posix_spawn(slot, program, &fa, null, @ptrCast(&args), c.environ) != 0) return error.ActionSpawnFailed;
    }
};

test "redacted handoff cannot launch an unredacted debugger" {
    var launcher = Launcher{ .redact = true };
    for ([_]Kind{ .attach, .profile }) |kind|
        try std.testing.expectError(error.RedactedDebuggerUnavailable, launcher.launch(.{ .kind = kind, .id = .{ .pid = 0, .start = 0 } }));
}
