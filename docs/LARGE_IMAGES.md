# Bounded object and DWARF readers

## Full-image budgets

Source lines, inline frames, types, disassembly and names for a native stack
need the whole ELF image. xodb copies it into its own memory, checks that the
file did not change during the copy, and never maps the file itself. Two
budgets bound those copies:

| Budget | Default | Option | Preference |
| --- | --- | --- | --- |
| One image | 256 MiB | `--image-limit SIZE` | `symbols.image_bytes` |
| All images in the xodb process | 1 GiB | `--image-total-limit SIZE` | `symbols.image_total_bytes` |

`SIZE` is bytes, or a whole number with `K`, `M` or `G` (`256M`, `4G`); the
preferences take bytes. Values from 1 MiB to 1 TiB are accepted (2 GiB at most
on a 32-bit host); anything else stops startup with the accepted range. The
command line wins over the preferences file. An image must fit both its own
budget and what is left of the total. The budgets are caps, not allocations:
memory is used only for images that are actually read, one copy each.

The defaults are small on purpose. The files a debugged process maps are the
process's to choose, and a budget is what xodb will read of them without
being asked. Larger budgets are opt-in: a 1 GB executable with DWARF costs
about 1 GB of resident memory once a stack through it is shown, and that is a
choice for whoever runs the debugger. The preferences file is the user's own
and is trusted with it.

When an image does not fit, xodb says which and why, and what to rerun with
for that image, in the same words everywhere:

```
/opt/game/engine is 1004 MiB; image budget 256 MiB; rerun with --image-limit 1100M --image-total-limit 3G or set symbols.image_bytes and symbols.image_total_bytes
/opt/game/libphysics.so is 300 MiB; 120 MiB left of the 1024 MiB total image budget; rerun with --image-total-limit 2G or set symbols.image_total_bytes
```

The suggested per-image value is the image's size plus 5%, rounded up to a
whole number of hundreds of MiB. The suggested total is whole GiB: enough for
the image beside what is already held, and at least twice the rounded
per-image suggestion, so searches of every image keep their share (below).
`--image-total-limit` is also named when that suggestion exceeds half the
current total. A suggestion is never above the
accepted range; an image larger than the range says so instead. The
preferences take the same values in bytes.

- `get_stack` carries it as top-level `image_budget`; the affected frames keep
  `inline_diagnostic: BinarySnapshotLimit` and stay unnamed. A compressed
  debug reader keeps `CompressedDebugBudget`; its sentence names the bytes
  needed for the private copy and decompressed data.
- `list_modules` carries the first one as top-level `image_budget` and each as
  `detail` in its `load_failures` row; the regions have `full_image_deferred`.
  Its `image_bytes` gives the process-wide figures: `held`, `peak`,
  `total_limit`, `image_limit`, `sweep_held` and `sweep_limit`. The sweep figure
  includes derived debug bytes read for source searches.
- `find_symbol` answers `ImageBudgetExceeded`, with the sentence as a second
  text item, when a name is not found while an image is unread.
- The GUI status line shows `Over budget: FILE is N MiB; …` for the selected thread.
- stderr suppresses repeated counts and permits at most one `module budget:`
  line per second across the process. Current details remain available through
  the requesting tool and `list_modules`, including after a burst stops.

The path in that sentence is the target's to choose. It is shown as UTF-8 of
at most 512 bytes: a longer path is cut between characters and ends in `...`,
and control characters and bytes that are not UTF-8 become `?`. The GUI status
line shows the file name only, cut to 128 bytes the same way.

### One total for the whole process

The total is a single figure for the xodb process. Everything that holds
full-image bytes reserves from it before reading and gives the bytes back when
it lets go:

