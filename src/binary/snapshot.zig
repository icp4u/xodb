//! Owned read-only ELF bytes; never retain a mapping of a mutable file.
const std = @import("std");
const c = @import("../c.zig").api;
const mib = 1024 * 1024;
/// Full-image budgets. Set once at startup, before any image is read. The
/// total is one figure for the whole process: every session, capture, debug
/// file and inflated debug section reserves from it before reading. Larger
/// values are the user's to choose (--image-limit, --image-total-limit).
pub const min_limit: u64 = mib;
pub const max_limit: u64 = if (@sizeOf(usize) >= 8) 1 << 40 else 1 << 31;
pub var per_image_limit: usize = 256 * mib;
pub var total_limit: usize = 512 * mib;
/// Whole-file transfers from a runtime agent keep the agent's fixed cap.
pub const remote_image_limit: usize = 256 * mib;
/// Null keeps the default. Values are bytes.
pub fn configure(per_image: ?u64, total: ?u64) error{InvalidImageBudget}!void {
    for ([_]?u64{ per_image, total }) |value| if (value) |n| {
        if (n < min_limit or n > max_limit) return error.InvalidImageBudget;
    };
    if (per_image) |n| per_image_limit = @intCast(n);
    if (total) |n| total_limit = @intCast(n);
}
/// Bytes, or a whole number of K, M or G (binary units): "268435456", "256M", "2G".
pub fn parseSize(text: []const u8) error{InvalidImageBudget}!u64 {
    if (text.len == 0) return error.InvalidImageBudget;
    const shift: u6 = switch (text[text.len - 1]) {
        'K', 'k' => 10,
        'M', 'm' => 20,
        'G', 'g' => 30,
        else => 0,
    };
    const digits = text[0 .. text.len - @intFromBool(shift != 0)];
    if (digits.len == 0) return error.InvalidImageBudget;
    for (digits) |d| if (!std.ascii.isDigit(d)) return error.InvalidImageBudget;
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidImageBudget;
    return std.math.shlExact(u64, n, shift) catch error.InvalidImageBudget;
}
/// What a refused image needed and what it was allowed.
pub const Refusal = struct {
    size: u64,
    limit: u64,
    which: enum { image, total, remote, lookup, runtime, sweep },
    /// What the total had left when the image was refused.
    left: u64 = 0,
    /// runtime: whether a stack frame in the image loads it (it has debug
    /// info), when that is known.
    stack_loads: ?bool = null,
    /// A per-image value that admits `size` with a little room: 5% over, as
    /// a whole number of hundreds of MiB, within the accepted range.
    fn imageOption(size: u64) u64 {
        const need = (size + mib - 1) / mib;
        return @min((need + need / 20 + 99) / 100 * 100, max_limit / mib);
    }
    /// A total, in GiB, that admits `size` beside what is held, and twice
    /// `size` at least so that searches keep their share; within the range.
    fn totalOption(self: Refusal) u64 {
        const gib = 1024 * mib;
        const want = @max(self.size *| 2, (total_limit -| self.left) +| self.size);
        return @min(want / gib + @intFromBool(want % gib != 0), max_limit / gib);
    }
    /// A total, in GiB, whose share for sweeps admits `size` beside what
    /// sweeps hold, and that is more than the present one.
    fn sweepOption(self: Refusal) u64 {
        const gib = 1024 * mib;
        const pool = (sweepLimit() -| self.limit) +| self.size;
        const want = @max(@max(pool *| 2, pool +| per_image_limit), total_limit +| 1);
        return @min(want / gib + @intFromBool(want % gib != 0), max_limit / gib);
    }
    /// "PATH is 1004 MiB; image budget 256 MiB; rerun with --image-limit 1100M
    /// --image-total-limit 2G or set symbols.image_bytes and symbols.image_total_bytes"
    pub fn write(self: Refusal, buffer: []u8, path: []const u8) []const u8 {
        var name: [path_text]u8 = undefined;
        const shown = printable(&name, path, path_text);
        const need = (self.size + mib - 1) / mib;
        return switch (self.which) {
            .image => if (self.size > max_limit)
                std.fmt.bufPrint(buffer, "{s} is {d} MiB; image budget {d} MiB; no accepted --image-limit is that large", .{ shown, need, self.limit / mib })
            else if (self.size > self.left)
                std.fmt.bufPrint(buffer, "{s} is {d} MiB; image budget {d} MiB; rerun with --image-limit {d}M --image-total-limit {d}G or set symbols.image_bytes and symbols.image_total_bytes", .{ shown, need, self.limit / mib, imageOption(self.size), self.totalOption() })
            else
                std.fmt.bufPrint(buffer, "{s} is {d} MiB; image budget {d} MiB; rerun with --image-limit {d}M or set symbols.image_bytes", .{ shown, need, self.limit / mib, imageOption(self.size) }),
            .total => std.fmt.bufPrint(buffer, "{s} is {d} MiB; {d} MiB left of the {d} MiB total image budget; rerun with --image-total-limit {d}G or set symbols.image_total_bytes", .{ shown, need, self.limit / mib, total_limit / mib, self.totalOption() }),
            .remote => std.fmt.bufPrint(buffer, "{s}: remote image transfer is capped at {d} MiB", .{ shown, self.limit / mib }),
            .lookup => std.fmt.bufPrint(buffer, "{s} is {d} MiB and has no symbols-only view; a name lookup may read {d} MiB of it (such images: 256 MiB each, 512 MiB per process)", .{ shown, need, self.limit / mib }),
            .runtime => std.fmt.bufPrint(buffer, "{s} is {d} MiB; a language view may read {d} MiB of the image it finds its runtime in, unless that is the main executable (256 MiB each, 512 MiB per process); {s}", .{ shown, need, self.limit / mib, if (self.stack_loads) |loads| (if (loads) "a stack frame in it loads it" else "it has no debug info, so a stack does not load it either") else "it is used once something else loads it" }),
            .sweep => if (self.size > sweep_image_limit)
                std.fmt.bufPrint(buffer, "{s} is {d} MiB; a search of every mapped image reads at most {d} MiB of an image that is not loaded (the main executable excepted); a stack frame in the image loads it", .{ shown, need, sweep_image_limit / mib })
            else
                std.fmt.bufPrint(buffer, "{s} is {d} MiB; {d} MiB left of the {d} MiB of the total image budget that searches of every mapped image may hold; rerun with --image-total-limit {d}G or set symbols.image_total_bytes; a stack frame in the image loads it", .{ shown, need, self.limit / mib, sweepLimit() / mib, self.sweepOption() }),
        } catch buffer[0..0];
    }
};
const path_text = 512;
pub const refusal_text = path_text + 288;
/// `text` as valid UTF-8 in at most `limit` bytes of `buffer`, for a
/// diagnostic line. A path is the target's to choose: control characters and
/// bytes that are not UTF-8 become '?', so the line cannot drive a terminal
/// and always encodes as a JSON string. A longer text is cut between
/// characters and ends in "...".
pub fn printable(buffer: []u8, text: []const u8, limit: usize) []const u8 {
    const room = @min(buffer.len, limit);
    const cut = text.len > room;
    const end = if (cut) room -| 3 else room;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        const whole = len != 0 and i + len <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..len]);
        const step: usize = if (whole) len else 1;
        // C0, DEL and C1 (U+0080..U+009F, encoded as C2 80..C2 9F).
        const control = text[i] < 0x20 or text[i] == 0x7f or (whole and len == 2 and text[i] == 0xc2 and text[i + 1] < 0xa0);
        const out: []const u8 = if (!whole or control) "?" else text[i..][0..len];
        if (n + out.len > end) break;
        @memcpy(buffer[n..][0..out.len], out);
        n += out.len;
        i += step;
    }
    if (cut and i < text.len) {
        const dots = @min(3, room - n);
        @memset(buffer[n..][0..dots], '.');
        n += dots;
    }
    return buffer[0..n];
}
// Bytes held by every reader in the process, and the most that ever was.
var reserved = std.atomic.Value(usize).init(0);
var peak = std.atomic.Value(usize).init(0);
pub fn used() usize {
    return reserved.load(.acquire);
}
pub fn peakUsed() usize {
    return peak.load(.acquire);
}
/// The most the next image may be. Advice only: `reserve` decides.
pub fn remaining() usize {
    return @min(per_image_limit, total_limit -| used());
}
pub fn refusal(size: u64) Refusal {
    const left = total_limit -| used();
    if (size > per_image_limit) return .{ .size = size, .limit = per_image_limit, .which = .image, .left = left };
    return .{ .size = size, .limit = left, .which = .total, .left = left };
}
/// Readers that search every mapped image (a source line, a capture's start)
/// act for one request and read files the target chose. Of images that are
/// not held yet and are not the main executable they read this much of one,
/// and all of them together hold at most `sweepLimit`: half the total, and
/// never the last per-image budget of it, which a stack frame may need.
pub const sweep_image_limit: usize = 256 * mib;
var swept = std.atomic.Value(usize).init(0);
pub fn sweepLimit() usize {
    return @min(total_limit / 2, total_limit -| per_image_limit);
}
pub fn sweepLeft() usize {
    return sweepLimit() -| swept.load(.acquire);
}
pub fn reserveSweep(bytes: u64) error{BinarySnapshotLimit}!usize {
    const n = std.math.cast(usize, bytes) orelse return error.BinarySnapshotLimit;
    var old = swept.load(.acquire);
    while (true) {
        if (n > sweep_image_limit or n > sweepLimit() -| old) return error.BinarySnapshotLimit;
        old = swept.cmpxchgWeak(old, old + n, .acq_rel, .acquire) orelse return n;
    }
}
pub fn releaseSweep(bytes: usize) void {
    _ = swept.fetchSub(bytes, .acq_rel);
}
/// Take `bytes` from the process-wide total before allocating them.
pub fn reserve(bytes: u64) error{BinarySnapshotLimit}!usize {
    const n = std.math.cast(usize, bytes) orelse return error.BinarySnapshotLimit;
    var old = reserved.load(.acquire);
    while (true) {
        if (n > per_image_limit or n > total_limit -| old) return error.BinarySnapshotLimit;
        old = reserved.cmpxchgWeak(old, old + n, .acq_rel, .acquire) orelse break;
    }
    _ = peak.fetchMax(old + n, .acq_rel);
    return n;
}
pub fn release(bytes: usize) void {
    _ = reserved.fetchSub(bytes, .acq_rel);
}
// Private copies and decompressed sections that a debug reader derives from
// a snapshot: the same total, their own error name.
pub fn reserveDerived(bytes: u64) error{CompressedDebugBudget}!usize {
    return reserve(bytes) catch error.CompressedDebugBudget;
}
pub const releaseDerived = release;
pub const Bytes = []align(std.heap.page_size_min) u8;
// One copy of each file version, however many readers hold it: a session and
// a capture of the same process, or every followed process that maps one
// library. The key is the identity the reader already checks around its read;
// the bytes are read-only once stored.
const Stamp = struct { device: u64, inode: u64, size: i64, mtime: [2]i64, ctime: [2]i64 };
const Shared = struct { stamp: Stamp, offset: u64, bytes: Bytes, holders: usize };
var store_lock: std.atomic.Mutex = .unlocked;
var store: std.ArrayList(Shared) = .empty;
fn lockStore() void {
    while (!store_lock.tryLock()) std.atomic.spinLoopHint();
}
fn stamp(stat: *const c.struct_stat) Stamp {
    return .{ .device = @intCast(stat.st_dev), .inode = @intCast(stat.st_ino), .size = @intCast(stat.st_size), .mtime = .{ @intCast(stat.st_mtim.tv_sec), @intCast(stat.st_mtim.tv_nsec) }, .ctime = .{ @intCast(stat.st_ctim.tv_sec), @intCast(stat.st_ctim.tv_nsec) } };
}
fn held(key: Stamp, offset: u64, size: usize) ?Bytes {
    for (store.items) |*item| if (item.offset == offset and item.bytes.len == size and std.meta.eql(item.stamp, key)) {
        item.holders += 1;
        return item.bytes;
    };
    return null;
}
/// Whether some reader holds this version of the range: reading it is free.
pub fn holds(fd: c_int, file_offset: u64, size: usize) bool {
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return false;
    const key = stamp(&stat);
    lockStore();
    defer store_lock.unlock();
    for (store.items) |item| if (item.offset == file_offset and item.bytes.len == size and std.meta.eql(item.stamp, key)) return true;
    return false;
}
/// Every `read` and `readRange` result is given back here, once per holder.
pub fn free(bytes: Bytes) void {
    lockStore();
    const last = for (store.items, 0..) |*item, i| {
        if (item.bytes.ptr != bytes.ptr) continue;
        item.holders -= 1;
        if (item.holders != 0) return store_lock.unlock();
        _ = store.swapRemove(i);
        break true;
    } else false;
    store_lock.unlock();
    _ = c.munmap(bytes.ptr, bytes.len);
    if (last) release(bytes.len);
}
pub fn read(fd: c_int, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Bytes {
    var before: c.struct_stat = undefined;
    if (c.fstat(fd, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG or before.st_size <= 0) return error.BinaryUnavailable;
    return readRange(fd, 0, std.math.cast(usize, before.st_size) orelse return error.BinarySnapshotLimit, limit, cancel);
}
/// Snapshot exactly one ELF entry, so a large APK is not retained per library.
/// `limit` is the caller's own bound on one image; the process-wide total is
/// applied here. A version of the file some reader already holds is shared
/// and costs nothing more.
pub fn readRange(fd: c_int, file_offset: u64, size: usize, limit: usize, cancel: ?*const std.atomic.Value(bool)) !Bytes {
    var before: c.struct_stat = undefined;
    if (c.fstat(fd, &before) != 0 or before.st_mode & c.S_IFMT != c.S_IFREG or before.st_size <= 0 or size == 0) return error.BinaryUnavailable;
    if (size > limit) return error.BinarySnapshotLimit;
    const end = std.math.add(u64, file_offset, size) catch return error.BinaryUnavailable;
    if (end > @as(u64, @intCast(before.st_size))) return error.BinaryUnavailable;
    const key = stamp(&before);
    lockStore();
    const shared = held(key, file_offset, size);
    store_lock.unlock();
    if (shared) |bytes| return bytes;
    const charged = try reserve(size);
    var owned = false;
    defer if (!owned) release(charged);
    const ptr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
    if (ptr == std.c.MAP_FAILED) return error.OutOfMemory;
    const bytes: Bytes = @as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(ptr.?)))[0..size];
    defer if (!owned) {
        _ = c.munmap(bytes.ptr, bytes.len);
    };
    var offset: usize = 0;
    while (offset < size) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.ArchiveCancelled;
        const n = c.pread(fd, bytes.ptr + offset, @min(1024 * 1024, size - offset), @intCast(file_offset + offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.BinaryChangedDuringRead;
        offset += @intCast(n);
    }
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or !std.meta.eql(key, stamp(&after))) return error.BinaryChangedDuringRead;
    if (c.mprotect(bytes.ptr, size, c.PROT_READ) != 0) return error.BinaryUnavailable;
    lockStore();
    defer store_lock.unlock();
    // Another thread may have read the same version meanwhile: keep theirs.
    if (held(key, file_offset, size)) |first| return first;
    try store.append(std.heap.page_allocator, .{ .stamp = key, .offset = file_offset, .bytes = bytes, .holders = 1 });
    owned = true;
    return bytes;
}
pub fn bootId() ?[36]u8 {
    return bootIdTarget(null);
}
pub fn bootIdTarget(target: ?*const @import("../target/runtime.zig").c.struct_xrt_target) ?[36]u8 {
    const rt = @import("../target/runtime.zig").c;
    const request = std.mem.zeroInit(rt.struct_xrt_file_request, .{ .kind = rt.XRT_FILE_BOOT_ID });
    var fd: c_int = -1;
    const status = if (target) |t| rt.xrt_target_file(t, &request, &fd) else rt.xrt_process_file(0, &request, &fd);
    if (status != rt.XRT_OK) return null;
    defer _ = c.close(fd);
    var value: [36]u8 = undefined;
    if (c.read(fd, &value, value.len) != value.len) return null;
    for (value) |b| if (!std.ascii.isHex(b) and b != '-') return null;
    return value;
}

