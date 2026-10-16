const std = @import("std");
const log = @import("../log.zig");
const c = @import("../c.zig").api;
const Session = @import("../model/session.zig").Session;
const disasm = @import("../model/disassembly.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const shared_context = @import("shared_context.zig");
const tool_definitions = @import("tool_catalog.zig").native_definitions;
const overview = @import("overview.zig");
fn member(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
fn string(value: ?Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}
fn number(value: ?Value) ?u64 {
    const v = value orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}
fn asValue(a: Allocator, value: anytype) !Value {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    return (try std.json.parseFromSlice(Value, a, text, .{ .allocate = .alloc_always })).value;
}
fn address(args: Value) !u64 {
    const text = string(member(args, "address")) orelse return error.InvalidArguments;
    return std.fmt.parseInt(u64, if (std.mem.startsWith(u8, text, "0x")) text[2..] else text, 16) catch error.InvalidArguments;
}

// Only read_memory accepts numeric addresses; mutation and breakpoint parsers
// retain their existing contracts. Reject integers that a JSON client may have
// rounded before sending them, even if Zig can represent the received value.
fn readAddress(args: Value) !u64 {
    const value = member(args, "address") orelse return error.AddressRequiredUseHexStringOrSafeInteger;
    return switch (value) {
        .integer => |n| if (n >= 0 and n <= 9007199254740991) @intCast(n) else error.AddressIntegerOutOfSafeRangeUseHexString,
        .string => address(args) catch error.InvalidHexAddress,
        else => error.AddressMustBeHexStringOrSafeInteger,
    };
}

test "read addresses preserve hex width and reject unsafe JSON integers" {
    var args = Value{ .object = .empty };
    defer args.object.deinit(std.testing.allocator);
    try std.testing.expectError(error.AddressRequiredUseHexStringOrSafeInteger, readAddress(args));
    try args.object.put(std.testing.allocator, "address", .{ .integer = 9007199254740991 });
    try std.testing.expectEqual(@as(u64, 9007199254740991), try readAddress(args));
    try args.object.put(std.testing.allocator, "address", .{ .integer = 9007199254740992 });
    try std.testing.expectError(error.AddressIntegerOutOfSafeRangeUseHexString, readAddress(args));
    try args.object.put(std.testing.allocator, "address", .{ .string = "0xffffffffffffffff" });
    try std.testing.expectEqual(std.math.maxInt(u64), try readAddress(args));
    // The shared parser used by writes/breakpoints retains hex-only input.
    try args.object.put(std.testing.allocator, "address", .{ .integer = 42 });
    try std.testing.expectError(error.InvalidArguments, address(args));
}

pub const Server = struct {
    shared: ?shared_context.Context = null,
    owner_queue: ?*@import("../model/remote_owner.zig").Queue = null,
    owner_connection: u64 = 0,
    pending_sequence: ?u64 = null,
    pending_line_bytes: usize = 0,
    owner_batch_remaining: usize = 0,
    policies: std.StringHashMapUnmanaged(shared_context.Policy) = .empty,
    policy_definitions: ?[]const u8 = null,
    request_limit: usize = 8,
    transmitted: u64 = 0,
    reported_revision: ?u64 = null,
    /// A sentence for the error being returned; lives in the request arena.
    error_detail: ?[]const u8 = null,
    input: [65536]u8 = undefined,
    used: usize = 0,
    // Accommodates a full 1024-thread session plus capture in a single reply.
    output: [1048576]u8 = undefined,
    queued: usize = 0,
    sent: usize = 0,
    closed: bool = false,
    input_eof: bool = false,
    negotiated: bool = false,
    initialized: bool = false,
    stdout_flags: c_int = 0,
    input_fd: c_int = 0,
    output_fd: c_int = 1,
    source_path: ?[:0]const u8 = null,
    reported_scope: ?@import("../model/session.zig").AgentScope = null,
    overview: overview.State = .{},
    overview_shared: ?*overview.State = null,
    overview_only: bool = false,
    overview_capture: ?*const ?*Session = null,
    private_access: @import("evidence.zig").PrivateAccess = .init(.remote, false),
    pub fn overviewTick(self: *Server) !void {
        if (self.overview_shared == null) _ = try self.overview.tick(@import("../target/linux.zig").now(), 0, false);
    }
    pub fn init(self: *Server) !void {
        self.stdout_flags = c.fcntl(self.output_fd, c.F_GETFL);
        if (self.stdout_flags < 0 or c.fcntl(self.output_fd, c.F_SETFL, self.stdout_flags | c.O_NONBLOCK) < 0) return error.McpOutputUnavailable;
    }
    pub fn deinit(self: *Server) void {
        _ = c.fcntl(self.output_fd, c.F_SETFL, self.stdout_flags);
        self.overview.deinit();
        self.clearPolicies();
    }
    fn clearPolicies(self: *Server) void {
        var keys = self.policies.keyIterator();
        while (keys.next()) |key| std.heap.c_allocator.free(key.*);
        self.policies.deinit(std.heap.c_allocator);
        self.policies = .empty;
        self.policy_definitions = null;
    }
    fn toolPolicy(self: *Server, definitions: []const u8, name: []const u8) !shared_context.Policy {
        // Cache only immutable schema metadata. Scope and lease are checked on
        // every call; mode changes rebuild the table before looking up a tool.
        if (self.policy_definitions == null or self.policy_definitions.?.ptr != definitions.ptr) {
            self.clearPolicies();
            errdefer self.clearPolicies();
            const a = std.heap.c_allocator;
            const parsed = try std.json.parseFromSlice(Value, a, definitions, .{});
            defer parsed.deinit();
            for (parsed.value.array.items) |definition| {
                const key = string(member(definition, "name")) orelse return error.MissingToolName;
                const policy = try shared_context.Policy.fromDefinition(definition);
                if (self.policies.contains(key)) return error.DuplicateToolName;
                const owned = try a.dupe(u8, key);
                errdefer a.free(owned);
                try self.policies.put(a, owned, policy);
            }
            self.policy_definitions = definitions;
        }
        return self.policies.get(name) orelse error.UnknownTool;
    }
    fn queue(self: *Server, given: []const u8) !void {
        // --redact: every string of every reply, one place for all tools.
        const scrubbed = if (@import("../redact.zig").active()) |policy| try policy.scrubJson(std.heap.page_allocator, given, "id") else null;
        defer if (scrubbed) |bytes| std.heap.page_allocator.free(bytes);
        const bytes = scrubbed orelse given;
        if (self.sent > 0) {
            std.mem.copyForwards(u8, &self.output, self.output[self.sent..self.queued]);
            self.queued -= self.sent;
            self.sent = 0;
        }
        if (bytes.len + 1 > self.output.len - self.queued) return error.McpClientNotReading;
        log.trace(.mcp, "mcp out: {d} bytes\n", .{bytes.len});
        @memcpy(self.output[self.queued..][0..bytes.len], bytes);
        self.queued += bytes.len;
        self.output[self.queued] = '\n';
        self.queued += 1;
    }
    fn reply(self: *Server, a: Allocator, id: Value, result: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
        if (bytes.len >= self.output.len) {
            try self.failure(a, id, -32000, "McpResponseTooLarge: request a smaller page or range");
            return;
        }
        try self.queue(bytes);
    }
    fn failure(self: *Server, a: Allocator, id: Value, code: i32, message: []const u8) !void {
        try self.queue(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}));
    }
    /// A source line that was not found: when the search left images unread
    /// for a budget, the reply says how many and names the first, so "no
    /// code" is not taken for an answer about all of them.
    fn lineError(self: *Server, a: Allocator, session: *Session, err: anyerror) anyerror {
        if (err != error.NoCodeForSourceLine) return err;
        const skipped = session.modules.skipped();
        if (skipped.first) |first| self.error_detail = std.fmt.allocPrint(a, "{d} images not searched; {s}", .{ skipped.count, first }) catch null;
        return err;
    }
    /// Owner-thread entry for queued protocol work. The caller resolves the
    /// server from the accepted connection, never from request JSON. A queued
    /// controller command cannot acquire a replacement lease while waiting.
    pub fn queuedTool(self: *Server, a: Allocator, root: *Session, actor: @import("../model/remote_owner.zig").Actor, name: []const u8, args: Value) !Value {
        if (actor != .agent) return error.ProtocolActorRequired;
        const agent = actor.agent;
        if (self.shared) |peer| {
            if (agent.client != peer.client_id) return error.UnknownSessionClient;
            try peer.tick(root);
            try shared_context.check(shared_context.c.xsvc_authorize(peer.service, peer.client_id, shared_context.c.XSVC_OBSERVE, @import("../target/linux.zig").now()));
            if (!shared_context.handles(name)) {
                const access_ = (try self.toolPolicy(if (self.overview_only) overview.definitions else if (root.imported != null) @import("imported.zig").definitions else tool_definitions, name)).required;
                if (access_ == .controller or access_ == .mutator) {
                    try peer.authorize(access_ == .mutator);
                    const lease = @import("../service/lease.zig").Lease.capture(peer.service, peer.client_id) orelse return error.ControlLeaseRequired;
                    if (agent.lease != lease.id) return error.ControlLeaseRequired;
                }
            }
        } else if (agent.client != 0 or agent.lease != null) return error.UnknownSessionClient;
        self.error_detail = null;
        return self.tool(a, root, name, args);
    }
    fn enqueueTool(self: *Server, a: Allocator, root: *Session, name: []const u8, args: Value, line_bytes: usize) !void {
        if (args != .object) return error.InvalidArguments;
        if (self.overview_only and !overview.handles(name) and !std.mem.eql(u8, name, "get_session_clients") and !std.mem.eql(u8, name, "get_session_events")) return error.UnknownTool;
        if (self.shared) |peer| try peer.tick(root);
        if (self.shared == null or !shared_context.handles(name)) _ = try self.authorizeTool(root, name);
        const boundary = @import("../model/remote_owner.zig");
        const process_id = try @import("profile.zig").number(args, "process_id", root.process_id);
        const session = if (root.process_tree) |tree| (try tree.find(process_id)).session else if (process_id == root.process_id) root else return error.UnknownProcess;
        const snapshot = session.target.snapshot();
        const actor: boundary.Actor = if (self.shared) |peer| .{ .agent = .{
            .client = peer.client_id,
            .lease = if (@import("../service/lease.zig").Lease.capture(peer.service, peer.client_id)) |lease| lease.id else null,
        } } else .{ .agent = .{ .client = 0, .lease = null } };
        const commands = @import("commands.zig");
        const decoded = if (commands.handles(name)) try commands.decode(name, args) else null;
        const command = try boundary.Command.create(std.heap.page_allocator, .{
            // This stamp protects time spent in our queue. The ordinary tool
            // handler separately interprets/validates its generation argument;
            // lease tools, for example, do not mutate a target generation.
            .stamp = .{ .connection = self.owner_connection, .session = session.id, .process = process_id, .pid = snapshot.pid, .image_epoch = snapshot.image_epoch, .generation = if (decoded) |typed| typed.generation else snapshot.generation },
            .actor = actor,
            .action = if (decoded) |typed| switch (typed.operation) {
                .control => |control| .{ .control = control },
                .breakpoint => |bp| .{ .breakpoint = bp },
            } else .{ .mcp = .{ .name = name, .arguments_json = try std.json.Stringify.valueAlloc(a, args, .{}) } },
            .protocol_reply = true,
        });
        errdefer command.destroy();
        self.pending_sequence = self.owner_queue.?.trySubmit(command) catch |err| switch (err) {
            error.Busy, error.QueueFull => return error.OwnerQueueBusy,
            else => return err,
        };
        self.pending_line_bytes = line_bytes;
        if (self.owner_batch_remaining == 0) self.owner_batch_remaining = @max(1, self.request_limit);
    }
    /// Preserve a bounded already-buffered MCP batch before admitting a new
    /// periodic poll. Backpressure never holds polling, and an admitted poll
    /// keeps its original queue order.
    pub fn ownerBatchContinuation(self: *const Server) bool {
        return self.owner_queue != null and self.pending_sequence != null and self.queued == 0 and
            self.pending_line_bytes <= self.used and
            std.mem.indexOfScalar(u8, self.input[self.pending_line_bytes..self.used], '\n') != null;
    }
    fn consumeInput(self: *Server, consumed: usize) void {
        std.mem.copyForwards(u8, &self.input, self.input[consumed..self.used]);
        self.used -= consumed;
        self.owner_batch_remaining -|= 1;
        if (std.mem.indexOfScalar(u8, self.input[0..self.used], '\n') == null) self.owner_batch_remaining = 0;
    }
    /// Owner only. Keep the original request line until its response has been
    /// encoded, so string/integer IDs and pipelined input survive deferral.
    /// Responses never pass through the coalescing presentation mailbox.
    pub fn completeQueued(self: *Server, sequence: u64, result: anyerror![]const u8) !void {
        if (self.pending_sequence != sequence) return error.StaleReply;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const request = try std.json.parseFromSlice(Value, a, self.input[0 .. self.pending_line_bytes - 1], .{});
        const id = member(request.value, "id").?;
        if (result) |json| {
            const value = try std.json.parseFromSlice(Value, a, json, .{});
            try self.toolReply(a, id, value.value);
        } else |err| {
            try self.toolFailure(a, id, err);
        }
        const consumed = self.pending_line_bytes;
        self.consumeInput(consumed);
        self.pending_sequence = null;
        self.pending_line_bytes = 0;
    }
    fn toolFailure(self: *Server, a: Allocator, id: Value, err: anyerror) !void {
        if (err == error.UnknownTool or err == error.InvalidArguments) {
            try self.failure(a, id, -32602, @errorName(err));
            return;
        }
        // The name stays first; the second line says which image and budget.
        // A queued call sets the detail on the owner, in the arena that is
        // still live while its reply is encoded.
        defer self.error_detail = null;
        if (self.error_detail) |detail| {
            try self.reply(a, id, .{ .isError = true, .content = .{ .{ .type = "text", .text = @errorName(err) }, .{ .type = "text", .text = detail } } });
            return;
        }
        try self.reply(a, id, .{ .isError = true, .content = .{.{ .type = "text", .text = @errorName(err) }} });
    }
    fn authorizeTool(self: *Server, root: *Session, name: []const u8) !shared_context.Policy {
        // Visibility is not authorization. Resolve the declared policy before
        // routing or validating tool-specific arguments, for every transport.
        const policy = try self.toolPolicy(if (self.overview_only) overview.definitions else if (root.imported != null) @import("imported.zig").definitions else tool_definitions, name);
        if (self.shared) |peer| {
            switch (policy.required) {
                .observer => {},
                .requester => try shared_context.check(shared_context.c.xsvc_authorize(peer.service, peer.client_id, shared_context.c.XSVC_OBSERVE, @import("../target/linux.zig").now())),
                .controller => try peer.authorize(false),
                .mutator => try peer.authorize(true),
                .lease => return error.InvalidToolSessionAccess,
            }
        } else if (!policy.localAllowed(root.agent_scope, root.shared_jobs)) return error.AgentScopeDenied;
        return policy;
    }
    fn tool(self: *Server, a: Allocator, root: *Session, name: []const u8, args: Value) !Value {
        if (args != .object) return error.InvalidArguments;
        if (self.overview_only and !overview.handles(name) and !std.mem.eql(u8, name, "get_session_clients") and !std.mem.eql(u8, name, "get_session_events")) return error.UnknownTool;
        if (self.shared) |peer| {
            if (shared_context.handles(name)) return peer.call(a, root, name, args);
            try peer.tick(root);
        }
        const policy = try self.authorizeTool(root, name);
        if (@import("system_capture.zig").handles(name)) {
            const caller: @import("../model/command.zig").Caller = .{ .agent = .{ .client = if (self.shared) |peer| peer.client_id else 0, .lease = null } };
            return @import("system_capture.zig").call(a, self.overview_shared orelse &self.overview, self.overview_capture, root.agent_scope, caller, name, args, @import("../target/linux.zig").now());
        }
        if (std.mem.eql(u8, name, "get_layout")) {
            if (args.object.count() != 0) return error.InvalidArguments;
            const layout = @import("../layout_snapshot.zig");
            const snapshot = try a.create(layout.Snapshot);
            layout.read(snapshot);
            return asValue(a, snapshot);
        }
        if (@import("fd.zig").isControl(name)) {
            if (root.agent_scope == .observe) return error.AgentScopeDenied;
            // Shared calls already passed the authoritative lease check above.
            const collector = self.overview_shared orelse &self.overview;
            if (std.mem.eql(u8, name, "start_fd_events") and collector.capture.backend_busy) return error.ExistingCaptureActive;
            const result = try @import("fd.zig").control(a, collector, name, args);
            collector.fd_lease = if (std.mem.eql(u8, name, "start_fd_events"))
                (if (self.shared) |peer| @import("../service/lease.zig").Lease.capture(peer.service, peer.client_id) else null)
            else
                null;
            return result;
        }
        // Whole-system observation needs no debug target or process routing.
        const redot_graph = std.mem.eql(u8, name, "get_graph") and std.mem.eql(u8, try @import("graph.zig").kind(args), "redot");
        if (redot_graph and self.overview_only) return error.GraphKindUnavailable;
        if (overview.handles(name) and !redot_graph) return overview.call(a, self.overview_shared orelse &self.overview, name, args);
        // External evidence belongs to the root session, not a target process.
        if (@import("evidence.zig").handles(name)) return @import("evidence.zig").call(a, .{
            .network = root.evidence_stream,
            .protocol_stream = root.protocol_stream,
            .tls_stream = root.tls_stream,
            .usb_stream = root.usb_stream,
            .dbus_stream = root.dbus_stream,
            .mitm_stream = root.mitm_stream,
            .live_capture = root.live_capture,
            .private = self.private_access.resolve(root.agent_scope == .observe),
        }, name, args);
        const process_id = try @import("profile.zig").number(args, "process_id", 1);
        const session = if (root.process_tree) |tree| (try tree.find(process_id)).session else if (process_id == root.process_id) root else return error.UnknownProcess;
        if (!policy.localAllowed(session.agent_scope, root.shared_jobs or session.shared_jobs)) return error.AgentScopeDenied;
        var local = Value{ .object = .empty };
        var fields = args.object.iterator();
        while (fields.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "process_id")) try local.object.put(a, field.key_ptr.*, field.value_ptr.*);
        if (@import("commands.zig").handles(name)) {
            const decoded = try @import("commands.zig").decode(name, local);
            const state = session.target.snapshot();
            const caller: @import("../model/command.zig").Caller = if (self.shared) |peer| .{ .agent = .{ .client = peer.client_id, .lease = if (@import("../service/lease.zig").Lease.capture(peer.service, peer.client_id)) |lease| lease.id else null } } else .{ .agent = .{ .client = 0, .lease = null } };
            const result = session.executeCommand(a, 0, if (self.shared) |peer| peer.service else null, .{
                .stamp = .{ .connection = 0, .session = session.id, .process = session.process_id, .pid = state.pid, .image_epoch = state.image_epoch, .generation = decoded.generation },
                .caller = caller,
                .operation = decoded.operation,
            }) catch |err| return self.lineError(a, session, err);
            var reply_value = try @import("commands.zig").reply(a, session, decoded.operation, result);
            try processFields(a, session, &reply_value);
            return reply_value;
        }
        const previous_lease = session.agent_lease;
        session.agent_lease = if (self.shared) |peer| @import("../service/lease.zig").Lease.capture(peer.service, peer.client_id) else null;
        defer session.agent_lease = previous_lease;
        const previous_client = session.agent_client_id;
        session.agent_client_id = if (self.shared) |peer| peer.client_id else null;
        defer session.agent_client_id = previous_client;
        const previous_controller = session.agent_controller;
        session.agent_controller = if (self.shared) |peer| peer.visible(.controller) catch false else session.agent_scope != .observe;
        defer session.agent_controller = previous_controller;
        var result = try self.toolForProcess(a, session, name, local);
        if (result == .object) {
            try result.object.put(a, "process_id", .{ .integer = @intCast(session.process_id) });
            try result.object.put(a, "process_session_id", .{ .integer = @intCast(session.id) });
        }
        return result;
    }
    fn processFields(a: Allocator, session: *Session, result: *Value) !void {
        if (result.* == .object) {
            try result.object.put(a, "process_id", .{ .integer = @intCast(session.process_id) });
            try result.object.put(a, "process_session_id", .{ .integer = @intCast(session.id) });
        }
    }
    /// Encode a typed owner's result without re-entering a tool handler.
    pub fn commandReply(self: *Server, a: Allocator, session: *Session, request: @import("../model/remote_owner.zig").Request, result: anytype) ![]const u8 {
        const outcome = result catch |err| return self.lineError(a, session, err);
        const operation: @import("../model/command.zig").Operation = switch (request.action) {
            .control => |control| .{ .control = control },
            .breakpoint => |bp| .{ .breakpoint = bp },
            else => return error.InvalidOwnerReply,
        };
        var reply_value = try @import("commands.zig").reply(a, session, operation, outcome.command);
        try processFields(a, session, &reply_value);
        return std.json.Stringify.valueAlloc(a, reply_value, .{});
    }
    pub fn queuedCaller(self: *const Server, actor: @import("../model/remote_owner.zig").Actor) !void {
        if (actor != .agent) return error.ProtocolActorRequired;
        if (self.shared) |peer| {
            if (actor.agent.client != peer.client_id) return error.UnknownSessionClient;
        } else if (actor.agent.client != 0 or actor.agent.lease != null) return error.UnknownSessionClient;
    }
    fn toolForProcess(self: *Server, a: Allocator, session: *Session, name: []const u8, args: Value) !Value {
        if (@import("frames.zig").handles(name)) return @import("frames.zig").call(a, session, name, args);
        const processes = @import("processes.zig");
        if (processes.handles(name)) return processes.call(a, session, name, args);
        if (session.imported) |*state| {
            if (std.mem.eql(u8, name, "get_session")) return asValue(a, session.snapshot());
            return @import("imported.zig").call(a, state, name, args);
        }
        if (std.mem.eql(u8, name, "get_core_info")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{ "mapping_start", "segment_start", "limit" });
            const core = if (session.target.core) |*core| core else return error.NotCoreSession;
            const m = try wire.number(args, "mapping_start", 0);
            const p = try wire.number(args, "segment_start", 0);
            const limit = try wire.number(args, "limit", 16);
            if (m > core.mappings.items.len or p > core.segments.items.len or limit == 0 or limit > 32) return error.InvalidArguments;
            const me = m + @min(limit, core.mappings.items.len - m);
            const pe = p + @min(limit, core.segments.items.len - p);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .path = core.path, .file_bytes = core.size, .pid = core.pid, .command = core.command, .signal = core.signal, .threads = core.threads.items.len, .segment_total = core.segments.items.len, .mapping_total = core.mappings.items.len, .mapping_next = if (me < core.mappings.items.len) @as(?u64, me) else null, .segment_next = if (pe < core.segments.items.len) @as(?u64, pe) else null, .segments = core.segments.items[@intCast(p)..@intCast(pe)], .mappings = core.mappings.items[@intCast(m)..@intCast(me)], .read_only = true, .memory_basis = "captured PT_LOAD bytes only; omitted memory is unavailable", .symbol_basis = "local ELF build ID matched against captured notes" });
        }
        if (std.mem.eql(u8, name, "get_stop_info")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{ "tid", "generation" });
            const tid = try wire.number(args, "tid", 0);
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            try session.target.expectGeneration(try wire.number(args, "generation", session.target.snapshot().generation));
            return asValue(a, .{ .generation = session.target.snapshot().generation, .stop = try session.target.stopInfo(@intCast(tid)) });
        }
        if (std.mem.eql(u8, name, "get_debug_metadata")) {
            try @import("profile.zig").fields(args, &.{});
            return asValue(a, .{ .jobs = session.metadata.snapshot() });
        }
        if (std.mem.eql(u8, name, "cancel_debug_metadata") or std.mem.eql(u8, name, "retry_debug_metadata")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{"id"});
            const id = try wire.number(args, "id", null);
            if (std.mem.eql(u8, name, "cancel_debug_metadata")) try session.metadata.cancel(id) else try session.metadata.retry(id);
            return asValue(a, .{ .jobs = session.metadata.snapshot() });
        }
        if (std.mem.eql(u8, name, "get_debug_files")) return @import("debug_files.zig").call(a, session, args);
        if (@import("macho.zig").handles(name)) return @import("macho.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "get_extended_registers")) return @import("registers.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "get_language_locals") or std.mem.eql(u8, name, "evaluate_language_expression")) return @import("language_locals.zig").call(a, session, name, args);
        if (@import("language_watches.zig").handles(name)) return @import("language_watches.zig").call(a, session, name, args);
        const language_tabs = @import("language_tabs.zig");
        if (language_tabs.handles(name)) return language_tabs.call(a, session, name, args);
        const redot = @import("redot.zig");
        if (std.mem.eql(u8, name, "get_graph")) return @import("graph.zig").redot(a, session, args);
        if (redot.handles(name)) return redot.call(a, session, name, args);
        const allocations = @import("allocation_control.zig");
        if (allocations.handles(name)) return allocations.call(a, session, name, args);
        const runtime_types = @import("runtime_types.zig");
        if (runtime_types.handles(name)) return runtime_types.call(a, session, name, args);
        const memory = @import("memory.zig");
        if (memory.handles(name)) return memory.call(a, session, name, args);
        const inspection = @import("inspection.zig");
        if (inspection.handles(name)) return inspection.call(a, session, name, args);
        const observation = @import("observation.zig");
        if (observation.handles(name)) return observation.call(a, session, name, args);
        const associations = @import("associations.zig");
        if (associations.handles(name)) return associations.call(a, session, name, args);
        const probes = @import("probes.zig");
        if (probes.handles(name)) return probes.call(a, session, name, args) catch |err| return self.lineError(a, session, err);
        const remote = @import("remote.zig");
        if (remote.handles(name)) return remote.call(a, session, name, args, self.source_path);
        if (std.mem.eql(u8, name, "get_profile_comparison")) return @import("comparison.zig").call(a, session, args);
        const archives = @import("archive.zig");
        if (archives.handles(name)) return archives.call(a, session, name, args);
        const profiles = @import("profile.zig");
        if (profiles.handles(name)) return profiles.call(a, session, name, args);
        const static_analysis = @import("static_analysis.zig");
        if (static_analysis.handles(name)) return static_analysis.call(a, session, name, args);
        if (session.offline) {
            const reads = [_][]const u8{ "get_session", "get_audit", "query_events", "list_threads", "get_breakpoints" };
            for (reads) |read| {
                if (std.mem.eql(u8, name, read)) break;
            } else return error.OfflineSession;
        }
        if (std.mem.eql(u8, name, "list_locals")) return @import("locals_list.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "list_modules")) return @import("module_list.zig").call(a, session, args);
        if (args != .object) return error.InvalidArguments;
        var fields = args.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            const allowed = if (std.mem.eql(u8, key, "inline_depth") and (std.mem.eql(u8, name, "list_locals") or std.mem.eql(u8, name, "evaluate_expression") or std.mem.eql(u8, name, "get_value_children"))) true else if (std.mem.eql(u8, name, "get_registers"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "read_memory"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "disassemble") or std.mem.eql(u8, name, "get_source_location"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "get_instruction_effects"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "generation") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "limit")
            else if (std.mem.eql(u8, name, "get_language_stack"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "language") or std.mem.eql(u8, key, "state") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "get_value_children"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") or std.mem.eql(u8, key, "start") or std.mem.eql(u8, key, "limit") or std.mem.eql(u8, key, "raw")
            else if (std.mem.eql(u8, name, "get_function_graph"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "symbol") or std.mem.eql(u8, key, "start_block") or std.mem.eql(u8, key, "limit") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "query_events")) std.mem.eql(u8, key, "after") else if (std.mem.eql(u8, name, "find_symbol")) std.mem.eql(u8, key, "name") else if (std.mem.eql(u8, name, "get_investigation")) std.mem.eql(u8, key, "id") else if (std.mem.eql(u8, name, "investigate_write")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "question") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "set_breakpoint")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "symbol") or std.mem.eql(u8, key, "file") or std.mem.eql(u8, key, "line") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "remove_breakpoint") or std.mem.eql(u8, name, "remove_watchpoint")) std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "set_watchpoint")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "continue") or std.mem.eql(u8, name, "interrupt")) std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "evaluate_expression")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "get_stack") or std.mem.eql(u8, name, "list_locals")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "step_instruction") or std.mem.eql(u8, name, "step_over_instruction") or std.mem.eql(u8, name, "step_source") or std.mem.eql(u8, name, "step_over")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "write_memory")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "hex") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "write_register")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "value") or std.mem.eql(u8, key, "generation") else false;
            if (!allowed) return error.InvalidArguments;
        }
        if (member(args, "generation")) |v| {
            const generation = number(v) orelse return error.InvalidArguments;
            try session.target.expectGeneration(generation);
        }
        if (std.mem.eql(u8, name, "find_symbol")) {
            const symbol = session.findSymbol(string(member(args, "name")) orelse return error.InvalidArguments) catch |err| {
                // A name that is not found may live in an image refused in full.
                const terminal = err == error.SymbolNotFound or err == error.BinarySnapshotLimit or err == error.SymbolSnapshotLimit;
                var text: [@import("../model/modules.zig").Modules.unsearched_text]u8 = undefined;
                self.error_detail = if (terminal) if (session.modules.budgetDetail(null) orelse session.modules.unsearchedDetail(&text)) |detail| try a.dupe(u8, detail) else null else null;
                return if (self.error_detail != null) error.ImageBudgetExceeded else err;
            };
            return asValue(a, .{ .module_id = symbol.module_id, .name = symbol.name, .address = try std.fmt.allocPrint(a, "0x{x}", .{symbol.address}), .size = symbol.size, .local_entry = symbol.entry });
        }
        if (std.mem.eql(u8, name, "get_breakpoints")) return asValue(a, .{ .breakpoints = session.target.breakpointSlice(), .watchpoints = session.target.watchpointSlice(), .policies = session.probes.rules, .definitions = session.persistent.entries.items, .loader_status = session.persistent.loader_status, .loader_reads = session.persistent.loader_reads, .symbol_transfer = .{ .bytes = session.persistent.file_reads.bytes, .files = session.persistent.file_reads.files, .negative_hits = session.persistent.file_reads.negative_hits, .skipped = session.persistent.file_reads.skipped, .resumed_bytes = session.persistent.file_reads.resumed_bytes, .cached_modules = session.modules.cachedSymbolCount(), .retained_bytes = session.modules.symbol_bytes }, .data_watch_slots = session.target.watchpointCapacity() catch null, .execution_watches = session.target.gdbRemoteInfo() == null and session.target.arch() == .x86_64 });
        if (std.mem.eql(u8, name, "get_investigation")) return asValue(a, (try session.investigation(number(member(args, "id")) orelse return error.InvalidArguments)).*);
        if (std.mem.eql(u8, name, "get_audit")) return asValue(a, .{ .actions = session.audit[0..session.audit_count] });
        const execution_names = [_][]const u8{ "investigate_write", "set_watchpoint", "remove_watchpoint" };
        const mutation_names = [_][]const u8{ "write_memory", "write_register" };
        var effect: ?@import("../model/session.zig").Effect = null;
        var action: []const u8 = "";
        for (execution_names) |candidate| if (std.mem.eql(u8, name, candidate)) {
            effect = .execution;
            action = candidate;
        };
        for (mutation_names) |candidate| if (std.mem.eql(u8, name, candidate)) {
            effect = .mutation;
            action = candidate;
        };
        if (effect) |kind| {
            try session.authorize(.agent, kind, number(member(args, "generation")));
            var created_id: ?u64 = null;
            if (std.mem.eql(u8, name, "investigate_write")) {
                const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
                if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
                const frame_index = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
                if (frame_index >= 64) return error.InvalidArguments;
                created_id = try session.investigateWrite(@intCast(tid), @intCast(frame_index), string(member(args, "question")) orelse return error.InvalidArguments, string(member(args, "expression")) orelse return error.InvalidArguments);
            } else if (std.mem.eql(u8, name, "remove_watchpoint")) try session.target.removeWatchpoint(number(member(args, "id")) orelse return error.InvalidArguments) else if (std.mem.eql(u8, name, "set_watchpoint")) {
                const length = number(member(args, "length")) orelse return error.InvalidArguments;
                if (length > 8) return error.InvalidArguments;
                const watch_kind = std.meta.stringToEnum(@import("../target/breakpoints.zig").WatchKind, string(member(args, "kind")) orelse "write") orelse return error.InvalidArguments;
                created_id = try session.target.setWatchpoint(try address(args), @intCast(length), watch_kind);
            } else if (std.mem.eql(u8, name, "write_memory")) {
                const hex = string(member(args, "hex")) orelse return error.InvalidArguments;
                if (hex.len == 0 or hex.len > 8192 or hex.len % 2 != 0) return error.InvalidArguments;
                var bytes: [4096]u8 = undefined;
                for (0..hex.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidArguments;
                const before = session.target.snapshot().generation;
                session.target.writeMemory(try address(args), bytes[0 .. hex.len / 2]) catch |err| {
                    if (session.target.snapshot().generation != before) session.record(.agent, "write_memory_partial");
                    return err;
                };
            } else if (std.mem.eql(u8, name, "write_register")) {
                const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
                if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
                const text = string(member(args, "value")) orelse return error.InvalidArguments;
                const value = std.fmt.parseInt(u64, text, 0) catch return error.InvalidArguments;
                try session.target.writeRegister(@intCast(tid), string(member(args, "name")) orelse return error.InvalidArguments, value);
            }
            session.record(.agent, action);
            return asValue(a, .{ .id = created_id, .session = session.snapshot() });
        }
        if (std.mem.eql(u8, name, "get_session")) return asValue(a, session.snapshot());
        if (std.mem.eql(u8, name, "list_threads")) {
            if (session.target.gdbRemoteInfo()) |info| if (info.threads == .unsupported) return error.UnsupportedControl;
            return asValue(a, .{ .generation = session.target.snapshot().generation, .threads = session.target.threadSlice(), .thread_labels = session.compatibility.labels.items });
        }
        if (std.mem.eql(u8, name, "get_source_location")) return asValue(a, .{ .generation = session.target.snapshot().generation, .source = try session.sourceAt(a, try address(args)) });
        if (std.mem.eql(u8, name, "get_language_stack")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            const frame = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            const language = string(member(args, "language")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32) or frame >= 64) return error.InvalidArguments;
            if (std.mem.eql(u8, language, "lua")) {
                const state: ?u64 = if (member(args, "state")) |v| std.fmt.parseInt(u64, string(v) orelse return error.InvalidArguments, 0) catch return error.InvalidArguments else null;
                return asValue(a, try @import("../language/lua.zig").stack(session, a, @intCast(tid), @intCast(frame), state));
            }
            if (member(args, "state") != null) return error.InvalidArguments;
            if (std.mem.eql(u8, language, "gdscript")) return asValue(a, @import("../language/gdscript.zig").stack(session, a, @intCast(tid), @intCast(frame)) catch |err| {
                // Which image, how large, and what to rerun with.
                if (err == error.GDScriptImageBudgetExceeded) self.error_detail = if (session.modules.budgetDetail(null)) |detail| try a.dupe(u8, detail) else null;
                return err;
            });
            if (std.mem.eql(u8, language, "elisp")) return asValue(a, try @import("../language/elisp.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "ruby")) return asValue(a, try @import("../language/ruby.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "go")) return asValue(a, try @import("../language/go.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "javascript")) return asValue(a, try @import("../language/javascript.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "python")) return asValue(a, try @import("../language/python.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (!std.mem.eql(u8, language, "perl")) return error.InvalidArguments;
            return asValue(a, try @import("../language/perl.zig").stack(session, a, @intCast(tid), @intCast(frame)));
        }
        if (std.mem.eql(u8, name, "get_stack")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const frames = try session.stack(a, @intCast(tid), 64);
            // Name the first image this stack could not read in full.
            // A core has no metadata unwinder: its walk ends at that frame.
            const image_budget: ?[]const u8 = found: for (frames) |frame| {
                for ([_]?[]const u8{ frame.inline_diagnostic, frame.diagnostic }) |reason| if (reason) |why| if (std.mem.eql(u8, why, "BinarySnapshotLimit") or std.mem.eql(u8, why, "CompressedDebugBudget")) if (session.modules.budgetDetail(frame.lookup_pc)) |detail| break :found try a.dupe(u8, detail);
            } else null;
            var result = try asValue(a, .{ .generation = session.target.snapshot().generation, .image_budget = image_budget, .frames = frames });
            for (result.object.getPtr("frames").?.array.items) |*frame| {
                const raw = string(member(frame.*, "symbol"));
                const display: ?[]const u8 = if (raw) |symbol| try @import("../debug/demangle.zig").display(a, symbol) else null;
                try frame.object.put(a, "symbol_display", if (display) |name_| .{ .string = name_ } else .null);
            }
            return result;
        }
        if (std.mem.eql(u8, name, "get_value_children")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const frame = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            const start = if (member(args, "start")) |v| number(v) orelse return error.InvalidArguments else 0;
            const limit = if (member(args, "limit")) |v| number(v) orelse return error.InvalidArguments else 16;
            const raw = if (member(args, "raw")) |v| switch (v) {
                .bool => v.bool,
                else => return error.InvalidArguments,
            } else false;
            if (frame >= 64 or limit == 0 or limit > 64) return error.InvalidArguments;
            const expression = string(member(args, "expression")) orelse return error.InvalidArguments;
            const v = try session.evaluateAtDepth(a, @intCast(tid), @intCast(frame), try inlineDepth(args), expression);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .tid = tid, .frame = frame, .expression = expression, .view = try session.valueChildren(a, v, start, @intCast(limit), raw) });
        }
        if (std.mem.eql(u8, name, "evaluate_expression")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const expression = string(member(args, "expression")) orelse return error.InvalidArguments;
            const frame_index = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            if (frame_index >= 64) return error.InvalidArguments;
            const value = try session.evaluateAtDepth(a, @intCast(tid), @intCast(frame_index), try inlineDepth(args), expression);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .tid = tid, .expression = expression, .type = value.type.name, .kind = value.type.kind, .size = value.type.size, .bits = if (value.runtime_type != null and (value.availability != .available or value.type.kind == .structure or value.type.kind == .array or value.type.kind == .unknown)) null else try std.fmt.allocPrint(a, "0x{x}", .{value.bits}), .availability = value.availability, .value = try session.summarize(a, value) });
        }
        if (std.mem.eql(u8, name, "get_registers")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const regs = try session.target.registers(@intCast(tid));
            var values: std.json.ObjectMap = .{};
            for (regs.descriptions()) |desc| try values.put(a, std.mem.span(desc.name), .{ .string = try @import("../target/runtime.zig").registerText(a, regs, desc) });
            const generation = session.target.snapshot().generation;
            if (regs.architecture() == .loongarch64)
                return asValue(a, .{ .generation = generation, .tid = tid, .note = "r0 is the kernel restart slot, not architectural zero", .registers = Value{ .object = values } });
            if (regs.architecture() == .riscv64)
                return asValue(a, .{ .generation = generation, .tid = tid, .note = "x0 is architectural zero and is not in NT_PRSTATUS", .registers = Value{ .object = values } });
            return asValue(a, .{ .generation = generation, .tid = tid, .registers = Value{ .object = values } });
        }
        if (std.mem.eql(u8, name, "read_memory")) {
            const addr = try readAddress(args);
            const len = number(member(args, "length")) orelse return error.InvalidArguments;
            if (len == 0 or len > 4096) return error.InvalidArguments;
            const bytes = try a.alloc(u8, @intCast(len));
            const n = try session.target.readMemory(addr, bytes);
            const hex = try a.alloc(u8, n * 2);
            const digits = "0123456789abcdef";
            for (bytes[0..n], 0..) |v, i| {
                hex[i * 2] = digits[v >> 4];
                hex[i * 2 + 1] = digits[v & 15];
            }
            return asValue(a, .{ .generation = session.target.snapshot().generation, .address = try std.fmt.allocPrint(a, "0x{x}", .{addr}), .bytes_read = n, .hex = hex });
        }
        if (std.mem.eql(u8, name, "get_function_graph")) {
            if (session.target.snapshot().state != .stopped) return error.NotStopped;
            if ((member(args, "address") != null) == (member(args, "symbol") != null)) return error.InvalidArguments;
            try session.refreshMaps();
            const addr = if (member(args, "symbol")) |value| (try session.modules.findSymbol(string(value) orelse return error.InvalidArguments)).address else try address(args);
            const first = if (member(args, "start_block")) |value| number(value) orelse return error.InvalidArguments else 0;
            const limit = if (member(args, "limit")) |value| number(value) orelse return error.InvalidArguments else 8;
            if (limit == 0 or limit > 16) return error.InvalidArguments;
            const function = try session.functionGraph(a, addr);
            const graph = function.graph;
            if (first >= graph.blocks.len) return error.InvalidArguments;
            const end = @min(graph.blocks.len, first + limit);
            var blocks: std.array_list.Managed(Value) = .init(a);
            for (graph.blocks[@intCast(first)..@intCast(end)]) |block| {
                const last = graph.instructions[block.first + block.count - 1];
                const source = if (block.source) |site| try asValue(a, .{ .path = site.path[0..@min(512, site.path.len)], .path_truncated = site.path.len > 512, .line = site.line, .column = site.column }) else Value.null;
                try blocks.append(try asValue(a, .{ .id = block.id, .address = try std.fmt.allocPrint(a, "0x{x}", .{block.address}), .end = try std.fmt.allocPrint(a, "0x{x}", .{block.end}), .instruction_count = block.count, .reachable_via_resolved_edges = block.reachable, .source = source, .terminator = .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{last.address}), .mnemonic = std.mem.sliceTo(&last.mnemonic, 0), .operands = std.mem.sliceTo(&last.operands, 0), .flow = last.flow } }));
            }
            var edges: std.array_list.Managed(Value) = .init(a);
            for (graph.edges) |edge| if (edge.from >= first and edge.from < end) {
                try edges.append(try asValue(a, .{ .from = edge.from, .to = edge.to, .kind = edge.kind, .resolution = edge.resolution, .assumed = edge.assumed, .address = if (edge.address) |to| try std.fmt.allocPrint(a, "0x{x}", .{to}) else @as(?[]const u8, null) }));
            };
            return asValue(a, .{ .generation = function.generation, .image_epoch = function.image_epoch, .module_id = function.module_id, .symbol = function.symbol[0..@min(512, function.symbol.len)], .symbol_truncated = function.symbol.len > 512, .address = try std.fmt.allocPrint(a, "0x{x}", .{graph.address}), .link_address = try std.fmt.allocPrint(a, "0x{x}", .{function.link_address}), .size = graph.size, .extent_source = function.extent_source, .range_index = function.range_index, .range_count = function.range_count, .whole_function = function.range_count == 1, .decoded_bytes = graph.decoded_bytes, .undecoded_bytes = graph.size - graph.decoded_bytes, .basis = "linear_decode_of_live_function_bytes_with_breakpoint_overlay", .execution_observed = false, .total_blocks = graph.blocks.len, .start_block = first, .next_block = if (end < graph.blocks.len) @as(?u64, end) else null, .blocks = Value{ .array = blocks }, .edges = Value{ .array = edges } });
        }
        if (std.mem.eql(u8, name, "get_instruction_effects")) {
            if (session.target.snapshot().state != .stopped) return error.NotStopped;
            if (session.target.arch() != .x86_64) return error.InstructionAnalysisUnsupportedArchitecture;
            const addr = try address(args);
            const length = if (member(args, "length")) |v| number(v) orelse return error.InvalidArguments else 256;
            const limit = if (member(args, "limit")) |v| number(v) orelse return error.InvalidArguments else 16;
            const ir = @import("../model/analysis_ir.zig");
            if (length == 0 or length > ir.max_bytes or limit == 0 or limit > ir.max_instructions) return error.InvalidArguments;
            var bytes: [ir.max_bytes]u8 = undefined;
            const n = try session.target.readMemory(addr, bytes[0..@intCast(length)]);
            if (n == 0) return error.FunctionMemoryIncomplete;
            const instructions = try ir.decode(a, bytes[0..n], addr, @intCast(limit));
            const decoded = if (instructions.len > 0) instructions[instructions.len - 1].address + instructions[instructions.len - 1].size - addr else 0;
            return asValue(a, .{ .generation = session.target.snapshot().generation, .image_epoch = session.target.snapshot().image_epoch, .architecture = @tagName(session.target.arch()), .schema_version = 1, .basis = "capstone_operands_and_register_access_from_live_bytes_with_breakpoint_overlay", .execution_observed = false, .address = addr, .bytes_read = n, .decoded_bytes = decoded, .uninspected_bytes = n - decoded, .instruction_limit_reached = instructions.len == limit, .next_address = if (decoded > 0) @as(?u64, addr + decoded) else null, .instructions = instructions, .limitations = "register aliases and flag meaning are architecture-specific; explicit memory expressions are not read; implicit memory, faults and full instruction semantics are not modeled" });
        }
        if (std.mem.eql(u8, name, "disassemble")) {
            const addr = try address(args);
            var bytes: [256]u8 = undefined;
            const n = try session.target.readMemory(addr, &bytes);
            var instructions: [32]disasm.Instruction = undefined;
            const count = try disasm.decodeFor(session.target.arch(), bytes[0..n], addr, &instructions);
            var list: std.array_list.Managed(Value) = .init(a);
            for (instructions[0..count]) |inst| try list.append(try asValue(a, .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{inst.address}), .size = inst.size, .mnemonic = std.mem.sliceTo(@as([]const u8, &inst.mnemonic), 0), .operands = std.mem.sliceTo(@as([]const u8, &inst.operands), 0) }));
            return asValue(a, .{ .generation = session.target.snapshot().generation, .instructions = Value{ .array = list } });
        }
        if (std.mem.eql(u8, name, "query_events")) {
            const after = if (member(args, "after")) |v| number(v) orelse return error.InvalidArguments else 0;
            const events = session.target.eventSlice();
            var first: usize = 0;
            while (first < events.len and events[first].sequence <= after) : (first += 1) {}
            const end = @min(events.len, first + 128);
            return asValue(a, .{ .events = events[first..end], .has_more = end < events.len, .oldest_available = if (events.len > 0) events[0].sequence else 0 });
        }
        return error.UnknownTool;
    }
    fn handle(self: *Server, session: *Session, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(Value, a, line, .{ .max_value_len = 65536 }) catch {
            try self.failure(a, .null, -32700, "Parse error");
            return;
        };
        const request = parsed.value;
        const id = member(request, "id") orelse Value.null;
        const version = string(member(request, "jsonrpc")) orelse "";
        const method = string(member(request, "method")) orelse "";
        if (!std.mem.eql(u8, version, "2.0") or method.len == 0 or (id != .null and id != .string and id != .integer)) {
            try self.failure(a, .null, -32600, "Invalid Request");
            return;
        }
        // Names and sizes only: a payload can hold target memory.
        if (log.on(.mcp, .trace)) {
            const called = string(member(member(request, "params") orelse Value.null, "name")) orelse "";
            log.trace(.mcp, "mcp in {s}{s}{s}: {d} bytes\n", .{ method[0..@min(method.len, 64)], if (called.len > 0) " " else "", called[0..@min(called.len, 64)], line.len });
        }
        if (member(request, "id") == null) {
            if (std.mem.eql(u8, method, "notifications/initialized") and self.negotiated) self.initialized = true;
            return;
        }
        if (self.shared) |peer| try peer.tick(session);
        const params = member(request, "params") orelse Value{ .object = .{} };
        if (std.mem.eql(u8, method, "initialize")) {
            const capabilities = member(params, "capabilities") orelse Value.null;
            const client_info = member(params, "clientInfo") orelse Value.null;
            if (self.negotiated or string(member(params, "protocolVersion")) == null or capabilities != .object or string(member(client_info, "name")) == null or string(member(client_info, "version")) == null) {
                try self.failure(a, id, -32602, "Invalid initialization parameters");
                return;
            }
            self.negotiated = true;
            try self.reply(a, id, .{ .protocolVersion = "2025-06-18", .capabilities = .{ .tools = .{ .listChanged = true } }, .serverInfo = .{ .name = "xodb", .version = "0.0.1" }, .instructions = if (self.overview_only) "Live system overview. Observers read shared caches; inspect ages and pending status. request_system_capture asks for bounded CPU/fd-flow collection: GUI requires human confirmation, headless requires explicit agent-scope control/mutate. Read consent, audit and deadlines with get_system_capture; polling never renews a capture. No general debugger control, control lease or attach tools are available." else if (self.shared != null) "Shared local debugger session. Inspect as an observer; claim_session_control with the original process generation to start jobs or control targets. Renew before lease expiry. The human scope is authoritative; scope change, expiry, release or disconnect revokes control. Jobs and retained evidence survive reconnect. Poll get_session_clients/get_session_events for ownership and query_events for target events. Process mutations still require that process generation." else "Inspect and control debugger process sessions within the human-configured agent_scope. Optional process_id selects a stable process; omitted means original process 1, independent of GUI selection. List IDs with get_processes. Mutations require that process\'s current generation from get_session; the human may revoke scope for all processes. Continue/step/interrupt are asynchronous. Poll get_session and query_events for outcomes." });
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.reply(a, id, Value{ .object = .{} });
        } else if (!self.initialized) {
            try self.failure(a, id, -32002, "Initialize first");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const definitions = try std.json.parseFromSlice(Value, a, if (self.overview_only) overview.definitions else if (session.imported != null) @import("imported.zig").definitions else tool_definitions, .{});
            var visible: std.array_list.Managed(Value) = .init(a);
            for (definitions.value.array.items) |definition| {
                if (!try shared_context.localAllowed(session.agent_scope, session.shared_jobs, definition)) continue;
                if (self.shared) |peer| if (!try peer.visible(try shared_context.access(definition))) continue;
                try visible.append(definition);
            }
            if (self.shared) |peer| {
                const extra = try std.json.parseFromSlice(Value, a, shared_context.definitions, .{});
                const state = try peer.state();
                for (extra.value.array.items) |definition| {
                    _ = try shared_context.access(definition);
                    const name = string(member(definition, "name")).?;
                    if (std.mem.eql(u8, name, "claim_session_control") and session.agent_scope == .observe) continue;
                    if (std.mem.eql(u8, name, "release_session_control") and state.controller != peer.client_id) continue;
                    try visible.append(definition);
                }
            }
            try self.reply(a, id, .{ .tools = Value{ .array = visible } });
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const name = string(member(params, "name")) orelse {
                try self.failure(a, id, -32602, "Missing tool name");
                return;
            };
            const args = member(params, "arguments") orelse Value{ .object = .{} };
            self.error_detail = null;
            if (self.owner_queue != null) {
                self.enqueueTool(a, session, name, args, line.len + 1) catch |err| {
                    if (err == error.OwnerQueueBusy) return err;
                    try self.toolFailure(a, id, err);
                };
                return;
            }
            const result = self.tool(a, session, name, args) catch |err| {
                try self.toolFailure(a, id, err);
                return;
            };
            try self.toolReply(a, id, result);
        } else try self.failure(a, id, -32601, "Method not found");
    }
    fn toolReply(self: *Server, a: Allocator, id: Value, result: Value) !void {
        var exact_result = result;
        @import("exact.zig").addresses(a, &exact_result) catch |err| switch (err) {
            error.ConflictingEvidenceWord, error.InvalidEvidenceWord => {
                // The handler may already have completed an operation. Refuse
                // its invalid representation without ending the session or
                // publishing a partially projected result.
                try self.reply(a, id, .{ .isError = true, .content = .{.{ .type = "text", .text = @errorName(err) }} });
                return;
            },
            else => return err,
        };
        const text = try std.json.Stringify.valueAlloc(a, exact_result, .{});
        try self.reply(a, id, .{ .structuredContent = exact_result, .isError = false, .content = .{.{ .type = "text", .text = text }} });
    }
    pub fn pump(self: *Server, session: *Session) !void {
        // A request executes exactly once, only when its full reply has room.
        // Leave both buffered requests and unread pipe bytes pending while the
        // client drains output. A burst is backpressure, not a client failure.
        try self.flush();
        if (self.queued != 0 or self.pending_sequence != null) return;
        const revision: ?u64 = if (self.shared) |peer| (try peer.state()).revision else null;
        const scope_changed = self.reported_scope != null and self.reported_scope.? != session.agent_scope;
        const policy_changed = self.reported_revision != null and self.reported_revision != revision;
        if (self.initialized and (scope_changed or policy_changed)) {
            try self.queue("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            self.reported_scope = session.agent_scope;
            self.reported_revision = revision;
            try self.flush();
            if (self.queued != 0) return;
        }
        self.reported_scope = session.agent_scope;
        self.reported_revision = revision;
        if (!self.input_eof and self.used < self.input.len) {
            var fd = c.pollfd{ .fd = self.input_fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&fd, 1, 0) > 0 and fd.revents & (c.POLLIN | c.POLLHUP) != 0) {
                const n = c.read(self.input_fd, self.input[self.used..].ptr, self.input.len - self.used);
                if (n < 0 and std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) return error.McpInputClosed;
                if (n == 0) self.input_eof = true;
                if (n > 0) self.used += @intCast(n);
            }
        }
        // Keep target polling and the GUI responsive even for notification or
        // tiny-response floods. Buffered lines are processed without new input.
        for (0..self.request_limit) |_| {
            const end = std.mem.indexOfScalar(u8, self.input[0..self.used], '\n') orelse {
                if (self.used == self.input.len) return error.McpRequestTooLarge;
                if (self.input_eof) self.closed = true;
                return;
            };
            self.handle(session, self.input[0..end]) catch |err| {
                if (err == error.OwnerQueueBusy) return;
                return err;
            };
            if (self.pending_sequence != null) return;
            const consumed = end + 1;
            self.consumeInput(consumed);
            try self.flush();
            if (self.queued != 0) return;
        }
    }
    /// Owner only; release a command response before beginning another slow
    /// capture. Writes are nonblocking and retain unsent bytes for the pump.
    pub fn flush(self: *Server) !void {
        if (self.sent < self.queued) {
            const n = c.write(self.output_fd, self.output[self.sent..].ptr, self.queued - self.sent);
            if (n > 0) {
                self.sent += @intCast(n);
                self.transmitted +%= @intCast(n);
            } else if (n < 0 and std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) return error.McpOutputClosed;
            if (self.sent == self.queued) {
                self.sent = 0;
                self.queued = 0;
            }
        }
    }
};

