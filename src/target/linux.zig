const std = @import("std");
const c = @import("../c.zig").api;
const bp = @import("breakpoints.zig");
const arm_watch = @import("arm_watch.zig");
const runtime = @import("runtime.zig");
pub const architecture = @import("arch.zig").native;
pub const StopInfo = struct {
    tid: i32,
    reason: bp.StopReason,
    signal: i32,
    signal_name: []const u8,
    code: ?i32 = null,
    errno: ?i32 = null,
    fault_address: ?u64 = null,
    pc: ?u64 = null,
    read_only: bool = false,
    pending_delivery: bool = false,
    diagnostic: ?[]const u8 = null,
};
pub fn signalName(number: i32) []const u8 {
    return switch (number) {
        0 => "none",
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        5 => "SIGTRAP",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        10 => "SIGUSR1",
        11 => "SIGSEGV",
        12 => "SIGUSR2",
        13 => "SIGPIPE",
        14 => "SIGALRM",
        15 => "SIGTERM",
        17 => "SIGCHLD",
        18 => "SIGCONT",
        19 => "SIGSTOP",
        20 => "SIGTSTP",
        21 => "SIGTTIN",
        22 => "SIGTTOU",
        else => "signal",
    };
}
pub const State = enum { idle, running, stopped, exited };
pub const Thread = struct { id: u64, tid: c.pid_t, state: State, signal: c_int = 0, newborn: bool = false, interrupt_pending: bool = false, reason: bp.StopReason = .none, breakpoint_address: u64 = 0, saved_debug: ?bp.DebugRegisters = null, arm_watch_slots: ?u8 = null, arm_watch_hit: ?bp.ArmWatchHit = null };
pub const X86Registers = runtime.X86Registers;
pub const ArmRegisters = runtime.ArmRegisters;
pub const Registers = runtime.Registers;
pub fn programCounter(regs: Registers) u64 {
    return regs.dwarf(regs.architecture().pc()).?;
}
pub fn stackPointer(regs: Registers) u64 {
    return regs.dwarf(regs.architecture().sp()).?;
}
pub const Event = struct {
    sequence: u64,
    time_ns: u64,
    tid: c.pid_t,
    kind: enum { launch, attach, thread_start, thread_exiting, stop, continued, exit, detach, breakpoint_set, breakpoint_removed, breakpoint_hit, watchpoint_set, watchpoint_removed, watchpoint_hit, step_started, step_complete, memory_written, register_written, agent_action, image_replaced, process_birth, process_separated },
    detail: i64 = 0,
    pc: u64 = 0,
    address: u64 = 0,
    before: u64 = 0,
    after: u64 = 0,
    size: u8 = 0,
    other_threads_running: bool = false,
    trap_pc: ?u64 = null,
    trap_address: ?u64 = null,
    trap_code: ?i32 = null,
    watch_phase: enum { after_access, completed, interrupted } = .after_access,
    watch_attribution: enum { hardware_slot, single_armed_watch, candidate } = .hardware_slot,
    before_valid: bool = true,
    after_valid: bool = true,
};

pub const BirthKind = enum { fork, vfork, clone_unknown };
pub const Birth = struct { pid: i32, parent_tid: i32, kind: BirthKind, stopped: bool = false, exited: bool = false, status: i32 = 0, unpatched_probe: ?u64 = null, saved_debug: ?bp.DebugRegisters = null, vm_errno: i32 = 0 };
const rt = runtime.c;
pub fn now() u64 {
    return rt.xrt_now();
}
fn trace(request: c_uint, tid: c.pid_t, addr: usize, data: usize) !c_long {
    if (!@import("builtin").is_test) @compileError("test-only ptrace injection");
    const result = c.ptrace(@intCast(request), tid, addr, data);
    if (result == -1) {
        const err = std.c._errno().*;
        if (err == c.EPERM or err == c.EACCES) return error.PermissionDenied;
        if (err == c.ESRCH) return error.ProcessGone;
        return error.PtraceFailed;
    }
    return result;
}

