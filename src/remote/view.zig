//! Versioned GUI snapshot; no host register layout or local process handles.
pub const Source = struct { path: []const u8, text: []const u8, truncated: bool = false };
pub const Site = struct { path: []const u8, line: u32 };
pub const Frame = struct { index: usize, pc: u64, symbol: ?[]const u8 = null, source: ?Site = null, diagnostic: ?[]const u8 = null };
pub const Thread = struct { id: u64, tid: i32, state: []const u8, reason: []const u8 };
pub const Register = struct { name: []const u8, value: u64 };
pub const Local = struct { name: []const u8, type: []const u8, display: []const u8, availability: []const u8, address: ?u64 = null, size: u64 = 0 };
pub const Instruction = struct { address: u64, mnemonic: []const u8, operands: []const u8 };
pub const Breakpoint = struct { id: u64, address: u64, source: ?Site = null };
pub const Watchpoint = struct { id: u64, address: u64, length: u8, kind: []const u8 };
pub const WatchHit = struct { tid: i32, id: u64, address: u64, pc: u64, trap_pc: ?u64, trap_address: ?u64, before: ?u64, after: ?u64, phase: []const u8, attribution: []const u8 };
pub const Diagnostic = struct { component: []const u8, message: []const u8 };
pub const View = struct {
    schema: u32 = 1,
    session_id: u64,
    generation: u64,
    pid: i32,
    architecture: []const u8,
    state: []const u8,
    scope: []const u8,
    owned: bool,
    tid: i32 = 0,
    frame: usize = 0,
    threads: []const Thread = &.{},
    threads_truncated: bool = false,
    frames: []const Frame = &.{},
    registers: []const Register = &.{},
    locals: []const Local = &.{},
    locals_truncated: bool = false,
    instructions: []const Instruction = &.{},
    breakpoints: []const Breakpoint = &.{},
    watchpoints: []const Watchpoint = &.{},
    watch_slots: ?u8 = null,
    watch_execute: bool = false,
    watch_hits: []const WatchHit = &.{},
    source: ?Source = null,
    diagnostics: []const Diagnostic = &.{},
};
