//! Linux ELF cores for x86-64 and aarch64. Metadata is retained; PT_LOAD bytes are read lazily
//! from the opened file. Omitted memory is unavailable, never implicit zeroes.
const std = @import("std");
const c = @import("../c.zig").api;
pub const Segment = struct { start: u64, end: u64, offset: u64, stored: u64, flags: u32, phys: u64 = 0 };
pub const Mapping = struct { start: u64, end: u64, offset: u64, path: []const u8 };
pub const Thread = struct { tid: i32, signal: u16, regs: [34]u64 = @splat(0), reg_words: u8 = 27, fp: ?[]const u8 = null, xstate: ?[]const u8 = null, signal_info: ?Signal = null };
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
    /// AT_SYSINFO_EHDR from NT_AUXV: where the kernel mapped [vdso].
    vdso: ?u64 = null,
    note_bytes: usize = 0,
    /// Set when a VMCOREINFO note is present. User cores leave it false.
    kernel: bool = false,
    /// The note body. A malformed key is ignored; it does not fail open.
    vmcore: []const u8 = "",
    /// First positive crash-note pid, used when the core has no process note.
    noted_pid: i32 = 0,
    page_root: ?u64 = null,
    page_offset: ?u64 = null,
    /// 4 or 5 once VMCOREINFO is present. The note's pgtable level selects 5.
    page_levels: u8 = 0,
    phys_base: ?u64 = null,
    stext: ?u64 = null,
    /// ELF e_machine. 62 is x86-64. 183 is aarch64.
    machine: u16 = 0,
    /// From VMCOREINFO NUMBER(VA_BITS). Zero means the note did not say.
    va_bits: u8 = 0,
    /// Kernel virtual address minus its physical address, when the note has it.
    kimage_voffset: ?u64 = null,
    /// Segment indices ordered by physical address. Empty means scan.
    phys_order: []u32 = &.{},
    /// For each prefix of `phys_order`, the segment whose physical end reaches farthest.
    /// A shorter segment can sit inside a longer one's physical range.
    phys_reach: []u32 = &.{},
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
        const machine = u16le(&header, 18);
        if (machine != 62 and machine != 183) return error.UnsupportedCoreArchitecture;
        self.machine = machine;
        // e_ehsize is not checked: QEMU's paged dump-guest-memory writes 8 there,
        // and readelf and GDB ignore it. The program-header size still has to fit.
        if (u16le(&header, 54) != 56) return error.InvalidCoreHeader;
        const phoff = u64le(&header, 32);
        var count: u32 = u16le(&header, 56);
        // A paged guest dump stores the real program-header count in the
        // first section header when the ELF count field is saturated.
        if (count == 0xffff) {
            const shoff = u64le(&header, 40);
            const shentsize = u16le(&header, 58);
            if (shoff < 64 or shentsize < 48 or shentsize > 4096) return error.InvalidCoreHeader;
            var shdr: [48]u8 = undefined;
            try self.exact(shoff, &shdr);
            count = u32le(&shdr, 44);
        }
        if (count == 0 or count > 262144) return error.CoreSegmentLimit;
        if (phoff < 64) return error.InvalidCoreHeader;
        var note_blobs: std.ArrayList([]u8) = .empty;
        for (0..count) |i| {
            var raw: [56]u8 = undefined;
            try self.exact(try add(phoff, @as(u64, i) * 56), &raw);
            const kind = u32le(&raw, 0);
            const offset = u64le(&raw, 8);
            const stored = u64le(&raw, 32);
            if (offset > self.size or stored > self.size - offset) return error.TruncatedCore;
            if (kind == 1) {
                const start = u64le(&raw, 16);
                const length = u64le(&raw, 40);
                if (stored > length) return error.InvalidCoreSegment;
                if (length > 0) try self.segments.append(alloc, .{ .start = start, .end = try add(start, length), .offset = offset, .stored = stored, .flags = u32le(&raw, 4), .phys = u64le(&raw, 24) });
            } else if (kind == 4) {
                if (stored > 32 * 1024 * 1024 - self.note_bytes) return error.CoreNoteLimit;
                self.note_bytes += @intCast(stored);
                const bytes = try alloc.alloc(u8, @intCast(stored));
                try self.exact(offset, bytes);
                try note_blobs.append(alloc, bytes);
            }
        }
        std.mem.sort(Segment, self.segments.items, {}, struct {
            fn less(_: void, x: Segment, y: Segment) bool {
                return x.start < y.start;
            }
        }.less);
        for (note_blobs.items) |bytes| try self.walkNotes(bytes, .vmcore);
        if (self.kernel and self.page_levels == 0) self.page_levels = if (self.machine == 183) armLevels(if (self.va_bits == 0) 48 else self.va_bits) else 4;
        if (!self.kernel) self.markKernelImage();
        try self.trimOverlaps();
        self.inferPageOffset();
        for (note_blobs.items) |bytes| try self.walkNotes(bytes, .rest);
        if (self.threads.items.len == 0) return error.CoreRegistersMissing;
        if (self.pid == 0) self.pid = if (self.kernel) if (self.noted_pid > 0) self.noted_pid else 1 else self.threads.items[0].tid;
        try self.indexPhys();
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
            switch (self.locate(at)) {
                .bytes => |hit| {
                    const n: usize = @min(out.len - done, hit.n);
                    try self.exact(hit.file, out[done..][0..n]);
                    done += n;
                },
                .hole => break,
                .miss => {
                    const phys = self.translate(at) orelse break;
                    const hit = self.physBytes(phys) orelse break;
                    const page_left = @as(usize, 4096) - @as(usize, @intCast(phys & 0xfff));
                    const n: usize = @min(out.len - done, @min(hit.n, page_left));
                    if (n == 0) break;
                    try self.exact(hit.file, out[done..][0..n]);
                    done += n;
                },
            }
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
        try self.walkNotes(bytes, .vmcore);
        try self.walkNotes(bytes, .rest);
    }
    const NotePass = enum { vmcore, rest };
    fn walkNotes(self: *Core, bytes: []const u8, pass: NotePass) !void {
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
            const label = std.mem.sliceTo(name, 0);
            if (std.mem.eql(u8, label, "VMCOREINFO")) {
                if (pass == .vmcore) self.takeVmcore(desc);
                continue;
            }
            if (pass == .vmcore) continue;
            const core = std.mem.eql(u8, name, "CORE\x00") or std.mem.eql(u8, name, "CORE");
            const linux = std.mem.eql(u8, name, "LINUX\x00") or std.mem.eql(u8, name, "LINUX");
            if (!core and !linux) continue;
            const a = self.arena.allocator();
            if (core and kind == 1) {
                const words: usize = if (self.machine == 183) 34 else 27;
                const expect: usize = if (self.machine == 183) 392 else 336;
                if (desc.len != expect) return error.InvalidCoreRegisters;
                if (self.threads.items.len >= 1024) return error.CoreThreadLimit;
                const noted = @as(i32, @bitCast(u32le(desc, 32)));
                const tid: i32 = if (self.kernel) blk: {
                    if (noted > 0 and self.noted_pid == 0) self.noted_pid = noted;
                    break :blk 0x60000000 + @as(i32, @intCast(self.threads.items.len)) + 2;
                } else noted;
                if (tid <= 0) return error.InvalidCoreRegisters;
                for (self.threads.items) |t| if (t.tid == tid) return error.DuplicateCoreThread;
                var value = Thread{ .tid = tid, .signal = u16le(desc, 12), .reg_words = @intCast(words) };
                for (value.regs[0..words], 0..) |*r, i| r.* = u64le(desc, 112 + i * 8);
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
            } else if (core and kind == 6) {
                var at: usize = 0;
                while (at + 16 <= desc.len) : (at += 16) {
                    const key = u64le(desc, at);
                    if (key == 0) break;
                    if (key == 33 and u64le(desc, at + 8) != 0) self.vdso = u64le(desc, at + 8);
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
            // The ordinary dump filter retains ELF header pages but can omit
            // later file-backed notes (for example GNU properties). Only a
            // fully captured note segment supplies identity; an omitted one
            // must not discard a build ID captured in another segment.
            const captured = self.mappedFileBytes(mapping.path, u64le(ph, 8), bytes) catch |err| {
                if (err == error.CoreModuleIdentityUnavailable) continue;
                return err;
            };
            if (captured != bytes.len) continue;
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
    const Located = union(enum) { bytes: struct { file: u64, n: usize }, hole, miss };

fn markKernelImage(self: *Core) void {
    if (self.segments.items.len == 0) return;
    for (self.segments.items) |seg| if (seg.start >> 63 == 0) return;
    // Every load is a kernel virtual address, as in a live kcore. There is no
    // page-table root here, so the level stays zero and reads use the segments.
    self.kernel = true;
}

fn takeVmcore(self: *Core, desc: []const u8) void {
    self.kernel = true;
    self.vmcore = desc;
    var lines = std.mem.splitScalar(u8, desc, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "NUMBER(PAGE_OFFSET)=")) {
            if (parseNum(line["NUMBER(PAGE_OFFSET)=".len..])) |n| self.page_offset = n;
        } else if (std.mem.startsWith(u8, line, "PAGE_OFFSET=")) {
            if (parseNum(line["PAGE_OFFSET=".len..])) |n| self.page_offset = n;
        } else if (std.mem.startsWith(u8, line, "SYMBOL(init_top_pgt)=")) {
            if (parseHexKey(line["SYMBOL(init_top_pgt)=".len..])) |n| self.page_root = n;
        } else if (std.mem.startsWith(u8, line, "NUMBER(pgtable_l5_enabled)=")) {
            if (parseNum(line["NUMBER(pgtable_l5_enabled)=".len..])) |n| self.page_levels = if (n == 0) 4 else 5;
        } else if (std.mem.startsWith(u8, line, "NUMBER(phys_base)=")) {
            if (parseNum(line["NUMBER(phys_base)=".len..])) |n| self.phys_base = n;
        } else if (std.mem.startsWith(u8, line, "SYMBOL(_stext)=")) {
            if (parseHexKey(line["SYMBOL(_stext)=".len..])) |n| self.stext = n;
        } else if (std.mem.startsWith(u8, line, "SYMBOL(swapper_pg_dir)=")) {
            if (self.page_root == null) {
                if (parseHexKey(line["SYMBOL(swapper_pg_dir)=".len..])) |n| self.page_root = n;
            }
        } else if (std.mem.startsWith(u8, line, "NUMBER(VA_BITS)=")) {
            if (parseNum(line["NUMBER(VA_BITS)=".len..])) |n| if (n >= 39 and n <= 52) {
                self.va_bits = @intCast(n);
                if (self.page_levels == 0) self.page_levels = armLevels(self.va_bits);
            };
        } else if (std.mem.startsWith(u8, line, "NUMBER(kimage_voffset)=")) {
            if (parseHexKey(line["NUMBER(kimage_voffset)=".len..])) |n| self.kimage_voffset = n;
        }
    }
}

fn trimOverlaps(self: *Core) !void {
    const crowded = self.segments.items.len > 4096 or self.kernel;
    var i: usize = 1;
    while (i < self.segments.items.len) {
        const prev = self.segments.items[i - 1];
        if (self.segments.items[i].start >= prev.end) {
            i += 1;
            continue;
        }
        if (!crowded) return error.OverlappingCoreSegments;
        const skip = prev.end - self.segments.items[i].start;
        const span = self.segments.items[i].end - self.segments.items[i].start;
        if (skip >= span) {
            _ = self.segments.orderedRemove(i);
            continue;
        }
        self.segments.items[i].start += skip;
        self.segments.items[i].phys +%= skip;
        if (skip >= self.segments.items[i].stored) self.segments.items[i].stored = 0 else {
            self.segments.items[i].offset += skip;
            self.segments.items[i].stored -= skip;
        }
        i += 1;
    }
}

fn inferPageOffset(self: *Core) void {
    if (!self.kernel or self.page_offset != null) return;
    var best: u64 = 0;
    var delta: ?u64 = null;
    for (self.segments.items) |seg| {
        if (self.stext) |stext| if (stext >= seg.start and stext < seg.end) continue;
        if (seg.stored <= best) continue;
        best = seg.stored;
        delta = seg.start -% seg.phys;
    }
    self.page_offset = delta;
}

fn locate(self: *const Core, at: u64) Located {
    var low: usize = 0;
    var high = self.segments.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.segments.items[mid].end <= at) low = mid + 1 else high = mid;
    }
    if (low == self.segments.items.len) return .miss;
    const segment = self.segments.items[low];
    if (at < segment.start) return .miss;
    const off = at - segment.start;
    if (off >= segment.stored) return .hole;
    return .{ .bytes = .{ .file = segment.offset + off, .n = @intCast(segment.stored - off) } };
}

