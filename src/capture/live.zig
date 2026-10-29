//! Owned live pcap capture through dumpcap or tcpdump.
//! One Live owns one supervisor child and one reader thread. The supervisor
//! is a fork of xodb (no exec) that runs the capture tool and stops it with
//! SIGTERM, then SIGKILL, when its life pipe closes: when the session ends or
//! when xodb dies by any means. A parent-death signal alone is not enough:
//! Linux clears it on exec of a binary with file capabilities or set-ID bits,
//! which is how dumpcap and tcpdump are normally given capture permission.
//! Raw packets are retained in a fixed record/byte ring and copied into
//! immutable pcap snapshots for the evidence layer.
const std = @import("std");
const log = @import("../log.zig");
const network = @import("../evidence/stream.zig");
const pcap = network.pcap;

extern fn xrt_spawn_owned_helper(pid: *i32, create: *const fn (*i32, ?*anyopaque) callconv(.c) c_int, context: ?*anyopaque) c_int;
extern fn xrt_drop_owned_helper(pid: i32) void;

const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/wait.h");
});

fn forkOwned(pid: *i32, _: ?*anyopaque) callconv(.c) c_int {
    const child = c.fork();
    if (child < 0) {
        const err = std.c._errno().*;
        return if (err > 0) @intCast(err) else @intCast(c.EAGAIN);
    }
    pid.* = @intCast(child);
    return 0;
}

fn dropHelper(pid: c.pid_t) void {
    if (pid > 1) xrt_drop_owned_helper(@intCast(pid));
}

pub const default_ring_bytes = 64 * 1024 * 1024;
pub const min_ring_bytes = 64 * 1024;
pub const max_ring_bytes = 256 * 1024 * 1024;
pub const max_ring_records = 65_536;
const max_pending_bytes = pcap.max_packet + 64;

pub const Producer = enum { dumpcap, tcpdump };
pub const Version = struct { producer: Producer, major: u16, minor: u16 };

const Slot = struct { time_ns: u64 = 0, origlen: u32 = 0, bytes: []u8 = &.{} };

