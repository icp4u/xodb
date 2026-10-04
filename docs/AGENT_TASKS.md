# Independent agent tasks

These packets can be given to Grok, Claude, or another coding agent. T01 (Fable/Claude) and T02 (Grok) are delivered and integrated/reviewed.
T03 (Grok) and T05 (Fable/Claude) are delivered; Codex integrated the lifecycle fixes and both UI patches. T04 is delivered and reviewed; T06 collection and CPU flame graphs are integrated. T07 is integrated with the user’s active-layout-only shortcut policy. Target control, semantic integration, UI, MCP, and shared build
files normally remain with Codex; the current dispatch below records the user's
cross-platform build assignment to Claude. Each agent must stay within its listed owned paths.

| Task | Work type | Owned paths | Depends on | Status / owner |
| --- | --- | --- | --- | --- |
| [T01 ELF and symbol reader](tasks/T01-elf-symbols.md) | Implementation | `src/binary/elf.zig`, `tests/fixtures/elf/`, `docs/research/elf.md` | None; consumes bytes | Delivered — Fable/Claude |
| [T02 DWARF normalization plan](tasks/T02-dwarf-research.md) | Research and contract proposal | `docs/research/dwarf.md` | None; coordinate assumptions with T01 | Reviewed — Grok |
| [T03 Debugger lifecycle audit](tasks/T03-target-audit.md) | Review and reproductions | `docs/research/target-audit.md`, `tests/repros/target/` | Current target sources | Integrated — Grok review / Codex fixes |
| [T04 Profiling workload suite](tasks/T04-profiling-workloads.md) | Standalone fixtures and measurement plan | `tests/workloads/`, `docs/research/profiling-workloads.md` | None | Delivered and reviewed — Claude |
| [T05 UI and rendering review](tasks/T05-ui-review.md) | Review and measured findings | `docs/research/ui-review.md`, `docs/research/ui-review/` | Current runnable UI | Integrated — Claude patches / Codex fixes; follow-ups in T07 |
| [T06 CPU sampling collector](tasks/T06-perf-sampling.md) | Implementation and live/offline tests | `src/profile/linux_perf.zig`, `src/profile/records.zig`, `tests/repros/perf/`, `docs/research/perf-collector.md` | None; T04 optional | Integrated — Grok collector / Codex captures, flames and MCP |
| [T07 Keyboard and cursor adapter](tasks/T07-wayland-input.md) | Adapter and integration prototype | `src/platform/input.zig`, `tests/repros/input/`, `docs/research/input.md`, `docs/research/input/` | Current sources; after T04 | Integrated — Claude adapter / Codex integration |
| [T08 Scheduling events](tasks/T08-scheduling-events.md) | Collector patch and measured evidence | `tests/repros/scheduling/`, `docs/research/scheduling.md`, `docs/research/scheduling/` | Current collector; T04 fixtures optional | Integrated — Grok collector / Codex model and MCP |
| [T09 Profile timeline](tasks/T09-profile-timeline.md) | Standalone UI and interaction prototype | `src/ui/timeline.zig`, `tests/repros/timeline/`, `docs/research/timeline.md`, `docs/research/timeline/` | Current UI; synthetic data permits work before T08 | Integrated — Claude timeline / Codex shared UI |
| [T10 Sampled-stack unwinding](tasks/T10-sampled-stack-unwind.md) | Collector/decoder/unwinder prototype and measurement | `tests/repros/sampled-unwind/`, `docs/research/sampled-unwind.md`, `docs/research/sampled-unwind/` | Current profile/libdw model | Integrated — Grok prototype / Codex raw retention, MCP worker and archive extension |
| [T11 Native capture archive](tasks/T11-native-capture-archive.md) | Versioned bounded codec and reopening contract | `tests/repros/capture-archive/`, `docs/research/capture-archive.md`, `docs/research/capture-archive/` | Current capture/timeline/export | Integrated — Fable/Claude codec / Codex revised artifact and worker workflow |
| [T12 Remote Android/Linux](tasks/T12-remote-debugging-research.md) | Research and fake-transport prototype | `tests/repros/remote-protocol/`, `docs/research/remote-debugging.md`, `docs/research/remote-debugging/` | Existing target/scope contracts | In progress — native-executable Pixel service and desktop GUI over ADB forwarding verified; broader T12 research remains |
| [T13 AArch64 target](tasks/T13-aarch64-target.md) | Architecture boundary and standalone native prototype | `tests/repros/aarch64/`, `docs/research/aarch64.md`, `docs/research/aarch64/` | Local work independent; native gate after Jetson readiness | Delivered and reviewed — Grok; Codex integrated the [first real headless ARM64 slice](ARM64.md); watchpoints/extended coverage remain |
| [T14 Capture setup and diagnostics](tasks/T14-profile-controls.md) | Native GUI prototype and integration patch | `tests/repros/profile-controls/`, `docs/research/profile-controls.md`, `docs/research/profile-controls/` | Current capture model; synthetic data for development | Integrated — Fable/Claude panel / Codex approved integration |
| [T15 Capture scaling](tasks/T15-capture-scaling.md) | Resource accounting, storage prototype and benchmarks | `tests/repros/capture-scaling/`, `docs/research/capture-scaling.md`, `docs/research/capture-scaling/` | Current capture/archive; synthetic T10 side data | Integrated — Fable/Claude prototype / Codex corrected storage and user-approved configurable ceiling |
| [T16 Derived-stack views](tasks/T16-derived-stack-views.md) | Native sample inspection and reconstructed flame prototype | `tests/repros/derived-stack-views/`, `docs/research/derived-stack-views.md`, `docs/research/derived-stack-views/` | Integrated T10/T14; no T15 dependency | Integrated — Fable/Claude prototype / Codex reviewed workers, inspector and MCP basis; user-approved |
| [T17 Syscall context](tasks/T17-syscall-context.md) | Task-scoped timing collector feasibility and tests | `tests/fixtures/syscall-context/`, `docs/research/syscall-context.md`, `docs/research/syscall-context/` | Current perf/scheduling contracts | Delivered and reviewed — Grok; configured rerun passed; [take 2 corrections](T17_TAKE2_REVIEW.md), production collector pending |
| [T18 ARM64 sampled state](tasks/T18-aarch64-sampled-state.md) | Architecture adapter, raw evidence and unwinding prototype | `tests/repros/aarch64-sampling/`, `docs/research/aarch64-sampling.md`, `docs/research/aarch64-sampling/` | T13 architecture handoff; local synthetic work independent of host | Delivered and reviewed — Grok; [integration gaps](T18_AARCH64_SAMPLING_REVIEW.md), native sampling pending |
| [T19 GUI expression evaluation](tasks/T19-expression-watch.md) | Native expression entry and watch-list prototype | `tests/repros/expression-watch/`, `docs/research/expression-watch.md`, `docs/research/expression-watch/` | Current evaluator, value view and locals pane | Integrated — Claude prototype / Codex reviewed model and UI; [user-approved behavior](M2_EXPRESSION_WATCH_PROPOSAL.md) |

