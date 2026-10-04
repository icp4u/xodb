# Claude scope: a C debugger runtime shared by xodb and remote agents

Claude (Opus 5.5), 2026-10-03. Measured against `097e3a9` (36.3k lines of
Zig) plus the T20–T24 architecture adapters. This is a proposal, not an
integration plan; Codex owns shared integration. Background facts are in
[CLAUDE_CPORT_REVIEW.md](CLAUDE_CPORT_REVIEW.md).

## Premise

Keep Zig for the application: GUI, Vulkan/Wayland, MCP, ELF/DWARF, expression
evaluation, profiling analysis and archives. Zig runs wherever that stack
runs. Move only the **target-side runtime** into C:

- linked into the Zig process for local targets;
- built standalone with a plain C compiler as a small **agent** for remote
  targets, including GCC-only ISAs (m68k, PA-RISC, SPARC).

One API serves both cases. In-process it is a direct call; remotely the same
API runs over a framed wire protocol.

## Summary

| | Size |
| --- | --- |
| Existing Zig that moves to C | **≈3.2k lines** (≈9% of 36.3k): target control (`src/target`, minus tests), the kernel side of the profiling collectors, and the `/proc` queries |
| ISA adapters that move (in the stack and repros, not yet in `HEAD`) | ≈3.5k lines of logic (riscv, ppc64, arm32, m68k, hppa) |
| New code | wire protocol, agent `main`, host proxy: ≈1.5–2k lines of C plus ≈0.3k of Zig |
| **Total C** | **≈10–13k lines** |
| Zig changed in place | ≈1–1.5k lines: a facade that keeps today's `Target` API, a run-time architecture model in place of the compile-time one, and a stable error-name map |
| Zig that stays as is | ≈32k lines, including **all** existing tests, which become the C core's regression suite through the facade |

Effort at our pace is roughly **6–12 agent-hours**, or half a day to a day
with parallel agents per piece and per ISA. Wall-clock time is dominated by
guest validation, especially the 1-CPU m68k/hppa guests (hppa first needs a
restart).

## The boundary: what goes into C

| Component | Where it is today | In the C core |
| --- | --- | --- |
| Process and thread control: launch gate, `SEIZE` options, attach/interrupt/continue, poll over known tids only, exit/reap/`EXITKILL`, exec image epoch | `target/linux.zig` (1.73k non-test lines, 34 public methods) | yes |
| Fork/vfork births, adoption, shared-VM families, process following (Codex `c44cec6`+) | `target/linux.zig` (≈120 lines touch it) | yes (target-side state) |
| Event ring, `generation`, `image_epoch`, stop info and signal classification | `target/linux.zig` | yes. **The C core owns generation**, so stale-snapshot rejection behaves identically locally and remotely |
| Registers: exact regset I/O, write hazards (hppa `POKEUSER`, ppc masks, m68k CCR) | `linux.zig`, `xstate.zig` | yes |
| **Architecture descriptors**: names, slots, DWARF maps both ways, widths, byte order, traps, alignment, caller and stopped-pc rules | `arch.zig` + adapters | yes, as **C data tables** that Zig reads through `@cImport`, so there is one source of truth for DWARF, the GUI and MCP |
| Memory read/write with probe overlay; patching in native ptrace words | `linux.zig` | yes |
| Breakpoints (per-probe trap kind), watchpoints (x86 DR, ARM64 regset, ARM32 HBP), hardware and software stepping, atomic-sequence planning | `linux.zig`, `breakpoints.zig`, `arm_watch.zig`, adapters | yes |
| **ISA decoders** (length, flow, successors) | adapters | yes. **Shared by agent stepping and host disassembly/CFG** (`model/disassembly.zig`, `control_flow.zig` call them) |
| Target OS queries: `/proc/<pid>/maps`, `map_files`, `exe`, task `comm`/`stat`, auxv, boot id; **file read with identity** (dev, inode, size, build ID) so the host can fetch binaries and debug files | `model/modules.zig`, `ui/workspace.zig`, `profile/activity.zig`, `binary/snapshot.zig` | yes, a small query API |
| Profiling collectors, kernel side: `perf_event_open`, mmap ring drain into **raw record bytes**, syscall-timing tracepoints, allocation uprobes at host-resolved offsets | `linux_perf.zig` (806), `linux_syscalls.zig` (178), `linux_allocations.zig` (355), `allocation_hooks.zig` (140), all non-test | yes, as phase 2. Record decoding (`records.zig`), sample stores, unwinding and archives stay in Zig |
| Core-dump targets (`Target.core`, `binary/core.zig`) | Zig | **no**. File analysis stays host-side, as a second backend behind the facade |

