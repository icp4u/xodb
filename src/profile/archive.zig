//! Native capture artifact, experimental format 2.5. Adapted from T11's codec.
//! Own original bytes for lossless copying; origin and recorded labels are never
//! reconstructed from runtime session IDs or the set of available asset files.
const std = @import("std");
const c = @import("../c.zig").api;
const capture_model = @import("capture.zig");
const perf = @import("linux_perf.zig");
const records = @import("records.zig");
const mappings = @import("mappings.zig");
const scheduling = @import("scheduling.zig");
const syscalls = @import("syscalls.zig");
const intervals = @import("intervals.zig");
const timeline = @import("timeline.zig");
const activity = @import("activity.zig");
const modules = @import("../model/modules.zig");
const elf = @import("../binary/elf.zig");
const Capture = capture_model.Capture;
const annotations = capture_model.annotations;
const Budget = @import("archive_budget.zig").Budget;
const progress = @import("archive_progress.zig");
const snapshot = @import("../binary/snapshot.zig");
const flame = @import("flame.zig");
const info = @import("../debug/info.zig");
pub const max_memory_bytes = 512 * 1024 * 1024;
pub const analysis_version = "xodb-recorded-flames-v1";
const Allocator = std.mem.Allocator;

pub const magic = "XODBCAPT";
pub const format_major: u16 = 2;
pub const format_minor: u16 = 5;
pub const header_bytes = 64;
pub const entry_bytes = 24;
pub const machine_x86_64: u16 = 62; // EM_X86_64; addresses are that machine's user VAs
pub const clock_monotonic: u32 = 1; // CLOCK_MONOTONIC; comparable only within one boot
/// Independent encoded-input limit; decoded allocations and assets have other caps.
pub const max_file_bytes: usize = 256 * 1024 * 1024;
pub const max_images = 256;
pub const max_path = 4096;
pub const max_text = 512;
pub const max_build_id = 64;
/// Total mapping path bytes. Real captures use well under 1 MiB.
pub const max_path_bytes = 16 * 1024 * 1024;

pub const Error = error{
    ArchiveTooLarge,
    ArchiveCancelled,
    ArchiveFeatureUnsupported,
    ArchiveBadMagic,
    ArchiveVersionUnsupported,
    ArchiveHeaderInvalid,
    ArchiveSectionLayout,
    ArchiveChecksum,
    ArchiveTruncated,
    ArchiveTrailingBytes,
    ArchiveLimit,
    ArchiveInvalidValue,
    ArchiveUnsupportedValue,
    ArchiveInconsistent,
    ArchiveStillCollecting,
};

pub const Tag = enum(u32) {
    syscalls = 0x43535953, // "SYSC", required feature bit 5
    limits = 0x544d494c, // "LIMT", required feature bit 4
    meta = 0x4154454d, // "META"
    threads = 0x44524854, // "THRD"
    images = 0x53474d49, // "IMGS"
    mappings = 0x5350414d, // "MAPS"
    samples = 0x4c504d53, // "SMPL"
    scheduling = 0x44484353, // "SCHD"
    markers = 0x4b52414d, // "MARK"
    intervals = 0x56544e49, // "INTV"
    annotations = 0x4f4e4e41, // "ANNO"
    thread_scope = 0x50435354, // "TSCP", required feature bit 3
    user_state = 0x41545355, // "USTA", required when feature bit 2 is set
};
/// Required sections, in this order. A future minor version may append
/// sections whose table flag marks them ignorable (bit 0).
const section_order = [_]Tag{ .meta, .threads, .images, .mappings, .samples, .scheduling, .markers, .intervals, .annotations };
const flag_ignorable: u32 = 1;

/// Archive code tables. A production enum gaining a tag fails to compile until
/// the table (and the minor version) is extended; a removed tag decodes as
/// ArchiveUnsupportedValue rather than a different meaning.
fn Codes(comptime E: type, comptime names: []const []const u8) type {
    comptime {
        for (@typeInfo(E).@"enum".fields) |field| {
            for (names) |name| {
                if (std.mem.eql(u8, name, field.name)) break;
            } else @compileError("archive code table lacks " ++ @typeName(E) ++ "." ++ field.name);
        }
    }
    return struct {
        fn encode(value: E) u8 {
            inline for (names, 0..) |name, i| if (std.mem.eql(u8, name, @tagName(value))) return i;
            unreachable;
        }
        fn decode(code: u8) Error!E {
            if (code >= names.len) return error.ArchiveInvalidValue;
            inline for (names, 0..) |name, i| if (i == code) return std.meta.stringToEnum(E, name) orelse error.ArchiveUnsupportedValue;
            unreachable;
        }
    };
}
const StopCode = Codes(capture_model.Stop, &.{ "collecting", "manual", "duration", "capacity", "mapping_limit", "mappings_changed", "metadata_lost", "thread_scope_changed", "decode_error", "target_ended", "image_changed", "drain_limit", "collector_error", "scheduling_limit", "scheduling_error", "syscall_limit", "syscall_error" });
const EventCode = Codes(perf.EventKind, &.{ "task_clock", "cpu_clock", "cpu_cycles" });
const FailureCode = Codes(perf.FailureKind, &.{ "unavailable", "permission", "configuration", "thread_gone", "resource", "other" });
const ReasonCode = Codes(mappings.Reason, &.{ "elf", "anonymous", "image_unavailable", "image_limit", "non_executable", "unsupported_record", "truncated_path" });
const ModeCode = Codes(records.CpuMode, &.{ "unknown", "kernel", "user", "hypervisor", "guest_kernel", "guest_user", "other" });
const ContextCode = Codes(records.Context, &.{ "unknown", "kernel", "user", "hypervisor", "guest", "guest_kernel", "guest_user", "user_deferred", "other" });
const ChainCode = Codes(records.Callchain, &.{ "absent", "complete", "truncated" });
const KindCode = Codes(intervals.Kind, &.{ "frame", "request", "custom" });
const MarkerCode = Codes(timeline.MarkerKind, &.{ "capture_open_stopped", "continued", "stop", "step_started", "step_complete", "breakpoint_hit", "watchpoint_hit", "exit", "detach" });

/// Facts about the saving process, not the capture. Pass fixed values for
/// deterministic output.
pub const Environment = struct {
    writer_boot_id: ?[36]u8 = null,
    progress: ?*progress.Progress = null,
    saved_realtime_ns: ?u64 = null,
    encoder: []const u8 = "xodb archive 2.2",
};
/// Identity of one ELF file as it was mapped during capture.
pub const ImageIdentity = struct { file_bytes: u64, sha256: [32]u8, build_id: ?[]const u8 };

// ---------------------------------------------------------------- encoding

const Writer = struct {
    a: Allocator,
    out: *std.ArrayList(u8),
    fn int(self: Writer, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.out.appendSlice(self.a, &buffer);
    }
    fn flag(self: Writer, value: bool) !void {
        try self.out.append(self.a, @intFromBool(value));
    }
    fn code(self: Writer, value: u8) !void {
        try self.out.append(self.a, value);
    }
    fn opt(self: Writer, comptime T: type, value: ?T) !void {
        try self.flag(value != null);
        if (value) |v| try self.int(T, v);
    }
    fn text(self: Writer, value: []const u8, max: usize) !void {
        if (value.len > max) return error.ArchiveLimit;
        try self.int(u32, @intCast(value.len));
        try self.out.appendSlice(self.a, value);
    }
    fn count(self: Writer, n: usize) !void {
        try self.int(u32, std.math.cast(u32, n) orelse return error.ArchiveLimit);
    }
};

