# T17: task-scoped syscall timing feasibility and collector prototype

Status: delivered by Grok (2026-10-01). The user requested evaluation with the
necessary permissions/configuration; [configured rerun](../T17_CONFIGURED_RERUN.md)
passed after user-authorized global tracefs/perf setup, including ordinary-user
collection. Production integration remains pending. The original read-only
requirement below describes Grok's packet; the later setup is documented separately.
[Take 2 review](../T17_TAKE2_REVIEW.md) records diagnostic/start-contract
corrections and the verified initial-read versus terminal-exit boundary spans.
Independent of T15 and the ARM64 production migration.

## Goal and ownership

Supply evidence for workloads with few CPU samples (copying files, waiting
servers): a bounded prototype of syscall entry/exit timing for explicitly chosen
owned threads. This is research/prototyping, not a new production default.
Own only:

- `tests/repros/syscall-context/`
- `docs/research/syscall-context.md`
- `docs/research/syscall-context/`

Read the collector, record decoder, scheduling/timeline model, Session scope
checks, `docs/PROFILING.md`, `docs/M2_TIMELINE.md`, `docs/M2_ARCHIVES.md`,
`docs/tasks/T15-capture-scaling.md` and its delivered measurements when present.
Use scratch copies under your paths; deliver production suggestions as a patch
against a recorded base and hashes. Leave shared files unchanged.

## Required slice

1. Read-only capability/permission inventory on this workstation. Prefer a small
   perf tracepoint experiment using installed interfaces; investigate alternatives
   only when evidence justifies them. Use current primary kernel/UAPI sources.
   Do not change sysctls, mounts, capabilities, packages or system configuration.
   If unavailable, deliver the decoder/pairing model and an explicit native gate.
2. Collect only selected owned TIDs, without following children, system-wide
   tracing, or silently broadening scope. Document event filtering, task identity,
   clock compatibility, per-thread descriptors/rings and cleanup. Initial payload:
   syscall number, thread identity, entry/exit timestamp, return result, loss and
   validity. Do not capture pointed-to buffers, strings or paths by default.
3. Pair entry/exit conservatively: capture begins mid-call; missing/reordered
   records; restart/interruption; nested or unexpected entries; thread exit,
   exec and reused numeric TIDs; loss and retention exhaustion. Unknown intervals
   stay unknown. Explain whether duration includes descheduling; do not call it
   CPU cost, I/O service time, or proof of the reason for waiting.
4. Keep pairing and storage bounded independently of CPU samples. Propose
   summaries and detail pages linked to existing time/thread filters, separate
   provenance and stop reasons. Model overflow explicitly. No selected retention
   policy, new archive feature or MCP execution authority is adopted here.
5. Owned fixtures: syscall-heavy copying using a small temporary file, a pipe or
   socket pair with known waits, and a CPU-heavy control. Compare traced versus
   untraced repetitions and, if already available, a separately measured strace
   run. Report CPU use, runtime perturbation, record loss, memory and cleanup;
   do not extrapolate these fixtures to Firefox or large games.

## Handoff

Provide a runnable standalone prototype, pure failure-injection tests, native
logs or a precise permission blocker, measured tradeoffs, interface proposal,
licenses/dependencies and reproduction commands. Coordinate host tests;
use only repo-local scratch and no visible GUI. Do not touch Jetson.

Precede any approval choices with a short critical review. The key risk is
measurement overhead and misleading duration attribution. Recommend the smallest
useful production slice from the evidence, with unsupported cases clearly marked.
Journal how an external agent might correlate syscall intervals with CPU samples
and scheduling while separating observations from causal hypotheses.
