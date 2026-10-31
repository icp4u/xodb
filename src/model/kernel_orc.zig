//! x86 ORC lookup. Each IP entry is an s32 added to the address of that entry.
//! The search keeps the rightmost entry whose address is at or below the
//! instruction, matching the kernel's range search. Entries are 6 bytes.

const std = @import("std");

pub const Reg = enum(u4) {
    undefined = 0,
    ax = 1,
    dx = 2,
    sp = 3,
    bp = 4,
    di = 5,
    r10 = 6,
    r13 = 7,
    prev_sp = 8,
    sp_indirect = 9,
    bp_indirect = 10,
    _,
};

pub const Type = enum(u3) {
    undefined = 0,
    end_of_stack = 1,
    call = 2,
    regs = 3,
    regs_partial = 4,
    _,
};

pub const Entry = struct {
    sp_offset: i16,
    bp_offset: i16,
    sp_reg: Reg,
    bp_reg: Reg,
    type: Type,
    signal: bool,
};

pub fn decode(bytes: []const u8) ?Entry {
    if (bytes.len < 6) return null;
    const bits: u16 = @as(u16, bytes[4]) | (@as(u16, bytes[5]) << 8);
    return .{
        .sp_offset = std.mem.readInt(i16, bytes[0..2], .little),
        .bp_offset = std.mem.readInt(i16, bytes[2..4], .little),
        .sp_reg = @enumFromInt(bits & 0xf),
        .bp_reg = @enumFromInt((bits >> 4) & 0xf),
        .type = @enumFromInt((bits >> 8) & 0x7),
        .signal = (bits >> 11) & 1 != 0,
    };
}

/// `ips` are the raw s32 table. `base` is the runtime address of `ips[0]`.
/// Returns the index of the rightmost entry at or below `ip`, if the table
/// is non-empty. A table whose first address is already above `ip` still
/// returns index 0, as the kernel search does.
pub fn find(base: u64, ips: []const i32, ip: u64) ?usize {
    if (ips.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = ips.len;
    var found: usize = 0;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = base +% @as(u64, mid *% 4) +% @as(u64, @bitCast(@as(i64, ips[mid])));
        if (at <= ip) {
            found = mid;
            lo = mid + 1;
        } else hi = mid;
    }
    return found;
}

pub const Regs = struct {
    ip: u64,
    sp: u64,
    bp: u64,
    ra: u64 = 0,
    ax: ?u64 = null,
    dx: ?u64 = null,
    di: ?u64 = null,
    r10: ?u64 = null,
    r13: ?u64 = null,
};

/// Byte offsets of `ip` and `sp` inside the image's `pt_regs`, plus the
/// struct's size. Call frames do not need this. Register and iret frames do.
pub const Pt = struct {
    size: u32,
    ip: u32,
    sp: u32,
};

pub const Frame = struct {
    ip: u64,
    sp: u64,
    bp: u64,
    ra: u64 = 0,
    outermost: bool = false,
    signal: bool = false,
};

/// Encode a runtime instruction so `find(base, ips, ip)` recovers it. The low
/// 32 bits of `ip - base - index * 4` are stored; the round trip must be exact.
/// A zero base only covers addresses in the signed 32-bit window.
pub fn encodeIp(base: u64, index: usize, ip: u64) ?i32 {
    const adjusted = ip -% base -% @as(u64, index *% 4);
    const low: i32 = @bitCast(@as(u32, @truncate(adjusted)));
    const back = base +% @as(u64, index *% 4) +% @as(u64, @bitCast(@as(i64, low)));
    if (back != ip) return null;
    return low;
}

fn readU64(memory: anytype, address: u64) !u64 {
    var buf: [8]u8 = undefined;
    const n = try memory.read(address, &buf);
    if (n != buf.len) return error.OrcMemory;
    return std.mem.readInt(u64, &buf, .little);
}

fn addOffset(base: u64, offset: i16) !u64 {
    if (offset >= 0) return std.math.add(u64, base, @intCast(offset)) catch error.OrcAddress;
    const mag: u64 = @intCast(-@as(i32, offset));
    if (base < mag) return error.OrcAddress;
    return base - mag;
}

