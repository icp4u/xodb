# M2: timeline linked to CPU flames

Status: T08/T09 integrated and tested, 2026-10-01. Grok supplied the optional
perf switch collector; Fable/Claude (Opus 5.5) supplied the timeline component
and layout. The user approved Claude’s layout: flames above the timeline while
profile view is open; **F** restores the source/threads/stack/events workspace.
Scheduling remains opt-in. M2 as a whole is still in progress.

## Try it

See [the profiling demo](PROFILING.md#try-the-demo). Open **F**, optionally click
**Next sched: on**, press **P** to start and **Space** to run. **P** stops capture
without pausing the target. Drag a timeline range and click a thread label/lane
to filter flames and source/assembly inspection. **Fit range** zooms the lanes;
the overview wheel adjusts zoom; **Reset** clears range and thread selection.
The scheduling button controls subsequent GUI captures. MCP can independently
request `start_profile(context_switch=true)`.

![Integrated range and thread selection](images/m2-timeline.png)

CPU bars count samples. Running/off-CPU lanes count elapsed nanoseconds from
paired switch events. Empty CPU regions alone cannot establish a wait, and a
busy thread can have an unknown final scheduling interval if it never switches
out before capture stops. Debugger stops consume wall time and have their own
observed per-thread overlays.

## Integrated contract and evidence rules

- `src/profile/timeline.zig`: shared half-open relative-time `Filter`, pointer-free
  `Selection`, exact integer CPU `Histogram`, conservative `Transition`/`Span`
  reconstruction. Clock: `CLOCK_MONOTONIC`; times are since capture start.
- `src/profile/scheduling.zig`: original-delivery-order history per opening TID,
  262,144 transitions total, 65,536 per lane. Transition allocations are bounded
  by 9 MiB on this x86-64 build, separate from rings, CPU records and UI caches.
- The collector still uses one task-scoped perf event per explicitly selected
  thread. No inheritance, CPU-wide capture, automatic enrollment, kernel sample
  collection, new dependency or system permission change was added.
- Validate event kind, timestamp and task identity before accepting a switch.
  Completed adjacent pairs become running/off CPU. Missing endpoints remain
  unknown. Invalid identity and unlocalized loss invalidate attribution;
  duplicate/reordered transitions invalidate their lane. Throttling, unknown
  records and incomplete decoding/draining also leave scheduling unknown.
- A history cap stops capture with `scheduling_limit`, preserves closed pairs
  before its cutoff, and exposes discarded suffixes as unknown. Invalid or
  contradictory records report `scheduling_error`. Final-drain scheduling errors
  preserve an earlier mapping/scope/collector failure reason. Stderr includes
  exceptional stop details and scheduling counts/storage.
- Preemption is a switch-out fact, not evidence of a lock, I/O cause, wakeup
  source, blocking stack or runnable duration. See the
  [perf ABI](https://man7.org/linux/man-pages/man2/perf_event_open.2.html) and
  [Grok’s boundary/rate findings](research/scheduling.md).
- `Capture.extentNs()` is revision-stable, includes final-drain evidence, and
  advances during a live capture at most four times per second without new
  records. Queries do not change it by consulting the clock.
- `TimelineSource` adapts CPU times, shared scheduling reconstruction and
  per-thread debugger-stop markers to Claude’s immutable display DTO. GUI
  preparation uses the extent once per build; it does not scan all CPU samples
  again for every lane. At most 4,096 stop overlays are retained, with an explicit
  omitted-overlay notice. Original bounded control markers remain available
  through MCP; unavailable/lost control history is not reconstructed as fact.
- `TimelineView`: up to 1,024 lanes, 64 visible, 4,096 columns, 1,024 overview bins,
  4,096 lane quads. Drag motion previews; release commits `FlameView.setFilter`.
  Replacement capture IDs clear selection. Full-range selection follows growth;
  a selected upper bound stays fixed. Clock-only revisions reuse flame trees.
- `get_profile_timeline`: CPU bins, paged counts, original control markers and
  scheduling status. `get_profile_schedule`: one TID’s intervals, pages of at
  most 128 spans, and totals for the whole filtered range. Both share the flame
  filter, capture/revision guards and observe scope.
- `get_profile.displayed_view`: last drawn GUI capture/revision/filter/visibility,
  plus graph `view_id` and snapshot `sample_count`. Flame pages use that retained
  snapshot during live collection. Timeline/scheduling still use the current
  capture revision; stop capture for stable comparisons across tools. Clock-only
  revisions do not rebuild the graph. See [worker semantics](M2_RECORDED_VIEW_PROPOSAL.md).

## Validation

All live tests used owned processes. All automated graphics/input ran on a
private headless Sway/Vulkan display. No user targets or system settings changed.
The installed binary is ReleaseSafe. Backups and run artifacts are in the repo.

- `./scripts/build test -Doptimize=ReleaseSafe --summary all`: **86/86 passed**
  on the host. `.work/scheduling-integration-host-unit.log`. Sandbox ptrace
  attempts failed with permission errors; the host run is the relevant result.
  Tests cover interval conservation/unknowns, maximum storage, invalid identity,
  earlier-error preservation, per-thread overlays, selection and capture reset.
- Production decoder: **10/10 passed**, `python3 tests/scheduling-decode.py`,
  `.work/scheduling-decode-20261001T002045078160/`. Uses Grok’s tests against
  production `records.zig`, including wrapped/truncated switch records,
  CPU-wide field distinctions, sample ID layout and output-capacity retry.
- `python3 tests/m2-scheduling.py`,
  `.work/m2-scheduling-20261001T003105539322/`: sleep had zero CPU samples and
  653 ms of paired off-CPU time; two busy threads had 258 CPU samples and 618
  switches; kernel-heavy had one user sample and nine switches. Disabled sleep
  retained no switches and its whole scheduling interval stayed unknown.
  Pagination, adjacent-range conservation, stale guards, exact partitioning,
  target registers/generation, exit retention and descriptor cleanup passed.
- `python3 tests/m2-timeline-gui.py`,
  `.work/timeline-20261001T003104873298/live/`: real two-thread capture, live drag,
  second-thread selection, MCP/flame count agreement, scheduling on/off through
  the GUI, fit/zoom/reset, source-view restoration, capture replacement and narrow
  resize passed. Target registers/generation were unchanged by browsing. No GUI
  phase reached the 250 ms slow-phase reporting threshold; clean EOF cleanup.
- Existing `tests/m2-timeline.py` and `tests/m2-profile.py` passed:
  `.work/m2-timeline-20261001T003248928833/` and
  `.work/m2-profile-20261001T003252036186/`. Includes zero-sample sleep/kernel,
  mapping/scope/duration/exit behavior, 66-thread pagination, 640-thread default
  CPU capture and cleanup. Opt-in scheduling preserves default CPU behavior.
- Existing `python3 scripts/gui-smoke.py --profile` passed on the RTX 4090:
  `.work/gui-20261001T003516763749/`, 328 frames, flame/source inspection,
  shared controls, resize and clean compositor-close shutdown.
- Maximum-history adapter (1,024 lanes, 262,144 switches, 16,384 CPU samples,
  1,024 control markers): **10.1 ms** to prepare. It retained 4,096 overlays and
  explicitly counted the remainder. Claude’s pathological 4K display test:
  **2.30 ms** rebuild, **0.10 ms** cached draw, 2,890 quads. These are synthetic
  ReleaseSafe measurements on this workstation, not worst-case latency promises.

The initial live test assumed every spinning lane would accumulate 100 ms of
closed running intervals. One lane instead had 86 ms paired and a 567 ms open
running tail, with CPU samples and 1,300 ms aggregate user CPU across the two
threads. The collector correctly supplied no synthetic final switch-out. The
test now checks CPU activity and explicitly unknown final intervals rather than
assuming periodic switches. No reconstruction rule was weakened to fill the tail.

## T04 cost comparison

**Follow-up:** the [gated server comparison](research/server-cost.md) now removes
request-clock startup skew and adds a debugger-only control. Queue and socket
runs completed identical request counts; p99 was 310–326 µs across the measured
modes. The original comparison below remains a record of the earlier setup and
its known confounding pause.

`python3 tests/m2-workload-cost.py` built unmodified T04 sources with debug/frame
pointers into `.work/m2-workload-cost-20261001T003316083550/`. Two repetitions per
mode, serially, 99 Hz. Frame loop: 120 paced frames, four workers and one known
lock stall at frame 60. Server: two seconds, four workers/four clients, 4,000
requests/s, work 100,000, hold 50,000, one shard. These are short workstation
measurements, not representative game/server acceptance or pure collector
microbenchmarks.

| Workload / mode | Target CPU ms | xodb CPU ms during capture | Latency / work p50 µs | p99 µs | Switch events/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Frame / native | 1,888–1,891 | — | 5,932–5,937 | 6,452–6,574 | — |
| Frame / CPU only | 1,889–1,894 | 10 | 5,937–5,959 | 6,396–6,430 | 0 |
| Frame / scheduling | 1,896–1,901 | 10–20 | 5,958–5,996 | 6,444–6,629 | 1,149–1,204 |
| Server / native | 1,561–1,565 | — | 197 | 318–321 | — |
| Server / CPU only | 1,575–1,576 | 10 | 199 | 4,778–5,277 | 0 |
| Server / scheduling | 1,582–1,584 | 50 | 200 | 1,617–3,199 | 18,231–18,252 |

No perf loss, invalid/discarded scheduling events or request drops occurred.
All captures ended with the target. Frame captures retained 185–187 CPU samples;
server captures retained 152. Scheduling used 50,176 bytes of transition capacity
for the frame loop and 787,456 bytes for the server. Server throughput was 3,970/s
native, 3,946–3,947/s CPU-only and 3,949/s with scheduling.

Frame quantiles omit frame zero, which contains the setup breakpoint; the known
stall’s maximum stayed 31.1–31.7 ms. Server timing **includes** startup breakpoint
and perf setup after clients started their clocks. The resulting request backlog
inflates tail latency in both debugger modes. These runs cannot isolate the
collector’s effect on server p99; do not interpret the lower scheduling p99 as an
improvement. xodb CPU is sampled from procfs at 10 ms granularity, excludes early
launch/symbol loading and GUI rendering, and includes MCP polling. Small deltas
across two unisolated runs are not a general overhead estimate. Grok’s earlier
fixed-duration enabled/disabled ratio likewise is not an overhead measurement.

## Remaining M2 work and LLM opportunities

Application markers/uprobes, syscall timing, blocking-stack or wakeup evidence
and allocation events can explain a selected interval. CPU samples and switch
pairs alone cannot identify the wait cause. Function recovery, analysis IR,
Rust/Zig values and representative large game/server validation remain open.
The present mapping history still misses unreported munmap/mremap and in-place
code changes. Durable capture files, deeper stacks, JIT metadata and following
new threads/processes are follow-ups, not completed features.

External local/remote LLMs can read the human’s pinned range and TID, compare
flames with scheduling totals, check unknown/loss counters and debugger stops,
then propose a targeted follow-up capture. They must cite measured durations
separately from hypotheses about lock/I/O/GPU waits. The T04 fixtures provide
known-cause cases to evaluate those explanations and the cost of new evidence.


## Application interval integration (2026-10-01)

Imported frame/request/custom intervals now appear as blue overlays, with caller
source and explicit imported provenance. Control-scoped `add_profile_intervals`
accepts atomic batches of 128, up to 4,096 records per completed capture;
observe-scoped `get_profile_intervals` pages overlapping records with the same
range/TID selection used by flames. Import advances capture revision and the
existing agent-action audit generation, while leaving target execution/registers
and collected CPU/scheduling evidence intact. See
[the workflow and CSV converter](PROFILING.md#imported-frame-and-request-timings).

Full ReleaseSafe suite **90/90 passed**, `.work/overnight-interval-unit.log`.
Real frame CSV integration: `.work/m2-intervals-20261001T012316256566/`, 49 complete
intervals, injected stall 31.54 ms. Source, clock and cause remain caller claims;
this does not implement live uprobes or automatically prove a blocking cause.

Private GUI overlay/hover/selection test passed:
`.work/timeline-20261001T012452740532/intervals/`. Register values and execution
state survived import/browsing; action-audit generation advanced only on import.
