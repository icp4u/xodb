//! A single MCP byte stream. TCP never binds implicitly; SSH owns one child.
const std = @import("std");
pub const c = @import("../generated/transport.zig");
extern "c" fn connect(c_int, *const c.sockaddr, c.socklen_t) c_int;
extern "c" fn bind(c_int, *const c.sockaddr, c.socklen_t) c_int;
extern "c" fn accept4(c_int, ?*c.sockaddr, ?*c.socklen_t, c_int) c_int;
const a = std.heap.page_allocator;
pub fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}
pub fn nonblock(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.RemoteNonblockFailed;
}
const Address = struct {
    storage: c.sockaddr_storage = std.mem.zeroes(c.sockaddr_storage),
    len: c.socklen_t,
    family: c_int,
    fn parse(text: []const u8) !Address {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.ExpectedNumericAddressAndPort;
        const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return error.InvalidPort;
        if (port == 0) return error.InvalidPort;
        var host = text[0..colon];
        const ipv6 = host.len > 2 and host[0] == '[' and host[host.len - 1] == ']';
        if (ipv6) host = host[1 .. host.len - 1];
        const z = try a.dupeSentinel(u8, host, 0);
        defer a.free(z);
        var result = Address{ .len = if (ipv6) @sizeOf(c.sockaddr_in6) else @sizeOf(c.sockaddr_in), .family = if (ipv6) c.AF_INET6 else c.AF_INET };
        if (ipv6) {
            const addr: *c.sockaddr_in6 = @ptrCast(@alignCast(&result.storage));
            addr.sin6_family = c.AF_INET6;
            addr.sin6_port = std.mem.nativeToBig(u16, port);
            if (c.inet_pton(c.AF_INET6, z, &addr.sin6_addr) != 1) return error.ExpectedNumericAddressAndPort;
        } else {
            const addr: *c.sockaddr_in = @ptrCast(@alignCast(&result.storage));
            addr.sin_family = c.AF_INET;
            addr.sin_port = std.mem.nativeToBig(u16, port);
            if (c.inet_pton(c.AF_INET, z, &addr.sin_addr) != 1) return error.ExpectedNumericAddressAndPort;
        }
        return result;
    }
};
pub const Stream = struct {
    fd: c_int = -1,
    child: c.pid_t = 0,
    pub fn close(self: *Stream) void {
        if (self.fd >= 0) {
            _ = c.shutdown(self.fd, c.SHUT_RDWR);
            _ = c.close(self.fd);
            self.fd = -1;
        }
        if (self.child > 0) {
            var status: c_int = 0;
            // Allow the remote server to restore probes/detach before SSH is reaped.
            const end = now() + 10_000_000_000;
            while (c.waitpid(self.child, &status, c.WNOHANG) == 0 and now() < end) _ = c.poll(null, 0, 10);
            if (c.waitpid(self.child, &status, c.WNOHANG) == 0) {
                _ = c.kill(self.child, c.SIGTERM);
                const kill_at = now() + 300_000_000;
                while (c.waitpid(self.child, &status, c.WNOHANG) == 0 and now() < kill_at) _ = c.poll(null, 0, 10);
                if (c.waitpid(self.child, &status, c.WNOHANG) == 0) {
                    _ = c.kill(self.child, c.SIGKILL);
                    _ = c.waitpid(self.child, &status, 0);
                }
            }
            self.child = 0;
        }
    }
    pub fn tcp(endpoint: []const u8, cancel: *const std.atomic.Value(bool)) !Stream {
        var address = try Address.parse(endpoint);
        const fd = c.socket(address.family, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
        if (fd < 0) return error.RemoteSocketFailed;
        errdefer _ = c.close(fd);
        const connected = connect(fd, @ptrCast(&address.storage), address.len);
        if (connected < 0 and std.c._errno().* != c.EINPROGRESS) return error.RemoteConnectFailed;
        var p = c.pollfd{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
        const deadline = now() + 8_000_000_000;
        while (connected < 0) {
            if (cancel.load(.acquire)) return error.Cancelled;
            if (now() >= deadline) return error.RemoteConnectTimeout;
            if (c.poll(&p, 1, 25) <= 0) continue;
            var err: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_ERROR, &err, &len) < 0 or err != 0) return error.RemoteConnectFailed;
            break;
        }
        tuneTcp(fd);
        return .{ .fd = fd };
    }
    pub fn ssh(host: []const u8, arguments: []const [:0]const u8) !Stream {
        if (host.len == 0 or host[0] == '-' or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidSshHost;
        const command = try shellCommand(a, arguments);
        defer a.free(command);
        const host_z = try a.dupeSentinel(u8, host, 0);
        defer a.free(host_z);
        const argv = [_:null]?[*:0]const u8{ "ssh", "-T", "-o", "BatchMode=yes", "-o", "ForwardAgent=no", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", host_z.ptr, command.ptr };
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &fds) < 0) return error.RemoteSocketFailed;
        errdefer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try nonblock(fds[0]);
        var actions: c.posix_spawn_file_actions_t = undefined;
        if (c.posix_spawn_file_actions_init(&actions) != 0) return error.RemoteSpawnFailed;
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        if (c.posix_spawn_file_actions_adddup2(&actions, fds[1], 0) != 0 or c.posix_spawn_file_actions_adddup2(&actions, fds[1], 1) != 0 or c.posix_spawn_file_actions_addclose(&actions, fds[0]) != 0 or c.posix_spawn_file_actions_addclose(&actions, fds[1]) != 0) return error.RemoteSpawnFailed;
        var stream = Stream{ .fd = fds[0] };
        if (c.posix_spawnp(&stream.child, "ssh", &actions, null, @ptrCast(@constCast(&argv)), c.environ) != 0) return error.RemoteSpawnFailed;
        return stream;
    }
};
pub fn shellCommand(allocator: std.mem.Allocator, args: []const [:0]const u8) ![:0]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "exec");
    for (args) |arg| {
        try bytes.appendSlice(allocator, " '");
        for (arg) |ch| if (ch == '\'') {
            try bytes.appendSlice(allocator, "'\\''");
        } else try bytes.append(allocator, ch);
        try bytes.append(allocator, '\'');
    }
    return allocator.dupeSentinel(u8, bytes.items, 0);
}
/// Accept exactly one connection before touching the target. No daemon/reconnect.
pub fn acceptOne(endpoint: []const u8, quitting: *volatile c.sig_atomic_t) !Stream {
    var address = try Address.parse(endpoint);
    const fd = c.socket(address.family, c.SOCK_STREAM | c.SOCK_CLOEXEC | c.SOCK_NONBLOCK, 0);
    if (fd < 0) return error.RemoteSocketFailed;
    defer _ = c.close(fd);
    const yes: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &yes, @sizeOf(c_int));
    if (bind(fd, @ptrCast(&address.storage), address.len) < 0) return error.RemoteBindFailed;
    if (c.listen(fd, 1) < 0) return error.RemoteListenFailed;
    @import("../m68k_log.zig").print("xodb: listening on {s}; one client, plaintext TCP without authentication\n", .{endpoint});
    while (quitting.* == 0) {
        var p = c.pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(&p, 1, 50) <= 0) continue;
        const client = accept4(fd, null, null, c.SOCK_CLOEXEC | c.SOCK_NONBLOCK);
        if (client < 0) {
            if (std.c._errno().* == c.EAGAIN or std.c._errno().* == c.EINTR) continue;
            return error.RemoteAcceptFailed;
        }
        tuneTcp(client);
        @import("../m68k_log.zig").print("xodb: remote client connected; listener closed\n", .{});
        return .{ .fd = client };
    }
    return error.Cancelled;
}
test "SSH arguments preserve shell metacharacters and quotes literally" {
    const command = try shellCommand(std.testing.allocator, &.{ "/a b/xodb", "a'b", "$(touch nope);`echo nope`", "" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("exec '/a b/xodb' 'a'\\''b' '$(touch nope);`echo nope`' ''", command);
}
test "TCP endpoint requires explicit numeric address and nonzero port" {
    _ = try Address.parse("127.0.0.1:4317");
    _ = try Address.parse("[::1]:4317");
    try std.testing.expectError(error.ExpectedNumericAddressAndPort, Address.parse("jetty:4317"));
    try std.testing.expectError(error.InvalidPort, Address.parse("127.0.0.1:0"));
}

fn tuneTcp(fd: c_int) void {
    const yes: c_int = 1;
    const idle: c_int = 15;
    const interval: c_int = 5;
    const count: c_int = 3;
    const timeout: c_int = 30000;
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &yes, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_KEEPALIVE, &yes, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_KEEPIDLE, &idle, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_KEEPINTVL, &interval, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_KEEPCNT, &count, @sizeOf(c_int));
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_USER_TIMEOUT, &timeout, @sizeOf(c_int));
}
