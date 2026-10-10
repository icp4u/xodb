# Bounded object and DWARF readers

The C components in `src/binary/object*` and `src/debug/dwarf_*` provide ranged
reads and reusable name indexes for large ELF debug images. The live JavaScript reader uses these components through a background metadata
job. Native stripped-library stacks use bounded CFI-only views directly;
images with DWARF, `.debug_frame`, or a verified companion retain the full
source/inline path.
Native stacks that exceed the full-image cap can also request a CFI-only view. Other full-image consumers retain their existing snapshot limits;
these paths do not imply complete large-image source or type support.

Ordinary local name lookups also use a symbols-only ELF projection. Headers,
symbol tables and their strings/indexes, notes, section names, dynamic metadata
and `.gnu_debuglink` are retained; code and DWARF contents are omitted. Files up
to 256 MiB use an immediate bounded local read. Larger files use the cancellable
worker. Both validate the pinned source and seal the result before publication.
Full code, source and type inspection retain their separate snapshot limits.

Local symbol projections use a 128 MiB LRU budget, charged by the greater of
copied bytes and allocated backing pages, excluding sparse holes. Published
names and mapped-instance IDs survive eviction. Reloading an evicted image, or
promoting it to a full snapshot, must match the original source device/inode,
size and modification/change timestamps. Remote projections remain pinned
within the same cap because that API does not expose their original file
identity. Up to 1,024 image identities and 65,536 published names (16 MiB of name
text) are retained per module set; these are limits, not initial allocations.
A worker's in-progress projection has its separate 64 MiB copied-byte limit.

Local CFI jobs keep only `.eh_frame` and `.eh_frame_hdr` in a compact ELF.
Images up to 16 MiB use an immediate local read; larger images and remote files
use workers and report `DebugMetadataPending` until ready. The local cache
admits at most 64 jobs and 128 MiB of unwind containers, reserving each worker's
32 MiB maximum while it can still allocate. Completed local jobs are evicted by
last stack query; jobs used by the current walk stay pinned. A walk that cannot
fit reports a budget refusal. Original file versions survive eviction in the
symbol identity ledger, so reload cannot silently mix file versions. Remote jobs
keep their existing four-active-job limit and are not LRU victims. JavaScript
jobs retain their separate two-slot bound. Job, object and decoder overhead,
symbol projections, and full DWARF snapshots are separate from the CFI cap.
Metadata status paths have a 512-byte preview with `image_truncated`; full paths
remain available through paged `list_modules`.

Full-image refusals produce one changed-count summary after a scan or session
poll: `module budget: N full images loaded, M mapped files deferred`. Repeated
VMAs count as one deferred file. Each affected `list_modules` region carries
`full_image_deferred`, even when the 64-entry detailed `load_failures` list is
full. Successful symbols or CFI do not mean full code/DWARF was loaded. Counts
are retained over unchanged mappings and repeated queries do not repeat notices.

`xbo_object` borrows a pinned source and validates its device/inode, length and
modification/change timestamps before and after reads. It reads ELF placement,
section metadata and build IDs without copying a whole image. A byte/read/deadline
budget or cancellation preserves partial metadata/read progress. A changed
source invalidates the object permanently. Local input uses `pread`, not a
mapping of mutable file bytes. A remote provider must bound callback latency and
bind identity checks to the same retained file handle.

`xdw_cursor` walks DWARF 2–5 using bounded pages, abbreviation tables and a
partially decoded DIE. Callers may skip children, stop/resume, or select a single
CU offset. CU headers, forms, references, extents and nesting remain checked.
Names are direct `DW_AT_name` attributes; abstract-origin/specification
inheritance and split/supplementary units are separate work.

`xdn_query` reads `.debug_names` or `.gdb_index` versions 7–9 with bounded I/O.
It returns candidate CU/DIE offsets. Consumers must verify the actual definition
and fields before accepting a layout. Index exhaustion does not prove that the
full DWARF has no matching definition. Names are currently ASCII, with explicit
refusals for unsupported Unicode folding, oversized names, compressed indexes
and foreign type units. GDB index names use the producer's canonical spelling.

## Persistent caches

`xbc_cache` wraps the pinned source with a private regular cache file. Its key
contains the complete source identity plus build ID. Checksummed contiguous
ranges are reused; gaps remain misses. A corrupt range is discarded and fetched
from the source. Cache hits still validate source identity. Cache files hold an
exclusive nonblocking lease because a read may fill a missing range. Requested
bytes remain charged to the outer reader's budget, whether served from the cache
or source; separate counters show actual source traffic. The caller supplies a quota for the entire sparse file extent, including
per-block metadata. `xbc_extent` calculates that charge before any growth.

