# Which tool do I reach for?

xodb does a lot. This page is the plain-language map; each section links to the
detailed docs. If you just want to try something, jump to
[Try it](#try-it).

## The short version

| I want to… | Use | You get |
| --- | --- | --- |
| Stop a program and look around | **Debugger** (breakpoints, stepping, Locals) | Source, stack, variables and registers at one moment |
| Catch who changes a value | **Watchpoint investigation** (**W** on a field) | Every write, with the code and stack that made it |
| Find where time goes | **Profile** (**P**) | Hot functions and flame graphs for the whole process |
| Understand why *some* calls to a function are slow | **Observation** (a recipe) | Every call timed, with its arguments, and fast vs slow compared |
| Open Python, Ruby or JVM logical stacks | **Logical frames** (`--open-frames FILE`, **L**) | Exact observation counts, source locations and collection provenance, separate from native stacks |
| Label JIT code in a native profile | **JIT evidence** (MCP import, then **I** in the profile) | Time-aware names, candidate citations and explicit ambiguity; raw PCs stay intact |
| Check whether a change made a function faster | **Repeated experiment** (`tools/experiments/run.py`) | Baseline vs changed vs unchanged control, several runs each, with honest spread ([details](OBSERVATION_EXPERIMENTS.md)) |
| Let an AI agent help | **MCP** (`--mcp` or `--session-socket`) | The same tools for an agent; you keep **F8** to take back control |
| Ask "what feeds this value?" or "what controls this call?" | **Static slice** (**S** on an instruction or source line; `slice_value` over MCP) | The parameters, values and branches that can reach it, with instruction and source citations and a trust label. Static possibilities, not an observed run ([details](SEMANTIC_QUERIES.md#in-the-debugger)) |

## What is an observation?

An observation records **every call to the functions you name** in a running
program, then lets you compare those calls afterwards.

- For each call, xodb keeps when it started and ended, which thread made it, its
  raw arguments and return value, and optionally the stack.
- The program keeps running. The kernel collects the calls, so the program isn't
  stopped for each one.
- A call that never finished (the program exited, or the capture ended) stays
  marked *incomplete*. xodb doesn't guess its duration.
- The result is saved as an `.xoi` file that you can reopen later, in a terminal,
  in the GUI or from an agent, without the original program.

The typical use: pick a duration threshold, and xodb splits the calls into
**fast** and **slow** groups. It shows how their arguments and timing differ,
and every number links back to the raw records it came from.

In one line: *"time every call to X, keep the evidence, and show me what's
different about the slow ones."*

## Profiles vs observations

| | **Profile** (`.xoc`, **P**) | **Observation** (`.xoi`) |
|---|---|---|
| Question | "Where does the program spend its time?" | "What happened in *each call* to X, and why are some slow?" |
| How | Sampling: a snapshot of the stack many times a second | Tracing: a probe on every entry and return of chosen functions |
| Covers | The whole program, with no setup | Only the functions you list |
| Basic unit | A stack sample, one moment | A call, start to finish |
| You get | Hot functions, flame graphs, an estimated share of time | Exact per-call durations, arguments, return values, counts, incomplete calls |
| Arguments | No | Yes, raw values per call |
| Misses | Short or rare calls between samples | Anything you didn't list |
| Compare | Whole profiles against each other | Calls against calls: fast vs slow groups |
| Cost | Low and steady | Grows with how often the function is called |

**They work together:**

1. **Profile first** to find the hot spot: "this function is 40% of the time".
2. **Observe it** to learn why: "half the calls take 5 µs, half take 4 ms, and
   the slow ones get the big input".
3. **Associations** tie the two together. They show the CPU samples, system calls
   and memory allocations that happened *during* the slow calls. That's "these
   overlapped", not proof that one caused the other. A saved `.xoi` keeps that
   evidence, so you can reopen and re-analyse it later without the program.
4. **Experiments** repeat the whole thing across builds: "did my change make the
   slow calls faster, or is that just run-to-run noise?"

**Rule of thumb:** profile when you don't know where to look; observe when you
know which function matters and want to know which calls are slow and why.

## Interpreted languages (Ruby, Python, Perl)

xodb debugs interpreters as the C programs they are. With a debug build of the
interpreter you can:

- break inside its native functions;
- read its internal structures by name;
- observe its native calls, e.g. how long each `sort` or array iteration takes.

What you see is the interpreter's own C code, plus, for Perl and CPython, the
script level:

- **Readable Perl values.** In Locals or **E**, an `SV *` shows as `IV 42`,
  `undef`, `PV "…"`, `AV (3 slots)` and so on, instead of raw union fields.
  Values that aren't meaningful yet (a brand-new element) say so rather than
  showing stale bits.
- **Readable Python values.** A `PyObject *` (or `PyListObject *`, `PyDictObject *`,
  …) shows as `int 42 (immortal)`, `str 'héllo' (refcnt 3)`, `list (8 items)`,
  `dict (2 items)`, `None`, `<Foo object>` and so on, with up to eight elements.
  Freed or overwritten objects and inconsistent headers are marked; no
  `__repr__` or other code runs in the target. Needs CPython DWARF types.
- **The script's stack at a native stop.** Agents ask `get_language_stack`
  (language `perl` or `python`) for sub/function names and file:line, read
  straight from the stopped interpreter without running any code in it. Each
  piece is tied to the native interpreter-loop frame it came from, and it says
  `partial` when a boundary can't be proven. For CPython the tie is proved by
  the activation's entry frame lying in that native frame's stack, so it works
  across threads, subinterpreters, generators and `coroutine.send()`, and on a
  stripped `/usr/bin/python3` 3.14 as well. See [CPython](PYTHON.md) and [Perl](PERL.md).

Logical stacks for Python, Ruby and the JVM are arriving as imports; see
[logical frames](LOGICAL_FRAMES.md).

## Try it

| Demo | Command | What to look at |
| --- | --- | --- |
| Watch a value change | see the M1 walkthrough in the [README](../README.md) | **W** on a field, **Space**, see who wrote it |
| Display an expression at each stop | launch any owned program with `xodb --break FUNCTION -- ./program` | **Shift+E**, enter an expression, **Return**; it follows the selected frame. **Shift+L** converts the selected watch between pinned and live. |
| Observe and browse calls | `xodb --browse-observation example-01.xoi` after the capture in [OBSERVATIONS.md](OBSERVATIONS.md#one-command-capture) | **]** / **[** move the threshold, **Tab** switches fast/slow, **E** shows the raw evidence |
| Inside Perl | `./scripts/demo-perl` | **Space**, **Shift+E** `val` and `av` (live rows that update every stop), then keep pressing **Space**: `val` undef ↔ not in scope, `av` 3 ↔ 4 slots |
| Inside CPython | `./scripts/demo-python` | **Space**, **E** `value` (list (8 items)), **E** `key` (str 'answer'), **E** `mp` (dict); in a second terminal `./scripts/demo-python stack` prints `record` ← `tick` ← `<module>` with file:line and the list's items |
| Inside Ruby | `./scripts/demo-cruby` | the `rb_ary_store` break |
| Profile | **P** in the GUI on any program | flame graph of where time goes |
| What feeds malloc's size? | `xodb --static-analysis DIR -- ./qx` (qx from `tests/fixtures/semq/qx.c`, DIR a built `tools/ghx` worker), stop in `qx_alloc` | click the `call` row, **S**, **Return**: `count` and `size` feed it, `flag` is irrelevant; **Tab** shows the `count > 4096` guard |
| Agent and human together | `xodb --session-socket ~/tmp/xs/s -- ./prog` | an agent drives; **F8** takes control back ([details](SHARED_SESSIONS.md)) |
| Debug a LoongArch64 program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against a LoongArch64 Linux host or QEMU loongarch64 | **Space** runs to the breakpoint. Instruction step, assembly, and hardware watches report unsupported. Remove the breakpoint before continuing |

## Where to go next

- [Observations: commands and limits](OBSERVATIONS.md)
- [Profiling](PROFILING.md) and [profile comparison](PROFILE_COMPARISON.md)
- [Shared sessions](SHARED_SESSIONS.md) and the [MCP overview](MCP_OVERVIEW.md)
- [Static analysis](SEMANTIC_QUERIES.md), [logical frames](LOGICAL_FRAMES.md),
  [themes](THEMES.md)

## Try logical frames

```sh
python3 tests/logical-frames/python_workload.py frames.jsonl frames-meta.json .5 10
xodb --open-frames frames.jsonl
```

Use **J/K** to select `fib`, then **Enter** to open its recorded source location.
The header shows the collection method and weight unit. **T** selects a thread;
**L** switches between logical evidence and the native workspace. These weights
count observations; they are not elapsed CPU time.

An agent can use `save_frames` to write `frames.xof`, then you can reopen it with
`xodb --open-frames frames.xof`. See [logical frame sessions](LOGICAL_FRAMES.md#session-and-gui-integration)
for MCP calls, JIT declarations and attachment to a native `.xoc` capture.

### Live display expressions

**E** adds a watch pinned to the current activation. **Shift+E** adds a live
expression, marked `~`, that evaluates in the selected frame after each stop and
frame selection change. An absent local shows `not in scope here`; the row stays
for the next applicable stop. Select a watch row and press **Shift+L** to convert
it between pinned and live while stopped. **W** still starts a separate write
investigation from the current value and address.

All watch rows share the existing limit of 16 expressions (256 bytes each).
They use the expression engine's existing bounds, with one stack and locals
lookup per context during a refresh. No values are evaluated while running or
on redraws without a changed stop, frame or watch list; running values are
labelled stale. Watches are GUI state; MCP's `evaluate_expression` remains an
explicit query rather than a stored display list.

For the Perl loop demo, run `scripts/demo-perl`, press **Space** to reach
`Perl_av_store`, then **Shift+E**, `val`, **Return**, and **Shift+E**, `av`,
**Return**. Add once, watch it update every iteration: **Space** reaches
`Perl_av_delete` (`val`: not in scope; `av`: four slots), then **Space** reaches
the next store (`val`: undef; `av`: three slots).

### Text editing and clipboard

Live rows that have never resolved an expression report an unknown-variable
error when the name cannot be found. This may be a typo, a macro without runtime
storage, or a name absent from the selected frame. After a row has resolved, a
later scope miss says `not in scope here`. While running, `stale: running` appears
before any retained value so a long preview cannot hide the marker.

In expression, breakpoint, memory/search, capture setup, save-path and threshold
fields, **Ctrl+V** inserts the Wayland clipboard at the cursor. **Middle-click**
in the field inserts the primary selection at the clicked position, when the
compositor supports it. **Return** still applies the field; paste never submits
it, resumes the target, or runs a shortcut.

Use **Left/Right**, **Home/End**, **Backspace/Delete** to edit. Hold **Shift** while
moving the cursor, or drag with the left mouse button, to select text. Selection
sets the primary selection. **Ctrl+C** copies the selection, or the whole field
when nothing is selected; inside a field it has no interrupt meaning. **Ctrl+U**
clears the field. **Up/Down** recall previous entries where history is available.
Function keys remain available while editing, including in capture setup:
**F5/F6** control execution without applying the edited rate, duration or filter.

Each transfer is limited to 4 KiB, then to the field's byte limit (usually 256;
capture numbers allow 10 digits and the thread filter 32 bytes). Truncation is
shown in the field. Newlines, controls, invisible format characters (including
bidi overrides/isolates, zero-width marks and BOM) and invalid UTF-8 are removed; numeric
capture fields also remove non-digits. Complete UTF-8 characters are retained.
A source that sends nothing times out after one second without changing the
field. Changing fields, closing/reopening an editor or losing keyboard focus
cancels an unfinished paste. Clipboard reads never block the interface.

For a video: `xodb --break change_value -- ./zig-out/bin/xodb-m1-fixture w`,
**Space**, **F10** to reach the function body, **Shift+E**, paste `amount` with
**Ctrl+V**, then **Return**. Use **Space** to reach the next call. Only the final
Return adds the live display.
