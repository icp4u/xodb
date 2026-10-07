//! One C implementation for logical decoding, aggregation, JVM adaptation and JIT attribution.
pub const api = @cImport({
    @cInclude("../frames/bundle.h");
    @cInclude("../import/jvm_evidence.h");
    @cInclude("../profile/jitmap.h");
    @cInclude("stdlib.h");
});
