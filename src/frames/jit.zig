//! JIT attribution only. Process and clock declarations retain their provenance;
//! no filename, method name or timestamp supplies a missing fact.
const std = @import("std");
const c = @import("c.zig").api;
const Budget = @import("../profile/archive_budget.zig").Budget;
const Capture = @import("../profile/capture.zig").Capture;
pub const Clock = struct {
    kind: enum { unknown, monotonic, arch, other } = .unknown,
    scope: ?[]const u8 = null,
    pub fn toC(self: Clock) !c.struct_xodb_jit_clock {
        var out = std.mem.zeroes(c.struct_xodb_jit_clock);
        out.kind = @intFromEnum(self.kind);
        if (self.scope) |scope| {
            out.scope = try hexId(scope);
            out.scope_known = 1;
        }
        return out;
    }
};
pub const Declaration = struct {
    pid: u32,
    start_ticks: ?u64 = null,
    boot_id: ?[]const u8 = null,
    clock: Clock = .{},
    mapping: enum { none, offset, perf_tsc } = .none,
    target_clock: Clock = .{},
    offset: i64 = 0,
    mult: u32 = 0,
    shift: u16 = 0,
    zero: u64 = 0,
    uncertainty: u64 = 0,
    measured_by: ?[]const u8 = null,
    coverage_end: ?u64 = null,
    slack: u64 = 0,
    header_time_in_clock: bool = false,
    debug_address_bias: u64 = 0,
    label: ?[]const u8 = null,
    /// Operator-supplied clock evidence for a native CLOCK_MONOTONIC capture.
    /// It is never derived from boot_id alone (time namespaces can differ).
    capture_clock: Clock = .{},
    capture_clock_evidence: ?[]const u8 = null,
    pub fn toC(self: Declaration, a: std.mem.Allocator, sha: [*c]const u8) !c.struct_xodb_jit_source_meta {
        if (self.pid == 0 or self.pid > std.math.maxInt(i32)) return error.JitIdentityInvalid;
        if ((self.start_ticks == null) != (self.boot_id == null)) return error.JitIdentityInvalid;
        var out = std.mem.zeroes(c.struct_xodb_jit_source_meta);
        out.process.pid = self.pid;
        if (self.boot_id) |id| {
            out.process.boot_id = try hexId(id);
            out.process.start_ticks = self.start_ticks.?;
            out.process.known = 1;
        }
        out.clock = try self.clock.toC();
        out.map.target = try self.target_clock.toC();
        out.map.method = @intFromEnum(self.mapping);
        out.map.offset = self.offset;
        out.map.mult = self.mult;
        out.map.shift = self.shift;
        out.map.zero = self.zero;
        out.map.uncertainty = self.uncertainty;
        if (self.measured_by) |s| out.map.measured_by = try boundedZ(a, s);
        if (self.label) |s| out.label = try boundedZ(a, s);
        if (self.coverage_end) |end| {
            out.has_coverage_end = 1;
            out.coverage_end = end;
        }
        out.slack = self.slack;
        out.header_time_in_clock = @intFromBool(self.header_time_in_clock);
        out.debug_address_bias = self.debug_address_bias;
        out.artifact_sha256 = sha;
        const query_clock = try self.capture_clock.toC();
        if (query_clock.scope_known != 0) {
            if (self.capture_clock.kind != .monotonic) return error.JitCaptureClockInvalid;
            const basis = self.capture_clock_evidence orelse return error.JitCaptureClockEvidenceRequired;
            if (basis.len == 0 or basis.len > 4096 or std.mem.indexOfScalar(u8, basis, 0) != null) return error.JitCaptureClockEvidenceRequired;
        }
        return out;
    }
};
fn boundedZ(a: std.mem.Allocator, s: []const u8) ![:0]const u8 {
    if (s.len > 4096 or std.mem.indexOfScalar(u8, s, 0) != null) return error.JitMetadataInvalid;
    return a.dupeZ(u8, s);
}
pub fn hexId(s: []const u8) ![16]u8 {
    if (s.len != 32 and s.len != 36) return error.JitIdentityInvalid;
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (s, 0..) |b, i| {
        if (s.len == 36 and (i == 8 or i == 13 or i == 18 or i == 23)) {
            if (b != '-') return error.JitIdentityInvalid;
            continue;
        }
        if (n == 32) return error.JitIdentityInvalid;
        hex[n] = b;
        n += 1;
    }
    var out: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, &hex) catch return error.JitIdentityInvalid;
    return out;
}
pub fn check(status: c_int, index: c_int) !void {
    switch (status) {
        c.XODB_JIT_OK => {},
        c.XODB_JIT_E_BUDGET => if (index < 0) {
            return error.JitMemoryLimit;
        },
        c.XODB_JIT_E_NOMEM => return error.JitMemoryLimit,
        c.XODB_JIT_E_CANCELLED => return error.FrameCancelled,
        c.XODB_JIT_E_WORK => return error.JitWorkLimit,
        c.XODB_JIT_E_IDENTITY => return error.JitIdentityInvalid,
        c.XODB_JIT_E_CLOCK => return error.JitClockInvalid,
        else => return error.JitSourceInvalid,
    }
}
pub const scratch_bytes = 32768;
pub fn add(model: *c.struct_xodb_jit_model, declaration: Declaration, sha: [*c]const u8, bytes: []const u8, perfmap: bool, cancellation: *c.struct_xodb_jit_cancel) !void {
    // The C importer copies provenance strings before returning.
    var scratch: [scratch_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    const meta = try declaration.toC(fixed.allocator(), sha);
    var control = std.mem.zeroes(c.struct_xodb_jit_control);
    control.cancel = cancellation;
    var index: c_int = -1;
    const status = if (perfmap) c.xodb_jit_add_perfmap_ctl(model, &meta, bytes.ptr, bytes.len, &control, &index) else c.xodb_jit_add_jitdump_ctl(model, &meta, bytes.ptr, bytes.len, &control, &index);
    try check(status, index);
}
pub const Candidate = struct {
    source: usize,
    source_sha256: []const u8,
    version: u32,
    name: []const u8,
    name_encoding: []const u8,
    name_bytes: usize,
    name_truncated: bool,
    name_offset: usize,
    start: u64,
    size: u64,
    code_index: ?u64,
    begin: c.struct_xodb_jit_bound,
    end: c.struct_xodb_jit_bound,
    reasons: u32,
    state: u32,
    read_stability: []const u8,
};
pub const Label = struct {
    raw_pc: u64,
    lookup_pc: u64,
    outcome: []const u8,
    resolver_outcome: []const u8,
    read_stability: []const u8,
    reasons: u32,
    total_candidates: usize,
    total_exact: bool,
    candidates: []Candidate,
};
pub const Sample = struct { ordinal: usize, leaf: ?Label, frames: []?Label, frames_omitted: usize };
pub const View = struct {
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    capture_id: u64,
    capture_revision: u64,
    evidence_revision: u64,
    samples: []Sample = &.{},
    peak_bytes: usize = 0,
    pub fn deinit(self: *View) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
    pub fn sample(self: *const View, capture: *const Capture, ordinal: usize, revision: u64) ?*const Sample {
        if (self.capture_id != capture.id or self.capture_revision != capture.revision or self.evidence_revision != revision) return null;
        if (self.samples.len == 0 or ordinal < self.samples[0].ordinal or ordinal - self.samples[0].ordinal >= self.samples.len) return null;
        return &self.samples[ordinal - self.samples[0].ordinal];
    }
};
pub const Context = struct { process: c.struct_xodb_jit_process, clock_allowed: bool };
pub fn context(capture: *const Capture, source: ?@import("../profile/archive.zig").Source) Context {
    var out = Context{ .process = std.mem.zeroes(c.struct_xodb_jit_process), .clock_allowed = capture.producer == null and capture.accepted.clockid == 1 };
    const pid = if (source) |s| s.pid else capture.pid;
    if (pid <= 0) return out;
    out.process.pid = @intCast(pid);
    const boot = if (source) |s| s.boot_id else capture.boot_id;
    if (boot) |id| {
        for (capture.threads[0..capture.thread_count]) |thread| if (thread.perf.tid == pid and thread.perf.start_time_known) {
            out.process.start_ticks = thread.perf.start_time_ticks;
            out.process.boot_id = hexId(&id) catch return out;
            out.process.known = 1;
            break;
        };
    }
    return out;
}
/// Sources are pinned by the session job. All decoder work and resolution occurs
/// on this worker; GUI/MCP only read the completed copied labels.
pub fn build(sources: anytype, capture: *const Capture, ctx: Context, revision: u64, start: usize, count: usize, available: usize, cancellation: *c.struct_xodb_jit_cancel) !*View {
    if (capture.collector != null) return error.ArchiveStillCollecting;
    if (start > capture.samples.len() or count == 0 or count > 64) return error.JitSampleRange;
    if (available <= @sizeOf(View) + scratch_bytes) return error.JitMemoryLimit;
    const view = std.heap.page_allocator.create(View) catch return error.JitMemoryLimit;
    view.* = .{ .budget = .{ .backing = std.heap.page_allocator, .limit = available - @sizeOf(View) }, .arena = undefined, .capture_id = capture.id, .capture_revision = capture.revision, .evidence_revision = revision };
    view.arena = .init(view.budget.allocator());
    errdefer view.deinit();
    const a = view.arena.allocator();
    var limits: c.struct_xodb_jit_limits = undefined;
    c.xodb_jit_limits_default(&limits);
    limits.max_input_bytes = 64 * 1024 * 1024;
    // Reserve bounded temporary metadata storage in addition to the C model.
    limits.max_memory_bytes = view.budget.limit - scratch_bytes;
    var model: c.struct_xodb_jit_model = undefined;
    c.xodb_jit_model_init(&model, &limits);
    defer c.xodb_jit_model_free(&model);
    var source_indexes: [8]usize = undefined;
    var clock = std.mem.zeroes(c.struct_xodb_jit_clock);
    var has_clock = false;
    for (sources, 0..) |optional, index| {
        const source = optional orelse continue;
        const declaration = source.metadata.jit orelse continue;
        source_indexes[model.source_count] = index;
        try add(&model, declaration, &source.input.sha256, source.raw(), source.kind == .perfmap, cancellation);
        if (ctx.clock_allowed) {
            const declared = try declaration.capture_clock.toC();
            if (declared.scope_known != 0) {
                if (has_clock and c.xodb_jit_clock_equal(&clock, &declared) == 0) return error.JitConflictingCaptureClocks;
                clock = declared;
                has_clock = true;
            }
        }
    }
    if (model.source_count == 0) return error.JitSourcesRequired;
    view.peak_bytes = model.memory_peak + scratch_bytes + view.budget.peak + @sizeOf(View);
    if (model.memory > view.budget.limit - view.budget.used) return error.JitMemoryLimit;
    view.budget.limit -= model.memory;
    view.samples = a.alloc(Sample, @min(capture.samples.len() - start, count)) catch return error.JitMemoryLimit;
    for (view.samples, start..) |*out, ordinal| {
        if (c.xodb_jit_cancel_requested(cancellation) != 0) return error.FrameCancelled;
        const sample = capture.samples.get(ordinal);
        var query = c.struct_xodb_jit_query{ .process = ctx.process, .address = sample.ip, .has_time = @intFromBool(sample.time_present), .time = sample.time_ns, .clock = clock };
        const frames = a.alloc(?Label, @min(64, sample.frame_count)) catch return error.JitMemoryLimit;
        out.* = .{ .ordinal = ordinal, .leaf = if (sample.ip_present) try resolve(a, &model, sources, &source_indexes, &query, sample.ip, cancellation) else null, .frames = frames, .frames_omitted = sample.frame_count - frames.len };
        for (frames, sample.frames[0..frames.len]) |*frame, item| {
            frame.* = null;
            if (item.marker or item.context != .user) continue;
            query.address = item.address -| 1;
            frame.* = try resolve(a, &model, sources, &source_indexes, &query, item.address, cancellation);
        }
    }
    view.peak_bytes = @max(view.peak_bytes, model.memory + view.budget.peak + @sizeOf(View));
    return view;
}
fn resolve(a: std.mem.Allocator, model: *const c.struct_xodb_jit_model, sources: anytype, indexes: *const [8]usize, query: *const c.struct_xodb_jit_query, raw_pc: u64, cancellation: *c.struct_xodb_jit_cancel) !Label {
    var result: c.struct_xodb_jit_result = undefined;
    var control = std.mem.zeroes(c.struct_xodb_jit_control);
    control.cancel = cancellation;
    const rc = c.xodb_jit_resolve_ctl(model, query, &control, &result);
    if (rc == c.XODB_JIT_E_CANCELLED) return error.FrameCancelled;
    const candidates = a.alloc(Candidate, result.count) catch return error.JitMemoryLimit;
    var unverified_read = false;
    for (candidates, result.candidates[0..result.count]) |*out, candidate| {
        const version = model.versions[candidate.version - 1];
        const input = model.sources[version.source];
        const source_index = indexes[version.source];
        const source = sources[source_index].?;
        const name = input.bytes[version.name_offset..][0..version.name_len];
        const utf8 = std.unicode.utf8ValidateSlice(name) and std.mem.indexOfScalar(u8, name, 0) == null;
        const stable = source.input.stability == c.XLF_STABILITY_LEASED;
        unverified_read = unverified_read or !stable;
        var n = @min(name.len, 256);
        if (utf8) while (n < name.len and n > 0 and name[n] & 0xc0 == 0x80) : (n -= 1) {};
        out.* = .{ .source = source_index, .source_sha256 = try a.dupe(u8, source.input.sha256[0..64]), .version = version.id, .name = if (utf8) try a.dupe(u8, name[0..n]) else try std.fmt.allocPrint(a, "{x}", .{name[0..n]}), .name_encoding = if (utf8) "utf8" else "hex", .name_bytes = name.len, .name_truncated = n != name.len, .name_offset = version.name_offset, .start = version.start, .size = version.size, .code_index = if (version.has_code_index != 0) version.code_index else null, .begin = version.begin, .end = version.end, .reasons = candidate.reasons, .state = candidate.state, .read_stability = std.mem.span(c.xlf_stability_name(source.input.stability)) };
    }
    return .{ .raw_pc = raw_pc, .lookup_pc = query.address, .outcome = if (unverified_read and result.outcome == c.XODB_JIT_RESOLVED) "unverified" else std.mem.span(c.xodb_jit_outcome_name(result.outcome)), .resolver_outcome = std.mem.span(c.xodb_jit_outcome_name(result.outcome)), .read_stability = if (unverified_read) "unverified" else "stable", .reasons = result.reasons, .total_candidates = result.total, .total_exact = result.total_exact != 0, .candidates = candidates };
}

pub const Summary = struct {
    raw_pc: u64, lookup_pc: u64, outcome: []const u8, resolver_outcome: []const u8,
    read_stability: []const u8, reasons: u32, total_candidates: usize, total_exact: bool,
};
pub fn summary(label: ?Label) ?Summary {
    const l = label orelse return null;
    return .{ .raw_pc=l.raw_pc, .lookup_pc=l.lookup_pc, .outcome=l.outcome, .resolver_outcome=l.resolver_outcome, .read_stability=l.read_stability, .reasons=l.reasons, .total_candidates=l.total_candidates, .total_exact=l.total_exact };
}
