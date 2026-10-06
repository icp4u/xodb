//! Static analysis inside the debugger. The function under the cursor is
//! resolved from the session's own symbols and image snapshot, exported by the
//! supervised native Ghidra worker (tools/ghx, a separate process tree, never
//! the target or its agent), converted to xsg and answered by src/semq.
//!
//! Answers are static possibilities, not an observed execution. They carry the
//! producer's qualification unchanged; nothing here upgrades it. The worker is
//! opt-in (--static-analysis DIR); without it every request is a typed
//! "unavailable" result that says how to build it.
const std = @import("std");
const libc = @import("../c.zig").api;
const Session = @import("../model/session.zig").Session;
const adapter = @import("adapter.zig");
pub const c = @cImport({
    @cInclude("xsq.h");
    @cInclude("xsq_report.h");
    @cInclude("ghx_host.h");
});
const Allocator = std.mem.Allocator;
const page = std.heap.page_allocator;

pub const banner = "static possibilities, not an observed execution";
pub const how_to_build = "static analysis is opt-in: build the native Ghidra worker with `sh tools/ghx/build_ghidra.sh GHIDRA_CHECKOUT DIR && make -C tools/ghx GHIDRA_CPP=DIR/ghidra-src/Ghidra/Features/Decompiler/src/decompile/cpp OUT=DIR`, then start xodb with `--static-analysis DIR` (or XODB_STATIC_ANALYSIS=DIR)";
pub const default_deadline_ms: u32 = 60_000;
pub const max_deadline_ms: u32 = 600_000;
const max_function_bytes: u64 = 1 << 20;
const max_export_bytes: usize = 64 << 20;
const max_analyses = 16;

pub const Unavailable = struct { reason: []const u8, detail: []const u8 };
pub const Toolchain = struct { dir: []const u8, supervisor: [:0]const u8, worker: [:0]const u8, sleigh: [:0]const u8 };

fn executable(path: [:0]const u8) bool {
    var st: libc.struct_stat = undefined;
    return libc.stat(path.ptr, &st) == 0 and st.st_mode & libc.S_IFMT == libc.S_IFREG and libc.access(path.ptr, libc.X_OK) == 0;
}
fn present(path: [:0]const u8) bool {
    var st: libc.struct_stat = undefined;
    return libc.stat(path.ptr, &st) == 0;
}

/// The worker directory layout is what build_ghidra.sh and the ghx Makefile
/// produce when both are given the same DIR.
pub fn discover(a: Allocator, dir: ?[]const u8) !union(enum) { ready: Toolchain, unavailable: Unavailable } {
    const root = dir orelse return .{ .unavailable = .{ .reason = "not_configured", .detail = "no --static-analysis directory was given" } };
    const t = Toolchain{
        .dir = root,
        .supervisor = try std.fmt.allocPrintSentinel(a, "{s}/ghx_supervise", .{root}, 0),
        .worker = try std.fmt.allocPrintSentinel(a, "{s}/ghx_worker", .{root}, 0),
        .sleigh = try std.fmt.allocPrintSentinel(a, "{s}/ghidra-src", .{root}, 0),
    };
    if (!executable(t.supervisor)) return .{ .unavailable = .{ .reason = "supervisor_missing", .detail = "ghx_supervise is not an executable file in the static analysis directory" } };
    if (!executable(t.worker)) return .{ .unavailable = .{ .reason = "worker_missing", .detail = "ghx_worker is not an executable file in the static analysis directory (Ghidra build absent)" } };
    if (!present(try std.fmt.allocPrintSentinel(a, "{s}/Ghidra/Processors/x86/data/languages/x86-64.sla", .{t.sleigh}, 0)))
        return .{ .unavailable = .{ .reason = "sleigh_missing", .detail = "ghidra-src/Ghidra/Processors/x86/data/languages/x86-64.sla is missing (run build_ghidra.sh)" } };
    return .{ .ready = t };
}

