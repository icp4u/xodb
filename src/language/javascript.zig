//! Stopped V8 reads. C owns layout interpretation; this adapter verifies the
//! loaded image, supplies the bounded reader, and copies owned UI/MCP values.
const std = @import("std");
const c = @import("../c.zig").api;
const model = @import("../model/session.zig");
const eval = @import("../model/evaluate.zig");
const view = @import("../model/value_view.zig");
const A = std.mem.Allocator;

fn read(ctx: ?*anyopaque, address: u64, out: ?*anyopaque, n: usize) callconv(.c) c_int {
    const session: *model.Session = @ptrCast(@alignCast(ctx.?));
    const bytes: [*]u8 = @ptrCast(out.?);
    return if ((session.target.readMemory(address, bytes[0..n]) catch return -1) == n) 0 else -1;
}
fn reader(session: *model.Session) c.struct_xjs_reader {
    return .{ .context = session, .read = read, .reads = 0, .bytes = 0, .@"error" = null, .version_table = 0 };
}
fn memory(r: *c.struct_xjs_reader, address: u64, out: []u8) !void {
    if (c.xjs_read_memory(r, address, out.ptr, out.len) == 0) return error.JavaScriptMemoryUnavailable;
}
fn text(a: A, bytes: []const u8) ![]const u8 {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.JavaScriptInvalidUtf8;
    return a.dupe(u8, bytes);
}
fn reason(a: A, ptr: [*c]const u8) !?[]const u8 {
    return if (ptr == null) null else try a.dupe(u8, std.mem.span(ptr));
}
fn buildId(a: A, l: *const c.struct_xjs_layout) ![]const u8 {
    const out = try a.alloc(u8, @as(usize, l.build_id_len) * 2);
    const digits = "0123456789abcdef";
    for (l.build_id[0..l.build_id_len], 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}
pub fn preview(session: *model.Session, a: A, value: eval.Value) !?view.Preview {
    if (value.availability != .available or value.type.javascript_handle == 0) return null;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    var r = reader(session);
    const layout = try session.metadata.javascript(session);
    const word_value = try eval.subvalue(value, &eval.uint_type, 0);
    var stored: [8]u8 = undefined;
    if (word_value.data) |data| {
        if (data.len < 8) return error.PartialValue;
        if (word_value.valid) |valid| {
            if (valid.len < 8) return error.PartialValue;
            for (valid[0..8]) |mask| if (mask != 255) return error.PartialValue;
        }
        @memcpy(&stored, data[0..8]);
    } else if (word_value.address) |address| {
        try memory(&r, address, &stored);
    } else return error.JavaScriptHandleUnavailable;
    var tagged = std.mem.readInt(u64, &stored, .little);
    if (value.type.javascript_handle == 2) {
        if (tagged == 0) return error.JavaScriptEmptyHandle;
        var bytes: [8]u8 = undefined;
        try memory(&r, tagged, &bytes);
        tagged = std.mem.readInt(u64, &bytes, .little);
    }
    const raw = try a.create(c.struct_xjs_value);
    c.xjs_value_read(&layout, &r, tagged, raw);
    const items = try a.alloc(view.JavaScriptItem, raw.item_count);
    for (raw.items[0..raw.item_count], items) |item, *out| out.* = .{
        .tagged = item.tagged,
        .key = try text(a, std.mem.sliceTo(&item.key, 0)),
        .type = try text(a, std.mem.sliceTo(&item.type, 0)),
        .display = try text(a, std.mem.sliceTo(&item.display, 0)),
        .diagnostic = try reason(a, item.reason),
        .truncated = item.truncated != 0,
        .extent_advisory = item.extent_advisory != 0,
        .name_diagnostic = try reason(a, item.name_reason),
    };
    try session.target.expectGeneration(generation);
    return .{
        .presentation = .scalar,
        .data_address = tagged,
        .count = raw.count,
        .element_type = value.type.name,
        .truncated = raw.truncated != 0,
        .extent_advisory = raw.extent_advisory != 0,
        .diagnostic = try reason(a, raw.reason),
        .basis = "V8 postmortem metadata verified against the loaded image and build-id; stopped memory; no inferior calls or getters; allocation extent and GC liveness not verified",
        .javascript = .{
            .name_diagnostic = try reason(a, raw.name_reason),
            .type = try text(a, std.mem.sliceTo(&raw.type, 0)),
            .display = try text(a, std.mem.sliceTo(&raw.display, 0)),
            .tagged = tagged,
            .map = raw.map,
            .instance_type = raw.instance_type,
            .runtime_version = try text(a, std.mem.sliceTo(&layout.version_string, 0)),
            .runtime_build_id = try buildId(a, &layout),
            .layout_source = if (raw.version_table == 0) "postmortem-metadata" else if (layout.dwarf_fields != 0) "version-table+partial-dwarf-crosscheck" else "version-table",
            .dwarf_fields = layout.dwarf_fields,
            .memory_reads = r.reads,
            .memory_bytes = r.bytes,
            .items = items,
        },
    };
}

pub const Frame = struct {
    name: []const u8,
    file: ?[]const u8,
    line: ?i32,
    column: ?i32,
    kind: []const u8,
    provenance: []const u8 = "external_read",
    frame_pointer: u64,
    pc: u64,
    function: u64,
    code: u64,
    reason: ?[]const u8,
};
pub const Segment = struct {
    runtime: struct { language: []const u8 = "javascript", implementation: []const u8 = "v8", version: []const u8, build_id: []const u8 },
    anchor: ?struct { frame: usize, pc: u64, symbol: ?[]const u8 },
    source_kind: []const u8 = "stopped_snapshot",
    state: []const u8,
    reason: ?[]const u8,
    layout_source: []const u8,
    dwarf_fields: u64,
    frames: []Frame,
    memory_reads: usize,
    memory_bytes: usize,
};
pub const Stack = struct {
    session_id: u64,
    generation: u64,
    tid: i32,
    segments: []Segment,
    native_stack_incomplete: bool,
    basis: []const u8 = "verified V8 image and metadata, native-unwind API-exit anchor, bounded stopped reads; physical frames only, no inferred async or inlined frames",
};
pub fn stack(session: *model.Session, a: A, tid: i32, first: usize) !Stack {
    if (first >= 64) return error.InvalidFrame;
    if (session.target.snapshot().state != .stopped) return error.NotStopped;
    const generation = session.target.snapshot().generation;
    // Pending metadata must not enqueue a foreground unwind ahead of the worker.
    const layout = try session.metadata.javascript(session);
    const native = try session.stack(a, tid, 64);
    if (first >= native.len) return error.InvalidFrame;
    var r = reader(session);
    const segments = try a.alloc(Segment, 1);
    segments[0] = .{
        .runtime = .{ .version = try text(a, std.mem.sliceTo(&layout.version_string, 0)), .build_id = try buildId(a, &layout) },
        .anchor = null,
        .state = "partial",
        .reason = "JavaScriptNativeAnchorUnavailable",
        .layout_source = "postmortem-metadata",
        .dwarf_fields = layout.dwarf_fields,
        .frames = &.{},
        .memory_reads = 0,
        .memory_bytes = 0,
    };
    for (native[first..]) |frame| {
        const fp = frame.registers[6] orelse continue;
        const root = frame.registers[13] orelse continue;
        const region = for (session.modules.regions.items) |region| {
            if (region.permissions[0] == 'r' and region.permissions[1] == 'w' and
                fp >= region.start and fp - region.start >= 48 and fp < region.end and region.end - fp >= 16) break region;
        } else continue;
        var marker: [8]u8 = undefined;
        memory(&r, fp - 8, &marker) catch break;
        if (layout.present[c.XJS_FRAME_API_EXIT] == 0 or layout.fields[c.XJS_FRAME_API_EXIT] < 0 or
            std.mem.readInt(u64, &marker, .little) != @as(u64, @intCast(layout.fields[c.XJS_FRAME_API_EXIT])) * 2) continue;
        const raw = try a.create(c.struct_xjs_stack);
        c.xjs_stack_read(&layout, &r, fp, frame.pc, root, region.start, region.end, raw);
        const frames = try a.alloc(Frame, raw.count);
        for (raw.frames[0..raw.count], frames) |f, *out| out.* = .{
            .name = try text(a, std.mem.sliceTo(&f.name, 0)),
            .file = if (f.file[0] != 0) try text(a, std.mem.sliceTo(&f.file, 0)) else null,
            .line = if (f.line > 0) f.line else null,
            .column = if (f.column > 0) f.column else null,
            .kind = try text(a, std.mem.sliceTo(&f.kind, 0)),
            .frame_pointer = f.fp,
            .pc = f.pc,
            .function = f.function,
            .code = f.code,
            .reason = try reason(a, f.reason),
        };
        segments[0].anchor = .{ .frame = frame.index, .pc = frame.pc, .symbol = if (frame.symbol) |s| try a.dupe(u8, s) else null };
        segments[0].frames = frames;
        segments[0].state = if (raw.reason == null) "complete" else "partial";
        segments[0].reason = try reason(a, raw.reason);
        segments[0].layout_source = if (raw.version_table == 0) "postmortem-metadata" else if (layout.dwarf_fields != 0) "version-table+partial-dwarf-crosscheck" else "version-table";
        break;
    }
    segments[0].memory_reads = r.reads;
    segments[0].memory_bytes = r.bytes;
    if (r.@"error" != null) segments[0].reason = try reason(a, r.@"error");
    try session.target.expectGeneration(generation);
    return .{ .session_id = session.id, .generation = generation, .tid = tid, .segments = segments, .native_stack_incomplete = native.len == 64 or native[native.len - 1].diagnostic != null };
}

/// Runtime identity and proof from the existing stopped-memory reader.
pub fn describe(session: *model.Session, a: A) !@import("../model/language_tabs.zig").Description {
    const layout = try session.metadata.javascript(session);
    return .{ .version = try text(a, std.mem.sliceTo(&layout.version_string, 0)), .build_id = try buildId(a, &layout), .basis = if (layout.dwarf_fields != 0) "postmortem metadata + partial DWARF" else "postmortem metadata" };
}
