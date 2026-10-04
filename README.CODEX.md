# xodb

Historical development notes. Capability statements below may be
outdated; use [README.md](README.md) and its per-feature documentation for the
current release.

A native Linux debugging workstation. M0 provides a Wayland/Vulkan workspace,
real process control, and a shared model for the GUI and external MCP clients.
M1 adds source debugging and recorded watchpoint investigations.
M2 is in progress, with static function graphs, CPU flames, and a linked timeline
with optional scheduling lanes now available.
The primary workstation is Linux x86-64 with Zig 0.16.0. An initial
[ARM64 headless debugger](docs/ARM64.md) now work through MCP.
The [remote GUI](docs/REMOTE_DEBUGGING.md) now drives Jetty over SSH or direct LAN TCP.
On Android, the desktop GUI debugs both an [owned native executable](docs/ANDROID.md)
and a [JNI library inside debug APK](docs/ANDROID_APPS.md) over USB.

Start with [SETUP.md](SETUP.md) for build dependencies, tracing permissions,
optional syscall-tracing setup, security implications and undo instructions.

The [allocation demo](docs/ALLOCATIONS.md) records native allocator calls,
reallocations and frees, with lifetime/outstanding views and MCP evidence.

## Try M1

From your graphical session:

```sh
cd ~/Work/xodb
./scripts/build
./zig-out/bin/xodb --break change_value --source tests/fixtures/m1.c \
  --record ".work/manual-m1-$(date +%Y%m%dT%H%M%S).json" \
  -- ./zig-out/bin/xodb-m1-fixture
```

1. **Space** continues from the exec stop to `change_value`. Stack-based locals
   are unavailable at this function-entry stop, before the prologue has run.
2. **F11** steps by source line. Stop on the assignment marked `WATCH_WRITE`.
   Source follows the selected frame; locals show `item->value = 7`, `amount = 5`,
   and `next = 12`.
3. Click **item->value** in Locals, then press **W** (or click **W watch**).
4. **Space** runs to its write. The event shows `7 -> 12`; the next source line
   is highlighted because a data watchpoint stops after the store.
5. **Q** closes xodb and saves the investigation in the new JSON file. It
   includes the question, values, frames, locals, event, and the preceding
   instruction with its derivation recorded.

**F10** steps over calls. Click a source line number to toggle its breakpoint.
Click a stack frame to inspect its source and locals. **Tab** switches the right
pane between locals and registers. **J/K** selects a thread; arrows or the wheel
scroll source. Drag the source divider to resize panes. **F8** grants/revokes
agent execution control; the default is observation only.

**E** opens expression entry in the selected frame: type `item->value + amount`
and press **Return** to add it to WATCH. **V** switches WATCH/EVENTS. In the
focused list, **Up/Down** select, **Return** expands, **PgUp/PgDn** page children,
**[ / ]** or the wheel scroll, and **Delete** removes an entry. **W** starts a
hardware write investigation for the selected addressable expression. While
editing, **Up/Down** recall history, **Ctrl-U** clears, and **Esc** cancels.

Expression watches refresh at debugger stops and show stale values while
running; adding one does not install a hardware watchpoint. **CFA match** means
the stack address and function still match, which cannot prove the same call
survived between stops. Observed-dead frames stay gone. This entry UI is local;
remote expression evaluation remains available through MCP.
[Watch behavior and limits](docs/M2_EXPRESSION_WATCH_PROPOSAL.md).

Letter shortcuts follow the **active keyboard layout**. Only its unshifted
ASCII/function/editing/keypad keysyms are used; other layouts and physical key
positions supply no fallback. Ctrl/Alt/Super combinations do not trigger plain
shortcuts. Hold J/K/arrows to repeat navigation; execution controls act once per
press. The divider requests a resize cursor where cursor-shape is supported.

**D** detaches and leaves the target running. Owned targets are killed and
reaped on close; targets attached with `--attach PID` are detached and preserved.

```sh
./zig-out/bin/xodb -- path/to/program arg1 arg2
./zig-out/bin/xodb --attach 12345
./zig-out/bin/xodb --help
```

Build your program with `-g` for source/locals; `-O0` is the simplest starting
point. GCC/Clang DWARF 4/5 and selected optimized cases are tested. Attach requires
permission to trace the process; xodb does not change workstation tracing policy.

[M1 details, evidence, and limits](docs/M1.md).

The original multithreaded M0 fixture remains available:

```sh
./zig-out/bin/xodb --source tests/fixtures/target.c -- ./zig-out/bin/xodb-fixture
```

Continue, then pause to inspect both threads. The initial exec stop is often
inside the dynamic loader, which may have no source information.

![M1 watched field and source workspace](docs/images/m1.png)

## Try a native CRuby symbol

