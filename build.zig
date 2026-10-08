const std = @import("std");
const runtime_sources = [_][]const u8{ "gdb_packet.c", "gdb_link.c", "gdb_description.c", "gdbremote.c", "memory.c", "arch.c", "registers.c", "process.c", "target.c", "probes.c", "loongarch_step.c", "watchpoints.c", "events.c", "family.c", "xstate.c", "perf.c", "perf_cpu.c", "perf_syscalls.c", "perf_allocations.c", "wire.c", "wire_target.c", "agent.c", "remote.c", "files.c", "file_view.c", "symbol_job.c", "loader.c", "elf_symbols.c", "mapped_file.c", "perf_wire.c", "agent_perf.c", "remote_perf.c", "fdscan.c", "fdevent.c", "fdevent_decode.c", "fdevent_count.c", "fdactivity.c", "../profile/allocation_broker.c", "source.c", "../binary/object.c", "../debug/dwarf_cursor.c", "../debug/source_paths.c" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Helpers are copied to other machines: never inherit the build host ISA.
    var portable_query = target.query;
    portable_query.cpu_model = .baseline;
    portable_query.cpu_features_add = .empty;
    portable_query.cpu_features_sub = .empty;
    const portable_target = b.resolveTargetQuery(portable_query);
    const gui = b.option(bool, "gui", "Build the Wayland/Vulkan interface (disable for headless MCP)") orelse true;
    const capstone_link = b.option(enum { system, vendored }, "capstone", "Link system Capstone, or the private static prefix from scripts/build-capstone") orelse .system;
    const font_path = b.option([]const u8, "font-path", "Default GUI font (runtime --font overrides this)") orelse "/usr/share/fonts/TTF/DejaVuSansMono.ttf";
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const options = b.addOptions();
    options.addOption(bool, "gui", gui);
    options.addOption(bool, "capstone_vendored", capstone_link == .vendored);
    options.addOption([]const u8, "font_path", font_path);
    module.addOptions("build_options", options);
    module.addIncludePath(b.path("src/profile"));
    module.addIncludePath(b.path("src/runtime"));
    module.addIncludePath(b.path("src/service"));
    for ([_][]const u8{ "src/language/perl.c", "src/language/perl_layout.c", "src/language/python.c", "src/language/python_layout.c", "src/language/javascript.c", "src/language/javascript_layout.c", "src/language/javascript_ranged.c", "src/language/javascript_image.c", "src/binary/symbol_query.c", "src/binary/placement.c", "src/debug/metadata_job.c", "src/debug/cfi_image.c", "src/binary/object_cache.c", "src/binary/cache_pool.c", "src/debug/dwarf_index.c", "src/debug/dwarf_names.c", "src/language/lua.c", "src/language/lua_layout.c", "src/language/ruby.c", "src/language/ruby_layout.c" }) |source| {
        module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    }
    module.addCSourceFile(.{ .file = b.path("src/service/session.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    // lsof-top: a terminal view over the runtime's fd scanner (xodb --lsof-top).
    module.addCSourceFile(.{ .file = b.path("src/lsoftop/lsoftop.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    // Host-only whole-system observer (overview view and MCP); not part of the agent.
    for ([_][]const u8{ "src/runtime/sysstat.c", "src/runtime/sysstat_nvml.c", "src/runtime/memstat.c", "src/runtime/memstat_system.c", "src/runtime/memstat_process.c", "src/runtime/memstat_pages.c", "src/runtime/memstat_cells.c", "src/runtime/memobserver.c" }) |source|
        module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    // Static queries (src/semq) and the supervised ghx worker driver; the
    // Ghidra worker itself stays a separate, opt-in host tool (tools/ghx).
    module.addIncludePath(b.path("src/semq"));
    for ([_][]const u8{ "sha256.c", "xsq_mem.c", "xsq_graph.c", "xsq_query.c", "xsq_report.c", "ghx_host.c" }) |source| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/semq/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    for (runtime_sources) |source| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    module.addIncludePath(b.path("src/profile"));
    for ([_][]const u8{ "src/frames/bundle.c", "src/profile/logical_frames.c", "src/profile/jitmap.c", "src/import/jvm_json.c", "src/import/jvm_import.c", "src/import/jvm_query.c", "src/import/jvm_lframes.c", "src/import/sha256.c", "src/import/jvm_budget.c", "src/import/jvm_evidence.c" }) |source| {
        module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    }
    module.linkSystemLibrary("libdw", .{});
    switch (capstone_link) {
        .system => module.linkSystemLibrary("capstone", .{}),
        .vendored => {
            // Zig 0.16 filesystem calls take an Io. Existence is mode 0 (F_OK).
            const io = b.graph.io;
            b.build_root.handle.access(io, ".work/capstone/lib/libcapstone.a", .{}) catch {
                std.debug.print("vendored Capstone prefix is missing; run scripts/build-capstone\n", .{});
                std.process.exit(1);
            };
            b.build_root.handle.access(io, ".work/capstone/include/capstone/capstone.h", .{}) catch {
                std.debug.print("vendored Capstone prefix is missing; run scripts/build-capstone\n", .{});
                std.process.exit(1);
            };
            module.addIncludePath(b.path(".work/capstone/include"));
            module.addLibraryPath(b.path(".work/capstone/lib"));
            module.linkSystemLibrary("capstone", .{
                .use_pkg_config = .no,
                .preferred_link_mode = .static,
                .search_strategy = .no_fallback,
            });
        },
    }
    if (gui) {
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" });
        const xdg_header = header.addOutputFileArg("xdg-shell-client-protocol.h");
        const protocol = b.addSystemCommand(&.{ "wayland-scanner", "private-code", "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml" });
        const xdg_code = protocol.addOutputFileArg("xdg-shell-protocol.c");
        module.addIncludePath(xdg_header.dirname());
        module.addCSourceFile(.{ .file = xdg_code, .flags = &.{} });
        const primary_xml = "/usr/share/wayland-protocols/unstable/primary-selection/primary-selection-unstable-v1.xml";
        const primary_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", primary_xml });
        module.addIncludePath(primary_header.addOutputFileArg("primary-selection-unstable-v1-client-protocol.h").dirname());
        const primary_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", primary_xml });
        module.addCSourceFile(.{ .file = primary_code.addOutputFileArg("primary-selection-unstable-v1.c"), .flags = &.{} });
        module.addCSourceFile(.{ .file = b.path("src/platform/clipboard.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        // Cursor shapes. The generated code refers to the tablet protocol's interfaces, so that code is built too.
        const cursor_xml = "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml";
        const cursor_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", cursor_xml });
        module.addIncludePath(cursor_header.addOutputFileArg("cursor-shape-v1-client-protocol.h").dirname());
        for ([_][]const u8{ cursor_xml, "/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml" }) |xml| {
            const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml });
            module.addCSourceFile(.{ .file = code.addOutputFileArg(b.fmt("{s}.c", .{std.fs.path.stem(xml)})), .flags = &.{} });
        }
        for ([_][]const u8{ "wayland-client", "xkbcommon", "vulkan", "freetype2", "harfbuzz" }) |lib| module.linkSystemLibrary(lib, .{});
        for ([_][]const u8{ "ui", "cell" }) |name| for ([_][]const u8{ "vert", "frag" }) |stage| {
            const shader = b.addSystemCommand(&.{"glslc"});
            shader.addFileArg(b.path(b.fmt("src/render/{s}.{s}", .{ name, stage })));
            shader.addArg("-o");
            const spv = shader.addOutputFileArg(b.fmt("{s}.{s}.spv", .{ name, stage }));
            const import = if (std.mem.eql(u8, name, "ui")) b.fmt("{s}_spv", .{stage}) else b.fmt("{s}_{s}_spv", .{ name, stage });
            module.addAnonymousImport(import, .{ .root_source_file = spv });
        };
    }
    const exe = b.addExecutable(.{ .name = "xodb", .root_module = module });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const app_step = b.step("app", "Build/install xodb without test fixtures");
    app_step.dependOn(&install_exe.step);
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux) {
        const helper = b.addExecutable(.{ .name = "xodb-allocation-helper", .root_module = b.createModule(.{ .target = portable_target, .optimize = optimize, .link_libc = true }) });
        helper.root_module.addCSourceFile(.{ .file = b.path("src/profile/allocation_broker.c"), .flags = &.{ "-std=c11", "-DXODB_ALLOCATION_HELPER" } });
        helper.root_module.addCSourceFile(.{ .file = b.path("src/runtime/mapped_file.c"), .flags = &.{"-std=c11"} });
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
    const observations = b.addExecutable(.{ .name = "xodb-observation-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    observations.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/observations.c"), .flags = &.{ "-g", "-O0", "-fno-omit-frame-pointer", "-fno-optimize-sibling-calls" } });
    b.installArtifact(observations);
    const profile = b.addExecutable(.{ .name = "xodb-profile-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSafe, .link_libc = true }) });
    profile.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/profile.c"), .flags = &.{ "-g", "-gdwarf-4", "-O2", "-fno-omit-frame-pointer", "-mno-omit-leaf-frame-pointer", "-fno-optimize-sibling-calls", "-pthread" } });
    b.installArtifact(profile);
    const lifecycle = b.addExecutable(.{ .name = "xodb-lifecycle-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    lifecycle.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/lifecycle.c"), .flags = &.{ "-g", "-O0", "-pthread" } });
    b.installArtifact(lifecycle);
    const process = b.addExecutable(.{ .name = "xodb-process-fixture", .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
    process.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/process-tree.c"), .flags = &.{ "-g", "-O0", "-fno-omit-frame-pointer" } });
    b.installArtifact(process);
    const fd_fixture = b.addExecutable(.{ .name = "xodb-fd-fixture", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fd_fixture.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/fd-activity.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    b.installArtifact(fd_fixture);
    const tests = b.addTest(.{ .root_module = module });
    if (capstone_link == .vendored) {
        // The self-hosted Debug backend segfaults on the Capstone 6 translate-c output.
        exe.use_llvm = true;
        tests.use_llvm = true;
        // libcapstone.a is linked statically. A search path must not become a
        // RUNPATH; that would record the build tree in the binary.
        exe.each_lib_rpath = false;
        tests.each_lib_rpath = false;
    }
    const runtime_tests = b.addExecutable(.{ .name = "xodb-runtime-memory-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    runtime_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/memory.c", "tests/runtime-memory.c" }) |source| {
        runtime_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    }
    const register_tests = b.addExecutable(.{ .name = "xodb-runtime-register-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    register_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/arch.c", "src/runtime/registers.c", "src/runtime/loongarch_step.c", "tests/runtime-registers.c" }) |source| {
        register_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const process_tests = b.addExecutable(.{ .name = "xodb-runtime-process-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    process_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/arch.c", "src/runtime/process.c", "tests/runtime-process.c" }) |source| {
        process_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const target_tests = b.addExecutable(.{ .name = "xodb-runtime-target-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    target_tests.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source| {
        target_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    target_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-target.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const perf_tests = b.addExecutable(.{ .name = "xodb-runtime-perf-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    perf_tests.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source| {
        perf_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    perf_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-perf.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const fdscan_tests = b.addExecutable(.{ .name = "xodb-runtime-fdscan-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fdscan_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/fdscan.c", "tests/runtime-fdscan.c" }) |source| {
        fdscan_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const fdevent_tests = b.addExecutable(.{ .name = "xodb-fdevent-decode-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    const fdcount_tests = b.addExecutable(.{ .name = "xodb-fdevent-count-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/runtime/fdevent_decode.c", "tests/runtime-fdevent.c" }) |source|
        fdevent_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    for ([_][]const u8{ "src/runtime/fdevent_count.c", "tests/runtime-fdevent-count.c" }) |source|
        fdcount_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    const fdactivity_tests = b.addExecutable(.{ .name = "xodb-fdactivity-demand-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fdactivity_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/fdscan.c", "tests/runtime-fdactivity.c" }) |source|
        fdactivity_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    const fdactivity_live = b.addExecutable(.{ .name = "xodb-fdactivity-live", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fdactivity_live.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source|
        fdactivity_live.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    fdactivity_live.root_module.addCSourceFile(.{ .file = b.path("tests/fdactivity-live.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    b.installArtifact(fdactivity_live);
    const fdactivity_scope = b.addExecutable(.{ .name = "xodb-fdactivity-scope", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fdactivity_scope.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source|
        fdactivity_scope.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    fdactivity_scope.root_module.addCSourceFile(.{ .file = b.path("tests/fdactivity-scope.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    b.installArtifact(fdactivity_scope);
    const fd_events = b.addExecutable(.{ .name = "xodb-fd-events", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    fd_events.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/fd-events.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    b.installArtifact(fd_events);
    const gdb_packet_tests = b.addExecutable(.{ .name = "xodb-gdb-packet-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    gdb_packet_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/gdb_packet.c", "tests/runtime-gdb-packet.c" }) |source|
        gdb_packet_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    b.installArtifact(gdb_packet_tests);
    const gdb_link_tests = b.addExecutable(.{ .name = "xodb-gdb-link-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    gdb_link_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/gdb_packet.c", "src/runtime/gdb_link.c", "tests/runtime-gdb-link.c" }) |source|
        gdb_link_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    b.installArtifact(gdb_link_tests);
    const gdb_description_tests = b.addExecutable(.{ .name = "xodb-gdb-description-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    gdb_description_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/arch.c", "src/runtime/gdb_description.c", "tests/runtime-gdb-description.c" }) |source|
        gdb_description_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    b.installArtifact(gdb_description_tests);
    const gdb_model_tests = b.addExecutable(.{ .name = "xodb-gdb-model-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    gdb_model_tests.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source|
        gdb_model_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    gdb_model_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-gdb-model.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    b.installArtifact(gdb_model_tests);
    const wire_tests = b.addExecutable(.{ .name = "xodb-runtime-wire-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    wire_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/wire.c", "tests/runtime-wire.c" }) |source| {
        wire_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const agent = b.addExecutable(.{ .name = "xodb-agent", .root_module = b.createModule(.{ .target = portable_target, .optimize = optimize, .link_libc = true }) });
    const snapshot_tests = b.addExecutable(.{ .name = "xodb-runtime-snapshot-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_]*std.Build.Step.Compile{ agent, snapshot_tests }) |artifact| {
        artifact.root_module.addIncludePath(b.path("src/runtime"));
        for (runtime_sources) |source| artifact.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    agent.root_module.addCSourceFile(.{ .file = b.path("src/runtime/agent_main.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    snapshot_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-snapshot.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    const sysstat_tests = b.addExecutable(.{ .name = "xodb-runtime-sysstat-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    sysstat_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/sysstat.c", "src/runtime/sysstat_nvml.c", "tests/runtime-sysstat.c" }) |source| {
        sysstat_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const sys_services_tests = b.addExecutable(.{ .name = "xodb-runtime-services-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    sys_services_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/sysstat.c", "src/runtime/sysstat_nvml.c", "tests/runtime-services.c" }) |source| {
        sys_services_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    const memstat_system_tests = b.addExecutable(.{ .name = "xodb-runtime-memstat-system-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    memstat_system_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/memstat.c", "src/runtime/memstat_system.c", "src/runtime/memstat_process.c", "src/runtime/memstat_pages.c", "src/runtime/memstat_cells.c", "src/runtime/memobserver.c", "tests/runtime-memstat-system.c" }) |source|
        memstat_system_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const memstat_process_tests = b.addExecutable(.{ .name = "xodb-runtime-memstat-process-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    memstat_process_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/memstat.c", "src/runtime/memstat_system.c", "src/runtime/memstat_process.c", "src/runtime/memstat_pages.c", "src/runtime/memstat_cells.c", "src/runtime/memobserver.c", "tests/runtime-memstat-process.c" }) |source|
        memstat_process_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const memstat_cells_tests = b.addExecutable(.{ .name = "xodb-runtime-memstat-cells-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    memstat_cells_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/memstat.c", "src/runtime/memstat_system.c", "src/runtime/memstat_process.c", "src/runtime/memstat_pages.c", "src/runtime/memstat_cells.c", "src/runtime/memobserver.c", "tests/runtime-memstat-cells.c" }) |source|
        memstat_cells_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const memobserver_tests = b.addExecutable(.{ .name = "xodb-runtime-memobserver-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    memobserver_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/memstat.c", "src/runtime/memstat_system.c", "src/runtime/memstat_process.c", "src/runtime/memstat_pages.c", "src/runtime/memstat_cells.c", "src/runtime/memobserver.c", "tests/runtime-memobserver.c" }) |source|
        memobserver_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    const loader_tests = b.addExecutable(.{ .name = "xodb-runtime-loader-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    loader_tests.pie = false;
    loader_tests.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source| loader_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    loader_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-loader.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-fno-pie", "-Wall", "-Wextra", "-Werror" } });
    const install_agent = b.addInstallArtifact(agent, .{});
    b.getInstallStep().dependOn(&install_agent.step);
    b.step("agent", "Build the standalone C runtime agent").dependOn(&install_agent.step);
    app_step.dependOn(&install_agent.step);
    const test_step = b.step("test", "Run unit and real target integration tests");
    test_step.dependOn(&b.addRunArtifact(gdb_packet_tests).step);
    test_step.dependOn(&b.addRunArtifact(gdb_link_tests).step);
    test_step.dependOn(&b.addRunArtifact(gdb_description_tests).step);
    test_step.dependOn(&b.addRunArtifact(gdb_model_tests).step);
    const symbol_tests = b.addExecutable(.{ .name = "xodb-runtime-symbol-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    symbol_tests.root_module.addIncludePath(b.path("src/runtime"));
    for ([_][]const u8{ "src/runtime/elf_symbols.c", "tests/runtime-symbols.c" }) |source| {
        symbol_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    test_step.dependOn(&b.addRunArtifact(symbol_tests).step);
    const symbol_job_tests = b.addExecutable(.{ .name = "xodb-runtime-symbol-job-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    symbol_job_tests.root_module.addIncludePath(b.path("src/runtime"));
    for (runtime_sources) |source| symbol_job_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    symbol_job_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-symbol-job.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    test_step.dependOn(&b.addRunArtifact(symbol_job_tests).step);
    test_step.dependOn(&b.addRunArtifact(loader_tests).step);
    const loader_agent_run = b.addRunArtifact(loader_tests);
    loader_agent_run.addArtifactArg(agent);
    test_step.dependOn(&loader_agent_run.step);

    const frame_tests = b.addExecutable(.{ .name = "xodb-frame-bundle-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    frame_tests.root_module.addIncludePath(b.path("src/profile"));
    for ([_][]const u8{ "src/frames/bundle.c", "src/profile/logical_frames.c", "src/import/sha256.c", "src/import/jvm_budget.c", "tests/frame-bundle.c" }) |source_file| {
        frame_tests.root_module.addCSourceFile(.{ .file = b.path(source_file), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    test_step.dependOn(&b.addRunArtifact(frame_tests).step);
    const perl_tests = b.addExecutable(.{ .name = "xodb-perl-reader-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/perl.c", "src/language/perl_layout.c", "tests/perl-reader.c" }) |source| {
        perl_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    perl_tests.root_module.linkSystemLibrary("libdw", .{});
    test_step.dependOn(&b.addRunArtifact(perl_tests).step);
    const python_tests = b.addExecutable(.{ .name = "xodb-python-reader-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/python.c", "src/language/python_layout.c", "tests/python-reader.c" }) |source| {
        python_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    python_tests.root_module.linkSystemLibrary("libdw", .{});
    test_step.dependOn(&b.addRunArtifact(python_tests).step);
    const lua_tests = b.addExecutable(.{ .name = "xodb-lua-memory-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/lua.c", "tests/lua-memory.c" }) |source| {
        lua_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    test_step.dependOn(&b.addRunArtifact(lua_tests).step);
    const ruby_tests = b.addExecutable(.{ .name = "xodb-ruby-reader-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/ruby.c", "tests/ruby-reader.c" }) |source| {
        ruby_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    test_step.dependOn(&b.addRunArtifact(ruby_tests).step);
    const javascript_tests = b.addExecutable(.{ .name = "xodb-javascript-reader-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/javascript.c", "src/language/javascript_layout.c", "tests/javascript-reader.c" }) |source| {
        javascript_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    javascript_tests.root_module.linkSystemLibrary("libdw", .{});
    test_step.dependOn(&b.addRunArtifact(javascript_tests).step);
    const javascript_layout_tests = b.addExecutable(.{ .name = "xodb-javascript-layout-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    for ([_][]const u8{ "src/language/javascript_layout.c", "tests/javascript-layout.c" }) |source| {
        javascript_layout_tests.root_module.addCSourceFile(.{ .file = b.path(source), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
    }
    javascript_layout_tests.root_module.linkSystemLibrary("libdw", .{});
    const layout_run = b.addRunArtifact(javascript_layout_tests);
    for ([_][]const u8{ "good", "bad" }, 0..) |name, i| {
        const layout_fixture = b.addExecutable(.{ .name = b.fmt("xodb-javascript-layout-{s}", .{name}), .root_module = b.createModule(.{ .target = target, .optimize = .Debug, .link_libc = true }) });
        layout_fixture.root_module.addCSourceFile(.{ .file = b.path("tests/fixtures/javascript/layout.cc"), .flags = &.{ "-std=c++17", "-g", "-fstandalone-debug", "-fno-eliminate-unused-debug-types", if (i == 0) "-DWRONG_LAYOUT=0" else "-DWRONG_LAYOUT=8" } });
        layout_run.addArtifactArg(layout_fixture);
    }
    test_step.dependOn(&layout_run.step);
    const service_tests = b.addExecutable(.{ .name = "xodb-service-session-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    service_tests.root_module.addIncludePath(b.path("src/service"));
    for ([_][]const u8{ "src/service/session.c", "tests/service-session.c" }) |source_file| {
        service_tests.root_module.addCSourceFile(.{ .file = b.path(source_file), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
    }
    test_step.dependOn(&b.addRunArtifact(service_tests).step);
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .linux and !target.result.abi.isAndroid()) {
        const uprobes = b.addExecutable(.{ .name = "xodb-runtime-uprobes-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        uprobes.pie = false;
        uprobes.root_module.addIncludePath(b.path("src/runtime"));
        for (runtime_sources) |source| uprobes.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        uprobes.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-uprobes.c"), .flags = &.{ "-std=c11", "-fno-pie", "-UNDEBUG", "-Wall", "-Wextra", "-Werror" } });
        test_step.dependOn(&b.addRunArtifact(uprobes).step);
    }
    if (!target.result.abi.isAndroid()) {
        const probe_ids = b.addExecutable(.{ .name = "xodb-runtime-probe-ids-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        probe_ids.root_module.addIncludePath(b.path("src/runtime"));
        for (runtime_sources) |source| probe_ids.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
        probe_ids.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-probe-ids.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        const probe_ids_run = b.addRunArtifact(probe_ids);
        probe_ids_run.addArtifactArg(agent);
        test_step.dependOn(&probe_ids_run.step);
        const replies = b.addExecutable(.{ .name = "xodb-runtime-replies-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        replies.root_module.addIncludePath(b.path("src/runtime"));
        for (runtime_sources) |source| replies.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
        replies.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-replies.c"), .flags = &.{ "-std=c11", "-UNDEBUG", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
        const replies_run = b.addRunArtifact(replies);
        replies_run.addArtifactArg(agent);
        test_step.dependOn(&replies_run.step);
        const remote_tests = b.addExecutable(.{ .name = "xodb-runtime-remote-test", .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
        remote_tests.pie = false;
        remote_tests.root_module.addIncludePath(b.path("src/runtime"));
        for (runtime_sources) |source| remote_tests.root_module.addCSourceFile(.{ .file = b.path(b.fmt("src/runtime/{s}", .{source})), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wswitch-enum" } });
        remote_tests.root_module.addCSourceFile(.{ .file = b.path("tests/runtime-remote.c"), .flags = &.{ "-std=c11", "-fno-pie", "-Wall", "-Wextra", "-Werror" } });
        const remote_run = b.addRunArtifact(remote_tests);
        remote_run.addArtifactArg(agent);
        test_step.dependOn(&remote_run.step);
    }
    if (target.result.abi.isAndroid()) {
        if (gui) @panic("Android currently supports -Dgui=false only");
        const libdir = b.option([]const u8, "android-lib-dir", "NDK library directory for the selected Android API") orelse
            @panic("Android requires -Dandroid-lib-dir pointing to the NDK API library directory");
        // Android requires PIE; permit both 4 KiB and 16 KiB page kernels.
        for ([_]*std.Build.Step.Compile{ exe, fixture, m1, m2, observations, profile, lifecycle, process, fd_fixture, fdscan_tests, fdevent_tests, fdcount_tests, fdactivity_tests, gdb_packet_tests, gdb_link_tests, gdb_description_tests, gdb_model_tests, fdactivity_live, fdactivity_scope, fd_events, tests, runtime_tests, register_tests, process_tests, target_tests, perf_tests, wire_tests, agent, snapshot_tests, sysstat_tests, sys_services_tests, memstat_system_tests, memstat_process_tests, memstat_cells_tests, memobserver_tests, perl_tests, python_tests, lua_tests, ruby_tests, javascript_tests, javascript_layout_tests }) |artifact| {
            artifact.root_module.addLibraryPath(.{ .cwd_relative = libdir });
            artifact.pie = true;
            artifact.link_z_max_page_size = 16384;
        }
    }
    const test_run = b.addRunArtifact(tests);
    test_run.step.dependOn(b.getInstallStep());
    test_run.step.dependOn(&b.addSystemCommand(&.{"tests/fixtures/elf/build.sh"}).step);
    test_step.dependOn(&test_run.step);
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    test_step.dependOn(&b.addRunArtifact(register_tests).step);
    test_step.dependOn(&b.addRunArtifact(process_tests).step);
    test_step.dependOn(&b.addRunArtifact(target_tests).step);
    test_step.dependOn(&b.addRunArtifact(perf_tests).step);
    test_step.dependOn(&b.addRunArtifact(wire_tests).step);
    test_step.dependOn(&b.addRunArtifact(fdscan_tests).step);
    test_step.dependOn(&b.addRunArtifact(fdactivity_tests).step);
    test_step.dependOn(&b.addRunArtifact(fdevent_tests).step);
    test_step.dependOn(&b.addRunArtifact(fdcount_tests).step);
    test_step.dependOn(&b.addRunArtifact(snapshot_tests).step);
    test_step.dependOn(&b.addRunArtifact(sysstat_tests).step);
    test_step.dependOn(&b.addRunArtifact(sys_services_tests).step);
    test_step.dependOn(&b.addRunArtifact(memobserver_tests).step);
    test_step.dependOn(&b.addRunArtifact(memstat_cells_tests).step);
    test_step.dependOn(&b.addRunArtifact(memstat_process_tests).step);
    test_step.dependOn(&b.addRunArtifact(memstat_system_tests).step);
}
