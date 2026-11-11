//! Test-only replay of live wire frames through the app's own delta State.
//! stdin: length-framed frames (u32 big-endian + JSON); stdout: per frame,
//! a length-framed JSON reply {"doc":...} or {"error":"Name"}; "current" returns
//! the published document, "reset-state" clears it as the app's stop() does. Used by
//! tests/agent-time-equivalence.py; not part of the application build.
const std = @import("std");
const delta = @import("agent_time_delta.zig");
const a = std.heap.c_allocator;

fn readAll(buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(0, buf[got..].ptr, buf.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}
fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(1, rest.ptr, rest.len);
        if (n <= 0) std.process.exit(3);
        rest = rest[@intCast(n)..];
    }
}
fn reply(bytes: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(bytes.len), .big);
    writeAll(&len);
    writeAll(bytes);
}

pub fn main() void {
    var state = delta.State{ .allocator = a };
    defer state.deinit();
    while (true) {
        var len: [4]u8 = undefined;
        if (!readAll(&len)) return;
        const size = std.mem.readInt(u32, &len, .big);
        const bytes = a.alloc(u8, size) catch std.process.exit(4);
        defer a.free(bytes);
        if (!readAll(bytes)) std.process.exit(5);
        if (std.mem.eql(u8, bytes, "reset-state")) {
            // The app does this when it stops/restarts its helper.
            state.deinit();
            reply("{\"ok\":true}");
            continue;
        }
        if (std.mem.eql(u8, bytes, "current")) {
            // The published document: what the app's view holds after the last apply.
            const root = state.root orelse {
                reply("{\"doc\":null}");
                continue;
            };
            send(root.doc);
            continue;
        }
        const frame = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .allocate = .alloc_always }) catch {
            reply("{\"error\":\"Parse\"}");
            continue;
        };
        defer frame.deinit();
        const session = state.apply(frame.value) catch |err| {
            var buf: [128]u8 = undefined;
            reply(std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"?\"}");
            continue;
        };
        defer session.release();
        send(session.doc);
    }
}
fn send(value: std.json.Value) void {
    const doc = std.json.Stringify.valueAlloc(a, value, .{}) catch std.process.exit(6);
    defer a.free(doc);
    const out = std.mem.concat(a, u8, &.{ "{\"doc\":", doc, "}" }) catch std.process.exit(7);
    defer a.free(out);
    reply(out);
}