const Ring = struct {
    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,
    slots: []Slot,
    first: usize = 0,
    count: usize = 0,
    bytes: usize = 0,
    byte_limit: usize,
    captured: u64 = 0,
    dropped: u64 = 0,
    snaplen: u32 = 65_535,
    link_type: u16 = 0,
    ready: bool = false,

    fn init(a: std.mem.Allocator, byte_limit: usize) !Ring {
        const capacity = @min(max_ring_records, @max(@as(usize, 64), byte_limit / 64));
        const slots = try a.alloc(Slot, capacity);
        @memset(slots, .{});
        return .{ .allocator = a, .slots = slots, .byte_limit = byte_limit };
    }

    fn deinit(self: *Ring) void {
        for (self.slots) |slot| if (slot.bytes.len != 0) self.allocator.free(slot.bytes);
        self.allocator.free(self.slots);
    }

    fn lock(self: *Ring) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn configure(self: *Ring, snaplen: u32, link_type: u16) void {
        self.lock();
        defer self.mutex.unlock();
        self.snaplen = snaplen;
        self.link_type = link_type;
        self.ready = true;
    }

    fn discardFirst(self: *Ring) void {
        const slot = &self.slots[self.first];
        self.bytes -= slot.bytes.len + 16;
        self.allocator.free(slot.bytes);
        slot.* = .{};
        self.first = (self.first + 1) % self.slots.len;
        self.count -= 1;
        self.dropped += 1;
    }

    fn append(self: *Ring, time_ns: u64, origlen: u32, bytes: []u8) void {
        self.lock();
        defer self.mutex.unlock();
        self.captured += 1;
        const needed = bytes.len + 16;
        if (needed > self.byte_limit) {
            self.dropped += 1;
            self.allocator.free(bytes);
            return;
        }
        while (self.count == self.slots.len or (self.count != 0 and self.bytes + needed > self.byte_limit)) self.discardFirst();
        const at = (self.first + self.count) % self.slots.len;
        self.slots[at] = .{ .time_ns = time_ns, .origlen = origlen, .bytes = bytes };
        self.count += 1;
        self.bytes += needed;
    }

    fn snapshot(self: *Ring, a: std.mem.Allocator) !struct { bytes: []u8, retained: usize, captured: u64, dropped: u64, ring_bytes: usize, ring_limit: usize } {
        self.lock();
        defer self.mutex.unlock();
        if (!self.ready) return error.LiveCaptureNotReady;
        const size = std.math.add(usize, 24, self.bytes) catch return error.OutOfMemory;
        const out = try a.alloc(u8, size);
        std.mem.writeInt(u32, out[0..4], pcap.pcap_ns, .little);
        std.mem.writeInt(u16, out[4..6], 2, .little);
        std.mem.writeInt(u16, out[6..8], 4, .little);
        @memset(out[8..16], 0);
        std.mem.writeInt(u32, out[16..20], self.snaplen, .little);
        std.mem.writeInt(u32, out[20..24], self.link_type, .little);
        var at: usize = 24;
        for (0..self.count) |i| {
            const slot = self.slots[(self.first + i) % self.slots.len];
            const seconds = slot.time_ns / std.time.ns_per_s;
            std.mem.writeInt(u32, out[at..][0..4], @intCast(@min(seconds, std.math.maxInt(u32))), .little);
            std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(slot.time_ns % std.time.ns_per_s), .little);
            std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(slot.bytes.len), .little);
            std.mem.writeInt(u32, out[at + 12 ..][0..4], slot.origlen, .little);
            @memcpy(out[at + 16 ..][0..slot.bytes.len], slot.bytes);
            at += 16 + slot.bytes.len;
        }
        std.debug.assert(at == out.len);
        return .{ .bytes = out, .retained = self.count, .captured = self.captured, .dropped = self.dropped, .ring_bytes = self.bytes, .ring_limit = self.byte_limit };
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(u8) = .empty,
    header: bool = false,
    endian: std.builtin.Endian = .little,
    nanosecond: bool = false,
    snaplen: u32 = 0,

    fn deinit(self: *Parser) void {
        self.pending.deinit(self.allocator);
    }

    fn feed(self: *Parser, ring: *Ring, bytes: []const u8) !void {
        if (self.pending.items.len + bytes.len > max_pending_bytes) return error.LiveCaptureProtocol;
        try self.pending.appendSlice(self.allocator, bytes);
        var at: usize = 0;
        if (!self.header) {
            if (self.pending.items.len < 24) return;
            const le = std.mem.readInt(u32, self.pending.items[0..4], .little);
            const be = std.mem.readInt(u32, self.pending.items[0..4], .big);
            self.endian = if (le == pcap.pcap_us or le == pcap.pcap_ns) .little else if (be == pcap.pcap_us or be == pcap.pcap_ns) .big else return error.LiveCaptureProtocol;
            const magic = std.mem.readInt(u32, self.pending.items[0..4], self.endian);
            self.nanosecond = magic == pcap.pcap_ns;
            if (std.mem.readInt(u16, self.pending.items[4..6], self.endian) != 2 or std.mem.readInt(u16, self.pending.items[6..8], self.endian) != 4) return error.LiveCaptureProtocol;
            self.snaplen = std.mem.readInt(u32, self.pending.items[16..20], self.endian);
            const link = std.mem.readInt(u32, self.pending.items[20..24], self.endian);
            if (link > std.math.maxInt(u16) or self.snaplen == 0 or self.snaplen > pcap.max_packet) return error.LiveCaptureProtocol;
            ring.configure(self.snaplen, @intCast(link));
            self.header = true;
            at = 24;
        }
        while (self.pending.items.len - at >= 16) {
            const header = self.pending.items[at..][0..16];
            const seconds = std.mem.readInt(u32, header[0..4], self.endian);
            const fraction = std.mem.readInt(u32, header[4..8], self.endian);
            const caplen = std.mem.readInt(u32, header[8..12], self.endian);
            const origlen = std.mem.readInt(u32, header[12..16], self.endian);
            if (caplen > pcap.max_packet or caplen > self.snaplen) return error.LiveCaptureProtocol;
            const scale: u32 = if (self.nanosecond) 1_000_000_000 else 1_000_000;
            if (fraction >= scale) return error.LiveCaptureProtocol;
            if (self.pending.items.len - at - 16 < caplen) break;
            const copy = try self.allocator.dupe(u8, self.pending.items[at + 16 ..][0..caplen]);
            const fraction_ns: u64 = if (self.nanosecond) 1 else 1000;
            const time_ns = @as(u64, seconds) * std.time.ns_per_s + @as(u64, fraction) * fraction_ns;
            ring.append(time_ns, origlen, copy);
            at += 16 + caplen;
        }
        if (at != 0) {
            std.mem.copyForwards(u8, self.pending.items, self.pending.items[at..]);
            self.pending.shrinkRetainingCapacity(self.pending.items.len - at);
        }
    }
};

