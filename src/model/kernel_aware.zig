//! Kernel facts that do not depend on a live stub. A KGDB target and a
//! vmcore both supply memory; the offsets come from the image's DWARF or
//! BTF, never from a compiled-in `struct module`.

const std = @import("std");
const orc = @import("kernel_orc.zig");

pub const Facts = struct {
    list_next: u32,
    name_off: u32,
    name_len: u16,
    state_off: u32,
    mem_off: u32,
    mem_stride: u32,
    text_base: u32,
    text_size: u32,
    build_id_off: ?u32 = null,
    build_id_len: u16 = 0,
    pid_off: u32,
    comm_off: u32,
    comm_len: u16,
    task_state_off: ?u32 = null,
    tasks_next: u32,
    cpu_off: ?u32 = null,
    thread_sp: ?u32 = null,
    /// Offsets within the inactive frame that `thread.sp` points at.
    saved_bp: ?u32 = null,
    saved_ret: ?u32 = null,
    arm_pc: ?u32 = null,
    arm_sp: ?u32 = null,
    arm_fp: ?u32 = null,
    pt_size: ?u32 = null,
    pt_ip: ?u32 = null,
    pt_sp: ?u32 = null,
    /// `task_struct.stack`. The waiter scan covers 16 KiB from this base.
    stack_off: ?u32 = null,
    /// `rq.curr`. The runqueue's current task, used when the image has no
    /// per-CPU `current_task` symbol.
    rq_curr: ?u32 = null,
    mutex_owner: ?u32 = null,
    mutex_wait_list: ?u32 = null,
    mutex_waiter_list: ?u32 = null,
    mutex_waiter_task: ?u32 = null,
    /// Set when `mutex` has `first_waiter` instead of an embedded wait list.
    mutex_first_waiter: ?u32 = null,
    rwsem_owner: ?u32 = null,
    rwsem_wait_list: ?u32 = null,
    rwsem_waiter_list: ?u32 = null,
    rwsem_waiter_task: ?u32 = null,
    rwsem_first_waiter: ?u32 = null,
    /// `task_struct.blocked_on`, a mutex pointer set while `mutex_lock` sleeps.
    task_blocked_on: ?u32 = null,
    /// `module.kallsyms`, a pointer. Null when the image has no such field.
    kallsyms_off: ?u32 = null,
    /// `module.core_kallsyms`, the embedded table.
    core_kallsyms_off: ?u32 = null,
    /// Offsets of `symtab`, `num_symtab`, and `strtab` within `mod_kallsyms`.
    ksym_symtab: ?u32 = null,
    ksym_count: ?u32 = null,
    ksym_strtab: ?u32 = null,
};

pub const Vmcore = struct {
    kernel_offset: ?u64 = null,
    kernel_pac_mask: ?u64 = null,
    page_offset: ?u64 = null,
    init_top_pgt: ?u64 = null,
    /// Null when the note omits the key. Zero is four levels; any other value is five.
    pgtable_l5: ?u64 = null,
    phys_base: ?u64 = null,
    stext: ?u64 = null,
};

/// Keys from a VMCOREINFO note. A missing key stays null. A present key that
/// is not a number is refused. `NUMBER` values may be signed; the bit pattern
/// is kept, because `phys_base` is printed as a signed long.
pub fn vmcoreInfo(text: []const u8) !Vmcore {
    var out = Vmcore{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "NUMBER(KERNELPACMASK)=")) {
            out.kernel_pac_mask = try parseNumber(line["NUMBER(KERNELPACMASK)=".len..]);
        } else if (std.mem.startsWith(u8, line, "KERNELOFFSET=")) {
            // The note prints this with %lx, so the digits are hexadecimal
            // even when they have no 0x prefix.
            out.kernel_offset = try parseHex(line["KERNELOFFSET=".len..]);
        } else if (std.mem.startsWith(u8, line, "NUMBER(PAGE_OFFSET)=")) {
            out.page_offset = try parseNumber(line["NUMBER(PAGE_OFFSET)=".len..]);
        } else if (std.mem.startsWith(u8, line, "PAGE_OFFSET=")) {
            out.page_offset = try parseNumber(line["PAGE_OFFSET=".len..]);
        } else if (std.mem.startsWith(u8, line, "SYMBOL(init_top_pgt)=")) {
            out.init_top_pgt = try parseHex(line["SYMBOL(init_top_pgt)=".len..]);
        } else if (std.mem.startsWith(u8, line, "NUMBER(pgtable_l5_enabled)=")) {
            out.pgtable_l5 = try parseNumber(line["NUMBER(pgtable_l5_enabled)=".len..]);
        } else if (std.mem.startsWith(u8, line, "NUMBER(phys_base)=")) {
            out.phys_base = try parseNumber(line["NUMBER(phys_base)=".len..]);
        } else if (std.mem.startsWith(u8, line, "SYMBOL(_stext)=")) {
            out.stext = try parseHex(line["SYMBOL(_stext)=".len..]);
        }
    }
    return out;
}

fn parseNumber(raw: []const u8) !u64 {
    const body = std.mem.trim(u8, raw, " \t\r");
    if (body.len == 0) return error.VmcoreInfoMalformed;
    const neg = body[0] == '-';
    const rest = if (neg) body[1..] else body;
    if (rest.len == 0) return error.VmcoreInfoMalformed;
    const hex = std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X");
    const digits = if (hex) rest[2..] else rest;
    if (digits.len == 0) return error.VmcoreInfoMalformed;
    const mag = std.fmt.parseInt(u64, digits, if (hex) 16 else 10) catch return error.VmcoreInfoMalformed;
    if (!neg) return mag;
    if (mag > @as(u64, std.math.maxInt(i64))) return error.VmcoreInfoMalformed;
    return @bitCast(-@as(i64, @intCast(mag)));
}

