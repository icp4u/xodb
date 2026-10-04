const std = @import("std");
const c = @import("../c.zig").api;
const bp = @import("breakpoints.zig");
const arm_watch = @import("arm_watch.zig");
// PTRACE_GETSIGINFO uses the kernel layout; Bionic wraps these fields in C
// anonymous unions that translate-c cannot expose with glibc field names.
const SignalInfo = std.os.linux.siginfo_t;
comptime {
    std.debug.assert(@sizeOf(SignalInfo) == @sizeOf(c.siginfo_t));
    std.debug.assert(@alignOf(SignalInfo) == @alignOf(c.siginfo_t));
}
pub const architecture = @import("arch.zig").native;
// Save before installing debugger handlers. Ignored dispositions survive exec;
// restarted inferiors must receive the launcher's original configuration too.
pub const launch_signal_numbers = [_]std.posix.SIG{ .INT, .TERM, .HUP, .PIPE };
pub var launch_signals: ?[launch_signal_numbers.len]std.posix.Sigaction = null;

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
pub const X86Registers = struct {
    rip: u64,
    rsp: u64,
    rbp: u64,
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    eflags: u64,
};
pub const ArmRegisters = extern struct {
    x0: u64,
    x1: u64,
    x2: u64,
    x3: u64,
    x4: u64,
    x5: u64,
    x6: u64,
    x7: u64,
    x8: u64,
    x9: u64,
    x10: u64,
    x11: u64,
    x12: u64,
    x13: u64,
    x14: u64,
    x15: u64,
    x16: u64,
    x17: u64,
    x18: u64,
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64,
    x30: u64,
    sp: u64,
    pc: u64,
    pstate: u64,
};
pub const Registers = if (architecture == .aarch64) ArmRegisters else X86Registers;
pub fn programCounter(regs: Registers) u64 {
    return if (architecture == .aarch64) regs.pc else regs.rip;
}
pub fn stackPointer(regs: Registers) u64 {
    return if (architecture == .aarch64) regs.sp else regs.rsp;
}
const RawRegisters = if (architecture == .aarch64) ArmRegisters else c.struct_user_regs_struct;
fn getRegisters(tid: i32) !RawRegisters {
    var raw: RawRegisters = undefined;
    if (architecture == .aarch64) {
        var io = c.iovec{ .iov_base = &raw, .iov_len = @sizeOf(RawRegisters) };
        _ = try trace(c.PTRACE_GETREGSET, tid, 1, @intFromPtr(&io));
        if (io.iov_len != @sizeOf(RawRegisters)) return error.UnexpectedRegisterSize;
    } else _ = try trace(c.PTRACE_GETREGS, tid, 0, @intFromPtr(&raw));
    return raw;
}
fn setRegisters(tid: i32, raw: *const RawRegisters) !void {
    if (architecture == .aarch64) {
        var io = c.iovec{ .iov_base = @constCast(raw), .iov_len = @sizeOf(RawRegisters) };
        _ = try trace(c.PTRACE_SETREGSET, tid, 1, @intFromPtr(&io));
        if (io.iov_len != @sizeOf(RawRegisters)) return error.UnexpectedRegisterSize;
    } else _ = try trace(c.PTRACE_SETREGS, tid, 0, @intFromPtr(raw));
}
fn setPc(tid: i32, pc: u64) !void {
    var raw = try getRegisters(tid);
    if (architecture == .aarch64) raw.pc = pc else raw.rip = pc;
    try setRegisters(tid, &raw);
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

pub fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn trace(request: c_uint, tid: c.pid_t, addr: usize, data: usize) !c_long {
    const result = c.ptrace(@intCast(request), tid, addr, data);
    if (result == -1) {
        const err = std.c._errno().*;
        if (err == c.EPERM or err == c.EACCES) return error.PermissionDenied;
        if (err == c.ESRCH) return error.ProcessGone;
        return error.PtraceFailed;
    }
    return result;
}

/// Owns one Linux thread group. All ptrace calls stay on its creating OS thread.
pub const BirthKind = enum { fork, vfork, clone_unknown };
pub const Birth = struct { pid: i32, parent_tid: i32, kind: BirthKind, stopped: bool = false, exited: bool = false, status: i32 = 0, unpatched_probe: ?u64 = null, saved_debug: ?bp.DebugRegisters = null, vm_errno: i32 = 0 };
pub const Target = struct {
    core: ?@import("../binary/core.zig").Core = null,
    pid: c.pid_t = 0,
    owned: bool = false,
    follow_processes: bool = false,
    /// Each held parent thread can report at most one birth before it resumes.
    births: [1024]Birth = undefined,
    birth_count: usize = 0,
    inherited_rearm: bool = false,
    detach_pending: bool = false,
    birth_image_epoch: u64 = 0,
    birth_breakpoints: [128]bp.Breakpoint = undefined,
    birth_breakpoint_count: usize = 0,
    birth_watchpoints: [4]?bp.Watchpoint = @splat(null),
    birth_next_probe_id: u64 = 1,
    /// Targets must have stable addresses while this relationship is live.
    vfork_parent: ?*Target = null,
    vfork_children: [1024]?*Target = @splat(null),
    // Detached owned children still need a parent to reap them. Exiting traced
    // threads may also have a final wait status pending after detach.
    reap_tids: [2048]c.pid_t = undefined,
    reap_count: usize = 0,
    state: State = .idle,
    want_run: bool = false,
    threads: [1024]Thread = undefined,
    thread_count: usize = 0,
    next_thread_id: u64 = 1,
    events: [4096]Event = undefined,
    event_count: usize = 0,
    sequence: u64 = 0,
    generation: u64 = 0,
    image_epoch: u64 = 0,
    breakpoints: [128]bp.Breakpoint = undefined,
    breakpoint_count: usize = 0,
    watchpoints: [4]?bp.Watchpoint = @splat(null),
    next_probe_id: u64 = 1,
    stepping: ?bp.Step = null,
    watchpoints_dirty: bool = false,
    watch_cancelled: bool = false,
    /// Synchronous observer on the ptrace owner thread, before a newborn can
    /// execute user code. The owner installs this only for the duration of poll.
    new_thread_observer: ?struct {
        context: *anyopaque,
        before_resume: *const fn (*anyopaque, Thread, bool) void,
    } = null,

    pub fn openCore(self: *Target, path: []const u8) !void {
        if (architecture != .x86_64) return error.UnsupportedCoreArchitecture;
        if (self.pid != 0 or self.core != null or self.thread_count != 0) return error.InvalidState;
        var core = try @import("../binary/core.zig").Core.open(std.heap.page_allocator, path);
        errdefer core.deinit();
        for (core.threads.items, 0..) |thread, i| {
            self.threads[i] = .{ .id = self.next_thread_id, .tid = thread.tid, .state = .stopped, .signal = thread.signal, .reason = .signal };
            self.next_thread_id += 1;
        }
        self.thread_count = core.threads.items.len;
        self.pid = core.pid;
        self.state = .stopped;
        self.owned = false;
        self.want_run = false;
        self.generation += 1;
        self.image_epoch += 1;
        self.core = core;
    }
    pub fn threadSlice(self: *const Target) []const Thread {
        return self.threads[0..self.thread_count];
    }
    pub fn eventSlice(self: *const Target) []const Event {
        return self.events[0..self.event_count];
    }
    pub fn event(self: *Target, kind: @FieldType(Event, "kind"), tid: c.pid_t, detail: i64) void {
        self.sequence += 1;
        if (self.event_count == self.events.len) {
            std.mem.copyForwards(Event, self.events[0 .. self.events.len - 1], self.events[1..]);
            self.event_count -= 1;
        }
        self.events[self.event_count] = .{ .sequence = self.sequence, .time_ns = now(), .tid = tid, .kind = kind, .detail = detail };
        self.event_count += 1;
        self.generation += 1;
    }
    fn index(self: *const Target, tid: c.pid_t) ?usize {
        for (self.threadSlice(), 0..) |t, i| if (t.tid == tid) return i;
        return null;
    }
    fn add(self: *Target, tid: c.pid_t, newborn: bool) !void {
        if (self.index(tid) != null) return;
        if (self.thread_count == self.threads.len) return error.TooManyThreads;
        self.threads[self.thread_count] = .{ .id = self.next_thread_id, .tid = tid, .state = .running, .newborn = newborn };
        self.thread_count += 1;
        self.next_thread_id += 1;
    }
    fn options(owned: bool, follow: bool) usize {
        // On x86, even disabled following must hold a newborn before it can
        // execute inherited software traps. The coordinator chooses adoption
        // or explicit family release; no untraced child runs patched code.
        return c.PTRACE_O_TRACECLONE | c.PTRACE_O_TRACEEXEC | c.PTRACE_O_TRACEEXIT | (if (architecture == .x86_64 or follow) @as(usize, c.PTRACE_O_TRACEFORK | c.PTRACE_O_TRACEVFORK | c.PTRACE_O_TRACEVFORKDONE) else 0) | (if (owned) @as(usize, c.PTRACE_O_EXITKILL) else 0);
    }
    pub fn setFollowProcesses(self: *Target, enabled: bool) !void {
        if (architecture != .x86_64) return error.UnsupportedProcessFollowing;
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        if (self.sharedVm()) return error.SharedAddressSpace;
        const previous = self.follow_processes;
        errdefer for (self.threadSlice()) |thread| {
            if (thread.state == .stopped) _ = trace(c.PTRACE_SETOPTIONS, thread.tid, 0, options(self.owned, previous)) catch 0;
        };
        for (self.threadSlice()) |thread| if (thread.state == .stopped) {
            _ = try trace(c.PTRACE_SETOPTIONS, thread.tid, 0, options(self.owned, enabled));
        };
        self.follow_processes = enabled;
        self.generation += 1;
    }
    pub fn sharedVm(self: *const Target) bool {
        if (self.vfork_parent != null) return true;
        for (self.vfork_children) |child| if (child != null) return true;
        return false;
    }
    fn memoryMutationAllowed(self: *const Target) !void {
        if (self.detach_pending) return error.DetachIncomplete;
        if (self.birth_count != 0) return error.ProcessBirthPending;
        if (self.sharedVm()) return error.SharedAddressSpace;
    }
    fn executionAllowed(self: *const Target) !void {
        if (self.detach_pending) return error.DetachIncomplete;
        if (self.birth_count != 0) return error.ProcessBirthPending;
        for (self.vfork_children) |child| if (child != null) return error.VforkParentBlocked;
        if (self.vfork_parent != null) {
            var family: [32]*Target = undefined;
            for (@constCast(self).sharedFamily(&family)) |peer| {
                if (peer != self and (peer.state == .running or peer.birth_count != 0)) return error.SharedAddressSpacePeerRunning;
            }
        }
    }
    fn pollBirths(self: *Target) !void {
        for (self.births[0..self.birth_count]) |*birth| {
            if (birth.stopped or birth.exited) continue;
            var status: c_int = 0;
            const got = c.waitpid(birth.pid, &status, c.__WALL | c.WNOHANG);
            if (got == 0) continue;
            if (got < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.ChildWaitFailed;
            }
            birth.status = status;
            if (c.WIFEXITED(status) or c.WIFSIGNALED(status)) {
                birth.exited = true;
            } else if (c.WIFSTOPPED(status)) {
                birth.stopped = true;
                if (@as(u32, @intCast(status)) >> 16 != c.PTRACE_EVENT_STOP) return error.UnexpectedChildInitialStop;
            } else return error.UnexpectedChildInitialStop;
            self.generation += 1;
        }
    }
    /// Transfer an already held, kernel-reported child. Parent breakpoint
    /// mutations and resume are forbidden while any birth remains pending.
    pub fn adoptChild(self: *Target, pid: i32, out: *Target) !Birth {
        if (self.state != .stopped) return error.NotStopped;
        if (out.pid != 0 or out.thread_count != 0 or out.core != null) return error.InvalidState;
        var index_: ?usize = null;
        for (self.births[0..self.birth_count], 0..) |birth, i| if (birth.pid == pid) {
            index_ = i;
            break;
        };
        const i = index_ orelse return error.UnknownChild;
        const birth = self.births[i];
        if (!birth.stopped and !birth.exited) return error.ChildInitialStopPending;
        if (self.birth_image_epoch != self.image_epoch) return error.ParentImageChangedDuringBirth;
        var shared = false;
        if (!birth.exited) {
            const compared = c.syscall(@as(c_long, @intFromEnum(std.os.linux.SYS.kcmp)), @as(c.pid_t, birth.parent_tid), @as(c.pid_t, birth.pid), @as(c_int, 1), @as(c_ulong, 0), @as(c_ulong, 0)); // KCMP_VM
            if (compared < 0) {
                self.births[i].vm_errno = std.c._errno().*;
                return if (std.c._errno().* == c.EACCES or std.c._errno().* == c.EPERM) error.ChildVmComparisonDenied else error.ChildVmComparisonFailed;
            }
            shared = compared == 0;
            if (shared and birth.kind != .vfork) return error.SharedCloneRequiresCoordination;
        }
        var shared_slot: ?usize = null;
        if (shared) {
            var root = self;
            while (root.vfork_parent) |parent| root = parent;
            var family: [32]*Target = undefined;
            family[0] = root;
            var n: usize = 1;
            var at: usize = 0;
            while (at < n) : (at += 1) for (family[at].vfork_children) |child| if (child) |target| {
                if (n == family.len) return error.ProcessLimit;
                family[n] = target;
                n += 1;
            };
            if (n == family.len) return error.ProcessLimit;
            for (self.vfork_children, 0..) |child, slot| if (child == null) {
                shared_slot = slot;
                break;
            };
            if (shared_slot == null) return error.ProcessLimit;
        }
        out.* = .{ .pid = pid, .owned = self.owned, .follow_processes = self.follow_processes, .state = if (birth.exited) .exited else .stopped, .image_epoch = self.birth_image_epoch, .next_probe_id = self.birth_next_probe_id };
        if (!birth.exited) {
            out.threads[0] = .{ .id = out.next_thread_id, .tid = pid, .state = .stopped, .reason = .interrupt };
            out.next_thread_id += 1;
            out.thread_count = 1;
            out.breakpoint_count = if (shared) self.breakpoint_count else self.birth_breakpoint_count;
            @memcpy(out.breakpoints[0..out.breakpoint_count], if (shared) self.breakpoints[0..self.breakpoint_count] else self.birth_breakpoints[0..self.birth_breakpoint_count]);
            if (!shared) if (birth.unpatched_probe) |id| if (out.breakpointId(id)) |b| {
                out.breakpoints[b].patched = false;
            };
            out.inherited_rearm = !shared;
            out.watchpoints = self.birth_watchpoints;
            out.watchpoints_dirty = true;
            // The original user debug state precedes xodb's watches, even if
            // the kernel inherited the currently programmed registers.
            out.threads[0].saved_debug = birth.saved_debug;
            if (shared_slot) |slot| {
                self.vfork_children[slot] = out;
                out.vfork_parent = self;
            }
        }
        self.birth_count -= 1;
        self.births[i] = self.births[self.birth_count];
        out.event(.process_birth, pid, birth.parent_tid);
        self.generation += 1;
        return birth;
    }
    fn rearmInherited(self: *Target) !void {
        if (!self.inherited_rearm) return;
        for (self.breakpoints[0..self.breakpoint_count]) |*probe| if (probe.enabled and !probe.pending and !probe.patched) {
            try self.patchInstruction(probe.address, architecture.trap());
            probe.patched = true;
        };
        self.inherited_rearm = false;
    }
    fn sharedFamily(self: *Target, storage: *[32]*Target) []*Target {
        var root = self;
        while (root.vfork_parent) |parent| root = parent;
        storage[0] = root;
        var count: usize = 1;
        var at: usize = 0;
        while (at < count) : (at += 1) for (storage[at].vfork_children) |child| if (child) |target| {
            std.debug.assert(count < storage.len);
            storage[count] = target;
            count += 1;
        };
        return storage[0..count];
    }
    fn syncSharedPatch(self: *Target, id: u64, patched: bool) void {
        if (self.vfork_parent == null) return;
        var family: [32]*Target = undefined;
        for (self.sharedFamily(&family)) |peer| if (peer.breakpointId(id)) |b| {
            peer.breakpoints[b].patched = patched;
        };
    }
    fn separateVfork(self: *Target) !void {
        const parent = self.vfork_parent orelse return;
        // Exec/exit can interrupt a step whose original instruction was
        // unpatched in the shared image. Repair the surviving parent first.
        for (parent.breakpoints[0..parent.breakpoint_count]) |*probe| if (probe.enabled and !probe.pending and !probe.patched and parent.state == .stopped) {
            try parent.patchInstruction(probe.address, architecture.trap());
            probe.patched = true;
            self.syncSharedPatch(probe.id, true);
        };
        for (&parent.vfork_children) |*child| if (child.* == self) {
            child.* = null;
        };
        self.vfork_parent = null;
        parent.event(.process_separated, self.pid, 0);
    }
    pub fn launch(self: *Target, argv: []const [:0]const u8) !void {
        if (self.core != null) return error.ReadOnlyCore;
        if (self.pid != 0 or argv.len == 0) return error.InvalidState;
        var args: [256:null]?[*:0]const u8 = @splat(null);
        if (argv.len >= args.len) return error.TooManyArguments;
        for (argv, 0..) |arg, i| args[i] = arg.ptr;
        var gate: [2]c_int = undefined;
        if (c.pipe2(&gate, c.O_CLOEXEC) != 0) return error.PipeFailed;
        const pid = c.fork();
        if (pid < 0) {
            _ = c.close(gate[0]);
            _ = c.close(gate[1]);
            return error.ForkFailed;
        }
        if (pid == 0) {
            if (launch_signals) |*actions| for (launch_signal_numbers, actions) |number, *action| std.posix.sigaction(number, action, null);
            _ = c.close(gate[1]);
            var token: u8 = 0;
            if (c.read(gate[0], &token, 1) != 1) c._exit(126);
            _ = c.close(gate[0]);
            // Inferior output must never enter the MCP response stream.
            _ = c.dup2(2, 1);
            const input = c.open("/dev/null", c.O_RDONLY);
            if (input >= 0) {
                _ = c.dup2(input, 0);
                _ = c.close(input);
            }
            _ = c.execvp(args[0].?, @ptrCast(&args));
            c._exit(127);
        }
        _ = c.close(gate[0]);
        defer _ = c.close(gate[1]);
        self.pid = pid;
        self.owned = true;
        self.state = .running;
        errdefer self.deinit();
        _ = try trace(c.PTRACE_SEIZE, pid, 0, options(true, self.follow_processes));
        try self.add(pid, false);
        self.event(.launch, pid, 0);
        const token: u8 = 1;
        if (c.write(gate[1], &token, 1) != 1) return error.PipeFailed;
        try self.waitStopped();
        if (self.state == .exited) return error.ExecFailed;
        try self.validateNativeAbi();
    }
    pub fn attach(self: *Target, pid: c.pid_t) !void {
        if (self.core != null) return error.ReadOnlyCore;
        if (pid <= 1 or pid == c.getpid() or self.pid != 0) return error.InvalidPid;
        self.pid = pid;
        self.owned = false;
        self.state = .running;
        errdefer self.deinit();
        const deadline = now() + 3_000_000_000;
        var announced = false;
        // Stop each discovered thread promptly, then rescan after all-stop.
        // A running, not-yet-seized parent can clone behind readdir's cursor.
        while (now() < deadline) {
            var buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/task", .{pid});
            const dir = c.opendir(path) orelse return error.ProcessGone;
            defer _ = c.closedir(dir);
            var added = false;
            while (c.readdir(dir)) |entry| {
                const name_buf = entry.*.d_name;
                const name = std.mem.sliceTo(&name_buf, 0);
                const tid = std.fmt.parseInt(c.pid_t, name, 10) catch continue;
                if (self.index(tid) != null) continue;
                _ = trace(c.PTRACE_SEIZE, tid, 0, options(false, self.follow_processes)) catch |err| {
                    if ((err == error.ProcessGone or err == error.PermissionDenied) and isZombie(tid)) {
                        // Retain the leader for a worker's possible exec rename.
                        if (tid == pid) {
                            try self.add(tid, false);
                            self.threads[self.index(tid).?].state = .exited;
                        }
                        continue;
                    }
                    if (err == error.ProcessGone) continue;
                    // TRACECLONE may have seized this member before its parent
                    // event is polled. Verify both tracer and group membership.
                    if (err == error.PermissionDenied and self.thread_count > 0 and tracedMember(tid, pid)) {
                        try self.add(tid, true);
                        added = true;
                        continue;
                    }
                    // A short-lived task can disappear between SEIZE's EPERM
                    // and the status checks above. Only a confirmed exit/missing
                    // proc entry makes that denial ignorable; preserve real EPERM.
                    if (err == error.PermissionDenied and taskGone(tid)) continue;
                    return err;
                };
                try self.add(tid, false);
                added = true;
                try interruptThread(&self.threads[self.index(tid).?]);
            }
            if (self.thread_count == 0) return error.ProcessGone;
            if (!announced) {
                self.event(.attach, pid, 0);
                announced = true;
            }
            try self.interrupt();
            try self.waitStopped();
            if (self.state == .exited) return;
            if (!added) {
                try self.validateNativeAbi();
                return;
            }
        }
        return error.StopTimeout;
    }
    fn validateNativeAbi(self: *const Target) !void {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, "/proc/{d}/exe", .{try self.stoppedTid()});
        const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC);
        if (fd < 0) return error.TargetImageUnavailable;
        defer _ = c.close(fd);
        var header: [20]u8 = undefined;
        if (c.pread(fd, &header, header.len, 0) != header.len) return error.TargetImageUnavailable;
        if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1 or std.mem.readInt(u16, header[18..20], .little) != @intFromEnum(architecture)) return error.UnsupportedTargetArchitecture;
    }
    fn tracedMember(tid: c.pid_t, pid: c.pid_t) bool {
        var path: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&path, "/proc/{d}/status", .{tid}) catch return false;
        const fd = c.open(name, c.O_RDONLY);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        var bytes: [4096]u8 = undefined;
        const n = c.read(fd, &bytes, bytes.len);
        if (n <= 0) return false;
        var lines = std.mem.splitScalar(u8, bytes[0..@intCast(n)], '\n');
        var same_group = false;
        var same_tracer = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Tgid:")) same_group = (std.fmt.parseInt(i32, std.mem.trim(u8, line[5..], " \t"), 10) catch 0) == pid;
            if (std.mem.startsWith(u8, line, "TracerPid:")) same_tracer = (std.fmt.parseInt(i32, std.mem.trim(u8, line[10..], " \t"), 10) catch 0) == c.getpid();
        }
        return same_group and same_tracer;
    }
    fn taskGone(tid: c.pid_t) bool {
        var path: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{tid}) catch return false;
        const fd = c.open(name, c.O_RDONLY);
        if (fd < 0) return std.c._errno().* == c.ENOENT or std.c._errno().* == c.ESRCH;
        defer _ = c.close(fd);
        var bytes: [1024]u8 = undefined;
        const n = c.read(fd, &bytes, bytes.len);
        if (n < 0) return std.c._errno().* == c.ESRCH;
        if (n == 0) return false;
        const text = bytes[0..@intCast(n)];
        const end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
        return end + 2 < text.len and (text[end + 2] == 'Z' or text[end + 2] == 'X');
    }
    fn isZombie(tid: c.pid_t) bool {
        var path: [64]u8 = undefined;
        const name = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{tid}) catch return false;
        const fd = c.open(name, c.O_RDONLY);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        var bytes: [1024]u8 = undefined;
        const n = c.read(fd, &bytes, bytes.len);
        if (n <= 0) return false;
        const text = bytes[0..@intCast(n)];
        const end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
        return end + 2 < text.len and text[end + 2] == 'Z';
    }
    pub fn interrupt(self: *Target) !void {
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state == .idle or self.state == .exited) return error.InvalidState;
        self.watch_cancelled = true;
        try self.stopPeers();
    }
    fn stopPeers(self: *Target) !void {
        if (self.stepping) |*step| step.interrupted = true;
        self.want_run = false;
        for (self.threads[0..self.thread_count]) |*t| try interruptThread(t);
    }
    fn interruptThread(t: *Thread) !void {
        // A kernel stop may already be waitable while our model still says
        // running. Sending another interrupt then queues a stop after resume.
        // Auto-attached clones already have their initial EVENT_STOP pending.
        if (t.state != .running or t.interrupt_pending or t.newborn) return;
        _ = trace(c.PTRACE_INTERRUPT, t.tid, 0, 0) catch |err| {
            if (err != error.ProcessGone) return err;
            // ESRCH alone is ambiguous; /proc confirms the pre-attach exit.
            if (isZombie(t.tid)) t.state = .exited;
            return;
        };
        t.interrupt_pending = true;
    }
    pub fn continueExecution(self: *Target) !void {
        try self.executionAllowed();
        try self.rearmInherited();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        try self.ensureWatchpoints();
        for (self.threadSlice()) |t| if (t.arm_watch_hit != null) return error.WatchpointCompletionPending;
        // Execute original instructions one thread at a time, keeping peers stopped
        // while a shared software breakpoint is temporarily removed.
        for (self.threadSlice()) |t| {
            if (t.state != .stopped) continue;
            const regs = try self.registers(t.tid);
            if (t.breakpoint_address != 0 and t.breakpoint_address == programCounter(regs) and self.breakpointAt(programCounter(regs)) != null) {
                try self.beginStep(t.tid, false);
                return;
            }
        }
        self.want_run = true;
        // Keep the model accurate even when a later thread fails to resume.
        defer self.recomputeState();
        for (self.threads[0..self.thread_count]) |*t| {
            if (t.state != .stopped) continue;
            _ = try trace(c.PTRACE_CONT, t.tid, 0, @intCast(t.signal));
            t.signal = 0;
            t.reason = .none;
            t.state = .running;
        }
        self.state = .running;
        self.event(.continued, self.pid, 0);
    }
    fn breakpointAt(self: *const Target, address: u64) ?usize {
        for (self.breakpoints[0..self.breakpoint_count], 0..) |v, i| if (!v.pending and v.address == address) return i;
        return null;
    }
    fn breakpointId(self: *const Target, id: u64) ?usize {
        for (self.breakpoints[0..self.breakpoint_count], 0..) |v, i| if (v.id == id) return i;
        return null;
    }
    fn peek(tid: i32, request: c_uint, address: usize) !usize {
        std.c._errno().* = 0;
        const result = c.ptrace(@intCast(request), tid, address, @as(usize, 0));
        if (result == -1 and std.c._errno().* != 0) return error.MemoryUnreadable;
        return @bitCast(result);
    }
    pub fn stoppedTid(self: *const Target) !i32 {
        for (self.threadSlice()) |t| if (t.state == .stopped) return t.tid;
        return error.NotStopped;
    }
    fn patchByte(self: *Target, address: u64, byte: u8) !void {
        const tid = try self.stoppedTid();
        const aligned = address & ~@as(u64, 7);
        const shift: u6 = @intCast((address & 7) * 8);
        const old = try peek(tid, c.PTRACE_PEEKTEXT, aligned);
        _ = try trace(c.PTRACE_POKETEXT, tid, aligned, (old & ~(@as(u64, 255) << shift)) | (@as(u64, byte) << shift));
    }
    fn patchInstruction(self: *Target, address: u64, bytes: []const u8) !void {
        try patchInstructionTid(try self.stoppedTid(), address, bytes);
    }
    fn patchInstructionTid(tid: i32, address: u64, bytes: []const u8) !void {
        if (bytes.len != architecture.trap().len or (architecture == .aarch64 and address % 4 != 0)) return error.InvalidBreakpointAddress;
        const aligned = address & ~@as(u64, 7);
        const offset: usize = @intCast(address & 7);
        var word: [8]u8 = undefined;
        std.mem.writeInt(u64, &word, try peek(tid, c.PTRACE_PEEKTEXT, aligned), .little);
        @memcpy(word[offset..][0..bytes.len], bytes);
        _ = try trace(c.PTRACE_POKETEXT, tid, aligned, std.mem.readInt(u64, &word, .little));
    }
    pub fn setBreakpoint(self: *Target, address: u64, temporary: bool) !u64 {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        if (self.breakpointAt(address)) |i| return self.breakpoints[i].id;
        if (self.breakpoint_count == self.breakpoints.len) return error.BreakpointLimit;
        if (architecture == .aarch64 and address % 4 != 0) return error.InvalidBreakpointAddress;
        var original: [4]u8 = @splat(0);
        const bytes = original[0..architecture.trap().len];
        if (try self.readMemory(address, bytes) != bytes.len) return error.MemoryUnreadable;
        if (std.mem.eql(u8, bytes, architecture.trap())) return error.ExistingTrapInstruction;
        try self.patchInstruction(address, architecture.trap());
        const id = self.next_probe_id;
        self.next_probe_id += 1;
        self.breakpoints[self.breakpoint_count] = .{ .id = id, .address = address, .original = original, .temporary = temporary };
        self.breakpoint_count += 1;
        self.event(.breakpoint_set, self.pid, @intCast(id));
        self.events[self.event_count - 1].address = address;
        return id;
    }
    pub fn reserveBreakpoint(self: *Target) !u64 {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        if (self.breakpoint_count == self.breakpoints.len) return error.BreakpointLimit;
        const id = self.next_probe_id;
        self.next_probe_id += 1;
        self.breakpoints[self.breakpoint_count] = .{ .id = id, .address = 0, .original = @splat(0), .pending = true, .patched = false };
        self.breakpoint_count += 1;
        self.event(.breakpoint_set, self.pid, @intCast(id));
        return id;
    }
    pub fn resolveBreakpoint(self: *Target, id: u64, address: u64) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        const i = self.breakpointId(id) orelse return error.UnknownBreakpoint;
        if (!self.breakpoints[i].pending) return error.BreakpointAlreadyResolved;
        if (self.breakpointAt(address) != null) return error.BreakpointLocationAlreadyUsed;
        if (address == 0 or (architecture == .aarch64 and address % 4 != 0)) return error.InvalidBreakpointAddress;
        var original: [4]u8 = @splat(0);
        const bytes = original[0..architecture.trap().len];
        if (try self.readMemory(address, bytes) != bytes.len) return error.MemoryUnreadable;
        if (std.mem.eql(u8, bytes, architecture.trap())) return error.ExistingTrapInstruction;
        const probe = &self.breakpoints[i];
        if (probe.enabled) try self.patchInstruction(address, architecture.trap());
        probe.address = address;
        probe.original = original;
        probe.pending = false;
        probe.patched = probe.enabled;
        self.generation += 1;
    }
    pub fn withdrawBreakpoint(self: *Target, id: u64) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        const i = self.breakpointId(id) orelse return error.UnknownBreakpoint;
        const probe = &self.breakpoints[i];
        if (probe.patched) try self.patchInstruction(probe.address, probe.original[0..architecture.trap().len]);
        probe.address = 0;
        probe.patched = false;
        probe.pending = true;
        self.generation += 1;
    }
    pub fn enableBreakpoint(self: *Target, id: u64, enabled: bool) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        const i = self.breakpointId(id) orelse return error.UnknownBreakpoint;
        const probe = &self.breakpoints[i];
        if (probe.enabled == enabled) return;
        if (!probe.pending) try self.patchInstruction(probe.address, if (enabled) architecture.trap() else probe.original[0..architecture.trap().len]);
        probe.enabled = enabled;
        probe.patched = enabled and !probe.pending;
        self.generation += 1;
    }
    pub fn removeBreakpoint(self: *Target, id: u64) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        const i = self.breakpointId(id) orelse return error.UnknownBreakpoint;
        const v = self.breakpoints[i];
        if (v.patched) try self.patchInstruction(v.address, v.original[0..architecture.trap().len]);
        self.breakpoint_count -= 1;
        self.breakpoints[i] = self.breakpoints[self.breakpoint_count];
        self.event(.breakpoint_removed, self.pid, @intCast(id));
    }
    pub fn singleStep(self: *Target, tid: i32) !void {
        if (self.core != null) return error.ReadOnlyCore;
        try self.beginStep(tid, true);
    }
    fn beginStep(self: *Target, tid: i32, stop_after: bool) !void {
        try self.executionAllowed();
        try self.rearmInherited();
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        try self.ensureWatchpoints();
        const i = self.index(tid) orelse return error.UnknownThread;
        const regs = try self.registers(tid);
        var rearm: ?u64 = null;
        if (self.breakpointAt(programCounter(regs))) |b| if (self.breakpoints[b].enabled) {
            const v = &self.breakpoints[b];
            try self.patchInstruction(v.address, v.original[0..architecture.trap().len]);
            v.patched = false;
            self.syncSharedPatch(v.id, false);
            rearm = v.id;
        };
        errdefer if (rearm) |id| {
            if (self.breakpointId(id)) |b| {
                self.patchInstruction(self.breakpoints[b].address, architecture.trap()) catch {};
                self.breakpoints[b].patched = true;
                self.syncSharedPatch(id, true);
            }
        };
        _ = try trace(c.PTRACE_SINGLESTEP, tid, 0, @intCast(self.threads[i].signal));
        const exec_entry_pc: ?u64 = if (self.threads[i].reason == .exec) programCounter(regs) else null;
        self.threads[i].signal = 0;
        self.threads[i].reason = .none;
        self.threads[i].state = .running;
        self.stepping = .{ .tid = tid, .rearm = rearm, .stop_after = stop_after, .exec_entry_pc = exec_entry_pc };
        self.want_run = false;
        self.state = .running;
        self.event(.step_started, tid, 0);
    }
    fn finishStep(self: *Target, completed: bool) !void {
        const step = self.stepping orelse return;
        if (step.rearm) |id| if (self.breakpointId(id)) |b| {
            var live = false;
            for (self.threadSlice()) |thread| if (thread.state != .exited) {
                live = true;
            };
            // TRACEEXIT has no resumable address space when the last thread
            // exits. Do not strand it trying to reinsert an obsolete trap.
            if (live) {
                try self.patchInstruction(self.breakpoints[b].address, architecture.trap());
                self.breakpoints[b].patched = true;
                self.syncSharedPatch(id, true);
            }
        };
        if (step.watch) |hit| {
            if (self.index(step.tid)) |i| if (self.threads[i].state == .stopped) {
                self.configureWatchpoints(step.tid) catch |err| {
                    self.watchpoints_dirty = true;
                    return err;
                };
            };
            self.publishArmWatch(step.tid, hit, completed);
        }
        self.stepping = null;
    }
    fn debugOffset(index_: usize) usize {
        if (architecture != .x86_64) unreachable;
        return @offsetOf(c.struct_user, "u_debugreg") + index_ * @sizeOf(c_ulonglong);
    }
    fn setDebug(tid: i32, index_: usize, value: usize) !void {
        _ = try trace(c.PTRACE_POKEUSER, tid, debugOffset(index_), value);
    }
    fn configureWatchpoints(self: *Target, tid: i32) !void {
        if (architecture == .aarch64) return self.configureArmWatchpoints(tid, true);
        const i = self.index(tid) orelse return error.UnknownThread;
        if (self.threads[i].state == .exited) return;
        if (self.threads[i].saved_debug == null) {
            var saved: bp.DebugRegisters = undefined;
            for (0..4) |slot| saved.address[slot] = try peek(tid, c.PTRACE_PEEKUSER, debugOffset(slot));
            saved.status = try peek(tid, c.PTRACE_PEEKUSER, debugOffset(6));
            saved.control = try peek(tid, c.PTRACE_PEEKUSER, debugOffset(7));
            self.threads[i].saved_debug = saved;
        }
        try setDebug(tid, 7, 0);
        var control: usize = 0x400;
        for (self.watchpoints, 0..) |maybe, slot| {
            try setDebug(tid, slot, if (maybe) |v| v.address else 0);
            if (maybe) |v| {
                const len: usize = switch (v.length) {
                    1 => 0,
                    2 => 1,
                    4 => 3,
                    8 => 2,
                    else => unreachable,
                };
                const rw: usize = switch (v.kind) {
                    .write => 1,
                    .read_write => 3,
                    .execute => 0,
                };
                control |= @as(usize, 1) << @intCast(2 * slot);
                control |= (rw | (len << 2)) << @intCast(16 + 4 * slot);
            }
        }
        try setDebug(tid, 6, 0);
        try setDebug(tid, 7, control);
    }
    pub fn setWatchpoint(self: *Target, address: u64, length: u8, kind: bp.WatchKind) !u64 {
        if (self.birth_count != 0) return error.ProcessBirthPending;
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        if (architecture == .aarch64 and kind == .execute) return error.ExecutionWatchpointsUnsupported;
        try self.ensureWatchpoints();
        const capacity = try self.watchpointCapacity();
        if ((length != 1 and length != 2 and length != 4 and length != 8) or address % length != 0 or (kind == .execute and length != 1)) return error.InvalidWatchRange;
        var slot: ?usize = null;
        for (self.watchpoints[0..capacity], 0..) |v, i| if (v == null) {
            slot = i;
            break;
        };
        const index_ = slot orelse return error.WatchpointLimit;
        var bytes: [8]u8 = @splat(0);
        if (try self.readMemory(address, bytes[0..length]) != length) return error.MemoryUnreadable;
        const id = self.next_probe_id;
        self.next_probe_id += 1;
        self.watchpoints[index_] = .{ .id = id, .address = address, .length = length, .kind = kind, .previous = std.mem.readInt(u64, &bytes, .little) };
        self.applyWatchpoints() catch |err| {
            self.watchpoints[index_] = null;
            self.applyWatchpoints() catch {
                self.watchpoints_dirty = true;
            };
            return err;
        };
        self.event(.watchpoint_set, self.pid, @intCast(id));
        self.events[self.event_count - 1].address = address;
        return id;
    }
    pub fn removeWatchpoint(self: *Target, id: u64) !void {
        if (self.birth_count != 0) return error.ProcessBirthPending;
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped or self.stepping != null) return error.NotStopped;
        try self.ensureWatchpoints();
        for (&self.watchpoints) |*v| {
            if (v.* != null and v.*.?.id == id) {
                const saved = v.*;
                v.* = null;
                self.applyWatchpoints() catch |err| {
                    v.* = saved;
                    self.applyWatchpoints() catch {
                        self.watchpoints_dirty = true;
                    };
                    return err;
                };
                self.event(.watchpoint_removed, self.pid, @intCast(id));
                return;
            }
        }
        return error.UnknownWatchpoint;
    }
    fn armDebug(tid: i32) !arm_watch.State {
        return armDebugBank(tid, arm_watch.note);
    }
    fn armDebugBank(tid: i32, note: usize) !arm_watch.State {
        var state: arm_watch.State = .{};
        var io = c.iovec{ .iov_base = &state, .iov_len = @sizeOf(arm_watch.State) };
        _ = try trace(c.PTRACE_GETREGSET, tid, note, @intFromPtr(&io));
        _ = try arm_watch.count(state, io.iov_len);
        return state;
    }
    pub fn watchpointCapacity(self: *const Target) !u8 {
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        if (architecture == .x86_64) return 4;
        var capacity: u8 = 4;
        for (self.threadSlice()) |t| {
            if (t.state != .stopped) continue;
            const slots = t.arm_watch_slots orelse @as(u8, @truncate((try armDebug(t.tid)).info));
            capacity = @min(capacity, slots);
        }
        return capacity;
    }
    fn configureArmWatchpoints(self: *Target, tid: i32, enabled: bool) !void {
        const i = self.index(tid) orelse return error.UnknownThread;
        const thread = &self.threads[i];
        if (thread.state == .exited) return;
        if (thread.arm_watch_slots == null) {
            var armed = false;
            for (self.watchpoints) |watch| if (watch != null) {
                armed = true;
            };
            if (!armed) return;
            const saved = try armDebug(tid);
            const execution = try armDebugBank(tid, 0x402); // NT_ARM_HW_BREAK
            for (execution.registers) |reg| if (reg.address != 0 or reg.control & 1 != 0) return error.ExistingHardwareBreakpoints;
            // Unknown pre-existing state cannot reliably be restored on all
            // kernels. Refuse ownership instead of silently overwriting it.
            for (saved.registers) |reg| if (reg.address != 0 or reg.control & 1 != 0) return error.ExistingHardwareWatchpoints;
            // Disabled slots can retain type/length/privilege bits after our
            // clear+detach. Zero addresses with enable clear are empty slots.
            thread.arm_watch_slots = @truncate(saved.info);
        }
        const slots = thread.arm_watch_slots.?;
        if (enabled) for (self.watchpoints, 0..) |watch, slot| {
            if (watch != null and slot >= slots) return error.WatchpointLimit;
        };
        var state = arm_watch.request(slots, self.watchpoints, enabled);
        var io = c.iovec{ .iov_base = &state, .iov_len = 8 + @as(usize, slots) * 16 };
        // SETREGSET may fail after changing earlier slots. Callers retain the
        // previous logical configuration and roll it back before any resume.
        _ = try trace(c.PTRACE_SETREGSET, tid, arm_watch.note, @intFromPtr(&io));
    }
    fn applyWatchpoints(self: *Target) !void {
        for (self.threadSlice()) |t| try self.configureWatchpoints(t.tid);
        self.watchpoints_dirty = false;
    }
    fn ensureWatchpoints(self: *Target) !void {
        if (self.watchpoints_dirty) try self.applyWatchpoints();
    }
    fn watchValue(tid: i32, watch: bp.Watchpoint) ?u64 {
        var bytes: [8]u8 = @splat(0);
        var local = c.iovec{ .iov_base = &bytes, .iov_len = watch.length };
        var remote = c.iovec{ .iov_base = @ptrFromInt(watch.address), .iov_len = watch.length };
        if (c.process_vm_readv(tid, &local, 1, &remote, 1, 0) != watch.length) return null;
        return std.mem.readInt(u64, &bytes, .little);
    }
    fn watchTrapWithInfo(self: *Target, tid: i32, pc: u64, info: SignalInfo) !bool {
        if (architecture != .aarch64) return self.watchTrap(tid, pc);
        var armed = false;
        var hit = bp.ArmWatchHit{ .pc = pc, .address = @intFromPtr(info.fields.sigfault.addr), .code = info.code };
        for (self.watchpoints, 0..) |maybe, slot| if (maybe) |watch| {
            armed = true;
            hit.before[slot] = watchValue(tid, watch);
        };
        if (!armed) return false;
        for (self.threadSlice()) |t| if (t.tid != tid and t.state == .running) {
            hit.other_threads_running = true;
        };
        self.threads[self.index(tid).?].arm_watch_hit = hit;
        return true;
    }
    fn publishArmWatch(self: *Target, tid: i32, hit: bp.ArmWatchHit, completed: bool) void {
        var count: usize = 0;
        for (self.watchpoints) |watch| if (watch != null) {
            count += 1;
        };
        const regs = self.registers(tid) catch null;
        for (&self.watchpoints, 0..) |*maybe, slot| if (maybe.*) |*watch| {
            const after = if (completed) watchValue(tid, watch.*) else null;
            self.event(.watchpoint_hit, tid, @intCast(watch.id));
            const e = &self.events[self.event_count - 1];
            e.pc = if (regs) |r| programCounter(r) else hit.pc;
            e.trap_pc = hit.pc;
            e.trap_address = hit.address;
            e.trap_code = hit.code;
            e.watch_phase = if (completed) .completed else .interrupted;
            // Linux's reported access address can be outside the watched
            // subrange. With several watches, preserve all candidates rather
            // than inventing a slot from address containment.
            e.watch_attribution = if (count == 1) .single_armed_watch else .candidate;
            e.address = watch.address;
            e.size = watch.length;
            e.before = hit.before[slot] orelse 0;
            e.before_valid = hit.before[slot] != null;
            e.after = after orelse 0;
            e.after_valid = after != null;
            e.other_threads_running = hit.other_threads_running;
            if (after) |value| watch.previous = value;
        };
        if (!completed) std.debug.print("xodb: ARM64 watch access interrupted tid={d} trap_pc=0x{x}; completion unconfirmed\n", .{ tid, hit.pc });
    }
    fn startArmWatchCompletion(self: *Target) !bool {
        for (self.threads[0..self.thread_count]) |*thread| {
            const hit = thread.arm_watch_hit orelse continue;
            if (self.watch_cancelled or thread.state != .stopped) {
                self.publishArmWatch(thread.tid, hit, false);
                thread.arm_watch_hit = null;
                continue;
            }
            try self.ensureWatchpoints();
            self.configureArmWatchpoints(thread.tid, false) catch |err| {
                self.watchpoints_dirty = true;
                return err;
            };
            self.beginStep(thread.tid, true) catch |err| {
                self.configureWatchpoints(thread.tid) catch {
                    self.watchpoints_dirty = true;
                };
                return err;
            };
            self.stepping.?.watch = hit;
            thread.arm_watch_hit = null;
            return true;
        }
        self.watch_cancelled = false;
        return false;
    }
    fn watchTrap(self: *Target, tid: i32, pc: u64) !bool {
        if (architecture != .x86_64) return false;
        const status = try peek(tid, c.PTRACE_PEEKUSER, debugOffset(6));
        if (status & 15 == 0) return false;
        var hit = false;
        for (&self.watchpoints, 0..) |*maybe, slot| {
            if (maybe.*) |*v| if (status & (@as(usize, 1) << @intCast(slot)) != 0) {
                var bytes: [8]u8 = @splat(0);
                var local = c.iovec{ .iov_base = &bytes, .iov_len = v.length };
                var remote = c.iovec{ .iov_base = @ptrFromInt(v.address), .iov_len = v.length };
                const n = c.process_vm_readv(tid, &local, 1, &remote, 1, 0);
                if (n != v.length) return error.MemoryUnreadable;
                const after = std.mem.readInt(u64, &bytes, .little);
                self.event(.watchpoint_hit, tid, @intCast(v.id));
                const e = &self.events[self.event_count - 1];
                e.pc = pc;
                e.address = v.address;
                e.before = v.previous;
                e.after = after;
                e.size = v.length;
                for (self.threadSlice()) |t| if (t.tid != tid and t.state == .running) {
                    e.other_threads_running = true;
                };
                v.previous = after;
                hit = true;
            };
        }
        try setDebug(tid, 6, 0);
        return hit;
    }
    pub fn writeRegister(self: *Target, tid: i32, name: []const u8, value: u64) !void {
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        _ = self.index(tid) orelse return error.UnknownThread;
        var regs = try getRegisters(tid);
        inline for (std.meta.fields(Registers)) |field| if (std.mem.eql(u8, name, field.name)) {
            @field(regs, field.name) = value;
            try setRegisters(tid, &regs);
            self.event(.register_written, tid, 0);
            return;
        };
        return error.UnknownRegister;
    }
    pub fn writeMemory(self: *Target, address: u64, bytes: []const u8) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.state != .stopped) return error.NotStopped;
        if (bytes.len > 4096 or address > std.math.maxInt(u64) - bytes.len) return error.InvalidAddress;
        var written: usize = 0;
        defer if (written > 0) {
            // Even a failed request invalidates snapshots if a prefix changed.
            self.event(.memory_written, self.pid, @intCast(written));
            self.events[self.event_count - 1].address = address;
        };
        for (bytes, 0..) |byte, offset| {
            const addr = address + offset;
            var overlay: ?*bp.Breakpoint = null;
            for (self.breakpoints[0..self.breakpoint_count]) |*b| {
                if (addr >= b.address and addr - b.address < architecture.trap().len) {
                    overlay = b;
                    break;
                }
            }
            if (overlay == null or !overlay.?.patched) self.patchByte(addr, byte) catch |err| {
                return if (written > 0) error.PartialMemoryWrite else err;
            };
            if (overlay) |b| b.original[@intCast(addr - b.address)] = byte;
            written += 1;
        }
    }
    fn recomputeState(self: *Target) void {
        if (self.pid == 0) return;
        if (self.thread_count == 0) {
            self.state = .exited;
            return;
        }
        var stopped = false;
        for (self.threadSlice()) |t| {
            if (t.state == .running) {
                self.state = .running;
                return;
            }
            stopped = stopped or t.state == .stopped;
        }
        // All threads can be past TRACEEXIT but not yet waitable. Keep polling.
        self.state = if (stopped) .stopped else .running;
    }
    fn rememberReap(self: *Target, tid: c.pid_t) void {
        for (self.reap_tids[0..self.reap_count]) |existing| if (existing == tid) return;
        self.reap_tids[self.reap_count] = tid;
        self.reap_count += 1;
    }
    fn reapDetached(self: *Target) void {
        var i: usize = 0;
        while (i < self.reap_count) {
            var status: c_int = 0;
            const result = c.waitpid(self.reap_tids[i], &status, c.__WALL | c.WNOHANG);
            if ((result > 0 and (c.WIFEXITED(status) or c.WIFSIGNALED(status))) or
                (result < 0 and std.c._errno().* == c.ECHILD))
            {
                self.reap_count -= 1;
                self.reap_tids[i] = self.reap_tids[self.reap_count];
            } else i += 1;
        }
    }
    /// Only wait on tids learned through launch, attach, or a clone event.
    /// Other subsystems can own children (including their own traced children).
    fn waitKnown(self: *Target, status: *c_int) !c.pid_t {
        for (self.threadSlice()) |t| {
            const tid = c.waitpid(t.tid, status, c.__WALL | c.WNOHANG);
            if (tid > 0) return tid;
            if (tid < 0 and std.c._errno().* != c.ECHILD and std.c._errno().* != c.EINTR) return error.WaitFailed;
        }
        return 0;
    }
    pub fn onlyInternalStops(self: *const Target) bool {
        var hit = false;
        for (self.threadSlice()) |thread| switch (thread.reason) {
            .none, .interrupt => {},
            .breakpoint => {
                const index_ = self.breakpointAt(thread.breakpoint_address) orelse return false;
                if (!self.breakpoints[index_].internal) return false;
                hit = true;
            },
            else => return false,
        };
        return hit;
    }
    pub fn poll(self: *Target) !void {
        if (self.core != null) return;
        self.reapDetached();
        try self.pollBirths();
        if (self.pid == 0 or self.thread_count == 0) return;
        defer self.recomputeState();
        while (true) {
            var status: c_int = 0;
            const tid = try self.waitKnown(&status);
            if (tid == 0) break;
            var i = self.index(tid).?;
            if (c.WIFEXITED(status) or c.WIFSIGNALED(status)) {
                self.event(.exit, tid, if (c.WIFEXITED(status)) c.WEXITSTATUS(status) else -c.WTERMSIG(status));
                self.thread_count -= 1;
                self.threads[i] = self.threads[self.thread_count];
                if (self.thread_count == 0) {
                    self.state = .exited;
                    try self.separateVfork();
                    self.stepping = null;
                } else if (self.stepping != null and self.stepping.?.tid == tid) {
                    // A stepped syscall may exit this thread. Stop peers before
                    // restoring the temporarily removed software breakpoint.
                    try self.stopPeers();
                }
                continue;
            }
            if (!c.WIFSTOPPED(status)) continue;
            const sig = c.WSTOPSIG(status);
            const kind: u32 = @as(u32, @intCast(status)) >> 16;
            self.threads[i].state = .stopped;
            self.threads[i].interrupt_pending = false;
            if (kind == c.PTRACE_EVENT_EXIT) {
                if (self.thread_count == 1) try self.separateVfork();
                var exit_status: c_ulong = 0;
                _ = try trace(c.PTRACE_GETEVENTMSG, tid, 0, @intFromPtr(&exit_status));
                // The leader's final wait status can be delayed until all workers
                // exit. It no longer participates in all-stop or memory access.
                self.threads[i].state = .exited;
                if (self.stepping != null and self.stepping.?.tid == tid and self.stepping.?.watch != null) try self.finishStep(false);
                self.threads[i].signal = 0;
                self.event(.thread_exiting, tid, @intCast(exit_status));
                _ = try trace(c.PTRACE_CONT, tid, 0, 0);
                if (self.stepping != null and self.stepping.?.tid == tid) try self.stopPeers();
                continue;
            }
            if (kind == c.PTRACE_EVENT_EXEC) {
                try self.separateVfork();
                var former_tid: c_ulong = 0;
                _ = try trace(c.PTRACE_GETEVENTMSG, tid, 0, @intFromPtr(&former_tid));
                // exec destroys peers and renames the executing thread to the
                // leader tid. Preserve its stable id, discard all obsolete tids.
                const prior = self.index(@intCast(former_tid)) orelse i;
                const id = self.threads[prior].id;
                self.threads[0] = .{ .id = id, .tid = tid, .state = .stopped };
                self.thread_count = 1;
                i = 0;
                // Never restore old breakpoint bytes into the replacement image.
                self.breakpoints = undefined;
                self.breakpoint_count = 0;
                self.watchpoints = @splat(null);
                self.stepping = null;
                self.inherited_rearm = false;
                self.watchpoints_dirty = false;
                self.watch_cancelled = false;
                self.image_epoch += 1;
                self.event(.image_replaced, tid, @intCast(self.image_epoch));
                try self.validateNativeAbi();
            }
            var process_child: c_ulong = 0;
            if (kind == c.PTRACE_EVENT_FORK or kind == c.PTRACE_EVENT_VFORK or kind == c.PTRACE_EVENT_CLONE)
                _ = try trace(c.PTRACE_GETEVENTMSG, tid, 0, @intFromPtr(&process_child));
            if (kind == c.PTRACE_EVENT_FORK or kind == c.PTRACE_EVENT_VFORK or (kind == c.PTRACE_EVENT_CLONE and !tracedMember(@intCast(process_child), self.pid))) {
                const child = process_child;
                // A stopped parent cannot report another birth until adopted;
                // the capacity equals the maximum number of parent threads.
                std.debug.assert(self.birth_count < self.births.len);
                if (self.birth_count == 0) {
                    self.birth_image_epoch = self.image_epoch;
                    self.birth_breakpoint_count = self.breakpoint_count;
                    @memcpy(self.birth_breakpoints[0..self.breakpoint_count], self.breakpoints[0..self.breakpoint_count]);
                    self.birth_watchpoints = self.watchpoints;
                    self.birth_next_probe_id = self.next_probe_id;
                }
                self.births[self.birth_count] = .{ .saved_debug = self.threads[i].saved_debug, .pid = @intCast(child), .parent_tid = tid, .kind = if (kind == c.PTRACE_EVENT_FORK) .fork else if (kind == c.PTRACE_EVENT_VFORK) .vfork else .clone_unknown, .unpatched_probe = if (self.stepping) |step| step.rearm else null };
                self.birth_count += 1;
                self.threads[i].signal = 0;
                self.threads[i].reason = if (kind == c.PTRACE_EVENT_FORK) .fork else if (kind == c.PTRACE_EVENT_VFORK) .vfork else .clone;
                self.event(.process_birth, @intCast(child), tid);
                if (self.stepping != null and self.stepping.?.tid == tid) try self.finishStep(false);
                try self.stopPeers();
                continue;
            }
            if (kind == c.PTRACE_EVENT_VFORK_DONE) {
                self.threads[i].signal = 0;
                self.threads[i].reason = .vfork_done;
                if (self.want_run) {
                    _ = try trace(c.PTRACE_CONT, tid, 0, 0);
                    self.threads[i].state = .running;
                } else try self.stopPeers();
                continue;
            }
            if (kind == c.PTRACE_EVENT_CLONE) {
                var child: c_ulong = 0;
                _ = try trace(c.PTRACE_GETEVENTMSG, tid, 0, @intFromPtr(&child));
                try self.add(@intCast(child), true);
                self.event(.thread_start, @intCast(child), 0);
                if (self.stepping != null and self.stepping.?.tid == tid) try self.finishStep(false);
                self.threads[i].reason = .clone;
                if (self.want_run) {
                    _ = try trace(c.PTRACE_CONT, tid, 0, 0);
                    self.threads[i].state = .running;
                } else try self.stopPeers();
                continue;
            }
            if (self.threads[i].newborn and kind == c.PTRACE_EVENT_STOP) {
                self.threads[i].newborn = false;
                if (self.new_thread_observer) |observer| observer.before_resume(observer.context, self.threads[i], tracedMember(tid, self.pid));
                for (self.watchpoints) |v| if (v != null) {
                    self.configureWatchpoints(tid) catch |err| {
                        self.watchpoints_dirty = true;
                        try self.stopPeers();
                        return err;
                    };
                    break;
                };
                if (self.want_run) {
                    _ = try trace(c.PTRACE_CONT, tid, 0, 0);
                    self.threads[i].state = .running;
                    continue;
                }
            }
            // stopPeers can race with a stop already pending in the kernel.
            // PTRACE_INTERRUPT then queues another EVENT_STOP after resume.
            // A Continue request still owns run intent; consume only this
            // SIGTRAP event. Group stops carry SIGSTOP/TSTP/TTIN/TTOU, and
            // explicit Pause clears want_run before issuing interrupts.
            // An interrupt queued before an already-waitable breakpoint can
            // arrive while its original instruction is being single-stepped.
            // Resume only an uninterrupted debugger step; explicit Pause and
            // meaningful peer stops mark the operation interrupted in stopPeers.
            if (kind == c.PTRACE_EVENT_STOP and sig == c.SIGTRAP) if (self.stepping) |step| {
                if (step.tid == tid and !step.interrupted) {
                    _ = try trace(c.PTRACE_SINGLESTEP, tid, 0, 0);
                    self.threads[i].signal = 0;
                    self.threads[i].reason = .none;
                    self.threads[i].state = .running;
                    continue;
                }
            };
            if (kind == c.PTRACE_EVENT_STOP and sig == c.SIGTRAP and self.want_run) {
                _ = try trace(c.PTRACE_CONT, tid, 0, 0);
                self.threads[i].signal = 0;
                self.threads[i].reason = .none;
                self.threads[i].state = .running;
                continue;
            }
            self.threads[i].signal = if (kind == 0) sig else 0;
            self.threads[i].reason = if (kind == c.PTRACE_EVENT_EXEC) .exec else if (kind == c.PTRACE_EVENT_STOP) .interrupt else .signal;
            if (kind == 0 and sig == c.SIGTRAP) {
                const regs = try self.registers(tid);
                var siginfo: SignalInfo = undefined;
                _ = try trace(c.PTRACE_GETSIGINFO, tid, 0, @intFromPtr(&siginfo));
                // SINGLESTEP from EVENT_EXEC can first report the completion
                // of exec's syscall without executing the entry instruction.
                // x86 uses TRAP_BRKPT; ARM64's generic report uses SI_USER/pid 0.
                // Consume this once, only at that exact exec PC. In particular,
                // never swallow an ARM BRK or a userspace-generated SIGTRAP.
                if (self.stepping) |*step| if (step.tid == tid) {
                    const entry = step.exec_entry_pc;
                    step.exec_entry_pc = null;
                    const exec_trap = if (architecture == .x86_64)
                        siginfo.code == c.TRAP_BRKPT
                    else
                        siginfo.code == c.SI_USER and siginfo.fields.common.first.piduid.pid == 0;
                    if (entry != null and programCounter(regs) == entry.? and exec_trap) {
                        _ = try trace(c.PTRACE_SINGLESTEP, tid, 0, 0);
                        self.threads[i].signal = 0;
                        self.threads[i].reason = .none;
                        self.threads[i].state = .running;
                        continue;
                    }
                };
                if (siginfo.code == 4 and try self.watchTrapWithInfo(tid, programCounter(regs), siginfo)) {
                    self.threads[i].signal = 0;
                    self.threads[i].reason = .watchpoint;
                    if (self.stepping != null) try self.finishStep(false);
                } else if (self.stepping != null and self.stepping.?.tid == tid and siginfo.code == c.TRAP_TRACE) {
                    const stop_after = self.stepping.?.stop_after;
                    const watch = self.stepping.?.watch != null;
                    // This trap belongs to our single-step even if rearming
                    // fails. Never forward it on a later recovered resume.
                    self.threads[i].signal = 0;
                    try self.finishStep(true);
                    self.threads[i].reason = if (watch) .watchpoint else .single_step;
                    self.threads[i].breakpoint_address = 0;
                    self.event(.step_complete, tid, 0);
                    self.events[self.event_count - 1].pc = programCounter(regs);
                    if (!stop_after) {
                        self.threads[i].reason = .none;
                        self.state = .stopped;
                        try self.continueExecution();
                        continue;
                    }
                } else if (siginfo.code == c.TRAP_BRKPT or siginfo.code == c.SI_KERNEL) {
                    if (if (architecture.breakpointPc(programCounter(regs))) |pc| self.breakpointAt(pc) else null) |b| {
                        const v = self.breakpoints[b];
                        if (v.patched) {
                            try setPc(tid, v.address);
                            self.threads[i].signal = 0;
                            self.threads[i].reason = .breakpoint;
                            self.threads[i].breakpoint_address = v.address;
                            self.breakpoints[b].hit_count +|= 1;
                            self.event(.breakpoint_hit, tid, @intCast(v.id));
                            self.events[self.event_count - 1].pc = v.address;
                        }
                    }
                }
            }
            if (self.stepping != null and self.stepping.?.tid == tid) {
                if (self.threads[i].reason == .signal) std.debug.print("xodb: single step interrupted by signal {d}; tid={d}\n", .{ sig, tid });
                try self.finishStep(false);
            }
            self.event(.stop, tid, sig);
            try self.stopPeers();
        }
        try self.pollBirths();
        self.recomputeState();
        if (self.thread_count > 0) {
            if (self.state == .stopped) {
                if (self.stepping) |step| {
                    const index_ = self.index(step.tid);
                    if (index_ == null or self.threads[index_.?].state == .exited or step.watch != null) try self.finishStep(false);
                }
                if (architecture == .aarch64 and self.stepping == null) {
                    if (try self.startArmWatchCompletion()) return;
                }
                var b: usize = 0;
                while (b < self.breakpoint_count) {
                    const v = self.breakpoints[b];
                    // Any user-visible stop ends a run-to-return operation.
                    if (v.temporary and self.birth_count == 0 and !self.sharedVm() and !self.onlyInternalStops()) try self.removeBreakpoint(v.id) else b += 1;
                }
            }
        }
    }
    pub fn waitStopped(self: *Target) !void {
        const deadline = now() + 3_000_000_000;
        while (now() < deadline) {
            try self.poll();
            if (self.state == .stopped or self.state == .exited) return;
            _ = c.usleep(1000);
        }
        return error.StopTimeout;
    }
    pub fn stopInfo(self: *const Target, tid: i32) !StopInfo {
        const index_ = self.index(tid) orelse return error.UnknownThread;
        const t = self.threads[index_];
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
        var signal: SignalInfo = undefined;
        _ = trace(c.PTRACE_GETSIGINFO, tid, 0, @intFromPtr(&signal)) catch |err| {
            result.diagnostic = @errorName(err);
            return result;
        };
        result.signal = @intCast(@intFromEnum(signal.signo));
        result.signal_name = signalName(result.signal);
        result.code = signal.code;
        result.errno = signal.errno;
        if (signal.code > 0 and (@intFromEnum(signal.signo) == c.SIGSEGV or @intFromEnum(signal.signo) == c.SIGBUS or @intFromEnum(signal.signo) == c.SIGILL or @intFromEnum(signal.signo) == c.SIGFPE)) result.fault_address = @intFromPtr(signal.fields.sigfault.addr);
        return result;
    }
    pub fn registers(self: *const Target, tid: c.pid_t) !Registers {
        if (self.core) |*core| {
            if (architecture != .x86_64) return error.UnsupportedCoreArchitecture;
            const t = try core.thread(tid);
            const r = t.regs;
            return .{ .r15 = r[0], .r14 = r[1], .r13 = r[2], .r12 = r[3], .rbp = r[4], .rbx = r[5], .r11 = r[6], .r10 = r[7], .r9 = r[8], .r8 = r[9], .rax = r[10], .rcx = r[11], .rdx = r[12], .rsi = r[13], .rdi = r[14], .rip = r[16], .eflags = r[18], .rsp = r[19] };
        }
        const i = self.index(tid) orelse return error.UnknownThread;
        if (self.threads[i].state != .stopped) return error.NotStopped;
        const regs = try getRegisters(tid);
        var out: Registers = undefined;
        inline for (std.meta.fields(Registers)) |field| @field(out, field.name) = @field(regs, field.name);
        return out;
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
        if (self.threads[i].state != .stopped) return error.NotStopped;
        return @import("xstate.zig").read(tid);
    }
    /// Returns the number actually read, including a partial read across mappings.
    pub fn readMemory(self: *const Target, address: u64, dest: []u8) !usize {
        if (self.core) |*core| return core.read(address, dest);
        if (self.state != .stopped) return error.NotStopped;
        if (dest.len == 0) return 0;
        if (address == 0 or address > std.math.maxInt(usize) - dest.len) return error.InvalidAddress;
        var local = c.iovec{ .iov_base = dest.ptr, .iov_len = dest.len };
        var remote = c.iovec{ .iov_base = @ptrFromInt(address), .iov_len = dest.len };
        const n = c.process_vm_readv(try self.stoppedTid(), &local, 1, &remote, 1, 0);
        if (n < 0) return error.MemoryUnreadable;
        const count: usize = @intCast(n);
        // Overlay every overlapping byte, including reads starting within an ARM64 trap.
        for (self.breakpoints[0..self.breakpoint_count]) |v| if (v.patched) {
            for (v.original[0..architecture.trap().len], 0..) |byte, i| {
                const addr = v.address + i;
                if (addr >= address and addr - address < count) dest[@intCast(addr - address)] = byte;
            }
        };
        return count;
    }
    /// Coordinated detach restores every shared/copied trap before any child
    /// can run. Also handles unadopted births and unknown CLONE_VM relationships.
    pub fn detachProcessFamily(self: *Target) !void {
        var root = self;
        while (root.vfork_parent) |parent| root = parent;
        var targets: [32]*Target = undefined;
        targets[0] = root;
        var count: usize = 1;
        var scan: usize = 0;
        while (scan < count) : (scan += 1) for (targets[scan].vfork_children) |child| if (child) |target| {
            if (count == targets.len) return error.ProcessLimit;
            targets[count] = target;
            count += 1;
        };
        for (targets[0..count]) |target| if (target.state == .running) {
            try target.interrupt();
            try target.waitStopped();
        };
        const deadline = now() + 3_000_000_000;
        while (true) {
            var pending = false;
            for (targets[0..count]) |target| {
                try target.pollBirths();
                for (target.births[0..target.birth_count]) |birth| pending = pending or (!birth.stopped and !birth.exited);
            }
            if (!pending) break;
            if (now() >= deadline) return error.ChildInitialStopTimeout;
            _ = c.usleep(1000);
        }
        for (targets[0..count]) |target| target.detach_pending = true;
        for (targets[0..count]) |target| {
            for (target.birth_breakpoints[0..target.birth_breakpoint_count]) |probe| if (!probe.pending) {
                for (target.births[0..target.birth_count]) |birth| if (!birth.exited) {
                    try patchInstructionTid(birth.pid, probe.address, probe.original[0..architecture.trap().len]);
                };
            };
            for (target.breakpoints[0..target.breakpoint_count]) |*probe| {
                if (!probe.pending) {
                    if (probe.patched and target.state == .stopped) try target.patchInstruction(probe.address, probe.original[0..architecture.trap().len]);
                }
                probe.patched = false;
                probe.enabled = false;
            }
            target.inherited_rearm = false;
            for (target.births[0..target.birth_count]) |birth| if (!birth.exited and architecture == .x86_64) {
                if (birth.saved_debug) |saved| {
                    try setDebug(birth.pid, 7, 0);
                    for (saved.address, 0..) |address, slot| try setDebug(birth.pid, slot, address);
                    try setDebug(birth.pid, 6, saved.status);
                    try setDebug(birth.pid, 7, saved.control);
                }
            };
        }
        for (targets[0..count]) |target| {
            while (target.birth_count != 0) {
                const birth = target.births[target.birth_count - 1];
                if (!birth.exited) _ = try trace(c.PTRACE_DETACH, birth.pid, 0, 0);
                target.birth_count -= 1;
            }
        }
        // All byte restoration is done before releasing the shared-VM guard.
        for (targets[0..count]) |target| {
            target.vfork_parent = null;
            target.vfork_children = @splat(null);
        }
        var remaining = count;
        while (remaining != 0) {
            remaining -= 1;
            const target = targets[remaining];
            target.detach_pending = false;
            if (target.pid != 0) target.detach() catch |err| {
                target.detach_pending = true;
                return err;
            };
        }
    }
    pub fn detach(self: *Target) !void {
        try self.memoryMutationAllowed();
        if (self.core != null) return error.ReadOnlyCore;
        if (self.pid == 0 or self.state == .idle) return error.InvalidState;
        self.reapDetached();
        if (self.reap_count + self.thread_count + 1 > self.reap_tids.len) return error.TooManyPendingChildren;
        if (self.state == .running) {
            try self.interrupt();
            try self.waitStopped();
        }
        if (self.state == .stopped) {
            while (self.breakpoint_count > 0) try self.removeBreakpoint(self.breakpoints[self.breakpoint_count - 1].id);
            for (self.threadSlice()) |t| if (t.saved_debug) |saved| {
                if (t.state == .exited) continue;
                if (architecture != .x86_64) continue;
                try setDebug(t.tid, 7, 0);
                for (saved.address, 0..) |address, slot| try setDebug(t.tid, slot, address);
                try setDebug(t.tid, 6, saved.status);
                try setDebug(t.tid, 7, saved.control);
            };
        }
        if (architecture == .aarch64) for (self.threadSlice()) |t| {
            if (t.state == .stopped and t.arm_watch_slots != null) try self.configureArmWatchpoints(t.tid, false);
        };
        // Detach each live thread; retain ownership of any thread that fails.
        while (self.thread_count > 0) {
            const t = self.threads[self.thread_count - 1];
            _ = trace(c.PTRACE_DETACH, t.tid, 0, @intCast(t.signal)) catch |err| {
                if (err != error.ProcessGone) return err;
            };
            if (t.state == .exited) self.rememberReap(t.tid);
            self.thread_count -= 1;
        }
        if (self.owned and self.state != .exited) self.rememberReap(self.pid);
        self.event(.detach, self.pid, 0);
        self.pid = 0;
        self.state = .idle;
        self.owned = false;
    }
    pub fn deinit(self: *Target) void {
        if (self.core) |*core| {
            core.deinit();
            self.core = null;
            self.pid = 0;
            self.thread_count = 0;
            self.state = .idle;
            return;
        }
        self.reapDetached();
        if (self.pid == 0) return;
        if (self.owned) for (self.vfork_children) |child| if (child) |target| target.deinit();
        if (self.birth_count == 0 and (self.state == .exited or (!self.owned and self.thread_count == 0))) {
            self.separateVfork() catch |err| std.debug.print("vfork cleanup failed: {s}\n", .{@errorName(err)});
            self.pid = 0;
            self.state = .idle;
            return;
        }
        if (!self.owned) {
            (if (self.birth_count != 0 or self.sharedVm()) self.detachProcessFamily() else self.detach()) catch |err| std.debug.print("detach failed: {s}\n", .{@errorName(err)});
            return;
        }
        for (self.births[0..self.birth_count]) |birth| if (!birth.exited) {
            _ = c.kill(birth.pid, c.SIGKILL);
        };
        if (self.state != .exited) _ = c.kill(self.pid, c.SIGKILL);
        // Reap whichever thread exits first: waiting for the leader first can
        // deadlock while the kernel waits for traced worker exits to be reaped.
        if (self.thread_count == 0 and self.state != .exited) {
            var status: c_int = 0;
            while (c.waitpid(self.pid, &status, 0) < 0 and std.c._errno().* == c.EINTR) {}
        }
        while (self.thread_count > 0) {
            var progressed = false;
            var i: usize = 0;
            while (i < self.thread_count) {
                var status: c_int = 0;
                const tid = self.threads[i].tid;
                const result = c.waitpid(tid, &status, c.__WALL | c.WNOHANG);
                if (result > 0 and c.WIFSTOPPED(status)) {
                    const kind = @as(u32, @intCast(status)) >> 16;
                    if (kind == c.PTRACE_EVENT_CLONE or kind == c.PTRACE_EVENT_FORK or kind == c.PTRACE_EVENT_VFORK) {
                        var child: c_ulong = 0;
                        if (trace(c.PTRACE_GETEVENTMSG, tid, 0, @intFromPtr(&child))) |_| {
                            if (kind == c.PTRACE_EVENT_CLONE and tracedMember(@intCast(child), self.pid)) {
                                self.add(@intCast(child), true) catch {};
                            } else {
                                std.debug.assert(self.birth_count < self.births.len);
                                self.births[self.birth_count] = .{ .pid = @intCast(child), .parent_tid = tid, .kind = if (kind == c.PTRACE_EVENT_VFORK) .vfork else if (kind == c.PTRACE_EVENT_FORK) .fork else .clone_unknown };
                                self.birth_count += 1;
                                _ = c.kill(@intCast(child), c.SIGKILL);
                            }
                        } else |_| {}
                    }
                    _ = c.ptrace(c.PTRACE_CONT, tid, @as(usize, 0), @as(usize, c.SIGKILL));
                    progressed = true;
                } else if (result > 0 or (result < 0 and std.c._errno().* == c.ECHILD)) {
                    self.thread_count -= 1;
                    self.threads[i] = self.threads[self.thread_count];
                    progressed = true;
                    continue;
                }
                i += 1;
            }
            if (!progressed) _ = c.usleep(1000);
        }
        for (self.births[0..self.birth_count]) |birth| if (!birth.exited) {
            var status: c_int = 0;
            while (true) {
                const result = c.waitpid(birth.pid, &status, c.__WALL);
                if (result < 0 and std.c._errno().* == c.EINTR) continue;
                if (result <= 0 or c.WIFEXITED(status) or c.WIFSIGNALED(status)) break;
                _ = c.ptrace(c.PTRACE_CONT, birth.pid, @as(usize, 0), @as(usize, c.SIGKILL));
            }
        };
        self.birth_count = 0;
        self.separateVfork() catch |err| std.debug.print("vfork cleanup failed: {s}\n", .{@errorName(err)});
        self.pid = 0;
        self.thread_count = 0;
        self.state = .idle;
    }
};

