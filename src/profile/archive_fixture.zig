//! Codec test fixtures adapted from the delivered T11 synthetic captures.
const std = @import("std");
const c = @import("../c.zig").api;
const capture_model = @import("capture.zig");
const perf = @import("linux_perf.zig");
const records = @import("records.zig");
const mappings = @import("mappings.zig");
const scheduling = @import("scheduling.zig");
const timeline = @import("timeline.zig");
const modules = @import("../model/modules.zig");
const elf = @import("../binary/elf.zig");
const Capture = capture_model.Capture;

pub const Kind = enum { empty, absent, representative, budget, scaled };
pub const base_ns: u64 = 5_000_000_000;
/// PIE load bias used for a real ELF in the representative capture.
pub const elf_bias: u64 = 0x5555_5555_4000;

fn blank(a: std.mem.Allocator, threads: usize) !*Capture {
    const capture = try a.create(Capture);
    capture.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = 7, .session_id = 3, .generation = 42, .image_epoch = 2, .pid = 4100, .started_ns = base_ns, .ended_ns = base_ns + 2_000_000_000, .observed_until_ns = base_ns + 1_999_000_000, .config = .{ .frequency_hz = 997, .duration_ms = 10000, .context_switch = true }, .accepted = .{ .event = .task_clock, .requested_frequency_hz = 997, .kernel_max_sample_rate = 100000, .kernel_max_stack = 127, .exclude_kernel = true, .mmap_data = true, .callchain = true, .include_weight = false, .sample_type = 0x1a7, .sample_max_stack = 64, .clockid = 1, .ring_data_bytes = 262144, .data_offset = 4096, .mmap_version = 0, .threads = @intCast(threads), .context_switch = true }, .thread_count = threads, .collector = null, .images = modules.Modules.init(a), .status = .manual, .revision = 99, .debugger_sequence = 77 };
    for (0..threads) |i| {
        capture.threads[i] = .{ .debugger_id = i + 1, .perf = .{ .tid = @intCast(4100 + i), .event_id = 900 + i, .start_time_ticks = 123456 + i, .start_time_known = i % 3 != 2 } };
        _ = std.fmt.bufPrintSentinel(&capture.thread_names[i], "Thread {d}", .{4100 + i}, 0) catch unreachable;
        if (i % 2 == 0) capture.cpu_before[i] = .{ .start_time = 123456 + i, .user = 10 * i, .kernel = i };
    }
    return capture;
}

/// Maps an ELF file as a capture-time image, the way capture opening does.
pub fn addElf(capture: *Capture, path: []const u8, start: u64, end: u64) !*modules.Module {
    const a = capture.images.allocator;
    const name = try a.dupeSentinel(u8, path, 0);
    errdefer a.free(name);
    const fd = c.open(name.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.FixtureElfMissing;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0) return error.FixtureElfMissing;
    const mapped = try @import("../binary/snapshot.zig").read(fd, @import("../binary/snapshot.zig").per_image_limit, null);
    errdefer _ = c.munmap(mapped.ptr, mapped.len);
    const module = try a.create(modules.Module);
    errdefer a.destroy(module);
    module.* = .{ .id = capture.images.next_id, .inode = @intCast(stat.st_ino), .device_major = c.major(stat.st_dev), .device_minor = c.minor(stat.st_dev), .path = name, .image = try elf.Image.parse(mapped), .bias = elf_bias, .start = start, .end = end, .mapping = mapped, .immutable = true };
    capture.images.next_id += 1;
    try capture.images.loaded.append(a, module);
    return module;
}

fn chainSample(time: u64, tid: u32, ip: u64, callers: []const u64) records.Sample {
    var sample = records.Sample{ .ip = ip, .ip_present = true, .ip_exact = true, .pid = 4100, .tid = tid, .tid_present = true, .time_ns = time, .time_present = true, .period = 1_002_000, .period_present = true, .cpu_mode = .user, .callchain = .complete };
    sample.frames[0] = .{ .marker = true, .context = .user, .raw_marker = records.context_user };
    sample.frames[1] = .{ .context = .user, .address = ip };
    for (callers, 2..) |caller, i| sample.frames[i] = .{ .context = .user, .address = caller };
    sample.frame_count = @intCast(2 + callers.len);
    return sample;
}