pub const Snapshot = struct {
    pid: i32 = 0,
    state: State = .idle,
    owned: bool = false,
    follow_processes: bool = false,
    stepping: ?void = null,
    detach_pending: bool = false,
    want_run: bool = false,
    generation: u64 = 0,
    image_epoch: u64 = 0,
    sequence: u64 = 0,
    next_thread_id: u64 = 1,
    next_probe_id: u64 = 1,
    thread_count: usize = 0,
    event_count: usize = 0,
    breakpoint_count: usize = 0,
    birth_count: usize = 0,
};
fn debugSnapshot(v: rt.struct_xrt_debug_registers) bp.DebugRegisters {
    return .{ .address = v.address, .status = @intCast(v.status), .control = @intCast(v.control) };
}
fn armHit(v: rt.struct_xrt_arm_watch_hit) bp.ArmWatchHit {
    var hit = bp.ArmWatchHit{ .pc = v.pc, .address = v.address, .code = v.code, .other_threads_running = v.other_threads_running };
    for (&hit.before, 0..) |*item, i| item.* = if (v.before_valid[i]) v.before[i] else null;
    return hit;
}
fn threadSnapshot(v: rt.struct_xrt_thread) Thread {
    return .{ .id = v.id, .tid = v.tid, .state = @enumFromInt(v.state), .signal = v.signal, .newborn = v.newborn, .interrupt_pending = v.interrupt_pending, .reason = @enumFromInt(v.reason), .breakpoint_address = v.breakpoint_address, .saved_debug = if (v.has_saved_debug) debugSnapshot(v.saved_debug) else null, .arm_watch_slots = if (v.has_arm_watch_slots) v.arm_watch_slots else null, .arm_watch_hit = if (v.has_arm_watch_hit) armHit(v.arm_watch_hit) else null };
}
fn birthSnapshot(v: rt.struct_xrt_birth) Birth {
    return .{ .pid = v.pid, .parent_tid = v.parent_tid, .kind = @enumFromInt(v.kind), .stopped = v.stopped, .exited = v.exited, .status = v.status, .unpatched_probe = if (v.unpatched_probe != 0) v.unpatched_probe else null, .saved_debug = if (v.has_saved_debug) debugSnapshot(v.saved_debug) else null, .vm_errno = v.vm_errno };
}
/// C owns all live state. These arrays only adapt read-only C snapshots for the
/// existing host/JSON types; no operation writes them back to the runtime.
pub const Target = struct {
    handle: ?*rt.struct_xrt_target = null,
    core: ?@import("../binary/core.zig").Core = null,
    thread_cache: [1024]Thread = undefined,
    event_cache: [4096]Event = undefined,
    breakpoint_cache: [128]bp.Breakpoint = undefined,
    birth_cache: [1024]Birth = undefined,
    cached_sequence: u64 = 0,
    cached_events: usize = 0,
    new_thread_observer: ?struct {
        context: *anyopaque,
        before_resume: *const fn (*anyopaque, Thread, bool) void,
    } = null,
    fn get(self: *Target) !*rt.struct_xrt_target {
        if (self.handle == null) self.handle = rt.xrt_target_create() orelse return error.OutOfMemory;
        return self.handle.?;
    }
    pub fn arch(self: *const Target) @import("arch.zig").Arch {
        return if (self.core != null) .x86_64 else @enumFromInt(rt.xrt_target_arch(self.handle).*.machine);
    }
    pub fn isRemote(self: *const Target) bool {
        return rt.xrt_target_is_remote(self.handle);
    }
    pub fn connectRemote(self: *Target, argv: []const [:0]const u8) !void {
        if (self.handle != null or self.core != null) return error.ConflictingTargets;
        if (argv.len == 0 or argv.len > 255) return error.TooManyArguments;
        var raw: [256]?[*:0]const u8 = @splat(null);
        for (argv, 0..) |arg, i| raw[i] = arg.ptr;
        try runtime.check(rt.xrt_target_remote(@ptrCast(&raw), &self.handle));
    }
    fn rawView(self: *const Target) rt.struct_xrt_target_view {
        var view: rt.struct_xrt_target_view = undefined;
        rt.xrt_target_view(self.handle, &view);
        return view;
    }
    pub fn snapshot(self: *const Target) Snapshot {
        const v = self.rawView();
        return .{ .pid = v.pid, .state = @enumFromInt(v.state), .owned = v.owned, .follow_processes = v.follow_processes, .stepping = if (v.stepping) {} else null, .detach_pending = v.detach_pending, .want_run = v.want_run, .generation = v.generation, .image_epoch = v.image_epoch, .sequence = v.sequence, .next_thread_id = v.next_thread_id, .next_probe_id = v.next_probe_id, .thread_count = v.thread_count, .event_count = v.event_count, .breakpoint_count = v.breakpoint_count, .birth_count = v.birth_count };
    }
    pub fn threadSlice(self: *const Target) []const Thread {
        const v = self.rawView();
        for (0..v.thread_count) |i| @constCast(self).thread_cache[i] = threadSnapshot(v.threads[i]);
        return self.thread_cache[0..v.thread_count];
    }
    pub fn breakpointSlice(self: *const Target) []const bp.Breakpoint {
        const v = self.rawView();
        for (0..v.breakpoint_count) |i| {
            const p = v.breakpoints[i];
            @constCast(self).breakpoint_cache[i] = .{ .architecture = self.arch(), .id = p.id, .address = p.address, .original = p.original, .patched = p.patched, .enabled = p.enabled, .hit_count = p.hit_count, .pending = p.pending, .internal = p.internal, .temporary = p.temporary };
        }
        return self.breakpoint_cache[0..v.breakpoint_count];
    }
    pub fn watchpointSlice(self: *const Target) [4]?bp.Watchpoint {
        const v = self.rawView();
        var out: [4]?bp.Watchpoint = @splat(null);
        if (self.handle != null) for (&out, 0..) |*item, i| {
            const p = v.watchpoints[i];
            if (p.present) item.* = .{ .id = p.id, .address = p.address, .length = p.length, .kind = @enumFromInt(p.kind), .previous = p.previous };
        };
        return out;
    }
    pub fn birthSlice(self: *const Target) []const Birth {
        const v = self.rawView();
        for (0..v.birth_count) |i| @constCast(self).birth_cache[i] = birthSnapshot(v.births[i]);
        return self.birth_cache[0..v.birth_count];
    }
    pub fn eventSlice(self: *const Target) []const Event {
        const v = self.rawView();
        if (v.sequence != self.cached_sequence or v.event_count != self.cached_events) {
            for (0..v.event_count) |i| {
                const e = v.events[i];
                @constCast(self).event_cache[i] = .{ .sequence = e.sequence, .time_ns = e.time_ns, .tid = e.tid, .kind = @enumFromInt(e.kind), .detail = e.detail, .pc = e.pc, .address = e.address, .before = e.before, .after = e.after, .size = e.size, .other_threads_running = e.other_threads_running, .trap_pc = if (e.has_trap) e.trap_pc else null, .trap_address = if (e.has_trap) e.trap_address else null, .trap_code = if (e.has_trap) e.trap_code else null, .watch_phase = @enumFromInt(e.watch_phase), .watch_attribution = @enumFromInt(e.watch_attribution), .before_valid = e.before_valid, .after_valid = e.after_valid };
            }
            @constCast(self).cached_sequence = v.sequence;
            @constCast(self).cached_events = v.event_count;
        }
        return self.event_cache[0..v.event_count];
    }
    pub fn expectGeneration(self: *const Target, generation: u64) !void {
        try runtime.check(rt.xrt_target_expect(self.handle, generation));
    }
    pub fn invalidate(self: *Target) void {
        rt.xrt_target_invalidate(self.get() catch @panic("runtime allocation failed"));
    }
    pub fn event(self: *Target, kind: @FieldType(Event, "kind"), tid: i32, detail: i64) void {
        rt.xrt_target_event(self.get() catch @panic("runtime allocation failed"), @intFromEnum(kind), tid, detail);
    }
    pub fn launch(self: *Target, argv: []const [:0]const u8) !void {
        if (argv.len == 0) return error.InvalidState;
        var args: [256:null]?[*:0]const u8 = @splat(null);
        if (argv.len >= args.len) return error.TooManyArguments;
        for (argv, 0..) |arg, i| args[i] = arg.ptr;
        const status = rt.xrt_target_launch(try self.get(), @ptrCast(&args));
        if (status == rt.XRT_UNSUPPORTED_ARCHITECTURE) return error.UnsupportedTargetArchitecture;
        try runtime.check(status);
    }
    pub fn attach(self: *Target, pid: i32) !void {
        const status = rt.xrt_target_attach(try self.get(), pid);
        if (status == rt.XRT_UNSUPPORTED_ARCHITECTURE) return error.UnsupportedTargetArchitecture;
        try runtime.check(status);
    }
    pub fn sharedVm(self: *const Target) bool {
        return rt.xrt_target_shared_vm(self.handle);
    }
    pub fn familyRoot(self: *const Target) ?*const rt.struct_xrt_target {
        return rt.xrt_target_family_root(self.handle);
    }
    pub fn onlyInternalStops(self: *const Target) bool {
        return rt.xrt_target_only_internal_stops(self.handle);
    }
    pub fn stoppedTid(self: *const Target) !i32 {
        if (self.handle == null) return error.NotStopped;
        var tid: i32 = 0;
        try runtime.check(rt.xrt_target_stopped_tid(self.handle, &tid));
        return tid;
    }
    fn observe(context: ?*anyopaque, thread: [*c]const rt.struct_xrt_thread, same_group: bool) callconv(.c) void {
        const self: *Target = @ptrCast(@alignCast(context.?));
        if (self.new_thread_observer) |observer| observer.before_resume(observer.context, threadSnapshot(thread.*), same_group);
    }
    pub fn poll(self: *Target) !void {
        const handle = self.handle orelse return;
        rt.xrt_target_observer(handle, if (self.new_thread_observer != null) observe else null, self);
        defer rt.xrt_target_observer(handle, null, null);
        const status = rt.xrt_target_poll(handle);
        if (status == rt.XRT_UNSUPPORTED_ARCHITECTURE) return error.UnsupportedTargetArchitecture;
        try runtime.check(status);
    }
    pub fn reset(self: *Target) !void {
        if (self.handle) |handle| try runtime.check(rt.xrt_target_reset(handle));
    }
    pub fn deinit(self: *Target) void {
        if (self.core) |*core| {
            core.deinit();
            self.core = null;
        }
        if (self.handle) |handle| runtime.check(rt.xrt_target_destroy(handle)) catch |err| {
            std.debug.print("xodb: target cleanup failed: {s}; handle retained\n", .{@errorName(err)});
            return;
        };
        self.handle = null;
    }
    pub fn adoptChild(self: *Target, pid: i32, out: *Target) !Birth {
        var birth: rt.struct_xrt_birth = undefined;
        try runtime.check(rt.xrt_target_adopt(try self.get(), pid, try out.get(), &birth));
        return birthSnapshot(birth);
    }
    pub fn interrupt(self: *Target) !void {
        try runtime.check(rt.xrt_target_interrupt(try self.get()));
    }
    pub fn continueExecution(self: *Target) !void {
        try runtime.check(rt.xrt_target_continue(try self.get()));
    }
    pub fn waitStopped(self: *Target) !void {
        try runtime.check(rt.xrt_target_wait_stopped(try self.get()));
    }
    pub fn detach(self: *Target) !void {
        try runtime.check(rt.xrt_target_detach(try self.get()));
    }
    pub fn detachProcessFamily(self: *Target) !void {
        try runtime.check(rt.xrt_target_detach_family(try self.get()));
    }
    pub fn setFollowProcesses(self: *Target, enabled: bool) !void {
        try runtime.check(rt.xrt_target_set_following(try self.get(), enabled));
    }
    pub fn singleStep(self: *Target, tid: i32) !void {
        try runtime.check(rt.xrt_target_step(try self.get(), tid));
    }
    pub fn suppressSignal(self: *Target, tid: i32) !void {
        try runtime.check(rt.xrt_target_signal_suppress(try self.get(), tid));
    }
    pub fn resolveBreakpoint(self: *Target, id: u64, address: u64) !void {
        try runtime.check(rt.xrt_target_breakpoint_resolve(try self.get(), id, address));
    }
    pub fn withdrawBreakpoint(self: *Target, id: u64) !void {
        try runtime.check(rt.xrt_target_breakpoint_withdraw(try self.get(), id));
    }
    pub fn enableBreakpoint(self: *Target, id: u64, enabled: bool) !void {
        try runtime.check(rt.xrt_target_breakpoint_enable(try self.get(), id, enabled));
    }
    pub fn markBreakpointInternal(self: *Target, id: u64, internal: bool) !void {
        try runtime.check(rt.xrt_target_breakpoint_internal(try self.get(), id, internal));
    }
    pub fn restoreBreakpoint(self: *Target, id: u64, enabled: bool) !void {
        try runtime.check(rt.xrt_target_breakpoint_restore(try self.get(), id, enabled));
    }
    pub fn removeBreakpoint(self: *Target, id: u64) !void {
        try runtime.check(rt.xrt_target_breakpoint_remove(try self.get(), id));
    }
    pub fn removeWatchpoint(self: *Target, id: u64) !void {
        try runtime.check(rt.xrt_target_watchpoint_remove(try self.get(), id));
    }

    pub fn setBreakpoint(self: *Target, address: u64, temporary: bool) !u64 {
        var id: u64 = 0;
        try runtime.check(rt.xrt_target_breakpoint_set(try self.get(), address, temporary, &id));
        return id;
    }
    pub fn reserveBreakpoint(self: *Target) !u64 {
        var id: u64 = 0;
        try runtime.check(rt.xrt_target_breakpoint_reserve(try self.get(), &id));
        return id;
    }
    pub fn setWatchpoint(self: *Target, address: u64, length: u8, kind: bp.WatchKind) !u64 {
        var id: u64 = 0;
        try runtime.check(rt.xrt_target_watchpoint_set(try self.get(), address, length, @intFromEnum(kind), &id));
        return id;
    }
    pub fn watchpointCapacity(self: *const Target) !u8 {
        if (self.handle == null) return error.NotStopped;
        var capacity: u8 = 0;
        try runtime.check(rt.xrt_target_watchpoint_capacity(self.handle, &capacity));
        return capacity;
    }
    pub fn readMemory(self: *const Target, address: u64, dest: []u8) !usize {
        if (self.core) |*core| return core.read(address, dest);
        if (self.handle == null) return error.NotStopped;
        var count: usize = 0;
        try runtime.check(rt.xrt_target_read(self.handle, address, dest.ptr, dest.len, &count));
        return count;
    }
    pub fn writeMemory(self: *Target, address: u64, bytes: []const u8) !void {
        try runtime.check(rt.xrt_target_write(try self.get(), address, bytes.ptr, bytes.len));
    }
    pub fn registers(self: *const Target, tid: i32) !Registers {
        if (self.core) |*core| {
            if (architecture != .x86_64) return error.UnsupportedCoreArchitecture;
            return runtime.coreRegisters(&(try core.thread(tid)).regs);
        }
        if (self.handle == null) return error.UnknownThread;
        var regs: rt.struct_xrt_registers = undefined;
        try runtime.check(rt.xrt_target_registers(self.handle, tid, &regs));
        return .{ .raw = regs };
    }
    pub fn writeRegister(self: *Target, tid: i32, name: []const u8, value: u64) !void {
        try runtime.check(rt.xrt_target_register_write(try self.get(), tid, name.ptr, name.len, value));
    }
    fn index(self: *const Target, tid: i32) ?usize {
        for (self.threadSlice(), 0..) |thread, i| if (thread.tid == tid) return i;
        return null;
    }
    pub fn openCore(self: *Target, path: []const u8) !void {
        if (architecture != .x86_64) return error.UnsupportedCoreArchitecture;
        if (self.snapshot().pid != 0 or self.core != null or self.snapshot().thread_count != 0) return error.InvalidState;
        var core = try @import("../binary/core.zig").Core.open(std.heap.page_allocator, path);
        errdefer core.deinit();
        var threads: [1024]rt.struct_xrt_thread = undefined;
        if (core.threads.items.len > threads.len) return error.TooManyThreads;
        for (core.threads.items, 0..) |thread, i| threads[i] = std.mem.zeroInit(rt.struct_xrt_thread, .{ .tid = thread.tid, .state = rt.XRT_STOPPED, .signal = thread.signal, .reason = rt.XRT_STOP_SIGNAL });
        try runtime.check(rt.xrt_target_core(try self.get(), core.pid, &threads, core.threads.items.len));
        self.core = core;
    }
    pub fn stopInfo(self: *const Target, tid: i32) !StopInfo {
        const index_ = self.index(tid) orelse return error.UnknownThread;
        const t = self.threadSlice()[index_];
        if (t.state != .stopped) return error.NotStopped;
        var result = StopInfo{ .tid = tid, .reason = t.reason, .signal = t.signal, .signal_name = signalName(t.signal), .read_only = self.core != null, .pending_delivery = self.core == null and t.signal != 0 };
        result.pc = programCounter(try self.registers(tid));
        if (self.core) |*core| {
            // Linux supplies signal info for the dumping thread; GDB may
            // also emit per-thread records. Keep the note's thread association.
            if ((try core.thread(tid)).signal_info) |signal| {
                result.signal = signal.number;
                result.signal_name = signalName(signal.number);
                result.code = signal.code;
                result.errno = signal.errno;
                result.fault_address = signal.address;
            }
            return result;
        }
        if (t.reason != .signal and t.reason != .watchpoint and t.reason != .breakpoint and t.reason != .single_step) return result;
        var signal: runtime.SignalInfo = undefined;
        runtime.check(rt.xrt_target_signal_info(self.handle, tid, &signal)) catch |err| {
            result.diagnostic = @errorName(err);
            return result;
        };
        result.signal = signal.number;
        result.signal_name = signalName(result.signal);
        result.code = signal.code;
        result.errno = signal.error_number;
        if (signal.has_address and signal.number != c.SIGTRAP) result.fault_address = signal.address;
        return result;
    }
    pub fn extendedRegisters(self: *const Target, tid: i32) !@import("xstate.zig").State {
        if (self.core) |*core| {
            const thread = try core.thread(tid);
            // Portable legacy FP/XMM layout. Extended XSAVE components depend
            // on the producing CPU's layout, not this host's CPUID.
            const raw = thread.fp orelse thread.xstate orelse return error.ExtendedRegistersUnavailable;
            return @import("xstate.zig").decodeLegacy(raw);
        }
        const i = self.index(tid) orelse return error.UnknownThread;
        if (self.threadSlice()[i].state != .stopped) return error.NotStopped;
        var out: rt.struct_xrt_xstate = undefined;
        try runtime.check(rt.xrt_target_extended(self.handle, tid, &out));
        return @import("xstate.zig").fromRuntime(out);
    }

    /// Deliberate fault injection for regression tests only. Production code
    /// imports only xrt_target.h and cannot edit the private C state.
    pub fn testing(self: *Target) *@import("runtime_test.zig").c.struct_xrt_target {
        if (!@import("builtin").is_test) @compileError("test-only runtime access");
        return @ptrCast(@alignCast(self.get() catch @panic("runtime allocation failed")));
    }
};

