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
