//! Fast synthetic PE/profile boundary checks, run by the build-tests gate.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("capture.zig");
const fixture = @import("archive_fixture.zig");
const records = @import("records.zig");
const assets = @import("pe_assets.zig");
const archive = @import("archive.zig");
const unwind = @import("unwind.zig");
const a = std.testing.allocator;
const bias: u64 = 0x180000000;
fn snapshotAllocations(allocator: std.mem.Allocator, capture: *const model.Capture) !void {
    const copy = try @import("recorded_view.zig").snapshot(allocator, capture);
    copy.deinit();
}
fn put(bytes: []u8, at: usize, comptime T: type, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
fn sectionEntry(bytes: []u8, tag: archive.Tag) []u8 {
    const count = std.mem.readInt(u32, bytes[24..28], .little);
    for (0..count) |i| {
        const entry = bytes[archive.header_bytes + i * archive.entry_bytes ..][0..archive.entry_bytes];
        if (std.mem.readInt(u32, entry[0..4], .little) == @intFromEnum(tag)) return entry;
    }
    unreachable;
}
fn sectionBytes(bytes: []u8, tag: archive.Tag) []u8 {
    const entry = sectionEntry(bytes, tag);
    const at = std.mem.readInt(u64, entry[8..16], .little);
    const size = std.mem.readInt(u32, entry[16..20], .little);
    return bytes[at..][0..size];
}
fn sectionChecksum(bytes: []u8, tag: archive.Tag) void {
    put(sectionEntry(bytes, tag), 20, u32, std.hash.Crc32.hash(sectionBytes(bytes, tag)));
}
fn binary(version: u8) [0x600]u8 {
    var b: [0x600]u8 = @splat(0);
    @memcpy(b[0..2], "MZ");
    put(&b, 60, u32, 64);
    @memcpy(b[64..68], "PE\x00\x00");
    put(&b, 68, u16, 0x8664);
    put(&b, 70, u16, 1);
    put(&b, 84, u16, 240);
    const opt = 88;
    put(&b, opt, u16, 0x20b);
    put(&b, opt + 24, u64, bias);
    put(&b, opt + 32, u32, 0x1000);
    put(&b, opt + 36, u32, 0x200);
    put(&b, opt + 56, u32, 0x2000);
    put(&b, opt + 60, u32, 0x200);
    put(&b, opt + 108, u32, 16);
    put(&b, opt + 136, u32, 0x1200);
    put(&b, opt + 140, u32, 24);
    @memcpy(b[328..333], ".text");
    put(&b, 336, u32, 0x400);
    put(&b, 340, u32, 0x1000);
    put(&b, 344, u32, 0x400);
    put(&b, 348, u32, 0x200);
    put(&b, 364, u32, 0x60000020);
    @memset(b[0x200..0x300], 0x90);
    put(&b, 0x400, u32, 0x1000);
    put(&b, 0x404, u32, 0x1010);
    put(&b, 0x408, u32, 0x1240);
    put(&b, 0x40c, u32, 0x1020);
    put(&b, 0x410, u32, 0x1030);
    put(&b, 0x414, u32, 0x1248);
    @memcpy(b[0x440..0x446], &[_]u8{ version, 4, 1, 0, 4, 0x32 }); // ALLOC_SMALL 32
    b[0x448] = 1;
    return b;
}
const File = struct {
    path: [64]u8 = @splat(0),
    fd: c_int,
    fn create(bytes: []const u8) !File {
        _ = c.mkdir(".work", 0o755);
        var self = File{ .fd = -1 };
        const template = ".work/pe-profile-XXXXXX";
        @memcpy(self.path[0..template.len], template);
        self.fd = c.mkstemp(&self.path);
        if (self.fd < 0) return error.FixtureFile;
        errdefer self.deinit();
        if (c.write(self.fd, bytes.ptr, bytes.len) != bytes.len) return error.FixtureWrite;
        return self;
    }
    fn deinit(self: *File) void {
        _ = c.close(self.fd);
        _ = c.unlink(&self.path);
    }
    fn name(self: *const File) []const u8 {
        return std.mem.sliceTo(&self.path, 0);
    }
};
fn build(file: *const File) !*model.Capture {
    const capture = try fixture.build(a, .empty, null);
    errdefer capture.deinit();
    const bytes = try @import("../binary/snapshot.zig").read(file.fd, 4096, null);
    const asset = assets.Asset.fromBytes(a, 1, file.name(), .{ .bias = bias, .start = bias, .end = bias + 0x2000, .device_major = 0, .device_minor = 0, .inode = 1 }, bytes) catch |err| {
        _ = c.munmap(bytes.ptr, bytes.len);
        return err;
    };
    capture.pe_assets.append(a, asset) catch |err| {
        asset.deinit(a);
        return err;
    };
    capture.images.snapshot_bytes = bytes.len;
    try capture.history.opening(a, .{ .start = bias + 0x1000, .end = bias + 0x1400, .image_id = 1, .reason = .pe });
    capture.config.user_stack_bytes = 4096;
    capture.config.user_stack_budget_bytes = 128;
    capture.accepted.user_stack_bytes = 4096;
    capture.accepted.user_regs_mask = records.user_regs_gpr_mask;
    capture.accepted.sample_type |= records.Bits.regs_user | records.Bits.stack_user;
    capture.user_state = try model.sample_state.Store.init(a, 1, 128);
    var raw = records.UserState{ .abi = records.regs_abi_64, .regs_mask = records.user_regs_gpr_mask, .regs_present = true, .stack_size = 4096, .stack_dyn = 48, .stack_len = 48, .stack_present = true, .stack_short = true };
    raw.regs[7] = 0x7000;
    raw.regs[8] = bias + 0x1008;
    var stack: [48]u8 = @splat(0);
    put(&stack, 32, u64, bias + 0x1024);
    const index = try capture.user_state.append(raw, &stack);
    try capture.samples.append(a, .{ .ip = raw.regs[8], .ip_present = true, .cpu_mode = .user, .tid_present = true, .pid = 4100, .tid = 4100, .time_present = true, .time_ns = fixture.base_ns + 1, .user_state = index });
    return capture;
}
test "PE saved stack walks immutable bytes and worker snapshots borrow pinned assets" {
    var file = try File.create(&binary(1));
    defer file.deinit();
    const capture = try build(&file);
    defer capture.deinit();
    const expected = try unwind.walk(a, capture, 0, null);
    try std.testing.expectEqual(unwind.Reason.complete, expected.reason);
    try std.testing.expectEqual(@as(usize, 2), expected.count);
    try std.testing.expectEqual(bias + 0x1024, expected.frames[1].pc);
    try std.testing.expectEqualStrings("windows_unwind", expected.frames[0].method.?);
    try std.testing.expect(std.mem.endsWith(u8, expected.frames[0].name[0..expected.frames[0].name_len], "!sub_1000"));
    const copy = try @import("recorded_view.zig").snapshot(a, capture);
    try std.testing.expect(copy.pe_assets.byId(1) == capture.pe_assets.byId(1));
    copy.deinit();
    try std.testing.checkAllAllocationFailures(a, snapshotAllocations, .{capture});
    // The source file ceases to contain a PE, but neither worker nor analysis reads it.
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(file.fd, 0));
    try std.testing.expectEqualSlices(u8, &expected.analysis_id, &(try unwind.walk(a, capture, 0, null)).analysis_id);
    capture.user_state.entries[0].state.stack_len = 40;
    const short = try unwind.walk(a, capture, 0, null);
    try std.testing.expectEqual(unwind.Reason.stack_window, short.reason);
    try std.testing.expectEqual(@as(usize, 2), short.count);
    capture.user_state.entries[0].state.stack_len = 48;
    capture.history.entries.items[0].end = bias + 0x1024;
    try std.testing.expectEqual(unwind.Reason.mapping_missing, (try unwind.walk(a, capture, 0, null)).reason);
    capture.history.entries.items[0].end = bias + 0x1400;
    capture.trusted_before_ns = fixture.base_ns + 1;
    try std.testing.expectEqual(unwind.Reason.mappings_untrusted, (try unwind.walk(a, capture, 0, null)).reason);
}
test "PE archive feature, verified assets, unavailable assets and identity mismatch" {
    var file = try File.create(&binary(1));
    defer file.deinit();
    const capture = try build(&file);
    defer capture.deinit();
    const expected = try unwind.walk(a, capture, 0, null);
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[10..12], .little));
    try std.testing.expect(std.mem.readInt(u64, bytes[40..48], .little) & 64 != 0);
    var missing = try archive.decode(a, bytes, .{ .local_id = 8 });
    defer missing.deinit();
    try std.testing.expectEqual(unwind.Reason.asset_missing, (try unwind.walk(a, missing.capture, 0, null)).reason);
    var resolved = try archive.decode(a, bytes, .{ .local_id = 9, .resolver = .{ .enabled = true } });
    defer resolved.deinit();
    try std.testing.expectEqual(archive.ImageKind.pe, resolved.source.images[0].kind);
    try std.testing.expectEqual(archive.ImageStatus.verified, resolved.source.images[0].status);
    try std.testing.expectEqualSlices(u8, &expected.analysis_id, &(try unwind.walk(a, resolved.capture, 0, null)).analysis_id);
    const changed = [_]u8{0};
    try std.testing.expectEqual(@as(isize, 1), c.pwrite(file.fd, &changed, 1, 0));
    var mismatch = try archive.decode(a, bytes, .{ .local_id = 10, .resolver = .{ .enabled = true } });
    defer mismatch.deinit();
    try std.testing.expectEqual(archive.ImageStatus.content_mismatch, mismatch.source.images[0].status);
    try std.testing.expectEqual(unwind.Reason.asset_missing, (try unwind.walk(a, mismatch.capture, 0, null)).reason);
    try std.testing.expectEqualSlices(u8, &expected.analysis_id, &(try unwind.walk(a, resolved.capture, 0, null)).analysis_id);
    const images = sectionBytes(bytes, .images);
    images[12] = 2;
    sectionChecksum(bytes, .images);
    try std.testing.expectError(error.ArchiveInvalidValue, archive.decode(a, bytes, .{ .local_id = 11 }));
    images[12] = 0; // Cannot reinterpret PE MAPS references as ELF.
    sectionChecksum(bytes, .images);
    try std.testing.expectError(error.ArchiveInconsistent, archive.decode(a, bytes, .{ .local_id = 11 }));
    images[12] = 1;
    sectionChecksum(bytes, .images);
    put(bytes, 10, u16, 7);
    put(bytes, 56, u32, std.hash.Crc32.hash(bytes[0..56]));
    try std.testing.expectError(error.ArchiveHeaderInvalid, archive.decode(a, bytes, .{ .local_id = 11 }));
}
test "PE unsupported metadata gives a partial stack with no speculative caller" {
    var file = try File.create(&binary(2));
    defer file.deinit();
    const capture = try build(&file);
    defer capture.deinit();
    const result = try unwind.walk(a, capture, 0, null);
    try std.testing.expectEqual(unwind.Reason.unsupported_windows_unwind, result.reason);
    try std.testing.expectEqual(@as(usize, 1), result.count);
}
