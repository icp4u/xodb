# T09: native timeline component and interaction prototype

Status: delivered and integrated by Codex, 2026-10-01.
See [integration and validation](../M2_TIMELINE.md). The packet below is the original handoff.

## Goal and owned paths

Build the bounded timeline view for `docs/M2_TIMELINE.md`. The user should be
able to select a time range/thread and inspect the corresponding CPU flames.
Work independently from T08 using synthetic evidence until integration.

Own only:

- `src/ui/timeline.zig` (new standalone component)
- `tests/repros/timeline/`
- `docs/research/timeline.md`
- `docs/research/timeline/`

Read existing `src/ui/flame.zig`, `workspace.zig`, `style.zig`, the renderer and
input APIs, and `docs/PROFILING.md`. Put shared workspace/flame/main/build changes
in `docs/research/timeline/integration.patch`, tested in a fresh scratch copy.
Do not edit the actual shared files, collector, model, MCP or another task's paths.
Keep the production build working while the independent component is developed.

## Component boundary

- Consume immutable, caller-owned display data: capture ID/revision, extent in
  nanoseconds since capture start, thread identities/labels, CPU sample bins,
  and intervals with running/off-CPU/unknown evidence. Propose a small explicit
  input contract in your research doc; keep kernel records and Session ownership
  out of the component.
- Return a time/thread selection to the coordinator. Use half-open
  `[from_ns,to_ns)` ranges and an optional TID, matching existing profile filters.
  Codex owns applying the selection to the model, flames and MCP.
- Preserve a user's selection as a capture grows. A replacement capture clears
  stale selection. Define how revision updates and shorter extents are clamped;
  do not retain pointers into an old capture arena.

## Interaction and presentation

- Show a compact CPU sample-density overview and visible thread lanes. Density
  units are samples; scheduling intervals are elapsed time. Keep those distinct.
- Mouse drag selects a range; selecting a lane filters a thread; an obvious
  reset returns to the whole capture. Use existing colors/type/control conventions
  and propose any new shortcut behavior for review. The user approved only the
  active-layout key policy; do not add physical/other-layout fallbacks.
- Distinguish unknown/unobserved regions, loss and partial interval boundaries.
  A missing CPU sample is not evidence of waiting. Label off-CPU intervals
  without inventing wait stacks, lock identities, wakers or syscall causes.
- Support narrow windows, empty captures, zero-width pointer drags, edge drags,
  clipped intervals and many threads. Virtualize lanes and bound visible geometry;
  the existing debugger supports up to 1,024 selected threads.
- Keep input responsive. Avoid rebuilding all graph data per motion event.
  Convert timestamp deltas to screen coordinates after subtracting the origin,
  rather than converting absolute nanosecond timestamps directly to float.

## Validation and handoff

Provide deterministic selection/clipping checks where they protect real edge
cases, plus screenshots and a private-display interaction run of the prototype.
Exercise a capture with short bursts, long waits, missing boundaries, loss,
equal timestamps, live growth and a replaced capture. Measure layout/draw work
at the proposed maximum visible budget; report numbers and assumptions.

All automated GUI tests use private headless Sway and owned targets. Clear the
inherited display/session variables; coordinate GPU work.
Back up every existing file before editing, keep caches/artifacts in the repo,
and use a scratch copy that includes untracked source files. No system/package
changes. Do not undo the current Wayland read-reservation fix.

Return the component, proposed shared-file patch, input/output contract, exact
reproduction commands, screenshots, measurements and unresolved interaction
choices. Record how external local/remote LLMs could select/cite an interval
through the shared model; no separate agent-only UI or embedded model is needed.