/// `elf_path`, when given, becomes image 1 mapped executable at `elf_bias`
/// with symbol-resolving samples in `hot_hash` under recursive callers.
pub fn build(a: std.mem.Allocator, kind: Kind, elf_path: ?[]const u8) !*Capture {
    return switch (kind) {
        .empty => blk: {
            const capture = try blank(a, 1);
            capture.config.context_switch = false;
            capture.accepted.context_switch = false;
            capture.status = .duration;
            break :blk capture;
        },
        .absent => absent(a),
        .representative => representative(a, elf_path),
        .budget => budget(a, capture_model.max_samples),
        .scaled => budget(a, capture_model.max_sample_limit),
    };
}

/// Every optional field absent and every presence flag false, plus a sample
/// whose fields are all absent (kept but invalid for views).
fn absent(a: std.mem.Allocator) !*Capture {
    const capture = try blank(a, 1);
    errdefer capture.deinit();
    capture.ended_ns = base_ns;
    capture.observed_until_ns = 0;
    capture.config.context_switch = false;
    capture.cpu_before[0] = null;
    try capture.samples.append(a, .{});
    try capture.samples.append(a, .{ .ip = 0, .ip_present = true, .tid = 0, .tid_present = true, .time_ns = base_ns, .time_present = true, .period = 0, .period_present = true, .weight = 0, .weight_present = true });
    return capture;
}

