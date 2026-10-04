//! Task-scoped raw_syscalls probe. One enter fd and one exit fd, inherit off,
//! cpu -1, no child enrollment. PERF_SAMPLE_RAW is decoded with the documented
//! layout and the argument words are not stored. A config of 0 is only an
//! inventory open: it is closed without being enabled.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const obs = @import("syscall_obs.zig");

const data_pages: usize = 16;
var recent_errno: i32 = 0;

fn note(rc: usize) i32 {
    const err = errnoOf(rc);
    if (err != 0) recent_errno = err;
    return err;
}
const max_sides: usize = 4096;
const max_events: usize = 8192;
const max_spans: usize = 2048;

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [768]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = linux.write(1, text.ptr, text.len);
}

fn cstr(bytes: []const u8) []const u8 {
    const n = std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len;
    return bytes[0..n];
}

fn errnoOf(rc: usize) i32 {
    const err = linux.errno(rc);
    if (err == .SUCCESS) return 0;
    return @intFromEnum(err);
}

fn openErrno(path: [*:0]const u8) i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const err = errnoOf(rc);
    if (err == 0) _ = linux.close(@intCast(rc));
    return err;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

fn mono() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn parseU64(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var v: u64 = 0;
    for (text) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    return v;
}

fn load64(map: []const u8, off: usize) u64 {
    const ptr: *const u64 = @alignCast(@ptrCast(map.ptr + off));
    return @atomicLoad(u64, ptr, .acquire);
}

fn storeTail(map: []u8, tail: u64) void {
    const ptr: *u64 = @alignCast(@ptrCast(map.ptr + 1032));
    @atomicStore(u64, ptr, tail, .seq_cst);
}

fn readPlain(map: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, map[off..][0..8], .little);
}

const Owned = struct {
    fds: [8]i32 = .{-1} ** 8,
    nfd: u8 = 0,
    maps: [2]struct { ptr: ?[*]u8 = null, len: usize = 0 } = .{ .{}, .{} },
    child: i32 = -1,
    closed: u8 = 0,

    fn addFd(self: *Owned, fd: i32) void {
        if (self.nfd < self.fds.len) {
            self.fds[self.nfd] = fd;
            self.nfd += 1;
        }
    }

    fn finish(self: *Owned) void {
        if (self.child > 0) {
            _ = linux.kill(self.child, linux.SIG.KILL);
            var status: u32 = 0;
            var spins: u16 = 0;
            while (spins < 1000) : (spins += 1) {
                const rc = linux.waitpid(self.child, &status, linux.W.NOHANG);
                const err = linux.errno(rc);
                if (err == .INTR) continue;
                if (err == .SUCCESS or err == .CHILD) break;
            }
            self.child = -1;
        }
        for (&self.maps) |*mapped| {
            if (mapped.ptr) |ptr| {
                _ = linux.munmap(ptr, mapped.len);
                mapped.ptr = null;
            }
        }
        for (self.fds[0..self.nfd]) |fd| {
            if (fd >= 0) {
                _ = linux.close(fd);
                self.closed += 1;
            }
        }
        self.nfd = 0;
    }
};

