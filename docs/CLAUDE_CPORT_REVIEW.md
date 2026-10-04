# Claude review: observations for the C port

Claude (Opus 5.5), 2026-10-03. This consolidates what the QEMU architecture
packets measured and what they imply for porting xodb from Zig to C. The port
is deferred until the Zig cleanup is done. Sources and raw evidence are in the
packet reports:

- [T20 RISC-V 64](research/qemu-riscv64.md)
- [T21 ARM 32](research/qemu-arm32.md)
- [T22 PowerPC 64 LE](research/qemu-ppc64le.md)
- [T23 m68k](research/qemu-m68k.md)
- [T24 PA-RISC](research/qemu-hppa.md)
- the [T20–T23 integration stack](research/qemu-riscv64/stack/README.md)
- Codex's [handoff review](ARCHITECTURE_HANDOFF_REVIEW.md)

Facts are from QEMU guests; physical hardware is unverified unless stated.

A scoped alternative to a full C port, which keeps Zig for the application
and moves only a shared target runtime into C, is in
[CLAUDE_C_RUNTIME_SCOPE.md](CLAUDE_C_RUNTIME_SCOPE.md).

## 1. Why C helps

| Target | Zig 0.16 status | C status |
| --- | --- | --- |
| x86-64, AArch64 | native, integrated | GCC/Clang |
| RISC-V 64, PPC64 LE, ARM 32 | cross-builds; headless xodb passes MCP on the guests | GCC on each guest |
| m68k | **blocked**: no LLVM build ships the experimental M68k backend; Zig also aligns 4/8-byte scalars to 4/8 while the m68k C ABI aligns every scalar to 2 (a 48-byte vs 32-byte `extern struct`) | guest GCC 16.2; its C harness ran 139 hardware steps |
| PA-RISC 32 | **blocked**: no LLVM PA-RISC backend; the C backend compiles library code with a *correct* layout, but `std.os.linux`/`start.zig` lack hppa | guest GCC 16.2; C harness captured registers, queue, traps |

In C, the target's struct layout is right by construction. You lose Zig's
compile-time exhaustiveness and safety checks, so the port must deliberately
replace them (section 2.11).

## 2. Design rules the C port must keep

These were each learned from a real failure or near miss.

### 2.1 Describe the target from the image, never from the host

Byte order, address width and ELF class come from the image (`e_ident`,
`e_machine`, `e_flags`), never from the kernel or the host. Accept each
machine in exactly one class and byte order: `EM_PPC64` big-endian is
`UnsupportedEncoding`, not a guess. T23's layout table (`Layout.of(machine)`)
is the model.

- Decode target bytes explicitly, with the target's byte order. Never cast a
  buffer to a host struct.
- `PTRACE_GETREGSET` **silently truncates** to the caller's length, so require
  the exact regset size:

  | Arch | Regset size |
  | --- | --- |
  | RISC-V | 256 |
  | ARM | 72 |
  | PPC | 384 |
  | hppa | 320 |
  | m68k | none: `GETREGS`, 76 bytes |

