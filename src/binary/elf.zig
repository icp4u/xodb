//! ELF image reader: a validated, typed view over a borrowed byte slice.
//!
//! Accepts ELF64 little-endian x86-64/AArch64/LoongArch and ELF32 big-endian m68k executables
//! (ET_EXEC) and shared objects/PIEs (ET_DYN). Anything else is rejected by `Image.parse` with a
//! specific error. Live targets and archive consumers also check their supported ISA.
//!
//! Ownership: `Image` never allocates and never copies. It borrows `bytes`,
//! and every slice it returns (names, section data) points into `bytes`. The
//! caller keeps `bytes` alive and unmodified for as long as any of them is used.
//!
//! Address spaces: fields named `addr`, `vaddr`, `entry`, and `Symbol.value`
//! are link-time virtual addresses exactly as stored in the file. Fields named
//! `offset` are file offsets. Neither is a runtime address. A runtime address
//! is `toRuntime(link_address, bias)` with the bias from `Image.loadBias`.
//!
//! Layouts and constants follow the System V gABI (ELF-64 object file format)
//! and the Linux/GNU extensions noted beside each constant. No code was copied.

const std = @import("std");

pub const Error = error{
    /// A header, table, or referenced range extends past the end of the bytes.
    Truncated,
    NotElf,
    UnsupportedClass,
    UnsupportedEncoding,
    UnsupportedVersion,
    UnsupportedMachine,
    UnsupportedType,
    /// ELF header fields are inconsistent: entry strides, extended counts, or the name table index.
    BadHeader,
    /// A section header cannot serve its role: wrong type, stride, size, or link.
    BadSection,
    /// A string offset is outside its table, or the string is not NUL-terminated.
    BadString,
    /// An index passed by the caller is outside the table.
    OutOfRange,
    /// The section occupies no file bytes (SHT_NOBITS).
    NoFileData,
    /// The image has no PT_LOAD segment, so it has no load bias.
    NoLoadSegment,
    /// The mapping passed to `loadBias` cannot be the image's first PT_LOAD.
    BadMapping,
};

const ehdr_size = 64;
const phdr_size = 56;
const shdr_size = 64;
const sym_size = 24;
const shn_undef = 0;
const shn_loreserve = 0xff00;
const shn_abs = 0xfff1;
const shn_common = 0xfff2;
const shn_xindex = 0xffff;
const pn_xnum = 0xffff;

pub const Type = enum { executable, shared };
pub const Machine = enum(u16) { m68k = 4, x86_64 = 62, aarch64 = 183, riscv = 243, loongarch = 258, _ };
pub const SegmentType = enum(u32) { null = 0, load = 1, dynamic = 2, interp = 3, note = 4, shlib = 5, phdr = 6, tls = 7, gnu_eh_frame = 0x6474e550, gnu_stack = 0x6474e551, gnu_relro = 0x6474e552, gnu_property = 0x6474e553, _ };
pub const SectionType = enum(u32) { null = 0, progbits = 1, symtab = 2, strtab = 3, rela = 4, hash = 5, dynamic = 6, note = 7, nobits = 8, rel = 9, shlib = 10, dynsym = 11, init_array = 14, fini_array = 15, preinit_array = 16, group = 17, symtab_shndx = 18, gnu_hash = 0x6ffffff6, gnu_verdef = 0x6ffffffd, gnu_verneed = 0x6ffffffe, gnu_versym = 0x6fffffff, _ };
/// Bits of `Segment.flags`.
pub const pf = struct {
    pub const x = 1;
    pub const w = 2;
    pub const r = 4;
};
/// Bits of `Section.flags`.
pub const shf = struct {
    pub const write = 0x1;
    pub const alloc = 0x2;
    pub const execinstr = 0x4;
    pub const tls = 0x400;
    /// Contents start with a compression header; `sectionData` returns them as stored.
    pub const compressed = 0x800;
};

pub const Header = struct {
    /// ET_EXEC is `.executable` (fixed addresses). ET_DYN is `.shared`: a PIE or a shared object.
    type: Type,
    machine: Machine,
    os_abi: u8,
    abi_version: u8,
    /// Link address of the entry point; 0 when there is none.
    entry: u64,
    flags: u32,
    segment_table_offset: u64,
    /// Counts and the name-table index are the effective values after extended numbering.
    segment_count: u32,
    section_table_offset: u64,
    section_count: u32,
    section_name_index: u32,
};

pub const Segment = struct {
    index: u32,
    type: SegmentType,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    file_size: u64,
    mem_size: u64,
    alignment: u64,
};

pub const Section = struct {
    index: u32,
    name: []const u8,
    type: SectionType,
    flags: u64,
    /// Link address, or 0 for a section that is not loaded.
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
    alignment: u64,
    entry_size: u64,
};

pub const Bind = enum(u4) { local = 0, global = 1, weak = 2, gnu_unique = 10, _ };
pub const SymbolType = enum(u4) { notype = 0, object = 1, func = 2, section = 3, file = 4, common = 5, tls = 6, gnu_ifunc = 10, _ };
pub const Visibility = enum(u2) { default = 0, internal = 1, hidden = 2, protected = 3 };
/// Where a symbol is defined. `section` holds the real index, already resolved
/// through SHT_SYMTAB_SHNDX when the entry used SHN_XINDEX. The index is not
/// checked against the section count until it is passed to `Image.section`.
pub const Placement = union(enum) { undefined, absolute, common, section: u32, reserved: u16 };

pub const Symbol = struct {
    table: SymbolTable.Kind,
    index: u32,
    name: []const u8,
    /// A link address only when `hasAddress()`; a TLS offset for `.tls`, a
    /// constant for absolute symbols, and unspecified for undefined ones.
    value: u64,
    size: u64,
    bind: Bind,
    type: SymbolType,
    visibility: Visibility,
    placement: Placement,

    pub fn isDefined(self: Symbol) bool {
        return self.placement != .undefined;
    }
    /// True when `value` is a link address that a load bias applies to.
    pub fn hasAddress(self: Symbol) bool {
        return self.placement == .section and addressType(@intFromEnum(self.type));
    }
};

pub const Located = struct {
    symbol: Symbol,
    /// Distance from `symbol.value`. A symbol with size 0 was matched as a label.
    offset: u64,
};

fn rd(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}
pub const Format = struct {
    is64: bool = true,
    endian: std.builtin.Endian = .little,
    pub fn addressBytes(self: Format) usize {
        return if (self.is64) 8 else 4;
    }
    fn phSize(self: Format) usize {
        return if (self.is64) 56 else 32;
    }
    fn shSize(self: Format) usize {
        return if (self.is64) 64 else 40;
    }
    fn symSize(self: Format) usize {
        return if (self.is64) 24 else 16;
    }
    fn read(self: Format, comptime T: type, bytes: []const u8, at: usize) T {
        return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], self.endian);
    }
    fn word(self: Format, bytes: []const u8, at64: usize, at32: usize) u64 {
        return if (self.is64) self.read(u64, bytes, at64) else self.read(u32, bytes, at32);
    }
};
fn span(bytes: []const u8, offset: u64, size: u64) Error![]const u8 {
    const end = std.math.add(u64, offset, size) catch return error.Truncated;
    if (end > bytes.len) return error.Truncated;
    return bytes[@intCast(offset)..@intCast(end)];
}
fn str(table: []const u8, offset: u32) Error![]const u8 {
    if (offset == 0 and table.len == 0) return "";
    if (offset >= table.len) return error.BadString;
    const rest = table[offset..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return error.BadString];
}
fn strIs(table: []const u8, offset: u32, name: []const u8) bool {
    if (offset >= table.len or table.len - offset <= name.len) return false;
    return table[offset + name.len] == 0 and std.mem.eql(u8, table[offset..][0..name.len], name);
}
fn addressType(symbol_type: u4) bool {
    return switch (@as(SymbolType, @enumFromInt(symbol_type))) {
        .notype, .object, .func, .gnu_ifunc => true,
        else => false,
    };
}
fn bindRank(bind: u4) u8 {
    return switch (@as(Bind, @enumFromInt(bind))) {
        .global, .gnu_unique => 0,
        .weak => 1,
        .local => 2,
        else => 3,
    };
}
fn typeRank(symbol_type: u4) u8 {
    return if (@as(SymbolType, @enumFromInt(symbol_type)) == .notype) 1 else 0;
}

