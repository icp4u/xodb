# C core / Zig boundary

Agreed direction, 2026-10-04. This summarizes the earlier
[C runtime proposal](CLAUDE_C_RUNTIME_SCOPE.md) and makes ownership explicit.

**C owns target execution and data collection. Zig owns debugger analysis,
user policy, and presentation.** The same C runtime links into local xodb and
builds as a standalone remote agent with GCC or Clang. The agent needs no Zig,
GUI libraries, or ELF/DWARF library. The host continues to provide the full
debugger experience. The analysis layer is limited to zig supported arch.

**When in doubt, prefer C if it makes the architecture cleaner.** The division
below is a starting point, not a requirement to keep particular logic in Zig.
If a boundary would require duplicate implementations or a complicated
interface, move the cohesive functionality into C and make that the one
authoritative implementation. More C with a clear division is preferable to
preserving Zig ownership through extra machinery. A complete C rewrite is
unnecessary; Zig remains suitable for the GUI and application code.
Host-side C can link into the Zig host without becoming part of the target agent.

```text
GUI / MCP / command line                 Zig
Session, symbols, source, profiles       Zig
Target facade                           Zig
              |
         C runtime API
          /          \
 local runtime     remote proxy -- framed stream -- C agent
       |                                               |
   Linux target                                   Linux target
```

**What belongs where**

| Area | C core | Zig application |
| --- | --- | --- |
| Process control | Launch, attach, wait on owned TIDs, signals, threads, exec, fork/vfork mechanics, detach and cleanup | Session selection, process-following policy, human/agent permissions, audit |
| Target state | Authoritative stops, generations, image epochs, registers, memory, physical breakpoints and watchpoints | Read-only snapshots, display state, logical/pending breakpoints, conditions and logpoints |
| Stepping | Instruction stepping, trap handling, software-step successors, bounded address/range operations | Source-line stepping, step-over/finish intent, choosing destinations from symbols and frames |
| Architecture | Target widths and byte order, register descriptions and DWARF-number maps, ISA rules needed for execution | ELF/DWARF interpretation, unwinding, expressions, value views and disassembly presentation |
| Files and modules | Target `/proc` queries and identity-checked access to mapped files | Module/symbol/source maps, binary/debug-file loading and caching, core-dump analysis |
| Profiling | Kernel collectors: perf rings, tracepoints and uprobes | Record decoding, symbolization, stack unwinding, stores, comparisons, timelines and `.xoc` archives |
| Interface | Typed operation results and capability reporting | GUI, MCP, existing remote GUI protocol, preferences and rendering |

The existing allocation privilege helper remains separate from the runtime.

**Rules at the boundary**

- Use a handwritten C11 headers under `src/runtime/`, imported
  by `src/target/runtime.zig`. Opaque handles hide implementation state. Bulk
  results use caller-provided buffers; C-owned handles have explicit destroy
  functions. Neither language frees the other's allocations.
- One event-loop thread owns ptrace and related targets. Zig obtains copied
  snapshots/events through the API; it cannot directly edit C state. Workers
  consume immutable snapshots. C owns the authoritative generation and checks
  expected generations on mutations. Policy changes that invalidate actions
  explicitly request invalidation through the API.
- Describe the target at runtime. Addresses use checked `uint64_t` values;
  register data carries widths and target byte order. Never interpret target
  pointers or register sets using the host's layout. Unsupported capabilities,
  permission failures and operational failures remain distinct results.
- Zig translates source intent into addresses and bounded execution plans.
  C executes those plans locally, respecting signals, user probes, watchpoints
  and cancellation. This avoids a remote round trip per instruction without
  moving DWARF or expression evaluation into the agent.
- Local and remote backends expose the same operations. The remote encoding is
  versioned, length-bounded and explicit about integer widths/byte order; it
  never transmits native C structs or pointers. Event sequence gaps require
  resynchronization before further mutations. Raw profiling records carry explicit producer architecture and clock metadata. This protocol is separate from MCP.
- C uses checked address/length arithmetic and bounded buffers, including on
  32-bit machines. Large scratch storage belongs on the heap. Preserve existing
  user-visible error names through the Zig facade.

**Implementation order**

1. **Local debugger control.** Introduce the header and Zig facade, then move
   the x86-64 Linux target implementation in testable slices. Start with
   launch/attach, stops, registers/memory, breakpoints and instruction stepping;
   follow with watchpoints and process-family lifecycle. Bring AArch64 to parity
   before retiring its Zig backend. GUI and MCP share the same facade.
2. **Standalone C agent.** Add the stream transport and host proxy. Validate
   it on x86-64, then build with GCC in the m68k VM and exercise cross-architecture
   debugging from the x86 GUI. Add other architectures behind explicit
   capabilities as their adapters are validated.
3. **Collection.** Move perf/syscall/allocation kernel plumbing behind the
   same API, preserving host analysis and capture behavior.

The first milestone is the existing local debugger running through the C core:
launch/attach, break/step, Zig-backed stacks and expressions, and clean teardown.
Use the existing lifecycle, thread/fork, breakpoint/watchpoint and MCP tests,
plus a private GUI smoke check. Compile C with GCC and Clang and run targeted
ASan/UBSan checks; add malformed-input tests for new decoders and framing.

Revisit the boundary as implementation reveals better divisions, using the
C-first rule above.

**Migration status:** the local debugger and kernel collectors now use the C
runtime. C owns launch/attach, waits and stop classification, generations and
image epochs, physical breakpoints and memory overlays, instruction stepping,
hardware watchpoints, fork/vfork coordination, detach/cleanup, general registers,
and x86 SIMD/FP state. Zig's target facade converts read-only snapshots and sends
operations; it cannot edit live state. Test-only private headers permit deliberate
fault injection without adding writable production APIs.

CPU sampling, syscall tracepoints and allocation uprobes share C-owned perf event
groups and rings. C owns event descriptors, mmap lifetime, head/tail barriers,
transactional enrollment, retirement, metadata validation, pinned allocation
files, cancellation and rollback. Zig consumes borrowed record bytes through a
bounded callback, retaining decoding, symbolization, capture policy and archives.
The allocation privilege helper remains separate.

The existing local suite passes through this boundary, including lifecycle,
probe/family control, live profiling, loss/cancellation handling and private GUI
checks. Standalone GCC tests exercise the C runtime without linking Zig; targeted
Clang ASan/UBSan runs check target and collector ownership. Ptrace sanitizer runs
disable LeakSanitizer (`ASAN_OPTIONS=detect_leaks=0`) because it starts its own
tracer. Collector/framing tests also run with leak detection enabled.

The standalone C agent and C host proxy now use that same API. The agent owns
remote targets, collectors and target-file descriptors. Mapped files cross as
bounded, identity-checked transfers into sealed host snapshots. General registers,
ELF parsing, unwinding, expressions and disassembly use the target ISA at runtime;
the x86-64 host has been exercised against a GCC-built m68k agent in the VM.
Remote CPU, syscall and allocation capture use the same host analysis and archive
paths as local capture. Allocation privilege remains an explicitly selected helper
on the target.

The agreed C swap is implemented. This does not add every architecture or collector:
process following and profiling remain x86-64 features; m68k lacks hardware watches
and extended registers. AArch64 C code is compiled here, with no new live ARM64
validation claimed. See [C runtime operations and limits](C_RUNTIME.md) for builds,
examples, the wire contract and the verification commands. The existing SSH/MCP GUI
protocol remains separate from the C runtime stream protocol.
