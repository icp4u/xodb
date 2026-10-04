# Scoped syscall timing candidate

Status: adopted by the user, 2026-10-02.
This implements the syscall/blocking-context item in the approved x86 functional
list. It incorporates the corrections in [T17 take 2 review](T17_TAKE2_REVIEW.md).

## Short critical review

This fills the gap between sparse CPU samples and observed blocking: select
threads, record kernel entry/exit durations, and inspect their overlap with
thread scheduling. The same retained evidence is available in the timeline,
GUI detail panel, MCP and saved captures. The sustained owned fixture retained
all 19,500 calls without loss; status requests during sustained collection stayed below 3.2 ms. Starts are
transactional and arguments are excluded from retained captures.

Tracing every call perturbs syscall-heavy workloads; these fixtures do not
establish game/server overhead. Elapsed time includes preemption and debugger
pauses, and cannot identify a wait cause. Raw tracepoints do not distinguish
all compatibility ABIs, so names explicitly assume x86-64; raw numbers remain
available. The proposed first scope is 1–32 explicitly chosen threads, and a
full detail store stops the entire capture. That makes the retained boundary
clear but can end CPU profiling sooner. Syscall archives require the new 2.5
reader; ordinary captures keep their existing encoding.

## Candidate workflow

- Off by default. Setup (`S`) adds a **Syscalls** toggle beside scheduling;
  `Y` toggles it while Setup is open.
- Select **Chosen** and 1–32 current threads. All/new-thread capture is refused
  while syscall tracing is requested. This uses the existing explicit selection
  semantics: new tasks end the capture.
- Amber timeline overlays show retained spans. Drawing is bounded and crowded
  overlays can be omitted; `X` opens all retained detail with paging and the
  same thread/time filter as the flames. Missing endpoints have no duration.
- `profile.syscall_timing` / `profile.syscall_limit` preferences, and matching
  `start_profile` arguments. Default 16,384 spans, configurable 1–65,536.
- The shared ring uses 16 data pages per selected thread and two perf descriptors.
  Its data pages count toward the existing capture ring budget. Metadata pages
  and bounded retained spans are separate allocations.
- Stop with `syscall_limit` on full detail; `syscall_error` on unusable records.
  Lost/throttled records invalidate affected pairing and remain visible in counters.
- `get_profile_syscalls` pages original entry/exit times, raw return values,
  pairing reason, and observed running/off-CPU/unknown overlap. Agent control
  scope is required to start/stop; read queries work with observe scope.
- Archive 2.5 uses required feature bit 5 and a bounded `SYSC` section. Earlier
  readers reject the required feature; reopen never recollects from the host.
- No system-policy changes, privileges, global tracing or implicit child tracing.

Preview: [detail](../.work/input-functional-7401396093/run-01/02-syscall-detail.png),
[small panel](../.work/input-functional-7401396093/run-01/04-small-syscalls.png),
[setup](../.work/input-functional-7401396093/run-02/07-small-setup.png).
These are ignored local review artifacts.

[Usage](SYSCALL_TIMING.md) · [journal](research/syscall-timing.md).
