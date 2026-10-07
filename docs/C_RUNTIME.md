# C runtime

Target execution and kernel collection live in `src/runtime/`. Both the local
debugger and the standalone agent use this implementation. Zig retains the GUI,
MCP, symbols, source stepping policy, DWARF analysis, expressions, profile decoding
and archives. See the agreed [C/Zig boundary](ZIG_TO_C.md).

## Build and try it

The ordinary application build also produces `zig-out/bin/xodb-agent`:

```sh
./scripts/build -Doptimize=ReleaseSafe
./zig-out/bin/xodb --runtime-agent ./zig-out/bin/xodb-agent \
  --break change_value -- ./zig-out/bin/xodb-m1-fixture
```

Press **Space** to reach `change_value`, **F11** to step into a source line (or an instruction when source is unavailable), **Tab** to
inspect registers, and **F10** to step over a source line. Omitting
`--runtime-agent` uses the same C runtime in the host process.

For a target machine, build with a normal C11 compiler and Linux development
headers. The agent links libc, pthread and libatomic; it needs no Zig, Capstone,
libdw, graphics libraries or generated bindings. Run from a source checkout:

```sh
make -C src/runtime CC=gcc BUILD="$PWD/.work/c-runtime" all
make -C src/runtime CC=gcc BUILD="$PWD/.work/c-runtime" check
# Or use CC=clang and a separate BUILD directory.
```

The output is `libxrt.a`, `xodb-agent` and `xodb-lsof-top` (the
[live open-file view](LSOF_TOP.md), the same program as `xodb --lsof-top`).
Copy the agent to a work directory on the target, then use its absolute path:

```sh
./zig-out/bin/xodb --runtime-ssh my-target --ssh-config ~/.ssh/config \
  --runtime-agent /home/dev/xodb-build/xodb-agent \
  --break main -- /home/dev/debug-program
```

SSH uses batch authentication and no PTY. Host command arguments are passed
directly to exec; the remote agent path is shell-quoted. Target program arguments
travel as separate wire strings. Relative program paths are relative to the
agent's working directory. Source files are still resolved by the host; use the
existing source maps when paths differ.

`--headless --mcp` works with both commands. This stream is separate from the
older `--ssh` / `--connect` GUI-to-MCP connection, which remains available.

To profile through a local agent:

```sh
./zig-out/bin/xodb --runtime-agent ./zig-out/bin/xodb-agent \
  --capture-out remote.xoc --break main -- ./zig-out/bin/xodb-profile-fixture 5
```

Press **Space** to reach `main`, **P** to start sampling, **Space** to run, then
**P** to stop sampling while it runs (or let the target exit). Press **F** for
flames. Exit normally to finish saving, then reopen with
`xodb --open-capture remote.xoc`. See [capture and comparison](PROFILE_COMPARISON.md).
For remote allocation capture, `--allocation-helper /target/path/to/helper`
explicitly selects the existing privilege helper **on the target**; the agent
never automatically elevates itself. [Allocation setup](ALLOCATIONS.md) applies.

The same helper and matching C agent support fixed-scope x86-64 function
entry/return observations. The C runtime owns probe setup and raw collection;
the host retains and compares the evidence. See [function recipes and saved
investigations](OBSERVATIONS.md) for a Ruby example and the CLI/MCP workflow.

## Supported operations

| Target ISA | Execution and analysis | Additional support |
| --- | --- | --- |
| x86-64 | Launch/attach, threads, signals, break/step, registers/memory, host symbols/DWARF | Hardware watches, fork/vfork coordination, SIMD/FP, CPU/syscall/allocation capture |
| AArch64 | Existing execution backend now in C; target registers and host ISA selection | Hardware data watches; no process following or remote profiling |
| m68k | GCC-built agent tested in the VM: launch, break/step, GPR writes, ELF32 big-endian files, host disassembly, CFI and expressions | Hardware watches, FP state, process following and profiling explicitly unsupported |
| LoongArch64 | GCC-built agent on a LoongArch64 Linux host: launch/attach, threads, signals, software breakpoints, register and memory read/write, host symbols, CFI and expressions. Host assembly is decoded when xodb links the private Capstone 6 prefix | Hardware watches, CPU/syscall/allocation capture and uprobes explicitly unsupported. The default system Capstone 5.x build reports disassembly unavailable. Single-step is refused while the row's hardware step is off. `r0` is read-only. This slice reads the general regset |

