//! Private-state access used only for deliberate test fault injection.
comptime {
    if (!@import("builtin").is_test) @compileError("test-only runtime access");
}
pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("target_internal.h");
});
