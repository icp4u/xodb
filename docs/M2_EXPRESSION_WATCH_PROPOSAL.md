# T19: expression entry and watch list

Status: adopted by the user and integrated (2026-10-02).
Based on Claude's [T19 handoff](research/expression-watch.md), rebased onto
`4ed1b6e` and corrected during coordinator review.

## Short critical review

This closes a useful gap: a person can evaluate the same expressions an MCP
client can, retain several results and turn an addressable expression into an
existing hardware write investigation. Reusing the evaluator keeps GUI and MCP
values consistent. The compact WATCH pane preserves source, assembly and locals;
small windows need scrolling to see expanded children.

The weakest assumption is frame lifetime. A CFA and function address can be
reused by a later call between stops. The candidate labels later results **CFA
match**, permanently retires an entry once its frame is observed gone, and
invalidates reused thread IDs and replaced images. It cannot prove activation
continuity without additional execution tracing. Change highlighting compares
value summaries, not every byte of an aggregate. I recommend this bounded first
slice with these limits visible; deeper call tracking, recursive object trees and
remote GUI entry should follow separately.

## Adopted interactions

- **E** opens an expression field against the selected thread/frame.
- **Return** adds the expression to the watch list; **Esc** cancels.
- While editing, **Up/Down** recall history and **Ctrl-U** clears text. Text does
  not trigger workspace shortcuts; function keys retain their normal actions.
- **V** switches the bottom-right pane between WATCH and EVENTS in the local GUI.
- In the focused watch list: **Up/Down** select; **Delete** removes;
  **Return** expands/collapses; **PgUp/PgDn** page children; **[ / ]** or the
  mouse wheel scroll rows; **W** starts the existing hardware write investigation.
- Click source/locals/stack to leave watch-list focus. Entry stays bound to its
  original context rather than following later frame selection.
- Initial session-only bounds: 16 expressions, 256 ASCII bytes each, 32 history
  entries, 16 children per page. These are implementation defaults, not permanent
  interface commitments. No expression persistence or preference schema yet.
- At heights below 640 pixels, showing WATCH gives the lower panes more space.
  Narrow watch panes show the selected entry's type, availability and context
  above the values. Wide panes show these in columns.

## Value and identity rules

- Evaluation and child expansion use `Session.evaluateInFrame`, `summarize` and
  `valueChildren`, sharing one unwind per watched thread and locals per frame.
- A watch stores session identity, executable epoch, stable thread ID, module,
  function address, CFA and its creation generation. Symbol text is a label,
  never the identity key.
- At its creation stop, a frame with no CFA/function identity can be evaluated;
  after a generation change the entry asks to be re-added. It is not rebound by
  stack index.
- A complete unwind that lacks the bound frame means **frame gone**, permanently.
  An incomplete or failed unwind means **stack unavailable**, without evaluation.
  A later successful match remains explicitly heuristic.
- Running targets retain stale labelled values and perform no watch evaluation.
  Exit/detach marks entries gone. Missing/changed contexts disable **W**.
- Changes compare the full formatted summary, type and availability before UI
  truncation. A structure whose summary stays `{N fields}` can have changed
  children without highlighting the parent; no recursive change claim is made.
- Errors and unavailable values remain explicit. Existing function-entry
  `PrologueNotComplete` handling is retained; symbol breakpoint placement stays
  at its established address.

## Scope and evidence

This first integration covers the local native GUI. Remote MCP already exposes
expression evaluation; its separate GUI needs a later adapter and interaction
review (remote **V** currently means the hardware watch list).

No evaluator grammar or MCP schema changes are proposed. GUI expression watches
are refreshed observations; only **W** installs a hardware watchpoint.

Validation and preview links are recorded in [the integration journal](research/t19-integration.md).
