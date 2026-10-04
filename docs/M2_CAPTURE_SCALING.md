# Compact capture storage (T15 integration)

Integrated 2026-10-01, adapting [Claude's T15 handoff](research/capture-scaling.md)
to the production T10/T14 model at `363741a`.

The user-approved [configurable-ceiling follow-up](M2_CAPTURE_LIMITS_PROPOSAL.md)
is integrated as of 2026-10-02. The measurements below describe the original
16,384-sample storage integration.

## Scope and critical assessment

Retained samples now use 56-byte cores in fixed chunks and share identical raw
callchains. Sample ordinals, frame order, recursion, presence flags and saved-stack
references retain their meanings. Core-only queries avoid expanding callchains;
flame building expands selected samples after filtering. No eviction or disk
spool is introduced. Archive 2.2, MCP output, UI interactions, the 16,384 sample
cap and capture defaults are unchanged.

This removes a large memory cost, but hashing/exact comparison makes append work
more expensive and does not accelerate full graph construction. Increasing the
sample count still requires responsive background views, archive-limit handling,
and measured game/server overhead. T15's proposed larger defaults remain for
review after that work; they were not adopted as part of this internal change.

## Corrections during integration

- The prototype dropped a nonzero address on a marker with raw value zero, or a
  nonzero raw marker on a non-marker with address zero. The wide-item encoding now
  preserves both fields whenever the normally unselected field is nonzero.
- Formula-based hash-table accounting omitted allocator-visible header/alignment
  costs. Store allocations now pass through the existing budget allocator, which
  observes actual requests, growth and frees. Partial allocation failures retain
  valid prior samples and correctly account for any reserved capacity.
- The compact store has a separate 32 MiB ceiling. A maximum-count fixture with
  64 distinct wide items per sample uses 19,564,120 bytes, below that ceiling;
  ordinary data reaches the existing count cap first. This bounds allocation
  requests, not process RSS or allocator/kernel overhead.
- A sample is admitted before copying its T10 state. Refused samples cannot leave
  orphan register/stack entries. After the first storage refusal, later drains
  count discards instead of admitting cheaper records after a gap. Stack-byte
  exhaustion continues to retain CPU samples and registers with explicit gaps.
- Updated live/offline captures, USTA validation/encoding/decoding, MCP samples and
  coverage, the unwind worker, timeline and capture controls to use stable ordinals.
  The anonymous MAPS-record fix from the handoff was already in production.

## Measurements and validation

Same synthetic input, 16,384 samples, ReleaseSafe on this workstation. Three view
rebuilds per shape; graph times below are medians. Sample bytes include storage
capacity; MB is decimal. Append time is one measured ingestion per process.

| Shape | Previous sample bytes | Compact sample bytes | Append ns/sample, before → after | Full graph ms, before → after |
| --- | ---: | ---: | ---: | ---: |
| Repeated | 33,549,808 | 1,065,976 | 597 → 859 | 51 → 54 |
| Recursive | 33,549,808 | 1,065,472 | 666 → 1,519 | 91 → 97 |
| Diverse | 33,549,808 | 6,013,528 | 1,037 → 1,544 | 30 → 32 |
| Unique deep stacks | 33,549,808 | 11,175,000 | 926 → 1,873 | 50 → 50 |

All four shapes produced identical full/filtered flame and CPU-bin digests,
archive lengths and archive SHA-256 hashes against the previous implementation.
This measures storage/view behavior; it is not a production-game overhead claim.

- **145/145 tests, 24/24 build steps**, ReleaseSafe, including every injected
  allocation failure through the next core chunk, exact allocation accounting,
  maximum unique wide chains and T10 admission/refusal across drains.
- The largest archive fixture remains 102,132,158 bytes, with a decoded allocation
  peak of **209,700,876 bytes** (previously 232,302,100). Its encode/decode+graph
  times were 411/419 ms; these budgets exclude the caller's existing capture and
  libdw internal allocations.
- Seven owned GCC/Clang live cases passed with/without frame pointers, short
  stacks and exhausted/zero budgets: raw sample inspection, 18-frame recursive
  reconstruction, exact filtered coverage, archive save/reopen/copy, matching
  assets and offline syscall isolation.
- Private headless Sway passed setup/thread selection, active/next distinction,
  capture stop, 640x480 controls and owned-target cleanup.

Logs: `.work/t15-integration-20261001T120802845077/` (`test-1.log`, `live.log`,
`gui.log`, and `bench/results.json`). Benchmark input is the delivered
`tests/repros/capture-scaling/bench.zig`, run against isolated `363741a` and
integration source copies with an additional archive hash comparison. Each
invocation used `SHAPE 16384 3`. Live artifacts are in
`.work/m2-sampled-20261001T121301336781/`; GUI evidence is in
`.work/input-capture-20261001T121454095302/`.

## Adapter notes for T16 and later work

`Capture.samples` is now `sample_store.Store`: use `len()`, `core(ordinal)` for
metadata, and `get(ordinal)` for a complete temporary sample. Core presence is
queried with `timePresent()` / `tidPresent()`. `coreMut()` is for metadata fixup;
`swap()` is used only by fixtures. Never retain a pointer into a temporary expanded
sample. Raw T10 bytes remain in the separate capture-owned `user_state` store.

External-agent opportunity: compare sampled hot paths across saved captures while
citing stable raw ordinals and coverage. Smaller storage does not extend the
observed time window; capacity stop and lost samples still limit conclusions.
