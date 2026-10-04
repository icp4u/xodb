const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui = b.option(bool, "gui", "Build the Wayland/Vulkan interface (disable for headless MCP)") orelse true;
    const font_path = b.option([]const u8, "font-path", "Default GUI font (runtime --font overrides this)") orelse "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const options = b.addOptions();
    options.addOption(bool, "gui", gui);
    options.addOption([]const u8, "font_path", font_path);
    module.addOptions("build_options", options);
    module.addIncludePath(b.path("src/profile"));
    module.addCSourceFile(.{ .file = b.path("src/profile/allocation_broker.c"), .flags = &.{"-std=c11"} });
    module.addCSourceFile(.{ .file = b.path("src/binary/mapped_file.c"), .flags = &.{"-std=c11"} });
    if (target.result.cpu.arch == .x86_64) module.addCSourceFile(.{ .file = b.path("src/target/xstate_layout.c"), .flags = &.{"-std=c11"} });
    for ([_][]const u8{ "capstone", "libdw" }) |lib| module.linkSystemLibrary(lib, .{});
    if (gui) {
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" });
        const xdg_header = header.addOutputFileArg("xdg-shell-client-protocol.h");
        const protocol = b.addSystemCommand(&.{ "wayland-scanner", "private-code", "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" });
        const xdg_code = protocol.addOutputFileArg("xdg-shell-protocol.c");
        module.addIncludePath(xdg_header.dirname());
        module.addCSourceFile(.{ .file = xdg_code, .flags = &.{} });
        // Cursor shapes. The generated code refers to the tablet protocol's interfaces, so that code is built too.
        const cursor_xml = "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml";
        const cursor_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", cursor_xml });
        module.addIncludePath(cursor_header.addOutputFileArg("cursor-shape-v1-client-protocol.h").dirname());
        for ([_][]const u8{ cursor_xml, "/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml" }) |xml| {
            const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml });
            module.addCSourceFile(.{ .file = code.addOutputFileArg(b.fmt("{s}.c", .{std.fs.path.stem(xml)})), .flags = &.{} });
        }
        for ([_][]const u8{ "wayland-client", "xkbcommon", "vulkan", "freetype2", "harfbuzz" }) |lib| module.linkSystemLibrary(lib, .{});
        for ([_][]const u8{ "vert", "frag" }) |stage| {
            const shader = b.addSystemCommand(&.{"glslc"});
            shader.addFileArg(b.path(b.fmt("src/render/ui.{s}", .{stage})));
            shader.addArg("-o");
            const spv = shader.addOutputFileArg(b.fmt("ui.{s}.spv", .{stage}));
            module.addAnonymousImport(b.fmt("{s}_spv", .{stage}), .{ .root_source_file = spv });
        }
    }
    const exe = b.addExecutable(.{ .name = "xodb", .root_module = module });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const app_step = b.step("app", "Build/install xodb without test fixtures");
    app_step.dependOn(&install_exe.step);
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
        const helper = b.addExecutable(.{ .name = "xodb-allocation-helper", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        helper.root_module.addCSourceFile(.{ .file = b.path("src/profile/allocation_broker.c"), .flags = &.{ "-std=c11", "-DXODB_ALLOCATION_HELPER" } });
        helper.root_module.addCSourceFile(.{ .file = b.path("src/binary/mapped_file.c"), .flags = &.{"-std=c11"} });
        const installed_helper = b.addInstallArtifact(helper, .{});
        b.getInstallStep().dependOn(&installed_helper.step);
        app_step.dependOn(&installed_helper.step);
    }
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run xodb").dependOn(&run.step);
    const fixture = b.addExecutable(.{ .name = "xodb-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    fixture.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/target.c"), .flags = &.{ "-g", "-O0", "-pthread" } });
    b.installArtifact(fixture);
    const m1 = b.addExecutable(.{ .name = "xodb-m1-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    m1.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/m1.c"), .flags = &.{ "-g", "-gdwarf-4", "-O0", "-fno-omit-frame-pointer" } });
    b.installArtifact(m1);
    const m2 = b.addExecutable(.{ .name = "xodb-m2-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    m2.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/m2.c"), .flags = &.{ "-g", "-gdwarf-4", "-O0", "-fno-omit-frame-pointer" } });
    b.installArtifact(m2);
    const profile = b.addExecutable(.{ .name = "xodb-profile-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true }) });
    profile.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/profile.c"), .flags = &.{ "-g", "-gdwarf-4", "-O2", "-fno-omit-frame-pointer", "-mno-omit-leaf-frame-pointer", "-fno-optimize-sibling-calls", "-pthread" } });
    b.installArtifact(profile);
    const lifecycle = b.addExecutable(.{ .name = "xodb-lifecycle-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    lifecycle.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/lifecycle.c"), .flags = &.{ "-g", "-O0", "-pthread" } });
    b.installArtifact(lifecycle);
    const process = b.addExecutable(.{ .name = "xodb-process-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    process.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/process-tree.c"), .flags = &.{ "-g", "-O0", "-fno-omit-frame-pointer" } });
    b.installArtifact(process);
    const tests = b.addTest(.{ .root_module = module });
    if (target.result.abi.isAndroid()) {
        if (gui) @panic("Android currently supports -Dgui=false only");
        const libdir = b.option([]const u8, "android-lib-dir", "NDK library directory for the selected Android API") orelse
            @panic("Android requires -Dandroid-lib-dir pointing to the NDK API library directory");
        // Android requires PIE; permit both 4 KiB and 16 KiB page kernels.
        for ([_]*std.Build.Step.Compile{ exe, fixture, m1, m2, profile, lifecycle, process, tests }) |artifact| {
            artifact.root_module.addLibraryPath(.{ .cwd_relative = libdir });
            artifact.pie = true;
            artifact.link_z_max_page_size = 16384;
        }
    }
    const test_run = b.addRunArtifact(tests);
    test_run.step.dependOn(b.getInstallStep());
    test_run.step.dependOn(&b.addSystemCommand(&.{"tests/fixtures/elf/build.sh"}).step);
    b.step("test", "Run unit and real target integration tests").dependOn(&test_run.step);
}
