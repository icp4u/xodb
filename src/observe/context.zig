//! Retained, bounded inspection jobs. Only the session owner reads the target.
//! Each item is copied before yielding; no module/DWARF pointers survive a poll.
const std = @import("std");
const Budget = @import("../profile/archive_budget.zig").Budget;
pub const max_jobs = 8;
pub const memory_limit = 4 * 1024 * 1024;
pub const max_item_bytes = 128 * 1024;
pub const Range = struct { address: u64, length: usize };
pub const Request = struct {
    generation: u64,
    tid: i32,
    frame: usize = 0,
    registers: bool = true,
    stack: bool = true,
    locals: bool = false,
    expressions: []const []const u8 = &.{},
    memory: []const Range = &.{},
    pub fn validate(self: Request) !void {
        if (self.tid <= 0 or self.frame >= 64 or self.expressions.len > 16 or self.memory.len > 16) return error.InvalidInspection;
        var bytes: usize = 0;
        for (self.memory) |range| {
            if (range.length == 0 or range.length > 4096 or range.address > std.math.maxInt(u64) - range.length) return error.InvalidInspection;
            bytes += range.length;
        }
        if (bytes > 65536) return error.InvalidInspection;
        for (self.expressions) |expression| if (expression.len == 0 or expression.len > 256) return error.InvalidInspection;
        if (self.count() == 0) return error.EmptyInspection;
    }
    pub fn count(self: Request) usize {
        return @as(usize, @intFromBool(self.registers)) + @intFromBool(self.stack) + @intFromBool(self.locals) + self.expressions.len + self.memory.len;
    }
};
pub const Thread = struct { id: u64, tid: i32 };
pub const Identity = struct { session_id: u64, process_id: u64, pid: i32, generation: u64, image_epoch: u64, thread_id: u64, tid: i32, frame: usize };
pub const State = enum { pending, running, completed, cancelled, failed };
pub const Kind = enum { registers, stack, locals, expression, memory };
pub const Item = struct { kind: Kind, index: usize, json: ?[]const u8 = null, diagnostic: ?[]const u8 = null };
pub const Job = struct {
    id: u64,
    identity: Identity,
    threads: []const Thread,
    request: Request,
    state: State = .pending,
    diagnostic: ?[]const u8 = null,
    budget: Budget,
    arena: std.heap.ArenaAllocator,
    items: [35]Item = undefined,
    done: usize = 0,
    pub fn active(self: *const Job) bool {
        return self.state == .pending or self.state == .running;
    }
    pub fn deinit(self: *Job) void {
        const backing = self.budget.backing;
        self.arena.deinit();
        backing.destroy(self);
    }
    fn check(self: *const Job, session: anytype) !void {
        const now = session.target.snapshot();
        if (session.id != self.identity.session_id or session.process_id != self.identity.process_id or now.pid != self.identity.pid or now.generation != self.identity.generation or now.image_epoch != self.identity.image_epoch) return error.InspectionContextChanged;
        if (now.state != .stopped or now.birth_count != 0 or session.target.sharedVm()) return error.InspectionContextChanged;
        var alive: usize = 0;
        for (session.target.threadSlice()) |thread| {
            if (thread.state == .exited) continue;
            if (thread.state != .stopped) return error.InspectionContextChanged;
            for (self.threads) |old| {
                if (old.id == thread.id and old.tid == thread.tid) break;
            } else return error.InspectionContextChanged;
            alive += 1;
        }
        if (alive != self.threads.len) return error.InspectionContextChanged;
    }
    fn descriptor(self: *const Job) Item {
        var index = self.done;
        inline for (.{ Kind.registers, Kind.stack, Kind.locals }) |kind| {
            if (@field(self.request, @tagName(kind))) {
                if (index == 0) return .{ .kind = kind, .index = 0 };
                index -= 1;
            }
        }
        if (index < self.request.expressions.len) return .{ .kind = .expression, .index = index };
        return .{ .kind = .memory, .index = index - self.request.expressions.len };
    }
    fn encode(self: *Job, value: anytype) ![]const u8 {
        const json = try std.json.Stringify.valueAlloc(self.arena.allocator(), value, .{ .emit_null_optional_fields = true });
        if (json.len > max_item_bytes) return error.InspectionItemTooLarge;
        return json;
    }
    fn capture(self: *Job, session: anytype, item: Item) ![]const u8 {
        var scratch = std.heap.ArenaAllocator.init(self.budget.allocator());
        defer scratch.deinit();
        const a = scratch.allocator();
        switch (item.kind) {
            .registers => {
                const registers = try session.target.registers(self.request.tid);
                var values: std.json.ObjectMap = .{};
                for (registers.descriptions()) |desc| try values.put(a, std.mem.span(desc.name), .{ .string = try std.fmt.allocPrint(a, "0x{x}", .{registers.value(desc)}) });
                return self.encode(.{ .architecture = @tagName(registers.architecture()), .values = std.json.Value{ .object = values } });
            },
            .stack => return self.encode(.{ .frames = try session.stack(a, self.request.tid, 64), .limit = 64 }),
            .locals => {
                const locals = try session.locals(a, self.request.tid, self.request.frame);
                const Row = struct { name: []const u8, value: ?@import("../model/session.zig").ValueSummary, diagnostic: ?[]const u8 };
                const rows = try a.alloc(Row, @min(locals.len, 128));
                for (locals[0..rows.len], rows) |local, *row| {
                    row.* = .{ .name = local.name, .value = null, .diagnostic = local.diagnostic };
                    row.value = session.summarize(a, local.value) catch |err| {
                        row.diagnostic = @errorName(err);
                        continue;
                    };
                }
                return self.encode(.{ .frame = self.request.frame, .locals = rows, .truncated = locals.len > rows.len });
            },
            .expression => {
                const expression = self.request.expressions[item.index];
                const value = try session.evaluateExpression(a, self.request.tid, self.request.frame, expression);
                return self.encode(.{ .expression = expression, .value = try session.summarize(a, value) });
            },
            .memory => {
                const range = self.request.memory[item.index];
                const bytes = try a.alloc(u8, range.length);
                const hex = try a.alloc(u8, range.length * 2);
                @memset(hex, '?');
                const valid = try a.alloc(bool, range.length);
                @memset(valid, false);
                var offset: usize = 0;
                var readable: usize = 0;
                const digits = "0123456789abcdef";
                while (offset < bytes.len) {
                    const address = range.address + offset;
                    const length = @min(bytes.len - offset, 4096 - (address & 4095));
                    const n = session.target.readMemory(address, bytes[offset..][0..length]) catch 0;
                    if (n > length) return error.InvalidMemoryRead;
                    for (bytes[offset..][0..n], 0..) |byte, j| {
                        hex[2 * (offset + j)] = digits[byte >> 4];
                        hex[2 * (offset + j) + 1] = digits[byte & 15];
                        valid[offset + j] = true;
                    }
                    readable += n;
                    offset += length;
                }
                return self.encode(.{ .address = try std.fmt.allocPrint(a, "0x{x}", .{range.address}), .length = range.length, .readable = readable, .hex = hex, .valid = valid });
            },
        }
    }
    fn poll(self: *Job, session: anytype) void {
        if (!self.active()) return;
        self.check(session) catch |err| {
            self.state = .failed;
            self.diagnostic = @errorName(err);
            return;
        };
        self.state = .running;
        var item = self.descriptor();
        item.json = self.capture(session, item) catch |err| blk: {
            if (err == error.OutOfMemory or err == error.InspectionItemTooLarge) {
                self.state = .failed;
                self.diagnostic = @errorName(err);
                return;
            }
            item.diagnostic = @errorName(err);
            break :blk null;
        };
        self.check(session) catch |err| {
            self.state = .failed;
            self.diagnostic = @errorName(err);
            return;
        };
        self.items[self.done] = item;
        self.done += 1;
        if (self.done == self.request.count()) self.state = .completed;
    }
};
pub const Manager = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
    jobs: [max_jobs]?*Job = @splat(null),
    next_id: u64 = 1,
    cursor: usize = 0,
    pub fn deinit(self: *Manager) void {
        for (&self.jobs) |*job| if (job.*) |v| {
            v.deinit();
            job.* = null;
        };
    }
    pub fn start(self: *Manager, session: anytype, request: Request) !*Job {
        try request.validate();
        if (session.offline or session.imported != null) return error.LiveOrCoreRequired;
        try session.target.expectGeneration(request.generation);
        const snapshot = session.target.snapshot();
        if (snapshot.state != .stopped) return error.NotStopped;
        if (snapshot.birth_count != 0 or session.target.sharedVm()) return error.ProcessFamilyRequiresResolution;
        var thread_id: ?u64 = null;
        var count: usize = 0;
        for (session.target.threadSlice()) |thread| {
            if (thread.state == .exited) continue;
            if (thread.state != .stopped) return error.AllThreadsMustBeStopped;
            if (thread.tid == request.tid) thread_id = thread.id;
            count += 1;
        }
        const selected = thread_id orelse return error.UnknownThread;
        const slot = for (&self.jobs) |*job| {
            if (job.* == null) break job;
        } else return error.InspectionLimit;
        if (self.next_id == std.math.maxInt(u64)) return error.InspectionLimit;
        const job = try self.allocator.create(Job);
        job.* = .{ .id = self.next_id, .identity = .{ .session_id = session.id, .process_id = session.process_id, .pid = snapshot.pid, .generation = snapshot.generation, .image_epoch = snapshot.image_epoch, .thread_id = selected, .tid = request.tid, .frame = request.frame }, .threads = &.{}, .request = request, .budget = .{ .backing = self.allocator, .limit = memory_limit }, .arena = undefined };
        job.arena = std.heap.ArenaAllocator.init(job.budget.allocator());
        errdefer job.deinit();
        const a = job.arena.allocator();
        const threads = try a.alloc(Thread, count);
        var i: usize = 0;
        for (session.target.threadSlice()) |thread| {
            if (thread.state == .exited) continue;
            threads[i] = .{ .id = thread.id, .tid = thread.tid };
            i += 1;
        }
        job.threads = threads;
        const expressions = try a.alloc([]const u8, request.expressions.len);
        for (request.expressions, expressions) |expression, *copy| copy.* = try a.dupe(u8, expression);
        job.request.expressions = expressions;
        job.request.memory = try a.dupe(Range, request.memory);
        slot.* = job;
        self.next_id += 1;
        return job;
    }
    pub fn find(self: *Manager, id: u64) !*Job {
        for (self.jobs) |job| if (job) |v| {
            if (v.id == id) return v;
        };
        return error.UnknownInspection;
    }
    pub fn release(self: *Manager, id: u64) !void {
        for (&self.jobs) |*job| if (job.*) |v| {
            if (v.id == id) {
                v.deinit();
                job.* = null;
                return;
            }
        };
        return error.UnknownInspection;
    }
    /// At most one item per owner poll, round-robin across retained jobs.
    pub fn poll(self: *Manager, session: anytype) void {
        for (0..max_jobs) |_| {
            const index = self.cursor;
            self.cursor = (self.cursor + 1) % max_jobs;
            if (self.jobs[index]) |job| if (job.active()) {
                job.poll(session);
                return;
            };
        }
    }
};
