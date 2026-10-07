const std = @import("std");
const Session = @import("../model/session.zig").Session;
const jit_frames = @import("../frames/jit.zig");
const model = @import("../frames/model.zig");
const c = model.c;
const wire = @import("profile.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
const eq = std.mem.eql;
pub fn handles(name: []const u8) bool {
    for ([_][]const u8{ "import_logical_frames", "import_jit_map", "prepare_jit_profile", "get_jit_profile", "get_jit_stack", "get_jit_candidates", "open_frame_bundle", "get_frame_status", "get_frame_threads", "get_frame_stacks", "get_frame_stack", "get_frame_functions", "get_frame_aggregate", "select_frame_aggregate", "get_frame_citation", "save_frames", "cancel_frame_job" }) |tool| if (eq(u8, name, tool)) return true;
    return false;
}
fn text(args: V, key: []const u8) ![]const u8 {
    const v = args.object.get(key) orelse return error.InvalidArguments;
    if (v != .string) return error.InvalidArguments;
    return v.string;
}
fn optionalIndex(args: V, key: []const u8) !?u32 {
    const v = args.object.get(key) orelse return null;
    if (v == .null) return null;
    const n = try wire.number(args, key, null);
    if (n > std.math.maxInt(u32)) return error.InvalidArguments;
    return @intCast(n);
}
pub fn call(a: A, session: *Session, name: []const u8, args: V) !V {
    var budget = @import("../profile/archive_budget.zig").Budget{ .backing = a, .limit = 8 * 1024 * 1024 };
    var arena = std.heap.ArenaAllocator.init(budget.allocator());
    defer arena.deinit();
    const value = callBounded(arena.allocator(), session, name, args) catch |err| return if (err == error.OutOfMemory) error.FrameResponseLimit else err;
    const bytes = std.json.Stringify.valueAlloc(arena.allocator(), value, .{}) catch return error.FrameResponseLimit;
    if (bytes.len > 512 * 1024) return error.FrameResponseLimit;
    return (try std.json.parseFromSlice(V, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn callBounded(a: A, session: *Session, name: []const u8, args: V) !V {
    const state = &session.frames;
    state.poll();
    if (!std.mem.startsWith(u8, name, "get_") and session.agent_scope == .observe) return error.AgentScopeDenied;
    if (eq(u8, name, "import_jit_map")) {
        try wire.fields(args, &.{ "path", "kind", "declaration" });
        const kind = std.meta.stringToEnum(model.Kind, try text(args, "kind")) orelse return error.JitSourceInvalid;
        const metadata = args.object.get("declaration") orelse return error.JitMetadataRequired;
        const bytes = try std.json.Stringify.valueAlloc(a, metadata, .{});
        try state.importJit(try text(args, "path"), kind, bytes);
        return wire.value(a, .{ .status = "pending", .serial = state.serial });
    }
    if (eq(u8, name, "prepare_jit_profile") or eq(u8, name, "get_jit_profile")) {
        try wire.fields(args, &.{ "capture_id", "revision", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try wire.number(args, "capture_id", null) != capture.id or try wire.number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const ordinal = try wire.number(args, "start", 0);
        const count = try wire.number(args, "limit", 1);
        if (count == 0 or count > 64 or ordinal > capture.samples.len()) return error.JitSampleRange;
        if (eq(u8, name, "prepare_jit_profile")) {
            try state.prepareJit(capture, if (session.artifact) |artifact| artifact.source else null, @intCast(ordinal), @intCast(count));
            return wire.value(a, .{ .status = "pending", .serial = state.serial });
        }
        const view = state.jit_view orelse return error.JitViewRequired;
        var samples = V{ .array = .init(a) };
        for (@as(usize, @intCast(ordinal))..@min(capture.samples.len(), @as(usize, @intCast(ordinal + count)))) |i| {
            const sample = view.sample(capture, i, state.evidence_revision) orelse return error.StaleJitView;
            try samples.array.append(try wire.value(a, .{ .ordinal = sample.ordinal, .leaf = jit_frames.summary(sample.leaf), .frames = sample.frames.len, .frames_omitted = sample.frames_omitted }));
        }
        return wire.value(a, .{ .capture_id = capture.id, .revision = capture.revision, .samples = samples, .algorithm = "xodb-jit-code-lifetime/3", .peak_bytes = view.peak_bytes, .clock_claim = "operator_declared; see each source declaration", .pc_policy = "raw sampled leaf; return PC minus one for recorded user callers" });
    }
    if (eq(u8, name, "get_jit_stack") or eq(u8, name, "get_jit_candidates")) {
        try wire.fields(args, &.{ "capture_id", "revision", "ordinal", "frame", "start", "limit" });
        const capture = session.profile orelse return error.NoProfile;
        if (try wire.number(args, "capture_id", null) != capture.id or try wire.number(args, "revision", null) != capture.revision) return error.StaleProfile;
        const ordinal = try wire.number(args, "ordinal", null);
        if (ordinal >= capture.samples.len()) return error.JitSampleRange;
        const view = state.jit_view orelse return error.JitViewRequired;
        const sample = view.sample(capture, @intCast(ordinal), state.evidence_revision) orelse return error.StaleJitView;
        const start = try wire.number(args, "start", 0);
        const limit = try wire.number(args, "limit", 16);
        if (limit == 0 or limit > 64) return error.InvalidArguments;
        var rows = V{ .array = .init(a) };
        var total: usize = 0;
        var label: ?jit_frames.Label = sample.leaf;
        if (eq(u8, name, "get_jit_stack")) {
            if (args.object.contains("frame")) return error.InvalidArguments;
            total = sample.frames.len;
            if (start <= total) for (@as(usize, @intCast(start))..@min(total, @as(usize, @intCast(start + limit)))) |i| try rows.array.append(try wire.value(a, .{ .index = i, .label = jit_frames.summary(sample.frames[i]) }));
        } else {
            if (try optionalIndex(args, "frame")) |index| {
                if (index >= sample.frames.len) return error.JitSampleRange;
                label = sample.frames[index];
            }
            if (label) |l| {
                total = l.candidates.len;
                if (start <= total) for (@as(usize, @intCast(start))..@min(total, @as(usize, @intCast(start + limit)))) |i| try rows.array.append(try wire.value(a, .{ .index = i, .candidate = l.candidates[i] }));
            }
        }
        if (start > total) return error.InvalidArguments;
        const end = @min(total, start + limit);
        return wire.value(a, .{ .capture_id = capture.id, .revision = capture.revision, .ordinal = ordinal, .leaf = jit_frames.summary(label), .rows = rows, .total = total, .next = if (end < total) @as(?u64, end) else null, .frames_omitted = sample.frames_omitted, .evidence_revision = state.evidence_revision });
    }
    if (eq(u8, name, "import_logical_frames")) {
        try wire.fields(args, &.{ "path", "kind", "jvm_kind", "replace" });
        const kind = std.meta.stringToEnum(model.Kind, try text(args, "kind")) orelse return error.FrameSourceUnsupported;
        if (@intFromEnum(kind) > @intFromEnum(model.Kind.coroutines)) return error.FrameSourceUnsupported;
        try state.importFile(try text(args, "path"), kind, try optionalIndex(args, "jvm_kind"), if (try optionalIndex(args, "replace")) |index| @as(usize, index) else null);
        return wire.value(a, .{ .status = "pending", .serial = state.serial });
    }
    if (eq(u8, name, "open_frame_bundle")) {
        try wire.fields(args, &.{"path"});
        const path = try text(args, "path");
        if (!std.mem.endsWith(u8, path, ".xof")) return error.FrameBundleExtension;
        try state.open(path);
        return wire.value(a, .{ .status = "pending", .serial = state.serial });
    }
    if (eq(u8, name, "cancel_frame_job")) {
        try wire.fields(args, &.{});
        state.cancel();
        return wire.value(a, .{ .status = if (state.job != null) "cancelling" else "idle" });
    }
    if (eq(u8, name, "save_frames")) {
        try wire.fields(args, &.{"path"});
        try state.save(try text(args, "path"));
        return wire.value(a, .{ .status = "pending", .serial = state.serial });
    }
    if (eq(u8, name, "get_frame_status")) {
        try wire.fields(args, &.{});
        var sources = V{ .array = .init(a) };
        for (state.sources[0..state.count], 0..) |source, index| {
            const s = source.?;
            if (s.jit_owner) |jit| {
                const input = jit.sources[0];
                try sources.array.append(try wire.value(a, .{ .index = index, .source_id = s.id[0..], .source_sha256 = s.input.sha256[0..64], .kind = @tagName(s.kind), .input_bytes = s.input.size, .read_stability = std.mem.span(c.xlf_stability_name(s.input.stability)), .declaration = s.metadata.jit, .metadata_provenance = "operator_declared", .algorithm = s.metadata.algorithm, .aggregate_stale = s.aggregate_stale, .complete = input.complete != 0, .partial = input.partial != 0, .tail_truncated = input.tail_truncated != 0, .records = input.records, .versions = jit.version_count, .diagnostics = jit.diag_count, .retained_bytes = if (state.job == null) @as(?usize, s.retained()) else null }));
                continue;
            }
            const d = s.doc();
            const h = d.header;
            var jvm: ?model.Owned(c.struct_jvm_evidence_info) = null;
            if (s.jvm_owner) |owner| {
                var info: c.struct_jvm_evidence_info = undefined;
                c.jvm_evidence_info(owner, &info);
                jvm = try model.own(a, info);
            }
            try sources.array.append(try wire.value(a, .{
                .index = index,
                .source_id = s.id[0..],
                .source_sha256 = s.input.sha256[0..64],
                .logical_sha256 = d.sha256_hex[0..64],
                .kind = @tagName(s.kind),
                .input_bytes = s.input.size,
                .read_stability = std.mem.span(c.xlf_stability_name(s.input.stability)),
                .language = try model.own(a, h.language),
                .implementation = try model.own(a, h.implementation),
                .runtime_version = try model.own(a, h.runtime_version),
                .source_kind = try model.own(a, h.source_kind),
                .method = try model.own(a, h.method),
                .trigger = try model.own(a, h.trigger),
                .atomicity = try model.own(a, h.atomicity),
                .notes = try model.own(a, h.notes),
                .producer = .{ .name = try model.own(a, h.producer_name), .version = try model.own(a, h.producer_version), .kind = try model.own(a, h.producer_kind), .sha256 = try model.own(a, h.producer_sha256) },
                .process = .{ .pid = h.pid, .start_ticks = try model.own(a, h.start_ticks), .boot_id = try model.own(a, h.boot_id), .unavailable = try model.own(a, h.process_unavailable) },
                .clock = .{ .known = h.has_clock, .domain = try model.own(a, h.clock_domain), .unavailable = try model.own(a, h.clock_unavailable) },
                .weight_unit = try model.own(a, h.weight_unit),
                .weight_semantics = try model.own(a, h.weight_semantics),
                .total_weight = try model.decimal(a, d.total_weight),
                .lost = try model.decimal(a, d.lost),
                .warnings = d.warnings,
                .input_incomplete = d.warnings & c.XLF_W_INCOMPLETE != 0,
                .ended = d.ended,
                .end_status = try model.own(a, d.end_status),
                .truncated_tail = d.truncated_tail,
                .threads = d.thread_count,
                .stacks = d.stack_count,
                .functions = d.function_count,
                .frames = d.frame_count,
                .algorithm = s.metadata.algorithm,
                .aggregate_stale = s.aggregate_stale,
                .selected_thread = s.metadata.selected_thread,
                .selection_stale = s.selection_stale,
                .jvm = jvm,
                // Query owns budget counters until its worker has joined.
                .retained_bytes = if (state.job == null) @as(?usize, s.retained()) else null,
                .peak_bytes = if (state.job == null) @as(?usize, s.peak) else null,
            }));
        }
        // Use the same retention check as saving. Sources remain inspectable,
        // but a completed import must not hide an unsavable attachment conflict.
        const conflict = blk: {
            _ = state.archiveSave() catch |err| break :blk err == error.ArchiveFrameAttachmentConflict;
            break :blk false;
        };
        const failure: ?anyerror = if (state.failure) |err| err else if (conflict) error.ArchiveFrameAttachmentConflict else null;
        return wire.value(a, .{ .status = if (state.busy()) "pending" else if (state.failure != null) "failed" else if (conflict) "conflict" else "ready", .error_name = if (failure) |err| @errorName(err) else null, .archive_attachment = state.attachment.status(), .diagnostic = if (state.diagnostic.status != c.XLF_OK) .{ .line = state.diagnostic.line, .offset = state.diagnostic.offset, .message = std.mem.sliceTo(&state.diagnostic.message, 0) } else null, .serial = state.serial, .source_count = state.count, .sources = sources, .working_limit = model.memory_limit, .input_limit = model.max_input, .page_limit = 64, .publication = state.publication, .native_bridge = "not_recorded" });
    }
    const allowed: []const []const u8 = if (eq(u8, name, "select_frame_aggregate")) &.{ "source", "source_id", "thread" } else if (eq(u8, name, "get_frame_citation")) &.{ "source", "source_id", "basis", "offset", "length" } else &.{ "source", "source_id", "start", "limit", "stack" };
    try wire.fields(args, allowed);
    const index = try wire.number(args, "source", 0);
    if (index >= state.count) return error.FrameSourceInvalid;
    const source = state.sources[@intCast(index)].?;
    if (!eq(u8, try text(args, "source_id"), &source.id)) return error.StaleFrameSource;
    if (eq(u8, name, "select_frame_aggregate")) {
        try state.select(@intCast(index), try optionalIndex(args, "thread"));
        return wire.value(a, .{ .status = "pending", .serial = state.serial });
    }
    if (eq(u8, name, "get_frame_citation")) {
        const basis = try text(args, "basis");
        var bytes: []const u8 = source.raw();
        if (eq(u8, basis, "logical")) {
            if (source.jit_owner != null) return error.FrameSourceNotLogical;
            if (source.jit_owner != null) return error.FrameSourceNotLogical;
            if (source.jvm_owner) |j| {
                var len: usize = 0;
                const ptr = c.jvm_evidence_lframes(j, &len);
                bytes = ptr[0..len];
            }
        } else if (!eq(u8, basis, "source")) return error.InvalidArguments;
        const offset = try wire.number(args, "offset", null);
        const length = try wire.number(args, "length", null);
        if (offset > bytes.len or length > bytes.len - offset or length > 4096) return error.FrameCitationRange;
        return wire.value(a, .{ .source_id = source.id[0..], .basis = basis, .offset = offset, .length = length, .encoding = "hex", .bytes = try std.fmt.allocPrint(a, "{x}", .{bytes[@intCast(offset)..][0..@intCast(length)]}) });
    }
    if (source.jit_owner != null) return error.FrameSourceNotLogical;
    const d = source.doc();
    const start = try wire.number(args, "start", 0);
    const limit = try wire.number(args, "limit", 32);
    if (limit == 0 or limit > 64) return error.InvalidArguments;
    var total: usize = 0;
    var rows = V{ .array = .init(a) };
    var summary: V = .null;
    if (eq(u8, name, "get_frame_aggregate")) {
        const agg = source.aggregate orelse return error.FrameAggregateStale;
        total = d.function_count;
        summary = try wire.value(a, .{ .algorithm = model.algorithm, .thread = agg.thread, .total_weight = agg.total, .partial_weight = agg.partial, .marker_weight = agg.marker, .unknown_leaf_weight = agg.unknown_leaf, .stacks = agg.stacks, .partial_stacks = agg.partial_stacks, .input_incomplete = agg.input_incomplete, .weight_unit = try model.own(a, d.header.weight_unit) });
        if (start <= total) for (@intCast(start)..@min(total, @as(usize, @intCast(start)) + @as(usize, @intCast(limit)))) |i| try rows.array.append(try wire.value(a, .{ .function = i, .self = agg.self[i], .inclusive = agg.inclusive[i], .name = try model.own(a, d.functions[i].name) }));
    } else if (eq(u8, name, "get_frame_threads")) {
        total = d.thread_count;
        if (start <= total) for (@intCast(start)..@min(total, @as(usize, @intCast(start)) + @as(usize, @intCast(limit)))) |i| {
            var jvm: ?model.Owned(c.struct_jvm_evidence_thread) = null;
            if (source.jvm_owner) |j| {
                var row: c.struct_jvm_evidence_thread = undefined;
                if (c.jvm_evidence_thread(j, @intCast(i), &row) == 0) jvm = try model.own(a, row);
            }
            try rows.array.append(try wire.value(a, .{ .index = i, .thread = try model.own(a, d.threads[i]), .jvm = jvm }));
        };
    } else if (eq(u8, name, "get_frame_stacks")) {
        total = d.stack_count;
        if (start <= total) for (@intCast(start)..@min(total, @as(usize, @intCast(start)) + @as(usize, @intCast(limit)))) |i| {
            const stack = d.stacks[i];
            var jvm: ?model.Owned(c.struct_jvm_evidence_stack) = null;
            if (source.jvm_owner) |j| {
                var row: c.struct_jvm_evidence_stack = undefined;
                if (c.jvm_evidence_stack(j, @intCast(i), &row) == 0) jvm = try model.own(a, row);
            }
            try rows.array.append(try wire.value(a, .{ .index = i, .stack = try model.own(a, stack), .state = std.mem.span(c.xlf_state_name(stack.state)), .weight = try std.fmt.allocPrint(a, "{d}", .{stack.weight}), .acquisition = try model.own(a, d.acquisitions[stack.acquisition]), .jvm = jvm }));
        };
    } else if (eq(u8, name, "get_frame_functions")) {
        total = d.function_count;
        if (start <= total) for (@intCast(start)..@min(total, @as(usize, @intCast(start)) + @as(usize, @intCast(limit)))) |i| {
            const f = d.functions[i];
            var jvm: ?model.Owned(c.struct_jvm_evidence_frame) = null;
            if (source.jvm_owner) |j| {
                var row: c.struct_jvm_evidence_frame = undefined;
                if (c.jvm_evidence_function(j, @intCast(i), &row) == 0) jvm = try model.own(a, row);
            }
            try rows.array.append(try wire.value(a, .{ .index = i, .function = try model.own(a, f), .kind = std.mem.span(c.xlf_kind_name(f.kind)), .code = if (f.code != c.XLF_NONE) try model.own(a, d.codes[f.code]) else null, .jvm = jvm }));
        };
    } else if (eq(u8, name, "get_frame_stack")) {
        const ordinal = try wire.number(args, "stack", null);
        if (ordinal >= d.stack_count) return error.FrameStackInvalid;
        const stack = d.stacks[@intCast(ordinal)];
        total = stack.frame_count;
        summary = try wire.value(a, .{ .stack = ordinal, .state = std.mem.span(c.xlf_state_name(stack.state)), .cite = stack.cite, .innermost_first = true });
        if (start <= total) for (@intCast(start)..@min(total, @as(usize, @intCast(start)) + @as(usize, @intCast(limit)))) |i| {
            const frame_index = stack.first_frame + i;
            const f = d.frames[frame_index];
            var jvm: ?model.Owned(c.struct_jvm_evidence_frame) = null;
            if (source.jvm_owner) |j| {
                var row: c.struct_jvm_evidence_frame = undefined;
                if (c.jvm_evidence_frame(j, @intCast(frame_index), &row) == 0) jvm = try model.own(a, row);
            }
            try rows.array.append(try wire.value(a, .{ .index = i, .frame = try model.own(a, f), .kind = std.mem.span(c.xlf_kind_name(f.kind)), .provenance = std.mem.span(c.xlf_provenance_name(f.provenance)), .function = if (f.function != c.XLF_NONE) try model.own(a, d.functions[f.function]) else null, .jvm = jvm, .native_authority = false }));
        };
    } else return error.UnknownTool;
    if (start > total) return error.InvalidArguments;
    const end = @min(total, start + limit);
    return wire.value(a, .{ .source_id = source.id[0..], .source = index, .start = start, .next = if (end < total) @as(?u64, end) else null, .total = total, .rows = rows, .summary = summary });
}
