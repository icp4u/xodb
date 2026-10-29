# Architecture plan: dependencies, one target path, a view layer

Status: plan, 2026-10-14. Responds to [ARCHITECTURE_REVIEW.md](ARCHITECTURE_REVIEW.md), an outside review by GPT-6 Pro.
The fast path so far took deliberate shortcuts; this is the time set aside to make
the structure intentional before it gets more expensive.

## Decisions

| Area | Decision |
|---|---|
| Dependencies | A dependency linter runs in the gate from now on. Existing violations are a baseline that may only shrink. |
| Target path | Every session, local included, goes through the owner/command/publication path that remote sessions use today. One semantic handler per operation, whatever the frontend or transport. |
| Local transport | The local backend runs behind the same owner. Whether it is linked in-process or is `xodb-agent` over a pipe is a transport choice under the owner, chosen by measurement; both stay supported and gated. |
| Order | Linter first (cheap, stops new damage), then the command boundary, then local behind the owner, then the rest of the review in its order. |
| View layer | A small declarative view layer that agents can compose at runtime. Concept below; built after the small-window/look work. |

## Where we are (measured 2026-10-14, 299 Zig files)

| Edge (directory to directory) | `@import` lines | Should be |
|---|---|---|
| model → ui | 18 | 0 |
| model → mcp | 6 | 0 |
| model → render, platform | 2 | 0 |
| mcp → ui and ui → mcp | 5 and 2 (a cycle) | 0 both ways; both go through the application API |
| language → model | 78 | providers get a narrow context, not the session |
| semq → model, debug → model | 2, 2 | 0 |

The linter (below) counts distinct file pairs: model → ui 17, language → model 56.
It also finds 8 import cycles, the largest holding 75 files around the session.

`model/session.zig` is imported by 96 files (196 transitively) (model 34, mcp 29, ui 11, language 10,
profile 4, observe 3, semq 2, redot, target, main). That number is the clearest single
measure of the review's point 1.3.

## 1. Dependency linter (`scripts/deps`, gate step `deps`)

Small, stdlib-only, no build integration needed to start.

- **Graph.** Parse `@import("...zig")` in Zig and `#include "..."` in C and headers.
  Resolve to files. Emit the file graph and the layer graph as JSON.
- **Layers.** `tools/deps/layers` maps path globs to layer names. Start with
  today's directories; the layers of the review (domain, api, ports, app, analysis,
  providers, frontends, composition root) are introduced as files move, not by a rename.
- **Rules.** `tools/deps/rules` says which layer may import which. Checked
  transitively as well as directly, so a re-export module cannot launder an edge.
  First rules: model does not reach ui, mcp, render or platform; mcp and ui do not
  import each other; render and platform import no application code; providers
  (language, semq, debug, binary) do not import the session; the C runtime includes
  nothing outside `src/runtime` and the system, so the agent stays buildable alone.
- **Baseline ratchet.** `tools/deps/baseline` lists today's violating edges. A new
  violating edge fails the gate. An edge that disappeared must also be removed from
  the baseline (the check fails on a stale entry), so the number only goes down and
  is visible in every diff.
- **Budgets.** Fan-in limits for hub files, starting with `session.zig` at 96;
  lowering a budget is a one-line change in the same diff that earns it.
- **Cycles.** Report strongly connected components at file level; new cycles fail.
- **Uses beyond the gate.**
  - `affected` follows the file graph (2026-10-20). A changed source file also
    selects the steps of its nearest covered importers: walk up the imports, stop at
    each file `COVERS` maps and at each hub in `tools/deps/budgets`. An unmapped file
    runs only those steps when every upward path reaches a covered file; a path that
    ends at an uncovered root or a hub keeps the full gui tier. Measured over all 617
    source files: 28 to 49 steps per changed file on average, 2 files narrowed, the
    rest the same or wider. It is harder to fool, not faster. C runtime files are linked,
    not imported, so they stay outside this graph; their coverage is still `COVERS`.
  - The JSON is a graph-model source: xodb's own architecture in the galaxy and the
    table view (`--graph-file`), which is also a good demo of those views.
- **Not now:** Zig build modules per layer. They enforce the same rules at
  compile time and are worth doing once the layers are real; the linter gets us
  there without a build-system refactor first.

