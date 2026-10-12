# Mach-O metadata reader

`src/binary/macho.c` reads 64-bit little-endian Mach-O images for arm64
(including arm64e) and x86_64: thin files, universal (FAT and FAT64)
containers, and images as they are loaded in an address space. It identifies
an image and reads its symbols. It does not run, load or follow anything:
every path it finds (libraries, debug-map objects) is reported, never opened.

## Try it

A Linux process only has to map the file. `tests/fixtures/macho/hold.c` does
that and stops:

    cc -g tests/fixtures/macho/hold.c -o hold
    zig cc -target aarch64-macos -g tests/fixtures/macho/main.c -o main-arm64
    xodb --headless --mcp --break macho_mapped -- ./hold main-arm64

After `continue`, `list_modules` shows the mapping of `main-arm64`; pass any
address inside it:

    {"name":"get_macho_image","arguments":{"address":"0x7f...","symbol":"_macho_target","sections":true}}

| Question | Argument | Answer |
| --- | --- | --- |
| What is this file? | `address` | `uuid`, `arch`, `file_type`, `platform`, `minimum_os`, `sdk`, `pie`, `in_shared_cache`, `entry`, `code_signature`, `fixups` |
| Which architectures does a universal file hold? | `address` | `container` (`thin`, `fat`, `fat64`) and `slices`, one marked `selected` |
| Read the other slice | `arch`: `arm64` or `x86_64` | the same answer for that slice |
| Where do its parts go? | `address`, `sections: true` | `segments` (addresses, sizes, protections) and `sections` |
| Where is a function? | `symbol`: the stored name, `_main` | `symbol`: link-time address, segment and section |
| What is at this address? | `symbol_address`: link-time hex | `symbol_at`: the covering symbol and its size |
| Was it built with debug info? | `address` | `debug_map`: object files with their timestamps and function counts |

Addresses are link-time addresses, as stored in the file. `get_macho_image` is
an observer tool: it reads a file the process already maps, through the same
pinned, identity-checked file view the other readers use, and returns
`MachOFileChanged` if the file changes while it reads. It keeps nothing between
calls and does not add the image to the process's modules. Each call may read
at most 64 MiB; `reads` reports what it used.

A lookup by name or address indexes the whole symbol table inside the call,
so it is offered for files with at most 131,072 symbols. A larger file still
reports its identity, segments, libraries and counts; `symbol` and `symbol_at`
then carry the status `limit`.

A mapped file is classified once per map revision, like ELF and PE. A file
whose first bytes are a Mach-O magic is `macho`; `0xCAFEBABE` followed by a
slice count from 1 to 32 is a universal Mach-O, and followed by anything else
(a Java class file stores its version there, 45 and up) is not.

## What is read

| Item | Source | Notes |
| --- | --- | --- |
| Architecture, file type, flags | `mach_header_64` | `MH_PIE`, `MH_DYLIB_IN_CACHE`; arm64e is cpusubtype 2 |
| Slices | `fat_header`, `fat_arch`, `fat_arch_64` | the first arm64 or x86_64 slice, or the one asked for by cputype |
| Identity | `LC_UUID` | the key that pairs an image with its dSYM |
| Platform, minimum OS, SDK | `LC_BUILD_VERSION`, else `LC_VERSION_MIN_*` | |
| Segments and sections | `LC_SEGMENT_64` | name, addresses, sizes, file range, protections |
| Entry point | `LC_MAIN`, else `LC_UNIXTHREAD` | as a link-time address |
| Libraries | `LC_ID_DYLIB`, `LC_LOAD_DYLIB` and the weak, re-export, lazy and upward forms | names and versions |
| Symbols | `LC_SYMTAB`, `LC_DYSYMTAB` | by index, by exact name, nearest by address; external, defined, undefined, absolute, indirect or debugger (stab) entry |
| Function starts | `LC_FUNCTION_STARTS` | ascending addresses; they end a symbol where no next symbol does |
| Debug map | `N_SO`, `N_OSO`, `N_FUN` stabs | per object file: path, timestamp, source name; per function: name, address, size |
| Section bytes | `xmo_find_section`, `xmo_section_range`, `xmo_read_section` | a bounded range for later readers of `__unwind_info`, `__eh_frame` and `__DWARF` |
| Presence only | `LC_CODE_SIGNATURE`, `LC_DYLD_INFO(_ONLY)`, `LC_DYLD_CHAINED_FIXUPS`, `LC_DYLD_EXPORTS_TRIE`, `LC_ENCRYPTION_INFO_64` | reported, not decoded |

