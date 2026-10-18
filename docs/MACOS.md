# macOS: native client and Apple debugserver targets

xodb runs on Linux and debugs a process on an Apple-silicon Mac by talking to
Apple's own `debugserver` with its [GDB remote client](GDB_REMOTE.md). That
debugger engine still runs on Linux. See [Mach-O metadata](MACHO.md) for UUID-matched
local files and frame names.

## Run the native client on a Mac

The first native build is a **presentation client**, not yet the local debugger.
It uses the existing remote-client panels and renderer with AppKit and MoltenVK.
With no arguments it opens a disconnected preview and does not contact a server.
`--connect HOST:PORT` connects to an xodb MCP endpoint (not directly to
debugserver); use an authenticated SSH tunnel when the server is remote.
Local `-- ./program`, `--attach`, overview/replay, MCP serving and the D pane
are not implemented in this native entry point and refuse explicitly.

Prerequisites: Zig 0.16, the macOS SDK, MoltenVK, and static FreeType/HarfBuzz
libraries. No package manager or automatic installs are used. Configure the
prefixes with `-Ddeps=PREFIX`, `-Dmoltenvk=PREFIX`, or `XODB_MAC_DEPS` and
`XODB_MAC_MOLTENVK`. Defaults are `tools/deps-prefix` and `tools/moltenvk`.
The MoltenVK prefix contains `include/` and `dynamic/dylib/macOS/`.
Shaders compile with `glslc`, or pass `-Dshader-dir=DIR` / `XODB_MAC_SHADERS`
containing this tree's compiled `.vert.spv` and `.frag.spv` files. The default
font is the system Menlo font; `--font FILE` overrides it.

```sh
zig build -Doptimize=ReleaseSafe
zig build bundle -Doptimize=ReleaseSafe
zig build test-cocoa -Doptimize=ReleaseSafe
zig-out/bin/xodb --connect 127.0.0.1:47001
XODB_MAC_OFFSCREEN=1 zig-out/bin/xodb --frames 3
```

`bundle` creates `zig-out/xodb.app`, embeds MoltenVK with a bundle-relative
loader path and verifies an ad-hoc signature. It neither installs the app nor
opens a window. Retina backing scale is the default. Cmd-Q, Cmd-W and SIGTERM
use normal shutdown; shifted plain Q closes outside editors, matching the
remote UI. Live resize redraws the current publication without backend calls.
The native translator currently handles committed characters, not IME composition.
SIGTERM sets a signal-safe close flag; during AppKit's native resize/title drag,
shutdown waits for mouse-up and then takes the normal teardown path. No AppKit
calls are made from a signal handler. Bundle executables are stripped of debug
maps before signing; the build-tree executable retains debug information.

### Native test hooks

`XODB_TEST_SCRIPT=FILE` enables frame-numbered steps through the same NSEvent
translator as real input. Each line is `FRAME COMMAND ARGS`; `#` starts a comment.
Frames must be nondecreasing. The reader retains one line, capped at 4096 bytes,
and accepts at most 4096 lines. Invalid/unavailable steps fail explicitly.

Commands: `key VK CHARS UNMOD MODS`, `text STRING`, `click X Y`, `move X Y`,
`scroll X Y DY PRECISE`, `resize W H`, `dragresize DW DH STEPS`, `clipset TEXT`,
`clipget`, `state`, `close`. Coordinates are content points from the top left;
scroll DY is positive down. Key modifiers are shift=1, control=2, option=4,
command=8; character tokens include CR, ESC, TAB, UP, DOWN, LEFT, RIGHT and `-`
(empty). Text is limited to 120 UTF-16 units per step. Script key presses try
the main menu's key equivalents first, as real input does, so `key 12 q q 8`
closes like Cmd-Q; posting real keys still checks the window-server path.
`shot` is not implemented.

Clipboard steps require `XODB_MAC_PRIVATE_PASTEBOARD=1`, never the general
pasteboard. `state` reports actual locals/registers/watches selection, pointer,
size and RSS. This thin client has no overview search, so it reports
`search_supported=false`, not a simulated search result. `dragresize` posts a
corner drag to this app's own queue at 60 Hz and requires an on-screen window;
offscreen runs refuse it. The shutdown summary counts frames submitted inside
the native live-resize callback separately.

