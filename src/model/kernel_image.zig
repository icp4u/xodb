//! vmlinux section helpers. Offsets come from DWARF when the image has it,
//! and from BTF only when DWARF is absent. ORC tables are copied so a later
//! unmap of the file cannot move them.

const std = @import("std");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const aware = @import("kernel_aware.zig");

pub const Orc = struct {
    base: u64,
    ips: []i32,
    entries: []u8,
};

/// Copy `.orc_unwind_ip` and `.orc_unwind`. A missing pair is not an error.
/// `slide` is the KASLR slide of an ET_EXEC image. A relocatable file whose
/// section address is zero has no runtime base here; the caller uses frames.
pub fn copyOrc(a: std.mem.Allocator, image: *const elf.Image, slide: u64) !?Orc {
    const ips_sec = image.sectionByName(".orc_unwind_ip") orelse return null;
    const ent_sec = image.sectionByName(".orc_unwind") orelse return null;
    // A relocatable object has no load address for this table. The module
    // loader applies its relocations separately.
    if ((image.header.type != .executable and image.header.type != .shared) or ips_sec.addr == 0) return null;
    const width: usize = switch (image.header.machine) {
        .x86_64 => 6,
        .loongarch => 8,
        else => return null,
    };
    const ip_bytes = image.sectionData(ips_sec) catch return error.KernelOrcMalformed;
    const entries = image.sectionData(ent_sec) catch return error.KernelOrcMalformed;
    if (ip_bytes.len == 0 or ip_bytes.len % 4 != 0 or entries.len % width != 0) return error.KernelOrcMalformed;
    const count = ip_bytes.len / 4;
    if (count != entries.len / width) return error.KernelOrcMalformed;
    const ips = try a.alloc(i32, count);
    errdefer a.free(ips);
    for (ips, 0..) |*slot, index| slot.* = std.mem.readInt(i32, ip_bytes[index * 4 ..][0..4], .little);
    const copy = try a.dupe(u8, entries);
    errdefer a.free(copy);
    const base = std.math.add(u64, ips_sec.addr, slide) catch return error.InvalidAddress;
    return .{ .base = base, .ips = ips, .entries = copy };
}

fn want(owner: u8, name: [*:0]const u8, kind: c_uint, optional: bool) c.struct_xdt_field {
    return .{ .owner = owner, .name = name, .kind = @intCast(kind), .width = 0, .optional = @intFromBool(optional) };
}

const type_names = [_][*:0]const u8{ "module", "module_memory", "task_struct", "inactive_task_frame", "pt_regs" };
const fields = [_]c.struct_xdt_field{
    want(0, "list.next", c.XDT_POINTER, false),
    want(0, "name", c.XDT_ANY, false),
    want(0, "state", c.XDT_ANY, false),
    want(0, "mem", c.XDT_ANY, false),
    want(0, "build_id", c.XDT_ANY, true),
    want(1, "base", c.XDT_POINTER, false),
    want(1, "size", c.XDT_ANY, false),
    want(2, "pid", c.XDT_ANY, false),
    want(2, "comm", c.XDT_ANY, false),
    want(2, "tasks.next", c.XDT_POINTER, false),
    want(2, "__state", c.XDT_ANY, true),
    want(2, "state", c.XDT_ANY, true),
    want(2, "thread_info.cpu", c.XDT_ANY, true),
    want(2, "thread.sp", c.XDT_ANY, true),
    want(2, "thread.cpu_context.pc", c.XDT_ANY, true),
    want(2, "thread.cpu_context.sp", c.XDT_ANY, true),
    want(2, "thread.cpu_context.fp", c.XDT_ANY, true),
    want(3, "bp", c.XDT_ANY, false),
    want(3, "ret_addr", c.XDT_ANY, false),
    want(4, "ip", c.XDT_ANY, false),
    want(4, "sp", c.XDT_ANY, false),
};

fn layoutName(text: []const u8) anyerror {
    const names = [_][]const u8{
        "DwarfTypesUnavailable",
        "DwarfTypesMalformed",
        "DwarfTypesWorkLimit",
        "DwarfTypesUnitLimit",
        "DwarfTypesSchemaLimit",
        "DwarfTypeNotFound",
        "DwarfTypeAmbiguous",
        "DwarfFieldNotFound",
        "DwarfFieldMismatch",
    };
    const errors = [_]anyerror{
        error.DwarfTypesUnavailable,
        error.DwarfTypesMalformed,
        error.DwarfTypesWorkLimit,
        error.DwarfTypesUnitLimit,
        error.DwarfTypesSchemaLimit,
        error.DwarfTypeNotFound,
        error.DwarfTypeAmbiguous,
        error.DwarfFieldNotFound,
        error.DwarfFieldMismatch,
    };
    for (names, errors) |name, err| if (std.mem.eql(u8, text, name)) return err;
    return error.KernelTypeInfoUnavailable;
}