pub const Key = struct {
    image_sha256: [64]u8,
    entry: u64, // link address
    size: u64,
    fn eql(self: Key, other: Key) bool {
        return std.mem.eql(u8, &self.image_sha256, &other.image_sha256) and self.entry == other.entry and self.size == other.size;
    }
};

/// A function as the session's own symbols describe it.
pub const Function = struct {
    key: Key,
    name: []const u8,
    module_id: u64,
    module_path: []const u8,
    bias: u64,
    bounds_source: []const u8,
    build_id: ?[]const u8, // lowercase hex
    pub fn runtime(self: Function, link: u64) u64 {
        return link +% self.bias;
    }
    fn dupe(self: Function, a: Allocator) !Function {
        var out = self;
        out.name = try a.dupe(u8, self.name);
        out.module_path = try a.dupe(u8, self.module_path);
        out.build_id = if (self.build_id) |b| try a.dupe(u8, b) else null;
        return out;
    }
};

pub const Reason = struct { code: []const u8, level: []const u8, detail: []const u8, address: ?u64 };

/// A completed export, converted and loaded once; cached by artifact_id.
pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    function: Function,
    artifact_id: []const u8,
    contract: []const u8,
    schema_version: []const u8,
    level: []const u8,
    reasons: []const Reason,
    graph: c.struct_xsq_graph = std.mem.zeroes(c.struct_xsq_graph),
    func: u32 = 0,
    export_path: []const u8,
    worker_ms: f64,
    fn destroy(self: *Analysis) void {
        c.xsq_free(&self.graph);
        var arena = self.arena;
        arena.deinit();
    }
};

pub const Failure = struct { code: []const u8, detail: []const u8, worker_status: ?[]const u8 = null, worker_pid: ?i64 = null };

