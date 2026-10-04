const std = @import("std");
const model = @import("../profile/imported.zig");
const State = @import("../profile/imported_job.zig").State;
const Value = std.json.Value;
pub const definitions = @embedFile("imported_tools.json");
fn asValue(a: std.mem.Allocator, object: anytype) !Value {
    return (try std.json.parseFromSlice(Value, a, try std.json.Stringify.valueAlloc(a, object, .{}), .{ .allocate = .alloc_always })).value;
}
fn number(args: Value, key: []const u8, default: u64) !u64 {
    const v = args.object.get(key) orelse return default;
    if (v != .integer or v.integer < 0) return error.InvalidArguments;
    return @intCast(v.integer);
}
fn time(args: Value, key: []const u8, default: u64) !u64 {
    const v = args.object.get(key) orelse return default;
    if (v != .string) return error.InvalidArguments;
    return model.integer(v.string) catch error.InvalidArguments;
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn clipped(value: []const u8, max: usize) []const u8 {
    var end = @min(value.len, max);
    while (end < value.len and end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return value[0..end];
}
fn decimal(a: std.mem.Allocator, n: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}
fn optionalDecimal(a: std.mem.Allocator, n: ?u64) !?[]const u8 {
    return if (n) |value| try decimal(a, value) else null;
}
pub fn call(a: std.mem.Allocator, state: *State, name: []const u8, args: Value) !Value {
    if (args != .object) return error.InvalidArguments;
    const info = equal(name, "get_imported_profile");
    const flames = equal(name, "get_imported_flamegraph");
    const sample_query = equal(name, "get_imported_sample");
    if (!info and !flames and !sample_query) return error.OfflineImportedProfile;
    const allowed: []const []const u8 = if (info) &.{ "start", "limit" } else if (flames)
        &.{ "import_id", "view_id", "tid", "tids", "from_ns", "to_ns", "start", "limit", "retry" }
    else
        &.{ "import_id", "ordinal", "start", "limit" };
    var fields = args.object.iterator();
    while (fields.next()) |field| {
        for (allowed) |key| {
            if (equal(field.key_ptr.*, key)) break;
        } else return error.InvalidArguments;
    }
    state.poll();
    if (info and state.profile == null) {
        return asValue(a, .{ .status = if (state.failure != null) "failed" else "pending", .error_name = if (state.failure) |err| @errorName(err) else null, .phase = if (state.load_job) |job| @tagName(job.progress.phase.load(.acquire)) else "complete", .completed_units = if (state.load_job) |job| job.progress.units.load(.acquire) else 0 });
    }
    const profile = state.profile orelse return error.ImportPending;
    const start_u64 = try number(args, "start", 0);
    const limit_u64 = try number(args, "limit", if (sample_query) 16 else 32);
    if (start_u64 > std.math.maxInt(usize) or limit_u64 == 0 or limit_u64 > (if (sample_query) @as(u64, 16) else 32)) return error.InvalidArguments;
    const start: usize = @intCast(start_u64);
    const limit: usize = @intCast(limit_u64);
    if (info) {
        if (start > profile.threads.len) return error.InvalidArguments;
        const end = @min(profile.threads.len, start + limit);
        const ThreadInfo = struct { tid: u32, name: []const u8, samples: usize };
        const threads = try a.alloc(ThreadInfo, end - start);
        for (threads, profile.threads[start..end]) |*out, thread| out.* = .{ .tid = thread.tid, .name = thread.name, .samples = thread.times.len };
        const command = clipped(profile.wire.source.command, 4096);
        const GuiFilter = struct { tid: ?u32, tids: ?[]const u32, from_ns: []const u8, to_ns: []const u8 };
        const gui_filter: ?GuiFilter = if (state.gui_filter) |*filter| .{ .tid = filter.tid, .tids = filter.tids.optional(), .from_ns = try decimal(a, filter.from_ns), .to_ns = try decimal(a, filter.to_ns) } else null;
        return asValue(a, .{ .status = "ready", .import_id = profile.digest[0..], .source_sha256 = profile.wire.source.sha256, .architecture = profile.wire.architecture, .event = profile.wire.event, .weight_unit = profile.wire.unit, .clock = profile.wire.clock, .first_sample_time_ns = try decimal(a, profile.first_ns), .extent_ns = try decimal(a, profile.extent_ns), .samples = profile.wire.samples.len, .total_period = try decimal(a, profile.total_period), .pid = profile.pid, .unresolved_stack_samples = profile.unresolved_samples, .labels = profile.wire.source.labels, .unwind_status = profile.wire.source.unwind_status, .record_command = command, .command_truncated = command.len != profile.wire.source.command.len, .loss = .{ .kernel_records = try optionalDecimal(a, profile.counter("kernelspace_lost_records")), .userspace_samples = try optionalDecimal(a, profile.counter("userspace_lost_samples")), .userspace_non_samples = try optionalDecimal(a, profile.counter("userspace_lost_non_samples")), .buffer_truncated_stacks = try optionalDecimal(a, profile.counter("userspace_truncated_stack_samples")) }, .thread_total = profile.threads.len, .start = start, .next = if (end < profile.threads.len) @as(?usize, end) else null, .threads = threads, .decoded_allocation_peak = profile.budget.peak, .gui = .{ .filter = gui_filter, .sample = state.gui_sample, .selected_node = state.gui_selected, .zoom = state.gui_zoom, .stack_start = state.gui_stack_start, .view_id = if (state.gui_view_id) |*id| id[0..] else null }, .filter_time_basis = "nanoseconds since earliest retained sample; half-open interval", .analysis_version = model.algorithm });
    }
    const identity = args.object.get("import_id") orelse return error.ImportIdentityRequired;
    if (identity != .string or !equal(identity.string, &profile.digest)) return error.StaleImport;
    if (flames) {
        var filter = model.Filter{ .from_ns = try time(args, "from_ns", 0), .to_ns = try time(args, "to_ns", std.math.maxInt(u64)) };
        try @import("profile.zig").readThreads(args, &filter);
        try profile.validateFilter(filter);
        const expected = profile.viewId(filter);
        if (args.object.get("view_id")) |view| if (view != .string or !equal(view.string, &expected)) return error.StaleProfileView;
        if (args.object.get("retry")) |retry| {
            if (retry != .bool) return error.InvalidArguments;
            if (retry.bool) state.retry(.mcp);
        }
        const view = switch (state.request(filter, .mcp)) {
            .pending => return asValue(a, .{ .status = "pending", .import_id = profile.digest[0..], .view_id = expected[0..] }),
            .failed => |err| return err,
            .ready => |view| view,
        };
        if (start > view.graph.nodes.items.len) return error.InvalidArguments;
        const end = @min(view.graph.nodes.items.len, start + limit);
        const Node = struct { id: u32, parent: ?u32, kind: treeKind, depth: u16, x: []const u8, inclusive_period: []const u8, self_period: []const u8, name: []const u8, name_truncated: bool, frame_index: ?u64, example_sample: ?usize };
        const nodes = try a.alloc(Node, end - start);
        for (nodes, view.graph.nodes.items[start..end]) |*out, node| {
            const label = clipped(node.frame.name, 512);
            out.* = .{ .id = node.id, .parent = node.parent, .kind = node.frame.kind, .depth = node.depth, .x = try decimal(a, node.x), .inclusive_period = try decimal(a, node.inclusive), .self_period = try decimal(a, node.self), .name = label, .name_truncated = label.len != node.frame.name.len, .frame_index = if (node.frame.kind == .code or node.frame.kind == .unknown) node.frame.address else null, .example_sample = if (view.examples[node.id] != std.math.maxInt(usize)) view.examples[node.id] else null };
        }
        return asValue(a, .{ .status = "ready", .import_id = profile.digest[0..], .view_id = view.id[0..], .weight_unit = profile.wire.unit, .samples = view.samples, .total_period = try decimal(a, view.total_period), .excluded_samples = view.graph.rejected, .excluded_period = try decimal(a, view.excluded_period), .unresolved_stack_samples = view.unresolved_samples, .node_total = view.graph.nodes.items.len, .start = start, .next = if (end < view.graph.nodes.items.len) @as(?usize, end) else null, .nodes = nodes });
    }
    const ordinal = try number(args, "ordinal", std.math.maxInt(u64));
    if (ordinal >= profile.wire.samples.len) return error.InvalidSample;
    const sample = profile.wire.samples[@intCast(ordinal)];
    if (start > sample.stack.len) return error.InvalidArguments;
    const end = @min(sample.stack.len, start + limit);
    const Row = struct { index: usize, frame_index: u32, ip: []const u8, vaddr: []const u8, name: []const u8, name_truncated: bool, module: []const u8, module_truncated: bool, build_id: ?[]const u8, resolved: bool, symbol_address: []const u8, symbol_size: []const u8, mapping_start: []const u8, mapping_end: []const u8, mapping_offset: []const u8 };
    const rows = try a.alloc(Row, end - start);
    for (rows, sample.stack[start..end], start..) |*out, site, index| {
        const frame = profile.wire.frames[site.frame];
        const module = profile.wire.modules[frame.module];
        const label = clipped(frame.name, 512);
        const path = clipped(module.path, 512);
        out.* = .{ .index = index, .frame_index = site.frame, .ip = site.ip, .vaddr = site.vaddr, .name = label, .name_truncated = label.len != frame.name.len, .module = path, .module_truncated = path.len != module.path.len, .build_id = module.build_id, .resolved = frame.resolved, .symbol_address = frame.symbol_address, .symbol_size = frame.symbol_size, .mapping_start = frame.mapping_start, .mapping_end = frame.mapping_end, .mapping_offset = frame.mapping_offset };
    }
    return asValue(a, .{ .import_id = profile.digest[0..], .ordinal = ordinal, .pid = sample.pid, .tid = sample.tid, .comm = sample.comm, .time_ns = sample.time_ns, .offset_ns = try decimal(a, profile.times[@intCast(ordinal)] - profile.first_ns), .period = sample.period, .unit = profile.wire.unit, .cpu = sample.cpu, .labels = profile.wire.source.labels, .unwind_status = profile.wire.source.unwind_status, .order = "root_to_leaf", .frame_total = sample.stack.len, .start = start, .next = if (end < sample.stack.len) @as(?usize, end) else null, .frames = rows });
}
const treeKind = @import("../profile/flame.zig").Kind;
