//! One read-only look at a Mach-O file that the debugged process has mapped.
//! The file is read through its pinned view within a fixed budget and closed
//! again: nothing is cached, and nothing is bound to the process's modules.
const std = @import("std");
const Session = @import("../model/session.zig").Session;
const runtime_api = @import("../target/runtime.zig");
const rt = runtime_api.c;
const c = @import("../c.zig").api;
const wire = @import("profile.zig");
const V = std.json.Value;
const A = std.mem.Allocator;
pub const definitions = @embedFile("macho_tools.json");
/// A synchronous tool call: well under the reader's own cap.
const read_budget = 64 * 1024 * 1024;
/// A lookup indexes the whole symbol table inside the call, on the session's
/// thread. Above this count `symbol` and `symbol_at` answer `limit`; identity,
/// segments and counts are still reported.
const max_lookup_symbols = 131072;
const max_rows = 256;
const max_dylibs = 64;
const max_objects = 16;

pub fn handles(name: []const u8) bool {
    return std.mem.eql(u8, name, "get_macho_image");
}

fn read(context: ?*anyopaque, offset: u64, out: ?*anyopaque, size: usize) callconv(.c) c.enum_xmo_status {
    const view: *rt.struct_xrt_file_view = @ptrCast(context.?);
    return switch (rt.xrt_file_view_read(view, offset, out, size)) {
        rt.XRT_OK => c.XMO_OK,
        rt.XRT_FILE_CHANGED => c.XMO_CHANGED,
        rt.XRT_FILE_LIMIT, rt.XRT_DISCOVERY_BUDGET => c.XMO_LIMIT,
        rt.XRT_DISCOVERY_CANCELLED => c.XMO_CANCELLED,
        rt.XRT_OUT_OF_MEMORY => c.XMO_NOMEM,
        else => c.XMO_IO,
    };
}
fn check(status: c.enum_xmo_status) !void {
    return switch (status) {
        c.XMO_OK => {},
        c.XMO_NOT_MACHO => error.NotMachO,
        c.XMO_UNSUPPORTED => error.MachOUnsupported,
        c.XMO_MALFORMED => error.MachOMalformed,
        c.XMO_LIMIT => error.MachOLimit,
        c.XMO_CHANGED => error.MachOFileChanged,
        c.XMO_CANCELLED => error.MachOCancelled,
        c.XMO_NOMEM => error.OutOfMemory,
        c.XMO_NOT_FOUND => error.MachOArchitectureNotFound,
        c.XMO_UNAVAILABLE => error.MachOUnavailable,
        else => error.MachOReadFailed,
    };
}
fn statusName(status: c.enum_xmo_status) []const u8 {
    return std.mem.span(c.xmo_status_name(status));
}
fn hex(a: A, value: u64) ![]const u8 {
    return std.fmt.allocPrint(a, "0x{x}", .{value});
}
fn hexArgument(args: V, key: []const u8) !?u64 {
    const v = args.object.get(key) orelse return null;
    if (v != .string) return error.InvalidArguments;
    const digits = if (std.mem.startsWith(u8, v.string, "0x")) v.string[2..] else v.string;
    return std.fmt.parseInt(u64, digits, 16) catch error.InvalidArguments;
}
/// Bytes from the file are not text until checked.
fn text(a: A, bytes: []const u8) ![]const u8 {
    return a.dupe(u8, if (std.unicode.utf8ValidateSlice(bytes)) bytes else "unavailable: non-UTF-8 bytes");
}
fn fixed(a: A, bytes: []const u8) ![]const u8 {
    return text(a, std.mem.sliceTo(bytes, 0));
}
fn protection(a: A, bits: u32) ![]const u8 {
    return a.dupe(u8, &.{ if (bits & 1 != 0) 'r' else '-', if (bits & 2 != 0) 'w' else '-', if (bits & 4 != 0) 'x' else '-' });
}
fn version(a: A, packed_version: u32) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ packed_version >> 16, (packed_version >> 8) & 0xff, packed_version & 0xff });
}
fn architecture(a: A, cputype: u32, cpusubtype: u32) ![]const u8 {
    const subtype = cpusubtype & c.XMO_CPU_SUBTYPE_MASK;
    if (cputype == c.XMO_CPU_ARM64) return a.dupe(u8, if (subtype == c.XMO_CPU_SUBTYPE_ARM64E) "arm64e" else "arm64");
    if (cputype == c.XMO_CPU_X86_64) return a.dupe(u8, "x86_64");
    return std.fmt.allocPrint(a, "cputype 0x{x}", .{cputype});
}
fn fileType(value: u32) []const u8 {
    return switch (value) {
        c.XMO_MH_OBJECT => "object",
        c.XMO_MH_EXECUTE => "execute",
        c.XMO_MH_DYLIB => "dylib",
        c.XMO_MH_DYLINKER => "dylinker",
        c.XMO_MH_BUNDLE => "bundle",
        c.XMO_MH_DSYM => "dsym",
        else => "other",
    };
}
fn platform(value: u32) ?[]const u8 {
    const names = [_][]const u8{ "macos", "ios", "tvos", "watchos", "bridgeos", "maccatalyst", "iossimulator", "tvossimulator", "watchossimulator", "driverkit", "visionos", "visionossimulator" };
    return if (value == 0) null else if (value <= names.len) names[value - 1] else "other";
}

