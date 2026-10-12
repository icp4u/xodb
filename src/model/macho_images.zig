//! Bounded local Mach-O symbol workers. Remote names never become host paths.
const std = @import("std");
const c = @import("../c.zig").api;
const rt = @import("../target/runtime.zig").c;
const budget = @import("../binary/snapshot.zig");
const dwarf = @import("../debug/info.zig");
const elf = @import("../binary/elf.zig");
const a = std.heap.page_allocator;
const max_entries = 32;
const byte_limit = 256 * 1024 * 1024;
const overhead = 128 * 1024; // worker, parser object and copied option strings
const Entry = struct {
    uuid: [16]u8,
    cpu: u32,
    subtype: u32,
    filetype: u32,
    basename: []const u8,
    job: ?*c.struct_xmo_job = null,
    failure: ?[]const u8 = null,
    charged: usize = 0,
    used: u64 = 0,
    debug: ?dwarf.Image = null,
    debug_error: ?anyerror = null,
    objects: [c.XMO_MAX_DEBUG_OBJECTS]?*dwarf.Image = @splat(null),
    cfi: ?dwarf.Cfi = null,
    cfi_checked: bool = false,
    object_errors: [c.XMO_MAX_DEBUG_OBJECTS]?anyerror = @splat(null),
};
fn objectImage(e: *Entry, index_: u32, container: *const c.struct_xmo_dwarf) !*dwarf.Image {
    const index: usize = @intCast(index_);
    if (index >= e.objects.len) return error.MachOObjectMalformed;
    if (e.object_errors[index]) |err| return err;
    if (e.objects[index] == null) {
        const bytes = container.*.bytes[0..container.*.size];
        const binary = elf.Image.parse(bytes) catch |err| {
            e.object_errors[index] = err;
            return err;
        };
        const debug = try a.create(dwarf.Image);
        errdefer a.destroy(debug);
        debug.* = dwarf.Image.init(binary, bytes) catch |err| {
            e.object_errors[index] = err;
            return err;
        };
        e.objects[index] = debug;
    }
    return e.objects[index].?;
}
fn primaryImage(e: *Entry, container: *const c.struct_xmo_dwarf) !*dwarf.Image {
    if (e.debug_error) |err| return err;
    if (e.debug == null) {
        const bytes = container.*.bytes[0..container.*.size];
        const binary = elf.Image.parse(bytes) catch |err| {
            e.debug_error = err;
            return err;
        };
        e.debug = dwarf.Image.init(binary, bytes) catch |err| {
            e.debug_error = err;
            return err;
        };
    }
    return &e.debug.?;
}
pub const State = struct {
    entries: std.ArrayList(*Entry) = .empty,
    pending: ?*Entry = null,
    held: usize = 0,
    clock: u64 = 0,
    executable: ?[:0]const u8 = null,

    pub fn deinit(self: *State) void {
        for (self.entries.items) |e| self.destroy(e);
        self.entries.deinit(a);
        self.* = .{};
    }
    fn destroy(self: *State, e: *Entry) void {
        if (e.debug) |*debug| debug.deinit();
        if (e.cfi) |*cfi| cfi.deinit();
        for (e.objects) |object| if (object) |debug| {
            debug.deinit();
            a.destroy(debug);
        };
        if (e.job) |job| c.xmo_job_destroy(job);
        budget.release(e.charged);
        self.held -= e.charged;
        a.free(e.basename);
        a.destroy(e);
    }
    fn matches(e: *const Entry, image: *const rt.struct_xrt_gdb_image) bool {
        return image.has_uuid and std.mem.eql(u8, &e.uuid, &image.uuid) and e.cpu == image.cputype and e.subtype == image.cpusubtype and e.filetype == image.filetype and std.mem.eql(u8, e.basename, std.fs.path.basename(std.mem.sliceTo(&image.path, 0)));
    }
    fn find(self: *const State, image: *const rt.struct_xrt_gdb_image) ?*Entry {
        for (self.entries.items) |e| if (matches(e, image)) return e;
        return null;
    }
    pub fn status(self: *const State, image: *const rt.struct_xrt_gdb_image) ?[]const u8 {
        const e = self.find(image) orelse return "MachOLocalFileUnavailable";
        return if (self.pending == e) "MachOSymbolsPending" else e.failure;
    }
    pub fn poll(self: *State) bool {
        const e = self.pending orelse return false;
        const job = e.job.?;
        const joined = c.xmo_job_join(job);
        if (joined == 0) return false;
        self.pending = null;
        var progress: c.struct_xmo_job_snapshot = undefined;
        c.xmo_job_poll(job, &progress);
        if (joined < 0 or progress.state != c.XMO_JOB_READY) {
            e.failure = if (joined < 0) "MachOWorkerJoinFailed" else switch (progress.failure) {
                c.XMO_JOB_MISSING => "MachOLocalFileUnavailable",
                c.XMO_JOB_UUID => "MachOUuidMismatch",
                c.XMO_JOB_ARCH => "MachOArchitectureMismatch",
                c.XMO_JOB_CHANGED => "MachOFileChanged",
                c.XMO_JOB_FILE => "MachOLocalFileRefused",
                else => statusName(progress.status),
            };
            c.xmo_job_destroy(job);
            e.job = null;
            budget.release(e.charged);
            self.held -= e.charged;
            e.charged = 0;
        } else {
            const retained = progress.retained_bytes + overhead;
            std.debug.assert(retained <= e.charged);
            budget.release(e.charged - @as(usize, @intCast(retained)));
            self.held -= e.charged - @as(usize, @intCast(retained));
            e.charged = @intCast(retained);
        }
        return true;
    }
    pub fn prune(self: *State, images: []const rt.struct_xrt_gdb_image) void {
        _ = self.poll();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            const live = for (images) |*image| {
                if (matches(e, image)) break true;
            } else false;
            if (live) {
                i += 1;
                continue;
            }
            if (self.pending == e) {
                c.xmo_job_cancel(e.job.?);
                i += 1;
            } else self.destroy(self.entries.swapRemove(i));
        }
    }
    fn evict(self: *State) bool {
        var oldest: ?usize = null;
        for (self.entries.items, 0..) |e, i| {
            if (e == self.pending) continue;
            if (oldest == null or e.used < self.entries.items[oldest.?].used) oldest = i;
        }
        const index = oldest orelse return false;
        self.destroy(self.entries.swapRemove(index));
        return true;
    }
    fn start(self: *State, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8) !*Entry {
        if (!image.has_uuid or !image.has_header or image.path_truncated) return error.MachOIdentityUnavailable;
        const path = std.mem.sliceTo(&image.path, 0);
        const base = std.fs.path.basename(path);
        if (base.len == 0 or base.len > 255 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..") or std.mem.indexOfScalar(u8, base, '\\') != null) {
            while (self.entries.items.len >= max_entries) if (!self.evict()) return error.MachOSymbolBudget;
            const e = try a.create(Entry);
            errdefer a.destroy(e);
            const name = try a.dupe(u8, base);
            errdefer a.free(name);
            e.* = .{ .uuid = image.uuid, .cpu = image.cputype, .subtype = image.cpusubtype, .filetype = image.filetype, .basename = name, .failure = "MachOImageBasenameInvalid", .used = self.clock };
            try self.entries.append(a, e);
            return e;
        }
        if (self.pending != null) return error.MachOSymbolsPending;
        if (roots.len == 0 and !(image.filetype == c.XMO_MH_EXECUTE and self.executable != null)) return error.MachOLocalFileUnavailable;
        const allowance: usize = @min(c.XMO_MAX_RETAINED_BYTES, budget.per_image_limit -| overhead);
        if (allowance == 0) return error.MachOSymbolBudget;
        const needed = allowance + overhead;
        while (self.entries.items.len >= max_entries or self.held > byte_limit - needed) if (!self.evict()) return error.MachOSymbolBudget;
        const charged = budget.reserve(needed) catch return error.MachOSymbolBudget;
        errdefer budget.release(charged);
        const e = try a.create(Entry);
        errdefer a.destroy(e);
        var pointers: [16][*c]const u8 = @splat(null);
        if (roots.len > pointers.len) return error.DebugDirectoryLimit;
        for (roots, 0..) |root, i| pointers[i] = root.ptr;
        const name = try a.dupeZ(u8, base);
        defer a.free(name);
        var options: c.struct_xmo_job_options = std.mem.zeroes(c.struct_xmo_job_options);
        options.executable = if (image.filetype == c.XMO_MH_EXECUTE) (if (self.executable) |p| p.ptr else null) else null;
        options.basename = name.ptr;
        options.roots = &pointers;
        options.root_count = roots.len;
        options.uuid = image.uuid;
        options.cputype = image.cputype;
        options.cpusubtype = image.cpusubtype;
        options.allowance = allowance;
        var job: ?*c.struct_xmo_job = null;
        const result = c.xmo_job_start(&options, &job);
        if (result != c.XMO_OK) return error.MachOSymbolWorkerFailed;
        errdefer c.xmo_job_destroy(job);
        const stored_name = try a.dupe(u8, base);
        errdefer a.free(stored_name);
        e.* = .{ .uuid = image.uuid, .cpu = image.cputype, .subtype = image.cpusubtype, .filetype = image.filetype, .basename = stored_name, .job = job, .charged = charged, .used = self.clock };
        try self.entries.append(a, e);
        self.held += charged;
        self.pending = e;
        return e;
    }
    pub const Symbol = struct { name: []const u8, address: u64, size: u64 };
    pub fn findSymbol(self: *State, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8, name: []const u8, text_address: u64) !?Symbol {
        if (name.len == 0 or name.len > c.XMO_MAX_NAME or std.mem.indexOfScalar(u8, name, 0) != null) return error.SymbolNameLimit;
        _ = self.poll();
        self.clock +|= 1;
        const e = self.find(image) orelse try self.start(image, roots);
        e.used = self.clock;
        if (self.pending == e) return error.MachOSymbolsPending;
        if (e.failure != null) return null;
        const job = e.job orelse return null;
        const info = c.xmo_job_info(job) orelse return error.MachOSymbolsUnavailable;
        if (info.*.has_text == 0 or info.*.text_vmaddr != text_address) return error.MachOLayoutMismatch;
        const stored = try a.dupeZ(u8, name);
        defer a.free(stored);
        var value: u64 = 0;
        var size: u64 = 0;
        const result = c.xmo_job_find_symbol(job, stored.ptr, &value, &size);
        if (result == c.XMO_NOT_FOUND) return null;
        if (result == c.XMO_UNAVAILABLE) return error.SymbolAmbiguous;
        if (result != c.XMO_OK) return error.MachOSymbolsUnavailable;
        return .{ .name = name, .address = value, .size = size };
    }
    pub fn unwind(self: *State, allocator: std.mem.Allocator, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8, text: u64, pc: u64, context: @import("../debug/location.zig").Context, mask: u64, top: bool) !dwarf.Unwind {
        if (image.cputype != c.XMO_CPU_ARM64) return error.MachOUnwindArchitectureUnsupported;
        _ = self.poll();
        self.clock +|= 1;
        const e = self.find(image) orelse try self.start(image, roots);
        e.used = self.clock;
        if (self.pending == e) return error.MachOSymbolsPending;
        if (e.failure != null) return error.MachOUnwindInfoUnavailable;
        const job = e.job orelse return error.MachOUnwindInfoUnavailable;
        const metadata = c.xmo_job_info(job) orelse return error.MachOUnwindInfoUnavailable;
        if (metadata.*.has_text == 0 or metadata.*.text_vmaddr != text) return error.MachOLayoutMismatch;
        var container: [*c]const c.struct_xmo_dwarf = null;
        const cfi_status = c.xmo_job_unwind(job, &container);
        if (cfi_status == c.XMO_CHANGED) return error.MachOFileChanged;
        if (cfi_status == c.XMO_OK and !e.cfi_checked) {
            e.cfi_checked = true;
            e.cfi = dwarf.Cfi.init(.aarch64, container.*.bytes[0..container.*.size]) catch null;
        }
        if (e.cfi) |*cfi| {
            if (cfi.unwind(allocator, pc, context)) |step_| {
                var step = step_;
                if (step.caller[32]) |value| step.caller[32] = value & mask;
                if (step.caller[29]) |value| step.caller[29] = value & mask;
                return step;
            } else |_| {}
        }
        var row: c.struct_xmu_row = undefined;
        switch (c.xmo_job_compact(job, pc, &row)) {
            c.XMO_OK => {},
            c.XMO_CHANGED => return error.MachOFileChanged,
            c.XMO_LIMIT => return error.MachOUnwindBudget,
            c.XMO_MALFORMED => return error.MachOCompactMalformed,
            else => return error.MachOUnwindInfoUnavailable,
        }
        // At an asynchronous stop compact metadata alone cannot say whether
        // the prologue has executed or the epilogue has restored SP/FP. A
        // zero-stack leaf is valid throughout; other first frames retain the
        // explicit prologue/frame-pointer fallback until CFI can describe it.
        if (top and row.encoding & 0x0fffffff != 0x02000000) return error.MachOCompactPrologueUnproven;
        return @import("../debug/macho_unwind.zig").unwind(row.encoding, context, mask);
    }
    pub const Debug = struct { info: *dwarf.Image, job: *c.struct_xmo_job, object: ?u32 = null, pc: u64 };
    pub fn debugInfo(self: *State, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8, text_address: u64, pc: u64) !Debug {
        _ = self.poll();
        self.clock +|= 1;
        const e = self.find(image) orelse try self.start(image, roots);
        e.used = self.clock;
        if (self.pending == e) return error.MachODebugInfoPending;
        if (e.failure != null) return error.MachODebugInfoUnavailable;
        const job = e.job orelse return error.MachODebugInfoUnavailable;
        const info = c.xmo_job_info(job) orelse return error.MachODebugInfoUnavailable;
        if (info.*.has_text == 0 or info.*.text_vmaddr != text_address) return error.MachOLayoutMismatch;
        var container: [*c]const c.struct_xmo_dwarf = null;
        switch (c.xmo_job_debug(job, &container)) {
            c.XMO_DEBUG_READY => {},
            c.XMO_DEBUG_UUID => return error.MachODsymUuidMismatch,
            c.XMO_DEBUG_ARCH => return error.MachODsymArchitectureMismatch,
            c.XMO_DEBUG_LIMIT => return error.MachODebugInfoBudget,
            c.XMO_DEBUG_CHANGED => return error.MachODebugFileChanged,
            c.XMO_DEBUG_MISSING => {
                var index: u32 = 0;
                var object_pc: u64 = 0;
                switch (c.xmo_job_object(job, pc, &index, &object_pc, &container)) {
                    c.XMO_OK => {},
                    c.XMO_LIMIT => return error.MachOObjectDebugBudget,
                    c.XMO_CHANGED => return error.MachOObjectChanged,
                    c.XMO_MALFORMED => return error.MachOObjectMalformed,
                    c.XMO_UNSUPPORTED => return error.MachOObjectDebugUnsupported,
                    else => return error.MachOObjectDebugUnavailable,
                }
                return .{ .info = try objectImage(e, index, container), .job = job, .object = index, .pc = object_pc };
            },
            else => return error.MachODebugFileRefused,
        }
        return .{ .info = try primaryImage(e, container), .job = job, .pc = pc };
    }
    /// Link-time addresses for a source line. A linked image with an N_OSO
    /// debug map has no single object PC that can nominate its DWARF, so a
    /// source search must visit every pinned object rather than asking for the
    /// object that owns the executable's text base.
    pub fn sourceAddresses(self: *State, alloc: std.mem.Allocator, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8, text_address: u64, path: []const u8, line: u32) ![]u64 {
        _ = self.poll();
        self.clock +|= 1;
        const e = self.find(image) orelse try self.start(image, roots);
        e.used = self.clock;
        if (self.pending == e) return error.MachODebugInfoPending;
        if (e.failure != null) return error.MachODebugInfoUnavailable;
        const job = e.job orelse return error.MachODebugInfoUnavailable;
        const info = c.xmo_job_info(job) orelse return error.MachODebugInfoUnavailable;
        if (info.*.has_text == 0 or info.*.text_vmaddr != text_address) return error.MachOLayoutMismatch;
        var addresses: std.ArrayList(u64) = .empty;
        var container: [*c]const c.struct_xmo_dwarf = null;
        switch (c.xmo_job_debug(job, &container)) {
            c.XMO_DEBUG_READY => {
                const debug = try primaryImage(e, container);
                const rows = debug.rowsForLine(alloc, path, line) catch return addresses.toOwnedSlice(alloc);
                for (rows) |row| try addresses.append(alloc, row.address);
            },
            c.XMO_DEBUG_UUID => return error.MachODsymUuidMismatch,
            c.XMO_DEBUG_ARCH => return error.MachODsymArchitectureMismatch,
            c.XMO_DEBUG_LIMIT => return error.MachODebugInfoBudget,
            c.XMO_DEBUG_CHANGED => return error.MachODebugFileChanged,
            c.XMO_DEBUG_MISSING => {
                var count: u32 = 0;
                switch (c.xmo_job_object_count(job, &count)) {
                    c.XMO_OK => {},
                    c.XMO_LIMIT => return error.MachOObjectDebugBudget,
                    c.XMO_CHANGED => return error.MachOObjectChanged,
                    c.XMO_MALFORMED => return error.MachOObjectMalformed,
                    else => return error.MachOObjectDebugUnavailable,
                }
                for (0..count) |index_| {
                    const index: u32 = @intCast(index_);
                    switch (c.xmo_job_object_debug(job, index, &container)) {
                        c.XMO_OK => {},
                        c.XMO_NOT_FOUND, c.XMO_UNAVAILABLE, c.XMO_IO, c.XMO_UNSUPPORTED => continue,
                        c.XMO_LIMIT => return error.MachOObjectDebugBudget,
                        c.XMO_CHANGED => return error.MachOObjectChanged,
                        c.XMO_MALFORMED => return error.MachOObjectMalformed,
                        else => return error.MachOObjectDebugUnavailable,
                    }
                    const debug = try objectImage(e, index, container);
                    const rows = debug.rowsForLine(alloc, path, line) catch continue;
                    for (rows) |row| {
                        var linked: u64 = 0;
                        switch (c.xmo_job_object_address(job, index, row.address, &linked)) {
                            c.XMO_OK => {},
                            c.XMO_CHANGED => return error.MachOObjectChanged,
                            else => continue,
                        }
                        var duplicate = false;
                        for (addresses.items) |old| if (old == linked) {
                            duplicate = true;
                            break;
                        };
                        if (!duplicate) try addresses.append(alloc, linked);
                    }
                }
            },
            else => return error.MachODebugFileRefused,
        }
        return addresses.toOwnedSlice(alloc);
    }
    pub fn symbol(self: *State, allocator: std.mem.Allocator, image: *const rt.struct_xrt_gdb_image, roots: []const [:0]const u8, link: u64, text_address: u64) !?Symbol {
        _ = self.poll();
        self.clock +|= 1;
        const e = self.find(image) orelse try self.start(image, roots);
        e.used = self.clock;
        if (self.pending == e) return error.MachOSymbolsPending;
        if (e.failure != null) return null;
        const job = e.job orelse return null;
        const info = c.xmo_job_info(job) orelse return error.MachOSymbolsUnavailable;
        if (info.*.has_text == 0 or info.*.text_vmaddr != text_address) return error.MachOLayoutMismatch;
        var name: [c.XMO_MAX_NAME + 1]u8 = undefined;
        var value: u64 = 0;
        var size: u64 = 0;
        const result = c.xmo_job_symbol(job, link, &name, name.len, &value, &size);
        if (result == c.XMO_NOT_FOUND or result == c.XMO_UNAVAILABLE) return null;
        if (result != c.XMO_OK) {
            e.failure = statusName(result);
            return null;
        }
        const stored = std.mem.sliceTo(&name, 0);
        if (!std.unicode.utf8ValidateSlice(stored)) return error.MachOSymbolNameInvalid;
        return .{ .name = try allocator.dupe(u8, if (std.mem.startsWith(u8, stored, "_")) stored[1..] else stored), .address = value, .size = size };
    }
};
fn statusName(status: c.enum_xmo_status) []const u8 {
    return switch (status) {
        c.XMO_LIMIT => "MachOSymbolBudget",
        c.XMO_CHANGED => "MachOFileChanged",
        c.XMO_CANCELLED => "MachOSymbolsCancelled",
        c.XMO_NOMEM => "OutOfMemory",
        c.XMO_UNSUPPORTED => "MachOFormatUnsupported",
        c.XMO_IO => "MachOLocalFileUnavailable",
        else => "MachOMalformed",
    };
}

