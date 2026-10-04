# x86-64 functional implementation plan

2026-10-02. User approved the complete functional gap list. Implement and verify
these increments while preserving the current debugger and remote workflows.
The [gap review](research/x86-functional-gaps.md) explains their motivation.

- [x] Conditional breakpoints, thread filters, hit/ignore counts, logpoints and GUI management ([usage](BREAKPOINTS.md)).
- [x] Finish/step out and run to cursor.
- [x] Restart and pending symbolic breakpoints (glibc base namespace; other loaders resolve at stops).
- [x] Memory browser, bounded search and changes between snapshots.
- [x] x86 floating-point/SIMD registers with typed lane views.
- [x] Automatic matching symbols, source remapping, inline frames, split DWARF and composite locations.
- [x] ELF core debugging and signal/crash inspection ([initial x86 scope and limits](CORE_DEBUGGING.md)).
- [x] Scoped syscall durations and blocking context in timeline/MCP/archive ([usage and limits](SYSCALL_TIMING.md), [evidence](research/syscall-timing.md)).
- [x] Allocation/free collection, outstanding allocations and lifetime evidence ([usage](ALLOCATIONS.md), [live results](research/allocation-tracing.md#adopted-live-capture-2026-10-03)).
- [x] Fork/vfork process trees, selection, per-process controls and cleanup ([usage and limits](PROCESS_TREES.md)).

Each increment needs real owned-fixture evidence, bounded work, error/cleanup
coverage and documented limits. Keep GUI and MCP backed by common model operations.
Use the existing configured workstation for native checks; no personal-device
operations or system-policy changes are part of this plan. GUI automation uses a
private headless compositor. Record findings and LLM opportunities in docs/research.

## Initial decisions

Breakpoint conditions are side-effect-free native expressions. Evaluation errors
stop visibly. Thread filters bind to stable debugger thread identity. Hit counts
count observed traps; ignore counts consume matching-thread hits before condition
evaluation. Logpoints record expression values in a bounded, sequenced history
and auto-continue only when no other thread has a meaningful stop. Explicit pause
and agent scope revocation take priority over automated continuation.

## Progress

The original functional list is implemented for its documented initial scopes.
Allocation tracing was adopted and verified on owned glibc workloads, including
cross-thread frees, explicit gaps and a private production GUI. The historical
preparation notes below describe earlier stages.

First breakpoint/control increment passes the native suite and owned MCP/GUI
fixtures. [Findings and evidence](research/breakpoint-controls.md).

Memory/search and typed x86 registers: [usage](MEMORY_REGISTERS.md),
[findings](research/memory-registers.md).

Restart/pending-library implementation: [usage](BREAKPOINTS.md),
[findings](research/restart-pending.md).

Optimized-code prerequisites: automatic verified local companions and explicit
source maps implemented ([usage](SYMBOL_DISCOVERY.md)). Inline scopes, live split
DWARF and bounded composite values implemented ([usage and limits](OPTIMIZED_DEBUGGING.md),
[findings](research/optimized-debugging.md)).


Process-tree GUI/MCP workflow adopted with the requested configurable 1,024
retained-session ceiling, default 32; [design and limits](M2_PROCESS_TREE_PROPOSAL.md).
Allocation lifetime analysis is implemented. The separately approved host
sudo probe passed once; [register evidence and limits](research/allocation-probe-host-20261003.md).
Production collection privileges and live integration still need review/work.

Allocation event pairing, strict perf decoding and a bounded uprobe collector
are prepared; the native gate passes 273 tests (four ARM skips). Ordinary-user
setup still returns EACCES and cleans up its descriptors. Successful collection,
the privilege workflow and GUI/MCP integration remain unverified/incomplete;
see [the investigation](research/allocation-tracing.md).

Runtime allocator hook preparation now verifies executable VMA/file identity,
resolves defined function symbols in the runtime ELF and rejects stale file
identities before opening probes. The updated native gate passes 276 tests
(four ARM skips). Live delivery and Session/GUI/MCP integration are still pending.

The shared allocation capture model now has cancellable lifetime workers,
revisioned event/call/lifetime pages and a prepared read-only MCP adapter.
The native gate passes 287 tests (four ARM skips). The adapter is not publicly
registered, and Session/GUI/live collector integration remains incomplete.

A read-only allocation inspector component is also prepared, with Calls,
Lifetimes, Outstanding and Events tabs. Twenty-one private GUI assertions pass
at wide/small sizes with explicitly labeled constructed captures; the native
gate remains 287 passed/four ARM skips. Production Workspace/Session wiring
and live validation remain outstanding; see the allocation journal for previews.

The approved host uprobe run now confirms three entry/return pairs and native
x86 register semantics. An explicit normalization adapter and register replay
regression pass all 26 targeted decoder/pairing/lifetime tests. The probe's
success does not adopt a root GUI or a production privilege mechanism.
