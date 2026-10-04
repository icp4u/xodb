# T16: reconstructed-stack inspection and flame views

Status: integrated by Codex following user approval (2026-10-01, "Adopt T16").
Fable/Claude's original handoff is preserved in
`docs/research/derived-stack-views.md`. The [adopted design and validation](../M2_DERIVED_VIEW_PROPOSAL.md)
cover the rebase and integration fixes; [usage](../M2_SAMPLED_UNWIND.md) explains
native inspection and the MCP reconstructed basis.

## Goal and ownership

Make T10 useful in the native UI: inspect one sample's recorded and reconstructed
stacks, then prototype a completed-capture reconstructed flame view. Own only:

- `tests/repros/derived-stack-views/`
- `docs/research/derived-stack-views.md`
- `docs/research/derived-stack-views/`

Read `docs/research/capture-scaling.md` (T15: large flame rebuilds, not just
storage, become the limiting cost), `docs/M2_SAMPLED_UNWIND.md`, `docs/M2_ARCHIVE_FORMAT.md`,
`src/profile/unwind.zig`, `src/profile/sample_state.zig`,
`src/profile/archive_job.zig`, `src/model/session.zig`, `src/mcp/sampled_stack.zig`,
`src/ui/capture_panel.zig`, `src/ui/flame.zig` and `src/ui/timeline.zig`.
Record the current commit plus hashes: Codex's T10/T14 integration may still be
uncommitted when you begin. Work in an isolated copy within your owned paths;
return shared changes as a patch. Do not edit production or T10/T15 artifacts.

## Integration update (2026-10-01)

T15 compact storage is integrated: [accessor notes and evidence](../M2_CAPTURE_SCALING.md).
Rebase shared-file patches onto `Capture.samples.len()/core()/get()`; raw T10
state ownership remains separate. `get()` returns a temporary full sample;
`core()` avoids callchain expansion for time/TID/coverage queries.

## Required slice

1. A sample inspector identifies capture/revision/sample ordinal, TID/time,
   register/stack availability, raw PC versus lookup PC, method and terminal
   reason. Recorded kernel callchain and derived callers remain distinguishable.
   Do not invent source context when no matching assets are loaded.
2. A deliberate recorded/reconstructed view choice for completed captures only.
   Selection keeps the existing time/thread filters. Missing stacks, failed or
   partial reconstruction and filtered samples remain explicit in the counts;
   the view must not silently discard unavailable samples or advertise full
   coverage. State its denominator and the meaning of each partial bucket.
3. Reconstruct on a cancellable worker; the UI consumes immutable published
   results. Reuse T10's saved-byte memory reader and timestamped mapping lookup.
   Cache by immutable input/asset/algorithm/filter identity, not only capture ID.
   Reuse verified asset fingerprints within a batch; do not rehash large ELF
   files for every sample. Bound derived-result storage as well as graph nodes;
   a streaming aggregate need not retain every expanded frame array.
   Handle target/capture replacement, changing filters, cancellation and failed
   jobs without stale results, automatic retries or UI-thread DWARF work.
4. Add proposed opt-in stack-size and total-budget controls to T14's next-capture
   panel. Preserve zero/off and 32 MiB defaults, current validation and active
   versus next separation. Propose presets rather than changing limits. Include
   stack coverage in completed-capture details and keep 640x480 controls usable.
5. Offer a bounded machine view of the same result; identify necessary MCP
   additions as a proposal. Preserve get_flamegraph's existing recorded semantics
   until the caller explicitly selects another basis. No target memory reads,
   automatic resume, archive rewriting or new agent authority.

## Validation and handoff

- Deterministic cases: complete, short stack, retention gap, no registers, missing
  asset/CFI, signal boundary, mapping ambiguity, stale identity and cancellation.
- Compare aggregate counts to individual T10 results, including recursion,
  repeated PCs, time/thread filters, and a zero-byte retention budget. Do not
  double-count leaf PCs or join unrelated fragments through an unknown gap.
- One owned optimized C/C++ fixture; a saved capture without assets and again
  with verified assets. Record graph/count parity and changed analysis identity.
- Private headless Sway at 640x480 and a wide window: responsive input during
  reconstruction, visible pending/error states, selection preservation, and
  current/next settings. Measure worker time, peak memory and UI draw/input cost.
- Deliver patch, reproduction commands, screenshots, measured limits and a
  **one- or two-paragraph critical review before listing choices for approval**.
  The user reviews new visual/interaction and analysis-policy choices. No binding
  format or retention change is authorized by this packet.

Critical risk: a polished reconstructed graph can hide coverage bias. Prefer
visible missing/partial evidence and stable sample references over a falsely
complete call tree. Preserve every raw input so results remain auditable.
Record how a local/remote agent could explain differences with cited samples.
