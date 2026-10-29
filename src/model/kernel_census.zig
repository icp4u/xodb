//! On-demand Linux task-stack census. No attach, tracing, signals or privilege
//! changes. A worker builds an immutable publication; only its owner swaps it.
const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("dirent.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
});
const a = std.heap.c_allocator;
pub const max_tasks = 32768;
pub const max_text = 8 * 1024 * 1024;
pub const Status = enum { ready, empty, denied, vanished, unsupported, unreadable, truncated };
pub const Task = struct {
    pid: i32,
    tid: i32,
    start_ticks: u64 = 0,
    state: u8 = '?',
    comm: []const u8 = "",
    wchan: []const u8 = "",
    group: usize = 0,
};
pub const Group = struct {
    id: usize,
    status: Status,
    stack: []const u8,
    count: usize = 0,
    d_count: usize = 0,
    first: usize = 0,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    tasks: std.ArrayList(Task) = .empty,
    groups: std.ArrayList(Group) = .empty,
    keys: std.StringHashMapUnmanaged(usize) = .empty,
    started_ns: u64 = 0,
    finished_ns: u64 = 0,
    denied: usize = 0,
    vanished: usize = 0,
    unreadable: usize = 0,
    truncated: bool = false,
    text_bytes: usize = 0,
    failure: ?[]const u8 = null,

    pub fn init() Snapshot {
        return .{ .arena = .init(a) };
    }
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
    fn save(self: *Snapshot, value: []const u8) ![]const u8 {
        if (value.len > max_text - self.text_bytes) return error.CensusTextLimit;
        const result = try self.arena.allocator().dupe(u8, value);
        self.text_bytes += value.len;
        return result;
    }
    fn saveName(self: *Snapshot, value: []const u8) ![]const u8 {
        const saved = try self.save(value);
        // comm is arbitrary target bytes; keep JSON and the renderer valid.
        for (@constCast(saved)) |*byte| if (byte.* < 32 or byte.* >= 127) {
            byte.* = '?';
        };
        return saved;
    }
    pub fn add(self: *Snapshot, task_: Task, status: Status, stack: []const u8) !void {
        if (self.tasks.items.len == max_tasks) return error.CensusTaskLimit;
        const alloc = self.arena.allocator();
        var key_buf: [8256]u8 = undefined;
        // Empty/unreadable stacks are explicitly labelled, never a real stack.
        const key = try std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ @tagName(status), stack });
        const id = self.keys.get(key) orelse blk: {
            const saved = try self.save(key);
            const id = self.groups.items.len;
            try self.groups.append(alloc, .{ .id = id, .status = status, .stack = saved[@tagName(status).len + 1 ..] });
            try self.keys.put(alloc, saved, id);
            break :blk id;
        };
        var task = task_;
        task.comm = try self.saveName(task.comm);
        task.wchan = try self.saveName(task.wchan);
        task.group = id;
        try self.tasks.append(alloc, task);
        self.groups.items[id].count += 1;
        self.groups.items[id].d_count += @intFromBool(task.state == 'D');
        switch (status) {
            .denied => self.denied += 1,
            .vanished => self.vanished += 1,
            .unreadable, .unsupported => self.unreadable += 1,
            .truncated => self.truncated = true,
            else => {},
        }
    }
    pub fn finish(self: *Snapshot) !void {
        std.mem.sort(Group, self.groups.items, {}, struct {
            fn less(_: void, x: Group, y: Group) bool {
                if ((x.d_count > 0) != (y.d_count > 0)) return x.d_count > 0;
                if (x.d_count != y.d_count) return x.d_count > y.d_count;
                if (x.count != y.count) return x.count > y.count;
                const order = std.mem.order(u8, x.stack, y.stack);
                if (order != .eq) return order == .lt;
                return @intFromEnum(x.status) < @intFromEnum(y.status);
            }
        }.less);
        const rank = try self.arena.allocator().alloc(usize, self.groups.items.len);
        var offset: usize = 0;
        for (self.groups.items, 0..) |*g, i| {
            rank[g.id] = i;
            g.first = offset;
            offset += g.count;
        }
        std.mem.sort(Task, self.tasks.items, rank, struct {
            fn less(order: []usize, x: Task, y: Task) bool {
                if (x.group != y.group) return order[x.group] < order[y.group];
                return if (x.pid != y.pid) x.pid < y.pid else x.tid < y.tid;
            }
        }.less);
        self.finished_ns = now();
    }
};