- Keep target values 64-bit everywhere. Narrow only at the ptrace, iovec and
  index boundaries, and **refuse** a value that does not fit (T21's
  `RegisterValueOutOfRange`; the stack's `processes.zig` index fix). Never
  truncate silently.
- Synthesized pointer types (`&x`, array→pointer) must use the **target**
  address width (Codex finding 4).

### 2.2 Register slots are not DWARF numbers

Keep two inverse maps per architecture: `slot → DWARF column` and
`DWARF column → slot`. A test should assert they are inverse.

| Arch | Pitfall |
| --- | --- |
| RISC-V | pc has no DWARF number; 32–63 are f0–f31. Reusing an identity map would read f0 as pc. |
| PPC64 LE | LR is **65** in `.debug_info` *and* CFI (measured on GCC 14); CTR 66, XER 76, CR fields 68–75; pc none. GDB's SysV reading of 108/109 as LR/CTR is wrong here, since 108 is VR31. |
| ARM 32 | r0–r15 = 0–15, d0–d31 = 256–287, CPSR none; CIE return column 14 (lr). |
| m68k | d0–d7 = 0–7, a0–a7 = 8–15, fp0–fp7 = 16–23; **return column 24 maps to the pc slot**. |
| hppa | **Two numbering spaces disagree above 31**: `.debug_info` puts fr4L..fr31R at 72..127, CFI at 32..87 with sar at 88. Map only r0–r31 until both are handled. CIE return column 2 (rp). |

### 2.3 Breakpoint traps and stopped-pc rules

| Arch | Trap | Alignment | Reported pc |
| --- | --- | --- | --- |
| x86-64 | `cc` | 1 | trap + 1, so subtract 1 |
| AArch64 | `BRK` | 4 | at the trap |
| RISC-V | `c.ebreak` `02 90` (needs hart C/Zca; `ebreak` for RV64G) | 2 | at the trap |
| PPC64 LE | `tw 31,0,0` `08 00 e0 7f` | 4 | at the trap |
| ARM 32 | per instruction set **and** width: ARM `e7f001f0`, Thumb `de01`, Thumb-2 `f7f0 a000` | 4 / 2 | at the trap |
| m68k | `trap #15` `4e 4f` | 2 | **trap + 2**, so subtract 2 |
| hppa | `break 4,8` `00010004` | 4 | at the trap (queue front) |

The trap is a property of each breakpoint (ARM), not of the architecture.
Store the planted bytes and the kind per breakpoint, and restore exactly that
many bytes.

Traps to avoid:

- ARM `bkpt` from user space spins and raises no signal.
- m68k `bkpt` and `illegal` raise SIGILL.
- A 4-byte RISC-V `ebreak` at an address ≡ 6 mod 8 needs two POKETEXT
  writes; `c.ebreak` never straddles a word.

An application's own trap is distinguishable from a probe **only** by the
debugger's probe table: no probe at pc means forward the signal.
`raise(SIGTRAP)` is `SI_TKILL`.

### 2.4 Single-step availability and the software-step contract

| Arch | Hardware step | Notes |
| --- | --- | --- |
| x86-64, AArch64 | yes | — |
| PPC64 LE | yes (MSR_SE; `SINGLEBLOCK` too) | **plan traps** for `sc`/`scv` (the report lands after the *next* instruction), `rt_sigreturn`, and `lwarx..stwcx.` |
| m68k | yes (SR.T1) | `SINGLEBLOCK` accepted but never stops under QEMU |
| RISC-V | **no** (`EIO`) | software |
| ARM 32 | **no** (`EIO`) | software |
| hppa | accepted, **never traps under QEMU 11.1** (no recovery-counter trap) | software |

Make the choice per instruction (T22's `softwareStepTargets → null` means
"use hardware"). A software step must:

- Compute **exact** successors from the stopped registers, including branch
  conditions. Planting at both branch arms doubles the traps and breaks
  self-loops. ARM IT blocks are the exception: plant at every remaining slot,
  because whether a condition-failed slot's trap fires is implementation
  defined (QEMU skips it).
- Treat a patched user probe at a successor as a completion target. Don't
  plant a second trap there.
- **Step load-reserved/store-conditional sequences as one unit.** The kernel
  clears the reservation on every trap return, and naive stepping failed the
  store **8/8** on RISC-V, ARM and PPC. Do a bounded forward scan (16
  instructions) from the load to the store, plant after the store and at
  forward exits, and refuse anything else (`AtomicSequenceUnsupported`).
- Handle signal returns by reading the saved pc from the frame:

  | Arch | Saved pc |
  | --- | --- |
  | RISC-V | `sp + 304` |
  | PPC | `r1 + 488` |
  | ARM `rt_sigreturn` | `sp + 220` |
  | ARM `sigreturn` | `sp + 92` |
  | m68k | `uc_mcontext.gregs[R_PC]` (trampoline on the stack) |

- **Refuse fork-like clones** (`clone`/`clone3` without `CLONE_THREAD`,
  `fork`, `vfork`): an untraced child inherits the temporary trap. glibc
  `pthread_create` uses `CLONE_THREAD`, so threads are fine. The same hazard
  exists for any probe when following forks is off.
- **Refuse self-branches.** A trap at pc fires before the instruction runs.
- Handle hppa delay slots and nullification. **Never plant in the delay slot
  of the gateway syscall `ble 0x100(%sr2,%r0)`**: T24 wedged the guest's
  syscall entry and sshd that way. Step the gateway as a unit to its return.

### 2.5 Signals and steps

- At a signal-delivery stop during an interrupted syscall, the kernel has
  **already rewound pc to the syscall instruction** and restored the first
  argument register. This is true on RISC-V, ARM and hppa (where r28 can hold
  a pending `-ERESTART*` value).
- **Software step:** forwarding the signal runs the handler *inside* the step,
  and the planted successor still completes it. A hardware step stops at the
  handler's first instruction. The user-visible semantics differ, so document
  them.
- **Hardware step that delivers a signal:** the next report is the kernel's
  `ptrace_notify` SIGTRAP (si_code 5 = SIGTRAP, si_pid = the task). This is
  the step's completion, **not** a SIGTRAP to forward (T22; x86 too).
- **m68k:** a step over `trap #0` or into a handler completes with
  `SI_KERNEL`. **Never forward it**: if the step forwarded SIGTRAP itself,
  the stop arrives after the handler, and forwarding would run it twice.

### 2.6 Caller lookup

The lookup pc for a caller frame must lie *inside* the call instruction:

| Arch | Rule | Why |
| --- | --- | --- |
| x86-64 | `ret − 1` | |
| AArch64 | `ret − 4` | |
| RISC-V | `ret − 1` | calls are 2 bytes (`c.jalr`) or 4 |
| ARM 32 | `(ret & ~1) − 1` | bit 0 is the caller's Thumb state; `BLX Rm` is 2 bytes |
| PPC64 LE | `ret − 4` | every call is one word |
| m68k | `ret − 1` | calls are 2–10 bytes |
| hppa | `(ret & ~3) − 4` | rp points past the delay slot and carries privilege bits |

Never use ARM64's universal `− 4`.

### 2.7 Writing registers

| Arch | Hazard |
| --- | --- |
| hppa | **`SETREGS`/`SETREGSET`/`SETFPREGS` corrupt registers**: register *k* receives element *2k*, from a kernel `__get_user` double evaluation (mainline 89f686a0fb6e). Write with `PTRACE_POKEUSER` one field at a time. Setting pc means writing **both** queue entries, with privilege 3 in the low bits. At an in-syscall stop, iaoq is stale and the task resumes through **r31**. |
| PPC64 LE | `gpr_set` masks `msr` to debug bits and `trap` (0xc01 → 0xc00), and ignores `dar`/`softe`. Treat msr, orig_r3 and trap as read-only. |
| m68k | `SETREGS` keeps only the CCR bits of SR. No `GETREGSET` at all, and `GET_SYSCALL_INFO` is `EIO`. |
| ARM 32 | A CPSR mode change is refused with `EINVAL`. |
| RISC-V | x0 is read-only (always 0). |

Re-read after every write and compare. Treat an unexpected difference as a
failure, not success.

### 2.8 Memory and code patching

- A ptrace word is the native `long`: **4 bytes on 32-bit targets**, in the
  target's byte order. Patch by read-modify-write of each word the patch
  touches; a patch can straddle two words.
- `PEEKDATA`/`POKETEXT` use FOLL_FORCE: they read a mapped `PROT_NONE` page
  that `process_vm_readv` refuses. Read memory with `process_vm_readv`, and
  patch code with POKETEXT.
- Under QEMU TCG, repatched code was always observed (the translated block is
  invalidated). The kernel's icache maintenance on physical hardware is
  **unverified** on every port.

### 2.9 Unwinding

| Arch | CFI through libdw | Fallback needed |
| --- | --- | --- |
| RISC-V, PPC64 LE | `.eh_frame` works to `_start`/`__libc_start_main` | — |
| ARM 32 | `.debug_frame` works for `-g` objects; **libc has only `.ARM.exidx`** (856 entries, no DWARF CFI) | EHABI unwinder (T21 wrote one) |
| m68k | **`.debug_frame` only** (no `.eh_frame` at default flags) | a6 frame-pointer chain without `-g` |
| hppa | **none**: elfutils 0.196 has no parisc CFI backend (`DWARF_E_UNKNOWN_ERROR`) | frame-pointer/rp unwinder; the stack grows **up** |

Unwind-opcode decoders must be bounded. Codex found T21's EHABI ULEB decoder
(`0xb2`) overflows its shift and **aborts** on `b2 80 80 80 80 80`
(finding 1). Malformed metadata must return an error, never crash the
debugger.

### 2.10 Disassembly: Capstone for text only

Capstone's instruction groups are wrong for control flow on every non-x86
port. Trusting them makes step-over run away:

| Arch | Capstone 5 problem |
| --- | --- |
| RISC-V | `j` and `ret` tagged **call**; `c.jr ra` a jump; Zba/Zicboz undecodable although the hart has them |
| PPC64 LE | every branch is a plain `jump`; `bc 20,…` printed as `bdnz`; no `scv`, prefixed or `lqarx` |
| ARM 32 | `pop {pc}`, `ldr pc`, `mov pc,lr` have **no** flow group |
| m68k | FPU instruction lengths wrong (desynchronizes listings); `bsr`/`jsr` never `call`; on a **big-endian host** every immediate prints `#$0` (correct on x86) |
| hppa | no architecture at all until Capstone 6 |

Take length, flow and direct targets from the port's own ISA decoder (the pure
`riscv/ppc64/arm/m68k/hppa` adapters). Emit an explicit `.insn`/`.long` row
for anything Capstone cannot print. Print absolute branch targets.