fn inlineDepth(args: Value) !usize {
    const n = if (member(args, "inline_depth")) |v| number(v) orelse return error.InvalidArguments else 0;
    if (n > 64) return error.InvalidArguments;
    return @intCast(n);
}

test "every advertised tool has a unique name and explicit session access classification" {
    const catalog = @import("tool_catalog.zig");
    var failure: ?catalog.Failure = null;
    try catalog.validate(std.testing.allocator, &.{
        .{ .name = "debugger", .text = tool_definitions, .group = .native },
        .{ .name = "imported", .text = @import("imported.zig").definitions, .group = .imported },
        .{ .name = "session", .text = shared_context.definitions, .group = .session },
    }, &failure);
}

test "one oversized reply returns a protocol error and preserves the server" {
    const a = std.testing.allocator;
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    const huge = try a.alloc(u8, server.output.len);
    defer a.free(huge);
    @memset(huge, 'x');
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try server.reply(arena.allocator(), .{ .integer = 7 }, huge);
    const reply = try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{});
    defer reply.deinit();
    try std.testing.expectEqual(7, member(reply.value, "id").?.integer);
    try std.testing.expectEqual(-32000, member(member(reply.value, "error").?, "code").?.integer);
    try std.testing.expect(!server.closed);
}

test "queued tools preserve client and lease identity at execution" {
    const socket = @cImport({
        @cInclude("sys/socket.h");
        @cInclude("sys/un.h");
        @cInclude("unistd.h");
    });
    const service_c = shared_context.c;
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    // Io.Dir may use O_PATH, which fchmod does not accept.
    if (@import("../c.zig").api.fchmodat(temporary.dir.handle, ".", @as(c_uint, 0o700), 0) != 0) return error.TestPrivateDirectoryFailed;
    const directory = try temporary.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/peer.sock", .{directory}, 0);
    defer a.free(path);
    const service = service_c.xsvc_open(path.ptr) orelse return error.SessionSocketUnavailable;
    defer service_c.xsvc_close(service);
    const fd = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = socket.close(fd);
    var socket_address: socket.struct_sockaddr_un = std.mem.zeroes(socket.struct_sockaddr_un);
    socket_address.sun_family = socket.AF_UNIX;
    try std.testing.expect(path.len < socket_address.sun_path.len);
    @memcpy(socket_address.sun_path[0..path.len], path);
    try std.testing.expectEqual(@as(c_int, 0), socket.connect(fd, @ptrCast(&socket_address), @sizeOf(@TypeOf(socket_address))));
    const now = @import("../target/linux.zig").now;
    var peer: service_c.struct_xsvc_peer = undefined;
    try std.testing.expectEqual(@as(c_int, 1), service_c.xsvc_accept(service, now(), &peer));
    const root = try a.create(Session);
    defer a.destroy(root);
    root.* = Session.init();
    defer root.deinit();
    root.agent_scope = .control;
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{ .shared = .{ .service = service, .client_id = peer.id } };
    defer server.clearPolicies();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    try server.shared.?.tick(root);
    try shared_context.check(service_c.xsvc_claim(service, peer.id, service_c.XSVC_MAX_TTL_MS, now()));
    const Lease = @import("../service/lease.zig").Lease;
    const original = Lease.capture(service, peer.id).?;
    const actor: @import("../model/remote_owner.zig").Actor = .{ .agent = .{ .client = peer.id, .lease = original.id } };
    const args = (try std.json.parseFromSlice(Value, scratch, "{\"generation\":0}", .{})).value;
    try root.launch(&.{ "./zig-out/bin/xodb-m1-fixture", "w" });
    // A queued controller creates a job for this accepted peer, even when
    // the session retains another caller's context outside this operation.
    root.agent_client_id = peer.id + 123;
    root.agent_controller = false;
    const search_args = try @import("profile.zig").value(scratch, .{ .generation = root.target.snapshot().generation, .address = "0x1000", .length = 64, .pattern = "ff" });
    _ = try server.queuedTool(scratch, root, actor, "search_memory", search_args);
    try std.testing.expectEqual(@as(c_uint, service_c.XSVC_JOB_SHARED), root.memory.search.?.owner.value.kind);
    try std.testing.expectEqual(peer.id, root.memory.search.?.owner.value.client);
    try std.testing.expectEqual(peer.id + 123, root.agent_client_id.?);
    try std.testing.expect(!root.agent_controller);
    root.memory.search.?.owner = .{};
    const cancel_args = try @import("profile.zig").value(scratch, .{ .id = root.memory.search.?.id });
    _ = try server.queuedTool(scratch, root, actor, "cancel_memory_search", cancel_args);
    try std.testing.expectEqual(.cancelled, root.memory.search.?.state);
    try std.testing.expectEqual(peer.id + 123, root.agent_client_id.?);
    try std.testing.expect(!root.agent_controller);
    // The typed path must not borrow the ambient client's audit identity.
    const api = @import("../model/command.zig");
    const state = root.target.snapshot();
    const rejected_step: api.Request = .{ .stamp = .{ .connection = 7, .session = root.id, .process = root.process_id, .pid = state.pid, .image_epoch = state.image_epoch, .generation = state.generation }, .caller = actor, .operation = .{ .control = .{ .step_instruction = std.math.maxInt(i32) } } };
    root.probe_resume_actor = .human;
    root.probe_resume_lease = null;
    try std.testing.expectError(error.UnknownThread, root.executeCommand(scratch, 7, service, rejected_step));
    try std.testing.expectEqual(.human, root.probe_resume_actor);
    try std.testing.expect(root.probe_resume_lease == null);
    const typed: api.Request = .{ .stamp = .{ .connection = 7, .session = root.id, .process = root.process_id, .pid = state.pid, .image_epoch = state.image_epoch, .generation = 0 }, .caller = actor, .operation = .{ .control = .cancel_continue } };
    _ = try root.executeCommand(scratch, 7, service, typed);
    try std.testing.expectEqual(peer.id, root.audit[root.audit_count - 1].client_id.?);
    try std.testing.expectEqual(peer.id + 123, root.agent_client_id.?);
    try std.testing.expect(root.agent_lease == null);
    try std.testing.expect(!root.agent_controller);
    root.pending_continue = .{ .generation = root.target.snapshot().generation, .epoch = root.target.snapshot().image_epoch, .actor = .agent, .lease = original };
    try shared_context.check(service_c.xsvc_release(service, peer.id, now()));
    try shared_context.check(service_c.xsvc_claim(service, peer.id, service_c.XSVC_MAX_TTL_MS, now()));
    try std.testing.expect(original.id != Lease.capture(service, peer.id).?.id);
    try std.testing.expectError(error.ControlLeaseRequired, root.executeCommand(scratch, 7, service, typed));
    try root.poll();
    try std.testing.expect(root.pending_continue == null);
    try std.testing.expectEqual(.stopped, root.target.snapshot().state);
    try std.testing.expectError(error.ControlLeaseRequired, server.queuedTool(scratch, root, actor, "continue", args));
    try std.testing.expectError(error.ControlLeaseRequired, server.queuedTool(scratch, root, actor, "remove_language_watch", args));
    try std.testing.expectEqual(@as(usize, 1), root.audit_count);
    const fresh_actor: @import("../model/remote_owner.zig").Actor = .{ .agent = .{ .client = peer.id, .lease = Lease.capture(service, peer.id).?.id } };
    root.agent_scope = .observe;
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, fresh_actor, "add_language_watch", args));
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, fresh_actor, "remove_language_watch", args));
    // Observers still read without a controller lease; unknown peers cannot
    // inherit another accepted connection's Server or a recycled identity.
    _ = try server.queuedTool(scratch, root, actor, "get_session", .{ .object = .empty });
    try std.testing.expectError(error.UnknownSessionClient, server.queuedTool(scratch, root, .{ .agent = .{ .client = peer.id + 1, .lease = null } }, "get_session", .{ .object = .empty }));
    try std.testing.expectError(error.ProtocolActorRequired, server.queuedTool(scratch, root, .human, "get_session", .{ .object = .empty }));
    try shared_context.check(service_c.xsvc_drop(service, peer.id, now()));
    try std.testing.expectError(error.UnknownSessionClient, server.queuedTool(scratch, root, actor, "get_session", .{ .object = .empty }));
}

