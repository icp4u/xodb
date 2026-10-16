# Dependency linter

`scripts/deps` reads the imports between source files under `src/`, puts each
file in a layer and checks which layer may import which. Violations that exist
today are listed in a baseline that may only shrink. Plan:
[ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) section 1.

## Running it

| Command | What it does |
|---|---|
| `scripts/deps check` | Exit 1 on a new violation, a stale baseline line, a new file in a cycle, a changed `cycle sizes:` line, an exceeded budget, an unmapped file or an unsafe narrow-integer source pattern. `-v` also lists unresolved includes. |
| `scripts/deps why A B` | Shortest import chain from A to B. A and B are each a file, a layer or a glob: `why model ui`, `why render runtime`, `why src/language/lua.zig src/model/session.zig`. |
| `scripts/deps rdeps FILE` | Every file that imports FILE, directly or through others (`--direct`: only direct). |
| `scripts/deps layers` | Edge counts between layers, and files per layer (`--all` includes edges inside a layer). |
| `scripts/deps cycles` | Every import cycle (strongly connected component) and its files. |
| `scripts/deps graph --json` | Files with layer and fan-in/fan-out, edges with kind, build modules, unresolved includes. |
| `scripts/deps baseline --write` | Rewrite `tools/deps/baseline` from today's tree. |
| `scripts/release-check portable --only deps,deps-selftest` | The gate steps. `deps` runs in every tier. |

The whole repository takes about half a second. Python 3 standard library only.

## What it reads

| Source | Edge kind | Resolved |
|---|---|---|
| `@import("x.zig")` in Zig | `import` | relative to the importing file |
| `@import("name")` without a path | `module` | node `module:name` (for example `build_options`); `std`, `builtin`, `root` are ignored |
| `@cInclude("x.h")` in Zig | `cinclude` | through the include directories of `build.zig`, then the file's directory; anything else is a system header |
| `#include "x.h"` in .c, .h, .cc, .inc | `include` | the file's directory, then its `src/*/Makefile` `-I` directories, then those of `build.zig` |
| `#include <x.h>` | `include` | the `-I` directories above, not the file's own; anything else is a system header |

An include that resolves nowhere is reported (`check -v`), not guessed. Today
there is one: the generated Wayland header that `src/platform/clipboard.c` uses.
Comments and Zig multiline strings are skipped.

## Narrow integer source check

`check` rejects a direct `@intFromBool(a) + @intFromBool(b)`. Each call returns
`u1`, so two true inputs overflow before a wider assignment can receive the
result. Widen an operand before the addition, for example
`@as(u8, @intFromBool(a)) + @intFromBool(b)`. Comments and string or character
literals are ignored. This is a deliberately small check for the crash pattern
found repeatedly in evidence decoders; bounds and explicit widening remain
required for other arithmetic on decoded integers.

## Configuration (`tools/deps/`)

| File | Line format | Meaning |
|---|---|---|
| `layers` | `GLOB LAYER` | First match wins. `*` stays in one directory, `**` crosses directories. Every source file must match. |
| `rules` | `deny NAME FROM... -> TO...` or `only NAME FROM... -> TO...` | FROM and TO are layers or path globs. `deny`: FROM must not reach TO. `only`: FROM may reach only TO and itself. |
| `baseline` | see below | Violations allowed because they exist today. Written by `baseline --write`. |
| `budgets` | `FILE LIMIT` | Most files that may import FILE directly. |

Every rule is checked directly and transitively. FROM reaching a forbidden file
through other files counts, so a re-export module cannot launder an edge. The
violation is reported once, on the direct edge where the chain leaves FROM.

## Reading a failure

