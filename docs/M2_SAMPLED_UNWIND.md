# Sampled registers/stacks and derived callers

T10/T16 are integrated on Linux x86-64. Stack capture is **off by default**.
Flames initially use recorded kernel callchains; **B** explicitly selects
reconstructed stacks for a completed capture. **I** compares one sample's recorded
and derived frames. The same reconstruction is available through MCP.
[Adopted design, critical review and evidence](M2_DERIVED_VIEW_PROPOSAL.md).

## Enable it

In an explicitly loaded preferences file:

```json
{
  "profile": {
    "user_stack_bytes": 4096,
    "user_stack_budget_bytes": 33554432
  }
}
```

Run `./zig-out/bin/xodb --config YOUR_FILE --attach PID` or launch your executable
normally with that config. The same fields are optional MCP `start_profile`
arguments. Omitted values use next-capture defaults; explicit arguments change
only that capture. In the profile view (**F**), **S** opens setup: choose stacks
off/1/4/8 KiB and a total budget of 8/32/64 MiB (the narrow budget chip cycles).
The presets affect the next capture. The default remains off / 32 MiB.

| Setting | Default | Accepted values |
| --- | --- | --- |
| user_stack_bytes | 0, disabled | 0 or multiples of 8 from 64 through 8192; 4096 is a useful first request |
| user_stack_budget_bytes | 33554432, 32 MiB total | 0 through 67108864, 64 MiB hard bound |

The total budget counts retained stack bytes, independently of register/record
metadata, raw sample count, ELF snapshots and archive work. Metadata capacity and
the stack buffer are allocated before collection starts. An allocation failure
rejects that start. No partially initialized capture replaces the prior one.

Only the kernel-reported valid prefix is copied, before the collector reuses its
drain buffers. When a nonempty dump cannot fit, later nonempty dumps are marked
`budget`; CPU samples and registers continue. Unused tail space is not filled by
smaller later dumps. One stderr diagnostic reports exhaustion, including that
capture/ring-copy overhead continues. Zero budget deliberately retains registers
without nonempty stack dumps. `get_profile.capture.sampled_state` reports totals.

Retention follows **drain order**, not globally sorted timestamps. The first
missing sample ordinal does not certify complete evidence before its timestamp.
Use per-sample status and filtered coverage before drawing conclusions.

## Native workflow

1. Pause at a useful point after initialization. Open **F**, then **S** and choose
   **4 KiB** stacks; leave the **32 MiB** total budget for a first try. Close S.
2. **P** starts capture, **Space** runs the target, and **P** stops collection.
   Stopping collection does not pause the target.
3. **B** switches to reconstructed flames. A worker builds the selected time/TID
   view; the header reports progress or a specific unavailable/error state.
   **B** returns to recorded callchains. A failed build needs an explicit retry:
   switch B back and forth, or use MCP `retry:true`.
4. Click a reconstructed node, then **I** to inspect a sample that contributed to
   it. With no cited node selected, I chooses the first sample in the filter.
   Recorded kernel items and derived frames occupy separate columns.
5. **[ / ]** moves between matching sample ordinals. Wheel or Up/Down scrolls
   frames; displayed/total counts make hidden rows explicit. **I/Esc** closes.
   The timeline filter applies to both graph bases and sample navigation.

Counts retain every filterable sample: **complete** (CFI reached its declared
end), **partial** (leaf and some callers), **leaf only**, **no stack**, or
**excluded** at the graph node limit. Missing callers form explicit boundary
nodes. Complete does not recover inline or optimized-away calls. An empty filter
shows no sample; it does not substitute sample zero.

Reconstruction needs a completed capture with stack capture enabled. Save,
per-sample inspection and reconstruction share one worker; the UI waits behind
other jobs, and a new capture may report `ArchiveBusy` until completion or
cancellation. Esc cancels a running worker when the inspector/setup is closed.
GUI and MCP requests do not cancel one another's builds merely because their
filters differ. One result is cached, so revisiting an evicted filter rebuilds.

Speedscope export (`export_profile` or `--profile-out`) still exports recorded
callchains, including when the GUI is showing reconstructed flames.

## Reconstructed flames over MCP

Use a completed capture's ID/revision, and the same optional `tid`, `from_ns` and
`to_ns` filters as the recorded graph:

```json
{"name":"get_flamegraph","arguments":{"capture_id":1,"revision":10,"basis":"reconstructed"}}
```

Repeat while `pending` is true. A ready response includes `view_id`, algorithm
and aggregate versions, `denominator`, coverage `buckets`, terminal reasons,
worker metrics and nodes. Each non-root node has `example_sample`; inspect that
ordinal with `get_profile_stack` to check the underlying evidence. Pages use the
returned `view_id`, original filters and `start`/`limit` (at most 64 nodes).
Stale/missing page identity is rejected. `retry:true` explicitly retries a failed
build. `get_profile_frame` accepts recorded view IDs only; derived frame evidence
comes from `get_profile_stack`. Omitting `basis` retains recorded semantics.
`get_profile.displayed_view.basis` identifies the GUI's current graph when present.

## Machine inspection

Get `capture_id` and `revision` from `get_profile`. Stop collection for stable
pagination and reconstruction. `get_profile_samples` returns durable zero-based
ordinals plus state availability; original kernel callchains remain unchanged.

