//! Static analysis preparation belongs to the remote session owner.
const std = @import("std");
const Session = @import("session.zig").Session;
const host = @import("../semq/host.zig");
const answer = @import("../semq/answer.zig");
pub const Mode = enum { slice, controls };
pub const Phase = enum { functions, questions, answer };
/// A source line carries every line-table row and every function those rows
/// fall in; with more than one function the user chooses, nothing is picked.
pub const Choice = struct { name: []const u8, entry: u64 };
pub const Target = union(enum) { pc: u64, line: struct { path: []const u8, line: u32, addresses: []const u64, functions: []const Choice } };
const max_rows = 64;
const max_functions = 16;
pub const Question = struct { op: u32, input: ?u32, label: []const u8 };
pub const Row = struct { address: ?u64, certainty: []const u8, label: []const u8 };

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
            self.value.?.detail = "Static analysis needs function bounds from the session's symbols (ELF or DWARF)";
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
                view.title = try std.fmt.allocPrint(a, "Analysing {s} (0x{x}, {d} bytes) with the supervised Ghidra worker: {d} ms of {d} ms", .{ job.function.name, job.function.runtime(job.function.key.entry), job.function.key.size, job.elapsedMs(), job.deadline_ms });
                view.detail = "The worker is a separate process tree, never the target; X cancels it";
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
                var reasons: std.ArrayList(u8) = .empty;
                for (analysis.reasons) |reason| try reasons.print(a, "{s} ", .{reason.code});
                view.unreliable = std.mem.eql(u8, analysis.level, "unreliable");
                view.qualification = try std.fmt.allocPrint(a, "result_trust graph_{s}   verified_semantics no   qualification {s}: {s}", .{ analysis.level, analysis.level, reasons.items });
                view.detail = try std.fmt.allocPrint(a, "{s}  0x{x}+{d}  ({s})   artifact {s}   image sha256 {s}", .{ analysis.function.name, analysis.function.runtime(analysis.function.key.entry), analysis.function.key.size, analysis.function.bounds_source, analysis.artifact_id, analysis.function.key.image_sha256[0..16] });
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
    const publication = try boundary.Publication.create(std.testing.allocator, .{
        .stamp = .{ .connection = 1, .session = 1, .process = 1, .pid = 42, .start_ticks = 1, .image_epoch = 0, .generation = 1 },
        .revision = 1,
        .taken_ns = 1,
        .status = .ready,
        .static_analysis = .{ .request = .{ .origin = .{ .pc = 0x1000 } }, .phase = .answer, .status = .ready, .questions = questions, .rows = rows, .heading = label },
    });
    defer publication.destroy();
    @memset(label, 'x');
    rows[0].address = 0;
    arena.deinit();
    const view = publication.value.static_analysis.?;
    try std.testing.expectEqualStrings("What feeds this value?", view.questions[0].label);
    try std.testing.expectEqualStrings("param 0 (DI)", view.rows[0].label);
    try std.testing.expectEqual(@as(?u64, 0x1000), view.rows[0].address);
}