fn inventory() u8 {
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    print("RESULT identity machine={s} kernel={s} page={d}\n", .{ @tagName(builtin.cpu.arch), cstr(&uts.release), std.heap.pageSize() });
    var buf: [128]u8 = undefined;
    if (readFile("/proc/sys/kernel/perf_event_paranoid", &buf)) |text| {
        print("RESULT paranoid {s}", .{text});
        if (text.len == 0 or text[text.len - 1] != '\n') print("\n", .{});
    } else print("RESULT paranoid unreadable\n", .{});
    if (readFile("/proc/sys/kernel/perf_event_mlock_kb", &buf)) |text| {
        print("RESULT mlock_kb {s}", .{text});
        if (text.len == 0 or text[text.len - 1] != '\n') print("\n", .{});
    }
    var status_buf: [1024]u8 = undefined;
    if (readFile("/proc/self/status", &status_buf)) |text| {
        var line_start: usize = 0;
        while (line_start < text.len) {
            var line_end = line_start;
            while (line_end < text.len and text[line_end] != '\n') line_end += 1;
            const line = text[line_start..line_end];
            if (std.mem.startsWith(u8, line, "CapEff:") or std.mem.startsWith(u8, line, "CapPrm:")) {
                print("RESULT {s}\n", .{line});
            }
            line_start = line_end + 1;
        }
    }
    const paths = [_][*:0]const u8{
        "/sys/kernel/tracing/events/raw_syscalls/sys_enter/id",
        "/sys/kernel/tracing/events/raw_syscalls/sys_exit/id",
        "/sys/kernel/debug/tracing/events/raw_syscalls/sys_enter/id",
        "/sys/kernel/debug/tracing/events/raw_syscalls/sys_exit/id",
    };
    for (paths) |path| print("RESULT id_path path={s} errno={d}\n", .{ cstr(std.mem.span(path)), openErrno(path) });

    var attr = std.mem.zeroes(linux.perf_event_attr);
    attr.type = .TRACEPOINT;
    attr.size = obs.attr_size_through_clockid;
    attr.config = 0;
    attr.sample_period_or_freq = 1;
    attr.sample_type = obs.sample_type;
    attr.flags.disabled = true;
    attr.flags.inherit = false;
    attr.flags.exclude_hv = true;
    attr.flags.sample_id_all = true;
    attr.flags.use_clockid = true;
    attr.clockid = .MONOTONIC;
    const flags_word: u64 = @bitCast(attr.flags);
    const tid: i32 = @intCast(linux.gettid());
    const opened = linux.perf_event_open(&attr, tid, -1, -1, 8);
    const err = errnoOf(opened);
    var closed: u8 = 0;
    if (err == 0) {
        _ = linux.close(@intCast(opened));
        closed = 1;
    }
    print("RESULT id_probe status={s} errno={d} inherit={d} cpu=-1 tid={d} config=0 exclude_kernel=0 closed={d} enabled=0\n", .{
        if (err == 0) "opened_closed" else "refused",
        err,
        (flags_word >> 1) & 1,
        tid,
        closed,
    });
    // Diagnostic only. exclude_kernel skips perf_allow_kernel, but a kernel
    // syscall tracepoint would then be dropped. config 0 is not enabled.
    attr.flags.exclude_kernel = true;
    const opened_ex = linux.perf_event_open(&attr, tid, -1, -1, 8);
    const err_ex = errnoOf(opened_ex);
    var closed_ex: u8 = 0;
    if (err_ex == 0) {
        _ = linux.close(@intCast(opened_ex));
        closed_ex = 1;
    }
    print("RESULT id_probe status={s} errno={d} inherit=0 cpu=-1 tid={d} config=0 exclude_kernel=1 closed={d} enabled=0\n", .{
        if (err_ex == 0) "opened_closed" else "refused",
        err_ex,
        tid,
        closed_ex,
    });
    return 0;
}

const DrainStatus = enum { ok, malformed, overwritten, truncated };