test "image budgets parse sizes, refuse nonsense and say what to raise" {
    const gib = 1024 * mib;
    // The defaults: larger budgets are the user's choice.
    try std.testing.expectEqual(@as(usize, 256 * mib), per_image_limit);
    try std.testing.expectEqual(@as(usize, 512 * mib), total_limit);
    try std.testing.expectEqual(@as(usize, 256 * mib), sweepLimit());
    try std.testing.expectEqual(@as(u64, 268435456), try parseSize("268435456"));
    try std.testing.expectEqual(@as(u64, 256 * mib), try parseSize("256M"));
    try std.testing.expectEqual(@as(u64, 2 * gib), try parseSize("2g"));
    try std.testing.expectEqual(@as(u64, 4096), try parseSize("4k"));
    for ([_][]const u8{ "", "M", "-1", "+1", "1.5G", "2GB", "0x10", " 1", "1 ", "99999999999999999999", "17179869184G" }) |bad|
        try std.testing.expectError(error.InvalidImageBudget, parseSize(bad));
    const saved = .{ per_image_limit, total_limit };
    defer per_image_limit = saved[0];
    defer total_limit = saved[1];
    var text: [refusal_text]u8 = undefined;
    const start = used();
    // The sentence names the option and a value that admits the image; the
    // suggestion parses, and is within the accepted range.
    try std.testing.expectEqualStrings("/opt/game/engine is 1004 MiB; image budget 256 MiB; rerun with --image-limit 1100M --image-total-limit 2G or set symbols.image_bytes and symbols.image_total_bytes", refusal(1052237576).write(&text, "/opt/game/engine"));
    try std.testing.expectEqualStrings("/lib/c.so is 300 MiB; image budget 256 MiB; rerun with --image-limit 400M or set symbols.image_bytes", refusal(300 * mib).write(&text, "/lib/c.so"));
    try std.testing.expect(1100 * mib >= 1052237576 + 1052237576 / 20 and try parseSize("1100M") <= max_limit);
    try std.testing.expectEqual(max_limit / mib, Refusal.imageOption(max_limit));
    try std.testing.expectEqual(max_limit / gib, (Refusal{ .size = max_limit, .limit = 0, .which = .total }).totalOption());
    try std.testing.expect(std.mem.endsWith(u8, refusal(max_limit + 1).write(&text, "/x"), "no accepted --image-limit is that large"));
    for ([_]u64{ 0, 1, min_limit - 1, max_limit + 1, std.math.maxInt(u64) }) |bad| {
        try std.testing.expectError(error.InvalidImageBudget, configure(bad, null));
        try std.testing.expectError(error.InvalidImageBudget, configure(null, bad));
    }
    try std.testing.expectEqual(saved[0], per_image_limit); // a refused value changes nothing
    try configure(2 * gib, null); // one value leaves the other alone
    try std.testing.expectEqual(saved[1], total_limit);
    try std.testing.expectEqual(@as(usize, 0), sweepLimit()); // nothing is left over a frame's image
    try configure(2 * gib, 8 * gib);
    try std.testing.expectEqual(@as(usize, 4 * gib), sweepLimit());
    try configure(1100 * mib, 2 * gib);
    try std.testing.expectEqual(@as(usize, 948 * mib), sweepLimit());
    try configure(64 * mib, 96 * mib);
    try std.testing.expectEqual(@as(usize, 64 * mib), remaining());
    try std.testing.expectEqual(@as(usize, 32 * mib), sweepLimit());
    try std.testing.expectEqualStrings("/lib/big.so is 301 MiB; image budget 64 MiB; rerun with --image-limit 400M --image-total-limit 1G or set symbols.image_bytes and symbols.image_total_bytes", refusal(300 * mib + 1).write(&text, "/lib/big.so"));
    const first = try reserve(60 * mib);
    try std.testing.expectEqual(@as(usize, 36 * mib), remaining());
    try std.testing.expectEqualStrings("/lib/b.so is 40 MiB; 36 MiB left of the 96 MiB total image budget; rerun with --image-total-limit 1G or set symbols.image_total_bytes", refusal(40 * mib).write(&text, "/lib/b.so"));
    try std.testing.expectError(error.BinarySnapshotLimit, reserve(65 * mib)); // over the per-image value
    try std.testing.expectError(error.BinarySnapshotLimit, reserve(40 * mib)); // over what the total has left
    // Debug sections draw on the same total as images.
    try std.testing.expectError(error.CompressedDebugBudget, reserveDerived(40 * mib));
    const second = try reserveDerived(36 * mib);
    try std.testing.expectEqual(@as(usize, 0), remaining());
    try std.testing.expect(peakUsed() >= start + 96 * mib);
    releaseDerived(second);
    release(first);
    try std.testing.expectEqual(start, used());
    // Searches of every image share their own part of the total.
    const swept_before = sweepLeft();
    try std.testing.expectError(error.BinarySnapshotLimit, reserveSweep(33 * mib));
    const a = try reserveSweep(20 * mib);
    try std.testing.expectError(error.BinarySnapshotLimit, reserveSweep(13 * mib));
    const b = try reserveSweep(12 * mib);
    try std.testing.expectEqual(swept_before - 32 * mib, sweepLeft());
    releaseSweep(a);
    releaseSweep(b);
    try std.testing.expectEqual(swept_before, sweepLeft());
    try std.testing.expectEqualStrings("/lib/s.so is 300 MiB; a search of every mapped image reads at most 256 MiB of an image that is not loaded (the main executable excepted); a stack frame in the image loads it", (Refusal{ .size = 300 * mib, .limit = 32 * mib, .which = .sweep }).write(&text, "/lib/s.so"));
    // 20 of the 32 MiB are held and 30 more are wanted: 50 MiB for sweeps is a total of 114 MiB (64 are a frame's).
    try std.testing.expectEqualStrings("/lib/t.so is 30 MiB; 12 MiB left of the 32 MiB of the total image budget that searches of every mapped image may hold; rerun with --image-total-limit 1G or set symbols.image_total_bytes; a stack frame in the image loads it", (Refusal{ .size = 30 * mib, .limit = 12 * mib, .which = .sweep }).write(&text, "/lib/t.so"));
    try configure(256 * mib, 512 * mib);
    try std.testing.expectEqual(@as(u64, 1), (Refusal{ .size = 256 * mib, .limit = 0, .which = .sweep }).sweepOption()); // 512 MiB for sweeps is a total of 1 GiB
    try std.testing.expectEqual(@as(u64, 1), (Refusal{ .size = mib, .limit = 0, .which = .sweep }).sweepOption());
}