pub const Job = struct {
    id: u64,
    arena: std.heap.ArenaAllocator,
    function: Function,
    toolchain: Toolchain,
    image_path: [:0]const u8,
    outdir: [:0]const u8,
    deadline_ms: u32,
    cancel: *c.struct_xsq_cancel,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    started_ms: u64,
    owner: Owner = .human,
    finished_ms: u64 = 0,
    analysis: ?*Analysis = null, // owned until State.poll adopts it
    failure: ?Failure = null,
    pub fn running(self: *Job) bool {
        return !self.done.load(.acquire);
    }
    pub fn requestCancel(self: *Job) void {
        c.xsq_cancel_request(self.cancel);
    }
    pub fn cancelRequested(self: *Job) bool {
        return c.xsq_cancel_requested(self.cancel) != 0;
    }
    pub fn elapsedMs(self: *Job) u64 {
        return (if (self.done.load(.acquire)) self.finished_ms else nowMs()) -| self.started_ms;
    }
    fn destroy(self: *Job) void {
        self.requestCancel();
        if (self.thread) |t| t.join();
        if (self.analysis) |analysis| {
            analysis.destroy();
            page.destroy(analysis);
        }
        c.xghx_cancel_free(self.cancel);
        var arena = self.arena;
        arena.deinit();
    }
    fn fail(self: *Job, code: []const u8, comptime format: []const u8, args: anytype) void {
        self.failure = .{ .code = code, .detail = std.fmt.allocPrint(self.arena.allocator(), format, args) catch code };
    }
    fn run(self: *Job) void {
        self.work() catch |err| if (self.failure == null) self.fail("host_error", "{s}", .{@errorName(err)});
        self.finished_ms = nowMs();
        self.done.store(true, .release);
    }
    fn work(self: *Job) !void {
        const a = self.arena.allocator();
        if (libc.mkdir(self.outdir.ptr, 0o700) != 0) return self.fail("host_error", "cannot create the job directory", .{});
        const line = try std.fmt.allocPrintSentinel(a, "DECOMPILE\tid=f\telf={s}\tentry=0x{x}\tsize=0x{x}\tname={s}", .{ self.image_path, self.function.key.entry, self.function.key.size, safeName(a, self.function.name) }, 0);
        const request = c.struct_xghx_request{ .supervisor = self.toolchain.supervisor.ptr, .worker = self.toolchain.worker.ptr, .sleighhome = self.toolchain.sleigh.ptr, .outdir = self.outdir.ptr, .line = line.ptr, .deadline_ms = self.deadline_ms, .grace_ms = 250, .memory_mb = 4096 };
        var outcome: c.struct_xghx_outcome = undefined;
        const status = c.xghx_run(&request, self.cancel, &outcome);
        const worker_status = std.mem.sliceTo(&outcome.status, 0);
        const detail = std.mem.sliceTo(&outcome.detail, 0);
        const pid: ?i64 = if (outcome.worker_pid > 0) outcome.worker_pid else null;
        switch (status) {
            c.XGHX_RESULT => {},
            c.XGHX_CANCELLED => {
                self.failure = .{ .code = "cancelled", .detail = "cancelled; the supervisor and its worker were stopped and reaped", .worker_pid = pid };
                return;
            },
            c.XGHX_HOST_DEADLINE => {
                self.failure = .{ .code = "worker_timeout", .detail = try std.fmt.allocPrint(a, "the supervisor exceeded the host bound of {d} ms and was stopped", .{self.deadline_ms}), .worker_pid = pid };
                return;
            },
            c.XGHX_SPAWN_FAILED => return self.fail("supervisor_failed", "could not start ghx_supervise (errno {d})", .{outcome.@"error"}),
            else => {
                self.failure = .{ .code = "supervisor_failed", .detail = try std.fmt.allocPrint(a, "ghx_supervise ended without a result (wait status {d})", .{outcome.supervisor_status}), .worker_pid = pid };
                return;
            },
        }
        if (!std.mem.eql(u8, worker_status, "ok")) {
            const code: []const u8 = if (std.mem.eql(u8, worker_status, "timeout")) "worker_timeout" else if (std.mem.eql(u8, worker_status, "worker_died")) "worker_died" else if (std.mem.eql(u8, worker_status, "cancelled")) "cancelled" else if (std.mem.eql(u8, worker_status, "error")) "worker_refused" else "worker_failed";
            var text: []const u8 = try a.dupe(u8, detail);
            // The result file names the cause (entry_unmapped, instruction_refused, a crash, ...).
            if (refusal(a, std.mem.sliceTo(&outcome.file, 0))) |cause| text = cause;
            self.failure = .{ .code = code, .detail = text, .worker_status = try a.dupe(u8, worker_status), .worker_pid = pid };
            return;
        }
        const export_path = try a.dupe(u8, std.mem.sliceTo(&outcome.file, 0));
        const bytes = readFile(a, export_path, max_export_bytes) catch |err| return self.fail("export_unreadable", "{s}", .{@errorName(err)});
        if (self.cancelRequested()) return self.fail("cancelled", "cancelled after the export", .{});
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .max_value_len = max_export_bytes }) catch |err| return self.fail("export_unreadable", "{s}", .{@errorName(err)});
        try self.admit(a, doc);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const converted = switch (try adapter.convert(a, doc, &std.fmt.bytesToHex(digest, .lower))) {
            .refused => |why| return self.fail("adapter_refused", "{s}", .{why}),
            .xsg => |text| text,
        };
        const analysis = try page.create(Analysis);
        analysis.* = .{ .arena = .init(page), .function = undefined, .artifact_id = "", .contract = "", .schema_version = "", .level = "", .reasons = &.{}, .export_path = "", .worker_ms = outcome.ms };
        errdefer {
            analysis.destroy();
            page.destroy(analysis);
        }
        const keep = analysis.arena.allocator();
        var budget = c.struct_xsq_load_budget{ .max_bytes = 256 << 20, .cancel = self.cancel };
        const loaded = c.xsq_load_buffer_budget(converted.ptr, converted.len, &budget, &analysis.graph);
        if (loaded != c.XSQ_OK) {
            const err_text = std.mem.sliceTo(&analysis.graph.@"error", 0);
            if (loaded == c.XSQ_CANCELLED) self.fail("cancelled", "cancelled while loading the graph", .{}) else self.fail("graph_rejected", "{s}: line {d}: {s}", .{ std.mem.span(c.xsq_status_name(loaded)), analysis.graph.error_line, err_text });
            return error.GraphRejected;
        }
        if (analysis.graph.func_count != 1) {
            self.fail("graph_rejected", "expected one function, got {d}", .{analysis.graph.func_count});
            return error.GraphRejected;
        }
        analysis.function = try self.function.dupe(keep);
        analysis.artifact_id = try keep.dupe(u8, str(doc, "artifact_id") orelse "unknown");
        analysis.contract = try keep.dupe(u8, str(doc, "contract") orelse "");
        analysis.schema_version = try keep.dupe(u8, str(doc, "schema_version") orelse "");
        analysis.export_path = try keep.dupe(u8, export_path);
        const q = if (doc.object.get("qualification")) |v| v else std.json.Value.null;
        analysis.level = try keep.dupe(u8, str(q, "level") orelse "unknown");
        var reasons: std.ArrayList(Reason) = .empty;
        if (q == .object) if (q.object.get("reasons")) |list| if (list == .array) for (list.array.items) |r| {
            const address = if (str(r, "addr")) |text| (if (std.mem.startsWith(u8, text, "0x")) std.fmt.parseInt(u64, text[2..], 16) catch null else null) else null;
            try reasons.append(keep, .{ .code = try keep.dupe(u8, str(r, "code") orelse "?"), .level = try keep.dupe(u8, str(r, "level") orelse "?"), .detail = try keep.dupe(u8, str(r, "detail") orelse ""), .address = address });
        };
        analysis.reasons = reasons.items;
        self.analysis = analysis;
    }
    /// The export must describe the bytes the session holds and the function
    /// the session asked for; anything else is refused, never reconciled.
    fn admit(self: *Job, a: Allocator, doc: std.json.Value) !void {
        if (doc != .object) {
            self.fail("export_unreadable", "export is not an object", .{});
            return error.ExportUnreadable;
        }
        const image = doc.object.get("image") orelse std.json.Value.null;
        const sha = str(image, "sha256") orelse "";
        if (!std.mem.eql(u8, sha, &self.function.key.image_sha256)) {
            self.fail("image_identity_mismatch", "export image sha256 {s} is not the session's image {s}", .{ sha, &self.function.key.image_sha256 });
            return error.ImageIdentityMismatch;
        }
        const build_id = str(image, "gnu_build_id");
        if ((build_id == null) != (self.function.build_id == null) or (build_id != null and !std.mem.eql(u8, build_id.?, self.function.build_id.?))) {
            self.fail("image_identity_mismatch", "export build-id {s} is not the session's build-id {s}", .{ build_id orelse "none", self.function.build_id orelse "none" });
            return error.ImageIdentityMismatch;
        }
        const function = doc.object.get("function") orelse std.json.Value.null;
        const entry = try std.fmt.allocPrint(a, "0x{x}", .{self.function.key.entry});
        if (!std.mem.eql(u8, str(function, "entry") orelse "", entry)) {
            self.fail("function_identity_mismatch", "export entry {s} is not the requested entry {s}", .{ str(function, "entry") orelse "none", entry });
            return error.FunctionIdentityMismatch;
        }
    }
};

