# Explicit debug symbols

`--debug-file FILE` supplies symbols and DWARF to a live xodb session. Repeat it
for multiple libraries. Use either the original unstripped ELF or a separate
file produced with `objcopy --only-keep-debug`. The target may use a stripped
copy, including a library mapped directly from an APK.

```sh
./zig-out/bin/xodb --debug-file /build/libnative.so --attach PID

./zig-out/bin/xodb --headless --mcp --agent-scope control \
  --debug-file /build/libone.debug --debug-file /build/libtwo.debug --attach PID
```

A matching file enables the existing source breakpoints, native locals,
evaluation, stack/source inspection and stepping. Hardware watches still use
addresses and slots on the stopped target.

## Remote sessions

The file must be readable by the **debugger service**. Copy a selected host build
artifact to an authorized location on the target before using it there. xodb
checks the actual mapped ELF against its GNU build ID, architecture, ELF type
and PT_LOAD virtual layout. It reports matched companions and same-ID layout
mismatches on stderr. A filename alone is never a match.

```sh
# /target/build is on the SSH host, not the desktop.
./zig-out/bin/xodb --ssh HOST --remote-xodb /target/xodb \
  --debug-file /target/build/libnative.debug --attach PID
```

With `--connect`, set the option on the already-running server. Source sharing
remains a separate `--source FILE` choice. Companions are loaded before target
attachment and remain available after exec. There is no automatic path search,
download or transfer. Build IDs identify builds; use trusted symbol artifacts.

## APK libraries

The module loader recognizes a directly mapped, uncompressed `.so` entry inside
an APK and computes that entry's own load bias. Multiple libraries and repeated
loaded instances remain separate. No APK extraction is required by the debugger.
The current parser supports single-disk ZIP32 and page-aligned stored entries;
ZIP64, encryption, ambiguous metadata and directly mapped compressed entries
are rejected. Android can still extract compressed libraries for ordinary ELF
loading, as the current demo does.

Host fixtures pass the debugger controls above for embedded DWARF and stripped
libraries with full/debug-only companions. The
[Pixel Bionic test](ANDROID_APK_TEST_PLAN.md#pixel-result-2026-10-02) also passes
for two directly mapped stripped libraries and their debug-only companions,
including source/locals/stack/eval, completed hardware writes and clean teardown.
This does not add managed Java/Kotlin variables or ART/JIT unwinding.

## Bounds and other symbol workflows

Up to 64 companions, 256 MiB per file and 512 MiB total. Files are retained in
immutable memory snapshots, so larger files increase startup time and memory.
Missing build IDs/DWARF, invalid inputs and duplicate build IDs are refused.

Offline captures use their existing `--symbols DIR` / SHA-256 asset workflow.
Imported simpleperf labels remain importer supplied. Live profiling does not
inherit these debugging companions in this first version.

[Decision and evidence](ANDROID_SYMBOLS_PROPOSAL.md) ·
[Implementation journal](research/android-symbols.md)
