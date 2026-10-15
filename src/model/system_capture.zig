//! Overview-owned capture backend. Protocol and view only edit the consent state.
const std = @import("std");
const log = @import("../log.zig");
const system = @import("system.zig");
const c = system.c;
const state = @import("system_capture_state.zig");
const authority = @import("../service/authority.zig");
const identity = @import("process_identity.zig");
const a = std.heap.c_allocator;

pub fn Owner(comptime Session: type) type {
    return struct {
        const Self = @This();
        collector: *system.Collector,
        root: *Session,
        service: ?*authority.c.struct_xsvc = null,
        stdio_alive: bool = true,
        cpu: ?*Session = null,
        next_flow_ns: u64 = 0,
        flow_generation: u64 = 0,
        flow_requested: bool = false,
        stopping: bool = false,

        pub fn deinit(self: *Self, now: u64) void {
            if (self.collector.capture.current) |r| if (r.active()) self.collector.capture.finish(.revoked, "owner_shutdown", now);
            if (self.flow_requested) if (self.collector.fd_collector) |ctx| {
                _ = c.xrt_fdactivity_request(ctx, &.{ .interval_ms = 1000, .stop_flow = 1 });
            };
            self.dropCpu();
            // Collector destruction closes its worker even if stop publication was busy.
            self.collector.capture.backend_busy = false;
        }
        fn dropCpu(self: *Self) void {
            if (self.cpu) |session| {
                session.deinit(); // target destruction detaches an attached process.
                a.destroy(session);
                self.cpu = null;
            }
        }
        fn present(self: *Self, caller: state.Caller, now: u64) bool {
            if (caller != .agent) return false;
            if (caller.agent.client == 0) return self.stdio_alive;
            const service = self.service orelse return false;
            return authority.c.xsvc_authorize(service, caller.agent.client, authority.c.XSVC_OBSERVE, now) == authority.c.XSVC_OK;
        }
        pub fn tick(self: *Self, now: u64) void {
            const s = &self.collector.capture;
            const before = s.current orelse return;
            s.check(self.root.agent_scope, self.present(before.caller, now), now);
            if (s.current.?.phase == .approved) {
                self.start(now) catch |err| {
                    s.finish(.failed, @errorName(err), now);
                    log.warn(.overview, "xodb: requested capture failed: {s}\n", .{@errorName(err)});
                };
            }
            if (s.current.?.phase == .running) {
                if (s.current.?.spec.kind == .cpu) {
                    const session = self.cpu orelse return;
                    session.poll() catch |err| s.finish(.failed, @errorName(err), now);
                    if (session.profile) |profile| if (profile.collector == null and s.current.?.phase == .running)
                        s.finish(.complete, @tagName(profile.status), now);
                } else self.pollFlow(now);
            }
            // No client poll or GUI pane is needed for stopping and detaching.
            if (!s.current.?.active() and s.backend_busy) self.stop(now);
        }
        fn start(self: *Self, now: u64) !void {
            const s = &self.collector.capture;
            const r = s.current.?;
            if (r.spec.kind == .fd_flow) {
                const ctx = try self.collector.descriptors();
                var publication: c.struct_xrt_fdactivity_view = undefined;
                if (c.xrt_fdactivity_acquire(ctx, &publication) == 0) return; // retry on owner tick
                const busy = publication.flow.requested != 0 or publication.flow.stream.running != 0 or publication.event_requested != 0 or publication.event.running != 0;
                self.flow_generation = publication.flow.generation;
                c.xrt_fdactivity_release(ctx);
                if (busy) return error.ExistingCaptureActive;
                const request = c.struct_xrt_fdactivity_request{ .interval_ms = r.spec.interval_ms, .poll_all = 1, .flow = 1 };
                const result = c.xrt_fdactivity_request(ctx, &request);
                if (result == c.XRT_STALE_SNAPSHOT) return;
                if (result != c.XRT_OK) return error.FdCollectorUnavailable;
                self.dropCpu();
                c.xrt_fdflow_live_free(self.collector.capture_flow);
                self.collector.capture_flow = null;
                self.flow_requested = true;
                self.stopping = false;
                self.next_flow_ns = now + @as(u64, r.spec.interval_ms) * std.time.ns_per_ms;
            } else {
                const id: identity.Identity = .{ .pid = r.spec.pid, .start = r.spec.start_ticks };
                try identity.validate(id);
                const session = try a.create(Session);
                errdefer a.destroy(session);
                session.* = Session.init();
                errdefer session.deinit();
                // A private, capture-only grant. No protocol/debug commands see this Session.
                session.agent_scope = .control;
                try session.target.attach(id.pid);
                try identity.validate(id);
                _ = try session.startProfile(.{ .frequency_hz = r.spec.frequency_hz, .duration_ms = r.spec.duration_ms, .sample_limit = 16384, .ring_budget_bytes = 64 * 1024 * 1024 });
                const caller: authority.Caller = .{ .actor = .agent, .client = r.caller.agent.client };
                try session.continueAs(caller);
                session.recordAs(caller, "requested_cpu_capture");
                self.dropCpu();
                self.cpu = session;
                c.xrt_fdflow_live_free(self.collector.capture_flow);
                self.collector.capture_flow = null;
            }
            s.result_id = r.id;
            s.result_kind = r.spec.kind;
            s.result_caller = r.caller;
            s.started(now);
        }
        fn pollFlow(self: *Self, now: u64) void {
            const s = &self.collector.capture;
            const ctx = self.collector.fd_collector orelse return;
            var publication: c.struct_xrt_fdactivity_view = undefined;
            if (c.xrt_fdactivity_acquire(ctx, &publication) != 0) {
                const failed = publication.flow.generation != self.flow_generation and publication.flow.status != c.XRT_OK and publication.flow.status != c.XRT_STALE_SNAPSHOT;
                c.xrt_fdactivity_release(ctx);
                if (failed) {
                    s.finish(.failed, "FdFlowOpenFailed", now);
                    return;
                }
            }
            if (now < self.next_flow_ns) return;
            const interval = s.current.?.spec.interval_ms;
            const request = c.struct_xrt_fdactivity_request{ .interval_ms = interval, .poll_all = 1, .flow = 1 };
            if (c.xrt_fdactivity_request(ctx, &request) == c.XRT_OK) self.next_flow_ns = now + @as(u64, interval) * std.time.ns_per_ms;
        }
        fn stop(self: *Self, now: u64) void {
            const s = &self.collector.capture;
            if (self.flow_requested) {
                const ctx = self.collector.fd_collector orelse return;
                if (!self.stopping) {
                    if (c.xrt_fdactivity_request(ctx, &.{ .interval_ms = 1000, .stop_flow = 1 }) != c.XRT_OK) return;
                    self.stopping = true;
                }
                var publication: c.struct_xrt_fdactivity_view = undefined;
                if (c.xrt_fdactivity_acquire(ctx, &publication) == 0) return;
                defer c.xrt_fdactivity_release(ctx);
                if (publication.flow.requested != 0 or publication.flow.stream.running != 0) return;
                self.collector.capture_flow = c.xrt_fdflow_live_copy(&publication.flow);
                if (self.collector.capture_flow == null) s.finish(.failed, "CaptureResultOutOfMemory", now);
                if (s.current.?.phase == .complete) {
                    if (publication.flow.status != c.XRT_OK) s.finish(.failed, "FdFlowOpenFailed", now) else if (publication.flow.stream.active_cpus == 0) s.finish(.failed, "CaptureNeverStarted", now);
                }
                self.flow_requested = false;
            } else if (self.cpu) |session| {
                if (session.profile) |profile| if (profile.collector != null) session.stopProfile() catch {};
                session.detach() catch |err| {
                    s.finish(.failed, @errorName(err), now);
                    return; // retain ownership and retry cleanup on subsequent ticks
                };
            }
            s.backend_busy = false;
        }
    };
}