/// One x86-64 ORC step. `pt` is required for register and partial-register
/// frames; its offsets come from the image's type information. A call frame
/// reads the return address at the previous SP minus one word.
pub fn step(entry: Entry, regs: Regs, pt: ?Pt, memory: anytype) !Frame {
    if (entry.type == .undefined) return error.OrcUndefined;
    if (entry.type == .end_of_stack) return error.OrcEndOfStack;
    var sp: u64 = undefined;
    var indirect = false;
    switch (entry.sp_reg) {
        .sp => sp = try addOffset(regs.sp, entry.sp_offset),
        .bp => sp = try addOffset(regs.bp, entry.sp_offset),
        .sp_indirect => {
            sp = regs.sp;
            indirect = true;
        },
        .bp_indirect => {
            sp = try addOffset(regs.bp, entry.sp_offset);
            indirect = true;
        },
        .ax => sp = regs.ax orelse return error.OrcRegisterUnavailable,
        .dx => sp = regs.dx orelse return error.OrcRegisterUnavailable,
        .di => sp = regs.di orelse return error.OrcRegisterUnavailable,
        .r10 => sp = regs.r10 orelse return error.OrcRegisterUnavailable,
        .r13 => sp = regs.r13 orelse return error.OrcRegisterUnavailable,
        else => return error.OrcRegisterUnavailable,
    }
    if (indirect) {
        sp = try readU64(memory, sp);
        if (entry.sp_reg == .sp_indirect) sp = try addOffset(sp, entry.sp_offset);
    }
    var next_ip: u64 = undefined;
    var next_sp: u64 = undefined;
    switch (entry.type) {
        .call => {
            if (sp < 8 or sp <= regs.sp) return error.OrcStackDirection;
            next_ip = try readU64(memory, sp - 8);
            next_sp = sp;
        },
        .regs, .regs_partial => {
            const layout = pt orelse return error.OrcPtRegsUnavailable;
            if (layout.ip >= layout.size or layout.sp >= layout.size or layout.ip + 8 > layout.size or layout.sp + 8 > layout.size) return error.OrcPtRegsUnavailable;
            const slot: u64 = if (entry.type == .regs) sp else blk: {
                // A partial frame's SP points at `ip`. The register block
                // begins that many bytes earlier, which is the kernel's iret offset.
                if (sp < layout.ip) return error.OrcAddress;
                break :blk sp - layout.ip;
            };
            next_ip = try readU64(memory, slot + layout.ip);
            next_sp = try readU64(memory, slot + layout.sp);
            if (next_sp <= regs.sp) return error.OrcStackDirection;
        },
        else => return error.OrcUndefined,
    }
    const next_bp: u64 = switch (entry.bp_reg) {
        .undefined => regs.bp,
        .prev_sp => try readU64(memory, try addOffset(sp, entry.bp_offset)),
        .bp => try readU64(memory, try addOffset(regs.bp, entry.bp_offset)),
        else => return error.OrcRegisterUnavailable,
    };
    return .{
        .ip = next_ip,
        .sp = next_sp,
        .bp = next_bp,
        .signal = entry.signal,
    };
}

/// Rightmost entry at or below `ip`. `entries` are packed 6-byte records in
/// the same order as `ips`.
pub fn entryAt(base: u64, ips: []const i32, entries: []const u8, ip: u64) ?Entry {
    const index = find(base, ips, ip) orelse return null;
    const at = std.math.mul(usize, index, 6) catch return null;
    if (at + 6 > entries.len) return null;
    return decode(entries[at..][0..6]);
}

test "orc find keeps the rightmost entry at or below the instruction" {
    // Entry addresses: base+0, base+16, base+16 (duplicate), base+64.
    // Relatives are measured from each entry's own address.
    const base: u64 = 0x1000;
    const ips = [_]i32{
        0, // address 0x1000
        12, // address 0x1004+12 = 0x1010
        8, // address 0x1008+8 = 0x1010
        52, // address 0x100c+52 = 0x1040
    };
    try std.testing.expectEqual(@as(?usize, 0), find(base, &ips, 0x1000));
    try std.testing.expectEqual(@as(?usize, 0), find(base, &ips, 0x100f));
    try std.testing.expectEqual(@as(?usize, 2), find(base, &ips, 0x1010));
    try std.testing.expectEqual(@as(?usize, 2), find(base, &ips, 0x103f));
    try std.testing.expectEqual(@as(?usize, 3), find(base, &ips, 0x1040));
    try std.testing.expectEqual(@as(?usize, null), find(base, &.{}, 0x1000));
}

test "orc entry bytes decode the packed base registers" {
    var raw = [_]u8{ 0x08, 0x00, 0xf8, 0xff, 0x34, 0x0a };
    // sp_offset 8, bp_offset -8, sp_reg=4 (bp), bp_reg=3 (sp), type=2 (call), signal=1
    const entry = decode(&raw).?;
    try std.testing.expectEqual(@as(i16, 8), entry.sp_offset);
    try std.testing.expectEqual(@as(i16, -8), entry.bp_offset);
    try std.testing.expectEqual(Reg.bp, entry.sp_reg);
    try std.testing.expectEqual(Reg.sp, entry.bp_reg);
    try std.testing.expectEqual(Type.call, entry.type);
    try std.testing.expect(entry.signal);
}

