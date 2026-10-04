# xodb — Day 1 features

Historical snapshot; later additions and current limits are documented in
[README.md](README.md) and the linked feature guides.

Implemented as of 2026-10-01. Local GUI and profiling features below describe
the Linux x86-64 build; ARM64 and remote support have separate limits.

## Platforms and operation

- Native Linux debugger, written in Zig.
- Wayland GUI with Vulkan rendering and FreeType/HarfBuzz text.
- GUI, headless MCP, or local GUI and MCP sharing one session.
- Linux x86-64 workstation support
- Native ARM64 headless debugging
- Headless build option; cross-build script
- Command-line launch with program arguments or attach to an existing PID.

## Process control

- Continue, interrupt, detach, and inspect individual threads.
- Instruction stepping, instruction step-over, source stepping, and source step-over.
- Instruction fallback when the executing frame has no source mapping.
- Software breakpoints by address, symbol, or source file/line.
- Breakpoint removal, rearming, and original-instruction restoration.
- Thread creation, exit, signal stops, and executable replacement events.
- Support for worker-thread exec and a main thread exiting before its workers.
- Detach preserves the process; closing kills launched targets and preserves attached targets.
- One process and its threads per session; up to 1,024 threads.

## Code, stack, and values

- ELF module enumeration, symbol lookup, and relocated runtime addresses.
- DWARF source locations, types, variable locations, and CFI stack unwinding through libdw.
- GCC/Clang DWARF 4/5 support on the workstation; older libdw limited to DWARF 4.
- Source and assembly views with current-location highlighting.
- Stack selection updates source and locals for the selected frame.
- Named general-purpose register reads and raw target-memory reads through MCP.
- C/C++ scalar, floating-point, pointer, struct, and array inspection.
- Simple expressions: fields, dereferences, indexing, arithmetic, comparisons, bitwise operations, and `$register` values.
- Expression evaluation and paged aggregate children through MCP; no target function calls.
- Shallow struct-field expansion in local GUI locals.
- Named integer enums and basic Rust/Zig slice, byte, and text previews.
- Explicit optimized-out, unavailable, unsupported, and truncated results.
- Memory and register writes through MCP with mutate scope.

## Hardware watches and write investigations — x86-64

- Four hardware debug slots for write, read/write, or execution watches.
- Aligned 1/2/4/8-byte data watches; execution watches use one byte.
- Local GUI watch action for an addressable scalar or expanded field.
- Recorded write investigations with a question, expression, initial value, and captured writes.
- Captured thread, registers, frames, locals, source location, and before/after samples.
- Derived preceding-instruction attribution, distinguished from the observed stop PC.
- Investigation and action-audit export to a new JSON file.

## Static code navigation — x86-64

- Bounded function control-flow graphs with basic blocks and branch edges.
- Function bounds from sized ELF symbols or compiler DWARF ranges.
- Explicit unresolved transfers, assumed call returns, and split-function fragments.
- Graph block selection linked to source and assembly without executing code.
- MCP instruction inspection with typed operands and register read/write information.
- Static inspection only; no execution counts, decompiler, or complete instruction semantics.

## CPU profiling — x86-64

- Per-thread Linux perf sampling of user CPU execution and recorded user callchains.
- All current threads or an explicit subset; up to 1,024 selected threads.
- Configurable 1–1,000 Hz sampling; initial default 99 Hz.
- Configurable wall-clock deadline, including an until-stopped option; initial default 60 seconds.
- Capture setup panel for duration, rate, threads, scheduling, and sampled stacks.
- Separate current-capture settings and next-capture defaults.
- CPU flame graphs with inclusive/self sample counts, selection, zoom, and stack-depth scrolling.
- Time-range and thread filters shared by GUI and MCP.
- Source/assembly navigation from sampled frames, subject to available matching code.
- Live graph construction on a worker, with displayed/current snapshot and lag reporting.
- Approximate completed-capture user/kernel CPU totals for selected threads.
- Timestamped mapping history across observed library loads and executable mapping changes.
- Explicit unresolved addresses, partial stacks, loss, throttling, resource limits, and stop reasons.
- Automatic capture-stop and failure diagnostics on stderr.
- One retained capture, currently capped at 16,384 CPU samples.
- New tasks outside the opening scope, exec, metadata loss, and capacity exhaustion can stop collection.
- Thread-subset captures retain raw addresses because mapping coverage is incomplete.

## Timeline and application timings

