# xodb development journal

Record decisions, implementation findings, experiments, and opportunities for local
or remote LLM assistance here as development proceeds. Distinguish observations
from proposals and retain the evidence needed to revisit decisions.

## 2026-09-30 — scope and workstation baseline

### Confirmed direction

These decisions come from the user's responses to the initial review of
[TODO.md](../TODO.md) and the [project brief](../linux-ai-debugger-agents.md).

- The brief is the starting direction. Revisions are welcome, but run proposed
  changes by the user before adopting them.
- Target the current x86-64 workstation first. An Omarchy machine is
  available if needed; broader compatibility can follow working functionality.
- Prioritize development speed and a fast, responsive product. Profiling large,
  complex games and high-performance servers is an intended use case. No specific
  application has been selected yet.
- Initial C/C++ support may cover scalars, pointers, structs, and basic
  expressions. Keep a path to richer language support and visualization.
  RAD Debugger and LLVM may be used as references or sources of reusable code
  where appropriate.
- Start with external agents connected through MCP. Journal potential uses of
  local or remote LLMs as they emerge.
- Agents may control execution, with configurable limits on their scope. The
  distinction between observation, execution control, and target-state mutation
  remains part of the design. Details of human/agent coordination are still to
  be worked out.
- The result must remain distributable. A permissive project license is not
  required; GPL is acceptable. Favor useful existing components and development
  speed, and revisit dependencies when needed. The specific project license is
  not yet selected. Record dependency origins, versions, licenses, and local
  changes when adopting code. Ask the user before acquiring paid tools.

The brief's initial sequence remains the implementation starting point: a runnable
Zig application, Wayland/Vulkan UI with text and tiled panes, minimal target
control and semantic interfaces, read-only MCP inspection, and fixture tests,
followed by DWARF and source-level support. No architecture revision is proposed
by this entry.

### Candidate workloads

These are starting ideas, not selected benchmarks:

- A small deterministic C fixture with a known field mutation for validating
  breakpoints, stepping, locals, and a watchpoint investigation.
- A multithreaded server fixture with request queues, lock contention, and
  allocation pressure for later CPU and latency profiling.
- A game-like frame loop with worker jobs, asset loading, and occasional frame
  stalls for later timeline and profiler integration.

Small fixtures should establish correctness; actual large games and servers
will be needed to establish useful behavior at the intended scale.

### Potential LLM assistance

These are hypotheses to revisit once structured data is available, not new
milestone requirements. No local model or model service has been selected.

- **Experiment planning:** an external agent can turn a question about a value
  change into a watchpoint experiment, then cite captured events, frames, and
  values in its explanation. An earlier unrecorded mutation remains unknown
  unless a new experiment or other evidence explains it.
- **Profile interpretation:** a local or remote model could compare captures,
  identify candidate causes of frame stalls or request latency, and suggest
  measurements that distinguish those causes. Preserve event loss and sampling
  limits in the evidence supplied to the model.
- **Pattern and protocol analysis:** a model could suggest structures, field
  meanings, or message patterns from selected observations. Store those as
  hypotheses with provenance and validate them against additional observations.
- **Investigation summaries:** a model could summarize collected evidence and
  unresolved questions into durable investigation records linked to semantic
  entities and events.

Model assistance should build on deterministic parsing, debugging, and evidence
collection. Compare local and remote options using measured latency, result
quality, and the user's chosen data-sharing scope when a concrete use appears.

### Next implementation checks

- Compile and link a minimal program with the installed Zig and graphics stack.
- Exercise rendering in an isolated headless graphical session as required by
  `~/AGENTS.md`, using an execution environment with GPU access for hardware
  rendering and performance measurements.
- Keep the application runnable while introducing target control and its first
  deterministic fixture.

## 2026-09-30 — M0 implementation and handoffs

### Delivered

M0 now builds and runs with Zig 0.16.0. The executable has a native Wayland
window, a Vulkan renderer with a shaped FreeType/HarfBuzz glyph atlas, clipped
source/disassembly/register/thread/event panes, an adjustable divider, keyboard
controls, and toolbar execution controls. Capstone decodes real process bytes.
System libraries are linked rather than vendored; origins and observed license
labels are recorded in [DEPENDENCIES.md](DEPENDENCIES.md).

The target module supports one Linux x86-64 thread group: launch into an exec
stop, attach, clone discovery, interrupt/continue, register/memory reads, and
detach. It tracks stable session-local thread IDs and a bounded ordered event
history. The GUI and read-only stdio MCP server share the same session object;
headless MCP is also available. Agent execution-scope configuration remains M1.

The [milestone chart](MILESTONES.md) calls the brief's first task M0; source
mapping and the watchpoint investigation remain M1. The [README](../README.md)
contains manual and automated testing commands and known limits.

### Parallel work

The user has additional Grok/Claude resources. [AGENT_TASKS.md](AGENT_TASKS.md)
provides five unassigned packets with explicit file ownership, acceptance checks,
and handoff requirements. T01 implements ELF/symbol reading; T02 researches the
DWARF path. They can proceed together. Other packets cover target correctness,
profiling workloads, and UI/rendering review. Shared entry points, the build,
and the central journal remain with the integration owner to avoid collisions.

### LLM opportunities observed during M0

Structured errors such as `NotStopped`, `StaleSnapshot`, and `MemoryUnreadable`
give an agent useful evidence about why a query failed. A future agent planner
can use these to propose a next measurement or ask for execution scope without
inventing a value. The current external client can inspect the exact state the
human sees, which is the starting point for M1 investigations.

The thread-cleanup defect suggests a useful development role for models:
generate small competing lifecycle scenarios, then retain only those with
repeatable kernel-observable outcomes. Keep proposed causes separate from
confirmed reproductions in the audit packet.

## 2026-09-30 — M1 source debugging and write investigations

### Decisions and integration

T01 from Fable/Claude is integrated without editing its owned files. Its 13
inline ELF tests now run in the shared Zig test target. The session keeps
link/runtime addresses explicit, rejects TLS/absolute entries as ordinary
address symbols, binds mapped files by device/inode, and clears module/probe
state across exec.

T02 from Grok is reviewed. It recommends adapted Zig parsers and documents the
normalization boundary, DWARF forms, frame bases, location availability and a
compiler matrix. After reviewing that tradeoff, the user explicitly approved
**libdw for M1**. The new adapter uses installed libdw/libelf on the T01 module's
bytes; xodb owns process reads, addresses, expression evaluation, scope policy,
and semantic records. No libdwfl session/module ownership was introduced.
Provenance and header license notices are in DEPENDENCIES.md.

The user added remote debugging as an eventual goal, with Android a priority
and serial/network connections to Linux hosts. MILESTONES.md now names those
requirements. No transport was selected and the current backend is local x86-64.
T03 is now assigned to Grok and T05 to Fable/Claude; their owned paths remain
separate from integration work.

### Implemented and measured

M1 includes source/symbol/address breakpoints, transparent original instruction
bytes, rearming, instruction and source stepping, call step-over, all-thread
hardware watchpoints, CFI frames, basic C/C++ values and side-effect-free
expressions. The GUI follows source, selects frames, expands simple fields,
and starts a write investigation on a selected value. External MCP uses the
same session, configurable observe/control/mutate scope, generation checks,
human revocation notifications, and an action audit.

Investigations retain a question/expression, initial sample, observed write,
frames/registers/locals, and a derived preceding instruction/source location.
The export explicitly distinguishes post-instruction PC, sampled before/after
values, and the instruction derived by decoding from a function boundary.
`--record` exclusively creates a JSON export; it never replaces older evidence.

- Shared Zig suite: **27/27 passed**, including 13 T01 ELF tests.
- Original MCP protocol/lifecycle and M1 scoped-control/mutation tests passed.
- All eight GCC/Clang DWARF 4/5 O0/O2 fixtures passed source, stack, values and
  watched-write checks, compared with GDB.
- Source step/next, G++/Clang++ method/array/pointer/const values, stripped CFI,
  and malformed debug-info handling passed. 
- Private Sway/RTX 4090 GUI passed field selection, GUI-created watch
  investigation, source stepping, scope revocation, shared MCP observation,
  resize, saved evidence and cleanup.

One compiler difference mattered: GCC O2 omits the `next` local's location.
The test initially expected 12 everywhere. Inspecting its DIE showed no
location, and GDB reported optimized out. The expectation now checks that
availability explicitly; the remaining pointer/parameter expression still
computes 12. Clang's tested optimized local is available.

The completed baseline and exact limits are in M1.md. In particular, signal
frames, split DWARF, rich C++ types, composite locations, remote targets and
large-program performance are not covered. Source stepping is currently an
interruptible instruction loop. T03/T05 reviews are ongoing, not acceptance
claims folded into these test results.

### Concrete LLM opportunities

The retained experiment gives a local or remote agent enough structured
facts to explain why the field became 12: initial 7, watched write, `amount=5`,
`next=12`, frame `change_value`, caller `main`, and the mapped assignment.
A summary can cite event and investigation IDs and keep inferred instruction
attribution distinct from raw observations. The same record can be evaluated
against several models without allowing them to control the target again.

Explicit optimized-out/unavailable results matter for planning: a model can
choose a different expression, move the breakpoint, or watch a surviving field
rather than invent the missing local. Generation errors and scope denial also
give a deterministic reason to refresh or hand control to the human. No model
backend was added or contacted by the debugger.


## 2026-09-30: T03/T05 integration and next agent packets

The user reported both reviews complete, approved Claude's optional visual
patch, assigned T04 to Claude, and requested further external-agent packets.
Codex integrated the changes in shared files; the delivered review reports and
original repro results were preserved.

### Target findings and fixes

Grok reproduced unscoped waitpid consuming unrelated children, a zombie leader
blocking all-stop and memory access, detached-owned-child zombies, and stale
thread IDs after a worker's exec. Waiting/cleanup now sweep known TIDs only.
TRACEEXIT distinguishes a non-runnable exiting thread from the final exit wait
status. Memory and module maps use a stopped live TID. Worker exec preserves
the survivor's stable ID while invalidating peers and probes. Detached children
have a separate nonblocking reap list while the session lives.

