//! Explicit bounded headless observation recipes. No implicit file discovery,
//! stdout protocol, signal suppression or mutation of another owner's probes.
const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("../model/session.zig").Session;
const capture = @import("capture.zig");
const hooks = @import("../profile/uprobe_hooks.zig");
const linux = @import("../target/linux.zig");
pub const max_bytes = 64 * 1024;
pub const phase_timeout_ns: u64 = 30 * std.time.ns_per_s;
pub const preparation_timeout_ns: u64 = 60 * std.time.ns_per_s;
pub const cleanup_timeout_ns: u64 = 15 * std.time.ns_per_s;
pub const Recipe = struct {
    version: u16,
    start: ?[]const u8 = null,
    functions: []const []const u8,
    stop: ?[]const u8 = null,
    duration_ms: u32 = 10000,
    record_limit: u32 = 32768,
    memory_limit: u32 = 64 * 1024 * 1024,
    callstacks: bool = true,
    threshold_ns: u64 = 4000000,
    /// In a headless recipe, selected means the thread that reached start;
    /// without a phase it means the held leader, or first held surviving thread.
    threads: enum { selected, all_stopped } = .selected,
    pub fn config(self: Recipe) capture.Config {
        return .{ .duration_ms = self.duration_ms, .record_limit = self.record_limit, .memory_limit = self.memory_limit, .callstacks = self.callstacks };
    }
    pub fn validate(self: Recipe) !void {
        if (self.version != 1) return error.UnsupportedObservationRecipeVersion;
        if (self.duration_ms == 0 or self.functions.len == 0 or self.functions.len > hooks.max_hooks) return error.InvalidObservationRecipe;
        try self.config().validate();
        if (self.start) |name| try symbol(name);
        if (self.stop) |name| try symbol(name);
        for (self.functions, 0..) |name, i| {
            try symbol(name);
            if (self.start) |phase_name| if (std.mem.eql(u8, phase_name, name)) return error.ObservationFunctionBreakpointConflict;
            if (self.stop) |phase_name| if (std.mem.eql(u8, phase_name, name)) return error.ObservationFunctionBreakpointConflict;
            for (self.functions[0..i]) |old| if (std.mem.eql(u8, old, name)) return error.DuplicateObservationFunction;
        }
    }
};
pub const Parsed = std.json.Parsed(Recipe);
fn symbol(name: []const u8) !void {
    if (name.len == 0 or name.len > 256 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidObservationRecipeSymbol;
}
pub fn parse(a: std.mem.Allocator, bytes: []const u8) !Parsed {
    if (bytes.len > max_bytes) return error.ObservationRecipeTooLarge;
    var result = try std.json.parseFromSlice(Recipe, a, bytes, .{ .allocate = .alloc_always });
    errdefer result.deinit();
    try result.value.validate();
    return result;
}
pub fn load(a: std.mem.Allocator, path: [:0]const u8) !Parsed {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return error.ObservationRecipeOpenFailed;
    defer _ = c.close(fd);
    var info: c.struct_stat = undefined;
    if (c.fstat(fd, &info) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG) return error.ObservationRecipeNotRegular;
    if (info.st_size < 0 or info.st_size > max_bytes) return error.ObservationRecipeTooLarge;
    const bytes = try a.alloc(u8, max_bytes + 1);
    defer a.free(bytes);
    var count: usize = 0;
    while (count < bytes.len) {
        const n = c.read(fd, bytes.ptr + count, bytes.len - count);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0) return error.ObservationRecipeReadFailed;
        if (n == 0) return parse(a, bytes[0..count]);
        count += @intCast(n);
    }
    return error.ObservationRecipeTooLarge;
}
pub const Outcome = struct {
    reason: enum { stop_symbol, duration, target_exit, signal, unexpected_stop, cancelled, limit, scope_changed, collector_error, thread_exit },
    elapsed_ns: u64,
    capture_id: ?u64 = null,
};
const Phase = struct { id: u64, owned: bool };
const Resources = struct {
    start: ?Phase = null,
    stop: ?Phase = null,
    ran: bool = false,
    observation: bool = false,
};
fn phase(session: *Session, name: []const u8) !Phase {
    try session.refreshMaps();
    if (session.modules.findSymbol(name)) |found| {
        for (session.target.breakpointSlice()) |probe| if (!probe.pending and probe.address == found.address) {
            if (!probe.enabled or probe.internal) return error.ObservationPhaseBreakpointConflict;
            return .{ .id = probe.id, .owned = false };
        };
    } else |_| {}
    var before: [128]u64 = undefined;
    const count = session.target.breakpointSlice().len;
    for (session.target.breakpointSlice(), 0..) |probe, i| before[i] = probe.id;
    const id = try session.persistent.addSymbol(session, name);
    for (session.target.breakpointSlice()) |probe| if (probe.id == id and !probe.enabled) return error.ObservationPhaseBreakpointConflict;
    return .{ .id = id, .owned = std.mem.indexOfScalar(u64, before[0..count], id) == null };
}
fn hit(session: *const Session, p: Phase) ?i32 {
    // A breakpoint event can precede completion of the other threads' stops.
    // Phase removal and collector preparation require the whole held target.
    if (session.target.snapshot().state != .stopped) return null;
    for (session.target.breakpointSlice()) |probe| {
        if (probe.id != p.id or probe.pending) continue;
        for (session.target.threadSlice()) |thread| if (thread.state == .stopped and thread.reason == .breakpoint and thread.breakpoint_address == probe.address) return thread.tid;
    }
    return null;
}
fn removePhase(session: *Session, slot: *?Phase) !void {
    const p = slot.* orelse return;
    if (p.owned) {
        const state = session.target.snapshot().state;
        if (state == .stopped) {
            for (session.target.breakpointSlice()) |probe| if (probe.id == p.id) {
                try session.target.removeBreakpoint(p.id);
                break;
            };
        } else if (state != .exited and state != .idle) return error.ObservationRecipeCleanupRequiresStop;
        session.persistent.forget(p.id);
    }
    slot.* = null;
}
fn pause(session: *Session) !void {
    if (session.target.snapshot().state != .running) return;
    try session.target.interrupt();
    const started = linux.now();
    while (session.target.snapshot().state == .running) {
        if (linux.now() -| started > cleanup_timeout_ns) return error.ObservationRecipePauseTimeout;
        try session.poll();
        _ = c.usleep(1000);
    }
}
fn cleanup(session: *Session, resources: *Resources) !void {
    const previous = session.suppress_probe_resume;
    session.suppress_probe_resume = true;
    defer session.suppress_probe_resume = previous;
    if (resources.observation and session.observations.busy()) session.observations.stop(.cancelled);
    if (resources.ran) try pause(session);
    const started = linux.now();
    while (resources.observation and session.observations.busy()) {
        if (linux.now() -| started > cleanup_timeout_ns) return error.ObservationRecipeCleanupTimeout;
        try session.poll();
        _ = c.usleep(1000);
    }
    try removePhase(session, &resources.start);
    try removePhase(session, &resources.stop);
    if (session.target.snapshot().state == .stopped) try session.persistent.poll(session);
}
fn selectedThread(session: *const Session, preferred: ?i32) !i32 {
    if (preferred) |tid| for (session.target.threadSlice()) |thread| {
        if (thread.tid == tid and thread.state == .stopped) return tid;
    };
    for (session.target.threadSlice()) |thread| if (thread.tid == session.target.snapshot().pid and thread.state == .stopped) return thread.tid;
    for (session.target.threadSlice()) |thread| if (thread.state == .stopped) return thread.tid;
    return error.ObservationRecipeNoHeldThread;
}
fn stoppedOutcome(session: *const Session) @FieldType(Outcome, "reason") {
    for (session.target.threadSlice()) |thread| if (thread.state == .stopped and thread.signal != 0) return .signal;
    return .unexpected_stop;
}
fn functionMapping(session: *Session, recipe: *const Recipe, start_address: ?u64) !u64 {
    try session.refreshMaps();
    var found: ?u64 = null;
    for (session.modules.regions.items) |region| {
        if (region.permissions[2] != 'x' or region.inode == 0 or region.path.len == 0 or region.path[0] != '/') continue;
        const module = session.modules.load(region) catch continue;
        var all = true;
        var first: u64 = 0;
        for (recipe.functions, 0..) |name, i| {
            const location = hooks.resolve(&module.image, region, name, null) catch {
                all = false;
                break;
            };
            if (i == 0) first = location.runtime_address;
            if (start_address == location.runtime_address) return error.ObservationFunctionBreakpointConflict;
            for (session.target.breakpointSlice()) |probe| if (probe.enabled and !probe.pending and probe.address == location.runtime_address) return error.ObservationFunctionBreakpointConflict;
        }
        if (!all) continue;
        if (found != null and found.? != first) return error.AmbiguousObservationRecipeMapping;
        found = first;
    }
    return found orelse error.ObservationFunctionsRequireOneExecutableMapping;
}
fn execute(session: *Session, recipe: *const Recipe, quit: *volatile c.sig_atomic_t, resources: *Resources) !Outcome {
    const began = linux.now();
    if (session.target.snapshot().state != .stopped or session.offline or session.target.core != null) return error.ObservationRecipeRequiresStoppedLiveTarget;
    if (session.observations.busy()) return error.ObservationBusy;
    if (session.source_step != null or session.run_to != null) return error.StepInProgress;
    var selected: ?i32 = null;
    var start_address: ?u64 = null;
    if (quit.* != 0) return .{ .reason = .cancelled, .elapsed_ns = 0 };
    if (recipe.start) |name| {
        resources.start = try phase(session, name);
        if (hit(session, resources.start.?)) |tid| selected = tid else {
            resources.ran = true;
            try session.continueExecution(.human);
            while (true) {
                if (quit.* != 0) return .{ .reason = .cancelled, .elapsed_ns = linux.now() -| began };
                if (linux.now() -| began > phase_timeout_ns) return error.ObservationRecipeStartTimeout;
                try session.poll();
                if (hit(session, resources.start.?)) |tid| {
                    selected = tid;
                    break;
                }
                const state = session.target.snapshot().state;
                if (state == .exited or state == .idle) return .{ .reason = .target_exit, .elapsed_ns = linux.now() -| began };
                if (state == .stopped) return .{ .reason = stoppedOutcome(session), .elapsed_ns = linux.now() -| began };
                _ = c.usleep(1000);
            }
        }
        for (session.target.breakpointSlice()) |probe| if (probe.id == resources.start.?.id and !probe.pending) {
            start_address = probe.address;
            break;
        };
        try removePhase(session, &resources.start);
        try session.persistent.poll(session);
    }
    if (recipe.stop) |name| resources.stop = try phase(session, name);
    const mapping = try functionMapping(session, recipe, start_address);
    var tids: [32]i32 = undefined;
    var count: usize = 0;
    switch (recipe.threads) {
        .selected => {
            tids[0] = try selectedThread(session, selected);
            count = 1;
        },
        .all_stopped => for (session.target.threadSlice()) |thread| {
            if (thread.state == .exited) continue;
            if (thread.state != .stopped) return error.ObservationRecipeRequiresHeldThreads;
            if (count == tids.len) return error.ObservationRecipeThreadLimit;
            tids[count] = thread.tid;
            count += 1;
        },
    }
    if (count == 0) return error.ObservationRecipeNoHeldThread;
    var requests: [hooks.max_hooks]hooks.Request = undefined;
    for (recipe.functions, 0..) |name, i| requests[i] = .{ .id = @intCast(i + 1), .name = name };
    try session.startObservation(.human, tids[0..count], recipe.config(), mapping, requests[0..recipe.functions.len]);
    resources.observation = true;
    const preparing = linux.now();
    while (session.observations.preparation != null) {
        if (quit.* != 0) {
            session.observations.stop(.cancelled);
            return .{ .reason = .cancelled, .elapsed_ns = linux.now() -| began };
        }
        if (linux.now() -| preparing > preparation_timeout_ns) return error.ObservationRecipePreparationTimeout;
        try session.poll();
        _ = c.usleep(1000);
    }
    if (session.observations.err) |err| return err;
    if (session.observations.collector == null) return error.ObservationRecipeCollectorUnavailable;
    const id = session.observations.capture.?.identity.capture_id;
    resources.ran = true;
    try session.continueExecution(.human);
    var reason: @FieldType(Outcome, "reason") = .limit;
    while (session.observations.busy()) {
        if (quit.* != 0) {
            session.observations.stop(.cancelled);
            reason = .cancelled;
            break;
        }
        try session.poll();
        const state = session.target.snapshot().state;
        if (state == .exited or state == .idle) {
            session.observations.stop(.target_ended);
            reason = .target_exit;
            break;
        }
        if (state == .stopped) {
            if (resources.stop != null and hit(session, resources.stop.?) != null) reason = .stop_symbol else reason = stoppedOutcome(session);
            session.observations.stop(.manual);
            break;
        }
        if (session.observations.capture.?.stop_reason) |why| {
            reason = switch (why) {
                .duration => .duration,
                .collector_error => .collector_error,
                .scope_changed, .mapping_changed, .image_changed => .scope_changed,
                .thread_ended => .thread_exit,
                .target_ended => .target_exit,
                .cancelled, .shutdown => .cancelled,
                else => .limit,
            };
            break;
        }
        _ = c.usleep(1000);
    }
    if (session.observations.capture.?.stop_reason == .duration) reason = .duration;
    return .{ .reason = reason, .elapsed_ns = linux.now() -| began, .capture_id = id };
}
/// Caller owns launch/attach, helper choice, archive publication and stdout.
/// On return, completed evidence remains in session.observations.capture. A
/// signal stop stays pending; the runner never suppresses or delivers it twice.
pub fn run(session: *Session, recipe: *const Recipe, quit: *volatile c.sig_atomic_t) !Outcome {
    try recipe.validate();
    var resources = Resources{};
    var outcome = execute(session, recipe, quit, &resources) catch |err| {
        cleanup(session, &resources) catch return error.ObservationRecipeCleanupFailed;
        return err;
    };
    try cleanup(session, &resources);
    // Perf can report the selected thread exit just before ptrace reports the
    // whole process exit; cleanup settles that distinction without guessing.
    if (outcome.reason == .thread_exit and session.target.snapshot().state == .exited) outcome.reason = .target_exit;
    return outcome;
}
test "observation recipe is strict bounded owned JSON with explicit defaults" {
    var bytes = [_]u8{'x'} ** 128;
    const text = "{\"version\":1,\"functions\":[\"observed_work\"],\"duration_ms\":25}";
    @memcpy(bytes[0..text.len], text);
    var parsed = try parse(std.testing.allocator, bytes[0..text.len]);
    defer parsed.deinit();
    @memset(&bytes, 'x');
    try std.testing.expectEqualStrings("observed_work", parsed.value.functions[0]);
    try std.testing.expect(parsed.value.duration_ms == 25 and parsed.value.start == null and parsed.value.stop == null and parsed.value.threads == .selected);
    for ([_][]const u8{
        "{\"version\":2,\"functions\":[\"f\"]}",
        "{\"version\":1,\"functions\":[]}",
        "{\"version\":1,\"functions\":[\"f\",\"f\"]}",
        "{\"version\":1,\"functions\":[\"f\"],\"start\":\"f\"}",
        "{\"version\":1,\"functions\":[\"f\"],\"stop\":\"f\"}",
        "{\"version\":1,\"functions\":[\"f\"],\"duration_ms\":0}",
        "{\"version\":1,\"functions\":[\"f\"],\"duration_ms\":86400001}",
        "{\"version\":1,\"functions\":[\"f\"],\"memory_limit\":100}",
        "{\"version\":1,\"functions\":[\"f\"],\"record_limit\":1}",
        "{\"version\":1,\"functions\":[\"f\"],\"typo\":true}",
        "{\"version\":1,\"functions\":[\"f\"],\"threads\":\"all\"}",
        "{\"version\":1,\"functions\":[\"f\\u0000x\"]}",
    }) |invalid| {
        if (parse(std.testing.allocator, invalid)) |value| {
            value.deinit();
            return error.InvalidRecipeAccepted;
        } else |_| {}
    }
    const huge = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(huge);
    try std.testing.expectError(error.ObservationRecipeTooLarge, parse(std.testing.allocator, huge));
}