| Output | Meaning | What to do |
|---|---|---|
| `+ a -> b  [rule]` | New direct edge breaking `rule`. | Remove the import, or move the code. |
| `+ a -> b  [rule transitive]` then `chain: a -> b -> ... -> x` | `a` is in the rule's FROM; `b` is allowed, but `b` reaches forbidden `x`. The culprit is the edge `a -> b`. | Run `scripts/deps why b x` to see the chain; cut it at `a -> b` or further along. |
| `+ file  [cycle]` then `cycle: file -> ... -> file` | `file` is now in an import cycle. | Break one edge of the printed cycle. |
| `import cycles grew or merged` with `- cycle sizes: ...` / `+ cycle sizes: ...` | Two cycles joined, or one grew, even if every file was in some cycle before. The grown cycle's first files are listed. | Find the new import (`git diff`, `scripts/deps why A B`) and remove it. |
| `import cycles shrank or split` | You broke or split a cycle. | Replace the `cycle sizes:` line with the printed `+` line. |
| `- line` under "no longer occur" | You fixed something. | Delete the line from `tools/deps/baseline` in the same diff. |
| `FAIL f has N direct importers, budget M` | Fan-in grew past the budget. | `scripts/deps rdeps --direct f`; import something narrower. |
| `note: f has N direct importers, under its budget M` | Fan-in shrank. | Lower the budget to N. |
| `unmapped file` | A new directory or top-level file. | Add a glob to `tools/deps/layers`. |

If a new violation is intended, `scripts/deps baseline --write` adds it; the
added line is visible in the diff and gets argued in review.

## Shrinking the baseline

1. Pick a rule from the table below and list its lines: `grep '\[mcp-no-ui' tools/deps/baseline`.
2. `scripts/deps why FROM TO` on one line shows the chain.
3. Remove the import, run `scripts/deps check`, delete the lines it prints with `-`.

A direct edge usually removes many transitive lines with it. All 107
`ui-no-mcp transitive` lines come from 12 edges into mcp from below it (model 6,
`observe/` 5, `profile/recorded_view_test.zig` 1): ui reaches mcp through those.

## Current numbers (2026-10-14)

579 source files, 2391 edges, 27 layers, 8 rules.

| Rule | Says | Direct | Transitive |
|---|---|---|---|
| `model-no-frontends` | model must not reach ui, mcp, render, platform, memdefrag | 25 | 2 |
| `ui-no-mcp` | ui must not reach mcp | 2 | 107 |
| `mcp-no-ui` | mcp must not reach ui | 4 | 7 |
| `render-leaf` | render reaches only platform, common, c_ui, config | 1 | 8 |
| `platform-leaf` | platform reaches only common, c_ui | 4 | 4 |
| `providers-no-session` | language, semq, debug, binary must not reach `src/model/session.zig` | 12 | 31 |
| `runtime-alone` | src/runtime includes only src/runtime (and system headers) | 3 | 0 |
| `evidence-leaf` | src/evidence (pcap reader, decoders, clocks, socket join) reaches only common: no session, frontends or engine C | 0 | 0 |
| cycles | files in an import cycle, plus one `cycle sizes: 75 30 13 8 2 2 2 2` line | 134 files in 8 cycles | |
| **baseline total** | | **344 lines** | |

| Cycle | Files | Layers in it |
|---|---|---|
| 1 | 75 | model (incl. `session.zig`), language, profile, observe, debug, frames, mcp, semq, target, config |
| 2 | 30 | model views, ui panes, `mcp/server.zig`, `mcp/remote.zig` |
| 3 | 13 | ui/overview |
| 4 | 8 | platform |
| 5 to 8 | 2 each | model, profile, redot, target |

| Budget | Direct importers today |
|---|---|
| `src/model/session.zig` | 96 (196 transitive) |
| `src/target/linux.zig` | 57 |
| `src/target/runtime.zig` | 44 |

Layer edge counts that the plan tracks (distinct file pairs, so lower than raw
`@import` counts): model to ui 17, model to mcp 6, model to render and platform
1 each, mcp to ui 4, ui to mcp 2, language to model 56, semq to model 2, debug to
model 2. `scripts/deps layers` prints the full table.
