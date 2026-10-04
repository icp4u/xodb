# T16: sample inspection and reconstructed flames

Status: adopted by the user, 2026-10-01 ("Adopt T16"). The
[reviewed patch and file hashes](research/t16-integration/manifest.json) rebase
Claude's delivery onto `5c4413a`, including the recorded-view workers.
The integrated workflow is documented in [sampled stacks](M2_SAMPLED_UNWIND.md).

## Short critical review

This makes sampled stacks useful for optimized programs that omit frame pointers:
the native UI can compare one recorded callchain with its reconstruction, then
aggregate the reconstructed paths. The main risk is overconfidence. Missing
stack bytes, missing binaries and partial walks remain in the denominator and
have explicit buckets and example samples. “Complete” means the CFI walk reached
its declared end; inline and optimized-away calls are not reconstructed. Retained
stack bytes follow ring-drain order, so budget exhaustion does **not** establish
a clean chronological cutoff or an unbiased subset of threads.

The first version is intentionally limited to completed captures. It shares the
existing archive worker, serializing save, inspection and reconstruction; a new
capture can return `ArchiveBusy` until that worker finishes or is cancelled.
One retained aggregate plus one build keeps the cache simple but switching
filters may rebuild. The 64 MiB build allowance counts Zig allocations, **not**
process RSS: retained binaries/capture data, libdw, thread stacks, the prior view
and the GUI copy cost more. This is a useful first workflow;
it is not evidence that arbitrary Unreal-sized debug information is inexpensive.

## Adopted choices

1. **B** switches recorded/reconstructed flames; **I** opens a sample inspector.
   **[ / ]** moves between samples in the selected time/thread filter; wheel or
   Up/Down scrolls frames; I/Esc closes. Selecting a reconstructed node chooses
   a sample that actually contributed to that node. Empty filters show no sample.
2. Keep recorded and derived evidence in separate inspector columns. Reconstructed
   flames show complete, partial, leaf-only, unavailable and excluded counts.
   Unknown callers form explicit boundary nodes; fragments are never joined
   across gaps. Small windows keep graph rows and all coverage counts visible.
3. Add next-capture presets: stacks off/1/4/8 KiB; retention 8/32/64 MiB.
   Defaults remain **off / 32 MiB**. Existing prefs/MCP can choose other validated
   values. Opening or changing controls does not change an existing capture.
4. Add `get_flamegraph basis:"reconstructed"` with pending progress, a separate
   result identity, coverage/reason counts and per-node `example_sample`.
   Recorded stays the default with its existing snapshot/paging contract.
   `get_profile_frame` remains recorded-only; reconstructed citations use
   `get_profile_stack`. Stale or cross-basis view IDs are rejected.
5. Adopt sampled-unwind algorithm v2: an explicitly undefined CFI return address
   terminates a complete walk; name missing-stack/budget-gap leaves only through
   verified captured binaries. Failures remain latched until explicit retry
   (B twice or MCP `retry:true`). GUI and MCP cannot cancel one another's builds
   merely by requesting different filters.

