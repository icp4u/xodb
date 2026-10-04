const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("syscall_obs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Syscall pairing and record tests").dependOn(&b.addRunArtifact(tests).step);

    const probe = b.addExecutable(.{
        .name = "probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("probe", "Task-scoped syscall probe").dependOn(&b.addInstallArtifact(probe, .{}).step);
}
