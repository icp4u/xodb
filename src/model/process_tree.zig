//! One ptrace owner thread, stable per-process sessions. UI selection does not
//! change MCP's default target: requests without process_id always use the root.
const std = @import("std");
const model = @import("session.zig");
const linux = @import("../target/linux.zig");
const A = std.heap.page_allocator;
pub const maximum = 1024;
pub const Entry = struct {
    id: u64,
    parent: ?u64,
    session: *model.Session,
    kind: ?linux.BirthKind = null,
    last_generation: u64 = 0,
    failed_generation: ?u64 = null,
    admission_error: ?[]const u8 = null,
};
pub const Tree = struct {
    entries: [maximum]Entry = undefined,
    count: usize = 0,
    selected: usize = 0,
    limit: usize = 32,
    revision: u64 = 1,
    pub fn init(self: *Tree, first: *model.Session) void {
        std.debug.assert(self.count == 0 and first.process_tree == null);
        self.entries[0] = .{ .id = 1, .parent = null, .session = first };
        self.count = 1;
        first.process_tree = self;
        first.process_id = 1;
    }
    pub fn root(self: *Tree) *model.Session {
        return self.entries[0].session;
    }
    pub fn active(self: *Tree) *model.Session {
        return self.entries[self.selected].session;
    }
    pub fn find(self: *Tree, id: u64) !*Entry {
        for (self.entries[0..self.count]) |*entry| if (entry.id == id) return entry;
        return error.UnknownProcess;
    }
    pub fn select(self: *Tree, id: u64) !void {
        _ = try self.find(id);
        self.selected = @intCast(id - 1);
        self.revision += 1;
    }
    pub fn setLimit(self: *Tree, limit: usize) !void {
        if (limit == 0 or limit > maximum or limit < self.count) return error.InvalidProcessLimit;
        self.limit = limit;
        self.retryAdmissions();
    }
    pub fn retryAdmissions(self: *Tree) void {
        for (self.entries[0..self.count]) |*entry| {
            entry.failed_generation = null;
            entry.admission_error = null;
        }
        self.revision += 1;
    }
    pub fn setFollowing(self: *Tree, session: *model.Session, enabled: bool, limit: ?usize, actor: model.Actor) !void {
        if (session.offline or session.imported != null) return error.OfflineSession;
        if (limit) |n| if (n == 0 or n > maximum or n < self.count) return error.InvalidProcessLimit;
        if (session.target.core != null) return error.ReadOnlyCore;
        if (session.target.state != .stopped) return error.NotStopped;
        if (session.target.follow_processes != enabled) try session.target.setFollowProcesses(enabled) else session.target.generation += 1;
        if (limit) |n| try self.setLimit(n);
        session.record(actor, "set_process_following");
        self.revision += 1;
    }
    fn familyRoot(target: *linux.Target) *linux.Target {
        var root_target = target;
        while (root_target.vfork_parent) |parent| root_target = parent;
        return root_target;
    }
    pub fn detachFamily(self: *Tree, session: *model.Session, actor: model.Actor) !void {
        if (session.offline or session.imported != null) return error.OfflineSession;
        if (session.target.core != null) return error.ReadOnlyCore;
        if (session.target.state == .idle or session.target.state == .exited) return error.InvalidState;
        const family = familyRoot(&session.target);
        var affected: [maximum]*model.Session = undefined;
        var n: usize = 0;
        for (self.entries[0..self.count]) |entry| if (familyRoot(&entry.session.target) == family) {
            affected[n] = entry.session;
            n += 1;
            entry.session.cancelStep();
            entry.session.allocations.stop(.target_ended);
            if (entry.session.profile) |capture| if (capture.collector != null) try entry.session.stopProfile();
        };
        try session.target.detachProcessFamily();
        for (affected[0..n]) |member| member.record(actor, "detach_process_family");
        self.retryAdmissions();
    }
    pub fn setScope(self: *Tree, scope: model.AgentScope) void {
        for (self.entries[0..self.count]) |entry| {
            entry.session.agent_scope = scope;
            entry.session.target.generation += 1;
            entry.session.record(.human, "set_agent_scope");
        }
        self.revision += 1;
    }
    pub fn poll(self: *Tree) !void {
        // New entries start polling on the following event-loop iteration.
        const end = self.count;
        for (self.entries[0..end]) |*entry| {
            entry.session.poll() catch |err| {
                entry.session.cancelStep();
                entry.session.step_diagnostic = @errorName(err);
                if (entry.last_generation != entry.session.target.generation)
                    std.debug.print("xodb: process #{d} pid={d} poll: {s}; target retained\n", .{ entry.id, entry.session.target.pid, @errorName(err) });
            };
            if (entry.last_generation != entry.session.target.generation) {
                self.revision += 1;
                entry.last_generation = entry.session.target.generation;
            }
        }
    }
    pub fn admit(self: *Tree, parent: *model.Session) void {
        if (parent.target.birth_count == 0 or parent.target.state != .stopped) return;
        const entry = self.find(parent.process_id) catch return;
        if (entry.failed_generation == parent.target.generation) return;
        // At most one admission per parent per poll; mappings load on demand.
        for (parent.target.births[0..parent.target.birth_count]) |birth| {
            if (!birth.stopped and !birth.exited) continue;
            self.adopt(parent, birth) catch |err| {
                entry.failed_generation = parent.target.generation;
                entry.admission_error = @errorName(err);
                std.debug.print("xodb: process #{d} child pid={d} held: {s}\n", .{ parent.process_id, birth.pid, @errorName(err) });
                self.revision += 1;
                return;
            };
            entry.failed_generation = null;
            entry.admission_error = null;
            return;
        }
    }
    fn adopt(self: *Tree, parent: *model.Session, birth: linux.Birth) !void {
        if (!parent.target.follow_processes) return error.ProcessFollowingDisabled;
        if (self.count == self.limit) return error.ProcessLimit;
        const child = try A.create(model.Session);
        child.* = model.Session.init();
        errdefer {
            child.deinit();
            A.destroy(child);
        }
        child.agent_scope = self.root().agent_scope;
        child.profile_defaults = parent.profile_defaults;
        child.allocation_defaults = parent.allocation_defaults;
        child.allocation_helper = parent.allocation_helper;
        child.symbol_files = self.root().symbolFiles();
        child.source_map_owner = self.root().sourceMaps();
        // Clone logical policies before the kernel child is transferred: any
        // allocation failure leaves that birth safely owned by its parent.
        try parent.persistent.copyForFork(&child.persistent);
        for (parent.probes.rules, &child.probes.rules) |rule, *copy| {
            copy.* = rule;
            copy.matched_hits = 0;
            copy.last_error = null;
        }
        const event = try parent.target.adoptChild(birth.pid, &child.target);
        child.process_id = self.count + 1;
        child.process_tree = self;
        child.persistent.epoch = child.target.image_epoch;
        child.persistent.observed = 0;
        for (child.target.breakpoints[0..child.target.breakpoint_count]) |*probe| probe.hit_count = 0;
        if (child.target.thread_count != 0) {
            // Do not accidentally bind an absent parent's thread filter to a
            // new child thread with a reused small debugger ID.
            const new_id = parent.target.next_thread_id;
            child.target.threads[0].id = new_id;
            child.target.next_thread_id = new_id + 1;
            var parent_thread_id: ?u64 = null;
            for (parent.target.threadSlice()) |thread| if (thread.tid == birth.parent_tid) {
                parent_thread_id = thread.id;
            };
            for (&child.probes.rules) |*rule| if (rule.thread_id) |wanted| {
                if (parent_thread_id == wanted) rule.thread_id = new_id else rule.last_error = "InheritedThreadFilterNotPresent";
            };
        }
        child.suppress_probe_resume = true;
        self.entries[self.count] = .{ .id = child.process_id, .parent = parent.process_id, .session = child, .kind = event.kind };
        self.count += 1;
        self.revision += 1;
        std.debug.print("xodb: process #{d} pid={d} {s} from #{d}; stopped for inspection\n", .{ child.process_id, child.target.pid, @tagName(event.kind), parent.process_id });
    }
    pub fn deinit(self: *Tree) void {
        // Release all target links before freeing any session. A failed detach
        // must not leave a dangling vfork pointer for a later parent's cleanup.
        var cleanup = self.count;
        while (cleanup > 1) {
            cleanup -= 1;
            self.entries[cleanup].session.target.deinit();
        }
        var remaining = self.count;
        while (remaining > 1) {
            remaining -= 1;
            const child = self.entries[remaining].session;
            child.process_tree = null;
            if (child.target.pid != 0 or child.target.sharedVm()) {
                // Main is shutting down. Keep storage alive for the root's
                // final cleanup retry; a leaked shutdown allocation is safer
                // than destroying a still-linked target.
                std.debug.print("xodb: process #{d} cleanup incomplete; retaining target storage for final shutdown retry\\n", .{child.process_id});
                continue;
            }
            child.deinit();
            A.destroy(child);
        }
        if (self.count > 0) self.root().process_tree = null;
        self.count = 0;
    }
};
