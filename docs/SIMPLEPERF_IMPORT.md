# Import simpleperf profiles

Convert on the workstation with an installed Android NDK, then open the printed
path. The converter and viewer perform no device operations.

```sh
scripts/import-simpleperf PATH/perf.data --ndk PATH/TO/NDK
zig-out/bin/xodb --open-profile PATH/TO/profile.xsp.json
```

Each conversion creates a fresh directory with `profile.xsp.json` and an exact
local copy of `source.perf.data`. Existing files are never overwritten. The
JSON is self-contained for viewing; retain the original recording for future
symbol resolution or conversion improvements.  The GUI needs only xodb, not the
NDK, the phone or the captured executables.

See [Android recording](ANDROID_PROFILING.md) for collecting a debuggable app
without root, and [verification](research/simpleperf-import.md) for the debug run.

## GUI

| Action | Control |
| --- | --- |
| Select a flame and its contributing sample | Click a flame bar |
| Zoom into the selected flame / go to its parent | Z / Backspace |
| Scroll flame depth | Mouse wheel, J/K or Down/Up |
| Filter by time | Drag across the overview or a thread lane |
| Select one thread / clear that single selection | Click the thread label or lane |
| Add/remove a thread from the selection | Ctrl-click its label or lane |
| Zoom the timeline around the pointer | Wheel over the overview |
| Scroll thread lanes | Wheel over the lanes |
| Clear time/thread filters | X or Reset filters |
| Inspect a contributing sample | I |
| Previous/next sample in the current filter | [ / ] |
| Scroll the sample's stack | Up/Down or wheel over the inspector |
| Close inspector / cancel pending work | Esc |
| Retry a failed filtered build | R |
| Quit | Q |

Ctrl-click combines selected threads in one flame graph and sample filter. Removing
the last selected thread returns to all threads; plain click selects one thread.
Thread changes preserve the selected time range.

The inspector sits beside flames in a wide window and replaces them in a small
window. I switches back. It displays original sample addresses and the reader's
root-to-leaf frames, names, modules and resolution flags. The bottom timeline
shows sample density, with no inferred running/waiting states.

**Flame widths use sample periods.** For `task-clock:u` and `cpu-clock:u`, weights
are CPU nanoseconds summed across sampled threads. They can exceed the capture's
wall duration. `cpu-cycles:u` uses cycles. Counts are shown separately. Time filters
are half-open offsets from the earliest retained sample, not phone wall time.
The timeline extent is the sample span plus one nanosecond, not the requested
recording duration.

Gray frames have unresolved names. All names are simpleperf-supplied labels;
xodb does not independently load or verify matching debug information here.
Per-sample unwind completeness is unavailable from this reader and stays marked
unknown. Available recorder loss counters are retained; missing counters are
unknown. Buffer-pressure stack truncation counts do not describe every short
or incomplete unwind. Thread grouping uses numeric TIDs and the first observed
name; task birth identity and TID reuse are not reconstructed.

## MCP

```sh
zig-out/bin/xodb --headless --mcp --open-profile PATH/TO/profile.xsp.json
```

Omit `--headless` to share the imported GUI with one MCP client. Use the usual
newline-delimited JSON-RPC initialization; [MCP overview](MCP_OVERVIEW.md).
This session advertises only these read-only tools:

- `get_session`: offline session with PID zero and the imported architecture
  once loading finishes.
- `get_imported_profile`: poll `status` (`pending`, `ready`, `failed`), inspect
  provenance, reported loss, totals and GUI selection; page sampled threads
  with `start` and `limit` (maximum 32).
- `get_imported_flamegraph`: supply `import_id` from profile status and optional
  `tid` or `tids`, `from_ns`, `to_ns`; poll the same request until ready. Page nodes with
  `start`, `limit` (maximum 32) and the returned `view_id`, preserving filters.
  `retry:true` retries a failed filtered build. Each node cites an example sample.
- `get_imported_sample`: supply `import_id` and zero-based `ordinal`; page stack
  sites with `start`, `limit` (maximum 16). Includes raw IP, module-relative
  address, mapping extent/offset, symbol extent and reported build ID.

Use `tids:[30619,30691]` for a union of threads, intersected with the time range.
Supply either `tid` or `tids`, never both. Arrays accept up to 1,024 distinct known
TIDs; order does not affect `view_id`. An empty array means all threads; a
single-element array has the same identity as `tid`. Unknown or duplicate IDs
are rejected. GUI status exposes `tid` for a single selection, `tids` for a
multiple selection, and null for both when all threads are included.

Time arguments and 64-bit times, addresses, weights and reported loss counters
use strings. Counts, indices and bounded PID/TID values use JSON numbers.
`import_id` hashes the converted bytes; `source_sha256` hashes the original perf
bytes. `view_id` identifies the import, analysis version and exact filter.
The GUI's `view_id` is null while it has no completed view for its current filter.
GUI and MCP have independent filtered worker slots. A different filter may
initially return pending while that slot finishes its current job. Pages remain
reproducible for the same immutable input and filter.

Names and paths longer than 512 UTF-8 bytes are explicitly shortened in paged
MCP rows; full strings remain in the JSON file. Unsupported native debugger or
archive tools fail in an imported session. Reopening the original JSON is the
persistence workflow; this format is separate from native `.xcap` archives.

## Scope and bounds

Version 1 accepts one sampled process and one user-space CPU event:
`task-clock:u`, `cpu-clock:u` or `cpu-cycles:u`. Supported architecture labels are
`aarch64`, `arm`, `x86_64`, `x86`. Off-CPU/system-wide recordings, multiple sampled
PIDs, mixed events, empty recordings and invalid/over-limit data are rejected.

- Converter input: regular file, at most 256 MiB. The installed NDK report
  library decodes it in the separate converter process.
- Converted JSON: at most 64 MiB; 65,536 samples and frame definitions; 4,096
  modules; 1,024 sampled threads; 256 sites per stack; 1,048,576 total sites.
- Decoded Zig allocation budget: 256 MiB. Each graph has a 64 MiB allocation
  budget and 65,536-node ceiling. Excluded samples and their period weights are
  reported explicitly; the graph never accepts part of a rejected sample.
- One retained full view plus one cached view per GUI/MCP slot; each slot can
  also have one replacement in progress. Budgets are per allocation owner, not
  a process RSS ceiling. NDK internal allocations are outside these budgets.
- Loading and filtered builds run on workers. Cancellation is cooperative;
  a bounded JSON parse or a graph operation can finish before cancellation is
  observed. Failed loads are retried by reopening the file.

There is no source navigation, live debugging, new symbol resolution, raw stack
memory or register reconstruction in this imported view. APK/ART names describe
sampled execution and do not provide Kotlin variable inspection.
