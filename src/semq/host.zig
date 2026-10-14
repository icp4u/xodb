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
const sidecar = @import("ghidra_sidecar.zig");
pub const c = @cImport({
    @cInclude("xsq.h");
    @cInclude("xsq_report.h");
    @cInclude("ghx_host.h");
});
const Allocator = std.mem.Allocator;
const page = std.heap.page_allocator;

pub const banner = "static possibilities, not an observed execution";
pub const how_to_build = "set GHIDRA_HOME to a Ghidra installation with a JDK on PATH; xodb starts scripts/ghidra-sidecar on demand. The no-JVM x86-64 fallback is built with `sh tools/ghx/build_ghidra.sh GHIDRA_CHECKOUT DIR && make -C tools/ghx GHIDRA_CPP=DIR/ghidra-src/Ghidra/Features/Decompiler/src/decompile/cpp OUT=DIR`, then selected with `--static-analysis DIR`.";
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
pub const ProducerKind = enum { native, sidecar };

/// The native worker's printed document.  Positions and addresses are kept
/// exactly as exported: lines are 1-based, columns are byte offsets, and pc is
/// a link-time address.  A missing pc is meaningful; consumers must never
/// invent a nearest instruction for it.
pub const PseudoToken = struct {
    index: u32,
    line: u32,
    col: u32,
    kind: []const u8,
    text: []const u8,
    op: ?u32 = null,
    pc: ?u64 = null,
    parameter: ?u32 = null,
};
pub const EntryPadMapping = struct {
    start: u64,
    end: u64,
    line: u32,
    token: u32,
};
pub const PseudoVariable = struct {
    name: []const u8,
    type_name: []const u8,
    size: u32,
    parameter: bool,
    storage: []const u8,
    register: ?[]const u8,
    register_bit_offset: u8,
    storage_offset: ?u64,
    valid_start: ?u64,
    valid_end: ?u64,
};
pub const PseudoDocument = struct {
    language: []const u8 = "c",
    printer: []const u8 = "",
    text: []const u8 = "",
    signature: []const u8 = "",
    token_status: []const u8 = "unavailable",
    address_map_status: []const u8 = "unavailable",
    tokens: []const PseudoToken = &.{},
    variables: []const PseudoVariable = &.{},
    entry_pad: ?EntryPadMapping = null,
};