test "queued protocol preserves request IDs and pipelined bytes across backpressure" {
    const boundary = @import("../model/remote_owner.zig");
    const a = std.testing.allocator;
    var queue: boundary.Queue = .{};
    defer queue.deinit();
    const root = try a.create(Session);
    defer a.destroy(root);
    root.* = Session.init();
    defer root.deinit();
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{ .owner_queue = &queue, .owner_connection = 17, .initialized = true };
    const first = "{\"jsonrpc\":\"2.0\",\"id\":\"one\\ntwo\",\"method\":\"tools/call\",\"params\":{\"name\":\"get_session\",\"arguments\":{}}}";
    const next = "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"ping\"}\n";
    const input = first ++ "\n" ++ next;
    @memcpy(server.input[0..input.len], input);
    server.used = input.len;
    // Fill user capacity with commands that have not executed. Admission must
    // retain the original protocol line and produce neither a reply nor a job.
    for (0..boundary.max_commands) |_| {
        const command = try boundary.Command.create(a, .{ .stamp = .{ .connection = 17, .session = root.id, .process = 1, .pid = 0, .image_epoch = 0, .generation = 0 }, .actor = .human, .action = .{ .control = .continue_execution } });
        _ = try queue.trySubmit(command);
    }
    try std.testing.expectError(error.OwnerQueueBusy, server.handle(root, server.input[0..first.len]));
    try std.testing.expect(server.pending_sequence == null);
    try std.testing.expectEqual(@as(usize, 0), server.queued);
    try std.testing.expectEqualStrings(input, server.input[0..server.used]);
    while (try queue.take()) |_| queue.finish();
    try server.handle(root, server.input[0..first.len]);
    const sequence = server.pending_sequence.?;
    const command = (try queue.take()).?;
    try std.testing.expectEqual(sequence, command.sequence);
    try std.testing.expectEqualStrings("get_session", command.request.action.mcp.name);
    try std.testing.expectEqual(@as(u64, 17), command.request.stamp.connection);
    try std.testing.expectEqual(@as(usize, 0), server.queued);
    try server.completeQueued(sequence, "{\"generation\":7,\"view\":{\"bits\":9007199254740993,\"address\":18446744073709551615}}");
    queue.finish();
    try std.testing.expect((try queue.take()) == null);
    try std.testing.expectEqualStrings(next, server.input[0..server.used]);
    const response = try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{});
    defer response.deinit();
    try std.testing.expectEqualStrings("one\ntwo", response.value.object.get("id").?.string);
    try std.testing.expectEqual(@as(i64, 7), response.value.object.get("result").?.object.get("structuredContent").?.object.get("generation").?.integer);
    const result = response.value.object.get("result").?;
    const structured = result.object.get("structuredContent").?;
    const view = structured.object.get("view").?;
    try std.testing.expectEqualStrings("0x20000000000001", view.object.get("bits_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", view.object.get("address_hex").?.string);
    const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
    const encoded = try std.json.Stringify.valueAlloc(a, structured, .{});
    defer a.free(encoded);
    try std.testing.expectEqualStrings(encoded, text);
    try std.testing.expectError(error.StaleReply, server.completeQueued(sequence, "{}"));
}

