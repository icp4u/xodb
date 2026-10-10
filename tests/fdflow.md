# System-wide IO stream checks

The stream is a C component for native Linux x86-64. It captures raw syscall
arguments and returns plus named IO exits, without subscribing to named entry
payloads. Compatibility syscalls have no native IO identity. The collector
covers CPUs online when opened, reports individual CPU enrollment failures,
and exposes loss even after the producer stops emitting events. It does not
perform descriptor-to-inode joins.

Fast lane (pure formats, hostile records, CPU ranges and scope refusal):

```sh
scripts/build test-fdflow -Doptimize=ReleaseSafe -j2
```

The fixture is manual/periodic because it requires existing tracefs/perf access
and two permitted CPUs for migration. It does not change host configuration:

```sh
scripts/build fdflow-fixture -Doptimize=ReleaseSafe -j2
zig-out/bin/xodb-fdflow-live
zig-out/bin/xodb-fdflow-live --tiny
zig-out/bin/xodb-fdflow-live --partial
zig-out/bin/xodb-fdflow-live --burst-silence
```

Permission denial exits 77 with a reason. If running it with existing root
access, prefix the fixture command with `sudo -n --`. Every event is filtered
to its single owned child before enabling; none of these tests captures other
processes. The normal case checks 17 read bytes and 17 write bytes, an entry
and exit on different CPUs, and a compatibility `getpid` that must not become
native `writev`. `--tiny` drains one record at a time. `--partial` limits the
ring budget to one CPU and checks the remaining failures. `--burst-silence`
overflows a small ring, then stops the child and checks the cumulative loss
counter without relying on a later event. All cases check handle cleanup.

Tests use always-on CHECK even with NDEBUG. The pure binary accepts
`--wrong-oracle`, which must fail; sanitizer runs and this negative control
belong in component review. CPU/wall/RSS measurements printed by the live
fixture are evidence, not timing gates.

Sampled inode counters have a separate fast lane and owned reuse fixture:

```sh
scripts/build test-fdflow-count fdflow-identity-fixture -Doptimize=ReleaseSafe -j2
zig-out/bin/xodb-fdflow-identity-live
```

The fixture cross-checks two memfds: 17 bytes remain attributed to the old inode;
5 bytes written just after `dup2` stay unattributed until a fresh poll; the new
inode then starts with 7 attributed bytes. All 32 write bytes, including its three
one-byte synchronization acknowledgements, are counted. Polling identities are
sampled correlations, not atomic kernel-file proofs. Mutations, stale samples,
loss, partial CPU coverage and pending calls keep uncertain bytes explicit.
Processes observed using asynchronous io_uring descriptor operations lose inode
correlation until a new capture or a proved new process identity. Only native
x86-64 descriptor-mutating numbers withdraw correlations. Raw records carry no
ABI, so a compat (`int $0x80`) or x32 close/dup in ABI-switching code is not
seen as a mutation and a later native IO on that fd can be joined to the old
inode; that code is outside coverage. Raw numbers alone never establish a
native operation.

The integrated worker and graph projection have fast, unprivileged checks:

```sh
scripts/build test-fdflow-order test-fdflow-owner -Doptimize=ReleaseSafe -j2
```

The merge regression drains interleaved CPU rings one record at a time and
checks global timestamp order, a future cutoff, a genuinely late commit and a
malformed record after a valid prefix. The worker test blocks the real polling
worker while synthetic event counts and stop still advance. It checks idle
rates, passive readers, failed-open retry and cleanup. Projection checks include
merged cgroups, focused fds, reused identities and peer endpoint activity. Each
new pure fixture accepts a planted wrong value through `--wrong-oracle` and
uses CHECK with NDEBUG. The worker's `--expiry` case belongs to the periodic
lane because it waits for the real three-second demand lease.

Manual/periodic private-display integration (existing permissions only):

```sh
python3 tests/fdflow-gui.py --work-dir "$(mktemp -d)" --expect-denied
python3 tests/fdflow-gui.py --work-dir "$(mktemp -d)" --binary ./xodb-private-launcher
```

The second command accepts an existing launcher that preserves the private
display environment (for example, a local `sudo -n -E` wrapper). The test always
supplies two owned fixture PIDs; every tracepoint is filtered before enabling.
It checks the visible cost banner, matched inode rates in both views, E off/on,
pause, pane exit, passive MCP reads and text layout. It never launches on the
interactive desktop. GUI checks are periodic, not a fast gate.

## Counter churn

Fast lane (pure, accelerated, part of `scripts/build test`): 40,000 short-lived
pids across 20 polls, a 131,072-pid flood with no poll, and 1,048,576 replaced
connections. It checks that the process/thread tables stay at the live set, rows
stay at the live descriptors, no cap is hit and churn never withdraws a steady
writer's joins. Per-record and per-publication costs are printed as evidence:

```sh
scripts/build test-fdflow-churn -Doptimize=ReleaseSafe -j2
```

Live (manual/periodic, needs root or CAP_PERFMON, exits 77 otherwise): forks
25,000 short-lived owned children under host-wide capture with the owner's 10 ms
drain and 1 s poll, then prints per-phase drain cost per record and ring loss as
aggregates. Read loss against the recorded load average:

```sh
scripts/build fdflow-churn-fixture -Doptimize=ReleaseSafe -j2
sudo -n -- zig-out/bin/xodb-fdflow-churn-live 25000
```
