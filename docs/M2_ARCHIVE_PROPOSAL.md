# M2 native capture reopening

Status: **revised direction adopted by the user, 2026-10-01**. The user approved
adopting the [adversarial review](M2_ARCHIVE_REVIEW.md). This replaces the initial
proposal; integration is authorized subject to the validation gates below.
Subsequent user decision: use a dedicated archive I/O worker and omit durability
syncs for saved files; section 6 supersedes the review's fsync recommendation.
Claude's [T11 prototype and evidence](research/capture-archive.md) remain useful
inputs, with the reproduced defects recorded in the review. This document is an
implementation contract. The first implementation and remaining limits are now
documented in [M2_ARCHIVES.md](M2_ARCHIVES.md).

## 1. Separate evidence, analysis and target control

| Concept | Owns | Identity and authority |
| --- | --- | --- |
| Immutable artifact | Capture origin/clock, normalized evidence, complete asset manifest, recorded annotations, feature declarations and preserved extensions | Content identity; recorded PIDs/session IDs are provenance |
| Derived view | Filter, analysis version/options, symbol-resolution context, flames/timeline and temporary node handles | Identifies the artifact and the exact analysis context |
| Live target | Current process/thread handles, stop generation and control capabilities | Authorizes debugger actions only in its current session |

An offline artifact must never acquire control authority from a recorded PID or
from sentinel values in a runtime `Capture`. Shared analysis functions remain
valuable, but serialization must not depend on runtime pointers, symbol caches,
currently loaded assets or synthetic offline IDs.

## 2. Preserve origin and allow lossless second saves

The artifact preserves:

- Original capture/session/PID/generation/image epoch and capture revision.
- Clock kind, capture boot identity when known, original timestamps and their
  interpretation. Record absence explicitly; do not infer an absent boot ID from
  the machine opening or saving an archive.
- Opening thread identities, raw CPU samples, mapping history, scheduling
  transitions, imported intervals and their provenance, debugger markers,
  collection settings, loss and all recorded stop conditions.
- The complete image manifest, including entries whose assets are unavailable.

Capture origin and writer metadata are separate fields. Writer host/boot/time
must never relabel old timestamps. Establish the capture boot identity when the
capture is created; legacy/unknown origin stays unknown. Analysis or annotation
provenance is also separate from the original collector evidence.

An unchanged reopened artifact can be copied byte-for-byte to a new destination,
retaining its content identity and unknown optional sections. A reconstruction
must preserve all supported evidence and manifests; if it cannot preserve an
extension, refuse the lossy rewrite. A saved filter is a view selection, not
permission to silently discard unselected evidence.

## 3. Preserve useful recorded analysis without requiring old build files

Include bounded recorded symbol annotations by default: mapping/module identity,
lookup address, resolved function address/range and name when available, available
source path/line, and resolver/version/limitations. Preserve unresolved outcomes
and annotation-limit reasons too. These are derived records, never replacements
for raw samples or proof of target state.

Record when annotations were produced and the asset identity used. “Recorded”
means retained in this artifact; annotations produced at archive finalization
must not be labelled as observations made at the instant of each sample. Define
a deterministic, bounded annotation pass over the completed evidence rather than
serializing whichever entries happen to be in a mutable UI cache.

The default offline view uses the recorded annotation context. Removing the old
build directory must not erase its saved names or function grouping. If available
metadata or budget cannot provide a label, expose that fact consistently.

Optional matching ELF/debug assets permit richer analysis and assembly inspection.
Optional source bytes need their own hashes and provenance; a DWARF path does not
certify current source contents as historical. Permit explicit asset/source
bundles without requiring them for the first useful offline workflow. Compression
and full source-tree packaging remain deferred.

Prefer external asset lookup by content identity. Recorded paths and basenames
are hints; support distinguishing two different binaries with the same basename.
No automatic network retrieval is part of this integration.

## 4. Verify owned bytes and keep the UI responsive