pub const SymbolTable = struct {
    format: Format = .{},
    kind: Kind,
    /// Index of the section holding the table.
    section: u32,
    entries: []const u8,
    strings: []const u8,
    /// SHT_SYMTAB_SHNDX contents for this table, or empty.
    extended: []const u8,

    pub const Kind = enum { symtab, dynsym };

    /// Entry 0 is the reserved null symbol.
    pub fn count(self: SymbolTable) u32 {
        return @intCast(self.entries.len / self.format.symSize());
    }
    fn entry(self: SymbolTable, index: u32) []const u8 {
        return self.entries[@as(usize, index) * self.format.symSize() ..][0..self.format.symSize()];
    }
    pub fn get(self: SymbolTable, index: u32) Error!Symbol {
        if (index >= self.count()) return error.OutOfRange;
        const e = self.entry(index);
        const raw = self.format.read(u16, e, if (self.format.is64) 6 else 14);
        const placement: Placement = switch (raw) {
            shn_undef => .undefined,
            shn_abs => .absolute,
            shn_common => .common,
            shn_xindex => if (self.extended.len == 0) return error.BadSection else .{ .section = self.format.read(u32, self.extended, @as(usize, index) * 4) },
            else => if (raw >= shn_loreserve) .{ .reserved = raw } else .{ .section = raw },
        };
        return .{
            .table = self.kind,
            .index = index,
            .name = try str(self.strings, self.format.read(u32, e, 0)),
            .value = self.format.word(e, 8, 4),
            .size = self.format.word(e, 16, 8),
            .bind = @enumFromInt(e[if (self.format.is64) 4 else 12] >> 4),
            .type = @enumFromInt(e[if (self.format.is64) 4 else 12] & 0xf),
            .visibility = @enumFromInt(e[if (self.format.is64) 5 else 13] & 3),
            .placement = placement,
        };
    }
};

