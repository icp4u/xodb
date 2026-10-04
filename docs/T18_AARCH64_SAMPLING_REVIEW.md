# T18 AArch64 sampled-state review

Codex review, 2026-10-01. [Grok's delivered report](research/aarch64-sampling.md)
is based on `363741a`; production integration is pending.

## Critical assessment

The packet improves the T13 research foundation: it supplies a mapped-ring probe,
explicit register masks, bounded cleanup helpers, failure aggregation and a host
libdw check against an ARM64 ELF. I reproduced its 32 passing test executions
(18 distinct tests, with imports repeated), the ARM64 probe cross build and the
host libdw result: machine 183, an `.eh_frame` range with return column 30.
Grok's Jetson transcript still reports perf permission denial, so native sampled
registers/stacks and an actual captured-stack unwind remain unverified.

Two added adversarial cases fail: an unavailable LR produces a falsely complete
stack, and a header-only sample is counted as decoded. The walker uses synthetic
rules rather than a libdw CFI evaluator; the archive check is a miniature codec,
not compatibility testing against production files. The adapter is useful design
input, but neither the full workflow nor the proposed format bump is ready to
adopt unchanged. Production remains x86-only.

## Required changes before integration

1. **Register availability must survive every frame.** `walk.zig` checks PC/SP
   presence but reads LR directly from a zero-initialized array. A mask without
   LR therefore reports `complete`. It also zeroes LR after a step without
   marking it unavailable, so later LR rules can make the same false claim.
   Track register validity per frame, apply actual CFI register rules and stop
   with `registers_unavailable` when the return column cannot be recovered.
2. **Framing is not payload decoding.** `ring.drain` increments `samples` for
   any type-9 record, including a header-only record. `capturedSample` then calls
   it decoded. The native probe does not invoke `decode.zig` and retains only
   a 64-byte body prefix; its requested IP + registers + 64-byte stack record
   can exceed that. Wire a complete bounded record through the real decoder
   before reporting decoded evidence. Keep malformed/partial/lost distinct.
   Check enable/disable ioctl failures and report their actual errno.
3. **Preserve registers on stack-budget exhaustion.** `decode` currently returns
   `error.Budget`, losing the decoded register result. Production T10 keeps those
   registers and the CPU sample with a missing-stack status. ARM64 must preserve
   that approved behavior, including across later drain batches.
4. **Keep address assumptions explicit.** The adapter has fixed default VA widths
   and one return adjustment shared by call-site and CFI lookup. Obtain justified
   capture metadata and test each consumer; do not silently apply new address
   rejection rules to current x86 captures. No PAC/tag stripping is validated.
5. **Archive proposal requires a production-format experiment.** The toy schema
   checks machine/count/mask relationships but cannot prove old 2.2 x86 archives
   still reopen, copied bytes remain identical, or unknown required evidence is
   rejected by existing readers. Add those tests against the actual codec before
   requesting approval for a version/required-bit change. Register width, byte
   order, ABI and address assumptions need one consistent interpretation.

The cleanup helper and integer-window tests address parts of T13's review. Their
presence does not prove debugger lifecycle cleanup: the native perf child is
untraced, and the fake wait outcomes do not cover a ptrace stop preceding exit.
Use the production target lifecycle rules when building that backend.

## Reproduced evidence

Fresh copied sources and isolated caches:
`.work/t18-review-20261001T121407979537/`.

- `zig build test -Doptimize=ReleaseSafe -j2 --summary all`: 32/32 pass.
- `zig build probe -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu.2.27 -j2
  --summary all`: 3/3 steps pass (cross build only).
- `sh libdw.sh`: libdw 0.196 reads ARM64 `.eh_frame` at `recur`, column 30;
  `.debug_frame` has no matching range at that address. This proves CFI lookup,
  not saved-state evaluation or native sampling.
- Added `review_test.zig`: **12 imported tests pass, 2 new cases fail**.
  `missing LR cannot prove the caller chain ended` expects unavailable and gets
  complete; `header-only sample is not decoded sampled state` rejects the
  prototype's decoded classification. See `adversarial.log`.

No remote run, package/policy change or production ARM64 change was made during
this review. Grok's original artifacts and transcript remain unchanged. Follow-up
work should correct the evidence boundary before expanding the feature set.

External LLM opportunity: compare denied, malformed, partial and decoded outcomes
using the raw mask, ABI and byte lengths. Unknown registers are not zero values;
a model must not describe a synthetic-rule walk as an observed native backtrace.
