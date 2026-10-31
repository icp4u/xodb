//! Bounded client for xodb's persistent per-user Ghidra JVM sidecar.
const std = @import("std");
const log = @import("../log.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("spawn.h");
    @cInclude("time.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("sys/wait.h");
});
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
extern "c" fn connect(c_int, *const c.sockaddr, c.socklen_t) c_int;
extern fn xrt_spawn_owned_helper(pid: *i32, create: *const fn (*i32, ?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) c_int;
extern fn xrt_drop_owned_helper(pid: i32) void;
extern fn xrt_reap_orphan_zombies() void;
const protocol = 1;
const schema = 1;
pub const producer = "ghidra-jvm-sidecar-0.1.10";
const max_line = 1 << 20;
const max_payload = 64 << 20;
var reported_unreplaceable = std.atomic.Value(bool).init(false);

pub const Stage = enum(u8) { queued, starting, opening, hashing, importing, analyzing, decompiling, loading, ready, failed };
pub fn stageText(stage: Stage) []const u8 {
    return switch (stage) {
        .queued => "queued",
        .starting => "starting Ghidra",
        .opening => "opening image",
        .hashing => "hashing image",
        .importing => "importing image",
        .analyzing => "analyzing image",
        .decompiling => "decompiling",
        .loading => "loading export",
        .ready => "ready",
        .failed => "failed",
    };
}

pub const Request = struct {
    socket_path: [:0]const u8,
    starter: ?[:0]const u8,
    image_path: []const u8,
    sha256: []const u8,
    entry: u64,
    size: u64,
    build_id: ?[]const u8,
    deadline_ms: u32,
};
pub const Endpoint = struct {
    socket_path: [:0]const u8,
    starter: ?[:0]const u8,
    deadline_ms: u32,
};
pub const Result = struct { document: []u8, elapsed_ms: f64 };
pub const Failure = struct { code: []const u8, detail: []const u8 };

fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

pub fn socketPath(a: Allocator) ![:0]u8 {
    if (c.getenv("XODB_GHIDRA_SOCKET")) |path| if (path[0] != 0) return a.dupeZ(u8, std.mem.span(path));
    if (c.getenv("XDG_RUNTIME_DIR")) |dir| if (dir[0] != 0) return std.fmt.allocPrintSentinel(a, "{s}/.xodb.ghidra.s", .{std.mem.span(dir)}, 0);
    const base = if (c.getenv("TMPDIR")) |dir| if (dir[0] != 0) std.mem.span(dir) else "/tmp" else "/tmp";
    return std.fmt.allocPrintSentinel(a, "{s}/xodb-{d}/.xodb.ghidra.s", .{ base, c.getuid() }, 0);
}

pub fn starterPath(a: Allocator) !?[:0]u8 {
    if (c.getenv("XODB_GHIDRA_SIDECAR")) |path| if (path[0] != 0) return if (c.access(path, c.X_OK) == 0) try a.dupeZ(u8, std.mem.span(path)) else null;
    // Never the current directory: the starter is found from where this
    // executable lives (beside it, an installed share directory, or the
    // source tree a zig-out/bin build sits in).
    var exe: [std.fs.max_path_bytes]u8 = undefined;
    const length = c.readlink("/proc/self/exe", &exe, exe.len);
    if (length <= 0 or length >= exe.len) return null;
    const dir = std.fs.path.dirname(exe[0..@intCast(length)]) orelse return null;
    for ([_][]const u8{ "ghidra-sidecar", "../share/xodb/scripts/ghidra-sidecar", "../../scripts/ghidra-sidecar" }) |relative| {
        const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, relative }, 0);
        if (c.access(path.ptr, c.X_OK) == 0) return path;
        a.free(path);
    }
    return null;
}

fn starterSearch(a: Allocator) []const u8 {
    if (env("XODB_GHIDRA_SIDECAR")) |path| return path;
    var exe: [std.fs.max_path_bytes]u8 = undefined;
    const length = c.readlink("/proc/self/exe", &exe, exe.len);
    if (length <= 0 or length >= exe.len) return "XODB_GHIDRA_SIDECAR and paths relative to /proc/self/exe";
    const dir = std.fs.path.dirname(exe[0..@intCast(length)]) orelse return "XODB_GHIDRA_SIDECAR and paths relative to /proc/self/exe";
    return std.fmt.allocPrint(a, "{s}/ghidra-sidecar, {s}/../share/xodb/scripts/ghidra-sidecar, {s}/../../scripts/ghidra-sidecar", .{ dir, dir, dir }) catch "paths relative to /proc/self/exe";
}