```sh
./scripts/demo-cruby
```

On this x86-64 workstation, **Space** stops Ruby's `a[3]=42` loop at
`rb_ary_store`. In frame #0, **E** expressions `$rsi`, `$rdx` and `$rdx >> 1`
show index **3**, tagged Ruby VALUE **85**, and decoded integer **42**. Inspect
before instruction stepping changes the argument registers. The helper waits
for libruby to load and cleans up its Ruby process when xodb closes.
[Demo details and symbol/type limitations](docs/research/cruby-demo.md).

## Try the M2 control-flow view

```sh
./scripts/build
./zig-out/bin/xodb --break flow_fixture --source tests/fixtures/m2.c \
  -- ./zig-out/bin/xodb-m2-fixture
```

**Space** reaches the function; **G** switches between graph and assembly.
Click a block to browse its source and instructions. Browsing leaves execution
unchanged; locals still describe the selected stopped frame.
[M2 demo, MCP graph API, and limits](docs/M2.md).
[Basic Rust/Zig value views](docs/M2_VALUES.md) show slices, text/bytes and named
enums; `get_value_children` pages through recorded fields/elements in observe scope.

## Try CPU flame graphs

```sh
./scripts/build
./zig-out/bin/xodb --break profile_ready --source tests/fixtures/profile.c \
  -- ./zig-out/bin/xodb-profile-fixture
```

**Space** reaches the profiling checkpoint. **P** starts capture, then **Space**
runs the target. **P** stops capture; **F** switches flame/source views. Click a
frame, **Z** to zoom, **Backspace** for its parent. Pause with **Space**, then
**Enter** browses a selected frame's source and assembly without moving the PC.