/// A completed export, converted and loaded once; cached by artifact_id.
pub const Analysis = struct {
    arena: std.heap.ArenaAllocator,
    function: Function,
    artifact_id: []const u8,
    contract: []const u8,
    schema_version: []const u8,
    level: []const u8,
    reasons: []const Reason,
    producer_kind: ProducerKind,
    producer_name: []const u8,
    producer_version: []const u8,
    pseudocode: PseudoDocument = .{},
    graph_available: bool = false,
    graph_failure: ?Failure = null,
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
    producer_kind: ProducerKind = .native,
    toolchain: ?Toolchain = null,
    sidecar_socket: [:0]const u8 = "",
    sidecar_starter: ?[:0]const u8 = null,
    image_path: [:0]const u8,
    outdir: [:0]const u8,
    deadline_ms: u32,
    cancel: *c.struct_xsq_cancel,
    stop: std.atomic.Value(bool) = .init(false),
    stage: std.atomic.Value(sidecar.Stage) = .init(.queued),
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
        self.stop.store(true, .release);
        c.xsq_cancel_request(self.cancel);
    }
    pub fn cancelRequested(self: *Job) bool {
        return self.stop.load(.acquire) or c.xsq_cancel_requested(self.cancel) != 0;
    }
    pub fn progress(self: *const Job) []const u8 {
        return sidecar.stageText(self.stage.load(.acquire));
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
        if (self.failure != null) self.stage.store(.failed, .release);
        self.finished_ms = nowMs();
        self.done.store(true, .release);
    }
    const Export = struct { path: []const u8, bytes: []const u8, worker_ms: f64 };
    fn nativeExport(self: *Job, a: Allocator) !?Export {
        self.stage.store(.analyzing, .release);
        const toolchain = self.toolchain.?;
        const line = try std.fmt.allocPrintSentinel(a, "DECOMPILE\tid=f\telf={s}\tentry=0x{x}\tsize=0x{x}\tname={s}", .{ self.image_path, self.function.key.entry, self.function.key.size, safeName(a, self.function.name) }, 0);
        const request = c.struct_xghx_request{ .supervisor = toolchain.supervisor.ptr, .worker = toolchain.worker.ptr, .sleighhome = toolchain.sleigh.ptr, .outdir = self.outdir.ptr, .line = line.ptr, .deadline_ms = self.deadline_ms, .grace_ms = 250, .memory_mb = 4096 };
        var outcome: c.struct_xghx_outcome = undefined;
        const status = c.xghx_run(&request, self.cancel, &outcome);
        const worker_status = std.mem.sliceTo(&outcome.status, 0);
        const detail = std.mem.sliceTo(&outcome.detail, 0);
        const pid: ?i64 = if (outcome.worker_pid > 0) outcome.worker_pid else null;
        switch (status) {
            c.XGHX_RESULT => {},
            c.XGHX_CANCELLED => {
                self.failure = .{ .code = "cancelled", .detail = "cancelled; the supervisor and its worker were stopped and reaped", .worker_pid = pid };
                return null;
            },
            c.XGHX_HOST_DEADLINE => {
                self.failure = .{ .code = "worker_timeout", .detail = try std.fmt.allocPrint(a, "the supervisor exceeded the host bound of {d} ms and was stopped", .{self.deadline_ms}), .worker_pid = pid };
                return null;
            },
            c.XGHX_SPAWN_FAILED => {
                self.fail("supervisor_failed", "could not start ghx_supervise (errno {d})", .{outcome.@"error"});
                return null;
            },
            else => {
                self.failure = .{ .code = "supervisor_failed", .detail = try std.fmt.allocPrint(a, "ghx_supervise ended without a result (wait status {d})", .{outcome.supervisor_status}), .worker_pid = pid };
                return null;
            },
        }
        if (!std.mem.eql(u8, worker_status, "ok")) {
            const code: []const u8 = if (std.mem.eql(u8, worker_status, "timeout")) "worker_timeout" else if (std.mem.eql(u8, worker_status, "worker_died")) "worker_died" else if (std.mem.eql(u8, worker_status, "cancelled")) "cancelled" else if (std.mem.eql(u8, worker_status, "error")) "worker_refused" else "worker_failed";
            var text: []const u8 = try a.dupe(u8, detail);
            if (refusal(a, std.mem.sliceTo(&outcome.file, 0))) |cause| text = cause;
            self.failure = .{ .code = code, .detail = text, .worker_status = try a.dupe(u8, worker_status), .worker_pid = pid };
            return null;
        }
        const export_path = try a.dupe(u8, std.mem.sliceTo(&outcome.file, 0));
        const bytes = readFile(a, export_path, max_export_bytes) catch |err| {
            self.fail("export_unreadable", "{s}", .{@errorName(err)});
            return null;
        };
        return .{ .path = export_path, .bytes = bytes, .worker_ms = outcome.ms };
    }
    fn sidecarStartupFailure(code: []const u8) bool {
        for ([_][]const u8{ "sidecar_unavailable", "sidecar_not_configured", "sidecar_start_failed", "sidecar_protocol_mismatch", "sidecar_died", "sidecar_io_failed", "sidecar_bad_reply", "sidecar_timeout", "sidecar_failed" }) |candidate|
            if (std.mem.eql(u8, code, candidate)) return true;
        return false;
    }
    fn work(self: *Job) !void {
        const a = self.arena.allocator();
        if (libc.mkdir(self.outdir.ptr, 0o700) != 0) return self.fail("host_error", "cannot create the job directory", .{});
        var export_path: []const u8 = undefined;
        var bytes: []const u8 = undefined;
        var worker_ms: f64 = 0;
        if (self.producer_kind == .native) {
            const exported = (try self.nativeExport(a)) orelse return;
            export_path = exported.path;
            bytes = exported.bytes;
            worker_ms = exported.worker_ms;
        } else {
            var sidecar_failure: sidecar.Failure = undefined;
            const outcome: ?sidecar.Result = sidecar.run(a, .{
                .socket_path = self.sidecar_socket,
                .starter = self.sidecar_starter,
                .image_path = self.image_path,
                .sha256 = &self.function.key.image_sha256,
                .entry = self.function.key.entry,
                .size = self.function.key.size,
                .build_id = self.function.build_id,
                .deadline_ms = self.deadline_ms,
            }, &self.stop, &self.stage, &sidecar_failure) catch |err| fallback: {
                const code = if (err == error.SidecarFailed) sidecar_failure.code else "sidecar_failed";
                if (self.toolchain != null and sidecarStartupFailure(code) and !self.cancelRequested()) {
                    self.producer_kind = .native;
                    break :fallback null;
                }
                if (err == error.SidecarFailed) self.failure = .{ .code = sidecar_failure.code, .detail = sidecar_failure.detail } else self.fail("sidecar_failed", "{s}", .{@errorName(err)});
                return;
            };
            if (outcome) |ready| {
                export_path = try std.fmt.allocPrint(a, "{s}/sidecar-export.json", .{self.outdir});
                const export_z = try a.dupeZ(u8, export_path);
                try writeFile(export_z, ready.document);
                bytes = ready.document;
                worker_ms = ready.elapsed_ms;
            } else {
                const exported = (try self.nativeExport(a)) orelse return;
                export_path = exported.path;
                bytes = exported.bytes;
                worker_ms = exported.worker_ms;
            }
        }
        if (self.cancelRequested()) return self.fail("cancelled", "cancelled after the export", .{});
        const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .max_value_len = max_export_bytes }) catch |err| return self.fail("export_unreadable", "{s}", .{@errorName(err)});
        try self.admit(a, doc);
        const analysis = try page.create(Analysis);
        analysis.* = .{ .arena = .init(page), .function = undefined, .artifact_id = "", .contract = "", .schema_version = "", .level = "", .reasons = &.{}, .producer_kind = self.producer_kind, .producer_name = "", .producer_version = "", .export_path = "", .worker_ms = worker_ms };
        errdefer {
            analysis.destroy();
            page.destroy(analysis);
        }
        const keep = analysis.arena.allocator();
        analysis.function = try self.function.dupe(keep);
        analysis.artifact_id = try keep.dupe(u8, str(doc, "artifact_id") orelse "unknown");
        analysis.contract = try keep.dupe(u8, str(doc, "contract") orelse "");
        analysis.schema_version = try keep.dupe(u8, str(doc, "schema_version") orelse "");
        analysis.export_path = try keep.dupe(u8, export_path);
        const producer_doc = if (doc.object.get("producer")) |v| v else std.json.Value.null;
        analysis.producer_name = try keep.dupe(u8, str(producer_doc, "kind") orelse if (self.producer_kind == .sidecar) "ghidra_java_sidecar" else "ghidra_native_decompiler");
        analysis.producer_version = try keep.dupe(u8, str(producer_doc, "worker_version") orelse "unknown");
        const q = if (doc.object.get("qualification")) |v| v else std.json.Value.null;
        analysis.level = try keep.dupe(u8, str(q, "level") orelse "unknown");
        var reasons: std.ArrayList(Reason) = .empty;
        if (q == .object) if (q.object.get("reasons")) |list| if (list == .array) for (list.array.items) |r| {
            const address = if (str(r, "addr")) |text| (if (std.mem.startsWith(u8, text, "0x")) std.fmt.parseInt(u64, text[2..], 16) catch null else null) else null;
            try reasons.append(keep, .{ .code = try keep.dupe(u8, str(r, "code") orelse "?"), .level = try keep.dupe(u8, str(r, "level") orelse "?"), .detail = try keep.dupe(u8, str(r, "detail") orelse ""), .address = address });
        };
        analysis.reasons = reasons.items;
        analysis.pseudocode = try pseudoDocument(keep, doc);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const converted = switch (try adapter.convert(a, doc, &std.fmt.bytesToHex(digest, .lower))) {
            .refused => |why| {
                analysis.graph_failure = .{ .code = "adapter_refused", .detail = try keep.dupe(u8, why) };
                self.stage.store(.ready, .release);
                self.analysis = analysis;
                return;
            },
            .xsg => |text| text,
        };
        var budget = c.struct_xsq_load_budget{ .max_bytes = 256 << 20, .cancel = self.cancel };
        const loaded = c.xsq_load_buffer_budget(converted.ptr, converted.len, &budget, &analysis.graph);
        if (loaded != c.XSQ_OK) {
            const err_text = std.mem.sliceTo(&analysis.graph.@"error", 0);
            if (loaded == c.XSQ_CANCELLED) {
                self.fail("cancelled", "cancelled while loading the graph", .{});
                return error.GraphRejected;
            }
            analysis.graph_failure = .{
                .code = "graph_rejected",
                .detail = try std.fmt.allocPrint(keep, "{s}: line {d}: {s}", .{ std.mem.span(c.xsq_status_name(loaded)), analysis.graph.error_line, err_text }),
            };
            self.stage.store(.ready, .release);
            self.analysis = analysis;
            return;
        }
        if (analysis.graph.func_count != 1) {
            analysis.graph_failure = .{ .code = "graph_rejected", .detail = try std.fmt.allocPrint(keep, "expected one function, got {d}", .{analysis.graph.func_count}) };
            self.stage.store(.ready, .release);
            self.analysis = analysis;
            return;
        }
        analysis.graph_available = true;
        self.stage.store(.ready, .release);
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