fn representative(a: std.mem.Allocator, elf_path: ?[]const u8) !*Capture {
    const capture = try blank(a, 4);
    errdefer capture.deinit();
    const arena = capture.arena.allocator();
    // Mapping history: the same range [R, R+0x10000) is the ELF (or another
    // file) at opening, replaced by an anonymous mapping, then by a second
    // identity: reused ranges must keep separate IDs.
    var R: u64 = elf_bias + 0x1000;
    var hot: u64 = R + 0x200;
    var recursive: u64 = R + 0x400;
    var main: u64 = R + 0x600;
    var image_id: u64 = 0;
    if (elf_path) |path| {
        const module = try addElf(capture, path, 0, 0);
        image_id = module.id;
        for ([_]struct { name: []const u8, out: *u64 }{ .{ .name = "hot_hash", .out = &hot }, .{ .name = "recursive_mix", .out = &recursive }, .{ .name = "main", .out = &main } }) |want| {
            const symbol = module.image.findSymbol(want.name) orelse return error.FixtureSymbolMissing;
            want.out.* = symbol.value + elf_bias + 4;
        }
        // The executable range covers the symbols, PIE or not.
        R = @min(hot, @min(recursive, main)) & ~@as(u64, 0xfff);
        module.start = R;
        module.end = R + 0x10000;
    }
    try capture.history.opening(a, .{ .start = 0x1000, .end = 0x2000, .executable = false, .reason = .non_executable, .path = "[heap]" });
    try capture.history.opening(a, .{ .start = R, .end = R + 0x10000, .image_id = image_id, .device_major = 259, .device_minor = 2, .inode = 777, .reason = if (image_id != 0) .elf else .image_unavailable, .path = try arena.dupe(u8, elf_path orelse "/opt/app/bin/game") });
    _ = try capture.history.add(a, base_ns + 1_000_000_000, .{ .start = R, .end = R + 0x10000, .reason = .anonymous, .path = "" });
    _ = try capture.history.add(a, base_ns + 1_500_000_000, .{ .start = R + 0x1000, .end = R + 0x2000, .device_major = 259, .device_minor = 2, .inode = 888, .reason = .truncated_path, .path = "/opt/app/lib/libtruncated-path-exam" });
    capture.mapping_revision = 2;
    capture.mapping_events = 2;
    // Samples: recursion (same PC at several depths), a thread with partial
    // chains, out-of-order delivery, and samples before start / unknown TID.
    var i: u64 = 0;
    while (i < 2000) : (i += 1) {
        const t = base_ns + 1_000_000 + i * 997_000;
        const tid: u32 = @intCast(4100 + i % 4);
        if (i % 4 == 3) {
            var sample = chainSample(t, tid, hot, &.{});
            sample.callchain = .truncated;
            try capture.samples.append(a, sample);
        } else {
            try capture.samples.append(a, chainSample(t, tid, hot, &.{ recursive + 1, recursive + 1, recursive + 1, main + 1 }));
        }
    }
    capture.samples.swap(10, 11);
    try capture.samples.append(a, chainSample(base_ns - 5, 4100, hot, &.{}));
    try capture.samples.append(a, chainSample(base_ns + 50, 9999, hot, &.{}));
    var kernel = chainSample(base_ns + 60, 4101, 0xffffffff81000000, &.{});
    kernel.cpu_mode = .kernel;
    kernel.frames[1].context = .kernel;
    kernel.weight = 0;
    kernel.weight_present = true;
    try capture.samples.append(a, kernel);
    // Scheduling: lane 0 alternates; lane 1 is contradictory; lane 2 hit its
    // budget (cutoff, unknown suffix); lane 3 has only an unmatched start.
    var offset: u64 = 5_000_000;
    var out = false;
    while (offset < 1_900_000_000) : (offset += 7_000_000) {
        capture.switches.add(a, 0, .{ .offset_ns = offset, .direction = if (out) .switch_out else .switch_in, .preempted = out and offset % 3 == 0 }) catch {};
        out = !out;
    }
    capture.switches.add(a, 1, .{ .offset_ns = 10, .direction = .switch_in }) catch {};
    capture.switches.add(a, 1, .{ .offset_ns = 20, .direction = .switch_in }) catch {};
    capture.switches.add(a, 2, .{ .offset_ns = 30, .direction = .switch_in }) catch {};
    capture.switches.lanes[2].cutoff_ns = 800_000_000;
    capture.switches.discarded = 17;
    capture.switches.add(a, 3, .{ .offset_ns = 1_200_000_000, .direction = .switch_out, .preempted = true }) catch {};
    capture.switches.invalid = 0;
    // Imported intervals: a frame per thread, a global instant, and labels.
    try capture.addIntervals("frame timing CSV (synthetic)", &.{
        .{ .from_ns = 100_000_000, .to_ns = 116_600_000, .tid = 4100, .label = "frame 6 \u{2014} hitch?", .kind = .frame, .correlation_id = 6 },
        .{ .from_ns = 700_000_000, .to_ns = 700_000_000, .label = "level load", .kind = .custom },
        .{ .from_ns = 900_000_000, .to_ns = 1_400_000_000, .tid = 4102, .label = "GET /api", .kind = .request },
    });
    // Whole-capture debugger markers, including one at the opening.
    for ([_]timeline.Marker{ .{ .offset_ns = 0, .sequence = 50, .tid = 4100, .kind = .capture_open_stopped }, .{ .offset_ns = 900_000, .sequence = 51, .tid = 4100, .kind = .continued }, .{ .offset_ns = 1_600_000_000, .sequence = 60, .tid = 4101, .kind = .breakpoint_hit }, .{ .offset_ns = 1_600_000_000, .sequence = 61, .tid = 4101, .kind = .stop } }) |marker| capture.addMarker(marker);
    capture.debugger_marker_dropped = 1;
    capture.revision = 99;
    capture.failure = .{ .kind = .thread_gone, .syscall = "perf_event_open", .errno = 3, .tid = 4103, .opened_then_closed = 2, .detail = "thread exited during open" };
    capture.lost_records = 1;
    capture.lost_samples = 3;
    capture.throttles = 2;
    capture.unthrottles = 2;
    capture.scope_change = .{ .pid = 4100, .tid = 4199, .parent_pid = 4100, .parent_tid = 4101, .time_ns = null };
    capture.trusted_before_ns = base_ns + 1_700_000_000;
    capture.cpu_activity = .{ .user_ms = 1800, .kernel_ms = null, .available_threads = 3, .unavailable_threads = 1, .ticks_per_second = 100, .complete = false };
    capture.status = .metadata_lost;
    if (comptime @hasField(Capture, "stop_reasons")) {
        capture.stop_reasons[0] = .metadata_lost;
        capture.stop_reasons[1] = .thread_scope_changed;
        capture.stop_reason_count = 2;
    }
    capture.diagnostic = "perf reported lost samples; mapping history may be incomplete";
    capture.unselected_threads = 2;
    return capture;
}