fn pathExecutable(a: Allocator, name: []const u8) bool {
    const path = env("PATH") orelse return false;
    var entries = std.mem.splitScalar(u8, path, ':');
    while (entries.next()) |directory| {
        const candidate = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (directory.len == 0) "." else directory, name }, 0) catch return false;
        const found = c.access(candidate.ptr, c.X_OK) == 0;
        a.free(candidate);
        if (found) return true;
    }
    return false;
}

fn producerVersion(name: []const u8) []const u8 {
    const prefix = "ghidra-jvm-sidecar-";
    return if (std.mem.startsWith(u8, name, prefix)) name[prefix.len..] else name;
}

/// Where scripts/ghidra-sidecar appends the JVM's and its own diagnostics.
fn logPath(a: Allocator) []const u8 {
    const made = if (env("XODB_GHIDRA_STATE")) |dir|
        std.fmt.allocPrint(a, "{s}/sidecar.log", .{dir})
    else if (env("XDG_STATE_HOME")) |dir|
        std.fmt.allocPrint(a, "{s}/xodb/ghidra-sidecar/sidecar.log", .{dir})
    else
        std.fmt.allocPrint(a, "{s}/.local/state/xodb/ghidra-sidecar/sidecar.log", .{env("HOME") orelse "~"});
    return made catch "sidecar.log";
}
fn env(name: [*:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return if (value[0] != 0) std.mem.span(value) else null;
}

/// XODB_GHIDRA_SIDECAR=off keeps this xodb on the native worker and away from
/// a sidecar that happens to be running (tests of the native producer use it).
pub fn selected(a: Allocator) !bool {
    if (env("XODB_GHIDRA_SIDECAR")) |value| if (std.mem.eql(u8, value, "off")) return false;
    const socket = try socketPath(a);
    var st: c.struct_stat = undefined;
    if (c.lstat(socket.ptr, &st) == 0) return true;
    if (try starterPath(a) == null) return false;
    for ([_][*:0]const u8{ "XODB_GHIDRA_HOME", "GHIDRA_HOME" }) |name| if (c.getenv(name)) |path| if (path[0] != 0) return true;
    return c.access("/opt/ghidra/support/analyzeHeadless", c.X_OK) == 0 or pathExecutable(a, "analyzeHeadless");
}

const Connection = struct {
    fd: c_int,
    cancel: *const std.atomic.Value(bool),
    deadline: u64,

    fn open(path: [:0]const u8, cancel: *const std.atomic.Value(bool), deadline: u64) !Connection {
        var st: c.struct_stat = undefined;
        if (c.lstat(path.ptr, &st) != 0) return error.SidecarAbsent;
        if (st.st_mode & c.S_IFMT != c.S_IFSOCK or st.st_uid != c.getuid() or st.st_mode & 0o777 != 0o600) return error.SidecarSocketUnsafe;
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SidecarConnectFailed;
        errdefer _ = c.close(fd);
        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        const bytes: []const u8 = path;
        if (bytes.len >= address.sun_path.len) return error.SidecarSocketPathTooLong;
        @memcpy(address.sun_path[0..bytes.len], bytes);
        if (connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.SidecarConnectFailed;
        var cred: c.struct_ucred = undefined;
        var cred_len: c.socklen_t = @sizeOf(c.struct_ucred);
        if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &cred_len) != 0 or cred.uid != c.getuid()) return error.SidecarPeerMismatch;
        return .{ .fd = fd, .cancel = cancel, .deadline = deadline };
    }
    fn close(self: *Connection) void {
        _ = c.close(self.fd);
        self.fd = -1;
    }
    fn wait(self: *Connection, events: c_short) !void {
        while (true) {
            if (self.cancel.load(.acquire)) return error.Cancelled;
            if (nowNs() >= self.deadline) return error.DeadlineExceeded;
            var p = c.pollfd{ .fd = self.fd, .events = events, .revents = 0 };
            const rc = c.poll(&p, 1, 50);
            if (rc < 0 and std.c._errno().* != c.EINTR) return error.SidecarIoFailed;
            // A peer may close immediately after its complete reply, yielding
            // POLLIN|POLLHUP together. Drain readable bytes before treating the
            // hangup as a death; readExact still reports a truncated reply.
            if (rc > 0 and p.revents & events != 0) return;
            if (rc > 0 and p.revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return error.SidecarDied;
        }
    }
    fn writeAll(self: *Connection, bytes: []const u8) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            try self.wait(c.POLLOUT);
            const n = c.send(self.fd, bytes[done..].ptr, bytes.len - done, c.MSG_NOSIGNAL);
            if (n < 0 and (std.c._errno().* == c.EINTR or std.c._errno().* == c.EAGAIN)) continue;
            if (n <= 0) return error.SidecarDied;
            done += @intCast(n);
        }
    }
    fn readExact(self: *Connection, bytes: []u8) !void {
        var done: usize = 0;
        while (done < bytes.len) {
            try self.wait(c.POLLIN);
            const n = c.recv(self.fd, bytes[done..].ptr, bytes.len - done, 0);
            if (n < 0 and (std.c._errno().* == c.EINTR or std.c._errno().* == c.EAGAIN)) continue;
            if (n <= 0) return error.SidecarDied;
            done += @intCast(n);
        }
    }
    fn readLine(self: *Connection, a: Allocator) ![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(a);
        while (line.items.len <= max_line) {
            var ch: [1]u8 = undefined;
            try self.readExact(&ch);
            if (ch[0] == '\n') return line.toOwnedSlice(a);
            if (ch[0] != '\r') try line.append(a, ch[0]);
        }
        return error.SidecarLineTooLarge;
    }
};