fn number(v: std.json.Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}

fn hexField(v: std.json.Value, key: []const u8) ?u64 {
    const text = str(v, key) orelse return null;
    if (!std.mem.startsWith(u8, text, "0x")) return null;
    return std.fmt.parseInt(u64, text[2..], 16) catch null;
}

fn idNumber(text: ?[]const u8, prefix: []const u8) ?u32 {
    const value = text orelse return null;
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return std.fmt.parseInt(u32, value[prefix.len..], 10) catch null;
}

fn signature(text: []const u8) []const u8 {
    var rows = Rows{ .lines = std.mem.splitScalar(u8, text, '\n') };
    while (rows.next()) |row| {
        const trimmed = std.mem.trim(u8, row.text, " \t\r");
        if (trimmed.len != 0 and !row.comment) return trimmed;
    }
    return "";
}

/// Pseudo-C lines with whether each holds nothing but comment text. A block
/// comment's later lines carry no marker of their own, so this keeps state.
const Rows = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    open: bool = false,

    const Row = struct { text: []const u8, comment: bool };

    fn next(self: *Rows) ?Row {
        const line = self.lines.next() orelse return null;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!self.open and !std.mem.startsWith(u8, trimmed, "/*")) return .{ .text = line, .comment = std.mem.startsWith(u8, trimmed, "//") };
        const from: usize = if (self.open) 0 else 2;
        const close = std.mem.indexOfPos(u8, trimmed, from, "*/") orelse {
            self.open = true;
            return .{ .text = line, .comment = true };
        };
        self.open = false;
        return .{ .text = line, .comment = std.mem.trim(u8, trimmed[close + 2 ..], " \t\r").len == 0 };
    }
};

fn textLine(text: []const u8, wanted: u32) ?[]const u8 {
    if (wanted == 0) return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line: u32 = 1;
    while (lines.next()) |row| : (line += 1) if (line == wanted) return row;
    return null;
}

fn normalizePseudoTokens(a: Allocator, text: []const u8, tokens: *std.ArrayList(PseudoToken)) !void {
    // A partial Ghidra markup alignment must never repaint different token text
    // on top of the authoritative pseudo-C line. Keep only exact spans.
    var kept: usize = 0;
    for (tokens.items) |token| {
        const line = textLine(text, token.line) orelse continue;
        const col: usize = token.col;
        if (col > line.len or token.text.len > line.len - col or !std.mem.eql(u8, line[col .. col + token.text.len], token.text)) continue;
        tokens.items[kept] = token;
        kept += 1;
    }
    tokens.shrinkRetainingCapacity(kept);

    // Per line (1-based): comment-only, or blank.
    var skip: std.ArrayList(bool) = .empty;
    defer skip.deinit(a);
    var comment: std.ArrayList(bool) = .empty;
    defer comment.deinit(a);
    try skip.append(a, true);
    try comment.append(a, false);
    var rows = Rows{ .lines = std.mem.splitScalar(u8, text, '\n') };
    while (rows.next()) |row| {
        try comment.append(a, row.comment);
        try skip.append(a, row.comment or std.mem.trim(u8, row.text, " \t\r").len == 0);
    }

    const Orphan = struct { pc: u64, line: u32 };
    var orphans: std.ArrayList(Orphan) = .empty;
    defer orphans.deinit(a);
    for (tokens.items) |*token| {
        if (token.line >= comment.items.len or !comment.items[token.line] or token.pc == null) continue;
        const pc = token.pc.?;
        var remembered = false;
        for (orphans.items) |old| if (old.pc == pc) {
            remembered = true;
            break;
        };
        if (!remembered) try orphans.append(a, .{ .pc = pc, .line = token.line });
        token.pc = null;
    }
    // Ghidra attaches an entry PC to its generated comment. Move that marker
    // to the first following code row, unless a real token already carries it.
    for (orphans.items) |orphan| {
        var already_mapped = false;
        for (tokens.items) |token| if (token.pc == orphan.pc) {
            already_mapped = true;
            break;
        };
        if (already_mapped) continue;
        var candidate: ?usize = null;
        for (tokens.items, 0..) |token, index| {
            if (token.line <= orphan.line or token.pc != null) continue;
            if (token.line >= skip.items.len or skip.items[token.line]) continue;
            if (candidate == null or token.line < tokens.items[candidate.?].line) candidate = index;
        }
        if (candidate) |index| tokens.items[index].pc = orphan.pc;
    }
}