pub const Stats = struct {
    state: enum { starting, capturing, stopped, failed },
    pid: i32,
    producer: Producer,
    version_major: u16,
    version_minor: u16,
    retained_records: usize,
    captured_records: u64,
    ring_dropped_records: u64,
    ring_bytes: usize,
    ring_limit_bytes: usize,
};

pub const Snapshot = struct {
    stream: *network.Stream,
    stats: Stats,
    pub fn destroy(self: *Snapshot) void {
        self.stream.destroy();
    }
};

pub const Live = struct {
    allocator: std.mem.Allocator,
    ring: Ring,
    parser: Parser,
    interface: []u8,
    version: Version,
    /// The supervisor; it and the tool share a process group of this id.
    pid: c.pid_t = 0,
    fd: c_int = -1,
    /// Write end of the supervisor's life pipe; closing it stops the tool.
    life: c_int = -1,
    worker: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(a: std.mem.Allocator, tool: [:0]const u8, interface: []const u8, ring_bytes: usize) !*Live {
        if (interface.len == 0 or interface[0] == '-' or std.mem.indexOfScalar(u8, interface, 0) != null) return error.InvalidCaptureInterface;
        if (ring_bytes < min_ring_bytes or ring_bytes > max_ring_bytes) return error.InvalidCaptureRingSize;
        const version = try probeVersion(tool);
        const self = try a.create(Live);
        errdefer a.destroy(self);
        var ring = try Ring.init(a, ring_bytes);
        errdefer ring.deinit();
        self.* = .{
            .allocator = a,
            .ring = ring,
            .parser = .{ .allocator = a },
            .interface = try a.dupe(u8, interface),
            .version = version,
        };
        errdefer self.parser.deinit();
        errdefer a.free(self.interface);
        const interface_z = try a.dupeZ(u8, interface);
        defer a.free(interface_z);
        const argv_dumpcap = [_:null]?[*:0]const u8{ tool.ptr, "-q", "-P", "-s", "65535", "-i", interface_z.ptr, "-w", "-", null };
        const argv_tcpdump = [_:null]?[*:0]const u8{ tool.ptr, "-U", "-n", "-s", "65535", "-i", interface_z.ptr, "-w", "-", null };
        const child = switch (version.producer) {
            .dumpcap => try spawnCapture(&argv_dumpcap),
            .tcpdump => try spawnCapture(&argv_tcpdump),
        };
        self.pid = child.pid;
        self.fd = child.fd;
        self.life = child.life;
        errdefer self.closeData();
        errdefer self.stopChild();
        self.worker = try std.Thread.spawn(.{}, readLoop, .{self});
        // A permission/interface error exits immediately. Refuse it here
        // instead of publishing a capture that can never produce a header.
        _ = c.poll(null, 0, 150);
        var status: c_int = 0;
        const waited = c.waitpid(self.pid, &status, c.WNOHANG);
        const stolen = waited < 0 and std.c._errno().* == c.ECHILD;
        if (waited == self.pid or stolen) {
            const code: c_int = if (waited == self.pid and c.WIFEXITED(status)) c.WEXITSTATUS(status) else -1;
            dropHelper(self.pid);
            self.pid = 0;
            self.stopChild();
            self.worker.?.join();
            self.worker = null;
            self.closeData();
            log.err(.session, "xodb: live capture: {s} exited during startup (status {d}). This account may lack capture permission on that interface, or the interface does not exist; xodb uses no sudo or helper, so grant {s} capture rights (for example its packaged group) and retry.\n", .{ @tagName(version.producer), code, @tagName(version.producer) });
            return error.LiveCaptureStartFailed;
        }
        return self;
    }

    pub fn destroy(self: *Live) void {
        const a = self.allocator;
        self.stopping.store(true, .release);
        self.stopChild();
        // The tool and supervisor are gone, so the reader sees EOF; close
        // the descriptor only after it can no longer be read.
        if (self.worker) |worker| worker.join();
        self.closeData();
        self.parser.deinit();
        self.ring.deinit();
        a.free(self.interface);
        a.destroy(self);
    }

    pub fn snapshot(self: *Live, a: std.mem.Allocator, id: u32) !Snapshot {
        const raw = try self.ring.snapshot(a);
        errdefer a.free(raw.bytes);
        const stream = try network.Stream.open(a, raw.bytes, "live capture");
        stream.id = id;
        return .{
            .stream = stream,
            .stats = .{
                .state = if (self.failed.load(.acquire)) .failed else if (self.finished.load(.acquire)) .stopped else if (raw.retained == 0) .starting else .capturing,
                .pid = self.pid,
                .producer = self.version.producer,
                .version_major = self.version.major,
                .version_minor = self.version.minor,
                .retained_records = raw.retained,
                .captured_records = raw.captured,
                .ring_dropped_records = raw.dropped,
                .ring_bytes = raw.ring_bytes,
                .ring_limit_bytes = raw.ring_limit,
            },
        };
    }

    pub fn stats(self: *Live) Stats {
        self.ring.lock();
        defer self.ring.mutex.unlock();
        return .{
            .state = if (self.failed.load(.acquire)) .failed else if (self.finished.load(.acquire)) .stopped else if (!self.ring.ready or self.ring.count == 0) .starting else .capturing,
            .pid = self.pid,
            .producer = self.version.producer,
            .version_major = self.version.major,
            .version_minor = self.version.minor,
            .retained_records = self.ring.count,
            .captured_records = self.ring.captured,
            .ring_dropped_records = self.ring.dropped,
            .ring_bytes = self.ring.bytes,
            .ring_limit_bytes = self.ring.byte_limit,
        };
    }

    fn readLoop(self: *Live) void {
        defer self.finished.store(true, .release);
        var buffer: [64 * 1024]u8 = undefined;
        while (!self.stopping.load(.acquire)) {
            const got = c.read(self.fd, &buffer, buffer.len);
            if (got > 0) {
                self.parser.feed(&self.ring, buffer[0..@intCast(got)]) catch {
                    self.failed.store(true, .release);
                    return;
                };
            } else if (got == 0) return else if (std.c._errno().* != c.EINTR) {
                if (!self.stopping.load(.acquire)) self.failed.store(true, .release);
                return;
            }
        }
    }

    /// Close the life pipe; the supervisor stops the tool (SIGTERM, SIGKILL
    /// after one second) and exits. If it has not exited after two seconds,
    /// its whole process group is killed. Then the exact PID is reaped.
    fn stopChild(self: *Live) void {
        if (self.life >= 0) {
            _ = c.close(self.life);
            self.life = -1;
        }
        if (self.pid > 0) {
            const pid = self.pid;
            defer dropHelper(pid);
            var status: c_int = 0;
            const deadline = nowNs() + 2 * std.time.ns_per_s;
            while (c.waitpid(pid, &status, c.WNOHANG) == 0 and nowNs() < deadline) _ = c.poll(null, 0, 10);
            if (c.waitpid(pid, &status, c.WNOHANG) == 0) {
                _ = c.kill(-pid, c.SIGKILL);
                _ = c.waitpid(pid, &status, 0);
            }
            self.pid = 0;
        }
    }

    fn closeData(self: *Live) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

pub fn defaultTool() [:0]const u8 {
    if (c.access("/usr/bin/dumpcap", c.X_OK) == 0) return "/usr/bin/dumpcap";
    if (c.access("/usr/bin/tcpdump", c.X_OK) == 0) return "/usr/bin/tcpdump";
    return "dumpcap";
}

pub fn parseVersion(text: []const u8) !Version {
    const choices = [_]struct { marker: []const u8, producer: Producer, minimum: u16 }{
        .{ .marker = "Dumpcap (Wireshark) ", .producer = .dumpcap, .minimum = 3 },
        .{ .marker = "tcpdump version ", .producer = .tcpdump, .minimum = 4 },
    };
    for (choices) |choice| if (std.mem.indexOf(u8, text, choice.marker)) |found| {
        var parts = std.mem.splitScalar(u8, text[found + choice.marker.len ..], '.');
        const major_text = parts.next() orelse return error.UnsupportedCaptureTool;
        const minor_text = parts.next() orelse return error.UnsupportedCaptureTool;
        const major = std.fmt.parseInt(u16, leadingDigits(major_text), 10) catch return error.UnsupportedCaptureTool;
        const minor = std.fmt.parseInt(u16, leadingDigits(minor_text), 10) catch return error.UnsupportedCaptureTool;
        if (major < choice.minimum) return error.UnsupportedCaptureToolVersion;
        return .{ .producer = choice.producer, .major = major, .minor = minor };
    };
    return error.UnsupportedCaptureTool;
}

fn leadingDigits(text: []const u8) []const u8 {
    var n: usize = 0;
    while (n < text.len and std.ascii.isDigit(text[n])) n += 1;
    return text[0..n];
}

const Child = struct { pid: c.pid_t, fd: c_int, life: c_int = -1 };

fn pipeChild(argv: anytype) !Child {
    var fds: [2]c_int = undefined;
    if (c.pipe2(&fds, c.O_CLOEXEC) != 0) return error.LiveCaptureSpawnFailed;
    errdefer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    var spawned: i32 = 0;
    if (xrt_spawn_owned_helper(&spawned, forkOwned, null) != 0) return error.LiveCaptureSpawnFailed;
    const pid: c.pid_t = @intCast(spawned);
    if (pid == 0) {
        _ = c.close(fds[0]);
        if (c.dup2(fds[1], c.STDOUT_FILENO) < 0) c._exit(126);
        _ = c.dup2(fds[1], c.STDERR_FILENO);
        _ = c.close(fds[1]);
        _ = c.execvp(argv[0].?, @ptrCast(argv));
        c._exit(127);
    }
    _ = c.close(fds[1]);
    return .{ .pid = pid, .fd = fds[0] };
}

fn spawnCapture(argv: anytype) !Child {
    var data: [2]c_int = undefined;
    if (c.pipe2(&data, c.O_CLOEXEC) != 0) return error.LiveCaptureSpawnFailed;
    errdefer {
        _ = c.close(data[0]);
        _ = c.close(data[1]);
    }
    var life: [2]c_int = undefined;
    if (c.pipe2(&life, c.O_CLOEXEC) != 0) return error.LiveCaptureSpawnFailed;
    errdefer {
        _ = c.close(life[0]);
        _ = c.close(life[1]);
    }
    var spawned: i32 = 0;
    if (xrt_spawn_owned_helper(&spawned, forkOwned, null) != 0) return error.LiveCaptureSpawnFailed;
    const pid: c.pid_t = @intCast(spawned);
    if (pid == 0) supervise(argv, data, life);
    _ = c.setpgid(pid, pid);
    _ = c.close(data[1]);
    _ = c.close(life[0]);
    return .{ .pid = pid, .fd = data[0], .life = life[1] };
}

/// The forked supervisor: async-signal-safe calls only. Its exit status is
/// the tool's (128 + signal when it was killed).
fn supervise(argv: anytype, data: [2]c_int, life: [2]c_int) noreturn {
    _ = c.close(data[0]);
    _ = c.close(life[1]);
    _ = c.setpgid(0, 0); // own group: no terminal signals; one group to kill
    const supervisor = c.getpid();
    // This tool is the supervisor's child. The debugger's reap does not see it.
    const tool = c.fork();
    if (tool < 0) c._exit(126);
    if (tool == 0) {
        // Kept for unprivileged tools; Linux clears it on a capability exec,
        // where the supervisor's life pipe still stops the tool.
        _ = c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGKILL), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        if (c.getppid() != supervisor) c._exit(125);
        // xodb ignores SIGPIPE; the tool must die writing to a closed pipe.
        std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
        var none: c.sigset_t = undefined;
        _ = c.sigemptyset(&none);
        _ = c.sigprocmask(c.SIG_SETMASK, &none, null);
        if (c.dup2(data[1], c.STDOUT_FILENO) < 0) c._exit(126);
        const devnull = c.open("/dev/null", c.O_RDWR | c.O_CLOEXEC);
        if (devnull >= 0) {
            _ = c.dup2(devnull, c.STDIN_FILENO);
            _ = c.dup2(devnull, c.STDERR_FILENO);
        }
        _ = c.execvp(argv[0].?, @ptrCast(argv));
        c._exit(127);
    }
    _ = c.close(data[1]);
    var status: c_int = 0;
    while (true) {
        if (c.waitpid(tool, &status, c.WNOHANG) == tool) c._exit(exitCode(status));
        var watch = c.struct_pollfd{ .fd = life[0], .events = c.POLLIN, .revents = 0 };
        if (c.poll(&watch, 1, 20) > 0) break; // EOF: xodb closed it or died
    }
    _ = c.kill(tool, c.SIGTERM);
    for (0..100) |_| {
        if (c.waitpid(tool, &status, c.WNOHANG) == tool) c._exit(exitCode(status));
        _ = c.poll(null, 0, 10);
    }
    _ = c.kill(tool, c.SIGKILL);
    _ = c.waitpid(tool, &status, 0);
    c._exit(exitCode(status));
}