/// A validated, otherwise idle connection owned by one xodb session.  The
/// sidecar counts open connections when deciding whether it may idle-exit.
pub const Hold = struct {
    fd: c_int = -1,

    pub fn open(a: Allocator, path: [:0]const u8) !Hold {
        var never_cancel = std.atomic.Value(bool).init(false);
        var connection = try Connection.open(path, &never_cancel, nowNs() + 2 * std.time.ns_per_s);
        errdefer connection.close();
        const encoded = try std.json.Stringify.valueAlloc(a, .{ .id = "xodb-session", .verb = "hello", .deadline_ms = 2000 }, .{});
        try connection.writeAll(encoded);
        try connection.writeAll("\n");
        const line = try connection.readLine(a);
        const reply = try std.json.parseFromSliceLeaky(Value, a, line, .{ .max_value_len = max_line });
        if (!expectedHello(reply)) return error.SidecarProtocolMismatch;
        const fd = connection.fd;
        connection.fd = -1;
        return .{ .fd = fd };
    }

    pub fn alive(self: *const Hold) bool {
        if (self.fd < 0) return false;
        var byte: [1]u8 = undefined;
        const n = c.recv(self.fd, &byte, byte.len, c.MSG_PEEK | c.MSG_DONTWAIT);
        if (n > 0) return true;
        if (n == 0) return false;
        const err = std.c._errno().*;
        return err == c.EAGAIN or err == c.EWOULDBLOCK or err == c.EINTR;
    }

    pub fn close(self: *Hold) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

const Reply = struct { value: Value, payload: ?[]u8 = null };
fn call(a: Allocator, path: [:0]const u8, request: anytype, cancel: *const std.atomic.Value(bool), deadline: u64) !Reply {
    var connection = try Connection.open(path, cancel, deadline);
    defer connection.close();
    const encoded = try std.json.Stringify.valueAlloc(a, request, .{ .emit_null_optional_fields = false });
    try connection.writeAll(encoded);
    try connection.writeAll("\n");
    const line = try connection.readLine(a);
    const parsed = try std.json.parseFromSliceLeaky(Value, a, line, .{ .max_value_len = max_line });
    if (parsed != .object) return error.SidecarBadReply;
    var result = Reply{ .value = parsed };
    if (parsed.object.get("payload_length")) |length_value| {
        if (length_value != .integer or length_value.integer < 0 or length_value.integer > max_payload) return error.SidecarBadReply;
        var frame: [8]u8 = undefined;
        try connection.readExact(&frame);
        const framed = std.mem.readInt(u64, &frame, .big);
        if (framed != length_value.integer) return error.SidecarBadReply;
        result.payload = try a.alloc(u8, @intCast(framed));
        try connection.readExact(result.payload.?);
    }
    return result;
}

fn memberText(value: Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}
fn memberInt(value: Value, name: []const u8) ?i64 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .integer) field.integer else null;
}
fn expectedHello(value: Value) bool {
    if (!std.mem.eql(u8, memberText(value, "state") orelse "", "ready")) return false;
    if (memberInt(value, "protocol") != protocol or memberInt(value, "schema") != schema or memberInt(value, "uid") != c.getuid()) return false;
    if (!std.mem.eql(u8, memberText(value, "producer") orelse "", producer)) return false;
    const healthy = value.object.get("healthy") orelse return false;
    if (healthy != .bool or !healthy.bool) return false;
    const capabilities = value.object.get("capabilities") orelse return false;
    if (capabilities != .array) return false;
    // "prime" is optional: a running sidecar from before it existed keeps
    // serving, and only misses the warm-up.
    for ([_][]const u8{ "open_image", "decompile", "cancel", "status", "shutdown", "xsg", "pseudocode" }) |needed| {
        var found = false;
        for (capabilities.array.items) |cap| if (cap == .string and std.mem.eql(u8, cap.string, needed)) {
            found = true;
            break;
        };
        if (!found) return false;
    }
    return true;
}

