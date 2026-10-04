# T03 Debugger lifecycle audit

Goal: find concrete correctness gaps in M0 target control before M1 builds on it.
Read `src/target/linux.zig`, the session model, MCP adapter, and their tests.
Own `docs/research/target-audit.md` and `tests/repros/target/`. Treat the existing
implementation as review input; propose patches without editing shared code.

## Focus

- `PTRACE_SEIZE`, clone discovery, attach while threads are created/exiting,
  interrupt/continue, signal delivery, and detach after partial failure.
- Tracee cleanup and reaping order, stale/reused PIDs or TIDs, and who owns
  launched versus attached processes on every error path.
- Snapshot consistency, event ordering/loss, running-thread register access,
  and partial or inaccessible memory reads.
- Describe the boundary for fork/vfork, nonleader exec, and group/job-control
  stops. Those are currently documented limits; distinguish new requirements
  from failures of the supported M0 contract.

## Acceptance

Every claimed defect includes a minimal disposable fixture, exact reproduction
commands, expected/actual behavior, and a proposed fix. Use timeouts and always
clean up the fixture. Do not attach to the user's unrelated processes. Run
ptrace tests outside the sandbox after `~/bin/bugme`; keep artifacts in your
owned directory. Cite the relevant Linux specification or reference behavior.

Prioritize failures that corrupt observations, change a target unexpectedly,
leave a target traced/stopped, or block cleanup. Avoid a generic style review.
If you cannot reproduce a concern, label it a hypothesis.

## Handoff

Return ranked findings, fixture sources, measured results, and small proposed
patches/tests for the coordinator. Do not claim full Linux debugger correctness
from a handful of fixtures. Record any opportunities for agent-generated
stress scenarios with deterministic pass/fail checks.
