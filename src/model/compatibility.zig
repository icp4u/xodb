//! Thread label providers and local Wine hints. Neither changes thread inventory.
const std = @import("std");
const linux = @import("../target/linux.zig");
const identity = @import("process_identity.zig");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/syscall.h");
    @cInclude("linux/openat2.h");
});

pub const Info = struct {
    kind: enum { unknown, not_detected, wine, unavailable } = .unknown,
    proton: bool = false,
    build: [96]u8 = @splat(0),
    pub fn title(self: *const Info, out: []u8) []const u8 {
        if (self.kind != .wine) return "";
        if (!self.proton) return "Windows process under Wine";
        const build_name = std.mem.sliceTo(&self.build, 0);
        return std.fmt.bufPrint(out, "Windows process under Wine (Proton {s})", .{if (build_name.len == 0) "version unavailable" else build_name}) catch "Windows process under Wine (Proton)";
    }
    pub fn jsonStringify(self: Info, writer: *std.json.Stringify) !void {
        try writer.write(.{ .kind = self.kind, .proton = self.proton, .proton_build = std.mem.sliceTo(&self.build, 0), .evidence = if (self.kind == .wine) "mapped Wine ntdll; optional installation version file" else "Wine mappings not observed or metadata unavailable" });
    }
};
pub const Label = struct {
    id: u64 = 0,
    tid: i32 = 0,
    name: [128]u8 = @splat(0),
    source: enum { linux_task_comm, gdb_thread_info } = .linux_task_comm,
    queue_address: ?u64 = null,
    readable: bool = false,
    internal_name: bool = false,
    possibly_truncated: bool = false,
    pub fn text(self: *const Label) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }
    pub fn jsonStringify(self: Label, writer: *std.json.Stringify) !void {
        var queue: [18]u8 = undefined;
        try writer.write(.{ .id = self.id, .tid = self.tid, .name = if (self.readable) self.text() else null, .source = self.source, .queue_address = if (self.queue_address) |address| std.fmt.bufPrint(&queue, "0x{x}", .{address}) catch unreachable else null, .possibly_truncated = self.possibly_truncated, .wine_internal_name = self.internal_name });
    }
};

/// This is a name hint, not proof of thread origin or an authority boundary.
pub fn internalName(name: []const u8) bool {
    return std.mem.eql(u8, name, "wine_threadpool") or
        std.mem.startsWith(u8, name, "wine_rpcrt4_") or
        std.mem.startsWith(u8, name, "wine_sechost_");
}
fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(std.mem.trimEnd(u8, path, "\x00"));
}
pub fn protonRoot(path: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, path, "/files/lib/") orelse std.mem.indexOf(u8, path, "/files/lib64/") orelse std.mem.indexOf(u8, path, "/dist/lib/") orelse return null;
    const root = path[0..at];
    return if (root.len > 0 and std.ascii.indexOfIgnoreCase(basename(root), "proton") != null) root else null;
}

