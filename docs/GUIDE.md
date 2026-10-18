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
| Find a value anywhere in a stopped process (a score, a name, a pointer) | **Memory** (**M**, **W** all writable, **/** `text:` or `hex:`; MCP `search_memory` with `regions` or `ranges`) | One search over every writable mapping (or a list of ranges), exact hits and readable/unreadable bytes per range ([details](MEMORY_REGISTERS.md)) |
| Inspect huge pages and memory fragmentation | MCP **get_memory_map**, **get_thp_state**, **get_fragmentation** | Pinned process maps, page states and system-wide buddy/THP counters; unknown and partial coverage remain explicit ([details](OVERVIEW.md#memory-page-observations-over-mcp)) |
| Stop a program and look around | **Debugger** (breakpoints, stepping, Locals) | Source, stack, variables and registers at one moment |
| Run the GUI on a Mac | **Native macOS client** (`--connect HOST:PORT`) | AppKit/MoltenVK remote-client panels; local launch/attach and overview are not yet available ([build and limits](MACOS.md#run-the-native-client-on-a-mac)) |
| Debug a very large program (a 3 GB game engine, an ML library) | Up to 1 GiB an image and 4 GiB in all it just works: those are the defaults. Beyond that, `--image-limit 3200M --image-total-limit 7G`, or `symbols.image_bytes` and `symbols.image_total_bytes`; a refused image says the values to rerun with | Named frames with source; an image over budget is named with its size, the budget and what to raise ([large images](LARGE_IMAGES.md#full-image-budgets)) |
| Identify a macOS binary and look up its symbols | MCP **get_macho_image** on a mapped Mach-O file ([details](MACHO.md#try-it)) | UUID, architecture and platform, slices of a universal file, segments, and a symbol by name or address. A file reader only: no macOS process is debugged |
| Switch between native and language views | **Tab** or click **Regs / C/C++ / Python / Perl / Lua / JS / Ruby / Elisp / GDScript** | Detected runtime tabs show version, layout proof and logical stack evidence; selection is shared with MCP |
| Catch who changes a native value | **Watchpoint investigation** (**W** on a C/C++ field) | Every write, with the code and stack that made it |
| Find where time goes | **Profile** (**P**) | Hot functions and flame graphs for the whole process |
| Understand why *some* calls to a function are slow | **Observation** (a recipe) | Every call timed, with its arguments, and fast vs slow compared |
| Open Python, Ruby or JVM logical stacks | **Logical frames** (`--open-frames FILE`, **L**) | Exact observation counts, source locations and collection provenance, separate from native stacks |
| See which GDScript function a Godot or Redot game is in | **GDScript** tab (`REDOT=ENGINE scripts/demo-redot`; MCP `get_language_stack` with `gdscript`) | The script call stack with `res://` path and line, each level paired with its native engine frame; read from a running debug-enabled game, no engine debugger needed ([details](GDSCRIPT.md)) |
| Read a GDScript function's locals and its node's members | **GDScript** tab, click a level, **E** `inventory["sword"].damage`, **Return** (`scripts/demo-redot values`; MCP `get_language_locals`, `evaluate_language_expression`) | Parameters, locals, `self` and script members with Variant previews: containers with size and first elements, objects with class, id, node path and script; paths step into them. Read from memory, nothing evaluated ([details](GDSCRIPT.md#values)) |
| Read Lua locals by name | **Lua** tab, click a Lua frame, **E** `count`, **Return** | Active locals and upvalues from this stop; innermost lexical binding wins; no target execution |
| Read Lua values and coroutine stacks at a native stop | **Lua view** (`scripts/demo-lua`, **E** `L`; MCP `get_language_stack`) | Bounded values and source lines from stopped memory; separate coroutine observations ([details](LUA.md)) |
| Label JIT code in a native profile | **JIT evidence** (MCP import, then **I** in the profile) | Time-aware names, candidate citations and explicit ambiguity; raw PCs stay intact |
| Check whether a change made a function faster | **Repeated experiment** (`tools/experiments/run.py`) | Baseline vs changed vs unchanged control, several runs each, with honest spread ([details](OBSERVATION_EXPERIMENTS.md)) |
| Let an AI agent help | **MCP** (`--mcp` or `--session-socket`) | The same tools for an agent; you keep **F8** to take back control |
| See which files are being read, written, leaked or held after deletion, right now | **lsof-top** (`xodb --lsof-top`, a terminal view) | Top files by bytes/s, processes by fd churn and growth, leak watch, deleted-but-open files and live per-process fd tables, from unprivileged `/proc` polling ([details](LSOF_TOP.md)) |
| Find out whether the microwave is killing your Wi-Fi | **Burrito mode** (`xodb --burrito`; `sudo xodb --burrito --radio wlan1 --phases 30,60,30`; **W** Radio panel in `--overview`) | The whole 2.4 GHz band from a spare spectral-capable card (a USB AR9271), the verdict in words ("microwave-like interference: 60 Hz pulsing, ~48% duty"), the blast radius per channel ("channels 6-13 blasted, 1-5 clean"), traffic per channel from a second spare card, and (with `--ping`) your link's ping loss while it ran. Receive-only; an in-use card is only read ([Is it the microwave?](#is-it-the-microwave), [details](RADIO.md)) |
| Show this machine off, fetch-style | **xodbfetch** (`xodb --fetch` in a terminal; **N** in `--overview`) | A fastfetch-format card (logo, `user@host`, `Key: value` lines, colour blocks) that prints and exits, or lives in the overview with the real distro logo, sparklines and ticking values; `--redact` hides names, **B** runs on-demand benchmarks ([details](FETCH.md)) |
| Explore open files visually | **Files & IO** (`xodb --overview --panel files`) | Churn heatmap, seekable progress, fd-growth sparklines and deleted holders. **L** drills in from Processes; exact events require explicit host-cost confirmation ([details](OVERVIEW.md#files-and-exact-events)) |
| Find paths holding open handles and sampled IO | **FD Treemap** (`xodb --overview --panel treemap`) | **B** opens; click zooms, **Backspace** goes up, **L** opens a sampled holder. **E** stops default live tracing (~11% host cost). Area is handle count ([details](FD_TREEMAP.md)). |
| Compare parent and child descriptors | **Parent/Child FDs** (`xodb --overview --panel inheritance`) | **I** opens the polling comparison; inspect child CLOEXEC flags, click for its Files table. A sampled match does not prove inheritance. |
| See shared files and IPC pulse across processes | **FD Graph / Galaxy** (`sudo -E xodb --overview --panel galaxy`) | Default live syscall tracing (~11% host cost); **E** switches to polling, **G/Y** switch graph/galaxy, click to focus, **L** opens Files. In the galaxy, processes are stars in nebulae, shared descriptors are threads, and bytes run along them as bright dots; `--galaxy-demo 150` shows a synthetic one. Inode joins are sampled; unknown bytes and loss stay visible ([details](OVERVIEW.md#descriptor-graph-and-galaxy)) |
| Ask which process holds a file, or count one process's descriptor IO | **FD observers over MCP** (`get_fd_activity`, `who_has_open`, `get_fd_leaks`, `get_deleted_open`) | Shared cached polling; exact events require explicit control and slow host-wide syscalls while active. Coverage, age, loss and cost accompany the data ([details](MCP_FD.md)) |
| See a packet capture beside a CPU capture, and which process owned each flow | **Network evidence** (`xodb --open-pcap trace.pcapng --open-capture run.xoc`; MCP `list_streams`, `query_stream`, `correlate`) | pcap/pcapng read offline with loss counters and undecoded records kept; a `net` lane in the profile timeline when the clocks are aligned; each packet joined to the captured process's socket with its basis (exact, sampled, inferred, none) ([details](NETWORK_EVIDENCE.md)) |
| Ask "what feeds this value?" or "what controls this call?" | **Static slice** (**S** on an instruction or source line; `slice_value` over MCP) | The parameters, values and branches that can reach it, with instruction and source citations and a trust label. Static possibilities, not an observed run ([details](SEMANTIC_QUERIES.md#in-the-debugger)) |

## Debugger keys that change process state

| Action | Key |
| --- | --- |
| Detach and preserve the target (or its shared family in Processes) | **Shift+D** |
| Quit the debugger; kill owned launches, preserve attached processes | **Shift+Q** |
| Restart an owned launch | **F4** |
| Continue or interrupt | **Space**, **F5** or **F6** |
| Cancel an edit or close the current panel | **Esc** |

Plain **d** and **q**, including Caps Lock, do not detach or quit. Shifted letters
remain text while an editor has focus. **Esc** in the main workspace does not
quit. **W** creates a watch investigation; it does not write the selected value.
Memory/register writes and continuing all process sessions are explicit MCP
operations, with no single-letter global GUI shortcut.

Ruby frame labels use the method's stored owner: `Owner#method` for instance
methods and `Owner.method` for class/module methods, including native calls
such as `Integer#digits`. Inherited and included methods retain their actual
owner. Aliases show `Owner#called (alias of original)`; `define_method` bodies
show `Owner#method (define_method)`. A nested block keeps its `block in` prefix.
Top-level `<main>` is shown without an owner diagnostic.
The reader calls no Ruby code to name a class. Anonymous or unreadable owners,
individual-object singleton methods, boxed class metadata and unsupported
frames keep the original label with **owner unproved**. MCP retains `name` and
adds nullable `qualified_name` and `name_reason`; source and frame diagnostics
remain separate.

Try `xodb --break rb_int_digits -- ruby -e '123.digits'` with a supported debug
Ruby. **Space**, then the **Ruby** tab: the native boundary is `Integer#digits`.

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

## Interpreted languages (Ruby, Python, Perl, JavaScript, Lua) and Go

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
debugged process. Python/Perl tabs marked **?** have a usable layout but no
stopped interpreter-frame witness; selecting one shows the quiet
"runtime not seen executing" explanation. This is normal for an idle
embedded interpreter. A language stack still requires evidence on its requested
thread. With several discoverable candidates, a sole image witnessed by stopped
threads supplies the process tab; none or several witnessed images are
ambiguous: the pane then shows "Several runtimes loaded" instead of a tab, while
MCP thread requests still answer. Python and Perl thread stacks, locals, expressions and frame watches
use the image witnessed on that thread. MCP tabs and decoded previews expose `identity: witnessed|unwitnessed`;
Python/Perl stack and named-local results carry `identity: witnessed`. Runtime
watches expose the observation's `runtime.identity` and generation separately
from their existing frame-lifetime explanation in `identity`. A watch without a
recoverable canonical frame retains its previous sample as history.

When two Python or Perl runtime images are executing, selecting a stopped
native thread (the thread list, or MCP `select_native_frame`) scopes that
language tab to the interpreter proven on that thread. The tab shows its
runtime version and thread ID, and `get_language_tabs` carries a nullable
`thread` on the scoped entry. Switching threads clears the previous tab
identity before the replacement is published. A thread running neither
interpreter keeps a selectable tab with an explicit no-frames reason, not
another thread's build ID. Before any thread has been selected the process
tab still reports the ambiguity; afterwards the scope stays on the last
selected thread across later stops until another thread is selected. Once
only one image is still executing, the ordinary process-wide tab returns.
This changes presentation scope only, not runtime identity or witness policy.

`get_language_tabs` reads this state; a controller holding the
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
`$value`, `@array` or `%hash`, and builtin paths such as `$hash{score}` or
`$list->[3]`. **Shift+E** retains a path watch that resolves fresh storage at
each stop; tied/magical or blessed storage is refused. In `scripts/demo-perl`, press **Space**, **Tab** to
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
wins. Builtin paths such as `items[0]` and `player["score"]` read raw Array/Hash
storage; custom methods and unsupported syntax refuse without running Ruby.
See [Ruby](RUBY.md) for the supported revision, limits and explicit refusals.
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
  (language `perl`, `python`, `javascript`, `lua`, `ruby`, `go` or `gdscript`) for sub/function names and file:line, read
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
  **E** `state`, `summary` or `values` shows Symbol, Hash and Array previews.
  The initial exact-revision DWARF profile and refusals are in [Ruby](RUBY.md).

- **Go goroutines.** `scripts/demo-go`, **Space**, choose **Go**: every
  goroutine with its state (`select`, `sync.Mutex.Lock`, `sleep`…), creation
  site and stack, read from the stopped runtime (go1.27.1, amd64). Strings,
  slices and structs preview in **C/C++**; maps, interfaces and channels say
  `partial: M2`. See [Go](GO.md).

Imported logical frames, including JVM exports, remain separate evidence; see
[logical frames](LOGICAL_FRAMES.md).

## Language views and hostile targets

The language views (Python, Perl, Lua, JavaScript, Ruby, Go, Emacs Lisp,
GDScript) do work you did not ask for by name. When a process stops, xodb:

- searches the mapped images for each runtime's marker symbol;
- opens and parses the file a mapping names, to learn that runtime's layout
  from its symbols and DWARF;
- reads target memory and interprets it through that layout.

Nothing in the target is executed, and the target is not written to. But the
target chooses which files its mappings name and what its memory holds, so
this is automatic work steered by the target.

The readers are bounded and refuse rather than guess: a build-id that does not
match, an unsupported version, unresolved runtime ambiguity, a chain that loops or
runs too long, an image over its budget. Those refusals protect you from
**honest mistakes and unbounded work**. They are not a defence against a file
crafted to attack the parser, and a target that hides its real runtime (in
anonymous memory, or behind rewritten file headers) and maps a second copy
can still leave that copy as the only discoverable candidate. Python and Perl
mark such a candidate **unwitnessed**, with "runtime not seen executing" on the
tab, unless a stopped thread's unwound interpreter frame lies in its exact
mapped image. It cannot report ready or supply a thread stack without that
evidence. The evidence itself comes from the target: a forged return address
or a thread parked inside the copy is enough to make the copy report ready,
so this guards against an accidental or lazy decoy, not a determined one; see
[PE support](PE.md).

If you do not trust the target, turn the views off in the
[preferences](PREFERENCES.md) file:

~~~json
{ "languages": { "enabled": false } }
~~~

or one at a time, `{ "languages": { "python": false } }`.
`--language-off NAME` (or `all`) does the same from the command line and may
be repeated.

| With a language off | Meaning |
| --- | --- |
| Its runtime is not searched for | No symbol scan for its marker |
| No file is opened or parsed for it | No layout or DWARF read on its behalf |
| No target memory is read for it | No stacks, locals, watches or value previews |
| Its tab is not offered | `get_language_tabs` says `disabled`, reason `LanguageDisabled` |
| Its MCP tools refuse | `LanguageDisabled`, not "runtime unavailable" |

Turning off one language leaves the others searching the same mapped files
for their own markers, which reads those files' symbol tables. Only
`"enabled": false` stops every search.

The switch covers every process of the session, including followed children,
cores and runtime-agent targets. The agent has no language code of its own: it
serves files and memory when the client asks, and the client does not ask.
With `--ssh` the switches are passed to the remote xodb. With `--connect` the
server owns the target, so start the server with the same setting.

What it does **not** do:

- Native debugging still parses files the target names: ELF symbols, DWARF,
  separate debug files, PE and PDB. Unwinding still reads target memory.
- Go, Ruby, JavaScript and Emacs Lisp types found in DWARF are still tagged
  while debug info is read; with the view off they display as plain native values.
- It is not a sandbox. xodb runs with your permissions in one process. For a
  target you believe is hostile, run xodb in a throwaway VM or container.

## Try it

| Demo | Command | What to look at |
| --- | --- | --- |
| Watch a value change | see the M1 walkthrough in the [README](../README.md) | **W** on a field, **Space**, see who wrote it |
| Display an expression at each stop | launch any owned program with `xodb --break FUNCTION -- ./program` | **Shift+E**, enter an expression, **Return**; it follows the selected frame. **Shift+L** converts the selected watch between pinned and live. |
| Observe and browse calls | `xodb --browse-observation example-01.xoi` after the capture in [OBSERVATIONS.md](OBSERVATIONS.md#one-command-capture) | **]** / **[** move the threshold, **Tab** switches fast/slow, **E** shows the raw evidence |
| Inside Perl | `./scripts/demo-perl` | **Space**, **Shift+E** `val` and `av` (live rows that update every stop), then keep pressing **Space**: `val` undef ↔ not in scope, `av` 3 ↔ 4 slots |
| Inside CPython | `./scripts/demo-python` | **Space**, **E** `value` (list (8 items)), **E** `key` (str 'answer'), **E** `mp` (dict); in a second terminal `./scripts/demo-python stack` prints `record` ← `tick` ← `<module>` with file:line and the list's items |
| Compare Lua values at each stop | `./scripts/demo-lua` | **Space**, **Lua**, select the loop frame at `lua-demo.lua:9`, **Shift+E** `value` **Return**, then **Space**. **V** shows changes; table/function values are explicitly unavailable. |
| Watch a Lua table field | `xodb --break luaB_print -- lua5.4 examples/lua-path-demo.lua` (debug Lua) | **Space**, **Lua**, select the Lua `print` caller, **Shift+E** `state.player.score` **Return**, then **Space**, **V**. Paths re-resolve replaced tables; metatables refuse. |
| Watch large Lua tables | `xodb --break luaB_print -- lua5.4 examples/lua-large-path-demo.lua` with debug Lua 5.4.9 | **Space**, **Lua**, select the print caller, **Shift+E** `module.player.score` **Return**, then **Space**, **V**. Lookup follows a bounded collision chain even with thousands of unrelated keys. |
| Watch Python container paths | `xodb --break builtin_print -- python3 examples/python-path-demo.py` with a supported debug interpreter | **Space**, **Python**, select **main**, **Shift+E** `state["player"]["score"]` **Return**, then **Space**, **V**. Dict/list/tuple paths re-resolve after replacement; no Python callbacks run. |
| Inside CRuby | `./scripts/demo-cruby` | **Space**, **Ruby**, select **tick**, **Shift+E** `round` or `values[0]` **Return**, then **Space**. **V** shows stopped scalar changes with the frame-lifetime caveat; **W** on a named local retains that declaration. |
| Inside a Rails model | `XODB_RAILS_GEMS=DIR ./scripts/demo-rails` (activemodel installed in DIR, see [Ruby](RUBY.md#rails-demo)) | **Space**, **Tab** to **Ruby**, click **checkout!**, **E** `attrs` **Return**; click **valid?** for `validations.rb:367`; back on **checkout!**, **Shift+E** `attrs[:line_items][0][:price]` **Return**, then **Space**. |
| Goroutines in a Go program | `./scripts/demo-go` | **Space**, **Go**, select **main.blocked** for a goroutine parked on a mutex; workers sit in `select`, one goroutine sleeps. **C/C++** shows `label`, `items` (len/cap) and `first` (struct). |
| Inside a Redot or Godot 4 game | `REDOT=ENGINE ./scripts/demo-redot` (a debug-enabled engine binary with DWARF) | **Space**, **Tab** to **GDScript**: `leaf` ← `step` ← `plan` ← `_process` with `res://` path:line, each over its native `GDScriptFunction::call` frame; click **plan**. In a second terminal `./scripts/demo-redot stack` prints the script stack and the labelled native stack |
| Script state of a Redot or Godot 4 game | `REDOT=ENGINE ./scripts/demo-redot values` | **Space**, **Tab** to **GDScript**, click **swing**: `weapon`, `power`, `damage`, `tags`, `aim`, then `self` and the player's members. **E** `inventory["sword"].damage` **Return** gives `12`. Click **_process** for one value of every Variant type. `./scripts/demo-redot locals` prints every level. [Walkthrough](DEMOS.md#redot--godot-script-state-of-a-running-game) |
| Inside Emacs Lisp | `./scripts/demo-emacs` | **Space**, **Elisp**, select **xodb-demo-checkpoint** for its label; nearby **let** rows show task titles, points and dynamic stage. **Space** visits two items, rendering, then a handled error. [Walkthrough](ELISP.md#try-the-demo). |
| Compare JavaScript context values | `./scripts/demo-node` | **Space**, **JS**, select **inspect**, click **round** under **CONTEXT STORAGE**, then **W**. Continue with **Space** and inspect **V**; lexical visibility and activation lifetime remain unproved. |
| Inside Node.js | `./scripts/demo-node` | **Space**, **E** `value`, **Return**; keep pressing **Space** for numbers, strings, arrays, objects, a class and a function. `./scripts/demo-node stack` prints the physical JavaScript frames. |
| Profile | **P** in the GUI on any program | flame graph of where time goes |
| Pseudo-C beside a stopped function | `GHIDRA_HOME=DIR ./scripts/demo-decompile` | **Space**, then **D**: retained pseudo-C beside source; click a pseudo line for its exact PC set, **D** returns to assembly, **S** asks semantic questions. [Walkthrough](DEMOS.md#pseudo-c-beside-a-live-stop) |
| What feeds malloc's size? | `xodb --static-analysis DIR -- ./qx` (qx from `tests/fixtures/semq/qx.c`, DIR a built `tools/ghx` worker), stop in `qx_alloc` | click the `call` row, **S**, **Return**: `count` and `size` feed it, `flag` is irrelevant; **Tab** shows the `count > 4096` guard |
| Live open files | start the owned workloads in [LSOF_TOP.md](LSOF_TOP.md#try-it), then `xodb --lsof-top --redact --pid PIDS` | **1** files advancing, **3** the leaker growing, **4** the deleted file's pinned bytes, **Enter** on any row to drill in |
| THP defrag, live | `cc -O2 -o ~/tmp/mdf tests/memdefrag-fixture.c && ~/tmp/mdf`, then `xodb --overview --memmap-pid PID --redact` (or `xodb --memdefrag --pid PID`) | type `collapse` into the fixture four times: cells turn dark blue with a white ring and **% Complete** climbs; `split` draws one red-edged cell. **t** cycles Win9x, DOS, modern and deep |
| Deep map at 4 KiB, live | the same fixture, `xodb --overview --memmap-pid PID --look deep --redact`; type `collapse` once | wheel up over the fixture's first block until the header says **4 KiB cells**: it is THP; type `split` and that block's 512 pages flash an orange edge for one refresh, then read 4 KiB anonymous on hover |
| Visual file activity | start the owned workloads in [LSOF_TOP.md](LSOF_TOP.md#try-it), then `xodb --overview --panel files --redact` | Watch churn and offset progress, use **[ ]** for Leak watch and Deleted, **Enter** to scope a process. **E** explains exact capture cost before starting |
| Agent and human together | `xodb --session-socket ~/tmp/xs/s -- ./prog` | an agent drives; **F8** takes control back ([details](SHARED_SESSIONS.md)) |
| Debug a RISC-V 64 program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against an RV64GC LP64D Linux host | **Space** runs to the breakpoint. The breakpoint is the two-byte `c.ebreak`. Assembly is shown with system Capstone. Instruction step and hardware watches report unsupported. Remove the breakpoint before continuing |
| Debug a LoongArch64 program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against a LoongArch64 Linux host or QEMU loongarch64 | **Space** runs to the breakpoint. Assembly is shown when xodb was built with `-Dcapstone=vendored` after `scripts/build-capstone`; with the default system Capstone, MCP `disassemble` reports `DisassemblerUnavailable` and the assembly pane stays empty. Instruction step and hardware watches report unsupported. Remove the breakpoint before continuing |
| Debug a ppc64le program from x86 | `xodb --runtime-ssh HOST --ssh-config FILE --runtime-agent /path/to/xodb-agent --break main -- /path/to/program` against a little-endian ELFv2 POWER host or QEMU ppc64le | **Space** runs to the breakpoint. A function breakpoint stops at the ELFv2 local entry when the symbol has one. Assembly is shown with the system Capstone. Instruction step works where `PTRACE_SINGLESTEP` stops. Hardware watches report unsupported. Remove the breakpoint before continuing |
| Debug through gdbserver or QEMU | `xodb --gdb-remote 127.0.0.1:2345` after preparing the stub | Inspect raw registers/memory and use address breakpoints; see [GDB_REMOTE.md](GDB_REMOTE.md) for supported targets and QEMU interrupt limits |
| Debug a process on a Mac | Start Apple's `debugserver` on the Mac's loopback, forward the port with `ssh -L`, then `xodb --gdb-remote 127.0.0.1:PORT` | Registers, memory, address breakpoints, watchpoints, Darwin signals, regions and images; no symbols or source yet. See [MACOS.md](MACOS.md) |

## The window is blank

GPU selection or driver loading can leave a window blank. xodb reports detected problems on stderr
in one line that starts with `xodb: vulkan:`. Run it from a terminal and look for that line.

| What stderr says | What happened | What to do |
|---|---|---|
| `driver ... failed to load` | A driver manifest names a library that Vulkan could not load; it may be stale or have a driver/library mismatch | Check the driver installation. A reboot hint appears only when the display GPU is also absent; if that followed a driver update, rebooting may help |
| `rendering on X, which is not the display GPU (drm 226:1, Y)` | The compositor draws with Y, but xodb is on X. Some pairs can hand frames across, some show nothing | `--vk-device Y`, or drop a `--vk-device` / `XODB_VK_DEVICE` you set earlier |
| `no Vulkan device matches "..."` | `--vk-device` or `XODB_VK_DEVICE` names nothing in the list printed below it | Use an index or a name from that list |
| nothing | No confirmed device mismatch or driver loading failure was detected; automatically selected software and devices without DRM nodes do not imply a mismatch | `--vk-list`, then try each device |

Three controls:

- `xodb --vk-list` prints every Vulkan device with its kind, DRM node, whether it can present to a
  window here, which one is the display GPU, and a `*` on the one xodb uses. It needs no target.
- `--vk-device INDEX|NAME` picks a device by its `--vk-list` index or by any part of its name
  (`--vk-device nvidia`, `--vk-device llvmpipe`). It works with `--overview` too.
- `XODB_VK_DEVICE=INDEX|NAME` does the same from the environment; the flag wins.

Without a request xodb uses the device behind the compositor's GPU (from the compositor's
linux-dmabuf feedback, matched to the device's DRM node). If the compositor does not say, or no
Vulkan device matches, it takes the first discrete GPU, then an integrated one, then anything
that can present. Indexes follow the driver's order, which can differ between sessions; names do not.

A device request that cannot be satisfied at startup exits with an error. After the renderer has
initialized successfully, a device that temporarily disappears causes retries while the debugger
retains its session and owned targets.

`llvmpipe` draws on the CPU and reaches any display, so `--vk-device llvmpipe` is a slow but safe
way to get a picture while a driver is broken.

## Seeing what xodb is doing

xodb writes its messages to stderr. Each has a level; you choose how much you see.

| Level | Flag | Shows |
|---|---|---|
| error | `-qq` | failures only |
| warn | `-q` | plus things you should act on |
| info (default) | none | what a normal run prints |
| debug | `-v` | plus decisions: why a Vulkan device was chosen, frames deferred while the window is hidden, the sidecar starting or restarting, the runtime agent starting and stopping |
| trace | `-vv` | plus per-event detail: every request the runtime agent serves, every MCP request and reply (method or tool name and size, never the content), every ptrace stop |

| You want | Use |
|---|---|
| A quiet run in a script | `xodb -q ...` |
| To see why something was slow or blank | `xodb -v ...` |
| Detail from one area only | `xodb --log=render=debug ...` or `--log=agent=trace,sidecar=debug` |
| The same for every run in this shell | `export XODB_LOG=debug` (a flag on the command line still wins) |
| The messages in a file, not the terminal | `xodb -v --log-file xodb.log ...` (appended; created readable by you only) |

- `--log=LEVEL` is the level by name: `error`, `warn`, `info`, `debug` or `trace`.
- `--log=TOPIC=LEVEL[,TOPIC=LEVEL...]` sets it per topic. The topics are `render`, `window`, `runtime`,
  `agent`, `session`, `mcp`, `sidecar`, `semq`, `overview`, `redot` and `profile`. A plain level and
  topics can be mixed: `--log=warn,render=debug`.
- Error, warn and info lines look as they always have (`xodb: message`), so scripts that match them
  keep working. Debug and trace lines carry the topic and the seconds since xodb started:
  `xodb[render] +12.345s message`.
- The processes xodb starts use the same setting: the runtime agent (locally and over SSH), the
  server behind `--ssh`, and the Ghidra sidecar starter all receive it as `XODB_LOG`.
- `--log-file FILE` also sets `XODB_LOG_FILE` for those processes, so a local runtime agent appends to
  the same file. `XODB_LOG_FILE=FILE` in the environment works like the option; the option wins. An
  agent on another machine (`--runtime-ssh`) cannot write to your file: its lines come back on stderr.
- A value xodb does not understand is a usage error: it says what it expected and exits with status 2.
- With `--mcp` on stdio, stdout carries only the protocol at every level.
- The flags are options of xodb: put them before `--`. Everything after `--` belongs to the program
  being debugged, and the value of another option is never read as one of them (`--break -v` sets a
  breakpoint named `-v`). `--lsof-top` and `--memdefrag` are separate terminal programs and do not
  take them.
- While a window is hidden, `-v` reports the deferred frames once when they start and once when they
  resume; a second such pair within ten seconds is left out.
- `--debug-dir` and `--debug-file` are about debug symbols, not about messages.

## Redaction

`--redact` is for recording a video or sharing what xodb wrote. It works in
every mode: the debugger window, `--headless --mcp`, `--open-capture`,
`--open-pcap`, and the overview tools (`--overview`, `--fetch`, `--lsof-top`,
`--memdefrag`, which had it first). In debugger modes one policy
(`src/redact.zig`) applies to:

| Surface | What happens |
|---|---|
| Window text | Every string is rewritten just before it is drawn. |
| MCP replies | Every string value of every reply (object keys and the request id stay). |
| Log lines | Every level, before the line reaches stderr or `--log-file`. |
| Saved capture archive | Written redacted, with header bit "redacted" (optional feature bit 0). Texts are rewritten, socket addresses become tags, stack copies have names overwritten with `x`, and imported frame sources are not attached. The originals are not in the file, so it cannot be un-redacted. |
| Copy of an opened archive | Allowed only when that archive was itself written redacted (`ArchiveNotRedacted` otherwise). |
| Allocation archive | Refused (`AllocationArchiveNotRedacted`): it has no redacting writer yet. |
| `query_stream include_raw` | Refused (`RawPayloadRedacted`): payload bytes are withheld, not rewritten. |
| System tools (`get_process`, `get_connections`, `who_has_open`, ...) | The overview's own `redact` rules apply as well (command lines, other accounts; path lookups refused). |

| Private | Shown as |
|---|---|
| `/home/NAME/...`, your `$HOME` | `~/...` |
| your user names, host name | `user`, `host` (any case, as a token: between non-letters such as `/`, `@`, `.`, `_`, `-` or digits, or at a camelCase step; names of 8+ characters also inside longer words, so a short name does not rewrite `stream`) |
| IPv4/IPv6 outside loopback, unspecified, broadcast and documentation ranges | `ip-` and 8 hex digits |
| MAC addresses | `mac-` and 8 hex digits |

A tag is the start of HMAC-SHA256 of the address under a random key that is
never written down. Within one run (or one archive) the same peer always gets
the same tag, so flows still group by peer; two runs or two archives give
different tags, so they cannot be linked. A redacted archive's socket table
therefore matches loopback and documentation tuples in a pcap, never tagged
ones. Not covered yet: speedscope and investigation exports, `.xoi`/`.xof`
files, the remote GUI wire protocol, raw memory reads, and binary (non-text)
addresses inside stack copies.

## HiDPI and UI scale

xodb normally takes its device-pixel scale from the compositor, including
fractional Wayland scales such as 1.5. Layout, clipping and pointer hit testing
remain in window UI units; swapchain images, font rasters and 3D overlays use
the scaled device extent. Moving a window between differently scaled outputs
updates the backing resolution and font atlas. On X11 the scale comes from the
Xft.dpi resource and then RandR; `--ui-scale` still wins, and `--platform wayland|x11`
overrides a set WAYLAND_DISPLAY, then DISPLAY.

`--ui-scale N` sets device pixels per UI unit for that run, from 0.5 through 4.
Smaller values make text and controls smaller and leave more layout space;
larger values make them bigger. The backing buffer always follows the
compositor's resolution, so lowering this setting does not stretch a low-resolution
buffer. For example, a window with a 1900-pixel-wide backing buffer has 950
UI units at scale 2, or 1266 whole UI units at scale 1.5.
`appearance.ui_scale` in an explicitly loaded [preferences](PREFERENCES.md)
file supplies the same setting; the CLI wins. Both work in the debugger,
remote GUI and `--overview`. Omit both to follow the compositor.

### Small debugger windows

The debugger fits down to 640×400 UI units. It collapses Events, Values,
Stack, Threads, then Assembly as their minimum useful sizes stop fitting;
space goes to the remaining panes. Click a collapsed title tab or use
Alt+1…Alt+6 (Source, Assembly, Values, Threads, Stack, Events) to give that
pane priority; press its shortcut again to restore automatic priorities.
Source is the last to give way; an explicit reopen can borrow the whole body,
and Alt+1 restores Source. Text-entry fields keep keyboard ownership.

Toolbar actions that do not fit move into **More**; their shortcuts still
work. Ctrl+Shift+D cycles auto/normal/compact density without changing UI
scale. Shortened values have an ellipsis and reveal retained text on hover
(up to 255 bytes; longer diagnostic copies are explicitly flagged).
Thread IDs remain whole. MCP `get_layout` reports both scales, pane and control
rectangles, collapsed tabs, overflow actions and visible native value rows.
It is observer-only and does not wake drawing; `available=false` means this
view has no layout publication (including headless operation).

The overview reserves space for values before shortening labels, uses a dash
for an unavailable reason that cannot fit, and shows the reason on hover.
Small windows put overhead on a second footer row; key hints drop whole,
lower-priority clauses. Hover details wrap beside the hovered object when
space permits; otherwise the footer remains the fallback.
Its `get_layout` publication includes the content rectangle, actual text
rectangles (including shape-drawn numeric readouts), overlap/unmarked-clip
counts and explicit bounded-copy flags.

## Is it the microwave?

Your Wi-Fi stutters when someone uses the microwave, and you want proof.
Burrito mode listens to 2.4 GHz and to your own link at the same time.

| You have | You get | Run |
| --- | --- | --- |
| Only the laptop's built-in Wi-Fi (your internet link) | Link evidence: signal, bitrate, retries, channel busy (add `--ping` for gateway ping loss at 50 Hz, the one thing xodb sends). It can say "the link degraded" but not what caused it. | `xodb --burrito` |
| A USB AR9271 adapter plugged in as well (the usual case) | The sweep of the whole band and the verdict: mains-rate pulsing (50/60 Hz), duty, band, and per channel 1-14 how hard it is hit ("channels 6-13 blasted, 1-5 clean"). The built-in card is only read, never changed. | `sudo xodb --burrito --radio wlan1 --phases 30,60,30` |
| A second spare card as well | Per-channel traffic too: frames/s, airtime, retries, bad-FCS frames, how many networks and stations (counts only) | `sudo xodb --burrito --radio wlan1 --traffic wlan0 --phases 30,60,30` |
| The same, in the window | The Radio panel (**W**): the total-energy spectrum, the 14-channel strip, traffic, the verdicts, the cards. Drag across the spectrum to focus the sensor on a span; double-click for the full sweep | `sudo xodb --overview --radio wlan1 --radio-traffic wlan0 --panel radio` |
| No hardware, just a look | The panel on synthetic spectrum and traffic (access points, Bluetooth and a microwave), labelled SYNTHETIC | `xodb --overview --radio-demo kitchen --panel radio` |
| An agent asking "which channel should my AP use?" | MCP `radio_channels`: per channel power, occupancy, traffic and microwave impact, and the least-affected of 1/6/11 | `xodb --overview --headless --mcp --radio wlan1` |

With `--phases 30,60,30` xodb prompts you to switch the microwave on, and
later off, and prints one verdict per phase. The off, on and off phases then
sit side by side. A transformer microwave shows "60 Hz pulsing" (50 Hz in
Europe). An inverter microwave can show "continuous wideband energy; mains
pulsing not seen". That means the pulsing was not seen; it does not mean
there is no microwave.

Rules it keeps: it never transmits from a card it holds (no scans, probes or
association; every held card's TX counters are checked every second and
printed at the end), it sends nothing at all unless you ask for `--ping`,
and it never touches a card that is in use. A card it takes goes back to how
it was on exit, or at the next start after a crash. `xodb --burrito` lists
your cards with what each can contribute and what is missing.
[Details](RADIO.md).

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


For stripped Jai programs with supported read-only runtime metadata, **Y** opens
the runtime type browser. **L** loads a range, **/** filters types, **G** reads a
typed address, **S** searches type-pointer candidates and **O** lists container
storage. See [Jai runtime browser](JAI.md#runtime-browser) for an owned example,
keyboard walkthrough and the limits of candidate counts.


Runtime field editing: open the runtime browser with `Y`, load metadata with `L`,
and open a typed address with `G` or Return on a candidate. `W` accepts
`FIELD_PATH VALUE` (for example `health 123`); Return writes and verifies readback.
`Shift+U` restores the latest original value; plain `U` does nothing. After `F8`,
a human can also undo an agent write. See [JAI.md](JAI.md#live-field-editing-and-recovery)
for a runnable owned fixture, MCP mutate-scope commands and conflict semantics.

### Emacs Lisp stack

A supported GNU Emacs 31.1 debug build exposes an **Elisp** tab at a stopped
main thread. See [ELISP.md](ELISP.md) for an owned batch example, layout
requirements, argument counts and control records. Proved interpreted/bytecode
frames link to live C argument storage; other boundaries remain explicitly
unknown. Bounded Lisp values are available from native Lisp_Object expressions;
per-frame dynamic and saved lexical bindings appear in the Elisp pane.
