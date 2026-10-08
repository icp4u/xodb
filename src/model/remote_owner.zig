//! Remote-session ownership boundary. Dormant until the session worker is wired
//! in: no live Target, Session, service pointer or borrowed string crosses it.
const std = @import("std");
const View = @import("../remote/view.zig").View;
const Allocator = std.mem.Allocator;
pub const max_commands = 64;
pub const max_command_bytes = 8 * 1024 * 1024;
pub const max_publication_bytes = 16 * 1024 * 1024;

pub const Stamp = struct {
    connection: u64, // Never reused, including after reconnect to the same PID.
    session: u64,
    process: u64,
    pid: i32,
    // Compare start times when both are known. Connection/session/process/PID
    // must always match; learning a start time does not replace that identity.
    start_ticks: ?u64 = null,
    image_epoch: u64,
    generation: u64,
    pub fn sameProcess(a: Stamp, b: Stamp) bool {
        return a.connection == b.connection and a.session == b.session and
            a.process == b.process and a.pid == b.pid and
            (a.start_ticks == null or b.start_ticks == null or a.start_ticks == b.start_ticks);
    }
};
pub const Actor = union(enum) {
    human,
    agent: struct { client: u64, lease: ?u64 },
};
pub const Selection = struct { tid: i32, frame: usize = 0 };
pub const Control = union(enum) {
    interrupt,
    continue_execution,
    step_instruction: i32,
    step_over_instruction: i32,
    step_source: struct { tid: i32, over: bool },
    finish_frame: Selection,
    run_to: struct { tid: i32, address: u64 },
    restart,
    detach,
    follow_processes: struct { enabled: bool, limit: ?usize },
};
pub const Inspection = struct {
    request_id: u64, // Changes with selection, tab, expression or display options.
    selection: Selection,
    kind: enum { view, stack, locals, registers, disassembly, memory, expression, language },
    address: u64 = 0,
    limit: usize = 0,
    text: []const u8 = "",
};
pub const Action = union(enum) {
    poll,
    inspect: Inspection,
    control: Control,
    breakpoint: union(enum) {
        address: u64,
        source: struct { path: []const u8, line: u32 },
        remove: u64,
        enabled: struct { id: u64, enabled: bool },
    },
    watchpoint: union(enum) {
        add: struct { address: u64, length: u8, kind: enum { write, read_write, execute } },
        remove: u64,
    },
    write_memory: struct { address: u64, bytes: []const u8 },
    write_register: struct { tid: i32, name: []const u8, value: u64 },
    /// Protocol ingress, not pre-authorized execution. The owner parses the
    /// arguments, resolves the existing tool catalog's access annotation and
    /// runs its ordinary scope/lease/argument checks at execution time. This
    /// also covers retained jobs without duplicating their schemas here.
    mcp: struct { name: []const u8, arguments_json: []const u8 },
};
pub const Request = struct { stamp: Stamp, actor: Actor, action: Action };