fn armLevels(va_bits: u8) u8 {
    if (va_bits < 39) return 4;
    const n: u8 = @intCast((@as(u16, va_bits) - 4) / 9);
    if (n < 3) return 3;
    if (n > 5) return 5;
    return n;
}

fn translate(self: *const Core, virt: u64) ?u64 {
    if (self.machine == 183) return self.translateArm(virt);
    const root = self.page_root orelse return null;
    const levels: u8 = if (self.page_levels == 5) 5 else if (self.page_levels == 4) 4 else return null;
    var table_pa: u64 = 0;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        const shift: u6 = @intCast(12 + @as(u16, 9) * @as(u16, levels - 1 - level));
        const index: u64 = (virt >> shift) & 0x1ff;
        const pte: u64 = if (level == 0) self.pteAtRoot(root, index) orelse return null else self.u64Phys(table_pa + index * 8) orelse return null;
        if (pte & 1 == 0) return null;
        const last = level + 1 == levels;
        const huge = !last and pte & (1 << 7) != 0;
        if (last or huge) {
            const page_shift: u6 = if (huge) shift else 12;
            const page_mask = (@as(u64, 1) << page_shift) - 1;
            const base = pte & 0x000ffffffffff000 & ~page_mask;
            return base + (virt & page_mask);
        }
        table_pa = pte & 0x000ffffffffff000;
    }
    return null;
}

