//! Typed Zig values and error translation over the authoritative C runtime.
const std = @import("std");
pub const c = @cImport({
    @cInclude("xrt_memory.h");
    @cInclude("xrt_arch.h");
    @cInclude("xrt_process.h");
    @cInclude("xrt_target.h");
    @cInclude("xrt_remote.h");
    @cInclude("xrt_files.h");
    @cInclude("xrt_source.h");
    @cInclude("xrt_loader.h");
});

pub const X86Registers = c.struct_xrt_x86_registers;
pub const ArmRegisters = c.struct_xrt_arm_registers;
pub const Registers = struct {
    raw: c.struct_xrt_registers,
    fn row(self: Registers) ?*const c.struct_xrt_arch {
        return c.xrt_arch_resolve(self.raw.abi);
    }
    pub fn architecture(self: Registers) @import("arch.zig").Arch {
        return @enumFromInt(self.raw.abi.machine);
    }
    pub fn descriptions(self: Registers) []const c.struct_xrt_register_desc {
        const desc = self.row() orelse return &.{};
        return desc.*.registers[0..desc.*.register_count];
    }
    /// Reads one register through the C row. The descriptor id selects the row
    /// member; a copied descriptor is not a membership proof.
    pub fn value(self: Registers, desc: c.struct_xrt_register_desc) !u64 {
        const arch = self.row() orelse return error.UnsupportedArchitecture;
        const member = c.xrt_arch_register_id(arch, desc.id) orelse return error.UnknownRegister;
        var out: u64 = undefined;
        try check(c.xrt_registers_value_desc(&self.raw, member, &out));
        return out;
    }
    pub fn named(self: Registers, name: []const u8) ?u64 {
        var out: u64 = undefined;
        return if (c.xrt_registers_value(&self.raw, name.ptr, name.len, &out) == c.XRT_OK) out else null;
    }
    pub fn dwarf(self: Registers, number: usize) ?u64 {
        if (number > std.math.maxInt(u16)) return null;
        var out: u64 = undefined;
        return if (c.xrt_registers_value_dwarf(&self.raw, @intCast(number), &out) == c.XRT_OK) out else null;
    }
};
pub fn registerText(allocator: std.mem.Allocator, regs: Registers, desc: c.struct_xrt_register_desc) ![]u8 {
    if (regs.value(desc)) |word| {
        return std.fmt.allocPrint(allocator, "0x{x}", .{word});
    } else |_| return allocator.dupe(u8, "unavailable");
}
pub const DwarfRegisters = [c.XRT_DWARF_REGISTER_COUNT]?u64;

