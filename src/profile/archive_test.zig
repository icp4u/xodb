const std = @import("std");
const archive = @import("archive.zig");
const fixture = @import("archive_fixture.zig");
const a = std.testing.allocator;
fn compare(left: *@import("capture.zig").Capture, right: *@import("capture.zig").Capture, filter: @import("capture.zig").Filter) !void {
    var one = try left.graph(a, filter);
    defer one.deinit();
    var two = try right.graphDirect(a, filter);
    defer two.deinit();
    try std.testing.expectEqual(one.nodes.items.len, two.nodes.items.len);
    try std.testing.expectEqual(one.rejected, two.rejected);
    for (one.nodes.items, two.nodes.items) |l, r| {
        try std.testing.expectEqual(l.parent, r.parent);
        try std.testing.expectEqual(l.frame.kind, r.frame.kind);
        try std.testing.expectEqual(l.frame.address, r.frame.address);
        try std.testing.expectEqual(l.frame.mapping_id, r.frame.mapping_id);
        try std.testing.expectEqualStrings(l.frame.name, r.frame.name);
        try std.testing.expectEqual(l.inclusive, r.inclusive);
        try std.testing.expectEqual(l.self, r.self);
    }
}
test "archive preserves origin labels and manifest through real second reopen without assets" {
    const original = try fixture.build(a, .representative, "zig-out/bin/xodb-profile-fixture");
    defer original.deinit();
    original.boot_id = "00000000-1111-2222-3333-444444444444".*;
    // Do not warm the original graph cache before saving.
    const bytes = try archive.encode(a, original, .{ .writer_boot_id = "99999999-8888-7777-6666-555555555555".* });
    defer a.free(bytes);
    var opened = try archive.decode(a, bytes, .{ .local_id = 101 });
    defer opened.deinit();
    try std.testing.expect(opened.capture.offline);
    try std.testing.expectEqual(@as(usize, 0), opened.capture.images.loaded.items.len);
    try std.testing.expectEqual(@as(usize, 1), opened.source.images.len);
    try std.testing.expectEqual(original.boot_id, opened.source.boot_id);
    try std.testing.expect(!std.mem.eql(u8, &opened.source.boot_id.?, &opened.source.writer_boot_id.?));
    var again = try archive.decode(a, opened.bytes, .{ .local_id = 102 });
    defer again.deinit();
    try std.testing.expectEqual(original.id, again.source.capture_id);
    try std.testing.expectEqual(original.pid, again.source.pid);
    try std.testing.expectEqual(original.generation, again.source.generation);
    try std.testing.expectEqual(original.session_id, again.source.session_id);
    try std.testing.expectEqualSlices(u8, bytes, again.bytes);
    try std.testing.expectError(error.ArchiveUseOriginalBytes, archive.encode(a, opened.capture, .{}));
    try compare(original, opened.capture, .{});
    try compare(original, again.capture, .{ .tid = 4100, .from_ns = 1000, .to_ns = 900000000 });
    var multiple = @import("capture.zig").Filter{};
    try multiple.setThreads(&.{ 4100, 4101 });
    try compare(original, again.capture, multiple);
    try std.testing.expect(!std.mem.eql(u8, &opened.viewId(multiple), &opened.viewId(.{})));
    var graph = try opened.capture.graph(a, .{});
    defer graph.deinit();
    var source_found = false;
    for (graph.nodes.items) |node| if (std.mem.eql(u8, node.frame.name, "hot_hash")) {
        const site = try opened.capture.source(a, node.frame);
        try std.testing.expect(std.mem.endsWith(u8, site.path, "tests/fixtures/profile.c"));
        source_found = true;
        break;
    };
    try std.testing.expect(source_found);
    try std.testing.expect(!std.mem.eql(u8, &opened.viewId(.{}), &opened.viewId(.{ .tid = 4100 })));
    try std.testing.expectEqualSlices(u8, &opened.viewId(.{}), &again.viewId(.{}));
}
test "archive optional sections survive copying and required features fail explicitly" {
    const capture = try fixture.build(a, .empty, null);
    defer capture.deinit();
    const original = try archive.encode(a, capture, .{});
    defer a.free(original);
    const count = std.mem.readInt(u32, original[24..28], .little);
    const table_end = archive.header_bytes + count * archive.entry_bytes;
    const bytes = try a.alloc(u8, original.len + archive.entry_bytes + 3);
    defer a.free(bytes);
    @memcpy(bytes[0..table_end], original[0..table_end]);
    @memcpy(bytes[table_end + archive.entry_bytes ..][0 .. original.len - table_end], original[table_end..]);
    for (0..count) |i| {
        const entry = bytes[archive.header_bytes + i * archive.entry_bytes ..][0..archive.entry_bytes];
        std.mem.writeInt(u64, entry[8..16], std.mem.readInt(u64, entry[8..16], .little) + archive.entry_bytes, .little);
    }
    const ext = bytes[table_end..][0..archive.entry_bytes];
    std.mem.writeInt(u32, ext[0..4], 0x54534554, .little);
    std.mem.writeInt(u32, ext[4..8], 1, .little);
    std.mem.writeInt(u64, ext[8..16], bytes.len - 3, .little);
    std.mem.writeInt(u32, ext[16..20], 3, .little);
    @memcpy(bytes[bytes.len - 3 ..], "abc");
    std.mem.writeInt(u32, ext[20..24], std.hash.Crc32.hash("abc"), .little);
    std.mem.writeInt(u32, bytes[24..28], count + 1, .little);
    std.mem.writeInt(u64, bytes[16..24], bytes.len, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
    var opened = try archive.decode(a, bytes, .{ .local_id = 2 });
    defer opened.deinit();
    try std.testing.expectEqual(@as(usize, 1), opened.source.ignored_sections);
    try std.testing.expectEqualSlices(u8, bytes, opened.bytes);
    std.mem.writeInt(u64, bytes[40..48], 129, .little);
    std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
    try std.testing.expectError(error.ArchiveFeatureUnsupported, archive.decode(a, bytes, .{ .local_id = 3 }));
}
test "archive decoding respects allocation and cancellation budgets and rejects malformed input" {
    const capture = try fixture.build(a, .representative, null);
    defer capture.deinit();
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    try std.testing.expectError(error.ArchiveMemoryLimit, archive.decode(a, bytes, .{ .local_id = 1, .max_memory_bytes = 1 }));
    var state = @import("archive_progress.zig").Progress{};
    state.cancel.store(true, .release);
    try std.testing.expectError(error.ArchiveCancelled, archive.decode(a, bytes, .{ .local_id = 1, .progress = &state }));
    for ([_]usize{ 0, 1, 63, 64, 100, bytes.len - 1 }) |len| try std.testing.expectError(error.ArchiveTruncated, archive.decode(a, bytes[0..len], .{ .local_id = 1 }));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.ArchiveChecksum, archive.decode(a, bytes, .{ .local_id = 1 }));
}