**Stays in Zig:**

- ELF, DWARF and libdw (`binary/`, `debug/`);
- the evaluator and value views;
- modules, symbols and source maps (with `/proc` routed through the core);
- session policies: source step, run-to, finish, pending and persistent
  probes, probe policies and logpoints;
- MCP, GUI, render and platform;
- the whole profile analysis/archive/timeline/flame stack;
- preferences;
- the existing remote-GUI view protocol.

## API shape (sketch)

```c
/* xrt.h — xodb runtime. All calls for one target stay on one thread (ptrace owner). */
typedef struct xrt_target xrt_target;          /* opaque */
typedef enum xrt_status { XRT_OK, XRT_NOT_STOPPED, XRT_INVALID_BREAKPOINT_ADDRESS,
    XRT_HARDWARE_WATCHPOINTS_UNSUPPORTED, /* … one per current Zig error name … */ } xrt_status;
const char *xrt_status_name(xrt_status);        /* "InvalidBreakpointAddress", … (MCP-stable) */
const xrt_arch *xrt_arch_of(const xrt_target *); /* descriptor tables: slots, DWARF maps, traps */
const xrt_state *xrt_state_of(const xrt_target *); /* generation, threads[], probes[], births[], events */
xrt_status xrt_launch(xrt_target *, const char *const argv[]);
xrt_status xrt_attach(xrt_target *, int pid);
xrt_status xrt_poll(xrt_target *);               /* drain kernel stops into the event ring */
xrt_status xrt_step(xrt_target *, int tid);      /* hardware or planned software step */
xrt_status xrt_step_range(xrt_target *, int tid, uint64_t lo, uint64_t hi); /* new: no per-insn RTT */
xrt_status xrt_read(xrt_target *, uint64_t addr, void *, size_t, size_t *got); /* overlay applied */
xrt_status xrt_file_read(xrt_target *, const char *path, uint64_t off, void *, size_t, xrt_file_id *);
/* … the remaining methods of today's 34, plus collector start/drain/stop … */
xrt_target *xrt_remote(int fd);                  /* proxy: same API over the wire, state mirrored from events */
int xrt_serve(int fd);                           /* agent main loop (~300 lines) */
```

Design rules:

- **One API, two transports.** The proxy implements `xrt.h` by RPC and keeps
  a replicated `xrt_state` updated from the agent's event stream. The Zig
  facade cannot tell local from remote.