/// Encodes a completed capture. Image identities are hashed from the mapped
/// ELF bytes the capture already holds; the result is deterministic for a
/// given capture and environment.
pub fn encode(a: Allocator, capture: *const Capture, env: Environment) ![]u8 {
    if (capture.offline) return error.ArchiveUseOriginalBytes;
    var budget = Budget{ .backing = a, .limit = max_memory_bytes };
    const bytes = encodeInner(budget.allocator(), capture, env) catch |err| return if (budget.denied) error.ArchiveMemoryLimit else err;
    defer budget.allocator().free(bytes);
    if (budget.denied) return error.ArchiveMemoryLimit;
    return a.dupe(u8, bytes);
}
fn encodeInner(a: Allocator, capture: *const Capture, env: Environment) ![]u8 {
    if (capture.collector != null) return error.ArchiveStillCollecting;
    try validateSyscalls(capture);
    const sampled = capture.config.user_stack_bytes != 0;
    const custom_limit = capture.config.sample_limit != capture_model.max_samples;
    if (capture.config.sample_limit == 0 or capture.config.sample_limit > capture_model.max_sample_limit) return error.ArchiveLimit;
    try validateUserState(capture);
    try validateThreadScope(capture);
    var selected_storage: [section_order.len + 4]Tag = undefined;
    @memcpy(selected_storage[0..section_order.len], &section_order);
    var selected_count: usize = section_order.len;
    if (sampled) {
        selected_storage[selected_count] = .user_state;
        selected_count += 1;
    }
    selected_storage[selected_count] = .thread_scope;
    selected_count += 1;
    if (custom_limit) {
        selected_storage[selected_count] = .limits;
        selected_count += 1;
    }
    if (capture.syscalls.enabled) {
        selected_storage[selected_count] = .syscalls;
        selected_count += 1;
    }
    const selected = selected_storage[0..selected_count];
    if (capture.thread_count > perf.max_threads or capture.samples.len() > capture.config.sample_limit or capture.images.loaded.items.len > max_images) return error.ArchiveLimit;
    // Lanes beyond the recorded threads are never written by the collector.
    for (capture.switches.lanes[capture.thread_count..]) |lane| if (lane.events.items.len != 0 or lane.cutoff_ns != null or lane.contradictory) return error.ArchiveInconsistent;
    var bodies: [section_order.len + 4]std.ArrayList(u8) = @splat(.empty);
    defer for (&bodies) |*body| body.deinit(a);
    for (selected, bodies[0..selected.len], 0..) |tag, *body, section_index| {
        try progress.step(env.progress, .encoding, section_index);
        const w = Writer{ .a = a, .out = body };
        switch (tag) {
            .limits => try w.int(u32, capture.config.sample_limit),
            .meta => try encodeMeta(w, capture, env),
            .threads => try encodeThreads(w, capture),
            .thread_scope => try encodeThreadScope(w, capture),
            .images => try encodeImages(w, capture),
            .mappings => try encodeMappings(w, capture),
            .samples => try encodeSamples(w, capture),
            .scheduling => try encodeScheduling(w, capture),
            .syscalls => try encodeSyscalls(w, capture),
            .markers => try encodeMarkers(w, capture),
            .intervals => try encodeIntervals(w, capture),
            .annotations => try encodeAnnotations(w, capture, env.progress),
            .user_state => try encodeUserState(w, capture, env.progress),
        }
    }
    var total: usize = header_bytes + entry_bytes * selected.len;
    for (bodies) |body| total += body.items.len;
    if (total > max_file_bytes) return error.ArchiveTooLarge;
    const out = try a.alloc(u8, total);
    errdefer a.free(out);
    @memset(out[0..header_bytes], 0);
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u16, out[8..10], format_major, .little);
    std.mem.writeInt(u16, out[10..12], if (capture.syscalls.enabled) format_minor else if (custom_limit) 4 else 3, .little);
    std.mem.writeInt(u32, out[12..16], header_bytes, .little);
    std.mem.writeInt(u64, out[16..24], total, .little);
    std.mem.writeInt(u32, out[24..28], @intCast(selected.len), .little);
    out[32] = 1; // little-endian
    out[33] = 64; // address bits
    std.mem.writeInt(u16, out[34..36], machine_x86_64, .little);
    std.mem.writeInt(u32, out[36..40], clock_monotonic, .little);
    std.mem.writeInt(u64, out[40..48], (@as(u64, if (capture.config.duration_ms == 0 or capture.config.duration_ms > 60000) 3 else 1) | @as(u64, if (sampled) 4 else 0) | 8 | @as(u64, if (custom_limit) 16 else 0) | @as(u64, if (capture.syscalls.enabled) 32 else 0)), .little); // annotations, duration, sampled state, thread scope
    std.mem.writeInt(u32, out[56..60], std.hash.Crc32.hash(out[0..56]), .little);
    var offset: usize = header_bytes + entry_bytes * selected.len;
    for (selected, bodies[0..selected.len], 0..) |tag, body, i| {
        const entry = out[header_bytes + i * entry_bytes ..][0..entry_bytes];
        std.mem.writeInt(u32, entry[0..4], @intFromEnum(tag), .little);
        std.mem.writeInt(u32, entry[4..8], 0, .little);
        std.mem.writeInt(u64, entry[8..16], offset, .little);
        std.mem.writeInt(u32, entry[16..20], @intCast(body.items.len), .little);
        std.mem.writeInt(u32, entry[20..24], std.hash.Crc32.hash(body.items), .little);
        @memcpy(out[offset..][0..body.items.len], body.items);
        offset += body.items.len;
    }
    return out;
}
fn encodeMeta(w: Writer, capture: *const Capture, env: Environment) !void {
    // Live-session identities are provenance only; reopening never reuses them.
    try w.int(u64, capture.id);
    try w.int(u64, capture.session_id);
    try w.int(u64, capture.generation);
    try w.int(u64, capture.image_epoch);
    try w.int(i32, capture.pid);
    try w.int(u64, capture.started_ns);
    try w.opt(u64, capture.ended_ns);
    try w.int(u64, capture.observed_until_ns);
    try w.int(u64, capture.revision);
    try w.int(u64, capture.mapping_revision);
    try w.code(StopCode.encode(capture.status));
    try w.text(capture.diagnostic, max_text);
    try w.int(u32, capture.config.frequency_hz);
    try w.int(u32, capture.config.duration_ms);
    try w.flag(capture.config.context_switch);
    const accepted = capture.accepted;
    try w.code(EventCode.encode(accepted.event));
    try w.int(u32, accepted.requested_frequency_hz);
    try w.int(u32, accepted.kernel_max_sample_rate);
    try w.int(u32, accepted.kernel_max_stack);
    for ([_]bool{ accepted.exclude_kernel, accepted.mmap_data, accepted.callchain, accepted.include_weight, accepted.context_switch }) |value| try w.flag(value);
    try w.int(u64, accepted.sample_type);
    try w.int(u16, accepted.sample_max_stack);
    try w.int(i32, accepted.clockid);
    try w.int(u64, accepted.ring_data_bytes);
    try w.int(u64, accepted.data_offset);
    try w.int(u32, accepted.mmap_version);
    try w.int(u16, accepted.threads);
    try w.flag(capture.failure != null);
    if (capture.failure) |failure| {
        try w.code(FailureCode.encode(failure.kind));
        try w.text(failure.syscall, max_text);
        try w.int(i32, failure.errno);
        try w.int(i32, failure.tid);
        try w.int(u16, failure.opened_then_closed);
        try w.text(failure.detail, max_text);
    }
    for ([_]u64{ capture.lost_records, capture.lost_samples, capture.throttles, capture.unthrottles, capture.mapping_events, capture.exec_events, capture.exit_events, capture.fork_events, capture.unknown_records, capture.discarded_samples, capture.missing_images, capture.unselected_threads }) |value| try w.int(u64, value);
    try w.flag(capture.scope_change != null);
    if (capture.scope_change) |change| {
        for ([_]u32{ change.pid, change.tid, change.parent_pid, change.parent_tid }) |value| try w.int(u32, value);
        try w.opt(u64, change.time_ns);
    }
    try w.opt(u64, if (capture.trusted_before_ns == std.math.maxInt(u64)) null else capture.trusted_before_ns);
    try w.flag(capture.cpu_activity != null);
    if (capture.cpu_activity) |cpu| {
        try w.opt(u64, cpu.user_ms);
        try w.opt(u64, cpu.kernel_ms);
        try w.int(u16, cpu.available_threads);
        try w.int(u16, cpu.unavailable_threads);
        try w.int(u64, cpu.ticks_per_second);
        try w.flag(cpu.complete);
    }
    try w.int(u64, capture.debugger_marker_dropped);
    try w.int(u64, capture.debugger_events_lost);
    try w.int(u64, capture.debugger_sequence);
    // Every exceptional stop condition, in observation order.
    const reasons = stopReasons(capture);
    try w.count(reasons.len);
    for (reasons) |reason| try w.code(StopCode.encode(reason));
    try w.flag(capture.boot_id != null);
    if (capture.boot_id) |id| try w.out.appendSlice(w.a, &id);
    try w.flag(env.writer_boot_id != null);
    if (env.writer_boot_id) |id| try w.out.appendSlice(w.a, &id);
    try w.opt(u64, env.saved_realtime_ns);
    try w.text(env.encoder, max_text);
}
fn stopReasons(capture: *const Capture) []const capture_model.Stop {
    return capture.stop_reasons[0..capture.stop_reason_count];
}
fn encodeThreads(w: Writer, capture: *const Capture) !void {
    try w.count(capture.thread_count);
    for (capture.threads[0..capture.thread_count], capture.thread_names[0..capture.thread_count], capture.cpu_before[0..capture.thread_count]) |thread, *name, before| {
        try w.int(u64, thread.debugger_id);
        try w.int(i32, thread.perf.tid);
        try w.int(u64, thread.perf.event_id);
        try w.int(u64, thread.perf.start_time_ticks);
        try w.flag(thread.perf.start_time_known);
        try w.text(std.mem.sliceTo(name, 0), name.len - 1);
        try w.flag(before != null);
        if (before) |ticks| for ([_]u64{ ticks.start_time, ticks.user, ticks.kernel }) |value| try w.int(u64, value);
    }
}
/// The identity recorded for a mapped ELF: size, SHA-256 and GNU build ID.
pub fn identify(bytes: []const u8) ImageIdentity {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .file_bytes = bytes.len, .sha256 = digest, .build_id = buildId(bytes) };
}
fn buildId(bytes: []const u8) ?[]const u8 {
    const image = elf.Image.parse(bytes) catch return null;
    const section = image.sectionByName(".note.gnu.build-id") orelse return null;
    const note = image.sectionData(section) catch return null;
    if (note.len < 16) return null;
    const name_size = std.mem.readInt(u32, note[0..4], .little);
    const desc_size = std.mem.readInt(u32, note[4..8], .little);
    const kind = std.mem.readInt(u32, note[8..12], .little);
    const desc_at = 12 + std.mem.alignForward(usize, name_size, 4);
    if (kind != 3 or name_size != 4 or !std.mem.eql(u8, note[12..16], "GNU\x00") or desc_size == 0 or desc_size > max_build_id or desc_at + desc_size > note.len) return null;
    return note[desc_at..][0..desc_size];
}
fn encodeImages(w: Writer, capture: *const Capture) !void {
    try w.count(capture.images.loaded.items.len);
    for (capture.images.loaded.items) |image| {
        if (!image.immutable) return error.ArchiveMutableImage;
        if (@intFromEnum(image.image.header.machine) != machine_x86_64) return error.ArchiveUnsupportedArchitecture;
        const identity = identify(image.mapping);
        try w.int(u64, image.id);
        try w.text(image.path, max_path);
        for ([_]u64{ image.device_major, image.device_minor, image.inode, image.bias, image.start, image.end, identity.file_bytes }) |value| try w.int(u64, value);
        try w.out.appendSlice(w.a, &identity.sha256);
        try w.flag(identity.build_id != null);
        if (identity.build_id) |id| try w.text(id, max_build_id);
    }
}
fn encodeMappings(w: Writer, capture: *const Capture) !void {
    const history = &capture.history;
    try w.count(history.opening_count);
    try w.count(history.changes.items.len);
    if (history.entries.items.len != history.opening_count + history.changes.items.len) return error.ArchiveInconsistent;
    for (history.entries.items) |entry| {
        for ([_]u64{ entry.start, entry.end, entry.offset, entry.image_id, entry.device_major, entry.device_minor, entry.inode }) |value| try w.int(u64, value);
        try w.flag(entry.executable);
        try w.code(ReasonCode.encode(entry.reason));
        try w.text(entry.path, max_path);
    }
    for (history.changes.items) |change| {
        try w.int(u64, change.time_ns);
        try w.int(u32, change.id);
    }
}
fn encodeSamples(w: Writer, capture: *const Capture) !void {
    try w.count(capture.samples.len());
    for (0..capture.samples.len()) |ordinal| {
        const sample = capture.samples.get(ordinal);
        const flags: u8 = @as(u8, @intFromBool(sample.ip_present)) | @as(u8, @intFromBool(sample.ip_exact)) << 1 | @as(u8, @intFromBool(sample.tid_present)) << 2 | @as(u8, @intFromBool(sample.time_present)) << 3 | @as(u8, @intFromBool(sample.period_present)) << 4 | @as(u8, @intFromBool(sample.weight_present)) << 5;
        try w.code(flags);
        if (sample.ip_present) try w.int(u64, sample.ip);
        try w.int(u32, sample.pid);
        if (sample.tid_present) try w.int(u32, sample.tid);
        if (sample.time_present) try w.int(u64, sample.time_ns);
        if (sample.period_present) try w.int(u64, sample.period);
        if (sample.weight_present) try w.int(u64, sample.weight);
        try w.code(ModeCode.encode(sample.cpu_mode));
        try w.code(ChainCode.encode(sample.callchain));
        try w.int(u16, sample.frame_count);
        for (sample.frames[0..sample.frame_count]) |item| {
            // Bit 7: marker. Low bits: context code. Markers carry their raw
            // ABI value; addresses carry the address.
            try w.code(@as(u8, @intFromBool(item.marker)) << 7 | ContextCode.encode(item.context));
            try w.int(u64, if (item.marker) item.raw_marker else item.address);
        }
    }
}
fn encodeScheduling(w: Writer, capture: *const Capture) !void {
    const store = &capture.switches;
    try w.int(u64, store.retained);
    try w.int(u64, store.discarded);
    try w.int(u64, store.invalid);
    try w.int(u64, store.extent_ns);
    try w.count(capture.thread_count);
    for (store.lanes[0..capture.thread_count]) |lane| {
        try w.count(lane.events.items.len);
        try w.opt(u64, lane.cutoff_ns);
        try w.flag(lane.contradictory);
        for (lane.events.items) |event| {
            try w.int(u64, event.offset_ns);
            try w.code(@as(u8, @intFromBool(event.direction == .switch_out)) | @as(u8, @intFromBool(event.preempted)) << 1);
        }
    }
}
fn encodeMarkers(w: Writer, capture: *const Capture) !void {
    try w.count(capture.debugger_markers.items.len);
    for (capture.debugger_markers.items) |marker| {
        try w.int(u64, marker.offset_ns);
        try w.int(u64, marker.sequence);
        try w.int(i32, marker.tid);
        try w.code(MarkerCode.encode(marker.kind));
    }
}
fn encodeIntervals(w: Writer, capture: *const Capture) !void {
    try w.count(capture.application_intervals.items.items.len);
    for (capture.application_intervals.items.items) |*item| {
        try w.int(u32, item.id);
        try w.int(u64, item.from_ns);
        try w.int(u64, item.to_ns);
        try w.opt(u32, item.tid);
        try w.code(KindCode.encode(item.kind));
        try w.opt(u64, item.correlation_id);
        try w.text(item.label(), intervals.text_limit);
        try w.text(item.source(), intervals.text_limit);
    }
}