### 2.11 What replaces Zig's safety in C

- Checked arithmetic on every address, offset and length computation.
  Subtraction-based slice bounds (`off <= len && n <= len - off`). An explicit
  choice between architectural wrapping and rejection. Never return an
  out-of-width pc (Codex finding 2: SPARC returned `0x100000000` for a 32-bit
  pc).
- Exhaustive `switch` over the architecture enum with `-Wswitch-enum
  -Werror`. Several merge bugs were only caught by Zig's exhaustiveness.
- A sanitizer build (UBSan/ASan) of the decoders and adapters, plus fuzzing:
  malformed ELF, DWARF and unwind bytes, and branch-condition combinations.
- Successor sets must be consistent with the known outcomes (Codex finding 3:
  an "unknown condition" result contradicted the decoder's own taken and
  not-taken answers).

### 2.12 Process lifecycle

- Wait only on known tids. Another subsystem may own other children.
- Kill and reap must resume stops already queued before SIGKILL, such as a
  worker's EVENT_EXIT, with `PTRACE_CONT` and SIGKILL. A leader cannot be
  reaped before its workers.
- Use `PTRACE_O_EXITKILL` for owned launches. Untraced helper children need
  `PR_SET_PDEATHSIG`.
- Attach sequence: SEIZE, INTERRUPT, waiting for `PTRACE_EVENT_STOP`, then
  detach. Verified everywhere; the program resumes.