Kernel permissions and kernel feature availability are checked by each operation.
Unsupported architecture/capability, permissions, transport failures and stale
state have distinct results. AArch64 was cross-compiled during this migration;
no new live ARM64 run is claimed. m68k big-endian DWARF bit pieces remain explicitly
unsupported; ordinary byte pieces work. Core dumps remain host-side analysis.

## Ownership and protocol

Public C headers describe opaque target/collector handles, immutable views and
explicit destruction. One OS thread owns ptrace and related target families.
Metadata transfers and allocation preparation may run in workers; the proxy
serializes requests, and these operations never publish a target snapshot.
Workers must finish before destroying their target. Active collectors prevent
target destruction. Failed detach retains its handle for an explicit retry.

The private protocol is experimental version 1, with no compatibility guarantee
between development revisions. Build host and agent from the same revision.
The 32-byte big-endian header contains `XRT1`, u16 version/opcode, u64 request ID,
and u32 target/status/body length/flags. Requests use flags 0; replies use flags 1.
IDs must increase by one. Frames have a 1 MiB ceiling and a 10-second deadline;
operation blobs have a 64 KiB ceiling. Native C structs never cross the stream.
`rpc.h`, `wire_target.c` and `perf_wire.c` define the field order and validation.

Execution mutations carry the expected authoritative generation. Replies carry
complete bounded snapshots with contiguous event suffixes; malformed snapshots
break the connection. Stale mutations return the current snapshot without
executing. The agent polls and waits only on its known TIDs. A broken stream
closes files and collectors, kills owned launches, and attempts to detach
attached processes. Cleanup failure is reported separately in the agent's exit
status; the host retains failed-cleanup handles.

The connection supports 128 target handles, 32 file transfers and 32 collectors.
Each target has at most 1,024 threads, 4,096 retained events, 128 software probes
and four hardware watch slots. Mapped ELF transfers are identity-checked before,
during and after reading (256 MiB ceiling); bounded proc metadata uses a 4 MiB
ceiling. Host copies are sealed memfds, so analysis never silently opens the
target's path on the host. Large debug assets must fit the existing snapshot
budgets. Target page size, clock tick rate, register widths and endianness come
from the agent.

Remote perf fragments contain complete records and an explicit producer layout.
Only the decoded prefix is acknowledged; the agent verifies record boundaries
before advancing the kernel tail. Zero-consumption retries retain the bytes.
Loss, capacity and collector failures retain the same meaning as local captures.
The agent enrolls held newborn threads before resuming them when CPU capture
follows threads. Syscall/allocation capture retains its explicit thread scope.

Remote timestamps are correlated to the host monotonic clock using the shortest
of four initial round trips. Half that round trip is the initial uncertainty;
clock drift is not measured. Captures preserve target boot/clock provenance and
use the host boot domain for normalized times. CPU archives add optional PROD
metadata in [format 2.6](M2_ARCHIVE_FORMAT.md); native captures retain their
previous minor version.

## Verification

```sh
./scripts/build test -Doptimize=ReleaseSafe --summary all
make -C src/runtime check
python3 tests/runtime-agent.py
python3 tests/runtime-host.py
python3 scripts/gui-smoke.py --m1 --runtime-agent
XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent python3 tests/m2-profile.py
XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent python3 tests/m2-dynamic-threads.py
XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent python3 tests/syscall-timing.py
XODB_RUNTIME_AGENT=./zig-out/bin/xodb-agent python3 tests/allocations-live.py \
  --helper "$PWD/zig-out/bin/xodb-allocation-helper"
```