pub fn now() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn ioError() anyerror {
    return switch (std.posix.errno(@as(c_int, -1))) {
        .ACCES, .PERM => error.AccessDenied,
        .NOENT, .SRCH => error.FileNotFound,
        else => error.ProcReadFailed,
    };
}
pub const Dir = struct {
    fd: c_int,
    pub fn open(path: [:0]const u8) !Dir {
        const fd = c.open(path, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return ioError();
        return .{ .fd = fd };
    }
    fn openDir(self: Dir, path: []const u8) !Dir {
        var buf: [128]u8 = undefined;
        const z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
        const fd = c.openat(self.fd, z, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return ioError();
        return .{ .fd = fd };
    }
    pub fn close(self: Dir) void {
        _ = c.close(self.fd);
    }
    fn iterate(self: Dir) !Iterator {
        const fd = c.openat(self.fd, ".", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (fd < 0) return ioError();
        const dir = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            return ioError();
        };
        return .{ .dir = dir };
    }
    const Iterator = struct {
        dir: *c.DIR,
        fn deinit(self: *Iterator) void {
            _ = c.closedir(self.dir);
        }
        fn next(self: *Iterator) !?[]const u8 {
            std.c._errno().* = 0;
            const entry = c.readdir(self.dir) orelse {
                if (std.c._errno().* != 0) return ioError();
                return null;
            };
            return std.mem.sliceTo(entry.*.d_name[0..], 0);
        }
    };
};
fn read(dir: Dir, path: [:0]const u8, buf: []u8) ![]const u8 {
    const fd = c.openat(dir.fd, path, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return ioError();
    defer _ = c.close(fd);
    var used: usize = 0;
    while (used < buf.len) {
        const n = c.read(fd, buf[used..].ptr, buf.len - used);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return ioError();
        }
        if (n == 0) break;
        used += @intCast(n);
    }
    return buf[0..used];
}
fn statusFor(err: anyerror) Status {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => .denied,
        error.FileNotFound, error.ProcessNotFound => .vanished,
        else => .unreadable,
    };
}

/// stat's comm may contain spaces and parentheses; field 22 is starttime.
pub fn parseStat(raw: []const u8, task: *Task) !void {
    const open = std.mem.indexOfScalar(u8, raw, '(') orelse return error.BadTaskStat;
    const close = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return error.BadTaskStat;
    if (close <= open) return error.BadTaskStat;
    task.comm = raw[open + 1 .. close];
    var fields = std.mem.tokenizeAny(u8, raw[close + 1 ..], " \t\n");
    const state = fields.next() orelse return error.BadTaskStat;
    if (state.len != 1) return error.BadTaskStat;
    task.state = state[0];
    for (0..18) |_| _ = fields.next() orelse return error.BadTaskStat;
    task.start_ticks = try std.fmt.parseInt(u64, fields.next() orelse return error.BadTaskStat, 10);
}

/// Drop kernel address prefixes (often masked) but keep ordered symbols,
/// offsets and module names. Do not merge different call sites.
pub fn normalize(raw: []const u8, out: []u8) ![]const u8 {
    var used: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_| {
        var line = std.mem.trim(u8, line_, " \t\r");
        if (std.mem.startsWith(u8, line, "[<")) {
            if (std.mem.indexOf(u8, line, ">]")) |end| line = std.mem.trimStart(u8, line[end + 2 ..], " \t");
        }
        if (line.len == 0) continue;
        if (line.len + 1 > out.len - used) return error.CensusStackLimit;
        for (line) |byte| {
            out[used] = if (byte >= 32 and byte < 127) byte else '?';
            used += 1;
        }
        out[used] = '\n';
        used += 1;
    }
    return out[0..used];
}

fn sampleTask(s: *Snapshot, dir: Dir, pid: i32, tid: i32) !void {
    var task = Task{ .pid = pid, .tid = tid };
    var stat_buf: [4096]u8 = undefined;
    const stat = read(dir, "stat", &stat_buf) catch |err| {
        try s.add(task, statusFor(err), "");
        return;
    };
    parseStat(stat, &task) catch {
        try s.add(task, .unreadable, "");
        return;
    };
    var wchan_buf: [256]u8 = undefined;
    task.wchan = std.mem.trim(u8, read(dir, "wchan", &wchan_buf) catch "", " \n\t");
    // The kernel prints "0" for no symbol and for a ptrace-access refusal.
    if (std.mem.eql(u8, task.wchan, "0")) task.wchan = "";
    var stack_buf: [8192]u8 = undefined;
    var normalized: [8192]u8 = undefined;
    const raw = read(dir, "stack", &stack_buf) catch |err| {
        var state = statusFor(err);
        if (state == .vanished) {
            var probe: [4096]u8 = undefined;
            var after = Task{ .pid = pid, .tid = tid };
            if (read(dir, "stat", &probe)) |text| {
                parseStat(text, &after) catch {};
                if (after.start_ticks == task.start_ticks) state = .unsupported;
            } else |_| {}
        }
        try s.add(task, state, "");
        return;
    };
    var state: Status = if (raw.len == stack_buf.len) .truncated else .ready;
    const stack = normalize(raw, &normalized) catch blk: {
        state = .truncated;
        break :blk "";
    };
    if (stack.len == 0 and state == .ready) state = .empty;
    // A census is not an atomic stop. Reject a task that vanished/reused its ID
    // during this read rather than attach its old name to a different stack.
    var after_buf: [4096]u8 = undefined;
    var after = Task{ .pid = pid, .tid = tid };
    const after_raw = read(dir, "stat", &after_buf) catch {
        try s.add(task, .vanished, "");
        return;
    };
    parseStat(after_raw, &after) catch return s.add(task, .unreadable, "");
    if (after.start_ticks != task.start_ticks) return s.add(task, .vanished, "");
    try s.add(task, state, stack);
}

pub fn identityMatches(task: Task) bool {
    var path: [96]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}", .{ task.pid, task.tid }) catch return false;
    var dir = Dir.open(name) catch return false;
    defer dir.close();
    var buf: [4096]u8 = undefined;
    var current = Task{ .pid = task.pid, .tid = task.tid };
    parseStat(read(dir, "stat", &buf) catch return false, &current) catch return false;
    return task.start_ticks != 0 and current.start_ticks == task.start_ticks;
}

