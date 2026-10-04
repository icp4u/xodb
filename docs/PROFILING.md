# CPU captures, flame graphs and timeline

This M2 increment integrates Grok's T06 collector with the shared session,
native Vulkan workspace, ELF/libdw navigation, and MCP. It samples **user CPU
execution**. Bar widths count samples; they do not measure wall time or time
spent waiting for a lock, queue, I/O, or the GPU. The linked timeline adds
optional per-thread scheduling evidence from T08/T09.

[System setup and tracing permissions](../SETUP.md) cover ordinary CPU sampling,
optional syscall-tracing prerequisites, security implications and rollback.

## Try the demo

From your graphical session:

```sh
cd ~/Work/xodb
./scripts/build
./zig-out/bin/xodb --break profile_ready --source tests/fixtures/profile.c \
  -- ./zig-out/bin/xodb-profile-fixture
```

1. **Space** reaches `profile_ready`, after the program's initial mappings exist.
2. **P** starts a capture and opens the flame view. The target stays stopped.
3. **Space** runs it. Bars update while samples arrive.
4. After a few seconds, **P** stops collection. The target keeps running.
   **Space** pauses execution when you want to browse its live source/assembly.
5. Click `hot_mix`, `hot_hash`, or a caller to inspect its inclusive/self count,
   source location and assembly. Repeated `recursive_mix` rows are real recursive
   callers. Gray rows identify threads, unresolved addresses, or partial callers.
6. **Z** zooms into the selected frame; **Backspace** moves to its parent.
   The mouse wheel or arrows scroll stack depth. Zoom a thread row to focus it.
7. **Enter** browses the selected sample/caller's source line and its function's
   assembly, provided the live stopped image still matches. **F** switches
   between flames and the source workspace. All of these controls have buttons.
8. Drag across the timeline to filter the flames to that time range. Click a
   thread label/lane to select that TID; click it again to clear that single
   selection. **Ctrl-click** adds/removes threads; removing the last returns to
   all threads. Thread changes preserve the selected time range.
   **Fit range** zooms the lanes, the overview wheel adjusts zoom, and **Reset**
   clears range/thread filters. **F** restores source, threads, stack and events.
9. For scheduling lanes, open **F → S** and enable **Schedule**, then start a
   new capture with **P**. Setup controls subsequent GUI captures; existing
   captures keep their original settings. Scheduling defaults to off.
10. **Q** closes xodb and cleans up the owned target.

The initial capture defaults are 99 Hz and a **60-second wall-clock deadline**,
including time spent stopped. In the profile view, click the **Next** duration
button or press **T** to cycle 10s, 30s, 60s, 5m and **until stopped**. These
controls affect future captures; the current capture keeps its opening settings.
Until stopped disables only the deadline; evidence/resource/scope limits remain.
The current capture's limit is shown alongside its status.

Load different defaults with --config FILE; see [PREFERENCES.md](PREFERENCES.md)
and [the provisional example](../config/preferences.example.json). The same
session defaults apply to omitted MCP arguments. Explicit MCP duration_ms=0
selects until stopped, and positive durations can exceed 60 seconds.

Automatic stops print their reason, elapsed time, configured duration limit,
sample counts and diagnostic to stderr, including deadline expiry and target
exit/detach. Manual stops remain quiet. The demo runs for 20 seconds by default.
A new capture replaces the previous completed capture; a failed start preserves
it. One capture is retained until replacement or debugger shutdown.

Selecting a flame frame does not move the instruction pointer or change target
registers. A blue source diamond marks browsing; the gold assembly arrow still
marks the actual stopped PC. Locals/registers describe the stopped frame, not
the historical sample. A flame node's source link is a representative location
within that function, **not a per-line sample histogram**.

![Timeline range and thread selection filters the CPU flames](images/m2-timeline.png)

## Reconstructed stacks

Open **F → S** and choose a stack preset before a new capture. After collection
stops, **B** switches recorded/reconstructed flames; **I** compares one sample's
recorded kernel callchain and derived frames. **[ / ]** moves through the current
filter and wheel/arrows scroll frames. Defaults remain stacks off / 32 MiB total.
Missing and partial stacks remain visible in coverage counts. Reconstructed
views use saved bytes and verified ELF assets, and work for explicitly resolved
offline captures. [Workflow, machine interface and limits](M2_SAMPLED_UNWIND.md).