test "launch, inspect executable bytes, resume, discover clone, interrupt, cleanup" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try std.testing.expectEqual(State.stopped, target.state);
    const regs = try target.registers(target.pid);
    try std.testing.expect(programCounter(regs) != 0 and regs.rsp != 0);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32), try target.readMemory(programCounter(regs), &bytes));
    try std.testing.expectError(error.MemoryUnreadable, target.readMemory(1, &bytes));
    try target.continueExecution();
    try std.testing.expectError(error.NotStopped, target.registers(target.pid));
    const deadline = now() + 2_000_000_000;
    while (target.thread_count < 2 and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 2), target.thread_count);
    try target.interrupt();
    try target.waitStopped();
    for (target.threadSlice()) |t| _ = try target.registers(t.tid);
    try std.testing.expect(target.events[0].sequence < target.events[target.event_count - 1].sequence);
}

test "repeated pause requests do not queue stops after resume" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.thread_count < 2 and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 2), target.thread_count);
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
            try std.testing.expectEqual(State.running, target.state);
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
    _ = try trace(c.PTRACE_INTERRUPT, target.pid, 0, 0);
    try target.continueExecution();
    const until = now() + 50_000_000;
    while (now() < until) {
        try target.poll();
        try std.testing.expectEqual(State.running, target.state);
        _ = c.usleep(1000);
    }
    // A subsequent explicit Pause must still stop every thread.
    try target.interrupt();
    try target.waitStopped();
    try std.testing.expectEqual(State.stopped, target.state);
}