fn refusal(a: Allocator, path: []const u8) ?[]const u8 {
    const bytes = readFile(a, path, max_export_bytes) catch return null;
    const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
    const e = if (doc == .object) doc.object.get("error") orelse return null else return null;
    return std.fmt.allocPrint(a, "{s}: {s}", .{ str(e, "code") orelse "?", str(e, "message") orelse "" }) catch null;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

/// Request fields are TAB separated; a symbol name is only a label.
fn safeName(a: Allocator, name: []const u8) []const u8 {
    const out = a.dupe(u8, name[0..@min(name.len, 200)]) catch return "f";
    for (out) |*ch| if (ch.* <= 0x20 or ch.* >= 0x7f) {
        ch.* = '_';
    };
    return if (out.len == 0) "f" else out;
}

fn nowMs() u64 {
    var t: libc.struct_timespec = undefined;
    _ = libc.clock_gettime(libc.CLOCK_MONOTONIC, &t);
    return @as(u64, @intCast(t.tv_sec)) * 1000 + @as(u64, @intCast(t.tv_nsec)) / 1_000_000;
}

fn readFile(a: Allocator, path: []const u8, limit: usize) ![]u8 {
    const z = try a.dupeZ(u8, path);
    const fd = libc.open(z.ptr, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
    if (fd < 0) return error.ExportMissing;
    defer _ = libc.close(fd);
    var st: libc.struct_stat = undefined;
    if (libc.fstat(fd, &st) != 0 or st.st_mode & libc.S_IFMT != libc.S_IFREG) return error.ExportNotRegular;
    if (st.st_size < 0 or @as(u64, @intCast(st.st_size)) > limit) return error.ExportTooLarge;
    const bytes = try a.alloc(u8, @intCast(st.st_size));
    var done: usize = 0;
    while (done < bytes.len) {
        const n = libc.read(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.ExportReadFailed;
        done += @intCast(n);
    }
    return bytes;
}

fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = libc.open(path.ptr, libc.O_WRONLY | libc.O_CREAT | libc.O_EXCL | libc.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.ImageSnapshotWriteFailed;
    defer _ = libc.close(fd);
    var done: usize = 0;
    while (done < bytes.len) {
        const n = libc.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.ImageSnapshotWriteFailed;
        done += @intCast(n);
    }
}

const scratch_prefix = "xodb-static-";

/// Removes `$TMPDIR/xodb-static-<pid>-*` directories of this uid whose
/// creating process no longer exists (an xodb that was killed). Symbolic
/// links, other owners and live pids are left alone. Returns the count.
pub fn sweepStale() usize {
    const base_c = libc.getenv("TMPDIR");
    const base: []const u8 = if (base_c != null and base_c[0] != 0) std.mem.span(base_c) else "/tmp";
    var path: [4096]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&path, "{s}", .{base}) catch return 0;
    const dir = libc.opendir(dir_z.ptr) orelse return 0;
    defer _ = libc.closedir(dir);
    var removed: usize = 0;
    while (libc.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.startsWith(u8, name, scratch_prefix)) continue;
        const rest = name[scratch_prefix.len..];
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
        const pid = std.fmt.parseInt(u32, rest[0..dash], 10) catch continue;
        if (pid == 0 or pid == libc.getpid()) continue;
        var proc: [32]u8 = undefined;
        const proc_z = std.fmt.bufPrintZ(&proc, "/proc/{d}", .{pid}) catch continue;
        if (present(proc_z)) continue;
        var full: [4200]u8 = undefined;
        const full_z = std.fmt.bufPrintZ(&full, "{s}/{s}", .{ base, name }) catch continue;
        var st: libc.struct_stat = undefined;
        if (libc.lstat(full_z.ptr, &st) != 0 or st.st_mode & libc.S_IFMT != libc.S_IFDIR or st.st_uid != libc.getuid()) continue;
        if (c.xghx_remove_tree(full_z.ptr) == 0) removed += 1;
    }
    return removed;
}

pub const Status = union(enum) { unavailable: Unavailable, running: *Job, failed: *Job, ready: *Analysis };
/// Who started a job: the GUI's human, or an MCP client (`null` is the one
/// client of a stdio session; shared sessions name the client).
pub const Owner = union(enum) { human, agent: ?u64 };
pub const Options = struct { deadline_ms: u32 = default_deadline_ms, retry: bool = false, owner: Owner = .human };
/// Who asks to cancel. A client may cancel its own jobs; any other job only
/// while it holds control (the controller lease, or a control-scope stdio
/// client). The human may always cancel.
pub const Requester = union(enum) { human, agent: struct { client: ?u64, controller: bool } };
pub fn mayCancel(owner: Owner, requester: Requester) bool {
    return switch (requester) {
        .human => true,
        .agent => |r| r.controller or switch (owner) {
            .human => false,
            .agent => |client| client == r.client,
        },
    };
}

const Hashed = struct { module_id: u64, ptr: usize, len: usize, sha: [64]u8 };

pub const State = struct {
    toolchain_dir: ?[]const u8 = null,
    dir: ?[:0]u8 = null,
    hashed: [8]?Hashed = @splat(null),
    hash_next: usize = 0,
    analyses: std.ArrayList(*Analysis) = .empty,
    job: ?*Job = null,
    next_job: u64 = 1,

    pub fn deinit(self: *State) void {
        if (self.job) |job| {
            job.destroy();
            page.destroy(job);
            self.job = null;
        }
        for (self.analyses.items) |analysis| {
            analysis.destroy();
            page.destroy(analysis);
        }
        self.analyses.deinit(page);
        if (self.dir) |dir| {
            _ = c.xghx_remove_tree(dir.ptr);
            page.free(dir);
            self.dir = null;
        }
    }

    /// Adopts a finished job's analysis into the cache (owner thread).
    pub fn poll(self: *State) void {
        const job = self.job orelse return;
        if (job.running()) return;
        const analysis = job.analysis orelse return;
        job.analysis = null;
        if (self.analyses.items.len >= max_analyses) {
            const old = self.analyses.orderedRemove(0);
            old.destroy();
            page.destroy(old);
        }
        self.analyses.append(page, analysis) catch {
            analysis.destroy();
            page.destroy(analysis);
            job.failure = .{ .code = "host_error", .detail = "OutOfMemory" };
        };
    }

    pub fn find(self: *State, artifact_id: []const u8) ?*Analysis {
        self.poll();
        for (self.analyses.items) |analysis| if (std.mem.eql(u8, analysis.artifact_id, artifact_id)) return analysis;
        return null;
    }

    fn cached(self: *State, key: Key) ?*Analysis {
        for (self.analyses.items) |analysis| if (analysis.function.key.eql(key)) return analysis;
        return null;
    }

    pub fn cancel(self: *State, id: u64, requester: Requester) !*Job {
        const job = self.job orelse return error.NoStaticAnalysisJob;
        if (job.id != id) return error.StaleStaticAnalysisJob;
        if (!mayCancel(job.owner, requester)) return error.StaticAnalysisJobNotOwned;
        if (job.running()) job.requestCancel();
        return job;
    }

    fn privateDir(self: *State) ![:0]const u8 {
        if (self.dir) |dir| return dir;
        const base = std.mem.span(libc.getenv("TMPDIR") orelse @as([*c]const u8, "/tmp"));
        // The creating pid is in the name so a later xodb can sweep the
        // scratch of one that died (sweepStale).
        const template = try std.fmt.allocPrintSentinel(page, "{s}/" ++ scratch_prefix ++ "{d}-XXXXXX", .{ if (base.len > 0) base else "/tmp", libc.getpid() }, 0);
        // Private analysis scratch: mkdtemp creates it 0700.
        if (libc.mkdtemp(template.ptr) == null) {
            page.free(template);
            return error.StaticAnalysisScratchUnavailable;
        }
        self.dir = template;
        return template;
    }

    fn identity(self: *State, module: anytype) [64]u8 {
        const ptr = @intFromPtr(module.mapping.ptr);
        for (self.hashed) |entry| if (entry) |h| if (h.module_id == module.id and h.ptr == ptr and h.len == module.mapping.len) return h.sha;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(module.mapping, &digest, .{});
        const sha = std.fmt.bytesToHex(digest, .lower);
        self.hashed[self.hash_next] = .{ .module_id = module.id, .ptr = ptr, .len = module.mapping.len, .sha = sha };
        self.hash_next = (self.hash_next + 1) % self.hashed.len;
        return sha;
    }

    /// Resolves the function containing `address` from the session's symbols
    /// (ELF symbol, else DWARF subprogram); never discovers functions.
    pub fn resolve(self: *State, a: Allocator, session: *Session, address: u64) !Function {
        try session.refreshMaps();
        const module = try session.modules.at(address);
        const link = try module.linkAddress(address);
        var name: []const u8 = "";
        var entry: u64 = 0;
        var size: u64 = 0;
        var source: []const u8 = "elf_symbol";
        if (module.symbols().symbolAt(link)) |found| if ((found.symbol.type == .func or found.symbol.type == .gnu_ifunc) and found.offset < found.symbol.size) {
            name = found.symbol.name;
            entry = found.symbol.value;
            size = found.symbol.size;
        };
        if (size == 0) {
            const debug = module.debugInfo() catch return error.FunctionBoundsUnavailable;
            const range = debug.functionRangeAt(a, link) catch return error.FunctionBoundsUnavailable;
            name = range.name;
            entry = range.address;
            size = range.end - range.address;
            source = "dwarf_subprogram";
        }
        if (size == 0) return error.FunctionBoundsUnavailable;
        if (size > max_function_bytes) return error.FunctionTooLarge;
        const build_id = if (module.image.buildId()) |id| try hexAlloc(a, id) else null;
        return .{ .key = .{ .image_sha256 = self.identity(module), .entry = entry, .size = size }, .name = name, .module_id = module.id, .module_path = module.path, .bias = module.bias, .bounds_source = source, .build_id = build_id };
    }

    /// The analysis of the function at `address`: cached, running, failed or
    /// newly started. One analysis runs at a time per session.
    pub fn request(self: *State, a: Allocator, session: *Session, address: u64, options: Options) !Status {
        switch (try discover(a, self.toolchain_dir)) {
            .unavailable => |u| return .{ .unavailable = u },
            .ready => {},
        }
        if (session.target.arch() != .x86_64) return .{ .unavailable = .{ .reason = "unsupported_architecture", .detail = "the native worker exports x86-64 only" } };
        const function = try self.resolve(a, session, address);
        self.poll();
        if (self.cached(function.key)) |analysis| return .{ .ready = analysis };
        if (self.job) |job| {
            if (job.function.key.eql(function.key)) {
                if (job.running()) return .{ .running = job };
                if (job.failure != null and !options.retry) return .{ .failed = job };
            } else if (job.running()) return error.StaticAnalysisBusy;
        }
        return .{ .running = try self.start(session, function, options) };
    }

    fn start(self: *State, session: *Session, function: Function, options: Options) !*Job {
        const toolchain = switch (try discover(page, self.toolchain_dir)) {
            .ready => |t| t,
            .unavailable => return error.StaticAnalysisUnavailable,
        };
        const dir = try self.privateDir();
        const image_path = try std.fmt.allocPrintSentinel(page, "{s}/image-{s}.elf", .{ dir, &function.key.image_sha256 }, 0);
        defer page.free(image_path);
        if (!present(image_path)) {
            // The worker reads exactly the bytes this session holds for the module.
            const module = try session.modules.at(function.runtime(function.key.entry));
            if (!std.mem.eql(u8, &self.identity(module), &function.key.image_sha256)) return error.BinaryChangedDuringRead;
            const temporary = try std.fmt.allocPrintSentinel(page, "{s}/.image-{s}.tmp", .{ dir, &function.key.image_sha256 }, 0);
            defer page.free(temporary);
            _ = libc.unlink(temporary.ptr);
            try writeFile(temporary, module.mapping);
            if (libc.rename(temporary.ptr, image_path.ptr) != 0) return error.ImageSnapshotWriteFailed;
        }
        if (self.job) |old| {
            old.destroy();
            page.destroy(old);
            self.job = null;
        }
        const flag = c.xghx_cancel_new() orelse return error.OutOfMemory;
        errdefer c.xghx_cancel_free(flag);
        const job = try page.create(Job);
        errdefer page.destroy(job);
        job.* = .{ .id = self.next_job, .arena = .init(page), .cancel = flag, .function = undefined, .toolchain = undefined, .image_path = undefined, .outdir = undefined, .deadline_ms = std.math.clamp(options.deadline_ms, 100, max_deadline_ms), .started_ms = nowMs(), .owner = options.owner };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.function = try function.dupe(a);
        job.toolchain = .{ .dir = try a.dupe(u8, toolchain.dir), .supervisor = try a.dupeZ(u8, toolchain.supervisor), .worker = try a.dupeZ(u8, toolchain.worker), .sleigh = try a.dupeZ(u8, toolchain.sleigh) };
        job.image_path = try a.dupeZ(u8, image_path);
        job.outdir = try std.fmt.allocPrintSentinel(a, "{s}/job-{d}", .{ dir, self.next_job }, 0);
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.next_job += 1;
        return job;
    }
};

fn hexAlloc(a: Allocator, bytes: []const u8) ![]u8 {
    const out = try a.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}

test "an export of other bytes or another entry is refused, never reconciled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("adapter_fixture.json"), .{});
    const image = doc.object.get("image").?;
    var job: Job = .{ .id = 1, .arena = .init(std.heap.page_allocator), .cancel = undefined, .function = .{ .key = .{ .image_sha256 = undefined, .entry = 0x4012e0, .size = 0x5b }, .name = "qx_alloc", .module_id = 1, .module_path = "", .bias = 0, .bounds_source = "elf_symbol", .build_id = str(image, "gnu_build_id") }, .toolchain = undefined, .image_path = "", .outdir = "", .deadline_ms = 1, .started_ms = 0 };
    defer job.arena.deinit();
    @memcpy(&job.function.key.image_sha256, str(image, "sha256").?);
    try job.admit(a, doc);
    try std.testing.expect(job.failure == null);
    job.function.key.image_sha256[0] ^= 1;
    try std.testing.expectError(error.ImageIdentityMismatch, job.admit(a, doc));
    try std.testing.expectEqualStrings("image_identity_mismatch", job.failure.?.code);
    job.function.key.image_sha256[0] ^= 1;
    job.function.build_id = "00";
    try std.testing.expectError(error.ImageIdentityMismatch, job.admit(a, doc));
    job.function.build_id = str(image, "gnu_build_id");
    job.function.key.entry += 1;
    try std.testing.expectError(error.FunctionIdentityMismatch, job.admit(a, doc));
    try std.testing.expectEqualStrings("function_identity_mismatch", job.failure.?.code);
}

