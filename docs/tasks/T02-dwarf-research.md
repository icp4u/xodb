# T02 DWARF normalization plan

Goal: recommend the fastest credible route to M1 source mappings, scopes,
variables, and unwinding while keeping debug-format details out of the UI.
This is a research and contract proposal, not approval to replace the stack.

Own `docs/research/dwarf.md`. Read T01's contract if available, but do not wait
for its implementation. Do not edit shared code or adopt a dependency yet.

## Questions to resolve

1. What is reusable from RAD Debugger, LLVM, Zig's implementation, and relevant
   mature system libraries? Inspect actual source and APIs; record versions,
   commits, license information, and binding/build costs.
2. Which minimal decoder path gives source-line lookup first, then frame
   unwinding, lexical scopes/types, and variable locations? Distinguish DWARF
   line tables from CFI and `.eh_frame` handling.
3. What normalized records should those subsystems return? Sketch ownership,
   stable identity, module-relative addresses, invalidation, and partial loading
   without freezing a large speculative database.
4. How should unsupported forms, optimized-out values, location-list gaps,
   inlining, split DWARF, and malformed input appear to callers?
5. Which deterministic fixtures and differential tools will prove each step?
   Cover GCC and Clang DWARF 4/5 first; plan Zig/Rust coverage where relevant.

## Acceptance and handoff

Provide a comparison grounded in primary sources, a recommended sequence of
small implementation tasks, an example normalized contract, and a fixture
matrix. Include concrete tradeoffs and unresolved questions. Keep the short
recommendation near the beginning; cite the evidence beside each claim.

Flag decisions that revise the brief or add a major dependency for user review.
Note where an LLM could help produce fixtures or diagnose discrepancies while
keeping runtime interpretation deterministic. No need to estimate human weeks.
