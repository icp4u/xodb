//! Prints src/binary/elf.zig's view of one file as JSON, for compare.py.
//!
//! elfdump FILE [--probes N] [--mapping START OFFSET] [--bench ROUNDS]
//!
//! --probes limits lookup probes to about N symbols per table (default: all).
//! --mapping reports the load bias for the file's lowest mapping (hex values).
//! --bench times ROUNDS name and address lookups and reports nanoseconds each.

const std = @import("std");
const elf = @import("elf");

fn string(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |b| switch (b) {
        '"', '\\' => try w.print("\\{c}", .{b}),
        0...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{b}),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

fn hit(w: *std.Io.Writer, found: ?elf.Symbol, offset: u64) !void {
    const s = found orelse return w.writeAll("null");
    try w.print("{{\"table\":\"{s}\",\"index\":{d},\"offset\":{d}}}", .{ @tagName(s.table), s.index, offset });
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    var path: ?[]const u8 = null;
    var probes: u32 = std.math.maxInt(u32);
    var mapping: ?[2]u64 = null;
    var bench: u32 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--probes") and i + 1 < args.len) {
            probes = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--bench") and i + 1 < args.len) {
            bench = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--mapping") and i + 2 < args.len) {
            mapping = .{ try std.fmt.parseInt(u64, args[i + 1], 16), try std.fmt.parseInt(u64, args[i + 2], 16) };
            i += 2;
        } else if (path == null) path = args[i] else return error.BadUsage;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path orelse return error.BadUsage, a, .unlimited);
    var buffer: [1 << 16]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    const w = &out.interface;
    defer w.flush() catch {};

    const image = elf.Image.parse(bytes) catch |err| return w.print("{{\"error\":\"{s}\"}}\n", .{@errorName(err)});
    const h = image.header;
    try w.print("{{\"header\":{{\"type\":\"{s}\",\"machine\":{d},\"os_abi\":{d},\"abi_version\":{d},\"entry\":{d},\"flags\":{d},\"segment_table_offset\":{d},\"segment_count\":{d},\"section_table_offset\":{d},\"section_count\":{d},\"section_name_index\":{d}}}", .{ @tagName(h.type), @intFromEnum(h.machine), h.os_abi, h.abi_version, h.entry, h.flags, h.segment_table_offset, h.segment_count, h.section_table_offset, h.section_count, h.section_name_index });

    try w.writeAll(",\n\"segments\":[");
    var n: u32 = 0;
    while (n < h.segment_count) : (n += 1) {
        const s = try image.segment(n);
        if (n != 0) try w.writeAll(",\n");
        try w.print("{{\"type\":{d},\"flags\":{d},\"offset\":{d},\"vaddr\":{d},\"paddr\":{d},\"file_size\":{d},\"mem_size\":{d},\"alignment\":{d}}}", .{ @intFromEnum(s.type), s.flags, s.offset, s.vaddr, s.paddr, s.file_size, s.mem_size, s.alignment });
    }

    try w.writeAll("],\n\"sections\":[");
    n = 0;
    while (n < h.section_count) : (n += 1) {
        const s = try image.section(n);
        if (n != 0) try w.writeAll(",\n");
        try w.writeAll("{\"name\":");
        try string(w, s.name);
        try w.print(",\"type\":{d},\"flags\":{d},\"addr\":{d},\"offset\":{d},\"size\":{d},\"link\":{d},\"info\":{d},\"alignment\":{d},\"entry_size\":{d}}}", .{ @intFromEnum(s.type), s.flags, s.addr, s.offset, s.size, s.link, s.info, s.alignment, s.entry_size });
    }
    try w.writeAll("]");

    for ([_]elf.SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
        try w.print(",\n\"{s}\":", .{@tagName(kind)});
        const table = (try image.symbols(kind)) orelse {
            try w.writeAll("null");
            continue;
        };
        try w.writeAll("[");
        n = 0;
        while (n < table.count()) : (n += 1) {
            const s = try table.get(n);
            if (n != 0) try w.writeAll(",\n");
            try w.writeAll("{\"name\":");
            try string(w, s.name);
            try w.print(",\"value\":{d},\"size\":{d},\"bind\":{d},\"type\":{d},\"visibility\":{d},\"has_address\":{},\"placement\":", .{ s.value, s.size, @intFromEnum(s.bind), @intFromEnum(s.type), @intFromEnum(s.visibility), s.hasAddress() });
            switch (s.placement) {
                .section => |index| try w.print("{d}}}", .{index}),
                .reserved => |raw| try w.print("\"reserved:{d}\"}}", .{raw}),
                else => try w.print("\"{s}\"}}", .{@tagName(s.placement)}),
            }
        }
        try w.writeAll("]");
    }

    // Lookup probes: each chosen symbol's name, and addresses at, inside,
    // at the end of, and just past it.
    try w.writeAll(",\n\"by_name\":[");
    var first = true;
    for ([_]elf.SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
        const table = (try image.symbols(kind)) orelse continue;
        const step = @max(1, table.count() / @max(1, probes));
        n = 1;
        while (n < table.count()) : (n += step) {
            const s = try table.get(n);
            if (!first) try w.writeAll(",\n");
            first = false;
            try w.writeAll("{\"name\":");
            try string(w, s.name);
            try w.writeAll(",\"hit\":");
            try hit(w, image.findSymbol(s.name), 0);
            try w.writeAll("}");
        }
    }
    try w.writeAll("],\n\"by_address\":[");
    first = true;
    for ([_]elf.SymbolTable.Kind{ .symtab, .dynsym }) |kind| {
        const table = (try image.symbols(kind)) orelse continue;
        const step = @max(1, table.count() / @max(1, probes));
        n = 1;
        while (n < table.count()) : (n += step) {
            const s = try table.get(n);
            for ([_]u64{ s.value, s.value +% s.size / 2, s.value +% s.size -% 1, s.value +% s.size, s.value +% 1 }) |address| {
                if (!first) try w.writeAll(",\n");
                first = false;
                try w.print("{{\"address\":{d},\"hit\":", .{address});
                const found = image.symbolAt(address);
                try hit(w, if (found) |f| f.symbol else null, if (found) |f| f.offset else 0);
                try w.writeAll("}");
            }
        }
    }
    try w.writeAll("]");

    if (mapping) |m| {
        try w.writeAll(",\n\"load_bias\":");
        if (image.loadBias(m[0], m[1])) |bias| try w.print("{d}", .{bias}) else |err| try w.print("\"{s}\"", .{@errorName(err)});
    }

    if (bench != 0) {
        const table = (try image.symbols(.symtab)) orelse (try image.symbols(.dynsym)) orelse return error.NoSymbols;
        var prng = std.Random.DefaultPrng.init(1);
        const random = prng.random();
        var sink: u64 = 0;
        const t0 = std.Io.Timestamp.now(init.io, .awake);
        for (0..bench) |_| {
            const s = try table.get(random.uintLessThan(u32, table.count()));
            if (image.findSymbol(s.name)) |f| sink +%= f.value;
        }
        const t1 = std.Io.Timestamp.now(init.io, .awake);
        for (0..bench) |_| {
            const s = try table.get(random.uintLessThan(u32, table.count()));
            if (image.symbolAt(s.value)) |f| sink +%= f.offset;
        }
        const t2 = std.Io.Timestamp.now(init.io, .awake);
        try w.print(",\n\"bench\":{{\"symbols\":{d},\"rounds\":{d},\"find_symbol_ns\":{d},\"symbol_at_ns\":{d},\"sink\":{d}}}", .{ table.count(), bench, @divTrunc(t0.durationTo(t1).nanoseconds, bench), @divTrunc(t1.durationTo(t2).nanoseconds, bench), sink });
    }
    try w.writeAll("}\n");
}