Hash and parse the same owned immutable bytes. A read-only file-backed mmap is
insufficient: the review reproduced both changing verified bytes and a truncation
crash. Apply this lifetime rule to assets retained for captures as well as assets
loaded when reopening. Copying/sealing can be used; do not promise an immutable
capture-time image when only an external path first read during saving is known.

Open paths without waiting on FIFOs, reject nonregular candidates, and perform
bounded reads. Detect failures/changes while acquiring a snapshot; preserve an
explicit unavailable/mismatch result instead of proceeding with guessed identity.
After verification, subsequent external writes/truncation must not change the
bytes used by analysis or crash the reader.

Use independent limits for:

- Encoded archive input: retain the initial **64 MiB** cap for the core artifact.
- Decoded allocations and total strings, alongside existing evidence-count caps.
- Individual and aggregate external asset bytes retained and hashed.
- Annotation/derived-view work and output, including stack reconstruction later.

Asset/bundle limits are separate from the core input limit. Establish and report
measured default memory/work budgets in the integration results; do not derive
heap or latency guarantees from file size. Existing numerical evidence limits
remain until measurements justify changing them. Limit exhaustion must say which
evidence or analysis is unavailable; it cannot silently change the investigation.

A dedicated archive I/O worker owns archive reading, hashing, decoding and
substantial derivation. The UI receives phase/progress and completed results;
transfer ownership only when the result is ready. Check cancellation between
bounded work units.
`O_NONBLOCK` addresses FIFO opening, not regular-file I/O latency. Cancellation
must not require immediate interruption of an already-blocked filesystem call;
keep its worker state safely owned until it finishes. Do not share mutable capture
or libdw state unsafely between the UI and workers.

The former 14.7 MB “maximum” was a fixture result. A valid long-path fixture was
30,473,783 bytes. Neither value establishes worst-case decoded memory or latency.

## 5. Identify analysis views and durable evidence references

A derived-view identity includes:

- Artifact content identity.
- Exact thread/time filter and analysis options.
- Analysis implementation/schema version.
- Recorded or newly resolved symbol/asset context, including unresolved outcomes.

Node numbers are temporary handles within that view. MCP responses and follow-up
node queries must carry/validate view identity. Durable citations refer to sample
ordinals or other immutable record IDs, mapping/module identity and address or
ancestry, plus the filter and analysis context. Artifact hash plus capture revision
alone is insufficient.

Discovering binaries or requesting a new symbolization/unwind pass creates a new
view identity; it must not silently change an existing view. Clearly distinguish
recorded annotations from newly derived results. Shared GUI/MCP algorithms remain
the source of flame/timeline semantics.

## 6. Publish with an explicit outcome

Publish only new files with mode 0600, complete writes and no-overwrite
publication. Use normal kernel buffering: **no file or directory `fsync`,
`fdatasync`, or equivalent forced durability step**. The user explicitly does
not require persistence across power loss or an OS crash. Do not add a durability
mode or sync option in this integration.

Write the complete temporary file, handle write/close errors, then publish it
without replacing an existing destination. This preserves ordinary file
publication behavior without waiting for a durability flush. Return a structured
result:

| State | Meaning |
| --- | --- |
| `not_published` | This operation did not install the destination; include the failure reason |
| `published` | The complete file was installed at the destination; no durability confirmation is attempted |

Include destination and artifact identity where available. Report temporary-file
cleanup problems separately from publication success, so a leftover temporary
name does not invite a blind retry against an existing destination. Never delete
a published capture merely to simplify an error result. Report crash leftovers
and leave unrelated/existing files alone; no automatic stale-file cleanup.

Save-on-shutdown failures need a machine-visible result (normally nonzero exit
status), in addition to stderr diagnostics. Report a requested save with no
capture explicitly. Existing Speedscope export remains available.

## 7. Version and extend the evidence format deliberately

Retain explicit architecture, byte order, clock, code tables, lengths, checksums,
count validation and cross-reference checks. Checksums/content hashes establish
integrity and identity, not authenticity of imported evidence.

