//! Bounded static graph from a declared function range. Edges describe decoded
//! possibilities, never observed execution. Calls may return; that is an assumption.
const std = @import("std");
const disasm = @import("disassembly.zig");
const Site = @import("../debug/info.zig").Site;
pub const max_bytes = 65536;
pub const max_instructions = 32768;
pub const max_blocks = 8192;
pub const EdgeKind = enum { taken, not_taken, jump, call, return_site, fallthrough, ret, trap, system_resume };
pub const Resolution = enum { block, external, indirect, non_boundary, decode_gap, function_end, dynamic_return, terminal };
pub const Edge = struct { from: usize, kind: EdgeKind, address: ?u64, to: ?usize = null, resolution: Resolution, assumed: bool = false };
pub const Block = struct {
    id: usize,
    address: u64,
    end: u64,
    first: usize,
    count: usize,
    reachable: bool = false,
    source: ?Site = null,
};
pub const Graph = struct {
    address: u64,
    size: usize,
    decoded_bytes: usize,
    instructions: []disasm.Instruction,
    blocks: []Block,
    edges: []Edge,
    pub fn blockAt(self: Graph, address: u64) ?usize {
        for (self.blocks) |b| if (address >= b.address and address < b.end) return b.id;
        return null;
    }
    pub fn deinit(self: Graph, a: std.mem.Allocator) void {
        a.free(self.instructions);
        a.free(self.blocks);
        a.free(self.edges);
    }
};
fn instructionAt(instructions: []const disasm.Instruction, address: u64) ?usize {
    var lo: usize = 0;
    var hi = instructions.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (instructions[mid].address < address) lo = mid + 1 else hi = mid;
    }
    return if (lo < instructions.len and instructions[lo].address == address) lo else null;
}
fn edge(graph: Graph, from: usize, kind: EdgeKind, destination: ?u64, assumed: bool) Edge {
    var result = Edge{ .from = from, .kind = kind, .address = destination, .resolution = .indirect, .assumed = assumed };
    if (destination) |address| {
        result.resolution = if (address < graph.address or address >= graph.address + graph.size) .external else if (address >= graph.address + graph.decoded_bytes) .decode_gap else .non_boundary;
        for (graph.blocks) |block| if (block.address == address) {
            result.to = block.id;
            result.resolution = .block;
            break;
        };
        if (address == graph.address + graph.size and (kind == .fallthrough or kind == .not_taken or kind == .return_site or kind == .system_resume)) result.resolution = .function_end;
    }
    return result;
}
/// All returned allocations belong to `a`; source metadata is filled by Session.
pub fn build(a: std.mem.Allocator, bytes: []const u8, address: u64) !Graph {
    if (bytes.len == 0) return error.EmptyFunction;
    if (bytes.len > max_bytes) return error.FunctionTooLarge;
    if (address > @as(u64, std.math.maxInt(u64)) - bytes.len) return error.InvalidAddress;
    const capacity = @min(max_instructions + 1, bytes.len);
    const buffer = try a.alloc(disasm.Instruction, capacity);
    defer a.free(buffer);
    const count = try disasm.decodeFlow(bytes, address, buffer);
    if (count == 0) return error.UndecodableFunction;
    if (count > max_instructions) return error.InstructionLimit;
    const instructions = try a.dupe(disasm.Instruction, buffer[0..count]);
    errdefer a.free(instructions);
    const leaders = try a.alloc(bool, count);
    defer a.free(leaders);
    @memset(leaders, false);
    leaders[0] = true;
    for (instructions, 0..) |inst, i| {
        if (inst.flow != .ordinary and i + 1 < count) leaders[i + 1] = true;
        // Call destinations are annotations, not intra-procedural successors.
        if (inst.flow == .conditional or inst.flow == .jump) if (inst.target) |target| {
            if (instructionAt(instructions, target)) |j| leaders[j] = true;
        };
    }
    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(a);
    for (instructions, 0..) |inst, i| {
        if (leaders[i]) {
            if (blocks.items.len == max_blocks) return error.BlockLimit;
            try blocks.append(a, .{ .id = blocks.items.len, .address = inst.address, .end = inst.address + inst.size, .first = i, .count = 1 });
        } else {
            const current = &blocks.items[blocks.items.len - 1];
            current.end = inst.address + inst.size;
            current.count += 1;
        }
    }
    var graph = Graph{ .address = address, .size = bytes.len, .decoded_bytes = @intCast(instructions[count - 1].address + instructions[count - 1].size - address), .instructions = instructions, .blocks = try blocks.toOwnedSlice(a), .edges = &.{} };
    errdefer a.free(graph.blocks);
    var edges: std.ArrayList(Edge) = .empty;
    errdefer edges.deinit(a);
    for (graph.blocks) |block| {
        const last = instructions[block.first + block.count - 1];
        switch (last.flow) {
            .ordinary => try edges.append(a, edge(graph, block.id, .fallthrough, block.end, false)),
            .conditional => {
                try edges.append(a, edge(graph, block.id, .taken, last.target, false));
                try edges.append(a, edge(graph, block.id, .not_taken, block.end, false));
            },
            .jump => try edges.append(a, edge(graph, block.id, .jump, last.target, false)),
            .call => {
                try edges.append(a, edge(graph, block.id, .call, last.target, false));
                try edges.append(a, edge(graph, block.id, .return_site, block.end, true));
            },
            .system => try edges.append(a, edge(graph, block.id, .system_resume, block.end, true)),
            .ret, .trap => try edges.append(a, .{ .from = block.id, .kind = if (last.flow == .ret) .ret else .trap, .address = null, .resolution = if (last.flow == .ret) .dynamic_return else .terminal }),
        }
    }
    graph.edges = try edges.toOwnedSlice(a);
    // Reachability follows possible local transfers, including assumed returns.
    graph.blocks[0].reachable = true;
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.edges) |e| if (e.kind != .call and graph.blocks[e.from].reachable) {
            if (e.to) |to| if (!graph.blocks[to].reachable) {
                graph.blocks[to].reachable = true;
                changed = true;
            };
        };
    }
    return graph;
}