fn parseHex(raw: []const u8) !u64 {
    const body = std.mem.trim(u8, raw, " \t\r");
    if (body.len == 0) return error.VmcoreInfoMalformed;
    const digits = if (std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X")) body[2..] else body;
    if (digits.len == 0) return error.VmcoreInfoMalformed;
    return std.fmt.parseInt(u64, digits, 16) catch error.VmcoreInfoMalformed;
}

/// Force the published kernel PAC bits on. A user address (bit 55 clear: TTBR0) is
/// left alone so a syscall frame can continue into user space. A missing mask
/// refuses a kernel-looking pointer instead of symbolising a signed address.
/// Mask zero means the note said authentication is off.
pub fn stripKernelPac(addr: u64, mask: ?u64) !u64 {
    // The PAC overwrites the top byte, so bit 63 may be clear on a signed
    // kernel return. Bit 55 selects the kernel (TTBR1) half.
    if ((addr >> 55) & 1 == 0) return addr;
    const bits = mask orelse return error.KernelPacMaskUnavailable;
    if (bits == 0) return addr;
    return addr | bits;
}

pub const ModuleRow = struct {
    address: u64,
    name: [64]u8 = @splat(0),
    name_len: u8 = 0,
    state: u32 = 0,
    text: u64 = 0,
    text_size: u32 = 0,
    /// `mem[MOD_DATA].base`, `mem[MOD_RODATA].base`, `mem[MOD_RO_AFTER_INIT].base`.
    data: u64 = 0,
    rodata: u64 = 0,
    ro_after: u64 = 0,
    build_id: [64]u8 = @splat(0),
    build_id_len: u8 = 0,
    /// The image published kallsyms fields. `ksym_failed` means the header
    /// could not be read, so the object must not be placed from the file.
    ksym_present: bool = false,
    ksym_failed: bool = false,
    ksym_symtab: u64 = 0,
    ksym_count: u32 = 0,
    ksym_strtab: u64 = 0,
};

/// A module symbol table larger than this is not checked in full.
pub const kallsyms_symbol_cap: u32 = 65536;

fn readAt(memory: anytype, address: u64, dest: []u8) !void {
    const n = memory.read(address, dest) catch return error.KernelMemory;
    if (n != dest.len) return error.KernelMemory;
}

fn readU64(memory: anytype, address: u64) !u64 {
    var buf: [8]u8 = undefined;
    try readAt(memory, address, &buf);
    return std.mem.readInt(u64, &buf, .little);
}

fn readU32(memory: anytype, address: u64) !u32 {
    var buf: [4]u8 = undefined;
    try readAt(memory, address, &buf);
    return std.mem.readInt(u32, &buf, .little);
}

/// Walk `head`, which is the address of the kernel's module list head.
/// `next` links point at the list field, so the object starts `list_next`
/// bytes earlier. The walk stops at the head, at a repeated address, or at
/// `cap` rows.
pub fn walkModules(memory: anytype, head: u64, facts: Facts, out: []ModuleRow) !usize {
    if (facts.name_len == 0 or facts.name_len > 64 or facts.mem_stride == 0) return error.KernelTypeInfoUnavailable;
    const first = try readU64(memory, head);
    if (first == head or first == 0) return 0;
    var link = first;
    var n: usize = 0;
    var guard: usize = 0;
    while (link != head and link != 0 and n < out.len) : (guard += 1) {
        if (guard == 4096) return error.KernelList;
        if (link < facts.list_next) return error.KernelList;
        const base = link - facts.list_next;
        for (out[0..n]) |row| if (row.address == base) return error.KernelList;
        var row = ModuleRow{ .address = base };
        var name_buf: [64]u8 = undefined;
        const name_n: usize = @min(facts.name_len, name_buf.len);
        try readAt(memory, base + facts.name_off, name_buf[0..name_n]);
        const name = std.mem.sliceTo(name_buf[0..name_n], 0);
        if (name.len == 0 or name.len > row.name.len) return error.KernelList;
        for (name) |byte| if (byte < 0x20 or byte > 0x7e) return error.KernelList;
        @memcpy(row.name[0..name.len], name);
        row.name_len = @intCast(name.len);
        row.state = try readU32(memory, base + facts.state_off);
        row.text = try readU64(memory, base + facts.mem_off + facts.text_base);
        row.text_size = try readU32(memory, base + facts.mem_off + facts.text_size);
        row.data = memBase(memory, base, facts, 1);
        row.rodata = memBase(memory, base, facts, 2);
        row.ro_after = memBase(memory, base, facts, 3);
        if (facts.build_id_off) |off| if (facts.build_id_len > 0) {
            const id_n: usize = @min(facts.build_id_len, row.build_id.len);
            try readAt(memory, base + off, row.build_id[0..id_n]);
            row.build_id_len = @intCast(id_n);
        };
        readModuleKallsyms(memory, base, facts, &row);
        out[n] = row;
        n += 1;
        const next = try readU64(memory, link);
        if (next == link) return error.KernelList;
        link = next;
    }
    return n;
}

fn readModuleKallsyms(memory: anytype, base: u64, facts: Facts, row: *ModuleRow) void {
    const inner = facts.ksym_symtab != null and facts.ksym_count != null and facts.ksym_strtab != null;
    const have_ptr = facts.kallsyms_off != null and inner;
    const have_core = facts.core_kallsyms_off != null and inner;
    if (!have_ptr and !have_core) return;
    row.ksym_present = true;
    if (have_ptr) {
        const ptr = readU64(memory, base + facts.kallsyms_off.?) catch {
            row.ksym_failed = true;
            return;
        };
        if (ptr != 0) {
            fillKallsyms(memory, ptr, facts, row);
            return;
        }
    }
    if (have_core) fillKallsyms(memory, base + facts.core_kallsyms_off.?, facts, row);
}

fn fillKallsyms(memory: anytype, table: u64, facts: Facts, row: *ModuleRow) void {
    const symtab = readU64(memory, table + facts.ksym_symtab.?) catch {
        row.ksym_failed = true;
        return;
    };
    const count = readU32(memory, table + facts.ksym_count.?) catch {
        row.ksym_failed = true;
        return;
    };
    const strtab = readU64(memory, table + facts.ksym_strtab.?) catch {
        row.ksym_failed = true;
        return;
    };
    if (count > kallsyms_symbol_cap or (count > 0 and (symtab == 0 or strtab == 0))) {
        row.ksym_failed = true;
        return;
    }
    row.ksym_symtab = symtab;
    row.ksym_count = count;
    row.ksym_strtab = strtab;
}

pub const TaskRow = struct {
    address: u64,
    pid: i32,
    comm: [16]u8 = @splat(0),
    comm_len: u8 = 0,
    state: ?u32 = null,
    cpu: ?u32 = null,
    /// Thread id published for a core task. Zero means the row was not published.
    pub_tid: i32 = 0,
};

/// One task_struct. Secondary idle tasks are not linked from `init_task`,
/// so a CPU's current pointer is read with this rather than the list walk.
pub fn readTask(memory: anytype, base: u64, facts: Facts) !TaskRow {
    if (facts.comm_len == 0 or facts.comm_len > 16) return error.KernelTypeInfoUnavailable;
    var row = TaskRow{ .address = base, .pid = @bitCast(try readU32(memory, base + facts.pid_off)) };
    var comm_buf: [16]u8 = undefined;
    const comm_n: usize = @min(facts.comm_len, comm_buf.len);
    try readAt(memory, base + facts.comm_off, comm_buf[0..comm_n]);
    const comm = std.mem.sliceTo(comm_buf[0..comm_n], 0);
    for (comm) |byte| if (byte < 0x20 or byte > 0x7e) return error.KernelList;
    @memcpy(row.comm[0..comm.len], comm);
    row.comm_len = @intCast(comm.len);
    if (facts.task_state_off) |off| row.state = try readU32(memory, base + off);
    if (facts.cpu_off) |off| row.cpu = try readU32(memory, base + off);
    return row;
}

pub fn walkTasks(memory: anytype, init_task: u64, facts: Facts, out: []TaskRow) !usize {
    if (facts.comm_len == 0 or facts.comm_len > 16) return error.KernelTypeInfoUnavailable;
    var base = init_task;
    var n: usize = 0;
    var guard: usize = 0;
    while (n < out.len) : (guard += 1) {
        if (guard == 8192) return error.KernelList;
        for (out[0..n]) |row| if (row.address == base) return n;
        out[n] = try readTask(memory, base, facts);
        n += 1;
        const next = try readU64(memory, base + facts.tasks_next);
        if (next < facts.tasks_next) return error.KernelList;
        const next_base = next - facts.tasks_next;
        if (next_base == base) return error.KernelList;
        base = next_base;
    }
    return n;
}

pub const WaitKind = enum { mutex, rwsem, unknown };

pub const WaitEdge = struct {
    waiter: u64,
    lock: u64,
    kind: WaitKind,
    owner: u64,
    owner_cpu: ?u32 = null,
    /// An rwsem held for read: the readers are not tracked, so no owner is named.
    readers: bool = false,
    /// The lock address is known, but the owner word is empty or not a walked task.
    unknown_owner: bool = false,
};

/// Outbound wait sentences follow at most this many edges, including the first.
pub const chain_bound = 4;

const LockLayout = struct {
    owner: u32,
    wait_list: u32,
    waiter_list: u32,
    waiter_task: u32,
};

const PointerLayout = struct {
    owner: u32,
    first_waiter: u32,
    waiter_task: u32,
};

fn pointerLayout(owner: ?u32, first_waiter: ?u32, waiter_task: ?u32) ?PointerLayout {
    return .{
        .owner = owner orelse return null,
        .first_waiter = first_waiter orelse return null,
        .waiter_task = waiter_task orelse return null,
    };
}

fn lockLayout(owner: ?u32, wait_list: ?u32, waiter_list: ?u32, waiter_task: ?u32) ?LockLayout {
    return .{
        .owner = owner orelse return null,
        .wait_list = wait_list orelse return null,
        .waiter_list = waiter_list orelse return null,
        .waiter_task = waiter_task orelse return null,
    };
}

const StackRange = struct { base: u64, end: u64 };

fn inStack(ranges: []const StackRange, address: u64) bool {
    for (ranges) |range| if (range.base != 0 and address >= range.base and address < range.end) return true;
    return false;
}

/// Bit 1 is uninterruptible sleep. Bit 10 marks an idle task, which is not a lock waiter.
fn isUninterruptible(state: u32) bool {
    return (state & 0x2) != 0 and (state & 0x400) == 0;
}

fn knownTask(tasks: []const TaskRow, address: u64) bool {
    for (tasks) |task| if (task.address == address) return true;
    return false;
}

fn ownerCpu(current: []const u64, owner: u64) ?u32 {
    for (current, 0..) |slot, index| if (slot == owner) return std.math.cast(u32, index) orelse null;
    return null;
}

const stack_window: u64 = 16 * 1024;

/// `list_head.next` is the first field. The lock's wait list is the one node
/// that is not inside a task stack. Owner flags occupy the low three bits.
fn findWait(memory: anytype, task: TaskRow, tasks: []const TaskRow, ranges: []const StackRange, stack: StackRange, layout: LockLayout, current: []const u64, kind: WaitKind, allow_unknown: bool) ?WaitEdge {
    var chunk: [512]u8 = undefined;
    var offset: u64 = 0;
    while (offset + 8 <= stack_window) {
        const want: usize = @intCast(@min(@as(u64, chunk.len), stack_window - offset));
        const n = memory.read(stack.base + offset, chunk[0..want]) catch break;
        if (n < 8) break;
        const usable = n - (n % 8);
        var i: usize = 0;
        while (i + 8 <= usable) : (i += 8) {
            const word = std.mem.readInt(u64, chunk[i..][0..8], .little);
            if (word != task.address) continue;
            const addr = stack.base + offset + @as(u64, i);
            if (addr < layout.waiter_task) continue;
            const base = addr - layout.waiter_task;
            if (base < stack.base) continue;
            const list_at = base + layout.waiter_list;
            if (list_at < stack.base or list_at + 8 > stack.end) continue;
            const edge = closeWait(memory, task, tasks, ranges, list_at, layout, current, kind, allow_unknown) orelse continue;
            return edge;
        }
        if (n < want) break;
        offset += @as(u64, n);
    }
    return null;
}

fn closeWait(memory: anytype, task: TaskRow, tasks: []const TaskRow, ranges: []const StackRange, list_at: u64, layout: LockLayout, current: []const u64, kind: WaitKind, allow_unknown: bool) ?WaitEdge {
    var node = readU64(memory, list_at) catch return null;
    var outside: ?u64 = null;
    var closed = false;
    var steps: usize = 0;
    while (steps < 64) : (steps += 1) {
        if (node == list_at) {
            closed = true;
            break;
        }
        if (node == 0 or node % 8 != 0) return null;
        if (!inStack(ranges, node)) {
            if (outside != null) return null;
            outside = node;
        }
        node = readU64(memory, node) catch return null;
    }
    if (!closed) return null;
    const head = outside orelse return null;
    if (head < layout.wait_list) return null;
    const lock = head - layout.wait_list;
    const raw = readU64(memory, lock + layout.owner) catch return null;
    // RWSEM_READER_OWNED: the owner word is only the last reader, not a holder.
    if (kind == .rwsem and raw & 1 != 0) return .{ .waiter = task.address, .lock = lock, .kind = kind, .owner = 0, .readers = true };
    return namedOwner(task, tasks, lock, raw, current, kind, allow_unknown);
}

fn namedOwner(task: TaskRow, tasks: []const TaskRow, lock: u64, raw: u64, current: []const u64, kind: WaitKind, allow_unknown: bool) ?WaitEdge {
    const owner = raw & ~@as(u64, 7);
    if (owner == 0 or owner == task.address or !knownTask(tasks, owner)) {
        if (!allow_unknown) return null;
        return .{
            .waiter = task.address,
            .lock = lock,
            .kind = kind,
            .owner = 0,
            .unknown_owner = true,
        };
    }
    return .{
        .waiter = task.address,
        .lock = lock,
        .kind = kind,
        .owner = owner,
        .owner_cpu = ownerCpu(current, owner),
    };
}

/// The lock's `first_waiter` points at a waiter on this task's stack, and that
/// waiter's task field is this task. Owner flags occupy the low three bits.
fn edgeAt(memory: anytype, task: TaskRow, tasks: []const TaskRow, stack: StackRange, lock: u64, layout: PointerLayout, current: []const u64, kind: WaitKind, allow_unknown: bool) ?WaitEdge {
    const first = readU64(memory, lock + layout.first_waiter) catch return null;
    if (first == 0 or first % 8 != 0 or first < stack.base or first >= stack.end) return null;
    const pointed_at = first + layout.waiter_task;
    if (pointed_at < stack.base or pointed_at + 8 > stack.end) return null;
    const pointed = readU64(memory, pointed_at) catch return null;
    if (pointed != task.address) return null;
    const raw = readU64(memory, lock + layout.owner) catch return null;
    // RWSEM_READER_OWNED: the owner word is only the last reader, not a holder.
    if (kind == .rwsem and raw & 1 != 0) return .{ .waiter = task.address, .lock = lock, .kind = kind, .owner = 0, .readers = true };
    return namedOwner(task, tasks, lock, raw, current, kind, allow_unknown);
}

fn blockedEdge(memory: anytype, task: TaskRow, tasks: []const TaskRow, ranges: []const StackRange, stack: StackRange, blocked_off: u32, layout: PointerLayout, current: []const u64, allow_unknown: bool) ?WaitEdge {
    const lock = readU64(memory, task.address + blocked_off) catch return null;
    if (lock == 0 or lock % 8 != 0 or inStack(ranges, lock)) return null;
    return edgeAt(memory, task, tasks, stack, lock, layout, current, .mutex, allow_unknown);
}

/// A kernel pointer on the waiter stack whose `first_waiter` names that waiter.
/// Used when the lock has no embedded wait list to walk back to.
fn findByPointer(memory: anytype, task: TaskRow, tasks: []const TaskRow, ranges: []const StackRange, stack: StackRange, layout: PointerLayout, current: []const u64, kind: WaitKind, allow_unknown: bool) ?WaitEdge {
    var chunk: [512]u8 = undefined;
    var offset: u64 = 0;
    while (offset + 8 <= stack_window) {
        const want: usize = @intCast(@min(@as(u64, chunk.len), stack_window - offset));
        const n = memory.read(stack.base + offset, chunk[0..want]) catch break;
        if (n < 8) break;
        const usable = n - (n % 8);
        var i: usize = 0;
        while (i + 8 <= usable) : (i += 8) {
            const word = std.mem.readInt(u64, chunk[i..][0..8], .little);
            if (word < 0x1000 or word % 8 != 0 or inStack(ranges, word)) continue;
            const edge = edgeAt(memory, task, tasks, stack, word, layout, current, kind, allow_unknown) orelse continue;
            return edge;
        }
        if (n < want) break;
        offset += @as(u64, n);
    }
    return null;
}

/// One edge per blocked task. A mutex match wins over an rwsem match for the same task.
/// A known lock whose owner is not a walked task is an unknown-owner edge.
/// A `blocked_on` address that matches neither type is an unknown-lock edge.
/// Missing offsets or a missing stack produce nothing.
pub fn walkWaits(memory: anytype, tasks: []const TaskRow, facts: Facts, current: []const u64, out: []WaitEdge) !usize {
    const stack_off = facts.stack_off orelse return 0;
    const mutex = lockLayout(facts.mutex_owner, facts.mutex_wait_list, facts.mutex_waiter_list, facts.mutex_waiter_task);
    const rwsem = lockLayout(facts.rwsem_owner, facts.rwsem_wait_list, facts.rwsem_waiter_list, facts.rwsem_waiter_task);
    const mutex_ptr = pointerLayout(facts.mutex_owner, facts.mutex_first_waiter, facts.mutex_waiter_task);
    const rwsem_ptr = pointerLayout(facts.rwsem_owner, facts.rwsem_first_waiter, facts.rwsem_waiter_task);
    if (mutex == null and rwsem == null and mutex_ptr == null and rwsem_ptr == null and facts.task_blocked_on == null) return 0;
    var ranges: [1024]StackRange = undefined;
    const range_n = @min(tasks.len, ranges.len);
    for (tasks[0..range_n], 0..) |task, index| {
        const base = readU64(memory, task.address + stack_off) catch 0;
        const end = std.math.add(u64, base, stack_window) catch 0;
        ranges[index] = .{ .base = if (base == 0 or end == 0) 0 else base, .end = end };
    }
    var n: usize = 0;
    var scanned: usize = 0;
    for (tasks[0..range_n], 0..) |task, index| {
        if (n == out.len or scanned == 128) break;
        const state = task.state orelse continue;
        if (!isUninterruptible(state)) continue;
        scanned += 1;
        const stack = ranges[index];
        if (stack.base == 0) continue;
        // A known owner wins over an unknown one, so a false structural match with an empty owner word cannot hide a real rwsem.
        var pass: u2 = 0;
        while (pass < 2) : (pass += 1) {
            const allow_unknown = pass == 1;
            if (mutex) |layout| if (findWait(memory, task, tasks, ranges[0..range_n], stack, layout, current, .mutex, allow_unknown)) |edge| {
                out[n] = edge;
                n += 1;
                break;
            };
            if (mutex_ptr) |layout| {
                const from_task = if (facts.task_blocked_on) |off| blockedEdge(memory, task, tasks, ranges[0..range_n], stack, off, layout, current, allow_unknown) else null;
                if (from_task orelse findByPointer(memory, task, tasks, ranges[0..range_n], stack, layout, current, .mutex, allow_unknown)) |edge| {
                    out[n] = edge;
                    n += 1;
                    break;
                }
            }
            if (n == out.len) break;
            if (rwsem) |layout| if (findWait(memory, task, tasks, ranges[0..range_n], stack, layout, current, .rwsem, allow_unknown)) |edge| {
                out[n] = edge;
                n += 1;
                break;
            };
            if (rwsem_ptr) |layout| if (findByPointer(memory, task, tasks, ranges[0..range_n], stack, layout, current, .rwsem, allow_unknown)) |edge| {
                out[n] = edge;
                n += 1;
                break;
            };
        } else if (unknownLock(memory, task, ranges[0..range_n], facts.task_blocked_on)) |edge| {
            if (n == out.len) break;
            out[n] = edge;
            n += 1;
        }
    }
    return n;
}

fn unknownLock(memory: anytype, task: TaskRow, ranges: []const StackRange, blocked_off: ?u32) ?WaitEdge {
    const off = blocked_off orelse return null;
    const lock = readU64(memory, task.address + off) catch return null;
    if (lock == 0 or lock % 8 != 0 or inStack(ranges, lock)) return null;
    return .{
        .waiter = task.address,
        .lock = lock,
        .kind = .unknown,
        .owner = 0,
        .unknown_owner = true,
    };
}

fn commOf(tasks: []const TaskRow, address: u64) []const u8 {
    for (tasks, 0..) |task, index| if (task.address == address and task.comm_len > 0) return tasks[index].comm[0..tasks[index].comm_len];
    return "task";
}

pub fn formatWait(edge: WaitEdge, tasks: []const TaskRow, buf: []u8) []const u8 {
    const waiter = commOf(tasks, edge.waiter);
    if (edge.kind == .unknown) return std.fmt.bufPrint(buf, "{s} waits on an unknown lock at 0x{x}", .{ waiter, edge.lock }) catch buf[0..0];
    if (edge.readers) return std.fmt.bufPrint(buf, "{s} waits on rwsem 0x{x} held by readers (readers are not tracked)", .{ waiter, edge.lock }) catch buf[0..0];
    if (edge.unknown_owner) return std.fmt.bufPrint(buf, "{s} waits on lock 0x{x} owned by an unknown task", .{ waiter, edge.lock }) catch buf[0..0];
    const owner = commOf(tasks, edge.owner);
    if (edge.owner_cpu) |cpu| {
        return std.fmt.bufPrint(buf, "{s} waits on lock 0x{x} owned by {s}, which spins on CPU {d}", .{ waiter, edge.lock, owner, cpu }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{s} waits on lock 0x{x} owned by {s}", .{ waiter, edge.lock, owner }) catch buf[0..0];
}

/// The owner's own label. It names the lock this task holds, not the waiter.
pub fn formatHold(edge: WaitEdge, buf: []u8) []const u8 {
    const what: []const u8 = if (edge.kind == .rwsem) "rwsem" else "lock";
    if (edge.owner_cpu) |cpu| {
        return std.fmt.bufPrint(buf, "spins on CPU {d} holding {s} 0x{x}", .{ cpu, what, edge.lock }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "holds {s} 0x{x}", .{ what, edge.lock }) catch buf[0..0];
}

fn findWaiter(edges: []const WaitEdge, waiter: u64) ?usize {
    for (edges, 0..) |edge, index| if (edge.waiter == waiter) return index;
    return null;
}

fn formatHop(edge: WaitEdge, tasks: []const TaskRow, buf: []u8) []const u8 {
    if (edge.kind == .unknown) return std.fmt.bufPrint(buf, ", which waits on an unknown lock at 0x{x}", .{edge.lock}) catch buf[0..0];
    if (edge.readers) return std.fmt.bufPrint(buf, ", which waits on rwsem 0x{x} held by readers", .{edge.lock}) catch buf[0..0];
    if (edge.unknown_owner) return std.fmt.bufPrint(buf, ", which waits on lock 0x{x} owned by an unknown task", .{edge.lock}) catch buf[0..0];
    const owner = commOf(tasks, edge.owner);
    if (edge.owner_cpu) |cpu| {
        return std.fmt.bufPrint(buf, ", which waits on lock 0x{x} owned by {s}, which spins on CPU {d}", .{ edge.lock, owner, cpu }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, ", which waits on lock 0x{x} owned by {s}", .{ edge.lock, owner }) catch buf[0..0];
}

/// One sentence for a chain of waits. The walk stops at `chain_bound` edges, at an unknown owner, or when an owner repeats.
pub fn formatChain(edges: []const WaitEdge, index: usize, tasks: []const TaskRow, buf: []u8) []const u8 {
    if (index >= edges.len) return buf[0..0];
    var used = formatWait(edges[index], tasks, buf).len;
    if (used == 0 or edges[index].unknown_owner or edges[index].kind == .unknown or edges[index].readers) return buf[0..used];
    var seen: [chain_bound]u64 = undefined;
    seen[0] = edges[index].waiter;
    var seen_n: usize = 1;
    var owner = edges[index].owner;
    var hops: usize = 1;
    while (hops < chain_bound) : (hops += 1) {
        if (owner == 0) break;
        var repeated = false;
        for (seen[0..seen_n]) |addr| if (addr == owner) {
            repeated = true;
            break;
        };
        if (repeated) break;
        const next = findWaiter(edges, owner) orelse break;
        if (seen_n < seen.len) {
            seen[seen_n] = owner;
            seen_n += 1;
        }
        const piece = formatHop(edges[next], tasks, buf[used..]);
        if (piece.len == 0) {
            // A label has 128 bytes. Say the chain goes on rather than end it silently.
            if (buf.len - used >= 4) {
                @memcpy(buf[used..][0..4], ", ..");
                used += 4;
            }
            break;
        }
        used += piece.len;
        if (edges[next].unknown_owner or edges[next].kind == .unknown or edges[next].readers or edges[next].owner == 0) break;
        owner = edges[next].owner;
    }
    return buf[0..used];
}

/// `thread.sp` points at the inactive frame. The saved return slot's offset
/// is the last field, so the resumed SP is just past it. This is the kernel's
/// sleeping-task start, not the stub's pc=0.
pub fn sleepingX86(thread_sp: u64, saved_ret: u32, bp: u64, ret: u64) !struct { ip: u64, sp: u64, bp: u64 } {
    if (ret == 0) return error.KernelTaskLayoutUnavailable;
    const sp = std.math.add(u64, thread_sp, @as(u64, saved_ret) + 8) catch return error.KernelTaskLayoutUnavailable;
    return .{ .ip = ret, .sp = sp, .bp = bp };
}

/// One hop of a wait chain. The thread label is 128 bytes and keeps a single hop.
pub const WaitHop = struct {
    lock: u64 = 0,
    kind: WaitKind = .mutex,
    owner: [16]u8 = @splat(0),
    owner_len: u8 = 0,
    owner_cpu: ?u32 = null,
    readers: bool = false,
    /// The owner word did not name a task. A reader-held lock is separate.
    unknown_owner: bool = false,
    pub fn jsonStringify(self: WaitHop, writer: *std.json.Stringify) !void {
        var lock_hex: [18]u8 = undefined;
        const lock = std.fmt.bufPrint(&lock_hex, "0x{x}", .{self.lock}) catch unreachable;
        const owner: ?[]const u8 = if (self.readers or self.unknown_owner or self.owner_len == 0) null else self.owner[0..self.owner_len];
        try writer.write(.{ .lock = lock, .kind = self.kind, .owner = owner, .owner_cpu = self.owner_cpu, .readers = self.readers, .unknown_owner = self.unknown_owner });
    }
};

fn findWaiterEdge(edges: []const WaitEdge, waiter: u64) ?usize {
    for (edges, 0..) |edge, index| if (edge.waiter == waiter) return index;
    return null;
}

fn fillHop(edge: WaitEdge, tasks: []const TaskRow) WaitHop {
    var hop = WaitHop{
        .lock = edge.lock,
        .kind = edge.kind,
        .owner_cpu = edge.owner_cpu,
        .readers = edge.readers,
    };
    if (edge.readers or edge.owner == 0) {
        hop.unknown_owner = edge.owner == 0 and !edge.readers;
        return hop;
    }
    const name = commOf(tasks, edge.owner);
    const n = @min(name.len, hop.owner.len);
    @memcpy(hop.owner[0..n], name[0..n]);
    hop.owner_len = @intCast(n);
    return hop;
}

/// Follow `waiter`'s owner for at most four hops. Stops on a repeated owner,
/// a reader-held lock, an owner that is not waiting, or an owner of zero.
/// How a published chain ended: at its last hop, at a repeated owner, or at the hop bound with more beyond.
pub const ChainEnd = enum { complete, cycle, truncated };

pub fn chainHops(edges: []const WaitEdge, tasks: []const TaskRow, waiter: u64, out: []WaitHop) usize {
    var end: ChainEnd = .complete;
    return chainHopsEnd(edges, tasks, waiter, out, &end);
}

pub fn chainHopsEnd(edges: []const WaitEdge, tasks: []const TaskRow, waiter: u64, out: []WaitHop, end: *ChainEnd) usize {
    end.* = .complete;
    if (out.len == 0 or waiter == 0) return 0;
    const first = findWaiterEdge(edges, waiter) orelse return 0;
    const limit = @min(out.len, 4);
    var seen: [4]u64 = undefined;
    var seen_n: usize = 0;
    var index: usize = first;
    var n: usize = 0;
    while (n < limit) {
        const edge = edges[index];
        if (seen_n < seen.len) {
            seen[seen_n] = edge.waiter;
            seen_n += 1;
        }
        out[n] = fillHop(edge, tasks);
        n += 1;
        if (edge.readers or edge.owner == 0) break;
        var repeated = false;
        for (seen[0..seen_n]) |addr| if (addr == edge.owner) {
            repeated = true;
            break;
        };
        if (repeated) {
            end.* = .cycle;
            break;
        }
        index = findWaiterEdge(edges, edge.owner) orelse break;
        if (n == limit) end.* = .truncated;
    }
    return n;
}

fn taskNamed(address: u64, pid: i32, comm: []const u8) TaskRow {
    var row = TaskRow{ .address = address, .pid = pid, .comm_len = @intCast(comm.len) };
    @memcpy(row.comm[0..comm.len], comm);
    return row;
}

test "a wait chain keeps every hop the 128-byte label cannot" {
    const tasks = [_]TaskRow{
        taskNamed(0xffff961301001000, 80, "kg0-blocked"),
        taskNamed(0xffff961301002000, 81, "kg0-spinner"),
        taskNamed(0xffff961301003000, 82, "kg0-holder"),
    };
    const two = [_]WaitEdge{
        .{ .waiter = 0xffff961301001000, .lock = 0xffffffffc00fb068, .kind = .mutex, .owner = 0xffff961301002000 },
        .{ .waiter = 0xffff961301002000, .lock = 0xffffffffc00fb0a0, .kind = .mutex, .owner = 0xffff961301003000, .owner_cpu = 1 },
    };
    var narrow: [128]u8 = undefined;
    const first = formatWait(two[0], &tasks, &narrow);
    var second_buf: [128]u8 = undefined;
    const second = formatWait(two[1], &tasks, &second_buf);
    try std.testing.expect(first.len + 2 + second.len > narrow.len);
    var hops: [4]WaitHop = undefined;
    try std.testing.expectEqual(@as(usize, 2), chainHops(&two, &tasks, tasks[0].address, &hops));
    try std.testing.expectEqual(@as(u64, 0xffffffffc00fb0a0), hops[1].lock);
    try std.testing.expectEqualStrings("kg0-holder", hops[1].owner[0..hops[1].owner_len]);
    try std.testing.expectEqual(@as(?u32, 1), hops[1].owner_cpu);
    try std.testing.expectEqual(@as(usize, 0), chainHops(&two, &tasks, tasks[2].address, &hops));

    const cycle = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x1000 },
    };
    const names = [_]TaskRow{ taskNamed(0x1000, 1, "A"), taskNamed(0x2000, 2, "B") };
    try std.testing.expectEqual(@as(usize, 2), chainHops(&cycle, &names, 0x1000, &hops));
    try std.testing.expectEqualStrings("A", hops[1].owner[0..hops[1].owner_len]);

    var chain_tasks: [6]TaskRow = undefined;
    var chain_edges: [5]WaitEdge = undefined;
    for (0..6) |i| chain_tasks[i] = taskNamed(0x1000 + @as(u64, i), @intCast(i + 1), &[_]u8{'A' + @as(u8, @intCast(i))});
    for (0..5) |i| chain_edges[i] = .{ .waiter = chain_tasks[i].address, .lock = 0x10 + @as(u64, i), .kind = .mutex, .owner = chain_tasks[i + 1].address };
    try std.testing.expectEqual(@as(usize, 4), chainHops(&chain_edges, &chain_tasks, chain_tasks[0].address, &hops));
    try std.testing.expectEqualStrings("E", hops[3].owner[0..hops[3].owner_len]);

    const readers = [_]WaitEdge{.{ .waiter = 0x1000, .lock = 0x50, .kind = .rwsem, .owner = 0, .readers = true }};
    try std.testing.expectEqual(@as(usize, 1), chainHops(&readers, &names, 0x1000, &hops));
    try std.testing.expect(hops[0].readers and !hops[0].unknown_owner and hops[0].owner_len == 0);
    const unknown = [_]WaitEdge{.{ .waiter = 0x1000, .lock = 0x60, .kind = .mutex, .owner = 0 }};
    try std.testing.expectEqual(@as(usize, 1), chainHops(&unknown, &names, 0x1000, &hops));
    try std.testing.expect(hops[0].unknown_owner and hops[0].owner_len == 0);
}

pub fn perCpuAddress(offsets: []const u64, cpu: u32, symbol: u64) !u64 {
    if (cpu >= offsets.len) return error.PerCpuOffsetUnavailable;
    // A possible CPU that never came up keeps a zero base; adding it would
    // return the link-time section address, which is not that CPU's data.
    if (cpu != 0 and offsets[cpu] == 0) return error.PerCpuOffsetUnavailable;
    // per_cpu_ptr() is modular: arm64 offsets are "negative".
    return offsets[cpu] +% symbol;
}

/// Shadow wire id `-cpu-2` as an unsigned 32-bit value. CPU 0 is `0xfffffffe`.
pub fn shadowCpu(remote: u64) ?u32 {
    if (remote > std.math.maxInt(u32)) return null;
    const signed: i32 = @bitCast(@as(u32, @intCast(remote)));
    if (signed >= -1) return null;
    const mag = -@as(i64, signed);
    if (mag < 2 or mag > 4096) return null;
    return @intCast(mag - 2);
}

/// Local id `0x60000000 + cpu + 2`, the alias KGDB shadow threads use.
pub fn shadowCpuLocal(local: i32) ?u32 {
    const base: i32 = 0x60000000;
    if (local < base + 2) return null;
    const mag: u32 = @intCast(local - base);
    if (mag < 2 or mag > 4096) return null;
    return mag - 2;
}

/// Kernel stack window used to pair a stopped CPU thread with `task.stack`.
pub const cpu_stack_span: u64 = 16 * 1024;

/// CPU whose per-CPU base equals `gs_base`, or whose kernel stack contains `sp`.
/// A zero base is not a match. Two matches are no match. `gs_base` wins when set.
pub fn cpuForStop(sp: u64, gs_base: ?u64, percpu: []const u64, stacks: []const u64) ?u32 {
    if (gs_base) |base| if (base != 0) {
        var found: ?u32 = null;
        for (percpu, 0..) |off, index| {
            if (off != base) continue;
            if (index > std.math.maxInt(u32)) return null;
            if (found != null) return null;
            found = @intCast(index);
        }
        if (found) |cpu| return cpu;
    };
    if (sp == 0) return null;
    var found: ?u32 = null;
    for (stacks, 0..) |base, index| {
        if (base == 0 or sp < base or sp - base >= cpu_stack_span) continue;
        if (index > std.math.maxInt(u32)) return null;
        if (found != null) return null;
        found = @intCast(index);
    }
    return found;
}

pub const Fp = struct { ip: u64, sp: u64, bp: u64 };

/// x86 frame record: previous BP, then the return address, SP just past both.
/// arm64 is the same pair; the caller strips a kernel PAC from `ip`.
pub fn framePointer(memory: anytype, bp: u64) !Fp {
    if (bp == 0 or bp % 8 != 0) return error.KernelFrame;
    const next_bp = try readU64(memory, bp);
    const ret = try readU64(memory, bp + 8);
    if (ret == 0 or (next_bp != 0 and next_bp <= bp)) return error.KernelFrame;
    const sp = std.math.add(u64, bp, 16) catch return error.KernelFrame;
    return .{ .ip = ret, .sp = sp, .bp = next_bp };
}

const BtfKind = enum(u8) {
    unknown = 0,
    int = 1,
    ptr = 2,
    array = 3,
    @"struct" = 4,
    @"union" = 5,
    @"enum" = 6,
    fwd = 7,
    typedef = 8,
    @"volatile" = 9,
    @"const" = 10,
    restrict = 11,
    func = 12,
    func_proto = 13,
    variable = 14,
    datasec = 15,
    float = 16,
    decl_tag = 17,
    type_tag = 18,
    enum64 = 19,
};

const BtfType = struct {
    kind: BtfKind,
    vlen: u32,
    kflag: bool,
    size_or_type: u32,
    extra: u32,
};

fn btfExtra(kind: BtfKind, vlen: u32) !u32 {
    return switch (kind) {
        .unknown, .ptr, .fwd, .typedef, .@"volatile", .@"const", .restrict, .func, .float, .type_tag => 0,
        .int, .variable, .decl_tag => 4,
        .array => 12,
        .@"struct", .@"union", .datasec, .enum64 => std.math.mul(u32, vlen, 12) catch error.BtfMalformed,
        .@"enum", .func_proto => std.math.mul(u32, vlen, 8) catch error.BtfMalformed,
    };
}

const BtfView = struct {
    bytes: []const u8,
    types: u32,
    types_end: u32,
    strings: u32,
    strings_end: u32,

    fn parse(bytes: []const u8) !BtfView {
        if (bytes.len < 24) return error.BtfMalformed;
        if (std.mem.readInt(u16, bytes[0..2], .little) != 0xeb9f) return error.BtfMalformed;
        if (bytes[2] != 1) return error.BtfUnsupported;
        const hdr: u32 = std.mem.readInt(u32, bytes[4..8], .little);
        if (hdr < 24 or hdr > bytes.len) return error.BtfMalformed;
        const type_off = std.mem.readInt(u32, bytes[8..12], .little);
        const type_len = std.mem.readInt(u32, bytes[12..16], .little);
        const str_off = std.mem.readInt(u32, bytes[16..20], .little);
        const str_len = std.mem.readInt(u32, bytes[20..24], .little);
        const types = std.math.add(u32, hdr, type_off) catch return error.BtfMalformed;
        const strings = std.math.add(u32, hdr, str_off) catch return error.BtfMalformed;
        const types_end = std.math.add(u32, types, type_len) catch return error.BtfMalformed;
        const strings_end = std.math.add(u32, strings, str_len) catch return error.BtfMalformed;
        if (types_end > bytes.len or strings_end > bytes.len) return error.BtfMalformed;
        if (str_len == 0 or bytes[strings] != 0) return error.BtfMalformed;
        return .{ .bytes = bytes, .types = types, .types_end = types_end, .strings = strings, .strings_end = strings_end };
    }

    fn name(self: BtfView, off: u32) ![]const u8 {
        const start = std.math.add(u32, self.strings, off) catch return error.BtfMalformed;
        if (start >= self.strings_end) return error.BtfMalformed;
        const rest = self.bytes[start..self.strings_end];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.BtfMalformed;
        return rest[0..end];
    }

    const Step = struct { info: BtfType, pos: u32, next: u32 };

    fn step(self: BtfView, pos: u32) !Step {
        if (pos + 12 > self.types_end) return error.BtfMalformed;
        const info_bits = std.mem.readInt(u32, self.bytes[pos + 4 ..][0..4], .little);
        const kind_raw: u8 = @intCast((info_bits >> 24) & 0x7f);
        const kind = std.enums.fromInt(BtfKind, kind_raw) orelse return error.BtfUnsupported;
        const vlen = info_bits & 0xffffff;
        const info = BtfType{
            .kind = kind,
            .vlen = vlen,
            .kflag = info_bits >> 31 != 0,
            .size_or_type = std.mem.readInt(u32, self.bytes[pos + 8 ..][0..4], .little),
            .extra = try btfExtra(kind, vlen),
        };
        const next = std.math.add(u32, pos + 12, info.extra) catch return error.BtfMalformed;
        if (next > self.types_end) return error.BtfMalformed;
        return .{ .info = info, .pos = pos, .next = next };
    }

    fn at(self: BtfView, id: u32) !struct { info: BtfType, pos: u32 } {
        if (id == 0) return error.BtfMalformed;
        var pos = self.types;
        var cur: u32 = 1;
        while (pos + 12 <= self.types_end) {
            const item = try self.step(pos);
            if (cur == id) return .{ .info = item.info, .pos = item.pos };
            pos = item.next;
            cur += 1;
        }
        return error.BtfMalformed;
    }
};

pub const Member = struct {
    offset: u32,
    type_id: u32,
    inline_len: u32 = 0,
};

fn byteOffset(raw: u32, kflag: bool) !u32 {
    if (kflag) {
        if (raw >> 24 != 0) return error.BtfBitfield;
        if ((raw & 0xffffff) % 8 != 0) return error.BtfBitfield;
        return (raw & 0xffffff) / 8;
    }
    if (raw % 8 != 0) return error.BtfBitfield;
    return raw / 8;
}

pub fn btfMember(bytes: []const u8, type_name: []const u8, member_name: []const u8) !Member {
    const view = try BtfView.parse(bytes);
    // Ids are dense from 1. One forward pass stays linear. Looking each id up
    // from the first type does not finish on a kernel-sized BTF section.
    var scan = view.types;
    while (scan + 12 <= view.types_end) {
        const found = view.step(scan) catch |err| switch (err) {
            error.BtfMalformed => break,
            else => return err,
        };
        scan = found.next;
        const type_off = std.mem.readInt(u32, view.bytes[found.pos..][0..4], .little);
        if (!std.mem.eql(u8, try view.name(type_off), type_name)) continue;
        var info = found.info;
        var pos = found.pos;
        var guard: u8 = 0;
        while (info.kind == .typedef or info.kind == .@"const" or info.kind == .@"volatile" or info.kind == .restrict) : (guard += 1) {
            if (guard == 8) return error.BtfMalformed;
            const next = try view.at(info.size_or_type);
            info = next.info;
            pos = next.pos;
        }
        if (info.kind != .@"struct" and info.kind != .@"union") continue;
        var m: u32 = 0;
        while (m < info.vlen) : (m += 1) {
            const at = pos + 12 + m * 12;
            const member_off = std.mem.readInt(u32, view.bytes[at..][0..4], .little);
            if (!std.mem.eql(u8, try view.name(member_off), member_name)) continue;
            const type_id = std.mem.readInt(u32, view.bytes[at + 4 ..][0..4], .little);
            const raw = std.mem.readInt(u32, view.bytes[at + 8 ..][0..4], .little);
            var member = Member{ .offset = try byteOffset(raw, info.kflag), .type_id = type_id };
            const child = try view.at(type_id);
            if (child.info.kind == .array and child.info.extra >= 12) {
                const nelems = std.mem.readInt(u32, view.bytes[child.pos + 12 + 8 ..][0..4], .little);
                member.inline_len = nelems;
            }
            return member;
        }
        return error.KernelTypeInfoUnavailable;
    }
    return error.KernelTypeInfoUnavailable;
}

fn requireMember(bytes: []const u8, type_name: []const u8, member_name: []const u8) !Member {
    return btfMember(bytes, type_name, member_name) catch error.KernelTypeInfoUnavailable;
}

/// Build the fact table from BTF. DWARF is preferred by the caller when the
/// image has it. Missing BTF, or a struct this table needs, is a typed refusal.
pub fn factsFromBtf(bytes: []const u8) !Facts {
    _ = try BtfView.parse(bytes);
    const list = try requireMember(bytes, "module", "list");
    const list_next = try requireMember(bytes, "list_head", "next");
    const name = try requireMember(bytes, "module", "name");
    const state = try requireMember(bytes, "module", "state");
    const mem = try requireMember(bytes, "module", "mem");
    const text_base = try requireMember(bytes, "module_memory", "base");
    const text_size = try requireMember(bytes, "module_memory", "size");
    const view = try BtfView.parse(bytes);
    const mem_type = try view.at(mem.type_id);
    if (mem_type.info.kind != .array) return error.KernelTypeInfoUnavailable;
    const elem_id = std.mem.readInt(u32, view.bytes[mem_type.pos + 12 ..][0..4], .little);
    const elem = try view.at(elem_id);
    if (elem.info.kind != .@"struct" or elem.info.size_or_type == 0) return error.KernelTypeInfoUnavailable;
    if (name.inline_len == 0 or name.inline_len > 64) return error.KernelTypeInfoUnavailable;
    const pid = try requireMember(bytes, "task_struct", "pid");
    const comm = try requireMember(bytes, "task_struct", "comm");
    const tasks = try requireMember(bytes, "task_struct", "tasks");
    const tasks_next = try requireMember(bytes, "list_head", "next");
    if (comm.inline_len == 0 or comm.inline_len > 16) return error.KernelTypeInfoUnavailable;
    var facts = Facts{
        .list_next = std.math.add(u32, list.offset, list_next.offset) catch return error.KernelTypeInfoUnavailable,
        .name_off = name.offset,
        .name_len = @intCast(name.inline_len),
        .state_off = state.offset,
        .mem_off = mem.offset,
        .mem_stride = elem.info.size_or_type,
        .text_base = text_base.offset,
        .text_size = text_size.offset,
        .pid_off = pid.offset,
        .comm_off = comm.offset,
        .comm_len = @intCast(comm.inline_len),
        .tasks_next = std.math.add(u32, tasks.offset, tasks_next.offset) catch return error.KernelTypeInfoUnavailable,
    };
    if (btfMember(bytes, "module", "build_id")) |id| {
        if (id.inline_len > 0 and id.inline_len <= 64) {
            facts.build_id_off = id.offset;
            facts.build_id_len = @intCast(id.inline_len);
        }
    } else |_| {}
    if (btfMember(bytes, "task_struct", "__state")) |slot| {
        facts.task_state_off = slot.offset;
    } else |_| if (btfMember(bytes, "task_struct", "state")) |slot| {
        facts.task_state_off = slot.offset;
    } else |_| {}
    // task_cpu() reads task_thread_info(p)->cpu, embedded in task_struct.
    if (btfMember(bytes, "task_struct", "thread_info")) |info| {
        if (btfMember(bytes, "thread_info", "cpu")) |slot| facts.cpu_off = std.math.add(u32, info.offset, slot.offset) catch null else |_| {}
    } else |_| {}
    if (btfMember(bytes, "task_struct", "thread")) |thread| {
        if (btfMember(bytes, "thread_struct", "sp")) |sp| {
            facts.thread_sp = std.math.add(u32, thread.offset, sp.offset) catch return error.KernelTypeInfoUnavailable;
        } else |_| {}
        if (btfMember(bytes, "thread_struct", "cpu_context")) |ctx| {
            if (btfMember(bytes, "cpu_context", "pc")) |pc| facts.arm_pc = std.math.add(u32, thread.offset, std.math.add(u32, ctx.offset, pc.offset) catch return error.KernelTypeInfoUnavailable) catch return error.KernelTypeInfoUnavailable else |_| {}
            if (btfMember(bytes, "cpu_context", "sp")) |sp| facts.arm_sp = std.math.add(u32, thread.offset, std.math.add(u32, ctx.offset, sp.offset) catch return error.KernelTypeInfoUnavailable) catch return error.KernelTypeInfoUnavailable else |_| {}
            if (btfMember(bytes, "cpu_context", "fp")) |fp| facts.arm_fp = std.math.add(u32, thread.offset, std.math.add(u32, ctx.offset, fp.offset) catch return error.KernelTypeInfoUnavailable) catch return error.KernelTypeInfoUnavailable else |_| {}
        } else |_| {}
    } else |_| {}
    if (btfMember(bytes, "inactive_task_frame", "bp")) |bp| facts.saved_bp = bp.offset else |_| {}
    if (btfMember(bytes, "inactive_task_frame", "ret_addr")) |ret| facts.saved_ret = ret.offset else |_| {}
    if (btfMember(bytes, "pt_regs", "ip")) |ip| {
        const sp = btfMember(bytes, "pt_regs", "sp") catch null;
        const view_pt = try view.at(ip.type_id);
        _ = view_pt;
        if (sp) |sp_slot| {
            const pt = try view.at((try requireMember(bytes, "pt_regs", "ip")).type_id);
            _ = pt;
            // Size lives on the struct, not on the member. Find the struct by walking.
            var pos: u32 = view.types;
            while (pos + 12 <= view.types_end) {
                const item = view.step(pos) catch break;
                pos = item.next;
                const item_name = view.name(std.mem.readInt(u32, view.bytes[item.pos..][0..4], .little)) catch break;
                if (item.info.kind == .@"struct" and std.mem.eql(u8, item_name, "pt_regs")) {
                    facts.pt_size = item.info.size_or_type;
                    facts.pt_ip = ip.offset;
                    facts.pt_sp = sp_slot.offset;
                    break;
                }
            }
        }
    } else |_| {}
    if (btfMember(bytes, "mod_kallsyms", "symtab")) |symtab| {
        if (btfMember(bytes, "mod_kallsyms", "num_symtab")) |count| {
            if (btfMember(bytes, "mod_kallsyms", "strtab")) |strtab| {
                facts.ksym_symtab = symtab.offset;
                facts.ksym_count = count.offset;
                facts.ksym_strtab = strtab.offset;
            } else |_| {}
        } else |_| {}
    } else |_| {}
    if (btfMember(bytes, "module", "kallsyms")) |slot| facts.kallsyms_off = slot.offset else |_| {}
    if (btfMember(bytes, "module", "core_kallsyms")) |slot| facts.core_kallsyms_off = slot.offset else |_| {}
    return facts;
}

/// A `.text` symbol in a relocatable module. Other sections are skipped:
/// one load bias cannot place both text and data.
pub fn textSymbol(section: u32, text_section: u32, text_base: u64, value: u64) ?u64 {
    if (text_section == 0 or section != text_section) return null;
    return std.math.add(u64, text_base, value) catch null;
}

const shf_write: u64 = 1;
const shf_alloc: u64 = 2;
const shf_exec: u64 = 4;
const shf_ro_after: u64 = 0x00200000;

/// True for a section the kernel puts in an init region. `.exit` stays in
/// the core image when the kernel is built with module unload.
pub fn moduleInitSection(name: []const u8) bool {
    return std.mem.startsWith(u8, name, ".init");
}

pub const AllocSec = struct {
    init: bool = false,
    flags: u64,
    size: u64,
    alignment: u64,
};

/// `kind` 0 is text, 1 data, 2 rodata, 3 ro-after-init, 4 init text,
/// 5 init data, 6 init rodata. 255 means the section is not allocated.
pub const Place = struct {
    kind: u8 = 255,
    offset: u64 = 0,
};

fn alignUp(value: u64, alignment: u64) u64 {
    if (alignment <= 1) return value;
    const mask = alignment - 1;
    if (alignment & mask != 0) return value;
    return (value + mask) & ~mask;
}

const LayoutMask = struct { need: u64, excl: u64, core: u8, init_kind: u8 };

/// Same grouping as the kernel's `layout_sections`: executable, read-only,
/// ro-after-init, then writable. Offsets accumulate in section order.
pub fn layoutAlloc(sections: []const AllocSec, out: []Place) void {
    const masks = [_]LayoutMask{
        .{ .need = shf_exec | shf_alloc, .excl = 0, .core = 0, .init_kind = 4 },
        .{ .need = shf_alloc, .excl = shf_write, .core = 2, .init_kind = 6 },
        .{ .need = shf_ro_after | shf_alloc, .excl = 0, .core = 3, .init_kind = 255 },
        .{ .need = shf_write | shf_alloc, .excl = 0, .core = 1, .init_kind = 5 },
    };
    var cursor = [_]u64{0} ** 7;
    for (out) |*slot| slot.* = .{};
    for (masks) |mask| {
        for (sections, 0..) |sec, index| {
            if (out[index].kind != 255) continue;
            if ((sec.flags & mask.need) != mask.need) continue;
            if ((sec.flags & mask.excl) != 0) continue;
            const kind: u8 = if (sec.init) mask.init_kind else mask.core;
            if (kind == 255 or kind >= cursor.len) continue;
            const aligned = alignUp(cursor[kind], if (sec.alignment == 0) 1 else sec.alignment);
            out[index] = .{ .kind = kind, .offset = aligned };
            cursor[kind] = aligned + sec.size;
        }
    }
}

fn memBase(memory: anytype, module_base: u64, facts: Facts, index: u32) u64 {
    const slot = std.math.add(u64, module_base, facts.mem_off) catch return 0;
    const at = std.math.add(u64, slot, @as(u64, index) * facts.mem_stride + facts.text_base) catch return 0;
    return readU64(memory, at) catch 0;
}

/// At the first instruction the frame pointer still belongs to the caller.
/// x86's return address is the word at `sp`. arm64's is `ra`.
pub fn entryFrame(arm: bool, sp: u64, ra: u64, fp: u64, stacked: u64) !Fp {
    if (arm) {
        if (ra == 0) return error.KernelFrame;
        return .{ .ip = ra, .sp = sp, .bp = fp };
    }
    if (stacked == 0) return error.KernelFrame;
    const next = std.math.add(u64, sp, 8) catch return error.KernelFrame;
    return .{ .ip = stacked, .sp = next, .bp = fp };
}

pub fn buildIdMatches(image_id: []const u8, memory_id: []const u8) bool {
    return image_id.len > 0 and image_id.len == memory_id.len and std.mem.eql(u8, image_id, memory_id);
}

pub const NamedAddr = struct {
    name: []const u8,
    address: u64,
};

/// True when every name that appears in both tables has the same address.
/// A name may occur more than once; any equal address accepts it. Two
/// non-empty tables that share no name do not agree. An empty table cannot
/// be checked and agrees. `wide` selects the 24-byte or 16-byte symbol record.
pub fn kallsymsAgree(memory: anytype, symtab: u64, count: u32, strtab: u64, wide: bool, placed: []const NamedAddr) !bool {
    if (count == 0 or placed.len == 0) return true;
    if (symtab == 0 or strtab == 0 or count > kallsyms_symbol_cap or placed.len > 512) return error.KernelSymbolTable;
    const width: u64 = if (wide) 24 else 16;
    const shndx_off: usize = if (wide) 6 else 14;
    var seen: [512]bool = @splat(false);
    var hit: [512]bool = @splat(false);
    var named_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var rec: [24]u8 = undefined;
        const rec_len: usize = if (wide) 24 else 16;
        try readAt(memory, symtab + @as(u64, index) * width, rec[0..rec_len]);
        const shndx = std.mem.readInt(u16, rec[shndx_off..][0..2], .little);
        if (shndx == 0 or shndx >= 0xff00) continue;
        const name_off = std.mem.readInt(u32, rec[0..4], .little);
        const value: u64 = if (wide)
            std.mem.readInt(u64, rec[8..16], .little)
        else
            std.mem.readInt(u32, rec[4..8], .little);
        var name_buf: [192]u8 = undefined;
        const name = readSymbolName(memory, strtab + name_off, &name_buf) orelse continue;
        if (name.len == 0) continue;
        named_count += 1;
        for (placed, 0..) |item, slot| {
            if (!std.mem.eql(u8, item.name, name)) continue;
            seen[slot] = true;
            if (item.address == value) hit[slot] = true;
        }
    }
    if (named_count == 0) return error.KernelSymbolTable;
    var shared = false;
    for (placed, 0..) |_, slot| {
        if (!seen[slot]) continue;
        shared = true;
        if (!hit[slot]) return false;
    }
    return shared;
}

pub const SectionSym = struct {
    name: []const u8,
    section: u32,
    /// File offset within `section`. The kernel's address is this plus the
    /// base it chose for the section.
    offset: u64,
};

/// True when every section that appears in both tables has one base.
/// The base is a kernel address minus the file offset. Sections may sit at
/// different addresses than a file layout predicts. A symbol that moved
/// inside its section disagrees. A name may occur more than once; any
/// pairing that yields one base accepts it. An empty table cannot be
/// checked and agrees. Two non-empty tables that share no name do not.
pub fn kallsymsSectionsAgree(memory: anytype, symtab: u64, count: u32, strtab: u64, wide: bool, placed: []const SectionSym) !bool {
    if (count == 0 or placed.len == 0) return true;
    if (symtab == 0 or strtab == 0 or count > kallsyms_symbol_cap or placed.len > 512) return error.KernelSymbolTable;
    const width: u64 = if (wide) 24 else 16;
    const shndx_off: usize = if (wide) 6 else 14;
    const hit_cap = 8;
    var hits: [512][hit_cap]u64 = undefined;
    var n_hit: [512]u8 = @splat(0);
    var seen: [512]bool = @splat(false);
    var named_count: u32 = 0;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        var rec: [24]u8 = undefined;
        const rec_len: usize = if (wide) 24 else 16;
        try readAt(memory, symtab + @as(u64, index) * width, rec[0..rec_len]);
        const shndx = std.mem.readInt(u16, rec[shndx_off..][0..2], .little);
        if (shndx == 0 or shndx >= 0xff00) continue;
        const name_off = std.mem.readInt(u32, rec[0..4], .little);
        const value: u64 = if (wide)
            std.mem.readInt(u64, rec[8..16], .little)
        else
            std.mem.readInt(u32, rec[4..8], .little);
        var name_buf: [192]u8 = undefined;
        const name = readSymbolName(memory, strtab + name_off, &name_buf) orelse continue;
        if (name.len == 0) continue;
        named_count += 1;
        for (placed, 0..) |item, slot| {
            if (!std.mem.eql(u8, item.name, name)) continue;
            seen[slot] = true;
            if (n_hit[slot] == hit_cap) continue;
            hits[slot][n_hit[slot]] = value;
            n_hit[slot] += 1;
        }
    }
    if (named_count == 0) return error.KernelSymbolTable;
    var shared = false;
    var checked: [512]bool = @splat(false);
    for (placed, 0..) |item, slot| {
        if (!seen[slot] or checked[slot]) continue;
        if (!sectionBaseAgrees(placed, &seen, &hits, &n_hit, item.section)) return false;
        shared = true;
        for (placed, 0..) |other, other_slot| if (other.section == item.section) {
            checked[other_slot] = true;
        };
    }
    return shared;
}

fn sectionBaseAgrees(placed: []const SectionSym, seen: *const [512]bool, hits: *const [512][8]u64, n_hit: *const [512]u8, section: u32) bool {
    var anchor: ?usize = null;
    for (placed, 0..) |item, slot| {
        if (!seen[slot] or item.section != section) continue;
        if (anchor == null) anchor = slot;
    }
    const first = anchor orelse return true;
    var cand: u8 = 0;
    while (cand < n_hit[first]) : (cand += 1) {
        const base = hits[first][cand] -% placed[first].offset;
        var ok = true;
        for (placed, 0..) |item, slot| {
            if (!seen[slot] or item.section != section) continue;
            const want = base +% item.offset;
            var found = false;
            var hit: u8 = 0;
            while (hit < n_hit[slot]) : (hit += 1) {
                if (hits[slot][hit] == want) found = true;
            }
            if (!found) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn readSymbolName(memory: anytype, address: u64, buf: []u8) ?[]const u8 {
    const n = memory.read(address, buf) catch return null;
    if (n == 0) return null;
    const end = std.mem.indexOfScalar(u8, buf[0..n], 0) orelse return null;
    return buf[0..end];
}

const Flat = struct {
    bytes: []const u8,
    fn read(self: @This(), address: u64, dest: []u8) !usize {
        if (address > self.bytes.len or dest.len > self.bytes.len - address) return error.KernelMemory;
        @memcpy(dest, self.bytes[@intCast(address)..][0..dest.len]);
        return dest.len;
    }
};

fn putU64(buf: []u8, at: u64, value: u64) void {
    std.mem.writeInt(u64, buf[@intCast(at)..][0..8], value, .little);
}
fn putU32(buf: []u8, at: u64, value: u32) void {
    std.mem.writeInt(u32, buf[@intCast(at)..][0..4], value, .little);
}

test "KGVM vmcore info reads the pac mask and the slide and refuses a bad number" {
    const note = "OSRELEASE=synthetic\nNUMBER(KERNELPACMASK)=0xffff000000000000\nKERNELOFFSET=200000\n";
    const parsed = try vmcoreInfo(note);
    try std.testing.expectEqual(@as(u64, 0xffff000000000000), parsed.kernel_pac_mask.?);
    try std.testing.expectEqual(@as(u64, 0x200000), parsed.kernel_offset.?);
    try std.testing.expectEqual(@as(?u64, null), (try vmcoreInfo("OSRELEASE=only\n")).kernel_pac_mask);
    try std.testing.expectError(error.VmcoreInfoMalformed, vmcoreInfo("KERNELOFFSET=zz\n"));
    const levels = try vmcoreInfo("NUMBER(pgtable_l5_enabled)=1\nSYMBOL(init_top_pgt)=ffffffff82c2e000\nNUMBER(phys_base)=-127926272\nSYMBOL(_stext)=ffffffffad400000\nPAGE_OFFSET=0xff11000000000000\n");
    try std.testing.expectEqual(@as(u64, 1), levels.pgtable_l5.?);
    try std.testing.expectEqual(@as(u64, 0xffffffff82c2e000), levels.init_top_pgt.?);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(i64, -127926272))), levels.phys_base.?);
    try std.testing.expectEqual(@as(u64, 0xffffffffad400000), levels.stext.?);
    try std.testing.expectEqual(@as(u64, 0xff11000000000000), levels.page_offset.?);
    try std.testing.expectError(error.VmcoreInfoMalformed, vmcoreInfo("NUMBER(PAGE_OFFSET)=zz\n"));
}

test "kernel pac bits are forced on and a user address is kept" {
    const mask: u64 = 0xffff000000000000;
    // Bit 55 stays set (TTBR1); the signature may clear bit 63.
    const signed: u64 = 0x2a8f000012340000;
    try std.testing.expectEqual(signed | mask, try stripKernelPac(signed, mask));
    try std.testing.expectEqual(@as(u64, 0x400000), try stripKernelPac(0x400000, mask));
    try std.testing.expectEqual(signed, try stripKernelPac(signed, 0));
    try std.testing.expectError(error.KernelPacMaskUnavailable, stripKernelPac(signed, null));
    // A live arm64 return (52-bit VA): the signature cleared bit 63.
    try std.testing.expectEqual(@as(u64, 0xffff975b909a0fb4), try stripKernelPac(0x428f975b909a0fb4, 0xfff0000000000000));
}

test "module and task lists follow the image's field offsets" {
    var mem: [512]u8 = @splat(0);
    // Head at 0. Module A list at 0x40 (object 0x20, list_next 0x20). Module B at 0x80.
    const facts = Facts{
        .list_next = 0x20,
        .name_off = 0x30,
        .name_len = 8,
        .state_off = 0x38,
        .mem_off = 0x40,
        .mem_stride = 16,
        .text_base = 0,
        .text_size = 8,
        .build_id_off = 0x50,
        .build_id_len = 4,
        .pid_off = 0,
        .comm_off = 8,
        .comm_len = 8,
        .tasks_next = 0x18,
        .task_state_off = 4,
        .cpu_off = 0x28,
    };
    putU64(&mem, 0, 0x40);
    putU64(&mem, 0x40, 0xa0);
    putU64(&mem, 0xa0, 0);
    @memcpy(mem[0x50..][0..4], "ext4");
    putU32(&mem, 0x58, 0);
    putU64(&mem, 0x60, 0x1000);
    putU32(&mem, 0x68, 0x100);
    mem[0x70] = 1;
    mem[0x71] = 2;
    mem[0x72] = 3;
    mem[0x73] = 4;
    @memcpy(mem[0xb0..][0..3], "kvm");
    putU32(&mem, 0xb8, 0);
    putU64(&mem, 0xc0, 0x2000);
    putU32(&mem, 0xc8, 0x20);
    var rows: [4]ModuleRow = undefined;
    try std.testing.expectEqual(@as(usize, 2), try walkModules(Flat{ .bytes = &mem }, 0, facts, &rows));
    try std.testing.expectEqualStrings("ext4", rows[0].name[0..rows[0].name_len]);
    try std.testing.expectEqual(@as(u64, 0x1000), rows[0].text);
    try std.testing.expectEqual(@as(u64, 0x2000), rows[1].text);
    try std.testing.expect(buildIdMatches(rows[0].build_id[0..4], &[_]u8{ 1, 2, 3, 4 }));
    try std.testing.expect(!buildIdMatches(rows[0].build_id[0..4], &[_]u8{ 9, 9, 9, 9 }));

    var tasks_mem: [256]u8 = @splat(0);
    putU32(&tasks_mem, 0, 1);
    putU32(&tasks_mem, 4, 0);
    @memcpy(tasks_mem[8..][0..4], "init");
    putU64(&tasks_mem, 0x18, 0x58);
    putU32(&tasks_mem, 0x28, 0);
    putU32(&tasks_mem, 0x40, 42);
    putU32(&tasks_mem, 0x44, 1);
    @memcpy(tasks_mem[0x48..][0..7], "kworker");
    putU64(&tasks_mem, 0x58, 0x18);
    putU32(&tasks_mem, 0x68, 1);
    var tasks: [4]TaskRow = undefined;
    try std.testing.expectEqual(@as(usize, 2), try walkTasks(Flat{ .bytes = &tasks_mem }, 0, facts, &tasks));
    try std.testing.expectEqual(@as(i32, 1), tasks[0].pid);
    try std.testing.expectEqual(@as(i32, 42), tasks[1].pid);
    try std.testing.expectEqual(@as(u32, 1), tasks[1].cpu.?);
    try std.testing.expectEqualStrings("kworker", tasks[1].comm[0..tasks[1].comm_len]);
    // A pid-0 idle task that is not on the list is still readable on its own.
    putU32(&tasks_mem, 0x70, 0);
    putU32(&tasks_mem, 0x74, 0);
    @memcpy(tasks_mem[0x78..][0..6], "swap/1");
    const idle = try readTask(Flat{ .bytes = &tasks_mem }, 0x70, facts);
    try std.testing.expectEqual(@as(u64, 0x70), idle.address);
    try std.testing.expectEqual(@as(i32, 0), idle.pid);
    try std.testing.expectEqual(@as(u32, 0), idle.state.?);
    try std.testing.expectEqualStrings("swap/1", idle.comm[0..idle.comm_len]);
}

test "kallsyms disagreement refuses a shifted symbol and keeps a match" {
    var mem: [0x280]u8 = @splat(0);
    const facts = Facts{
        .list_next = 0x10,
        .name_off = 0x20,
        .name_len = 2,
        .state_off = 0x28,
        .mem_off = 0x30,
        .mem_stride = 16,
        .text_base = 0,
        .text_size = 8,
        .pid_off = 0,
        .comm_off = 8,
        .comm_len = 4,
        .tasks_next = 0x18,
        .kallsyms_off = 0x40,
        .core_kallsyms_off = 0x48,
        .ksym_symtab = 0,
        .ksym_count = 8,
        .ksym_strtab = 16,
    };
    putU64(&mem, 0x200, 0x10);
    putU64(&mem, 0x10, 0x200);
    @memcpy(mem[0x20..][0..2], "ko");
    putU64(&mem, 0x30, 0x1000);
    putU32(&mem, 0x38, 0x100);
    putU64(&mem, 0x40, 0x80);
    putU64(&mem, 0x80, 0x100);
    putU32(&mem, 0x88, 3);
    putU64(&mem, 0x90, 0x180);
    // Record 0 is the null symbol. The next two share a name at two addresses.
    std.mem.writeInt(u16, mem[0x118 + 6 ..][0..2], 1, .little);
    putU64(&mem, 0x118 + 8, 0x1000);
    std.mem.writeInt(u16, mem[0x130 + 6 ..][0..2], 1, .little);
    putU64(&mem, 0x130 + 8, 0x2000);
    @memcpy(mem[0x180..][0..5], "lock\x00");
    var rows: [2]ModuleRow = undefined;
    const flat = Flat{ .bytes = &mem };
    try std.testing.expectEqual(@as(usize, 1), try walkModules(flat, 0x200, facts, &rows));
    try std.testing.expect(rows[0].ksym_present);
    try std.testing.expect(!rows[0].ksym_failed);
    try std.testing.expectEqual(@as(u64, 0x100), rows[0].ksym_symtab);
    try std.testing.expectEqual(@as(u32, 3), rows[0].ksym_count);
    try std.testing.expectEqual(@as(u64, 0x180), rows[0].ksym_strtab);
    const match = [_]NamedAddr{.{ .name = "lock", .address = 0x1000 }};
    const shifted = [_]NamedAddr{.{ .name = "lock", .address = 0x1090 }};
    const other = [_]NamedAddr{.{ .name = "other", .address = 0x1000 }};
    const either = [_]NamedAddr{.{ .name = "lock", .address = 0x2000 }};
    try std.testing.expect(try kallsymsAgree(flat, rows[0].ksym_symtab, rows[0].ksym_count, rows[0].ksym_strtab, true, &match));
    try std.testing.expect(!try kallsymsAgree(flat, rows[0].ksym_symtab, rows[0].ksym_count, rows[0].ksym_strtab, true, &shifted));
    try std.testing.expect(!try kallsymsAgree(flat, rows[0].ksym_symtab, rows[0].ksym_count, rows[0].ksym_strtab, true, &other));
    try std.testing.expect(try kallsymsAgree(flat, rows[0].ksym_symtab, rows[0].ksym_count, rows[0].ksym_strtab, true, &either));
    try std.testing.expect(try kallsymsAgree(flat, rows[0].ksym_symtab, 0, rows[0].ksym_strtab, true, &match));
    // A null pointer uses the embedded table.
    putU64(&mem, 0x40, 0);
    putU64(&mem, 0x48, 0x100);
    putU32(&mem, 0x50, 3);
    putU64(&mem, 0x58, 0x180);
    try std.testing.expectEqual(@as(usize, 1), try walkModules(flat, 0x200, facts, &rows));
    try std.testing.expectEqual(@as(u64, 0x100), rows[0].ksym_symtab);
    try std.testing.expect(!rows[0].ksym_failed);
    // A header that cannot be read is a failed row, not a failed walk.
    putU64(&mem, 0x40, 0x400);
    try std.testing.expectEqual(@as(usize, 1), try walkModules(flat, 0x200, facts, &rows));
    try std.testing.expect(rows[0].ksym_present);
    try std.testing.expect(rows[0].ksym_failed);
}

test "kallsyms section bases agree across a load bias and refuse a moved symbol" {
    var mem: [0x280]u8 = @splat(0);
    // Five records: a null symbol, two in one section, two in another.
    const names = "keep\x00lock\x00str\x00str2\x00";
    @memcpy(mem[0x180..][0..names.len], names);
    putSym(&mem, 0x118, 0, 1, 0x8000);
    putSym(&mem, 0x130, 5, 1, 0x8028);
    putSym(&mem, 0x148, 10, 2, 0x5000);
    putSym(&mem, 0x160, 14, 2, 0x5001);
    const flat = Flat{ .bytes = &mem };
    const match = [_]SectionSym{
        .{ .name = "keep", .section = 1, .offset = 0 },
        .{ .name = "lock", .section = 1, .offset = 0x28 },
        .{ .name = "str", .section = 2, .offset = 0 },
        .{ .name = "str2", .section = 2, .offset = 1 },
    };
    const moved = [_]SectionSym{
        .{ .name = "keep", .section = 1, .offset = 0 },
        .{ .name = "lock", .section = 1, .offset = 0x48 },
        .{ .name = "str", .section = 2, .offset = 0 },
        .{ .name = "str2", .section = 2, .offset = 1 },
    };
    const other = [_]SectionSym{.{ .name = "other", .section = 1, .offset = 0 }};
    try std.testing.expect(try kallsymsSectionsAgree(flat, 0x100, 5, 0x180, true, &match));
    try std.testing.expect(!try kallsymsSectionsAgree(flat, 0x100, 5, 0x180, true, &moved));
    try std.testing.expect(!try kallsymsSectionsAgree(flat, 0x100, 5, 0x180, true, &other));
    try std.testing.expect(try kallsymsSectionsAgree(flat, 0x100, 0, 0x180, true, &match));
}

fn putSym(mem: []u8, at: u64, name_off: u32, shndx: u16, value: u64) void {
    putU32(mem, at, name_off);
    std.mem.writeInt(u16, mem[@intCast(at + 6)..][0..2], shndx, .little);
    putU64(mem, at + 8, value);
}

test "sleeping x86 state, per-cpu slots, shadow cpus and a frame record" {
    const saved = try sleepingX86(0x1000, 48, 0x2000, 0x3000);
    try std.testing.expectEqual(@as(u64, 0x3000), saved.ip);
    try std.testing.expectEqual(@as(u64, 0x1000 + 56), saved.sp);
    try std.testing.expectEqual(@as(u64, 0x2000), saved.bp);
    try std.testing.expectError(error.KernelTaskLayoutUnavailable, sleepingX86(0x1000, 48, 1, 0));
    const offsets = [_]u64{ 0x10000, 0x20000 };
    try std.testing.expectEqual(@as(u64, 0x20040), try perCpuAddress(&offsets, 1, 0x40));
    try std.testing.expectError(error.PerCpuOffsetUnavailable, perCpuAddress(&offsets, 2, 0x40));
    const sparse = [_]u64{ 0x10000, 0 };
    try std.testing.expectError(error.PerCpuOffsetUnavailable, perCpuAddress(&sparse, 1, 0x40));
    const arm_offsets = [_]u64{0xfff068a4ed992000};
    try std.testing.expectEqual(@as(u64, 0xfff000007fac2c80), try perCpuAddress(&arm_offsets, 0, 0xffff975b92130c80));
    try std.testing.expectEqual(@as(?u32, 0), shadowCpu(0xfffffffe));
    try std.testing.expectEqual(@as(?u32, 1), shadowCpuLocal(0x60000003));
    try std.testing.expectEqual(@as(?u32, null), shadowCpu(1));
    const bases = [_]u64{ 0x1000, 0x2000, 0 };
    const stacks = [_]u64{ 0x8000, 0x10000, 0 };
    try std.testing.expectEqual(@as(?u32, 1), cpuForStop(0x9000, 0x2000, &bases, &stacks));
    try std.testing.expectEqual(@as(?u32, null), cpuForStop(0, 0x2000, &[_]u64{ 0x2000, 0x2000 }, &stacks));
    try std.testing.expectEqual(@as(?u32, 0), cpuForStop(0x9000, null, &bases, &stacks));
    try std.testing.expectEqual(@as(?u32, null), cpuForStop(0x9000, null, &bases, &[_]u64{ 0x8000, 0x8800 }));
    try std.testing.expectEqual(@as(?u32, null), cpuForStop(0, 0, &bases, &stacks));
    try std.testing.expectEqual(@as(?u32, 1), cpuForStop(0x10010, 0, &bases, &stacks));
    var stack: [32]u8 = @splat(0);
    putU64(&stack, 16, 32);
    putU64(&stack, 24, 0xabcdef);
    const fp = try framePointer(Flat{ .bytes = &stack }, 16);
    try std.testing.expectEqual(@as(u64, 0xabcdef), fp.ip);
    try std.testing.expectEqual(@as(u64, 32), fp.sp);
    try std.testing.expectEqual(@as(u64, 32), fp.bp);
    try std.testing.expectEqual(@as(?u64, 0x1100), textSymbol(3, 3, 0x1000, 0x100));
    try std.testing.expectEqual(@as(?u64, null), textSymbol(4, 3, 0x1000, 0x100));
    try std.testing.expectEqual(@as(?u64, null), textSymbol(0, 0, 0x1000, 0x100));
}

test "KGHANG a blocked task names the mutex or rwsem owner and the cpu it spins on" {
    const a = std.testing.allocator;
    const mem = try a.alloc(u8, 0xb020);
    defer a.free(mem);
    @memset(mem, 0);
    const facts = Facts{
        .list_next = 0,
        .name_off = 0,
        .name_len = 1,
        .state_off = 0,
        .mem_off = 0,
        .mem_stride = 1,
        .text_base = 0,
        .text_size = 1,
        .pid_off = 0,
        .comm_off = 0,
        .comm_len = 1,
        .tasks_next = 0,
        .stack_off = 0,
        .mutex_owner = 0,
        .mutex_wait_list = 8,
        .mutex_waiter_list = 0,
        .mutex_waiter_task = 16,
        .rwsem_owner = 0,
        .rwsem_wait_list = 16,
        .rwsem_waiter_list = 0,
        .rwsem_waiter_task = 16,
    };
    var waiter = TaskRow{ .address = 0x100, .pid = 10, .state = 2 };
    @memcpy(waiter.comm[0..6], "waiter");
    waiter.comm_len = 6;
    var holder = TaskRow{ .address = 0x180, .pid = 11, .state = 0 };
    @memcpy(holder.comm[0..6], "holder");
    holder.comm_len = 6;
    var blocked = TaskRow{ .address = 0x200, .pid = 12, .state = 2 };
    @memcpy(blocked.comm[0..7], "blocked");
    blocked.comm_len = 7;
    var sleeping = TaskRow{ .address = 0x300, .pid = 13, .state = 1 };
    @memcpy(sleeping.comm[0..5], "sleep");
    sleeping.comm_len = 5;
    var idle = TaskRow{ .address = 0x380, .pid = 14, .state = 0x402 };
    @memcpy(idle.comm[0..4], "idle");
    idle.comm_len = 4;
    putU64(mem, 0x100, 0x2000);
    putU64(mem, 0x180, 0);
    putU64(mem, 0x200, 0x6000);
    putU64(mem, 0x2100, 0xa108);
    putU64(mem, 0x2108, 0xa108);
    putU64(mem, 0x2110, 0x100);
    putU64(mem, 0xa100, 0x180);
    putU64(mem, 0xa108, 0x2100);
    putU64(mem, 0xa110, 0x2100);
    putU64(mem, 0x6100, 0xb010);
    putU64(mem, 0x6108, 0xb010);
    putU64(mem, 0x6110, 0x200);
    // A writer-held rwsem: bit 1 (RWSEM_NONSPINNABLE) is masked. Bit 0 would mean readers.
    putU64(mem, 0xb000, 0x182);
    putU64(mem, 0xb010, 0x6100);
    putU64(mem, 0xb018, 0x6100);
    const tasks = [_]TaskRow{ waiter, holder, blocked, sleeping, idle };
    const current = [_]u64{ 0, 0, 0, 0x180 };
    var edges: [8]WaitEdge = undefined;
    try std.testing.expectEqual(@as(usize, 0), try walkWaits(Flat{ .bytes = mem }, &tasks, Facts{
        .list_next = 0,
        .name_off = 0,
        .name_len = 1,
        .state_off = 0,
        .mem_off = 0,
        .mem_stride = 1,
        .text_base = 0,
        .text_size = 1,
        .pid_off = 0,
        .comm_off = 0,
        .comm_len = 1,
        .tasks_next = 0,
    }, &current, &edges));
    const n = try walkWaits(Flat{ .bytes = mem }, &tasks, facts, &current, &edges);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(WaitKind.mutex, edges[0].kind);
    try std.testing.expectEqual(@as(u64, 0x100), edges[0].waiter);
    try std.testing.expectEqual(@as(u64, 0xa100), edges[0].lock);
    try std.testing.expectEqual(@as(u64, 0x180), edges[0].owner);
    try std.testing.expectEqual(@as(u32, 3), edges[0].owner_cpu.?);
    try std.testing.expectEqual(WaitKind.rwsem, edges[1].kind);
    try std.testing.expectEqual(@as(u64, 0xb000), edges[1].lock);
    try std.testing.expectEqual(@as(u64, 0x180), edges[1].owner);
    var line: [160]u8 = undefined;
    try std.testing.expectEqualStrings("waiter waits on lock 0xa100 owned by holder, which spins on CPU 3", formatWait(edges[0], &tasks, &line));
    try std.testing.expectEqualStrings("blocked waits on lock 0xb000 owned by holder, which spins on CPU 3", formatWait(edges[1], &tasks, &line));
    var quiet = edges[0];
    quiet.owner_cpu = null;
    try std.testing.expectEqualStrings("waiter waits on lock 0xa100 owned by holder", formatWait(quiet, &tasks, &line));
    try std.testing.expectEqualStrings("spins on CPU 3 holding lock 0xa100", formatHold(edges[0], &line));
    try std.testing.expectEqualStrings("spins on CPU 3 holding rwsem 0xb000", formatHold(edges[1], &line));
    try std.testing.expectEqualStrings("holds lock 0xa100", formatHold(quiet, &line));
    try std.testing.expect(std.mem.indexOf(u8, formatHold(edges[0], &line), "waiter") == null);
}

test "KGHANG blocked_on names a mutex that has no embedded wait list" {
    const a = std.testing.allocator;
    const mem = try a.alloc(u8, 0x6020);
    defer a.free(mem);
    @memset(mem, 0);
    const facts = Facts{
        .list_next = 0,
        .name_off = 0,
        .name_len = 1,
        .state_off = 0,
        .mem_off = 0,
        .mem_stride = 1,
        .text_base = 0,
        .text_size = 1,
        .pid_off = 0,
        .comm_off = 0,
        .comm_len = 1,
        .tasks_next = 0,
        .stack_off = 0,
        .task_blocked_on = 8,
        .mutex_owner = 0,
        .mutex_first_waiter = 8,
        .mutex_waiter_task = 16,
    };
    var waiter = TaskRow{ .address = 0x100, .pid = 81, .state = 2 };
    @memcpy(waiter.comm[0..7], "blocked");
    waiter.comm_len = 7;
    var holder = TaskRow{ .address = 0x180, .pid = 82, .state = 0 };
    @memcpy(holder.comm[0..7], "spinner");
    holder.comm_len = 7;
    // Stack window is 16 KiB from 0x1000, so the lock at 0x6000 is outside it.
    putU64(mem, 0x100, 0x1000);
    putU64(mem, 0x108, 0x6000);
    putU64(mem, 0x1110, 0x100);
    putU64(mem, 0x6000, 0x181);
    putU64(mem, 0x6008, 0x1100);
    const tasks = [_]TaskRow{ waiter, holder };
    const current = [_]u64{ 0, 0x180 };
    var edges: [4]WaitEdge = undefined;
    const n = try walkWaits(Flat{ .bytes = mem }, &tasks, facts, &current, &edges);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(WaitKind.mutex, edges[0].kind);
    try std.testing.expectEqual(@as(u64, 0x100), edges[0].waiter);
    try std.testing.expectEqual(@as(u64, 0x6000), edges[0].lock);
    try std.testing.expectEqual(@as(u64, 0x180), edges[0].owner);
    try std.testing.expectEqual(@as(u32, 1), edges[0].owner_cpu.?);
    var line: [160]u8 = undefined;
    try std.testing.expectEqualStrings("blocked waits on lock 0x6000 owned by spinner, which spins on CPU 1", formatWait(edges[0], &tasks, &line));
}

test "btf struct members become kernel facts and a missing image is refused" {
    // strings: 0 "", then names. Header is the 24-byte form (no layout section).
    var strings: [256]u8 = @splat(0);
    const names = [_][]const u8{ "list_head", "next", "prev", "module", "list", "name", "state", "mem", "build_id", "module_memory", "base", "size", "task_struct", "pid", "comm", "tasks", "__state", "cpu", "thread", "thread_struct", "sp", "inactive_task_frame", "bp", "ret_addr", "pt_regs", "ip" };
    var off: usize = 1;
    var str_at: [names.len]u32 = undefined;
    for (names, 0..) |name, i| {
        str_at[i] = @intCast(off);
        @memcpy(strings[off..][0..name.len], name);
        off += name.len + 1;
    }
    var types: std.ArrayList(u8) = .empty;
    defer types.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    // Helper writes one type header plus payload.
    const W = struct {
        fn intType(list: *std.ArrayList(u8), alloc: std.mem.Allocator, name_off: u32, bits: u32) !void {
            var hdr: [16]u8 = @splat(0);
            std.mem.writeInt(u32, hdr[0..4], name_off, .little);
            std.mem.writeInt(u32, hdr[4..8], (1 << 24), .little); // kind INT, vlen 0
            std.mem.writeInt(u32, hdr[8..12], bits / 8, .little);
            std.mem.writeInt(u32, hdr[12..16], bits, .little);
            try list.appendSlice(alloc, &hdr);
        }
        fn ptrType(list: *std.ArrayList(u8), alloc: std.mem.Allocator, pointee: u32) !void {
            var hdr: [12]u8 = @splat(0);
            std.mem.writeInt(u32, hdr[4..8], (2 << 24), .little);
            std.mem.writeInt(u32, hdr[8..12], pointee, .little);
            try list.appendSlice(alloc, &hdr);
        }
        fn arrayType(list: *std.ArrayList(u8), alloc: std.mem.Allocator, elem: u32, count: u32) !void {
            var hdr: [24]u8 = @splat(0);
            std.mem.writeInt(u32, hdr[4..8], (3 << 24) | 0, .little);
            std.mem.writeInt(u32, hdr[12..16], elem, .little);
            std.mem.writeInt(u32, hdr[16..20], 1, .little);
            std.mem.writeInt(u32, hdr[20..24], count, .little);
            try list.appendSlice(alloc, &hdr);
        }
    };
    // id 1: char int 8. id 2: u32 int. id 3: u64 int. id 4: pointer to void-ish (ptr to 1).
    try W.intType(&types, a, 0, 8);
    try W.intType(&types, a, 0, 32);
    try W.intType(&types, a, 0, 64);
    try W.ptrType(&types, a, 1);
    // id 5: list_head { next ptr @ 0, prev ptr @ 64 bits }
    {
        var hdr: [12 + 24]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[0], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 2, .little);
        std.mem.writeInt(u32, hdr[8..12], 16, .little);
        std.mem.writeInt(u32, hdr[12..16], str_at[1], .little);
        std.mem.writeInt(u32, hdr[16..20], 4, .little);
        std.mem.writeInt(u32, hdr[20..24], 0, .little);
        std.mem.writeInt(u32, hdr[24..28], str_at[2], .little);
        std.mem.writeInt(u32, hdr[28..32], 4, .little);
        std.mem.writeInt(u32, hdr[32..36], 64, .little);
        try types.appendSlice(a, &hdr);
    }
    // The rest of the types are enough for factsFromBtf. Keep the blob small
    // by describing module, module_memory, task_struct, thread_struct,
    // inactive_task_frame and pt_regs with the members the walker reads.
    // id 6: name array of 8 chars. id 7: build_id array of 4. id 8: comm array of 16.
    // id 9: mem array of 1 module_memory — the element type must exist first.
    // Order constraint: array element id must already exist. So module_memory
    // before the mem array, and the array before struct module. factsFromBtf
    // looks up by name, so order of structs does not matter aside from ids.
    try W.arrayType(&types, a, 1, 8); // 6 name
    try W.arrayType(&types, a, 1, 4); // 7 build id
    try W.arrayType(&types, a, 1, 16); // 8 comm
    // id 10 module_memory { base ptr @ 0, size u32 @ 64 bits }
    {
        var hdr: [12 + 24]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[9], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 2, .little);
        std.mem.writeInt(u32, hdr[8..12], 16, .little);
        std.mem.writeInt(u32, hdr[12..16], str_at[10], .little);
        std.mem.writeInt(u32, hdr[16..20], 4, .little);
        std.mem.writeInt(u32, hdr[24..28], str_at[11], .little);
        std.mem.writeInt(u32, hdr[28..32], 2, .little);
        std.mem.writeInt(u32, hdr[32..36], 64, .little);
        try types.appendSlice(a, &hdr);
    }
    try W.arrayType(&types, a, 9, 1); // id 10, one module_memory (id 9)
    // id 12 module
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        var hdr: [12]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[3], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 5, .little);
        std.mem.writeInt(u32, hdr[8..12], 64, .little);
        try body.appendSlice(a, &hdr);
        const members = [_]struct { n: u32, t: u32, bit: u32 }{
            .{ .n = str_at[4], .t = 5, .bit = 0 }, // list
            .{ .n = str_at[5], .t = 6, .bit = 128 }, // name at byte 16
            .{ .n = str_at[6], .t = 2, .bit = 192 }, // state at byte 24
            .{ .n = str_at[7], .t = 10, .bit = 256 }, // mem array (id 10) at byte 32
            .{ .n = str_at[8], .t = 7, .bit = 384 }, // build_id at byte 48
        };
        for (members) |member| {
            var raw: [12]u8 = @splat(0);
            std.mem.writeInt(u32, raw[0..4], member.n, .little);
            std.mem.writeInt(u32, raw[4..8], member.t, .little);
            std.mem.writeInt(u32, raw[8..12], member.bit, .little);
            try body.appendSlice(a, &raw);
        }
        try types.appendSlice(a, body.items);
    }
    // id 13 thread_struct { sp @ 0 }
    {
        var hdr: [12 + 12]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[19], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 1, .little);
        std.mem.writeInt(u32, hdr[8..12], 8, .little);
        std.mem.writeInt(u32, hdr[12..16], str_at[20], .little);
        std.mem.writeInt(u32, hdr[16..20], 3, .little);
        try types.appendSlice(a, &hdr);
    }
    // id 14 task_struct
    {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        var hdr: [12]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[12], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 6, .little);
        std.mem.writeInt(u32, hdr[8..12], 80, .little);
        try body.appendSlice(a, &hdr);
        const members = [_]struct { n: u32, t: u32, bit: u32 }{
            .{ .n = str_at[13], .t = 2, .bit = 0 }, // pid
            .{ .n = str_at[16], .t = 2, .bit = 32 }, // __state at byte 4
            .{ .n = str_at[14], .t = 8, .bit = 64 }, // comm at byte 8
            .{ .n = str_at[15], .t = 5, .bit = 192 }, // tasks at byte 24
            .{ .n = str_at[17], .t = 2, .bit = 320 }, // cpu at byte 40
            .{ .n = str_at[18], .t = 12, .bit = 384 }, // thread_struct (id 12) at byte 48
        };
        for (members) |member| {
            var raw: [12]u8 = @splat(0);
            std.mem.writeInt(u32, raw[0..4], member.n, .little);
            std.mem.writeInt(u32, raw[4..8], member.t, .little);
            std.mem.writeInt(u32, raw[8..12], member.bit, .little);
            try body.appendSlice(a, &raw);
        }
        try types.appendSlice(a, body.items);
    }
    // id 15 inactive_task_frame { bp @ 0, ret_addr @ 64 bits }
    {
        var hdr: [12 + 24]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[21], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 2, .little);
        std.mem.writeInt(u32, hdr[8..12], 16, .little);
        std.mem.writeInt(u32, hdr[12..16], str_at[22], .little);
        std.mem.writeInt(u32, hdr[16..20], 3, .little);
        std.mem.writeInt(u32, hdr[24..28], str_at[23], .little);
        std.mem.writeInt(u32, hdr[28..32], 3, .little);
        std.mem.writeInt(u32, hdr[32..36], 64, .little);
        try types.appendSlice(a, &hdr);
    }
    // id 16 pt_regs { ip @ 0, sp @ 64 bits }
    {
        var hdr: [12 + 24]u8 = @splat(0);
        std.mem.writeInt(u32, hdr[0..4], str_at[24], .little);
        std.mem.writeInt(u32, hdr[4..8], (4 << 24) | 2, .little);
        std.mem.writeInt(u32, hdr[8..12], 16, .little);
        std.mem.writeInt(u32, hdr[12..16], str_at[25], .little);
        std.mem.writeInt(u32, hdr[16..20], 3, .little);
        // second member name "sp" is str_at[20], same string as thread_struct.sp
        std.mem.writeInt(u32, hdr[24..28], str_at[20], .little);
        std.mem.writeInt(u32, hdr[28..32], 3, .little);
        std.mem.writeInt(u32, hdr[32..36], 64, .little);
        try types.appendSlice(a, &hdr);
    }
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(a);
    var header: [24]u8 = @splat(0);
    std.mem.writeInt(u16, header[0..2], 0xeb9f, .little);
    header[2] = 1;
    std.mem.writeInt(u32, header[4..8], 24, .little);
    std.mem.writeInt(u32, header[8..12], 0, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(types.items.len), .little);
    std.mem.writeInt(u32, header[16..20], @intCast(types.items.len), .little);
    std.mem.writeInt(u32, header[20..24], @intCast(off), .little);
    try image.appendSlice(a, &header);
    try image.appendSlice(a, types.items);
    try image.appendSlice(a, strings[0..off]);
    const facts = try factsFromBtf(image.items);
    try std.testing.expectEqual(@as(u32, 0), facts.list_next);
    try std.testing.expectEqual(@as(u32, 16), facts.name_off);
    try std.testing.expectEqual(@as(u16, 8), facts.name_len);
    try std.testing.expectEqual(@as(u32, 32), facts.mem_off);
    try std.testing.expectEqual(@as(u32, 16), facts.mem_stride);
    try std.testing.expectEqual(@as(u32, 0), facts.text_base);
    try std.testing.expectEqual(@as(u32, 8), facts.text_size);
    try std.testing.expectEqual(@as(u32, 48), facts.build_id_off.?);
    try std.testing.expectEqual(@as(u32, 48), facts.thread_sp.?);
    try std.testing.expectEqual(@as(u32, 8), facts.saved_ret.?);
    try std.testing.expectEqual(@as(u32, 8), facts.pt_sp.?);
    try std.testing.expectEqual(@as(u32, 16), facts.pt_size.?);
    try std.testing.expectError(error.BtfMalformed, factsFromBtf(&[_]u8{ 1, 2, 3, 4 }));
}

