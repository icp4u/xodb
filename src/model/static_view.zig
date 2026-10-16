//! Static analysis preparation belongs to the remote session owner.
const std = @import("std");
const Session = @import("session.zig").Session;
const host = @import("../semq/host.zig");
const answer = @import("../semq/answer.zig");
const pseudo_values = @import("pseudo_values.zig");
pub const Mode = enum { decompile, slice, controls };
pub const Phase = enum { functions, questions, answer };
/// A source line carries every line-table row and every function those rows
/// fall in; with more than one function the user chooses, nothing is picked.
pub const Choice = struct { name: []const u8, entry: u64 };
pub const Target = union(enum) { pc: u64, line: struct { path: []const u8, line: u32, addresses: []const u64, functions: []const Choice } };
const max_rows = 64;
const max_functions = 16;
pub const Question = struct { op: u32, input: ?u32, label: []const u8 };
pub const Row = struct { address: ?u64, certainty: []const u8, label: []const u8 };
pub const PseudoSite = struct { path: []const u8, line: u32 };
pub const PseudoToken = struct {
    index: u32,
    line: u32,
    col: u32,
    kind: []const u8,
    text: []const u8,
    op: ?u32 = null,
    link_pc: ?u64 = null,
    pc: ?u64 = null,
    source: ?PseudoSite = null,
    parameter: ?u32 = null,
};
pub const EntryPadMapping = struct {
    start: u64,
    end: u64,
    line: u32,
    token: u32,
};
pub const PseudoValue = pseudo_values.PseudoValue;
const LiveMemory = pseudo_values.LiveMemory;
const livePseudoValue = pseudo_values.value;

fn readSessionMemory(user: *anyopaque, address: u64, bytes: []u8) !usize {
    const session: *Session = @ptrCast(@alignCast(user));
    return session.target.readMemory(address, bytes);
}

/// Apply the sidecar's storage proof to one stopped frame. MCP keeps an
/// identical copy (src/mcp/static_analysis.zig livePseudoValues; the layer
/// rules keep it from importing this file); both end in pseudo_values.collect
/// so a variable cannot gain a different live meaning on a different surface.
pub fn livePseudoValues(a: std.mem.Allocator, session: *Session, analysis: *host.Analysis, tid: i32, frame_index: usize) ![]const PseudoValue {
    if (tid == 0) return &.{};
    const frame_count = std.math.add(usize, frame_index, 1) catch return &.{};
    const frames = session.stack(a, tid, frame_count) catch return &.{};
    if (frame_index >= frames.len) return &.{};
    const frame = frames[frame_index];
    const link_pc = frame.lookup_pc -% analysis.function.bias;
    // Pseudo-C names the physical function's variables. An inlined callee's
    // parameter may share a name and shadow it at depth 0, so match only the
    // concrete subprogram's DWARF, and refuse when inline scopes are unknown.
    if (frame.inline_diagnostic != null) return &.{};
    const locals = session.frameLocalsAtDepth(a, frame, frame.inline_frames.len) catch return &.{};
    // A stack proof includes the call that ends it, and an outer frame's
    // lookup PC is that call on arm64. The callee may have written the slot
    // since, so outer frames read no stack pieces.
    const memory: ?LiveMemory = if (frame_index == 0) .{ .user = session, .read = readSessionMemory } else null;
    return pseudo_values.collect(a, analysis, frame.architecture, frame.registers, frame.cfa, memory, link_pc, locals);
}

