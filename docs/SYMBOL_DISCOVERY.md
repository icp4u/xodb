# Local symbol discovery and source paths

Live sessions automatically look for a verified debug companion when a loaded
ELF lacks DWARF. The local GUI and MCP use the same companion and source map.

- Build ID: `/usr/lib/debug/.build-id/xx/remaining-id.debug`.
- `.gnu_debuglink`: the binary's directory, its `.debug` subdirectory, then the
  matching absolute directory beneath each debug root.
- `--debug-dir /absolute/root` replaces the default root; repeat for multiple roots.
- `--debug-file FILE` remains the explicit build-ID-matched companion option.
- `--source-map /recorded/build/root=/local/checkout` substitutes whole directory
  prefixes. Repeat for up to 32 mappings; the longest matching prefix wins.
- GUI source display, source stepping, stack locations, source breakpoints and
  source run-to use these maps. Returned source records preserve `original_path`.
- `get_debug_files` reports retained companions, verification method, byte counts
  and source maps. It does not return file contents.

Example:

```sh
./zig-out/bin/xodb --debug-dir "$PWD/symbols" \
  --source-map /build/project="$PWD" -- ./stripped-program
```

`symbols.automatic` in preferences disables automatic discovery. Defaults are
64 MiB per automatic file and 128 MiB total; `symbols.auto_file_bytes` and
`symbols.auto_total_bytes` configure them up to the existing 256/512 MiB bounds.
Explicit files share the overall 512 MiB, 64-file retention limit. Files are
snapshotted, checked for changes during reading, and retained read-only.

Matching checks build ID when present, debuglink CRC when that method is used,
and ELF architecture/type/load layout. CRC-only files work for binaries without
build IDs. Mismatches produce diagnostics and leave the runtime image usable.
Build IDs and CRCs associate builds; they are not authentication of binary origin.
Automatic discovery is local, has no download path, and is currently for ordinary
live ELF modules. APK companions and offline archives retain their explicit rules.

Remote source sharing still requires `--source FILE` on the service. A source map
changes path interpretation; it does not itself grant remote file sharing. With
`--ssh`, source-map/debug-directory arguments are forwarded as service paths.