test "module layout puts data after the earlier writable sections" {
    const ax: u64 = shf_exec | shf_alloc;
    const wa: u64 = shf_write | shf_alloc;
    const ro: u64 = shf_alloc;
    const secs = [_]AllocSec{
        .{ .flags = ro, .size = 0x18, .alignment = 8 },
        .{ .flags = wa, .size = 0x38, .alignment = 8 },
        .{ .flags = ax, .size = 0x204, .alignment = 16 },
        .{ .flags = wa, .size = 0x40, .alignment = 8 },
        .{ .flags = wa, .size = 0x28, .alignment = 8 },
        .{ .flags = ro, .size = 0xd8, .alignment = 1 },
        .{ .init = true, .flags = ax, .size = 0xc3, .alignment = 16 },
        .{ .flags = ax, .size = 0x49, .alignment = 16 },
    };
    var out: [secs.len]Place = undefined;
    layoutAlloc(&secs, &out);
    try std.testing.expectEqual(@as(u8, 0), out[2].kind);
    try std.testing.expectEqual(@as(u64, 0), out[2].offset);
    try std.testing.expectEqual(@as(u8, 0), out[7].kind);
    try std.testing.expectEqual(@as(u64, 0x210), out[7].offset);
    try std.testing.expectEqual(@as(u8, 1), out[4].kind);
    try std.testing.expectEqual(@as(u64, 0x78), out[4].offset);
    try std.testing.expectEqual(@as(u8, 4), out[6].kind);
    try std.testing.expectEqual(@as(u8, 2), out[5].kind);
    const stacked: u64 = 0xffffffff81000040;
    const entered = try entryFrame(false, 0xffffffff8100f000, 0, 0xffffffff8100e000, stacked);
    try std.testing.expectEqual(stacked, entered.ip);
    try std.testing.expectEqual(@as(u64, 0xffffffff8100f008), entered.sp);
    const arm = try entryFrame(true, 0xffff80001000, 0xffff80002000, 0xffff80003000, 0);
    try std.testing.expectEqual(@as(u64, 0xffff80002000), arm.ip);
    try std.testing.expectEqual(@as(u64, 0xffff80003000), arm.bp);
}

