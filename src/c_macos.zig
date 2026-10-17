//! Native metadata headers; Linux tracing and elfutils stay in c.zig.
pub const api = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/mman.h");
    @cInclude("capstone/capstone.h");
    @cInclude("../binary/macho.h");
    @cInclude("../binary/macho_job.h");
});
