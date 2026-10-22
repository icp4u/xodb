# Child-process ownership and protocol inventory

This is the runtime inventory for processes started by xodb or by an xodb
helper. It records the launch site, the object that owns the child, how that
owner tears it down, the child's independent exit rule, and the check made
before state crosses a protocol boundary. It was audited on 2026-10-21 from
the production `fork`, `exec` and `posix_spawn` sites in `src`, plus the two
Ghidra launch layers in `tools/ghx` and `scripts/ghidra-sidecar`.

Tests and build tools are outside the runtime inventory. In particular,
`tools/ghx/ghx_measure`, fixture launchers, and forks inside Zig or Python test
blocks are test/build children rather than processes started by a shipped xodb
session. Threads are also outside this table. A target's own descendants are
tracked by the process-tree policy in `docs/PROCESS_TREES.md`; xodb did not
start those descendants.

Status means:

- **complete**: one named owner has a teardown path and the child has an
  independent exit rule; a peer is checked before state is sent, where a peer
  protocol exists;
- **partial**: ownership is explicit, but a bounded teardown or one part of
  the producer/version/capability check is missing;
- **gap**: state reaches an unchecked peer or an owner can lose a live child;
- **not applicable**: the child is a user payload or an exact fork of the
  current image, so there is no separately versioned peer.

## Runtime inventory

| Process or family | Launch site | Owner and teardown | Independent exit rule | Version or protocol check | Status |
|---|---|---|---|---|---|
| Capture-tool `--version` probe | `src/capture/live.zig`, `pipeChild` from `probeVersion` | The `probeVersion` stack frame closes the pipe and reaps the exact PID. At two seconds it sends `SIGTERM` and waits. | The tool exits after printing its version. | Output must identify dumpcap >= 3 or tcpdump >= 4 before the capture interface is passed to a child. | **partial**: a probe that ignores `SIGTERM` can make the final wait unbounded. |
| Live-capture supervisor | `src/capture/live.zig`, `spawnCapture` | One `Live` owns the supervisor PID, data pipe, life pipe, and reader thread. `Live.destroy` closes the life pipe, allows two seconds, then kills the supervisor process group and reaps the exact PID. | EOF on the life pipe stops the capture tool; this also works when xodb dies and closes all descriptors. | It is a fork of the running xodb image and carries no peer state. | **complete**, protocol **not applicable**. |
| dumpcap or tcpdump capture tool | `src/capture/live.zig`, `supervise` | The capture supervisor owns the tool PID and process group. It sends `SIGTERM`, waits one second, then sends `SIGKILL` and reaps. | It exits on capture failure, stdout closure, or the supervisor's teardown signal. `PR_SET_PDEATHSIG` is an extra guard for binaries without file capabilities. | The separate version probe runs first. The data stream must then be a bounded pcap 2.4 stream with an admitted link type, snap length, lengths and timestamps. | **complete**. |
| Locally launched debug target | `src/runtime/process.c`, `xrt_process_launch` | The runtime target and process-tree coordinator own the seized PID and all adopted processes. Launch failure kills and reaps the held child. Session teardown follows the configured detach/kill family policy; owned launches use `PTRACE_O_EXITKILL`. | The launch gate prevents exec before ptrace ownership. After release, the program exits normally or under debugger policy. | This is the user's payload, not an xodb protocol peer. Its executable class, endianness and machine are validated before native control. | **complete**, protocol **not applicable**. |
| Runtime transport command (`xodb-agent`, SSH, or an explicit command vector) | `src/runtime/remote.c`, remote connection creation | One `xrt_connection` owns the socket and exact child PID. Release closes the socket, waits up to five seconds (shortened by cancellation), sends `SIGTERM`, then `SIGKILL`, and reaps before freeing owner storage. | Local agents exit on transport EOF. SSH is expected to close its remote command on EOF; parent signals are bounded fallbacks for the local transport PID. | Every frame carries XRT wire version 2. HELLO precedes target creation, reports architecture and a capability bitmap, and repeated clock probes must agree. No producer build/version is reported. | **partial**: explicit wire and capabilities, missing producer version. |
| Allocation-helper `sudo`/helper chain | `src/profile/allocation_broker.c`, `xodb_allocation_broker_start` | The allocation job or remote perf scope owns the seqpacket FD and returned `sudo` PID. Close waits 200 ms, sends `SIGKILL`, and reaps the exact PID. | The helper exits on socket EOF, first failed request, 1,024 requests, or its 30-second alarm. `sudo -n` either executes the helper or exits without prompting. | Requests and replies carry `XODB_ALLOCATION_MAGIC` (`XAL2`), and the helper checks inherited seqpacket transport plus peer credentials. The parent sends PID and file descriptors before receiving a producer version or capability set. | **gap**: add a startup HELLO with helper producer/version and required uprobe capabilities before target state or descriptors. |
| Remote-GUI SSH client and remote xodb | `src/remote/transport.zig`, `Stream.ssh`; Darwin shim in `src/platform/macos_process.c` | One remote `Client` thread owns `Stream`. Close shuts down the socket, gives the remote server ten seconds to detach, then sends `SIGTERM`, waits 300 ms, sends `SIGKILL`, and reaps the exact SSH PID. | SSH and the remote xodb exit on stream EOF. The remote MCP server owns and tears down its target before closing. | MCP initialize must return protocol `2025-06-18`; the client then requires `get_debug_view` and validates debug-view schema 1. `serverInfo.version` and the declared server capability object are not checked. | **partial**: protocol and required behavior are checked, producer version is not. |
| `xcode-select -p` lookup | `src/runtime/macos_debugserver.c`, `xrt_debugserver_find` | The finder stack owns the exact PID and output pipe and normally reaps it through `xrt_debugserver_close`. | `xcode-select` exits after printing the active developer directory. Reads have a five-second deadline. | Fixed system path and bounded output; no peer protocol. | **partial**: the non-detached close path deliberately does not signal, so a wedged lookup can survive the timeout after its stack owner returns. |
| Apple debugserver | `src/runtime/macos_debugserver.c`, `xrt_debugserver_start` | One GDB connection owns the private socket and `xrt_debugserver` PID. It closes the transport and waits ten seconds. Only an acknowledged GDB `D`/`OK` permits `SIGTERM`; the exact targetless PID is then reaped. | Private transport EOF tells debugserver to release. The target is detached before xodb closes a healthy connection. | GDB `qSupported`, packet size, target XML, register layout, architecture and required operations are negotiated. No explicit debugserver producer version is checked. | **partial**: teardown is intentionally target-safe, while producer version remains implicit. |
| Ghidra sidecar starter and its synchronous compiler/setup commands | `src/semq/ghidra_sidecar.zig`, `start`; `scripts/ghidra-sidecar` | The requesting sidecar job owns the starter PID and waits for it. Cancellation/deadline sends `SIGTERM` and waits. The shell synchronously owns `javac` and setup utilities. | The starter exits after it observes a ready endpoint or reports a bounded startup failure. Synchronous commands exit before the shell advances. | The starter receives no image state. Its result is not trusted as readiness: xodb opens the endpoint and validates HELLO after it exits. | **partial**: the cancel path has no `SIGKILL` escalation and its final wait is unbounded. |
| Shared Ghidra JVM | `scripts/ghidra-sidecar`, detached `java` launch | The JVM owns the Unix endpoint and project. Each xodb session owns one validated hold connection and closes it at session teardown; no single xodb owns the shared JVM process. Explicit stop validates the recorded PID's uid and command before signalling it. | It exits after the configured idle interval with no clients or requests, when its endpoint inode disappears or is replaced, or after acknowledged shutdown. | Before any image path is sent, xodb checks socket type, mode, owner, peer uid, HELLO protocol 1, schema 1, producer `ghidra-jvm-sidecar-0.1.10`, health, uid and required capabilities. One bounded replacement is allowed. | **complete**. |
| Native Ghidra supervisor | `src/semq/ghx_host.c`, `xghx_run` | One static-analysis job owns the supervisor PID and pipes. The child has its own process group and `PR_SET_PDEATHSIG`. Cancellation/deadline sends `SIGTERM`, then `SIGKILL`, and the exact PID is reaped before return. | It exits at stdin EOF, after all queued results, or on termination; it also kills/reaps its worker. | xodb now requires the exact `ghx_supervise` protocol, producer, schema and capability HELLO before writing DECOMPILE. A mismatch, or no HELLO within five seconds (a pre-HELLO supervisor stays silent), is `supervisor_protocol_mismatch`, and no analysis state is sent. | **complete**. |
| Native Ghidra worker | `tools/ghx/ghx_supervise.c`, `worker_start` | The supervisor owns the worker process group, pipes and private spec snapshot. Deadline, cancellation, malformed output and shutdown all end in bounded group kill/reap; `PR_SET_PDEATHSIG` covers supervisor death. | It exits on QUIT, pipe failure, fatal analysis state, or the parent-death signal. | The supervisor now requires the exact worker protocol, producer, function-graph schema and capability HELLO before writing DECOMPILE. A mismatch is `incompatible_worker`; the worker itself refuses DECOMPILE before HELLO. | **complete**. |
| Confirmed overview handoff (`xodb`, optionally inside foot/xterm/alacritty) | `src/ui/overview/actions.zig`, `Launcher.launch` | The overview `Launcher` records up to 16 direct child PIDs and polls/reaps exits while the overview runs. This is a deliberate ownership handoff: teardown does not close a user-opened debugger window. | The launched xodb exits when its own window/session closes; a terminal exits with that command or by user action. Orphan reaping transfers to the service manager when the overview itself exits first. | The child xodb path comes from `/proc/self/exe`, so its build identity is the current executable by construction. It revalidates the sampled PID/start-time identity before attach. The optional terminal is only an argv carrier and has no version contract. | **complete as a documented handoff**; terminal version is **not applicable** to debugger state. |

