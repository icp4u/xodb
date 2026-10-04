# Shared contract for T20–T26

Read the per-target packet, `docs/AGENT_TASKS.md`, the applicable local and remote
AGENTS instructions, and current production sources. The user requested these
seven tasks for Claude on their local QEMU Linux guests. This contract is an
implementation and evidence checklist; the final shared architecture API will
be integrated by Codex after reviewing the first candidates.

## Ownership and coordination

- Only the three paths in your packet are yours in the shared checkout.
- Back up every existing file before modifying it. Put builds/caches and an
  isolated source snapshot under your owned repro directory. Record the base
  commit and an exact list/hash of copied dirty source files, if any. Exclude
  other agents' scratch directories, caches and backups from snapshots.
- Put changes to shared production files in `integration.patch` under your
  research directory, tested against that snapshot. Do not apply it to the
  shared checkout or stage/commit another agent's files.
- Keep original sources/licenses for anything adapted from Linux, GDB, LLVM
  or other upstream projects. Cite primary ABI/UAPI/code references with a
  version or commit. Do not infer support from a tool's architecture name alone.
- Journals must include ideas where an external local/remote LLM could help
  interpret evidence or automate diagnosis; do not add an embedded LLM runtime.

## Guest use

Use the packet's existing SSH alias with `BatchMode=yes` and a connection
deadline. Use the loaded SSH agent normally; never print/export private keys,
alter `~/.ssh/config`, or copy authentication material into a guest. Verify the
reported guest identity before deploying or attaching. Read remote instructions.

Owned test deployment goes in a newly created dedicated `~/Work/xodb-Txx-*`
workdir on that guest, respecting its instructions. Record its exact path and
every launched PID. Do not install packages, change sysctls, disable security
controls, restart guests, edit host QEMU configuration, or attach to an existing
user process. Record missing dependencies and proceed with independent work.
The authorization is for xodb development/tests, not system maintenance.

Run only your owned fixtures, with bounded deadlines, PID-specific stop/kill
and reap checks, and cleanup on every error path. Start with one compile job
and one live fixture per guest; increase only with measured room. Emulated
machines can be slow: configurable deadlines must distinguish guest scheduling
latency from a debugger deadlock. Use small fixtures, bounded memory and no
unbounded tracing or core dumps. Leave a cleanup manifest and preserve reports.
Do not run native GUI programs on the user's desktop; the first target is a
headless service controlled by the existing host GUI/MCP client over SSH.

## Stage A: ABI and capability ledger

Provide a read-only `capabilities` command and save JSON plus readable results:

- UTC date, SSH alias, kernel, userspace/ELF class and byte order, pointer/long
  widths, page size, libc, compiler/linker/Zig/libdw/libelf/Capstone versions.
- Exposed ISA/CPU features and ABI, readable ptrace/perf policies and effective
  permissions. Separate kernel interfaces from optional emulated hardware.
- Actual supported ptrace requests/regsets; lengths, errno and raw bytes where
  safe. General registers, PC/SP/return linkage, DWARF numbers and validity.
- Software trap encoding/alignment, PC adjustment, stepping semantics, cache
  synchronization, signal/fault decoding and architecture-specific state.
- Build feasibility for the installed Zig and its backends. Try a minimal
  executable first. Use guest GCC/Clang for a C ABI harness if necessary; label
  that distinction. Do not promise a full Zig port without a working link/run.

Each capability has `supported`, `unsupported`, `permission_denied`,
`not_tested` or `failed`, a reason, command and evidence path. Never classify
EPERM as absent CPU/kernel support. Compare an installed GDB/LLDB on the same
owned fixture where it clarifies a disputed result; do not install one silently.

## Stage B: architecture adapter and control harness

Deliver a small standalone harness and a proposed typed adapter. Preserve raw
guest bytes alongside normalized values. Identify these dimensions explicitly:

1. ISA, ELF machine/class, target byte order, pointer/address size and ABI.
2. Register descriptors: names, widths, DWARF numbers, PC/SP/control roles,
   available/unavailable state, exact regset decode/encode bounds. Do not
   reinterpret foreign byte buffers as host structs or use zero for unknown.