// ---------------------------------------------------------------- decoding

const Reader = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    bytes: []const u8,
    pos: usize = 0,
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.cancel) |cancelled| if (cancelled.load(.acquire)) return error.ArchiveCancelled;
        if (n > self.bytes.len - self.pos) return error.ArchiveTruncated;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
    fn int(self: *Reader, comptime T: type) Error!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
    fn flag(self: *Reader) Error!bool {
        return switch ((try self.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.ArchiveInvalidValue,
        };
    }
    fn code(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    fn opt(self: *Reader, comptime T: type) Error!?T {
        return if (try self.flag()) try self.int(T) else null;
    }
    fn text(self: *Reader, max: usize) Error![]const u8 {
        const n = try self.int(u32);
        if (n > max) return error.ArchiveLimit;
        return self.take(n);
    }
    /// A record count, checked against its limit and against the bytes left
    /// (each record needs at least `min_bytes`) before anything is allocated.
    fn count(self: *Reader, max: usize, min_bytes: usize) Error!usize {
        const n = try self.int(u32);
        if (n > max) return error.ArchiveLimit;
        if (n * min_bytes > self.bytes.len - self.pos) return error.ArchiveTruncated;
        return n;
    }
    fn end(self: *const Reader) Error!void {
        if (self.pos != self.bytes.len) return error.ArchiveTrailingBytes;
    }
};

pub const ImageStatus = enum { verified, not_requested, missing, size_mismatch, content_mismatch, unreadable, invalid_elf, limit };
/// Capture-time placement of an image: device/inode as observed, load bias and range.
pub const Placement = struct { device_major: u64, device_minor: u64, inode: u64, bias: u64, start: u64, end: u64 };
pub const ImageReport = struct { id: u64, path: []const u8, opened_path: []const u8, status: ImageStatus, identity: ImageIdentity, placement: Placement };
/// Explicit asset loading only. A symbol directory holds SHA-256-named files;
/// without a root, an explicitly enabled resolver tries the recorded path.
pub const Resolver = struct {
    root: ?[]const u8 = null,
    enabled: bool = false,
    fn candidate(self: Resolver, buffer: []u8, report: ImageReport) ?[:0]const u8 {
        if (!self.enabled) return null;
        if (self.root) |root| return std.fmt.bufPrintZ(buffer, "{s}/{s}", .{ root, std.fmt.bytesToHex(report.identity.sha256, .lower) }) catch null;
        return std.fmt.bufPrintZ(buffer, "{s}", .{report.path}) catch null;
    }
};
pub const Options = struct {
    /// Session-local ID for the reopened capture; never the recorded live ID.
    local_id: u64,
    resolver: Resolver = .{},
    max_file_bytes: usize = max_file_bytes,
    max_memory_bytes: usize = max_memory_bytes,
    reanalyze: bool = false,
    progress: ?*progress.Progress = null,
};
/// Offline provenance kept beside the reopened capture.
pub const Source = struct {
    format_major: u16,
    format_minor: u16,
    archive_sha256: [32]u8,
    file_bytes: usize,
    capture_id: u64,
    session_id: u64,
    generation: u64,
    image_epoch: u64,
    pid: i32,
    revision: u64,
    boot_id: ?[36]u8,
    writer_boot_id: ?[36]u8 = null,
    annotation_basis: []const u8 = annotations.basis,
    annotation_resolver: []const u8 = annotations.resolver,
    annotation_count: usize = 0,
    stack_registers: []const u8 = "not_recorded",
    reconstructed_callers: []const u8 = "not_recorded",
    optional_features: u64 = 0,
    saved_realtime_ns: ?u64,
    encoder: []const u8,
    images: []ImageReport,
    ignored_sections: usize,
};
pub const Opened = struct {
    capture: *Capture,
    source: Source,
    bytes: []const u8,
    budget: *Budget,
    resolution_id: [32]u8,
    /// Owns `source` strings and reports. The capture owns its own memory.
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *Opened) void {
        self.capture.deinit();
        self.arena.deinit();
        self.budget.allocator().free(self.bytes);
        const backing = self.budget.backing;
        std.debug.assert(self.budget.used == 0);
        backing.destroy(self.budget);
    }
    pub fn viewId(self: *const Opened, filter: capture_model.Filter) [64]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(&self.source.archive_sha256);
        hash.update(&self.resolution_id);
        hash.update(analysis_version);
        var fields: [20]u8 = undefined;
        std.mem.writeInt(u32, fields[0..4], filter.tid orelse 0, .little);
        std.mem.writeInt(u64, fields[4..12], filter.from_ns, .little);
        std.mem.writeInt(u64, fields[12..20], filter.to_ns, .little);
        hash.update(&fields);
        filter.tids.hashInto(&hash);
        return std.fmt.bytesToHex(hash.finalResult(), .lower);
    }
};