- CPU sample histogram and per-thread timeline linked to flame filters.
- Drag-to-select time ranges, thread selection, range fitting, zoom, and filter reset.
- Optional scheduling transitions reconstructed into running, off-CPU, and unknown intervals.
- Debugger-stop and control-event markers.
- Import of application frame, request, or custom intervals through MCP.
- Imported interval overlays with labels, source provenance, and range selection.
- Converter for the supplied workload CSV timing files.
- Scheduling intervals report elapsed time; CPU flame widths count samples.

## Sampled stacks — x86-64

- Optional sampled registers and stack bytes; disabled by default.
- Configurable stack bytes per sample, up to 8 KiB; GUI presets off/1/4/8 KiB.
- Configurable retained-stack budget, up to 64 MiB; initial default 32 MiB.
- CPU samples and registers continue after stack retention fills, with explicit gaps.
- Background DWARF reconstruction from saved registers, stack bytes, and matching ELF data.
- Completed-capture switch between recorded and reconstructed flame graphs.
- Sample inspector comparing recorded callchains and derived frames.
- Sample navigation within the selected time/thread filter.
- Coverage counts, terminal reasons, and contributing sample citations through MCP.
- Reconstruction uses retained evidence without reading the target's current stack.

## Saved captures and exports

- Native capture save on shutdown or through a background MCP job.
- Offline capture reopening in GUI or headless MCP without a live target.
- Retained samples, mappings, scheduling, imported intervals, markers, settings, diagnostics, and optional sampled stacks.
- Recorded symbol/source-location annotations and binary identities.
- Offline time/thread filtering, flames, timeline, and raw sample inspection.
- Optional ELF assets matched by SHA-256 for assembly and sampled-stack analysis.
- Explicit symbol reanalysis with a separate analysis identity.
- Byte-preserving archive copies, including unknown optional sections.
- Artifact, view, and sample identities for citing evidence.
- Worker progress, cancellation, and bounded archive/view allocations.
- Speedscope JSON export of recorded-callchain aggregates, including filtered MCP exports.
- Source text and executable assets are not embedded in capture archives.

## MCP and agent control

- MCP 2025-06-18 tools over newline-delimited JSON-RPC.
- Stdio server and a one-client TCP server.
- Tool discovery and structured inspection of sessions, threads, modules, code, values, events, and captures.
- Debugger control, breakpoints, watchpoints, investigations, profiling, imports, and exports.
- Archive jobs, sampled-stack analysis, coherent remote GUI snapshots, and detach.
- Observe, control, and mutate scopes; ordinary MCP sessions default to observe.
- Human grant/revocation of agent execution control in the local GUI.
- Generation checks reject stale control requests; capture/view identities guard evidence queries.
- Action audit and bounded event history with sequence numbers.
- Polled asynchronous execution and analysis, with paged results and explicit pending/error states.
- External models and scripts use MCP; no embedded LLM.
- Diagnostics and target output go to stderr; MCP stdout contains JSON-RPC only.

## Remote debugging

- Workstation GUI controls a headless target-side xodb over SSH or direct TCP.
- Verified x86-64 GUI to ARM64 debugging over both transports.
- Remote launch or PID attach; continue, interrupt, detach, source/instruction stepping, and step-over.
- Remote source/assembly breakpoints, thread/frame selection, locals, and general-purpose registers.
- Target-side symbols, disassembly, unwinding, and expression evaluation through MCP.
- Explicit sharing of one source file with the GUI, capped at 48 KiB.
- Connection I/O and JSON decoding on a worker; rejected actions reported on stderr.
- Disconnected state retains a labelled last snapshot and disables execution controls.
- Plain TCP has no authentication or encryption; intended for a trusted LAN or loopback.
- One client per server session; no automatic reconnect or action replay.
- ARM64 hardware watches and profiling are not integrated; native ARM GUI rendering is pending.
- Remote GUI profiling, watchpoint controls, expression entry, and local MCP proxy are pending.

## Other current limits

- Fork/vfork process trees, reverse execution, replay, and core-dump debugging are not implemented.
- Signal-frame unwinding, split DWARF, separate debug-file discovery, and richer optimized values remain unsupported.
- Source stepping is instruction-driven and has an interruptible 10,000-instruction limit.
- Mapping history does not cover all unmaps, moves, JIT code, or in-place code changes.
- Syscall, allocation, wakeup, blocking-stack, and GPU tracing are not integrated.
- GUI expression watches, Lua scripting, Android, serial transport, and multi-client sessions remain pending.
- No saved/dockable layouts or general shortcut/theme editor.