// Bound before allocating; count nested slices, not only their outer headers.
fn payloadBytes(value: anytype, remaining: *usize) error{TooLarge}!void {
    switch (@typeInfo(@TypeOf(value))) {
        .pointer => |p| {
            if (p.size != .slice or p.sentinel() != null) @compileError("owned messages require ordinary slices");
            const bytes = std.math.mul(usize, value.len, @sizeOf(p.child)) catch return error.TooLarge;
            if (bytes > remaining.*) return error.TooLarge;
            remaining.* -= bytes;
            for (value) |item| try payloadBytes(item, remaining);
        },
        .optional => if (value) |v| try payloadBytes(v, remaining),
        .@"struct" => |s| inline for (s.fields) |f| try payloadBytes(@field(value, f.name), remaining),
        .@"union" => switch (value) {
            inline else => |v| try payloadBytes(v, remaining),
        },
        .array => for (value) |v| try payloadBytes(v, remaining),
        else => {},
    }
}
fn copyOwned(a: Allocator, value: anytype) Allocator.Error!@TypeOf(value) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |p| blk: {
            if (p.size != .slice or p.sentinel() != null) @compileError("owned messages require ordinary slices");
            const copy = try a.alloc(p.child, value.len);
            for (value, copy) |v, *out| out.* = try copyOwned(a, v);
            break :blk copy;
        },
        .optional => if (value) |v| try copyOwned(a, v) else null,
        .@"struct" => |s| blk: {
            var copy = value;
            inline for (s.fields) |f| @field(copy, f.name) = try copyOwned(a, @field(value, f.name));
            break :blk copy;
        },
        .@"union" => switch (value) {
            inline else => |v, tag| @unionInit(T, @tagName(tag), try copyOwned(a, v)),
        },
        .array => blk: {
            var copy = value;
            for (value, &copy) |v, *out| out.* = try copyOwned(a, v);
            break :blk copy;
        },
        else => value,
    };
}
pub const Command = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,
    bytes: usize,
    sequence: u64 = 0,
    pub fn create(a: Allocator, request: Request) !*Command {
        var remaining: usize = max_command_bytes - @sizeOf(Command);
        try payloadBytes(request, &remaining);
        const result = try a.create(Command);
        errdefer a.destroy(result);
        result.* = .{ .arena = std.heap.ArenaAllocator.init(a), .request = undefined, .bytes = max_command_bytes - remaining };
        errdefer result.arena.deinit();
        result.request = try copyOwned(result.arena.allocator(), request);
        return result;
    }
    pub fn destroy(self: *Command) void {
        const a = self.arena.child_allocator;
        self.arena.deinit();
        a.destroy(self);
    }
    /// Called only by the owner immediately before dispatch. The authorizer
    /// MUST resolve the actor against the live service, not a queued grant.
    /// It must classify MCP tools from the authoritative catalog, and run the
    /// same checks for retained jobs as ordinary synchronous dispatch.
    pub fn validate(self: *const Command, current: Stamp, authorizer: anytype) !void {
        const expected = self.request.stamp;
        if (!expected.sameProcess(current)) return error.StaleProcess;
        if (self.request.action != .poll and
            (expected.image_epoch != current.image_epoch or expected.generation != current.generation))
            return error.StaleSnapshot;
        try authorizer.authorize(self.request);
    }
};

/// One queue per remote connection family. Both GUI and MCP submit here.
/// Nothing holds this mutex across dispatch, allocation, free or remote I/O.
/// trySubmit/take return Busy immediately when the other side holds the lock.
/// The owner has at most one active command. Regular commands stay charged
/// through finish; polls use a reserved slot and cannot consume user capacity.
/// Same-process, same-actor pending polls coalesce and return the first sequence.
/// Different identities/actors get PollPending; no request is retargeted.
/// At most one active and one pending poll add two fixed headers, no payload,
/// beyond the regular 64-command / 8 MiB budget.
pub const Queue = struct {
    mutex: std.atomic.Mutex = .unlocked,
    slots: [max_commands]?*Command = @splat(null),
    head: usize = 0,
    count: usize = 0,
    active: ?*Command = null,
    poll_pending: ?*Command = null,
    bytes: usize = 0,
    next_sequence: u64 = 1,
    closed: bool = false,
    pub fn trySubmit(self: *Queue, command: *Command) !u64 {
        var coalesced: ?*Command = null;
        defer if (coalesced) |c| c.destroy(); // After unlocking; success owns input.
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (command.sequence != 0) return error.AlreadySubmitted;
        if (command.request.action == .poll) {
            if (self.poll_pending) |pending| {
                if (!pending.request.stamp.sameProcess(command.request.stamp) or
                    !std.meta.eql(pending.request.actor, command.request.actor)) return error.PollPending;
                coalesced = command;
                return pending.sequence;
            }
        } else {
            const active_count: usize = if (self.active) |c| @intFromBool(c.request.action != .poll) else 0;
            if (self.count + active_count == max_commands or
                command.bytes > max_command_bytes - self.bytes) return error.QueueFull;
        }
        if (self.next_sequence == std.math.maxInt(u64)) return error.SequenceExhausted;
        command.sequence = self.next_sequence;
        self.next_sequence += 1;
        if (command.request.action == .poll) {
            self.poll_pending = command;
            return command.sequence;
        }
        self.slots[(self.head + self.count) % max_commands] = command;
        self.count += 1;
        self.bytes += command.bytes;
        return command.sequence; // Ownership transfers only on success.
    }
    pub fn take(self: *Queue) !?*const Command {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (self.active != null) return null;
        if (self.poll_pending) |poll| {
            // Coalescing retains the first request's place in owner order.
            if (self.count == 0 or poll.sequence < self.slots[self.head].?.sequence) {
                self.active = poll;
                self.poll_pending = null;
                return poll;
            }
        }
        if (self.count == 0) return null;
        self.active = self.slots[self.head];
        self.slots[self.head] = null;
        self.head = (self.head + 1) % max_commands;
        self.count -= 1;
        return self.active;
    }
    /// Owner only, after dispatch (including rejection). Not a frame API.
    pub fn finish(self: *Queue) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        const command = self.active.?;
        self.active = null;
        if (command.request.action != .poll) self.bytes -= command.bytes;
        self.mutex.unlock();
        command.destroy();
    }
    /// Stop accepting commands; queued commands still require explicit failed
    /// completions. This does not interrupt a transport or confirm detach.
    pub fn close(self: *Queue) !void {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        self.closed = true;
    }
    /// After owner/producer shutdown only; never join or free on the frame.
    pub fn deinit(self: *Queue) void {
        if (self.active) |command| command.destroy();
        if (self.poll_pending) |command| command.destroy();
        for (self.slots) |command| if (command) |c| c.destroy();
        self.* = .{};
    }
};