pub const Image = struct {
    format: Format = .{},
    bytes: []const u8,
    header: Header,
    segment_table: []const u8,
    section_table: []const u8,
    section_names: []const u8,

    /// Validates the ELF header and the extent of the segment table, section
    /// table, and section-name table. Entries are validated when accessed.
    pub fn parse(bytes: []const u8) Error!Image {
        if (bytes.len < 4 or !std.mem.eql(u8, bytes[0..4], "\x7fELF")) return error.NotElf;
        if (bytes.len < 16) return error.Truncated;
        if (bytes[4] != 1 and bytes[4] != 2) return error.UnsupportedClass;
        if (bytes[5] != 1 and bytes[5] != 2) return error.UnsupportedEncoding;
        const f = Format{ .is64 = bytes[4] == 2, .endian = if (bytes[5] == 1) .little else .big };
        if (bytes.len < (if (f.is64) @as(usize, 64) else 52)) return error.Truncated;
        const machine: Machine = @enumFromInt(f.read(u16, bytes, 18));
        if (machine != .m68k) {
            if (!f.is64) return error.UnsupportedClass;
            if (f.endian != .little) return error.UnsupportedEncoding;
        }
        if (machine != .x86_64 and machine != .aarch64 and machine != .m68k and machine != .loongarch) return error.UnsupportedMachine;
        if ((machine == .m68k) == f.is64) return error.UnsupportedClass;
        if (f.endian != (if (machine == .m68k) std.builtin.Endian.big else .little)) return error.UnsupportedEncoding;
        if (bytes[6] != 1 or f.read(u32, bytes, 20) != 1) return error.UnsupportedVersion;
        const file_type: Type = switch (f.read(u16, bytes, 16)) {
            2 => .executable,
            3 => .shared,
            else => return error.UnsupportedType,
        };
        const phoff = f.word(bytes, 32, 28);
        const shoff = f.word(bytes, 40, 32);
        var phnum: u32 = f.read(u16, bytes, if (f.is64) 56 else 44);
        var shnum: u32 = f.read(u16, bytes, if (f.is64) 60 else 48);
        var shstrndx: u32 = f.read(u16, bytes, if (f.is64) 62 else 50);
        var section_table: []const u8 = &.{};
        if (shoff == 0) {
            // No section header table; the other section fields mean nothing.
            if (phnum == pn_xnum) return error.BadHeader;
            shnum = 0;
            shstrndx = 0;
        } else {
            if (f.read(u16, bytes, if (f.is64) 58 else 46) != f.shSize()) return error.BadHeader;
            // Section 0 holds the counts that do not fit the 16-bit header fields.
            if (shnum == 0 or shstrndx == shn_xindex or phnum == pn_xnum) {
                const zero = try span(bytes, shoff, f.shSize());
                if (shnum == 0) shnum = std.math.cast(u32, f.word(zero, 32, 20)) orelse return error.BadHeader;
                if (shstrndx == shn_xindex) shstrndx = f.read(u32, zero, if (f.is64) 40 else 24);
                if (phnum == pn_xnum) phnum = f.read(u32, zero, if (f.is64) 44 else 28);
            }
            section_table = try span(bytes, shoff, @as(u64, shnum) * f.shSize());
        }
        var segment_table: []const u8 = &.{};
        if (phnum != 0) {
            if (f.read(u16, bytes, if (f.is64) 54 else 42) != f.phSize()) return error.BadHeader;
            segment_table = try span(bytes, phoff, @as(u64, phnum) * f.phSize());
        }
        var section_names: []const u8 = &.{};
        if (shstrndx != 0) {
            if (shstrndx >= shnum) return error.BadHeader;
            const h = section_table[@as(usize, shstrndx) * f.shSize() ..][0..f.shSize()];
            if (f.read(u32, h, 4) != @intFromEnum(SectionType.strtab)) return error.BadSection;
            section_names = try span(bytes, f.word(h, 24, 16), f.word(h, 32, 20));
        }
        return .{
            .format = f,
            .bytes = bytes,
            .header = .{
                .type = file_type,
                .machine = machine,
                .os_abi = bytes[7],
                .abi_version = bytes[8],
                .entry = f.word(bytes, 24, 24),
                .flags = f.read(u32, bytes, if (f.is64) 48 else 36),
                .segment_table_offset = phoff,
                .segment_count = phnum,
                .section_table_offset = shoff,
                .section_count = shnum,
                .section_name_index = shstrndx,
            },
            .segment_table = segment_table,
            .section_table = section_table,
            .section_names = section_names,
        };
    }

    pub fn segment(self: *const Image, index: u32) Error!Segment {
        if (index >= self.header.segment_count) return error.OutOfRange;
        const h = self.segment_table[@as(usize, index) * self.format.phSize() ..][0..self.format.phSize()];
        return .{ .index = index, .type = @enumFromInt(self.format.read(u32, h, 0)), .flags = self.format.read(u32, h, if (self.format.is64) 4 else 24), .offset = self.format.word(h, 8, 4), .vaddr = self.format.word(h, 16, 8), .paddr = self.format.word(h, 24, 12), .file_size = self.format.word(h, 32, 16), .mem_size = self.format.word(h, 40, 20), .alignment = self.format.word(h, 48, 28) };
    }
    /// The file-backed part of a segment.
    pub fn segmentData(self: *const Image, s: Segment) Error![]const u8 {
        return span(self.bytes, s.offset, s.file_size);
    }

    fn sectionHeader(self: *const Image, index: u32) []const u8 {
        return self.section_table[@as(usize, index) * self.format.shSize() ..][0..self.format.shSize()];
    }
    /// Index 0 is the reserved null section. Names are empty when the image
    /// has no section-name table.
    pub fn section(self: *const Image, index: u32) Error!Section {
        if (index >= self.header.section_count) return error.OutOfRange;
        const h = self.sectionHeader(index);
        return .{ .index = index, .name = if (self.header.section_name_index == 0) "" else try str(self.section_names, self.format.read(u32, h, 0)), .type = @enumFromInt(self.format.read(u32, h, 4)), .flags = self.format.word(h, 8, 8), .addr = self.format.word(h, 16, 12), .offset = self.format.word(h, 24, 16), .size = self.format.word(h, 32, 20), .link = self.format.read(u32, h, if (self.format.is64) 40 else 24), .info = self.format.read(u32, h, if (self.format.is64) 44 else 28), .alignment = self.format.word(h, 48, 32), .entry_size = self.format.word(h, 56, 36) };
    }
    /// First section with this name in table order. Names are not unique;
    /// iterate with `section` to see every match.
    pub fn sectionByName(self: *const Image, name: []const u8) ?Section {
        if (self.header.section_name_index == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return null;
        var i: u32 = 0;
        while (i < self.header.section_count) : (i += 1) {
            if (strIs(self.section_names, self.format.read(u32, self.sectionHeader(i), 0), name)) return self.section(i) catch continue;
        }
        return null;
    }
    pub fn sectionData(self: *const Image, s: Section) Error![]const u8 {
        if (s.type == .nobits) return error.NoFileData;
        return span(self.bytes, s.offset, s.size);
    }

    /// The first SHT_SYMTAB or SHT_DYNSYM section, found by type rather than
    /// name. Null when the image has none, including when it has no section table.
    pub fn symbols(self: *const Image, kind: SymbolTable.Kind) Error!?SymbolTable {
        const want = @intFromEnum(switch (kind) {
            .symtab => SectionType.symtab,
            .dynsym => SectionType.dynsym,
        });
        const n = self.header.section_count;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const h = self.sectionHeader(i);
            if (self.format.read(u32, h, 4) != want) continue;
            if (self.format.word(h, 56, 36) != self.format.symSize()) return error.BadSection;
            const entries = try span(self.bytes, self.format.word(h, 24, 16), self.format.word(h, 32, 20));
            if (entries.len % self.format.symSize() != 0 or entries.len / self.format.symSize() > std.math.maxInt(u32)) return error.BadSection;
            const link = self.format.read(u32, h, if (self.format.is64) 40 else 24);
            if (link >= n) return error.BadSection;
            const sh = self.sectionHeader(link);
            if (self.format.read(u32, sh, 4) != @intFromEnum(SectionType.strtab)) return error.BadSection;
            const strings = try span(self.bytes, self.format.word(sh, 24, 16), self.format.word(sh, 32, 20));
            var extended: []const u8 = &.{};
            var j: u32 = 0;
            while (j < n) : (j += 1) {
                const x = self.sectionHeader(j);
                if (self.format.read(u32, x, 4) != @intFromEnum(SectionType.symtab_shndx) or self.format.read(u32, x, if (self.format.is64) 40 else 24) != i) continue;
                extended = try span(self.bytes, self.format.word(x, 24, 16), self.format.word(x, 32, 20));
                if (extended.len != entries.len / self.format.symSize() * 4) return error.BadSection;
                break;
            }
            return .{ .format = self.format, .kind = kind, .section = i, .entries = entries, .strings = strings, .extended = extended };
        }
        return null;
    }

    /// Best defined symbol with this exact name: global before weak before
    /// local, `.symtab` before `.dynsym`, then lowest index. Undefined symbols
    /// are never returned, and the empty name matches nothing. Check
    /// `hasAddress()` before treating the value as an address. Unreadable
    /// tables and entries are skipped.
    pub fn findSymbol(self: *const Image, name: []const u8) ?Symbol {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return null;
        var best: ?Symbol = null;
        for ([_]SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
            const table = (self.symbols(kind) catch continue) orelse continue;
            var i: u32 = 1;
            while (i < table.count()) : (i += 1) {
                const e = table.entry(i);
                if (self.format.read(u16, e, if (self.format.is64) 6 else 14) == shn_undef or !strIs(table.strings, self.format.read(u32, e, 0), name)) continue;
                if (best) |old| if (bindRank(@truncate(e[if (self.format.is64) 4 else 12] >> 4)) >= bindRank(@intFromEnum(old.bind))) continue;
                best = table.get(i) catch continue;
            }
        }
        return best;
    }

    /// Symbol covering a link address. Only symbols with `hasAddress()` take
    /// part. The innermost sized symbol containing the address wins; ties go
    /// to typed over untyped, global over weak over local, `.symtab` over
    /// `.dynsym`, then lowest index. Failing that, the nearest zero-size
    /// symbol below the address is used as a label when no sized symbol starts
    /// between them and the address is inside the label's section.
    pub fn symbolAt(self: *const Image, address: u64) ?Located {
        var best: ?Symbol = null;
        var label: ?Symbol = null;
        var barrier: ?u64 = null;
        for ([_]SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
            const table = (self.symbols(kind) catch continue) orelse continue;
            var i: u32 = 1;
            while (i < table.count()) : (i += 1) {
                const e = table.entry(i);
                const value = self.format.word(e, 8, 4);
                const shndx = self.format.read(u16, e, if (self.format.is64) 6 else 14);
                if (value > address or shndx == shn_undef or (shndx >= shn_loreserve and shndx != shn_xindex) or !addressType(@truncate(e[if (self.format.is64) 4 else 12]))) continue;
                const size = self.format.word(e, 16, 8);
                if (size != 0 and address - value >= size) {
                    if (barrier == null or value > barrier.?) barrier = value;
                    continue;
                }
                const slot = if (size == 0) &label else &best;
                if (slot.*) |old| {
                    if (value < old.value) continue;
                    if (value == old.value) {
                        const new = [2]u8{ typeRank(@truncate(e[if (self.format.is64) 4 else 12])), bindRank(@truncate(e[if (self.format.is64) 4 else 12] >> 4)) };
                        const cur = [2]u8{ typeRank(@intFromEnum(old.type)), bindRank(@intFromEnum(old.bind)) };
                        if (std.mem.order(u8, &new, &cur) != .lt) continue;
                    }
                }
                slot.* = table.get(i) catch continue;
            }
        }
        if (best) |s| return .{ .symbol = s, .offset = address - s.value };
        const s = label orelse return null;
        if (address != s.value) {
            if (barrier) |b| if (b >= s.value) return null;
            const sec = self.section(s.placement.section) catch return null;
            if (address < sec.addr or address - sec.addr >= sec.size) return null;
        }
        return .{ .symbol = s, .offset = address - s.value };
    }

    /// File offset of the byte that a PT_LOAD maps at this link address, or
    /// null when no segment loads it from the file (unmapped, or zero-fill).
    pub fn fileOffset(self: *const Image, address: u64) ?u64 {
        var i: u32 = 0;
        while (i < self.header.segment_count) : (i += 1) {
            const s = self.segment(i) catch unreachable;
            if (s.type != .load or address < s.vaddr or address - s.vaddr >= s.file_size) continue;
            const offset = std.math.add(u64, s.offset, address - s.vaddr) catch return null;
            return if (offset < self.bytes.len) offset else null;
        }
        return null;
    }

    /// GNU build ID from PT_NOTE or SHT_NOTE, including sectionless stripped ELF.
    /// Conflicting or malformed notes are not evidence of a matching build.
    pub fn buildId(self: *const Image) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (0..self.header.segment_count) |i| {
            const segment_ = self.segment(@intCast(i)) catch return null;
            if (segment_.type != .note) continue;
            const notes = span(self.bytes, segment_.offset, segment_.file_size) catch return null;
            mergeBuildId(self.format, notes, &found) catch return null;
        }
        for (0..self.header.section_count) |i| {
            const section_ = self.section(@intCast(i)) catch return null;
            if (section_.type != .note) continue;
            mergeBuildId(self.format, self.sectionData(section_) catch return null, &found) catch return null;
        }
        return found;
    }
    fn mergeBuildId(format: Format, notes: []const u8, found: *?[]const u8) !void {
        var cursor: usize = 0;
        while (cursor < notes.len) {
            if (notes.len - cursor < 12) return error.BadNote;
            const name_size: usize = format.read(u32, notes, cursor);
            const desc_size: usize = format.read(u32, notes, cursor + 4);
            const kind = format.read(u32, notes, cursor + 8);
            const name_at = cursor + 12;
            const desc_at = std.math.add(usize, name_at, std.mem.alignForward(usize, name_size, 4)) catch return error.BadNote;
            const next = std.math.add(usize, desc_at, std.mem.alignForward(usize, desc_size, 4)) catch return error.BadNote;
            if (next > notes.len) return error.BadNote;
            if (kind == 3 and name_size == 4 and std.mem.eql(u8, notes[name_at..][0..4], "GNU\x00")) {
                if (desc_size == 0 or desc_size > 64) return error.BadNote;
                const id = notes[desc_at..][0..desc_size];
                if (found.*) |prior| if (!std.mem.eql(u8, prior, id)) return error.BadNote;
                found.* = id;
            }
            cursor = next;
        }
    }

    /// Load bias of one mapped instance of this image: the value to add to a
    /// link address to get a runtime address in that process.
    ///
    /// Pass the lowest-addressed mapping of the file in the process: its
    /// start address and its file offset (the first and third fields of its
    /// /proc/PID/maps line). That mapping is the image's first PT_LOAD. Do not
    /// pass a later mapping; two segments can share a file page, so a file
    /// offset alone does not identify a segment. The result is 0 for a
    /// correctly mapped ET_EXEC. Arithmetic wraps, as the bias is modular.
    pub fn loadBias(self: *const Image, mapping_start: u64, mapping_file_offset: u64) Error!u64 {
        var first: ?Segment = null;
        var i: u32 = 0;
        while (i < self.header.segment_count) : (i += 1) {
            const s = self.segment(i) catch unreachable;
            if (s.type == .load and (first == null or s.vaddr < first.?.vaddr)) first = s;
        }
        const s = first orelse return error.NoLoadSegment;
        // The mapping starts at the page holding the segment's first byte.
        if (mapping_file_offset > s.offset) return error.BadMapping;
        const lead = s.offset - mapping_file_offset;
        if (lead > s.vaddr or (s.alignment > 1 and lead >= s.alignment)) return error.BadMapping;
        return mapping_start -% (s.vaddr - lead);
    }
};