test "KGHANG a reader-owned rwsem names no owner" {
    const tasks = [_]TaskRow{.{ .address = 0x1000, .pid = 7, .comm = "writer".* ++ [_]u8{0} ** 10, .comm_len = 6 }};
    var buf: [128]u8 = undefined;
    const text = formatWait(.{ .waiter = 0x1000, .lock = 0x5000, .kind = .rwsem, .owner = 0, .readers = true }, &tasks, &buf);
    try std.testing.expectEqualStrings("writer waits on rwsem 0x5000 held by readers (readers are not tracked)", text);
}

test "KGHANG a wait list that cycles without its head gives no edge" {
    var mem = [_]u8{0} ** 0x1000;
    putU64(&mem, 0x100, 0x200); // the waiter's list node points into a loop
    putU64(&mem, 0x200, 0x300);
    putU64(&mem, 0x300, 0x200); // never returns to 0x100
    const task = TaskRow{ .address = 0x800, .pid = 9 };
    const ranges = [_]StackRange{.{ .base = 0x200, .end = 0x400 }};
    const layout = LockLayout{ .owner = 0, .wait_list = 0x10, .waiter_list = 0, .waiter_task = 0x10 };
    try std.testing.expect(closeWait(Flat{ .bytes = &mem }, task, &.{task}, &ranges, 0x100, layout, &.{}, .mutex, true) == null);
}

