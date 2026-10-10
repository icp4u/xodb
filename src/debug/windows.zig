//! PE unwind adapter. Metadata/code and stack have distinct explicit readers;
//! recorded stacks can supply only captured bytes, without a live fallback.
const std = @import("std");
const c = @import("../c.zig").api;
const loc = @import("location.zig");
const info = @import("info.zig");
const pe = @import("../model/pe_images.zig");
const dwarf = [_]usize{ 0, 2, 1, 3, 7, 6, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15 };

pub const Reader = struct {
    user: *anyopaque,
    read: *const fn (*anyopaque, u64, []u8) anyerror!usize,
};
pub fn executable(image: *const c.struct_xpe_image, rva: u32) bool {
    for (0..c.xpe_info(image).*.section_count) |i| {
        const section = c.xpe_section(image, @intCast(i)).*;
        if (section.characteristics & 0x20000000 != 0 and rva >= section.rva and rva - section.rva < @max(section.virtual_size, section.raw_size)) return true;
    }
    return false;
}
const Adapter = struct {
    image: *const c.struct_xpe_image,
    base: u64,
    stack: Reader,
    loaded: ?Reader,
    failure: ?anyerror = null,
    fn read(self: *Adapter, reader: Reader, at: u64, out: []u8) !void {
        _ = self;
        if (try reader.read(reader.user, at, out) != out.len) return error.WindowsMemoryUnavailable;
    }
    fn metadata(ptr: ?*anyopaque, rva: u32, raw: ?*anyopaque, n: usize) callconv(.c) c_int {
        const self: *Adapter = @ptrCast(@alignCast(ptr.?));
        const out: []u8 = @as([*]u8, @ptrCast(raw.?))[0..n];
        pe.check(c.xpe_read_range(self.image, rva, out.ptr, out.len)) catch |err| {
            self.failure = err;
            return 0;
        };
        // The table and each consulted UNWIND_INFO must still match the
        // stopped image, including anonymous Wine mappings and relocations.
        if (self.loaded) |reader| {
            var actual: [512]u8 = undefined;
            if (n > actual.len) {
                self.failure = error.WindowsUnwindLimit;
                return 0;
            }
            const address = std.math.add(u64, self.base, rva) catch {
                self.failure = error.InvalidAddress;
                return 0;
            };
            self.read(reader, address, actual[0..n]) catch |err| {
                self.failure = err;
                return 0;
            };
            if (!std.mem.eql(u8, actual[0..n], out)) {
                self.failure = error.PeUnwindMetadataChanged;
                return 0;
            }
        }
        return 1;
    }
    fn code(ptr: ?*anyopaque, rva: u32, raw: ?*anyopaque, n: usize) callconv(.c) c_int {
        const self: *Adapter = @ptrCast(@alignCast(ptr.?));
        if (self.loaded) |reader| {
            const address = std.math.add(u64, self.base, rva) catch {
                self.failure = error.InvalidAddress;
                return 0;
            };
            self.read(reader, address, @as([*]u8, @ptrCast(raw.?))[0..n]) catch |err| {
                self.failure = err;
                return 0;
            };
            return 1;
        }
        return metadata(ptr, rva, raw, n);
    }
    /// The table row covering rva, revalidated like the selected row.
    fn functionAt(ptr: ?*anyopaque, rva: u32, out: ?*c.struct_xpu_function) callconv(.c) c_int {
        const self: *Adapter = @ptrCast(@alignCast(ptr.?));
        const found = c.xpe_function_at(self.image, rva) orelse return 0;
        var row: [12]u8 = undefined;
        if (metadata(ptr, found.*.record_rva, &row, row.len) == 0) return -1;
        if (std.mem.readInt(u32, row[0..4], .little) != found.*.begin or std.mem.readInt(u32, row[4..8], .little) != found.*.end or std.mem.readInt(u32, row[8..12], .little) != found.*.unwind) {
            self.failure = error.PeUnwindMetadataChanged;
            return -1;
        }
        out.?.* = .{ .begin = found.*.begin, .end = found.*.end, .unwind = found.*.unwind };
        return 1;
    }
    fn stackRead(ptr: ?*anyopaque, address: u64, raw: ?*anyopaque, n: usize) callconv(.c) c_int {
        const self: *Adapter = @ptrCast(@alignCast(ptr.?));
        self.read(self.stack, address, @as([*]u8, @ptrCast(raw.?))[0..n]) catch |err| {
            self.failure = err;
            return 0;
        };
        return 1;
    }
};
pub fn unwind(image: *const c.struct_xpe_image, base: u64, pc: u64, registers: loc.RegisterSet, stack: Reader, loaded: ?Reader) !info.Unwind {
    if (pc < base or pc - base >= c.xpe_info(image).*.image_size) return error.PeImagePlacementMismatch;
    const rva: u32 = @intCast(pc - base);
    if (!executable(image, rva)) return error.WindowsNonExecutableAddress;
    var adapter = Adapter{ .image = image, .base = base, .stack = stack, .loaded = loaded };
    var function: ?c.struct_xpu_function = null;
    if (c.xpe_function_at(image, rva)) |found| {
        // Revalidate the selected table row as well as its unwind records.
        var row: [12]u8 = undefined;
        if (Adapter.metadata(&adapter, found.*.record_rva, &row, row.len) == 0) return adapter.failure orelse error.WindowsMetadataUnavailable;
        if (std.mem.readInt(u32, row[0..4], .little) != found.*.begin or std.mem.readInt(u32, row[4..8], .little) != found.*.end or std.mem.readInt(u32, row[8..12], .little) != found.*.unwind) return error.PeUnwindMetadataChanged;
        function = .{ .begin = found.*.begin, .end = found.*.end, .unwind = found.*.unwind };
    }
    var context = std.mem.zeroes(c.struct_xpu_context);
    context.rip = pc;
    for (dwarf, 0..) |number, win| if (registers[number]) |value| {
        context.gpr[win] = value;
        context.gpr_known |= @as(u16, 1) << @intCast(win);
    };
    var result: c.struct_xpu_result = undefined;
    const source = c.struct_xpu_source{ .context = &adapter, .image_size = c.xpe_info(image).*.image_size, .metadata = Adapter.metadata, .code = Adapter.code, .stack = Adapter.stackRead, .function = Adapter.functionAt };
    const status = c.xpu_step(&source, if (function) |*f| f else null, rva, &context, &result);
    if (adapter.failure) |err| return err;
    try check(status);
    var caller: loc.RegisterSet = @splat(null);
    for (dwarf, 0..) |number, win| if (result.caller.gpr_known & (@as(u16, 1) << @intCast(win)) != 0) {
        caller[number] = result.caller.gpr[win];
    };
    caller[16] = result.caller.rip;
    return .{ .cfa = result.cfa, .caller = caller, .method = switch (result.method) {
        c.XPU_UNWIND => .windows_unwind,
        c.XPU_LEAF => .windows_leaf,
        c.XPU_EPILOG => .windows_epilog,
        else => return error.WindowsUnwindUnsupported,
    }, .outermost = result.caller.rip == 0 };
}
fn check(status: c.enum_xpu_status) !void {
    return switch (status) {
        c.XPU_OK => {},
        c.XPU_MALFORMED => error.WindowsUnwindMalformed,
        c.XPU_UNSUPPORTED_VERSION => error.WindowsUnwindVersionUnsupported,
        c.XPU_UNSUPPORTED_OPCODE => error.WindowsUnwindOpcodeUnsupported,
        c.XPU_UNSUPPORTED_CHAIN => error.WindowsUnwindChainUnsupported,
        c.XPU_UNSUPPORTED_EPILOG => error.WindowsEpilogUnsupported,
        c.XPU_MACHINE_FRAME => error.WindowsMachineFrameUnsupported,
        c.XPU_METADATA_MISSING => error.WindowsMetadataUnavailable,
        c.XPU_CODE_MISSING => error.WindowsCodeUnavailable,
        c.XPU_STACK_MISSING => error.WindowsStackUnavailable,
        c.XPU_REGISTER_MISSING => error.WindowsRegisterUnavailable,
        c.XPU_LIMIT => error.WindowsUnwindLimit,
        c.XPU_NO_PROGRESS => error.WindowsUnwindNoProgress,
        else => error.WindowsUnwindUnsupported,
    };
}