fn hello(a: Allocator, path: [:0]const u8, cancel: *const std.atomic.Value(bool), deadline: u64) !Value {
    return (try call(a, path, .{ .id = "xodb-hello", .verb = "hello", .deadline_ms = 2000 }, cancel, deadline)).value;
}

const SidecarSpawn = struct {
    file: [*:0]const u8,
    actions: *c.posix_spawn_file_actions_t,
    argv: [*c]?[*:0]const u8,
};

fn sidecarSpawn(pid: *i32, raw: ?*anyopaque) callconv(.c) c_int {
    const ctx: *SidecarSpawn = @ptrCast(@alignCast(raw orelse return @intCast(c.EINVAL)));
    var child: c.pid_t = 0;
    // spawn-allow: create callback of xrt_spawn_owned_helper
    const rc = c.posix_spawnp(&child, ctx.file, ctx.actions, null, @ptrCast(ctx.argv), c.environ);
    if (rc != 0) return rc;
    pid.* = @intCast(child);
    return 0;
}

fn dropOwned(pid: c.pid_t) void {
    if (pid > 1) xrt_drop_owned_helper(@intCast(pid));
}

fn taskZombie(pid: c.pid_t) bool {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return false;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var buf: [512]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return false;
    const text = buf[0..@intCast(n)];
    const paren = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    if (paren + 2 >= text.len) return false;
    return text[paren + 2] == 'Z';
}

/// Test-only. After the helper is a zombie, run the same orphan reap the
/// follow poll uses, then let the wait below read the status. Unset in
/// ordinary runs. The helper is noted first, so the reap leaves it alone.
fn reapBeforeHelperWait(pid: c.pid_t) void {
    const flag = c.getenv("XODB_TEST_REAP_BEFORE_HELPER_WAIT") orelse return;
    if (flag[0] != '1' or flag[1] != 0) return;
    const deadline = nowNs() + 8 * std.time.ns_per_s;
    while (nowNs() < deadline and !taskZombie(pid)) _ = c.poll(null, 0, 20);
    xrt_reap_orphan_zombies();
}