/// aarch64 stage-1, 4 KiB pages. A 52-bit virtual address uses a short top
/// table. Descriptors use the type bits, not the x86 page-size bit. A 52-bit
/// physical address stores its top two bits in descriptor bits 9:8.
fn translateArm(self: *const Core, virt: u64) ?u64 {
    const root = self.page_root orelse return null;
    const levels: u8 = if (self.page_levels >= 3 and self.page_levels <= 5) self.page_levels else return null;
    const va_bits: u16 = if (self.va_bits == 0) 48 else self.va_bits;
    var table_pa: u64 = 0;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        const shift: u6 = @intCast(12 + @as(u16, 9) * @as(u16, levels - 1 - level));
        if (va_bits <= shift) return null;
        const span: u16 = va_bits - shift;
        const bits: u6 = if (level == 0) @intCast(@min(span, 9)) else 9;
        const index: u64 = (virt >> shift) & ((@as(u64, 1) << bits) - 1);
        const pte: u64 = if (level == 0) self.pteAtRoot(root, index) orelse return null else self.u64Phys(std.math.add(u64, table_pa, index * 8) catch return null) orelse return null;
        const kind = pte & 3;
        if (kind == 0 or kind == 2) return null;
        const last = level + 1 == levels;
        const block = kind == 1;
        if (last or block) {
            if (last and kind != 3) return null;
            const page_shift: u6 = if (block) shift else 12;
            const page_mask = (@as(u64, 1) << page_shift) - 1;
            const base = armPhys(pte, va_bits) & ~page_mask;
            return base + (virt & page_mask);
        }
        table_pa = armPhys(pte, va_bits);
    }
    return null;
}

