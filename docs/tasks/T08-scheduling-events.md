# T08: scheduling-event collection for the M2 timeline

Status: delivered and integrated by Codex, 2026-10-01.
See [integration and validation](../M2_TIMELINE.md). The packet below is the original handoff.

## Goal and owned paths

Develop and validate an optional extension to the existing perf collector that
records per-thread scheduling transitions alongside CPU samples. Deliver it as
a reviewed integration patch so the shared application keeps building while
the capture model learns the new record kind.

Own only:

- `tests/repros/scheduling/`
- `docs/research/scheduling.md`
- `docs/research/scheduling/`

Read `docs/M2_TIMELINE.md`, `docs/PROFILING.md`, the T04 workload report, and
`src/profile/linux_perf.zig` / `records.zig`. Put proposed changes to those two
production files in `docs/research/scheduling/collector.patch`; test them in a
fresh scratch source copy. Do not edit production/shared files or other tasks.
The patch is for Codex to integrate, not an authorization to alter current
capture policy or defaults.

## Collector requirements

- Use the installed Zig 0.16 toolchain and Linux ABI. No new package, service,
  privileged helper, system setting, inherited collection or CPU-wide capture.
- Add an explicit optional `context_switch` configuration field, default false,
  and report its accepted value. Preserve all existing CPU/mapping settings,
  thread identity, ring sizing, failure reporting and cleanup behavior.
- Decode `PERF_RECORD_SWITCH`, including switch direction, preemption flag,
  sample-ID timestamp and task identity. Verify `PERF_RECORD_SWITCH_CPU_WIDE`
  layout defensively if supporting its decoder, without enabling that mode.
  Keep the switched task and optional next/previous task identities distinct.
- Supply raw facts to the coordinator; interval pairing and display belong to
  Codex. Propose a typed record and output API that remains bounded, preserves
  ordering evidence and distinguishes absent fields from zero values.
- New record kinds may require changes to exhaustive switches in capture.zig;
  name every required integration point rather than editing them yourself.
- Preserve ring acquire/release ordering, consumption only after successful
  decode, retry on output capacity, and explicit malformed/unknown/loss results.
  Default-disabled collection must preserve the old event selection.

## Required evidence

1. Compare constants/layouts with installed headers and the
   [perf ABI](https://man7.org/linux/man-pages/man2/perf_event_open.2.html).
   Cite primary sources for semantic claims and record host/kernel versions.
2. Offline wrapped/truncated records, optional sample-ID fields, invalid sizes,
   mixed CPU/MMAP2/loss/switch streams and output-capacity retries.
3. Live owned workloads with known CPU and sleep phases. Explain the first/last
   transition behavior when enabling, disabling and stopping a traced thread;
   use time brackets rather than exact counts that vary with scheduling.
4. Demonstrate how per-thread identities behave across migration, thread exit
   and unavailable tasks. If preemption cannot be induced reliably, separate
   the decoder check from any unverified live claim.
5. Measure event rate and drain pressure on a bounded many-thread or handoff
   workload. Include ring bytes, losses, fd cleanup, and disabled/enabled timing.
   Keep T04 files unchanged; invoke them or make a new small owned fixture.
6. Investigate whether the records provide enough evidence to reconstruct
   running/off-CPU intervals, and where gaps must stay unknown. They do not
   provide wait stacks or waker/lock attribution; document that boundary.

Use `~/bin/bugme` before outside-sandbox perf tests. Never interpret sandbox
EPERM as proof the workstation lacks perf. Use owned processes, bounded test
durations, repo-local caches, and separate compiler output. Back up every
existing file before editing it. System changes and paid tools require review.

## Handoff

Return the patch, an exact build/test runner, measured results, output contract,
integration points, budget recommendation, limitations and provenance. The runner
must compile the proposed collector/decoder in the scratch copy, not accidentally
test the untouched production module. Note opportunities for external local or
remote LLM analysis without embedding a model into the collector.
