# xodb

A graphical, Linux-native debugger. The hugs and kisses debugger.

Not a GUI bolted onto GDB. Not a chat panel bolted onto a debugger. Not an IDA
clone. It's a live visual instrument for understanding software — debugger,
disassembler, profiler, tracer, and agent playground sharing one semantic model
of your program.

Zig. Wayland. Vulkan. FreeType/HarfBuzz. No Electron, no webview, no 1990s
widget toolkit. Dark, dense, keyboard-driven with a huge nod to RAD Debugger's
visuals (but not a clone- it's linux-first and cross-arch read on)

## ⚠️ Disclaimer

This started as a **challenge project**: 24 hours of work to make a functioning
debugger and a followup week to see how hard it can be productionalized,
starting **2026-09-30**. I want to find out how much I could do with AI
in a stupidly short amount of time. **The 1 week challenge finished on 10/7 but
I forgot to count what all I had done by then**. You can use it now. It's
pretty good.

So: it works, there are tests, there's a *lot* of it — and it will absolutely
fall over in ways a 20-year-old debugger wouldn't. We're fuckin' around and
making stuff. Mind the edges, read [Current limits](#current-limits).

This is still pre-alpha. I reserve the right to break interfaces. If it doesn't
work, have your agent fix it and send a pr. 

## Guiding principles

- **Graphical, fast, flashy.** The UI is the product, not a courtesy wrapper.
- **AI-native by design.** MCP interfaces built for agent control and analysis
  from day zero — humans and agents drive the *same* model, the same evidence.
- **Linux native in all ways.** ptrace, perf, /proc, pidfd, eBPF, uprobes,
  hardware debug registers. (not all *implemented* yet, mind)
- **Portable where it counts.** Not glued to x86-64, ELF, DWARF, or 64-bit
  pointers. Mach-O and Swift with MacOS. 
  - GUI: Linux/x86_64 and Linux/Aarch64 - MacOS in the works
  - Debugger targets: x86_64, aarch64, loongarch64 (龙芯), riscv64, ppc64le and m68k. debugserver/adb.
- **Dual Language runtimes:** Ruby, Perl, CPython, Lua, Node/JS, Go, Emacs Lisp, Redot/GDScript, Jai - see [docs](docs/)
- **Non-PC:** remote debugging (Android especially), planned Lua scriptability
  with `dbg.eval()`, replay, object/causal graphs.
- **One model, three readers:** human understanding, agent understanding,
  machine-verifiable semantics. A design has to improve all three.

The long version — the whole architectural brief this thing grew from — lives in
[linux-ai-debugger-agents.md](linux-ai-debugger-agents.md).

### Screenshot

![xodb stopped at rb_ary_store in CRuby, with the control-flow graph, stack, locals and event timeline](ruby_flow.png)

*Stopped on `rb_ary_store` in CRuby: source, static control-flow graph with the
selected block's disassembly, decoded `VALUE` locals, threads, stack, and the
event timeline.*

Keys, in brief: **F10** step over · **G** graph/asm · **P** profile · **F**
flames · **E** pinned expression · **Shift+E** live display · **Shift+L** convert selected watch · **V** watch/events · **Tab** locals/registers/Language runtimes
· **J/K** threads · **Shift+D** detach · **F8** grant or yank agent control · **Shift+Q** quit.
Letter shortcuts follow your active keyboard layout. In text fields, **Ctrl+V**
pastes, **middle-click** pastes the primary selection, and **Ctrl+C** copies.
See [text editing](docs/GUIDE.md#text-editing-and-clipboard).

On compositors supporting `xdg-decoration` (including KDE Plasma), the GUI
requests the desktop's native title bar for dragging, minimizing, maximizing
and closing the window. A look that draws its own title bar and window buttons
(`--overview --look win95`) asks the compositor to leave the frame off instead.
Compositors without the protocol (including GNOME) are unchanged.

## What actually works today

( this is VERY incomplete - browse my media tab on X for current status https://x.com/icpolicy/media )

New here? [Which tool do I reach for?](docs/GUIDE.md) is the plain-language map
(debugger vs profile vs observation, with demos).

**Process control.** Launch or attach, continue, interrupt, detach, per-thread
inspection. Software breakpoints by address, symbol, or file:line. Instruction
and source stepping, step-over. Worker-thread exec, main-thread-exits-first,
up to 1,024 threads.

**Source debugging.** ELF modules, DWARF 4/5 via libdw, CFI unwinding, locals
for the selected frame, C/C++ scalars/pointers/structs/arrays, side-effect-free
expressions with `$register` access, Rust/Zig slice and text previews. Explicit
*optimized-out* / *unavailable* / *unsupported* results instead of lies.

**Hardware write investigations.** Point at `item->value`, hit **W**, run. xodb
records the write (`7 -> 12`), the thread, registers, frames, locals, source
location, and the derived preceding instruction — then exports the whole
investigation to JSON as evidence.

**CPU profiling.** perf sampling, flame graphs with zoom and self/inclusive
counts, a linked timeline with drag-select ranges and optional scheduling lanes,
sampled stacks with background DWARF reconstruction, saved capture archives,
offline reopen, speedscope export.

**Static navigation.** Bounded control-flow graphs, basic blocks, branch edges,
honest *unresolved transfer* markers. Click a block, read its source and asm,
nothing executes.

**Allocations.** Native allocator calls, reallocs, frees, lifetime and
outstanding views, allocation caller stacks and byte/count heap flames — with
MCP evidence and save/reopen. See [docs/ALLOCATIONS.md](docs/ALLOCATIONS.md).
CPU archives can be compared with `--compare-capture before.xoc --open-capture after.xoc`;
see [profile comparison](docs/PROFILE_COMPARISON.md). Single-thread x86-64 source
stepping now batches straight-line instructions; see [source stepping](docs/SOURCE_STEPPING.md).

**Function investigations.** Headless recipes capture native function entries,
return words and call durations, compare fast/slow cohorts, and save/reopen `.xoi`
evidence. MCP also provides retained stopped inspections and temporal joins to
CPU, syscall and allocation records. See [commands and limits](docs/OBSERVATIONS.md).
For repeated baseline/variant runs with input hashes, retained failures and offline
summaries, see [observation experiments](docs/OBSERVATION_EXPERIMENTS.md).

**Themes.** Built-in dark, light and contrast palettes and custom JSON colors,
selected at startup for local, remote and offline views. See [themes](docs/THEMES.md).

**C runtime.** Target control and kernel collectors have one C implementation,
used locally and by `xodb-agent`. Build the agent with GCC or Clang; it needs no
Zig or GUI libraries. The host GUI/MCP keeps symbols, expressions and profiling
analysis, including cross-ISA debugging of an m68k target.
See [C runtime builds, commands and limits](docs/C_RUNTIME.md).

**Dual Language runtimes:** Ruby, Perl, CPython, Lua, Node/JS, Go, Emacs Lisp, Redot/GDScript, Jai - see [docs](docs/)

- Redot: https://x.com/icpolicy/status/2109814211702620260
- Redot: https://x.com/icpolicy/status/2109718652467728573
- Redot: https://x.com/icpolicy/status/2109181763608318108
- Wine: https://x.com/icpolicy/status/2109344883177906301
- emacs: https://x.com/icpolicy/status/2108953480287440986
- golang: https://x.com/icpolicy/status/2108692716112765221
- Ruby/rails: https://x.com/icpolicy/status/2108467525675819081
- ruby: https://x.com/icpolicy/status/2108447782231228616
- python: https://x.com/icpolicy/status/2107741869807673843
- jai: https://x.com/icpolicy/status/2108792793313505397

**Ghidra integration for in-line decompilation** Press 'd' at any stop to
generate pesudo-C for a function. We sidecar a Ghidra jvm that loads and warms
caches in parallel so as to keep startups fast. Verified on x86, arm64,
ppc64le, m68k and LoongArch.

https://x.com/icpolicy/status/2109838187728347196
https://x.com/icpolicy/status/2109864753174806946

**Remote** The workstation GUI drives a headless xodb on multiple remote
architectures via SSH/TCP, USB (android) etc. Android: native executables *and*
JNI libraries inside a debug APK, over USB.  ([ARM64](docs/ARM64.md) · [remote](docs/REMOTE_DEBUGGING.md) · [Android](docs/ANDROID.md))

| Feature | x86-64 | aarch64 | loongarch64 | riscv64 | ppc64le | m68k | macOS (debugserver) | gdbserver / QEMU (RSP) | Android (adb) | Windows x64 under Wine |
|---|---|---|---|---|---|---|---|---|---|---|
| Launch / attach | ✓ | ✓ | ✓ | ✓ | ✓ | launch | ✓ (stub) | ✓ (stub) | ✓ | ✓ |
| Software breakpoints, stepping | ✓ | ✓ | ✓ (software step) | breakpoint; step refused | ✓ (incl. larx/stcx.) | ✓ | ✓ | ✓ (needs Z0) | ✓ | ✓ |
| Hardware watchpoints | ✓ (4) | ✓ (4) | – | – | – | – | ✓ | – | ? | ✓ |
| Source, locals, expressions | DWARF | DWARF | DWARF | DWARF | DWARF | DWARF | Mach-O, Swift names | DWARF (host) | DWARF | PE exports, SEH unwind |
| Disassembly | ✓ | ✓ | Capstone 6 build | system Capstone 5 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Pseudo-C, Ghidra sidecar | ✓ | ✓ | ✓ (weak) | – | ✓ | ✓ | – | ? | ? | – |
| Pseudo-C, native worker | ✓ (ELF) | – | – | – | – | – | – | – | – | – |
| CPU profiling, flames | ✓ | – | – | – | – | – | – | – | – | ✓ (host) |
| Syscall timing, allocations | ✓ | – | – | – | – | – | – | – | – | ? |
| Fork/vfork following | ✓ | – | – | – | – | – | – | – | – | – |
| Core dumps | ✓ | – | – | – | – | – | – | – | – | – |
| Overview fd flow tracing | ✓ | – | – | – | – | – | – | – | – | n/a |
| GUI host | ✓ | ✓ | – | – | – | – | in progress | n/a | n/a | n/a |

Notes:
- loongarch64 pseudo-C is weak: no parameter names, and calls through the PLT resolve to the wrong targets.
- riscv64 steps are refused. `PTRACE_SINGLESTEP` returned EIO on the measured QEMU guest. Continue from a planted breakpoint stays refused until software step exists. Registers, memory, CFI stack, locals and expressions were checked through the agent.
- Sidecar on macOS and Wine: Ghidra itself reads Mach-O and PE, but importing a remote Mach-O or a PE image was deferred in DC4.
- The Wine column is a guess in two places. It is x86-64 native ptrace underneath, so profiling should work via the host, but no doc claims it; that's why it says "(host)". Syscall timing and allocations under Wine are untried.
- Several x86-64-only rows are table work, not design limits. Fd flow tracing (G22) is one; profiling and syscall timing on aarch64 are listed as remaining work in ARM64.md.
- Android hardware watchpoints should work, since it's the same arm64 xodb, but nobody has run them on the phone.


## Build and run

The GUI baseline is Linux x86-64/Aarch64, a Wayland session, a working Vulkan driver,
and **Zig 0.16 or newer**. See **[SETUP.md](SETUP.md)** for tracing permissions
and headless builds. Runs great on OmarchyMac.

Install the compiler tools, development headers, shader compiler and default
font for your distribution. These commands cover the application build;
[test dependencies](docs/DEPENDENCIES.md) are separate.

```sh
# Arch Linux
sudo pacman -S --needed base-devel zig pkgconf wayland wayland-protocols \
  libxkbcommon vulkan-headers vulkan-icd-loader shaderc freetype2 harfbuzz \
  capstone libelf ttf-dejavu
XODB_FONT=/usr/share/fonts/TTF/DejaVuSansMono.ttf
```

```sh
# Debian / Ubuntu (install Zig separately if it is not in your repository)
sudo apt install build-essential pkg-config libwayland-dev libwayland-bin \
  wayland-protocols libxkbcommon-dev libvulkan-dev glslc libfreetype-dev \
  libharfbuzz-dev libcapstone-dev libdw-dev libelf-dev fonts-dejavu-core
XODB_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf
```

```sh
# Fedora
sudo dnf install gcc zig pkgconf-pkg-config wayland-devel wayland-protocols-devel \
  libxkbcommon-devel vulkan-loader-devel vulkan-headers glslc freetype-devel \
  harfbuzz-devel capstone-devel elfutils-devel elfutils-libelf-devel \
  dejavu-sans-mono-fonts
XODB_FONT=/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf
```

Zig is not pinned to an exact compiler version. **0.16.0** is the last verified
baseline; newer compilers should be checked with the build and test suite, and
compatibility fixes are welcome. Build reports record `zig version` without
rejecting newer releases. The [official Zig downloads](https://ziglang.org/download/)
provide standalone toolchains. The GUI also requires the stable tablet-v2 XML
from **wayland-protocols 1.36 or newer**; older distribution releases may need
updated development packages. Install your GPU's Vulkan driver separately if
your desktop does not already have one; the Vulkan loader alone is insufficient.

Then, in the same shell:

```sh
./scripts/build -Doptimize=ReleaseSafe -Dfont-path="$XODB_FONT"
./zig-out/bin/xodb -- path/to/program arg1 arg2
./zig-out/bin/xodb --attach 12345
./zig-out/bin/xodb --help
```

`--font /path/to/font.ttf` overrides the compiled default. Build your target
with `-g -O0` for the simplest source debugging experience.

Local **RPM, Debian and Arch package recipes** are included; see
[packaging/README.md](packaging/README.md) for source snapshots and build commands.
They are development packaging, not published distribution packages.

### Demo

```sh
./zig-out/bin/xodb --break change_value --source tests/fixtures/m1.c \
  --record ".work/manual-m1-$(date +%Y%m%dT%H%M%S).json" \
  -- ./zig-out/bin/xodb-m1-fixture
```

**Space** to continue · **F11** steps a source line · click `item->value` in
Locals, press **W** · **Space** again and watch it catch the store · **Shift+Q** saves
the investigation. Full walkthrough and limits: [docs/M1.md](docs/M1.md).

Other things to poke at: `./scripts/demo-cruby` (break on `rb_ary_store`, inspect
Ruby frames and named locals with the supported DWARF runtime), `./scripts/demo-perl` (break on `Perl_av_store` and read
`key`, the new element and the interpreter's stack through Perl's DWARF), the [M2 flow graph](docs/M2.md), and
[flame graphs](docs/PROFILING.md).

Repeat for our other supported languages and runtimes: cpython, cruby, decompile, emacs, go, lua, node, perl, python, rails, redot.

## Agents

Point any MCP client at:

```text
xodb --headless --mcp -- /absolute/path/to/program
xodb --session-socket /tmp/xodb.mcp.sock
```
TODO clean up MCP behavior

Drop `--headless` and the GUI and the agent share one live session — same
threads, same stops, same evidence. MCP `2025-06-18`, newline-delimited
JSON-RPC, stdio or single-client TCP.

Scopes are deliberate: **observe** by default; `--agent-scope control` adds
breakpoints, stepping, profiling and `investigate_write`; `mutate` adds memory
and register writes. Every control action must present the current session
`generation`, so stale agents get rejected. **F8** revokes control from the GUI
mid-flight. There's an action audit. There's no embedded LLM — bring your own.

For several agents on one debugger, use `--session-socket /absolute/private/path/xodb.sock`
with the GUI or `--headless`, then connect each MCP client through
`scripts/session-client /absolute/private/path/xodb.sock`. Clients begin as observers;
one can claim a time-limited controller lease. Reconnecting preserves retained
investigations. [Shared-session commands and examples](docs/SHARED_SESSIONS.md).

[MCP overview](docs/MCP_OVERVIEW.md)

## Current limits

- Basic C/C++ types, no function calls, casts, bitfields, or inheritance.
  [Split DWARF and separate debug files](docs/DEBUG_SYMBOLS.md) are supported
  with documented limits. Signal-frame unwinding remains unsupported.
- Four x86 debug slots, aligned 1/2/4/8-byte watches. A watchpoint samples —
  it is **not** a replay trace. Concurrent writes can slip between samples.
- Source stepping is instruction-driven with a 10,000-instruction ceiling. It
  needs to get faster.
- Fixed 1,024-thread / 4,096-event capacities per process; old events expire.
  Source files are capped at 1 MiB.
- [Startup colors and presets](docs/THEMES.md); one adjustable divider, no saved layouts, docking or theme editor yet.
  Text starts at 16 UI units; independent text-size and accessibility controls still need work.
- No reverse execution, replay, or GPU tracing. Pseudo-C is available through the optional persistent Ghidra sidecar or native x86-64 ELF worker.
  [Syscall timing](docs/SYSCALL_TIMING.md) is opt-in for selected x86-64 threads;
  [core debugging](docs/CORE_DEBUGGING.md) is read-only.
- **License: GPLv3** System dependencies and their observed licenses
  are catalogued in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

The per-feature docs describe current limits; [DAY1.md](DAY1.md) preserves the
initial feature snapshot.

## What's next

- Skinnable, flexible display: text-size controls, skin controls and pane layouts you can save; startup themes and HiDPI backing scale are available.
- AArch64 feature coverage: precise multi-watch attribution, modern ARM
  validation, profiling
- More architectures, and the hardware or emulation to actually validate them.
- Your issues and PRs - file 'em please

[TODO.md](TODO.md) · [milestones](docs/MILESTONES.md) ·
[agent tasks](docs/AGENT_TASKS.md) · [findings journal](docs/journal.md)

## Tests

```sh
timeout 45 ./scripts/build test --summary all
python3 tests/mcp.py
python3 scripts/gui-smoke.py --m1
```

- 730 Zig unit tests (test blocks in src/)
- ~490 test programs in tests/: Python drivers, C fixtures and targets, and shell
- 338 gate steps in scripts/release-check all, which run those against real runtimes, real Ghidra, QEMU-style remote targets and private GUI sessions
