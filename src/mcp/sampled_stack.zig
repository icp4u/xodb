//! Bounded raw evidence and asynchronous derived-stack inspection.
const std = @import("std");
const common = @import("profile.zig");
const Session = @import("../model/session.zig").Session;
const model = @import("../profile/capture.zig");
const records = @import("../profile/records.zig");
const unwind = @import("../profile/unwind.zig");
const aType = std.mem.Allocator;
const Value = std.json.Value;
pub const Summary = struct { status: enum { disabled, missing, captured, budget }, abi: u64 = 0, regs_present: bool = false, stack_size: u64 = 0, valid_bytes: u64 = 0, retained_bytes: u32 = 0, short: bool = false };
pub fn summary(capture: *const model.Capture, sample: anytype) Summary {
    if (capture.config.user_stack_bytes == 0) return .{ .status = .disabled };
    if (sample.user_state == 0 or sample.user_state > capture.user_state.count) return .{ .status = .missing };
    const entry = capture.user_state.entries[sample.user_state - 1];
    return .{ .status = if (entry.status == .budget) .budget else .captured, .abi = entry.state.abi, .regs_present = entry.state.regs_present, .stack_size = entry.state.stack_size, .valid_bytes = entry.state.stack_dyn, .retained_bytes = entry.state.stack_len, .short = entry.state.stack_short };
}
const Counts = struct {
    samples: usize = 0,
    registers: usize = 0,
    retained_stacks: usize = 0,
    budget_missing: usize = 0,
    kernel_stack_absent: usize = 0,
    state_missing: usize = 0,
    disabled: usize = 0,
    fn add(self: *Counts, state: Summary) void {
        self.samples += 1;
        self.registers += @intFromBool(state.regs_present);
        switch (state.status) {
            .disabled => self.disabled += 1,
            .missing => self.state_missing += 1,
            .budget => self.budget_missing += 1,
            .captured => if (state.retained_bytes != 0) {
                self.retained_stacks += 1;
            } else {
                self.kernel_stack_absent += 1;
            },
        }
    }
};
pub fn call(a: aType, session: *Session, name: []const u8, args: Value) !Value {
    const coverage = std.mem.eql(u8, name, "get_profile_stack_coverage");
    if (coverage) try common.fields(args, &.{ "capture_id", "revision", "tid", "tids", "from_ns", "to_ns", "start", "limit" }) else try common.fields(args, &.{ "capture_id", "revision", "sample", "stack_offset", "stack_limit", "reconstruct" });
    const capture = session.profile orelse return error.NoProfile;
    if (try common.number(args, "capture_id", null) != capture.id) return error.StaleCapture;
    if (try common.number(args, "revision", null) != capture.revision) return error.StaleProfile;
    if (coverage) {
        const filter = try common.readFilter(args);
        try capture.validateFilter(filter);
        const start = std.math.cast(usize, try common.number(args, "start", 0)) orelse return error.InvalidArguments;
        const limit = std.math.cast(usize, try common.number(args, "limit", 64)) orelse return error.InvalidArguments;
        if (limit == 0 or limit > 128) return error.InvalidArguments;
        const Row = struct { tid: u32, counts: Counts = .{} };
        var rows: std.ArrayList(Row) = .empty;
        var indices = std.AutoHashMap(u32, usize).init(a);
        var totals = Counts{};
        var invalid: usize = 0;
        for (0..capture.samples.len()) |ordinal| {
            const sample = capture.samples.core(ordinal);
            if (!sample.tidPresent() or !sample.timePresent() or sample.time_ns < capture.started_ns) {
                invalid += 1;
                continue;
            }
            if (!filter.contains(sample.tid, sample.time_ns - capture.started_ns)) continue;
            const state = summary(capture, sample);
            totals.add(state);
            const index = try indices.getOrPut(sample.tid);
            if (!index.found_existing) {
                index.value_ptr.* = rows.items.len;
                try rows.append(a, .{ .tid = sample.tid });
            }
            rows.items[index.value_ptr.*].counts.add(state);
        }
        std.mem.sort(Row, rows.items, {}, struct {
            fn less(_: void, x: Row, y: Row) bool {
                return x.tid < y.tid;
            }
        }.less);
        if (start > rows.items.len) return error.InvalidArguments;
        const end = @min(rows.items.len, start + limit);
        return common.value(a, .{ .capture_id = capture.id, .revision = capture.revision, .range = filter.clipped(capture.extentNs()), .totals = totals, .unfilterable_samples = invalid, .threads = rows.items[start..end], .total_threads = rows.items.len, .next = if (end < rows.items.len) @as(?usize, end) else null, .selection = "half-open time range relative to capture start; retention follows drain order, not a guaranteed chronological prefix" });
    }
    const ordinal = std.math.cast(usize, try common.number(args, "sample", null)) orelse return error.InvalidArguments;
    if (ordinal >= capture.samples.len()) return error.InvalidArguments;
    const offset = std.math.cast(usize, try common.number(args, "stack_offset", 0)) orelse return error.InvalidArguments;
    const limit = std.math.cast(usize, try common.number(args, "stack_limit", 256)) orelse return error.InvalidArguments;
    if (limit > 1024) return error.InvalidArguments;
    const reconstruct = if (args.object.get("reconstruct")) |v| switch (v) {
        .bool => v.bool,
        else => return error.InvalidArguments,
    } else true;
    const sample = capture.samples.get(ordinal);
    const state = summary(capture, sample);
    var raw: ?Value = null;
    if (sample.user_state != 0 and sample.user_state <= capture.user_state.count) {
        const entry = capture.user_state.entries[sample.user_state - 1];
        const bytes = capture.user_state.stack(entry);
        if (offset > bytes.len) return error.InvalidArguments;
        const end = @min(bytes.len, offset + limit);
        const Reg = struct { perf_index: usize, hex: []const u8 };
        var regs: std.ArrayList(Reg) = .empty;
        if (entry.state.regs_present) for (entry.state.regs, 0..) |reg, i| {
            if (entry.state.regs_mask & (@as(u64, 1) << @intCast(i)) != 0) try regs.append(a, .{ .perf_index = i, .hex = try std.fmt.allocPrint(a, "0x{x}", .{reg}) });
        };
        const hex = try a.alloc(u8, (end - offset) * 2);
        const digits = "0123456789abcdef";
        for (bytes[offset..end], 0..) |byte, i| {
            hex[2 * i] = digits[byte >> 4];
            hex[2 * i + 1] = digits[byte & 15];
        }
        raw = try common.value(a, .{ .abi = entry.state.abi, .regs_mask = entry.state.regs_mask, .registers = regs.items, .stack_address = if (entry.state.regs_present and entry.state.regs_mask & (1 << 7) != 0) try std.fmt.allocPrint(a, "0x{x}", .{entry.state.regs[7]}) else null, .stack_offset = offset, .stack_hex = hex, .next_offset = if (end < bytes.len) @as(?usize, end) else null });
    } else if (offset != 0) return error.InvalidArguments;
    const job = if (reconstruct) try session.requestProfileStack(@intCast(ordinal)) else null;
    var derived: ?Value = null;
    if (job) |j| if (j.reaped) {
        if (j.stack_result) |result| {
            const Frame = struct { pc: []const u8, sp: []const u8, lookup_pc: []const u8, mapping_id: u32, module_id: u64, name: []const u8, name_truncated: bool, cfi_method: ?[]const u8 };
            var frames: std.ArrayList(Frame) = .empty;
            for (result.frames[0..result.count]) |f| try frames.append(a, .{ .pc = try std.fmt.allocPrint(a, "0x{x}", .{f.pc}), .sp = try std.fmt.allocPrint(a, "0x{x}", .{f.sp}), .lookup_pc = try std.fmt.allocPrint(a, "0x{x}", .{f.lookup_pc}), .mapping_id = f.mapping_id, .module_id = f.module_id, .name = try a.dupe(u8, f.name[0..f.name_len]), .name_truncated = f.name_truncated, .cfi_method = f.method });
            derived = try common.value(a, .{ .algorithm = unwind.algorithm, .analysis_id = result.analysis_id[0..], .frames = frames.items, .terminal_reason = result.reason, .detail = result.detail, .mapping_coverage = @import("../profile/mappings.zig").coverage, .basis = "saved perf registers/stack, timestamped mappings, matching retained ELF bytes; original callchain unchanged" });
        }
    };
    return common.value(a, .{ .capture_id = capture.id, .revision = capture.revision, .sample = ordinal, .artifact_sha256 = if (session.artifact) |*artifact| try a.dupe(u8, &std.fmt.bytesToHex(artifact.source.archive_sha256, .lower)) else null, .state = state, .raw = raw, .job = if (job) |j| j.status() else null, .pending = if (job) |j| !j.reaped else false, .derived = derived });
}