test "archive worker cancellation preserves capture and does not retry the failed view" {
    const Session = @import("../model/session.zig").Session;
    const Job = @import("archive_job.zig").Job;
    const capture = try fixture.build(a, .representative, null);
    defer capture.deinit();
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    var session = Session.init();
    defer session.deinit();
    session.artifact = try archive.decode(a, bytes, .{ .local_id = 1 });
    session.profile = session.artifact.?.capture;
    session.offline = true;
    const job = try Job.create(1, .view, "cancelled test view");
    session.archive_job = job;
    job.capture = session.profile;
    job.filter = .{ .tid = 4100 };
    job.progress.cancel.store(true, .release);
    try job.start();
    try std.testing.expectError(error.ArchiveCancelled, session.finishArchive());
    try std.testing.expectError(error.ArchiveCancelled, session.ensureArchiveView(job.filter));
    try std.testing.expectEqual(@as(u64, 1), session.archive_job.?.id);
    try std.testing.expect(session.profile.?.offline_graph != null);
    try session.ensureArchiveView(.{});
    // A successful asynchronous view keeps its job alive through the pending
    // result, and its labels must refer to capture storage after the thread exits.
    const selected = @import("capture.zig").Filter{ .tid = 4101 };
    try std.testing.expectError(error.ArchiveViewPending, session.ensureArchiveView(selected));
    const selected_job = session.archive_job.?.id;
    try session.finishArchive();
    try session.ensureArchiveView(selected);
    try std.testing.expectEqual(selected_job, session.archive_job.?.id);
    try compare(capture, session.profile.?, selected);
    const save = try Job.create(2, .save, ".work/archive-cancelled-must-not-exist.xcap");
    defer save.deinit();
    save.original_bytes = session.artifact.?.bytes;
    save.progress.cancel.store(true, .release);
    try save.start();
    save.join();
    const status = save.status();
    try std.testing.expect(status.done);
    try std.testing.expectEqualStrings("ArchiveCancelled", status.publication.?.error_name.?);
    try std.testing.expectEqual(.not_published, status.publication.?.state);
}