fn injectArmHit(target: *Target, hit: bp.ArmWatchHit) void {
    const t = target.testing();
    t.threads[0].has_arm_watch_hit = true;
    t.threads[0].arm_watch_hit = std.mem.zeroInit(@TypeOf(t.threads[0].arm_watch_hit), .{ .pc = hit.pc, .address = hit.address, .code = hit.code, .other_threads_running = hit.other_threads_running });
    for (hit.before, 0..) |value, i| {
        t.threads[0].arm_watch_hit.before[i] = value orelse 0;
        t.threads[0].arm_watch_hit.before_valid[i] = value != null;
    }
}
fn testArmDebugBank(tid: i32, note: usize) !arm_watch.State {
    var state: arm_watch.State = .{};
    var io = c.iovec{ .iov_base = &state, .iov_len = @sizeOf(arm_watch.State) };
    _ = try trace(c.PTRACE_GETREGSET, tid, note, @intFromPtr(&io));
    _ = try arm_watch.count(state, io.iov_len);
    return state;
}

test "launch, inspect executable bytes, resume, discover clone, interrupt, cleanup" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try std.testing.expectEqual(State.stopped, target.snapshot().state);
    const regs = try target.registers(target.snapshot().pid);
    try std.testing.expect(programCounter(regs) != 0 and stackPointer(regs) != 0);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32), try target.readMemory(programCounter(regs), &bytes));
    try std.testing.expectError(error.MemoryUnreadable, target.readMemory(1, &bytes));
    try target.continueExecution();
    try std.testing.expectError(error.NotStopped, target.registers(target.snapshot().pid));
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().thread_count < 2 and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 2), target.snapshot().thread_count);
    try target.interrupt();
    try target.waitStopped();
    for (target.threadSlice()) |t| _ = try target.registers(t.tid);
    try std.testing.expect(target.eventSlice()[0].sequence < target.eventSlice()[target.snapshot().event_count - 1].sequence);
}