fn present(slot: c.struct_xdt_slot) ?u32 {
    return if (slot.present != 0) slot.offset else null;
}

/// One walk of the image. `work` bounds the DIE visits. A vmlinux needs more
/// than a language runtime; the caller passes that bound.
pub fn factsFromDwarf(dwarf: *c.Dwarf, work: u64) !aware.Facts {
    const schema = c.struct_xdt_schema{
        .types = @ptrCast(&type_names),
        .fields = &fields,
        .type_count = type_names.len,
        .field_count = fields.len,
        .optional_types = (1 << 3) | (1 << 4),
    };
    var slots: [fields.len]c.struct_xdt_slot = undefined;
    var sizes: [type_names.len]u32 = undefined;
    var stats: c.struct_xdt_stats = undefined;
    if (c.xdt_layout_build(dwarf, &schema, work, &slots, &sizes, &stats)) |why| return layoutName(std.mem.span(why));
    if (sizes[1] == 0 or slots[1].size == 0 or slots[1].size > 64 or slots[7].size != 4) return error.KernelTypeInfoUnavailable;
    var facts = aware.Facts{
        .list_next = slots[0].offset,
        .name_off = slots[1].offset,
        .name_len = @intCast(slots[1].size),
        .state_off = slots[2].offset,
        .mem_off = slots[3].offset,
        .mem_stride = sizes[1],
        .text_base = slots[5].offset,
        .text_size = slots[6].offset,
        .pid_off = slots[7].offset,
        .comm_off = slots[8].offset,
        .comm_len = @intCast(slots[8].size),
        .tasks_next = slots[9].offset,
    };
    if (facts.comm_len == 0 or facts.comm_len > 16) return error.KernelTypeInfoUnavailable;
    if (present(slots[4])) |off| {
        if (slots[4].size > 0 and slots[4].size <= 64) {
            facts.build_id_off = off;
            facts.build_id_len = @intCast(slots[4].size);
        }
    }
    if (present(slots[10])) |off| {
        facts.task_state_off = off;
    } else if (present(slots[11])) |off| {
        facts.task_state_off = off;
    }
    if (present(slots[12])) |off| facts.cpu_off = off;
    if (present(slots[13])) |off| facts.thread_sp = off;
    if (present(slots[14])) |off| facts.arm_pc = off;
    if (present(slots[15])) |off| facts.arm_sp = off;
    if (present(slots[16])) |off| facts.arm_fp = off;
    if (present(slots[17])) |off| facts.saved_bp = off;
    if (present(slots[18])) |off| facts.saved_ret = off;
    if (present(slots[19]) != null and present(slots[20]) != null and sizes[4] >= 8) {
        facts.pt_size = sizes[4];
        facts.pt_ip = slots[19].offset;
        facts.pt_sp = slots[20].offset;
    }
    return facts;
}

pub fn factsFromImage(image: *const elf.Image, dwarf: ?*c.Dwarf, work: u64) !aware.Facts {
    var facts = if (dwarf) |handle|
        factsFromDwarf(handle, work) catch |err| switch (err) {
            error.DwarfTypesUnavailable => try factsFromBtf(image),
            else => return err,
        }
    else
        try factsFromBtf(image);
    fillLocks(&facts, image, dwarf, work);
    return facts;
}

fn fillLocks(facts: *aware.Facts, image: *const elf.Image, dwarf: ?*c.Dwarf, work: u64) void {
    if (dwarf) |handle| _ = fillLocksDwarf(facts, handle, work);
    if (facts.stack_off != null and facts.mutex_owner != null and facts.rwsem_owner != null) return;
    const section = image.sectionByName(".BTF") orelse return;
    const bytes = image.sectionData(section) catch return;
    fillLocksBtf(facts, bytes);
}

