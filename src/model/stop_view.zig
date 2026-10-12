//! Owner-prepared stop evidence. Rendering never reads the target or maps.
const std = @import("std");
const Session = @import("session.zig").Session;
const linux = @import("../target/linux.zig");
pub const Key = struct {
    session: u64,
    generation: u64,
    image: u64,
    metadata: u64,
    tid: i32,
};
pub const View = struct {
    key: ?Key = null,
    info: ?linux.StopInfo = null,
    source: ?[]const u8 = null,
    mapping: ?[]const u8 = null,
    mapping_missing: bool = false,
    failure: ?[]const u8 = null,
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
    pub fn refresh(self: *Capture, session: *Session, tid: i32, enabled: bool) void {
        if (!enabled) {
            self.clear();
            return;
        }
        const snapshot = session.target.snapshot();
        const key = Key{ .session = session.id, .generation = snapshot.generation, .image = snapshot.image_epoch, .metadata = session.metadata.revision, .tid = tid };
        if (self.value.key != null and std.meta.eql(self.value.key.?, key)) return;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .key = key };
        self.prepare(session, tid) catch |err| {
            self.value.failure = @errorName(err);
        };
    }
    fn prepare(self: *Capture, session: *Session, tid: i32) !void {
        const a = self.arena.allocator();
        var stop = try session.target.stopInfo(tid);
        stop.signal_name = try a.dupe(u8, stop.signal_name);
        if (stop.diagnostic) |message| stop.diagnostic = try a.dupe(u8, message);
        self.value.info = stop;
        if (stop.pc) |pc| {
            const site = session.sourceAt(a, pc) catch null;
            if (site) |source| self.value.source = try std.fmt.allocPrint(a, "{s}:{d}", .{ source.path, source.line });
        }
        if (stop.fault_address) |address| {
            if (session.target.core) |*core| {
                for (core.segments.items) |segment| if (address >= segment.start and address < segment.end) {
                    self.value.mapping = if (address - segment.start < segment.stored) "Fault address lies in captured memory" else "Fault address mapped; bytes omitted from core";
                    break;
                };
            } else {
                session.refreshMaps() catch {};
                const remote_map = session.gdbMap() catch |err| {
                    // Optional map failure must not hide the causal stop.
                    self.value.mapping_missing = true;
                    self.value.mapping = try std.fmt.allocPrint(a, "Fault map unavailable: {s}", .{@errorName(err)});
                    return;
                };
                const regions = if (remote_map) |map| map.regions else session.modules.regions.items;
                for (regions) |region| if (address >= region.start and address < region.end) {
                    self.value.mapping = try std.fmt.allocPrint(a, "Fault mapping: {s} {s}", .{ &region.permissions, region.path });
                    break;
                };
            }
            if (self.value.mapping == null) {
                self.value.mapping_missing = true;
                self.value.mapping = "Fault address has no mapping in the available map snapshot";
            }
        }
    }
};

test "stop publication retains evidence after hidden capture releases storage" {
    const boundary = @import("remote_owner.zig");
    var capture: Capture = .{ .arena = .init(std.testing.allocator) };
    defer capture.deinit();
    const a = capture.arena.allocator();
    capture.value = .{
        .key = .{ .session = 2, .generation = 3, .image = 4, .metadata = 5, .tid = 6 },
        .info = .{ .tid = 6, .reason = .signal, .signal = 11, .signal_name = try a.dupe(u8, "SIGSEGV"), .fault_address = 0x1234, .diagnostic = try a.dupe(u8, "synthetic evidence") },
        .source = try a.dupe(u8, "fixture.c:7"),
        .mapping = try a.dupe(u8, "Fault mapping: rw-p fixture"),
    };
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 2, .process = 1, .pid = 6, .image_epoch = 4, .generation = 3 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .stop = capture.value,
    });
    defer publication.destroy();
    capture.clear();
    try std.testing.expect(capture.value.key == null);
    const view = publication.value.stop.?;
    try std.testing.expectEqualStrings("SIGSEGV", view.info.?.signal_name);
    try std.testing.expectEqualStrings("synthetic evidence", view.info.?.diagnostic.?);
    try std.testing.expectEqualStrings("fixture.c:7", view.source.?);
    try std.testing.expectEqualStrings("Fault mapping: rw-p fixture", view.mapping.?);
}