test "repeated pause requests do not queue stops after resume" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().thread_count < 2 and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 2), target.snapshot().thread_count);
    for (0..8) |_| {
        try target.interrupt();
        // Model stays running until the pending statuses are consumed.
        // A repeated user request must not issue another kernel interrupt.
        try target.interrupt();
        try target.waitStopped();
        for (target.threadSlice()) |t| {
            try std.testing.expect(!t.interrupt_pending);
            _ = try target.registers(t.tid);
        }
        try target.continueExecution();
        const until = now() + 30_000_000;
        while (now() < until) {
            try target.poll();
            try std.testing.expectEqual(State.running, target.snapshot().state);
            _ = c.usleep(1000);
        }
    }
}

test "delayed peer interrupt after continue does not stop the target again" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    // Force the race: stopPeers can INTERRUPT a task whose earlier kernel
    // stop is already waiting to be read. Linux queues a second stop.
    _ = try trace(c.PTRACE_INTERRUPT, target.snapshot().pid, 0, 0);
    try target.continueExecution();
    const until = now() + 50_000_000;
    while (now() < until) {
        try target.poll();
        try std.testing.expectEqual(State.running, target.snapshot().state);
        _ = c.usleep(1000);
    }
    // A subsequent explicit Pause must still stop every thread.
    try target.interrupt();
    try target.waitStopped();
    try std.testing.expectEqual(State.stopped, target.snapshot().state);
}