test "group stop after signal delivery is not a delayed peer interrupt" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-fixture"});
    try target.continueExecution();
    try std.testing.expectEqual(@as(c_int, 0), c.kill(target.pid, c.SIGSTOP));
    try target.waitStopped();
    try std.testing.expectEqual(@as(c_int, c.SIGSTOP), target.threads[0].signal);
    try target.continueExecution(); // Deliver SIGSTOP; kernel reports EVENT_STOP/SIGSTOP.
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.interrupt, target.threads[0].reason);
    try std.testing.expectEqual(State.stopped, target.state);
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
    try std.testing.expectEqual(@as(usize, 2), target.thread_count);
    for (target.threadSlice()) |t| _ = try target.registers(t.tid);
    try target.continueExecution();
    const until = now() + 30_000_000;
    while (now() < until) {
        try target.poll();
        try std.testing.expectEqual(State.running, target.state);
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
    while (target.state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.state);
    try std.testing.expectEqual(@as(i64, 23), target.events[target.event_count - 1].detail);
}

test "missing executable reports failure without leaving an owned child" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try std.testing.expectError(error.ExecFailed, target.launch(&.{"/xodb-test-no-such-executable"}));
    try std.testing.expectEqual(@as(i32, 0), target.pid);
}

test "signal delivery stop is preserved and forwarded on continue" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{ "./zig-out/bin/xodb-fixture", "signal" });
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(@as(c_int, c.SIGUSR1), target.threads[0].signal);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.state);
    try std.testing.expectEqual(@as(i64, -c.SIGUSR1), target.events[target.event_count - 1].detail);
}