fn readFile(path: [:0]const u8, out: []u8) ?[]const u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK | c.O_NOFOLLOW);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, out.ptr, out.len);
    if (n < 0 or n >= out.len) return null;
    return out[0..@intCast(n)];
}
fn startTicks(pid: i32) ?u64 {
    var path: [64]u8 = undefined;
    var bytes: [4096]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    return identity.parse(readFile(name, &bytes) orelse return null) catch null;
}
fn safeName(out: []u8, bytes: []const u8) void {
    @memset(out, 0);
    var used: usize = 0;
    var at: usize = 0;
    while (at < bytes.len and used + 1 < out.len) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[at]) catch 1;
        if (at + n > bytes.len or used + n >= out.len) break;
        const cp = std.unicode.utf8Decode(bytes[at..][0..n]) catch 0;
        if (cp < 32 or cp == 127 or (cp >= 0x200b and cp <= 0x200f) or (cp >= 0x202a and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069)) {
            out[used] = '?';
            used += 1;
        } else {
            @memcpy(out[used..][0..n], bytes[at..][0..n]);
            used += n;
        }
        at += n;
    }
}
fn version(pid: i32, root: []const u8, out: *[96]u8) void {
    if (!std.fs.path.isAbsolute(root)) return;
    var path: [4096]u8 = undefined;
    const proc = std.fmt.bufPrintZ(&path, "/proc/{d}/root", .{pid}) catch return;
    const fd = c.open(proc.ptr, c.O_PATH | c.O_DIRECTORY | c.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = c.close(fd);
    const relative = std.fmt.bufPrintZ(&path, "{s}/version", .{std.mem.trimStart(u8, root, "/")}) catch return;
    const how = std.mem.zeroInit(c.struct_open_how, .{ .flags = c.O_PATH | c.O_CLOEXEC, .resolve = c.RESOLVE_IN_ROOT | c.RESOLVE_NO_SYMLINKS | c.RESOLVE_NO_MAGICLINKS });
    const opened = c.syscall(c.SYS_openat2, fd, relative.ptr, &how, @as(c_ulong, @sizeOf(c.struct_open_how)));
    if (opened < 0) return;
    const file: c_int = @intCast(opened);
    defer _ = c.close(file);
    var stat: c.struct_stat = undefined;
    if (c.fstat(file, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size <= 0 or stat.st_size > 4096) return;
    const pinned = std.fmt.bufPrintZ(&path, "/proc/self/fd/{d}", .{file}) catch return;
    const reader = c.open(pinned.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (reader < 0) return;
    defer _ = c.close(reader);
    var bytes: [4097]u8 = undefined;
    const n = c.read(reader, &bytes, bytes.len);
    if (n <= 0 or n >= bytes.len) return;
    const line = std.mem.trim(u8, std.mem.sliceTo(bytes[0..@intCast(n)], '\n'), "\r \t");
    if (line.len >= out.len or std.ascii.indexOfIgnoreCase(line, "proton") == null) return;
    safeName(out, line);
}

pub const Cache = struct {
    info: Info = .{},
    labels: std.ArrayList(Label) = .empty,
    pid: i32 = 0,
    epoch: u64 = 0,
    maps_generation: ?u64 = null,
    next: u64 = 0,
    cursor: usize = 0,
    revision: u64 = 0,
    remote_generation: ?u64 = null,
    pub fn deinit(self: *Cache) void {
        self.labels.deinit(std.heap.page_allocator);
        self.* = .{};
    }
    pub fn find(self: *const Cache, thread: linux.Thread) ?*const Label {
        for (self.labels.items) |*row| if (row.id == thread.id and row.tid == thread.tid) return row;
        return null;
    }
    pub fn poll(self: *Cache, session: anytype) void {
        const snap = session.target.snapshot();
        if (snap.pid != self.pid or snap.image_epoch != self.epoch) {
            self.deinit();
            self.pid = snap.pid;
            self.epoch = snap.image_epoch;
        }
        if (session.target.gdbRemoteInfo()) |gdb| if (gdb.os == .darwin) {
            self.info = .{ .kind = .unavailable };
            if (snap.state != .stopped or self.remote_generation == snap.generation) return;
            const threads = session.target.threadSlice();
            self.labels.resize(std.heap.page_allocator, threads.len) catch return;
            for (threads, self.labels.items) |thread, *row| {
                row.* = .{ .id = thread.id, .tid = thread.tid, .source = .gdb_thread_info };
                const detail = session.target.gdbThreadInfo(thread.tid) catch continue;
                if (detail.has_name) {
                    safeName(&row.name, std.mem.sliceTo(&detail.name, 0));
                    row.readable = true;
                    row.possibly_truncated = detail.name_truncated;
                }
                if (detail.has_queue) row.queue_address = detail.queue_address;
            }
            self.remote_generation = snap.generation;
            self.revision +%= 1;
            return;
        };
        if (session.target.isRemote() or session.target.core != null or session.offline) {
            self.info = .{ .kind = .unavailable };
            self.labels.clearRetainingCapacity();
            return;
        }
        if (snap.pid <= 1 or snap.state == .idle or snap.state == .exited) return;
        if (self.maps_generation == null or self.maps_generation.? != session.maps_generation) {
            if (session.maps_epoch != snap.image_epoch or session.maps_generation != snap.generation) return;
            self.info = .{ .kind = .not_detected };
            var pe = false;
            var unix = false;
            var root: ?[]const u8 = null;
            for (session.modules.regions.items) |region| {
                if (region.permissions[2] != 'x') continue;
                const name = basename(region.path);
                if (std.ascii.eqlIgnoreCase(name, "ntdll.dll")) pe = true;
                if (std.mem.eql(u8, name, "ntdll.so") or std.mem.eql(u8, name, "ntdll.dll.so")) {
                    unix = true;
                    root = protonRoot(region.path);
                }
            }
            if (pe and unix) {
                self.info.kind = .wine;
                if (root) |value| {
                    self.info.proton = true;
                    version(snap.pid, value, &self.info.build);
                }
            }
            self.maps_generation = session.maps_generation;
            self.next = 0;
            self.revision +%= 1;
        }
        if (self.info.kind != .wine) {
            self.labels.clearRetainingCapacity();
            return;
        }
        const now = linux.now();
        if (now < self.next) return;
        const start = startTicks(snap.pid) orelse return;
        const threads = session.target.threadSlice();
        const old_len = self.labels.items.len;
        self.labels.resize(std.heap.page_allocator, threads.len) catch return;
        for (threads, self.labels.items, 0..) |thread, *row, i| {
            if (i >= old_len or row.id != thread.id or row.tid != thread.tid) row.* = .{ .id = thread.id, .tid = thread.tid };
        }
        if (self.cursor >= threads.len) self.cursor = 0;
        const end = @min(threads.len, self.cursor + 32);
        for (self.labels.items[self.cursor..end]) |*row| {
            var path: [96]u8 = undefined;
            var bytes: [32]u8 = undefined;
            const name = std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}/comm", .{ snap.pid, row.tid }) catch continue;
            const raw = readFile(name, &bytes);
            var next = Label{ .id = row.id, .tid = row.tid };
            if (raw) |text| {
                const trimmed = std.mem.trimEnd(u8, text, "\n");
                safeName(next.name[0..16], trimmed);
                next.possibly_truncated = trimmed.len >= 15;
                next.readable = true;
                next.internal_name = internalName(next.text());
            }
            if (!std.meta.eql(row.*, next)) self.revision +%= 1;
            row.* = next;
        }
        if ((startTicks(snap.pid) orelse 0) != start) {
            self.deinit();
            return;
        }
        self.cursor = end;
        if (end == threads.len) self.next = now + 500 * std.time.ns_per_ms;
    }
};

test "Wine names are bounded hints and ordinary application names remain visible" {
    try std.testing.expect(internalName("wine_threadpool"));
    try std.testing.expect(!internalName("RenderWorker"));
    try std.testing.expect(!internalName("wineApplication"));
    var label: Label = .{};
    safeName(&label.name, "render\x1b[31m\n");
    try std.testing.expectEqualStrings("render?[31m?", label.text());
    safeName(label.name[0..16], "very-long-thread-name");
    try std.testing.expectEqual(@as(usize, 15), label.text().len);
    safeName(&label.name, "caf\xc3\xa9");
    try std.testing.expectEqualStrings("caf\xc3\xa9", label.text());
    try std.testing.expectEqualStrings("/tools/Proton X", protonRoot("/tools/Proton X/files/lib/wine/ntdll.so").?);
    try std.testing.expect(protonRoot("/usr/lib/wine/ntdll.so") == null);
    try std.testing.expect(protonRoot("/tools/not-wine/files/lib/wine/ntdll.so") == null);
}
