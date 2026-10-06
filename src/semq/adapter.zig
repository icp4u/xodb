//! In-process port of scripts/semq/c01_to_xsg.py (adapter 0.3.0) for the
//! debugger host: one `xodb.ghidra.function_graph` 0.4.x export becomes xsg v1
//! text, byte for byte what the Python adapter writes without `--elf`. The
//! mapping decisions are documented in docs/SEMANTIC_QUERIES.md; a refusal
//! there is a refusal here, with the same message text where it matters.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
pub const version = "0.3.0";

pub const Result = union(enum) { xsg: []u8, refused: []const u8 };

const aliases = [_][2][]const u8{
    .{ "BUILD", "MULTIEQUAL" },          .{ "DELAY_SLOT", "INDIRECT" },          .{ "LABEL", "PTRADD" },
    .{ "CROSSBUILD", "PTRSUB" },         .{ "INT2FLOAT", "FLOAT_INT2FLOAT" },    .{ "FLOAT2FLOAT", "FLOAT_FLOAT2FLOAT" },
    .{ "TRUNC", "FLOAT_TRUNC" },         .{ "CEIL", "FLOAT_CEIL" },              .{ "FLOOR", "FLOAT_FLOOR" },
    .{ "ROUND", "FLOAT_ROUND" },
};
const space_classes = [_][2][]const u8{
    .{ "constant", "constant" }, .{ "internal", "unique" }, .{ "spacebase", "stack" },
    .{ "join", "join" },         .{ "fspec", "other" },     .{ "iop", "other" },
};

const Converter = struct {
    a: Allocator,
    why: []const u8 = "",
    fn refuse(self: *Converter, comptime format: []const u8, args: anytype) error{Refused} {
        self.why = std.fmt.allocPrint(self.a, format, args) catch "adapter refusal (message unavailable)";
        return error.Refused;
    }
    fn get(self: *Converter, object: Value, key: []const u8) !Value {
        if (object != .object) return self.refuse("TypeError: expected an object for {s}", .{key});
        return object.object.get(key) orelse self.refuse("KeyError: '{s}'", .{key});
    }
    fn opt(object: Value, key: []const u8) ?Value {
        if (object != .object) return null;
        const v = object.object.get(key) orelse return null;
        return if (v == .null) null else v;
    }
    fn str(self: *Converter, object: Value, key: []const u8) ![]const u8 {
        const v = try self.get(object, key);
        return if (v == .string) v.string else self.refuse("TypeError: {s} is not a string", .{key});
    }
    fn array(self: *Converter, object: Value, key: []const u8) ![]Value {
        const v = try self.get(object, key);
        return if (v == .array) v.array.items else self.refuse("TypeError: {s} is not a list", .{key});
    }
    fn hex(self: *Converter, v: Value, what: []const u8) !u64 {
        if (v != .string or !std.mem.startsWith(u8, v.string, "0x")) return self.refuse("{s}: expected canonical hex string", .{what});
        return std.fmt.parseInt(u64, v.string[2..], 16) catch self.refuse("{s}: bad or >64-bit hex {s}", .{ what, v.string });
    }
    fn num(self: *Converter, v: Value, prefix: []const u8) !u32 {
        if (v != .string or !std.mem.startsWith(u8, v.string, prefix)) return self.refuse("bad id (want {s}<n>)", .{prefix});
        const text = v.string[prefix.len..];
        if (text.len == 0) return self.refuse("bad id {s}", .{v.string});
        for (text) |ch| if (!std.ascii.isDigit(ch)) return self.refuse("bad id {s}", .{v.string});
        const n = std.fmt.parseInt(u64, text, 10) catch return self.refuse("bad id {s}", .{v.string});
        if (n >= 0xffffffff) return self.refuse("bad id {s}", .{v.string});
        return @intCast(n);
    }
    fn int(self: *Converter, v: Value, what: []const u8) !i64 {
        return if (v == .integer) v.integer else self.refuse("TypeError: {s} is not an integer", .{what});
    }
};

/// Python's str() of a JSON scalar, as the adapter's `%s` comments print it.
fn pyStr(a: Allocator, v: ?Value) ![]const u8 {
    const value = v orelse return "None";
    return switch (value) {
        .null => "None",
        .bool => |b| if (b) "True" else "False",
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
        else => "?",
    };
}