`XODB_PACING=1` prints streaming present-gap statistics at exit. Pacing and
script modes continuously render so frame-numbered tests can progress; normal
idle behavior is unchanged. The diagnostic modes are not idle-power benchmarks.

For automated SSH checks, use `scripts/release-check gui --macos mac` (or
`all`/`periodic`). Set `XODB_MAC_ZIG`, `XODB_MAC_DEPS` and `XODB_MAC_MOLTENVK`
to the already-provisioned Mac tool locations. The opt-in test copies current
sources and locally compiled shaders into a fresh `~/xodb-mac/native-check.*`
directory. It builds, tests Cocoa, checks the signed bundle, renders offscreen,
receives a synthetic TCP publication and tests normal SIGTERM cleanup. It does
**not** yet test local debugserver, real input, on-screen resize or scanout.
The retained directory is recorded in `.work/macos-native-remote-dir.txt`.

The native local owner uses `xrt_debugserver_start`. It discovers debugserver
in the selected Xcode and starts
launch or attach with one end of a private `AF_UNIX` socketpair inherited through
debugserver's documented [`--fd`](https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/debugserver.cpp)
option. No TCP port is reserved or opened. The caller transfers the other end
directly into the existing GDB client. The helper has its own process group,
starts with an empty signal mask and default `SIGTERM`, `SIGINT` and `SIGPIPE`
dispositions, and inherits no unrelated session descriptors. The owner must
receive the GDB detach reply before closing the transport and reaping the helper.
The first packet after adopting the socket is `QSetDetachOnError:1`. For an
attach, xodb requires its OK reply before attaching, and debugserver starts in
its remote-protocol mode without `--attach`; xodb then sends `vAttach;PID`.
That starts debugserver's packet read thread before the attach, so channel EOF is
observed even if xodb is killed while the attach request is in flight. Upstream
debugserver detaches on read-thread exit when detach-on-error is enabled (see
[debugserver.cpp](https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/debugserver.cpp)
and [RNBRemote.cpp](https://github.com/llvm/llvm-project/blob/main/lldb/tools/debugserver/source/RNBRemote.cpp)).
A launched target is left running if xodb dies and then becomes an orphan.
Unconfirmed detach never races EOF cleanup with a signal. After an actual
`D/OK` exchange, xodb keeps the stream open for up to two seconds while
debugserver completes its own shutdown. This avoids making Apple's helper
process the same detach twice. A helper still alive after the stream is closed
and the final grace period is terminated by its exact pid and reaped. An
idle/exited no-op detach does not count as that protocol confirmation. Any
cleanup timeout retains the helper pid rather than claiming success.
The bootstrap currently discards child stdio; target console forwarding is not
implemented by this component.

All native child spawns, including the SSH shim, use
`POSIX_SPAWN_CLOEXEC_DEFAULT`. The debugserver executable override is confined
to component tests; neither MCP nor the session wire supplies it. When a
close-on-exec descriptor already has its destination number, the spawn action
marks it inherited instead of applying a no-op `dup2`; this keeps discovery and
the private transport working when any of descriptors 0, 1 or 2 were closed.
Window
close, Cmd-Q and SIGTERM close the window first, then the owning worker sends
detach and waits for OK before disconnect/reap. Cleanup can take roughly
20 seconds in the timeout case; it performs no target work on the Cocoa
thread, and reports any retained helper pid. A GUI Detach publishes `detached`
and ends polling. Missing symbols/registers are diagnostic observations, not
automatic detach requests. See [native local scope](MACOS_LOCAL.md) for limits.

`zig build test-debugserver -Doptimize=ReleaseSafe` is an explicit, native-only
component test. It launches and attaches owned fixtures, checks that the helper
has no TCP listener, steps using the existing GDB packet/link implementation,
waits for debugserver's exit after detach and before close, checks closed-stdio
discovery and helper reaping, and preserves an attached fixture after transport
loss and after owner death with `vAttach` in flight. Its JSON proof fields come
from those checks. Add `--bootstrap-load` for 40 attach and attach-owner-loss
cycles under six owned CPU loops. `tests/macos-native.py --ssh mac --bootstrap` and
the opt-in `macos-bootstrap` release-check step run this lane; Linux's
`macos-seam` also compiles the component. These are **not** acceptance of a
native source/locals/MCP implementation. The separate `--local` lane exercises the native GUI.

Startup logs distinguish main-to-first-submitted-frame from on-screen appearance.
`XODB_STARTUP_TRACE=1` additionally logs when the window's occlusion
notification first reports it visible, timed from kernel process start (about
10-17 ms after the window server shows it). It never queries the window list
in-process: that deadlocks the commit that shows the window for ~0.5 s. Time
on-screen appearance exactly from another process. It does not capture pixels. Offscreen runs cannot supply this measurement. Keep first
execution of a new binary separate from warm runs; do not call it a cold-cache
measurement unless cache state is actually known.

## Quick start

`mac` below is whatever `ssh mac` reaches. Use your own host name.

```sh
# On the Mac: start the program stopped, with debugserver on loopback only.
DS="$(xcode-select -p)/../SharedFrameworks/LLDB.framework/Resources/debugserver"
"$DS" 127.0.0.1:47000 ./program            # launch, stopped before its first instruction
"$DS" 127.0.0.1:47000 --attach=PID         # or attach to a running process you own

# On Linux: forward a local port to the Mac's loopback, then connect.
ssh -N -L 127.0.0.1:47001:127.0.0.1:47000 mac &
xodb --gdb-remote 127.0.0.1:47001
xodb --headless --mcp --agent-scope mutate --gdb-remote 127.0.0.1:47001   # for an agent
```

debugserver serves one connection and exits when it closes. Detaching leaves
the program running: xodb never kills a stub's target, so end it yourself
(`kill PID` on the Mac) when you are done.

## Why loopback and an SSH tunnel

debugserver has no authentication and no encryption. Anyone who can reach its
port controls the process: memory, registers, execution. Always give it a
`127.0.0.1:PORT` address, never a bare port or `0.0.0.0`, and check with
`lsof -nP -iTCP -sTCP:LISTEN` that it listens on `127.0.0.1` only. The SSH
forward supplies the authentication and the encryption. xodb prints a notice
when a GDB connection is not loopback.

## Requirements on the Mac

| Requirement | Why |
| --- | --- |
| Xcode selected (`xcode-select -p`) | debugserver ships inside it; `xcrun --find debugserver` can fail, the path above works |
| Developer mode enabled, account in the `_developer` group | The configuration this was tested in (macOS 26, arm64). Without it macOS may ask for an administrator or refuse |
| A process of your own user | Tested with ordinary builds. Hardened-runtime and system binaries were not tested |

Apple signs debugserver with private entitlements, so it can debug an
ordinary build such as `cc -g program.c`. No signing of the program is needed.

A launched program's standard output goes to debugserver, and xodb does not
show it. Add `--stdout-path FILE` (an absolute path) before the address to
keep it in a file on the Mac.

## What works

| Operation | State | Notes |
| --- | --- | --- |
| Session identity | Works | `get_session` reports `architecture: aarch64` and `gdb_remote.os: darwin` |
| Threads | Works | Inventory at every stop; optional names from `jThreadsInfo` and real dispatch queues from `jThreadExtendedInfo` |
| Registers `x0`-`x30`, `sp`, `pc`, `pstate` | Read and write | debugserver's `fp`, `lr` and `cpsr` map to `x29`, `x30`, `pstate`; its `w`/`v`/`s`/`d` views are not shown |
| Memory | Read and write | Writes are read back |
| Breakpoints by address, function, or source line | Works | Function names use UUID-matched Mach-O symbols; source lines use matching dSYM or N_OSO object DWARF |
| Instruction step, continue, interrupt | Works | Interrupt arrives as Darwin `SIGSTOP` and is shown as an interrupt |
| Hardware watchpoints | Write and read/write, 1/2/4/8 bytes, 4 slots | The stop comes **before** the access: the event has the old value and the exact address accessed |
| Signals | Works | Darwin numbers and names: `SIGUSR1` is 30, `SIGSTOP` 17; ordinary pending signals are delivered on continue |
| Mach exceptions | `get_stop_info`, C stop panel | Exception type and hexadecimal codes; `EXC_BAD_ACCESS` includes the fault address and warns that Continue will fault again. A Mach exception has no application signal to forward |
| Attach, exec and exit | Recorded transitions | An attached initial stop is an interrupt. Exec says that it removed old breakpoints; `get_session.exit` distinguishes a status from a killing signal and names that signal |
| Fork | Parent stop only | `SIGCHLD` (Darwin signal 20) is forwarded without stopping by default; no child is adopted |
| Memory regions | `list_modules` regions | Start, end, permissions; image paths for unique owners and `[shared cache: N images]` for merged cache ranges |
| Loaded images | `list_modules` | Load addresses, image paths and metadata diagnostics; see [Mach-O metadata](MACHO.md) for local file matching |
| Stack, source and locals | Recorded metadata | UUID-matched dSYM or N_OSO object DWARF supplies names, lines and available locals; common Swift scalar values and compact Swift frame names are shown; ARM64 EH-frame/compact unwind precedes the bounded register/frame fallback |
| Detach | Works | Breakpoints and watchpoints are removed first |

## Limits

| Not available | What you get instead |
| --- | --- |
| Missing local symbols for `find_symbol` or source breakpoints | A typed Mach-O metadata refusal. Address breakpoints still work |
| Missing dSYM or object DWARF | A typed metadata refusal; frame names can still use Mach-O symbols and unwinding can still use image metadata or the bounded register/frame fallback |
| Kill | xodb has no kill action for a stub's target. Detach, then `kill PID` on the Mac |
| Vector and floating-point registers | `ExtendedRegistersUnavailable` |
| Execute watchpoints | `ExecutionWatchpointsUnsupported` |
| POSIX `siginfo` fields | The stub does not supply `si_code` or `errno`; these stay null. Mach exception codes are separate |
| Oversized loaded-image list | `GdbListTooLarge`: the decoded list must fit the 512 KiB packet bound. Regions still list |
| Very large address spaces | A region walk is one round trip per region; `map_cut: true` returns the first 4,096 rows instead of losing the map. The 8-second budget remains |
| arm64e targets, Rosetta (x86-64) processes, iOS devices | Not tested. Return addresses are masked to the 47 address bits the stub reports |
| Non-ASCII image paths | Shown with `?` for each byte outside printable ASCII |
| Launching or restarting from xodb | Start debugserver again |

`thread_labels` identifies its provider as `gdb_thread_info`. `dispatch_queue`
is the optional `dispatch_queue_t` from `jThreadExtendedInfo`; a plain pthread
has no queue field. Queue names are not available in the recording.
`qfThreadInfo` remains the thread inventory: extra JSON rows cannot create
threads. Metadata is cached for the stopped generation. Unsupported metadata
leaves names and dispatch queues unavailable.

A reduced image list without segment geometry labels only the mapping starting
exactly at an image's load address. Segment geometry extends labels to data
and later code mappings only where one image covers the whole region. Shared
or overlapping ranges remain unlabelled. Image paths are display labels.

The recorded hardware has six execution-breakpoint slots and four data-watch
slots, although the stub granted eight `Z1` insertions. This client exposes
software breakpoints and up to four data watchpoints; execution watches stay
unsupported. It does not infer usable hardware slots from successful insertions.

Paths in these lists come from the Mac. xodb displays them and never opens a
file of that name on the Linux host.

## Untrusted remote

Every reply is treated as hostile, as for other GDB stubs. In addition to the
bounds in [GDB_REMOTE.md](GDB_REMOTE.md):

| Input | Bound |
| --- | --- |
| Image list (`jGetLoadedDynamicLibrariesInfos`) | One packet (512 KiB), 4,096 images, nesting depth 16, paths cut at 255 bytes; no allocation while parsing |
| Thread metadata (`jThreadsInfo`) | 1,024 unique positive 32-bit IDs, depth 16, names cut at 127 printable ASCII bytes; malformed/oversized optional metadata is marked failed without losing registers or control |
| Mach stop fields | One type and count, at most four 64-bit codes; duplicate, incomplete or contradictory fault addresses refuse the stop |
| Region image labels | At most 16,384 segment ranges and 32,768 sorted boundaries; overlapping images and regions crossing a gap do not acquire a guessed owner |
| Region reply (`qMemoryRegionInfo`) | Must contain the address asked, so the walk always advances; names cut at 127 bytes |
| Oversized reply to those two | Discarded under its checksum, at most 16 MiB within the request deadline; the connection survives. A region keeps its leading fields |
| `qHostInfo`, `qProcessInfo` | Known keys once each, numbers range-checked |
| Registers without a `g` packet | One `p` per mapped register; a reply of the wrong width refuses the read |
| Waits | Five seconds per request, ten per operation, as for every stub |

Malformed stop packets invalidate the connection and require reconnecting;
old threads cannot be resumed or decoded. Optional thread metadata has a
separate failed capability state. A list that is merely too large is a typed
refusal and the session continues.

## Tests

```sh
# No Mac needed: a recorded session replayed by a loopback stub, then hostile replies.
python3 -B tests/gdb-debugserver.py --work .work/gdb-debugserver
# Names, queues, region ownership, Mach stops, exec and slot limits from recordings.
python3 -B tests/macos-views.py --work .work/macos-views
# The real thing. Builds a fixture on the Mac, runs launch and attach, cleans up.
python3 -B tests/macos-debugserver.py --ssh mac --work .work/macos-debugserver
scripts/release-check periodic --macos-ssh mac
# Re-record the transcript after a client change that alters the packet sequence.
python3 -B tests/macos-debugserver.py --ssh mac --work .work/record --cases launch \
    --record tests/fixtures/debugserver-arm64.json
```

The live test keeps everything in one directory on the Mac
(`--remote-dir`, default `xodb-debugserver-test` under the home directory),
signals only the two processes it started, checks that none is left, and
removes its files and then the directory if that left it empty. The
recording has synthetic process and thread identities and a neutral fixture
path; the recorder refuses to write a transcript that contains the account
name, the host name or a home path.

## Building the client code for macOS

The GDB remote client, the agent wire client and the decoders around them
compile for a macOS host. `scripts/build macos-seam` cross-compiles that set
for `aarch64-macos` from Linux, and `scripts/build test` includes it, so a
Linux-only include in a shared header fails the build. The ptrace backend,
perf, `/proc` readers and ELF loading are not part of the set. On macOS a
sealed in-memory file does not exist, so fetching a remote file through the
agent wire reports the file as unavailable there.

## Cocoa desktop backend groundwork

The window-system boundary now accepts `-Dplatform=cocoa`. On Linux this builds
the complete GUI against `src/platform/cocoa.zig` and a native stub:

```sh
scripts/build app -Dplatform=cocoa -Doptimize=ReleaseSafe
scripts/build test-cocoa -Dplatform=cocoa -Doptimize=ReleaseSafe
```

The stub deliberately returns `CocoaUnavailable` before creating a window. Its
purpose is to keep the Cocoa contract compiling while no Mac is reachable. The
contract already covers logical window size and backing scale, translated key
and text events, pointer and scroll events, title and window actions, the
synchronous macOS clipboard shape, FIFO frame pacing, and a
`VK_EXT_metal_surface` creation hook. `cocoa_shim.h` is the stable C boundary
for the Objective-C/AppKit implementation.

The native implementation and bundle are described above. The Linux stub is
only a compile/contract lane, not a substitute for native execution. IME
composition still needs `NSTextInputClient`. The remote debugserver client
described above is independent and remains usable from Linux.