pub const Presentation = struct {
    stamp: Stamp,
    revision: u64,
    taken_ns: u64,
    status: enum { ready, pending, failed, disconnected },
    inspection_id: ?u64 = null,
    /// Last confirmed target state. Pending/failure never fabricate a stop,
    /// resume or detach. The view carries its own generation when older.
    view: ?View = null,
    diagnostic: []const u8 = "",
    pub fn matchesInspection(self: Presentation, expected: Stamp, request_id: u64) bool {
        const view = self.view orelse return false;
        return self.status == .ready and self.inspection_id == request_id and
            self.stamp.sameProcess(expected) and self.stamp.image_epoch == expected.image_epoch and
            self.stamp.generation == expected.generation and view.generation == expected.generation and
            view.session_id == expected.session and view.pid == expected.pid;
    }
};
pub const Publication = struct {
    arena: std.heap.ArenaAllocator,
    value: Presentation,
    bytes: usize,
    pub fn create(a: Allocator, value: Presentation) !*const Publication {
        var remaining: usize = max_publication_bytes - @sizeOf(Publication);
        try payloadBytes(value, &remaining);
        const result = try a.create(Publication);
        errdefer a.destroy(result);
        result.* = .{ .arena = std.heap.ArenaAllocator.init(a), .value = undefined, .bytes = max_publication_bytes - remaining };
        errdefer result.arena.deinit();
        result.value = try copyOwned(result.arena.allocator(), value);
        return result;
    }
    pub fn destroy(self: *const Publication) void {
        const owned = @constCast(self);
        const a = owned.arena.child_allocator;
        owned.arena.deinit();
        a.destroy(owned);
    }
};
/// Transfer, not a shared mutable cache. The presenter keeps at most its current
/// view; a successful take transfers the pending one and it retires the old.
/// The single slot holds either a new view or the GUI's retired view. Owner
/// replaces/collects it and frees outside the lock before building another.
/// With one current GUI view and one being built, at most three payloads live.
/// Publication construction and retirement must stay off the frame path.
pub const Publications = struct {
    mutex: std.atomic.Mutex = .unlocked,
    connection: u64,
    latest_revision: u64 = 0,
    pending: ?*const Publication = null,
    retired: bool = false,
    pub fn publish(self: *Publications, publication: *const Publication) !?*const Publication {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (publication.value.stamp.connection != self.connection) return error.StaleProcess;
        if (publication.value.revision <= self.latest_revision) return error.StalePublication;
        const old = self.pending;
        self.pending = publication;
        self.retired = false;
        self.latest_revision = publication.value.revision;
        return old;
    }
    /// GUI only: exchange a previously taken view without freeing on frame.
    /// On null/error the caller still owns current and must keep displaying it.
    pub fn take(self: *Publications, current: ?*const Publication) !?*const Publication {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (self.pending == null) return null;
        if (self.retired) return null;
        const result = self.pending;
        self.pending = current;
        self.retired = current != null;
        return result;
    }
    /// Owner only; retire the GUI's old view outside the lock.
    pub fn collect(self: *Publications) !?*const Publication {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (!self.retired) return null;
        const result = self.pending;
        self.pending = null;
        self.retired = false;
        return result;
    }
    /// Owner lifecycle transition; rejects late results from the old worker.
    /// Retires the pending view via the caller; UI must also retire its old view
    /// before displaying the new connection. No network cancellation here.
    pub fn reset(self: *Publications, connection: u64) !?*const Publication {
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (connection <= self.connection) return error.StaleProcess;
        const old = self.pending;
        self.pending = null;
        self.retired = false;
        self.connection = connection;
        self.latest_revision = 0;
        return old;
    }
    pub fn deinit(self: *Publications) void {
        if (self.pending) |p| p.destroy();
        self.pending = null;
        self.retired = false;
    }
};

