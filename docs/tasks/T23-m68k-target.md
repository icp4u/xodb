# T23: Motorola 68k Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first Motorola 68k debugger slice on SSH alias **`m68k`**.
The user reports **ELF32, big endian, 68020**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-m68k/`
- `docs/research/qemu-m68k.md`
- `docs/research/qemu-m68k/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Determine the exposed CPU and Linux ABI. Map data/address registers, PC, status register and regset/legacy ptrace interfaces with byte-accurate evidence.
- Test big-endian ELF32 and DWARF values, 32-bit pointers and the actual ptrace word size. A build that swaps instruction bytes incorrectly must fail a fixture before any live patch.
- Verify a suitable software trap, its stopped-PC semantics and single-step across variable-length instructions, calls and returns. Restore all neighboring bytes and preserve application-generated traps/signals.
- Establish Zig/LLVM/backend/linker feasibility early. If full Zig execution is unavailable, deliver a native C ABI/ptrace harness and a precise build blocker plus host-side parser tests; do not replace the existing debugger with an unrelated implementation.

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

