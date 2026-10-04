# T21: ARM 32 Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first ARM 32 debugger slice on SSH alias **`arm32`**.
The user reports **ELF32, little endian, EABI5**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-arm32/`
- `docs/research/qemu-arm32.md`
- `docs/research/qemu-arm32/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Identify the guest's float ABI, architecture level, ARM/Thumb support and actual user/kernel ABI. Inspect CPSR, PC, SP and LR and the effect of tagged code addresses.
- Test ARM and Thumb code separately, including 16-bit and 32-bit Thumb instructions and interworking calls/returns. Verify breakpoint width, alignment, PC normalization and restored neighboring bytes.
- Verify single-step behavior in each instruction set, including conditional execution/IT blocks. Where software stepping is needed, document and test the supported subset explicitly.
- Test 32-bit address/word handling, hard-float arguments when present, and DWARF CFI. Identify binaries using ARM EHABI rather than DWARF; missing EHABI unwind support must be reported accurately.

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

