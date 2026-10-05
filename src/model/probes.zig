//! Bounded breakpoint policy and log evidence, executed by the session owner.
const std = @import("std");
const bp = @import("../target/breakpoints.zig");
pub const Text = struct {
    bytes: [512]u8 = undefined,
    len: u16 = 0,
    pub fn init(value: []const u8) !Text {
        if (value.len > 512) return error.BreakpointTextTooLong;
        var result: Text = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.write(self.slice());
    }
};
pub const Options = struct {
    condition: []const u8 = "",
    log_expression: []const u8 = "",
    thread_id: ?u64 = null,
    ignore_count: u64 = 0,
    mode: enum { stop, log } = .stop,
};
pub const Rule = struct {
    id: u64 = 0,
    condition: Text = .{},
    log_expression: Text = .{},
    thread_id: ?u64 = null,
    ignore_remaining: u64 = 0,
    matched_hits: u64 = 0,
    mode: @FieldType(Options, "mode") = .stop,
    last_error: ?[]const u8 = null,
};
pub const Log = struct {
    sequence: u64,
    breakpoint_id: u64,
    hit: u64,
    generation: u64,
    image_epoch: u64,
    tid: i32,
    time_ns: u64,
    pc: u64,
    expression: Text,
    display: Text,
    bits: ?u64,
    address: ?u64,
    diagnostic: ?[]const u8 = null,
};
pub const Manager = struct {
    rules: [128]Rule = @splat(.{}),
    logs: [256]Log = undefined,
    log_count: usize = 0,
    log_sequence: u64 = 0,
    dropped_logs: u64 = 0,
    processed_sequence: u64 = 0,
    pub fn rule(self: *Manager, id: u64) ?*Rule {
        for (&self.rules) |*item| if (item.id == id and id != 0) return item;
        return null;
    }
    pub fn prepare(id: u64, options: Options) !Rule {
        if (id == 0) return error.UnknownBreakpoint;
        return .{ .id = id, .condition = try Text.init(options.condition), .log_expression = try Text.init(options.log_expression), .thread_id = options.thread_id, .ignore_remaining = options.ignore_count, .mode = options.mode };
    }
    pub fn configure(self: *Manager, target: anytype, id: u64, options: Options, enabled: bool) !void {
        const candidate = try prepare(id, options);
        self.prune(target.breakpointSlice());
        var slot = self.rule(id);
        if (slot == null) for (&self.rules) |*item| {
            if (item.id == 0) {
                slot = item;
                break;
            }
        };
        const out = slot orelse return error.BreakpointLimit;
        try target.enableBreakpoint(id, enabled);
        out.* = candidate;
        target.invalidate();
    }
    fn prune(self: *Manager, probes: []const bp.Breakpoint) void {
        for (&self.rules) |*item| {
            if (item.id == 0) continue;
            for (probes) |probe| {
                if (probe.id == item.id) break;
            } else item.id = 0;
        }
    }
    fn push(self: *Manager, item: Log) void {
        if (self.log_count == self.logs.len) {
            std.mem.copyForwards(Log, self.logs[0 .. self.logs.len - 1], self.logs[1..]);
            self.log_count -= 1;
            self.dropped_logs += 1;
        }
        self.log_sequence += 1;
        self.logs[self.log_count] = item;
        self.logs[self.log_count].sequence = self.log_sequence;
        self.log_count += 1;
    }
    /// Evaluate once after all threads have stopped. Return whether every new
    /// breakpoint stop was filtered/logged and execution may safely continue.
    pub fn poll(self: *Manager, session: anytype, internal_id: ?u64) !bool {
        const target = &session.target;
        self.prune(target.breakpointSlice());
        if (target.snapshot().state != .stopped) return false;
        const after = self.processed_sequence;
        self.processed_sequence = target.snapshot().sequence;
        var hits: usize = 0;
        var keep_stopped = false;
        if (target.snapshot().event_count > 0 and after < target.eventSlice()[0].sequence - 1) {
            session.step_diagnostic = "BreakpointEventHistoryGap";
            keep_stopped = true;
        }
        for (target.threadSlice()) |thread| switch (thread.reason) {
            .none, .interrupt, .breakpoint => {},
            else => keep_stopped = true,
        };
        for (target.eventSlice()) |event| {
            if (event.sequence <= after or event.kind != .breakpoint_hit) continue;
            hits += 1;
            if (internal_id != null and event.detail == internal_id.?) continue;
            var loader = false;
            for (target.breakpointSlice()) |probe| if (probe.id == event.detail and probe.internal) {
                loader = true;
            };
            if (loader) continue;
            const rule_ = self.rule(@intCast(event.detail)) orelse {
                keep_stopped = true;
                continue;
            };
            rule_.last_error = null;
            defer if (rule_.last_error) |err| std.debug.print("xodb: breakpoint #{d} tid={d} stopped: {s}\n", .{ rule_.id, event.tid, err });
            if (rule_.thread_id) |wanted| {
                var matches = false;
                for (target.threadSlice()) |thread| if (thread.tid == event.tid and thread.id == wanted) {
                    matches = true;
                };
                if (!matches) continue;
            }
            rule_.matched_hits +|= 1;
            if (rule_.ignore_remaining > 0) {
                rule_.ignore_remaining -= 1;
                continue;
            }
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (rule_.condition.len > 0) {
                const value = session.evaluateExpression(a, event.tid, 0, rule_.condition.slice()) catch |err| {
                    rule_.last_error = @errorName(err);
                    keep_stopped = true;
                    continue;
                };
                if (value.availability != .available or value.type.kind == .structure or value.type.kind == .array or value.type.kind == .unknown) {
                    rule_.last_error = "BreakpointConditionUnavailable";
                    keep_stopped = true;
                    continue;
                }
                const truth = if (value.type.kind == .float) switch (value.type.size) {
                    4 => @as(f32, @bitCast(@as(u32, @truncate(value.bits)))) != 0,
                    8 => @as(f64, @bitCast(value.bits)) != 0,
                    else => {
                        rule_.last_error = "BreakpointConditionType";
                        keep_stopped = true;
                        continue;
                    },
                } else value.bits != 0;
                if (!truth) continue;
            }
            if (rule_.mode == .stop) {
                keep_stopped = true;
                continue;
            }
            var record = Log{ .sequence = 0, .breakpoint_id = rule_.id, .hit = rule_.matched_hits, .generation = target.snapshot().generation, .image_epoch = target.snapshot().image_epoch, .tid = event.tid, .time_ns = event.time_ns, .pc = event.pc, .expression = rule_.log_expression, .display = .{}, .bits = null, .address = null };
            if (rule_.log_expression.len > 0) {
                const value = session.evaluateExpression(a, event.tid, 0, rule_.log_expression.slice()) catch |err| {
                    rule_.last_error = @errorName(err);
                    record.diagnostic = rule_.last_error;
                    self.push(record);
                    keep_stopped = true;
                    continue;
                };
                const summary = try session.summarize(a, value);
                record.bits = summary.bits;
                record.address = summary.address;
                record.display = try Text.init(summary.display[0..@min(512, summary.display.len)]);
                if (summary.availability != .available) {
                    rule_.last_error = "LogValueUnavailable";
                    record.diagnostic = rule_.last_error;
                    keep_stopped = true;
                }
            }
            self.push(record);
        }
        return hits > 0 and !keep_stopped;
    }
};