/// Printable ASCII except `"\#=`; every other code point becomes one `_`.
fn token(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch & 0xc0 == 0x80) continue; // UTF-8 continuation: one code point, one '_'
        const keep = ch >= 0x21 and ch <= 0x7e and std.mem.indexOfScalar(u8, "\"\\#=", ch) == null;
        try out.append(a, if (keep) ch else '_');
    }
    if (out.items.len == 0) try out.append(a, '_');
    return out.items;
}

fn truthy(v: ?Value) bool {
    const value = v orelse return false;
    return switch (value) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .string => |s| s.len > 0,
        .array => |l| l.items.len > 0,
        .object => |o| o.count() > 0,
        else => true,
    };
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn flagSet(v: Value) []const Value {
    if (v != .object) return &.{};
    const flags = v.object.get("flags") orelse return &.{};
    return if (flags == .array) flags.array.items else &.{};
}
fn hasFlag(v: Value, name: []const u8) bool {
    for (flagSet(v)) |f| if (f == .string and std.mem.eql(u8, f.string, name)) return true;
    return false;
}

/// Converts one export; the input SHA-256 (hex) goes into the `source` line.
/// Every allocation comes from `a` (an arena); a refusal carries its reason.
pub fn convert(a: Allocator, doc: Value, source_sha256: []const u8) !Result {
    var k = Converter{ .a = a };
    const text = run(&k, doc, source_sha256) catch |err| switch (err) {
        error.Refused => return .{ .refused = k.why },
        else => return err,
    };
    return .{ .xsg = text };
}