The sidecar integrity gap fixed with this inventory was the native fallback's
unchecked two-hop connection. Previously xodb wrote the ELF path and function
request to any executable named `ghx_supervise`, which immediately forwarded
it to any executable named `ghx_worker`. Now both hops advertise one exact
contract from `src/semq/ghx_protocol.h`, and each parent checks it before
sending state. Supervisor tests also put an old producer on the worker hop and
prove that the request is not pipelined ahead of HELLO; the debugger integration
does the same for the supervisor hop.

## Remaining work, in priority order

1. Add an allocation-helper HELLO before the first PID or descriptor transfer.
   It should include a producer build/version, protocol version, architecture,
   uprobe PMU availability, retprobe format bit, and the allocation/function
   register modes it supports.
2. Add producer build identities to the runtime-agent HELLO and remote-xodb MCP
   initialize checks. Keep capability checks independent so a compatible newer
   producer can be admitted intentionally.
3. Put the Ghidra starter in an owned process group and bound TERM-to-KILL
   escalation. The script should terminate a just-started JVM if startup is
   cancelled before readiness is handed off.
4. Give the capture version probe a TERM-to-KILL bound, and give the
   `xcode-select` lookup a safe forced-exit path distinct from attached
   debugserver teardown.
5. Record a debugserver producer/version when Apple exposes one without
   weakening the existing capability, architecture and detach checks.

Any new runtime launch must add a row here in the same change. The launch-site
comment remains authoritative for ownership mechanics; this inventory is the
cross-component audit index.