The last command explicitly exercises the existing sudo helper workflow. The
GUI test uses a private headless compositor. For the cross-ISA host check, compile
`tests/fixtures/runtime-isa.c` with `-g -O0 -fno-omit-frame-pointer -fno-pie -no-pie`
on the target, then pass `--ssh HOST --ssh-config FILE --agent /path/xodb-agent
--fixture /path/fixture --arch m68k` or `--arch loongarch64` to `tests/runtime-host.py`.
On LoongArch64 that script expects instruction step, watchpoints, profile and
uprobes to report unsupported, and it removes the breakpoint before continuing.
Disassembly is refused on the system Capstone 5.x build and decoded when the
binary was built with `-Dcapstone=vendored`. Instruction step and
continue-from-breakpoint return unsupported control. The row is LP64D, little-endian ELF machine 258. `csr_era` is the PC
and has no DWARF number; `r1` is the return-address column and `r3` is the stack
pointer. `r0` is read-only: the value is the kernel's saved slot, not the
architectural zero register. The glibc loader rendezvous is skipped, before
loader discovery, because resuming a planted breakpoint takes a hardware step.
The measured agent ran under QEMU loongarch64 with no hardware watchpoint unit,
so this row keeps hardware step off until a machine with a debug unit is measured.

## Portable agent startup and bounded breakpoint discovery

Zig builds `xodb-agent` and the allocation helper for the target's baseline CPU,
independently of the workstation CPU. The GUI can still use the selected host
CPU. A baseline ISA does not lower the selected libc version: build against the
remote machine's libc/ABI when those differ. Agent startup failures report the
transport exit status or signal; SIGILL includes a CPU compatibility hint. SSH
retains a shell so a signalled agent can report its signal-derived exit status.
The remote account's login shell must accept POSIX shell syntax for this wrapper.

Loader rendezvous discovery reads `auxv`, the executable's `PT_DYNAMIC` /
`DT_DEBUG`, and (during early startup) only the interpreter's dynamic exports.
It downloads no complete image. Reads are limited to 128 KiB / 128 requests and
two seconds between requests; unsupported or uninitialized metadata leaves
explicit loader status and resolves pending breakpoints at later ordinary stops.
An older agent without auxiliary-vector support reports that it needs updating.

Remote symbol lookup skips device, anonymous, memfd and deleted mappings.
Automatic breakpoint resolution also skips files without executable mappings
and yields after a 25 ms or 128 KiB slice, between bounded transport requests.
Unfinished discovery resumes at the same stop, keeping its file and region
progress. Explicit `find_symbol` uses the same symbol-only reader and caches,
without an automatic-discovery time slice. Non-ELF signature failures are remembered by device,
inode, size, mtime and ctime; replaced or modified files are checked again.
`get_breakpoints` reports `loader_reads` and `symbol_transfer` counters, including
negative-cache hits, skipped files, resumed bytes, cached symbol images and
retained symbol bytes. Only ELF headers, build-ID notes, dynamic metadata,
symbol tables and their linked string and extended-index tables cross the transport. Large code, data and DWARF
sections do not count against a symbol search. A 64 MiB or 244 MiB image can
therefore resolve a breakpoint without a complete download.

Completed symbol views are immutable, sealed snapshots, separate from full
binary/debug images. One incomplete file retains its ranged reads and agent
file descriptor across passes; every read and the final close verify its inode
version. No partial view is published. Each slice permits at least one bounded
read even if opening the file consumed the time budget; cancellation and byte
limits still apply. This lets discovery advance when round-trip latency exceeds
the nominal 25 ms slice.
Ranged symbol reads have no 256 MiB whole-file ceiling: a tested executable
with 300 MiB of real data transfers only its selected metadata. The host requests
this using the symbol-purpose flag on FILE_OPEN; ordinary requests, including
older hosts, retain the snapshot cap. An older agent can still refuse the large
image without ending the session; `SymbolFileAgentUpdateRequired` means
"agent needs updating: large symbol files unsupported". Native sessions without
`--runtime-agent` still have the 256 MiB image limit, including symbol lookup.
Selected symbol
data is limited to 64 MiB per image, with 1,024 cached images and 128 MiB of cached source bytes per module collection. Unsupported or
malformed ELF metadata is reported. Sectionless ELF dynamic-symbol lookup is not provided by this symbol-only path.
APK lookup, code inspection and DWARF loading keep the existing full-image
reader and its limits. Module IDs remain stable when a full view is loaded. Verified host debug companions can supply symbols using the build ID.