pub fn toRuntime(link_address: u64, bias: u64) u64 {
    return link_address +% bias;
}
pub fn toLink(runtime_address: u64, bias: u64) u64 {
    return runtime_address -% bias;
}

// Tests. The synthetic image needs no files. The fixture tests read
// tests/fixtures/elf/out/, built by tests/fixtures/elf/build.sh, relative to
// the repository root.

const testing = std.testing;
const both_tables = [_]SymbolTable.Kind{ .symtab, .dynsym };

const shstr = "\x00.text\x00.symtab\x00.strtab\x00.shstrtab\x00.dynsym\x00.dynstr\x00.symtab_shndx\x00";
const symstr = "\x00helper\x00main\x00label\x00tls\x00abs\x00ext\x00dup\x00";
const dynstr = "\x00main\x00dynonly\x00";
fn nameOffset(comptime table: []const u8, comptime name: []const u8) u32 {
    return @intCast(std.mem.indexOf(u8, table, "\x00" ++ name ++ "\x00").? + 1);
}

/// A hand-assembled image: two PT_LOADs, eight sections, ten `.symtab` and
/// three `.dynsym` entries, and an extended section index for `main`.
const Synthetic = struct {
    buf: [total]u8 = @splat(0),

    const text_addr = 0x400100;
    const text_off = 0x100;
    const shstr_off = 0x140;
    const symstr_off = 0x180;
    const dynstr_off = 0x1b0;
    const symtab_off = 0x1c0;
    const dynsym_off = 0x2b0;
    const shndx_off = 0x2f8;
    const sh_off = 0x320;
    const total = sh_off + 8 * shdr_size;

    fn put(self: *Synthetic, comptime T: type, at: usize, value: T) void {
        std.mem.writeInt(T, self.buf[at..][0..@sizeOf(T)], value, .little);
    }
    fn phdr(self: *Synthetic, i: usize, typ: u32, flags: u32, offset: u64, vaddr: u64, filesz: u64, memsz: u64) void {
        const at = ehdr_size + i * phdr_size;
        self.put(u32, at, typ);
        self.put(u32, at + 4, flags);
        self.put(u64, at + 8, offset);
        self.put(u64, at + 16, vaddr);
        self.put(u64, at + 24, vaddr);
        self.put(u64, at + 32, filesz);
        self.put(u64, at + 40, memsz);
        self.put(u64, at + 48, 0x1000);
    }
    fn shdr(self: *Synthetic, i: usize, name: u32, typ: SectionType, addr: u64, offset: u64, size: u64, link: u32, entsize: u64) void {
        const at = sh_off + i * shdr_size;
        self.put(u32, at, name);
        self.put(u32, at + 4, @intFromEnum(typ));
        self.put(u64, at + 16, addr);
        self.put(u64, at + 24, offset);
        self.put(u64, at + 32, size);
        self.put(u32, at + 40, link);
        self.put(u64, at + 56, entsize);
    }
    fn sym(self: *Synthetic, table: usize, i: usize, name: u32, info: u8, shndx: u16, value: u64, size: u64) void {
        const at = table + i * sym_size;
        self.put(u32, at, name);
        self.buf[at + 4] = info;
        self.put(u16, at + 6, shndx);
        self.put(u64, at + 8, value);
        self.put(u64, at + 16, size);
    }
    fn init() Synthetic {
        var s = Synthetic{};
        @memcpy(s.buf[0..7], "\x7fELF\x02\x01\x01");
        s.put(u16, 16, 2);
        s.put(u16, 18, 62);
        s.put(u32, 20, 1);
        s.put(u64, 24, 0x400120);
        s.put(u64, 32, ehdr_size);
        s.put(u64, 40, sh_off);
        s.put(u16, 52, ehdr_size);
        s.put(u16, 54, phdr_size);
        s.put(u16, 56, 2);
        s.put(u16, 58, shdr_size);
        s.put(u16, 60, 8);
        s.put(u16, 62, 4);
        s.phdr(0, 1, pf.r | pf.x, 0, 0x400000, 0x140, 0x140);
        s.phdr(1, 1, pf.r | pf.w, 0x140, 0x601140, 0x10, 0x30);
        @memcpy(s.buf[shstr_off..][0..shstr.len], shstr);
        @memcpy(s.buf[symstr_off..][0..symstr.len], symstr);
        @memcpy(s.buf[dynstr_off..][0..dynstr.len], dynstr);
        s.shdr(1, nameOffset(shstr, ".text"), .progbits, text_addr, text_off, 0x40, 0, 0);
        s.shdr(2, nameOffset(shstr, ".symtab"), .symtab, 0, symtab_off, 10 * sym_size, 3, sym_size);
        s.shdr(3, nameOffset(shstr, ".strtab"), .strtab, 0, symstr_off, symstr.len, 0, 0);
        s.shdr(4, nameOffset(shstr, ".shstrtab"), .strtab, 0, shstr_off, shstr.len, 0, 0);
        s.shdr(5, nameOffset(shstr, ".dynsym"), .dynsym, 0, dynsym_off, 3 * sym_size, 6, sym_size);
        s.shdr(6, nameOffset(shstr, ".dynstr"), .strtab, 0, dynstr_off, dynstr.len, 0, 0);
        s.shdr(7, nameOffset(shstr, ".symtab_shndx"), .symtab_shndx, 0, shndx_off, 10 * 4, 2, 4);
        // info = bind << 4 | type
        s.sym(symtab_off, 1, nameOffset(symstr, "helper"), 0x02, 1, 0x400100, 0x10);
        s.sym(symtab_off, 2, nameOffset(symstr, "helper"), 0x02, 1, 0x400110, 0x10);
        s.sym(symtab_off, 3, nameOffset(symstr, "main"), 0x12, shn_xindex, 0x400120, 0x10);
        s.put(u32, shndx_off + 3 * 4, 1);
        s.sym(symtab_off, 4, nameOffset(symstr, "label"), 0x10, 1, 0x400130, 0);
        s.sym(symtab_off, 5, nameOffset(symstr, "tls"), 0x16, 1, 0x400124, 4);
        s.sym(symtab_off, 6, nameOffset(symstr, "abs"), 0x10, shn_abs, 0x400128, 0);
        s.sym(symtab_off, 7, nameOffset(symstr, "ext"), 0x12, shn_undef, 0x400108, 0);
        s.sym(symtab_off, 8, nameOffset(symstr, "dup"), 0x02, 1, 0x400118, 4);
        s.sym(symtab_off, 9, nameOffset(symstr, "dup"), 0x22, 1, 0x400118, 4);
        s.sym(dynsym_off, 1, nameOffset(dynstr, "main"), 0x12, 1, 0x400120, 0x10);
        s.sym(dynsym_off, 2, nameOffset(dynstr, "dynonly"), 0x11, 1, 0x400138, 4);
        return s;
    }
    fn section0(field: usize) usize {
        return sh_off + field;
    }
};

/// Touches every accessor and swallows every error; a trap fails the test.
fn walk(bytes: []const u8) void {
    const image = Image.parse(bytes) catch return;
    var i: u32 = 0;
    while (i < image.header.segment_count) : (i += 1) {
        const s = image.segment(i) catch unreachable;
        _ = image.segmentData(s) catch {};
    }
    i = 0;
    while (i < image.header.section_count and i < 64) : (i += 1) {
        const s = image.section(i) catch continue;
        _ = image.sectionData(s) catch {};
        _ = image.sectionByName(s.name);
    }
    for (both_tables) |kind| {
        const table = (image.symbols(kind) catch continue) orelse continue;
        i = 0;
        while (i < table.count() and i < 16) : (i += 1) {
            const s = table.get(i) catch continue;
            _ = image.findSymbol(s.name);
            _ = image.symbolAt(s.value);
            _ = image.symbolAt(s.value +% s.size);
            _ = image.fileOffset(s.value);
        }
    }
    _ = image.symbolAt(image.header.entry);
    _ = image.loadBias(0x7f0000000000, 0) catch {};
}