test "group stop after signal delivery is not a delayed peer interrupt" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try target.continueExecution();
    try std.testing.expectEqual(@as(c_int, 0), c.kill(target.snapshot().pid, c.SIGSTOP));
    try target.waitStopped();
    try std.testing.expectEqual(@as(c_int, c.SIGSTOP), target.threadSlice()[0].signal);
    try target.continueExecution(); // Deliver SIGSTOP; kernel reports EVENT_STOP/SIGSTOP.
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.interrupt, target.threadSlice()[0].reason);
    try std.testing.expectEqual(State.stopped, target.snapshot().state);
}

test "attach, inspect every thread, detach and preserve externally owned process" {
    try @import("../test_support.zig").requireLive();
    const pid = c.fork();
    if (pid == 0) {
        _ = c.execl("./zig-out/bin/xodb-fixture", "xodb-fixture", @as(?[*:0]const u8, null));
        c._exit(127);
    }
    try std.testing.expect(pid > 0);
    defer {
        _ = c.kill(pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
    }
    _ = c.usleep(100000);
    var target = Target{};
    defer target.deinit();
    try target.attach(pid);
    try std.testing.expectEqual(@as(usize, 2), target.snapshot().thread_count);
    for (target.threadSlice()) |t| _ = try target.registers(t.tid);
    try target.continueExecution();
    const until = now() + 30_000_000;
    while (now() < until) {
        try target.poll();
        try std.testing.expectEqual(State.running, target.snapshot().state);
        _ = c.usleep(1000);
    }
    try target.detach();
    try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, 0));
}