fn run(k: *Converter, doc: Value, source_sha256: []const u8) ![]u8 {
    const a = k.a;
    const schema = Converter.opt(doc, "schema");
    if (schema == null or schema.? != .string or !std.mem.eql(u8, schema.?.string, "xodb.ghidra.function_graph")) return k.refuse("not an xodb.ghidra.function_graph export", .{});
    const schema_version = try pyStr(a, Converter.opt(doc, "schema_version") orelse Value{ .string = "" });
    if (!std.mem.startsWith(u8, schema_version, "0.4.")) return k.refuse("unsupported schema_version {s} (adapter reads 0.4.x only)", .{schema_version});
    const status = Converter.opt(doc, "status");
    if (status == null or status.? != .string or !std.mem.eql(u8, status.?.string, "ok")) return k.refuse("export status is not ok", .{});
    const image = try k.get(doc, "image");
    const lang = try k.get(doc, "language");
    const func = try k.get(doc, "function");
    const high = try k.get(doc, "high_pcode");
    const kind = Converter.opt(high, "kind");
    if (kind == null or kind.? != .string or !std.mem.eql(u8, kind.?.string, "decompiler_final_ssa")) return k.refuse("high_pcode.kind is not decompiler_final_ssa", .{});
    var notes: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    const producer = try k.get(doc, "producer");
    const artifact = Converter.opt(doc, "artifact_id");
    try out.append(a, "xsg 1");
    try out.append(a, try std.fmt.allocPrint(a, "# adapter c01_to_xsg {s} from {s} {s} artifact {s}", .{ version, try pyStr(a, schema), schema_version, try pyStr(a, artifact) }));
    try out.append(a, try std.fmt.allocPrint(a, "# producer {s} {s} ghidra {s} java={s}", .{ try pyStr(a, Converter.opt(producer, "kind")), try pyStr(a, Converter.opt(producer, "worker_version")), try pyStr(a, Converter.opt(producer, "ghidra_commit")), try pyStr(a, if (producer == .object) producer.object.get("java") else null) }));
    const path = if (Converter.opt(image, "path")) |p| (if (p == .string and p.string.len > 0) p.string else "unknown") else "unknown";
    const build_id = if (Converter.opt(image, "gnu_build_id")) |b| (if (b == .string and b.string.len > 0) b.string else "unknown") else "unknown";
    try out.append(a, try std.fmt.allocPrint(a, "image sha256={s} build_id={s} name={s}", .{ try token(a, try k.str(image, "sha256")), try token(a, build_id), try token(a, std.fs.path.basename(path)) }));

    const Space = struct { name: []const u8, index: i64, cls: []const u8 };
    var spaces: std.ArrayList(Space) = .empty;
    var ram_bytes: i64 = 0;
    for (try k.array(doc, "address_spaces")) |s| {
        const space_type = try k.str(s, "type");
        var cls: ?[]const u8 = null;
        for (space_classes) |pair| if (std.mem.eql(u8, pair[0], space_type)) {
            cls = pair[1];
        };
        if (std.mem.eql(u8, space_type, "processor")) {
            const name = try k.str(s, "name");
            cls = if (std.mem.eql(u8, name, "ram")) "ram" else if (std.mem.eql(u8, name, "register")) "register" else "other";
            if (truthy(Converter.opt(s, "default_code"))) ram_bytes = try k.int(try k.get(s, "addr_size"), "addr_size");
        }
        const chosen = cls orelse return k.refuse("unknown address space type {s}", .{space_type});
        const entry = Space{ .name = try k.str(s, "name"), .index = try k.int(try k.get(s, "index"), "index"), .cls = chosen };
        for (spaces.items) |*existing| {
            if (!std.mem.eql(u8, existing.name, entry.name)) continue;
            existing.* = entry;
            break;
        } else try spaces.append(a, entry);
    }
    if (ram_bytes == 0) return k.refuse("no default code space", .{});
    try out.append(a, try std.fmt.allocPrint(a, "spec language={s} compiler={s} addr_bytes={d}", .{ try token(a, try k.str(lang, "id")), try token(a, try k.str(lang, "compiler_spec")), ram_bytes }));
    try out.append(a, "producer xsq-c01-adapter " ++ version);
    try out.append(a, try std.fmt.allocPrint(a, "source kind=c01-function-graph-{s} sha256={s}", .{ try token(a, schema_version), source_sha256 }));
    const artifact_token = try token(a, if (artifact) |v| (if (v == .string and v.string.len > 0) v.string else "unknown") else "unknown");
    if (Converter.opt(doc, "qualification")) |q| {
        var codes: std.ArrayList([]const u8) = .empty;
        if (Converter.opt(q, "reasons")) |reasons| if (reasons == .array) for (reasons.array.items) |r| {
            const code = try k.str(r, "code");
            if (!contains(codes.items, code)) try codes.append(a, code);
        };
        std.mem.sort([]const u8, codes.items, {}, struct {
            fn less(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.order(u8, l, r) == .lt;
            }
        }.less);
        var line = try std.fmt.allocPrint(a, "qualification level={s}", .{try token(a, try k.str(q, "level"))});
        if (codes.items.len > 0) line = try std.fmt.allocPrint(a, "{s} reasons={s}", .{ line, try token(a, try std.mem.join(a, ",", codes.items)) });
        try out.append(a, try std.fmt.allocPrint(a, "{s} artifact={s}", .{ line, artifact_token }));
    } else try out.append(a, try std.fmt.allocPrint(a, "qualification level=unknown artifact={s}", .{artifact_token}));
    std.mem.sort(Space, spaces.items, {}, struct {
        fn less(_: void, l: Space, r: Space) bool {
            return l.index < r.index;
        }
    }.less);
    for (spaces.items) |s| try out.append(a, try std.fmt.allocPrint(a, "space {d} {s} {s}", .{ s.index, try token(a, s.name), s.cls }));
    if (image == .object) if (image.object.get("load_segments")) |segments| if (segments != .null) {
        if (segments != .array) return k.refuse("TypeError: load_segments is not a list", .{});
        for (segments.array.items) |seg| {
            const low = try k.hex(try k.get(seg, "vaddr"), "segment");
            const size = try k.hex(try k.get(seg, "memsz"), "segment");
            if (std.mem.indexOfScalar(u8, try k.str(seg, "flags"), 'w') == null and size != 0)
                try out.append(a, try std.fmt.allocPrint(a, "readonly 0x{x} 0x{x}", .{ low, low +% size }));
        }
        try notes.append(a, "readonly ranges from the export's non-writable PT_LOAD segments");
    };

    const entry = try k.hex(try k.get(func, "entry"), "function.entry");
    const blocks = try k.array(doc, "blocks");
    for (blocks) |b| {
        if (try k.hex(try k.get(b, "start"), "block") == entry) break;
    } else {
        var warnings: std.ArrayList(u8) = .empty;
        if (Converter.opt(func, "warnings")) |w| if (w == .array) for (w.array.items, 0..) |item, i| {
            if (i > 0) try warnings.appendSlice(a, "; ");
            if (Converter.opt(item, "text")) |t| if (t == .string) try warnings.appendSlice(a, t.string);
        };
        return k.refuse("no block starts at function entry 0x{x}; decompiler warnings: {s}", .{ entry, warnings.items[0..@min(600, warnings.items.len)] });
    }
    if (Converter.opt(func, "instructions_outside_declared_bounds")) |outside| if (outside == .array and outside.array.items.len > 0)
        try notes.append(a, try std.fmt.allocPrint(a, "{d} instructions outside declared bounds (bounds_policy={s}); results may cite them", .{ outside.array.items.len, try pyStr(a, if (func == .object) func.object.get("bounds_policy") else null) }));
    const fname = if (Converter.opt(func, "name")) |n| (if (n == .string and n.string.len > 0) n.string else "unnamed") else "unnamed";
    try out.append(a, try std.fmt.allocPrint(a, "function 1 {s} entry=0x{x}", .{ try token(a, fname), entry }));

    const ops = try k.array(high, "ops");
    var op_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (ops, 0..) |op, i| try op_index.put(a, try k.str(op, "id"), i);
    var block_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (blocks, 0..) |b, i| try block_index.put(a, try k.str(b, "id"), i);
    const Place = struct { block: []const u8, seq: usize };
    var op_block: std.StringHashMapUnmanaged(Place) = .empty;
    for (blocks) |b| {
        const id = try k.str(b, "id");
        try out.append(a, try std.fmt.allocPrint(a, "block {d} 0x{x}", .{ try k.num(try k.get(b, "id"), "bb:"), try k.hex(try k.get(b, "start"), id) }));
        for (try k.array(b, "ops"), 0..) |op_id, seq| {
            if (op_id != .string) return k.refuse("TypeError: block op id", .{});
            if (op_block.contains(op_id.string)) return k.refuse("op {s} listed in two blocks", .{op_id.string});
            if (!op_index.contains(op_id.string)) return k.refuse("block {s} lists unknown op {s}", .{ id, op_id.string });
            try op_block.put(a, op_id.string, .{ .block = id, .seq = seq });
        }
    }
    // Edges in each target's pred[] order: MULTIEQUAL input i belongs to pred i.
    var used = try a.alloc([]bool, blocks.len);
    for (blocks, used) |b, *u| {
        u.* = try a.alloc(bool, (try k.array(b, "succ")).len);
        @memset(u.*, false);
    }
    for (blocks) |b| {
        const id = try k.str(b, "id");
        for (try k.array(b, "pred")) |p| {
            if (p != .string) return k.refuse("TypeError: pred id", .{});
            const pi = block_index.get(p.string) orelse return k.refuse("block {s} has unknown predecessor {s}", .{ id, p.string });
            const succ = try k.array(blocks[pi], "succ");
            const slot = for (succ, 0..) |s, j| {
                const to = try k.get(s, "to");
                if (to == .string and std.mem.eql(u8, to.string, id) and !used[pi][j]) break j;
            } else return k.refuse("pred {s} -> {s} has no matching succ entry", .{ p.string, id });
            used[pi][slot] = true;
            const edge_kind = try k.str(succ[slot], "kind");
            const pops = try k.array(blocks[pi], "ops");
            const last: ?[]const u8 = if (pops.len > 0) try k.str(ops[op_index.get(pops[pops.len - 1].string).?], "opcode") else null;
            const mapped: []const u8 = if (std.mem.eql(u8, edge_kind, "true_out")) "true" else if (std.mem.eql(u8, edge_kind, "false_out")) "false" else if (std.mem.eql(u8, edge_kind, "switch")) "switch" else if (std.mem.eql(u8, edge_kind, "flow")) "fall" else if (std.mem.eql(u8, edge_kind, "unconditional")) (if (last != null and std.mem.eql(u8, last.?, "BRANCH")) "jump" else "fall") else return k.refuse("unknown edge kind {s}", .{edge_kind});
            try out.append(a, try std.fmt.allocPrint(a, "edge {d} {d} {s}", .{ try k.num(p, "bb:"), try k.num(try k.get(b, "id"), "bb:"), mapped }));
        }
    }
    for (blocks, used) |b, u| for (u) |flag| if (!flag) return k.refuse("block {s} has a succ entry without matching pred", .{try k.str(b, "id")});

    const Param = struct { space: ?[]const u8, offset: ?[]const u8, index: i64 };
    var params: std.ArrayList(Param) = .empty;
    if (Converter.opt(func, "prototype")) |proto| if (Converter.opt(proto, "params")) |list| if (list == .array) for (list.array.items) |prm| {
        const space = Converter.opt(prm, "storage_space");
        const offset = Converter.opt(prm, "storage_offset");
        const p = Param{ .space = if (space) |s| (if (s == .string) s.string else null) else null, .offset = if (offset) |o| (if (o == .string) o.string else null) else null, .index = try k.int(try k.get(prm, "index"), "index") };
        for (params.items) |existing| {
            if (optEql(existing.space, p.space) and optEql(existing.offset, p.offset)) break;
        } else try params.append(a, p);
    };
    const processor = if (Converter.opt(lang, "processor")) |p| (if (p == .string) p.string else "") else "";
    const stack_regs: []const []const u8 = if (std.mem.eql(u8, processor, "x86")) &.{ "RSP", "ESP", "SP" } else if (std.mem.eql(u8, processor, "AARCH64")) &.{"sp"} else if (std.mem.eql(u8, processor, "68000")) &.{ "SP", "A7" } else &.{};
    const varnodes = try k.array(high, "varnodes");
    var vns: std.StringHashMapUnmanaged(Value) = .empty;
    for (varnodes) |v| {
        const id = try k.str(v, "id");
        try vns.put(a, id, v);
        const space = try k.str(v, "space");
        const sp = for (spaces.items) |s| {
            if (std.mem.eql(u8, s.name, space)) break s;
        } else return k.refuse("varnode {s} in unknown space {s}", .{ id, space });
        var attrs: std.ArrayList([]const u8) = .empty;
        const offset = try k.hex(try k.get(v, "offset"), id);
        if (Converter.opt(v, "offset_encoding")) |enc| if (enc == .string and std.mem.eql(u8, enc.string, "reference_elided")) {
            if (std.mem.eql(u8, space, "iop")) continue; // INDIRECT op reference: emitted as @op
            if (std.mem.eql(u8, space, "fspec")) try attrs.append(a, "annotation");
        };
        const register = if (Converter.opt(v, "register")) |r| (if (r == .string) r.string else null) else null;
        if (hasFlag(v, "input")) {
            try attrs.append(a, "input");
            const voff = try k.str(v, "offset");
            for (params.items) |p| if (p.space != null and p.offset != null and std.mem.eql(u8, p.space.?, space) and std.mem.eql(u8, p.offset.?, voff)) {
                try attrs.append(a, try std.fmt.allocPrint(a, "param={d}", .{p.index}));
                break;
            };
            if (hasFlag(v, "spacebase")) try attrs.append(a, "spacebase") else if (register != null and contains(stack_regs, register.?)) {
                try attrs.append(a, "spacebase_heuristic");
                try notes.append(a, try std.fmt.allocPrint(a, "{s} ({s}) marked frame base by register-name heuristic", .{ id, register.? }));
            }
        }
        if (hasFlag(v, "annotation") and !contains(attrs.items, "annotation")) try attrs.append(a, "annotation");
        if (hasFlag(v, "addrtied")) try attrs.append(a, "addrtied");
        if (hasFlag(v, "persist")) try attrs.append(a, "persist");
        if (hasFlag(v, "free") and !std.mem.eql(u8, sp.cls, "constant") and !contains(attrs.items, "annotation") and !hasFlag(v, "input"))
            return k.refuse("free non-constant varnode {s} has no def and no input flag", .{id});
        if (register) |name| if (name.len > 0) try attrs.append(a, try std.fmt.allocPrint(a, "name={s}", .{try token(a, name)}));
        try attrs.append(a, try std.fmt.allocPrint(a, "origin={s}", .{try token(a, id)}));
        try out.append(a, try std.fmt.allocPrint(a, "vn {d} {d} 0x{x} {d} {s}", .{ try k.num(try k.get(v, "id"), "vn:"), sp.index, offset, try k.int(try k.get(v, "size"), "size"), try std.mem.join(a, " ", attrs.items) }));
    }
    var flipped: usize = 0;
    for (ops) |op| {
        const id = try k.str(op, "id");
        const place = op_block.get(id) orelse return k.refuse("op {s} is in no block", .{id});
        var opcode = try k.str(op, "opcode");
        for (aliases) |pair| if (std.mem.eql(u8, pair[0], opcode)) {
            opcode = pair[1];
            break;
        };
        if (std.mem.eql(u8, opcode, "CBRANCH") and truthy(Converter.opt(op, "boolean_flip"))) flipped += 1;
        var ins: std.ArrayList([]const u8) = .empty;
        for (try k.array(op, "in")) |ref| {
            if (ref != .string) return k.refuse("op {s} reads a non-string varnode id", .{id});
            const v = vns.get(ref.string) orelse return k.refuse("op {s} reads unknown varnode {s}", .{ id, ref.string });
            if (std.mem.eql(u8, try k.str(v, "space"), "iop")) {
                const target = Converter.opt(v, "ref_op") orelse return k.refuse("iop varnode {s} has no ref_op", .{ref.string});
                try ins.append(a, try std.fmt.allocPrint(a, "@{d}", .{try k.num(target, "op:")}));
            } else try ins.append(a, try std.fmt.allocPrint(a, "{d}", .{try k.num(ref, "vn:")}));
        }
        const output = Converter.opt(op, "out");
        const outv = if (truthy(output)) try std.fmt.allocPrint(a, "{d}", .{try k.num(output.?, "vn:")}) else "-";
        try out.append(a, try std.fmt.allocPrint(a, "op {d} {d} 0x{x} {d} {s} {s} {s} origin={s}", .{ try k.num(try k.get(op, "id"), "op:"), try k.num(Value{ .string = place.block }, "bb:"), try k.hex(try k.get(op, "pc"), id), place.seq, try token(a, opcode), outv, try std.mem.join(a, " ", ins.items), try token(a, id) }));
    }
    if (Converter.opt(doc, "calls")) |calls| {
        if (calls != .array) return k.refuse("TypeError: calls is not a list", .{});
        for (calls.array.items) |call| {
            const target = if (Converter.opt(call, "target")) |t| try std.fmt.allocPrint(a, "0x{x}", .{try k.hex(t, "call")}) else "unknown";
            var line = try std.fmt.allocPrint(a, "call {d} target={s}", .{ try k.num(try k.get(call, "op"), "op:"), target });
            if (Converter.opt(call, "target_name")) |name| if (truthy(name)) {
                line = try std.fmt.allocPrint(a, "{s} name={s}", .{ line, try token(a, try pyStr(a, name)) });
            };
            try out.append(a, line);
        }
    }
    if (flipped > 0) try notes.append(a, try std.fmt.allocPrint(a, "{d} CBRANCH with boolean_flip: edge true/false follow Ghidra getTrueOut/getFalseOut, i.e. the raw condition value", .{flipped}));
    for (notes.items) |n| try out.insert(a, 3, try std.fmt.allocPrint(a, "# note: {s}", .{n}));
    try out.append(a, "end");
    var text: std.ArrayList(u8) = .empty;
    for (out.items) |line| {
        try text.appendSlice(a, line);
        try text.append(a, '\n');
    }
    return text.items;
}