fn start(starter: [:0]const u8, cancel: *const std.atomic.Value(bool), deadline: u64) !void {
    var pid: c.pid_t = 0;
    const argv = [_:null]?[*:0]const u8{ starter.ptr, "start", null };
    const devnull = c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC);
    if (devnull < 0) return error.SidecarStarterFailed;
    defer _ = c.close(devnull);
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SidecarStarterFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (c.posix_spawn_file_actions_adddup2(&actions, devnull, 1) != 0 or c.posix_spawn_file_actions_adddup2(&actions, devnull, 2) != 0 or c.posix_spawn_file_actions_addclose(&actions, devnull) != 0) return error.SidecarStarterFailed;
    var spawned: i32 = 0;
    var spawn_ctx = SidecarSpawn{ .file = starter.ptr, .actions = &actions, .argv = @ptrCast(@constCast(&argv)) };
    if (xrt_spawn_owned_helper(&spawned, sidecarSpawn, &spawn_ctx) != 0) return error.SidecarStarterFailed;
    pid = @intCast(spawned);
    defer dropOwned(pid);
    reapBeforeHelperWait(pid);
    var status: c_int = 0;
    while (true) {
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited == pid) break;
        if (waited < 0) {
            // Noted too late: the follow reap already collected this child.
            // The status is gone. A clean exit lets the hello below decide.
            if (std.c._errno().* == c.ECHILD) {
                status = 0;
                break;
            }
            return error.SidecarStarterFailed;
        }
        if (cancel.load(.acquire) or nowNs() >= deadline) {
            _ = c.kill(pid, c.SIGTERM);
            _ = c.waitpid(pid, &status, 0);
            return if (cancel.load(.acquire)) error.Cancelled else error.DeadlineExceeded;
        }
        _ = c.poll(null, 0, 25);
    }
    // The starter exits 4 when it finds no Ghidra installation or no JDK.
    if (c.WIFEXITED(status) and c.WEXITSTATUS(status) == 4) return error.SidecarNotConfigured;
    if (!c.WIFEXITED(status) or c.WEXITSTATUS(status) != 0) return error.SidecarStarterFailed;
}

fn fail(a: Allocator, out: *Failure, code: []const u8, comptime format: []const u8, args: anytype) error{SidecarFailed} {
    out.* = .{ .code = code, .detail = std.fmt.allocPrint(a, format, args) catch code };
    return error.SidecarFailed;
}

fn ensure(a: Allocator, endpoint: Endpoint, cancel: *const std.atomic.Value(bool), deadline: u64, stage: *std.atomic.Value(Stage), failure: *Failure) !void {
    var seen: []const u8 = "no answering socket";
    var observed_producer: ?[]const u8 = null;
    if (hello(a, endpoint.socket_path, cancel, @min(deadline, nowNs() + 2 * std.time.ns_per_s))) |reply| {
        if (expectedHello(reply)) return log.debug(.sidecar, "Ghidra sidecar answers on {s}; using it\n", .{endpoint.socket_path});
        observed_producer = memberText(reply, "producer");
        seen = try std.json.Stringify.valueAlloc(a, reply, .{});
    } else |_| {}
    const starter = endpoint.starter orelse {
        const searched = starterSearch(a);
        if (observed_producer) |observed| {
            if (reported_unreplaceable.cmpxchgStrong(false, true, .acq_rel, .acquire) == null)
                log.debug(.sidecar, "Ghidra sidecar unavailable: running sidecar is {s}, this xodb needs {s}; no starter found to replace it (looked in {s})\n", .{ producerVersion(observed), producerVersion(producer), searched });
            return fail(a, failure, "sidecar_protocol_mismatch", "running sidecar is {s}, this xodb needs {s}; no starter found to replace it (looked in {s})", .{ producerVersion(observed), producerVersion(producer), searched });
        }
        log.debug(.sidecar, "Ghidra sidecar unavailable: no answering socket and no starter found (looked in {s})\n", .{searched});
        return fail(a, failure, "sidecar_unavailable", "Ghidra sidecar is absent; no starter found (looked in {s}); set XODB_GHIDRA_SIDECAR", .{searched});
    };
    log.debug(.sidecar, "Ghidra sidecar start or restart: {s}\n", .{seen});
    stage.store(.starting, .release);
    start(starter, cancel, deadline) catch |err| {
        log.debug(.sidecar, "Ghidra sidecar starter {s} failed: {s}\n", .{ starter, @errorName(err) });
        if (err == error.SidecarNotConfigured) return fail(a, failure, "sidecar_not_configured", "no Ghidra installation or JDK was found: set GHIDRA_HOME (or XODB_GHIDRA_HOME) to a Ghidra directory and JAVA_HOME, or put java and javac on PATH; details in {s}", .{logPath(a)});
        return fail(a, failure, if (err == error.Cancelled) "cancelled" else if (err == error.DeadlineExceeded) "sidecar_timeout" else "sidecar_start_failed", "{s}; expected protocol {d}, schema {d}; initially saw {s}; sidecar log {s}", .{ @errorName(err), protocol, schema, seen, logPath(a) });
    };
    const reply = hello(a, endpoint.socket_path, cancel, @min(deadline, nowNs() + 3 * std.time.ns_per_s)) catch |err| return fail(a, failure, "sidecar_start_failed", "starter exited successfully but hello failed: {s}; expected protocol {d}, schema {d}; sidecar log {s}", .{ @errorName(err), protocol, schema, logPath(a) });
    if (!expectedHello(reply)) {
        const after = try std.json.Stringify.valueAlloc(a, reply, .{});
        return fail(a, failure, "sidecar_protocol_mismatch", "expected protocol {d}, schema {d}, producer {s}, same uid and required capabilities; initially saw {s}; after one restart saw {s}; sidecar log {s}", .{ protocol, schema, producer, seen, after, memberText(reply, "log") orelse logPath(a) });
    }
}