const State = struct {
    open: bool = false,
    mode: Mode = .slice,
    phase: Phase = .questions,
    target: Target = .{ .pc = 0 },
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    answer_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    answering: bool = false,
    artifact: [96]u8 = @splat(0),
    artifact_len: usize = 0,
    questions: []Question = &.{},
    rows: []Row = &.{},
    heading: []const u8 = "",
    summary: []const u8 = "",
    parameters: []const u8 = "",
    selected: usize = 0,
    retry: bool = false,
    running: bool = false,
    /// A citation chosen with Return or a click; the workspace browses to it.
    navigate: ?u64 = null,
    /// Increments per computed answer (the input trace reports each once).
    answers: u64 = 0,
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    target_text: [600]u8 = @splat(0),
    path: [512]u8 = @splat(0),
    line_addresses: [max_rows]u64 = @splat(0),
    functions: [max_functions]Choice = undefined,
    function_names: [max_functions][128]u8 = undefined,
    /// The function chosen for a source line (index into the line's functions).
    chosen: ?usize = null,

    pub fn show(self: *State, target: Target) void {
        // Re-opening on the same selection keeps the last answer.
        const same = std.meta.activeTag(target) == std.meta.activeTag(self.target) and switch (target) {
            .pc => |pc| pc == self.target.pc,
            .line => |l| l.line == self.target.line.line and std.mem.eql(u8, l.path, self.target.line.path),
        };
        self.open = true;
        self.navigate = null;
        if (same and self.artifact_len > 0) return;
        _ = self.arena.reset(.retain_capacity);
        self.target = switch (target) {
            .pc => target,
            .line => |l| blk: {
                const n = @min(l.path.len, self.path.len);
                @memcpy(self.path[0..n], l.path[0..n]);
                const rows = @min(l.addresses.len, max_rows);
                @memcpy(self.line_addresses[0..rows], l.addresses[0..rows]);
                const count_functions = @min(l.functions.len, max_functions);
                for (l.functions[0..count_functions], 0..) |f, i| {
                    const m = @min(f.name.len, self.function_names[i].len);
                    @memcpy(self.function_names[i][0..m], f.name[0..m]);
                    self.functions[i] = .{ .name = self.function_names[i][0..m], .entry = f.entry };
                }
                break :blk .{ .line = .{ .path = self.path[0..n], .line = l.line, .addresses = self.line_addresses[0..rows], .functions = self.functions[0..count_functions] } };
            },
        };
        self.artifact_len = 0;
        self.questions = &.{};
        self.rows = &.{};
        self.chosen = if (self.target == .line and self.target.line.functions.len == 1) 0 else null;
        self.phase = if (self.target == .line and self.chosen == null) .functions else .questions;
        self.selected = 0;
        self.retry = false;
        self.message_len = 0;
    }
    fn say(self: *State, text: []const u8) void {
        self.message_len = @min(text.len, self.message.len);
        @memcpy(self.message[0..self.message_len], text[0..self.message_len]);
    }
    fn address(self: *const State) u64 {
        return switch (self.target) {
            .pc => |pc| pc,
            .line => |l| l.functions[self.chosen.?].entry,
        };
    }
    fn print(self: *State, comptime format: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(if (self.answering) self.answer_arena.allocator() else self.arena.allocator(), format, args) catch "";
    }
    fn where(self: *State, ref: ?answer.OpRef) []const u8 {
        const op = ref orelse return "";
        if (op.source) |s| return self.print("{s} @{x}  {s}:{d}", .{ op.opcode, op.address, std.fs.path.basename(s.path), s.line });
        return self.print("{s} @{x}", .{ op.opcode, op.address });
    }
    fn value(self: *State, v: answer.ValueRef) []const u8 {
        if (v.param) |p| return self.print("param {d} ({s})", .{ p, v.register orelse "?" });
        if (std.mem.eql(u8, v.role, "constant")) return self.print("constant 0x{x}", .{v.offset});
        if (v.register) |name| return self.print("{s} {s}", .{ v.role, name });
        return self.print("{s} v{d}", .{ v.role, v.id });
    }

    /// Questions for the selection: each sliceable input (and the output) of
    /// each op cited there, or each op for control dependences. The user picks;
    /// nothing is chosen for them.
    fn build(self: *State, session: *Session, analysis: *host.Analysis) void {
        const a = self.arena.allocator();
        const selector: answer.Selector = switch (self.target) {
            .pc => |pc| .{ .pc = pc },
            .line => |l| .{ .line = .{ .path = l.path, .line = l.line, .addresses = l.addresses } },
        };
        const found = answer.candidates(a, session, analysis, selector, null) catch |err| {
            self.say(@errorName(err));
            return;
        };
        var questions: std.ArrayList(Question) = .empty;
        for (found) |cand| {
            if (questions.items.len >= 256) break;
            const op = cand.op;
            const callee = if (op.call) |name| self.print(" {s}", .{name}) else "";
            if (self.mode == .controls) {
                questions.append(a, .{ .op = op.op, .input = null, .label = self.print("What controls {s}{s} @{x}?", .{ op.opcode, callee, op.address }) }) catch {};
                continue;
            }
            for (cand.inputs) |input| if (input.sliceable and questions.items.len < 256) {
                const arg = if (op.call != null and input.index > 0) self.print(" (argument {d})", .{input.index - 1}) else "";
                questions.append(a, .{ .op = op.op, .input = input.index, .label = self.print("What feeds {s}{s} input {d}{s} @{x}?  {s}", .{ op.opcode, callee, input.index, arg, op.address, self.value(input.value) }) }) catch {};
            };
            if (cand.output) |out| if (questions.items.len < 256) questions.append(a, .{ .op = op.op, .input = null, .label = self.print("What feeds the output of {s}{s} @{x}?  {s}", .{ op.opcode, callee, op.address, self.value(out) }) }) catch {};
        }
        self.questions = questions.items;
        self.selected = @min(self.selected, self.questions.len -| 1);
        if (found.len == 0) {
            if (self.target == .line) {
                // Say why, never "no code": the rows may be inlined code.
                const miss = answer.lineMiss(a, session, analysis, self.target.line.addresses) catch null;
                if (miss) |m| {
                    var text: std.ArrayList(u8) = .empty;
                    text.print(a, "{s}: no exported op is cited at this line's rows", .{m.reason}) catch {};
                    for (m.rows) |row| {
                        text.print(a, "  0x{x}", .{row.address}) catch {};
                        if (row.inlined.len > 0) text.print(a, " (inlined {s})", .{row.inlined[0]}) catch {};
                    }
                    self.say(text.items);
                }
            } else self.say("No op of the analysed graph is cited here (the instruction may have no surviving p-code)");
        }
        const n = @min(analysis.artifact_id.len, self.artifact.len);
        @memcpy(self.artifact[0..n], analysis.artifact_id[0..n]);
        self.artifact_len = n;
    }

    fn run(self: *State, session: *Session) void {
        if (self.selected >= self.questions.len) return;
        const q = self.questions[self.selected];
        _ = self.answer_arena.reset(.retain_capacity);
        self.rows = &.{};
        self.heading = "";
        self.summary = "";
        self.parameters = "";
        self.phase = .questions;
        self.answering = true;
        defer self.answering = false;
        const analysis = session.static_analysis.find(self.artifact[0..self.artifact_len]) orelse {
            self.artifact_len = 0;
            return;
        };
        const a = self.answer_arena.allocator();
        var rows: std.ArrayList(Row) = .empty;
        if (self.mode == .slice) {
            const s = answer.slice(a, session, analysis, q.op, q.input, false, .{}) catch |err| {
                self.say(@errorName(err));
                return;
            };
            self.heading = q.label;
            self.summary = self.print("{s}  data and control  status {s}  limit {s}  exhaustive {s}  memory complete {s}  {d} values", .{ s.trust.result_trust, s.status, s.limit, if (s.exhaustive) "yes" else "no", if (s.memory_complete) "yes" else "no", s.contributions_total });
            var params: std.ArrayList(u8) = .empty;
            for (s.parameters) |p| params.print(a, "param {d} {s}: {s}    ", .{ p.index, p.registers, p.relevance }) catch {};
            self.parameters = params.items;
            for (s.contributions) |row| {
                if (rows.items.len == 512) break;
                const at = row.defined_by orelse row.read_by;
                rows.append(a, .{ .address = if (at) |op| op.address else null, .certainty = row.certainty, .label = self.print("{s}  ({s})  {s}{s}", .{ self.value(row.value), row.step, if (row.defined_by != null) "defined by " else if (row.read_by != null) "read by " else "", self.where(at) }) }) catch {};
            }
            for (s.boundaries) |bd| if (rows.items.len < 512) rows.append(a, .{ .address = if (bd.op) |op| op.address else null, .certainty = bd.certainty, .label = self.print("boundary {s}  {s}", .{ bd.kind, self.where(bd.op) }) }) catch {};
        } else {
            const ctl = answer.controls(a, session, analysis, q.op, .{}) catch |err| {
                self.say(@errorName(err));
                return;
            };
            self.heading = q.label;
            self.summary = self.print("{s}  status {s}  limit {s}  {d} control dependences", .{ ctl.trust.result_trust, ctl.status, ctl.limit, ctl.controls_total });
            self.parameters = "";
            for (ctl.controls) |row| {
                if (rows.items.len == 512) break;
                var feeds: std.ArrayList(u8) = .empty;
                for (row.condition_parameters) |p| if (!std.mem.eql(u8, p.relevance, "irrelevant")) feeds.print(a, " param {d} {s} ({s})", .{ p.index, p.registers, p.relevance }) catch {};
                rows.append(a, .{ .address = row.branch.address, .certainty = row.certainty, .label = self.print("{s} {s}  edge {s} -> block {d}  condition fed by:{s}", .{ row.relation, self.where(row.branch), row.edge, row.controlled_block, if (feeds.items.len > 0) feeds.items else " no parameter" }) }) catch {};
            }
        }
        self.rows = rows.items;
        self.answers += 1;
        self.phase = .answer;
        self.selected = 0;
        self.message_len = 0;
    }
};