fn optEql(l: ?[]const u8, r: ?[]const u8) bool {
    if (l == null or r == null) return l == null and r == null;
    return std.mem.eql(u8, l.?, r.?);
}

fn fixtureConvert(a: Allocator) !Result {
    const bytes = @embedFile("adapter_fixture.json");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const doc = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    return convert(a, doc, &std.fmt.bytesToHex(digest, .lower));
}

test "adapter output is byte-identical to the Python adapter on the qx_alloc export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try fixtureConvert(arena.allocator());
    try std.testing.expectEqualStrings(@embedFile("adapter_fixture.xsg"), result.xsg);
}

test "adapter refusals keep their cause" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try std.json.parseFromSliceLeaky(Value, a, "{\"schema\":\"xodb.ghidra.function_graph\",\"schema_version\":\"0.3.0\",\"status\":\"ok\"}", .{});
    try std.testing.expect(std.mem.indexOf(u8, (try convert(a, old, "00")).refused, "0.4.x only") != null);
    const failed = try std.json.parseFromSliceLeaky(Value, a, "{\"schema\":\"xodb.ghidra.function_graph\",\"schema_version\":\"0.4.1\",\"status\":\"error\"}", .{});
    try std.testing.expect(std.mem.indexOf(u8, (try convert(a, failed, "00")).refused, "not ok") != null);
    // A graph whose entry has no block (the PIC call-to-branch rewrite) is refused.
    var doc = try std.json.parseFromSliceLeaky(Value, a, @embedFile("adapter_fixture.json"), .{});
    try doc.object.getPtr("function").?.object.put(a, "entry", .{ .string = "0x1" });
    try std.testing.expect(std.mem.startsWith(u8, (try convert(a, doc, "00")).refused, "no block starts at function entry 0x1"));
}
