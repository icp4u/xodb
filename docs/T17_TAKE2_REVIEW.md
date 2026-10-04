# T17 take 2 — integration review

2026-10-01. Reviewed [Grok's second memo](research/syscall-context-take2.md)
against the configured-run evidence and current source. The memo is a product
recommendation drawing on that evaluation; it supplies no new collector patch
or independent sustained-load results. Production syscall timing remains pending.
The delivered memos are preserved; corrections and new evidence are below.

## Critical assessment

The direction is sound: off by default, explicitly selected threads, actual perf
opens determine access, and agent authority stays distinct from kernel permissions.
Successful ordinary-user operation should be quiet. Reusing the setup/header/
stderr/MCP surfaces and linking SETUP.md avoids a warning before the user requests
syscall timing. The configured run supports proceeding with a collector prototype.

The refusal wording overstates what an errno proves, and the explanation of the
unknown span is incorrect. There is also an unresolved start contract: preserving
CPU-only operation is sensible, but a requested combined capture cannot report
"Did not start" while quietly collecting CPU-only evidence. Correct these before
adopting the proposed messages or GUI/MCP behavior. The ~2x copy perturbation and
short end-drain fixtures still require sustained-load and lifecycle work.

## Corrections before integration

### 1. Preserve errno; do not claim a unique cause

`EACCES` does not prove the paranoid check failed: target credentials can also
cause it. `EPERM` is not proof that paranoid/CAP_PERFMON is irrelevant; it can
also reflect permission or unsupported attribute restrictions. `ENOENT` alone
does not establish that this kernel lacks syscall tracepoints. These cases
vary across kernels and architectures. The controlled paranoid=2/1 experiment
supports that explanation for those specific owned runs.
[Linux perf_event_open error documentation](https://man7.org/linux/man-pages/man2/perf_event_open.2.html#ERRORS).

Keep failure component/stage, syscall/path, errno, TID and cleanup counts.
Attach observed settings and conditional next steps, not an asserted kernel
call path. The current broad `permission` kind already preserves raw errno;
splitting it into supposed internal causes would lose accuracy. Machine-readable
fields should describe observations; `detail` carries the explanatory sentence.

Suggested wording:

> Syscall timing could not open the selected thread's perf event (EACCES).
> Check target access and host tracing policy; SETUP.md describes the tested
> perf_event_paranoid=1 and CAP_PERFMON configurations.

Missing metadata, unreadable metadata, unsupported layout and an open failure
should remain distinguishable. No new automatic mount, privilege escalation or
policy change is implied. `AgentScopeDenied` remains a session-policy error.

### 2. The counted unknown span is the terminal syscall

The memo says the configured runs' unknown span was already in progress when
capture began. However, `probe.zig` counts `unknown_after` only for spans with
an entry timestamp at or after `go_ns`. An initial exit with no entry cannot
contribute to that count.

An instrumented, ordinary-user rerun of all three fixture modes confirmed:

| Boundary | Number on this x86-64 host | Pairing reason | Counted in `unknown_after`? |
| --- | ---: | --- | --- |
| Initial synchronization read finishes | 0 (`read`) | `exit_without_entry`; entry absent | No |
| Process terminates | 231 (`exit_group`) | `missing_exit`; entry after `go_ns`, exit absent | Yes |

Every run has **two** unknown boundary spans, with `unknown_after=1`. The first
lacks an entry; the terminal syscall does not return. Neither proves loss or a
permission problem. Keep elapsed time unavailable and retain the actual reason.
A later production model can distinguish observed termination from missing data
when lifecycle evidence supports it; do not infer that from syscall number alone.
The host's `/usr/include/asm/unistd_64.h` confirms these syscall numbers.

### 3. Format validation needs widths and interpretation

The memo lists field names and offsets. The decoder reads 64-bit little-endian
words, skips 48 argument bytes, and expects at least 64/24 raw bytes for entry/
exit. The gate must also check sizes, signedness, supported byte order and raw
bounds, and require ID/format agreement and the exact perf sample envelope.
Matching offsets alone is insufficient. The configured runner already checks
field sizes; the new boundary check also verified signedness before opening.

Keep this first decoder explicitly scoped to its supported ABI. Do not interpret
the same syscall number as the same operation on a future ARM64 target. Successful
metadata reads still require a successful open/mmap/enable and valid records.

### 4. Define start failure before reusing "Did not start"

The memo's "leaves CPU sampling alone" has two possible meanings. Preserve the
CPU-only path and existing captures regardless of the eventual choice. For a
new request that explicitly asks for both components, choose one clear contract:

- **Recommended first version:** open requested components transactionally;
  if syscall setup fails, close the new resources, preserve the prior capture,
  and report failure. The user can explicitly retry CPU-only.
- A later configurable partial-start policy could return a successful capture
  with syscall status `unavailable` and an explicit reason. It must report what
  actually started, rather than an MCP error or a generic failed-start banner.

This is a proposed integration choice, not an adopted behavior. The existing
start path rejects a second active capture and preserves a completed capture on
failure; keep those lifecycle guarantees.

### 5. Permissions passing does not settle capacity or lifecycle

136 KiB is the two-ring cost **per selected TID** in this prototype. At 1,024
TIDs that would be 136 MiB and 2,048 perf descriptors before the CPU collector,
staging buffers and span storage. The delivered pairing model has only 32 slots.
Those constraints need an explicit admission budget; the successful one-thread
runs do not establish that CAP_IPC_LOCK/resource limits are irrelevant at scale.

The native probe waits for fixture completion before draining. Before wiring it
into xodb, test continuous/fair draining, split pairs across drains, ring loss,
bounded retained detail, cancellation and partial-open cleanup, and real thread
identity across exit/exec/reuse. Its start-time placeholder and timeout/reap
handling remain prototype limitations already recorded in the first review.
No larger limit, loss policy, archive layout or UI/MCP change is adopted here.

## New validation and evidence

**10/10 ReleaseSafe pairing tests and 6/6 build steps passed.** Three short
CPU/wait/copy traces then ran as ordinary user with `CapEff=0`, paranoid 1 and
existing tracefs settings. All decoded both rings, reported zero foreign spans,
loss and drops, emitted fixture completion and reaped/closed their resources.
The wait's longest read was 50.089 ms. This was a boundary-attribution check,
not a new overhead benchmark. No system settings or delivered probe sources
were changed; an isolated copy adds unknown-span logging and carries the prior
cleanup-check corrections.

To reproduce in a new scratch directory from the repository root, first verify
the original source hashes against the manifest above. Then:

## Recommended next step

A bounded collector prototype with continuous draining and the diagnostic
observations above, then a concrete integration proposal covering transactional
start, retention, selected-thread limits and GUI/MCP presentation. This review
supports the opt-in direction; it does not approve production workflow changes.

External LLM opportunity: explain the failed stage using actual errno, format,
credentials and target identity, and distinguish capture-boundary/termination
artifacts from loss. Neither an errno nor an unmatched syscall alone proves a
permission cause, a performance bottleneck or why a thread waited.
