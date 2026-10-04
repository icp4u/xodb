# Final Zig demo release

2026-10-03. The user is finishing the current Zig implementation for a demo
release, then plans to restart implementation in C. Compiler/backend work is
outside this release. Existing ABI fixtures, recorded evidence, MCP contracts
and debugger behavior tests should carry forward.

## Finishing order

1. **Finish allocation tracing first**, as selected by the user: live collection,
   explicit scoped helper privileges, GUI/MCP controls, lifetime evidence and
   end-to-end owned-fixture validation. Adopted and verified; [usage](ALLOCATIONS.md).
2. Small Lua inspection slice: explicitly loaded named commands, `dbg.eval`,
   stack/locals/memory inspection, bounded jobs and MCP results. Put the Lua
   runtime/error boundary in C so that component can survive the rewrite.
3. Data-only themes: passive startup palette loading, preserving the
   current default and the current control geometry. Implemented; [workflow](THEMES.md).
4. Fix and integrate demonstrable architecture candidates with the existing
   compiler where worthwhile; do not make missing compiler backends a release
   dependency. Review corrections against ARCHITECTURE_HANDOFF_REVIEW.md.
5. Freeze the feature list, run the existing release reliability gate, and
   provide short reproducible demos and an accurate capability table.

Allocation tracing is complete for the adopted first scope. Lua/theme ordering can be
revisited. Each interface will get a concrete review with a short critical
analysis before adoption, per the user's standing request.

## Critical review

The main payoff is a demo that shows customization and reusable investigations,
with fixtures and interfaces that remain useful in C. The risk is building a
large plugin platform immediately before replacing the host. Keep the first
slice small: inspection-only commands with copied, stop-tagged values; ordinary
theme data; no docking editor, automatic project scripts or target function calls.

The rewrite should reuse tested behavior, not freeze every implementation detail.
Preserve native/C fixtures, transport tests, malformed-input cases, ABI captures
and documented semantics. Zig-specific worker/allocator plumbing can be replaced.
The compiler-blocked targets retain useful research; they are not demo support
claims. T24 remains assigned to Claude.
