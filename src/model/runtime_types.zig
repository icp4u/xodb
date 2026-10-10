//! Stop-pinned runtime type providers. Interpretation and worker lifetime are C;
//! this adapter binds captures/results to a session and retained stop.
const std = @import("std");
const c = @import("../c.zig").api;
const jobs = @import("../service/job_owner.zig");
pub const max_contexts = 4;
pub const Entry = struct {
    id: u64,
    owner: jobs.Owner,
    session_id: u64,
    generation: u64,
    image_epoch: u64,
    job: *c.struct_xjai_job,
    ranges: [16]c.struct_xjai_write_range = undefined,
    range_count: usize = 0,
    pub fn poll(self: Entry) c.struct_xjai_job_snapshot {
        var result: c.struct_xjai_job_snapshot = undefined;
        c.xjai_job_poll(self.job, &result);
        return result;
    }
    pub fn graph(self: Entry) !*const c.struct_xjai_graph {
        const result = self.poll();
        if (result.state == c.XJAI_JOB_PENDING) return error.RuntimeTypesPending;
        if (result.state == c.XJAI_JOB_FAILED or result.graph == null) return error.RuntimeTypesFailed;
        return @ptrCast(result.graph);
    }
    pub fn stale(self: Entry, session: anytype) bool {
        const state = session.target.snapshot();
        return self.session_id != session.id or self.image_epoch != state.image_epoch or self.generation != state.generation;
    }
    pub fn requireStop(self: Entry, session: anytype) !void {
        if (self.stale(session)) return error.RuntimeTypesStale;
        if (session.target.snapshot().state != .stopped) return error.NotStopped;
    }
};
pub const Cache = struct {
    entries: [max_contexts]?Entry = @splat(null),
    next_id: u64 = 1,
    /// A completed worker may become visible without a target generation change.
    pub fn signature(self: *const Cache) u64 {
        var hash = std.hash.Wyhash.init(self.next_id);
        for (self.entries) |entry| if (entry) |e| {
            hash.update(std.mem.asBytes(&e.id));
            const state = e.poll().state;
            hash.update(std.mem.asBytes(&state));
        };
        return hash.final();
    }
    /// A verified data-only write cannot change the protected metadata captures.
    pub fn advance(self: *Cache, session: anytype, before: u64) void {
        const state = session.target.snapshot();
        for (&self.entries) |*slot| if (slot.*) |*e| {
            if (e.session_id == session.id and e.image_epoch == state.image_epoch and e.generation == before)
                e.generation = state.generation;
        };
    }
    pub fn deinit(self: *Cache) void {
        for (&self.entries) |*entry| if (entry.*) |e| {
            c.xjai_job_release(e.job);
            entry.* = null;
        };
    }
    pub fn find(self: *const Cache, id: u64) !Entry {
        for (self.entries) |entry| if (entry) |e| {
            if (e.id == id) return e;
        };
        return error.RuntimeTypesExpired;
    }
    pub fn release(self: *Cache, id: u64, requester: jobs.Requester) !void {
        for (&self.entries) |*entry| if (entry.*) |e| {
            if (e.id != id) continue;
            try e.owner.require(requester);
            entry.* = null;
            c.xjai_job_release(e.job);
            return;
        };
        return error.RuntimeTypesExpired;
    }
    pub fn load(self: *Cache, session: anytype, ids: []const u64, requester: jobs.Requester) !u64 {
        const state = session.target.snapshot();
        if (state.state != .stopped) return error.NotStopped;
        if (ids.len == 0 or ids.len > 16) return error.InvalidArguments;
        try session.refreshMaps();
        var regions: [16]c.struct_xjai_region = undefined;
        var total: usize = 0;
        for (ids, 0..) |id, i| {
            const capture = try session.memory.find(id);
            if (capture.session_id != session.id or capture.image_epoch != state.image_epoch or capture.generation != state.generation) return error.RuntimeTypesStale;
            if (capture.readable != capture.bytes.len) return error.RuntimeTypesCaptureUnreadable;
            const end = std.math.add(u64, capture.address, capture.bytes.len) catch return error.InvalidMemoryRange;
            const readonly = for (session.modules.regions.items) |region| {
                if (capture.address >= region.start and end <= region.end and region.permissions[0] == 'r' and region.permissions[1] != 'w') break true;
            } else false;
            if (!readonly) return error.RuntimeTypesNeedReadonlyCapture;
            total += capture.bytes.len;
            if (total > 32 * 1024 * 1024) return error.RuntimeTypesCaptureLimit;
            regions[i] = .{ .address = capture.address, .data = capture.bytes.ptr, .size = capture.bytes.len };
        }
        std.mem.sort(c.struct_xjai_region, regions[0..ids.len], {}, struct {
            fn less(_: void, a: c.struct_xjai_region, b: c.struct_xjai_region) bool {
                return a.address < b.address;
            }
        }.less);
        // Reserve a permitted slot before starting; publication replaces it only
        // after input copying/thread creation succeeds. A peer's work survives.
        var slot: ?usize = null;
        for (self.entries, 0..) |entry, i| {
            if (entry == null) {
                slot = i;
                break;
            }
            entry.?.owner.require(requester) catch continue;
            if (slot == null or entry.?.id < self.entries[slot.?].?.id) slot = i;
        }
        const index = slot orelse return error.JobNotOwned;
        if (self.next_id == std.math.maxInt(u64)) return error.RuntimeTypesIdLimit;
        try session.target.expectGeneration(state.generation);
        const image = c.struct_xjai_image{ .regions = &regions, .count = ids.len };
        var job: ?*c.struct_xjai_job = null;
        if (c.xjai_job_start(&image, &job)) |reason| {
            if (std.mem.eql(u8, std.mem.span(reason), "JaiWorkerBusy")) return error.RuntimeTypesBusy;
            if (std.mem.eql(u8, std.mem.span(reason), "JaiOutOfMemory")) return error.OutOfMemory;
            return error.RuntimeTypesInvalidCapture;
        }
        if (self.entries[index]) |old| c.xjai_job_release(old.job);
        const id = self.next_id;
        self.next_id += 1;
        self.entries[index] = .{ .id = id, .owner = requester.owner, .session_id = session.id, .generation = state.generation, .image_epoch = state.image_epoch, .job = job.? };
        for (regions[0..ids.len], 0..) |r, i| self.entries[index].?.ranges[i] = .{ .address = r.address, .size = r.size };
        self.entries[index].?.range_count = ids.len;
        return id;
    }
};
