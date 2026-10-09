# Process-tree workflow proposal

2026-10-03. Adopted with the requested 1,024-session configurable ceiling;
default remains 32.
Backend cleanup and child-transfer foundations are already checked in.

## Proposed workflow

- Opt-in x86-64 fork/vfork following: CLI `--follow-forks`, or the GUI
  **Processes (O)** panel's **Follow (F)** control on a stopped process.
- Even with following disabled, x86 process creation stops safely with
  `ProcessFollowingDisabled`; enable following or explicitly detach the family.
  This prevents untraced children from executing inherited software traps.
- New children stop for inspection. They inherit following, software/hardware
  probes and conditional/logpoint policies. Each gets an independent session,
  symbols, frame selection, memory inspection, capture and GUI workspace.
- **O** opens the process list; click or Enter selects a row. Existing continue,
  pause, step, expression and watch controls act on that selected process.
- Stable debugger process IDs never reuse a slot. Default retained limit is 32;
  CLI `--process-limit` and MCP allow 1–1024. Exited sessions retain slots.
  Limit/error cases keep the kernel child held, with a diagnostic and retry.
- MCP tools accept optional `process_id`. Omitted always means original process
  **1**, independent of the GUI selection. Replies include process identity.
  Generation, probe and capture IDs belong to that process.
- `get_processes`, `set_process_following`, `retry_process_admission` and
  `detach_process_family` expose management. Agent scope is common to all
  processes; human revocation applies immediately to every session.
- Vfork memory sharing is explicit: the parent cannot continue and software
  byte changes are refused until separation. Instruction stepping works.
  **Detach family (Shift+D inside the panel)** restores traps before releasing shared
  members and pending children; independently adopted fork children stay attached.
- CPU profiles remain per process. CLI shutdown exports refer to process 1;
  MCP can save an explicitly selected child's capture. Whole-tree aggregation,
  a remote-GUI selector and restarting a child are later work.

## Process IDs and capacity clarification

A debugger `process_id` selects one process session, which contains that
process's threads. It is separate from the Linux PID and TIDs. For example,
a parent with 800 threads and a forked child with one thread occupy two
process slots. Stable IDs route GUI/MCP work and namespace per-process probe,
generation and capture identities. MCP's default process 1 is independent of
GUI selection.

The current bounds describe different resources:

| Resource | Candidate bound | Counted unit |
| --- | --- | --- |
| Process sessions | Default 32, configurable 1–1024 | Every admitted process, including exited/detached sessions |
| Debugger threads | 1,024 per process | Currently tracked threads |
| CPU sampling threads | 1,024 per capture | Distinct enrolled thread identities, including retired identities |
| Coordinated shared-memory family | 32 targets | Related adopted targets during family cleanup |

These are implementation limits, not limits imposed by MCP or Linux. Each
process owns target/session state, symbols, probes and optional captures;
visited processes also retain a GUI workspace. Current storage is bounded by
fixed arrays, and process polling scans retained sessions. Threads share the
process's modules/address space and need separate execution/register state.
Sampling additionally consumes per-thread perf descriptors and ring memory.

The user raised a desired scale of roughly 10,000 threads on 2026-10-03.
**Process capacity decision:** the user subsequently requested a configurable
ceiling of 1,024 while keeping the default 32. That change is adopted. The
separate approximately 10,000-thread target and history policy remain future
work. Proposed direction: separate live-process capacity
from retained history, release heavy exited state while preserving stable IDs,
and evaluate 10,000-thread operation with configurable memory/resource budgets.
Simply raising the constants does not establish latency, descriptor/memory
bounds or cleanup behavior at that scale. The cumulative retained-process cap
also needs revision for workloads that repeatedly create short-lived children.

## Critical review

This makes launchers and worker processes inspectable without mixing their
addresses, breakpoint policies or capture identities. Explicit MCP IDs avoid a
dangerous GUI-selection race: an agent's next continue cannot silently change
targets because a human selected another row. Holding new children also gives
the user a predictable inspection point.

The cost is interruption: even disabled following stops on new process creation
until the user chooses adoption or family detach. A fork-heavy workload stops
frequently, and a stopped child can leave its parent waiting. Each retained session consumes memory; the
limit includes exited sessions and there is no eviction yet. Vfork source
operations needing temporary software traps remain restricted until exec/exit.
A non-vfork shared-memory clone is recognized but held for explicit coordinated
detach; it is not supported for independent debugging. A denied KCMP_VM check
also holds the child. Explicit detach preserves retryable error state, while
final shutdown still inherits the backend's best-effort detach limitation.

## Review artifacts

- [Usage and limits](PROCESS_TREES.md).
- [Implementation findings](research/process-trees.md).
- Installed build: `zig-out/bin/xodb`; `--process-limit 1024` selects the new
  ceiling. Child state is allocated on admission; MCP pages stay at 128 rows.
- Native suite: 289 passed, four ARM-only skips.
- Capacity fixture: 129 workers plus parent held together; process #130
  breakpoint/register control and normal exit/reaping passed. Configuration
  boundaries at 1,024 passed; a full 1,024-live-process load was not tested.
- Owned MCP fork/vfork/exec, inherited policy, limit, scope and detach tests:
  `tests/process-tree.py`.
- Private GUI selection, per-process continue, default-root MCP and common
  scope tests at 1280×800 and 720×480: `tests/process-gui.py`.
- Default-off safety hold and enable-following recovery also passed.
- GUI evidence: `.work/input-functional-6077912377/run-01/`.