test "ELF32 big endian m68k tables and symbols are independent of the host ABI" {
    const W = struct {
        fn put(bytes: []u8, comptime T: type, at: usize, value: T) void {
            std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .big);
        }
    };
    var bytes: [512]u8 = @splat(0);
    @memcpy(bytes[0..7], "\x7fELF\x01\x02\x01");
    W.put(&bytes, u16, 16, 2);
    W.put(&bytes, u16, 18, 4);
    W.put(&bytes, u32, 20, 1);
    W.put(&bytes, u32, 24, 0x1190);
    W.put(&bytes, u32, 28, 52);
    W.put(&bytes, u32, 32, 128);
    W.put(&bytes, u16, 40, 52);
    W.put(&bytes, u16, 42, 32);
    W.put(&bytes, u16, 44, 1);
    W.put(&bytes, u16, 46, 40);
    W.put(&bytes, u16, 48, 4);
    W.put(&bytes, u32, 52, 1);
    W.put(&bytes, u32, 60, 0x1000);
    W.put(&bytes, u32, 68, 512);
    W.put(&bytes, u32, 72, 512);
    W.put(&bytes, u32, 76, 5);
    W.put(&bytes, u32, 80, 4096);
    W.put(&bytes, u32, 172, 1);
    W.put(&bytes, u32, 176, 6);
    W.put(&bytes, u32, 180, 0x1190);
    W.put(&bytes, u32, 184, 400);
    W.put(&bytes, u32, 188, 4);
    W.put(&bytes, u32, 212, 2);
    W.put(&bytes, u32, 224, 320);
    W.put(&bytes, u32, 228, 32);
    W.put(&bytes, u32, 232, 3);
    W.put(&bytes, u32, 244, 16);
    W.put(&bytes, u32, 252, 3);
    W.put(&bytes, u32, 264, 300);
    W.put(&bytes, u32, 268, 6);
    @memcpy(bytes[300..306], "\x00func\x00");
    W.put(&bytes, u32, 336, 1);
    W.put(&bytes, u32, 340, 0x1190);
    W.put(&bytes, u32, 344, 4);
    bytes[348] = 0x12;
    W.put(&bytes, u16, 350, 1);
    const image = try Image.parse(&bytes);
    try testing.expectEqual(Machine.m68k, image.header.machine);
    try testing.expectEqual(@as(u64, 0x1190), image.header.entry);
    const segment = try image.segment(0);
    try testing.expectEqual(@as(u64, 0x1000), segment.vaddr);
    try testing.expectEqual(@as(u32, 5), segment.flags);
    const table = (try image.symbols(.symtab)).?;
    const symbol = try table.get(1);
    try testing.expectEqualStrings("func", symbol.name);
    try testing.expectEqual(@as(u64, 0x1190), symbol.value);
    try testing.expectEqual(@as(u64, 4), symbol.size);
    try testing.expectEqual(Placement{ .section = 1 }, symbol.placement);
    for (0..bytes.len) |n| _ = Image.parse(bytes[0..n]) catch continue;
}

test "synthetic image: header, segments, sections, symbols" {
    const s = Synthetic.init();
    const image = try Image.parse(&s.buf);
    try testing.expectEqual(Type.executable, image.header.type);
    try testing.expectEqual(Machine.x86_64, image.header.machine);
    try testing.expectEqual(@as(u64, 0x400120), image.header.entry);
    try testing.expectEqual(@as(u32, 2), image.header.segment_count);
    try testing.expectEqual(@as(u32, 8), image.header.section_count);
    try testing.expectEqual(@as(u32, 4), image.header.section_name_index);

    const data = try image.segment(1);
    try testing.expectEqual(SegmentType.load, data.type);
    try testing.expectEqual(@as(u64, 0x601140), data.vaddr);
    try testing.expectEqual(@as(u64, 0x30), data.mem_size);
    try testing.expectEqual(@as(usize, 0x10), (try image.segmentData(data)).len);
    try testing.expectError(error.OutOfRange, image.segment(2));

    const text = try image.section(1);
    try testing.expectEqualStrings(".text", text.name);
    try testing.expectEqual(@as(u64, Synthetic.text_addr), text.addr);
    try testing.expectEqual(@as(usize, 0x40), (try image.sectionData(text)).len);
    try testing.expectEqualStrings("", (try image.section(0)).name);
    try testing.expectEqual(@as(u32, 2), image.sectionByName(".symtab").?.index);
    try testing.expectEqual(@as(u32, 7), image.sectionByName(".symtab_shndx").?.index);
    try testing.expect(image.sectionByName(".symtab_") == null);
    try testing.expect(image.sectionByName("") == null or image.sectionByName("").?.index == 0);
    try testing.expectError(error.OutOfRange, image.section(8));

    const symtab = (try image.symbols(.symtab)).?;
    try testing.expectEqual(@as(u32, 10), symtab.count());
    try testing.expectEqual(@as(u32, 2), symtab.section);
    const main = try symtab.get(3);
    try testing.expectEqualStrings("main", main.name);
    try testing.expectEqual(Placement{ .section = 1 }, main.placement);
    try testing.expectEqual(Bind.global, main.bind);
    try testing.expectEqual(SymbolType.func, main.type);
    try testing.expect(main.hasAddress());
    const tls = try symtab.get(5);
    try testing.expectEqual(SymbolType.tls, tls.type);
    try testing.expect(tls.isDefined() and !tls.hasAddress());
    const abs = try symtab.get(6);
    try testing.expectEqual(Placement.absolute, abs.placement);
    try testing.expect(abs.isDefined() and !abs.hasAddress());
    const ext = try symtab.get(7);
    try testing.expect(!ext.isDefined() and !ext.hasAddress());
    try testing.expectEqual(Bind.weak, (try symtab.get(9)).bind);
    try testing.expectEqualStrings("", (try symtab.get(0)).name);
    try testing.expectError(error.OutOfRange, symtab.get(10));
    try testing.expectEqual(@as(u32, 3), (try image.symbols(.dynsym)).?.count());
}

test "synthetic image: lookup by name handles duplicates and undefined symbols" {
    const s = Synthetic.init();
    const image = try Image.parse(&s.buf);
    const main = image.findSymbol("main").?;
    try testing.expectEqual(SymbolTable.Kind.symtab, main.table);
    try testing.expectEqual(@as(u32, 3), main.index);
    try testing.expectEqual(@as(u32, 1), image.findSymbol("helper").?.index);
    try testing.expectEqual(@as(u32, 9), image.findSymbol("dup").?.index);
    try testing.expectEqual(SymbolTable.Kind.dynsym, image.findSymbol("dynonly").?.table);
    try testing.expect(!image.findSymbol("tls").?.hasAddress());
    try testing.expect(image.findSymbol("ext") == null);
    try testing.expect(image.findSymbol("mai") == null);
    try testing.expect(image.findSymbol("main\x00") == null);
    try testing.expect(image.findSymbol("") == null);
}

test "synthetic image: lookup by address" {
    var s = Synthetic.init();
    const image = try Image.parse(&s.buf);
    const Case = struct { address: u64, name: ?[]const u8, index: u32 = 0, offset: u64 = 0 };
    for ([_]Case{
        .{ .address = 0x400120, .name = "main", .index = 3 },
        .{ .address = 0x40012f, .name = "main", .index = 3, .offset = 0xf }, // tls and abs values inside main are not addresses
        .{ .address = 0x400108, .name = "helper", .index = 1, .offset = 8 }, // not the undefined `ext`
        .{ .address = 0x400119, .name = "dup", .index = 9, .offset = 1 }, // innermost; weak beats local
        .{ .address = 0x40011c, .name = "helper", .index = 2, .offset = 0xc }, // past the nested symbol
        .{ .address = 0x400130, .name = "label", .index = 4 },
        .{ .address = 0x400134, .name = "label", .index = 4, .offset = 4 }, // zero-size label
        .{ .address = 0x400139, .name = "dynonly", .index = 2, .offset = 1 },
        .{ .address = 0x40013d, .name = null }, // a sized symbol starts between the label and the address
        .{ .address = 0x400140, .name = null },
        .{ .address = 0x4000ff, .name = null },
        .{ .address = 0, .name = null },
        .{ .address = std.math.maxInt(u64), .name = null },
    }) |case| {
        const found = image.symbolAt(case.address);
        if (case.name) |name| {
            try testing.expectEqualStrings(name, found.?.symbol.name);
            try testing.expectEqual(case.index, found.?.symbol.index);
            try testing.expectEqual(case.offset, found.?.offset);
        } else try testing.expect(found == null);
    }
    // Without the sized symbol the label extends to the end of its section and no further.
    s.buf[Synthetic.dynsym_off + 2 * sym_size + 4] = 0x16;
    try testing.expectEqual(@as(u64, 0xf), image.symbolAt(0x40013f).?.offset);
    try testing.expect(image.symbolAt(0x400140) == null);
}

