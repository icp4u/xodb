# PE metadata reader

`src/binary/pe.c` reads PE32+ x64 metadata from an explicit file layout or loaded
memory layout. It follows the [Microsoft PE format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format).
Native Linux sessions discover file-anchored Wine images, including anonymous
code/data mappings covered by their sections. Export names and `.pdata` function
starts supply stack labels and symbol breakpoints. Native Windows x64 stack
walking uses version-1 SEH unwind records and reports its method per frame.

The reader retains sections, export entries and aliases, forwarder strings,
imports, CodeView RSDS identities and sorted executable runtime-function ranges.
Forwarded exports remain strings; they are never returned as code addresses.
Export holes do not resolve to the image base. Valid data exports may refer to
zero-filled storage, but file metadata reads cannot consume that storage as
unrelated following file bytes. File and loaded-memory CodeView locations are
handled separately. A bound import table without a lookup table is explicitly
unavailable rather than decoded as names.

The caller owns the source and must validate its identity or stopped generation
before publication and reuse. Parsed metadata owns its labels and arrays.
`xpe_read_rva` borrows the source under the parser's budget; destroying an image
does not close that source. Post-parse `xpe_read_range` reads at most 4 KiB through
the same identity-checked source, without consuming the parser's lifetime budget.
It does not mutate parser state. Opcode and chain interpretation lives in the
separate `src/debug/pe_unwind.c` decoder.

Caps are 96 sections, 65,536 exports/names/imports, 4,194,304 runtime functions,
1,024 imported libraries and 16 RSDS records. Retained allocations are capped
at 96 MiB; total source reads at 128 MiB and 262,144 callbacks. Strings are capped
at 4,096 bytes including their terminator. A retained runtime-function row costs
16 bytes, so a game executable with a million functions retains 16 MiB and the
cap itself 64 MiB; the table is read once into a temporary buffer of 12 bytes a
row. An empty row (`begin >= end`, left behind by some linkers) covers no address:
it is left out and counted in `function_skipped`, and the image keeps its other
rows. Unwind records are not read while loading; each is located and checked
when an unwind consults it. Export labels by address use an index sorted once
at load. Imports grow with actual entries.
Temporary table buffers have separate checked sizes and are freed during
parsing. Each metadata table must fit within one declared section or headers;
ambiguous/overlapping sections are refused. Source callbacks must return exact reads and propagate changes,
cancellation or unavailability. Unsupported machines/PE32 return a typed refusal.

## Native Wine images

The debugger pins a mapped file by device/inode and source timestamps, reads its
metadata on one background worker, and compares its PE headers and sections with
the stopped loaded image. The mapping must cover every section; executable
sections must have executable mappings. Runtime addresses use the actual mapped
header base, including relocated DLLs. File bytes and loaded-memory RVAs remain
separate. Matching structural headers does not compare all executable bytes.

Each mapped file is classified once, from its first bytes, as ELF, PE or neither,
and the ELF and PE paths share that decision; it is dropped when the file leaves
the address space. A stop therefore does not reopen files that are not PE images.
File views opened during one stop share a single read of the process's maps: a
stopped, unshared address space cannot drop a mapping between two views.

`list_modules` preserves each raw kernel mapping and adds nullable `pe_image`
attribution with module ID, base and path. `pe_metadata_pending` marks incomplete
discovery. Session `pe_metadata` counts resident images, identity records, retained
and reserved bytes, evictions and an active worker. Symbol breakpoints accept
`module.dll!export`; forwarded exports refuse with
`PeForwardedExportUnavailable`. Functions without exported names use
`module.dll!sub_RVA`. PDB paths and GUIDs are metadata only; PDB symbols and lines
are not loaded yet.

The cache retains at most 256 jobs, 256 MiB of parsed metadata, and 1,024 identity
records. An active worker reserves its 96 MiB allocation ceiling. Each pinned
file view also has a bounded 64 KiB read buffer; this overhead is separate from
parsed metadata. Eviction closes the view and frees metadata, while IDs and
original identities survive. Reload must match the original file version.
Limits are caps, with allocation following actual metadata sizes.