`xdi_index` builds a persistent fallback index of direct names on type, function,
namespace, CU, member, variable, constant and enumerator DIEs. It uses bounded memory and
streams records to disk. Buckets are published only after the walk completes and
source identity is revalidated; incomplete indexes cannot answer queries. A
byte/read/work/deadline limit or cancellation resumes within the current builder.
A file-quota refusal resumes after `xdi_set_file_limit` increases the limit within representable file offsets. An interrupted process leaves an unusable partial file, which the cache
owner must discard before rebuilding; cross-process build resumption is not yet
implemented.

A caller can project the fallback index onto a finite exact-name list. The full
ordered list is stored in the cache header and checked on reopen; a query outside
that list refuses explicitly. The JavaScript job indexes the names in its shared
layout-check table, including static members, and still checks namespaces, owner
types and values when parsing the selected CUs. It merges producer accelerator
hints with this complete projection: a missing `.debug_names` member cannot
silently remove a conflicting definition.

Completed indexes support shared read leases and exact-name queries with bounded
work per call. The header, bucket links, records and matched names are checked
before use. Candidates still require normal CU/type validation; no cached name
or offset bypasses the semantic layout checks. The index does not add inherited
names or qualified-name synthesis.

The application's C cache pool chooses `$XDG_CACHE_HOME/xodb-debug-v2`, falling
back to `$HOME/.cache/xodb-debug-v2`. Old `xodb-debug-v1` range files are
truncated opportunistically only after both
the slot and range-file nonblocking leases are held; busy or unsafe old entries
are left intact and checked again on a later open. Old small name indexes remain.
Its directory is mode 0700 and its regular
files are mode 0600. The root must be owned by the current user; a group-writable
root is allowed only with an opened, owner-checked private child. Relative roots,
symlinks at the cache root/entry, nonprivate entries, hardlinks and nonregular
files are never used. Local stripped images need no persistent cache, and local
debug images cache only their name index: source bytes are read from the pinned
local file with identity checks. Range files are populated only for remote images.
Two fixed slots each allow at most 8 GiB of combined range/index file extent,
plus a 256-byte lease record. Sparse holes count toward this quota. Active
leases are never evicted; an unused matching slot is reused, otherwise the
oldest unlocked slot is replaced. A briefly busy scan retries within a bounded
window. If the pool is unavailable, busy or over quota, managed jobs use the
bounded direct scan instead; cache availability never disables inspection.
Interrupted name indexes rebuild, and a query-time malformed index is rebuilt
once under its lease. A second malformed result refuses; the reader never loops
indefinitely over malformed source data. Checked range data can survive. A corrupt range is fetched again. Cache
checksums detect corruption and incomplete writes; they do not authenticate data
against a malicious writer with the owner's permissions.

Cleanup runs when a job opens the persistent pool, not on every Node launch.
Small local and stock stripped Node images bypass the pool, so using only
those builds leaves old files in place. When cleanup does run, it first checks
complete `XODBSLOT` and `XOBCACHE` version-one headers, their checksums,
matching object/build identities and the declared extent. Unknown, truncated
or corrupt files are retained for manual review. No cached source bytes are
read, and active legacy leases are left alone.

A first index build can take substantially longer than a direct scan: it walks
the complete direct-name coverage before publishing candidate CUs. Progress,
cancellation and other client requests stay available during that work. Warm
queries reuse the completed index but still validate the source and parse the
selected CUs. Explicit cache-component quotas, unsupported DWARF and CU-count
limits are typed refusals; increasing the source size never removes a bound.

## Component checks

```sh
python3 tests/dwarf-cursor.py --work .work/dwarf-cursor
python3 tests/dwarf-names.py --work .work/dwarf-names
python3 tests/object-cache.py --work .work/object-cache
python3 tests/dwarf-index.py --work .work/dwarf-index
```

Use a fresh work directory for each run. `--sanitize` selects Clang ASan/UBSan.
The suites include compiler/libdw oracles, tiny resumable budgets, source changes,
corrupt indexes/caches, shared-reader and writer leases, and sparse ELF images
with DWARF or name tables beyond 5 GiB. These are component checks, not evidence
of application support for every large executable.

## Ranged symbols and loaded-image verification

`binary/symbol_query.h` resolves a finite set of exact symbol names with bounded
retained pages. Each step has byte, read, work, deadline and cancellation limits;
progress survives a short budget. Results appear only after every symbol table
has been checked. Conflicting definitions, unsupported TLS/extended indexes,
malformed extents and a changed pinned file refuse explicitly.

`language/javascript_image.h` collects V8 metadata without a whole-image copy.
Its separate verifier compares the loaded build-id note, grouped constants and
version string against the pinned image. One verification work unit performs at
most one target-memory read. File reads retain progress too, so a slow remote
reply cannot repeatedly consume the same deadline without advancing. A caller
must discard the verifier when the stopped generation or load bias changes.