- **Move the hot loops into the core.** Today a source step is a loop of
  single instruction steps driven from Zig (up to 10,000). Remotely that is
  one round trip per instruction. Add range stepping (step while pc is in
  `[lo, hi)`, as GDB's `vCont;r` does), run-to-address, and batched memory
  reads. DWARF evaluation's memory reads get a per-generation read cache.
- **The core never sees DWARF.** The host translates source lines into
  address ranges.

## Zig-side work

- **Facade (`target/runtime.zig`, ≈400–600 lines).** It keeps the current
  `Target` method names and semantics. Today 23 files call 34 methods and read
  internal fields directly, most often:

  | Field | Reads |
  | --- | --- |
  | `generation` | 76 |
  | `state` | 67 |
  | `image_epoch` | 35 |
  | `breakpoints` | 21 |
  | `threads` | 13 |
  | `core` | 15 |
  | `birth_count` | 10 |

  These become reads of the C `xrt_state` (a plain C struct through
  `@cImport`) or small accessors, so caller churn is minimal.
- **Run-time architecture (about 40 sites).** `linux.architecture`,
  `linux.Registers`, `programCounter`/`stackPointer` and `regs.rip` are
  compile-time native today. The sites are `model/session.zig` (21),
  `ui/workspace.zig` (9), `mcp/remote.zig` (2), and one each in
  `mcp/server.zig`, `model/disassembly.zig`, `model/analysis_ir.zig`,
  `debug/location.zig` and `model/modules.zig`; the collectors move to C
  anyway. They become `target.arch` plus a slot array read through the C
  descriptors. x86-only features (XSAVE vectors, the instruction-analysis IR)
  stay gated at run time. T23's ELF/DWARF layer already follows the image's
  architecture, so this is the next layer up.
- **Error names.** `src/target` raises 65 distinct error names, and MCP and
  the Python tests assert exact strings. Use a C enum with a name table and a
  compile-time Zig map from `xrt_status` to error, so every MCP error text is
  unchanged.
- **Tests.** Keep the existing Zig suites (`linux.zig` 406 test lines,
  `lifecycle_test.zig` 243, `process_test.zig` 315, the Python MCP suite)
  against the facade as the core's regression gate. Call the C decoders from
  the existing Zig adapter tests through `@cImport`; nothing is rewritten.
- **Build.** Zig compiles the core with `addCSourceFiles`: the same toolchain
  everywhere Zig runs, with no new dependency. The agent builds with
  `cc -std=c11` from a tiny Makefile on GCC-only targets. Use one source tree,
  C11 only, and these warnings: `-Wall -Wextra -Wswitch-enum -Werror`. Add a
  UBSan/ASan build plus fuzzing of the decoders, regset decoders and wire
  framing, because Zig's checked arithmetic and exhaustiveness no longer
  protect this code (see CLAUDE_CPORT_REVIEW §2.11 and Codex's findings).

## Size and effort (agent pace; rough)

| Piece | Zig today (non-test) | C estimate | Agent effort |
| --- | --- | --- | --- |
| Target control, fork families, events, probes, watch, step plumbing, stop info | ≈1.9k | ≈2.5–3k | 1.5–3 h |
| ISA adapters (riscv, ppc64, arm32, m68k, hppa) | ≈3.5k | ≈4–4.5k | 1–2 h, parallel per ISA |
| OS queries and file fetch | ≈0.1k | ≈0.3k | 0.5 h |
| Collectors, kernel side | ≈1.2k | ≈1.2–1.5k | 1–2 h (can defer) |
| Wire protocol, agent `main`, host proxy | new | ≈1.5–2k C + 0.3k Zig | 1–2 h |
| Facade, run-time architecture, error map | — | ≈1–1.5k Zig changed | 1–2 h |
| **Total** | **≈6.7k moved** | **≈10–13k C** | **≈6–12 agent-hours** |

Validation turnaround: x86 suites take minutes. riscv64/ppc64le/arm32 guest
MCP runs take 5–15 minutes each. m68k and hppa are slower (1 CPU), and hppa
needs the VM restarted first.

## Risks and decisions

1. **Where step policy lives.** Range stepping in the core removes remote
   latency; source-line policy stays in Zig. Decide this before writing the
   protocol.
2. **State mirroring.** The event ring is capped at 4096 entries. The proxy
   must detect gaps and resynchronize from a full `xrt_state` snapshot, never
   guess. Generation must advance identically on both sides.
3. **One ptrace thread.** The core is not thread-safe by design; the facade
   keeps today's invariant that all calls happen on the creating thread.
4. **Fetching binaries and debug files.** The host must analyze the exact file
   the target ran. `xrt_file_read` returns identity (inode, size, build ID),
   and `debug_files.zig` already verifies build IDs.
5. **Profiling over SSH.** Raw ring bytes can be large; ship them bounded and
   compressed, and keep decoding on the host. This can be deferred.
6. **Fork hazards are unchanged.** Software steps still refuse fork-like
   clones until process following can repair inherited step traps; the core
   enforces it.
7. **Coexistence.** Keep today's full-xodb remote mode for Zig-capable
   targets until split mode matches it, then retire it.

## Suggested first slices

1. **x86-64 only, in-process.** Build the C core and the facade, delete the
   moved Zig, and require every existing Zig test and the Python MCP suite to
   pass unchanged. This proves the boundary and the error names.
2. **Agent on riscv64** (a fast guest). Run `riscv64-native.py` through split
   mode (Zig host plus C agent). This proves the protocol, mirroring and range
   stepping.
3. **m68k agent.** This is the first live m68k debugging. It needs no Zig on
   the target, and no gdbserver.

## Critical analysis

The benefit is a single debugger runtime written once in C. Today's xodb links
it locally; on GCC-only ISAs it ships as a tiny agent, while ELF/DWARF, MCP,
the GUI and profiling analysis stay in Zig. Only about 9% of current Zig
moves, plus the adapters. The ISA decoders become one implementation serving
both stepping and disassembly. The existing Zig and Python suites act as an
unchanged gate, and the per-port C harnesses and kernel facts carry over
directly.

The weakest assumption is that today's `Target` surface, about 34 methods plus
a handful of internal fields, is a good RPC boundary. It was designed as an
in-process object. Source-step loops, per-read DWARF memory access and direct
field reads all assume zero latency, so range stepping, batched reads and
state mirroring are mandatory, not optimizations. The other cost is losing
Zig's safety in exactly the code that parses hostile bytes and drives ptrace,
which is where Codex already found overflow bugs; sanitizers and fuzzing must
come with the move. I would do slice 1 first and defer the collectors and
retiring full-remote mode until split mode passes MCP on a fast guest.