test "KGHANG a reader-owned rwsem gives a readers edge, not the last reader" {
    var mem = [_]u8{0} ** 0x1000;
    putU64(&mem, 0x200, 0x510); // waiter node on the stack -> the lock's wait_list
    putU64(&mem, 0x510, 0x200); // and back: the list is closed
    putU64(&mem, 0x500, 0x181); // owner word: last reader 0x180 | RWSEM_READER_OWNED
    const waiter = TaskRow{ .address = 0x800, .pid = 9 };
    const reader = TaskRow{ .address = 0x180, .pid = 3 };
    const ranges = [_]StackRange{.{ .base = 0x200, .end = 0x400 }};
    const layout = LockLayout{ .owner = 0, .wait_list = 0x10, .waiter_list = 0, .waiter_task = 0x10 };
    const edge = closeWait(Flat{ .bytes = &mem }, waiter, &.{ waiter, reader }, &ranges, 0x200, layout, &.{}, .rwsem, false).?;
    try std.testing.expect(edge.readers and edge.owner == 0 and edge.lock == 0x500);
}

fn named(address: u64, pid: i32, name: []const u8) TaskRow {
    var task = TaskRow{ .address = address, .pid = pid };
    @memcpy(task.comm[0..name.len], name);
    task.comm_len = @intCast(name.len);
    return task;
}