const fixture_stamp: Stamp = .{ .connection = 1, .session = 2, .process = 3, .pid = 42, .start_ticks = 10, .image_epoch = 4, .generation = 5 };
const FakeOwner = struct {
    lease: ?u64 = 7,
    calls: usize = 0,
    fn authorize(self: *@This(), request: Request) !void {
        if (request.actor == .agent and request.actor.agent.lease != self.lease) return error.ControlLeaseRequired;
        self.calls += 1;
    }
};
fn testRequest(action: Action) Request {
    return .{ .stamp = fixture_stamp, .actor = .human, .action = action };
}
test "owner queue preserves GUI MCP order and owns input" {
    var queue: Queue = .{};
    defer queue.deinit();
    var bytes = [_]u8{ 1, 2, 3 };
    const first = try Command.create(std.testing.allocator, testRequest(.{ .write_memory = .{ .address = 16, .bytes = &bytes } }));
    const seq = try queue.trySubmit(first);
    bytes[0] = 9;
    const second = try Command.create(std.testing.allocator, .{ .stamp = fixture_stamp, .actor = .{ .agent = .{ .client = 8, .lease = 7 } }, .action = .{ .mcp = .{ .name = "continue", .arguments_json = "{}" } } });
    try std.testing.expectEqual(seq + 1, try queue.trySubmit(second));
    const command = (try queue.take()).?;
    try std.testing.expectEqual(@as(u8, 1), command.request.action.write_memory.bytes[0]);
    try std.testing.expect((try queue.take()) == null);
    var owner: FakeOwner = .{};
    try command.validate(fixture_stamp, &owner);
    queue.finish();
    const next = (try queue.take()).?;
    owner.lease = null;
    try std.testing.expectError(error.ControlLeaseRequired, next.validate(fixture_stamp, &owner));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    queue.finish();
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
}
test "owner validates process epoch and generation at execution" {
    const command = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
    defer command.destroy();
    var owner: FakeOwner = .{};
    inline for (.{ "connection", "session", "process", "pid", "image_epoch", "generation" }) |field| {
        var current = fixture_stamp;
        @field(current, field) += 1;
        try std.testing.expectError(if (std.mem.eql(u8, field, "generation") or std.mem.eql(u8, field, "image_epoch")) error.StaleSnapshot else error.StaleProcess, command.validate(current, &owner));
    }
    var current = fixture_stamp;
    current.start_ticks = fixture_stamp.start_ticks.? + 1;
    try std.testing.expectError(error.StaleProcess, command.validate(current, &owner));
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
}
test "owner input is bounded including active command and contention is explicit" {
    var queue: Queue = .{};
    defer queue.deinit();
    const extra = try Command.create(std.testing.allocator, testRequest(.{ .control = .interrupt }));
    defer extra.destroy();
    for (0..max_commands) |_| {
        const c = try Command.create(std.testing.allocator, testRequest(.{ .control = .interrupt }));
        _ = try queue.trySubmit(c);
    }
    try std.testing.expectError(error.QueueFull, queue.trySubmit(extra));
    _ = try queue.take();
    try std.testing.expectError(error.QueueFull, queue.trySubmit(extra));
    queue.finish();
    try std.testing.expect(queue.mutex.tryLock());
    try std.testing.expectError(error.Busy, queue.trySubmit(extra));
    try std.testing.expectError(error.Busy, queue.take());
    queue.mutex.unlock();
    try queue.close();
    try std.testing.expectError(error.Closed, queue.trySubmit(extra));
}
test "publications retain nested strings and reject old worker and revision" {
    var publications: Publications = .{ .connection = fixture_stamp.connection };
    defer publications.deinit();
    var text = [_]u8{ 'o', 'l', 'd' };
    const view: View = .{ .session_id = 2, .generation = 5, .pid = 42, .architecture = "fixture", .state = "stopped", .scope = "observe", .owned = true, .frames = &.{.{ .index = 0, .pc = 16, .source = .{ .path = &text, .line = 1 } }} };
    const first = try Publication.create(std.testing.allocator, .{ .stamp = fixture_stamp, .revision = 1, .taken_ns = 1, .status = .ready, .view = view });
    try std.testing.expect((try publications.publish(first)) == null);
    const held = (try publications.take(null)).?;
    defer held.destroy();
    text[0] = 'X';
    const second = try Publication.create(std.testing.allocator, .{ .stamp = fixture_stamp, .revision = 2, .taken_ns = 2, .status = .pending });
    try std.testing.expect((try publications.publish(second)) == null);
    try std.testing.expectEqualStrings("old", held.value.view.?.frames[0].source.?.path);
    try std.testing.expectError(error.StalePublication, publications.publish(held));
    (try publications.reset(2)).?.destroy();
    try std.testing.expectError(error.StaleProcess, publications.publish(held));
    try std.testing.expect((try publications.take(null)) == null);
}
fn allocationFailure(a: Allocator) !void {
    const command = try Command.create(a, testRequest(.{ .mcp = .{ .name = "tool", .arguments_json = "{}" } }));
    defer command.destroy();
    const publication = try Publication.create(a, .{ .stamp = fixture_stamp, .revision = 1, .taken_ns = 0, .status = .failed, .diagnostic = "synthetic failure" });
    defer publication.destroy();
}
test "owner copies clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}

