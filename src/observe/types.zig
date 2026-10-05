//! Normalized invocation evidence. Process/image/clock identity belongs to the
//! owning observation job; these values never imply a typed function prototype.
pub const max_arguments = 6;
pub const max_stack_pcs = 32;
pub const Phase = enum { enter, leave };
pub const Stack = struct {
    pcs: [max_stack_pcs]u64 = @splat(0),
    len: u8 = 0,
    truncated: bool = false,
};
/// Original x86-64 PERF_SAMPLE_REGS_USER values, before ABI normalization.
/// The producer validates its accepted mask/layout and retains that mask/ABI.
pub const RawRegisters = struct {
    abi: u64,
    mask: u64,
    ax: u64,
    cx: u64,
    dx: u64,
    si: u64,
    di: u64,
    sp: u64,
    ip: u64,
    r8: u64,
    r9: u64,
};
pub const Sample = struct {
    phase: Phase,
    function_id: u32,
    /// Collector-normalized entry/return stack identity, nonzero and equal for
    /// a pair. Nested x86-64 frames have strictly smaller keys. A function name
    /// alone is never sufficient pairing evidence.
    stack_key: u64,
    ip: u64 = 0,
    args: [max_arguments]u64 = @splat(0),
    arg_count: u8 = 0,
    result: ?u64 = null,
    /// Actual captured PCs, independent of stack_key; absent when len is zero.
    stack: Stack = .{},
    raw_registers: ?RawRegisters = null,
    /// Original optional PERF_SAMPLE_STACK_USER bytes at entry SP. Only the
    /// first stack_word_valid bytes are evidence; a partial word is not a PC.
    stack_word: [8]u8 = @splat(0),
    stack_word_size: u8 = 0,
    stack_word_valid: u8 = 0,
};
pub const Event = struct {
    /// Stable debugger/producer identity within the owning process incarnation.
    thread_id: u64,
    tid: u32,
    time_ns: u64,
    data: union(enum) {
        sample: Sample,
        lost: u64,
        throttle,
        unthrottle,
        thread_exit,
        exec,
        mapping_change,
        fork,
        decode_error,
    },
};
pub const Reason = enum {
    pending,
    complete,
    missing_entry,
    capture_end,
    cancelled,
    stop,
    thread_exit,
    process_exit,
    exec,
    loss,
    throttle,
    decode_error,
    function_mismatch,
    stack_mismatch,
    stack_changed,
    time_reversed,
    nesting_limit,
    record_limit,
    thread_limit,
    memory_limit,
    identity,
    scope_changed,
    unread,
};
pub const Record = struct { ordinal: u32, event: Event };
pub const Call = struct {
    /// Stable zero-based ordinal within this store; never recycled.
    id: u32,
    thread_id: u64,
    tid: u32,
    function_id: u32,
    entry_record: ?u32 = null,
    return_record: ?u32 = null,
    parent_call: ?u32 = null,
    reason: Reason = .pending,
};
pub const Gap = struct { reason: Reason, record: ?u32 = null };
