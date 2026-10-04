# T06: bounded Linux CPU sampling collector

Status: delivered by Grok; integrated by Codex into CPU captures, flame graphs
and MCP. See [the demo and integration limits](../PROFILING.md). Claude owns T04
workloads. The ownership section below preserves the original task boundary.

## Goal and owned files

Implement a small, independently testable `perf_event_open` collector for M2's
first CPU sampling workflow. Follow the already agreed Linux-first direction.
Own only:

- `src/profile/linux_perf.zig`
- `src/profile/records.zig`
- `tests/repros/perf/`
- `docs/research/perf-collector.md`

Do not edit shared build, target, session, MCP, UI, dependencies, or T04 files.
Use a standalone Zig test root/build runner under your test directory. Keep
proposed integration changes in your research document. Back up existing files.

## First implementation

- Zig 0.16, installed Linux APIs; no new packages, daemon, root requirement,
  kernel/sysctl changes or paid tools. Use a local C import if needed so the
  shared `src/c.zig` remains with Codex.
- Explicit start/stop/drain/close ownership on one caller thread. Accept an
  explicit list of existing Linux TIDs and bounded configuration. Never attach
  automatically to unrelated processes or sweep all system tasks.
- Start with user-space CPU-clock or task-clock sampling; report the actual
  event selected, requested rate and kernel acceptance. Hardware counters can
  be an optional capability, not a silent substitute.
- Use mmap ring buffers correctly: ordering of data_head/data_tail, wrapped
  headers/payloads, bounded draining, validated record lengths, unknown-record
  skipping, explicit lost/throttled events. Prove clean shutdown on every
  partial-start failure. Bound file descriptors, ring size and decoded storage.
- Normalize sample IP, pid/tid, monotonic timestamp, period/weight and callchain
  addresses when available. Preserve kernel context markers separately from
  addresses. A truncated or absent callchain is explicit.
- Include process/mapping/exec metadata or describe exactly how the coordinator
  must supply mapping epochs for symbolization. Do not equate a reused PID/TID
  with a stable debugger identity. Keep raw collection independent of DWARF.
- Return distinct unavailable/permission/configuration errors. Sandbox denial
  does not establish that workstation perf is unavailable. Do not weaken machine
  security settings to get a measurement.

## Acceptance

1. Pure ring-decoder tests: wrapping, malformed/truncated records, unknown
   types, lost samples, mixed event/sample records, capacity exhaustion.
2. An opt-in bounded live test (a few seconds, small CPU/thread limits): known
   hot functions, start/stop/restart, thread exit, close with queued records, and
   failure cleanup. Show a sample distribution compatible with known work;
   avoid exact timing or sample-count assertions.
3. If perf is available, report measured overhead versus the same workload
   without collection, observed loss and capture settings. T04 is optional input;
   do not wait for it or change its files. Otherwise give the exact failing
   syscall/errno and keep offline acceptance runnable.
4. Document proposed public types and integration calls, timestamp domain,
   supported architecture/kernel assumptions and remaining races. Show how a
   collector reports a thread that disappears during start.

Run `~/bin/bugme` before outside-sandbox CPU tests and coordinate workstation
resources. All caches/artifacts stay in the workdir. No remote actions.

## Research and handoff

Cite primary kernel perf documentation and any reused implementation; preserve
applicable notices. Return exact commands/results and a minimal integration
sketch. Note where an external/local LLM could compare hot paths or choose the
next capture, and which loss/overhead/identity facts it must cite. Statistical
CPU samples cannot by themselves prove why a particular write occurred.