test "synthetic image: load bias and address conversion" {
    var s = Synthetic.init();
    const image = try Image.parse(&s.buf);
    try testing.expectEqual(@as(u64, 0), try image.loadBias(0x400000, 0));
    const bias = try image.loadBias(0x555555954000, 0);
    try testing.expectEqual(@as(u64, 0x555555554000), bias);
    try testing.expectEqual(@as(u64, 0x555555954120), toRuntime(image.findSymbol("main").?.value, bias));
    try testing.expectEqual(@as(u64, 0x400120), toLink(0x555555954120, bias));
    try testing.expectEqual(@as(u64, 0x400120), toLink(toRuntime(0x400120, try image.loadBias(0x1000, 0)), try image.loadBias(0x1000, 0)));
    try testing.expectError(error.BadMapping, image.loadBias(0x555555955000, 0x1000));

    try testing.expectEqual(@as(?u64, 0x120), image.fileOffset(0x400120));
    try testing.expectEqual(@as(?u64, 0x140), image.fileOffset(0x601140));
    try testing.expectEqual(@as(?u64, null), image.fileOffset(0x601150)); // zero-fill tail
    try testing.expectEqual(@as(?u64, null), image.fileOffset(0x3fffff));

    // A first segment that starts mid-page: the mapping still begins at the page.
    s.phdr(0, 1, pf.r | pf.x, 0x10, 0x400010, 0x130, 0x130);
    try testing.expectEqual(@as(u64, 0x1000), try image.loadBias(0x401000, 0));
    s.phdr(0, 4, pf.r, 0, 0x400000, 0x140, 0x140);
    s.phdr(1, 4, pf.r, 0x140, 0x601140, 0x10, 0x30);
    try testing.expectError(error.NoLoadSegment, image.loadBias(0x400000, 0));
}

test "synthetic image: unsupported formats are rejected by name" {
    const Case = struct { at: usize, value: u8, err: Error };
    for ([_]Case{
        .{ .at = 0, .value = 0x7e, .err = error.NotElf },
        .{ .at = 4, .value = 1, .err = error.UnsupportedClass },
        .{ .at = 5, .value = 2, .err = error.UnsupportedEncoding },
        .{ .at = 6, .value = 0, .err = error.UnsupportedVersion },
        .{ .at = 20, .value = 2, .err = error.UnsupportedVersion },
        .{ .at = 18, .value = 243, .err = error.UnsupportedMachine },
        .{ .at = 16, .value = 1, .err = error.UnsupportedType }, // ET_REL
        .{ .at = 16, .value = 4, .err = error.UnsupportedType }, // ET_CORE
    }) |case| {
        var s = Synthetic.init();
        s.buf[case.at] = case.value;
        try testing.expectError(case.err, Image.parse(&s.buf));
    }
    try testing.expectError(error.NotElf, Image.parse(""));
    try testing.expectError(error.NotElf, Image.parse("\x7fEL"));
    try testing.expectError(error.Truncated, Image.parse(Synthetic.init().buf[0..63]));
}

test "ELF64 little-endian LoongArch is accepted" {
    var s = Synthetic.init();
    s.buf[18] = 0x02;
    s.buf[19] = 0x01;
    const image = try Image.parse(&s.buf);
    try testing.expectEqual(Machine.loongarch, image.header.machine);
    try testing.expect(image.format.is64);
    try testing.expectEqual(std.builtin.Endian.little, image.format.endian);
}

test "synthetic image: malformed headers and tables return errors" {
    const max = std.math.maxInt(u64);
    {
        var s = Synthetic.init();
        s.put(u16, 54, phdr_size - 1);
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u16, 58, shdr_size + 1);
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u64, 32, max - 8); // offset + size overflows
        try testing.expectError(error.Truncated, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u64, 40, Synthetic.total - 8);
        try testing.expectError(error.Truncated, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u16, 62, 8); // name table index past the table
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u16, 62, 1); // .text is not a string table
        try testing.expectError(error.BadSection, Image.parse(&s.buf));
        s = Synthetic.init();
        s.put(u64, Synthetic.sh_off + 4 * shdr_size + 32, max);
        try testing.expectError(error.Truncated, Image.parse(&s.buf));
    }
    {
        // Section names: offset outside the table, and a final string with no terminator.
        var s = Synthetic.init();
        s.put(u32, Synthetic.sh_off + 1 * shdr_size, 0xffff);
        s.buf[Synthetic.shstr_off + shstr.len - 1] = 'x';
        const image = try Image.parse(&s.buf);
        try testing.expectError(error.BadString, image.section(1));
        try testing.expectError(error.BadString, image.section(7));
        try testing.expect(image.sectionByName(".text") == null);
        try testing.expectEqualStrings(".symtab", (try image.section(2)).name);
    }
    {
        // A bad .symtab is reported by `symbols`; lookups fall back to .dynsym.
        const symtab = Synthetic.sh_off + 2 * shdr_size;
        var s = Synthetic.init();
        const image = try Image.parse(&s.buf);
        s.put(u64, symtab + 56, sym_size - 1); // entry stride
        try testing.expectError(error.BadSection, image.symbols(.symtab));
        try testing.expectEqual(SymbolTable.Kind.dynsym, image.findSymbol("main").?.table);
        try testing.expect(image.findSymbol("helper") == null);
        try testing.expectEqualStrings("main", image.symbolAt(0x400121).?.symbol.name);
        s = Synthetic.init();
        s.put(u64, symtab + 32, 10 * sym_size + 1); // size is not a whole number of entries
        try testing.expectError(error.BadSection, image.symbols(.symtab));
        s.put(u64, symtab + 32, max);
        try testing.expectError(error.Truncated, image.symbols(.symtab));
        s = Synthetic.init();
        s.put(u64, symtab + 24, Synthetic.total - 8); // table runs off the end
        try testing.expectError(error.Truncated, image.symbols(.symtab));
        s = Synthetic.init();
        s.put(u32, symtab + 40, 8); // string table link past the section table
        try testing.expectError(error.BadSection, image.symbols(.symtab));
        s.put(u32, symtab + 40, 1); // linked section is not a string table
        try testing.expectError(error.BadSection, image.symbols(.symtab));
        s = Synthetic.init();
        s.put(u64, Synthetic.sh_off + 3 * shdr_size + 32, max); // string table extent
        try testing.expectError(error.Truncated, image.symbols(.symtab));
    }
    {
        // Entry-level damage is confined to the entry.
        var s = Synthetic.init();
        const image = try Image.parse(&s.buf);
        s.put(u32, Synthetic.symtab_off + 1 * sym_size, 0xffffff);
        const table = (try image.symbols(.symtab)).?;
        try testing.expectError(error.BadString, table.get(1));
        try testing.expectEqual(@as(u32, 2), image.findSymbol("helper").?.index);
        try testing.expectEqualStrings("helper", (try table.get(2)).name);
        try testing.expect(image.symbolAt(0x400104) == null);
    }
    {
        // Extended section indexes: wrong table size, then no table at all.
        var s = Synthetic.init();
        const image = try Image.parse(&s.buf);
        s.put(u64, Synthetic.sh_off + 7 * shdr_size + 32, 9 * 4);
        try testing.expectError(error.BadSection, image.symbols(.symtab));
        s.put(u32, Synthetic.sh_off + 7 * shdr_size + 4, @intFromEnum(SectionType.progbits));
        const table = (try image.symbols(.symtab)).?;
        try testing.expectError(error.BadSection, table.get(3));
        try testing.expectEqualStrings("label", (try table.get(4)).name);
        try testing.expectEqual(SymbolTable.Kind.dynsym, image.findSymbol("main").?.table);
    }
    {
        var s = Synthetic.init();
        const image = try Image.parse(&s.buf);
        s.put(u32, Synthetic.sh_off + 1 * shdr_size + 4, @intFromEnum(SectionType.nobits));
        try testing.expectError(error.NoFileData, image.sectionData(try image.section(1)));
        s.put(u32, Synthetic.sh_off + 1 * shdr_size + 4, @intFromEnum(SectionType.progbits));
        s.put(u64, Synthetic.sh_off + 1 * shdr_size + 32, Synthetic.total);
        try testing.expectError(error.Truncated, image.sectionData(try image.section(1)));
        s.put(u64, ehdr_size + 32, max);
        try testing.expectError(error.Truncated, image.segmentData(try image.segment(0)));
        try testing.expectEqual(@as(?u64, null), image.fileOffset(0x400000 + Synthetic.total));
    }
}

