//! Immutable agent work-log projection, independent of any debug target.
const std = @import("std");
const flame = @import("flame.zig");
const redact = @import("../redact.zig");
const chronology = @import("agent_time_chart.zig");
const delta = @import("agent_time_delta.zig");
const a = std.heap.page_allocator;
pub const Value = std.json.Value;
pub fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn text(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: Value) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => 0,
    };
}
pub fn array(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}
pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    pub const Summary = struct {
        title: []const u8,
        project: []const u8,
        date: []const u8,
        started: []const u8,
        ended: []const u8 = "",
        activity_date: []const u8 = "",
        start: f64,
        end: f64,
        duration: f64,
        tokens: ?u64,
        turn_count: usize,
        cached: bool,
        cache_state: []const u8,
    };
    pub const Entry = struct {
        agent: []const u8,
        path: []const u8,
        title: []const u8 = "session",
        project: []const u8 = "",
        date: []const u8 = "",
        started: []const u8 = "",
        ended: []const u8 = "",
        activity_date: []const u8 = "",
        modified: f64 = 0,
        bytes: u64 = 0,
        start: ?f64 = null,
        end: ?f64 = null,
        duration: ?f64 = null,
        tokens: ?u64 = null,
        turn_count: ?usize = null,
        indexed: bool = false,
        cached: bool = false,
        cache_state: []const u8 = "queued",
        failure: ?[]const u8 = null,
    };
    pub fn decode(bytes: []const u8) !*Catalog {
        const self = try a.create(Catalog);
        errdefer a.destroy(self);
        self.arena = .init(a);
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        const wire = try std.json.parseFromSliceLeaky(struct { sessions: []Entry }, aa, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        self.entries = wire.sessions;
        if (redact.active()) |policy| for (self.entries) |*entry| {
            entry.title = try policy.scrubAlloc(aa, entry.title);
            entry.project = try policy.scrubAlloc(aa, entry.project);
        };
        return self;
    }
    pub fn update(self: *Catalog, index: usize, summary: Summary) !void {
        const entry = &self.entries[index];
        const aa = self.arena.allocator();
        entry.title = if (redact.active()) |policy| try policy.scrubAlloc(aa, summary.title) else try aa.dupe(u8, summary.title);
        entry.project = if (redact.active()) |policy| try policy.scrubAlloc(aa, summary.project) else try aa.dupe(u8, summary.project);
        entry.date = try aa.dupe(u8, summary.date);
        entry.started = try aa.dupe(u8, summary.started);
        entry.ended = try aa.dupe(u8, summary.ended);
        entry.activity_date = try aa.dupe(u8, summary.activity_date);
        entry.start = summary.start;
        entry.end = summary.end;
        entry.duration = summary.duration;
        entry.turn_count = summary.turn_count;
        entry.tokens = summary.tokens;
        entry.cached = summary.cached;
        entry.cache_state = try aa.dupe(u8, summary.cache_state);
        entry.indexed = true;
    }
    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const Profile = struct {
    arena: std.heap.ArenaAllocator,
    live_document: ?*delta.Session = null,
    doc: Value,
    wall: flame.Graph,
    tokens: flame.Graph,
    task_wall: flame.Graph,
    task_tokens: flame.Graph,
    cache: []CacheShare,
    task_cache: []CacheShare,
    source_fingerprint: []const u8,
    chart: chronology.Chart,

    pub const CacheShare = struct {
        read: u64 = 0,
        input: u64 = 0,
        pub fn ratio(self: CacheShare) f32 {
            return if (self.input == 0) 0 else @as(f32, @floatFromInt(self.read)) / @as(f32, @floatFromInt(self.input));
        }
    };
    fn cacheShares(aa: std.mem.Allocator, graph: *const flame.Graph) ![]CacheShare {
        const shares = try aa.alloc(CacheShare, graph.nodes.items.len);
        @memset(shares, .{});
        for (graph.nodes.items) |node| {
            const name = node.frame.name;
            if (std.mem.eql(u8, name, "cached input")) shares[node.id].read = node.self;
            if (std.mem.eql(u8, name, "cached input") or std.mem.eql(u8, name, "fresh input") or std.mem.eql(u8, name, "cache write")) shares[node.id].input = node.self;
        }
        var i = shares.len;
        while (i > 0) {
            i -= 1;
            if (graph.nodes.items[i].parent) |parent| {
                shares[parent].read += shares[i].read;
                shares[parent].input += shares[i].input;
            }
        }
        return shares;
    }

    pub fn decode(bytes: []const u8) !*Profile {
        const self = try a.create(Profile);
        errdefer a.destroy(self);
        self.arena = .init(a);
        self.live_document = null;
        errdefer self.arena.deinit();
        const aa = self.arena.allocator();
        self.doc = try std.json.parseFromSliceLeaky(Value, aa, bytes, .{ .allocate = .alloc_always });
        if (field(self.doc, "agent") != .string) return error.InvalidAgentTimeDocument;
        self.source_fingerprint = text(field(self.doc, "source_fingerprint"));
        _ = self.doc.object.swapRemove("source_fingerprint");
        if (redact.active()) |policy| try policy.scrubValue(aa, &self.doc);
        try self.build();
        return self;
    }
    /// Takes the caller's immutable document reference, including on failure.
    pub fn fromLive(document: *delta.Session) !*Profile {
        errdefer document.release();
        const self = try a.create(Profile);
        errdefer a.destroy(self);
        self.arena = .init(a);
        errdefer self.arena.deinit();
        self.live_document = document;
        self.doc = document.doc;
        self.source_fingerprint = "";
        try self.build();
        return self;
    }
    fn build(self: *Profile) !void {
        const aa = self.arena.allocator();
        self.wall = try flame.Graph.init(aa);
        self.tokens = try flame.Graph.init(aa);
        self.task_wall = try flame.Graph.init(aa);
        self.task_tokens = try flame.Graph.init(aa);
        self.wall.nodes.items[0].frame.name = "Agent work + waits (microseconds)";
        self.tokens.nodes.items[0].frame.name = "Logged token burn";
        self.task_wall.nodes.items[0].frame.name = "Inferred task packets / work (microseconds)";
        self.task_tokens.nodes.items[0].frame.name = "Inferred task packets / tokens";
        try self.project(self.doc, &.{}, 0);
        try self.wall.layout();
        try self.tokens.layout();
        try self.task_wall.layout();
        try self.task_tokens.layout();
        self.cache = try cacheShares(aa, &self.tokens);
        self.task_cache = try cacheShares(aa, &self.task_tokens);
        self.chart = try chronology.Chart.build(aa, self.doc);
    }
    pub fn deinit(self: *Profile) void {
        self.arena.deinit();
        if (self.live_document) |document| document.release();
        a.destroy(self);
    }
    pub fn save(self: *const Profile, io: std.Io, destination: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, self.doc, .{});
        defer a.free(bytes);
        // Never replace an existing archive. The document has already crossed
        // the common redaction boundary, and includes no transcript bodies.
        const file = try std.Io.Dir.cwd().createFile(io, destination, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
    fn frame(name: []const u8) flame.Frame {
        return .{ .kind = .code, .name = name, .address = std.hash.Wyhash.hash(0, name) };
    }
    fn path(self: *Profile, doc: Value, turn: f64, prefix: []const flame.Frame) ![]flame.Frame {
        const aa = self.arena.allocator();
        const out = try aa.alloc(flame.Frame, prefix.len + 3);
        @memcpy(out[0..prefix.len], prefix);
        out[prefix.len] = frame(text(field(doc, "agent")));
        out[prefix.len + 1] = frame(text(field(doc, "title")));
        const turns = array(field(doc, "turns"));
        const label = if (turn >= 0 and turn < @as(f64, @floatFromInt(turns.len))) text(field(turns[@intFromFloat(turn)], "title")) else "between turns";
        out[prefix.len + 2] = frame(try std.fmt.allocPrint(aa, "turn {d:.0}: {s}", .{ turn + 1, label }));
        return out;
    }
    fn project(self: *Profile, doc: Value, prefix: []const flame.Frame, depth: usize) !void {
        if (depth > 8) return error.AgentNestingLimit;
        const aa = self.arena.allocator();
        if (std.mem.eql(u8, text(field(doc, "agent")), "fleet")) {
            for (array(field(doc, "children"))) |child| try self.project(child, prefix, depth);
            return;
        }
        for (array(field(doc, "spans"))) |span| {
            const duration = number(field(span, "end")) - number(field(span, "start"));
            if (!std.math.isFinite(duration) or duration <= 0 or duration > 1e10) continue;
            const base = try self.path(doc, number(field(span, "turn")), prefix);
            const frames = try aa.alloc(flame.Frame, base.len + 3);
            @memcpy(frames[0..base.len], base);
            frames[base.len] = frame(text(field(span, "activity")));
            var count = base.len + 1;
            for ([_][]const u8{ "class", "detail" }) |key| {
                const name = text(field(span, key));
                if (name.len == 0) continue;
                frames[count] = frame(name);
                if (std.mem.eql(u8, key, "detail")) frames[count].mapping_note = text(field(span, "full"));
                count += 1;
            }
            try self.wall.addWeighted(frames[0..count], @max(1, @as(u64, @intFromFloat(duration * 1e6))));
            if (!std.mem.startsWith(u8, text(field(span, "activity")), "waiting for ")) {
                const task = try self.taskPath(doc, number(field(span, "turn")), frames[base.len..count]);
                try self.task_wall.addWeighted(task, @max(1, @as(u64, @intFromFloat(duration * 1e6))));
            }
        }
        for (array(field(doc, "tokens"))) |call| {
            const base = try self.path(doc, number(field(call, "turn")), prefix);
            const frames = try aa.alloc(flame.Frame, base.len + 2);
            @memcpy(frames[0..base.len], base);
            frames[base.len] = frame(text(field(call, "detail")));
            const weights = field(call, "weights");
            if (weights != .object) continue;
            var it = weights.object.iterator();
            while (it.next()) |entry| {
                const count = number(entry.value_ptr.*);
                if (!std.math.isFinite(count) or count <= 0 or count > 1e15) continue;
                frames[base.len + 1] = frame(entry.key_ptr.*);
                try self.tokens.addWeighted(frames, @intFromFloat(count));
                try self.task_tokens.addWeighted(try self.taskPath(doc, number(field(call, "turn")), frames[base.len..]), @intFromFloat(count));
            }
        }
        for (array(field(doc, "children"))) |child| {
            const id = text(field(child, "parent_call_id"));
            var parent: ?Value = null;
            for (array(field(doc, "spans"))) |span| if (id.len > 0 and std.mem.eql(u8, id, text(field(span, "call_id")))) {
                parent = span;
                break;
            };
            const base = try self.path(doc, if (parent) |p| number(field(p, "turn")) else -1, prefix);
            const frames = try aa.alloc(flame.Frame, base.len + 2);
            @memcpy(frames[0..base.len], base);
            frames[base.len] = frame(if (parent) |p| text(field(p, "activity")) else if (field(child, "spawn_time") != .null and id.len > 0) "recorded spawn (not in view)" else "unlinked subagent");
            frames[base.len + 1] = frame(try std.fmt.allocPrint(aa, "subagent:{s}", .{text(field(child, "subagent_name"))}));
            try self.project(child, frames, depth + 1);
        }
    }
    fn taskPath(self: *Profile, doc: Value, turn: f64, suffix: []const flame.Frame) ![]flame.Frame {
        const turns = array(field(doc, "turns"));
        const tag = if (turn >= 0 and turn < @as(f64, @floatFromInt(turns.len))) text(field(turns[@intFromFloat(turn)], "task")) else "";
        const frames = try self.arena.allocator().alloc(flame.Frame, suffix.len + 2);
        frames[0] = frame(if (tag.len > 0) tag else "unlabelled");
        frames[1] = frame(text(field(doc, "agent")));
        @memcpy(frames[2..], suffix);
        return frames;
    }
};

/// Each bounded helper has an owner; no debug session/SIGCHLD owner exists here.
/// UI owns this helper, and cancels its sole request job before stopping it.
/// Decoder state never leaves the helper's memory or survives live mode.
pub const LiveReader = struct {
    // spawn-allow: private live helper owned and reaped by stop(), after the request job is cancelled.
    child: ?std.process.Child = null,
    documents: delta.State = .{ .allocator = std.heap.c_allocator },
    pub fn stop(self: *LiveReader, io: std.Io) void {
        if (self.child) |*child| child.kill(io);
        self.child = null;
        self.documents.deinit();
    }
    fn read(self: *LiveReader, io: std.Io, agent: []const u8, path: []const u8) ![]u8 {
        errdefer self.stop(io);
        if (self.child == null) {
            @import("../child_env.zig").settle();
            const argv = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--agent", agent, "--file", path, "--live", "--redact" };
            // spawn-allow: standalone log viewer; UI cancels the request then kills/reaps its private helper.
            self.child = try std.process.spawn(io, .{
                .argv = argv[0 .. argv.len - @intFromBool(redact.active() == null)],
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .ignore,
            });
        }
        try self.child.?.stdin.?.writeStreamingAll(io, "refresh\n");
        var storage: std.Io.File.MultiReader.Buffer(1) = undefined;
        var reader: std.Io.File.MultiReader = undefined;
        reader.init(a, io, storage.toStreams(), &.{self.child.?.stdout.?});
        defer reader.deinit();
        const timeout = (std.Io.Timeout{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } }).toDeadline(io);
        while (true) {
            const bytes = reader.reader(0).buffered();
            if (bytes.len >= 4) {
                const len = std.mem.readInt(u32, bytes[0..4], .big);
                if (len > 64 * 1024 * 1024) return error.AgentLogSnapshotLimit;
                if (bytes.len >= 4 + @as(usize, len)) return a.dupe(u8, bytes[4 .. 4 + @as(usize, len)]);
            }
            try reader.fill(4096, timeout);
        }
    }
};

pub const Job = struct {
    agent: []const u8,
    path: []const u8,
    done: std.atomic.Value(bool) = .init(false),
    io: std.Io,
    future: ?std.Io.Future(void) = null,
    profile: ?*Profile = null,
    catalog: ?*Catalog = null,
    summary: ?std.json.Parsed(Catalog.Summary) = null,
    indexing: bool = false,
    fingerprint: []const u8 = "",
    unchanged: bool = false,
    failure: ?anyerror = null,
    tail: ?*LiveReader = null,
    pub fn start(io: std.Io, agent: []const u8, path: []const u8) !*Job {
        return startMode(io, agent, path, false, "", null);
    }
    pub fn startIndex(io: std.Io, agent: []const u8, path: []const u8) !*Job {
        return startMode(io, agent, path, true, "", null);
    }
    pub fn startRefresh(io: std.Io, agent: []const u8, path: []const u8, fingerprint: []const u8) !*Job {
        return startMode(io, agent, path, false, fingerprint, null);
    }
    pub fn startTail(io: std.Io, agent: []const u8, path: []const u8, tail: *LiveReader) !*Job {
        return startMode(io, agent, path, false, "", tail);
    }
    fn startMode(io: std.Io, agent: []const u8, path: []const u8, indexing: bool, fingerprint: []const u8, tail: ?*LiveReader) !*Job {
        const self = try a.create(Job);
        errdefer a.destroy(self);
        const owned_agent = try a.dupe(u8, agent);
        errdefer a.free(owned_agent);
        self.* = .{ .io = io, .agent = owned_agent, .path = try a.dupe(u8, path), .indexing = indexing, .tail = tail };
        errdefer a.free(self.path);
        self.fingerprint = try a.dupe(u8, fingerprint);
        errdefer a.free(self.fingerprint);
        self.future = try io.concurrent(run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn execute(self: *Job) !void {
        if (self.tail) |tail| {
            errdefer tail.stop(self.io);
            const document = snapshot: {
                const bytes = try tail.read(self.io, self.agent, self.path);
                defer a.free(bytes);
                if (bytes.len < 256) {
                    const status = try std.json.parseFromSlice(struct { unchanged: bool = false, failure: ?[]const u8 = null }, a, bytes, .{ .ignore_unknown_fields = true });
                    defer status.deinit();
                    if (status.value.failure != null) return error.AgentLogReadFailed;
                    if (status.value.unchanged) {
                        self.unchanged = true;
                        return;
                    }
                }
                var frame = try std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always });
                defer frame.deinit();
                if (redact.active()) |policy| try policy.scrubValue(frame.arena.allocator(), &frame.value);
                // The immutable snapshot owns its data. Drop wire/parser storage
                // before building graphs, including on the first full reset.
                break :snapshot try tail.documents.apply(frame.value);
            };
            self.profile = try Profile.fromLive(document);
            return;
        }
        if (std.mem.eql(u8, self.agent, "archive")) {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, self.path, a, .limited(64 * 1024 * 1024));
            defer a.free(bytes);
            self.profile = try Profile.decode(bytes);
            return;
        }
        @import("../child_env.zig").settle();
        const listing = std.mem.eql(u8, self.agent, "catalog");
        // -I: no cwd/user-site modules or PYTHON* variables; --redact only when the policy is on.
        const argv = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--agent", self.agent, "--file", self.path, "--redact" };
        const list = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--list", "--redact" };
        const index = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--agent", self.agent, "--file", self.path, "--index", "--redact" };
        const fleet = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--fleet", self.path, "--redact" };
        const refresh = [_][]const u8{ "python3", "-I", "-B", "-c", @embedFile("agent_time.py"), "--agent", self.agent, "--file", self.path, "--if-fingerprint", self.fingerprint, "--redact" };
        const off = @intFromBool(redact.active() == null);
        // spawn-allow: standalone log viewer has no target/wait owner; run owns and reaps this bounded helper.
        const result = try std.process.run(a, self.io, .{
            .argv = if (listing) list[0 .. list.len - off] else if (self.indexing) index[0 .. index.len - off] else if (std.mem.eql(u8, self.agent, "fleet")) fleet[0 .. fleet.len - off] else if (self.fingerprint.len > 0) refresh[0 .. refresh.len - off] else argv[0 .. argv.len - off],
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(16384),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
        });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.AgentLogReadFailed;
        if (self.fingerprint.len > 0 and result.stdout.len < 256) {
            const status = try std.json.parseFromSlice(struct { unchanged: bool = false }, a, result.stdout, .{ .ignore_unknown_fields = true });
            defer status.deinit();
            if (status.value.unchanged) {
                self.unchanged = true;
                return;
            }
        }
        if (listing) self.catalog = try Catalog.decode(result.stdout) else if (self.indexing) self.summary = try std.json.parseFromSlice(Catalog.Summary, a, result.stdout, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) else self.profile = try Profile.decode(result.stdout);
    }
    pub fn deinit(self: *Job) void {
        if (self.future) |*future| future.cancel(self.io);
        if (self.profile) |profile| profile.deinit();
        if (self.catalog) |catalog| catalog.deinit();
        if (self.summary) |summary| summary.deinit();
        a.free(self.agent);
        a.free(self.path);
        a.free(self.fingerprint);
        a.destroy(self);
    }
};