test "Mach-O cache distinguishes basenames and caches invalid path components" {
    var state = State{};
    defer state.deinit();
    var first = std.mem.zeroes(rt.struct_xrt_gdb_image);
    first.has_uuid = true;
    first.has_header = true;
    first.cputype = 0x0100000c;
    first.filetype = 2;
    first.path[0] = '.';
    const failed = try state.start(&first, &.{});
    try std.testing.expectEqualStrings("MachOImageBasenameInvalid", failed.failure.?);
    try std.testing.expect(state.pending == null and failed.job == null);
    try std.testing.expectEqual(failed, state.find(&first).?);
    var second = first;
    second.path[1] = '.';
    try std.testing.expect(state.find(&second) == null);
    const other = try state.start(&second, &.{});
    try std.testing.expect(other != failed and state.entries.items.len == 2);
    second.filetype = 6;
    try std.testing.expect(state.find(&second) == null);
    try std.testing.expectEqual(@as(usize, 0), state.held);
}

test "ARM64 Mach-O unwind refuses x86 metadata before reading registers" {
    const Reader = struct {
        fn read(_: *anyopaque, _: u64, _: []u8) !usize {
            return error.UnexpectedMemoryRead;
        }
    };
    var state = State{};
    defer state.deinit();
    var image = std.mem.zeroes(rt.struct_xrt_gdb_image);
    image.cputype = c.XMO_CPU_X86_64;
    var user: u8 = 0;
    try std.testing.expectError(error.MachOUnwindArchitectureUnsupported, state.unwind(std.testing.allocator, &image, &.{}, 0, 0, .{ .registers = @splat(null), .user = &user, .read = Reader.read }, std.math.maxInt(u64), true));
    try std.testing.expectEqual(@as(usize, 0), state.entries.items.len);
}
