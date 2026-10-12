//! C seen by rendering, platform and UI code, and by the system collectors
//! whose snapshots the UI draws. Nothing here is the debug engine's: no ptrace,
//! ELF, DWARF or kernel headers (those are c.zig). A header that declares types lives in only one of the
//! two, so its types are the same everywhere.
const gui = @import("build_options").gui;

pub const api = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // glibc's fortified fcntl wrappers do not translate; ReleaseSafe defines it
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("dirent.h");
    @cInclude("time.h");
    @cInclude("sys/stat.h");
    @cInclude("../runtime/xrt_sysstat.h");
    @cInclude("../runtime/xrt_fdactivity.h");
    @cInclude("../runtime/xrt_fdflow_graph.h");
    @cInclude("../runtime/xrt_fdinherit.h");
    @cInclude("../runtime/xrt_fdtreemap.h");
    @cInclude("../runtime/xrt_memobserver.h");
    @cInclude("../text.h");
    if (gui) {
        @cInclude("vulkan/vulkan.h");
        @cInclude("freetype/freetype.h");
        @cInclude("hb.h");
        @cInclude("hb-ft.h");
    }
});
