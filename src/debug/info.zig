//! libdw is a byte decoder. All addresses here are link addresses; the caller
//! supplies stopped registers, memory reads, and one explicit module load bias.
const std = @import("std");
const c = @import("../c.zig").api;
const elf = @import("../binary/elf.zig");
const loc = @import("location.zig");
const eval = @import("../model/evaluate.zig");
pub const Site = struct { path: []const u8, original_path: ?[]const u8 = null, line: u32, column: u32, address: u64, is_statement: bool, prologue_end: bool, discriminator: u32 };
pub const Local = struct { name: []const u8, parameter: bool, value: eval.Value, diagnostic: ?[]const u8 = null };
/// `outermost`: CFI marks the return address undefined (DW_CFA_undefined),
/// the DWARF end-of-stack convention (glibc _start and clone3).
pub const Unwind = struct { cfa: u64, caller: loc.RegisterSet, method: enum { eh_frame, debug_frame }, outermost: bool = false };
const Unit = struct { die: c.Dwarf_Die, kind: u8, split: ?c.Dwarf_Die = null, split_error: ?anyerror = null };
pub const Inline = struct { name: []const u8, depth: usize, die_offset: u64, call_path: ?[]const u8 = null, call_line: ?u32 = null, call_column: ?u32 = null, decl_path: ?[]const u8 = null, decl_line: ?u32 = null };
const unknown = eval.Type{ .name = "unknown", .kind = .unknown, .size = 0 };
fn name(die: *c.Dwarf_Die) []const u8 {
    var attr: c.Dwarf_Attribute = undefined;
    const found = c.dwarf_attr_integrate(die, std.dwarf.AT.name, &attr);
    if (found != null) {
        const str = c.dwarf_formstring(found);
        if (str != null) return std.mem.span(str);
    }
    return "";
}
fn unsigned(die: *c.Dwarf_Die, code: c_uint) ?u64 {
    var attr: c.Dwarf_Attribute = undefined;
    const found = c.dwarf_attr_integrate(die, code, &attr);
    var value: c.Dwarf_Word = 0;
    if (found == null or c.dwarf_formudata(found, &value) != 0) return null;
    return value;
}
fn reference(die: *c.Dwarf_Die, code: c_uint) ?c.Dwarf_Die {
    var attr: c.Dwarf_Attribute = undefined;
    const found = c.dwarf_attr_integrate(die, code, &attr);
    var out: c.Dwarf_Die = undefined;
    if (found == null or c.dwarf_formref_die(found, &out) == null) return null;
    return out;
}
// libdw on this workstation does not descend every namespace from a CU.
// Retry namespaces explicitly, retaining outer scopes and bounding our walk.
fn scopesIn(a: std.mem.Allocator, die: *c.Dwarf_Die, pc: u64, budget: *usize, depth: usize) anyerror![]c.Dwarf_Die {
    if (depth > 64) return error.ScopeLimit;
    var raw: [*c]c.Dwarf_Die = null;
    const count = c.dwarf_getscopes(die, pc, &raw);
    defer c.free(raw);
    if (count < 0) return error.MalformedDebugInfo;
    if (count > 4096) return error.ScopeLimit;
    if (count > 0) return a.dupe(c.Dwarf_Die, raw[0..@intCast(count)]);
    var child: c.Dwarf_Die = undefined;
    if (c.dwarf_child(die, &child) != 0) return &.{};
    while (true) {
        if (budget.* == 0) return error.ScopeLimit;
        budget.* -= 1;
        if (c.dwarf_tag(&child) == std.dwarf.TAG.namespace) {
            const nested = try scopesIn(a, &child, pc, budget, depth + 1);
            defer a.free(nested);
            if (nested.len > 0) {
                const result = try a.alloc(c.Dwarf_Die, nested.len + 1);
                @memcpy(result[0..nested.len], nested);
                result[nested.len] = die.*;
                return result;
            }
        }
        const next = c.dwarf_siblingof(&child, &child);
        if (next > 0) break;
        if (next < 0) return error.MalformedDebugInfo;
    }
    return &.{};
}
fn scopesAt(a: std.mem.Allocator, die: *c.Dwarf_Die, pc: u64) ![]c.Dwarf_Die {
    var budget: usize = 65536;
    return scopesIn(a, die, pc, &budget, 0);
}
// getscopes follows an inline's abstract lexical origin; the concrete DIE
// parent chain retains the physical caller and surrounding inline instances.
fn concreteScopesAt(a: std.mem.Allocator, die: *c.Dwarf_Die, pc: u64) ![]c.Dwarf_Die {
    const lexical = try scopesAt(a, die, pc);
    if (lexical.len == 0) return lexical;
    for (lexical) |*scope| if (c.dwarf_tag(scope) == std.dwarf.TAG.inlined_subroutine) {
        defer a.free(lexical);
        var raw: [*c]c.Dwarf_Die = null;
        const count = c.dwarf_getscopes_die(&lexical[0], &raw);
        defer c.free(raw);
        if (count <= 0 or count > 4096) return error.InlineScopeUnavailable;
        return a.dupe(c.Dwarf_Die, raw[0..@intCast(count)]);
    };
    return lexical;
}
fn language(die: *c.Dwarf_Die) eval.Language {
    var cu: c.Dwarf_Die = undefined;
    if (c.dwarf_diecu(die, &cu, null, null) == null) return .unknown;
    switch (c.dwarf_srclang(&cu)) {
        std.dwarf.LANG.Rust => return .rust,
        std.dwarf.LANG.Zig => return .zig,
        else => {},
    }
    // Zig 0.16 LLVM emits C99; producer evidence disambiguates it from C.
    var attr: c.Dwarf_Attribute = undefined;
    if (c.dwarf_attr(&cu, std.dwarf.AT.producer, &attr) != null) {
        const producer = c.dwarf_formstring(&attr);
        if (producer != null and std.mem.startsWith(u8, std.mem.span(producer), "zig ")) return .zig;
    }
    return .unknown;
}
pub const Image = struct {
    architecture: @import("../target/arch.zig").Arch,
    object: *c.Elf,
    debug_object: *c.Elf,
    dwarf: ?*c.Dwarf,
    eh: ?*c.Dwarf_CFI,
    debug_cfi: ?*c.Dwarf_CFI,
    arena: std.heap.ArenaAllocator,
    units: std.ArrayList(Unit) = .empty,
    units_ready: bool = false,
    allow_split: bool = false,
    split_count: usize = 0,
    split_bytes: usize = 0,
    units_error: ?anyerror = null,
    types: std.AutoHashMapUnmanaged(u64, *eval.Type) = .empty,
    pending_aliases: std.AutoHashMapUnmanaged(*const eval.Type, Alias) = .empty,
    address_table: []const u8,
    const Alias = struct { target: *const eval.Type, name: []const u8 };
    pub fn init(binary: elf.Image, bytes: []u8) !Image {
        return initWithAllocator(binary, bytes, std.heap.page_allocator);
    }
    pub fn initWithAllocator(binary: elf.Image, bytes: []u8, allocator: std.mem.Allocator) !Image {
        return initWithCompanion(binary, bytes, null, allocator);
    }
    pub fn initWithCompanion(binary: elf.Image, bytes: []u8, companion: ?*const @import("../binary/debug_files.zig").File, allocator: std.mem.Allocator) !Image {
        if (c.elf_version(c.EV_CURRENT) == c.EV_NONE) return error.ElfLibraryUnavailable;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const object_bytes = try libelfBytes(binary, bytes, arena.allocator());
        const object = c.elf_memory(@ptrCast(object_bytes.ptr), object_bytes.len) orelse return error.InvalidDebugImage;
        errdefer _ = c.elf_end(object);
        const debug_object = if (companion) |file| blk: {
            const debug_bytes = try libelfBytes(file.image, file.bytes, arena.allocator());
            break :blk c.elf_memory(@ptrCast(debug_bytes.ptr), debug_bytes.len) orelse return error.InvalidDebugImage;
        } else object;
        const debug_binary = if (companion) |file| file.image else binary;
        const dwarf = c.dwarf_begin_elf(debug_object, c.DWARF_C_READ, null);
        return .{ .architecture = @enumFromInt(@intFromEnum(binary.header.machine)), .object = object, .debug_object = debug_object, .dwarf = dwarf, .eh = c.dwarf_getcfi_elf(object), .debug_cfi = if (dwarf) |d| c.dwarf_getcfi(d) else null, .arena = arena, .address_table = if (dwarf != null) addressTable(debug_binary, debug_object) else &.{} };
    }
    fn addressTable(binary: elf.Image, object: *c.Elf) []const u8 {
        // dwarf_begin_elf has decompressed recognized sections in this private
        // handle. Indexed locations must use those bytes, not the compressed
        // original snapshot. Section indices survive GNU section renaming.
        const section = binary.sectionByName(".debug_addr") orelse binary.sectionByName(".zdebug_addr") orelse return &.{};
        const scn = c.elf_getscn(object, section.index) orelse return &.{};
        const data = c.elf_getdata(scn, null) orelse return &.{};
        const bytes: [*]const u8 = @ptrCast(data.*.d_buf orelse return &.{});
        return bytes[0..data.*.d_size];
    }
    fn libelfBytes(binary: elf.Image, bytes: []u8, a: std.mem.Allocator) ![]u8 {
        // elf_memory borrows its buffer as writable private storage. Even
        // DWARF_C_READ decompresses sections by rewriting their ELF headers.
        // Keep those writes off read-only mappings and shared capture evidence.
        // Plain images need no copy: our read-only libdw calls do not edit them.
        for (0..binary.header.section_count) |i| {
            const section = try binary.section(@intCast(i));
            if (section.flags & elf.shf.compressed != 0 or std.mem.startsWith(u8, section.name, ".zdebug"))
                return a.dupe(u8, bytes);
        }
        return bytes;
    }
    pub fn deinit(self: *Image) void {
        if (self.eh) |cache| _ = c.dwarf_cfi_end(cache);
        if (self.dwarf) |d| _ = c.dwarf_end(d);
        if (self.debug_object != self.object) _ = c.elf_end(self.debug_object);
        _ = c.elf_end(self.object);
        self.arena.deinit();
    }
    // Jetty ships elfutils 0.170. Its public iterator supports the demo's DWARF 4;
    // reject newer unit versions explicitly instead of guessing their headers.
    fn loadLegacyUnits(self: *Image, d: *c.Dwarf) !void {
        var offset: c.Dwarf_Off = 0;
        while (true) {
            var next: c.Dwarf_Off = 0;
            var header: usize = 0;
            var version: c.Dwarf_Half = 0;
            const rc = c.dwarf_next_unit(d, offset, &next, &header, &version, null, null, null, null, null);
            if (rc == 1) break;
            if (rc != 0 or next <= offset or header >= next - offset) return error.MalformedDebugInfo;
            if (version > 4) return error.DwarfVersionUnsupportedByLibdw;
            if (version == 4) {
                var die: c.Dwarf_Die = undefined;
                if (c.dwarf_offdie(d, offset + header, &die) == null) return error.MalformedDebugInfo;
                if (self.units.items.len == 1_000_000) return error.DebugInfoLimit;
                try self.units.append(self.arena.allocator(), .{ .die = die, .kind = std.dwarf.UT.compile });
            }
            offset = next;
        }
    }
    fn loadUnits(self: *Image) !void {
        if (self.units_error) |err| return err;
        if (self.units_ready) return;
        errdefer |err| self.units_error = err;
        const d = self.dwarf orelse return error.NoDebugInfo;
        if (!@hasDecl(c, "dwarf_get_units")) {
            try self.loadLegacyUnits(d);
            self.units_ready = true;
            return;
        }
        var previous: ?*c.Dwarf_CU = null;
        while (true) {
            var next: ?*c.Dwarf_CU = null;
            var die: c.Dwarf_Die = undefined;
            var version: c.Dwarf_Half = 0;
            var kind: u8 = 0;
            const result = c.dwarf_get_units(d, previous, &next, &version, &kind, &die, null);
            if (result == 1) break;
            if (result < 0 or next == previous) return error.MalformedDebugInfo;
            previous = next;
            if (version < 4 or version > 5) continue;
            if (kind != std.dwarf.UT.compile and kind != std.dwarf.UT.skeleton) continue;
            if (self.units.items.len == 1_000_000) return error.DebugInfoLimit;
            try self.units.append(self.arena.allocator(), .{ .die = die, .kind = kind });
        }
        self.units_ready = true;
    }
    fn scopeDie(self: *Image, unit: *Unit) !*c.Dwarf_Die {
        if (unit.kind != std.dwarf.UT.skeleton) return &unit.die;
        if (unit.split_error) |err| return err;
        if (unit.split) |*die| return die;
        errdefer |err| unit.split_error = err;
        if (!self.allow_split) return error.SplitDwarfDisabled;
        if (!@hasDecl(c, "dwarf_cu_info")) return error.SplitDwarfUnsupportedByLibdw;
        if (self.split_count >= 64) return error.SplitDwarfFileLimit;
        var attr: c.Dwarf_Attribute = undefined;
        const found = c.dwarf_attr(&unit.die, std.dwarf.AT.dwo_name, &attr) orelse c.dwarf_attr(&unit.die, std.dwarf.AT.GNU_dwo_name, &attr) orelse return error.SplitDwarfNameMissing;
        const raw = c.dwarf_formstring(found) orelse return error.SplitDwarfNameMissing;
        const name_ = std.mem.span(raw);
        if (name_.len == 0 or name_.len > 4096) return error.SplitDwarfNameInvalid;
        var arena = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const path = if (name_[0] == '/') try a.dupeZ(u8, name_) else blk: {
            const dir_attr = c.dwarf_attr(&unit.die, std.dwarf.AT.comp_dir, &attr) orelse return error.SplitDwarfNameMissing;
            const dir = std.mem.span(c.dwarf_formstring(dir_attr) orelse return error.SplitDwarfNameMissing);
            if (dir.len == 0 or dir.len > 4096 or dir[0] != '/') return error.SplitDwarfRequiresAbsoluteBuildPath;
            break :blk try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name_ }, 0);
        };
        // libdw's documented split lookup links skeleton/address tables by DWO ID.
        // Preflight its only possible path for an elf_memory-backed skeleton.
        const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) return error.SplitDwarfFileUnavailable;
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size <= 0) return error.SplitDwarfNotRegular;
        const size: usize = @intCast(stat.st_size);
        if (size > 64 * 1024 * 1024 or size > 256 * 1024 * 1024 - self.split_bytes) return error.SplitDwarfByteLimit;
        self.split_count += 1;
        self.split_bytes += size;
        var split: c.Dwarf_Die = undefined;
        if (c.dwarf_cu_info(unit.die.cu, null, null, null, &split, null, null, null) != 0 or c.dwarf_tag(&split) != std.dwarf.TAG.compile_unit) return error.SplitDwarfMissingOrMismatched;
        unit.split = split;
        return &unit.split.?;
    }
    pub fn inlineAt(self: *Image, a: std.mem.Allocator, pc: u64) ![]Inline {
        const unit = try self.unitAt(pc);
        const scope_die = try self.scopeDie(unit);
        const scopes = try concreteScopesAt(a, scope_die, pc);
        defer a.free(scopes);
        var result: std.ArrayList(Inline) = .empty;
        for (scopes) |*scope| {
            if (c.dwarf_tag(scope) != std.dwarf.TAG.inlined_subroutine) continue;
            if (result.items.len >= 64) return error.InlineDepthLimit;
            var value = Inline{ .name = try a.dupe(u8, name(scope)), .depth = result.items.len, .die_offset = c.dwarf_dieoffset(scope) };
            if (unsigned(scope, std.dwarf.AT.call_line)) |n| value.call_line = std.math.cast(u32, n);
            if (unsigned(scope, std.dwarf.AT.call_column)) |n| value.call_column = std.math.cast(u32, n);
            var cu: c.Dwarf_Die = undefined;
            var files: ?*c.Dwarf_Files = null;
            var count: usize = 0;
            if (c.dwarf_diecu(scope, &cu, null, null) != null and c.dwarf_getsrcfiles(&cu, &files, &count) == 0) {
                if (unsigned(scope, std.dwarf.AT.call_file)) |n| if (n < count) {
                    if (c.dwarf_filesrc(files, @intCast(n), null, null)) |file| value.call_path = try a.dupe(u8, std.mem.span(file));
                };
            }
            if (c.dwarf_decl_file(scope)) |file| value.decl_path = try a.dupe(u8, std.mem.span(file));
            var line: c_int = 0;
            if (c.dwarf_decl_line(scope, &line) == 0 and line > 0) value.decl_line = @intCast(line);
            try result.append(a, value);
        }
        return result.toOwnedSlice(a);
    }
    fn unitAt(self: *Image, pc: u64) !*Unit {
        try self.loadUnits();
        for (self.units.items) |*unit| if (c.dwarf_haspc(&unit.die, pc) == 1) return unit;
        return error.NoDebugInfoAtAddress;
    }
    fn site(a: std.mem.Allocator, die: *c.Dwarf_Die, row: *c.Dwarf_Line) !Site {
        var line: c_int = 0;
        var column: c_int = 0;
        var address: c.Dwarf_Addr = 0;
        var end = false;
        var statement = false;
        var prologue = false;
        var discriminator: c_uint = 0;
        if (c.dwarf_lineno(row, &line) != 0 or c.dwarf_lineaddr(row, &address) != 0 or line <= 0) return error.NoSourceLocation;
        _ = c.dwarf_linecol(row, &column);
        _ = c.dwarf_lineendsequence(row, &end);
        if (end) return error.NoSourceLocation;
        _ = c.dwarf_linebeginstatement(row, &statement);
        _ = c.dwarf_lineprologueend(row, &prologue);
        _ = c.dwarf_linediscriminator(row, &discriminator);
        const filename = c.dwarf_linesrc(row, null, null);
        if (filename == null) return error.NoSourceLocation;
        const path = std.mem.span(filename);
        var comp_dir: []const u8 = "";
        var attr: c.Dwarf_Attribute = undefined;
        if (c.dwarf_attr(die, std.dwarf.AT.comp_dir, &attr) != null) {
            const str = c.dwarf_formstring(&attr);
            if (str != null) comp_dir = std.mem.span(str);
        }
        const absolute = if (std.fs.path.isAbsolute(path)) try a.dupe(u8, path) else try std.fs.path.resolve(a, &.{ comp_dir, path });
        return .{ .path = absolute, .line = @intCast(line), .column = @intCast(@max(0, column)), .address = address, .is_statement = statement, .prologue_end = prologue, .discriminator = discriminator };
    }
    pub fn siteAt(self: *Image, a: std.mem.Allocator, pc: u64) !Site {
        const unit = try self.unitAt(pc);
        const row = c.dwarf_getsrc_die(&unit.die, pc) orelse return error.NoSourceLocation;
        return site(a, &unit.die, row);
    }
    pub const FunctionRange = struct { name: []const u8, address: u64, end: u64, range_index: usize, range_count: usize };
    /// Compiler-declared contiguous fragment containing pc. Never treat a CFI
    /// row, nearest symbol, prologue pattern or inline scope as a function bound.
    pub fn functionRangeAt(self: *Image, a: std.mem.Allocator, pc: u64) !FunctionRange {
        const unit = try self.unitAt(pc);
        const scopes = try concreteScopesAt(a, try self.scopeDie(unit), pc);
        defer a.free(scopes);
        if (scopes.len == 0) return error.NoFunctionRange;
        for (scopes) |*die| {
            if (c.dwarf_tag(die) != std.dwarf.TAG.subprogram) continue;
            var offset: isize = 0;
            var base: c.Dwarf_Addr = 0;
            var total: usize = 0;
            var found: ?FunctionRange = null;
            while (true) {
                var first: c.Dwarf_Addr = 0;
                var end: c.Dwarf_Addr = 0;
                const next = c.dwarf_ranges(die, offset, &base, &first, &end);
                if (next == 0) break;
                if (next < 0 or next == offset or end < first) return error.MalformedFunctionRanges;
                if (total == 1024) return error.FunctionRangeLimit;
                if (pc >= first and pc < end) {
                    if (found != null) return error.AmbiguousFunctionRanges;
                    found = .{ .name = "", .address = first, .end = end, .range_index = total, .range_count = 0 };
                }
                total += 1;
                offset = next;
            }
            var result = found orelse return error.NoFunctionRange;
            result.name = try a.dupe(u8, if (name(die).len > 0) name(die) else "[DWARF subprogram]");
            result.range_count = total;
            return result;
        }
        return error.NoFunctionRange;
    }
    pub fn rowsForLine(self: *Image, a: std.mem.Allocator, path: []const u8, line: u32) ![]Site {
        try self.loadUnits();
        var rows: std.ArrayList(Site) = .empty;
        for (self.units.items) |*unit| {
            var lines: ?*c.Dwarf_Lines = null;
            var count: usize = 0;
            if (c.dwarf_getsrclines(&unit.die, &lines, &count) != 0) continue;
            if (count > 10_000_000) return error.DebugInfoLimit;
            for (0..count) |i| {
                const row = c.dwarf_onesrcline(lines, i) orelse continue;
                var row_line: c_int = 0;
                if (c.dwarf_lineno(row, &row_line) != 0 or row_line < 0 or row_line != line) continue;
                const value = site(a, &unit.die, row) catch continue;
                const matches = std.mem.eql(u8, path, value.path) or
                    (!std.fs.path.isAbsolute(path) and value.path.len > path.len and std.mem.endsWith(u8, value.path, path) and value.path[value.path.len - path.len - 1] == '/');
                if (!matches) continue;
                var duplicate = false;
                for (rows.items) |*old| if (old.address == value.address) {
                    if (value.is_statement) old.* = value;
                    duplicate = true;
                    break;
                };
                if (!duplicate) try rows.append(a, value);
            }
        }
        var any_statement = false;
        for (rows.items) |row| if (row.is_statement) {
            any_statement = true;
        };
        if (any_statement) {
            var n: usize = 0;
            for (rows.items) |row| if (row.is_statement) {
                rows.items[n] = row;
                n += 1;
            };
            rows.items.len = n;
        }
        return rows.toOwnedSlice(a);
    }
    fn expression(self: *Image, a: std.mem.Allocator, attr: ?*c.Dwarf_Attribute, ops: [*c]c.Dwarf_Op, count: usize, ctx: loc.Context) !loc.Place {
        if (count > 4096) return error.ExpressionTooLarge;
        const normalized = try a.alloc(loc.Op, count);
        for (normalized, 0..) |*out, i| {
            out.* = .{ .atom = ops[i].atom, .number = ops[i].number, .number2 = ops[i].number2, .offset = ops[i].offset };
            if (out.atom == std.dwarf.OP.implicit_value) {
                const attribute = attr orelse return error.UnsupportedLocation;
                var block: c.Dwarf_Block = undefined;
                if (c.dwarf_getlocation_implicit_value(attribute, &ops[i], &block) != 0) return error.MalformedLocation;
                if (block.length > 4096) return error.CompositeTooLarge;
                out.data = try a.dupe(u8, block.data[0..@intCast(block.length)]);
            }
            if (out.atom == std.dwarf.OP.addrx or out.atom == std.dwarf.OP.constx or out.atom == std.dwarf.OP.GNU_addr_index or out.atom == std.dwarf.OP.GNU_const_index) {
                const attribute = attr orelse return error.UnsupportedLocation;
                var unit: c.Dwarf_Die = undefined;
                if (c.dwarf_cu_die(attribute.cu, &unit, null, null, null, null, null, null) == null) return error.MalformedDebugInfo;
                const base = unsigned(&unit, std.dwarf.AT.addr_base) orelse return error.AddressTableUnavailable;
                const index = std.math.mul(u64, out.number, self.architecture.addressBytes()) catch return error.MalformedDebugInfo;
                const offset = std.math.add(u64, base, index) catch return error.MalformedDebugInfo;
                if (offset > self.address_table.len or self.address_table.len - offset < self.architecture.addressBytes()) return error.MalformedDebugInfo;
                out.number = loc.lowBits(self.address_table[@intCast(offset)..][0..self.architecture.addressBytes()], self.architecture.endian());
                out.atom = if (out.atom == std.dwarf.OP.addrx or out.atom == std.dwarf.OP.GNU_addr_index) std.dwarf.OP.addr else std.dwarf.OP.constu;
            }
        }
        var context = ctx;
        context.endian = self.architecture.endian();
        context.address_bytes = self.architecture.addressBytes();
        return loc.composite(a, context, normalized);
    }
    pub fn unwind(self: *Image, a: std.mem.Allocator, pc: u64, ctx: loc.Context) !Unwind {
        var frame: ?*c.Dwarf_Frame = null;
        var method: @FieldType(Unwind, "method") = .eh_frame;
        if (self.eh == null or c.dwarf_cfi_addrframe(self.eh.?, pc, &frame) != 0) {
            method = .debug_frame;
            if (self.debug_cfi == null or c.dwarf_cfi_addrframe(self.debug_cfi.?, pc, &frame) != 0) return error.NoUnwindInfo;
        }
        defer c.free(frame);
        var signal = false;
        const return_register = c.dwarf_frame_info(frame, null, null, &signal);
        if (signal) return error.SignalFrameUnsupported;
        if (return_register != self.architecture.ra()) return error.UnsupportedReturnRegister;
        var ops: [*c]c.Dwarf_Op = null;
        var count: usize = 0;
        if (c.dwarf_frame_cfa(frame, &ops, &count) != 0 or count == 0) return error.CfaUnavailable;
        const cfa = try loc.scalar(try self.expression(a, null, ops, count, ctx), ctx.address_bytes);
        var context = ctx;
        context.cfa = cfa;
        var caller: loc.RegisterSet = @splat(null);
        var outermost = false;
        for (caller[0..self.architecture.count()], 0..) |*value, index| {
            var buffer: [3]c.Dwarf_Op = undefined;
            ops = null;
            count = 0;
            if (c.dwarf_frame_register(frame, @intCast(index), &buffer, &ops, &count) != 0) continue;
            if (count == 0) {
                if (ops == null) value.* = ctx.registers[index] else if (index == self.architecture.ra()) outermost = true;
                continue;
            }
            const where = self.expression(a, null, ops, count, context) catch continue;
            if (where.kind == .address) {
                var bytes: [8]u8 = undefined;
                const width = self.architecture.addressBytes();
                const n = ctx.read(ctx.user, where.bits, bytes[0..width]) catch continue;
                if (n == width) value.* = loc.lowBits(bytes[0..width], self.architecture.endian());
            } else value.* = loc.scalar(where, ctx.address_bytes) catch continue;
        }
        caller[self.architecture.sp()] = cfa;
        if (self.architecture == .aarch64) caller[self.architecture.pc()] = caller[self.architecture.ra()];
        return .{ .cfa = cfa, .caller = caller, .method = method, .outermost = outermost };
    }
    fn typeOf(self: *Image, die_: c.Dwarf_Die, depth: usize) anyerror!*const eval.Type {
        // Recursive aliases can observe a structure before its fields exist.
        // Finish their copies only after the complete outer graph is built.
        defer if (depth == 0) self.finishAliases();
        errdefer if (depth == 0) {
            // No unfinished type may survive a failed graph construction.
            self.types.clearRetainingCapacity();
            self.pending_aliases.clearRetainingCapacity();
        };
        if (depth > 64) return &unknown;
        var die = die_;
        const key = @intFromPtr(die.addr);
        if (self.types.get(key)) |t| return t;
        const a = self.arena.allocator();
        const t = try a.create(eval.Type);
        t.* = .{ .name = name(&die), .kind = .unknown, .size = unsigned(&die, std.dwarf.AT.byte_size) orelse 0, .language = language(&die) };
        try self.types.put(a, key, t);
        switch (c.dwarf_tag(&die)) {
            std.dwarf.TAG.base_type => {
                t.kind = switch (unsigned(&die, std.dwarf.AT.encoding) orelse 0) {
                    std.dwarf.ATE.signed, std.dwarf.ATE.signed_char => .signed,
                    std.dwarf.ATE.unsigned, std.dwarf.ATE.unsigned_char, std.dwarf.ATE.address => .unsigned,
                    std.dwarf.ATE.boolean => .boolean,
                    std.dwarf.ATE.float => .float,
                    else => .unknown,
                };
            },
            std.dwarf.TAG.enumeration_type => {
                if (reference(&die, std.dwarf.AT.type)) |ref| {
                    const base = try self.typeOf(ref, depth + 1);
                    t.kind = base.kind;
                    if (t.size == 0) t.size = base.size;
                } else t.kind = if ((unsigned(&die, std.dwarf.AT.encoding) orelse std.dwarf.ATE.signed) == std.dwarf.ATE.unsigned) .unsigned else .signed;
                if (t.kind != .unsigned and t.kind != .signed) t.kind = .unknown;
                var names: std.ArrayList(eval.Enumerator) = .empty;
                var child: c.Dwarf_Die = undefined;
                var scanned: usize = 0;
                if (c.dwarf_child(&die, &child) == 0) while (true) : (scanned += 1) {
                    if (scanned == 1024) {
                        t.enumerators_complete = false;
                        break;
                    }
                    if (c.dwarf_tag(&child) == std.dwarf.TAG.enumerator) {
                        var attr: c.Dwarf_Attribute = undefined;
                        var signed: c.Dwarf_Sword = 0;
                        var bits: c.Dwarf_Word = 0;
                        if (c.dwarf_attr(&child, std.dwarf.AT.const_value, &attr) != null) {
                            if (t.kind == .signed and c.dwarf_formsdata(&attr, &signed) == 0) {
                                bits = @bitCast(signed);
                            } else if (c.dwarf_formudata(&attr, &bits) != 0) {
                                t.enumerators_complete = false;
                                break;
                            }
                            try names.append(a, .{ .name = name(&child), .bits = bits });
                        } else t.enumerators_complete = false;
                    }
                    if (c.dwarf_siblingof(&child, &child) != 0) break;
                };
                t.enumerators = try names.toOwnedSlice(a);
            },
            std.dwarf.TAG.typedef, std.dwarf.TAG.const_type, std.dwarf.TAG.volatile_type, std.dwarf.TAG.restrict_type, std.dwarf.TAG.atomic_type => {
                if (reference(&die, std.dwarf.AT.type)) |child| {
                    const target = try self.typeOf(child, depth + 1);
                    t.* = target.*;
                    const alias = name(&die);
                    if (alias.len > 0) t.name = alias;
                    try self.pending_aliases.put(a, t, .{ .target = target, .name = alias });
                }
            },
            std.dwarf.TAG.pointer_type, std.dwarf.TAG.reference_type, std.dwarf.TAG.rvalue_reference_type => {
                t.kind = .pointer;
                if (t.size == 0) t.size = self.architecture.addressBytes();
                t.child = if (reference(&die, std.dwarf.AT.type)) |child| try self.typeOf(child, depth + 1) else &unknown;
                if (t.name.len == 0) t.name = try std.fmt.allocPrint(a, "{s} *", .{t.child.?.name});
            },
            std.dwarf.TAG.structure_type, std.dwarf.TAG.class_type, std.dwarf.TAG.union_type => {
                t.kind = .structure;
                var fields: std.ArrayList(eval.Field) = .empty;
                var child: c.Dwarf_Die = undefined;
                var scanned: usize = 0;
                if (c.dwarf_child(&die, &child) == 0) while (true) : (scanned += 1) {
                    const tag = c.dwarf_tag(&child);
                    if (scanned == 4096 or tag == std.dwarf.TAG.inheritance or tag == std.dwarf.TAG.variant_part) {
                        t.kind = .unknown;
                        break;
                    }
                    if (tag == std.dwarf.TAG.member) {
                        const offset = unsigned(&child, std.dwarf.AT.data_member_location) orelse (if (c.dwarf_tag(&die) == std.dwarf.TAG.union_type) @as(u64, 0) else {
                            t.kind = .unknown;
                            break;
                        });
                        if (c.dwarf_hasattr(&child, std.dwarf.AT.bit_size) != 0) {
                            t.kind = .unknown;
                            break;
                        }
                        const child_type = if (reference(&child, std.dwarf.AT.type)) |ref| try self.typeOf(ref, depth + 1) else &unknown;
                        if (offset > t.size or child_type.size > t.size - offset) {
                            t.kind = .unknown;
                            break;
                        }
                        try fields.append(a, .{ .name = name(&child), .offset = offset, .type = child_type });
                    }
                    if (c.dwarf_siblingof(&child, &child) != 0) break;
                };
                t.fields = try fields.toOwnedSlice(a);
                const js_handle = c.xjs_dwarf_handle(&die);
                if (js_handle != 0) {
                    t.javascript_handle = @intCast(js_handle);
                    t.kind = .structure;
                }
            },
            std.dwarf.TAG.array_type => {
                t.kind = .array;
                t.child = if (reference(&die, std.dwarf.AT.type)) |ref| try self.typeOf(ref, depth + 1) else &unknown;
                var child: c.Dwarf_Die = undefined;
                if (c.dwarf_child(&die, &child) == 0 and c.dwarf_tag(&child) == std.dwarf.TAG.subrange_type) {
                    if ((unsigned(&child, std.dwarf.AT.lower_bound) orelse 0) != 0) {
                        t.kind = .unknown;
                        return t;
                    }
                    t.count = unsigned(&child, std.dwarf.AT.count) orelse if (unsigned(&child, std.dwarf.AT.upper_bound)) |v| std.math.add(u64, v, 1) catch 0 else 0;
                    if (c.dwarf_siblingof(&child, &child) == 0) {
                        t.kind = .unknown;
                        return t;
                    }
                }
                t.size = std.math.mul(u64, t.count, t.child.?.size) catch 0;
            },
            else => {},
        }
        return t;
    }
    fn finishAliases(self: *Image) void {
        var it = self.pending_aliases.iterator();
        while (it.next()) |entry| {
            var target = entry.value_ptr.target;
            var alias_name = entry.value_ptr.name;
            var hops: usize = 0;
            while (self.pending_aliases.get(target)) |alias| : (hops += 1) {
                if (hops == 64) {
                    target = &unknown;
                    break;
                }
                if (alias_name.len == 0) alias_name = alias.name;
                target = alias.target;
            }
            const out = @constCast(entry.key_ptr.*);
            out.* = target.*;
            if (alias_name.len > 0) out.name = alias_name;
        }
        self.pending_aliases.clearRetainingCapacity();
    }
    fn place(self: *Image, a: std.mem.Allocator, die: *c.Dwarf_Die, pc: u64, ctx: loc.Context, before_prologue: bool) !loc.Place {
        var attr: c.Dwarf_Attribute = undefined;
        if (c.dwarf_attr_integrate(die, std.dwarf.AT.const_value, &attr) != null) {
            var signed: c.Dwarf_Sword = 0;
            var value: c.Dwarf_Word = 0;
            if (c.dwarf_formsdata(&attr, &signed) == 0) return .{ .kind = .value, .bits = @bitCast(signed) };
            if (c.dwarf_formudata(&attr, &value) == 0) return .{ .kind = .value, .bits = value };
            return error.UnsupportedConstant;
        }
        if (c.dwarf_attr_integrate(die, std.dwarf.AT.location, &attr) == null) return error.OptimizedOut;
        var ops: [2][*c]c.Dwarf_Op = @splat(null);
        var lengths: [2]usize = @splat(0);
        const count = c.dwarf_getlocation_addr(&attr, pc, &ops, &lengths, 2);
        if (count < 0) return error.MalformedLocation;
        if (count == 0) return error.LocationUnavailable;
        if (count != 1) return error.AmbiguousLocation;
        // Some -O0 producers describe a stack slot for the whole function,
        // including instructions before arguments have been spilled into it.
        if (before_prologue) for (ops[0][0..lengths[0]]) |op| {
            if (op.atom == std.dwarf.OP.fbreg) return error.PrologueNotComplete;
        };
        return self.expression(a, &attr, ops[0], lengths[0], ctx);
    }
    fn scopesForDepth(self: *Image, a: std.mem.Allocator, unit: *Unit, pc: u64, depth: usize) ![]c.Dwarf_Die {
        const die = try self.scopeDie(unit);
        if (depth == 0) return scopesAt(a, die, pc);
        const concrete = try concreteScopesAt(a, die, pc);
        defer a.free(concrete);
        var index: usize = 0;
        for (concrete, 0..) |*scope, i| {
            const tag = c.dwarf_tag(scope);
            if (tag != std.dwarf.TAG.inlined_subroutine and tag != std.dwarf.TAG.subprogram) continue;
            if (index == depth) {
                if (tag == std.dwarf.TAG.subprogram) return a.dupe(c.Dwarf_Die, concrete[i..]);
                // Parameters/locals belong to this concrete inline instance.
                // Its enclosing lexical namespace comes from the abstract origin,
                // not the other inline caller's locals.
                var result: std.ArrayList(c.Dwarf_Die) = .empty;
                try result.append(a, scope.*);
                if (reference(scope, std.dwarf.AT.abstract_origin)) |origin_| {
                    var origin = origin_;
                    var raw: [*c]c.Dwarf_Die = null;
                    const n = c.dwarf_getscopes_die(&origin, &raw);
                    defer c.free(raw);
                    if (n < 0 or n > 4096) return error.InlineScopeUnavailable;
                    if (n > 1) try result.appendSlice(a, raw[1..@intCast(n)]);
                }
                return result.toOwnedSlice(a);
            }
            index += 1;
        }
        return error.InvalidInlineDepth;
    }
    pub fn localsAt(self: *Image, a: std.mem.Allocator, pc: u64, context: loc.Context) ![]Local {
        return self.localsAtDepth(a, pc, context, 0);
    }
    pub fn localsAtDepth(self: *Image, a: std.mem.Allocator, pc: u64, context: loc.Context, depth: usize) ![]Local {
        const unit = try self.unitAt(pc);
        const scopes = try self.scopesForDepth(a, unit, pc, depth);
        defer a.free(scopes);
        if (scopes.len == 0) return error.NoScopeAtAddress;
        const concrete = try concreteScopesAt(a, try self.scopeDie(unit), pc);
        defer a.free(concrete);
        var before_prologue = false;
        for (concrete) |*scope| {
            if (c.dwarf_tag(scope) != std.dwarf.TAG.subprogram) continue;
            var entry: c.Dwarf_Addr = 0;
            if (c.dwarf_lowpc(scope, &entry) != 0) break;
            before_prologue = pc == entry;
            if (c.dwarf_getsrc_die(&unit.die, pc)) |row| {
                var address: c.Dwarf_Addr = 0;
                var prologue_end = false;
                if (c.dwarf_lineaddr(row, &address) == 0) {
                    _ = c.dwarf_lineprologueend(row, &prologue_end);
                    before_prologue = !prologue_end and address == entry;
                }
            }
            break;
        }
        var ctx = context;
        for (concrete) |*scope| {
            var attr: c.Dwarf_Attribute = undefined;
            if (c.dwarf_attr_integrate(scope, std.dwarf.AT.frame_base, &attr) != null) {
                var ops: [*c]c.Dwarf_Op = null;
                var len: usize = 0;
                if (c.dwarf_getlocation_addr(&attr, pc, &ops, &len, 1) == 1) {
                    const base = self.expression(a, &attr, ops, len, ctx) catch break;
                    ctx.frame_base = loc.scalar(base, ctx.address_bytes) catch break;
                }
                break;
            }
        }
        var out: std.ArrayList(Local) = .empty;
        for (scopes) |*scope| {
            var die: c.Dwarf_Die = undefined;
            if (c.dwarf_child(scope, &die) != 0) continue;
            var scanned: usize = 0;
            while (scanned < 1_000_000) : (scanned += 1) {
                const tag = c.dwarf_tag(&die);
                if (tag == std.dwarf.TAG.variable or tag == std.dwarf.TAG.formal_parameter) {
                    const variable_name = name(&die);
                    var duplicate = variable_name.len == 0;
                    for (out.items) |v| if (std.mem.eql(u8, v.name, variable_name)) {
                        duplicate = true;
                        break;
                    };
                    if (!duplicate) {
                        const t = if (reference(&die, std.dwarf.AT.type)) |ref| try self.typeOf(ref, 0) else &unknown;
                        var value = Local{ .name = variable_name, .parameter = tag == std.dwarf.TAG.formal_parameter, .value = .{ .type = t } };
                        if (self.place(a, &die, pc, ctx, before_prologue)) |where| {
                            if (where.kind == .address) value.value.address = where.bits else {
                                value.value.bits = where.bits;
                                value.value.data = if (where.data) |data| try a.dupe(u8, data) else if (t.kind == .array or t.kind == .structure) blk: {
                                    var register_bytes: [8]u8 = undefined;
                                    std.mem.writeInt(u64, &register_bytes, where.bits, ctx.endian);
                                    const width: usize = @intCast(@min(t.size, ctx.address_bytes));
                                    const bytes = try a.dupe(u8, if (ctx.endian == .big) register_bytes[8 - width ..] else register_bytes[0..width]);
                                    break :blk bytes;
                                } else null;
                                value.value.valid = where.valid;
                            }
                        } else |err| {
                            value.diagnostic = @errorName(err);
                            value.value.availability = if (err == error.OptimizedOut) .optimized_out else if (err == error.PrologueNotComplete or err == error.LocationUnavailable or err == error.RegisterUnavailable or err == error.FrameBaseUnavailable or err == error.CfaUnavailable or err == error.EntryValueUnavailable) .unavailable else .unsupported;
                        }
                        try out.append(a, value);
                        if (out.items.len == 4096) return error.LocalLimit;
                    }
                }
                const next = c.dwarf_siblingof(&die, &die);
                if (next == 1) break;
                if (next < 0) return error.MalformedDebugInfo;
            }
        }
        return out.toOwnedSlice(a);
    }
};