The undefined return-address rule agrees with the DWARF committee's
[outermost-frame resolution](https://dwarfstd.org/issues/040729.1.html) and its
[DWARF 5 section 6.4.4 clarification](https://lists.dwarfstd.org/pipermail/dwarf-discuss/2020-July/001938.html).
Installed `/usr/include/elfutils/libdw.h` distinguishes an undefined register
(`nops == 0`, ops points at the caller's buffer) from a same-value register
(`nops == 0`, null ops). The adapter preserves that distinction.

## Previews

[Wide reconstructed view with budget gaps](research/t16-integration/wide-budget-gaps.png)
· [Inspector](research/t16-integration/wide-inspector.png)
· [640×480 coverage](research/t16-integration/small-budget-gaps.png)
· [640×480 setup](research/t16-integration/small-setup.png)
· [15-frame inspector](research/t16-integration/small-inspector.png)
→ [scrolled](research/t16-integration/small-inspector-scrolled.png)

## Integration corrections

- Preserve current recorded snapshots, worker-owned capture lifetime, lag labels,
  explicit pagination identity and capture replacement behavior.
- Discard cancelled/superseded results even if cancellation arrives after worker
  completion; latch allocation/start failures and GUI copy failures.
- Store names once per graph node instead of accumulating duplicates per sample.
  Serialize filter identity in explicit little-endian form.
- Identify the GUI's displayed basis in MCP; reject stale reconstructed pages
  before starting work. Tool discovery advertises the optional basis.
- Make the inspector scrollable with visible frame counts; never replace an
  empty selection with sample zero. Keep completed setup controls visible at
  640×480, and avoid the recorded-only partial counter in reconstructed details.
- Keep archive bytes, target-memory access rules, agent scopes and capture limits
  unchanged. No system configuration changes were needed for these tests.

## Validation

- **169/169 ReleaseSafe tests; 24/24 build steps**, including added regressions for
  cancellation after completion, GUI/MCP ownership, label-memory scaling and an
  empty inspector selection. [Log](research/t16-integration/test.log).
- Four owned GCC/Clang `-O2` fixtures with and without frame pointers: aggregate
  counts, reason buckets and cited paths matched individual sample walks;
  time/thread partitions, cancellation/retry, and archived identity/count parity
  passed. Missing assets remained explicit. About 1,000 samples per capture;
  builds 54–57 ms, budgeted peak 50–53 KB, maximum pending MCP ping 1.75 ms.
  [Results](research/t16-integration/live.log).
- Private headless Sway at 640×480 and 1600×1000: stack presets, visible pending
  state, basis switching, sample navigation and clean shutdown passed. Roughly
  5,000 samples built in 273–277 ms; no slow-loop diagnostics were emitted.
  These are fixture measurements, not a frame-rate or large-game guarantee.
  [Results](research/t16-integration/gui-results.json).
- Three owned 16,384-sample captures reached the existing capacity limit. Whole
  views built in 878/602/176 ms for 4 KiB/64 MiB, 8 KiB/64 MiB and 8 KiB/16 MiB
  settings; counted peaks 116,110/117,284/120,000 bytes. Pending MCP pings stayed
  at or below 1.75 ms. The last case retained all 16,384 samples in its denominator:
  2,639 complete and 13,745 explicitly leaf-only. Process RSS after reconstruction
  was about 35–83 MiB; this small-binary fixture does not bound large-game RSS.
  [Measurements](research/t16-integration/scale.log).
- Final private GUI with a 4 MiB retention budget: 661 retained stacks and
  4,313/4,315 leaf-only gaps out of 4,974/4,976 samples; GUI/MCP coverage agrees.
  Reconstructed views built in 47 ms. [Results](research/t16-integration/gui-gaps-results.json).
- Existing live recorded-worker regression passed: snapshot paging stayed stable
  while collection advanced; stale views, frame queries and capture replacement
  retained their current behavior. [Log](research/t16-integration/recorded-regression.log).
- MCP tool discovery advertises the basis; missing/stale/cross-basis citations and
  invalid basis values are rejected without starting a job.
  [Checks](research/t16-integration/api-guards.log).

A final 640×480 run selected cited sample 1 with 15 frames, verified frame
scrolling, switched back to recorded and exited cleanly.
[Evidence](research/t16-integration/gui-scroll-results.json).

## Production adoption

The user approved T16 with “Adopt T16”. Applied the reviewed patch with exact
file-hash parity, rebuilt/installed ReleaseSafe, and verified the main tree with
169/169 tests plus the four live/archive cases and private 640×480 inspector
scrolling. [Production verification](research/t16-adoption/README.md).

## Reproduction

The [review bundle](research/t16-integration/README.md) contains the patch,
harness copies, hashes, logs and private-display previews. Claude's original
handoff remains unchanged under `docs/research/derived-stack-views/` and
`tests/repros/derived-stack-views/`.

## External LLM opportunity

An agent can compare recorded and reconstructed counts, cite a contributing
sample and its analysis ID, and explain missing assets or retention gaps from
explicit reason buckets. It should report coverage before drawing conclusions
from flame widths. Local/remote models need no new execution authority for these
queries; reconstructed source/disassembly and live reconstruction remain future
work.
