# T18: AArch64 sampled registers, captured stacks and offline unwinding

Status: delivered by Grok; reviewed by Codex (2026-10-01). Local tests/cross build
and host ARM64 CFI lookup reproduced. Two new adverse-input tests fail; native
sampled-stack acceptance and production integration remain pending.
See [review and required corrections](../T18_AARCH64_SAMPLING_REVIEW.md).

## Goal and ownership

Prepare the ARM64 counterpart of T10 without merging an unreviewed architecture
or archive migration. Own only:

- `tests/repros/aarch64-sampling/`
- `docs/research/aarch64-sampling.md`
- `docs/research/aarch64-sampling/`

Read T13's packet/handoff, `docs/M2_SAMPLED_UNWIND.md`, the production perf decoder,
sampled-state store, unwinder, ELF/debug-info adapter and archive format. Record
base commit and hashes; deliver a patch tested in your own scratch copy. Do not
edit T13, T10, shared production files, build outputs or another agent's packet.

## T13 review corrections to carry forward

Read [the coordinator's T13 review](../T13_AARCH64_REVIEW.md). Keep T13's original
sources/transcript unchanged; corrected helpers and tests belong in this task's
owned paths. Do not treat the reported native run as validation of changed code.

- Replace T13's `read(perf_fd)` sample decoder with the production-style mapped
  ring path. Validate head/tail ordering, wrap, bounds and loss using synthetic
  records before native work. Permission/unsupported/empty are distinct outcomes;
  none counts as a captured sample.
- Test runner failure propagation with an intentionally failing mode; aggregate
  errors and list capability skips separately. Authorized remote staging must
  use a new run directory or back up anything it replaces.
- Bound owned-child cleanup, retry EINTR, preserve ownership until reaped or
  explicitly gone, and report failures. Test partial setup/tracer failure.
- Preserve failed/short memory reads as unavailable. Include target address zero
  without a Zig null-pointer panic, and reject oversized returned register data.
- Do not infer general watchpoint semantics from the aligned eight-byte fixture.
  Only copy watch helpers if this task needs them, and then fix read validity.
- Separate CIE return column (normally LR=30) from current PC=32; test raw PC,
  call-site attribution and CFI/mapping lookup independently. A descriptor's
  known encoding must not advertise an implemented backend capability.

The report's missing Jetson development packages do not block host-side
experiments on cross-built ARM64 ELF with installed workstation libdw. Investigate
that path in the isolated harness; record any actual limitation. Keep production
ELF/archive rejection intact until all relevant consumers are adapted.

## Required slice

1. Specify an explicit architecture/ABI adapter for perf register masks and
   ordering, PC/SP access, DWARF register identities, ELF machine checks and
   return-address lookup. Preserve raw identities and unknown fields. Use
   primary Linux UAPI and toolchain documentation; cite version assumptions.
2. Add local synthetic decoder/unwind cases for missing/short register sets,
   ABI absence, partial captured stacks, byte budgets, endianness/machine mismatch,
   mapping boundaries/history and cancellation. Target addresses must never
   become host dereferences or trigger late process-memory reads.
3. Explore pointer authentication/tagged return addresses and signal boundaries.
   Unsupported states terminate explicitly. Do not strip bits or claim a caller
   is trustworthy without a justified architecture rule and tests. Preserve both
   raw and adjusted addresses in any proposed result.
4. When the user-authorized host is ready, run an owned native recursion fixture
   with and without frame pointers. Compare raw perf evidence, standalone derived
   frames and an available debugger. Record CPU/kernel/page size, compiler/libdw
   versions, loss, stack coverage, timing, fd cleanup and failure behavior.
5. Propose the smallest archive extension/migration that keeps old x86 captures
   readable and rejects unknown required evidence. Preserve byte-identical copy,
   raw-versus-derived separation and the no-fsync publication policy. Do not
   silently reinterpret the current format's x86 machine tag or fixed GPR set.

## Host and handoff rules

T13's host coordination applies: no maintenance, package installation, firmware,
policy changes or existing user targets. Reconfirm readiness with the maintenance
owner; keep authorized remote scratch in a dedicated ~/Work workdir. Finish local
work if native access is unavailable and label cross/emulated/native evidence.
The incoming M1 runs Linux; it is not a macOS backend task.

Deliver the adapter proposal, isolated code/tests, logs, limits, reproduction
commands and a short critical review before choices requiring user approval.
ARM64 production support is not complete merely because the prototype runs.
Note where an external agent could compare architecture-specific failure evidence
without replacing ABI checks with inference.