test "exit status is retained as an event" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/xodb-fixture", "exit" });
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.snapshot().state);
    try std.testing.expectEqual(@as(i64, 23), target.eventSlice()[target.snapshot().event_count - 1].detail);
}

test "missing executable reports failure without leaving an owned child" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try std.testing.expectError(error.ExecFailed, target.launch(&.{"/xodb-test-no-such-executable"}));
    try std.testing.expectEqual(@as(i32, 0), target.snapshot().pid);
}

test "signal delivery stop is preserved and forwarded on continue" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/xodb-fixture", "signal" });
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(@as(c_int, c.SIGUSR1), target.threadSlice()[0].signal);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.snapshot().state);
    try std.testing.expectEqual(@as(i64, -c.SIGUSR1), target.eventSlice()[target.snapshot().event_count - 1].detail);
}

fn rendezvous(target: *Target) !Registers {
    try target.launch(&.{ "./zig-out/bin/xodb-m1-fixture", "test" });
    try target.continueExecution();
    try target.waitStopped();
    const regs = try target.registers(target.snapshot().pid);
    try std.testing.expectEqual(@as(c_int, c.SIGTRAP), target.threadSlice()[0].signal);
    // This fixture's explicit INT3 is a program signal, not an installed breakpoint.
    try target.suppressSignal(target.snapshot().pid);
    return regs;
}

test "persistent software breakpoint rearm, original bytes, and single step" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    var original: [8]u8 = undefined;
    _ = try target.readMemory(start.named("rsi").?, &original);
    const id = try target.setBreakpoint(start.named("rsi").?, false);
    var visible: [8]u8 = undefined;
    _ = try target.readMemory(start.named("rsi").?, &visible);
    try std.testing.expectEqualSlices(u8, &original, &visible);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, target.threadSlice()[0].reason);
    try std.testing.expectEqual(start.named("rsi").?, programCounter(try target.registers(target.snapshot().pid)));
    try target.singleStep(target.snapshot().pid);
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.single_step, target.threadSlice()[0].reason);
    try std.testing.expect(programCounter(try target.registers(target.snapshot().pid)) != start.named("rsi").?);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, target.threadSlice()[0].reason);
    try std.testing.expectEqual(start.named("rsi").?, programCounter(try target.registers(target.snapshot().pid)));
    try target.removeBreakpoint(id);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.snapshot().state);
    try std.testing.expectEqual(@as(i64, 0), target.eventSlice()[target.snapshot().event_count - 1].detail);
}

