//! Recorded derived labels are separate from collector evidence and asset bytes.
const flame = @import("flame.zig");
const info = @import("../debug/info.zig");
pub const Key = struct { address: u64, mapping_id: u32, trusted: bool, ambiguous: bool };
pub const Record = struct {
    frame: flame.Frame,
    symbol_size: ?u64 = null,
    site: ?info.Site = null,
    source_error: []const u8 = "",
};
pub const resolver = "xodb-elf-symbols-libdw-lines-v1";
pub const basis = "derived at archive finalization from retained immutable ELF snapshots; source text not archived";
