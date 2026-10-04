//! Linux x86-64 ELF cores. Metadata is retained; PT_LOAD bytes are read lazily
//! from the opened file. Omitted memory is unavailable, never implicit zeroes.
const std = @import("std");
const c = @import("../c.zig").api;
pub const Segment = struct { start: u64, end: u64, offset: u64, stored: u64, flags: u32 };
pub const Mapping = struct { start: u64, end: u64, offset: u64, path: []const u8 };
pub const Thread = struct { tid: i32, signal: u16, regs: [27]u64, fp: ?[]const u8 = null, xstate: ?[]const u8 = null, signal_info: ?Signal = null };
pub const Signal = struct { number: i32, code: i32, errno: i32, address: ?u64 = null };
pub const Core = struct {
    arena: std.heap.ArenaAllocator,
    fd: c_int = -1,
    path: []const u8 = "",
    size: u64 = 0,
    modified: c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 },
    changed: c.timespec = .{ .tv_sec = 0, .tv_nsec = 0 },
    segments: std.ArrayList(Segment) = .empty,
    mappings: std.ArrayList(Mapping) = .empty,
    threads: std.ArrayList(Thread) = .empty,
    signal: ?Signal = null,
    pid: i32 = 0,
    command: []const u8 = "",
    page_size: u64 = 4096,
    note_bytes: usize = 0,
    pub fn open(a: std.mem.Allocator, path: []const u8) !Core {
        var self = Core{ .arena = std.heap.ArenaAllocator.init(a) };
        errdefer self.deinit();
        const alloc = self.arena.allocator();
        const z = try alloc.dupeZ(u8, path);
        self.path = z;
        self.fd = c.open(z, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (self.fd < 0) return error.CoreFileUnavailable;
        var stat: c.struct_stat = undefined;
        if (c.fstat(self.fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size < 64) return error.InvalidCoreFile;
        self.size = @intCast(stat.st_size);
        self.modified = stat.st_mtim;
        self.changed = stat.st_ctim;
        var header: [64]u8 = undefined;
        try self.exact(0, &header);
        if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1 or header[6] != 1 or u16le(&header, 16) != 4 or u32le(&header, 20) != 1) return error.UnsupportedCoreFormat;
        if (u16le(&header, 18) != 62) return error.UnsupportedCoreArchitecture;
        if (u16le(&header, 52) != 64 or u16le(&header, 54) != 56) return error.InvalidCoreHeader;
        const phoff = u64le(&header, 32);
        const count = u16le(&header, 56);
        if (count == 0 or count > 4096) return error.CoreSegmentLimit;
        if (phoff < 64) return error.InvalidCoreHeader;
        for (0..count) |i| {
            var raw: [56]u8 = undefined;
            try self.exact(try add(phoff, i * 56), &raw);
            const kind = u32le(&raw, 0);
            const offset = u64le(&raw, 8);
            const stored = u64le(&raw, 32);
            if (offset > self.size or stored > self.size - offset) return error.TruncatedCore;
            if (kind == 1) {
                const start = u64le(&raw, 16);
                const length = u64le(&raw, 40);
                if (stored > length) return error.InvalidCoreSegment;
                if (length > 0) try self.segments.append(alloc, .{ .start = start, .end = try add(start, length), .offset = offset, .stored = stored, .flags = u32le(&raw, 4) });
            } else if (kind == 4) {
                if (stored > 32 * 1024 * 1024 - self.note_bytes) return error.CoreNoteLimit;
                self.note_bytes += @intCast(stored);
                const bytes = try alloc.alloc(u8, @intCast(stored));
                try self.exact(offset, bytes);
                try self.notes(bytes);
            }
        }
        std.mem.sort(Segment, self.segments.items, {}, struct {
            fn less(_: void, x: Segment, y: Segment) bool {
                return x.start < y.start;
            }
        }.less);
        for (self.segments.items, 0..) |segment, i| if (i > 0 and segment.start < self.segments.items[i - 1].end) return error.OverlappingCoreSegments;
        if (self.threads.items.len == 0) return error.CoreRegistersMissing;
        if (self.pid == 0) self.pid = self.threads.items[0].tid;
        try self.unchanged();
        return self;
    }
    pub fn deinit(self: *Core) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.arena.deinit();
        self.fd = -1;
    }
    fn unchanged(self: *const Core) !void {
        var stat: c.struct_stat = undefined;
        if (c.fstat(self.fd, &stat) != 0 or stat.st_size < 0 or @as(u64, @intCast(stat.st_size)) != self.size or stat.st_mtim.tv_sec != self.modified.tv_sec or stat.st_mtim.tv_nsec != self.modified.tv_nsec or stat.st_ctim.tv_sec != self.changed.tv_sec or stat.st_ctim.tv_nsec != self.changed.tv_nsec) return error.CoreFileChanged;
    }
    fn exact(self: *const Core, offset: u64, out: []u8) !void {
        if (offset > self.size or out.len > self.size - offset or offset > std.math.maxInt(i64)) return error.TruncatedCore;
        var done: usize = 0;
        while (done < out.len) {
            const n = c.pread(self.fd, out[done..].ptr, out.len - done, @intCast(offset + done));
            if (n < 0 and std.c._errno().* == c.EINTR) continue;
            if (n <= 0) return error.TruncatedCore;
            done += @intCast(n);
        }
    }
    pub fn read(self: *const Core, address: u64, out: []u8) !usize {
        if (out.len == 0) return 0;
        _ = try add(address, out.len);
        try self.unchanged();
        var done: usize = 0;
        while (done < out.len) {
            const at = address + done;
            var low: usize = 0;
            var high = self.segments.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (self.segments.items[mid].end <= at) low = mid + 1 else high = mid;
            }
            if (low == self.segments.items.len) break;
            const segment = self.segments.items[low];
            if (at < segment.start or at - segment.start >= segment.stored) break;
            const n: usize = @intCast(@min(out.len - done, segment.stored - (at - segment.start)));
            try self.exact(try add(segment.offset, at - segment.start), out[done..][0..n]);
            done += n;
        }
        try self.unchanged();
        if (done == 0) return error.CoreMemoryOmitted;
        return done;
    }
    pub fn thread(self: *const Core, tid: i32) !*const Thread {
        for (self.threads.items) |*item| if (item.tid == tid) return item;
        return error.UnknownThread;
    }
    fn notes(self: *Core, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            if (bytes.len - pos < 12) return error.MalformedCoreNote;
            const names = u32le(bytes, pos);
            const size = u32le(bytes, pos + 4);
            const kind = u32le(bytes, pos + 8);
            pos += 12;
            const name_size = try padded(names);
            const desc_size = try padded(size);
            if (name_size > bytes.len - pos) return error.MalformedCoreNote;
            const name = bytes[pos..][0..names];
            pos += name_size;
            if (desc_size > bytes.len - pos) return error.MalformedCoreNote;
            const desc = bytes[pos..][0..size];
            pos += desc_size;
            const core = std.mem.eql(u8, name, "CORE\x00") or std.mem.eql(u8, name, "CORE");
            const linux = std.mem.eql(u8, name, "LINUX\x00") or std.mem.eql(u8, name, "LINUX");
            if (!core and !linux) continue;
            const a = self.arena.allocator();
            if (core and kind == 1) {
                if (desc.len != 336) return error.InvalidCoreRegisters;
                if (self.threads.items.len >= 1024) return error.CoreThreadLimit;
                const tid = @as(i32, @bitCast(u32le(desc, 32)));
                if (tid <= 0) return error.InvalidCoreRegisters;
                for (self.threads.items) |t| if (t.tid == tid) return error.DuplicateCoreThread;
                var value = Thread{ .tid = tid, .signal = u16le(desc, 12), .regs = undefined };
                for (&value.regs, 0..) |*r, i| r.* = u64le(desc, 112 + i * 8);
                try self.threads.append(a, value);
            } else if (core and kind == 3) {
                if (desc.len != 136) return error.InvalidCoreProcessInfo;
                self.pid = @bitCast(u32le(desc, 24));
                if (self.pid <= 0) return error.InvalidCoreProcessInfo;
                self.command = std.mem.sliceTo(desc[56..136], 0);
            } else if (core and kind == 0x53494749) {
                if (desc.len != 128) return error.InvalidCoreSignal;
                const number: i32 = @bitCast(u32le(desc, 0));
                const code: i32 = @bitCast(u32le(desc, 8));
                const signal = Signal{ .number = number, .code = code, .errno = @bitCast(u32le(desc, 4)), .address = if (code > 0 and (number == 4 or number == 7 or number == 8 or number == 11)) u64le(desc, 16) else null };
                if (self.threads.items.len == 0) return error.CoreSignalWithoutThread;
                const t = &self.threads.items[self.threads.items.len - 1];
                if (t.signal_info != null) return error.DuplicateCoreSignal;
                t.signal_info = signal;
                if (self.threads.items.len == 1) self.signal = signal;
            } else if (core and kind == 0x46494c45) {
                if (desc.len < 16 or self.mappings.items.len != 0) return error.InvalidCoreFileNotes;
                const count = u64le(desc, 0);
                self.page_size = u64le(desc, 8);
                if (count > 65536 or self.page_size == 0 or self.page_size > 1024 * 1024 or !std.math.isPowerOfTwo(self.page_size)) return error.CoreMappingLimit;
                const start = 16 + count * 24;
                if (start > desc.len) return error.InvalidCoreFileNotes;
                var name_pos: usize = @intCast(start);
                for (0..@intCast(count)) |i| {
                    const end = std.mem.indexOfScalarPos(u8, desc, name_pos, 0) orelse return error.InvalidCoreFileNotes;
                    const path = desc[name_pos..end];
                    if (path.len > 4096) return error.CorePathLimit;
                    name_pos = end + 1;
                    const begin = u64le(desc, 16 + i * 24);
                    const finish = u64le(desc, 24 + i * 24);
                    if (finish <= begin) return error.InvalidCoreFileNotes;
                    const offset = std.math.mul(u64, u64le(desc, 32 + i * 24), self.page_size) catch return error.InvalidCoreFileNotes;
                    try self.mappings.append(a, .{ .start = begin, .end = finish, .offset = offset, .path = path });
                }
            } else if ((core and kind == 2) or (linux and kind == 0x202)) {
                if (self.threads.items.len == 0 or desc.len > 65536 or desc.len < 512) return error.InvalidCoreFpRegisters;
                const t = &self.threads.items[self.threads.items.len - 1];
                if (kind == 2) {
                    if (t.fp != null) return error.DuplicateCoreFpRegisters;
                    t.fp = desc;
                } else {
                    if (t.xstate != null) return error.DuplicateCoreFpRegisters;
                    t.xstate = desc;
                }
            }
        }
    }
    fn mappedFileBytes(self: *const Core, path: []const u8, offset: u64, out: []u8) !usize {
        var done: usize = 0;
        while (done < out.len) {
            const at = try add(offset, done);
            var progressed = false;
            for (self.mappings.items) |mapping| {
                if (!std.mem.eql(u8, mapping.path, path) or at < mapping.offset or at - mapping.offset >= mapping.end - mapping.start) continue;
                const relative = at - mapping.offset;
                const wanted: usize = @intCast(@min(out.len - done, mapping.end - mapping.start - relative));
                const n = self.read(try add(mapping.start, relative), out[done..][0..wanted]) catch |err| {
                    if (err == error.CoreMemoryOmitted) continue;
                    return err;
                };
                done += n;
                progressed = true;
                break;
            }
            if (!progressed) break;
        }
        if (done == 0) return error.CoreModuleIdentityUnavailable;
        return done;
    }
    /// Identity from captured ELF headers/notes only, independent of host files.
    /// Missing headers mean symbols cannot be authenticated by this first path.
    pub fn buildId(self: *const Core, a: std.mem.Allocator, mapping: Mapping) ![]const u8 {
        if (mapping.offset != 0) return error.CoreModuleIdentityUnavailable;
        var header: [64]u8 = undefined;
        if (try self.read(mapping.start, &header) != header.len) return error.CoreModuleIdentityUnavailable;
        if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1 or u16le(&header, 18) != 62 or u16le(&header, 54) != 56) return error.CoreModuleIdentityUnavailable;
        const count = u16le(&header, 56);
        if (count == 0 or count > 4096) return error.CoreModuleIdentityUnavailable;
        const table = try a.alloc(u8, @as(usize, count) * 56);
        defer a.free(table);
        if (try self.read(try add(mapping.start, u64le(&header, 32)), table) != table.len) return error.CoreModuleIdentityUnavailable;
        var found: ?[]const u8 = null;
        errdefer if (found) |id| a.free(id);
        for (0..count) |i| {
            const ph = table[i * 56 ..][0..56];
            if (u32le(ph, 0) != 4) continue;
            const size = u64le(ph, 32);
            if (size > 65536) return error.CoreModuleNoteLimit;
            const bytes = try a.alloc(u8, @intCast(size));
            defer a.free(bytes);
            if (try self.mappedFileBytes(mapping.path, u64le(ph, 8), bytes) != bytes.len) return error.CoreModuleIdentityUnavailable;
            var pos: usize = 0;
            while (pos < bytes.len) {
                if (bytes.len - pos < 12) return error.MalformedCoreNote;
                const names = u32le(bytes, pos);
                const length = u32le(bytes, pos + 4);
                const kind = u32le(bytes, pos + 8);
                pos += 12;
                const ns = try padded(names);
                const ds = try padded(length);
                if (ns > bytes.len - pos) return error.MalformedCoreNote;
                const name = bytes[pos..][0..names];
                pos += ns;
                if (ds > bytes.len - pos) return error.MalformedCoreNote;
                const value = bytes[pos..][0..length];
                pos += ds;
                if (kind == 3 and std.mem.eql(u8, name, "GNU\x00")) {
                    if (value.len == 0 or value.len > 64) return error.CoreModuleIdentityUnavailable;
                    if (found) |old| {
                        if (!std.mem.eql(u8, old, value)) return error.CoreModuleIdentityUnavailable;
                    } else found = try a.dupe(u8, value);
                }
            }
        }
        return found orelse error.CoreModuleIdentityUnavailable;
    }
};
fn add(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b) catch error.InvalidCoreAddress;
}
fn padded(n: u32) !usize {
    return (std.math.add(usize, n, 3) catch return error.MalformedCoreNote) & ~@as(usize, 3);
}
fn u16le(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}
fn u32le(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn u64le(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

test "core notes retain per-thread signal identity and reject malformed metadata" {
    var self = Core{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator) };
    defer self.deinit();
    const a = self.arena.allocator();
    const Note = struct {
        fn make(alloc: std.mem.Allocator, kind: u32, desc: []const u8) ![]u8 {
            const out = try alloc.alloc(u8, 20 + try padded(@intCast(desc.len)));
            @memset(out, 0);
            std.mem.writeInt(u32, out[0..4], 5, .little);
            std.mem.writeInt(u32, out[4..8], @intCast(desc.len), .little);
            std.mem.writeInt(u32, out[8..12], kind, .little);
            @memcpy(out[12..17], "CORE\x00");
            @memcpy(out[20..][0..desc.len], desc);
            return out;
        }
    };
    var regs: [336]u8 = @splat(0);
    std.mem.writeInt(u32, regs[32..36], 101, .little);
    try self.notes(try Note.make(a, 1, &regs));
    var signal: [128]u8 = @splat(0);
    std.mem.writeInt(u32, signal[0..4], 11, .little);
    std.mem.writeInt(u32, signal[8..12], 1, .little);
    std.mem.writeInt(u64, signal[16..24], 0x12345000, .little);
    try self.notes(try Note.make(a, 0x53494749, &signal));
    std.mem.writeInt(u32, regs[32..36], 102, .little);
    try self.notes(try Note.make(a, 1, &regs));
    std.mem.writeInt(u32, signal[0..4], 19, .little);
    std.mem.writeInt(i32, signal[8..12], -6, .little);
    try self.notes(try Note.make(a, 0x53494749, &signal));
    try std.testing.expectEqual(@as(i32, 11), self.signal.?.number);
    try std.testing.expectEqual(@as(?u64, 0x12345000), self.threads.items[0].signal_info.?.address);
    try std.testing.expectEqual(@as(i32, 19), self.threads.items[1].signal_info.?.number);
    try std.testing.expectEqual(null, self.threads.items[1].signal_info.?.address);
    try std.testing.expectError(error.DuplicateCoreThread, self.notes(try Note.make(a, 1, &regs)));
    try std.testing.expectError(error.InvalidCoreRegisters, self.notes(try Note.make(a, 1, regs[0..335])));
    const broken = try Note.make(a, 1, &regs);
    try std.testing.expectError(error.MalformedCoreNote, self.notes(broken[0 .. broken.len - 1]));
    var files: [16]u8 = @splat(0);
    std.mem.writeInt(u64, files[0..8], 65537, .little);
    std.mem.writeInt(u64, files[8..16], 4096, .little);
    try std.testing.expectError(error.CoreMappingLimit, self.notes(try Note.make(a, 0x46494c45, &files)));
}
