# T26: SPARC 32 compat Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first SPARC 32 compat debugger slice on SSH alias **`sparc32`**.
The user reports **ELF32, big endian, SPARC32PLUS; user reports a sparc64 kernel**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-sparc32/`
- `docs/research/qemu-sparc32.md`
- `docs/research/qemu-sparc32/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Verify user-space, tracer and tracee word sizes independently of uname. Establish whether this is a 32-bit userspace on a 64-bit kernel, and record compat ptrace structures, note layouts and syscall conventions.
- Map register windows, PC/next-PC and stack/frame addressing for this ABI. Do not reuse the SPARC64 stack bias or register layout without evidence.
- Test traps, instruction restoration, delay slots, annulled branches, stepping and signal delivery with a 32-bit tracer and tracee. A future 64-bit tracer of a 32-bit target is a separate compatibility matrix entry, not required for this packet.
- Prove ELF32/big-endian DWARF, pointer loads and CFI on guest-generated fixtures. Investigate toolchain/Capstone gaps and coordinate findings with T25 through documents, without editing its files.

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

