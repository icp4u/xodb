# M2: keep captures running across thread creation

Status: adopted by the user and implemented, 2026-10-01.

## Adopted behavior

- An all-thread capture follows newly created threads in the same process.
  Enroll each at its initial ptrace stop, before its first user instruction.
  Flame graphs, thread filters, scheduling lanes and saved captures include it.
- Add `follow_threads` to capture configuration and preferences (default true).
  An explicit TID selection always keeps its scope fixed, even with this default.
  Setting false preserves the current stop-on-new-task behavior.
- Child processes remain a reported scope boundary for this increment. Following
  a process tree needs separate address spaces and process identities; moreover,
  an untraced vfork/CLONE_VM child can share the parent's mappings. We must not
  quietly treat every child process as harmless to parent symbol attribution.
- Retain enrollment times and stable debugger/perf identities. Stop explicitly
  on numeric TID reuse instead of merging two incarnations into one flame lane.
- Keep the 1,024 distinct-thread-per-capture bound. Release exited threads' rings
  after their final records are drained. Keep adaptive opening ring sizes; add a
  configurable 64 MiB total ring-data ceiling (allocated only as threads arrive,
  plus one metadata page per open thread). New threads get the same ring size as
  opening threads. Failure to enroll or a resource limit stops the capture with
  a concrete stderr/MCP/UI reason, preserving evidence already collected.
- Persist the scope policy and enrollment times behind a required archive feature
  bit. Old archives keep their opening-thread interpretation; older readers reject
  new dynamic captures instead of misrepresenting their scope.

## Critical review

This fixes worker-pool growth and thread churn without a polling gap at the start
of a new thread. It builds on ptrace attachment already used by xodb, and does not
need new privileges or kernel settings. A plain `perf inherit` switch is not a
substitute: Linux documents that inheritance with cpu=-1 prevents the sampling
mmap ring used by this collector. Enrollment still delays thread startup while
xodb opens its event and ring; profiling under a debugger is not zero overhead.

The limits are deliberate and visible. This is not process-tree profiling;
process creation can still end a capture. A capture that creates more than 1,024
thread identities, reuses a TID, or exhausts its ring budget also ends. The larger
configurable ring ceiling preserves room for mapping bursts and growing worker
pools, but can increase debugger memory use. Scheduling before enrollment remains
unknown. Tests must cover short-lived threads, new-thread mapping changes,
selected subsets, failed enrollment, archive reload and resource cleanup.

## Implementation and evidence plan

1. Add bounded collector enrollment/retirement with transactional fd cleanup.
2. Connect enrollment to the target's initial child stop on its ptrace owner thread.
3. Carry scope/enrollment evidence through captures, workers, archives and MCP.
4. Add preferences and display the effective scope; retain fixed subset semantics.
5. Exercise owned CPU fixtures, mapping changes on new threads, thread churn,
   archive round trips and a private GUI flame graph. Record measured overhead.

Sources: Linux [perf_event_open](https://man7.org/linux/man-pages/man2/perf_event_open.2.html)
and [ptrace](https://man7.org/linux/man-pages/man2/ptrace.2.html) interfaces.

Potential LLM use: compare opening and newly created worker hotspots using recorded
thread IDs and enrollment times; identify short-lived-worker churn without claiming
that unsampled startup time was observed CPU time.

## Foundation verified before adoption

The collector and target observer were verified before adoption; automatic
enrollment is now integrated in all-thread sessions. A real owned pthread was enrolled before resume; its
first executable mapping and CPU samples were received. Resource/admission
failures and retired-ring cleanup passed. Full ReleaseSafe suite: 181 passed,
four ARM-only skips. See [the research journal](research/dynamic-threads.md).