pub const Origin = union(enum) {
    pc: u64,
    line: struct { path: [512]u8 = @splat(0), len: usize = 0, line: u32 },
    pub fn source(path: []const u8, line: u32) !Origin {
        if (path.len == 0 or path.len > 512 or line == 0) return error.InvalidSourceLocation;
        var out: Origin = .{ .line = .{ .line = line, .len = path.len } };
        @memcpy(out.line.path[0..path.len], path);
        return out;
    }
};
pub const QuestionRef = struct {
    artifact: [96]u8 = @splat(0),
    len: usize = 0,
    op: u32,
    input: ?u32,
    pub fn from(artifact: []const u8, question: Question) !QuestionRef {
        if (artifact.len > 96) return error.InvalidStaticArtifact;
        var out: QuestionRef = .{ .len = artifact.len, .op = question.op, .input = question.input };
        @memcpy(out.artifact[0..artifact.len], artifact);
        return out;
    }
};
pub fn resolveQuestion(artifact: []const u8, questions: []const Question, question: QuestionRef) !usize {
    if (question.len > question.artifact.len or !std.mem.eql(u8, question.artifact[0..question.len], artifact)) return error.StaleStaticQuestion;
    return for (questions, 0..) |q, i| {
        if (q.op == question.op and q.input == question.input) break i;
    } else error.StaleStaticQuestion;
}
pub const Request = struct {
    origin: Origin,
    mode: Mode = .slice,
    chosen: ?u64 = null,
    question: ?QuestionRef = null,
    retry: u64 = 0,
    tid: i32 = 0,
    frame: usize = 0,
};
pub const View = struct {
    request: Request,
    phase: Phase = .questions,
    target: Target = .{ .pc = 0 },
    artifact: []const u8 = "",
    status: enum { functions, pending, unavailable, failed, ready } = .pending,
    job_id: ?u64 = null,
    title: []const u8 = "Preparing static analysis",
    detail: []const u8 = "",
    qualification: []const u8 = "",
    unreliable: bool = false,
    heading: []const u8 = "",
    summary: []const u8 = "",
    parameters: []const u8 = "",
    observed: []const u8 = "",
    pseudocode: []const u8 = "",
    signature: []const u8 = "",
    pseudo_language: []const u8 = "",
    pseudo_printer: []const u8 = "",
    pseudo_producer: []const u8 = "",
    pseudo_token_status: []const u8 = "",
    pseudo_map_status: []const u8 = "",
    pseudo_qualification: []const u8 = "",
    pseudo_reasons: []const u8 = "",
    pseudo_tokens: []const PseudoToken = &.{},
    pseudo_values: []const PseudoValue = &.{},
    pseudo_entry_pad: ?EntryPadMapping = null,
    pseudo_cut: bool = false,
    /// Runtime bounds of the function a ready view describes.
    function_entry: u64 = 0,
    function_size: u64 = 0,
    message: []const u8 = "",
    questions: []const Question = &.{},
    rows: []const Row = &.{},
    answers: u64 = 0,
};
comptime {
    @import("debugger_view.zig").requireImmutable(View);
}
pub fn cancel(session: *Session, actor: @import("session.zig").Actor, id: u64) !void {
    const job = session.static_analysis.job orelse return error.NoStaticAnalysisJob;
    if (job.id != id) return error.StaleStaticAnalysisJob;
    if (!host.mayCancel(job.owner, if (actor == .human) .human else .{ .agent = .{ .client = session.agent_client_id, .controller = session.agent_controller } })) return error.JobNotOwned;
    job.requestCancel();
}
pub const Capture = struct {
    state: State = .{},
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    value: ?View = null,
    session: u64 = 0,
    image: u64 = 0,
    generation: u64 = 0,
    metadata: u64 = 0,
    retry: u64 = 0,
    refreshed_ns: u64 = 0,
    answers: u64 = 0,
    pub fn deinit(self: *Capture) void {
        self.state.arena.deinit();
        self.state.answer_arena.deinit();
        self.arena.deinit();
    }
    pub fn changed(self: *const Capture, session: *const Session) bool {
        const old = self.value orelse return false;
        if (self.session != session.id or self.generation != session.target.snapshot().generation or self.metadata != session.metadata.revision) return true;
        if (old.status == .pending) {
            if (session.static_analysis.job) |job| if (old.job_id != job.id or !job.running()) return true;
            return @import("../target/linux.zig").now() -| self.refreshed_ns >= 100 * std.time.ns_per_ms;
        }
        return false;
    }
    pub fn refresh(self: *Capture, session: *Session, wanted: ?Request) void {
        const request = wanted orelse {
            self.value = null;
            _ = self.arena.reset(.free_all);
            self.state.arena.deinit();
            self.state.answer_arena.deinit();
            self.state = .{ .answers = self.answers };
            return;
        };
        if (self.value) |old| if (std.meta.eql(old.request, request) and !self.changed(session)) return;
        const state = session.target.snapshot();
        const replaced = self.session != session.id or self.image != state.image_epoch;
        self.session = session.id;
        self.image = state.image_epoch;
        self.generation = state.generation;
        self.metadata = session.metadata.revision;
        self.refreshed_ns = @import("../target/linux.zig").now();
        const old = self.value;
        const new_target = replaced or old == null or !std.meta.eql(old.?.request.origin, request.origin);
        const new_mode = old == null or old.?.request.mode != request.mode;
        _ = self.arena.reset(.retain_capacity);
        self.value = .{ .request = request };
        self.prepare(session, request, new_target, new_mode) catch |err| {
            self.value.?.status = .failed;
            self.value.?.title = if ((err == error.NoCodeAtSourceLine or err == error.NoCodeForSourceLine) and session.modules.skipped().count != 0)
                "No code in the images searched; some are over the image budget (Modules lists them)"
            else
                @errorName(err);
            self.value.?.detail = if (err == error.FunctionTooLarge)
                "The function is over the 1 MiB analysis limit"
            else
                "Static analysis needs function bounds from the session's symbols (ELF or DWARF)";
        };
        self.answers = self.state.answers;
        self.value.?.answers = self.answers;
    }
    fn prepare(self: *Capture, session: *Session, request: Request, new_target: bool, new_mode: bool) !void {
        const a = self.arena.allocator();
        var view = &self.value.?;
        const state = &self.state;
        if (new_target) {
            state.arena.deinit();
            state.answer_arena.deinit();
            state.* = .{ .answers = self.answers };
            const target: Target = switch (request.origin) {
                .pc => |pc| .{ .pc = pc },
                .line => |line| blk: {
                    if (line.len == 0 or line.len > line.path.len or line.line == 0) return error.InvalidSourceLocation;
                    const path = line.path[0..line.len];
                    const addresses = try session.sourceAddresses(a, path, line.line);
                    if (addresses.len == 0) return error.NoCodeAtSourceLine;
                    var functions: std.ArrayList(Choice) = .empty;
                    for (addresses) |address| {
                        const f = session.static_analysis.resolve(a, session, address) catch continue;
                        const entry = f.runtime(f.key.entry);
                        for (functions.items) |known| {
                            if (known.entry == entry) break;
                        } else if (functions.items.len < max_functions) try functions.append(a, .{ .name = f.name, .entry = entry });
                    }
                    if (functions.items.len == 0) return error.NoSourceFunctionBounds;
                    break :blk .{ .line = .{ .path = path, .line = line.line, .addresses = addresses, .functions = functions.items } };
                },
            };
            state.show(target);
        }
        view.target = state.target;
        state.mode = request.mode;
        if (new_mode) {
            state.artifact_len = 0;
            state.phase = .questions;
        }
        if (state.target == .line) {
            if (request.chosen == null and state.target.line.functions.len > 1) state.chosen = null;
            if (request.chosen) |entry| {
                const chosen: usize = for (state.target.line.functions, 0..) |f, i| {
                    if (f.entry == entry) break i;
                } else return error.StaleStaticFunction;
                if (state.chosen != chosen) {
                    state.artifact_len = 0;
                    state.phase = .questions;
                }
                state.chosen = chosen;
            }
            if (state.chosen == null) {
                state.phase = .functions;
                view.status = .functions;
                view.phase = .functions;
                const line = state.target.line;
                view.title = try std.fmt.allocPrint(a, "{s}:{d} has code in {d} functions: choose one (Up/Down, Return); nothing is chosen for you", .{ std.fs.path.basename(line.path), line.line, line.functions.len });
                return;
            }
            view.request.chosen = state.target.line.functions[state.chosen.?].entry;
        }
        const status = try session.static_analysis.request(a, session, state.address(), .{ .retry = request.retry != self.retry });
        self.retry = request.retry;
        switch (status) {
            .unavailable => |why| {
                view.status = .unavailable;
                view.title = try std.fmt.allocPrint(a, "Static analysis unavailable: {s}", .{why.reason});
                view.detail = why.detail;
            },
            .running => |job| {
                view.status = .pending;
                view.job_id = job.id;
                // Stage and elapsed time lead: the pane is narrow and cuts the tail.
                const elapsed = job.elapsedMs();
                view.title = try std.fmt.allocPrint(a, "{s} {d}.{d} s of {d} s: {s} (0x{x}, {d} bytes)", .{ job.progress(), elapsed / 1000, elapsed % 1000 / 100, job.deadline_ms / 1000, job.function.name, job.function.runtime(job.function.key.entry), job.function.key.size });
                view.detail = if (job.producer_kind == .sidecar) "Persistent Ghidra JVM sidecar; the debugger stays usable and X cancels this request" else "The native worker is a separate process tree, never the target; X cancels it";
            },
            .failed => |job| {
                view.status = .failed;
                view.job_id = job.id;
                const f = job.failure.?;
                view.title = try std.fmt.allocPrint(a, "Analysis of {s} {s}: {s}", .{ job.function.name, if (std.mem.eql(u8, f.code, "cancelled")) "cancelled" else "failed", f.code });
                view.detail = f.detail;
            },
            .ready => |analysis| {
                view.status = .ready;
                var reasons: std.ArrayList(u8) = .empty;
                for (analysis.reasons) |reason| try reasons.print(a, "{s} ", .{reason.code});
                view.unreliable = std.mem.eql(u8, analysis.level, "unreliable");
                view.qualification = try std.fmt.allocPrint(a, "result_trust graph_{s}   verified_semantics no   qualification {s}: {s}", .{ analysis.level, analysis.level, reasons.items });
                view.detail = try std.fmt.allocPrint(a, "{s}  0x{x}+{d}  ({s})   artifact {s}   image sha256 {s}", .{ analysis.function.name, analysis.function.runtime(analysis.function.key.entry), analysis.function.key.size, analysis.function.bounds_source, analysis.artifact_id, analysis.function.key.image_sha256[0..16] });
                view.artifact = analysis.artifact_id;
                view.function_entry = analysis.function.runtime(analysis.function.key.entry);
                view.function_size = analysis.function.key.size;
                if (request.mode == .decompile) {
                    const document = analysis.pseudocode;
                    const text_len = @min(document.text.len, 2 << 20);
                    const token_count = @min(document.tokens.len, 32 * 1024);
                    const tokens = try a.alloc(PseudoToken, token_count);
                    for (document.tokens[0..token_count], tokens) |token, *out| {
                        const pc = if (token.pc) |link| analysis.function.runtime(link) else null;
                        const source: ?PseudoSite = if (pc) |runtime| if (session.sourceAt(a, runtime) catch null) |site| .{ .path = site.path, .line = site.line } else null else null;
                        out.* = .{ .index = token.index, .line = token.line, .col = token.col, .kind = token.kind, .text = token.text, .op = token.op, .link_pc = token.pc, .pc = pc, .source = source, .parameter = token.parameter };
                    }
                    view.title = try std.fmt.allocPrint(a, "Pseudo-C for {s}", .{analysis.function.name});
                    view.pseudocode = document.text[0..text_len];
                    view.signature = document.signature;
                    view.pseudo_language = document.language;
                    view.pseudo_printer = document.printer;
                    view.pseudo_producer = try std.fmt.allocPrint(a, "{s} {s}", .{ analysis.producer_name, analysis.producer_version });
                    view.pseudo_token_status = document.token_status;
                    view.pseudo_map_status = document.address_map_status;
                    if (analysis.graph_failure) |failure| {
                        view.pseudo_qualification = try std.fmt.allocPrint(a, "{s}   graph unavailable: {s}", .{ view.pseudo_producer, failure.code });
                        view.pseudo_reasons = try std.fmt.allocPrint(a, "{s}: {s}", .{ failure.code, failure.detail });
                    } else {
                        view.pseudo_qualification = try std.fmt.allocPrint(a, "{s}   qualification {s} / result_trust graph_{s}", .{ view.pseudo_producer, analysis.level, analysis.level });
                        view.pseudo_reasons = try std.fmt.allocPrint(a, "reasons {s}", .{reasons.items});
                    }
                    view.pseudo_tokens = tokens;
                    view.pseudo_values = try livePseudoValues(a, session, analysis, request.tid, request.frame);
                    if (document.entry_pad) |pad| view.pseudo_entry_pad = .{
                        .start = analysis.function.runtime(pad.start),
                        .end = analysis.function.runtime(pad.end),
                        .line = pad.line,
                        .token = pad.token,
                    };
                    view.pseudo_cut = text_len != document.text.len or token_count != document.tokens.len;
                    view.phase = .questions;
                    return;
                }
                if (!analysis.graph_available) {
                    const failure = analysis.graph_failure.?;
                    view.status = .unavailable;
                    view.title = try std.fmt.allocPrint(a, "Static graph unavailable for {s}: {s}", .{ analysis.function.name, failure.code });
                    view.detail = failure.detail;
                    return;
                }
                if (state.artifact_len == 0 or !std.mem.eql(u8, state.artifact[0..state.artifact_len], analysis.artifact_id)) {
                    _ = state.arena.reset(.retain_capacity);
                    state.phase = .questions;
                    state.questions = &.{};
                    state.rows = &.{};
                    state.heading = "";
                    state.summary = "";
                    state.parameters = "";
                    _ = state.answer_arena.reset(.free_all);
                    state.build(session, analysis);
                }
                if (request.question) |question| {
                    const index = try resolveQuestion(analysis.artifact_id, state.questions, question);
                    if (state.phase != .answer or state.selected != index) {
                        state.selected = index;
                        state.run(session);
                        state.selected = index;
                    }
                } else state.phase = .questions;
                view.title = switch (state.target) {
                    .pc => |pc| try std.fmt.allocPrint(a, "Instruction 0x{x}: choose a question (Up/Down, Return)", .{pc}),
                    .line => |line| try std.fmt.allocPrint(a, "{s}:{d}: choose a question (Up/Down, Return)", .{ std.fs.path.basename(line.path), line.line }),
                };
                if (state.phase == .answer and state.mode == .slice and request.tid != 0) {
                    if (answer.observed(a, session, analysis, request.tid, request.frame) catch null) |seen| {
                        var observed: std.ArrayList(u8) = .empty;
                        try observed.print(a, "OBSERVED NOW (tid {d} frame {d}, generation {d}; not part of the static answer):", .{ seen.tid, seen.frame, seen.generation });
                        for (seen.parameters) |p| try observed.print(a, "  {s} = {s}", .{ p.name, p.value });
                        view.observed = observed.items;
                    }
                }
                view.artifact = state.artifact[0..state.artifact_len];
                view.phase = state.phase;
                view.questions = state.questions;
                view.rows = state.rows;
                view.heading = state.heading;
                view.summary = state.summary;
                view.parameters = state.parameters;
                view.message = state.message[0..state.message_len];
                view.answers = state.answers;
                if (view.message.len == 0 and (view.questions.len >= 256 or view.rows.len >= 512)) view.message = "Visible analysis is capped at 256 questions and 512 answer rows";
            },
        }
    }
};