test "compressed DWARF preserves read-only ELF images and companions" {
    const a = std.testing.allocator;
    const snapshot = @import("../binary/snapshot.zig");
    const File = @import("../binary/debug_files.zig").File;
    inline for (.{ "gcc", "clang" }) |compiler| {
        inline for (.{ "", ".zlib", ".zstd", ".zlib-gnu" }) |suffix| {
            inline for (.{ false, true }) |separate| {
                const image_path = "tests/fixtures/elf/out/" ++ compiler ++ "-pie" ++ (if (separate) ".stripped" else suffix);
                const fd = c.open(image_path, c.O_RDONLY | c.O_CLOEXEC);
                if (fd < 0) return error.FixtureUnavailable;
                defer _ = c.close(fd);
                const bytes = try snapshot.read(fd, snapshot.per_image_limit, null);
                defer _ = c.munmap(bytes.ptr, bytes.len);
                const binary = try elf.Image.parse(bytes);
                const debug_fd = c.open("tests/fixtures/elf/out/" ++ compiler ++ "-pie.debug" ++ suffix, c.O_RDONLY | c.O_CLOEXEC);
                if (debug_fd < 0) return error.FixtureUnavailable;
                defer _ = c.close(debug_fd);
                const debug_bytes = try snapshot.read(debug_fd, snapshot.per_image_limit, null);
                defer _ = c.munmap(debug_bytes.ptr, debug_bytes.len);
                const debug_binary = try elf.Image.parse(debug_bytes);
                const companion = File{ .path = "fixture.debug", .image = debug_binary, .bytes = debug_bytes, .build_id = debug_binary.buildId() orelse &.{} };
                const before = std.hash.Wyhash.hash(0, bytes);
                const debug_before = std.hash.Wyhash.hash(0, debug_bytes);
                const pc = debug_binary.findSymbol("main").?.value;
                var scratch = std.heap.ArenaAllocator.init(a);
                defer scratch.deinit();
                // Two independent consumers share the same immutable backing bytes.
                var first = try Image.initWithCompanion(binary, bytes, if (separate) &companion else null, a);
                defer first.deinit();
                var second = try Image.initWithCompanion(binary, bytes, if (separate) &companion else null, a);
                defer second.deinit();
                if (comptime std.mem.eql(u8, compiler, "clang")) {
                    const plain_fd = c.open("tests/fixtures/elf/out/clang-pie", c.O_RDONLY | c.O_CLOEXEC);
                    if (plain_fd < 0) return error.FixtureUnavailable;
                    defer _ = c.close(plain_fd);
                    const plain_bytes = try snapshot.read(plain_fd, snapshot.per_image_limit, null);
                    defer _ = c.munmap(plain_bytes.ptr, plain_bytes.len);
                    const plain = try elf.Image.parse(plain_bytes);
                    const expected = try plain.sectionData(plain.sectionByName(".debug_addr") orelse return error.FixtureUnavailable);
                    try std.testing.expect(expected.len > 0);
                    try std.testing.expectEqualSlices(u8, expected, first.address_table);
                    try std.testing.expectEqualSlices(u8, expected, second.address_table);
                }
                const one = try first.siteAt(scratch.allocator(), pc);
                const two = try second.siteAt(scratch.allocator(), pc);
                try std.testing.expect(one.line > 0 and std.mem.endsWith(u8, one.path, "fixture.c"));
                try std.testing.expectEqual(one.line, two.line);
                try std.testing.expectEqualStrings(one.path, two.path);
                try std.testing.expectEqual(before, std.hash.Wyhash.hash(0, bytes));
                try std.testing.expectEqual(debug_before, std.hash.Wyhash.hash(0, debug_bytes));
                if (suffix.len > 0) {
                    var empty: [0]u8 = .{};
                    var limited = std.heap.FixedBufferAllocator.init(&empty);
                    try std.testing.expectError(error.OutOfMemory, Image.initWithCompanion(binary, bytes, if (separate) &companion else null, limited.allocator()));
                }
            }
        }
    }
}