test "migrated queued tools carry typed operations and separate reply routing" {
    const boundary = @import("../model/remote_owner.zig");
    const a = std.testing.allocator;
    const root = try a.create(Session);
    defer a.destroy(root);
    root.* = Session.init();
    defer root.deinit();
    root.agent_scope = .control;
    var queue: boundary.Queue = .{};
    defer queue.deinit();
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{ .owner_queue = &queue, .owner_connection = 23 };
    defer server.clearPolicies();
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const args = (try std.json.parseFromSlice(Value, arena.allocator(), "{\"generation\":42,\"symbol\":\"owned_stop\"}", .{})).value;
        try server.enqueueTool(arena.allocator(), root, "set_breakpoint", args, 1);
    }
    const queued = (try queue.take()).?;
    try std.testing.expect(queued.request.protocol_reply);
    try std.testing.expectEqual(@as(u64, 42), queued.request.stamp.generation);
    try std.testing.expectEqual(@as(u64, 23), queued.request.stamp.connection);
    try std.testing.expectEqualStrings("owned_stop", queued.request.action.breakpoint.symbol);
    try std.testing.expectEqual(@as(u64, 0), queued.request.actor.agent.client);
    queue.finish();
}

test "tool policy cache is mode-specific and does not cache authorization" {
    const a = std.testing.allocator;
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    defer server.clearPolicies();
    const control = try server.toolPolicy(tool_definitions, "add_language_watch");
    try std.testing.expect(control.localAllowed(.control, true));
    try std.testing.expect(!(try server.toolPolicy(tool_definitions, "add_language_watch")).localAllowed(.observe, true));
    try std.testing.expectError(error.UnknownTool, server.toolPolicy(overview.definitions, "add_language_watch"));
    try std.testing.expectError(error.UnknownTool, server.toolPolicy(@import("imported.zig").definitions, "write_memory"));
    try std.testing.expectEqual(shared_context.Access.mutator, (try server.toolPolicy(tool_definitions, "write_memory")).required);
}