test "static question identity survives paging but never another artifact" {
    const questions = [_]Question{ .{ .op = 7, .input = 1, .label = "input" }, .{ .op = 7, .input = null, .label = "output" } };
    var selected = try QuestionRef.from("artifact-one", questions[1]);
    try std.testing.expectEqual(@as(usize, 1), try resolveQuestion("artifact-one", &questions, selected));
    try std.testing.expectError(error.StaleStaticQuestion, resolveQuestion("artifact-two", &questions, selected));
    selected.input = 2;
    try std.testing.expectError(error.StaleStaticQuestion, resolveQuestion("artifact-one", &questions, selected));
    selected.len = selected.artifact.len + 1;
    try std.testing.expectError(error.StaleStaticQuestion, resolveQuestion("artifact-one", &questions, selected));
}

test "static publications retain questions and answers after owner arenas retire" {
    const boundary = @import("remote_owner.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    const a = arena.allocator();
    const label = try a.dupe(u8, "What feeds this value?");
    const questions = try a.alloc(Question, 1);
    questions[0] = .{ .op = 7, .input = 1, .label = label };
    const rows = try a.alloc(Row, 1);
    rows[0] = .{ .address = 0x1000, .certainty = "direct", .label = try a.dupe(u8, "param 0 (DI)") };
    const pseudo = try a.alloc(PseudoToken, 1);
    pseudo[0] = .{ .index = 4, .line = 7, .col = 2, .kind = try a.dupe(u8, "variable"), .text = try a.dupe(u8, "count"), .pc = 0x1000, .source = .{ .path = try a.dupe(u8, "/owned/qx.c"), .line = 14 } };
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 42, .start_ticks = 1, .image_epoch = 0, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .static_analysis = .{ .request = .{ .origin = .{ .pc = 0x1000 } }, .phase = .answer, .status = .ready, .questions = questions, .rows = rows, .heading = label, .pseudocode = try a.dupe(u8, "count += 1;"), .pseudo_tokens = pseudo },
    });
    defer publication.destroy();
    @memset(label, 'x');
    rows[0].address = 0;
    pseudo[0].pc = 0;
    arena.deinit();
    const view = publication.value.static_analysis.?;
    try std.testing.expectEqualStrings("What feeds this value?", view.questions[0].label);
    try std.testing.expectEqualStrings("param 0 (DI)", view.rows[0].label);
    try std.testing.expectEqual(@as(?u64, 0x1000), view.rows[0].address);
    try std.testing.expectEqualStrings("count += 1;", view.pseudocode);
    try std.testing.expectEqual(@as(?u64, 0x1000), view.pseudo_tokens[0].pc);
    try std.testing.expectEqualStrings("/owned/qx.c", view.pseudo_tokens[0].source.?.path);
}