fn drain(map: []u8, linear: []u8, kind: obs.Kind, expect_id: ?u64, tid: i32, sides: []obs.Side, count: *usize) DrainStatus {
    if (map.len < 1056) return .malformed;
    const head = load64(map, 1024);
    const tail = load64(map, 1032);
    const data_off = readPlain(map, 1040);
    const data_size = readPlain(map, 1048);
    if (data_size == 0 or data_off + data_size > map.len) return .malformed;
    if (head < tail) return .malformed;
    const avail = head - tail;
    if (avail > data_size) {
        storeTail(map, head);
        return .overwritten;
    }
    if (avail > linear.len) {
        storeTail(map, head);
        return .truncated;
    }
    var left = avail;
    var src = tail % data_size;
    var dst: usize = 0;
    while (left > 0) {
        const chunk = @min(left, data_size - src);
        @memcpy(linear[dst .. dst + chunk], map[data_off + src ..][0 .. chunk]);
        dst += chunk;
        src = 0;
        left -= chunk;
    }
    var off: usize = 0;
    var status: DrainStatus = .ok;
    while (off + 8 <= dst) {
        const size = std.mem.readInt(u16, linear[off + 6 ..][0..2], .little);
        if (size < 8 or off + size > dst) {
            status = .truncated;
            break;
        }
        const decoded = obs.decodeRecord(linear[off .. off + size], kind, expect_id, obs.documented_layout) catch {
            status = .truncated;
            break;
        };
        const side: ?obs.Side = switch (decoded) {
            .syscall => |syscall| .{
                .time_ns = syscall.time_ns,
                .rank = if (syscall.kind == .enter) 0 else 3,
                .event = if (syscall.kind == .enter)
                    .{ .enter = .{ .tid = syscall.tid, .nr = syscall.raw.nr, .time_ns = syscall.time_ns } }
                else
                    .{ .exit = .{ .tid = syscall.tid, .nr = syscall.raw.nr, .ret = syscall.raw.ret orelse 0, .time_ns = syscall.time_ns } },
            },
            .lost => |lost| .{
                .time_ns = lost.time_ns orelse 0,
                .rank = 4,
                .event = .{ .loss = .{ .tid = lost.tid, .lost = lost.lost } },
            },
            .fork => |fork| .{ .time_ns = fork.time_ns, .rank = 1, .event = .{ .fork = .{ .parent_tid = fork.parent_tid, .child_tid = fork.child_tid } } },
            .thread_exit => |exit| .{ .time_ns = exit.time_ns, .rank = 5, .event = .{ .thread_exit = .{ .tid = exit.tid, .time_ns = exit.time_ns } } },
            .skipped => null,
        };
        if (side) |item| {
            if (count.* >= sides.len) {
                status = .truncated;
                break;
            }
            sides[count.*] = item;
            count.* += 1;
        }
        off += size;
    }
    storeTail(map, head);
    if (status == .truncated) {
        if (count.* < sides.len) {
            sides[count.*] = .{ .time_ns = std.math.maxInt(u64), .rank = 6, .event = .{ .truncated = .{ .tid = tid } } };
            count.* += 1;
        }
    }
    return status;
}

fn eventId(fd: i32) ?u64 {
    var id: u64 = 0;
    const req = linux.IOCTL.IOR('$', 7, u64);
    const rc = linux.ioctl(fd, req, @intFromPtr(&id));
    if (linux.errno(rc) != .SUCCESS) return null;
    return id;
}

/// dup until the result is at least `min`. The returned fd is a new descriptor,
/// so closing the original pipe ends cannot close it.
fn dupAtLeast(src: i32, min: i32) i32 {
    const latest_rc = linux.dup(src);
    if (errnoOf(latest_rc) != 0) linux.exit_group(126);
    var latest: i32 = @intCast(latest_rc);
    var guard: u8 = 0;
    while (latest < min) : (guard += 1) {
        if (guard == 16) linux.exit_group(126);
        const next_rc = linux.dup(latest);
        if (errnoOf(next_rc) != 0) linux.exit_group(126);
        _ = linux.close(latest);
        latest = @intCast(next_rc);
    }
    return latest;
}

/// Ready-write on fd 3 and go-read on fd 4. Holds are taken first so a later
/// close of the inherited pipe numbers cannot close 3 or 4.
fn installChildSync(ready: *const [2]i32, go: *const [2]i32) void {
    const hold_ready = dupAtLeast(ready[1], 8);
    const hold_go = dupAtLeast(go[0], 8);
    _ = linux.close(ready[0]);
    _ = linux.close(ready[1]);
    _ = linux.close(go[0]);
    _ = linux.close(go[1]);
    if (errnoOf(linux.dup2(hold_ready, 3)) != 0) linux.exit_group(126);
    if (errnoOf(linux.dup2(hold_go, 4)) != 0) linux.exit_group(126);
    if (hold_ready != 3) _ = linux.close(hold_ready);
    if (hold_go != 4 and hold_go != hold_ready) _ = linux.close(hold_go);
}

