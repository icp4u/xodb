//! Bounded local Mach-O symbol workers. Remote names never become host paths.
const std = @import("std");
const c = @import("../c.zig").api;
const rt = @import("../target/runtime.zig").c;
const budget = @import("../binary/snapshot.zig");
const a = std.heap.page_allocator;
const max_entries = 32;
const byte_limit = 256 * 1024 * 1024;
const overhead = 128 * 1024; // worker, parser object and copied option strings
const Entry = struct {
    uuid: [16]u8,
    cpu: u32,
    subtype: u32,
    job: ?*c.struct_xmo_job = null,
    failure: ?[]const u8 = null,
    charged: usize = 0,
    used: u64 = 0,
};
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
        if (e.job) |job| c.xmo_job_destroy(job);
        budget.release(e.charged);
        self.held -= e.charged;
        a.destroy(e);
    }
    fn matches(e: *const Entry, image: *const rt.struct_xrt_gdb_image) bool {
        return image.has_uuid and std.mem.eql(u8, &e.uuid, &image.uuid) and e.cpu == image.cputype and e.subtype == image.cpusubtype;
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
        const path = std.mem.sliceTo(&image.path, 0);
        const base = std.fs.path.basename(path);
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
        e.* = .{ .uuid = image.uuid, .cpu = image.cputype, .subtype = image.cpusubtype, .job = job, .charged = charged, .used = self.clock };
        try self.entries.append(a, e);
        self.held += charged;
        self.pending = e;
        return e;
    }
    pub const Symbol = struct { name: []const u8, address: u64 };
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
        return .{ .name = try allocator.dupe(u8, if (std.mem.startsWith(u8, stored, "_")) stored[1..] else stored), .address = value };
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