pub fn check(status: c.enum_xrt_status) !void {
    switch (status) {
        c.XRT_OK => {},
        c.XRT_INVALID_ADDRESS => return error.InvalidAddress,
        c.XRT_INVALID_ARGUMENT => return error.InvalidArgument,
        c.XRT_MEMORY_UNREADABLE => return error.MemoryUnreadable,
        c.XRT_PERMISSION_DENIED => return error.PermissionDenied,
        c.XRT_PROCESS_GONE => return error.ProcessGone,
        c.XRT_PTRACE_FAILED => return error.PtraceFailed,
        c.XRT_UNSUPPORTED_ARCHITECTURE => return error.UnsupportedArchitecture,
        c.XRT_UNEXPECTED_REGISTER_SIZE => return error.UnexpectedRegisterSize,
        c.XRT_UNKNOWN_REGISTER => return error.UnknownRegister,
        c.XRT_BUFFER_TOO_SMALL => return error.BufferTooSmall,
        c.XRT_PIPE_FAILED => return error.PipeFailed,
        c.XRT_FORK_FAILED => return error.ForkFailed,
        c.XRT_SIGNAL_FAILED => return error.SignalFailed,
        c.XRT_TARGET_IMAGE_UNAVAILABLE => return error.TargetImageUnavailable,
        c.XRT_TASK_INFO_UNAVAILABLE => return error.TaskInfoUnavailable,
        c.XRT_BREAKPOINT_ALREADY_RESOLVED => return error.BreakpointAlreadyResolved,
        c.XRT_BREAKPOINT_LIMIT => return error.BreakpointLimit,
        c.XRT_BREAKPOINT_LOCATION_ALREADY_USED => return error.BreakpointLocationAlreadyUsed,
        c.XRT_CHILD_INITIAL_STOP_PENDING => return error.ChildInitialStopPending,
        c.XRT_CHILD_INITIAL_STOP_TIMEOUT => return error.ChildInitialStopTimeout,
        c.XRT_CHILD_VM_COMPARISON_DENIED => return error.ChildVmComparisonDenied,
        c.XRT_CHILD_VM_COMPARISON_FAILED => return error.ChildVmComparisonFailed,
        c.XRT_CHILD_WAIT_FAILED => return error.ChildWaitFailed,
        c.XRT_DETACH_INCOMPLETE => return error.DetachIncomplete,
        c.XRT_EXEC_FAILED => return error.ExecFailed,
        c.XRT_EXECUTION_WATCHPOINTS_UNSUPPORTED => return error.ExecutionWatchpointsUnsupported,
        c.XRT_EXISTING_HARDWARE_BREAKPOINTS => return error.ExistingHardwareBreakpoints,
        c.XRT_EXISTING_HARDWARE_WATCHPOINTS => return error.ExistingHardwareWatchpoints,
        c.XRT_EXISTING_TRAP_INSTRUCTION => return error.ExistingTrapInstruction,
        c.XRT_EXTENDED_REGISTERS_UNAVAILABLE => return error.ExtendedRegistersUnavailable,
        c.XRT_INVALID_BREAKPOINT_ADDRESS => return error.InvalidBreakpointAddress,
        c.XRT_INVALID_PID => return error.InvalidPid,
        c.XRT_INVALID_STATE => return error.InvalidState,
        c.XRT_INVALID_WATCH_RANGE => return error.InvalidWatchRange,
        c.XRT_NOT_STOPPED => return error.NotStopped,
        c.XRT_PARENT_IMAGE_CHANGED_DURING_BIRTH => return error.ParentImageChangedDuringBirth,
        c.XRT_PARTIAL_MEMORY_WRITE => return error.PartialMemoryWrite,
        c.XRT_PROCESS_BIRTH_PENDING => return error.ProcessBirthPending,
        c.XRT_PROCESS_LIMIT => return error.ProcessLimit,
        c.XRT_READ_ONLY_CORE => return error.ReadOnlyCore,
        c.XRT_SHARED_ADDRESS_SPACE => return error.SharedAddressSpace,
        c.XRT_SHARED_ADDRESS_SPACE_PEER_RUNNING => return error.SharedAddressSpacePeerRunning,
        c.XRT_SHARED_CLONE_REQUIRES_COORDINATION => return error.SharedCloneRequiresCoordination,
        c.XRT_STOP_TIMEOUT => return error.StopTimeout,
        c.XRT_TOO_MANY_ARGUMENTS => return error.TooManyArguments,
        c.XRT_TOO_MANY_PENDING_CHILDREN => return error.TooManyPendingChildren,
        c.XRT_TOO_MANY_THREADS => return error.TooManyThreads,
        c.XRT_UNEXPECTED_CHILD_INITIAL_STOP => return error.UnexpectedChildInitialStop,
        c.XRT_UNKNOWN_BREAKPOINT => return error.UnknownBreakpoint,
        c.XRT_UNKNOWN_CHILD => return error.UnknownChild,
        c.XRT_UNKNOWN_THREAD => return error.UnknownThread,
        c.XRT_UNKNOWN_WATCHPOINT => return error.UnknownWatchpoint,
        c.XRT_UNSUPPORTED_CORE_ARCHITECTURE => return error.UnsupportedCoreArchitecture,
        c.XRT_UNSUPPORTED_PROCESS_FOLLOWING => return error.UnsupportedProcessFollowing,
        c.XRT_VFORK_PARENT_BLOCKED => return error.VforkParentBlocked,
        c.XRT_WAIT_FAILED => return error.WaitFailed,
        c.XRT_WATCHPOINT_COMPLETION_PENDING => return error.WatchpointCompletionPending,
        c.XRT_WATCHPOINT_LIMIT => return error.WatchpointLimit,
        c.XRT_OUT_OF_MEMORY => return error.OutOfMemory,
        c.XRT_STALE_SNAPSHOT => return error.StaleSnapshot,
        c.XRT_UNEXPECTED_WATCH_REGISTER_SIZE => return error.UnexpectedWatchRegisterSize,
        c.XRT_XSTATE_COMPONENT_UNAVAILABLE => return error.XstateComponentUnavailable,
        c.XRT_INVALID_XSTATE_SIZE => return error.InvalidXstateSize,
        c.XRT_INVALID_XSTATE_HEADER => return error.InvalidXstateHeader,
        c.XRT_EXTENDED_REGISTERS_UNSUPPORTED_ARCHITECTURE => return error.ExtendedRegistersUnsupportedArchitecture,
        c.XRT_TRANSPORT_FAILED => return error.TransportFailed,
        c.XRT_PROTOCOL_ERROR => return error.ProtocolError,
        c.XRT_FILE_UNAVAILABLE => return error.BinaryIdentityUnavailable,
        c.XRT_FILE_CHANGED => return error.BinaryChangedDuringRead,
        c.XRT_FILE_LIMIT => return error.BinarySnapshotLimit,
        c.XRT_DISCOVERY_CANCELLED => return error.SymbolDiscoveryCancelled,
        c.XRT_DISCOVERY_PENDING => return error.SymbolDiscoveryPending,
        c.XRT_DISCOVERY_BUDGET => return error.SymbolDiscoveryBudgetExceeded,
        c.XRT_SYMBOL_AGENT_UPDATE_REQUIRED => return error.SymbolFileAgentUpdateRequired,
        c.XRT_PARTIAL_REGISTER_WRITE => return error.PartialRegisterWrite,
        c.XRT_REGISTER_UNAVAILABLE => return error.RegisterUnavailable,
        c.XRT_REGISTER_NOT_WRITABLE => return error.RegisterNotWritable,
        c.XRT_UNSUPPORTED_CONTROL => return error.UnsupportedControl,
        c.XRT_UNSUPPORTED_MODE => return error.UnsupportedMode,
        c.XRT_AMBIGUOUS_MATCH => return error.AmbiguousMatch,
        else => unreachable,
    }
}

