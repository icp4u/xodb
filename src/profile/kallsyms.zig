//! One capture's kernel symbol table, parsed from kallsyms text.
//! The text is owned once. Names and module names are slices into it.
//! Addresses are the values in that text. A table whose addresses are all
//! zero cannot be searched; the caller labels those frames without a name.
const std = @import("std");

pub const Symbol = struct {
    address: u64,
    name: []const u8,
    /// Empty for a symbol built into the kernel image. Otherwise the module
    /// name, without brackets.
    module: []const u8 = "",
    /// Zero uses the next stored symbol as the end, and the last symbol
    /// matches only its own address. A nonzero limit matches [address, limit).
    limit: u64 = 0,
};

pub const Table = struct {
    symbols: []Symbol = &.{},
    text: []u8 = &.{},
    addresses_hidden: bool = false,
    allocator: std.mem.Allocator = std.heap.page_allocator,

    pub fn deinit(self: *Table) void {
        self.allocator.free(self.symbols);
        self.allocator.free(self.text);
        self.* = .{ .allocator = self.allocator };
    }

    /// Greatest symbol at or below `address`. A following symbol, or `limit`
    /// when set, ends the range. The last symbol of a full table matches only
    /// its own address.
    pub fn lookup(self: Table, address: u64) ?Symbol {
        if (self.addresses_hidden or self.symbols.len == 0 or address < self.symbols[0].address) return null;
        var lo: usize = 0;
        var hi: usize = self.symbols.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.symbols[mid].address <= address) lo = mid else hi = mid;
        }
        var symbol = self.symbols[lo];
        if (symbol.limit != 0) {
            if (address < symbol.address or address >= symbol.limit) return null;
            return symbol;
        }
        if (lo + 1 < self.symbols.len) {
            if (address >= self.symbols[lo + 1].address) return null;
            symbol.limit = self.symbols[lo + 1].address;
            return symbol;
        }
        if (address != symbol.address) return null;
        symbol.limit = address + 1;
        return symbol;
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Table {
    const owned = try allocator.dupe(u8, text);
    return parseOwned(allocator, owned);
}

/// `owned` is the table text. The table keeps it, and an error frees it.
pub fn parseOwned(allocator: std.mem.Allocator, owned: []u8) !Table {
    errdefer allocator.free(owned);
    var list: std.ArrayList(Symbol) = .empty;
    errdefer list.deinit(allocator);
    var nonzero = false;
    var lines = std.mem.splitScalar(u8, owned, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const parsed = parseLine(line) catch continue;
        const symbol = parsed orelse continue;
        if (symbol.address != 0) nonzero = true;
        try list.append(allocator, symbol);
    }
    std.mem.sort(Symbol, list.items, {}, less);
    const symbols = try list.toOwnedSlice(allocator);
    return .{ .symbols = symbols, .text = owned, .addresses_hidden = symbols.len > 0 and !nonzero, .allocator = allocator };
}

fn less(_: void, a: Symbol, b: Symbol) bool {
    return a.address < b.address;
}

fn parseLine(line: []const u8) !?Symbol {
    var parts = std.mem.tokenizeAny(u8, line, " \t");
    const addr_text = parts.next() orelse return null;
    const type_text = parts.next() orelse return null;
    const name_text = parts.next() orelse return null;
    if (type_text.len != 1) return null;
    const address = std.fmt.parseInt(u64, addr_text, 16) catch return null;
    if (parts.next()) |extra| {
        if (extra.len < 3 or extra[0] != '[' or extra[extra.len - 1] != ']' or parts.next() != null) return error.InvalidKallsymsLine;
        return .{ .address = address, .name = name_text, .module = extra[1 .. extra.len - 1] };
    }
    return .{ .address = address, .name = name_text };
}

test "kallsyms names an interior address and a module, and hides an all-zero table" {
    const a = std.testing.allocator;
    const text =
        \\ffffffff81000100 T vfs_read
        \\ffffffff81000200 T sys_read
        \\ffffffffa0100100 t drm_ioctl [drm]
        \\
    ;
    var table = try parse(a, text);
    defer table.deinit();
    try std.testing.expect(!table.addresses_hidden);
    const vfs = table.lookup(0xffffffff81000180).?;
    try std.testing.expectEqualStrings("vfs_read", vfs.name);
    try std.testing.expectEqual(@as(usize, 0), vfs.module.len);
    try std.testing.expectEqual(@as(u64, 0xffffffff81000200), vfs.limit);
    const drm = table.lookup(0xffffffffa0100100).?;
    try std.testing.expectEqualStrings("drm_ioctl", drm.name);
    try std.testing.expectEqualStrings("drm", drm.module);
    try std.testing.expectEqualStrings("sys_read", table.lookup(0xffffffff81000201).?.name);
    try std.testing.expect(table.lookup(0xffffffff81000080) == null);
    try std.testing.expect(table.lookup(0xffffffffa0100101) == null);
    // A sparse row matches only up to its stored limit.
    table.symbols[0].limit = 0xffffffff81000140;
    try std.testing.expect(table.lookup(0xffffffff81000180) == null);
    try std.testing.expectEqualStrings("vfs_read", table.lookup(0xffffffff81000120).?.name);

    const hidden_text = "0000000000000000 t hidden_fn\n0000000000000000 t other\n";
    var hidden = try parse(a, hidden_text);
    defer hidden.deinit();
    try std.testing.expect(hidden.addresses_hidden);
    try std.testing.expect(hidden.lookup(0) == null);
}