fn spawnSynced(fixture: [:0]const u8, scratch: [:0]const u8, mode: [:0]const u8, ready: *[2]i32, go: *[2]i32) ?i32 {
    if (linux.errno(linux.pipe2(ready, .{})) != .SUCCESS) return null;
    if (linux.errno(linux.pipe2(go, .{})) != .SUCCESS) {
        _ = linux.close(ready[0]);
        _ = linux.close(ready[1]);
        ready[0] = -1;
        ready[1] = -1;
        return null;
    }
    const fork_rc = linux.fork();
    if (linux.errno(fork_rc) != .SUCCESS) return null;
    if (fork_rc == 0) {
        installChildSync(ready, go);
        const argv = [_:null]?[*:0]const u8{ fixture, "--sync", mode, scratch, null };
        const envp = [_:null]?[*:0]const u8{ "PATH=/usr/bin:/bin", "LANG=C", null };
        _ = linux.execve(fixture, &argv, &envp);
        linux.exit_group(127);
    }
    _ = linux.close(ready[1]);
    ready[1] = -1;
    _ = linux.close(go[0]);
    go[0] = -1;
    return @intCast(fork_rc);
}

fn awaitReady(ready_read: i32) bool {
    var poll_fd = linux.pollfd{ .fd = ready_read, .events = linux.POLL.IN, .revents = 0 };
    const polled = linux.poll(@as([*]linux.pollfd, @ptrCast(&poll_fd)), 1, 5000);
    var ready_byte: [1]u8 = undefined;
    return linux.errno(polled) == .SUCCESS and (poll_fd.revents & linux.POLL.IN) != 0 and linux.read(ready_read, &ready_byte, 1) == 1;
}

fn releaseGo(go_write: i32) bool {
    const poke = [_]u8{'G'};
    return linux.write(go_write, &poke, 1) == 1;
}

fn openTrace(attr_config: u64, tid: i32, owned: *Owned) ?i32 {
    const request = obs.taskRequest(tid, attr_config);
    obs.validateScope(request) catch {
        recent_errno = 22;
        return null;
    };
    var attr = std.mem.zeroes(linux.perf_event_attr);
    attr.type = .TRACEPOINT;
    attr.size = request.size;
    attr.config = request.config;
    attr.sample_period_or_freq = 1;
    attr.sample_type = request.sample_type;
    attr.flags.disabled = true;
    attr.flags.inherit = false;
    attr.flags.exclude_hv = true;
    attr.flags.sample_id_all = true;
    attr.flags.use_clockid = true;
    attr.clockid = .MONOTONIC;
    attr.wakeup_events_or_watermark = 1;
    const opened = linux.perf_event_open(&attr, tid, -1, -1, 8);
    if (note(opened) != 0) return null;
    const fd: i32 = @intCast(opened);
    owned.addFd(fd);
    return fd;
}