fn pteAtRoot(self: *const Core, root: u64, index: u64) ?u64 {
    const va = std.math.add(u64, root, index * 8) catch return null;
    if (self.u64Virt(va)) |word| return word;
    const phys = self.rootPhys(root) orelse return null;
    return self.u64Phys(std.math.add(u64, phys, index * 8) catch return null);
}

fn rootPhys(self: *const Core, root: u64) ?u64 {
    if (self.stext) |stext| if (root >= stext) if (self.physFromVirtual(stext)) |stext_phys| return root -% stext +% stext_phys;
    if (self.kimage_voffset) |off| if (root >= off) return root -% off;
    const page = self.page_offset orelse return null;
    if (root < page) return null;
    return root - page;
}

fn physFromVirtual(self: *const Core, va: u64) ?u64 {
    var low: usize = 0;
    var high = self.segments.items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.segments.items[mid].end <= va) low = mid + 1 else high = mid;
    }
    if (low == self.segments.items.len) return null;
    const seg = self.segments.items[low];
    if (va < seg.start or va >= seg.end) return null;
    return seg.phys +% (va - seg.start);
}

fn indexPhys(self: *Core) !void {
    const n = self.segments.items.len;
    if (n == 0) return;
    const order = try self.arena.allocator().alloc(u32, n);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    std.mem.sort(u32, order, self.segments.items, struct {
        fn less(segs: []const Segment, x: u32, y: u32) bool {
            if (segs[x].phys == segs[y].phys) return segs[x].stored > segs[y].stored;
            return segs[x].phys < segs[y].phys;
        }
    }.less);
    const reach = try self.arena.allocator().alloc(u32, n);
    var best: u32 = order[0];
    var best_end: u64 = segmentEnd(self.segments.items[best]);
    for (order, 0..) |idx, at| {
        const end = segmentEnd(self.segments.items[idx]);
        if (end > best_end) {
            best = idx;
            best_end = end;
        }
        reach[at] = best;
    }
    self.phys_order = order;
    self.phys_reach = reach;
}

fn segmentEnd(seg: Segment) u64 {
    return seg.phys +% seg.stored;
}

const PhysHit = struct { file: u64, n: usize };

fn physBytes(self: *const Core, pa: u64) ?PhysHit {
    if (self.phys_order.len != self.segments.items.len or self.phys_reach.len != self.phys_order.len) return self.physBytesLinear(pa);
    var low: usize = 0;
    var high = self.phys_order.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (self.segments.items[self.phys_order[mid]].phys <= pa) low = mid + 1 else high = mid;
    }
    if (low == 0) return null;
    const seg = self.segments.items[self.phys_reach[low - 1]];
    if (seg.stored == 0 or pa < seg.phys) return null;
    const off = pa - seg.phys;
    if (off >= seg.stored) return null;
    return .{ .file = seg.offset + off, .n = @intCast(seg.stored - off) };
}

fn physBytesLinear(self: *const Core, pa: u64) ?PhysHit {
    for (self.segments.items) |seg| {
        if (seg.stored == 0 or pa < seg.phys) continue;
        const off = pa - seg.phys;
        if (off >= seg.stored) continue;
        return .{ .file = seg.offset + off, .n = @intCast(seg.stored - off) };
    }
    return null;
}

fn u64Virt(self: *const Core, va: u64) ?u64 {
    const hit = switch (self.locate(va)) {
        .bytes => |hit| hit,
        else => return null,
    };
    if (hit.n < 8) return null;
    var buf: [8]u8 = undefined;
    self.exact(hit.file, &buf) catch return null;
    return std.mem.readInt(u64, &buf, .little);
}

fn u64Phys(self: *const Core, pa: u64) ?u64 {
    const hit = self.physBytes(pa) orelse return null;
    if (hit.n < 8) return null;
    var buf: [8]u8 = undefined;
    self.exact(hit.file, &buf) catch return null;
    return std.mem.readInt(u64, &buf, .little);
}

fn parseNum(raw: []const u8) ?u64 {
    const body = std.mem.trim(u8, raw, " \t\r");
    if (body.len == 0) return null;
    const neg = body[0] == '-';
    const rest = if (neg) body[1..] else body;
    if (rest.len == 0) return null;
    const hex = std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X");
    const digits = if (hex) rest[2..] else rest;
    if (digits.len == 0) return null;
    const mag = std.fmt.parseInt(u64, digits, if (hex) 16 else 10) catch return null;
    if (!neg) return mag;
    if (mag > @as(u64, std.math.maxInt(i64))) return null;
    return @bitCast(-@as(i64, @intCast(mag)));
}

fn parseHexKey(raw: []const u8) ?u64 {
    const body = std.mem.trim(u8, raw, " \t\r");
    if (body.len == 0) return null;
    const digits = if (std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X")) body[2..] else body;
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u64, digits, 16) catch null;
}

};
fn armPhys(pte: u64, va_bits: u16) u64 {
    if (va_bits <= 48) return pte & 0x0000fffffffff000;
    const low = pte & 0x0003fffffffff000;
    const high = (pte >> 8) & 3;
    return low | (high << 50);
}
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

