# APK mappings and explicit debug companions

2026-10-02. Status: user adopted APK loading and explicit companions. Host tests and
Android cross-build pass. The separately approved Pixel Bionic test also passes.

## Short critical review

This removes the extracted/unstripped-library requirement from the debugger's
module layer. Each mapped APK entry gets its own ELF bytes and load bias, and a
repeatable `--debug-file FILE` supplies symbols/DWARF from an explicit matching
build. The existing source, locals, evaluation, stepping and watch controls then
work through the same remote protocol. Host tests exercise two libraries in one
APK with embedded DWARF, stripped libraries plus full companions, and stripped
libraries plus `objcopy --only-keep-debug` companions.

The tradeoff is that the first companion path belongs to the debugger service:
for Android, a host build artifact must be explicitly staged alongside xodb.
It is not desktop-side DWARF processing or automatic symbol transfer. Build ID
plus architecture and PT_LOAD layout prevents accidental cross-build matches;
it does not authenticate an untrusted file. A stale or wrong companion stays
unused. Large companions cost startup time and memory, and the Pixel test now
proves Bionic's real APK mapping behavior for this owned shell-UID fixture.
Feature adoption did not authorize phone writes; the device test was separately
reviewed and approved.

## Adopted behavior

- Detect ZIP-backed mappings from the actual matching device/inode file.
- Locate an uncompressed `.so` entry using ZIP metadata and the observed mapping
  offset. Never scan for ELF signatures inside arbitrary data or extract names.
- Keep different entries and repeated loaded instances separate. Subtract the
  entry offset before interpreting ELF segment offsets. Source breakpoint and
  symbol searches include executable mappings with nonzero offsets.
- Retain only the selected ELF bytes, not the whole APK for each library.
  Snapshot limits: 256 MiB per image, 512 MiB per image store. ZIP metadata has
  a separate 16 MiB directory ceiling and the ZIP32 entry-count bound.
- First parser supports ordinary single-disk ZIP32, stored entries, ZIP comments,
  data descriptors, and APK signing blocks before the central directory.
  Compressed directly mapped libraries, encrypted entries, ZIP64, malformed or
  ambiguous entries are explicit errors. Extracted compressed libraries continue
  to work as ordinary ELF files.
- Repeat `--debug-file FILE` on the live debugger service. Accept an unstripped
  ELF or an objcopy debug-only ELF with GNU build ID and DWARF. Reject invalid
  inputs before attaching, including duplicate build IDs. Up to 64 companions,
  256 MiB each / 512 MiB total, in immutable snapshots.
- Match GNU build ID, machine, ELF type and each PT_LOAD's virtual address,
  memory extent, permissions and alignment. File extents may differ after
  stripping. Runtime instructions and `.eh_frame` still come from the mapped
  image; symbols, DWARF and `.debug_frame` come from the companion.
- Report matched files and same-ID layout mismatches on stderr. No basename,
  directory, debuglink or network search. No source is shared by this option;
  `--source` remains an explicit separate choice.
- `--ssh ... --debug-file FILE` forwards a **remote** path. `--connect` rejects
  it because the live server owns symbol loading. Offline archives and imported
  profiles retain their existing symbol workflows. Live profiling does not
  currently inherit these debugging companions.

## Usage and verification

```sh
# Host-only test. Creates and reaps owned fixture processes; never uses ADB.
python3 tests/apk/check.py --server zig-out/bin/xodb --debug-files

# Service-side example; paths must exist on that host/device.
xodb --headless --mcp --agent-scope control \
  --debug-file /explicit/build/libnative.so --attach PID
```

- Native suite: **222 passed, 4 skipped**. New cases cover malformed/ambiguous
  APK entries, unsupported compression/flags/ZIP64, repeated load instances,
  build IDs without section headers, conflicting notes, different build IDs,
  duplicate companions and same-ID architecture/layout mismatches.
- Host end-to-end evidence: `.work/apk-check-20261002T163021643956/`.
  All three variants pass distinct module identity, native symbol lookup, source
  breakpoints, locals, eval, hardware writes **100 -> 103**, and source stepping.
- Android/Bionic ARM64 ReleaseSafe cross-build passes in
  `.work/android-symbols-build-20261002T163754059068/`. Its exact service bytes
  passed the Pixel test and were promoted into the launchers' default build.
- Existing remote TCP lifecycle checks also pass, including attached-target
  preservation and probe restoration on hangup.
- The host fixture maps two real ELF PT_LOAD sets from the same archive inode.
  It is not a complete Android linker emulation or evidence about ART frames.
- [Implementation findings](research/android-symbols.md).

[User guide](DEBUG_SYMBOLS.md) · [Bionic device test plan](ANDROID_APK_TEST_PLAN.md)

## Later work

The [approved Pixel test](ANDROID_APK_TEST_PLAN.md) passed with exact cleanup.
Next, make the app launcher accept ordinary debuggable packages, explicit APK/library
identity and selected symbol artifacts. Desktop-side symbol workers can avoid
uploading large DWARF files once the remote memory/inspection contracts support
that division of work. Managed frames, reconnect and live profiling are separate.
