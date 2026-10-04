# Recorded flame views on a worker — proposal

Status: adopted by the user and integrated (2026-10-01). Live GUI/MCP dispatch
uses the snapshot worker; offline archive view behavior is preserved.

2026-10-01. Applies to the existing kernel-callchain graph, alongside T16's
separate completed-capture DWARF reconstruction. No count/default/archive change.

## Critical review

T15 made sample storage much smaller, but graph construction still takes tens of
milliseconds at 16K samples and seconds at experimental larger counts. Moving
that work off the event loop should keep input, MCP and collector draining
responsive. A worker must own a stable snapshot of samples/mapping history and
its symbol cache; it cannot traverse mutable collector arrays or share lazy
libdw state with the GUI.

The cost is one bounded input copy, worker/output memory and a graph that can lag
live collection. The UI must say which snapshot is displayed, and machine callers
need a stable result to poll/page while capture revision advances. Cancellation
must not join a running worker on the event loop, and an error must not trigger
an endless automatic retry. Keep current capture limits while measuring copy
latency and memory. Source/disassembly inspection is separate work; this change
only moves graph construction.

## Adopted integration

- One recorded-view worker per session. Copy compact samples, observed mappings,
  thread metadata and required annotation data at dispatch; use private mutable
  caches. Retained immutable ELF bytes may be borrowed while the originating
  capture is pinned. Capture replacement cancels the job and defers old-capture
  reclamation until the worker finishes; it does not stop or resume the target.
- Bound snapshot, worker and graph allocations together (initially 64 MiB for one
  job). This is not an RSS cap: the source capture and its pinned ELF images,
  thread stack, prior published result and GUI copy are additional memory. Keep
  at most one published result plus one in-progress job. Failure is
  explicit. No live process-memory reads, new asset discovery, or shared libdw
  handles during recorded graph construction.
- Copy labels into the published graph so that later worker cleanup cannot
  invalidate GUI/MCP strings. Publish only for the matching capture and requested
  filter. Cancel obsolete filters without blocking; discard stale completions.
- GUI shows a building/error state and identifies the displayed sample snapshot
  when it trails collection. Preserve zoom/selection by ancestry when valid.
  Current four-per-second refresh throttling remains the upper bound.
- MCP recorded-graph requests may return a pending result with job identity;
  polling the same capture/revision/filter remains valid while that requested
  snapshot is pending or retained, even if collection has advanced. A ready
  result reports its snapshot revision/sample count, current revision and a
  view identity. Pagination/frame queries bind to that identity. An evicted view
  or replaced capture is explicitly stale. Requests never silently substitute
  another filter or newer snapshot.
- Existing offline graph/asset semantics and archive bytes remain unchanged.
  T16's reconstructed basis remains an explicit, separately reviewed choice.

## Validation gate

Compare worker and synchronous recorded graphs, including recursion, time/TID
filters, equal timestamps and mapping changes. Exercise mutation after dispatch,
allocation failure, cancellation, filter/capture replacement, stale pagination,
worker shutdown and label lifetime. Measure snapshot time, worker time, peak
allocation and MCP/UI responsiveness using owned fixtures and private Sway.

## Foundation results (2026-10-01)

Implemented direct compact-store cloning, private mapping/thread/annotation
snapshots, private ELF descriptors borrowing immutable captured bytes, worker
cancellation, and graphs whose label text survives worker/capture destruction.
The input is only sufficient for recorded graph construction: it deliberately
omits raw saved stacks, scheduling, intervals and source annotations. It must not
be used as a complete capture or for export/unwinding. Snapshot creation remains
on the event loop; graph construction and input cleanup run on the worker.

**154/154 ReleaseSafe tests, 24/24 build steps passed.** Added nine tests covering
exact recursive/filtered/equal-time/mapping graph parity, original mutation during
work, result/clone lifetime after capture retirement, cancellation and abandoned
jobs, memory refusal, offline annotation ownership, and injected allocation
failures through snapshot/graph/store growth. Budget accounting returns to zero
after cancellation/refusal and injected failures.

Single-run measurements at 16,384 samples, 1,024 threads, 16,384 opening mappings
with 1,023-byte paths and 4,096 changes; decimal MB. The wide case gives every
64-item chain a distinct extra raw value, exercising the largest representation.

| Chains | Snapshot ms | Worker ms | Input MB | Peak MB |
| --- | ---: | ---: | ---: | ---: |
| Repeated deep | 9.49 | 49.65 | 28.80 | 37.78 |
| Unique wide | 19.55 | 54.31 | 44.88 | 53.86 |

These pathological copies can exceed a 16 ms frame, so this is a bounded initial
foundation, not evidence for larger capture defaults or a 60 Hz responsiveness
guarantee. The following integration measurements cover UI/MCP queries, stable polling,
filter replacement, session retirement and failure retry. CLI shutdown export
and the internal synchronous graph API remain available; live GUI/MCP graph
builds use the worker.
Graph clones now independently own their label strings.