fn fillLocksDwarf(facts: *aware.Facts, dwarf: *c.Dwarf, work: u64) bool {
    const names = [_][*:0]const u8{ "task_struct", "mutex", "mutex_waiter", "rw_semaphore", "rwsem_waiter" };
    const wanted = [_]c.struct_xdt_field{
        want(0, "stack", c.XDT_POINTER, true),
        want(0, "blocked_on", c.XDT_POINTER, true),
        want(1, "owner", c.XDT_ANY, true),
        want(1, "wait_list", c.XDT_ANY, true),
        want(1, "first_waiter", c.XDT_POINTER, true),
        want(2, "list", c.XDT_ANY, true),
        want(2, "task", c.XDT_POINTER, true),
        want(3, "owner", c.XDT_ANY, true),
        want(3, "wait_list", c.XDT_ANY, true),
        want(3, "first_waiter", c.XDT_POINTER, true),
        want(4, "list", c.XDT_ANY, true),
        want(4, "task", c.XDT_POINTER, true),
    };
    const schema = c.struct_xdt_schema{
        .types = @ptrCast(&names),
        .fields = &wanted,
        .type_count = names.len,
        .field_count = wanted.len,
        .optional_types = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4),
    };
    var slots: [wanted.len]c.struct_xdt_slot = undefined;
    var sizes: [names.len]u32 = undefined;
    var stats: c.struct_xdt_stats = undefined;
    if (c.xdt_layout_build(dwarf, &schema, work, &slots, &sizes, &stats)) |_| return false;
    if (present(slots[0])) |off| facts.stack_off = off;
    if (present(slots[1])) |off| facts.task_blocked_on = off;
    if (present(slots[2])) |owner| {
        if (present(slots[3]) != null and present(slots[5]) != null and present(slots[6]) != null) {
            facts.mutex_owner = owner;
            facts.mutex_wait_list = slots[3].offset;
            facts.mutex_waiter_list = slots[5].offset;
            facts.mutex_waiter_task = slots[6].offset;
        }
        if (present(slots[4]) != null and present(slots[6]) != null) {
            facts.mutex_owner = owner;
            facts.mutex_first_waiter = slots[4].offset;
            facts.mutex_waiter_task = slots[6].offset;
        }
    }
    if (present(slots[7])) |owner| {
        if (present(slots[8]) != null and present(slots[10]) != null and present(slots[11]) != null) {
            facts.rwsem_owner = owner;
            facts.rwsem_wait_list = slots[8].offset;
            facts.rwsem_waiter_list = slots[10].offset;
            facts.rwsem_waiter_task = slots[11].offset;
        }
        if (present(slots[9]) != null and present(slots[11]) != null) {
            facts.rwsem_owner = owner;
            facts.rwsem_first_waiter = slots[9].offset;
            facts.rwsem_waiter_task = slots[11].offset;
        }
    }
    return facts.stack_off != null or facts.mutex_owner != null or facts.rwsem_owner != null;
}

fn fillLocksBtf(facts: *aware.Facts, bytes: []const u8) void {
    if (facts.stack_off == null) {
        if (aware.btfMember(bytes, "task_struct", "stack")) |slot| facts.stack_off = slot.offset else |_| {}
    }
    if (facts.task_blocked_on == null) {
        if (aware.btfMember(bytes, "task_struct", "blocked_on")) |slot| facts.task_blocked_on = slot.offset else |_| {}
    }
    if (facts.mutex_owner == null) {
        if (aware.btfMember(bytes, "mutex", "owner")) |owner| {
            if (aware.btfMember(bytes, "mutex", "wait_list")) |list| {
                if (aware.btfMember(bytes, "mutex_waiter", "list")) |waiter_list| {
                    if (aware.btfMember(bytes, "mutex_waiter", "task")) |task| {
                        facts.mutex_owner = owner.offset;
                        facts.mutex_wait_list = list.offset;
                        facts.mutex_waiter_list = waiter_list.offset;
                        facts.mutex_waiter_task = task.offset;
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }
    if (facts.mutex_first_waiter == null) {
        if (aware.btfMember(bytes, "mutex", "owner")) |owner| {
            if (aware.btfMember(bytes, "mutex", "first_waiter")) |first| {
                if (aware.btfMember(bytes, "mutex_waiter", "task")) |task| {
                    facts.mutex_owner = owner.offset;
                    facts.mutex_first_waiter = first.offset;
                    facts.mutex_waiter_task = task.offset;
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }
    if (facts.rwsem_owner == null) {
        if (aware.btfMember(bytes, "rw_semaphore", "owner")) |owner| {
            if (aware.btfMember(bytes, "rw_semaphore", "wait_list")) |list| {
                if (aware.btfMember(bytes, "rwsem_waiter", "list")) |waiter_list| {
                    if (aware.btfMember(bytes, "rwsem_waiter", "task")) |task| {
                        facts.rwsem_owner = owner.offset;
                        facts.rwsem_wait_list = list.offset;
                        facts.rwsem_waiter_list = waiter_list.offset;
                        facts.rwsem_waiter_task = task.offset;
                    } else |_| {}
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }
    if (facts.rwsem_first_waiter == null) {
        if (aware.btfMember(bytes, "rw_semaphore", "owner")) |owner| {
            if (aware.btfMember(bytes, "rw_semaphore", "first_waiter")) |first| {
                if (aware.btfMember(bytes, "rwsem_waiter", "task")) |task| {
                    facts.rwsem_owner = owner.offset;
                    facts.rwsem_first_waiter = first.offset;
                    facts.rwsem_waiter_task = task.offset;
                } else |_| {}
            } else |_| {}
        } else |_| {}
    }
}

fn factsFromBtf(image: *const elf.Image) !aware.Facts {
    const section = image.sectionByName(".BTF") orelse return error.KernelTypeInfoUnavailable;
    const bytes = image.sectionData(section) catch return error.KernelTypeInfoUnavailable;
    return aware.factsFromBtf(bytes);
}

pub fn textSection(image: *const elf.Image) ?u32 {
    const section = image.sectionByName(".text") orelse return null;
    if (section.index == 0) return null;
    return section.index;
}