fn rendezvous(target: *Target) !Registers {
    try target.launch(&.{ "./zig-out/bin/xodb-m1-fixture", "test" });
    try target.continueExecution();
    try target.waitStopped();
    const regs = try target.registers(target.pid);
    try std.testing.expectEqual(@as(c_int, c.SIGTRAP), target.threads[0].signal);
    // This fixture's explicit INT3 is a program signal, not an installed breakpoint.
    target.threads[0].signal = 0;
    return regs;
}

test "persistent software breakpoint rearm, original bytes, and single step" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    var original: [8]u8 = undefined;
    _ = try target.readMemory(start.rsi, &original);
    const id = try target.setBreakpoint(start.rsi, false);
    var visible: [8]u8 = undefined;
    _ = try target.readMemory(start.rsi, &visible);
    try std.testing.expectEqualSlices(u8, &original, &visible);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, target.threads[0].reason);
    try std.testing.expectEqual(start.rsi, (try target.registers(target.pid)).rip);
    try target.singleStep(target.pid);
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.single_step, target.threads[0].reason);
    try std.testing.expect((try target.registers(target.pid)).rip != start.rsi);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.breakpoint, target.threads[0].reason);
    try std.testing.expectEqual(start.rsi, (try target.registers(target.pid)).rip);
    try target.removeBreakpoint(id);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.state);
    try std.testing.expectEqual(@as(i64, 0), target.events[target.event_count - 1].detail);
}