test "agent time uses the weighted graph and preserves both independent units" {
    const p = try Profile.decode(
        \\{"agent":"synthetic","title":"task","turns":[{"title":"inspect"}],"spans":[{"start":1,"end":3,"turn":0,"activity":"tool:read","detail":"read a"}],"tokens":[{"turn":0,"detail":"read a","weights":{"fresh input":12,"output":3}}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u64, 2_000_000), p.wall.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 15), p.tokens.nodes.items[0].inclusive);
}

test "catalog accepts numeric index summaries without constructing a flame profile" {
    const catalog = try Catalog.decode(
        \\{"sessions":[{"agent":"synthetic","path":"fixture.jsonl"}]}
    );
    defer catalog.deinit();
    try catalog.update(0, .{ .title = "task", .project = "fixture", .date = "2026-01-01", .started = "2026-01-01T00:00:00Z", .start = 1, .end = 4, .duration = 3, .tokens = 130, .turn_count = 2, .cached = true, .cache_state = "cached" });
    try std.testing.expectEqual(@as(?u64, 130), catalog.entries[0].tokens);
    try std.testing.expectEqual(@as(?usize, 2), catalog.entries[0].turn_count);
    try std.testing.expect(catalog.entries[0].indexed and catalog.entries[0].cached);
    try std.testing.expectEqualStrings("task", catalog.entries[0].title);
}