test "core module identity survives unrelated omitted note segments" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: [4096]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    std.mem.writeInt(u16, bytes[18..20], 62, .little);
    std.mem.writeInt(u64, bytes[32..40], 64, .little);
    std.mem.writeInt(u16, bytes[54..56], 56, .little);
    std.mem.writeInt(u16, bytes[56..58], 2, .little);
    for (0..2) |i| {
        const ph = bytes[64 + i * 56 ..][0..56];
        std.mem.writeInt(u32, ph[0..4], 4, .little);
        std.mem.writeInt(u64, ph[8..16], if (i == 0) 512 else 8192, .little);
        std.mem.writeInt(u64, ph[32..40], 20, .little);
    }
    std.mem.writeInt(u32, bytes[512..516], 4, .little);
    std.mem.writeInt(u32, bytes[516..520], 4, .little);
    std.mem.writeInt(u32, bytes[520..524], 3, .little);
    @memcpy(bytes[524..528], "GNU\x00");
    @memcpy(bytes[528..532], "test");
    const file = try tmp.dir.createFile(std.testing.io, "captured-pages", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &bytes);
    var core = Core{ .arena = std.heap.ArenaAllocator.init(a) };
    defer core.deinit();
    core.fd = c.dup(file.handle);
    try std.testing.expect(core.fd >= 0);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(core.fd, &stat));
    core.size = @intCast(stat.st_size);
    core.modified = stat.st_mtim;
    core.changed = stat.st_ctim;
    try core.segments.append(core.arena.allocator(), .{ .start = 0x10000, .end = 0x13000, .offset = 0, .stored = bytes.len, .flags = 4 });
    const mapping = Mapping{ .start = 0x10000, .end = 0x13000, .offset = 0, .path = "python-fixture" };
    try core.mappings.append(core.arena.allocator(), mapping);
    const id = try core.buildId(a, mapping);
    defer a.free(id);
    try std.testing.expectEqualStrings("test", id);
    // Omitted notes can precede the captured build-ID note as well.
    std.mem.swap([56]u8, bytes[64..120], bytes[120..176]);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(core.fd, &stat));
    core.modified = stat.st_mtim;
    core.changed = stat.st_ctim;
    const reordered = try core.buildId(a, mapping);
    defer a.free(reordered);
    try std.testing.expectEqualStrings("test", reordered);
    // A partially captured unrelated segment is equally unavailable.
    std.mem.writeInt(u64, bytes[72..80], 4090, .little);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(core.fd, &stat));
    core.modified = stat.st_mtim;
    core.changed = stat.st_ctim;
    const partial = try core.buildId(a, mapping);
    defer a.free(partial);
    try std.testing.expectEqualStrings("test", partial);
    // Without any captured build ID, host files still cannot establish it.
    core.segments.items[0].stored = 512;
    try std.testing.expectError(error.CoreModuleIdentityUnavailable, core.buildId(a, mapping));
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
    std.mem.writeInt(u32, regs[32..36], 0, .little);
    try std.testing.expectError(error.InvalidCoreRegisters, self.notes(try Note.make(a, 1, &regs)));
    const broken = try Note.make(a, 1, &regs);
    try std.testing.expectError(error.MalformedCoreNote, self.notes(broken[0 .. broken.len - 1]));
    var files: [16]u8 = @splat(0);
    std.mem.writeInt(u64, files[0..8], 65537, .little);
    std.mem.writeInt(u64, files[8..16], 4096, .little);
    try std.testing.expectError(error.CoreMappingLimit, self.notes(try Note.make(a, 0x46494c45, &files)));
}

fn pushNote(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, name: []const u8, kind: u32, desc: []const u8) !void {
    var hdr: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(name.len), .little);
    std.mem.writeInt(u32, hdr[4..8], @intCast(desc.len), .little);
    std.mem.writeInt(u32, hdr[8..12], kind, .little);
    try buf.appendSlice(alloc, &hdr);
    try buf.appendSlice(alloc, name);
    const name_pad = (4 - name.len % 4) % 4;
    try buf.appendNTimes(alloc, @as(u8, 0), name_pad);
    try buf.appendSlice(alloc, desc);
    const desc_pad = (4 - desc.len % 4) % 4;
    try buf.appendNTimes(alloc, @as(u8, 0), desc_pad);
}

fn pushPhdr(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, kind: u32, flags: u32, offset: u64, vaddr: u64, paddr: u64, filesz: u64, memsz: u64) !void {
    var raw: [56]u8 = @splat(0);
    std.mem.writeInt(u32, raw[0..4], kind, .little);
    std.mem.writeInt(u32, raw[4..8], flags, .little);
    std.mem.writeInt(u64, raw[8..16], offset, .little);
    std.mem.writeInt(u64, raw[16..24], vaddr, .little);
    std.mem.writeInt(u64, raw[24..32], paddr, .little);
    std.mem.writeInt(u64, raw[32..40], filesz, .little);
    std.mem.writeInt(u64, raw[40..48], memsz, .little);
    try buf.appendSlice(alloc, &raw);
}

fn elfHeader(phoff: u64, phnum: u16, shoff: u64, shentsize: u16, shnum: u16) [64]u8 {
    var header: [64]u8 = @splat(0);
    @memcpy(header[0..4], "\x7fELF");
    header[4] = 2;
    header[5] = 1;
    header[6] = 1;
    std.mem.writeInt(u16, header[16..18], 4, .little);
    std.mem.writeInt(u16, header[18..20], 62, .little);
    std.mem.writeInt(u32, header[20..24], 1, .little);
    std.mem.writeInt(u64, header[32..40], phoff, .little);
    std.mem.writeInt(u64, header[40..48], shoff, .little);
    std.mem.writeInt(u16, header[52..54], 64, .little);
    std.mem.writeInt(u16, header[54..56], 56, .little);
    std.mem.writeInt(u16, header[56..58], phnum, .little);
    std.mem.writeInt(u16, header[58..60], shentsize, .little);
    std.mem.writeInt(u16, header[60..62], shnum, .little);
    return header;
}