3. Software breakpoint width, bytes, instruction mode, stopped-PC adjustment,
   original byte restoration, read masking and pending/temporary-probe behavior.
4. Single-step availability and any software fallback; successor decoding must
   distinguish unsupported instructions from an actual next-PC result.
5. Return-address lookup, calling convention and unwind prerequisites. Do not
   use one universal `return_pc - 1` or `return_pc - 4` rule.
6. Capability reporting for hardware watches, FP/vector registers, profiling,
   disassembly and unwind; unsupported optional features fail explicitly.

Test the real guest kernel with owned O0 and O2 fixtures:

- Launch and attach to a separately running owned process; interrupt and stop.
- Read known registers and memory (including high-bit values and page edges).
- Plant/hit/remove a software breakpoint; compare surrounding original bytes;
  step off/reinsert, repeat hits, and distinguish an application's SIGTRAP.
- Instruction stepping at straight-line code, conditional control flow,
  call/return and target-specific modes/delay slots. Preserve signal delivery.
- Multi-thread enumeration, clone, exec, normal exit and a fault stop; operate
  only on known TIDs and never consume another task's child waits.
- Restore and detach an attached fixture, proving it resumes correctly; kill
  and reap an owned launched child on debugger shutdown and failure/timeout.
- Try one write-watchpoint and one task-scoped software CPU sample if exposed.
  Record precise failure categories. Emulated hardware support is optional.

Host-side decoder tests must reject truncated/oversized regsets, preserve
unknown fields during writes, and check address overflow, signed values and
both actual target byte order and word size. Do not rely on a successful
cross-build as evidence that ptrace control worked.

## Stage C: headless xodb candidate

In the isolated snapshot, implement the smallest maintainable production patch
that launches the headless service and passes the applicable shared MCP tests.
Reuse current lifecycle, scope and remote transport contracts. Do not fork a
separate permanent debugger or broaden unrelated UI/profiler changes.

Required where the toolchain permits: MCP initialize/session; owned launch and
attach; pause/continue/step; registers/memory; software breakpoint lifecycle;
ELF symbols; source lookup; stack/locals/expression evaluation on an O0 fixture;
remote host GUI over SSH; clean detach/shutdown. Check agent scopes and stale
generation rejection. Record an O2 fixture's exact available/unavailable values.
Keep inferior addresses serialized as target values, independently of the
host/client width and endian. Existing x86/AArch64 tests must still build/run
locally for a candidate that touches shared representations.

Use `-Dgui=false` and the build's `app` step when appropriate; production fixture
flags may themselves assume an ISA. Keep a missing optional profiler, graphics
stack or disassembler from being misreported as a ptrace failure. Any feature
stub must advertise unsupported capability, not return fabricated data.

If Zig cannot produce the target, finish A/B plus portable parser/ABI tests,
deliver the exact compiler/linker failure and a concrete smallest next step.
Do not label the native C harness as an integrated xodb service. Hardware watch,
perf, native GUI and full language coverage are follow-ups after core control.

## Handoff (all packets)

- `docs/research/qemu-<alias>.md`: summary, architecture facts, implementation
  map, critical review (one or two paragraphs), blockers and next step.
- Evidence directory: dated raw transcripts, capability JSON, fixture hashes,
  source/compiler versions and tested `integration.patch` with base commit.
- Repro directory: minimal fixtures, adapter/harness, local parser tests and
  separate explicit guest deploy/run commands. Repeatable without shell history.
- Feature matrix separating cross-build, full-system QEMU guest runs and
  physical hardware (unverified unless separately tested).
- At most six clear demo commands with expected observations; host GUI demo
  can remain a documented command if safe automated GUI testing is unavailable.
- Cleanup result: every owned child reaped/detached, original patched bytes and
  debug-register state restored as applicable; exact retained guest files.

Completion means the supported slice is demonstrated and the integration patch
is tested, or a precise build blocker is proven with all independent A/B work
finished. Discovery alone is an early checkpoint, not the whole assignment.
