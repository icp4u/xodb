# T14: capture setup and useful stop diagnostics

Status: delivered by Fable/Claude; panel/interactions approved and integrated by Codex.

## Goal and ownership

Prototype a native capture setup view that makes existing profiling choices
usable without MCP, and makes an early stop understandable inside the GUI.
Keep the current flame/timeline workflow and the active capture's evidence intact.

Own only:

- `tests/repros/profile-controls/`
- `docs/research/profile-controls.md`
- `docs/research/profile-controls/`

Read `docs/PREFERENCES.md`, `docs/PROFILING.md`, `docs/M2_TIMELINE.md`,
`docs/M2_ARCHIVES.md`, `src/ui/flame.zig`, `src/ui/timeline.zig`,
`src/ui/workspace.zig`, `src/platform/input.zig`, `src/model/session.zig`,
`src/mcp/profile.zig` and `src/profile/capture.zig`.

Implement the prototype in a fresh scratch copy under your owned paths. Deliver
shared production changes as `docs/research/profile-controls/integration.patch`
against a recorded base commit. Do not edit actual production files, preferences,
other packets, shared docs or build outputs. Codex owns integration; new visual
and interaction choices will be shown to the user before production adoption.

## Required workflow

- A clear next-capture setup surface for duration, sample rate, scheduling and
  selected threads. Use the existing 60s / 99Hz / scheduling-off defaults and
  current duration presets including until stopped. Show custom values loaded
  from preferences accurately. Prototype numeric editing if the existing input
  contract makes it practical; a new general text editor is not a prerequisite.
- Thread selection offers all current threads or an explicit subset, with
  thread names, TIDs, a selected count and a bounded/virtualized list. Support
  deliberate selection on a large process without collecting every thread.
  An empty explicit subset is invalid; it must not become the all-threads mode.
- Model thread selection separately from defaults that can be saved to disk.
  Use session/thread identity as well as numeric TIDs, revalidate at start, and
  invalidate stale selections on target replacement/exec. A changed list must
  not silently enroll new threads or select a reused TID. No follow-children,
  automatic resume, system-wide profiling or expanded agent authority.
- Keep next settings distinct from the active capture's accepted configuration.
  Changes during a capture apply to the next one. Preserve P start/stop, T
  duration cycling and current filter/zoom behavior; propose any added shortcuts
  explicitly and obey the active-layout-only policy.
- A compact active/completed capture summary: elapsed time and deadline,
  stored samples versus the current cap, requested/selected thread counts,
  loss/discards, and the stop reason in readable language. Provide details for
  additional stop reasons and collector failures without losing the primary one.
  Use actual model evidence; do not estimate remaining runtime from sample rate
  alone or infer waiting/syscalls from missing CPU samples.
- Surface deadline, sample capacity, scope change and permission failures with
  an actionable next step supported by current behavior. Until stopped removes
  the deadline only. Keep start failures distinct from capture-stop diagnostics.
  Offline archives expose recorded status and disable live capture controls.

## Component contract and scope

Consume an immutable display snapshot and emit explicit configuration/selection
actions. Keep pointers into target/capture storage out of retained widget state.
List snapshot identity and ownership rules in the handoff, including how a queued
start is rejected/refreshed when the target changes. Production start must still
go through Session's existing validation; the GUI cannot bypass it.

No new preferences schema, write-back, automatic discovery or chosen retention
policy. Parameterize displayed limits so T15 can change them later. Represent
sampled-stack controls as future work until Codex integrates T10; the prototype
must work with today's backend. Keep user-facing language focused on decisions
and results rather than internal codec, allocator or worker details.

## Validation and handoff

1. Deterministic cases for all/subset/empty selection, list churn, reused TIDs,
   target replacement, applying next defaults, and active/offline gating.
2. Synthetic snapshots: empty, collecting, deadline, capacity, thread scope
   change, multiple stop reasons and a rejected collector open. Use actual enum
   values and summary fields; record any proposed model additions separately.
3. Private headless Sway interaction and screenshots at 640x480 and a wide
   window. Exercise a 1,024-row synthetic thread list, keyboard/pointer access,
   long names, no input starvation and a replaced capture. Bound visible work.
4. One owned live fixture run showing the chosen TID subset in the resulting
   capture, unchanged active settings after editing next settings, and cleanup.
   Keep expensive GPU/live runs coordinated with bugme and isolated caches.
5. Return the patch, precise component API, reproduction commands, screenshots,
   measured interaction costs, limitations and the concrete choices needing
   review. Back up every existing file before modification.

Record how an external local/remote agent can explain the same stop and settings
using `get_profile`; avoid a second definition of capture scope or state.