test "fleet roots are independent and task work excludes waits while cache share excludes output" {
    const p = try Profile.decode(
        \\{"agent":"fleet","start":1,"end":10,"source_fingerprint":"private-stat-key","children":[{"agent":"codex","title":"first","start":1,"end":8,"turns":[{"task":"A33-M1"}],"spans":[{"start":1,"end":3,"turn":0,"activity":"tool:read"},{"start":3,"end":8,"turn":-1,"activity":"waiting for user"}],"tokens":[{"time":2,"turn":0,"weights":{"fresh input":10,"cached input":30,"cache write":10,"output":50}}]},{"agent":"claude","title":"second","start":2,"end":4,"turns":[{"task":"A33-M1"}],"spans":[{"start":2,"end":4,"turn":0,"activity":"model (inferred)"}],"tokens":[]}]}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u64, 9_000_000), p.wall.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 4_000_000), p.task_wall.nodes.items[0].inclusive);
    var tagged: u64 = 0;
    var task_nodes: usize = 0;
    for (p.task_wall.nodes.items) |node| if (std.mem.eql(u8, node.frame.name, "A33-M1")) {
        tagged += node.inclusive;
        task_nodes += 1;
    };
    try std.testing.expectEqual(@as(u64, 4_000_000), tagged);
    try std.testing.expectEqual(@as(usize, 1), task_nodes);
    try std.testing.expectEqual(@as(u64, 100), p.task_tokens.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 30), p.cache[0].read);
    try std.testing.expectEqual(@as(u64, 50), p.cache[0].input);
    try std.testing.expectEqual(p.cache[0], p.task_cache[0]);
    try std.testing.expectEqualStrings("private-stat-key", p.source_fingerprint);
    try std.testing.expect(field(p.doc, "source_fingerprint") == .null);
    var first: ?u32 = null;
    var second: ?u32 = null;
    for (p.wall.nodes.items) |node| try std.testing.expect(!std.mem.eql(u8, node.frame.name, "unlinked subagent"));
    for (p.chart.wall.items) |span| {
        if (std.mem.eql(u8, span.label, "codex")) first = span.depth;
        if (std.mem.eql(u8, span.label, "claude")) second = span.depth;
        try std.testing.expect(std.mem.indexOf(u8, span.label, "unlinked subagent") == null);
    }
    try std.testing.expect(first != null and second != null and first.? != second.?);
    for (p.chart.tokens.items) |span| {
        try std.testing.expectEqual(@as(f64, 30), span.cache_read);
        try std.testing.expectEqual(@as(f64, 50), span.cache_input);
    }
}

