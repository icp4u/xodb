# Native ARM64 hardware-watchpoint investigation

Standalone Linux UAPI probe for owned child processes. This does not modify or
exercise the production xodb watchpoint backend. Native results and integration
requirements: [report](../../docs/research/arm64-watchpoints.md).

From the repository root, with the user's host/resource authorization:

```sh
python3 -B tests/arm64-watchpoints/run.py --host jetty
```

The runner copies only `probe.c` into a new `~/Work/xodb-arm64-watch-*` directory
on the selected host, compiles with its existing GCC, and runs the probe. It
makes no package/policy changes. Compiler errors and probe failures propagate.
Local transcripts and source hashes go into a fresh `.work/arm64-watchpoints/`
subdirectory. Remote source/binaries remain as reproduction artifacts.

The probe deliberately asserts Jetty's measured four-slot data-watch capacity.
A different count on another CPU fails that host-specific expectation; it does
not establish missing hardware support. The probe also requires native ARM64
and the installed Linux headers. Its `TRAP_HWBKPT` constant fills the actual gap
in Jetty's glibc 2.27 headers using Linux's UAPI value 4.

All traced processes are forked children, with EXITKILL, bounded waits and
cleanup. One child creates an owned pthread; another execs this same probe.
The final 23 cases cover the 15 naturally aligned 1/2/4/8-byte ranges within
an eight-byte block, read/write access, removal, detach, capacity/rollback,
clone, exec, overlapping wide stores and pair stores. Every sampled value
requires a full successful `process_vm_readv`; a failed read never becomes zero.

The harness is C to test the installed kernel ABI without the Zig production
backend or debugger libraries. It is new project test code, not copied from
GDB or a kernel implementation. Single-stepping/rearming uses the requested
watch configuration; kernel register readback is logged as evidence.