fn exitCode(status: c_int) u8 {
    if (c.WIFEXITED(status)) return @intCast(c.WEXITSTATUS(status));
    return @intCast(128 + (c.WTERMSIG(status) & 0x7f));
}

fn probeVersion(tool: [:0]const u8) !Version {
    const argv = [_:null]?[*:0]const u8{ tool.ptr, "--version", null };
    const child = try pipeChild(&argv);
    defer dropHelper(child.pid);
    defer _ = c.close(child.fd);
    const flags = c.fcntl(child.fd, c.F_GETFL);
    if (flags >= 0) _ = c.fcntl(child.fd, c.F_SETFL, flags | c.O_NONBLOCK);
    var output: [4096]u8 = undefined;
    var used: usize = 0;
    var status: c_int = 0;
    var reaped = false;
    const deadline = nowNs() + 2 * std.time.ns_per_s;
    while (nowNs() < deadline) {
        if (used < output.len) {
            const got = c.read(child.fd, output[used..].ptr, output.len - used);
            if (got > 0) used += @intCast(got);
        }
        const waited = c.waitpid(child.pid, &status, c.WNOHANG);
        if (waited == child.pid) {
            reaped = true;
            break;
        }
        // Already collected. Do not signal the pid: it may have been reused.
        if (waited < 0 and std.c._errno().* == c.ECHILD) return error.CaptureVersionFailed;
        _ = c.poll(null, 0, 10);
    }
    if (!reaped) {
        _ = c.kill(child.pid, c.SIGTERM);
        _ = c.waitpid(child.pid, &status, 0);
        return error.CaptureVersionTimeout;
    }
    while (used < output.len) {
        const got = c.read(child.fd, output[used..].ptr, output.len - used);
        if (got <= 0) break;
        used += @intCast(got);
    }
    if (!c.WIFEXITED(status) or c.WEXITSTATUS(status) != 0) return error.CaptureVersionFailed;
    return parseVersion(output[0..used]);
}

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.tv_nsec));
}

