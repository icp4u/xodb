# Which tool do I reach for?

xodb does a lot. This page is the plain-language map; each section links to the
detailed docs. If you just want to try something, jump to
[Try it](#try-it).

## The short version

| I want to… | Use | You get |
| --- | --- | --- |
| See what is using the machine | **System overview** (`--overview`) | Live CPU, memory, disk, network and processes; unknown values show reasons. **L** opens files, **F** profiles, **Enter** attaches after a cost/access confirmation. `--session-socket PATH` shares the same cache with observer-only MCP clients. |
| Watch a process's memory get defragmented (THP) | **Memory map** (`xodb --overview --panel memory_map`, **M**; **m** on a Processes row) and the terminal twin `xodb --memdefrag` | A Windows 9x Disk Defragmenter, an MS-DOS DEFRAG screen or a modern grid of 2 MiB cells: THP, 4 KiB, file, swapped, unknown (hatched); collapses, splits and page-state changes stay distinct; coverage, buddy fragmentation and system-wide THP/compaction activity, with the real refresh period ([details](MEMDEFRAG.md)) |
| Zoom into one process's pages, down to single 4 KiB pages | **Memory map, deep look** (**t** to cycle, or `--look deep`) | Up to 65,536 cells from 2 MiB down to 4 KiB: wheel zoom at the pointer, drag to pan, **0** fit, **[ ]** VMA to VMA, a minimap of the whole address space; pending, unknown and the three change kinds stay distinct; hover shows range, VMA, state bits and the VMA's NUMA totals ([details](OVERVIEW.md#deep-map)) |
| Inspect huge pages and memory fragmentation | MCP **get_memory_map**, **get_thp_state**, **get_fragmentation** | Pinned process maps, page states and system-wide buddy/THP counters; unknown and partial coverage remain explicit ([details](OVERVIEW.md#memory-page-observations-over-mcp)) |
| Stop a program and look around | **Debugger** (breakpoints, stepping, Locals) | Source, stack, variables and registers at one moment |
| Switch between native and language views | **Tab** or click **Regs / C/C++ / Python / Perl / Lua / JS** | Detected runtime tabs show version, layout proof and logical stack evidence; selection is shared with MCP |
| Catch who changes a native value | **Watchpoint investigation** (**W** on a C/C++ field) | Every write, with the code and stack that made it |
| Find where time goes | **Profile** (**P**) | Hot functions and flame graphs for the whole process |
| Understand why *some* calls to a function are slow | **Observation** (a recipe) | Every call timed, with its arguments, and fast vs slow compared |
| Open Python, Ruby or JVM logical stacks | **Logical frames** (`--open-frames FILE`, **L**) | Exact observation counts, source locations and collection provenance, separate from native stacks |
| Read Lua locals by name | **Lua** tab, click a Lua frame, **E** `count`, **Return** | Active locals and upvalues from this stop; innermost lexical binding wins; no target execution |
| Read Lua values and coroutine stacks at a native stop | **Lua view** (`scripts/demo-lua`, **E** `L`; MCP `get_language_stack`) | Bounded values and source lines from stopped memory; separate coroutine observations ([details](LUA.md)) |
| Label JIT code in a native profile | **JIT evidence** (MCP import, then **I** in the profile) | Time-aware names, candidate citations and explicit ambiguity; raw PCs stay intact |
| Check whether a change made a function faster | **Repeated experiment** (`tools/experiments/run.py`) | Baseline vs changed vs unchanged control, several runs each, with honest spread ([details](OBSERVATION_EXPERIMENTS.md)) |
| Let an AI agent help | **MCP** (`--mcp` or `--session-socket`) | The same tools for an agent; you keep **F8** to take back control |
| See which files are being read, written, leaked or held after deletion, right now | **lsof-top** (`xodb --lsof-top`, a terminal view) | Top files by bytes/s, processes by fd churn and growth, leak watch, deleted-but-open files and live per-process fd tables, from unprivileged `/proc` polling ([details](LSOF_TOP.md)) |
| Explore open files visually | **Files & IO** (`xodb --overview --panel files`) | Churn heatmap, seekable progress, fd-growth sparklines and deleted holders. **L** drills in from Processes; exact events require explicit host-cost confirmation ([details](OVERVIEW.md#files-and-exact-events)) |
| Ask which process holds a file, or count one process's descriptor IO | **FD observers over MCP** (`get_fd_activity`, `who_has_open`, `get_fd_leaks`, `get_deleted_open`) | Shared cached polling; exact events require explicit control and slow host-wide syscalls while active. Coverage, age, loss and cost accompany the data ([details](MCP_FD.md)) |
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

## Interpreted languages (Ruby, Python, Perl, JavaScript, Lua)

xodb debugs interpreters as the C programs they are. With a debug build of the
interpreter you can:

- break inside its native functions;
- read its internal structures by name;
- observe its native calls, e.g. how long each `sort` or array iteration takes.

The right pane starts with **Regs** and **C/C++** (native locals). Once a
stopped-memory reader verifies a runtime, its tab appears. **Tab** cycles the
visible tabs; clicking a tab selects it. The version and layout proof appear
above that runtime's logical stack, including explicit reasons when the stop
has no proved language frame. Selection survives stops and stays local to each
debugged process. `get_language_tabs` reads this state; a controller holding the
shared-session lease uses `select_language_tab` with `generation` and `tab`.
Tab selection does not change registers or resume the target. The cycle goes
from C/C++ through each available language tab, then Regs; reaching Regs can
take more than one press. A detected runtime that cannot be read shows its
reason below the tabs. A `*` marks a language segment offered for the selected
native frame. Clicking or pressing **j/k** in Stack preserves C/C++ or Regs;
only an already open language pane follows a unique language offer.

Below the logical stack, **Native frame #N** lists that language's decoded
objects from the selected C/C++ frame (`av`/`sv`, `L`, or a Node probe's
`value`, for example). Scroll over this section to see more objects; scrolling
over the stack moves its rows separately. Click **Native frame #N [-]** to
collapse it and give the logical stack more room; **[+]** expands it. These are
native variables, not logical locals. Until named logical locals arrive for a runtime, the pane says
**Variables by name / Not yet for ...**.

Click a logical frame to highlight its proved native **segment** anchor, or click
a native frame to offer matching language segments. A segment link does not
prove a one-to-one pairing of every script activation and native frame. Rows
without a proved anchor stay partial and leave the native selection alone.
Distinct coroutine segments remain separate. Frame selections are scoped to
the retained stop; a new stop clears them while keeping the chosen tab.
`select_native_frame` and `select_language_frame` expose the same selection to
MCP controllers. Observer clients read it with `get_language_tabs`.

Use the anchor actually reported by the reader: on some debug Lua builds it
is `luaD_callnoyield`, while xodb cannot recover the `L` argument at
`luaV_execute`. Optimized entry-value recovery may require more DWARF support.
Adjacent native frames are never assumed to share a state.

Try `scripts/demo-lua`, press **Space**, then **Tab** to reach **Lua**.
For JavaScript, run `scripts/demo-node`, press **Space**, then **Tab** to **JS**.
In **Lua**, click a Lua logical frame to read its active named locals and closure
upvalues. Scroll over the lower pane to page through bindings. **E**, a bare name
such as `count`, then **Return** reads the innermost active binding at this stop;
outer locals with the same name and upvalues remain distinct rows. Values expire
when execution resumes, and unavailable names or slots have explicit reasons.
Calls, operators and implicit globals are refused; no Lua code runs. Unnamed
extra arguments have a `(vararg) ×N` row; it has no expression name or address.

In **Perl**, click a subroutine logical frame to read its active `my`/`state`
bindings and captured outer pad entries. **E** accepts a sigil-name such as
`$value`, `@array` or `%hash`. In `scripts/demo-perl`, press **Space**, **Tab** to
Perl, select `main::store_answer`, then **E**, `$value`, **Return** to read `IV 42`.
Recursion uses the selected activation's pad. Eval/try/format/XS frames, fields,
missing names and unproved storage show a reason. No magic or Perl code runs.
In **Python**, select a logical frame for its fast locals, cells and free
variables. Try `scripts/demo-python`, **Space**, **Tab** to Python, select `tick`,
then **E**, `round`, **Return**. Deleted names and module/class mapping locals
show a reason. `E:` marks the expression result and its named row is labelled.
In **JS**, select a proved interpreted frame to browse **CONTEXT STORAGE**.
These are retained context slots: lexical visibility is unproved and stack-only
names are not shown. A shadowed lexical name may have a different value.
**E** refuses bare names with `JavaScriptLexicalUnproved`; it does not guess from
an outer context. See [JavaScript](JAVASCRIPT.md#context-storage-in-the-javascript-pane).
In **Ruby**, select a logical frame for VM-stack locals and escaped closure
environments. **E** accepts a bare local/capture name; the closest lexical scope
wins. See [Ruby](RUBY.md) for the initial supported revision and explicit refusals.
**E** in **C/C++** still uses the
native expression/watch view. In **Lua**, **Python**, **Perl** or **Ruby**, click a named
binding then **W**, or use **Shift+E** with a local name (`$name` in Perl), to
compare complete bounded scalar values at each stop.
**V** opens the runtime watch list; changed rows show old and new values. Storage
is resolved again after resume/GC. These watches observe stops; they do not
interrupt a running process. In **JS**, **W** watches only an explicitly selected
context-storage row; bare-name **Shift+E** stays refused and lexical visibility
remains unproved.
See [Lua watches](LUA.md#runtime-watches), [Python watches](PYTHON.md#runtime-watches)
[Perl watches](PERL.md#runtime-watches), [Ruby watches](RUBY.md#stopped-value-watches),
and [JavaScript watches](JAVASCRIPT.md#comparing-context-values-at-stops) for scope
and comparison limits.

What you see is the interpreter's own C code, plus, for Perl, CPython, CRuby and V8, the
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
  (language `perl`, `python`, `javascript`, `lua` or `ruby`) for sub/function names and file:line, read
  straight from the stopped interpreter without running any code in it. Each
  piece is tied to the native interpreter-loop frame it came from, and it says
  `partial` when a boundary can't be proven. For CPython the tie is proved by
  the activation's entry frame lying in that native frame's stack, so it works
  across threads, subinterpreters, generators and `coroutine.send()`, and on a
  stripped `/usr/bin/python3` 3.14 as well. See [CPython](PYTHON.md) and [Perl](PERL.md).
- **Readable JavaScript values.** A DWARF-identified V8 `Local<Value>` or
  internal `Tagged<T>` shows numbers, strings, bounded arrays/objects, function
  names and class names. The JavaScript stack includes columns when its code
  identity and source table are proved. No getters, coercions, or target code
  run. Support is deliberately tied to verified V8 layouts; see
  [JavaScript](JAVASCRIPT.md) for supported builds and partial results.

- **Readable Lua values.** `TValue *` and `lua_State *` previews cover PUC Lua
  5.4.9 and 5.2.4 with DWARF. Lua stacks keep coroutines separate, report source
  lines and C boundaries, and mark unknown names and native alignment partial.
  Try `scripts/demo-lua`, **Space**, then **E**, `L`, **Return**.
  Interrupted native I/O frames retain lower Lua state evidence; ambiguous state
  arguments appear as separate segments. See [Lua](LUA.md).

- **CRuby frames and locals.** `scripts/demo-cruby`, **Space**, choose **Ruby**,
  select **tick**, then **E**, `round`, **Return**. Native `VALUE` previews and
  named stack/escaped-environment bindings are read without target calls.
  The initial exact-revision DWARF profile and refusals are in [Ruby](RUBY.md).

Imported logical frames, including JVM exports, remain separate evidence; see
[logical frames](LOGICAL_FRAMES.md).

## Try it

| Demo | Command | What to look at |
| --- | --- | --- |
| Watch a value change | see the M1 walkthrough in the [README](../README.md) | **W** on a field, **Space**, see who wrote it |
| Display an expression at each stop | launch any owned program with `xodb --break FUNCTION -- ./program` | **Shift+E**, enter an expression, **Return**; it follows the selected frame. **Shift+L** converts the selected watch between pinned and live. |
| Observe and browse calls | `xodb --browse-observation example-01.xoi` after the capture in [OBSERVATIONS.md](OBSERVATIONS.md#one-command-capture) | **]** / **[** move the threshold, **Tab** switches fast/slow, **E** shows the raw evidence |
| Inside Perl | `./scripts/demo-perl` | **Space**, **Shift+E** `val` and `av` (live rows that update every stop), then keep pressing **Space**: `val` undef ↔ not in scope, `av` 3 ↔ 4 slots |
| Inside CPython | `./scripts/demo-python` | **Space**, **E** `value` (list (8 items)), **E** `key` (str 'answer'), **E** `mp` (dict); in a second terminal `./scripts/demo-python stack` prints `record` ← `tick` ← `<module>` with file:line and the list's items |
| Compare Lua values at each stop | `./scripts/demo-lua` | **Space**, **Lua**, select the loop frame at `lua-demo.lua:9`, **Shift+E** `value` **Return**, then **Space**. **V** shows changes; table/function values are explicitly unavailable. |
| Inside CRuby | `./scripts/demo-cruby` | **Space**, **Ruby**, select **tick**, **Shift+E** `round` **Return**, then **Space**. **V** shows stopped scalar changes with the frame-lifetime caveat; **W** on a named local retains that declaration. |
| Compare JavaScript context values | `./scripts/demo-node` | **Space**, **JS**, select **inspect**, click **round** under **CONTEXT STORAGE**, then **W**. Continue with **Space** and inspect **V**; lexical visibility and activation lifetime remain unproved. |
| Inside Node.js | `./scripts/demo-node` | **Space**, **E** `value`, **Return**; keep pressing **Space** for numbers, strings, arrays, objects, a class and a function. `./scripts/demo-node stack` prints the physical JavaScript frames. |
| Profile | **P** in the GUI on any program | flame graph of where time goes |
| What feeds malloc's size? | `xodb --static-analysis DIR -- ./qx` (qx from `tests/fixtures/semq/qx.c`, DIR a built `tools/ghx` worker), stop in `qx_alloc` | click the `call` row, **S**, **Return**: `count` and `size` feed it, `flag` is irrelevant; **Tab** shows the `count > 4096` guard |
| Live open files | start the owned workloads in [LSOF_TOP.md](LSOF_TOP.md#try-it), then `xodb --lsof-top --redact --pid PIDS` | **1** files advancing, **3** the leaker growing, **4** the deleted file's pinned bytes, **Enter** on any row to drill in |
| THP defrag, live | `cc -O2 -o ~/tmp/mdf tests/memdefrag-fixture.c && ~/tmp/mdf`, then `xodb --overview --memmap-pid PID --redact` (or `xodb --memdefrag --pid PID`) | type `collapse` into the fixture four times: cells turn dark blue with a white ring and **% Complete** climbs; `split` draws one red-edged cell. **t** cycles Win9x, DOS, modern and deep |
| Deep map at 4 KiB, live | the same fixture, `xodb --overview --memmap-pid PID --look deep --redact`; type `collapse` once | wheel up over the fixture's first block until the header says **4 KiB cells**: it is THP; type `split` and that block's 512 pages flash an orange edge for one refresh, then read 4 KiB anonymous on hover |
| Visual file activity | start the owned workloads in [LSOF_TOP.md](LSOF_TOP.md#try-it), then `xodb --overview --panel files --redact` | Watch churn and offset progress, use **[ ]** for Leak watch and Deleted, **Enter** to scope a process. **E** explains exact capture cost before starting |
| Agent and human together | `xodb --session-socket ~/tmp/xs/s -- ./prog` | an agent drives; **F8** takes control back ([details](SHARED_SESSIONS.md)) |
| Debug a LoongArch64 program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against a LoongArch64 Linux host or QEMU loongarch64 | **Space** runs to the breakpoint. Assembly is shown when xodb was built with `-Dcapstone=vendored` after `scripts/build-capstone`; with the default system Capstone, MCP `disassemble` reports `DisassemblerUnavailable` and the assembly pane stays empty. Instruction step and hardware watches report unsupported. Remove the breakpoint before continuing |
| Debug a ppc64le program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against a little-endian ELFv2 POWER host or QEMU ppc64le | **Space** runs to the breakpoint. A function breakpoint stops at the ELFv2 local entry when the symbol has one. Assembly is shown with the system Capstone. Instruction step works where `PTRACE_SINGLESTEP` stops. Hardware watches report unsupported. Remove the breakpoint before continuing |
| Debug through gdbserver or QEMU | `xodb --gdb-remote 127.0.0.1:2345` after preparing the stub | Inspect raw registers/memory and use address breakpoints; see [GDB_REMOTE.md](GDB_REMOTE.md) for supported targets and QEMU interrupt limits |

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