`debug/metadata_job.h` owns the pinned view and one bounded worker. Its full
JavaScript path combines symbols, file constants and the DWARF cross-check;
the DWARF-only entry point is available for callers that already verified the
image. Polling and cancellation do no target I/O. Joined verification is split
into owner-thread steps, validates the pinned file before and after loaded
checks, and withholds every partial layout. The job and borrowed target must be
destroyed in that order. The session cancels jobs on image changes, restart and detach, and joins them
before destroying any borrowed target. Cancellation withdraws a completed job's
ready status too; it does not imply its worker has joined. The UI refreshes after metadata or loaded-
image verification completes. No JavaScript result is published until the file
profile and the stopped process agree.

The native fallback copies only `.eh_frame` and optional `.eh_frame_hdr`, with
their original virtual addresses, into a CFI-only ELF container capped at 32 MiB.
The container supplies unwind rules only: it is not a module or a source/type/
symbol image. Compressed or relocated unwind sections refuse explicitly.

## Using a large Node build

Point the existing demo at your debug Node and its matching headers:

```sh
NODE=./node-debug/bin/node NODE_INCLUDE=./node-debug/include/node scripts/demo-node
```

The demo stops inside its native probe. The status line reports debug-data work;
after it completes, the language view and Locals/Watch can show verified values.
Press `E`, enter `value`, then Return to add that stopped value to Watch. A
pending job is a diagnostic, not an empty language stack. A debug build can
provide values, frame names and scripts while lacking one of the configuration
constants needed for source positions. Such frames keep null positions with
`JavaScriptFrameConfigUnavailable`; see [JavaScript support](JAVASCRIPT.md).

MCP observers can inspect `get_debug_metadata` for the job state, source and cache
traffic, index size and candidate CU count. A controller can call
`cancel_debug_metadata` or `retry_debug_metadata` with the displayed `id`. Retry
discards that job; the next stack/value request starts it again. Stopped-register
and process-generation checks still apply to all returned language values.


## Local symbols and startup breakpoints

For live local images above the snapshot cap, ELF symbol lookup uses the same
C section-selection parser as remote discovery in a background worker. It pins
the file, copies at most 64 MiB of symbol/placement metadata into a sealed sparse
file, and revalidates identity before publication. Reads are at most 64 KiB;
other clients can keep polling while a lookup returns `SymbolDiscoveryPending`.
The view is kept separate from source, code and DWARF consumers. Symbol counts
and file extent remain independent: sparse holes are not copied.

For example, `xodb --break main -- ./node-debug/bin/node demo.js` resolves the
startup symbol before the queued continue enters the target. Symbol breakpoints
keep their logical IDs across restart. Address-only breakpoint restoration still
requires the existing full-module identity path and can refuse a large image.

Checks with owned fixtures:

```sh
python3 tests/metadata-session.py --work .work/metadata-session
python3 tests/metadata-session.py --work .work/metadata-agent --agent zig-out/bin/xodb-agent
python3 tests/local-large-symbols.py --work .work/large-symbols --storage ./large-fixtures
```

These cover shared-client controller leases, cancelled-ready status, retry,
generation changes, restart, exec, fork/vfork detach, exit and shutdown, plus
symbol lookup and first-call startup/restart breakpoints in a runnable sparse
5 GiB image. Choose fresh work/storage paths. `release-check` includes these
checks; `XODB_LARGE_IMAGE_STORAGE` selects its large-fixture destination.

Remote stack walks use the background CFI reader for caller modules whose full
DWARF has not been loaded. They keep source and inline information unavailable
with `DebugMetadataNotLoaded` instead of downloading whole libraries during
automatic stack decoration. Selecting a caller for explicit locals inspection
can still load its full debug image; later stack walks reuse that image. The top
frame and explicit source/locals operations retain their existing synchronous
small-image path.

Native cache checks: the default and debug-frame cases are fast; eviction and
budget variants are periodic.

```sh
python3 tests/module-unwind.py --work .work/unwind-chain
python3 tests/module-unwind.py --work .work/unwind-debug-frame --debug-frame
python3 tests/module-unwind.py --work .work/unwind-lru --eviction
python3 tests/module-unwind.py --work .work/unwind-budget --budget
```

The first uses 12 stripped, optimized libraries padded to 64 MiB and compares
unwound PCs with compiler return addresses recorded by the inferior. The second
visits 66 small libraries, proves eviction and cold reload, then changes an
evicted source timestamp and requires refusal. The budget variant requires an
explicit refusal for a working set with 24 MiB of CFI per image. `--wrong-result` plants a wrong
caller PC and must fail. RSS and CPU readings accompany both runs.
