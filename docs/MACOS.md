# macOS targets through Apple's debugserver

xodb runs on Linux and debugs a process on an Apple-silicon Mac by talking to
Apple's own `debugserver` with its [GDB remote client](GDB_REMOTE.md). Nothing
of xodb runs on the Mac. See [Mach-O metadata](MACHO.md) for UUID-matched
local files and frame names.

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

This is groundwork, not a usable Mac application. The AppKit implementation,
MoltenVK/static dependency build, application bundle, live resize callback,
`NSTextInputClient`, Command-key policy, and on-screen Mac test lane still need
a Mac that can open windows. The remote debugserver client described above is
independent and remains usable from Linux.
