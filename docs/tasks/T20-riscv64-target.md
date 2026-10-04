# T20: RISC-V 64 Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first RISC-V 64 debugger slice on SSH alias **`riscv64`**.
The user reports **ELF64, little endian; RVC, double-float ABI**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-riscv64/`
- `docs/research/qemu-riscv64.md`
- `docs/research/qemu-riscv64/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Determine the actual ISA extensions, ABI and regset sizes. Verify DWARF register numbering, PC, SP, return address and preserved registers.
- Exercise both compressed and full-width instructions. Determine correct breakpoint width/alignment and stopped-PC behavior at each; preserve adjacent instructions and instruction-cache coherency.
- Check the kernel's single-step support empirically. If unavailable, implement and test a bounded software-step candidate covering conditional branches, direct/indirect jumps, compressed control flow and atomic sequences; report cases it cannot safely step.
- Confirm Capstone's installed RISC-V support and cross/native Zig build viability. Test CFI across leaf and non-leaf functions, including compressed return sites. Do not apply the ARM64 fixed caller-PC subtraction.

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