fn process(s: *Snapshot, root: Dir, pid: i32, stop: *const std.atomic.Value(bool), deadline: u64) !void {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{d}/task", .{pid});
    var tasks = root.openDir(path) catch |err| {
        try s.add(.{ .pid = pid, .tid = pid }, statusFor(err), "");
        return;
    };
    defer tasks.close();
    var it = try tasks.iterate();
    defer it.deinit();
    while (try it.next()) |entry| {
        if (stop.load(.acquire) or now() > deadline) return error.CensusTimeLimit;
        const tid = std.fmt.parseInt(i32, entry, 10) catch continue;
        if (tid <= 0) continue;
        var dir = tasks.openDir(entry) catch |err| {
            try s.add(.{ .pid = pid, .tid = tid }, statusFor(err), "");
            continue;
        };
        defer dir.close();
        try sampleTask(s, dir, pid, tid);
    }
}

/// root is injectable only by component tests, never by an MCP caller.
pub fn collect(root: Dir, pid: ?i32, stop: *const std.atomic.Value(bool)) !Snapshot {
    var s = Snapshot.init();
    errdefer s.deinit();
    s.started_ns = now();
    const deadline = s.started_ns + 5 * std.time.ns_per_s;
    collectInto(&s, root, pid, stop, deadline) catch |err| switch (err) {
        error.CensusTimeLimit, error.CensusTextLimit, error.CensusTaskLimit => s.truncated = true,
        else => s.failure = @errorName(err),
    };
    try s.finish();
    return s;
}
fn collectInto(s: *Snapshot, root: Dir, pid: ?i32, stop: *const std.atomic.Value(bool), deadline: u64) !void {
    if (pid) |id| return process(s, root, id, stop, deadline);
    var it = try root.iterate();
    defer it.deinit();
    while (try it.next()) |entry| {
        if (stop.load(.acquire) or now() > deadline) return error.CensusTimeLimit;
        const id = std.fmt.parseInt(i32, entry, 10) catch continue;
        if (id > 0) try process(s, root, id, stop, deadline);
    }
}

