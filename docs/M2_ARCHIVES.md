# Native capture archives

The first save/reopen workflow is integrated for local x86-64 captures. The
experimental format supports **2.4** (nondefault sample ceilings; default captures
still write 2.3), described in [M2_ARCHIVE_FORMAT.md](M2_ARCHIVE_FORMAT.md).
It implements the [approved archive contract](M2_ARCHIVE_PROPOSAL.md). T11's
prototype files remain unchanged; prototype version 1 files are rejected.
Version 2.0 archives remain readable. Captures with a zero deadline or a deadline
over 60 seconds declare a required feature; old readers reject that feature.

## Try it

~~~sh
./zig-out/bin/xodb --capture-out run.xcap --attach PID
~~~

Use **P** to start sampling and **Space** to resume if the target is stopped.
Use **P** again to stop sampling; **Shift+Q** closes xodb and saves the latest capture.
An active capture is stopped and drained before saving. Choose a new filename.
A requested save without a capture, or a failed save, produces a nonzero exit.

~~~sh
./zig-out/bin/xodb --open-capture run.xcap
~~~

The offline workspace opens with flames above the timeline. Drag a range or
select a thread to filter it; zoom and inspect recorded function/source
locations. It works after the target exits and the old build directory is gone.
It contains no live target; recorded PIDs cannot authorize process operations.
Source text is not bundled and the GUI does not open today's file as historical
source. No symbols are loaded from external paths by default.

**Escape** requests cancellation while archive work is active. The status line
shows the current phase and completion/error; MCP provides the same status.
Cancellation is cooperative between work units. A filesystem or libdw call
already executing can delay completion. Closing the window cancels an unfinished
open/view unless a shutdown save was requested; an accepted save is allowed to
finish. There is one archive worker per session.

To make an unchanged copy, preserving all original evidence and extensions:

~~~sh
./zig-out/bin/xodb --headless --mcp --open-capture run.xcap --capture-out copy.xcap < /dev/null
~~~

All saves use complete writes, mode 0600 and no-overwrite publication. Existing
files and symlinks are never replaced. There is **no fsync, fdatasync, directory
sync or durability option**. Stderr reports publication errors and temporary
cleanup failures separately. A published file stays published even if removing
its temporary name fails; crash leftovers are not automatically deleted.

## Evidence and analysis

The artifact retains opening and enrolled threads, effective scope, enrollment times, normalized raw samples/kernel callchains,
mapping history, scheduling transitions, application intervals and provenance,
debugger markers, settings, loss/stop information and the complete image manifest.
The original boot/clock, capture/session/PID/generation/epoch/revision are separate
from the writer's boot/time and the new session's local IDs.

A deterministic finalization pass records bounded function names/ranges and
available source paths/lines. These are derived annotations, identified as
produced during archive finalization. They do not claim to have observed source
contents or code bytes at every sample instant. Missing annotations have an
explicit unavailable/limit label; unresolved addresses remain evidence.

Each offline analysis view identifies the artifact SHA-256, exact filter,
analysis version, asset-resolution context and the actual annotation output of
explicit reanalysis. Node numbers belong
only to that view. Durable citations use artifact hash plus raw sample ordinal,
mapping/module identity and address, retaining the filter and view identity.
Hashes and checksums provide identity/integrity, not authenticity.

Re-saving an offline session copies the original bytes. It preserves unknown
optional sections and the original annotation context even after richer analysis.
It does not bake a selected filter or newly derived labels into a new artifact.

## Optional matching assets

For assembly inspection, put exact ELF files in a directory named by each file's
lowercase SHA-256 digest, then:

~~~sh
./zig-out/bin/xodb --open-capture run.xcap --symbols /path/to/assets
~~~

The required digests and sizes are available from MCP get_archive_status.
Identity lookup distinguishes different binaries with the same basename.
Verified bytes are copied into owned read-only memory before use. Changing or
truncating the external file afterward cannot alter those analysis bytes.
Missing, mismatched, nonregular and over-budget assets have explicit statuses;
the manifest and recorded labels survive all of these outcomes.

--symbols enriches assembly while retaining recorded labels. To explicitly
derive a different label context:

