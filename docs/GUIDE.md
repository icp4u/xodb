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

What you see is the interpreter's own C code, plus, for Perl, the script level:

- **Readable Perl values.** In Locals or **E**, an `SV *` shows as `IV 42`,
  `undef`, `PV "…"`, `AV (3 slots)` and so on, instead of raw union fields.
  Values that aren't meaningful yet (a brand-new element) say so rather than
  showing stale bits.
- **The Perl stack at a native stop.** Agents ask `get_language_stack`
  (language `perl`) for sub names and file:line, read straight from the
  stopped interpreter without running any code in it. Each piece is tied to
  the native interpreter-loop frame it came from, and it says `partial` when a
  boundary can't be proven.

Logical stacks for Python, Ruby and the JVM are arriving as imports; see
[logical frames](LOGICAL_FRAMES.md).

## Try it

| Demo | Command | What to look at |
| --- | --- | --- |
| Watch a value change | see the M1 walkthrough in the [README](../README.md) | **W** on a field, **Space**, see who wrote it |
| Observe and browse calls | `xodb --browse-observation example-01.xoi` after the capture in [OBSERVATIONS.md](OBSERVATIONS.md#one-command-capture) | **]** / **[** move the threshold, **Tab** switches fast/slow, **E** shows the raw evidence |
| Inside Perl | `./scripts/demo-perl` | **Space**, **E** `val` (undef: new element), **E** `av` (3 slots), **Space**, **E** `av->sv_u.svu_array[3]` (IV 42) |
| Inside Ruby | `./scripts/demo-cruby` | the `rb_ary_store` break |
| Profile | **P** in the GUI on any program | flame graph of where time goes |
| What feeds malloc's size? | `xodb --static-analysis DIR -- ./qx` (qx from `tests/fixtures/semq/qx.c`, DIR a built `tools/ghx` worker), stop in `qx_alloc` | click the `call` row, **S**, **Return**: `count` and `size` feed it, `flag` is irrelevant; **Tab** shows the `count > 4096` guard |
| Agent and human together | `xodb --session-socket ~/tmp/xs/s -- ./prog` | an agent drives; **F8** takes control back ([details](SHARED_SESSIONS.md)) |

## Where to go next

- [Observations: commands and limits](OBSERVATIONS.md)
- [Profiling](PROFILING.md) and [profile comparison](PROFILE_COMPARISON.md)
- [Shared sessions](SHARED_SESSIONS.md) and the [MCP overview](MCP_OVERVIEW.md)
- [Static analysis](SEMANTIC_QUERIES.md), [logical frames](LOGICAL_FRAMES.md),
  [themes](THEMES.md)