## Attach to an existing process

```sh
./zig-out/bin/xodb --attach PID
```

Attach pauses the process. **P** starts capture, **Space** resumes execution,
and **P** stops capture. **D** detaches; closing xodb also preserves an attached
process. The capture covers threads in that one process. A browser's content,
GPU and utility processes have separate PIDs; attaching the browser parent does
not include them. `grep '^Threads:' /proc/PID/status` counts that PID's threads;
`ps -eLf | grep PID` can also match other columns and command-line arguments.

An all-thread capture follows new threads in the same process by default.
Each newborn is enrolled at its initial ptrace stop, before user code runs.
Its CPU samples, mappings and optional scheduling records join the existing
capture, flame graph and timeline; exited workers remain selectable afterward.

Up to **1,024 distinct thread identities** can be retained per capture. Explicit
TID selections stay fixed, even if they initially include every live thread.
Set `profile.follow_threads` to false in preferences, or `follow_threads:false`
on MCP `start_profile`, to keep the fixed opening set for an all-thread request.
The setup panel labels the following mode as **All (…) + new**.

**Child processes still stop collection**, including fork/vfork: process-tree
profiling needs separate address-space identities. A reused numeric TID or a
failed enrollment also stops collection with a specific diagnostic; xodb never
silently merges identities or drops a requested thread. Kernel settings stay
unchanged. [Implementation and test evidence](research/dynamic-threads.md).

### Captures that stop early

Read the stop reason beside the capture number; the sample count is not the
reason. The footer gives additional failure details when available. Failed starts
and exceptional stops also produce a concise **stderr** report (once per stop),
including PID, elapsed time, samples, thread count, mappings, loss and ring size.
Task creation includes child/parent PID and TID; collector failures include the
syscall and errno. Only manual completion stays quiet; automatic duration and target-exit stops also report their reason.
MCP stdout remains JSON-RPC only.

The first exceptional condition observed remains the primary `status` and
`diagnostic`, including during the final drain. `stop_reasons` lists every
unique exceptional condition in observation order; it is empty for a clean
manual/duration/target-exit stop. This order is not a global timestamp order
across thread rings. Later loss still invalidates symbol/scheduling attribution
and increments the loss counters, even if task creation triggered the stop
first. Additional conditions also appear on stderr.

| Stop reason | Meaning |
| --- | --- |
| `duration` | The requested wall-clock interval elapsed, including time spent stopped. Resume soon after starting capture. |
| `metadata_lost` | Perf lost records or required metadata is unavailable. A ring overflow can lose mapping events as well as CPU samples; xodb stops and keeps raw addresses. |
| `thread_scope_changed` | A child process was created, or a new thread appeared during a fixed-scope capture. Pause and start a new capture for the desired scope. `scope_change` identifies the first observed creation; the GUI footer distinguishes a thread from a child process. |
| `mappings_changed` / `image_changed` | The target executed another image. Ordinary observed library loads and mapping changes now continue. |
| `collector_error` | A perf operation failed, the ring-data budget filled, 1,024 thread identities were retained, or a numeric TID was reused. The diagnostic and failure fields identify the cause. |
| `mapping_limit` / `capacity` | The bounded history/sample storage filled. Use a shorter capture. |

A private Firefox test exposed a 16 KiB ring overflow after one sample. Capture
rings use adaptive opening sizes: for roughly 100 threads each ring gets
128 KiB. New threads get that capture's same ring size. Exited rings are drained
before being released. `profile.ring_budget_bytes` / MCP `ring_budget_bytes`
limits total live data-ring memory to **64 MiB by default** (configurable from
4 KiB to 256 MiB), plus one metadata page per open thread. A budget too small
for the opening set rejects the start; exhausted headroom ends collection.
Opening allocations retain the previous 4,096-data-page bound; additional memory
is allocated only as new threads arrive. OS perf limits can reject an open first.
No limits are changed automatically. Restart xodb after rebuilding.

Bounded drains rotate through retained rings so busy threads cannot starve later
ones. [Burst checks](research/capture-robustness.md) and
[dynamic thread tests](research/dynamic-threads.md) cover mapping limits, thread
churn, child processes and resource cleanup.