Declare required and optional features. Unknown required evidence is rejected
with an explicit unsupported-feature result. Unknown optional sections are
reported and preserved for copying; rebuilding an artifact that would discard
them is refused. Adding fields inside an old required section is not implicitly
minor-compatible.

Before freezing a published version, define the section boundary for imminent
T10 data: per-sample register ABI/mask/values, stack base/captured and valid byte
lengths/data, plus separately derived callers, unwind method/version, asset
context and partial-stack reasons. An archive lacking these records must say they
were not recorded. Never synthesize them from a currently running process.
Future thread lifetime/enrollment-gap evidence also needs an explicit extension.

T10's final handoff has arrived. Its report informs the boundary in
[M2_ARCHIVE_FORMAT.md](M2_ARCHIVE_FORMAT.md);
archive adoption does not approve an unfinished collector/unwinder. Do not make
a permanent compatibility promise for T11's prototype 1.0 bytes. Any unsupported
prototype input must fail clearly, without being interpreted as a newer format.

## 8. First user-facing integration

- `--capture-out NEWFILE` saves the completed artifact on shutdown.
- Control-scope MCP `save_capture_archive` validates current session generation,
  capture/revision or immutable artifact identity as appropriate. If saving is
  asynchronous, expose completion and publication state explicitly.
- `--open-capture FILE` opens a separate offline GUI or headless MCP session.
  Reject combining it with attach/launch. Open the GUI in the profile view.
- Read-only flame/timeline/interval inspection uses the shared semantics and
  identifies the artifact, recorded origin and derived view separately.
- Archived source locations may be displayed as recorded annotations. Opening
  current source text requires explicit provenance; it must not be presented as
  an automatically verified historical copy.
- Target execution, stepping, breakpoints, memory writes and live source actions
  cannot operate on the archived PID. Saving a new archive remains a filesystem
  action governed by agent scope, even in an otherwise read-only offline session.

Opening alongside a live target can follow later. The evidence/control separation
above makes that a UI/workflow extension rather than a serialization redesign.

## Implementation order and gates

1. **Artifact and codec foundation:** preserve origin, complete manifests and
   opaque optional sections; separate writer metadata; add annotations/features;
   prove genuine reopen/re-save/reopen behavior, including absent assets.
2. **Asset lifetime and file operations:** immutable snapshots, bounded reads,
   content-based lookup and structured publication results; turn mutation,
   truncation, FIFO, write/publication failures and cleanup outcomes into directed
   regression tests. Confirm the save path issues no durability sync calls.
3. **Shared analysis identity:** recorded annotation default, explicit reanalysis,
   view identity and durable MCP references; conserve samples under filters.
4. **Application integration:** worker ownership/progress/cancellation, CLI/MCP,
   separate offline session, safe source display and private-GUI navigation.
5. **End-to-end acceptance:** run the workflow below and record measured resource
   limits before marking native archive reopening integrated in M2.

Required acceptance workflow:

**real capture → save → target exits → original build directory removed → offline
inspection → second save → second reopen**.

Verify original origin/clock/manifest/evidence and recorded labels survive. Verify
filters conserve counts, reanalysis is explicit, unsupported evidence is reported,
missing assets remain inspectable, and archived IDs never permit target access.
Exercise save/reopen without ever viewing the live flame graph, so the archive
cannot accidentally depend on a warmed UI cache.

Also cover cold/slow and oversized assets, maximum path/string totals, malformed
archives, unknown optional/required features, worker cancellation, publication
phase failures, machine-visible shutdown errors and private-GUI responsiveness.
Record input/decoded/asset peaks and encode/decode/analysis timings separately.

T11's reported 32/32 runner checks, 96-test scratch suite and mutation sweep are
prototype evidence. They do not satisfy these gates; the adversarial review found
workflows those tests missed. Keep the delivered T11 files as handoff evidence;
make production changes in coordinator-owned paths and retain focused review
probes alongside the new regression tests.
