# Adversarial review of the first archive proposal

2026-10-01. Review of [M2_ARCHIVE_PROPOSAL.md](M2_ARCHIVE_PROPOSAL.md), Claude's
[T11 handoff](research/capture-archive.md), the codec and current shared model.
**Recommendation: revise before adopting.** No production integration or codec
fixes were made during this review. The findings below distinguish reproduced
failures, code-inspection findings and design recommendations.

**Subsequent user decision, 2026-10-01:** omit file/directory durability syncs.
The [adopted proposal](M2_ARCHIVE_PROPOSAL.md#6-publish-with-an-explicit-outcome)
now uses `not_published` / `published`; the original fsync observations and
recommendations below remain as the historical review.

## 1. Saving a reopened capture can corrupt its meaning or make it unreadable

**P1 — reproduced.** `decode` separates recorded origin into `Opened.source`, and
assigns the working `Capture` an offline PID/session/generation and a new local ID.
`encode` accepts only `Capture` and a saving environment, so it cannot preserve
that origin or the complete image manifest. `encodeImages` writes only images
successfully loaded in this process.

In the directed probe:

- Original capture/session/PID/generation were **7 / 3 / 4100 / 42**.
- Saving the verified reopened capture recorded **101 / 0 / 0 / max-u64** instead.
- Its boot ID became the new writer-supplied boot ID, while sample timestamps
  retained their original clock domain.
- Opening with image loading disabled, saving, and opening again failed with
  **`ArchiveInconsistent`**. Mapping image IDs survived, but their manifest
  records were omitted because no ELF was loaded.

The existing test at `archive_test.zig:186` says it checks re-encoding the reopened
capture, but both encode calls actually use `original`. This explains a hole in
the claimed round-trip coverage.

**Revision:** retain immutable capture origin, capture clock domain and the
complete asset manifest independently of the live/offline view. Archive encoding
must consume that full artifact. Keep writer host/boot/time and derivation history
in separate fields. Preserve manifests even when assets are missing. Until a
lossless second save exists, explicitly refuse it. Passing the saving machine's
boot ID must never relabel old monotonic timestamps.

Code anchors: `archive.zig:209` (`encodeMeta`), `:313` (`encodeImages`), `:487`
(`Opened`), `:545` (`decode`).

## 2. A verified ELF remains mutable and can crash the reader

**P1 — reproduced.** The resolver hashes an external file, marks it verified,
then retains a read-only `MAP_PRIVATE` file mapping. That mapping is not an
immutable snapshot.

The probe changed one byte in `hot_hash` in an owned ELF copy after verification.
The retained mapping changed, its recorded hash remained the old value, and the
image report still said **`verified`**. A separate probe truncated an owned copy
after verification and then saved: hashing the retained mapping produced a
**bus error followed by process abort** (exit -6 through Zig's crash handler).
This is an in-place edit/truncation case; replacing a path by renaming a different
inode is a different operation.

Linux documents that later file changes have unspecified visibility through
`MAP_PRIVATE`, and access beyond the mapped file's end can raise SIGBUS.
[Linux mmap manual](https://man7.org/linux/man-pages/man2/mmap.2.html).
The live capture module also uses file mappings; archive claims must not imply it
already retained immutable capture-time bytes.

**Revision:** hash and parse the same owned immutable byte snapshot, within
explicit resource limits. A copied/sealed asset store can support larger files;
its identity and lifetime must be part of the contract. Reading, hashing and
parsing must fail cleanly if an external candidate changes. Capture-time asset
identity and an external path first examined at save time are different facts.

Code anchors: `archive.zig:834` (`loadImage`), `src/model/modules.zig:100`.

## 3. Archive identity and capture revision do not pin a flame graph

**P1 for agent citations — reproduced.** With verified symbols, samples at
different instructions in a function merge into a function node. Without them,
those addresses remain distinct. The derived graph therefore depends on available
assets and analysis behavior, as well as the recorded samples and filters.

For the same encoded capture at revision **99**, the probe produced **56 named
nodes versus 57 raw nodes**, with **38 shared node numbers differing in identity
or counts**. Both views retained **2,002 accepted samples**. The assertion in the
handoff that preserving revision preserves node IDs does not hold across these
resolution contexts. Future unwinding/symbolization changes add another source
of variation.

**Revision:** identify a derived view by artifact identity, filter, analysis
version/options and symbol-resolution context. Node numbers should be temporary
handles within that view. Durable citations should reference recorded samples or
module/mapping identity and address/ancestry, with the relevant filter. Symbol
resolution must either create a new view revision or leave the existing view
immutable. Record enough analysis provenance to explain changed results.

Code anchors: `src/profile/capture.zig:398`, `src/profile/flame.zig:47`.

## 4. Portability is too weak for the intended investigation workflow

**Design concern.** After rebuilding a game/server, moving to another workstation
or giving a capture to a remote agent, the exact original binaries may be absent.
The default archive then loses names, function grouping and source navigation.
The saved bytes remain useful, but the reader cannot reliably reproduce the
investigation the user saw. A directory lookup by basename also cannot represent
two distinct binaries with the same filename; hash checks avoid a false match
but do not solve discovery.

I put too much weight on keeping the initial file small. We can retain useful
context without requiring full binaries or an entire source checkout in every
archive.

**Revision:** include a bounded table of capture-time symbol resolutions by
default: module identity, address/range, name, available line location, resolver
version and limitations. Label it as recorded derived metadata; keep normalized
samples authoritative. Permit an explicit bundle of matching ELF/debug assets
and selected source bytes for deeper portable inspection. Source contents remain
optional and must carry their own hashes/provenance. Prefer asset lookup by
content identity; treat paths/basenames as hints.

Acceptance should include reopening after removing the original build directory
and comparing the saved view with an intentionally re-resolved view.

## 5. Resource bounds and responsiveness are underspecified

**Reproduced and code-inspection findings.** The earlier review reproduced 500 ms
blocking opens on both FIFO archive paths and FIFO image candidates. Opening with
nonblocking flags before validating regular-file type addresses that specific
case. It does not guarantee responsive disk access: `O_NONBLOCK` does not prevent
blocking I/O for regular files. [Linux open manual](https://man7.org/linux/man-pages/man2/open.2.html).

The 64 MiB input cap also does not cap external ELF hashing/mapping, total decode
allocations, or UI-thread time. The reported 14.7 MB budget fixture used relatively
short paths. Filling its 20,480 mappings with valid 800-byte paths produced an
archive of **30,473,783 bytes**, and it decoded successfully. That is within the
64 MiB cap; it disproves treating 14.7 MB as the largest valid archive. No claim
about worst-case heap usage follows from this test.

**Revision:** specify separate limits for input bytes, decoded evidence, external
asset bytes and derived work. Report what was skipped or unavailable. Keep
loading/hashing/derivation off the UI event loop, with progress and cancellation
between bounded work units. Test maximum string totals and cold/slow assets,
not only maximum event counts. Retain the current numerical bounds until those
measurements support a change.

## 6. A save error does not necessarily mean nothing was saved

**P2 — reproduced.** `publish` links the completed temporary file into place,
then opens/fsyncs the destination directory. A failure in that last phase returns
`ArchiveSyncFailed` after publication has already succeeded.

In an owned directory with write/search permission but no read permission, the
tool returned **`ArchiveSyncFailed`**, yet the destination existed and decoded
successfully. A blind retry would encounter `ArchiveExists`. The no-overwrite
property held; the result does not communicate the actual publication state.

**Revision:** return structured publication state: not published; published with
durability unconfirmed; or published and synced. Include destination and artifact
identity where available. Make save-on-shutdown failures visible in CLI exit
status or an equally explicit result contract; a log alone is inadequate for
machine callers. Do not delete a published capture to simplify an error result.

Code anchor: `archive.zig:895` (`publish`). Evidence:
`.work/archive-publish-review-20261001T081329629588/result.json`.

## 7. Do not freeze the format around today's in-memory Capture

**Design concern.** T10 is adding user registers/stack bytes and reconstructed
callers. The proposed SMPL records do not contain those facts. Future thread
enrollment would also need lifetime/enrollment-gap records. Although the section
header permits unknown ignorable sections, decode discards them and re-encoding
cannot preserve them. Adding fields to an existing required section is not a
transparent minor-version extension because the reader rejects section slack.

The format already has useful explicit endian/architecture tags. This does not
require implementing Android or a generic serialization framework now.

**Revision:** define required/optional feature declarations and a section plan
for the imminent stack data. An older reader must report unsupported evidence,
retain opaque optional sections if copying, or refuse a lossy rewrite. Separate
immutable archive records from runtime caches, current PID/generation sentinels
and loaded-asset pointers. Avoid promising permanent 1.0 compatibility until that
boundary and the imminent T10 data are accounted for.

## What I would keep

- Separate offline sessions for the first UI: a reasonable way to limit initial
  work. The model should distinguish an archive handle from a controllable target,
  permitting future comparison without redesigning the archive format.
- Shared flame/timeline/scheduling algorithms and explicit uncertainty/loss.
- Fixed endianness, explicit code tables, length/checksum validation, no native
  pointer serialization, and rejecting unsupported required evidence.
- New-file publication with mode 0600 and no automatic overwrite or cleanup of
  other files. Full compression and embedded source trees can wait.

## Recommended revised shape and acceptance

1. **Immutable artifact:** capture origin and clock, normalized recorded evidence,
   complete asset manifest, recorded symbol/line annotations, and feature tags.
2. **Derived view:** artifact reference, filter, analysis version and resolution
   context; disposable node IDs; optional verified assets for further analysis.
3. **Live target:** separate control identity and explicit capabilities. Recorded
   PID/generation never supply authority, even when values resemble a live target.

Before integration, demonstrate a real capture through save, target exit, original
binary removal, offline inspection, re-save, and second reopen. Check provenance,
sample/filter conservation, recorded labels, missing assets and stable evidence
references. Add directed file-mutation/truncation/FIFO and publication-phase tests,
plus private-GUI responsiveness. Existing synthetic tests remain valuable, but
the 96 baseline tests and byte-mutation sweep do not establish these workflows.

## Reproduction and scope

Run `python3 tests/repros/archive-review/run.py` with the delivered T11 prototype
and the existing `zig-out/bin/xodb-profile-fixture`. It copies code and binaries
into a fresh repo-local directory, backs up each changed ELF copy, disables core
dumps in the crash probe, and records observations rather than requiring bugs to
remain. Production code and delivered task-owned files are unchanged.

Final directed evidence:
`.work/archive-adversarial-20261001T081300035021/results.json` and per-case logs.
Source hashes and the exact scratch program are retained alongside results.
The earlier FIFO evidence is
`.work/archive-file-review-20261001T080213007039/results.json`.
Only owned file copies were mutated/truncated; no target process was attached.

External LLMs particularly need origin preservation and derived-view identity:
otherwise a confident citation to an archived node or boot timestamp can refer
to different evidence after reopening. Checksums establish byte integrity and
identity, not authenticity or proof that an arbitrary imported claim is true.