test "pseudo-C live values use base registers, subregister offsets and PC bounds" {
    const loc = @import("../debug/location.zig");
    const Arch = @import("../target/arch.zig").Arch;
    var registers: loc.RegisterSet = @splat(null);
    registers[Arch.x86_64.registerNumber("rdi").?] = 0x1234_5678_9abc_def0;
    registers[Arch.x86_64.registerNumber("rax").?] = 0x0000_0000_0000_0100;
    const rdi_proof: pseudo_values.DwarfLocation = .{ .size = 4, .place = .{ .kind = .register, .bits = registers[Arch.x86_64.registerNumber("rdi").?].?, .register = @intCast(Arch.x86_64.registerNumber("rdi").?) } };
    const value = (try livePseudoValue(std.testing.allocator, .x86_64, registers, null, null, 0x1010, .{
        .name = "count",
        .type_name = "unsigned int",
        .size = 4,
        .parameter = true,
        .storage = "register",
        .register = "RDI",
        .register_bit_offset = 0,
        .storage_offset = 0,
        .valid_start = 0x1000,
        .valid_end = 0x1020,
    }, rdi_proof)).?;
    defer std.testing.allocator.free(value.display);
    try std.testing.expectEqualStrings("count", value.name);
    try std.testing.expectEqualStrings("0x9abcdef0", value.display);
    const flag_piece = [_]loc.Piece{.{ .kind = .register, .bits = registers[Arch.x86_64.registerNumber("rax").?].?, .register = @intCast(Arch.x86_64.registerNumber("rax").?), .bit_size = 8, .value_bit_offset = 0, .source_bit_offset = 8, .available = true }};
    const flag = (try livePseudoValue(std.testing.allocator, .x86_64, registers, null, null, 0x1010, .{
        .name = "flag",
        .type_name = "bool",
        .size = 1,
        .parameter = false,
        .storage = "register",
        .register = "RAX",
        .register_bit_offset = 8,
        .storage_offset = 0,
        .valid_start = 0x1010,
        .valid_end = 0x1011,
    }, .{ .size = 1, .place = .{ .kind = .value, .bits = 1, .pieces = &flag_piece } })).?;
    try std.testing.expectEqualStrings("true", flag.display);
    try std.testing.expect((try livePseudoValue(std.testing.allocator, .x86_64, registers, null, null, 0x1020, .{
        .name = "count",
        .type_name = "unsigned int",
        .size = 4,
        .parameter = true,
        .storage = "register",
        .register = "RDI",
        .register_bit_offset = 0,
        .storage_offset = 0,
        .valid_start = 0x1000,
        .valid_end = 0x1020,
    }, rdi_proof)) == null);
}