fn prstatus(pid: u32) [336]u8 {
    var regs: [336]u8 = @splat(0);
    std.mem.writeInt(u32, regs[32..36], pid, .little);
    return regs;
}

test "KGVM kernel core translates a virtual miss and accepts a zero crash-note pid" {
    const a = std.testing.allocator;
    var note: std.ArrayList(u8) = .empty;
    defer note.deinit(a);
    const zero = prstatus(0);
    try pushNote(&note, a, "CORE\x00", 1, &zero);
    try pushNote(&note, a, "CORE\x00", 1, &zero);
    const info = "PAGE_OFFSET=zz\nNUMBER(PAGE_OFFSET)=0xffff888000000000\nSYMBOL(init_top_pgt)=ffffffff80001000\nNUMBER(pgtable_l5_enabled)=0\nSYMBOL(_stext)=ffffffff80000000\nNUMBER(phys_base)=-127926272\n";
    try pushNote(&note, a, "VMCOREINFO\x00", 0, info);
    var pages: [0x6000]u8 = @splat(0);
    const virt: u64 = 0xffffc90000001000;
    const shifts = [_]u6{ 39, 30, 21, 12 };
    var idx: [4]usize = undefined;
    for (shifts, 0..) |shift, i| idx[i] = @intCast((virt >> shift) & 0x1ff);
    std.mem.writeInt(u64, pages[0x1000 + idx[0] * 8 ..][0..8], 1 | 0x102000, .little);
    std.mem.writeInt(u64, pages[0x2000 + idx[1] * 8 ..][0..8], 1 | 0x103000, .little);
    std.mem.writeInt(u64, pages[0x3000 + idx[2] * 8 ..][0..8], 1 | 0x104000, .little);
    std.mem.writeInt(u64, pages[0x4000 + idx[3] * 8 ..][0..8], 1 | 0x4000, .little);
    pages[0x5000] = 0x5a;
    const note_off: u64 = 64 + 3 * 56;
    const kern_off = note_off + note.items.len;
    const data_off = kern_off + 0x5000;
    var file_bytes: std.ArrayList(u8) = .empty;
    defer file_bytes.deinit(a);
    const header = elfHeader(64, 3, 0, 0, 0);
    try file_bytes.appendSlice(a, &header);
    try pushPhdr(&file_bytes, a, 4, 0, note_off, 0, 0, note.items.len, note.items.len);
    try pushPhdr(&file_bytes, a, 1, 5, kern_off, 0xffffffff80000000, 0x100000, 0x5000, 0x5000);
    try pushPhdr(&file_bytes, a, 1, 6, data_off, 0xffff888000004000, 0x4000, 0x1000, 0x1000);
    try file_bytes.appendSlice(a, note.items);
    try file_bytes.appendSlice(a, &pages);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "kernel-core", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, file_bytes.items);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "kernel-core", a);
    defer a.free(path);
    var core = try Core.open(a, path);
    defer core.deinit();
    try std.testing.expect(core.kernel);
    try std.testing.expectEqual(@as(u8, 4), core.page_levels);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -127926272))), core.phys_base.?);
    try std.testing.expectEqual(@as(usize, 2), core.threads.items.len);
    try std.testing.expectEqual(@as(i32, 0x60000002), core.threads.items[0].tid);
    try std.testing.expectEqual(@as(i32, 0x60000003), core.threads.items[1].tid);
    try std.testing.expectEqual(@as(i32, 1), core.pid);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try core.read(0xffff888000004000, &byte));
    try std.testing.expectEqual(@as(u8, 0x5a), byte[0]);
    byte[0] = 0;
    try std.testing.expectEqual(@as(usize, 1), try core.read(virt, &byte));
    try std.testing.expectEqual(@as(u8, 0x5a), byte[0]);
    try std.testing.expectError(error.CoreMemoryOmitted, core.read(0x2000, &byte));
}

test "KGVM five level large page uses the page offset when the root is not mapped" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pages: [0x5000]u8 = @splat(0);
    const virt: u64 = 0xffffc90000000100;
    const shifts = [_]u6{ 48, 39, 30, 21 };
    const next = [_]u64{ 0x2000, 0x3000, 0x4000, 1 | (1 << 7) | 0x200000 };
    for (shifts, 0..) |shift, level| {
        const index: usize = @intCast((virt >> shift) & 0x1ff);
        const value: u64 = if (level + 1 == shifts.len) next[level] else (1 | next[level]);
        std.mem.writeInt(u64, pages[level * 0x1000 + index * 8 ..][0..8], value, .little);
    }
    pages[0x4000 + 0x100] = 0xab;
    const file = try tmp.dir.createFile(std.testing.io, "pages", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &pages);
    var core = Core{ .arena = std.heap.ArenaAllocator.init(a) };
    defer core.deinit();
    core.fd = c.dup(file.handle);
    try std.testing.expect(core.fd >= 0);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(core.fd, &stat));
    core.size = @intCast(stat.st_size);
    core.modified = stat.st_mtim;
    core.changed = stat.st_ctim;
    core.kernel = true;
    core.page_levels = 5;
    core.page_offset = 0xff11000000000000;
    core.page_root = core.page_offset.? + 0x1000;
    try core.segments.append(core.arena.allocator(), .{ .start = 0xffffffff80000000, .end = 0xffffffff80004000, .offset = 0, .stored = 0x4000, .flags = 5, .phys = 0x1000 });
    try core.segments.append(core.arena.allocator(), .{ .start = 0xffff888000200000, .end = 0xffff888000201000, .offset = 0x4000, .stored = 0x1000, .flags = 6, .phys = 0x200000 });
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try core.read(virt, &byte));
    try std.testing.expectEqual(@as(u8, 0xab), byte[0]);
}