~~~sh
./zig-out/bin/xodb --open-capture run.xcap --symbols /path/to/assets --resolve-capture-symbols
~~~

Without --symbols, that explicit reanalysis option tries recorded paths and
still requires content identity. Reanalysis can lose names when matching assets
are absent; the original artifact remains intact. Its view identity differs
from the recorded view. No automatic network retrieval, source packaging,
separate debug-file discovery or asset bundling is implemented.

## MCP

Run with --headless --mcp for an offline machine interface. Observation remains
the default agent scope; writing/cancelling requires --agent-scope control.

| Tool | Contract |
| --- | --- |
| save_capture_archive | Requires current generation, capture_id, revision and a new path; completed capture only; returns a job ID |
| get_archive_status | Reports phase/progress, done/error, publication, origin/manifest, artifact hash, analysis basis and resource limits |
| cancel_archive_job | Requires current generation and job_id; requests cooperative cancellation |
| get_profile_samples | Paged normalized raw evidence with durable ordinals; up to 16 samples per call |
| get_flamegraph | Returns view_id; offline pages after the first require it |
| get_profile_frame | Offline node lookup requires the view_id and matching filter |
| Existing timeline/mapping/scheduling/interval queries | Read the retained evidence; local capture/revision guards still apply |

A new offline filter may return ArchiveViewPending. Poll archive status, then
retry the same query. The worker caches one prepared filter; GUI/MCP reuse the
same graph semantics. An unchanged filter that failed/cancelled is not retried
on every UI frame; selecting another filter permits new work.

Accepting a save job does not mean a file exists. Check job.done,
job.error_name, then job.publication.state (published or not_published),
error_name and cleanup_error. A live completed capture is pinned against
replacement/interval mutation during saving. Target controls are rejected in
offline sessions, irrespective of agent scope.

## Budgets and remaining limits

| Resource | Current limit |
| --- | --- |
| Core archive input/output | 256 MiB |
| Encoder temporary / retained decoded Zig allocations | 512 MiB each |
| New offline filtered graph working allocations | 64 MiB |
| Live recorded snapshot/graph worker | 96 MiB |
| Owned ELF snapshot | 256 MiB per image; 512 MiB total |
| Mapping path strings | 16 MiB aggregate; 4096 bytes per path |
| Annotations / graph nodes | 8192 each |
| Raw evidence | Configured 1–65,536 samples (default 16,384; 32 MiB sample-store budget), 1024 threads, 256 images and mapping/scheduling/interval caps |

These are separate budgets, not a whole-process RSS limit. The archive input
buffer, copied output, UI/query results, live capture and C libdw allocations add
memory outside the retained decoder counter. libdw's own allocations are not
governed by the Zig budget. A hostile ELF is not isolated in a helper process.

Archive read/hash/decode/annotations and offline graph rebuilds run on the worker.
Live capture ELF snapshot acquisition is still synchronous during capture opening
or observed mapping changes; a large image can add latency, and files over the
limits remain unresolved. This does not establish large-game/server overhead.
The debugger's ordinary live-module loading is unchanged.

Snapshot acquisition verifies file size/mtime/ctime before and after reading.
The bytes describe the mapped file observed when acquired; they cannot prove
equality to self-modified/JIT/runtime-patched code or defeat adversarial metadata
changes. Existing unobserved munmap/mremap and frame-pointer callchain limits
remain. T10 optionally records raw registers/stacks with an explicit required
archive extension; derived callers stay separate worker results. See
[sampled-state inspection](M2_SAMPLED_UNWIND.md) and
[USTA encoding](M2_ARCHIVE_FORMAT.md#sampled-user-state-usta-schema-1).

## Validation

~~~sh
./scripts/build test -Doptimize=ReleaseSafe --summary all
python3 -B tests/m2-archive.py
python3 -B tests/m2-archive-gui.py PATH_TO_CAPTURE [PATH_TO_BUDGET_CAPTURE]
~~~

Live checks use owned fixtures; GUI checks use a private headless Sway session.
Measured results, failures found during development and remaining work are in
[journal.md](journal.md).
