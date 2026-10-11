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

## Not read yet

| Missing | Effect | Where it belongs |
| --- | --- | --- |
| Live module discovery on a macOS target | no Mach-O image appears in the module list or in stacks | with the macOS target's image list (dyld's image infos), feeding this reader in the memory layout |
| Debug info | no source lines, locals or types | debug map (`N_OSO` to the `.o` files) and `.dSYM` by `LC_UUID`, into the DWARF readers |
| Compact unwind and `__eh_frame` | no Mach-O stack unwinding | a `__unwind_info` decoder that hands DWARF-mode entries to the existing CFI code |
| The dyld shared cache as a file | `unsupported`; cache libraries are read from memory instead | a cache-file reader, with the `.symbols` file for stripped locals |
| Exports trie, chained fixups, bind and rebase opcodes | exported-only names of stripped images are not found; pointers in a file are not resolved | with symbolication of stripped system libraries |
| 32-bit, big-endian, arm64_32 | `unsupported` | not planned |
| More than 2,097,152 symbols | `limit` | raise the cap with the retained budget when a real image needs it |
| Symbol lookup over MCP in a file with more than 131,072 symbols | `symbol` and `symbol_at` report `limit` | with images that are kept between calls and indexed by a background job, as PE images are |

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