test "archive largest evidence counts and long paths fit measured independent budgets" {
    const c = @import("../c.zig").api;
    const now = @import("../target/linux.zig").now;
    const original = try fixture.build(a, .scaled, null);
    defer original.deinit();
    // Near the aggregate mapping path bound, without relying on small fixture paths.
    const path = try original.arena.allocator().alloc(u8, 1023);
    @memset(path, 'x');
    path[0] = '/';
    for (original.history.entries.items[0..original.history.opening_count]) |*entry| entry.path = path;
    // Exercise the largest supported sampled-state budget alongside the largest
    // existing evidence counts; codec limits must remain independently usable.
    const records = @import("records.zig");
    const model = @import("capture.zig");
    original.config.user_stack_bytes = 4096;
    original.config.user_stack_budget_bytes = model.sample_state.max_budget_bytes;
    original.accepted.user_stack_bytes = 4096;
    original.accepted.user_regs_mask = records.user_regs_gpr_mask;
    original.accepted.sample_type |= records.Bits.regs_user | records.Bits.stack_user;
    original.user_state = try model.sample_state.Store.init(a, original.samples.len(), model.sample_state.max_budget_bytes);
    const stack: [4096]u8 = @splat(7);
    const raw = records.UserState{ .abi = 2, .regs_mask = records.user_regs_gpr_mask, .regs_present = true, .stack_size = 4096, .stack_dyn = 4096, .stack_len = 4096, .stack_present = true };
    for (0..original.samples.len()) |ordinal| original.samples.coreMut(ordinal).user_state = try original.user_state.append(raw, &stack);
    var encoding = @import("archive_budget.zig").Budget{ .backing = a, .limit = 2 * archive.max_memory_bytes };
    const started = now();
    const bytes = try archive.encode(encoding.allocator(), original, .{});
    defer encoding.allocator().free(bytes);
    const encoded = now();
    var opened = try archive.decode(a, bytes, .{ .local_id = 1 });
    defer opened.deinit();
    const decoded = now();
    try std.testing.expectEqual(original.samples.len(), opened.capture.samples.len());
    try std.testing.expect(opened.budget.peak < archive.max_memory_bytes);
    try std.testing.expectEqual(@as(usize, 1023), opened.capture.history.entries.items[0].path.len);
    var view = try opened.capture.graphDirect(a, .{ .tid = 4100 });
    defer view.deinit();
    std.debug.print("archive budget: bytes={d} encoded_peak={d} decoded_peak={d} encode_ms={d} decode_and_graph_ms={d} filter_ms={d} nodes={d} excluded_samples={d}\n", .{ bytes.len, encoding.peak, opened.budget.peak, (encoded - started) / 1_000_000, (decoded - encoded) / 1_000_000, (now() - decoded) / 1_000_000, opened.capture.offline_graph.?.nodes.items.len, opened.capture.offline_graph.?.rejected });
    if (c.getenv("XODB_ARCHIVE_BUDGET_PATH")) |destination| {
        const result = archive.publish(std.mem.span(destination), bytes, null);
        try std.testing.expectEqual(.published, result.state);
    }
}

