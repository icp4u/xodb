//! Native owner adapter over the shared GDB runtime and Mach-O symbol cache.
//! All transport/metadata work stays on the client's worker, never AppKit.
const std = @import("std");
const rt = @import("../target/runtime.zig");
const c = rt.c;
const wire = @import("../remote/view.zig");
const command = @import("command.zig");
const symbols = @import("macho_images.zig");
const log = @import("../log.zig");
const a = std.heap.page_allocator;
pub const Options = struct {
    argv: []const [:0]const u8 = &.{},
    attach: i32 = 0,
    executable: ?[:0]const u8 = null,
    source: ?[:0]const u8 = null,
    breakpoint: ?[]const u8 = null,
};
pub const Session = struct {
    target: ?*c.struct_xrt_target = null,
    gdb: ?*c.struct_xrt_gdb = null,
    helper: c.struct_xrt_debugserver = std.mem.zeroes(c.struct_xrt_debugserver),
    metadata: symbols.State = .{},
    images: []c.struct_xrt_gdb_image = &.{},
    image_count: usize = 0,
    image_generation: u64 = std.math.maxInt(u64),
    options: Options,
    revision: u64 = 1,
    initial_break: bool = false,
    detached: bool = false,
    source_text: ?[]const u8 = null,

    pub fn open(self: *Session) !void {
        self.target = c.xrt_target_create() orelse return error.OutOfMemory;
        errdefer self.close();
        self.images = try a.alloc(c.struct_xrt_gdb_image, 256);
        const args = try a.alloc([*c]const u8, self.options.argv.len + 1);
        defer a.free(args);
        for (self.options.argv, 0..) |arg, i| args[i] = arg.ptr;
        args[self.options.argv.len] = null;
        try rt.check(c.xrt_debugserver_start(&.{
            .executable = null,
            .cancel = null,
            .argv = if (self.options.argv.len != 0) args.ptr else null,
            .attach_pid = self.options.attach,
        }, &self.helper));
        log.info(.runtime, "xodb: native helper started pid={d}; private inherited transport\n", .{self.helper.pid});
        try rt.check(c.xrt_gdb_open_fd(c.xrt_debugserver_take_transport(&self.helper), self.options.attach, self.target, &self.gdb, null));
        self.metadata.executable = self.options.executable orelse if (self.options.argv.len != 0) self.options.argv[0] else null;
        if (self.options.source) |path| {
            const file = @import("../c.zig").api;
            const fd = file.open(path.ptr, file.O_RDONLY | file.O_CLOEXEC | file.O_NONBLOCK);
            if (fd < 0) return error.SourceUnavailable;
            defer _ = file.close(fd);
            const bytes = try a.alloc(u8, 48 * 1024);
            errdefer a.free(bytes);
            const size = file.read(fd, bytes.ptr, bytes.len);
            if (size < 0) return error.SourceUnavailable;
            self.source_text = try a.dupe(u8, bytes[0..@intCast(size)]);
            a.free(bytes);
        }
    }
    pub fn close(self: *Session) void {
        const helper_pid = self.helper.pid;
        var detach_confirmed = false;
        if (self.gdb != null) {
            self.call(.{ .op = c.XRT_RPC_DETACH }) catch |err|
                log.warn(.runtime, "xodb: native detach unconfirmed: {s}\n", .{@errorName(err)});
            detach_confirmed = c.xrt_gdb_detach_confirmed(self.gdb);
            if (detach_confirmed) _ = c.xrt_debugserver_wait(&self.helper, 2000);
            c.xrt_gdb_free(self.gdb);
            self.gdb = null;
        }
        const result = if (detach_confirmed) c.xrt_debugserver_close_detached(&self.helper) else c.xrt_debugserver_close(&self.helper);
        if (result != c.XRT_OK) {
            log.warn(.runtime, "xodb: native helper cleanup unconfirmed (status {d}); kept helper pid={d}\n", .{ result, self.helper.pid });
        } else if (helper_pid != 0) {
            log.info(.runtime, "xodb: native helper reaped pid={d}\n", .{helper_pid});
        }
        if (self.target) |target| std.c.free(target);
        self.target = null;
        self.metadata.deinit();
        a.free(self.images);
        self.images = &.{};
        if (self.source_text) |text| a.free(text);
        self.source_text = null;
    }
    fn call(self: *Session, request: c.struct_xrt_call) !void {
        try rt.check(c.xrt_gdb_call(self.gdb, self.target, &request));
    }
    fn state(self: *Session) c.struct_xrt_target_view {
        var view: c.struct_xrt_target_view = undefined;
        c.xrt_target_view(self.target, &view);
        return view;
    }
    /// The private stream failed: no further packet can reach debugserver.
    pub fn linkLost(self: *const Session) bool {
        return self.gdb == null or c.xrt_gdb_health(self.gdb) != c.XRT_OK;
    }
    pub fn ready(self: *const Session) bool {
        return self.options.breakpoint == null or self.initial_break;
    }
    pub fn poll(self: *Session) !void {
        if (self.detached) return;
        const before = self.state().generation;
        try self.call(.{ .op = c.XRT_RPC_SYNC });
        const view = self.state();
        if (before != view.generation) self.revision +%= 1;
        if (self.metadata.poll()) self.revision +%= 1;
        if (view.state == c.XRT_STOPPED and self.image_generation != view.generation) {
            var count: usize = 0;
            const status = c.xrt_gdb_images(self.gdb, self.target, self.images.ptr, self.images.len, &count);
            self.image_count = if (status == c.XRT_OK) @min(count, self.images.len) else 0;
            self.metadata.prune(self.images[0..self.image_count]);
            self.image_generation = view.generation;
        }
        if (!self.initial_break) if (self.options.breakpoint) |name| {
            const address = self.findSymbol(name) catch |err| {
                if (err == error.MachOSymbolsPending) return;
                // A missing startup symbol is a diagnostic, not a reason to
                // release the target. Expose its initial stop for user control.
                self.initial_break = true;
                self.revision +%= 1;
                return err;
            };
            try self.execute(.{ .breakpoint = .{ .address = address } });
            self.initial_break = true;
            try self.execute(.{ .control = .continue_execution });
        };
    }
    fn textAddress(image: *const c.struct_xrt_gdb_image) ?u64 {
        for (image.segments[0..@min(image.segment_count, image.segments.len)]) |segment|
            if (std.mem.eql(u8, std.mem.sliceTo(&segment.name, 0), "__TEXT")) return segment.vmaddr;
        return null;
    }
    fn findSymbol(self: *Session, name: []const u8) !u64 {
        for (self.images[0..self.image_count]) |*image| {
            if (image.filetype != 2) continue;
            const text = textAddress(image) orelse continue;
            if (try self.metadata.findSymbol(image, &.{}, name, text)) |found|
                return std.math.add(u64, image.load_address, found.address - text) catch error.InvalidAddress;
        }
        return error.SymbolNotFound;
    }
    fn label(self: *Session, mem: std.mem.Allocator, pc: u64) !?[]const u8 {
        for (self.images[0..self.image_count]) |*image| {
            const text = textAddress(image) orelse continue;
            if (image.load_address < text or pc < image.load_address) continue;
            const slide = image.load_address - text;
            var contains = false;
            for (image.segments[0..@min(image.segment_count, image.segments.len)]) |segment| {
                const start = std.math.add(u64, segment.vmaddr, slide) catch continue;
                if (segment.maxprot & 4 != 0 and pc >= start and pc - start < segment.vmsize) contains = true;
            }
            if (!contains) continue;
            const found = self.metadata.symbol(mem, image, &.{}, pc - slide, text) catch null;
            if (found) |symbol| return try std.fmt.allocPrint(mem, "{s}+0x{x}", .{ symbol.name, pc - slide - symbol.address });
            return try std.fmt.allocPrint(mem, "{s}+0x{x}", .{ std.fs.path.basename(std.mem.sliceTo(&image.path, 0)), pc - image.load_address });
        }
        return null;
    }
    pub fn execute(self: *Session, operation: command.Operation) !void {
        switch (operation) {
            .control => |control| switch (control) {
                .interrupt, .cancel_continue => try self.call(.{ .op = c.XRT_RPC_INTERRUPT }),
                .continue_execution => try self.call(.{ .op = c.XRT_RPC_CONTINUE }),
                .step_instruction => |tid| try self.call(.{ .op = c.XRT_RPC_STEP, .args = .{ @intCast(tid), 0, 0 } }),
                .detach => {
                    try self.call(.{ .op = c.XRT_RPC_DETACH });
                    self.detached = true;
                },
                // Refuse before decoding/executing; do not mislabel a single
                // instruction as source stepping or a step over a call.
                else => return error.NativeControlNotAvailable,
            },
            .breakpoint => |breakpoint| switch (breakpoint) {
                .address => |address| try self.call(.{ .op = c.XRT_RPC_BP_SET, .args = .{ address, 0, 0 } }),
                .symbol => |name| try self.call(.{ .op = c.XRT_RPC_BP_SET, .args = .{ try self.findSymbol(name), 0, 0 } }),
                .remove => |id| try self.call(.{ .op = c.XRT_RPC_BP_REMOVE, .args = .{ id, 0, 0 } }),
                else => return error.NativeDwarfNotAvailable,
            },
        }
        self.revision +%= 1;
    }
    fn registers(self: *Session, tid: i32) !rt.Registers {
        var bytes: [4096]u8 = undefined;
        var size: usize = 0;
        try self.call(.{ .op = c.XRT_RPC_REGISTERS, .args = .{ @intCast(tid), 0, 0 }, .out = &bytes, .capacity = bytes.len, .length = &size });
        var codec = c.xrt_codec(&bytes, size, true);
        var result: rt.Registers = undefined;
        c.xrt_wire_registers(&codec, &result.raw);
        if (!codec.ok or codec.at != size) return error.InvalidRegisters;
        return result;
    }
    pub fn read(self: *Session, address: u64, bytes: []u8) !usize {
        var size: usize = 0;
        try self.call(.{ .op = c.XRT_RPC_READ, .args = .{ address, bytes.len, 0 }, .out = bytes.ptr, .capacity = bytes.len, .length = &size });
        return size;
    }
    pub fn summary(self: *Session, mem: std.mem.Allocator, selected_tid: i32) !wire.View {
        const view = self.state();
        var info: c.struct_xrt_gdb_info = undefined;
        c.xrt_gdb_info(self.gdb, &info);
        var out = wire.View{ .session_id = 1, .generation = self.revision, .pid = view.pid, .architecture = try mem.dupe(u8, std.mem.sliceTo(&info.architecture, 0)), .state = switch (view.state) {
            c.XRT_STOPPED => "stopped",
            c.XRT_RUNNING => "running",
            c.XRT_EXITED => "exited",
            else => if (self.detached) "detached" else "idle",
        }, .scope = "control", .owned = self.options.argv.len != 0, .diagnostics = &.{.{ .component = "metadata", .message = "Native DWARF unavailable: source lines and locals are not decoded" }} };
        const threads = try mem.alloc(wire.Thread, view.thread_count);
        for (view.threads[0..view.thread_count], threads) |thread, *row| row.* = .{ .id = thread.id, .tid = thread.tid, .state = if (thread.state == c.XRT_STOPPED) "stopped" else "running", .reason = "debugserver" };
        out.threads = threads;
        out.tid = if (threads.len != 0) threads[0].tid else 0;
        for (threads) |thread| if (thread.tid == selected_tid) {
            out.tid = selected_tid;
            break;
        };
        const breakpoints = try mem.alloc(wire.Breakpoint, view.breakpoint_count);
        for (view.breakpoints[0..view.breakpoint_count], breakpoints) |bp, *row| row.* = .{ .id = bp.id, .address = bp.address };
        out.breakpoints = breakpoints;
        if (self.source_text) |text| out.source = .{ .path = self.options.source.?, .text = text, .truncated = text.len == 48 * 1024 };
        return out;
    }
    pub fn snapshot(self: *Session, mem: std.mem.Allocator, selected_tid: i32, selected_frame: usize) !wire.View {
        var out = try self.summary(mem, selected_tid);
        if (!std.mem.eql(u8, out.state, "stopped") or out.tid == 0) return out;
        var info: c.struct_xrt_gdb_info = undefined;
        c.xrt_gdb_info(self.gdb, &info);
        const regs = try self.registers(out.tid);
        const descriptions = regs.descriptions();
        const rows = try mem.alloc(wire.Register, descriptions.len);
        for (descriptions, rows) |desc, *row| row.* = .{ .name = std.mem.span(desc.name), .value = regs.value(desc) catch null };
        out.registers = rows;
        const mask: u64 = if (info.address_bits > 0 and info.address_bits < 64) (@as(u64, 1) << @intCast(info.address_bits)) - 1 else std.math.maxInt(u64);
        const pc = (regs.named("pc") orelse regs.named("rip") orelse return error.ProgramCounterUnavailable) & mask;
        var frames: std.ArrayList(wire.Frame) = .empty;
        try frames.append(mem, .{ .index = 0, .pc = pc, .symbol = try self.label(mem, pc), .diagnostic = "frame-pointer fallback; DWARF unavailable" });
        var fp = (regs.named("x29") orelse regs.named("rbp") orelse 0) & mask;
        const sp = regs.named("sp") orelse regs.named("rsp") orelse 0;
        while (frames.items.len < 64 and fp >= sp and fp - sp < 16 * 1024 * 1024 and fp % 16 == 0) {
            var bytes: [16]u8 = undefined;
            if ((self.read(fp, &bytes) catch break) != bytes.len) break;
            const previous = std.mem.readInt(u64, bytes[0..8], .little) & mask;
            const caller = std.mem.readInt(u64, bytes[8..16], .little) & mask;
            if (caller == 0 or previous <= fp) break;
            try frames.append(mem, .{ .index = frames.items.len, .pc = caller, .symbol = try self.label(mem, caller -| 1), .diagnostic = "frame-pointer fallback; registers/locals unavailable" });
            fp = previous;
        }
        out.frames = frames.items;
        out.frame = @min(selected_frame, frames.items.len - 1);
        if (out.frame != 0) out.registers = &.{}; // Do not show top-frame values as a caller's.
        const address = out.frames[out.frame].pc;
        var bytes: [256]u8 = undefined;
        const size = self.read(address, &bytes) catch 0;
        var instructions: [32]@import("disassembly.zig").Instruction = undefined;
        const count = @import("disassembly.zig").decodeFor(regs.architecture(), bytes[0..size], address, &instructions) catch 0;
        const decoded = try mem.alloc(wire.Instruction, count);
        for (instructions[0..count], decoded) |instruction, *row| row.* = .{ .address = instruction.address, .mnemonic = try mem.dupe(u8, std.mem.sliceTo(&instruction.mnemonic, 0)), .operands = try mem.dupe(u8, std.mem.sliceTo(&instruction.operands, 0)) };
        out.instructions = decoded;
        return out;
    }
};