test "KGVM a nested physical segment does not hide the longer range" {
    const a = std.testing.allocator;
    var core = Core{ .arena = std.heap.ArenaAllocator.init(a) };
    defer core.deinit();
    const alloc = core.arena.allocator();
    try core.segments.append(alloc, .{ .start = 0, .end = 0x2000, .offset = 0x1000, .stored = 0x2000, .flags = 6, .phys = 0x200000 });
    try core.segments.append(alloc, .{ .start = 1, .end = 9, .offset = 0, .stored = 8, .flags = 5, .phys = 0x2000f0 });
    try core.indexPhys();
    const hit = core.physBytes(0x200100);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(@as(u64, 0x1100), hit.?.file);
    try std.testing.expect(core.physBytes(0x300000) == null);
}

test "KGVM an arm64 core walks a 52-bit table and keeps a read-only table entry" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pages: [0x6000]u8 = @splat(0);
    const virt: u64 = 0xffff800080001000;
    const shifts = [_]u6{ 48, 39, 30, 21, 12 };
    const next = [_]u64{ 0x2000, 0x3000, 0x4000, 0x5000, 0x6000 };
    const va_bits: u16 = 52;
    for (shifts, 0..) |shift, level| {
        const span: u16 = va_bits - shift;
        const bits: u6 = if (level == 0) @intCast(@min(span, 9)) else 9;
        const index: usize = @intCast((virt >> shift) & ((@as(u64, 1) << bits) - 1));
        const value: u64 = 3 | (1 << 7) | next[level];
        std.mem.writeInt(u64, pages[level * 0x1000 + index * 8 ..][0..8], value, .little);
    }
    pages[0x5000] = 0x5a;
    const file = try tmp.dir.createFile(std.testing.io, "arm-pages", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, &pages);
    var core = Core{ .arena = std.heap.ArenaAllocator.init(a) };
    defer core.deinit();
    core.fd = c.dup(file.handle);
    try std.testing.expect(core.fd >= 0);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.fstat(core.fd, &stat));
    core.size = @intCast(stat.st_size);
    core.modified = stat.st_mtim;
    core.changed = stat.st_ctim;
    core.kernel = true;
    core.machine = 183;
    core.va_bits = 52;
    core.page_levels = 5;
    core.page_root = 0xffff800081000000;
    try core.segments.append(core.arena.allocator(), .{ .start = core.page_root.?, .end = core.page_root.? + 0x6000, .offset = 0, .stored = 0x6000, .flags = 5, .phys = 0x1000 });
    try core.indexPhys();
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try core.read(virt, &byte));
    try std.testing.expectEqual(@as(u8, 0x5a), byte[0]);
    const high = armPhys(3 | (1 << 8) | 0x1000, 52);
    try std.testing.expectEqual(@as(u64, (1 << 50) | 0x1000), high);
}

test "KGVM an arm64 crash note is 392 bytes and names aarch64" {
    const a = std.testing.allocator;
    var note: std.ArrayList(u8) = .empty;
    defer note.deinit(a);
    var regs: [392]u8 = @splat(0);
    std.mem.writeInt(u32, regs[32..36], 1, .little);
    std.mem.writeInt(u64, regs[112 + 32 * 8 ..][0..8], 0xffff8000810ee454, .little);
    try pushNote(&note, a, "CORE\x00", 1, &regs);
    const info = "SYMBOL(swapper_pg_dir)=ffff800081e9c000\nNUMBER(VA_BITS)=52\nNUMBER(kimage_voffset)=0xffff80003fe00000\nSYMBOL(_stext)=ffff800080010000\nNUMBER(KERNELPACMASK)=0xfff0000000000000\n";
    try pushNote(&note, a, "VMCOREINFO\x00", 0, info);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var header = elfHeader(64, 2, 0, 0, 0);
    std.mem.writeInt(u16, header[18..20], 183, .little);
    try bytes.appendSlice(a, &header);
    const note_off: u64 = 64 + 2 * 56;
    try pushPhdr(&bytes, a, 4, 0, note_off, 0, 0, note.items.len, note.items.len);
    try pushPhdr(&bytes, a, 1, 5, note_off + note.items.len, 0xffff800080000000, 0x40000000, 1, 1);
    try bytes.appendSlice(a, note.items);
    try bytes.append(a, 0x11);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "arm-core", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes.items);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "arm-core", a);
    defer a.free(path);
    var core = try Core.open(a, path);
    defer core.deinit();
    try std.testing.expectEqual(@as(u16, 183), core.machine);
    try std.testing.expectEqual(@as(u8, 52), core.va_bits);
    try std.testing.expectEqual(@as(u8, 5), core.page_levels);
    try std.testing.expectEqual(@as(u64, 0xffff800081e9c000), core.page_root.?);
    try std.testing.expectEqual(@as(u64, 0xffff80003fe00000), core.kimage_voffset.?);
    try std.testing.expectEqual(@as(u8, 34), core.threads.items[0].reg_words);
    try std.testing.expectEqual(@as(u64, 0xffff8000810ee454), core.threads.items[0].regs[32]);
}

