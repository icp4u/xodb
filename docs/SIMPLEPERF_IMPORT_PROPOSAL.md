# Simpleperf import: first offline view

Status: approved by the user and implemented, 2026-10-02.
[Usage](SIMPLEPERF_IMPORT.md) · [verification](research/simpleperf-import.md).

## Short critical review

Using the installed NDK's reader gets us Android/ART and APK-contained-library
decoding immediately, in a separate conversion process. A small versioned JSON
file gives xodb a bounded, architecture-independent input and preserves individual
samples for time/thread filtering and inspection. The costs are an extra command,
larger intermediate files and dependence on the NDK reader's symbol/unwind output.
The existing app capture converts to 3,121 samples and 579 distinct frame
records. GUI and read-only MCP integration are now verified against those samples.

The main correctness risks are misleading weights and confidence: sample periods
are CPU-event weights, timestamps are capture-local, and named frames are labels
reported by simpleperf rather than independently verified DWARF results. The
import must preserve that provenance and show unavailable unwind completeness,
unknown symbols and reported loss. It must also keep loading and graph builds
off the event loop. Missing symbols will stay offsets in this first version.

## Adopted workflow

```sh
python3 scripts/import-simpleperf PATH/perf.data --ndk PATH/TO/NDK
zig-out/bin/xodb --open-profile PATH/TO/profile.xsp.json
```

The converter creates a fresh directory under `.work/`, including a private
copy of the original `perf.data` and its SHA-256 identity. No device operations
or external ELF loading are added to xodb's view. Native `.xcap` archives retain
their current format and semantics.

The GUI is a read-only imported-profile view with flames above the existing
timeline, click selection, Z/Backspace zoom, timeline range/thread selection,
and recorded sample inspection. Widths use recorded sample periods; sample
counts remain separately visible. No source stepping, register reconstruction,
live controls, scheduling states or new symbol resolution are implied.

Headless MCP exposes imported-profile status/metadata, bounded flame-node
pages and sample/stack evidence with an explicit import/view identity. These
queries are read-only and use separate names from native capture analysis.
GUI and MCP filtered builds get separate bounded worker slots so one caller's
filter does not continually displace the other's view.

## Version 1 input contract

- JSON `format: "xodb.simpleperf"`, `version: 1`.
- Architecture, one event and its unit, clock name, original recording digest,
  record command, simpleperf metadata, and explicit label/unwind provenance.
- Module dictionary: full captured path, reported build ID when available.
- Frame dictionary: name, reported resolution flag, module reference, symbol
  extent and mapping start/end/file offset. These fields describe the reader's
  output; a build ID by itself does not verify a local executable.
- Samples: PID, TID, thread name, absolute timestamp, period, CPU and root-to-leaf
  sites, each retaining raw IP and module-relative address. The separately
  returned sampled leaf is included.
- All 64-bit quantities use strings to preserve JSON integer precision.
  Time filtering uses offsets from the earliest retained sample, not device
  wall time. Original timestamps remain available.
- Initial supported scope: one sampled process, user-space `task-clock:u`,
  `cpu-clock:u` or `cpu-cycles:u`; one event per import. Reject off-CPU/system-wide
  recordings, mixed events, multiple sampled PIDs and empty recordings explicitly.
- No claim that a stack is complete: the NDK report API used here does not
  export per-sample unwind status. Preserve available aggregate recorder loss
  and stack-truncation metadata; absent counters mean unknown, not zero.
- Reject malformed/unsupported input rather than silently converting a subset.

Initial bounds: 64 MiB JSON input, 65,536 samples, 65,536 frame definitions,
4,096 modules, 1,024 sampled threads, 256 frames per stack and 1,048,576 total
stack sites. The decoded Zig allocation budget is 256 MiB. Graph builds have
a separate bounded allocation budget and node ceiling; any excluded samples
must retain explicit counts and weights. These are allocation bounds, not RSS
guarantees. The converter has count/file bounds but uses the NDK's native library,
whose internal allocations are not controlled by xodb's Zig budget.

## Verification

The real app import preserves 3,121 samples and 31,525,252,210 ns of period
weight. Headless checks passed range/thread partitions, raw-site preservation,
node citations and stable MCP paging. Native tests passed malformed input,
integer/weight overflow, node limits, cancellation and cleanup. Wide/small
private-Sway checks passed timeline selection, zoom and sample inspection.
The full native suite passed 209 tests with four architecture-specific skips.
[Evidence and screenshots](research/simpleperf-import.md).

An external LLM can cite an imported sample/frame and explain the visible hot
paths. It should receive the explicit reader provenance and coverage gaps along
with those citations, and must not infer function names from unresolved offsets.