Defaults: 99 Hz, 60 seconds including stopped time, all current threads up to 1,024.
Widths count CPU samples; frame-pointer callers can be incomplete. Thread/time
filters and capture diagnostics are available through MCP. Add
`--profile-out NEW_FILE.speedscope.json` to save the latest capture on shutdown,
or use MCP `export_profile` for a selected range/TID. See
[portable export](docs/PROFILING.md#save-a-portable-profile) for sample-count semantics and limits.
[Demo, API and limits](docs/PROFILING.md).

For optimized code, open **F → S**, choose **4 KiB** stacks, then start a new
capture. After **P** stops collection, **B** switches recorded/reconstructed
flames and **I** opens sample inspection; **[ / ]** changes samples and arrows
scroll frames. Stacks default to off; the initial retention budget is 32 MiB.
[Sampled stacks, MCP and coverage limits](docs/M2_SAMPLED_UNWIND.md).

Attach with `./zig-out/bin/xodb --attach PID`; profiling supports up to 1,024
threads in that process. Completed captures show user/kernel CPU totals to help
explain sparse user CPU samples during copying or I/O-heavy work. Observed library
loads and mapping changes continue within the capture, with timestamped mapping
identities available through `get_profile_mappings`. New tasks outside scope and
metadata loss still stop collection. Perf does not report all unmaps/moves; the
flame view and MCP expose that attribution limit.

## Startup timing

GUI launches print `xodb: first window frame submitted in N.NNN ms` once to
stdout. This uses a monotonic clock from entry into `main` through the first
accepted Vulkan presentation, including initialization and synchronous target
setup. It approximates first paint; compositor scanout and background loading
may finish later. With `--mcp`, the line goes to stderr to preserve JSON stdout.
Headless sessions emit no window timing. [Verification](docs/research/startup-timing.md).

## Automated checks

```sh
timeout 45 ./scripts/build test --summary all
python3 tests/mcp.py
python3 tests/m1-control.py
python3 tests/m1-source.py
python3 tests/m1-stepping.py
python3 tests/m2-flow.py
python3 tests/m2-recovery.py
python3 tests/m2-ir.py
python3 tests/m2-values.py
python3 tests/m2-values-gui.py
python3 tests/m2-profile.py
python3 tests/m2-export.py
python3 tests/m2-timeline.py
python3 tests/scheduling-decode.py
python3 tests/m2-scheduling.py
python3 tests/m2-timeline-gui.py
python3 tests/m2-intervals.py
python3 tests/m2-intervals-gui.py
# Optional bounded latency/CPU comparison using the T04 workloads:
python3 tests/m2-workload-cost.py
python3 tests/m2-mappings.py
python3 scripts/gui-smoke.py --profile
python3 tests/wayland-read-race.py --attach-fixture
python3 scripts/gui-smoke.py --graph
python3 scripts/input-smoke.py
python3 scripts/gui-smoke.py --m1
python3 scripts/gui-smoke.py --m1 --render-fault
python3 scripts/gui-smoke.py --glyph-stress
```

The first command runs unit, ELF fixture, and actual process-control tests.
The M1 scripts cover scope and mutations, GCC/Clang DWARF 4/5 at O0/O2 compared
with GDB, saved watchpoint investigations, source stepping, C++ values, and
stripped/malformed debug information. The MCP test
compares memory against `/proc/PID/mem`, validates protocol errors and lifecycle,
and checks that the launched process is reaped when the client disconnects.
The M1 graphical test uses a private headless Sway session and virtual pointer
to grant agent scope, continue, source-step, select a field, start a watch
investigation, revoke scope, resize, export evidence and close. MCP observes
the same session. Run it without `--m1` for the original multithreaded M0 smoke. Its compositor, target,
and client are cleaned up. `--render-fault` injects one failed Vulkan submit and
checks renderer recreation without losing the target; `--glyph-stress` fills
the glyph cache and verifies that controls still work. 

The input smoke reuses T07 scenarios against the current build: ordered key/click
batches, held keys, active layouts, compose/modifiers, device lifecycle and
cursor-shape requests. Cursor appearance is not visible in the headless captures.

The agent sandbox denies ptrace and hides GPU devices. Run these integration
checks outside it. Agents must notify the user before using
shared workstation resources; automated GUI tests always use the private
session. `scripts/build` keeps Zig caches in this workdir.

## External agents

See the [MCP and machine-interface overview](docs/MCP_OVERVIEW.md) for the current
architecture and tentative future directions.

Configure an MCP client to launch this executable with stdio connected:

```text
~/Work/xodb/zig-out/bin/xodb --headless --mcp -- /absolute/path/to/program
```

Omit `--headless` when the client should open the GUI as well. Both interfaces
then inspect the same in-memory session. The stdio endpoint does not connect a second client to
an already-running GUI. Inferior stdout is redirected to stderr so it cannot
corrupt the MCP stream; inferior stdin is `/dev/null` for now.

The server negotiates MCP `2025-06-18`. `tools/list` reports the tools available
under the current scope. Inspection includes registers/memory, disassembly,
source, stack, locals, expressions, static function graphs, module/symbol lookup,
events, CPU captures/flame graphs, and audit.

Add `--agent-scope control` for breakpoint/watchpoint management, stepping,
continue/interrupt, profiling start/stop, and `investigate_write`. `mutate` additionally permits
memory and register writes. Every agent control action requires the current
`generation` from `get_session`. Control is asynchronous; poll for the next
stop. **F8** revokes control in the GUI and sends a tool-list notification.

`get_investigation` returns captured evidence; `--record NEW_FILE` saves the
records and action audit on shutdown. Existing evidence files are never
replaced. Event and watchpoint fields document sampling and attribution limits.

## Current limits

- One local x86-64 Linux process and its threads. Worker-thread exec and an
  exited main thread with live workers are supported. Fork/vfork child trees
  and job-control/group-stop workflows remain unsupported.
- Basic C/C++ types and side-effect-free expressions only. No function calls,
  casts, short-circuit logical operators, rich visualizers, bitfields or inheritance.
  Entry values, composite locations, split DWARF and signal-frame unwinding are
  explicit unsupported/unavailable cases. Separate debug-file discovery is pending.
- Source breakpoints resolve currently loaded modules. Hardware watchpoints use
  four x86 slots with aligned 1/2/4/8-byte ranges. [ARM64 data watches](docs/research/arm64-watchpoints/integration.md)
  now work through MCP and the remote GUI, with internal access completion and
  explicit candidate attribution. Concurrent writes can intervene between
  recorded samples; a watchpoint is not a replay trace.
- Source stepping currently advances instructions (running calls for step-over),
  with an interruptible 10,000-instruction limit. This needs acceleration for
  large workloads. Per-module CU lookup and symbol lookup are still linear.
- Fixed 1024-thread and 4096-event capacities. Old events expire; MCP reports the
  oldest available sequence. Source loading is capped at 1 MiB, with a notice
  in the source header when truncated.
- A tiled workspace with one adjustable divider; no saved layouts or full
  docking. Initial text size is 16 pixels; scaling and accessibility need work.
- The font defaults to the installed DejaVu Sans Mono. Override with `--font`.
  Its bounded glyph cache substitutes missing-glyph boxes when full. Renderer
  failures retry while preserving the target; a real GPU reset is not tested.
- MCP request lines are limited to 64 KiB; a client that stops reading can exhaust
  its bounded output queue and end the session.

## Development

[Milestones](docs/MILESTONES.md) · [Independent agent tasks](docs/AGENT_TASKS.md)
· [Findings journal](docs/journal.md) · [Original brief](linux-ai-debugger-agents.md)

Platform, renderer, target control, session model, UI, and MCP have separate
modules under `src/`. Existing files must be backed up before editing. Proposed
changes to the agreed architecture go to the user before implementation.
