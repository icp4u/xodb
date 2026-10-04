# Memory and floating-point/vector inspection

## Local GUI

- **M** opens memory at the selected local's address, or the selected thread's stack pointer.
- **G** enters an address or native expression such as `&counter` or `buffer`.
- Arrows, wheel and Page Up/Down move through memory; byte and ASCII views agree.
- **P** pins the displayed snapshot. Orange bytes changed or became unreadable;
  blue bytes became readable. **U** clears the baseline. `??` means unreadable.
- **/** searches from the displayed address: `hex:414241` or `text:ABA`.
  **L** changes range length, **N** visits matches, **C** cancels.
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

- `capture_memory(address, length, generation)` retains an immutable snapshot.
- `read_memory_snapshot(id, baseline?, start?, limit?)` pages bytes, validity and
  per-byte comparison. Hex uses memory byte order and `??` for unreadable bytes.
- `search_memory(address, length, pattern, encoding?, generation)` starts a job;
  `get_memory_search(id, start?, limit?)` reports coverage and pages hit addresses.
- `cancel_memory_search(id)` cancels analysis without resuming the target.
- `get_extended_registers(tid, generation?, width?, format?)` returns vectors,
  x87 values/tags/control/status, MXCSR and available AVX-512 mask registers.
  Floating-point lanes are strings, including non-finite values. Raw bytes are
  also returned, so no floating-point formatting precision is imposed on callers.

Address arguments are strings such as `"0x1234"`. All are read-only operations
available to observe-scope agents. They work on the live MCP server, including
remote servers; the separate remote GUI does not yet expose these panels.

## Bounds and limitations

- Eight snapshots of at most 64 KiB; the GUI retains 1 KiB and may pin one baseline.
  Unpinned snapshots expire as newer snapshots replace them. Expired IDs error.
- One search, at most 64 MiB, 256 pattern bytes, 1,024 matches. Results explicitly
  distinguish complete, cancelled, stale and match-limit termination.
- Searches run in 64 KiB slices. Unreadable bytes count toward coverage and break
  pattern matching; patterns may overlap or span readable page boundaries.
- Resume, register/stop generation changes or image replacement make an active
  search stale. Snapshots remain immutable and carry their original identity.
- Snapshot comparisons across process images are explicitly outside the baseline.
- Shared mappings can change through another process even while all target threads
  are stopped. A memory snapshot is an observation, not an atomic system snapshot.
- x87/SSE and OS-enabled AVX/AVX-512 are read through Linux register sets. Unsupported
  widths error. AMX, ARM vector state, register editing and memory editing are absent.