This integration currently supports native local targets with a known file-backed
header. Agent/remote and core PE discovery, and images without
a known file anchor, remain unavailable. Shared-vm stops refuse loaded-image
verification. The standalone reader also accepts memory-layout sources; that does
not imply a live anonymous-only discovery path.

## Windows x64 stacks

The decoder follows the [Windows x64 unwind format](https://learn.microsoft.com/en-us/cpp/build/exception-handling-x64)
and [prologue/epilogue rules](https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog).
It supports version-1 push, small/large allocation, frame establishment, integer
and XMM saves, and chained delayed saves. Completed prologue operations and
remaining epilogue instructions are handled separately. Instruction inspection
always starts at the actual control PC; the caller-label adjustment to PC-1 is
never used to scan an epilogue. Known leaves pop one return address only after
the owner verifies executable PE placement.

Native walks revalidate the source identity, selected runtime-function row, and
every consulted unwind record against the stopped loaded image. Code reads use
the target reader, including its software-breakpoint overlay. Generation changes,
changed metadata, failed reads and missing required registers stop the walk.
The caller context is published only after a complete successful step. Volatile
registers become unavailable; vector values are not exposed by the current
scalar frame register model.

Limits are 32 chained records, 255 slots per record, 64 epilogue bytes and 16 KiB
of stack reads per frame. Chain cycles, malformed records and arithmetic overflow
refuse. Exception-handler references are checked but handlers are never called.
Version 2/3, indirect runtime-function chaining and machine frames have distinct
unsupported diagnostics.

Records are accepted as the format allows them: codes at offset 0 with no prolog
(how GCC describes the cold half of a split function) and a frame-pointer set
between pushes (`push rbp; mov rbp,rsp; push ...`) are valid.

An epilogue is `add rsp,imm` or `lea rsp,disp[frame]`, then pops, then `ret` or a
`jmp` that leaves the function. A `jmp` counts only in the forms compilers
reserve for leaving: `jmp [rip+disp]`, any indirect `jmp` carrying REX.W, and a
relative `jmp` out of the function (or to its own start). Without REX.W,
`jmp rax` and `jmp [table+reg*8]` are switch dispatch in the body. Anything not
recognised, a doubtful case included, is unwound from the unwind codes.
One case departs from the platform on purpose: a bare relative `jmp` that lands
inside another table row, or on a row whose frame exists on entry (a chained
record, or codes with no prolog), is a jump between fragments of one function,
so the frame is intact and the unwind codes apply. `RtlVirtualUnwind` treats
such a `jmp` as a tail call and reports the wrong caller. When no function table
is available to classify the target, that one form is refused.

Wine transitions use available Windows metadata or existing ELF CFI. Missing or
unsupported rules leave a partial stack with the failing frame's diagnostic;
there is no stack scan, frame-pointer guess or special syscall-frame reconstruction.
Recovering ordinary owned Windows stacks does not establish support for every
Wine syscall/host transition. Dynamic runtime function tables and PDB locals
remain unavailable.

## Recorded profiles

Opening a native profile retains already discovered and verified PE files while
the process is stopped. It compares the opening maps, loaded headers, complete
runtime-function table and every unwind record that can produce a caller with
the pinned file version. Pending discovery and failed retention are reported in
the capture's `mapping_history` summary. A PE loaded later in the capture has no
retained PE asset; its addresses remain available with partial analysis.

Saved Windows stacks use only captured perf registers, the saved stack window,
timestamped mappings and immutable file assets. They never read the live target
or reopen an asset during analysis. Both the label PC and actual control PC must
have matching executable placement. Each successful step reports
`windows_unwind`, `windows_leaf` or `windows_epilog`. Missing bytes, unsupported
records and unverified mappings terminate a partial result.

PE and ELF snapshots share the 256-image, 256 MiB per-file and 512 MiB total file
budgets. PE parser allocations have a separate 256 MiB retained cap. These limits
do not preallocate storage. Capture opening is synchronous, as for existing ELF
snapshots. Header/unwind comparison does not establish byte-for-byte loaded code
identity: recorded epilogue inspection uses the original file, and in-place code
or unwind modifications after opening are outside mapping-history coverage.

Archives with PE assets use format 2.8 and required feature bit 6. Assets remain
external: explicit resolution requires matching length and SHA-256 before parsing.
Missing or changed assets leave recorded labels intact, but cannot supply callers.
Worker snapshots borrow immutable PE assets from their pinned source capture.

## Checks

```sh
python3 -B tests/pe-image.py --work .work/pe-check
python3 -B tests/pe-unwind.py --work .work/pe-unwind
```

This fast component lane builds an owned DLL and PDB with Clang/LLD, compares
exports and runtime-function ranges with `llvm-readobj`, checks both layouts,
and rejects hostile extents, ordinals, forwarders, function ranges and CodeView
pointers. The loaded-image check deliberately corrupts the irrelevant disk
pointer. A wrong ordinal must abort with checks still active under `NDEBUG`.

The fast check is registered in the ordinary release-check lanes.
`periodic` and `periodic-gui` also run the fuzz check. Clang, LLD (`lld-link`),
`llvm-readobj` and a host C compiler must be available.

Add `--fuzz` for the periodic 30-second ASan/UBSan libFuzzer lane. Use a fresh work
directory each run. Compiler and parser fixtures are synthetic; no private game
or existing Windows installation is required.

The worker and private Wine checks run in periodic lanes:

```sh
python3 -B tests/pe-job.py --work .work/pe-worker --sanitize
python3 -B tests/pe-wine.py --work .work/pe-native --wine /usr/bin/wine
python3 -B tests/pe-wine.py --work .work/pe-eviction --wine /usr/bin/wine --eviction
python3 -B tests/pe-wine.py --work .work/pe-stack --wine /usr/bin/wine --unwind
python3 -B tests/pe-wine.py --work .work/pe-profile --wine /usr/bin/wine --profile
python3 -B tests/pe-unwind-runtime.py --work .work/pe-runtime --wine /usr/bin/wine
python3 -B tests/pe-corpus.py --work .work/pe-corpus --wine /usr/bin/wine
```

The corpus check runs the reader and the unwind validator over every x64 PE file
of the installed Wine, found beside the given executable, and prints counts only.
It fails if an image is refused, if more than 100 records per million are
refused, or if a refusal has no stated reason. The expected remainder is a
handful of dispatcher stubs in `ntdll` that carry machine frames.

The worker test includes a condition-held source read, cancelled publication,
nonblocking join, changed-file refusal, and a planted wrong ordinal under
`NDEBUG`. The Wine checks compare stopped PCs with addresses printed by the owned
fixture, change and restore loaded headers, verify an unexported function label,
and prove eviction by a closed pinned source descriptor before reload. Wine uses
a fresh private prefix and headless compositor. Pass `--wine PATH` to
`release-check periodic` or `periodic-gui` to include these optional Wine checks.

The fast unwind lane checks compiler-assembled SEH tables at prologue/epilogue
boundaries, recovered nonvolatile registers, chained saves, malformed records,
and every-read failure. `--fuzz` adds the periodic sanitizer lane. The runtime
oracle compares the decoder with `RtlVirtualUnwind` at 28 compiler instruction
boundaries, two chained-save states and 14 crafted epilogue and record shapes
(`tests/fixtures/pe/unwind-cases.h`), and checks that the two documented
fragment jumps do differ from the platform; it requires Zig's Windows headers. The live oracle compares optimized
recursive/dynamic/SEH frames with `RtlCaptureStackBackTrace` and a compiler return
address, then changes and restores loaded unwind metadata. Both include planted
wrong results. Keep private compositor work paths short enough for Unix sockets.

The profile variant samples a bounded workload inside that same optimized stack,
compares its saved callers with the runtime oracle, reopens the archive with
verified assets, then checks missing and altered assets. `--wrong-result --profile`
plants a wrong saved caller. Fast Zig tests cover truncated stack windows,
unsupported metadata, actual-PC placement, immutable file ownership, worker
borrowing and the typed archive feature boundary; build-tests runs them in every
release-check lane.