## 2. One target path

The local GUI loop today reads the session directly; the remote loop gets copied
publications from an owner worker and never sees a live pointer. The remote shape is
the better one (review 1.1). Plan:

1. **Command boundary** (review packet A). Continue, interrupt, step, breakpoints
   first: GUI and MCP both build typed requests with an explicit caller context and
   reach one handler. The MCP-tool-in-the-dispatcher re-entry goes away for each
   operation as it moves. Authority is checked when the command executes.
2. **Local behind the owner** (review packet B). The owner thread starts first and
   creates the ptrace relationship itself (ptrace is per tracer thread, so the
   target cannot be handed over later). The local GUI then renders publications
   only. A deliberately slowed backend must not slow input or drawing.
3. **Transport under the owner.** In-process C runtime, `xodb-agent` over a local
   pipe, `xodb-agent` over ssh, RSP. Same contract, capabilities reported per
   target. Run the local-agent mode in the gate so the remote path is exercised by
   every local test, then pick the default by measuring step latency, input
   latency and profiling throughput against today's baseline.
4. **Capabilities as data.** Each backend reports scoped capabilities with reasons
   (supported, not supported here, needs privilege, not present). The support
   matrix in the docs is generated from these, not hand-written.

The first command slice uses `model/command.zig` for plain request values and
`model/commands.zig` for owner-thread execution. GUI and MCP native controls and
breakpoints share this handler; MCP only decodes and encodes. Queued replies
are routed independently of the operation tag. The handler checks the live
scope/lease and process identity, passes caller identity explicitly to audit
and deferred resume, and does not import frontend or publication machinery.
Continue/step/breakpoint changes require the expected observation; interrupt
and pending-continue cancellation accept an old view. Human scope revocation
also ignores the displayed observation. Separate bounded human and protocol
urgent slots admit stop/revoke ahead of ordinary work, taking the human slot
first, without preempting a backend call already in flight. Unmigrated tools
retain the existing adapter path.

The first native-owner slice starts the worker before local live GUI attach or
launch. That thread establishes ptrace, executes controls, prepares immutable
views, serves protocol peers and tears down the native process family. The
same publication-only frame loop serves native and remote debugger windows;
native targets cannot be transferred after creation, and dispatch rejects a
different OS thread. Linux tracer membership compares against the owner task
ID, not the process leader. Native sessions do not offer remote reconnect.

Migration boundaries: native headless CLI, retained offline/investigation
workspaces and the separate `--redot-debugger` scene adapter retain their
existing lifecycles in this slice. In particular, there is not yet a scene
publication adapter; enabling the scene debugger preserves its existing UI.
These are explicit follow-ups, not a user-selectable legacy debugger mode.

`gui-local-owner` holds an actual native register read with an owned test
interposer and requires the watch editor to repaint before release. It checks
the kernel tracer ID, measures step/input latency and CPU/RSS, and retains
publication assembly/copy time, copied bytes and queue depth from opt-in input
tracing. `--baseline` measures a prior binary; `--expect-blocked` proves that
binary fails the same repaint property. Timings include the input driver and
are evidence, not absolute performance gates; overloaded hosts are labelled
not measurable. The C target suite also launches and attaches on a worker.

`scripts/gen-command-decode` generates the migrated tools' typed JSON input
decoder from `base_tools.json`; `mcp/commands.zig` only maps those values to model
operations and encodes replies. The `command-decode` gate rejects stale output
and tests changed schema limits/required fields. After a catalog edit, regenerate
with `python3 scripts/gen-command-decode`.

For behavioral comparisons, use `scripts/release-check host --compare-binary
./before/xodb` (optionally `--compare-agent ./before/xodb-agent`). This opt-in
step runs the same owned-fixture command sequence against both binaries and
compares errors, reply shapes, stop locations relative to the fixture symbol,
source lines, state and audit actions. Raw observations and stderr stay in the
step's work directory. The always-registered comparison self-test rejects
changed stop/error facts and incomplete transcripts. No installed binary or
interactive desktop is selected implicitly.

## 3. Other items found while working this week

