const std = @import("std");
const model = @import("capture.zig");
const records = @import("records.zig");
const fixture = @import("archive_fixture.zig");
const archive = @import("archive.zig");
const unwind = @import("unwind.zig");
const a = std.testing.allocator;
fn enable(capture: *model.Capture, capacity: usize, budget: u32) !void {
    capture.config.user_stack_bytes = 4096;
    capture.config.user_stack_budget_bytes = budget;
    capture.accepted.user_stack_bytes = 4096;
    capture.accepted.user_regs_mask = records.user_regs_gpr_mask;
    capture.accepted.sample_type |= records.Bits.regs_user | records.Bits.stack_user;
    capture.user_state = try model.sample_state.Store.init(a, capacity, budget);
}
fn state(pc: u64, len: u32) records.UserState {
    var raw = records.UserState{ .abi = records.regs_abi_64, .regs_mask = records.user_regs_gpr_mask, .regs_present = true, .stack_size = 4096, .stack_dyn = len, .stack_len = len, .stack_present = true, .stack_short = len < 4096 };
    raw.regs[7] = 0x7000;
    raw.regs[8] = pc;
    return raw;
}
fn build() !*model.Capture {
    const capture = try fixture.build(a, .empty, null);
    errdefer capture.deinit();
    const image = try fixture.addElf(capture, "tests/fixtures/elf/out/unwind-cfi.so", 0, 0);
    const leaf = image.image.findSymbol("saved_leaf").?.value + image.bias;
    const parent = image.image.findSymbol("saved_parent").?.value + image.bias;
    image.start = leaf;
    image.end = parent + 2;
    try capture.history.opening(a, .{ .start = leaf, .end = parent + 2, .image_id = image.id, .reason = .elf });
    try enable(capture, 2, 32);
    var bytes: [16]u8 = @splat(0);
    std.mem.writeInt(u64, bytes[0..8], parent + 2, .little); // return PC lies exactly outside mapping
    const index = try capture.user_state.append(state(leaf, 16), &bytes);
    try capture.samples.append(a, .{ .ip = leaf, .ip_present = true, .cpu_mode = .user, .tid_present = true, .pid = 4100, .tid = 4100, .time_present = true, .time_ns = fixture.base_ns + 1, .user_state = index });
    return capture;
}
test "saved DWARF callers select the adjusted return PC and mapping history" {
    const capture = try build();
    defer capture.deinit();
    const original = capture.samples.get(0);
    const result = try unwind.walk(a, capture, 0, null);
    try std.testing.expectEqual(unwind.Reason.complete, result.reason);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("saved_parent", result.frames[1].name[0..result.frames[1].name_len]);
    try std.testing.expectEqual(result.frames[1].pc - 1, result.frames[1].lookup_pc);
    try std.testing.expectEqualDeep(original, capture.samples.get(0));
    const mapping = capture.history.entries.items[0];
    _ = try capture.history.add(a, fixture.base_ns + 2, .{ .start = mapping.start, .end = mapping.end, .reason = .anonymous });
    try std.testing.expectEqualSlices(u8, &result.analysis_id, &(try unwind.walk(a, capture, 0, null)).analysis_id);
    capture.samples.coreMut(0).time_ns += 1;
    try std.testing.expectEqual(unwind.Reason.mapping_ambiguous, (try unwind.walk(a, capture, 0, null)).reason);
    capture.samples.coreMut(0).time_ns += 1;
    try std.testing.expectEqual(unwind.Reason.asset_missing, (try unwind.walk(a, capture, 0, null)).reason);
    capture.trusted_before_ns = capture.samples.get(0).time_ns;
    try std.testing.expectEqual(unwind.Reason.mappings_untrusted, (try unwind.walk(a, capture, 0, null)).reason);
}
test "saved unwind labels absent budget ABI short CFI signal and cycle boundaries" {
    const capture = try build();
    defer capture.deinit();
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.ArchiveCancelled, unwind.walk(a, capture, 0, &cancel));
    var entry = &capture.user_state.entries[0];
    const original = entry.*;
    entry.status = .budget;
    try std.testing.expectEqual(unwind.Reason.retention_budget, (try unwind.walk(a, capture, 0, null)).reason);
    entry.* = original;
    entry.state.stack_len = 0;
    try std.testing.expectEqual(unwind.Reason.stack_absent, (try unwind.walk(a, capture, 0, null)).reason);
    entry.state.stack_len = 8;
    const short = try unwind.walk(a, capture, 0, null);
    try std.testing.expectEqual(unwind.Reason.stack_window, short.reason);
    try std.testing.expectEqual(@as(usize, 2), short.count);
    entry.* = original;
    entry.state.abi = records.regs_abi_32;
    try std.testing.expectEqual(unwind.Reason.unsupported_abi, (try unwind.walk(a, capture, 0, null)).reason);
    entry.state.regs_present = false;
    try std.testing.expectEqual(unwind.Reason.registers_absent, (try unwind.walk(a, capture, 0, null)).reason);
    entry.* = original;
    const image = capture.images.loaded.items[0];
    capture.history.entries.items[0].end += 4096;
    for ([_]struct { name: []const u8, reason: unwind.Reason }{ .{ .name = "saved_signal", .reason = .signal_frame }, .{ .name = "saved_cycle", .reason = .cycle }, .{ .name = "saved_nocfi", .reason = .cfi_missing } }) |case| {
        const pc = image.image.findSymbol(case.name).?.value + image.bias;
        entry.state.regs[8] = pc;
        capture.samples.coreMut(0).ip = pc;
        try std.testing.expectEqual(case.reason, (try unwind.walk(a, capture, 0, null)).reason);
    }
}
test "sampled archive retains raw evidence and budget gaps with matching asset reanalysis" {
    const capture = try build();
    defer capture.deinit();
    // A retained 16-byte stack leaves 16 bytes; this dump cannot fit.
    const missing = try capture.user_state.append(state(capture.samples.get(0).ip, 32), &(@as([32]u8, @splat(9))));
    var sample = capture.samples.get(0);
    sample.user_state = missing;
    sample.time_ns += 1;
    try capture.samples.append(a, sample);
    const expected = try unwind.walk(a, capture, 0, null);
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    try std.testing.expectEqual(@as(u64, 13), std.mem.readInt(u64, bytes[40..48], .little));
    var opened = try archive.decode(a, bytes, .{ .local_id = 8 });
    defer opened.deinit();
    try std.testing.expectEqualStrings("perf_user_state_v1", opened.source.stack_registers);
    try std.testing.expectEqual(@as(usize, 1), opened.capture.user_state.skipped);
    try std.testing.expectEqual(@as(usize, 16), opened.capture.user_state.used);
    try std.testing.expectEqualDeep(capture.user_state.entries[0..2], opened.capture.user_state.entries[0..2]);
    try std.testing.expectEqualSlices(u8, capture.user_state.bytes[0..16], opened.capture.user_state.bytes);
    try std.testing.expectEqualSlices(u8, bytes, opened.bytes);
    try std.testing.expectEqual(unwind.Reason.asset_missing, (try unwind.walk(a, opened.capture, 0, null)).reason);
    try std.testing.expectEqual(unwind.Reason.retention_budget, (try unwind.walk(a, opened.capture, 1, null)).reason);
    var resolved = try archive.decode(a, bytes, .{ .local_id = 9, .resolver = .{ .enabled = true } });
    defer resolved.deinit();
    try std.testing.expectEqualSlices(u8, &expected.analysis_id, &(try unwind.walk(a, resolved.capture, 0, null)).analysis_id);
    // A new reader must not silently accept USTA without its required feature.
    std.mem.writeInt(u64, bytes[40..48], 9, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
    try std.testing.expectError(error.ArchiveSectionLayout, archive.decode(a, bytes, .{ .local_id = 10 }));
    std.mem.writeInt(u64, bytes[40..48], 13, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
    const directory = bytes[archive.header_bytes + 9 * archive.entry_bytes ..][0..archive.entry_bytes];
    const offset = std.mem.readInt(u64, directory[8..16], .little);
    // Budget larger than the hard bound, even with a valid CRC.
    std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], 0xffffffff, .little);
    std.mem.writeInt(u32, directory[20..24], std.hash.Crc32.hash(bytes[offset..][0..std.mem.readInt(u32, directory[16..20], .little)]), .little);
    try std.testing.expectError(error.ArchiveInvalidValue, archive.decode(a, bytes, .{ .local_id = 11 }));
}
test "stack worker cancellation is terminal and replacing a capture cannot reuse a result" {
    const Session = @import("../model/session.zig").Session;
    const Job = @import("archive_job.zig").Job;
    var session = Session.init();
    defer session.deinit();
    session.profile = try build();
    const job = try Job.create(7, .stack, "cancelled sampled stack");
    session.archive_job = job;
    job.capture = session.profile;
    job.capture_id = session.profile.?.id;
    job.capture_revision = session.profile.?.revision;
    session.profile.?.archive_busy = true;
    job.progress.cancel.store(true, .release);
    try job.start();
    try std.testing.expectError(error.ArchiveCancelled, session.finishArchive());
    try std.testing.expect(!session.profile.?.archive_busy);
    try std.testing.expectEqual(job, try session.requestProfileStack(0));
    session.profile.?.revision += 1;
    const next = try session.requestProfileStack(0);
    try std.testing.expect(next.id != 7);
    try session.finishArchive();
    try std.testing.expectEqual(unwind.Reason.complete, next.stack_result.?.reason);
}
