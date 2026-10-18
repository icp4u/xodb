# Native local debugger: first slice

The native Cocoa app accepts `xodb -- ./program args...` or
`xodb --attach PID --exe ./program`. It opens the window before a worker starts
Apple debugserver. Target reads, Mach-O jobs and run-control stay off AppKit's
thread; the GUI renders owned publications. Closing the window detaches and
leaves the target running. It does not terminate the debugged program.

Available: stopped threads, current registers, Capstone assembly, bounded
frame-pointer stacks, Continue/Interrupt, instruction Step, Detach, and
`--break SYMBOL` (a main-executable symbol breakpoint before continuing).
The symbolic lookup uses the existing UUID/architecture-matched Mach-O cache.
Pass `--exe` for attach if main-executable symbol names are wanted.

Limits: no native DWARF provider yet. Source lines, locals, source stepping,
step-over, finish, watches and restart are unavailable; unsupported controls
refuse before execution. `--source FILE` shows an explicitly selected file as
text, not an inferred executing location. Caller frames are labelled as
frame-pointer fallback and do not display the top frame's register values.
No native stdio MCP server or overview collectors are included in this slice.
The existing remote `--connect` mode is unchanged.

The current Mach-O dSYM/N_OSO adapter ultimately calls the libdw-backed
`debug/info.zig.Image` over private ELF section containers. That adapter is
Linux-only; the native symbol path has no libdw/libelf dependency. This is not
an elfutils port or a claim that native source debugging is complete.

## Build and test

Build the pinned dependency with `python3 scripts/build-capstone --jobs 2
--prefix PREFIX --cmake CMAKE`. Set `XODB_MAC_CAPSTONE=PREFIX`, alongside the
existing native Zig, FreeType/HarfBuzz and MoltenVK prefixes. Native
`zig build app bundle -Dcapstone=vendored -Doptimize=ReleaseSafe` statically
links it and produces the stripped, ad-hoc signed app bundle.

`tests/macos-native.py --native --local` runs the existing offscreen contract
and `tests/macos-local.py`. From Linux use `--ssh HOST --local`; the opt-in
`macos-local` release-check step runs this lane. The tests compile only an
owned, lifetime-bounded fixture and check launch, symbolic breakpoint, attach,
rendered registers/assembly, instruction-step PC changes, and heartbeat
progress after window close, Cmd-Q, SIGTERM and setup errors. Missing startup
symbols retain a controllable stopped session; explicit Detach publishes the
detached state once, then stops the owner. A deliberately unchanged PC and a
summary incorrectly marked detached must fail their respective oracles.
The enclosing timeout is a hang bound, not a speed assertion.

The Cocoa test script adds `FRAME stopped`: wait for a stopped publication to
have been presented with no pending request. `FRAME detached` waits for the
detached publication and completed owner cleanup. It uses the same NSEvent input
path as other script commands. It does not inject a synthetic target state.
The existing `state` diagnostic adds a debugger row with generation, PC and
register/instruction/breakpoint counts. Native testing remains offscreen;
actual display/input acceptance is a separate console-session check.
Scripted offscreen runs install the real Cmd-Q/W menu without creating a
window or activating the app, so menu-close cleanup can be checked there too.