test "CFG diamond and loop have exact successors" {
    // cmp edi,0; je +7; dec edi; jmp -9; nop; nop; ret
    const bytes = [_]u8{ 0x83, 0xff, 0, 0x74, 6, 0xff, 0xcf, 0xeb, 0xf7, 0x90, 0x90, 0xc3 };
    const graph = try build(std.testing.allocator, &bytes, 0x1000);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), graph.blocks.len);
    try std.testing.expectEqual(@as(?usize, 3), graph.edges[0].to);
    try std.testing.expectEqual(@as(?usize, 1), graph.edges[1].to);
    try std.testing.expectEqual(@as(?usize, 0), graph.edges[2].to);
    try std.testing.expect(!graph.blocks[2].reachable);
    try std.testing.expect(graph.blocks[3].reachable);
}
test "CFG distinguishes indirect calls, tail exits and assumed returns" {
    const graph = try build(std.testing.allocator, &.{ 0xff, 0xd0, 0xe9, 0x20, 0, 0, 0 }, 0x2000);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(Resolution.indirect, graph.edges[0].resolution);
    try std.testing.expectEqual(EdgeKind.call, graph.edges[0].kind);
    try std.testing.expect(graph.edges[1].assumed);
    try std.testing.expectEqual(Resolution.external, graph.edges[2].resolution);
    try std.testing.expectEqual(@as(?u64, 0x2027), graph.edges[2].address);
}
test "CFG rejects oversized input and labels gaps and overlapping destinations" {
    const a = std.testing.allocator;
    const overlap = try build(a, &.{ 0xeb, 1, 0x48, 0x89, 0xe5, 0xc3 }, 0x3000);
    defer overlap.deinit(a);
    try std.testing.expectEqual(Resolution.non_boundary, overlap.edges[0].resolution);
    const gap = try build(a, &.{ 0x90, 0x0f }, 0x4000);
    defer gap.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), gap.decoded_bytes);
    try std.testing.expectEqual(Resolution.decode_gap, gap.edges[0].resolution);
    try std.testing.expectError(error.InvalidAddress, build(a, &.{ 0x90, 0xc3 }, std.math.maxInt(u64)));
    const large = try a.alloc(u8, max_bytes + 1);
    defer a.free(large);
    try std.testing.expectError(error.FunctionTooLarge, build(a, large, 0));
}
test "CFG indirect jump ends a block and trap has no fallthrough" {
    const graph = try build(std.testing.allocator, &.{ 0xff, 0xe0, 0x0f, 0x0b, 0xc3 }, 0x5000);
    defer graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), graph.blocks.len);
    try std.testing.expectEqual(EdgeKind.jump, graph.edges[0].kind);
    try std.testing.expectEqual(Resolution.indirect, graph.edges[0].resolution);
    try std.testing.expectEqual(EdgeKind.trap, graph.edges[1].kind);
    try std.testing.expect(!graph.blocks[1].reachable and !graph.blocks[2].reachable);
}