pub const Cache = struct {
    pid: ?i32 = null,
    current: ?Snapshot = null,
    job: ?*Job = null,
    sequence: u64 = 0,
    next_ns: u64 = 0,
    failure: ?[]const u8 = null,
    const Job = struct {
        thread: ?std.Thread = null,
        done: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        pid: ?i32,
        result: ?Snapshot = null,
        failure: ?[]const u8 = null,
        fn run(j: *Job) void {
            defer j.done.store(true, .release);
            if (builtin.os.tag != .linux) {
                j.failure = "LinuxOnly";
                return;
            }
            var root = Dir.open("/proc") catch |err| {
                j.failure = @errorName(err);
                return;
            };
            defer root.close();
            j.result = collect(root, j.pid, &j.stop) catch |err| {
                j.failure = @errorName(err);
                return;
            };
        }
    };
    pub fn deinit(self: *Cache) void {
        if (self.job) |j| {
            j.stop.store(true, .release);
            j.thread.?.join();
            if (j.result) |*s| s.deinit();
            a.destroy(j);
        }
        if (self.current) |*s| s.deinit();
        self.* = .{};
    }
    pub fn poll(self: *Cache) bool {
        const j = self.job orelse return false;
        if (!j.done.load(.acquire)) return false;
        j.thread.?.join();
        if (self.current) |*s| s.deinit();
        self.current = j.result;
        self.failure = j.failure;
        self.job = null;
        a.destroy(j);
        self.sequence += 1;
        self.next_ns = now() + std.time.ns_per_s;
        return true;
    }
    pub fn request(self: *Cache) !void {
        _ = self.poll();
        if (self.job != null or now() < self.next_ns) return;
        const j = try a.create(Job);
        errdefer a.destroy(j);
        j.* = .{ .pid = self.pid };
        j.thread = try std.Thread.spawn(.{}, Job.run, .{j});
        self.job = j;
    }
};

test "kernel census keeps callsites, groups identical stacks, and puts D first" {
    var s = Snapshot.init();
    defer s.deinit();
    var buf: [256]u8 = undefined;
    const stack = try normalize("[<0000000000000000>] io_schedule+0x1/0x20\n[<abcdef>] wait+0x2/0x40 [test]\n", &buf);
    try s.add(.{ .pid = 1, .tid = 1, .state = 'S' }, .ready, "wait+0x1\n");
    try s.add(.{ .pid = 2, .tid = 2, .state = 'S' }, .ready, "wait+0x1\n");
    try s.add(.{ .pid = 3, .tid = 3, .state = 'D' }, .ready, stack);
    try s.add(.{ .pid = 3, .tid = 4, .state = 'S' }, .ready, stack);
    try s.add(.{ .pid = 4, .tid = 4 }, .ready, "wait+0x2\n");
    try s.add(.{ .pid = 5, .tid = 5 }, .denied, "");
    try s.add(.{ .pid = 6, .tid = 6 }, .empty, "");
    try s.finish();
    try std.testing.expectEqual(@as(usize, 5), s.groups.items.len);
    try std.testing.expectEqual(@as(usize, 2), s.groups.items[0].count);
    try std.testing.expectEqual(@as(usize, 1), s.groups.items[0].d_count);
    try std.testing.expectEqualStrings("io_schedule+0x1/0x20\nwait+0x2/0x40 [test]\n", s.groups.items[0].stack);
    try std.testing.expectEqual(@as(usize, 1), s.denied);
}