| Item | Why |
|---|---|
| Per-architecture tables in one place (syscall numbers, register schemas, trap encodings), generated or shared C to Zig | `src/runtime/xrt_arch_syscalls.h` owns the curated x86-64 syscall row and the generated asm-generic rows. The per-thread fd event counter selects between them in `src/runtime/fdevent_syscalls.h`. `scripts/generate-syscall-tables` checks AArch64, LoongArch64 and RISC-V native rows against their Linux UAPI headers, emits the shared C/Zig tables and cross-compiles every CPU/syscall/fdflow consumer; native fdflow builds also assert each included syscall against the matching row. Register rows and software-breakpoint bytes live in `src/runtime/arch.c` for m68k, x86-64, AArch64, LoongArch64, RISC-V and ppc64le. s390x has no row. `src/runtime/events.c` still spells the x86 `syscall` opcode and restart numbers. Missing architectures remain unsupported instead of receiving a guessed row. |
| Owned child processes in the job supervisor (sidecar JVMs, helpers, agents) | Leaked sidecar JVMs ran for 21 hours; every child needs an owner and an exit rule. |
| Protocol versions and capability negotiation for every peer (agent, sidecar, remote xodb, MCP clients) | An older sidecar served stale data; a new flag would break an older remote xodb. |
| Gate builds every helper it uses from the tree under test | A prebuilt native decompiler helper made a correct change fail. |
| Privacy check as a gate step (account names, paths, hostnames in tracked files) | Done by hand before every stage today. |
| One preferences schema, generated docs and validation | Preferences grew per feature. |
| "not present / needs privilege / not supported" as one shared type | The overview showed one phrase for three situations. |

Every process xodb starts must record its owner, teardown path, and independent
exit rule at the launch site. A detached shared service such as the Ghidra JVM
uses a validated session-held connection plus idle/orphaned-endpoint exit;
per-session workers and agents are joined, reaped, or terminated by that
session. On every connection the parent checks an explicit protocol version,
producer version and required capabilities before sending state. A mismatch is
a typed refusal or one bounded replacement attempt, never an assumption that a
new option is understood. New agent and remote-xodb transports follow this
rule as their launch paths move behind the owner. The audited runtime matrix and
open gaps are kept in [CHILD_PROCESSES.md](CHILD_PROCESSES.md).

## 4. View layer for agents (concept)

Goal: an agent can put a purpose-built view on screen for the question at hand,
composed from the views we already have, laid out precisely, without anyone
writing UI code. Agents can lay out dense, data-driven arrangements per question
that nobody would hand-design for one use.

- **Primitives only.** Table, graph (galaxy), text/code, timeline, sparkline,
  memory/hex, value tree, flame. Each binds to a data source that already exists:
  the graph model, an MCP query result, a watch expression, a capture range.
- **Layout is a split tree** with weights and minimum sizes. No free positioning,
  no constraint solver, no styling language; the look layer (type roles,
  densities, pane priorities, from the small-window work) supplies sizes.
- **A view spec is data.** JSON, validated, capped (boxes, rows, refresh rate).
  MCP: `show_view(spec)`, `update_view(id, patch)`, `close_view(id)`,
  `get_layout()`. The human can save a view as a preset, and the agent sees what the human
  selects in it (shared selection, as table and galaxy already do).
- **Honesty rules carry over.** Every mark comes from its bound data; unknown draws
  as unknown; each view states its sources.
- **Dogfooding.** The built-in panes move onto the same layer one by one, which is
  what keeps it small and real.
- **Not included:** scripting, custom drawing code from agents, arbitrary widgets,
  remote HTML.

## Ownership and sequencing

| Step | Owner | Depends on |
|---|---|---|
| Linter, baseline, gate step, graph JSON | head (in-house) | none |
| Command boundary, slice 1 (continue/interrupt/step/breakpoints) | Astra-1 | linter baseline |
| Local behind the owner; local-agent mode in the gate | Astra-1 | command boundary |
| Per-architecture tables | Grok | none (with G22) |
| Child-process ownership, protocol versions | Astra-2 (sidecar first) | none |
| `affected` from the dependency graph | head | linter |
| View layer | Astra-1 | look layer (U01/U02) |
| Validity/authority split, job supervisor, providers | review packets C to F | command boundary |