| Holder | What it holds |
| --- | --- |
| Each debugged process (every followed child with `--follow-forks`) | images read for stacks, source, types and names |
| Each CPU capture | every executable mapping of the process, read when the capture starts (up to 256 images), and each one mapped while it runs; within the bounds for [searches of every image](#searches-of-every-mapped-image) |
| Each opened profile archive | the verified local images its samples resolve against, when asked to resolve them |
| Allocation capture | every executable mapping of the process, read when the capture is prepared, for its call stacks; within the same bounds |
| An observation recipe (`--observe-recipe`) | every executable mapping, searched for the recipe's functions; within the same bounds |
| Explicit and discovered debug files | each companion file |
| Debug readers | the private copy and inflated sections of compressed DWARF |
| Opening a core | the named executable, while its build ID is read |

One version of a file is read once and shared. A file is identified by device,
inode, size, modification time and change time, the same identity the reader
checks before and after its copy. So a session and a capture of the same
program hold one copy of its executable, and 32 followed processes that map
the same library hold one copy between them. The copy is still xodb's own
read-only memory, never a mapping of the file; a file that changes is a new
version and is read again.

A debugged process keeps its images until it is restarted, it execs, or the
session ends. They are not released when the process exits: its module list
stays readable, and the parts of xodb that hold on to a loaded image are only
told to let go when the process image changes. An exited process therefore
still counts toward the total, once per file however many processes shared it.

The symbols-only views of the next sections (128 MiB per debugged process) and
libdw's own working memory are separate from this total.

### Compressed debug sections

An image whose debug sections are compressed (`SHF_COMPRESSED` or `.zdebug_*`)
needs a private copy of the image plus the inflated sections. Before anything
is allocated the copy plus the sizes the section headers declare must fit both
budgets, or the reader refuses with `CompressedDebugBudget`. Once the sections
are inflated the charge drops to what exists: the copy and the sections that
did inflate. A section that declares a large size and then fails to inflate
holds nothing.

The declared size is a sound bound: a stream larger than it declares is not
inflated. The consequence is that an image with compressed DWARF needs the
image plus the inflated DWARF to fit `--image-limit` at once: an image whose
compressed debug info inflates to more than what the budget has left over the
image cannot open its debug info. Raise `--image-limit` for it.

### Other bounds

Windows (PE) images keep their 256 MiB bound, including from a profile
archive. The optional adjacent PDB reader is outside the process-wide image
total: one worker per session may read a PDB of at most 64 MiB, allocate at most
64 MiB for its parser, and perform at most 256 MiB of stream work. These bytes
are reserved against the separate 256 MiB PE metadata cache; they are not
controlled by `--image-limit` or `--image-total-limit`.
A Mach-O file is never read whole. `get_macho_image` reads the header, the load
commands and the tables it is asked about through ranged reads of the pinned
file, at most 64 MiB per call (the reader's own caps are 128 MiB read and
96 MiB retained), and keeps nothing afterwards, so it reserves nothing from
the image budgets and has no row in the table above. See [MACHO.md](MACHO.md#bounds).
What a name lookup reads of images that have no symbols-only view
keeps fixed bounds too (256 MiB each, 512 MiB for one process; see "Name
lookups and the full image"). With a runtime agent, whole-file transfers keep
the agent's fixed 256 MiB cap, whatever the local budget is; the refusal says so. Opening a
profile archive reads only verified local assets under the same two budgets,
so an archive cannot make xodb read more than they allow.

A full image may have up to 1,048,576 sections and 4,096 program headers, its
section names may total 64 MiB, and no single name may exceed 1 MiB. An image
outside those bounds is refused with `TableLimit` rather than walked.

Working out where an image is loaded takes one pass over the mappings of its
file, once per map, whatever the number of mappings: 60,000 mappings of the
executable cost a fraction of a second. The pass is mappings × program
headers steps, and one map gets 2^27 of them, between one and two seconds of
work. A file that would exceed what is left (tens of thousands of mappings of
a file with thousands of program headers) is refused with `MappingLimit`,
which `list_modules` shows under `load_failures`. Files already placed are
not affected, and a placement of fewer than 4,096 steps (any ordinary
library) is neither counted nor refused, so a file that uses the allowance up
does not take the names of the libraries beside it.

### Name lookups and the full image

Symbol lookups normally read only the symbol tables (next sections). A target
chooses what it maps and what those files say: it can make that reader refuse
an image, by giving it more than 64 MiB of symbol tables or too many sections,
and it chooses how many such images it maps. So one rule decides whether a
name lookup may read an image in full:

1. **An image already loaded** for another reason, such as a stack frame in
   it, is searched at no further cost.
2. **An image with a symbols-only view** (an ordinary ELF file of a live
   process) is never read in full to look, with one exception. For a name
   someone asked for (`find_symbol`, a breakpoint by symbol, `--break NAME`),
   the **main executable** is read in full when its tables are too large for
   the symbols-only view, under the image budgets. It is the one file a
   process cannot multiply, and the one whose names are wanted first: this is
   what makes `find_symbol` work on a 1 GB game engine with 105 MB of symbol
   tables. It is identified by device, inode and path, and once a file has
   been chosen for a process image no other file ever is.
3. **An image with no symbols-only view** is read in full by any lookup, but
   only within fixed bounds: 256 MiB each and 512 MiB for one process,
   whatever the image budgets are. These are libraries stored inside a
   container (an APK), and every image of a core or of another session
   without a live process. A larger one is refused with its own sentence:

   ```
   /data/app/base.apk is 300 MiB and has no symbols-only view; a name lookup may read 256 MiB of it (such images: 256 MiB each, 512 MiB per process)
   ```

4. **The image a language view finds its runtime in** is then read in full,
   because the view needs its types, and nobody asked for it by name. If it
   is the main executable it is read under the image budgets, like the
   executable the Lua, Ruby, Go and Emacs Lisp views read. Any other image
   (a `libpython` or `libperl`) is read within the fixed bounds of rule 3,
   and at most four images that define the runtime's symbol are read for one
   view. A larger interpreter library makes the view, and its tab, report
   the budget error. The sentence ends with whether anything else will load
   the image:

   ```
   /opt/app/libperl.so is 300 MiB; a language view may read 256 MiB of the image it finds its runtime in, unless that is the main executable (256 MiB each, 512 MiB per process); a stack frame in it loads it
   /opt/app/libpython3.so is 300 MiB; a language view may read 256 MiB of the image it finds its runtime in, unless that is the main executable (256 MiB each, 512 MiB per process); it has no debug info, so a stack does not load it either
   ```

   A library with debug info is loaded by a stack frame in it, under the
   image budgets; the tab is looked at again whenever another image has been
   loaded, so it does not go on saying "unavailable" when the view works. A
   library without debug info is unwound from its frame tables and is never
   loaded in full, so a stripped interpreter library over 256 MiB keeps the
   view unavailable. That is a limit of this rule, not of the budgets:
   raising them does not change it.

Automatic lookups (runtime detection for Python, Perl and the other language
views) follow the same rule without the exception in 2: they never read an
image that has a symbols-only view in full to look, and report their budget
error instead.

So a lookup costs at most one image plus the bounded reads of rules 3 and 4,
whatever the target maps. When a name is not found and some library could not
be searched, `find_symbol` answers `ImageBudgetExceeded` with a second text
item naming the first such library:

```
/opt/game/libhuge.so: symbol tables too large to search by name until the image is loaded; only the main executable is read in full for a name
```

Its names resolve once the image is loaded, for example by stopping in it.

With `--follow-forks`, the exception in rule 2 belongs to the process the
name was given for. A followed child inherits its parent's pending
breakpoints, and resolving an inherited one is an automatic lookup: it does
not read the child's executable in full. So `--break NAME` on a launcher that
forks and then execs a very large program does not resolve in that program by
itself. Asking in the child (`find_symbol` or a breakpoint by symbol with its
process ID) is a request for that process and may read its executable; so
does anything that loads the image, such as showing a stack in it.

Two other requests read one full image each and are outside this rule,
because they need more than names: a stack frame (or an address you give)
loads the image it is in, under the image budgets, and a saved breakpoint is
restored by loading the one image it was set in.

### Searches of every mapped image

Some requests have to look in every image the process maps, and the process
chooses how many there are and how large:

| Request | What it reads |
| --- | --- |
| A breakpoint, `run_to`, `control_dependencies` or `slice_value` by `FILE:LINE` (MCP and the GUI's source pane) | every mapped image, for its line tables |
| Starting a CPU capture | every executable mapping, so samples resolve later |
| Preparing an allocation capture with call stacks | every executable mapping |
| `--observe-recipe` with functions | every executable mapping, for those functions |

One such request must not fill the total and leave nothing for the frame you
are stopped in. So every load in xodb states why it wants the image, and the
bound follows from the reason, in one place (`Modules.allowance`):

| Reason | Bound |
| --- | --- |
| a stack frame, or an address you gave | the image budgets |
| a name lookup | rules 2 and 3 above |
| a language view's runtime | rule 4 above |
| a saved breakpoint | the image budgets (through a runtime agent: the bounds of rule 3) |
| a search of every image | below |

A search of every image reads an already held image at no extra cost. Every
new image, **including the main executable**, counts against the sweep share:
`min(total / 2, total - per_image)`. At defaults that is 512 MiB; with
`--image-limit 2G --image-total-limit 8G` it is 4 GiB. The main executable may
be as large as the per-image budget; other new images may be at most 256 MiB.
Derived copies and inflated debug sections opened for a source search also
count against the share.

The share belongs to the whole xodb process. Its charge stays with a shared
file version until the **last** reader releases it: a parent executing a new
program cannot give back a charge for bytes its followed child still holds.
A frame using an image first loaded by a sweep does not remove its charge.

Sweeps alone leave at least one per-image budget free in the total, even
when the executable is large. Explicit frame, name, runtime and saved-image
requests use the total too and can consume that remaining room. If the user
sets the per-image budget at or above the total, the sweep share is zero.
The options are capped at the accepted range; at its largest values there
may be no accepted total that is twice the per-image value.

A search that skipped an image says so, so that "no code for this line" is
never taken for an answer about images that were not read:

- `set_breakpoint` and `run_to` by line carry `images_not_searched` (a count
  of files) and `image_budget` (the first one's sentence) in their result.
  When the line is found nowhere the error is still `NoCodeForSourceLine`,
  with a second text item `N images not searched; SENTENCE`.
- `control_dependencies` and `slice_value` carry the same two fields in their
  `no_selection` answer.
- `start_profile` and `get_profile` carry them under `mapping_history`;
  `get_allocation_capture` carries them at the top; `--observe-recipe` prints one
  line to stderr.
- The GUI status line says that some images are over the image budget, and
  the Modules list names them.

```
/opt/app/libhuge.so is 1023 MiB; a search of every mapped image reads at most 256 MiB of an image that is not loaded; raise --image-limit if needed, then a stack frame in the image can load it
/usr/lib/libz.so.1 is 1 MiB; 0 MiB left of the 512 MiB of the total image budget that searches of every mapped image may hold; rerun with --image-total-limit 2G or set symbols.image_total_bytes; a stack frame in the image loads it
```

To search a skipped image, show a stack with a frame in it (it is then held,
and free to every later search), or raise the total. A search also may skip
the library the thread is stopped in, if the stack has not been shown yet and
other images came first; the reply says so, and after `get_stack` the same
request covers it.

A stopped CPU capture retains its images so its samples can still be resolved
and exported. To free them before rebuilding or restarting a target, call
`release_profile` with its `capture_id`, `revision` and the current session
`generation`. Export first if the capture is needed later. A collecting capture
refuses release. A borrowed capture returns `ProfileViewPending` while its
reader is cancelled; retry after it finishes. Starting a replacement capture
also releases the stopped one **before** reading the new images. A later perf
open failure therefore leaves no previous capture. Other holders of a shared
image still count until they release it too.

A compressed-debug refusal adds a `CompressedDebugBudget` row and sentence
to `list_modules`. A source search counts that file as not searched, even
though its compressed image fit: missing line information is never silently
reported as a complete search.

A search reads each file once, through one loaded copy, however many times
and at whatever addresses the process mapped it; a file that cannot be loaded
is tried once. Its time is linear in the number of mappings: 8,000 mappings
of one file answer in a tenth of a second. One source line may resolve to at
most 4,096 addresses; a line in a file mapped more often than that is refused
with `SourceLineAddressLimit` (a breakpoint by line holds at most 128 anyway). A line
of a small inline or template function in a header can reach the bound in one
large optimised program as well (`Vector::size()` in a 1.3 GB game engine
does); give an address or a symbol for such a line.

A core is searched the same way, and has no main executable for this
purpose: every image of a core over 256 MiB is searched for a line only once
a stack frame has loaded it.

Through a runtime agent the main executable is not told apart in a search
either: it counts as any other image there, within the same 256 MiB and the
same share of the total. Separate file transfers can have distinct snapshot
identities, so two agent readers can require separate copies of one target
file. Release the earlier capture, or restart to release a line reader,
before testing a fresh capture at a full sweep share. Caller frames use
metadata-only unwinding until their image is explicitly selected; selecting
an address uses the frame budget. The agent's fixed 256 MiB whole-file transfer
cap is unchanged by host budget options.

The periodic `image-budget-lifecycle`, `image-budget-regressions` and
`image-budget-torch` checks exercise these bounds. The Torch check uses
`python3` by default; `XODB_TORCH_PYTHON` selects another existing Python with
Torch installed. It reports named self-sample coverage and requires named
`libtorch_cpu` samples after the budget advice admits the mapped images;
it does not assert a fixed percentage.

## Ranged readers

The C components in `src/binary/object*` and `src/debug/dwarf_*` provide ranged
reads and reusable name indexes for large ELF debug images. The live JavaScript reader uses these components through a background metadata
job. Native stripped-library stacks use bounded CFI-only views directly;
images with DWARF, `.debug_frame`, or a verified companion retain the full
source/inline path.
Native stacks that exceed the full-image budget can also request a CFI-only view. Other full-image consumers retain their existing snapshot limits;
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
shared file-identity ledger, so reload cannot silently mix file versions. Remote jobs
keep their existing four-active-job limit and are not LRU victims. JavaScript
jobs retain their separate two-slot bound. Job, object and decoder overhead,
symbol projections, and full DWARF snapshots are separate from the CFI cap.
Metadata status paths have a 512-byte preview with `image_truncated`; full paths
remain available through paged `list_modules`.

Full-image refusals produce at most one summary per stopped generation: `module budget: N full images loaded, M mapped files deferred`. Repeated
VMAs count as one deferred file. Each affected `list_modules` region carries
`full_image_deferred`, even when the 64-entry detailed `load_failures` list is
full. Successful symbols or CFI do not mean full code/DWARF was loaded. The summary describes the first refusal batch at that stop; subsequent deferred
files remain visible through `list_modules`. Unchanged polls do not recount
regions, and further queries at the same stop do not repeat the notice.

The shared identity ledger also caches companion discovery and the choice of
metadata-only unwinding. Rejected and missing companions are tried once per
mapped file identity. Adding an explicit debug file or search root, or changing
automatic discovery, invalidates those decisions. Automatically retained
companions do not invalidate decisions for other images.

File identity includes size, modification time and change time. Touching a
mapped library can therefore make metadata stack frames or an evicted-image
reload refuse with `BinaryChangedDuringRead` or `DebugMetadataFileChanged`, even
when its bytes are unchanged. Exec or restarting the target establishes a new
module set. Existing immutable full snapshots remain usable; the debugger never
mixes newly read metadata with an older pinned file version.

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
python3 tests/module-unwind.py --work .work/unwind-companions --companions
python3 tests/module-unwind.py --work .work/unwind-large-companions --large-companions
python3 tests/module-unwind.py --work .work/unwind-full-dwarf --full-dwarf
```

The first uses 12 stripped, optimized libraries padded to 64 MiB and compares
unwound PCs with compiler return addresses recorded by the inferior. The eviction variant
visits 66 small libraries, proves eviction and cold reload, then changes an
evicted source timestamp and requires refusal. The budget variant requires an
explicit refusal for a working set with 24 MiB of CFI per image. `--wrong-result` plants a wrong
caller PC and must fail. RSS and CPU readings accompany both runs.

The companion variants repeat stacks through four libraries with wrong-CRC debug
files and require one rejection per file. The full-DWARF variant exceeds the
full-image budget progressively and requires one summary for the stop.