/// Every retained-evidence bound at its maximum.
fn budget(a: std.mem.Allocator, sample_limit: u32) !*Capture {
    const threads: usize = perf.max_threads;
    const capture = try blank(a, threads);
    errdefer capture.deinit();
    const arena = capture.arena.allocator();
    try capture.history.entries.ensureTotalCapacity(a, mappings.max_opening + mappings.max_changes);
    for (0..mappings.max_opening) |i| {
        const start = 0x10000 + i * 0x2000;
        try capture.history.opening(a, .{ .start = start, .end = start + 0x1000, .executable = i % 2 == 0, .reason = if (i % 2 == 0) .anonymous else .non_executable, .path = try std.fmt.allocPrint(arena, "/usr/lib/budget/libsynthetic-{d:0>5}.so", .{i}) });
    }
    for (0..mappings.max_changes) |i| {
        const start = 0x10000 + i * 0x2000 + 0x800;
        _ = try capture.history.add(a, base_ns + 1 + i, .{ .start = start, .end = start + 0x400, .reason = .anonymous, .path = "" });
    }
    capture.config.sample_limit = sample_limit;
    capture.samples.max_samples = sample_limit;
    for (0..sample_limit) |i| {
        var sample = records.Sample{ .ip = 0x10000 + (i % 4096) * 0x2000 + 0x10, .ip_present = true, .pid = 4100, .tid = @intCast(4100 + i % threads), .tid_present = true, .time_ns = base_ns + 10 + i * 100_000, .time_present = true, .period = 1_000_000, .period_present = true, .cpu_mode = .user, .callchain = .complete, .frame_count = records.max_frames };
        for (&sample.frames, 0..) |*item, depth| item.* = .{ .context = .user, .address = 0x10000 + ((i + depth) % 4096) * 0x2000 + 0x21 };
        try capture.samples.append(a, sample);
    }
    for (0..threads) |lane| for (0..scheduling.max_events / threads) |i| {
        try capture.switches.add(a, lane, .{ .offset_ns = 1 + i * 6_000_000 + lane, .direction = if (i % 2 == 0) .switch_in else .switch_out, .preempted = i % 6 == 1 });
    };
    var batch: [128]@import("intervals.zig").Input = undefined;
    var labels: [128][16]u8 = undefined;
    for (0..32) |b| {
        for (&batch, &labels, 0..) |*input, *label, j| {
            const k = b * 128 + j;
            input.* = .{ .from_ns = k * 400_000, .to_ns = k * 400_000 + 300_000, .tid = @intCast(4100 + k % threads), .label = std.fmt.bufPrint(label, "frame {d}", .{k}) catch unreachable, .kind = .frame, .correlation_id = k };
        }
        try capture.addIntervals("budget intervals", &batch);
    }
    for (0..timeline.max_markers) |i| capture.addMarker(.{ .offset_ns = i * 1_000_000, .sequence = i + 1, .tid = 4100, .kind = if (i % 2 == 0) .stop else .continued });
    capture.revision = 12345;
    return capture;
}
