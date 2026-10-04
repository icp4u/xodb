# T22: PowerPC 64 LE Linux target

Status: ready for user assignment to Claude (2026-10-02).

## Goal and host

Build and validate the first PowerPC 64 LE debugger slice on SSH alias **`ppc64le`**.
The user reports **ELF64, little endian, OpenPOWER ELFv2**. Reconfirm this in the guest; do not use kernel
architecture alone to select the userspace ABI.

Own only:

- `tests/repros/qemu-ppc64le/`
- `docs/research/qemu-ppc64le.md`
- `docs/research/qemu-ppc64le/`

The complete required workflow, permissions, tests and handoff are in
[QEMU_TARGET_CONTRACT.md](QEMU_TARGET_CONTRACT.md). Read it before starting.
Shared production edits are a tested patch in your evidence directory, from an
isolated snapshot; Codex owns applying them. Keep separate scratch/build caches.

## Architecture-specific questions and experiments

- Confirm ELFv2 and the actual CPU features. Map GPRs, PC/NIP, LR, CTR, CR, XER and floating/vector regsets without assuming x86/AArch64 names or counts.
- Distinguish global/local function entry points and TOC handling when resolving a function breakpoint. Verify symbol addresses against the loaded ELF and actual control flow.
- Test trap bytes, stopped PC, single-step, branch/return and instruction-cache coherency. Investigate prefixed instructions only if supported by the exposed CPU/toolchain; do not blindly assume every instruction is four bytes.
- Test CFI across optimized and non-optimized functions, LR save/restore and leaf frames. Report hardware watchpoint and perf support of this QEMU CPU separately from the Linux architecture's API.

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