test "archive extended durations round trip with an explicit required feature" {
    const capture = try fixture.build(a, .empty, null);
    defer capture.deinit();
    for ([_]u32{ 0, 300000, std.math.maxInt(u32) }) |duration| {
        capture.config.duration_ms = duration;
        const bytes = try archive.encode(a, capture, .{});
        defer a.free(bytes);
        try std.testing.expectEqual(@as(u64, 11), std.mem.readInt(u64, bytes[40..48], .little));
        var opened = try archive.decode(a, bytes, .{ .local_id = 1 });
        defer opened.deinit();
        try std.testing.expectEqual(duration, opened.capture.config.duration_ms);
        std.mem.writeInt(u64, bytes[40..48], 9, .little);
        std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
        try std.testing.expectError(error.ArchiveFeatureUnsupported, archive.decode(a, bytes, .{ .local_id = 2 }));
    }
}

test "remote clock provenance round trips independently of the host boot" {
    const capture = try fixture.build(a, .empty, null);
    defer capture.deinit();
    capture.boot_id = "00000000-1111-2222-3333-444444444444".*;
    capture.producer = .{ .machine = 62, .address_bits = 64, .little_endian = true, .boot_id = "99999999-8888-7777-6666-555555555555".*, .monotonic_ns = 1000, .host_monotonic_ns = 9000, .uncertainty_ns = 50 };
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    var opened = try archive.decode(a, bytes, .{ .local_id = 2 });
    defer opened.deinit();
    try std.testing.expectEqual(@as(u16, 6), opened.source.format_minor);
    try std.testing.expectEqualDeep(capture.producer, opened.capture.producer);
    try std.testing.expectEqualDeep(capture.producer, opened.source.producer);
    try std.testing.expectEqual(capture.boot_id, opened.source.boot_id);
    try std.testing.expectEqual(@as(usize, 0), opened.source.ignored_sections);
    // Keep checksums valid, so rejection proves the section itself is checked.
    const n = std.mem.readInt(u32, bytes[24..28], .little);
    const entry = bytes[archive.header_bytes + (n - 1) * archive.entry_bytes ..][0..archive.entry_bytes];
    const offset = std.mem.readInt(u64, entry[8..16], .little);
    const body = bytes[@intCast(offset)..];
    body[0] = 2;
    std.mem.writeInt(u32, entry[20..24], std.hash.Crc32.hash(body), .little);
    try std.testing.expectError(error.ArchiveUnsupportedValue, archive.decode(a, bytes, .{ .local_id = 3 }));
}

test "archive rejects inconsistent sampled user evidence" {
    const capture = try fixture.build(a, .representative, "zig-out/bin/xodb-profile-fixture");
    defer capture.deinit();
    capture.accepted.user_stack_bytes = 4096;
    try std.testing.expectError(error.ArchiveInconsistent, archive.encode(a, capture, .{}));
    capture.accepted.user_stack_bytes = 0;
    capture.samples.coreMut(0).user_state = 1;
    try std.testing.expectError(error.ArchiveInconsistent, archive.encode(a, capture, .{}));
}