const Header = struct { syscalls: ?[]const u8 = null, limits: ?[]const u8 = null, thread_scope: ?[]const u8 = null, user_state: ?[]const u8 = null, minor: u16, sections: [section_order.len][]const u8, ignored: usize, required_features: u64, optional_features: u64 };
fn readHeader(bytes: []const u8, limit: usize) Error!Header {
    if (bytes.len > limit) return error.ArchiveTooLarge;
    if (bytes.len < header_bytes) return error.ArchiveTruncated;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.ArchiveBadMagic;
    if (std.mem.readInt(u32, bytes[56..60], .little) != std.hash.Crc32.hash(bytes[0..56])) return error.ArchiveChecksum;
    const major = std.mem.readInt(u16, bytes[8..10], .little);
    const minor = std.mem.readInt(u16, bytes[10..12], .little);
    if (major != format_major) return error.ArchiveVersionUnsupported;
    if (std.mem.readInt(u32, bytes[12..16], .little) != header_bytes or bytes[32] != 1 or bytes[33] != 64 or std.mem.readInt(u16, bytes[34..36], .little) != machine_x86_64 or std.mem.readInt(u32, bytes[36..40], .little) != clock_monotonic or std.mem.readInt(u32, bytes[28..32], .little) != 0) return error.ArchiveHeaderInvalid;
    const required_features = std.mem.readInt(u64, bytes[40..48], .little);
    if (required_features & ~@as(u64, 63) != 0) return error.ArchiveFeatureUnsupported;
    if (required_features & 1 == 0) return error.ArchiveHeaderInvalid;
    for (bytes[60..64]) |b| if (b != 0) return error.ArchiveHeaderInvalid;
    const file_bytes = std.mem.readInt(u64, bytes[16..24], .little);
    if (file_bytes != bytes.len) return if (file_bytes > bytes.len) error.ArchiveTruncated else error.ArchiveTrailingBytes;
    const count = std.mem.readInt(u32, bytes[24..28], .little);
    if (count < section_order.len or count > 64) return error.ArchiveSectionLayout;
    const table_end = header_bytes + @as(usize, count) * entry_bytes;
    if (table_end > bytes.len) return error.ArchiveTruncated;
    var result = Header{ .minor = minor, .sections = undefined, .ignored = 0, .required_features = required_features, .optional_features = std.mem.readInt(u64, bytes[48..56], .little) };
    var next = table_end;
    var required: usize = 0;
    for (0..count) |i| {
        const entry = bytes[header_bytes + i * entry_bytes ..][0..entry_bytes];
        const tag = std.mem.readInt(u32, entry[0..4], .little);
        const flags = std.mem.readInt(u32, entry[4..8], .little);
        const offset = std.mem.readInt(u64, entry[8..16], .little);
        const length = std.mem.readInt(u32, entry[16..20], .little);
        // Contiguous sections in table order: no gaps, overlap or slack.
        if (offset != next or length > bytes.len - next) return error.ArchiveSectionLayout;
        const body = bytes[next..][0..length];
        next += length;
        if (std.mem.readInt(u32, entry[20..24], .little) != std.hash.Crc32.hash(body)) return error.ArchiveChecksum;
        if (required < section_order.len and tag == @intFromEnum(section_order[required])) {
            if (flags != 0) return error.ArchiveSectionLayout;
            result.sections[required] = body;
            required += 1;
        } else if (tag == @intFromEnum(Tag.syscalls)) {
            if (flags != 0 or required != section_order.len or result.syscalls != null or required_features & 32 == 0 or minor < 5) return error.ArchiveSectionLayout;
            result.syscalls = body;
        } else if (tag == @intFromEnum(Tag.user_state)) {
            if (flags != 0 or required != section_order.len or result.user_state != null or required_features & 4 == 0 or minor < 2) return error.ArchiveSectionLayout;
            result.user_state = body;
        } else if (tag == @intFromEnum(Tag.limits)) {
            if (flags != 0 or required != section_order.len or result.limits != null or required_features & 16 == 0 or minor < 4) return error.ArchiveSectionLayout;
            result.limits = body;
        } else if (tag == @intFromEnum(Tag.thread_scope)) {
            if (flags != 0 or required != section_order.len or result.thread_scope != null or required_features & 8 == 0 or minor < 3) return error.ArchiveSectionLayout;
            result.thread_scope = body;
        } else if (flags == flag_ignorable) {
            for (section_order) |known| if (tag == @intFromEnum(known)) return error.ArchiveSectionLayout;
            result.ignored += 1;
        } else return error.ArchiveSectionLayout;
    }
    if ((required_features & 32 != 0) != (result.syscalls != null)) return error.ArchiveSectionLayout;
    if ((required_features & 16 != 0) != (result.limits != null)) return error.ArchiveSectionLayout;
    if ((required_features & 8 != 0) != (result.thread_scope != null)) return error.ArchiveSectionLayout;
    if ((required_features & 4 != 0) != (result.user_state != null)) return error.ArchiveSectionLayout;
    if (required != section_order.len) return error.ArchiveSectionLayout;
    if (next != bytes.len) return error.ArchiveTrailingBytes;
    return result;
}