test "synthetic image: extended numbering and missing section table" {
    {
        // e_shnum, e_shstrndx, and e_phnum escape to section 0.
        var s = Synthetic.init();
        s.put(u16, 60, 0);
        s.put(u64, Synthetic.section0(32), 8);
        s.put(u16, 62, shn_xindex);
        s.put(u32, Synthetic.section0(40), 4);
        s.put(u16, 56, pn_xnum);
        s.put(u32, Synthetic.section0(44), 2);
        const image = try Image.parse(&s.buf);
        try testing.expectEqual(@as(u32, 8), image.header.section_count);
        try testing.expectEqual(@as(u32, 4), image.header.section_name_index);
        try testing.expectEqual(@as(u32, 2), image.header.segment_count);
        try testing.expectEqualStrings(".text", (try image.section(1)).name);
        try testing.expectEqual(@as(u32, 3), image.findSymbol("main").?.index);
        s.put(u64, Synthetic.section0(32), 1 << 32);
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
        s.put(u64, Synthetic.section0(32), 9);
        try testing.expectError(error.Truncated, Image.parse(&s.buf));
        s.put(u64, Synthetic.section0(32), 0); // no sections, yet a name table index
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
    }
    {
        // Sections without a name table have empty names.
        var s = Synthetic.init();
        s.put(u16, 62, 0);
        const image = try Image.parse(&s.buf);
        try testing.expectEqualStrings("", (try image.section(1)).name);
        try testing.expect(image.sectionByName(".text") == null);
        try testing.expectEqual(@as(u32, 3), image.findSymbol("main").?.index);
    }
    {
        // e_shoff == 0: no section table, so no named sections and no symbol tables.
        var s = Synthetic.init();
        s.put(u64, 40, 0);
        const image = try Image.parse(&s.buf);
        try testing.expectEqual(@as(u32, 0), image.header.section_count);
        try testing.expectEqual(@as(u32, 2), image.header.segment_count);
        try testing.expectError(error.OutOfRange, image.section(0));
        try testing.expect(try image.symbols(.symtab) == null);
        try testing.expect(try image.symbols(.dynsym) == null);
        try testing.expect(image.findSymbol("main") == null);
        try testing.expect(image.symbolAt(0x400120) == null);
        try testing.expectEqual(@as(u64, 0), try image.loadBias(0x400000, 0));
        s.put(u16, 56, pn_xnum); // the segment count would live in section 0
        try testing.expectError(error.BadHeader, Image.parse(&s.buf));
    }
}

test "synthetic image: every prefix and every single-byte corruption is survivable" {
    var s = Synthetic.init();
    for (0..Synthetic.total) |len| {
        try testing.expect(std.meta.isError(Image.parse(s.buf[0..len])));
        walk(s.buf[0..len]);
    }
    for (0..Synthetic.total) |at| {
        const original = s.buf[at];
        for ([_]u8{ 0x00, 0xff, original ^ 0x01, original ^ 0x80, original +% 1, original -% 1 }) |value| {
            s.buf[at] = value;
            walk(&s.buf);
        }
        s.buf[at] = original;
    }
    try testing.expectEqualSlices(u8, &Synthetic.init().buf, &s.buf);
}

fn fixture(comptime name: []const u8) ![]u8 {
    const path = "tests/fixtures/elf/out/" ++ name;
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited) catch |err| {
        std.debug.print("cannot read {s}: {s}. Run tests/fixtures/elf/build.sh, then test from the repository root.\n", .{ path, @errorName(err) });
        return error.FixtureUnavailable;
    };
}
fn countNamed(table: SymbolTable, name: []const u8) !u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < table.count()) : (i += 1) {
        if (std.mem.eql(u8, (try table.get(i)).name, name)) n += 1;
    }
    return n;
}
fn hasSegment(image: *const Image, wanted: SegmentType) bool {
    var i: u32 = 0;
    while (i < image.header.segment_count) : (i += 1) {
        if ((image.segment(i) catch unreachable).type == wanted) return true;
    }
    return false;
}

test "fixtures: executable and PIE symbols" {
    inline for (.{ "gcc-exec", "gcc-pie", "clang-pie", "clang-lld-pie" }) |name| {
        const bytes = try fixture(name);
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        const pie = !std.mem.eql(u8, name, "gcc-exec");
        try testing.expectEqual(if (pie) Type.shared else Type.executable, image.header.type);
        try testing.expect(hasSegment(&image, .interp) and hasSegment(&image, .dynamic));

        const main = image.findSymbol("main").?;
        try testing.expectEqual(SymbolTable.Kind.symtab, main.table);
        try testing.expectEqual(Bind.global, main.bind);
        try testing.expectEqual(SymbolType.func, main.type);
        try testing.expect(main.hasAddress() and main.size > 0);
        const inside = image.symbolAt(main.value + main.size - 1).?;
        try testing.expectEqualStrings("main", inside.symbol.name);
        try testing.expectEqual(main.size - 1, inside.offset);

        // The symbol's section and the PT_LOAD mapping agree about where its bytes are.
        const text = try image.section(main.placement.section);
        try testing.expectEqualStrings(".text", text.name);
        try testing.expect(text.flags & shf.execinstr != 0);
        try testing.expectEqual(@as(?u64, text.offset + (main.value - text.addr)), image.fileOffset(main.value));
        try testing.expectEqualStrings(".text", image.sectionByName(".text").?.name);

        // Duplicate local names: both remain visible, lookup returns the first.
        const symtab = (try image.symbols(.symtab)).?;
        try testing.expectEqual(@as(u32, 2), try countNamed(symtab, "helper"));
        try testing.expectEqual(@as(u32, 2), try countNamed(symtab, "counter"));
        const helper = image.findSymbol("helper").?;
        try testing.expectEqual(Bind.local, helper.bind);
        var i: u32 = 1;
        while (i < helper.index) : (i += 1) try testing.expect(!std.mem.eql(u8, (try symtab.get(i)).name, "helper"));

        const tls = image.findSymbol("fixture_tls").?;
        try testing.expectEqual(SymbolType.tls, tls.type);
        try testing.expect(!tls.hasAddress());
        const abs = image.findSymbol("fixture_abs").?;
        try testing.expectEqual(Placement.absolute, abs.placement);
        try testing.expectEqual(@as(u64, 0x1234), abs.value);
        try testing.expectEqual(Bind.weak, image.findSymbol("fixture_weak").?.bind);
        // Linkers disagree on how a hidden symbol is recorded: GLOBAL HIDDEN, LOCAL DEFAULT, or LOCAL HIDDEN.
        const hidden = image.findSymbol("fixture_hidden").?;
        try testing.expect(hidden.bind == .local or hidden.visibility == .hidden);
        try testing.expectEqual(@as(u32, 0), try countNamed((try image.symbols(.dynsym)).?, "fixture_hidden"));
        try testing.expectEqualStrings(".bss", (try image.section(image.findSymbol("fixture_zeroed").?.placement.section)).name);
        try testing.expectEqual(@as(?u64, null), image.fileOffset(image.findSymbol("fixture_zeroed").?.value));

        // A function label with no size covers the bytes up to the next symbol.
        const label = image.findSymbol("fixture_label").?;
        try testing.expectEqual(@as(u64, 0), label.size);
        const after = image.symbolAt(label.value + 1).?;
        try testing.expectEqualStrings("fixture_label", after.symbol.name);
        try testing.expectEqual(@as(u64, 1), after.offset);

        // Undefined symbols stay visible in iteration and never resolve, even
        // when the linker gave one a PLT address (gcc-exec's libfix_plain).
        try testing.expect(image.findSymbol("libfix_add") == null);
        try testing.expect(image.findSymbol("") == null); // unnamed section symbols exist; the empty name finds none
        const dynsym = (try image.symbols(.dynsym)).?;
        try testing.expectEqual(@as(u32, 1), try countNamed(dynsym, "libfix_plain"));
        i = 1;
        while (i < dynsym.count()) : (i += 1) {
            const s = try dynsym.get(i);
            if (s.isDefined()) continue;
            try testing.expect(image.findSymbol(s.name) == null);
            if (image.symbolAt(s.value)) |found| try testing.expect(found.symbol.isDefined());
        }

        const first = try image.loadBias(if (pie) 0x555555554000 else 0x400000, 0);
        try testing.expectEqual(@as(u64, if (pie) 0x555555554000 else 0), first);
    }
}