test "dynamic scope round trips, snapshots detach enrollment and legacy captures stay fixed" {
    const capture = try fixture.build(a, .representative, null);
    defer capture.deinit();
    const last = capture.thread_count - 1;
    const enrollment = capture.started_ns + 1;
    capture.threads[last].enrolled_ns = enrollment;
    capture.config.ring_budget_bytes = 1048576;
    const frozen = try @import("recorded_view.zig").snapshot(a, capture);
    defer frozen.deinit();
    capture.threads[last].enrolled_ns = enrollment + 1;
    try std.testing.expectEqual(enrollment, frozen.threads[last].enrolled_ns.?);
    try std.testing.expect(frozen.config.follow_threads);
    const bytes = try archive.encode(a, capture, .{});
    defer a.free(bytes);
    var opened = try archive.decode(a, bytes, .{ .local_id = 1 });
    defer opened.deinit();
    try std.testing.expect(opened.capture.config.follow_threads);
    try std.testing.expectEqual(@as(u32, 1048576), opened.capture.config.ring_budget_bytes);
    try std.testing.expectEqualDeep(capture.threads[0..capture.thread_count], opened.capture.threads[0..opened.capture.thread_count]);
    capture.config.follow_threads = false;
    try std.testing.expectError(error.ArchiveInconsistent, archive.encode(a, capture, .{}));
    capture.config.follow_threads = true;
    capture.threads[last].enrolled_ns = capture.ended_ns.? + 1;
    try std.testing.expectError(error.ArchiveInconsistent, archive.encode(a, capture, .{}));
    // Strip the appended scope section to recreate the legacy 2.2 layout.
    // Its reader must never inherit today's default follow_threads=true.
    const n = std.mem.readInt(u32, bytes[24..28], .little);
    const entry = bytes[archive.header_bytes + (n - 1) * archive.entry_bytes ..][0..archive.entry_bytes];
    try std.testing.expectEqual(@intFromEnum(archive.Tag.thread_scope), std.mem.readInt(u32, entry[0..4], .little));
    const offset: usize = @intCast(std.mem.readInt(u64, entry[8..16], .little));
    const legacy = try a.alloc(u8, offset - archive.entry_bytes);
    defer a.free(legacy);
    const old_table = archive.header_bytes + n * archive.entry_bytes;
    const new_table = old_table - archive.entry_bytes;
    @memcpy(legacy[0..new_table], bytes[0..new_table]);
    @memcpy(legacy[new_table..], bytes[old_table..offset]);
    for (0..n - 1) |i| {
        const e = legacy[archive.header_bytes + i * archive.entry_bytes ..][0..archive.entry_bytes];
        std.mem.writeInt(u64, e[8..16], std.mem.readInt(u64, e[8..16], .little) - archive.entry_bytes, .little);
    }
    std.mem.writeInt(u16, legacy[10..12], 2, .little);
    std.mem.writeInt(u64, legacy[16..24], legacy.len, .little);
    std.mem.writeInt(u32, legacy[24..28], n - 1, .little);
    std.mem.writeInt(u64, legacy[40..48], std.mem.readInt(u64, legacy[40..48], .little) & ~@as(u64, 8), .little);
    std.mem.writeInt(u32, legacy[56..60], std.hash.Crc32.hash(legacy[0..56]), .little);
    var old = try archive.decode(a, legacy, .{ .local_id = 2 });
    defer old.deinit();
    try std.testing.expect(!old.capture.config.follow_threads);
    try std.testing.expectEqual(@as(?u32, null), old.capture.summary().ring_budget_bytes);
    for (old.capture.threads[0..old.capture.thread_count]) |thread| try std.testing.expectEqual(@as(?u64, null), thread.enrolled_ns);
    // A claimed dynamic capture with its section removed is rejected.
    std.mem.writeInt(u64, legacy[40..48], std.mem.readInt(u64, legacy[40..48], .little) | 8, .little);
    std.mem.writeInt(u32, legacy[56..60], std.hash.Crc32.hash(legacy[0..56]), .little);
    try std.testing.expectError(error.ArchiveSectionLayout, archive.decode(a, legacy, .{ .local_id = 3 }));
}

