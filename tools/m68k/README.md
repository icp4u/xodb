# Experimental m68k / Zig 0.18 xodb snapshot

This branch preserves the headless m68k experiment for reference. It is not
intended for merging into master. The source changes include architecture and
Zig 0.18 API adaptations, plus targeted workarounds for the compiler's limited
stack-frame support. Some substitutions are deliberately unconditional; this
snapshot does not preserve the host GUI or production architecture matrix.

## Validated configuration

- Compiler: patched Zig `0.18.0-dev.m68k.r2`.
- Target: Linux m68k, M68040, ELF32 big endian, GNU libc.
- Optimization: ReleaseSafe, single-threaded, non-PIC, large code model,
  frame pointers retained and compiler-generated unwind tables disabled.
- Linking: GNU ld, the matching compiler runtime, GNU libatomic, libdw/libelf,
  and an m68k-only Capstone build with its immediate-formatting repair.
- Small C wrapper headers are retained in `src/generated`. The experiment used
  translated target headers instead of inline C imports; the generated `.zig`
  bindings are deliberately omitted and ignored to keep this patch readable.
  They remain in the original external experiment. No regeneration script is
  included, so this branch requires those bindings before it can compile.

The compiler and dependency patches are managed separately. This branch records
xodb source only; compiler binaries, sysroot, external build/link drivers,
compiled objects, archives, VM configuration, logs and SSH credentials remain
outside git. The ordinary `scripts/build` / `build.zig` path has not been adapted
for this experimental toolchain. The original experiment's drivers use
`zig build-obj` followed by GNU ld; this is a preservation checkpoint, not an
integrated cross-build target.

The original object compilation uses these options, with external libc config,
sysroot headers, and a `build_options` module setting `gui = false`:

```text
-target m68k-linux-gnu -mcpu M68040 -O ReleaseSafe -lc
-fno-compiler-rt -mcmodel=large -fno-PIC -static -fsingle-threaded
-fno-unwind-tables -fno-omit-frame-pointer
```

## Recorded validation: 2026-10-04

The ReleaseSafe build completed a native m68k VM acceptance run with 66 MCP
requests: launch/exec stop; registers and register mutation/restoration; memory
reads/writes; invalid SR and odd-breakpoint rejection; symbols and disassembly;
software breakpoints, code overlays, policy serialization and ID round trips;
continue/trap-PC rewind; instruction stepping; numeric stack addresses and
`leaf -> middle -> main` unwinding; source breakpoints, locals and expressions;
source stepping; finish-frame; and process exit. MCP startup/EOF and owned-target
cleanup also passed. These results apply to the original experimental build;
importing the sources into this branch does not constitute a new VM test run.

Validated binary SHA-256:
`73dcbab2f4860d321c03ad68eac782218e253709e49e39036c14db896feeb842`.

## Limits

CPU/allocation/syscall profiling, hardware watchpoints, extended FP/vector
registers, process-family following, worker-based archives/comparisons and
composite DWARF bit pieces remain unsupported. Built-in stack tracing and the
segfault reporter are disabled in favor of the small panic handler. Large
static frames remain a compiler limitation; several large buffers and two
137,216-byte breakpoint-policy temporaries were moved off the stack or accessed
by reference. Broader and optimized workloads have not been validated.
