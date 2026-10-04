# M2: captures across executable mapping changes

Status: approved by the user and implemented, 2026-09-30. This replaces the
initial stop-on-mapping policy. No new dependency. Current behavior and testing
commands are in [PROFILING.md](PROFILING.md).

## User-visible result

Loading a shared library or creating an executable mapping should normally let
an existing capture continue. Each sample is resolved using the mapping evidence
at its timestamp. Existing frames remain navigable after a library unloads.
Anonymous/JIT code stays explicitly unresolved until xodb has its code metadata.

**Measured limitation:** perf does not report munmap or mremap on this workstation,
including a move that replaces another executable image. The proposal therefore
provides history of **observed mapping events**, with explicit attribution limits;
it does not establish complete address ownership. New tracing would be a separate
change. See [the coverage report](research/mapping-events.md).

This follows the Firefox test: opening all 100 threads succeeded, then its first
mapping event ended the capture before useful samples arrived. Games and servers
also load code during execution.

## Approved implementation

1. Keep the stopped opening map snapshot, then retain bounded, timestamped perf
   MMAP/MMAP2 records. Process records in timestamp order across thread rings.
   A mapping replaces attribution only in its overlapping address range; equal
   timestamp conflicts remain unresolved. Late records advance capture revision
   and invalidate affected derived results.
2. Give each observed mapping lifetime its own identity. Cache and aggregate
   frames using mapping/image identity as well as address, so reusing a virtual
   address in a reported mapping transition does not reuse an old function name.
   Unreported moves remain outside the supported attribution contract. Keep captured module IDs
   sufficient to retrieve historical source/assembly without consulting current
   address ownership.
3. Open new file-backed ELF images only after checking recorded device/inode
   identity and deriving load bias from the recorded file offset. Retain the
   image with the capture. Inaccessible, truncated-path, anonymous, unsupported
   identity or otherwise ambiguous mappings remain raw addresses with a reason.
4. Continue across supported mapping changes. Preserve bounded collection and
   explicit stop reasons for exec, new threads outside the selected scope,
   metadata loss, malformed records and capacity exhaustion. Thread subsets
   keep their existing conservative symbol policy. No implicit enrollment of
   browser children or new threads.
5. Expose mapping-history coverage (including the unobserved-move limitation),
   unresolved mappings and stop reasons in the
   shared model, GUI and MCP. Keep the existing capture/revision guards, user
   control and evidence counters. Verify live module identity again before
   browsing the current source workspace.

Initial budgets: 4,096 mapping records and the existing 256 opened-image cap,
16,384 sample cap, and 1,024 selected-thread cap. Reaching a budget reports an
explicit stop or unavailable image; it never silently discards required identity
history. Measure worst-case graph rebuild cost before enabling the new default.

## Kernel evidence gate

The local decoder already retains MMAP2 address, length, file offset,
device/inode, protection, path truncation and sample timestamp. The original
collector requested executable mappings only. The live two-thread probe now establishes how mmap, mprotect, unmap/address reuse
and mremap appear in the actual event stream. Adding `mmap_data` reports tested
non-executable replacements and execute-permission removal. This flag is
part of the integration, with bounded metadata storage and loss checks. Perf mapping records are not a complete memory-management syscall log;
do not label this a complete VMA history.

The Linux [perf ABI](https://man7.org/linux/man-pages/man2/perf_event_open.2.html)
describes MMAP2 identity/protection and the optional mmap_data flag for
non-executable mappings. Upstream
[mprotect](https://github.com/torvalds/linux/blob/master/mm/mprotect.c) reports
mapping changes through perf. Known missing/ambiguous identities retain raw
addresses, and the overall mapping-coverage limitation must remain visible even
when a particular frame has a symbol. Broader
tracing or system changes would require a separate proposal.

## Acceptance

- Deterministic mapping overlap, partial replacement, address reuse, out-of-order
  delivery, duplicate/conflicting timestamps and metadata-loss tests.
- A fixture loads and unloads two distinct ELF images, reuses addresses, and
  executes known hot functions before/after transitions. No old-symbol reuse;
  unaffected code retains its identity, and historical source/assembly survives.
- A second thread changes mappings while both threads are sampled; selected
  subsets remain conservative. Exercise non-executable replacement and
  mprotect behavior found by the evidence gate. Preserve the mremap counterexample
  as an explicit unsupported-case repro; do not claim that MMAP2 detects it.
- Existing CPU, 640-thread, scope, generation, cleanup and private Vulkan tests
  pass. Repeat the disposable headless Firefox check and report whether it ends
  by duration or by a separate thread-scope/identity limitation.
- Journal exact evidence and remaining gaps. LLM analysis can compare hotspot
  paths across library loads and cite mapping identity/coverage instead of
  assuming a process address has one meaning for the whole capture.

## Implementation evidence

- `src/profile/mappings.zig` keeps stable range identities and applies ordered
  changes with overlap splitting. Frame caches and graph nodes include mapping
  identity. Historical source/ELF assembly uses retained image IDs.
- `get_profile_mappings` exposes bounded pages of opening ranges and changes.
  GUI/MCP report observed-history coverage and unresolved identities. UI node
  selection is restored by ancestry when ordinary sample arrival reorders nodes;
  changed mapping evidence invalidates the selection.
- `tests/m2-mappings.py` passes main-thread, worker-thread and selected-subset
  cases: distinct A/B libraries reuse a function address, B loses/regains execute
  permission, and anonymous code remains raw. Historical source/assembly survives
  both unload and process exit. Counts and fd cleanup are checked.
- Kernel probe preserves the **unreported mremap-over-existing-code counterexample**;
  this remains unsupported, with the limitation visible even on symbolized graphs.
- Shared tests, the 640-thread capture and the private Vulkan flame test pass.
  The maximum-budget graph measured 87–95 ms in ReleaseSafe and 558–584 ms in Debug;
  Debug can visibly stall at this bound. See the journal for exact runs.
- The first private Firefox run exposed a mapping-metadata burst overflowing its
  old 16 KiB ring (one sample, 47 reported lost records). Adaptive 4–64-page rings
  preserve the existing total 4,096-data-page ceiling; roughly 100 threads get
  128 KiB each. The repeat reached its 1.5-second deadline with 14 samples and no
  loss. A 10-second request stopped separately at `thread_scope_changed`, with
  20 samples, 1,048 mapping events and no loss. The user's screenshot likewise
  shows that separate guard (22 samples, 451 mappings, 3.883 seconds, no loss).
- Following new threads is deliberately deferred. The user confirmed that full
  Firefox readiness is not required for this increment. The capture continues
  to cover a fixed opening task set and stops when new task creation is observed.