test "a child whose recorded spawn was clipped is not invented as unlinked" {
    const p = try Profile.decode(
        \\{"agent":"claude","title":"parent","start":10,"end":20,"children":[{"agent":"claude","title":"child","start":11,"end":12,"parent_call_id":"spawn","spawn_time":5,"spans":[{"start":11,"end":12,"activity":"model (inferred)"}]}]}
    );
    defer p.deinit();
    var found = false;
    for (p.wall.nodes.items) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.frame.name, "unlinked subagent"));
        if (std.mem.eql(u8, node.frame.name, "recorded spawn (not in view)")) found = true;
    }
    try std.testing.expect(found);
    found = false;
    for (p.chart.wall.items) |span| if (std.mem.startsWith(u8, span.label, "recorded spawn (not in view)")) {
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(u64, 1_000_000), p.wall.nodes.items[0].inclusive);
}

test "live splices project exactly like a fresh snapshot after parser storage is released" {
    const ta = std.testing.allocator;
    var state = delta.State{ .allocator = ta };
    defer state.deinit();
    const old = blk: {
        const wire = try std.json.parseFromSlice(Value, ta,
            \\{"wire":1,"generation":1,"size":512,"reset":{"agent":"claude","title":"parent","start":1,"end":3,"turns":[{"title":"task","task":"A33-M1"}],"spans":[{"start":1,"end":3,"turn":0,"activity":"model (inferred)"}],"tokens":[],"children":[]}}
        , .{});
        defer wire.deinit();
        break :blk try Profile.fromLive(try state.apply(wire.value));
    };
    defer old.deinit();
    const live = blk: {
        const wire = try std.json.parseFromSlice(Value, ta,
            \\{"wire":1,"generation":2,"base":1,"size":800,"patch":{"meta":{"agent":"claude","title":"parent","start":1,"end":6},"spans":{"length":1,"ops":[[1,1,[{"start":3,"end":6,"turn":0,"activity":"tool:exec","detail":"git status","full":"git status --short"}]]]},"tokens":{"length":0,"ops":[[0,0,[{"time":4,"turn":0,"detail":"model","weights":{"fresh input":10,"cached input":20,"output":5}}]]]}}}
        , .{});
        defer wire.deinit();
        break :blk try state.apply(wire.value);
    };
    const p = try Profile.fromLive(live);
    defer p.deinit();
    const fresh = try Profile.decode(
        \\{"agent":"claude","title":"parent","start":1,"end":6,"turns":[{"title":"task","task":"A33-M1"}],"spans":[{"start":1,"end":3,"turn":0,"activity":"model (inferred)"},{"start":3,"end":6,"turn":0,"activity":"tool:exec","detail":"git status","full":"git status --short"}],"tokens":[{"time":4,"turn":0,"detail":"model","weights":{"fresh input":10,"cached input":20,"output":5}}],"children":[]}
    );
    defer fresh.deinit();
    inline for (.{ "wall", "tokens", "task_wall", "task_tokens" }) |name| {
        const actual = try std.json.Stringify.valueAlloc(ta, @field(p, name).nodes.items, .{});
        defer ta.free(actual);
        const expected = try std.json.Stringify.valueAlloc(ta, @field(fresh, name).nodes.items, .{});
        defer ta.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
    inline for (.{ "wall", "tokens" }) |name| {
        const actual = try std.json.Stringify.valueAlloc(ta, @field(p.chart, name).items, .{});
        defer ta.free(actual);
        const expected = try std.json.Stringify.valueAlloc(ta, @field(fresh.chart, name).items, .{});
        defer ta.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
    try std.testing.expectEqualSlices(Profile.CacheShare, fresh.cache, p.cache);
    try std.testing.expectEqualSlices(Profile.CacheShare, fresh.task_cache, p.task_cache);
    try std.testing.expectEqual(@as(u64, 2_000_000), old.wall.nodes.items[0].inclusive);
    try std.testing.expectEqual(@as(u64, 5_000_000), p.wall.nodes.items[0].inclusive);
}