## QEMU architecture dispatch (2026-10-02)

The user supplied seven local Linux guests with configured SSH aliases and
requested one Claude task for each. [Overview and copyable handoff](QEMU_ARCHITECTURES.md);
[shared acceptance/ownership contract](tasks/QEMU_TARGET_CONTRACT.md).
Codex continues the approved x86 functional work and owns shared integration.
**2026-10-03 review:** Claude delivered T20–T23; Grok delivered T25/T26.
The user has assigned T24 to Claude. [Review, reproduced defects and follow-ups](ARCHITECTURE_HANDOFF_REVIEW.md).
T20/T21/T22 have live service candidates; T23 is a toolchain-blocked metadata
candidate; T25/T26 remain partial probes. None of these candidates is integrated.

| Packet | SSH alias | Owned repro/report prefix | Status / owner |
| --- | --- | --- | --- |
| [T20: RISC-V 64](tasks/T20-riscv64-target.md) | `riscv64` | `tests/repros/qemu-riscv64/`, `docs/research/qemu-riscv64.md`, `docs/research/qemu-riscv64/` | Reviewed candidate — Claude; shared fixes/integration pending |
| [T21: ARM 32](tasks/T21-arm32-target.md) | `arm32` | `tests/repros/qemu-arm32/`, `docs/research/qemu-arm32.md`, `docs/research/qemu-arm32/` | Reviewed candidate — Claude; ARM unwind bound needs correction |
| [T22: PowerPC 64 LE](tasks/T22-ppc64le-target.md) | `ppc64le` | `tests/repros/qemu-ppc64le/`, `docs/research/qemu-ppc64le.md`, `docs/research/qemu-ppc64le/` | Reviewed candidate — Claude; shared fixes/integration pending |
| [T23: Motorola 68k](tasks/T23-m68k-target.md) | `m68k` | `tests/repros/qemu-m68k/`, `docs/research/qemu-m68k.md`, `docs/research/qemu-m68k/` | Reviewed partial candidate — Claude; live toolchain blocker, evaluator fix |
| [T24: PA-RISC 32](tasks/T24-hppa-target.md) | `hppa` | `tests/repros/qemu-hppa/`, `docs/research/qemu-hppa.md`, `docs/research/qemu-hppa/` | In progress — Claude (assigned by user) |
| [T25: SPARC V9 64](tasks/T25-sparc64-target.md) | `sparc64` | `tests/repros/qemu-sparc64/`, `docs/research/qemu-sparc64.md`, `docs/research/qemu-sparc64/` | Reviewed partial handoff — Grok; decoder and Stage B follow-ups |
| [T26: SPARC 32 compat](tasks/T26-sparc32-target.md) | `sparc32` | `tests/repros/qemu-sparc32/`, `docs/research/qemu-sparc32.md`, `docs/research/qemu-sparc32/` | Reviewed partial handoff — Grok; decoder, Stage B and regset-write follow-ups |

