# T13: AArch64 target boundary and native debugger prototype

Status: delivered by Grok and reviewed by Codex (2026-10-01). Local tests and
cross build reproduced; native evidence comes from Grok's Jetson transcript.
See [review and required corrections](../T13_AARCH64_REVIEW.md). Production
integration remains pending; [T18](T18-aarch64-sampled-state.md) is ready next.

Original dispatch: suggested owner Grok after the Jetson maintenance
handoff; local research and prototype work can start before the host is ready.

## Goal and ownership

Prepare the first Linux AArch64 debugger backend for the Omarchy portability
goal. Deliver a small executable prototype, an architecture-boundary proposal,
and evidence that clearly separates local checks from native ARM64 results.

Own only:

- `tests/repros/aarch64/`
- `docs/research/aarch64.md`
- `docs/research/aarch64/`

Read `docs/MILESTONES.md`, `docs/AGENT_TASKS.md`, `docs/M1.md`,
`src/target/linux.zig`, `src/target/breakpoints.zig`, `src/debug/location.zig`,
`src/debug/info.zig`, `src/model/disassembly.zig`, `src/binary/elf.zig`,
`src/profile/records.zig`, `docs/M2_ARCHIVE_FORMAT.md` and `build.zig`.
Keep production, shared documentation, build files and T10 artifacts unchanged.
Place proposed shared-file changes in your research directory as a patch against
a recorded base commit, tested in a fresh scratch copy within your owned paths.

## Host coordination

Prepare a read-only capability collector and a separate, explicitly invoked
owned-fixture runner. Remote deployment/execution must follow the user's host
authorization and remote AGENTS instructions; coordinate readiness with the
maintenance owner. Keep any authorized remote scratch files in a dedicated
`~/Work` workdir. Do not modify system configuration or use existing user targets.
If native runs are unavailable, finish the local prototype and label the native
gate pending. The incoming M1 will run Omarchy Linux; it is not available yet.

## Required first slice

1. Inventory current x86 assumptions by file and symbol: register fields and
   DWARF numbering, trap bytes/PC handling, debug registers, stepping, ELF machine
   validation, disassembly/IR, perf register masks, callchain lookup and archive
   machine tags. Distinguish changes needed for a minimal native target from
   later GUI, expression, profiling and archive support.
2. Propose a small typed architecture interface: target architecture/ABI,
   pointer width and byte order, register identity plus PC/SP access, software
   breakpoint bytes and stop-PC normalization, and supported debug features.
   Keep raw register identities available; avoid host-pointer assumptions.
   Codex owns adopting this interface and converting the existing x86 backend.
3. Build a standalone Zig-first ptrace harness for an owned ARM64 child: launch,
   stop, read general registers and memory, insert/remove a software breakpoint,
   recognize its stop, step over it, resume and cleanly reap. Investigate the
   relevant GETREGSET/SETREGSET, signal-info and instruction-cache contracts using
   Linux UAPI/kernel sources. Preserve surrounding instruction bytes and signal
   delivery. Exercise malformed/short register data in local tests.
4. Add bounded timeouts and cleanup on partial failure. Distinguish unsupported
   features, permission errors and target disappearance. Never run a destructive
   register-write experiment against a user process. Use a narrow C fixture or
   ABI checker where useful; document copied code and licenses.

## Capability checks and follow-up boundary

Record OS/kernel, CPU, page size, libc/compiler/Zig availability, resource limits
and readable ptrace/perf policy. Check available build dependencies without
installing them. Keep graphics probing separate from the headless target harness.
The current build links graphical libraries even for `--headless`; propose a
small independent harness build instead of assuming that flag removes them.

After the core slice, investigate hardware breakpoint/watchpoint capability
discovery, one write-watchpoint fixture, AArch64 CFI/register mapping with libdw,
and a minimal task-scoped CPU sample. Deliver bounded probes or an ordered plan
with explicit unsupported/pending outcomes; do not expand into a full profiler,
remote daemon, SVE implementation or production archive migration. Preserve T10's
separation between captured registers/stacks and reconstructed callers.

## Acceptance and handoff

- Local parser/architecture tests and a reproducible build command for the
  harness. A cross-compile or emulator run is labeled as such, never native proof.
- When authorized and available, a native transcript showing register/memory
  reads, breakpoint hit/restoration, stepping, exit and failure cleanup; record
  exact kernel/tool versions and compare with GDB only if already available.
- A file/symbol migration map, proposed interface and tested patch, capability
  report, primary-source references, limits, and next production integration step.
- Native acceptance can remain pending while the local handoff is delivered.
  Never describe ARM64 xodb support as complete based on the standalone harness.

Follow the common coordination/handoff rules in `docs/AGENT_TASKS.md`: back up
existing files, isolate caches, and keep GUI tests private. Record where
external agents could help compare ISA-specific results while grounding
conclusions in the fixtures and observed capabilities.
