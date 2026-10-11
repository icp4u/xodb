# macOS targets through Apple's debugserver

xodb runs on Linux and debugs a process on an Apple-silicon Mac by talking to
Apple's own `debugserver` with its [GDB remote client](GDB_REMOTE.md). Nothing
of xodb runs on the Mac. This is the first macOS target; a native backend,
Mach-O symbols and source come later.

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
| Threads | Works | Listed at every stop; thread IDs are the stub's |
| Registers `x0`-`x30`, `sp`, `pc`, `pstate` | Read and write | debugserver's `fp`, `lr` and `cpsr` map to `x29`, `x30`, `pstate`; its `w`/`v`/`s`/`d` views are not shown |
| Memory | Read and write | Writes are read back |
| Breakpoints by address | Works | Insert, remove, hit counts, step over |
| Instruction step, continue, interrupt | Works | Interrupt arrives as Darwin `SIGSTOP` and is shown as an interrupt |
| Hardware watchpoints | Write and read/write, 1/2/4/8 bytes, 4 slots | The stop comes **before** the access: the event has the old value and the exact address accessed |
| Signals | Works | Darwin numbers and names: `SIGUSR1` is 30, `SIGSTOP` 17. Continuing delivers the signal |
| Memory regions | `list_modules` regions | Start, end, permissions; the image path at an image's first region, else the stub's type such as `[stack]` |
| Loaded images | `list_modules` load failures | One `MachOImageUnsupported` row per image with its load address and path |
| Stack | Frame-pointer walk | Unsymbolised; each frame says how it was found (`registers`, `link_register`, `frame_pointer`) |
| Detach | Works | Breakpoints and watchpoints are removed first |

## Limits

| Not available | What you get instead |
| --- | --- |
| Symbols, source lines, locals, `find_symbol`, source breakpoints | `GdbLibrariesUnavailable`. Use addresses: `nm program` on the Mac gives link addresses; add the image's load address from `list_modules` minus `0x100000000` |
| Unwind tables (compact unwind, DWARF CFI) | The frame-pointer walk. In a leaf function or a prologue the caller comes from `x30`; that guess is labelled `link_register` and can be wrong after an early return |
| Kill | xodb has no kill action for a stub's target. Detach, then `kill PID` on the Mac |
| Vector and floating-point registers | `ExtendedRegistersUnavailable` |
| Execute watchpoints | `ExecutionWatchpointsUnsupported` |
| Stop details (`si_code`, fault address) | `get_stop_info` says `TaskInfoUnavailable`; the signal number and name are still right |
| More than about 700 loaded images | `GdbListTooLarge`: the image list must fit one 64 KiB packet. Regions still list |
| Very large address spaces | A region walk is one round trip per region and stops after 8 seconds or 4,096 regions with `GdbListBudgetExceeded` or `GdbListTooLarge` |
| arm64e targets, Rosetta (x86-64) processes, iOS devices | Not tested. Return addresses are masked to the 47 address bits the stub reports |
| Non-ASCII image paths | Shown with `?` for each byte outside printable ASCII |
| Launching or restarting from xodb | Start debugserver again |

Paths in these lists come from the Mac. xodb displays them and never opens a
file of that name on the Linux host.

## Untrusted remote

Every reply is treated as hostile, as for other GDB stubs. In addition to the
bounds in [GDB_REMOTE.md](GDB_REMOTE.md):

| Input | Bound |
| --- | --- |
| Image list (`jGetLoadedDynamicLibrariesInfos`) | One packet (64 KiB), 4,096 images, nesting depth 16, paths cut at 255 bytes; no allocation while parsing |
| Region reply (`qMemoryRegionInfo`) | Must contain the address asked, so the walk always advances; names cut at 127 bytes |
| Oversized reply to those two | Discarded under its checksum, at most 16 MiB within the request deadline; the connection survives. A region keeps its leading fields |
| `qHostInfo`, `qProcessInfo` | Known keys once each, numbers range-checked |
| Registers without a `g` packet | One `p` per mapped register; a reply of the wrong width refuses the read |
| Waits | Five seconds per request, ten per operation, as for every stub |

A reply that breaks a packet's grammar ends the connection with
`ProtocolError`. A list that is merely too large is a typed refusal and the
session continues.

## Tests

```sh
# No Mac needed: a recorded session replayed by a loopback stub, then hostile replies.
python3 -B tests/gdb-debugserver.py --work .work/gdb-debugserver
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