test "layout is an observer publication even without a target or GUI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    defer server.clearPolicies();
    const session = try a.create(Session);
    session.* = Session.init();
    defer session.deinit();
    const args = (try std.json.parseFromSlice(Value, a, "{}", .{})).value;
    @import("../layout_snapshot.zig").unavailable();
    for ([_]bool{ false, true }) |overview_only| {
        server.overview_only = overview_only;
        const result = try server.tool(a, session, "get_layout", args);
        try std.testing.expect(!result.object.get("available").?.bool);
        try std.testing.expectEqual(@as(usize, 0), result.object.get("panes").?.array.items.len);
        try std.testing.expectEqual(@as(i64, 640), result.object.get("window").?.object.get("minimum_width").?.integer);
    }
}

test "tool replies preserve numeric fields and share exact structured and text results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const result = try asValue(a, .{ .rows = .{.{ .address = @as(u64, 9007199254740993), .slot_address = std.math.maxInt(u64), .offset = std.math.minInt(i64) }} });
    try server.toolReply(a, .{ .integer = 1 }, result);
    const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value.object.get("result").?;
    const structured = reply.object.get("structuredContent").?;
    const text = reply.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(text, try std.json.Stringify.valueAlloc(a, structured, .{}));
    const row = structured.object.get("rows").?.array.items[0];
    try std.testing.expectEqual(@as(i64, 9007199254740993), row.object.get("address").?.integer);
    try std.testing.expectEqualStrings("0x20000000000001", row.object.get("address_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", row.object.get("slot_address_hex").?.string);
    try std.testing.expectEqualStrings("-0x8000000000000000", row.object.get("offset_hex").?.string);
}

