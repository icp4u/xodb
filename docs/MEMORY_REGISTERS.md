# Memory and floating-point/vector inspection

## Local GUI

- **M** opens memory at the selected local's address, or the selected thread's stack pointer.
- **G** enters an address or native expression such as `&counter` or `buffer`.
- Arrows, wheel and Page Up/Down move through memory; byte and ASCII views agree.
- **P** pins the displayed snapshot. Orange bytes changed or became unreadable;
  blue bytes became readable. **U** clears the baseline. `??` means unreadable.
- **/** searches from the displayed address: `hex:414241` or `text:ABA`.
  **L** changes range length, **N** visits matches, **C** cancels.
  **W** toggles searching every writable private mapping at this stop instead
  (the `writable` selector below); the footer shows `scan all writable`.
- **R** opens floating-point/SIMD registers for the selected thread.
  **V** cycles float32, float64, int32, uint32, uint64 and hex lane formats;
  **W** cycles available 128/256/512-bit widths. Scroll to x87 and mask registers.
  Lanes run from least significant to most significant; orange values differ
  from the preceding observed stop of this thread and process image.
- Escape closes either panel. Space/F5 and function-key stepping still work.
  A running target leaves a clearly labelled historical display.

The vector panel describes physical registers at the current stop, regardless
of the selected stack frame. It does not reconstruct caller-saved SIMD state.

## MCP

- `capture_memory(address, length, generation)` retains an immutable snapshot;
  `capture_memory(ranges=[{address, length}, ...], generation)` captures up to
  16 ranges during the same stop and returns one snapshot per range. Capture once,
  resume, then page the snapshots at leisure.
- `read_memory_snapshot(id, baseline?, start?, limit?)` pages bytes, validity and
  per-byte comparison. Hex uses memory byte order and `??` for unreadable bytes.
- `search_memory(address, length, pattern, encoding?, generation)` starts a job;
  `get_memory_search(id, start?, limit?)` reports coverage and pages hit addresses.
- `search_memory(ranges=[{address, length}, ...], pattern, ...)` searches up to
  1,024 ascending, non-overlapping ranges as one job with one hit list.
  `search_memory(regions="writable", pattern, ...)` builds the ranges from the
  process map at this stop, so a client need not fetch maps first; add
  `address`/`length` to clip the selected mappings to a window. Selectors:

  | `regions` | Includes |
  | --- | --- |
  | `writable` | readable and writable private mappings (`rw-p`): heap, stacks, anonymous memory and file-backed private data such as `.data`/`.bss` |
  | `anon-writable` | the same, only mappings without a file path: no name or a bracketed name such as `[heap]`, `[stack]`, `[anon:…]` |
  | `all-readable` | every readable private mapping (`r--p`, `r-xp`, `rw-p`, …), including code and read-only file mappings |

  Shared mappings (`rw-s`, `r--s`) are added only with `include_shared: true`:
  another process can change them, and device mappings can be slow or refuse
  reads. Selected mappings that touch merge into one range.
  `get_memory_search` adds `range_count`, `ranges_done`,
  `ranges_with_unreadable`, `ranges_unreadable` and a page of per-range rows
  (`address`, `length`, `scanned`, `unreadable`, `hits`) selected with
  `range_start`/`range_limit` (default 16, at most 256; `range_next` continues).

  ```json
  {"generation":42,"regions":"writable","pattern":"Player One","encoding":"utf8"}
  ```
- `cancel_memory_search(id)` cancels analysis without resuming the target.
- `get_extended_registers(tid, generation?, width?, format?)` returns vectors,
  x87 values/tags/control/status, MXCSR and available AVX-512 mask registers.
  Floating-point lanes are strings, including non-finite values. Raw bytes are
  also returned, so no floating-point formatting precision is imposed on callers.

Address arguments are strings such as `"0x1234"`. All are read-only operations
available to observe-scope agents. They work on the live MCP server, including
remote servers; the separate remote GUI does not yet expose these panels.

## Bounds and limitations

- Snapshots of at most 16 MiB; one multi-range call takes at most 16 ranges and
  32 MiB. At most 64 snapshots and 64 MiB of captured bytes are retained (about
  twice that resident, for per-byte validity); the oldest replaceable snapshots
  expire first and expired IDs error. Clients cannot evict another client's
  snapshots or the GUI's pinned baseline: such a capture fails with `JobNotOwned`,
  and a multi-range call that would have to evict its own ranges fails with
  `MemoryBudgetExceeded`. The GUI retains 1 KiB and may pin one baseline.
- One search, at most 256 pattern bytes and 4,096 matches. A single range is at
  most 1 GiB; a multi-range or region search at most 4 GiB in total and 1,024
  explicit ranges (one MCP request line is 64 KiB) or 4,096 merged region ranges.
  The larger total stays bounded: it uses the same fixed 1 MiB buffer, the same
  per-turn time budget and cancellation, and gaps between ranges cost no reads,
  so it only keeps the stopped target stopped for a few seconds. A selector that
  exceeds a limit fails with `MemorySearchTooLarge` or `MemorySearchTooManyRanges`
  (clip it with `address`/`length`); one that selects nothing fails with
  `NoMatchingRegions`. A hit never spans two ranges: partial matches reset at
  each range boundary, as at an unreadable page. Results explicitly distinguish
  complete, cancelled, stale and match-limit termination.
- Searches read 1 MiB at a time (64 KiB per request to a remote agent) and scan
  for at most about 4 ms per owner-loop turn, so the debugger stays responsive.
  A local search scans several GB/s; a remote agent a few hundred MB/s. After a
  short or failed read the search falls back to 4 KiB pages until a whole page
  reads again, so unreadable bytes are counted exactly. Each unmapped page costs
  one read: about 1 µs locally but one round trip remotely, so keep remote search
  ranges on mapped memory. Unreadable bytes count toward coverage and break
  pattern matching; patterns may overlap or span readable page and read boundaries.
- Resume, register/stop generation changes or image replacement make an active
  search stale. Snapshots remain immutable and carry their original identity.
- Snapshot comparisons across process images are explicitly outside the baseline.
- Shared mappings can change through another process even while all target threads
  are stopped. A memory snapshot is an observation, not an atomic system snapshot.
- x87/SSE and OS-enabled AVX/AVX-512 are read through Linux register sets. Unsupported
  widths error. AMX, ARM vector state, register editing and memory editing are absent.