test "KGHANG an owner that is not a walked task is named unknown" {
    var mem = [_]u8{0} ** 0x1000;
    putU64(&mem, 0x200, 0x510);
    putU64(&mem, 0x510, 0x200);
    putU64(&mem, 0x500, 0);
    const waiter = named(0x800, 9, "waiter");
    const ranges = [_]StackRange{.{ .base = 0x200, .end = 0x400 }};
    const layout = LockLayout{ .owner = 0, .wait_list = 0x10, .waiter_list = 0, .waiter_task = 0x10 };
    try std.testing.expect(closeWait(Flat{ .bytes = &mem }, waiter, &.{waiter}, &ranges, 0x200, layout, &.{}, .mutex, false) == null);
    const empty = closeWait(Flat{ .bytes = &mem }, waiter, &.{waiter}, &ranges, 0x200, layout, &.{}, .mutex, true).?;
    try std.testing.expect(empty.unknown_owner and empty.owner == 0 and empty.lock == 0x500 and !empty.readers);
    var line: [160]u8 = undefined;
    const tasks = [_]TaskRow{waiter};
    try std.testing.expectEqualStrings("waiter waits on lock 0x500 owned by an unknown task", formatWait(empty, &tasks, &line));
    putU64(&mem, 0x500, 0x999);
    const stray = closeWait(Flat{ .bytes = &mem }, waiter, &.{waiter}, &ranges, 0x200, layout, &.{}, .mutex, true).?;
    try std.testing.expect(stray.unknown_owner and stray.owner == 0);
    putU64(&mem, 0x500, 0x800);
    const self_owned = closeWait(Flat{ .bytes = &mem }, waiter, &.{waiter}, &ranges, 0x200, layout, &.{}, .mutex, true).?;
    try std.testing.expect(self_owned.unknown_owner and self_owned.owner == 0);
}

