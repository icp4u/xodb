# Remote debugging over SSH or TCP

Adopted by the user on 2026-10-01. The workstation GUI now controls a headless
xodb on another host. Verified: x86-64 GUI to native ARM64, over both
SSH and direct LAN TCP. [Evidence and screenshots](research/remote-gui/README.md).
The same GUI now controls the native Pixel service over a USB ADB forward:
[Android demo and walkthrough](ANDROID.md), [device evidence](research/android-gui.md).

## GUI demo: SSH

Run on the workstation (restart xodb to use the new binary):

```sh
./zig-out/bin/xodb --ssh jetty \
  --remote-xodb ~/Work/xodb-remote-demo-20261001-r2/zig-out/bin/xodb \
  --source ~/Work/xodb-remote-demo-20261001-r2/tests/fixtures/m1.c \
  --break change_value \
  -- ~/Work/xodb-remote-demo-20261001-r2/zig-out/bin/xodb-m1-fixture w
```

Press **Space** to reach `change_value`. Click the source gutter at line 10,
then Space again: locals show `amount=5` and `next=12`. Click a stack entry to
inspect its frame. **F11** steps into the next source line, **F10** steps over,
**F7** steps one instruction, and **Tab** switches locals/registers. The mouse
wheel scrolls source, registers/locals, threads or stack under the pointer.
Space interrupts a running target. **D** detaches; **Q** closes the GUI.

Hardware watches: click an addressable scalar local and press **W / Watch**.
**V / Watches** opens the installed list; select a watch and **W / Remove** to
remove it. A pointer local watches its storage, not the pointee. For the demo,
select `next` at line 10 (value 12), arm it, and continue past the next function
entry breakpoint: its next assignment stops with **12 → 21**. A watch retains
its address after the local's lifetime, so remove it when finished. The status
bar shows the recorded values and marks ambiguous hits as possible watches.

ARM64 completes the access internally before presenting the stop. It preserves
the raw pre-access PC, and faults/signals remain incomplete rather than reporting
an invented value. Jetty exposes four data slots; aligned 1/2/4/8-byte write and
read/write watches work. MCP supports address/length watches and expressions;
GUI creation currently uses scalar locals. [Limits and native evidence](research/arm64-watchpoints/integration.md).

At the initial loader stop, or anywhere the executing frame has no source line,
Step advances one instruction and Over steps over one instruction/call, matching
the local GUI. The shared-source gutter can still set or remove breakpoints
while stopped there; it operates on the displayed file, independent of the
selected frame. Once source mapping is available they use source stepping.
Stepping returns inspection to frame #0 even if a caller was selected. Rejected
remote actions print their tool name and reason to stderr.

While the target runs, inspection panes retain the last stopped view with
**last stop** labels. Values are stale; the thread list and execution controls
use current state. Step, Watch and frame selection cannot act on the retained
view. Interrupt fetches fresh inspection.

To attach, replace `--break change_value -- PROGRAM ARGS...` with `--attach PID`.
For any SSH host, supply its alias and installed xodb path. Paths and arguments
are shell quoted literally: use an absolute remote path or a path relative to
the remote login directory; a quoted `~` is not expanded remotely.

SSH uses existing authentication/configuration with batch mode and strict host
key checking. Agent forwarding is disabled. A failed authentication/host-key
check is reported on stderr and in the disconnected GUI. SSH starts the server
with **control** scope unless `--agent-scope observe|control|mutate` is explicitly
supplied. The remote host still enforces normal ptrace permissions.

## Direct TCP on the LAN

On Jetty, start one server. This address is Jetty's measured LAN address; use the
appropriate address for another host:

```sh
cd ~/Work/xodb-remote-demo-20261001-r2
./zig-out/bin/xodb --headless --mcp \
  --listen 192.168.1.100:4317 --agent-scope control \
  --source tests/fixtures/m1.c --break change_value \
  -- ./zig-out/bin/xodb-m1-fixture w
```

On the workstation:

```sh
./zig-out/bin/xodb --connect 192.168.1.100:4317
```

For attach, put `--attach PID` on the **server** command line instead of
`--break ... -- PROGRAM ...`. Target and scope options belong on the server
when using `--connect`. TCP accepts numeric IPv4 and bracketed IPv6 endpoints,
for example `127.0.0.1:4317` or `[::1]:4317`; use SSH aliases for hostname-based
connections in this first version.