test "publication exchange retires on owner and preserves frame under contention" {
    var publications: Publications = .{ .connection = fixture_stamp.connection };
    defer publications.deinit();
    const first = try Publication.create(std.testing.allocator, .{ .stamp = fixture_stamp, .revision = 1, .taken_ns = 1, .status = .pending });
    _ = try publications.publish(first);
    const current = (try publications.take(null)).?;
    const second = try Publication.create(std.testing.allocator, .{ .stamp = fixture_stamp, .revision = 2, .taken_ns = 2, .status = .failed });
    _ = try publications.publish(second);
    const next = (try publications.take(current)).?;
    defer next.destroy();
    try std.testing.expect((try publications.take(next)) == null);
    try std.testing.expectEqual(@as(u64, 2), next.value.revision);
    const third = try Publication.create(std.testing.allocator, .{ .stamp = fixture_stamp, .revision = 3, .taken_ns = 3, .status = .disconnected });
    (try publications.publish(third)).?.destroy();
    try std.testing.expect((try publications.collect()) == null);
    try std.testing.expect(publications.mutex.tryLock());
    try std.testing.expectError(error.Busy, publications.take(next));
    publications.mutex.unlock();
}

test "owner queue enforces byte budget before and after take" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, max_command_bytes / 2);
    defer a.free(bytes);
    @memset(bytes, 7);
    var queue: Queue = .{};
    defer queue.deinit();
    const first = try Command.create(a, testRequest(.{ .write_memory = .{ .address = 0, .bytes = bytes } }));
    _ = try queue.trySubmit(first);
    const second = try Command.create(a, testRequest(.{ .write_memory = .{ .address = 0, .bytes = bytes } }));
    defer second.destroy();
    try std.testing.expectError(error.QueueFull, queue.trySubmit(second));
    _ = try queue.take();
    try std.testing.expectError(error.QueueFull, queue.trySubmit(second));
    queue.finish();
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    var remaining: usize = 1;
    try std.testing.expectError(error.TooLarge, payloadBytes(bytes, &remaining));
}

const FakeWorker = struct {
    queue: *Queue,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    saw: u64 = 0,
    fn run(self: *@This()) void {
        const command = (self.queue.take() catch unreachable).?;
        self.saw = command.sequence;
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        var owner: FakeOwner = .{};
        command.validate(fixture_stamp, &owner) catch unreachable;
        self.queue.finish();
    }
};
test "fake owner can hold an operation while frontend queues the next" {
    var queue: Queue = .{};
    defer queue.deinit();
    const first = try Command.create(std.testing.allocator, testRequest(.{ .control = .interrupt }));
    const sequence = try queue.trySubmit(first);
    var worker: FakeWorker = .{ .queue = &queue };
    const thread = try std.Thread.spawn(.{}, FakeWorker.run, .{&worker});
    defer thread.join();
    defer worker.release.store(true, .release);
    while (!worker.entered.load(.acquire)) std.atomic.spinLoopHint();
    const second = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
    try std.testing.expectEqual(sequence + 1, try queue.trySubmit(second));
    try std.testing.expectEqual(sequence, worker.saw);
}