test "a file version is read once and shared by every holder" {
    const saved = .{ per_image_limit, total_limit };
    defer per_image_limit = saved[0];
    defer total_limit = saved[1];
    try configure(mib, 3 * mib / 2);
    const fd = c.memfd_create("xodb-snapshot-test", c.MFD_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, mib));
    const start = used();
    const a = try read(fd, per_image_limit, null);
    const b = try read(fd, per_image_limit, null); // would not fit twice
    try std.testing.expectEqual(a.ptr, b.ptr);
    try std.testing.expectEqual(start + mib, used());
    // The caller's own bound still applies to a shared image.
    try std.testing.expectError(error.BinarySnapshotLimit, read(fd, mib - 1, null));
    free(a);
    try std.testing.expectEqual(start + mib, used());
    // A changed file is another version: it is read again, and charged.
    try std.testing.expectEqual(@as(isize, 1), c.pwrite(fd, "x", 1, 0));
    const times = [2]c.struct_timespec{ .{ .tv_sec = 1, .tv_nsec = 0 }, .{ .tv_sec = 1, .tv_nsec = 0 } };
    try std.testing.expectEqual(@as(c_int, 0), c.futimens(fd, &times));
    try std.testing.expectError(error.BinarySnapshotLimit, read(fd, per_image_limit, null));
    free(b);
    try std.testing.expectEqual(start, used());
    const d = try read(fd, per_image_limit, null);
    try std.testing.expectEqual(@as(u8, 'x'), d[0]);
    free(d);
    try std.testing.expectEqual(start, used());
}

test "diagnostic paths are cut between characters and carry no control bytes" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/lib/a.so", printable(&buffer, "/lib/a.so", 64));
    try std.testing.expectEqualStrings("/tmp/?[31mred?.so", printable(&buffer, "/tmp/\x1b[31mred\n.so", 64));
    try std.testing.expectEqualStrings("a?b?c", printable(&buffer, "a\xffb\xc2\x9bc", 64)); // not UTF-8; C1 CSI
    // "é" would straddle the cut: it is dropped whole.
    try std.testing.expectEqualStrings("abcd...", printable(&buffer, "abcd\xc3\xa9fghij", 8));
    try std.testing.expectEqualStrings("abc\xc3\xa9...", printable(&buffer, "abc\xc3\xa9fghij", 8));
    try std.testing.expectEqualStrings("abcdefgh", printable(&buffer, "abcdefgh", 8));
    var long: [600]u8 = @splat('p');
    @memcpy(long[507..510], "\xe2\x82\xac"); // a euro sign across byte 509
    var text: [refusal_text]u8 = undefined;
    const line = refusal(300 * mib).write(&text, &long);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(std.mem.indexOf(u8, line, "... is 300 MiB; ") != null);
}