test "pseudo-C live values read stack pieces and assemble proven split pieces" {
    const loc = @import("../debug/location.zig");
    const Arch = @import("../target/arch.zig").Arch;
    const Memory = struct {
        fn read(_: *anyopaque, address: u64, bytes: []u8) !usize {
            if (address != 0x7ffc or bytes.len != 4) return error.UnexpectedRead;
            @memcpy(bytes, &[_]u8{ 0x78, 0x56, 0x34, 0x12 });
            return bytes.len;
        }
    };
    var context: u8 = 0;
    var registers: loc.RegisterSet = @splat(null);
    registers[Arch.x86_64.registerNumber("rdi").?] = 0xabcd;
    const pieces = [_]host.PseudoPiece{
        .{ .storage = "register", .size = 2, .value_bit_offset = 0, .register = "RDI" },
        .{ .storage = "stack", .size = 4, .value_bit_offset = 16, .cfa_offset = -4 },
    };
    const stack = [_]host.PseudoPiece{.{ .storage = "stack", .size = 4, .value_bit_offset = 0, .cfa_offset = -4 }};
    const split_proof_pieces = [_]loc.Piece{
        .{ .kind = .register, .bits = registers[Arch.x86_64.registerNumber("rdi").?].?, .register = @intCast(Arch.x86_64.registerNumber("rdi").?), .bit_size = 16, .value_bit_offset = 0, .available = true },
        .{ .kind = .address, .bits = 0x7ffc, .bit_size = 32, .value_bit_offset = 16, .available = true },
    };
    const seventh = (try livePseudoValue(std.testing.allocator, .x86_64, registers, 0x8000, .{ .user = &context, .read = Memory.read }, 0x1010, .{
        .name = "seventh",
        .type_name = "int",
        .size = 4,
        .parameter = true,
        .storage = "stack",
        .register = null,
        .register_bit_offset = 0,
        .storage_offset = null,
        .valid_start = 0x1000,
        .valid_end = 0x1020,
        .pieces = &stack,
    }, .{ .size = 4, .place = .{ .kind = .address, .bits = 0x7ffc } })).?;
    defer std.testing.allocator.free(seventh.display);
    try std.testing.expectEqualStrings("0x12345678", seventh.display);
    const split = (try livePseudoValue(std.testing.allocator, .x86_64, registers, 0x8000, .{ .user = &context, .read = Memory.read }, 0x1010, .{
        .name = "split",
        .type_name = "owned6",
        .size = 6,
        .parameter = true,
        .storage = "split",
        .register = null,
        .register_bit_offset = 0,
        .storage_offset = null,
        .valid_start = 0x1000,
        .valid_end = 0x1020,
        .pieces = &pieces,
    }, .{ .size = 6, .place = .{ .kind = .value, .bits = 0, .pieces = &split_proof_pieces } })).?;
    defer std.testing.allocator.free(split.display);
    try std.testing.expectEqualStrings("0x12345678abcd", split.display);
}