- Report every optional feature as one of `supported`, `unsupported`,
  `permission_denied` or `failed`. Never report EPERM/EACCES as missing
  support.

## 3. Optional capabilities measured

| Arch | Hardware watchpoints | perf (user / root) |
| --- | --- | --- |
| RISC-V | unsupported (no `HAVE_HW_BREAKPOINT`, no regset) | EACCES (paranoid 3) / software works |
| PPC64 LE | API present, but POWER9 policy reports 0 DAWRs; with `dawr_enable_dangerous` QEMU fires **late** (3 instructions after the store) | EACCES / software and hardware cycles work |
| ARM 32 | **available**: `PTRACE_SETHBPREGS`, v7.1, 4 watch slots, and a QEMU write watch fires; not yet integrated | EACCES / software works |
| m68k | unsupported | **ENOSYS** (`CONFIG_PERF_EVENTS` off) |
| hppa | unsupported | EACCES / no hardware PMU |

## 4. Testing and operations lessons

- The guests have 430–500 MB of RAM and no swap. The full xodb unit binary
  was OOM-killed at about 335 MB RSS, so run the debugger namespaces on the
  guest and the profile/archive suites on x86. Confirm any SIGKILL in
  `dmesg` before calling it a failure.
- m68k and hppa have one slow CPU. Use per-operation deadlines that separate
  slowness from hangs (`T20_TIMEOUT`, `--deadline-ms`).