test "hex expansion obeys the reply cap and leaves the next request usable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const Row = struct { address: u64 };
    const rows = try a.alloc(Row, 10000);
    for (rows) |*row| row.* = .{ .address = std.math.maxInt(u64) };
    const value = try asValue(a, rows);
    const old_text = try std.json.Stringify.valueAlloc(a, value, .{});
    const old_reply = try std.json.Stringify.valueAlloc(a, .{ .structuredContent = value, .isError = false, .content = .{.{ .type = "text", .text = old_text }} }, .{});
    try std.testing.expect(old_reply.len < server.output.len);
    try server.toolReply(a, .{ .integer = 1 }, value);
    const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
    try std.testing.expectEqual(-32000, reply.object.get("error").?.object.get("code").?.integer);
    try std.testing.expect(!server.closed);
    server.queued = 0; // Previous reply drained by the peer.
    try server.toolReply(a, .{ .integer = 2 }, try asValue(a, .{ .address = @as(u64, 9007199254740993) }));
    const next = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
    try std.testing.expectEqualStrings("0x20000000000001", next.object.get("result").?.object.get("structuredContent").?.object.get("address_hex").?.string);
}

test "invalid exact-word replies stay tool errors and the next reply succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const cases = [_]struct { json: []const u8, reason: []const u8 }{
        .{ .json = "{\"address\":7,\"address_hex\":\"0x9\"}", .reason = "ConflictingEvidenceWord" },
        .{ .json = "{\"address\":18446744073709551616}", .reason = "InvalidEvidenceWord" },
        .{ .json = "{\"offset\":-9223372036854775809}", .reason = "InvalidEvidenceWord" },
    };
    for (cases) |case| {
        server.queued = 0;
        const bad = (try std.json.parseFromSlice(Value, a, case.json, .{})).value;
        try server.toolReply(a, .{ .string = "word-error" }, bad);
        const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
        try std.testing.expectEqualStrings("word-error", reply.object.get("id").?.string);
        const result = reply.object.get("result").?;
        try std.testing.expect(result.object.get("isError").?.bool);
        try std.testing.expect(!result.object.contains("structuredContent"));
        try std.testing.expectEqualStrings(case.reason, result.object.get("content").?.array.items[0].object.get("text").?.string);
        try std.testing.expect(!server.closed);
        server.queued = 0;
        try server.toolReply(a, .{ .integer = 2 }, try asValue(a, .{ .address = @as(u64, 9007199254740993) }));
        const next = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
        try std.testing.expectEqualStrings("0x20000000000001", next.object.get("result").?.object.get("structuredContent").?.object.get("address_hex").?.string);
    }
}