### Few or no samples

The graph samples **user CPU only**. Frequent system calls can spend nearly all
CPU time inside the kernel, so file copying can produce very few samples even
when it is busy. A task blocked waiting for I/O also produces no CPU samples.
A low sample count alone cannot tell these cases apart.

After collection stops, the view and `get_profile` report separate approximate
**user and kernel CPU totals** for the selected threads, alongside wall time.
These are deltas from `/proc/PID/task/TID/stat`, not sample-derived estimates.
They use the system clock-tick granularity; short bursts may round to zero.
They sum across threads, so CPU time can exceed wall time. Collection setup and
sequential start/stop reads make the accounting interval approximate. Exited,
recycled or inaccessible tasks are excluded and reported as unavailable; partial
coverage is explicit. A capture that ends after process exit may lack totals.

High kernel CPU explains sparse user samples. Low total CPU can mean sleeping,
I/O waits, or other scheduling delays; it does not identify the wait cause.
Kernel stacks, syscall timings, and off-CPU attribution remain future work.

## Capture identity and evidence

- Start requires an all-stopped target and opens an explicit set of live TIDs.
  Each is paired with its debugger thread ID, perf event ID and `/proc` start
  time. All-thread captures additionally enroll held same-process newborns;
  `enrolled_ns` is their monotonic enrollment-start observation (null for opening
  threads). Kernel perf inheritance stays off. `follow_threads`, `opening_threads`,
  `ring_budget_bytes` and current `ring_allocated_bytes` describe effective scope
  and resource use. Legacy archives report an unknown ring budget as null.
- Collection uses `PERF_COUNT_SW_TASK_CLOCK`, excludes kernel/hypervisor stacks,
  and uses `CLOCK_MONOTONIC`. Accepted kernel parameters, ring size, frequency,
  loss, throttle/unthrottle, mapping, exec and fork/exit counts are exposed.
- A capture has its own ID and revision. Appending samples never advances the
  debugger's stop generation. An agent's start/stop action still enters the
  existing audit and requires execution-control scope and a current generation.
- Symbols use the opening map snapshot plus timestamped, observed perf mapping
  changes, including non-executable replacements (`mmap_data`). Each mapping has
  a capture-local identity. Overlapping replacements change only their covered
  range; conflicting equal-time ownership stays unresolved. Graphs sort samples
  and mapping events by timestamp across all selected thread rings.
- ELF images are opened against recorded device/inode identity and file offset;
  historical source/assembly uses retained images after unload or target exit.
  Inaccessible, anonymous/JIT, truncated-path and unsupported identities remain
  raw with a reason. Queries do not reopen a recycled PID or substitute a later
  pathname. Source text is still read from the current local source file.
- Observed mapping changes continue; exec, new tasks outside scope, metadata
  loss, malformed records and exhausted budgets still stop collection. Kernel
  metadata loss, unknown records or a decoder failure invalidate symbol trust
  for the whole capture. Raw stored samples are retained in memory. Live graphs
  are provisional: later drains can supply earlier mapping records and revise
  attribution. Stop collection and use its final revision for stable evidence.
- **This is observed mapping history, not complete address ownership.** Perf
  does not report tested munmap/mremap operations here. An unreported move over
  another mapping or an in-place code edit can leave an incorrect symbol even
  when the observed record history has no loss. Coverage is exposed in the
  GUI and MCP. See [the kernel probe](research/mapping-events.md).
- **Selecting a subset of live threads gives raw-address graphs.** Per-thread
  perf events do not report mappings made by unselected threads. If the set of
  live threads expands during capture, collection ends conservatively. Keeping
  complete mapping history while sampling a subset is future work.

## MCP

Read operations are available in **observe** scope. Start/stop require **control**
or **mutate** scope; they do not change target execution state. The user can
always stop collection with P, including after revoking agent control with F8.

