# Breakpoint policies and run controls

Software breakpoints now support enable/disable, observed hit counts,
side-effect-free conditions, stable-thread filters, ignore counts and logpoints.
The local GUI and MCP use the same session policy. Hardware watch behavior is
unchanged by these additions.

## Local GUI

- Set a breakpoint by clicking a source gutter or through MCP.
- **B** in the debugger view opens the breakpoint manager. In the profile view,
  B retains its existing flame-basis behavior.
- Select a breakpoint with the pointer or Up/Down.
- **Space** enables/disables it; **Delete** (or **Backspace**) removes it.
- **C** edits its condition; submit an empty expression to clear it.
- **H** sets how many matching-thread hits to ignore.
- **T** selects a live numeric TID; an empty entry selects all threads.
- **L** sets a log expression and changes the breakpoint to log-and-continue.
  An empty log expression records the hit without evaluating a value.
- **O** restores stop mode. **Esc/B** closes the manager.
- **F12** runs until the selected physical stack frame returns.
- Click source text to select a cursor line, then **F9** runs to it on the
  selected thread. The selected line has a faint highlight.
- **F5** continues/pauses even with the manager open.

The panel shows conditions, hit counts, filter/ignore status, errors and the latest
log observation. MCP pages the complete retained log history. GUI text entry is
currently bounded at 256 characters; MCP policy expressions allow 512.

## MCP

Create ordinary breakpoints with the existing `set_breakpoint`, then configure
an ID through `configure_breakpoint`:

```json
{
  "id": 1,
  "generation": 12,
  "condition": "request->id == 42",
  "tid": 1234,
  "ignore_count": 0,
  "mode": "stop",
  "enabled": true
}
```

This is an example argument object: substitute the current generation, breakpoint
ID, TID and an expression valid at that location. Configuration replaces the
whole policy: omitted condition/thread/ignore/mode/enabled fields mean no
condition, all threads, zero, stop and enabled. The GUI preserves other fields
when editing one. Source lines can resolve to several physical breakpoint IDs;
configure each intended location returned in `ids`.

Use `mode: "log"` and `log_expression` for observations. `get_breakpoint_logs`
accepts `after` (sequence) and `limit` (1–64) and returns records, pagination,
oldest available sequence and an overwritten-record count. The newest 256 records
are retained. Records include image epoch, stop generation, time, TID, PC,
expression and observed value. They describe their original stop, not current
memory. `get_breakpoints` exposes raw hit counts and policy state.

`finish` takes `tid`, optional `frame` (default 0) and `generation`. `run_to`
takes `tid`, `generation` and either a hexadecimal `address` string or `file`
plus `line`. These controls are asynchronous; poll `get_session`, whose
`running_to` is non-null while the operation is active. Their tools require
control scope; log inspection is read-only.

## Semantics and bounds

Raw hit counts include every observed trap. Thread filters bind to the debugger's
stable thread identity, so a reused OS TID does not acquire an old filter. Ignore
counts consume matching-thread hits before conditions are evaluated. Conditions
use the existing native expression evaluator and cannot call target functions.
A condition/log evaluation error stops visibly and reports a diagnostic on stderr.

A filtered or logged hit resumes only after the process reaches a coherent stop
and no thread has another meaningful stop. Explicit pause, stepping and revoked
agent control prevent automatic continuation. An event-history gap also keeps
the target stopped. Logpoints still trap and stop peers on every hit; use them
for bounded investigations, not an assumption of low-overhead hot-path tracing.

Finish checks caller stack identity as well as the return PC, distinguishing
recursive calls that share a return address. Other meaningful stops interrupt
finish/run-to. Internal probes are removed on completion/interruption; a shared
user breakpoint remains. A disabled breakpoint at the requested destination is
reported explicitly. Finish requires usable caller unwind information and does
not yet decode a typed return value. Source run-to currently chooses the first
resolved address for the selected line.

Broader grouping of several source locations under one editable policy remains
a follow-up; each physical location currently has its own ID and policy.

## Pending libraries and restart

**B**, then **N**, adds a symbol, including one in an unloaded library. The row
says PENDING until resolved; conditions, log mode, enables and thread filters can
be configured before resolution. MCP uses `set_breakpoint(symbol, generation)`;
`--break SYMBOL` uses the same logical request. Repeat it to install several
symbols in command-line order (at most 64 occurrences, including duplicates):

```sh
xodb --break main --break change_value -- ./zig-out/bin/xodb-m1-fixture
```

Duplicate names reuse the existing logical breakpoint. An unresolved name stays
pending without dropping the other requests. The same options work in local GUI,
headless/MCP, shared-session and C-agent launches, and are forwarded by `--ssh`.
For `--connect`, put all the options on the listening server's command line;
target selection still belongs to that server. A 65th option reports
`InitialBreakpointLimit` before launching a target.

IDs remain stable as libraries
load, unload and reload. `get_breakpoints` includes logical `definitions`, pending
and internal flags, and loader availability/diagnostics. One internal read-only
loader breakpoint appears while definitions require it.

**F4** or MCP `restart(generation)` restarts the original owned launch. Pause first
if it is running. It also works after exit. The old owned process is killed and
reaped before launching again; attached processes reject restart. Original argv
and the debugger's launch environment/directory are reused.

Symbolic breakpoints resolve against the new image. Ordinary source/address
breakpoints are retained as a module path, build ID and image-relative offset;
only the matching build can restore them. An anonymous or unidentifiable address
stays pending with a diagnostic. Breakpoint IDs, conditions/log mode and enable
state survive; per-run hit counters reset. Ignore counts retain their remainder.
Hardware watches are cleared because their addresses belong to the old run.
Thread-filtered breakpoints become disabled until the user selects a new thread
or clears the filter; a new process never silently broadens their scope.

The dynamic loader integration currently uses glibc's `_r_debug` /
`_dl_debug_state` rendezvous for the base namespace. Probes are withdrawn before
unload and re-resolved at consistent loader stops. Hidden loader stops preserve
step-over return probes. Other loaders resolve pending symbols at ordinary stops
and report the missing rendezvous; `dlmopen` namespace tracking is not implemented.
One physical location has one policy; a second unresolved alias that later
collides with an existing location reports `BreakpointLocationAlreadyUsed`.
