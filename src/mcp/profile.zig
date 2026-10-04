//! Profile operations have capture/revision guards independent of target stops.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const profile = @import("../profile/capture.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "start_profile", "stop_profile", "get_profile", "get_flamegraph", "get_profile_frame", "get_profile_mappings", "get_profile_timeline", "get_profile_schedule", "get_profile_syscalls", "add_profile_intervals", "get_profile_intervals", "export_profile", "get_profile_samples", "get_profile_stack", "get_profile_stack_coverage" }) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}
pub fn value(a: Allocator, object: anytype) !Value {
    const bytes = try std.json.Stringify.valueAlloc(a, object, .{});
    return (try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always })).value;
}
pub fn number(args: Value, key: []const u8, default: ?u64) !u64 {
    const v = args.object.get(key) orelse return default orelse error.InvalidArguments;
    if (v != .integer or v.integer < 0) return error.InvalidArguments;
    return @intCast(v.integer);
}
pub fn fields(args: Value, allowed: []const []const u8) !void {
    if (args != .object) return error.InvalidArguments;
    var iterator = args.object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |key| if (std.mem.eql(u8, key, entry.key_ptr.*)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidArguments;
    }
}
pub fn readThreads(args: Value, filter: *profile.Filter) !void {
    if (args != .object) return error.InvalidArguments;
    if (args.object.get("tids")) |list| {
        if (args.object.get("tid") != null or list != .array or list.array.items.len > @import("../profile/timeline.zig").ThreadSet.capacity) return error.InvalidArguments;
        var tids: [@import("../profile/timeline.zig").ThreadSet.capacity]u32 = undefined;
        for (list.array.items, 0..) |item, i| {
            if (item != .integer or item.integer <= 0 or item.integer > std.math.maxInt(i32)) return error.InvalidArguments;
            tids[i] = @intCast(item.integer);
        }
        filter.setThreads(tids[0..list.array.items.len]) catch return error.InvalidArguments;
    } else if (args.object.get("tid") != null) {
        const tid = try number(args, "tid", null);
        if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
        filter.tid = @intCast(tid);
    }
}
pub fn readFilter(args: Value) !profile.Filter {
    var filter = profile.Filter{ .from_ns = try number(args, "from_ns", 0), .to_ns = try number(args, "to_ns", std.math.maxInt(u64)) };
    try readThreads(args, &filter);
    filter.validate() catch return error.InvalidArguments;
    return filter;
}
fn derivedFlamegraph(a: Allocator, session: *Session, capture: *profile.Capture, filter: profile.Filter, args: Value) !Value {
    const derived = @import("../profile/derived.zig");
    const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
    const limit = std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments;
    if (limit == 0 or limit > 64) return error.InvalidArguments;
    // Pages refer only to the retained result; stale citations must not start
    // a new build or reinterpret a node from the other basis.
    if (args.object.get("view_id")) |given| {
        const published = session.derived orelse return error.StaleProfileView;
        if (given != .string or !std.mem.eql(u8, given.string, &published.view.identity) or
            !std.meta.eql(published.key, derived.Key.of(capture, filter))) return error.StaleProfileView;
    } else if (start > 0) return error.ProfileViewRequired;
    // A failed reconstruction is cached for its key; retry is explicit.
    if (args.object.get("retry")) |retry| {
        if (retry != .bool) return error.InvalidArguments;
        if (retry.bool) session.retryDerived();
    }
    const state = session.requestDerived(filter);
    const view = switch (state) {
        .ready => |view| view,
        .pending => |p| return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .basis = "reconstructed", .pending = true, .samples_done = p.done, .samples_total = p.total, .job = if (session.archive_job) |job| job.status() else null }),
        .failed => |err| return err,
        .unavailable => |err| return err,
    };
    // A view_id from an earlier page must still name this exact result.
    if (args.object.get("view_id")) |given| {
        if (given != .string or !std.mem.eql(u8, given.string, &view.identity)) return error.StaleProfileView;
    } else if (start > 0) return error.ProfileViewRequired;
    const graph = &view.graph;
    if (start >= graph.nodes.items.len) return error.InvalidArguments;
    const end = @min(graph.nodes.items.len, start + limit);
    const Row = struct { id: u32, parent: ?u32, name: []const u8, kind: @import("../profile/flame.zig").Kind, module_id: u64, mapping_id: u32, address: []const u8, lookup_address: []const u8, inclusive: u64, self: u64, depth: u16, x: u64, example_sample: ?u32 };
    var rows: std.ArrayList(Row) = .empty;
    for (graph.nodes.items[start..end], view.examples[start..end]) |node, example| {
        const frame = node.frame;
        try rows.append(a, .{ .id = node.id, .parent = node.parent, .name = frame.name, .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .address = try std.fmt.allocPrint(a, "0x{x}", .{frame.address}), .lookup_address = try std.fmt.allocPrint(a, "0x{x}", .{frame.lookup_address}), .inclusive = node.inclusive, .self = node.self, .depth = node.depth, .x = node.x, .example_sample = if (example == std.math.maxInt(u32)) null else example });
    }
    const Reason = struct { reason: []const u8, samples: u64, examples: []const u32 };
    var reasons: std.ArrayList(Reason) = .empty;
    for (view.counts.by_reason, 0..) |n, i| if (n > 0) try reasons.append(a, .{ .reason = @tagName(@as(@import("../profile/unwind.zig").Reason, @enumFromInt(i))), .samples = n, .examples = view.reason_examples[i][0..view.reason_example_count[i]] });
    return value(a, .{
        .capture_id = capture.id,
        .revision = capture.revision,
        .basis = "reconstructed",
        .pending = false,
        .view_id = view.identity[0..],
        .algorithm = @import("../profile/unwind.zig").algorithm,
        .aggregate = derived.version,
        .units = "samples",
        .filter = .{ .tid = filter.tid, .tids = filter.tids.optional(), .from_ns = filter.from_ns, .to_ns = if (filter.to_ns == std.math.maxInt(u64)) null else @as(?u64, filter.to_ns) },
        .denominator = view.counts.filtered,
        .buckets = .{ .complete = view.counts.complete, .partial = view.counts.partial, .leaf_only = view.counts.leaf_only, .unavailable = view.counts.unavailable, .excluded_by_node_limit = view.counts.excluded },
        .bucket_meaning = derived.bucket_meaning,
        .terminal_reasons = reasons.items,
        .outside_filter = view.counts.outside_filter,
        .worker = .{ .build_ms = view.build_ns / 1_000_000, .peak_bytes = view.peak_bytes, .memory_limit = derived.memory_limit, .elf_bytes_hashed = view.elf_bytes_hashed },
        .unfilterable = view.counts.unfilterable,
        .basis_note = "saved registers/stack bytes and timestamped mappings with verified ELF assets; partial stacks hang under explicit [callers unknown] nodes and are never joined to complete paths; recorded kernel callchains are unchanged",
        .total_nodes = graph.nodes.items.len,
        .nodes = rows.items,
        .next = if (end < graph.nodes.items.len) @as(?usize, end) else null,
    });
}
pub fn call(a: Allocator, session: *Session, name: []const u8, args: Value) !Value {
    if (@import("../target/arch.zig").native == .m68k) return error.ProfileUnsupportedArchitecture;
    if (std.mem.eql(u8, name, "get_profile_stack") or std.mem.eql(u8, name, "get_profile_stack_coverage")) return @import("sampled_stack.zig").call(a, session, name, args);
    if (std.mem.eql(u8, name, "get_profile_samples")) {
        try fields(args, &.{ "capture_id", "revision", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try number(args, "limit", 8)) orelse return error.InvalidArguments;
        if (start > capture.samples.len() or limit == 0 or limit > 16) return error.InvalidArguments;
        const end = @min(capture.samples.len(), start + limit);
        const Row = struct { ordinal: usize, sample: Value };
        var rows: std.ArrayList(Row) = .empty;
        for (start..end) |ordinal| {
            const sample = capture.samples.get(ordinal);
            try rows.append(a, .{ .ordinal = ordinal, .sample = try value(a, .{ .ip = if (sample.ip_present) @as(?u64, sample.ip) else null, .ip_exact = sample.ip_exact, .pid = if (sample.tid_present) @as(?u32, sample.pid) else null, .tid = if (sample.tid_present) @as(?u32, sample.tid) else null, .time_ns = if (sample.time_present) @as(?u64, sample.time_ns) else null, .period = if (sample.period_present) @as(?u64, sample.period) else null, .weight = if (sample.weight_present) @as(?u64, sample.weight) else null, .cpu_mode = sample.cpu_mode, .callchain = sample.callchain, .frames = sample.frames[0..sample.frame_count], .user_state = @import("sampled_stack.zig").summary(capture, sample) }) });
        }
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .artifact_sha256 = if (session.artifact) |*artifact| try a.dupe(u8, &std.fmt.bytesToHex(artifact.source.archive_sha256, .lower)) else null, .samples = rows.items, .total = capture.samples.len(), .next = if (end < capture.samples.len()) @as(?usize, end) else null });
    }
    if (std.mem.eql(u8, name, "export_profile")) {
        try fields(args, &.{ "generation", "capture_id", "revision", "path", "tid", "tids", "from_ns", "to_ns" });
        try session.authorize(.agent, .execution, try number(args, "generation", null));
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const raw_path = args.object.get("path") orelse return error.InvalidArguments;
        if (raw_path != .string or raw_path.string.len == 0 or raw_path.string.len > 4096 or std.mem.indexOfScalar(u8, raw_path.string, 0) != null) return error.InvalidArguments;
        const path = try a.dupeSentinel(u8, raw_path.string, 0);
        const selected_filter = try readFilter(args);
        try session.ensureArchiveView(selected_filter);
        if (capture.collector != null) return error.ProfileStillCollecting;
        const prepared = if (!capture.offline) &(try session.recorded_views.request(capture, capture.revision, selected_filter, false)).graph else null;
        const result = try @import("../profile/export.zig").savePrepared(capture, path, selected_filter, prepared);
        session.record(.agent, "export_profile");
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .generation = session.target.generation, .path = path, .format = "speedscope", .result = result, .ordering = @import("../profile/export.zig").ordering });
    }
    if (std.mem.eql(u8, name, "add_profile_intervals")) {
        try fields(args, &.{ "generation", "capture_id", "revision", "source", "intervals" });
        try session.authorize(.agent, .execution, try number(args, "generation", null));
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const source = args.object.get("source") orelse return error.InvalidArguments;
        if (source != .string) return error.InvalidArguments;
        const list = args.object.get("intervals") orelse return error.InvalidArguments;
        const app = @import("../profile/intervals.zig");
        if (list != .array or list.array.items.len == 0 or list.array.items.len > app.batch_limit) return error.InvalidArguments;
        var batch: [app.batch_limit]app.Input = undefined;
        for (list.array.items, 0..) |item, i| {
            try fields(item, &.{ "from_ns", "to_ns", "tid", "label", "kind", "correlation_id" });
            const label = item.object.get("label") orelse return error.InvalidArguments;
            if (label != .string) return error.InvalidArguments;
            const tid = if (item.object.get("tid") != null) try number(item, "tid", null) else null;
            if (tid != null and (tid.? == 0 or tid.? > std.math.maxInt(i32))) return error.InvalidArguments;
            const kind = if (item.object.get("kind")) |k| blk: {
                if (k != .string) return error.InvalidArguments;
                break :blk std.meta.stringToEnum(app.Kind, k.string) orelse return error.InvalidArguments;
            } else .custom;
            batch[i] = .{ .from_ns = try number(item, "from_ns", null), .to_ns = try number(item, "to_ns", null), .tid = if (tid) |t| @intCast(t) else null, .label = label.string, .kind = kind, .correlation_id = if (item.object.get("correlation_id") != null) try number(item, "correlation_id", null) else null };
        }
        try capture.addIntervals(source.string, batch[0..list.array.items.len]);
        session.record(.agent, "add_profile_intervals");
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .generation = session.target.generation, .added = list.array.items.len, .total = capture.application_intervals.items.items.len, .limit = app.limit, .provenance = app.provenance });
    }
    if (std.mem.eql(u8, name, "get_profile_intervals")) {
        try fields(args, &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const filter = try readFilter(args);
        try capture.validateFilter(filter);
        const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments;
        if (limit == 0 or limit > 128) return error.InvalidArguments;
        const app = @import("../profile/intervals.zig");
        const extent = capture.extentNs();
        var total: usize = 0;
        var rows: std.ArrayList(app.Interval) = .empty;
        for (capture.application_intervals.items.items) |item| if (item.matches(filter, extent)) {
            if (total >= start and rows.items.len < limit) try rows.append(a, item);
            total += 1;
        };
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .range = filter.clipped(extent), .total = total, .start = start, .next = if (start < total and rows.items.len < total - start) @as(?u64, start + rows.items.len) else null, .intervals = rows.items, .provenance = app.provenance, .selection = "overlap with half-open range; returned endpoints retain original imported times; global intervals match every TID" });
    }
    if (std.mem.eql(u8, name, "start_profile")) {
        try fields(args, &.{ "generation", "tids", "sample_limit", "frequency_hz", "duration_ms", "context_switch", "syscall_timing", "syscall_limit", "follow_threads", "ring_budget_bytes", "user_stack_bytes", "user_stack_budget_bytes" });
        try session.authorize(.agent, .execution, try number(args, "generation", null));
        const sample_limit = try number(args, "sample_limit", session.profile_defaults.sample_limit);
        if (sample_limit == 0 or sample_limit > @import("../profile/capture.zig").max_sample_limit) return error.InvalidArguments;
        const hz = try number(args, "frequency_hz", session.profile_defaults.frequency_hz);
        const duration = try number(args, "duration_ms", session.profile_defaults.duration_ms);
        if (hz == 0 or hz > 1000 or duration > std.math.maxInt(u32)) return error.InvalidArguments;
        const stack_bytes = try number(args, "user_stack_bytes", session.profile_defaults.user_stack_bytes);
        const stack_budget = try number(args, "user_stack_budget_bytes", session.profile_defaults.user_stack_budget_bytes);
        if (stack_bytes > std.math.maxInt(u32) or stack_budget > std.math.maxInt(u32)) return error.InvalidArguments;
        const context_switch = if (args.object.get("context_switch")) |v| switch (v) {
            .bool => v.bool,
            else => return error.InvalidArguments,
        } else session.profile_defaults.context_switch;
        const syscall_timing = if (args.object.get("syscall_timing")) |v| switch (v) {
            .bool => v.bool,
            else => return error.InvalidArguments,
        } else session.profile_defaults.syscall_timing;
        const syscall_limit = try number(args, "syscall_limit", session.profile_defaults.syscall_limit);
        if (syscall_limit == 0 or syscall_limit > @import("../profile/syscalls.zig").max_limit) return error.InvalidArguments;
        const follow_threads = if (args.object.get("follow_threads")) |v| switch (v) {
            .bool => v.bool,
            else => return error.InvalidArguments,
        } else session.profile_defaults.follow_threads;
        const ring_budget = try number(args, "ring_budget_bytes", session.profile_defaults.ring_budget_bytes);
        if (ring_budget < 4096 or ring_budget > 256 * 1024 * 1024) return error.InvalidArguments;
        var tids: [@import("../profile/linux_perf.zig").max_threads]i32 = undefined;
        var count: usize = 0;
        if (args.object.get("tids")) |list| {
            if (list != .array or list.array.items.len == 0 or list.array.items.len > tids.len) return error.InvalidArguments;
            for (list.array.items) |tid| {
                if (tid != .integer or tid.integer <= 0 or tid.integer > std.math.maxInt(i32)) return error.InvalidArguments;
                tids[count] = @intCast(tid.integer);
                count += 1;
            }
        }
        _ = try session.startProfile(.{ .sample_limit = @intCast(sample_limit), .follow_threads = follow_threads, .ring_budget_bytes = @intCast(ring_budget), .frequency_hz = @intCast(hz), .duration_ms = @intCast(duration), .context_switch = context_switch, .syscall_timing = syscall_timing, .syscall_limit = @intCast(syscall_limit), .user_stack_bytes = @intCast(stack_bytes), .user_stack_budget_bytes = @intCast(stack_budget), .tids = tids[0..count] });
        session.record(.agent, "start_profile");
        return value(a, .{ .capture = session.profile.?.summary(), .session = session.snapshot() });
    }
    if (std.mem.eql(u8, name, "get_profile")) {
        try fields(args, &.{"capture_id"});
        if (args.object.get("capture_id") != null) {
            const capture = session.profile orelse return error.NoProfile;
            if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        }
        return value(a, .{ .defaults = .{ .sample_limit = session.profile_defaults.sample_limit, .follow_threads = session.profile_defaults.follow_threads, .ring_budget_bytes = session.profile_defaults.ring_budget_bytes, .frequency_hz = session.profile_defaults.frequency_hz, .duration_ms = session.profile_defaults.duration_ms, .context_switch = session.profile_defaults.context_switch, .syscall_timing = session.profile_defaults.syscall_timing, .syscall_limit = session.profile_defaults.syscall_limit, .user_stack_bytes = session.profile_defaults.user_stack_bytes, .user_stack_budget_bytes = session.profile_defaults.user_stack_budget_bytes }, .offline = session.offline, .archive_job = if (session.archive_job) |job| job.status() else null, .recorded_view_job = if (session.recorded_views.job) |job| .{ .id = job.id, .capture_id = job.key.capture_id, .revision = job.key.revision, .sample_count = job.sample_count, .done = job.done.load(.acquire), .cancelled = job.cancel.load(.acquire) } else null, .capture = if (session.profile) |capture| capture.summary() else null, .displayed_view = if (session.profile_view) |view| .{ .visible = session.profile_view_visible, .basis = view.basis, .capture_id = view.capture_id, .revision = view.revision, .view_id = if (view.view_id) |id| @as(?[]const u8, &id) else null, .sample_count = view.sample_count, .filter = .{ .tid = view.filter.tid, .tids = view.filter.tids.optional(), .from_ns = view.filter.from_ns, .to_ns = if (view.filter.to_ns == std.math.maxInt(u64)) null else @as(?u64, view.filter.to_ns) } } else null, .last_open_failure = session.profile_failure, .last_start_error = session.profile_error, .requested_threads = session.profile_requested_threads, .thread_limit = @import("../profile/linux_perf.zig").max_threads });
    }
    if (std.mem.eql(u8, name, "stop_profile")) {
        try fields(args, &.{ "generation", "capture_id" });
        try session.authorize(.agent, .execution, try number(args, "generation", null));
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        try session.stopProfile();
        session.record(.agent, "stop_profile");
        return value(a, .{ .capture = capture.summary(), .session = session.snapshot() });
    }
    if (std.mem.eql(u8, name, "get_profile_mappings")) {
        try fields(args, &.{ "capture_id", "revision", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments;
        if (start > capture.history.entries.items.len or limit == 0 or limit > 64) return error.InvalidArguments;
        const end = @min(capture.history.entries.items.len, start + limit);
        const Row = struct { id: u32, time_ns: ?u64, offset_ns: ?u64, start: []const u8, end: []const u8, file_offset: []const u8, module_id: u64, device_major: u64, device_minor: u64, inode: u64, executable: bool, reason: @import("../profile/mappings.zig").Reason, path: []const u8 };
        var rows: std.ArrayList(Row) = .empty;
        for (capture.history.entries.items[start..end], start..) |entry, i| {
            const time: ?u64 = if (i < capture.history.opening_count) null else capture.history.changes.items[i - capture.history.opening_count].time_ns;
            try rows.append(a, .{ .id = entry.id, .time_ns = time, .offset_ns = if (time) |t| t -| capture.started_ns else null, .start = try std.fmt.allocPrint(a, "0x{x}", .{entry.start}), .end = try std.fmt.allocPrint(a, "0x{x}", .{entry.end}), .file_offset = try std.fmt.allocPrint(a, "0x{x}", .{entry.offset}), .module_id = entry.image_id, .device_major = entry.device_major, .device_minor = entry.device_minor, .inode = entry.inode, .executable = entry.executable, .reason = entry.reason, .path = entry.path[0..@min(512, entry.path.len)] });
        }
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .coverage = @import("../profile/mappings.zig").coverage, .mappings = rows.items, .total = capture.history.entries.items.len, .next = if (end < capture.history.entries.items.len) @as(?usize, end) else null });
    }
    if (std.mem.eql(u8, name, "get_profile_schedule")) {
        try fields(args, &.{ "capture_id", "revision", "tid", "from_ns", "to_ns", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const filter = try readFilter(args);
        try capture.validateFilter(filter);
        const tid = filter.tid orelse return error.InvalidArguments;
        const index = capture.threadIndex(@intCast(tid)).?;
        const range = filter.clipped(capture.extentNs());
        const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try number(args, "limit", 128)) orelse return error.InvalidArguments;
        if (limit == 0 or limit > 128) return error.InvalidArguments;
        const spans = try capture.schedulingSpans(a, index, range);
        defer a.free(spans);
        if (start > spans.len) return error.InvalidArguments;
        const end = @min(spans.len, start + limit);
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .provisional = capture.collector != null, .thread = capture.threads[index], .range = range, .scheduling = capture.schedulingSummary(), .totals = @import("../profile/scheduling.zig").Totals.from(spans), .units = "nanoseconds of thread elapsed time, not CPU sample counts", .spans = spans[start..end], .total_spans = spans.len, .next = if (end < spans.len) @as(?usize, end) else null });
    }
    if (std.mem.eql(u8, name, "get_profile_syscalls")) {
        try fields(args, &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const filter = try readFilter(args);
        const page = try capture.syscallPage(a, filter, std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments, std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments);
        return value(a, .{ .capture_id = capture.id, .revision = capture.revision, .provisional = capture.collector != null, .syscalls = capture.syscallSummary(), .rows = page.rows, .total = page.total, .next = page.next, .clock = "CLOCK_MONOTONIC", .selection = "rows overlap the relative capture-time filter; row timestamps and durations retain full original endpoints; unfinished durations are null", .scheduling = capture.schedulingSummary() });
    }
    if (std.mem.eql(u8, name, "get_profile_timeline")) {
        try fields(args, &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "bins", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
        if (try number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const filter = try readFilter(args);
        const bins = try number(args, "bins", 128);
        const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments;
        if (bins == 0 or bins > @import("../profile/timeline.zig").max_bins or limit == 0 or limit > 64) return error.InvalidArguments;
        var data = try capture.cpuTimeline(a, filter, @intCast(bins));
        defer data.deinit();
        if (start > data.lanes.len) return error.InvalidArguments;
        const end = @min(data.lanes.len, start + limit);
        return value(a, .{
            .capture_id = capture.id,
            .revision = capture.revision,
            .provisional = capture.collector != null,
            .extent_ns = capture.extentNs(),
            .clock = "CLOCK_MONOTONIC",
            .units = "samples (not elapsed time)",
            .filter = .{ .tid = filter.tid, .tids = filter.tids.optional(), .from_ns = filter.from_ns, .to_ns = if (filter.to_ns == std.math.maxInt(u64)) null else @as(?u64, filter.to_ns) },
            .range = data.histogram.range,
            .bins = data.histogram.bins,
            .samples = data.histogram.samples,
            .invalid_samples = data.invalid_samples,
            .application_intervals = capture.application_intervals.items.items.len,
            .threads = data.lanes[start..end],
            .total_threads = data.lanes.len,
            .next = if (end < data.lanes.len) @as(?usize, end) else null,
            .lost_records = capture.lost_records,
            .lost_samples = capture.lost_samples,
            .discarded_samples = capture.discarded_samples,
            .scheduling = capture.schedulingSummary(),
            .debugger_markers = capture.debugger_markers.items,
            .debugger_marker_basis = @import("../profile/timeline.zig").marker_basis,
            .debugger_marker_dropped = capture.debugger_marker_dropped,
            .debugger_events_lost = capture.debugger_events_lost,
        });
    }
    const detail = std.mem.eql(u8, name, "get_profile_frame");
    try fields(args, if (detail) &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "node", "view_id" } else &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "start", "limit", "view_id", "retry", "basis" });
    const capture = session.profile orelse return error.NoProfile;
    if (try number(args, "capture_id", null) != capture.id) return error.StaleCapture;
    const revision = try number(args, "revision", if (capture.offline or detail or try number(args, "start", 0) > 0 or args.object.get("view_id") != null) null else capture.revision);
    const filter = try readFilter(args);
    try capture.validateFilter(filter);
    // Reconstructed node IDs belong to a separate completed-capture view.
    if (!detail) if (args.object.get("basis")) |basis| {
        if (basis != .string) return error.InvalidArguments;
        if (std.mem.eql(u8, basis.string, "reconstructed")) {
            if (capture.collector != null) return error.ArchiveStillCollecting;
            if (revision != capture.revision) return error.StaleProfile;
            return derivedFlamegraph(a, session, capture, filter, args);
        }
        if (!std.mem.eql(u8, basis.string, "recorded")) return error.InvalidArguments;
    };
    const retry = if (args.object.get("retry")) |given| switch (given) {
        .bool => given.bool,
        else => return error.InvalidArguments,
    } else false;
    const page_start = if (detail) 0 else try number(args, "start", 0);
    const page_limit = if (detail) 1 else try number(args, "limit", 64);
    if (page_limit == 0 or page_limit > 64) return error.InvalidArguments;
    var view_id: ?[]const u8 = null;
    var owned_graph: ?@import("../profile/flame.zig").Graph = null;
    defer if (owned_graph) |*graph| graph.deinit();
    var snapshot_samples = capture.samples.len();
    var snapshot_ns: u64 = 0;
    var build_ns: u64 = 0;
    var peak_bytes: usize = 0;
    const graph: *const @import("../profile/flame.zig").Graph = if (capture.offline) blk: {
        if (revision != capture.revision) return error.StaleProfile;
        view_id = if (session.artifact) |*artifact| try a.dupe(u8, &artifact.viewId(filter)) else null;
        if (view_id) |expected| {
            if (args.object.get("view_id")) |given| {
                if (given != .string or !std.mem.eql(u8, given.string, expected)) return error.StaleArchiveView;
            } else if (detail or page_start > 0) return error.ArchiveViewRequired;
        }
        try session.ensureArchiveView(filter);
        owned_graph = try capture.graph(a, filter);
        break :blk &owned_graph.?;
    } else blk: {
        const recorded = @import("../profile/recorded_view.zig");
        var key = recorded.Key.of(capture, filter);
        key.revision = revision;
        view_id = try a.dupe(u8, &key.viewId());
        session.recorded_views.poll(capture);
        if (args.object.get("view_id")) |given| {
            if (given != .string or !std.mem.eql(u8, given.string, view_id.?) or !session.recorded_views.retained(key)) return error.StaleProfileView;
        } else if (detail or page_start > 0) return error.ProfileViewRequired;
        const result = session.recorded_views.request(capture, revision, filter, retry) catch |err| {
            if (err != error.ProfileViewPending) return err;
            const job = session.recorded_views.job.?;
            return value(a, .{ .capture_id = capture.id, .revision = revision, .current_revision = capture.revision, .view_id = view_id, .basis = "recorded", .pending = true, .job_id = job.id, .snapshot_samples = job.sample_count });
        };
        snapshot_samples = result.sample_count;
        snapshot_ns = result.snapshot_ns;
        build_ns = result.build_ns;
        peak_bytes = result.peak_bytes;
        break :blk &result.graph;
    };
    if (detail) {
        const node = std.math.cast(usize, try number(args, "node", null)) orelse return error.InvalidArguments;
        if (node >= graph.nodes.items.len) return error.InvalidArguments;
        const frame = graph.nodes.items[node].frame;
        const site = capture.source(a, frame) catch null;
        const Instruction = struct { address: []const u8, mnemonic: []const u8, operands: []const u8 };
        var instructions: std.ArrayList(Instruction) = .empty;
        var diagnostic: ?[]const u8 = null;
        const decoded = capture.instructions(a, frame) catch |err| result: {
            diagnostic = @errorName(err);
            break :result &.{};
        };
        for (decoded) |instruction| try instructions.append(a, .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{instruction.address}), .mnemonic = try a.dupe(u8, std.mem.sliceTo(&instruction.mnemonic, 0)), .operands = try a.dupe(u8, std.mem.sliceTo(&instruction.operands, 0)) });
        return value(a, .{ .capture_id = capture.id, .revision = revision, .current_revision = capture.revision, .view_id = view_id, .node = node, .evidence = .{ .mapping_id = frame.mapping_id, .module_id = frame.module_id, .lookup_address = try std.fmt.allocPrint(a, "0x{x}", .{frame.lookup_address}), .reference_basis = "mapping/address plus the view filter; node is temporary within view_id" }, .source_basis = if (capture.reanalyzed) "new analysis of identity-verified immutable assets; source text not archived" else if (capture.offline) @import("../profile/annotations.zig").basis else "retained capture ELF; current source text not certified", .mapping_id = frame.mapping_id, .mapping_note = frame.mapping_note, .mapping_coverage = @import("../profile/mappings.zig").coverage, .source = site, .instructions = instructions.items, .diagnostic = diagnostic, .assembly_basis = "retained ELF file for the recorded mapping, not live memory; sample IP or caller return address minus one is a representative location, not a per-line histogram", .target_changed = session.target.image_epoch != capture.image_epoch });
    }
    const start = std.math.cast(usize, try number(args, "start", 0)) orelse return error.InvalidArguments;
    const limit = std.math.cast(usize, try number(args, "limit", 64)) orelse return error.InvalidArguments;
    if (start >= graph.nodes.items.len or limit == 0 or limit > 64) return error.InvalidArguments;
    const end = @min(graph.nodes.items.len, start + limit);
    const Row = struct { id: u32, parent: ?u32, name: []const u8, kind: @import("../profile/flame.zig").Kind, module_id: u64, mapping_id: u32, mapping_note: []const u8, module: []const u8, address: []const u8, lookup_address: []const u8, inclusive: u64, self: u64, depth: u16, x: u64 };
    var rows: std.ArrayList(Row) = .empty;
    for (graph.nodes.items[start..end]) |node| {
        const frame = node.frame;
        try rows.append(a, .{ .id = node.id, .parent = node.parent, .name = frame.name, .kind = frame.kind, .module_id = frame.module_id, .mapping_id = frame.mapping_id, .mapping_note = frame.mapping_note, .module = frame.module[0..@min(512, frame.module.len)], .address = try std.fmt.allocPrint(a, "0x{x}", .{frame.address}), .lookup_address = try std.fmt.allocPrint(a, "0x{x}", .{frame.lookup_address}), .inclusive = node.inclusive, .self = node.self, .depth = node.depth, .x = node.x });
    }
    return value(a, .{ .capture_id = capture.id, .revision = revision, .current_revision = capture.revision, .view_id = view_id, .basis = "recorded", .pending = false, .snapshot_samples = snapshot_samples, .worker = if (!capture.offline) .{ .algorithm = @import("../profile/recorded_view.zig").algorithm, .snapshot_ns = snapshot_ns, .build_ns = build_ns, .peak_bytes = peak_bytes, .limit_bytes = @import("../profile/recorded_view.zig").memory_limit } else null, .analysis_version = @import("../profile/archive.zig").analysis_version, .units = "samples", .mapping_coverage = @import("../profile/mappings.zig").coverage, .filter = .{ .tid = filter.tid, .tids = filter.tids.optional(), .from_ns = filter.from_ns, .to_ns = if (filter.to_ns == std.math.maxInt(u64)) null else @as(?u64, filter.to_ns) }, .samples = graph.nodes.items[0].inclusive, .excluded_by_node_limit = graph.rejected, .partial_callchain_samples = graph.partial_samples, .unverified_mapping_samples = graph.unverified_samples, .total_nodes = graph.nodes.items.len, .nodes = rows.items, .next = if (end < graph.nodes.items.len) @as(?usize, end) else null });
}