```json
{"name":"get_profile_stack","arguments":{"capture_id":1,"revision":10,"sample":0}}
```

The response includes:

- `state`: disabled/missing/captured/budget, ABI, register presence, kernel record
  size, valid bytes, retained bytes and short-stack flag.
- `raw`: x86 perf register indices and hexadecimal values, sampled SP, up to 256
  bytes as hexadecimal by default. `stack_offset`/`stack_limit` page at most 1024
  bytes. `reconstruct:false` permits raw inspection during collection.
- `job`/`pending`: completed-capture analysis is queued on the worker. Repeat the
  same request until pending is false. Other archive/analysis jobs may return
  ArchiveBusy. `get_archive_status` reports progress; existing control-scope
  `cancel_archive_job` cancels cooperatively. Inspection needs observe scope.
- `derived`: algorithm and analysis identity, frames with raw PC/SP, lookup PC,
  mapping/module IDs and CFI method, plus a terminal reason and mapping coverage.
  Job errors are explicit and the same failed request is not automatically retried.

`get_profile_stack_coverage` accepts the same capture/revision, optional TID and
half-open `from_ns`/`to_ns` relative-time filter. It reports totals and paged TID
counts for registers, retained stacks, budget gaps, kernel-absent stacks, missing
state and disabled capture. Unfilterable records are counted separately.

The x86-64 walker is bounded to 32 frames. Its DWARF path reads only the saved stack
window through the existing debug-info adapter, using a private libdw handle on
the worker. No target memory, current stack, source file or executable code is
fetched to fill gaps. The leaf uses its exact sampled PC; callers use PC-1 for
mapping and CFI lookup. Recorded mappings are replayed at the sample timestamp.
Ambiguous mappings and metadata-loss cutoffs terminate explicitly.

Algorithm v3 also handles retained PE Windows x64 metadata. It uses the actual
control PC for function and epilogue decoding, while names use PC-1 for callers.
Both must have matching executable PE placement. PE metadata and instruction
bytes come from an immutable file snapshot; stack reads stay within the saved
window. Supported records and opening-time verification are described in
[PE stacks and recorded profiles](PE.md). Unsupported Windows records produce
`unsupported_windows_unwind` with a specific detail.

Terminal reasons include missing registers/assets/CFI, unsupported ABI or CFI,
signal frames, inaccessible saved bytes, a cycle, depth limit and retention gaps.
In sampled-unwind algorithms v2/v3, `complete` means unwinding reached a zero return PC
or an explicitly undefined return-address rule. Unavailable terminal registers
remain a separate reason. A partial result is not proof that further callers did not
exist. libdw's internal allocations/call duration are not governed by Zig's
64 MiB worker budget; cancellation is checked between frames and hash chunks.

Analysis IDs hash the algorithm, sampled inputs, consulted mappings/ELF or PE contents
and result. Archive replies additionally identify the artifact SHA-256. Reopening
with identical verified assets reproduces the result independently of session IDs.

## Archives

Format 2.2 uses required feature bit 2 and a USTA section for raw sampled evidence.
Registers and retained bytes, including budget gaps, survive reopening without
assets and byte-identical copying. Reconstruct offline only after explicitly
loading matching ELF/PE assets (`--resolve-capture-symbols` or `--symbols ROOT`).
Absent assets remain explicit. Derived results are not written into the archive.
Old 2.0/2.1 archives remain readable; earlier readers reject the required extension.
See [format](M2_ARCHIVE_FORMAT.md) and [archive workflow](M2_ARCHIVES.md).

## Validation and limits

- T16 adds aggregate/per-sample parity, filters, cited paths, cancellation after
  completion, worker ownership, memory growth and inspector-selection checks.
  Private 640×480/wide GUI runs cover presets, basis switching, pending states,
  sample navigation and scrolling. [Evidence](M2_DERIVED_VIEW_PROPOSAL.md#validation).
- Unit coverage: drain ownership, retention exhaustion/allocation failure, decoder
  bounds/fairness, exact return-PC mapping boundary, historical remapping,
  missing/short state, unsupported ABI, missing CFI, signal frame, cycle,
  cancellation, raw archive round trip and checksum-valid malformed fields.
- `python3 -B tests/m2-sampled.py`: owned GCC/Clang recursion with and without frame
  pointers, 64-byte stacks, zero/32 KiB exhaustion budgets, coverage partitioning,
  save/copy/reopen with and without verified assets. Four full-stack cases each
  recovered 18 frames, including the recursive chain; terminal unavailable
  registers stayed explicit. Offline syscall traces showed no target/perf or
  durability calls. These fixtures do not establish large-game/server overhead.
- A maximum fixture combines 16,384 samples, long mapping paths, other evidence
  limits and 64 MiB retained stacks: 102,132,158 encoded bytes, 232,302,100 peak
  decoded Zig allocation bytes, within the independent 128 MiB/256 MiB bounds.
- Production T14 GUI check: `python3 -B tests/m2-capture-setup.py`, private Sway,
  selected TIDs, preserved stack preferences, active/next settings and narrow UI.

The 32 MiB default remains provisional. T15 evaluates storage/scaling; ARM64
sample capture is [T18](tasks/T18-aarch64-sampled-state.md). No automatic stack
resizing, reconstructed flame default, JIT unwinding, signal trampoline unwinding
or cross-architecture archive support is implied.