test "CFG models counter branches and enforces instruction and block budgets" {
    const a = std.testing.allocator;
    // loop, loope, loopne, jrcxz, then ret; each branches back to entry.
    const graph = try build(a, &.{ 0xe2, 0xfe, 0xe1, 0xfc, 0xe0, 0xfa, 0xe3, 0xf8, 0xc3 }, 0x6000);
    defer graph.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), graph.blocks.len);
    for (0..4) |i| {
        try std.testing.expectEqual(EdgeKind.taken, graph.edges[i * 2].kind);
        try std.testing.expectEqual(@as(?usize, 0), graph.edges[i * 2].to);
        try std.testing.expectEqual(@as(?usize, i + 1), graph.edges[i * 2 + 1].to);
    }
    const nops = try a.alloc(u8, max_instructions + 1);
    defer a.free(nops);
    @memset(nops, 0x90);
    const at_instruction_limit = try build(a, nops[0..max_instructions], 0);
    defer at_instruction_limit.deinit(a);
    try std.testing.expectEqual(@as(usize, max_instructions), at_instruction_limit.instructions.len);
    try std.testing.expectError(error.InstructionLimit, build(a, nops, 0));
    const returns = try a.alloc(u8, max_blocks + 1);
    defer a.free(returns);
    @memset(returns, 0xc3);
    const at_block_limit = try build(a, returns[0..max_blocks], 0);
    defer at_block_limit.deinit(a);
    try std.testing.expectEqual(@as(usize, max_blocks), at_block_limit.blocks.len);
    try std.testing.expectError(error.BlockLimit, build(a, returns, 0));
}

test "CFG retains late branches and PC lookup in interpreter-sized functions" {
    const a = std.testing.allocator;
    // 1,720 blocks and 8,600 instructions exceed both former budgets.
    // Each block has four nops and jumps to the next block; the last returns.
    const block_count = 1720;
    const bytes = try a.alloc(u8, block_count * 6);
    defer a.free(bytes);
    for (0..block_count) |i| {
        @memset(bytes[i * 6 ..][0..4], 0x90);
        bytes[i * 6 + 4] = 0xeb;
        bytes[i * 6 + 5] = 0;
    }
    bytes[bytes.len - 2] = 0xc3;
    const graph = try build(a, bytes[0 .. bytes.len - 1], 0x1000);
    defer graph.deinit(a);
    try std.testing.expectEqual(@as(usize, block_count), graph.blocks.len);
    try std.testing.expectEqual(@as(usize, block_count * 5), graph.instructions.len);
    try std.testing.expectEqual(bytes.len - 1, graph.decoded_bytes);
    for (graph.blocks, 0..) |block, i| {
        try std.testing.expect(block.reachable);
        try std.testing.expectEqual(@as(?usize, i), graph.blockAt(block.address + 2));
        if (i + 1 < block_count) try std.testing.expectEqual(@as(?usize, i + 1), graph.edges[i].to);
    }
    try std.testing.expectEqual(EdgeKind.ret, graph.edges[block_count - 1].kind);
    try std.testing.expectEqual(@as(?usize, null), graph.blockAt(0x1000 + bytes.len - 1));
}