The ptrace exit/exec model was checked against the primary
[Linux ptrace manual](https://man7.org/linux/man-pages/man2/ptrace.2.html).
ESRCH alone is not treated as proof of death. For an already-dead leader at
attach, `/proc` state confirms the zombie; live workers still undergo normal
permission checks. Seven new lifecycle cases exercise these boundaries,
including an unrelated traced child during target cleanup.

Reusing Grok's burst repro exposed another race: attaching while parents create
threads could miss a live child behind the directory cursor, or get EPERM on
a clone already seized by TRACECLONE. The first instrumented run had 19/20
successful attachments and three stable untraced threads. The fix interrupts
newly discovered threads promptly and rescans after all-stop; an already-seized
clone is accepted only after checking tracer and thread-group membership.
The same 20-round repro then passed 20/20, with zero missed/untracked/leftover
tracees. The regular suite also runs 20 such attach bursts.

The detached-zombie audit destroys the Target before killing the child, so that
particular test still observes a zombie until its own parent reaps it. A separate
regression checks the application's actual lifetime: detach, keep polling,
child exits, reap without new target events. A destroyed library object cannot
reap future exits for a still-running embedding process. Fork/vfork trees and
job-control group stops remain explicit limits; vfork interrupt still times out
while the child blocks its parent.

### Rendering, values and visual integration

Both Claude patches are integrated. Glyph lookup uses a direct table, pointer
motion redraws only when it affects hover/drag state, scrolling handles distance
and file bounds, tabs expand, selection remains visible, and swapchain resizes
retain compatible pipelines. The new style adds thread colors, stop animation,
rounded controls, selection borders and fading ellipses. The RAD Debugger MIT
notice is retained under `docs/licenses/`; no runtime dependency was added.

Integration also fixed renderer error propagation: a failed frame recreates the
renderer with a retry delay while the target and MCP keep running. A test-only
LD_PRELOAD wrapper rejects the second queue submission after its fence reset;
the application recreates the renderer, keeps the same target, and completes
the M1 GUI investigation. This proves the error path, not recovery from an
actual hardware GPU reset. Glyph exhaustion now logs once and uses a reserved
missing-glyph box. Source truncation has a visible header notice and source line
counts are cached. Input/cursor and HiDPI limitations remain documented.

A visual comparison caught a build defect missed by functional GUI checks:
shader filenames were ordinary command strings, so editing them did not
invalidate cached SPIR-V. The build now registers each shader with addFileArg.
After rebuilding, the actual screenshot matches the intended rounded controls
and border treatment. `docs/images/m1.png` now shows the integrated interface.

The function-entry locals issue was also reproduced: -O0 DWARF can describe a
stack argument slot before the prologue stores into it. Frame-relative values
in the entry line row now report PrologueNotComplete; optimized register
arguments remain available. All eight GCC/Clang × DWARF 4/5 × O0/O2 fixtures
pass this check and the existing post-prologue source/stack/watch/GDB comparison.
The guard is conservative and is not a full variable-initialization analysis.

### Validation

- Debug and ReleaseSafe: **35/35 tests each**. ReleaseSafe now builds after
  disabling untranslated glibc fortified wrappers in the Zig C import.
- Original MCP lifecycle/protocol/memory comparison and M1 control/mutation/
  stepping/C++/stripped/malformed tests passed.
- Eight compiler/debug-format variants passed; entry and watched-write RPC
- Styled GUI, injected Vulkan submit failure, renderer recreation, GUI watch,
  scope revocation, multiple resizes, export and cleanup passed on the private
  Sway/RTX 4090 session.
- A 3,322-supported-glyph source exhausts the 2,048-slot cache; the app then
  continues/pauses/inspects/resizes and cleans up successfully.

Reproduction commands and the remaining limits are in M1.md. GUI tests stayed
on private displays and all test-owned applications/compositors were closed.

### Next work and LLM opportunities

T06 is ready for Grok: a bounded perf_event_open collector with pure ring-parser
checks, explicit loss/timestamp/identity information and bounded live tests.
T07 is ready for Claude after T04: an ordered layout-aware input adapter, repeat
policy, cursor prototype and integration patch. They own separate paths; shared
session/UI/MCP/build integration stays with Codex. These packets were prepared
for the user to assign; Codex did not contact either external agent.

The new explicit unavailable values prevent an LLM from explaining random
pre-prologue stack bytes as real arguments. Structured lifecycle events can
also explain why a leader is exited while another worker remains inspectable.
For profiling, an external/local model can compare hot functions across T04
baseline/impaired runs, but must cite collection settings, loss, timestamps and
module identity. Capture review remains useful: visual comparison found the
stale shaders even though execution controls passed. No LLM service is embedded
in the debugger or needed by these tests.


## 2026-09-30 — M2 static function graphs and T04 handoff

The user handed T06 to Grok and T07 to Claude, then confirmed T04 complete and
T07 started. Codex kept shared files and implemented the planned static
navigation work. No new dependency or architecture revision was needed.

### Function graph model and navigation

The existing Capstone decoder now optionally requests detail for flow analysis.
Direct branch operands and instruction groups provide addresses and transfer
kinds; LOOP/LOOPE/LOOPNE need explicit handling. The installed Capstone headers
and its [C API documentation](https://www.capstone-engine.org/lang_c.html) were
checked. Ordinary disassembly keeps detail off. Empty output slices return
without asking Capstone to decode an unlimited number of instructions.

A declared ELF function range becomes address-ordered blocks with conditional,
unconditional, call, return, trap and system-continuation edges. Resolved block
edges, external addresses, indirect transfers, overlapping destinations and
decode gaps have distinct representations. Call and system continuations are
assumptions. Entry reachability follows known local edges plus assumed returns;
a block without such a path may still be reached by an unresolved transfer.
All of this is static possibility, without execution counts. Transactional
aborts, exceptions and nonlocal transfers remain outside this first model.

The Session adapter reads stopped live bytes through the existing software
breakpoint overlay and adds libdw source locations. Limits are 64 KiB, 4,096
instructions and 512 blocks, plus one executable mapping and a sized function
symbol. Errors identify unavailable/oversized functions. Incomplete decoding
reports remaining bytes. This is linear decoding, with no function recovery,
jump-table analysis or architecture-neutral IR yet.

Observe-scope MCP tool `get_function_graph` adds generation/image/module
identity, bounded block pages and edge provenance. It rejects running targets
and stale generations. The GUI's G/Flow control switches graph and assembly.
Clicking a block browses source and instructions without changing target state.
Gold PC markers and blue browsing diamonds distinguish the selections; locals
still belong to the selected stopped frame. Target generation changes clear
browsing. A separate view-toggle cache key preserves that stale-state check.

### Validation and evidence

- Debug and ReleaseSafe suites: **40/40 tests each** (five new graph cases).
  Tests include indirect transfers, loops/counter branches, call assumptions,
  invalid destinations, incomplete decode, overflow and each capacity limit.
- `python3 tests/m2-flow.py`: GCC/Clang × O0/O2, DWARF 5 PIE, all passed.
  GNU objdump independently checks block boundaries, terminators and direct
  destinations. Live MCP checks cover source links, pagination, INT3 overlay,
  scope, stale/running rejection and unchanged register/generation state.
- The first test incorrectly expected an emitted branch for each source if/loop.
  Clang O2 uses conditional moves and unrolls this fixture; the expectation now
  follows actual machine instructions. The graph correctly contains calls and
  returns without invented conditional edges in that variant.
- `python3 scripts/gui-smoke.py --graph`: passed on private headless Sway and
  RTX 4090. Reviewed source/assembly selection, fixed a gold browsing arrow to
  a blue diamond, checked PC preservation, scrolling, sizes from 500×360 to
  2560×1440, and shutdown cleanup.
- `python3 scripts/gui-smoke.py --m1`: source stepping, watched value,
  investigation export, human scope revocation, resize and cleanup passed.

Tests used the approved outside-sandbox workflow and private
displays. The installed executable was rebuilt in Debug after ReleaseSafe
verification. Reproduction and scope are in [M2.md](M2.md).

### T04 review and profiling implications

Reviewed Claude's workload source/scripts. These measurements were performed
by Claude, not rerun by Codex. T04 supplies bounded frame-loop and request-server
fixtures, known stall causes, timing ground truth, and baseline/impaired runs.
The research records perf/strace evidence and proposed acceptance thresholds.
They are useful inputs to integration, not proof that xodb profiling exists.

The key integration gap is blocked-time attribution. Claude could identify
synthetic frame stalls with combined observations, but unprivileged on-CPU
samples could not establish the server's lock-wait share. Stackful strace raised
calm-server latency dramatically while changing saturated throughput little.
Measure latency distributions as well as throughput and collection loss. Do not
change tracing permissions implicitly to satisfy a missing source.

GCC's frameless hot leaf and tail calls can remove the very function the sampler
should explain. T06 integration must preserve the unwinding method and capture
limits so incomplete stacks do not become confident causal claims. T04 also
provides monotonic frame markers for later time-window correlation. Its real
project shortlist remains unbuilt; large-game/server scalability is unproven.

### Local or remote LLM opportunities

- Explain the possible routes through a function and propose the next breakpoint
  or watchpoint, citing block addresses, stop generation and unresolved edges.
  Require runtime evidence before claiming that a route executed.
- Compare optimized disassembly with source and explain removed branches or
  missing physical frames. The Clang branchless fixture and T04 tail-call
  variant provide concrete checks against invented control flow/stack frames.
- Combine future sample hot spots with static callers/branches to suggest a
  follow-up experiment. Keep the graph's static provenance separate from sample
  timestamps, counts, loss and unwind quality.
- For T04 wait cases, say which evidence is unavailable and choose a measurement
  that distinguishes lock waiting, job waiting and I/O. Check explanations
  against workload ground truth instead of treating a plausible story as proof.

M2 remains in progress: T06 collection, sample/flame-graph integration, richer
tracing and the remaining static-analysis/value features are still pending.


## 2026-09-30 — T07 review: pause/resume and composed text

Claude delivered T07's adapter, integration patch and private-display tests.
The patch base hashes still match the current shared files. Its logical-letter
shortcut policy, modifier-chord behavior, navigation-only repeats and installed
libxkbcommon dependency have been presented to the user for adoption; application
integration is pending that decision. The standalone adapter remains available.

### Pause/resume defect fixed

Claude's headless `tests/stale-interrupt.py` failed on the current
binary: running, stopped, then stopped again after Continue. This was independent
of input delivery. Each collected stop called `interrupt()` on peers still
marked running in our model, even if their original kernel stop was already
pending. Attach enumeration also sent an interrupt and immediately sent another
through the shared all-stop path.

Each thread now tracks an outstanding interrupt request. All request paths use
one helper, which skips an outstanding request and auto-attached newborn threads
already awaiting their initial stop. Consuming a stop clears the request state.
The Linux [ptrace manual](https://man7.org/linux/man-pages/man2/ptrace.2.html)
documents the asynchronous interrupt and auto-attached clone stops. This fix
does not extend the existing limits for job-control/group stops or fork trees.

The same repro now reports running, stopped, running. Added an eight-cycle
repeated-pause/resume regression and verified resume immediately after attach.
The shared Debug suite passes **41/41 tests** including its existing burst-attach,
worker-exec and exited-leader cases. The M1 control and stepping scripts also
pass, covering breakpoint rearming, two watched writes, scope/mutations, source
stepping, C++ values and stripped/malformed debug information. All targets were
test-owned.

### Composed text defect fixed

A focused extra test found that dead acute followed by Ctrl+E committed `é`,
contrary to the adapter's contract that modified shortcuts produce no text.
The composition-success path bypassed the plain-key check. The adapter now
cancels pending composition on Ctrl/Alt/Logo chords before feeding the key.
A regression covers all three modifiers and verifies normal typing afterwards;
the standalone adapter suite passes **11/11 tests**.

### Further integration review

The queued-input patch also needs care around selections consumed by later keys
in the same batch, drag press/release coordinates, reporting overflow counters,
and releasing compositor-side input objects during capability changes. These
are integration checks, not reasons to replace the adapter. The cursor-shape
requests were verified by Claude, but private screenshots did not show cursor
pixels; retain that limitation until a visible-cursor check succeeds.

For an external/local LLM, a useful diagnostic is separating a lost input from a
successfully delivered command followed by a queued kernel stop. Require both
ordered input traces and target lifecycle events; a screenshot alone cannot
establish which subsystem caused the apparent ignored click.


## 2026-09-30 — T07 integrated with active-layout shortcuts

The user revised the proposed policy in `docs/research/input.md`: use only the
active layout’s unshifted keysym; defer searching other layouts and the physical
QWERTY-position fallback. Both fallbacks are removed from the adapter. ASCII and
function/editing/keypad keysyms are accepted, with ASCII letters lowercased for
bindings. Unrecognized keys and a missing keymap produce no shortcut identity.
The physical code and translated Unicode text remain separate fields.

Integrated Claude’s event queue, repeat scheduling, Wayland keyboard callbacks
and cursor-shape patch. Ctrl/Alt/Super chords do not invoke plain bindings;
Shift does not change a letter’s shortcut identity. Only J/K/arrows repeat.
The application now links the installed MIT libxkbcommon 1.13.2-1 and generates
cursor-shape/tablet protocol interfaces from installed wayland-protocols 1.49.
Dependency provenance is recorded in DEPENDENCIES.md. No package or system
input setting was changed.

### Integration fixes

- Refresh frame/thread-derived values after each queued action, so selecting
  another frame and pressing Watch in the same batch uses that frame’s locals.
  The first action retains the stale-snapshot check against the displayed state.
- Replay button press/release positions, including a whole drag between frames
  and a key preceding a pending drag release. Processing ends when Quit acts.
  Motion and wheel deltas remain coalesced after queued key/button events.
- Count and report queue overflow and keymap errors through stderr and UI status.
  A failed keymap leaves mouse controls available without inferred key bindings.
- Release keyboard/pointer/seat objects on the server when the bound protocol
  version supports release. Older versions use local destruction. The first
  seat is used; multiple-seat selection remains outside this increment.
- Preserve the already-tested composed-modifier fix and pause/resume correction
  from the prior review. No kernel permissions were changed.

### Verification

- **54/54 shared tests pass in Debug and ReleaseSafe.** This includes 11 input
  adapter tests plus two queued-workspace cases, alongside the 41 existing
  target/model tests. The invalid-keymap test deliberately emits an xkbcommon
  parser diagnostic; the test command exits successfully. The installed app
  was restored to Debug by the final Debug test build.
- **45/45 private-display checks pass** with `python3 scripts/input-smoke.py`.
  The runner reuses Claude’s scenarios against the current executable without
  applying/reversing an old patch. It explicitly checks Russian-only input,
  active Russian with an inactive French layout, switching French active,
  function keys, modifiers, dead keys, ordered fast input, held controls,
  repeat cancellation and cursor-shape requests. 
- The current-build runner uses pidfds and acts as a subreaper to clean up the
  target deliberately detached by its controls scenario. Test-owned targets,
  helper processes and private compositors are cleaned up.
- M1 private GUI step/watch/export/revocation/resize/cleanup regression passed.
- M2 private GUI graph/source/assembly browsing/resize/cleanup regression passed.
  The final capture preserves the blue browsing marker and the distinct stopped
  PC marker after input integration.

Cursor-shape requests (default → column-resize → default) are verified without
protocol errors. Cursor appearance remains **unverified**: captures with and
without the cursor are identical in this headless environment. A compositor
without cursor-shape support, seat-global removal, IME input and HiDPI remain
untested or unimplemented as documented in the research. No automated test used
the user’s interactive display.

### Agent-facing interpretation

A Cyrillic key with `shortcut = 0` is now expected behavior, even when another
Latin layout is configured. An LLM reviewing “Q did nothing” should cite the
active layout and event identity, and must not recommend silently restoring the
deferred fallback. Trace text alone does not establish a command; modifier and
shortcut fields plus the action/target event stream establish what acted.
Input trace collection remains opt-in through `XODB_INPUT_TRACE`.

T07 is integrated. T06 remains with Grok; CPU capture and flame-graph integration
are still pending within M2.


## 2026-09-30 — T06 integration: bounded CPU captures and native flame graphs

The user asked to continue flame graphs. Reviewed Grok's delivered collector,
record decoder, standalone tests and handoff; integrated their API without a
new dependency or system setting. The only collector edit undefines
`_FORTIFY_SOURCE` in its local C import, matching the existing shared C import:
Zig/glibc's fortified fcntl wrappers otherwise fail translation in ReleaseSafe.
All existing source/document files were backed up before each edit.

### What is implemented

- `src/profile/capture.zig` owns one bounded capture and its opened module
  snapshot, copies borrowed collector records, drains at bounded intervals,
  tracks event loss/throttling/map/exec/thread metadata, and closes perf fds on
  stop/timeout/exit/error. Old completed data survive a failed new start and
  target exit; explicit new capture replaces the old data. Capture ID/revision
  are separate from target generation and paired with stable debugger/perf
  thread identities. No sampling starts on an unselected thread.
- `src/profile/flame.zig` builds sample-count call trees with caller identity,
  recursion, inclusive/self conservation, deterministic sibling layout, and
  explicit whole-sample exclusions at its node limit. A sampled IP is looked
  up directly; caller return addresses use minus one. Kernel context markers
  are never interpreted as PCs. Frozen region lookup uses binary search.
- The native view offers P capture/stop, F flames/source, click selection,
  Z zoom, Backspace parent, depth scrolling, source location, ELF assembly and
  Enter to browse the matching stopped live image. Source uses a blue browsing
  marker; stopped PC/locals remain independent. The view renders at most 512
  visible bars and refreshes the aggregation at most every 250 ms while live.
- MCP exposes `start_profile`, `stop_profile`, `get_profile`, `get_flamegraph`,
  and `get_profile_frame`. Read tools need observe scope; collection needs
  control plus current target generation. Queries pin capture ID/revision,
  support thread/relative-time filters and bounded pages, and retain
  source/assembly access after exit. No command resumes the target implicitly.
- `tests/fixtures/profile.c` is an optimized frame-pointer fixture with two
  CPU paths, four recursive callers, a late-map mode and a two-thread mode.
  [PROFILING.md](PROFILING.md) includes the graphical demo, MCP contract,
  screenshot and limits. M2 remains in progress.

### Findings that affect interpretation

The first live sample tree contained nonsense outer return addresses after the
walk passed into code without a reliable frame-pointer chain. Stored raw
records are kept, but derived ancestry stops at the first caller outside the
opening executable maps and gets an explicit partial marker. Even a complete
kernel record does not prove a complete or correct call stack. In the reviewed
GUI run all 128 samples had partial outer ancestry; the two hot functions and
recursive frames were still resolved. Missing libc symbols remain gray.

Per-thread perf side-band events are delivered through the current task's event
context (and eligible CPU events), not every sibling's context. See the kernel's
[`perf_iterate_sb` implementation](https://github.com/torvalds/linux/blob/master/kernel/events/core.c).
Consequently a selected subset cannot establish complete process mapping
history. Such captures retain raw-address graphs and report unverified mappings.
New threads end capture conservatively; no hidden scope expansion is used.
Observed mapping/exec boundaries preserve symbolization only before the earliest
boundary across the rings. Loss/unknown metadata invalidates all symbol trust.
This is a deliberately limited opening-image workflow, not mapping-history
reconstruction. Kernel source was inspected directly; no external implementation
was copied into the call tree or native view.

### Validation

- Shared unit/live debugger suite: 57 tests (54 previous plus call-tree
  conservation/recursion/capacity, caller-address normalization, and out-of-order
  map/loss invalidation). Debug and ReleaseSafe builds passed. Invalid-keymap
  diagnostics are intentional; Zig's stderr report is not itself a test failure.
- Grok's standalone ring decoder: **11/11 passed**, using
  `zig build --build-file tests/repros/perf/build.zig test --summary all` with
  repo-local Zig/TMPDIR caches. His live collector measurements remain in the
  handoff; they are not a measurement of the integrated UI.
- `python3 tests/m2-profile.py`.
  Manual capture retained **169 samples**,
  both known hot functions and all four recursive callers. Tests check zero
  samples while stopped, page/count conservation, time partitioning, thread
  filters, stale identities, scope denial, source/assembly after actual exit,
  no target mutation on reads, and all perf fds closed after final drains.
  Timed, executable-mapping-change and process-exit stops passed. Two-thread
  capture returned **90 + 90 samples**; the explicit one-thread subset returned
  **90 raw-address samples**, all correctly marked as unverified mappings.
- Private headless Sway/Vulkan on the **RTX 4090** passed capture/stop, live
  rendering, frame selection, zoom, source browsing, resize and target cleanup.
  Reviewed empty, selected, zoomed and source screenshots across the GUI runs;
  selected sample assembly and source are readable, with a separate execution
  PC. GUI capture had **128 samples**, zero reported kernel loss and zero
  discarded samples.  MCP verifies unchanged registers/generation during
  browsing. The published screenshot is `docs/images/m2-flames.png`.
- M1 private GUI regression passed. source step, watch investigation, agent
  revocation, evidence export, resizing and cleanup.

A final Debug gate exposed an existing attach/burst race (56/57 passed):
`PTRACE_SEIZE` returned EPERM for a thread that disappeared before both subsequent
`/proc` checks. A focused in-process diagnostic reproduced it on run 7:
`ATTACH_RACE ... count=14 err=PermissionDenied status=gone` in
`.work/attach-profile-diagnostic/before.log`. The fix ignores EPERM only when a
fresh `/proc/TID/stat` lookup confirms ENOENT/ESRCH or an exited Z/X task;
other permission errors still fail. No ptrace permissions were changed.
A scratch test build selects only the existing attach-burst test. After the
fix, **30 runs × 20 attach bursts passed (600 attaches)**. The full Debug gate
then passed **57/57**. The final ReleaseSafe gate also passed **57/57**, then
`./scripts/build` restored the normal Debug executable. An initial attempt to
pass `--test-filter` to an already compiled Zig test binary was rejected before
running any tests; the filter belongs on the compile step.

### Remaining work and LLM opportunities

No full-game/high-performance-server overhead or worst-case UI latency has been
measured. The default is a user task clock, not hardware-cycle weighting. Durable
capture export/reopening, mapping-history stitching (especially with sampling
subsets), DWARF callchain reconstruction, JIT/remote support, off-CPU evidence,
and tracing remain future increments. Captures currently live only in memory;
external clients can save MCP responses. File-backed ELF bytes and local source
can change if rebuilt in place; the capture does not snapshot source text.

An external local or remote LLM can now compare hot caller paths and filtered
thread/time windows, cite capture/revision/sample counts, and use
`get_profile_frame` to inspect the corresponding source/assembly before proposing
a change. It should report partial stacks, unverified mappings, loss and scope
alongside a hotspot claim; raw samples do not prove lock, GPU or I/O causality.
Useful next experiments: compare T04's baseline and CPU-heavy frame/server modes,
then ask which additional off-CPU or allocation evidence would discriminate
competing explanations. Agents should request a bounded follow-up capture under
user-granted scope rather than expand collection silently.


## 2026-09-30 — Firefox thread limits and sparse copy samples

The user attached successfully to Firefox, then saw `ProfileThreadLimit` when
starting a capture. A long-running `mv` copying roughly 100 GB produced only
zero or one sample. These are separate issues.

### Findings

- The initial collector admitted only 16 TIDs, although ptrace already supported
  1,024 threads. Our own disposable headless Firefox reproduced the exact error:
  95 threads before attach, 96 in the stopped snapshot.
- Read-only inspection of the user's PID 16227 showed **127 threads in that
  process**, plus **24 descendant processes with 1,572 threads**. One descendant
  was a zombie. A later per-thread snapshot found 588 `MediaTrackGrph` threads
  in PID 16742 and 365 in PID 2977, all sampled threads sleeping. The total was
  dominated by live threads in these two content processes, not zombies.
  These are snapshots, not proof of a Firefox leak or its cause.
- Mozilla's [GraphDriver.cpp](https://searchfox.org/firefox-main/source/dom/media/GraphDriver.cpp)
  creates the `MediaTrackGrph` thread for its threaded media graph driver and
  contains explicit asynchronous shutdown paths. The name identifies a useful
  area to investigate but does not identify the owning tab or explain retention.
  Firefox's [process manager](https://support.mozilla.org/en-US/kb/task-manager-tabs-or-extensions-are-slowing-firefox)
  can map those PIDs to content. A follow-up should observe thread creation and
  exit over time and correlate with the identified tab's activity.
- The capture excludes kernel execution. Repeated system calls can consume
  almost all CPU inside the kernel and leave very few user samples. Blocked
  I/O time is absent too; sample count alone cannot distinguish these cases.
  See [perf_event_open](https://man7.org/linux/man-pages/man2/perf_event_open.2.html).
  GNU coreutils can perform copy offloading through `copy_file_range`, including
  cross-filesystem `mv` copying; see its
  [9.0 announcement](https://lists.gnu.org/archive/html/info-gnu/2021-09/msg00010.html).
  We did not trace the user's specific `mv` or establish its kernel-time ratio.

### Changes

- Raise the profiling ceiling to **1,024 TIDs**, matching the debugger's thread
  capacity. All current threads remain the default; explicit MCP subsets remain
  available and retain the existing mapping-trust restrictions. No automatic
  process-tree or thread-scope expansion was introduced.
- Expose the last start error, requested thread count and ceiling through MCP;
  provide actionable thread-limit and perf syscall/errno text in the flame view.
  Failed starts preserve the previous capture and do not detach the target.
- Increase the bounded MCP output queue from 256 KiB to 1 MiB. The measured
  640-thread `start_profile` reply was **366,679 bytes**, larger than the old
  queue. A successful capture must also fit its reply rather than disconnecting
  a client after collection has started.
- Add independent user/kernel CPU accounting to completed captures and the UI.
  Read `/proc/PID/task/TID/stat` at capture start/stop only; `/proc/PID/stat`
  aggregates the thread group, so using it for the leader would double-count.
  Convert ticks using `_SC_CLK_TCK`; require matching start time and monotonic
  counters; expose missing/recycled/exited tasks and partial coverage. User time
  includes guest CPU as Linux reports it. See
  [proc_pid_stat](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html).
  Totals have tick granularity and approximate intervals because setup and
  sequential endpoint reads take time. They are not weighted samples, syscall
  timings or off-CPU attribution. Aggregate CPU can exceed elapsed wall time.
- No new dependencies or system settings. One fd and 4 data pages plus one
  metadata page per selected TID: 20 MiB of perf ring mappings at the ceiling
  on 4 KiB pages. OS descriptor/perf memory limits can still reject an open;
  already opened fds/rings are released and the failure is reported.

### Follow-up and LLM opportunities

The next browser/game capture improvement is maintaining executable mapping
history so ordinary mapping changes need not stop a capture. Process-tree
selection should remain explicit and scoped; sampled JIT addresses still need
appropriate code identity. A local or remote LLM can now compare user/kernel
CPU totals with sample counts and counter coverage before claiming that an
empty graph means inactivity. For the media-thread investigation it could group
thread names, compare bounded snapshots, and propose evidence to distinguish
retained media graphs from a thread shutdown defect. It should not infer a leak
from one snapshot or infer I/O latency from missing CPU samples.


## 2026-09-30 — next profiling increment: mapping-history evidence gate

The user asked to continue xodb. Proposed continuing captures across executable
mapping changes in `docs/M2_MAPPING_PROPOSAL.md`; review is pending under the
user's standing instruction to run revisions by them. Corrected the M2 summary
row to reflect the already integrated collector/flames. Product behavior has
not yet changed for this increment.

Completed independent kernel research while awaiting review. New standalone
`tests/repros/mappings/events.c` and `run.py` compiled without warnings and
ran. Two configurations and two owned threads each exercised nine operations;
the detailed table and interpretation are in `docs/research/mapping-events.md`.

MMAP2 reports observed executable mmap/replacement and RW-to-RX mprotect.
`mmap_data` additionally reports RW mappings and removing execute permission.
Neither configuration reports **munmap or mremap** here. The stronger repro
moves file B over an existing executable file A mapping: the move succeeds but
no replacement event appears. A perf-only history can consequently retain an
incorrect A identity. Events appear only in the calling thread's ring, confirming
the importance of sampling all threads for the available metadata coverage.

Updated the proposal with this measured limit and documented it for the existing
capture too: the current stop-on-mapping policy cannot catch an unreported move.
Any continuation implementation must expose its evidence limits. It must not
claim that perf's MMAP2 stream is complete address-space history. Broader tracing
remains a separate decision; unprivileged access to syscall tracepoint metadata
was unavailable through the tested tracefs/debugfs paths, and no settings changed.

LLM opportunity: check syscall/event coverage using the saved brackets and raw
records before constructing address-to-symbol histories; distinguish observed
identity from an assumption that no unreported change occurred. Record a
counterexample directly instead of generalizing from ordinary mmap success.


## 2026-09-30 — observed mapping history integrated; Firefox stop diagnosis

The user approved mapping history after reviewing the alternatives and the
kernel coverage counterexample. Implemented the approved bounded history,
without new dependencies or system settings.

### Implementation

- Keep the stopped opening ranges and up to 4,096 timestamped mapping changes.
  Sort a cursor's changes and sampled records by time across thread rings;
  split partial replacements without changing unaffected ranges. Exact-time
  sample boundaries and conflicting equal-time overlaps remain unresolved.
- Stable mapping IDs participate in symbol-cache and flame-node identity. New
  evidence advances capture revision; the UI preserves ordinary selections by
  numeric ancestry and resets them when mapping evidence changes. MCP retains
  its capture/revision checks and exposes `get_profile_mappings` in observe scope.
- `mmap_data` records non-executable replacements and RX-to-RW transitions.
  `records.zig` previously declared raw record type/size without filling them;
  those fields are now populated and asserted in the MMAP2 decoder test.
- Capture ELF opening uses the recorded range, device/inode and file offset.
  The existing general module loader's first-PT_LOAD bias assumption cannot be
  used for a later executable-only mapping. `loadObserved` instead derives a
  unique bias from executable PT_LOAD file pages covering the recorded range.
  It retains verified images by ID for historical source and assembly, without
  mixing the new range with an old opening snapshot.
- Anonymous code, missing images, ambiguous ownership and unsupported/truncated
  metadata stay raw with an availability reason. Image/history/sample/node
  budgets remain explicit. Thread subsets still cannot trust mapping ownership
  because unselected threads can change the shared address space.
- Ordinary observed mapping changes no longer stop collection. Exec, scope
  expansion, loss, decode failures and exhausted budgets retain explicit stops.
  Missing events invalidate symbol attribution; stored raw samples remain.
- GUI/MCP always disclose that **munmap/mremap and in-place code changes are not
  fully observed**. The existing kernel probe demonstrates mremap replacing an
  executable range without a perf event. This implementation does not eliminate
  that counterexample or establish complete address ownership.

### Firefox: two separate early-stop causes

1. Initial private mapping-history run opened all 99 threads, then
   stopped `metadata_lost` with one stored sample and 47 reported lost records.
   It saw 275 mapping events. The fixed 16 KiB ring was too small for that burst
   once non-executable mapping events were requested.
2. Rings now use 4–64 data pages per selected thread, choosing the largest power
   of two within the previous **4,096 total data-page budget**. On this host that
   is 128 KiB per ring at roughly 100 threads, and the same 16 KiB at 640–1,024.
   Metadata adds one page per thread: at most 20 MiB total ring mappings. The
   decoder's side-record output capacity increased from 512 to 2,048; loss
   handling remains conservative. A unit test checks every supported thread
   count for power-of-two sizing and the total budget.
3. 98 threads, requested 1.5 seconds,
   **duration** stop, 14 samples, 120 ms user / 110 ms kernel CPU, no loss.
   requested 10 seconds, stopped
   **thread_scope_changed**, 20 samples, 1,048 mappings, four creation records,
   no loss. All private-browser runs check perf fd cleanup and terminate the
   disposable browser/process group. They use a separate headless profile and
   never attach to the user's Firefox or interactive display.
4. The user supplied `2026-09-30_22-40-57.png`. It shows capture #6 on PID 16227:
   **thread_scope_changed**, 22 samples, no loss, 131 opening threads, 451 mapping
   events, 240 ms user / 130 ms kernel CPU, 3,883 ms wall. That capture's cause is
   task creation, not the buffer overflow seen in the earlier private run.
   The fixed-scope collector stops on PERF_RECORD_FORK (which can describe a
   new thread or a new process); it does not automatically enroll the task.
   Its zero 'outside scope' count came from the previous thread inventory, so
   that GUI label now explicitly says 'unselected at last scan'.
5. Added `scope_change` with the first perf creation record's child/parent
   PID/TID and timestamp. The flame footer identifies a thread versus a child
   process when that record is present. Capture stop diagnostics explain other
   exceptional outcomes. At the user's request, failed starts and exceptional
   stops also emit bounded stderr messages, once per completed stop, with
   counts, elapsed time, ring size and syscall/errno when applicable. MCP stdout
   remains the protocol stream.

The user explicitly said Firefox readiness can wait. Following newly created
threads and handling new processes remain deferred; this increment preserves
its reviewed fixed opening-thread policy. A later follow mode must hook the
newborn ptrace stop before execution resumes, track task lifetimes/TID reuse,
respect selected scope and total ring/identity budgets, and distinguish process
memory sharing before assuming a child cannot change the parent's mappings.

### Verification

- Shared suite: **63/63 passed in Debug and ReleaseSafe**. Expected invalid-XKB
  fixture diagnostics appear on stderr. Zig's stderr echo can say `failed command`
  on a successful test; the summary and exit status both report success.
- Standalone perf decoder: **11/11 passed**, using its existing build file with
  repo-local caches. No system or permission settings changed.
- `tests/m2-profile.py`:
  159 samples in the normal capture;
  duration/mapping-continuation/exit, conservation, scope, filtering, source and
  descriptor cleanup pass. All-thread samples 89+89; subset 89 raw samples.
  Kernel fixture: 630 ms kernel / 0 ms user, one user sample (tick granularity
  and endpoint timing make this possible). Sleep: zero CPU/samples. 640 threads:
  178 samples, 900 ms user / 0 ms kernel, all perf descriptors closed.
- `tests/m2-mappings.py`:
  Main: 196 samples/15 changes;
  worker: 194/16; selected worker subset: 196/16. Distinct library symbols share
  the same runtime address but different module/mapping identities. B's execute
  permission transition creates another mapping lifetime. Anonymous RX samples
  stay raw; subset attribution stays unverified. Historical source/assembly
  survives unload and exit, with unchanged stopped registers/generation and no
  remaining perf descriptors.
- Maximum-budget graph: 16,384 opening regions, 4,096 changes, 16,384 samples
  with 64 callers each. **87–95 ms ReleaseSafe; 558–584 ms Debug**, 8,192 nodes,
  126 accepted / 16,258 explicitly excluded by node budget. Sample conservation
  and the symbol-cache bound pass. Test-process MaxRSS 60–64 MiB; retained ELF
  images/libdw and production game/server overhead are not covered by this
  synthetic bound. Debug can stall visibly here; ReleaseSafe is preferable for
  large interactive captures. Leaving a ReleaseSafe binary built for the user.
- Private headless Sway flame test:
  RTX 4090, 323 clean frames. Capture, selection,
  zoom, source navigation, resize and cleanup pass. Reviewed the screenshot:
  coverage text and CPU totals are readable, selection and source/assembly match.

### LLM opportunities

An external local or remote model can now compare hot paths across library loads
using capture, mapping and module IDs; inspect unknown mapping reasons; and cite
coverage limitations alongside symbol claims. It can classify a short capture
from the stop reason and triggering task IDs instead of inferring its cause from
sample count. Timing/loss evidence should guide follow-up captures before making
optimization recommendations. Full address-space history, automatic thread
following, JIT symbols and durable captures remain future work.


Final stderr verification (ReleaseSafe): opened 101 private-browser threads.
It stopped after 204 ms when Firefox created TID 29464 in the same PID 29066
(parent TID 29080), before any user CPU sample. Sixteen mapping events arrived,
no loss, and the task IDs match `get_profile.scope_change`. The log contains
exactly one exceptional-stop line and one task-creation line; perf descriptors
were closed and the private browser cleaned up. This confirms the remaining
fixed-task-set limitation can trigger immediately even with adequate rings.
A separate idle-target failed-start check emitted `NotStopped` exactly once on
stderr while every stdout response parsed as JSON-RPC:
Final ReleaseSafe build and
`zig fmt --check` passed. The final logging additions were checked through these
live stderr/MCP paths; the 63-test suites above preceded those logging-only edits.


## 2026-09-30 — GUI hang after Unreal attach: Wayland reader race

The user reported attaching to UnrealEditor PID 21020, seeing a working window
that became unresponsive without input, then exiting. Their stderr showed the
RTX 4090 and `58 frames, clean shutdown`. Read-only host inspection found the
editor alive and detached (`TracerPid: 0`), with 58 threads and 797 executable
images. No xodb core was available; kernel logs were inaccessible. The ordinary
shutdown message did not explain the earlier stall or identify the close source.
No agent attached to, stopped or otherwise controlled the user's editor.

Found a real defect in `Window.pump`: external `poll` followed by blocking
`wl_display_dispatch` races with another thread reading a graphics-library event
queue. The official Wayland API explicitly documents this failure mode. The
repro/fix details and primary reference are in
[research/wayland-attach-hang.md](research/wayland-attach-hang.md).

Created `tests/wayland-read-race.c` and `.py`. A real secondary libwayland queue
reader consumes a private sync reply after the main thread observes readiness.
On the old ReleaseSafe binary, MCP/GUI stopped progressing; a compositor close
woke dispatch and the program printed **59 frames, clean shutdown**. This
reproduces the failure class and nearly identical frame count, without
requiring Unreal or any user process.  It does not replace a stack trace from
the user's particular stalled run.

The pump now reserves a read before polling and reads/cancels on every path.
Timeouts, interrupted polls, disconnections and output backpressure are handled.
Pending callbacks are dispatched after releasing the reservation. All ptrace
work stays on the original OS thread; no new application worker or dependency.

Added attach progress/timing, shutdown reason (compositor close, quit key, signal,
MCP EOF or frame limit), and stderr timings for GUI phases taking at least 250 ms.
Main-loop close/quit handling now avoids another render after a close was already
received. Slow-operation reports appear after a call returns; they are not an
interrupting watchdog. GPU/driver waits remain another possible source of stalls.

Validation:

- Initial fixed Debug race.
  The secondary reader waited for the main read reservation, then completed.
  Repeated MCP requests stayed responsive; close logged `compositor_close`.
- ReleaseSafe build and race with an owned 58-thread target.  Attach took 1 ms;
  GUI/MCP remained responsive during the induced race. All 58 threads appeared
  stopped, and closing xodb detached/preserved the fixture, with TracerPid
  returning to zero. The runner then terminated only its own fixture and
  private compositor.
- Formatting checks passed. Existing source files were backed up before edits;
  test artifacts and GPU caches remained under the repo. No system settings,
  packages, interactive display or Unreal files were modified.

LLM opportunity: correlate named slow phases, close reason and a native stack or
syscall trace before assigning blame to target size, ptrace or the GPU. Distinguish
reproduction of a shared event-loop defect from proof about a past unobserved run.

Final GUI regression: `python3 scripts/gui-smoke.py --profile` passed on the
RTX 4090, 328 frames, close reason `compositor_close`.
Shared session, execution controls, flame capture/inspection, resizing and
cleanup passed. ReleaseSafe binary left built.


## 2026-09-30 — Unreal retest confirmed; next M2 timeline handoffs

The user retried the fixed build against their Unreal workflow and reported
“yup, works now.” Recorded that confirmation in the Wayland hang research.
The earlier automated checks used owned fixtures; no agent attached to the
user's editor. No new runtime test was needed for this documentation update.

Prepared [M2_TIMELINE.md](M2_TIMELINE.md) as the next increment of the existing
M2 event-timeline item: select a slow interval/thread and inspect matching CPU
flames, with optional scheduling evidence. CPU sample density and scheduled
wall time remain separate measurements. T04 already observed per-thread perf
switch records on this workstation; direct collector behavior, event pressure
and overhead still need validation. These records alone cannot identify a
wait stack, waker, lock or syscall cause.

Prepared two independent, unassigned handoff packets:

- [T08](tasks/T08-scheduling-events.md), suggested Grok: optional scheduling
  records, decoder and collector evidence. Deliver production changes in a
  tested scratch-copy patch so new exhaustive record cases cannot break the
  shared capture build before integration. Collection defaults stay unchanged.
- [T09](tasks/T09-profile-timeline.md), suggested Fable/Claude: standalone native
  timeline component, synthetic-data interaction tests, and a tested patch for
  shared UI integration. Keep lane geometry bounded for large thread counts.

Codex owns bounded interval pairing, uncertainty/loss handling, range/thread
filters, capture/revision identity, MCP and shared integration. The plan requires
unknown regions where transitions are incomplete, preserves fixed opening TID
scope, and accounts for debugger stops where boundary evidence is available.
No dependency, system setting or collection-default revision was adopted; any
such choice remains subject to review. This prepares work; the timeline and
scheduling collection are not yet implemented or integrated.

External local or remote LLMs could compare two selected intervals, cite their
CPU and scheduling evidence, and suggest a targeted follow-up capture. The
model must preserve the distinction between measured off-CPU time and a
hypothesis about why the thread waited. T04 frame/server fixtures provide
controlled cases for evaluating that distinction and instrumentation cost.


## 2026-09-30 — Shared timeline foundation; T08/T09 assigned

The user assigned T08 to Grok and T09 to Fable/Claude, using Opus 5.5. Recorded
those assignments without editing either agent's owned source/research paths.
The UI and live scheduling deliveries remain pending.

Implemented `src/profile/timeline.zig`: shared half-open relative-time filters,
pointer-free capture selection, exact bounded integer CPU bins, and conservative
single-lane scheduling reconstruction. Missing endpoints stay unknown. Unlocalized
loss, invalid identity and contradictory/duplicate/out-of-order transitions make
the lane unknown rather than manufacturing durations. Preemption is retained as
a switch-out attribute, without asserting runnable duration or a wait cause.
The 65,536-event bound is for offline reconstruction; a live collection budget
still requires T08's rate/pressure measurements.

`Capture.cpuTimeline` and flames now share filter validation and sample identity
checks. Bins and per-thread counts conserve the same sample population, including
flame samples rejected by the graph-node cap. Samples predating capture start
are explicitly invalid instead of being clamped to time zero. Live extent is
revision-stable, updates at most four times per second without new evidence, and
includes final-drain samples beyond the stop-request timestamp.

Added observe-scope `get_profile_timeline`: at most 512 bins, 64 thread rows per
page, loss diagnostics and up to 1,024 retained debugger markers. Stop/control
markers come from the target event history; they describe debugger timestamps,
not exact scheduling boundaries. Lost history and marker capacity have separate
counters. Markers are retained after target exit and reset on capture replacement.
Scheduling is explicitly disabled until T08 is integrated, including for zero-
sample captures. No collector flag/default or dependency changed.

Added `FlameView.setFilter` for T09's committed range/thread selection. Selecting
another capture clears the filter; full-range selection follows growth. Flame
trees are reused when only clock/marker revisions change, avoiding repeated
symbol/graph work solely to advance the timeline. The visual drag control is
still pending T09. The integration contract is in [M2_TIMELINE.md](M2_TIMELINE.md).

Validation:

- Standalone model: 5/5 Debug tests, including uneven-bin boundaries, u64-scale
  timestamps, selection changes, unknown evidence and the maximum event bound.
- Final full ReleaseSafe suite: **71/71 passed**.
  Includes CPU/flame
  conservation, final-drain extent, marker capacity and flame cache/filter checks.
  Maximum mapping/graph regression: 82 ms, 8,192 nodes, 126 accepted and 16,258
  explicitly excluded samples. Expected malformed-keymap stderr remains in the
  test log; the build summary and exit status report success.
- New `tests/m2-timeline.py`.
  241 samples across two threads; every requested bin agrees with flames, thread
  totals agree, pause/resume markers appear, stale IDs/revisions and invalid
  filters reject, registers/generation stay unchanged, and completed data survives
  target exit. Sleep: zero samples; 66-thread capture: 27 samples and correct
  two-page thread totals. Replacement clears counts and markers.
- Existing `tests/m2-profile.py`.
  170 normal samples; duration/mapping/exit, recursive ancestry, source links,
  subset/all-thread capture and descriptor cleanup passed. Kernel-heavy: zero
  user samples, 650 ms kernel CPU. Sleep: zero CPU/samples. 640 threads: 172
  samples, 860 ms user CPU, descriptors closed.
- Final private headless Sway/Vulkan flame regression. RTX 4090, 328 frames,
  compositor-close shutdown. Shared session, controls, flame inspection, resize
  and cleanup passed.  Unit tests cover the new filter entry point; this GUI
  run covers the existing visible flame workflow, not T09's pending drag
  interaction.

Source files and rebuilt installed binaries/ELF fixtures were backed up before
changes. Artifacts and caches stayed in the repo. Only owned targets and a private
headless display were used; no system settings or user's targets were changed.
ReleaseSafe binary left ready. API docs, milestone status and README test commands
are updated; M2 and the visual/scheduling timeline remain incomplete.

External local/remote LLM opportunity: use a pinned timeline range and thread to
request matching flames/source, compare hot intervals, and cite retained debugger
markers before attributing a long pause to application behavior. Scheduling remains
unavailable in current live captures, so no-sample gaps cannot support wait-cause
claims. Reconstruction and collection loss must stay explicit when T08 arrives.


## 2026-10-01 — T08/T09 integrated: optional scheduling and linked timeline

The user confirmed Grok’s T08 and Fable/Claude’s T09 complete, then explicitly
approved Claude’s layout: flames above the timeline; F restores the source
workspace and its thread/stack/event panes. Integrated both deliveries, retaining
their scratch patches and reports as provenance. Scheduling remains off by
default; the GUI’s **Next sched** button and MCP’s boolean `context_switch`
select it for the next capture. No new dependency or system setting was needed.

Grok’s raw per-task switch records now feed a bounded retained history: 262,144
transitions total, 65,536 per lane, at most 9 MiB transition allocation capacity.
The existing side-drain cap stays 2,048. Shared reconstruction pairs only observed
transitions; unmatched edges and incomplete evidence stay unknown. Invalid
identity, ordering, loss and capacity are explicit. Capacity preserves a valid
prefix and stops capture; final-drain scheduling failures preserve an earlier
mapping/scope/collector stop reason. Exceptional stops include counts/storage
on stderr. `get_profile_schedule` pages intervals at 128 spans with whole-filter
running/off-CPU/unknown totals and capture/revision guards.

Claude’s component is connected to real samples, scheduling and debugger
markers. Drag commits a range on release; a lane click filters a TID; fit, zoom
and reset remain display actions. The flame/source lookup uses that same filter.
`get_profile.displayed_view` exposes the last GUI capture/revision/filter to an
external agent without granting control. It can lag a live capture; stop and
refresh for stable comparisons. Fixed per-thread debugger-stop reconstruction so
one thread stepping does not close another thread’s stop. Capped expanded stop
overlays at 4,096 with an omitted-overlay notice, avoiding unbounded rendering
work from many threads and control events. The adapter computes extent once per
build and flame refresh avoids rescanning unchanged evidence every frame.

Validation:

- Full host ReleaseSafe suite **86/86 passed**:
  The earlier sandbox attempt
  failed ptrace-dependent tests with permission errors, including expected
  ExecFailed becoming PermissionDenied; host testing resolved that environment
  restriction. Pure bounds/reconstruction tests passed there too.
- **10/10 production decoder tests**.
- Live scheduling. Sleep: zero CPU
  samples, 653 ms paired off-CPU; busy two-thread: 258 samples, 618 switches;
  kernel-heavy: one user sample, nine switches. Disabled sleep: no switches,
  entire interval unknown. Pagination/filter conservation, stale guards,
  register/generation preservation, exit retention and fd cleanup passed.
- Corrected an invalid test assumption: a busy thread had only 86 ms in closed
  running pairs but a 567 ms open tail. CPU samples and aggregate user CPU
  demonstrated activity. No final switch-out existed, so the unknown tail was
  correct. The test now checks this conservative rule rather than requiring
  arbitrary periodic scheduler transitions.
- Private GUI. Real second-thread
  selection and live drag agreed with MCP/flame counts; GUI scheduling toggle,
  fit/wheel/reset, source restoration, replacement, resize, unchanged target and
  clean shutdown passed. Saved selected-range screenshot in
  `docs/images/m2-timeline.png`; inspected the selected and full-range renders.
- Existing CPU timeline/profile tests passed including 640-thread default capture.
- Existing private Vulkan flame/source smoke passed, RTX 4090, 328 frames,
  clean compositor close.
- Synthetic maximum adapter: 1,024 lanes, 262,144 transitions, 16,384 samples,
  1,024 control markers prepared in 10.1 ms. Component’s pathological 4K case:
  2.30 ms rebuild and 0.10 ms cached draw, 2,890 quads. Live GUI logged no phase
  at or above the 250 ms slow-phase threshold. These do not guarantee worst-case
  behavior on arbitrary game/server processes.

Measured T04 frame/server runs with `tests/m2-workload-cost.py`, two repetitions
per native/CPU-only/scheduling mode, 99 Hz, about two seconds each: No perf
loss, request drops, invalid events or retention overflow. Scheduling recorded
1,149–1,204 switches/s in the six-thread frame loop and 18,231–18,252/s in the
nine-thread server.  Compared with CPU-only, scheduling used 0–10 ms more xodb
CPU in frame runs and 40 ms more in server runs; procfs granularity is 10 ms
and GUI rendering was excluded. Target CPU ranges, latency/throughput, storage
and method limits are in [M2_TIMELINE.md](M2_TIMELINE.md#t04-cost-comparison).

Server p99 includes debugger setup after request clocks started, making a
backlog in both profiled modes. These results cannot isolate collector cost on
server tail latency; lower scheduling p99 is not evidence of improvement.
Frame quantiles exclude frame zero’s setup pause. Grok’s original fixed-duration
ratio likewise cannot quantify collector overhead. Representative large games
and high-performance servers remain an open M2 acceptance task.

Only owned targets and private headless graphics were used; notified host
resource use. Existing source/docs and rebuilt binaries/ELF fixtures were backed
up, with artifacts/caches inside the repo. Installed binary remains ReleaseSafe.
Task statuses, milestones, profiling workflow/API and README commands are updated.

LLM opportunity: read the human’s selected time/TID via `displayed_view`, pin the
final capture revision, compare CPU flames and scheduling totals, and inspect
unknown/loss/debugger-stop evidence before explaining a hitch. Suggest targeted
application markers or wait-site collection when evidence is insufficient. The
current events cannot distinguish a lock, I/O or GPU wait; that remains a
hypothesis until richer evidence supports it. T04 known-cause fixtures provide
an evaluation set for that reasoning. Application markers are a useful next M2
increment; remote Android/Linux transport remains an eventual goal.


## 2026-10-01 — Unattended continuation and first local check-in

The user requested continued work while asleep. No remote changes were made.

Tested the direct task-scoped uprobe PMU (type 9) on an owned stopped child:
`perf_event_open` returned EACCES even with user-only collection. This is distinct
from the earlier tracefs-based perf-probe restriction. No system setting was
changed. Reproduction and source references are in
[research/uprobe-permissions.md](research/uprobe-permissions.md). Continued with
independent M2 work instead of requiring a sleeping user to adjust permissions.

Added compiler-declared DWARF subprogram range recovery for function graphs when
ELF size/symbol evidence is absent. Bounds remain explicit, executable and capped;
multiple ranges expose a fragment, never a fabricated whole-function extent.
CFI rows are not function extents. GCC/Clang O0/O2 PIE tests passed after removing
the function’s ELF symbol, including source, overlay and stale checks.

Added a bounded instruction inspection IR and observe-scope MCP query:
`get_instruction_effects`. Typed widths/operands, memory address expressions,
register reads/writes, prefixes and operation classes are available without
parsing assembly strings. LEA is address-only; unsupported operations are opaque.
No register-alias normalization, full flags/implicit-memory semantics, execution,
SSA or symbolic proof is claimed. Every result reports incomplete semantics.

Full ReleaseSafe suite: **88/88 passed**, `.work/overnight-static-unit-2.log`.
New recovery test.
New IR/observe/overlay/bounds test.
Existing GCC/Clang/objdump flow comparison.
Detailed APIs and limits are in M2.md.

LLM opportunity: use typed memory widths/address expressions and compiler range
provenance for layout/protocol hypotheses, preserving explicit uncertainty about
runtime values, aliases and instruction semantics. Imported application timing
is a useful next step while privileged probe collection is unavailable.

Private headless Vulkan flow regression passed.
272 frames and clean compositor-close shutdown.


## 2026-10-01 — Imported application intervals

Added bounded application timing records to completed captures: frame, request
or custom, source/label, optional opening TID and correlation ID. Control-scoped
MCP import validates the entire batch before mutation; 128 per call and 4,096
per capture. Read-only queries use half-open overlap filters and retain original
endpoints/provenance. Global records match every selected TID. The timeline
renders blue overlays and explicitly labels imported data on hover.

`scripts/frame-intervals.py` converts T04 CLOCK_MONOTONIC CSV microseconds to
capture-relative nanoseconds, keeps complete work intervals only, and emits
MCP tool calls. It reports skipped boundary/outside rows and requires caller
confirmation of matching process/run/clock through its documented contract.
There is no clock synchronization inference or live probe substitution.

Full ReleaseSafe suite **90/90 passed**.
Real workload test imported 49 frames;
known injected stall was 31.54 ms. Verified pages, filters, source labels, stale
guards, atomic invalid-batch rejection and unchanged flame nodes/scheduling spans.
Initial test assertions incorrectly expected no generation change on import;
existing `Session.record(.agent, ...)` intentionally emits an audited action and
advances generation. Kept that policy, returned the new generation, corrected
tests to compare target register values, and projected per-batch generations in
the converter. Browsing remains read-only.

External LLM opportunity: join frame/request correlation IDs to selected CPU
and scheduling evidence, distinguish work duration from pacing, and report the
known limitations of caller-provided timestamps. Prefer a bounded follow-up
capture over inventing a cause when a long imported interval has unknown lanes.

Private GUI overlay/hover/selection test passed. Register values and execution
state survived import/browsing; action-audit generation advanced only on import.


## 2026-10-01 — Portable capture export

Added weighted Speedscope sampled output, optional `--profile-out` on shutdown,
and control-scoped `export_profile` with the shared time/TID filter. The portable
stack order is explicitly synthetic and units are sample counts. Recursive
ancestry and mapping identity survive frame interning. An xodb extension retains
selection/capture identity, counts and coverage, CPU density, scheduling totals,
imported intervals and debugger observations. It is not a native capture archive.

Publication writes a private exclusive temporary beside the requested destination,
fsyncs it and hard-links it into place without replacing an existing file or
symlink. No directory fsync/power-loss durability guarantee is claimed. Export is
bounded at 64 MiB and records the existing agent action audit policy.

ReleaseSafe suite passed **91/91** on the host:
`.work/overnight-export-unit-host.log`. An initial sandbox invocation failed the
17 ptrace-dependent tests with permission errors; the host run corrected that
execution context, with no product workaround or system changes.
Live export test passed conservation vs MCP, full/time/TID/empty selections,
recursion, imported records, scheduling, stale/scope checks, target-state
preservation, no-overwrite/symlink protection, post-exit export and
stopping/draining a zero-sample capture at shutdown.

All six generated outputs also passed the official Speedscope JSON schema using
an isolated test-only jsonschema 4.25.1 environment. The schema website rejected
a direct urllib fetch, so the same published schema was read from upstream
[gh-pages](https://raw.githubusercontent.com/jlfwong/speedscope/gh-pages/file-format-schema.json).
No browser rendering claim; source references and optional reproduction are in
PROFILING.md. The live test also validates the schema when given `--schema`.

LLM opportunity: retain a small selected aggregate for asynchronous analysis by
external agents, joining imported IDs to CPU and scheduling evidence. Keep the
recorded selection, synthetic ordering and missing raw history explicit; avoid
inventing temporal causality from Speedscope stack order.


## 2026-10-01 — Basic Rust/Zig values and a namespace crash fix

Compiler fixtures exposed a real Rust locals crash: `dwarf_getscopes(CU, pc)`
returned zero and a null array, which Zig rejected even for a zero-length slice.
A standalone C reproduction found the scopes from the namespace DIE. Added a
bounded namespace fallback that retains outer scopes and reports no-scope cases
explicitly. Function-range recovery shares it. No elfutils patch was needed.

Types now retain Rust/Zig language/producer evidence and bounded named integer
enumerators, including signed narrow and unsigned 64-bit values. Zig 0.16 LLVM
emits C99 language with a Zig producer; the adapter uses that explicit evidence.
Slice recognition requires the producer, spelling and recorded ptr/length member
types/offsets. Byte previews read at most 64 bytes, preserve invalid UTF-8 as hex,
report truncation/read failure, and never read an empty slice's data pointer.
The GUI uses these summaries; observe-scope `get_value_children` pages up to 64
fields/array/slice elements, with raw-field access and stopped-generation guards.
No target function is called. Rich containers/active variants remain pending.

Rust Option's variant-part DWARF now reports unsupported rather than an empty
struct. Unsupported array ranges also remain unknown in the type cache on repeat
queries. Aggregate/enumerator parsing has explicit bounds. Rust O2's split slice
location remains unsupported while addressable values work; the test requires
this explicit result rather than fabricating memory. Details: M2_VALUES.md.

Verification:

- ReleaseSafe full suite **93/93**, `.work/overnight-values-unit-2.log`.
- Final Rust Debug/O2 and Zig LLVM/native fixture matrix covers negative and
  high unsigned enums, arrays/structs, text/invalid bytes/empty slices, raw
  fields, bounds, stale/observe behavior and unchanged registers/generation.
- GCC/Clang × DWARF4/5 × O0/O2 source/watch/CFI comparison against GDB:
  all eight passed.
- C++ source-step and stripped/malformed-debug regression: passed.
- GCC/Clang O0/O2 DWARF range recovery still passed.
- Private Sway/Vulkan caller selection and 1600×1400 screenshot clean shutdown.
  Reviewed the visible enum, byte hex, escaped text, slice length and
  unsupported variant.

The final installed binary is ReleaseSafe. Existing files and rebuilt outputs
were backed up. No system setting, package or remote repository was changed.

LLM opportunity: query bounded structured children and exact byte prefixes to
investigate protocols or application objects, preserving field/type provenance,
stopped generation, truncation and unsupported variants. Producer recognition
is evidence for these tested layouts, not a license to guess all Rust/Zig ABI
representations. Additional container adapters need compiler fixture coverage.


## 2026-10-01 — Next independent handoffs and check-in summary

Prepared T10 (sampled-stack unwinding, suggested Grok), T11 (native capture
archive, suggested Fable/Claude), and T12 (Android/remote Linux research). The
packets have disjoint owned paths, concrete evidence requirements, scratch-only
production patches, and explicit boundaries for user review. They are unassigned;
no external message or automatic agent job was sent. AGENT_TASKS.md contains
ready-to-copy handoffs. These extend the user's existing parallel-task workflow.

Tested debugger/profile/timeline baseline
DWARF function range recovery and typed instruction inspection
Imported application timings, timeline overlays and CSV conversion
Portable Speedscope export through CLI and filtered MCP
Basic Rust/Zig views, paged aggregate inspection and scope crash fix

The installed binary is the final ReleaseSafe build. Unit/live/GDB/private-GUI
results are recorded above. Automatic tests used owned fixtures; no Firefox,
Unreal, Android device or interactive desktop was used in this session.

M2 remains in progress: privileged tracing, complete mapping observation, sampled
stack reconstruction without frame pointers, native capture reopening and broad
representative game/server acceptance remain work to demonstrate. Direct uprobes
were measured as EACCES on this workstation; no permission changes were made.


## 2026-10-01 — Working MCP/interface overview

At the user's request, added [MCP_OVERVIEW.md](MCP_OVERVIEW.md) and linked it from
README. It describes current CLI/MCP/model/target/file boundaries, tool families,
scope/revision checks and the basic investigation loop. Multi-client access,
subscriptions, bulk evidence and remote target transport are explicitly tentative;
this overview makes no new implementation or protocol commitments. Checked current
claims against the server/session code and the official MCP 2025-06-18 tools and
stdio specifications. Local links and diff whitespace checked; no runtime changes.


## 2026-10-01 — Fair capture draining and preserved failure evidence

Continued M2 capture robustness. A bounded decode buffer could be consumed on
every drain by an early thread ring, delaying later rings. Draining now rotates,
including giving first turn to a ring that had no buffer space. A second bug let
later side records replace the initial exceptional stop reason; status and its
diagnostic now stay together. The bounded `stop_reasons` list preserves each
additional condition, and stderr reports them. Later loss still invalidates
attribution regardless of the primary status.

Both regressions failed before the fixes (93/95 passed). Final ReleaseSafe suite
passed **96/96**; Added an owned nine-thread fixture for thread creation, fork,
512 mapping changes, and crossing the 4,096 mapping-history limit. All four
passed, including three capture replacements and complete perf-fd cleanup per
case. Primary reasons and mapping coverage were correct, with zero reported
sample loss and paired query latency at most 10.0 ms in this fixture.

Existing CPU regressions passed including 640 opening threads, subset
coverage, kernel-heavy/sleeping accounting, duration/exit and historical views.
Scheduling regressions passed. Two serial native/CPU/scheduling repetitions of
each T04 workload passed. All captured runs had zero reported perf loss and no
discarded/invalid scheduling records. Server startup pauses still confound
tail-latency comparisons; the measured numbers and limits are in
[the robustness research note](research/capture-robustness.md).

No collection policy changed: new tasks still stop at the opening scope boundary.
Automatic enrollment needs review and lifecycle/gap/resource evidence. The
sampled-unwind and capture-archive prototype directories were left untouched;
integration must preserve the new collector cursor and capture stop evidence.
Existing files and rebuilt outputs were backed up. Host tests used owned targets;
no user process, interactive desktop, system setting or remote repository changed.

LLM opportunity: explain early stops from all retained conditions, loss counters,
and parent/child identity, then propose a narrower experiment. A single primary
status is insufficient evidence to explain missing samples or a wait cause.


## 2026-10-01 — Server startup barrier and archive handoff review

Continued M2 while checking external handoffs. Added a test-only startup barrier
via linker wrapping of pthread create/join for the unmodified T04 request server.
All callbacks wait until debugger/perf setup finishes. The runner checks zero
started callbacks across a deliberate 250 ms pause and compares native,
debugger-only, CPU and scheduling modes over queue/socket transports.

All 16 cases passed: identical 7,940 completed requests, zero drops, p99
310–326 µs. All eight captures ended with the target; no reported perf loss or
invalid/discarded scheduling records.  The earlier multi-millisecond p99 did
not recur after removing the setup backlog.  Two short unisolated repetitions
do not establish a general overhead bound.  Full measurements, clock semantics
and limits: [server-cost.md](research/server-cost.md).  No production debugger
or T04-owned workload source changed.

Claude's completed T11 report appeared during this work. Reviewed its format,
offline identity, validation, image matching and file publication code. Wrote
[M2_ARCHIVE_PROPOSAL.md](M2_ARCHIVE_PROPOSAL.md) and requested review of native
archive adoption as previously instructed. Production integration is pending.
A bounded independent repro found blocking FIFO opens for archive and image
paths; integration must add nonblocking regular-file checks and external-image
byte budgets. Delivered T11 and T10 paths remain untouched. The optional
task-status question is superseded for T11 by its completed report; T10's final
report has not yet arrived.

LLM opportunity: use the gated workload to distinguish setup, debugger control,
sampling and scheduling costs with equal offered work. Offline archive agents
should cite archive identity, filters and image verification, retaining missing
symbols and partial coverage as explicit evidence limits.


## 2026-10-01 — Adversarial archive review requested by the user

Reviewed the proposed workflow and delivered codec without integrating or fixing
production code. [M2_ARCHIVE_REVIEW.md](M2_ARCHIVE_REVIEW.md) prioritizes reproduced
issues and design changes. Added an independent coordinator reproduction runner
under `tests/repros/archive-review/`; T10/T11-owned paths remain unchanged.

Directed probes confirmed: re-save replaces recorded origin with offline
IDs/writer boot; re-save without loaded ELFs produces an archive rejected as
`ArchiveInconsistent`; identical archive revision 99 produces 56 versus 57
nodes with/without symbols (38 shared node IDs differ, accepted sample count
stays 2,002); a verified mmap changes after an owned ELF edit, retaining its
verified label; truncation causes a bus error then abort during hashing. A
valid long-path budget archive is 30,473,783 bytes, so 14.7 MB was a fixture
measurement rather than a largest-valid-file bound.

A separate owned-directory probe returned `ArchiveSyncFailed` after the destination
was published and could be decoded. Earlier FIFO hangs remain
reproduced. Checked Linux's mmap/open manuals for the lifetime and O_NONBLOCK
limitations; links and exact test scope are in the review. Probe ELF copies were
backed up, crash probes disabled core dumps, and no live target or GUI was used.

Recommended revisions: immutable artifact origin/manifest, preserved capture-time
symbol annotations with optional asset/source bundles, derived-view identities,
owned verified asset bytes, separate resource budgets and responsive background
loading, structured publication results, and explicit feature/version handling
for T10. This is a critique and proposed direction, not adoption. Archive integration
remains pending the user's review. The installed production binary is unchanged.

LLM opportunity/risk: stable archive hashes alone cannot pin graph nodes or
establish the source clock domain. Agent citations need immutable origin plus
filter/analysis/symbol context and stable references to recorded evidence.


## 2026-10-01 — User adopted the adversarial archive analysis

The user said “yes, please adopt your analysis.” Revised
[M2_ARCHIVE_PROPOSAL.md](M2_ARCHIVE_PROPOSAL.md) into the adopted integration
contract, superseding the original compact/raw-only proposal. Updated milestones
and agent coordination to distinguish approval from implementation. T11 remains
delivered; T10 prototype files are present but its final report is absent.

Adopted: immutable artifact origin/clock/evidence/manifests; recorded symbol/line
annotations by default; explicit derived-view identity and durable evidence
references; owned immutable verified asset bytes; independent memory/I/O/work
budgets and background loading; structured publication/durability outcomes; and
required/optional feature handling with a boundary for T10 stack evidence.
Unchanged artifact copying preserves original bytes and optional extensions.
Annotations created at finalization must identify that timing and asset context,
without claiming they were observations made at each sample timestamp.

Integration is authorized in coordinator-owned production paths. The proposal
orders implementation and requires real capture → target exit → original binary
removal → offline inspection → re-save → reopen, plus directed regression tests
for the reproduced failures and private-GUI responsiveness. No extra approval is
needed for these adopted revisions. Native archive reopening remains unchecked
in M2 until those gates pass; this check-in changes documentation only.

LLM opportunity: offline agents should consume the recorded default view and cite
artifact/record identity plus filter/analysis context. Loading newly available
symbols or reconstructing callers must produce a distinguishable view, so old
citations cannot silently refer to a different aggregation.


## 2026-10-01 — Dedicated archive worker approved; durability syncs removed

The user approved the separate I/O-thread approach and explicitly requested no
fsync/durability work for saved files. Updated the adopted archive proposal and
coordination notes: one archive worker owns loading/analysis state and reports
progress/completed results; file publication uses ordinary kernel buffering with
no file/directory fsync, fdatasync, equivalent forced flush or new durability
option. Results now distinguish `not_published` / `published`; cleanup warnings
are separate. Annotated the historical adversarial review with this superseding
decision rather than erasing the original findings.

Removed the existing file fsync from the production Speedscope exporter too.
Complete-write handling, mode 0600, no-overwrite publication and temporary cleanup
remain. Updated PROFILING.md to describe the current save behavior. Delivered
T11 prototype files retain their original contents as handoff evidence; their
sync calls must not be carried into integration.

Validation: the initial sandbox build failed with Zig `manifest_create
ReadOnlyFileSystem`; the host ReleaseSafe build succeeded using fresh repo-local
caches/output after coordination. Backed up and replaced the installed
xodb executable. `python3 -B tests/m2-export.py` passed full/filtered/empty count
and stack conservation, scheduling/interval metadata, recursion, scope/stale/audit
checks, existing-file/symlink protection, post-exit export and active-close saving.
No additional JSON-schema validation was requested for this file-I/O change.
Source inspection found no remaining fsync/fdatasync/syncfs/O_SYNC/O_DSYNC
calls or flags under src/. Documentation links and git diff whitespace checks
passed. No GUI or user-owned process was touched.

LLM interface consequence: a successful save means publication, with no separate
durability confirmation or retry policy. Agents should report actual write or
publication errors without inventing a durability requirement.


## 2026-10-01 — Native artifacts, offline analysis and archive worker integrated

Implemented the approved revised contract in production paths, adapted from
Claude's T11 codec. Delivered T10/T11 paths are unchanged. Experimental format 2
has separate original capture/boot and writer provenance, complete manifests,
normalized evidence, deterministic finalization annotations, required features
and optional-section preservation. Offline second saves copy the original bytes;
they cannot silently discard unavailable assets/extensions or replace origin
with the new process's IDs. Default offline labels/source locations do not need
the original build directory. Verified SHA-256-named assets add assembly;
--resolve-capture-symbols explicitly derives a new view context.

Capture assets and reopened assets now use owned anonymous read-only snapshots,
with size/mtime/ctime checks while reading, 256 MiB per image and 512 MiB total.
Nonregular files are rejected without waiting for FIFO writers. Archive core
input/output is capped at 64 MiB, Zig encoding/decoding allocations at 256 MiB,
filtered view work at 64 MiB, and mapping path strings at 16 MiB. These counters
do not cover all process memory or libdw's internal C allocations. Live capture
asset acquisition still runs during opening/mapping handling and can add latency;
large game binaries can hit the image limit. No large-game overhead claim follows
from these fixtures.

One job worker handles open/save/offline graph derivation, with atomic
phase/progress/cancel and completed-result ownership transfer. Saving pins a
completed capture's evidence; independent analysis arenas, caches and Elf/Dwarf
handles avoid sharing mutable debugger state. The worker reads only immutable
evidence fields, not even copying the UI's concurrently mutable cache headers.
The installed libdw lacks _ELFUTILS_THREAD_SAFE; no library handles are shared.
Upstream's [thread-safety design discussion](https://www.mail-archive.com/elfutils-devel@sourceware.org/msg09530.html)
distinguishes separate handles from derived handles that share state; this is
the ownership model used here, not a claim of enabling its experimental shared
handle support. No Dwfl/debuginfod lookup or network access is added.

GUI opens offline flames/timeline directly, supports range/thread selection and
resizing, and reports progress; Escape requests cancellation. CLI supports
--capture-out, --open-capture, --symbols and explicit reanalysis. MCP adds
save_capture_archive, get_archive_status, cancel_archive_job and
get_profile_samples. Offline frame/page requests validate view identity; raw
sample ordinals and artifact hashes provide durable evidence references.
Offline target control is rejected even in control scope. Saves use complete
writes/close, 0600 temporary files and no-overwrite publication, with separate
cleanup errors. No durability sync or durability mode was introduced.

Validation:

- Full ReleaseSafe suite: **101/101 passed**, 24/24 build steps. Focused Debug
  archive suite: **9/9 entries passed**, including worker cancellation and
  successful asynchronous filter ownership.
- Real owned two-thread fixture: save before warming a graph, let the target
  exit, remove its build path, reopen with recorded labels/source and raw
  samples, save again and reopen with identical original bytes/origin/view.
  Filtered views match the original live graph. Explicit matching-asset
  reanalysis produces a different view ID; saving still preserves the artifact.
- Stale capture/view/job and observe-scope checks, offline target-control and
  interval-mutation rejection, active-close drain/save, existing files/symlinks,
  write/search-only destination directory, oversized/FIFO inputs, missing assets,
  FIFO assets, and assembly after truncating a loaded asset passed.
- Strace of offline inspection/resaving found no ptrace, perf_event_open,
  process_vm_readv, fsync, fdatasync or syncfs calls. CLI requested-save failures
  produce nonzero status.
- Optional sections survive copying; unknown required feature bits, malformed
  input/checksums, tiny allocation budget and cancellation fail explicitly.
- Maximum-count synthetic evidence with 1023-byte opening mapping paths:
  31,385,994 encoded bytes and 106,076,888 tracked decoded peak bytes.
  ReleaseSafe: encode 154 ms, decode plus default graph 168 ms, one thread filter
  22 ms. Debug: 431 / 730 / 36 ms. This stresses existing count/string caps,
  not every possible ELF or a worst-case process-memory/latency bound.
- Private headless Sway: missing-build offline view, drag range and MCP count
  agreement, 1600x1000 resize, PID/generation isolation and clean shutdown passed.
  The large fixture opened and filtered on the worker; first status RPC including
  initial rendering took 188 ms, RPC during filter work at most 8.2 ms in this run.
  Opening finished before its first status response, so this GUI run does not
  measure RPC service during filesystem stalls. No >=250 ms GUI phases logged.
  Inspected the screenshot and corrected stale live-source footer text.

Development failures were retained in scratch logs: an arena was copied before
its last allocation, invalidating ownership; an error-return used to signal
pending work accidentally ran the job's errdefer cleanup; a private capture copy
would also have left graph thread labels referring to worker stack storage.
Fixed ownership and added direct regression coverage. A failed/cancelled filter
does not trigger a redraw retry loop. These were caught before this check-in.

Final installed binary was rebuilt after the UI text correction and after adding
the reanalysis annotation digest to view identity; integration-final.log records
the final passing end-to-end rerun.

T10's final handoff has now arrived. Reviewed its evidence layout and the
drain-local buffer lifetime; [M2_ARCHIVE_FORMAT.md](M2_ARCHIVE_FORMAT.md) defines
the proposed separate register/stack/reconstruction boundary. The collector and
unwinder remain unchanged pending their own integration review. Existing
frame-pointer, unobserved munmap/mremap and remote limitations remain.

LLM opportunity: an external local/remote agent can inspect a saved capture
without target authority, cite artifact plus sample ordinals and exact analysis
view, and compare a recorded view to an explicit reanalysis. Preserve partial,
unresolved and limit reasons in its conclusions; neither available names nor
an ELF hash justify filling in missing callers or historical source contents.


## 2026-10-01 — Report every automatic capture stop to stderr

The user reported a capture stopping without a terminal hint. The existing
reportStop deliberately suppressed duration and target_ended alongside manual
stops. Removed those two exemptions, added deadline/exit explanations, and
included duration_limit_ms in the existing reason/elapsed/sample/thread/loss
summary. Existing exceptional-stop details remain. The common stop finalizer
reports only once after draining and closing the collector; manual stops stay
quiet unless final draining discovers an exceptional condition.

ReleaseSafe build and the installed binary passed directed owned-fixture checks:
a 125 ms capture stopped at 127 ms and printed duration plus its configured
deadline; target exit printed target_ended; both messages arrived while xodb
was still running. Five later polls produced no duplicate reports, MCP continued
responding, and a manual stop produced no automatic-stop message. No GUI or
user target was touched. No additional full-suite run was needed
for this logging change.

Agent interpretation: the duration limit is wall clock, including time spent
stopped; reaching it does not establish that a process ran out of work or lost
samples. The same diagnostic remains available through get_profile.


## 2026-10-01 — Configurable duration and a provisional preferences file

The user approved a 60-second capture default, a GUI duration control and an
until-stopped option, and asked for the start of a preferences format without
locking behavior in. Added [PREFERENCES.md](PREFERENCES.md) and
[config/preferences.example.json](../config/preferences.example.json), with a
small explicitly loaded JSON reader via --config FILE. First settings are
profile.duration_ms, profile.frequency_hz and profile.context_switch. No implicit
home/project lookup, file creation, write-back or reload is implemented. Future
appearance/input/debugger/archive and override questions remain a sketch.

The shared session owns next-capture defaults, seeded from built-ins plus the
file. GUI duration/scheduling changes affect those defaults; omitted MCP
start_profile arguments use the same values, and get_profile reports them.
Explicit MCP arguments affect only that capture. Active captures retain their
opening config. Agent scope remains separate.

Default duration is now 60,000 ms. The GUI Next button and T shortcut cycle
10s, 30s, 60s, 5m and until stopped; T also works when the button cannot fit.
Zero disables only the wall-clock deadline. Positive u32 millisecond values
can exceed 60 seconds, through files or MCP. Existing count, memory, mapping,
scheduling and task-scope stops remain, with stderr reasons. The status line
shows the active capture's own limit alongside the separate next setting.

Native format 2.1 keeps the META layout and adds required feature bit 1 for zero
or greater-than-60,000 durations. Version 2.0 archives remain readable; older
readers reject unsupported duration semantics explicitly. Updated the current
format/workflow docs; external T10/T11 handoff files remain untouched.

Validation:

- ReleaseSafe full suite passed, including preference parsing/defaults, unknown
  field/type/range errors, duration cycling, archive feature/round-trip guards,
  and narrow-window/offline keyboard behavior.
- Owned live fixture verified 60s built-ins, file defaults, explicit MCP
  overrides, a short deadline while paused, no-deadline collection, unchanged
  file contents/defaults, and manual stopping. At 1000 Hz across two busy
  threads, an untimed capture stopped at 16,384 samples after 8,208 ms, reason
  capacity, with zero lost/unknown records. Its archive copied byte for byte.
- Invalid config, oversized input and FIFO input fail explicitly without a
  blocking FIFO open. Missing paths fail before starting a target.
- Private headless Sway verified mouse presets, until-stopped capture,
  changing the next duration while the current capture remains untimed,
  application to the next capture, unchanged target generation and clean close.
  Inspected the screenshot: both the active limit and Next control are legible.
- Compatibility check with the backed-up older binary: old format 2.0 opens and
  copies unchanged in the new reader; the older reader rejects the new untimed
  artifact with ArchiveFeatureUnsupported.

LLM interface consequence: read get_profile.defaults before omitting capture
options; a human may have changed them since startup. Cite the capture's stored
config when explaining a stop. An untimed capture is still subject to resource
and scope boundaries; reaching capacity does not mean the target finished work.


## 2026-10-01 — Omarchy portability goal and ARM64 test hosts

The user made Omarchy across x86-64 and ARM64 an explicit debugger sub-goal.
They supplied an NVIDIA Jetson reachable as jetty and ordered an M1 MacBook Air,
expected next week, which they intend to run with Omarchy Linux. Added the goal,
host matrix and initial validation scope to [MILESTONES.md](MILESTONES.md).

Read-only SSH verification from this session succeeded using the existing
SSH agent outside the sandbox. Agent forwarding was disabled; no known-host or
remote file changes were made. uname reported Linux 4.9.253-tegra aarch64. This
establishes access and architecture only; no xodb binary or fixture has been run
on the Jetson. The M1 environment remains planned until delivery and setup.

External local/remote agents could compare owned-fixture results across these
hosts and identify architecture, kernel or driver differences. Findings should
cite each host's measured capabilities and test output; shared AArch64 hardware
does not establish matching perf, watchpoint or renderer support.


## 2026-10-01 — Next Claude/Grok packets and Jetson coordination

The user is separately assigning Grok to update the long-idle Jetson and asked
for more parallel xodb work. Prepared three new packets with disjoint research
and reproduction paths; shared production changes remain tested scratch-copy
patches for Codex integration. No external agent was automatically dispatched.

- T13 (suggested Grok after maintenance): map x86 assumptions and prototype a
  Linux AArch64 target boundary plus a standalone ptrace harness. Local ABI and
  architecture work can finish while native validation is pending. A read-only
  capability collector and separate owned-fixture runner keep host readiness,
  system maintenance and debugger evidence distinct.
- T14 (suggested Claude now): GUI next-capture setup, explicit thread subsets,
  active versus next settings, and readable stop/failure diagnostics. Use today's
  backend and synthetic snapshots; no dependence on the sampled-stack merge or
  a chosen future preferences schema. Review new UX before production adoption.
- T15 (next available agent): account for memory and responsiveness at larger
  capture sizes; compare retention policies and deliver one bounded prototype.
  Preserve raw evidence, stable ordinals, mapping history and no-fsync behavior;
  new limits, eviction or disk spooling remain proposals.

The existing T12 remote Android/Linux research packet remains available. Codex
keeps T10 sampled-stack review and shared production integration. Corrected the
original T10 packet's stale unassigned status and added copyable dispatch text to
AGENT_TASKS.md, with links from MILESTONES.md. Maintenance readiness and remote
execution follow the user's separate host authorization; this documentation
change performs no SSH, package, device or runtime operations.

Validation: checked packet paths, local documentation links, disjoint ownership
and whitespace. No production code changed and no runtime suite was needed.
Backed up existing documents before editing. Each packet requests exact evidence,
primary-source/license provenance where applicable, limitations and concrete
external local/remote LLM opportunities in its own research notes.


## 2026-10-01 — T10 collector foundation and critical workflow review

Reviewed Grok's delivered register/stack collector and offline unwinder. Integrated
only the low-level opt-in collector/decoder foundation; Session, GUI, preferences
and MCP still do not enable sampled user state. The original delivered files are
preserved. The proposed capture-owned retention, worker inspection and archive
extension are in [M2_SAMPLED_UNWIND_PROPOSAL.md](M2_SAMPLED_UNWIND_PROPOSAL.md).
The user requested a short critical review instead of approving that workflow.

Corrections to the collector/decoder:

- Kept existing fair thread-ring rotation and its regression test; the delivered
  patch would have removed both.
- Empty/undersized remaining output buffers now report capacity and leave the
  record queued, including when an earlier thread used most of the stack buffer.
- User-state counts/offsets commit only after the complete sample validates.
  Missing weight or extra trailing bytes cannot publish orphan side data.
- Checked side-buffer index/offset overflow, register ABI and requested stack
  bounds. Kernel callchain truncation still preserves subsequent user state;
  a requested weight after that state must be present.
- Kept zero defaults and allocated side buffers only when requested. Added an
  explicit archive guard against silently saving sampled state without its
  reviewed format extension. Old archive reads initialize the new acceptance
  fields to zero and reject unsupported sampled-state declarations.

Further unwinder findings, still to adapt: capture-start-only address matching
cannot stand in for timestamped mapping history; lookup-adjusted caller addresses
must choose the mapping; private ELF arithmetic/machine checks should use our
existing parser. The prototype also releases dwarf_getcfi's borrowed cache with
`dwarf_cfi_end`, contrary to installed elfutils/libdw.h lines 374-389. Our existing
info.Image destructor already follows the required ownership. Signal/unavailable
register/short-stack cases must remain explicit partial results.

Critical review: 32 MiB is an unmeasured retention default (8192 full 4 KiB dumps),
early retention can bias time/thread coverage, discarding dumps does not remove
collection overhead, and MCP-only inspection delays the flame-graph benefit.
Recommended configurable budgets and per-sample/time/thread coverage before
activation, followed promptly by reconstructed flame views. Since drain order
is not global time order, a first-drop timestamp cannot certify all earlier
samples have stack evidence. These recommendations are not adopted runtime policy.

Validation:

- Final ReleaseSafe suite: 120/120 tests, 24/24 build steps; existing archive
  origin/copy/bounds/cancellation and collector fairness tests remain passing.
- Original offline perf decoder suite: 11/11 tests.
- New owned live runner: 353 samples each at disabled, 64, 4096 and 8192 byte
  requests; enabled runs had state and stack for every sample, with 22,592,
  1,445,888 and 2,891,776 valid bytes respectively. Zero reported lost records;
  descriptor counts returned to baseline after each run. This verifies the
  transport and cleanup, not application overhead or offline reconstruction.
- The runner initially hit the installed fortified-glibc C-import issue, fixed
  by matching the project's `_FORTIFY_SOURCE` undef in its C import.

Reproduction: [sampled-state runner](../tests/sampled-state/README.md).
Existing source, generated fixtures and installed executable are backed up before
modification/replacement. No Jetson, user target or graphical session was touched.

External LLM opportunity: per-sample reconstruction can explain missing callers
using observed registers, bounded captured bytes and matching CFI. Require raw
sample ordinal, mapping/time identity and partial reason in citations; neither
missing retained state nor failed reconstruction proves that a caller was absent.


## 2026-10-01: T10 sampled evidence, worker inspection, T14 setup and new packets

The user confirmed **32 MiB total retained stack bytes**, configurable and
provisional, and approved proceeding with MCP inspection before reconstructed
flames. T10 is now integrated end to end on Linux x86-64:

- Off by default; preferences/MCP request 64–8192 bytes/sample, aligned to eight,
  with a separate 0–64 MiB total budget (32 MiB default). Register metadata and
  byte capacity are allocated before collection; initialization failure rejects
  the new capture. Drain data is copied into capture ownership before reuse.
- On first non-fitting nonempty dump, later nonempty stacks remain explicitly
  missing due to budget; CPU samples/registers continue. One stderr diagnostic
  includes the remaining capture overhead. Coverage is per sample and filtered
  by time/TID; drain order is not a chronological guarantee.
- Background completed-capture DWARF inspection uses the production ELF/debug
  adapter with a private libdw handle. Memory reads are confined to retained
  bytes. Leaf PCs are exact; caller PC-1 chooses both historical mapping and CFI.
  Missing data/assets, mapping ambiguity/trust cutoff, signal frames, cycles,
  unsupported CFI/ABI and depth limits remain explicit. Results have algorithm,
  input/asset-derived identity and do not alter original callchains.
- Format 2.2 USTA/required feature bit 2 preserves raw state and budget gaps;
  offline analysis needs explicit matching assets. No derived caller cache is
  serialized, no target memory is fetched, no durability sync was introduced.
  Archive core cap is now 128 MiB while decoded Zig work remains 256 MiB.

Integration findings:

1. A single anonymous mapping exposed the existing MAPS minimum-size bug: 62
   encoded bytes, not 63. Corrected and covered by the new raw archive fixture.
   Claude independently found the same issue in T15 and supplied corroborating
   evidence. This is already fixed before compact-storage integration.
2. Combining the maximum 64 MiB raw-stack budget with existing maximum evidence
   initially exceeded the codec's allocation limit due to allocation slack.
   USTA reserves its exact encoded length, and retained original file bytes use
   a direct allocation instead of an arena growth allocation. The worst fixture
   now encodes to 102,132,158 bytes and peaks at 232,302,100 decoded Zig bytes:
   415 ms encode / 408 ms decode+graph on the final run. These independent codec
   budgets exclude the caller's already-held capture and libdw internal memory.
3. T14 was delivered by Claude, visually reviewed, approved by the user and
   integrated. S opens duration/rate/scheduling/thread setup; the selected subset
   is revalidated by identity, and settings remain separate from the active
   capture. Added a queued-Start regression: after target replacement, the
   action now returns to selection review instead of immediately collecting all
   threads. Tightened compact spacing so the actionable start hint is visible
   at 640x480; made an available Stop button look enabled during collection.
4. The initial sandbox suite denied ptrace (105/122 passed); reran owned target
   checks outside the sandbox after the authorized coordination. This was
   an environment restriction, not evidence of unavailable Vulkan/debugging.

Final validation:

- ReleaseSafe: **138/138 tests, 24/24 build steps**, including exact mapping-edge,
  history, short/absent/budget, unsupported ABI, missing CFI, signal, cycle,
  cancellation, allocation failure and raw archive cases.
- `tests/m2-sampled.py`: seven owned live cases, 109–110 samples each. GCC and
  Clang with and without frame pointers recovered 18 frames including recursion;
  terminal unavailable registers stayed explicit. A 64-byte request produced
  two frames then stack_window; 32 KiB and zero budgets produced explicit gaps
  while CPU samples/registers continued. Filter partitions summed exactly.
- Each live artifact survived offline raw inspection, byte-identical copy and
  second reopening with matching assets; derived results/IDs matched. A traced
  offline run made no ptrace, perf_event_open, process_vm_readv or durability
  calls. The installed pre-extension reader explicitly rejected the new required
  feature. A previously saved owned 2.0 artifact reopened successfully.
- `tests/m2-capture-setup.py`: private headless Sway, correct chosen TIDs, retained
  T10 settings through T14 controls, active/next separation, P stop, S/Escape and
  640x480 access. Screenshots inspected; debugger and owned target exited cleanly.

The installed binary is rebuilt. No user process, visible desktop or Jetson was
used. Large-game/server overhead, ARM64 and reconstructed GUI flames remain
separate work; bounded Zig work does not bound libdw's internal call duration.

T15's full report arrived during integration. Initial critical assessment:
compact cores/interned callchains can reduce memory without changing policy, but
its patch predates T10 ownership/archive changes and must be adapted and measured
against them. Larger flame rebuilds take seconds, so storage savings alone do not
justify raising the sample limit. Its statement about a 64 MiB archive decode
budget is stale: current decoded Zig budget is 256 MiB; filtered graph jobs use
64 MiB. No new retention/default policy is adopted from T15 yet.

Prepared isolated packets: T16 native derived-stack inspection/flames (Claude
next), T17 task-scoped syscall context (independent systems work), T18 ARM64
sampled-state adapter (Grok after T13). T12 remains available. User requested a
one- or two-paragraph critical analysis before every future review request;
recorded in the shared coordination guide and packets.

External LLM opportunity: compare recorded versus reconstructed ancestry by
sample ordinal and analysis identity, explain loss/retention gaps using filtered
coverage, and select useful follow-up captures within configured scope. Missing
stack evidence must not become a claim about absent callers or waiting causes.
T17 can provide syscall observations for hypotheses that CPU sampling alone
cannot answer; causal conclusions still need independent supporting evidence.


## 2026-10-01 — T13 AArch64 handoff reviewed

Grok delivered the architecture descriptor, register-buffer decoder and native
Jetson harness. Reproduced **5/5 local tests** and **3/3 cross-build steps**
with isolated caches and copied sources; `file` confirms a static AArch64
executable. Native register/memory, BRK/restore, step, signal and watchpoint
results are Grok's recorded observations, not a fresh coordinator run. Updated
the roadmap's Jetson snapshot from the old kernel to reported `4.9.337-tegra` /
Ubuntu 18.04.6 / L4T R32.7.6.

[Critical review](T13_AARCH64_REVIEW.md): the perf probe reads the counter fd as
if it supplied sample records, but requires a mapped ring; the remote runner
masks failed modes; cleanup has an unbounded wait and drops ownership on errors;
a failed watchpoint read becomes zero; a target address of zero can still panic.
Recorded each correction and evidence limit without rewriting Grok's transcript.
Architecture constants checked against Arm's DWARF specification; an architecture
encoding is not proof that an xodb backend exists. Kept current production gates.

T18 is ready for Grok with those corrections carried into its isolated ownership.
Local adapters, synthetic sampling and host-side ARM64 CFI experiments can proceed
without changing Jetson packages or perf policy. Shared backend integration stays
with Codex. No production behavior, installed executable, remote host or visible
desktop changed in this review.

External LLM opportunity: compare raw stop PCs, siginfo and memory-read status
across architectures, then suggest narrowly scoped experiments. Never convert a
failed read to a value or a permission skip to a claim of supported sampling.


## 2026-10-01 — T15 compact storage integrated; T18 reviewed

Integrated Claude's compact cores/interned callchains through live captures,
archives, MCP, T10 reconstruction and T14/UI adapters. Corrected two prototype
issues: unusual marker/address combinations could lose one field, and manual
hash allocation estimates missed overhead. Actual allocation requests are now
budgeted. Sample admission precedes raw-state retention, and a refusal latches
across drains so no orphan state or silently resumed suffix appears. Existing
16,384 count, defaults, archive 2.2 and raw/derived semantics remain intact.

[Full results](M2_CAPTURE_SCALING.md): 145/145 ReleaseSafe tests; seven owned live
GCC/Clang saved-stack/archive cases; private headless Sway setup/timeline controls.
Four 16K synthetic shapes cut sample storage from 33,549,808 bytes to
1,065,472–11,175,000 bytes with identical flame/bin digests and archive SHA-256.
Append costs increase; full flame rebuild time is roughly unchanged. Maximum
unique wide-chain storage is 19,564,120 bytes under 32 MiB. The largest archive's
decoded allocation peak falls from 232,302,100 to 209,700,876 bytes. No larger
capture default, rolling history or spool was adopted. Rebuilt executable installed

Grok delivered T18 during integration. Reproduced 32 passing test executions,
ARM64 probe cross build, and host libdw lookup of an ARM64 FDE returning column
30. Added two adversarial tests: absent LR falsely reports stack completion,
and an empty sample body is classified decoded. Both fail on the delivered
prototype; its existing imported tests pass. [Review](T18_AARCH64_SAMPLING_REVIEW.md)
also tracks register preservation after stack-budget exhaustion and the gap
between the miniature archive experiment and real compatibility. Native perf
is still denied per Grok's transcript. No ARM64 code or new format was adopted.

External LLM opportunity: compare captures using stable raw sample ordinals and
coverage; explain capacity or partial-state limits without treating absent
registers as zero. Compact storage changes memory cost, not observed duration.
An ARM64 synthetic-rule result is not native sampled-stack evidence.


## 2026-10-01 — Recorded-view worker foundation; Grok owns T17

The user assigned T17 to Grok. Recorded that ownership without changing his
artifact paths. Claude's T16 final report appeared during this work and is marked
delivered, with integration review pending. Its completed-capture reconstruction
and proposed analysis/UI changes remain separate from recorded callchains.

Built a private snapshot and cancellable recorded-graph worker to prepare live
flame builds off the event loop. Compact samples clone their chunks directly;
threads, mapping history and offline annotation strings have private ownership.
Only immutable captured ELF bytes are borrowed, with source lifetime pinned by
the job. Workers have private descriptors/caches and no shared lazy libdw state.
Published graphs and their clones own label text, surviving capture retirement.
The snapshot is graph-only: raw saved state/scheduling/intervals are not copied.

The [proposal and critical review](M2_RECORDED_VIEW_PROPOSAL.md) remain pending:
GUI publication and MCP pending/stable-view identities are not enabled. This
foundation has **154/154 ReleaseSafe tests, 24/24 build steps**, including injected
allocation failure, cancellation, source mutation, capture/result destruction,
filtered recursive/mapping parity, offline labels and store accounting. The
largest-path fixture with unique wide chains peaks at 53,858,607 bytes under the
64 MiB job budget; snapshot/build times are 19.55/54.31 ms. Repeated deep chains
use 37,776,431 peak bytes and 9.49/49.65 ms. These are one-run synthetic results,
not measured GUI latency or evidence to raise limits. Source captures/ELF bytes,
thread stacks and simultaneous published/UI views are outside that job budget.

External LLM opportunity: poll/page a stable snapshot, cite its revision/filter
and compare it to current collection progress. Never combine counts or node IDs
from different snapshots or recorded/reconstructed bases; a pending view is not
an empty capture. This motivates the proposed stable view identity contract.


## 2026-10-01 — Recorded flame workers integrated

Adopted the user's approved snapshot/view behavior. Live GUI and MCP recorded
flame builds now run on the bounded worker; collection and input continue while
it builds. Published graphs own their labels; capture retirement cancels without
joining an active worker on the event loop. The GUI shows displayed/collected
sample counts and revision lag, preserves valid ancestry, and latches failures.
Clock-only revisions retain the immutable graph identity. Source/disassembly
lookups and export serialization remain synchronous, outside this change.

MCP's initial live graph request can omit revision to bind current input without
racing every collector drain. Accepted jobs/pages use the exact revision, filter
and view ID. Pending, busy, evicted and failed results are distinct; explicit
retry is required after failure. Exports reuse completed snapshot graphs and
publish/audit only once ready. Offline artifact behavior and archive bytes are
preserved. [Contract and measurements](M2_RECORDED_VIEW_PROPOSAL.md).

**157/157 ReleaseSafe tests, 24/24 build steps passed.** Owned live tests covered
640 threads, mapping changes/subsets, raw samples, source retention, archive
save/reopen/asset isolation/no-sync, and full/filtered/empty export conservation.
Private headless Sway verified flame labels, selection/zoom/source, execution
controls and resize. The snapshot stress run dispatched at 7,051 samples in
2.77 ms (0.409 ms input copy, 10.47 ms worker build, 812,475-byte peak), with
1.87 ms maximum measured ping and ongoing collection. These fixture timings do
not replace the earlier pathological ~20 ms snapshot-copy bound.

The stale archive oversize test now exceeds the already-existing 128 MiB limit;
production limits did not change. Updated the legacy timeline GUI client's view
identity handling; that full script was not rerun (the private GUI smoke above
was). Changed Python files passed syntax checks; Zig formatting and diff checks
passed. The final binary was installed by replacement after backing up the old
one; an existing running instance retains its prior executable.

External LLM opportunity: poll/page an immutable view while following live
capture progress, and state snapshot lag explicitly. Do not combine node IDs or
counts across views, or use a graph's old revision for current timeline queries.
T16 reconstruction remains a separate delivered patch awaiting review.


## 2026-10-01 — T17 configured host evaluation; global setup authorized

The user challenged treating an unconfigured environment as a capability limit,
then explicitly asked to configure it globally and report the changes. Mounted
tracefs, changed `kernel.perf_event_paranoid` from 2 to 1, and persisted.
Package installation or persistent executable capability was needed. The sysctl
applies host-wide; tracefs group access alone is not a perf authorization policy.
[Exact configuration, backups, undo guidance and results](T17_CONFIGURED_RERUN.md).

Preserved Grok's original packet and compiled an isolated copy, correcting a
`waitpid(WNOHANG)==0` cleanup check. The ReleaseSafe library/probe and C fixture
built. All 45 traced runs passed: five CPU/wait/copy cases each as ordinary user
with no effective capabilities, root, and user with only temporary CAP_PERFMON.
All had both rings decoded, no foreign spans, zero reported loss/drops, completed
fixtures and descriptor/child cleanup. Five untraced pairs per combination make
90 recorded runs. Real IDs/formats came from tracefs. A separate check at
paranoid=2 denied the ordinary user with EACCES but worked with root/CAP_PERFMON;
the working value 1 was restored and verified.

Ordinary-user medians: CPU 4.510 -> 4.648 ms, programmed 50 ms pipe wait
50.198 -> 50.223 ms, 256 KiB copy 0.448 -> 0.899 ms. The traced read was
50.070–50.096 ms. This corrects the capability conclusion but exposes roughly 2x
copy perturbation; syscall timing should be opt-in. Each run retained an unknown
span, and none of these short end-drain probes validates sustained draining,
large thread counts, lifecycle identity or total RSS. No production syscall
collector/default/format/MCP change is integrated. The original packet and the
configured-run evidence are checked in for reproduction, not adopted as a
production patch. Logs/source hashes are linked from the report.

External LLM opportunity: correlate syscall elapsed intervals with scheduling
and CPU samples, reporting scope, clock alignment, loss and unknown spans. Such
correlation suggests follow-up experiments; it does not establish the cause of
an I/O wait or turn elapsed syscall duration into CPU or device service time.


## 2026-10-01 — User-facing workstation setup guide

Added root SETUP.md and linked it from README/profiling. It distinguishes
ordinary CPU sampling from the experimental syscall prerequisites, documents
trusted-group tracefs access and perf/sysctl persistence, and explains optional
same-user ptrace attach. Included one short security warning, configuration
backups, normal-user verification, existing-mount handling and rollback. Checked
permission explanations against primary kernel perf/tracefs/Yama documentation
and the measured T17 configuration. No system settings were changed for this
documentation task. Grok's independently rerun evaluation remains with Grok.
Validated all nine shell examples with bash syntax checks without executing
configuration commands, plus local links and diff whitespace. Claude's T19 GUI
expression task is intact and owns separate prototype paths; included its new
task file so the already-committed index link resolves in a fresh checkout.

External LLM opportunity: diagnose the specific failed syscall and observed
host capabilities instead of prescribing a universal permission reduction.
A sandbox refusal, missing tracepoint, ptrace denial and resource limit are
different observations; successful metadata reads alone do not prove collection.


## 2026-10-01 — T17 take 2 reviewed; boundary attribution verified

Reviewed Grok's product recommendation against the configured measurements and
current Session/UI/MCP paths. Agree with opt-in, selected-TID collection and
actual opens as the capability test. [Review](T17_TAKE2_REVIEW.md) corrects the
claim that errno alone identifies an internal kernel permission gate, requires
field widths/signedness/byte order in the format check, and flags an ambiguous
partial-start contract. Recommended transactional setup for a requested combined
capture, with explicit CPU-only retry, remains a proposal for user review.

A source inspection contradicted the memo's unknown-span explanation. Built an
isolated instrumented probe: **10/10 ReleaseSafe tests, 6/6 build steps**. Three
ordinary-user CPU/wait/copy runs at the existing paranoid=1 setting confirmed two
unknown boundaries: an initial read exit without an entry, and terminal
exit_group entry without an exit. Only the latter contributes to unknown_after=1.
No foreign spans, loss or drops were reported; fixture results and cleanup passed.
The read wait was 50.089 ms. Raw logs, hashes and a reproduction patch. No
system configuration or production capture behavior changed. Delivered memos
remain preserved as handoff evidence.

Next evidence needed: sustained/fair draining, pairing across drains, loss and
capacity, real task lifetime, and accounting for two rings/fds per selected TID.
The one-thread success does not validate thousands of threads. No additional
agent assignment or external message was sent.

External LLM opportunity: diagnose from observed stage/errno/identity and keep
boundary artifacts separate from lost events. A lone errno cannot establish
which kernel hook refused access; a non-returning exit syscall is not proof of
missing permissions or a bottleneck.


## 2026-10-01 — Lua scripting recorded as a future feature

The user requested Lua scriptability, bindings such as dbg.eval(), configuration
knobs and possible MCP exposure, then clarified that this is a future feature.
Recorded it in TODO, the roadmap (milestone open) and the machine-interface
sketch. Runtime/API/default choices and implementation assignment are deferred.

External LLM opportunity: compose debugger queries through Lua using the same
bindings as human scripts, with the caller's existing authority and explicit
execution/resource limits. Concrete permission and scheduling choices need
review when this feature is taken up.


## 2026-10-01 — T16 rebased, corrected and prepared for review

Rebased Claude's reconstructed-stack/inspector patch in an isolated export,
preserving recorded-view workers and pinned capture lifetime. Prepared [the
candidate and short critical review](M2_DERIVED_VIEW_PROPOSAL.md). New UI,
presets, MCP basis and algorithm choices are awaiting user approval; production
sources and the installed binary have not changed.

Corrected cancellation after completion, failed-job/copy retry loops, GUI/MCP
worker contention, duplicate per-sample label allocation, explicit basis and
view-identity checks, empty-filter sample inspection and small-window controls.
The inspector now scrolls and reports displayed/total frames; verified a 15-frame
sample at 640x480. Sample budgets follow drain order rather than a guaranteed
chronological prefix. Undefined-RA handling matches installed libdw semantics and
DWARF section 6.4.4; “complete” does not include optimized-away or inline calls.

Validation: 169/169 ReleaseSafe tests, four optimized GCC/Clang live cases with
per-sample/aggregate parity and archive replay with/without verified assets,
existing recorded-worker live regression, stale/cross-basis API guards and
private Sway small/wide runs. At 16,384 samples, builds took 176–878 ms, counted
peaks 116–120 KB and pending MCP pings <=1.75 ms. This is a small-binary fixture,
not a large-game RSS bound; libdw/captured ELF memory is outside that allowance.
A low-budget case kept all 16,384 samples in the denominator, with 13,745 explicit
leaf-only gaps. No system configuration changes or interactive desktop use.

The [review bundle](research/t16-integration/README.md) keeps patch/base hashes,
independent harness copies, summary results and screenshots. Original handoff
artifacts and concurrent expression-watch work were preserved. No new external
agent assignment was made. Further regression runs should address a concrete
remaining risk, rather than repeat completed fixture checks.

External LLM opportunity: compare recorded/reconstructed paths using per-node
sample citations, state coverage and missing-asset reasons, and explain why a
flame width is not evidence of a fully observed call chain. These are read-only
queries under existing agent authority. Rich reconstructed frame details and
live reconstruction remain follow-ups.


## 2026-10-01 — T16 adopted and installed

The user approved the reviewed candidate with “Adopt T16”. Applied all 15 files
with exact reviewed hashes, including native B/I interactions, stack presets,
reconstructed aggregate workers/MCP citations and sampled-unwind v2. Defaults
remain stacks off / 32 MiB; archive bytes, existing agent scopes and capture
limits are preserved. Backed up all existing files and atomically installed the
ReleaseSafe outputs so running executables were not overwritten in place.

Main-tree verification passed 169/169 tests and 24/24 build steps. The installed
binary passed all four GCC/Clang live/per-sample/aggregate/archive cases; private
640x480 Sway verified setup, pending state, basis switching, a cited 10-frame
sample with scrolling and clean shutdown. [Logs and hashes](research/t16-adoption/README.md).
Updated README, profiling/sample/MCP/preferences docs and roadmap/task status.
No system configuration or interactive desktop changes. Original handoffs and
concurrent expression-watch artifacts remain untouched.

External LLM opportunity is now implemented through observe-scope reconstructed
views: cite a node's example sample, inspect saved evidence, and explain coverage
or asset gaps before interpreting costs. Reconstructed export/frame detail and
live reconstruction remain follow-ups; Speedscope still uses recorded callchains.


## 2026-10-01 — first native ARM64 headless debugger

The user asked to advance ARM64 toward a demo and chose headless first, GUI next.
Rechecked Jetty over authenticated SSH without forwarding the agent. Ubuntu
18.04.6/Linux 4.9.337/glibc 2.27 remain installed; Zig is absent. The current
perf policy is -1 and a self-owned software event opens successfully. This
supersedes permission denial as a current observation, not the outstanding T18
sample-decoding/unwind review. No host policy or package changed.

Added a real graphics-free build and cross-linked against read-only copies of
Jetty's installed libdw/libelf/Capstone. The explicit target is
`aarch64-linux.4.9-gnu.2.27`. Added native GETREGSET/SETREGSET, full-word BRK
patching/overlay/restoration, target/image ISA checks, ARM instruction flow,
register expressions and LR-aware CFI. The old libdw iterator gets an explicit
DWARF-4 path; newer units fail clearly. Existing x86 MCP register arrays and
numeric breakpoint bytes are preserved. ARM profiling and hardware watches
return explicit unsupported errors; existing archive bytes remain x86 and
foreign-ISA assets are rejected even when hashes match.

Native tests cover real xodb launch, register writes, overlapping breakpoint
memory writes, instruction/source stepping, step-over, four-frame CFI, locals and
expressions, agent scope, multithread cleanup and attach/detach restoration.
Final main-tree verification passed 172/172 ReleaseSafe tests. The checked-in
Jetty build helper passed 14/14 steps, and the final native acceptance/demo
passed. The x86 MCP/source/private Sway smoke also passed before the final
archive-only guard. GCC 7.5 on Jetty built O0/O2 fixtures; O2 `amount` needs an unavailable entry
value, also unavailable in installed GDB, while `next=12` and CFI work. The
[demo and critical assessment](ARM64.md) distinguish these fixtures from broad
ARM64, GUI, modern-kernel or profiling acceptance. [Evidence](research/arm64-demo/README.md).

Claude's T19 completion arrived during this work. Recorded it as delivered and
queued its separate UI review; the expression-watch handoff remains untouched.

External LLM opportunity: drive the same scoped MCP tools over SSH, compare
ARM/x86 stop and DWARF evidence, and summarize capability gaps. Keep unavailable
entry values and missing native profiling evidence explicit; successful SSH or
cross-compilation alone does not establish target support.

## 2026-10-01 — adopted remote GUI over SSH and TCP

The user assigned cross-platform builds to Claude and requested remote debugging
in the workstation GUI, then explicitly allowed direct TCP on the LAN and
approved the first remote UI/CLI after reviewing the screenshot and tradeoffs.
Kept build scripts, the local workspace and T19 handoffs untouched.

Added a worker-owned MCP client and an architecture-neutral bounded view. The
server retains ptrace, symbols, CFI and register interpretation; the x86 GUI
displays ARM registers without using local /proc or native register structures.
A lightweight summary polls generation/state without copying every thread.
The server shares only its explicitly configured source file; this is labelled
as provided source, without claiming compiler/source identity verification.

SSH launches one headless xodb with quoted arguments, strict host keys and no
agent forwarding. TCP binds only an explicit address, accepts one client and
closes its listener. It is plaintext and unauthenticated as requested for the
trusted LAN. No system packages, services, firewall rules or desktop session
were changed. Remote staging uses fresh workdirs.

Validation exercised real x86 and ARM64 targets: fragmented handshake, scoped
inspection/control, stale generation rejection, source breakpoints, stack/frame
selection, locals, stepping, interrupt, EOF cleanup, explicit detach and restored
probe bytes after SIGHUP. Private Sway GUI tests drove native Jetty via both
actual SSH and direct LAN TCP; the TCP proxy also forced a disconnect and
verified the GUI remained open with controls disabled. Full regression: 178/178
ReleaseSafe tests. A sandbox run initially denied ptrace (157/174 passed); the
permitted host run passed. The GUI test caught an empty-object/array handshake
encoding mistake before adoption. Old Jetty Python needed a 3.6-compatible test.

Limits: 256 visible threads, 64 frames, 128 locals, 32 instructions, 48 KiB
provided source, 1 MiB wire messages. Remote profiling and a local MCP proxy
for another agent are pending. Disconnection marks the last snapshot stale;
there is no action replay/reconnect, and an unreachable host cannot confirm
cleanup. Source mappings/content verification and controller ownership are
needed before those workflows grow. [Usage/critical review](REMOTE_DEBUGGING.md)
and [evidence](research/remote-gui/README.md).

External LLM opportunity: inspect the same bounded target-side snapshots to
explain cross-architecture stops and unavailable values, propose source mappings,
and compare independent GDB observations. Treat generated mappings as suggestions;
keep file identity, generation checks and execution scope in deterministic code.

Final remote review aligned the parser string limit with the 1 MiB wire frame:
MCP text mirrors of otherwise bounded views can exceed 64 KiB. Added an 80 KiB
reply regression; the 178-test suite passes. The installed stdio MCP smoke also
passes, retaining the local machine interface.

## 2026-10-01 — remote Step at the loader stop

The user reported that Step flashed a pending message but repeatedly logged the
same ARM64 generation 4, unknown symbol and source line 0. Reproduced the bug
in a private GUI before changing production code: the remote GUI sent
`step_source` at the initial loader stop; the server returned `NoDebugInfo` and
the PC remained unchanged. The earlier GUI acceptance only stepped after
reaching a source breakpoint, leaving this startup path uncovered.

Matched the existing local GUI behavior: Step/Over use instruction operations
when the executing frame has no source line, and source operations when it does.
The caller being inspected does not determine the executing frame's source
availability. Successful step requests reset inspection to frame #0 so callers
do not hide execution progress. Rejected remote actions now print their names
and reasons to stderr; messages generated by the remote GUI take precedence
over unrelated inspection diagnostics. The remote server and scope checks are unchanged.

Extended the private GUI regressions to click Step and Over at startup, verify
actual PC changes, then source-step while inspecting a caller and require frame
#0 afterwards. The before-fix check fails, the corrected native ARM64 SSH and
direct-LAN checks pass, and all 179 ReleaseSafe tests pass. Installed the updated
workstation binary after backup. Jetty's existing r2 server needs no update.
[Evidence](research/remote-step/README.md).

External LLM opportunity: compare action requests, explicit failure results and
stop generations to distinguish missing source metadata from transport failure;
do not infer execution from a flashed pending state or repeated identical
snapshots. Startup and non-source locations belong in generated demo scenarios.


## 2026-10-01 — ARM64 hardware-watchpoint investigation

The user requested investigation of adding ARM64 watches. A new standalone
Linux-UAPI probe passed 23 cases on native Jetty (`4.9.337-tegra`, UID 1000),
using only owned children and a fresh remote workdir. It found four data
slots, six instruction slots, working aligned 1/2/4/8-byte write watches,
read/write watches, repeated hits, per-clone installation, exec reset, removal
and detach. No sudo, system changes or production binary replacement occurred.

The main integration hazards are now measured: the trap occurs before the
access; plain Continue traps again; replaying GETREGSET control bits failed to
rearm on this kernel; and a wide store can report an address outside the watched
subrange. Retaining the requested configuration fixed the rearm probe. Exact
successful memory reads distinguish pre-access 3, completed 7 and second write
11. The original T13 handoff was left intact. Production xodb remains explicitly
unsupported for ARM watches until its lifecycle and evidence model are adapted.
[Findings, failed candidate, native transcript and integration plan](research/arm64-watchpoints.md).

The report proposes retaining raw trap evidence and separately recording an
internal completion step for before/after write investigations; this presentation
choice remains for user review. Backend regression gates include signals/faults,
rollback, software-breakpoint interaction and pre-existing debug-state restoration.
External LLM use: compare raw and completed stop transcripts to identify missing
tests, without guessing values from failed reads or exact IDs from ambiguous
fault addresses.


## 2026-10-01 — ARM64 watches integrated with access completion

The user approved completing ARM64 watch accesses internally after asking how
GDB/LLDB handle them. Source review confirms both use internal stepping before
normal watchpoint reporting. Added a Linux ARM data-bank adapter, per-thread
pending hits and asynchronous completion, explicit raw/completed/interrupted
record fields, and investigation instruction evidence at the raw trap PC.
Multi-watch attribution remains candidate-based; same-value stores still stop.

Remote GUI locals now carry address/size information: select a scalar and W to
start an investigation; V opens installed watches and W removes a selection.
All commands use existing MCP scopes, generation checks and audit. The local
workspace only gains honest formatting for candidate/unavailable event values.

Jetty passed 26 real xodb/MCP cases. Four native backend tests exercise injected
fault/signal/cancellation, failed installation/restore and preservation of foreign
data/instruction debug banks, rearm-error SIGTRAP suppression and last-thread
exit cleanup. The initial native run caught disabled metadata
surviving clear/detach; accepting cleared zero-address slots fixed reattach.
The x86 suite passed 180 tests, with the four ARM-only tests run on Jetty instead.
The first sandbox run's ptrace/socket denials were rerun with appropriate access.
GCC/Clang source/watch evidence and private remote GUI checks cover shared paths.
[Full integration notes, evidence, source references and limits](research/arm64-watchpoints/integration.md).

Installed the tested workstation binary and backed up/replaced Jetty's r2 demo
server binary. Tests used owned processes/private Sway; no system configuration
or package changes. External LLM opportunity: compare raw/completed event
sequences and source instructions to propose missing architecture cases; do not
replace deterministic availability, completion or attribution checks.

Final adversarial review found and fixed two cleanup paths: a failed watch rearm
must clear the debugger-owned single-step SIGTRAP before a later resume, and a
last-thread TRACEEXIT must skip software-trap restoration into its disappearing
address space. A dedicated native test injects both cases; all four ARM backend
tests and the 26 MCP scenarios pass, followed by the x86 regression gate.


## 2026-10-04 — Startup themes across native GUI views

Added a data-only theme loader with built-in dark, light and contrast palettes,
strict versioned JSON and owned palette values. `--theme` overrides
`appearance.theme`; relative preference paths resolve beside the selected
configuration. Themes load once before the GUI starts. Successful loading is
silent; invalid files report on stderr and fall back to dark. Local debugger,
core/archive, imported-profile and remote GUI drawing use the same colors.
Headless services accept preferences without opening appearance assets.

The user selected passive, startup-only behavior: no theme hotkeys, popups,
reload worker or file polling. Restarting applies edited theme files. Fonts,
zoom, density, saved layouts and docking remain separate work. Custom colors can
reduce contrast; built-in light and contrast text have deterministic contrast
checks, while the original dark palette is retained. The [workflow and schema](THEMES.md)
document these boundaries.

Validation covers parser ownership and errors, preference paths/precedence,
built-in contrast and private-Sway startup in local/imported/remote views.
The GUI test verifies quiet success, unchanged palette and stop generation after
file edits or the former hotkey, next-startup adoption, small windows, invalid-file
fallback and headless operation. No target permissions, packages or system
settings changed.