`xmo_load` reads the header and the load commands and nothing else. The symbol
table, the name index, the address index, function starts and the debug map
each load on first use, once; a failure is remembered and returned again, so
an image whose `__LINKEDIT` cannot be read still gives its identity and
segments. A symbol with a bad name does not fail the table: its name reads as
`malformed` or `limit`, and the table counts it.

Lookup by name uses an index of 32-bit name hashes, sorted once (heap sort,
n log n on every input). Equal hashes are compared by reading the names, at
most 64 per lookup; beyond that the lookup returns `limit`. Lookup by address
is a binary search over the defined symbols that lie inside their own section,
sorted once the same way. Neither path is quadratic and neither recurses.

## Two layouts

The reader has one read callback and two ways to interpret offsets.

- **File**: offsets are file offsets. A universal file is accepted and one
  slice chosen; every later offset is checked against that slice.
- **Memory**: offset 0 is the mach header as loaded and offset N is the byte
  at header address + N. A table named by a file offset is found through the
  segment that maps that offset. `xmo_slide` gives runtime header address
  minus `__TEXT`'s link address.

The memory layout is what a remote macOS target will feed in. A library inside
the dyld shared cache has `MH_DYLIB_IN_CACHE`, segments far apart, and a
`__LINKEDIT` shared with every other library whose string table can be
hundreds of megabytes. The reader asks only for the header, the load commands,
the symbol entries and the 4 KiB string pages that those entries point into;
the test fixture declares a 400 MiB string table of which three pages exist.
Reads must be exact: a source that cannot return all the bytes asked for
returns a failure, and the reader passes it on.

## Bounds

Every field is untrusted. Sums and products are done in 64 bits and checked
before use. A count is checked against what its container can hold, then
against a cap, before anything of that size is allocated.

