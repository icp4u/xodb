# T19: GUI expression evaluation

Status: integrated after user approval (2026-10-02); Claude prototype / Codex corrections.
[Adopted behavior](../M2_EXPRESSION_WATCH_PROPOSAL.md) · [Evidence](../research/t19-integration.md).
Handoff: `docs/research/expression-watch.md`. Requested by the user 2026-10-01.

## Goal and ownership

Let a person evaluate expressions in the native UI, matching what agents already do
with MCP `evaluate_expression`. Today the GUI shows locals and one level of struct
fields; it has no place to type an expression. Own only:

- `tests/repros/expression-watch/`
- `docs/research/expression-watch.md`
- `docs/research/expression-watch/`

Read `src/model/evaluate.zig` (parser and operators), `Session.evaluateExpression`,
`Session.valueChildren`, `Session.locals` and `Session.investigateWrite` in
`src/model/session.zig`, `src/model/value_view.zig`, the `evaluate_expression`
and `get_value_children` handlers in `src/mcp/server.zig`, the locals/registers
pane and frame selection in `src/ui/workspace.zig`, and the text-field handling
in `src/ui/capture_panel.zig` (T14) for keyboard editing conventions. Record
the current commit plus hashes, work in an isolated copy within your owned
paths, and return shared changes as a patch against that commit. Do not edit
production files or other tasks' artifacts.

## Required slice

1. An expression entry, opened by a key and closed by Esc, in the stopped-target
   view. It evaluates against the **selected thread and frame**, the same context
   `evaluate_expression {tid, frame}` uses, and says which TID/frame it used.
2. Results show value, type and availability. Errors name the cause in plain
   words: unknown variable/register/field, not addressable, optimized out, out of
   bounds, unreadable memory, short-circuit operators not supported, too deep.
   A typo must never look like a value.
3. Struct, array and slice results expand through `Session.valueChildren`, using its
   paging and raw/slice presentation, bounded as MCP's `get_value_children` is.
4. Several expressions can be kept as a short watch list, bounded in count and
   text length. On each new stop, generation change or frame change, each entry
   re-evaluates. Entries carry the frame they were made in and show when that
   frame is gone; they must never silently move to an unrelated frame with the
   same index. Show which values changed since the previous stop.
5. While the target is running, entries show their last value as stale, and no
   memory is read. Selecting a watch entry may offer the existing
   `investigate_write` watchpoint action (W), with no new authority.
6. Keyboard-first: history recall, the current shortcut policy (active layout
   only), and no keys stolen from the source/flow/profile views. Usable at
   640x480 and in a wide window.

Out of scope unless proposed separately as a patch with evidence: new evaluator
grammar (casts, sizeof, globals, `&&`/`||`), inferior function calls, memory
writes, and any MCP schema change. List evaluator gaps the UI work exposes as
proposals.

## Validation and handoff

- Unit tests for the watch-list model: bounds, re-evaluation per generation and
  frame, frame-identity loss, change marking, and stale-while-running without
  memory reads.
- A live test against an owned optimized C fixture (`-O0` and `-O2`) with structs,
  arrays, pointers, a Rust/Zig-style slice if one is practical, an optimized-out
  local and a dangling pointer. For each GUI result, confirm parity with MCP
  `evaluate_expression` for the same TID/frame/expression.
- A private headless Sway at 640x480 and in a wide window (never the user's desktop):
  entering and editing text, error states, expansion, watch updates across stops
  and steps, and a frame change. Measure input and draw cost, and the time of a
  watch refresh with the maximum number of entries.
- Deliver the patch, reproduction commands, screenshots, measured limits, and **one
  or two short paragraphs of critical review before the choices for approval**
  (keys, layout, list bound, change-marking style).

Critical risk: a watch value that silently re-binds to a different frame or thread
after stepping, or a stale value that looks current. Prefer an explicit
"frame gone" or "stale" state over a plausible wrong number.