test "inspection readiness rejects old selection at unchanged generation" {
    var view: Presentation = .{
        .stamp = fixture_stamp,
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .inspection_id = 10,
        .view = .{ .session_id = 2, .generation = 5, .pid = 42, .architecture = "fixture", .state = "stopped", .scope = "observe", .owned = true },
    };
    try std.testing.expect(view.matchesInspection(fixture_stamp, 10));
    try std.testing.expect(!view.matchesInspection(fixture_stamp, 11));
    view.status = .pending;
    try std.testing.expect(!view.matchesInspection(fixture_stamp, 10));
    view.status = .ready;
    view.view.?.generation -= 1;
    try std.testing.expect(!view.matchesInspection(fixture_stamp, 10));
}

test "poll pressure never consumes user capacity and retains owner order" {
    var queue: Queue = .{};
    defer queue.deinit();
    const active = try Command.create(std.testing.allocator, testRequest(.{ .control = .interrupt }));
    _ = try queue.trySubmit(active);
    _ = try queue.take();
    var poll_sequence: u64 = 0;
    for (0..1000) |i| {
        const poll = try Command.create(std.testing.allocator, testRequest(.poll));
        const sequence = try queue.trySubmit(poll);
        if (i == 0) poll_sequence = sequence else try std.testing.expectEqual(poll_sequence, sequence);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.count);
    for (0..max_commands - 1) |_| {
        const mutation = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
        _ = try queue.trySubmit(mutation);
    }
    const extra = try Command.create(std.testing.allocator, testRequest(.{ .control = .interrupt }));
    defer extra.destroy();
    try std.testing.expectError(error.QueueFull, queue.trySubmit(extra));
    queue.finish();
    const poll = (try queue.take()).?;
    try std.testing.expectEqual(poll_sequence, poll.sequence);
    try std.testing.expect(poll.request.action == .poll);
    // A poll requested during an active poll is one follow-up, after already
    // queued user commands. It never reuses a result which is being computed.
    var followup_sequence: u64 = 0;
    for (0..1000) |i| {
        const followup = try Command.create(std.testing.allocator, testRequest(.poll));
        const sequence = try queue.trySubmit(followup);
        if (i == 0) followup_sequence = sequence else try std.testing.expectEqual(followup_sequence, sequence);
    }
    queue.finish();
    for (0..max_commands - 1) |i| {
        const mutation = (try queue.take()).?;
        try std.testing.expectEqual(poll_sequence + i + 1, mutation.sequence);
        try std.testing.expect(mutation.request.action == .control);
        queue.finish();
    }
    try std.testing.expectEqual(followup_sequence, (try queue.take()).?.sequence);
    queue.finish();
    try std.testing.expect((try queue.take()) == null);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
}

test "poll coalescing refuses different identities actors and closed queue" {
    var queue: Queue = .{};
    defer queue.deinit();
    _ = try queue.trySubmit(try Command.create(std.testing.allocator, testRequest(.poll)));
    var request = testRequest(.poll);
    request.stamp.process += 1;
    const other = try Command.create(std.testing.allocator, request);
    defer other.destroy();
    try std.testing.expectError(error.PollPending, queue.trySubmit(other));
    request = testRequest(.poll);
    request.actor = .{ .agent = .{ .client = 8, .lease = 7 } };
    const agent = try Command.create(std.testing.allocator, request);
    defer agent.destroy();
    try std.testing.expectError(error.PollPending, queue.trySubmit(agent));
    try queue.close();
    try std.testing.expectError(error.Closed, queue.trySubmit(other));
}

test "process identity compares start times only when both are known" {
    var unknown = fixture_stamp;
    unknown.start_ticks = null;
    try std.testing.expect(unknown.sameProcess(fixture_stamp));
    try std.testing.expect(fixture_stamp.sameProcess(unknown));
    try std.testing.expect(unknown.sameProcess(unknown));
    var different = fixture_stamp;
    different.start_ticks = fixture_stamp.start_ticks.? + 1;
    try std.testing.expect(!fixture_stamp.sameProcess(different));
    different = unknown;
    different.connection += 1;
    try std.testing.expect(!unknown.sameProcess(different));
}