T24 remains with Claude; the review includes separate corrective handoffs for
Claude and Grok. Do not edit another packet or shared production files in the
common checkout.

## Future queue — not yet assigned

User-added 2026-10-01; [scope](MILESTONES.md#future-display-and-architecture-work):

- Skinnable display and flexible, persistent workspace layouts.
- AArch64 watchpoints and remaining feature coverage; build on T13/T18 and
  coordinate with Claude's current build assignment.
- Research debugging other architectures, with an explicit validation plan.
- [Periodic unmet-wants review](MILESTONES.md#periodic-agent-reassessment-of-unmet-wants):
  identify valuable missing workflows, including ideas outside today's backlog;
  deliver a short ranked review with evidence and proposed experiments.

Prepare owned-path packets when these tasks are assigned. For the recurring
review, the proposed cadence is milestone boundaries and roughly weekly during
active development; scheduling automation remains open.

## Current dispatch update

**2026-10-01 remote/build split:** the user assigned cross-platform builds to
Claude and SSH/TCP remote debugging to Codex. Codex's adopted remote GUI is now
verified against native ARM64 Jetty over both transports; [usage and owned-file
boundary](REMOTE_DEBUGGING.md). `build.zig`, `scripts/build-jetty` and the local
workspace were not edited for that integration. Coordinate any needed changes
to `src/main.zig`, which contains the new remote CLI path.

T10, T14 and T15's bounded compact storage are integrated. T15 preserves the default
sample count and provides an opt-in 65,536 ceiling; [measurements and adapter notes](M2_CAPTURE_SCALING.md)
cover the corrected store and the T16 rebase. The user-approved [larger ceiling](M2_CAPTURE_LIMITS_PROPOSAL.md) passes real
65,536-sample capture/save/reopen and private GUI checks. Preferences/MCP, archive
2.4 for nondefault limits and larger bounded worker/archive allocations are integrated.

T13 and T18 are delivered and reviewed. Local tests/cross builds and host ARM64
CFI lookup pass; [T13](T13_AARCH64_REVIEW.md) and
[T18](T18_AARCH64_SAMPLING_REVIEW.md) record the remaining evidence and integration
gaps. Jetty now passes real headless xodb debugging/MCP checks. A fresh
ordinary-user perf open succeeds; ARM profiling remains explicitly unavailable
until T18 and the capture ABI are integrated. [Demo and ARM64 scope](ARM64.md).
ARM64 data watches and the remote watch UI are now integrated, including native
completion/fault/cleanup checks. [Evidence and remaining gaps](research/arm64-watchpoints/integration.md).
The local workspace has one small watch-event formatting adjustment for
unavailable/candidate values; build files and T19 handoff files remain separate.

**T19 is integrated following user approval** (2026-10-02), based on Claude's
`docs/research/expression-watch.md` handoff. The [adopted GUI](M2_EXPRESSION_WATCH_PROPOSAL.md)
adds expression entry, a bounded watch list and expansion/paging through the
shared evaluator. Corrections cover dead-frame resurrection, stable thread
identity, CFA-match uncertainty and small-window scrolling.
[Evidence](research/t19-integration.md): 196 native tests passed (4 ARM-only skips),
90 private-GUI checks and 156 C GUI/MCP comparisons. Remote GUI entry remains
separate work; remote MCP evaluation already exists.

**T16 is integrated following user approval.** The [adopted design and evidence](M2_DERIVED_VIEW_PROPOSAL.md) cover native sample inspection, reconstructed flame workers, stack presets and explicit MCP basis/citations. [Usage](M2_SAMPLED_UNWIND.md).
**Grok delivered T17**; the [configured rerun](T17_CONFIGURED_RERUN.md) passed
after user-authorized global setup. Ordinary-user tracing works; the tiny copy
fixture costs roughly 2x. [Take 2 review](T17_TAKE2_REVIEW.md) confirms the
opt-in direction, corrects unknown-span attribution and requires precise
diagnostics and a start contract before production integration. T12 (remote
protocol) remains available. Codex integrated the user-approved [recorded-view workers](M2_RECORDED_VIEW_PROPOSAL.md). Codex owns shared integration and the
ARM64 review fixes.
Assignments remain with the user; this update sends no external message and
authorizes no host maintenance.

Before asking the user to review a proposed change, include **one or two short
paragraphs of critical analysis**: benefit, weakest assumption/tradeoff, and what
to change or defer. This is the user's standing review preference (2026-10-01).


## Earlier dispatch (2026-10-01)

The user is separately assigning Grok to update `jetty`. These are prepared
xodb packets; no new external assignment has been sent automatically.

| Lane | Start with | Next |
| --- | --- | --- |
| Fable/Claude | T14 capture setup and stop diagnostics | T15 longer-capture storage measurements |
| Grok | User-directed Jetson maintenance, then T13 AArch64 prototype | T12 remote Android/Linux research |
| Codex | T10 sampled-stack review and shared production integration | Review and integrate delivered prototypes with user-approved choices |

T13 has useful local work while Jetson availability is pending. Coordinate all
native tests with the maintenance owner; this queue does not expand the scope of
the system update. T14 and T15 consume today's model and use synthetic future
data where needed, so neither waits for T10. T12 can also be taken immediately
by another available agent; keep one owner per task and tell the coordinator.

Copyable handoffs:

> Claude: take T14 in docs/tasks/T14-profile-controls.md. Read AGENTS instructions
> and docs/AGENT_TASKS.md. Stay within the three owned paths; deliver a tested
> scratch-copy patch, private-display screenshots and exact results. Back up every
> existing file. Keep current active-layout shortcuts, capture semantics and
> provisional preferences behavior; propose new UX for review before adoption.

> Grok: after your separately assigned Jetson update, take T13 in
> docs/tasks/T13-aarch64-target.md. Read AGENTS instructions and
> docs/AGENT_TASKS.md. Stay within the three owned paths. Deliver the architecture
> map, standalone ARM64 target harness and capability evidence. Local work can
> proceed before the host is ready; coordinate native runs and label unverified
> capabilities. Keep system maintenance and xodb changes separate.

> Next free agent: take T15 in docs/tasks/T15-capture-scaling.md after confirming
> ownership with the coordinator. Stay within its three owned paths; deliver
> measured resource accounting, one bounded prototype and a tested integration
> patch. New retention policies/defaults remain proposals. Preserve raw evidence,
> T10 side-data ownership and the approved no-fsync archive policy.

All three packets isolate shared-source experiments in their own scratch copies.
Do not apply another agent's patch to the shared checkout or commit its files.
Record the base commit, test commands and any integration conflicts in the handoff.

## Completed handoffs

> Grok: take T06 in `docs/tasks/T06-perf-sampling.md`. Implement and validate the
> collector within its owned paths; return the proposed integration API.

> Claude: after T04, take T07 in `docs/tasks/T07-wayland-input.md`. Keep shared
> UI/Wayland/build changes in a proposed patch and test it in a fresh scratch copy.

The user handed off T06 to Grok and T07 to Claude on 2026-09-30, and then
confirmed T04 and T07 complete. T06 and T07 are now integrated. The original packets remain as handoff
records. The user assigned T08 to Grok and T09 to Fable/Claude (Opus 5.5) on 2026-09-30; both are now delivered and integrated. The user approved Claude’s layout on 2026-10-01.
Codex owns shared integration files; T03/T05 integration evidence is in M1.md.

## Integrated assignments and completed work

- **T08 — Grok, integrated:** optional scheduling collector and measured raw
  event evidence. Codex added bounded retention, conservative intervals and MCP.
- **T09 — Fable/Claude (Opus 5.5), integrated:** native timeline and approved
  flames-above-timeline layout. Codex connected live scheduling, GUI filters,
  per-thread debugger overlays, and a next-capture scheduling toggle.
- **Codex — integration verified:** live and completed captures share range/TID
  selection with flames and MCP. Scheduling remains opt-in. Results, limits and
  cost measurements: [M2_TIMELINE.md](M2_TIMELINE.md).

- **T04 — Claude, delivered:** frame/server fixtures, controlled stall causes,
  perf/strace measurements, and proposed M2 acceptance checks. Codex reviewed the
  research and saved results; representative game/server profiling remains an
  M2 acceptance task.
- **T06 — Grok, integrated:** CPU collector and decoder. Codex added bounded
  captures, mapping/loss handling, native flames and MCP; see [PROFILING.md](PROFILING.md).
- **T07 — Claude, integrated:** keyboard/cursor adapter with the user’s revised
  shortcut policy: active layout only; other-layout and physical fallbacks are
  deferred. Codex fixed pause/resume, composed modifiers and queued-action
  ordering, and added the current-build runner `scripts/input-smoke.py`.

- **T03 — Grok, delivered:** review/repro artifacts retained unchanged. Codex
  fixed scoped waiting, leader exit, detached-child reaping, worker exec and
  a further attach/enumeration race found in the stress repro.
- **T05 — Claude, delivered:** both patches integrated, including the styling
  explicitly approved by the user. Codex added render recovery, entry-value
  availability handling and the source-size notice. T07 covers input/cursor
  follow-up; HiDPI, font fallback/eviction and broader layout remain future work.
- T01 code and T02 research retain their original owned paths. Shared changes
  and integration remain with Codex.

## Integration status

The [timeline linked to CPU flames](M2_TIMELINE.md) is integrated. T08/T09
handoff patches remain as the delivered artifacts; do not reapply them to the
current tree. Imported application intervals and portable Speedscope export
are now integrated, as is [native capture reopening](M2_ARCHIVES.md). T10's
final report has arrived; the corrected collector/decoder foundation is integrated.
The [retained-state workflow and unwinder](M2_SAMPLED_UNWIND_PROPOSAL.md) remain
under review. T12 prepares
the eventual remote goal and remains unassigned.
No external agent job was started automatically. T10 collection/unwinding and
T12 protocol choices still need review before production adoption. The revised
T11 direction is implemented; its validation and limits are linked above.

Broader mapping-event coverage, deeper callchain
reconstruction and representative game/server measurements remain future work.
The existing observed mapping history still cannot observe all munmap/mremap
changes; timeline work does not close that coverage gap.

## Original T08/T09 handoffs (completed)

> Grok: work on T08 in docs/tasks/T08-scheduling-events.md. Read the repository
> instructions, docs/MILESTONES.md, docs/journal.md, docs/AGENT_TASKS.md and
> docs/M2_TIMELINE.md first. Stay within the packet's owned paths; deliver the
> collector changes as a tested scratch-copy patch, not production edits.
> Back up every existing file before editing. Include measured results and a
> concise handoff. Run revisions to the agreed direction by the user; ask before
> using a paid tool.

> Fable/Claude: work on T09 in docs/tasks/T09-profile-timeline.md. Read the
> repository instructions, docs/MILESTONES.md, docs/journal.md,
> docs/AGENT_TASKS.md and docs/M2_TIMELINE.md first. Stay within the packet's
> owned paths. Use synthetic data to develop independently of T08; deliver
> shared-file changes as a tested scratch-copy patch. Back up every existing
> file before editing. Include private-display interaction evidence and a
> concise handoff. Run revisions to the agreed direction by the user; ask before
> using a paid tool.

## Coordination rules

- One owner per packet. Tell the user which task you are taking; record findings
  in your owned research document. The coordinator incorporates them into the
  shared journal after review.
- Keep shared files (`build.zig`, `src/main.zig`, `src/c.zig`,
  `docs/MILESTONES.md`, and `docs/journal.md`) with the coordinator. Describe
  required integration changes in the handoff. Do not edit another packet's
  paths without coordinating its owner.
- Independent files can be developed in one workdir. For changes to shared code,
  use a separate checkout or provide a proposed patch for integration. At this
  stage project files may still be untracked; a Git worktree alone will not
  include uncommitted/untracked work. Check before assuming it contains M0.
- Follow `~/AGENTS.md` when working on this machine: notify with `~/bin/bugme`
  before outside-sandbox resource use, use private displays for automated GUI
  work, make backups, and leave system changes to the user. Keep artifacts and
  caches inside the workdir. Do not push or make remote changes.
- CPU-heavy profiling and GPU tests share the user's workstation. Coordinate
  those runs; research and small local fixtures can proceed independently.
- Existing decisions: Zig first, Linux first, external MCP agents,
  configurable agent scope, distributable dependencies including GPL where
  useful. Proposed revisions go to the user before adoption. Paid tools need
  user approval.
- Research should cite primary specifications and source implementations, give
  versions/commits, and distinguish verified facts from hypotheses. Record reuse
  provenance and license information when recommending or copying code.

## Required handoff

Each agent returns the files produced, the contract or conclusion, exact build
and test commands with results, known limits, dependency origins, and the next
integration step. Findings that suggest local or remote LLM assistance belong
in the packet's research notes. Do not report a milestone complete based only
on a design memo or an untested patch.


## T11 review update (2026-10-01)

Claude's completed [archive report](research/capture-archive.md), codec, fixtures,
patch and measured results are present. The user approved adopting Codex's
[adversarial review](M2_ARCHIVE_REVIEW.md); the revised
[M2_ARCHIVE_PROPOSAL.md](M2_ARCHIVE_PROPOSAL.md) is the adopted integration
contract. Keep the delivered paths intact. Codex owns the artifact/codec fixes,
immutable asset lifetime, recorded annotations, analysis identity, structured save
results and worker/CLI/GUI/MCP integration. The concrete validation gates are in
the proposal; no further approval is required for those agreed revisions.
The user subsequently approved a dedicated archive I/O worker and explicitly
removed durability requirements: do not carry T11's file/directory fsync calls
into production. Save results distinguish `not_published` from `published`.

T10's final report has arrived. Its drain-local register/stack buffers must
be copied into capture-owned storage before the next drain. The
[archive extension boundary](M2_ARCHIVE_FORMAT.md#t10-extension-boundary)
records the evidence and analysis separation; the collector/unwinder itself
remains pending review and production integration. The lower-level register/stack
collector and decoder are integrated with fairness and buffer-boundary corrections;
GUI/MCP capture options remain disabled pending the
[sampled-state workflow review](M2_SAMPLED_UNWIND_PROPOSAL.md).

## Original T10/T11 handoff messages (delivered); T12 remains ready

> Grok: take T10 in docs/tasks/T10-sampled-stack-unwind.md. Limit edits to its
> owned paths; return a tested prototype/patch and measured stack-capture costs.

> Claude: take T11 in docs/tasks/T11-native-capture-archive.md. Limit edits to its
> owned paths; return a bounded codec prototype, round-trip/adversarial evidence
> and a concrete native reopening contract.

> Optional research agent: take T12 in docs/tasks/T12-remote-debugging-research.md.
> Stay within its owned paths. No real device, daemon deployment or network
> configuration is authorized by this packet.

## Android native executable first demo (2026-10-02)

Codex has begun the native-executable slice of T12. The user provided an attached
non-rooted Pixel and approved one isolated probe. Registers, memory reads,
single stepping and a hardware write watchpoint passed; four data-watch slots
were reported. The probe child exited/reaped and its temporary files were removed.
[Plan, evidence and device boundary](ANDROID_NATIVE_PLAN.md). Next is an
Android/Bionic headless build and desktop GUI over ADB forwarding. This does not
complete T12 protocol/serial research or authorize further writes to the main phone.


**2026-10-02 Android service:** the user confirmed Claude's build work is finished.
Codex added the reproducible NDK/Bionic headless build and portable libc accesses.
The separately approved full-service Pixel test passed source breakpoints,
stack/locals/evaluation, source stepping, two hardware write hits and exact
process/file cleanup over ADB stdio. [Evidence](research/android-native-build.md).
No payload was left on the phone.

**2026-10-02 Android GUI:** the user approved the GUI/ADB-forward follow-up.
The desktop GUI passed source/instruction stepping, breakpoints, locals/registers,
caller inspection, hardware watch creation/hit/removal and disconnect cleanup on
the Pixel. `scripts/demo-android` manages the owned fixture, temporary forward
and cleanup; cancellation before accept and the service deadline also passed.
An exec-entry synthetic-trap correction fixed the same initial-step defect on
x86 and ARM64. [Demo](ANDROID.md), [evidence](research/android-gui.md). This does
not certify APK access, ART/Java, reconnect or profiling.


**2026-10-02 Android APK:** the user approved installing the opt-in debug
APK and testing only its separate JNI demo process. MCP and private GUI now pass
native source breakpoints, locals/eval, source stepping, hardware writes and
clean detach/file cleanup. Device TCP required a missing app permission; the
launcher uses app-UID ADB stdio with a host loopback bridge. Tests also fixed
queued peer interrupts after Continue and remote selection of the stop-causing
worker. [Demo](ANDROID_APPS.md), [journal](research/android-apk-debugging.md).
This does not complete APK-offset symbol loading, managed inspection or reconnect.