**Plain TCP has no authentication or encryption. Anyone who can reach the
listener can claim its session and exercise the configured scope. Use it only
on a trusted LAN, or bind loopback; use SSH elsewhere.** No network listener,
firewall rule or service is installed automatically. Binding happens only with
an explicit `--listen`. The listener closes after accepting its one client.
The server waits for that connection before launching/attaching the target.

## Source, ownership and failures

- Symbols, disassembly, registers and unwinding are computed on the target host.
  The client does not interpret remote memory using its native register layout.
- `--source FILE` on the server explicitly shares one regular UTF-8 source file,
  capped at 48 KiB and labelled when truncated. The GUI labels it as a provided
  file; it is not verified against a compiler-recorded content hash. Matching
  basenames let that explicitly provided file follow DWARF locations. Automatic
  source fetching, multiple-file mapping and verified source identities follow.
- Closing the GUI detaches an attached process and kills/reaps a server-launched
  process. **D / Detach** explicitly preserves either kind of process.
- On connection loss, the GUI retains a labelled stale snapshot, disables target
  controls, and makes no automatic reconnect or action replay. It cannot confirm
  cleanup on an unreachable host. Restart the server/session explicitly.
- TCP sockets request keepalive probes after 15 seconds, every 5 seconds, with
  three missed probes and a 30-second user timeout. These are failure-detection
  aids, not a guarantee of immediate cleanup. SSH has its own keepalive checks.
  The server handles SIGHUP through orderly cleanup; the client gives SSH up to
  ten seconds to exit after closing its input before terminating its child.
- Connection/request I/O and JSON decoding run on a worker. TCP connect has an
  eight-second deadline; each RPC read/write has a fifteen-second deadline and
  a cancellable poll. Closing a window cancels the worker.

## Interface and present limits

Both transports carry newline-delimited MCP JSON-RPC. `get_debug_view` supplies
schema 1, a coherent snapshot with session ID/generation, target architecture,
threads, named registers, stack, locals, assembly, breakpoints and data watches.
Additive optional fields expose local addresses/sizes, watch capacity and recent
watch evidence; older views default those fields to unavailable/empty. Optional
`summary_only:true` polls identity/state without repeatedly transferring threads
or debug data. GUI controls use the existing tools and the generation that was
actually displayed; stale actions fail without replay.

A view retains at most 256 thread rows, 64 frames, 128 locals, 32 instructions
and 48 KiB of explicit source. Truncated threads/locals/source are labelled;
thread paging is not yet implemented. Messages are capped at 1 MiB. A single
pending GUI action prevents accidental repeated execution requests.

This first remote workspace supports the debugging loop above. Remote profiling,
flames, expression-entry UI, expandable local fields and full local-pane parity
remain follow-ups. It consumes the server's single MCP connection; it does not
yet expose a local MCP proxy for another agent to join that remote GUI session.
Use a separate headless server/session when an external MCP client is controlling
the target. ARM target limitations still apply: [ARM64.md](ARM64.md).

## Critical assessment

Reusing MCP gives us tested target control, scope and stale-generation checks,
with an x86 GUI controlling ARM64 without copying remote ELF assets. A bounded
view avoids piecing together several generations across a slow connection. The
cost is a separate remote workspace with fewer features; shared presentation
should converge as the session boundary settles. This does not select the
future serial protocol. The Android proof currently covers only an owned native
executable on the tested Pixel, not arbitrary APK attachment or ART/Java.

The weakest areas are recovery and source identity. An unreachable host cannot
confirm target cleanup, and a manually provided file can differ from the built
source. Both remain explicit in the interface. Reconnect needs server identity,
controller ownership and action acknowledgement before it can be added safely.

## Build coordination

Claude owns the requested cross-platform/GUI build work. This integration adds
`src/remote/`, `src/ui/remote.zig`, `src/mcp/remote.zig` and remote CLI/dispatch in
`src/main.zig` / `src/mcp/server.zig`. It does not change `build.zig`,
`scripts/build-jetty`, or the handed-off T19 files. The ARM watch follow-up makes
one small local-workspace event-formatting change to label candidate/unavailable
watch values; the remaining presentation changes are in the remote workspace.