fn pseudoDocument(a: Allocator, root: std.json.Value) !PseudoDocument {
    const pseudo = if (root == .object) root.object.get("pseudocode") orelse return .{} else return .{};
    if (pseudo != .object) return .{};
    const function = root.object.get("function") orelse std.json.Value.null;
    const prototype = if (function == .object) function.object.get("prototype") orelse std.json.Value.null else std.json.Value.null;
    const params = if (prototype == .object) prototype.object.get("params") orelse std.json.Value.null else std.json.Value.null;
    var parameter_names: std.StringHashMapUnmanaged(u32) = .empty;
    defer parameter_names.deinit(a);
    if (params == .array) for (params.array.items) |param| {
        const name = str(param, "name") orelse continue;
        const index = number(param, "index") orelse continue;
        if (index < 0 or index > std.math.maxInt(u32)) continue;
        const found = try parameter_names.getOrPut(a, name);
        if (!found.found_existing) found.value_ptr.* = @intCast(index);
    };
    var tokens: std.ArrayList(PseudoToken) = .empty;
    if (pseudo.object.get("tokens")) |list| if (list == .array) for (list.array.items) |token| {
        const line = number(token, "line") orelse continue;
        const col = number(token, "col") orelse continue;
        const index = number(token, "i") orelse continue;
        if (line <= 0 or col < 0 or index < 0 or line > std.math.maxInt(u32) or col > std.math.maxInt(u32) or index > std.math.maxInt(u32)) continue;
        const token_text = str(token, "text") orelse "";
        try tokens.append(a, .{
            .index = @intCast(index),
            .line = @intCast(line),
            .col = @intCast(col),
            .kind = try a.dupe(u8, str(token, "kind") orelse "text"),
            .text = try a.dupe(u8, token_text),
            .op = idNumber(str(token, "op"), "op:"),
            .pc = hexField(token, "pc"),
            .parameter = parameter_names.get(token_text),
        });
    };
    const text = try a.dupe(u8, str(pseudo, "text") orelse "");
    try normalizePseudoTokens(a, text, &tokens);
    var variables: std.ArrayList(PseudoVariable) = .empty;
    if (root.object.get("variables")) |list| if (list == .array) for (list.array.items) |variable| {
        const size = number(variable, "size") orelse 0;
        if (size < 0 or size > std.math.maxInt(u32)) continue;
        const parameter = if (variable == .object) if (variable.object.get("parameter")) |value| value == .bool and value.bool else false else false;
        try variables.append(a, .{
            .name = try a.dupe(u8, str(variable, "name") orelse ""),
            .type_name = try a.dupe(u8, str(variable, "type") orelse ""),
            .size = @intCast(size),
            .parameter = parameter,
            .storage = try a.dupe(u8, str(variable, "storage") orelse "temp"),
            .register = if (str(variable, "register")) |name| try a.dupe(u8, name) else null,
            .register_bit_offset = @intCast(@min(63, @max(0, number(variable, "register_bit_offset") orelse 0))),
            .storage_offset = hexField(variable, "storage_offset"),
            .valid_start = hexField(variable, "valid_start"),
            .valid_end = hexField(variable, "valid_end"),
        });
    };
    var pad_mapping: ?EntryPadMapping = null;
    if (adapter.verifiedEntryPad(a, root)) |pad| {
        // The pad belongs to the line carrying the first mapped instruction
        // after it. This is an exact mapping only for adapter-proven pads.
        var first_pc: u64 = std.math.maxInt(u64);
        var first_token: ?PseudoToken = null;
        for (tokens.items) |candidate| {
            const pc = candidate.pc orelse continue;
            if (pc < pad.end or pc > first_pc) continue;
            if (pc < first_pc or first_token == null or candidate.line < first_token.?.line) {
                first_pc = pc;
                first_token = candidate;
            }
        }
        if (first_token) |target| pad_mapping = .{
            .start = pad.start,
            .end = pad.end,
            .line = target.line,
            .token = target.index,
        };
    }
    return .{
        .language = try a.dupe(u8, str(pseudo, "language") orelse "c"),
        .printer = try a.dupe(u8, str(pseudo, "printer") orelse ""),
        .text = text,
        .signature = try a.dupe(u8, signature(text)),
        .token_status = try a.dupe(u8, str(pseudo, "token_status") orelse "unavailable"),
        .address_map_status = try a.dupe(u8, str(pseudo, "address_map_status") orelse "unavailable"),
        .tokens = tokens.items,
        .variables = variables.items,
        .entry_pad = pad_mapping,
    };
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
const max_warm_images = 8;
const max_warm_functions = 16;
/// A cancelled background import that ran at least this long counts as wasted.
const warm_waste_ms = 2000;

const WarmImage = struct {
    module_id: u64,
    path: [:0]const u8,
    snapshot_path: [:0]const u8,
    mapping: ?[]const u8,
    size: usize,
    use_original: bool,
};
const WarmCandidate = struct { id: u64, path: []const u8, mapping: ?[]const u8, size: usize, file_offset: u64 };
const WarmFunction = struct {
    sha256: [64]u8,
    path: [:0]const u8,
    snapshot_path: [:0]const u8,
    mapping: ?[]const u8,
    entry: u64,
    build_id: ?[]const u8,
    /// Stack functions seed direct callees; breakpoint functions do not.
    seed_callees: bool,
};
const WarmFunctionCandidate = struct { sha256: [64]u8, path: []const u8, mapping: ?[]const u8, entry: u64, build_id: ?[]const u8, seed_callees: bool };

const Warmup = struct {
    arena: std.heap.ArenaAllocator = .init(page),
    endpoint: sidecar.Endpoint = undefined,
    images: []const WarmImage = &.{},
    functions: []const WarmFunction = &.{},
    cancel: std.atomic.Value(bool) = .init(false),
    stage: std.atomic.Value(sidecar.Stage) = .init(.queued),
    attempted: std.atomic.Value(usize) = .init(0),
    /// The sidecar could not be reached or started; asking again per image
    /// would only run the starter again.
    unusable: std.atomic.Value(bool) = .init(false),
    /// A cancelled import had already cost the sidecar real work.
    wasted: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    fn sidecarGone(err: anyerror, failure: *const sidecar.Failure) bool {
        return err == error.SidecarFailed and std.mem.startsWith(u8, failure.code, "sidecar_");
    }

    fn run(self: *Warmup) void {
        _ = libc.nice(10);
        defer self.done.store(true, .release);
        const a = self.arena.allocator();
        for (self.images, 0..) |image, index| {
            if (self.cancel.load(.acquire)) return;
            const sha = if (image.mapping) |mapping| hashWarmBytes(mapping, &self.cancel) catch return else hashWarmFile(image.path, &self.cancel) catch {
                if (self.cancel.load(.acquire)) return;
                self.attempted.store(index + 1, .release);
                continue;
            };
            const path = if (image.use_original) image.path else blk: {
                writeWarmSnapshot(image.snapshot_path, image.mapping.?, &self.cancel) catch {
                    // A snapshot that cannot be written is not asked for again at every poll.
                    if (self.cancel.load(.acquire)) return;
                    self.attempted.store(index + 1, .release);
                    continue;
                };
                break :blk image.snapshot_path;
            };
            var failure: sidecar.Failure = undefined;
            const begun = nowMs();
            sidecar.openImage(a, self.endpoint, path, &sha, &self.cancel, &self.stage, &failure) catch |err| {
                if (self.cancel.load(.acquire)) {
                    if (nowMs() - begun >= warm_waste_ms) self.wasted.store(true, .release);
                    return;
                }
                if (sidecarGone(err, &failure)) return self.unusable.store(true, .release);
                self.attempted.store(index + 1, .release);
                continue;
            };
            self.attempted.store(index + 1, .release);
        }
        var warmed: [max_warm_functions]struct { sha256: [64]u8, entry: u64 } = undefined;
        var warmed_count: usize = 0;
        var stack_docs: [max_warm_functions]?[]const u8 = @splat(null);
        // Stack functions first, in frame order.
        for (self.functions, 0..) |function, index| {
            if (!function.seed_callees or warmed_count == warmed.len or self.cancel.load(.acquire)) continue;
            const path = self.functionImage(function) catch continue;
            if (!self.openFunctionImage(function, path)) {
                if (self.cancel.load(.acquire) or self.unusable.load(.acquire)) return;
                continue;
            }
            var failure: sidecar.Failure = undefined;
            const document = sidecar.warmDecompile(a, self.endpoint, path, &function.sha256, function.entry, function.build_id, &self.cancel, &self.stage, &failure) catch |err| {
                if (self.cancel.load(.acquire)) return;
                if (sidecarGone(err, &failure)) return self.unusable.store(true, .release);
                continue;
            };
            warmed[warmed_count] = .{ .sha256 = function.sha256, .entry = function.entry };
            warmed_count += 1;
            stack_docs[index] = document;
        }
        // Then one level of direct callees from those stack documents.
        for (self.functions, 0..) |function, index| {
            const bytes = stack_docs[index] orelse continue;
            const doc = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{ .max_value_len = max_export_bytes }) catch continue;
            const function_index = if (doc == .object) doc.object.get("function_index") orelse continue else continue;
            const direct = if (function_index == .object) function_index.object.get("direct_callees") orelse continue else continue;
            if (direct != .array) continue;
            const path = self.functionImage(function) catch continue;
            for (direct.array.items) |callee| {
                if (warmed_count == warmed.len or self.cancel.load(.acquire)) break;
                const entry = hexField(callee, "entry") orelse continue;
                var seen = false;
                for (warmed[0..warmed_count]) |old| if (old.entry == entry and std.mem.eql(u8, &old.sha256, &function.sha256)) {
                    seen = true;
                    break;
                };
                if (seen) continue;
                var failure: sidecar.Failure = undefined;
                _ = sidecar.warmDecompile(a, self.endpoint, path, &function.sha256, entry, function.build_id, &self.cancel, &self.stage, &failure) catch |err| {
                    if (self.cancel.load(.acquire)) return;
                    if (sidecarGone(err, &failure)) return self.unusable.store(true, .release);
                    continue;
                };
                warmed[warmed_count] = .{ .sha256 = function.sha256, .entry = entry };
                warmed_count += 1;
            }
        }
        // User breakpoints are last.
        for (self.functions) |function| {
            if (function.seed_callees or warmed_count == warmed.len or self.cancel.load(.acquire)) continue;
            var seen = false;
            for (warmed[0..warmed_count]) |old| if (old.entry == function.entry and std.mem.eql(u8, &old.sha256, &function.sha256)) {
                seen = true;
                break;
            };
            if (seen) continue;
            const path = self.functionImage(function) catch continue;
            if (!self.openFunctionImage(function, path)) {
                if (self.cancel.load(.acquire) or self.unusable.load(.acquire)) return;
                continue;
            }
            var failure: sidecar.Failure = undefined;
            _ = sidecar.warmDecompile(a, self.endpoint, path, &function.sha256, function.entry, function.build_id, &self.cancel, &self.stage, &failure) catch |err| {
                if (self.cancel.load(.acquire)) return;
                if (sidecarGone(err, &failure)) return self.unusable.store(true, .release);
                continue;
            };
            warmed[warmed_count] = .{ .sha256 = function.sha256, .entry = function.entry };
            warmed_count += 1;
        }
    }

    fn functionImage(self: *Warmup, function: WarmFunction) ![]const u8 {
        if (function.mapping == null) return function.path;
        try writeWarmSnapshot(function.snapshot_path, function.mapping.?, &self.cancel);
        return function.snapshot_path;
    }

    fn openFunctionImage(self: *Warmup, function: WarmFunction, path: []const u8) bool {
        var failure: sidecar.Failure = undefined;
        sidecar.openImage(self.arena.allocator(), self.endpoint, path, &function.sha256, &self.cancel, &self.stage, &failure) catch |err| {
            if (self.cancel.load(.acquire)) return false;
            if (sidecarGone(err, &failure)) self.unusable.store(true, .release);
            return false;
        };
        return true;
    }

    fn destroy(self: *Warmup) void {
        self.cancel.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        var arena = self.arena;
        arena.deinit();
        page.destroy(self);
    }
};

