# T25: SPARC V9 64 Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first SPARC V9 64 debugger slice on SSH alias **`sparc64`**.
The user reports **ELF64, big endian, SPARC V9, relaxed memory ordering**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-sparc64/`
- `docs/research/qemu-sparc64.md`
- `docs/research/qemu-sparc64/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Identify the actual register-window representation, PC and next-PC, SP/stack bias and ptrace interfaces. Preserve both control-flow registers when testing mutation.
- Test a software trap and single-step at ordinary instructions, branches with delay slots, calls and returns, including annulled branches where supported. Record whether the trap PC is advanced or unchanged.
- Validate stack-window saves/spills and CFI across several recursive calls; distinguish architectural registers from memory-backed window state. Include a signal stop and return path.
- Confirm build and Capstone feasibility. Keep this task's ABI/register/ELF work independent of T26: the 32-bit guest is a separate user ABI even if both kernels report sparc64.

## Concrete delivery

1. Capture current guest/toolchain facts and the capability ledger.
2. Build/run the ABI and ptrace harness with verified cleanup, including the
   target-specific experiments above. Save byte-level trap/register evidence.
3. Implement the architecture candidate in your isolated xodb snapshot and run
   headless MCP plus source/locals/unwind fixtures wherever the toolchain allows.
4. Deliver the reviewed integration patch, reproducible commands and report.
   For a toolchain blocker, finish the independent harness/parser work and give
   the exact smallest next change. Separate optional capability gaps from
   failures of core debug control.