test "KGHANG blocked_on that matches no lock type is an unknown lock" {
    var mem = [_]u8{0} ** 0x6020;
    const facts = Facts{
        .list_next = 0,
        .name_off = 0,
        .name_len = 1,
        .state_off = 0,
        .mem_off = 0,
        .mem_stride = 1,
        .text_base = 0,
        .text_size = 1,
        .pid_off = 0,
        .comm_off = 0,
        .comm_len = 1,
        .tasks_next = 0,
        .stack_off = 0,
        .task_blocked_on = 8,
    };
    const waiter = named(0x100, 4, "blocked");
    var row = waiter;
    row.state = 2;
    putU64(&mem, 0x100, 0x1000);
    putU64(&mem, 0x108, 0x6000);
    const tasks = [_]TaskRow{row};
    var edges: [4]WaitEdge = undefined;
    const n = try walkWaits(Flat{ .bytes = &mem }, &tasks, facts, &.{}, &edges);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(WaitKind.unknown, edges[0].kind);
    try std.testing.expectEqual(@as(u64, 0x6000), edges[0].lock);
    try std.testing.expect(edges[0].unknown_owner);
    var line: [160]u8 = undefined;
    try std.testing.expectEqualStrings("blocked waits on an unknown lock at 0x6000", formatWait(edges[0], &tasks, &line));
    putU64(&mem, 0x108, 0);
    try std.testing.expectEqual(@as(usize, 0), try walkWaits(Flat{ .bytes = &mem }, &tasks, facts, &.{}, &edges));
}