test "worker discovery names the missing piece" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("not_configured", (try discover(arena.allocator(), null)).unavailable.reason);
    try std.testing.expectEqualStrings("supervisor_missing", (try discover(arena.allocator(), "/nonexistent-static-analysis")).unavailable.reason);
}

test "cancel: own jobs, or any job only with control" {
    try std.testing.expect(mayCancel(.human, .human));
    try std.testing.expect(mayCancel(.{ .agent = 7 }, .human));
    try std.testing.expect(mayCancel(.{ .agent = 7 }, .{ .agent = .{ .client = 7, .controller = false } }));
    try std.testing.expect(!mayCancel(.{ .agent = 7 }, .{ .agent = .{ .client = 8, .controller = false } }));
    try std.testing.expect(mayCancel(.{ .agent = 7 }, .{ .agent = .{ .client = 8, .controller = true } }));
    try std.testing.expect(!mayCancel(.human, .{ .agent = .{ .client = 8, .controller = false } }));
    try std.testing.expect(mayCancel(.human, .{ .agent = .{ .client = 8, .controller = true } }));
    try std.testing.expect(!mayCancel(.human, .{ .agent = .{ .client = null, .controller = false } }));
    try std.testing.expect(mayCancel(.{ .agent = null }, .{ .agent = .{ .client = null, .controller = false } }));
}
