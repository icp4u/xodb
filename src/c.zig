//! C seen by the debug engine. Rendering, platform and UI code use c_ui.zig.
pub const api = @cImport({
    @cUndef("_FORTIFY_SOURCE"); // glibc's fortified fcntl wrappers do not translate; ReleaseSafe defines it
    @cDefine("_GNU_SOURCE", "1");
    @cDefine("BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD", "1"); // translate-c needs one ioctl declaration
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
    @cInclude("../text.h");
    @cInclude("capstone/capstone.h");
    @cInclude("elfutils/libdw.h");
    @cInclude("../language/perl.h");
    @cInclude("../language/python.h");
    @cInclude("../language/javascript.h");
    @cInclude("../debug/metadata_job.h");
    @cInclude("../binary/pe_job.h");
    @cInclude("../binary/macho.h");
    @cInclude("../binary/macho_job.h");
    @cInclude("../debug/pe_unwind.h");
    @cInclude("../language/lua.h");
    @cInclude("../language/watch.h");
    @cInclude("../language/ruby.h");
    @cInclude("../language/go.h");
    @cInclude("../language/go_map.h");
    @cInclude("../language/go_type_index.h");
    @cInclude("../language/jai_job.h");
    @cInclude("../language/elisp.h");
    @cInclude("../debug/dwarf_types.h");
    @cInclude("dwarf.h");
});