test "fixtures: shared object, stripped, debug-only, section-less, static" {
    {
        const bytes = try fixture("libfix.so");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expectEqual(Type.shared, image.header.type);
        try testing.expect(!hasSegment(&image, .interp));
        const add = image.findSymbol("libfix_add").?;
        try testing.expectEqual(Visibility.protected, add.visibility);
        try testing.expectEqual(Bind.global, add.bind);
        try testing.expectEqual(Bind.local, image.findSymbol("libfix_hidden_fn").?.bind);
        const dynsym = (try image.symbols(.dynsym)).?;
        try testing.expectEqual(@as(u32, 1), try countNamed(dynsym, "libfix_add"));
        try testing.expectEqual(@as(u32, 0), try countNamed(dynsym, "libfix_hidden_fn"));
        try testing.expectEqual(@as(u32, 0), try countNamed(dynsym, "local_data"));
    }
    {
        const bytes = try fixture("libfix.stripped.so");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expect(try image.symbols(.symtab) == null);
        const add = image.findSymbol("libfix_add").?;
        try testing.expectEqual(SymbolTable.Kind.dynsym, add.table);
        try testing.expectEqualStrings("libfix_add", image.symbolAt(add.value + 1).?.symbol.name);
        try testing.expect(image.findSymbol("libfix_hidden_fn") == null);
    }
    const pie_bytes = try fixture("gcc-pie");
    defer testing.allocator.free(pie_bytes);
    const pie = try Image.parse(pie_bytes);
    {
        const bytes = try fixture("gcc-pie.stripped");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expect(try image.symbols(.symtab) == null);
        try testing.expect((try image.symbols(.dynsym)).?.count() > 1);
        try testing.expect(image.findSymbol("main") == null);
        try testing.expect(image.symbolAt(pie.findSymbol("main").?.value) == null);
        try testing.expectEqual(pie.sectionByName(".text").?.addr, image.sectionByName(".text").?.addr);
        try testing.expectEqual(pie.header.entry, image.header.entry);
    }
    {
        // objcopy --only-keep-debug: symbols survive, loaded contents become SHT_NOBITS.
        const bytes = try fixture("gcc-pie.debug");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expectEqual(pie.findSymbol("main").?.value, image.findSymbol("main").?.value);
        try testing.expect(try image.symbols(.dynsym) == null);
        try testing.expectError(error.NoFileData, image.sectionData(image.sectionByName(".text").?));
        try testing.expectEqual(@as(?u64, null), image.fileOffset(image.findSymbol("main").?.value));
    }
    {
        // llvm-objcopy --strip-sections: segments only.
        const bytes = try fixture("gcc-pie.nosections");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expectEqual(@as(u32, 0), image.header.section_count);
        try testing.expectEqual(pie.header.segment_count, image.header.segment_count);
        try testing.expectEqual(pie.header.entry, image.header.entry);
        try testing.expect(try image.symbols(.symtab) == null and try image.symbols(.dynsym) == null);
        try testing.expect(image.findSymbol("main") == null and image.sectionByName(".text") == null);
        try testing.expectEqual(pie.fileOffset(pie.header.entry), image.fileOffset(image.header.entry));
        try testing.expectEqual(@as(u64, 0x7f0000000000), try image.loadBias(0x7f0000000000, 0));
    }
    {
        const bytes = try fixture("gcc-static");
        defer testing.allocator.free(bytes);
        const image = try Image.parse(bytes);
        try testing.expectEqual(Type.executable, image.header.type);
        try testing.expect(!hasSegment(&image, .interp));
        try testing.expect(try image.symbols(.dynsym) == null);
        try testing.expectEqualStrings("main", image.symbolAt(image.findSymbol("main").?.value).?.symbol.name);
        try testing.expectEqual(SymbolType.tls, image.findSymbol("static_tls").?.type);
        const table = (try image.symbols(.symtab)).?;
        var ifuncs: u32 = 0;
        var i: u32 = 0;
        while (i < table.count()) : (i += 1) {
            const s = try table.get(i);
            if (s.type != .gnu_ifunc) continue;
            ifuncs += 1;
            try testing.expect(s.hasAddress());
        }
        try testing.expect(ifuncs > 0);
    }
}

test "fixtures: more than 0xff00 sections" {
    const bytes = try fixture("many-sections");
    defer testing.allocator.free(bytes);
    const image = try Image.parse(bytes);
    try testing.expect(image.header.section_count > 66000);
    try testing.expect(image.header.section_name_index >= shn_loreserve);
    const s = image.findSymbol("many66000").?;
    try testing.expect(s.placement.section >= shn_loreserve);
    const sec = try image.section(s.placement.section);
    try testing.expectEqualStrings("sec66000", sec.name);
    try testing.expectEqual(sec.addr, s.value);
    try testing.expectEqualSlices(u8, &.{ 0xd0, 0x01, 0x01, 0x00 }, try image.sectionData(sec)); // 66000
    try testing.expectEqualStrings("many66000", image.symbolAt(s.value + 3).?.symbol.name);
    try testing.expectEqual(image.findSymbol("many65000").?.placement.section, image.sectionByName("sec65000").?.index);
    try testing.expectEqualStrings("main", image.symbolAt(image.findSymbol("main").?.value).?.symbol.name);
}

test "fixtures: other object kinds are rejected by name" {
    inline for (.{
        .{ "reject-rel.o", error.UnsupportedType },
        .{ "reject-i386", error.UnsupportedClass },
        .{ "reject-ppc64be", error.UnsupportedEncoding },
    }) |case| {
        const bytes = try fixture(case[0]);
        defer testing.allocator.free(bytes);
        try testing.expectError(case[1], Image.parse(bytes));
    }
}

test "fixtures: truncation and seeded corruption are survivable" {
    inline for (.{ "gcc-pie", "libfix.so", "gcc-pie.stripped", "gcc-pie.nosections", "clang-lld-pie" }) |name| {
        const bytes = try fixture(name);
        defer testing.allocator.free(bytes);
        for (0..bytes.len) |len| walk(bytes[0..len]);
        const image = try Image.parse(bytes);
        if (image.header.section_count != 0) {
            // The section table is the last thing in these files, so losing one byte loses it.
            try testing.expectError(error.Truncated, Image.parse(bytes[0 .. bytes.len - 1]));
        }
        // Corrupt one byte at a time, favouring the headers and tables.
        const section_table: usize = @intCast(image.header.section_table_offset);
        const regions = [_][2]usize{
            .{ 0, @min(bytes.len, 0x400) },
            .{ section_table, bytes.len },
            .{ 0, bytes.len },
        };
        var prng = std.Random.DefaultPrng.init(0x7801);
        const random = prng.random();
        for (0..1500) |round| {
            const region = regions[round % regions.len];
            const at = region[0] + random.uintLessThan(usize, region[1] - region[0]);
            const original = bytes[at];
            bytes[at] = if (round % 2 == 0) random.int(u8) else original ^ (@as(u8, 1) << random.int(u3));
            walk(bytes);
            bytes[at] = original;
        }
    }
}

// Kept under its historical fixture name so existing evidence remains identifiable.
test "fixtures: ARM64 ELF machine is preserved independently of the host" {
    const bytes = try fixture("reject-aarch64");
    defer testing.allocator.free(bytes);
    const image = try Image.parse(bytes);
    try testing.expectEqual(Machine.aarch64, image.header.machine);
    try testing.expect(image.findSymbol("_start") != null);
}

test "build ID works without sections and rejects conflicting or truncated GNU notes" {
    var bytes: [256]u8 = @splat(0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[4] = 2;
    bytes[5] = 1;
    bytes[6] = 1;
    const wr = struct {
        fn put(b: []u8, comptime T: type, at: usize, v: T) void {
            std.mem.writeInt(T, b[at..][0..@sizeOf(T)], v, .little);
        }
    }.put;
    wr(&bytes, u16, 16, 3);
    wr(&bytes, u16, 18, 183);
    wr(&bytes, u32, 20, 1);
    wr(&bytes, u64, 32, 64);
    wr(&bytes, u16, 52, 64);
    wr(&bytes, u16, 54, 56);
    wr(&bytes, u16, 56, 1);
    wr(&bytes, u32, 64, 4);
    wr(&bytes, u64, 72, 128);
    wr(&bytes, u64, 96, 20);
    wr(&bytes, u32, 128, 4);
    wr(&bytes, u32, 132, 4);
    wr(&bytes, u32, 136, 3);
    @memcpy(bytes[140..148], "GNU\x00abcd");
    var image = try Image.parse(&bytes);
    try testing.expectEqualStrings("abcd", image.buildId().?);
    @memcpy(bytes[148..168], bytes[128..148]);
    wr(&bytes, u64, 96, 40);
    image = try Image.parse(&bytes);
    try testing.expectEqualStrings("abcd", image.buildId().?);
    bytes[164] = 'X';
    try testing.expect(image.buildId() == null);
    wr(&bytes, u64, 96, 19);
    image = try Image.parse(&bytes);
    try testing.expect(image.buildId() == null);
}
