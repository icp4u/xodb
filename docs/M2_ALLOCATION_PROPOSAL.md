# Allocation tracing for the demo

2026-10-03. **Adopted; scoped live and private-GUI tests passed.**

## Concrete workflow

- Native Linux x86-64 first. Stop after the allocator library is loaded.
- **A** opens the allocation inspector; **P** or Start captures the currently
  selected stopped thread. Space continues/pauses; P stops; Esc closes the panel.
- The default hooks are the defined runtime functions malloc, calloc, realloc
  and free in the unique executable libc.so.6 mapping. Missing or ambiguous
  symbols fail explicitly. This does not imply language-runtime/custom-allocator
  coverage.
- MCP exposes start_allocations, stop_allocations, get_allocation_capture and
  paged get_allocation_events/calls/lifetimes. Start accepts 1–32 explicit TIDs,
  an optional executable mapping address and up to 16 named allocator hooks.
  Control scope and a current target generation are required to start/stop.
- Source preparation and descriptor creation run on a worker. The target must
  remain at the same stop until preparation completes. Only the session thread
  enables events, after rechecking target/image/thread identities.
- Defaults: 60 seconds, 32,768 entry/return records and 32 MiB for retained
  metadata/evidence/analysis. Explicit JSON prefs and MCP may set duration
  (zero means unlimited), 2–131,072 records, and 1–128 MiB.
- One retained allocation capture per process. A failed replacement preserves
  the previous capture. Starting another successful capture replaces it.
- Calls, Lifetimes, Outstanding and Events share the same evidence model in
  GUI/MCP. Stable finalized pages carry session/capture/revision citations.
  Lost, unpaired or rejected evidence remains inspectable; lifetime totals
  become unavailable across a gap.
- No allocation archive or allocation flame graph in this first slice. MCP
  pages can be saved by a client. CPU capture/archive behavior is unchanged.

## Explicit helper option

The ordinary-user direct open is attempted unless the launch command supplies:

```sh
./zig-out/bin/xodb --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper"   --break allocation_ready -- ./path/to/fixture
```

That option permits a worker to invoke **sudo -n -- HELPER --stdio**.
There is no password prompt in the GUI, implicit escalation, persistent
service, listening socket, sysctl change, tracefs write or file capability.

The C helper accepts an inherited Unix seqpacket socket. It checks peer
credentials and verifies every requested TID is held in a ptrace stop by that
peer, belongs to the requested process and has the peer's UID throughout its
credential set. The supplied runtime ELF descriptor must be regular x86-64 ELF
and its executable offset must correspond to that target's mapped inode.
The helper fixes all perf attributes itself, opens task-specific disabled
uprobes and returns descriptors with SCM_RIGHTS. It exits at EOF/error, after
at most 1,024 requests, or after a 30-second alarm. The normal user maps,
enables, drains, closes and analyzes the events.

A sudo timestamp or separately administered policy is required on hosts with
this permission restriction. Installing a broad sudoers rule for a writable
checkout helper would be unsafe and is not part of this proposal. Run the GUI
as your normal user.

## Critical review

This finishes a useful inspection path without making the debugger GUI root.
However, every recorded allocator call involves probes on entry and return:
expect workload-dependent overhead, potentially large for tiny allocations.
Fixed explicit thread scope is honest but can miss frees on other threads;
preexisting allocations, unhooked allocators and excluded threads remain outside
coverage. Outstanding allocations are not automatically leaks.

The privileged helper is additional code to review. Its short lifetime and
narrow protocol reduce exposure but do not make it a security sandbox or a
production privilege deployment policy. Real fd transfer, normal-user mmap and
actual glibc entry/return behavior passed the scoped tests below. Representative
application overhead and a general deployment policy remain future work.
[Results and corrections](research/allocation-tracing.md#adopted-live-capture-2026-10-03).

## Prepared scoped test

Reviewable code: src/profile/allocation_broker.c,
src/profile/allocation_live.zig, tests/fixtures/allocations.c,
tests/allocations-live.py and tests/allocation-helper.py.

```sh
XODB_BIN="$PWD/.work/allocation-demo/out/bin/xodb" timeout --signal=TERM --kill-after=2 90s python3 tests/allocations-live.py   --helper "$PWD/.work/allocation-demo/out/bin/xodb-allocation-helper"
```

Python and xodb run as the ordinary workstation user. Only the explicit helper
uses sudo, and it receives only this test's own traced child. Scenarios cover
known allocation/free/realloc sizes, a full store, ring loss, exec/fork/exit,
cancellation and stale preparation. Each fixture is owned and reaped by xodb.
The helper expires independently; files and logs remain inside the checkout.
No existing application, host configuration, guest or phone is touched.

A private headless Sway GUI check will exercise the same owned fixture and helper,
with a 90-second outer deadline, then close the temporary compositor and child.
The helper may be rerun only for these bounded owned-fixture checks and necessary
fix verification. Permission for the earlier one-off wrapper probe did not cover
this integration test.

## Evidence before privileged testing

- Native ReleaseSafe gate: 289 passed, four ARM-specific skips, all 29 build steps.
- Helper rejection checks passed unprivileged outside the Unix-socket sandbox:
  malformed packet, bad descriptor count/flags, untraced process, extra ancillary
  descriptors and non-socket input.
- Ordinary-user allocation startup reaches perf_event_open and returns EACCES
  with no leaked perf descriptors. An initial check also found the start audit
  event advanced generation; the candidate now includes that known audit change
  in the expected preparation generation. The rerun passed with
  AllocationCollectorOpen / permission / errno 13 and no leaked descriptors.
- Production GUI denial path passed on a private compositor at 1280×800 and
  720×480, including A/P, close/return to source and clean shutdown.

Normal completion also closes perf descriptors on a worker before finalizing;
actual kernel teardown caused a 262 ms event-loop stall before that correction.