test "hardware watchpoint captures both writes and continuing does not forward SIGTRAP" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    try std.testing.expectError(error.InvalidWatchRange, target.setWatchpoint(start.named("rdi").? + 1, 8, .write));
    const id = try target.setWatchpoint(start.named("rdi").?, 8, .write);
    for ([_]u64{ 12, 21 }, [_]u64{ 7, 12 }) |after, before| {
        try target.continueExecution();
        try target.waitStopped();
        try std.testing.expectEqual(bp.StopReason.watchpoint, target.threadSlice()[0].reason);
        var found: ?Event = null;
        for (target.eventSlice()) |e| if (e.kind == .watchpoint_hit) {
            found = e;
        };
        try std.testing.expectEqual(before, found.?.before);
        try std.testing.expectEqual(after, found.?.after);
        try std.testing.expectEqual(start.named("rdi").?, found.?.address);
        try std.testing.expect(found.?.pc != 0);
    }
    try target.removeWatchpoint(id);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.snapshot().state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.snapshot().state);
}

test "detach restores software and hardware breakpoints" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    const pid = target.snapshot().pid;
    _ = try target.setBreakpoint(start.named("rsi").?, false);
    _ = try target.setWatchpoint(start.named("rdi").?, 8, .write);
    try target.detach();
    var status: c_int = 0;
    try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    try std.testing.expect(c.WIFEXITED(status));
    try std.testing.expectEqual(@as(c_int, 0), c.WEXITSTATUS(status));
}

test {
    std.testing.refAllDecls(@import("lifecycle_test.zig"));
    std.testing.refAllDecls(arm_watch);
}

// Native, deterministic fault/signal injection at the run-control boundary.
// The hardware pre-access behavior is separately exercised through real MCP.
test "ARM64 watch completion handles a fault, signal and cancellation without invented values" {
    try @import("../test_support.zig").requireLive();
    if (architecture != .aarch64) return error.SkipZigTest;
    for (0..3) |mode| {
        var target = Target{};
        defer target.deinit();
        try target.launch(&.{ "./zig-out/bin/arm64-watch-fixture", "harness" });
        try target.continueExecution();
        try target.waitStopped();
        const start = try target.registers(target.snapshot().pid);
        try target.suppressSignal(target.snapshot().pid); // owned fixture rendezvous BRK
        const pc = if (mode == 0) start.x2 else start.x1;
        try target.writeRegister(target.snapshot().pid, "pc", pc);
        try target.writeRegister(target.snapshot().pid, "x1", 7);
        try target.writeRegister(target.snapshot().pid, "x2", 0);
        _ = try target.setWatchpoint(start.x0, 8, .write);
        injectArmHit(&target, .{ .pc = pc, .address = start.x0, .code = 4, .before = .{ 3, null, null, null } });
        if (mode == 1) try std.testing.expectEqual(@as(c_int, 0), c.kill(target.snapshot().pid, c.SIGUSR1));
        if (mode == 2) try target.interrupt();
        try target.waitStopped();
        var found = false;
        for (target.eventSlice()) |event_| if (event_.kind == .watchpoint_hit) {
            found = true;
            try std.testing.expect(event_.watch_phase == .interrupted and !event_.after_valid);
            try std.testing.expect(event_.before_valid and event_.before == 3);
            try std.testing.expectEqual(pc, event_.trap_pc.?);
        };
        try std.testing.expect(found);
        if (mode != 2) try std.testing.expectEqual(@as(c_int, if (mode == 0) c.SIGSEGV else c.SIGUSR1), target.threadSlice()[0].signal);
        // Recover this owned fixture and prove watches were rearmed.
        try target.suppressSignal(target.snapshot().pid);
        try target.writeRegister(target.snapshot().pid, "pc", start.x1);
        try target.continueExecution();
        try target.waitStopped();
        try std.testing.expectEqual(bp.StopReason.watchpoint, target.threadSlice()[0].reason);
        var after: ?u64 = null;
        for (target.eventSlice()) |event_| if (event_.kind == .watchpoint_hit and event_.after_valid) {
            after = event_.after;
        };
        try std.testing.expectEqual(@as(?u64, 7), after);
    }
}

test "ARM64 watch installation failure restores prior slots before resume" {
    try @import("../test_support.zig").requireLive();
    if (architecture != .aarch64) return error.SkipZigTest;
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/arm64-watch-fixture", "harness" });
    try target.continueExecution();
    try target.waitStopped();
    const start = try target.registers(target.snapshot().pid);
    try target.suppressSignal(target.snapshot().pid);
    _ = try target.setWatchpoint(start.x0, 8, .write);
    // A kernel-space address passes the generic range check but is forbidden
    // by ptrace. Apply the candidate bank directly to force a later-slot error.
    target.testing().watchpoints[1] = .{ .id = 99, .address = 0xffff000000000000, .length = 8, .kind = rt.XRT_WATCH_WRITE, .previous = 0, .present = true };
    target.testing().watchpoints_dirty = true;
    if (runtime.check(@import("runtime_test.zig").c.xrt_ensure_watches(target.testing()))) |_| return error.ExpectedWatchInstallFailure else |_| {}
    target.testing().watchpoints[1].present = false;
    target.testing().watchpoints_dirty = true;
    try target.writeRegister(target.snapshot().pid, "pc", start.x1);
    try target.writeRegister(target.snapshot().pid, "x1", 7);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.watchpoint, target.threadSlice()[0].reason);
    try std.testing.expect(!target.testing().watchpoints_dirty);
}