fn bootThread() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!(selected(a) catch false)) return;
    const endpoint = Endpoint{ .socket_path = socketPath(a) catch return, .starter = starterPath(a) catch null, .deadline_ms = 30_000 };
    var cancel = std.atomic.Value(bool).init(false);
    var stage = std.atomic.Value(Stage).init(.queued);
    var failure: Failure = undefined;
    const deadline = nowNs() + @as(u64, endpoint.deadline_ms) * std.time.ns_per_ms;
    ensure(a, endpoint, &cancel, deadline, &stage, &failure) catch {};
}

/// Start or connect to the configured sidecar while the rest of xodb starts.
/// This worker owns all of its storage and intentionally outlives the caller.
pub fn prestart() void {
    const thread = std.Thread.spawn(.{}, bootThread, .{}) catch return;
    thread.detach();
}

fn updateStage(reply: Value, stage: *std.atomic.Value(Stage)) void {
    const progress = memberText(reply, "progress") orelse return;
    const next: Stage = if (std.mem.eql(u8, progress, "hashing")) .hashing else if (std.mem.eql(u8, progress, "importing")) .importing else if (std.mem.eql(u8, progress, "analyzing")) .analyzing else if (std.mem.eql(u8, progress, "decompiling")) .decompiling else if (std.mem.eql(u8, progress, "opening project image")) .opening else return;
    stage.store(next, .release);
}

fn waitJob(a: Allocator, path: [:0]const u8, first: Reply, cancel: *const std.atomic.Value(bool), deadline: u64, stage: *std.atomic.Value(Stage), failure: *Failure) !Reply {
    var reply = first;
    while (std.mem.eql(u8, memberText(reply.value, "state") orelse "", "pending")) {
        updateStage(reply.value, stage);
        const job = memberText(reply.value, "job") orelse return fail(a, failure, "sidecar_bad_reply", "pending reply omitted its job id", .{});
        if (cancel.load(.acquire) or nowNs() >= deadline) {
            var sending = std.atomic.Value(bool).init(false);
            _ = call(a, path, .{ .id = "xodb-cancel", .verb = "cancel", .job = job, .deadline_ms = 2000 }, &sending, nowNs() + 2 * std.time.ns_per_s) catch {};
            if (cancel.load(.acquire)) return fail(a, failure, "cancelled", "sidecar request cancelled", .{});
            return fail(a, failure, "sidecar_timeout", "sidecar request exceeded its deadline", .{});
        }
        _ = c.poll(null, 0, 5);
        reply = call(a, path, .{ .id = "xodb-status", .verb = "status", .job = job, .deadline_ms = 2000 }, cancel, deadline) catch |err| {
            if (err == error.Cancelled) {
                var sending = std.atomic.Value(bool).init(false);
                _ = call(a, path, .{ .id = "xodb-cancel", .verb = "cancel", .job = job, .deadline_ms = 2000 }, &sending, nowNs() + 2 * std.time.ns_per_s) catch {};
                return fail(a, failure, "cancelled", "sidecar request cancelled", .{});
            }
            // Each poll is a new connection, so a sidecar that died between polls refuses or has no socket.
            const died = err == error.SidecarDied or err == error.SidecarConnectFailed or err == error.SidecarAbsent;
            return fail(a, failure, if (died) "sidecar_died" else "sidecar_io_failed", "{s} while polling {s}; a retry starts a new sidecar", .{ @errorName(err), job });
        };
    }
    if (!std.mem.eql(u8, memberText(reply.value, "state") orelse "", "ready")) return fail(a, failure, memberText(reply.value, "code") orelse "sidecar_failed", "{s}", .{memberText(reply.value, "detail") orelse "sidecar request failed"});
    return reply;
}