const Symbol = struct {
    status: []const u8,
    name: ?[]const u8 = null,
    address: ?[]const u8 = null,
    size: ?[]const u8 = null,
    defined: ?bool = null,
    external: ?bool = null,
    segment: ?[]const u8 = null,
    section: ?[]const u8 = null,
};
fn symbol(a: A, image: *c.struct_xmo_image, status: c.enum_xmo_status, found: ?*const c.struct_xmo_symbol, size: ?u64) !Symbol {
    if (status == c.XMO_CHANGED) return error.MachOFileChanged;
    const s = found orelse return .{ .status = statusName(status) };
    var name: [c.XMO_MAX_NAME + 1]u8 = undefined;
    const named = c.xmo_string(image, s.strx, &name, name.len);
    const flags = c.xmo_symbol_flags(s);
    const stored = if (flags & c.XMO_SYMBOL_DEFINED != 0 and s.sect != 0) c.xmo_section(image, s.sect - 1) else null;
    const owner: ?c.struct_xmo_section = if (stored != null) stored.* else null;
    return .{
        .status = statusName(status),
        .name = if (named == c.XMO_OK) try fixed(a, &name) else null,
        .address = if (flags & c.XMO_SYMBOL_DEFINED != 0) try hex(a, s.value) else null,
        .size = if (size) |n| try hex(a, n) else null,
        .defined = flags & c.XMO_SYMBOL_DEFINED != 0,
        .external = flags & c.XMO_SYMBOL_EXTERNAL != 0,
        .segment = if (owner) |o| try fixed(a, &o.segment) else null,
        .section = if (owner) |o| try fixed(a, &o.name) else null,
    };
}

