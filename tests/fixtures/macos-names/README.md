# Recorded macOS naming fixtures

These are owned synthetic programs compiled with Apple clang 21 / Swift 6.4
and recorded with Apple debugserver 2103 on macOS 26.6. No macOS machine is
needed for the tests. `SHA256.json` identifies the original binary and packet
files. Process/thread identities are synthetic; paths use `/xodb-corpus`.
Image UUIDs identify these builds, not hardware, and remain intact so the
debugger can match a transcript image to its exact file.

The corpus includes C, C++, Objective-C and Swift executables and their small
dylibs, a debug-stripped executable, arm64e, and a universal file whose running
slice is arm64e. The universal container's subtype includes capability bits;
the stub reports the low subtype bits. There are no Apple shared-cache files
or private export lists here. System frames receive image offsets only.

`tests/macos-names.py` serves stopped register, frame-record and image-list
replies from these transcripts. For the existing frame-pointer prologue
heuristic, executable bytes come from the matching corpus binary. Unrecorded
memory is unavailable. The older generic debugserver replay helper may serve
its last recorded image list for a supplementary query; these tests instead
use the image list recorded at each selected stop, including dlopen/dlclose.

The dylib oracle comes from `llvm-nm --format=posix --defined-only --extern-only`:
`libdep.dylib` defines `_dep_add` at `0x4c8`, and `libplug.dylib` defines
`_plug_entry` at `0x390`. The abort address example is checked directly through
`get_macho_image`, including the link register. Its image label does not imply
that the unwinder has proved an extra frame from that register.

The source/locals fixtures also include matching dSYM DWARF files, N_OSO
objects, and optimized C++/Objective-C/Swift recordings from the same owned,
scrubbed corpus. `SHA256.json` covers these additions. Source paths remain
under `/xodb-corpus`; no host paths or private recordings are used. The
recordings provide only their captured memory, so absent values deliberately
remain unavailable. Compiler-generated compact/EH data is retained in the
original images and used as an independent unwind oracle.

The regions, threads, bad-access, exec, exit, fork, signal and hardware-slot
recordings also drive `tests/macos-views.py`. Missing read packets remain
unavailable. Run-control replays use recorded stops; hostile variants and the
retained-probe/over-generous-slot cases explicitly alter those inputs. Raw
thread IDs in RSP fields, `jThreadsInfo` JSON and the hex-encoded `jstopinfo`
JSON of stop replies are normalized to the same synthetic range. The SHA-256 manifest covers every fixture file listed.

For a new harvest, decode every hex-encoded `jstopinfo` JSON payload before
scrubbing identifiers, normalize its JSON thread and process values alongside
the visible RSP fields, then encode the JSON again. A text-only replacement
does not see identifiers hidden in those hexadecimal bytes.
