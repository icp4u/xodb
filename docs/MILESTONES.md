# xodb milestones

This plan names the brief's initial foundation **M0** and keeps its numbered
milestones as M1 onward. Target the current Linux workstation first. Changes to
the agreed direction go to the user before implementation.

| Milestone | Outcome | Completion evidence | Status |
| --- | --- | --- | --- |
| M0 — foundation | Runnable native debugger shell and external inspection | Real target state appears in the UI and MCP; fixture and private-display tests pass | Complete on this workstation |
| M1 — source debugging | Answer “why did this value change?” with a recorded experiment | Break on a source line, inspect a value, set a watchpoint, run, and explain the captured write | Complete for the workstation baseline; limits in M1.md |
| M2 — profiling and static navigation | Investigate CPU cost and execution flow in games and servers | Navigate samples and a flame graph to source/disassembly, correlate probes and allocations | In progress; static navigation, input and CPU flame graphs integrated |
| M3 — richer investigations | Correlate runtime objects, memory activity, and hypotheses | Evidence-backed object and causal views, runtime adapters, and dynamic type recovery | Planned |
| M4+ — demonstrated extensions | Remote Android/Linux targets, replay, other architectures, and deeper analysis | Select and prove individual workflows before adding broad scope | First native ARM64 and SSH/TCP remote GUI demos verified; other extensions exploratory |

## Portability goal: Omarchy on x86-64 and AArch64

User-confirmed sub-goal (2026-10-01): build a strong debugger and profiler for
Omarchy across x86-64 and AArch64, with the same source-debugging, profiling,
GUI and MCP workflows. Keep the current Linux workstation as the development
baseline while adding evidence from the available ARM64 machines.

| Host | Architecture / OS | Availability and evidence |
| --- | --- | --- |
| Current workstation | x86-64 / Linux | Existing implementation and regression baseline |
| `jetty` (NVIDIA Jetson) | AArch64 / Ubuntu 18.04.6, kernel `4.9.337-tegra` | 2026-10-01 coordinator run: real headless xodb passes native debugging/MCP checks; perf open succeeds; workstation remote GUI verified over SSH/TCP; native ARM GUI and profiling pending ([demo](REMOTE_DEBUGGING.md)) |
| Incoming M1 MacBook Air | AArch64 / planned Omarchy Linux | User expects delivery next week; installation and xodb validation pending |

Use the Jetson to establish native AArch64 target support: registers,
breakpoints/watchpoints, stepping, unwinding and perf sampling. Validate the
shared UI on each host's graphics stack when available. The M1 adds the intended
Omarchy environment on a second ARM64 hardware family. Track kernel and driver
capabilities per host rather than assuming parity from the CPU architecture.
Native ARM64 support and remote Android/Linux debugging have separate
acceptance work; SSH access provides a way to run tests on the Jetson today.