| Tool | Arguments and result |
| --- | --- |
| `start_profile` | Required current `generation`; optional `tids`, `frequency_hz` (1–1000), `duration_ms` (0–4294967295; 0 disables the deadline), `context_switch`, `follow_threads` (booleans), `ring_budget_bytes` (4096–268435456). Defaults: all live and newly created same-process threads and current session preferences (initially 99 Hz, 60000 ms, scheduling off). Returns capture and session. |
| `stop_profile` | Required `generation` and `capture_id`. Disables, drains and closes perf events. |
| `get_profile` | Optional `capture_id`. Returns capture metadata and scheduling status/budgets, `displayed_view` (last GUI frame’s basis/capture/revision/filter, view identity, sample count and visibility, or null headlessly), `cpu_activity` on completed captures, `scope_change` (triggering task IDs/time when reported by perf), `last_start_error`, `requested_threads`, `thread_limit`, and `last_open_failure` (syscall/errno). |
| `get_profile_mappings` | Required `capture_id` and `revision`; optional `start`, `limit` (1–64). Pages opening ranges and observed changes in stable mapping-ID order, with timestamps, image identity, execute permission, reason and coverage. |
| `get_flamegraph` | Required `capture_id`; omit `revision` on the first live page to bind current data. Poll a pending response with its exact `revision`/`view_id` and filters. Pages require `view_id`; optional `tid` or `tids`, `from_ns`, `to_ns`, `start`, `limit` (1–64), `retry`. Ready results include snapshot/current revisions, worker metrics, nodes/counts and `next`. Offline queries still require `revision`. Optional `basis:"reconstructed"` selects completed-capture saved-stack analysis with separate identity, coverage and sample citations; see [sampled stacks](M2_SAMPLED_UNWIND.md#reconstructed-flames-over-mcp). |
| `get_profile_timeline` | Required `capture_id` and `revision`; optional `tid` or `tids`, `from_ns`, `to_ns`, `bins` (1–512, default 128), `start`, `limit` (1–64). Returns CPU bins, paged thread counts, loss diagnostics and debugger markers. Includes scheduling status; use `get_profile_schedule` for intervals. |
| `get_profile_schedule` | Required `capture_id`, `revision`, `tid`; optional `from_ns`, `to_ns`, `start`, `limit` (1–128). Returns paged running/off-CPU/unknown spans and totals for the entire filtered range. Units are elapsed nanoseconds. |
| `add_profile_intervals` | Control scope; required `generation`, `capture_id`, `revision`, `source`, `intervals` (1–128). Adds imported application timings to a completed capture; advances capture revision and action-audit generation. |
| `export_profile` | Control scope; required `generation`, `capture_id`, `revision`, `path`; optional common time/TID filters. Publishes a new Speedscope file for a completed capture. May return `ProfileViewPending` while its worker builds the graph; retry after readiness. Advances action-audit generation only on publication, preserves capture revision. |
| `get_profile_intervals` | Observe scope; required `capture_id`, `revision`; optional common time/TID filters, `start`, `limit` (1–128). Returns overlapping imported intervals with original endpoints, labels, IDs and source. |
| `get_profile_frame` | Recorded basis only. Required `capture_id`, `revision`, `view_id`, `node`; repeat any filters used for the graph. Returns source location and bounded assembly from the retained ELF for that mapping, or an availability diagnostic. Includes mapping identity and coverage. |

Live recorded graphs build on a snapshot worker. The GUI labels the displayed
revision and displayed/collected sample counts. Initial MCP callers should omit
`revision`, then use the returned revision and `view_id` for polling, pages and
frame inspection. An evicted view returns `StaleProfileView`; begin a new view
instead of merging old and new pages. A different filter can return
`ProfileViewBusy` while obsolete work is cancelled. Worker failure is terminal
until an explicit `retry: true` request or a different filter/capture. See the
[full contract and measurements](M2_RECORDED_VIEW_PROPOSAL.md#live-integration-and-machine-contract).


Filter times are nanoseconds **since capture start**, using `[from_ns,to_ns)`.
Omitted endpoints select the whole capture; a returned null `to_ns` means no
upper bound. Thread/time filters intersect. Node IDs belong to that capture,
revision, and exact filter set; they are not persistent function IDs.

Common view filters accept either `tid` or `tids:[1234,1235]`, never both. A
thread array selects their union, intersected with the time range. Up to 1,024
distinct recorded TIDs are accepted; unknown and duplicate IDs reject the
query. Order is normalized, `[]` means all threads, and a one-element array
has the same view identity as its scalar `tid`. This applies to flames, frame
inspection, CPU timelines, imported intervals, stack coverage and Speedscope
export. `get_profile_schedule` continues to require one `tid` because its
result describes one lane. These are view filters; changing them does not
change collection scope.

Flame pagination uses the same capture/revision/view ID/filter arguments on
every page, including during live collection. Other profile queries still use
the current capture revision; stop collection for stable cross-tool comparisons.
`StaleCapture` rejects replaced captures; `StaleProfile` rejects unsupported old
revisions; `StaleProfileView` rejects an evicted graph. Nodes expose parent,
depth, inclusive/self count, horizontal offset in sample units, symbol/module,
mapping ID/reason, and representative lookup address. Mapping IDs are stable within
a capture; node IDs may change when delayed records arrive. Siblings are ordered by name/identity, not
chronologically. `inclusive = self + sum(children)`; the root is the accepted
sample count. Samples excluded by the node budget are counted separately.

Portable export is available below; [native archives](M2_ARCHIVES.md) support
saving and reopening captures in an offline session.

## Timeline data and shared GUI selection

`get_profile_timeline` exposes the same CPU evidence used by the GUI timeline.
For example, after stopping collection, pass its final identity and revision:

```json
{"name":"get_profile_timeline","arguments":{"capture_id":1,"revision":42,"bins":64,"from_ns":100000000,"to_ns":500000000}}
```

Replace the example capture ID/revision with those returned by `get_profile`.
Bins exactly partition the requested range clipped to the capture extent, with
integer nanosecond boundaries and no overlap. Short ranges produce at most one
bin per nanosecond; an empty intersection returns no bins and zero samples.
Use any bin's `from_ns`/`to_ns` with `get_flamegraph` and `get_profile_frame` to
inspect that same interval. For identical filters, timeline `samples` equals
flame `samples + excluded_by_node_limit`. Bin counts sum to the timeline total;
per-thread counts sum to it once all thread pages have been read.

`extent_ns` is relative to capture start and belongs to the returned revision.
During collection, a clock update advances it at most four times per second;
new evidence can advance it sooner. Final-drain sample timestamps are included,
even when just beyond the stop request. Live replies are `provisional`; stop
collection before comparing or paging stable results. `invalid_samples` counts
all stored samples without usable time/recorded-thread identity, independent of
the filter; those samples are excluded consistently from bins and flames.

`debugger_markers` retains up to 1,024 opening-stop, continue, stop, step,
breakpoint/watchpoint, exit and detach observations while collection is active.
All markers are returned with every page, independently of the CPU filter, so
prior control context is available. These timestamps describe debugger control
or observation, not exact kernel scheduling boundaries. Overflow and gaps in
the target event history have separate counters. Completed captures retain their
markers after target exit and discard them only when replaced or destroyed.

`get_profile.displayed_view` reports the last drawn GUI filter, graph revision,
`view_id`, and snapshot `sample_count`. Omit null filter fields in queries. Use
that graph identity for flame queries; timeline/scheduling queries need the
current capture revision. A clock-only revision does not rebuild the graph, so
its revision can remain older even after stopping. For exact count comparisons,
stop collection and wait for its sample evidence to reach the GUI snapshot;
revision equality alone is not a readiness check. GUI selection changes do not
control target execution or grant agents control.

## Optional scheduling

Start with `context_switch: true` through MCP, or **Next sched: on** before a
GUI capture. `accepted.context_switch` records the setting actually used.
`get_profile_schedule` reconstructs one recorded TID in the same
relative clock and returns a partition of its filtered elapsed interval:

```json
{"name":"get_profile_schedule","arguments":{"capture_id":1,"revision":42,"tid":1234,"from_ns":100000000,"to_ns":500000000,"limit":128}}
```

- **Running / off CPU:** only completed pairs of observed switch events.
- **Unknown:** unmatched capture edges, disabled collection, invalid identity,
  contradictory ordering, loss or exhausted history. A thread that runs without
  switching out can have CPU samples inside an unknown final scheduling span.
- `switch_out_preempted` describes the switch-out transition; it does not reveal
  a lock, wait stack, I/O operation, wakeup source or time spent runnable.
- Totals cover the whole filtered range, independent of pagination; they sum to
  its elapsed length. `scheduling.status = available` means the event stream is
  usable, not that every nanosecond has known scheduling state.
- Unlocalized loss invalidates scheduling attribution for the whole capture.
  Contradictory records invalidate their lane. A retention limit preserves
  completed pairs before the cutoff, marks its suffix unknown and stops capture.
- Debugger-stop overlays use per-thread observed control history. They can
  identify debugger-induced pauses, with bounded overlays and explicit omissions.

[Integration evidence and cost measurements](M2_TIMELINE.md).

## Imported frame and request timings

![Imported application timing overlay](images/m2-intervals.png)

Completed captures can retain application-supplied intervals through
`add_profile_intervals`. The timeline draws blue overlays and labels them
**imported** on hover. Existing drag/thread filters query the same evidence
through `get_profile_intervals`. Application timing does not alter CPU samples,
flame counts or scheduling reconstruction. It is caller-supplied evidence;
xodb does not verify the producing application, clock alignment or wait cause.

```json
{"name":"add_profile_intervals","arguments":{"generation":37,"capture_id":1,"revision":206,"source":"frame instrumentation, CLOCK_MONOTONIC","intervals":[{"from_ns":200000000,"to_ns":231500000,"tid":1234,"kind":"frame","label":"frame 60","correlation_id":60}]}}
```

Each interval needs `from_ns`, `to_ns`, `label`. Optional `tid` must be a recorded
thread; omission makes it global. `kind` is `frame`, `request` or `custom`;
`correlation_id` is an optional application integer. Times are relative to the
capture start and must be wholly inside its completed extent. Equal endpoints
represent an instant. Labels and sources are valid UTF-8, at most 96 bytes, with
no ASCII control characters. A batch is validated before anything is added;
4,096 records per capture is the hard limit. Import requires control scope and
is audited; the returned capture revision and session generation advance. No
thread is resumed and no target bytes/registers are changed.

Read queries use interval overlap with the usual half-open range. A point at the
selected end is excluded. Original endpoints are returned unchanged, so a query
for part of a long interval does not relabel its whole duration. Global records
match every selected TID. Pagination is over matching records in insertion order.

The T04 frame fixture writes compatible CLOCK_MONOTONIC microsecond CSV. Convert
it to guarded tool calls with:

```sh
python3 scripts/frame-intervals.py frames.csv --capture capture.json \
  --generation 37 --tid 1234 > import-calls.json
```

`capture.json` can contain the completed capture summary, `get_profile` result,
or full MCP response. Use the current session generation and the opening frame
thread’s TID. The converter keeps only complete work intervals, omits pacing,
skips boundary-crossing/outside rows, and reports those counts. It writes tool
calls to stdout; it does not contact xodb. Its projected revisions/generations
assume sequential imports without intervening actions; refresh metadata if a
stale guard fires. Verify CSV and capture came from the same run/clock.

Validation: `tests/m2-intervals.py` imported 49 real frame timings and identified
the known 31.54 ms injected lock stall. Paging, overlap/TID rules, provenance,
atomic rejection and unchanged CPU/scheduling evidence passed. Unit coverage and
private GUI overlay/hover/filter checks accompany the integration. This workflow
provides application context while direct uprobes remain unavailable under the
current [host permissions](research/uprobe-permissions.md).

## Bounds and current limits

- At most 1,024 sampled threads, 16,384 retained samples, 64 kernel callchain
  entries, 8,192 symbol-cache identities and 8,192 graph nodes. Retained images
  are limited to 256, with at most 16,384 opening regions and 4,096 mapping changes. Exceeding a limit rejects
  a request, stops a capture, or reports exclusions/unknown labels explicitly.
- Optional scheduling retains at most 262,144 transitions total and 65,536 per
  thread. Transition storage including capacity slack is bounded by 9 MiB on
  this x86-64 build, separate from CPU samples, rings and UI caches. Allocation
  failure or capacity stops capture with `scheduling_limit`; invalid/contradictory
  evidence reports `scheduling_error`. Exceptional stops also report to stderr.
- Timeline display: 1,024 lanes, at most 64 visible, 4,096 lane quads and 4,096
  retained debugger-stop overlays. An omitted-overlay notice directs inspection
  to MCP’s original bounded marker history. Live preparation runs at most four
  times per second; range drag previews commit a flame filter on release.
- One perf fd and a 4–64-page data ring plus a metadata page per sampled thread.
  The largest power of two that fits 4,096 total data pages is used: on 4 KiB
  pages, 256 KiB for up to 64 threads, 128 KiB for 100, and 16 KiB for 640–1,024.
  Total ring mappings stay at most 20 MiB. Polling/final draining are bounded;
  live graph rebuilds are throttled to at most four per second. The view
  draws at most 512 visible rectangles; zooming reveals small frames. Raw
  samples use compact cores and shared exact callchains under a separate 32 MiB
  ceiling; measured storage at the current cap is 1.1–11.2 MB across four stack
  shapes. Saved registers/stack bytes have their own budget. See
  [storage validation](M2_CAPTURE_SCALING.md). A synthetic maximum-budget graph
  (16,384 samples × 64 callers, 16,384 opening regions, 4,096 changes) took
  87–95 ms in ReleaseSafe and 558–584 ms in Debug on this workstation. Debug can
  visibly stall at that bound; use `./scripts/build -Doptimize=ReleaseSafe` for
  heavier captures. These are rebuild measurements, not full-game overhead
  claims. ELF mappings and libdw data have additional costs.
- Current flames use kernel frame-pointer callchains. Optional saved registers/
  stacks support separate per-sample MCP DWARF reconstruction; see
  [sampled-state workflow](M2_SAMPLED_UNWIND.md).
  Build profiled code with frame pointers and disable sibling-call optimization
  when caller fidelity matters. Libraries can still lack frame pointers. The
  derived tree stops at the first caller outside the observed executable mappings at sample time
  and labels that ancestry partial; an executable address alone does not prove
  that a caller is correct. Original kernel callchains remain in stored records.
- Sample IPs use their recorded address. Caller return addresses use minus one
  for symbol/source lookup; only the initial duplicate leaf is removed, so
  recursion survives. Context markers never become symbol addresses. Kernel
  truncation and unavailable/partial callers are visible.
- Perf mapping events are incomplete: this workstation reports neither munmap
  nor mremap, including moves over another executable mapping. Such unreported
  moves can invalidate symbol attribution despite retained history. See [the measured coverage](research/mapping-events.md).
- No guarantees for JIT/self-modifying code, in-place edits to mapped ELF files,
  remote targets, capture stitching across exec, or events outside the selected
  task contexts. This is a local x86-64, single-process workflow.
- ELF assembly is decoded from a declared symbol boundary, bounded to 64 KiB
  and 4,096 instructions, with up to 16 instructions returned around a sample.
  It can differ from live patched code. Normal source browsing checks the live
  image's device/inode/load bias before following a captured address.
- The software clock and frame-pointer restrictions can bias sampling. No
  hardware-cycle weighting, off-CPU attribution, uprobes, syscall/allocation
  trace, GPU profile, or production game/server overhead claim is included.

## Validation

```sh
./scripts/build test --summary all
./scripts/build test -Doptimize=ReleaseSafe --summary all
python3 tests/m2-profile.py
python3 tests/m2-mappings.py
python3 scripts/gui-smoke.py --profile
```

Live tests require the workstation's ptrace/perf access. Agents use `~/bin/bugme`
to coordinate resources; automated GUI tests use private headless Sway only.
No system permission or kernel setting is changed.

The tests cover known hot paths, recursion, conservation, paging, time/thread
filters, stale identities, scopes, zero samples while stopped, timed/manual/exit stops, continued observed mapping changes, source/assembly after exit, and closed perf descriptors. Kernel-heavy,
sleeping and 640-thread fixtures verify CPU accounting and larger captures.
Mapping fixtures load/unload distinct libraries at reused addresses, toggle code
permissions, and run anonymous code on the main or a worker thread. They check
separate mapping identities, subset conservatism, and historical source/assembly
after unload and exit. The private
GUI test exercises capture, selection, zoom, source browsing, resizing and owned
target cleanup, checking unchanged registers and generation during browsing.
Exact results and limitations are in [journal.md](journal.md).


## Save a portable profile

Add `--profile-out NEW_FILE` when launching xodb:

```sh
./zig-out/bin/xodb --profile-out capture.speedscope.json --attach PID
```

Capture with **P**, resume with **Space**, stop capture with **P**, and quit with
**Q**. Shutdown saves the full latest capture; an active capture is stopped and
drained first. The stderr message reports the saved sample count and path, or
an explicit error. No capture means no file. Existing files are never replaced.

For a selected time range/TID, use control-scoped MCP after stopping capture:

```json
{"name":"export_profile","arguments":{"generation":42,"capture_id":1,"revision":206,"path":"selected.speedscope.json","tid":1234,"from_ns":200000000,"to_ns":500000000}}
```

Use current identities from `get_session` and `get_profile`. The export contains
weighted CPU stacks in [Speedscope's sampled format](https://github.com/jlfwong/speedscope/wiki/Importing-from-custom-sources).
Open the file in Speedscope and use its **Left Heavy** or **Sandwich** view.
Weights count samples (`unit: none`); the stack order is synthetic. A Time Order
view of this aggregate **does not show the original execution chronology**.
Recursion, caller ancestry and distinct mapping identities are preserved.

The `xodb` extension retains capture/filter identity, loss and mapping coverage,
frame identities, CPU bins/thread counts, per-thread scheduling totals, imported
application intervals and their provenance. Debugger markers cover the whole
capture so a range can retain earlier stop/resume context. This is a portable
aggregate: it omits raw samples, per-switch history, executable/source files and
target state. xodb does not reopen Speedscope JSON; use the native archive workflow below. Speedscope does not
render the xodb-specific scheduling or application timing metadata.

Files are private (0600), limited to 64 MiB and published only after the complete
JSON is written. Writes use normal kernel buffering, with no file or directory
durability sync. Publication refuses an existing destination, including a symlink,
and removes its temporary file on success or failure. MCP export
requires control scope because it writes a file; it records an audited action
without changing target registers or capture revision.

Validation: `python3 tests/m2-export.py` checks sample/path conservation against
MCP, full/TID/time/empty filters, recursion, scheduling and interval agreement,
post-exit retention, shutdown drain, stale/scope guards and no-overwrite behavior.
Its optional `--schema PATH` validates all outputs against the upstream
[JSON schema](https://www.speedscope.app/file-format-schema.json) with the test-only
Python `jsonschema` package. Live tests and schema validation passed on this
workstation; browser rendering itself was not exercised in this increment.


## Save and reopen a native capture

Use --capture-out NEW_FILE when launching or attaching, then capture with P and
quit with Q. Reopen without a target using --open-capture FILE:

~~~sh
./zig-out/bin/xodb --capture-out run.xcap --attach PID
./zig-out/bin/xodb --open-capture run.xcap
~~~

This preserves raw evidence, origin, mapping/scheduling/application history and
recorded symbol/source-location annotations. The offline flame/timeline view
works after the old binaries are removed. Optional verified assets enrich
assembly, and explicit reanalysis creates a different view identity. Archive
work runs on a worker with progress/cancellation; saves perform no durability
syncs. See [M2_ARCHIVES.md](M2_ARCHIVES.md) for MCP, limits and validation.


## Capture setup and reconstructed sample inspection

Press **S** in the profile view for the approved T14 setup panel. Set duration
(including a custom value or until stopped), rate, scheduling and all/current
versus explicitly chosen threads. Unchecking a row from all-current mode selects
all remaining threads. New threads never silently join an explicit subset; stale
thread identities and empty subsets reject a start. **P** still starts/stops;
**T** cycles duration. Settings edited during collection apply to the next capture.
**Escape** cancels numeric editing or closes setup. Offline controls are disabled.

The panel shows recorded stop reasons and start failures separately, sample counts,
loss, selected threads and deadline. At narrow widths it uses Settings/Threads
tabs. Its defaults do not change agent scope or write back a preference file.

For opt-in saved stacks, configurable 32 MiB retention, raw sample inspection,
coverage by thread/time and background DWARF callers, see
[M2_SAMPLED_UNWIND.md](M2_SAMPLED_UNWIND.md). Native reconstructed flames remain
[T16](tasks/T16-derived-stack-views.md); the existing graph keeps its recorded basis.