test "ARM64 watch refuses foreign data and instruction debug state" {
    try @import("../test_support.zig").requireLive();
    if (architecture != .aarch64) return error.SkipZigTest;
    for ([_]usize{ arm_watch.note, 0x402 }) |note| {
        var target = Target{};
        defer target.deinit();
        try target.launch(&.{ "./zig-out/bin/arm64-watch-fixture", "harness" });
        try target.continueExecution();
        try target.waitStopped();
        const start = try target.registers(target.snapshot().pid);
        try target.suppressSignal(target.snapshot().pid);
        const saved = try testArmDebugBank(target.snapshot().pid, note);
        const slots: u8 = @truncate(saved.info);
        var foreign: arm_watch.State = .{};
        foreign.registers[0] = .{ .address = if (note == arm_watch.note) start.x0 else start.x1, .control = if (note == arm_watch.note) 0x1ff1 else 0x1e1 };
        var io = c.iovec{ .iov_base = &foreign, .iov_len = 8 + @as(usize, slots) * 16 };
        _ = try trace(c.PTRACE_SETREGSET, target.snapshot().pid, note, @intFromPtr(&io));
        const before = try testArmDebugBank(target.snapshot().pid, note);
        try std.testing.expectError(if (note == arm_watch.note) error.ExistingHardwareWatchpoints else error.ExistingHardwareBreakpoints, target.setWatchpoint(start.x0 + 8, 8, .write));
        const after = try testArmDebugBank(target.snapshot().pid, note);
        try std.testing.expectEqualDeep(before, after);
        try std.testing.expect(!target.testing().watchpoints_dirty);
        for (target.watchpointSlice()) |watch| try std.testing.expect(watch == null);
    }
}

test "ARM64 watch restore failure suppresses owned traps and pending exit remains reapable" {
    try @import("../test_support.zig").requireLive();
    if (architecture != .aarch64) return error.SkipZigTest;
    for (0..2) |mode| {
        var target = Target{};
        defer target.deinit();
        try target.launch(&.{ "./zig-out/bin/arm64-watch-fixture", "harness" });
        try target.continueExecution();
        try target.waitStopped();
        const start = try target.registers(target.snapshot().pid);
        try target.suppressSignal(target.snapshot().pid);
        try target.writeRegister(target.snapshot().pid, "pc", start.x1);
        try target.writeRegister(target.snapshot().pid, "x1", 7);
        _ = try target.setWatchpoint(start.x0, 8, .write);
        _ = try target.setBreakpoint(start.x1, false);
        injectArmHit(&target, .{ .pc = start.x1, .address = start.x0, .code = 4, .before = .{ 3, null, null, null } });
        var started = false;
        try runtime.check(@import("runtime_test.zig").c.xrt_start_arm_watch_completion(target.testing(), &started));
        try std.testing.expect(started);
        if (mode == 0) {
            target.testing().watchpoints[1] = .{ .id = 99, .address = 0xffff000000000000, .length = 8, .kind = rt.XRT_WATCH_WRITE, .previous = 0, .present = true };
            try std.testing.expectError(error.PtraceFailed, target.waitStopped());
            try std.testing.expectEqual(@as(c_int, 0), target.threadSlice()[0].signal);
            try std.testing.expect(target.testing().watchpoints_dirty and target.snapshot().stepping != null);
            target.testing().watchpoints[1].present = false;
            try target.poll();
            try std.testing.expect(target.snapshot().stepping == null);
            try std.testing.expectEqual(@as(c_int, 0), target.threadSlice()[0].signal);
        } else {
            try std.testing.expectEqual(@as(c_int, 0), c.kill(target.snapshot().pid, c.SIGKILL));
            const deadline = now() + 3_000_000_000;
            while (target.snapshot().state != .exited and now() < deadline) {
                try target.poll();
                _ = c.usleep(1000);
            }
            try std.testing.expectEqual(State.exited, target.snapshot().state);
        }
    }
}

test "first instruction step after exec consumes the syscall completion trap" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-m1-fixture"});
    try std.testing.expectEqual(bp.StopReason.exec, target.threadSlice()[0].reason);
    const entry = programCounter(try target.registers(target.snapshot().pid));
    try target.singleStep(target.snapshot().pid);
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.single_step, target.threadSlice()[0].reason);
    try std.testing.expectEqual(@as(c_int, 0), target.threadSlice()[0].signal);
    try std.testing.expect(programCounter(try target.registers(target.snapshot().pid)) != entry);
}