fn hashWarmBytes(bytes: []const u8, cancel: *const std.atomic.Value(bool)) ![64]u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (cancel.load(.acquire)) return error.Cancelled;
        const end = @min(bytes.len, offset + (1 << 20));
        digest.update(bytes[offset..end]);
        offset = end;
    }
    var result: [32]u8 = undefined;
    digest.final(&result);
    return std.fmt.bytesToHex(result, .lower);
}

fn hashWarmFile(path: [:0]const u8, cancel: *const std.atomic.Value(bool)) ![64]u8 {
    const fd = libc.open(path.ptr, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
    if (fd < 0) return error.ImageSnapshotReadFailed;
    defer _ = libc.close(fd);
    var stat: libc.struct_stat = undefined;
    if (libc.fstat(fd, &stat) != 0 or stat.st_mode & libc.S_IFMT != libc.S_IFREG) return error.ImageSnapshotReadFailed;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        if (cancel.load(.acquire)) return error.Cancelled;
        const count = libc.read(fd, &buffer, buffer.len);
        if (count < 0 and std.c._errno().* == libc.EINTR) continue;
        if (count < 0) return error.ImageSnapshotReadFailed;
        if (count == 0) break;
        digest.update(buffer[0..@intCast(count)]);
    }
    var result: [32]u8 = undefined;
    digest.final(&result);
    return std.fmt.bytesToHex(result, .lower);
}

