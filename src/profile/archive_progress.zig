const std = @import("std");
pub const Phase = enum(u8) { idle, reading, encoding, annotations, decoding, assets, publishing, complete };
pub const Progress = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.idle),
    units: std.atomic.Value(usize) = .init(0),
    pub fn step(self: *Progress, phase: Phase, units: usize) !void {
        if (self.cancel.load(.acquire)) return error.ArchiveCancelled;
        self.phase.store(phase, .release);
        self.units.store(units, .release);
    }
};
pub fn step(progress: ?*Progress, phase: Phase, units: usize) !void {
    if (progress) |p| try p.step(phase, units);
}
