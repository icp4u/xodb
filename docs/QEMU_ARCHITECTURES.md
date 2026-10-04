# QEMU Linux architecture tasks

Prepared 2026-10-02 at the user's request. SSH agent authentication and host
aliases are configured by the user. Availability/ABI below are user-reported;
Codex has not independently probed these guests in this dispatch.

## Dispatch

**2026-10-03:** Claude delivered T20–T23, Grok delivered T25/T26, and the user
assigned T24 to Claude. [Handoff review and corrective checklists](ARCHITECTURE_HANDOFF_REVIEW.md)
record the actual completion levels: RISC-V64/ARM32/PPC64LE have headless service
candidates; m68k has a toolchain-blocked metadata candidate; SPARC32/64 have
partial probes with remaining decoder/control work. Shared integration is pending.
[Current owners/status](AGENT_TASKS.md#qemu-architecture-dispatch-2026-10-02).

The packets below retain their original scope and ownership.

| Packet | SSH alias | Reported executable ABI | Particular integration pressure |
| --- | --- | --- | --- |
| [T20: RISC-V 64](tasks/T20-riscv64-target.md) | `riscv64` | ELF64, little endian; RVC, double-float ABI | Compressed instructions and software stepping |
| [T21: ARM 32](tasks/T21-arm32-target.md) | `arm32` | ELF32, little endian, EABI5 | 32-bit pointers and ARM/Thumb interworking |
| [T22: PowerPC 64 LE](tasks/T22-ppc64le-target.md) | `ppc64le` | ELF64, little endian, OpenPOWER ELFv2 | Register diversity and ELFv2 entry points |
| [T23: Motorola 68k](tasks/T23-m68k-target.md) | `m68k` | ELF32, big endian, 68020 | Big endian and variable instruction lengths |
| [T24: PA-RISC 32](tasks/T24-hppa-target.md) | `hppa` | ELF32, big endian, PA-RISC 1.1 | Instruction queues and toolchain support |
| [T25: SPARC V9 64](tasks/T25-sparc64-target.md) | `sparc64` | ELF64, big endian, SPARC V9, relaxed memory ordering | Register windows, delay slots and stack bias |
| [T26: SPARC 32 compat](tasks/T26-sparc32-target.md) | `sparc32` | ELF32, big endian, SPARC32PLUS; user reports a sparc64 kernel | Compat ABI on a 64-bit kernel |

Copy/paste, replacing the task filename:

> Claude: implement docs/tasks/T20-riscv64-target.md. Read the shared contract in
> docs/tasks/QEMU_TARGET_CONTRACT.md and the AGENTS instructions. Stay inside
> the packet's owned paths; shared production changes belong in a tested patch
> from your isolated scratch copy. Use the configured SSH alias and loaded
> agent. Deliver runnable owned-fixture tests, raw results, capability outcomes,
> and a headless xodb/MCP candidate wherever the toolchain permits. Coordinate
> shared integration with Codex. Back up existing files before changing them.

## Common ownership

Codex owns the target-neutral boundary and integration in production sources,
shared build scripts, CLI/MCP, ELF/DWARF, archives and UI. Each agent supplies a
tested candidate in its own paths. No packet edits `src/target/arch.zig`,
`src/target/linux.zig`, `build.zig`, this index or `docs/AGENT_TASKS.md` in the
shared checkout. Seven independent edits to those files would conflict and
could silently break other architectures.

The current production architecture enum supports x86-64 and AArch64. Other
important assumptions include a fixed register array, little-endian DWARF value
reads, 64-bit address-sized operations and host-native ptrace structures.
Changing only the enum or adding another `else` branch is insufficient.
The ongoing x86 work is recorded in [X86_FUNCTIONAL_PLAN.md](X86_FUNCTIONAL_PLAN.md).

The common acceptance checklist is [QEMU_TARGET_CONTRACT.md](tasks/QEMU_TARGET_CONTRACT.md).
Agents should read current source, since old T13 research predates several
integrations. First deliver the architecture facts and standalone control
harness; proceed to the full headless candidate without waiting for other
packets. Mark a toolchain/ABI blocker precisely and finish the remaining
independent work. A C harness alone is capability evidence, not xodb support.

## What QEMU proves

These are full Linux guest tests, not merely cross compilation. They can test
guest ptrace, loaders, signals and debugger behavior for the exposed CPU/ABI.
They do not establish native hardware timing, performance overhead, hardware
watchpoint capacity or PMU availability. Record unsupported emulated features
separately; do not stop the port because guest hardware profiling is absent.
Keep ELF class, byte order, ABI, instruction mode and kernel architecture
separate in the report—especially for `sparc32`.