pub fn registers(tid: i32) !Registers {
    var regs: c.struct_xrt_registers = undefined;
    try check(c.xrt_registers_read(tid, &regs));
    return .{ .raw = regs };
}

pub fn writeRegister(tid: i32, name: []const u8, value: u64) !void {
    try check(c.xrt_register_write(tid, name.ptr, name.len, value));
}

pub fn setPc(tid: i32, pc: u64) !void {
    try check(c.xrt_register_write_pc(tid, pc));
}

pub fn dwarfRegisters(regs: Registers) DwarfRegisters {
    var values: [c.XRT_DWARF_REGISTER_COUNT]u64 = undefined;
    var present: [c.XRT_DWARF_REGISTER_COUNT]u8 = undefined;
    check(c.xrt_registers_dwarf(&regs.raw, &values, &present, values.len)) catch unreachable;
    var out: DwarfRegisters = @splat(null);
    for (present, 0..) |flag, i| if (flag != 0) {
        out[i] = values[i];
    };
    return out;
}

pub fn coreRegisters(words: *const [27]u64) !Registers {
    var bytes: [27 * 8]u8 = undefined;
    for (words, 0..) |word, i| std.mem.writeInt(u64, bytes[i * 8 ..][0..8], word, .little);
    const arch = c.xrt_arch_get(c.XRT_X86_64) orelse return error.UnsupportedArchitecture;
    const abi = c.xrt_arch_abi(arch);
    var regs: c.struct_xrt_registers = undefined;
    try check(c.xrt_registers_decode(&abi, &bytes, bytes.len, &regs));
    return .{ .raw = regs };
}

