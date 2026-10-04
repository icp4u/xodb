# T24: PA-RISC 32 Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first PA-RISC 32 debugger slice on SSH alias **`hppa`**.
The user reports **ELF32, big endian, PA-RISC 1.1**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-hppa/`
- `docs/research/qemu-hppa.md`
- `docs/research/qemu-hppa/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Confirm kernel/user bitness and ABI. Investigate register layout, instruction-address queues, privilege/address bits and how a breakpoint resumes correctly.
- Investigate delayed control transfer and nullification. A single PC and a universal return-address subtraction may be insufficient; provide a minimal explicit representation and tests.
- Verify trap choice, instruction patching/cache coherency, single-step, calls and returns with an owned fixture. Test signal delivery and fault stops rather than equating every SIGTRAP with our breakpoint.
- Establish compiler/Zig/LLVM and disassembler support first. Deliver a native C harness if Zig cannot target this ABI. Investigate stack direction, unwind representation and function-pointer conventions from current ABI/kernel sources; demonstrate actual CFI availability rather than assuming it.

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