pub fn call(a: A, session: *Session, args: V) !V {
    try wire.fields(args, &.{ "address", "arch", "symbol", "symbol_address", "sections" });
    if (session.offline) return error.OfflineSession;
    const address = try hexArgument(args, "address") orelse return error.InvalidArguments;
    if (session.target.gdbRemoteInfo()) |gdb| if (gdb.os == .darwin) {
        // The stub's address map and UUID-matched local symbols are available
        // without opening a remote pathname or claiming local debug info.
        for ([_][]const u8{ "arch", "symbol", "symbol_address", "sections" }) |field| if (args.object.contains(field)) return error.MachORemoteLabelOptions;
        try session.gdb_map.refreshImages(&session.target);
        const label = try session.gdb_map.label(a, address, address, session.debug_files.roots.items) orelse return error.MachOAddressUnavailable;
        return wire.value(a, .{
            .source = "gdb_remote_images",
            .address = try hex(a, address),
            .module_id = label.module,
            .label = label.name,
            .diagnostic = label.diagnostic,
            .status = if (label.diagnostic) |reason| (if (std.mem.eql(u8, reason, "MachOSymbolsPending")) "pending" else "image_only") else "ready",
        });
    };
    var options: c.struct_xmo_options = std.mem.zeroes(c.struct_xmo_options);
    options.max_read_bytes = read_budget;
    if (args.object.get("arch")) |v| {
        if (v != .string) return error.InvalidArguments;
        options.cputype = if (std.mem.eql(u8, v.string, "arm64")) c.XMO_CPU_ARM64 else if (std.mem.eql(u8, v.string, "x86_64")) c.XMO_CPU_X86_64 else return error.InvalidArguments;
    }
    const wanted: ?[:0]const u8 = if (args.object.get("symbol")) |v| blk: {
        if (v != .string or v.string.len == 0 or v.string.len > c.XMO_MAX_NAME or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidArguments;
        break :blk try a.dupeZ(u8, v.string);
    } else null;
    const wanted_address = try hexArgument(args, "symbol_address");
    const with_sections = if (args.object.get("sections")) |v| (if (v == .bool) v.bool else return error.InvalidArguments) else false;

    try session.refreshMaps();
    const file = try session.modules.machoFileView(address);
    defer _ = rt.xrt_file_view_close(file.view);
    const identity = rt.xrt_file_view_identity(file.view).*;
    var source = c.struct_xmo_source{ .context = file.view, .size = @intCast(@max(identity.size, 0)), .layout = c.XMO_FILE, .read = read };
    var loaded: ?*c.struct_xmo_image = null;
    try check(c.xmo_load(&source, &options, &loaded));
    const image = loaded.?;
    defer c.xmo_destroy(image);
    const info = c.xmo_info(image);

    const Slice = struct { arch: []const u8, cputype: u32, cpusubtype: []const u8, offset: []const u8, size: []const u8, selected: bool };
    const slices = try a.alloc(Slice, info.*.fat_count);
    for (slices, 0..) |*row, i| {
        const arch = c.xmo_fat_arch(image, @intCast(i)).*;
        row.* = .{ .arch = try architecture(a, arch.cputype, arch.cpusubtype), .cputype = arch.cputype, .cpusubtype = try hex(a, arch.cpusubtype), .offset = try hex(a, arch.offset), .size = try hex(a, arch.size), .selected = arch.offset == info.*.slice_offset };
    }
    const Segment = struct { name: []const u8, vmaddr: []const u8, vmsize: []const u8, fileoff: []const u8, filesize: []const u8, maxprot: []const u8, initprot: []const u8, sections: u32 };
    const segments = try a.alloc(Segment, @min(info.*.segment_count, max_rows));
    for (segments, 0..) |*row, i| {
        const s = c.xmo_segment(image, @intCast(i)).*;
        row.* = .{ .name = try fixed(a, &s.name), .vmaddr = try hex(a, s.vmaddr), .vmsize = try hex(a, s.vmsize), .fileoff = try hex(a, s.fileoff), .filesize = try hex(a, s.filesize), .maxprot = try protection(a, s.maxprot), .initprot = try protection(a, s.initprot), .sections = s.section_count };
    }
    const Section = struct { segment: []const u8, name: []const u8, address: []const u8, size: []const u8, bytes: []const u8 };
    const sections = try a.alloc(Section, if (with_sections) @min(info.*.section_count, max_rows) else 0);
    for (sections, 0..) |*row, i| {
        const stored = c.xmo_section(image, @intCast(i));
        const s = stored.*;
        var range: c.struct_xmo_range = undefined;
        row.* = .{ .segment = try fixed(a, &s.segment), .name = try fixed(a, &s.name), .address = try hex(a, s.address), .size = try hex(a, s.size), .bytes = statusName(c.xmo_section_range(image, stored, &range)) };
    }
    const Library = struct { kind: []const u8, name: []const u8 };
    const kinds = [_][]const u8{ "id", "load", "weak", "reexport", "lazy", "upward" };
    const libraries = try a.alloc(Library, @min(info.*.dylib_count, max_dylibs));
    for (libraries, 0..) |*row, i| {
        const d = c.xmo_dylib(image, @intCast(i)).*;
        row.* = .{ .kind = kinds[@min(d.kind, kinds.len - 1)], .name = try text(a, std.mem.span(d.name)) };
    }

    var symbol_count: u32 = 0;
    const symbols_status = c.xmo_symbols(image, &symbol_count);
    var start_count: u32 = 0;
    const starts_status = c.xmo_function_starts(image, null, &start_count);
    var map: c.struct_xmo_debug_map = undefined;
    const map_status = c.xmo_debug_map(image, &map);
    const Object = struct { path: ?[]const u8, mtime: u64, source: ?[]const u8, functions: u32 };
    const objects = try a.alloc(Object, if (map_status == c.XMO_OK) @min(map.object_count, max_objects) else 0);
    var name: [c.XMO_MAX_NAME + 1]u8 = undefined;
    for (objects, 0..) |*row, i| {
        const o = map.objects[i];
        const path = if (c.xmo_string(image, o.path, &name, name.len) == c.XMO_OK) try fixed(a, &name) else null;
        const from = if (c.xmo_string(image, o.source_name, &name, name.len) == c.XMO_OK) try fixed(a, &name) else null;
        row.* = .{ .path = path, .mtime = o.mtime & 0xffffffff, .source = from, .functions = o.function_count };
    }
    var by_name: ?Symbol = null;
    if (wanted) |text_name| {
        var found: ?*const c.struct_xmo_symbol = null;
        by_name = if (symbol_count > max_lookup_symbols) .{ .status = statusName(c.XMO_LIMIT) } else try symbol(a, image, c.xmo_symbol_find(image, text_name.ptr, &found), found, null);
    }
    var by_address: ?Symbol = null;
    if (wanted_address) |link_address| {
        var found: ?*const c.struct_xmo_symbol = null;
        var size: u64 = 0;
        const status: c.enum_xmo_status = if (symbol_count > max_lookup_symbols) c.XMO_LIMIT else c.xmo_symbol_at(image, link_address, &found, &size);
        by_address = try symbol(a, image, status, found, if (status == c.XMO_OK) size else null);
    }
    var not_read: std.ArrayList([]const u8) = .empty;
    if (info.*.has_exports_trie != 0) try not_read.append(a, "exports_trie");
    if (info.*.fixups == c.XMO_FIXUPS_CHAINED) try not_read.append(a, "chained_fixups");
    if (c.xmo_find_section(image, "__TEXT", "__unwind_info") != null) try not_read.append(a, "compact_unwind");
    if (c.xmo_find_section(image, "__TEXT", "__eh_frame") != null or c.xmo_find_section(image, "__DWARF", "__debug_info") != null) try not_read.append(a, "dwarf");

    var uuid: ?[]const u8 = null;
    if (info.*.has_uuid != 0) {
        const u = info.*.uuid;
        uuid = try std.fmt.allocPrint(a, "{X:0>2}{X:0>2}{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}-{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}{X:0>2}", .{ u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15] });
    }
    const reads = .{ .source_bytes = info.*.source_bytes, .source_reads = info.*.source_reads, .retained_bytes = info.*.retained_bytes, .budget_bytes = @as(u64, read_budget) };
    // What was read is published only if the file is still the one opened.
    try runtime_api.check(rt.xrt_file_view_validate(file.view));
    return wire.value(a, .{
        .path = try text(a, file.path),
        .file_size = @as(u64, @intCast(@max(identity.size, 0))),
        .container = if (info.*.fat_count == 0) "thin" else if (info.*.fat_64 != 0) "fat64" else "fat",
        .slices = slices,
        .arch = try architecture(a, info.*.cputype, info.*.cpusubtype),
        .cputype = info.*.cputype,
        .cpusubtype = try hex(a, info.*.cpusubtype),
        .file_type = fileType(info.*.filetype),
        .flags = try hex(a, info.*.flags),
        .pie = info.*.flags & c.XMO_MH_PIE != 0,
        .in_shared_cache = info.*.flags & c.XMO_MH_DYLIB_IN_CACHE != 0,
        .uuid = uuid,
        .platform = platform(info.*.platform),
        .minimum_os = if (info.*.platform != 0) try version(a, info.*.min_os) else null,
        .sdk = if (info.*.platform != 0) try version(a, info.*.sdk) else null,
        .entry = .{ .kind = switch (info.*.entry) {
            c.XMO_ENTRY_MAIN => "main",
            c.XMO_ENTRY_UNIXTHREAD => "unixthread",
            else => "none",
        }, .address = if (info.*.entry != c.XMO_ENTRY_NONE) try hex(a, info.*.entry_address) else null },
        .header_address = if (info.*.has_text != 0) try hex(a, info.*.text_vmaddr) else null,
        .segments = segments,
        .total_segments = info.*.segment_count,
        .sections = if (with_sections) sections else null,
        .total_sections = info.*.section_count,
        .libraries = libraries,
        .total_libraries = info.*.dylib_count,
        .symbols = .{ .status = statusName(symbols_status), .count = symbol_count },
        .function_starts = .{ .status = statusName(starts_status), .count = start_count },
        .debug_map = .{ .status = statusName(map_status), .objects = objects, .total_objects = if (map_status == c.XMO_OK) map.object_count else 0, .total_functions = if (map_status == c.XMO_OK) map.function_count else 0 },
        .code_signature = info.*.has_code_signature != 0,
        .encrypted = info.*.encrypted != 0,
        .fixups = switch (info.*.fixups) {
            c.XMO_FIXUPS_DYLD_INFO => "dyld_info",
            c.XMO_FIXUPS_CHAINED => "chained",
            else => "none",
        },
        .not_read = not_read.items,
        .symbol = by_name,
        .symbol_at = by_address,
        .reads = reads,
    });
}