- Hand-encoded test vectors must come from the guest's own `as`/`objdump`;
  T20 found one wrong constant that way. The decoders were also checked
  against corpora: m68k matched objdump on 99.95% of 2.2 M instruction
  lengths (the rest are reserved or non-68040 encodings) and on every branch
  target; PPC had 106 hardware steps with 0 mismatches.
- Harness pattern that worked everywhere:
  1. The fixture prints `name 0xaddr` lines, then `ready`, then raises
     SIGSTOP.
  2. The harness SEIZEs, writes JSON lines with raw bytes, and keeps a table
     of owned PIDs.
  3. It cleans up by checking each guest process's cwd against the workdir.
- Debian sid guests (m68k, hppa) have no `/etc/resolv.conf`. Install offline
  from verified `.deb`s, or set a temporary resolver and restore it.
- Kill only processes you can prove are yours. The user runs the same demos
  concurrently.

## 5. Reusable artifacts for the port

- **C ptrace harnesses** (already C):
  [`tests/repros/qemu-m68k/harness.c`](../tests/repros/qemu-m68k/harness.c),
  [`tests/repros/qemu-hppa/harness.c`](../tests/repros/qemu-hppa/harness.c).
  These are self-contained control loops for registers, traps, steps,
  threads, exec, faults and attach.
- **Pure ISA adapters** (Zig, but plain logic that translates directly):
  [`riscv.zig`](../tests/repros/qemu-riscv64/riscv.zig),
  [`ppc64.zig`](../tests/repros/qemu-ppc64le/ppc64.zig),
  [`arm.zig`](../tests/repros/qemu-arm32/arm.zig),
  [`m68k.zig`](../tests/repros/qemu-m68k/m68k.zig),
  [`hppa.zig`](../tests/repros/qemu-hppa/hppa.zig). Each has host tests with
  guest-verified vectors. Port the tests with them.
- **Guest fixtures** with hand-encoded sites (`fixtures/*fix.c`), capability
  ledgers (`capabilities.py`) and runners (`guest.py`) in each
  `tests/repros/qemu-*`.
- **MCP acceptance scripts** (`riscv64-native.py`, `ppc64le-native.py`,
  `arm32-native.py`) and the private-Sway `remote-ssh-gui.py`. These test the
  protocol, not the implementation language, so they apply unchanged to a
  C build.

## 6. Open items to carry into the port

1. Codex review: fix the ARM EHABI ULEB bound (finding 1) and the target
   pointer width in the evaluator (finding 4), either in Zig before the port
   or directly in the C version.
2. T24: four live steps (ledger, software-step demo, the signal/breakpoint
   step-off, the C-backend adapter run) wait for the user to restart the
   wedged `hppa` VM.
3. With C, live m68k and hppa backends become possible:
   - m68k: GETREGS/SETREGS, `trap #15` with pc − 2, hardware step with the
     `SI_KERNEL` rule.
   - hppa: POKEUSER writes, the queue-aware pc, software step, and an rp
     unwinder.
4. Integration work not yet done in any language:
   - ARM 32 hardware watchpoints;
   - FP/VFP/VSX register display, and DWARF FP locations for O2 `double`s;
   - stepping over fork via process following instead of refusing;
   - physical-hardware validation (icache, LR/SC forward progress, PMU).