`SymbolDiscoveryPending` means a time slice ended with more discovery to do;
`SymbolDiscoveryBudgetExceeded` and `SymbolDiscoveryCancelled` distinguish byte/
file-budget exhaustion and cancellation. A searched but absent symbol remains
`BreakpointSymbolNotLoaded`. SIGINT cancels between requests. A reply already in
flight retains the normal ten-second transport timeout, including file cleanup;
crossing a discovery deadline never closes a healthy transport. One in-flight
request can extend the slice; this is cooperative scheduling, not a hard
network-response deadline.
Measured observer latency at 1 MiB/s was 90 ms worst through a local stdio proxy
and 680 ms through real SSH. These are separate measurements, not a latency
guarantee; queued channel data and control replies can extend the wait.

A `continue` requested during automatic discovery is queued while the target
stays stopped. `get_session` exposes `symbol_discovery_pending` and
`continue_pending`; wait for both to clear when waiting for a visible stop.
An internal loader stop also stays stopped until its discovery completes.
A symbol that never loads can hold the first stop for a complete search of all
eligible mappings (13 seconds in a 200-library SSH test at 1 MiB/s). Cancel
cancels the queued continue; discovery finishes while the target stays stopped.
Installing a resolved breakpoint is outside the file-transfer budget. A yielded
installation keeps discovery pending until it succeeds or returns a terminal
diagnostic. Restoring a saved address by build ID uses the same bounded symbol
metadata and load-placement reads, so it does not require a full image inside
one slice. Background installation can change the generation while stopped:
clients must refresh `get_session` and retry a rejected `StaleSnapshot` action.
Interrupt, a changed target generation or image, scope loss, and controller
lease expiry/release cancel the queued continue. Reclaiming control, even as
the same client, does not revive it. Renewing an unbroken lease preserves it.
`DeferredContinueCancelled` reports cancellation of a queued continue. The
controller's own state-changing action during the hold, such as adding a
breakpoint, also cancels it. A fresh continue can resume after cancellation. In the GUI the Continue button
becomes Cancel while a continue is queued; Space cancels it without running the
target. Instruction/source-step requests
while discovery is unfinished return `SymbolDiscoveryPending` for retry.
`symbol_transfer` counters accumulate across the slices at the stop and reset
for the next generation. A relocation failure that prevents completing the pass
cancels queued continue, run-to and finish, preserving the stop and reporting
`step_diagnostic`; a new explicit action is required.

Try the owned large-file/slow-transport regression with
`python3 tests/symbol-discovery.py`. It uses a local agent proxy, two MCP clients,
and a generated 300 MiB executable under the test work directory.
`python3 tests/symbol-discovery-install.py` uses a sparse library with symbol
tables above 1 GiB and forces the completing read past its deadline. It checks
the first call, the first call after Interrupt followed by a fresh continue,
and address-breakpoint restoration after restart in a 256 KiB executable.

`run_to` and frame finish run until the requested stop, another visible stop or
user cancellation. There is no implicit wall-clock deadline. Frame finish also
matches the selected caller's stack position; deeper recursive returns by that
thread are progress, not wrong-thread hits. `RunToNoProgress` stops after 64 hits
by other threads. The owned temporary probe is removed; an existing user probe
remains. These internal stops retain truthful target
generations. Controller lease acquisition is independent of target generations,
so it remains available during the operation; execution and mutation still
require a fresh generation.

For an owned remote fixture, copy the matching baseline agent and fixture to the
lab machine, then run:

```sh
xodb --runtime-ssh lab --runtime-agent ./xodb-agent \
  --break change_value -- ./xodb-m1-fixture w
```

Press **Space** to reach `change_value`, **F10** to step, and **Space** again to
continue. The runtime-agent route uses the normal local workspace and its panes.
`python3 tests/remote-stops.py` checks the owned many-mapping fixture locally;
add `--ssh-config FILE --ssh-host HOST` for an owned SSH server sharing the test
checkout. It loads 200 real ELF libraries plus large and late-loaded libraries.
The test does not create keys or alter SSH configuration.
