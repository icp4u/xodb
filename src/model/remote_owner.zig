//! Remote-session ownership boundary. No live Target, Session, service pointer
//! or borrowed string crosses the command/publication exchange.
const std = @import("std");
const View = @import("../remote/view.zig").View;
const Allocator = std.mem.Allocator;
pub const max_commands = 64;
pub const max_command_bytes = 8 * 1024 * 1024;
pub const max_publication_bytes = 16 * 1024 * 1024;

const commands = @import("command.zig");
pub const Stamp = commands.Stamp;
pub const Actor = commands.Caller;
pub const Selection = commands.Selection;
pub const Control = commands.Control;
pub const Inspection = struct {
    request_id: u64, // Changes with selection, tab, expression or display options.
    selection: Selection,
    kind: enum { view, debugger, stack, locals, registers, disassembly, memory, expression, language },
    browse_address: ?u64 = null,
    browse_assembly: ?u64 = null,
    show_flow: bool = false,
    show_stop: bool = false,
    show_processes: bool = false,
    show_probes: bool = false,
    show_setup: bool = false,
    logical_frames: ?@import("frame_view.zig").Request = null,
    static_analysis: ?@import("static_view.zig").Request = null,
    runtime_types: ?@import("runtime_type_view.zig").Request = null,
    invocations: ?@import("invocation_view.zig").Request = null,
    allocations: ?@import("allocation_view.zig").Request = null,
    profile: ?@import("profile_view.zig").Request = null,
    timeline: ?@import("../ui/timeline.zig").Request = null,
    sample: ?@import("sample_view.zig").Request = null,
    syscalls: ?@import("syscall_view.zig").Request = null,
    memory: ?@import("inspection_view.zig").Request = null,
    inline_scope: ?@import("inline_view.zig").Request = null,
    binding_start: usize = 0,
    language_selection: ?@import("language_view.zig").SelectedKey = null,
    address: u64 = 0,
    limit: usize = 0,
    text: []const u8 = "",
};
pub const Action = union(enum) {
    poll,
    inspect: Inspection,
    control: Control,
    language: @import("language_view.zig").Action,
    runtime_watch: @import("runtime_watch_view.zig").Action,
    native_watch: @import("native_watches.zig").Action,
    memory_action: @import("inspection_view.zig").Action,
    inline_expression: @import("inline_view.zig").Expression,
    process: @import("process_view.zig").Operation,
    probe_policy: @import("probe_view.zig").Request,
    allocation: @import("allocation_view.zig").Action,
    capture_control: @import("capture_view.zig").Action,
    logical_frames: @import("frame_view.zig").Action,
    static_cancel: u64,
    runtime_type: @import("runtime_type_view.zig").Action,
    invocation: @import("invocation_view.zig").Action,
    workspace: @import("workspace_view.zig").Action,
    toggle_scope,
    breakpoint: commands.Breakpoint,
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
pub const Request = struct {
    stamp: Stamp,
    actor: Actor,
    action: Action,
    /// Trusted adapter metadata, independent of the operation's semantic tag.
    protocol_reply: bool = false,
};

// C register storage uses an untagged union of fixed-size values. It can be
// copied as a value only when every alternative is pointer-free; no inactive
// pointer or slice may evade the recursive payload budget.
fn requirePlainValue(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("untagged message unions must be pointer-free"),
        .optional => |o| requirePlainValue(o.child),
        .array => |v| requirePlainValue(v.child),
        .@"struct" => |s| inline for (s.fields) |f| requirePlainValue(f.type),
        .@"union" => |u| inline for (u.fields) |f| requirePlainValue(f.type),
        else => {},
    }
}
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
        .@"union" => |u| if (u.tag_type == null) {
            comptime requirePlainValue(@TypeOf(value));
        } else switch (value) {
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
        .@"union" => |u| if (u.tag_type == null) blk: {
            comptime requirePlainValue(T);
            break :blk value;
        } else switch (value) {
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
/// Bounded deep copy for an owner-prepared const view. Callers own the arena;
/// this helper never belongs on the frame/publication-exchange path.
pub fn copyView(a: Allocator, value: anytype) !@TypeOf(value) {
    comptime {
        @setEvalBranchQuota(20000);
        @import("debugger_view.zig").requireImmutable(@TypeOf(value));
    }
    var remaining: usize = max_publication_bytes;
    try payloadBytes(value, &remaining);
    return copyOwned(a, value);
}
pub const Command = struct {
    arena: std.heap.ArenaAllocator,
    request: Request,
    bytes: usize,
    sequence: u64 = 0,
    pub fn urgent(self: *const Command) bool {
        const action = self.request.action;
        return action == .toggle_scope or (action == .control and
            (action.control == .interrupt or action.control == .cancel_continue));
    }
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
        // A GUI inspection/control refers to the displayed stop. MCP ingress
        // instead preserves each tool's existing contract: get_session reads
        // the execution-time snapshot, while mutations validate the caller's
        // generation in the authoritative handler. Lease/job operations may
        // not refer to a target stop at all. Process identity still pins both.
        const old_view_allowed = self.request.action == .control and
            (self.request.action.control == .interrupt or self.request.action.control == .cancel_continue);
        if (!old_view_allowed and self.request.action != .poll and self.request.action != .mcp and self.request.action != .toggle_scope and
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
    // One reservation per caller class: a protocol stop cannot occupy the
    // human's F8/revoke slot. Human urgency wins, without preempting an active
    // backend operation or coalescing mutations. Not one slot per client.
    urgent_pending: [2]?*Command = @splat(null),
    // A protocol client resubmitting stops cannot starve ordinary work: after
    // a protocol urgent turn, ready ordinary work (or a poll) goes once first.
    protocol_urgent_last: bool = false,
    bytes: usize = 0,
    next_sequence: u64 = 1,
    closed: std.atomic.Value(bool) = .init(false),
    pub fn trySubmit(self: *Queue, command: *Command) !u64 {
        var coalesced: ?*Command = null;
        defer if (coalesced) |c| c.destroy(); // After unlocking; success owns input.
        if (!self.mutex.tryLock()) return error.Busy;
        defer self.mutex.unlock();
        if (self.closed.load(.acquire)) return error.Closed;
        if (command.sequence != 0) return error.AlreadySubmitted;
        if (command.request.action == .poll) {
            if (self.poll_pending) |pending| {
                if (!pending.request.stamp.sameProcess(command.request.stamp) or
                    !std.meta.eql(pending.request.actor, command.request.actor)) return error.PollPending;
                coalesced = command;
                return pending.sequence;
            }
        } else if (command.urgent()) {
            if (self.urgent_pending[urgentClass(command)] != null) return error.QueueFull;
        } else {
            const active_count: usize = if (self.active) |c| @intFromBool(c.request.action != .poll and !c.urgent()) else 0;
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
        if (command.urgent()) {
            self.urgent_pending[urgentClass(command)] = command;
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
        for (&self.urgent_pending, 0..) |*pending, class| if (pending.*) |urgent| {
            if (class == 1 and self.protocol_urgent_last and (self.count > 0 or self.poll_pending != null)) break;
            self.active = urgent;
            pending.* = null;
            self.protocol_urgent_last = class == 1;
            return urgent;
        };
        if (self.poll_pending) |poll| {
            // Coalescing retains the first request's place in owner order.
            if (self.count == 0 or poll.sequence < self.slots[self.head].?.sequence) {
                self.active = poll;
                self.poll_pending = null;
                self.protocol_urgent_last = false;
                return poll;
            }
        }
        if (self.count == 0) return null;
        self.protocol_urgent_last = false;
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
        if (command.request.action != .poll and !command.urgent()) self.bytes -= command.bytes;
        self.mutex.unlock();
        command.destroy();
    }
    /// Stop accepting commands; queued commands still require explicit failed
    /// completions. This does not interrupt a transport or confirm detach.
    pub fn close(self: *Queue) !void {
        self.closed.store(true, .release);
    }
    /// After owner/producer shutdown only; never join or free on the frame.
    pub fn deinit(self: *Queue) void {
        if (self.active) |command| command.destroy();
        if (self.poll_pending) |command| command.destroy();
        for (self.urgent_pending) |command| if (command) |c| c.destroy();
        for (self.slots) |command| if (command) |c| c.destroy();
        self.* = .{};
    }
    fn urgentClass(command: *const Command) usize {
        return if (command.request.actor == .human) 0 else 1;
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
    debugger: ?@import("debugger_view.zig").Presentation = null,
    language: ?@import("language_view.zig").Presentation = null,
    runtime_watches: ?@import("runtime_watch_view.zig").View = null,
    native_watches: ?@import("native_watches.zig").View = null,
    stop: ?@import("stop_view.zig").View = null,
    memory: ?@import("inspection_view.zig").View = null,
    inline_scope: ?@import("inline_view.zig").View = null,
    processes: ?@import("process_view.zig").View = null,
    probes: ?@import("probe_view.zig").View = null,
    allocations: ?@import("allocation_view.zig").View = null,
    profile: ?@import("profile_view.zig").View = null,
    capture_control: ?@import("capture_view.zig").View = null,
    logical_frames: ?@import("frame_view.zig").View = null,
    static_analysis: ?@import("static_view.zig").View = null,
    runtime_types: ?@import("runtime_type_view.zig").View = null,
    invocations: ?@import("invocation_view.zig").View = null,
    workspace: ?@import("workspace_view.zig").Header = null,
    timeline: ?@import("../ui/timeline.zig").Prepared = null,
    sample: ?@import("sample_view.zig").View = null,
    syscalls: ?@import("syscall_view.zig").View = null,
    diagnostic: []const u8 = "",
    omitted: u64 = 0,
    debugger_omitted: u32 = 0,
    pub fn matchesInspection(self: Presentation, expected: Stamp, request_id: u64) bool {
        const identity = self.status == .ready and self.inspection_id == request_id and
            self.stamp.sameProcess(expected) and self.stamp.image_epoch == expected.image_epoch and
            self.stamp.generation == expected.generation;
        if (!identity) return false;
        if (self.language) |view| return view.header.generation == expected.generation and view.header.session == expected.session;
        if (self.debugger) |view| return view.snapshot.generation == expected.generation and view.snapshot.pid == expected.pid;
        if (self.view) |view| return view.generation == expected.generation and view.session_id == expected.session and view.pid == expected.pid;
        return false;
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
    /// Target-sized panes degrade independently. No partial copy is published;
    /// create still checks the complete resulting payload before allocation.
    pub fn createDegraded(a: Allocator, original: Presentation) !*const Publication {
        var value = original;
        // Leave room for fixed fallback strings and the publication header.
        var remaining: usize = max_publication_bytes - @sizeOf(Publication) - 4096;
        inline for (@typeInfo(Presentation).@"struct".fields, 0..) |field, index| {
            if (comptime std.mem.eql(u8, field.name, "debugger")) {
                if (value.debugger) |*debugger| {
                    const empty: @import("debugger_view.zig").Presentation = .{};
                    inline for (@typeInfo(@TypeOf(empty)).@"struct".fields, 0..) |part, part_index| {
                        var available = remaining;
                        if (payloadBytes(@field(debugger, part.name), &available)) {
                            remaining = available;
                        } else |_| {
                            @field(debugger, part.name) = @field(empty, part.name);
                            value.debugger_omitted |= @as(u32, 1) << part_index;
                        }
                    }
                    if (value.debugger_omitted != 0) debugger.local_diagnostic = if (debugger.locals.len == 0) "View limit: omitted data is listed below" else debugger.local_diagnostic;
                }
            } else {
                var available = remaining;
                if (payloadBytes(@field(value, field.name), &available)) {
                    remaining = available;
                } else |_| {
                    if (comptime std.mem.eql(u8, field.name, "workspace")) {
                        // Routing and authority facts must survive even when
                        // a variable metadata string exceeds the pane limit.
                        var header = value.workspace.?;
                        header.metadata = null;
                        header.frame_failure = null;
                        header.frame_state = "";
                        value.workspace = header;
                        value.omitted |= @as(u64, 1) << index;
                    } else if (comptime @typeInfo(field.type) == .optional) {
                        @field(value, field.name) = null;
                        value.omitted |= @as(u64, 1) << index;
                    } else if (comptime std.mem.eql(u8, field.name, "diagnostic")) {
                        value.diagnostic = "Remote diagnostic exceeds the view limit";
                        value.omitted |= @as(u64, 1) << index;
                    } else unreachable; // All other fields are fixed-size values.
                }
            }
        }
        if (value.omitted != 0 or value.debugger_omitted != 0) value.status = .failed;
        return create(a, value);
    }
    pub fn destroy(self: *const Publication) void {
        const owned = @constCast(self);
        const a = owned.arena.child_allocator;
        owned.arena.deinit();
        a.destroy(owned);
    }
};

test "debugger publication retains source inline frames and target rows" {
    var source = [_]u8{ 'a', '\n' };
    var name = [_]u8{ 'f', 'n' };
    var inlines = [_]@import("../debug/info.zig").Inline{.{ .name = &name, .depth = 1, .die_offset = 9 }};
    var frames = [_]@import("session.zig").Frame{.{ .index = 0, .pc = 1, .lookup_pc = 1, .registers = @splat(null), .symbol = &name, .inline_frames = &inlines }};
    var threads = [_]@import("../target/linux.zig").Thread{.{ .id = 3, .tid = 7, .state = .stopped }};
    var labels = [_]@import("compatibility.zig").Label{.{ .id = 3, .tid = 7, .source = .gdb_thread_info, .dispatch_queue = 0x1234, .readable = true }};
    @memcpy(labels[0].name[0..6], "worker");
    const publication = try Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 7, .image_epoch = 1, .generation = 2 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .inspection_id = 3,
        .debugger = .{ .snapshot = .{ .pid = 7, .generation = 2 }, .source = .{ .bytes = &source, .path = "sample.c" }, .frames = &frames, .threads = &threads, .thread_labels = &labels, .compatibility = .{ .kind = .wine } },
    });
    defer publication.destroy();
    @memset(&source, 'x');
    @memset(&name, 'x');
    inlines[0].depth = 4;
    frames[0].pc = 99;
    threads[0].state = .running;
    labels[0].name[0] = 'x';
    labels[0].dispatch_queue = 0;
    const view = publication.value.debugger.?;
    try std.testing.expectEqualStrings("a\n", view.source.bytes);
    try std.testing.expectEqualStrings("fn", view.frames[0].inline_frames[0].name);
    try std.testing.expectEqual(@as(usize, 1), view.frames[0].inline_frames[0].depth);
    try std.testing.expectEqual(@as(u64, 1), view.frames[0].pc);
    try std.testing.expectEqual(@import("../target/linux.zig").State.stopped, view.threads[0].state);
    try std.testing.expectEqualStrings("worker", view.thread_labels[0].text());
    try std.testing.expectEqual(@as(?u64, 0x1234), view.thread_labels[0].dispatch_queue);
    // The painter's Wine header comes only from this publication.
    var title: [192]u8 = undefined;
    try std.testing.expectEqualStrings("Windows process under Wine", view.compatibility.title(&title));
    try std.testing.expect(publication.value.matchesInspection(publication.value.stamp, 3));
}
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
test "protocol ingress retains identity while tool handlers own stop freshness" {
    const a = std.testing.allocator;
    const command = try Command.create(a, .{ .stamp = fixture_stamp, .actor = .{ .agent = .{ .client = 8, .lease = 7 } }, .action = .{ .mcp = .{ .name = "get_session", .arguments_json = "{}" } } });
    defer command.destroy();
    var owner: FakeOwner = .{};
    var current = fixture_stamp;
    current.generation += 1;
    current.image_epoch += 1;
    try command.validate(current, &owner);
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    current.connection += 1;
    try std.testing.expectError(error.StaleProcess, command.validate(current, &owner));
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
    const inspection = try Command.create(a, testRequest(.{ .inspect = .{ .request_id = 1, .selection = .{ .tid = 42 }, .kind = .view } }));
    defer inspection.destroy();
    current.connection = fixture_stamp.connection;
    try std.testing.expectError(error.StaleSnapshot, inspection.validate(current, &owner));
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
    const extra = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
    defer extra.destroy();
    for (0..max_commands) |_| {
        const c = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
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
    const first = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
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
    const active = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
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
    const extra = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
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

test "language publication owns header rows and nested binding values" {
    const prepared = @import("language_view.zig");
    const named = @import("language_locals.zig");
    const Session = @import("session.zig").Session;
    var session = Session.init();
    defer session.deinit();
    session.id = fixture_stamp.session;
    var state = prepared.header(&session);
    state.generation = fixture_stamp.generation;
    state.state = .stopped;
    state.selected = .ruby;
    var text = [_]u8{ 'k', 'e', 'p', 't' };
    state.entries[@intFromEnum(state.selected) - 2] = .{ .present = true, .version = &text };
    var rows = [_]prepared.Row{.{ .name = &text, .location = &text, .reason = null, .segment = 0, .frame = 1 }};
    var children = [_]named.Child{.{ .key = &text, .type = "String", .display = &text, .address = null, .diagnostic = null, .advisory = false }};
    var bindings = [_]named.Row{.{ .name = &text, .scope = .local, .ordinal = 0, .address = null, .value = .{ .type = "Array", .display = &text, .children = &children } }};
    const publication = try Publication.create(std.testing.allocator, .{
        .stamp = fixture_stamp,
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .inspection_id = 17,
        .language = .{
            .header = state,
            .key = state.key(42, 0),
            .rows = &rows,
            .expression = &text,
            .bindings = .{ .generation = fixture_stamp.generation, .tid = 42, .language = .ruby, .segment = 0, .frame = 1, .start = 0, .total = 1, .truncated = false, .rows = &bindings, .diagnostic = null, .runtime_version = &text, .runtime_build_id = &text, .basis = &text, .memory_reads = 1, .memory_bytes = 8 },
        },
    });
    defer publication.destroy();
    @memset(&text, 'x');
    rows[0].frame = 9;
    children[0].advisory = true;
    bindings[0].hidden = true;
    const view = publication.value.language.?;
    try std.testing.expectEqualStrings("kept", view.header.entries[@intFromEnum(view.header.selected) - 2].version);
    try std.testing.expectEqualStrings("kept", view.rows[0].name);
    try std.testing.expectEqual(@as(?usize, 1), view.rows[0].frame);
    try std.testing.expectEqualStrings("kept", view.expression);
    try std.testing.expectEqualStrings("kept", view.bindings.?.runtime_build_id);
    try std.testing.expectEqualStrings("kept", view.bindings.?.rows[0].value.children[0].display);
    try std.testing.expect(!view.bindings.?.rows[0].hidden);
    try std.testing.expect(!view.bindings.?.rows[0].value.children[0].advisory);
    try std.testing.expect(publication.value.matchesInspection(fixture_stamp, 17));
    var changed = fixture_stamp;
    changed.session += 1;
    try std.testing.expect(!publication.value.matchesInspection(changed, 17));
}

test "oversized panes do not discard fitting panes or publication identity" {
    const a = std.testing.allocator;
    const large = try a.alloc(u8, max_publication_bytes);
    defer a.free(large);
    @memset(large, 'x');
    const language_header: @import("language_view.zig").Header = .{ .session = 1, .generation = 2, .metadata = 0, .revision = 0, .state = .stopped, .selected = .native, .native_selection = null, .logical_selection = null };
    const original: Presentation = .{
        .stamp = fixture_stamp,
        .revision = 9,
        .taken_ns = 8,
        .status = .ready,
        .inspection_id = 7,
        .debugger = .{ .source = .{ .bytes = large }, .local_diagnostic = "retained local diagnostic", .snapshot = .{ .generation = 2 } },
        .language = .{ .header = language_header, .key = language_header.key(0, 0), .message = large },
        .workspace = .{ .process = 3, .scope = .control, .frame_failure = large },
        .runtime_watches = .{},
        .diagnostic = "retained diagnostic",
    };
    try std.testing.expectError(error.TooLarge, Publication.create(a, original));
    const publication = try Publication.createDegraded(a, original);
    defer publication.destroy();
    const value = publication.value;
    try std.testing.expectEqual(fixture_stamp, value.stamp);
    try std.testing.expectEqual(@as(?u64, 7), value.inspection_id);
    try std.testing.expectEqual(@as(u64, 9), value.revision);
    try std.testing.expectEqual(@as(u64, 2), value.debugger.?.snapshot.generation);
    try std.testing.expectEqual(@as(usize, 0), value.debugger.?.source.bytes.len);
    try std.testing.expect(value.language == null);
    try std.testing.expectEqual(@as(u64, 3), value.workspace.?.process);
    try std.testing.expectEqual(.control, value.workspace.?.scope);
    try std.testing.expect(value.workspace.?.frame_failure == null);
    try std.testing.expect(value.runtime_watches != null);
    try std.testing.expect(value.omitted != 0 and value.debugger_omitted != 0);
    try std.testing.expectEqual(.failed, value.status);
    try std.testing.expectEqualStrings("retained diagnostic", value.diagnostic);
    try std.testing.expect(publication.bytes < max_publication_bytes);
}

test "pane budget is aggregate and a rejected pane leaves room for later panes" {
    const a = std.testing.allocator;
    const part = try a.alloc(u8, max_publication_bytes / 2);
    defer a.free(part);
    @memset(part, 'y');
    const publication = try Publication.createDegraded(a, .{
        .stamp = fixture_stamp,
        .revision = 1,
        .taken_ns = 0,
        .status = .ready,
        .debugger = .{ .source = .{ .bytes = part } },
        .workspace = .{ .frame_failure = part },
        .diagnostic = "a smaller later pane still fits",
    });
    defer publication.destroy();
    try std.testing.expectEqual(part.len, publication.value.debugger.?.source.bytes.len);
    try std.testing.expect(publication.value.workspace.?.frame_failure == null);
    try std.testing.expectEqualStrings("a smaller later pane still fits", publication.value.diagnostic);
    try std.testing.expect(publication.bytes < max_publication_bytes);
}

test "old-view interrupt and revocation keep reserved admission under queue pressure" {
    var queue: Queue = .{};
    defer queue.deinit();
    for (0..max_commands) |_| {
        const mutation = try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution }));
        _ = try queue.trySubmit(mutation);
    }
    var owner: FakeOwner = .{};
    var current = fixture_stamp;
    current.generation += 1;
    current.image_epoch += 1;
    inline for (.{ Action{ .control = .interrupt }, Action.toggle_scope }) |action| {
        const urgent = try Command.create(std.testing.allocator, testRequest(action));
        _ = try queue.trySubmit(urgent);
        const taken = (try queue.take()).?;
        try std.testing.expect(taken == urgent);
        try taken.validate(current, &owner);
        queue.finish();
    }
    const mutation = (try queue.take()).?;
    try std.testing.expectError(error.StaleSnapshot, mutation.validate(current, &owner));
    queue.finish();
    try std.testing.expectEqual(@as(usize, 2), owner.calls);
}

test "protocol urgency cannot occupy or overtake the human reservation" {
    var queue: Queue = .{};
    defer queue.deinit();
    for (0..max_commands) |_| {
        _ = try queue.trySubmit(try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution })));
    }
    var protocol = testRequest(.{ .control = .interrupt });
    protocol.actor = .{ .agent = .{ .client = 1, .lease = null } };
    const agent_stop = try Command.create(std.testing.allocator, protocol);
    _ = try queue.trySubmit(agent_stop);
    // A second client shares the protocol reservation; it cannot grow it.
    protocol.actor.agent.client = 2;
    const duplicate = try Command.create(std.testing.allocator, protocol);
    defer duplicate.destroy();
    try std.testing.expectError(error.QueueFull, queue.trySubmit(duplicate));
    var human = testRequest(.toggle_scope);
    human.actor = .human;
    const revoke = try Command.create(std.testing.allocator, human);
    _ = try queue.trySubmit(revoke);
    try std.testing.expect((try queue.take()).? == revoke);
    queue.finish();
    try std.testing.expect((try queue.take()).? == agent_stop);
    queue.finish();
    try std.testing.expectEqual(max_commands, queue.count);
}

test "a protocol client resubmitting stops cannot starve ordinary commands" {
    var queue: Queue = .{};
    defer queue.deinit();
    for (0..3) |_| _ = try queue.trySubmit(try Command.create(std.testing.allocator, testRequest(.{ .control = .continue_execution })));
    var protocol = testRequest(.{ .control = .interrupt });
    protocol.actor = .{ .agent = .{ .client = 1, .lease = null } };
    var ordinary: usize = 0;
    for (0..6) |_| {
        // The client resubmits as soon as its reservation is free.
        if (queue.urgent_pending[1] == null) _ = try queue.trySubmit(try Command.create(std.testing.allocator, protocol));
        const taken = (try queue.take()).?;
        if (!taken.urgent()) ordinary += 1;
        queue.finish();
    }
    try std.testing.expectEqual(@as(usize, 3), ordinary);
    // A human stop still goes first, ahead of the pending protocol stop.
    try std.testing.expect(queue.urgent_pending[1] != null);
    var human = testRequest(.toggle_scope);
    human.actor = .human;
    const revoke = try Command.create(std.testing.allocator, human);
    _ = try queue.trySubmit(revoke);
    try std.testing.expect((try queue.take()).? == revoke);
    queue.finish();
}
