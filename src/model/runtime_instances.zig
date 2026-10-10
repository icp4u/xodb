//! Bind the existing owned memory-search job to retained runtime metadata.
//! C interprets candidate bytes; a match never proves allocation lifetime.
const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("session.zig").Session;
const cache = @import("runtime_types.zig");
pub const max_page = 64;
pub fn selfField(g: *const c.struct_xjai_graph, index: u32, name: []const u8) !u32 {
    if (index >= g.type_count or name.len == 0 or name.len > 1024) return error.InvalidArguments;
    const t = g.types[index];
    if (t.reason != null or t.tag != 7) return error.RuntimeSelfTypeFieldUnproved;
    var found: ?u32 = null;
    for (g.members[t.first_member .. t.first_member + t.member_count], t.first_member..) |m, i| {
        if (!std.mem.eql(u8, std.mem.span(g.text + m.name), name)) continue;
        if (found != null) return error.RuntimeTypeAmbiguous;
        if (m.reason != null or m.type >= g.type_count or g.types[m.type].reason != null or g.types[m.type].tag != 13 or
            m.flags & (g.layout.flags[c.XJAI_F_CONSTANT] | g.layout.flags[c.XJAI_F_IMPORTED]) != 0) return error.RuntimeSelfTypeFieldUnproved;
        found = @intCast(i);
    }
    return found orelse error.RuntimeSelfTypeFieldUnproved;
}
pub const Query = struct { id: u64, context_id: u64, declared: u32, needle: u32, member: u32 };
pub const Row = struct { hit: u64, address: ?u64, type_address: ?u64, reason: ?[]const u8 };
pub const Page = struct {
    rows: [max_page]Row = undefined,
    count: usize = 0,
    reads: usize = 0,
    bytes: usize = 0,
    backend_error: ?anyerror = null,
};
pub const State = struct {
    query: ?Query = null,
    pub fn begin(self: *State, session: *Session, entry: cache.Entry, declared: u32, needle: u32, member: u32, address: u64, length: usize) !u64 {
        if (length > @import("memory.zig").max_search) return error.InvalidMemoryRange;
        return self.beginOwned(session, entry, declared, needle, member, &.{.{ .address = address, .length = length }}, session.jobRequester());
    }
    pub fn beginOwned(self: *State, session: *Session, entry: cache.Entry, declared: u32, needle: u32, member: u32, ranges: []const @import("memory.zig").Range, requester: @import("../service/job_owner.zig").Requester) !u64 {
        try entry.requireStop(session);
        const g = try entry.graph();
        if (needle >= g.type_count or g.types[needle].reason != null or g.types[needle].tag != 7) return error.RuntimeTypeUnproved;
        var pattern: [8]u8 = undefined;
        std.mem.writeInt(u64, &pattern, g.types[needle].address, .little);
        const id = try session.memory.startSearchRanges(session, ranges, &pattern, requester);
        self.query = .{ .id = id, .context_id = entry.id, .declared = declared, .needle = needle, .member = member };
        return id;
    }
    pub fn find(self: *const State, session: *Session, id: u64) !Query {
        const query = self.query orelse return error.NoRuntimeInstanceSearch;
        if (query.id != id) return error.StaleRuntimeInstanceSearch;
        const search = if (session.memory.search) |*v| v else return error.StaleRuntimeInstanceSearch;
        if (search.id != id) return error.StaleRuntimeInstanceSearch;
        return query;
    }
    pub fn page(self: *const State, session: *Session, id: u64, start: usize, limit: usize) !Page {
        const query = try self.find(session, id);
        const entry = try session.runtime_types.find(query.context_id);
        try entry.requireStop(session);
        const g = try entry.graph();
        const search = &session.memory.search.?;
        if (search.generation != entry.generation or search.image_epoch != entry.image_epoch) return error.RuntimeTypesStale;
        if (start > search.count or limit == 0 or limit > max_page) return error.InvalidArguments;
        var context = cache.LiveReader{ .session = session };
        var reader = context.reader();
        var result = Page{};
        const end = @min(search.count, start + limit);
        for (search.hits[start..end]) |hit| {
            var address: u64 = 0;
            var actual: u32 = c.XJAI_NONE;
            const why = c.xjai_instance_candidate(g, query.declared, query.member, hit, &reader, &address, &actual);
            const reason: ?[]const u8 = if (why != null) std.mem.span(why) else if (actual != query.needle) "JaiCandidateTypeChanged" else null;
            result.rows[result.count] = .{ .hit = hit, .address = if (reason == null) address else null, .type_address = if (reason == null) g.types[actual].address else null, .reason = reason };
            result.count += 1;
        }
        try entry.requireStop(session);
        result.reads = reader.reads;
        result.bytes = reader.bytes;
        result.backend_error = context.failure;
        return result;
    }
};