fn run(fixture: [:0]const u8, scratch: [:0]const u8, mode: [:0]const u8, enter_id: u64, exit_id: u64) u8 {
    var owned = Owned{};
    defer owned.finish();
    var ready: [2]i32 = .{-1} ** 2;
    var go: [2]i32 = .{-1} ** 2;
    defer {
        if (ready[0] >= 0) _ = linux.close(ready[0]);
        if (ready[1] >= 0) _ = linux.close(ready[1]);
        if (go[0] >= 0) _ = linux.close(go[0]);
        if (go[1] >= 0) _ = linux.close(go[1]);
    }
    const child = spawnSynced(fixture, scratch, mode, &ready, &go) orelse {
        print("RESULT trace mode={s} status=error stage=spawn\n", .{mode});
        return 1;
    };
    owned.child = child;
    if (!awaitReady(ready[0])) {
        print("RESULT trace mode={s} status=error stage=ready child={d}\n", .{ mode, child });
        return 1;
    }
    const enter_fd = openTrace(enter_id, child, &owned) orelse {
        print("RESULT trace mode={s} status=refused stage=enter errno={d} tid={d} inherit=0 tracked_fds={d}\n", .{ mode, recent_errno, child, owned.nfd });
        return 0;
    };
    const exit_fd = openTrace(exit_id, child, &owned) orelse {
        print("RESULT trace mode={s} status=refused stage=exit errno={d} tid={d} inherit=0 tracked_fds={d}\n", .{ mode, recent_errno, child, owned.nfd });
        return 0;
    };
    const enter_event = eventId(enter_fd);
    const exit_event = eventId(exit_fd);
    const page = std.heap.pageSize();
    const map_len = page * (1 + data_pages);
    const enter_map = mapFd(enter_fd, map_len) orelse {
        print("RESULT trace mode={s} status=error stage=mmap errno={d}\n", .{ mode, recent_errno });
        return 1;
    };
    owned.maps[0] = .{ .ptr = enter_map, .len = map_len };
    const exit_map = mapFd(exit_fd, map_len) orelse {
        print("RESULT trace mode={s} status=error stage=mmap errno={d}\n", .{ mode, recent_errno });
        return 1;
    };
    owned.maps[1] = .{ .ptr = exit_map, .len = map_len };
    const enable = linux.IOCTL.IO('$', 0);
    const disable = linux.IOCTL.IO('$', 1);
    const enabled_enter = linux.ioctl(enter_fd, enable, 0);
    const enabled_exit = linux.ioctl(exit_fd, enable, 0);
    if (note(enabled_enter) != 0 or note(enabled_exit) != 0) {
        print("RESULT trace mode={s} status=error stage=enable errno={d}\n", .{ mode, recent_errno });
        return 1;
    }
    const go_ns = mono();
    if (!releaseGo(go[1])) {
        print("RESULT trace mode={s} status=error stage=go\n", .{mode});
        return 1;
    }
    const reaped = reap(child, 5_000_000_000);
    owned.child = -1;
    _ = linux.ioctl(enter_fd, disable, 0);
    _ = linux.ioctl(exit_fd, disable, 0);
    const allocator = std.heap.page_allocator;
    const sides = allocator.alloc(obs.Side, max_sides) catch return 1;
    defer allocator.free(sides);
    const events = allocator.alloc(obs.Event, max_events) catch return 1;
    defer allocator.free(events);
    const spans = allocator.alloc(obs.Span, max_spans) catch return 1;
    defer allocator.free(spans);
    const linear = allocator.alloc(u8, page * data_pages) catch return 1;
    defer allocator.free(linear);
    var enter_n: usize = 0;
    var exit_n: usize = 0;
    const enter_status = drain(enter_map[0..map_len], linear, .enter, enter_event, child, sides, &enter_n);
    const exit_status = drain(exit_map[0..map_len], linear, .exit, exit_event, child, sides[enter_n..], &exit_n);
    const merged = obs.merge(sides[0..enter_n], sides[enter_n .. enter_n + exit_n], events) catch |err| {
        print("RESULT trace mode={s} status={s} enter={s} exit={s} tid={d} go_ns={d} reaped={d}\n", .{
            mode, @errorName(err), @tagName(enter_status), @tagName(exit_status), child, go_ns, @intFromBool(reaped),
        });
        return if (err == error.Contradictory) 0 else 1;
    };
    var machine = obs.Machine.init(spans);
    machine.select(child, 1, 0) catch {
        print("RESULT trace mode={s} status=error stage=select\n", .{mode});
        return 1;
    };
    var i: usize = 0;
    while (i < merged) : (i += 1) machine.feed(events[i]);
    if (!reaped) machine.feed(.{ .thread_exit = .{ .tid = child, .time_ns = mono() } });
    machine.finish();
    var complete_after: u32 = 0;
    var unknown_after: u32 = 0;
    var foreign: u32 = 0;
    var best_nr: i64 = -1;
    var best_elapsed: u64 = 0;
    var elapsed_after: u64 = 0;
    for (spans[0..machine.span_count]) |span| {
        if (span.tid != child) foreign += 1;
        const entry = span.entry_ns orelse continue;
        if (entry < go_ns) continue;
        if (span.validity == .elapsed) {
            complete_after += 1;
            const elapsed = span.elapsed_ns orelse 0;
            elapsed_after +|= elapsed;
            if (elapsed >= best_elapsed) {
                best_elapsed = elapsed;
                best_nr = span.nr;
            }
        } else unknown_after += 1;
    }
    const sum = machine.summary(.{ .from_ns = go_ns, .to_ns = std.math.maxInt(u64) }) catch {
        print("RESULT trace mode={s} status=error stage=summary\n", .{mode});
        return 1;
    };
    print("RESULT trace mode={s} status=ok tid={d} inherit=0 foreign={d} forks={d} lost={d} dropped={d} complete_after={d} unknown_after={d} elapsed_after={d} longest_nr={d} longest_elapsed={d} stored={d} bytes={d} budget={d} enter={s} exit={s} reaped={d} go_ns={d}\n", .{
        mode,
        child,
        foreign,
        machine.forks_not_followed,
        machine.lost_records,
        machine.dropped,
        complete_after,
        unknown_after,
        elapsed_after,
        best_nr,
        best_elapsed,
        sum.stored_matched,
        machine.storedBytes(),
        machine.budgetBytes(),
        @tagName(enter_status),
        @tagName(exit_status),
        @intFromBool(reaped),
        go_ns,
    });
    owned.finish();
    print("RESULT cleanup closed={d} child={d}\n", .{ owned.closed, child });
    return 0;
}

