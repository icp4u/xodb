# GDB remote targets

Connect the existing GUI or MCP session to a target already prepared by a GDB
remote stub:

```sh
# Terminal 1: the stub launches the program and waits.
gdbserver --once 127.0.0.1:2345 ./program
# Terminal 2: xodb controls that stopped target.
xodb --gdb-remote 127.0.0.1:2345
```

For an existing process, prepare the stub with
`gdbserver --once --attach 127.0.0.1:2345 PID`. The target belongs to the stub;
do not combine `--gdb-remote` with xodb's `--attach`, a launch command, an agent
transport, process following, or a core/archive. Detach restores xodb's software
breakpoints and asks the stub to detach. xodb never kills a remote PID as though
it were a local child. Restart and launching another program through an existing
connection are unsupported.

The endpoint accepts a DNS name, IPv4 address, or bracketed IPv6 address plus
port. TCP has no authentication or encryption: use a trusted connection or an
SSH port forward. A non-loopback connection prints a notice on stderr. Serial and pipe transports are not implemented.

## Available operations

Supported register descriptions are `i386:x86-64` and little-endian `aarch64`.
The target description supplies register numbers and widths; names map onto
xodb's architecture descriptors. Missing registers and `x` bytes stay
unavailable. A complete-register prefix in the bulk reply is valid: QEMU leaves
optional register banks out of that reply. FP/vector and system registers are
parsed for layout but are not exposed as general registers. Big-endian targets
are outside this backend's scope.

Memory reads, verified memory/register writes, software address breakpoints,
instruction stepping, continuation, thread lists, stop events and detach use
the same session and generation checks as native debugging. Breakpoint stops
use the PC reported by the stub, which has already applied its own trap-PC
adjustment. Continuing at an installed breakpoint temporarily removes it,
steps that thread, restores it, and continues. AArch64 exclusive/ordered memory
instructions refuse instruction stepping and breakpoint step-over before
execution; an exclusive sequence is not split into single steps.

The client negotiates `qSupported`, `target.xml` and its remote XML includes,
`vCont?`, optional no-ack mode, all-stop mode, and `qAttached`. Non-stop mode,
process following and remote exec adoption are unsupported. An unexpected
fork/exec stop requires a new target admission.

The MCP session contains a `gdb_remote` object with architecture, packet size,
register count, attach provenance, last reason, and capability states:
`available`, `unsupported`, `failed`, or `not_tested`. An advertised step
capability is distinguished from operations such as register writes and
software breakpoints, which become available after confirmation.

| Operation | gdbserver x86-64 | QEMU user x86-64 / AArch64 |
| --- | --- | --- |
| XML general registers; memory reads/writes | Supported | Supported |
| Register writes | Verified `P`, or a verified `G` prefix fallback | Verified `P` |
| Address breakpoints; step/continue; threads | Supported | Supported |
| Stub without `Z0` support | Address breakpoints unsupported; no memory-write fallback | Address breakpoints unsupported; no memory-write fallback |
| Asynchronous interrupt | Supported in the owned launch/attach fixtures | Failed with the tested 11.1.1 user-mode stubs |
| Detach while stopped | Supported | Supported |
| Hardware watches; library maps; binary `X` writes | Unsupported by this client | Unsupported by this client |
| Source/symbol breakpoints, source stepping, module-backed stack/locals | Unavailable without remote library/image support | Unavailable without remote library/image support |

Memory writes use hexadecimal `M` packets. Register writes first try `P`; if
unsupported, a `G` write uses only bytes read from the stopped target, with the
requested register changed. An unavailable suffix can be omitted; unavailable
holes are refused. Every confirmed write is reread. An error reply, transport
failure, or read-back mismatch still invalidates the old generation. An
unconfirmed breakpoint change prevents resuming until its operation is retried
successfully or the target is detached. After a transport failure, destroying
the local target releases its storage; it cannot confirm remote detach or
breakpoint cleanup.

The tested gdbserver needs an initial stop query before fetching its XML. It
also directs asynchronous interrupt to the attached target's process group;
an attached process without a matching group can fail to interrupt. QEMU
user-mode does not service this TCP interrupt while freely running in the
tested version. Use breakpoints to retain control. An interrupt request does
not itself claim that the target stopped. A bounded stop wait reports
`StopTimeout` and retains the running state and connection, allowing a later
stop to be observed.

## MCP and QEMU examples

```sh
xodb --headless --mcp --agent-scope mutate --gdb-remote 127.0.0.1:2345
```

Inspect `get_session`, `list_threads` and `get_registers`. Set a breakpoint with
`set_breakpoint {"address":"0x...","generation":...}` using an address from
your own binary. Symbol/module queries report `GdbLibrariesUnavailable` until
that data path is implemented. Raw disassembly uses the selected architecture
when the installed decoder supports it.

For a static AArch64 program on an x86 host:

```sh
qemu-aarch64 -g 2345 ./program-aarch64
xodb --gdb-remote 127.0.0.1:2345
```

This operates through the QEMU stub; it does not attach to QEMU as a native
x86 process. The reported thread IDs are remote identifiers. The client does
not read local `/proc` files using those IDs for target memory or registers.

## Bounds and validation

Packets are limited to 64 KiB decoded, with a bounded escaped frame, checksum
validation, at most three retransmissions, and at most 128 frames per receive.
TCP connect and individual request waits have five-second deadlines. All
exchanges in one target call share a ten-second operation deadline; opening
a target has a thirty-second budget. Exhausting the operation budget fails
the connection, even if the stub keeps sending individual replies. DNS
resolution uses the system resolver and its own timeout policy; it cannot be
interrupted by these deadlines. Calls are synchronous, so a slow stub can
still pause its caller until the deadline. XML has a 1 MiB aggregate
limit, 32 documents, eight include levels, 1,024 registers, and 4 MiB of
register-layout metadata. XML includes are remote annex names only; external
DTDs are ignored and entity declarations are rejected. Thread/event/breakpoint
storage follows the target API's fixed limits. Thread limits apply to the
current inventory, rather than every distinct thread seen over a session.

```sh
scripts/build test -Doptimize=ReleaseSafe -j2
make -C src/runtime check -j2
python3 -B tests/gdb-remote.py --work .work/gdb-stubs
```

The integration test creates owned fixtures, compares C API and MCP operations
with native debugging, checks two real gdbserver threads, and tests QEMU user
stubs on both architectures. Its QEMU flows stop at breakpoints and deliberately
do not claim asynchronous-interrupt support. Results distinguish pass, fail
and missing-dependency skips. Separate packet/XML fuzz harnesses accept
attacker-controlled input; `runtime-gdb-model.c` tests false confirmations,
unavailable capabilities, and retryable detach against a synthetic stub.

Protocol references: [GDB remote protocol](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Remote-Protocol.html),
[target descriptions](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Target-Description-Format.html),
and [QEMU GDB usage](https://www.qemu.org/docs/master/system/gdb.html).
