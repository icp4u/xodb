const gui = @import("build_options").gui;

pub const api = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // glibc's fortified fcntl wrappers do not translate; ReleaseSafe defines it
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1"); // translate-c needs one ioctl declaration
    if (gui) @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("dirent.h");
    @cInclude("time.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
    @cInclude("sys/uio.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/file.h");
    @cInclude("sys/sysmacros.h");
    @cInclude("../runtime/mapped_file.h");
    @cInclude("../lsoftop/lsoftop.h");
    @cInclude("../runtime/xrt_sysstat.h");
    @cInclude("../runtime/xrt_fdactivity.h");
    @cInclude("../text.h");
    if (gui) {
        @cInclude("wayland-client.h");
        @cInclude("../platform/clipboard.h");
        @cInclude("xdg-shell-client-protocol.h");
        @cInclude("cursor-shape-v1-client-protocol.h");
        @cInclude("vulkan/vulkan.h");
        @cInclude("freetype/freetype.h");
        @cInclude("hb.h");
        @cInclude("hb-ft.h");
    }
    @cInclude("capstone/capstone.h");
    @cInclude("elfutils/libdw.h");
    @cInclude("../language/perl.h");
    @cInclude("../language/python.h");
    @cInclude("../language/javascript.h");
    @cInclude("../debug/metadata_job.h");
    @cInclude("../language/lua.h");
    @cInclude("dwarf.h");
});
