# T15: longer captures with measured resource budgets

Status: bounded compact storage integrated by Codex (2026-10-01), with corrections
and T10/T14 adaptation. [Results](../M2_CAPTURE_SCALING.md). Larger limits, rolling
retention and spooling remain proposals.

## Goal and ownership

Find a practical path from the current short bounded capture to useful longer
game/server sessions, without unbounded memory or unresponsive interaction.
Produce measurements and one bounded storage prototype. Retention behavior and
new defaults remain proposals for user review.

Own only:

- `tests/repros/capture-scaling/`
- `docs/research/capture-scaling.md`
- `docs/research/capture-scaling/`

Read `docs/PROFILING.md`, `docs/PREFERENCES.md`, `docs/M2_TIMELINE.md`,
`docs/M2_ARCHIVE_PROPOSAL.md`, `docs/M2_ARCHIVE_FORMAT.md`, T10's report,
`src/profile/records.zig`, `capture.zig`, `flame.zig`, `timeline.zig`,
`archive.zig`, `archive_job.zig`, `archive_budget.zig`, and T04 cost research.
Use fresh scratch copies inside your owned paths. Keep production, T10/T11
handoffs, shared build files and documentation unchanged. Supply a tested patch
and a recorded base commit for any proposed shared-file changes.

## Starting evidence

The default deadline is now 60 seconds, and zero disables it. The current sample
cap is still 16,384. A directed two-busy-thread fixture at 1,000 Hz reached that
cap in about 8.2 seconds; see the 2026-10-01 preferences entry in the journal.
That is one measurement, not a prediction for every process. Each retained
sample currently includes bounded callchain storage; additional T10 register and
stack bytes will require separate ownership and budgets.

## Work

1. Account for current memory by category: allocated sample capacity, callchains,
   perf rings, scheduling, mappings and retained images, symbols, timeline/flame
   views, temporary rebuild copies and archive input/output. Measure peaks across
   live collection, filtering, finalization, save and reopen. Identify which
   bounds are independent, shared or duplicated; include allocation slack.
2. Benchmark the current representation and a compact alternative using generated
   repeated/deep and diverse stacks. Consider interning/chunking with stable
   ordinals; assess adversarial diversity as well as favorable repeated frames.
   Preserve IP/time/TID, raw kernel evidence, mapping history and explicit loss.
   Do not deduplicate away recursion, zero/unknown distinctions or provenance.
3. Compare bounded in-memory retention, a rolling window, and asynchronous disk
   spooling. State which samples/metadata each policy retains or loses, effects
   on timeline/filter semantics, disk exhaustion, stop behavior, archive identity,
   cancellation and complexity. Prototype one measured next step, not all three.
   Do not silently adopt eviction, aggregation-only history, automatic disk
   writes or new default limits.
4. Measure append/drain work, range/TID filtering, graph/timeline rebuilds, UI or
   MCP latency, encode/decode time and peak RSS/allocated bytes. Use 16K, 64K and
   256K logical samples where the budget permits; try 1M only if bounded. Use
   controlled synthetic timestamps so there is no need to run for hours. Cap
   each experiment's working set (initially 256 MiB); record budget refusals as
   results instead of raising limits or saturating the workstation.
5. Include a T10-shaped side-data workload with explicit per-sample and total
   byte caps. Use synthetic records or an isolated copy of the delivered
   prototype; do not wait for or edit Codex's integration. Distinguish optional
   side-data exhaustion from losing the original sample and report the policy.
6. Check format and citation consequences: archive input/decoded-memory bounds,
   feature negotiation, stable raw sample ordinals, old-file read/copy, derived
   view identity, lost/evicted prefixes and mappings needed by retained samples.
   Do not just raise the sample constant while leaving the reader or worker
   bounded to the old representation. Honor the approved no-fsync policy.

## Correctness and measurement gates

- Reference comparison of sample counts/order, recursive paths, flame totals,
  time/TID filters and explicit exclusions; include equal timestamps, mapping
  changes, scheduling unknown intervals and high-cardinality stacks.
- Allocation-failure/budget refusal, cancellation and truncated archive tests
  for whichever path is prototyped. Complete cleanup of owned resources.
- Repeated ReleaseSafe measurements with environment and commands, separate
  correctness checks from benchmarks, and report variation. A synthetic scale
  result is not proof of overhead on a production game or high-performance server.
- A small optional owned T04 live run can validate the bottleneck identified by
  the synthetic work. No user process, permission change or package installation.

Return the accounting table, benchmark runner/data, one bounded prototype and
patch, an ordered integration plan, proposed resource knobs/defaults, and tradeoffs
that need review. Follow backups, repo-local caches, coordination and private
GUI rules. Record how external agents should describe incomplete windows, sample
loss and budget exhaustion without claiming an entire session was observed.