test {
    std.testing.refAllDecls(@import("module_list.zig"));
}

test {
    std.testing.refAllDecls(@import("list_page.zig"));
    std.testing.refAllDecls(@import("locals_list.zig"));
    std.testing.refAllDecls(@import("debug_files.zig"));
}

test "queued stdio commands recheck live scope and capture requests keep separate consent" {
    const a = std.testing.allocator;
    const root = try a.create(Session);
    defer a.destroy(root);
    root.* = Session.init();
    defer root.deinit();
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    defer server.clearPolicies();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const actor: @import("../model/remote_owner.zig").Actor = .{ .agent = .{ .client = 0, .lease = null } };
    root.agent_scope = .control;
    _ = try server.toolPolicy(tool_definitions, "add_language_watch");
    // The queue retains identity, never a cached authorization decision.
    root.agent_scope = .observe;
    const definitions = try std.json.parseFromSlice(Value, scratch, tool_definitions, .{});
    var checked: usize = 0;
    for (definitions.value.array.items) |definition| {
        if (try shared_context.readOnly(definition)) continue;
        const name = string(member(definition, "name")).?;
        if (try shared_context.access(definition) == .requester) {
            try std.testing.expect(std.mem.eql(u8, name, "request_system_capture") or std.mem.eql(u8, name, "cancel_system_capture"));
            continue;
        }
        try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, name, .{ .object = .empty }));
        checked += 1;
    }
    const request = try std.json.parseFromSlice(Value, scratch, "{\"kind\":\"fd_flow\",\"duration_ms\":100}", .{});
    try std.testing.expectError(error.CaptureRequestsUnavailable, server.queuedTool(scratch, root, actor, "request_system_capture", request.value));
    server.overview.capture.mode = .headless;
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, "request_system_capture", request.value));
    try std.testing.expect(server.overview.capture.current == null);
    try std.testing.expect(checked >= 50);
    root.agent_scope = .control;
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, "write_memory", .{ .object = .empty }));
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, "write_register", .{ .object = .empty }));
    _ = try server.queuedTool(scratch, root, actor, "get_session", .{ .object = .empty });
    try std.testing.expectEqual(@as(usize, 0), root.audit_count);
}