test "KGVM a user core still rejects overlapping segments and a saturated count uses the section header" {
    const a = std.testing.allocator;
    var note: std.ArrayList(u8) = .empty;
    defer note.deinit(a);
    const one = prstatus(3);
    try pushNote(&note, a, "CORE\x00", 1, &one);
    const note_off: u64 = 240;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var header = elfHeader(128, 0xffff, 64, 64, 1);
    try bytes.appendSlice(a, &header);
    var shdr: [64]u8 = @splat(0);
    std.mem.writeInt(u32, shdr[44..48], 2, .little);
    try bytes.appendSlice(a, &shdr);
    try pushPhdr(&bytes, a, 4, 0, note_off, 0, 0, note.items.len, note.items.len);
    try pushPhdr(&bytes, a, 1, 5, note_off + note.items.len, 0x400000, 0, 1, 1);
    try bytes.appendSlice(a, note.items);
    try bytes.append(a, 0x7e);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "saturated", .{ .read = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes.items);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "saturated", a);
    defer a.free(path);
    var core = try Core.open(a, path);
    defer core.deinit();
    try std.testing.expect(!core.kernel);
    try std.testing.expectEqual(@as(i32, 3), core.threads.items[0].tid);
    try std.testing.expectEqual(@as(usize, 1), core.segments.items.len);
    var overlap_note: std.ArrayList(u8) = .empty;
    defer overlap_note.deinit(a);
    const task = prstatus(9);
    try pushNote(&overlap_note, a, "CORE\x00", 1, &task);
    var overlap: std.ArrayList(u8) = .empty;
    defer overlap.deinit(a);
    header = elfHeader(64, 3, 0, 0, 0);
    try overlap.appendSlice(a, &header);
    const overlap_note_off: u64 = 64 + 3 * 56;
    try pushPhdr(&overlap, a, 4, 0, overlap_note_off, 0, 0, overlap_note.items.len, overlap_note.items.len);
    try pushPhdr(&overlap, a, 1, 5, overlap_note_off + overlap_note.items.len, 0x1000, 0, 1, 1);
    try pushPhdr(&overlap, a, 1, 5, overlap_note_off + overlap_note.items.len, 0x1000, 0, 1, 2);
    try overlap.appendSlice(a, overlap_note.items);
    try overlap.append(a, 0x11);
    const second = try tmp.dir.createFile(std.testing.io, "overlap", .{ .read = true });
    defer second.close(std.testing.io);
    try second.writeStreamingAll(std.testing.io, overlap.items);
    const overlap_path = try tmp.dir.realPathFileAlloc(std.testing.io, "overlap", a);
    defer a.free(overlap_path);
    try std.testing.expectError(error.OverlappingCoreSegments, Core.open(a, overlap_path));
}

test "KGHANG a kernel-half core is a kernel image and a low mapping still rejects pid 0" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const openNote = struct {
        fn open(alloc: std.mem.Allocator, dir: anytype, name: [:0]const u8, loads: []const u64) !Core {
            var note: std.ArrayList(u8) = .empty;
            defer note.deinit(alloc);
            const zero = prstatus(0);
            try pushNote(&note, alloc, "CORE\x00", 1, &zero);
            const phnum: u16 = @intCast(loads.len + 1);
            const note_off: u64 = 64 + @as(u64, phnum) * 56;
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(alloc);
            const header = elfHeader(64, phnum, 0, 0, 0);
            try bytes.appendSlice(alloc, &header);
            try pushPhdr(&bytes, alloc, 4, 0, note_off, 0, 0, note.items.len, note.items.len);
            const data_off = note_off + note.items.len;
            for (loads) |vaddr| try pushPhdr(&bytes, alloc, 1, 5, data_off, vaddr, 0, 1, 1);
            try bytes.appendSlice(alloc, note.items);
            try bytes.append(alloc, 0x3c);
            const out = try dir.createFile(std.testing.io, name, .{ .read = true });
            defer out.close(std.testing.io);
            try out.writeStreamingAll(std.testing.io, bytes.items);
            const path = try dir.realPathFileAlloc(std.testing.io, name, alloc);
            defer alloc.free(path);
            return Core.open(alloc, path);
        }
    };
    var core = try openNote.open(a, tmp.dir, "kernel-half", &.{0xffff888000001000});
    defer core.deinit();
    try std.testing.expect(core.kernel);
    try std.testing.expectEqual(@as(u8, 0), core.page_levels);
    try std.testing.expectEqual(@as(i32, 0x60000002), core.threads.items[0].tid);
    try std.testing.expectEqual(@as(i32, 1), core.pid);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try core.read(0xffff888000001000, &byte));
    try std.testing.expectEqual(@as(u8, 0x3c), byte[0]);
    try std.testing.expectError(error.InvalidCoreRegisters, openNote.open(a, tmp.dir, "user-zero", &.{0x400000}));
    try std.testing.expectError(error.InvalidCoreRegisters, openNote.open(a, tmp.dir, "mixed-zero", &.{ 0x400000, 0xffff888000001000 }));
}