fn writeWarmSnapshot(path: [:0]const u8, bytes: []const u8, cancel: *const std.atomic.Value(bool)) !void {
    if (present(path)) return;
    const fd = libc.open(path.ptr, libc.O_WRONLY | libc.O_CREAT | libc.O_EXCL | libc.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return error.ImageSnapshotWriteFailed;
    defer _ = libc.close(fd);
    var complete = false;
    defer {
        if (!complete) _ = libc.unlink(path.ptr);
    }
    var done: usize = 0;
    while (done < bytes.len) {
        if (cancel.load(.acquire)) return error.Cancelled;
        const end = @min(bytes.len, done + (1 << 20));
        const n = libc.write(fd, bytes[done..end].ptr, end - done);
        if (n <= 0) return error.ImageSnapshotWriteFailed;
        done += @intCast(n);
    }
    complete = true;
}

pub const State = struct {
    toolchain_dir: ?[]const u8 = null,
    warmup_enabled: bool = true,
    eager_library_bytes: u64 = 1024 * 1024,
    dir: ?[:0]u8 = null,
    hashed: [8]?Hashed = @splat(null),
    hash_next: usize = 0,
    analyses: std.ArrayList(*Analysis) = .empty,
    job: ?*Job = null,
    warmup: ?*Warmup = null,
    warm_seen: [64]u64 = @splat(0),
    warm_seen_count: usize = 0,
    warm_generation: ?u64 = null,
    /// The first image ever queued: the main executable. Never given up.
    warm_main: ?u64 = null,
    warm_main_path: ?[]u8 = null,
    /// The image whose import was last cancelled after real work.
    warm_struck: ?u64 = null,
    next_job: u64 = 1,

    pub fn deinit(self: *State) void {
        self.cancelWarmup();
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
        if (self.warm_main_path) |path| {
            page.free(path);
            self.warm_main_path = null;
        }
        if (self.dir) |dir| {
            _ = c.xghx_remove_tree(dir.ptr);
            page.free(dir);
            self.dir = null;
        }
    }

    fn sawWarmImage(self: *const State, id: u64) bool {
        for (self.warm_seen[0..self.warm_seen_count]) |seen| if (seen == id) return true;
        return false;
    }

    fn markWarmSeen(self: *State, id: u64) void {
        if (self.sawWarmImage(id) or self.warm_seen_count == self.warm_seen.len) return;
        self.warm_seen[self.warm_seen_count] = id;
        self.warm_seen_count += 1;
    }

    /// Joins a finished or cancelled worker and keeps what it learned.
    fn reapWarmup(self: *State) void {
        const warm = self.warmup orelse return;
        warm.cancel.store(true, .release);
        if (warm.thread) |thread| thread.join();
        warm.thread = null;
        const attempted = @min(warm.attempted.load(.acquire), warm.images.len);
        for (warm.images[0..attempted]) |image| self.markWarmSeen(image.module_id);
        // An import restarts from nothing after a cancel. One that was twice
        // cancelled after real work is left to an explicit request, so short
        // stops cannot keep the sidecar busy for no result.
        if (warm.wasted.load(.acquire) and attempted < warm.images.len) {
            const id = warm.images[attempted].module_id;
            if (self.warm_main != id) {
                if (self.warm_struck == id) self.markWarmSeen(id) else self.warm_struck = id;
            }
        }
        if (warm.unusable.load(.acquire)) self.warmup_enabled = false;
        warm.destroy();
        self.warmup = null;
    }

    fn harvestWarmup(self: *State) void {
        const warm = self.warmup orelse return;
        if (warm.done.load(.acquire)) self.reapWarmup();
    }

    pub fn cancelWarmup(self: *State) void {
        self.reapWarmup();
    }

    fn overEagerBound(self: *State, session: *Session, address: u64) bool {
        const module = session.modules.at(address) catch return false;
        if (module.mapping.len <= self.eager_library_bytes) return false;
        const main = self.warm_main_path orelse return false;
        return !std.mem.eql(u8, main, module.path);
    }

    fn addWarmFunction(self: *State, a: Allocator, session: *Session, candidates: *[max_warm_functions]WarmFunctionCandidate, count: *usize, address: u64, seed_callees: bool) void {
        if (count.* == candidates.len) return;
        const function = self.resolve(a, session, address) catch return;
        for (candidates[0..count.*]) |old| if (old.entry == function.key.entry and std.mem.eql(u8, &old.sha256, &function.key.image_sha256)) return;
        const module = session.modules.at(address) catch return;
        const local_path = !session.target.isRemote() and blk: {
            const path_z = a.dupeZ(u8, function.module_path) catch break :blk false;
            break :blk present(path_z);
        };
        candidates[count.*] = .{
            .sha256 = function.key.image_sha256,
            .path = function.module_path,
            .mapping = if (local_path) null else module.mapping,
            .entry = function.key.entry,
            .build_id = function.build_id,
            .seed_callees = seed_callees,
        };
        count.* += 1;
    }

    /// Starts only bounded background work. The owner calls this after its
    /// normal target poll, so startup, priming and imports never delay it.
    pub fn maintain(self: *State, session: *Session) void {
        self.harvestWarmup();
        const snapshot = session.target.snapshot();
        // Resume only flips the cancellation flag. Joining here would put
        // sidecar I/O on the debugger's execution path; a later poll harvests
        // the worker after it has cancelled its queued Ghidra job.
        if (self.warmup) |warm| if (snapshot.state != .stopped) {
            warm.cancel.store(true, .release);
            return;
        };
        if (!self.warmup_enabled or self.warmup != null) return;
        if (snapshot.pid == 0) return;
        if (snapshot.state != .stopped) return;
        var select_arena = std.heap.ArenaAllocator.init(page);
        defer select_arena.deinit();
        if (!(sidecar.selected(select_arena.allocator()) catch false)) return;
        const need_functions = self.warm_generation == null or self.warm_generation.? != snapshot.generation;
        if (!need_functions and self.warm_seen_count == self.warm_seen.len) return;
        if (self.job) |job| if (job.running()) return;
        var selected_images: [max_warm_images]WarmCandidate = undefined;
        var count: usize = 0;
        // Mapped executable files are available before xodb needs their symbol
        // images. Hashing them in this worker lets the main executable start
        // importing immediately after the first map refresh.
        // Only for a target on this host: a remote target's paths name other
        // files here, or none.
        if (!session.target.isRemote()) for (session.modules.regions.items) |region| {
            if (count == selected_images.len) break;
            if (region.permissions[2] != 'x' or region.inode == 0 or !std.fs.path.isAbsolute(region.path)) continue;
            var hash = std.hash.Wyhash.init(0x676869647261);
            std.hash.autoHash(&hash, region.inode);
            std.hash.autoHash(&hash, region.device_major);
            std.hash.autoHash(&hash, region.device_minor);
            hash.update(region.path);
            const id = hash.final() | (@as(u64, 1) << 63);
            if (self.sawWarmImage(id)) continue;
            var duplicate = false;
            for (selected_images[0..count]) |old| if (old.id == id) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            var stat: libc.struct_stat = undefined;
            const path_z = select_arena.allocator().dupeZ(u8, region.path) catch continue;
            const size: u64 = if (libc.stat(path_z.ptr, &stat) == 0 and stat.st_size >= 0) @intCast(stat.st_size) else region.end -| region.start;
            const main = self.warm_main == null and count == 0 or self.warm_main == id;
            if (!main and size > self.eager_library_bytes) {
                self.markWarmSeen(id);
                continue;
            }
            selected_images[count] = .{ .id = id, .path = region.path, .mapping = null, .size = @intCast(size), .file_offset = 0 };
            count += 1;
        };
        // A remote target's path is not normally present on this host. Once
        // xodb has loaded its immutable snapshot, queue that exact byte slice.
        for (session.modules.loaded.items) |module| {
            if (count == selected_images.len or self.sawWarmImage(module.id)) continue;
            var duplicate = false;
            for (selected_images[0..count]) |old| if (std.mem.eql(u8, old.path, module.path)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            const main = self.warm_main == null and count == 0 or self.warm_main == module.id;
            if (!main and module.mapping.len > self.eager_library_bytes) {
                self.markWarmSeen(module.id);
                continue;
            }
            selected_images[count] = .{ .id = module.id, .path = module.path, .mapping = module.mapping, .size = module.mapping.len, .file_offset = module.file_offset };
            count += 1;
        }
        var selected_functions: [max_warm_functions]WarmFunctionCandidate = undefined;
        var function_count: usize = 0;
        if (need_functions) {
            var tid: ?i32 = null;
            for (session.target.threadSlice()) |thread| if (thread.state == .stopped) {
                if (tid == null or thread.reason != .none) tid = thread.tid;
                if (thread.reason != .none) break;
            };
            if (tid) |stopped_tid| if (session.stack(select_arena.allocator(), stopped_tid, 8)) |frames| {
                for (frames, 0..) |frame, index| {
                    // Nearly every stack ends in libc, and many pass through
                    // a toolkit: only the stop function itself, or a user
                    // breakpoint below, may pull in a library over the eager
                    // bound. The outer frames of one wait for an explicit D.
                    if (index > 0 and self.overEagerBound(session, frame.lookup_pc)) continue;
                    self.addWarmFunction(select_arena.allocator(), session, &selected_functions, &function_count, frame.lookup_pc, true);
                }
            } else |_| {};
            for (session.target.breakpointSlice()) |probe| {
                if (!probe.enabled or probe.pending or probe.internal or probe.temporary) continue;
                self.addWarmFunction(select_arena.allocator(), session, &selected_functions, &function_count, probe.address, false);
            }
            // Symbol/debug discovery can complete later in the same stop.
            // Retry this generation until at least one function resolves.
            if (function_count > 0) self.warm_generation = snapshot.generation;
        }
        if (count == 0 and function_count == 0) return;
        if (self.warm_main == null and count > 0) {
            self.warm_main = selected_images[0].id;
            self.warm_main_path = page.dupe(u8, selected_images[0].path) catch null;
        }
        // The first executable mapping of a normal launch is the main image:
        // it stays first. Everything else goes smallest first, in every batch.
        const pinned: usize = if (count > 0 and self.warm_main == selected_images[0].id) 1 else 0;
        if (count - pinned > 1) std.mem.sort(WarmCandidate, selected_images[pinned..count], {}, struct {
            fn less(_: void, left: WarmCandidate, right: WarmCandidate) bool {
                return left.size < right.size;
            }
        }.less);
        const warm = page.create(Warmup) catch return;
        warm.* = .{};
        const a = warm.arena.allocator();
        warm.endpoint = .{ .socket_path = sidecar.socketPath(a) catch {
            warm.destroy();
            return;
        }, .starter = sidecar.starterPath(a) catch null, .deadline_ms = default_deadline_ms };
        if (count > 0) {
            const images = a.alloc(WarmImage, count) catch {
                warm.destroy();
                return;
            };
            for (selected_images[0..count], images) |candidate, *image| image.* = .{
                .module_id = candidate.id,
                .path = a.dupeZ(u8, candidate.path) catch {
                    warm.destroy();
                    return;
                },
                .snapshot_path = std.fmt.allocPrintSentinel(a, "{s}/warm-{d}.image", .{ self.privateDir() catch {
                    warm.destroy();
                    return;
                }, candidate.id }, 0) catch {
                    warm.destroy();
                    return;
                },
                .mapping = candidate.mapping,
                .size = candidate.size,
                .use_original = candidate.mapping == null,
            };
            warm.images = images;
        }
        if (function_count > 0) {
            const functions = a.alloc(WarmFunction, function_count) catch {
                warm.destroy();
                return;
            };
            for (selected_functions[0..function_count], functions) |candidate, *function| function.* = .{
                .sha256 = candidate.sha256,
                .path = a.dupeZ(u8, candidate.path) catch {
                    warm.destroy();
                    return;
                },
                .snapshot_path = std.fmt.allocPrintSentinel(a, "{s}/warm-f-{s}.image", .{ self.privateDir() catch {
                    warm.destroy();
                    return;
                }, &candidate.sha256 }, 0) catch {
                    warm.destroy();
                    return;
                },
                .mapping = candidate.mapping,
                .entry = candidate.entry,
                .build_id = if (candidate.build_id) |id| a.dupe(u8, id) catch {
                    warm.destroy();
                    return;
                } else null,
                .seed_callees = candidate.seed_callees,
            };
            warm.functions = functions;
        }
        warm.thread = std.Thread.spawn(.{}, Warmup.run, .{warm}) catch {
            warm.destroy();
            return;
        };
        self.warmup = warm;
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

    fn cached(self: *State, key: Key, producer_kind: ProducerKind) ?*Analysis {
        for (self.analyses.items) |analysis| if (analysis.producer_kind == producer_kind and analysis.function.key.eql(key)) return analysis;
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
        const use_sidecar = try sidecar.selected(a);
        const producer_kind: ProducerKind = if (use_sidecar) .sidecar else .native;
        if (!use_sidecar) switch (try discover(a, self.toolchain_dir)) {
            .unavailable => |u| return .{ .unavailable = .{ .reason = u.reason, .detail = "Ghidra sidecar is not configured (set GHIDRA_HOME); the native worker is also unavailable" } },
            .ready => {},
        };
        if (!use_sidecar and session.target.arch() != .x86_64) return .{ .unavailable = .{ .reason = "unsupported_architecture", .detail = "the native worker exports x86-64 only; configure the Ghidra sidecar for this architecture" } };
        const function = try self.resolve(a, session, address);
        self.poll();
        if (self.cached(function.key, producer_kind)) |analysis| return .{ .ready = analysis };
        // If a configured sidecar could not start, keep serving the native
        // result for this function instead of retrying the broken endpoint on
        // every frame. The producer field still says which engine made it.
        if (producer_kind == .sidecar) if (self.cached(function.key, .native)) |analysis| return .{ .ready = analysis };
        if (self.job) |job| {
            if (job.function.key.eql(function.key) and (job.producer_kind == producer_kind or producer_kind == .sidecar and job.producer_kind == .native)) {
                if (job.running()) return .{ .running = job };
                if (job.failure != null and !options.retry) return .{ .failed = job };
            } else if (job.running()) return error.StaticAnalysisBusy;
        }
        // Foreground work only requests cancellation. The owner thread never
        // joins a background sidecar call; maintain() harvests it later.
        if (self.warmup) |warm| warm.cancel.store(true, .release);
        return .{ .running = try self.start(session, function, producer_kind, options) };
    }

    fn start(self: *State, session: *Session, function: Function, producer_kind: ProducerKind, options: Options) !*Job {
        const toolchain: ?Toolchain = find: {
            if (producer_kind == .native) break :find switch (try discover(page, self.toolchain_dir)) {
                .ready => |t| t,
                .unavailable => return error.StaticAnalysisUnavailable,
            };
            if (session.target.arch() != .x86_64) break :find null;
            const found = discover(page, self.toolchain_dir) catch break :find null;
            break :find switch (found) {
                .ready => |t| t,
                .unavailable => null,
            };
        };
        const dir = try self.privateDir();
        const module = try session.modules.at(function.runtime(function.key.entry));
        if (!std.mem.eql(u8, &self.identity(module), &function.key.image_sha256)) return error.BinaryChangedDuringRead;
        const original = try page.dupeZ(u8, function.module_path);
        defer page.free(original);
        const image_path = if (producer_kind == .sidecar and present(original)) try page.dupeZ(u8, function.module_path) else try std.fmt.allocPrintSentinel(page, "{s}/image-{s}.image", .{ dir, &function.key.image_sha256 }, 0);
        defer page.free(image_path);
        if (!present(image_path)) {
            // The worker reads exactly the bytes this session holds for the module.
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
        job.* = .{ .id = self.next_job, .arena = .init(page), .cancel = flag, .function = undefined, .producer_kind = producer_kind, .image_path = undefined, .outdir = undefined, .deadline_ms = std.math.clamp(options.deadline_ms, 100, max_deadline_ms), .started_ms = nowMs(), .owner = options.owner };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        job.function = try function.dupe(a);
        if (toolchain) |native| job.toolchain = .{ .dir = try a.dupe(u8, native.dir), .supervisor = try a.dupeZ(u8, native.supervisor), .worker = try a.dupeZ(u8, native.worker), .sleigh = try a.dupeZ(u8, native.sleigh) };
        if (producer_kind == .sidecar) {
            job.sidecar_socket = try sidecar.socketPath(a);
            job.sidecar_starter = try sidecar.starterPath(a);
        }
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

test "worker pseudo-C is retained with exact token positions and links" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("adapter_fixture.json"), .{});
    const document = try pseudoDocument(a, root);
    try std.testing.expect(std.mem.startsWith(u8, document.signature, "xunknown1 * qx_alloc("));
    try std.testing.expect(std.mem.indexOf(u8, document.text, "malloc") != null);
    try std.testing.expectEqualStrings("ok", document.token_status);
    const parameter = for (document.tokens) |token| {
        if (std.mem.eql(u8, token.text, "param_1") and token.pc == 0x4012e6) break token;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 7), parameter.line);
    try std.testing.expectEqual(@as(u32, 15), parameter.col);
    try std.testing.expectEqual(@as(?u32, 0), parameter.parameter);
}

test "pseudo-C drops disagreeing spans and moves comment PCs to code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"function":{"prototype":{"params":[]}},"pseudocode":{"text":"int f(void)\n  /* Unresolved local var */\n  return 0;\n","token_status":"partial_alignment","tokens":[{"i":0,"line":1,"col":0,"kind":"type","text":"wrong"},{"i":1,"line":1,"col":4,"kind":"funcname","text":"f"},{"i":2,"line":2,"col":2,"kind":"comment","text":"/* Unresolved local var */","pc":"0x1000"},{"i":3,"line":3,"col":2,"kind":"syntax","text":"return"}]}}
    , .{});
    const document = try pseudoDocument(a, root);
    try std.testing.expectEqualStrings("int f(void)", document.signature);
    try std.testing.expectEqual(@as(usize, 3), document.tokens.len);
    try std.testing.expectEqual(@as(?u64, null), document.tokens[1].pc);
    try std.testing.expectEqual(@as(?u64, 0x1000), document.tokens[2].pc);
    try std.testing.expectEqualStrings("return", document.tokens[2].text);
}

test "pseudo-C block comments spanning lines hold no PC, and code after one does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Ghidra's second and later comment lines start with plain text.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"function":{"prototype":{"params":[]}},"pseudocode":{"text":"\n/* note\n   more */\nint f(void)\n{\n  /* Unresolved local var: a\n     Unresolved local var: b */\n  *p = 1; /* kept */\n}\n","token_status":"ok","tokens":[{"i":0,"line":4,"col":4,"kind":"funcname","text":"f"},{"i":1,"line":6,"col":2,"kind":"comment","text":"/* Unresolved local var: a","pc":"0x1000"},{"i":2,"line":7,"col":5,"kind":"comment","text":"Unresolved local var: b */","pc":"0x1000"},{"i":3,"line":8,"col":2,"kind":"op","text":"*"},{"i":4,"line":8,"col":3,"kind":"var","text":"p","pc":"0x1004"}]}}
    , .{});
    const document = try pseudoDocument(a, root);
    try std.testing.expectEqualStrings("int f(void)", document.signature);
    try std.testing.expectEqual(@as(?u64, null), document.tokens[1].pc);
    try std.testing.expectEqual(@as(?u64, null), document.tokens[2].pc);
    try std.testing.expectEqual(@as(?u64, 0x1000), document.tokens[3].pc);
    try std.testing.expectEqual(@as(?u64, 0x1004), document.tokens[4].pc);
}