test "capture producer versions are explicit and old or unknown tools refuse" {
    try std.testing.expectEqual(Version{ .producer = .tcpdump, .major = 4, .minor = 99 }, try parseVersion("tcpdump version 4.99.7\nlibpcap"));
    try std.testing.expectEqual(Version{ .producer = .dumpcap, .major = 4, .minor = 4 }, try parseVersion("Dumpcap (Wireshark) 4.4.0"));
    try std.testing.expectError(error.UnsupportedCaptureToolVersion, parseVersion("tcpdump version 3.9.8"));
    try std.testing.expectError(error.UnsupportedCaptureTool, parseVersion("packet copier 7"));
}

test "packet ring evicts whole oldest records and snapshots a valid pcap" {
    const a = std.testing.allocator;
    var ring = try Ring.init(a, min_ring_bytes);
    defer ring.deinit();
    ring.configure(65_535, network.decode.link_ethernet);
    const packet = try a.alloc(u8, 40_000);
    @memset(packet, 1);
    ring.append(1, 40_000, packet);
    const next = try a.alloc(u8, 40_000);
    @memset(next, 2);
    ring.append(2, 40_000, next);
    const raw = try ring.snapshot(a);
    defer a.free(raw.bytes);
    try std.testing.expectEqual(@as(usize, 1), raw.retained);
    try std.testing.expectEqual(@as(u64, 2), raw.captured);
    try std.testing.expectEqual(@as(u64, 1), raw.dropped);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try pcap.parse(arena.allocator(), raw.bytes, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.records.len);
    try std.testing.expectEqual(@as(u8, 2), parsed.data(raw.bytes, 0)[0]);
}