test "hardware watchpoint captures both writes and continuing does not forward SIGTRAP" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    try std.testing.expectError(error.InvalidWatchRange, target.setWatchpoint(start.rdi + 1, 8, .write));
    const id = try target.setWatchpoint(start.rdi, 8, .write);
    for ([_]u64{ 12, 21 }, [_]u64{ 7, 12 }) |after, before| {
        try target.continueExecution();
        try target.waitStopped();
        try std.testing.expectEqual(bp.StopReason.watchpoint, target.threads[0].reason);
        var found: ?Event = null;
        for (target.eventSlice()) |e| if (e.kind == .watchpoint_hit) {
            found = e;
        };
        try std.testing.expectEqual(before, found.?.before);
        try std.testing.expectEqual(after, found.?.after);
        try std.testing.expectEqual(start.rdi, found.?.address);
        try std.testing.expect(found.?.pc != 0);
    }
    try target.removeWatchpoint(id);
    try target.continueExecution();
    const deadline = now() + 2_000_000_000;
    while (target.state != .exited and now() < deadline) {
        try target.poll();
        _ = c.usleep(1000);
    }
    try std.testing.expectEqual(State.exited, target.state);
}

test "detach restores software and hardware breakpoints" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    const start = try rendezvous(&target);
    const pid = target.pid;
    _ = try target.setBreakpoint(start.rsi, false);
    _ = try target.setWatchpoint(start.rdi, 8, .write);
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
        const start = try target.registers(target.pid);
        target.threads[0].signal = 0; // owned fixture rendezvous BRK
        const pc = if (mode == 0) start.x2 else start.x1;
        try target.writeRegister(target.pid, "pc", pc);
        try target.writeRegister(target.pid, "x1", 7);
        try target.writeRegister(target.pid, "x2", 0);
        _ = try target.setWatchpoint(start.x0, 8, .write);
        target.threads[0].arm_watch_hit = .{ .pc = pc, .address = start.x0, .code = 4, .before = .{ 3, null, null, null } };
        if (mode == 1) try std.testing.expectEqual(@as(c_int, 0), c.kill(target.pid, c.SIGUSR1));
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
        if (mode != 2) try std.testing.expectEqual(@as(c_int, if (mode == 0) c.SIGSEGV else c.SIGUSR1), target.threads[0].signal);
        // Recover this owned fixture and prove watches were rearmed.
        target.threads[0].signal = 0;
        try target.writeRegister(target.pid, "pc", start.x1);
        try target.continueExecution();
        try target.waitStopped();
        try std.testing.expectEqual(bp.StopReason.watchpoint, target.threads[0].reason);
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
    const start = try target.registers(target.pid);
    target.threads[0].signal = 0;
    _ = try target.setWatchpoint(start.x0, 8, .write);
    // A kernel-space address passes the generic range check but is forbidden
    // by ptrace. Apply the candidate bank directly to force a later-slot error.
    target.watchpoints[1] = .{ .id = 99, .address = 0xffff000000000000, .length = 8, .kind = .write };
    if (target.applyWatchpoints()) |_| return error.ExpectedWatchInstallFailure else |_| {}
    target.watchpoints[1] = null;
    target.watchpoints_dirty = true;
    try target.writeRegister(target.pid, "pc", start.x1);
    try target.writeRegister(target.pid, "x1", 7);
    try target.continueExecution();
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.watchpoint, target.threads[0].reason);
    try std.testing.expect(!target.watchpoints_dirty);
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
        const start = try target.registers(target.pid);
        target.threads[0].signal = 0;
        const saved = try Target.armDebugBank(target.pid, note);
        const slots: u8 = @truncate(saved.info);
        var foreign: arm_watch.State = .{};
        foreign.registers[0] = .{ .address = if (note == arm_watch.note) start.x0 else start.x1, .control = if (note == arm_watch.note) 0x1ff1 else 0x1e1 };
        var io = c.iovec{ .iov_base = &foreign, .iov_len = 8 + @as(usize, slots) * 16 };
        _ = try trace(c.PTRACE_SETREGSET, target.pid, note, @intFromPtr(&io));
        const before = try Target.armDebugBank(target.pid, note);
        try std.testing.expectError(if (note == arm_watch.note) error.ExistingHardwareWatchpoints else error.ExistingHardwareBreakpoints, target.setWatchpoint(start.x0 + 8, 8, .write));
        const after = try Target.armDebugBank(target.pid, note);
        try std.testing.expectEqualDeep(before, after);
        try std.testing.expect(!target.watchpoints_dirty);
        for (target.watchpoints) |watch| try std.testing.expect(watch == null);
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
        const start = try target.registers(target.pid);
        target.threads[0].signal = 0;
        try target.writeRegister(target.pid, "pc", start.x1);
        try target.writeRegister(target.pid, "x1", 7);
        _ = try target.setWatchpoint(start.x0, 8, .write);
        _ = try target.setBreakpoint(start.x1, false);
        target.threads[0].arm_watch_hit = .{ .pc = start.x1, .address = start.x0, .code = 4, .before = .{ 3, null, null, null } };
        try std.testing.expect(try target.startArmWatchCompletion());
        if (mode == 0) {
            target.watchpoints[1] = .{ .id = 99, .address = 0xffff000000000000, .length = 8, .kind = .write };
            try std.testing.expectError(error.PtraceFailed, target.waitStopped());
            try std.testing.expectEqual(@as(c_int, 0), target.threads[0].signal);
            try std.testing.expect(target.watchpoints_dirty and target.stepping != null);
            target.watchpoints[1] = null;
            try target.poll();
            try std.testing.expect(target.stepping == null);
            try std.testing.expectEqual(@as(c_int, 0), target.threads[0].signal);
        } else {
            try std.testing.expectEqual(@as(c_int, 0), c.kill(target.pid, c.SIGKILL));
            const deadline = now() + 3_000_000_000;
            while (target.state != .exited and now() < deadline) {
                try target.poll();
                _ = c.usleep(1000);
            }
            try std.testing.expectEqual(State.exited, target.state);
        }
    }
}

test "first instruction step after exec consumes the syscall completion trap" {
    try @import("../test_support.zig").requireLive();
    var target = Target{};
    defer target.deinit();
    try target.launch(&.{"./zig-out/bin/xodb-m1-fixture"});
    try std.testing.expectEqual(bp.StopReason.exec, target.threads[0].reason);
    const entry = programCounter(try target.registers(target.pid));
    try target.singleStep(target.pid);
    try target.waitStopped();
    try std.testing.expectEqual(bp.StopReason.single_step, target.threads[0].reason);
    try std.testing.expectEqual(@as(c_int, 0), target.threads[0].signal);
    try std.testing.expect(programCounter(try target.registers(target.pid)) != entry);
}