test "adapter-proven entry pads map to the first exported code line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("adapter_fixture.json"), .{});
    try root.object.getPtr("function").?.object.put(a, "entry", .{ .string = "0x4012dc" });
    const endbr = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"id":"insn:0x4012dc","addr":"0x4012dc","length":4,"admission":"admitted","bytes":"f30f1efa","mnemonic":"ENDBR64","raw_pcode":[],"high_ops":[]}
    , .{});
    try root.object.getPtr("instructions").?.array.insert(0, endbr);
    const document = try pseudoDocument(a, root);
    const pad = document.entry_pad orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 0x4012dc), pad.start);
    try std.testing.expectEqual(@as(u64, 0x4012e0), pad.end);
    const target = for (document.tokens) |token| {
        if (token.index == pad.token) break token;
    } else return error.TestExpectedEqual;
    try std.testing.expectEqual(pad.line, target.line);
    try std.testing.expect(target.pc.? >= pad.end);

    root.object.getPtr("instructions").?.array.items[0].object.getPtr("bytes").?.* = .{ .string = "0f1f4000" };
    try std.testing.expect(adapter.verifiedEntryPad(a, root) == null);
    try std.testing.expect((try pseudoDocument(a, root)).entry_pad == null);
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

test "sidecar variable metadata retains base register, subregister offset and lifetime" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"pseudocode":{"text":"int f(int count)\\n","tokens":[]},"variables":[{"name":"count","type":"int","size":4,"parameter":true,"storage":"register","register":"RDI","register_bit_offset":8,"storage_offset":"0x20","valid_start":"0x1000","valid_end":"0x1010"}]}
    , .{});
    const document = try pseudoDocument(arena.allocator(), root);
    try std.testing.expectEqual(@as(usize, 1), document.variables.len);
    const variable = document.variables[0];
    try std.testing.expectEqualStrings("count", variable.name);
    try std.testing.expectEqualStrings("RDI", variable.register.?);
    try std.testing.expectEqual(@as(u8, 8), variable.register_bit_offset);
    try std.testing.expectEqual(@as(?u64, 0x20), variable.storage_offset);
    try std.testing.expectEqual(@as(?u64, 0x1000), variable.valid_start);
    try std.testing.expectEqual(@as(?u64, 0x1010), variable.valid_end);
}