| Field | Check | Cap | Status |
| --- | --- | --- | --- |
| magic | first 4 bytes (8 for a universal file) | | `not-macho`; `unsupported` for 32-bit, big-endian, other cputypes, a shared cache file |
| `nfat_arch` | not zero; table inside the file | 32 | `malformed`; `limit` above the cap; `not-macho` for a Java class file |
| slice offset and size | after the table, inside the file, no overflow, no two slices overlap | | `malformed` |
| slice contents | one thin image of the cputype its entry names; not another universal file | | `malformed`; `unsupported` for a static archive |
| `ncmds` | `ncmds * 8 <= sizeofcmds` | 16,384 | `malformed`; `limit` |
| `sizeofcmds` | header + commands inside the file or slice | 1 MiB | `malformed`; `limit` |
| each `cmdsize` | at least 8, a multiple of 8, at least its structure, no more than the bytes left | | `malformed` |
| segments | `vmaddr + vmsize` and `fileoff + filesize` do not overflow; `filesize <= vmsize`; file range inside the file | 256 | `malformed`; `limit` |
| `nsects` | fits in its command | 4,096 in all | `malformed`; `limit` |
| section | address range inside its segment | | `malformed`; `unavailable` from `xmo_section_range` when it has no bytes in this layout |
| library name | offset inside its command, terminated inside it | 1,024 bytes, 4,096 libraries | `malformed`; `limit` |
| `LC_UNIXTHREAD` | each flavor's word count inside the command | | `malformed` |
| one-per-image commands | at most one `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_UUID`, `LC_MAIN`, `LC_ID_DYLIB`, `LC_FUNCTION_STARTS`, `LC_CODE_SIGNATURE` | | `malformed` |
| `LC_DYSYMTAB` ranges | inside `nsyms` | | `malformed` |
| `symoff`, `nsyms` | `symoff + nsyms * 16` inside the file, or inside one segment in memory | 2,097,152 symbols | `malformed`; `limit`, before any symbol is read |
| `stroff`, `strsize` | inside the file or one segment | | `malformed` |
| `n_strx` | below `strsize`; terminator before the end of the table | 4,096 bytes per name | per name: `malformed`; `limit` |
| name index work | bytes copied while hashing every name | 256 MiB | `limit` |
| equal-hash names in one lookup | | 64 | `limit` |
| function starts | ULEB128 of at most 10 bytes with no bits above 64; address does not overflow; no truncated value at the end | 16 MiB of data, 2,097,152 entries | `malformed`; `limit` |
| all reads | each inside the source | 128 MiB (or the caller's smaller budget), 262,144 calls, 64 KiB each | `limit` |
| all retained memory | | 96 MiB | `limit` |

Other statuses: `io`, `changed` and `cancelled` are whatever the read callback
returned, unchanged; `unavailable` means a table is absent or is not readable
through this source; `not-found` is a lookup with no answer or a universal
file without the slice asked for; `no-memory` is a failed allocation.

Memory use follows the retained counter: 16 bytes per symbol, 4 more for the
address index and 8 for the name index, 8 per function start, 24 per debug-map
function. An image at the symbol cap retains about 56 MiB.

## Names on a Darwin GDB target

For a target behind Apple debugserver, stopped image lists provide UUIDs,
architecture and executable segment ranges. Stack frames use `image!symbol+offset`
when a configured local binary matches, and `image+offset` otherwise, including
shared-cache frames. Return addresses are stripped to the stub's reported
address width before lookup (47 bits on the recorded arm64e target).

```sh
xodb --gdb-remote 127.0.0.1:2345 --exe ./program --debug-dir /opt/corpus/bin
```

`--exe` is an explicit local executable. Each `--debug-dir` is searched for an
image's basename only; the target's directory names are never opened here.
Files must be regular, without a final symlink, and their LC_UUID, CPU and
subtype must match the stopped image. Universal binaries select the recorded
subtype, including arm64e; capability bits do not change subtype matching.
The pinned file's identity is checked during indexing and before each cached
lookup. A mismatch or changed file produces a typed diagnostic and an image
offset, never a name from the wrong file.

One background worker at a time loads the address index and bounded string
table. Frame queries do no table reads. `MachOSymbolsPending` becomes ready on
a later query; the GUI refreshes when the metadata revision changes. Up to
32 cached images share 256 MiB and the process-wide image budget. Each worker
may retain at most 96 MiB of parser data plus a conservative 128 KiB overhead
reservation, released down to retained size when it joins. Reads across all
candidate directories share a 128 MiB / 262,144-read cap and a ten-second
construction deadline checked at reads. Sorting is bounded by the existing
2,097,152-symbol cap. The stopped image list has at most 4,096 images, 64
segments per image and 16,384 executable intervals; overlapping code intervals
refuse ambiguous labels. These map records and the bounded GDB packet buffers
are separate from the symbol cache's retained-byte figure.

On a Darwin GDB target, `get_macho_image` with only `address` labels a runtime
code address through the same map and local cache. It returns `pending`,
`ready`, or `image_only`, with the label, module ID and diagnostic. Other
options belong to the existing mapped-file inspection mode and refuse on
this path. The background path supports indexed images above 131,072 symbols;
the synchronous mapped-file tool retains its smaller lookup limit.

Image lists are refreshed at each stopped generation. Unloaded images lose
their mappings, and completed metadata for departed UUIDs is released; a
pending worker is cancelled before it can be reused. IDs remain stable for
an unchanged UUID at the same address. The map is not a shared-cache symbol
extractor: shared-cache system symbols still require separate local metadata. A labelled link-register address is not proof that
it is an additional stack frame.

## Source locations, locals and unwind metadata

The Darwin image cache also supplies `get_source_location`, stack source
locations and `list_locals`. It searches for `<image>.dSYM/Contents/Resources/DWARF/<image>`
next to the selected executable and beneath each explicit debug directory;
a debug directory may itself be a dSYM bundle. CPU, subtype and LC_UUID must
match. Every derived component is opened without following symlinks; a final
file must be regular. Retained descriptors are revalidated before each query.
No source path or absolute build path found in DWARF is opened by this worker.

If no dSYM is available, the linked image's N_OSO/N_FUN debug map can identify
object DWARF. Relative object paths are searched beneath explicit roots;
absolute build paths contribute only their basename. Traversal components,
archive-member syntax and backslashes are refused. Nonzero N_OSO timestamps
must match the object. Objects lack the executable's LC_UUID: architecture,
timestamp when supplied, and the named function ranges are checked, but these
checks do not authenticate a build. A changed pinned object refuses later
queries. Ambiguous definitions and missing object addresses remain unavailable.

Translation is per function. Optimized linking can move a cold function by a
different amount from another function in the same object, so one object-wide
slide would give wrong lines. Defined data symbols and unresolved external
relocations have separate checked mappings. The supported object relocation
form is 64-bit, non-PC-relative UNSIGNED; other forms produce
`MachOObjectDebugUnsupported`. Missing external definitions never become zero
addresses. Register and stack locations retain their runtime coordinates;
only DWARF image addresses pass through the object/link/runtime translation.

A private section container exposes the selected DWARF sections to the existing
libdw reader. It contains no program headers or code, never enters the module
map, and preserves link or object addresses, including PC-relative EH data.
The worker's 96 MiB retained-data cap includes companion bytes, object maps and
compact rows; all companion reads share its existing read/deadline budgets.
Object fallback allows at most 64 objects and 16,384 function records. This
figure covers the worker's retained storage, not libdw's internal allocations
or the existing DWARF reader's decoded type/line caches. CPU and RSS evidence
for actual replays is reported separately from those storage counters.

The cache key includes UUID, CPU/subtype, file type and basename; executable
and debug-directory configuration is fixed for that session. Invalid `.` or
`..` basenames are negatively cached as `MachOImageBasenameInvalid` without
starting a worker. An oversized refused image list reports `GdbListTooLarge`
at the frame and `get_macho_image` request that needs it. Image labels share
the PE formatter: a target-chosen `!` in an image name cannot supply the
image/symbol separator.

ARM64 stacks first try the image's EH-frame CFI, then compact unwind, then the
explicit frame-pointer/prologue fallback. Compact regular and compressed pages
are bounded and validated. Frame-based recipes restore FP/LR and saved integer
register pairs; frameless recipes restore SP and use LR. Unreadable saved
registers stay unknown. At an asynchronous first frame, only a zero-stack leaf
can use compact metadata alone; other prologue/epilogue positions need precise
CFI or the fallback. A compact row's start is not treated as a function entry,
because a linker can coalesce adjacent identical recipes. SIMD registers are
not supplied by this transport and are not invented. PAC masking applies to
recovered ARM64e return/frame addresses before lookup.

Each frame's `unwind_method` describes the step from that frame to its caller,
as on native CFI stacks. A recording without executable segment geometry
reports `UnmappedAddress` for inline metadata while the bounded register/frame
fallback can still recover callers.

The owned recordings cover C, C++, Objective-C and Swift at their recorded
entry stops, including optimized line tables and register arguments. Missing
recorded stack/global memory remains `MemoryUnreadable`. Swift dSYMs may omit
member layouts despite supplying names and sizes; those locals report
`SwiftTypeLayoutUnavailable` with unknown type instead of interpreting a
mangled name as a layout. This path does not add Darwin source-line breakpoints,
`run_to`, runtime Swift metadata decoding, shared-cache DWARF, or x86_64 Darwin
stack unwinding. Those require separate run-control or runtime evidence.

## Not read yet

| Missing | Effect | Where it belongs |
| --- | --- | --- |
| The dyld shared cache as a file | `unsupported`; cache libraries are read from memory instead | a cache-file reader, with the `.symbols` file for stripped locals |
| Exports trie, chained fixups, bind and rebase opcodes | exported-only names of stripped images are not found; pointers in a file are not resolved | with symbolication of stripped system libraries |
| 32-bit, big-endian, arm64_32 | `unsupported` | not planned |
| More than 2,097,152 symbols | `limit` | raise the cap with the retained budget when a real image needs it |
| Synchronous mapped-file MCP lookup above 131,072 symbols | `symbol` and `symbol_at` report `limit` | use the background Darwin image path for indexed frame labels |

## Tests

`tests/macho-image.py` builds every fixture: Zig cross-compiles
`tests/fixtures/macho/*.c` for arm64 and x86_64 macOS, and
`tests/helpers/macho_fixture.py` assembles the images a linker will not produce
(arm64e, `LC_UNIXTHREAD`, a debug map, universal files, a shared-cache image in
memory, files past 4 GiB) and the hostile ones. Each case runs under a plain
and an ASan/UBSan build of `tests/macho-image.c`, ends in the expected typed
status, and may grow the process only by what the reader reports as retained.
Linker-built images are also compared with `llvm-objdump` and `llvm-nm` when
those are installed. `tests/macho-image.py --fuzz` adds the cap-sized cases
and a 30-second libFuzzer run of `tests/macho-fuzz.c`. `tests/macho-mcp.py`
checks `get_macho_image` on the native runtime, through the runtime agent and
as a shared observer.

`tests/macos-names.py` replays owned Apple-linked C/C++/Objective-C/Swift,
stripped, universal and arm64e recordings, the abort address example, and
dlopen/dlclose. Hostile UUIDs, ranges and local files must refuse. Its periodic
matrix exercises an index above 131,072 symbols and a small image budget.

`tests/macos-debug.py` checks source/locals through the real MCP endpoint with
both dSYMs and object fallback, including changed/hostile companions and Swift
missing layouts. `tests/macos-dwarf.py` compares component source queries and
per-function object translation. `tests/macos-unwind.py` compares compact rows
with LLVM's dump of the original linked files and checks malformed regular
pages; the Zig unit test checks an actual Swift EH recipe against explicit
synthetic saved-register memory. Sanitized full-file matrices, the production
worker mutation harness and LLDB parser fuzzing run in the periodic lane.