const Mem = struct {
    slots: []const struct { at: u64, value: u64 },
    fn read(self: @This(), address: u64, dest: []u8) !usize {
        for (self.slots) |slot| if (address == slot.at and dest.len >= 8) {
            std.mem.writeInt(u64, dest[0..8], slot.value, .little);
            return 8;
        };
        return error.OrcMemory;
    }
};

test "orc call step reads the return address above the stack pointer" {
    const entry = Entry{ .sp_offset = 8, .bp_offset = 0, .sp_reg = .sp, .bp_reg = .prev_sp, .type = .call, .signal = false };
    const mem = Mem{ .slots = &.{ .{ .at = 0x2000, .value = 0x3000 }, .{ .at = 0x2008, .value = 0x1ff0 } } };
    const next = try step(entry, .{ .ip = 0x1000, .sp = 0x2000, .bp = 0x1f00 }, null, mem);
    try std.testing.expectEqual(@as(u64, 0x3000), next.ip);
    try std.testing.expectEqual(@as(u64, 0x2008), next.sp);
    try std.testing.expectEqual(@as(u64, 0x1ff0), next.bp);
    try std.testing.expectError(error.OrcEndOfStack, step(.{ .sp_offset = 0, .bp_offset = 0, .sp_reg = .sp, .bp_reg = .undefined, .type = .end_of_stack, .signal = false }, .{ .ip = 1, .sp = 2, .bp = 3 }, null, mem));
    try std.testing.expectError(error.OrcStackDirection, step(.{ .sp_offset = 0, .bp_offset = 0, .sp_reg = .sp, .bp_reg = .undefined, .type = .call, .signal = false }, .{ .ip = 1, .sp = 0x2000, .bp = 3 }, null, mem));
}

test "orc register step uses the image's pt_regs offsets" {
    // ip at byte 16, sp at byte 32, of a 40-byte block. Not a baked x86 layout:
    // the caller supplies the offsets the image's types reported.
    // 0x40 bytes above the current SP, so the block sits at 0x2040.
    const entry = Entry{ .sp_offset = 0x40, .bp_offset = 0, .sp_reg = .sp, .bp_reg = .undefined, .type = .regs, .signal = false };
    const mem = Mem{ .slots = &.{ .{ .at = 0x2050, .value = 0xabc0 }, .{ .at = 0x2060, .value = 0x5000 } } };
    const next = try step(entry, .{ .ip = 0x1000, .sp = 0x2000, .bp = 0x1500 }, .{ .size = 40, .ip = 16, .sp = 32 }, mem);
    try std.testing.expectEqual(@as(u64, 0xabc0), next.ip);
    try std.testing.expectEqual(@as(u64, 0x5000), next.sp);
    try std.testing.expectError(error.OrcPtRegsUnavailable, step(entry, .{ .ip = 0x1000, .sp = 0x2000, .bp = 0x1500 }, null, mem));
}

pub const Loong = struct {
    sp_offset: i16,
    fp_offset: i16,
    ra_offset: i16,
    sp_reg: u4,
    fp_reg: u4,
    ra_reg: u4,
    type: u3,
    signal: bool,
};

/// LoongArch packs three s16 offsets and a 16-bit register word.
/// sp_reg, fp_reg and ra_reg are 4 bits; type is 3; signal is 1.
pub fn decodeLoong(bytes: []const u8) ?Loong {
    if (bytes.len < 8) return null;
    const bits = std.mem.readInt(u16, bytes[6..8], .little);
    return .{
        .sp_offset = std.mem.readInt(i16, bytes[0..2], .little),
        .fp_offset = std.mem.readInt(i16, bytes[2..4], .little),
        .ra_offset = std.mem.readInt(i16, bytes[4..6], .little),
        .sp_reg = @truncate(bits),
        .fp_reg = @truncate(bits >> 4),
        .ra_reg = @truncate(bits >> 8),
        .type = @truncate(bits >> 12),
        .signal = (bits >> 15) & 1 != 0,
    };
}

