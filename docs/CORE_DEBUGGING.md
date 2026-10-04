# ELF core and crash inspection

Initial Linux x86-64 support, 2026-10-02.

```sh
zig-out/bin/xodb --core ./program.core
zig-out/bin/xodb --core ./program.core --exe ./saved-build/program
zig-out/bin/xodb --headless --mcp --core ./program.core
```

`--exe` is optional and supplies a relocated executable only when its build ID
matches captured evidence. `--debug-file`, local verified debug-file discovery
and `--source-map` also apply. Core mode cannot be combined with launch/attach,
profile import/archive loading or live capture/export options.

## Available inspection

- Recorded threads, general registers, stack, symbols, source, locals and
  side-effect-free native expressions through the normal GUI and MCP tools.
- **M** opens memory/search; **R** opens captured x87/XMM state.
- **I** inspects inline scopes when matching debug information is available.
- **C** opens stop/crash details: signal, kernel code, fault address, instruction
  location and the available mapping evidence. C also works on live stops.
- MCP `get_stop_info` takes `tid` and optional `generation`. For live targets it
  reports whether Continue would forward a pending application signal.
- MCP `get_core_info` reports the recorded process, command, signal and paged
  segment/file mappings. `mapping_start`, `segment_start` and `limit` select pages (16 by default, maximum 32).
- `get_session.mode` distinguishes `core`, `live`, `archive` and `imported` sessions. Recorded PIDs are
  identities in the dump; xodb does not attach to, wait for or control them.
- Continue, stepping, detach, restart, break/watchpoint installation, target
  writes and profiling return `ReadOnlyCore`. Closing only releases the dump
  and its local symbol resources. GUI execution controls are dimmed.

## Evidence and limitations

Memory reads use captured `PT_LOAD` bytes. Omitted ranges report
`CoreMemoryOmitted`; they are never zero-filled or borrowed from a live process.
Memory inspection can report partial readable ranges. The core stays open and
is read lazily; a changed size/timestamp produces `CoreFileChanged`. Keep it
stable during inspection.

Local ELF images are snapshotted and checked against build IDs from captured
ELF notes. Captured aliases of the same mapped file pages can supply a note
when its original virtual mapping was omitted. A filename alone is insufficient.
If identifying notes are absent, registers/memory remain usable but symbols,
source and CFI for that module may be unavailable. A mismatched explicit
executable is rejected. Shared libraries currently use their recorded local
paths; a general core library/sysroot remapping UI remains future work.

Signal notes remain associated with their thread. GDB can emit a SIGINFO note
for every thread; another thread's stop must not overwrite the faulting thread's
signal. A signal/fault address describes the stop, not its root cause.

Initial bounds: 4,096 program headers, 1,024 threads, 65,536 file mappings,
32 MiB of notes and 1,024 cached module-identity checks. Referenced ELF snapshots
use the existing 256 MiB per-image / 512 MiB total bounds. Reading a large dump
does not allocate its entire file. Metadata/first symbol loading is synchronous.

Supported core format is ELF64 little-endian Linux x86-64, with ordinary program
header counts and Linux/GDB status notes. Other core architectures, extended
program-header numbering, implicit split-DWARF loading and signal-trampoline
unwinding remain unsupported. Captured FP/XMM uses the portable legacy area;
extended XSAVE components are not decoded using the inspecting host's CPU layout.
The standalone native GUI has the new crash panel; remote MCP can query the
same backend, while the separate remote GUI does not yet have that panel.

## Reproduce

```sh
scripts/build -Doptimize=ReleaseSafe
python tests/core-debugging.py
python tests/core-gui.py zig-out
```

The first test uses GDB to generate a core from a new owned fixture, without
changing system core-dump settings. The second opens the latest fixture core in
a private headless compositor. Pass a core path as a second argument to choose
an existing test artifact explicitly. [Findings](research/core-debugging.md).