/// Decodes and validates an archive into a new, completed, offline capture.
/// All allocation is bounded by the validated counts (see `Error.ArchiveLimit`).
pub fn decode(a: Allocator, bytes: []const u8, options: Options) !Opened {
    const budget = try a.create(Budget);
    budget.* = .{ .backing = a, .limit = @min(options.max_memory_bytes, max_memory_bytes) };
    errdefer a.destroy(budget);
    return decodeInner(budget, bytes, options) catch |err| return if (budget.denied) error.ArchiveMemoryLimit else err;
}
fn decodeInner(budget: *Budget, bytes: []const u8, options: Options) !Opened {
    const a = budget.allocator();
    try progress.step(options.progress, .decoding, 0);
    const header = try readHeader(bytes, @min(options.max_file_bytes, max_file_bytes));
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const self = try a.create(Capture);
    // Fields are filled section by section; deinit is valid at every point.
    self.* = .{ .allocator = a, .arena = std.heap.ArenaAllocator.init(a), .id = options.local_id, .session_id = 0, .generation = std.math.maxInt(u64), .image_epoch = std.math.maxInt(u64), .pid = 0, .started_ns = 0, .config = .{}, .accepted = undefined, .thread_count = 0, .collector = null, .images = modules.Modules.init(a) };
    errdefer self.deinit();
    self.offline = true;
    var source = Source{ .format_major = format_major, .format_minor = header.minor, .archive_sha256 = undefined, .file_bytes = bytes.len, .capture_id = 0, .session_id = 0, .generation = 0, .image_epoch = 0, .pid = 0, .revision = 0, .boot_id = null, .saved_realtime_ns = null, .encoder = "", .images = &.{}, .ignored_sections = header.ignored, .optional_features = header.optional_features };
    std.crypto.hash.sha2.Sha256.hash(bytes, &source.archive_sha256, .{});
    var r = Reader{ .bytes = header.sections[0], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeMeta(&r, self, &source, arena.allocator());
    if (header.limits) |body| {
        var limit_reader = Reader{ .bytes = body };
        const sample_limit = try limit_reader.int(u32);
        try limit_reader.end();
        if (sample_limit == 0 or sample_limit > capture_model.max_sample_limit) return error.ArchiveLimit;
        self.config.sample_limit = sample_limit;
        self.samples.max_samples = sample_limit;
    }
    if ((self.config.duration_ms == 0 or self.config.duration_ms > 60000) and header.required_features & 2 == 0) return error.ArchiveFeatureUnsupported;
    r = .{ .bytes = header.sections[1], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeThreads(&r, self);
    if (header.thread_scope) |body| {
        r = .{ .bytes = body, .cancel = if (options.progress) |p| &p.cancel else null };
        try decodeThreadScope(&r, self);
    }
    r = .{ .bytes = header.sections[2], .cancel = if (options.progress) |p| &p.cancel else null };
    const reports = try decodeImages(&r, arena.allocator());
    r = .{ .bytes = header.sections[3], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeMappings(&r, self, reports);
    r = .{ .bytes = header.sections[4], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeSamples(&r, self);
    r = .{ .bytes = header.sections[5], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeScheduling(&r, self);
    r = .{ .bytes = header.sections[6], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeMarkers(&r, self);
    r = .{ .bytes = header.sections[7], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeIntervals(&r, self);
    r = .{ .bytes = header.sections[8], .cancel = if (options.progress) |p| &p.cancel else null };
    try decodeAnnotations(&r, self, reports);
    if (header.user_state) |body| {
        r = .{ .bytes = body, .cancel = if (options.progress) |p| &p.cancel else null };
        try decodeUserState(&r, self);
        source.stack_registers = "perf_user_state_v1";
    }
    if (header.syscalls) |body| {
        r = .{ .bytes = body, .cancel = if (options.progress) |p| &p.cancel else null };
        try decodeSyscalls(&r, self);
    }
    try validateSyscalls(self);
    try validateUserState(self);
    source.annotation_count = self.recorded.count();
    self.boot_id = source.boot_id;
    // Optional assets enrich assembly only. They never replace recorded labels.
    for (reports, 0..) |*report, i| {
        try progress.step(options.progress, .assets, i);
        try loadImage(self, report, options.resolver, arena.allocator(), options.progress);
    }
    source.images = reports;
    var reanalysis_digest: ?[32]u8 = null;
    if (options.reanalyze) {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try encodeAnnotations(.{ .a = a, .out = &body }, self, options.progress);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(body.items, &digest, .{});
        reanalysis_digest = digest;
        self.recorded.deinit(a);
        self.recorded = .empty;
        var resolved_reader = Reader{ .bytes = body.items, .cancel = if (options.progress) |p| &p.cancel else null };
        try decodeAnnotations(&resolved_reader, self, reports);
        self.reanalyzed = true;
    }
    var resolution = std.crypto.hash.sha2.Sha256.init(.{});
    resolution.update(annotations.resolver);
    resolution.update(if (options.reanalyze) "verified-assets-reanalysis" else "recorded-annotations");
    if (reanalysis_digest) |digest| resolution.update(&digest);
    for (reports) |report| {
        resolution.update(&report.identity.sha256);
        resolution.update(@tagName(report.status));
    }
    try progress.step(options.progress, .annotations, source.annotation_count);
    self.work_cancel = if (options.progress) |p| &p.cancel else null;
    self.offline_graph = try self.graphDirect(a, .{});
    self.work_cancel = null;
    // Large immutable evidence gets an exact allocation, avoiding arena growth slack.
    const retained = try a.dupe(u8, bytes);
    return .{ .capture = self, .source = source, .arena = arena, .bytes = retained, .budget = budget, .resolution_id = resolution.finalResult() };
}
fn decodeMeta(r: *Reader, self: *Capture, source: *Source, a: Allocator) !void {
    source.capture_id = try r.int(u64);
    source.session_id = try r.int(u64);
    source.generation = try r.int(u64);
    source.image_epoch = try r.int(u64);
    source.pid = try r.int(i32);
    self.started_ns = try r.int(u64);
    self.ended_ns = try r.opt(u64);
    // Reopening needs a completed capture: an archive never resumes collection.
    if (self.ended_ns == null or self.ended_ns.? < self.started_ns) return error.ArchiveInconsistent;
    self.observed_until_ns = try r.int(u64);
    source.revision = try r.int(u64);
    self.revision = source.revision;
    self.mapping_revision = try r.int(u64);
    self.status = try StopCode.decode(try r.code());
    if (self.status == .collecting) return error.ArchiveInconsistent;
    self.diagnostic = try self.arena.allocator().dupe(u8, try r.text(max_text));
    self.config = .{ .follow_threads = false, .ring_budget_bytes = 0, .frequency_hz = try r.int(u32), .duration_ms = try r.int(u32), .context_switch = try r.flag(), .user_stack_budget_bytes = 0 };
    var accepted: perf.Acceptance = undefined;
    accepted.user_regs_mask = 0;
    accepted.user_stack_bytes = 0;
    accepted.event = try EventCode.decode(try r.code());
    accepted.requested_frequency_hz = try r.int(u32);
    accepted.kernel_max_sample_rate = try r.int(u32);
    accepted.kernel_max_stack = try r.int(u32);
    accepted.exclude_kernel = try r.flag();
    accepted.mmap_data = try r.flag();
    accepted.callchain = try r.flag();
    accepted.include_weight = try r.flag();
    accepted.context_switch = try r.flag();
    accepted.sample_type = try r.int(u64);
    accepted.sample_max_stack = try r.int(u16);
    accepted.clockid = try r.int(i32);
    if (accepted.clockid != clock_monotonic) return error.ArchiveUnsupportedValue;
    accepted.ring_data_bytes = try r.int(u64);
    accepted.data_offset = try r.int(u64);
    accepted.mmap_version = try r.int(u32);
    accepted.threads = try r.int(u16);
    self.accepted = accepted;
    if (try r.flag()) {
        const kind = try FailureCode.decode(try r.code());
        const syscall = try self.arena.allocator().dupe(u8, try r.text(max_text));
        const errno = try r.int(i32);
        const tid = try r.int(i32);
        const opened = try r.int(u16);
        self.failure = .{ .kind = kind, .syscall = syscall, .errno = errno, .tid = tid, .opened_then_closed = opened, .detail = try self.arena.allocator().dupe(u8, try r.text(max_text)) };
    }
    inline for (.{ "lost_records", "lost_samples", "throttles", "unthrottles", "mapping_events", "exec_events", "exit_events", "fork_events", "unknown_records", "discarded_samples", "missing_images" }) |field| @field(self, field) = try r.int(u64);
    self.unselected_threads = std.math.cast(usize, try r.int(u64)) orelse return error.ArchiveInvalidValue;
    if (try r.flag()) self.scope_change = .{ .pid = try r.int(u32), .tid = try r.int(u32), .parent_pid = try r.int(u32), .parent_tid = try r.int(u32), .time_ns = try r.opt(u64) };
    // Absent means trusted throughout; a stored maxInt would be ambiguous.
    if (try r.opt(u64)) |trusted| {
        if (trusted == std.math.maxInt(u64)) return error.ArchiveInvalidValue;
        self.trusted_before_ns = trusted;
    }
    if (try r.flag()) self.cpu_activity = .{ .user_ms = try r.opt(u64), .kernel_ms = try r.opt(u64), .available_threads = try r.int(u16), .unavailable_threads = try r.int(u16), .ticks_per_second = try r.int(u64), .complete = try r.flag() };
    self.debugger_marker_dropped = try r.int(u64);
    self.debugger_events_lost = try r.int(u64);
    self.debugger_sequence = try r.int(u64);
    const reasons = try r.count(@typeInfo(capture_model.Stop).@"enum".fields.len, 1);
    for (0..reasons) |i| {
        const reason = try StopCode.decode(try r.code());
        if (std.mem.indexOfScalar(capture_model.Stop, self.stop_reasons[0..i], reason) != null) return error.ArchiveInconsistent;
        self.stop_reasons[i] = reason;
        self.stop_reason_count = i + 1;
    }
    if (try r.flag()) {
        var id: [36]u8 = undefined;
        @memcpy(&id, try r.take(36));
        for (id) |b| if (!std.ascii.isHex(b) and b != '-') return error.ArchiveInvalidValue;
        source.boot_id = id;
    }
    if (try r.flag()) {
        var writer_boot: [36]u8 = undefined;
        @memcpy(&writer_boot, try r.take(36));
        for (writer_boot) |b| if (!std.ascii.isHex(b) and b != '-') return error.ArchiveInvalidValue;
        source.writer_boot_id = writer_boot;
    }
    source.saved_realtime_ns = try r.opt(u64);
    source.encoder = try a.dupe(u8, try r.text(max_text));
    try r.end();
}
fn validateThreadScope(self: *const Capture) !void {
    if (self.thread_count > perf.max_threads or self.accepted.threads != self.thread_count) return error.ArchiveInconsistent;
    if (self.config.ring_budget_bytes < 4096 or self.config.ring_budget_bytes > 256 * 1024 * 1024) return error.ArchiveInvalidValue;
    var previous = self.started_ns;
    var seen_enrolled = false;
    for (self.threads[0..self.thread_count]) |thread| {
        if (thread.enrolled_ns) |time| {
            if (!self.config.follow_threads or time < previous or time > (self.ended_ns orelse return error.ArchiveStillCollecting)) return error.ArchiveInconsistent;
            previous = time;
            seen_enrolled = true;
        } else if (seen_enrolled) return error.ArchiveInconsistent;
    }
}
fn encodeThreadScope(w: Writer, self: *const Capture) !void {
    try w.flag(self.config.follow_threads);
    try w.int(u32, self.config.ring_budget_bytes);
    try w.count(self.thread_count);
    for (self.threads[0..self.thread_count]) |thread| try w.opt(u64, thread.enrolled_ns);
}
fn decodeThreadScope(r: *Reader, self: *Capture) !void {
    self.config.follow_threads = try r.flag();
    self.config.ring_budget_bytes = try r.int(u32);
    if (try r.count(perf.max_threads, 1) != self.thread_count) return error.ArchiveInconsistent;
    for (self.threads[0..self.thread_count]) |*thread| thread.enrolled_ns = try r.opt(u64);
    try r.end();
    try validateThreadScope(self);
}
fn decodeThreads(r: *Reader, self: *Capture) !void {
    const n = try r.count(perf.max_threads, 39);
    for (0..n) |i| {
        const debugger_id = try r.int(u64);
        const tid = try r.int(i32);
        if (tid <= 0) return error.ArchiveInvalidValue;
        // Flames and timelines select a lane by TID; duplicates are ambiguous.
        for (self.threads[0..i]) |prior| if (prior.perf.tid == tid) return error.ArchiveInconsistent;
        self.threads[i] = .{ .debugger_id = debugger_id, .perf = .{ .tid = tid, .event_id = try r.int(u64), .start_time_ticks = try r.int(u64), .start_time_known = try r.flag() } };
        const name = try r.text(self.thread_names[i].len - 1);
        if (std.mem.indexOfScalar(u8, name, 0) != null) return error.ArchiveInvalidValue;
        @memset(&self.thread_names[i], 0);
        @memcpy(self.thread_names[i][0..name.len], name);
        if (try r.flag()) self.cpu_before[i] = .{ .start_time = try r.int(u64), .user = try r.int(u64), .kernel = try r.int(u64) };
        self.thread_count = i + 1;
    }
    try r.end();
}
fn decodeImages(r: *Reader, a: Allocator) ![]ImageReport {
    const n = try r.count(max_images, 101);
    const reports = try a.alloc(ImageReport, n);
    for (reports, 0..) |*report, i| {
        const id = try r.int(u64);
        if (id == 0) return error.ArchiveInvalidValue;
        for (reports[0..i]) |prior| if (prior.id == id) return error.ArchiveInconsistent;
        const path = try a.dupe(u8, try r.text(max_path));
        var fields: [7]u64 = undefined;
        for (&fields) |*field| field.* = try r.int(u64);
        var identity = ImageIdentity{ .file_bytes = fields[6], .sha256 = undefined, .build_id = null };
        @memcpy(&identity.sha256, try r.take(32));
        if (try r.flag()) {
            const id_bytes = try r.text(max_build_id);
            if (id_bytes.len == 0) return error.ArchiveInvalidValue;
            identity.build_id = try a.dupe(u8, id_bytes);
        }
        if (fields[4] >= fields[5] or path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.ArchiveInvalidValue;
        report.* = .{ .id = id, .path = path, .opened_path = "", .status = .not_requested, .identity = identity, .placement = .{ .device_major = fields[0], .device_minor = fields[1], .inode = fields[2], .bias = fields[3], .start = fields[4], .end = fields[5] } };
    }
    try r.end();
    return reports;
}
fn decodeMappings(r: *Reader, self: *Capture, reports: []const ImageReport) !void {
    const opening = try r.count(mappings.max_opening, 62);
    const changes = try r.count(mappings.max_changes, 0);
    if ((opening + changes) * 62 + changes * 12 > r.bytes.len - r.pos) return error.ArchiveTruncated;
    var path_bytes: usize = 0;
    const entries = try self.allocator.alloc(mappings.Mapping, opening + changes);
    defer self.allocator.free(entries);
    for (entries) |*entry| {
        var fields: [7]u64 = undefined;
        for (&fields) |*field| field.* = try r.int(u64);
        const executable = try r.flag();
        const reason = try ReasonCode.decode(try r.code());
        const path = try r.text(max_path);
        path_bytes += path.len;
        if (path_bytes > max_path_bytes) return error.ArchiveLimit;
        if (fields[3] != 0) {
            for (reports) |report| {
                if (report.id == fields[3]) break;
            } else return error.ArchiveInconsistent;
        }
        entry.* = .{ .start = fields[0], .end = fields[1], .offset = fields[2], .image_id = fields[3], .device_major = fields[4], .device_minor = fields[5], .inode = fields[6], .executable = executable, .reason = reason, .path = try self.arena.allocator().dupe(u8, path) };
    }
    // Rebuild through the shared history so its invariants are re-checked;
    // an archive whose IDs differ from replay is inconsistent, not repaired.
    for (entries[0..opening]) |entry| self.history.opening(self.allocator, entry) catch |err| return if (err == error.OutOfMemory) err else error.ArchiveInconsistent;
    for (entries[opening..], 0..) |entry, i| {
        const time = try r.int(u64);
        const id = try r.int(u32);
        if (id != opening + i + 1) return error.ArchiveInconsistent;
        const got = self.history.add(self.allocator, time, entry) catch |err| return if (err == error.OutOfMemory) err else error.ArchiveInconsistent;
        if (got != id) return error.ArchiveInconsistent;
    }
    try r.end();
}
fn decodeSamples(r: *Reader, self: *Capture) !void {
    // Validate the complete variable-length section before allocating compact
    // sample storage. A forged count must not trigger speculative allocations;
    // the second pass remains subject to count and allocation budgets.
    const n = try r.count(self.config.sample_limit, 9);
    var scan = r.*;
    for (0..n) |_| _ = try readSample(&scan);
    try scan.end();
    // Decoded memory follows the compact store's own byte budget.
    for (0..n) |_| try self.samples.append(self.allocator, try readSample(r));
    try r.end();
}
fn readSample(r: *Reader) !records.Sample {
    var sample = records.Sample{};
    const flags = try r.code();
    if (flags >> 6 != 0) return error.ArchiveInvalidValue;
    sample.ip_present = flags & 1 != 0;
    sample.ip_exact = flags & 2 != 0;
    sample.tid_present = flags & 4 != 0;
    sample.time_present = flags & 8 != 0;
    sample.period_present = flags & 16 != 0;
    sample.weight_present = flags & 32 != 0;
    if (sample.ip_present) sample.ip = try r.int(u64);
    sample.pid = try r.int(u32);
    if (sample.tid_present) sample.tid = try r.int(u32);
    if (sample.time_present) sample.time_ns = try r.int(u64);
    if (sample.period_present) sample.period = try r.int(u64);
    if (sample.weight_present) sample.weight = try r.int(u64);
    sample.cpu_mode = try ModeCode.decode(try r.code());
    sample.callchain = try ChainCode.decode(try r.code());
    const frames = try r.int(u16);
    if (frames > records.max_frames) return error.ArchiveLimit;
    if (frames * 9 > r.bytes.len - r.pos) return error.ArchiveTruncated;
    sample.frame_count = frames;
    for (sample.frames[0..frames]) |*item| {
        const tag = try r.code();
        const value = try r.int(u64);
        item.* = .{ .marker = tag & 0x80 != 0, .context = try ContextCode.decode(tag & 0x7f) };
        if (item.marker) item.raw_marker = value else item.address = value;
    }
    return sample;
}
fn decodeScheduling(r: *Reader, self: *Capture) !void {
    const store = &self.switches;
    const retained = try r.int(u64);
    store.discarded = try r.int(u64);
    store.invalid = try r.int(u64);
    store.extent_ns = try r.int(u64);
    if (retained > scheduling.max_events) return error.ArchiveLimit;
    const lanes = try r.count(perf.max_threads, 6);
    if (lanes != self.thread_count) return error.ArchiveInconsistent;
    var total: usize = 0;
    for (store.lanes[0..lanes]) |*lane| {
        const n = try r.count(scheduling.max_lane_events, 9);
        total += n;
        if (total > retained) return error.ArchiveInconsistent;
        lane.cutoff_ns = try r.opt(u64);
        const contradictory = try r.flag();
        try lane.events.ensureTotalCapacityPrecise(self.allocator, n);
        var derived = false;
        for (0..n) |i| {
            const offset = try r.int(u64);
            const bits = try r.code();
            if (bits >> 2 != 0) return error.ArchiveInvalidValue;
            const event = timeline.Transition{ .offset_ns = offset, .direction = if (bits & 1 != 0) .switch_out else .switch_in, .preempted = bits & 2 != 0 };
            // The flag is derived from order; recompute it rather than trust it.
            if (i > 0) {
                const last = lane.events.items[i - 1];
                if (event.offset_ns <= last.offset_ns or event.direction == last.direction) derived = true;
            }
            if (offset +| 1 > store.extent_ns) return error.ArchiveInconsistent;
            lane.events.appendAssumeCapacity(event);
        }
        if (derived != contradictory) return error.ArchiveInconsistent;
        lane.contradictory = contradictory;
    }
    if (total != retained) return error.ArchiveInconsistent;
    store.retained = total;
    try r.end();
}
fn decodeMarkers(r: *Reader, self: *Capture) !void {
    const n = try r.count(timeline.max_markers, 21);
    try self.debugger_markers.ensureTotalCapacityPrecise(self.allocator, n);
    for (0..n) |_| self.debugger_markers.appendAssumeCapacity(.{ .offset_ns = try r.int(u64), .sequence = try r.int(u64), .tid = try r.int(i32), .kind = try MarkerCode.decode(try r.code()) });
    try r.end();
}
fn decodeIntervals(r: *Reader, self: *Capture) !void {
    const n = try r.count(intervals.limit, 31);
    const extent = self.extentNs();
    for (0..n) |i| {
        const id = try r.int(u32);
        const from = try r.int(u64);
        const to = try r.int(u64);
        const tid = try r.opt(u32);
        const kind = try KindCode.decode(try r.code());
        const correlation = try r.opt(u64);
        const label = try r.text(intervals.text_limit);
        const origin = try r.text(intervals.text_limit);
        if (id != i + 1) return error.ArchiveInconsistent;
        if (tid) |t| if (t > std.math.maxInt(i32) or self.threadIndex(@intCast(t)) == null) return error.ArchiveInconsistent;
        // The shared store re-validates text, bounds and extent.
        self.application_intervals.add(self.allocator, origin, &.{.{ .from_ns = from, .to_ns = to, .tid = tid, .label = label, .kind = kind, .correlation_id = correlation }}, extent) catch |err| return if (err == error.OutOfMemory) err else error.ArchiveInconsistent;
    }
    try r.end();
}
fn loadImage(self: *Capture, report: *ImageReport, resolver: Resolver, a: Allocator, state: ?*progress.Progress) !void {
    var buffer: [max_path + 256]u8 = undefined;
    const path = resolver.candidate(&buffer, report.*) orelse return;
    report.opened_path = try a.dupe(u8, path);
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) {
        report.status = .missing;
        return;
    }
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) {
        report.status = .unreadable;
        return;
    }
    if (stat.st_size != report.identity.file_bytes) {
        report.status = .size_mismatch;
        return;
    }
    const bytes = snapshot.read(fd, @min(snapshot.per_image_limit, snapshot.total_limit - self.images.snapshot_bytes), if (state) |p| &p.cancel else null) catch |err| {
        if (err == error.ArchiveCancelled or err == error.OutOfMemory) return err;
        report.status = if (err == error.BinarySnapshotLimit) .limit else .unreadable;
        return;
    };
    var keep = false;
    defer if (!keep) {
        _ = c.munmap(bytes.ptr, bytes.len);
    };
    const identity = identify(bytes);
    if (!std.mem.eql(u8, &identity.sha256, &report.identity.sha256)) {
        report.status = .content_mismatch;
        return;
    }
    const image = elf.Image.parse(bytes) catch {
        report.status = .invalid_elf;
        return;
    };
    // The current archive header and sampled-register ABI are still x86-64.
    // A matching content hash does not make a foreign ISA compatible with it.
    if (@intFromEnum(image.header.machine) != machine_x86_64) {
        report.status = .invalid_elf;
        return;
    }
    const name = try self.images.allocator.dupeZ(u8, report.path);
    errdefer self.images.allocator.free(name);
    const module = try self.images.allocator.create(modules.Module);
    errdefer self.images.allocator.destroy(module);
    const p = report.placement;
    module.* = .{ .id = report.id, .device_major = p.device_major, .device_minor = p.device_minor, .inode = p.inode, .bias = p.bias, .start = p.start, .end = p.end, .path = name, .image = image, .mapping = bytes, .immutable = true };
    try self.images.loaded.append(self.images.allocator, module);
    self.images.snapshot_bytes += bytes.len;
    keep = true;
    report.status = .verified;
}

// ---------------------------------------------------------------- files

pub const Publication = struct {
    state: enum { not_published, published } = .not_published,
    error_name: ?[]const u8 = null,
    cleanup_error: bool = false,
    bytes: usize = 0,
    sha256: [64]u8 = @splat('0'),
};
/// Writes and closes before no-overwrite publication. No durability syncs.
pub fn publish(path: [:0]const u8, bytes: []const u8, state: ?*progress.Progress) Publication {
    var result = Publication{ .bytes = bytes.len };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    result.sha256 = std.fmt.bytesToHex(digest, .lower);
    publishInner(path, bytes, state, &result) catch |err| {
        result.error_name = @errorName(err);
    };
    return result;
}
fn publishInner(path: [:0]const u8, bytes: []const u8, state: ?*progress.Progress, result: *Publication) !void {
    if (path.len == 0 or path.len > max_path or std.mem.indexOfScalar(u8, path, 0) != null or bytes.len > max_file_bytes) return error.ArchivePathInvalid;
    try progress.step(state, .publishing, 0);
    var buffer: [max_path + 80]u8 = undefined;
    const temporary = try std.fmt.bufPrintZ(&buffer, "{s}.xcap-{d}-{d}.tmp", .{ path, c.getpid(), @import("../target/linux.zig").now() });
    const fd = c.open(temporary.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.ArchiveOpenFailed;
    defer {
        if (c.unlink(temporary.ptr) != 0) result.cleanup_error = true;
    }
    var closed = false;
    defer if (!closed) {
        _ = c.close(fd);
    };
    var offset: usize = 0;
    while (offset < bytes.len) {
        try progress.step(state, .publishing, offset);
        const n = c.write(fd, bytes.ptr + offset, @min(1024 * 1024, bytes.len - offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ArchiveWriteFailed;
        offset += @intCast(n);
    }
    closed = true; // Linux releases the fd even when close reports an error.
    if (c.close(fd) != 0) return error.ArchiveCloseFailed;
    try progress.step(state, .publishing, bytes.len);
    if (c.link(temporary.ptr, path.ptr) != 0) return if (std.c._errno().* == c.EEXIST) error.ArchiveExists else error.ArchivePublishFailed;
    result.state = .published;
}
pub fn readFile(a: Allocator, path: [:0]const u8, limit: usize, state: ?*progress.Progress) ![]u8 {
    try progress.step(state, .reading, 0);
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.ArchiveOpenFailed;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.ArchiveNotRegular;
    if (stat.st_size < 0 or stat.st_size > @min(limit, max_file_bytes)) return error.ArchiveTooLarge;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        try progress.step(state, .reading, offset);
        const n = c.read(fd, bytes.ptr + offset, @min(1024 * 1024, bytes.len - offset));
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n <= 0) return error.ArchiveTruncated;
        offset += @intCast(n);
    }
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or stat.st_size != after.st_size or stat.st_mtim.tv_sec != after.st_mtim.tv_sec or stat.st_mtim.tv_nsec != after.st_mtim.tv_nsec or stat.st_ctim.tv_sec != after.st_ctim.tv_sec or stat.st_ctim.tv_nsec != after.st_ctim.tv_nsec) return error.ArchiveChangedDuringRead;
    return bytes;
}

const FrameCode = Codes(flame.Kind, &.{ "root", "thread", "code", "unknown", "unverified", "incomplete" });
fn encodeAnnotations(w: Writer, original: *const Capture, state: ?*progress.Progress) !void {
    // Borrow immutable evidence/ELF bytes. Every mutable cache and libdw handle
    // belongs to this private analysis copy. The job pins the original lifetime.
    // Read only completed evidence; do not even copy the UI's mutable arenas,
    // cache headers or libdw handles while that thread may be updating them.
    var view = Capture{
        .allocator = w.a,
        .arena = std.heap.ArenaAllocator.init(w.a),
        .id = original.id,
        .session_id = original.session_id,
        .generation = original.generation,
        .image_epoch = original.image_epoch,
        .pid = original.pid,
        .started_ns = original.started_ns,
        .config = original.config,
        .accepted = original.accepted,
        .thread_count = original.thread_count,
        .collector = null,
        .threads = original.threads,
        .thread_names = original.thread_names,
        .samples = original.samples,
        .history = original.history,
        .trusted_before_ns = original.trusted_before_ns,
        .images = modules.Modules.init(w.a),
    };
    defer view.arena.deinit();
    view.cache = .empty;
    defer view.cache.deinit(w.a);
    view.recorded = .empty;
    defer view.images.deinit();
    view.work_cancel = if (state) |p| &p.cancel else null;
    for (original.images.loaded.items) |source| {
        if (!source.immutable) return error.ArchiveMutableImage;
        const module = try w.a.create(modules.Module);
        errdefer w.a.destroy(module);
        module.* = .{
            .id = source.id,
            .inode = source.inode,
            .device_major = source.device_major,
            .device_minor = source.device_minor,
            .path = try w.a.dupeZ(u8, source.path),
            .image = source.image,
            .bias = source.bias,
            .start = source.start,
            .end = source.end,
            .mapping = source.mapping,
            .file_offset = source.file_offset,
            .immutable = true,
        };
        errdefer w.a.free(module.path);
        module.owns_mapping = false;
        module.debug = null;
        module.debug_allocator = w.a;
        try view.images.loaded.append(w.a, module);
    }
    try progress.step(state, .annotations, 0);
    var graph = try view.graph(w.a, .{});
    graph.deinit();
    const keys = try w.a.alloc(annotations.Key, view.cache.count());
    defer w.a.free(keys);
    var it = view.cache.keyIterator();
    var n: usize = 0;
    while (it.next()) |key| {
        keys[n] = key.*;
        n += 1;
    }
    std.mem.sort(annotations.Key, keys, {}, struct {
        fn less(_: void, l: annotations.Key, r: annotations.Key) bool {
            if (l.mapping_id != r.mapping_id) return l.mapping_id < r.mapping_id;
            if (l.address != r.address) return l.address < r.address;
            if (l.trusted != r.trusted) return !l.trusted;
            return !l.ambiguous and r.ambiguous;
        }
    }.less);
    try w.int(u32, 1); // recorded annotation schema/resolver version
    try w.count(keys.len);
    for (keys, 0..) |key, i| {
        try progress.step(state, .annotations, i);
        const frame = view.cache.get(key).?;
        try w.int(u64, key.address);
        try w.int(u32, key.mapping_id);
        try w.flag(key.trusted);
        try w.flag(key.ambiguous);
        try w.code(FrameCode.encode(frame.kind));
        try w.int(u64, frame.module_id);
        try w.int(u64, frame.address);
        try w.text(frame.name, 256);
        try w.text(frame.mapping_note, max_text);
        var size: ?u64 = null;
        for (view.images.loaded.items) |image| if (image.id == frame.module_id) {
            if (image.image.symbolAt(try image.linkAddress(frame.lookup_address))) |symbol| size = symbol.symbol.size;
            break;
        };
        try w.opt(u64, size);
        var detail_arena = std.heap.ArenaAllocator.init(w.a);
        defer detail_arena.deinit();
        var source_error: []const u8 = "";
        const site: ?info.Site = view.source(detail_arena.allocator(), frame) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            source_error = @errorName(err);
            break :blk null;
        };
        const kept = if (site) |loc| loc.path.len <= max_path else false;
        if (site != null and !kept) source_error = "SourcePathLimit";
        try w.flag(kept);
        if (kept) {
            const loc = site.?;
            try w.text(loc.path, max_path);
            try w.int(u32, loc.line);
            try w.int(u32, loc.column);
            try w.int(u64, loc.address);
            try w.flag(loc.is_statement);
            try w.flag(loc.prologue_end);
            try w.int(u32, loc.discriminator);
        }
        try w.text(source_error, max_text);
    }
}
fn decodeAnnotations(r: *Reader, self: *Capture, reports: []const ImageReport) !void {
    if (try r.int(u32) != 1) return error.ArchiveFeatureUnsupported;
    const count = try r.count(capture_model.max_frames_cached, 43);
    const a = self.arena.allocator();
    for (0..count) |_| {
        const key = annotations.Key{ .address = try r.int(u64), .mapping_id = try r.int(u32), .trusted = try r.flag(), .ambiguous = try r.flag() };
        const kind = try FrameCode.decode(try r.code());
        if (kind != .code and kind != .unknown and kind != .unverified) return error.ArchiveInvalidValue;
        if (key.mapping_id > self.history.entries.items.len or (!key.trusted and key.mapping_id != 0)) return error.ArchiveInconsistent;
        var frame = flame.Frame{ .kind = kind, .module_id = try r.int(u64), .address = try r.int(u64), .mapping_id = key.mapping_id, .lookup_address = key.address, .name = try a.dupe(u8, try r.text(256)), .mapping_note = try a.dupe(u8, try r.text(max_text)) };
        if (key.mapping_id > 0 and key.trusted and !key.ambiguous) frame.module = self.history.entries.items[key.mapping_id - 1].path;
        if (frame.module_id != 0) {
            for (reports) |report| {
                if (report.id == frame.module_id) break;
            } else return error.ArchiveInconsistent;
        }
        if (kind == .code) {
            if (!key.trusted or key.ambiguous or key.mapping_id == 0 or frame.module_id == 0 or frame.address > key.address) return error.ArchiveInconsistent;
            const mapping = self.history.entries.items[key.mapping_id - 1];
            if (mapping.image_id != frame.module_id or !mapping.executable or key.address < mapping.start or key.address >= mapping.end) return error.ArchiveInconsistent;
        }
        var record = annotations.Record{ .frame = frame, .symbol_size = try r.opt(u64) };
        if (try r.flag()) record.site = .{ .path = try a.dupe(u8, try r.text(max_path)), .line = try r.int(u32), .column = try r.int(u32), .address = try r.int(u64), .is_statement = try r.flag(), .prologue_end = try r.flag(), .discriminator = try r.int(u32) };
        record.source_error = try a.dupe(u8, try r.text(max_text));
        const entry = try self.recorded.getOrPut(self.allocator, key);
        if (entry.found_existing) return error.ArchiveInconsistent;
        entry.value_ptr.* = record;
    }
    try r.end();
}

// USTA v1. All lengths are checked independently of the surrounding section CRC.
fn validateUserState(self: *const Capture) !void {
    const store = &self.user_state;
    const bits = records.Bits.regs_user | records.Bits.stack_user;
    if (self.config.user_stack_bytes == 0) {
        if (self.accepted.user_regs_mask != 0 or self.accepted.user_stack_bytes != 0 or self.accepted.sample_type & bits != 0 or store.count != 0 or store.used != 0) return error.ArchiveInconsistent;
        for (0..self.samples.len()) |ordinal| if (self.samples.core(ordinal).user_state != 0) return error.ArchiveInconsistent;
        return;
    }
    self.config.validate() catch return error.ArchiveInvalidValue;
    if (self.accepted.user_stack_bytes != self.config.user_stack_bytes or self.accepted.user_regs_mask != records.user_regs_gpr_mask or self.accepted.sample_type & bits != bits or store.count > store.entries.len or store.used > store.bytes.len or store.used > self.config.user_stack_budget_bytes) return error.ArchiveInconsistent;
    var count: usize = 0;
    var used: usize = 0;
    var skipped: usize = 0;
    var first: ?usize = null;
    for (0..self.samples.len()) |ordinal| {
        const sample = self.samples.core(ordinal);
        if (sample.user_state == 0) continue; // explicit missing evidence after a collector error
        if (sample.user_state != count + 1 or count >= store.count) return error.ArchiveInconsistent;
        const entry = store.entries[count];
        const state = entry.state;
        if (state.abi > records.regs_abi_64 or state.regs_mask != self.accepted.user_regs_mask or state.regs_present != (state.abi != records.regs_abi_none) or state.stack_present != (state.stack_size != 0) or state.stack_short != (state.stack_size != 0 and (state.stack_dyn < state.stack_size or state.stack_dyn < self.config.user_stack_bytes)) or state.stack_size > self.config.user_stack_bytes or state.stack_dyn > state.stack_size) return error.ArchiveInconsistent;
        for (state.regs, 0..) |reg, index| if ((!state.regs_present or state.regs_mask & (@as(u64, 1) << @intCast(index)) == 0) and reg != 0) return error.ArchiveInconsistent;
        if (entry.status == .budget) {
            if (state.stack_len != 0 or state.stack_off != 0 or state.stack_dyn == 0) return error.ArchiveInconsistent;
            if (first == null) {
                if (state.stack_dyn <= self.config.user_stack_budget_bytes - used) return error.ArchiveInconsistent;
                first = count;
            }
            skipped += 1;
        } else {
            if (state.stack_len != state.stack_dyn or state.stack_len > store.used - used) return error.ArchiveInconsistent;
            if (state.stack_len != 0) {
                if (first != null or state.stack_off != used) return error.ArchiveInconsistent;
                used += state.stack_len;
            } else if (state.stack_off != 0) return error.ArchiveInconsistent;
        }
        count += 1;
    }
    if (count != store.count or used != store.used or skipped != store.skipped or first != store.first_skipped or store.exhausted != (skipped != 0)) return error.ArchiveInconsistent;
}
fn encodeUserState(w: Writer, self: *const Capture, state: ?*progress.Progress) !void {
    // All counts were validated. Reserve exactly once: growing a 64 MiB body
    // geometrically would compete with the final container for the codec budget.
    try w.out.ensureTotalCapacityPrecise(w.a, 28 + self.samples.len() + self.user_state.count * 221 + self.user_state.used);
    try w.int(u32, 1);
    try w.int(u32, self.config.user_stack_bytes);
    try w.int(u32, self.config.user_stack_budget_bytes);
    try w.int(u64, self.accepted.user_regs_mask);
    try w.count(self.user_state.used);
    try w.count(self.samples.len());
    for (0..self.samples.len()) |ordinal| {
        const sample = self.samples.core(ordinal);
        try progress.step(state, .encoding, ordinal);
        try w.flag(sample.user_state != 0);
        if (sample.user_state == 0) continue;
        const entry = self.user_state.entries[sample.user_state - 1];
        const raw = entry.state;
        try w.code(if (entry.status == .captured) 0 else 1);
        try w.int(u64, raw.abi);
        for (raw.regs) |reg| try w.int(u64, reg);
        try w.int(u64, raw.stack_size);
        try w.int(u64, raw.stack_dyn);
        try w.int(u32, raw.stack_len);
        try w.out.appendSlice(w.a, self.user_state.stack(entry));
    }
}
fn decodeUserState(r: *Reader, self: *Capture) !void {
    if (try r.int(u32) != 1) return error.ArchiveFeatureUnsupported;
    self.config.user_stack_bytes = try r.int(u32);
    self.config.user_stack_budget_bytes = try r.int(u32);
    if (self.config.user_stack_bytes == 0) return error.ArchiveInconsistent;
    self.config.validate() catch return error.ArchiveInvalidValue;
    self.accepted.user_stack_bytes = self.config.user_stack_bytes;
    self.accepted.user_regs_mask = try r.int(u64);
    const retained = try r.int(u32);
    if (retained > self.config.user_stack_budget_bytes) return error.ArchiveLimit;
    const count = try r.count(self.config.sample_limit, 1);
    if (count != self.samples.len() or retained > r.bytes.len - r.pos) return error.ArchiveInconsistent;
    self.user_state = try capture_model.sample_state.Store.init(self.allocator, count, retained);
    const store = &self.user_state;
    for (0..self.samples.len()) |ordinal| {
        const sample = self.samples.coreMut(ordinal);
        if (!try r.flag()) continue;
        const status: capture_model.sample_state.Status = switch (try r.code()) {
            0 => .captured,
            1 => .budget,
            else => return error.ArchiveInvalidValue,
        };
        var raw = records.UserState{ .abi = try r.int(u64), .regs_mask = self.accepted.user_regs_mask };
        raw.regs_present = raw.abi != records.regs_abi_none;
        for (&raw.regs) |*reg| reg.* = try r.int(u64);
        raw.stack_size = try r.int(u64);
        raw.stack_dyn = try r.int(u64);
        raw.stack_present = raw.stack_size != 0;
        raw.stack_short = raw.stack_size != 0 and (raw.stack_dyn < raw.stack_size or raw.stack_dyn < self.config.user_stack_bytes);
        raw.stack_len = try r.int(u32);
        if (raw.stack_len > records.max_user_stack or raw.stack_len > retained - store.used) return error.ArchiveLimit;
        if (raw.stack_len != 0) raw.stack_off = @intCast(store.used);
        @memcpy(store.bytes[store.used..][0..raw.stack_len], try r.take(raw.stack_len));
        store.used += raw.stack_len;
        if (status == .budget) {
            store.exhausted = true;
            store.skipped += 1;
            if (store.first_skipped == null) store.first_skipped = store.count;
        }
        store.entries[store.count] = .{ .state = raw, .status = status };
        store.count += 1;
        sample.user_state = @intCast(store.count);
    }
    if (store.used != retained) return error.ArchiveInconsistent;
    try r.end();
}

test "x86 archives reject ARM64 images even with a matching asset identity" {
    const a = std.testing.allocator;
    const fixture = @import("archive_fixture.zig");
    const source = try fixture.build(a, .empty, null);
    defer source.deinit();
    const path = "tests/fixtures/elf/out/reject-aarch64";
    const arm = try fixture.addElf(source, path, 0, 4096);
    try std.testing.expectError(error.ArchiveUnsupportedArchitecture, encode(a, source, .{}));
    const destination = try fixture.build(a, .empty, null);
    defer destination.deinit();
    var report = ImageReport{ .id = 1, .path = path, .opened_path = "", .status = .not_requested, .identity = identify(arm.mapping), .placement = .{ .device_major = 0, .device_minor = 0, .inode = 0, .bias = 0, .start = 0, .end = 4096 } };
    try loadImage(destination, &report, .{ .enabled = true }, destination.arena.allocator(), null);
    try std.testing.expectEqual(ImageStatus.invalid_elf, report.status);
    try std.testing.expectEqual(@as(usize, 0), destination.images.loaded.items.len);
}

const SyscallReasonCode = Codes(syscalls.Reason, &.{ "complete", "missing_entry", "missing_exit", "nested_entry", "number_mismatch", "time_reversed", "loss", "throttle", "thread_exit", "exec", "truncated", "decode_error" });
fn validateSyscalls(self: *const Capture) !void {
    const store = &self.syscalls;
    if (store.enabled != self.config.syscall_timing) return error.ArchiveInconsistent;
    if (!store.enabled) {
        if (store.items.items.len != 0 or self.hasStop(.syscall_error) or self.hasStop(.syscall_limit)) return error.ArchiveInconsistent;
        return;
    }
    if (self.config.follow_threads or self.thread_count == 0 or self.thread_count > syscalls.max_threads or !store.finished or store.limit == 0 or store.limit > syscalls.max_limit or store.limit != self.config.syscall_limit or store.items.items.len > store.limit) return error.ArchiveInconsistent;
    var last: [syscalls.max_threads]u64 = @splat(0);
    for (store.items.items) |span| {
        if (span.thread_index >= self.thread_count or (span.entry_ns == null and span.exit_ns == null) or (span.exit_ns != null) != (span.result != null) or (span.exit_nr != null) != (span.exit_ns != null)) return error.ArchiveInconsistent;
        const start = span.entry_ns orelse span.exit_ns.?;
        const end = span.exit_ns orelse start;
        if (start < self.started_ns or start < last[span.thread_index] or end < start or end > store.extent_ns) return error.ArchiveInconsistent;
        last[span.thread_index] = end;
        switch (span.reason) {
            .complete => if (span.entry_ns == null or span.exit_ns == null or span.nr != span.exit_nr.?) return error.ArchiveInconsistent,
            .number_mismatch => if (span.entry_ns == null or span.exit_ns == null or span.nr == span.exit_nr.?) return error.ArchiveInconsistent,
            .missing_entry => if (span.entry_ns != null or span.exit_ns == null or span.nr != span.exit_nr.?) return error.ArchiveInconsistent,
            else => if (span.entry_ns == null or span.exit_ns != null) return error.ArchiveInconsistent,
        }
    }
}
fn encodeSyscalls(w: Writer, self: *const Capture) !void {
    const store = &self.syscalls;
    try w.int(u32, store.limit);
    try w.flag(store.unread_possible);
    inline for (.{ "lost", "throttles", "discarded", "invalid", "extent_ns" }) |field| try w.int(u64, @field(store, field));
    try w.count(store.items.items.len);
    for (store.items.items) |span| {
        try w.int(u16, span.thread_index);
        try w.int(i64, span.nr);
        try w.opt(i64, span.exit_nr);
        try w.opt(u64, span.entry_ns);
        try w.opt(u64, span.exit_ns);
        try w.opt(i64, span.result);
        try w.code(SyscallReasonCode.encode(span.reason));
    }
}
fn decodeSyscalls(r: *Reader, self: *Capture) !void {
    const store = &self.syscalls;
    store.enabled = true;
    store.finished = true;
    store.limit = try r.int(u32);
    store.unread_possible = try r.flag();
    if (store.limit == 0 or store.limit > syscalls.max_limit) return error.ArchiveLimit;
    inline for (.{ "lost", "throttles", "discarded", "invalid", "extent_ns" }) |field| @field(store, field) = try r.int(u64);
    self.config.syscall_timing = true;
    self.config.syscall_limit = store.limit;
    const count = try r.count(store.limit, 23);
    try store.items.ensureTotalCapacityPrecise(self.allocator, count);
    for (0..count) |_| store.items.appendAssumeCapacity(.{ .thread_index = try r.int(u16), .nr = try r.int(i64), .exit_nr = try r.opt(i64), .entry_ns = try r.opt(u64), .exit_ns = try r.opt(u64), .result = try r.opt(i64), .reason = try SyscallReasonCode.decode(try r.code()) });
    try r.end();
}