Logs: `.work/recorded-view-20261001T123205928116/test-2.log`. The foundation preceded the live integration and private-GUI run below.

T16's delivered completed-capture reconstruction uses the archive job and a
separate cache. Its patch needs review alongside this work: neither worker may
borrow mutable lazy debug handles, free the other's capture, or return a node
identity from the wrong graph basis. Its proposed UI/MCP/analysis changes are not
adopted by this recorded-view proposal.

## Live integration and machine contract

- GUI consumes a cloned published graph. Its status line identifies the snapshot
  revision, displayed/collected sample counts, current revision and building/error
  state. Clock-only revisions preserve the graph's original identity. Ancestry
  selection survives valid rebuilds; capture/filter/mapping-trust changes reset it.
- The event loop polls completion; it never joins a running recorded-view job.
  Capture replacement transfers old-capture ownership to the cancelled job until
  completion. Shutdown cancels and joins before freeing borrowed ELF bytes.
- **Initial live `get_flamegraph`:** require `capture_id`; omit `revision` to
  snapshot current data without racing collection. An explicitly supplied
  revision remains strict. Offline queries still require their capture revision.
- **Pending response:** `pending: true`, `job_id`, `capture_id`, `revision`,
  `current_revision`, `view_id`, `snapshot_samples`. Poll with that exact
  revision/view identity and the same filters. Never refresh the revision while
  polling an accepted job. Failure remains queryable at the accepted identity.
- **Ready response:** `pending: false`, snapshot/current revisions, raw snapshot
  count and worker timing/allocation metrics alongside existing graph counts and
  rows. Raw `snapshot_samples` includes samples omitted by graph validity/filter
  rules; `samples` remains the graph's accepted sample denominator.
- **Pages and frames:** `view_id` is required with `start > 0` and for
  `get_profile_frame`. Missing IDs fail `ProfileViewRequired`; wrong-filter or
  evicted IDs fail `StaleProfileView`; replaced captures fail `StaleCapture`.
  A session retains one published graph. GUI or MCP builds can replace it; an
  evicted client starts a fresh view rather than combining pages.
- Explicit requests for another filter cancel obsolete work and return
  `ProfileViewBusy` until it finishes; no new snapshot was accepted in that case.
  Retry an initial request after the busy result. The GUI waits for an MCP job
  instead of repeatedly cancelling it. GUI builds are limited to four per second.
- Worker failures are latched, printed once to stderr, and require a filter/capture
  change or `retry: true` with a current snapshot request. GUI clone failures also
  latch until filter/capture change. There is no automatic failure retry loop.
- MCP `export_profile` reuses the completed snapshot graph. If it needs to build
  one, it returns `ProfileViewPending`; retry the same export after readiness.
  Publication/audit happen only after the view is ready. File serialization and
  source/disassembly lookups remain synchronous and are outside this change.
- `get_profile` exposes `recorded_view_job` and the displayed view's identity and
  raw sample count. Timeline/scheduling queries still require the current capture
  revision; stop collection to compare all evidence against a fixed input.

The initial-request omission was necessary: the live stress test showed that
separate `get_profile` / exact-revision requests could lose every race until the
capture hit capacity. The server now binds current data only when the caller
explicitly omits the first revision. It never substitutes a newer revision for
an accepted or explicitly versioned query.

### Integration validation

**157/157 ReleaseSafe tests; 24/24 build steps.** Additional lifecycle/RPC tests
cover initial binding, stable pending/ready pages across sample growth, frame
identity, eviction, filter cancellation, source retirement and latched failure
queries/retry after revisions advance. Existing async GUI-model tests retain
selection and avoid rebuilding on clock-only updates.

Owned live regression `tests/m2-recorded-views.py`: 7,051 samples at dispatch,
2.77 ms request latency, 0.409 ms input copy, 10.47 ms worker build, 812,475 bytes
peak allocation, and at most 1.87 ms MCP ping during work. Collection advanced to
7,366 samples while the original snapshot stayed pageable and source-inspectable.
Evicted/replaced identities were rejected. These are single-run fixture results,
not a universal latency guarantee; the foundation's pathological mapping-path
copy still costs roughly 20 ms on this workstation.

Also passed: live profiling including 640 threads; mapping changes on main and
worker threads and subset attribution; full/filtered/empty exports; archive
save/reopen/asset/source/format isolation and no-sync checks; private headless
Sway profile controls, live snapshot labels, selection/zoom/source and resize.
The archive regression's obsolete 64 MiB oversized input was corrected to exceed
the existing 128 MiB limit; the production limit did not change.

Logs: `.work/recorded-integration-20261001T130414236211/`; live snapshot transcript
`.work/m2-recorded-20261001T132138589098/`; private GUI screenshots
`.work/gui-20261001T131454942445/`. Tests retain raw RPC transcripts and timings.