fn handshake(fixture: [:0]const u8, scratch: [:0]const u8, mode: [:0]const u8) u8 {
    var ready: [2]i32 = .{-1} ** 2;
    var go: [2]i32 = .{-1} ** 2;
    defer {
        if (ready[0] >= 0) _ = linux.close(ready[0]);
        if (ready[1] >= 0) _ = linux.close(ready[1]);
        if (go[0] >= 0) _ = linux.close(go[0]);
        if (go[1] >= 0) _ = linux.close(go[1]);
    }
    const child = spawnSynced(fixture, scratch, mode, &ready, &go) orelse {
        print("RESULT handshake mode={s} status=error stage=spawn\n", .{mode});
        return 1;
    };
    if (!awaitReady(ready[0])) {
        _ = linux.kill(child, linux.SIG.KILL);
        _ = reap(child, 1_000_000_000);
        print("RESULT handshake mode={s} status=error stage=ready child={d}\n", .{ mode, child });
        return 1;
    }
    if (!releaseGo(go[1])) {
        _ = linux.kill(child, linux.SIG.KILL);
        _ = reap(child, 1_000_000_000);
        print("RESULT handshake mode={s} status=error stage=go child={d}\n", .{ mode, child });
        return 1;
    }
    const reaped = reap(child, 5_000_000_000);
    print("RESULT handshake mode={s} status={s} child={d} reaped={d}\n", .{ mode, if (reaped) "ok" else "timeout", child, @intFromBool(reaped) });
    return if (reaped) 0 else 1;
}

fn mapFd(fd: i32, len: usize) ?[*]u8 {
    const mapped = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (note(mapped) != 0) return null;
    return @ptrFromInt(mapped);
}

fn reap(pid: i32, budget_ns: u64) bool {
    const start = mono();
    var status: u32 = 0;
    while (mono() - start < budget_ns) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err == .CHILD) return true;
        if (err == .SUCCESS and rc == @as(usize, @intCast(pid))) return true;
        var req = linux.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&req, null);
    }
    _ = linux.kill(pid, linux.SIG.KILL);
    const rc = linux.waitpid(pid, &status, 0);
    return linux.errno(rc) == .SUCCESS or linux.errno(rc) == .CHILD;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    if (argv.len < 2) {
        print("usage: probe inventory | probe handshake <fixture> <scratch> <mode> | probe run <fixture> <scratch> <mode> <enter_id> <exit_id>\n", .{});
        return 2;
    }
    const cmd = std.mem.span(argv[1]);
    if (std.mem.eql(u8, cmd, "inventory")) return inventory();
    if (std.mem.eql(u8, cmd, "handshake")) {
        if (argv.len < 5) return 2;
        return handshake(std.mem.span(argv[2]), std.mem.span(argv[3]), std.mem.span(argv[4]));
    }
    if (!std.mem.eql(u8, cmd, "run") or argv.len < 7) return 2;
    const enter_id = parseU64(std.mem.span(argv[5])) orelse return 2;
    const exit_id = parseU64(std.mem.span(argv[6])) orelse return 2;
    if (enter_id == 0 or exit_id == 0) {
        print("RESULT trace status=no_id\n", .{});
        return 0;
    }
    return run(std.mem.span(argv[2]), std.mem.span(argv[3]), std.mem.span(argv[4]), enter_id, exit_id);
}