test "KGHANG a wait chain names each hop and stops at the bound" {
    const tasks = [_]TaskRow{
        named(0x1000, 1, "A"),
        named(0x2000, 2, "B"),
        named(0x3000, 3, "C"),
        named(0x4000, 4, "D"),
        named(0x5000, 5, "E"),
        named(0x6000, 6, "F"),
    };
    const two = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x3000 },
    };
    var buf: [500]u8 = undefined;
    try std.testing.expectEqualStrings("A waits on lock 0x11 owned by B, which waits on lock 0x22 owned by C", formatChain(&two, 0, &tasks, &buf));
    const edges = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x3000 },
        .{ .waiter = 0x3000, .lock = 0x33, .kind = .mutex, .owner = 0x4000 },
        .{ .waiter = 0x4000, .lock = 0x44, .kind = .mutex, .owner = 0x5000 },
        .{ .waiter = 0x5000, .lock = 0x55, .kind = .mutex, .owner = 0x6000 },
    };
    const bounded = formatChain(&edges, 0, &tasks, &buf);
    try std.testing.expectEqualStrings("A waits on lock 0x11 owned by B, which waits on lock 0x22 owned by C, which waits on lock 0x33 owned by D, which waits on lock 0x44 owned by E", bounded);
    try std.testing.expect(std.mem.indexOf(u8, bounded, "F") == null);
    const cycle = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x1000 },
    };
    const closed = formatChain(&cycle, 0, &tasks, &buf);
    try std.testing.expectEqualStrings("A waits on lock 0x11 owned by B, which waits on lock 0x22 owned by A", closed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, closed, "0x11"));
}

test "KGHANG a chain cut by a short label buffer says so" {
    const tasks = [_]TaskRow{ named(0xffff961301001000, 80, "kg0-blocked"), named(0xffff961301002000, 81, "kg0-spinner"), named(0xffff961301003000, 82, "kg0-holder") };
    const two = [_]WaitEdge{
        .{ .waiter = 0xffff961301001000, .lock = 0xffffffffc00fb068, .kind = .mutex, .owner = 0xffff961301002000 },
        .{ .waiter = 0xffff961301002000, .lock = 0xffffffffc00fb0a0, .kind = .mutex, .owner = 0xffff961301003000, .owner_cpu = 1 },
    };
    var buf: [92]u8 = undefined; // a label tail after "comm pid= state= cpu="
    try std.testing.expectEqualStrings("kg0-blocked waits on lock 0xffffffffc00fb068 owned by kg0-spinner, ..", formatChain(&two, 0, &tasks, &buf));
    var wide: [400]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, formatChain(&two, 0, &tasks, &wide), "owned by kg0-holder, which spins on CPU 1") != null);
}

test "KGHANG a published chain says whether it was cut or closed a cycle" {
    var names = [_]TaskRow{ .{ .address = 0x1000, .pid = 1 }, .{ .address = 0x2000, .pid = 2 }, .{ .address = 0x3000, .pid = 3 }, .{ .address = 0x4000, .pid = 4 }, .{ .address = 0x5000, .pid = 5 }, .{ .address = 0x6000, .pid = 6 } };
    _ = &names;
    var hops: [4]WaitHop = undefined;
    var end: ChainEnd = .complete;
    const five = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x3000 },
        .{ .waiter = 0x3000, .lock = 0x33, .kind = .mutex, .owner = 0x4000 },
        .{ .waiter = 0x4000, .lock = 0x44, .kind = .mutex, .owner = 0x5000 },
        .{ .waiter = 0x5000, .lock = 0x55, .kind = .mutex, .owner = 0x6000 },
    };
    try std.testing.expectEqual(@as(usize, 4), chainHopsEnd(&five, &names, 0x1000, &hops, &end));
    try std.testing.expectEqual(ChainEnd.truncated, end);
    try std.testing.expectEqual(@as(usize, 4), chainHopsEnd(five[0..4], &names, 0x1000, &hops, &end));
    try std.testing.expectEqual(ChainEnd.complete, end);
    const cycle = [_]WaitEdge{
        .{ .waiter = 0x1000, .lock = 0x11, .kind = .mutex, .owner = 0x2000 },
        .{ .waiter = 0x2000, .lock = 0x22, .kind = .mutex, .owner = 0x1000 },
    };
    try std.testing.expectEqual(@as(usize, 2), chainHopsEnd(&cycle, &names, 0x1000, &hops, &end));
    try std.testing.expectEqual(ChainEnd.cycle, end);
}
