//! Owner-prepared inline scopes and read-only expression results.
const std = @import("std");
const model = @import("session.zig");
const linux = @import("../target/linux.zig");
pub const Request = struct { generation: u64, tid: i32, frame: usize, depth: usize };
pub const Key = struct { session: u64, image: u64, metadata: u64, request: Request };
pub const View = struct {
    key: ?Key = null,
    state: linux.State = .idle,
    frame: ?model.Frame = null,
    locals: []const @import("debugger_view.zig").LocalRow = &.{},
    diagnostic: ?[]const u8 = null,
};
comptime {
    @setEvalBranchQuota(10000);
    @import("debugger_view.zig").requireImmutable(View);
}
pub const Capture = struct {
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: View = .{},
    pub fn deinit(self: *Capture) void {
        self.arena.deinit();
    }
    pub fn clear(self: *Capture) void {
        _ = self.arena.reset(.free_all);
        self.value = .{};
    }
    pub fn refresh(self: *Capture, session: *model.Session, wanted: ?Request) void {
        var request = wanted orelse {
            self.clear();
            return;
        };
        const state = session.target.snapshot();
        if (request.generation != state.generation) request.depth = 0;
        request.generation = state.generation;
        const key: Key = .{ .session = session.id, .image = state.image_epoch, .metadata = session.metadata.revision, .request = request };
        if (self.value.key != null and std.meta.eql(self.value.key.?, key)) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .key = key, .state = state.state };
        if (state.state != .stopped) return;
        self.prepare(session, request) catch |err| {
            self.value.diagnostic = @errorName(err);
        };
    }
    fn prepare(self: *Capture, session: *model.Session, request: Request) !void {
        const a = self.arena.allocator();
        if (request.frame == std.math.maxInt(usize)) return error.FrameUnavailable;
        const frames = try session.stack(a, request.tid, request.frame + 1);
        if (request.frame >= frames.len) return error.FrameUnavailable;
        const frame = frames[request.frame];
        self.value.frame = frame;
        const depth = @min(request.depth, frame.inline_frames.len);
        self.value.key.?.request.depth = depth;
        const locals = try session.frameLocalsAtDepth(a, frame, depth);
        const rows = try a.alloc(@import("debugger_view.zig").LocalRow, locals.len);
        var count: usize = 0;
        for (locals) |local| {
            const summary = session.summarize(a, local.value) catch |err| {
                self.value.diagnostic = @errorName(err);
                break;
            };
            rows[count] = .{ .name = local.name, .value = summary };
            count += 1;
        }
        self.value.locals = rows[0..count];
    }
};

pub const Expression = struct { tid: i32, frame: usize, depth: usize, metadata: u64, text: []const u8 };
/// Fixed completion storage keeps delivery and retirement off the frame allocator.
pub const Message = struct {
    bytes: [512]u8 = @splat(0),
    len: usize = 0,
    pub fn slice(self: *const Message) []const u8 {
        return self.bytes[0..self.len];
    }
};
pub fn evaluate(session: *model.Session, request: Expression) !Message {
    if (request.metadata != session.metadata.revision) return error.StaleSnapshot;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try session.evaluateAtDepth(a, request.tid, request.frame, request.depth, request.text);
    const summary = try session.summarize(a, value);
    if (request.metadata != session.metadata.revision) return error.StaleSnapshot;
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s} = {s} ({s})", .{ request.text, summary.display, summary.type }) catch summary.display;
    var message: Message = .{ .len = @min(text.len, 512) };
    @memcpy(message.bytes[0..message.len], text[0..message.len]);
    return message;
}

test "inline expressions refuse stale metadata before evaluating" {
    var session = model.Session.init();
    defer session.deinit();
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    try std.testing.expectError(error.StaleSnapshot, evaluate(&session, .{ .tid = 1, .frame = 0, .depth = 2, .metadata = session.metadata.revision + 1, .text = "1 + 2" }));
    try std.testing.expectEqual(@as(usize, 0), session.audit_count);
}

test "inline publication retains scope paths and summarized locals after capture release" {
    const boundary = @import("remote_owner.zig");
    var capture: Capture = .{ .arena = .init(std.testing.allocator) };
    defer capture.deinit();
    const a = capture.arena.allocator();
    const name = try a.dupe(u8, "scope");
    const scopes = try a.alloc(@import("../debug/info.zig").Inline, 1);
    scopes[0] = .{ .name = name, .depth = 1, .die_offset = 1, .call_path = try a.dupe(u8, "fixture.c"), .call_line = 7 };
    const rows = try a.alloc(@import("debugger_view.zig").LocalRow, 1);
    rows[0] = .{ .name = name, .value = .{ .type = try a.dupe(u8, "int"), .kind = .signed, .size = 4, .address = null, .bits = 3, .display = try a.dupe(u8, "3"), .availability = .available } };
    capture.value = .{
        .key = .{ .session = 2, .image = 4, .metadata = 5, .request = .{ .generation = 3, .tid = 6, .frame = 0, .depth = 0 } },
        .state = .stopped,
        .frame = .{ .index = 0, .pc = 1, .lookup_pc = 1, .registers = @splat(null), .symbol = name, .inline_frames = scopes },
        .locals = rows,
    };
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 2, .process = 1, .pid = 6, .image_epoch = 4, .generation = 3 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .inline_scope = capture.value,
    });
    defer publication.destroy();
    capture.clear();
    const view = publication.value.inline_scope.?;
    try std.testing.expectEqualStrings("scope", view.frame.?.inline_frames[0].name);
    try std.testing.expectEqualStrings("fixture.c", view.frame.?.inline_frames[0].call_path.?);
    try std.testing.expectEqualStrings("int", view.locals[0].value.type);
    try std.testing.expectEqualStrings("3", view.locals[0].value.display);
    const rt = @import("../target/runtime.zig").c;
    rt.xrt_remote_io_guard(true);
    defer rt.xrt_remote_io_guard(false);
    var panel: @import("../ui/inline.zig").Panel = .{ .open = true };
    panel.present(view);
    try std.testing.expectEqual(@as(usize, 2), panel.scope_count);
    try std.testing.expect(panel.keyView(6, 0, 5, .{ .kind = .press, .shortcut = @import("../platform/input.zig").sym.down }) == .local);
    try std.testing.expectEqual(@as(usize, 1), panel.request(6, 0, 3).?.depth);
    try std.testing.expectEqual(@as(usize, 0), panel.request(6, 0, 4).?.depth);
}
