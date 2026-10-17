//! Native presentation build. Linux keeps the full runtime build in build.zig.
const std = @import("std");

pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const deps = b.option([]const u8, "deps", "FreeType/HarfBuzz static prefix") orelse b.graph.environ_map.get("XODB_MAC_DEPS") orelse "tools/deps-prefix";
    const mvk = b.option([]const u8, "moltenvk", "MoltenVK directory containing include/ and dynamic/") orelse b.graph.environ_map.get("XODB_MAC_MOLTENVK") orelse "tools/moltenvk";
    const spv = b.option([]const u8, "shader-dir", "Precompiled shaders from this source tree (otherwise use glslc)") orelse b.graph.environ_map.get("XODB_MAC_SHADERS");
    const font = b.option([]const u8, "font-path", "Default GUI font") orelse "/System/Library/Fonts/Menlo.ttc";
    const capstone_link = b.option(enum { vendored }, "capstone", "Native builds use the private Capstone prefix") orelse .vendored;
    _ = capstone_link;
    const capstone = b.option([]const u8, "capstone-prefix", "Private static Capstone prefix") orelse b.graph.environ_map.get("XODB_MAC_CAPSTONE") orelse ".work/capstone";
    const module = b.createModule(.{ .root_source_file = b.path("src/macos_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const options = b.addOptions();
    options.addOption(bool, "gui", true);
    options.addOption(enum { wayland, x11, linux, cocoa, null }, "platform", .cocoa);
    options.addOption(bool, "capstone_vendored", true);
    options.addOption([]const u8, "font_path", font);
    module.addOptions("build_options", options);
    const coverage = b.addOptions();
    coverage.addOption([]const []const u8, "paths", &.{});
    coverage.addOption([]const []const u8, "sources", &.{});
    module.addOptions("overview_font_sources", coverage);
    module.addIncludePath(b.path("src/platform"));
    module.addIncludePath(b.path("src/runtime"));
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{capstone}) });
    module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libcapstone.a", .{capstone}) });
    for ([_][]const u8{ "cancel.c", "gdb_packet.c", "gdb_link.c", "gdb_description.c", "gdb_lldb.c", "gdbremote.c", "target_state.c", "file_identity.c", "arch.c", "loongarch_step.c", "riscv_step.c", "wire.c", "wire_target.c", "macos_debugserver.c", "../binary/macho.c", "../binary/macho_job.c", "../debug/macho_dwarf.c", "../debug/macho_object.c", "../debug/macho_unwind.c" }) |source|
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mvk}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/freetype2", .{deps}) });
    module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include/harfbuzz", .{deps}) });
    module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libfreetype.a", .{deps}) });
    module.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/libharfbuzz.a", .{deps}) });
    module.addCSourceFile(.{ .file = b.path("src/platform/cocoa_shim.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" } });
    for ([_][]const u8{ "src/platform/macos_process.c", "src/runtime/log.c" }) |source|
        module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    module.addCSourceFile(.{ .file = b.path("src/memset.c"), .flags = &.{ "-std=c11", "-fno-builtin", "-fno-sanitize=all" } });
    for ([_][]const u8{ "Cocoa", "QuartzCore" }) |framework| module.linkFramework(framework, .{});
    module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/dynamic/dylib/macOS", .{mvk}) });
    module.linkSystemLibrary("MoltenVK", .{ .use_pkg_config = .no });
    module.addRPath(.{ .cwd_relative = b.fmt("{s}/dynamic/dylib/macOS", .{mvk}) });
    const shaders = [_][3][]const u8{
        .{ "vert_spv", "ui.vert", "src/render/ui.vert" },                       .{ "frag_spv", "ui.frag", "src/render/ui.frag" },
        .{ "cell_vert_spv", "cell.vert", "src/render/cell.vert" },              .{ "cell_frag_spv", "cell.frag", "src/render/cell.frag" },
        .{ "scene_box_vert", "box.vert", "src/render/scene3d/box.vert" },       .{ "scene_point_vert", "point.vert", "src/render/scene3d/point.vert" },
        .{ "scene_line_vert", "line.vert", "src/render/scene3d/line.vert" },    .{ "scene_glyph_vert", "glyph.vert", "src/render/scene3d/glyph.vert" },
        .{ "scene_scene_frag", "scene.frag", "src/render/scene3d/scene.frag" }, .{ "scene_post_vert", "post.vert", "src/render/scene3d/post.vert" },
        .{ "scene_blur_frag", "blur.frag", "src/render/scene3d/blur.frag" },    .{ "scene_composite_frag", "composite.frag", "src/render/scene3d/composite.frag" },
    };
    for (shaders) |shader| {
        const binary: std.Build.LazyPath = if (spv) |dir| .{ .cwd_relative = b.fmt("{s}/{s}.spv", .{ dir, shader[1] }) } else binary: {
            const compile = b.addSystemCommand(&.{"glslc"});
            compile.addFileArg(b.path(shader[2]));
            compile.addArg("-o");
            break :binary compile.addOutputFileArg(b.fmt("{s}.spv", .{shader[1]}));
        };
        module.addAnonymousImport(shader[0], .{ .root_source_file = binary });
    }
    const exe = b.addExecutable(.{ .name = "xodb", .root_module = module });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    b.step("app", "Build/install the native macOS presentation client").dependOn(&install.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the native macOS client").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module, .filters = &.{ "Cocoa", "translated input", "remote " } });
    const check = b.step("test-cocoa", "Test Cocoa units and the native offscreen contract");
    const unit_run = b.addRunArtifact(tests);
    unit_run.setEnvironmentVariable("XODB_MAC_OFFSCREEN", "1");
    check.dependOn(&unit_run.step);
    const native_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    native_module.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{mvk}) });
    native_module.addCSourceFile(.{ .file = b.path("tests/cocoa-native.m"), .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Werror" } });
    native_module.addCSourceFile(.{ .file = b.path("src/runtime/log.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    for ([_][]const u8{ "Cocoa", "QuartzCore" }) |framework| native_module.linkFramework(framework, .{});
    native_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/dynamic/dylib/macOS", .{mvk}) });
    native_module.linkSystemLibrary("MoltenVK", .{ .use_pkg_config = .no });
    native_module.addRPath(.{ .cwd_relative = b.fmt("{s}/dynamic/dylib/macOS", .{mvk}) });
    const native = b.addExecutable(.{ .name = "cocoa-native", .root_module = native_module });
    const native_run = b.addRunArtifact(native);
    native_run.setEnvironmentVariable("MVK_CONFIG_LOG_LEVEL", "1");
    check.dependOn(&native_run.step);
    check.dependOn(&b.addInstallArtifact(native, .{}).step);
    const bundle = b.addSystemCommand(&.{ "/usr/bin/python3", "-B" });
    bundle.addFileArg(b.path("scripts/macos-bundle.py"));
    bundle.addFileArg(exe.getEmittedBin());
    bundle.addArg(b.fmt("{s}/dynamic/dylib/macOS/libMoltenVK.dylib", .{mvk}));
    bundle.addArg(b.getInstallPath(.prefix, "xodb.app"));
    b.step("bundle", "Package an ad-hoc signed native app with MoltenVK").dependOn(&bundle.step);

    const bootstrap_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    bootstrap_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "tests/macos-bootstrap.c", "src/runtime/macos_debugserver.c", "src/runtime/cancel.c", "src/runtime/gdb_link.c", "src/runtime/gdb_packet.c", "src/runtime/log.c" }) |source|
        bootstrap_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const bootstrap = b.addExecutable(.{ .name = "xodb-macos-bootstrap", .root_module = bootstrap_module });
    const bootstrap_check = b.step("test-debugserver", "Opt-in: test native debugserver bootstrap on owned fixtures");
    bootstrap_check.dependOn(&b.addRunArtifact(bootstrap).step);
    bootstrap_check.dependOn(&b.addInstallArtifact(bootstrap, .{}).step);
}