test "kernel census live scope and stat parsing" {
    var task = Task{ .pid = 42, .tid = 43 };
    try parseStat("43 (a ) name) D 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 12345 20\n", &task);
    try std.testing.expectEqualStrings("a ) name", task.comm);
    try std.testing.expectEqual(@as(u64, 12345), task.start_ticks);
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var dir = try Dir.open("/proc");
    defer dir.close();
    var stop = std.atomic.Value(bool).init(false);
    var s = try collect(dir, c.getpid(), &stop);
    defer s.deinit();
    try std.testing.expect(s.failure == null);
    try std.testing.expect(s.tasks.items.len > 0);
    for (s.tasks.items) |task_| try std.testing.expectEqual(c.getpid(), task_.pid);
    var cache = Cache{ .pid = c.getpid() };
    defer cache.deinit();
    try cache.request();
}

fn fixtureFile(dir: Dir, name: [:0]const u8, text: []const u8) !void {
    const fd = c.openat(dir.fd, name, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c_uint, 0o644));
    if (fd < 0) return error.FixtureOpen;
    defer _ = c.close(fd);
    if (c.write(fd, text.ptr, text.len) != text.len) return error.FixtureWrite;
}

test "kernel census synthetic procfs, unavailable is not empty, bounded collection" {
    var path = "/tmp/xodb-census-test-XXXXXX".* ++ [_]u8{0};
    _ = c.mkdtemp(&path) orelse return error.FixtureDirectory;
    _ = c.chmod(&path, 0o755);
    defer _ = c.rmdir(&path);
    var root = try Dir.open(std.mem.sliceTo(path[0..], 0));
    defer root.close();
    try fixtureFile(root, "stat", "42 (test worker) D 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 99\n");
    defer _ = c.unlinkat(root.fd, "stat", 0);
    try fixtureFile(root, "wchan", "test_wait\n");
    defer _ = c.unlinkat(root.fd, "wchan", 0);
    try fixtureFile(root, "stack", "[<0>] test_wait+0x1/0x20\n[<0>] test_entry+0x2/0x40\n");
    defer _ = c.unlinkat(root.fd, "stack", 0);
    var s = Snapshot.init();
    defer s.deinit();
    try sampleTask(&s, root, 42, 42);
    try std.testing.expectEqual(Status.ready, s.groups.items[0].status);
    try std.testing.expectEqualStrings("test_wait+0x1/0x20\ntest_entry+0x2/0x40\n", s.groups.items[0].stack);
    try std.testing.expectEqualStrings("test worker", s.tasks.items[0].comm);
    try std.testing.expectEqualStrings("test_wait", s.tasks.items[0].wchan);
    try std.testing.expectEqual(@as(u64, 99), s.tasks.items[0].start_ticks);
    try fixtureFile(root, "stack", "");
    try fixtureFile(root, "wchan", "0");
    try sampleTask(&s, root, 42, 43);
    try std.testing.expectEqual(Status.empty, s.groups.items[1].status);
    try std.testing.expectEqualStrings("", s.tasks.items[1].wchan);
    _ = c.unlinkat(root.fd, "stack", 0);
    try sampleTask(&s, root, 42, 44);
    try std.testing.expectEqual(Status.unsupported, s.groups.items[2].status);
    const long = [_]u8{'a'} ** 8192;
    try fixtureFile(root, "stack", &long);
    try sampleTask(&s, root, 42, 45);
    try std.testing.expect(s.truncated);
    try std.testing.expectEqual(Status.truncated, s.groups.items[3].status);
    try std.testing.expectEqual(Status.denied, statusFor(error.AccessDenied));
    try std.testing.expectEqual(Status.vanished, statusFor(error.FileNotFound));
    _ = c.unlinkat(root.fd, "stat", 0);
    try sampleTask(&s, root, 42, 46);
    try std.testing.expectEqual(@as(usize, 1), s.vanished);
    var bounded = Snapshot.init();
    defer bounded.deinit();
    for (0..max_tasks) |i| try bounded.add(.{ .pid = 1, .tid = @intCast(i + 1) }, .empty, "");
    try std.testing.expectError(error.CensusTaskLimit, bounded.add(.{ .pid = 2, .tid = 2 }, .empty, ""));
    try std.testing.expectEqual(@as(usize, max_tasks), bounded.tasks.items.len);
    bounded.text_bytes = max_text;
    try std.testing.expectError(error.CensusTextLimit, bounded.save("x"));
}