pub fn readMemory(tid: i32, address: u64, dest: []u8) !usize {
    var count: usize = 0;
    const status = c.xrt_memory_read(tid, address, dest.ptr, dest.len, &count);
    switch (status) {
        c.XRT_OK => return count,
        c.XRT_INVALID_ADDRESS => return error.InvalidAddress,
        // Preserve the existing public read error while C retains the cause.
        else => return error.MemoryUnreadable,
    }
}

pub fn patchMemory(tid: i32, address: u64, bytes: []const u8) !void {
    var count: usize = 0;
    const status = c.xrt_memory_patch(tid, address, bytes.ptr, bytes.len, &count);
    if (status != c.XRT_OK and count != 0) return error.PartialMemoryWrite;
    try check(status);
}

pub fn saveLaunchSignals() !void {
    try check(c.xrt_process_save_launch_signals());
}

pub fn launch(argv: [*:null]const ?[*:0]const u8, follow: bool) !i32 {
    var pid: i32 = 0;
    try check(c.xrt_process_launch(@ptrCast(argv), follow, &pid));
    return pid;
}

pub fn processOptions(owned: bool, follow: bool) usize {
    return c.xrt_process_options(owned, follow);
}

pub fn validateNativeAbi(tid: i32) !void {
    const status = c.xrt_process_validate_native(tid);
    if (status == c.XRT_UNSUPPORTED_ARCHITECTURE) return error.UnsupportedTargetArchitecture;
    try check(status);
}

pub fn tracedMember(tid: i32, pid: i32) bool {
    var info: c.struct_xrt_task_info = undefined;
    if (c.xrt_task_inspect(tid, &info) != c.XRT_OK) return false;
    return info.group == pid and info.tracer == @import("../c.zig").api.getpid();
}

pub fn taskGone(tid: i32) bool {
    var info: c.struct_xrt_task_info = undefined;
    return switch (c.xrt_task_inspect(tid, &info)) {
        c.XRT_OK => info.state == 'Z' or info.state == 'X',
        c.XRT_PROCESS_GONE => true,
        else => false,
    };
}

pub fn isZombie(tid: i32) bool {
    var info: c.struct_xrt_task_info = undefined;
    return c.xrt_task_inspect(tid, &info) == c.XRT_OK and info.state == 'Z';
}

test "an unavailable register is not displayed as its snapshot bytes" {
    var words: [27]u64 = @splat(0x1111111111111111);
    var regs = try coreRegisters(&words);
    const rax = regs.descriptions()[3];
    const rip = regs.descriptions()[0];
    try std.testing.expectEqualStrings("rax", std.mem.span(rax.name));
    try std.testing.expectEqualStrings("rip", std.mem.span(rip.name));
    const present = try registerText(std.testing.allocator, regs, rax);
    defer std.testing.allocator.free(present);
    try std.testing.expectEqualStrings("0x1111111111111111", present);
    try std.testing.expectEqual(@as(c.enum_xrt_status, c.XRT_OK), c.xrt_registers_mark_absent(&regs.raw, rax.id));
    try std.testing.expectError(error.RegisterUnavailable, regs.value(rax));
    try std.testing.expect(regs.named("rax") == null);
    try std.testing.expect(regs.dwarf(0) == null);
    try std.testing.expectEqual(@as(u64, 0x1111111111111111), try regs.value(rip));
    const hidden = try registerText(std.testing.allocator, regs, rax);
    defer std.testing.allocator.free(hidden);
    try std.testing.expectEqualStrings("unavailable", hidden);
    const dense = dwarfRegisters(regs);
    try std.testing.expect(dense[0] == null);
    try std.testing.expectEqual(@as(?u64, 0x1111111111111111), dense[16]);
}

pub const SignalInfo = c.struct_xrt_signal_info;
pub fn signalInfo(tid: i32) !SignalInfo {
    var info: SignalInfo = undefined;
    try check(c.xrt_signal_read(tid, &info));
    return info;
}
