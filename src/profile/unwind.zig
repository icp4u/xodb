//! Derived stacks from immutable perf evidence. The only memory reader below
//! serves the saved stack window; it cannot fall back to a process or host VA.
const std = @import("std");
const capture_model = @import("capture.zig");
const records = @import("records.zig");
const mappings = @import("mappings.zig");
const loc = @import("../debug/location.zig");
const info = @import("../debug/info.zig");
pub const algorithm = "xodb-sampled-x86_64-v3";
pub const max_frames = 32;
pub const Reason = enum {
    complete,
    disabled,
    state_missing,
    registers_absent,
    unsupported_abi,
    registers_unavailable,
    stack_absent,
    retention_budget,
    invalid_sample,
    mappings_untrusted,
    mapping_missing,
    mapping_ambiguous,
    non_executable,
    asset_missing,
    cfi_missing,
    signal_frame,
    unsupported_cfi,
    unsupported_windows_unwind,
    stack_window,
    cycle,
    depth_limit,
};
pub const Frame = struct {
    pc: u64,
    sp: u64,
    lookup_pc: u64,
    mapping_id: u32 = 0,
    module_id: u64 = 0,
    name: [256]u8 = @splat(0),
    name_len: usize = 0,
    name_truncated: bool = false,
    /// Runtime address of the containing ELF/PE symbol, when one was found.
    symbol_address: ?u64 = null,
    method: ?[]const u8 = null,
};
pub const Result = struct {
    frames: [max_frames]Frame = undefined,
    count: usize = 0,
    reason: Reason = .depth_limit,
    detail: ?[]const u8 = null,
    analysis_id: [64]u8 = undefined,
};
const Window = struct {
    start: u64,
    bytes: []const u8,
    failed: bool = false,
    fn read(raw: *anyopaque, address: u64, out: []u8) !usize {
        const self: *Window = @ptrCast(@alignCast(raw));
        if (address < self.start or address - self.start > self.bytes.len or out.len > self.bytes.len - (address - self.start)) {
            self.failed = true;
            return error.CapturedStackUnavailable;
        }
        const offset: usize = @intCast(address - self.start);
        @memcpy(out, self.bytes[offset..][0..out.len]);
        return out.len;
    }
};
fn cancelled(cancel: ?*const std.atomic.Value(bool)) !void {
    if (cancel) |value| if (value.load(.acquire)) return error.ArchiveCancelled;
}
fn hashInt(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
/// Shared state for unwinding many samples of one completed capture: a mapping
/// cursor that advances with sample time (rebuilt if time goes backwards),
/// one SHA-256 fingerprint per consulted ELF/PE, and a small cache of private
/// libdw handles. Results and analysis IDs equal per-sample `walk`.
pub const Batch = struct {
    allocator: std.mem.Allocator,
    capture: *const capture_model.Capture,
    cancel: ?*const std.atomic.Value(bool),
    cursor: ?mappings.Cursor = null,
    cursor_ns: u64 = 0,
    fingerprints: std.AutoHashMapUnmanaged(u64, [32]u8) = .empty,
    debug: [max_debug]?Debug = @splat(null),
    debug_next: usize = 0,
    /// Bytes hashed for fingerprints; each asset at most once per batch.
    hashed_bytes: u64 = 0,
    /// Symbol lookups by module and link address; profiles repeat PCs, and
    /// an ELF symbol lookup is a linear scan. Bounded; misses past the bound
    /// are looked up directly.
    symbols: std.AutoHashMapUnmanaged(SymbolKey, ?@import("../binary/elf.zig").Located) = .empty,
    const max_symbols = 64 * 1024;
    const SymbolKey = struct { module: u64, link: u64 };
    const max_debug = 8;
    const Debug = struct { id: u64, image: info.Image };
    pub fn init(a: std.mem.Allocator, capture: *const capture_model.Capture, cancel: ?*const std.atomic.Value(bool)) Batch {
        return .{ .allocator = a, .capture = capture, .cancel = cancel };
    }
    pub fn deinit(self: *Batch) void {
        if (self.cursor) |*cursor| cursor.deinit();
        self.fingerprints.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        for (&self.debug) |*slot| if (slot.*) |*entry| {
            entry.image.deinit();
            slot.* = null;
        };
    }
    fn cursorAt(self: *Batch, time_ns: u64) !*mappings.Cursor {
        if (self.cursor != null and time_ns < self.cursor_ns) {
            self.cursor.?.deinit();
            self.cursor = null;
        }
        if (self.cursor == null) self.cursor = try mappings.Cursor.init(self.allocator, &self.capture.history);
        try self.cursor.?.advance(time_ns);
        self.cursor_ns = time_ns;
        return &self.cursor.?;
    }
    fn symbolAt(self: *Batch, module: anytype, link: u64) !?@import("../binary/elf.zig").Located {
        const key = SymbolKey{ .module = module.id, .link = link };
        if (self.symbols.get(key)) |found| return found;
        const found = module.image.symbolAt(link);
        if (self.symbols.count() < max_symbols) try self.symbols.put(self.allocator, key, found);
        return found;
    }
    fn fingerprint(self: *Batch, module: anytype) ![32]u8 {
        if (self.fingerprints.get(module.id)) |digest| return digest;
        var asset_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var offset: usize = 0;
        while (offset < module.mapping.len) {
            try cancelled(self.cancel);
            const end = @min(module.mapping.len, offset + 1024 * 1024);
            asset_hash.update(module.mapping[offset..end]);
            offset = end;
        }
        self.hashed_bytes += module.mapping.len;
        const digest = asset_hash.finalResult();
        try self.fingerprints.put(self.allocator, module.id, digest);
        return digest;
    }
    fn debugImage(self: *Batch, module: anytype) !*info.Image {
        for (&self.debug) |*slot| if (slot.*) |*entry| if (entry.id == module.id) return &entry.image;
        const slot = &self.debug[self.debug_next];
        if (slot.*) |*old| old.image.deinit();
        slot.* = null;
        // Private libdw handle: no cache shared with the UI/event loop.
        slot.* = .{ .id = module.id, .image = try info.Image.initWithAllocator(module.image, module.mapping, self.allocator) };
        self.debug_next = (self.debug_next + 1) % max_debug;
        return &slot.*.?.image;
    }
    pub fn walk(self: *Batch, ordinal: usize) !Result {
        return walkWith(self, ordinal);
    }
};
pub fn walk(a: std.mem.Allocator, capture: *const capture_model.Capture, ordinal: usize, cancel: ?*const std.atomic.Value(bool)) !Result {
    var batch = Batch.init(a, capture, cancel);
    defer batch.deinit();
    return batch.walk(ordinal);
}
fn walkWith(batch: *Batch, ordinal: usize) !Result {
    const capture = batch.capture;
    const cancel = batch.cancel;
    try cancelled(cancel);
    if (capture.collector != null) return error.ArchiveStillCollecting;
    if (ordinal >= capture.samples.len()) return error.InvalidSampleOrdinal;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(algorithm);
    hashInt(&hash, ordinal);
    hashInt(&hash, capture.started_ns);
    hashInt(&hash, capture.trusted_before_ns);
    const sample = capture.samples.get(ordinal);
    hashInt(&hash, sample.ip);
    hashInt(&hash, sample.time_ns);
    hashInt(&hash, sample.tid);
    var result = try walkInner(batch, sample, &hash);
    hash.update(@tagName(result.reason));
    if (result.detail) |detail| hash.update(detail);
    for (result.frames[0..result.count]) |frame| {
        hashInt(&hash, frame.pc);
        hashInt(&hash, frame.sp);
        hashInt(&hash, frame.lookup_pc);
        hashInt(&hash, frame.mapping_id);
        hashInt(&hash, frame.module_id);
        hash.update(frame.name[0..frame.name_len]);
        if (frame.method) |method| hash.update(method);
    }
    result.analysis_id = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return result;
}
fn nameLeaf(batch: *Batch, frame: *Frame, time_ns: u64, hash: *std.crypto.hash.sha2.Sha256) !void {
    const cursor = try batch.cursorAt(time_ns);
    const found = cursor.at(frame.lookup_pc) orelse return;
    if (found.ambiguous or !found.mapping.executable) return;
    if (batch.capture.pe_assets.byId(found.mapping.image_id)) |asset| {
        hashInt(hash, found.mapping.start);
        hashInt(hash, found.mapping.end);
        hashInt(hash, found.mapping.offset);
        hash.update(&(try batch.fingerprint(asset)));
        hashInt(hash, asset.bias);
        frame.mapping_id = found.mapping.id;
        frame.module_id = asset.id;
        namePe(frame, asset);
        return;
    }
    const module = for (batch.capture.images.loaded.items) |image| {
        if (image.id == found.mapping.image_id) break image;
    } else return;
    const link = module.linkAddress(frame.lookup_pc) catch return;
    hashInt(hash, found.mapping.start);
    hashInt(hash, found.mapping.end);
    hashInt(hash, found.mapping.offset);
    hash.update(&(try batch.fingerprint(module)));
    hashInt(hash, module.bias);
    frame.mapping_id = found.mapping.id;
    frame.module_id = module.id;
    const symbol = (try batch.symbolAt(module, link)) orelse return;
    frame.name_len = @min(frame.name.len, symbol.symbol.name.len);
    @memcpy(frame.name[0..frame.name_len], symbol.symbol.name[0..frame.name_len]);
    frame.name_truncated = frame.name_len < symbol.symbol.name.len;
    frame.symbol_address = module.runtimeAddress(symbol.symbol.value) catch null;
}
fn namePe(frame: *Frame, asset: *const @import("pe_assets.zig").Asset) void {
    if (asset.symbol(frame.lookup_pc, &frame.name)) |symbol| {
        frame.name_len = symbol.name.len;
        frame.name_truncated = symbol.truncated;
        frame.symbol_address = symbol.address;
    }
}
fn walkInner(batch: *Batch, sample: records.Sample, hash: *std.crypto.hash.sha2.Sha256) !Result {
    const capture = batch.capture;
    const cancel = batch.cancel;
    if (capture.config.user_stack_bytes == 0) return .{ .reason = .disabled };
    if (sample.user_state == 0 or sample.user_state > capture.user_state.count) return .{ .reason = .state_missing };
    const entry = capture.user_state.entries[sample.user_state - 1];
    const state = entry.state;
    hashInt(hash, state.abi);
    hashInt(hash, state.regs_mask);
    for (state.regs) |reg| hashInt(hash, reg);
    hashInt(hash, state.stack_size);
    hashInt(hash, state.stack_dyn);
    hash.update(capture.user_state.stack(entry));
    if (!state.regs_present) return .{ .reason = .registers_absent };
    if (state.abi != records.regs_abi_64) return .{ .reason = .unsupported_abi };
    var registers: loc.RegisterSet = @splat(null);
    const perf_to_dwarf = [_]i8{ 0, 3, 2, 1, 4, 5, 6, 7, 16, -1, -1, -1, -1, -1, -1, -1, 8, 9, 10, 11, 12, 13, 14, 15 };
    for (perf_to_dwarf, 0..) |dwarf, index| if (dwarf >= 0 and state.regs_mask & (@as(u64, 1) << @intCast(index)) != 0) {
        registers[@intCast(dwarf)] = state.regs[index];
    };
    const initial_sp = registers[7] orelse return .{ .reason = .registers_unavailable };
    const initial_pc = registers[16] orelse return .{ .reason = .registers_unavailable };
    if (!sample.time_present or !sample.ip_present or sample.cpu_mode != .user or sample.ip != initial_pc or sample.time_ns < capture.started_ns) return .{ .reason = .invalid_sample };
    var result = Result{};
    // Even a partial result retains the sampled leaf, without inventing callers.
    result.frames[0] = .{ .pc = initial_pc, .sp = initial_sp, .lookup_pc = initial_pc };
    result.count = 1;
    if (entry.status == .budget or state.stack_len == 0) {
        result.reason = if (entry.status == .budget) .retention_budget else .stack_absent;
        // No callers, but the sampled leaf is still named from the same
        // timestamped mapping and verified ELF the full walk would use.
        if (sample.time_ns < capture.trusted_before_ns) try nameLeaf(batch, &result.frames[0], sample.time_ns, hash);
        return result;
    }
    if (sample.time_ns >= capture.trusted_before_ns) {
        result.reason = .mappings_untrusted;
        return result;
    }
    var window = Window{ .start = initial_sp, .bytes = capture.user_state.stack(entry) };
    const cursor = try batch.cursorAt(sample.time_ns);
    var seen_images: [max_frames]u64 = undefined;
    var seen_count: usize = 0;
    while (true) {
        try cancelled(cancel);
        const frame = &result.frames[result.count - 1];
        const found = cursor.at(frame.lookup_pc) orelse {
            result.reason = .mapping_missing;
            return result;
        };
        const mapping = found.mapping;
        frame.mapping_id = mapping.id;
        frame.module_id = mapping.image_id;
        hashInt(hash, mapping.start);
        hashInt(hash, mapping.end);
        hashInt(hash, mapping.offset);
        if (found.ambiguous) {
            result.reason = .mapping_ambiguous;
            return result;
        }
        if (!mapping.executable) {
            result.reason = .non_executable;
            return result;
        }
        window.failed = false;
        const step: info.Unwind = step: {
            if (capture.pe_assets.byId(mapping.image_id)) |asset| {
                // PE lookup and epilogue inspection use the actual PC. Confirm
                // its ownership at this sample time as well as the PC-1 label.
                const actual = cursor.at(frame.pc) orelse {
                    result.reason = .mapping_missing;
                    return result;
                };
                if (actual.ambiguous) {
                    result.reason = .mapping_ambiguous;
                    return result;
                }
                if (!actual.mapping.executable) {
                    result.reason = .non_executable;
                    return result;
                }
                if (actual.mapping.image_id != asset.id) {
                    result.reason = .mapping_missing;
                    return result;
                }
                if (std.mem.indexOfScalar(u64, seen_images[0..seen_count], asset.id) == null) {
                    seen_images[seen_count] = asset.id;
                    seen_count += 1;
                    hash.update(&(try batch.fingerprint(asset)));
                    hashInt(hash, asset.bias);
                }
                namePe(frame, asset);
                break :step @import("../debug/windows.zig").unwind(asset.image, asset.bias, frame.pc, registers, .{ .user = &window, .read = Window.read }, null) catch |err| {
                    result.reason = if (window.failed) .stack_window else .unsupported_windows_unwind;
                    result.detail = @errorName(err);
                    return result;
                };
            }
            const module = blk: {
                for (capture.images.loaded.items) |image| if (image.id == mapping.image_id) break :blk image;
                result.reason = .asset_missing;
                return result;
            };
            const link = module.linkAddress(frame.lookup_pc) catch {
                result.reason = .mapping_missing;
                return result;
            };
            if (std.mem.indexOfScalar(u64, seen_images[0..seen_count], module.id) == null) {
                seen_images[seen_count] = module.id;
                seen_count += 1;
                // The same per-sample identity, with each ELF hashed once per batch.
                const digest = try batch.fingerprint(module);
                hash.update(&digest);
                hashInt(hash, module.bias);
            }
            if (try batch.symbolAt(module, link)) |symbol| {
                frame.name_len = @min(frame.name.len, symbol.symbol.name.len);
                @memcpy(frame.name[0..frame.name_len], symbol.symbol.name[0..frame.name_len]);
                frame.name_truncated = frame.name_len < symbol.symbol.name.len;
                frame.symbol_address = module.runtimeAddress(symbol.symbol.value) catch null;
            }
            const debug = batch.debugImage(module) catch |err| {
                result.reason = .unsupported_cfi;
                result.detail = @errorName(err);
                return result;
            };
            var scratch: [64 * 1024]u8 = undefined;
            var scratch_allocator = std.heap.FixedBufferAllocator.init(&scratch);
            break :step debug.unwind(scratch_allocator.allocator(), link, .{ .registers = registers, .load_bias = module.bias, .user = &window, .read = Window.read }) catch |err| {
                result.reason = switch (err) {
                    error.NoUnwindInfo => .cfi_missing,
                    error.SignalFrameUnsupported => .signal_frame,
                    else => if (window.failed) .stack_window else .unsupported_cfi,
                };
                result.detail = @errorName(err);
                return result;
            };
        };
        frame.method = @tagName(step.method);
        const pc = step.caller[16] orelse {
            result.reason = if (step.outermost) .complete else if (window.failed) .stack_window else .registers_unavailable;
            return result;
        };
        const sp = step.caller[7] orelse {
            result.reason = .registers_unavailable;
            return result;
        };
        if (pc == 0) {
            result.reason = .complete;
            return result;
        }
        for (result.frames[0..result.count]) |old| if (old.pc == pc and old.sp == sp) {
            result.reason = .cycle;
            return result;
        };
        if (result.count == max_frames) {
            result.reason = .depth_limit;
            return result;
        }
        result.frames[result.count] = .{ .pc = pc, .sp = sp, .lookup_pc = pc - 1 };
        result.count += 1;
        registers = step.caller;
    }
}
test "captured memory reads cannot escape the saved window including overflow addresses" {
    var window = Window{ .start = 0x1000, .bytes = &.{ 1, 2, 3, 4 } };
    var out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try Window.read(&window, 0x1002, &out));
    try std.testing.expectEqualSlices(u8, &.{ 3, 4 }, &out);
    try std.testing.expectError(error.CapturedStackUnavailable, Window.read(&window, 0x1003, &out));
    try std.testing.expectError(error.CapturedStackUnavailable, Window.read(&window, 0xfff, &out));
    try std.testing.expectError(error.CapturedStackUnavailable, Window.read(&window, std.math.maxInt(u64), &out));
}