/// One LoongArch call step. Register frames are refused so the walk stops
/// instead of inventing a caller. `ORC_REG_SP` is 2, `ORC_REG_FP` is 3,
/// `ORC_REG_PREV_SP` is 1, `ORC_REG_UNDEFINED` is 0. A call return is the
/// word at `sp + ra_offset`, or `ra`. The stack walk subtracts one
/// instruction from that address. A zero stack offset is the entry before
/// the frame is allocated; only a move to a lower address is refused.
pub fn stepLoong(entry: Loong, regs: Regs, memory: anytype) !Frame {
    if (entry.type == 0 or entry.type == 1) return error.OrcEndOfStack;
    if (entry.type != 2) return error.OrcUndefined;
    var sp = regs.sp;
    switch (entry.sp_reg) {
        2 => sp = try addOffset(regs.sp, entry.sp_offset),
        3 => sp = regs.bp,
        else => return error.OrcRegisterUnavailable,
    }
    if (sp < regs.sp) return error.OrcStackDirection;
    var fp = regs.bp;
    switch (entry.fp_reg) {
        0 => {},
        1 => fp = try readU64(memory, try addOffset(sp, entry.fp_offset)),
        else => return error.OrcRegisterUnavailable,
    }
    var ra = regs.ra;
    const raw: u64 = switch (entry.ra_reg) {
        1 => try readU64(memory, try addOffset(sp, entry.ra_offset)),
        0 => blk: {
            if (ra == 0 or ra == regs.ip) return error.OrcEndOfStack;
            const taken = ra;
            ra = 0;
            break :blk taken;
        },
        else => return error.OrcRegisterUnavailable,
    };
    if (raw < 4) return error.OrcAddress;
    return .{ .ip = raw, .sp = sp, .bp = fp, .ra = ra };
}

test "a module orc address round-trips through a zero base" {
    const ip: u64 = 0xffffffffc0400061;
    const low = encodeIp(0, 3, ip) orelse return error.OrcAddress;
    const ips = [_]i32{ 0, 0, 0, low };
    try std.testing.expectEqual(@as(?usize, 3), find(0, &ips, ip));
    const at = @as(u64, 3 * 4) +% @as(u64, @bitCast(@as(i64, low)));
    try std.testing.expectEqual(ip, at);
    const high: u64 = 0xffff80000220c000;
    try std.testing.expect(encodeIp(0, 0, high) == null);
    const based = encodeIp(high, 1, high + 0x40) orelse return error.OrcAddress;
    const table = [_]i32{ 0, based };
    try std.testing.expectEqual(@as(?usize, 1), find(high, &table, high + 0x40));
    try std.testing.expectEqual(@as(?usize, 0), find(high, &table, high + 0x18));
}

test "loongarch orc call reads the return word as the caller pc" {
    var stack: [64]u8 = @splat(0);
    std.mem.writeInt(u64, stack[32..][0..8], 0xffffffff80001234, .little);
    std.mem.writeInt(u64, stack[24..][0..8], 0xffffffff80002000, .little);
    const entry = decodeLoong(&[_]u8{
        32, 0, // sp_offset +32
        0xf8, 0xff, // fp_offset -8
        0, 0, // ra_offset 0, word at the new sp
        0x12, 0x21, // sp_reg=2, fp_reg=1, ra_reg=1, type=2
    }) orelse return error.OrcUndefined;
    const mem = struct {
        bytes: []const u8,
        fn read(self: @This(), address: u64, dest: []u8) !usize {
            if (address > self.bytes.len or dest.len > self.bytes.len - address) return error.OrcMemory;
            @memcpy(dest, self.bytes[@intCast(address)..][0..dest.len]);
            return dest.len;
        }
    }{ .bytes = &stack };
    const next = try stepLoong(entry, .{ .ip = 0x1000, .sp = 0, .bp = 0, .ra = 0x55 }, mem);
    try std.testing.expectEqual(@as(u64, 0xffffffff80001234), next.ip);
    try std.testing.expectEqual(@as(u64, 32), next.sp);
    try std.testing.expectEqual(@as(u64, 0xffffffff80002000), next.bp);
}

test "loongarch orc entry with a zero stack offset returns through ra" {
    const entry = Loong{ .sp_offset = 0, .fp_offset = 0, .ra_offset = 0, .sp_reg = 2, .fp_reg = 0, .ra_reg = 0, .type = 2, .signal = false };
    const mem = struct {
        fn read(_: @This(), _: u64, _: []u8) !usize {
            return error.OrcMemory;
        }
    }{};
    const next = try stepLoong(entry, .{ .ip = 0x1000, .sp = 0x2000, .bp = 0x1500, .ra = 0xffffffff80001234 }, mem);
    try std.testing.expectEqual(@as(u64, 0xffffffff80001234), next.ip);
    try std.testing.expectEqual(@as(u64, 0x2000), next.sp);
    try std.testing.expectEqual(@as(u64, 0), next.ra);
    const down = Loong{ .sp_offset = -8, .fp_offset = 0, .ra_offset = 0, .sp_reg = 2, .fp_reg = 0, .ra_reg = 0, .type = 2, .signal = false };
    try std.testing.expectError(error.OrcStackDirection, stepLoong(down, .{ .ip = 0x1000, .sp = 0x2000, .bp = 0x1500, .ra = 0xffffffff80001234 }, mem));
}