test "queued retained jobs use per-call requester and distinguish shared scope" {
    const a = std.testing.allocator;
    const root = try a.create(Session);
    defer a.destroy(root);
    root.* = Session.init();
    defer root.deinit();
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    defer server.clearPolicies();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const actor: @import("../model/remote_owner.zig").Actor = .{ .agent = .{ .client = 0, .lease = null } };
    root.agent_scope = .observe;
    root.agent_client_id = 7;
    root.agent_controller = true;
    root.memory.search = .{ .ranges = &.{}, .owner = @import("../service/job_owner.zig").Owner.agent(null), .id = 1, .generation = 1, .image_epoch = 0, .address = 4096, .length = 64, .pattern_len = 1 };
    const args = try @import("profile.zig").value(scratch, .{ .id = 1 });
    _ = try server.queuedTool(scratch, root, actor, "cancel_memory_search", args);
    try std.testing.expectEqual(.cancelled, root.memory.search.?.state);
    try std.testing.expectEqual(@as(?u64, 7), root.agent_client_id);
    try std.testing.expect(root.agent_controller);
    root.memory.search.?.state = .running;
    root.memory.search.?.owner = .{};
    try std.testing.expectError(error.JobNotOwned, server.queuedTool(scratch, root, actor, "cancel_memory_search", args));
    try std.testing.expectEqual(.running, root.memory.search.?.state);
    // GUI/shared sessions deny even target-read-only job starters at the
    // common dispatcher. An already cached private policy cannot override it.
    root.shared_jobs = true;
    try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, "cancel_memory_search", args));
    const definitions = try std.json.parseFromSlice(Value, scratch, tool_definitions, .{});
    var checked: usize = 0;
    for (definitions.value.array.items) |definition| {
        const policy = try shared_context.Policy.fromDefinition(definition);
        if (!policy.read_only or policy.required != .controller) continue;
        const name = string(member(definition, "name")).?;
        try std.testing.expectError(error.AgentScopeDenied, server.queuedTool(scratch, root, actor, name, .{ .object = .empty }));
        checked += 1;
    }
    try std.testing.expect(checked >= 15);
    try std.testing.expectEqual(.running, root.memory.search.?.state);
}