test "archive configurable sample ceiling is preserved and enforced before sample allocation" {
    const model = @import("capture.zig");
    const capture = try fixture.build(a, .absent, null);
    defer capture.deinit();
    for ([_]u32{ 2, model.max_samples, model.max_sample_limit }) |limit| {
        capture.config.sample_limit = limit;
        const bytes = try archive.encode(a, capture, .{});
        defer a.free(bytes);
        var opened = try archive.decode(a, bytes, .{ .local_id = 1 });
        defer opened.deinit();
        try std.testing.expectEqual(limit, opened.capture.config.sample_limit);
        try std.testing.expectEqual(limit, opened.capture.samples.max_samples);
        try std.testing.expectEqual(limit, opened.capture.summary().sample_limit);
        try std.testing.expectEqualSlices(u8, bytes, opened.bytes);
        if (limit == model.max_samples) {
            try std.testing.expectEqual(@as(u16, 3), opened.source.format_minor);
            try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, bytes[40..48], .little));
            continue;
        }
        try std.testing.expectEqual(@as(u16, 4), opened.source.format_minor);
        const n = std.mem.readInt(u32, bytes[24..28], .little);
        const entry = bytes[archive.header_bytes + (n - 1) * archive.entry_bytes ..][0..archive.entry_bytes];
        try std.testing.expectEqual(@intFromEnum(archive.Tag.limits), std.mem.readInt(u32, entry[0..4], .little));
        const offset = std.mem.readInt(u64, entry[8..16], .little);
        const body = bytes[offset..][0..4];
        for ([_]u32{ 0, 1, model.max_sample_limit + 1 }) |bad_limit| {
            std.mem.writeInt(u32, body, bad_limit, .little);
            std.mem.writeInt(u32, entry[20..24], std.hash.Crc32.hash(body), .little);
            try std.testing.expectError(error.ArchiveLimit, archive.decode(a, bytes, .{ .local_id = 2 }));
        }
        std.mem.writeInt(u32, body, limit, .little);
        std.mem.writeInt(u32, entry[20..24], std.hash.Crc32.hash(body), .little);
        std.mem.writeInt(u64, bytes[40..48], 9, .little);
        std.mem.writeInt(u32, bytes[56..60], std.hash.Crc32.hash(bytes[0..56]), .little);
        try std.testing.expectError(error.ArchiveSectionLayout, archive.decode(a, bytes, .{ .local_id = 2 }));
    }
    capture.config.sample_limit = 1;
    try std.testing.expectError(error.ArchiveLimit, archive.encode(a, capture, .{}));
}

test "syscall archives preserve partial boundaries, limits and raw results" {
    const original = try fixture.build(a, .representative, "zig-out/bin/xodb-profile-fixture");
    defer original.deinit();
    original.config.follow_threads = false;
    original.config.syscall_timing = true;
    original.config.syscall_limit = 20;
    original.syscalls = .{ .enabled = true, .limit = 20 };
    const begin = original.started_ns;
    try original.syscalls.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = begin + 10, .result = 1 } });
    try original.syscalls.feed(a, 0, .{ .call = .{ .enter = true, .nr = 0, .time = begin + 20, .result = null } });
    try original.syscalls.feed(a, 0, .{ .call = .{ .enter = false, .nr = 0, .time = begin + 2000, .result = -9 } });
    try original.syscalls.feed(a, 0, .{ .call = .{ .enter = true, .nr = 231, .time = begin + 2100, .result = null } });
    try original.syscalls.finish(a, .thread_exit);
    const encoded = try archive.encode(a, original, .{});
    defer a.free(encoded);
    var opened = try archive.decode(a, encoded, .{ .local_id = 101 });
    defer opened.deinit();
    try std.testing.expectEqual(@as(u16, 5), opened.source.format_minor);
    try std.testing.expectEqualDeep(original.syscalls.items.items, opened.capture.syscalls.items.items);
    try std.testing.expectEqualDeep(original.syscallSummary(), opened.capture.syscallSummary());
    const page = try opened.capture.syscallPage(a, .{}, 1, 1);
    defer a.free(page.rows);
    try std.testing.expectEqual(2, page.next.?);
    try std.testing.expectEqual(1980, page.rows[0].elapsed_ns.?);
    try std.testing.expectEqual(-9, page.rows[0].result.?);
    original.syscalls.items.items[1].exit_ns = begin + 1;
    try std.testing.expectError(error.ArchiveInconsistent, archive.encode(a, original, .{}));
}

test "invalid optional frame evidence survives without blocking native capture" {
    const capture = try fixture.build(a, .representative, null);
    defer capture.deinit();
    const native = try archive.encode(a, capture, .{});
    defer a.free(native);
    const copied = try archive.attachFrames(a, native, null);
    defer a.free(copied);
    try std.testing.expectEqualSlices(u8, native, copied);
    const malformed = try archive.attachFrames(a, native, "invalid frame envelope");
    defer a.free(malformed);
    var opened = try archive.decode(a, malformed, .{ .local_id = 1 });
    defer opened.deinit();
    try std.testing.expectEqual(capture.samples.len(), opened.capture.samples.len());
    try std.testing.expectEqualStrings("invalid frame envelope", opened.frame_bundle.?);
    try std.testing.expectEqual(.retained_opaque, opened.source.frame_attachments.?.state);
}