pub fn run(a: Allocator, request: Request, cancel: *const std.atomic.Value(bool), stage: *std.atomic.Value(Stage), failure: *Failure) !Result {
    const begun = nowNs();
    const deadline = begun + @as(u64, request.deadline_ms) * std.time.ns_per_ms;
    try ensure(a, .{ .socket_path = request.socket_path, .starter = request.starter, .deadline_ms = request.deadline_ms }, cancel, deadline, stage, failure);
    stage.store(.opening, .release);
    const open_reply = call(a, request.socket_path, .{ .id = "xodb-open", .verb = "open_image", .path = request.image_path, .sha256 = request.sha256, .deadline_ms = request.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else if (err == error.SidecarDied) "sidecar_died" else "sidecar_io_failed", "open_image: {s}", .{@errorName(err)});
    _ = try waitJob(a, request.socket_path, open_reply, cancel, deadline, stage, failure);
    stage.store(.decompiling, .release);
    const entry = try std.fmt.allocPrint(a, "0x{x}", .{request.entry});
    const size = try std.fmt.allocPrint(a, "0x{x}", .{request.size});
    const decompile_reply = call(a, request.socket_path, .{ .id = "xodb-decompile", .verb = "decompile", .path = request.image_path, .sha256 = request.sha256, .entry = entry, .size = size, .build_id = request.build_id, .options = "default", .deadline_ms = request.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else if (err == error.SidecarDied) "sidecar_died" else "sidecar_io_failed", "decompile: {s}", .{@errorName(err)});
    const ready = try waitJob(a, request.socket_path, decompile_reply, cancel, deadline, stage, failure);
    const document = ready.payload orelse return fail(a, failure, "sidecar_bad_reply", "ready decompile reply omitted its framed document", .{});
    stage.store(.loading, .release);
    return .{ .document = document, .elapsed_ms = @as(f64, @floatFromInt(nowNs() - begun)) / std.time.ns_per_ms };
}

/// Decompile a named function from an immutable image without inventing a
/// target process, runtime bias, stop generation, registers or live values.
pub fn runStatic(a: Allocator, endpoint: Endpoint, image_path: []const u8, display_path: []const u8, sha256: []const u8, debug_path: ?[]const u8, debug_sha256: ?[]const u8, symbol: []const u8, cancel: *const std.atomic.Value(bool), stage: *std.atomic.Value(Stage), failure: *Failure) !Result {
    const begun = nowNs();
    const deadline = begun + @as(u64, endpoint.deadline_ms) * std.time.ns_per_ms;
    try ensure(a, endpoint, cancel, deadline, stage, failure);
    stage.store(.opening, .release);
    const open_reply = call(a, endpoint.socket_path, .{ .id = "xodb-static-open", .verb = "open_image", .path = image_path, .sha256 = sha256, .debug_path = debug_path, .debug_sha256 = debug_sha256, .deadline_ms = endpoint.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else if (err == error.SidecarDied) "sidecar_died" else "sidecar_io_failed", "open_image: {s}", .{@errorName(err)});
    _ = try waitJob(a, endpoint.socket_path, open_reply, cancel, deadline, stage, failure);
    stage.store(.decompiling, .release);
    const decompile_reply = call(a, endpoint.socket_path, .{ .id = "xodb-static-decompile", .verb = "decompile", .path = display_path, .sha256 = sha256, .debug_path = debug_path, .debug_sha256 = debug_sha256, .symbol = symbol, .options = "default", .deadline_ms = endpoint.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else if (err == error.SidecarDied) "sidecar_died" else "sidecar_io_failed", "decompile: {s}", .{@errorName(err)});
    const ready = try waitJob(a, endpoint.socket_path, decompile_reply, cancel, deadline, stage, failure);
    const document = ready.payload orelse return fail(a, failure, "sidecar_bad_reply", "ready static decompile reply omitted its framed document", .{});
    stage.store(.ready, .release);
    return .{ .document = document, .elapsed_ms = @as(f64, @floatFromInt(nowNs() - begun)) / std.time.ns_per_ms };
}

pub fn prime(a: Allocator, endpoint: Endpoint, architecture: []const u8, cancel: *const std.atomic.Value(bool), stage: *std.atomic.Value(Stage), failure: *Failure) !void {
    const deadline = nowNs() + @as(u64, endpoint.deadline_ms) * std.time.ns_per_ms;
    try ensure(a, endpoint, cancel, deadline, stage, failure);
    stage.store(.decompiling, .release);
    const first = call(a, endpoint.socket_path, .{ .id = "xodb-prime", .verb = "prime", .architecture = architecture, .deadline_ms = endpoint.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else "sidecar_io_failed", "prime: {s}", .{@errorName(err)});
    _ = try waitJob(a, endpoint.socket_path, first, cancel, deadline, stage, failure);
    stage.store(.ready, .release);
}

pub fn openImage(a: Allocator, endpoint: Endpoint, image_path: []const u8, sha256: []const u8, cancel: *const std.atomic.Value(bool), stage: *std.atomic.Value(Stage), failure: *Failure) !void {
    const deadline = nowNs() + @as(u64, endpoint.deadline_ms) * std.time.ns_per_ms;
    try ensure(a, endpoint, cancel, deadline, stage, failure);
    stage.store(.opening, .release);
    const first = call(a, endpoint.socket_path, .{ .id = "xodb-warm-open", .verb = "open_image", .path = image_path, .sha256 = sha256, .background = true, .deadline_ms = endpoint.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else "sidecar_io_failed", "open_image: {s}", .{@errorName(err)});
    _ = try waitJob(a, endpoint.socket_path, first, cancel, deadline, stage, failure);
    stage.store(.ready, .release);
}

/// Low-priority decompile used only for bounded stop-time warm-ahead. The
/// caller has already opened the image; the returned document can seed direct
/// callees and is retained by the sidecar for the later foreground request.
pub fn warmDecompile(a: Allocator, endpoint: Endpoint, image_path: []const u8, sha256: []const u8, entry_value: u64, build_id: ?[]const u8, cancel: *const std.atomic.Value(bool), stage: *std.atomic.Value(Stage), failure: *Failure) ![]u8 {
    const deadline = nowNs() + @as(u64, endpoint.deadline_ms) * std.time.ns_per_ms;
    try ensure(a, endpoint, cancel, deadline, stage, failure);
    stage.store(.decompiling, .release);
    const entry = try std.fmt.allocPrint(a, "0x{x}", .{entry_value});
    const first = call(a, endpoint.socket_path, .{ .id = "xodb-warm-decompile", .verb = "decompile", .path = image_path, .sha256 = sha256, .entry = entry, .size = "0x0", .build_id = build_id, .options = "default", .background = true, .deadline_ms = endpoint.deadline_ms }, cancel, deadline) catch |err| return fail(a, failure, if (err == error.Cancelled) "cancelled" else "sidecar_io_failed", "decompile: {s}", .{@errorName(err)});
    const ready = try waitJob(a, endpoint.socket_path, first, cancel, deadline, stage, failure);
    stage.store(.ready, .release);
    return ready.payload orelse return fail(a, failure, "sidecar_bad_reply", "ready warm decompile reply omitted its framed document", .{});
}

test "sidecar stage text is stable for the UI" {
    try std.testing.expectEqualStrings("starting Ghidra", stageText(.starting));
    try std.testing.expectEqualStrings("decompiling", stageText(.decompiling));
}
