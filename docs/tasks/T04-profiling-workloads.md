# T04 Profiling workload suite

Goal: prepare representative, reproducible workloads for the eventual game and
high-performance server profiling workflows. Own `tests/workloads/` and
`docs/research/profiling-workloads.md`. This task does not implement a collector
or change the planned milestone order.

## Deliverables

- A small C/C++ or Zig frame-loop workload with worker jobs and an intentionally
  triggered frame stall. Use a fixed seed and mark the known cause in its source.
- A server-like request workload with configurable work, queue pressure, and
  lock contention. Prefer in-process or local-only traffic; avoid external
  services, root privileges, downloads of large games, or paid tools.
- Build/run scripts with bounded runtime, explicit thread count/load, graceful
  termination, and all generated files inside the workdir.
- A measurement plan: which CPU, scheduling, allocation, and application events
  distinguish the known causes, and what overhead/event-loss measurements matter.
- A short list of possible real large games/server projects for later validation,
  with access/build requirements and source links. Synthetic fixtures establish
  controlled behavior; they do not establish large-application scalability.

## Acceptance and handoff

Show baseline and deliberately impaired runs with reproducible parameters.
Coordinate CPU-heavy runs with the user. Do not change kernel settings or
install tools. Document any unavailable perf/BPF capability without treating
sandbox denial as a workstation failure.

Return sources, commands/results, known causal ground truth, and proposed M2
acceptance checks. Note how an LLM could compare captures or propose a useful
next measurement, with evidence needed to check its conclusions.
