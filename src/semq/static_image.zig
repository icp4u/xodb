//! Read-only pseudo-C for an image with no debug target. The input is copied
//! to a private immutable snapshot before the sidecar sees it.
const std = @import("std");
const log = @import("../log.zig");
const sidecar = @import("ghidra_sidecar.zig");
const snapshot = @import("../binary/snapshot.zig");
const c = @import("../c.zig").api;

const Snapshot = struct {
    dir: [:0]u8,
    path: [:0]u8,
    companion: ?[:0]u8 = null,
    sha256: [64]u8,
    companion_sha256: ?[64]u8 = null,
    fn deinit(self: *Snapshot) void {
        if (self.companion) |path| _ = c.unlink(path.ptr);
        _ = c.unlink(self.path.ptr);
        _ = c.rmdir(self.dir.ptr);
    }
};

fn copyFile(source: [:0]const u8, destination: [:0]const u8, limit: u64, hash: ?*std.crypto.hash.sha2.Sha256) !void {
    const input = c.open(source.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (input < 0) return error.StaticImageOpenFailed;
    defer _ = c.close(input);
    var info: c.struct_stat = undefined;
    if (c.fstat(input, &info) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG or info.st_size < 0) return error.StaticImageNotRegular;
    if (@as(u64, @intCast(info.st_size)) > limit) return error.BinarySnapshotLimit;
    const output = c.open(destination.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (output < 0) return error.StaticImageSnapshotFailed;
    errdefer _ = c.unlink(destination.ptr);
    defer _ = c.close(output);
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = c.read(input, &buffer, buffer.len);
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        if (count < 0) return error.StaticImageReadFailed;
        if (count == 0) break;
        const bytes = buffer[0..@intCast(count)];
        total += bytes.len;
        if (total > limit) return error.BinarySnapshotLimit;
        if (hash) |digest| digest.update(bytes);
        var written: usize = 0;
        while (written < bytes.len) {
            const amount = c.write(output, bytes[written..].ptr, bytes.len - written);
            if (amount < 0 and std.c._errno().* == c.EINTR) continue;
            if (amount <= 0) return error.StaticImageSnapshotFailed;
            written += @intCast(amount);
        }
    }
}

fn copySnapshot(a: std.mem.Allocator, source: [:0]const u8) !Snapshot {
    const base = if (c.getenv("TMPDIR")) |value| if (value[0] != 0) std.mem.span(value) else "/tmp" else "/tmp";
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/xodb-static-XXXXXX", .{base}, 0);
    if (c.mkdtemp(directory.ptr) == null) return error.StaticImageSnapshotFailed;
    errdefer _ = c.rmdir(directory.ptr);
    const destination = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, std.fs.path.basename(source) }, 0);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    try copyFile(source, destination, snapshot.per_image_limit, &hash);
    errdefer _ = c.unlink(destination.ptr);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var companion: ?[:0]u8 = null;
    var companion_sha256: ?[64]u8 = null;
    const extension = std.fs.path.extension(source);
    if (std.ascii.eqlIgnoreCase(extension, ".exe") or std.ascii.eqlIgnoreCase(extension, ".dll")) {
        const basename = std.fs.path.basename(source);
        const pdb_name = try std.fmt.allocPrint(a, "{s}.pdb", .{basename[0 .. basename.len - extension.len]});
        const source_pdb = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ std.fs.path.dirname(source) orelse ".", pdb_name }, 0);
        if (c.access(source_pdb.ptr, c.R_OK) == 0) {
            const destination_pdb = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ directory, pdb_name }, 0);
            var pdb_hash = std.crypto.hash.sha2.Sha256.init(.{});
            try copyFile(source_pdb, destination_pdb, 64 << 20, &pdb_hash);
            var pdb_digest: [32]u8 = undefined;
            pdb_hash.final(&pdb_digest);
            companion = destination_pdb;
            companion_sha256 = std.fmt.bytesToHex(pdb_digest, .lower);
        }
    }
    return .{ .dir = directory, .path = destination, .companion = companion, .sha256 = std.fmt.bytesToHex(digest, .lower), .companion_sha256 = companion_sha256 };
}

fn writeStdout(bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and std.c._errno().* == c.EINTR) continue;
        if (count <= 0) return error.StaticDecompileOutputFailed;
        offset += @intCast(count);
    }
}

pub fn decompile(a: std.mem.Allocator, path: [:0]const u8, symbol: []const u8) !void {
    if (!try sidecar.selected(a)) return error.GhidraSidecarNotConfigured;
    var image = try copySnapshot(a, path);
    defer image.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    var stage = std.atomic.Value(sidecar.Stage).init(.queued);
    var failure = sidecar.Failure{ .code = "sidecar_failed", .detail = "the Ghidra sidecar did not return a document" };
    const socket = try sidecar.socketPath(a);
    const starter = try sidecar.starterPath(a);
    const companion_sha: ?[]const u8 = if (image.companion_sha256) |*sha| sha[0..] else null;
    const result = sidecar.runStatic(a, .{ .socket_path = socket, .starter = starter, .deadline_ms = 600_000 }, image.path, path, &image.sha256, image.companion, companion_sha, symbol, &cancel, &stage, &failure) catch |err| {
        log.err(.sidecar, "xodb: static decompile failed: {s}: {s}\n", .{ failure.code, failure.detail });
        return err;
    };
    const document = try std.json.parseFromSliceLeaky(std.json.Value, a, result.document, .{ .max_value_len = 64 << 20 });
    if (document != .object) return error.StaticDecompileDocumentInvalid;
    const pseudocode = document.object.get("pseudocode") orelse return error.StaticDecompileDocumentInvalid;
    if (pseudocode != .object) return error.StaticDecompileDocumentInvalid;
    const text = pseudocode.object.get("text") orelse return error.StaticDecompileDocumentInvalid;
    if (text != .string) return error.StaticDecompileDocumentInvalid;
    try writeStdout(text.string);
    if (text.string.len == 0 or text.string[text.string.len - 1] != '\n') try writeStdout("\n");
}