[T13](tasks/T13-aarch64-target.md) is delivered and reviewed: five local tests
and the ARM64 cross build were reproduced; the native register, breakpoint,
step, signal and watchpoint evidence comes from Grok's Jetson transcript.
[Review corrections](T13_AARCH64_REVIEW.md) cover sampling, failure reporting,
cleanup and unavailable reads. [T18](tasks/T18-aarch64-sampled-state.md) is also
delivered and reviewed: host ARM64 CFI lookup works; [adverse-input failures](T18_AARCH64_SAMPLING_REVIEW.md) still need correction.
The fresh Jetty check can open an ordinary-user perf event; this does not yet
validate sampled registers/stacks. The user-approved headless-first slice now
runs real xodb natively: registers, software breakpoints, source/instruction
steps, CFI/locals, MCP and owned-fixture attach/detach. [Demo and remaining ARM
work](ARM64.md). The [remote GUI](REMOTE_DEBUGGING.md) now works over SSH/TCP.
Hardware watches, profiling and a GUI rendering natively on ARM remain. The [dispatch plan](AGENT_TASKS.md#current-dispatch-update)
tracks owners. Host maintenance and new native runs remain separately coordinated.

## M0 foundation

Keep a working executable throughout development. Initial panes may show source
files and machine state without source-to-address mapping; M1 adds that mapping.

- [x] Zig 0.16 project with explicit platform, rendering, target, model, UI, and
  MCP boundaries.
- [x] Native Wayland window and Vulkan renderer, resize and clean shutdown.
- [x] FreeType/HarfBuzz text and a simple tiled source, assembly, threads,
  registers, and event workspace with keyboard controls.
- [x] Linux x86-64 launch, attach, interrupt, continue, detach, thread
  enumeration, register reads, and memory reads.
- [x] Typed semantic state with session/thread identity and ordered events.
- [x] Read-only MCP inspection through the same model as the GUI, usable with
  or without the GUI. Keep execution controls reserved for the human in M0;
  M1 introduces configurable agent execution scope.
- [x] Fixture tests for target lifecycle and inspection, protocol tests for
  MCP, and a graphical smoke test in a private headless compositor.
- [x] Document build/run commands, limitations, dependency provenance, findings,
  and potential uses for local or remote LLMs.

Acceptance: build from this workstation's installed dependencies, launch a
fixture into a stopped session, inspect its threads/registers/memory through
both interfaces, continue and interrupt it, attach/detach from a fixture, and
close the application without leaving owned debug targets or test compositors.

Resource coordination:
Keep automated GUI work on a private display. Keep caches, logs, generated
files, and backups in the workdir; back up existing files before editing them.

M0 validation on 2026-09-30: all 8 Zig tests passed; the real stdio MCP
integration passed; and the private Sway GUI test passed on the RTX 4090,
including shared GUI/MCP identity, continue/clone/pause, register inspection,
resize, and target cleanup. See [README.md](../README.md) for commands and
current limits, and [agent tasks](AGENT_TASKS.md) for parallel M1 preparation.

## M1 source debugging and agent experiments

- [x] ELF/DWARF normalization, source and symbol breakpoints, CFI stack unwinding.
- [x] C/C++ scalar, pointer, struct, array and basic expression inspection;
  explicit unavailable/unsupported results for richer cases.
- [x] [T19 local GUI expression entry and bounded watch list](M2_EXPRESSION_WATCH_PROPOSAL.md),
  with shared MCP evaluation, expansion/paging, stale values and explicit frame
  identity limits.
- [x] Instruction stepping, source stepping and step over, hardware watchpoints.
- [x] Configurable agent observation, execution-control, and target-mutation
  scope; generation checks, human revocation, and action audit.
- [x] Recorded write investigations: before/after samples, thread, registers,
  frames, locals, source, and derived preceding-instruction attribution; JSON
  export that preserves existing files.
- [x] Deterministic GCC/Clang DWARF 4/5 at O0/O2 compared with GDB; C++ values,
  stripped CFI, malformed info, and a private-display GUI experiment.

Validation and limitations are recorded in [M1.md](M1.md). This is the local
x86-64 baseline. It does not imply broad optimized-language, signal-frame,
remote-target, or large-program performance coverage. T03/T05 findings and the
user-approved visual patch are integrated; regression evidence and remaining
limits are in [M1.md](M1.md#review-integration).

## M2 profiling and static navigation

[T04 workloads](tasks/T04-profiling-workloads.md) are delivered by Claude and
reviewed; the research and saved results cover controlled frame stalls and server
queue/lock pressure. [T06 collection](tasks/T06-perf-sampling.md) is delivered by Grok and
integrated with bounded CPU captures, flame graphs and MCP. [T07 input/cursors](tasks/T07-wayland-input.md) is integrated with the
user’s active-layout-only policy; its fallback proposals remain deferred. Shared
model, source links, UI and MCP integration stay with Codex.
These packets prepare M2; they do not establish its acceptance gate.

T10, T14, T15 bounded storage and [T16 derived-stack views](tasks/T16-derived-stack-views.md)
are integrated. [T17 syscall context](tasks/T17-syscall-context.md) is delivered
and reviewed; its production collector remains pending. Codex owns shared integration.

- [x] Bounded user CPU sampling, native flame graphs, source/assembly links,
  thread/time filters through MCP, loss/partial-stack reporting and capture
  identity. [Demo, tests and current limits](PROFILING.md).
- [x] Continue captures across observed executable mapping changes with retained
  ELF identities and timestamped attribution; expose unobserved munmap/mremap
  limitations. [Approved design and validation](M2_MAPPING_PROPOSAL.md).
- [x] Shared CPU timeline model/MCP, exact range/thread filtering, debugger
  markers and conservative scheduling reconstruction. [Contract and tests](M2_TIMELINE.md).
- [x] Visual timeline linked to CPU flames: select a time range/thread, with
  opt-in scheduling lanes and explicit unknown intervals. T08 (Grok) and T09
  (Fable/Claude, Opus 5.5) are integrated with the user-approved layout.
  [Validation and remaining acceptance work](M2_TIMELINE.md).
- [x] Imported application frame/request intervals linked to timeline filters,
  with source provenance, guarded MCP import and a T04 CSV converter.
- [x] Portable Speedscope aggregate export with CPU/scheduling/interval evidence,
  filtered MCP output and optional save on shutdown.
- [x] Native capture save/reopen with immutable origin/evidence, recorded symbol
  annotations, explicit analysis identity and bounded asset loading. Archive I/O
  and offline flame rebuilds use a cancellable worker; no durability syncs.
  [Workflow, validation and limitations](M2_ARCHIVES.md).
- [x] T10 opt-in sampled registers/stacks, configurable 32 MiB retention, raw
  evidence archive extension, MCP coverage and background per-sample DWARF
  reconstruction. [Workflow and validation](M2_SAMPLED_UNWIND.md).
- [x] T16 native sample inspector and explicitly selected reconstructed flame
  views, with missing/partial coverage, stack presets and MCP sample citations.
  User-approved; [workflow](M2_SAMPLED_UNWIND.md) and
  [critical review/test evidence](M2_DERIVED_VIEW_PROPOSAL.md).
- [x] T14 capture setup panel: duration/rate, explicit thread subsets, scheduling,
  active/next separation and readable stop diagnostics; user-approved interactions.
- [x] T15 compact sample storage, with verified T10 ownership and identical
  archive/view evidence. [Measurements and limits](M2_CAPTURE_SCALING.md).
- [x] Live recorded flame builds on a snapshot worker, with explicit lag labels,
  stable MCP polling/pages and deferred capture reclamation. User-approved;
  [contract, 157 tests and live measurements](M2_RECORDED_VIEW_PROPOSAL.md).
- [x] User-approved configurable sample ceiling, 1–65,536 (default 16,384), with
  live recorded views and archive 2.4 for nondefault limits. [Tests and bounds](M2_CAPTURE_LIMITS_PROPOSAL.md).
  Streaming retention and larger defaults remain future choices.
- [x] New same-process threads join all-thread captures at their initial debugger
  stop; fixed subset scope, configurable ring memory, exited-ring reclamation and
  archived enrollment evidence. [Evidence](research/dynamic-threads.md).
- [x] Fair bounded thread-ring draining and preserved stop causes, with owned
  task-creation/mapping-burst checks and 640-thread regression coverage.
  [Evidence and remaining scope limits](research/capture-robustness.md).
- [x] Initial scoped syscall timing and allocator uprobes, GUI/MCP evidence,
  selected time/thread filters and explicit permission/gap handling.
  [Syscalls](SYSCALL_TIMING.md) / [allocations](ALLOCATIONS.md).
- [ ] Allocation call stacks, archives/comparisons and representative workload
  overhead evaluation beyond the validated owned-fixture scope.
- [x] Bounded static x86-64 function graphs, GUI block selection linked to
  source/assembly, and observe-scope MCP queries. [Demo and limits](M2.md).
- [x] Initial function-range recovery from DWARF when ELF symbols are absent or
  unsized, with explicit fragment provenance; normalized typed instruction
  operands/register effects through MCP. [Scope and tests](M2.md).
- [x] Basic Rust/Zig slice and byte/text previews, named enums and paged aggregate
  inspection; [tested scope and unsupported layouts](M2_VALUES.md).
- [ ] Broader function recovery without compiler bounds, executable analysis IR,
  and richer language/runtime visualization.
- Measure event loss, collection overhead, UI responsiveness, and usefulness on
  representative games and high-performance servers selected during development.

## M3 richer investigations

- Deeper BPF collection, memory heatmaps, object and causal graphs.
- Runtime adapters including CPython; inferred types with explicit provenance.
- Static and dynamic evidence that supports or rejects an agent's hypotheses.
- Evaluate local/remote model assistance against concrete investigation tasks.

## M4 and later candidates

Remote debugging is an explicit eventual goal (user update, 2026-09-30), with
Android a priority and serial/network access to any Linux host. Plan for a
remote target service and transport boundary, architecture-specific register and
breakpoint support (especially AArch64), module/source transfer, and reliable
stop identity across disconnects. Evaluate Android access and deployment on a
real device before selecting its transport. The first workstation remote GUI
now uses MCP over SSH or TCP to a headless target-side xodb. That path also
passed a native-executable GUI demo on the Pixel through an ADB TCP forward;
broader Android access and serial protocols remain open.

Keep target addresses separate from host addresses, generation checks in the
semantic API, and platform control behind the target boundary. Local x86-64
and initial native ARM64 debugging now work, with SSH/TCP remote GUI control;
APK-native access, ART/Java, serial transport and reconnect remain separate
acceptance work.

Replay/rr interoperability, remote debugging, AArch64/RISC-V, core dumps,
kernel instrumentation, heap snapshots, lock analysis, network/protocol
causality, fuzzing, decompilation, and patch experiments remain candidates.
Promote individual workflows when their value is demonstrated.


## Near-term Lua scripting — milestone open

Requested 2026-10-01 as a future feature:

- Lua bindings to the shared debugger model, including `dbg.eval()` for expression
  evaluation and other inspection/automation operations.
- Configurable preferences, scripting behavior, execution/resource limits and
  allowed operations; keep concrete keys and defaults open for later review.
- Possible MCP access to the same bindings, preserving session scope, generation
  checks and action auditing.

Runtime choice, embedding, hooks, persistence and the exact API remain open.
Prioritized for near-term work on 2026-10-02; implementation assignment and
concrete API review remain open.


## Future display and architecture work

Requested 2026-10-01. These are future tasks; implementation milestones and
owners remain open.

- [x] **Startup themes:** semantic colors, built-in presets and explicit JSON loading
  across local, remote and offline GUI views. [Workflow and limits](THEMES.md).
- [ ] **Skinnable, flexible display (near-term priority):** fonts, scaling and
  density; flexible pane arrangement, resizing, visibility and saved layouts.
  Review concrete interactions and preference keys before adopting them.
- [x] **Initial AArch64 data watches:** native thread lifecycle, internal access
  completion, cleanup, write investigations and remote GUI controls verified
  ([evidence/limits](research/arm64-watchpoints/integration.md)).
- [ ] **AArch64 feature coverage:** refine multi-watch attribution and validate
  modern ARM kernels/hardware; extend profiling, sampled stacks,
  archive support, native GUI and remote controls. Build on T13/T18 and Claude's
  current build work. Track each feature's native evidence on Jetty and, when
  available, the M1 Omarchy system.
- [ ] **Additional architectures:** investigate targets beyond x86-64/AArch64,
  with RISC-V as one candidate. Compare useful workloads, hardware/emulator
  access, Linux register/debug interfaces, stepping, watchpoints, unwinding,
  disassembly, perf and build dependencies. Recommend a first demonstrable
  debugging slice and its cost. Distinguish cross-build, emulator and native
  evidence; evaluate capabilities with the necessary permissions/configuration
  before declaring them unavailable.

## Periodic agent reassessment of unmet wants

- [ ] Establish a recurring review of what users want to accomplish and what
  xodb is failing to help them do, including gaps absent from the current plan.
- Proposed cadence: milestone boundaries and roughly weekly during active
  development, performed in a working session. Calendar automation is open.
- Compare user feedback, failed or awkward demos, deferred findings, and
  [current capabilities](../DAY1.md) against the roadmap. Include large games,
  high-performance servers, Omarchy, ARM64, remote debugging and agent workflows.
- Ask: **What should we be doing that we are not doing?** Consider missing
  workflows, friction, performance, reliability, and places where local or
  remote LLM assistance could be useful.
- Record a short dated review in `docs/research/`: ranked gaps, supporting
  evidence, expected benefit, likely cost, and a small next experiment. Mark
  hypotheses and identify stale assumptions or work that should be deferred.
- Carry unresolved items into the next review and check whether adopted changes
  actually improved the workflow. Run proposed changes of direction by the user
  with the standing short critical analysis before adopting them.

### Android native executable progress (2026-10-02)

The approved isolated Pixel probe passed registers, memory reads, stepping
and hardware write watchpoints without root (four data-watch slots).
[Device evidence and Android/Bionic service plan](ANDROID_NATIVE_PLAN.md).
The [Android/Bionic headless build](research/android-native-build.md) now passes
locally. The separately approved full service test also passed on the Pixel:
source/stack/locals/eval, source stepping and two hardware writes through MCP
over ADB stdio, followed by process/file cleanup. The approved desktop GUI
follow-up also passed over a loopback ADB forward: stepping, source breakpoints,
locals/registers, caller selection, hardware watches and disconnect cleanup.
[Run the Android demo](ANDROID.md). Rootless CPU profiling of a debuggable app
is also verified: the existing debug app install records with simpleperf and opens
in xodb through a separate host conversion. Imported period-weighted flames,
time/thread filters, sample inspection and read-only MCP queries are integrated.
[Workflow and limits](SIMPLEPERF_IMPORT.md). The approved ANDROID_APPS.md
now passes APK-native source breakpoints, locals/eval, stepping and hardware
watches through app-UID ADB stdio and the desktop GUI, with clean detach.
APK-offset loading is now verified below; ART/Java inspection and reconnect remain
separate work.

### APK library and explicit companions (2026-10-02)

[Adopted APK mapping and debug-file workflow](DEBUG_SYMBOLS.md) passes host
breakpoint/locals/eval/watch/step tests for two libraries mapped from one archive,
including stripped libraries with full or debug-only companions. Native suite:
222 passed, 4 skipped; Android ARM64 cross-build passes. User approved the
CLI/workflow and the separate bounded Pixel test. Real Bionic loading, both
source breakpoints, stacks/locals/eval, hardware writes 100 -> 103 -> 106 and
source stepping pass; the owned child and all six files were cleaned up.
[Device evidence](ANDROID_APK_TEST_PLAN.md#pixel-result-2026-10-02).
The first explicit companion path is service-local, so Android use requires
staging selected build artifacts. A reusable app launcher is next.
